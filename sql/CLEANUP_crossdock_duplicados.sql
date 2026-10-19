-- ============================================================
-- LIMPIEZA de tareas/pedidos duplicados en la tanda "CROSSDOCK Z5"
-- y cuadros precargados por ingesta forzada (HUB Escuintla).
-- ------------------------------------------------------------
-- Contexto: estos cuadros recibieron pedidos+tareas por ingesta forzada
-- estando en 'Pendiente'. Al iniciarlos, el trigger volvió a crear todo
-- (SP_AddOrderRouteTasks no deduplicaba) -> triplicó cada línea.
--
-- ORDEN RECOMENDADO:
--   1) Aplicar primero  sql/HARDEN_SP_AddOrderRouteTasks.sql
--      (con eso los cuadros que aún NO se han iniciado ya no duplicarán
--       al iniciarse: el SP salta las líneas que ya existen).
--   2) Correr este script para limpiar lo YA duplicado.
--
-- Deja EXACTAMENTE 1 tarea por (RouteNumber, OV, Line_ID, Producto),
-- conservando la de mayor avance (Verificado > Finalizado > Asignado/
-- En Proceso > Pendiente; a igualdad, la más antigua). Luego borra los
-- pedidos (OPM) que queden sin tareas. Todo en transacción.
--
-- SOLO toca Picking_Management. Ajusta la lista @lote si hace falta.
-- ============================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @lote TABLE (RN INT);
INSERT @lote VALUES
    (34574),(34577),(34699),(34708),(34709),(34710),(34711),(34712),
    (34713),(34714),(34715),(34716),(34717),(34718),(34719),(34777),(34787);

-- ── Diagnóstico previo ────────────────────────────────────
PRINT '=== ANTES ===';
;WITH d AS (
    SELECT t.RouteNumber, t.OV_Number, t.Line_ID, t.IdProduct
    FROM dbo.OrderPickingTask t
    WHERE t.RouteNumber IN (SELECT RN FROM @lote)
    GROUP BY t.RouteNumber, t.OV_Number, t.Line_ID, t.IdProduct
    HAVING COUNT(*) > 1
)
SELECT (SELECT COUNT(*) FROM d) AS LineasDuplicadas,
       (SELECT COUNT(*) FROM dbo.OrderPickingTask WHERE RouteNumber IN (SELECT RN FROM @lote)) AS TareasTotales;

BEGIN TRAN;

    -- 1) Dedup de tareas: conservar 1 por línea (la de mayor avance)
    ;WITH r AS (
        SELECT t.ID_Task,
            ROW_NUMBER() OVER (
                PARTITION BY t.RouteNumber, t.OV_Number, t.Line_ID, t.IdProduct
                ORDER BY
                    CASE WHEN t.Verificado = 1 THEN 0 ELSE 1 END,
                    CASE t.Estado WHEN 'Finalizado' THEN 0
                                  WHEN 'Asignado'   THEN 1
                                  WHEN 'En Proceso' THEN 1
                                  ELSE 2 END,
                    t.ID_Task
            ) AS rn
        FROM dbo.OrderPickingTask t
        WHERE t.RouteNumber IN (SELECT RN FROM @lote)
    )
    DELETE FROM dbo.OrderPickingTask
    WHERE ID_Task IN (SELECT ID_Task FROM r WHERE rn > 1);
    PRINT 'Tareas duplicadas borradas: ' + CONVERT(varchar, @@ROWCOUNT);

    -- 2) Borrar pedidos (OPM) que quedaron sin tareas
    DELETE opm
    FROM dbo.OrderPickingManagement opm
    WHERE opm.RouteNumber IN (SELECT RN FROM @lote)
      AND NOT EXISTS (SELECT 1 FROM dbo.OrderPickingTask t
                      WHERE t.ID_OrderPicking = opm.ID_OrderPicking);
    PRINT 'Pedidos vacios borrados: ' + CONVERT(varchar, @@ROWCOUNT);

COMMIT;

-- ── Verificación ──────────────────────────────────────────
PRINT '=== DESPUES ===';
;WITH d2 AS (
    SELECT t.RouteNumber, t.OV_Number, t.Line_ID, t.IdProduct
    FROM dbo.OrderPickingTask t
    WHERE t.RouteNumber IN (SELECT RN FROM @lote)
    GROUP BY t.RouteNumber, t.OV_Number, t.Line_ID, t.IdProduct
    HAVING COUNT(*) > 1
)
SELECT (SELECT COUNT(*) FROM d2) AS LineasAunDuplicadas,   -- debe ser 0
       (SELECT COUNT(*) FROM dbo.OrderPickingTask WHERE RouteNumber IN (SELECT RN FROM @lote)) AS TareasTotales;
