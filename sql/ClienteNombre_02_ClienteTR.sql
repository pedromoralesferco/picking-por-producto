-- ============================================================
-- ClienteTR — nombre del cliente final de los TR (solicitudes de traslado ligadas
-- a una OV por OWTQ.U_PedidoAnticipo = ORDR.DocEntry). Se guarda aparte de
-- ClienteNombre (que para TR es el destino y planificación lo usa como parada).
--   NULL  = aún no leído de SAP
--   ''    = TR sin OV (resurtido de tienda): sin cliente
-- Aplicar en Picking_Management ANTES de desplegar el código. NO escribe a SAP.
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.OrderPickingManagement') AND name = 'ClienteTR')
    ALTER TABLE dbo.OrderPickingManagement ADD ClienteTR NVARCHAR(150) NULL;
GO

CREATE OR ALTER PROCEDURE [dbo].[SP_FillClienteNombre]
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
        CREATE TABLE #tr (DocNum INT, Destino NVARCHAR(150) COLLATE DATABASE_DEFAULT, Cliente NVARCHAR(150) COLLATE DATABASE_DEFAULT);
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

        -- TR/RESURTIDO a los que les falta el destino o el cliente
        SELECT @lista = NULL;
        SELECT @lista = STUFF((
            SELECT DISTINCT ',' + CAST(TRY_CAST(OV_Number AS INT) AS VARCHAR(12))
            FROM dbo.OrderPickingManagement
            WHERE ID_RoutePlan = @ID_RoutePlan AND DocType IN ('TR', 'RESURTIDO') AND TRY_CAST(OV_Number AS INT) IS NOT NULL
              AND (ClienteNombre IS NULL OR ClienteTR IS NULL)
            FOR XML PATH('')), 1, 1, '');
        IF @lista IS NOT NULL
        BEGIN
            IF LEN(@lista) > 7000 RAISERROR('Demasiados documentos para una sola consulta', 16, 1);
            SET @sql = N'INSERT INTO #tr (DocNum, Destino, Cliente) SELECT * FROM OPENQUERY([server-sql], '''
                     + N'SELECT q.DocNum, LEFT(ISNULL(w.WhsName, q.ToWhsCode), 150) AS Destino, '
                     -- Cliente solo si el TR está ligado a una OV (U_PedidoAnticipo); los resurtidos
                     -- de tienda (CardName "CEDI Zona 5") quedan en cadena vacía = sin cliente.
                     + N'CASE WHEN q.U_PedidoAnticipo IS NULL THEN SPACE(0) ELSE LEFT(q.CardName, 150) END AS Cliente '
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

        -- Cliente final del TR (nombre del socio de la OV ligada). ClienteNombre sigue siendo
        -- el destino: planificación cuenta paradas por ese campo.
        UPDATE opm SET opm.ClienteTR = ISNULL(t.Cliente, '')
        FROM dbo.OrderPickingManagement opm
        JOIN #tr t ON t.DocNum = TRY_CAST(opm.OV_Number AS INT)
        WHERE opm.ID_RoutePlan = @ID_RoutePlan AND opm.DocType IN ('TR', 'RESURTIDO') AND opm.ClienteTR IS NULL;
    END TRY
    BEGIN CATCH
        PRINT 'SP_FillClienteNombre: lectura OPENQUERY fallida, se usa la directa: ' + ERROR_MESSAGE();
        EXEC dbo.SP_FillClienteNombre_Directo @ID_RoutePlan;
    END CATCH
END;
GO

-- Carga inicial en los cuadros activos con TR (los nuevos lo traen desde la ingesta).
DECLARE @id INT;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT DISTINCT orp.ID_RoutePlan FROM dbo.OrderRoutePlan orp
    JOIN dbo.OrderPickingManagement opm ON opm.ID_RoutePlan = orp.ID_RoutePlan AND opm.DocType IN ('TR', 'RESURTIDO')
    WHERE orp.Estado IN ('Pendiente', 'Iniciado')
       OR ISNULL(orp.EstadoDespacho, '') <> 'Finalizado'
       OR CAST(orp.FechaDespachoFin AS DATE) >= CAST(GETDATE() AS DATE);
OPEN c; FETCH NEXT FROM c INTO @id;
WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC dbo.SP_FillClienteNombre @id;
    FETCH NEXT FROM c INTO @id;
END
CLOSE c; DEALLOCATE c;
GO
PRINT 'ClienteTR: columna + SP_FillClienteNombre + carga inicial OK';
