const express = require('express');
const { getPool, sql } = require('../db');
const { getSapDb } = require('../config/paises');
const router = express.Router();

// Trae { OV_Number: CardName } desde SAP para un conjunto de OVs (por país)
async function getClientesSAP(pool, pais, ovNumbers) {
    const map = {};
    const ovInts = [...new Set(ovNumbers.map(v => parseInt(v)).filter(v => !isNaN(v)))];
    if (ovInts.length === 0) return map;
    const sapDb = getSapDb(pais);
    const req = pool.request();
    const inParams = ovInts.map((v, i) => { req.input('ov' + i, sql.Int, v); return '@ov' + i; }).join(',');
    try {
        const r = await req.query(`
            SELECT o.DocNum AS OV, MAX(c.CardName) AS CardName
            FROM [server-sql].[${sapDb}].dbo.ORDR o WITH (NOLOCK)
            LEFT JOIN [server-sql].[${sapDb}].dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
            WHERE o.DocNum IN (${inParams})
            GROUP BY o.DocNum`);
        r.recordset.forEach(row => { map[String(row.OV)] = row.CardName; });
    } catch (e) { console.error('getClientesSAP error:', e.message); }
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
                c.Nombre AS CarrilNombre,
                cd.Nombre AS CentroNombre,
                ISNULL(opm.TotalPedidos, 0) AS TotalPedidos,
                ISNULL(opm.TotalLineas, 0) AS TotalLineas,
                ISNULL(opm.PesoTotal, 0) AS PesoTotal,
                ISNULL(opm.PedidosFinalizados, 0) AS PedidosFinalizados
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
                    o.Nombre AS OperarioNombre
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
        res.json(result.recordset[0]);
    } catch (err) {
        console.error('GET /api/order/rutas/:id/resumen error:', err);
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
        const result = await pool.request()
            .input('idOrderPicking', sql.Int, parseInt(req.params.id))
            .query(`
                SELECT
                    ID_Task,
                    InternIdProduct,
                    Descripcion,
                    Cantidad,
                    CantidadPendiente,
                    UnitWeight,
                    Estado,
                    ID_Operario,
                    UltimaActualizacion
                FROM OrderPickingTask
                WHERE ID_OrderPicking = @idOrderPicking
                ORDER BY
                    CASE Estado WHEN 'Finalizado' THEN 1 ELSE 0 END,
                    InternIdProduct
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

        // Nombre de cliente desde SAP (solo OVs)
        const ovsOV = lineasRes.recordset.filter(r => r.DocType === 'OV').map(r => r.OV_Number);
        const clientes = await getClientesSAP(pool, ruta.Pais, ovsOV);

        // Agrupar líneas por pedido
        const pedidosMap = new Map();
        for (const r of lineasRes.recordset) {
            if (!pedidosMap.has(r.ID_OrderPicking)) {
                pedidosMap.set(r.ID_OrderPicking, {
                    ID_OrderPicking: r.ID_OrderPicking, OV_Number: r.OV_Number, DocType: r.DocType,
                    ClienteNombre: clientes[String(r.OV_Number)] || null, PesoTotal: r.PesoTotal,
                    OperarioNombre: r.OperarioNombre, lineas: []
                });
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
                    opm.TotalLineas,
                    opm.TotalUnidades,
                    opm.PesoTotal,
                    opm.Estado,
                    opm.FechaAsignacion,
                    c.Nombre AS CarrilNombre
                FROM OrderPickingManagement opm
                INNER JOIN OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
                LEFT JOIN Carril c ON c.ID_Carril = orp.ID_Carril
                WHERE opm.ID_Operario = @operarioId
                  AND (opm.Estado IN ('Asignado', 'En Proceso')
                       OR (opm.Estado = 'Finalizado' AND CAST(opm.FechaFin AS DATE) = CAST(GETDATE() AS DATE)))
                ORDER BY
                    CASE opm.Estado
                        WHEN 'En Proceso' THEN 0
                        WHEN 'Asignado' THEN 1
                        WHEN 'Finalizado' THEN 2
                    END,
                    opm.FechaAsignacion DESC
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
                SELECT
                    (SELECT COUNT(*) FROM OrderPickingManagement
                     WHERE ID_Operario = @operarioId AND Estado IN ('Asignado','En Proceso')) AS PedidosPendientes,
                    (SELECT COUNT(*) FROM OrderPickingManagement
                     WHERE ID_Operario = @operarioId AND Estado = 'Finalizado'
                       AND CAST(FechaFin AS DATE) = CAST(GETDATE() AS DATE)) AS PedidosCompletadosHoy,
                    (SELECT ISNULL(SUM(TotalUnidades), 0) FROM OrderPickingManagement
                     WHERE ID_Operario = @operarioId AND Estado IN ('Asignado','En Proceso')) AS UnidadesPendientes,
                    (SELECT ISNULL(SUM(PesoTotal), 0) FROM OrderPickingManagement
                     WHERE ID_Operario = @operarioId AND Estado IN ('Asignado','En Proceso')) AS PesoPendiente
            `);
        res.json(result.recordset[0]);
    } catch (err) {
        console.error('GET /api/order/pickers/:id/resumen error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

module.exports = router;
