-- ============================================================
-- Confirmación de entregas con el cliente (Plan de Despachos, modo pedido).
-- Una fila por OV dentro de un cuadro: el cliente SÍ recibe (verde) o NO puede
-- (rojo + fecha en que sí puede recibir). Sin fila = sin confirmar.
-- Si la OV pasa a otro cuadro, arranca sin confirmar (la llave incluye el cuadro).
--
-- Orden de aplicación en Picking_Management:
--   1) sql/ClienteNombre_01_Schema.sql  (columna Telefono + SP_FillClienteNombre)
--   2) este archivo                      (tabla + carga inicial del teléfono)
-- Idempotente. NO escribe a SAP.
-- ============================================================
IF OBJECT_ID('dbo.ConfirmacionEntrega') IS NULL
BEGIN
    CREATE TABLE dbo.ConfirmacionEntrega (
        ID_Confirmacion   INT IDENTITY(1,1) PRIMARY KEY,
        ID_RoutePlan      INT            NOT NULL,
        OV_Number         NVARCHAR(50)   NOT NULL,
        Estado            NVARCHAR(10)   NOT NULL CONSTRAINT CK_ConfEntrega_Estado CHECK (Estado IN ('Si', 'No')),
        FechaRecepcion    DATE           NULL,      -- solo Estado = 'No'
        Comentario        NVARCHAR(500)  NULL,
        Usuario           NVARCHAR(100)  NULL,
        Fecha             DATETIME       NOT NULL DEFAULT GETDATE(),
        CONSTRAINT UQ_ConfEntrega UNIQUE (ID_RoutePlan, OV_Number)
    );
END
GO

-- Carga inicial del teléfono en los cuadros activos (los nuevos lo traen desde la
-- ingesta). Reusa el SP: solo llena lo que está en NULL.
IF OBJECT_ID('dbo.SP_FillClienteNombre') IS NOT NULL
   AND EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.OrderPickingManagement') AND name = 'Telefono')
BEGIN
    DECLARE @id INT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT ID_RoutePlan FROM dbo.OrderRoutePlan
        WHERE Estado IN ('Pendiente', 'Iniciado')
           OR ISNULL(EstadoDespacho, '') <> 'Finalizado'
           OR CAST(FechaDespachoFin AS DATE) >= CAST(GETDATE() AS DATE);
    OPEN c; FETCH NEXT FROM c INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC dbo.SP_FillClienteNombre @id;
        FETCH NEXT FROM c INTO @id;
    END
    CLOSE c; DEALLOCATE c;
END
GO
PRINT 'ConfirmacionEntrega: tabla + carga inicial de teléfonos OK';
