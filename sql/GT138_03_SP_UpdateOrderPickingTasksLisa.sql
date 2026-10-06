-- ============================================================
-- SP_UpdateOrderPickingTasksLisa — agrega GT (Escuintla/138) al loop.
-- Supersede el SP principal de sql/HN_04 (el sub-SP
-- SP_UpdateOrderPickingLisa_PorPais NO cambia).
-- GT refresca tareas order con Pais='GT' desde lisa_sboferco/sboferco
-- (solo aplica a 138; Zona 5 es producto y vive en otras tablas).
-- ============================================================
ALTER PROCEDURE [dbo].[SP_UpdateOrderPickingTasksLisa]
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
    RAISERROR('SP completado.', 0, 0) WITH NOWAIT;
END;
GO
