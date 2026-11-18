-- ============================================================
-- Sincronización con Lisa (job UpdateLIsaSboferco, cada 30 s): lectura ÚNICA de
-- los cuadros de SAP.
--
-- Antes, en cada ciclo, SP_SyncNoDespachadaEscuintla, SP_AutoDespachoEscuintla y
-- SP_LimpiarHuerfanosEscuintla leían por separado [@CUADRO_RUTA_E] (32 mil filas) y
-- [@CUADRO_RUTA_D] (207 mil) cruzándolas con tablas locales, lo que obliga a traer
-- las tablas completas por el linked server: ~3,7 s por ciclo.
-- Ahora SP_UpdateOrderPickingTasksLisa hace UNA lectura filtrada en SAP
-- (OPENQUERY, DocNum IN cuadros activos) en #SapCuadroDet y los tres SP la usan:
-- ~0,05 s. Verificado contra producción (2026-11-18): mismos cuadros, líneas,
-- cuadros vivos y candidatos de autodespacho (reglas 1 y 2) que la lectura anterior.
--
-- Seguridad:
--   * Si la lectura única falla, se borran las tablas y cada SP vuelve a su
--     lectura anterior. Llamados sueltos funcionan igual que antes.
--   * LimpiarHuerfanos solo evalúa cuadros que estaban en la lectura.
--
-- Supersede, para estos SP, a FIX_/GT138_03_/HN_04_SP_UpdateOrderPickingTasksLisa,
-- NoDespachada_02_SP_SyncNoDespachadaEscuintla, SP_AutoDespachoEscuintla y
-- SP_LimpiarHuerfanosEscuintla. El resto del cuerpo es la versión de producción
-- del 2026-11-18, sin cambios. Idempotente. NO escribe a SAP ni a Lisa.
-- Requiere SQL Server 2016 SP1+ (CREATE OR ALTER).
-- ============================================================

CREATE OR ALTER PROCEDURE [dbo].[SP_SnapshotCuadrosSapEscuintla]
AS
BEGIN
    -- Llena #CuadrosLeidos y #SapCuadroDet, que crea quien llama
    -- (SP_UpdateOrderPickingTasksLisa): los cuadros activos de Escuintla (GT, centro 3,
    -- no despachados) y, de SAP, su cabecera y sus líneas en UNA consulta remota por
    -- lote de 400 cuadros. Con OPENQUERY el filtro DocNum IN (...) corre en SAP con su
    -- índice, en vez de traer las tablas completas al servidor local.
    SET NOCOUNT ON;
    IF OBJECT_ID('tempdb..#SapCuadroDet') IS NULL OR OBJECT_ID('tempdb..#CuadrosLeidos') IS NULL RETURN;

    INSERT INTO #CuadrosLeidos (RouteNumber)
    SELECT DISTINCT RouteNumber FROM dbo.OrderRoutePlan
    WHERE ID_Centro = 3 AND Pais = 'GT' AND EstadoDespacho <> 'Finalizado' AND RouteNumber > 0;

    DECLARE @desde INT = 0, @hasta INT, @lista NVARCHAR(MAX), @inner NVARCHAR(MAX), @sql NVARCHAR(MAX);
    WHILE 1 = 1
    BEGIN
        SELECT @lista = NULL, @hasta = NULL;
        SELECT @lista = STUFF((SELECT TOP 400 ',' + CAST(RouteNumber AS VARCHAR(12))
                               FROM #CuadrosLeidos WHERE RouteNumber > @desde
                               ORDER BY RouteNumber FOR XML PATH('')), 1, 1, '');
        IF @lista IS NULL BREAK;
        SELECT @hasta = MAX(RouteNumber)
        FROM (SELECT TOP 400 RouteNumber FROM #CuadrosLeidos WHERE RouteNumber > @desde ORDER BY RouteNumber) x;

        -- Sin comillas dentro de la consulta remota (así no hay que escaparlas).
        SET @inner = N'SELECT e.DocNum, e.U_Estado, ISNULL(LTRIM(RTRIM(e.U_Placa)), SPACE(0)) AS Placa, e.UpdateDate, '
                   + N'CASE WHEN d.DocEntry IS NULL THEN 0 ELSE 1 END AS TieneLinea, LTRIM(RTRIM(d.U_No_OV)) AS OV '
                   + N'FROM sboferco.dbo.[@CUADRO_RUTA_E] e WITH (NOLOCK) '
                   + N'LEFT JOIN sboferco.dbo.[@CUADRO_RUTA_D] d WITH (NOLOCK) ON d.DocEntry = e.DocEntry '
                   + N'WHERE e.DocNum IN (' + @lista + N')';
        SET @sql = N'INSERT INTO #SapCuadroDet (DocNum, Estado, Placa, UpdateDate, TieneLinea, OV) '
                 + N'SELECT * FROM OPENQUERY([server-sql], ''' + @inner + N''')';
        EXEC (@sql);
        SET @desde = @hasta;
    END
END;
GO

CREATE OR ALTER PROCEDURE [dbo].[SP_SyncNoDespachadaEscuintla]
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#SapCuadros') IS NOT NULL DROP TABLE #SapCuadros;
    IF OBJECT_ID('tempdb..#SapLineas')  IS NOT NULL DROP TABLE #SapLineas;
    CREATE TABLE #SapCuadros (RouteNumber INT PRIMARY KEY);
    CREATE TABLE #SapLineas  (RouteNumber INT, OV NVARCHAR(50) COLLATE DATABASE_DEFAULT);

    IF OBJECT_ID('tempdb..#SapCuadroDet') IS NOT NULL
    BEGIN
        -- Lectura única hecha por SP_UpdateOrderPickingTasksLisa (ya filtrada a los
        -- cuadros activos de Escuintla): cabeceras y líneas.
        INSERT INTO #SapCuadros (RouteNumber) SELECT DISTINCT DocNum FROM #SapCuadroDet;
        IF NOT EXISTS (SELECT 1 FROM #SapCuadros) RETURN;  -- anti-falsos
        INSERT INTO #SapLineas (RouteNumber, OV)
        SELECT DISTINCT DocNum, OV FROM #SapCuadroDet WHERE TieneLinea = 1;
    END
    ELSE
    BEGIN
        -- Llamado suelto: lectura directa como antes.
        -- Cuadros vigentes de Escuintla (no despachados) que tienen header en SAP.
        INSERT INTO #SapCuadros (RouteNumber)
        SELECT e.DocNum
        FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
        WHERE EXISTS (
            SELECT 1 FROM dbo.OrderRoutePlan orp
            WHERE orp.RouteNumber = e.DocNum AND orp.ID_Centro = 3 AND orp.Pais = 'GT'
              AND orp.EstadoDespacho <> 'Finalizado'
        );

        -- Anti-falsos: si el linked server no devolvió headers, no tocar nada.
        IF NOT EXISTS (SELECT 1 FROM #SapCuadros) RETURN;

        -- Líneas (documentos) actuales de esos cuadros en SAP.
        INSERT INTO #SapLineas (RouteNumber, OV)
        SELECT DISTINCT e.DocNum, LTRIM(RTRIM(d.U_No_OV)) COLLATE DATABASE_DEFAULT
        FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
        INNER JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] d WITH (NOLOCK)
             ON d.DocEntry = e.DocEntry
        WHERE EXISTS (SELECT 1 FROM #SapCuadros c WHERE c.RouteNumber = e.DocNum);
    END

    CREATE INDEX IX_SapLineas ON #SapLineas (RouteNumber, OV);

    -- MARCA: la OV ya no está en el cuadro de SAP (pero el cuadro SÍ se leyó).
    --   EDIT-AWARE: no marcar pedidos AGREGADOS en el app (PendienteSync=1) —
    --   aún no están en SAP, no es que SAP los haya sacado.
    UPDATE opm
    SET opm.NoDespachada = 1, opm.FechaNoDespachada = GETDATE()
    FROM dbo.OrderPickingManagement opm
    INNER JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
    INNER JOIN #SapCuadros c ON c.RouteNumber = orp.RouteNumber
    WHERE orp.ID_Centro = 3 AND orp.Pais = 'GT'
      AND orp.EstadoDespacho <> 'Finalizado'
      AND opm.NoDespachada = 0
      AND opm.PendienteSync = 0
      AND NOT EXISTS (
          SELECT 1 FROM #SapLineas s
          WHERE s.RouteNumber = orp.RouteNumber
            AND s.OV = LTRIM(RTRIM(opm.OV_Number)) COLLATE DATABASE_DEFAULT
      );

    -- DESMARCA: SAP volvió a incluir el documento en el cuadro.
    --   EDIT-AWARE: NO revivir un doc QUITADO en el app cuya baja aún no se
    --   refleja en SAP (RemocionPendienteSync=1): SAP todavía lo trae, pero la
    --   baja la pedimos nosotros y Fase 3 la sincronizará.
    UPDATE opm
    SET opm.NoDespachada = 0, opm.FechaNoDespachada = NULL
    FROM dbo.OrderPickingManagement opm
    INNER JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
    WHERE orp.ID_Centro = 3 AND orp.Pais = 'GT'
      AND opm.NoDespachada = 1
      AND opm.RemocionPendienteSync = 0
      AND EXISTS (
          SELECT 1 FROM #SapLineas s
          WHERE s.RouteNumber = orp.RouteNumber
            AND s.OV = LTRIM(RTRIM(opm.OV_Number)) COLLATE DATABASE_DEFAULT
      );

    DROP TABLE #SapCuadros;
    DROP TABLE #SapLineas;
END;
GO

CREATE OR ALTER PROCEDURE [dbo].[SP_AutoDespachoEscuintla]
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#SapCuadroDet') IS NOT NULL
    BEGIN
        -- Con la lectura única de SP_UpdateOrderPickingTasksLisa (mismas reglas).
        -- Regla 1: picking completo + placa -> Despachado
        UPDATE orp
        SET orp.EstadoDespacho = 'Finalizado',
            orp.FechaDespachoFin = GETDATE()
        FROM dbo.OrderRoutePlan orp
        JOIN (SELECT DISTINCT DocNum, Placa FROM #SapCuadroDet) e
             ON e.DocNum = orp.RouteNumber
        WHERE orp.ID_Centro = 3
          AND orp.Estado = 'Finalizado'
          AND orp.EstadoDespacho IN ('Pendiente', 'Listo para Carga')
          AND ISNULL(e.Placa, '') <> '';

        -- Regla 2: SAP ya está en '03' (despachado) -> cerrar completo,
        -- sin importar el estado de picking del app.
        UPDATE orp
        SET orp.Estado = 'Finalizado',
            orp.FechaFin = ISNULL(orp.FechaFin, ISNULL(e.UpdateDate, GETDATE())),
            orp.EstadoDespacho = 'Finalizado',
            orp.FechaDespachoFin = ISNULL(e.UpdateDate, GETDATE())
        FROM dbo.OrderRoutePlan orp
        JOIN (SELECT DISTINCT DocNum, Estado, UpdateDate FROM #SapCuadroDet) e
             ON e.DocNum = orp.RouteNumber
        WHERE orp.ID_Centro = 3
          AND orp.Pais = 'GT'
          AND orp.EstadoDespacho <> 'Finalizado'
          AND e.Estado = '03';
        RETURN;
    END

    -- Llamado suelto: lectura directa como antes.
    -- Regla 1: picking completo + placa -> Despachado
    UPDATE orp
    SET orp.EstadoDespacho = 'Finalizado',
        orp.FechaDespachoFin = GETDATE()
    FROM dbo.OrderRoutePlan orp
    JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
         ON e.DocNum = orp.RouteNumber
    WHERE orp.ID_Centro = 3
      AND orp.Estado = 'Finalizado'
      AND orp.EstadoDespacho IN ('Pendiente', 'Listo para Carga')
      AND LTRIM(RTRIM(ISNULL(e.U_Placa, ''))) <> '';

    -- Regla 2: SAP ya está en '03' (despachado) -> cerrar completo,
    -- sin importar el estado de picking del app.
    UPDATE orp
    SET orp.Estado = 'Finalizado',
        orp.FechaFin = ISNULL(orp.FechaFin, ISNULL(e.UpdateDate, GETDATE())),
        orp.EstadoDespacho = 'Finalizado',
        orp.FechaDespachoFin = ISNULL(e.UpdateDate, GETDATE())
    FROM dbo.OrderRoutePlan orp
    JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
         ON e.DocNum = orp.RouteNumber
    WHERE orp.ID_Centro = 3
      AND orp.Pais = 'GT'
      AND orp.EstadoDespacho <> 'Finalizado'
      AND e.u_estado = '03';
END;
GO

CREATE OR ALTER PROCEDURE [dbo].[SP_LimpiarHuerfanosEscuintla]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @sapUp INT;
    DECLARE @conLectura BIT = CASE WHEN OBJECT_ID('tempdb..#SapCuadroDet') IS NOT NULL
                                    AND OBJECT_ID('tempdb..#CuadrosLeidos') IS NOT NULL THEN 1 ELSE 0 END;
    IF OBJECT_ID('tempdb..#vivos') IS NOT NULL DROP TABLE #vivos;
    CREATE TABLE #vivos (RouteNumber INT PRIMARY KEY);
    -- Cuadros que se pueden evaluar en esta corrida (los que se leyeron de SAP).
    IF OBJECT_ID('tempdb..#evaluables') IS NOT NULL DROP TABLE #evaluables;
    CREATE TABLE #evaluables (RouteNumber INT PRIMARY KEY);

    IF @conLectura = 1
    BEGIN
        -- Guard: ¿SAP responde? (conteo filtrado en SAP) y la lectura única trajo cuadros.
        SELECT @sapUp = n FROM OPENQUERY([server-sql],
            'SELECT COUNT(*) AS n FROM sboferco.dbo.[@CUADRO_RUTA_E] WITH (NOLOCK) WHERE CreateDate > DATEADD(day, -3, GETDATE())');
        IF ISNULL(@sapUp, 0) = 0 OR NOT EXISTS (SELECT 1 FROM #SapCuadroDet) RETURN;
        -- Cuadros activos del app que SÍ tienen líneas en SAP.
        INSERT INTO #vivos (RouteNumber) SELECT DISTINCT DocNum FROM #SapCuadroDet WHERE TieneLinea = 1;
        -- Solo cuadros que estaban en la lectura (uno creado después no es huérfano,
        -- solo no se leyó en este ciclo).
        INSERT INTO #evaluables (RouteNumber) SELECT RouteNumber FROM #CuadrosLeidos;
    END
    ELSE
    BEGIN
        -- Llamado suelto: lectura directa como antes.
        -- Guard: ¿SAP responde? Si no hay cuadros recientes, no tocar nada.
        SELECT @sapUp = COUNT(*)
        FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] WITH (NOLOCK)
        WHERE CreateDate > GETDATE() - 3;
        IF ISNULL(@sapUp, 0) = 0 RETURN;

        -- Cuadros activos del app que SÍ tienen líneas en SAP (traídos en bloque).
        INSERT INTO #vivos (RouteNumber)
        SELECT DISTINCT e.DocNum
        FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
        JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] d WITH (NOLOCK) ON d.DocEntry = e.DocEntry
        WHERE EXISTS (SELECT 1 FROM dbo.OrderRoutePlan orp
                      WHERE orp.RouteNumber = e.DocNum AND orp.ID_Centro = 3 AND orp.Pais = 'GT'
                        AND orp.EstadoDespacho <> 'Finalizado');
        -- Como antes: se evalúan todos los cuadros activos.
        INSERT INTO #evaluables (RouteNumber)
        SELECT DISTINCT RouteNumber FROM dbo.OrderRoutePlan
        WHERE ID_Centro = 3 AND Pais = 'GT' AND EstadoDespacho <> 'Finalizado';
    END

    -- Huérfanos: activos en app sin líneas en SAP -> sacar del tablero.
    UPDATE orp
    SET orp.Estado = CASE WHEN orp.Estado = 'Pendiente' THEN 'Finalizado' ELSE orp.Estado END,
        orp.FechaFin = ISNULL(orp.FechaFin, GETDATE()),
        orp.EstadoDespacho = 'Finalizado',
        orp.FechaDespachoFin = ISNULL(orp.FechaFin, GETDATE())
    FROM dbo.OrderRoutePlan orp
    WHERE orp.ID_Centro = 3 AND orp.Pais = 'GT'
      AND orp.EstadoDespacho <> 'Finalizado'
      -- No tocar complementos que aún no se crean en SAP (RouteNumber provisional
      -- negativo, o pendientes del sync): no son huérfanos, solo no sincronizados.
      AND orp.RouteNumber > 0
      AND NOT (ISNULL(orp.EsComplemento, 0) = 1 AND ISNULL(orp.CreacionPendienteSync, 0) = 1)
      AND NOT EXISTS (SELECT 1 FROM #vivos v WHERE v.RouteNumber = orp.RouteNumber)
      AND EXISTS (SELECT 1 FROM #evaluables x WHERE x.RouteNumber = orp.RouteNumber);

    DROP TABLE #vivos;
    DROP TABLE #evaluables;
END;
GO

-- ============================================================
-- SP_UpdateOrderPickingTasksLisa — agrega GT (Escuintla/138) al loop.
-- Supersede el SP principal de sql/HN_04 (el sub-SP
-- SP_UpdateOrderPickingLisa_PorPais NO cambia).
-- GT refresca tareas order con Pais='GT' desde lisa_sboferco/sboferco
-- (solo aplica a 138; Zona 5 es producto y vive en otras tablas).
-- ============================================================
CREATE OR ALTER PROCEDURE [dbo].[SP_UpdateOrderPickingTasksLisa]
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 5000;

    DECLARE @msg VARCHAR(200), @retry INT, @done BIT;

    IF OBJECT_ID('tempdb..#RoutesProcessed') IS NOT NULL DROP TABLE #RoutesProcessed;
    -- COLLATE DATABASE_DEFAULT: la tabla temp toma la colación de la BD (CP850),
    -- no la de tempdb (CP1); evita el conflicto al comparar rp.Pais = t0.Pais.
    CREATE TABLE #RoutesProcessed (RouteNumber INT, Pais NVARCHAR(10) COLLATE DATABASE_DEFAULT);

    -- ── Refresco por país (modalidad order). Agregar países aquí. ──
    EXEC dbo.SP_UpdateOrderPickingLisa_PorPais @Pais = 'SV', @LisaDb = 'lisa_sbointergres', @SapDb = 'sbointergres';
    EXEC dbo.SP_UpdateOrderPickingLisa_PorPais @Pais = 'HN', @LisaDb = 'lisa_sbopym',       @SapDb = 'sbopym';
    EXEC dbo.SP_UpdateOrderPickingLisa_PorPais @Pais = 'GT', @LisaDb = 'lisa_sboferco',     @SapDb = 'sboferco';

    -- Sync de "No Despachada" (Escuintla): marca/desmarca OVs según sigan o no
    -- en el cuadro de SAP. ANTES del cierre, para que una OV recién marcada no
    -- bloquee el cierre del cuadro en esta misma corrida.
    -- Lectura ÚNICA de los cuadros activos de Escuintla en SAP (cabecera + líneas),
    -- filtrada en SAP por OPENQUERY. La usan SyncNoDespachada, AutoDespacho y
    -- LimpiarHuerfanos (antes cada uno leía por su cuenta las tablas completas:
    -- ~4 s por ciclo). Si la lectura falla, se borran las tablas y cada SP vuelve a
    -- su lectura anterior.
    CREATE TABLE #CuadrosLeidos (RouteNumber INT PRIMARY KEY);
    CREATE TABLE #SapCuadroDet (
        DocNum     INT NOT NULL,
        Estado     NVARCHAR(10) COLLATE DATABASE_DEFAULT NULL,
        Placa      NVARCHAR(10) COLLATE DATABASE_DEFAULT NULL,
        UpdateDate DATETIME NULL,
        TieneLinea BIT NOT NULL,
        OV         NVARCHAR(15) COLLATE DATABASE_DEFAULT NULL
    );
    BEGIN TRY
        EXEC dbo.SP_SnapshotCuadrosSapEscuintla;
    END TRY
    BEGIN CATCH
        SET @msg = 'Lectura unica de cuadros SAP fallida (se usa la lectura anterior): ' + LEFT(ERROR_MESSAGE(), 100);
        RAISERROR(@msg, 0, 0) WITH NOWAIT;
        DROP TABLE #SapCuadroDet;
        DROP TABLE #CuadrosLeidos;
    END CATCH

    EXEC dbo.SP_SyncNoDespachadaEscuintla;

    -- ================================================
    -- Cierre 1: OrderPickingTask con CantidadPendiente = 0
    -- ================================================
    RAISERROR('Cerrando tareas finalizadas...', 0, 0) WITH NOWAIT;
    SET @retry = 0; SET @done = 0;
    WHILE @retry <= 3 AND @done = 0
    BEGIN
        BEGIN TRY
            UPDATE t0 WITH (ROWLOCK)
            SET Estado = 'Finalizado', UltimaActualizacion = GETDATE()
            FROM dbo.OrderPickingTask t0
            WHERE ISNULL(t0.CantidadPendiente, 0) = 0
              AND t0.Estado <> 'Finalizado'
              AND EXISTS (SELECT 1 FROM #RoutesProcessed rp
                          WHERE rp.RouteNumber = t0.RouteNumber AND rp.Pais = t0.Pais);
            SET @msg = 'Tareas cerradas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
            RAISERROR(@msg, 0, 0) WITH NOWAIT; SET @done = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() = 1222 AND @retry < 3
            BEGIN SET @retry += 1; WAITFOR DELAY '00:00:03'; END
            ELSE BEGIN
                SET @msg = 'Cierre tareas fallido: ' + ERROR_MESSAGE();
                RAISERROR(@msg, 0, 0) WITH NOWAIT; SET @done = 1;
            END
        END CATCH
    END

    -- ================================================
    -- Cierre 2: OrderPickingManagement
    -- ================================================
    RAISERROR('Cerrando OrderPickingManagement...', 0, 0) WITH NOWAIT;
    SET @retry = 0; SET @done = 0;
    WHILE @retry <= 3 AND @done = 0
    BEGIN
        BEGIN TRY
            ;WITH PendientePedido AS (
                SELECT opt.ID_OrderPicking, SUM(ISNULL(opt.CantidadPendiente, 0)) AS CantidadPendiente
                FROM dbo.OrderPickingTask opt WITH (NOLOCK)
                WHERE opt.Estado <> 'Pendiente'
                  AND EXISTS (SELECT 1 FROM #RoutesProcessed rp
                              WHERE rp.RouteNumber = opt.RouteNumber AND rp.Pais = opt.Pais)
                GROUP BY opt.ID_OrderPicking
            )
            UPDATE opm WITH (ROWLOCK)
            SET opm.Estado = 'Finalizado', opm.FechaFin = GETDATE()
            FROM dbo.OrderPickingManagement opm
            INNER JOIN PendientePedido pp ON pp.ID_OrderPicking = opm.ID_OrderPicking
            WHERE pp.CantidadPendiente = 0 AND ISNULL(opm.Estado, '') <> 'Finalizado';
            SET @msg = 'OrderPickingManagement cerrados: ' + CONVERT(VARCHAR, @@ROWCOUNT);
            RAISERROR(@msg, 0, 0) WITH NOWAIT; SET @done = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() = 1222 AND @retry < 3
            BEGIN SET @retry += 1; WAITFOR DELAY '00:00:03'; END
            ELSE BEGIN
                SET @msg = 'Cierre OPM fallido: ' + ERROR_MESSAGE();
                RAISERROR(@msg, 0, 0) WITH NOWAIT; SET @done = 1;
            END
        END CATCH
    END

    -- ================================================
    -- Cierre 3: OrderRoutePlan (aislado por RouteNumber + Pais)
    -- ================================================
    RAISERROR('Cerrando OrderRoutePlan...', 0, 0) WITH NOWAIT;
    SET @retry = 0; SET @done = 0;
    WHILE @retry <= 3 AND @done = 0
    BEGIN
        BEGIN TRY
            UPDATE orp WITH (ROWLOCK)
            SET orp.Estado = 'Finalizado', orp.FechaFin = GETDATE()
            FROM dbo.OrderRoutePlan orp
            INNER JOIN (
                -- Las OVs marcadas No Despachada se excluyen: no bloquean el cierre.
                SELECT opt.RouteNumber, opt.Pais
                FROM dbo.OrderPickingTask opt WITH (NOLOCK)
                INNER JOIN dbo.OrderPickingManagement opm WITH (NOLOCK)
                        ON opm.ID_OrderPicking = opt.ID_OrderPicking
                WHERE EXISTS (SELECT 1 FROM #RoutesProcessed rp
                              WHERE rp.RouteNumber = opt.RouteNumber AND rp.Pais = opt.Pais)
                  AND opm.NoDespachada = 0
                GROUP BY opt.RouteNumber, opt.Pais
                HAVING SUM(ISNULL(opt.CantidadPendiente, 0)) = 0
            ) tareas ON tareas.RouteNumber = orp.RouteNumber AND tareas.Pais = orp.Pais
            WHERE orp.Estado <> 'Finalizado';
            SET @msg = 'OrderRoutePlan cerrados: ' + CONVERT(VARCHAR, @@ROWCOUNT);
            RAISERROR(@msg, 0, 0) WITH NOWAIT; SET @done = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() = 1222 AND @retry < 3
            BEGIN SET @retry += 1; WAITFOR DELAY '00:00:03'; END
            ELSE BEGIN
                SET @msg = 'Cierre ORP fallido: ' + ERROR_MESSAGE();
                RAISERROR(@msg, 0, 0) WITH NOWAIT; SET @done = 1;
            END
        END CATCH
    END

    -- ================================================
    -- Cierre 2b: reconciliación de líneas huérfanas.
    -- Si un PEDIDO ya está 'Finalizado', sus tareas que quedaron pendientes NO se
    -- van a pickear → se cierran (CantidadPendiente=0, Estado='Finalizado'). Así la
    -- ruta puede llegar al 100% y cerrar. Solo rutas activas (Iniciado).
    -- ================================================
    UPDATE t
    SET t.CantidadPendiente = 0, t.Estado = 'Finalizado', t.UltimaActualizacion = GETDATE()
    FROM dbo.OrderPickingTask t
    INNER JOIN dbo.OrderPickingManagement opm ON opm.ID_OrderPicking = t.ID_OrderPicking
    INNER JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
    WHERE orp.Estado = 'Iniciado'
      AND opm.Estado = 'Finalizado'
      AND (ISNULL(t.CantidadPendiente, 0) > 0 OR t.Estado <> 'Finalizado');
    SET @msg = 'Lineas huerfanas cerradas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    -- ================================================
    -- Cierre 4 (catch-all): cierra rutas 'Iniciado' que ya están 100% pero
    -- cuyas tareas NO estaban 'En Proceso' en esta corrida (p.ej. el picker
    -- las finalizó en la app) → nunca entraron a #RoutesProcessed y el Cierre 3
    -- no las evalúa. Independiente de #RoutesProcessed. FechaFin = último pick real.
    -- ================================================
    RAISERROR('Cierre catch-all OrderRoutePlan...', 0, 0) WITH NOWAIT;
    UPDATE orp
    SET orp.Estado = 'Finalizado',
        orp.FechaFin = ISNULL((
            SELECT MAX(t.UltimaActualizacion)
            FROM dbo.OrderPickingManagement opm
            INNER JOIN dbo.OrderPickingTask t ON t.ID_OrderPicking = opm.ID_OrderPicking
            WHERE opm.ID_RoutePlan = orp.ID_RoutePlan
        ), GETDATE())
    FROM dbo.OrderRoutePlan orp
    WHERE orp.Estado = 'Iniciado'
      AND EXISTS (
          SELECT 1 FROM dbo.OrderPickingManagement opm
          INNER JOIN dbo.OrderPickingTask t ON t.ID_OrderPicking = opm.ID_OrderPicking
          WHERE opm.ID_RoutePlan = orp.ID_RoutePlan)
      AND NOT EXISTS (
          SELECT 1 FROM dbo.OrderPickingManagement opm
          INNER JOIN dbo.OrderPickingTask t ON t.ID_OrderPicking = opm.ID_OrderPicking
          WHERE opm.ID_RoutePlan = orp.ID_RoutePlan
            AND opm.NoDespachada = 0
            AND ISNULL(t.CantidadPendiente, 0) > 0);
    SET @msg = 'Cierre catch-all cerrados: ' + CONVERT(VARCHAR, @@ROWCOUNT);
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    -- Renumerar prioridades de HUB Escuintla a 1..N contiguas en cada ciclo (cada 30s).
    -- Cierra los huecos cuando una ruta priorizada se completa/quita, sin depender del Node.
    EXEC dbo.SP_NormalizeEscuintlaPriorities;

    -- Auto-despacho HUB Escuintla: los cuadros con picking completo y PLACA
    -- asignada en SAP salen del tablero como Despachados (cada 30s).
    EXEC dbo.SP_AutoDespachoEscuintla;

    -- Limpiar huérfanos: cuadros activos cuyo cuadro en SAP ya no tiene líneas
    -- (borrado o vaciado) -> salen del tablero.
    EXEC dbo.SP_LimpiarHuerfanosEscuintla;

    IF OBJECT_ID('tempdb..#RoutesProcessed') IS NOT NULL DROP TABLE #RoutesProcessed;
    IF OBJECT_ID('tempdb..#SapCuadroDet') IS NOT NULL DROP TABLE #SapCuadroDet;
    IF OBJECT_ID('tempdb..#CuadrosLeidos') IS NOT NULL DROP TABLE #CuadrosLeidos;
    RAISERROR('SP completado.', 0, 0) WITH NOWAIT;
END;
GO
PRINT 'SyncLisa: lectura unica de cuadros SAP OK';
