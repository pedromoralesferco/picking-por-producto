-- ============================================================
-- Backfill: renombrar complementos con nombre genérico ("COMP" / "COMP-<n>")
-- al nombre de su ruta de origen + " - COMP" (ej. "COMP-36365" -> "30OCT MIXCO 3.5T - COMP").
--
-- - Solo toca cuadros EsComplemento=1 cuyo RouteName es genérico ('COMP' o 'COMP-%').
--   Los complementos que ya tienen nombre propio ("... - COMP", "27OCT PAQUETERIA", etc.)
--   NO se tocan.
-- - Resuelve la CADENA de ComplementoDe hasta la primera ruta con nombre real
--   (complemento de complemento -> "<raíz> - COMP", sin duplicar el sufijo).
-- - Picking_Management (NO escribe a SAP). Idempotente: correrlo de nuevo no cambia nada.
-- ============================================================

;WITH ORP AS (
    SELECT ID_RoutePlan, RouteNumber, RouteName, ComplementoDe, ISNULL(EsComplemento,0) AS EsComplemento
    FROM dbo.OrderRoutePlan
    WHERE ID_Centro = 3 AND Pais = 'GT'
),
-- Complementos con nombre genérico que hay que renombrar
Target AS (
    SELECT ID_RoutePlan, RouteNumber, ComplementoDe
    FROM ORP
    WHERE EsComplemento = 1
      AND (RouteName = 'COMP' OR RouteName LIKE 'COMP-%')
      AND ComplementoDe IS NOT NULL
),
-- Subir por ComplementoDe hasta encontrar un nombre "real" (no genérico)
Walk AS (
    SELECT t.ID_RoutePlan AS TargetID, p.RouteNumber AS CurRN, p.RouteName AS CurName,
           p.ComplementoDe AS CurDe, 0 AS lvl
    FROM Target t
    JOIN ORP p ON p.RouteNumber = t.ComplementoDe
    UNION ALL
    SELECT w.TargetID, p.RouteNumber, p.RouteName, p.ComplementoDe, w.lvl + 1
    FROM Walk w
    JOIN ORP p ON p.RouteNumber = w.CurDe
    WHERE (w.CurName = 'COMP' OR w.CurName LIKE 'COMP-%')   -- el nodo actual aún es genérico → seguir subiendo
      AND w.CurDe IS NOT NULL
      AND w.lvl < 10
),
-- Primer ancestro con nombre real por cada complemento
Root AS (
    SELECT TargetID, CurName AS RootName,
           ROW_NUMBER() OVER (PARTITION BY TargetID
               ORDER BY CASE WHEN CurName = 'COMP' OR CurName LIKE 'COMP-%' THEN 1 ELSE 0 END, lvl) AS rk
    FROM Walk
)
UPDATE orp
SET RouteName = LEFT(LTRIM(RTRIM(
        CASE WHEN r.RootName LIKE '%- COMP'
             THEN LEFT(r.RootName, LEN(r.RootName) - LEN(' - COMP'))
             ELSE r.RootName END)), 66) + ' - COMP'
FROM dbo.OrderRoutePlan orp
JOIN Root r ON r.TargetID = orp.ID_RoutePlan AND r.rk = 1
WHERE r.RootName IS NOT NULL
  AND NOT (r.RootName = 'COMP' OR r.RootName LIKE 'COMP-%');

PRINT 'Backfill nombres de complemento: OK (' + CAST(@@ROWCOUNT AS NVARCHAR(10)) + ' renombrados)';
