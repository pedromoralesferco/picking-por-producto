-- ============================================================
-- Mini WMS Schema for DIMORA
-- Database: Picking_Management
-- SAP Society: [server-SQL].SBODIMORA
-- ============================================================

-- ── 1. Ubicaciones internas ──

CREATE TABLE WMS_Ubicacion (
    ID_Ubicacion    INT IDENTITY(1,1) PRIMARY KEY,
    Codigo          NVARCHAR(50)  NOT NULL UNIQUE,   -- ej: A-01-01, RECEPCION, STAGING
    Descripcion     NVARCHAR(200) NULL,
    Zona            NVARCHAR(50)  NULL,              -- ej: ALMACEN, RECEPCION, DESPACHO, STAGING
    Pasillo         NVARCHAR(20)  NULL,
    Rack            NVARCHAR(20)  NULL,
    Nivel           NVARCHAR(20)  NULL,
    Activo          BIT NOT NULL DEFAULT 1,
    FechaCreacion   DATETIME NOT NULL DEFAULT GETDATE()
);

-- ── 2. License Plates (LPN) ──

CREATE TABLE WMS_LicensePlate (
    ID_LPN              INT IDENTITY(1,1) PRIMARY KEY,
    Codigo              NVARCHAR(50)  NOT NULL UNIQUE,   -- ej: LPN-00452
    ID_Ubicacion        INT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
    Estado              NVARCHAR(20)  NOT NULL DEFAULT 'Abierta',
                        -- Abierta, Cerrada, EnTransito, Despachada
    Tipo                NVARCHAR(20)  NULL,              -- Picking, Recepcion, Almacenamiento
    ID_Operador         INT NULL,                        -- FK a Usuario (operador asignado)
    FechaCreacion       DATETIME NOT NULL DEFAULT GETDATE(),
    FechaUltimoMov      DATETIME NULL
);

-- ── 3. Stock por ubicacion + LPN ──
--    ID_LPN NULL = producto suelto en la ubicacion

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

-- ── 4. Historial de movimientos (LPN o producto) ──

CREATE TABLE WMS_Movimiento (
    ID_Movimiento       INT IDENTITY(1,1) PRIMARY KEY,
    Tipo                NVARCHAR(20) NOT NULL,  -- LPN, Producto
    TipoOperacion       NVARCHAR(20) NOT NULL,  -- Picking, PutAway, Traslado, Despacho, Ingreso
    ID_LPN              INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
    ItemCode            NVARCHAR(50) NULL,
    Cantidad            DECIMAL(18,4) NULL,
    ID_UbicacionOrigen  INT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
    ID_UbicacionDestino INT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
    ID_LPN_Origen       INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
    ID_LPN_Destino      INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
    ID_Operador         INT NULL,
    Referencia          NVARCHAR(100) NULL,     -- DocNum OV, PO, etc.
    FechaMovimiento     DATETIME NOT NULL DEFAULT GETDATE()
);

CREATE INDEX IX_WMS_Mov_LPN ON WMS_Movimiento(ID_LPN);
CREATE INDEX IX_WMS_Mov_Fecha ON WMS_Movimiento(FechaMovimiento);

-- ── 5. Tareas de Picking (desde OV / ORDR en SAP) ──

CREATE TABLE WMS_TareaPicking (
    ID_Tarea        INT IDENTITY(1,1) PRIMARY KEY,
    DocEntry_SAP    INT NULL,                       -- ORDR.DocEntry en SBODIMORA
    DocNum_SAP      INT NULL,                       -- ORDR.DocNum (numero visible OV)
    CardCode        NVARCHAR(50)  NULL,
    CardName        NVARCHAR(200) NULL,
    LineNum_SAP     INT NULL,                       -- RDR1.LineNum
    ItemCode        NVARCHAR(50)  NOT NULL,
    Descripcion     NVARCHAR(200) NULL,
    Cantidad        DECIMAL(18,4) NOT NULL,
    CantidadPickeada DECIMAL(18,4) NOT NULL DEFAULT 0,
    WhsCode         NVARCHAR(20)  NULL,             -- Almacen SAP origen
    ID_UbicacionOrigen INT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
    ID_LPN          INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
    ID_Operador     INT NULL,                       -- Usuario asignado
    Estado          NVARCHAR(20) NOT NULL DEFAULT 'Pendiente',
                    -- Pendiente, Asignada, EnProceso, Completada
    Prioridad       INT NOT NULL DEFAULT 0,
    FechaCreacion   DATETIME NOT NULL DEFAULT GETDATE(),
    FechaAsignacion DATETIME NULL,
    FechaFin        DATETIME NULL
);

CREATE INDEX IX_WMS_TareaPick_Doc ON WMS_TareaPicking(DocNum_SAP);
CREATE INDEX IX_WMS_TareaPick_Oper ON WMS_TareaPicking(ID_Operador);
CREATE INDEX IX_WMS_TareaPick_Estado ON WMS_TareaPicking(Estado);

-- ── 6. Tareas de Ingreso (desde PO / OPOR en SAP) ──

CREATE TABLE WMS_TareaIngreso (
    ID_Tarea        INT IDENTITY(1,1) PRIMARY KEY,
    DocEntry_SAP    INT NULL,                       -- OPOR.DocEntry en SBODIMORA
    DocNum_SAP      INT NULL,                       -- OPOR.DocNum (numero visible PO)
    CardCode        NVARCHAR(50)  NULL,
    CardName        NVARCHAR(200) NULL,
    LineNum_SAP     INT NULL,                       -- POR1.LineNum
    ItemCode        NVARCHAR(50)  NOT NULL,
    Descripcion     NVARCHAR(200) NULL,
    CantidadEsperada DECIMAL(18,4) NOT NULL,
    CantidadRecibida DECIMAL(18,4) NOT NULL DEFAULT 0,
    WhsCode         NVARCHAR(20)  NULL,
    ID_UbicacionDestino INT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
    ID_LPN          INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
    ID_Operador     INT NULL,
    Estado          NVARCHAR(20) NOT NULL DEFAULT 'Pendiente',
                    -- Pendiente, Asignada, EnProceso, Completada
    FechaCreacion   DATETIME NOT NULL DEFAULT GETDATE(),
    FechaAsignacion DATETIME NULL,
    FechaFin        DATETIME NULL
);

CREATE INDEX IX_WMS_TareaIng_Doc ON WMS_TareaIngreso(DocNum_SAP);
CREATE INDEX IX_WMS_TareaIng_Estado ON WMS_TareaIngreso(Estado);

-- ── 7. Tareas de Traslado ──

CREATE TABLE WMS_TareaTraslado (
    ID_Tarea        INT IDENTITY(1,1) PRIMARY KEY,
    Tipo            NVARCHAR(20) NOT NULL,          -- LPN, Producto
    ID_LPN          INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
    ItemCode        NVARCHAR(50) NULL,
    Cantidad        DECIMAL(18,4) NULL,
    ID_UbicacionOrigen  INT NOT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
    ID_UbicacionDestino INT NOT NULL REFERENCES WMS_Ubicacion(ID_Ubicacion),
    ID_LPN_Origen   INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
    ID_LPN_Destino  INT NULL REFERENCES WMS_LicensePlate(ID_LPN),
    ID_Operador     INT NULL,
    Estado          NVARCHAR(20) NOT NULL DEFAULT 'Pendiente',
                    -- Pendiente, Asignada, EnTransito, Completada
    FechaCreacion   DATETIME NOT NULL DEFAULT GETDATE(),
    FechaFin        DATETIME NULL
);

-- ══════════════════════════════════════════════════
-- ── 8. Tablas de Staging / Integracion con UiPath ──
-- ══════════════════════════════════════════════════

-- Tabla principal de integracion: cada registro = 1 documento a crear en SAP via DI API
CREATE TABLE WMS_Integracion (
    ID_Integracion  INT IDENTITY(1,1) PRIMARY KEY,
    TipoDocumento   NVARCHAR(30) NOT NULL,
                    -- ENTREGA (Delivery from OV)
                    -- FACTURA (Invoice from OV)
                    -- ENTRADA_MERCANCIA (Goods Receipt PO)
                    -- TRASLADO_STOCK (Stock Transfer)
    DocNum_SAP_Origen INT NULL,                     -- DocNum de la OV/PO origen
    DocEntry_SAP_Origen INT NULL,                   -- DocEntry de la OV/PO origen
    CardCode        NVARCHAR(50) NULL,
    CardName        NVARCHAR(200) NULL,
    WhsCode         NVARCHAR(20) NULL,
    Comentarios     NVARCHAR(500) NULL,
    Estado          NVARCHAR(20) NOT NULL DEFAULT 'Pendiente',
                    -- Pendiente      → listo para UiPath
                    -- EnProceso      → UiPath lo tomo
                    -- Completado     → Documento creado exitosamente
                    -- Error          → Fallo al crear, ver MensajeError
    DocNum_SAP_Creado INT NULL,                     -- DocNum del documento creado por DI API
    MensajeError    NVARCHAR(1000) NULL,
    IntentosUiPath  INT NOT NULL DEFAULT 0,
    ID_Usuario      INT NULL,                       -- Quien confirmo en la app
    FechaCreacion   DATETIME NOT NULL DEFAULT GETDATE(),
    FechaProcesado  DATETIME NULL
);

CREATE INDEX IX_WMS_Int_Estado ON WMS_Integracion(Estado);
CREATE INDEX IX_WMS_Int_Tipo ON WMS_Integracion(TipoDocumento);

-- Detalle de lineas para cada documento de integracion
CREATE TABLE WMS_IntegracionDetalle (
    ID_Detalle      INT IDENTITY(1,1) PRIMARY KEY,
    ID_Integracion  INT NOT NULL REFERENCES WMS_Integracion(ID_Integracion),
    LineNum_SAP     INT NULL,                       -- LineNum de la OV/PO origen
    ItemCode        NVARCHAR(50)  NOT NULL,
    Descripcion     NVARCHAR(200) NULL,
    Cantidad        DECIMAL(18,4) NOT NULL,
    WhsCode         NVARCHAR(20)  NULL,
    WhsCodeDestino  NVARCHAR(20)  NULL,             -- Solo para traslados
    Lote            NVARCHAR(50)  NULL,
    ID_LPN          INT NULL,                       -- LPN donde se pickeo/recibio
    PrecioUnitario  DECIMAL(18,4) NULL
);

CREATE INDEX IX_WMS_IntDet_Parent ON WMS_IntegracionDetalle(ID_Integracion);

-- ── 9. Secuencia para codigos LPN ──

CREATE TABLE WMS_Secuencia (
    Nombre          NVARCHAR(50) PRIMARY KEY,
    ValorActual     INT NOT NULL DEFAULT 0
);

INSERT INTO WMS_Secuencia (Nombre, ValorActual) VALUES ('LPN', 0);

-- ══════════════════════════════════════════════════
-- ── 10. Datos iniciales ──
-- ══════════════════════════════════════════════════

-- Centro de distribucion DIMORA (ajustar ID si es necesario)
-- INSERT INTO CentroDistribucion (Nombre, Pais, Codigo) VALUES ('DIMORA', 'GT', 'DIMORA');

-- Ubicaciones iniciales de ejemplo
INSERT INTO WMS_Ubicacion (Codigo, Descripcion, Zona) VALUES ('RECEPCION', 'Muelle de recepcion', 'RECEPCION');
INSERT INTO WMS_Ubicacion (Codigo, Descripcion, Zona) VALUES ('STAGING', 'Zona de preparacion/carga', 'DESPACHO');
INSERT INTO WMS_Ubicacion (Codigo, Descripcion, Zona) VALUES ('DESPACHO', 'Muelle de despacho', 'DESPACHO');
