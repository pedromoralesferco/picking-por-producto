const express = require('express');
const { getPool, sql } = require('../db');
const { getSapDb, getLisaDb, esOrderMode } = require('../config/paises');
const router = express.Router();

/*
── SQL para crear tabla Carril y modificar RoutePlan ──
CREATE TABLE Carril (
    ID_Carril INT IDENTITY(1,1) PRIMARY KEY,
    Nombre NVARCHAR(50) NOT NULL,
    ID_Centro INT NOT NULL REFERENCES CentroDistribucion(ID_Centro),
    Activo BIT NOT NULL DEFAULT 1
);

ALTER TABLE RoutePlan ADD
    ID_Carril INT NULL,
    EstadoDespacho NVARCHAR(20) NULL DEFAULT 'Pendiente',
    FechaDespachoFin DATETIME NULL;

── SQL para crear tabla UsuarioCentro ──
CREATE TABLE UsuarioCentro (
    ID_Usuario INT NOT NULL REFERENCES Usuario(ID_Usuario),
    ID_Centro INT NOT NULL REFERENCES CentroDistribucion(ID_Centro),
    PRIMARY KEY (ID_Usuario, ID_Centro)
);
*/

// Helper: get user's active centro(s) from session
// If a centro is selected, return only that one; otherwise return all assigned
function getUserCentros(req) {
    if (!req.session || !req.session.user) return null;
    const user = req.session.user;
    if (user.selectedCentro) return [user.selectedCentro];
    return user.centros;
}

// ── Carriles ──

router.get('/carriles', async (req, res) => {
    try {
        const pool = getPool();
        const centro = req.query.centro;
        const centros = getUserCentros(req);
        let query = `SELECT ID_Carril, Nombre, ID_Centro FROM Carril WHERE Activo = 1`;
        const request = pool.request();
        if (centro) {
            query += ` AND ID_Centro = @centro`;
            request.input('centro', sql.Int, centro);
        }
        if (centros && centros.length > 0) {
            query += ` AND ID_Centro IN (${centros.map((_, i) => `@uc${i}`).join(',')})`;
            centros.forEach((c, i) => request.input(`uc${i}`, sql.Int, c));
        }
        query += ` ORDER BY Nombre`;
        const result = await request.query(query);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/carriles error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// ── Rutas (agregadas desde RoutePickingManagement) ──

router.get('/rutas', async (req, res) => {
    try {
        const pool = getPool();
        const centros = getUserCentros(req);
        let centroFilter = '';
        const request = pool.request();
        if (centros && centros.length > 0) {
            const params = centros.map((_, i) => `@uc${i}`).join(',');
            centros.forEach((c, i) => request.input(`uc${i}`, sql.Int, c));
            centroFilter = ` AND (c.ID_Centro IN (${params}) OR rp.ID_Carril IS NULL)`;
        }
        const result = await request.query(`
            SELECT
                rp.RouteNumber,
                rp.RouteName,
                rp.FechaPlanificacion,
                rp.AlmacenOrigen,
                rp.Estado,
                rp.FechaInicio,
                rp.FechaFin,
                rp.ID_Carril,
                rp.EstadoDespacho,
                c.Nombre AS CarrilNombre,
                ISNULL(rpm.TotalProductos, 0) AS TotalProductos,
                ISNULL(rpm.TotalArticulos, 0) AS TotalArticulos,
                ISNULL(rpm.PesoTotal, 0) AS PesoTotal,
                ISNULL(rpm.ProductosFinalizados, 0) AS ProductosFinalizados
            FROM RoutePlan rp
            LEFT JOIN Carril c ON c.ID_Carril = rp.ID_Carril
            LEFT JOIN (
                SELECT RouteNumber,
                       COUNT(*) AS TotalProductos,
                       SUM(ISNULL(TotalArticulo, 0)) AS TotalArticulos,
                       SUM(ISNULL(PesoTotal, 0)) AS PesoTotal,
                       SUM(CASE WHEN Estado = 'Finalizado' THEN 1 ELSE 0 END) AS ProductosFinalizados
                FROM RoutePickingManagement
                GROUP BY RouteNumber
            ) rpm ON rpm.RouteNumber = rp.RouteNumber
            WHERE (rp.Estado IN ('Pendiente', 'Iniciado')
               OR (rp.Estado = 'Finalizado' AND rp.FechaFin > DATEADD(MINUTE, -30, GETDATE())))
               ${centroFilter}
            ORDER BY
                CASE rp.Estado
                    WHEN 'Iniciado' THEN 0
                    WHEN 'Pendiente' THEN 1
                    WHEN 'Finalizado' THEN 2
                END,
                ISNULL(rp.Prioridad, 999999),
                rp.FechaPlanificacion DESC
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/rutas error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

router.get('/rutas/:routeNumber/productos', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('routeNumber', sql.Int, req.params.routeNumber)
            .query(`
                SELECT rpm.RouteNumber, rpm.RouteName, rpm.Product, rpm.ProductName,
                       rpm.TotalArticulo, rpm.PesoTotal, rpm.Estado,
                       rpm.ID_Operario, rpm.FechaAsignacion, rpm.FechaInicio, rpm.FechaFin,
                       o.Nombre AS PickerNombre
                FROM RoutePickingManagement rpm
                LEFT JOIN Operario o ON o.ID_Operario = rpm.ID_Operario
                WHERE rpm.RouteNumber = @routeNumber
                ORDER BY
                    CASE rpm.Estado
                        WHEN 'En Proceso' THEN 0
                        WHEN 'Asignado' THEN 1
                        WHEN 'Pendiente' THEN 2
                        WHEN 'Finalizado' THEN 3
                    END,
                    rpm.Product
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/rutas/:routeNumber/productos error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

router.get('/rutas/:routeNumber/resumen', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('routeNumber', sql.Int, req.params.routeNumber)
            .query(`
                SELECT
                    COUNT(*) AS TotalProductos,
                    SUM(CASE WHEN Estado = 'Finalizado' THEN 1 ELSE 0 END) AS ProductosFinalizados,
                    SUM(CASE WHEN Estado IN ('Asignado','En Proceso') THEN 1 ELSE 0 END) AS ProductosAsignados,
                    SUM(CASE WHEN Estado = 'Pendiente' THEN 1 ELSE 0 END) AS ProductosPendientes,
                    SUM(ISNULL(TotalArticulo, 0)) AS TotalArticulos,
                    SUM(ISNULL(PesoTotal, 0)) AS PesoTotal
                FROM RoutePickingManagement
                WHERE RouteNumber = @routeNumber
            `);
        res.json(result.recordset[0]);
    } catch (err) {
        console.error('GET /api/rutas/:routeNumber/resumen error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// ── Iniciar ruta ──

router.post('/rutas/:routeNumber/iniciar', async (req, res) => {
    try {
        const pool = getPool();
        const { idCarril } = req.body || {};
        const request = pool.request()
            .input('routeNumber', sql.Int, parseInt(req.params.routeNumber));

        let setClause = `Estado = 'Iniciado', FechaInicio = GETDATE()`;
        if (idCarril) {
            request.input('idCarril', sql.Int, parseInt(idCarril));
            setClause += `, ID_Carril = @idCarril, EstadoDespacho = 'Pendiente'`;
        }

        await request.query(`
            UPDATE RoutePlan
            SET ${setClause}
            WHERE RouteNumber = @routeNumber AND Estado = 'Pendiente'
        `);
        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/rutas/:routeNumber/iniciar error:', err);
        res.status(500).json({ error: 'Error al iniciar ruta' });
    }
});

// ── Tareas de un producto en una ruta ──

router.get('/rutas/:routeNumber/productos/:product/tareas', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('routeNumber', sql.NVarChar, req.params.routeNumber)
            .input('product', sql.NVarChar, req.params.product)
            .query(`
                SELECT MIN(ID_Task) AS ID_Task, Route_Number, OV_Number, DocType,
                       MAX(IDCustomerORder) AS IDCustomerORder,
                       MAX(IdAccountableOrder) AS IdAccountableOrder,
                       MAX(Line_ID) AS Line_ID,
                       MAX(IdProduct) AS IdProduct,
                       @product AS InternIdProduct,
                       MAX(Descripcion) AS Descripcion,
                       MAX(Cantidad) AS Cantidad,
                       MAX(CantidadPendiente) AS CantidadPendiente,
                       MAX(UnitWeight) AS UnitWeight,
                       CASE WHEN MAX(CantidadPendiente) = 0 THEN 'Finalizado' ELSE MAX(Estado) END AS Estado,
                       MAX(ID_Operario) AS ID_Operario,
                       MAX(FechaLiberacion) AS FechaLiberacion,
                       MAX(UltimaActualizacion) AS UltimaActualizacion
                FROM RoutePickingTask
                WHERE Route_Number = @routeNumber AND InternIdProduct = @product
                GROUP BY Route_Number, OV_Number, DocType
                ORDER BY
                    CASE WHEN MAX(CantidadPendiente) = 0 THEN 1 ELSE 0 END,
                    OV_Number
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET tareas error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// ── Asignar operario a un producto ──

router.post('/productos/asignar', async (req, res) => {
    try {
        const { routeNumber, product, operarioId, pickerId } = req.body;
        const idOperario = operarioId || pickerId; // backward compat
        const pool = getPool();
        await pool.request()
            .input('routeNumber', sql.Int, routeNumber)
            .input('product', sql.NVarChar, product)
            .input('operarioId', sql.Int, idOperario)
            .query(`
                UPDATE RoutePickingManagement
                SET ID_Operario = @operarioId
                WHERE RouteNumber = @routeNumber AND Product = @product
            `);
        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/productos/asignar error:', err);
        res.status(500).json({ error: 'Error al asignar operario' });
    }
});

// ── Cerrar un producto (forzar finalización) ──

router.post('/productos/cerrar', async (req, res) => {
    try {
        const { routeNumber, product } = req.body;
        const pool = getPool();

        await pool.request()
            .input('routeNumber', sql.NVarChar, routeNumber)
            .input('product', sql.NVarChar, product)
            .query(`
                UPDATE RoutePickingTask
                SET CantidadPendiente = 0, UltimaActualizacion = GETDATE()
                WHERE Route_Number = @routeNumber AND InternIdProduct = @product
                  AND Estado <> 'Finalizado'
            `);

        await pool.request()
            .input('routeNumber', sql.Int, routeNumber)
            .input('product', sql.NVarChar, product)
            .query(`
                UPDATE RoutePickingManagement
                SET Estado = 'Finalizado', FechaFin = GETDATE()
                WHERE RouteNumber = @routeNumber AND Product = @product
                  AND Estado <> 'Finalizado'
            `);

        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/productos/cerrar error:', err);
        res.status(500).json({ error: 'Error al cerrar producto' });
    }
});

// ── Finalizar ruta completa ──

router.post('/rutas/:routeNumber/finalizar', async (req, res) => {
    try {
        const pool = getPool();
        const rn = req.params.routeNumber;

        await pool.request()
            .input('routeNumber', sql.NVarChar, rn)
            .query(`
                UPDATE RoutePickingTask
                SET CantidadPendiente = 0, UltimaActualizacion = GETDATE()
                WHERE Route_Number = @routeNumber AND Estado <> 'Finalizado'
            `);

        await pool.request()
            .input('routeNumber', sql.Int, rn)
            .query(`
                UPDATE RoutePickingManagement
                SET Estado = 'Finalizado', FechaFin = GETDATE()
                WHERE RouteNumber = @routeNumber AND Estado <> 'Finalizado'
            `);

        await pool.request()
            .input('routeNumber', sql.Int, rn)
            .query(`
                UPDATE RoutePlan
                SET Estado = 'Finalizado'
                WHERE RouteNumber = @routeNumber AND Estado <> 'Finalizado'
            `);

        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/rutas/:routeNumber/finalizar error:', err);
        res.status(500).json({ error: 'Error al finalizar ruta' });
    }
});

// ── Limpiar tareas huérfanas de rutas finalizadas ──

router.post('/admin/limpiar-rutas-finalizadas', async (req, res) => {
    try {
        const pool = getPool();

        // Cerrar tareas de rutas ya finalizadas
        const taskResult = await pool.request().query(`
            UPDATE rt
            SET rt.CantidadPendiente = 0, rt.UltimaActualizacion = GETDATE()
            FROM RoutePickingTask rt
            INNER JOIN RoutePlan rp ON rp.RouteNumber = rt.Route_Number
            WHERE rp.Estado = 'Finalizado' AND rt.Estado <> 'Finalizado'
        `);

        // Cerrar productos de rutas ya finalizadas
        const mgmtResult = await pool.request().query(`
            UPDATE rpm
            SET rpm.Estado = 'Finalizado', rpm.FechaFin = GETDATE()
            FROM RoutePickingManagement rpm
            INNER JOIN RoutePlan rp ON rp.RouteNumber = rpm.RouteNumber
            WHERE rp.Estado = 'Finalizado' AND rpm.Estado <> 'Finalizado'
        `);

        res.json({
            ok: true,
            tareasActualizadas: taskResult.rowsAffected[0],
            productosActualizados: mgmtResult.rowsAffected[0]
        });
    } catch (err) {
        console.error('POST /api/admin/limpiar-rutas-finalizadas error:', err);
        res.status(500).json({ error: 'Error al limpiar' });
    }
});

// ── Operarios (para modal de asignación) ──

async function getOperarios(req, res) {
    try {
        const pool = getPool();
        const centros = getUserCentros(req);
        let centroFilter = '';
        const request = pool.request();
        if (centros && centros.length > 0) {
            const params = centros.map((_, i) => `@uc${i}`).join(',');
            centros.forEach((c, i) => request.input(`uc${i}`, sql.Int, c));
            centroFilter = ` AND o.ID_Centro IN (${params})`;
        }
        const result = await request.query(`
            SELECT o.ID_Operario, o.Nombre, o.ID_Centro, o.Pais,
                   cd.Nombre AS CentroNombre,
                (SELECT COUNT(*) FROM RoutePickingManagement
                 WHERE ID_Operario = o.ID_Operario AND Estado IN ('Asignado','En Proceso')) AS Asignados,
                (SELECT COUNT(*) FROM RoutePickingManagement
                 WHERE ID_Operario = o.ID_Operario AND Estado = 'Finalizado'
                   AND CAST(FechaFin AS DATE) = CAST(GETDATE() AS DATE)) AS CompletadosHoy
            FROM Operario o
            LEFT JOIN CentroDistribucion cd ON cd.ID_Centro = o.ID_Centro
            WHERE o.Activo = 1${centroFilter}
            ORDER BY o.Nombre
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/operarios error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
}

router.get('/operarios', getOperarios);
router.get('/pickers', getOperarios); // backward compat

// ── Picker view endpoints ──

router.get('/centros', async (req, res) => {
    try {
        const pool = getPool();
        const centros = getUserCentros(req);
        const request = pool.request();
        let where = '';
        if (centros && centros.length > 0) {
            const params = centros.map((_, i) => `@uc${i}`).join(',');
            centros.forEach((c, i) => request.input(`uc${i}`, sql.Int, c));
            where = ` WHERE ID_Centro IN (${params})`;
        }
        const result = await request.query(`
            SELECT ID_Centro, Nombre, Pais FROM CentroDistribucion${where} ORDER BY Pais, Nombre
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/centros error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

router.get('/centros/:id/pickers', async (req, res) => {
    try {
        const pool = getPool();
        // Detect country of this centro to query the right tables
        const centroRes = await pool.request()
            .input('idCentro', sql.Int, req.params.id)
            .query(`SELECT Pais FROM CentroDistribucion WHERE ID_Centro = @idCentro`);
        const pais = centroRes.recordset[0]?.Pais || 'GT';

        let query;
        if (esOrderMode(pais)) {
            // Order mode: count from OrderPickingManagement / OrderPickingTask
            query = `
                SELECT o.ID_Operario, o.Nombre,
                    (SELECT COUNT(*) FROM OrderPickingManagement
                     WHERE ID_Operario = o.ID_Operario AND Estado IN ('Asignado','En Proceso')) AS ProductosPendientes,
                    (SELECT COUNT(*) FROM OrderPickingTask
                     WHERE ID_Operario = o.ID_Operario AND Estado <> 'Finalizado') AS TareasPendientes
                FROM Operario o
                WHERE o.ID_Centro = @idCentro AND o.Activo = 1
                ORDER BY o.Nombre`;
        } else {
            // Product mode: count from RoutePickingManagement / RoutePickingTask
            query = `
                SELECT o.ID_Operario, o.Nombre,
                    (SELECT COUNT(*) FROM RoutePickingManagement
                     WHERE ID_Operario = o.ID_Operario AND Estado IN ('Asignado','En Proceso')) AS ProductosPendientes,
                    (SELECT COUNT(*) FROM RoutePickingTask
                     WHERE ID_Operario = o.ID_Operario AND Estado <> 'Finalizado') AS TareasPendientes
                FROM Operario o
                WHERE o.ID_Centro = @idCentro AND o.Activo = 1
                ORDER BY o.Nombre`;
        }

        const result = await pool.request()
            .input('idCentro', sql.Int, req.params.id)
            .query(query);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/centros/:id/pickers error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

router.get('/pickers/:id/productos', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('pickerId', sql.Int, req.params.id)
            .query(`
                ;WITH UniqueTasks AS (
                    SELECT Route_Number, OV_Number, DocType, InternIdProduct,
                           MAX(Descripcion) AS Descripcion,
                           MAX(Cantidad) AS Cantidad,
                           MAX(CantidadPendiente) AS CantidadPendiente,
                           MAX(UnitWeight) AS UnitWeight,
                           MAX(Estado) AS Estado,
                           MAX(UltimaActualizacion) AS UltimaActualizacion
                    FROM RoutePickingTask
                    WHERE ID_Operario = @pickerId
                    GROUP BY Route_Number, OV_Number, DocType, InternIdProduct
                )
                SELECT t.Route_Number AS RouteNumber,
                       MAX(rp.RouteName) AS RouteName,
                       t.InternIdProduct AS Product,
                       MAX(t.Descripcion) AS ProductName,
                       COUNT(*) AS TotalArticulo,
                       SUM(t.Cantidad * ISNULL(t.UnitWeight, 0)) AS PesoTotal,
                       CASE
                           WHEN SUM(t.CantidadPendiente) = 0 THEN 'Finalizado'
                           WHEN MAX(t.Estado) = 'En Proceso' THEN 'En Proceso'
                           ELSE 'Asignado'
                       END AS Estado,
                       MIN(t.UltimaActualizacion) AS FechaAsignacion,
                       MAX(car.Nombre) AS CarrilNombre
                FROM UniqueTasks t
                LEFT JOIN RoutePlan rp ON rp.RouteNumber = t.Route_Number
                LEFT JOIN Carril car ON car.ID_Carril = rp.ID_Carril
                GROUP BY t.Route_Number, t.InternIdProduct
                HAVING SUM(t.CantidadPendiente) > 0
                   OR (SUM(t.CantidadPendiente) = 0 AND CAST(MAX(t.UltimaActualizacion) AS DATE) = CAST(GETDATE() AS DATE))
                ORDER BY
                    CASE
                        WHEN SUM(t.CantidadPendiente) > 0 AND MAX(t.Estado) = 'En Proceso' THEN 0
                        WHEN SUM(t.CantidadPendiente) > 0 THEN 1
                        ELSE 2
                    END,
                    MIN(t.UltimaActualizacion),
                    t.Route_Number, t.InternIdProduct
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/pickers/:id/productos error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

router.get('/pickers/:id/resumen', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('pickerId', sql.Int, req.params.id)
            .query(`
                ;WITH UniqueTasks AS (
                    SELECT Route_Number, OV_Number, DocType, InternIdProduct,
                           MAX(Cantidad) AS Cantidad,
                           MAX(CantidadPendiente) AS CantidadPendiente,
                           MAX(UnitWeight) AS UnitWeight,
                           CASE WHEN MAX(CantidadPendiente) = 0 THEN 'Finalizado' ELSE MAX(Estado) END AS Estado,
                           MAX(UltimaActualizacion) AS UltimaActualizacion
                    FROM RoutePickingTask
                    WHERE ID_Operario = @pickerId
                    GROUP BY Route_Number, OV_Number, DocType, InternIdProduct
                )
                SELECT
                    (SELECT COUNT(*) FROM UniqueTasks WHERE Estado <> 'Finalizado') AS TareasPendientes,
                    (SELECT ISNULL(SUM(CantidadPendiente * ISNULL(UnitWeight, 0)), 0) FROM UniqueTasks WHERE Estado <> 'Finalizado') AS KgPendientes,
                    (SELECT COUNT(*) FROM UniqueTasks WHERE Estado = 'Finalizado' AND CAST(UltimaActualizacion AS DATE) = CAST(GETDATE() AS DATE)) AS TareasCompletadasHoy,
                    (SELECT ISNULL(SUM(Cantidad * ISNULL(UnitWeight, 0)), 0) FROM UniqueTasks WHERE Estado = 'Finalizado' AND CAST(UltimaActualizacion AS DATE) = CAST(GETDATE() AS DATE)) AS KgCompletadosHoy
            `);
        res.json(result.recordset[0]);
    } catch (err) {
        console.error('GET /api/pickers/:id/resumen error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

router.get('/pickers/:id/producto-tareas', async (req, res) => {
    try {
        const { routeNumber, product } = req.query;
        const pool = getPool();
        const result = await pool.request()
            .input('routeNumber', sql.NVarChar, routeNumber)
            .input('product', sql.NVarChar, product)
            .query(`
                SELECT MIN(ID_Task) AS ID_Task, OV_Number, DocType,
                       MAX(Descripcion) AS Descripcion,
                       MAX(Cantidad) AS Cantidad,
                       MAX(CantidadPendiente) AS CantidadPendiente,
                       MAX(UnitWeight) AS UnitWeight,
                       CASE WHEN MAX(CantidadPendiente) = 0 THEN 'Finalizado' ELSE MAX(Estado) END AS Estado
                FROM RoutePickingTask
                WHERE Route_Number = @routeNumber AND InternIdProduct = @product
                GROUP BY OV_Number, DocType
                ORDER BY
                    CASE WHEN MAX(CantidadPendiente) = 0 THEN 1 ELSE 0 END,
                    OV_Number
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/pickers/:id/producto-tareas error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// ── Priorización de Rutas ──

router.get('/priorizacion/rutas', async (req, res) => {
    try {
        const pool = getPool();
        const centros = getUserCentros(req);
        let centroFilter = '';
        const request = pool.request();
        if (centros && centros.length > 0) {
            const params = centros.map((_, i) => `@uc${i}`).join(',');
            centros.forEach((c, i) => request.input(`uc${i}`, sql.Int, c));
            centroFilter = ` AND (c.ID_Centro IN (${params}) OR rp.ID_Carril IS NULL)`;
        }
        const result = await request.query(`
            SELECT rp.RouteNumber, rp.RouteName, rp.FechaPlanificacion, rp.AlmacenOrigen,
                   rp.Estado, rp.Prioridad, rp.FechaInicio,
                   ISNULL(rp.PesoEstimado, 0) AS PesoTotal,
                   CASE WHEN rp.Estado = 'Iniciado'
                        THEN ISNULL(rp.PesoEstimado, 0) - ISNULL(rpm.PesoFinalizado, 0)
                        ELSE ISNULL(rp.PesoEstimado, 0)
                   END AS PesoPendiente,
                   ISNULL(rpm.TotalProductos, 0) AS TotalProductos,
                   ISNULL(rpm.ProductosFinalizados, 0) AS ProductosFinalizados
            FROM RoutePlan rp
            LEFT JOIN Carril c ON c.ID_Carril = rp.ID_Carril
            LEFT JOIN (
                SELECT RouteNumber,
                       COUNT(DISTINCT Product) AS TotalProductos,
                       SUM(CASE WHEN Estado = 'Finalizado' THEN 1 ELSE 0 END) AS ProductosFinalizados,
                       SUM(CASE WHEN Estado = 'Finalizado' THEN ISNULL(PesoTotal, 0) ELSE 0 END) AS PesoFinalizado
                FROM RoutePickingManagement
                WHERE RouteNumber IN (SELECT RouteNumber FROM RoutePlan WHERE Estado = 'Iniciado')
                GROUP BY RouteNumber
            ) rpm ON rpm.RouteNumber = rp.RouteNumber
            WHERE rp.Estado IN ('Iniciado', 'Pendiente')
              AND (rp.Estado = 'Iniciado' OR rp.FechaPlanificacion >= DATEADD(DAY, -3, CAST(GETDATE() AS DATE)))
              ${centroFilter}
            ORDER BY
                CASE rp.Estado WHEN 'Iniciado' THEN 0 ELSE 1 END,
                ISNULL(rp.Prioridad, 999999),
                rp.FechaPlanificacion DESC
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/priorizacion/rutas error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

router.post('/priorizacion/guardar', async (req, res) => {
    try {
        const { orden } = req.body;
        if (!Array.isArray(orden)) {
            return res.status(400).json({ error: 'Se requiere un array de rutas' });
        }
        const pool = getPool();
        for (let i = 0; i < orden.length; i++) {
            await pool.request()
                .input('routeNumber', sql.Int, orden[i])
                .input('prioridad', sql.Int, i + 1)
                .query(`
                    UPDATE RoutePlan
                    SET Prioridad = @prioridad
                    WHERE RouteNumber = @routeNumber AND Estado = 'Pendiente'
                `);
        }
        res.json({ ok: true, actualizadas: orden.length });
    } catch (err) {
        console.error('POST /api/priorizacion/guardar error:', err);
        res.status(500).json({ error: 'Error al guardar prioridades' });
    }
});

// ── Despacho endpoints ──

router.get('/despacho/rutas', async (req, res) => {
    try {
        const pool = getPool();
        const centros = getUserCentros(req);
        let centroFilter = '';
        const request = pool.request();
        if (centros && centros.length > 0) {
            const params = centros.map((_, i) => `@uc${i}`).join(',');
            centros.forEach((c, i) => request.input(`uc${i}`, sql.Int, c));
            centroFilter = ` AND c.ID_Centro IN (${params})`;
        }
        const result = await request.query(`
            SELECT
                rp.RouteNumber,
                rp.RouteName,
                rp.Estado,
                rp.EstadoDespacho,
                rp.FechaDespachoFin,
                rp.ID_Carril,
                c.Nombre AS CarrilNombre,
                c.ID_Centro,
                ISNULL(rp.PesoEstimado, 0) AS PesoEstimado,
                ISNULL(rpm.TotalProductos, 0) AS TotalProductos,
                ISNULL(rpm.ProductosFinalizados, 0) AS ProductosFinalizados
            FROM RoutePlan rp
            LEFT JOIN Carril c ON c.ID_Carril = rp.ID_Carril
            LEFT JOIN (
                SELECT RouteNumber,
                       COUNT(*) AS TotalProductos,
                       SUM(CASE WHEN Estado = 'Finalizado' THEN 1 ELSE 0 END) AS ProductosFinalizados
                FROM RoutePickingManagement
                GROUP BY RouteNumber
            ) rpm ON rpm.RouteNumber = rp.RouteNumber
            WHERE rp.ID_Carril IS NOT NULL
              AND (
                  (rp.Estado IN ('Iniciado', 'Finalizado') AND rp.EstadoDespacho IN ('Pendiente', 'Listo para Carga'))
                  OR (rp.EstadoDespacho = 'Finalizado' AND rp.FechaDespachoFin > DATEADD(MINUTE, -2, GETDATE()))
              )
              ${centroFilter}
            ORDER BY c.Nombre, rp.RouteNumber
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/despacho/rutas error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

router.post('/despacho/estado', async (req, res) => {
    try {
        const { routeNumber, estado } = req.body;
        if (!routeNumber || !estado) {
            return res.status(400).json({ error: 'routeNumber y estado requeridos' });
        }

        const validEstados = ['Pendiente', 'Listo para Carga', 'Finalizado'];
        if (!validEstados.includes(estado)) {
            return res.status(400).json({ error: 'Estado no valido' });
        }

        const pool = getPool();

        // Validate: can't set 'Listo para Carga' unless picking is Finalizado
        if (estado === 'Listo para Carga') {
            const check = await pool.request()
                .input('routeNumber', sql.Int, routeNumber)
                .query(`SELECT Estado FROM RoutePlan WHERE RouteNumber = @routeNumber`);
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
            .input('routeNumber', sql.Int, routeNumber)
            .input('estado', sql.NVarChar, estado)
            .query(`
                UPDATE RoutePlan
                SET ${setClause}
                WHERE RouteNumber = @routeNumber
            `);

        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/despacho/estado error:', err);
        res.status(500).json({ error: 'Error al cambiar estado de despacho' });
    }
});

// ── Documentos de una ruta (para despacho detail) ──

router.get('/despacho/rutas/:routeNumber/documentos', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('routeNumber', sql.Int, parseInt(req.params.routeNumber))
            .query(`
                SELECT
                    OV_Number,
                    DocType,
                    MAX(IDCustomerORder) AS IDCustomerOrder,
                    COUNT(DISTINCT InternIdProduct) AS TotalProductos,
                    SUM(CASE WHEN CantidadPendiente = 0 THEN 1 ELSE 0 END) AS ProductosFinalizados,
                    SUM(ISNULL(Cantidad, 0) * ISNULL(UnitWeight, 0)) AS PesoTotal,
                    CASE WHEN SUM(CantidadPendiente) = 0 THEN 'Finalizado' ELSE 'Pendiente' END AS Estado
                FROM RoutePickingTask
                WHERE Route_Number = @routeNumber
                GROUP BY OV_Number, DocType
                ORDER BY
                    CASE WHEN SUM(CantidadPendiente) = 0 THEN 1 ELSE 0 END,
                    OV_Number
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/despacho/rutas/:routeNumber/documentos error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

router.get('/despacho/rutas/:routeNumber/documentos/:ovNumber/productos', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request()
            .input('routeNumber', sql.Int, parseInt(req.params.routeNumber))
            .input('ovNumber', sql.NVarChar, req.params.ovNumber)
            .query(`
                SELECT
                    InternIdProduct AS Product,
                    MAX(Descripcion) AS ProductName,
                    MAX(Cantidad) AS Cantidad,
                    MAX(CantidadPendiente) AS CantidadPendiente,
                    MAX(UnitWeight) AS UnitWeight,
                    CASE WHEN MAX(CantidadPendiente) = 0 THEN 'Finalizado' ELSE MAX(Estado) END AS Estado
                FROM RoutePickingTask
                WHERE Route_Number = @routeNumber AND OV_Number = @ovNumber
                GROUP BY InternIdProduct
                ORDER BY
                    CASE WHEN MAX(CantidadPendiente) = 0 THEN 1 ELSE 0 END,
                    InternIdProduct
            `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET documentos productos error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// ── Cuadro de Ruta (print data) ──

router.get('/despacho/cuadro-ruta/:routeNumber', async (req, res) => {
    try {
        const pool = getPool();
        const routeNumber = parseInt(req.params.routeNumber);

        // Detect country from query param or session
        const pais = req.query.pais || req.session?.user?.selectedPais || 'GT';
        const db = getSapDb(pais);

        // Header + lines with joins
        const reqJoin = pais === 'GT'
            ? `LEFT JOIN [server-sql].[${db}].[dbo].[@REQ_ENTREGA] REQ WITH (NOLOCK)
                    ON CLI.U_ReqEntrega = REQ.Code COLLATE DATABASE_DEFAULT`
            : '';
        const reqSelect = pais === 'GT'
            ? `ISNULL(REQ.U_U_Descripcion, '') AS TextoLargo,`
            : `'' AS TextoLargo,`;

        const result = await pool.request()
            .input('routeNumber', sql.Int, routeNumber)
            .query(`
                SELECT
                    T0.DocNum, T0.U_NombreR, T0.U_ID_Camion, T0.U_Placa, T0.U_Chofer,
                    T0.U_Capacidad, T0.U_Fecha_Entrega, T0.U_CardCode,
                    T0.U_Planificador, T0.U_TelPiloto, T0.U_Almacen_origen,
                    PLN.Name AS Planificador,
                    ISNULL(PRV.CardName, '') AS Nombre_Transportista,
                    T1.LineId, T1.U_No_OV, T1.U_Codigo_Cliente, T1.U_Direccion,
                    T1.U_Comentarios, T1.U_Asesor, T1.U_Peso_1,
                    T1.U_Tipo_Documento,
                    ODR.CardCode AS ClienteCode,
                    CLI.CardName AS ClienteNombre,
                    ODR.DocDate AS FechaCreacion,
                    ODR.DocDueDate AS FechaEntrega,
                    ${reqSelect}
                    T0.U_Fecha_Salida
                FROM [server-sql].[${db}].[dbo].[@CUADRO_RUTA_E] T0 WITH (NOLOCK)
                INNER JOIN [server-sql].[${db}].[dbo].[@CUADRO_RUTA_D] T1 WITH (NOLOCK)
                    ON T0.DocEntry = T1.DocEntry
                LEFT JOIN [server-sql].[${db}].[dbo].[@PLANIFICADORES] PLN WITH (NOLOCK)
                    ON T0.U_Planificador = PLN.Code COLLATE DATABASE_DEFAULT
                LEFT JOIN [server-sql].[${db}].[dbo].OCRD PRV WITH (NOLOCK)
                    ON T0.U_CardCode = PRV.CardCode
                LEFT JOIN [server-sql].[${db}].[dbo].ORDR ODR WITH (NOLOCK)
                    ON T1.U_No_OV = CAST(ODR.DocNum AS NVARCHAR) COLLATE DATABASE_DEFAULT
                LEFT JOIN [server-sql].[${db}].[dbo].OCRD CLI WITH (NOLOCK)
                    ON ODR.CardCode = CLI.CardCode
                ${reqJoin}
                WHERE T0.DocNum = @routeNumber
                ORDER BY T1.LineId
            `);

        if (result.recordset.length === 0) {
            return res.status(404).json({ error: 'Cuadro de ruta no encontrado' });
        }

        // Build response: header + lines
        const first = result.recordset[0];
        const pesoTotal = result.recordset.reduce((sum, r) => sum + (r.U_Peso_1 || 0), 0);
        const capacidad = parseFloat(first.U_Capacidad) || 0;
        const ocupacion = capacidad > 0 ? ((pesoTotal / 1000) / capacidad * 100) : 0;

        const header = {
            DocNum: first.DocNum,
            NombreRuta: first.U_NombreR,
            Transporte: first.U_ID_Camion,
            Placa: first.U_Placa,
            Chofer: first.U_Chofer,
            Capacidad: first.U_Capacidad,
            FechaEntrega: first.U_Fecha_Entrega,
            Transportista: first.Nombre_Transportista,
            Planificador: first.Planificador,
            TelPiloto: first.U_TelPiloto,
            Almacen: first.U_Almacen_origen,
            PesoTotal: pesoTotal,
            Ocupacion: ocupacion
        };

        const lineas = result.recordset.map(r => ({
            LineId: r.LineId,
            TipoDocumento: r.U_Tipo_Documento,
            NumeroOV: r.U_No_OV,
            ClienteCodigo: r.ClienteCode || r.U_Codigo_Cliente,
            ClienteNombre: r.ClienteNombre,
            Direccion: r.U_Direccion,
            Comentarios: r.U_Comentarios,
            Asesor: r.U_Asesor,
            Peso: r.U_Peso_1,
            FechaCreacion: r.FechaCreacion,
            FechaEntrega: r.FechaEntrega,
            TextoLargo: r.TextoLargo
        }));

        res.json({ header, lineas });
    } catch (err) {
        console.error('GET /api/despacho/cuadro-ruta error:', err);
        res.status(500).json({ error: 'Error al obtener cuadro de ruta' });
    }
});

// ══════════════════════════════════════════════
// ── Pase de Salida ──
// ══════════════════════════════════════════════

// Search: find DL (OV delivery) or REQDEL (transfer shipment) transactions by document number
router.get('/pase-salida/buscar/:docNum', async (req, res) => {
    try {
        const pool = getPool();
        const docNum = parseInt(req.params.docNum);
        if (isNaN(docNum)) return res.status(400).json({ error: 'Número de documento inválido' });

        const pais = req.query.pais || 'GT';
        const lisaDb = getLisaDb(pais);
        const sapDb  = getSapDb(pais);

        // 1) Try as OV first (DL transactions)
        const ovResult = await pool.request()
            .input('docNum', sql.Int, docNum)
            .query(`
                SELECT DISTINCT
                    'OV' AS TipoDocumento,
                    t0.DocNumSAP AS NumeroDocumento,
                    t0.DateTimeTransaction AS FechaTransaccion,
                    t8.CardCode AS CodigoCliente,
                    t8.CardName AS NombreCliente,
                    t8.Address2 AS Direccion,
                    t8.U_Celular AS Telefono,
                    slp.SlpName AS Vendedor,
                    t8.DocDueDate AS FechaComprometida,
                    pag.PymntGroup AS TipoPago,
                    ship.TrnspName AS TipoSalida,
                    t8.Comments AS Observaciones,
                    t5.Code AS CodAlmacen,
                    t5.Name AS Almacen,
                    ISNULL(suc.U_BranchName, '') AS Sucursal
                FROM [server-sql].[${lisaDb}].dbo.InventoryTransactionLog t0 WITH (NOLOCK)
                LEFT JOIN [server-sql].[${lisaDb}].dbo.Product t4 WITH (NOLOCK) ON t4.IDProduct = t0.IDProduct
                LEFT JOIN [server-sql].[${lisaDb}].dbo.WareHouse t5 WITH (NOLOCK) ON t5.IDWareHouse = t0.IDWarehouse
                LEFT JOIN [server-sql].[${sapDb}].dbo.ORDR t8 WITH (NOLOCK) ON t8.DocNum = t0.DocNumSAP
                LEFT JOIN [server-sql].[${sapDb}].dbo.OSLP slp WITH (NOLOCK) ON slp.SlpCode = t8.SlpCode
                LEFT JOIN [server-sql].[${sapDb}].dbo.OCTG pag WITH (NOLOCK) ON pag.GroupNum = t8.GroupNum
                LEFT JOIN [server-sql].[${sapDb}].dbo.OSHP ship WITH (NOLOCK) ON ship.TrnspCode = t8.TrnspCode
                LEFT JOIN [server-sql].[${sapDb}].dbo.[@sucursal_ccosto] suc WITH (NOLOCK) ON suc.Name = t8.U_sucursal
                WHERE t0.TransactionType = 'DL'
                AND t0.DocNumSAP = @docNum
            `);

        if (ovResult.recordset.length > 0) {
            // Get detail lines
            const lines = await pool.request()
                .input('docNum', sql.Int, docNum)
                .query(`
                    SELECT
                        t0.InternIDProduct AS CodigoMaterial,
                        t4.ProductName AS NombreMaterial,
                        SUM(t0.OldQty - t0.NewQty) AS Cantidad
                    FROM [server-sql].[${lisaDb}].dbo.InventoryTransactionLog t0 WITH (NOLOCK)
                    LEFT JOIN [server-sql].[${lisaDb}].dbo.Product t4 WITH (NOLOCK) ON t4.IDProduct = t0.IDProduct
                    WHERE t0.TransactionType = 'DL'
                    AND t0.DocNumSAP = @docNum
                    GROUP BY t0.InternIDProduct, t4.ProductName
                    ORDER BY t0.InternIDProduct
                `);

            const h = ovResult.recordset[0];
            return res.json({
                tipo: 'OV',
                header: {
                    Fecha: h.FechaTransaccion,
                    CodigoCliente: h.CodigoCliente,
                    NombreCliente: h.NombreCliente,
                    NumeroDocumento: h.NumeroDocumento,
                    Direccion: (h.Direccion || '').replace(/\r/g, ' '),
                    Telefono: h.Telefono || '',
                    Vendedor: h.Vendedor,
                    FechaComprometida: h.FechaComprometida,
                    TipoPago: h.TipoPago,
                    TipoSalida: h.TipoSalida,
                    Observaciones: h.Observaciones,
                    CodAlmacen: h.CodAlmacen,
                    Almacen: h.Almacen,
                    Sucursal: h.Sucursal
                },
                lineas: lines.recordset.map(l => ({
                    CodigoMaterial: l.CodigoMaterial,
                    NombreMaterial: l.NombreMaterial,
                    Cantidad: l.Cantidad
                }))
            });
        }

        // 2) Try as TR (REQDEL transactions from OWTQ)
        const trResult = await pool.request()
            .input('docNum', sql.Int, docNum)
            .query(`
                SELECT DISTINCT
                    'TR' AS TipoDocumento,
                    t0.DocNumSAP AS NumeroDocumento,
                    t0.DateTimeTransaction AS FechaTransaccion,
                    t5.Code AS CodAlmacenOrigen,
                    t5.Name AS AlmacenOrigen,
                    tq.ToWhsCode AS CodAlmacenDestino,
                    whd.WhsName AS AlmacenDestino,
                    tq.Comments AS Observaciones,
                    tq.DocDate AS FechaDocumento,
                    slp.SlpName AS Solicitante
                FROM [server-sql].[${lisaDb}].dbo.InventoryTransactionLog t0 WITH (NOLOCK)
                LEFT JOIN [server-sql].[${lisaDb}].dbo.Product t4 WITH (NOLOCK) ON t4.IDProduct = t0.IDProduct
                LEFT JOIN [server-sql].[${lisaDb}].dbo.WareHouse t5 WITH (NOLOCK) ON t5.IDWareHouse = t0.IDWarehouse
                LEFT JOIN [server-sql].[${sapDb}].dbo.OWTQ tq WITH (NOLOCK) ON tq.DocNum = t0.DocNumSAP
                LEFT JOIN [server-sql].[${sapDb}].dbo.OWHS whd WITH (NOLOCK) ON whd.WhsCode = tq.ToWhsCode
                LEFT JOIN [server-sql].[${sapDb}].dbo.OSLP slp WITH (NOLOCK) ON slp.SlpCode = tq.SlpCode
                WHERE t0.TransactionType = 'REQDEL'
                AND t0.OldQty > t0.NewQty
                AND t0.DocNumSAP = @docNum
            `);

        if (trResult.recordset.length > 0) {
            const lines = await pool.request()
                .input('docNum', sql.Int, docNum)
                .query(`
                    SELECT
                        t0.InternIDProduct AS CodigoMaterial,
                        t4.ProductName AS NombreMaterial,
                        SUM(t0.OldQty - t0.NewQty) AS Cantidad
                    FROM [server-sql].[${lisaDb}].dbo.InventoryTransactionLog t0 WITH (NOLOCK)
                    LEFT JOIN [server-sql].[${lisaDb}].dbo.Product t4 WITH (NOLOCK) ON t4.IDProduct = t0.IDProduct
                    WHERE t0.TransactionType = 'REQDEL'
                    AND t0.OldQty > t0.NewQty
                    AND t0.DocNumSAP = @docNum
                    GROUP BY t0.InternIDProduct, t4.ProductName
                    ORDER BY t0.InternIDProduct
                `);

            const h = trResult.recordset[0];
            return res.json({
                tipo: 'TR',
                header: {
                    Fecha: h.FechaTransaccion,
                    CodigoCliente: '',
                    NombreCliente: h.AlmacenDestino || '',
                    NumeroDocumento: h.NumeroDocumento,
                    Direccion: h.AlmacenDestino || '',
                    Telefono: '',
                    Vendedor: h.Solicitante || '',
                    FechaComprometida: h.FechaDocumento,
                    TipoPago: '',
                    TipoSalida: 'TRASLADO',
                    Observaciones: h.Observaciones,
                    CodAlmacen: h.CodAlmacenOrigen,
                    Almacen: h.AlmacenOrigen,
                    Sucursal: h.AlmacenDestino || ''
                },
                lineas: lines.recordset.map(l => ({
                    CodigoMaterial: l.CodigoMaterial,
                    NombreMaterial: l.NombreMaterial,
                    Cantidad: l.Cantidad
                }))
            });
        }

        // 3) Not found as DL or REQDEL — try to find OV in SAP (maybe not dispatched yet)
        const sapOV = await pool.request()
            .input('docNum', sql.Int, docNum)
            .query(`
                SELECT TOP 1 t8.DocNum
                FROM [server-sql].[${sapDb}].dbo.ORDR t8 WITH (NOLOCK)
                WHERE t8.DocNum = @docNum
            `);

        if (sapOV.recordset.length > 0) {
            return res.status(404).json({
                error: 'El documento ' + docNum + ' existe como OV en SAP pero aún no tiene despacho (entrega) registrado en LISA.'
            });
        }

        const sapTR = await pool.request()
            .input('docNum', sql.Int, docNum)
            .query(`
                SELECT TOP 1 tq.DocNum
                FROM [server-sql].[${sapDb}].dbo.OWTQ tq WITH (NOLOCK)
                WHERE tq.DocNum = @docNum
            `);

        if (sapTR.recordset.length > 0) {
            return res.status(404).json({
                error: 'El documento ' + docNum + ' existe como Solicitud de Traslado en SAP pero aún no tiene envío registrado en LISA.'
            });
        }

        res.status(404).json({ error: 'No se encontró el documento ' + docNum + ' como OV ni como TR.' });
    } catch (err) {
        console.error('GET /api/pase-salida/buscar error:', err);
        res.status(500).json({ error: 'Error al buscar documento: ' + err.message });
    }
});

// List recent dispatches (DL + REQDEL) for a warehouse, for browsing
router.get('/pase-salida/recientes', async (req, res) => {
    try {
        const pool = getPool();
        const pais = req.query.pais || 'GT';
        const codAlmacen = req.query.almacen || '';
        const lisaDb = getLisaDb(pais);
        const sapDb  = getSapDb(pais);

        let almacenFilter = '';
        if (codAlmacen) {
            almacenFilter = `AND t5.Code = @codAlmacen`;
        }

        const result = await pool.request()
            .input('codAlmacen', sql.VarChar(8), codAlmacen)
            .query(`
                SELECT TOP 50
                    t0.DocNumSAP AS NumeroDocumento,
                    CASE WHEN t0.TransactionType = 'DL' THEN 'OV' ELSE 'TR' END AS Tipo,
                    MAX(t0.DateTimeTransaction) AS Fecha,
                    MAX(t8.CardName) AS Cliente,
                    MAX(t5.Code) AS CodAlmacen,
                    MAX(t5.Name) AS Almacen,
                    MAX(ship.TrnspName) AS TipoSalida,
                    COUNT(DISTINCT t0.InternIDProduct) AS CantArticulos,
                    SUM(t0.OldQty - t0.NewQty) AS TotalPiezas
                FROM [server-sql].[${lisaDb}].dbo.InventoryTransactionLog t0 WITH (NOLOCK)
                LEFT JOIN [server-sql].[${lisaDb}].dbo.WareHouse t5 WITH (NOLOCK) ON t5.IDWareHouse = t0.IDWarehouse
                LEFT JOIN [server-sql].[${sapDb}].dbo.ORDR t8 WITH (NOLOCK) ON t8.DocNum = t0.DocNumSAP AND t0.TransactionType = 'DL'
                LEFT JOIN [server-sql].[${sapDb}].dbo.OSHP ship WITH (NOLOCK) ON ship.TrnspCode = t8.TrnspCode
                WHERE t0.TransactionType IN ('DL', 'REQDEL')
                AND t0.OldQty > t0.NewQty
                AND t0.DateTimeTransaction > DATEADD(HOUR, -4, GETDATE())
                ${almacenFilter}
                GROUP BY t0.DocNumSAP, t0.TransactionType
                ORDER BY MAX(t0.DateTimeTransaction) DESC
            `);

        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/pase-salida/recientes error:', err);
        res.status(500).json({ error: 'Error al obtener recientes: ' + err.message });
    }
});

// Get list of warehouses for filter dropdown
router.get('/pase-salida/almacenes', async (req, res) => {
    try {
        const pool = getPool();
        const pais = req.query.pais || 'GT';
        const sapDb = getSapDb(pais);

        const result = await pool.request().query(`
            SELECT WhsCode AS Code, WhsName AS Name
            FROM [server-sql].[${sapDb}].dbo.OWHS WITH (NOLOCK)
            WHERE Inactive = 'N'
            ORDER BY WhsCode
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/pase-salida/almacenes error:', err);
        res.status(500).json({ error: 'Error al obtener almacenes' });
    }
});

module.exports = router;
