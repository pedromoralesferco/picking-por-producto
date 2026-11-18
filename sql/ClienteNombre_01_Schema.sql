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

-- 2) SP centralizado: llena ClienteNombre de los pedidos de un cuadro (solo los NULL).
--    Best-effort: si el linked server a SAP falla, no rompe la ingesta.
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
PRINT 'ClienteNombre: columnas (ClienteNombre, Telefono) + IX_OPM_Cliente + SP_FillClienteNombre OK';
