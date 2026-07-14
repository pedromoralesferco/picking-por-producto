-- ============================================================
-- Mini WMS Schema for DIMORA  (VERSION IDEMPOTENTE)
-- Database: Picking_Management
-- SAP Society: [server-SQL].SBODIMORA
-- Seguro de correr/re-correr: cada objeto se crea solo si no existe.
-- USO:  USE Picking_Management;  GO  (o seleccionar la BD en SSMS antes de ejecutar)
-- ============================================================

-- ── 1. Ubicaciones internas ──
IF OBJECT_ID('dbo.WMS_Ubicacion') IS NULL
CREATE TABLE WMS_Ubicacion (
    ID_Ubicacion    INT IDENTITY(1,1) PRIMARY KEY,
    Codigo          NVARCHAR(50)  NOT NULL UNIQUE,
    Descripcion     NVARCHAR(200) NULL,
    Zona            NVARCHAR(50)  NULL,
    Pasillo         NVARCHAR(20)  NULL,
    Rack            NVARCHAR(20)  NULL,
    Nivel           NVARCHAR(20)  NULL,
    Activo          BIT NOT NULL DEFAULT 1,
    FechaCreacion   DATETIME NOT NULL DEFAULT GETDATE()
);
GO

-- ── 2. License Plates (LPN) ──
IF OBJECT_ID('dbo.WMS_LicensePlate') IS NULL
CREATE TABLE WMS_LicensePlate (
    ID_LPN              INT IDENTITY(1,1) PRIMARY KEY,
    Codigo              NVARCHAR(50)  NOT NULL UNIQUE,
    ID_Ubicacion        INT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
    Estado              NVARCHAR(20)  NOT NULL DEFAULT 'Abierta',
    Tipo                NVARCHAR(20)  NULL,
    ID_Operador         INT NULL,
    FechaCreacion       DATETIME NOT NULL DEFAULT GETDATE(),
    FechaUltimoMov      DATETIME NULL
);
GO

-- ── 3. Stock por ubicacion + LPN ──
IF OBJECT_ID('dbo.WMS_Stock') IS NULL
BEGIN
    CREATE TABLE WMS_Stock (
        ID_Stock        INT IDENTITY(1,1) PRIMARY KEY,
        ItemCode        NVARCHAR(50)  NOT NULL,
        Descripcion     NVARCHAR(200) NULL,
        Cantidad        DECIMAL(18,4) NOT NULL DEFAULT 0,
        Lote            NVARCHAR(50)  NULL,
        ID_Ubicacion    INT NOT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
        ID_LPN          INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
        FechaActualizacion DATETIME NOT NULL DEFAULT GETDATE()
    );
    CREATE INDEX IX_WMS_Stock_Item ON WMS_Stock(ItemCode);
    CREATE INDEX IX_WMS_Stock_Ubicacion ON WMS_Stock(ID_Ubicacion);
    CREATE INDEX IX_WMS_Stock_LPN ON WMS_Stock(ID_LPN);
END
GO

-- ── 4. Historial de movimientos ──
IF OBJECT_ID('dbo.WMS_Movimiento') IS NULL
BEGIN
    CREATE TABLE WMS_Movimiento (
        ID_Movimiento       INT IDENTITY(1,1) PRIMARY KEY,
        Tipo                NVARCHAR(20) NOT NULL,
        TipoOperacion       NVARCHAR(20) NOT NULL,
        ID_LPN              INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
        ItemCode            NVARCHAR(50) NULL,
        Cantidad            DECIMAL(18,4) NULL,
        ID_UbicacionOrigen  INT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
        ID_UbicacionDestino INT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
        ID_LPN_Origen       INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
        ID_LPN_Destino      INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
        ID_Operador         INT NULL,
        Referencia          NVARCHAR(100) NULL,
        FechaMovimiento     DATETIME NOT NULL DEFAULT GETDATE()
    );
    CREATE INDEX IX_WMS_Mov_LPN ON WMS_Movimiento(ID_LPN);
    CREATE INDEX IX_WMS_Mov_Fecha ON WMS_Movimiento(FechaMovimiento);
END
GO

-- ── 5. Tareas de Picking ──
IF OBJECT_ID('dbo.WMS_TareaPicking') IS NULL
BEGIN
    CREATE TABLE WMS_TareaPicking (
        ID_Tarea        INT IDENTITY(1,1) PRIMARY KEY,
        DocEntry_SAP    INT NULL,
        DocNum_SAP      INT NULL,
        CardCode        NVARCHAR(50)  NULL,
        CardName        NVARCHAR(200) NULL,
        LineNum_SAP     INT NULL,
        ItemCode        NVARCHAR(50)  NOT NULL,
        Descripcion     NVARCHAR(200) NULL,
        Cantidad        DECIMAL(18,4) NOT NULL,
        CantidadPickeada DECIMAL(18,4) NOT NULL DEFAULT 0,
        WhsCode         NVARCHAR(20)  NULL,
        ID_UbicacionOrigen INT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
        ID_LPN          INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
        ID_Operador     INT NULL,
        Estado          NVARCHAR(20) NOT NULL DEFAULT 'Pendiente',
        Prioridad       INT NOT NULL DEFAULT 0,
        FechaCreacion   DATETIME NOT NULL DEFAULT GETDATE(),
        FechaAsignacion DATETIME NULL,
        FechaFin        DATETIME NULL
    );
    CREATE INDEX IX_WMS_TareaPick_Doc ON WMS_TareaPicking(DocNum_SAP);
    CREATE INDEX IX_WMS_TareaPick_Oper ON WMS_TareaPicking(ID_Operador);
    CREATE INDEX IX_WMS_TareaPick_Estado ON WMS_TareaPicking(Estado);
END
GO

-- ── 6. Tareas de Ingreso ──
IF OBJECT_ID('dbo.WMS_TareaIngreso') IS NULL
BEGIN
    CREATE TABLE WMS_TareaIngreso (
        ID_Tarea        INT IDENTITY(1,1) PRIMARY KEY,
        DocEntry_SAP    INT NULL,
        DocNum_SAP      INT NULL,
        CardCode        NVARCHAR(50)  NULL,
        CardName        NVARCHAR(200) NULL,
        LineNum_SAP     INT NULL,
        ItemCode        NVARCHAR(50)  NOT NULL,
        Descripcion     NVARCHAR(200) NULL,
        CantidadEsperada DECIMAL(18,4) NOT NULL,
        CantidadRecibida DECIMAL(18,4) NOT NULL DEFAULT 0,
        WhsCode         NVARCHAR(20)  NULL,
        ID_UbicacionDestino INT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
        ID_LPN          INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
        ID_Operador     INT NULL,
        Estado          NVARCHAR(20) NOT NULL DEFAULT 'Pendiente',
        FechaCreacion   DATETIME NOT NULL DEFAULT GETDATE(),
        FechaAsignacion DATETIME NULL,
        FechaFin        DATETIME NULL
    );
    CREATE INDEX IX_WMS_TareaIng_Doc ON WMS_TareaIngreso(DocNum_SAP);
    CREATE INDEX IX_WMS_TareaIng_Estado ON WMS_TareaIngreso(Estado);
END
GO

-- ── 7. Tareas de Traslado ──
IF OBJECT_ID('dbo.WMS_TareaTraslado') IS NULL
CREATE TABLE WMS_TareaTraslado (
    ID_Tarea        INT IDENTITY(1,1) PRIMARY KEY,
    Tipo            NVARCHAR(20) NOT NULL,
    ID_LPN          INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
    ItemCode        NVARCHAR(50) NULL,
    Cantidad        DECIMAL(18,4) NULL,
    ID_UbicacionOrigen  INT NOT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
    ID_UbicacionDestino INT NOT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
    ID_LPN_Origen   INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
    ID_LPN_Destino  INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
    ID_Operador     INT NULL,
    Estado          NVARCHAR(20) NOT NULL DEFAULT 'Pendiente',
    FechaCreacion   DATETIME NOT NULL DEFAULT GETDATE(),
    FechaFin        DATETIME NULL
);
GO

-- ── 8. Integracion con UiPath ──
IF OBJECT_ID('dbo.WMS_Integracion') IS NULL
BEGIN
    CREATE TABLE WMS_Integracion (
        ID_Integracion  INT IDENTITY(1,1) PRIMARY KEY,
        TipoDocumento   NVARCHAR(30) NOT NULL,
        DocNum_SAP_Origen INT NULL,
        DocEntry_SAP_Origen INT NULL,
        CardCode        NVARCHAR(50) NULL,
        CardName        NVARCHAR(200) NULL,
        WhsCode         NVARCHAR(20) NULL,
        Comentarios     NVARCHAR(500) NULL,
        Estado          NVARCHAR(20) NOT NULL DEFAULT 'Pendiente',
        DocNum_SAP_Creado INT NULL,
        MensajeError    NVARCHAR(1000) NULL,
        IntentosUiPath  INT NOT NULL DEFAULT 0,
        ID_Usuario      INT NULL,
        FechaCreacion   DATETIME NOT NULL DEFAULT GETDATE(),
        FechaProcesado  DATETIME NULL
    );
    CREATE INDEX IX_WMS_Int_Estado ON WMS_Integracion(Estado);
    CREATE INDEX IX_WMS_Int_Tipo ON WMS_Integracion(TipoDocumento);
END
GO

IF OBJECT_ID('dbo.WMS_IntegracionDetalle') IS NULL
BEGIN
    CREATE TABLE WMS_IntegracionDetalle (
        ID_Detalle      INT IDENTITY(1,1) PRIMARY KEY,
        ID_Integracion  INT NOT NULL REFERENCES WMS_Integracion(ID_Integracion),
        LineNum_SAP     INT NULL,
        ItemCode        NVARCHAR(50)  NOT NULL,
        Descripcion     NVARCHAR(200) NULL,
        Cantidad        DECIMAL(18,4) NOT NULL,
        WhsCode         NVARCHAR(20)  NULL,
        WhsCodeDestino  NVARCHAR(20)  NULL,
        Lote            NVARCHAR(50)  NULL,
        ID_LPN          INT NULL,
        PrecioUnitario  DECIMAL(18,4) NULL
    );
    CREATE INDEX IX_WMS_IntDet_Parent ON WMS_IntegracionDetalle(ID_Integracion);
END
GO

-- ── 9. Secuencia para codigos LPN ──
IF OBJECT_ID('dbo.WMS_Secuencia') IS NULL
CREATE TABLE WMS_Secuencia (
    Nombre          NVARCHAR(50) PRIMARY KEY,
    ValorActual     INT NOT NULL DEFAULT 0
);
GO
IF NOT EXISTS (SELECT 1 FROM WMS_Secuencia WHERE Nombre = 'LPN')
    INSERT INTO WMS_Secuencia (Nombre, ValorActual) VALUES ('LPN', 0);
GO

-- ── 10. Ubicaciones iniciales ──
IF NOT EXISTS (SELECT 1 FROM WMS_Ubicacion WHERE Codigo = 'RECEPCION')
    INSERT INTO WMS_Ubicacion (Codigo, Descripcion, Zona) VALUES ('RECEPCION', 'Muelle de recepcion', 'RECEPCION');
IF NOT EXISTS (SELECT 1 FROM WMS_Ubicacion WHERE Codigo = 'STAGING')
    INSERT INTO WMS_Ubicacion (Codigo, Descripcion, Zona) VALUES ('STAGING', 'Zona de preparacion/carga', 'DESPACHO');
IF NOT EXISTS (SELECT 1 FROM WMS_Ubicacion WHERE Codigo = 'DESPACHO')
    INSERT INTO WMS_Ubicacion (Codigo, Descripcion, Zona) VALUES ('DESPACHO', 'Muelle de despacho', 'DESPACHO');
GO
