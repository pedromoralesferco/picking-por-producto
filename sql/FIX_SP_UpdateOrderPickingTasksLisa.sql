-- ============================================================
-- FIX: SP_UpdateOrderPickingTasksLisa
-- BUG: Estaba leyendo de lisa_sboferco (GT) en vez de
--      lisa_sbointergres (SV) para las tareas de Order mode.
--
-- Cambios:
--   1. Bloque TR: lisa_sboferco → lisa_sbointergres
--   2. Bloque OV: lisa_sboferco → lisa_sbointergres
--   3. Bloque RMA: sboferco → sbointergres
-- ============================================================

ALTER PROCEDURE [dbo].[SP_UpdateOrderPickingTasksLisa]
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 5000;

    DECLARE @msg     VARCHAR(200);
    DECLARE @retry   INT;
    DECLARE @done    BIT;

    -- ================================================
    -- BLOQUE TR
    -- ================================================
    RAISERROR('TR [1/3] Leyendo OrderPickingTask...', 0, 0) WITH NOWAIT;

    IF OBJECT_ID('tempdb..#TareasTR')        IS NOT NULL DROP TABLE #TareasTR;
    IF OBJECT_ID('tempdb..#LineasTR')        IS NOT NULL DROP TABLE #LineasTR;
    IF OBJECT_ID('tempdb..#TareasOV')        IS NOT NULL DROP TABLE #TareasOV;
    IF OBJECT_ID('tempdb..#LineasOV')        IS NOT NULL DROP TABLE #LineasOV;
    IF OBJECT_ID('tempdb..#TareasRMA')       IS NOT NULL DROP TABLE #TareasRMA;
    IF OBJECT_ID('tempdb..#LineasRMA')       IS NOT NULL DROP TABLE #LineasRMA;
    IF OBJECT_ID('tempdb..#RoutesProcessed') IS NOT NULL DROP TABLE #RoutesProcessed;

    SELECT
        ID_Task, RouteNumber, IDCustomerOrder, Line_ID, DocType, CantidadPendiente
    INTO #TareasTR
    FROM dbo.OrderPickingTask WITH (NOLOCK)
    WHERE Estado = 'En Proceso' AND DocType = 'TR';

    SET @msg = 'TR [1/3] Completado. Filas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    CREATE CLUSTERED INDEX IX_TareasTR ON #TareasTR(IDCustomerOrder, Line_ID);

    CREATE TABLE #LineasTR (
        IdTransferRequest INT,
        IDLine            INT,
        QtyToPick         NUMERIC(18, 6)
    );

    IF EXISTS (SELECT 1 FROM #TareasTR)
    BEGIN
        DECLARE @IDListTR NVARCHAR(MAX);
        SELECT @IDListTR = STUFF((
            SELECT DISTINCT N',' + CONVERT(NVARCHAR(50), IDCustomerOrder)
            FROM #TareasTR
            FOR XML PATH(N'')
        ), 1, 1, N'');

        SET @msg = 'TR [2/3] OPENQUERY... IDs: '
                   + CONVERT(VARCHAR, (SELECT COUNT(DISTINCT IDCustomerOrder) FROM #TareasTR));
        RAISERROR(@msg, 0, 0) WITH NOWAIT;

        DECLARE @sqlTR NVARCHAR(MAX);
        SET @sqlTR = N'
            SELECT IdTransferRequest, IDLine, QtyToPick
            FROM OPENQUERY([server-sql],
                ''SELECT IdTransferRequest, IDLine, QtyToPick
                  FROM lisa_sbointergres.dbo.TransferRequestLines WITH (NOLOCK)
                  WHERE IdTransferRequest IN (' + @IDListTR + N')
                '');';
        -- ^^^^ FIX: era lisa_sboferco, ahora lisa_sbointergres

        INSERT INTO #LineasTR (IdTransferRequest, IDLine, QtyToPick)
        EXEC sp_executesql @sqlTR;

        SET @msg = 'TR [2/3] OPENQUERY OK. Lineas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
        RAISERROR(@msg, 0, 0) WITH NOWAIT;

        SET @retry = 0; SET @done = 0;
        WHILE @retry <= 3 AND @done = 0
        BEGIN
            BEGIN TRY
                SET @msg = 'TR [3/3] UPDATE (intento ' + CONVERT(VARCHAR, @retry + 1) + '/3)...';
                RAISERROR(@msg, 0, 0) WITH NOWAIT;

                UPDATE t0 WITH (ROWLOCK)
                SET
                    t0.CantidadPendiente   = t1.QtyToPick,
                    t0.UltimaActualizacion = GETDATE()
                FROM dbo.OrderPickingTask t0
                INNER JOIN #TareasTR tmp
                    ON  tmp.ID_Task = t0.ID_Task
                INNER JOIN #LineasTR t1
                    ON  t1.IdTransferRequest = CONVERT(INT, tmp.IDCustomerOrder)
                    AND t1.IDLine            = tmp.Line_ID
                WHERE ISNULL(t0.CantidadPendiente, -1) <> ISNULL(t1.QtyToPick, -1);

                SET @msg = 'TR [3/3] UPDATE OK. Filas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
                RAISERROR(@msg, 0, 0) WITH NOWAIT;
                SET @done = 1;
            END TRY
            BEGIN CATCH
                IF ERROR_NUMBER() = 1222 AND @retry < 3
                BEGIN
                    SET @retry += 1;
                    SET @msg = 'TR bloqueado, esperando 3s para reintento '
                               + CONVERT(VARCHAR, @retry) + '/3...';
                    RAISERROR(@msg, 0, 0) WITH NOWAIT;
                    WAITFOR DELAY '00:00:03';
                END
                ELSE
                BEGIN
                    SET @msg = 'TR UPDATE fallido tras reintentos: ' + ERROR_MESSAGE();
                    RAISERROR(@msg, 0, 0) WITH NOWAIT;
                    SET @done = 1;
                END
            END CATCH
        END
    END
    ELSE
        RAISERROR('TR: Sin tareas activas.', 0, 0) WITH NOWAIT;

    -- ================================================
    -- BLOQUE OV
    -- ================================================
    RAISERROR('OV [1/3] Leyendo OrderPickingTask...', 0, 0) WITH NOWAIT;

    SELECT
        ID_Task, RouteNumber, IDCustomerOrder, Line_ID, DocType, CantidadPendiente
    INTO #TareasOV
    FROM dbo.OrderPickingTask WITH (NOLOCK)
    WHERE Estado = 'En Proceso' AND DocType = 'OV';

    SET @msg = 'OV [1/3] Completado. Filas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    CREATE CLUSTERED INDEX IX_TareasOV ON #TareasOV(IDCustomerOrder, Line_ID);

    CREATE TABLE #LineasOV (
        IdCustomerOrder INT,
        IDLine          INT,
        ToPick          NUMERIC(18, 6)
    );

    IF EXISTS (SELECT 1 FROM #TareasOV)
    BEGIN
        DECLARE @IDListOV NVARCHAR(MAX);
        SELECT @IDListOV = STUFF((
            SELECT DISTINCT N',' + CONVERT(NVARCHAR(50), IDCustomerOrder)
            FROM #TareasOV
            FOR XML PATH(N'')
        ), 1, 1, N'');

        SET @msg = 'OV [2/3] OPENQUERY... IDs: '
                   + CONVERT(VARCHAR, (SELECT COUNT(DISTINCT IDCustomerOrder) FROM #TareasOV));
        RAISERROR(@msg, 0, 0) WITH NOWAIT;

        DECLARE @sqlOV NVARCHAR(MAX);
        SET @sqlOV = N'
            SELECT IdCustomerOrder, IDLine, ToPick
            FROM OPENQUERY([server-sql],
                ''SELECT IdCustomerOrder, IDLine, ToPick
                  FROM lisa_sbointergres.dbo.CustomerOrderLine WITH (NOLOCK)
                  WHERE IdCustomerOrder IN (' + @IDListOV + N')
                '');';
        -- ^^^^ FIX: era lisa_sboferco, ahora lisa_sbointergres

        INSERT INTO #LineasOV (IdCustomerOrder, IDLine, ToPick)
        EXEC sp_executesql @sqlOV;

        SET @msg = 'OV [2/3] OPENQUERY OK. Lineas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
        RAISERROR(@msg, 0, 0) WITH NOWAIT;

        SET @retry = 0; SET @done = 0;
        WHILE @retry <= 3 AND @done = 0
        BEGIN
            BEGIN TRY
                SET @msg = 'OV [3/3] UPDATE (intento ' + CONVERT(VARCHAR, @retry + 1) + '/3)...';
                RAISERROR(@msg, 0, 0) WITH NOWAIT;

                UPDATE t0 WITH (ROWLOCK)
                SET
                    t0.CantidadPendiente   = t1.ToPick,
                    t0.UltimaActualizacion = GETDATE()
                FROM dbo.OrderPickingTask t0
                INNER JOIN #TareasOV tmp
                    ON  tmp.ID_Task = t0.ID_Task
                INNER JOIN #LineasOV t1
                    ON  t1.IdCustomerOrder = CONVERT(INT, tmp.IDCustomerOrder)
                    AND t1.IDLine          = tmp.Line_ID
                WHERE ISNULL(t0.CantidadPendiente, -1) <> ISNULL(t1.ToPick, -1);

                SET @msg = 'OV [3/3] UPDATE OK. Filas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
                RAISERROR(@msg, 0, 0) WITH NOWAIT;
                SET @done = 1;
            END TRY
            BEGIN CATCH
                IF ERROR_NUMBER() = 1222 AND @retry < 3
                BEGIN
                    SET @retry += 1;
                    SET @msg = 'OV bloqueado, esperando 3s para reintento '
                               + CONVERT(VARCHAR, @retry) + '/3...';
                    RAISERROR(@msg, 0, 0) WITH NOWAIT;
                    WAITFOR DELAY '00:00:03';
                END
                ELSE
                BEGIN
                    SET @msg = 'OV UPDATE fallido tras reintentos: ' + ERROR_MESSAGE();
                    RAISERROR(@msg, 0, 0) WITH NOWAIT;
                    SET @done = 1;
                END
            END CATCH
        END
    END
    ELSE
        RAISERROR('OV: Sin tareas activas.', 0, 0) WITH NOWAIT;

    -- ================================================
    -- BLOQUE RMA
    -- Actualiza CantidadPendiente desde NWR_RMASTATUS.OpenQty
    -- ================================================
    RAISERROR('RMA [1/3] Leyendo OrderPickingTask...', 0, 0) WITH NOWAIT;

    SELECT
        ID_Task, RouteNumber, IDCustomerOrder, Line_ID, DocType, CantidadPendiente
    INTO #TareasRMA
    FROM dbo.OrderPickingTask WITH (NOLOCK)
    WHERE Estado = 'En Proceso' AND DocType = 'RMA';

    SET @msg = 'RMA [1/3] Completado. Filas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    CREATE CLUSTERED INDEX IX_TareasRMA ON #TareasRMA(IDCustomerOrder, Line_ID);

    CREATE TABLE #LineasRMA (
        CallID   INT,
        LineNum  INT,
        OpenQty  NUMERIC(18, 6)
    );

    IF EXISTS (SELECT 1 FROM #TareasRMA)
    BEGIN
        DECLARE @IDListRMA NVARCHAR(MAX);
        SELECT @IDListRMA = STUFF((
            SELECT DISTINCT N',' + CONVERT(NVARCHAR(50), IDCustomerOrder)
            FROM #TareasRMA
            FOR XML PATH(N'')
        ), 1, 1, N'');

        SET @msg = 'RMA [2/3] OPENQUERY... IDs: '
                   + CONVERT(VARCHAR, (SELECT COUNT(DISTINCT IDCustomerOrder) FROM #TareasRMA));
        RAISERROR(@msg, 0, 0) WITH NOWAIT;

        DECLARE @sqlRMA NVARCHAR(MAX);
        SET @sqlRMA = N'
            SELECT CallID, LineNum, OpenQty
            FROM OPENQUERY([server-sql],
                ''SELECT CallID, LineNum, OpenQty
                  FROM sbointergres.dbo.NWR_RMASTATUS WITH (NOLOCK)
                  WHERE CallID IN (' + @IDListRMA + N')
                '');';
        -- ^^^^ FIX: era sboferco, ahora sbointergres

        INSERT INTO #LineasRMA (CallID, LineNum, OpenQty)
        EXEC sp_executesql @sqlRMA;

        SET @msg = 'RMA [2/3] OPENQUERY OK. Lineas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
        RAISERROR(@msg, 0, 0) WITH NOWAIT;

        SET @retry = 0; SET @done = 0;
        WHILE @retry <= 3 AND @done = 0
        BEGIN
            BEGIN TRY
                SET @msg = 'RMA [3/3] UPDATE (intento ' + CONVERT(VARCHAR, @retry + 1) + '/3)...';
                RAISERROR(@msg, 0, 0) WITH NOWAIT;

                UPDATE t0 WITH (ROWLOCK)
                SET
                    t0.CantidadPendiente   = t1.OpenQty,
                    t0.UltimaActualizacion = GETDATE()
                FROM dbo.OrderPickingTask t0
                INNER JOIN #TareasRMA tmp
                    ON  tmp.ID_Task = t0.ID_Task
                INNER JOIN #LineasRMA t1
                    ON  t1.CallID  = CONVERT(INT, tmp.IDCustomerOrder)
                    AND t1.LineNum = tmp.Line_ID
                WHERE ISNULL(t0.CantidadPendiente, -1) <> ISNULL(t1.OpenQty, -1);

                SET @msg = 'RMA [3/3] UPDATE OK. Filas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
                RAISERROR(@msg, 0, 0) WITH NOWAIT;
                SET @done = 1;
            END TRY
            BEGIN CATCH
                IF ERROR_NUMBER() = 1222 AND @retry < 3
                BEGIN
                    SET @retry += 1;
                    SET @msg = 'RMA bloqueado, esperando 3s para reintento '
                               + CONVERT(VARCHAR, @retry) + '/3...';
                    RAISERROR(@msg, 0, 0) WITH NOWAIT;
                    WAITFOR DELAY '00:00:03';
                END
                ELSE
                BEGIN
                    SET @msg = 'RMA UPDATE fallido tras reintentos: ' + ERROR_MESSAGE();
                    RAISERROR(@msg, 0, 0) WITH NOWAIT;
                    SET @done = 1;
                END
            END CATCH
        END
    END
    ELSE
        RAISERROR('RMA: Sin tareas activas.', 0, 0) WITH NOWAIT;

    -- ================================================
    -- Rutas procesadas (scope para cierres)
    -- ================================================
    SELECT DISTINCT RouteNumber INTO #RoutesProcessed FROM #TareasTR
    UNION
    SELECT DISTINCT RouteNumber FROM #TareasOV
    UNION
    SELECT DISTINCT RouteNumber FROM #TareasRMA;

    -- ================================================
    -- Cierre 1: OrderPickingTask con CantidadPendiente = 0
    -- ================================================
    RAISERROR('Cerrando tareas finalizadas...', 0, 0) WITH NOWAIT;

    SET @retry = 0; SET @done = 0;
    WHILE @retry <= 3 AND @done = 0
    BEGIN
        BEGIN TRY
            UPDATE dbo.OrderPickingTask WITH (ROWLOCK)
            SET
                Estado              = 'Finalizado',
                UltimaActualizacion = GETDATE()
            WHERE ISNULL(CantidadPendiente, 0) = 0
              AND Estado <> 'Finalizado'
              AND RouteNumber IN (SELECT RouteNumber FROM #RoutesProcessed);

            SET @msg = 'Tareas cerradas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
            RAISERROR(@msg, 0, 0) WITH NOWAIT;
            SET @done = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() = 1222 AND @retry < 3
            BEGIN
                SET @retry += 1;
                SET @msg = 'Cierre tareas bloqueado, reintento ' + CONVERT(VARCHAR, @retry) + '/3...';
                RAISERROR(@msg, 0, 0) WITH NOWAIT;
                WAITFOR DELAY '00:00:03';
            END
            ELSE
            BEGIN
                SET @msg = 'Cierre tareas fallido: ' + ERROR_MESSAGE();
                RAISERROR(@msg, 0, 0) WITH NOWAIT;
                SET @done = 1;
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
            ;WITH PendientePedido AS
            (
                SELECT
                    ID_OrderPicking,
                    SUM(ISNULL(CantidadPendiente, 0)) AS CantidadPendiente
                FROM dbo.OrderPickingTask WITH (NOLOCK)
                WHERE Estado <> 'Pendiente'
                  AND RouteNumber IN (SELECT RouteNumber FROM #RoutesProcessed)
                GROUP BY ID_OrderPicking
            )
            UPDATE opm WITH (ROWLOCK)
            SET opm.Estado = 'Finalizado', opm.FechaFin = GETDATE()
            FROM dbo.OrderPickingManagement opm
            INNER JOIN PendientePedido pp
                ON pp.ID_OrderPicking = opm.ID_OrderPicking
            WHERE pp.CantidadPendiente = 0
              AND ISNULL(opm.Estado, '') <> 'Finalizado';

            SET @msg = 'OrderPickingManagement cerrados: ' + CONVERT(VARCHAR, @@ROWCOUNT);
            RAISERROR(@msg, 0, 0) WITH NOWAIT;
            SET @done = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() = 1222 AND @retry < 3
            BEGIN
                SET @retry += 1;
                SET @msg = 'Cierre OPM bloqueado, reintento ' + CONVERT(VARCHAR, @retry) + '/3...';
                RAISERROR(@msg, 0, 0) WITH NOWAIT;
                WAITFOR DELAY '00:00:03';
            END
            ELSE
            BEGIN
                SET @msg = 'Cierre OPM fallido: ' + ERROR_MESSAGE();
                RAISERROR(@msg, 0, 0) WITH NOWAIT;
                SET @done = 1;
            END
        END CATCH
    END

    -- ================================================
    -- Cierre 3: OrderRoutePlan
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
                SELECT RouteNumber
                FROM dbo.OrderPickingTask WITH (NOLOCK)
                WHERE RouteNumber IN (SELECT RouteNumber FROM #RoutesProcessed)
                GROUP BY RouteNumber
                HAVING SUM(ISNULL(CantidadPendiente, 0)) = 0
            ) tareas ON tareas.RouteNumber = orp.RouteNumber
            WHERE orp.Estado <> 'Finalizado';

            SET @msg = 'OrderRoutePlan cerrados: ' + CONVERT(VARCHAR, @@ROWCOUNT);
            RAISERROR(@msg, 0, 0) WITH NOWAIT;
            SET @done = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() = 1222 AND @retry < 3
            BEGIN
                SET @retry += 1;
                SET @msg = 'Cierre ORP bloqueado, reintento ' + CONVERT(VARCHAR, @retry) + '/3...';
                RAISERROR(@msg, 0, 0) WITH NOWAIT;
                WAITFOR DELAY '00:00:03';
            END
            ELSE
            BEGIN
                SET @msg = 'Cierre ORP fallido: ' + ERROR_MESSAGE();
                RAISERROR(@msg, 0, 0) WITH NOWAIT;
                SET @done = 1;
            END
        END CATCH
    END

    RAISERROR('SP completado.', 0, 0) WITH NOWAIT;
END;
GO
