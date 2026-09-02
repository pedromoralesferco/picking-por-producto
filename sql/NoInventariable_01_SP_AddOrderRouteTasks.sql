-- ============================================================
-- SP_AddOrderRouteTasks — manejo de artículos NO INVENTARIABLES
-- Supersede sql/HN_02. Cambios:
--   1. Se agrega el flag OITM.InvntItem a cada línea (join a SAP OITM).
--   2. En la inserción de tareas, los no-inventariables (InvntItem='N',
--      p. ej. flete/servicios) nacen con CantidadPendiente=0 y
--      Estado='Finalizado' (el WMS no los pickea, pero quedan en el
--      pedido/packing list marcados como completados).
--   3. Se elimina la exclusión hardcodeada de '013956' (ahora lo cubre
--      el flag general InvntItem).
-- Nota: en sbopym (HN) el item 013956 está como InvntItem='Y'; si debe
--       ser no inventariable, corregirlo en el maestro de artículos SAP.
-- ============================================================
ALTER PROCEDURE [dbo].[SP_AddOrderRouteTasks]
    @ID_RoutePlan INT,
    @RouteNumber  INT,
    @ID_Centro    INT,
    @Pais         NVARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#tmpOrderRouteData') IS NOT NULL
        DROP TABLE #tmpOrderRouteData;

    CREATE TABLE #tmpOrderRouteData (
        RouteNumber INT,
        RouteName NVARCHAR(100) COLLATE DATABASE_DEFAULT,
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
        UnitWeight NUMERIC(18,6),
        InvntItem NVARCHAR(1) COLLATE DATABASE_DEFAULT
    );

    IF @Pais = 'GT'
    BEGIN
        INSERT INTO #tmpOrderRouteData
        SELECT
            t0.DocNum, t0.U_NombreR, t1.U_No_Ov, t1.U_Tipo_Documento,
            t2.IdCustomerOrder, t2.IdAccountableOrder,
            t3.IdLine, t3.IdProduct, t4.InternIdProduct, t4.ProductName,
            t3.QtyOrdered, t3.ToPick, t4.UnitMass, ISNULL(oi.InvntItem, 'Y')
        FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_Ov
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        LEFT JOIN [server-sql].sboferco.dbo.OITM oi WITH (NOLOCK) ON oi.ItemCode COLLATE DATABASE_DEFAULT = t4.InternIdProduct COLLATE DATABASE_DEFAULT
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento = 'OV';

        INSERT INTO #tmpOrderRouteData
        SELECT
            t0.DocNum, t0.U_NombreR, t1.U_No_Ov, t1.U_Tipo_Documento,
            t2.IdTransferRequest, t2.DocNum,
            t3.IdLine, t3.IdProduct, t4.InternIdProduct, t4.ProductName,
            t3.QtyToTransfer, t3.QtyToPick, t4.UnitMass, ISNULL(oi.InvntItem, 'Y')
        FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sboferco.dbo.TransferRequest t2 WITH (NOLOCK) ON t2.DocNum = t1.U_No_OV
        LEFT JOIN [server-sql].lisa_sboferco.dbo.TransferRequestLines t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        LEFT JOIN [server-sql].sboferco.dbo.OITM oi WITH (NOLOCK) ON oi.ItemCode COLLATE DATABASE_DEFAULT = t4.InternIdProduct COLLATE DATABASE_DEFAULT
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento IN ('TR', 'RESURTIDO');
    END
    ELSE IF @Pais = 'SV'
    BEGIN
        INSERT INTO #tmpOrderRouteData
        SELECT
            t0.DocNum, ISNULL(t0.U_NombreR, 'Ruta ' + CAST(t0.DocNum AS NVARCHAR(20))),
            t1.U_No_Ov, t1.U_Tipo_Documento,
            t2.IdCustomerOrder, t2.IdAccountableOrder,
            t3.IdLine, t3.IdProduct, t4.InternIdProduct, t4.ProductName,
            t3.QtyOrdered, t3.ToPick, t4.UnitMass, ISNULL(oi.InvntItem, 'Y')
        FROM [server-sql].sbointergres.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbointergres.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_Ov
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        LEFT JOIN [server-sql].sbointergres.dbo.OITM oi WITH (NOLOCK) ON oi.ItemCode COLLATE DATABASE_DEFAULT = t4.InternIdProduct COLLATE DATABASE_DEFAULT
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento = 'OV';

        INSERT INTO #tmpOrderRouteData
        SELECT
            t0.DocNum, ISNULL(t0.U_NombreR, 'Ruta ' + CAST(t0.DocNum AS NVARCHAR(20))),
            t1.U_No_Ov, t1.U_Tipo_Documento,
            t2.IdTransferRequest, t2.DocNum,
            t3.IdLine, t3.IdProduct, t4.InternIdProduct, t4.ProductName,
            t3.QtyToTransfer, t3.QtyToPick, t4.UnitMass, ISNULL(oi.InvntItem, 'Y')
        FROM [server-sql].sbointergres.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbointergres.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.TransferRequest t2 WITH (NOLOCK) ON t2.DocNum = t1.U_No_OV
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.TransferRequestLines t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        LEFT JOIN [server-sql].sbointergres.dbo.OITM oi WITH (NOLOCK) ON oi.ItemCode COLLATE DATABASE_DEFAULT = t4.InternIdProduct COLLATE DATABASE_DEFAULT
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento IN ('TR', 'RESURTIDO');
    END
    ELSE IF @Pais = 'HN'
    BEGIN
        INSERT INTO #tmpOrderRouteData
        SELECT
            t0.DocNum, ISNULL(t0.U_NombreR, 'Ruta ' + CAST(t0.DocNum AS NVARCHAR(20))),
            t1.U_No_Ov, t1.U_Tipo_Documento,
            t2.IdCustomerOrder, t2.IdAccountableOrder,
            t3.IdLine, t3.IdProduct, t4.InternIdProduct, t4.ProductName,
            t3.QtyOrdered, t3.ToPick, t4.UnitMass, ISNULL(oi.InvntItem, 'Y')
        FROM [server-sql].sbopym.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbopym.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_Ov
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        LEFT JOIN [server-sql].sbopym.dbo.OITM oi WITH (NOLOCK) ON oi.ItemCode COLLATE DATABASE_DEFAULT = t4.InternIdProduct COLLATE DATABASE_DEFAULT
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento = 'OV';

        INSERT INTO #tmpOrderRouteData
        SELECT
            t0.DocNum, ISNULL(t0.U_NombreR, 'Ruta ' + CAST(t0.DocNum AS NVARCHAR(20))),
            t1.U_No_Ov, t1.U_Tipo_Documento,
            t2.IdTransferRequest, t2.DocNum,
            t3.IdLine, t3.IdProduct, t4.InternIdProduct, t4.ProductName,
            t3.QtyToTransfer, t3.QtyToPick, t4.UnitMass, ISNULL(oi.InvntItem, 'Y')
        FROM [server-sql].sbopym.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbopym.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbopym.dbo.TransferRequest t2 WITH (NOLOCK) ON t2.DocNum = t1.U_No_OV
        LEFT JOIN [server-sql].lisa_sbopym.dbo.TransferRequestLines t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        LEFT JOIN [server-sql].sbopym.dbo.OITM oi WITH (NOLOCK) ON oi.ItemCode COLLATE DATABASE_DEFAULT = t4.InternIdProduct COLLATE DATABASE_DEFAULT
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento IN ('TR', 'RESURTIDO');
    END

    INSERT INTO dbo.OrderPickingManagement (
        ID_RoutePlan, RouteNumber, OV_Number, DocType,
        IDCustomerOrder, IdAccountableOrder,
        TotalLineas, TotalUnidades, PesoTotal,
        ID_Centro, Pais
    )
    SELECT
        @ID_RoutePlan, RouteNumber, OV_Number, DocType,
        IdCustomerOrder, IdAccountableOrder,
        COUNT(*), SUM(Cantidad), SUM(Cantidad * UnitWeight),
        @ID_Centro, @Pais
    FROM #tmpOrderRouteData
    GROUP BY RouteNumber, OV_Number, DocType, IdCustomerOrder, IdAccountableOrder;

    INSERT INTO dbo.OrderPickingTask (
        ID_OrderPicking, RouteNumber, OV_Number, DocType,
        IDCustomerOrder, IdAccountableOrder, Line_ID,
        IdProduct, InternIdProduct, Descripcion,
        Cantidad, CantidadPendiente, UnitWeight,
        Estado, FechaLiberacion, ID_Centro, Pais
    )
    SELECT
        opm.ID_OrderPicking, tmp.RouteNumber, tmp.OV_Number, tmp.DocType,
        tmp.IdCustomerOrder, tmp.IdAccountableOrder, tmp.Line_ID,
        tmp.IdProduct, tmp.InternIdProduct, tmp.ProductName,
        tmp.Cantidad,
        CASE WHEN tmp.InvntItem = 'N' THEN 0 ELSE tmp.CantidadPendiente END,
        tmp.UnitWeight,
        CASE WHEN tmp.InvntItem = 'N' THEN 'Finalizado' ELSE 'Pendiente' END,
        GETDATE(), @ID_Centro, @Pais
    FROM #tmpOrderRouteData tmp
    INNER JOIN dbo.OrderPickingManagement opm
        ON  opm.RouteNumber = tmp.RouteNumber
        AND opm.OV_Number   = tmp.OV_Number
        AND opm.ID_RoutePlan = @ID_RoutePlan;

    DROP TABLE #tmpOrderRouteData;
END;
GO
