-- ============================================================
-- ClienteNombre — persistir el nombre del cliente (OV) / destino (TR) en Picking,
-- poblado en la ingesta, para NO consultar SAP en cada carga del detalle del plan
-- de despachos y habilitar el filtro por cliente.
--
-- Guarda el nombre CRUDO (sin prefijos): OV -> OCRD.CardName; TR/RESURTIDO ->
-- OWHS.WhsName (destino). El frontend/endpoint le pone el prefijo "Traslado → " a
-- los TR (así el dato queda limpio y buscable por nombre de cliente).
-- RMA: se deja NULL (el detalle muestra "—").
--
-- Aplicar en Picking_Management (server-apps-tab). NO escribe a SAP.
-- ============================================================

-- 1) Columna + índice para el filtro por cliente
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.OrderPickingManagement') AND name = 'ClienteNombre')
    ALTER TABLE dbo.OrderPickingManagement ADD ClienteNombre NVARCHAR(150) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_OPM_Cliente' AND object_id = OBJECT_ID('dbo.OrderPickingManagement'))
    CREATE INDEX IX_OPM_Cliente ON dbo.OrderPickingManagement (ID_Centro, Pais, ClienteNombre);
GO
-- 1b) Teléfono de la OV (ORDR.U_Celular), para la confirmación de entregas en el
--     Plan de Despachos. Solo OV; TR/RESURTIDO/RMA quedan NULL.
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.OrderPickingManagement') AND name = 'Telefono')
    ALTER TABLE dbo.OrderPickingManagement ADD Telefono NVARCHAR(30) NULL;
GO

-- 2) Lectura DIRECTA (versión anterior, sin cambios): UPDATE ... JOIN de 4 partes.
--    Queda como respaldo de SP_FillClienteNombre si la lectura OPENQUERY falla.
--    Best-effort: si el linked server a SAP falla, no rompe la ingesta.
IF OBJECT_ID('dbo.SP_FillClienteNombre_Directo') IS NOT NULL
    DROP PROCEDURE dbo.SP_FillClienteNombre_Directo;
GO
CREATE PROCEDURE [dbo].[SP_FillClienteNombre_Directo]
    @ID_RoutePlan INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Pais NVARCHAR(10);
    SELECT @Pais = Pais FROM dbo.OrderRoutePlan WHERE ID_RoutePlan = @ID_RoutePlan;
    IF @Pais IS NULL RETURN;

    BEGIN TRY
        IF @Pais = 'GT'
        BEGIN
            UPDATE opm SET opm.ClienteNombre = LEFT(c.CardName, 150)
            FROM dbo.OrderPickingManagement opm
            JOIN [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK) ON o.DocNum = TRY_CAST(opm.OV_Number AS INT)
            JOIN [server-sql].sboferco.dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
            WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.DocType = 'OV' AND opm.ClienteNombre IS NULL;

            UPDATE opm SET opm.ClienteNombre = LEFT(ISNULL(w.WhsName, q.ToWhsCode), 150)
            FROM dbo.OrderPickingManagement opm
            JOIN [server-sql].sboferco.dbo.OWTQ q WITH (NOLOCK) ON q.DocNum = TRY_CAST(opm.OV_Number AS INT)
            LEFT JOIN [server-sql].sboferco.dbo.OWHS w WITH (NOLOCK) ON w.WhsCode = q.ToWhsCode
            WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.DocType IN ('TR','RESURTIDO') AND opm.ClienteNombre IS NULL;
        END
        ELSE IF @Pais = 'SV'
        BEGIN
            UPDATE opm SET opm.ClienteNombre = LEFT(c.CardName, 150)
            FROM dbo.OrderPickingManagement opm
            JOIN [server-sql].sbointergres.dbo.ORDR o WITH (NOLOCK) ON o.DocNum = TRY_CAST(opm.OV_Number AS INT)
            JOIN [server-sql].sbointergres.dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
            WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.DocType = 'OV' AND opm.ClienteNombre IS NULL;

            UPDATE opm SET opm.ClienteNombre = LEFT(ISNULL(w.WhsName, q.ToWhsCode), 150)
            FROM dbo.OrderPickingManagement opm
            JOIN [server-sql].sbointergres.dbo.OWTQ q WITH (NOLOCK) ON q.DocNum = TRY_CAST(opm.OV_Number AS INT)
            LEFT JOIN [server-sql].sbointergres.dbo.OWHS w WITH (NOLOCK) ON w.WhsCode = q.ToWhsCode
            WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.DocType IN ('TR','RESURTIDO') AND opm.ClienteNombre IS NULL;
        END
        ELSE IF @Pais = 'HN'
        BEGIN
            UPDATE opm SET opm.ClienteNombre = LEFT(c.CardName, 150)
            FROM dbo.OrderPickingManagement opm
            JOIN [server-sql].sbopym.dbo.ORDR o WITH (NOLOCK) ON o.DocNum = TRY_CAST(opm.OV_Number AS INT)
            JOIN [server-sql].sbopym.dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
            WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.DocType = 'OV' AND opm.ClienteNombre IS NULL;

            UPDATE opm SET opm.ClienteNombre = LEFT(ISNULL(w.WhsName, q.ToWhsCode), 150)
            FROM dbo.OrderPickingManagement opm
            JOIN [server-sql].sbopym.dbo.OWTQ q WITH (NOLOCK) ON q.DocNum = TRY_CAST(opm.OV_Number AS INT)
            LEFT JOIN [server-sql].sbopym.dbo.OWHS w WITH (NOLOCK) ON w.WhsCode = q.ToWhsCode
            WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.DocType IN ('TR','RESURTIDO') AND opm.ClienteNombre IS NULL;
        END
    END TRY
    BEGIN CATCH
        -- best-effort: el nombre de cliente no debe romper la ingesta si SAP no responde
        PRINT 'SP_FillClienteNombre aviso: ' + ERROR_MESSAGE();
    END CATCH

    -- Teléfono de la OV: SIEMPRE el campo "Celular" de la OV (ORDR.U_Celular), sin
    -- respaldos. Se ignoran valores basura (menos de 8 caracteres). Bloque aparte para
    -- que un fallo aquí no afecte el nombre de cliente.
    BEGIN TRY
        IF @Pais = 'GT'
            UPDATE opm SET opm.Telefono = LEFT(LTRIM(RTRIM(o.U_Celular)), 30)
            FROM dbo.OrderPickingManagement opm
            JOIN [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK) ON o.DocNum = TRY_CAST(opm.OV_Number AS INT)
            WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.DocType = 'OV' AND opm.Telefono IS NULL
              AND LEN(LTRIM(RTRIM(ISNULL(o.U_Celular, '')))) >= 8;
        ELSE IF @Pais = 'SV'
            UPDATE opm SET opm.Telefono = LEFT(LTRIM(RTRIM(o.U_Celular)), 30)
            FROM dbo.OrderPickingManagement opm
            JOIN [server-sql].sbointergres.dbo.ORDR o WITH (NOLOCK) ON o.DocNum = TRY_CAST(opm.OV_Number AS INT)
            WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.DocType = 'OV' AND opm.Telefono IS NULL
              AND LEN(LTRIM(RTRIM(ISNULL(o.U_Celular, '')))) >= 8;
        ELSE IF @Pais = 'HN'
            UPDATE opm SET opm.Telefono = LEFT(LTRIM(RTRIM(o.U_Celular)), 30)
            FROM dbo.OrderPickingManagement opm
            JOIN [server-sql].sbopym.dbo.ORDR o WITH (NOLOCK) ON o.DocNum = TRY_CAST(opm.OV_Number AS INT)
            WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.DocType = 'OV' AND opm.Telefono IS NULL
              AND LEN(LTRIM(RTRIM(ISNULL(o.U_Celular, '')))) >= 8;
    END TRY
    BEGIN CATCH
        PRINT 'SP_FillClienteNombre (telefono) aviso: ' + ERROR_MESSAGE();
    END CATCH
END;
GO

-- 3) SP centralizado (lo llaman SP_AddOrderRouteTasks, SP_AddDocToCuadroApp y
--    SP_ReimportOrderRouteLines al ingresar un cuadro): nombre del cliente (OV),
--    destino (TR/RESURTIDO) y teléfono (ORDR.U_Celular) de los pedidos del cuadro,
--    solo los que están en NULL.
--    UNA lectura a SAP por tipo de documento, filtrada en SAP por OPENQUERY
--    (DocNum IN (...)), en vez de tres UPDATE ... JOIN que traían ORDR completa.
--    Si algo falla, usa la lectura directa anterior (SP_FillClienteNombre_Directo).
IF OBJECT_ID('dbo.SP_FillClienteNombre') IS NOT NULL
    DROP PROCEDURE dbo.SP_FillClienteNombre;
GO
CREATE PROCEDURE [dbo].[SP_FillClienteNombre]
    @ID_RoutePlan INT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Pais NVARCHAR(10);
    SELECT @Pais = Pais FROM dbo.OrderRoutePlan WHERE ID_RoutePlan = @ID_RoutePlan;
    IF @Pais IS NULL RETURN;
    DECLARE @db SYSNAME = CASE @Pais WHEN 'GT' THEN 'sboferco' WHEN 'SV' THEN 'sbointergres' WHEN 'HN' THEN 'sbopym' END;
    IF @db IS NULL RETURN;

    BEGIN TRY
        CREATE TABLE #ov (DocNum INT, Cliente NVARCHAR(150) COLLATE DATABASE_DEFAULT, Celular NVARCHAR(30) COLLATE DATABASE_DEFAULT);
        CREATE TABLE #tr (DocNum INT, Destino NVARCHAR(150) COLLATE DATABASE_DEFAULT);
        DECLARE @lista NVARCHAR(MAX), @sql NVARCHAR(MAX);

        -- OV a las que les falta nombre o teléfono
        SELECT @lista = STUFF((
            SELECT DISTINCT ',' + CAST(TRY_CAST(OV_Number AS INT) AS VARCHAR(12))
            FROM dbo.OrderPickingManagement
            WHERE ID_RoutePlan = @ID_RoutePlan AND DocType = 'OV' AND TRY_CAST(OV_Number AS INT) IS NOT NULL
              AND (ClienteNombre IS NULL OR Telefono IS NULL)
            FOR XML PATH('')), 1, 1, '');
        IF @lista IS NOT NULL
        BEGIN
            IF LEN(@lista) > 7000 RAISERROR('Demasiados documentos para una sola consulta', 16, 1);
            SET @sql = N'INSERT INTO #ov (DocNum, Cliente, Celular) SELECT * FROM OPENQUERY([server-sql], '''
                     + N'SELECT o.DocNum, LEFT(c.CardName, 150) AS Cliente, LTRIM(RTRIM(o.U_Celular)) AS Celular '
                     + N'FROM ' + @db + N'.dbo.ORDR o WITH (NOLOCK) '
                     + N'LEFT JOIN ' + @db + N'.dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode '
                     + N'WHERE o.DocNum IN (' + @lista + N')'')';
            EXEC (@sql);
        END

        -- TR/RESURTIDO a los que les falta el destino
        SELECT @lista = NULL;
        SELECT @lista = STUFF((
            SELECT DISTINCT ',' + CAST(TRY_CAST(OV_Number AS INT) AS VARCHAR(12))
            FROM dbo.OrderPickingManagement
            WHERE ID_RoutePlan = @ID_RoutePlan AND DocType IN ('TR', 'RESURTIDO') AND TRY_CAST(OV_Number AS INT) IS NOT NULL
              AND ClienteNombre IS NULL
            FOR XML PATH('')), 1, 1, '');
        IF @lista IS NOT NULL
        BEGIN
            IF LEN(@lista) > 7000 RAISERROR('Demasiados documentos para una sola consulta', 16, 1);
            SET @sql = N'INSERT INTO #tr (DocNum, Destino) SELECT * FROM OPENQUERY([server-sql], '''
                     + N'SELECT q.DocNum, LEFT(ISNULL(w.WhsName, q.ToWhsCode), 150) AS Destino '
                     + N'FROM ' + @db + N'.dbo.OWTQ q WITH (NOLOCK) '
                     + N'LEFT JOIN ' + @db + N'.dbo.OWHS w WITH (NOLOCK) ON w.WhsCode = q.ToWhsCode '
                     + N'WHERE q.DocNum IN (' + @lista + N')'')';
            EXEC (@sql);
        END

        UPDATE opm SET opm.ClienteNombre = o.Cliente
        FROM dbo.OrderPickingManagement opm
        JOIN #ov o ON o.DocNum = TRY_CAST(opm.OV_Number AS INT)
        WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.DocType = 'OV' AND opm.ClienteNombre IS NULL;

        -- Teléfono: SIEMPRE el campo "Celular" de la OV; se ignoran valores de menos de 8 caracteres.
        UPDATE opm SET opm.Telefono = o.Celular
        FROM dbo.OrderPickingManagement opm
        JOIN #ov o ON o.DocNum = TRY_CAST(opm.OV_Number AS INT)
        WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.DocType = 'OV' AND opm.Telefono IS NULL
          AND LEN(ISNULL(o.Celular, '')) >= 8;

        UPDATE opm SET opm.ClienteNombre = t.Destino
        FROM dbo.OrderPickingManagement opm
        JOIN #tr t ON t.DocNum = TRY_CAST(opm.OV_Number AS INT)
        WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.DocType IN ('TR', 'RESURTIDO') AND opm.ClienteNombre IS NULL;
    END TRY
    BEGIN CATCH
        PRINT 'SP_FillClienteNombre: lectura OPENQUERY fallida, se usa la directa: ' + ERROR_MESSAGE();
        EXEC dbo.SP_FillClienteNombre_Directo @ID_RoutePlan;
    END CATCH
END;
GO
PRINT 'ClienteNombre: columnas (ClienteNombre, Telefono) + IX_OPM_Cliente + SP_FillClienteNombre (+ _Directo) OK';
