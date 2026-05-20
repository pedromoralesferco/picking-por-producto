const express = require('express');
const path = require('path');
const session = require('express-session');
const helmet = require('helmet');
require('dotenv').config();

const db = require('./db');
const apiRoutes = require('./routes/api');
const authRoutes = require('./routes/auth');
const adminRoutes = require('./routes/admin');
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
app.use('/api', apiRoutes);

// Protected page routes
app.get('/dashboard', requireAuthPage, (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'dashboard.html'));
});

app.get('/gestion', requireAuthPage, requirePermisoPage('gestion'), (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'gestion.html'));
});

app.get('/priorizacion', requireAuthPage, requirePermisoPage('priorizacion'), (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'priorizacion.html'));
});

app.get('/admin', requireAdminPage, (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'admin.html'));
});

// Picker page stays public (no auth)
app.get('/picker', (req, res) => {
    res.sendFile(path.join(__dirname, 'public', 'picker.html'));
});

async function start() {
    await db.connect();
    app.listen(PORT, () => {
        console.log(`Picking por Producto running on http://localhost:${PORT}`);
    });
}

start().catch(console.error);
