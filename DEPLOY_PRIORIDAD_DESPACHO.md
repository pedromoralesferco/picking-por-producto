# Despliegue — Prioridad de despacho (HUB Escuintla)

> Complementa `DEPLOY.md`. Mismas reglas: se bajan archivos raw fijando el hash del commit y Node se reinicia con `pm2`.

## Qué hace

- Columna nueva `OrderRoutePlan.PrioridadDespacho`: una cola de despacho 1..N, separada de la prioridad de picking.
- Cada cuadro que termina el picking entra **al final** de la cola (FIFO por hora de fin de picking). El app revisa cada 30 s.
- En **Plan de Despachos → 2. Picking finalizado / Listo para despachar**, quien tiene permiso `priorizacion` escribe la prioridad de despacho. Los demás cuadros se recorren y la **Fecha Planificada** toma la del cuadro de arriba (si queda #1, hoy).
- En **Despacho**, "Picking completado" y "Listas para despachar" salen ordenadas por esa prioridad, con la etiqueta `D1`, `D2`…
- Al despacharse, el cuadro sale de la cola y conserva su número como historial.

## Orden obligatorio

1. **SQL primero.** Si el código sube antes que la columna, Plan de Despachos y Despacho fallan al cargar.
2. Archivos del app.
3. `pm2 restart picking`.

## 1. Base de datos (SSMS, Picking_Management)

Correr `sql/PrioridadDespacho_01_Schema.sql`. Es idempotente. Al final numera por FIFO los cuadros que hoy están listos para despachar.

Comprobar:

```sql
SELECT RouteNumber, RouteName, PrioridadDespacho, FechaFin, FechaPlanDespacho, EstadoDespacho
FROM dbo.OrderRoutePlan
WHERE ID_Centro = 3 AND Estado = 'Finalizado' AND ISNULL(EstadoDespacho,'Pendiente') <> 'Finalizado'
ORDER BY PrioridadDespacho;
```

## 2. Archivos del app (PowerShell como administrador)

```powershell
cd C:\PickingManagementV2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$commit = "REEMPLAZAR_POR_EL_HASH"
$base = "https://raw.githubusercontent.com/pedromoralesferco/picking-por-producto/$commit"

Invoke-WebRequest "$base/server.js"                  -OutFile "server.js"
Invoke-WebRequest "$base/routes/reportes-api.js"     -OutFile "routes\reportes-api.js"
Invoke-WebRequest "$base/routes/order-api.js"        -OutFile "routes\order-api.js"
Invoke-WebRequest "$base/public/plan-despachos.html" -OutFile "public\plan-despachos.html"
Invoke-WebRequest "$base/public/despacho.html"       -OutFile "public\despacho.html"

pm2 restart picking
pm2 logs picking --lines 30 --nostream   # debe decir "Cola de prioridad de despacho activa (30s)." y ningún AVISO de la cola
```

Luego **Ctrl+Shift+R** en el navegador.

## 3. Verificación

1. Plan de Despachos, sección 2: la columna dice **Prio desp.** y los cuadros vienen 1, 2, 3… del más antiguo al más reciente.
2. Mover uno de pasado mañana a la prioridad 1: los demás bajan un lugar y su Fecha Planificada pasa a hoy.
3. Despacho: los cuadros con picking terminado salen en el mismo orden, con la etiqueta `D#`.
4. Al terminar el picking de un cuadro nuevo, en menos de 30 s aparece al final de la cola.

## Volver atrás

Bajar los 5 archivos del commit anterior y `pm2 restart picking`. La columna puede quedarse; nada más la usa.
