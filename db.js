const sql = require('mssql');

const config = {
    server: process.env.DB_SERVER || process.env.DB_HOST,
    port: parseInt(process.env.DB_PORT || '1433'),
    database: process.env.DB_NAME,
    user: process.env.DB_USER,
    password: process.env.DB_PASSWORD,
    options: {
        encrypt: false,
        trustServerCertificate: true
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

module.exports = { connect, getPool, sql };
