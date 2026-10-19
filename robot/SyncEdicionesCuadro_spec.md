# Robot UiPath — SyncEdicionesCuadro (Fase 3: ediciones del cuadro → SAP)

Un solo `.xaml`. Barre el outbox del app, aplica en SAP por DI-API y marca el resultado.
Arranca solo con **PLACA**; REMOVE/ADD se agregan como ramas del Switch después.

## Flujo (actividades)
1. **Database Connect** → SQL Server `SERVER-APPS-TAB`, base `Picking_Management`.
   (El outbox vive acá; el linked server `[server-sql]` alcanza SAP para el DocEntry.)
2. **Invoke Code "Conectarse"** → DI-API (reusar el bloque PRD de `PAG_OVPrepaHN/Main.xaml`:
   `ocompany.Connect()`, Server `server-sql.ferco.com.gt`, CompanyDB `SBOFERCO`).
   *(Para pruebas usar el bloque QA: `SBOFERCO_SANDBOX` @ `SANDOBOX-SAP`.)*
3. **Execute Query** → `dtPend` (ver SQL #1). Filtrar `Accion='PLACA'` en el rollout inicial.
4. **For Each Row** `row` en `dtPend.Rows`:
   - **Switch** por `row("Accion").ToString()`:
     - **"PLACA"** → *Invoke Code "Aplicar PLACA"* (ver C# abajo) con sus argumentos.
   - **If** `strOutCode = "SUCCESS"` → *Execute NonQuery* SQL #2a (confirmado)
     **Else** → *Execute NonQuery* SQL #2b (error).
5. **Invoke Code "Desconectarse"** → `ocompany.Disconnect();`
6. **Database Disconnect.**

## Argumentos del Invoke Code "Aplicar PLACA" (Language = CSharp)
| Dirección | Nombre | Tipo | Valor |
|---|---|---|---|
| In/Out | `ocompany` | `SAPbobsCOM.Company` | `ocompany` |
| In | `DocEntry` | `Int32` | `Convert.ToInt32(row("CuadroDocEntry"))` |
| In | `Placa` | `String` | `row("Placa").ToString()` |
| In | `IDCamion` | `String` | `row("IDCamion").ToString()` |
| In | `Capacidad` | `String` | `row("Capacidad").ToString()` |
| In | `CardCode` | `String` | `row("CardCode").ToString()` |
| Out | `strOutCode` | `String` | `strOutCode` |
| Out | `strErrMsg` | `String` | `strErrMsg` |

### C# del Invoke Code "Aplicar PLACA"
```csharp
try {
    SAPbobsCOM.CompanyService cs = ocompany.GetCompanyService();
    SAPbobsCOM.GeneralService gs = cs.GetGeneralService("Cuadro_ruta");
    SAPbobsCOM.GeneralDataParams prm =
        (SAPbobsCOM.GeneralDataParams)gs.GetDataInterface(SAPbobsCOM.GeneralServiceDataInterfaces.gsGeneralDataParams);
    prm.SetProperty("DocEntry", DocEntry);
    SAPbobsCOM.GeneralData gd = gs.GetByParams(prm);
    if (gd == null) {
        strOutCode = "ERROR"; strErrMsg = "Cuadro no encontrado (DocEntry " + DocEntry + ")";
    } else {
        // SAP gana: si ya hay placa en SAP, NO pisar (idempotente).
        string placaActual = Convert.ToString(gd.GetProperty("U_Placa"));
        if (!string.IsNullOrEmpty(placaActual) && placaActual.Trim() != "") {
            strOutCode = "SUCCESS"; strErrMsg = "SAP ya tenia placa (" + placaActual + ")";
        } else {
            gd.SetProperty("U_Placa", Placa);
            if (!string.IsNullOrEmpty(IDCamion)) gd.SetProperty("U_ID_Camion", IDCamion);
            if (!string.IsNullOrEmpty(CardCode)) gd.SetProperty("U_CardCode", CardCode);
            // U_Capacidad: si el UDF es numérico, usar la rama Double; si es alfanumérico, la String.
            double capNum;
            if (double.TryParse(Capacidad, out capNum)) gd.SetProperty("U_Capacidad", capNum);
            else if (!string.IsNullOrEmpty(Capacidad)) gd.SetProperty("U_Capacidad", Capacidad);
            gs.Update(gd);                 // guarda el UDO
            strOutCode = "SUCCESS"; strErrMsg = "";
        }
    }
} catch (Exception ex) {
    strOutCode = "ERROR"; strErrMsg = "Catch: " + ex.Message;
}
```
> Namespaces: agregar `Interop.SAPbobsCOM` en Imports (igual que Main.xaml). `GetCompanyService/GetGeneralService` son estándar de DI-API 9.3.

## SQL
**#1 — leer pendientes** (Execute Query → `dtPend`):
```sql
SELECT ID_Edicion, RouteNumber, CuadroDocEntry, Accion,
       Placa, Capacidad, IDCamion, Transportista, CardCode
FROM dbo.vw_CuadroEdicionPendiente
WHERE Accion = 'PLACA' AND CuadroDocEntry IS NOT NULL
ORDER BY ID_Edicion;
```
**#2a — marcar confirmado** (Execute NonQuery; parámetro `@id = row("ID_Edicion")`):
```sql
UPDATE dbo.CuadroEdicionCola SET Estado='confirmado', FechaSync=GETDATE() WHERE ID_Edicion=@id;
```
**#2b — marcar error** (`@id`, `@msg = strErrMsg`):
```sql
UPDATE dbo.CuadroEdicionCola SET Estado='error', Error=@msg, Intentos=Intentos+1 WHERE ID_Edicion=@id;
```

El reconciliador del app (cada 60s, `SP_ReconcileCuadroEdiciones`) ve `confirmado`, limpia `PlacaPendienteSync` y cierra la fila (`cerrado`). No hay que tocar nada más del lado app.

## Disparo
Job agendado en Orchestrator cada X min (como `start_import_rutas`), o cola por trigger. Para
PLACA basta cada pocos minutos (el flete se calcula hasta la liquidación, no urge).

## Siguientes ramas (después de PLACA)
- **REMOVE**: en el Switch, abrir el UDO por DocEntry, localizar en `@CUADRO_RUTA_D` la fila con
  `U_No_OV = row("OV_Number")` y `U_Tipo_Documento = row("DocType")`, eliminarla del `GeneralDataCollection` de líneas, `gs.Update(gd)`.
- **ADD**: agregar una línea nueva al collection con los datos del doc.
- **CREATE complemento**: reusar el robot que ya crea cuadros; luego remapear el RouteNumber
  provisional (negativo) al DocNum real.
