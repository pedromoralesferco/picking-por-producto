-- ============================================================
-- SP_AutoDespachoEscuintla  (HUB Escuintla, ID_Centro=3)
-- Se llama desde el job de 30s (SP_UpdateOrderPickingTasksLisa).
--
-- Regla 1: cuadro con picking Finalizado + placa en SAP -> Despachado.
-- Regla 2 (NUEVO): cuadro cuyo SAP ya está en u_estado='03' (ya salió;
--   todos los '03' de 138 traen placa) -> se cierra COMPLETO
--   (Estado y EstadoDespacho = Finalizado), sin importar el picking del
--   app. Cubre el hueco de los cuadros que pasan a '03' DESPUÉS de
--   ingestarse (ganan placa/despacho en SAP sin pickearse en el app) y
--   quedaban colgados en Pendiente. FechaDespachoFin = UpdateDate de SAP
--   (día real del despacho), con GETDATE() de respaldo.
--
-- Idempotente.
-- ============================================================
IF OBJECT_ID('dbo.SP_AutoDespachoEscuintla') IS NOT NULL
    DROP PROCEDURE dbo.SP_AutoDespachoEscuintla;
GO
CREATE PROCEDURE [dbo].[SP_AutoDespachoEscuintla]
AS
BEGIN
    SET NOCOUNT ON;

    -- Regla 1: picking completo + placa -> Despachado
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

    -- Regla 2: SAP ya está en '03' (despachado) -> cerrar completo,
    -- sin importar el estado de picking del app.
    UPDATE orp
    SET orp.Estado = 'Finalizado',
        orp.FechaFin = ISNULL(orp.FechaFin, ISNULL(e.UpdateDate, GETDATE())),
        orp.EstadoDespacho = 'Finalizado',
        orp.FechaDespachoFin = ISNULL(e.UpdateDate, GETDATE())
    FROM dbo.OrderRoutePlan orp
    JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
         ON e.DocNum = orp.RouteNumber
    WHERE orp.ID_Centro = 3
      AND orp.Pais = 'GT'
      AND orp.EstadoDespacho <> 'Finalizado'
      AND e.u_estado = '03';
END;
GO
PRINT 'SP_AutoDespachoEscuintla actualizado (regla u_estado=03)';
