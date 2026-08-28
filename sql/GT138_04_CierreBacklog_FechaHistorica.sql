-- ============================================================
-- Cierre puntual del backlog de tareas/pedidos/rutas que quedaron
-- 100% completos pero abiertos (por el bug de colación en el SP de
-- refresco que abortaba el cierre-red-de-seguridad).
--
-- Clave: la FechaFin se pone con la fecha REAL de completado
-- (última modificación), NO con GETDATE(), para no falsear que se
-- cerraron "hoy".
--
-- Truco anti-trigger: los triggers TR_OrderPickingMgmt_Asignacion y
-- TR_OrderRoutePlan_EstadosFechas ponen FechaFin=GETDATE() SOLO si
-- FechaFin IS NULL. Al setear FechaFin explícito (histórico) en el
-- mismo UPDATE, ya no es NULL -> el trigger no lo sobreescribe.
-- Las tareas se cierran cambiando solo Estado (sin tocar
-- CantidadPendiente ni UltimaActualizacion) para conservar su fecha.
--
-- Ejecución única. Ya ejecutado el 2026-08-27.
-- ============================================================
BEGIN TRAN;

-- 1) Tareas 100% completas pero abiertas -> Finalizado (conserva UltimaActualizacion)
UPDATE OrderPickingTask SET Estado = 'Finalizado'
WHERE ISNULL(CantidadPendiente, 0) = 0 AND Estado <> 'Finalizado';

-- 2) Pedidos con todas sus tareas completas -> Finalizado con FechaFin histórico
UPDATE opm SET Estado = 'Finalizado', FechaFin = x.FechaFin
FROM OrderPickingManagement opm
INNER JOIN (
    SELECT ID_OrderPicking, MAX(UltimaActualizacion) AS FechaFin
    FROM OrderPickingTask GROUP BY ID_OrderPicking
) x ON x.ID_OrderPicking = opm.ID_OrderPicking
WHERE opm.Estado <> 'Finalizado'
  AND EXISTS (SELECT 1 FROM OrderPickingTask t WHERE t.ID_OrderPicking = opm.ID_OrderPicking)
  AND NOT EXISTS (SELECT 1 FROM OrderPickingTask t WHERE t.ID_OrderPicking = opm.ID_OrderPicking AND ISNULL(t.CantidadPendiente, 0) > 0);

-- 3) Rutas con todos sus pedidos finalizados -> Finalizado con FechaFin histórico
UPDATE orp SET Estado = 'Finalizado', FechaFin = x.FechaFin
FROM OrderRoutePlan orp
INNER JOIN (
    SELECT ID_RoutePlan, MAX(FechaFin) AS FechaFin
    FROM OrderPickingManagement GROUP BY ID_RoutePlan
) x ON x.ID_RoutePlan = orp.ID_RoutePlan
WHERE orp.Estado <> 'Finalizado'
  AND EXISTS (SELECT 1 FROM OrderPickingManagement o WHERE o.ID_RoutePlan = orp.ID_RoutePlan)
  AND NOT EXISTS (SELECT 1 FROM OrderPickingManagement o WHERE o.ID_RoutePlan = orp.ID_RoutePlan AND o.Estado <> 'Finalizado');

COMMIT;
