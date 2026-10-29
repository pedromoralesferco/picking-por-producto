-- ============================================================
-- BLINDAJE de SP_AddOrderRouteTasks (arreglo de RAÍZ del duplicado)
-- ------------------------------------------------------------
-- Problema: el SP inserta pedidos (OPM) y tareas SIN verificar si ya
-- existen. Si una ruta se inicia dos veces, o se le forzó la ingesta
-- antes de iniciarla, el trigger vuelve a insertar TODO -> duplica.
--
-- Fix: hacer ambos INSERT idempotentes con NOT EXISTS por clave natural.
--   * OPM: no reinsertar un pedido (OV/TR) que ya existe en la ruta.
--   * Tarea: no reinsertar una línea (OV+Line+Producto) que ya existe.
-- Así un re-inicio o una re-importación SOLO agrega líneas nuevas y
-- nunca duplica, conservando el avance de las tareas ya existentes.
--
-- El cuerpo de lectura (GT/SV/HN) queda idéntico; solo cambian los
-- dos INSERT finales (marcados con  <<< BLINDAJE).
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

    -- <<< BLINDAJE 1: OPM idempotente — no reinsertar un pedido (OV/TR)
    -- que ya exista en esta ruta.
    INSERT INTO dbo.OrderPickingManagement (
        ID_RoutePlan, RouteNumber, OV_Number, DocType,
        IDCustomerOrder, IdAccountableOrder,
        TotalLineas, TotalUnidades, PesoTotal,
        ID_Centro, Pais
    )
    SELECT
        @ID_RoutePlan, tmp.RouteNumber, tmp.OV_Number, tmp.DocType,
        tmp.IdCustomerOrder, tmp.IdAccountableOrder,
        COUNT(*), SUM(tmp.Cantidad), SUM(tmp.Cantidad * tmp.UnitWeight),
        @ID_Centro, @Pais
    FROM #tmpOrderRouteData tmp
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.OrderPickingManagement o
        WHERE o.ID_RoutePlan = @ID_RoutePlan
          AND o.OV_Number = tmp.OV_Number COLLATE DATABASE_DEFAULT
    )
    GROUP BY tmp.RouteNumber, tmp.OV_Number, tmp.DocType, tmp.IdCustomerOrder, tmp.IdAccountableOrder;

    -- <<< BLINDAJE 2: Tarea idempotente — no reinsertar una línea
    -- (OV + Line_ID + Producto) que ya exista en esta ruta.
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
        AND opm.ID_RoutePlan = @ID_RoutePlan
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.OrderPickingTask t2
        WHERE t2.RouteNumber = tmp.RouteNumber
          AND t2.OV_Number   = tmp.OV_Number COLLATE DATABASE_DEFAULT
          AND t2.Line_ID     = tmp.Line_ID
          AND t2.IdProduct   = tmp.IdProduct COLLATE DATABASE_DEFAULT
          AND t2.Pais        = @Pais
    );

    DROP TABLE #tmpOrderRouteData;

    -- Nombre de cliente/destino desde SAP (best-effort; no rompe si el linked server falla).
    IF OBJECT_ID('dbo.SP_FillClienteNombre') IS NOT NULL
        EXEC dbo.SP_FillClienteNombre @ID_RoutePlan;
END;
GO
