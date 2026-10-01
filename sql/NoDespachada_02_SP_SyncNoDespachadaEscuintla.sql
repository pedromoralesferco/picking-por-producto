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
-- PERFORMANCE: se traen UNA sola vez los headers y líneas vigentes de
-- SAP a tablas temporales (#SapCuadros / #SapLineas) y luego marca/
-- desmarca con joins LOCALES. Así evitamos subconsultas correlacionadas
-- contra el linked server (que hacían el SP lento ~2s y pesaban sobre
-- SAP). Dos lecturas masivas en vez de barridos fila-por-fila.
--
-- Guardas anti-falsos:
--   - Si no se trajo NINGÚN header (linked server caído) -> RETURN, no
--     se toca nada.
--   - Solo se evalúan cuadros cuyo header SÍ se leyó (#SapCuadros): un
--     cuadro que no se pudo leer no marca por error.
--   - Solo cuadros aún no despachados (EstadoDespacho <> 'Finalizado').
--   - No se tocan las tareas: la OV queda intacta -> desmarcado reversible.
--   - COLLATE DATABASE_DEFAULT al comparar contra SAP (CP850).
-- ============================================================
IF OBJECT_ID('dbo.SP_SyncNoDespachadaEscuintla') IS NOT NULL
    DROP PROCEDURE dbo.SP_SyncNoDespachadaEscuintla;
GO
CREATE PROCEDURE [dbo].[SP_SyncNoDespachadaEscuintla]
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('tempdb..#SapCuadros') IS NOT NULL DROP TABLE #SapCuadros;
    IF OBJECT_ID('tempdb..#SapLineas')  IS NOT NULL DROP TABLE #SapLineas;
    CREATE TABLE #SapCuadros (RouteNumber INT PRIMARY KEY);
    CREATE TABLE #SapLineas  (RouteNumber INT, OV NVARCHAR(50) COLLATE DATABASE_DEFAULT);

    -- Cuadros vigentes de Escuintla (no despachados) que tienen header en SAP.
    INSERT INTO #SapCuadros (RouteNumber)
    SELECT e.DocNum
    FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
    WHERE EXISTS (
        SELECT 1 FROM dbo.OrderRoutePlan orp
        WHERE orp.RouteNumber = e.DocNum AND orp.ID_Centro = 3 AND orp.Pais = 'GT'
          AND orp.EstadoDespacho <> 'Finalizado'
    );

    -- Anti-falsos: si el linked server no devolvió headers, no tocar nada.
    IF NOT EXISTS (SELECT 1 FROM #SapCuadros) RETURN;

    -- Líneas (documentos) actuales de esos cuadros en SAP.
    INSERT INTO #SapLineas (RouteNumber, OV)
    SELECT DISTINCT e.DocNum, LTRIM(RTRIM(d.U_No_OV)) COLLATE DATABASE_DEFAULT
    FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
    INNER JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] d WITH (NOLOCK)
         ON d.DocEntry = e.DocEntry
    WHERE EXISTS (SELECT 1 FROM #SapCuadros c WHERE c.RouteNumber = e.DocNum);

    CREATE INDEX IX_SapLineas ON #SapLineas (RouteNumber, OV);

    -- MARCA: la OV ya no está en el cuadro de SAP (pero el cuadro SÍ se leyó).
    UPDATE opm
    SET opm.NoDespachada = 1, opm.FechaNoDespachada = GETDATE()
    FROM dbo.OrderPickingManagement opm
    INNER JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
    INNER JOIN #SapCuadros c ON c.RouteNumber = orp.RouteNumber
    WHERE orp.ID_Centro = 3 AND orp.Pais = 'GT'
      AND orp.EstadoDespacho <> 'Finalizado'
      AND opm.NoDespachada = 0
      AND NOT EXISTS (
          SELECT 1 FROM #SapLineas s
          WHERE s.RouteNumber = orp.RouteNumber
            AND s.OV = LTRIM(RTRIM(opm.OV_Number)) COLLATE DATABASE_DEFAULT
      );

    -- DESMARCA: SAP volvió a incluir el documento en el cuadro.
    UPDATE opm
    SET opm.NoDespachada = 0, opm.FechaNoDespachada = NULL
    FROM dbo.OrderPickingManagement opm
    INNER JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
    WHERE orp.ID_Centro = 3 AND orp.Pais = 'GT'
      AND opm.NoDespachada = 1
      AND EXISTS (
          SELECT 1 FROM #SapLineas s
          WHERE s.RouteNumber = orp.RouteNumber
            AND s.OV = LTRIM(RTRIM(opm.OV_Number)) COLLATE DATABASE_DEFAULT
      );

    DROP TABLE #SapCuadros;
    DROP TABLE #SapLineas;
END;
GO

PRINT 'SP_SyncNoDespachadaEscuintla creado OK';
