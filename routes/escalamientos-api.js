// ============================================================
// Módulo Escalamientos — tickets de OV/TR a escalar en picking/despacho.
// HUB Escuintla (GT, centro 3). Estado (Pendiente/Programado/Finalizado)
// se deriva en vivo cruzando la OV contra los cuadros (app OPM + SAP).
// ============================================================
const express = require('express');
const router = express.Router();
const { getPool, sql } = require('../db');
const { getSapDb } = require('../config/paises');

const CENTRO = 3; // HUB Escuintla

// Acceso al módulo: comercial (reportes), operativo (reportes_operativo) o Admin.
function requireEsc(req, res, next) {
    const u = req.session && req.session.user;
    if (!u) return res.status(401).json({ error: 'No autenticado' });
    if (u.rol === 'Admin' || (u.permisos && (u.permisos.includes('reportes') || u.permisos.includes('reportes_operativo')))) return next();
    return res.status(403).json({ error: 'Sin permiso para escalamientos' });
}

// Busca datos del documento (OV o TR) en SAP/Lisa: tipo, cliente, monto, peso, líneas.
async function lookupDoc(pool, docRaw) {
    const num = parseInt(String(docRaw).replace(/\D/g, ''));
    const out = { OV_Number: String(docRaw).trim(), DocType: null, ClienteNombre: null, Destino: null, Monto: null, PesoKg: null, TotalLineas: null, U_Estado2: null, enPrepa: false, encontrado: false };
    if (!num || isNaN(num)) return out;
    const db = getSapDb('GT');
    const lisa = 'lisa_' + db;
    // ¿OV?
    try {
        const ov = await pool.request().input('d', sql.Int, num).query(`
            SELECT TOP 1 o.DocTotal AS Monto, c.CardName AS Cliente, s.SlpName AS Asesor, o.U_Estado2 AS Estado2
            FROM [server-sql].[${db}].dbo.ORDR o WITH (NOLOCK)
            LEFT JOIN [server-sql].[${db}].dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
            LEFT JOIN [server-sql].[${db}].dbo.OSLP s WITH (NOLOCK) ON s.SlpCode = o.SlpCode
            WHERE o.DocNum = @d`);
        if (ov.recordset.length) {
            out.DocType = 'OV'; out.encontrado = true;
            out.ClienteNombre = ov.recordset[0].Cliente || null;
            out.Monto = ov.recordset[0].Monto != null ? Number(ov.recordset[0].Monto) : null;
            out.Asesor = ov.recordset[0].Asesor || null;
            out.U_Estado2 = ov.recordset[0].Estado2 != null ? String(ov.recordset[0].Estado2).trim() : null;
        }
    } catch (e) { console.error('lookupDoc OV:', e.message); }
    // ¿TR?
    if (!out.DocType) {
        try {
            const tr = await pool.request().input('d', sql.Int, num).query(`
                SELECT TOP 1 c.CardName AS Cliente, wh.WhsName AS Destino, o.U_Estado2 AS Estado2
                FROM [server-sql].[${db}].dbo.OWTQ o WITH (NOLOCK)
                LEFT JOIN [server-sql].[${db}].dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
                LEFT JOIN [server-sql].[${db}].dbo.OWHS wh WITH (NOLOCK) ON wh.WhsCode = o.ToWhsCode
                WHERE o.DocNum = @d`);
            if (tr.recordset.length) {
                out.DocType = 'TR'; out.encontrado = true;
                out.ClienteNombre = tr.recordset[0].Cliente || null;
                out.Destino = tr.recordset[0].Destino || null;
                out.U_Estado2 = tr.recordset[0].Estado2 != null ? String(tr.recordset[0].Estado2).trim() : null;
            }
        } catch (e) { console.error('lookupDoc TR:', e.message); }
    }
    out.enPrepa = out.U_Estado2 === '03';
    // Peso + líneas desde Lisa
    try {
        const d = String(num);
        if (out.DocType === 'OV') {
            const r = await pool.request().input('d', sql.VarChar(50), d).query(`
                SELECT COUNT(DISTINCT l.IdProduct) AS Lineas, SUM(ISNULL(l.QtyOrdered,0) * ISNULL(pr.UnitMass,0)) AS Peso
                FROM [server-sql].[${lisa}].dbo.[CustomerOrder] co WITH (NOLOCK)
                JOIN [server-sql].[${lisa}].dbo.[CustomerOrderLine] l WITH (NOLOCK) ON l.IdCustomerOrder = co.IdCustomerOrder
                LEFT JOIN [server-sql].[${lisa}].dbo.[Product] pr WITH (NOLOCK) ON pr.IdProduct = l.IdProduct
                WHERE co.IdAccountableOrder = @d`);
            out.TotalLineas = r.recordset[0].Lineas || 0; out.PesoKg = r.recordset[0].Peso != null ? Number(r.recordset[0].Peso) : 0;
        } else if (out.DocType === 'TR') {
            const r = await pool.request().input('d', sql.VarChar(50), d).query(`
                SELECT COUNT(DISTINCT l.IdProduct) AS Lineas, SUM(ISNULL(l.QtyToTransfer,0) * ISNULL(pr.UnitMass,0)) AS Peso
                FROM [server-sql].[${lisa}].dbo.[TransferRequest] co WITH (NOLOCK)
                JOIN [server-sql].[${lisa}].dbo.[TransferRequestLines] l WITH (NOLOCK) ON l.IdTransferRequest = co.IdTransferRequest
                LEFT JOIN [server-sql].[${lisa}].dbo.[Product] pr WITH (NOLOCK) ON pr.IdProduct = l.IdProduct
                WHERE co.DocNum = @d`);
            out.TotalLineas = r.recordset[0].Lineas || 0; out.PesoKg = r.recordset[0].Peso != null ? Number(r.recordset[0].Peso) : 0;
        }
    } catch (e) { console.error('lookupDoc lineas:', e.message); }
    return out;
}

// Detalle de productos (en vivo) de un documento.
async function getLineasDoc(pool, docRaw, docType) {
    const num = parseInt(String(docRaw).replace(/\D/g, ''));
    if (!num || isNaN(num)) return [];
    const db = getSapDb('GT'); const lisa = 'lisa_' + db; const d = String(num);
    try {
        if (docType === 'OV') {
            const r = await pool.request().input('d', sql.VarChar(50), d).query(`
                SELECT pr.InternIdProduct AS Codigo, MAX(pr.ProductName) AS Nombre,
                       SUM(ISNULL(l.QtyOrdered,0)) AS Cantidad,
                       SUM(ISNULL(l.QtyOrdered,0) * ISNULL(pr.UnitMass,0)) AS Peso
                FROM [server-sql].[${lisa}].dbo.[CustomerOrder] co WITH (NOLOCK)
                JOIN [server-sql].[${lisa}].dbo.[CustomerOrderLine] l WITH (NOLOCK) ON l.IdCustomerOrder = co.IdCustomerOrder
                LEFT JOIN [server-sql].[${lisa}].dbo.[Product] pr WITH (NOLOCK) ON pr.IdProduct = l.IdProduct
                WHERE co.IdAccountableOrder = @d GROUP BY pr.InternIdProduct ORDER BY pr.InternIdProduct`);
            return r.recordset;
        } else {
            const r = await pool.request().input('d', sql.VarChar(50), d).query(`
                SELECT pr.InternIdProduct AS Codigo, MAX(pr.ProductName) AS Nombre,
                       SUM(ISNULL(l.QtyToTransfer,0)) AS Cantidad,
                       SUM(ISNULL(l.QtyToTransfer,0) * ISNULL(pr.UnitMass,0)) AS Peso
                FROM [server-sql].[${lisa}].dbo.[TransferRequest] co WITH (NOLOCK)
                JOIN [server-sql].[${lisa}].dbo.[TransferRequestLines] l WITH (NOLOCK) ON l.IdTransferRequest = co.IdTransferRequest
                LEFT JOIN [server-sql].[${lisa}].dbo.[Product] pr WITH (NOLOCK) ON pr.IdProduct = l.IdProduct
                WHERE co.DocNum = @d GROUP BY pr.InternIdProduct ORDER BY pr.InternIdProduct`);
            return r.recordset;
        }
    } catch (e) { console.error('getLineasDoc:', e.message); return []; }
}

// Estado por OV cruzando contra cuadros. Devuelve { rank, desp } por OV:
// rank 0=Pendiente, 1=Programado, 2=Finalizado; desp = fecha de despacho (para
// los finalizados), usada para ocultar del tablero 24h después.
async function estadosDeOVs(pool, ovs) {
    const list = [...new Set(ovs.map(o => String(o).trim()).filter(Boolean))];
    const map = {}; list.forEach(o => map[o] = { rank: 0, desp: null, cuadroFin: null, cuadroAny: null });
    if (!list.length) return map;
    const merge = (k, rk, desp, cuadroFin, cuadroAny) => {
        const m = map[k]; if (!m) return;
        if (rk > m.rank) m.rank = rk;
        if (desp && (!m.desp || new Date(desp) > new Date(m.desp))) m.desp = desp;
        if (cuadroFin && !m.cuadroFin) m.cuadroFin = cuadroFin;
        if (cuadroAny && (!m.cuadroAny || cuadroAny > m.cuadroAny)) m.cuadroAny = cuadroAny;
    };
    // App: OPM de Escuintla
    try {
        const req = pool.request();
        const inP = list.map((v, i) => { req.input('a' + i, sql.VarChar(50), v); return '@a' + i; }).join(',');
        const a = await req.query(`
            SELECT LTRIM(RTRIM(opm.OV_Number)) ov,
                   MAX(CASE WHEN orp.EstadoDespacho='Finalizado' THEN 2 ELSE 1 END) rk,
                   MAX(CASE WHEN orp.EstadoDespacho='Finalizado' THEN orp.FechaDespachoFin END) desp,
                   MAX(CASE WHEN orp.EstadoDespacho='Finalizado' THEN orp.RouteNumber END) cuadroFin,
                   MAX(orp.RouteNumber) cuadroAny
            FROM OrderPickingManagement opm
            JOIN OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
            WHERE orp.ID_Centro = ${CENTRO} AND LTRIM(RTRIM(opm.OV_Number)) IN (${inP})
            GROUP BY LTRIM(RTRIM(opm.OV_Number))`);
        a.recordset.forEach(r => merge(String(r.ov).trim(), r.rk, r.desp, r.cuadroFin, r.cuadroAny));
    } catch (e) { console.error('estadosDeOVs app:', e.message); }
    // SAP: presencia en cuadros (@cuadro_ruta_d) + u_estado='03' = despachado
    try {
        const db = getSapDb('GT');
        const req = pool.request();
        const inP = list.map((v, i) => { req.input('s' + i, sql.VarChar(50), v); return '@s' + i; }).join(',');
        const s = await req.query(`
            SELECT LTRIM(RTRIM(d.U_No_OV)) ov,
                   MAX(CASE WHEN e.u_estado='03' THEN 2 ELSE 1 END) rk,
                   MAX(CASE WHEN e.u_estado='03' THEN e.UpdateDate END) desp,
                   MAX(CASE WHEN e.u_estado='03' THEN e.DocNum END) cuadroFin,
                   MAX(e.DocNum) cuadroAny
            FROM [server-sql].[${db}].dbo.[@cuadro_ruta_e] e WITH (NOLOCK)
            JOIN [server-sql].[${db}].dbo.[@cuadro_ruta_d] d WITH (NOLOCK) ON d.DocEntry = e.DocEntry
            WHERE LTRIM(RTRIM(d.U_No_OV)) COLLATE DATABASE_DEFAULT IN (${inP})
            GROUP BY LTRIM(RTRIM(d.U_No_OV))`);
        s.recordset.forEach(r => merge(String(r.ov).trim(), r.rk, r.desp, r.cuadroFin, r.cuadroAny));
    } catch (e) { console.error('estadosDeOVs sap:', e.message); }
    // Cuadro a mostrar: el despachado si está finalizado, si no cualquiera donde esté
    Object.keys(map).forEach(k => { const m = map[k]; m.cuadro = m.rank === 2 ? (m.cuadroFin || m.cuadroAny) : m.cuadroAny; });
    return map;
}
const ESTADO_NOMBRE = { 0: 'Pendiente', 1: 'Programado', 2: 'Finalizado' };

// GET /api/escalamientos/lookup?ov=  — datos del documento para el formulario
router.get('/lookup', requireEsc, async (req, res) => {
    try {
        const ov = String(req.query.ov || '').trim();
        if (!ov) return res.status(400).json({ error: 'ov requerido' });
        const info = await lookupDoc(getPool(), ov);
        res.json(info);
    } catch (err) { console.error('GET /lookup', err); res.status(500).json({ error: 'Error en lookup' }); }
});

// POST /api/escalamientos — crear ticket
router.post('/', requireEsc, async (req, res) => {
    try {
        const pool = getPool();
        const ov = String(req.body.ov || '').trim();
        if (!ov) return res.status(400).json({ error: 'OV/TR requerido' });
        const fechaReq = /^\d{4}-\d{2}-\d{2}$/.test(String(req.body.fechaRequerida || '').slice(0, 10))
            ? String(req.body.fechaRequerida).slice(0, 10) : null;
        const comentario = String(req.body.comentario || '').trim();
        const info = await lookupDoc(pool, ov);
        // No permitir escalar si el documento está pendiente de poner en preparación
        // (U_Estado2 <> '03'). Si no se encontró en SAP, no se puede validar -> se permite.
        if (info.encontrado && !info.enPrepa) {
            return res.status(409).json({
                error: `La ${info.DocType || 'OV'} ${ov} no está en preparación (U_Estado2=${info.U_Estado2 || '—'}). Ponla en preparación ('03') antes de escalar.`,
                codigo: 'NO_PREPA'
            });
        }
        const docType = info.DocType || (String(req.body.docType || '').toUpperCase() === 'TR' ? 'TR' : 'OV');
        const autor = (req.session.user && (req.session.user.nombre || req.session.user.usuario)) || 'Sistema';
        const ins = await pool.request()
            .input('ov', sql.NVarChar(50), ov)
            .input('dt', sql.NVarChar(10), docType)
            .input('fr', sql.VarChar(10), fechaReq)
            .input('cli', sql.NVarChar(200), info.ClienteNombre || null)
            .input('monto', sql.Decimal(18, 2), docType === 'OV' ? (info.Monto ?? null) : null)
            .input('peso', sql.Decimal(18, 2), info.PesoKg ?? null)
            .input('lin', sql.Int, info.TotalLineas ?? null)
            .input('autor', sql.NVarChar(100), autor)
            .query(`
                INSERT INTO dbo.Escalamientos (OV_Number, DocType, FechaRequerida, ClienteNombre, Monto, PesoKg, TotalLineas, CreadoPor)
                OUTPUT INSERTED.ID_Escalamiento
                VALUES (@ov, @dt, CONVERT(date, @fr, 23), @cli, @monto, @peso, @lin, @autor)`);
        const id = ins.recordset[0].ID_Escalamiento;
        if (comentario) {
            await pool.request().input('id', sql.Int, id).input('c', sql.NVarChar(sql.MAX), comentario).input('a', sql.NVarChar(100), autor)
                .query(`INSERT INTO dbo.EscalamientoComentarios (ID_Escalamiento, Comentario, Autor) VALUES (@id, @c, @a)`);
        }
        res.json({ ok: true, id, encontrado: info.encontrado, docType });
    } catch (err) { console.error('POST /escalamientos', err); res.status(500).json({ error: 'Error al crear escalamiento' }); }
});

// GET /api/escalamientos — lista con estado derivado (para el kanban)
router.get('/', requireEsc, async (req, res) => {
    try {
        const pool = getPool();
        const r = await pool.request().query(`
            SELECT e.ID_Escalamiento, e.OV_Number, e.DocType, e.FechaRequerida, e.ClienteNombre,
                   e.Monto, e.PesoKg, e.TotalLineas, e.CreadoPor, e.FechaCreacion,
                   (SELECT COUNT(*) FROM dbo.EscalamientoComentarios c WHERE c.ID_Escalamiento = e.ID_Escalamiento) AS Comentarios
            FROM dbo.Escalamientos e
            WHERE e.Archivado = 0
            ORDER BY e.FechaRequerida ASC, e.FechaCreacion ASC`);
        const estados = await estadosDeOVs(pool, r.recordset.map(x => x.OV_Number));
        const cut = Date.now() - 24 * 3600 * 1000; // Finalizados: visibles solo 24h tras el despacho
        const data = r.recordset.map(x => {
            const st = estados[String(x.OV_Number).trim()] || { rank: 0, desp: null, cuadro: null };
            return { ...x, Estado: ESTADO_NOMBRE[st.rank], FechaDespacho: st.desp, Cuadro: st.cuadro };
        }).filter(x => {
            if (x.Estado !== 'Finalizado') return true;
            if (!x.FechaDespacho) return true; // sin fecha de despacho -> no se puede datar, se mantiene
            return new Date(x.FechaDespacho).getTime() >= cut;
        });
        res.json(data);
    } catch (err) { console.error('GET /escalamientos', err); res.status(500).json({ error: 'Error al listar' }); }
});

// GET /api/escalamientos/:id — detalle (líneas en vivo + comentarios)
router.get('/:id', requireEsc, async (req, res) => {
    try {
        const pool = getPool();
        const id = parseInt(req.params.id);
        const e = await pool.request().input('id', sql.Int, id)
            .query(`SELECT * FROM dbo.Escalamientos WHERE ID_Escalamiento = @id`);
        if (!e.recordset.length) return res.status(404).json({ error: 'No encontrado' });
        const esc = e.recordset[0];
        const coms = await pool.request().input('id', sql.Int, id)
            .query(`SELECT Comentario, Autor, Fecha FROM dbo.EscalamientoComentarios WHERE ID_Escalamiento = @id ORDER BY Fecha ASC`);
        const lineas = await getLineasDoc(pool, esc.OV_Number, esc.DocType);
        const estados = await estadosDeOVs(pool, [esc.OV_Number]);
        const st = estados[String(esc.OV_Number).trim()] || { rank: 0, cuadro: null };
        // Historial de la OV en su cuadro: planificado / pickeado / despachado
        let historial = null;
        try {
            const h = await pool.request().input('ov', sql.VarChar(50), String(esc.OV_Number).trim()).query(`
                SELECT TOP 1 orp.RouteNumber AS Cuadro, orp.FechaPlanificacion AS Planificado,
                       ISNULL(opm.FechaFin, orp.FechaFin) AS Pickeado, orp.FechaDespachoFin AS Despachado
                FROM OrderPickingManagement opm
                JOIN OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
                WHERE orp.ID_Centro = ${CENTRO} AND LTRIM(RTRIM(opm.OV_Number)) = @ov
                ORDER BY CASE WHEN orp.EstadoDespacho='Finalizado' THEN 0 ELSE 1 END,
                         orp.FechaDespachoFin DESC, orp.RouteNumber DESC`);
            if (h.recordset.length) historial = h.recordset[0];
        } catch (e) { console.error('historial:', e.message); }
        res.json({ escalamiento: esc, estado: ESTADO_NOMBRE[st.rank], cuadro: st.cuadro, comentarios: coms.recordset, lineas, historial });
    } catch (err) { console.error('GET /escalamientos/:id', err); res.status(500).json({ error: 'Error al obtener detalle' }); }
});

// POST /api/escalamientos/:id/comentario
router.post('/:id/comentario', requireEsc, async (req, res) => {
    try {
        const pool = getPool();
        const id = parseInt(req.params.id);
        const c = String(req.body.comentario || '').trim();
        if (!c) return res.status(400).json({ error: 'Comentario vacío' });
        const autor = (req.session.user && (req.session.user.nombre || req.session.user.usuario)) || 'Sistema';
        await pool.request().input('id', sql.Int, id).input('c', sql.NVarChar(sql.MAX), c).input('a', sql.NVarChar(100), autor)
            .query(`INSERT INTO dbo.EscalamientoComentarios (ID_Escalamiento, Comentario, Autor) VALUES (@id, @c, @a)`);
        res.json({ ok: true });
    } catch (err) { console.error('POST comentario', err); res.status(500).json({ error: 'Error al comentar' }); }
});

// POST /api/escalamientos/:id/archivar — ocultar del tablero
router.post('/:id/archivar', requireEsc, async (req, res) => {
    try {
        const pool = getPool();
        const id = parseInt(req.params.id);
        const val = req.body.archivar === false ? 0 : 1;
        await pool.request().input('id', sql.Int, id).input('v', sql.Bit, val)
            .query(`UPDATE dbo.Escalamientos SET Archivado = @v WHERE ID_Escalamiento = @id`);
        res.json({ ok: true });
    } catch (err) { console.error('POST archivar', err); res.status(500).json({ error: 'Error al archivar' }); }
});

module.exports = router;
