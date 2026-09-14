-- ============================================================
-- Cierre puntual del backlog de despacho de Zona 5 (centro 1, producto).
-- Rutas con picking FINALIZADO que nunca se marcaron despachadas y que
-- son viejas (planificadas hace >2 días) -> EstadoDespacho='Finalizado'
-- con FechaDespachoFin histórica (FechaFin real).
-- Conserva: rutas Iniciado (picking en curso) y finalizadas de <2 días.
-- Ejecución única (aplicado 2026-09-14). Cerró 2,711 rutas.
-- ============================================================
UPDATE rp
SET rp.EstadoDespacho = 'Finalizado',
    rp.FechaDespachoFin = ISNULL(rp.FechaFin, rp.FechaPlanificacion)
FROM dbo.RoutePlan rp
JOIN dbo.Carril c ON c.ID_Carril = rp.ID_Carril
WHERE c.ID_Centro = 1
  AND rp.Estado = 'Finalizado'
  AND rp.EstadoDespacho IN ('Pendiente', 'Listo para Carga')
  AND rp.FechaPlanificacion < DATEADD(DAY, -2, GETDATE());
