-- ============================================================
-- Vista analítica ÚNICA de Picking para el DW (base DW_VENTA)
-- Se ejecuta EN DW_VENTA; lee de Picking_Management (mismo server).
--
--   dbo.v_Picking  -> 1 fila por TAREA (grano más fino).
--   Trae también los datos de la RUTA (denormalizados) para que
--   Tableau calcule todo desde un solo origen.
--
-- CÓMO USARLA EN TABLEAU:
--   • Métricas por TAREA / persona : usa TODAS las filas.
--       - DuracionAsigFinMin = tiempo asignación -> fin de la tarea.
--   • Métricas por RUTA            : filtra EsRepresentanteRuta = 1
--       (1 fila por ruta) para no multiplicar.
--       - CicloLeadMin   = "Iniciar Ruta" -> cierre de ruta (lead time).
--       - CicloActivoMin = 1ª asignación -> última tarea (trabajo real).
--
-- Tiempos: FechaAsignacion (momento en que se asigna el pedido/producto
--   al operario) y FechaFinTarea (UltimaActualizacion al completarse).
--   Todo dentro de Picking_Management (no depende de Lisa).
--
-- Colación: DW_VENTA=CP1, Picking_Management=CP850 -> joins numéricos y
--   COLLATE CP1 en columnas de texto de salida.
-- ============================================================
IF OBJECT_ID('dbo.v_Picking_CicloRuta') IS NOT NULL DROP VIEW dbo.v_Picking_CicloRuta;
IF OBJECT_ID('dbo.v_Picking_Tarea')     IS NOT NULL DROP VIEW dbo.v_Picking_Tarea;
GO

CREATE OR ALTER VIEW dbo.v_Picking AS
WITH base AS (
    -- ═══ Modo PEDIDO (order) ═══
    SELECT
        t.ID_Task,
        t.Pais       COLLATE SQL_Latin1_General_CP1_CI_AS AS Pais,
        t.ID_Centro,
        CAST('Pedido' AS NVARCHAR(12))                    AS Modo,
        t.RouteNumber,
        t.ID_Operario,
        CAST(t.DocType AS NVARCHAR(10)) COLLATE SQL_Latin1_General_CP1_CI_AS AS DocType,
        t.Cantidad,
        opm.FechaAsignacion,
        t.UltimaActualizacion AS FechaFinTarea,
        orp.FechaInicio       AS RutaInicio,
        orp.FechaFin          AS RutaFin
    FROM Picking_Management.dbo.OrderPickingTask t
    INNER JOIN Picking_Management.dbo.OrderPickingManagement opm
            ON opm.ID_OrderPicking = t.ID_OrderPicking
    INNER JOIN Picking_Management.dbo.OrderRoutePlan orp
            ON orp.ID_RoutePlan = opm.ID_RoutePlan
    WHERE t.Estado = 'Finalizado' AND t.UltimaActualizacion IS NOT NULL

    UNION ALL

    -- ═══ Modo PRODUCTO (Zona 5) ═══
    SELECT
        t.ID_Task,
        CAST('GT' AS NVARCHAR(10))                        AS Pais,
        c.ID_Centro,
        CAST('Producto' AS NVARCHAR(12))                  AS Modo,
        TRY_CAST(t.Route_Number AS INT)                   AS RouteNumber,
        t.ID_Operario,
        CAST(t.DocType AS NVARCHAR(10)) COLLATE SQL_Latin1_General_CP1_CI_AS AS DocType,
        t.Cantidad,
        rpm.FechaAsignacion,
        t.UltimaActualizacion AS FechaFinTarea,
        rp.FechaInicio        AS RutaInicio,
        rp.FechaFin           AS RutaFin
    FROM Picking_Management.dbo.RoutePickingTask t
    LEFT JOIN Picking_Management.dbo.RoutePickingManagement rpm
           ON rpm.RouteNumber = TRY_CAST(t.Route_Number AS INT)
          AND rpm.Product = t.InternIdProduct
    LEFT JOIN Picking_Management.dbo.RoutePlan rp
           ON rp.RouteNumber = TRY_CAST(t.Route_Number AS INT)
    LEFT JOIN Picking_Management.dbo.CentroDistribucion c
           ON c.Codigo = rp.AlmacenOrigen AND c.Modo = 'product'
    WHERE t.Estado = 'Finalizado' AND t.UltimaActualizacion IS NOT NULL
)
SELECT
    -- ── Dimensiones ──
    b.Pais,
    CAST(cd.Nombre AS NVARCHAR(120)) COLLATE SQL_Latin1_General_CP1_CI_AS AS CEDI,
    b.Modo,
    b.ID_Centro,
    CAST(b.FechaFinTarea AS DATE)                                         AS Fecha,
    b.RouteNumber,
    -- ── Tarea ──
    b.ID_Task,
    b.ID_Operario,
    CAST(op.Nombre AS NVARCHAR(120)) COLLATE SQL_Latin1_General_CP1_CI_AS AS Operario,
    b.DocType,
    b.Cantidad,
    b.FechaAsignacion,
    b.FechaFinTarea,
    DATEDIFF(SECOND, b.FechaAsignacion, b.FechaFinTarea)                  AS DuracionAsigFinSeg,
    CAST(DATEDIFF(SECOND, b.FechaAsignacion, b.FechaFinTarea)/60.0 AS DECIMAL(10,2)) AS DuracionAsigFinMin,
    -- ── Ruta (denormalizada; usar con EsRepresentanteRuta = 1) ──
    b.RutaInicio,
    b.RutaFin,
    DATEDIFF(MINUTE, b.RutaInicio, b.RutaFin)                             AS CicloLeadMin,
    DATEDIFF(MINUTE,
        MIN(b.FechaAsignacion) OVER (PARTITION BY b.Modo, b.ID_Centro, b.RouteNumber),
        MAX(b.FechaFinTarea)   OVER (PARTITION BY b.Modo, b.ID_Centro, b.RouteNumber)) AS CicloActivoMin,
    CASE WHEN ROW_NUMBER() OVER (
            PARTITION BY b.Modo, b.ID_Centro, b.RouteNumber
            ORDER BY b.ID_Task) = 1 THEN 1 ELSE 0 END                    AS EsRepresentanteRuta
FROM base b
LEFT JOIN Picking_Management.dbo.Operario op ON op.ID_Operario = b.ID_Operario
LEFT JOIN Picking_Management.dbo.CentroDistribucion cd ON cd.ID_Centro = b.ID_Centro;
GO
