# Notificaciones a clientes (WhatsApp vía n8n)

Proceso independiente del app de Picking. Cada ~10 min, una tarea programada
de Windows en el servidor del app (`sync_notif.ps1`):

1. **Detecta en SAP** (por país) las OV nuevas en preparación (`U_Estado2='03'`),
   con cliente, celular, vendedor, dirección y fecha de entrega, más las cancelaciones.
2. **Lee el avance** desde las tablas del app de Picking: el pedido entra a un cuadro,
   inicia y termina el picking, y se despacha.
3. **Sube a Supabase** (proyecto SAC_FERCO, esquema `notif`) lo que cambió.

n8n Cloud solo habla con Supabase. Nunca toca SQL Server ni SAP.

```
SAP + Picking_Management ──(sync_notif.ps1 cada 10 min)──► Supabase notif ◄── n8n Cloud ──► WhatsApp
```

## Archivos

| Archivo | Dónde corre | Qué hace |
|---|---|---|
| `sql/Notif_01_Schema_y_SPs.sql` | SSMS, `Picking_Management` | Tabla `NotifPedido` + `SP_NotifDetectarSAP` + `SP_NotifHitos` |
| `supabase/notif_01_schema.sql` | Supabase (ya aplicado) | Esquema `notif`: catálogo, `pedido`, `evento`, funciones |
| `supabase/notif_04_vendedor_y_vista.sql` | Supabase (ya aplicado) | Vendedor, `fecha_estado`, vista `v_pedidos_activos` |
| `supabase/notif_02_usuario_n8n.sql` | Supabase (ya aplicado) | Usuario `notif_n8n` de solo lectura + funciones de envío |
| `supabase/notif_05_silencioso_y_antiguedad.sql` | Supabase (ya aplicado) | Modo silencioso a prueba de olvidos + avisos de máx. 6 h |
| `supabase/notif_06_almacen_en_vista.sql` | Supabase (ya aplicado) | Columna `almacen` en la vista |
| `supabase/notif_03_prueba.sql` | Supabase | Prueba de humo (pedido ficticio `ZZ`, se borra solo) |
| `notif/sync_notif.ps1` | Servidor del app | El sync |
| `notif/instalar_tarea.ps1` | Servidor del app | Registra la tarea `\Ferco\NotifSync` |

## Despliegue en el servidor

1. **SQL**: correr `sql/Notif_01_Schema_y_SPs.sql` en SSMS (crea todo en `Picking_Management`).
2. **Carpeta**: crear `C:\NotifSync` y copiar ahí `sync_notif.ps1`, `instalar_tarea.ps1` y `.env.example`.
3. **.env**: copiar `.env.example` como `.env` y llenarlo. Para empezar se puede usar el mismo
   usuario SQL del app (`DB_USER` del `.env` del app), porque los SPs leen SAP por el
   linked server con esa misma conexión. La llave de Supabase es la secreta (service_role) de SAC_FERCO.
4. **Carga inicial silenciosa**, a mano (sube lo que ya está abierto sin escribirle a nadie).
   La primera corrida de un país siempre es silenciosa, aunque se olvide el `-Silencioso`:
   ```
   cd C:\NotifSync
   powershell -NoProfile -ExecutionPolicy Bypass -File .\sync_notif.ps1 -Silencioso
   ```
   Revisar el log (`.\logs\`) y la vista `notif.v_pedidos_activos` en Supabase.
5. **Tarea programada** (como administrador): `powershell -ExecutionPolicy Bypass -File .\instalar_tarea.ps1`

`-DryRun` no corre los SPs ni sube nada: solo muestra cuántas filas están pendientes de
subir y un ejemplo. Sirve para revisar antes de una corrida.

**Después de una caída larga** (servidor o tarea detenidos varias horas): correr una vez a
mano con `-Silencioso` antes de reactivar la tarea. Las fechas "recibido" y "planificado"
se toman cuando el sync las ve, así que la regla de las 6 horas no las detiene.

**Almacenes**: `NOTIF_PAISES` define país, base SAP y almacenes, por ejemplo `GT:sboferco:138`.
Varios almacenes de un mismo país se separan con `+` (`GT:sboferco:138+01`). Si no se ponen
almacenes, entran todos los de ese país. Solo entran las OV con al menos una línea en esos
almacenes, y el almacén queda en la columna `almacen` de la vista.

Para agregar SV y HN: sumarlos a `NOTIF_PAISES` (ej. `GT:sboferco:138,SV:sbointergres`).
La primera corrida de un país nuevo es silenciosa sola.

## Reglas

- **Solo OV.** Las TR y RMA no tienen `U_Celular`.
- **Todos los tipos de entrega** del almacén (no solo RUTA). Con `NOTIF_SOLO_RUTA=1` se limita a `TrnspCode = 22`.
- **Celular**: se toma el primer número que parezca móvil del país (GT 3/4/5, SV 6/7, HN 3/7/8/9)
  y se guarda como `+502XXXXXXXX`. Sin móvil válido el pedido igual se sincroniza, pero queda
  `notificable = false` y no se le escribe.
- **Fechas**: "recibido" y "planificado" son la primera vez que el sync lo vio (hasta ~10 min de
  diferencia). Las de picking y despacho son las reales del app.
- **Un aviso por paso por pedido.** Un paso detectado con más de 6 horas de atraso queda `omitido`.
- **Despachado** = `EstadoDespacho = 'Finalizado'` en el app (en Escuintla: picking completo + placa en SAP).
- **Avisos viejos**: n8n nunca recibe avisos de más de 6 horas, aunque haya estado caído.

Límites conocidos:
- Si la OV sale en un complemento, se sigue el cuadro más reciente: el despacho del cuadro
  original no se avisa hasta que salga el complemento.
- Una OV que deja de estar en '03' sin cancelarse ni despacharse se queda activa en la vista.

---

## Respuestas para la desarrolladora de n8n

**1. Campos.** n8n no lee SAP. Lee la vista **`notif.v_pedidos_activos`** en Supabase: una fila
por pedido, solo los activos y los que cerraron en los últimos 7 días.

| Columna | Qué es |
|---|---|
| `pais`, `numero_pedido` | País (GT/SV/HN) y número de OV de SAP |
| `cliente_nombre`, `celular` | Cliente y celular en formato internacional (`+502...`) |
| `notificable` | `false` si no hay un celular móvil válido |
| `vendedor_nombre`, `vendedor_email` | Vendedor de la OV |
| `direccion`, `fecha_entrega` | Dirección y fecha de entrega de SAP |
| `fecha_entrega_cliente` | Fecha que pidió el cliente si reprogramó |
| `estado`, `estado_descripcion` | Estatus actual (ver catálogo) |
| `fecha_ultimo_cambio` | Fecha y hora del último cambio de estatus |
| `confirmacion` | Respuesta del cliente: pendiente / confirmado / reprogramar / rechazado |
| `cuadro_ruta`, `placa` | Cuadro de ruta y camión, cuando existen |
| `almacen` | Almacén SAP que despacha (ej. `138`) |
| `fecha_recibido` … `fecha_cancelado` | Historial: fecha y hora de cada estatus |

**2. Catálogo de estatus** (`notif.estado_catalogo`):

| Estatus | Significado | Origen |
|---|---|---|
| `RECIBIDO` | Pedido en preparación | SAP Business One, campo de usuario `U_Estado2 = '03'` en la OV |
| `CONFIRMADO_CLIENTE` | El cliente confirmó por WhatsApp | n8n (respuesta del cliente) |
| `PLANIFICADO` | Asignado a un cuadro de ruta | App de Picking |
| `PICKING_INICIADO` | Empezó la preparación en bodega | App de Picking (que a su vez lee LISA) |
| `PICKING_COMPLETADO` | Terminó la preparación en bodega | App de Picking (que a su vez lee LISA) |
| `DESPACHADO` | Salió con camión asignado | App de Picking + placa del cuadro en SAP |
| `CANCELADO` | OV cancelada | SAP Business One |

"En ruta" equivale hoy a `DESPACHADO`. **"Entregado" no tiene fuente todavía**; habría que definir de dónde sale.

**3. Conexión** (nodo Postgres de n8n). No es SAP ni SQL Server: es Supabase (PostgreSQL 17).
- Host: el del *Session pooler* (Supabase → Project Settings → Database → Connection string), región `ca-central-1`
- Puerto `5432`, base `postgres`, usuario `notif_n8n.fhefwggpiumjtcnqixsb`, SSL `require`
- Contraseña: se entrega por un canal seguro, no por correo ni chat.
- El usuario es de solo lectura sobre las vistas. Además puede ejecutar 4 funciones:
  - `notif.tomar_avisos(50)`: reserva los WhatsApp por enviar (no se repiten aunque dos flujos corran a la vez).
  - `notif.marcar_envio(id, 'enviado' | 'error', wa_message_id, error)`: registra el resultado del envío.
  - `notif.pedidos_por_respuesta(wa_message_id, celular)`: dice a qué pedido responde el cliente.
  - `notif.registrar_confirmacion(pais, pedido, respuesta, fecha_cliente, nota)`: guarda la respuesta del cliente.

**4. Red.** No hay que abrir nada ni montar VPN: n8n Cloud llega a Supabase por internet con SSL.

**5. Respuestas del cliente hacia SAP.** Por ahora quedan en Supabase (`confirmacion`,
`fecha_entrega_cliente`, `confirmacion_nota`). Llevarlas a SAP y avisar a despachos es una
segunda fase; FERCO define el camino (Service Layer o los robots de UiPath que ya escriben en SAP).

**6. App de Picking.** No hace falta API ni webhook: sus estatus ya llegan a la misma vista
(`PLANIFICADO`, `PICKING_*`, `DESPACHADO`), de solo lectura.
