-- ============================================================================
-- Conector "Ferco Planificación" (MCP) · Fase 1 · Login de lectura en SERVER-APPS-TAB
-- Lo corre Pedro (sysadmin) o el DBA. NO toca SERVER-SQL.
--
-- Modelo: Node ejecuta SOLO stored procedures para todo lo que viene de SAP/Lisa
-- (sql/Planificacion_04_SP_Lectura.sql), acotados a un documento/cuadro o a listas
-- de máximo 10. Este login solo puede ejecutar esos SP y leer las tablas locales que
-- usan los endpoints; no puede escribir nada.
--
-- Reemplazar <PWD> por una contraseña fuerte y ponerla en el .env del app como
-- PLAN_DB_USER=app_planificacion / PLAN_DB_PASSWORD=<PWD>. Reiniciar el app (pm2).
-- ============================================================================
USE master;
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'app_planificacion')
    CREATE LOGIN app_planificacion WITH PASSWORD = '<PWD>', CHECK_POLICY = ON, DEFAULT_DATABASE = Picking_Management;
GO
USE Picking_Management;
IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'app_planificacion')
    CREATE USER app_planificacion FOR LOGIN app_planificacion;
GO
-- Lecturas locales de /api/planificacion
GRANT SELECT ON dbo.OrderRoutePlan            TO app_planificacion;
GRANT SELECT ON dbo.OrderPickingManagement    TO app_planificacion;
GRANT SELECT ON dbo.OrderPickingTask          TO app_planificacion;
GRANT SELECT ON dbo.CentroDistribucion        TO app_planificacion;
GRANT SELECT ON dbo.Escalamientos             TO app_planificacion;
GRANT SELECT ON dbo.EscalamientoComentarios   TO app_planificacion;
GRANT SELECT ON dbo.CuadroEdicionCola         TO app_planificacion;
GRANT SELECT ON dbo.vw_CuadroEdicionPendiente TO app_planificacion;
GRANT SELECT ON dbo.PlanBacklogSnapshot       TO app_planificacion;
GRANT SELECT ON dbo.PlanBacklogCorte          TO app_planificacion;
GRANT SELECT ON dbo.ConfigPlanDiario          TO app_planificacion;
GRANT SELECT ON dbo.ConfigCamion              TO app_planificacion;
GRANT SELECT ON dbo.DespachoBulto             TO app_planificacion;
GO
-- Las ESCRITURAS del conector (agregar/quitar líneas, crear cuadros, prioridad, Comprometida)
-- NO usan este login: corren con la conexión del app, con el nombre del planificador como autor.
-- Este login no tiene acceso a SAP ni a Lisa: el conector no consulta [server-sql] en vivo
-- (el único lector de SAP es el job del backlog, con el login del app).
--
-- Verificación rápida (con el login nuevo):
--   SELECT TOP 1 * FROM dbo.PlanBacklogSnapshot;                                      -- devuelve filas
--   UPDATE dbo.ConfigPlanDiario SET ModificadoEn = ModificadoEn WHERE 1 = 0;          -- esperado: permiso denegado
--
-- NOTA para el DBA (endurecimiento opcional): el linked server SERVER-SQL mapea TODOS los
-- logins locales al usuario remoto 'tableau'. Para negarle el linked server a este login:
--   EXEC sp_addlinkedsrvlogin 'SERVER-SQL', 'false', 'app_planificacion', NULL, NULL;
