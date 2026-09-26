-- ============================================================
-- SP_AutoDespachoEscuintla
--
-- Regla continua para HUB Escuintla (ID_Centro=3): cuando un cuadro
-- ya tiene PLACA asignada en SAP y su picking está completo, lo marca
-- automáticamente como DESPACHADO (sale del tablero de despacho).
--
-- Criterio:
--   - Estado = 'Finalizado' (picking al 100%)
--   - EstadoDespacho en ('Pendiente','Listo para Carga')  (aún en tablero)
--   - El cuadro en SAP (sboferco) tiene U_Placa no vacía
--
-- Idempotente: los ya despachados no se reprocesan. Se llama desde el
-- job de 30s (SP_UpdateOrderPickingTasksLisa).
-- ============================================================
IF OBJECT_ID('dbo.SP_AutoDespachoEscuintla') IS NOT NULL
    DROP PROCEDURE dbo.SP_AutoDespachoEscuintla;
GO
CREATE PROCEDURE [dbo].[SP_AutoDespachoEscuintla]
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE orp
    SET orp.EstadoDespacho = 'Finalizado',
        orp.FechaDespachoFin = GETDATE()
    FROM dbo.OrderRoutePlan orp
    JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
         ON e.DocNum = orp.RouteNumber
    WHERE orp.ID_Centro = 3
      AND orp.Estado = 'Finalizado'
      AND orp.EstadoDespacho IN ('Pendiente', 'Listo para Carga')
      AND LTRIM(RTRIM(ISNULL(e.U_Placa, ''))) <> '';
END;
GO
