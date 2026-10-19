-- ============================================================
-- CRUD cuadros — Fase 3 (sync a SAP vía RPA): contrato de lectura + cierre de lazo.
-- NO escribe a SAP. El robot/Power Automate aplican el cambio en SAP y marcan la
-- fila del outbox como 'confirmado' (o 'error' + Error). Este reconciliador corre
-- en el app y, al ver 'confirmado', limpia los flags *Pendiente* y cierra la fila.
--
-- Ciclo de una edición:  pendiente → (PA/robot aplica en SAP) confirmado
--                         → (SP_ReconcileCuadroEdiciones) cerrado   [flags limpios]
-- Aditivo e idempotente.
-- ============================================================

-- Vista plana para que Power Automate/robot consuman las ediciones pendientes
-- sin parsear JSON. Incluye los campos de placa ya extraídos.
IF OBJECT_ID('dbo.vw_CuadroEdicionPendiente') IS NOT NULL DROP VIEW dbo.vw_CuadroEdicionPendiente;
GO
CREATE VIEW dbo.vw_CuadroEdicionPendiente AS
SELECT
    c.ID_Edicion,
    c.RouteNumber,
    -- DocEntry del cuadro en SAP (clave del UDO 'Cuadro_ruta' para GeneralService).
    -- RouteNumber negativo = complemento provisional aún no creado en SAP (DocEntry NULL).
    (SELECT TOP 1 e.DocEntry FROM [server-sql].sboferco.dbo.[@CUADRO_RUTA_E] e WITH (NOLOCK)
       WHERE e.DocNum = c.RouteNumber) AS CuadroDocEntry,
    c.Ambito,                         -- HEADER | LINEA
    c.Accion,                         -- PLACA | ADD | REMOVE
    c.OV_Number,
    c.DocType,
    c.Estado,                         -- pendiente | enviado | confirmado | error
    c.Intentos,
    c.Usuario,
    c.FechaCreacion,
    -- Campos de PLACA (NULL si no aplica)
    JSON_VALUE(c.Payload, '$.placa')         AS Placa,
    JSON_VALUE(c.Payload, '$.capacidad')     AS Capacidad,
    JSON_VALUE(c.Payload, '$.idCamion')      AS IDCamion,
    JSON_VALUE(c.Payload, '$.transportista') AS Transportista,
    JSON_VALUE(c.Payload, '$.cardCode')      AS CardCode,
    -- Campos de LINEA (destino de un quitado / cuadro al que se movió)
    JSON_VALUE(c.Payload, '$.destino')       AS Destino,
    JSON_VALUE(c.Payload, '$.aCuadro')       AS ACuadro,
    -- Datos de la línea del cuadro para ADD (peso del app; cliente/dir/asesor de SAP).
    (SELECT TOP 1 opm.PesoTotal FROM dbo.OrderPickingManagement opm
       INNER JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
       WHERE orp.RouteNumber = c.RouteNumber
         AND opm.OV_Number COLLATE DATABASE_DEFAULT = c.OV_Number COLLATE DATABASE_DEFAULT
         AND opm.DocType = c.DocType) AS LineaPeso,
    -- OJO: en el cuadro, U_Codigo_Cliente guarda el NOMBRE del cliente (no el CardCode).
    CASE WHEN c.DocType = 'OV' THEN (SELECT TOP 1 oc.CardName FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK) LEFT JOIN [server-sql].sboferco.dbo.OCRD oc WITH (NOLOCK) ON oc.CardCode = o.CardCode WHERE o.DocNum = TRY_CAST(c.OV_Number AS INT))
         WHEN c.DocType IN ('TR','RESURTIDO') THEN (SELECT TOP 1 oc.CardName FROM [server-sql].sboferco.dbo.OWTQ q WITH (NOLOCK) LEFT JOIN [server-sql].sboferco.dbo.OCRD oc WITH (NOLOCK) ON oc.CardCode = q.CardCode WHERE q.DocNum = TRY_CAST(c.OV_Number AS INT))
    END AS LineaCodigoCliente,
    CASE WHEN c.DocType = 'OV' THEN (SELECT TOP 1 LEFT(o.Comments, 250) FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK) WHERE o.DocNum = TRY_CAST(c.OV_Number AS INT))
         WHEN c.DocType IN ('TR','RESURTIDO') THEN (SELECT TOP 1 LEFT(q.Comments, 250) FROM [server-sql].sboferco.dbo.OWTQ q WITH (NOLOCK) WHERE q.DocNum = TRY_CAST(c.OV_Number AS INT))
    END AS LineaComentario,
    CASE WHEN c.DocType = 'OV' THEN (SELECT TOP 1 LEFT(ISNULL(o.Address2, oc.Address), 200) FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK) LEFT JOIN [server-sql].sboferco.dbo.OCRD oc WITH (NOLOCK) ON oc.CardCode = o.CardCode WHERE o.DocNum = TRY_CAST(c.OV_Number AS INT))
         WHEN c.DocType IN ('TR','RESURTIDO') THEN (SELECT TOP 1 w.WhsName FROM [server-sql].sboferco.dbo.OWTQ q WITH (NOLOCK) LEFT JOIN [server-sql].sboferco.dbo.OWHS w WITH (NOLOCK) ON w.WhsCode = q.ToWhsCode WHERE q.DocNum = TRY_CAST(c.OV_Number AS INT))
    END AS LineaDireccion,
    CASE WHEN c.DocType = 'OV' THEN (SELECT TOP 1 s.SlpName FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK) LEFT JOIN [server-sql].sboferco.dbo.OSLP s WITH (NOLOCK) ON s.SlpCode = o.SlpCode WHERE o.DocNum = TRY_CAST(c.OV_Number AS INT))
         ELSE NULL END AS LineaAsesor,
    -- Centro de costo: 1) copiar el del origen (su línea actual en @CUADRO_RUTA_D);
    --                   2) fallback: de la sucursal del pedido (OV) vía @SUCURSAL_CCOSTO.
    COALESCE(
        CAST((SELECT TOP 1 d.U_Centro_Costo FROM [server-sql].sboferco.dbo.[@CUADRO_RUTA_D] d WITH (NOLOCK)
                WHERE d.U_No_OV COLLATE DATABASE_DEFAULT = c.OV_Number COLLATE DATABASE_DEFAULT
                  AND d.U_Tipo_Documento = c.DocType AND d.U_Centro_Costo IS NOT NULL) AS NVARCHAR(20)),
        CASE WHEN c.DocType = 'OV' THEN CAST((SELECT TOP 1 sc.U_CCosto FROM [server-sql].sboferco.dbo.ORDR o WITH (NOLOCK)
                JOIN [server-sql].sboferco.dbo.[@SUCURSAL_CCOSTO] sc WITH (NOLOCK) ON sc.Name COLLATE DATABASE_DEFAULT = o.U_sucursal COLLATE DATABASE_DEFAULT
                WHERE o.DocNum = TRY_CAST(c.OV_Number AS INT)) AS NVARCHAR(20)) END
    ) AS LineaCentroCosto,
    c.Payload
FROM dbo.CuadroEdicionCola c
WHERE c.Estado IN ('pendiente', 'enviado', 'error')
GO

-- Cierra el lazo: por cada edición 'confirmado' por SAP, limpia el flag que
-- corresponda y marca la fila 'cerrado'. Los reconciliadores edit-aware dejan de
-- intervenir porque ya no hay *Pendiente* que proteger.
IF OBJECT_ID('dbo.SP_ReconcileCuadroEdiciones') IS NOT NULL DROP PROCEDURE dbo.SP_ReconcileCuadroEdiciones;
GO
CREATE PROCEDURE [dbo].[SP_ReconcileCuadroEdiciones]
AS
BEGIN
    SET NOCOUNT ON;

    IF NOT EXISTS (SELECT 1 FROM dbo.CuadroEdicionCola WHERE Estado = 'confirmado') RETURN;

    -- PLACA: SAP ya tiene la placa → quitar el pendiente del encabezado.
    UPDATE orp SET orp.PlacaPendienteSync = 0
    FROM dbo.OrderRoutePlan orp
    INNER JOIN dbo.CuadroEdicionCola c ON c.RouteNumber = orp.RouteNumber
    WHERE c.Estado = 'confirmado' AND c.Accion = 'PLACA' AND orp.ID_Centro = 3 AND orp.PlacaPendienteSync = 1;

    -- ADD: SAP ya tiene la línea → quitar PendienteSync del documento en ese cuadro.
    UPDATE opm SET opm.PendienteSync = 0
    FROM dbo.OrderPickingManagement opm
    INNER JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
    INNER JOIN dbo.CuadroEdicionCola c
        ON c.RouteNumber = orp.RouteNumber
       AND c.OV_Number COLLATE DATABASE_DEFAULT = opm.OV_Number COLLATE DATABASE_DEFAULT
       AND c.DocType = opm.DocType
    WHERE c.Estado = 'confirmado' AND c.Accion = 'ADD' AND opm.PendienteSync = 1;

    -- REMOVE (eliminar): SAP ya quitó la línea → quitar RemocionPendienteSync del
    -- documento oculto que quedó en ese cuadro. (En 'mover', el OPM ya no está en el
    -- cuadro origen, así que no hay fila que tocar aquí; su alta la cierra el ADD.)
    UPDATE opm SET opm.RemocionPendienteSync = 0
    FROM dbo.OrderPickingManagement opm
    INNER JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
    INNER JOIN dbo.CuadroEdicionCola c
        ON c.RouteNumber = orp.RouteNumber
       AND c.OV_Number COLLATE DATABASE_DEFAULT = opm.OV_Number COLLATE DATABASE_DEFAULT
       AND c.DocType = opm.DocType
    WHERE c.Estado = 'confirmado' AND c.Accion = 'REMOVE' AND opm.RemocionPendienteSync = 1;

    -- Cerrar las filas ya reconciliadas.
    UPDATE dbo.CuadroEdicionCola SET Estado = 'cerrado', FechaSync = GETDATE()
    WHERE Estado = 'confirmado';
END;
GO

PRINT 'CuadroSync Fase 3: vista + reconciliador OK';
