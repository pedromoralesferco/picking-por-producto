const express = require('express');
const { getPool, sql } = require('../db');
const { requireAuth, requirePermiso } = require('../middleware/auth');
const router = express.Router();

// All WMS routes require authentication
router.use(requireAuth);

// Helper: SAP DB for DIMORA
// Override temporal via .env (SAP_DB=SANDBOX-TEST) para validaciones.
// Sin la variable, usa la sociedad de produccion 'SBODIMORA'.
const SAP_DB = process.env.SAP_DB || 'SBODIMORA';

// ══════════════════════════════════════════════════
// ── Ubicaciones ──
// ══════════════════════════════════════════════════

// GET /api/wms/ubicaciones
router.get('/ubicaciones', requirePermiso('wms_config'), async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
            SELECT ID_Ubicacion, Codigo, Descripcion, Zona, Pasillo, Rack, Nivel, Activo
            FROM WMS_Ubicacion
            ORDER BY Zona, Codigo
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/ubicaciones error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// GET /api/wms/ubicaciones/activas (for dropdowns, all WMS users)
router.get('/ubicaciones/activas', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
            SELECT ID_Ubicacion, Codigo, Descripcion, Zona
            FROM WMS_Ubicacion
            WHERE Activo = 1
            ORDER BY Zona, Codigo
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/ubicaciones/activas error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// POST /api/wms/ubicaciones
router.post('/ubicaciones', requirePermiso('wms_config'), async (req, res) => {
    try {
        const { codigo, descripcion, zona, pasillo, rack, nivel } = req.body;
        if (!codigo) return res.status(400).json({ error: 'Codigo requerido' });

        const pool = getPool();
        const result = await pool.request()
            .input('codigo', sql.NVarChar, codigo.toUpperCase().trim())
            .input('descripcion', sql.NVarChar, descripcion || null)
            .input('zona', sql.NVarChar, zona || null)
            .input('pasillo', sql.NVarChar, pasillo || null)
            .input('rack', sql.NVarChar, rack || null)
            .input('nivel', sql.NVarChar, nivel || null)
            .query(`
                INSERT INTO WMS_Ubicacion (Codigo, Descripcion, Zona, Pasillo, Rack, Nivel)
                OUTPUT INSERTED.ID_Ubicacion
                VALUES (@codigo, @descripcion, @zona, @pasillo, @rack, @nivel)
            `);
        res.json({ ok: true, id: result.recordset[0].ID_Ubicacion });
    } catch (err) {
        if (err.number === 2627) return res.status(400).json({ error: 'Codigo de ubicacion ya existe' });
        console.error('POST /api/wms/ubicaciones error:', err);
        res.status(500).json({ error: 'Error al crear ubicacion' });
    }
});

// PUT /api/wms/ubicaciones/:id
router.put('/ubicaciones/:id', requirePermiso('wms_config'), async (req, res) => {
    try {
        const id = parseInt(req.params.id);
        const { codigo, descripcion, zona, pasillo, rack, nivel, activo } = req.body;
        const pool = getPool();
        await pool.request()
            .input('id', sql.Int, id)
            .input('codigo', sql.NVarChar, codigo.toUpperCase().trim())
            .input('descripcion', sql.NVarChar, descripcion || null)
            .input('zona', sql.NVarChar, zona || null)
            .input('pasillo', sql.NVarChar, pasillo || null)
            .input('rack', sql.NVarChar, rack || null)
            .input('nivel', sql.NVarChar, nivel || null)
            .input('activo', sql.Bit, activo ? 1 : 0)
            .query(`
                UPDATE WMS_Ubicacion
                SET Codigo = @codigo, Descripcion = @descripcion, Zona = @zona,
                    Pasillo = @pasillo, Rack = @rack, Nivel = @nivel, Activo = @activo
                WHERE ID_Ubicacion = @id
            `);
        res.json({ ok: true });
    } catch (err) {
        console.error('PUT /api/wms/ubicaciones error:', err);
        res.status(500).json({ error: 'Error al actualizar ubicacion' });
    }
});

// ══════════════════════════════════════════════════
// ── License Plates (LPN) ──
// ══════════════════════════════════════════════════

// POST /api/wms/lpn - Create new LPN
router.post('/lpn', async (req, res) => {
    try {
        const { idUbicacion, tipo, codigo: codigoInput } = req.body;
        const pool = getPool();

        let codigo;
        if (codigoInput && codigoInput.trim()) {
            // Codigo provisto por el operario (tecleo/escaneo)
            codigo = codigoInput.toUpperCase().trim();
            const existing = await pool.request()
                .input('codigo', sql.NVarChar, codigo)
                .query(`SELECT ID_LPN, Codigo FROM WMS_LicensePlate WHERE Codigo = @codigo`);
            if (existing.recordset.length > 0) {
                // Ya existe: devolver la existente (find-or-create)
                return res.json({ ok: true, id: existing.recordset[0].ID_LPN, codigo: existing.recordset[0].Codigo, yaExistia: true });
            }
        } else {
            // Sin codigo: generar automatico LPN-0000X
            const seqResult = await pool.request().query(`
                UPDATE WMS_Secuencia SET ValorActual = ValorActual + 1
                OUTPUT INSERTED.ValorActual
                WHERE Nombre = 'LPN'
            `);
            const seq = seqResult.recordset[0].ValorActual;
            codigo = 'LPN-' + String(seq).padStart(5, '0');
        }

        const result = await pool.request()
            .input('codigo', sql.NVarChar, codigo)
            .input('idUbicacion', sql.Int, idUbicacion || null)
            .input('tipo', sql.NVarChar, tipo || 'Almacenamiento')
            .input('idOperador', sql.Int, req.session.user.id)
            .query(`
                INSERT INTO WMS_LicensePlate (Codigo, ID_Ubicacion, Estado, Tipo, ID_Operador)
                OUTPUT INSERTED.ID_LPN, INSERTED.Codigo
                VALUES (@codigo, @idUbicacion, 'Abierta', @tipo, @idOperador)
            `);

        res.json({ ok: true, id: result.recordset[0].ID_LPN, codigo: result.recordset[0].Codigo });
    } catch (err) {
        console.error('POST /api/wms/lpn error:', err);
        res.status(500).json({ error: 'Error al crear LPN' });
    }
});

// GET /api/wms/lpn - List LPNs (with filters)
router.get('/lpn', async (req, res) => {
    try {
        const pool = getPool();
        const { estado, ubicacion } = req.query;
        let where = 'WHERE 1=1';
        const request = pool.request();

        if (estado) {
            where += ' AND lp.Estado = @estado';
            request.input('estado', sql.NVarChar, estado);
        }
        if (ubicacion) {
            where += ' AND lp.ID_Ubicacion = @ubicacion';
            request.input('ubicacion', sql.Int, parseInt(ubicacion));
        }

        const result = await request.query(`
            SELECT lp.ID_LPN, lp.Codigo, lp.Estado, lp.Tipo,
                   lp.FechaCreacion, lp.FechaUltimoMov,
                   u.Codigo AS UbicacionCodigo, u.Zona,
                   op.Nombre AS OperadorNombre,
                   (SELECT COUNT(*) FROM WMS_Stock s WHERE s.ID_LPN = lp.ID_LPN AND s.Cantidad > 0) AS TotalItems,
                   (SELECT ISNULL(SUM(s.Cantidad), 0) FROM WMS_Stock s WHERE s.ID_LPN = lp.ID_LPN) AS TotalCantidad
            FROM WMS_LicensePlate lp
            LEFT JOIN WMS_Ubicacion u ON u.ID_Ubicacion = lp.ID_Ubicacion
            LEFT JOIN Usuario op ON op.ID_Usuario = lp.ID_Operador
            ${where}
            ORDER BY lp.FechaCreacion DESC
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/lpn error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// GET /api/wms/lpn/:id - LPN detail with contents
router.get('/lpn/:id', async (req, res) => {
    try {
        const pool = getPool();
        const id = parseInt(req.params.id);

        const lpn = await pool.request()
            .input('id', sql.Int, id)
            .query(`
                SELECT lp.*, u.Codigo AS UbicacionCodigo, u.Zona
                FROM WMS_LicensePlate lp
                LEFT JOIN WMS_Ubicacion u ON u.ID_Ubicacion = lp.ID_Ubicacion
                WHERE lp.ID_LPN = @id
            `);

        if (lpn.recordset.length === 0) return res.status(404).json({ error: 'LPN no encontrada' });

        const contenido = await pool.request()
            .input('id', sql.Int, id)
            .query(`
                SELECT s.ID_Stock, s.ItemCode, s.Descripcion, s.Cantidad, s.Lote,
                       u.Codigo AS UbicacionCodigo
                FROM WMS_Stock s
                LEFT JOIN WMS_Ubicacion u ON u.ID_Ubicacion = s.ID_Ubicacion
                WHERE s.ID_LPN = @id AND s.Cantidad > 0
                ORDER BY s.ItemCode
            `);

        res.json({ lpn: lpn.recordset[0], contenido: contenido.recordset });
    } catch (err) {
        console.error('GET /api/wms/lpn/:id error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// GET /api/wms/lpn/buscar/:codigo - Find LPN by code (for scanner)
router.get('/lpn/buscar/:codigo', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('codigo', sql.NVarChar, req.params.codigo.toUpperCase().trim())
            .query(`
                SELECT lp.ID_LPN, lp.Codigo, lp.Estado, lp.Tipo,
                       u.Codigo AS UbicacionCodigo, u.ID_Ubicacion
                FROM WMS_LicensePlate lp
                LEFT JOIN WMS_Ubicacion u ON u.ID_Ubicacion = lp.ID_Ubicacion
                WHERE lp.Codigo = @codigo
            `);
        if (result.recordset.length === 0) return res.status(404).json({ error: 'LPN no encontrada' });
        res.json(result.recordset[0]);
    } catch (err) {
        console.error('GET /api/wms/lpn/buscar error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// POST /api/wms/lpn/:id/cerrar
router.post('/lpn/:id/cerrar', async (req, res) => {
    try {
        const pool = getPool();
        await pool.request()
            .input('id', sql.Int, parseInt(req.params.id))
            .query(`UPDATE WMS_LicensePlate SET Estado = 'Cerrada' WHERE ID_LPN = @id`);
        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/wms/lpn/:id/cerrar error:', err);
        res.status(500).json({ error: 'Error al cerrar LPN' });
    }
});

// ══════════════════════════════════════════════════
// ── Movimientos (Traslados) ──
// ══════════════════════════════════════════════════

// POST /api/wms/traslados/lpn - Move entire LPN to new location
router.post('/traslados/lpn', requirePermiso('wms_traslados'), async (req, res) => {
    try {
        const { idLPN, idUbicacionDestino } = req.body;
        if (!idLPN || !idUbicacionDestino) {
            return res.status(400).json({ error: 'idLPN y idUbicacionDestino requeridos' });
        }

        const pool = getPool();

        // Get current LPN info
        const lpnResult = await pool.request()
            .input('id', sql.Int, idLPN)
            .query(`SELECT ID_LPN, ID_Ubicacion, Estado FROM WMS_LicensePlate WHERE ID_LPN = @id`);

        if (lpnResult.recordset.length === 0) return res.status(404).json({ error: 'LPN no encontrada' });
        const lpn = lpnResult.recordset[0];

        if (lpn.Estado === 'Despachada') {
            return res.status(400).json({ error: 'No se puede mover una LPN despachada' });
        }

        const idUbicacionOrigen = lpn.ID_Ubicacion;

        // Update LPN location
        await pool.request()
            .input('id', sql.Int, idLPN)
            .input('idUbic', sql.Int, idUbicacionDestino)
            .query(`
                UPDATE WMS_LicensePlate
                SET ID_Ubicacion = @idUbic, FechaUltimoMov = GETDATE()
                WHERE ID_LPN = @id
            `);

        // Update all stock in this LPN to new location
        await pool.request()
            .input('idLPN', sql.Int, idLPN)
            .input('idUbic', sql.Int, idUbicacionDestino)
            .query(`
                UPDATE WMS_Stock
                SET ID_Ubicacion = @idUbic, FechaActualizacion = GETDATE()
                WHERE ID_LPN = @idLPN
            `);

        // Record movement
        await pool.request()
            .input('idLPN', sql.Int, idLPN)
            .input('ubOrigen', sql.Int, idUbicacionOrigen)
            .input('ubDestino', sql.Int, idUbicacionDestino)
            .input('idOp', sql.Int, req.session.user.id)
            .query(`
                INSERT INTO WMS_Movimiento (Tipo, TipoOperacion, ID_LPN,
                    ID_UbicacionOrigen, ID_UbicacionDestino, ID_Operador)
                VALUES ('LPN', 'Traslado', @idLPN, @ubOrigen, @ubDestino, @idOp)
            `);

        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/wms/traslados/lpn error:', err);
        res.status(500).json({ error: 'Error al trasladar LPN' });
    }
});

// POST /api/wms/traslados/producto - Move product between locations/LPNs
router.post('/traslados/producto', requirePermiso('wms_traslados'), async (req, res) => {
    try {
        const { idStockOrigen, cantidad, idUbicacionDestino, idLPNDestino } = req.body;
        if (!idStockOrigen || !cantidad || !idUbicacionDestino) {
            return res.status(400).json({ error: 'idStockOrigen, cantidad y idUbicacionDestino requeridos' });
        }

        const pool = getPool();

        // Get source stock
        const srcResult = await pool.request()
            .input('id', sql.Int, idStockOrigen)
            .query(`SELECT * FROM WMS_Stock WHERE ID_Stock = @id`);

        if (srcResult.recordset.length === 0) return res.status(404).json({ error: 'Stock origen no encontrado' });
        const src = srcResult.recordset[0];

        if (cantidad > src.Cantidad) {
            return res.status(400).json({ error: `Cantidad excede disponible (${src.Cantidad})` });
        }

        // Decrease source
        await pool.request()
            .input('id', sql.Int, idStockOrigen)
            .input('cant', sql.Decimal(18, 4), cantidad)
            .query(`UPDATE WMS_Stock SET Cantidad = Cantidad - @cant, FechaActualizacion = GETDATE() WHERE ID_Stock = @id`);

        // Find or create destination stock
        const destRequest = pool.request()
            .input('item', sql.NVarChar, src.ItemCode)
            .input('lote', sql.NVarChar, src.Lote || '')
            .input('ubDest', sql.Int, idUbicacionDestino);

        let destQuery = `SELECT ID_Stock FROM WMS_Stock WHERE ItemCode = @item AND ID_Ubicacion = @ubDest`;
        if (idLPNDestino) {
            destRequest.input('lpnDest', sql.Int, idLPNDestino);
            destQuery += ' AND ID_LPN = @lpnDest';
        } else {
            destQuery += ' AND ID_LPN IS NULL';
        }
        destQuery += ` AND ISNULL(Lote, '') = @lote`;

        const destResult = await destRequest.query(destQuery);

        if (destResult.recordset.length > 0) {
            // Add to existing stock record
            await pool.request()
                .input('id', sql.Int, destResult.recordset[0].ID_Stock)
                .input('cant', sql.Decimal(18, 4), cantidad)
                .query(`UPDATE WMS_Stock SET Cantidad = Cantidad + @cant, FechaActualizacion = GETDATE() WHERE ID_Stock = @id`);
        } else {
            // Create new stock record at destination
            const insReq = pool.request()
                .input('item', sql.NVarChar, src.ItemCode)
                .input('desc', sql.NVarChar, src.Descripcion)
                .input('cant', sql.Decimal(18, 4), cantidad)
                .input('lote', sql.NVarChar, src.Lote)
                .input('ubDest', sql.Int, idUbicacionDestino);

            let lpnVal = 'NULL';
            if (idLPNDestino) {
                insReq.input('lpnDest', sql.Int, idLPNDestino);
                lpnVal = '@lpnDest';
            }

            await insReq.query(`
                INSERT INTO WMS_Stock (ItemCode, Descripcion, Cantidad, Lote, ID_Ubicacion, ID_LPN)
                VALUES (@item, @desc, @cant, @lote, @ubDest, ${lpnVal})
            `);
        }

        // Record movement
        await pool.request()
            .input('item', sql.NVarChar, src.ItemCode)
            .input('cant', sql.Decimal(18, 4), cantidad)
            .input('ubOrigen', sql.Int, src.ID_Ubicacion)
            .input('ubDestino', sql.Int, idUbicacionDestino)
            .input('lpnOrigen', sql.Int, src.ID_LPN)
            .input('lpnDestino', sql.Int, idLPNDestino || null)
            .input('idOp', sql.Int, req.session.user.id)
            .query(`
                INSERT INTO WMS_Movimiento (Tipo, TipoOperacion, ItemCode, Cantidad,
                    ID_UbicacionOrigen, ID_UbicacionDestino,
                    ID_LPN_Origen, ID_LPN_Destino, ID_Operador)
                VALUES ('Producto', 'Traslado', @item, @cant,
                    @ubOrigen, @ubDestino, @lpnOrigen, @lpnDestino, @idOp)
            `);

        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/wms/traslados/producto error:', err);
        res.status(500).json({ error: 'Error al trasladar producto' });
    }
});

// ══════════════════════════════════════════════════
// ── Picking de OV (Sales Orders from SAP) ──
// ══════════════════════════════════════════════════

// GET /api/wms/picking/ordenes-sap - Fetch open Sales Orders from SAP DIMORA
router.get('/picking/ordenes-sap', requirePermiso('wms_picking'), async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
            SELECT
                T0.DocEntry, T0.DocNum, T0.CardCode, T0.CardName,
                T0.DocDate, T0.DocDueDate, T0.DocTotal,
                T0.Comments,
                (SELECT COUNT(*) FROM [server-SQL].[${SAP_DB}].[dbo].RDR1 T1 WITH (NOLOCK)
                 WHERE T1.DocEntry = T0.DocEntry AND T1.LineStatus = 'O') AS LineasAbiertas
            FROM [server-SQL].[${SAP_DB}].[dbo].ORDR T0 WITH (NOLOCK)
            WHERE T0.DocStatus = 'O'
              AND T0.CANCELED = 'N'
            ORDER BY T0.DocDueDate, T0.DocNum
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/picking/ordenes-sap error:', err);
        res.status(500).json({ error: 'Error al consultar ordenes SAP' });
    }
});

// POST /api/wms/picking/importar - Import OV lines as picking tasks
router.post('/picking/importar', requirePermiso('wms_picking'), async (req, res) => {
    try {
        const { docEntry, docNum } = req.body;
        if (!docEntry || !docNum) return res.status(400).json({ error: 'docEntry y docNum requeridos' });

        const pool = getPool();

        // Check if already imported
        const existing = await pool.request()
            .input('docNum', sql.Int, docNum)
            .query(`SELECT COUNT(*) AS c FROM WMS_TareaPicking WHERE DocNum_SAP = @docNum`);
        if (existing.recordset[0].c > 0) {
            return res.status(400).json({ error: 'Esta OV ya fue importada' });
        }

        // Fetch lines from SAP
        const lines = await pool.request()
            .input('docEntry', sql.Int, docEntry)
            .query(`
                SELECT
                    T0.DocEntry, T0.DocNum, T0.CardCode, T0.CardName,
                    T1.LineNum, T1.ItemCode, T1.Dscription, T1.OpenQty, T1.WhsCode
                FROM [server-SQL].[${SAP_DB}].[dbo].ORDR T0 WITH (NOLOCK)
                INNER JOIN [server-SQL].[${SAP_DB}].[dbo].RDR1 T1 WITH (NOLOCK)
                    ON T0.DocEntry = T1.DocEntry
                WHERE T0.DocEntry = @docEntry
                  AND T1.LineStatus = 'O'
                  AND T1.OpenQty > 0
            `);

        if (lines.recordset.length === 0) {
            return res.status(400).json({ error: 'No hay lineas abiertas en esta OV' });
        }

        // Insert picking tasks
        for (const line of lines.recordset) {
            await pool.request()
                .input('docEntry', sql.Int, line.DocEntry)
                .input('docNum', sql.Int, line.DocNum)
                .input('cardCode', sql.NVarChar, line.CardCode)
                .input('cardName', sql.NVarChar, line.CardName)
                .input('lineNum', sql.Int, line.LineNum)
                .input('itemCode', sql.NVarChar, line.ItemCode)
                .input('desc', sql.NVarChar, line.Dscription)
                .input('cantidad', sql.Decimal(18, 4), line.OpenQty)
                .input('whsCode', sql.NVarChar, line.WhsCode)
                .query(`
                    INSERT INTO WMS_TareaPicking
                        (DocEntry_SAP, DocNum_SAP, CardCode, CardName, LineNum_SAP,
                         ItemCode, Descripcion, Cantidad, WhsCode)
                    VALUES (@docEntry, @docNum, @cardCode, @cardName, @lineNum,
                            @itemCode, @desc, @cantidad, @whsCode)
                `);
        }

        res.json({ ok: true, lineasImportadas: lines.recordset.length });
    } catch (err) {
        console.error('POST /api/wms/picking/importar error:', err);
        res.status(500).json({ error: 'Error al importar OV' });
    }
});

// GET /api/wms/picking/tareas - List picking tasks (grouped by OV)
router.get('/picking/tareas', requirePermiso('wms_picking'), async (req, res) => {
    try {
        const pool = getPool();
        const { estado } = req.query;
        let where = '';
        const request = pool.request();

        if (estado) {
            where = 'WHERE t.Estado = @estado';
            request.input('estado', sql.NVarChar, estado);
        }

        const result = await request.query(`
            SELECT
                t.DocNum_SAP, t.CardCode, t.CardName,
                MIN(t.FechaCreacion) AS FechaImportacion,
                COUNT(*) AS TotalLineas,
                SUM(CASE WHEN t.Estado = 'Completada' THEN 1 ELSE 0 END) AS LineasCompletadas,
                SUM(t.Cantidad) AS CantidadTotal,
                SUM(t.CantidadPickeada) AS CantidadPickeada,
                CASE
                    WHEN SUM(CASE WHEN t.Estado = 'Completada' THEN 1 ELSE 0 END) = COUNT(*) THEN 'Completada'
                    WHEN SUM(CASE WHEN t.Estado IN ('EnProceso', 'Asignada', 'Completada') THEN 1 ELSE 0 END) > 0 THEN 'EnProceso'
                    ELSE 'Pendiente'
                END AS EstadoGeneral
            FROM WMS_TareaPicking t
            ${where}
            GROUP BY t.DocNum_SAP, t.CardCode, t.CardName
            ORDER BY
                CASE
                    WHEN SUM(CASE WHEN t.Estado = 'Completada' THEN 1 ELSE 0 END) = COUNT(*) THEN 2
                    ELSE 0
                END,
                MIN(t.Prioridad), t.DocNum_SAP
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/picking/tareas error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// GET /api/wms/picking/tareas/:docNum - Lines for a specific OV
router.get('/picking/tareas/:docNum', requirePermiso('wms_picking'), async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('docNum', sql.Int, parseInt(req.params.docNum))
            .query(`
                SELECT t.ID_Tarea, t.LineNum_SAP, t.ItemCode, t.Descripcion,
                       t.Cantidad, t.CantidadPickeada, t.WhsCode, t.Estado,
                       t.ID_Operador, t.ID_LPN, t.FechaAsignacion, t.FechaFin,
                       u.Nombre AS OperadorNombre,
                       lp.Codigo AS LPN_Codigo,
                       ub.Codigo AS UbicacionCodigo
                FROM WMS_TareaPicking t
                LEFT JOIN Usuario u ON u.ID_Usuario = t.ID_Operador
                LEFT JOIN WMS_LicensePlate lp ON lp.ID_LPN = t.ID_LPN
                LEFT JOIN WMS_Ubicacion ub ON ub.ID_Ubicacion = t.ID_UbicacionOrigen
                WHERE t.DocNum_SAP = @docNum
                ORDER BY t.LineNum_SAP
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/picking/tareas/:docNum error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// POST /api/wms/picking/asignar - Assign operator to picking tasks
router.post('/picking/asignar', requirePermiso('wms_picking'), async (req, res) => {
    try {
        const { tareaIds, idOperador } = req.body;
        if (!tareaIds || !tareaIds.length || !idOperador) {
            return res.status(400).json({ error: 'tareaIds e idOperador requeridos' });
        }

        const pool = getPool();
        for (const id of tareaIds) {
            await pool.request()
                .input('id', sql.Int, id)
                .input('idOp', sql.Int, idOperador)
                .query(`
                    UPDATE WMS_TareaPicking
                    SET ID_Operador = @idOp, Estado = 'Asignada', FechaAsignacion = GETDATE()
                    WHERE ID_Tarea = @id AND Estado IN ('Pendiente', 'Asignada')
                `);
        }
        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/wms/picking/asignar error:', err);
        res.status(500).json({ error: 'Error al asignar' });
    }
});

// POST /api/wms/picking/pickear - Record pick (product into LPN)
router.post('/picking/pickear', requirePermiso('wms_picking'), async (req, res) => {
    try {
        const { idTarea, cantidad, idLPN, codigoOrigen } = req.body;
        if (!idTarea || !cantidad || !idLPN) {
            return res.status(400).json({ error: 'idTarea, cantidad e idLPN requeridos' });
        }

        const pool = getPool();

        // Get task
        const tareaResult = await pool.request()
            .input('id', sql.Int, idTarea)
            .query(`SELECT * FROM WMS_TareaPicking WHERE ID_Tarea = @id`);
        if (tareaResult.recordset.length === 0) return res.status(404).json({ error: 'Tarea no encontrada' });
        const tarea = tareaResult.recordset[0];

        const pendiente = tarea.Cantidad - tarea.CantidadPickeada;
        if (cantidad > pendiente) {
            return res.status(400).json({ error: `Cantidad excede pendiente (${pendiente})` });
        }

        // Get LPN location
        const lpnResult = await pool.request()
            .input('id', sql.Int, idLPN)
            .query(`SELECT ID_LPN, ID_Ubicacion, Estado FROM WMS_LicensePlate WHERE ID_LPN = @id`);
        if (lpnResult.recordset.length === 0) return res.status(404).json({ error: 'LPN no encontrada' });
        const lpn = lpnResult.recordset[0];

        if (lpn.Estado === 'Despachada' || lpn.Estado === 'Cerrada') {
            return res.status(400).json({ error: 'LPN no esta abierta' });
        }

        // Origen del stock: la LPN elegida/escaneada (codigoOrigen); si no viene, PRODUCTION por default
        let origenResult;
        if (codigoOrigen && codigoOrigen.trim()) {
            origenResult = await pool.request()
                .input('cod', sql.NVarChar, codigoOrigen.toUpperCase().trim())
                .input('item', sql.NVarChar, tarea.ItemCode)
                .query(`
                    SELECT TOP 1 s.ID_Stock, s.Cantidad, s.ID_LPN, s.ID_Ubicacion
                    FROM WMS_Stock s
                    JOIN WMS_LicensePlate lp ON lp.ID_LPN = s.ID_LPN
                    WHERE s.ItemCode = @item AND lp.Codigo = @cod
                `);
        } else {
            origenResult = await pool.request()
                .input('item', sql.NVarChar, tarea.ItemCode)
                .query(`
                    SELECT TOP 1 s.ID_Stock, s.Cantidad, s.ID_LPN, s.ID_Ubicacion
                    FROM WMS_Stock s
                    JOIN WMS_LicensePlate lp ON lp.ID_LPN = s.ID_LPN
                    WHERE s.ItemCode = @item AND lp.Codigo = 'PRODUCTION'
                `);
        }
        const dispOrigen = origenResult.recordset.length ? origenResult.recordset[0].Cantidad : 0;
        const origenCod = (codigoOrigen && codigoOrigen.trim()) ? codigoOrigen.toUpperCase().trim() : 'PRODUCTION';
        if (dispOrigen < cantidad) {
            return res.status(400).json({ error: `Stock insuficiente en la ubicacion ${origenCod} para ${tarea.ItemCode} (disponible ${dispOrigen})` });
        }
        const origen = origenResult.recordset[0];

        const newPickeada = tarea.CantidadPickeada + cantidad;
        const newEstado = newPickeada >= tarea.Cantidad ? 'Completada' : 'EnProceso';

        // Update task
        await pool.request()
            .input('id', sql.Int, idTarea)
            .input('cant', sql.Decimal(18, 4), newPickeada)
            .input('estado', sql.NVarChar, newEstado)
            .input('idLPN', sql.Int, idLPN)
            .query(`
                UPDATE WMS_TareaPicking
                SET CantidadPickeada = @cant, Estado = @estado, ID_LPN = @idLPN
                    ${newEstado === 'Completada' ? ', FechaFin = GETDATE()' : ''}
                WHERE ID_Tarea = @id
            `);

        // Salida: descontar la cantidad pickeada del stock origen (PRODUCTION)
        await pool.request()
            .input('id', sql.Int, origen.ID_Stock)
            .input('cant', sql.Decimal(18, 4), cantidad)
            .query(`UPDATE WMS_Stock SET Cantidad = Cantidad - @cant, FechaActualizacion = GETDATE() WHERE ID_Stock = @id`);

        // Record movement (salida desde PRODUCTION hacia la LPN de picking)
        await pool.request()
            .input('item', sql.NVarChar, tarea.ItemCode)
            .input('cant', sql.Decimal(18, 4), cantidad)
            .input('ubOrigen', sql.Int, origen.ID_Ubicacion)
            .input('idLPNOrigen', sql.Int, origen.ID_LPN)
            .input('idLPN', sql.Int, idLPN)
            .input('idOp', sql.Int, req.session.user.id)
            .input('ref', sql.NVarChar, `OV-${tarea.DocNum_SAP}`)
            .query(`
                INSERT INTO WMS_Movimiento (Tipo, TipoOperacion, ItemCode, Cantidad,
                    ID_UbicacionOrigen, ID_LPN_Origen, ID_LPN_Destino, ID_Operador, Referencia)
                VALUES ('Producto', 'Picking', @item, @cant,
                    @ubOrigen, @idLPNOrigen, @idLPN, @idOp, @ref)
            `);

        res.json({ ok: true, estado: newEstado, cantidadPickeada: newPickeada });
    } catch (err) {
        console.error('POST /api/wms/picking/pickear error:', err);
        res.status(500).json({ error: 'Error al registrar pick' });
    }
});

// POST /api/wms/picking/confirmar/:docNum - Confirm OV and send to UiPath staging
router.post('/picking/confirmar/:docNum', requirePermiso('wms_picking'), async (req, res) => {
    try {
        const docNum = parseInt(req.params.docNum);
        const pool = getPool();

        // Verify all lines completed
        const check = await pool.request()
            .input('docNum', sql.Int, docNum)
            .query(`
                SELECT COUNT(*) AS total,
                       SUM(CASE WHEN Estado = 'Completada' THEN 1 ELSE 0 END) AS completadas
                FROM WMS_TareaPicking
                WHERE DocNum_SAP = @docNum
            `);

        const { total, completadas } = check.recordset[0];
        if (total === 0) return res.status(404).json({ error: 'OV no encontrada' });
        if (completadas < total) {
            return res.status(400).json({ error: `Faltan ${total - completadas} lineas por completar` });
        }

        // Get OV header info
        const header = await pool.request()
            .input('docNum', sql.Int, docNum)
            .query(`
                SELECT TOP 1 DocEntry_SAP, DocNum_SAP, CardCode, CardName
                FROM WMS_TareaPicking WHERE DocNum_SAP = @docNum
            `);
        const h = header.recordset[0];

        // Create integration record: ENTREGA
        const entrega = await pool.request()
            .input('tipo', sql.NVarChar, 'ENTREGA')
            .input('docNumOrigen', sql.Int, h.DocNum_SAP)
            .input('docEntryOrigen', sql.Int, h.DocEntry_SAP)
            .input('cardCode', sql.NVarChar, h.CardCode)
            .input('cardName', sql.NVarChar, h.CardName)
            .input('idUsuario', sql.Int, req.session.user.id)
            .query(`
                INSERT INTO WMS_Integracion (TipoDocumento, DocNum_SAP_Origen, DocEntry_SAP_Origen,
                    CardCode, CardName, ID_Usuario)
                OUTPUT INSERTED.ID_Integracion
                VALUES (@tipo, @docNumOrigen, @docEntryOrigen, @cardCode, @cardName, @idUsuario)
            `);
        const idIntegracion = entrega.recordset[0].ID_Integracion;

        // Insert detail lines
        const lines = await pool.request()
            .input('docNum', sql.Int, docNum)
            .query(`SELECT * FROM WMS_TareaPicking WHERE DocNum_SAP = @docNum`);

        for (const line of lines.recordset) {
            await pool.request()
                .input('idInt', sql.Int, idIntegracion)
                .input('lineNum', sql.Int, line.LineNum_SAP)
                .input('item', sql.NVarChar, line.ItemCode)
                .input('desc', sql.NVarChar, line.Descripcion)
                .input('cant', sql.Decimal(18, 4), line.CantidadPickeada)
                .input('whs', sql.NVarChar, line.WhsCode)
                .input('idLPN', sql.Int, line.ID_LPN)
                .query(`
                    INSERT INTO WMS_IntegracionDetalle
                        (ID_Integracion, LineNum_SAP, ItemCode, Descripcion, Cantidad, WhsCode, ID_LPN)
                    VALUES (@idInt, @lineNum, @item, @desc, @cant, @whs, @idLPN)
                `);
        }

        // Also create FACTURA integration record (UiPath creates delivery first, then invoice)
        await pool.request()
            .input('tipo', sql.NVarChar, 'FACTURA')
            .input('docNumOrigen', sql.Int, h.DocNum_SAP)
            .input('docEntryOrigen', sql.Int, h.DocEntry_SAP)
            .input('cardCode', sql.NVarChar, h.CardCode)
            .input('cardName', sql.NVarChar, h.CardName)
            .input('idUsuario', sql.Int, req.session.user.id)
            .input('comentarios', sql.NVarChar, `Basada en Entrega de OV ${h.DocNum_SAP} - Integracion #${idIntegracion}`)
            .query(`
                INSERT INTO WMS_Integracion (TipoDocumento, DocNum_SAP_Origen, DocEntry_SAP_Origen,
                    CardCode, CardName, ID_Usuario, Comentarios)
                VALUES (@tipo, @docNumOrigen, @docEntryOrigen, @cardCode, @cardName, @idUsuario, @comentarios)
            `);

        res.json({ ok: true, idIntegracion });
    } catch (err) {
        console.error('POST /api/wms/picking/confirmar error:', err);
        res.status(500).json({ error: 'Error al confirmar OV' });
    }
});

// ══════════════════════════════════════════════════
// ── Ingreso de Mercaderia (Purchase Orders from SAP) ──
// ══════════════════════════════════════════════════

// GET /api/wms/ingreso/ordenes-sap - Fetch open Purchase Orders
router.get('/ingreso/ordenes-sap', requirePermiso('wms_ingreso'), async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
            SELECT
                T0.DocEntry, T0.DocNum, T0.CardCode, T0.CardName,
                T0.DocDate, T0.DocDueDate, T0.DocTotal,
                (SELECT COUNT(*) FROM [server-SQL].[${SAP_DB}].[dbo].POR1 T1 WITH (NOLOCK)
                 WHERE T1.DocEntry = T0.DocEntry AND T1.LineStatus = 'O') AS LineasAbiertas
            FROM [server-SQL].[${SAP_DB}].[dbo].OPOR T0 WITH (NOLOCK)
            WHERE T0.DocStatus = 'O'
              AND T0.CANCELED = 'N'
            ORDER BY T0.DocDueDate, T0.DocNum
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/ingreso/ordenes-sap error:', err);
        res.status(500).json({ error: 'Error al consultar POs de SAP' });
    }
});

// POST /api/wms/ingreso/importar - Import PO lines as receiving tasks
router.post('/ingreso/importar', requirePermiso('wms_ingreso'), async (req, res) => {
    try {
        const { docEntry, docNum } = req.body;
        if (!docEntry || !docNum) return res.status(400).json({ error: 'docEntry y docNum requeridos' });

        const pool = getPool();

        const existing = await pool.request()
            .input('docNum', sql.Int, docNum)
            .query(`SELECT COUNT(*) AS c FROM WMS_TareaIngreso WHERE DocNum_SAP = @docNum`);
        if (existing.recordset[0].c > 0) {
            return res.status(400).json({ error: 'Esta PO ya fue importada' });
        }

        const lines = await pool.request()
            .input('docEntry', sql.Int, docEntry)
            .query(`
                SELECT
                    T0.DocEntry, T0.DocNum, T0.CardCode, T0.CardName,
                    T1.LineNum, T1.ItemCode, T1.Dscription, T1.OpenQty, T1.WhsCode
                FROM [server-SQL].[${SAP_DB}].[dbo].OPOR T0 WITH (NOLOCK)
                INNER JOIN [server-SQL].[${SAP_DB}].[dbo].POR1 T1 WITH (NOLOCK)
                    ON T0.DocEntry = T1.DocEntry
                WHERE T0.DocEntry = @docEntry
                  AND T1.LineStatus = 'O'
                  AND T1.OpenQty > 0
            `);

        if (lines.recordset.length === 0) {
            return res.status(400).json({ error: 'No hay lineas abiertas en esta PO' });
        }

        for (const line of lines.recordset) {
            await pool.request()
                .input('docEntry', sql.Int, line.DocEntry)
                .input('docNum', sql.Int, line.DocNum)
                .input('cardCode', sql.NVarChar, line.CardCode)
                .input('cardName', sql.NVarChar, line.CardName)
                .input('lineNum', sql.Int, line.LineNum)
                .input('itemCode', sql.NVarChar, line.ItemCode)
                .input('desc', sql.NVarChar, line.Dscription)
                .input('cantidad', sql.Decimal(18, 4), line.OpenQty)
                .input('whsCode', sql.NVarChar, line.WhsCode)
                .query(`
                    INSERT INTO WMS_TareaIngreso
                        (DocEntry_SAP, DocNum_SAP, CardCode, CardName, LineNum_SAP,
                         ItemCode, Descripcion, CantidadEsperada, WhsCode)
                    VALUES (@docEntry, @docNum, @cardCode, @cardName, @lineNum,
                            @itemCode, @desc, @cantidad, @whsCode)
                `);
        }

        res.json({ ok: true, lineasImportadas: lines.recordset.length });
    } catch (err) {
        console.error('POST /api/wms/ingreso/importar error:', err);
        res.status(500).json({ error: 'Error al importar PO' });
    }
});

// GET /api/wms/ingreso/tareas - List receiving tasks grouped by PO
router.get('/ingreso/tareas', requirePermiso('wms_ingreso'), async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
            SELECT
                t.DocNum_SAP, t.CardCode, t.CardName,
                MIN(t.FechaCreacion) AS FechaImportacion,
                COUNT(*) AS TotalLineas,
                SUM(CASE WHEN t.Estado = 'Completada' THEN 1 ELSE 0 END) AS LineasCompletadas,
                SUM(t.CantidadEsperada) AS CantidadEsperada,
                SUM(t.CantidadRecibida) AS CantidadRecibida,
                CASE
                    WHEN SUM(CASE WHEN t.Estado = 'Completada' THEN 1 ELSE 0 END) = COUNT(*) THEN 'Completada'
                    WHEN SUM(CASE WHEN t.Estado IN ('EnProceso', 'Asignada', 'Completada') THEN 1 ELSE 0 END) > 0 THEN 'EnProceso'
                    ELSE 'Pendiente'
                END AS EstadoGeneral
            FROM WMS_TareaIngreso t
            GROUP BY t.DocNum_SAP, t.CardCode, t.CardName
            ORDER BY
                CASE WHEN SUM(CASE WHEN t.Estado = 'Completada' THEN 1 ELSE 0 END) = COUNT(*) THEN 2 ELSE 0 END,
                t.DocNum_SAP
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/ingreso/tareas error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// GET /api/wms/ingreso/tareas/:docNum - Lines for a specific PO
router.get('/ingreso/tareas/:docNum', requirePermiso('wms_ingreso'), async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('docNum', sql.Int, parseInt(req.params.docNum))
            .query(`
                SELECT t.ID_Tarea, t.LineNum_SAP, t.ItemCode, t.Descripcion,
                       t.CantidadEsperada, t.CantidadRecibida, t.WhsCode, t.Estado,
                       t.ID_Operador, t.ID_LPN, t.FechaAsignacion, t.FechaFin,
                       u.Nombre AS OperadorNombre,
                       lp.Codigo AS LPN_Codigo,
                       ub.Codigo AS UbicacionCodigo
                FROM WMS_TareaIngreso t
                LEFT JOIN Usuario u ON u.ID_Usuario = t.ID_Operador
                LEFT JOIN WMS_LicensePlate lp ON lp.ID_LPN = t.ID_LPN
                LEFT JOIN WMS_Ubicacion ub ON ub.ID_Ubicacion = t.ID_UbicacionDestino
                WHERE t.DocNum_SAP = @docNum
                ORDER BY t.LineNum_SAP
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/ingreso/tareas/:docNum error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// POST /api/wms/ingreso/recibir - Record receipt (product into LPN at location)
router.post('/ingreso/recibir', requirePermiso('wms_ingreso'), async (req, res) => {
    try {
        const { idTarea, cantidad, idLPN, idUbicacionDestino } = req.body;
        if (!idTarea || !cantidad) {
            return res.status(400).json({ error: 'idTarea y cantidad requeridos' });
        }

        const pool = getPool();

        const tareaResult = await pool.request()
            .input('id', sql.Int, idTarea)
            .query(`SELECT * FROM WMS_TareaIngreso WHERE ID_Tarea = @id`);
        if (tareaResult.recordset.length === 0) return res.status(404).json({ error: 'Tarea no encontrada' });
        const tarea = tareaResult.recordset[0];

        const newRecibida = tarea.CantidadRecibida + cantidad;
        const newEstado = newRecibida >= tarea.CantidadEsperada ? 'Completada' : 'EnProceso';

        const ubDestino = idUbicacionDestino || tarea.ID_UbicacionDestino;

        // Update task
        await pool.request()
            .input('id', sql.Int, idTarea)
            .input('cant', sql.Decimal(18, 4), newRecibida)
            .input('estado', sql.NVarChar, newEstado)
            .input('idLPN', sql.Int, idLPN || null)
            .input('ubDest', sql.Int, ubDestino || null)
            .query(`
                UPDATE WMS_TareaIngreso
                SET CantidadRecibida = @cant, Estado = @estado, ID_LPN = @idLPN,
                    ID_UbicacionDestino = @ubDest
                    ${newEstado === 'Completada' ? ', FechaFin = GETDATE()' : ''}
                WHERE ID_Tarea = @id
            `);

        // Add to stock
        if (ubDestino) {
            const existingStock = await pool.request()
                .input('item', sql.NVarChar, tarea.ItemCode)
                .input('ubic', sql.Int, ubDestino)
                .input('idLPN', sql.Int, idLPN || null)
                .query(`
                    SELECT ID_Stock FROM WMS_Stock
                    WHERE ItemCode = @item AND ID_Ubicacion = @ubic
                      AND ${idLPN ? 'ID_LPN = @idLPN' : 'ID_LPN IS NULL'}
                `);

            if (existingStock.recordset.length > 0) {
                await pool.request()
                    .input('id', sql.Int, existingStock.recordset[0].ID_Stock)
                    .input('cant', sql.Decimal(18, 4), cantidad)
                    .query(`UPDATE WMS_Stock SET Cantidad = Cantidad + @cant, FechaActualizacion = GETDATE() WHERE ID_Stock = @id`);
            } else {
                await pool.request()
                    .input('item', sql.NVarChar, tarea.ItemCode)
                    .input('desc', sql.NVarChar, tarea.Descripcion)
                    .input('cant', sql.Decimal(18, 4), cantidad)
                    .input('ubic', sql.Int, ubDestino)
                    .input('idLPN', sql.Int, idLPN || null)
                    .query(`
                        INSERT INTO WMS_Stock (ItemCode, Descripcion, Cantidad, ID_Ubicacion, ID_LPN)
                        VALUES (@item, @desc, @cant, @ubic, @idLPN)
                    `);
            }

            // Record movement
            await pool.request()
                .input('item', sql.NVarChar, tarea.ItemCode)
                .input('cant', sql.Decimal(18, 4), cantidad)
                .input('ubDest', sql.Int, ubDestino)
                .input('idLPN', sql.Int, idLPN || null)
                .input('idOp', sql.Int, req.session.user.id)
                .input('ref', sql.NVarChar, `PO-${tarea.DocNum_SAP}`)
                .query(`
                    INSERT INTO WMS_Movimiento (Tipo, TipoOperacion, ItemCode, Cantidad,
                        ID_UbicacionDestino, ID_LPN_Destino, ID_Operador, Referencia)
                    VALUES ('Producto', 'Ingreso', @item, @cant,
                        @ubDest, @idLPN, @idOp, @ref)
                `);
        }

        res.json({ ok: true, estado: newEstado, cantidadRecibida: newRecibida });
    } catch (err) {
        console.error('POST /api/wms/ingreso/recibir error:', err);
        res.status(500).json({ error: 'Error al registrar recepcion' });
    }
});

// POST /api/wms/ingreso/confirmar/:docNum - Confirm PO and send to UiPath staging
router.post('/ingreso/confirmar/:docNum', requirePermiso('wms_ingreso'), async (req, res) => {
    try {
        const docNum = parseInt(req.params.docNum);
        const pool = getPool();

        const check = await pool.request()
            .input('docNum', sql.Int, docNum)
            .query(`
                SELECT COUNT(*) AS total,
                       SUM(CASE WHEN Estado = 'Completada' THEN 1 ELSE 0 END) AS completadas
                FROM WMS_TareaIngreso WHERE DocNum_SAP = @docNum
            `);

        const { total, completadas } = check.recordset[0];
        if (total === 0) return res.status(404).json({ error: 'PO no encontrada' });
        if (completadas < total) {
            return res.status(400).json({ error: `Faltan ${total - completadas} lineas por completar` });
        }

        const header = await pool.request()
            .input('docNum', sql.Int, docNum)
            .query(`SELECT TOP 1 * FROM WMS_TareaIngreso WHERE DocNum_SAP = @docNum`);
        const h = header.recordset[0];

        // Create integration: ENTRADA_MERCANCIA
        const intResult = await pool.request()
            .input('tipo', sql.NVarChar, 'ENTRADA_MERCANCIA')
            .input('docNumOrigen', sql.Int, h.DocNum_SAP)
            .input('docEntryOrigen', sql.Int, h.DocEntry_SAP)
            .input('cardCode', sql.NVarChar, h.CardCode)
            .input('cardName', sql.NVarChar, h.CardName)
            .input('idUsuario', sql.Int, req.session.user.id)
            .query(`
                INSERT INTO WMS_Integracion (TipoDocumento, DocNum_SAP_Origen, DocEntry_SAP_Origen,
                    CardCode, CardName, ID_Usuario)
                OUTPUT INSERTED.ID_Integracion
                VALUES (@tipo, @docNumOrigen, @docEntryOrigen, @cardCode, @cardName, @idUsuario)
            `);
        const idIntegracion = intResult.recordset[0].ID_Integracion;

        const lines = await pool.request()
            .input('docNum', sql.Int, docNum)
            .query(`SELECT * FROM WMS_TareaIngreso WHERE DocNum_SAP = @docNum`);

        for (const line of lines.recordset) {
            await pool.request()
                .input('idInt', sql.Int, idIntegracion)
                .input('lineNum', sql.Int, line.LineNum_SAP)
                .input('item', sql.NVarChar, line.ItemCode)
                .input('desc', sql.NVarChar, line.Descripcion)
                .input('cant', sql.Decimal(18, 4), line.CantidadRecibida)
                .input('whs', sql.NVarChar, line.WhsCode)
                .input('idLPN', sql.Int, line.ID_LPN)
                .query(`
                    INSERT INTO WMS_IntegracionDetalle
                        (ID_Integracion, LineNum_SAP, ItemCode, Descripcion, Cantidad, WhsCode, ID_LPN)
                    VALUES (@idInt, @lineNum, @item, @desc, @cant, @whs, @idLPN)
                `);
        }

        res.json({ ok: true, idIntegracion });
    } catch (err) {
        console.error('POST /api/wms/ingreso/confirmar error:', err);
        res.status(500).json({ error: 'Error al confirmar PO' });
    }
});

// ══════════════════════════════════════════════════
// ── Stock & Inventory ──
// ══════════════════════════════════════════════════

// GET /api/wms/picking/pase/:docNum - Datos para el pase de salida (PDF)
router.get('/picking/pase/:docNum', requirePermiso('wms_picking'), async (req, res) => {
    try {
        const docNum = parseInt(req.params.docNum);
        const pool = getPool();
        const header = await pool.request()
            .input('d', sql.Int, docNum)
            .query(`SELECT TOP 1 DocNum_SAP, CardCode, CardName FROM WMS_TareaPicking WHERE DocNum_SAP = @d`);
        const lineas = await pool.request()
            .input('d', sql.Int, docNum)
            .query(`
                SELECT t.ItemCode, t.Descripcion, t.CantidadPickeada AS Cantidad,
                       lp.Codigo AS LPN
                FROM WMS_TareaPicking t
                LEFT JOIN WMS_LicensePlate lp ON lp.ID_LPN = t.ID_LPN
                WHERE t.DocNum_SAP = @d AND t.CantidadPickeada > 0
                ORDER BY t.LineNum_SAP
            `);
        res.json({ header: header.recordset[0] || null, lineas: lineas.recordset });
    } catch (err) {
        console.error('GET /api/wms/picking/pase error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// GET /api/wms/stock/disponible/:itemCode - Fuentes de stock (ubicacion/LPN) de un item, para elegir origen al pickear
router.get('/stock/disponible/:itemCode', requirePermiso('wms_picking'), async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('item', sql.NVarChar, req.params.itemCode)
            .query(`
                SELECT s.ID_Stock, s.Cantidad,
                       s.ID_LPN, lp.Codigo AS LPN_Codigo,
                       s.ID_Ubicacion, u.Codigo AS Ubicacion_Codigo
                FROM WMS_Stock s
                LEFT JOIN WMS_LicensePlate lp ON lp.ID_LPN = s.ID_LPN
                LEFT JOIN WMS_Ubicacion u ON u.ID_Ubicacion = s.ID_Ubicacion
                WHERE s.ItemCode = @item AND s.Cantidad > 0
                ORDER BY s.Cantidad DESC
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/stock/disponible error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// GET /api/wms/stock - Inventory view
router.get('/stock', async (req, res) => {
    try {
        const pool = getPool();
        const { ubicacion, itemCode } = req.query;
        let where = 'WHERE s.Cantidad > 0';
        const request = pool.request();

        if (ubicacion) {
            where += ' AND s.ID_Ubicacion = @ubicacion';
            request.input('ubicacion', sql.Int, parseInt(ubicacion));
        }
        if (itemCode) {
            where += ' AND s.ItemCode LIKE @itemCode';
            request.input('itemCode', sql.NVarChar, `%${itemCode}%`);
        }

        const result = await request.query(`
            SELECT s.ID_Stock, s.ItemCode, s.Descripcion, s.Cantidad, s.Lote,
                   u.Codigo AS UbicacionCodigo, u.Zona,
                   lp.Codigo AS LPN_Codigo, lp.Estado AS LPN_Estado
            FROM WMS_Stock s
            LEFT JOIN WMS_Ubicacion u ON u.ID_Ubicacion = s.ID_Ubicacion
            LEFT JOIN WMS_LicensePlate lp ON lp.ID_LPN = s.ID_LPN
            ${where}
            ORDER BY u.Codigo, s.ItemCode
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/stock error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// ══════════════════════════════════════════════════
// ── Integracion (staging table monitor) ──
// ══════════════════════════════════════════════════

// GET /api/wms/integracion - List integration records
router.get('/integracion', requirePermiso('wms_config'), async (req, res) => {
    try {
        const pool = getPool();
        const { estado } = req.query;
        let where = '';
        const request = pool.request();

        if (estado) {
            where = 'WHERE i.Estado = @estado';
            request.input('estado', sql.NVarChar, estado);
        }

        const result = await request.query(`
            SELECT i.ID_Integracion, i.TipoDocumento, i.DocNum_SAP_Origen,
                   i.CardCode, i.CardName, i.Estado, i.DocNum_SAP_Creado,
                   i.MensajeError, i.IntentosUiPath,
                   i.FechaCreacion, i.FechaProcesado,
                   u.Nombre AS UsuarioNombre,
                   (SELECT COUNT(*) FROM WMS_IntegracionDetalle d WHERE d.ID_Integracion = i.ID_Integracion) AS TotalLineas
            FROM WMS_Integracion i
            LEFT JOIN Usuario u ON u.ID_Usuario = i.ID_Usuario
            ${where}
            ORDER BY i.FechaCreacion DESC
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/integracion error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// GET /api/wms/integracion/:id - Integration detail
router.get('/integracion/:id', requirePermiso('wms_config'), async (req, res) => {
    try {
        const pool = getPool();
        const id = parseInt(req.params.id);

        const header = await pool.request()
            .input('id', sql.Int, id)
            .query(`SELECT * FROM WMS_Integracion WHERE ID_Integracion = @id`);
        if (header.recordset.length === 0) return res.status(404).json({ error: 'No encontrado' });

        const detail = await pool.request()
            .input('id', sql.Int, id)
            .query(`SELECT * FROM WMS_IntegracionDetalle WHERE ID_Integracion = @id ORDER BY LineNum_SAP`);

        res.json({ header: header.recordset[0], detalle: detail.recordset });
    } catch (err) {
        console.error('GET /api/wms/integracion/:id error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// POST /api/wms/integracion/:id/reintentar - Reset failed integration for retry
router.post('/integracion/:id/reintentar', requirePermiso('wms_config'), async (req, res) => {
    try {
        const pool = getPool();
        await pool.request()
            .input('id', sql.Int, parseInt(req.params.id))
            .query(`
                UPDATE WMS_Integracion
                SET Estado = 'Pendiente', MensajeError = NULL
                WHERE ID_Integracion = @id AND Estado = 'Error'
            `);
        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/wms/integracion/:id/reintentar error:', err);
        res.status(500).json({ error: 'Error al reintentar' });
    }
});

// ══════════════════════════════════════════════════
// ── Operadores WMS (users with WMS permissions) ──
// ══════════════════════════════════════════════════

// GET /api/wms/operadores - List users with any wms_ permission
router.get('/operadores', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
            SELECT DISTINCT u.ID_Usuario, u.Nombre, u.NombreUsuario
            FROM Usuario u
            INNER JOIN UsuarioPermiso up ON up.ID_Usuario = u.ID_Usuario
            WHERE up.Modulo LIKE 'wms_%'
              AND u.Activo = 1
            ORDER BY u.Nombre
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/operadores error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// ══════════════════════════════════════════════════
// ── Movimientos history ──
// ══════════════════════════════════════════════════

router.get('/movimientos', async (req, res) => {
    try {
        const pool = getPool();
        const { limit } = req.query;
        const top = Math.min(parseInt(limit) || 50, 200);

        const result = await pool.request()
            .input('top', sql.Int, top)
            .query(`
                SELECT TOP (@top)
                    m.ID_Movimiento, m.Tipo, m.TipoOperacion,
                    m.ItemCode, m.Cantidad, m.Referencia, m.FechaMovimiento,
                    lp.Codigo AS LPN_Codigo,
                    uo.Codigo AS UbicacionOrigen,
                    ud.Codigo AS UbicacionDestino,
                    lpO.Codigo AS LPN_Origen,
                    lpD.Codigo AS LPN_Destino,
                    op.Nombre AS OperadorNombre
                FROM WMS_Movimiento m
                LEFT JOIN WMS_LicensePlate lp ON lp.ID_LPN = m.ID_LPN
                LEFT JOIN WMS_Ubicacion uo ON uo.ID_Ubicacion = m.ID_UbicacionOrigen
                LEFT JOIN WMS_Ubicacion ud ON ud.ID_Ubicacion = m.ID_UbicacionDestino
                LEFT JOIN WMS_LicensePlate lpO ON lpO.ID_LPN = m.ID_LPN_Origen
                LEFT JOIN WMS_LicensePlate lpD ON lpD.ID_LPN = m.ID_LPN_Destino
                LEFT JOIN Usuario op ON op.ID_Usuario = m.ID_Operador
                ORDER BY m.FechaMovimiento DESC
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/wms/movimientos error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

module.exports = router;
