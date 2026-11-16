-- ════════════════════════════════════════════════════════════════════
-- Usuario de base de datos para n8n Cloud (nodo Postgres).
-- Correr en el SQL Editor DESPUÉS de notif_01_schema.sql.
--
-- ANTES DE CORRER: reemplazar CAMBIAR_ESTA_CLAVE por una contraseña larga
-- (sin comillas simples). No guardar el script con la clave puesta.
--
-- Qué puede hacer: leer la vista de pendientes y el catálogo, y ejecutar
-- tomar_avisos, marcar_envio, registrar_confirmacion y pedidos_por_respuesta.
-- No puede leer ni escribir las tablas directamente, ni ver nada fuera de notif.
--
-- Conexión en n8n (Credencial "Postgres"), usando el pooler de Supabase
-- (Project Settings → Database → Connection string → Session pooler):
--   Host:     el host del pooler, ej. aws-0-ca-central-1.pooler.supabase.com (el proyecto está en ca-central-1)
--   Port:     5432
--   Database: postgres
--   User:     notif_n8n.fhefwggpiumjtcnqixsb
--   Password: la que se ponga abajo
--   SSL:      require
-- ════════════════════════════════════════════════════════════════════

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'notif_n8n') then
        create role notif_n8n with login password 'CAMBIAR_ESTA_CLAVE';
    else
        alter role notif_n8n with login password 'CAMBIAR_ESTA_CLAVE';
    end if;
end $$;

-- Que solo vea el esquema notif
alter role notif_n8n set search_path = notif;
revoke all on schema public from notif_n8n;

grant usage on schema notif to notif_n8n;
grant select on notif.v_avisos_pendientes, notif.estado_catalogo to notif_n8n;
grant execute on function notif.tomar_avisos(integer)                                    to notif_n8n;
grant execute on function notif.marcar_envio(bigint, text, text, text)                   to notif_n8n;
grant execute on function notif.registrar_confirmacion(char, integer, text, date, text)  to notif_n8n;
grant execute on function notif.pedidos_por_respuesta(text, text)                        to notif_n8n;
