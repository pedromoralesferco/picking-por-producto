-- ============================================================
-- CRUD cuadros — Fase 4 (complemento): el robot crea el cuadro nuevo en SAP y
-- luego remapea el RouteNumber provisional (negativo) al DocNum real.
-- NO escribe a SAP. Aditivo e idempotente.
-- ============================================================

-- Líneas del/los complemento(s) provisional(es), para que el robot arme el cuadro.
-- Una fila por documento; header repetido (NombreRuta/AlmacenOrigen). Peso del app;
-- cliente/dirección/asesor de SAP (como en vw_CuadroEdicionPendiente).
IF OBJECT_ID('dbo.vw_ComplementoLineas') IS NOT NULL DROP VIEW dbo.vw_ComplementoLineas;
GO
CREATE VIEW dbo.vw_ComplementoLineas AS
SELECT
    orp.RouteNumber,                       -- negativo provisional
    orp.RouteName       AS NombreRuta,
    orp.AlmacenOrigen,
    opm.OV_Number,
    opm.DocType,
    ISNULL(opm.PesoTotal, 0) AS Peso,
    orp.FechaPlanDespacho AS FechaEntrega,
    -- U_Codigo_Cliente guarda el NOMBRE del cliente (como en los cuadros reales).
    CASE WHEN opm.DocType = 'OV' THEN (SELECT TOP 1 oc.CardName FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK) LEFT JOIN [server-sql].sboferco.dbo.OCRD oc WITH (NOLOCK) ON oc.CardCode = o.CardCode WHERE o.DocNum = TRY_CAST(opm.OV_Number AS INT))
         WHEN opm.DocType IN ('TR','RESURTIDO') THEN (SELECT TOP 1 oc.CardName FROM [server-sql].sboferco.dbo.OWTQ q WITH (NOLOCK) LEFT JOIN [server-sql].sboferco.dbo.OCRD oc WITH (NOLOCK) ON oc.CardCode = q.CardCode WHERE q.DocNum = TRY_CAST(opm.OV_Number AS INT))
    END AS CodigoCliente,
    CASE WHEN opm.DocType = 'OV' THEN (SELECT TOP 1 LEFT(o.Comments, 250) FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK) WHERE o.DocNum = TRY_CAST(opm.OV_Number AS INT))
         WHEN opm.DocType IN ('TR','RESURTIDO') THEN (SELECT TOP 1 LEFT(q.Comments, 250) FROM [server-sql].sboferco.dbo.OWTQ q WITH (NOLOCK) WHERE q.DocNum = TRY_CAST(opm.OV_Number AS INT))
    END AS Comentario,
    CASE WHEN opm.DocType = 'OV' THEN (SELECT TOP 1 LEFT(ISNULL(o.Address2, oc.Address), 200) FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK) LEFT JOIN [server-sql].sboferco.dbo.OCRD oc WITH (NOLOCK) ON oc.CardCode = o.CardCode WHERE o.DocNum = TRY_CAST(opm.OV_Number AS INT))
         WHEN opm.DocType IN ('TR','RESURTIDO') THEN (SELECT TOP 1 w.WhsName FROM [server-sql].sboferco.dbo.OWTQ q WITH (NOLOCK) LEFT JOIN [server-sql].sboferco.dbo.OWHS w WITH (NOLOCK) ON w.WhsCode = q.ToWhsCode WHERE q.DocNum = TRY_CAST(opm.OV_Number AS INT))
    END AS Direccion,
    CASE WHEN opm.DocType = 'OV' THEN (SELECT TOP 1 s.SlpName FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK) LEFT JOIN [server-sql].sboferco.dbo.OSLP s WITH (NOLOCK) ON s.SlpCode = o.SlpCode WHERE o.DocNum = TRY_CAST(opm.OV_Number AS INT))
         ELSE NULL END AS Asesor,
    COALESCE(
        CAST((SELECT TOP 1 d.U_Centro_Costo FROM [server-sql].sboferco.dbo.[@CUADRO_RUTA_D] d WITH (NOLOCK)
                WHERE d.U_No_OV COLLATE DATABASE_DEFAULT = opm.OV_Number COLLATE DATABASE_DEFAULT
                  AND d.U_Tipo_Documento = opm.DocType AND d.U_Centro_Costo IS NOT NULL) AS NVARCHAR(20)),
        CASE WHEN opm.DocType = 'OV' THEN CAST((SELECT TOP 1 sc.U_CCosto FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK)
                JOIN [server-sql].sboferco.dbo.[@SUCURSAL_CCOSTO] sc WITH (NOLOCK) ON sc.Name COLLATE DATABASE_DEFAULT = o.U_sucursal COLLATE DATABASE_DEFAULT
                WHERE o.DocNum = TRY_CAST(opm.OV_Number AS INT)) AS NVARCHAR(20)) END
    ) AS CentroCosto
FROM dbo.OrderRoutePlan orp
INNER JOIN dbo.OrderPickingManagement opm ON opm.ID_RoutePlan = orp.ID_RoutePlan
WHERE orp.EsComplemento = 1 AND orp.CreacionPendienteSync = 1 AND opm.NoDespachada = 0;
GO

-- Remapea el complemento provisional (@Prov, negativo) al DocNum real (@RealDocNum)
-- que SAP asignó al crearlo. Cierra la fila CREATE del outbox y limpia los flags.
IF OBJECT_ID('dbo.SP_RemapComplemento') IS NOT NULL DROP PROCEDURE dbo.SP_RemapComplemento;
GO
CREATE PROCEDURE [dbo].[SP_RemapComplemento]
    @Prov       INT,   -- RouteNumber provisional (negativo)
    @RealDocNum INT    -- DocNum real asignado por SAP
AS
BEGIN
    SET NOCOUNT ON;
    IF @Prov >= 0 OR @RealDocNum IS NULL OR @RealDocNum <= 0
    BEGIN RAISERROR('Parámetros inválidos (Prov debe ser negativo, RealDocNum positivo).', 16, 1); RETURN; END

    BEGIN TRY
        BEGIN TRAN;

        -- Race con la ingesta: si ya creó un ORP para el DocNum real, lo quitamos
        -- para conservar NUESTRO cuadro provisional (que trae el avance movido).
        IF EXISTS (SELECT 1 FROM dbo.OrderRoutePlan WHERE RouteNumber = @RealDocNum AND ISNULL(EsComplemento,0) = 0)
        BEGIN
            DELETE t FROM dbo.OrderPickingTask t
              INNER JOIN dbo.OrderPickingManagement o ON o.ID_OrderPicking = t.ID_OrderPicking
              INNER JOIN dbo.OrderRoutePlan r ON r.ID_RoutePlan = o.ID_RoutePlan
              WHERE r.RouteNumber = @RealDocNum AND ISNULL(r.EsComplemento,0) = 0;
            DELETE o FROM dbo.OrderPickingManagement o
              INNER JOIN dbo.OrderRoutePlan r ON r.ID_RoutePlan = o.ID_RoutePlan
              WHERE r.RouteNumber = @RealDocNum AND ISNULL(r.EsComplemento,0) = 0;
            DELETE FROM dbo.OrderRoutePlan WHERE RouteNumber = @RealDocNum AND ISNULL(EsComplemento,0) = 0;
        END

        -- Renombrar el provisional → real
        UPDATE dbo.OrderPickingManagement SET RouteNumber = @RealDocNum, PendienteSync = 0 WHERE RouteNumber = @Prov;
        UPDATE dbo.OrderPickingTask       SET RouteNumber = @RealDocNum WHERE RouteNumber = @Prov;
        UPDATE dbo.OrderRoutePlan         SET RouteNumber = @RealDocNum, CreacionPendienteSync = 0 WHERE RouteNumber = @Prov AND EsComplemento = 1;
        -- Remapear referencias en el outbox y cerrar la orden CREATE
        UPDATE dbo.CuadroEdicionCola SET RouteNumber = @RealDocNum WHERE RouteNumber = @Prov;
        UPDATE dbo.CuadroEdicionCola SET Estado = 'cerrado', FechaSync = GETDATE()
            WHERE RouteNumber = @RealDocNum AND Accion = 'CREATE' AND Estado <> 'cerrado';

        COMMIT;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        DECLARE @em NVARCHAR(2000) = ERROR_MESSAGE();
        RAISERROR(@em, 16, 1);
    END CATCH
END;
GO

PRINT 'CuadroSync Fase 4 (complemento): vista + remap OK';
