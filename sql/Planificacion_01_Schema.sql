-- Fase 1 del conector "Ferco Planificación" (MCP): esquema base. Idempotente y aditivo.
--  * Usuario.Email: une el correo del login de Microsoft (pase de Supabase Auth) con el usuario del app.
--  * MCP_Auditoria: cada llamada a /api/planificacion (lectura y escritura).
--  * ConfigPlanDiario / ConfigCamion: metas y reglas por centro que usan validar_plan y orden-dia.
-- El acceso al conector es el módulo 'planificacion' en UsuarioPermiso (casilla en Admin → Usuarios).

-- ── Usuario.Email ───────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Usuario') AND name = 'Email')
    ALTER TABLE dbo.Usuario ADD Email NVARCHAR(200) NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE object_id = OBJECT_ID('dbo.Usuario') AND name = 'UX_Usuario_Email')
    CREATE UNIQUE INDEX UX_Usuario_Email ON dbo.Usuario (Email) WHERE Email IS NOT NULL;
GO
PRINT 'Usuario.Email OK';

-- ── Auditoría ───────────────────────────────────────────────────────────────
IF OBJECT_ID('dbo.MCP_Auditoria') IS NULL
BEGIN
    CREATE TABLE dbo.MCP_Auditoria (
        ID_Auditoria   BIGINT IDENTITY(1,1) PRIMARY KEY,
        Fecha          DATETIME       NOT NULL CONSTRAINT DF_MCPAud_Fecha DEFAULT GETDATE(),
        ID_Usuario     INT            NULL,
        Email          NVARCHAR(200)  NULL,
        Metodo         VARCHAR(10)    NOT NULL,
        Ruta           NVARCHAR(200)  NOT NULL,
        Parametros     NVARCHAR(MAX)  NULL,
        ID_Centro      INT            NULL,
        EstadoHttp     INT            NOT NULL,
        DuracionMs     INT            NULL,
        Error          NVARCHAR(1000) NULL,
        ClaveOperacion NVARCHAR(100)  NULL   -- escrituras (fase 2): idempotencia
    );
    CREATE INDEX IX_MCPAud_Fecha ON dbo.MCP_Auditoria (Fecha DESC);
    CREATE INDEX IX_MCPAud_Usuario ON dbo.MCP_Auditoria (ID_Usuario, Fecha DESC);
END
GO
PRINT 'MCP_Auditoria OK';

-- ── Configuración del plan diario (por centro) ──────────────────────────────
IF OBJECT_ID('dbo.ConfigPlanDiario') IS NULL
    CREATE TABLE dbo.ConfigPlanDiario (
        ID_Centro              INT           NOT NULL PRIMARY KEY,
        CorteToneladasDia      DECIMAL(9,1)  NOT NULL,  -- toneladas que caben en un día de picking
        ToneladasHora          DECIMAL(9,1)  NOT NULL,  -- ritmo para estimar la hora de cada cambio de grupo
        HoraInicio             TIME          NOT NULL,
        PresupuestoTiendasTon  DECIMAL(9,1)  NULL,      -- referencia para el bloque de tiendas/plataformas
        RutasPequenasDia       INT           NULL,      -- referencia (~20)
        VentanaCandadoHoras    INT           NOT NULL,  -- fase 3: protege cambios de otro planificador
        OrdenGrupos            NVARCHAR(100) NOT NULL,  -- orden del día, p. ej. 'tiendas,expos,ultima_milla'
        ModificadoPor          NVARCHAR(100) NULL,
        ModificadoEn           DATETIME      NOT NULL CONSTRAINT DF_CPD_Mod DEFAULT GETDATE()
    );
GO
IF OBJECT_ID('dbo.ConfigCamion') IS NULL
    CREATE TABLE dbo.ConfigCamion (
        ID_Centro          INT          NOT NULL,
        Tipo               VARCHAR(10)  NOT NULL,   -- '3.5T', '5T', '10T', '12T', '15T', '22T'
        CapacidadKg        INT          NOT NULL,   -- carga útil de planificación (no la nominal)
        MaxParadas         INT          NOT NULL,
        SoloClienteUnico   BIT          NOT NULL CONSTRAINT DF_CC_Unico DEFAULT 0,  -- 22T: un cliente o una plataforma
        CONSTRAINT PK_ConfigCamion PRIMARY KEY (ID_Centro, Tipo)
    );
GO
-- Valores con los que se planifica hoy el HUB Escuintla (centro 3). Revisarlos antes del piloto.
IF NOT EXISTS (SELECT 1 FROM dbo.ConfigPlanDiario WHERE ID_Centro = 3)
    INSERT INTO dbo.ConfigPlanDiario (ID_Centro, CorteToneladasDia, ToneladasHora, HoraInicio,
        PresupuestoTiendasTon, RutasPequenasDia, VentanaCandadoHoras, OrdenGrupos, ModificadoPor)
    VALUES (3, 360, 18, '06:00', 160, 20, 12, 'tiendas,expos,ultima_milla', 'seed fase 1');
GO
IF NOT EXISTS (SELECT 1 FROM dbo.ConfigCamion WHERE ID_Centro = 3)
    INSERT INTO dbo.ConfigCamion (ID_Centro, Tipo, CapacidadKg, MaxParadas, SoloClienteUnico) VALUES
        (3, '3.5T', 3300, 5, 0),
        (3, '5T',   4800, 5, 0),
        (3, '10T',  9500, 3, 0),
        (3, '12T', 11500, 3, 0),
        (3, '15T', 14000, 3, 0),
        (3, '22T', 21000, 1, 1);
GO
PRINT 'ConfigPlanDiario / ConfigCamion OK';
