-- ============================================================
-- CRUD de cuadros de ruta (pivoteo en carril) — Fase 1 (esquema)
-- Todo app-first; la sincronización a SAP (Service Layer) lee el outbox.
-- Aditivo e idempotente. NO toca SAP.
-- ============================================================

-- Outbox: cada edición de cuadro hecha en el app queda registrada para (a)
-- sincronizar a SAP por Service Layer y (b) desambiguar la fuente de verdad
-- ("en SAP sí, en app no" = ¿hay remoción pendiente del app?).
IF OBJECT_ID('dbo.CuadroEdicionCola') IS NULL
BEGIN
    CREATE TABLE dbo.CuadroEdicionCola (
        ID_Edicion      INT IDENTITY(1,1) PRIMARY KEY,
        RouteNumber     INT           NOT NULL,          -- cuadro afectado
        Ambito          NVARCHAR(10)  NOT NULL,          -- 'LINEA' | 'HEADER'
        Accion          NVARCHAR(10)  NOT NULL,          -- 'ADD' | 'REMOVE' | 'PLACA'
        OV_Number       NVARCHAR(50)  NULL,              -- doc afectado (si Ambito='LINEA')
        DocType         NVARCHAR(10)  NULL,              -- OV | TR | RMA
        Payload         NVARCHAR(MAX) NULL,              -- JSON (placa/capacidad/id_camion, etc.)
        Estado          NVARCHAR(12)  NOT NULL DEFAULT 'pendiente', -- pendiente|enviado|confirmado|error
        Intentos        INT           NOT NULL DEFAULT 0,
        Error           NVARCHAR(1000) NULL,
        Usuario         NVARCHAR(100) NULL,
        FechaCreacion   DATETIME      NOT NULL DEFAULT GETDATE(),
        FechaSync       DATETIME      NULL
    );
    CREATE INDEX IX_CuadroEdicionCola_Route ON dbo.CuadroEdicionCola (RouteNumber);
    CREATE INDEX IX_CuadroEdicionCola_Pend ON dbo.CuadroEdicionCola (Estado) WHERE Estado IN ('pendiente','error');
END
GO

-- Flag en el pedido: línea agregada en el app aún no reflejada en SAP. Los
-- reconciliadores (reimport / No Despachada) deben respetarla (no borrarla).
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.OrderPickingManagement') AND name='PendienteSync')
    ALTER TABLE dbo.OrderPickingManagement ADD PendienteSync BIT NOT NULL CONSTRAINT DF_OPM_PendienteSync DEFAULT 0;
GO

-- Placa/camión asignado desde el app (app-first; se sincroniza al header del
-- cuadro en SAP vía Service Layer). El Plan de Despachos muestra esto hasta que
-- SAP confirme. PlacaPendienteSync: aún no reflejado en SAP.
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.OrderRoutePlan') AND name='PlacaApp')
    ALTER TABLE dbo.OrderRoutePlan ADD PlacaApp NVARCHAR(20) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.OrderRoutePlan') AND name='CapacidadApp')
    ALTER TABLE dbo.OrderRoutePlan ADD CapacidadApp DECIMAL(10,2) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.OrderRoutePlan') AND name='IDCamionApp')
    ALTER TABLE dbo.OrderRoutePlan ADD IDCamionApp NVARCHAR(30) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.OrderRoutePlan') AND name='TransportistaApp')
    ALTER TABLE dbo.OrderRoutePlan ADD TransportistaApp NVARCHAR(100) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id=OBJECT_ID('dbo.OrderRoutePlan') AND name='PlacaPendienteSync')
    ALTER TABLE dbo.OrderRoutePlan ADD PlacaPendienteSync BIT NOT NULL CONSTRAINT DF_ORP_PlacaPendiente DEFAULT 0;
GO
PRINT 'CRUD cuadros: esquema Fase 1 OK';
