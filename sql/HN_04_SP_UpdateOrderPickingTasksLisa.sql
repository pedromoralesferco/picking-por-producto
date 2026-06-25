-- ============================================================
-- Honduras (HN) — Paso 4: Refresco de cantidades país-aware
--
-- La versión vigente de SP_UpdateOrderPickingTasksLisa está
-- HARDCODEADA a SV (lisa_sbointergres / sbointergres) y no
-- filtra por país, por lo que no sirve para HN.
--
-- Esta versión:
--   1. Crea un sub-SP SP_UpdateOrderPickingLisa_PorPais que hace
--      el refresco (TR / OV / RMA) para UN país, con el nombre de
--      base Lisa/SAP como parámetro.
--   2. Reescribe SP_UpdateOrderPickingTasksLisa para llamarlo por
--      cada país en modalidad order (SV, HN) y luego cerrar.
--   3. El cierre ahora aísla por (RouteNumber + Pais) para evitar
--      colisiones de número de ruta entre países.
--
-- Para agregar otro país, basta con un EXEC adicional al final.
-- ============================================================

-- ════════════════════════════════════════════════════════════
-- SUB-PROCEDIMIENTO: refresco de un país
-- ════════════════════════════════════════════════════════════
IF OBJECT_ID('dbo.SP_UpdateOrderPickingLisa_PorPais') IS NOT NULL
    DROP PROCEDURE dbo.SP_UpdateOrderPickingLisa_PorPais;
GO
CREATE PROCEDURE [dbo].[SP_UpdateOrderPickingLisa_PorPais]
    @Pais   NVARCHAR(10),
    @LisaDb SYSNAME,
    @SapDb  SYSNAME
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 5000;

    DECLARE @msg VARCHAR(200), @retry INT, @done BIT;

    IF OBJECT_ID('tempdb..#TareasTR')  IS NOT NULL DROP TABLE #TareasTR;
    IF OBJECT_ID('tempdb..#LineasTR')  IS NOT NULL DROP TABLE #LineasTR;
    IF OBJECT_ID('tempdb..#TareasOV')  IS NOT NULL DROP TABLE #TareasOV;
    IF OBJECT_ID('tempdb..#LineasOV')  IS NOT NULL DROP TABLE #LineasOV;
    IF OBJECT_ID('tempdb..#TareasRMA') IS NOT NULL DROP TABLE #TareasRMA;
    IF OBJECT_ID('tempdb..#LineasRMA') IS NOT NULL DROP TABLE #LineasRMA;

    -- ================================================
    -- BLOQUE TR
    -- ================================================
    SET @msg = '[' + @Pais + '] TR [1/3] Leyendo OrderPickingTask...';
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    SELECT ID_Task, RouteNumber, IDCustomerOrder, Line_ID, DocType, CantidadPendiente
    INTO #TareasTR
    FROM dbo.OrderPickingTask WITH (NOLOCK)
    WHERE Estado = 'En Proceso' AND DocType = 'TR' AND Pais = @Pais;

    SET @msg = '[' + @Pais + '] TR [1/3] Filas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    CREATE CLUSTERED INDEX IX_TareasTR ON #TareasTR(IDCustomerOrder, Line_ID);
    CREATE TABLE #LineasTR (IdTransferRequest INT, IDLine INT, QtyToPick NUMERIC(18,6));

    IF EXISTS (SELECT 1 FROM #TareasTR)
    BEGIN
        DECLARE @IDListTR NVARCHAR(MAX);
        SELECT @IDListTR = STUFF((
            SELECT DISTINCT N',' + CONVERT(NVARCHAR(50), IDCustomerOrder)
            FROM #TareasTR FOR XML PATH(N'')), 1, 1, N'');

        DECLARE @sqlTR NVARCHAR(MAX);
        SET @sqlTR = N'
            SELECT IdTransferRequest, IDLine, QtyToPick
            FROM OPENQUERY([server-sql],
                ''SELECT IdTransferRequest, IDLine, QtyToPick
                  FROM ' + @LisaDb + N'.dbo.TransferRequestLines WITH (NOLOCK)
                  WHERE IdTransferRequest IN (' + @IDListTR + N')'');';

        INSERT INTO #LineasTR (IdTransferRequest, IDLine, QtyToPick)
        EXEC sp_executesql @sqlTR;

        SET @retry = 0; SET @done = 0;
        WHILE @retry <= 3 AND @done = 0
        BEGIN
            BEGIN TRY
                UPDATE t0 WITH (ROWLOCK)
                SET t0.CantidadPendiente = t1.QtyToPick, t0.UltimaActualizacion = GETDATE()
                FROM dbo.OrderPickingTask t0
                INNER JOIN #TareasTR tmp ON tmp.ID_Task = t0.ID_Task
                INNER JOIN #LineasTR t1
                    ON t1.IdTransferRequest = CONVERT(INT, tmp.IDCustomerOrder)
                    AND t1.IDLine = tmp.Line_ID
                WHERE ISNULL(t0.CantidadPendiente, -1) <> ISNULL(t1.QtyToPick, -1);
                SET @done = 1;
            END TRY
            BEGIN CATCH
                IF ERROR_NUMBER() = 1222 AND @retry < 3
                BEGIN SET @retry += 1; WAITFOR DELAY '00:00:03'; END
                ELSE BEGIN
                    SET @msg = '[' + @Pais + '] TR UPDATE fallido: ' + ERROR_MESSAGE();
                    RAISERROR(@msg, 0, 0) WITH NOWAIT; SET @done = 1;
                END
            END CATCH
        END
    END

    -- ================================================
    -- BLOQUE OV
    -- ================================================
    SET @msg = '[' + @Pais + '] OV [1/3] Leyendo OrderPickingTask...';
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    SELECT ID_Task, RouteNumber, IDCustomerOrder, Line_ID, DocType, CantidadPendiente
    INTO #TareasOV
    FROM dbo.OrderPickingTask WITH (NOLOCK)
    WHERE Estado = 'En Proceso' AND DocType = 'OV' AND Pais = @Pais;

    SET @msg = '[' + @Pais + '] OV [1/3] Filas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    CREATE CLUSTERED INDEX IX_TareasOV ON #TareasOV(IDCustomerOrder, Line_ID);
    CREATE TABLE #LineasOV (IdCustomerOrder INT, IDLine INT, ToPick NUMERIC(18,6));

    IF EXISTS (SELECT 1 FROM #TareasOV)
    BEGIN
        DECLARE @IDListOV NVARCHAR(MAX);
        SELECT @IDListOV = STUFF((
            SELECT DISTINCT N',' + CONVERT(NVARCHAR(50), IDCustomerOrder)
            FROM #TareasOV FOR XML PATH(N'')), 1, 1, N'');

        DECLARE @sqlOV NVARCHAR(MAX);
        SET @sqlOV = N'
            SELECT IdCustomerOrder, IDLine, ToPick
            FROM OPENQUERY([server-sql],
                ''SELECT IdCustomerOrder, IDLine, ToPick
                  FROM ' + @LisaDb + N'.dbo.CustomerOrderLine WITH (NOLOCK)
                  WHERE IdCustomerOrder IN (' + @IDListOV + N')'');';

        INSERT INTO #LineasOV (IdCustomerOrder, IDLine, ToPick)
        EXEC sp_executesql @sqlOV;

        SET @retry = 0; SET @done = 0;
        WHILE @retry <= 3 AND @done = 0
        BEGIN
            BEGIN TRY
                UPDATE t0 WITH (ROWLOCK)
                SET t0.CantidadPendiente = t1.ToPick, t0.UltimaActualizacion = GETDATE()
                FROM dbo.OrderPickingTask t0
                INNER JOIN #TareasOV tmp ON tmp.ID_Task = t0.ID_Task
                INNER JOIN #LineasOV t1
                    ON t1.IdCustomerOrder = CONVERT(INT, tmp.IDCustomerOrder)
                    AND t1.IDLine = tmp.Line_ID
                WHERE ISNULL(t0.CantidadPendiente, -1) <> ISNULL(t1.ToPick, -1);
                SET @done = 1;
            END TRY
            BEGIN CATCH
                IF ERROR_NUMBER() = 1222 AND @retry < 3
                BEGIN SET @retry += 1; WAITFOR DELAY '00:00:03'; END
                ELSE BEGIN
                    SET @msg = '[' + @Pais + '] OV UPDATE fallido: ' + ERROR_MESSAGE();
                    RAISERROR(@msg, 0, 0) WITH NOWAIT; SET @done = 1;
                END
            END CATCH
        END
    END

    -- ================================================
    -- BLOQUE RMA (desde NWR_RMASTATUS en la base SAP)
    -- ================================================
    SET @msg = '[' + @Pais + '] RMA [1/3] Leyendo OrderPickingTask...';
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    SELECT ID_Task, RouteNumber, IDCustomerOrder, Line_ID, DocType, CantidadPendiente
    INTO #TareasRMA
    FROM dbo.OrderPickingTask WITH (NOLOCK)
    WHERE Estado = 'En Proceso' AND DocType = 'RMA' AND Pais = @Pais;

    SET @msg = '[' + @Pais + '] RMA [1/3] Filas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    CREATE CLUSTERED INDEX IX_TareasRMA ON #TareasRMA(IDCustomerOrder, Line_ID);
    CREATE TABLE #LineasRMA (CallID INT, LineNum INT, OpenQty NUMERIC(18,6));

    IF EXISTS (SELECT 1 FROM #TareasRMA)
    BEGIN
        DECLARE @IDListRMA NVARCHAR(MAX);
        SELECT @IDListRMA = STUFF((
            SELECT DISTINCT N',' + CONVERT(NVARCHAR(50), IDCustomerOrder)
            FROM #TareasRMA FOR XML PATH(N'')), 1, 1, N'');

        DECLARE @sqlRMA NVARCHAR(MAX);
        SET @sqlRMA = N'
            SELECT CallID, LineNum, OpenQty
            FROM OPENQUERY([server-sql],
                ''SELECT CallID, LineNum, OpenQty
                  FROM ' + @SapDb + N'.dbo.NWR_RMASTATUS WITH (NOLOCK)
                  WHERE CallID IN (' + @IDListRMA + N')'');';

        INSERT INTO #LineasRMA (CallID, LineNum, OpenQty)
        EXEC sp_executesql @sqlRMA;

        SET @retry = 0; SET @done = 0;
        WHILE @retry <= 3 AND @done = 0
        BEGIN
            BEGIN TRY
                UPDATE t0 WITH (ROWLOCK)
                SET t0.CantidadPendiente = t1.OpenQty, t0.UltimaActualizacion = GETDATE()
                FROM dbo.OrderPickingTask t0
                INNER JOIN #TareasRMA tmp ON tmp.ID_Task = t0.ID_Task
                INNER JOIN #LineasRMA t1
                    ON t1.CallID = CONVERT(INT, tmp.IDCustomerOrder)
                    AND t1.LineNum = tmp.Line_ID
                WHERE ISNULL(t0.CantidadPendiente, -1) <> ISNULL(t1.OpenQty, -1);
                SET @done = 1;
            END TRY
            BEGIN CATCH
                IF ERROR_NUMBER() = 1222 AND @retry < 3
                BEGIN SET @retry += 1; WAITFOR DELAY '00:00:03'; END
                ELSE BEGIN
                    SET @msg = '[' + @Pais + '] RMA UPDATE fallido: ' + ERROR_MESSAGE();
                    RAISERROR(@msg, 0, 0) WITH NOWAIT; SET @done = 1;
                END
            END CATCH
        END
    END

    -- ================================================
    -- Acumular rutas procesadas (si el SP padre creó #RoutesProcessed)
    -- ================================================
    IF OBJECT_ID('tempdb..#RoutesProcessed') IS NOT NULL
    BEGIN
        INSERT INTO #RoutesProcessed (RouteNumber, Pais)
        SELECT DISTINCT RouteNumber, @Pais FROM #TareasTR
        UNION SELECT DISTINCT RouteNumber, @Pais FROM #TareasOV
        UNION SELECT DISTINCT RouteNumber, @Pais FROM #TareasRMA;
    END
END;
GO

-- ════════════════════════════════════════════════════════════
-- SP PRINCIPAL: orquesta el refresco por país + cierres
-- ════════════════════════════════════════════════════════════
ALTER PROCEDURE [dbo].[SP_UpdateOrderPickingTasksLisa]
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 5000;

    DECLARE @msg VARCHAR(200), @retry INT, @done BIT;

    IF OBJECT_ID('tempdb..#RoutesProcessed') IS NOT NULL DROP TABLE #RoutesProcessed;
    CREATE TABLE #RoutesProcessed (RouteNumber INT, Pais NVARCHAR(10));

    -- ── Refresco por país (modalidad order). Agregar países aquí. ──
    EXEC dbo.SP_UpdateOrderPickingLisa_PorPais @Pais = 'SV', @LisaDb = 'lisa_sbointergres', @SapDb = 'sbointergres';
    EXEC dbo.SP_UpdateOrderPickingLisa_PorPais @Pais = 'HN', @LisaDb = 'lisa_sbopym',       @SapDb = 'sbopym';

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
                SELECT opt.RouteNumber, opt.Pais
                FROM dbo.OrderPickingTask opt WITH (NOLOCK)
                WHERE EXISTS (SELECT 1 FROM #RoutesProcessed rp
                              WHERE rp.RouteNumber = opt.RouteNumber AND rp.Pais = opt.Pais)
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

    IF OBJECT_ID('tempdb..#RoutesProcessed') IS NOT NULL DROP TABLE #RoutesProcessed;
    RAISERROR('SP completado.', 0, 0) WITH NOWAIT;
END;
GO
