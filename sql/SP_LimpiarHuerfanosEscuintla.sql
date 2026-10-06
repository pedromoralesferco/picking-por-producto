-- ============================================================
-- SP_LimpiarHuerfanosEscuintla  (HUB Escuintla, ID_Centro=3)
-- Se llama desde el job de 30s (SP_UpdateOrderPickingTasksLisa).
--
-- Saca del tablero los cuadros HUÉRFANOS: activos en el app (no
-- despachados) cuyo cuadro en SAP ya no tiene líneas — porque el
-- @cuadro_ruta_e fue BORRADO, o quedó sin líneas (todos sus docs se
-- reacomodaron a otros cuadros). Quedaban colgados en "Listo para
-- despachar"/Pendiente porque SP_AutoDespachoEscuintla necesita el
-- header de SAP para cerrarlos.
--
-- Los cierra: EstadoDespacho='Finalizado' (y Estado='Finalizado' si
-- estaba Pendiente). FechaDespachoFin = FechaFin (día en que estuvo
-- activo), así NO aparecen como "despachado hoy" — simplemente salen
-- del tablero.
--
-- Guard anti-caída: si SAP no devuelve cuadros recientes (linked server
-- caído), RETURN sin tocar nada. Y solo evalúa contra la lista de
-- cuadros que SÍ tienen líneas en SAP (#vivos), traída en bloque.
-- ============================================================
IF OBJECT_ID('dbo.SP_LimpiarHuerfanosEscuintla') IS NOT NULL
    DROP PROCEDURE dbo.SP_LimpiarHuerfanosEscuintla;
GO
CREATE PROCEDURE [dbo].[SP_LimpiarHuerfanosEscuintla]
AS
BEGIN
    SET NOCOUNT ON;

    -- Guard: ¿SAP responde? Si no hay cuadros recientes, no tocar nada.
    DECLARE @sapUp INT;
    SELECT @sapUp = COUNT(*)
    FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] WITH (NOLOCK)
    WHERE CreateDate > GETDATE() - 3;
    IF ISNULL(@sapUp, 0) = 0 RETURN;

    -- Cuadros activos del app que SÍ tienen líneas en SAP (traídos en bloque).
    IF OBJECT_ID('tempdb..#vivos') IS NOT NULL DROP TABLE #vivos;
    CREATE TABLE #vivos (RouteNumber INT PRIMARY KEY);
    INSERT INTO #vivos (RouteNumber)
    SELECT DISTINCT e.DocNum
    FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
    JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] d WITH (NOLOCK) ON d.DocEntry = e.DocEntry
    WHERE EXISTS (SELECT 1 FROM dbo.OrderRoutePlan orp
                  WHERE orp.RouteNumber = e.DocNum AND orp.ID_Centro = 3 AND orp.Pais = 'GT'
                    AND orp.EstadoDespacho <> 'Finalizado');

    -- Huérfanos: activos en app sin líneas en SAP -> sacar del tablero.
    UPDATE orp
    SET orp.Estado = CASE WHEN orp.Estado = 'Pendiente' THEN 'Finalizado' ELSE orp.Estado END,
        orp.FechaFin = ISNULL(orp.FechaFin, GETDATE()),
        orp.EstadoDespacho = 'Finalizado',
        orp.FechaDespachoFin = ISNULL(orp.FechaFin, GETDATE())
    FROM dbo.OrderRoutePlan orp
    WHERE orp.ID_Centro = 3 AND orp.Pais = 'GT'
      AND orp.EstadoDespacho <> 'Finalizado'
      AND NOT EXISTS (SELECT 1 FROM #vivos v WHERE v.RouteNumber = orp.RouteNumber);

    DROP TABLE #vivos;
END;
GO
PRINT 'SP_LimpiarHuerfanosEscuintla creado OK';
