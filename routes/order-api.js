const express = require('express');
const { getPool, sql } = require('../db');
const { getSapDb } = require('../config/paises');
const { requirePermiso } = require('../middleware/auth');
const router = express.Router();

// HUB Escuintla — único centro GT en modo pedido; la priorización inline solo aplica aquí
const CENTRO_ESCUINTLA = 3;

// Trae { OV_Number: { name, address } } desde SAP para un conjunto de OVs (por país).
// address = dirección de entrega (ship-to = ORDR.Address2), fallback a facturación (Address).
async function getClientesSAP(pool, pais, ovNumbers) {
    const map = {};
    const ovInts = [...new Set(ovNumbers.map(v => parseInt(v)).filter(v => !isNaN(v)))];
    if (ovInts.length === 0) return map;
    const sapDb = getSapDb(pais);
    const req = pool.request();
    const inParams = ovInts.map((v, i) => { req.input('ov' + i, sql.Int, v); return '@ov' + i; }).join(',');
    try {
        const r = await req.query(`
            SELECT o.DocNum AS OV, MAX(c.CardName) AS CardName,
                   MAX(ISNULL(NULLIF(o.Address2, ''), o.Address)) AS ShipTo,
                   MAX(o.Comments) AS Comentarios
            FROM [server-sql].[${sapDb}].dbo.ORDR o WITH (NOLOCK)
            LEFT JOIN [server-sql].[${sapDb}].dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
            WHERE o.DocNum IN (${inParams})
            GROUP BY o.DocNum`);
        r.recordset.forEach(row => { map[String(row.OV)] = { name: row.CardName, address: row.ShipTo, comentarios: row.Comentarios }; });
    } catch (e) { console.error('getClientesSAP error:', e.message); }
    return map;
}

// Trae { TR_DocNum: { destino, comentarios } } para traslados (OWTQ) desde SAP.
// El destino de un TR es OWTQ.ToWhsCode → nombre en OWHS.
async function getTrasladosDestinoSAP(pool, pais, trNumbers) {
    const map = {};
    const ints = [...new Set(trNumbers.map(v => parseInt(v)).filter(v => !isNaN(v)))];
    if (ints.length === 0) return map;
    const sapDb = getSapDb(pais);
    const req = pool.request();
    const inParams = ints.map((v, i) => { req.input('tr' + i, sql.Int, v); return '@tr' + i; }).join(',');
    try {
        const r = await req.query(`
            SELECT o.DocNum AS TR,
                   MAX(o.ToWhsCode) AS ToWhs,
                   MAX(wh.WhsName) AS Destino,
                   MAX(o.Comments) AS Comentarios
            FROM [server-sql].[${sapDb}].dbo.OWTQ o WITH (NOLOCK)
            LEFT JOIN [server-sql].[${sapDb}].dbo.OWHS wh WITH (NOLOCK) ON wh.WhsCode = o.ToWhsCode
            WHERE o.DocNum IN (${inParams})
            GROUP BY o.DocNum`);
        r.recordset.forEach(row => {
            map[String(row.TR)] = {
                destino: row.Destino || (row.ToWhs ? ('Almacén ' + row.ToWhs) : null),
                comentarios: row.Comentarios || null
            };
        });
    } catch (e) { console.error('getTrasladosDestinoSAP error:', e.message); }
    return map;
}

// Helper: get user's active centro(s) from session
// If a centro is selected, return only that one; otherwise return all assigned
function getUserCentros(req) {
    if (!req.session || !req.session.user) return null;
    const user = req.session.user;
    if (user.selectedCentro) return [user.selectedCentro];
    return user.centros;
}

// Helper: build centro filter clause and bind params
function buildCentroFilter(request, centros, tableAlias = 'c') {
    if (!centros || centros.length === 0) return '';
    const params = centros.map((_, i) => `@uc${i}`).join(',');
    centros.forEach((c, i) => request.input(`uc${i}`, sql.Int, c));
    return ` AND ${tableAlias}.ID_Centro IN (${params})`;
}

// ══════════════════════════════════════════
// ── Gestión: Rutas por Pedido (Order)
// ══════════════════════════════════════════

// GET /api/order/rutas — List order routes with centro filtering
router.get('/rutas', async (req, res) => {
    try {
        const pool = getPool();
        const centros = getUserCentros(req);
        // Mantener las prioridades de Escuintla contiguas (1..N) — capta completados/removidos
        if (!centros || centros.includes(CENTRO_ESCUINTLA)) {
            await pool.request().execute('SP_NormalizeEscuintlaPriorities');
        }
        const request = pool.request();
        const centroFilter = buildCentroFilter(request, centros, 'orp');

        const result = await request.query(`
            SELECT
                orp.ID_RoutePlan,
                orp.RouteNumber,
                orp.RouteName,
                orp.FechaPlanificacion,
                orp.AlmacenOrigen,
                orp.Estado,
                orp.FechaInicio,
                orp.FechaFin,
                orp.ID_Carril,
                orp.EstadoDespacho,
                orp.ID_Centro,
                orp.Pais,
                orp.Prioridad,
                c.Nombre AS CarrilNombre,
                cd.Nombre AS CentroNombre,
                ISNULL(opm.TotalPedidos, 0) AS TotalPedidos,
                ISNULL(opm.TotalLineas, 0) AS TotalLineas,
                ISNULL(opm.PesoTotal, 0) AS PesoTotal,
                ISNULL(opm.PedidosFinalizados, 0) AS PedidosFinalizados,
                (SELECT MAX(t.UltimaActualizacion) FROM OrderPickingTask t
                 INNER JOIN OrderPickingManagement o2 ON o2.ID_OrderPicking = t.ID_OrderPicking
                 WHERE o2.ID_RoutePlan = orp.ID_RoutePlan) AS UltimaTransaccion
            FROM OrderRoutePlan orp
            LEFT JOIN Carril c ON c.ID_Carril = orp.ID_Carril
            LEFT JOIN CentroDistribucion cd ON cd.ID_Centro = orp.ID_Centro
            LEFT JOIN (
                SELECT ID_RoutePlan,
                       COUNT(*) AS TotalPedidos,
                       SUM(ISNULL(TotalLineas, 0)) AS TotalLineas,
                       SUM(ISNULL(PesoTotal, 0)) AS PesoTotal,
                       SUM(CASE WHEN Estado = 'Finalizado' THEN 1 ELSE 0 END) AS PedidosFinalizados
                FROM OrderPickingManagement
                GROUP BY ID_RoutePlan
            ) opm ON opm.ID_RoutePlan = orp.ID_RoutePlan
            WHERE (orp.Estado IN ('Pendiente', 'Iniciado')
               OR (orp.Estado = 'Finalizado' AND orp.FechaFin > DATEADD(MINUTE, -30, GETDATE())))
               ${centroFilter}
            ORDER BY
                CASE orp.Estado
                    WHEN 'Iniciado' THEN 0
                    WHEN 'Pendiente' THEN 1
                    WHEN 'Finalizado' THEN 2
                END,
                ISNULL(orp.Prioridad, 999999),
                orp.FechaPlanificacion DESC
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/order/rutas error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// GET /api/order/rutas/:id/pedidos — List OVs for a route
router.get('/rutas/:id/pedidos', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('idRoutePlan', sql.Int, parseInt(req.params.id))
            .query(`
                SELECT
                    opm.ID_OrderPicking,
                    opm.RouteNumber,
                    opm.OV_Number,
                    opm.DocType,
                    opm.IDCustomerOrder,
                    opm.IdAccountableOrder,
                    opm.TotalLineas,
                    opm.TotalUnidades,
                    opm.PesoTotal,
                    opm.Estado,
                    opm.ID_Operario,
                    opm.FechaAsignacion,
                    opm.FechaInicio,
                    opm.FechaFin,
                    o.Nombre AS OperarioNombre,
                    (SELECT MAX(t.UltimaActualizacion) FROM OrderPickingTask t
                     WHERE t.ID_OrderPicking = opm.ID_OrderPicking) AS UltimaTransaccion,
                    -- Desglose de asignación por línea (para detectar OV "repartida")
                    (SELECT COUNT(DISTINCT t.ID_Operario) FROM OrderPickingTask t
                     WHERE t.ID_OrderPicking = opm.ID_OrderPicking AND t.ID_Operario IS NOT NULL) AS PickersDistintos,
                    STUFF((SELECT DISTINCT ', ' + o2.Nombre
                           FROM OrderPickingTask t2
                           INNER JOIN Operario o2 ON o2.ID_Operario = t2.ID_Operario
                           WHERE t2.ID_OrderPicking = opm.ID_OrderPicking
                           FOR XML PATH('')), 1, 2, '') AS PickersNombres
                FROM OrderPickingManagement opm
                LEFT JOIN Operario o ON o.ID_Operario = opm.ID_Operario
                WHERE opm.ID_RoutePlan = @idRoutePlan
                ORDER BY
                    CASE opm.Estado
                        WHEN 'En Proceso' THEN 0
                        WHEN 'Asignado' THEN 1
                        WHEN 'Pendiente' THEN 2
                        WHEN 'Finalizado' THEN 3
                    END,
                    opm.OV_Number
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/order/rutas/:id/pedidos error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// GET /api/order/rutas/:id/resumen — Route summary
router.get('/rutas/:id/resumen', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('idRoutePlan', sql.Int, parseInt(req.params.id))
            .query(`
                SELECT
                    COUNT(*) AS TotalPedidos,
                    SUM(CASE WHEN Estado = 'Finalizado' THEN 1 ELSE 0 END) AS PedidosFinalizados,
                    SUM(CASE WHEN Estado IN ('Asignado','En Proceso') THEN 1 ELSE 0 END) AS PedidosAsignados,
                    SUM(CASE WHEN Estado = 'Pendiente' THEN 1 ELSE 0 END) AS PedidosPendientes,
                    SUM(ISNULL(TotalLineas, 0)) AS TotalLineas,
                    SUM(ISNULL(TotalUnidades, 0)) AS TotalUnidades,
                    SUM(ISNULL(PesoTotal, 0)) AS PesoTotal
                FROM OrderPickingManagement
                WHERE ID_RoutePlan = @idRoutePlan
            `);
        const resumen = result.recordset[0] || {};

        // Avance de picking: líneas/unidades/kg ya pickeados (desde las tareas).
        // Cantidad/CantidadPendiente se repiten por fila de tarea → MAX por producto.
        try {
            const av = await pool.request()
                .input('idRoutePlan', sql.Int, parseInt(req.params.id))
                .query(`
                    ;WITH prod AS (
                        SELECT opt.ID_OrderPicking, opt.InternIdProduct,
                               MAX(ISNULL(opt.Cantidad, 0)) AS Cant,
                               MAX(ISNULL(opt.CantidadPendiente, 0)) AS Pend,
                               MAX(ISNULL(opt.UnitWeight, 0)) AS UW
                        FROM OrderPickingTask opt
                        INNER JOIN OrderPickingManagement opm ON opm.ID_OrderPicking = opt.ID_OrderPicking
                        WHERE opm.ID_RoutePlan = @idRoutePlan
                        GROUP BY opt.ID_OrderPicking, opt.InternIdProduct
                    )
                    SELECT
                        SUM(CASE WHEN Pend = 0 THEN 1 ELSE 0 END) AS LineasFinalizadas,
                        SUM(Cant - Pend) AS UnidadesPickeadas,
                        SUM((Cant - Pend) * UW) AS PesoPickeado
                    FROM prod
                `);
            const a = av.recordset[0] || {};
            resumen.LineasFinalizadas = a.LineasFinalizadas || 0;
            resumen.UnidadesPickeadas = a.UnidadesPickeadas || 0;
            resumen.PesoPickeado = a.PesoPickeado || 0;
        } catch (e) { console.error('avance resumen (order):', e.message); }

        res.json(resumen);
    } catch (err) {
        console.error('GET /api/order/rutas/:id/resumen error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// GET /api/order/pickers-activos — pickers activos del CEDI (todas las rutas Iniciadas): tareas pendientes + última transacción
router.get('/pickers-activos', async (req, res) => {
    try {
        const pool = getPool();
        const centros = getUserCentros(req);
        const request = pool.request();
        const centroFilter = buildCentroFilter(request, centros, 'orp');
        const result = await request.query(`
            SELECT
                o.ID_Operario,
                o.Nombre AS OperarioNombre,
                SUM(CASE WHEN t.Estado <> 'Finalizado' THEN 1 ELSE 0 END) AS TareasPendientes,
                COUNT(DISTINCT CASE WHEN t.Estado <> 'Finalizado' THEN orp.ID_RoutePlan END) AS RutasActivas,
                MAX(t.UltimaActualizacion) AS UltimaTransaccion
            FROM OrderPickingTask t
            INNER JOIN OrderPickingManagement opm ON opm.ID_OrderPicking = t.ID_OrderPicking
            INNER JOIN OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
            INNER JOIN Operario o ON o.ID_Operario = t.ID_Operario
            WHERE t.ID_Operario IS NOT NULL AND orp.Estado = 'Iniciado'${centroFilter}
            GROUP BY o.ID_Operario, o.Nombre
            HAVING SUM(CASE WHEN t.Estado <> 'Finalizado' THEN 1 ELSE 0 END) > 0
            ORDER BY MAX(t.UltimaActualizacion) ASC
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/order/pickers-activos error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// POST /api/order/rutas/:id/iniciar — Start a route (with optional carril)
router.post('/rutas/:id/iniciar', async (req, res) => {
    try {
        const pool = getPool();
        const { idCarril } = req.body || {};
        const request = pool.request()
            .input('idRoutePlan', sql.Int, parseInt(req.params.id));

        let setClause = `Estado = 'Iniciado', FechaInicio = GETDATE()`;
        if (idCarril) {
            request.input('idCarril', sql.Int, parseInt(idCarril));
            setClause += `, ID_Carril = @idCarril, EstadoDespacho = 'Pendiente'`;
        }

        await request.query(`
            UPDATE OrderRoutePlan
            SET ${setClause}
            WHERE ID_RoutePlan = @idRoutePlan AND Estado = 'Pendiente'
        `);
        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/order/rutas/:id/iniciar error:', err);
        res.status(500).json({ error: 'Error al iniciar ruta' });
    }
});

// POST /api/order/rutas/:id/finalizar — Finalize entire route
router.post('/rutas/:id/finalizar', async (req, res) => {
    try {
        const pool = getPool();
        const id = parseInt(req.params.id);

        // Close all tasks
        await pool.request()
            .input('idRoutePlan', sql.Int, id)
            .query(`
                UPDATE opt
                SET opt.CantidadPendiente = 0, opt.UltimaActualizacion = GETDATE()
                FROM OrderPickingTask opt
                INNER JOIN OrderPickingManagement opm ON opm.ID_OrderPicking = opt.ID_OrderPicking
                WHERE opm.ID_RoutePlan = @idRoutePlan AND opt.Estado <> 'Finalizado'
            `);

        // Close all pedidos
        await pool.request()
            .input('idRoutePlan', sql.Int, id)
            .query(`
                UPDATE OrderPickingManagement
                SET Estado = 'Finalizado', FechaFin = GETDATE()
                WHERE ID_RoutePlan = @idRoutePlan AND Estado <> 'Finalizado'
            `);

        // Close route
        await pool.request()
            .input('idRoutePlan', sql.Int, id)
            .query(`
                UPDATE OrderRoutePlan
                SET Estado = 'Finalizado', FechaFin = GETDATE()
                WHERE ID_RoutePlan = @idRoutePlan AND Estado <> 'Finalizado'
            `);

        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/order/rutas/:id/finalizar error:', err);
        res.status(500).json({ error: 'Error al finalizar ruta' });
    }
});

// POST /api/order/rutas/:id/reimportar — Re-sync líneas/pedidos contra el cuadro actual (SV/HN)
router.post('/rutas/:id/reimportar', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('idRoutePlan', sql.Int, parseInt(req.params.id))
            .query('EXEC dbo.SP_ReimportOrderRouteLines @ID_RoutePlan = @idRoutePlan');
        const resumen = result.recordset && result.recordset[0]
            ? result.recordset[0]
            : { PedidosAgregados: 0, LineasAgregadas: 0, LineasEliminadas: 0, PedidosEliminados: 0 };
        res.json({ ok: true, resumen });
    } catch (err) {
        console.error('POST /api/order/rutas/:id/reimportar error:', err);
        // El SP usa RAISERROR para casos controlados (cuadro vacío, línea sin match, etc.)
        res.status(500).json({ error: err.message || 'Error al re-importar líneas' });
    }
});

// ══════════════════════════════════════════
// ── Asignación de Pedidos a Operarios
// ══════════════════════════════════════════

// POST /api/order/pedidos/asignar — Assign operario to an OV (entire pedido)
router.post('/pedidos/asignar', async (req, res) => {
    try {
        const { idOrderPicking, operarioId, pickerId } = req.body;
        const idOperario = operarioId || pickerId;
        if (!idOrderPicking || !idOperario) {
            return res.status(400).json({ error: 'idOrderPicking y operarioId requeridos' });
        }
        const pool = getPool();

        // Candado: el operario debe pertenecer al MISMO centro que el pedido
        // (evita asignar, p.ej., un operario de Zona 5 a un pedido de Escuintla —
        //  típico cuando hay operarios con el mismo nombre en distintos CEDIs).
        const chk = await pool.request()
            .input('idOrderPicking', sql.Int, idOrderPicking)
            .input('operarioId', sql.Int, idOperario)
            .query(`
                SELECT opm.ID_Centro AS PedidoCentro, o.ID_Centro AS OperarioCentro,
                       o.Nombre AS OperarioNombre, cd.Nombre AS CentroPedido
                FROM OrderPickingManagement opm
                CROSS JOIN Operario o
                LEFT JOIN CentroDistribucion cd ON cd.ID_Centro = opm.ID_Centro
                WHERE opm.ID_OrderPicking = @idOrderPicking AND o.ID_Operario = @operarioId
            `);
        if (chk.recordset.length === 0) {
            return res.status(404).json({ error: 'Pedido u operario no encontrado' });
        }
        const row = chk.recordset[0];
        if (row.PedidoCentro !== row.OperarioCentro) {
            return res.status(400).json({
                error: `El operario "${row.OperarioNombre}" no pertenece a ${row.CentroPedido || 'este CEDI'}. Asigná un operario del mismo centro.`
            });
        }

        // The trigger on OrderPickingManagement handles:
        // - Setting Estado='Asignado', FechaAsignacion
        // - Cascading to OrderPickingTask (Estado='En Proceso', ID_Operario)
        await pool.request()
            .input('idOrderPicking', sql.Int, idOrderPicking)
            .input('operarioId', sql.Int, idOperario)
            .query(`
                UPDATE OrderPickingManagement
                SET ID_Operario = @operarioId
                WHERE ID_OrderPicking = @idOrderPicking
            `);
        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/order/pedidos/asignar error:', err);
        res.status(500).json({ error: 'Error al asignar operario' });
    }
});

// POST /api/order/pedidos/asignar-lineas — Asignar líneas (tareas) sueltas a un operario.
// Permite repartir una OV entre varios pickers. NO toca OPM.ID_Operario (para no
// disparar el trigger que cascada a todas las líneas); solo marca las tareas dadas.
router.post('/pedidos/asignar-lineas', async (req, res) => {
    try {
        const { idOrderPicking, idTasks, operarioId, pickerId } = req.body;
        const idOperario = operarioId || pickerId;
        const tasks = Array.isArray(idTasks) ? idTasks.map(n => parseInt(n)).filter(n => !isNaN(n)) : [];
        if (!idOrderPicking || !idOperario || tasks.length === 0) {
            return res.status(400).json({ error: 'idOrderPicking, operarioId e idTasks requeridos' });
        }
        const pool = getPool();

        // Candado: operario del mismo centro que el pedido
        const chk = await pool.request()
            .input('idOrderPicking', sql.Int, idOrderPicking)
            .input('operarioId', sql.Int, idOperario)
            .query(`
                SELECT opm.ID_Centro AS PedidoCentro, o.ID_Centro AS OperarioCentro,
                       o.Nombre AS OperarioNombre, cd.Nombre AS CentroPedido
                FROM OrderPickingManagement opm
                CROSS JOIN Operario o
                LEFT JOIN CentroDistribucion cd ON cd.ID_Centro = opm.ID_Centro
                WHERE opm.ID_OrderPicking = @idOrderPicking AND o.ID_Operario = @operarioId
            `);
        if (chk.recordset.length === 0) return res.status(404).json({ error: 'Pedido u operario no encontrado' });
        const row = chk.recordset[0];
        if (row.PedidoCentro !== row.OperarioCentro) {
            return res.status(400).json({
                error: `El operario "${row.OperarioNombre}" no pertenece a ${row.CentroPedido || 'este CEDI'}. Asigná un operario del mismo centro.`
            });
        }

        // Asignar las tareas indicadas (solo del pedido dado, por seguridad).
        // Las ya finalizadas no se reasignan (conservan su histórico).
        const reqUpd = pool.request()
            .input('idOrderPicking', sql.Int, idOrderPicking)
            .input('operarioId', sql.Int, idOperario);
        const inParams = tasks.map((v, i) => { reqUpd.input('t' + i, sql.Int, v); return '@t' + i; }).join(',');
        const upd = await reqUpd.query(`
            UPDATE OrderPickingTask
            SET ID_Operario = @operarioId,
                Estado = CASE WHEN ISNULL(CantidadPendiente, 0) > 0 THEN 'En Proceso' ELSE Estado END,
                FechaLiberacion = ISNULL(FechaLiberacion, GETDATE()),
                UltimaActualizacion = GETDATE()
            WHERE ID_OrderPicking = @idOrderPicking
              AND ID_Task IN (${inParams})
              AND Estado <> 'Finalizado';

            -- El encabezado pasa a 'En Proceso' si estaba Pendiente (sin tocar ID_Operario)
            UPDATE OrderPickingManagement
            SET Estado = 'En Proceso', FechaAsignacion = ISNULL(FechaAsignacion, GETDATE())
            WHERE ID_OrderPicking = @idOrderPicking AND Estado = 'Pendiente';
        `);
        res.json({ ok: true, asignadas: upd.rowsAffected && upd.rowsAffected[0] ? upd.rowsAffected[0] : 0 });
    } catch (err) {
        console.error('POST /api/order/pedidos/asignar-lineas error:', err);
        res.status(500).json({ error: 'Error al asignar líneas' });
    }
});

// POST /api/order/pedidos/cerrar — Force-close a pedido
router.post('/pedidos/cerrar', async (req, res) => {
    try {
        const { idOrderPicking } = req.body;
        if (!idOrderPicking) {
            return res.status(400).json({ error: 'idOrderPicking requerido' });
        }
        const pool = getPool();

        // Close all tasks for this pedido
        await pool.request()
            .input('idOrderPicking', sql.Int, idOrderPicking)
            .query(`
                UPDATE OrderPickingTask
                SET CantidadPendiente = 0, UltimaActualizacion = GETDATE()
                WHERE ID_OrderPicking = @idOrderPicking AND Estado <> 'Finalizado'
            `);

        // Close the pedido
        await pool.request()
            .input('idOrderPicking', sql.Int, idOrderPicking)
            .query(`
                UPDATE OrderPickingManagement
                SET Estado = 'Finalizado', FechaFin = GETDATE()
                WHERE ID_OrderPicking = @idOrderPicking AND Estado <> 'Finalizado'
            `);

        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/order/pedidos/cerrar error:', err);
        res.status(500).json({ error: 'Error al cerrar pedido' });
    }
});

// GET /api/order/pedidos/:id/tareas — Get tasks (lines) for a pedido
router.get('/pedidos/:id/tareas', async (req, res) => {
    try {
        const pool = getPool();
        // operarioId opcional: contexto picker → solo sus líneas. Gestión no lo manda → todas.
        const operarioId = req.query.operarioId ? parseInt(req.query.operarioId) : null;
        const reqDb = pool.request().input('idOrderPicking', sql.Int, parseInt(req.params.id));
        if (operarioId) reqDb.input('operarioId', sql.Int, operarioId);
        const result = await reqDb.query(`
                SELECT
                    t.ID_Task,
                    t.InternIdProduct,
                    t.Descripcion,
                    t.Cantidad,
                    t.CantidadPendiente,
                    t.UnitWeight,
                    t.Estado,
                    t.ID_Operario,
                    o.Nombre AS OperarioNombre,
                    t.UltimaActualizacion
                FROM OrderPickingTask t
                LEFT JOIN Operario o ON o.ID_Operario = t.ID_Operario
                WHERE t.ID_OrderPicking = @idOrderPicking
                  ${operarioId ? 'AND t.ID_Operario = @operarioId' : ''}
                ORDER BY
                    CASE t.Estado WHEN 'Finalizado' THEN 1 ELSE 0 END,
                    t.InternIdProduct
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/order/pedidos/:id/tareas error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// ══════════════════════════════════════════
// ── Priorización de Rutas Order
// ══════════════════════════════════════════

router.get('/priorizacion/rutas', async (req, res) => {
    try {
        const pool = getPool();
        const centros = getUserCentros(req);
        const request = pool.request();
        const centroFilter = buildCentroFilter(request, centros, 'orp');

        const result = await request.query(`
            SELECT
                orp.ID_RoutePlan,
                orp.RouteNumber,
                orp.RouteName,
                orp.FechaPlanificacion,
                orp.AlmacenOrigen,
                orp.Estado,
                orp.Prioridad,
                orp.FechaInicio,
                orp.ID_Centro,
                orp.Pais,
                ISNULL(orp.PesoEstimado, 0) AS PesoTotal,
                CASE WHEN orp.Estado = 'Iniciado'
                     THEN ISNULL(orp.PesoEstimado, 0) - ISNULL(opm.PesoFinalizado, 0)
                     ELSE ISNULL(orp.PesoEstimado, 0)
                END AS PesoPendiente,
                ISNULL(opm.TotalPedidos, 0) AS TotalPedidos,
                ISNULL(opm.PedidosFinalizados, 0) AS PedidosFinalizados
            FROM OrderRoutePlan orp
            LEFT JOIN (
                SELECT ID_RoutePlan,
                       COUNT(*) AS TotalPedidos,
                       SUM(CASE WHEN Estado = 'Finalizado' THEN 1 ELSE 0 END) AS PedidosFinalizados,
                       SUM(CASE WHEN Estado = 'Finalizado' THEN ISNULL(PesoTotal, 0) ELSE 0 END) AS PesoFinalizado
                FROM OrderPickingManagement
                GROUP BY ID_RoutePlan
            ) opm ON opm.ID_RoutePlan = orp.ID_RoutePlan
            WHERE orp.Estado IN ('Iniciado', 'Pendiente')
              AND (orp.Estado = 'Iniciado' OR orp.FechaPlanificacion >= DATEADD(DAY, -3, CAST(GETDATE() AS DATE)))
              AND orp.ID_Centro <> ${CENTRO_ESCUINTLA}  -- Escuintla prioriza inline en gestión
              ${centroFilter}
            ORDER BY
                CASE orp.Estado WHEN 'Iniciado' THEN 0 ELSE 1 END,
                ISNULL(orp.Prioridad, 999999),
                orp.FechaPlanificacion DESC
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/order/priorizacion/rutas error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// POST /priorizacion/set — fija la prioridad de UNA ruta (edición inline en gestión).
// Solo HUB Escuintla, rutas Pendientes o Iniciadas; requiere permiso 'priorizacion'.
router.post('/priorizacion/set', requirePermiso('priorizacion'), async (req, res) => {
    try {
        const id = parseInt(req.body.id_routePlan);
        if (!id) return res.status(400).json({ error: 'id_routePlan requerido' });

        const raw = req.body.prioridad;
        let prio = null; // vacío = quitar prioridad
        if (raw !== null && raw !== undefined && String(raw).trim() !== '') {
            prio = parseInt(raw);
            if (isNaN(prio) || prio < 1) return res.status(400).json({ error: 'Prioridad inválida' });
        }

        const pool = getPool();
        const result = await pool.request()
            .input('id', sql.Int, id)
            .input('prio', sql.Int, prio)
            .input('centro', sql.Int, CENTRO_ESCUINTLA)
            .query(`
                UPDATE OrderRoutePlan
                SET Prioridad = @prio
                WHERE ID_RoutePlan = @id AND ID_Centro = @centro
                  AND Estado IN ('Pendiente', 'Iniciado')
            `);

        if (result.rowsAffected[0] === 0) {
            return res.status(404).json({ error: 'Ruta no encontrada, no pertenece a Escuintla o ya está finalizada' });
        }
        // Recompactar prioridades (1..N contiguas) tras el cambio
        await pool.request().execute('SP_NormalizeEscuintlaPriorities');
        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/order/priorizacion/set error:', err);
        res.status(500).json({ error: 'Error al guardar prioridad' });
    }
});

router.post('/priorizacion/guardar', async (req, res) => {
    try {
        const { orden } = req.body;
        if (!Array.isArray(orden)) {
            return res.status(400).json({ error: 'Se requiere un array de IDs' });
        }
        const pool = getPool();
        for (let i = 0; i < orden.length; i++) {
            await pool.request()
                .input('idRoutePlan', sql.Int, orden[i])
                .input('prioridad', sql.Int, i + 1)
                .query(`
                    UPDATE OrderRoutePlan
                    SET Prioridad = @prioridad
                    WHERE ID_RoutePlan = @idRoutePlan AND Estado = 'Pendiente'
                      AND ID_Centro <> ${CENTRO_ESCUINTLA}
                `);
        }
        res.json({ ok: true, actualizadas: orden.length });
    } catch (err) {
        console.error('POST /api/order/priorizacion/guardar error:', err);
        res.status(500).json({ error: 'Error al guardar prioridades' });
    }
});

// ══════════════════════════════════════════
// ── Despacho Order
// ══════════════════════════════════════════

router.get('/despacho/rutas', async (req, res) => {
    try {
        const pool = getPool();
        const centros = getUserCentros(req);
        const request = pool.request();
        const centroFilter = buildCentroFilter(request, centros, 'orp');

        const result = await request.query(`
            SELECT
                orp.ID_RoutePlan,
                orp.RouteNumber,
                orp.RouteName,
                orp.Estado,
                orp.EstadoDespacho,
                orp.FechaDespachoFin,
                orp.ID_Carril,
                orp.ID_Centro,
                orp.Pais,
                c.Nombre AS CarrilNombre,
                cd.Nombre AS CentroNombre,
                ISNULL(orp.PesoEstimado, 0) AS PesoEstimado,
                ISNULL(opm.TotalPedidos, 0) AS TotalPedidos,
                ISNULL(opm.PedidosFinalizados, 0) AS PedidosFinalizados
            FROM OrderRoutePlan orp
            LEFT JOIN Carril c ON c.ID_Carril = orp.ID_Carril
            LEFT JOIN CentroDistribucion cd ON cd.ID_Centro = orp.ID_Centro
            LEFT JOIN (
                SELECT ID_RoutePlan,
                       COUNT(*) AS TotalPedidos,
                       SUM(CASE WHEN Estado = 'Finalizado' THEN 1 ELSE 0 END) AS PedidosFinalizados
                FROM OrderPickingManagement
                GROUP BY ID_RoutePlan
            ) opm ON opm.ID_RoutePlan = orp.ID_RoutePlan
            WHERE orp.ID_Carril IS NOT NULL
              AND (
                  (orp.Estado IN ('Iniciado', 'Finalizado') AND orp.EstadoDespacho IN ('Pendiente', 'Listo para Carga'))
                  OR (orp.EstadoDespacho = 'Finalizado' AND orp.FechaDespachoFin > DATEADD(MINUTE, -2, GETDATE()))
              )
              ${centroFilter}
            ORDER BY c.Nombre, orp.RouteNumber
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/order/despacho/rutas error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

router.post('/despacho/estado', async (req, res) => {
    try {
        const { idRoutePlan, estado } = req.body;
        if (!idRoutePlan || !estado) {
            return res.status(400).json({ error: 'idRoutePlan y estado requeridos' });
        }

        const validEstados = ['Pendiente', 'Listo para Carga', 'Finalizado'];
        if (!validEstados.includes(estado)) {
            return res.status(400).json({ error: 'Estado no valido' });
        }

        const pool = getPool();

        if (estado === 'Listo para Carga') {
            const check = await pool.request()
                .input('idRoutePlan', sql.Int, idRoutePlan)
                .query(`SELECT Estado FROM OrderRoutePlan WHERE ID_RoutePlan = @idRoutePlan`);
            if (check.recordset.length === 0) {
                return res.status(404).json({ error: 'Ruta no encontrada' });
            }
            if (check.recordset[0].Estado !== 'Finalizado') {
                return res.status(400).json({ error: 'El picking debe estar Finalizado para marcar como Listo para Carga' });
            }
        }

        // Despachar (Finalizado) solo desde 'Listo para Carga' — hay que revisarla antes
        if (estado === 'Finalizado') {
            const check = await pool.request()
                .input('idRoutePlan', sql.Int, idRoutePlan)
                .query(`SELECT EstadoDespacho FROM OrderRoutePlan WHERE ID_RoutePlan = @idRoutePlan`);
            if (check.recordset.length === 0) {
                return res.status(404).json({ error: 'Ruta no encontrada' });
            }
            if (check.recordset[0].EstadoDespacho !== 'Listo para Carga') {
                return res.status(400).json({ error: 'La ruta debe estar Lista para Carga antes de despacharla' });
            }
        }

        let setClause = `EstadoDespacho = @estado`;
        if (estado === 'Finalizado') {
            setClause += `, FechaDespachoFin = GETDATE()`;
        }

        await pool.request()
            .input('idRoutePlan', sql.Int, idRoutePlan)
            .input('estado', sql.NVarChar, estado)
            .query(`
                UPDATE OrderRoutePlan
                SET ${setClause}
                WHERE ID_RoutePlan = @idRoutePlan
            `);

        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/order/despacho/estado error:', err);
        res.status(500).json({ error: 'Error al cambiar estado de despacho' });
    }
});

// GET /api/order/despacho/rutas/:id/documentos — Documents for despacho detail
router.get('/despacho/rutas/:id/documentos', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('idRoutePlan', sql.Int, parseInt(req.params.id))
            .query(`
                SELECT
                    opm.ID_OrderPicking,
                    opm.OV_Number,
                    opm.DocType,
                    opm.IDCustomerOrder,
                    opm.TotalLineas,
                    opm.TotalUnidades,
                    opm.PesoTotal,
                    opm.Estado,
                    opm.ID_Operario,
                    o.Nombre AS OperarioNombre,
                    ISNULL(opm.Bultos, 1) AS Bultos,
                    (SELECT COUNT(*) FROM OrderPickingTask
                     WHERE ID_OrderPicking = opm.ID_OrderPicking AND CantidadPendiente = 0) AS LineasFinalizadas
                FROM OrderPickingManagement opm
                LEFT JOIN Operario o ON o.ID_Operario = opm.ID_Operario
                WHERE opm.ID_RoutePlan = @idRoutePlan
                ORDER BY
                    CASE opm.Estado WHEN 'Finalizado' THEN 1 ELSE 0 END,
                    opm.OV_Number
            `);

        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/order/despacho/rutas/:id/documentos error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// POST /api/order/pedidos/:id/bultos — Persistir la cantidad de bultos de un pedido
// (lo usa BarTender vía SP_EtiquetasCuadro para imprimir una etiqueta por bulto).
router.post('/pedidos/:id/bultos', async (req, res) => {
    try {
        const idOrderPicking = parseInt(req.params.id);
        let bultos = parseInt(req.body && req.body.bultos);
        if (!idOrderPicking || !Number.isFinite(bultos)) {
            return res.status(400).json({ error: 'idOrderPicking y bultos requeridos' });
        }
        if (bultos < 1) bultos = 1;
        if (bultos > 999) bultos = 999;
        const pool = getPool();
        await pool.request()
            .input('id', sql.Int, idOrderPicking)
            .input('bultos', sql.Int, bultos)
            .query(`UPDATE OrderPickingManagement SET Bultos = @bultos WHERE ID_OrderPicking = @id`);
        res.json({ ok: true, bultos });
    } catch (err) {
        console.error('POST /api/order/pedidos/:id/bultos error:', err);
        res.status(500).json({ error: 'Error al guardar bultos' });
    }
});

// GET /api/order/despacho/rutas/:id/documentos/:idOrderPicking/productos — Lines for a pedido in despacho
router.get('/despacho/rutas/:id/documentos/:idOrderPicking/productos', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('idOrderPicking', sql.Int, parseInt(req.params.idOrderPicking))
            .query(`
                SELECT
                    InternIdProduct AS Product,
                    MAX(Descripcion) AS ProductName,
                    MAX(Cantidad) AS Cantidad,
                    MAX(CantidadPendiente) AS CantidadPendiente,
                    MAX(UnitWeight) AS UnitWeight,
                    CASE WHEN MAX(CantidadPendiente) = 0 THEN 'Finalizado' ELSE MAX(Estado) END AS Estado,
                    CAST(MIN(CAST(Verificado AS INT)) AS BIT) AS Verificado,
                    MAX(FechaVerificacion) AS FechaVerificacion,
                    MAX(VerificadoPor) AS VerificadoPor
                FROM OrderPickingTask
                WHERE ID_OrderPicking = @idOrderPicking
                GROUP BY InternIdProduct
                ORDER BY
                    CASE WHEN MAX(CantidadPendiente) = 0 THEN 1 ELSE 0 END,
                    InternIdProduct
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET despacho order productos error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// POST /api/order/despacho/verificar — marcar/desmarcar verificación QC de una línea (producto de un pedido)
router.post('/despacho/verificar', async (req, res) => {
    try {
        const { idOrderPicking, product, verificado } = req.body || {};
        if (!idOrderPicking || product === undefined) {
            return res.status(400).json({ error: 'idOrderPicking y product requeridos' });
        }
        const usuario = req.session?.user?.nombre || 'Sistema';
        const marcar = verificado ? 1 : 0;
        const pool = getPool();
        await pool.request()
            .input('idOrderPicking', sql.Int, parseInt(idOrderPicking))
            .input('product', sql.NVarChar, String(product))
            .input('verificado', sql.Bit, marcar)
            .input('usuario', sql.NVarChar, usuario)
            .query(`
                UPDATE OrderPickingTask
                SET Verificado = @verificado,
                    FechaVerificacion = CASE WHEN @verificado = 1 THEN GETDATE() ELSE NULL END,
                    VerificadoPor = CASE WHEN @verificado = 1 THEN @usuario ELSE NULL END
                WHERE ID_OrderPicking = @idOrderPicking AND InternIdProduct = @product
            `);
        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/order/despacho/verificar error:', err);
        res.status(500).json({ error: 'Error al verificar' });
    }
});

// GET /api/order/despacho/packing/:idRoutePlan — datos de packing list (ruta + pedidos + líneas con verificación)
router.get('/despacho/packing/:idRoutePlan', async (req, res) => {
    try {
        const pool = getPool();
        const idRoutePlan = parseInt(req.params.idRoutePlan);

        const rutaRes = await pool.request()
            .input('idRoutePlan', sql.Int, idRoutePlan)
            .query(`
                SELECT orp.ID_RoutePlan, orp.RouteNumber, orp.RouteName, orp.Pais,
                       c.Nombre AS CarrilNombre, cd.Nombre AS CentroNombre
                FROM OrderRoutePlan orp
                LEFT JOIN Carril c ON c.ID_Carril = orp.ID_Carril
                LEFT JOIN CentroDistribucion cd ON cd.ID_Centro = orp.ID_Centro
                WHERE orp.ID_RoutePlan = @idRoutePlan
            `);
        if (rutaRes.recordset.length === 0) return res.status(404).json({ error: 'Ruta no encontrada' });
        const ruta = rutaRes.recordset[0];

        const lineasRes = await pool.request()
            .input('idRoutePlan', sql.Int, idRoutePlan)
            .query(`
                SELECT opm.ID_OrderPicking, opm.OV_Number, opm.DocType, opm.IDCustomerOrder,
                       opm.PesoTotal, o.Nombre AS OperarioNombre,
                       t.InternIdProduct AS Product, MAX(t.Descripcion) AS ProductName,
                       MAX(t.Cantidad) AS Cantidad, MAX(t.UnitWeight) AS UnitWeight,
                       MAX(t.UltimaActualizacion) AS UltimoPick,
                       CAST(MIN(CAST(t.Verificado AS INT)) AS BIT) AS Verificado,
                       MAX(t.FechaVerificacion) AS FechaVerificacion, MAX(t.VerificadoPor) AS VerificadoPor
                FROM OrderPickingManagement opm
                INNER JOIN OrderPickingTask t ON t.ID_OrderPicking = opm.ID_OrderPicking
                LEFT JOIN Operario o ON o.ID_Operario = opm.ID_Operario
                WHERE opm.ID_RoutePlan = @idRoutePlan
                GROUP BY opm.ID_OrderPicking, opm.OV_Number, opm.DocType, opm.IDCustomerOrder,
                         opm.PesoTotal, o.Nombre, t.InternIdProduct
                ORDER BY opm.OV_Number, t.InternIdProduct
            `);

        // Nombre de cliente desde SAP (solo OVs) + destino de traslados (TR)
        const ovsOV = lineasRes.recordset.filter(r => r.DocType === 'OV').map(r => r.OV_Number);
        const clientes = await getClientesSAP(pool, ruta.Pais, ovsOV);
        const trsTR = lineasRes.recordset.filter(r => r.DocType === 'TR').map(r => r.OV_Number);
        const destinosTR = await getTrasladosDestinoSAP(pool, ruta.Pais, trsTR);

        // Agrupar líneas por pedido
        const pedidosMap = new Map();
        for (const r of lineasRes.recordset) {
            if (!pedidosMap.has(r.ID_OrderPicking)) {
                const cli = clientes[String(r.OV_Number)] || null;
                const tr = r.DocType === 'TR' ? (destinosTR[String(r.OV_Number)] || null) : null;
                pedidosMap.set(r.ID_OrderPicking, {
                    ID_OrderPicking: r.ID_OrderPicking, OV_Number: r.OV_Number, DocType: r.DocType,
                    ClienteNombre: cli ? cli.name : null,
                    ClienteDireccion: tr ? tr.destino : (cli ? cli.address : null),
                    SucursalDestino: tr ? tr.destino : null,
                    Comentarios: tr ? tr.comentarios : (cli ? cli.comentarios : null),
                    PesoTotal: r.PesoTotal, OperarioNombre: r.OperarioNombre,
                    FechaPicking: r.UltimoPick || null,
                    RouteNumber: ruta.RouteNumber, RouteName: ruta.RouteName, lineas: []
                });
            }
            // Fecha de picking = máxima UltimaActualizacion entre las líneas del pedido
            const ped = pedidosMap.get(r.ID_OrderPicking);
            if (r.UltimoPick && (!ped.FechaPicking || new Date(r.UltimoPick) > new Date(ped.FechaPicking))) {
                ped.FechaPicking = r.UltimoPick;
            }
            pedidosMap.get(r.ID_OrderPicking).lineas.push({
                Product: r.Product, ProductName: r.ProductName, Cantidad: r.Cantidad,
                UnitWeight: r.UnitWeight, Verificado: r.Verificado,
                FechaVerificacion: r.FechaVerificacion, VerificadoPor: r.VerificadoPor
            });
        }
        res.json({ ruta, pedidos: Array.from(pedidosMap.values()) });
    } catch (err) {
        console.error('GET /api/order/despacho/packing error:', err);
        res.status(500).json({ error: 'Error al obtener packing list' });
    }
});

// ══════════════════════════════════════════
// ── Limpiar rutas finalizadas (Order)
// ══════════════════════════════════════════

router.post('/admin/limpiar-rutas-finalizadas', async (req, res) => {
    try {
        const pool = getPool();

        const taskResult = await pool.request().query(`
            UPDATE opt
            SET opt.CantidadPendiente = 0, opt.UltimaActualizacion = GETDATE()
            FROM OrderPickingTask opt
            INNER JOIN OrderPickingManagement opm ON opm.ID_OrderPicking = opt.ID_OrderPicking
            INNER JOIN OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
            WHERE orp.Estado = 'Finalizado' AND opt.Estado <> 'Finalizado'
        `);

        const mgmtResult = await pool.request().query(`
            UPDATE opm
            SET opm.Estado = 'Finalizado', opm.FechaFin = GETDATE()
            FROM OrderPickingManagement opm
            INNER JOIN OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
            WHERE orp.Estado = 'Finalizado' AND opm.Estado <> 'Finalizado'
        `);

        res.json({
            ok: true,
            tareasActualizadas: taskResult.rowsAffected[0],
            pedidosActualizados: mgmtResult.rowsAffected[0]
        });
    } catch (err) {
        console.error('POST /api/order/admin/limpiar-rutas-finalizadas error:', err);
        res.status(500).json({ error: 'Error al limpiar' });
    }
});

// ══════════════════════════════════════════
// ── Picker view: pedidos de un operario
// ══════════════════════════════════════════

router.get('/pickers/:id/pedidos', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('operarioId', sql.Int, parseInt(req.params.id))
            .query(`
                SELECT
                    opm.ID_OrderPicking,
                    opm.RouteNumber,
                    orp.RouteName,
                    opm.OV_Number,
                    opm.DocType,
                    -- Subtotales del PICKER (solo sus líneas). Cantidad se repite por
                    -- fila de tarea → MAX por producto.
                    (SELECT COUNT(DISTINCT t.InternIdProduct) FROM OrderPickingTask t
                     WHERE t.ID_OrderPicking = opm.ID_OrderPicking AND t.ID_Operario = @operarioId) AS TotalLineas,
                    (SELECT ISNULL(SUM(x.Cant), 0) FROM (
                        SELECT MAX(ISNULL(t.Cantidad, 0)) AS Cant FROM OrderPickingTask t
                        WHERE t.ID_OrderPicking = opm.ID_OrderPicking AND t.ID_Operario = @operarioId
                        GROUP BY t.InternIdProduct) x) AS TotalUnidades,
                    (SELECT ISNULL(SUM(x.Peso), 0) FROM (
                        SELECT MAX(ISNULL(t.Cantidad, 0)) * MAX(ISNULL(t.UnitWeight, 0)) AS Peso FROM OrderPickingTask t
                        WHERE t.ID_OrderPicking = opm.ID_OrderPicking AND t.ID_Operario = @operarioId
                        GROUP BY t.InternIdProduct) x) AS PesoTotal,
                    opm.Estado,
                    opm.FechaAsignacion,
                    c.Nombre AS CarrilNombre,
                    -- OV repartida entre varios pickers (para avisar en el picker)
                    (SELECT COUNT(DISTINCT t.ID_Operario) FROM OrderPickingTask t
                     WHERE t.ID_OrderPicking = opm.ID_OrderPicking AND t.ID_Operario IS NOT NULL) AS PickersDistintos
                FROM OrderPickingManagement opm
                INNER JOIN OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
                LEFT JOIN Carril c ON c.ID_Carril = orp.ID_Carril
                -- Muestra el pedido mientras el picker tenga líneas SUYAS pendientes.
                -- Cuando termina lo suyo, la OV desaparece de su lista (aunque otros
                -- pickers sigan con sus líneas).
                WHERE orp.Estado = 'Iniciado'
                  AND EXISTS (SELECT 1 FROM OrderPickingTask t
                              WHERE t.ID_OrderPicking = opm.ID_OrderPicking
                                AND t.ID_Operario = @operarioId
                                AND ISNULL(t.CantidadPendiente, 0) > 0)
                ORDER BY opm.FechaAsignacion DESC, opm.OV_Number
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/order/pickers/:id/pedidos error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

router.get('/pickers/:id/resumen', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('operarioId', sql.Int, parseInt(req.params.id))
            .query(`
                ;WITH mias AS (
                    SELECT t.ID_OrderPicking, t.InternIdProduct,
                           MAX(ISNULL(t.Cantidad, 0)) AS Cant,
                           MAX(ISNULL(t.CantidadPendiente, 0)) AS Pend
                    FROM OrderPickingTask t
                    INNER JOIN OrderRoutePlan orp2 ON orp2.RouteNumber = t.RouteNumber AND orp2.Pais = t.Pais
                    WHERE t.ID_Operario = @operarioId AND orp2.Estado = 'Iniciado'
                    GROUP BY t.ID_OrderPicking, t.InternIdProduct
                )
                SELECT
                    (SELECT COUNT(DISTINCT ID_OrderPicking) FROM mias WHERE Pend > 0) AS PedidosPendientes,
                    (SELECT COUNT(*) FROM OrderPickingTask t2
                     WHERE t2.ID_Operario = @operarioId AND t2.Estado = 'Finalizado'
                       AND CAST(t2.UltimaActualizacion AS DATE) = CAST(GETDATE() AS DATE)) AS LineasCompletadasHoy,
                    (SELECT ISNULL(SUM(Pend), 0) FROM mias) AS UnidadesPendientes,
                    (SELECT ISNULL(SUM(x.Peso), 0) FROM (
                        SELECT t3.ID_OrderPicking, t3.InternIdProduct,
                               MAX(ISNULL(t3.CantidadPendiente,0)) * MAX(ISNULL(t3.UnitWeight,0)) AS Peso
                        FROM OrderPickingTask t3
                        INNER JOIN OrderRoutePlan orp3 ON orp3.RouteNumber = t3.RouteNumber AND orp3.Pais = t3.Pais
                        WHERE t3.ID_Operario = @operarioId AND orp3.Estado = 'Iniciado'
                        GROUP BY t3.ID_OrderPicking, t3.InternIdProduct) x) AS PesoPendiente
            `);
        res.json(result.recordset[0]);
    } catch (err) {
        console.error('GET /api/order/pickers/:id/resumen error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

module.exports = router;
