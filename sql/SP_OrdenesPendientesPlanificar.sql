-- ============================================================
-- SP_OrdenesPendientesPlanificar  (Zona 5 / GT - sboferco)
--
-- Devuelve las órdenes de venta pendientes de planificar en
-- formato de planilla, filtradas a entregas tipo RUTA (TrnspCode 22).
-- Vive en Picking_Management y consulta sboferco por linked server.
--
-- Parámetros:
--   @FechaEntrega DATE  -> fecha de entrega (DocDueDate). NULL = mañana.
--   @Bodega NVARCHAR(20) -> almacén (WhsCode). Default '01'.
--
-- Nota: TrnspCode=22 (RUTA) queda fijo; si luego se quiere jugar con
--       el tipo de entrega, se parametriza igual que @Bodega.
-- ============================================================
IF OBJECT_ID('dbo.SP_OrdenesPendientesPlanificar') IS NOT NULL
    DROP PROCEDURE dbo.SP_OrdenesPendientesPlanificar;
GO
CREATE PROCEDURE [dbo].[SP_OrdenesPendientesPlanificar]
    @FechaEntrega DATE = NULL,
    @Bodega       NVARCHAR(20) = '01'
AS
BEGIN
    SET NOCOUNT ON;

    IF @FechaEntrega IS NULL
        SET @FechaEntrega = CAST(DATEADD(day, 1, GETDATE()) AS DATE);

    SELECT
        CAST(T0.DocNum AS NVARCHAR) + ' - ' + (T0.CardName) AS 'Documento',
        '' AS 'Descripcion (opcional)',
        '' AS 'Usuario (opcional)',
        '' AS 'Geocerca (opcional)',
        '' AS 'Formularios (opcional)',
        CONVERT(VARCHAR, @FechaEntrega, 103) AS 'Fecha programada',
        '' AS 'Hora inicio',
        '' AS 'Fechan fin',
        '' AS 'Hora fin',
        T0.Address2 AS 'Direccion',
        T0.Comments AS 'Direccion',
        '' AS 'Telefono de Contacto',
        '' AS 'Tipo de tarea',
        '' AS 'Correo electronico de contacto',
        '' AS 'Telefonos para notificaciones',
        '' AS ' Correos para notificaciones',
        '' AS 'Id remoto',
        '' AS 'Duracion',
        '08:00' AS 'Ventana horaria de entrega',
        '21:00' AS 'Ventana horaria de entrega',
        T1.Itemcode AS 'SKU Articulo',
        T1.Dscription AS 'Descripcion Articulo',
        T1.Quantity AS 'Cantidad de Articulos',
        '' AS 'Volumen del Articulo',
        (SELECT
            CASE WHEN T5.ItmsGrpNam LIKE '%(6)%' THEN '200'
                 ELSE T2.SWeight1
            END) AS 'Peso del Articulo'
    FROM [server-sql].sboferco.dbo.ORDR T0
    INNER JOIN [server-sql].sboferco.dbo.RDR1 T1 ON T0.DocEntry = T1.DocEntry
    INNER JOIN [server-sql].sboferco.dbo.OITM T2 ON T1.ItemCode = T2.ItemCode
    INNER JOIN [server-sql].sboferco.dbo.OCRD T3 ON T0.CardCode = T3.CardCode
    INNER JOIN [server-sql].sboferco.dbo.OWHS T4 ON T1.WhsCode = T4.WhsCode
    INNER JOIN [server-sql].sboferco.dbo.OITB T5 ON T2.ItmsGrpCod = T5.ItmsGrpCod
    INNER JOIN [server-sql].sboferco.dbo.OOCR T6 ON T1.OcrCode = T6.OcrCode
    INNER JOIN [server-sql].sboferco.dbo.OSLP T7 ON T0.SlpCode = T7.SlpCode
    WHERE
        T0.U_Estado2 = '03'
        AND T1.WhsCode = @Bodega
        AND T0.TrnspCode = 22                                  -- ENTREGA "RUTA"
        AND T1.ItemCode NOT IN ('013956', '031780')
        AND CAST(T0.DocDueDate AS DATE) = @FechaEntrega
    GROUP BY
        T0.DocNum, T0.Address2, T1.Dscription, T1.Quantity, T1.ItemCode,
        T0.DocDueDate, T2.SWeight1, T0.CardCode, T0.CardName, T3.Phone1,
        T3.E_Mail, T0.Weight, T5.ItmsGrpNam, T0.Comments, T6.OcrName,
        T6.OcrCode, T7.SlpName, T7.Email, T0.U_Celular, T0.ObjType
    ORDER BY T0.DocDueDate;
END;
GO
