-- ════════════════════════════════════════════════════════════════════
-- notif_07 — Pedido de Elena (n8n), 17-nov-2026:
--  * detalle del pedido: líneas del almacén (código, descripción,
--    cantidad, unidad), sin precios. jsonb en notif.pedido.detalle.
--  * condiciones de entrega desde la OV de SAP:
--      instrucciones_entrega  U_FE_InstEntrega
--      comentarios            Comments (texto libre de ventas: puede traer
--                             notas internas; n8n no debe mandarlo tal cual)
--      ton_max                U_FE_TonMax (toneladas máx. que pueden ingresar)
--      requiere_montacarga    U_FE_Montacarga (S/N)
--      requiere_cuadrilla     U_FE_Cuadrilla (S/N)
--      latitud / longitud     U_Latitud / U_Longitud
--      mapa_url               enlace de Google Maps (calculado)
-- Se agregan al final de las vistas para no mover las columnas existentes.
-- Se puede volver a correr.
-- ════════════════════════════════════════════════════════════════════

alter table notif.pedido add column if not exists instrucciones_entrega text;
alter table notif.pedido add column if not exists comentarios           text;
alter table notif.pedido add column if not exists ton_max               numeric(9,3);
alter table notif.pedido add column if not exists requiere_montacarga   boolean;
alter table notif.pedido add column if not exists requiere_cuadrilla    boolean;
alter table notif.pedido add column if not exists latitud               text;
alter table notif.pedido add column if not exists longitud              text;
alter table notif.pedido add column if not exists detalle               jsonb;
alter table notif.pedido add column if not exists mapa_url text generated always as (
    case when latitud  ~ '^\s*-?[0-9]{1,3}(\.[0-9]+)?\s*$'
          and longitud ~ '^\s*-?[0-9]{1,3}(\.[0-9]+)?\s*$'
         then 'https://www.google.com/maps?q=' || trim(latitud) || ',' || trim(longitud)
    end) stored;

-- upsert_pedidos: + condiciones y detalle (el resto igual que notif_05)
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
        est_ini := case when silencioso or coalesce((f->>'silencioso')::boolean, false) then 'omitido' else 'pendiente' end;
        select * into antes from notif.pedido
         where pais = f->>'pais' and doc_type = coalesce(f->>'doc_type','OV') and doc_num = (f->>'doc_num')::int
         for update;

        insert into notif.pedido as p (
            pais, doc_type, doc_num, estado,
            cliente_nombre, celular_original, celular_e164, notificable,
            vendedor_nombre, vendedor_email,
            direccion, fecha_entrega, centro, cuadro_actual, placa,
            instrucciones_entrega, comentarios, ton_max, requiere_montacarga, requiere_cuadrilla,
            latitud, longitud, detalle,
            fecha_recibido, fecha_planificado, fecha_picking_inicio,
            fecha_picking_fin, fecha_despacho, fecha_cancelado)
        values (
            f->>'pais', coalesce(f->>'doc_type','OV'), (f->>'doc_num')::int, 'RECIBIDO',
            f->>'cliente_nombre', f->>'celular_original', f->>'celular_e164',
            coalesce((f->>'notificable')::boolean, false),
            f->>'vendedor_nombre', f->>'vendedor_email',
            f->>'direccion', (f->>'fecha_entrega')::date, f->>'centro',
            (f->>'cuadro_actual')::int, f->>'placa',
            f->>'instrucciones_entrega', f->>'comentarios', (f->>'ton_max')::numeric,
            (f->>'requiere_montacarga')::boolean, (f->>'requiere_cuadrilla')::boolean,
            f->>'latitud', f->>'longitud', (f->>'detalle')::jsonb,
            (f->>'fecha_recibido')::timestamptz, (f->>'fecha_planificado')::timestamptz,
            (f->>'fecha_picking_inicio')::timestamptz, (f->>'fecha_picking_fin')::timestamptz,
            (f->>'fecha_despacho')::timestamptz, (f->>'fecha_cancelado')::timestamptz)
        on conflict (pais, doc_type, doc_num) do update set
            cliente_nombre        = coalesce(excluded.cliente_nombre,   p.cliente_nombre),
            celular_original      = coalesce(excluded.celular_original, p.celular_original),
            celular_e164          = coalesce(excluded.celular_e164,     p.celular_e164),
            notificable           = excluded.notificable,
            vendedor_nombre       = coalesce(excluded.vendedor_nombre,  p.vendedor_nombre),
            vendedor_email        = coalesce(excluded.vendedor_email,   p.vendedor_email),
            direccion             = coalesce(excluded.direccion,        p.direccion),
            fecha_entrega         = coalesce(excluded.fecha_entrega,    p.fecha_entrega),
            centro                = coalesce(excluded.centro,           p.centro),
            cuadro_actual         = coalesce(excluded.cuadro_actual,    p.cuadro_actual),
            placa                 = coalesce(excluded.placa,            p.placa),
            instrucciones_entrega = coalesce(excluded.instrucciones_entrega, p.instrucciones_entrega),
            comentarios           = coalesce(excluded.comentarios,      p.comentarios),
            ton_max               = coalesce(excluded.ton_max,          p.ton_max),
            requiere_montacarga   = coalesce(excluded.requiere_montacarga, p.requiere_montacarga),
            requiere_cuadrilla    = coalesce(excluded.requiere_cuadrilla,  p.requiere_cuadrilla),
            latitud               = coalesce(excluded.latitud,          p.latitud),
            longitud              = coalesce(excluded.longitud,         p.longitud),
            detalle               = coalesce(excluded.detalle,          p.detalle),
            fecha_recibido        = coalesce(p.fecha_recibido,       excluded.fecha_recibido),
            fecha_planificado     = coalesce(p.fecha_planificado,    excluded.fecha_planificado),
            fecha_picking_inicio  = coalesce(p.fecha_picking_inicio, excluded.fecha_picking_inicio),
            fecha_picking_fin     = coalesce(p.fecha_picking_fin,    excluded.fecha_picking_fin),
            fecha_despacho        = coalesce(p.fecha_despacho,       excluded.fecha_despacho),
            fecha_cancelado       = coalesce(p.fecha_cancelado,      excluded.fecha_cancelado),
            actualizado_en        = now()
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

-- Vista de pedidos activos: columnas nuevas al final
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
       p.fecha_entrega_cliente,
       p.estado,
       c.nombre                                    as estado_descripcion,
       p.fecha_estado                              as fecha_ultimo_cambio,
       p.confirmacion,
       p.cuadro_actual                             as cuadro_ruta,
       p.placa,
       p.fecha_recibido,
       p.fecha_confirmacion,
       p.fecha_planificado,
       p.fecha_picking_inicio,
       p.fecha_picking_fin,
       p.fecha_despacho,
       p.fecha_cancelado,
       p.centro                                    as almacen,
       p.detalle,
       p.instrucciones_entrega,
       p.comentarios,
       p.ton_max,
       p.requiere_montacarga,
       p.requiere_cuadrilla,
       p.mapa_url
from notif.pedido p
join notif.estado_catalogo c on c.codigo = p.estado
where p.estado not in ('DESPACHADO', 'CANCELADO')
   or p.fecha_estado >= now() - interval '7 days';

-- Avisos: columnas nuevas al final (vista y función se recrean juntas)
drop function if exists notif.tomar_avisos(integer);
drop view if exists notif.v_avisos_pendientes;

create view notif.v_avisos_pendientes as
select e.id, e.evento, c.plantilla_wa, e.cuadro, e.ocurrido_en,
       p.pais, p.doc_num, p.cliente_nombre, p.celular_e164, p.direccion,
       coalesce(p.fecha_entrega_cliente, p.fecha_entrega) as fecha_entrega,
       p.centro, p.placa, p.vendedor_nombre, p.vendedor_email,
       p.detalle, p.instrucciones_entrega, p.comentarios, p.ton_max,
       p.requiere_montacarga, p.requiere_cuadrilla, p.mapa_url
from notif.evento e
join notif.pedido p using (pais, doc_type, doc_num)
join notif.estado_catalogo c on c.codigo = e.evento
where e.envio_estado = 'pendiente'
  and e.ocurrido_en >= now() - interval '6 hours'
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
          and e.ocurrido_en >= now() - interval '6 hours'
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
           p.centro, p.placa, p.vendedor_nombre, p.vendedor_email,
           p.detalle, p.instrucciones_entrega, p.comentarios, p.ton_max,
           p.requiere_montacarga, p.requiere_cuadrilla, p.mapa_url
    from tomados t
    join notif.evento e on e.id = t.id
    join notif.pedido p using (pais, doc_type, doc_num)
    join notif.estado_catalogo c on c.codigo = e.evento;
$$;

revoke execute on all functions in schema notif from public, anon, authenticated;
grant execute on function notif.upsert_pedidos(jsonb, boolean) to service_role;
do $$
begin
    if exists (select 1 from pg_roles where rolname = 'notif_n8n') then
        grant select on notif.v_avisos_pendientes, notif.v_pedidos_activos to notif_n8n;
        grant execute on function notif.tomar_avisos(integer) to notif_n8n;
    end if;
end $$;
