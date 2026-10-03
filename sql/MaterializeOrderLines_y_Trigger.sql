-- ============================================================
-- Flujo "documentos desde la ingesta" (HUB Escuintla / order)
--
-- 1) SP_MaterializeOrderLinesEscuintla: materializa OPM+tareas (Pendiente)
--    de los cuadros GT/Escuintla Pendientes que aún no las tienen, usando
--    reimport (@EmitResult=0). Se llama al final de SP_DetectaNuevasOrdenRutas.
--    TRY/CATCH por cuadro: uno con problema no aborta el resto; se reintenta
--    en el próximo ciclo.
-- 2) Trigger TR_OrderRoutePlan_EstadosFechas: al Iniciar un cuadro GT ya NO
--    crea líneas desde cero (SP_AddOrderRouteTasks) sino que RE-IMPORTA
--    (reconcilia: agrega nuevas, quita eliminadas, preserva progreso). El
--    candado (línea sin match en Lisa / cuadro vacío) sigue abortando el
--    Iniciar porque reimport hace ROLLBACK + RAISERROR. SV/HN sin cambios.
-- ============================================================

IF OBJECT_ID('dbo.SP_MaterializeOrderLinesEscuintla') IS NOT NULL
    DROP PROCEDURE dbo.SP_MaterializeOrderLinesEscuintla;
GO
CREATE PROCEDURE [dbo].[SP_MaterializeOrderLinesEscuintla]
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT orp.ID_RoutePlan
        FROM dbo.OrderRoutePlan orp
        WHERE orp.ID_Centro = 3 AND orp.Pais = 'GT' AND orp.Estado = 'Pendiente'
          AND NOT EXISTS (SELECT 1 FROM dbo.OrderPickingManagement o WHERE o.ID_RoutePlan = orp.ID_RoutePlan);
    OPEN cur;
    FETCH NEXT FROM cur INTO @id;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC dbo.SP_ReimportOrderRouteLines @ID_RoutePlan = @id, @EmitResult = 0;
        END TRY
        BEGIN CATCH
            -- Cuadro con problema (vacío / línea sin match en Lisa): se salta,
            -- se reintenta en el próximo ciclo. No aborta la materialización.
        END CATCH
        FETCH NEXT FROM cur INTO @id;
    END
    CLOSE cur;
    DEALLOCATE cur;
END;
GO

IF OBJECT_ID('dbo.TR_OrderRoutePlan_EstadosFechas') IS NOT NULL
    DROP TRIGGER dbo.TR_OrderRoutePlan_EstadosFechas;
GO
CREATE TRIGGER dbo.TR_OrderRoutePlan_EstadosFechas
ON dbo.OrderRoutePlan
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Estado → Iniciado: marcar FechaInicio
    UPDATE orp
    SET FechaInicio = GETDATE()
    FROM dbo.OrderRoutePlan orp
    INNER JOIN inserted i ON orp.ID_RoutePlan = i.ID_RoutePlan
    INNER JOIN deleted d  ON orp.ID_RoutePlan = d.ID_RoutePlan
    WHERE i.Estado = 'Iniciado'
      AND (d.Estado IS NULL OR d.Estado <> 'Iniciado')
      AND orp.FechaInicio IS NULL;

    -- Estado → Iniciado: reconciliar líneas por cada ruta.
    --   GT/Escuintla: RE-IMPORTAR (agrega/quita/preserva; candado vía ROLLBACK+RAISERROR).
    --   SV/HN: comportamiento anterior (crear con SP_AddOrderRouteTasks).
    DECLARE @ID_RoutePlan INT, @RouteNumber INT, @ID_Centro INT, @Pais NVARCHAR(10);

    DECLARE curRoute CURSOR LOCAL FAST_FORWARD FOR
        SELECT i.ID_RoutePlan, i.RouteNumber, i.ID_Centro, i.Pais
        FROM inserted i
        INNER JOIN deleted d ON i.ID_RoutePlan = d.ID_RoutePlan
        WHERE i.Estado = 'Iniciado'
          AND (d.Estado IS NULL OR d.Estado <> 'Iniciado');

    OPEN curRoute;
    FETCH NEXT FROM curRoute INTO @ID_RoutePlan, @RouteNumber, @ID_Centro, @Pais;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @Pais = 'GT'
            EXEC dbo.SP_ReimportOrderRouteLines @ID_RoutePlan = @ID_RoutePlan, @EmitResult = 0;
        ELSE
            EXEC dbo.SP_AddOrderRouteTasks @ID_RoutePlan, @RouteNumber, @ID_Centro, @Pais;
        FETCH NEXT FROM curRoute INTO @ID_RoutePlan, @RouteNumber, @ID_Centro, @Pais;
    END

    CLOSE curRoute;
    DEALLOCATE curRoute;

    -- Estado → Finalizado: marcar FechaFin
    UPDATE orp
    SET FechaFin = GETDATE()
    FROM dbo.OrderRoutePlan orp
    INNER JOIN inserted i ON orp.ID_RoutePlan = i.ID_RoutePlan
    INNER JOIN deleted d  ON orp.ID_RoutePlan = d.ID_RoutePlan
    WHERE i.Estado = 'Finalizado'
      AND (d.Estado IS NULL OR d.Estado <> 'Finalizado')
      AND orp.FechaFin IS NULL;
END;
GO
