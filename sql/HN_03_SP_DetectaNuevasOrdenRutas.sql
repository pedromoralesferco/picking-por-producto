-- ============================================================
-- Honduras (HN) — Paso 3: SP_DetectaNuevasOrdenRutas
-- Agrega el bloque que inserta rutas nuevas de Honduras
-- (sbopym, CEDI 01) en OrderRoutePlan.
-- El bloque GT sigue comentado; SV sin cambios.
-- Este SP normalmente lo ejecuta un Job del Agente SQL.
-- ============================================================
ALTER PROCEDURE [dbo].[SP_DetectaNuevasOrdenRutas]
AS
BEGIN
    SET NOCOUNT ON;

    -- ========================================
    -- Guatemala (sboferco, Almacen 01, Pais GT) — (desactivado)
    -- ========================================
    -- (bloque GT comentado en la versión vigente; se mantiene igual)

    -- ========================================
    -- El Salvador (sbointergres, Pais SV)
    -- ========================================
    INSERT INTO dbo.OrderRoutePlan (
        RouteNumber, RouteName, FechaPlanificacion, AlmacenOrigen,
        ID_Centro, Pais, PesoEstimado
    )
    SELECT
        src.DocNum,
        ISNULL(src.U_NombreR, 'Ruta ' + CAST(src.DocNum AS NVARCHAR(20))),
        GETDATE(),
        '67',
        cd.ID_Centro,
        'SV',
        ISNULL(peso.PesoEstimado, 0)
    FROM [server-sql].sbointergres.dbo.[@CUADRO_RUTA_E] AS src WITH (NOLOCK)
    CROSS JOIN dbo.CentroDistribucion cd
    LEFT JOIN (
        SELECT t0.DocNum, SUM(t3.QtyOrdered * ISNULL(t4.UnitMass, 0)) AS PesoEstimado
        FROM [server-sql].sbointergres.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbointergres.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_OV
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
        LEFT JOIN [server-sql].lisa_sbointergres.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        WHERE t1.U_Tipo_Documento = 'OV'
        GROUP BY t0.DocNum
    ) peso ON peso.DocNum = src.DocNum
    WHERE cd.Pais = 'SV' AND cd.Codigo = '67'
      AND src.u_estado = '02'
      AND src.CreateDate > GETDATE() - 5
      AND NOT EXISTS (
            SELECT 1 FROM dbo.OrderRoutePlan orp
            WHERE orp.RouteNumber = src.DocNum AND orp.Pais = 'SV'
      );

    -- ========================================
    -- Honduras (sbopym, CEDI 01, Pais HN) — NUEVO
    -- ========================================
    INSERT INTO dbo.OrderRoutePlan (
        RouteNumber, RouteName, FechaPlanificacion, AlmacenOrigen,
        ID_Centro, Pais, PesoEstimado
    )
    SELECT
        src.DocNum,
        ISNULL(src.U_NombreR, 'Ruta ' + CAST(src.DocNum AS NVARCHAR(20))),
        GETDATE(),
        '01',
        cd.ID_Centro,
        'HN',
        ISNULL(peso.PesoEstimado, 0)
    FROM [server-sql].sbopym.dbo.[@CUADRO_RUTA_E] AS src WITH (NOLOCK)
    CROSS JOIN dbo.CentroDistribucion cd
    LEFT JOIN (
        SELECT t0.DocNum, SUM(t3.QtyOrdered * ISNULL(t4.UnitMass, 0)) AS PesoEstimado
        FROM [server-sql].sbopym.dbo.[@CUADRO_RUTA_E] t0 WITH (NOLOCK)
        LEFT JOIN [server-sql].sbopym.dbo.[@CUADRO_RUTA_D] t1 WITH (NOLOCK) ON t1.DocEntry = t0.DocEntry
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[CustomerOrder] t2 WITH (NOLOCK) ON t2.IdAccountableOrder = t1.U_No_OV
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[CustomerOrderLine] t3 WITH (NOLOCK) ON t3.IdCustomerOrder = t2.IdCustomerOrder
        LEFT JOIN [server-sql].lisa_sbopym.dbo.[Product] t4 WITH (NOLOCK) ON t4.IdProduct = t3.IdProduct
        WHERE t1.U_Tipo_Documento = 'OV'
        GROUP BY t0.DocNum
    ) peso ON peso.DocNum = src.DocNum
    WHERE cd.Pais = 'HN' AND cd.Codigo = '01'
      AND src.u_estado IN ('01', '02')   -- HN: toma rutas en estado 01 o 02
      AND src.CreateDate > GETDATE() - 5
      -- Si el CEDI Tegus debe filtrarse por almacén de origen, descomentar:
      -- AND src.U_Almacen_Origen = '01'
      AND NOT EXISTS (
            SELECT 1 FROM dbo.OrderRoutePlan orp
            WHERE orp.RouteNumber = src.DocNum AND orp.Pais = 'HN'
      );
END;
GO
