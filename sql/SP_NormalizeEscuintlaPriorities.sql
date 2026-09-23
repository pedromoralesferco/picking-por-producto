-- ============================================================
-- SP_NormalizeEscuintlaPriorities
--
-- Mantiene las prioridades de HUB Escuintla (ID_Centro=3) siempre
-- CONTIGUAS empezando en 1 (1,2,3…), sin huecos.
--
-- Considera solo las rutas ACTIVAS (Estado Pendiente/Iniciado) con
-- Prioridad asignada. Al recompactar preserva el orden relativo
-- (por Prioridad actual, y a igualdad por fecha de planificación).
--
-- Cuando una ruta priorizada se completa (pasa a Finalizado) o se le
-- quita la prioridad, deja de contar → las demás se recorren hacia
-- arriba (la prioridad 2 pasa a ser la nueva prioridad 1, etc.).
--
-- Idempotente y barato: solo escribe las filas cuyo número cambia;
-- si ya están contiguas, no toca nada.
-- ============================================================
IF OBJECT_ID('dbo.SP_NormalizeEscuintlaPriorities') IS NOT NULL
    DROP PROCEDURE dbo.SP_NormalizeEscuintlaPriorities;
GO
CREATE PROCEDURE [dbo].[SP_NormalizeEscuintlaPriorities]
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH ranked AS (
        SELECT
            ID_RoutePlan,
            Prioridad,
            ROW_NUMBER() OVER (ORDER BY Prioridad, FechaPlanificacion DESC, ID_RoutePlan) AS nueva
        FROM dbo.OrderRoutePlan
        WHERE ID_Centro = 3
          AND Estado IN ('Pendiente', 'Iniciado')
          AND Prioridad IS NOT NULL
    )
    UPDATE r
    SET r.Prioridad = k.nueva
    FROM dbo.OrderRoutePlan r
    INNER JOIN ranked k ON k.ID_RoutePlan = r.ID_RoutePlan
    WHERE r.Prioridad <> k.nueva;
END;
GO
