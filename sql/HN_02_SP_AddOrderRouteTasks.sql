-- ============================================================
-- Honduras (HN) — Paso 2: SP_AddOrderRouteTasks
-- Agrega la rama @Pais = 'HN' (lee de sbopym / lisa_sbopym).
-- Resto idéntico a la versión vigente (GT / SV sin cambios).
-- Lo dispara el trigger TR_OrderRoutePlan_EstadosFechas al
-- pasar una ruta a 'Iniciado'.
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
        UnitWeight NUMERIC(18,6)
    );

    IF @Pais = 'GT'
    BEGIN
        INSERT INTO #tmpOrderRouteData
        SELECT
            t0.DocNum, t0.U_NombreR, t1.U_No_Ov, t1.U_Tipo_Documento,
            t2.IdCustomerOrder, t2.IdAccountableOrder,
            t3.IdLine, t3.IdProduct, t4.InternIdProduct, t4.ProductName,
            t3.QtyOrdered, t3.ToPick, t4.UnitMass
        FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_Ov
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento = 'OV' AND t4.InternIdProduct <> '013956';

        INSERT INTO #tmpOrderRouteData
        SELECT
            t0.DocNum, t0.U_NombreR, t1.U_No_Ov, t1.U_Tipo_Documento,
            t2.IdTransferRequest, t2.DocNum,
            t3.IdLine, t3.IdProduct, t4.InternIdProduct, t4.ProductName,
            t3.QtyToTransfer, t3.QtyToPick, t4.UnitMass
        FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sboferco.dbo.TransferRequest t2 WITH (NOLOCK) ON t2.DocNum = t1.U_No_OV
        LEFT JOIN [server-sql].lisa_sboferco.dbo.TransferRequestLines t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento IN ('TR', 'RESURTIDO');
    END
    ELSE IF @Pais = 'SV'
    BEGIN
        INSERT INTO #tmpOrderRouteData
        SELECT
            t0.DocNum,
            ISNULL(t0.U_NombreR, 'Ruta ' + CAST(t0.DocNum AS NVARCHAR(20))),
            t1.U_No_Ov, t1.U_Tipo_Documento,
            t2.IdCustomerOrder, t2.IdAccountableOrder,
            t3.IdLine, t3.IdProduct, t4.InternIdProduct, t4.ProductName,
            t3.QtyOrdered, t3.ToPick, t4.UnitMass
        FROM [server-sql].sbointergres.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbointergres.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_Ov
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento = 'OV';

        INSERT INTO #tmpOrderRouteData
        SELECT
            t0.DocNum,
            ISNULL(t0.U_NombreR, 'Ruta ' + CAST(t0.DocNum AS NVARCHAR(20))),
            t1.U_No_Ov, t1.U_Tipo_Documento,
            t2.IdTransferRequest, t2.DocNum,
            t3.IdLine, t3.IdProduct, t4.InternIdProduct, t4.ProductName,
            t3.QtyToTransfer, t3.QtyToPick, t4.UnitMass
        FROM [server-sql].sbointergres.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbointergres.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.TransferRequest t2 WITH (NOLOCK) ON t2.DocNum = t1.U_No_OV
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.TransferRequestLines t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento IN ('TR', 'RESURTIDO');
    END
    -- ════════════════════════════════════════════════════════
    -- ── HONDURAS (sbopym / lisa_sbopym, Pais HN) — NUEVO
    -- ════════════════════════════════════════════════════════
    ELSE IF @Pais = 'HN'
    BEGIN
        INSERT INTO #tmpOrderRouteData
        SELECT
            t0.DocNum,
            ISNULL(t0.U_NombreR, 'Ruta ' + CAST(t0.DocNum AS NVARCHAR(20))),
            t1.U_No_Ov, t1.U_Tipo_Documento,
            t2.IdCustomerOrder, t2.IdAccountableOrder,
            t3.IdLine, t3.IdProduct, t4.InternIdProduct, t4.ProductName,
            t3.QtyOrdered, t3.ToPick, t4.UnitMass
        FROM [server-sql].sbopym.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbopym.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_Ov
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        WHERE t0.DocNum = @RouteNumber AND t1.U_Tipo_Documento = 'OV';

        INSERT INTO #tmpOrderRouteData
        SELECT
            t0.DocNum,
            ISNULL(t0.U_NombreR, 'Ruta ' + CAST(t0.DocNum AS NVARCHAR(20))),
            t1.U_No_Ov, t1.U_Tipo_Documento,
            t2.IdTransferRequest, t2.DocNum,
            t3.IdLine, t3.IdProduct, t4.InternIdProduct, t4.ProductName,
            t3.QtyToTransfer, t3.QtyToPick, t4.UnitMass
        FROM [server-sql].sbopym.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbopym.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbopym.dbo.TransferRequest t2 WITH (NOLOCK) ON t2.DocNum = t1.U_No_OV
        LEFT JOIN [server-sql].lisa_sbopym.dbo.TransferRequestLines t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
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
        FechaLiberacion, ID_Centro, Pais
    )
    SELECT
        opm.ID_OrderPicking, tmp.RouteNumber, tmp.OV_Number, tmp.DocType,
        tmp.IdCustomerOrder, tmp.IdAccountableOrder, tmp.Line_ID,
        tmp.IdProduct, tmp.InternIdProduct, tmp.ProductName,
        tmp.Cantidad, tmp.CantidadPendiente, tmp.UnitWeight,
        GETDATE(), @ID_Centro, @Pais
    FROM #tmpOrderRouteData tmp
    INNER JOIN dbo.OrderPickingManagement opm
        ON  opm.RouteNumber = tmp.RouteNumber
        AND opm.OV_Number   = tmp.OV_Number
        AND opm.ID_RoutePlan = @ID_RoutePlan;

    DROP TABLE #tmpOrderRouteData;
END;
GO
