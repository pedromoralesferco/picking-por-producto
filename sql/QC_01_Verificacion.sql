-- ============================================================
-- Verificación de calidad (QC) en despacho + packing list
-- Agrega estado de "verificado" por línea a las tablas de tareas
-- (modo pedido y modo producto), con auditoría (usuario + fecha).
-- ============================================================
SET NOCOUNT ON;

-- ── Modo pedido ──
IF COL_LENGTH('dbo.OrderPickingTask', 'Verificado') IS NULL
    ALTER TABLE dbo.OrderPickingTask ADD
        Verificado        BIT NOT NULL DEFAULT 0,
        FechaVerificacion DATETIME     NULL,
        VerificadoPor     NVARCHAR(100) NULL;
GO

-- ── Modo producto ──
IF COL_LENGTH('dbo.RoutePickingTask', 'Verificado') IS NULL
    ALTER TABLE dbo.RoutePickingTask ADD
        Verificado        BIT NOT NULL DEFAULT 0,
        FechaVerificacion DATETIME     NULL,
        VerificadoPor     NVARCHAR(100) NULL;
GO

PRINT 'Columnas de verificación QC agregadas.';
