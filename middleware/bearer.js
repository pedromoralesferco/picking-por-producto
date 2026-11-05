// Autenticación por pase (Bearer) para /api/planificacion.
// La usa el conector MCP "Ferco Planificación": el MCP no tiene credenciales,
// solo reenvía el pase que Supabase Auth (login con Microsoft) le dio a Claude.
// Aquí se verifica el pase, se saca el correo y se busca el usuario del app;
// el acceso es el módulo 'planificacion' de UsuarioPermiso (o rol Admin).
const { createRemoteJWKSet, createLocalJWKSet, jwtVerify } = require('jose');
const { getPool, sql } = require('../db');

const MODULO = 'planificacion';
const SUPABASE_URL = (process.env.PLAN_SUPABASE_URL || '').replace(/\/$/, '');
const ISSUER = process.env.PLAN_JWT_ISSUER || (SUPABASE_URL ? `${SUPABASE_URL}/auth/v1` : null);
// Si se define, solo se aceptan pases emitidos para estos clientes OAuth (el conector de Planificación).
const CLIENTES = (process.env.PLAN_ALLOWED_CLIENT_IDS || '').split(',').map(s => s.trim()).filter(Boolean);

let jwks = null;
function getJwks() {
    if (jwks) return jwks;
    // PLAN_JWKS_JSON: llaves públicas locales, SOLO para pruebas en desarrollo. Exige el
    // flag explícito PLAN_DEV_LOCAL_JWKS=1 además de no estar en producción: nunca copiar
    // estas variables al .env del servidor.
    if (process.env.PLAN_DEV_LOCAL_JWKS === '1' && process.env.PLAN_JWKS_JSON && process.env.NODE_ENV !== 'production') {
        jwks = createLocalJWKSet(JSON.parse(process.env.PLAN_JWKS_JSON));
    } else if (SUPABASE_URL) {
        jwks = createRemoteJWKSet(new URL(`${SUPABASE_URL}/auth/v1/.well-known/jwks.json`));
    }
    return jwks;
}

// El access token de OAuth de Supabase puede no traer el correo; viene en userinfo.
async function emailDesdeUserinfo(token) {
    if (!SUPABASE_URL || !process.env.PLAN_SUPABASE_ANON_KEY) return null;
    try {
        const r = await fetch(`${SUPABASE_URL}/auth/v1/oauth/userinfo`, {
            headers: { Authorization: `Bearer ${token}`, apikey: process.env.PLAN_SUPABASE_ANON_KEY }
        });
        if (!r.ok) return null;
        const info = await r.json();
        return info.email || null;
    } catch (e) {
        console.error('planificacion auth userinfo:', e.message);
        return null;
    }
}

async function cargarUsuario(email) {
    const pool = getPool();
    const u = await pool.request().input('email', sql.NVarChar, email).query(`
        SELECT ID_Usuario, NombreUsuario, Nombre, Rol, Email
        FROM Usuario WHERE Activo = 1 AND LOWER(Email) = LOWER(@email)`);
    if (!u.recordset.length) return null;
    const user = u.recordset[0];
    const esAdmin = user.Rol === 'Admin';
    const perm = await pool.request().input('id', sql.Int, user.ID_Usuario)
        .query(`SELECT Modulo FROM UsuarioPermiso WHERE ID_Usuario = @id`);
    const cen = esAdmin
        ? await pool.request().query(`SELECT ID_Centro, Pais, Codigo FROM CentroDistribucion`)
        : await pool.request().input('id', sql.Int, user.ID_Usuario).query(`
            SELECT c.ID_Centro, c.Pais, c.Codigo
            FROM UsuarioCentro uc JOIN CentroDistribucion c ON c.ID_Centro = uc.ID_Centro
            WHERE uc.ID_Usuario = @id`);
    return {
        id: user.ID_Usuario,
        usuario: user.NombreUsuario,
        nombre: user.Nombre,
        email: user.Email,
        rol: user.Rol,
        permisos: perm.recordset.map(r => r.Modulo),
        centros: cen.recordset.map(r => ({ id: r.ID_Centro, pais: r.Pais || 'GT', codigo: r.Codigo }))
    };
}

// Cache corto por pase: evita consultar userinfo y la BD en cada llamada del MCP.
const cache = new Map();
const CACHE_MS = 60 * 1000;

async function requireBearer(req, res, next) {
    const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '').trim();
    if (!token) return res.status(401).json({ error: 'Falta el pase de acceso' });

    const hit = cache.get(token);
    if (hit && hit.hasta > Date.now()) { req.planUser = hit.user; return next(); }

    const keys = getJwks();
    if (!keys) {
        console.error('planificacion auth: falta PLAN_SUPABASE_URL (o PLAN_JWKS_JSON en desarrollo)');
        return res.status(503).json({ error: 'Autenticación de planificación no configurada' });
    }
    let payload;
    try {
        ({ payload } = await jwtVerify(token, keys, ISSUER ? { issuer: ISSUER } : {}));
    } catch (e) {
        return res.status(401).json({ error: 'Pase inválido o vencido' });
    }
    if (CLIENTES.length && !CLIENTES.includes(payload.client_id)) {
        return res.status(401).json({ error: 'Pase emitido para otro conector' });
    }

    const meta = payload.user_metadata || {};
    const email = payload.email || meta.email || await emailDesdeUserinfo(token);
    if (!email) return res.status(401).json({ error: 'El pase no trae el correo del usuario' });

    let user;
    try {
        user = await cargarUsuario(email);
    } catch (e) {
        console.error('planificacion auth cargarUsuario:', e.message);
        return res.status(500).json({ error: 'Error al validar el usuario' });
    }
    const tieneAcceso = user && (user.rol === 'Admin' || user.permisos.includes(MODULO));
    if (!tieneAcceso) {
        req.planEmail = email; // para la auditoría del rechazo
        return res.status(403).json({ error: 'Sin acceso al conector de planificación. Pide a un admin del app de Picking que te marque "Planificación con Claude".' });
    }

    const hasta = Math.min(Date.now() + CACHE_MS, (payload.exp || 0) * 1000);
    cache.set(token, { user, hasta });
    if (cache.size > 500) cache.delete(cache.keys().next().value);
    req.planUser = user;
    next();
}

module.exports = { requireBearer, MODULO };
