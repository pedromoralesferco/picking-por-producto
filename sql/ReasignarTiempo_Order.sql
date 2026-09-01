-- ============================================================
-- Tiempo real por tarea con trabajo SECUENCIAL (modo pedido: SV/HN/GT-138)
--
-- Problema: cuando a un picker se le asignan varios pedidos a la vez,
-- todos quedan con la misma FechaAsignacion, pero se trabajan uno tras
-- otro. Eso infla el tiempo "asignación -> fin" de los posteriores.
--
-- Solución: cada vez que un pedido del picker se FINALIZA, se reinicia
-- FechaAsignacion = GETDATE() en los demás pedidos AÚN pendientes del
-- MISMO operario. Así cada pedido mide desde que realmente empezó
-- (cuando terminó el anterior).
--
-- No afecta el ciclo de ruta (se mide a nivel cabecera FechaInicio/FechaFin).
-- ============================================================
CREATE OR ALTER TRIGGER dbo.TR_OrderPickingMgmt_ReasignarTiempo
ON dbo.OrderPickingManagement
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF UPDATE(Estado)
    BEGIN
        UPDATE opm
        SET opm.FechaAsignacion = GETDATE()
        FROM dbo.OrderPickingManagement opm
        WHERE opm.Estado <> 'Finalizado'          -- solo los que siguen pendientes
          AND opm.ID_Operario IS NOT NULL
          AND EXISTS (
                SELECT 1 FROM inserted i
                WHERE i.Estado = 'Finalizado'                  -- un pedido que acaba de terminar
                  AND i.ID_Operario = opm.ID_Operario          -- del mismo operario
                  AND i.ID_OrderPicking <> opm.ID_OrderPicking -- distinto pedido
          );
    END
END;
GO
