-- ============================================================
-- Corrección puntual: complementos que el limpiador de huérfanos
-- (SP_LimpiarHuerfanosEscuintla) cerró por error mientras estaban en
-- provisional (RouteNumber negativo, antes de sincronizarse a SAP).
--
-- Un complemento es un cuadro NUEVO: su picking viene completo (los docs
-- llegan ya pickeados), pero su DESPACHO debe estar pendiente. El limpiador
-- los marcó EstadoDespacho='Finalizado' con FechaDespachoFin = FechaFin
-- (su firma). Aquí los reabrimos a 'Pendiente de despachar'.
--
-- Solo toca los que NO fueron despachados de verdad (FechaDespachoFin = FechaFin).
-- Picking (Estado) se deja como está (Finalizado = picking hecho).
-- Ejecutar una sola vez en SSMS. Afecta ~35 cuadros.
-- El fix de raíz está en SP_LimpiarHuerfanosEscuintla.sql (ya no los cierra).
-- ============================================================
UPDATE orp
SET orp.EstadoDespacho  = 'Pendiente',
    orp.FechaDespachoFin = NULL
FROM dbo.OrderRoutePlan orp
WHERE orp.ID_Centro = 3 AND orp.Pais = 'GT'
  AND ISNULL(orp.EsComplemento, 0) = 1
  AND orp.RouteNumber > 0
  AND orp.EstadoDespacho = 'Finalizado'
  AND (orp.FechaDespachoFin = orp.FechaFin OR orp.FechaDespachoFin IS NULL);

PRINT 'Complementos reabiertos a Pendiente de despachar: ' + CAST(@@ROWCOUNT AS VARCHAR(10));
