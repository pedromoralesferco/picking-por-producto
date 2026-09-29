// ============================================================
// Reportes — módulo "Plan de Despachos" (tablero de control).
// En vivo, amarrado al centro seleccionado. Soporta modo pedido y producto.
// Permisos: 'reportes' (vista comercial) y 'reportes_operativo' (desbloquea
// la vista operativa con datos de transporte). Admin ve todo.
// ============================================================
const express = require('express');
const { getPool, sql } = require('../db');
const { getSapDb } = require('../config/paises');
const router = express.Router();

// Acceso al módulo: reportes | reportes_operativo | Admin
function requireReportes(req, res, next) {
    const u = req.session && req.session.user;
    if (!u) return res.status(401).json({ error: 'No autenticado' });
    if (u.rol === 'Admin' || (u.permisos && (u.permisos.includes('reportes') || u.permisos.includes('reportes_operativo')))) {
        return next();
    }
    return res.status(403).json({ error: 'Sin permiso para reportes' });
}

const puedeOperativo = (u) => u.rol === 'Admin' || (u.permisos && u.permisos.includes('reportes_operativo'));

// Trae datos de transporte por cuadro desde SAP (@CUADRO_RUTA_E), por país.
async function getTransporteSAP(pool, pais, routeNumbers) {
    const map = {};
    const ints = [...new Set(routeNumbers.map(v => parseInt(v)).filter(v => !isNaN(v)))];
    if (ints.length === 0) return map;
    const db = getSapDb(pais);
    const req = pool.request();
    const inParams = ints.map((v, i) => { req.input('r' + i, sql.Int, v); return '@r' + i; }).join(',');
    try {
        const r = await req.query(`
            SELECT T0.DocNum AS Cuadro,
                   LTRIM(RTRIM(ISNULL(T0.U_Placa, '')))     AS Placa,
                   LTRIM(RTRIM(ISNULL(T0.U_Chofer, '')))    AS Chofer,
                   ISNULL(T0.U_Capacidad, '')               AS Capacidad,
                   ISNULL(T0.U_ID_Camion, '')               AS Transporte,
                   ISNULL(PRV.CardName, '')                 AS Transportista
            FROM [server-sql].[${db}].[dbo].[@CUADRO_RUTA_E] T0 WITH (NOLOCK)
            LEFT JOIN [server-sql].[${db}].[dbo].OCRD PRV WITH (NOLOCK) ON T0.U_CardCode = PRV.CardCode
            WHERE T0.DocNum IN (${inParams})`);
        r.recordset.forEach(row => {
            map[String(row.Cuadro)] = {
                Placa: row.Placa || null, Chofer: row.Chofer || null,
                Capacidad: row.Capacidad || null, Transporte: row.Transporte || null,
                Transportista: row.Transportista || null
            };
        });
    } catch (e) { console.error('getTransporteSAP error:', e.message); }
    return map;
}

const pct = (num, den) => (den > 0 ? Math.round((num / den) * 100) : 0);

// GET /api/reportes/plan-despachos — tablero del centro seleccionado
router.get('/plan-despachos', requireReportes, async (req, res) => {
    try {
        const u = req.session.user;
        const centro = u.selectedCentro;
        const modo = u.selectedModo || (['SV', 'HN'].includes(u.selectedPais) ? 'order' : 'product');
        const pais = u.selectedPais || 'GT';
        const verOperativo = puedeOperativo(u);
        if (!centro) return res.status(400).json({ error: 'Seleccioná un centro primero' });

        const pool = getPool();
        let cuadros = [];

        if (modo === 'order') {
            // Cabeceras de cuadros: activos + los del día (finalizados/despachados hoy)
            const cab = await pool.request().input('centro', sql.Int, centro).query(`
                SELECT orp.ID_RoutePlan, orp.RouteNumber, orp.RouteName, orp.Prioridad,
                       orp.Estado, orp.EstadoDespacho, orp.FechaFin, orp.FechaDespachoFin,
                       ISNULL(orp.PesoEstimado, 0) AS PesoEstimado, c.Nombre AS CarrilNombre
                FROM OrderRoutePlan orp
                LEFT JOIN Carril c ON c.ID_Carril = orp.ID_Carril
                WHERE orp.ID_Centro = @centro
                  AND ( orp.Estado IN ('Pendiente', 'Iniciado')
                        OR (orp.Estado = 'Finalizado' AND CAST(orp.FechaFin AS DATE) = CAST(GETDATE() AS DATE))
                        OR (orp.EstadoDespacho = 'Finalizado' AND CAST(orp.FechaDespachoFin AS DATE) = CAST(GETDATE() AS DATE)) )
                ORDER BY CASE WHEN orp.Prioridad IS NULL THEN 1 ELSE 0 END, orp.Prioridad, orp.RouteNumber
            `);

            // Avance por cuadro (desde tareas; Cantidad se repite por fila → MAX por producto)
            const av = await pool.request().input('centro', sql.Int, centro).query(`
                ;WITH prod AS (
                    SELECT t.RouteNumber, t.ID_OrderPicking, t.InternIdProduct,
                           MAX(ISNULL(t.Cantidad, 0)) AS Cant,
                           MAX(ISNULL(t.CantidadPendiente, 0)) AS Pend,
                           MAX(ISNULL(t.UnitWeight, 0)) AS UW
                    FROM OrderPickingTask t
                    WHERE t.ID_Centro = @centro
                    GROUP BY t.RouteNumber, t.ID_OrderPicking, t.InternIdProduct
                )
                SELECT RouteNumber,
                       SUM(Cant) AS UnidadesTot, SUM(Cant - Pend) AS UnidadesPick,
                       SUM(Cant * UW) AS PesoTot, SUM((Cant - Pend) * UW) AS PesoPick,
                       COUNT(*) AS LineasTot, SUM(CASE WHEN Pend = 0 THEN 1 ELSE 0 END) AS LineasFin
                FROM prod GROUP BY RouteNumber
            `);
            const avMap = {}; av.recordset.forEach(r => { avMap[r.RouteNumber] = r; });

            const ped = await pool.request().input('centro', sql.Int, centro).query(`
                SELECT RouteNumber, COUNT(*) AS PedidosTot,
                       SUM(CASE WHEN Estado = 'Finalizado' THEN 1 ELSE 0 END) AS PedidosFin
                FROM OrderPickingManagement WHERE ID_Centro = @centro GROUP BY RouteNumber
            `);
            const pedMap = {}; ped.recordset.forEach(r => { pedMap[r.RouteNumber] = r; });

            cuadros = cab.recordset.map(r => {
                const a = avMap[r.RouteNumber] || {};
                const p = pedMap[r.RouteNumber] || {};
                return {
                    ID_RoutePlan: r.ID_RoutePlan, Cuadro: r.RouteNumber, Ruta: r.RouteName,
                    Prioridad: r.Prioridad, Carril: r.CarrilNombre,
                    EstadoPicking: r.Estado, EstadoDespacho: r.EstadoDespacho,
                    FechaDespacho: r.FechaDespachoFin,
                    PesoEstimadoKg: r.PesoEstimado,
                    PedidosTot: p.PedidosTot || 0, PedidosFin: p.PedidosFin || 0,
                    UnidadesTot: a.UnidadesTot || 0, UnidadesPick: a.UnidadesPick || 0,
                    LineasTot: a.LineasTot || 0, LineasFin: a.LineasFin || 0,
                    AvancePct: pct(a.UnidadesPick || 0, a.UnidadesTot || 0)
                };
            });
        } else {
            // Modo producto (Zona 5): RoutePlan / RoutePickingManagement / RoutePickingTask
            const cab = await pool.request().query(`
                SELECT rp.RouteNumber, rp.RouteName, rp.Prioridad,
                       rp.Estado, rp.EstadoDespacho, rp.FechaFin, rp.FechaDespachoFin,
                       ISNULL(rp.PesoEstimado, 0) AS PesoEstimado, c.Nombre AS CarrilNombre
                FROM RoutePlan rp
                LEFT JOIN Carril c ON c.ID_Carril = rp.ID_Carril
                WHERE ( rp.Estado IN ('Pendiente', 'Iniciado')
                        OR (rp.Estado = 'Finalizado' AND CAST(rp.FechaFin AS DATE) = CAST(GETDATE() AS DATE))
                        OR (rp.EstadoDespacho = 'Finalizado' AND CAST(rp.FechaDespachoFin AS DATE) = CAST(GETDATE() AS DATE)) )
                ORDER BY CASE WHEN rp.Prioridad IS NULL THEN 1 ELSE 0 END, rp.Prioridad, rp.RouteNumber
            `);
            const av = await pool.request().query(`
                ;WITH prod AS (
                    SELECT t.Route_Number AS RouteNumber, t.OV_Number, t.InternIdProduct,
                           MAX(ISNULL(t.Cantidad, 0)) AS Cant,
                           MAX(ISNULL(t.CantidadPendiente, 0)) AS Pend,
                           MAX(ISNULL(t.UnitWeight, 0)) AS UW
                    FROM RoutePickingTask t
                    GROUP BY t.Route_Number, t.OV_Number, t.InternIdProduct
                )
                SELECT RouteNumber,
                       SUM(Cant) AS UnidadesTot, SUM(Cant - Pend) AS UnidadesPick,
                       COUNT(*) AS LineasTot, SUM(CASE WHEN Pend = 0 THEN 1 ELSE 0 END) AS LineasFin
                FROM prod GROUP BY RouteNumber
            `);
            const avMap = {}; av.recordset.forEach(r => { avMap[r.RouteNumber] = r; });
            const ped = await pool.request().query(`
                SELECT RouteNumber, COUNT(*) AS PedidosTot,
                       SUM(CASE WHEN Estado = 'Finalizado' THEN 1 ELSE 0 END) AS PedidosFin
                FROM RoutePickingManagement GROUP BY RouteNumber
            `);
            const pedMap = {}; ped.recordset.forEach(r => { pedMap[r.RouteNumber] = r; });

            cuadros = cab.recordset.map(r => {
                const a = avMap[r.RouteNumber] || {};
                const p = pedMap[r.RouteNumber] || {};
                return {
                    ID_RoutePlan: null, Cuadro: r.RouteNumber, Ruta: r.RouteName,
                    Prioridad: r.Prioridad, Carril: r.CarrilNombre,
                    EstadoPicking: r.Estado, EstadoDespacho: r.EstadoDespacho,
                    FechaDespacho: r.FechaDespachoFin,
                    PesoEstimadoKg: r.PesoEstimado,
                    PedidosTot: p.PedidosTot || 0, PedidosFin: p.PedidosFin || 0,
                    UnidadesTot: a.UnidadesTot || 0, UnidadesPick: a.UnidadesPick || 0,
                    LineasTot: a.LineasTot || 0, LineasFin: a.LineasFin || 0,
                    AvancePct: pct(a.UnidadesPick || 0, a.UnidadesTot || 0)
                };
            });
        }

        // Transporte (solo si el usuario puede ver la vista operativa)
        if (verOperativo && cuadros.length > 0) {
            const transp = await getTransporteSAP(pool, pais, cuadros.map(c => c.Cuadro));
            cuadros.forEach(c => {
                const t = transp[String(c.Cuadro)] || {};
                c.Placa = t.Placa || null;
                c.Chofer = t.Chofer || null;
                c.TipoUnidad = t.Capacidad ? (String(t.Capacidad).replace(/\.0+$/, '') + ' TN') : null;
                c.Transportista = t.Transportista || null;
            });
        }

        // KPIs del centro
        const kpis = {
            cuadros: cuadros.length,
            despachados: cuadros.filter(c => c.EstadoDespacho === 'Finalizado').length,
            listos: cuadros.filter(c => c.EstadoDespacho === 'Listo para Carga').length,
            enPicking: cuadros.filter(c => c.EstadoPicking === 'Iniciado' && c.EstadoDespacho !== 'Finalizado').length,
            pendientes: cuadros.filter(c => c.EstadoPicking === 'Pendiente').length,
            tonTotal: cuadros.reduce((s, c) => s + (c.PesoEstimadoKg || 0), 0) / 1000,
            tonDespachada: cuadros.filter(c => c.EstadoDespacho === 'Finalizado').reduce((s, c) => s + (c.PesoEstimadoKg || 0), 0) / 1000,
            unidadesTot: cuadros.reduce((s, c) => s + (c.UnidadesTot || 0), 0),
            unidadesPick: cuadros.reduce((s, c) => s + (c.UnidadesPick || 0), 0)
        };
        kpis.avancePctGlobal = pct(kpis.unidadesPick, kpis.unidadesTot);
        kpis.tonPendiente = kpis.tonTotal - kpis.tonDespachada;

        res.json({
            modo, verOperativo,
            centro: { id: centro, nombre: u.selectedCentroNombre || null, pais },
            generado: new Date(),
            kpis, cuadros
        });
    } catch (err) {
        console.error('GET /api/reportes/plan-despachos error:', err);
        res.status(500).json({ error: 'Error al generar el plan de despachos' });
    }
});

module.exports = router;
