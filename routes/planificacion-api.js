// ============================================================
// /api/planificacion — API de lectura del conector MCP "Ferco Planificación" (fase 1).
// Autenticación por pase (middleware/bearer.js), nunca por sesión. Solo lectura:
// ningún endpoint de este módulo escribe en la BD salvo la auditoría.
// ============================================================
const express = require('express');
const router = express.Router();
const { getPool, getPlanPool, sql } = require('../db');
const { requireBearer } = require('../middleware/bearer');
const esc = require('./escalamientos-api');
// Regla de seguridad: este módulo NUNCA consulta [server-sql] (SAP/Lisa) con SQL propio.
// Todo lo que viene de SAP o Lisa sale de los SP de sql/Planificacion_04_SP_Lectura.sql,
// acotados a un documento, un cuadro o una lista de máximo 10 documentos.

const CENTRO_ESCALAMIENTOS = 3; // el módulo de escalamientos es del HUB Escuintla

// ── Auditoría: toda llamada, también las rechazadas por el pase ─────────────
router.use((req, res, next) => {
    const t0 = Date.now();
    res.on('finish', () => {
        const u = req.planUser;
        const parametros = JSON.stringify({ query: req.query, body: req.method === 'GET' ? undefined : req.body });
        getPool().request()
            .input('idu', sql.Int, u ? u.id : null)
            .input('email', sql.NVarChar(200), u ? u.email : (req.planEmail || null))
            .input('metodo', sql.VarChar(10), req.method)
            .input('ruta', sql.NVarChar(200), (req.baseUrl + req.path).slice(0, 200))
            .input('params', sql.NVarChar(sql.MAX), parametros.slice(0, 8000))
            .input('centro', sql.Int, req.centro ? req.centro.id : null)
            .input('estado', sql.Int, res.statusCode)
            .input('ms', sql.Int, Date.now() - t0)
            .input('error', sql.NVarChar(1000), res.locals.error ? String(res.locals.error).slice(0, 1000) : null)
            .input('clave', sql.NVarChar(100), res.locals.claveOperacion || null)
            .query(`INSERT INTO MCP_Auditoria (ID_Usuario, Email, Metodo, Ruta, Parametros, ID_Centro, EstadoHttp, DuracionMs, Error, ClaveOperacion)
                    VALUES (@idu, @email, @metodo, @ruta, @params, @centro, @estado, @ms, @error, @clave)`)
            .catch(e => console.error('MCP_Auditoria:', e.message));
    });
    next();
});
router.use(requireBearer);

// ── Helpers ─────────────────────────────────────────────────────────────────
function fallo(res, err, msg) {
    console.error('planificacion:', msg, err);
    res.locals.error = err && err.message ? err.message : String(err);
    res.status(500).json({ error: msg });
}

// Centro pedido (?centro= o body.centro); si el usuario tiene uno solo, ese.
function requireCentro(req, res, next) {
    const u = req.planUser;
    const pedido = parseInt(req.query.centro || (req.body && req.body.centro));
    const c = pedido ? u.centros.find(x => x.id === pedido) : (u.centros.length === 1 ? u.centros[0] : null);
    if (!c) {
        return res.status(pedido ? 403 : 400).json({
            error: pedido ? 'No tienes acceso a ese centro' : 'Indica el centro (parámetro centro)',
            centros: u.centros
        });
    }
    req.centro = c;
    next();
}

function fechaValida(s) { return /^\d{4}-\d{2}-\d{2}$/.test(String(s || '')); }
function hoyStr() {
    const d = new Date();
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
function inList(request, prefix, values, type) {
    return values.map((v, i) => { request.input(prefix + i, type, v); return '@' + prefix + i; }).join(',');
}

// Estado de documentos (Pendiente / Programado / Finalizado) cruzando el app (local) y los
// cuadros de SAP (SP_MCP_CuadrosDeDocumentos, en lotes de LOTE_SP). Misma lógica que escalamientos-api.
async function estadosDocumentos(pool, centro, docs) {
    const list = [...new Set(docs.map(o => String(o).trim()).filter(Boolean))];
    const map = {}; list.forEach(o => { map[o] = { rank: 0, desp: null, cuadroFin: null, cuadroAny: null }; });
    if (!list.length) return map;
    const merge = (k, rk, desp, cuadroFin, cuadroAny) => {
        const m = map[k]; if (!m) return;
        if (rk > m.rank) m.rank = rk;
        if (desp && (!m.desp || new Date(desp) > new Date(m.desp))) m.desp = desp;
        if (cuadroFin && !m.cuadroFin) m.cuadroFin = cuadroFin;
        if (cuadroAny && (!m.cuadroAny || cuadroAny > m.cuadroAny)) m.cuadroAny = cuadroAny;
    };
    const r = pool.request().input('c', sql.Int, centro.id);
    const inP = inList(r, 'a', list, sql.VarChar(50));
    const a = await r.query(`
        SELECT LTRIM(RTRIM(opm.OV_Number)) ov,
               MAX(CASE WHEN orp.EstadoDespacho='Finalizado' THEN 2 ELSE 1 END) rk,
               MAX(CASE WHEN orp.EstadoDespacho='Finalizado' THEN orp.FechaDespachoFin END) desp,
               MAX(CASE WHEN orp.EstadoDespacho='Finalizado' THEN orp.RouteNumber END) cuadroFin,
               MAX(orp.RouteNumber) cuadroAny
        FROM OrderPickingManagement opm JOIN OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
        WHERE orp.ID_Centro = @c AND LTRIM(RTRIM(opm.OV_Number)) IN (${inP}) AND ISNULL(opm.NoDespachada, 0) = 0
        GROUP BY LTRIM(RTRIM(opm.OV_Number))`);
    a.recordset.forEach(x => merge(String(x.ov).trim(), x.rk, x.desp, x.cuadroFin, x.cuadroAny));
    // Fase 1: solo el app (sin cuadros de SAP en vivo). Un doc en un cuadro solo de SAP (p. ej. CEDI Z5) se verá como Pendiente.
    Object.keys(map).forEach(k => { const m = map[k]; m.cuadro = m.rank === 2 ? (m.cuadroFin || m.cuadroAny) : m.cuadroAny; });
    return map;
}

// Tipo de camión según el nombre del cuadro ("02NOV MIXCO 3.5T", "CEDI TOTO 4 22T").
function camionDe(nombre) {
    const m = String(nombre || '').toUpperCase().match(/(\d+(?:\.\d)?)\s*TN?\b/);
    return m ? `${m[1]}T` : null;
}
// Grupo del día: expos (R46/R47), tiendas/plataformas (mayoría de kg en TR) o última milla.
function grupoDe(c) {
    const n = String(c.RouteName || '').toUpperCase();
    if (/\bEXPO\b|^R4[67]\b/.test(n)) return 'expos';
    if (c.KgPlan > 0 && c.KgTR * 2 >= c.KgPlan) return 'tiendas';
    return 'ultima_milla';
}

async function leerCola(pool, idCentro, { hasta, sinFecha = true } = {}) {
    const r = pool.request().input('c', sql.Int, idCentro);
    let filtroFecha = '';
    if (hasta) {
        r.input('hasta', sql.VarChar(10), hasta);
        filtroFecha = sinFecha
            ? `AND (p.FechaPlanDespacho IS NULL OR p.FechaPlanDespacho <= CONVERT(date, @hasta, 23))`
            : `AND p.FechaPlanDespacho <= CONVERT(date, @hasta, 23)`;
    }
    const q = await r.query(`
        SELECT p.RouteNumber, p.RouteName, CONVERT(varchar(10), p.FechaPlanDespacho, 23) AS Fecha,
               p.Prioridad, ISNULL(p.Comprometida, 0) AS Comprometida, p.Estado, ISNULL(p.EstadoDespacho, '') AS EstadoDespacho,
               CAST(SUM(CASE WHEN ISNULL(m.NoDespachada,0)=0 THEN t.Cantidad*ISNULL(t.UnitWeight,0) ELSE 0 END) AS int) AS KgPlan,
               CAST(SUM(CASE WHEN ISNULL(m.NoDespachada,0)=0 THEN t.CantidadPendiente*ISNULL(t.UnitWeight,0) ELSE 0 END) AS int) AS KgPorPickear,
               CAST(SUM(CASE WHEN ISNULL(m.NoDespachada,0)=0 AND m.DocType IN ('TR','RESURTIDO') THEN t.Cantidad*ISNULL(t.UnitWeight,0) ELSE 0 END) AS int) AS KgTR,
               COUNT(DISTINCT CASE WHEN ISNULL(m.NoDespachada,0)=0 THEN m.ClienteNombre END) AS Paradas,
               COUNT(DISTINCT CASE WHEN ISNULL(m.NoDespachada,0)=0 THEN m.OV_Number END) AS Documentos
        FROM OrderRoutePlan p
        LEFT JOIN OrderPickingManagement m ON m.ID_RoutePlan = p.ID_RoutePlan
        LEFT JOIN OrderPickingTask t ON t.ID_OrderPicking = m.ID_OrderPicking
        WHERE p.ID_Centro = @c AND p.Estado IN ('Pendiente', 'Iniciado') ${filtroFecha}
        GROUP BY p.RouteNumber, p.RouteName, p.FechaPlanDespacho, p.Prioridad, p.Comprometida, p.Estado, p.EstadoDespacho
        ORDER BY CASE WHEN p.Prioridad IS NULL THEN 1 ELSE 0 END, p.Prioridad, p.RouteNumber`);
    return q.recordset.map(c => ({
        ...c, Comprometida: !!c.Comprometida, Camion: camionDe(c.RouteName), Grupo: grupoDe(c)
    }));
}

async function leerConfig(pool, idCentro) {
    const r = await pool.request().input('c', sql.Int, idCentro).query(`
        SELECT CorteToneladasDia, ToneladasHora, CONVERT(varchar(5), HoraInicio, 108) AS HoraInicio,
               PresupuestoTiendasTon, RutasPequenasDia, VentanaCandadoHoras, OrdenGrupos
        FROM ConfigPlanDiario WHERE ID_Centro = @c;
        SELECT Tipo, CapacidadKg, MaxParadas, SoloClienteUnico FROM ConfigCamion WHERE ID_Centro = @c`);
    return { dia: r.recordsets[0][0] || null, camiones: r.recordsets[1] };
}

// ── Endpoints ───────────────────────────────────────────────────────────────

// Quién soy: nombre, rol y centros que puedo consultar.
router.get('/yo', (req, res) => {
    const u = req.planUser;
    res.json({ nombre: u.nombre, email: u.email, rol: u.rol, centros: u.centros });
});

// Cola de cuadros Pendiente/Iniciado, en orden de prioridad.
router.get('/cola', requireCentro, async (req, res) => {
    try {
        const hasta = fechaValida(req.query.hasta) ? req.query.hasta : null;
        const sinFecha = req.query.sin_fecha !== 'false';
        const pool = await getPlanPool();
        const cuadros = await leerCola(pool, req.centro.id, { hasta, sinFecha });
        const porFecha = {};
        for (const c of cuadros) {
            const k = c.Fecha || 'sin_fecha';
            const f = porFecha[k] || (porFecha[k] = { cuadros: 0, kgPlan: 0, kgPorPickear: 0, iniciados: 0 });
            f.cuadros++; f.kgPlan += c.KgPlan; f.kgPorPickear += c.KgPorPickear; if (c.Estado === 'Iniciado') f.iniciados++;
        }
        res.json({ centro: req.centro.id, corte: new Date(), resumenPorFecha: porFecha, cuadros });
    } catch (e) { fallo(res, e, 'Error al leer la cola'); }
});

// Detalle de un cuadro: documentos, kg y avance de picking/entrega en Lisa.
router.get('/cuadros/:numero', async (req, res) => {
    try {
        const numero = parseInt(req.params.numero);
        if (!numero) return res.status(400).json({ error: 'Número de cuadro inválido' });
        const pool = await getPlanPool();
        const h = await pool.request().input('n', sql.Int, numero).query(`
            SELECT ID_RoutePlan, RouteNumber, RouteName, ID_Centro, Estado, ISNULL(EstadoDespacho,'') AS EstadoDespacho,
                   Prioridad, ISNULL(Comprometida,0) AS Comprometida, CONVERT(varchar(10), FechaPlanDespacho, 23) AS Fecha
            FROM OrderRoutePlan WHERE RouteNumber = @n`);
        const cab = h.recordset.find(x => req.planUser.centros.some(c => c.id === x.ID_Centro));
        if (!cab) return res.status(404).json({ error: 'Cuadro no encontrado en tus centros' });
        req.centro = req.planUser.centros.find(c => c.id === cab.ID_Centro);

        const d = await pool.request().input('id', sql.Int, cab.ID_RoutePlan).query(`
            SELECT LTRIM(RTRIM(m.OV_Number)) AS Documento, m.DocType AS Tipo, m.ClienteNombre AS Cliente,
                   CAST(ISNULL(m.NoDespachada,0) AS bit) AS NoDespachada,
                   CAST(SUM(t.Cantidad*ISNULL(t.UnitWeight,0)) AS int) AS KgPlan,
                   CAST(SUM(t.CantidadPendiente*ISNULL(t.UnitWeight,0)) AS int) AS KgPorPickear,
                   COUNT(t.ID_OrderPicking) AS Lineas
            FROM OrderPickingManagement m
            LEFT JOIN OrderPickingTask t ON t.ID_OrderPicking = m.ID_OrderPicking
            WHERE m.ID_RoutePlan = @id
            GROUP BY m.OV_Number, m.DocType, m.ClienteNombre, m.NoDespachada
            ORDER BY m.DocType, m.OV_Number`);
        const docs = d.recordset;

        // Bultos (licencias) ya capturados por el app desde el log de picking (local; no consulta Lisa)
        const bultos = {};
        {
            const q = await pool.request().input('id', sql.Int, cab.ID_RoutePlan).input('c', sql.Int, cab.ID_Centro).query(`
                SELECT LTRIM(RTRIM(db.OV_Number)) AS Doc, COUNT(DISTINCT db.Licencia) AS Bultos, MAX(db.FechaCaptura) AS Ultimo
                FROM DespachoBulto db
                WHERE db.ID_Centro = @c AND LTRIM(RTRIM(db.OV_Number)) IN (SELECT LTRIM(RTRIM(m.OV_Number)) FROM OrderPickingManagement m WHERE m.ID_RoutePlan = @id)
                GROUP BY LTRIM(RTRIM(db.OV_Number))`);
            q.recordset.forEach(x => { bultos[String(x.Doc)] = x; });
        }
        res.json({
            cuadro: { ...cab, Comprometida: !!cab.Comprometida, Camion: camionDe(cab.RouteName) },
            documentos: docs.map(x => {
                const bu = bultos[String(x.Documento).trim()];
                return { ...x, BultosCapturados: bu ? bu.Bultos : 0, UltimaCaptura: bu ? bu.Ultimo : null };
            })
        });
    } catch (e) { fallo(res, e, 'Error al leer el cuadro'); }
});

// Detalle de un documento (OV, TR o RMA): estado en SAP, líneas y stock, cuadros, Lisa, escalamientos.
router.get('/documentos/:doc', requireCentro, async (req, res) => {
    try {
        const num = parseInt(String(req.params.doc).replace(/\D/g, ''));
        if (!num) return res.status(400).json({ error: 'Documento inválido' });
        const tipoPedido = ['OV', 'TR', 'RMA'].includes(String(req.query.tipo || '').toUpperCase()) ? req.query.tipo.toUpperCase() : null;
        if (req.centro.pais !== 'GT') return res.status(501).json({ error: 'Fase 1: detalle de documento solo para Guatemala' });
        const pool = await getPlanPool();
        const whs = req.centro.codigo;
        // Fase 1 'light': sin consultas en vivo a SAP/Lisa. Fuente: snapshot del backlog + historial del app + escalamientos + bultos capturados.
        const docStr = String(num);
        const q = await pool.request().input('s', sql.VarChar(50), docStr).input('c', sql.Int, req.centro.id).input('tipo', sql.VarChar(5), tipoPedido).query(`
            SELECT TOP 1 *, CONVERT(varchar(16), Corte, 120) AS CorteTxt FROM PlanBacklogSnapshot WHERE ID_Centro = @c AND Documento = @s AND (@tipo IS NULL OR Tipo = @tipo);
            SELECT p.RouteNumber AS Cuadro, p.RouteName AS Nombre, p.Estado, ISNULL(p.EstadoDespacho,'') AS EstadoDespacho, m.DocType AS Tipo, m.ClienteNombre AS Cliente,
                   CAST(ISNULL(m.NoDespachada,0) AS bit) AS NoDespachada, CONVERT(varchar(10), p.FechaPlanDespacho, 23) AS Fecha, p.Prioridad,
                   CAST(SUM(t.Cantidad*ISNULL(t.UnitWeight,0)) AS int) AS Kg, CAST(SUM(t.CantidadPendiente*ISNULL(t.UnitWeight,0)) AS int) AS KgPorPickear
            FROM OrderPickingManagement m JOIN OrderRoutePlan p ON p.ID_RoutePlan = m.ID_RoutePlan LEFT JOIN OrderPickingTask t ON t.ID_OrderPicking = m.ID_OrderPicking
            WHERE LTRIM(RTRIM(m.OV_Number)) = @s AND p.ID_Centro = @c AND (@tipo IS NULL OR m.DocType = @tipo)
            GROUP BY p.RouteNumber, p.RouteName, p.Estado, p.EstadoDespacho, m.DocType, m.ClienteNombre, m.NoDespachada, p.FechaPlanDespacho, p.Prioridad
            ORDER BY p.RouteNumber DESC;
            SELECT ID_Escalamiento, CONVERT(varchar(10), FechaRequerida, 23) AS FechaRequerida, CreadoPor, CONVERT(varchar(16), FechaCreacion, 120) AS Creado
            FROM Escalamientos WHERE LTRIM(RTRIM(OV_Number)) = @s AND Archivado = 0;
            SELECT Licencia, DocType AS Tipo, CAST(SUM(Cantidad) AS decimal(18,2)) AS Cantidad, MAX(FechaCaptura) AS Capturado
            FROM DespachoBulto WHERE ID_Centro = @c AND LTRIM(RTRIM(OV_Number)) = @s GROUP BY Licencia, DocType`);
        const snap = q.recordsets[0][0] || null, cuadrosApp = q.recordsets[1], escalamientos = q.recordsets[2], bultosCapturados = q.recordsets[3];
        if (!snap && !cuadrosApp.length && !escalamientos.length) return res.status(404).json({ error: `El documento ${num} no está en el backlog sin cuadro ni en ningún cuadro del app (centro ${req.centro.codigo}). Si es nuevo, entra en el próximo corte (15 min).` });
        const tipo = snap ? snap.Tipo : (cuadrosApp[0] ? cuadrosApp[0].Tipo : null);
        const vivo = cuadrosApp.find(c => ['Pendiente', 'Iniciado'].includes(c.Estado) && !c.NoDespachada);
        const backlog = snap ? Object.assign({}, snap, { Corte: snap.CorteTxt }) : null; if (backlog) delete backlog.CorteTxt;
        return res.json({ tipo, situacion: snap ? `sin cuadro (${snap.Categoria})` : vivo ? `en cuadro ${vivo.Cuadro} (${vivo.Estado})` : 'estuvo en cuadros ya finalizados o fue removido',
            backlog, cuadrosApp, escalamientos, bultosCapturados,
            nota: 'Fase 1: sin consulta en vivo a SAP/Lisa. El avance de picking está en cuadrosApp.KgPorPickear; PickeadoLisa/EntregadoLisa vienen del snapshot.' });
    } catch (e) { fallo(res, e, 'Error al leer el documento'); }
});

// Ritmo del piso: toneladas y cuadros finalizados por día.
router.get('/ritmo', requireCentro, async (req, res) => {
    try {
        const dias = Math.min(Math.max(parseInt(req.query.dias) || 7, 1), 60);
        const pool = await getPlanPool();
        const r = await pool.request().input('c', sql.Int, req.centro.id).input('dias', sql.Int, dias).query(`
            SELECT CONVERT(varchar(10), p.FechaFin, 23) AS Fecha, COUNT(DISTINCT p.RouteNumber) AS Cuadros,
                   CAST(SUM(CASE WHEN ISNULL(m.NoDespachada,0)=0 THEN t.Cantidad*ISNULL(t.UnitWeight,0) ELSE 0 END)/1000.0 AS decimal(9,1)) AS Toneladas
            FROM OrderRoutePlan p
            JOIN OrderPickingManagement m ON m.ID_RoutePlan = p.ID_RoutePlan
            JOIN OrderPickingTask t ON t.ID_OrderPicking = m.ID_OrderPicking
            WHERE p.ID_Centro = @c AND p.Estado = 'Finalizado' AND p.FechaFin >= DATEADD(day, -@dias, CAST(GETDATE() AS date))
            GROUP BY CONVERT(varchar(10), p.FechaFin, 23)
            ORDER BY Fecha`);
        res.json({ centro: req.centro.id, dias: r.recordset });
    } catch (e) { fallo(res, e, 'Error al leer el ritmo'); }
});

// Estado del Sync de ediciones de cuadros hacia SAP.
router.get('/sync', requireCentro, async (req, res) => {
    try {
        const pool = await getPlanPool();
        const r = await pool.request().input('c', sql.Int, req.centro.id).query(`
            SELECT v.ID_Edicion, v.RouteNumber AS Cuadro, v.Accion, v.OV_Number AS Documento, v.DocType AS Tipo,
                   v.Estado, v.Intentos, v.Usuario, CONVERT(varchar(16), v.FechaCreacion, 120) AS Creado
            FROM vw_CuadroEdicionPendiente v
            WHERE EXISTS (SELECT 1 FROM OrderRoutePlan p WHERE p.RouteNumber = v.RouteNumber AND p.ID_Centro = @c)
            ORDER BY v.ID_Edicion;
            SELECT c.Estado, COUNT(*) AS Ediciones
            FROM CuadroEdicionCola c
            WHERE c.FechaCreacion >= DATEADD(day, -7, GETDATE())
              AND EXISTS (SELECT 1 FROM OrderRoutePlan p WHERE p.RouteNumber = c.RouteNumber AND p.ID_Centro = @c)
            GROUP BY c.Estado`);
        res.json({ centro: req.centro.id, pendientes: r.recordsets[0], ultimos7Dias: r.recordsets[1] });
    } catch (e) { fallo(res, e, 'Error al leer el Sync'); }
});

// Escalamientos abiertos con su estado derivado (Pendiente / Programado / Finalizado).
router.get('/escalamientos', requireCentro, async (req, res) => {
    try {
        if (req.centro.id !== CENTRO_ESCALAMIENTOS) return res.json({ centro: req.centro.id, escalamientos: [] });
        const pool = await getPlanPool();
        const r = await pool.request().query(`
            SELECT e.ID_Escalamiento, LTRIM(RTRIM(e.OV_Number)) AS Documento, e.DocType AS Tipo,
                   CONVERT(varchar(10), e.FechaRequerida, 23) AS FechaRequerida, e.ClienteNombre AS Cliente,
                   e.PesoKg, e.TotalLineas, e.CreadoPor, CONVERT(varchar(16), e.FechaCreacion, 120) AS Creado,
                   (SELECT COUNT(*) FROM EscalamientoComentarios c WHERE c.ID_Escalamiento = e.ID_Escalamiento) AS Comentarios
            FROM Escalamientos e WHERE e.Archivado = 0 ORDER BY e.FechaRequerida, e.FechaCreacion`);
        const estados = await estadosDocumentos(pool, req.centro, r.recordset.map(x => x.Documento));
        const lista = r.recordset.map(x => {
            const st = estados[x.Documento] || { rank: 0, cuadro: null };
            return { ...x, Estado: esc.ESTADO_NOMBRE[st.rank], Cuadro: st.cuadro || null };
        }).filter(x => req.query.incluir_finalizados === 'true' || x.Estado !== 'Finalizado');
        res.json({ centro: req.centro.id, escalamientos: lista });
    } catch (e) { fallo(res, e, 'Error al leer los escalamientos'); }
});

// Capacidad del día: toneladas por grupo contra el corte, hora estimada de cada cambio de grupo.
// Incluye lo atrasado (fecha anterior aún pendiente). No escribe nada.
router.get('/capacidad-dia', requireCentro, async (req, res) => {
    try {
        const fecha = fechaValida(req.query.fecha) ? req.query.fecha : hoyStr();
        const pool = await getPlanPool();
        const [cola, cfg] = await Promise.all([
            leerCola(pool, req.centro.id, { hasta: fecha, sinFecha: false }),
            leerConfig(pool, req.centro.id)
        ]);
        if (!cfg.dia) return res.status(404).json({ error: 'El centro no tiene configuración de plan diario (ConfigPlanDiario)' });
        const orden = cfg.dia.OrdenGrupos.split(',').map(s => s.trim());
        const pequenos = new Set(cfg.camiones.filter(c => c.CapacidadKg <= 9500).map(c => c.Tipo));
        const grupos = {};
        for (const g of orden) grupos[g] = { cuadros: 0, toneladasPorPickear: 0, atrasados: 0 };
        let rutasPequenas = 0;
        for (const c of cola) {
            const g = grupos[c.Grupo] || (grupos[c.Grupo] = { cuadros: 0, toneladasPorPickear: 0, atrasados: 0 });
            g.cuadros++; g.toneladasPorPickear += c.KgPorPickear / 1000;
            if (c.Fecha && c.Fecha < fecha) g.atrasados++;
            if (c.Grupo === 'ultima_milla' && pequenos.has(c.Camion)) rutasPequenas++;
        }
        // Hora estimada: iniciados primero (ya en curso), luego los grupos en el orden configurado.
        const [hh, mm] = cfg.dia.HoraInicio.split(':').map(Number);
        let acumulado = 0;
        const tramos = [];
        for (const g of orden) {
            const t = grupos[g] ? grupos[g].toneladasPorPickear : 0;
            const desde = acumulado; acumulado += t;
            const hora = h => { const min = Math.round(hh * 60 + mm + (h / cfg.dia.ToneladasHora) * 60); return `${String(Math.floor(min / 60) % 24).padStart(2, '0')}:${String(min % 60).padStart(2, '0')}${min >= 1440 ? ' (+1 día)' : ''}`; };
            tramos.push({ grupo: g, toneladas: Math.round(t * 10) / 10, empiezaAprox: hora(desde), terminaAprox: hora(acumulado) });
        }
        for (const g of Object.keys(grupos)) grupos[g].toneladasPorPickear = Math.round(grupos[g].toneladasPorPickear * 10) / 10;
        res.json({
            centro: req.centro.id, fecha,
            corteToneladas: Number(cfg.dia.CorteToneladasDia), toneladasHora: Number(cfg.dia.ToneladasHora),
            toneladasPorPickear: Math.round(acumulado * 10) / 10,
            excedenteToneladas: Math.max(0, Math.round((acumulado - cfg.dia.CorteToneladasDia) * 10) / 10),
            grupos, tramos,
            rutasPequenasUltimaMilla: rutasPequenas, metaRutasPequenas: cfg.dia.RutasPequenasDia,
            nota: 'Grupo estimado por el nombre y la mezcla OV/TR del cuadro; las expos las ordena el usuario.'
        });
    } catch (e) { fallo(res, e, 'Error al calcular la capacidad del día'); }
});

// ── Validación de un plan (no escribe) ──────────────────────────────────────
// body: { centro, cuadros: [{ nombre, fecha, camion?, documentos: [...] }], agregados: [{ cuadro, documentos: [...] }] }
function paradaDe(d) {
    if (d.Tipo === 'TR') return (d.DestinoNombre || d.AlmacenDestino || d.Cliente || '').trim() || '(sin destino)';
    return (d.Cliente || '').trim() || '(sin cliente)';
}
// Valida una propuesta (cuadros nuevos y agregados) SIN escribir. Fase 1 'light': solo contra el
// snapshot del backlog y el app; un documento que no esté en el snapshot se reporta, no se consulta SAP.
async function validarPlan(pool, centro, body) {
    {
        const cuadrosNuevos = Array.isArray(body.cuadros) ? body.cuadros : [];
        const agregados = Array.isArray(body.agregados) ? body.agregados : [];
        const cfg = await leerConfig(pool, centro.id);
        const camiones = {}; cfg.camiones.forEach(c => { camiones[c.Tipo] = c; });
        const errores = [], avisos = [];
        const err = (donde, codigo, detalle) => errores.push({ donde, codigo, detalle });
        const aviso = (donde, codigo, detalle) => avisos.push({ donde, codigo, detalle });

        // Documentos del plan, repetidos y vacíos
        const vistos = {};
        const todos = [];
        const listar = (donde, docs) => (Array.isArray(docs) ? docs : []).map(x => {
            const d = String(x == null ? '' : x).trim();
            if (!d) { err(donde, 'documento_vacio', 'Hay un documento vacío en la lista'); return null; }
            if (!/^\d+$/.test(d)) { err(donde, 'documento_invalido', `"${d}" no es un número de documento`); return null; }
            if (vistos[d]) err(donde, 'documento_repetido', `${d} también está en ${vistos[d]}`); else vistos[d] = donde;
            todos.push(d);
            return d;
        }).filter(Boolean);
        const nuevos = cuadrosNuevos.map((c, i) => ({ ...c, donde: c.nombre || `cuadro #${i + 1}`, docs: listar(c.nombre || `cuadro #${i + 1}`, c.documentos) }));
        const adds = agregados.map(a => ({ ...a, donde: `cuadro ${a.cuadro}`, docs: listar(`cuadro ${a.cuadro}`, a.documentos) }));
        const unicos = [...new Set(todos)];

        // Datos de cada documento: snapshot del backlog, cuadros vivos del app y (si no está en el snapshot) SAP
        const info = {};
        if (unicos.length) {
            const r1 = pool.request().input('c', sql.Int, centro.id);
            const in1 = inList(r1, 'd', unicos, sql.VarChar(20));
            const s = await r1.query(`
                SELECT Tipo, Documento, Cliente, AlmacenDestino, DestinoNombre, Kg, LineasSinStock, Categoria, Modalidad, PickeadoLisa,
                       CONVERT(varchar(10), EscalamientoFecha, 23) AS EscalamientoFecha, CONVERT(varchar(10), FechaEntrega, 23) AS FechaEntrega
                FROM PlanBacklogSnapshot WHERE ID_Centro = @c AND Documento IN (${in1});
                SELECT LTRIM(RTRIM(m.OV_Number)) AS Documento, p.RouteNumber, p.Estado
                FROM OrderPickingManagement m JOIN OrderRoutePlan p ON p.ID_RoutePlan = m.ID_RoutePlan
                WHERE p.ID_Centro = @c AND p.Estado IN ('Pendiente','Iniciado') AND ISNULL(m.NoDespachada,0) = 0 AND LTRIM(RTRIM(m.OV_Number)) IN (${in1})`);
            s.recordsets[0].forEach(d => { info[d.Documento] = { ...d, origen: 'backlog' }; });
            const vivos = {};
            s.recordsets[1].forEach(v => { (vivos[v.Documento] = vivos[v.Documento] || []).push(v); });
            const faltan = unicos.filter(d => !info[d]);
            if (faltan.length) {
                // Fase 1: no se consulta SAP en vivo. Lo que no está en el snapshot se reporta con el corte.
                const corte = (await pool.request().input('c', sql.Int, centro.id).query(`SELECT TOP 1 CONVERT(varchar(16), Corte, 120) AS Corte FROM PlanBacklogCorte WHERE ID_Centro = @c AND Error IS NULL ORDER BY ID_Corte DESC`)).recordset[0];
                for (const d of faltan) err(vistos[d], 'fuera_del_backlog', `${d} no está en el backlog sin cuadro (corte ${corte ? corte.Corte : 'sin corte'}): o ya tiene cuadro, no está en preparación, es de otro almacén, o es nuevo y entra en el próximo corte (15 min). Revísalo con detalle_documento`);
            }
            // Revisión por documento
            for (const d of unicos) {
                const donde = vistos[d];
                const x = info[d];
                if (!x) continue; // ya reportado como fuera_del_backlog
                if (vivos[d]) err(donde, 'ya_en_cuadro_vivo', `${d} ya está en el cuadro ${vivos[d].map(v => `${v.RouteNumber} (${v.Estado})`).join(', ')} del app`);
                if (x.origen === 'sap') {
                    if (x.cuadrosSAP && x.cuadrosSAP.length) err(donde, 'ya_en_cuadro_sap', `${d} ya está en el cuadro ${x.cuadrosSAP.map(c => c.Cuadro).join(', ')} de SAP`);
                    if (x.Tipo === '?') continue; // solo lo vimos en un cuadro de SAP (p. ej. una RMA): no hay más que revisar
                    if (x.LineasAlmacen === 0) { err(donde, 'otro_almacen', `${d} (${x.Tipo}) no es del almacén ${centro.codigo}`); continue; }
                    if (x.DocStatus === 'C') err(donde, 'documento_cerrado', `${d} está cerrado en SAP`);
                    else if (x.U_Estado2 && x.U_Estado2 !== '03') err(donde, 'no_en_preparacion', `${d} tiene U_Estado2 = ${x.U_Estado2}, el robot solo acepta '03'`);
                    if (x.TrnspCode === 1) err(donde, 'cliente_retira', `${d} es "cliente retira" (forma de envío 1)`);
                } else {
                    if (String(x.Categoria).startsWith('no_aplica')) err(donde, x.Categoria, `${d}: ${x.Categoria === 'no_aplica_cliente_retira' ? 'cliente retira, no se rutea' : 'TR ya operado en Lisa, cerrar en SAP'}`);
                    if (x.Categoria === 'paqueteria') aviso(donde, 'paqueteria', `${d} es paquetería (forma de envío 71): va en el cuadro de paquetería del día`);
                    if (x.LineasSinStock > 0) aviso(donde, 'sin_stock', `${d} tiene ${x.LineasSinStock} línea(s) sin existencia en ${centro.codigo}`);
                    if (x.PickeadoLisa) aviso(donde, 'ya_pickeado', `${d} ya está pickeado en Lisa (solo falta cargarlo)`);
                }
            }
        }

        // Revisión por cuadro
        const detalle = [];
        const revisarCuadro = (donde, camionTipo, docs, base) => {
            const cam = camiones[camionTipo];
            if (!cam) { err(donde, 'camion_desconocido', `No reconozco el camión "${camionTipo || '?'}" (configurados: ${Object.keys(camiones).join(', ')})`); }
            const ds = docs.map(d => info[d]).filter(Boolean);
            const kg = base.kg + ds.reduce((s, d) => s + (d.Kg || 0), 0);
            const paradas = new Set([...base.paradas, ...ds.filter(d => d.Tipo !== '?').map(paradaDe)]);
            const rmas = ds.filter(d => d.Tipo === 'RMA').map(d => d.Documento);
            const kgTR = ds.filter(d => d.Tipo === 'TR' && d.Modalidad !== 'Directo a cliente').reduce((s, d) => s + (d.Kg || 0), 0) + base.kgTR;
            if (cam) {
                if (kg > cam.CapacidadKg) err(donde, 'sobrecupo', `${(kg / 1000).toFixed(1)} T supera la carga útil de ${camionTipo} (${(cam.CapacidadKg / 1000).toFixed(1)} T)`);
                if (paradas.size > cam.MaxParadas) err(donde, 'exceso_paradas', `${paradas.size} paradas; el ${camionTipo} admite ${cam.MaxParadas}`);
                if (cam.SoloClienteUnico && paradas.size > 1) err(donde, 'camion_grande_multi_parada', `${camionTipo} solo para un cliente o una plataforma de tienda; tiene ${paradas.size} paradas`);
            }
            const esPlataforma = kg > 0 && kgTR * 2 >= kg;
            if (esPlataforma && ds.some(d => d.Tipo === 'OV')) aviso(donde, 'cliente_en_plataforma', `Lleva OV de clientes en una plataforma de tiendas: ${ds.filter(d => d.Tipo === 'OV').map(d => d.Documento).join(', ')}`);
            return { donde, camion: camionTipo, kg, capacidadKg: cam ? cam.CapacidadKg : null, paradas: paradas.size, maxParadas: cam ? cam.MaxParadas : null, rmas, documentos: ds.map(d => ({ Documento: d.Documento, Tipo: d.Tipo, Kg: d.Kg, parada: d.Tipo === '?' ? null : paradaDe(d) })) };
        };
        for (const c of nuevos) {
            const tipo = c.camion ? String(c.camion).toUpperCase().replace(/\s/g, '') : camionDe(c.nombre);
            if (c.fecha && !fechaValida(c.fecha)) err(c.donde, 'fecha_invalida', `Fecha "${c.fecha}" no es AAAA-MM-DD`);
            if ((c.nombre || '').length > 75) err(c.donde, 'nombre_largo', 'El nombre del cuadro admite 75 caracteres en SAP');
            const det = revisarCuadro(c.donde, tipo, c.docs, { kg: 0, kgTR: 0, paradas: [] });
            if (det.rmas.length) err(c.donde, 'rma_en_cuadro_nuevo', `El robot no acepta RMA en cuadros nuevos (${det.rmas.join(', ')}): agrégalas por el app después de crear el cuadro`);
            detalle.push({ ...det, accion: 'nuevo', fecha: c.fecha || null });
        }
        for (const a of adds) {
            const n = parseInt(a.cuadro);
            const h = n ? await pool.request().input('n', sql.Int, n).input('c', sql.Int, centro.id).query(`
                SELECT p.RouteNumber, p.RouteName, p.Estado,
                       CAST(SUM(CASE WHEN ISNULL(m.NoDespachada,0)=0 THEN t.Cantidad*ISNULL(t.UnitWeight,0) ELSE 0 END) AS int) AS Kg,
                       CAST(SUM(CASE WHEN ISNULL(m.NoDespachada,0)=0 AND m.DocType IN ('TR','RESURTIDO') THEN t.Cantidad*ISNULL(t.UnitWeight,0) ELSE 0 END) AS int) AS KgTR
                FROM OrderRoutePlan p LEFT JOIN OrderPickingManagement m ON m.ID_RoutePlan = p.ID_RoutePlan LEFT JOIN OrderPickingTask t ON t.ID_OrderPicking = m.ID_OrderPicking
                WHERE p.RouteNumber = @n AND p.ID_Centro = @c GROUP BY p.RouteNumber, p.RouteName, p.Estado;
                SELECT DISTINCT ISNULL(m.ClienteNombre, '') AS Parada FROM OrderPickingManagement m JOIN OrderRoutePlan p ON p.ID_RoutePlan = m.ID_RoutePlan
                WHERE p.RouteNumber = @n AND p.ID_Centro = @c AND ISNULL(m.NoDespachada,0) = 0`) : null;
            const cab = h && h.recordsets[0][0];
            if (!cab) { err(a.donde, 'cuadro_no_encontrado', `El cuadro ${a.cuadro} no existe en el centro`); continue; }
            if (!['Pendiente', 'Iniciado'].includes(cab.Estado)) err(a.donde, 'cuadro_no_vivo', `El cuadro ${n} está ${cab.Estado}; solo se agrega a Pendiente o Iniciado`);
            const det = revisarCuadro(a.donde, camionDe(cab.RouteName), a.docs, { kg: cab.Kg || 0, kgTR: cab.KgTR || 0, paradas: h.recordsets[1].map(x => x.Parada).filter(Boolean) });
            detalle.push({ ...det, accion: 'agregar', cuadro: n, nombre: cab.RouteName, estado: cab.Estado, kgActual: cab.Kg || 0 });
        }
        return { ok: errores.length === 0, errores, avisos, cuadros: detalle };
    }
}
router.post('/validar-plan', requireCentro, async (req, res) => {
    try {
        if (!(Array.isArray(req.body.cuadros) && req.body.cuadros.length) && !(Array.isArray(req.body.agregados) && req.body.agregados.length)) return res.status(400).json({ error: 'Envía cuadros y/o agregados' });
        res.json(await validarPlan(await getPlanPool(), req.centro, req.body));
    } catch (e) { fallo(res, e, 'Error al validar el plan'); }
});

// ── Orden del día propuesto (no escribe) ────────────────────────────────────
// Grupos en el orden de ConfigPlanDiario; dentro: iniciados/ya pickeados → comprometidos → escalado más viejo → fecha más vieja.
router.get('/orden-dia', requireCentro, async (req, res) => {
    try {
        const fecha = fechaValida(req.query.fecha) ? req.query.fecha : hoyStr();
        const pool = await getPlanPool();
        const [cola, cfg] = await Promise.all([leerCola(pool, req.centro.id, { hasta: fecha, sinFecha: false }), leerConfig(pool, req.centro.id)]);
        if (!cfg.dia) return res.status(404).json({ error: 'El centro no tiene configuración de plan diario (ConfigPlanDiario)' });
        const orden = cfg.dia.OrdenGrupos.split(',').map(s => s.trim());
        const escPorCuadro = {};
        if (cola.length) {
            const r = pool.request().input('c', sql.Int, req.centro.id);
            const inP = inList(r, 'n', cola.map(c => c.RouteNumber), sql.Int);
            const e = await r.query(`
                SELECT p.RouteNumber, CONVERT(varchar(10), MIN(e.FechaRequerida), 23) AS Fecha, COUNT(DISTINCT e.ID_Escalamiento) AS N
                FROM Escalamientos e JOIN OrderPickingManagement m ON LTRIM(RTRIM(m.OV_Number)) = LTRIM(RTRIM(e.OV_Number))
                JOIN OrderRoutePlan p ON p.ID_RoutePlan = m.ID_RoutePlan
                WHERE e.Archivado = 0 AND p.ID_Centro = @c AND ISNULL(m.NoDespachada,0) = 0 AND p.RouteNumber IN (${inP})
                GROUP BY p.RouteNumber`);
            e.recordset.forEach(x => { escPorCuadro[x.RouteNumber] = x; });
        }
        const rango = (c) => {
            if (c.Estado === 'Iniciado' || c.KgPorPickear === 0) return 0;
            if (c.Comprometida) return 1;
            return 2 + Math.max(0, orden.indexOf(c.Grupo));
        };
        const motivo = (c) => c.Estado === 'Iniciado' ? 'iniciado' : c.KgPorPickear === 0 ? 'ya pickeado, solo cargar' : c.Comprometida ? 'comprometida' : (escPorCuadro[c.RouteNumber] ? `escalado al ${escPorCuadro[c.RouteNumber].Fecha}` : (c.Fecha < fecha ? `atrasado (${c.Fecha})` : c.Grupo));
        const lista = [...cola].sort((a, b) => {
            const ra = rango(a), rb = rango(b); if (ra !== rb) return ra - rb;
            if (ra <= 1) return (a.Prioridad || 9e9) - (b.Prioridad || 9e9);
            const ea = (escPorCuadro[a.RouteNumber] || {}).Fecha || '9999', eb = (escPorCuadro[b.RouteNumber] || {}).Fecha || '9999';
            if (ea !== eb) return ea < eb ? -1 : 1;
            if ((a.Fecha || '') !== (b.Fecha || '')) return (a.Fecha || '') < (b.Fecha || '') ? -1 : 1;
            return (a.Prioridad || 9e9) - (b.Prioridad || 9e9);
        });
        const [hh, mm] = cfg.dia.HoraInicio.split(':').map(Number);
        const hora = t => { const min = Math.round(hh * 60 + mm + (t / cfg.dia.ToneladasHora) * 60); return `${String(Math.floor(min / 60) % 24).padStart(2, '0')}:${String(min % 60).padStart(2, '0')}${min >= 1440 ? ' (+1 día)' : ''}`; };
        let acum = 0, pos = 0, cambios = 0;
        const propuesta = lista.map(c => {
            const t = c.KgPorPickear / 1000; acum += t; pos++;
            if (c.Prioridad !== pos) cambios++;
            return { posicion: pos, prioridadActual: c.Prioridad, cuadro: c.RouteNumber, nombre: c.RouteName, fecha: c.Fecha, grupo: c.Grupo, camion: c.Camion,
                     toneladasPorPickear: Math.round(t * 10) / 10, acumuladoToneladas: Math.round(acum * 10) / 10, terminaAprox: hora(acum),
                     motivo: motivo(c), escalamientos: (escPorCuadro[c.RouteNumber] || {}).N || 0, excedente: acum > cfg.dia.CorteToneladasDia };
        });
        const excedente = propuesta.filter(p => p.excedente);
        res.json({
            centro: req.centro.id, fecha, corteToneladas: Number(cfg.dia.CorteToneladasDia), toneladasHora: Number(cfg.dia.ToneladasHora), ordenGrupos: orden,
            totalToneladas: Math.round(acum * 10) / 10, cuadros: propuesta.length, cambiosRespectoAHoy: cambios,
            propuesta, excedente: { cuadros: excedente.length, toneladas: Math.round(excedente.reduce((s, p) => s + p.toneladasPorPickear, 0) * 10) / 10, sugerencia: excedente.length ? 'Pasar estos cuadros al día siguiente, a la cabeza de su grupo' : null },
            nota: 'Propuesta de solo lectura. Las expos las ordena el usuario; no mover lo que otro planificador reordenó a mano sin avisar.'
        });
    } catch (e) { fallo(res, e, 'Error al proponer el orden del día'); }
});

// Backlog sin cuadro (snapshot de SP_MCP_BacklogSinCuadro, refrescado cada 15 min por el job del app).
// Por defecto excluye lo que no se planifica (cliente retira, TR ya operados en Lisa).
router.get('/backlog', requireCentro, async (req, res) => {
    try {
        const pool = await getPlanPool();
        const r = pool.request().input('c', sql.Int, req.centro.id);
        const filtros = [];
        if (req.query.incluir_no_aplica !== 'true') filtros.push(`Categoria NOT LIKE 'no_aplica%'`);
        if (req.query.categoria) { r.input('cat', sql.VarChar(30), String(req.query.categoria)); filtros.push('Categoria = @cat'); }
        if (['OV', 'TR', 'RMA'].includes(String(req.query.tipo || '').toUpperCase())) { r.input('tipo', sql.VarChar(5), req.query.tipo.toUpperCase()); filtros.push('Tipo = @tipo'); }
        const q = await r.query(`
            SELECT TOP 1 Corte, Filas, DuracionMs, Error FROM PlanBacklogCorte WHERE ID_Centro = @c ORDER BY ID_Corte DESC;
            SELECT Categoria, Tipo, COUNT(*) AS Documentos, SUM(Kg) AS Kg FROM PlanBacklogSnapshot WHERE ID_Centro = @c GROUP BY Categoria, Tipo ORDER BY Categoria, Tipo;
            SELECT Tipo, Documento, CONVERT(varchar(10), FechaDoc, 23) AS FechaDoc, CONVERT(varchar(10), FechaEntrega, 23) AS FechaEntrega,
                   FormaEnvioCodigo, FormaEnvio, Cliente, AlmacenDestino, DestinoNombre, Municipio, Direccion, Comentario, Kg, LineasSinStock,
                   Sucursal, Modalidad, TrOperadoLisa, PickeadoLisa, EntregadoLisa, UltimoCuadroApp, UltimoCuadroEstado, NoDespachada,
                   CONVERT(varchar(10), EscalamientoFecha, 23) AS EscalamientoFecha, Categoria
            FROM PlanBacklogSnapshot WHERE ID_Centro = @c ${filtros.length ? 'AND ' + filtros.join(' AND ') : ''}
            ORDER BY CASE WHEN EscalamientoFecha IS NULL THEN 1 ELSE 0 END, EscalamientoFecha, FechaEntrega, FechaDoc`);
        const corte = q.recordsets[0][0] || null;
        const docs = q.recordsets[2].map(d => ({ ...d, TrOperadoLisa: !!d.TrOperadoLisa, PickeadoLisa: !!d.PickeadoLisa, EntregadoLisa: !!d.EntregadoLisa, NoDespachada: !!d.NoDespachada }));
        if (!corte) return res.status(503).json({ error: 'Todavía no hay un corte del backlog para este centro' });
        const edadMin = Math.round((Date.now() - new Date(corte.Corte).getTime()) / 60000);
        res.json({
            centro: req.centro.id, corte: corte.Corte, edadMinutos: edadMin, corteAtrasado: edadMin > 30, errorUltimoCorte: corte.Error || null,
            resumen: q.recordsets[1], documentos: docs,
            categorias: { nuevo: 'sin cuadro, por planificar', rezago: 'estuvo en un cuadro del app y ya no está en SAP', paqueteria: 'forma de envío 71, va en su cuadro de paquetería', exportacion: 'expo', no_aplica_cliente_retira: 'forma de envío 1, no se rutea', no_aplica_tr_operado_lisa: 'TR ya despachado en Lisa con saldo abierto en SAP: cerrar en SAP' }
        });
    } catch (e) { fallo(res, e, 'Error al leer el backlog'); }
});

// Estado del staging de rutas (Supabase rutas_staging): lotes recientes y lo pendiente para el robot.
router.get('/staging', requireCentro, async (req, res) => {
    try {
        const base = (process.env.PLAN_STAGING_URL || '').replace(/\/$/, '');
        const key = process.env.PLAN_STAGING_KEY;
        if (!base || !key) return res.status(503).json({ error: 'Staging no configurado en el app (PLAN_STAGING_URL / PLAN_STAGING_KEY)' });
        const dias = Math.min(Math.max(parseInt(req.query.dias) || 7, 1), 60);
        const desde = new Date(Date.now() - dias * 86400000).toISOString();
        const url = `${base}/rest/v1/rutas_staging?select=id,lote_id,archivo,ruta,documento,tipo,almacen_origen,estado,cuadro_docnum,error_msg,created_at,completed_at&created_at=gte.${desde}&order=id.asc&limit=5000`;
        const r = await fetch(url, { headers: { apikey: key, Authorization: `Bearer ${key}` } });
        if (!r.ok) throw new Error(`Supabase ${r.status}: ${(await r.text()).slice(0, 200)}`);
        const filas = await r.json();
        const lotes = {};
        for (const f of filas) {
            const l = lotes[f.lote_id] || (lotes[f.lote_id] = { lote: f.lote_id, archivo: f.archivo, creado: f.created_at, almacenOrigen: f.almacen_origen, filas: 0, estados: {}, rutas: {}, errores: new Set(), cuadros: new Set(), documentosVacios: 0 });
            l.filas++; l.estados[f.estado] = (l.estados[f.estado] || 0) + 1;
            l.rutas[f.ruta] = (l.rutas[f.ruta] || 0) + 1;
            if (f.error_msg) l.errores.add(String(f.error_msg).slice(0, 120));
            if (f.cuadro_docnum && f.cuadro_docnum !== '0') l.cuadros.add(f.cuadro_docnum);
            if (!String(f.documento || '').trim()) l.documentosVacios++;
        }
        const lista = Object.values(lotes).map(l => ({ ...l, errores: [...l.errores], cuadros: [...l.cuadros] })).sort((a, b) => a.creado < b.creado ? 1 : -1);
        const pendientes = filas.filter(f => f.estado === 'pendiente');
        res.json({
            dias, lotes: lista,
            pendientes: { filas: pendientes.length, rutas: [...new Set(pendientes.map(f => f.ruta))], lotes: [...new Set(pendientes.map(f => f.lote_id))], documentosVacios: pendientes.filter(f => !String(f.documento || '').trim()).length },
            nota: 'El robot procesa TODO lo pendiente; un mismo documento pendiente en dos lotes se crea dos veces y un documento vacío rompe la consulta.'
        });
    } catch (e) { fallo(res, e, 'Error al leer el staging'); }
});

// Escrituras (dos pasos: vista previa + confirmar). Ver routes/planificacion-escritura.js
require('./planificacion-escritura')(router, { requireCentro, fechaValida, camionDe, leerConfig, validarPlan, fallo, inList });

module.exports = router;
