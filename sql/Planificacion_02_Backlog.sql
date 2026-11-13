-- Fase 1 del conector "Ferco Planificación": backlog sin cuadro precalculado.
-- La consulta contra SAP/Lisa tarda minutos; un job del app corre SP_MCP_BacklogSinCuadro
-- cada 15 min y GET /api/planificacion/backlog lee PlanBacklogSnapshot (con la hora del corte).
-- Solo lectura de SAP y Lisa (linked server); escribe únicamente en estas dos tablas.

IF OBJECT_ID('dbo.PlanBacklogSnapshot') IS NULL
BEGIN
    CREATE TABLE dbo.PlanBacklogSnapshot (
        ID_Centro         INT            NOT NULL,
        Corte             DATETIME       NOT NULL,
        Tipo              VARCHAR(5)     NOT NULL,   -- OV | TR | RMA
        Documento         VARCHAR(20)    NOT NULL,
        DocEntry          INT            NULL,
        FechaDoc          DATE           NULL,
        FechaEntrega      DATE           NULL,
        FormaEnvioCodigo  INT            NULL,       -- ORDR.TrnspCode (22 ruta, 1 cliente retira, 71 paquetería); -1 TR; -2 RMA
        FormaEnvio        NVARCHAR(25)   NULL,
        Cliente           NVARCHAR(100)  NULL,
        AlmacenDestino    VARCHAR(10)    NULL,       -- TR: tienda destino
        DestinoNombre     NVARCHAR(100)  NULL,
        Municipio         NVARCHAR(40)   NULL,
        Direccion         NVARCHAR(200)  NULL,
        Comentario        NVARCHAR(250)  NULL,
        Kg                INT            NOT NULL,
        LineasSinStock    INT            NOT NULL,
        Sucursal          NVARCHAR(50)   NULL,
        Modalidad         VARCHAR(20)    NULL,       -- TR: 'Directo a cliente' | 'A tienda'
        TrOperadoLisa     BIT            NOT NULL,   -- TR ya operado/despachado en Lisa con saldo abierto en SAP
        PickeadoLisa      BIT            NOT NULL,
        EntregadoLisa     BIT            NOT NULL,
        UltimoCuadroApp   INT            NULL,       -- estuvo en un cuadro del app (rezago)
        UltimoCuadroEstado VARCHAR(20)   NULL,
        NoDespachada      BIT            NOT NULL,
        EscalamientoFecha DATE           NULL,       -- fecha requerida del escalamiento abierto más antiguo
        Categoria         VARCHAR(30)    NOT NULL,   -- nuevo | rezago | paqueteria | exportacion | no_aplica_cliente_retira | no_aplica_tr_operado_lisa
        CONSTRAINT PK_PlanBacklogSnapshot PRIMARY KEY (ID_Centro, Tipo, Documento)
    );
END
GO
IF OBJECT_ID('dbo.PlanBacklogCorte') IS NULL
    CREATE TABLE dbo.PlanBacklogCorte (
        ID_Corte    INT IDENTITY(1,1) PRIMARY KEY,
        ID_Centro   INT NOT NULL,
        Corte       DATETIME NOT NULL,
        Filas       INT NULL,
        DuracionMs  INT NULL,
        Error       NVARCHAR(1000) NULL
    );
GO
PRINT 'PlanBacklogSnapshot / PlanBacklogCorte OK';
GO

IF OBJECT_ID('dbo.SP_MCP_BacklogSinCuadro') IS NOT NULL DROP PROCEDURE dbo.SP_MCP_BacklogSinCuadro;
GO
CREATE PROCEDURE dbo.SP_MCP_BacklogSinCuadro
    @ID_Centro INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t0 DATETIME = GETDATE(), @whs VARCHAR(10), @pais VARCHAR(5), @db SYSNAME, @lisa SYSNAME, @paisNombre NVARCHAR(30);
    SELECT @whs = Codigo, @pais = ISNULL(Pais, 'GT') FROM dbo.CentroDistribucion WHERE ID_Centro = @ID_Centro;
    IF @whs IS NULL BEGIN RAISERROR('Centro no existe', 16, 1); RETURN; END
    SELECT @db = CASE @pais WHEN 'SV' THEN 'sbointergres' WHEN 'HN' THEN 'sbopym' ELSE 'sboferco' END;
    SET @lisa = 'lisa_' + @db;
    SET @paisNombre = CASE @pais WHEN 'SV' THEN N'El Salvador' WHEN 'HN' THEN N'Honduras' ELSE N'Guatemala' END;

    BEGIN TRY
        -- ── 1) Documentos en preparación (U_Estado2='03') del almacén, sin cuadro en SAP (OPENQUERY: corre en SAP)
        CREATE TABLE #d (
            tipo VARCHAR(5), DocNum INT, DocEntry INT, fe DATETIME, fd DATETIME, TrnspCode INT, envio NVARCHAR(25),
            cli NVARCHAR(100), hacia VARCHAR(10), muni NVARCHAR(40), dir NVARCHAR(200), com NVARCHAR(250),
            kg DECIMAL(18,3), sinStk INT, suc NVARCHAR(50)
        );
        DECLARE @q NVARCHAR(MAX) = N'
WITH C AS (SELECT DISTINCT LTRIM(RTRIM(d.U_No_OV)) doc FROM {db}.dbo.[@CUADRO_RUTA_D] d WITH (NOLOCK) JOIN {db}.dbo.[@CUADRO_RUTA_E] e WITH (NOLOCK) ON e.DocEntry=d.DocEntry WHERE e.Canceled<>''Y'' AND e.CreateDate>=DATEADD(day,-540,GETDATE()))
SELECT ''OV'' tipo, o.DocNum, o.DocEntry, o.DocDueDate fe, o.DocDate fd, o.TrnspCode, LEFT(h.TrnspName,25) envio, LEFT(o.CardName,100) cli, '''' hacia, LEFT(ISNULL(o.U_SF_MUNI,''''),40) muni,
 LEFT(REPLACE(REPLACE(CAST(ISNULL(o.Address2,'''') AS nvarchar(400)),CHAR(13),'' ''),CHAR(10),'' ''),200) dir, LEFT(REPLACE(REPLACE(CAST(ISNULL(o.Comments,'''') AS nvarchar(400)),CHAR(13),'' ''),CHAR(10),'' ''),250) com,
 SUM(l.OpenQty*ISNULL(i.SWeight1,0)) kg, SUM(CASE WHEN ISNULL(w.OnHand,0)<l.OpenQty THEN 1 ELSE 0 END) sinStk, o.U_SUCURSAL suc
FROM {db}.dbo.ORDR o WITH (NOLOCK) JOIN {db}.dbo.RDR1 l WITH (NOLOCK) ON l.DocEntry=o.DocEntry JOIN {db}.dbo.OITM i WITH (NOLOCK) ON i.ItemCode=l.ItemCode
 LEFT JOIN {db}.dbo.OITW w WITH (NOLOCK) ON w.ItemCode=l.ItemCode AND w.WhsCode=l.WhsCode LEFT JOIN {db}.dbo.OSHP h ON h.TrnspCode=o.TrnspCode
WHERE o.U_Estado2=''03'' AND l.WhsCode=''{whs}'' AND l.LineStatus=''O'' AND o.DocDate>=DATEADD(day,-365,GETDATE()) AND NOT EXISTS (SELECT 1 FROM C WHERE C.doc=CAST(o.DocNum AS varchar(20)))
GROUP BY o.DocNum,o.DocEntry,o.DocDueDate,o.DocDate,o.TrnspCode,h.TrnspName,o.CardName,o.U_SF_MUNI,CAST(ISNULL(o.Address2,'''') AS nvarchar(400)),CAST(ISNULL(o.Comments,'''') AS nvarchar(400)),o.U_SUCURSAL
UNION ALL
SELECT ''TR'', q.DocNum, q.DocEntry, q.DocDueDate, q.DocDate, -1, ''Traslado'', LEFT(q.CardName,100), MAX(l.WhsCode), '''',
 '''', LEFT(REPLACE(REPLACE(CAST(ISNULL(q.Comments,'''') AS nvarchar(400)),CHAR(13),'' ''),CHAR(10),'' ''),250),
 SUM(l.OpenQty*ISNULL(i.SWeight1,0)), SUM(CASE WHEN ISNULL(w.OnHand,0)<l.OpenQty THEN 1 ELSE 0 END), q.U_SUCURSAL
FROM {db}.dbo.OWTQ q WITH (NOLOCK) JOIN {db}.dbo.WTQ1 l WITH (NOLOCK) ON l.DocEntry=q.DocEntry JOIN {db}.dbo.OITM i WITH (NOLOCK) ON i.ItemCode=l.ItemCode
 LEFT JOIN {db}.dbo.OITW w WITH (NOLOCK) ON w.ItemCode=l.ItemCode AND w.WhsCode=q.Filler
WHERE q.U_Estado2=''03'' AND q.Filler=''{whs}'' AND l.LineStatus=''O'' AND q.DocDate>=DATEADD(day,-365,GETDATE()) AND NOT EXISTS (SELECT 1 FROM C WHERE C.doc=CAST(q.DocNum AS varchar(20)))
GROUP BY q.DocNum,q.DocEntry,q.DocDueDate,q.DocDate,q.CardName,CAST(ISNULL(q.Comments,'''') AS nvarchar(400)),q.U_SUCURSAL';
        -- RMA: en Lisa, con cantidad aún no despachada y cuya OV original (OSCL.U_NWR_PO) es
        -- de este almacén. Lisa tiene los RMA de todo el país (Zona 5, HUB, tiendas) y la línea
        -- del RMA no trae almacén, así que el centro se toma del almacén de la OV original.
        IF @whs = '138' SET @q = @q + N'
UNION ALL
SELECT ''RMA'', s.callID, s.callID, NULL, s.createDate, -2, ''RMA'', LEFT(s.custmrName,100), '''', LEFT(ISNULL(o.U_SF_MUNI,''''),40),
 LEFT(REPLACE(REPLACE(CAST(ISNULL(o.Address2,'''') AS nvarchar(400)),CHAR(13),'' ''),CHAR(10),'' ''),200), LEFT(REPLACE(REPLACE(CAST(ISNULL(s.subject,'''') AS nvarchar(400)),CHAR(13),'' ''),CHAR(10),'' ''),250),
 SUM((l.U_NWR_Qty_RMA-ISNULL(sh.Qty,0))*ISNULL(i.SWeight1,0)), 0, o.U_SUCURSAL
FROM {db}.dbo.OSCL s WITH (NOLOCK) JOIN {db}.dbo.[@NWR_RMADT] l WITH (NOLOCK) ON l.DocEntry=s.callID
JOIN (SELECT DISTINCT NoServiceCallSAP FROM {lisa}.dbo.CustServiceCall WITH (NOLOCK)) cs ON cs.NoServiceCallSAP=s.callID
LEFT JOIN (SELECT c.NoServiceCallSAP, p.InternIDProduct, SUM(sl.Quantity) Qty FROM {lisa}.dbo.CustRMAShippingLine sl WITH (NOLOCK) JOIN {lisa}.dbo.CustRMAShipping sh WITH (NOLOCK) ON sh.idCustRMAShipping=sl.idCustRMAShipping JOIN {lisa}.dbo.CustServiceCall c WITH (NOLOCK) ON c.idCustServiceCall=sh.idCustServiceCall JOIN {lisa}.dbo.Product p WITH (NOLOCK) ON p.IDProduct=sl.idProduct GROUP BY c.NoServiceCallSAP, p.InternIDProduct) sh ON sh.NoServiceCallSAP=s.callID AND sh.InternIDProduct=l.U_NWR_ItemNo
LEFT JOIN {db}.dbo.OITM i WITH (NOLOCK) ON i.ItemCode=l.U_NWR_ItemNo LEFT JOIN {db}.dbo.ORDR o WITH (NOLOCK) ON o.DocNum=s.U_NWR_PO
WHERE s.status=-3 AND s.createDate>=DATEADD(day,-365,GETDATE()) AND l.U_NWR_ItemNo IS NOT NULL AND l.U_NWR_Qty_RMA-ISNULL(sh.Qty,0)>0
 AND EXISTS (SELECT 1 FROM {db}.dbo.RDR1 r WITH (NOLOCK) WHERE r.DocEntry=o.DocEntry AND r.WhsCode=''{whs}'') AND NOT EXISTS (SELECT 1 FROM C WHERE C.doc=CAST(s.callID AS varchar(20)))
GROUP BY s.callID,s.createDate,s.custmrName,o.U_SF_MUNI,CAST(ISNULL(o.Address2,'''') AS nvarchar(400)),CAST(ISNULL(s.subject,'''') AS nvarchar(400)),o.U_SUCURSAL';
        SET @q = REPLACE(REPLACE(REPLACE(@q, '{db}', @db), '{lisa}', @lisa), '{whs}', @whs);
        DECLARE @sql NVARCHAR(MAX) = N'SELECT * FROM OPENQUERY([SERVER-SQL], ''' + REPLACE(@q, '''', '''''') + ''')';
        INSERT INTO #d EXEC sp_executesql @sql;

        -- ── 2) Lisa: picks y entregas (últimos 90 días)
        CREATE TABLE #lisa (Doc INT PRIMARY KEY, Picks INT, Entregas INT);
        SET @sql = N'SELECT t.DocNumSAP, SUM(CASE WHEN t.TransactionType IN (''PI'',''PIREQ'') THEN 1 ELSE 0 END), SUM(CASE WHEN t.TransactionType IN (''DL'',''REQDEL'') THEN 1 ELSE 0 END)
            FROM [server-sql].' + QUOTENAME(@lisa) + N'.dbo.InventoryTransactionLog t WITH (NOLOCK)
            WHERE t.TransactionType IN (''PI'',''PIREQ'',''DL'',''REQDEL'') AND t.DateTimeTransaction >= DATEADD(day,-90,GETDATE())
              AND t.DocNumSAP IN (SELECT DocNum FROM #d)
            GROUP BY t.DocNumSAP';
        INSERT INTO #lisa EXEC sp_executesql @sql;

        -- ── 3) Historial en el app (rezagos) y escalamientos
        SELECT LTRIM(RTRIM(m.OV_Number)) COLLATE DATABASE_DEFAULT AS Doc, p.RouteNumber, p.Estado, ISNULL(m.NoDespachada, 0) AS NoDespachada,
               ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(m.OV_Number)) ORDER BY p.RouteNumber DESC) rn
        INTO #app
        FROM dbo.OrderPickingManagement m JOIN dbo.OrderRoutePlan p ON p.ID_RoutePlan = m.ID_RoutePlan
        WHERE p.ID_Centro = @ID_Centro AND LTRIM(RTRIM(m.OV_Number)) IN (SELECT CAST(DocNum AS varchar(20)) FROM #d);

        SELECT LTRIM(RTRIM(OV_Number)) COLLATE DATABASE_DEFAULT AS Doc, MIN(FechaRequerida) AS Fecha
        INTO #esc FROM dbo.Escalamientos WHERE Archivado = 0 GROUP BY LTRIM(RTRIM(OV_Number));

        -- ── 4) TR ya operados en Lisa (DW_VENTA) y nombres de almacén destino (SAP)
        SELECT DISTINCT DocEntrySAP INTO #op FROM DW_VENTA.dbo.TR_Operado_LISA WHERE Pais = @paisNombre AND DocEntrySAP IN (SELECT DocEntry FROM #d WHERE tipo = 'TR');
        CREATE TABLE #wh (WhsCode VARCHAR(10) COLLATE DATABASE_DEFAULT PRIMARY KEY, WhsName NVARCHAR(100));
        SET @sql = N'SELECT WhsCode, WhsName FROM [server-sql].' + QUOTENAME(@db) + N'.dbo.OWHS WITH (NOLOCK)';
        INSERT INTO #wh EXEC sp_executesql @sql;

        -- ── 5) Reemplazar el snapshot del centro
        DECLARE @corte DATETIME = GETDATE();
        BEGIN TRAN;
        DELETE FROM dbo.PlanBacklogSnapshot WHERE ID_Centro = @ID_Centro;
        INSERT INTO dbo.PlanBacklogSnapshot (ID_Centro, Corte, Tipo, Documento, DocEntry, FechaDoc, FechaEntrega, FormaEnvioCodigo, FormaEnvio,
            Cliente, AlmacenDestino, DestinoNombre, Municipio, Direccion, Comentario, Kg, LineasSinStock, Sucursal, Modalidad,
            TrOperadoLisa, PickeadoLisa, EntregadoLisa, UltimoCuadroApp, UltimoCuadroEstado, NoDespachada, EscalamientoFecha, Categoria)
        SELECT @ID_Centro, @corte, d.tipo, CAST(d.DocNum AS varchar(20)), d.DocEntry, CAST(d.fd AS date), CAST(d.fe AS date), d.TrnspCode, d.envio,
               d.cli, NULLIF(d.hacia, ''), wh.WhsName, NULLIF(d.muni, ''), NULLIF(d.dir, ''), NULLIF(d.com, ''), CAST(ROUND(d.kg, 0) AS int), d.sinStk, d.suc,
               CASE WHEN d.tipo = 'TR' THEN CASE WHEN d.com LIKE '%[[]DIRECTO DESDE%' THEN 'Directo a cliente' ELSE 'A tienda' END END,
               CASE WHEN op.DocEntrySAP IS NOT NULL THEN 1 ELSE 0 END,
               CASE WHEN ISNULL(li.Picks, 0) > 0 THEN 1 ELSE 0 END, CASE WHEN ISNULL(li.Entregas, 0) > 0 THEN 1 ELSE 0 END,
               a.RouteNumber, a.Estado, ISNULL(a.NoDespachada, 0), e.Fecha,
               CASE WHEN d.TrnspCode = 1 THEN 'no_aplica_cliente_retira'
                    WHEN d.tipo = 'TR' AND op.DocEntrySAP IS NOT NULL THEN 'no_aplica_tr_operado_lisa'
                    WHEN d.envio = 'EXPORTACION' THEN 'exportacion'
                    WHEN d.TrnspCode = 71 THEN 'paqueteria'
                    WHEN a.RouteNumber IS NOT NULL THEN 'rezago'
                    ELSE 'nuevo' END
        FROM #d d
        LEFT JOIN #lisa li ON li.Doc = d.DocNum
        LEFT JOIN #app a ON a.Doc = CAST(d.DocNum AS varchar(20)) AND a.rn = 1
        LEFT JOIN #esc e ON e.Doc = CAST(d.DocNum AS varchar(20))
        LEFT JOIN #op op ON op.DocEntrySAP = d.DocEntry AND d.tipo = 'TR'
        LEFT JOIN #wh wh ON wh.WhsCode = d.hacia COLLATE DATABASE_DEFAULT;
        COMMIT;

        INSERT INTO dbo.PlanBacklogCorte (ID_Centro, Corte, Filas, DuracionMs)
        VALUES (@ID_Centro, @corte, (SELECT COUNT(*) FROM dbo.PlanBacklogSnapshot WHERE ID_Centro = @ID_Centro), DATEDIFF(ms, @t0, GETDATE()));
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        INSERT INTO dbo.PlanBacklogCorte (ID_Centro, Corte, Filas, DuracionMs, Error)
        VALUES (@ID_Centro, @t0, NULL, DATEDIFF(ms, @t0, GETDATE()), LEFT(ERROR_MESSAGE(), 1000));
        THROW;
    END CATCH
END
GO
PRINT 'SP_MCP_BacklogSinCuadro OK';
