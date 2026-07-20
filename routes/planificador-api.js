const express = require('express');
const { getPool, sql } = require('../db');
const { getSapDb } = require('../config/paises');
const router = express.Router();

// Camión más grande de la flota (kg). Un punto por encima de esto no cabe
// en ninguna unidad → va a "Especiales" (flete dedicado / viajes múltiples).
const MAX_TRUCK_KG = 22000;

// ── Helpers ──────────────────────────────────────────────
function normAddr(s) {
    return (s || '').replace(/[\r\n]+/g, ' ').replace(/\s+/g, ' ').trim();
}

// Extrae zona / municipio / departamento del texto de dirección de Ferco.
// Formato típico: "... Zona {N} #{detalle} {Municipio},{Departamento}"
function parseGeo(addr) {
    const a = normAddr(addr);
    const mz = a.match(/zona\s*0*(\d{1,2})/i);
    const zona = mz ? parseInt(mz[1], 10) : null;
    let muni = null, depto = null;
    const tail = a.split('#').pop();
    if (tail && tail.includes(',')) {
        const parts = tail.split(',');
        depto = (parts.pop() || '').trim();
        muni = (parts.pop() || '').trim();
    }
    // Metropolitano = departamento de Guatemala (incluye Mixco, Villa Nueva,
    // Fraijanes, etc.). Sin departamento reconocible → se asume local (metro).
    const region = (!depto || /guatemala/i.test(depto)) ? 'metro' : 'regional';
    return { zona, muni: muni || null, depto: depto || null, region };
}

// ── GET /api/planificador/pendientes?fecha=YYYY-MM-DD&bodega=01 ──
// Devuelve los puntos de entrega pendientes de planificar (agregados por
// cliente+dirección) más un resumen. Zona 5 / GT por ahora.
router.get('/pendientes', async (req, res) => {
    try {
        const pool = getPool();
        const pais = req.query.pais || req.session?.user?.selectedPais || 'GT';
        const sapDb = getSapDb(pais);
        const bodega = (req.query.bodega || '01').toString();
        // fecha por defecto: mañana
        let fecha = req.query.fecha;
        if (!fecha || !/^\d{4}-\d{2}-\d{2}$/.test(fecha)) {
            const d = new Date();
            d.setDate(d.getDate() + 1);
            fecha = d.toISOString().slice(0, 10);
        }

        const result = await pool.request()
            .input('bodega', sql.NVarChar, bodega)
            .input('fecha', sql.Date, fecha)
            .query(`
                SELECT T0.DocNum, T0.CardCode, T0.CardName, T0.Address2,
                       T1.Quantity,
                       CASE WHEN T5.ItmsGrpNam LIKE '%(6)%' THEN 200 ELSE T2.SWeight1 END AS PesoUnit
                FROM [server-sql].${sapDb}.dbo.ORDR T0
                INNER JOIN [server-sql].${sapDb}.dbo.RDR1 T1 ON T0.DocEntry = T1.DocEntry
                INNER JOIN [server-sql].${sapDb}.dbo.OITM T2 ON T1.ItemCode = T2.ItemCode
                INNER JOIN [server-sql].${sapDb}.dbo.OITB T5 ON T2.ItmsGrpCod = T5.ItmsGrpCod
                WHERE T0.U_Estado2 = '03'
                  AND T1.WhsCode = @bodega
                  AND T0.TrnspCode = 22
                  AND T1.ItemCode NOT IN ('013956','031780')
                  AND CAST(T0.DocDueDate AS DATE) = @fecha
            `);

        // Agregar por punto de entrega = CardCode + Address2
        const pts = new Map();
        let lineas = 0;
        for (const r of result.recordset) {
            lineas++;
            const dir = normAddr(r.Address2);
            const key = r.CardCode + '||' + dir;
            if (!pts.has(key)) {
                pts.set(key, {
                    cliente: r.CardName, dir, ovs: new Set(),
                    peso: 0, unidades: 0, ...parseGeo(r.Address2)
                });
            }
            const p = pts.get(key);
            p.ovs.add(r.DocNum);
            p.peso += (r.PesoUnit || 0) * (r.Quantity || 0);
            p.unidades += (r.Quantity || 0);
        }

        const puntos = [...pts.values()].map(p => ({
            cliente: p.cliente,
            direccion: p.dir,
            zona: p.zona, municipio: p.muni, departamento: p.depto,
            region: p.region,
            ovs: [...p.ovs],
            nOV: p.ovs.size,
            peso: Math.round(p.peso),
            unidades: p.unidades,
            excede: p.peso > MAX_TRUCK_KG
        })).sort((a, b) => b.peso - a.peso);

        const pesoTotal = puntos.reduce((s, p) => s + p.peso, 0);
        res.json({
            fecha, bodega, pais,
            resumen: {
                puntos: puntos.length,
                lineas,
                kg: pesoTotal,
                toneladas: Math.round(pesoTotal / 100) / 10,
                exceden: puntos.filter(p => p.excede).length
            },
            maxTruckKg: MAX_TRUCK_KG,
            puntos
        });
    } catch (err) {
        console.error('GET /api/planificador/pendientes error:', err);
        res.status(500).json({ error: 'Error al importar rutas pendientes' });
    }
});

module.exports = router;
