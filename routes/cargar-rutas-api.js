// ============================================================
// /api/cargar-rutas — carga de plantillas de rutas al staging (Supabase
// rutas_staging) y disparo del robot de importación (UiPath), desde el app.
// Reemplaza el salto SharePoint -> Power Automate: el usuario sube la MISMA
// plantilla (RUTA;PESO;DOCUMENTO;TIPO;CAPACIDAD;ALMACENORIGEN) y un botón
// "Procesar" la inserta en el staging y corre el robot.
//
// NUNCA escribe a SAP: solo anexa filas 'pendiente' al staging; el robot de
// UiPath es quien crea los cuadros en SAP (igual que el flujo actual).
// Auth: sesión del app + permiso 'planificador' (o Admin).
// ============================================================
const express = require('express');
const crypto = require('crypto');
const { requireAuth, requirePermiso } = require('../middleware/auth');
const router = express.Router();

router.use(requireAuth, requirePermiso('planificador'));

// ── Config del staging / robot ─────────────────────────────
function stagingCfg() {
    const base = (process.env.PLAN_STAGING_URL || '').replace(/\/$/, '');
    const key = process.env.PLAN_STAGING_KEY;
    return { base, key, ok: !!(base && key) };
}

// Lanza el robot de importación de rutas (staging → cuadros SAP) en UiPath.
// Mismo mecanismo que start_import_rutas.py y el conector MCP.
async function lanzarRobotRutas() {
    const need = ['UIPATH_TOKEN_URL', 'UIPATH_CLIENT_ID', 'UIPATH_CLIENT_SECRET', 'UIPATH_STARTJOBS_URL', 'UIPATH_RELEASE_KEY', 'UIPATH_ORG_UNIT'];
    const falta = need.filter(k => !process.env[k]);
    if (falta.length) throw new Error('UiPath no configurado en el app: faltan ' + falta.join(', '));
    const tr = await fetch(process.env.UIPATH_TOKEN_URL, {
        method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ grant_type: 'client_credentials', client_id: process.env.UIPATH_CLIENT_ID, client_secret: process.env.UIPATH_CLIENT_SECRET, scope: 'OR.Jobs' })
    });
    if (!tr.ok) { const t = (await tr.text().catch(() => '')).slice(0, 200); throw new Error(`UiPath token HTTP ${tr.status}: ${t}`); }
    const tok = await tr.json();
    const sr = await fetch(process.env.UIPATH_STARTJOBS_URL, {
        method: 'POST',
        headers: { Authorization: `Bearer ${tok.access_token}`, 'Content-Type': 'application/json', 'X-UIPATH-OrganizationUnitId': process.env.UIPATH_ORG_UNIT },
        body: JSON.stringify({ startInfo: { ReleaseKey: process.env.UIPATH_RELEASE_KEY, Strategy: 'ModernJobsCount', JobsCount: 1, InputArguments: '{}' } })
    });
    const body = await sr.text();
    if (!(sr.status === 200 || sr.status === 201)) throw new Error(`UiPath StartJobs HTTP ${sr.status}: ${body.slice(0, 200)}`);
    let job = null; try { job = JSON.parse(body).value[0]; } catch { /* sin cuerpo */ }
    return job ? { id: job.Id, key: job.Key, estado: job.State, creado: job.CreationTime } : { ok: true };
}

// ── Parser de la plantilla ─────────────────────────────────
// Normaliza encabezados: minúsculas, sin acentos, sin espacios.
function normKey(s) {
    return String(s || '').replace(/^﻿/, '').toLowerCase()
        .normalize('NFD').replace(/[̀-ͯ]/g, '')
        .replace(/[\s_]+/g, '').trim();
}
const COL_ALIASES = {
    ruta: 'ruta',
    peso: 'peso', pesokg: 'peso', kg: 'peso',
    documento: 'documento', doc: 'documento', ov: 'documento', novov: 'documento',
    tipo: 'tipo', tipodocumento: 'tipo',
    capacidad: 'capacidad', cap: 'capacidad', capacidadt: 'capacidad', camion: 'capacidad',
    almacenorigen: 'almacen_origen', almacen: 'almacen_origen', bodega: 'almacen_origen', bodegaorigen: 'almacen_origen'
};
const TIPOS_OK = new Set(['OV', 'TR', 'RESURTIDO']);

function detectarDelim(linea) {
    const cands = [';', '\t', ',', '|'];
    let best = ';', n = -1;
    for (const d of cands) { const c = linea.split(d).length; if (c > n) { n = c; best = d; } }
    return best;
}

// Devuelve { filas:[...válidas...], invalidas:[{linea,motivo,raw}], headerOk, columnas }
function parsePlantilla(texto) {
    const txt = String(texto || '').replace(/^﻿/, '');
    const lineas = txt.split(/\r?\n/).map(l => l).filter(l => l.trim().length);
    if (!lineas.length) return { filas: [], invalidas: [], headerOk: false, columnas: [], error: 'El archivo está vacío.' };

    const delim = detectarDelim(lineas[0]);
    const headerCells = lineas[0].split(delim).map(normKey);
    const mapped = headerCells.map(h => COL_ALIASES[h] || null);
    const tieneHeader = mapped.includes('ruta') && mapped.includes('documento');
    if (!tieneHeader) {
        return { filas: [], invalidas: [], headerOk: false, columnas: headerCells,
            error: 'No reconocí el encabezado. Usa la plantilla estándar: RUTA;PESO;DOCUMENTO;TIPO;CAPACIDAD;ALMACENORIGEN (descárgala con el botón).' };
    }
    const idx = {};
    mapped.forEach((m, i) => { if (m && idx[m] === undefined) idx[m] = i; });

    const filas = [], invalidas = [];
    for (let i = 1; i < lineas.length; i++) {
        const raw = lineas[i];
        const cells = raw.split(delim);
        const get = (k) => (idx[k] != null ? (cells[idx[k]] || '').trim() : '');
        const ruta = get('ruta');
        const documento = get('documento').replace(/\s+/g, '');
        let tipo = get('tipo').toUpperCase();
        const pesoRaw = get('peso').replace(',', '.');
        const capRaw = get('capacidad').toUpperCase().replace(/\s*T$/,'').replace(',', '.');
        const almacen = get('almacen_origen');

        // fila totalmente vacía → ignorar en silencio
        if (!ruta && !documento && !tipo && !pesoRaw) continue;

        const motivos = [];
        if (!ruta) motivos.push('sin RUTA');
        if (!documento) motivos.push('sin DOCUMENTO');
        else if (!/^\d+$/.test(documento)) motivos.push('DOCUMENTO no numérico');
        if (!tipo) tipo = documento && documento.length >= 8 ? 'OV' : '';   // heurística suave; se valida abajo
        if (!TIPOS_OK.has(tipo)) motivos.push(`TIPO inválido ("${get('tipo')}") — usa OV o TR`);
        const peso = pesoRaw === '' ? null : Number(pesoRaw);
        if (pesoRaw !== '' && !Number.isFinite(peso)) motivos.push('PESO no numérico');
        const capacidad = capRaw === '' ? null : Number(capRaw);
        if (capRaw !== '' && !Number.isFinite(capacidad)) motivos.push('CAPACIDAD no numérica');
        if (!almacen) motivos.push('sin ALMACENORIGEN');

        if (motivos.length) { invalidas.push({ linea: i + 1, motivo: motivos.join(', '), raw }); continue; }
        filas.push({ ruta, documento, tipo, peso, capacidad, almacen_origen: almacen });
    }
    return { filas, invalidas, headerOk: true, delim, columnas: headerCells };
}

// Agrupa filas por ruta para el resumen.
function resumenPorRuta(filas) {
    const m = new Map();
    for (const f of filas) {
        if (!m.has(f.ruta)) m.set(f.ruta, { ruta: f.ruta, docs: 0, pesoKg: 0, capacidad: f.capacidad, almacenes: new Set() });
        const r = m.get(f.ruta);
        r.docs++; r.pesoKg += (f.peso || 0); if (f.almacen_origen) r.almacenes.add(f.almacen_origen);
        if (r.capacidad == null && f.capacidad != null) r.capacidad = f.capacidad;
    }
    return [...m.values()].map(r => ({ ruta: r.ruta, docs: r.docs, pesoKg: Math.round(r.pesoKg), capacidad: r.capacidad, almacenes: [...r.almacenes] }));
}

// ── POST /preview — parsea y devuelve el resumen (sin escribir nada) ──
router.post('/preview', (req, res) => {
    try {
        const p = parsePlantilla(req.body && req.body.texto);
        if (p.error) return res.status(400).json({ error: p.error, columnas: p.columnas });
        res.json({
            rutas: resumenPorRuta(p.filas),
            totalFilas: p.filas.length,
            totalRutas: new Set(p.filas.map(f => f.ruta)).size,
            invalidas: p.invalidas
        });
    } catch (e) { res.status(500).json({ error: 'No se pudo leer la plantilla: ' + e.message }); }
});

// ── POST /procesar — inserta en staging + lanza el robot ──
// Body: { texto, archivo?, fecha? (AAAA-MM-DD) }
router.post('/procesar', async (req, res) => {
    try {
        const cfg = stagingCfg();
        if (!cfg.ok) return res.status(503).json({ error: 'Staging no configurado en el app (PLAN_STAGING_URL / PLAN_STAGING_KEY)' });

        const p = parsePlantilla(req.body && req.body.texto);
        if (p.error) return res.status(400).json({ error: p.error });
        if (!p.filas.length) return res.status(400).json({ error: 'No hay filas válidas para cargar.' });

        const fecha = (req.body && req.body.fecha && /^\d{4}-\d{2}-\d{2}$/.test(req.body.fecha)) ? req.body.fecha : null;
        const u = req.session.user;
        const archivo = String((req.body && req.body.archivo) || `App ${u.usuario || u.nombre || ''}`).trim().slice(0, 120);

        // Un lote_id por ruta (el robot crea un cuadro por ruta). lote fino = cleanup/estado por ruta.
        const porRuta = new Map();
        for (const f of p.filas) { if (!porRuta.has(f.ruta)) porRuta.set(f.ruta, crypto.randomUUID()); }

        const filas = p.filas.map(f => ({
            lote_id: porRuta.get(f.ruta),
            archivo,
            ruta: f.ruta,
            peso: f.peso,
            documento: f.documento,
            tipo: f.tipo,
            capacidad: f.capacidad,
            almacen_origen: f.almacen_origen,
            fecha_carga: fecha,
            estado: 'pendiente'
        }));

        // 1) Insertar en Supabase rutas_staging
        const r = await fetch(`${cfg.base}/rest/v1/rutas_staging`, {
            method: 'POST',
            headers: { apikey: cfg.key, Authorization: `Bearer ${cfg.key}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
            body: JSON.stringify(filas)
        });
        if (!r.ok) return res.status(502).json({ error: `Supabase ${r.status}: ${(await r.text().catch(() => '')).slice(0, 300)}` });

        // 2) Disparar el robot
        let robot = null, errorRobot = null;
        try { robot = await lanzarRobotRutas(); } catch (e) { errorRobot = e.message; }

        const lotes = [...porRuta.entries()].map(([ruta, lote_id]) => ({ ruta, lote_id }));
        res.json({
            filasInsertadas: filas.length,
            totalRutas: lotes.length,
            omitidas: p.invalidas.length,
            archivo, fecha,
            lotes,
            robot, errorRobot,
            nota: errorRobot
                ? 'Las rutas quedaron en el staging, pero el robot no arrancó: revisa el mensaje y vuelve a correrlo.'
                : 'Robot encolado. El robot crea un cuadro por ruta en SAP y el app lo ingesta en ~5 min.'
        });
    } catch (e) { res.status(500).json({ error: 'Error al procesar: ' + e.message }); }
});

// ── GET /estado?lotes=a,b,c — conteo por estado de cada lote (para seguir el avance) ──
router.get('/estado', async (req, res) => {
    try {
        const cfg = stagingCfg();
        if (!cfg.ok) return res.status(503).json({ error: 'Staging no configurado' });
        const lotes = String(req.query.lotes || '').split(',').map(s => s.trim()).filter(Boolean);
        if (!lotes.length) return res.json({ lotes: [] });
        const inList = lotes.map(encodeURIComponent).join(',');
        const url = `${cfg.base}/rest/v1/rutas_staging?select=lote_id,ruta,estado,cuadro_docnum,error_msg&lote_id=in.(${inList})`;
        const r = await fetch(url, { headers: { apikey: cfg.key, Authorization: `Bearer ${cfg.key}` } });
        if (!r.ok) return res.status(502).json({ error: `Supabase ${r.status}` });
        const rows = await r.json();
        const m = new Map();
        for (const x of rows) {
            if (!m.has(x.lote_id)) m.set(x.lote_id, { lote_id: x.lote_id, ruta: x.ruta, total: 0, pendiente: 0, completado: 0, error: 0, cuadros: new Set(), errores: [] });
            const g = m.get(x.lote_id);
            g.total++;
            if (x.estado === 'pendiente') g.pendiente++;
            else if (x.estado === 'completado') g.completado++;
            else if (x.estado === 'error') g.error++;
            if (x.cuadro_docnum && x.cuadro_docnum !== '0') g.cuadros.add(x.cuadro_docnum);
            if (x.error_msg) g.errores.push(x.error_msg);
        }
        res.json({ lotes: [...m.values()].map(g => ({ ...g, cuadros: [...g.cuadros], errores: [...new Set(g.errores)].slice(0, 3) })) });
    } catch (e) { res.status(500).json({ error: e.message }); }
});

module.exports = router;
// Expuesto para pruebas unitarias (no afecta el routing).
module.exports._parsePlantilla = parsePlantilla;
module.exports._resumenPorRuta = resumenPorRuta;
