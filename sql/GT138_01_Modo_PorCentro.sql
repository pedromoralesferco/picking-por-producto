-- ============================================================
-- Modalidad POR CENTRO (antes era por país)
-- Agrega CentroDistribucion.Modo = 'order' | 'product'
--   - order   = picking por pedido  (OrderPickingManagement)
--   - product = picking por producto (RoutePickingManagement)
-- Escuintla (GT, 138) pasa a 'order'; Zona 5 (GT, 01) queda 'product'.
-- El país sigue definiendo la BASE SAP (config/paises.js).
-- ============================================================
SET NOCOUNT ON;

IF COL_LENGTH('dbo.CentroDistribucion', 'Modo') IS NULL
    ALTER TABLE dbo.CentroDistribucion ADD Modo NVARCHAR(20) NULL;
GO

-- Valor por defecto según el país (compatibilidad con lo actual)
UPDATE dbo.CentroDistribucion
SET Modo = CASE WHEN Pais IN ('SV', 'HN') THEN 'order' ELSE 'product' END
WHERE Modo IS NULL;

-- Excepción: Escuintla (GT, bodega 138) corre en modo pedido
UPDATE dbo.CentroDistribucion
SET Modo = 'order'
WHERE Pais = 'GT' AND Codigo = '138';

SELECT ID_Centro, Nombre, Pais, Codigo, Modo FROM dbo.CentroDistribucion ORDER BY Pais, ID_Centro;
GO
