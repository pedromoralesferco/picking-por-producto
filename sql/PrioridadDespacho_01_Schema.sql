-- ============================================================
-- Prioridad de DESPACHO por cuadro (HUB Escuintla)
--
-- Cola propia, separada de la prioridad de picking (OrderRoutePlan.Prioridad):
--   · Entra a la cola un cuadro con picking terminado y aún sin despachar
--     (Estado = 'Finalizado' y EstadoDespacho <> 'Finalizado').
--   · Al entrar recibe el último lugar (FIFO por FechaFin = hora en que terminó
--     el picking). La fecha planificada NO cambia al asignarse sola.
--   · Los números se mantienen contiguos 1..N.
--   · Al despacharse sale de la cola y CONSERVA su número (historial).
--   · Si un cuadro vuelve a picking (Pendiente/Iniciado), pierde el número y,
--     cuando termine de nuevo, entra al final.
--
-- SP_NormalizePrioridadDespacho lo corre el app cada 30 s y después de cada
-- cambio manual. Idempotente: solo escribe filas cuyo número cambia.
-- La primera corrida acomoda por FIFO todos los cuadros listos que ya existan.
--
-- Correr en Picking_Management ANTES de desplegar el código del app.
-- ============================================================

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.OrderRoutePlan') AND name = 'PrioridadDespacho')
    ALTER TABLE dbo.OrderRoutePlan ADD PrioridadDespacho INT NULL;
GO
PRINT 'OrderRoutePlan.PrioridadDespacho OK';
GO

IF OBJECT_ID('dbo.SP_NormalizePrioridadDespacho') IS NOT NULL
    DROP PROCEDURE dbo.SP_NormalizePrioridadDespacho;
GO
CREATE PROCEDURE dbo.SP_NormalizePrioridadDespacho
    @ID_Centro INT = 3
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    BEGIN TRAN;

    -- Serializa contra el endpoint que mueve prioridades (mismo recurso).
    DECLARE @recurso NVARCHAR(100) = N'PrioridadDespacho_' + CAST(@ID_Centro AS NVARCHAR(10));
    EXEC sp_getapplock @Resource = @recurso, @LockMode = 'Exclusive', @LockOwner = 'Transaction', @LockTimeout = 15000;

    -- 1) Cuadros que regresaron a picking: fuera de la cola.
    UPDATE dbo.OrderRoutePlan
    SET PrioridadDespacho = NULL
    WHERE ID_Centro = @ID_Centro
      AND Estado IN ('Pendiente', 'Iniciado')
      AND PrioridadDespacho IS NOT NULL;

    -- 2) Recién terminados (sin número): al final de la cola, FIFO por FechaFin.
    DECLARE @base INT = ISNULL((
        SELECT MAX(PrioridadDespacho) FROM dbo.OrderRoutePlan
        WHERE ID_Centro = @ID_Centro AND Estado = 'Finalizado'
          AND ISNULL(EstadoDespacho, 'Pendiente') <> 'Finalizado'
          AND PrioridadDespacho IS NOT NULL), 0);

    ;WITH nuevos AS (
        SELECT ID_RoutePlan,
               ROW_NUMBER() OVER (ORDER BY CASE WHEN FechaFin IS NULL THEN 1 ELSE 0 END, FechaFin, ID_RoutePlan) AS n
        FROM dbo.OrderRoutePlan
        WHERE ID_Centro = @ID_Centro AND Estado = 'Finalizado'
          AND ISNULL(EstadoDespacho, 'Pendiente') <> 'Finalizado'
          AND PrioridadDespacho IS NULL
    )
    UPDATE r SET r.PrioridadDespacho = @base + k.n
    FROM dbo.OrderRoutePlan r
    INNER JOIN nuevos k ON k.ID_RoutePlan = r.ID_RoutePlan;

    -- 3) Compactar 1..N conservando el orden (empates: el que terminó antes).
    ;WITH ranked AS (
        SELECT ID_RoutePlan,
               ROW_NUMBER() OVER (ORDER BY PrioridadDespacho, CASE WHEN FechaFin IS NULL THEN 1 ELSE 0 END, FechaFin, ID_RoutePlan) AS nueva
        FROM dbo.OrderRoutePlan
        WHERE ID_Centro = @ID_Centro AND Estado = 'Finalizado'
          AND ISNULL(EstadoDespacho, 'Pendiente') <> 'Finalizado'
    )
    UPDATE r SET r.PrioridadDespacho = k.nueva
    FROM dbo.OrderRoutePlan r
    INNER JOIN ranked k ON k.ID_RoutePlan = r.ID_RoutePlan
    WHERE ISNULL(r.PrioridadDespacho, -1) <> k.nueva;

    COMMIT;
END;
GO
PRINT 'SP_NormalizePrioridadDespacho OK';
GO

-- Primera corrida: numera por FIFO los cuadros listos que ya existen.
EXEC dbo.SP_NormalizePrioridadDespacho @ID_Centro = 3;
GO

-- Comprobación:
-- SELECT RouteNumber, RouteName, PrioridadDespacho, FechaFin, FechaPlanDespacho, EstadoDespacho
-- FROM dbo.OrderRoutePlan
-- WHERE ID_Centro = 3 AND Estado = 'Finalizado' AND ISNULL(EstadoDespacho,'Pendiente') <> 'Finalizado'
-- ORDER BY PrioridadDespacho;
