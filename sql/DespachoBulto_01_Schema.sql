-- ============================================================
-- DespachoBulto — relación persistida OV↔Licencia (bulto) para decirle al
-- montacarguista qué bultos cargar y en qué ubicación están.
--
-- La licencia DESTINO del picking se toma del log de Lisa (InventoryTransactionLog,
-- TransactionType PI/PIREQ): la Location con LicensePlate=1 donde la cantidad
-- AUMENTA (SUM(NewQty-OldQty) > 0). NO se excluyen carros/estaciones compartidos
-- (se registran tal cual). La ubicación física se resuelve en la LECTURA con un
-- lookup liviano a Locations.IDLocationParent (la ubicación cambia; el enlace no).
--
-- El enlace es por (OV_Number, DocType, Licencia) — INDEPENDIENTE del cuadro: si el
-- doc se mueve a un complemento, la licencia lo sigue; el cuadro actual se resuelve
-- en la lectura uniendo contra OrderPickingManagement por OV.
--
-- Aplicar en Picking_Management. SOLO LECTURA sobre Lisa; no escribe a Lisa/SAP.
-- ============================================================

-- 1) Tabla del enlace OV↔Licencia (creación inicial)
IF OBJECT_ID('dbo.DespachoBulto') IS NOT NULL DROP TABLE dbo.DespachoBulto;
GO
CREATE TABLE dbo.DespachoBulto (
    ID_Bulto           INT IDENTITY(1,1) PRIMARY KEY,
    OV_Number          NVARCHAR(50)  NOT NULL,
    DocType            NVARCHAR(10)  NOT NULL,
    Licencia           NVARCHAR(220) NOT NULL,
    IDLocationLicencia INT           NULL,     -- idLocation de Lisa del pallet (para resolver ubicación)
    Cantidad           DECIMAL(18,6) NULL,
    ID_Centro          INT           NULL,
    Pais               NVARCHAR(10)  NULL,
    FechaCaptura       DATETIME      NOT NULL DEFAULT GETDATE()
);
GO
CREATE UNIQUE INDEX UX_DespachoBulto ON dbo.DespachoBulto (OV_Number, DocType, Licencia);
GO

-- 2) SP de captura: llena DespachoBulto con las licencias destino del picking de
--    los cuadros ACTIVOS (no despachados) de Escuintla. Idempotente (NOT EXISTS).
--    Consulta ITL con DocNumSAP IN (...) para usar el índice remoto (el JOIN de
--    tabla temporal forzaba un scan completo y timeout).
IF OBJECT_ID('dbo.SP_CaptureBultosEscuintla') IS NOT NULL
    DROP PROCEDURE dbo.SP_CaptureBultosEscuintla;
GO
CREATE PROCEDURE [dbo].[SP_CaptureBultosEscuintla]
    @DaysBack INT = 30
AS
BEGIN
    SET NOCOUNT ON;

    -- Guard anti-caída: si Lisa no devuelve movimientos recientes, no tocar nada.
    DECLARE @up INT;
    SELECT @up = COUNT(*) FROM [server-sql].lisa_sboferco.dbo.InventoryTransactionLog WITH (NOLOCK)
    WHERE DateTimeTransaction > GETDATE() - 1;
    IF ISNULL(@up, 0) = 0 RETURN;

    -- DocNum de cuadros activos (Escuintla).
    DECLARE @ovList NVARCHAR(MAX);
    SELECT @ovList = STUFF((
        SELECT DISTINCT ',' + CAST(TRY_CAST(opm.OV_Number AS INT) AS NVARCHAR(20))
        FROM dbo.OrderPickingManagement opm
        JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
        WHERE orp.ID_Centro = 3 AND orp.Pais = 'GT'
          AND ISNULL(orp.EstadoDespacho, '') <> 'Finalizado'
          AND opm.NoDespachada = 0 AND TRY_CAST(opm.OV_Number AS INT) IS NOT NULL
        FOR XML PATH('')), 1, 1, '');
    IF @ovList IS NULL OR @ovList = '' RETURN;

    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH bult AS (
        SELECT i.DocNumSAP, CAST(i.Location AS NVARCHAR(220)) AS Licencia, MAX(i.IDLocation) AS IDLoc,
               SUM(ISNULL(i.NewQty,0) - ISNULL(i.OldQty,0)) AS NetQty
        FROM [server-sql].lisa_sboferco.dbo.InventoryTransactionLog i WITH (NOLOCK)
        JOIN [server-sql].lisa_sboferco.dbo.Locations lic WITH (NOLOCK) ON lic.idLocation = i.IDLocation AND lic.LicensePlate = 1
        WHERE i.TransactionType IN (''PI'',''PIREQ'')
          AND i.DocNumSAP IN (' + @ovList + N')
          AND i.DateTimeTransaction > DATEADD(DAY, -' + CAST(@DaysBack AS NVARCHAR(10)) + N', GETDATE())
        GROUP BY i.DocNumSAP, i.Location
        HAVING SUM(ISNULL(i.NewQty,0) - ISNULL(i.OldQty,0)) > 0
    ),
    docs AS (
        SELECT DISTINCT opm.OV_Number, opm.DocType, TRY_CAST(opm.OV_Number AS INT) AS OVInt
        FROM dbo.OrderPickingManagement opm
        JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
        WHERE orp.ID_Centro = 3 AND orp.Pais = ''GT'' AND ISNULL(orp.EstadoDespacho,'''') <> ''Finalizado'' AND opm.NoDespachada = 0
    )
    INSERT INTO dbo.DespachoBulto (OV_Number, DocType, Licencia, IDLocationLicencia, Cantidad, ID_Centro, Pais)
    SELECT o.OV_Number, o.DocType, b.Licencia, b.IDLoc, b.NetQty, 3, ''GT''
    FROM bult b
    JOIN docs o ON o.OVInt = b.DocNumSAP
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.DespachoBulto d
        WHERE d.OV_Number = o.OV_Number AND d.DocType = o.DocType
          AND d.Licencia COLLATE DATABASE_DEFAULT = b.Licencia COLLATE DATABASE_DEFAULT);';
    EXEC sp_executesql @sql;
END;
GO
PRINT 'DespachoBulto: tabla + SP_CaptureBultosEscuintla OK';
