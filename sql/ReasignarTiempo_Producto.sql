-- ============================================================
-- Tiempo real por tarea con trabajo SECUENCIAL — MODO PRODUCTO (Zona 5)
-- Análogo a TR_OrderPickingMgmt_ReasignarTiempo pero sobre
-- RoutePickingManagement (grano: RouteNumber + Product).
--
-- Al finalizar un producto, reinicia FechaAsignacion = GETDATE() en los
-- demás productos aún pendientes del MISMO operario, para reflejar el
-- trabajo secuencial y medir el tiempo real por tarea.
-- No afecta el ciclo de ruta (cabecera).
-- ============================================================
CREATE OR ALTER TRIGGER dbo.TR_RoutePickingMgmt_ReasignarTiempo
ON dbo.RoutePickingManagement
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF UPDATE(Estado)
    BEGIN
        UPDATE rpm
        SET rpm.FechaAsignacion = GETDATE()
        FROM dbo.RoutePickingManagement rpm
        WHERE rpm.Estado <> 'Finalizado'          -- solo los que siguen pendientes
          AND rpm.ID_Operario IS NOT NULL
          AND EXISTS (
                SELECT 1 FROM inserted i
                WHERE i.Estado = 'Finalizado'                     -- un producto recién terminado
                  AND i.ID_Operario = rpm.ID_Operario             -- mismo operario
                  AND NOT (i.RouteNumber = rpm.RouteNumber
                           AND i.Product = rpm.Product)           -- distinto producto
          );
    END
END;
GO
