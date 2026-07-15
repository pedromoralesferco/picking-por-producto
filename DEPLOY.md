# Despliegue — Picking por Producto / WMS DIMORA

> Cómo pasar cambios de GitHub al servidor de producción.

## Arquitectura (importante)

- **Servidor:** Windows Server. Ruta física de la app: `C:\PickingManagementV2`
- **IIS** sirve el sitio en **HTTPS 443** (`picking.ferco.com.gt`) como **reverse-proxy** → reescribe todo a `http://localhost:8080`. IIS **no** ejecuta Node (no es iisnode).
- **Node** corre en el puerto **8080**, gestionado por **PM2** (nombre del proceso: `picking`).
- ⚠️ **El servidor NO tiene git instalado** y la carpeta **no es un clon** (`.git` no existe). Por eso **no se puede hacer `git pull`** en el servidor.
- El despliegue se hace **descargando los archivos raw de GitHub** con PowerShell.

## Regla clave: ¿reiniciar o no?

| Qué cambiaste | Acción |
|---|---|
| **Backend** (`routes/*.js`, `server.js`, `db.js`) | Descargar archivo(s) + **`pm2 restart picking`** |
| **Frontend** (`public/**` — html, css, js del navegador) | Descargar archivo(s) + **Ctrl+Shift+R** (recarga dura). NO requiere pm2 restart. |
| **`.env`** | Editar en el servidor (NO está en git) + `pm2 restart picking` |

> `iisreset` **no** sirve para aplicar cambios de Node — solo recicla el proxy IIS. Usa siempre `pm2 restart picking`.

## Pasos para desplegar

En **PowerShell (como administrador)** en el servidor:

```powershell
cd C:\PickingManagementV2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = "https://raw.githubusercontent.com/pedromoralesferco/picking-por-producto/main"

# 1) Descargar SOLO los archivos que cambiaron (ejemplos)
Invoke-WebRequest "$base/routes/wms-api.js"       -OutFile "routes\wms-api.js"
Invoke-WebRequest "$base/public/wms/picking.html" -OutFile "public\wms\picking.html"

# 2) Si tocaste backend, reiniciar Node:
pm2 restart picking
```

Luego en el navegador: **Ctrl+Shift+R** (recarga dura para evitar caché del frontend).

### Verificar que bajó la versión nueva
Busca en el archivo descargado un texto que sepas que agregaste en el commit:

```powershell
if (Select-String "routes\wms-api.js" -Pattern "TEXTO_DEL_CAMBIO" -Quiet) { "OK" } else { "FALTA (cache de GitHub, reintenta en ~1 min)" }
```

> Nota: `raw.githubusercontent.com` puede tardar hasta ~1 minuto en reflejar un push reciente (caché CDN). Si dice FALTA, espera y reintenta.

## Confirmar que la app está arriba

```powershell
pm2 list                                  # 'picking' debe estar 'online'
netstat -ano | findstr ":8080"            # debe aparecer LISTENING
```

Si el sitio "no levanta": casi siempre es que el proceso Node de PM2 se cayó (reiniciar IIS NO lo revive). Solución:

```powershell
pm2 restart picking
# si no existe en la lista:
cd C:\PickingManagementV2; pm2 start server.js --name picking; pm2 save
```

Ver el error real de Node:

```powershell
pm2 logs picking --lines 40 --nostream
```

## Base de datos

Los scripts SQL (carpeta `sql/`) se corren aparte, contra la BD `Picking_Management`
(servidor `server-apps-tab`) con SSMS o `sqlcmd`. NO se despliegan con este método.

## Pendiente / mejora futura

Instalar **Git for Windows** en el servidor y convertir `C:\PickingManagementV2` en un clon
real para poder hacer `git pull` (más limpio que descargar archivo por archivo).
Mientras tanto, este método (raw download) es el oficial.
