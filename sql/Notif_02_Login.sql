-- ════════════════════════════════════════════════════════════════════
-- Login propio para el sync de notificaciones (C:\SACWhatsappSync)
-- Correr en SSMS en SERVER-APPS-TAB con un login que pueda crear logins.
--
-- ANTES DE CORRER: reemplazar <PWD> por una contraseña fuerte. Evitar la
-- comilla simple ('). No guardar el script con la contraseña puesta.
-- Luego poner en C:\SACWhatsappSync\.env:
--   NOTIF_DB_USER=app_sacwhatsapp
--   NOTIF_DB_PASSWORD=<la misma contraseña>
--
-- Permisos: solo ejecutar los dos SPs del sync y leer/actualizar NotifPedido.
-- No puede leer ni escribir ninguna otra tabla del app. Los SPs leen SAP por
-- el linked server SERVER-SQL, que hoy mapea todos los logins locales al
-- usuario remoto de solo lectura.
-- ════════════════════════════════════════════════════════════════════
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'app_sacwhatsapp')
    CREATE LOGIN app_sacwhatsapp WITH PASSWORD = '<PWD>', CHECK_POLICY = ON, DEFAULT_DATABASE = Picking_Management;
GO
USE Picking_Management;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'app_sacwhatsapp')
    CREATE USER app_sacwhatsapp FOR LOGIN app_sacwhatsapp;
GO
GRANT EXECUTE ON dbo.SP_NotifDetectarSAP TO app_sacwhatsapp;
GRANT EXECUTE ON dbo.SP_NotifHitos       TO app_sacwhatsapp;
GRANT SELECT, UPDATE ON dbo.NotifPedido  TO app_sacwhatsapp;
GO
PRINT 'Login app_sacwhatsapp listo';

-- Verificación (conectado como app_sacwhatsapp):
--   SELECT COUNT(*) FROM dbo.NotifPedido;            -- funciona
--   SELECT TOP 1 * FROM dbo.OrderRoutePlan;          -- esperado: permiso denegado
