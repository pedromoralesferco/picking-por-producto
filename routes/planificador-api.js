const express = require('express');
const { getPool, sql } = require('../db');
const { getSapDb } = require('../config/paises');
const router = express.Router();

// Camión más grande de la flota (kg). Referencia para etapas posteriores.
const MAX_TRUCK_KG = 22000;

// ── GET /api/planificador/pendientes?fecha=YYYY-MM-DD&bodega=01 ──
// Devuelve los documentos (OV) pendientes de planificar para la fecha/bodega,
// uno por DocNum, con los campos que se muestran en el grid. Zona 5 / GT.
router.get('/pendientes', async (req, res) => {
    try {
        const pool = getPool();
        const pais = req.query.pais || req.session?.user?.selectedPais || 'GT';
        const sapDb = getSapDb(pais);
        const bodega = (req.query.bodega || '01').toString();
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
                SELECT T0.DocNum, T0.CardCode, T0.CardName,
                       T0.DocDueDate, T0.Address2, T0.Comments,
                       T7.SlpName,
                       T1.Quantity,
                       CASE WHEN T5.ItmsGrpNam LIKE '%(6)%' THEN 200 ELSE T2.SWeight1 END AS PesoUnit
                FROM [server-sql].${sapDb}.dbo.ORDR T0
                INNER JOIN [server-sql].${sapDb}.dbo.RDR1 T1 ON T0.DocEntry = T1.DocEntry
                INNER JOIN [server-sql].${sapDb}.dbo.OITM T2 ON T1.ItemCode = T2.ItemCode
                INNER JOIN [server-sql].${sapDb}.dbo.OITB T5 ON T2.ItmsGrpCod = T5.ItmsGrpCod
                LEFT JOIN  [server-sql].${sapDb}.dbo.OSLP T7 ON T0.SlpCode = T7.SlpCode
                WHERE T0.U_Estado2 = '03'
                  AND T1.WhsCode = @bodega
                  AND T0.TrnspCode = 22
                  AND T1.ItemCode NOT IN ('013956','031780')
                  AND CAST(T0.DocDueDate AS DATE) = @fecha
            `);

        const clean = s => (s || '').replace(/[\r\n]+/g, ' ').replace(/\s+/g, ' ').trim();

        // Agregar por documento (DocNum)
        const docs = new Map();
        let lineas = 0;
        for (const r of result.recordset) {
            lineas++;
            if (!docs.has(r.DocNum)) {
                docs.set(r.DocNum, {
                    docNum: r.DocNum,
                    cliente: r.CardName,
                    tipo: 'OV',                          // fuente ORDR = todas OV
                    fechaEntrega: r.DocDueDate,          // DocDueDate
                    direccion: clean(r.Address2),
                    comentarios: clean(r.Comments),
                    vendedor: r.SlpName || null,
                    peso: 0,
                    lineas: 0
                });
            }
            const d = docs.get(r.DocNum);
            d.peso += (r.PesoUnit || 0) * (r.Quantity || 0);
            d.lineas++;
        }

        const documentos = [...docs.values()]
            .map(d => ({ ...d, peso: Math.round(d.peso) }))
            .sort((a, b) => b.peso - a.peso);

        const pesoTotal = documentos.reduce((s, d) => s + d.peso, 0);
        res.json({
            fecha, bodega, pais,
            maxTruckKg: MAX_TRUCK_KG,
            resumen: {
                documentos: documentos.length,
                lineas,
                kg: pesoTotal,
                toneladas: Math.round(pesoTotal / 100) / 10
            },
            documentos
        });
    } catch (err) {
        console.error('GET /api/planificador/pendientes error:', err);
        res.status(500).json({ error: 'Error al importar rutas pendientes' });
    }
});

module.exports = router;
