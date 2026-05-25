const express = require('express');
const { getPool, sql } = require('../db');
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
*/

// ── Carriles ──

router.get('/carriles', async (req, res) => {
    try {
        const pool = getPool();
        const centro = req.query.centro;
        let query = `SELECT ID_Carril, Nombre, ID_Centro FROM Carril WHERE Activo = 1`;
        const request = pool.request();
        if (centro) {
            query += ` AND ID_Centro = @centro`;
            request.input('centro', sql.Int, centro);
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
        const result = await pool.request().query(`
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
            WHERE rp.Estado IN ('Pendiente', 'Iniciado')
               OR (rp.Estado = 'Finalizado' AND rp.FechaFin > DATEADD(MINUTE, -30, GETDATE()))
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
        const { idCarril } = req.body || {};
        const request = pool.request()
            .input('routeNumber', sql.Int, req.params.routeNumber);

        let setClause = `Estado = 'Iniciado', FechaInicio = GETDATE()`;
        if (idCarril) {
            request.input('idCarril', sql.Int, idCarril);
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

// ── Pickers (para modal de asignación) ──

router.get('/pickers', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
            SELECT p.ID_Picker, p.Nombre, p.ID_Centro, cd.Nombre AS CentroNombre,
                (SELECT COUNT(*) FROM RoutePickingManagement
                 WHERE PickerID = p.ID_Picker AND Estado IN ('Asignado','En Proceso')) AS Asignados,
                (SELECT COUNT(*) FROM RoutePickingManagement
                 WHERE PickerID = p.ID_Picker AND Estado = 'Finalizado'
                   AND CAST(FechaFin AS DATE) = CAST(GETDATE() AS DATE)) AS CompletadosHoy
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
                ;WITH UniqueTasks AS (
                    SELECT Route_Number, OV_Number, DocType, InternIdProduct,
                           MAX(Descripcion) AS Descripcion,
                           MAX(Cantidad) AS Cantidad,
                           MAX(CantidadPendiente) AS CantidadPendiente,
                           MAX(UnitWeight) AS UnitWeight,
                           MAX(Estado) AS Estado,
                           MAX(UltimaActualizacion) AS UltimaActualizacion
                    FROM RoutePickingTask
                    WHERE Picker_ID = @pickerId
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

// ── Priorización de Rutas ──

router.get('/priorizacion/rutas', async (req, res) => {
    try {
        const pool = getPool();
        const result = await pool.request().query(`
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
        const result = await pool.request().query(`
            SELECT
                rp.RouteNumber,
                rp.RouteName,
                rp.Estado,
                rp.EstadoDespacho,
                rp.ID_Carril,
                c.Nombre AS CarrilNombre,
                c.ID_Centro,
                ISNULL(rp.PesoEstimado, 0) AS PesoEstimado
            FROM RoutePlan rp
            LEFT JOIN Carril c ON c.ID_Carril = rp.ID_Carril
            WHERE rp.Estado IN ('Iniciado', 'Finalizado')
              AND rp.EstadoDespacho IN ('Pendiente', 'Listo para Carga')
              AND rp.ID_Carril IS NOT NULL
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

module.exports = router;
