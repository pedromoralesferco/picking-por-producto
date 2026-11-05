# Despliegue — Conector "Ferco Planificación" (MCP) · Fase 1 light

> Complementa `DEPLOY.md`. Mismas reglas: el servidor no tiene git, se bajan archivos raw de GitHub fijando el hash del commit, y Node se reinicia con `pm2`.

Son tres piezas, en este orden:

1. **Base de datos** (Picking_Management): 3 scripts, una sola vez.
2. **App de Picking** (`C:\PickingManagementV2`): archivos nuevos y modificados + `npm install` + variables del `.env` + `pm2 restart picking`.
3. **Servicio MCP** (carpeta nueva, proceso PM2 nuevo en el puerto 3002) + publicación HTTPS por IIS.

Después: alta del conector en Supabase Auth y en Claude, y permisos a los planificadores en Admin → Usuarios.

---

## 1. Base de datos (SSMS, en SERVER-APPS-TAB, base Picking_Management)

Correr en este orden. Son idempotentes (se pueden repetir sin daño).

| Script | Qué crea |
|---|---|
| `sql/Planificacion_01_Schema.sql` | `Usuario.Email`, `MCP_Auditoria`, `ConfigPlanDiario` y `ConfigCamion` con los valores del HUB (centro 3) |
| `sql/Planificacion_02_Backlog.sql` | `PlanBacklogSnapshot`, `PlanBacklogCorte` y `SP_MCP_BacklogSinCuadro` (lo corre el app cada 15 min) |
| `sql/Planificacion_03_LoginDBA.sql` | Login de solo lectura `app_planificacion` (reemplazar `<PWD>`) |

Opcionales: `Planificacion_04_SP_Lectura.sql` (SP de lectura a SAP; **no los usa** la versión light) y `Planificacion_05_NegarLinkedServer.sql` (negarle el linked server al login de lectura; decisión pendiente).

Comprobar que el snapshot corre: `EXEC dbo.SP_MCP_BacklogSinCuadro @ID_Centro = 3;` tarda ~1 min y debe dejar filas en `PlanBacklogSnapshot`.

## 2. App de Picking

### 2.1 Archivos (PowerShell como administrador)

```powershell
cd C:\PickingManagementV2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$commit = "REEMPLAZAR_POR_EL_HASH"   # commit que incluye el conector
$base = "https://raw.githubusercontent.com/pedromoralesferco/picking-por-producto/$commit"

# Nuevos
New-Item -ItemType Directory -Force middleware | Out-Null
Invoke-WebRequest "$base/middleware/bearer.js"                 -OutFile "middleware\bearer.js"
Invoke-WebRequest "$base/routes/planificacion-api.js"          -OutFile "routes\planificacion-api.js"
Invoke-WebRequest "$base/routes/planificacion-escritura.js"    -OutFile "routes\planificacion-escritura.js"
# Modificados
Invoke-WebRequest "$base/server.js"                            -OutFile "server.js"
Invoke-WebRequest "$base/db.js"                                -OutFile "db.js"
Invoke-WebRequest "$base/package.json"                         -OutFile "package.json"
Invoke-WebRequest "$base/routes/admin.js"                      -OutFile "routes\admin.js"
Invoke-WebRequest "$base/routes/cuadro-crud-api.js"            -OutFile "routes\cuadro-crud-api.js"
Invoke-WebRequest "$base/routes/escalamientos-api.js"          -OutFile "routes\escalamientos-api.js"
Invoke-WebRequest "$base/public/admin.html"                    -OutFile "public\admin.html"

# Dependencia nueva (jose: verificación del pase)
npm install --omit=dev
```

Verificar que bajó la versión correcta:

```powershell
if (Select-String "server.js" -Pattern "Planificacion (MCP)" -Quiet) { "OK" } else { "FALTA" }
```

### 2.2 Variables del `.env` del app (editar en el servidor)

```
# Login de Microsoft (Supabase Auth del proyecto de Ventas Analytics)
PLAN_SUPABASE_URL=https://<proyecto>.supabase.co
PLAN_SUPABASE_ANON_KEY=<anon key del proyecto>
# Opcional: solo aceptar pases emitidos para el conector de Planificación (client_id de Supabase OAuth)
PLAN_ALLOWED_CLIENT_IDS=

# Staging de rutas (Supabase). Idealmente una llave restringida a rutas_staging
PLAN_STAGING_URL=https://<proyecto-staging>.supabase.co
PLAN_STAGING_KEY=<llave>

# Login de SOLO LECTURA para los endpoints /api/planificacion
PLAN_DB_USER=app_planificacion
PLAN_DB_PASSWORD=<la del script 03>

# Robot de importación de rutas (crear_cuadros / lanzar_robot_rutas). Mismos valores que usa start_import_rutas.py
UIPATH_TOKEN_URL=...
UIPATH_CLIENT_ID=...
UIPATH_CLIENT_SECRET=...
UIPATH_STARTJOBS_URL=...
UIPATH_RELEASE_KEY=...
UIPATH_ORG_UNIT=...
```

**Nunca** poner en producción `PLAN_DEV_LOCAL_JWKS`, `PLAN_JWKS_JSON` ni `PLAN_JWT_ISSUER`: son solo para firmar pases de prueba en desarrollo.

### 2.3 Reiniciar y comprobar

```powershell
pm2 restart picking
pm2 logs picking --lines 30 --nostream     # debe decir "Modulo Planificacion (MCP) cargado." y "Snapshot del backlog ... activo (15 min)."
```

Sin pase, el endpoint debe responder 401:

```powershell
Invoke-WebRequest http://localhost:8080/api/planificacion/yo -UseBasicParsing   # esperado: 401 "Falta el pase de acceso"
```

## 3. Servicio MCP (carpeta nueva + proceso PM2 nuevo)

El servicio vive en su propio repositorio/carpeta (`ferco-planificacion-mcp`). **No tiene credenciales**: solo la URL del app y la del Authorization Server.

```powershell
New-Item -ItemType Directory -Force C:\PlanificacionMCP\src | Out-Null
cd C:\PlanificacionMCP
$baseMcp = "https://raw.githubusercontent.com/pedromoralesferco/ferco-planificacion-mcp/<commit>"
Invoke-WebRequest "$baseMcp/package.json"   -OutFile "package.json"
Invoke-WebRequest "$baseMcp/src/index.js"   -OutFile "src\index.js"
npm install --omit=dev
```

`.env` del servicio (`C:\PlanificacionMCP\.env`):

```
PORT=3002
PLAN_API_URL=http://localhost:8080
PLAN_PUBLIC_URL=https://planificacion-mcp.ferco.com.gt
PLAN_AUTH_SERVER=https://<proyecto>.supabase.co/auth/v1
PLAN_ALLOWED_ORIGINS=https://claude.ai,https://claude.com
```

Arrancar y dejar persistente:

```powershell
pm2 start src\index.js --name planificacion-mcp
pm2 save
Invoke-WebRequest http://localhost:3002/health -UseBasicParsing     # {"ok":true,...}
```

### 3.1 Publicación HTTPS (TI / IIS)

Igual que el app: un sitio IIS en 443 para `planificacion-mcp.ferco.com.gt` (o el nombre que defina TI) como reverse-proxy a `http://localhost:3002`. Debe pasar los encabezados `Authorization`, `Accept` y `Mcp-Session-Id` sin tocarlos, y permitir `POST` y `GET` en `/mcp` y `/.well-known/*`. El valor final va en `PLAN_PUBLIC_URL` y en el `.mcp.json` del plugin.

Comprobación externa: `https://<url>/.well-known/oauth-protected-resource/mcp` debe responder JSON con `authorization_servers`.

## 4. Login y alta del conector

1. **Supabase Auth** (proyecto de Ventas Analytics, Authentication → OAuth): registrar "Ferco Planificación" como cliente. Si entrega un `client_id`, ponerlo en `PLAN_ALLOWED_CLIENT_IDS` del app para que un pase de Ventas no sirva aquí.
2. **Página de consentimiento** (Vercel, `consent-page/oauth/consent.html`): que muestre el nombre del conector que pide acceso.
3. **Claude** (admin de la organización): agregar el conector con la URL `https://<url>/mcp`, o publicar el plugin `ferco-planificacion-plugin` (lleva `.mcp.json` con esa URL y las 4 skills).
4. **Admin → Usuarios** del app: a cada planificador, su **Correo** de Microsoft y la casilla **"Planificacion con Claude"**; para escribir necesita además **Priorizacion** (o ser Admin).

## 5. Verificación de punta a punta

1. Un planificador conecta en Claude → inicia sesión con Microsoft → `yo` devuelve su nombre y centros.
2. `backlog_sin_cuadro` devuelve un corte de menos de 30 min.
3. Una escritura inofensiva en dos pasos (p. ej. fecha de un cuadro y regresarla) queda en `MCP_Auditoria` con su correo y clave de operación.

## 6. Si algo falla

| Síntoma | Causa probable | Qué revisar |
|---|---|---|
| `Modulo Planificacion (MCP) deshabilitado` en el log | Falta un archivo o `jose` no instalado | Bajar de nuevo los 3 archivos nuevos; `npm install` |
| 503 "Autenticación de planificación no configurada" | Falta `PLAN_SUPABASE_URL` | `.env` del app + `pm2 restart picking` |
| 401 "Pase inválido o vencido" con un login correcto | `PLAN_SUPABASE_URL` apunta a otro proyecto o el pase no es de Supabase Auth | Comparar con el proyecto de Ventas |
| 403 "Sin acceso al conector" | El correo no está en `Usuario.Email` o falta la casilla | Admin → Usuarios |
| `backlog` 503 "no hay un corte" | El job no ha corrido o falló | `SELECT TOP 5 * FROM PlanBacklogCorte ORDER BY ID_Corte DESC` (columna `Error`) |
| `estado_staging` 503 | Faltan `PLAN_STAGING_URL/KEY` | `.env` del app |
| `crear_cuadros` aplica pero `errorRobot` no es null | Faltan `UIPATH_*` o el token falló | `.env` del app; el staging ya quedó cargado, se puede relanzar con `lanzar_robot_rutas` |
