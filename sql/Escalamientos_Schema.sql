-- ============================================================
-- Módulo de Escalamientos (tickets de OV/TR a escalar en picking/despacho)
-- HUB Escuintla. Estado (Pendiente/Programado/Finalizado) se deriva en vivo
-- cruzando la OV contra los cuadros; NO se guarda aquí.
-- Idempotente.
-- ============================================================
IF OBJECT_ID('dbo.Escalamientos') IS NULL
BEGIN
    CREATE TABLE dbo.Escalamientos (
        ID_Escalamiento   INT IDENTITY(1,1) PRIMARY KEY,
        OV_Number         NVARCHAR(50)  NOT NULL,
        DocType           NVARCHAR(10)  NOT NULL DEFAULT 'OV',   -- 'OV' | 'TR'
        FechaRequerida    DATE          NULL,
        -- Snapshot al crear (buscado del pedido)
        ClienteNombre     NVARCHAR(200) NULL,
        Monto             DECIMAL(18,2) NULL,                    -- solo OV
        PesoKg            DECIMAL(18,2) NULL,
        TotalLineas       INT           NULL,
        -- Auditoría
        CreadoPor         NVARCHAR(100) NULL,
        FechaCreacion     DATETIME      NOT NULL DEFAULT GETDATE(),
        Archivado         BIT           NOT NULL DEFAULT 0
    );
    CREATE INDEX IX_Escalamientos_OV ON dbo.Escalamientos (OV_Number);
END
GO

IF OBJECT_ID('dbo.EscalamientoComentarios') IS NULL
BEGIN
    CREATE TABLE dbo.EscalamientoComentarios (
        ID_Comentario     INT IDENTITY(1,1) PRIMARY KEY,
        ID_Escalamiento   INT           NOT NULL,
        Comentario        NVARCHAR(MAX) NOT NULL,
        Autor             NVARCHAR(100) NULL,
        Fecha             DATETIME      NOT NULL DEFAULT GETDATE()
    );
    CREATE INDEX IX_EscComentarios_Esc ON dbo.EscalamientoComentarios (ID_Escalamiento);
END
GO
PRINT 'Escalamientos: tablas OK';
