-- notif_06 — la vista de pedidos activos muestra el almacén SAP (columna
-- "centro" de notif.pedido, ej. '138'). Se agrega al final para no romper
-- el orden de columnas que ya usa n8n.
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
       p.centro                                    as almacen
from notif.pedido p
join notif.estado_catalogo c on c.codigo = p.estado
where p.estado not in ('DESPACHADO', 'CANCELADO')
   or p.fecha_estado >= now() - interval '7 days';
