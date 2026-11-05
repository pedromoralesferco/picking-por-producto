-- Fase 1 del conector "Ferco Planificación": lecturas de SAP/Lisa SOLO por stored procedure.
-- Regla: Node nunca arma consultas hacia [server-sql]; ejecuta estos SP, cada uno acotado a UN
-- documento o UN cuadro (o una lista de máximo 10). Solo lectura, WITH (NOLOCK), sin SQL dinámico.
-- Alcance fase 1: Guatemala (sboferco / lisa_sboferco). Para SV/HN se agregan ramas por país.

-- ── Documento a fondo: cabecera, líneas con existencia, cuadros en SAP y movimientos en Lisa ──
IF OBJECT_ID('dbo.SP_MCP_DetalleDocumento') IS NOT NULL DROP PROCEDURE dbo.SP_MCP_DetalleDocumento;
GO
CREATE PROCEDURE dbo.SP_MCP_DetalleDocumento
    @Documento INT,
    @Almacen   VARCHAR(10),
    @Tipo      VARCHAR(5) = NULL      -- NULL = detectar; 'OV' | 'TR' | 'RMA'
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @t VARCHAR(5) = NULL;
    IF (@Tipo IS NULL OR @Tipo = 'OV') AND EXISTS (
        SELECT 1 FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK)
        JOIN [server-sql].sboferco.dbo.RDR1 l WITH (NOLOCK) ON l.DocEntry = o.DocEntry
        WHERE o.DocNum = @Documento AND l.WhsCode = @Almacen) SET @t = 'OV';
    ELSE IF (@Tipo IS NULL OR @Tipo = 'TR') AND EXISTS (
        SELECT 1 FROM [server-sql].sboferco.dbo.OWTQ q WITH (NOLOCK) WHERE q.DocNum = @Documento AND q.Filler = @Almacen) SET @t = 'TR';
    ELSE IF (@Tipo IS NULL OR @Tipo = 'RMA') AND EXISTS (
        SELECT 1 FROM [server-sql].sboferco.dbo.OSCL s WITH (NOLOCK) WHERE s.callID = @Documento) SET @t = 'RMA';

    -- RS0: tipo detectado (NULL = no existe en ese almacén)
    SELECT @t AS Tipo;
    IF @t IS NULL RETURN;

    -- RS1 cabecera, RS2 líneas
    IF @t = 'OV'
    BEGIN
        SELECT TOP 1 o.DocNum, o.DocStatus, o.U_Estado2, o.CardName AS Cliente,
               CONVERT(varchar(10), o.DocDate, 23) AS FechaDoc, CONVERT(varchar(10), o.DocDueDate, 23) AS FechaEntrega,
               o.TrnspCode AS FormaEnvioCodigo, h.TrnspName AS FormaEnvio,
               LEFT(CAST(o.Address2 AS nvarchar(400)), 200) AS Direccion, LEFT(CAST(o.Comments AS nvarchar(400)), 250) AS Comentario,
               o.U_SUCURSAL AS Sucursal
        FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK)
        LEFT JOIN [server-sql].sboferco.dbo.OSHP h WITH (NOLOCK) ON h.TrnspCode = o.TrnspCode
        WHERE o.DocNum = @Documento;
        SELECT l.LineNum, l.ItemCode, l.Dscription AS Descripcion, CAST(l.Quantity AS decimal(18,2)) AS Cantidad,
               CAST(l.OpenQty AS decimal(18,2)) AS Abierta, l.LineStatus, l.WhsCode AS Almacen,
               CAST(ISNULL(w.OnHand,0) AS decimal(18,2)) AS Existencia, CAST(l.OpenQty*ISNULL(i.SWeight1,0) AS decimal(18,1)) AS KgAbiertos
        FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK)
        JOIN [server-sql].sboferco.dbo.RDR1 l WITH (NOLOCK) ON l.DocEntry = o.DocEntry
        LEFT JOIN [server-sql].sboferco.dbo.OITM i WITH (NOLOCK) ON i.ItemCode = l.ItemCode
        LEFT JOIN [server-sql].sboferco.dbo.OITW w WITH (NOLOCK) ON w.ItemCode = l.ItemCode AND w.WhsCode = l.WhsCode
        WHERE o.DocNum = @Documento AND l.WhsCode = @Almacen ORDER BY l.LineNum;
    END
    ELSE IF @t = 'TR'
    BEGIN
        SELECT TOP 1 q.DocNum, q.DocStatus, q.U_Estado2, q.CardName AS Cliente,
               CONVERT(varchar(10), q.DocDate, 23) AS FechaDoc, CONVERT(varchar(10), q.DocDueDate, 23) AS FechaEntrega,
               q.Filler AS AlmacenOrigen, q.ToWhsCode AS AlmacenDestino, wh.WhsName AS Destino,
               LEFT(CAST(q.Comments AS nvarchar(400)), 250) AS Comentario, q.U_SUCURSAL AS Sucursal,
               CASE WHEN CAST(q.Comments AS nvarchar(4000)) LIKE '%[[]DIRECTO DESDE%' THEN 'Directo a cliente' ELSE 'A tienda' END AS Modalidad
        FROM [server-sql].sboferco.dbo.OWTQ q WITH (NOLOCK)
        LEFT JOIN [server-sql].sboferco.dbo.OWHS wh WITH (NOLOCK) ON wh.WhsCode = q.ToWhsCode
        WHERE q.DocNum = @Documento AND q.Filler = @Almacen;
        SELECT l.LineNum, l.ItemCode, l.Dscription AS Descripcion, CAST(l.Quantity AS decimal(18,2)) AS Cantidad,
               CAST(l.OpenQty AS decimal(18,2)) AS Abierta, l.LineStatus, q.Filler AS Almacen,
               CAST(ISNULL(w.OnHand,0) AS decimal(18,2)) AS Existencia, CAST(l.OpenQty*ISNULL(i.SWeight1,0) AS decimal(18,1)) AS KgAbiertos
        FROM [server-sql].sboferco.dbo.OWTQ q WITH (NOLOCK)
        JOIN [server-sql].sboferco.dbo.WTQ1 l WITH (NOLOCK) ON l.DocEntry = q.DocEntry
        LEFT JOIN [server-sql].sboferco.dbo.OITM i WITH (NOLOCK) ON i.ItemCode = l.ItemCode
        LEFT JOIN [server-sql].sboferco.dbo.OITW w WITH (NOLOCK) ON w.ItemCode = l.ItemCode AND w.WhsCode = q.Filler
        WHERE q.DocNum = @Documento AND q.Filler = @Almacen ORDER BY l.LineNum;
    END
    ELSE
    BEGIN
        SELECT TOP 1 s.callID AS DocNum, s.status AS EstadoLlamada, s.custmrName AS Cliente,
               CONVERT(varchar(10), s.createDate, 23) AS FechaDoc, LEFT(CAST(s.subject AS nvarchar(400)), 250) AS Comentario,
               s.U_NWR_PO AS OVOrigen
        FROM [server-sql].sboferco.dbo.OSCL s WITH (NOLOCK) WHERE s.callID = @Documento;
        SELECT l.U_NWR_ItemNo AS ItemCode, CAST(l.U_NWR_Qty_RMA AS decimal(18,2)) AS Cantidad
        FROM [server-sql].sboferco.dbo.[@NWR_RMADT] l WITH (NOLOCK) WHERE l.DocEntry = @Documento AND l.U_NWR_ItemNo IS NOT NULL;
    END

    -- RS3: cuadros de ruta en SAP donde está o estuvo
    DECLARE @s VARCHAR(20) = CAST(@Documento AS varchar(20));
    SELECT TOP 50 e.DocNum AS Cuadro, e.U_NombreR AS Nombre, e.U_ESTADO AS EstadoSAP, e.Canceled AS Cancelado,
           CONVERT(varchar(10), e.CreateDate, 23) AS Creado
    FROM [server-sql].sboferco.dbo.[@cuadro_ruta_d] d WITH (NOLOCK)
    JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK) ON e.DocEntry = d.DocEntry
    WHERE LTRIM(RTRIM(d.U_No_OV)) = @s
    ORDER BY e.DocNum DESC;

    -- RS4: picks y entregas en Lisa (últimos 120 días)
    SELECT TransactionType AS Tipo, COUNT(*) AS Movimientos, MAX(DateTimeTransaction) AS Ultimo
    FROM [server-sql].lisa_sboferco.dbo.InventoryTransactionLog WITH (NOLOCK)
    WHERE DocNumSAP = @Documento AND TransactionType IN ('PI','PIREQ','DL','REQDEL')
      AND DateTimeTransaction >= DATEADD(day, -120, GETDATE())
    GROUP BY TransactionType;
END
GO

-- ── Lisa por cuadro: picks/entregas de los documentos de UN cuadro del app ──
IF OBJECT_ID('dbo.SP_MCP_LisaPorCuadro') IS NOT NULL DROP PROCEDURE dbo.SP_MCP_LisaPorCuadro;
GO
CREATE PROCEDURE dbo.SP_MCP_LisaPorCuadro
    @Cuadro INT
AS
BEGIN
    SET NOCOUNT ON;
    -- Documentos del cuadro, en lotes de 10. Un IN (SELECT ... FROM #tabla) no se envía al servidor
    -- remoto (traería todo el log de Lisa); por eso la lista va como literales INT ya validados.
    CREATE TABLE #docs (Doc INT PRIMARY KEY, Lote INT);
    INSERT INTO #docs (Doc, Lote)
    SELECT Doc, (ROW_NUMBER() OVER (ORDER BY Doc) - 1) / 10
    FROM (SELECT DISTINCT TRY_CAST(LTRIM(RTRIM(m.OV_Number)) AS int) AS Doc
          FROM dbo.OrderPickingManagement m JOIN dbo.OrderRoutePlan p ON p.ID_RoutePlan = m.ID_RoutePlan
          WHERE p.RouteNumber = @Cuadro) x
    WHERE Doc IS NOT NULL;
    CREATE TABLE #out (Doc INT, Picks INT, Entregas INT, Ultimo DATETIME);
    DECLARE @lote INT = 0, @max INT = (SELECT MAX(Lote) FROM #docs), @lista NVARCHAR(400), @sql NVARCHAR(MAX);
    WHILE @lote <= @max
    BEGIN
        SET @lista = STUFF((SELECT ',' + CAST(Doc AS varchar(20)) FROM #docs WHERE Lote = @lote FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '');
        SET @sql = N'SELECT t.DocNumSAP, SUM(CASE WHEN t.TransactionType IN (''PI'',''PIREQ'') THEN 1 ELSE 0 END),
                            SUM(CASE WHEN t.TransactionType IN (''DL'',''REQDEL'') THEN 1 ELSE 0 END), MAX(t.DateTimeTransaction)
                     FROM [server-sql].lisa_sboferco.dbo.InventoryTransactionLog t WITH (NOLOCK)
                     WHERE t.TransactionType IN (''PI'',''PIREQ'',''DL'',''REQDEL'') AND t.DateTimeTransaction >= DATEADD(day, -90, GETDATE())
                       AND t.DocNumSAP IN (' + @lista + N')
                     GROUP BY t.DocNumSAP';
        INSERT INTO #out EXEC sp_executesql @sql;
        SET @lote += 1;
    END
    SELECT Doc, Picks, Entregas, Ultimo FROM #out;
END
GO

-- ── Estado de UN documento en SAP (para validar un plan cuando no está en el snapshot) ──
IF OBJECT_ID('dbo.SP_MCP_EstadoDocumentoSAP') IS NOT NULL DROP PROCEDURE dbo.SP_MCP_EstadoDocumentoSAP;
GO
CREATE PROCEDURE dbo.SP_MCP_EstadoDocumentoSAP
    @Documento INT,
    @Almacen   VARCHAR(10)
AS
BEGIN
    SET NOCOUNT ON;
    -- RS0: OV o TR de los últimos 2 años (un DocNum puede repetirse entre OV y TR)
    SELECT 'OV' AS Tipo, o.DocNum, o.DocStatus, o.U_Estado2, o.CardName AS Cliente, o.TrnspCode,
           CAST(SUM(l.OpenQty*ISNULL(i.SWeight1,0)) AS int) AS Kg, SUM(CASE WHEN l.WhsCode = @Almacen THEN 1 ELSE 0 END) AS LineasAlmacen
    FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK) JOIN [server-sql].sboferco.dbo.RDR1 l WITH (NOLOCK) ON l.DocEntry = o.DocEntry
    LEFT JOIN [server-sql].sboferco.dbo.OITM i WITH (NOLOCK) ON i.ItemCode = l.ItemCode
    WHERE o.DocNum = @Documento AND o.DocDate >= DATEADD(year, -2, GETDATE())
    GROUP BY o.DocNum, o.DocStatus, o.U_Estado2, o.CardName, o.TrnspCode
    UNION ALL
    SELECT 'TR', q.DocNum, q.DocStatus, q.U_Estado2, q.CardName, -1,
           CAST(SUM(l.OpenQty*ISNULL(i.SWeight1,0)) AS int), SUM(CASE WHEN q.Filler = @Almacen THEN 1 ELSE 0 END)
    FROM [server-sql].sboferco.dbo.OWTQ q WITH (NOLOCK) JOIN [server-sql].sboferco.dbo.WTQ1 l WITH (NOLOCK) ON l.DocEntry = q.DocEntry
    LEFT JOIN [server-sql].sboferco.dbo.OITM i WITH (NOLOCK) ON i.ItemCode = l.ItemCode
    WHERE q.DocNum = @Documento AND q.DocDate >= DATEADD(year, -2, GETDATE())
    GROUP BY q.DocNum, q.DocStatus, q.U_Estado2, q.CardName;

    -- RS1: cuadros vigentes en SAP donde ya está
    DECLARE @s VARCHAR(20) = CAST(@Documento AS varchar(20));
    SELECT TOP 20 e.DocNum AS Cuadro, e.U_ESTADO AS EstadoSAP
    FROM [server-sql].sboferco.dbo.[@cuadro_ruta_d] d WITH (NOLOCK)
    JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK) ON e.DocEntry = d.DocEntry
    WHERE e.Canceled <> 'Y' AND e.CreateDate >= DATEADD(day, -540, GETDATE()) AND LTRIM(RTRIM(d.U_No_OV)) = @s
    ORDER BY e.DocNum DESC;
END
GO

-- ── Cuadros en SAP de una lista de documentos (máximo 10 por llamada) ──
IF OBJECT_ID('dbo.SP_MCP_CuadrosDeDocumentos') IS NOT NULL DROP PROCEDURE dbo.SP_MCP_CuadrosDeDocumentos;
GO
CREATE PROCEDURE dbo.SP_MCP_CuadrosDeDocumentos
    @Documentos VARCHAR(300)     -- hasta 10 números separados por coma
AS
BEGIN
    SET NOCOUNT ON;
    -- Solo se aceptan números: cualquier otra cosa se descarta antes de armar la lista.
    CREATE TABLE #d (Doc INT PRIMARY KEY);
    DECLARE @x XML = CAST('<r>' + REPLACE(REPLACE(@Documentos, ' ', ''), ',', '</r><r>') + '</r>' AS xml);
    INSERT INTO #d (Doc)
    SELECT DISTINCT TRY_CAST(v.value('.', 'varchar(20)') AS int) FROM @x.nodes('/r') AS n(v)
    WHERE TRY_CAST(v.value('.', 'varchar(20)') AS int) IS NOT NULL;
    IF (SELECT COUNT(*) FROM #d) > 10 BEGIN RAISERROR('Máximo 10 documentos por llamada', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM #d) RETURN;

    -- Lista literal (enteros validados) para que el filtro corra en SAP y no se traiga la tabla completa.
    DECLARE @lista NVARCHAR(400) = STUFF((SELECT ',''' + CAST(Doc AS varchar(20)) + '''' FROM #d FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, '');
    DECLARE @sql NVARCHAR(MAX) = N'
    SELECT LTRIM(RTRIM(d.U_No_OV)) AS Documento,
           MAX(CASE WHEN e.u_estado IN (''03'',''04'') THEN 2 ELSE 1 END) AS Rk,
           MAX(CASE WHEN e.u_estado IN (''03'',''04'') THEN e.UpdateDate END) AS Despacho,
           MAX(CASE WHEN e.u_estado IN (''03'',''04'') THEN e.DocNum END) AS CuadroFin,
           MAX(e.DocNum) AS CuadroAny
    FROM [server-sql].sboferco.dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
    JOIN [server-sql].sboferco.dbo.[@cuadro_ruta_d] d WITH (NOLOCK) ON d.DocEntry = e.DocEntry
    WHERE e.Canceled <> ''Y'' AND LTRIM(RTRIM(d.U_No_OV)) IN (' + @lista + N')
    GROUP BY LTRIM(RTRIM(d.U_No_OV))';
    EXEC sp_executesql @sql;
END
GO
PRINT 'SP_MCP_DetalleDocumento / LisaPorCuadro / EstadoDocumentoSAP / CuadrosDeDocumentos OK';
