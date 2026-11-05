const sql = require('mssql');

const config = {
    server: process.env.DB_SERVER || process.env.DB_HOST,
    port: parseInt(process.env.DB_PORT || '1433'),
    database: process.env.DB_NAME,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    options: {
        encrypt: false,
        trustServerCertificate: true,
        useUTC: false
    },
    pool: {
        max: 20,
        min: 2,
        idleTimeoutMillis: 30000
    }
};

let pool;

async function connect() {
    pool = await sql.connect(config);
    console.log('Connected to SQL Server');
    return pool;
}

function getPool() {
    if (!pool) throw new Error('Database not connected');
    return pool;
}

// Pool de solo lectura para /api/planificacion (login PLAN_DB_USER: SELECT en vistas,
// EXECUTE en SP de lectura, y del lado de SAP un usuario de solo lectura en el linked server).
// Mientras no exista ese login, usa el pool principal.
let planPool;
async function getPlanPool() {
    if (!process.env.PLAN_DB_USER) return getPool();
    if (!planPool) {
        planPool = new sql.ConnectionPool({
            ...config,
            user: process.env.PLAN_DB_USER,
            password: process.env.PLAN_DB_PASSWORD,
            pool: { max: 5, min: 0, idleTimeoutMillis: 30000 }
        }).connect().catch(err => { planPool = null; throw err; });
    }
    return planPool;
}

// Pool para jobs largos (p. ej. el snapshot del backlog tarda ~1 min): mismo login
// que el app, pero con timeout de 10 min en lugar de los 15 s por defecto.
let jobPool;
async function getJobPool() {
    if (!jobPool) {
        jobPool = new sql.ConnectionPool({ ...config, requestTimeout: 10 * 60 * 1000, pool: { max: 2, min: 0, idleTimeoutMillis: 60000 } })
            .connect().catch(err => { jobPool = null; throw err; });
    }
    return jobPool;
}

module.exports = { connect, getPool, getPlanPool, getJobPool, sql };
