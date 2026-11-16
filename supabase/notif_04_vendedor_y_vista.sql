-- ════════════════════════════════════════════════════════════════════
-- notif_04 — Pedido de la desarrolladora de n8n:
--  * vendedor (nombre y correo) en la tabla maestra
--  * fecha_estado: fecha y hora del último cambio de estatus (una columna),
--    además del historial por estatus que ya existe (fecha_recibido,
--    fecha_confirmacion, fecha_planificado, fecha_picking_inicio,
--    fecha_picking_fin, fecha_despacho, fecha_cancelado)
--  * vista notif.v_pedidos_activos: una fila por pedido activo o reciente,
--    con las columnas que pidió, para que n8n la lea con notif_n8n.
-- Correr después de notif_01..03. Se puede volver a correr.
-- ════════════════════════════════════════════════════════════════════

alter table notif.pedido add column if not exists vendedor_nombre text;
alter table notif.pedido add column if not exists vendedor_email  text;
alter table notif.pedido add column if not exists fecha_estado    timestamptz;

-- upsert_pedidos: + vendedor y fecha_estado (= fecha del hito del estado actual)
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
    v_estado text;
begin
    for f in select * from jsonb_array_elements(filas) loop
        est_ini := case when coalesce((f->>'silencioso')::boolean, silencioso) then 'omitido' else 'pendiente' end;
        select * into antes from notif.pedido
         where pais = f->>'pais' and doc_type = coalesce(f->>'doc_type','OV') and doc_num = (f->>'doc_num')::int
         for update;

        insert into notif.pedido as p (
            pais, doc_type, doc_num, estado,
            cliente_nombre, celular_original, celular_e164, notificable,
            vendedor_nombre, vendedor_email,
            direccion, fecha_entrega, centro, cuadro_actual, placa,
            fecha_recibido, fecha_planificado, fecha_picking_inicio,
            fecha_picking_fin, fecha_despacho, fecha_cancelado)
        values (
            f->>'pais', coalesce(f->>'doc_type','OV'), (f->>'doc_num')::int, 'RECIBIDO',
            f->>'cliente_nombre', f->>'celular_original', f->>'celular_e164',
            coalesce((f->>'notificable')::boolean, false),
            f->>'vendedor_nombre', f->>'vendedor_email',
            f->>'direccion', (f->>'fecha_entrega')::date, f->>'centro',
            (f->>'cuadro_actual')::int, f->>'placa',
            (f->>'fecha_recibido')::timestamptz, (f->>'fecha_planificado')::timestamptz,
            (f->>'fecha_picking_inicio')::timestamptz, (f->>'fecha_picking_fin')::timestamptz,
            (f->>'fecha_despacho')::timestamptz, (f->>'fecha_cancelado')::timestamptz)
        on conflict (pais, doc_type, doc_num) do update set
            cliente_nombre       = coalesce(excluded.cliente_nombre,   p.cliente_nombre),
            celular_original     = coalesce(excluded.celular_original, p.celular_original),
            celular_e164         = coalesce(excluded.celular_e164,     p.celular_e164),
            notificable          = excluded.notificable,
            vendedor_nombre      = coalesce(excluded.vendedor_nombre,  p.vendedor_nombre),
            vendedor_email       = coalesce(excluded.vendedor_email,   p.vendedor_email),
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

        v_estado := case
            when despues.fecha_despacho       is not null then 'DESPACHADO'
            when despues.fecha_cancelado      is not null then 'CANCELADO'
            when despues.fecha_picking_fin    is not null then 'PICKING_COMPLETADO'
            when despues.fecha_picking_inicio is not null then 'PICKING_INICIADO'
            when despues.fecha_planificado    is not null then 'PLANIFICADO'
            when despues.confirmacion = 'confirmado'     then 'CONFIRMADO_CLIENTE'
            else 'RECIBIDO' end;

        update notif.pedido set
            estado       = v_estado,
            fecha_estado = case v_estado
                when 'DESPACHADO'         then despues.fecha_despacho
                when 'CANCELADO'          then despues.fecha_cancelado
                when 'PICKING_COMPLETADO' then despues.fecha_picking_fin
                when 'PICKING_INICIADO'   then despues.fecha_picking_inicio
                when 'PLANIFICADO'        then despues.fecha_planificado
                when 'CONFIRMADO_CLIENTE' then despues.fecha_confirmacion
                else despues.fecha_recibido end
         where pais = despues.pais and doc_type = despues.doc_type and doc_num = despues.doc_num;

        cuadro_f := coalesce(despues.cuadro_actual, 0);
        insert into notif.evento (pais, doc_type, doc_num, evento, cuadro, ocurrido_en, envio_estado)
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

-- registrar_confirmacion: si pasa a CONFIRMADO_CLIENTE, actualiza fecha_estado
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
        fecha_confirmacion    = now(),
        fecha_estado = case when estado = 'RECIBIDO' and p_respuesta = 'confirmado'
                            then now() else fecha_estado end,
        estado = case when estado = 'RECIBIDO' and p_respuesta = 'confirmado'
                      then 'CONFIRMADO_CLIENTE' else estado end,
        actualizado_en        = now()
    where pais = p_pais and doc_type = 'OV' and doc_num = p_doc_num;
end $$;

-- Vista para n8n: pedidos activos (no despachados ni cancelados) y los que
-- cerraron en los últimos 7 días. Una fila por pedido.
create or replace view notif.v_pedidos_activos as
select p.pais,
       p.doc_num                                   as numero_pedido,
       p.cliente_nombre,
       p.celular_e164                              as celular,
       p.notificable,
       p.vendedor_nombre,
       p.vendedor_email,
       p.direccion,
       p.fecha_entrega,
       p.fecha_entrega_cliente,                    -- si el cliente pidió reprogramar
       p.estado,
       c.nombre                                    as estado_descripcion,
       p.fecha_estado                              as fecha_ultimo_cambio,
       p.confirmacion,
       p.cuadro_actual                             as cuadro_ruta,
       p.placa,
       -- historial de fechas por estatus
       p.fecha_recibido,
       p.fecha_confirmacion,
       p.fecha_planificado,
       p.fecha_picking_inicio,
       p.fecha_picking_fin,
       p.fecha_despacho,
       p.fecha_cancelado
from notif.pedido p
join notif.estado_catalogo c on c.codigo = p.estado
where p.estado not in ('DESPACHADO', 'CANCELADO')
   or p.fecha_estado >= now() - interval '7 days';

-- tomar_avisos y v_avisos_pendientes: + vendedor (útil para el mensaje)
-- (se recrean juntas porque la función devuelve el tipo de la vista)
drop function if exists notif.tomar_avisos(integer);
drop view if exists notif.v_avisos_pendientes;

create view notif.v_avisos_pendientes as
select e.id, e.evento, c.plantilla_wa, e.cuadro, e.ocurrido_en,
       p.pais, p.doc_num, p.cliente_nombre, p.celular_e164, p.direccion,
       coalesce(p.fecha_entrega_cliente, p.fecha_entrega) as fecha_entrega,
       p.centro, p.placa, p.vendedor_nombre, p.vendedor_email
from notif.evento e
join notif.pedido p using (pais, doc_type, doc_num)
join notif.estado_catalogo c on c.codigo = e.evento
where e.envio_estado = 'pendiente'
  and c.notifica
  and p.notificable;

create function notif.tomar_avisos(p_limite integer default 50)
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
           p.centro, p.placa, p.vendedor_nombre, p.vendedor_email
    from tomados t
    join notif.evento e on e.id = t.id
    join notif.pedido p using (pais, doc_type, doc_num)
    join notif.estado_catalogo c on c.codigo = e.evento;
$$;

-- Permisos (create or replace conserva los grants; lo recreado los pierde)
revoke execute on all functions in schema notif from public, anon, authenticated;
grant execute on function notif.upsert_pedidos(jsonb, boolean) to service_role;
do $$
begin
    if exists (select 1 from pg_roles where rolname = 'notif_n8n') then
        grant select on notif.v_avisos_pendientes, notif.v_pedidos_activos to notif_n8n;
        grant execute on function notif.tomar_avisos(integer) to notif_n8n;
    end if;
end $$;
