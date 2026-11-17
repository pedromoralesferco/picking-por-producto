-- ════════════════════════════════════════════════════════════════════
-- Notif_03 — condiciones de entrega + detalle del pedido (pedido de Elena, n8n)
-- Correr en Picking_Management DESPUÉS de Notif_01 y Notif_02.
--
--  * NotifPedido: columnas nuevas desde la OV de SAP
--      InstEntrega  U_FE_InstEntrega   Comentarios  Comments
--      TonMax       U_FE_TonMax        Montacarga   U_FE_Montacarga (S/N)
--      Cuadrilla    U_FE_Cuadrilla     Latitud / Longitud  U_Latitud / U_Longitud
--      Detalle      JSON con las líneas del almacén: linea, codigo,
--                   descripcion, cantidad, unidad (sin precios)
--  * HashActual se recalcula con las columnas nuevas (todas las filas se
--    vuelven a subir una vez; no genera avisos porque las fechas no cambian).
--  * SP_NotifDetectarSAP con CREATE OR ALTER: conserva el GRANT EXECUTE de
--    app_sacwhatsapp. (Notif_01 usa DROP/CREATE: si se vuelve a correr,
--    hay que volver a correr Notif_02_Login y este script.)
--  * El detalle solo se refresca para OV abiertas en SAP (DocStatus = 'O');
--    las ya entregadas conservan el último detalle leído.
-- ════════════════════════════════════════════════════════════════════
USE Picking_Management;
GO

IF COL_LENGTH('dbo.NotifPedido', 'InstEntrega') IS NULL
    ALTER TABLE dbo.NotifPedido ADD
        InstEntrega  NVARCHAR(1000) NULL,
        Comentarios  NVARCHAR(1000) NULL,
        TonMax       DECIMAL(9,3)   NULL,
        Montacarga   NVARCHAR(1)    NULL,
        Cuadrilla    NVARCHAR(1)    NULL,
        Latitud      NVARCHAR(20)   NULL,
        Longitud     NVARCHAR(20)   NULL,
        Detalle      NVARCHAR(MAX)  NULL;
GO

-- Hash con las columnas nuevas
IF COL_LENGTH('dbo.NotifPedido', 'HashActual') IS NOT NULL
    ALTER TABLE dbo.NotifPedido DROP COLUMN HashActual;
GO
ALTER TABLE dbo.NotifPedido ADD HashActual AS CHECKSUM(
    ClienteNombre, Celular, VendedorNombre, VendedorEmail, Direccion, FechaEntrega, Almacen, ID_Centro,
    CuadroActual, Placa, FechaPlanificado, FechaPickingInicio, FechaPickingFin, FechaDespacho, FechaCancelado,
    InstEntrega, Comentarios, TonMax, Montacarga, Cuadrilla, Latitud, Longitud, Detalle);
GO

CREATE OR ALTER PROCEDURE dbo.SP_NotifDetectarSAP
    @Pais      NVARCHAR(10),
    @SapDb     SYSNAME,
    @Almacenes NVARCHAR(200) = NULL,
    @SoloRuta  BIT = 0,
    @Silencioso BIT = 0      -- 1 en la primera corrida por país (backfill sin mensajes)
AS
BEGIN
    SET NOCOUNT ON;
    IF @SapDb NOT LIKE 'sbo%' OR @SapDb LIKE '%[^a-z0-9_]%' BEGIN RAISERROR('SapDb inválida', 16, 1); RETURN; END
    SET @Almacenes = NULLIF(REPLACE(LTRIM(RTRIM(@Almacenes)), ' ', ''), '');
    IF @Almacenes LIKE '%[^A-Za-z0-9,]%' BEGIN RAISERROR('Almacenes inválidos (solo códigos separados por coma)', 16, 1); RETURN; END

    -- Lista para el IN dentro de OPENQUERY: 138,01 -> ''138'',''01''
    DECLARE @in NVARCHAR(400) = N'''''' + REPLACE(@Almacenes, N',', N''''',''''') + N'''''';
    DECLARE @filtroWhs NVARCHAR(400) = CASE WHEN @Almacenes IS NULL THEN N'' ELSE N' AND l.WhsCode IN (' + @in + N')' END;

    -- Primera corrida de un país (aún no tiene filas): siempre silenciosa
    IF NOT EXISTS (SELECT 1 FROM dbo.NotifPedido WHERE Pais = @Pais) SET @Silencioso = 1;

    -- Filtro común de OV (corre en SAP)
    DECLARE @where NVARCHAR(MAX) = N'
WHERE o.DocDate >= DATEADD(day, -60, GETDATE())
  AND (o.U_Estado2 = ''''03'''' OR (o.CANCELED = ''''Y'''' AND o.UpdateDate >= DATEADD(day, -7, GETDATE())))'
        + CASE WHEN @SoloRuta = 1 THEN N' AND o.TrnspCode = 22' ELSE N'' END;

    CREATE TABLE #sap (DocNum INT PRIMARY KEY, Cliente NVARCHAR(150), Celular NVARCHAR(50),
                       Vendedor NVARCHAR(155), VendedorEmail NVARCHAR(100),
                       Direccion NVARCHAR(254), FechaEntrega DATE, Cancelado BIT, Almacen NVARCHAR(10),
                       InstEntrega NVARCHAR(1000), Comentarios NVARCHAR(1000), TonMax DECIMAL(9,3),
                       Montacarga NVARCHAR(1), Cuadrilla NVARCHAR(1), Latitud NVARCHAR(20), Longitud NVARCHAR(20));

    DECLARE @q NVARCHAR(MAX) = N'
SELECT o.DocNum,
       CAST(LEFT(o.CardName, 150)  AS NVARCHAR(150)) AS CardName,
       CAST(LEFT(o.U_Celular, 50)  AS NVARCHAR(50))  AS U_Celular,
       CAST(LEFT(s.SlpName, 155)   AS NVARCHAR(155)) AS SlpName,
       CAST(LEFT(s.Email, 100)     AS NVARCHAR(100)) AS Email,
       CAST(LEFT(CAST(o.Address2 AS NVARCHAR(MAX)), 254) AS NVARCHAR(254)) AS Address2,
       CAST(o.DocDueDate AS DATE) AS DocDueDate,
       CASE WHEN o.CANCELED = ''''Y'''' THEN 1 ELSE 0 END AS Cancelado,
       a.Almacen,
       CAST(LEFT(CAST(o.U_FE_InstEntrega AS NVARCHAR(MAX)), 1000) AS NVARCHAR(1000)) AS InstEntrega,
       CAST(LEFT(CAST(o.Comments AS NVARCHAR(MAX)), 1000) AS NVARCHAR(1000)) AS Comentarios,
       CAST(NULLIF(o.U_FE_TonMax, 0) AS DECIMAL(9,3)) AS TonMax,
       CAST(o.U_FE_Montacarga AS NVARCHAR(1)) AS Montacarga,
       CAST(o.U_FE_Cuadrilla AS NVARCHAR(1)) AS Cuadrilla,
       CAST(LEFT(o.U_Latitud, 20)  AS NVARCHAR(20)) AS Latitud,
       CAST(LEFT(o.U_Longitud, 20) AS NVARCHAR(20)) AS Longitud
FROM ' + @SapDb + N'.dbo.ORDR o
LEFT JOIN ' + @SapDb + N'.dbo.OSLP s ON s.SlpCode = o.SlpCode
CROSS APPLY (SELECT CAST(MIN(l.WhsCode) AS NVARCHAR(10)) AS Almacen
             FROM ' + @SapDb + N'.dbo.RDR1 l
             WHERE l.DocEntry = o.DocEntry' + @filtroWhs + N') a'
        + @where + N' AND a.Almacen IS NOT NULL';

    DECLARE @sql NVARCHAR(MAX) = N'INSERT INTO #sap SELECT * FROM OPENQUERY([server-sql], ''' + @q + N''')';
    EXEC (@sql);

    -- Líneas del almacén de las OV abiertas (para el detalle)
    CREATE TABLE #lin (DocNum INT, Linea INT, Codigo NVARCHAR(50), Descripcion NVARCHAR(200),
                       Cantidad DECIMAL(19,6), Unidad NVARCHAR(100));
    DECLARE @ql NVARCHAR(MAX) = N'
SELECT o.DocNum, l.LineNum,
       CAST(l.ItemCode AS NVARCHAR(50)) AS ItemCode,
       CAST(LEFT(l.Dscription, 200) AS NVARCHAR(200)) AS Dscription,
       CAST(l.Quantity AS DECIMAL(19,6)) AS Quantity,
       CAST(LEFT(l.unitMsr, 100) AS NVARCHAR(100)) AS unitMsr
FROM ' + @SapDb + N'.dbo.ORDR o
JOIN ' + @SapDb + N'.dbo.RDR1 l ON l.DocEntry = o.DocEntry' + @filtroWhs
        + @where + N' AND o.DocStatus = ''''O''''';
    SET @sql = N'INSERT INTO #lin SELECT * FROM OPENQUERY([server-sql], ''' + @ql + N''')';
    EXEC (@sql);

    -- Nuevas en '03' -> RECIBIDO
    INSERT INTO dbo.NotifPedido (Pais, DocType, DocNum, ClienteNombre, Celular, VendedorNombre, VendedorEmail,
                                 Direccion, FechaEntrega, Almacen, FechaRecibido, Silencioso)
    SELECT @Pais, 'OV', s.DocNum, s.Cliente, s.Celular, s.Vendedor, s.VendedorEmail,
           s.Direccion, s.FechaEntrega, s.Almacen, GETDATE(), @Silencioso
    FROM #sap s
    WHERE s.Cancelado = 0
      AND NOT EXISTS (SELECT 1 FROM dbo.NotifPedido n WHERE n.Pais = @Pais AND n.DocType = 'OV' AND n.DocNum = s.DocNum);

    -- Refrescar datos del mensaje y condiciones de entrega
    UPDATE n SET n.ClienteNombre = s.Cliente, n.Celular = s.Celular,
                 n.VendedorNombre = s.Vendedor, n.VendedorEmail = s.VendedorEmail,
                 n.Direccion = s.Direccion, n.FechaEntrega = s.FechaEntrega, n.Almacen = s.Almacen,
                 n.InstEntrega = NULLIF(LTRIM(RTRIM(s.InstEntrega)), ''),
                 n.Comentarios = NULLIF(LTRIM(RTRIM(s.Comentarios)), ''),
                 n.TonMax = s.TonMax,
                 n.Montacarga = NULLIF(s.Montacarga, ''), n.Cuadrilla = NULLIF(s.Cuadrilla, ''),
                 n.Latitud = NULLIF(LTRIM(RTRIM(s.Latitud)), ''), n.Longitud = NULLIF(LTRIM(RTRIM(s.Longitud)), ''),
                 n.FechaCancelado = CASE WHEN s.Cancelado = 1 AND n.FechaDespacho IS NULL
                                         THEN ISNULL(n.FechaCancelado, GETDATE()) ELSE n.FechaCancelado END
    FROM dbo.NotifPedido n
    JOIN #sap s ON s.DocNum = n.DocNum
    WHERE n.Pais = @Pais AND n.DocType = 'OV';

    -- Detalle (JSON) de las OV abiertas que trajeron líneas
    UPDATE n SET n.Detalle = (
        SELECT x.Linea AS linea, x.Codigo AS codigo, x.Descripcion AS descripcion,
               x.Cantidad AS cantidad, x.Unidad AS unidad
        FROM #lin x WHERE x.DocNum = n.DocNum
        ORDER BY x.Linea
        FOR JSON PATH)
    FROM dbo.NotifPedido n
    WHERE n.Pais = @Pais AND n.DocType = 'OV'
      AND EXISTS (SELECT 1 FROM #lin x WHERE x.DocNum = n.DocNum);
END
GO

-- Que todo se vuelva a subir con los campos nuevos
UPDATE dbo.NotifPedido SET HashSync = NULL;
GO
PRINT 'Notif_03: condiciones de entrega + detalle listos';
