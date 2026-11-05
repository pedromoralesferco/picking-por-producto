-- Conector "Ferco Planificación": negarle el linked server SERVER-SQL al login de lectura.
-- Correr en SERVER-APPS-TAB (SSMS, con un login sysadmin). Reversible con el bloque de abajo.
-- Efecto: cualquier consulta de app_planificacion hacia [server-sql] falla por login;
-- el único camino a SAP queda en el job del backlog, que corre con el login del app.
EXEC master.dbo.sp_addlinkedsrvlogin
    @rmtsrvname = 'SERVER-SQL',
    @useself    = 'false',
    @locallogin = 'app_planificacion',
    @rmtuser    = NULL,
    @rmtpassword = NULL;
GO

-- Verificación (con el login app_planificacion): debe fallar por login
--   SELECT TOP 1 DocNum FROM [server-sql].sboferco.dbo.ORDR WITH (NOLOCK);

-- Para revertir:
--   EXEC master.dbo.sp_droplinkedsrvlogin @rmtsrvname = 'SERVER-SQL', @locallogin = 'app_planificacion';
