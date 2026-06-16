-- ============================================================
-- RMA INTEGRATION - ALL STORED PROCEDURES
-- Picking_Management database
-- Ejecutar en orden: 1, 2, 3, 4
-- ============================================================

-- ============================================================
-- 1. ALTER AddRouteTask
--    Agrega bloque RMA al UNION ALL para crear tareas de picking
--    cuando un cuadro de ruta contiene documentos tipo 'RMA'
-- ============================================================
ALTER PROCEDURE [dbo].[AddRouteTask]
    @RouteNumber INT
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#tmpPickRouteStatus') IS NOT NULL
        DROP TABLE #tmpPickRouteStatus;

    -- ── OV Block ──
    SELECT
        t0.DocNum    [RouteNumber],
        t0.U_NombreR [RouteName],
        t1.U_No_Ov   [DocNum],
        t1.U_Tipo_Documento [DocType],
        t2.IdCustomerOrder,
        t2.IdAccountableOrder,
        t3.IdLine,
        t3.IdProduct,
        t4.InternIdProduct,
        t4.ProductName,
        t3.QtyOrdered,
        t3.Picked,
        t3.ToPick,
        t3.LineStatus,
        t4.UnitMass  [UnitWeight]
    INTO #tmpPickRouteStatus
    FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] t0 WITH (NOLOCK)
    LEFT JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
    LEFT JOIN [server-sql].lisa_sboferco.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_ov
    LEFT JOIN [server-sql].lisa_sboferco.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
    LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] t4 WITH (NOLOCK) ON t4.idProduct = t3.IdProduct
    WHERE t0.DocNum = @RouteNumber
      AND t1.U_Tipo_Documento = 'OV'
      AND t4.InternIdProduct <> '013956'

    UNION ALL

    -- ── TR Block ──
    SELECT
        t0.DocNum    [RouteNumber],
        t0.U_NombreR [RouteName],
        t1.U_No_Ov   [DocNum],
        t1.U_Tipo_Documento [DocType],
        t2.IdTransferRequest,
        t2.DocNum,
        t3.IdLine,
        t3.IdProduct,
        t4.InternIdProduct,
        t4.ProductName,
        t3.QtyToTransfer,
        t3.QtyPicked,
        t3.QtyToPick,
        t3.LineStatus,
        t4.UnitMass  [UnitWeight]
    FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] t0 WITH (NOLOCK)
    LEFT JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
    LEFT JOIN [server-sql].lisa_sboferco.dbo.TransferRequest t2 WITH (NOLOCK) ON t2.DocNum = t1.U_No_OV
    LEFT JOIN [server-sql].lisa_sboferco.dbo.TransferRequestLines t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
    LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] t4 WITH (NOLOCK) ON t4.idProduct = t3.IdProduct
    WHERE t0.DocNum = @RouteNumber
      AND t1.U_Tipo_Documento IN ('TR','RESURTIDO')

    UNION ALL

    -- ── RMA Block (NUEVO) ──
    SELECT
        t0.DocNum    [RouteNumber],
        t0.U_NombreR [RouteName],
        t1.U_No_Ov   [DocNum],
        'RMA'         [DocType],
        rma.CallID    AS IdCustomerOrder,
        CAST(rma.CallID AS INT) AS IdAccountableOrder,
        rma.LineNum   AS IdLine,
        p.IdProduct,
        rma.ItemCode  AS InternIdProduct,
        p.ProductName,
        rma.RMAQty    AS QtyOrdered,
        (rma.RMAQty - rma.OpenQty) AS Picked,
        rma.OpenQty   AS ToPick,
        rma.[Status]  AS LineStatus,
        ISNULL(p.UnitMass, 0) AS [UnitWeight]
    FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] t0 WITH (NOLOCK)
    LEFT JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
    LEFT JOIN [server-sql].sboferco.dbo.NWR_RMASTATUS rma WITH (NOLOCK)
        ON rma.CallID = CAST(t1.U_No_OV AS INT)
        AND rma.[Status] = 'O'
    LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] p WITH (NOLOCK)
        ON p.InternIdProduct = rma.ItemCode
    WHERE t0.DocNum = @RouteNumber
      AND t1.U_Tipo_Documento = 'RMA'
      AND rma.ItemCode IS NOT NULL;

    -- Creacion de tareas de cabecera en Route picking Management
    INSERT INTO RoutePickingManagement (
        [RouteNumber],
        [RouteName],
        [Product],
        [ProductName],
        [TotalArticulo],
        [PesoTotal]
    )
    SELECT
        RouteNumber,
        RouteName,
        InternIdProduct,
        ProductName,
        SUM(QtyOrdered)              [Quantity],
        SUM(QtyOrdered * UnitWeight) [TotalWeight]
    FROM #tmpPickRouteStatus
    GROUP BY RouteNumber, RouteName, InternIdProduct, ProductName;

    -- Creacion de tareas de detalle para TaskManagement
    INSERT INTO RoutePickingTask (
        [Route_Number],
        [OV_Number],
        [DocType],
        [IDCustomerORder],
        [IdAccountableOrder],
        [Line_ID],
        [IdProduct],
        [InternIdProduct],
        [Descripcion],
        [Cantidad],
        [CantidadPendiente],
        [UnitWeight],
        [FechaLiberacion]
    )
    SELECT
        RouteNumber,
        DocNum,
        DocType,
        IdCustomerOrder,
        IdAccountableOrder,
        IdLine,
        IdProduct,
        InternIdProduct,
        ProductName,
        QtyOrdered,
        ToPick,
        UnitWeight,
        GETDATE()
    FROM #tmpPickRouteStatus;
END;
GO


-- ============================================================
-- 2. ALTER RP_DetectaNuevasRutas
--    Agrega peso estimado de RMA al calculo de PesoEstimado
-- ============================================================
ALTER PROCEDURE [dbo].[RP_DetectaNuevasRutas] AS

INSERT INTO dbo.RoutePlan
(
    [RouteNumber],
    [RouteName],
    FechaPlanificacion,
    AlmacenOrigen,
    PesoEstimado
)
SELECT
    src.DocNum,
    src.U_NombreR,
    GETDATE() AS FechaPlanificacion,
    src.U_Almacen_Origen,
    ISNULL(peso.PesoEstimado, 0)
FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] AS src
LEFT JOIN (
    SELECT DocNum, SUM(PesoEstimado) AS PesoEstimado
    FROM (
        -- Peso de OVs
        SELECT t0.DocNum, SUM(t3.QtyOrdered * ISNULL(t4.UnitMass, 0)) AS PesoEstimado
        FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_OV
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        WHERE t1.U_Tipo_Documento = 'OV' AND t4.InternIdProduct <> '013956'
        GROUP BY t0.DocNum

        UNION ALL

        -- Peso de TRs
        SELECT t0.DocNum, SUM(t3.QtyToTransfer * ISNULL(t4.UnitMass, 0)) AS PesoEstimado
        FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sboferco.dbo.TransferRequest t2 WITH (NOLOCK) ON t2.DocNum = t1.U_No_OV
        LEFT JOIN [server-sql].lisa_sboferco.dbo.TransferRequestLines t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        WHERE t1.U_Tipo_Documento IN ('TR', 'RESURTIDO')
        GROUP BY t0.DocNum

        UNION ALL

        -- Peso de RMAs (NUEVO)
        SELECT t0.DocNum, SUM(rma.RMAQty * ISNULL(p.UnitMass, 0)) AS PesoEstimado
        FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].sboferco.dbo.NWR_RMASTATUS rma WITH (NOLOCK)
            ON rma.CallID = CAST(t1.U_No_OV AS INT)
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] p WITH (NOLOCK)
            ON p.InternIdProduct = rma.ItemCode
        WHERE t1.U_Tipo_Documento = 'RMA'
          AND rma.ItemCode IS NOT NULL
        GROUP BY t0.DocNum
    ) x
    GROUP BY DocNum
) peso ON peso.DocNum = src.DocNum
WHERE src.u_estado = '02'
  AND src.CreateDate > GETDATE() - 5
  AND src.U_Almacen_Origen = '01'
  AND NOT EXISTS (
        SELECT 1
        FROM dbo.RoutePlan rp
        WHERE rp.[RouteNumber] = src.DocNum
  );
GO


-- ============================================================
-- 3. ALTER PRC_UpdateRoutePickingTasksLisa
--    Agrega bloque RMA para actualizar CantidadPendiente
--    desde NWR_RMASTATUS.OpenQty
-- ============================================================
ALTER PROCEDURE [dbo].[PRC_UpdateRoutePickingTasksLisa]
AS
BEGIN
    SET NOCOUNT ON;
    SET LOCK_TIMEOUT 5000;

    DECLARE @msg     VARCHAR(200);
    DECLARE @retry   INT;
    DECLARE @done    BIT;

    -- ================================================
    -- BLOQUE TR (incluye RESURTIDO, ambos son traslados)
    -- ================================================
    RAISERROR('TR [1/3] Leyendo RoutePickingTask...', 0, 0) WITH NOWAIT;

    IF OBJECT_ID('tempdb..#TareasTR')        IS NOT NULL DROP TABLE #TareasTR;
    IF OBJECT_ID('tempdb..#LineasTR')        IS NOT NULL DROP TABLE #LineasTR;
    IF OBJECT_ID('tempdb..#TareasOV')        IS NOT NULL DROP TABLE #TareasOV;
    IF OBJECT_ID('tempdb..#LineasOV')        IS NOT NULL DROP TABLE #LineasOV;
    IF OBJECT_ID('tempdb..#TareasRMA')       IS NOT NULL DROP TABLE #TareasRMA;
    IF OBJECT_ID('tempdb..#LineasRMA')       IS NOT NULL DROP TABLE #LineasRMA;
    IF OBJECT_ID('tempdb..#RoutesProcessed') IS NOT NULL DROP TABLE #RoutesProcessed;

    SELECT
        Route_Number, IDCustomerORder, Line_ID, DocType, CantidadPendiente
    INTO #TareasTR
    FROM dbo.RoutePickingTask WITH (NOLOCK)
    WHERE Estado = 'En Proceso' AND DocType IN ('TR', 'RESURTIDO');

    SET @msg = 'TR [1/3] Completado. Filas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    CREATE CLUSTERED INDEX IX_TareasTR ON #TareasTR(IDCustomerORder, Line_ID);

    CREATE TABLE #LineasTR (
        IdTransferRequest INT,
        IDLine            INT,
        QtyToPick         NUMERIC(18, 6)
    );

    IF EXISTS (SELECT 1 FROM #TareasTR)
    BEGIN
        DECLARE @IDListTR NVARCHAR(MAX);
        SELECT @IDListTR = STUFF((
            SELECT DISTINCT N',' + CONVERT(NVARCHAR(50), IDCustomerORder)
            FROM #TareasTR
            FOR XML PATH(N'')
        ), 1, 1, N'');

        SET @msg = 'TR [2/3] OPENQUERY... IDs: '
                   + CONVERT(VARCHAR, (SELECT COUNT(DISTINCT IDCustomerORder) FROM #TareasTR));
        RAISERROR(@msg, 0, 0) WITH NOWAIT;

        DECLARE @sqlTR NVARCHAR(MAX);
        SET @sqlTR = N'
            SELECT IdTransferRequest, IDLine, QtyToPick
            FROM OPENQUERY([server-sql],
                ''SELECT IdTransferRequest, IDLine, QtyToPick
                  FROM lisa_sboferco.dbo.TransferRequestLines WITH (NOLOCK)
                  WHERE IdTransferRequest IN (' + @IDListTR + N')
                '');';

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
                FROM dbo.RoutePickingTask t0
                INNER JOIN #TareasTR tmp
                    ON  tmp.Route_Number    = t0.Route_Number
                    AND tmp.IDCustomerORder = t0.IDCustomerORder
                    AND tmp.Line_ID         = t0.Line_ID
                INNER JOIN #LineasTR t1
                    ON  t1.IdTransferRequest = CONVERT(INT, tmp.IDCustomerORder)
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
    RAISERROR('OV [1/3] Leyendo RoutePickingTask...', 0, 0) WITH NOWAIT;

    SELECT
        Route_Number, IDCustomerORder, Line_ID, DocType, CantidadPendiente
    INTO #TareasOV
    FROM dbo.RoutePickingTask WITH (NOLOCK)
    WHERE Estado = 'En Proceso' AND DocType = 'OV';

    SET @msg = 'OV [1/3] Completado. Filas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    CREATE CLUSTERED INDEX IX_TareasOV ON #TareasOV(IDCustomerORder, Line_ID);

    CREATE TABLE #LineasOV (
        IdCustomerOrder INT,
        IDLine          INT,
        ToPick          NUMERIC(18, 6)
    );

    IF EXISTS (SELECT 1 FROM #TareasOV)
    BEGIN
        DECLARE @IDListOV NVARCHAR(MAX);
        SELECT @IDListOV = STUFF((
            SELECT DISTINCT N',' + CONVERT(NVARCHAR(50), IDCustomerORder)
            FROM #TareasOV
            FOR XML PATH(N'')
        ), 1, 1, N'');

        SET @msg = 'OV [2/3] OPENQUERY... IDs: '
                   + CONVERT(VARCHAR, (SELECT COUNT(DISTINCT IDCustomerORder) FROM #TareasOV));
        RAISERROR(@msg, 0, 0) WITH NOWAIT;

        DECLARE @sqlOV NVARCHAR(MAX);
        SET @sqlOV = N'
            SELECT IdCustomerOrder, IDLine, ToPick
            FROM OPENQUERY([server-sql],
                ''SELECT IdCustomerOrder, IDLine, ToPick
                  FROM lisa_sboferco.dbo.CustomerOrderLine WITH (NOLOCK)
                  WHERE IdCustomerOrder IN (' + @IDListOV + N')
                '');';

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
                FROM dbo.RoutePickingTask t0
                INNER JOIN #TareasOV tmp
                    ON  tmp.Route_Number    = t0.Route_Number
                    AND tmp.IDCustomerORder = t0.IDCustomerORder
                    AND tmp.Line_ID         = t0.Line_ID
                INNER JOIN #LineasOV t1
                    ON  t1.IdCustomerOrder = CONVERT(INT, tmp.IDCustomerORder)
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
    -- BLOQUE RMA (NUEVO)
    -- Actualiza CantidadPendiente desde NWR_RMASTATUS.OpenQty
    -- ================================================
    RAISERROR('RMA [1/3] Leyendo RoutePickingTask...', 0, 0) WITH NOWAIT;

    SELECT
        Route_Number, IDCustomerORder, Line_ID, InternIdProduct, DocType, CantidadPendiente
    INTO #TareasRMA
    FROM dbo.RoutePickingTask WITH (NOLOCK)
    WHERE Estado = 'En Proceso' AND DocType = 'RMA';

    SET @msg = 'RMA [1/3] Completado. Filas: ' + CONVERT(VARCHAR, @@ROWCOUNT);
    RAISERROR(@msg, 0, 0) WITH NOWAIT;

    CREATE CLUSTERED INDEX IX_TareasRMA ON #TareasRMA(IDCustomerORder, Line_ID);

    CREATE TABLE #LineasRMA (
        CallID   INT,
        LineNum  INT,
        OpenQty  NUMERIC(18, 6)
    );

    IF EXISTS (SELECT 1 FROM #TareasRMA)
    BEGIN
        DECLARE @IDListRMA NVARCHAR(MAX);
        SELECT @IDListRMA = STUFF((
            SELECT DISTINCT N',' + CONVERT(NVARCHAR(50), IDCustomerORder)
            FROM #TareasRMA
            FOR XML PATH(N'')
        ), 1, 1, N'');

        SET @msg = 'RMA [2/3] OPENQUERY... IDs: '
                   + CONVERT(VARCHAR, (SELECT COUNT(DISTINCT IDCustomerORder) FROM #TareasRMA));
        RAISERROR(@msg, 0, 0) WITH NOWAIT;

        DECLARE @sqlRMA NVARCHAR(MAX);
        SET @sqlRMA = N'
            SELECT CallID, LineNum, OpenQty
            FROM OPENQUERY([server-sql],
                ''SELECT CallID, LineNum, OpenQty
                  FROM sboferco.dbo.NWR_RMASTATUS WITH (NOLOCK)
                  WHERE CallID IN (' + @IDListRMA + N')
                '');';

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
                FROM dbo.RoutePickingTask t0
                INNER JOIN #TareasRMA tmp
                    ON  tmp.Route_Number    = t0.Route_Number
                    AND tmp.IDCustomerORder = t0.IDCustomerORder
                    AND tmp.Line_ID         = t0.Line_ID
                INNER JOIN #LineasRMA t1
                    ON  t1.CallID  = CONVERT(INT, tmp.IDCustomerORder)
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
    -- Cierres acotados a rutas procesadas
    -- (incluye RMA en el scope)
    -- ================================================
    SELECT DISTINCT Route_Number INTO #RoutesProcessed FROM #TareasTR
    UNION
    SELECT DISTINCT Route_Number FROM #TareasOV
    UNION
    SELECT DISTINCT Route_Number FROM #TareasRMA;

    RAISERROR('Cerrando tareas finalizadas...', 0, 0) WITH NOWAIT;

    SET @retry = 0; SET @done = 0;
    WHILE @retry <= 3 AND @done = 0
    BEGIN
        BEGIN TRY
            UPDATE dbo.RoutePickingTask WITH (ROWLOCK)
            SET
                Estado              = 'Finalizado',
                UltimaActualizacion = GETDATE()
            WHERE ISNULL(CantidadPendiente, 0) = 0
              AND Estado <> 'Finalizado'
              AND Route_Number IN (SELECT Route_Number FROM #RoutesProcessed);

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

    RAISERROR('Cerrando RoutePlan...', 0, 0) WITH NOWAIT;

    SET @retry = 0; SET @done = 0;
    WHILE @retry <= 3 AND @done = 0
    BEGIN
        BEGIN TRY
            UPDATE rp WITH (ROWLOCK)
            SET rp.Estado = 'Finalizado'
            FROM dbo.RoutePlan rp
            INNER JOIN (
                SELECT Route_Number
                FROM dbo.RoutePickingTask WITH (NOLOCK)
                WHERE Route_Number IN (SELECT Route_Number FROM #RoutesProcessed)
                GROUP BY Route_Number
                HAVING SUM(ISNULL(CantidadPendiente, 0)) = 0
            ) tareas ON tareas.Route_Number = rp.RouteNumber
            WHERE rp.Estado <> 'Finalizado';

            SET @msg = 'RoutePlan cerrados: ' + CONVERT(VARCHAR, @@ROWCOUNT);
            RAISERROR(@msg, 0, 0) WITH NOWAIT;
            SET @done = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() = 1222 AND @retry < 3
            BEGIN
                SET @retry += 1;
                SET @msg = 'Cierre RoutePlan bloqueado, reintento ' + CONVERT(VARCHAR, @retry) + '/3...';
                RAISERROR(@msg, 0, 0) WITH NOWAIT;
                WAITFOR DELAY '00:00:03';
            END
            ELSE
            BEGIN
                SET @msg = 'Cierre RoutePlan fallido: ' + ERROR_MESSAGE();
                RAISERROR(@msg, 0, 0) WITH NOWAIT;
                SET @done = 1;
            END
        END CATCH
    END

    RAISERROR('Cerrando RoutePickingManagement...', 0, 0) WITH NOWAIT;

    SET @retry = 0; SET @done = 0;
    WHILE @retry <= 3 AND @done = 0
    BEGIN
        BEGIN TRY
            ;WITH PendienteProducto AS
            (
                SELECT
                    Route_Number,
                    InternIdProduct,
                    SUM(ISNULL(CantidadPendiente, 0)) AS CantidadPendiente
                FROM dbo.RoutePickingTask WITH (NOLOCK)
                WHERE Estado <> 'Pendiente'
                  AND Route_Number IN (SELECT Route_Number FROM #RoutesProcessed)
                GROUP BY Route_Number, InternIdProduct
            )
            UPDATE rpm WITH (ROWLOCK)
            SET rpm.Estado = 'Finalizado'
            FROM dbo.RoutePickingManagement rpm
            INNER JOIN PendienteProducto pp
                ON  pp.Route_Number    = rpm.RouteNumber
                AND pp.InternIdProduct = rpm.Product
            WHERE pp.CantidadPendiente = 0
              AND ISNULL(rpm.Estado, '') <> 'Finalizado';

            SET @msg = 'RoutePickingManagement cerrados: ' + CONVERT(VARCHAR, @@ROWCOUNT);
            RAISERROR(@msg, 0, 0) WITH NOWAIT;
            SET @done = 1;
        END TRY
        BEGIN CATCH
            IF ERROR_NUMBER() = 1222 AND @retry < 3
            BEGIN
                SET @retry += 1;
                SET @msg = 'Cierre RPM bloqueado, reintento ' + CONVERT(VARCHAR, @retry) + '/3...';
                RAISERROR(@msg, 0, 0) WITH NOWAIT;
                WAITFOR DELAY '00:00:03';
            END
            ELSE
            BEGIN
                SET @msg = 'Cierre RPM fallido: ' + ERROR_MESSAGE();
                RAISERROR(@msg, 0, 0) WITH NOWAIT;
                SET @done = 1;
            END
        END CATCH
    END

    RAISERROR('SP completado.', 0, 0) WITH NOWAIT;
END;
GO


-- ============================================================
-- 4. ALTER SP_UpdateOrderPickingTasksLisa
--    Agrega bloque RMA para actualizar CantidadPendiente
--    desde NWR_RMASTATUS.OpenQty (modelo por pedido)
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
        -- FIX: era lisa_sboferco, corregido a lisa_sbointergres (SV)

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
        -- FIX: era lisa_sboferco, corregido a lisa_sbointergres (SV)

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
    -- BLOQUE RMA (NUEVO)
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
        -- FIX: era sboferco, corregido a sbointergres (SV)

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
    -- Rutas procesadas (scope para cierres - incluye RMA)
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
            SET opm.Estado = 'Finalizado'
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
            SET orp.Estado = 'Finalizado'
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
