-- ============================================================
-- Confirmación de entregas: comentario por OV independiente de la marca Sí/No.
--  * Estado pasa a NULL-able: una fila puede tener solo comentario (sin marcar).
--    El CHECK existente (Estado IN ('Si','No')) deja pasar NULL.
--  * ComentarioUsuario / ComentarioFecha: quién y cuándo escribió el comentario
--    (Usuario / Fecha siguen siendo de la marca Sí/No).
-- Aplicar ANTES de desplegar el código. Idempotente. NO escribe a SAP.
-- ============================================================
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dbo.ConfirmacionEntrega') AND name = 'Estado' AND is_nullable = 0)
    ALTER TABLE dbo.ConfirmacionEntrega ALTER COLUMN Estado NVARCHAR(10) NULL;
GO

IF COL_LENGTH('dbo.ConfirmacionEntrega', 'ComentarioUsuario') IS NULL
    ALTER TABLE dbo.ConfirmacionEntrega ADD ComentarioUsuario NVARCHAR(100) NULL;
GO

IF COL_LENGTH('dbo.ConfirmacionEntrega', 'ComentarioFecha') IS NULL
    ALTER TABLE dbo.ConfirmacionEntrega ADD ComentarioFecha DATETIME NULL;
GO

-- Comentarios ya guardados con la marca "No": se atribuyen a quien marcó.
UPDATE dbo.ConfirmacionEntrega
   SET ComentarioUsuario = Usuario, ComentarioFecha = Fecha
 WHERE Comentario IS NOT NULL AND ComentarioFecha IS NULL;
GO
