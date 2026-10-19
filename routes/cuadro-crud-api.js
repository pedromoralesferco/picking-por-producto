// ============================================================
// CRUD de cuadros de ruta (pivoteo en carril) — HUB Escuintla.
// App-first: edita el cuadro en el app y encola el cambio (CuadroEdicionCola)
// para sincronizar a SAP por Service Layer (Fase 3). NO escribe a SAP aquí.
// ============================================================
const express = require('express');
const router = express.Router();
const { getPool, sql } = require('../db');
const { getSapDb, getLisaDb } = require('../config/paises');

// Puede editar cuadros: priorizacion, operativo o Admin.
function requireCrud(req, res, next) {
    const u = req.session && req.session.user;
    if (!u) return res.status(401).json({ error: 'No autenticado' });
    if (u.rol === 'Admin' || (u.permisos && (u.permisos.includes('priorizacion') || u.permisos.includes('reportes_operativo')))) return next();
    return res.status(403).json({ error: 'Sin permiso para editar cuadros' });
}

// GET /api/cuadro/camiones/buscar?q= — búsqueda formateada contra @camiones (SAP)
router.get('/camiones/buscar', requireCrud, async (req, res) => {
    try {
        const q = String(req.query.q || '').trim();
        const db = getSapDb('GT');
        const reqS = getPool().request().input('q', sql.NVarChar(50), '%' + q + '%');
        const r = await reqS.query(`
            SELECT TOP 25
                   LTRIM(RTRIM(c.U_Camion)) AS Placa,
                   c.U_Capacidad            AS Capacidad,
                   LTRIM(RTRIM(c.U_Proveedor)) AS Transportista,
                   c.U_CardCode             AS CardCode,
                   LTRIM(RTRIM(c.U_Piloto)) AS Piloto,
                   c.U_ID_Camion            AS IDCamion
            FROM [server-sql].[${db}].dbo.[@camiones] c WITH (NOLOCK)
            WHERE LTRIM(RTRIM(ISNULL(c.U_Camion,''))) <> ''
              AND ( @q = '%%'
                 OR c.U_Camion   COLLATE DATABASE_DEFAULT LIKE @q
                 OR c.U_Proveedor COLLATE DATABASE_DEFAULT LIKE @q
                 OR c.U_Piloto    COLLATE DATABASE_DEFAULT LIKE @q )
            ORDER BY c.U_Camion`);
        res.json(r.recordset);
    } catch (err) {
        console.error('GET /cuadro/camiones/buscar error:', err);
        res.status(500).json({ error: 'Error al buscar camiones' });
    }
});

// POST /api/cuadro/:routeNumber/placa — asignar placa al cuadro (app-first) y
// encolar el cambio para sincronizar el header en SAP (Service Layer, Fase 3).
router.post('/:routeNumber/placa', requireCrud, async (req, res) => {
    try {
        const rn = parseInt(req.params.routeNumber);
        if (!rn) return res.status(400).json({ error: 'RouteNumber requerido' });
        const placa = String(req.body.placa || '').trim();
        if (!placa) return res.status(400).json({ error: 'Placa requerida' });
        const capacidad = req.body.capacidad != null && req.body.capacidad !== '' ? Number(req.body.capacidad) : null;
        const idCamion = req.body.idCamion != null ? String(req.body.idCamion).trim() : null;
        const transportista = req.body.transportista != null ? String(req.body.transportista).trim() : null;
        const cardCode = req.body.cardCode != null ? String(req.body.cardCode).trim() : null;
        const pool = getPool();
        // SAP = fuente de la verdad: si el cuadro YA tiene placa en SAP, no se
        // reasigna desde el app (idempotente, respeta SAP). Solo se puede asignar
        // cuando SAP está vacío (rellenar el hueco).
        const db = getSapDb('GT');
        const sapChk = await pool.request().input('rn', sql.Int, rn)
            .query(`SELECT TOP 1 LTRIM(RTRIM(ISNULL(U_Placa,''))) AS Placa
                    FROM [server-sql].[${db}].dbo.[@CUADRO_RUTA_E] WITH (NOLOCK)
                    WHERE DocNum = @rn`);
        const placaSap = sapChk.recordset[0] && sapChk.recordset[0].Placa;
        if (placaSap && placaSap.trim() !== '') {
            return res.status(409).json({ error: 'SAP_TIENE_PLACA', mensaje: 'Este cuadro ya tiene placa asignada en SAP (' + placaSap.trim() + '). No se reasigna desde el app.' });
        }
        const upd = await pool.request()
            .input('rn', sql.Int, rn)
            .input('placa', sql.NVarChar(20), placa)
            .input('cap', sql.Decimal(10, 2), capacidad)
            .input('idc', sql.NVarChar(30), idCamion)
            .input('tr', sql.NVarChar(100), transportista)
            .query(`
                UPDATE OrderRoutePlan
                SET PlacaApp = @placa, CapacidadApp = @cap, IDCamionApp = @idc,
                    TransportistaApp = @tr, PlacaPendienteSync = 1
                WHERE RouteNumber = @rn AND ID_Centro = 3 AND Pais = 'GT'`);
        if (upd.rowsAffected[0] === 0) return res.status(404).json({ error: 'Cuadro no encontrado en Escuintla' });
        const autor = (req.session.user && (req.session.user.nombre || req.session.user.usuario)) || 'Sistema';
        await pool.request()
            .input('rn', sql.Int, rn)
            .input('payload', sql.NVarChar(sql.MAX), JSON.stringify({ placa, capacidad, idCamion, transportista, cardCode }))
            .input('autor', sql.NVarChar(100), autor)
            .query(`INSERT INTO dbo.CuadroEdicionCola (RouteNumber, Ambito, Accion, Payload, Usuario)
                    VALUES (@rn, 'HEADER', 'PLACA', @payload, @autor)`);
        res.json({ ok: true, placa, pendienteSync: true });
    } catch (err) {
        console.error('POST /cuadro/:rn/placa error:', err);
        res.status(500).json({ error: 'Error al asignar placa' });
    }
});

// ── Helpers ──────────────────────────────────────────────

// Busca un doc (OV/TR) en SAP/Lisa: tipo, cliente, líneas, en preparación.
async function lookupDoc(pool, docRaw, tipoForzado) {
    const forzar = (tipoForzado === 'OV' || tipoForzado === 'TR' || tipoForzado === 'RMA') ? tipoForzado : null;
    const num = parseInt(String(docRaw).replace(/\D/g, ''));
    const out = { doc: String(docRaw).trim(), tipo: null, cliente: null, lineas: null, enPrepa: false, encontrado: false };
    if (!num || isNaN(num)) return out;
    const db = getSapDb('GT'); const lisa = 'lisa_' + db;
    if (forzar !== 'TR' && forzar !== 'RMA') {
        try {
            const ov = await pool.request().input('d', sql.Int, num).query(`
                SELECT TOP 1 c.CardName AS Cliente, o.U_Estado2 AS Estado2
                FROM [server-sql].[${db}].dbo.ORDR o WITH (NOLOCK)
                LEFT JOIN [server-sql].[${db}].dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
                WHERE o.DocNum = @d`);
            if (ov.recordset.length) {
                out.tipo = 'OV'; out.encontrado = true;
                out.cliente = ov.recordset[0].Cliente || null;
                out.enPrepa = String(ov.recordset[0].Estado2 || '').trim() === '03';
            }
        } catch (e) { console.error('lookupDoc OV:', e.message); }
    }
    if (!out.tipo && forzar !== 'OV' && forzar !== 'RMA') {
        try {
            const tr = await pool.request().input('d', sql.Int, num).query(`
                SELECT TOP 1 c.CardName AS Cliente, wh.WhsName AS Destino, o.U_Estado2 AS Estado2
                FROM [server-sql].[${db}].dbo.OWTQ o WITH (NOLOCK)
                LEFT JOIN [server-sql].[${db}].dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
                LEFT JOIN [server-sql].[${db}].dbo.OWHS wh WITH (NOLOCK) ON wh.WhsCode = o.ToWhsCode
                WHERE o.DocNum = @d`);
            if (tr.recordset.length) {
                out.tipo = 'TR'; out.encontrado = true;
                out.cliente = tr.recordset[0].Destino || tr.recordset[0].Cliente || null;
                out.enPrepa = String(tr.recordset[0].Estado2 || '').trim() === '03';
            }
        } catch (e) { console.error('lookupDoc TR:', e.message); }
    }
    if (!out.tipo && forzar) out.tipo = forzar;
    // líneas desde Lisa
    try {
        const d = String(num);
        if (out.tipo === 'OV') {
            const r = await pool.request().input('d', sql.VarChar(50), d).query(`
                SELECT COUNT(DISTINCT l.IdProduct) AS Lineas
                FROM [server-sql].[${lisa}].dbo.[CustomerOrder] co WITH (NOLOCK)
                JOIN [server-sql].[${lisa}].dbo.[CustomerOrderLine] l WITH (NOLOCK) ON l.IdCustomerOrder = co.IdCustomerOrder
                WHERE co.IdAccountableOrder = @d`);
            out.lineas = r.recordset[0].Lineas || 0;
        } else if (out.tipo === 'TR') {
            const r = await pool.request().input('d', sql.VarChar(50), d).query(`
                SELECT COUNT(DISTINCT l.IdProduct) AS Lineas
                FROM [server-sql].[${lisa}].dbo.[TransferRequest] co WITH (NOLOCK)
                JOIN [server-sql].[${lisa}].dbo.[TransferRequestLines] l WITH (NOLOCK) ON l.IdTransferRequest = co.IdTransferRequest
                WHERE co.DocNum = @d`);
            out.lineas = r.recordset[0].Lineas || 0;
        }
    } catch (e) { console.error('lookupDoc lineas:', e.message); }
    return out;
}

// Encola una edición de cuadro en el outbox (para sincronizar a SAP, Fase 3).
async function encolar(pool, { rn, ambito, accion, ov, tipo, payload, autor }) {
    await pool.request()
        .input('rn', sql.Int, rn)
        .input('ambito', sql.NVarChar(10), ambito)
        .input('accion', sql.NVarChar(10), accion)
        .input('ov', sql.NVarChar(50), ov || null)
        .input('tipo', sql.NVarChar(10), tipo || null)
        .input('payload', sql.NVarChar(sql.MAX), payload ? JSON.stringify(payload) : null)
        .input('autor', sql.NVarChar(100), autor || 'Sistema')
        .query(`INSERT INTO dbo.CuadroEdicionCola (RouteNumber, Ambito, Accion, OV_Number, DocType, Payload, Usuario)
                VALUES (@rn, @ambito, @accion, @ov, @tipo, @payload, @autor)`);
}

// ── Endpoints de edición de líneas ───────────────────────

// GET /api/cuadro/doc-lookup?doc=&tipo= — previsualiza un doc a agregar.
router.get('/doc-lookup', requireCrud, async (req, res) => {
    try {
        const pool = getPool();
        const info = await lookupDoc(pool, req.query.doc, req.query.tipo);
        // ¿ya está en un cuadro del app (Escuintla)?
        if (info.tipo) {
            const num = parseInt(String(req.query.doc).replace(/\D/g, ''));
            const r = await pool.request().input('ov', sql.NVarChar(50), String(num)).input('tipo', sql.NVarChar(10), info.tipo)
                .query(`SELECT TOP 1 orp.RouteNumber
                        FROM dbo.OrderPickingManagement opm
                        INNER JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
                        WHERE opm.OV_Number COLLATE DATABASE_DEFAULT = @ov COLLATE DATABASE_DEFAULT
                          AND opm.DocType = @tipo AND opm.NoDespachada = 0
                          AND orp.ID_Centro = 3 AND orp.Pais = 'GT'`);
            info.enCuadroApp = r.recordset[0] ? r.recordset[0].RouteNumber : null;
        }
        res.json(info);
    } catch (err) {
        console.error('GET /cuadro/doc-lookup error:', err);
        res.status(500).json({ error: 'Error al buscar el documento' });
    }
});

// GET /api/cuadro/cuadros-destino?q= — cuadros candidatos para mover documentos.
router.get('/cuadros-destino', requireCrud, async (req, res) => {
    try {
        const q = String(req.query.q || '').trim();
        const excluir = parseInt(req.query.excluir) || 0;
        const pool = getPool();
        const r = await pool.request().input('q', sql.NVarChar(50), '%' + q + '%').input('ex', sql.Int, excluir)
            .query(`SELECT TOP 25 orp.RouteNumber, orp.RouteName, orp.Estado, orp.EstadoDespacho,
                           (SELECT COUNT(*) FROM dbo.OrderPickingManagement o WHERE o.ID_RoutePlan = orp.ID_RoutePlan AND o.NoDespachada = 0) AS Docs
                    FROM dbo.OrderRoutePlan orp
                    WHERE orp.ID_Centro = 3 AND orp.Pais = 'GT'
                      AND ISNULL(orp.EstadoDespacho,'') <> 'Finalizado'
                      AND orp.RouteNumber <> @ex
                      AND (@q = '%%' OR CAST(orp.RouteNumber AS NVARCHAR(20)) LIKE @q OR orp.RouteName LIKE @q)
                    ORDER BY orp.RouteNumber DESC`);
        res.json(r.recordset);
    } catch (err) {
        console.error('GET /cuadro/cuadros-destino error:', err);
        res.status(500).json({ error: 'Error al listar cuadros' });
    }
});

// POST /api/cuadro/:routeNumber/editar — commit batch de la edición del cuadro.
// Body: { agregar:[{ov,tipo}], quitar:[{ov,tipo}], destino:'eliminar'|'nuevo'|{cuadro:N} }
router.post('/:routeNumber/editar', requireCrud, async (req, res) => {
    const pool = getPool();
    try {
        const rn = parseInt(req.params.routeNumber);
        if (!rn) return res.status(400).json({ error: 'RouteNumber requerido' });
        const agregar = Array.isArray(req.body.agregar) ? req.body.agregar : [];
        const quitar = Array.isArray(req.body.quitar) ? req.body.quitar : [];
        const destino = req.body.destino; // 'eliminar' | 'nuevo' | {cuadro:N}
        const autor = (req.session.user && (req.session.user.nombre || req.session.user.usuario)) || 'Sistema';

        // Cuadro origen A
        const aRes = await pool.request().input('rn', sql.Int, rn)
            .query(`SELECT TOP 1 ID_RoutePlan, RouteName, AlmacenOrigen, FechaPlanificacion, FechaPlanDespacho,
                           Prioridad, Estado, ISNULL(EstadoDespacho,'Pendiente') AS EstadoDespacho
                    FROM dbo.OrderRoutePlan WHERE RouteNumber = @rn AND ID_Centro = 3 AND Pais = 'GT'`);
        const A = aRes.recordset[0];
        if (!A) return res.status(404).json({ error: 'Cuadro no encontrado en Escuintla' });
        if (A.EstadoDespacho === 'Finalizado') return res.status(409).json({ error: 'El cuadro ya está despachado; no se puede editar.' });

        const out = { quitados: [], agregados: [], errores: [], complemento: null };

        // ── Destino de los quitados ──
        let destinoRoutePlan = null, destinoRn = null, modoQuitar = 'eliminar';
        const esComplementoNuevo = destino === 'nuevo';
        if (quitar.length) {
            if (destino === 'nuevo') {
                modoQuitar = 'mover';
                const prov = await pool.request().query(`SELECT ISNULL(MIN(RouteNumber),0) - 1 AS Prov FROM dbo.OrderRoutePlan WHERE RouteNumber < 0`);
                destinoRn = prov.recordset[0].Prov; // negativo provisional
                const ins = await pool.request()
                    .input('rn', sql.Int, destinoRn)
                    .input('name', sql.NVarChar(200), 'COMP-' + rn)
                    .input('alm', sql.NVarChar(50), A.AlmacenOrigen)
                    .input('fp', sql.DateTime, A.FechaPlanificacion)
                    .input('fpd', sql.Date, A.FechaPlanDespacho)
                    .input('prio', sql.Int, A.Prioridad)
                    .input('comp', sql.Int, rn)
                    .query(`INSERT INTO dbo.OrderRoutePlan
                               (RouteNumber, RouteName, AlmacenOrigen, FechaPlanificacion, FechaPlanDespacho,
                                Prioridad, Estado, EstadoDespacho, ID_Centro, Pais, EsComplemento, ComplementoDe, CreacionPendienteSync)
                            OUTPUT INSERTED.ID_RoutePlan
                            VALUES (@rn, @name, @alm, @fp, @fpd, @prio, 'Pendiente', 'Pendiente', 3, 'GT', 1, @comp, 1)`);
                destinoRoutePlan = ins.recordset[0].ID_RoutePlan;
                out.complemento = { routeNumber: destinoRn, provisional: true };
            } else if (destino && typeof destino === 'object' && destino.cuadro) {
                modoQuitar = 'mover';
                destinoRn = parseInt(destino.cuadro);
                const bRes = await pool.request().input('rn', sql.Int, destinoRn)
                    .query(`SELECT TOP 1 ID_RoutePlan FROM dbo.OrderRoutePlan WHERE RouteNumber=@rn AND ID_Centro=3 AND Pais='GT' AND ISNULL(EstadoDespacho,'')<>'Finalizado'`);
                if (!bRes.recordset[0]) return res.status(400).json({ error: 'Cuadro destino inválido o ya despachado' });
                destinoRoutePlan = bRes.recordset[0].ID_RoutePlan;
            }

            for (const q of quitar) {
                const ov = String(q.ov).trim(), tipo = String(q.tipo || '').toUpperCase();
                const opmRes = await pool.request().input('idrp', sql.Int, A.ID_RoutePlan).input('ov', sql.NVarChar(50), ov).input('tipo', sql.NVarChar(10), tipo)
                    .query(`SELECT TOP 1 ID_OrderPicking FROM dbo.OrderPickingManagement
                            WHERE ID_RoutePlan=@idrp AND OV_Number COLLATE DATABASE_DEFAULT = @ov COLLATE DATABASE_DEFAULT AND DocType=@tipo AND NoDespachada=0`);
                if (!opmRes.recordset[0]) { out.errores.push(`${tipo} ${ov}: no está en el cuadro`); continue; }
                const idOP = opmRes.recordset[0].ID_OrderPicking;
                if (modoQuitar === 'mover') {
                    // mover (avance incluido): repuntar OPM + sus tareas al cuadro destino
                    await pool.request().input('id', sql.Int, idOP).input('drp', sql.Int, destinoRoutePlan).input('drn', sql.Int, destinoRn)
                        .query(`UPDATE dbo.OrderPickingManagement SET ID_RoutePlan=@drp, RouteNumber=@drn, PendienteSync=1, NoDespachada=0, RemocionPendienteSync=0 WHERE ID_OrderPicking=@id;
                                UPDATE dbo.OrderPickingTask SET RouteNumber=@drn WHERE ID_OrderPicking=@id;`);
                    await encolar(pool, { rn, ambito: 'LINEA', accion: 'REMOVE', ov, tipo, payload: { destino: esComplementoNuevo ? 'complemento' : 'mover', aCuadro: destinoRn }, autor });
                    // Complemento nuevo: nace completo con un solo CREATE (abajo), no ADD por doc.
                    // Mover a cuadro existente: sí ADD por doc en el destino.
                    if (!esComplementoNuevo) {
                        await encolar(pool, { rn: destinoRn, ambito: 'LINEA', accion: 'ADD', ov, tipo, payload: { origen: rn }, autor });
                    }
                } else {
                    // eliminar: ocultar del cuadro, baja pendiente de reflejar en SAP
                    await pool.request().input('id', sql.Int, idOP)
                        .query(`UPDATE dbo.OrderPickingManagement SET NoDespachada=1, RemocionPendienteSync=1, FechaNoDespachada=GETDATE() WHERE ID_OrderPicking=@id`);
                    await encolar(pool, { rn, ambito: 'LINEA', accion: 'REMOVE', ov, tipo, payload: { destino: 'eliminar' }, autor });
                }
                out.quitados.push(`${tipo} ${ov}`);
            }
            // Complemento nuevo con al menos un doc movido → una sola orden CREATE.
            // El robot crea el cuadro completo en SAP y remapea el RouteNumber provisional.
            if (esComplementoNuevo && out.quitados.length) {
                await encolar(pool, { rn: destinoRn, ambito: 'HEADER', accion: 'CREATE', payload: { nombre: 'COMP-' + rn, almacen: A.AlmacenOrigen, origen: rn }, autor });
            }
        }

        // ── Agregar ──
        for (const a of agregar) {
            const ov = String(a.ov).trim(), tipo = String(a.tipo || '').toUpperCase();
            if (!ov || !['OV', 'TR', 'RMA'].includes(tipo)) { out.errores.push(`${a.ov}: tipo inválido`); continue; }
            // ¿ya está (visible) en este cuadro?
            const yaAqui = await pool.request().input('idrp', sql.Int, A.ID_RoutePlan).input('ov', sql.NVarChar(50), ov).input('tipo', sql.NVarChar(10), tipo)
                .query(`SELECT TOP 1 ID_OrderPicking, NoDespachada FROM dbo.OrderPickingManagement
                        WHERE ID_RoutePlan=@idrp AND OV_Number COLLATE DATABASE_DEFAULT=@ov COLLATE DATABASE_DEFAULT AND DocType=@tipo`);
            if (yaAqui.recordset[0] && !yaAqui.recordset[0].NoDespachada) { out.errores.push(`${tipo} ${ov}: ya está en el cuadro`); continue; }
            // ¿existe en otro cuadro del app? → mover aquí (preserva avance)
            const enOtro = await pool.request().input('ov', sql.NVarChar(50), ov).input('tipo', sql.NVarChar(10), tipo).input('idrp', sql.Int, A.ID_RoutePlan)
                .query(`SELECT TOP 1 opm.ID_OrderPicking, orp.RouteNumber AS OrigenRn
                        FROM dbo.OrderPickingManagement opm INNER JOIN dbo.OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
                        WHERE opm.OV_Number COLLATE DATABASE_DEFAULT=@ov COLLATE DATABASE_DEFAULT AND opm.DocType=@tipo
                          AND opm.NoDespachada=0 AND orp.ID_Centro=3 AND orp.Pais='GT' AND opm.ID_RoutePlan<>@idrp`);
            try {
                if (enOtro.recordset[0]) {
                    const idOP = enOtro.recordset[0].ID_OrderPicking, origenRn = enOtro.recordset[0].OrigenRn;
                    await pool.request().input('id', sql.Int, idOP).input('drp', sql.Int, A.ID_RoutePlan).input('drn', sql.Int, rn)
                        .query(`UPDATE dbo.OrderPickingManagement SET ID_RoutePlan=@drp, RouteNumber=@drn, PendienteSync=1, NoDespachada=0, RemocionPendienteSync=0 WHERE ID_OrderPicking=@id;
                                UPDATE dbo.OrderPickingTask SET RouteNumber=@drn WHERE ID_OrderPicking=@id;`);
                    await encolar(pool, { rn: origenRn, ambito: 'LINEA', accion: 'REMOVE', ov, tipo, payload: { destino: 'mover', aCuadro: rn }, autor });
                    await encolar(pool, { rn, ambito: 'LINEA', accion: 'ADD', ov, tipo, payload: { origen: origenRn }, autor });
                } else {
                    // materializar desde Lisa
                    await pool.request().input('idrp', sql.Int, A.ID_RoutePlan).input('ov', sql.NVarChar(50), ov).input('tipo', sql.NVarChar(10), tipo)
                        .query(`EXEC dbo.SP_AddDocToCuadroApp @ID_RoutePlan=@idrp, @OV=@ov, @DocType=@tipo, @EmitResult=0`);
                    await encolar(pool, { rn, ambito: 'LINEA', accion: 'ADD', ov, tipo, payload: { origen: null }, autor });
                }
                out.agregados.push(`${tipo} ${ov}`);
            } catch (e) {
                out.errores.push(`${tipo} ${ov}: ${e.message.replace(/\s+/g, ' ').slice(0, 160)}`);
            }
        }

        res.json({ ok: true, ...out });
    } catch (err) {
        console.error('POST /cuadro/:rn/editar error:', err);
        res.status(500).json({ error: 'Error al guardar la edición del cuadro' });
    }
});

// ── Interfaz para el robot UiPath (Fase 3: sync a SAP) ───
// El robot se autentica con un token compartido (ROBOT_API_TOKEN en .env), no con
// sesión de usuario. Lee pendientes, aplica en SAP y marca el resultado.
function requireRobot(req, res, next) {
    const tok = process.env.ROBOT_API_TOKEN;
    if (!tok) return res.status(503).json({ error: 'ROBOT_API_TOKEN no configurado en el servidor' });
    const auth = req.headers['authorization'] || '';
    const sent = auth.replace(/^Bearer\s+/i, '') || req.headers['x-robot-token'] || '';
    if (sent !== tok) return res.status(401).json({ error: 'Token de robot inválido' });
    next();
}

// GET /api/cuadro/edicion/pendientes[?accion=PLACA] — ediciones por aplicar en SAP.
router.get('/edicion/pendientes', requireRobot, async (req, res) => {
    try {
        const accion = req.query.accion ? String(req.query.accion).toUpperCase() : null;
        const r = await getPool().request()
            .input('accion', sql.NVarChar(10), accion)
            .query(`SELECT TOP 200 * FROM dbo.vw_CuadroEdicionPendiente
                    WHERE (@accion IS NULL OR Accion = @accion)
                    ORDER BY ID_Edicion`);
        res.json(r.recordset);
    } catch (err) {
        console.error('GET /cuadro/edicion/pendientes error:', err);
        res.status(500).json({ error: 'Error al leer pendientes' });
    }
});

// POST /api/cuadro/edicion/:id/estado — el robot marca el resultado de aplicar en SAP.
// body: { estado: 'confirmado'|'error'|'enviado', error?: '...' }
router.post('/edicion/:id/estado', requireRobot, async (req, res) => {
    try {
        const id = parseInt(req.params.id);
        const estado = String(req.body.estado || '').toLowerCase();
        if (!id || !['confirmado', 'error', 'enviado'].includes(estado)) return res.status(400).json({ error: 'id/estado inválido' });
        const err = req.body.error != null ? String(req.body.error).slice(0, 1000) : null;
        const upd = await getPool().request()
            .input('id', sql.Int, id)
            .input('estado', sql.NVarChar(12), estado)
            .input('err', sql.NVarChar(1000), err)
            .query(`UPDATE dbo.CuadroEdicionCola
                    SET Estado = @estado,
                        Error = @err,
                        Intentos = Intentos + CASE WHEN @estado = 'error' THEN 1 ELSE 0 END,
                        FechaSync = CASE WHEN @estado = 'confirmado' THEN GETDATE() ELSE FechaSync END
                    WHERE ID_Edicion = @id AND Estado NOT IN ('cerrado')`);
        if (upd.rowsAffected[0] === 0) return res.status(404).json({ error: 'Edición no encontrada o ya cerrada' });
        res.json({ ok: true, estado });
    } catch (err) {
        console.error('POST /cuadro/edicion/:id/estado error:', err);
        res.status(500).json({ error: 'Error al actualizar estado' });
    }
});

// Puede imprimir (cuadro + pases): cualquiera con acceso a despacho del HUB.
function requirePrint(req, res, next) {
    const u = req.session && req.session.user;
    if (!u) return res.status(401).json({ error: 'No autenticado' });
    if (u.rol === 'Admin' || (u.permisos && (u.permisos.includes('despacho') || u.permisos.includes('priorizacion') || u.permisos.includes('reportes_operativo') || u.permisos.includes('reportes')))) return next();
    return res.status(403).json({ error: 'Sin permiso' });
}

// GET /api/cuadro/:routeNumber/roll — datos para imprimir "Cuadro + Pases" en un PDF:
//   - cuadro: armado desde el APP (encabezado + placa app-first + documentos actuales)
//   - pases: una entrega = un pase. OV → ODLN (parciales reales). TR → REQDEL por fecha.
router.get('/:routeNumber/roll', requirePrint, async (req, res) => {
    try {
        const rn = parseInt(req.params.routeNumber);
        if (!rn) return res.status(400).json({ error: 'RouteNumber requerido' });
        const pool = getPool();
        const db = getSapDb('GT');
        const lisa = getLisaDb('GT');

        // ── Encabezado: app (placa/capacidad/transportista) + SAP (planificador/chofer/tel) ──
        const appH = await pool.request().input('rn', sql.Int, rn)
            .query(`SELECT TOP 1 RouteNumber, RouteName, AlmacenOrigen, PlacaApp, CapacidadApp, IDCamionApp,
                           TransportistaApp, PlacaPendienteSync, ID_RoutePlan, EsComplemento
                    FROM dbo.OrderRoutePlan WHERE RouteNumber=@rn AND ID_Centro=3 AND Pais='GT'`);
        const A = appH.recordset[0];
        if (!A) return res.status(404).json({ error: 'Cuadro no encontrado en Escuintla' });

        let sapH = {};
        try {
            const r = await pool.request().input('rn', sql.Int, rn).query(`
                SELECT TOP 1 T0.U_NombreR, T0.U_ID_Camion, T0.U_Placa, T0.U_Chofer, T0.U_Capacidad,
                       T0.U_Fecha_Entrega, T0.U_TelPiloto, T0.U_Almacen_origen,
                       PLN.Name AS Planificador, ISNULL(PRV.CardName,'') AS Transportista
                FROM [server-sql].[${db}].dbo.[@CUADRO_RUTA_E] T0 WITH (NOLOCK)
                LEFT JOIN [server-sql].[${db}].dbo.[@PLANIFICADORES] PLN WITH (NOLOCK) ON T0.U_Planificador = PLN.Code COLLATE DATABASE_DEFAULT
                LEFT JOIN [server-sql].[${db}].dbo.OCRD PRV WITH (NOLOCK) ON T0.U_CardCode = PRV.CardCode
                WHERE T0.DocNum=@rn`);
            sapH = r.recordset[0] || {};
        } catch (e) { console.error('roll: SAP header no disponible:', e.message); }

        const placaApp = A.PlacaPendienteSync && A.PlacaApp && String(A.PlacaApp).trim() !== '';
        const placa = placaApp ? String(A.PlacaApp).trim() : String(sapH.U_Placa || '').trim();

        // ── Documentos del cuadro (desde el app) ──
        const docsRes = await pool.request().input('idrp', sql.Int, A.ID_RoutePlan)
            .query(`SELECT OV_Number, DocType, ISNULL(PesoTotal,0) AS Peso, ISNULL(Bultos,1) AS Bultos
                    FROM dbo.OrderPickingManagement WHERE ID_RoutePlan=@idrp AND NoDespachada=0
                    ORDER BY DocType, OV_Number`);
        const docs = docsRes.recordset;
        const ovInts = [...new Set(docs.filter(d => d.DocType === 'OV').map(d => parseInt(d.OV_Number)).filter(n => !isNaN(n)))];
        const trInts = [...new Set(docs.filter(d => ['TR', 'RESURTIDO'].includes(d.DocType)).map(d => parseInt(d.OV_Number)).filter(n => !isNaN(n)))];

        // Enriquecer clientes/dirección/asesor desde SAP (OV y TR)
        const cliMap = {};
        if (ovInts.length) {
            try {
                const r = await pool.request().query(`
                    SELECT o.DocNum, c.CardCode, c.CardName, ISNULL(o.Address2, c.Address) AS Direccion, s.SlpName AS Asesor, o.DocDueDate AS FechaEntrega
                    FROM [server-sql].[${db}].dbo.ORDR o WITH (NOLOCK)
                    LEFT JOIN [server-sql].[${db}].dbo.OCRD c WITH (NOLOCK) ON c.CardCode=o.CardCode
                    LEFT JOIN [server-sql].[${db}].dbo.OSLP s WITH (NOLOCK) ON s.SlpCode=o.SlpCode
                    WHERE o.DocNum IN (${ovInts.join(',')})`);
                r.recordset.forEach(x => { cliMap['OV' + x.DocNum] = x; });
            } catch (e) { console.error('roll: enriquecer OV:', e.message); }
        }
        if (trInts.length) {
            try {
                const r = await pool.request().query(`
                    SELECT q.DocNum, c.CardName, w.WhsName AS Destino, q.DocDueDate AS FechaEntrega
                    FROM [server-sql].[${db}].dbo.OWTQ q WITH (NOLOCK)
                    LEFT JOIN [server-sql].[${db}].dbo.OCRD c WITH (NOLOCK) ON c.CardCode=q.CardCode
                    LEFT JOIN [server-sql].[${db}].dbo.OWHS w WITH (NOLOCK) ON w.WhsCode=q.ToWhsCode
                    WHERE q.DocNum IN (${trInts.join(',')})`);
                r.recordset.forEach(x => { cliMap['TR' + x.DocNum] = x; });
            } catch (e) { console.error('roll: enriquecer TR:', e.message); }
        }

        let pesoTotal = 0;
        const lineas = docs.map(d => {
            const k = (d.DocType === 'OV' ? 'OV' : 'TR') + parseInt(d.OV_Number);
            const c = cliMap[k] || {};
            pesoTotal += Number(d.Peso) || 0;
            return {
                TipoDocumento: d.DocType,
                NumeroOV: d.OV_Number,
                ClienteCodigo: c.CardCode || '',
                ClienteNombre: c.CardName || (d.DocType === 'OV' ? '' : (c.Destino || '')),
                Direccion: (c.Direccion || c.Destino || '').replace(/\r/g, ' '),
                Asesor: c.Asesor || '',
                FechaEntrega: c.FechaEntrega || null,
                Peso: Number(d.Peso) || 0,
                Bultos: d.Bultos || 1
            };
        });

        const cuadro = {
            header: {
                DocNum: rn,
                NombreRuta: A.RouteName || sapH.U_NombreR || '',
                Placa: placa, PlacaPendiente: !!placaApp,
                Transporte: A.IDCamionApp || sapH.U_ID_Camion || '',
                Chofer: sapH.U_Chofer || '',
                Capacidad: (A.CapacidadApp != null ? A.CapacidadApp : sapH.U_Capacidad) || '',
                Transportista: A.TransportistaApp || sapH.Transportista || '',
                Planificador: sapH.Planificador || '',
                TelPiloto: sapH.U_TelPiloto || '',
                Almacen: A.AlmacenOrigen || sapH.U_Almacen_origen || '',
                FechaEntrega: sapH.U_Fecha_Entrega || null,
                PesoTotal: pesoTotal,
                EsComplemento: !!A.EsComplemento
            },
            lineas
        };

        // ── Pases: OV → ODLN (una entrega = un pase, parciales reales) ──
        const pases = [];
        const ovDeliv = {}; // OV -> [ {entrega, fecha, cliente, direccion, lineas:[]} ]
        if (ovInts.length) {
            try {
                const heads = await pool.request().query(`
                    SELECT dln.DocEntry, dln.DocNum AS Entrega, dln.DocDate, l.BaseRef AS OV,
                           dln.CardName, ISNULL(dln.Address2, dln.Address) AS Direccion, dln.Comments
                    FROM [server-sql].[${db}].dbo.DLN1 l WITH (NOLOCK)
                    JOIN [server-sql].[${db}].dbo.ODLN dln WITH (NOLOCK) ON dln.DocEntry = l.DocEntry
                    WHERE l.BaseType=17 AND l.BaseRef IN ('${ovInts.join("','")}')
                    GROUP BY dln.DocEntry, dln.DocNum, dln.DocDate, l.BaseRef, dln.CardName, dln.Address2, dln.Address, dln.Comments`);
                const linesR = await pool.request().query(`
                    SELECT l.DocEntry, l.BaseRef AS OV, l.ItemCode AS Codigo, MAX(l.Dscription) AS Nombre, SUM(l.Quantity) AS Cant
                    FROM [server-sql].[${db}].dbo.DLN1 l WITH (NOLOCK)
                    WHERE l.BaseType=17 AND l.BaseRef IN ('${ovInts.join("','")}')
                    GROUP BY l.DocEntry, l.BaseRef, l.ItemCode`);
                const linesByKey = {};
                linesR.recordset.forEach(r => {
                    const key = r.DocEntry + '|' + r.OV;
                    (linesByKey[key] = linesByKey[key] || []).push({ codigo: r.Codigo, nombre: r.Nombre, cantidad: Number(r.Cant) });
                });
                heads.recordset.forEach(h => {
                    const key = h.DocEntry + '|' + h.OV;
                    (ovDeliv[h.OV] = ovDeliv[h.OV] || []).push({
                        entrega: String(h.Entrega), fecha: h.DocDate, cliente: h.CardName,
                        direccion: (h.Direccion || '').replace(/\r/g, ' '), comentarios: h.Comments || '',
                        lineas: linesByKey[key] || []
                    });
                });
            } catch (e) { console.error('roll: pases OV (ODLN):', e.message); }
        }

        // ── Pases: TR → REQDEL agrupado por fecha ──
        const trDeliv = {};
        if (trInts.length) {
            try {
                const r = await pool.request().query(`
                    SELECT itl.DocNumSAP AS TR, CONVERT(date, itl.DateTimeTransaction) AS Fecha,
                           itl.InternIDProduct AS Codigo, MAX(p.ProductName) AS Nombre, SUM(itl.OldQty - itl.NewQty) AS Cant
                    FROM [server-sql].[${lisa}].dbo.InventoryTransactionLog itl WITH (NOLOCK)
                    LEFT JOIN [server-sql].[${lisa}].dbo.Product p WITH (NOLOCK) ON p.IDProduct = itl.IDProduct
                    WHERE itl.TransactionType='REQDEL' AND itl.OldQty > itl.NewQty AND itl.DocNumSAP IN (${trInts.join(',')})
                    GROUP BY itl.DocNumSAP, CONVERT(date, itl.DateTimeTransaction), itl.InternIDProduct
                    ORDER BY itl.DocNumSAP, Fecha`);
                r.recordset.forEach(x => {
                    const tr = String(x.TR), fkey = (x.Fecha instanceof Date ? x.Fecha.toISOString().slice(0, 10) : String(x.Fecha).slice(0, 10));
                    trDeliv[tr] = trDeliv[tr] || {};
                    (trDeliv[tr][fkey] = trDeliv[tr][fkey] || { fecha: x.Fecha, lineas: [] }).lineas.push({ codigo: x.Codigo, nombre: x.Nombre, cantidad: Number(x.Cant) });
                });
            } catch (e) { console.error('roll: pases TR (REQDEL):', e.message); }
        }

        // Ensamblar pases en el orden de los documentos del cuadro
        docs.forEach(d => {
            const num = String(parseInt(d.OV_Number));
            if (d.DocType === 'OV') {
                (ovDeliv[num] || []).sort((a, b) => new Date(a.fecha) - new Date(b.fecha)).forEach(dv => {
                    const c = cliMap['OV' + num] || {};
                    pases.push({ tipo: 'OV', doc: d.OV_Number, entrega: dv.entrega, fecha: dv.fecha,
                        cliente: dv.cliente || c.CardName || '', direccion: dv.direccion || (c.Direccion || ''),
                        asesor: c.Asesor || '', lineas: dv.lineas });
                });
            } else if (['TR', 'RESURTIDO'].includes(d.DocType)) {
                const byDate = trDeliv[num] || {};
                Object.keys(byDate).sort().forEach(fkey => {
                    const dv = byDate[fkey]; const c = cliMap['TR' + num] || {};
                    pases.push({ tipo: 'TR', doc: d.OV_Number, entrega: fkey, fecha: dv.fecha,
                        cliente: c.CardName || '', destino: c.Destino || '', direccion: c.Destino || '',
                        lineas: dv.lineas });
                });
            }
        });

        res.json({ pais: 'GT', cuadro, pases, sinPase: lineas.filter(l => {
            const num = String(parseInt(l.NumeroOV));
            return l.TipoDocumento === 'OV' ? !(ovDeliv[num] && ovDeliv[num].length) : !(trDeliv[num] && Object.keys(trDeliv[num]).length);
        }).map(l => `${l.TipoDocumento} ${l.NumeroOV}`) });
    } catch (err) {
        console.error('GET /cuadro/:rn/roll error:', err);
        res.status(500).json({ error: 'Error al armar el cuadro + pases' });
    }
});

module.exports = router;
