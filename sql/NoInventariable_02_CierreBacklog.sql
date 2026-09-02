-- ============================================================
-- Backlog: cerrar líneas NO INVENTARIABLES ya atascadas (order) y los
-- pedidos/rutas que quedaban bloqueados solo por ellas.
-- Ejecución única (aplicado 2026-09). Detección por OITM.InvntItem='N'.
-- ============================================================

-- 1) Cerrar líneas no-inventariables aún abiertas (por país -> su OITM)
UPDATE t SET t.CantidadPendiente = 0, t.Estado = 'Finalizado'
FROM dbo.OrderPickingTask t
JOIN [server-sql].sbointergres.dbo.OITM o WITH (NOLOCK)
     ON o.ItemCode COLLATE DATABASE_DEFAULT = t.InternIdProduct COLLATE DATABASE_DEFAULT
WHERE t.Pais = 'SV' AND t.Estado <> 'Finalizado' AND ISNULL(t.CantidadPendiente,0) > 0 AND o.InvntItem = 'N';

UPDATE t SET t.CantidadPendiente = 0, t.Estado = 'Finalizado'
FROM dbo.OrderPickingTask t
JOIN [server-sql].sbopym.dbo.OITM o WITH (NOLOCK)
     ON o.ItemCode COLLATE DATABASE_DEFAULT = t.InternIdProduct COLLATE DATABASE_DEFAULT
WHERE t.Pais = 'HN' AND t.Estado <> 'Finalizado' AND ISNULL(t.CantidadPendiente,0) > 0 AND o.InvntItem = 'N';

UPDATE t SET t.CantidadPendiente = 0, t.Estado = 'Finalizado'
FROM dbo.OrderPickingTask t
JOIN [server-sql].sboferco.dbo.OITM o WITH (NOLOCK)
     ON o.ItemCode COLLATE DATABASE_DEFAULT = t.InternIdProduct COLLATE DATABASE_DEFAULT
WHERE t.Pais = 'GT' AND t.Estado <> 'Finalizado' AND ISNULL(t.CantidadPendiente,0) > 0 AND o.InvntItem = 'N';

-- 2) Cerrar pedidos 100% completos (FechaFin histórica = última act. de sus tareas)
UPDATE opm SET Estado = 'Finalizado', FechaFin = x.FechaFin
FROM dbo.OrderPickingManagement opm
INNER JOIN (SELECT ID_OrderPicking, MAX(UltimaActualizacion) AS FechaFin
            FROM dbo.OrderPickingTask GROUP BY ID_OrderPicking) x ON x.ID_OrderPicking = opm.ID_OrderPicking
WHERE opm.Estado <> 'Finalizado'
  AND EXISTS (SELECT 1 FROM dbo.OrderPickingTask t WHERE t.ID_OrderPicking = opm.ID_OrderPicking)
  AND NOT EXISTS (SELECT 1 FROM dbo.OrderPickingTask t WHERE t.ID_OrderPicking = opm.ID_OrderPicking AND ISNULL(t.CantidadPendiente,0) > 0);

-- 3) Cerrar rutas cuyos pedidos están todos finalizados
UPDATE orp SET Estado = 'Finalizado', FechaFin = x.FechaFin
FROM dbo.OrderRoutePlan orp
INNER JOIN (SELECT ID_RoutePlan, MAX(FechaFin) AS FechaFin
            FROM dbo.OrderPickingManagement GROUP BY ID_RoutePlan) x ON x.ID_RoutePlan = orp.ID_RoutePlan
WHERE orp.Estado <> 'Finalizado'
  AND EXISTS (SELECT 1 FROM dbo.OrderPickingManagement o WHERE o.ID_RoutePlan = orp.ID_RoutePlan)
  AND NOT EXISTS (SELECT 1 FROM dbo.OrderPickingManagement o WHERE o.ID_RoutePlan = orp.ID_RoutePlan AND o.Estado <> 'Finalizado');
