-- ════════════════════════════════════════════════════════════════════
-- Notificaciones a clientes (WhatsApp vía n8n Cloud) — esquema Supabase
-- Proyecto: https://fhefwggpiumjtcnqixsb.supabase.co (solo notificaciones)
-- Se corre completo en el SQL Editor. Se puede volver a correr sin romper nada.
--
-- Principios
--  * Solo viaja a Supabase lo mínimo para el mensaje (nombre, celular,
--    dirección, fecha, cuadro). Nada de montos, artículos, precios ni costos.
--  * El app de Picking EMPUJA (push) a Supabase; n8n nunca toca SQL Server.
--  * notif.pedido   = tabla maestra, 1 fila por pedido, estado + una fecha por hito.
--  * notif.evento   = bandeja de salida (outbox), 1 fila por aviso a enviar.
--                     n8n reserva avisos con tomar_avisos() y los marca
--                     enviado/error con marcar_envio().
--  * Los hitos nunca retroceden y una fecha ya puesta no se sobreescribe.
--  * Llave del pedido: (pais, doc_type, doc_num). El celular NO es llave
--    (un cliente puede tener varios pedidos abiertos), va indexado.
-- ════════════════════════════════════════════════════════════════════

create schema if not exists notif;

-- ── Catálogo de estados ─────────────────────────────────────────────
create table if not exists notif.estado_catalogo (
    codigo        text primary key,
    orden         smallint not null unique,      -- el estado del pedido = hito de mayor orden alcanzado
    nombre        text not null,
    notifica      boolean not null default true, -- ¿genera mensaje al cliente?
    plantilla_wa  text                           -- nombre de la plantilla aprobada en WhatsApp Business
);

insert into notif.estado_catalogo (codigo, orden, nombre, notifica, plantilla_wa) values
    ('RECIBIDO',           10, 'Pedido recibido (en preparación)',  true,  'pedido_recibido'),
    ('CONFIRMADO_CLIENTE', 20, 'Cliente confirmó condiciones',      false, null),
    ('PLANIFICADO',        30, 'Asignado a cuadro de ruta',         true,  'pedido_planificado'),
    ('PICKING_INICIADO',   40, 'Preparación en bodega iniciada',    true,  'picking_iniciado'),
    ('PICKING_COMPLETADO', 50, 'Preparación en bodega completada',  true,  'picking_completado'),
    ('DESPACHADO',         60, 'Despachado (camión asignado)',      true,  'pedido_despachado'),
    ('CANCELADO',          90, 'Pedido cancelado / anulado',        false, null)
on conflict (codigo) do update
    set orden = excluded.orden, nombre = excluded.nombre,
        notifica = excluded.notifica, plantilla_wa = excluded.plantilla_wa;

-- ── Tabla maestra por pedido ────────────────────────────────────────
create table if not exists notif.pedido (
    pais                 char(2)  not null,               -- GT | SV | HN ...
    doc_type             text     not null default 'OV',  -- solo OV (TR/RMA no tienen ORDR.U_Celular)
    doc_num              integer  not null,
    estado               text     not null references notif.estado_catalogo(codigo),

    -- Datos para el mensaje (dueño: sync del app)
    cliente_nombre       text,
    celular_original     text,                            -- ORDR.U_Celular tal cual
    celular_e164         text,                            -- normalizado: +502XXXXXXXX
    notificable          boolean  not null default false, -- false si el celular no es válido
    direccion            text,
    fecha_entrega        date,                            -- ORDR.DocDueDate
    centro               text,                            -- nombre del centro / bodega que despacha
    cuadro_actual        integer,                         -- último cuadro en el que está
    placa                text,                            -- opcional: solo si se quiere decir el camión

    -- Confirmación del cliente (dueño: n8n, vía notif.registrar_confirmacion)
    confirmacion         text check (confirmacion in ('pendiente','confirmado','reprogramar','rechazado')),
    confirmacion_nota    text,
    fecha_entrega_cliente date,                           -- la fecha que el cliente pidió, si reprogramó

    -- Hitos: fecha en que sucede cada paso (nunca se sobreescriben)
    fecha_recibido           timestamptz,
    fecha_confirmacion       timestamptz,
    fecha_planificado        timestamptz,
    fecha_picking_inicio     timestamptz,
    fecha_picking_fin        timestamptz,
    fecha_despacho           timestamptz,
    fecha_cancelado          timestamptz,

    creado_en            timestamptz not null default now(),
    actualizado_en       timestamptz not null default now(),
    primary key (pais, doc_type, doc_num)
);
create index if not exists ix_pedido_celular on notif.pedido (pais, celular_e164);
create index if not exists ix_pedido_estado  on notif.pedido (pais, estado);

-- ── Bandeja de salida: un aviso por (pedido, hito, cuadro) ──────────
-- cuadro=0 cuando el hito no depende de cuadro (RECIBIDO, CONFIRMADO).
-- v1: un aviso por hito por pedido (la fecha guarda la PRIMERA vez). La
-- columna cuadro queda lista por si luego se quiere avisar de nuevo cuando
-- el pedido sale en un complemento (decisión abierta).
create table if not exists notif.evento (
    id            bigserial primary key,
    pais          char(2) not null,
    doc_type      text    not null,
    doc_num       integer not null,
    evento        text    not null references notif.estado_catalogo(codigo),
    cuadro        integer not null default 0,
    ocurrido_en   timestamptz not null,
    envio_estado  text not null default 'pendiente'
                  check (envio_estado in ('pendiente','enviando','enviado','error','omitido')),
    intentos      smallint not null default 0,
    tomado_en     timestamptz,                 -- cuándo n8n lo reservó (estado 'enviando')
    enviado_en    timestamptz,
    wa_message_id text,
    error         text,
    creado_en     timestamptz not null default now(),
    unique (pais, doc_type, doc_num, evento, cuadro),
    foreign key (pais, doc_type, doc_num) references notif.pedido (pais, doc_type, doc_num)
);
create index if not exists ix_evento_pendiente on notif.evento (envio_estado) where envio_estado = 'pendiente';

-- ── Vista que consume n8n: el aviso ya con los datos del mensaje ────
create or replace view notif.v_avisos_pendientes as
select e.id, e.evento, c.plantilla_wa, e.cuadro, e.ocurrido_en,
       p.pais, p.doc_num, p.cliente_nombre, p.celular_e164, p.direccion,
       coalesce(p.fecha_entrega_cliente, p.fecha_entrega) as fecha_entrega,
       p.centro, p.placa
from notif.evento e
join notif.pedido p using (pais, doc_type, doc_num)
join notif.estado_catalogo c on c.codigo = e.evento
where e.envio_estado = 'pendiente'
  and c.notifica
  and p.notificable;

-- ════════════════════════════════════════════════════════════════════
-- RPC 1: notif.upsert_pedidos(filas jsonb, silencioso boolean)
-- La llama SOLO el job del app de Picking (POST /rest/v1/rpc/upsert_pedidos,
-- header Content-Profile: notif, con la service_role key).
--  * Actualiza los datos del mensaje.
--  * Cada fecha_* se llena solo si estaba vacía (coalesce) -> no retrocede.
--  * Por cada hito NUEVO inserta su evento (on conflict do nothing).
--  * silencioso=true (carga inicial / backfill): los eventos se crean como
--    'omitido' para no escribirle a clientes por pedidos viejos.
-- ════════════════════════════════════════════════════════════════════
create or replace function notif.upsert_pedidos(filas jsonb, silencioso boolean default false)
returns integer
language plpgsql
security definer
set search_path = notif, public
as $$
declare
    f        jsonb;
    antes    notif.pedido%rowtype;
    despues  notif.pedido%rowtype;
    n        integer := 0;
    est_ini  text := case when silencioso then 'omitido' else 'pendiente' end;
    cuadro_f integer;
begin
    for f in select * from jsonb_array_elements(filas) loop
        -- 'silencioso' puede venir por fila (backfill de NotifPedido.Silencioso)
        est_ini := case when coalesce((f->>'silencioso')::boolean, silencioso) then 'omitido' else 'pendiente' end;
        select * into antes from notif.pedido
         where pais = f->>'pais' and doc_type = coalesce(f->>'doc_type','OV') and doc_num = (f->>'doc_num')::int
         for update;

        insert into notif.pedido as p (
            pais, doc_type, doc_num, estado,
            cliente_nombre, celular_original, celular_e164, notificable,
            direccion, fecha_entrega, centro, cuadro_actual, placa,
            fecha_recibido, fecha_planificado, fecha_picking_inicio,
            fecha_picking_fin, fecha_despacho, fecha_cancelado)
        values (
            f->>'pais', coalesce(f->>'doc_type','OV'), (f->>'doc_num')::int, 'RECIBIDO',
            f->>'cliente_nombre', f->>'celular_original', f->>'celular_e164',
            coalesce((f->>'notificable')::boolean, false),
            f->>'direccion', (f->>'fecha_entrega')::date, f->>'centro',
            (f->>'cuadro_actual')::int, f->>'placa',
            (f->>'fecha_recibido')::timestamptz, (f->>'fecha_planificado')::timestamptz,
            (f->>'fecha_picking_inicio')::timestamptz, (f->>'fecha_picking_fin')::timestamptz,
            (f->>'fecha_despacho')::timestamptz, (f->>'fecha_cancelado')::timestamptz)
        on conflict (pais, doc_type, doc_num) do update set
            -- un campo que no viene (null) no borra lo que ya había
            cliente_nombre       = coalesce(excluded.cliente_nombre,   p.cliente_nombre),
            celular_original     = coalesce(excluded.celular_original, p.celular_original),
            celular_e164         = coalesce(excluded.celular_e164,     p.celular_e164),
            notificable          = excluded.notificable,
            direccion            = coalesce(excluded.direccion,        p.direccion),
            fecha_entrega        = coalesce(excluded.fecha_entrega,    p.fecha_entrega),
            centro               = coalesce(excluded.centro,           p.centro),
            cuadro_actual        = coalesce(excluded.cuadro_actual, p.cuadro_actual),
            placa                = coalesce(excluded.placa, p.placa),
            fecha_recibido       = coalesce(p.fecha_recibido,       excluded.fecha_recibido),
            fecha_planificado    = coalesce(p.fecha_planificado,    excluded.fecha_planificado),
            fecha_picking_inicio = coalesce(p.fecha_picking_inicio, excluded.fecha_picking_inicio),
            fecha_picking_fin    = coalesce(p.fecha_picking_fin,    excluded.fecha_picking_fin),
            fecha_despacho       = coalesce(p.fecha_despacho,       excluded.fecha_despacho),
            fecha_cancelado      = coalesce(p.fecha_cancelado,      excluded.fecha_cancelado),
            actualizado_en       = now()
        returning * into despues;

        -- Estado = hito de mayor orden alcanzado (CANCELADO gana solo si no se despachó)
        update notif.pedido set estado = case
                when despues.fecha_despacho       is not null then 'DESPACHADO'
                when despues.fecha_cancelado      is not null then 'CANCELADO'
                when despues.fecha_picking_fin    is not null then 'PICKING_COMPLETADO'
                when despues.fecha_picking_inicio is not null then 'PICKING_INICIADO'
                when despues.fecha_planificado    is not null then 'PLANIFICADO'
                when despues.confirmacion = 'confirmado'     then 'CONFIRMADO_CLIENTE'
                else 'RECIBIDO' end
         where pais = despues.pais and doc_type = despues.doc_type and doc_num = despues.doc_num;

        -- Eventos de los hitos que acaban de aparecer
        cuadro_f := coalesce(despues.cuadro_actual, 0);
        insert into notif.evento (pais, doc_type, doc_num, evento, cuadro, ocurrido_en, envio_estado)
        -- Un hito viejo (backfill, job caído, celular corregido tarde) se guarda
        -- como 'omitido': no se le escribe al cliente algo que pasó hace horas.
        select despues.pais, despues.doc_type, despues.doc_num, h.evento, h.cuadro, h.fecha,
               case when h.fecha < now() - interval '6 hours' then 'omitido' else est_ini end
        from (values
            ('RECIBIDO',           0,        despues.fecha_recibido,       antes.fecha_recibido),
            ('PLANIFICADO',        cuadro_f, despues.fecha_planificado,    antes.fecha_planificado),
            ('PICKING_INICIADO',   cuadro_f, despues.fecha_picking_inicio, antes.fecha_picking_inicio),
            ('PICKING_COMPLETADO', cuadro_f, despues.fecha_picking_fin,    antes.fecha_picking_fin),
            ('DESPACHADO',         cuadro_f, despues.fecha_despacho,       antes.fecha_despacho),
            ('CANCELADO',          0,        despues.fecha_cancelado,      antes.fecha_cancelado)
        ) as h(evento, cuadro, fecha, fecha_antes)
        where h.fecha is not null and h.fecha_antes is null
        on conflict (pais, doc_type, doc_num, evento, cuadro) do nothing;

        n := n + 1;
    end loop;
    return n;
end $$;

-- ════════════════════════════════════════════════════════════════════
-- RPC 2: notif.registrar_confirmacion — la llama n8n cuando el cliente
-- responde el WhatsApp. Solo toca las columnas de confirmación.
-- ════════════════════════════════════════════════════════════════════
create or replace function notif.registrar_confirmacion(
    p_pais char(2), p_doc_num integer, p_respuesta text,
    p_fecha_cliente date default null, p_nota text default null)
returns void
language plpgsql
security definer
set search_path = notif, public
as $$
begin
    update notif.pedido set
        confirmacion          = p_respuesta,
        confirmacion_nota     = p_nota,
        fecha_entrega_cliente = coalesce(p_fecha_cliente, fecha_entrega_cliente),
        fecha_confirmacion    = now(),   -- fecha de la última respuesta
        estado = case when estado = 'RECIBIDO' and p_respuesta = 'confirmado'
                      then 'CONFIRMADO_CLIENTE' else estado end,
        actualizado_en        = now()
    where pais = p_pais and doc_type = 'OV' and doc_num = p_doc_num;
end $$;

-- RPC 2b: notif.tomar_avisos — n8n reserva un lote de avisos antes de
-- enviarlos (pendiente -> enviando). Si dos corridas se traslapan, cada una
-- recibe avisos distintos (skip locked). Un aviso que quedó 'enviando' más
-- de 15 min (n8n falló a media corrida) vuelve a estar disponible.
create or replace function notif.tomar_avisos(p_limite integer default 50)
returns setof notif.v_avisos_pendientes
language sql
security definer
set search_path = notif, public
as $$
    with libres as (
        select e.id
        from notif.evento e
        join notif.pedido p using (pais, doc_type, doc_num)
        join notif.estado_catalogo c on c.codigo = e.evento
        where c.notifica and p.notificable
          and (e.envio_estado = 'pendiente'
               or (e.envio_estado = 'enviando' and e.tomado_en < now() - interval '15 minutes'))
        order by e.ocurrido_en
        limit p_limite
        for update of e skip locked
    ), tomados as (
        update notif.evento e set envio_estado = 'enviando', tomado_en = now()
        from libres where e.id = libres.id
        returning e.id
    )
    select e.id, e.evento, c.plantilla_wa, e.cuadro, e.ocurrido_en,
           p.pais, p.doc_num, p.cliente_nombre, p.celular_e164, p.direccion,
           coalesce(p.fecha_entrega_cliente, p.fecha_entrega) as fecha_entrega,
           p.centro, p.placa
    from tomados t
    join notif.evento e on e.id = t.id
    join notif.pedido p using (pais, doc_type, doc_num)
    join notif.estado_catalogo c on c.codigo = e.evento;
$$;

-- RPC 3: notif.marcar_envio — n8n reporta el resultado de cada WhatsApp.
create or replace function notif.marcar_envio(
    p_id bigint, p_estado text, p_wa_message_id text default null, p_error text default null)
returns void
language sql
security definer
set search_path = notif, public
as $$
    update notif.evento set
        envio_estado  = p_estado,
        intentos      = intentos + 1,
        enviado_en    = case when p_estado = 'enviado' then now() else enviado_en end,
        wa_message_id = coalesce(p_wa_message_id, wa_message_id),
        error         = p_error
    where id = p_id;
$$;

-- RPC 4: notif.pedidos_por_respuesta — n8n recibe la respuesta del cliente
-- y necesita saber de qué pedido habla: primero por el mensaje citado
-- (wa_message_id), si no, los pedidos abiertos de ese celular.
create or replace function notif.pedidos_por_respuesta(
    p_wa_message_id text default null, p_celular_e164 text default null)
returns table (pais char(2), doc_num integer, estado text, fecha_entrega date, direccion text)
language sql
security definer
set search_path = notif, public
as $$
    select p.pais, p.doc_num, p.estado, p.fecha_entrega, p.direccion
    from notif.pedido p
    where exists (select 1 from notif.evento e
                  where e.wa_message_id = p_wa_message_id
                    and (e.pais, e.doc_type, e.doc_num) = (p.pais, p.doc_type, p.doc_num))
    union
    select p.pais, p.doc_num, p.estado, p.fecha_entrega, p.direccion
    from notif.pedido p
    where p_wa_message_id is null
      and p.celular_e164 = p_celular_e164
      and p.estado not in ('DESPACHADO', 'CANCELADO');
$$;

-- ════════════════════════════════════════════════════════════════════
-- Seguridad: nada expuesto a anon/authenticated.
--   App de Picking -> REST (como rutas_staging) con la service_role key de
--     ESTE proyecto; 'notif' se agrega a "Exposed schemas" y el job manda
--     Content-Profile: notif. Solo puede ejecutar upsert_pedidos.
--   n8n Cloud -> nodo Postgres con un usuario propio (notif_n8n, vía el
--     pooler). Solo ve la vista y las RPC de envío/confirmación.
-- ════════════════════════════════════════════════════════════════════
alter table notif.estado_catalogo enable row level security;
alter table notif.pedido          enable row level security;
alter table notif.evento          enable row level security;
revoke all on schema notif from anon, authenticated;
revoke execute on all functions in schema notif from public, anon, authenticated;
grant usage on schema notif to service_role;
grant execute on function notif.upsert_pedidos(jsonb, boolean) to service_role;

-- El usuario de n8n (notif_n8n) y sus permisos están en notif_02_usuario_n8n.sql.
