const express = require('express');
const https = require('https');
const fs = require('fs');
const path = require('path');
const { getPool, sql } = require('../db');
const { getSapDb } = require('../config/paises');
const router = express.Router();

// Camión más grande de la flota (kg). Un punto por encima de esto no cabe
// en ninguna unidad → "especial" (flete dedicado / viajes múltiples).
const MAX_TRUCK_KG = 22000;

// ── Helpers ──────────────────────────────────────────────
function normAddr(s) { return (s || '').replace(/[\r\n]+/g, ' ').replace(/\s+/g, ' ').trim(); }

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
    const region = (!depto || /guatemala/i.test(depto)) ? 'metro' : 'regional';
    return { zona, muni: muni || null, depto: depto || null, region };
}

// Trae las líneas pendientes (Zona 5 / RUTA) para fecha+bodega
async function fetchRows(pool, sapDb, bodega, fecha) {
    const r = await pool.request()
        .input('bodega', sql.NVarChar, bodega)
        .input('fecha', sql.Date, fecha)
        .query(`
            SELECT T0.DocNum, T0.CardCode, T0.CardName, T0.DocDueDate, T0.Address2, T0.Comments,
                   T7.SlpName, T1.Quantity,
                   CASE WHEN T5.ItmsGrpNam LIKE '%(6)%' THEN 200 ELSE T2.SWeight1 END AS PesoUnit
            FROM [server-sql].${sapDb}.dbo.ORDR T0
            INNER JOIN [server-sql].${sapDb}.dbo.RDR1 T1 ON T0.DocEntry = T1.DocEntry
            INNER JOIN [server-sql].${sapDb}.dbo.OITM T2 ON T1.ItemCode = T2.ItemCode
            INNER JOIN [server-sql].${sapDb}.dbo.OITB T5 ON T2.ItmsGrpCod = T5.ItmsGrpCod
            LEFT JOIN  [server-sql].${sapDb}.dbo.OSLP T7 ON T0.SlpCode = T7.SlpCode
            WHERE T0.U_Estado2 = '03' AND T1.WhsCode = @bodega AND T0.TrnspCode = 22
              AND T1.ItemCode NOT IN ('013956','031780')
              AND CAST(T0.DocDueDate AS DATE) = @fecha
        `);
    return r.recordset;
}

// Documentos (uno por DocNum) — para el grid de "Importar"
// fecha (YYYY-MM-DD) se usa como fechaEntrega para evitar corrimientos de zona
// horaria: todos los documentos filtrados tienen DocDueDate == fecha.
function buildDocumentos(rows, fecha) {
    const docs = new Map();
    let lineas = 0;
    for (const r of rows) {
        lineas++;
        if (!docs.has(r.DocNum)) {
            docs.set(r.DocNum, {
                docNum: r.DocNum, cliente: r.CardName, tipo: 'OV',
                fechaEntrega: fecha, direccion: normAddr(r.Address2),
                comentarios: normAddr(r.Comments), vendedor: r.SlpName || null,
                peso: 0, lineas: 0
            });
        }
        const d = docs.get(r.DocNum);
        d.peso += (r.PesoUnit || 0) * (r.Quantity || 0);
        d.lineas++;
    }
    const documentos = [...docs.values()].map(d => ({ ...d, peso: Math.round(d.peso) }))
        .sort((a, b) => b.peso - a.peso);
    return { documentos, lineas };
}

// Puntos de entrega (cliente+dirección) — para planificar.
// Incluye los campos de detalle para validar (OVs, vendedor, comentarios, fecha).
function buildPuntos(rows, fecha) {
    const pts = new Map();
    for (const r of rows) {
        const dir = normAddr(r.Address2);
        const key = r.CardCode + '||' + dir;
        if (!pts.has(key)) pts.set(key, { cliente: r.CardName, direccion: dir, ovs: new Set(), coments: new Set(), vendedor: null, peso: 0, ...parseGeo(r.Address2) });
        const p = pts.get(key);
        p.ovs.add(r.DocNum);
        const com = normAddr(r.Comments); if (com) p.coments.add(com);
        if (!p.vendedor && r.SlpName) p.vendedor = r.SlpName;
        p.peso += (r.PesoUnit || 0) * (r.Quantity || 0);
    }
    return [...pts.values()]
        .map(p => ({
            cliente: p.cliente, direccion: p.direccion,
            zona: p.zona, municipio: p.muni, departamento: p.depto, region: p.region,
            tipo: 'OV', fechaEntrega: fecha, vendedor: p.vendedor || null,
            comentarios: [...p.coments].join('  |  '), ovs: [...p.ovs],
            peso: Math.round(p.peso), excede: p.peso > MAX_TRUCK_KG
        }))
        .sort((a, b) => b.peso - a.peso)
        .map((p, i) => ({ id: i, ...p }));   // id estable tras ordenar
}

function resolveFecha(q) {
    if (q && /^\d{4}-\d{2}-\d{2}$/.test(q)) return q;
    const d = new Date(); d.setDate(d.getDate() + 1);
    return d.toISOString().slice(0, 10);
}

// ── GET /pendientes — grid de documentos ──
router.get('/pendientes', async (req, res) => {
    try {
        const pool = getPool();
        const pais = req.query.pais || req.session?.user?.selectedPais || 'GT';
        const sapDb = getSapDb(pais);
        const bodega = (req.query.bodega || '01').toString();
        const fecha = resolveFecha(req.query.fecha);
        const rows = await fetchRows(pool, sapDb, bodega, fecha);
        const { documentos, lineas } = buildDocumentos(rows, fecha);
        const kg = documentos.reduce((s, d) => s + d.peso, 0);
        res.json({
            fecha, bodega, pais, maxTruckKg: MAX_TRUCK_KG,
            resumen: { documentos: documentos.length, lineas, kg, toneladas: Math.round(kg / 100) / 10 },
            documentos
        });
    } catch (err) {
        console.error('GET /api/planificador/pendientes error:', err);
        res.status(500).json({ error: 'Error al importar rutas pendientes' });
    }
});

// ── Prompt ──────────────────────────────────────────────
const SYSTEM_PROMPT_DEFAULT = `Eres un planificador experto de rutas de reparto para una distribuidora en Guatemala.
Recibes una lista de PUNTOS DE ENTREGA pendientes (cada uno = un cliente en una dirección, con su peso total en kg y su ubicación) y una FLOTA de camiones disponibles. Debes agrupar los puntos en rutas.

REGLAS DURAS (obligatorias, no las violes):
1. El peso total de una ruta NO puede exceder la capacidad nominal (capacidad_kg) del camión asignado.
2. Máximo 5 puntos de entrega por ruta. Máximo 3 puntos si el camión es de 10 T o más (10000 kg o más).
3. Solo puedes usar la cantidad de camiones disponible por tipo. El tipo "22 T" es de uso ilimitado. No tienes que usar toda la flota.
4. Cada punto se asigna a exactamente UNA ruta. No dupliques ni omitas puntos.

CRITERIO GEOGRÁFICO:
- Los puntos "regional" (fuera del departamento de Guatemala) NO se mezclan con los "metro". Agrupa los regionales por municipio/departamento cercano; un destino lejano puede ir solo en su ruta.
- Los puntos "metro" (capital) se agrupan por zona; puedes combinar zonas vecinas en una misma ruta.

OBJETIVO: balancear la carga entre rutas (evita dejar unas casi llenas y otras casi vacías) y usar la menor cantidad de camiones razonable, sin violar las reglas.

Devuelve ÚNICAMENTE un objeto JSON válido, sin texto adicional ni markdown, con esta forma exacta:
{
  "rutas": [
    { "nombre": "R1 ...", "camion": "5 T", "capacidad_kg": 5000, "region": "metro", "peso_kg": 4500, "puntos": [0, 3, 7] }
  ],
  "notas": "observaciones breves (opcional)"
}
- "puntos" son los "id" numéricos de los puntos, tal cual te los di.
- "camion" debe ser uno de: "1.5 T", "3.5 T", "5 T", "10 T", "22 T".
- Elige para cada ruta el camión más pequeño en el que quepa su carga.`;

// El prompt se puede ajustar en config/planificador-prompt.txt SIN redeploy:
// se lee en cada corrida; si el archivo no existe, se usa el default de arriba.
const PROMPT_PATH = path.join(__dirname, '..', 'config', 'planificador-prompt.txt');
function getSystemPrompt() {
    try { const t = fs.readFileSync(PROMPT_PATH, 'utf8'); if (t && t.trim()) return t; } catch (_) { /* usa default */ }
    return SYSTEM_PROMPT_DEFAULT;
}

function buildUserMsg(ruteables, flota) {
    const puntosMsg = ruteables.map(p => ({
        id: p.id, cliente: p.cliente, region: p.region,
        zona: p.zona, municipio: p.municipio, departamento: p.departamento, peso_kg: p.peso
    }));
    const flotaMsg = flota.map(f => ({
        tipo: f.tipo, capacidad_kg: f.kg,
        disponibles: (f.disponibles == null ? 'ilimitado' : f.disponibles)
    }));
    return `FLOTA disponible:\n${JSON.stringify(flotaMsg, null, 1)}\n\n`
        + `PUNTOS DE ENTREGA a rutear (${ruteables.length}):\n${JSON.stringify(puntosMsg, null, 1)}\n\n`
        + `Agrupa TODOS estos puntos en rutas siguiendo las reglas. Devuelve solo el JSON.`;
}

// Llamada a la API de Anthropic por HTTP directo (sin SDK), en STREAMING.
// El streaming mantiene el socket activo (llegan eventos y pings continuos),
// evitando el timeout por inactividad en generaciones largas.
function callAnthropic(system, userText) {
    return new Promise((resolve, reject) => {
        if (!process.env.ANTHROPIC_API_KEY) return reject(new Error('Falta ANTHROPIC_API_KEY en el .env del servidor.'));
        const payload = JSON.stringify({
            model: 'claude-opus-4-8',
            max_tokens: 32000,
            stream: true,
            thinking: { type: 'adaptive' },
            output_config: { effort: 'high' },
            system,
            messages: [{ role: 'user', content: userText }]
        });
        const reqA = https.request({
            hostname: 'api.anthropic.com', path: '/v1/messages', method: 'POST',
            headers: {
                'content-type': 'application/json',
                'x-api-key': process.env.ANTHROPIC_API_KEY,
                'anthropic-version': '2023-06-01',
                'content-length': Buffer.byteLength(payload)
            }
        }, resp => {
            if (resp.statusCode !== 200) {
                let errData = '';
                resp.on('data', c => errData += c);
                resp.on('end', () => reject(new Error('Anthropic ' + resp.statusCode + ': ' + errData.slice(0, 400))));
                return;
            }
            resp.setEncoding('utf8');
            let buffer = '', text = '', stopReason = null;
            resp.on('data', chunk => {
                buffer += chunk;
                let nl;
                while ((nl = buffer.indexOf('\n')) !== -1) {
                    const line = buffer.slice(0, nl).trim();
                    buffer = buffer.slice(nl + 1);
                    if (!line.startsWith('data:')) continue;
                    const payloadStr = line.slice(5).trim();
                    if (!payloadStr || payloadStr === '[DONE]') continue;
                    let ev; try { ev = JSON.parse(payloadStr); } catch { continue; }
                    if (ev.type === 'content_block_delta' && ev.delta && ev.delta.type === 'text_delta') {
                        text += ev.delta.text;
                    } else if (ev.type === 'message_delta' && ev.delta && ev.delta.stop_reason) {
                        stopReason = ev.delta.stop_reason;
                    } else if (ev.type === 'error') {
                        reject(new Error('Anthropic stream: ' + JSON.stringify(ev.error || ev).slice(0, 300)));
                    }
                }
            });
            resp.on('end', () => {
                if (stopReason === 'refusal') return reject(new Error('La IA rechazó la solicitud.'));
                resolve({ text, stopReason });
            });
            resp.on('error', reject);
        });
        reqA.on('error', reject);
        // Timeout de inactividad: con streaming llegan eventos/pings seguido,
        // así que solo salta si el socket queda mudo mucho tiempo.
        reqA.setTimeout(180000, () => reqA.destroy(new Error('Timeout: Anthropic no respondió (socket inactivo 180s).')));
        reqA.write(payload);
        reqA.end();
    });
}

function parsePlan(text) {
    let t = (text || '').trim();
    // 1) si viene en un bloque markdown ```json ... ```, tomar su contenido
    const fence = t.match(/```(?:json)?\s*([\s\S]*?)```/i);
    if (fence) t = fence[1].trim();
    // 2) extraer el objeto JSON más externo (ignora texto antes/después)
    const i = t.indexOf('{');
    const j = t.lastIndexOf('}');
    if (i !== -1 && j !== -1 && j > i) t = t.slice(i, j + 1);
    return JSON.parse(t);
}

// Valida la propuesta de la IA contra las reglas duras
function validar(plan, puntosById, flota) {
    const violaciones = [];
    const usados = {};
    const asignados = new Set();
    const capPorTipo = {}; flota.forEach(f => capPorTipo[f.tipo] = f);

    for (const r of (plan.rutas || [])) {
        const f = capPorTipo[r.camion];
        const cap = f ? f.kg : 0;
        if (!f) violaciones.push(`Ruta "${r.nombre}": tipo de camión desconocido "${r.camion}".`);
        let peso = 0, n = 0;
        for (const id of (r.puntos || [])) {
            const p = puntosById[id];
            if (!p) { violaciones.push(`Ruta "${r.nombre}": el punto ${id} no existe.`); continue; }
            if (asignados.has(id)) violaciones.push(`El punto ${id} (${p.cliente}) está en más de una ruta.`);
            asignados.add(id); peso += p.peso; n++;
        }
        usados[r.camion] = (usados[r.camion] || 0) + 1;
        const maxPts = cap >= 10000 ? 3 : 5;
        if (cap && peso > cap) violaciones.push(`Ruta "${r.nombre}": ${peso} kg excede la capacidad de ${r.camion} (${cap} kg).`);
        if (n > maxPts) violaciones.push(`Ruta "${r.nombre}": ${n} puntos (máximo ${maxPts} para ${r.camion}).`);
    }
    for (const f of flota) {
        if (f.disponibles == null) continue; // ilimitado
        if ((usados[f.tipo] || 0) > f.disponibles) violaciones.push(`Se usaron ${usados[f.tipo]} camiones de ${f.tipo} (solo hay ${f.disponibles}).`);
    }
    const sinAsignar = Object.values(puntosById).filter(p => !p.excede && !asignados.has(p.id)).map(p => p.id);
    return { ok: violaciones.length === 0 && sinAsignar.length === 0, violaciones, sinAsignar };
}

// ── POST /planificar — llama a la IA y devuelve rutas agrupadas ──
router.post('/planificar', async (req, res) => {
    try {
        if (!process.env.ANTHROPIC_API_KEY) return res.status(500).json({ error: 'Falta ANTHROPIC_API_KEY en el .env del servidor. Agrégala y reinicia (pm2 restart picking --update-env).' });
        const pool = getPool();
        const pais = (req.body && req.body.pais) || req.session?.user?.selectedPais || 'GT';
        const sapDb = getSapDb(pais);
        const bodega = ((req.body && req.body.bodega) || '01').toString();
        const fecha = resolveFecha(req.body && req.body.fecha);
        const flota = Array.isArray(req.body && req.body.flota) ? req.body.flota : [];
        if (!flota.length) return res.status(400).json({ error: 'Falta la configuración de flota.' });

        const rows = await fetchRows(pool, sapDb, bodega, fecha);
        const puntos = buildPuntos(rows, fecha);
        const puntosById = {}; puntos.forEach(p => puntosById[p.id] = p);
        const especiales = puntos.filter(p => p.excede).map(p => p.id);
        const ruteables = puntos.filter(p => !p.excede);

        if (!ruteables.length) {
            return res.json({ fecha, puntos, rutas: [], especiales, notas: 'No hay puntos ruteables.', validacion: { ok: true, violaciones: [], sinAsignar: [] } });
        }

        const ai = await callAnthropic(getSystemPrompt(), buildUserMsg(ruteables, flota));
        let plan;
        try { plan = parsePlan(ai.text); }
        catch (e) {
            console.error('Planificador: respuesta no parseable. stop_reason=%s raw=%s', ai.stopReason, (ai.text || '').slice(0, 2000));
            return res.status(502).json({
                error: ai.stopReason === 'max_tokens'
                    ? 'La IA devolvió una respuesta truncada (se quedó sin espacio). Reintenta.'
                    : 'La IA devolvió un formato inesperado.',
                stopReason: ai.stopReason,
                raw: (ai.text || '').slice(0, 1500)
            });
        }

        const validacion = validar(plan, puntosById, flota);
        res.json({ fecha, puntos, rutas: plan.rutas || [], especiales, notas: plan.notas || '', validacion });
    } catch (err) {
        console.error('POST /api/planificador/planificar error:', err);
        res.status(500).json({ error: err.message || 'Error al planificar' });
    }
});

module.exports = router;
