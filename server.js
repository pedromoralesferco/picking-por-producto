const express = require('express');
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
app.use(express.static(path.join(__dirname, 'public'), { index: false }));

// API routes
app.use('/api/auth', authRoutes);
app.use('/api/admin', adminRoutes);
app.use('/api/order', orderApiRoutes);
app.use('/api/wms', wmsApiRoutes);
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

app.get('/priorizacion', requireAuthPage, requireCentro, requirePermisoPage('priorizacion'), (req, res) => {
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

async function start() {
    await db.connect();
    app.listen(PORT, () => {
        console.log(`Picking por Producto running on http://localhost:${PORT}`);
    });
}

start().catch(console.error);
