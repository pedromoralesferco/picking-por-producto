const express = require('express');
const bcrypt = require('bcryptjs');
const { getPool, sql } = require('../db');
const { requireAdmin } = require('../middleware/auth');
const router = express.Router();

// All routes require Admin role
router.use(requireAdmin);

// ── Usuarios CRUD ──

// GET /api/admin/usuarios - List all users with permisos
router.get('/usuarios', async (req, res) => {
    try {
        const pool = getPool();
        const users = await pool.request().query(`
            SELECT u.ID_Usuario, u.NombreUsuario, u.Nombre, u.Rol, u.Activo, u.FechaCreacion
            FROM Usuario u
            ORDER BY u.Activo DESC, u.Nombre
        `);

        const permisos = await pool.request().query(`
            SELECT ID_Usuario, Modulo FROM UsuarioPermiso
        `);

        const permMap = {};
        for (const p of permisos.recordset) {
            if (!permMap[p.ID_Usuario]) permMap[p.ID_Usuario] = [];
            permMap[p.ID_Usuario].push(p.Modulo);
        }

        const result = users.recordset.map(u => ({
            ...u,
            permisos: permMap[u.ID_Usuario] || []
        }));

        res.json(result);
    } catch (err) {
        console.error('GET /api/admin/usuarios error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// POST /api/admin/usuarios - Create user
router.post('/usuarios', async (req, res) => {
    try {
        const { nombreUsuario, nombre, password, rol, permisos } = req.body;
        if (!nombreUsuario || !nombre || !password || !rol) {
            return res.status(400).json({ error: 'Campos requeridos: nombreUsuario, nombre, password, rol' });
        }

        const pool = getPool();

        // Check duplicate
        const dup = await pool.request()
            .input('usuario', sql.NVarChar, nombreUsuario)
            .query(`SELECT COUNT(*) AS c FROM Usuario WHERE NombreUsuario = @usuario`);
        if (dup.recordset[0].c > 0) {
            return res.status(400).json({ error: 'El nombre de usuario ya existe' });
        }

        const hash = await bcrypt.hash(password, 10);

        const result = await pool.request()
            .input('usuario', sql.NVarChar, nombreUsuario)
            .input('nombre', sql.NVarChar, nombre)
            .input('hash', sql.NVarChar, hash)
            .input('rol', sql.NVarChar, rol)
            .query(`
                INSERT INTO Usuario (NombreUsuario, Nombre, PasswordHash, Rol, Activo, FechaCreacion)
                OUTPUT INSERTED.ID_Usuario
                VALUES (@usuario, @nombre, @hash, @rol, 1, GETDATE())
            `);

        const userId = result.recordset[0].ID_Usuario;

        // Insert permisos
        if (permisos && permisos.length > 0 && rol !== 'Admin') {
            for (const modulo of permisos) {
                await pool.request()
                    .input('userId', sql.Int, userId)
                    .input('modulo', sql.NVarChar, modulo)
                    .query(`INSERT INTO UsuarioPermiso (ID_Usuario, Modulo) VALUES (@userId, @modulo)`);
            }
        }

        res.json({ ok: true, id: userId });
    } catch (err) {
        console.error('POST /api/admin/usuarios error:', err);
        res.status(500).json({ error: 'Error al crear usuario' });
    }
});

// PUT /api/admin/usuarios/:id - Update user
router.put('/usuarios/:id', async (req, res) => {
    try {
        const id = parseInt(req.params.id);
        const { nombre, password, rol, permisos, activo } = req.body;
        const pool = getPool();

        let query = `UPDATE Usuario SET Nombre = @nombre, Rol = @rol`;
        const request = pool.request()
            .input('id', sql.Int, id)
            .input('nombre', sql.NVarChar, nombre)
            .input('rol', sql.NVarChar, rol);

        if (typeof activo !== 'undefined') {
            query += `, Activo = @activo`;
            request.input('activo', sql.Bit, activo ? 1 : 0);
        }

        if (password) {
            const hash = await bcrypt.hash(password, 10);
            query += `, PasswordHash = @hash`;
            request.input('hash', sql.NVarChar, hash);
        }

        query += ` WHERE ID_Usuario = @id`;
        await request.query(query);

        // Update permisos: delete old, insert new
        await pool.request()
            .input('id', sql.Int, id)
            .query(`DELETE FROM UsuarioPermiso WHERE ID_Usuario = @id`);

        if (permisos && permisos.length > 0 && rol !== 'Admin') {
            for (const modulo of permisos) {
                await pool.request()
                    .input('userId', sql.Int, id)
                    .input('modulo', sql.NVarChar, modulo)
                    .query(`INSERT INTO UsuarioPermiso (ID_Usuario, Modulo) VALUES (@userId, @modulo)`);
            }
        }

        res.json({ ok: true });
    } catch (err) {
        console.error('PUT /api/admin/usuarios/:id error:', err);
        res.status(500).json({ error: 'Error al actualizar usuario' });
    }
});

// DELETE /api/admin/usuarios/:id - Soft delete (Activo=0)
router.delete('/usuarios/:id', async (req, res) => {
    try {
        const id = parseInt(req.params.id);
        const pool = getPool();
        await pool.request()
            .input('id', sql.Int, id)
            .query(`UPDATE Usuario SET Activo = 0 WHERE ID_Usuario = @id`);
        res.json({ ok: true });
    } catch (err) {
        console.error('DELETE /api/admin/usuarios/:id error:', err);
        res.status(500).json({ error: 'Error al desactivar usuario' });
    }
});

// ── Pickers CRUD ──

// GET /api/admin/pickers - List all pickers
router.get('/pickers', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
            SELECT p.ID_Picker, p.Nombre, p.ID_Centro, p.Activo,
                   cd.Nombre AS CentroNombre
            FROM Picker p
            LEFT JOIN CentroDistribucion cd ON cd.ID_Centro = p.ID_Centro
            ORDER BY p.Activo DESC, p.Nombre
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/admin/pickers error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// POST /api/admin/pickers - Create picker
router.post('/pickers', async (req, res) => {
    try {
        const { nombre, idCentro } = req.body;
        if (!nombre || !idCentro) {
            return res.status(400).json({ error: 'Nombre y centro requeridos' });
        }
        const pool = getPool();
        const result = await pool.request()
            .input('nombre', sql.NVarChar, nombre)
            .input('idCentro', sql.Int, idCentro)
            .query(`
                INSERT INTO Picker (Nombre, ID_Centro, Activo)
                OUTPUT INSERTED.ID_Picker
                VALUES (@nombre, @idCentro, 1)
            `);
        res.json({ ok: true, id: result.recordset[0].ID_Picker });
    } catch (err) {
        console.error('POST /api/admin/pickers error:', err);
        res.status(500).json({ error: 'Error al crear picker' });
    }
});

// PUT /api/admin/pickers/:id - Update picker
router.put('/pickers/:id', async (req, res) => {
    try {
        const id = parseInt(req.params.id);
        const { nombre, idCentro, activo } = req.body;
        const pool = getPool();
        await pool.request()
            .input('id', sql.Int, id)
            .input('nombre', sql.NVarChar, nombre)
            .input('idCentro', sql.Int, idCentro)
            .input('activo', sql.Bit, activo ? 1 : 0)
            .query(`
                UPDATE Picker
                SET Nombre = @nombre, ID_Centro = @idCentro, Activo = @activo
                WHERE ID_Picker = @id
            `);
        res.json({ ok: true });
    } catch (err) {
        console.error('PUT /api/admin/pickers/:id error:', err);
        res.status(500).json({ error: 'Error al actualizar picker' });
    }
});

// GET /api/admin/centros - List centros for dropdown
router.get('/centros', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
            SELECT ID_Centro, Nombre, Pais FROM CentroDistribucion ORDER BY Pais, Nombre
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/admin/centros error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// ── Carriles CRUD ──

// GET /api/admin/carriles - List all carriles with centro name
router.get('/carriles', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
            SELECT c.ID_Carril, c.Nombre, c.ID_Centro, c.Activo,
                   cd.Nombre AS CentroNombre
            FROM Carril c
            LEFT JOIN CentroDistribucion cd ON cd.ID_Centro = c.ID_Centro
            ORDER BY c.Activo DESC, cd.Nombre, c.Nombre
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/admin/carriles error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// POST /api/admin/carriles - Create carril
router.post('/carriles', async (req, res) => {
    try {
        const { nombre, idCentro } = req.body;
        if (!nombre || !idCentro) {
            return res.status(400).json({ error: 'Nombre y centro requeridos' });
        }
        const pool = getPool();
        const result = await pool.request()
            .input('nombre', sql.NVarChar, nombre)
            .input('idCentro', sql.Int, idCentro)
            .query(`
                INSERT INTO Carril (Nombre, ID_Centro, Activo)
                OUTPUT INSERTED.ID_Carril
                VALUES (@nombre, @idCentro, 1)
            `);
        res.json({ ok: true, id: result.recordset[0].ID_Carril });
    } catch (err) {
        console.error('POST /api/admin/carriles error:', err);
        res.status(500).json({ error: 'Error al crear carril' });
    }
});

// PUT /api/admin/carriles/:id - Update carril
router.put('/carriles/:id', async (req, res) => {
    try {
        const id = parseInt(req.params.id);
        const { nombre, idCentro, activo } = req.body;
        const pool = getPool();
        await pool.request()
            .input('id', sql.Int, id)
            .input('nombre', sql.NVarChar, nombre)
            .input('idCentro', sql.Int, idCentro)
            .input('activo', sql.Bit, activo ? 1 : 0)
            .query(`
                UPDATE Carril
                SET Nombre = @nombre, ID_Centro = @idCentro, Activo = @activo
                WHERE ID_Carril = @id
            `);
        res.json({ ok: true });
    } catch (err) {
        console.error('PUT /api/admin/carriles/:id error:', err);
        res.status(500).json({ error: 'Error al actualizar carril' });
    }
});

module.exports = router;
