// ============================================================
// /api/planificacion — escrituras del conector MCP "Ferco Planificación".
// Reglas:
//  * Todo en DOS PASOS: la primera llamada devuelve la vista previa y un token; la
//    segunda, con `confirmar: <token>`, aplica. El token vale 15 min, un solo uso, y está
//    atado al usuario, a la herramienta y a los parámetros exactos.
//  * Las escrituras corren con la conexión del app (getPool), pero cada registro lleva la
//    identidad de quien entró por el MCP (autor en el outbox del Sync, archivo del staging,
//    auditoría).
//  * NUNCA se escribe a SAP: agregar/quitar dejan órdenes en CuadroEdicionCola (Sync) y
//    crear cuadros va al staging + robot, igual que la pantalla del app.
// ============================================================
const crypto = require('crypto');
const { getPool, getPlanPool, sql } = require('../db');
const { editarCuadro } = require('./cuadro-crud-api');

const TOKEN_MIN = 15;
const confirmaciones = new Map(); // token -> { userId, herramienta, hash, vence }

function estable(v) {
    if (Array.isArray(v)) return '[' + v.map(estable).join(',') + ']';
    if (v && typeof v === 'object') return '{' + Object.keys(v).sort().map(k => JSON.stringify(k) + ':' + estable(v[k])).join(',') + '}';
    return JSON.stringify(v === undefined ? null : v);
}
function hashParams(params) { return crypto.createHash('sha256').update(estable(params)).digest('hex'); }
function emitirToken(user, herramienta, params) {
    for (const [t, c] of confirmaciones) if (c.vence < Date.now()) confirmaciones.delete(t);
    const token = crypto.randomBytes(16).toString('hex');
    const vence = Date.now() + TOKEN_MIN * 60 * 1000;
    confirmaciones.set(token, { userId: user.id, herramienta, hash: hashParams(params), vence });
    return { token, vence: new Date(vence) };
}
function validarToken(user, herramienta, params, token) {
    const c = confirmaciones.get(String(token || ''));
    if (!c) return 'Token de confirmación inválido o ya usado: pide la vista previa de nuevo';
    if (c.vence < Date.now()) { confirmaciones.delete(token); return 'El token venció (15 min): pide la vista previa de nuevo'; }
    if (c.userId !== user.id || c.herramienta !== herramienta) return 'El token no corresponde a este usuario/herramienta';
    if (c.hash !== hashParams(params)) return 'Los parámetros cambiaron respecto a la vista previa: pide la vista previa de nuevo';
    confirmaciones.delete(token);
    return null;
}
function autorDe(user) { return `${user.nombre || user.usuario} (MCP)`.slice(0, 100); }

// Quién puede escribir: mismo criterio que la pantalla de cuadros/priorización del app.
function requireEscritura(req, res, next) {
    const u = req.planUser;
    if (u.rol === 'Admin' || (u.permisos && u.permisos.includes('priorizacion'))) return next();
    return res.status(403).json({ error: 'Para escribir necesitas el permiso "Priorizacion" en el app de Picking (o ser Admin)' });
}

// Lanza el robot de importación de rutas (staging → cuadros SAP) en UiPath Orchestrator.
async function lanzarRobotRutas() {
    const need = ['UIPATH_TOKEN_URL', 'UIPATH_CLIENT_ID', 'UIPATH_CLIENT_SECRET', 'UIPATH_STARTJOBS_URL', 'UIPATH_RELEASE_KEY', 'UIPATH_ORG_UNIT'];
    const falta = need.filter(k => !process.env[k]);
    if (falta.length) throw new Error('UiPath no configurado en el app: faltan ' + falta.join(', '));
    const tr = await fetch(process.env.UIPATH_TOKEN_URL, {
        method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ grant_type: 'client_credentials', client_id: process.env.UIPATH_CLIENT_ID, client_secret: process.env.UIPATH_CLIENT_SECRET, scope: 'OR.Jobs' })
    });
    if (!tr.ok) throw new Error(`UiPath token HTTP ${tr.status}`);
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

module.exports = function montar(router, h) {
    const { requireCentro, fechaValida, camionDe, leerConfig, validarPlan, fallo } = h;

    // Esquema común de dos pasos
    function dosPasos(herramienta, params, req, res, vistaPrevia, aplicar) {
        if (!req.body.confirmar) {
            const { token, vence } = emitirToken(req.planUser, herramienta, params);
            return res.json({ paso: 'vista_previa', herramienta, vistaPrevia, confirmar: token, vence, nota: `Para aplicar, repite la llamada con los mismos parámetros y confirmar="${token}".` });
        }
        const problema = validarToken(req.planUser, herramienta, params, req.body.confirmar);
        if (problema) return res.status(409).json({ error: problema });
        res.locals.claveOperacion = String(req.body.confirmar);
        return aplicar();
    }

    async function cabeceraCuadro(pool, n, centroId) {
        const r = await pool.request().input('n', sql.Int, n).input('c', sql.Int, centroId).query(`
            SELECT p.ID_RoutePlan, p.RouteNumber, p.RouteName, p.Estado, ISNULL(p.EstadoDespacho,'') AS EstadoDespacho,
                   p.Prioridad, ISNULL(p.Comprometida,0) AS Comprometida, CONVERT(varchar(10), p.FechaPlanDespacho, 23) AS Fecha,
                   CAST(SUM(CASE WHEN ISNULL(m.NoDespachada,0)=0 THEN t.Cantidad*ISNULL(t.UnitWeight,0) ELSE 0 END) AS int) AS Kg,
                   COUNT(DISTINCT CASE WHEN ISNULL(m.NoDespachada,0)=0 THEN m.OV_Number END) AS Documentos
            FROM OrderRoutePlan p LEFT JOIN OrderPickingManagement m ON m.ID_RoutePlan = p.ID_RoutePlan LEFT JOIN OrderPickingTask t ON t.ID_OrderPicking = m.ID_OrderPicking
            WHERE p.RouteNumber = @n AND p.ID_Centro = @c
            GROUP BY p.ID_RoutePlan, p.RouteNumber, p.RouteName, p.Estado, p.EstadoDespacho, p.Prioridad, p.Comprometida, p.FechaPlanDespacho`);
        return r.recordset[0] || null;
    }

    // Resuelve el tipo (OV/TR/RMA) de documentos: parámetro → snapshot del backlog → historial del app.
    async function tiposDe(pool, centroId, docs) {
        const out = {};
        const sin = docs.filter(d => !d.tipo).map(d => d.documento);
        if (sin.length) {
            const r = pool.request().input('c', sql.Int, centroId);
            const inP = h.inList(r, 'd', sin, sql.VarChar(50));
            const q = await r.query(`
                SELECT Documento, Tipo FROM PlanBacklogSnapshot WHERE ID_Centro = @c AND Documento IN (${inP});
                SELECT DISTINCT LTRIM(RTRIM(m.OV_Number)) AS Documento, m.DocType AS Tipo FROM OrderPickingManagement m JOIN OrderRoutePlan p ON p.ID_RoutePlan = m.ID_RoutePlan
                WHERE p.ID_Centro = @c AND LTRIM(RTRIM(m.OV_Number)) IN (${inP})`);
            q.recordsets[1].forEach(x => { out[x.Documento] = x.Tipo; });
            q.recordsets[0].forEach(x => { out[x.Documento] = x.Tipo; });
        }
        return docs.map(d => ({ documento: d.documento, tipo: (d.tipo || out[d.documento] || '').toUpperCase() || null }));
    }
    function normalizarDocs(lista) {
        return (Array.isArray(lista) ? lista : []).map(x => typeof x === 'object' && x ? { documento: String(x.documento || x.doc || '').trim(), tipo: x.tipo ? String(x.tipo).toUpperCase() : null } : { documento: String(x == null ? '' : x).trim(), tipo: null }).filter(x => x.documento);
    }

    // ── Agregar documentos a un cuadro existente ────────────────────────────
    router.post('/cuadros/:numero/agregar', requireCentro, requireEscritura, async (req, res) => {
        try {
            const n = parseInt(req.params.numero);
            const docs = normalizarDocs(req.body.documentos);
            if (!n || !docs.length) return res.status(400).json({ error: 'Indica el cuadro y los documentos' });
            if (req.centro.id !== 3) return res.status(501).json({ error: 'Fase 1: edición de cuadros solo para el HUB Escuintla' });
            const pool = await getPlanPool();
            const cab = await cabeceraCuadro(pool, n, req.centro.id);
            if (!cab) return res.status(404).json({ error: `El cuadro ${n} no existe en el centro` });
            const resueltos = await tiposDe(pool, req.centro.id, docs);
            const sinTipo = resueltos.filter(d => !d.tipo).map(d => d.documento);
            if (sinTipo.length) return res.status(400).json({ error: `No sé si son OV, TR o RMA: ${sinTipo.join(', ')}. Indica el tipo.` });
            const params = { cuadro: n, documentos: resueltos };
            const val = await validarPlan(pool, req.centro, { agregados: [{ cuadro: n, documentos: resueltos.map(d => d.documento) }] });
            const vistaPrevia = { cuadro: { numero: cab.RouteNumber, nombre: cab.RouteName, estado: cab.Estado, kgActual: cab.Kg, documentos: cab.Documentos }, documentos: resueltos, validacion: val };
            if (val.errores.length) return res.status(422).json({ error: 'La validación tiene errores; corrígelos antes de agregar', vistaPrevia });
            return dosPasos('agregar_docs_cuadro', params, req, res, vistaPrevia, async () => {
                const r = await editarCuadro(getPool(), n, { agregar: resueltos.map(d => ({ ov: d.documento, tipo: d.tipo })) }, autorDe(req.planUser));
                res.status(r.status).json({ paso: 'aplicado', ...r.body, siguiente: 'Correr SyncEdicionesCuadro en UiPath para reflejarlo en SAP' });
            });
        } catch (e) { fallo(res, e, 'Error al agregar documentos'); }
    });

    // ── Quitar documentos de un cuadro (eliminar, mover a otro cuadro o a complemento nuevo) ──
    router.post('/cuadros/:numero/quitar', requireCentro, requireEscritura, async (req, res) => {
        try {
            const n = parseInt(req.params.numero);
            const docs = normalizarDocs(req.body.documentos);
            const d = req.body.destino;
            const destino = d === 'nuevo' ? 'nuevo' : (d && typeof d === 'object' && d.cuadro) ? { cuadro: parseInt(d.cuadro) } : (typeof d === 'string' && /^\d+$/.test(d)) ? { cuadro: parseInt(d) } : 'eliminar';
            if (!n || !docs.length) return res.status(400).json({ error: 'Indica el cuadro y los documentos' });
            if (req.centro.id !== 3) return res.status(501).json({ error: 'Fase 1: edición de cuadros solo para el HUB Escuintla' });
            const pool = await getPlanPool();
            const cab = await cabeceraCuadro(pool, n, req.centro.id);
            if (!cab) return res.status(404).json({ error: `El cuadro ${n} no existe en el centro` });
            const resueltos = await tiposDe(pool, req.centro.id, docs);
            const r0 = pool.request().input('id', sql.Int, cab.ID_RoutePlan);
            const inP = h.inList(r0, 'd', resueltos.map(x => x.documento), sql.VarChar(50));
            const enCuadro = (await r0.query(`SELECT LTRIM(RTRIM(OV_Number)) AS Documento, DocType AS Tipo FROM OrderPickingManagement WHERE ID_RoutePlan = @id AND ISNULL(NoDespachada,0) = 0 AND LTRIM(RTRIM(OV_Number)) IN (${inP})`)).recordset;
            const noEstan = resueltos.filter(x => !enCuadro.some(e => e.Documento === x.documento)).map(x => x.documento);
            if (noEstan.length) return res.status(422).json({ error: `No están en el cuadro ${n}: ${noEstan.join(', ')}` });
            const lista = enCuadro.map(e => ({ documento: e.Documento, tipo: e.Tipo }));
            let validacion = null, destinoCab = null;
            if (destino !== 'eliminar' && destino !== 'nuevo') {
                destinoCab = await cabeceraCuadro(pool, destino.cuadro, req.centro.id);
                if (!destinoCab) return res.status(404).json({ error: `El cuadro destino ${destino.cuadro} no existe` });
                validacion = await validarPlan(pool, req.centro, { agregados: [{ cuadro: destino.cuadro, documentos: lista.map(x => x.documento) }] });
                validacion.errores = validacion.errores.filter(e => e.codigo !== 'ya_en_cuadro_vivo'); // salen de este cuadro
                if (validacion.errores.length) return res.status(422).json({ error: 'El cuadro destino no admite estos documentos', validacion });
            }
            const params = { cuadro: n, documentos: lista, destino };
            const vistaPrevia = { cuadro: { numero: cab.RouteNumber, nombre: cab.RouteName, estado: cab.Estado }, documentos: lista,
                destino: destino === 'eliminar' ? 'eliminar (quedan No Despachada; en SAP se quitan del cuadro con el Sync)' : destino === 'nuevo' ? 'complemento nuevo (nombre "... - COMP", lo crea el Sync)' : { cuadro: destinoCab.RouteNumber, nombre: destinoCab.RouteName, kgActual: destinoCab.Kg }, validacion };
            return dosPasos('quitar_docs_cuadro', params, req, res, vistaPrevia, async () => {
                const r = await editarCuadro(getPool(), n, { quitar: lista.map(x => ({ ov: x.documento, tipo: x.tipo })), destino }, autorDe(req.planUser));
                res.status(r.status).json({ paso: 'aplicado', ...r.body, siguiente: 'Correr SyncEdicionesCuadro en UiPath para reflejarlo en SAP' });
            });
        } catch (e) { fallo(res, e, 'Error al quitar documentos'); }
    });

    // ── Crear cuadros nuevos: staging (Supabase) + robot de importación ────────
    router.post('/cuadros', requireCentro, requireEscritura, async (req, res) => {
        try {
            const cuadros = Array.isArray(req.body.cuadros) ? req.body.cuadros : [];
            if (!cuadros.length) return res.status(400).json({ error: 'Envía la lista de cuadros' });
            const base = (process.env.PLAN_STAGING_URL || '').replace(/\/$/, ''), key = process.env.PLAN_STAGING_KEY;
            if (!base || !key) return res.status(503).json({ error: 'Staging no configurado en el app (PLAN_STAGING_URL / PLAN_STAGING_KEY)' });
            const pool = await getPlanPool();
            const plan = cuadros.map((c, i) => ({ nombre: String(c.nombre || '').trim(), fecha: c.fecha ? String(c.fecha) : null, camion: c.camion || null, documentos: normalizarDocs(c.documentos).map(d => d.documento) }));
            for (const c of plan) {
                if (!c.nombre) return res.status(400).json({ error: 'Cada cuadro necesita nombre' });
                if (!c.fecha || !fechaValida(c.fecha)) return res.status(400).json({ error: `Cuadro "${c.nombre}": fecha AAAA-MM-DD requerida` });
            }
            const val = await validarPlan(pool, req.centro, { cuadros: plan });
            if (val.errores.length) return res.status(422).json({ error: 'La validación tiene errores; corrígelos antes de crear', validacion: val });
            // Filas del staging (solo OV/TR; las RMA las rechaza validarPlan)
            const cfg = await leerConfig(pool, req.centro.id);
            const hoy = new Date().toISOString().slice(0, 10);
            const archivo = `MCP ${req.planUser.usuario} ${hoy}`;
            const filas = []; const lotes = [];
            for (const c of plan) {
                const lote = crypto.randomUUID();
                const det = val.cuadros.find(x => x.donde === c.nombre);
                const cap = (det && det.camion) ? String(det.camion).replace(/T$/i, '') : null;
                lotes.push({ lote, ruta: c.nombre, fecha: c.fecha, documentos: c.documentos.length });
                for (const dd of (det ? det.documentos : [])) {
                    filas.push({ lote_id: lote, archivo, ruta: c.nombre, peso: dd.Kg != null ? String(dd.Kg) : null, documento: dd.Documento, tipo: dd.Tipo, capacidad: cap, almacen_origen: req.centro.codigo, fecha_carga: c.fecha, estado: 'pendiente' });
                }
            }
            const params = { cuadros: plan, lanzar_robot: req.body.lanzar_robot !== false };
            const vistaPrevia = { archivo, lotes, filas: filas.length, validacion: val, nota: 'El robot crea un cuadro por ruta en SAP; el app lo ingesta en ~5 min. Después puedes fijar prioridad y fecha.' };
            return dosPasos('crear_cuadros', params, req, res, vistaPrevia, async () => {
                const r = await fetch(`${base}/rest/v1/rutas_staging`, { method: 'POST', headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' }, body: JSON.stringify(filas) });
                if (!r.ok) throw new Error(`Supabase ${r.status}: ${(await r.text()).slice(0, 200)}`);
                let robot = null, errorRobot = null;
                if (params.lanzar_robot) { try { robot = await lanzarRobotRutas(); } catch (e) { errorRobot = e.message; } }
                res.json({ paso: 'aplicado', archivo, lotes, filasInsertadas: filas.length, robot, errorRobot, siguiente: 'Revisar con estado_staging que cada lote quede "completado" y con cola_cuadros que el cuadro aparezca en el app' });
            });
        } catch (e) { fallo(res, e, 'Error al crear cuadros'); }
    });

    // ── Relanzar el robot de importación (p. ej. tras limpiar el staging) ──────
    router.post('/robot/importar-rutas', requireCentro, requireEscritura, async (req, res) => {
        try {
            const params = { accion: 'lanzar_robot_rutas' };
            return dosPasos('lanzar_robot', params, req, res, { nota: 'Lanza Planificacion_SAP_Z5Locales: procesa TODO lo pendiente del staging (todos los equipos). Revisa estado_staging antes.' }, async () => {
                const job = await lanzarRobotRutas();
                res.json({ paso: 'aplicado', job });
            });
        } catch (e) { fallo(res, e, 'Error al lanzar el robot'); }
    });

    // ── Prioridad y fecha de un cuadro (con candado: hay que decir lo que se vio) ──
    router.post('/cuadros/:numero/prioridad', requireCentro, requireEscritura, async (req, res) => {
        try {
            const n = parseInt(req.params.numero);
            const prioridad = req.body.prioridad != null ? parseInt(req.body.prioridad) : null;
            const fechaRaw = req.body.fecha;
            const fecha = fechaRaw === undefined ? undefined : (fechaRaw === null || String(fechaRaw).trim() === '' ? null : String(fechaRaw).trim().slice(0, 10));
            const esperado = req.body.esperado || null;
            if (!n) return res.status(400).json({ error: 'Cuadro inválido' });
            if (prioridad == null && fecha === undefined) return res.status(400).json({ error: 'Indica prioridad y/o fecha' });
            if (prioridad != null && (isNaN(prioridad) || prioridad < 1)) return res.status(400).json({ error: 'Prioridad inválida' });
            if (fecha && !fechaValida(fecha)) return res.status(400).json({ error: 'Fecha inválida (AAAA-MM-DD)' });
            const pool = await getPlanPool();
            const cab = await cabeceraCuadro(pool, n, req.centro.id);
            if (!cab) return res.status(404).json({ error: `El cuadro ${n} no existe en el centro` });
            if (!['Pendiente', 'Iniciado'].includes(cab.Estado)) return res.status(409).json({ error: `El cuadro está ${cab.Estado}` });
            if (cab.Comprometida && req.planUser.rol !== 'Admin') return res.status(403).json({ error: 'El cuadro está Comprometido: solo un Admin lo mueve' });
            if (prioridad != null && cab.Estado === 'Iniciado' && cab.Prioridad != null && prioridad > cab.Prioridad) return res.status(409).json({ error: 'Un cuadro iniciado no baja de prioridad: hay un operario pickeándolo' });
            // Candado: para mover prioridad hay que declarar la prioridad y fecha que se vieron
            if (prioridad != null) {
                if (!esperado || esperado.prioridad === undefined) return res.status(400).json({ error: 'Para cambiar prioridad envía esperado: { prioridad, fecha } con lo que viste en cola_cuadros' });
                if ((esperado.prioridad ?? null) !== (cab.Prioridad ?? null) || (esperado.fecha ?? null) !== (cab.Fecha ?? null)) {
                    return res.status(409).json({ error: 'Alguien cambió este cuadro desde que lo leíste; vuelve a leer la cola', actual: { prioridad: cab.Prioridad, fecha: cab.Fecha } });
                }
            }
            const params = { cuadro: n, prioridad, fecha: fecha === undefined ? '(sin cambio)' : fecha, esperado: { prioridad: cab.Prioridad, fecha: cab.Fecha } };
            const vistaPrevia = { cuadro: { numero: cab.RouteNumber, nombre: cab.RouteName, estado: cab.Estado, comprometida: !!cab.Comprometida }, actual: { prioridad: cab.Prioridad, fecha: cab.Fecha }, nuevo: { prioridad: prioridad ?? cab.Prioridad, fecha: fecha === undefined ? cab.Fecha : fecha }, nota: prioridad != null ? `Los cuadros con prioridad >= ${prioridad} se corren un lugar y luego se compacta la cola` : null };
            return dosPasos('fijar_prioridad_fecha', params, req, res, vistaPrevia, async () => {
                const w = getPool();
                const tx = new sql.Transaction(w);
                await tx.begin();
                try {
                    const rq = () => new sql.Request(tx);
                    const cur = (await rq().input('id', sql.Int, cab.ID_RoutePlan).query(`SELECT Prioridad, CONVERT(varchar(10), FechaPlanDespacho, 23) AS Fecha, Estado FROM OrderRoutePlan WITH (UPDLOCK, HOLDLOCK) WHERE ID_RoutePlan = @id`)).recordset[0];
                    if (prioridad != null && ((cur.Prioridad ?? null) !== (cab.Prioridad ?? null) || (cur.Fecha ?? null) !== (cab.Fecha ?? null))) { await tx.rollback(); return res.status(409).json({ error: 'El cuadro cambió justo ahora; vuelve a leer la cola' }); }
                    if (prioridad != null) {
                        await rq().input('c', sql.Int, req.centro.id).input('p', sql.Int, prioridad).input('id', sql.Int, cab.ID_RoutePlan)
                            .query(`UPDATE OrderRoutePlan SET Prioridad = Prioridad + 1 WHERE ID_Centro = @c AND Estado IN ('Pendiente','Iniciado') AND Prioridad >= @p AND ID_RoutePlan <> @id;
                                    UPDATE OrderRoutePlan SET Prioridad = @p WHERE ID_RoutePlan = @id`);
                        if (req.centro.id === 3) await rq().execute('SP_NormalizeEscuintlaPriorities');
                        else await rq().input('c', sql.Int, req.centro.id).query(`
                            ;WITH k AS (SELECT ID_RoutePlan, ROW_NUMBER() OVER (ORDER BY Prioridad, FechaPlanificacion DESC, ID_RoutePlan) AS nueva FROM OrderRoutePlan WHERE ID_Centro = @c AND Estado IN ('Pendiente','Iniciado') AND Prioridad IS NOT NULL)
                            UPDATE r SET r.Prioridad = k.nueva FROM OrderRoutePlan r JOIN k ON k.ID_RoutePlan = r.ID_RoutePlan WHERE r.Prioridad <> k.nueva`);
                    }
                    if (fecha !== undefined) {
                        await rq().input('id', sql.Int, cab.ID_RoutePlan).input('f', sql.VarChar(10), fecha)
                            .query(`UPDATE OrderRoutePlan SET FechaPlanDespacho = CASE WHEN @f IS NULL THEN NULL ELSE CONVERT(date, @f, 23) END WHERE ID_RoutePlan = @id`);
                    }
                    await tx.commit();
                } catch (e) { try { await tx.rollback(); } catch { /* ya revertida */ } throw e; }
                const despues = await cabeceraCuadro(pool, n, req.centro.id);
                res.json({ paso: 'aplicado', cuadro: n, antes: { prioridad: cab.Prioridad, fecha: cab.Fecha }, ahora: { prioridad: despues.Prioridad, fecha: despues.Fecha }, autor: autorDe(req.planUser) });
            });
        } catch (e) { fallo(res, e, 'Error al fijar prioridad/fecha'); }
    });

    // ── Comprometida (motivo obligatorio) ──────────────────────────────────────
    router.post('/cuadros/:numero/comprometida', requireCentro, requireEscritura, async (req, res) => {
        try {
            const n = parseInt(req.params.numero);
            const valor = !!req.body.comprometida;
            const motivo = String(req.body.motivo || '').trim();
            if (!n) return res.status(400).json({ error: 'Cuadro inválido' });
            if (motivo.length < 5) return res.status(400).json({ error: 'Indica el motivo (quién lo pidió y por qué; un escalamiento por sí solo no basta)' });
            const pool = await getPlanPool();
            const cab = await cabeceraCuadro(pool, n, req.centro.id);
            if (!cab) return res.status(404).json({ error: `El cuadro ${n} no existe en el centro` });
            if (!['Pendiente', 'Iniciado'].includes(cab.Estado)) return res.status(409).json({ error: `El cuadro está ${cab.Estado}` });
            if (!!cab.Comprometida === valor) return res.json({ paso: 'sin_cambio', cuadro: n, comprometida: valor });
            if (cab.Comprometida && !valor && req.planUser.rol !== 'Admin') return res.status(403).json({ error: 'Desmarcar una Comprometida requiere Admin' });
            const params = { cuadro: n, comprometida: valor, motivo };
            const vistaPrevia = { cuadro: { numero: cab.RouteNumber, nombre: cab.RouteName, estado: cab.Estado, prioridad: cab.Prioridad, fecha: cab.Fecha }, actual: !!cab.Comprometida, nuevo: valor, motivo };
            return dosPasos('marcar_comprometida', params, req, res, vistaPrevia, async () => {
                await getPool().request().input('id', sql.Int, cab.ID_RoutePlan).input('v', sql.Bit, valor ? 1 : 0).query(`UPDATE OrderRoutePlan SET Comprometida = @v WHERE ID_RoutePlan = @id`);
                res.json({ paso: 'aplicado', cuadro: n, comprometida: valor, motivo, autor: autorDe(req.planUser) });
            });
        } catch (e) { fallo(res, e, 'Error al marcar Comprometida'); }
    });
};
