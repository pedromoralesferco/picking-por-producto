-- ════════════════════════════════════════════════════════════════════
-- Prueba de humo del esquema notif. Correr en el SQL Editor después de
-- notif_01_schema.sql. Usa un pedido ficticio (país 'ZZ') y lo borra al
-- final. Si algo falla, el bloque completo se revierte y el error dice qué.
-- Resultado esperado: una fila con "OK - todas las pruebas pasaron".
-- ════════════════════════════════════════════════════════════════════

do $$
declare
    r  record;
    k  integer;
begin
    -- 1) Pedido nuevo (RECIBIDO) -> 1 aviso pendiente
    perform notif.upsert_pedidos(jsonb_build_array(jsonb_build_object(
        'pais','ZZ','doc_num',1,'cliente_nombre','Cliente Prueba',
        'celular_original','5555-0000','celular_e164','+50255550000','notificable',true,
        'direccion','Dirección de prueba','fecha_entrega', current_date + 1,
        'fecha_recibido', now())));
    select estado into r from notif.pedido where pais='ZZ' and doc_num=1;
    assert r.estado = 'RECIBIDO', 'paso 1: estado debía ser RECIBIDO y es ' || r.estado;
    select count(*) into k from notif.evento where pais='ZZ' and evento='RECIBIDO' and envio_estado='pendiente';
    assert k = 1, 'paso 1: debía haber 1 aviso RECIBIDO pendiente';

    -- 2) Mismo envío otra vez -> no duplica avisos
    perform notif.upsert_pedidos(jsonb_build_array(jsonb_build_object(
        'pais','ZZ','doc_num',1,'celular_e164','+50255550000','notificable',true,
        'fecha_recibido', now() - interval '1 minute')));
    select count(*) into k from notif.evento where pais='ZZ';
    assert k = 1, 'paso 2: se duplicó el aviso RECIBIDO';

    -- 3) Entra a cuadro (PLANIFICADO) + picking iniciado hace 2 días (viejo -> omitido)
    perform notif.upsert_pedidos(jsonb_build_array(jsonb_build_object(
        'pais','ZZ','doc_num',1,'celular_e164','+50255550000','notificable',true,
        'cuadro_actual', 12345,
        'fecha_planificado', now(),
        'fecha_picking_inicio', now() - interval '2 days')));
    select estado into r from notif.pedido where pais='ZZ' and doc_num=1;
    assert r.estado = 'PICKING_INICIADO', 'paso 3: estado debía ser PICKING_INICIADO y es ' || r.estado;
    select count(*) into k from notif.evento where pais='ZZ' and evento='PICKING_INICIADO' and envio_estado='omitido';
    assert k = 1, 'paso 3: el aviso viejo de picking debía quedar omitido';

    -- 4) n8n reserva avisos: 2 la primera vez (RECIBIDO, PLANIFICADO), 0 la segunda
    select count(*) into k from notif.tomar_avisos(10) t where t.pais='ZZ';
    assert k = 2, 'paso 4: tomar_avisos debía devolver 2 y devolvió ' || k;
    select count(*) into k from notif.tomar_avisos(10) t where t.pais='ZZ';
    assert k = 0, 'paso 4: la segunda reserva debía devolver 0 (no repetir avisos)';

    -- 5) Marcar enviado
    for r in select id from notif.evento where pais='ZZ' and envio_estado='enviando' loop
        perform notif.marcar_envio(r.id, 'enviado', 'wamid.prueba');
    end loop;
    select count(*) into k from notif.evento where pais='ZZ' and envio_estado='enviado';
    assert k = 2, 'paso 5: debían quedar 2 avisos enviados';

    -- 6) Respuesta del cliente: se encuentra el pedido por el mensaje citado
    select count(*) into k from notif.pedidos_por_respuesta('wamid.prueba', null) where pais='ZZ';
    assert k = 1, 'paso 6: no se encontró el pedido por wa_message_id';
    perform notif.registrar_confirmacion('ZZ', 1, 'rechazado', null, 'prueba');
    select estado, confirmacion into r from notif.pedido where pais='ZZ' and doc_num=1;
    assert r.confirmacion = 'rechazado' and r.estado = 'PICKING_INICIADO',
        'paso 6: un rechazo no debe cambiar el estado';

    -- 7) Despacho -> DESPACHADO y su aviso
    perform notif.upsert_pedidos(jsonb_build_array(jsonb_build_object(
        'pais','ZZ','doc_num',1,'celular_e164','+50255550000','notificable',true,
        'fecha_picking_fin', now(), 'fecha_despacho', now(), 'placa','P000TEST')));
    select estado into r from notif.pedido where pais='ZZ' and doc_num=1;
    assert r.estado = 'DESPACHADO', 'paso 7: estado debía ser DESPACHADO y es ' || r.estado;

    -- Limpieza
    delete from notif.evento where pais='ZZ';
    delete from notif.pedido where pais='ZZ';
end $$;

select 'OK - todas las pruebas pasaron' as resultado;
