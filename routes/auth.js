const express = require('express');
const bcrypt = require('bcryptjs');
const { getPool, sql } = require('../db');
const router = express.Router();

// POST /api/auth/login
router.post('/login', async (req, res) => {
    try {
        const { usuario, password } = req.body;
        if (!usuario || !password) {
            return res.status(400).json({ error: 'Usuario y contraseña requeridos' });
        }

        const pool = getPool();
        const result = await pool.request()
            .input('usuario', sql.NVarChar, usuario)
            .query(`
                SELECT ID_Usuario, NombreUsuario, Nombre, PasswordHash, Rol, Activo
                FROM Usuario
                WHERE NombreUsuario = @usuario
            `);

        if (result.recordset.length === 0) {
            return res.status(401).json({ error: 'Usuario o contraseña incorrectos' });
        }

        const user = result.recordset[0];

        if (!user.Activo) {
            return res.status(401).json({ error: 'Usuario desactivado' });
        }

        const valid = await bcrypt.compare(password, user.PasswordHash);
        if (!valid) {
            return res.status(401).json({ error: 'Usuario o contraseña incorrectos' });
        }

        // Get permisos
        let permisos = [];
        if (user.Rol === 'Admin') {
            permisos = ['priorizacion', 'gestion'];
        } else {
            const permResult = await pool.request()
                .input('userId', sql.Int, user.ID_Usuario)
                .query(`SELECT Modulo FROM UsuarioPermiso WHERE ID_Usuario = @userId`);
            permisos = permResult.recordset.map(r => r.Modulo);
        }

        req.session.user = {
            id: user.ID_Usuario,
            nombreUsuario: user.NombreUsuario,
            nombre: user.Nombre,
            rol: user.Rol,
            permisos
        };

        res.json({
            ok: true,
            user: {
                nombre: user.Nombre,
                rol: user.Rol,
                permisos
            }
        });
    } catch (err) {
        console.error('POST /api/auth/login error:', err);
        res.status(500).json({ error: 'Error interno del servidor' });
    }
});

// POST /api/auth/logout
router.post('/logout', (req, res) => {
    req.session.destroy(() => {
        res.json({ ok: true });
    });
});

// GET /api/auth/me
router.get('/me', (req, res) => {
    if (!req.session || !req.session.user) {
        return res.status(401).json({ error: 'No autenticado' });
    }
    res.json(req.session.user);
});

// GET /api/auth/setup - Bootstrap first admin (only works if no users exist)
router.get('/setup', async (req, res) => {
    try {
        const pool = getPool();
        const check = await pool.request().query(`SELECT COUNT(*) AS total FROM Usuario`);
        if (check.recordset[0].total > 0) {
            return res.status(400).json({ error: 'Ya existen usuarios. Setup no disponible.' });
        }

        const hash = await bcrypt.hash('admin123', 10);
        await pool.request()
            .input('nombre', sql.NVarChar, 'Administrador')
            .input('usuario', sql.NVarChar, 'admin')
            .input('hash', sql.NVarChar, hash)
            .query(`
                INSERT INTO Usuario (NombreUsuario, Nombre, PasswordHash, Rol, Activo, FechaCreacion)
                VALUES (@usuario, @nombre, @hash, 'Admin', 1, GETDATE())
            `);

        res.json({ ok: true, message: 'Admin creado: usuario=admin, password=admin123' });
    } catch (err) {
        console.error('GET /api/auth/setup error:', err);
        res.status(500).json({ error: 'Error al crear admin inicial' });
    }
});

module.exports = router;
