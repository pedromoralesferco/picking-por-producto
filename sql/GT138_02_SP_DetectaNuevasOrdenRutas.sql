-- ============================================================
-- SP_DetectaNuevasOrdenRutas  (versión con GT/138 en modo pedido)
-- Supersede a sql/HN_03. Bloques activos: SV (67), HN (01), GT-138.
-- Zona 5 (GT/01) NO va aquí: sigue en modo producto (RP_DetectaNuevasRutas).
-- PesoEstimado = OV + TR (los traslados también cuentan en el peso).
-- ============================================================
ALTER PROCEDURE [dbo].[SP_DetectaNuevasOrdenRutas]
AS
BEGIN
    SET NOCOUNT ON;

    -- ========================================
    -- El Salvador (sbointergres, Pais SV)
    -- ========================================
    INSERT INTO dbo.OrderRoutePlan (RouteNumber, RouteName, FechaPlanificacion, AlmacenOrigen, ID_Centro, Pais, PesoEstimado)
    SELECT src.DocNum, ISNULL(src.U_NombreR, 'Ruta ' + CAST(src.DocNum AS NVARCHAR(20))), GETDATE(), '67', cd.ID_Centro, 'SV', ISNULL(peso.PesoEstimado, 0)
    FROM [server-sql].sbointergres.dbo.[@CUADRO_RUTA_E] AS src WITH (NOLOCK)
    CROSS JOIN dbo.CentroDistribucion cd
    LEFT JOIN (
        SELECT z.DocNum, SUM(z.peso) AS PesoEstimado FROM (
            -- OV
            SELECT t0.DocNum, SUM(ISNULL(t3.QtyOrdered,0) * ISNULL(t4.UnitMass, 0)) AS peso
            FROM [server-sql].sbointergres.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
            LEFT JOIN [server-sql].sbointergres.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
            LEFT JOIN [server-sql].lisa_sbointergres.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_OV
            LEFT JOIN [server-sql].lisa_sbointergres.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
            LEFT JOIN [server-sql].lisa_sbointergres.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
            WHERE t1.U_Tipo_Documento = 'OV' GROUP BY t0.DocNum
            UNION ALL
            -- TR (traslados) — también cuentan en el peso
            SELECT t0.DocNum, SUM(ISNULL(t3.QtyToTransfer,0) * ISNULL(t4.UnitMass, 0)) AS peso
            FROM [server-sql].sbointergres.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
            LEFT JOIN [server-sql].sbointergres.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
            LEFT JOIN [server-sql].lisa_sbointergres.dbo.[TransferRequest] t2 WITH (NOLOCK) ON t2.DocNum = t1.U_No_OV
            LEFT JOIN [server-sql].lisa_sbointergres.dbo.[TransferRequestLines] t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
            LEFT JOIN [server-sql].lisa_sbointergres.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
            WHERE t1.U_Tipo_Documento IN ('TR','RESURTIDO') GROUP BY t0.DocNum
        ) z GROUP BY z.DocNum
    ) peso ON peso.DocNum = src.DocNum
    WHERE cd.Pais = 'SV' AND cd.Codigo = '67'
      AND src.u_estado = '02' AND src.CreateDate > GETDATE() - 5
      AND NOT EXISTS (SELECT 1 FROM dbo.OrderRoutePlan orp WHERE orp.RouteNumber = src.DocNum AND orp.Pais = 'SV');

    -- ========================================
    -- Honduras (sbopym, CEDI 01, Pais HN) — estados 01/02
    -- ========================================
    INSERT INTO dbo.OrderRoutePlan (RouteNumber, RouteName, FechaPlanificacion, AlmacenOrigen, ID_Centro, Pais, PesoEstimado)
    SELECT src.DocNum, ISNULL(src.U_NombreR, 'Ruta ' + CAST(src.DocNum AS NVARCHAR(20))), GETDATE(), '01', cd.ID_Centro, 'HN', ISNULL(peso.PesoEstimado, 0)
    FROM [server-sql].sbopym.dbo.[@CUADRO_RUTA_E] AS src WITH (NOLOCK)
    CROSS JOIN dbo.CentroDistribucion cd
    LEFT JOIN (
        SELECT z.DocNum, SUM(z.peso) AS PesoEstimado FROM (
            -- OV
            SELECT t0.DocNum, SUM(ISNULL(t3.QtyOrdered,0) * ISNULL(t4.UnitMass, 0)) AS peso
            FROM [server-sql].sbopym.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
            LEFT JOIN [server-sql].sbopym.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
            LEFT JOIN [server-sql].lisa_sbopym.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_OV
            LEFT JOIN [server-sql].lisa_sbopym.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
            LEFT JOIN [server-sql].lisa_sbopym.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
            WHERE t1.U_Tipo_Documento = 'OV' GROUP BY t0.DocNum
            UNION ALL
            -- TR (traslados) — también cuentan en el peso
            SELECT t0.DocNum, SUM(ISNULL(t3.QtyToTransfer,0) * ISNULL(t4.UnitMass, 0)) AS peso
            FROM [server-sql].sbopym.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
            LEFT JOIN [server-sql].sbopym.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
            LEFT JOIN [server-sql].lisa_sbopym.dbo.[TransferRequest] t2 WITH (NOLOCK) ON t2.DocNum = t1.U_No_OV
            LEFT JOIN [server-sql].lisa_sbopym.dbo.[TransferRequestLines] t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
            LEFT JOIN [server-sql].lisa_sbopym.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
            WHERE t1.U_Tipo_Documento IN ('TR','RESURTIDO') GROUP BY t0.DocNum
        ) z GROUP BY z.DocNum
    ) peso ON peso.DocNum = src.DocNum
    WHERE cd.Pais = 'HN' AND cd.Codigo = '01'
      AND src.u_estado IN ('01', '02') AND src.CreateDate > GETDATE() - 5
      AND NOT EXISTS (SELECT 1 FROM dbo.OrderRoutePlan orp WHERE orp.RouteNumber = src.DocNum AND orp.Pais = 'HN');

    -- ========================================
    -- Guatemala / Escuintla (sboferco, bodega 138, Pais GT) — modo pedido
    -- (Zona 5 / 01 NO entra aquí; sigue en modo producto)
    -- ========================================
    -- Cuadro de reacomodo (último minuto): si NACE despachado entra CERRADO
    -- (Finalizado + Despachado), no a la cola de picking — su mercadería ya se pickeó
    -- en el cuadro original. "Nace despachado" = u_estado '03' (ya salió; en 138 todos
    -- los '03' traen placa) O ya trae placa. OJO: por eso la ingestión abajo incluye
    -- u_estado IN ('02','03') — los '03' que saltan la ventana de '02' (reacomodos
    -- rápidos) entraban antes NUNCA; ahora entran cerrados.
    -- Fecha de cierre = src.CreateDate (día real del cuadro), NO GETDATE: así un
    -- backfill de cuadros de días previos cae en su día y no infla el despacho de hoy.
    -- El trigger TR_OrderRoutePlan_EstadosFechas es AFTER UPDATE, así que un INSERT
    -- directo en 'Finalizado' NO dispara SP_AddOrderRouteTasks (sin tareas fantasma).
    -- Solo GT/Escuintla. Un cuadro que gana placa DESPUÉS (ya ingestado en '02') sigue
    -- el flujo normal (picking -> SP_AutoDespachoEscuintla).
    INSERT INTO dbo.OrderRoutePlan (RouteNumber, RouteName, FechaPlanificacion, AlmacenOrigen, ID_Centro, Pais, PesoEstimado,
                                    Estado, EstadoDespacho, FechaInicio, FechaFin, FechaDespachoFin)
    SELECT src.DocNum, ISNULL(src.U_NombreR, 'Ruta ' + CAST(src.DocNum AS NVARCHAR(20))), GETDATE(), '138', cd.ID_Centro, 'GT', ISNULL(peso.PesoEstimado, 0),
           CASE WHEN src.u_estado = '03' OR LTRIM(RTRIM(ISNULL(src.U_Placa, ''))) <> '' THEN 'Finalizado' ELSE 'Pendiente' END,
           CASE WHEN src.u_estado = '03' OR LTRIM(RTRIM(ISNULL(src.U_Placa, ''))) <> '' THEN 'Finalizado' ELSE 'Pendiente' END,
           CASE WHEN src.u_estado = '03' OR LTRIM(RTRIM(ISNULL(src.U_Placa, ''))) <> '' THEN src.CreateDate ELSE NULL END,
           CASE WHEN src.u_estado = '03' OR LTRIM(RTRIM(ISNULL(src.U_Placa, ''))) <> '' THEN src.CreateDate ELSE NULL END,
           CASE WHEN src.u_estado = '03' OR LTRIM(RTRIM(ISNULL(src.U_Placa, ''))) <> '' THEN src.CreateDate ELSE NULL END
    FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] AS src WITH (NOLOCK)
    CROSS JOIN dbo.CentroDistribucion cd
    LEFT JOIN (
        SELECT z.DocNum, SUM(z.peso) AS PesoEstimado FROM (
            -- OV
            SELECT t0.DocNum, SUM(ISNULL(t3.QtyOrdered,0) * ISNULL(t4.UnitMass, 0)) AS peso
            FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] t0 WITH (NOLOCK)
            LEFT JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
            LEFT JOIN [server-sql].lisa_sboferco.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_OV
            LEFT JOIN [server-sql].lisa_sboferco.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
            LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
            WHERE t1.U_Tipo_Documento = 'OV' AND t4.InternIdProduct <> '013956' GROUP BY t0.DocNum
            UNION ALL
            -- TR (traslados) — también cuentan en el peso
            SELECT t0.DocNum, SUM(ISNULL(t3.QtyToTransfer,0) * ISNULL(t4.UnitMass, 0)) AS peso
            FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] t0 WITH (NOLOCK)
            LEFT JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
            LEFT JOIN [server-sql].lisa_sboferco.dbo.[TransferRequest] t2 WITH (NOLOCK) ON t2.DocNum = t1.U_No_OV
            LEFT JOIN [server-sql].lisa_sboferco.dbo.[TransferRequestLines] t3 WITH (NOLOCK) ON t3.IdTransferRequest = t2.IdTransferRequest
            LEFT JOIN [server-sql].lisa_sboferco.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
            WHERE t1.U_Tipo_Documento IN ('TR','RESURTIDO') AND t4.InternIdProduct <> '013956' GROUP BY t0.DocNum
        ) z GROUP BY z.DocNum
    ) peso ON peso.DocNum = src.DocNum
    WHERE cd.Pais = 'GT' AND cd.Codigo = '138'
      AND src.u_estado IN ('02', '03') AND src.CreateDate > GETDATE() - 5
      AND src.U_Almacen_Origen = '138'
      AND NOT EXISTS (SELECT 1 FROM dbo.OrderRoutePlan orp WHERE orp.RouteNumber = src.DocNum AND orp.Pais = 'GT');

    -- Materializar líneas/documentos de los cuadros GT/Escuintla recién ingestados
    -- (y de cualquier Pendiente que aún no las tenga), vía reimport. Así se ven los
    -- documentos, líneas y peso ANTES de iniciar, para priorizar.
    EXEC dbo.SP_MaterializeOrderLinesEscuintla;
END;
GO
