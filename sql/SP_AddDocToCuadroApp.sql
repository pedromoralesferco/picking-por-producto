-- ============================================================
-- SP_AddDocToCuadroApp — agrega UN documento (OV/TR/RMA) a un cuadro de
-- Escuintla DESDE EL APP (app-first), jalando sus líneas directo de Lisa por
-- número de documento (no desde @cuadro_ruta, porque aún no está en SAP).
--
-- El pedido/líneas nacen con PendienteSync=1 (los reconciliadores NO los
-- borran ni marcan hasta que Fase 3 lo sincronice a SAP). Candado: si el doc
-- no trae líneas en Lisa, RAISERROR (no se agrega un doc vacío/ inexistente).
-- Solo GT/Escuintla (sboferco/lisa_sboferco).
-- ============================================================
IF OBJECT_ID('dbo.SP_AddDocToCuadroApp') IS NOT NULL
    DROP PROCEDURE dbo.SP_AddDocToCuadroApp;
GO
CREATE PROCEDURE [dbo].[SP_AddDocToCuadroApp]
    @ID_RoutePlan INT,
    @OV           NVARCHAR(50),
    @DocType      NVARCHAR(10),   -- 'OV' | 'TR' | 'RMA'
    @EmitResult   BIT = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RouteNumber INT, @ID_Centro INT, @Pais NVARCHAR(10);
    SELECT @RouteNumber = RouteNumber, @ID_Centro = ID_Centro, @Pais = Pais
    FROM dbo.OrderRoutePlan WHERE ID_RoutePlan = @ID_RoutePlan;

    IF @RouteNumber IS NULL
    BEGIN RAISERROR('Cuadro no encontrado.', 16, 1); RETURN; END
    IF @ID_Centro <> 3 OR @Pais <> 'GT'
    BEGIN RAISERROR('Agregar documento solo disponible en HUB Escuintla (GT).', 16, 1); RETURN; END

    SET @OV = LTRIM(RTRIM(@OV));
    SET @DocType = UPPER(LTRIM(RTRIM(@DocType)));

    -- Ya está en el cuadro: nada que hacer.
    IF EXISTS (SELECT 1 FROM dbo.OrderPickingManagement
               WHERE ID_RoutePlan = @ID_RoutePlan
                 AND OV_Number COLLATE DATABASE_DEFAULT = @OV COLLATE DATABASE_DEFAULT
                 AND DocType = @DocType)
    BEGIN
        IF @EmitResult = 1 SELECT 0 AS PedidosAgregados, 0 AS LineasAgregadas, 'Ya estaba en el cuadro' AS Nota;
        RETURN;
    END

    IF OBJECT_ID('tempdb..#src') IS NOT NULL DROP TABLE #src;
    CREATE TABLE #src (
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

    IF @DocType = 'OV'
        INSERT INTO #src
        SELECT @OV, 'OV', t2.IdCustomerOrder, t2.IdAccountableOrder, t3.IdLine, t3.IdProduct,
               t4.InternIdProduct, t4.ProductName, t3.QtyOrdered, t3.ToPick, t4.UnitMass, ISNULL(oi.InvntItem, 'Y')
        FROM [server-sql].lisa_sboferco.dbo.[CustomerOrder] t2 WITH (NOLOCK)
        INNER JOIN [server-sql].lisa_sboferco.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        LEFT JOIN [server-sql].sboferco.dbo.OITM oi WITH (NOLOCK) ON oi.ItemCode COLLATE DATABASE_DEFAULT = t4.InternIdProduct COLLATE DATABASE_DEFAULT
        WHERE t2.IdAccountableOrder COLLATE DATABASE_DEFAULT = @OV COLLATE DATABASE_DEFAULT;
    ELSE IF @DocType = 'TR'
        INSERT INTO #src
        SELECT @OV, 'TR', t2.IdTransferRequest, t2.DocNum, t3.IdLine, t3.IdProduct,
               t4.InternIdProduct, t4.ProductName, t3.QtyToTransfer, t3.QtyToPick, t4.UnitMass, ISNULL(oi.InvntItem, 'Y')
        FROM [server-sql].lisa_sboferco.dbo.TransferRequest t2 WITH (NOLOCK)
        INNER JOIN [server-sql].lisa_sboferco.dbo.TransferRequestLines t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        LEFT JOIN [server-sql].sboferco.dbo.OITM oi WITH (NOLOCK) ON oi.ItemCode COLLATE DATABASE_DEFAULT = t4.InternIdProduct COLLATE DATABASE_DEFAULT
        WHERE CAST(t2.DocNum AS NVARCHAR(50)) COLLATE DATABASE_DEFAULT = @OV COLLATE DATABASE_DEFAULT;
    ELSE IF @DocType = 'RMA'
        INSERT INTO #src
        SELECT @OV, 'RMA', CAST(rma.CallID AS NVARCHAR(50)), CAST(rma.CallID AS NVARCHAR(50)), rma.LineNum, t4.IdProduct,
               rma.ItemCode, ISNULL(t4.ProductName, rma.ItemCode), rma.RMAQty, rma.RMAQty, ISNULL(t4.UnitMass, 0), ISNULL(oi.InvntItem, 'Y')
        FROM [server-sql].sboferco.dbo.NWR_RMASTATUS rma WITH (NOLOCK)
        LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] t4 WITH (NOLOCK) ON t4.InternIdProduct COLLATE DATABASE_DEFAULT = rma.ItemCode COLLATE DATABASE_DEFAULT
        LEFT JOIN [server-sql].sboferco.dbo.OITM oi WITH (NOLOCK) ON oi.ItemCode COLLATE DATABASE_DEFAULT = rma.ItemCode COLLATE DATABASE_DEFAULT
        WHERE rma.CallID = TRY_CAST(@OV AS INT) AND rma.[Status] = 'O';
    ELSE
    BEGIN RAISERROR('DocType inválido (OV|TR|RMA).', 16, 1); RETURN; END

    -- Candado: el doc no existe / no tiene líneas en Lisa.
    IF NOT EXISTS (SELECT 1 FROM #src)
    BEGIN
        DROP TABLE #src;
        RAISERROR('El documento no tiene líneas en Lisa (no existe o no está disponible).', 16, 1);
        RETURN;
    END

    DECLARE @addPed INT = 0, @addTask INT = 0;

    BEGIN TRY
        BEGIN TRAN;

        -- OPM (pedido) nuevo — PendienteSync=1 (agregado en el app, aún no en SAP)
        INSERT INTO dbo.OrderPickingManagement
            (ID_RoutePlan, RouteNumber, OV_Number, DocType, IDCustomerOrder, IdAccountableOrder,
             TotalLineas, TotalUnidades, PesoTotal, ID_Centro, Pais, PendienteSync)
        SELECT @ID_RoutePlan, @RouteNumber, s.OV_Number, s.DocType,
               MAX(s.IdCustomerOrder), MAX(s.IdAccountableOrder), 0, 0, 0, @ID_Centro, @Pais, 1
        FROM #src s
        GROUP BY s.OV_Number, s.DocType;
        SET @addPed = @@ROWCOUNT;

        -- Tareas (líneas). No-inventariables nacen 'Finalizado'. Candado de
        -- integridad: IdCustomerOrder NOT NULL (línea sin match en Lisa revierte).
        INSERT INTO dbo.OrderPickingTask
            (ID_OrderPicking, RouteNumber, OV_Number, DocType, IDCustomerOrder, IdAccountableOrder,
             Line_ID, IdProduct, InternIdProduct, Descripcion, Cantidad, CantidadPendiente,
             UnitWeight, Estado, FechaLiberacion, ID_Centro, Pais)
        SELECT opm.ID_OrderPicking, @RouteNumber, s.OV_Number, s.DocType, s.IdCustomerOrder, s.IdAccountableOrder,
               s.Line_ID, s.IdProduct, s.InternIdProduct, s.ProductName, s.Cantidad,
               CASE WHEN s.InvntItem = 'N' THEN 0 ELSE s.CantidadPendiente END,
               s.UnitWeight,
               CASE WHEN s.InvntItem = 'N' THEN 'Finalizado' ELSE 'Pendiente' END,
               GETDATE(), @ID_Centro, @Pais
        FROM #src s
        INNER JOIN dbo.OrderPickingManagement opm
            ON opm.ID_RoutePlan = @ID_RoutePlan AND opm.OV_Number = s.OV_Number AND opm.DocType = s.DocType;
        SET @addTask = @@ROWCOUNT;

        -- Totales del pedido
        UPDATE opm
        SET opm.TotalLineas = x.n, opm.TotalUnidades = x.u, opm.PesoTotal = x.p
        FROM dbo.OrderPickingManagement opm
        INNER JOIN (
            SELECT t.ID_OrderPicking, COUNT(*) AS n,
                   SUM(ISNULL(t.Cantidad,0)) AS u,
                   SUM(ISNULL(t.Cantidad,0)*ISNULL(t.UnitWeight,0)) AS p
            FROM dbo.OrderPickingTask t
            INNER JOIN dbo.OrderPickingManagement o ON o.ID_OrderPicking = t.ID_OrderPicking
            WHERE o.ID_RoutePlan = @ID_RoutePlan AND o.OV_Number = @OV AND o.DocType = @DocType
            GROUP BY t.ID_OrderPicking
        ) x ON x.ID_OrderPicking = opm.ID_OrderPicking;

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

    -- Nombre de cliente/destino desde SAP (best-effort; no rompe si el linked server falla).
    IF OBJECT_ID('dbo.SP_FillClienteNombre') IS NOT NULL
        EXEC dbo.SP_FillClienteNombre @ID_RoutePlan;

    IF @EmitResult = 1 SELECT @addPed AS PedidosAgregados, @addTask AS LineasAgregadas, NULL AS Nota;
END;
GO

PRINT 'SP_AddDocToCuadroApp creado OK';
