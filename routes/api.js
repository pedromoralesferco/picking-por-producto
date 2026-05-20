const express = require('express');
const { getPool, sql } = require('../db');
const router = express.Router();

// ── Rutas (agregadas desde RoutePickingManagement) ──

router.get('/rutas', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
            SELECT
                rp.RouteNumber,
                rp.RouteName,
                rp.FechaPlanificacion,
                rp.AlmacenOrigen,
                rp.Estado,
                rp.FechaInicio,
                rp.FechaFin,
                ISNULL(rpm.TotalProductos, 0) AS TotalProductos,
                ISNULL(rpm.TotalArticulos, 0) AS TotalArticulos,
                ISNULL(rpm.PesoTotal, 0) AS PesoTotal,
                ISNULL(rpm.ProductosFinalizados, 0) AS ProductosFinalizados
            FROM RoutePlan rp
            LEFT JOIN (
                SELECT RouteNumber,
                       COUNT(*) AS TotalProductos,
                       SUM(ISNULL(TotalArticulo, 0)) AS TotalArticulos,
                       SUM(ISNULL(PesoTotal, 0)) AS PesoTotal,
                       SUM(CASE WHEN Estado = 'Finalizado' THEN 1 ELSE 0 END) AS ProductosFinalizados
                FROM RoutePickingManagement
                GROUP BY RouteNumber
            ) rpm ON rpm.RouteNumber = rp.RouteNumber
            WHERE rp.Estado IN ('Pendiente', 'Iniciado')
               OR (rp.Estado = 'Finalizado' AND rp.FechaFin > DATEADD(MINUTE, -30, GETDATE()))
            ORDER BY
                CASE rp.Estado
                    WHEN 'Iniciado' THEN 0
                    WHEN 'Pendiente' THEN 1
                    WHEN 'Finalizado' THEN 2
                END,
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
                       rpm.PickerID, rpm.FechaAsignacion, rpm.FechaInicio, rpm.FechaFin,
                       p.Nombre AS PickerNombre
                FROM RoutePickingManagement rpm
                LEFT JOIN Picker p ON p.ID_Picker = rpm.PickerID
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
        await pool.request()
            .input('routeNumber', sql.Int, req.params.routeNumber)
            .query(`
                UPDATE RoutePlan
                SET Estado = 'Iniciado'
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
                       MAX(Picker_ID) AS Picker_ID,
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

// ── Asignar picker a un producto ──

router.post('/productos/asignar', async (req, res) => {
    try {
        const { routeNumber, product, pickerId } = req.body;
        const pool = getPool();
        await pool.request()
            .input('routeNumber', sql.Int, routeNumber)
            .input('product', sql.NVarChar, product)
            .input('pickerId', sql.Int, pickerId)
            .query(`
                UPDATE RoutePickingManagement
                SET PickerID = @pickerId
                WHERE RouteNumber = @routeNumber AND Product = @product
            `);
        res.json({ ok: true });
    } catch (err) {
        console.error('POST /api/productos/asignar error:', err);
        res.status(500).json({ error: 'Error al asignar picker' });
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

// ── Pickers (para modal de asignación) ──

router.get('/pickers', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
            SELECT p.ID_Picker, p.Nombre, p.ID_Centro, cd.Nombre AS CentroNombre,
                (SELECT COUNT(*) FROM RoutePickingManagement
                 WHERE PickerID = p.ID_Picker AND Estado IN ('Asignado','En Proceso')) AS Asignados,
                (SELECT COUNT(*) FROM RoutePickingManagement
                 WHERE PickerID = p.ID_Picker AND Estado = 'Finalizado') AS Completados
            FROM Picker p
            LEFT JOIN CentroDistribucion cd ON cd.ID_Centro = p.ID_Centro
            WHERE p.Activo = 1
            ORDER BY p.Nombre
        `);
        res.json(result.recordset);
    } catch (err) {
        console.error('GET /api/pickers error:', err);
        res.status(500).json({ error: 'Error interno' });
    }
});

// ── Picker view endpoints ──

router.get('/centros', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
            SELECT ID_Centro, Nombre, Pais FROM CentroDistribucion ORDER BY Pais, Nombre
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
        const result = await pool.request()
            .input('idCentro', sql.Int, req.params.id)
            .query(`
                SELECT p.ID_Picker, p.Nombre,
                    (SELECT COUNT(*) FROM RoutePickingManagement
                     WHERE PickerID = p.ID_Picker AND Estado IN ('Asignado','En Proceso')) AS ProductosPendientes,
                    (SELECT COUNT(*) FROM RoutePickingTask
                     WHERE Picker_ID = p.ID_Picker AND Estado <> 'Finalizado') AS TareasPendientes
                FROM Picker p
                WHERE p.ID_Centro = @idCentro AND p.Activo = 1
                ORDER BY p.Nombre
            `);
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
                SELECT rpm.RouteNumber,
                       MAX(rpm.RouteName) AS RouteName,
                       rpm.Product,
                       MAX(rpm.ProductName) AS ProductName,
                       MAX(rpm.TotalArticulo) AS TotalArticulo,
                       MAX(rpm.PesoTotal) AS PesoTotal,
                       MAX(rpm.Estado) AS Estado,
                       MAX(rpm.FechaAsignacion) AS FechaAsignacion
                FROM RoutePickingManagement rpm
                WHERE rpm.PickerID = @pickerId
                  AND rpm.Estado IN ('Asignado', 'En Proceso')
                GROUP BY rpm.RouteNumber, rpm.Product
                ORDER BY rpm.RouteNumber, rpm.Product
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
                    WHERE Picker_ID = @pickerId
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

module.exports = router;
