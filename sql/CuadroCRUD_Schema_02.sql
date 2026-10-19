-- ============================================================
-- CRUD de cuadros — Fase 1 (esquema 02): agregar / quitar línea.
-- Aditivo e idempotente. NO toca SAP. Complementa CuadroCRUD_Schema.sql.
-- ============================================================

-- OPM: documento QUITADO del cuadro en el app cuya baja aún no se refleja en
-- SAP. Lo usan los reconciliadores para NO revivirlo (SP_SyncNoDespachada) ni
-- borrarlo por error. Se limpia (=0) cuando SAP confirma la baja (Fase 3).
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.OrderPickingManagement') AND name='RemocionPendienteSync')
    ALTER TABLE dbo.OrderPickingManagement ADD RemocionPendienteSync BIT NOT NULL CONSTRAINT DF_OPM_RemocionPend DEFAULT 0;
GO

-- OrderRoutePlan: cuadro COMPLEMENTO creado en el app (nace con los documentos
-- quitados de otro cuadro). Mientras SAP no lo cree, su RouteNumber es
-- provisional (negativo) y CreacionPendienteSync=1. Fase 3 lo crea en SAP y
-- reemplaza el RouteNumber provisional por el DocNum real.
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.OrderRoutePlan') AND name='EsComplemento')
    ALTER TABLE dbo.OrderRoutePlan ADD EsComplemento BIT NOT NULL CONSTRAINT DF_ORP_EsComplemento DEFAULT 0;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.OrderRoutePlan') AND name='ComplementoDe')
    ALTER TABLE dbo.OrderRoutePlan ADD ComplementoDe INT NULL;   -- RouteNumber de origen
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.OrderRoutePlan') AND name='CreacionPendienteSync')
    ALTER TABLE dbo.OrderRoutePlan ADD CreacionPendienteSync BIT NOT NULL CONSTRAINT DF_ORP_CreacionPend DEFAULT 0;
GO

PRINT 'CRUD cuadros: esquema 02 (agregar/quitar línea) OK';
