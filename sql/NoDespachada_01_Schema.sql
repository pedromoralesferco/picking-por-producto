-- ============================================================
-- NoDespachada — marca a nivel OV/pedido (OrderPickingManagement).
--
-- Cuando un documento (OV/TR) se QUITA de un cuadro en SAP porque no
-- cupo y se manda en otro cuadro, en vez de borrarlo del app lo
-- MARCAMOS como "No Despachada": no cuenta como pendiente, no bloquea
-- el cierre del cuadro, pero queda en el historial con badge.
--
-- La marca es 100% derivada de SAP (ver SP_SyncNoDespachadaEscuintla):
-- se pone sola cuando el doc sale del cuadro y SOLO se quita si el
-- cuadro vuelve a incluir el documento en SAP. No hay desmarcado manual.
--
-- Idempotente.
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.OrderPickingManagement') AND name = 'NoDespachada')
    ALTER TABLE dbo.OrderPickingManagement
        ADD NoDespachada BIT NOT NULL CONSTRAINT DF_OPM_NoDespachada DEFAULT 0;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.OrderPickingManagement') AND name = 'FechaNoDespachada')
    ALTER TABLE dbo.OrderPickingManagement
        ADD FechaNoDespachada DATETIME NULL;
GO

PRINT 'OrderPickingManagement.NoDespachada / FechaNoDespachada OK';
