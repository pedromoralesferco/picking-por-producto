-- ============================================================
-- SP_SyncNoDespachadaEscuintla
--
-- Mantiene OrderPickingManagement.NoDespachada en sync con SAP para
-- HUB Escuintla (ID_Centro=3, Pais GT). Se llama desde el job de 30s
-- (SP_UpdateOrderPickingTasksLisa), ANTES del cierre de cuadros.
--
-- MARCA (NoDespachada=1): una OV/TR del cuadro en el app que YA NO está
--   en las líneas del cuadro en SAP (@cuadro_ruta_d) -> se quitó para
--   mandarla en otro cuadro.
-- DESMARCA (NoDespachada=0): la ÚNICA forma de volver es que SAP vuelva
--   a incluir ese documento en el cuadro. No hay desmarcado manual.
--
-- Guardas anti-falsos:
--   - INNER JOIN al header del cuadro en SAP (@cuadro_ruta_e): si el
--     linked server cae o el cuadro no existe, el cuadro no entra -> no
--     marca nada por error.
--   - Solo cuadros aún no despachados (EstadoDespacho <> 'Finalizado'):
--     lo que ya salió físicamente no se toca.
--   - No se tocan las tareas: la OV queda intacta, así el desmarcado es
--     reversible sin re-importar nada.
--   - COLLATE DATABASE_DEFAULT al comparar contra SAP (CP850).
-- ============================================================
IF OBJECT_ID('dbo.SP_SyncNoDespachadaEscuintla') IS NOT NULL
    DROP PROCEDURE dbo.SP_SyncNoDespachadaEscuintla;
GO
CREATE PROCEDURE [dbo].[SP_SyncNoDespachadaEscuintla]
AS
BEGIN
    SET NOCOUNT ON;

    -- MARCA: la OV ya no está en el cuadro de SAP
    UPDATE opm
    SET opm.NoDespachada = 1, opm.FechaNoDespachada = GETDATE()
    FROM dbo.OrderPickingManagement opm
    INNER JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
    INNER JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
         ON e.DocNum = orp.RouteNumber
    WHERE orp.ID_Centro = 3
      AND orp.Pais = 'GT'
      AND orp.EstadoDespacho <> 'Finalizado'
      AND opm.NoDespachada = 0
      AND NOT EXISTS (
          SELECT 1 FROM [server-sql].sboferco.dbo.[@cuadro_ruta_d] d WITH (NOLOCK)
          WHERE d.DocEntry = e.DocEntry
            AND LTRIM(RTRIM(d.U_No_OV)) COLLATE DATABASE_DEFAULT
                = LTRIM(RTRIM(opm.OV_Number)) COLLATE DATABASE_DEFAULT
      );

    -- DESMARCA: SAP volvió a incluir el documento en el cuadro
    UPDATE opm
    SET opm.NoDespachada = 0, opm.FechaNoDespachada = NULL
    FROM dbo.OrderPickingManagement opm
    INNER JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
    INNER JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
         ON e.DocNum = orp.RouteNumber
    WHERE orp.ID_Centro = 3
      AND orp.Pais = 'GT'
      AND opm.NoDespachada = 1
      AND EXISTS (
          SELECT 1 FROM [server-sql].sboferco.dbo.[@cuadro_ruta_d] d WITH (NOLOCK)
          WHERE d.DocEntry = e.DocEntry
            AND LTRIM(RTRIM(d.U_No_OV)) COLLATE DATABASE_DEFAULT
                = LTRIM(RTRIM(opm.OV_Number)) COLLATE DATABASE_DEFAULT
      );
END;
GO

PRINT 'SP_SyncNoDespachadaEscuintla creado OK';
