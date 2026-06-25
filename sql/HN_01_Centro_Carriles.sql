-- ============================================================
-- Honduras (HN) — Paso 1: Centro de distribución + Carriles
-- Empresa SAP: sbopym (PISOS Y MARMOLES SA DE CV)
-- CEDI: 01 -> ".001 CEDI Tegus" (Tegucigalpa)
-- Modalidad: order (picking por pedido), igual que El Salvador
-- ============================================================
SET NOCOUNT ON;

BEGIN TRANSACTION;

-- ── 1. Centro de distribución ──
IF NOT EXISTS (SELECT 1 FROM dbo.CentroDistribucion WHERE Pais = 'HN' AND Codigo = '01')
BEGIN
    INSERT INTO dbo.CentroDistribucion (Nombre, Pais, Codigo)
    VALUES ('.001 CEDI Tegus', 'HN', '01');
END

DECLARE @ID_Centro_HN INT =
    (SELECT ID_Centro FROM dbo.CentroDistribucion WHERE Pais = 'HN' AND Codigo = '01');

PRINT 'Centro HN ID_Centro = ' + CONVERT(VARCHAR, @ID_Centro_HN);

-- ── 2. Carriles (ajustar cantidad según los andenes reales del CEDI Tegus) ──
DECLARE @i INT = 1;
WHILE @i <= 12
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM dbo.Carril
        WHERE ID_Centro = @ID_Centro_HN
          AND Nombre = 'Carril #' + CONVERT(VARCHAR, @i)
    )
    BEGIN
        INSERT INTO dbo.Carril (Nombre, ID_Centro, Activo)
        VALUES ('Carril #' + CONVERT(VARCHAR, @i), @ID_Centro_HN, 1);
    END
    SET @i += 1;
END

PRINT 'Carriles HN creados.';

COMMIT TRANSACTION;

-- ── 3. (Manual) Asignar usuarios al centro HN ──
-- Ejemplo:
--   INSERT INTO dbo.UsuarioCentro (ID_Usuario, ID_Centro)
--   VALUES (<ID_Usuario>, @ID_Centro_HN);
--   INSERT INTO dbo.UsuarioPermiso (ID_Usuario, Modulo)
--   VALUES (<ID_Usuario>, 'priorizacion'), (<ID_Usuario>, 'gestion'),
--          (<ID_Usuario>, 'despacho'), (<ID_Usuario>, 'pase-salida');
