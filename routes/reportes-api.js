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
                        OR (orp.Estado = 'Finalizado' AND orp.EstadoDespacho <> 'Finalizado')
                        OR (orp.EstadoDespacho = 'Finalizado' AND CAST(orp.FechaDespachoFin AS DATE) >= CAST(DATEADD(DAY, -1, GETDATE()) AS DATE)) )
                ORDER BY CASE WHEN orp.FechaFin IS NULL THEN 1 ELSE 0 END, orp.FechaFin, orp.RouteNumber
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
                    FechaFin: r.FechaFin,
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
                        OR (rp.Estado = 'Finalizado' AND rp.EstadoDespacho <> 'Finalizado')
                        OR (rp.EstadoDespacho = 'Finalizado' AND CAST(rp.FechaDespachoFin AS DATE) >= CAST(DATEADD(DAY, -1, GETDATE()) AS DATE)) )
                ORDER BY CASE WHEN rp.FechaFin IS NULL THEN 1 ELSE 0 END, rp.FechaFin, rp.RouteNumber
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
                    FechaFin: r.FechaFin,
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

// Cliente/asesor/monto de OVs desde SAP
async function getDocInfoSAP(pool, pais, ovNumbers) {
    const map = {};
    const ints = [...new Set(ovNumbers.map(v => parseInt(v)).filter(v => !isNaN(v)))];
    if (ints.length === 0) return map;
    const db = getSapDb(pais);
    const req = pool.request();
    const inParams = ints.map((v, i) => { req.input('o' + i, sql.Int, v); return '@o' + i; }).join(',');
    try {
        const r = await req.query(`
            SELECT o.DocNum AS OV, MAX(c.CardName) AS Cliente,
                   MAX(s.SlpName) AS Asesor, MAX(o.DocTotal) AS Monto
            FROM [server-sql].[${db}].dbo.ORDR o WITH (NOLOCK)
            LEFT JOIN [server-sql].[${db}].dbo.OCRD c WITH (NOLOCK) ON c.CardCode = o.CardCode
            LEFT JOIN [server-sql].[${db}].dbo.OSLP s WITH (NOLOCK) ON s.SlpCode = o.SlpCode
            WHERE o.DocNum IN (${inParams}) GROUP BY o.DocNum`);
        r.recordset.forEach(row => { map[String(row.OV)] = { cliente: row.Cliente, asesor: row.Asesor, monto: row.Monto }; });
    } catch (e) { console.error('getDocInfoSAP error:', e.message); }
    return map;
}

// Destino de traslados (OWTQ) desde SAP
async function getTrDestinoSAP(pool, pais, trNumbers) {
    const map = {};
    const ints = [...new Set(trNumbers.map(v => parseInt(v)).filter(v => !isNaN(v)))];
    if (ints.length === 0) return map;
    const db = getSapDb(pais);
    const req = pool.request();
    const inParams = ints.map((v, i) => { req.input('t' + i, sql.Int, v); return '@t' + i; }).join(',');
    try {
        const r = await req.query(`
            SELECT o.DocNum AS TR, MAX(o.ToWhsCode) AS ToWhs, MAX(wh.WhsName) AS Destino
            FROM [server-sql].[${db}].dbo.OWTQ o WITH (NOLOCK)
            LEFT JOIN [server-sql].[${db}].dbo.OWHS wh WITH (NOLOCK) ON wh.WhsCode = o.ToWhsCode
            WHERE o.DocNum IN (${inParams}) GROUP BY o.DocNum`);
        r.recordset.forEach(row => { map[String(row.TR)] = row.Destino || (row.ToWhs ? ('Almacén ' + row.ToWhs) : null); });
    } catch (e) { console.error('getTrDestinoSAP error:', e.message); }
    return map;
}

// GET /api/reportes/plan-despachos/detalle — sección 3: documentos por cuadro (para el PDF)
router.get('/plan-despachos/detalle', requireReportes, async (req, res) => {
    try {
        const u = req.session.user;
        const centro = u.selectedCentro;
        const modo = u.selectedModo || (['SV', 'HN'].includes(u.selectedPais) ? 'order' : 'product');
        const pais = u.selectedPais || 'GT';
        if (!centro) return res.status(400).json({ error: 'Seleccioná un centro primero' });
        const pool = getPool();

        let docs = [];
        if (modo === 'order') {
            const r = await pool.request().input('centro', sql.Int, centro).query(`
                SELECT orp.RouteNumber AS Cuadro, orp.RouteName AS Ruta, orp.Prioridad,
                       opm.OV_Number, opm.DocType, ISNULL(opm.PesoTotal, 0) AS PesoKg
                FROM OrderPickingManagement opm
                INNER JOIN OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
                WHERE orp.ID_Centro = @centro
                  AND ( orp.Estado IN ('Pendiente', 'Iniciado')
                        OR orp.EstadoDespacho = 'Listo para Carga'
                        OR (orp.Estado = 'Finalizado' AND CAST(orp.FechaFin AS DATE) = CAST(GETDATE() AS DATE))
                        OR (orp.EstadoDespacho = 'Finalizado' AND CAST(orp.FechaDespachoFin AS DATE) = CAST(GETDATE() AS DATE)) )
                ORDER BY CASE WHEN orp.Estado = 'Finalizado' THEN 0 ELSE 1 END,
                         CASE WHEN orp.Estado = 'Finalizado' THEN orp.FechaFin END,
                         CASE WHEN orp.Estado <> 'Finalizado' AND orp.Prioridad IS NULL THEN 1 ELSE 0 END,
                         CASE WHEN orp.Estado <> 'Finalizado' THEN orp.Prioridad END,
                         orp.RouteNumber, opm.OV_Number
            `);
            docs = r.recordset;
        } else {
            const r = await pool.request().query(`
                ;WITH prod AS (
                    SELECT t.Route_Number AS Cuadro, t.OV_Number, t.InternIdProduct,
                           MAX(t.DocType) AS DocType,
                           MAX(ISNULL(t.Cantidad, 0)) * MAX(ISNULL(t.UnitWeight, 0)) AS Peso
                    FROM RoutePickingTask t GROUP BY t.Route_Number, t.OV_Number, t.InternIdProduct
                )
                SELECT p.Cuadro, rp.RouteName AS Ruta, rp.Prioridad, p.OV_Number,
                       MAX(p.DocType) AS DocType, SUM(p.Peso) AS PesoKg
                FROM prod p INNER JOIN RoutePlan rp ON rp.RouteNumber = p.Cuadro
                WHERE ( rp.Estado IN ('Pendiente', 'Iniciado')
                        OR rp.EstadoDespacho = 'Listo para Carga'
                        OR (rp.Estado = 'Finalizado' AND CAST(rp.FechaFin AS DATE) = CAST(GETDATE() AS DATE))
                        OR (rp.EstadoDespacho = 'Finalizado' AND CAST(rp.FechaDespachoFin AS DATE) = CAST(GETDATE() AS DATE)) )
                GROUP BY p.Cuadro, rp.RouteName, rp.Prioridad, p.OV_Number
                ORDER BY CASE WHEN MIN(rp.Estado) = 'Finalizado' THEN 0 ELSE 1 END,
                         CASE WHEN MIN(rp.Estado) = 'Finalizado' THEN MIN(rp.FechaFin) END,
                         CASE WHEN MIN(rp.Estado) <> 'Finalizado' AND rp.Prioridad IS NULL THEN 1 ELSE 0 END,
                         CASE WHEN MIN(rp.Estado) <> 'Finalizado' THEN rp.Prioridad END,
                         p.Cuadro, p.OV_Number
            `);
            docs = r.recordset;
        }

        const info = await getDocInfoSAP(pool, pais, docs.filter(d => d.DocType === 'OV').map(d => d.OV_Number));
        const dest = await getTrDestinoSAP(pool, pais, docs.filter(d => d.DocType === 'TR').map(d => d.OV_Number));

        const map = new Map();
        for (const d of docs) {
            if (!map.has(d.Cuadro)) map.set(d.Cuadro, { Cuadro: d.Cuadro, Ruta: d.Ruta, Prioridad: d.Prioridad, docs: [], subtotalPeso: 0, subtotalMonto: 0 });
            const g = map.get(d.Cuadro);
            const i = d.DocType === 'OV' ? (info[String(d.OV_Number)] || {}) : {};
            const cliente = d.DocType === 'TR'
                ? ('Traslado → ' + (dest[String(d.OV_Number)] || 'destino s/d'))
                : (i.cliente || '');
            const monto = d.DocType === 'OV' ? (i.monto != null ? Number(i.monto) : null) : null;
            const peso = Number(d.PesoKg) || 0;
            g.docs.push({ OV_Number: d.OV_Number, DocType: d.DocType, Cliente: cliente, Asesor: i.asesor || '', PesoKg: peso, Monto: monto });
            g.subtotalPeso += peso; g.subtotalMonto += (monto || 0);
        }
        res.json({ modo, cuadros: Array.from(map.values()) });
    } catch (err) {
        console.error('GET /api/reportes/plan-despachos/detalle error:', err);
        res.status(500).json({ error: 'Error al obtener el detalle' });
    }
});

// GET /api/reportes/plan-despachos/buscar?q= — ubica una OV o un cuadro en el centro
router.get('/plan-despachos/buscar', requireReportes, async (req, res) => {
    try {
        const u = req.session.user;
        const centro = u.selectedCentro;
        const modo = u.selectedModo || (['SV', 'HN'].includes(u.selectedPais) ? 'order' : 'product');
        if (!centro) return res.status(400).json({ error: 'Seleccioná un centro primero' });
        const q = String(req.query.q || '').trim();
        if (!q) return res.json({ resultados: [] });
        const qi = /^\d+$/.test(q) ? parseInt(q) : null;
        const pool = getPool();
        // SAP db para buscar la OV en el cuadro aunque la ruta aún no se haya
        // iniciado (los cuadros Pendientes no tienen filas en OrderPickingManagement).
        const sapDb = getSapDb(u.selectedPais || 'GT');
        const sapDbProd = getSapDb('GT');
        let rows;
        if (modo === 'order') {
            rows = (await pool.request().input('centro', sql.Int, centro).input('q', sql.NVarChar, q)
                .input('qi', sql.Int, qi).query(`
                SELECT orp.RouteNumber AS Cuadro, orp.RouteName AS Ruta, orp.Estado AS EstadoPicking,
                       orp.EstadoDespacho, orp.FechaDespachoFin AS FechaDespacho,
                       CAST(NULL AS NVARCHAR(50)) AS OV, 'cuadro' AS Tipo
                FROM OrderRoutePlan orp WHERE orp.ID_Centro = @centro AND orp.RouteNumber = @qi
                UNION
                SELECT orp.RouteNumber, orp.RouteName, orp.Estado, orp.EstadoDespacho, orp.FechaDespachoFin,
                       opm.OV_Number, 'ov'
                FROM OrderPickingManagement opm
                INNER JOIN OrderRoutePlan orp ON orp.ID_RoutePlan = opm.ID_RoutePlan
                WHERE orp.ID_Centro = @centro AND LTRIM(RTRIM(opm.OV_Number)) = @q
                UNION
                SELECT orp.RouteNumber, orp.RouteName, orp.Estado, orp.EstadoDespacho, orp.FechaDespachoFin,
                       LTRIM(RTRIM(d.U_No_OV)), 'ov'
                FROM [server-sql].[${sapDb}].dbo.[@CUADRO_RUTA_E] e WITH (NOLOCK)
                INNER JOIN [server-sql].[${sapDb}].dbo.[@CUADRO_RUTA_D] d WITH (NOLOCK) ON d.DocEntry = e.DocEntry
                INNER JOIN OrderRoutePlan orp ON orp.RouteNumber = e.DocNum AND orp.ID_Centro = @centro
                WHERE LTRIM(RTRIM(d.U_No_OV)) = @q
            `)).recordset;
        } else {
            rows = (await pool.request().input('q', sql.NVarChar, q).input('qi', sql.Int, qi).query(`
                SELECT rp.RouteNumber AS Cuadro, rp.RouteName AS Ruta, rp.Estado AS EstadoPicking,
                       rp.EstadoDespacho, rp.FechaDespachoFin AS FechaDespacho,
                       CAST(NULL AS NVARCHAR(50)) AS OV, 'cuadro' AS Tipo
                FROM RoutePlan rp WHERE rp.RouteNumber = @qi
                UNION
                SELECT rp.RouteNumber, rp.RouteName, rp.Estado, rp.EstadoDespacho, rp.FechaDespachoFin,
                       t.OV_Number, 'ov'
                FROM (SELECT DISTINCT Route_Number, OV_Number FROM RoutePickingTask WHERE LTRIM(RTRIM(OV_Number)) = @q) t
                INNER JOIN RoutePlan rp ON rp.RouteNumber = t.Route_Number
                UNION
                SELECT rp.RouteNumber, rp.RouteName, rp.Estado, rp.EstadoDespacho, rp.FechaDespachoFin,
                       LTRIM(RTRIM(d.U_No_OV)), 'ov'
                FROM [server-sql].[${sapDbProd}].dbo.[@CUADRO_RUTA_E] e WITH (NOLOCK)
                INNER JOIN [server-sql].[${sapDbProd}].dbo.[@CUADRO_RUTA_D] d WITH (NOLOCK) ON d.DocEntry = e.DocEntry
                INNER JOIN RoutePlan rp ON rp.RouteNumber = e.DocNum
                WHERE LTRIM(RTRIM(d.U_No_OV)) = @q
            `)).recordset;
        }
        // Dedup por Cuadro+OV
        const seen = new Set(); const resultados = [];
        for (const r of rows) {
            const k = r.Cuadro + '|' + (r.OV || '');
            if (seen.has(k)) continue; seen.add(k);
            resultados.push(r);
        }
        res.json({ q, resultados });
    } catch (err) {
        console.error('GET /api/reportes/plan-despachos/buscar error:', err);
        res.status(500).json({ error: 'Error en la búsqueda' });
    }
});

module.exports = router;
