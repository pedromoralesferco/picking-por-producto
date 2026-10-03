-- Flag "Comprometida" por cuadro (entrega comprometida a destacar en Plan de Despachos).
-- Editable solo por quien tiene permiso de priorización. Idempotente.
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.OrderRoutePlan') AND name = 'Comprometida')
    ALTER TABLE dbo.OrderRoutePlan
        ADD Comprometida BIT NOT NULL CONSTRAINT DF_ORP_Comprometida DEFAULT 0;
GO
PRINT 'OrderRoutePlan.Comprometida OK';
