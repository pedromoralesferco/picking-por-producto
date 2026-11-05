const express = require('express');
const http = require('http');
const path = require('path');
const session = require('express-session');
const helmet = require('helmet');
require('dotenv').config();

const db = require('./db');
const apiRoutes = require('./routes/api');
const orderApiRoutes = require('./routes/order-api');
const authRoutes = require('./routes/auth');
const adminRoutes = require('./routes/admin');
const wmsApiRoutes = require('./routes/wms-api');
const { requireAuthPage, requireAdminPage, requirePermisoPage } = require('./middleware/auth');

const app = express();
const PORT = process.env.PORT || 3001;

// Security headers
app.use(helmet({
    contentSecurityPolicy: false  // Desactivar CSP para no romper CDN de Bootstrap Icons
}));

// Trust proxy (para que rate-limit funcione con IIS reverse proxy)
app.set('trust proxy', 1);

// Conector de Planificación (MCP): el FortiGate manda el HTTPS directo a Node, así que
// Node reenvía /mcp y el descubrimiento OAuth al servicio MCP (proceso aparte, puerto 3002).
// Va ANTES de express.json() para pasar el cuerpo tal cual (stream) y no consumirlo aquí.
const MCP_UPSTREAM = new URL(process.env.MCP_UPSTREAM || 'http://localhost:3002');
function proxyMcp(req, res) {
    const headers = { ...req.headers, host: MCP_UPSTREAM.host };
    const up = http.request({ hostname: MCP_UPSTREAM.hostname, port: MCP_UPSTREAM.port || 80, method: req.method, path: req.originalUrl, headers }, (r) => {
        res.writeHead(r.statusCode, r.headers);
        r.pipe(res);
    });
    up.on('error', (err) => {
        console.error('AVISO: proxy MCP no disponible:', err.message);
        if (!res.headersSent) res.status(502).json({ error: 'Servicio de planificación (MCP) no disponible' });
    });
    req.pipe(up);
}
app.all(['/mcp', '/.well-known/oauth-protected-resource', '/.well-known/oauth-protected-resource/mcp'], proxyMcp);

app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Session middleware - BEFORE routes
app.use(session({
    secret: 'ferco-picking-2026',
    resave: false,
    saveUninitialized: false,
    cookie: { maxAge: 8 * 60 * 60 * 1000 } // 8 hours
}));

// Home page (public)
app.get('/', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'home.html'));
});

// Login page (public)
app.get('/login', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'login.html'));
});

// Static files (public)
// Cache-Control: no-cache en JS/CSS/HTML → el navegador SIEMPRE revalida con ETag
// (304 si no cambió, versión fresca si cambió). Evita servir código viejo tras un deploy.
app.use(express.static(path.join(__dirname, 'public'), {
    index: false,
    etag: true,
    setHeaders: (res, filePath) => {
        if (/\.(js|css|html)$/i.test(filePath)) {
            res.setHeader('Cache-Control', 'no-cache');
        }
    }
}));

// Páginas HTML servidas por sendFile (gestión, dashboard, etc.): revalidar siempre
app.use((req, res, next) => {
    if (req.method === 'GET' && !req.path.startsWith('/api/')) {
        res.setHeader('Cache-Control', 'no-cache');
    }
    next();
});

// API routes
app.use('/api/auth', authRoutes);
app.use('/api/admin', adminRoutes);
app.use('/api/order', orderApiRoutes);
app.use('/api/wms', wmsApiRoutes);

// Planificador (blindado): si su módulo falla al cargar (p.ej. un archivo
// bajó incompleto en un deploy), se desactiva SOLO el planificador y el
// resto de la app arranca normal — no tumba todo el servidor.
try {
    const planificadorApiRoutes = require('./routes/planificador-api');
    app.use('/api/planificador', planificadorApiRoutes);
    app.get('/planificador', requireAuthPage, requireCentro, requirePermisoPage('planificador'), (req, res) => {
        res.sendFile(path.join(__dirname, 'public', 'planificador.html'));
    });
    console.log('Modulo Planificador cargado.');
} catch (err) {
    console.error('AVISO: Planificador deshabilitado (fallo al cargar el modulo):', err.message);
}

// Reportes / Plan de Despachos (blindado, igual que el Planificador): si el
// módulo falla al cargar, se desactiva SOLO Reportes y el resto arranca normal.
try {
    const reportesApiRoutes = require('./routes/reportes-api');
    app.use('/api/reportes', reportesApiRoutes);
    app.get('/plan-despachos', requireAuthPage, requireCentro, (req, res) => {
        const u = req.session.user;
        const ok = u.rol === 'Admin' || (u.permisos && (u.permisos.includes('reportes') || u.permisos.includes('reportes_operativo') || u.permisos.includes('reportes_comercial')));
        if (!ok) return res.redirect('/dashboard');
        res.sendFile(path.join(__dirname, 'public', 'plan-despachos.html'));
    });
    console.log('Modulo Reportes (Plan de Despachos) cargado.');
} catch (err) {
    console.error('AVISO: Reportes deshabilitado (fallo al cargar el modulo):', err.message);
}

// CRUD de cuadros de ruta (blindado): pivoteo en carril (editar líneas, placa).
try {
    const cuadroCrudRoutes = require('./routes/cuadro-crud-api');
    app.use('/api/cuadro', cuadroCrudRoutes);
    console.log('Modulo CRUD de cuadros cargado.');
} catch (err) {
    console.error('AVISO: CRUD de cuadros deshabilitado (fallo al cargar el modulo):', err.message);
}

// Escalamientos (blindado): tickets de OV/TR a escalar en picking/despacho.
try {
    const escalamientosApiRoutes = require('./routes/escalamientos-api');
    app.use('/api/escalamientos', escalamientosApiRoutes);
    app.get('/escalamientos', requireAuthPage, requireCentro, (req, res) => {
        const u = req.session.user;
        const ok = u.rol === 'Admin' || (u.permisos && (u.permisos.includes('reportes') || u.permisos.includes('reportes_operativo') || u.permisos.includes('priorizacion')));
        if (!ok) return res.redirect('/dashboard');
        res.sendFile(path.join(__dirname, 'public', 'escalamientos.html'));
    });
    console.log('Modulo Escalamientos cargado.');
} catch (err) {
    console.error('AVISO: Escalamientos deshabilitado (fallo al cargar el modulo):', err.message);
}

// Planificación (conector MCP "Ferco Planificación", blindado): API de lectura
// autenticada por pase (Bearer de Supabase Auth), no por sesión.
try {
    const planificacionApiRoutes = require('./routes/planificacion-api');
    app.use('/api/planificacion', planificacionApiRoutes);
    console.log('Modulo Planificacion (MCP) cargado.');
} catch (err) {
    console.error('AVISO: Planificacion (MCP) deshabilitada (fallo al cargar el modulo):', err.message);
}

app.use('/api', apiRoutes);

// Centro selection page
app.get('/select-centro', requireAuthPage, (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'select-centro.html'));
});

// Middleware: require centro selected (redirects to selection if not)
function requireCentro(req, res, next) {
    if (!req.session || !req.session.user) {
        return res.redirect('/login');
    }
    // If user has multiple centros and hasn't selected one, redirect
    const user = req.session.user;
    if (!user.selectedCentro && user.centros && user.centros.length > 1) {
        return res.redirect('/select-centro');
    }
    next();
}

// Protected page routes
app.get('/dashboard', requireAuthPage, requireCentro, (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'dashboard.html'));
});

app.get('/gestion', requireAuthPage, requireCentro, requirePermisoPage('gestion'), (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'gestion.html'));
});

// HUB Escuintla (ID_Centro=3) prioriza desde gestión de rutas (inline), no con drag-drop.
const CENTRO_ESCUINTLA = 3;
app.get('/priorizacion', requireAuthPage, requireCentro, requirePermisoPage('priorizacion'), (req, res) => {
    if (req.session.user.selectedCentro === CENTRO_ESCUINTLA) {
        return res.redirect('/gestion');
    }
    res.sendFile(path.join(__dirname, 'public', 'priorizacion.html'));
});

app.get('/despacho', requireAuthPage, requireCentro, requirePermisoPage('despacho'), (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'despacho.html'));
});

app.get('/pase-salida', requireAuthPage, requireCentro, requirePermisoPage('pase-salida'), (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'pase-salida.html'));
});

app.get('/admin', requireAdminPage, (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});

// Picker page stays public (no auth)
app.get('/picker', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'picker.html'));
});

// ── WMS Pages ──
app.get('/wms', requireAuthPage, requireCentro, requirePermisoPage('wms_picking'), (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'wms', 'dashboard.html'));
});
app.get('/wms/picking', requireAuthPage, requireCentro, requirePermisoPage('wms_picking'), (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'wms', 'picking.html'));
});
app.get('/wms/ingreso', requireAuthPage, requireCentro, requirePermisoPage('wms_ingreso'), (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'wms', 'ingreso.html'));
});
app.get('/wms/traslados', requireAuthPage, requireCentro, requirePermisoPage('wms_traslados'), (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'wms', 'traslados.html'));
});
app.get('/wms/config', requireAuthPage, requireCentro, requirePermisoPage('wms_config'), (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'wms', 'config.html'));
});
app.get('/wms/stock', requireAuthPage, requireCentro, requirePermisoPage('wms_picking'), (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'wms', 'stock.html'));
});
app.get('/wms/integracion', requireAuthPage, requireCentro, requirePermisoPage('wms_config'), (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'wms', 'integracion.html'));
});

// Reconciliador de ediciones de cuadro (Fase 3): cuando el robot/PA marcan una
// edición como 'confirmado' en SAP, limpia los flags *Pendiente* y cierra la fila.
// Blindado: cualquier fallo se loguea y no afecta al resto. NO escribe a SAP.
function startCuadroSyncReconciler() {
    const tick = async () => {
        try { await db.getPool().request().execute('SP_ReconcileCuadroEdiciones'); }
        catch (err) { console.error('AVISO: reconciliador de ediciones de cuadro falló este ciclo:', err.message); }
    };
    setInterval(tick, 60 * 1000);
    tick();
}

// Captura de bultos (licencias destino del picking) para el montacarguista.
// Lee el log de picking de Lisa y persiste el enlace OV↔Licencia en DespachoBulto.
// Blindado: cualquier fallo se loguea y no afecta al resto. NO escribe a Lisa/SAP.
function startBultoCapture() {
    const tick = async () => {
        try { await db.getPool().request().execute('SP_CaptureBultosEscuintla'); }
        catch (err) { console.error('AVISO: captura de bultos falló este ciclo:', err.message); }
    };
    setInterval(tick, 120 * 1000);
    tick();
}

// Snapshot del backlog sin cuadro para el conector de Planificación (MCP): corre
// SP_MCP_BacklogSinCuadro por cada centro con ConfigPlanDiario. Tarda ~1 min por
// centro (lee SAP y Lisa por linked server), por eso va en el pool de jobs.
// Blindado: cualquier fallo se loguea y no afecta al resto. NO escribe a SAP/Lisa.
function startBacklogSnapshot() {
    let corriendo = false;
    const tick = async () => {
        if (corriendo) return;
        corriendo = true;
        try {
            const pool = await db.getJobPool();
            const centros = await pool.request().query('SELECT ID_Centro FROM ConfigPlanDiario');
            for (const c of centros.recordset) {
                try { await pool.request().input('ID_Centro', db.sql.Int, c.ID_Centro).execute('SP_MCP_BacklogSinCuadro'); }
                catch (err) { console.error(`AVISO: snapshot del backlog (centro ${c.ID_Centro}) falló este ciclo:`, err.message); }
            }
        } catch (err) { console.error('AVISO: snapshot del backlog falló este ciclo:', err.message); }
        finally { corriendo = false; }
    };
    setInterval(tick, 15 * 60 * 1000);
    setTimeout(tick, 20 * 1000); // no competir con el arranque
}

// Puertos:
//  PORT          → app completa (producción: 8081, donde el FortiGate manda el HTTPS 8443)
//  PORT_ALT      → segundo puerto con la app completa (para migrar sin corte: 8080 y 8081 a la vez)
//  REDIRECT_PORT → puerto que SOLO redirige (301) a REDIRECT_TO conservando la ruta, para que el
//                  link viejo http://picking.ferco.com.gt:8080 siga funcionando y lleve al HTTPS.
//                  El FortiGate no redirige en estos puertos; por eso lo hace la app.
const PORT_ALT = process.env.PORT_ALT;
const REDIRECT_PORT = process.env.REDIRECT_PORT;
const REDIRECT_TO = (process.env.REDIRECT_TO || '').replace(/\/$/, '');

async function start() {
    await db.connect();
    app.listen(PORT, () => {
        console.log(`Picking por Producto running on http://localhost:${PORT}`);
        startCuadroSyncReconciler();
        console.log('Reconciliador de ediciones de cuadro activo (60s).');
        startBultoCapture();
        console.log('Captura de bultos (licencias) activa (120s).');
        startBacklogSnapshot();
        console.log('Snapshot del backlog de planificacion activo (15 min).');
    });
    if (PORT_ALT && String(PORT_ALT) !== String(PORT)) {
        app.listen(PORT_ALT, () => console.log(`Picking por Producto tambien en http://localhost:${PORT_ALT} (PORT_ALT)`));
    }
    if (REDIRECT_PORT && REDIRECT_TO && String(REDIRECT_PORT) !== String(PORT) && String(REDIRECT_PORT) !== String(PORT_ALT)) {
        const redirectApp = express();
        redirectApp.use((req, res) => res.redirect(301, REDIRECT_TO + req.originalUrl));
        redirectApp.listen(REDIRECT_PORT, () => console.log(`Redirect 301 ${REDIRECT_PORT} -> ${REDIRECT_TO} activo.`));
    } else if (REDIRECT_PORT) {
        console.error('AVISO: REDIRECT_PORT ignorado (falta REDIRECT_TO o coincide con PORT/PORT_ALT).');
    }
}

start().catch(console.error);
