// ════════════════════════════════════════════════════════════
// Configuración central por país
// ─ sap:  base SAP Business One en el linked server [server-sql]
// ─ lisa: base Lisa (WMS) en el linked server
// ─ modo: 'order' (picking por pedido) | 'product' (picking por producto)
//
// Para agregar un país nuevo basta con añadir una entrada aquí.
// ════════════════════════════════════════════════════════════
const PAISES = {
    GT: { sap: 'sboferco',     lisa: 'lisa_sboferco',     modo: 'product' }, // Guatemala
    SV: { sap: 'sbointergres', lisa: 'lisa_sbointergres', modo: 'order'   }, // El Salvador
    HN: { sap: 'sbopym',       lisa: 'lisa_sbopym',       modo: 'order'   }, // Honduras
};

const DEFAULT_PAIS = 'GT';

function getPais(pais) {
    return PAISES[pais] || PAISES[DEFAULT_PAIS];
}

function getSapDb(pais)  { return getPais(pais).sap; }
function getLisaDb(pais) { return getPais(pais).lisa; }
function esOrderMode(pais) { return getPais(pais).modo === 'order'; }

module.exports = { PAISES, DEFAULT_PAIS, getPais, getSapDb, getLisaDb, esOrderMode };
