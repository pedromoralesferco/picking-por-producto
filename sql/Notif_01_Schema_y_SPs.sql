-- ════════════════════════════════════════════════════════════════════
-- Notificaciones a clientes — lado SQL Server (Picking_Management)
-- BORRADOR / PROPUESTA. No se ha corrido en producción.
--
-- dbo.NotifPedido es el espejo local de notif.pedido (Supabase). Lo llenan
-- dos SPs y el job de Node (server.js) empuja a Supabase lo que cambió:
--
--   SP_NotifDetectarSAP @Pais   (cada 10 min, lee SAP por OPENQUERY)
--       hito 1 RECIBIDO: OV con U_Estado2='03' -> fila nueva. SAP no guarda
--       cuándo pasó a '03', así que FechaRecibido = primera vez que la vimos.
--       También refresca nombre/celular/dirección/fecha y detecta cancelaciones.
--
--   SP_NotifHitos               (cada 10 min, mismo ciclo, solo tablas locales)
--       hito 3 PLANIFICADO, 4 PICKING_INICIADO, 5 PICKING_COMPLETADO,
--       6 DESPACHADO, leídos de OrderPickingManagement / OrderRoutePlan.
--       Modo pedido (SV/HN): fechas por pedido (opm). Modo producto (GT):
--       fechas del cuadro (orp). Se usa COALESCE(opm, orp).
--
-- Una fecha ya puesta nunca se sobreescribe (ISNULL(actual, nueva)).
-- Sincronización: HashActual <> HashSync => pendiente de subir.
-- Solo OV: TR y RMA no tienen ORDR.U_Celular.
-- ════════════════════════════════════════════════════════════════════

USE Picking_Management;
GO


IF OBJECT_ID('dbo.NotifPedido') IS NULL
BEGIN
    CREATE TABLE dbo.NotifPedido (
        Pais               NVARCHAR(10)  NOT NULL,
        DocType            NVARCHAR(10)  NOT NULL CONSTRAINT DF_NotifPedido_DocType DEFAULT 'OV',
        DocNum             INT           NOT NULL,
        -- datos del mensaje
        ClienteNombre      NVARCHAR(150) NULL,
        Celular            NVARCHAR(50)  NULL,        -- ORDR.U_Celular crudo (lo normaliza sync_notif.ps1)
        VendedorNombre     NVARCHAR(155) NULL,        -- OSLP.SlpName
        VendedorEmail      NVARCHAR(100) NULL,        -- OSLP.Email
        Direccion          NVARCHAR(254) NULL,
        FechaEntrega       DATE          NULL,
        Almacen            NVARCHAR(10)  NULL,        -- RDR1.WhsCode (ej. '138'); va a Supabase como "centro"
        ID_Centro          INT           NULL,
        CuadroActual       INT           NULL,
        Placa              NVARCHAR(20)  NULL,
        -- hitos
        FechaRecibido      DATETIME      NOT NULL,
        FechaPlanificado   DATETIME      NULL,
        FechaPickingInicio DATETIME      NULL,
        FechaPickingFin    DATETIME      NULL,
        FechaDespacho      DATETIME      NULL,
        FechaCancelado     DATETIME      NULL,
        -- control de sync
        HashActual AS CHECKSUM(ClienteNombre, Celular, VendedorNombre, VendedorEmail, Direccion, FechaEntrega, Almacen, ID_Centro, CuadroActual, Placa,
                               FechaPlanificado, FechaPickingInicio, FechaPickingFin, FechaDespacho, FechaCancelado),
        HashSync           INT           NULL,        -- NULL = nunca subido
        FechaSync          DATETIME      NULL,
        Silencioso         BIT           NOT NULL CONSTRAINT DF_NotifPedido_Silencioso DEFAULT 0, -- carga inicial: no avisar
        CONSTRAINT PK_NotifPedido PRIMARY KEY (Pais, DocType, DocNum)
    );
END
GO

-- ────────────────────────────────────────────────────────────────────
-- SP_NotifDetectarSAP: hito RECIBIDO + datos del cliente + cancelaciones
-- @SapDb viene de config/paises.js (sboferco, sbointergres, sbopym).
-- @Almacenes: lista de WhsCode separados por coma (ej. '138' o '138,01').
--   Solo entran OV con al menos una línea de esos almacenes. NULL = todos.
-- @SoloRuta = 1 limita a TrnspCode=22 (entrega en RUTA). Default 0: todos los tipos de entrega.
-- ────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.SP_NotifDetectarSAP') IS NOT NULL DROP PROCEDURE dbo.SP_NotifDetectarSAP;
GO
CREATE PROCEDURE dbo.SP_NotifDetectarSAP
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

    -- Primera corrida de un país (aún no tiene filas): siempre silenciosa, para
    -- no avisar de todo lo que ya estaba abierto aunque se olvide el -Silencioso.
    IF NOT EXISTS (SELECT 1 FROM dbo.NotifPedido WHERE Pais = @Pais) SET @Silencioso = 1;

    CREATE TABLE #sap (DocNum INT PRIMARY KEY, Cliente NVARCHAR(150), Celular NVARCHAR(50),
                       Vendedor NVARCHAR(155), VendedorEmail NVARCHAR(100),
                       Direccion NVARCHAR(254), FechaEntrega DATE, Cancelado BIT, Almacen NVARCHAR(10));

    -- OPENQUERY: el filtro corre en SAP (igual que Planificacion_02_Backlog).
    -- Trae las '03' abiertas y las canceladas recientes (para el hito CANCELADO).
    DECLARE @q NVARCHAR(MAX) = N'
SELECT o.DocNum,
       CAST(LEFT(o.CardName, 150)  AS NVARCHAR(150)) AS CardName,
       CAST(LEFT(o.U_Celular, 50)  AS NVARCHAR(50))  AS U_Celular,
       CAST(LEFT(s.SlpName, 155)   AS NVARCHAR(155)) AS SlpName,
       CAST(LEFT(s.Email, 100)     AS NVARCHAR(100)) AS Email,
       CAST(LEFT(CAST(o.Address2 AS NVARCHAR(MAX)), 254) AS NVARCHAR(254)) AS Address2,
       CAST(o.DocDueDate AS DATE) AS DocDueDate,
       CASE WHEN o.CANCELED = ''''Y'''' THEN 1 ELSE 0 END AS Cancelado,
       a.Almacen
FROM ' + @SapDb + N'.dbo.ORDR o
LEFT JOIN ' + @SapDb + N'.dbo.OSLP s ON s.SlpCode = o.SlpCode
CROSS APPLY (SELECT CAST(MIN(l.WhsCode) AS NVARCHAR(10)) AS Almacen
             FROM ' + @SapDb + N'.dbo.RDR1 l
             WHERE l.DocEntry = o.DocEntry' + @filtroWhs + N') a
WHERE o.DocDate >= DATEADD(day, -60, GETDATE())
  AND a.Almacen IS NOT NULL
  AND (o.U_Estado2 = ''''03'''' OR (o.CANCELED = ''''Y'''' AND o.UpdateDate >= DATEADD(day, -7, GETDATE())))'
        + CASE WHEN @SoloRuta = 1 THEN N' AND o.TrnspCode = 22' ELSE N'' END;

    DECLARE @sql NVARCHAR(MAX) = N'INSERT INTO #sap SELECT * FROM OPENQUERY([server-sql], ''' + @q + N''')';
    EXEC (@sql);

    -- Nuevas en '03' -> RECIBIDO
    INSERT INTO dbo.NotifPedido (Pais, DocType, DocNum, ClienteNombre, Celular, VendedorNombre, VendedorEmail,
                                 Direccion, FechaEntrega, Almacen, FechaRecibido, Silencioso)
    SELECT @Pais, 'OV', s.DocNum, s.Cliente, s.Celular, s.Vendedor, s.VendedorEmail,
           s.Direccion, s.FechaEntrega, s.Almacen, GETDATE(), @Silencioso
    FROM #sap s
    WHERE s.Cancelado = 0
      AND NOT EXISTS (SELECT 1 FROM dbo.NotifPedido n WHERE n.Pais = @Pais AND n.DocType = 'OV' AND n.DocNum = s.DocNum);

    -- Refrescar datos del mensaje (cambian en SAP: dirección, fecha, celular)
    UPDATE n SET n.ClienteNombre = s.Cliente, n.Celular = s.Celular,
                 n.VendedorNombre = s.Vendedor, n.VendedorEmail = s.VendedorEmail,
                 n.Direccion = s.Direccion, n.FechaEntrega = s.FechaEntrega, n.Almacen = s.Almacen,
                 n.FechaCancelado = CASE WHEN s.Cancelado = 1 AND n.FechaDespacho IS NULL
                                         THEN ISNULL(n.FechaCancelado, GETDATE()) ELSE n.FechaCancelado END
    FROM dbo.NotifPedido n
    JOIN #sap s ON s.DocNum = n.DocNum
    WHERE n.Pais = @Pais AND n.DocType = 'OV';
END
GO

-- ────────────────────────────────────────────────────────────────────
-- SP_NotifHitos: hitos 3-6 desde las tablas del app (cada 10 min, mismo ciclo)
-- Si la OV está en varios cuadros (complementos), manda el cuadro más
-- reciente; las fechas guardan la PRIMERA vez que ocurrió cada hito.
-- Se ignoran las líneas marcadas NoDespachada.
-- ────────────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.SP_NotifHitos') IS NOT NULL DROP PROCEDURE dbo.SP_NotifHitos;
GO
CREATE PROCEDURE dbo.SP_NotifHitos
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH x AS (
        SELECT opm.Pais COLLATE DATABASE_DEFAULT AS Pais,
               TRY_CAST(opm.OV_Number AS INT)    AS DocNum,
               orp.RouteNumber, orp.ID_Centro,
               NULLIF(LTRIM(RTRIM(orp.PlacaApp)), '') AS Placa,
               COALESCE(opm.FechaInicio, orp.FechaInicio) AS PickIni,
               CASE WHEN opm.Estado = 'Finalizado' OR orp.Estado = 'Finalizado'
                    THEN COALESCE(opm.FechaFin, orp.FechaFin, GETDATE()) END AS PickFin,
               CASE WHEN orp.EstadoDespacho = 'Finalizado'
                    THEN ISNULL(orp.FechaDespachoFin, GETDATE()) END AS Despacho,
               ROW_NUMBER() OVER (PARTITION BY opm.Pais, opm.OV_Number ORDER BY orp.ID_RoutePlan DESC) AS rn
        FROM dbo.OrderPickingManagement opm
        JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
        WHERE opm.DocType = 'OV'
          AND ISNULL(opm.NoDespachada, 0) = 0
    )
    UPDATE n SET
        n.CuadroActual       = x.RouteNumber,
        n.ID_Centro          = x.ID_Centro,
        n.Placa              = ISNULL(x.Placa, n.Placa),
        n.FechaPlanificado   = ISNULL(n.FechaPlanificado,   GETDATE()),   -- primera vez que la vemos en un cuadro
        n.FechaPickingInicio = ISNULL(n.FechaPickingInicio, x.PickIni),
        n.FechaPickingFin    = ISNULL(n.FechaPickingFin,    x.PickFin),
        n.FechaDespacho      = ISNULL(n.FechaDespacho,      x.Despacho)
    FROM dbo.NotifPedido n
    JOIN x ON x.rn = 1 AND x.Pais = n.Pais AND x.DocNum = n.DocNum
    WHERE n.DocType = 'OV'
      AND n.FechaCancelado IS NULL
      AND n.FechaDespacho IS NULL                        -- solo pedidos abiertos
      AND n.FechaRecibido >= DATEADD(day, -60, GETDATE());
END
GO

-- Un solo ciclo cada ~10 min: Detectar (por país) -> Hitos -> push. Así una
-- fila nueva sube ya con sus hitos y no se avisa de cosas viejas.
-- Fechas: db.js usa useUTC:false, así que el server debe estar en hora local
-- del país al serializar a ISO para timestamptz.
-- Lo que el job de Node sube en cada ciclo (lotes de 500):
--   SELECT TOP 500 *, HashActual AS HashLeido FROM dbo.NotifPedido
--   WHERE HashSync IS NULL OR HashSync <> HashActual ORDER BY FechaRecibido;
-- y tras el 2xx de Supabase, por cada fila:
--   UPDATE dbo.NotifPedido SET HashSync = @HashLeido, FechaSync = GETDATE(), Silencioso = 0
--   WHERE Pais=@Pais AND DocType=@DocType AND DocNum=@DocNum;
-- (si la fila cambió entre la lectura y el UPDATE, HashActual ya no es
--  HashLeido y se vuelve a subir en el siguiente ciclo).
PRINT 'Notif_01: NotifPedido + SP_NotifDetectarSAP + SP_NotifHitos';
