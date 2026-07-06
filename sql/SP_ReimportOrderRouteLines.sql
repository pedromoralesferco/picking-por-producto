-- ============================================================
-- SP_ReimportOrderRouteLines  (modo pedido / order: SV, HN)
--
-- Re-sincroniza las líneas/pedidos de una ruta YA INICIADA contra
-- el cuadro de ruta actual en SAP/Lisa:
--   - Agrega pedidos y líneas nuevos que no existían.
--   - Elimina líneas/pedidos que se quitaron del cuadro.
--   - Recalcula totales (TotalLineas/Unidades/Peso) por pedido.
--   - Reabre pedidos 'Finalizado' que vuelvan a tener pendientes.
-- NO toca el progreso de las líneas que permanecen (no refresca
-- cantidades: de eso se encarga SP_UpdateOrderPickingTasksLisa).
--
-- Candado de seguridad: si el cuadro no devuelve líneas (p.ej. falla
-- el linked server), ABORTA sin borrar nada.
-- ============================================================
IF OBJECT_ID('dbo.SP_ReimportOrderRouteLines') IS NOT NULL
    DROP PROCEDURE dbo.SP_ReimportOrderRouteLines;
GO
CREATE PROCEDURE [dbo].[SP_ReimportOrderRouteLines]
    @ID_RoutePlan INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RouteNumber INT, @ID_Centro INT, @Pais NVARCHAR(10), @Estado NVARCHAR(20);
    SELECT @RouteNumber = RouteNumber, @ID_Centro = ID_Centro, @Pais = Pais, @Estado = Estado
    FROM dbo.OrderRoutePlan WHERE ID_RoutePlan = @ID_RoutePlan;

    IF @RouteNumber IS NULL
    BEGIN RAISERROR('Ruta no encontrada.', 16, 1); RETURN; END

    IF @Pais NOT IN ('SV', 'HN')
    BEGIN RAISERROR('Re-import solo disponible para rutas en modo pedido (SV/HN).', 16, 1); RETURN; END

    IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;
    CREATE TABLE #src (
        RouteNumber INT,
        OV_Number NVARCHAR(50) COLLATE DATABASE_DEFAULT,
        DocType NVARCHAR(10) COLLATE DATABASE_DEFAULT,
        IdCustomerOrder NVARCHAR(50) COLLATE DATABASE_DEFAULT,
        IdAccountableOrder NVARCHAR(50) COLLATE DATABASE_DEFAULT,
        Line_ID INT,
        IdProduct NVARCHAR(30) COLLATE DATABASE_DEFAULT,
        InternIdProduct NVARCHAR(30) COLLATE DATABASE_DEFAULT,
        ProductName NVARCHAR(255) COLLATE DATABASE_DEFAULT,
        Cantidad NUMERIC(18,6),
        CantidadPendiente NUMERIC(18,6),
        UnitWeight NUMERIC(18,6)
    );

    -- ── Cargar el cuadro actual desde SAP/Lisa según país ──
    IF @Pais = 'SV'
    BEGIN
        INSERT INTO #src
        SELECT t0.DocNum, t1.U_No_Ov, t1.U_Tipo_Documento,
               t2.IdCustomerOrder, t2.IdAccountableOrder, t3.IdLine, t3.IdProduct,
               t4.InternIdProduct, t4.ProductName, t3.QtyOrdered, t3.ToPick, t4.UnitMass
        FROM [server-sql].sbointergres.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbointergres.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_Ov
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento = 'OV';

        INSERT INTO #src
        SELECT t0.DocNum, t1.U_No_Ov, t1.U_Tipo_Documento,
               t2.IdTransferRequest, t2.DocNum, t3.IdLine, t3.IdProduct,
               t4.InternIdProduct, t4.ProductName, t3.QtyToTransfer, t3.QtyToPick, t4.UnitMass
        FROM [server-sql].sbointergres.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbointergres.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.TransferRequest t2 WITH (NOLOCK) ON t2.DocNum = t1.U_No_OV
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.TransferRequestLines t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento IN ('TR', 'RESURTIDO');
    END
    ELSE IF @Pais = 'HN'
    BEGIN
        INSERT INTO #src
        SELECT t0.DocNum, t1.U_No_Ov, t1.U_Tipo_Documento,
               t2.IdCustomerOrder, t2.IdAccountableOrder, t3.IdLine, t3.IdProduct,
               t4.InternIdProduct, t4.ProductName, t3.QtyOrdered, t3.ToPick, t4.UnitMass
        FROM [server-sql].sbopym.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbopym.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_Ov
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento = 'OV';

        INSERT INTO #src
        SELECT t0.DocNum, t1.U_No_Ov, t1.U_Tipo_Documento,
               t2.IdTransferRequest, t2.DocNum, t3.IdLine, t3.IdProduct,
               t4.InternIdProduct, t4.ProductName, t3.QtyToTransfer, t3.QtyToPick, t4.UnitMass
        FROM [server-sql].sbopym.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbopym.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbopym.dbo.TransferRequest t2 WITH (NOLOCK) ON t2.DocNum = t1.U_No_OV
        LEFT JOIN [server-sql].lisa_sbopym.dbo.TransferRequestLines t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento IN ('TR', 'RESURTIDO');
    END

    -- ── Candado de seguridad: no borrar todo si el cuadro vino vacío ──
    IF NOT EXISTS (SELECT 1 FROM #src)
    BEGIN
        DROP TABLE #src;
        RAISERROR('No se obtuvieron líneas del cuadro de ruta; re-import cancelado.', 16, 1);
        RETURN;
    END

    DECLARE @addPed INT = 0, @addTask INT = 0, @delTask INT = 0, @delPed INT = 0;

    BEGIN TRY
        BEGIN TRAN;

        -- 1) Pedidos (OPM) nuevos
        INSERT INTO dbo.OrderPickingManagement
            (ID_RoutePlan, RouteNumber, OV_Number, DocType, IDCustomerOrder, IdAccountableOrder,
             TotalLineas, TotalUnidades, PesoTotal, ID_Centro, Pais)
        SELECT @ID_RoutePlan, @RouteNumber, s.OV_Number, s.DocType,
               MAX(s.IdCustomerOrder), MAX(s.IdAccountableOrder), 0, 0, 0, @ID_Centro, @Pais
        FROM #src s
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.OrderPickingManagement opm
            WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.OV_Number = s.OV_Number AND opm.DocType = s.DocType)
        GROUP BY s.OV_Number, s.DocType;
        SET @addPed = @@ROWCOUNT;

        -- 2) Líneas (tareas) nuevas  (IDCustomerOrder es NOT NULL: si una línea nueva
        --    no matchea en Lisa, el INSERT falla y se revierte todo — candado de integridad)
        INSERT INTO dbo.OrderPickingTask
            (ID_OrderPicking, RouteNumber, OV_Number, DocType, IDCustomerOrder, IdAccountableOrder,
             Line_ID, IdProduct, InternIdProduct, Descripcion, Cantidad, CantidadPendiente,
             UnitWeight, FechaLiberacion, ID_Centro, Pais)
        SELECT opm.ID_OrderPicking, @RouteNumber, s.OV_Number, s.DocType, s.IdCustomerOrder, s.IdAccountableOrder,
               s.Line_ID, s.IdProduct, s.InternIdProduct, s.ProductName, s.Cantidad, s.CantidadPendiente,
               s.UnitWeight, GETDATE(), @ID_Centro, @Pais
        FROM #src s
        INNER JOIN dbo.OrderPickingManagement opm
            ON opm.ID_RoutePlan = @ID_RoutePlan AND opm.OV_Number = s.OV_Number AND opm.DocType = s.DocType
        WHERE NOT EXISTS (
            SELECT 1 FROM dbo.OrderPickingTask t
            WHERE t.ID_OrderPicking = opm.ID_OrderPicking AND t.Line_ID = s.Line_ID);
        SET @addTask = @@ROWCOUNT;

        -- 3) Borrar líneas que ya no están en el cuadro
        DELETE t
        FROM dbo.OrderPickingTask t
        INNER JOIN dbo.OrderPickingManagement opm ON opm.ID_OrderPicking = t.ID_OrderPicking
        WHERE opm.ID_RoutePlan = @ID_RoutePlan
          AND NOT EXISTS (
              SELECT 1 FROM #src s
              WHERE s.OV_Number = t.OV_Number AND s.DocType = t.DocType AND s.Line_ID = t.Line_ID);
        SET @delTask = @@ROWCOUNT;

        -- 4) Borrar pedidos que quedaron sin líneas
        DELETE opm
        FROM dbo.OrderPickingManagement opm
        WHERE opm.ID_RoutePlan = @ID_RoutePlan
          AND NOT EXISTS (SELECT 1 FROM dbo.OrderPickingTask t WHERE t.ID_OrderPicking = opm.ID_OrderPicking);
        SET @delPed = @@ROWCOUNT;

        -- 5) Recalcular totales por pedido
        UPDATE opm
        SET opm.TotalLineas = x.n, opm.TotalUnidades = x.u, opm.PesoTotal = x.p
        FROM dbo.OrderPickingManagement opm
        INNER JOIN (
            SELECT t.ID_OrderPicking,
                   COUNT(*) AS n,
                   SUM(ISNULL(t.Cantidad, 0)) AS u,
                   SUM(ISNULL(t.Cantidad, 0) * ISNULL(t.UnitWeight, 0)) AS p
            FROM dbo.OrderPickingTask t
            INNER JOIN dbo.OrderPickingManagement o ON o.ID_OrderPicking = t.ID_OrderPicking
            WHERE o.ID_RoutePlan = @ID_RoutePlan
            GROUP BY t.ID_OrderPicking
        ) x ON x.ID_OrderPicking = opm.ID_OrderPicking;

        -- 6) Reabrir pedidos 'Finalizado' que vuelvan a tener pendientes
        UPDATE opm
        SET opm.Estado = 'Pendiente', opm.FechaFin = NULL
        FROM dbo.OrderPickingManagement opm
        WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.Estado = 'Finalizado'
          AND EXISTS (SELECT 1 FROM dbo.OrderPickingTask t
                      WHERE t.ID_OrderPicking = opm.ID_OrderPicking AND ISNULL(t.CantidadPendiente, 0) > 0);

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        DECLARE @em NVARCHAR(2000) = ERROR_MESSAGE();
        DROP TABLE #src;
        RAISERROR(@em, 16, 1);
        RETURN;
    END CATCH

    DROP TABLE #src;

    SELECT @addPed AS PedidosAgregados, @addTask AS LineasAgregadas,
           @delTask AS LineasEliminadas, @delPed AS PedidosEliminados;
END;
GO
