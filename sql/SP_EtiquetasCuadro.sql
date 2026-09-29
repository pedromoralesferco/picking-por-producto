-- ============================================================
-- SP_EtiquetasCuadro — datos de etiquetas de empaque para BarTender.
-- Entrada: @RouteNumber (cuadro de ruta). Devuelve UNA FILA POR BULTO,
-- lista para que BarTender imprima una etiqueta por fila.
--   Columnas: Cuadro, Ruta, OV, Tipo, Cliente, DirLabel, Direccion,
--             Comentarios, Picker, FechaPicking, Bulto (corrido),
--             TotalBultos, BultoEnOV, BultosDeOV, Barcode.
-- Los bultos por OV salen de OrderPickingManagement.Bultos (default 1).
-- Cliente/Direccion/Comentarios se LEEN de SAP (server-sql) por país;
-- para TR el destino es OWTQ.ToWhsCode -> OWHS.WhsName. (Solo lectura de SAP.)
-- ============================================================

-- Columna de bultos por pedido (persistida; default 1)
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.COLUMNS
               WHERE TABLE_NAME = 'OrderPickingManagement' AND COLUMN_NAME = 'Bultos')
    ALTER TABLE dbo.OrderPickingManagement
        ADD Bultos INT NULL CONSTRAINT DF_OPM_Bultos DEFAULT (1);
GO

IF OBJECT_ID('dbo.SP_EtiquetasCuadro') IS NOT NULL DROP PROCEDURE dbo.SP_EtiquetasCuadro;
GO

CREATE PROCEDURE dbo.SP_EtiquetasCuadro
    @RouteNumber INT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Pais NVARCHAR(10), @sapDb NVARCHAR(50), @sql NVARCHAR(MAX);
    SELECT TOP 1 @Pais = Pais FROM dbo.OrderRoutePlan WHERE RouteNumber = @RouteNumber;
    SET @sapDb = CASE @Pais
                    WHEN 'SV' THEN 'sbointergres'
                    WHEN 'HN' THEN 'sbopym'
                    ELSE 'sboferco'    -- GT
                 END;

    IF OBJECT_ID('tempdb..#ped') IS NOT NULL DROP TABLE #ped;
    CREATE TABLE #ped (
        ID_OrderPicking INT,
        OV_Number   NVARCHAR(50)  COLLATE DATABASE_DEFAULT,
        DocType     NVARCHAR(10)  COLLATE DATABASE_DEFAULT,
        Bultos      INT,
        RouteNumber INT,
        RouteName   NVARCHAR(200) COLLATE DATABASE_DEFAULT,
        Picker      NVARCHAR(200) COLLATE DATABASE_DEFAULT,
        FechaPicking DATETIME,
        Cliente     NVARCHAR(200) COLLATE DATABASE_DEFAULT NULL,
        Direccion   NVARCHAR(400) COLLATE DATABASE_DEFAULT NULL,
        Comentarios NVARCHAR(500) COLLATE DATABASE_DEFAULT NULL,
        ovOrder     INT
    );

    INSERT #ped (ID_OrderPicking, OV_Number, DocType, Bultos, RouteNumber, RouteName, Picker, FechaPicking, ovOrder)
    SELECT opm.ID_OrderPicking, opm.OV_Number, opm.DocType, ISNULL(opm.Bultos, 1),
           orp.RouteNumber, orp.RouteName, o.Nombre,
           (SELECT MAX(t.UltimaActualizacion) FROM dbo.OrderPickingTask t WHERE t.ID_OrderPicking = opm.ID_OrderPicking),
           ROW_NUMBER() OVER (ORDER BY opm.OV_Number)
    FROM dbo.OrderPickingManagement opm
    INNER JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
    LEFT JOIN dbo.Operario o ON o.ID_Operario = opm.ID_Operario
    WHERE orp.RouteNumber = @RouteNumber;

    -- Enriquecer OVs desde SAP (cliente, dirección de entrega, comentarios)
    SET @sql = N'
        UPDATE p SET p.Cliente = c.CardName,
                     p.Direccion = LTRIM(RTRIM(ISNULL(NULLIF(o.Address2, ''''), o.Address))),
                     p.Comentarios = o.Comments
        FROM #ped p
        INNER JOIN [server-sql].[' + @sapDb + '].dbo.ORDR o WITH (NOLOCK) ON o.DocNum = TRY_CONVERT(INT, p.OV_Number)
        LEFT JOIN [server-sql].[' + @sapDb + '].dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
        WHERE p.DocType = ''OV'';';
    EXEC sp_executesql @sql;

    -- Enriquecer TRs desde SAP (destino = almacén ToWhsCode -> OWHS.WhsName, comentarios)
    SET @sql = N'
        UPDATE p SET p.Cliente = ''Traslado interno'',
                     p.Direccion = ISNULL(wh.WhsName, ''Almacen '' + o.ToWhsCode),
                     p.Comentarios = o.Comments
        FROM #ped p
        INNER JOIN [server-sql].[' + @sapDb + '].dbo.OWTQ o WITH (NOLOCK) ON o.DocNum = TRY_CONVERT(INT, p.OV_Number)
        LEFT JOIN [server-sql].[' + @sapDb + '].dbo.OWHS wh WITH (NOLOCK) ON wh.WhsCode = o.ToWhsCode
        WHERE p.DocType = ''TR'';';
    EXEC sp_executesql @sql;

    DECLARE @Total INT = (SELECT ISNULL(SUM(Bultos), 0) FROM #ped);

    -- Expandir por bulto y numerar corrido (1..TotalBultos) por el cuadro
    SELECT
        p.RouteNumber AS Cuadro,
        p.RouteName   AS Ruta,
        p.OV_Number   AS OV,
        p.DocType     AS Tipo,
        ISNULL(p.Cliente, CASE WHEN p.DocType = 'TR' THEN 'Traslado interno' ELSE '' END) AS Cliente,
        CASE WHEN p.DocType = 'TR' THEN 'Destino' ELSE 'Direccion' END AS DirLabel,
        ISNULL(p.Direccion, '')   AS Direccion,
        ISNULL(p.Comentarios, '') AS Comentarios,
        ISNULL(p.Picker, '')      AS Picker,
        p.FechaPicking,
        ROW_NUMBER() OVER (ORDER BY p.ovOrder, n.number) AS Bulto,
        @Total       AS TotalBultos,
        n.number     AS BultoEnOV,
        p.Bultos     AS BultosDeOV,
        p.OV_Number  AS Barcode
    FROM #ped p
    INNER JOIN master.dbo.spt_values n ON n.type = 'P' AND n.number BETWEEN 1 AND p.Bultos
    ORDER BY p.ovOrder, n.number;

    DROP TABLE #ped;
END;
GO
