-- ============================================================
-- Vistas analíticas de Picking para el DW (base DW_VENTA)
-- Se ejecutan EN DW_VENTA; leen de Picking_Management (mismo server).
--
-- Diseño al GRANO (no totales), para medir dispersión en Tableau:
--   v_Picking_CicloRuta : 1 fila por ruta  -> ciclo por ruta/día
--   v_Picking_Tarea     : 1 fila por tarea -> tiempo por tarea / persona
--
-- Notas de colación: DW_VENTA=CP1, Picking_Management=CP850.
--   - Los JOIN entre bases son por claves NUMÉRICAS (o TRY_CAST) para
--     evitar conflictos de colación.
--   - Las columnas de texto de salida se normalizan a CP1 con COLLATE
--     para que integren nativo en el DW.
-- ============================================================

-- ══════════════════════════════════════════════════════════
-- 1) CICLO POR RUTA  (grano: ruta con inicio y fin de picking)
-- ══════════════════════════════════════════════════════════
CREATE OR ALTER VIEW dbo.v_Picking_CicloRuta AS
-- ---- Modo PEDIDO (order) ----
SELECT
    orp.Pais            COLLATE SQL_Latin1_General_CP1_CI_AS               AS Pais,
    CAST(cd.Nombre AS NVARCHAR(120)) COLLATE SQL_Latin1_General_CP1_CI_AS AS CEDI,
    CAST('Pedido' AS NVARCHAR(12))                                        AS Modo,
    orp.ID_Centro,
    CAST(orp.FechaInicio AS DATE)                                         AS Fecha,
    orp.RouteNumber,
    orp.FechaInicio,
    orp.FechaFin,
    DATEDIFF(MINUTE, orp.FechaInicio, orp.FechaFin)                       AS CicloMin,
    CAST(DATEDIFF(SECOND, orp.FechaInicio, orp.FechaFin)/3600.0 AS DECIMAL(10,2)) AS CicloHoras,
    (SELECT COUNT(*)              FROM Picking_Management.dbo.OrderPickingTask t
       WHERE t.RouteNumber = orp.RouteNumber AND t.ID_Centro = orp.ID_Centro)      AS NumTareas,
    (SELECT ISNULL(SUM(t.Cantidad),0) FROM Picking_Management.dbo.OrderPickingTask t
       WHERE t.RouteNumber = orp.RouteNumber AND t.ID_Centro = orp.ID_Centro)      AS Unidades
FROM Picking_Management.dbo.OrderRoutePlan orp
LEFT JOIN Picking_Management.dbo.CentroDistribucion cd ON cd.ID_Centro = orp.ID_Centro
WHERE orp.FechaInicio IS NOT NULL AND orp.FechaFin IS NOT NULL

UNION ALL

-- ---- Modo PRODUCTO (Zona 5) ----
SELECT
    CAST('GT' AS NVARCHAR(10))                                            AS Pais,
    CAST(COALESCE(cd.Nombre, 'Almacén ' + rp.AlmacenOrigen) AS NVARCHAR(120))
        COLLATE SQL_Latin1_General_CP1_CI_AS                             AS CEDI,
    CAST('Producto' AS NVARCHAR(12))                                     AS Modo,
    cd.ID_Centro,
    CAST(rp.FechaInicio AS DATE)                                         AS Fecha,
    rp.RouteNumber,
    rp.FechaInicio,
    rp.FechaFin,
    DATEDIFF(MINUTE, rp.FechaInicio, rp.FechaFin)                        AS CicloMin,
    CAST(DATEDIFF(SECOND, rp.FechaInicio, rp.FechaFin)/3600.0 AS DECIMAL(10,2)) AS CicloHoras,
    (SELECT COUNT(*)              FROM Picking_Management.dbo.RoutePickingTask t
       WHERE TRY_CAST(t.Route_Number AS INT) = rp.RouteNumber)          AS NumTareas,
    (SELECT ISNULL(SUM(t.Cantidad),0) FROM Picking_Management.dbo.RoutePickingTask t
       WHERE TRY_CAST(t.Route_Number AS INT) = rp.RouteNumber)          AS Unidades
FROM Picking_Management.dbo.RoutePlan rp
LEFT JOIN Picking_Management.dbo.CentroDistribucion cd
       ON cd.Codigo = rp.AlmacenOrigen AND cd.Modo = 'product'
WHERE rp.FechaInicio IS NOT NULL AND rp.FechaFin IS NOT NULL;
GO

-- ══════════════════════════════════════════════════════════
-- 2) TIEMPO POR TAREA  (grano: tarea finalizada)
--    DuracionTareaSeg = gap entre completados consecutivos del
--    MISMO operario en el MISMO día (proxy de ritmo por tarea).
--    La 1ª tarea del día por operario queda NULL (sin referencia).
--    OJO: incluye pausas/recorridos -> en Tableau usar MEDIANA y
--    percentiles, y filtrar outliers (p.ej. > 60 min).
-- ══════════════════════════════════════════════════════════
CREATE OR ALTER VIEW dbo.v_Picking_Tarea AS
WITH tareas AS (
    -- ---- Modo PEDIDO ----
    SELECT
        t.ID_Task,
        t.Pais       COLLATE SQL_Latin1_General_CP1_CI_AS AS Pais,
        t.ID_Centro,
        CAST('Pedido' AS NVARCHAR(12))                    AS Modo,
        t.RouteNumber,
        t.ID_Operario,
        CAST(t.DocType AS NVARCHAR(10)) COLLATE SQL_Latin1_General_CP1_CI_AS AS DocType,
        t.Cantidad,
        t.FechaLiberacion,
        t.UltimaActualizacion AS FechaFinTarea
    FROM Picking_Management.dbo.OrderPickingTask t
    WHERE t.Estado = 'Finalizado' AND t.UltimaActualizacion IS NOT NULL

    UNION ALL

    -- ---- Modo PRODUCTO ----
    SELECT
        t.ID_Task,
        CAST('GT' AS NVARCHAR(10))                        AS Pais,
        c.ID_Centro,
        CAST('Producto' AS NVARCHAR(12))                  AS Modo,
        TRY_CAST(t.Route_Number AS INT)                   AS RouteNumber,
        t.ID_Operario,
        CAST(t.DocType AS NVARCHAR(10)) COLLATE SQL_Latin1_General_CP1_CI_AS AS DocType,
        t.Cantidad,
        t.FechaLiberacion,
        t.UltimaActualizacion AS FechaFinTarea
    FROM Picking_Management.dbo.RoutePickingTask t
    LEFT JOIN Picking_Management.dbo.RoutePlan rp
           ON rp.RouteNumber = TRY_CAST(t.Route_Number AS INT)
    LEFT JOIN Picking_Management.dbo.CentroDistribucion c
           ON c.Codigo = rp.AlmacenOrigen AND c.Modo = 'product'
    WHERE t.Estado = 'Finalizado' AND t.UltimaActualizacion IS NOT NULL
)
SELECT
    ta.Pais,
    CAST(cd.Nombre AS NVARCHAR(120)) COLLATE SQL_Latin1_General_CP1_CI_AS AS CEDI,
    ta.Modo,
    ta.ID_Centro,
    CAST(ta.FechaFinTarea AS DATE)                                        AS Fecha,
    ta.RouteNumber,
    ta.ID_Operario,
    CAST(op.Nombre AS NVARCHAR(120)) COLLATE SQL_Latin1_General_CP1_CI_AS AS Operario,
    ta.DocType,
    ta.Cantidad,
    ta.FechaLiberacion,
    ta.FechaFinTarea,
    DATEDIFF(SECOND,
        LAG(ta.FechaFinTarea) OVER (
            PARTITION BY ta.ID_Operario, CAST(ta.FechaFinTarea AS DATE)
            ORDER BY ta.FechaFinTarea),
        ta.FechaFinTarea)                                                 AS DuracionTareaSeg,
    CAST(DATEDIFF(SECOND,
        LAG(ta.FechaFinTarea) OVER (
            PARTITION BY ta.ID_Operario, CAST(ta.FechaFinTarea AS DATE)
            ORDER BY ta.FechaFinTarea),
        ta.FechaFinTarea)/60.0 AS DECIMAL(10,2))                          AS DuracionTareaMin
FROM tareas ta
LEFT JOIN Picking_Management.dbo.Operario op ON op.ID_Operario = ta.ID_Operario
LEFT JOIN Picking_Management.dbo.CentroDistribucion cd ON cd.ID_Centro = ta.ID_Centro;
GO
