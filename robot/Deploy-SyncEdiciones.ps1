# ============================================================
# Genera la copia desplegable del robot inyectando la config.
# Uso (PowerShell, en la carpeta robot\):
#   .\Deploy-SyncEdiciones.ps1
# Lee  SyncEdicionesCuadro.Config.env  (copia llena del .sample)
# y produce  SyncEdicionesCuadro.deploy.xaml  con los valores puestos.
# El .deploy.xaml NO debe subirse a git (lleva credenciales).
# ============================================================
param(
  [string]$Config   = "SyncEdicionesCuadro.Config.env",
  [string]$Template = "SyncEdicionesCuadro.xaml",
  [string]$Out      = "SyncEdicionesCuadro.deploy.xaml"
)

if (!(Test-Path $Config))   { Write-Error "No existe $Config (copia el .sample y llenalo)"; exit 1 }
if (!(Test-Path $Template)) { Write-Error "No existe $Template"; exit 1 }

# --- leer el .env ---
$cfg = @{}
Get-Content $Config | ForEach-Object {
  $l = $_.Trim()
  if ($l -and -not $l.StartsWith("#") -and $l.Contains("=")) {
    $k,$v = $l.Split("=",2); $cfg[$k.Trim()] = $v.Trim()
  }
}

# --- validar credenciales ---
foreach ($k in "SQL_USER","SQL_PASS","DB_USER","DB_PASS","SAP_USER","SAP_PASS") {
  if ([string]::IsNullOrWhiteSpace($cfg[$k])) { Write-Error "Falta $k en $Config"; exit 1 }
}

$entorno = ($cfg["ENTORNO"]).ToUpper()
if ($entorno -eq "QA") { $sapSrv = $cfg["SAP_SERVER_QA"]; $sapDb = $cfg["SAP_COMPANYDB_QA"] }
else                   { $entorno = "PRD"; $sapSrv = $cfg["SAP_SERVER_PRD"]; $sapDb = $cfg["SAP_COMPANYDB_PRD"] }

$xml = Get-Content $Template -Raw

# 1) credenciales (6 placeholders)
$xml = $xml.Replace("__SQL_USER__", $cfg["SQL_USER"]).Replace("__SQL_PASS__", $cfg["SQL_PASS"])
$xml = $xml.Replace("__DB_USER__",  $cfg["DB_USER"]).Replace("__DB_PASS__",  $cfg["DB_PASS"])
$xml = $xml.Replace("__SAP_USER__", $cfg["SAP_USER"]).Replace("__SAP_PASS__", $cfg["SAP_PASS"])

# 2) endpoint SAP (el template viene en PRD; si ENTORNO=QA se cambia)
$xml = $xml.Replace("server-sql.ferco.com.gt", $sapSrv)
$xml = $xml.Replace('CompanyDB = &quot;SBOFERCO&quot;', "CompanyDB = &quot;$sapDb&quot;")

# 3) outbox (por si el server/base cambian de nombre)
if ($cfg["OUTBOX_SERVER"]) { $xml = $xml.Replace("Server=SERVER-APPS-TAB;", "Server=$($cfg['OUTBOX_SERVER']);") }
if ($cfg["OUTBOX_DB"])     { $xml = $xml.Replace("Database=Picking_Management;", "Database=$($cfg['OUTBOX_DB']);") }

if ($xml -match "__[A-Z_]+__") { Write-Error "Quedaron placeholders sin reemplazar. Revisa $Config"; exit 1 }

Set-Content -Path $Out -Value $xml -Encoding UTF8
Write-Host "OK -> $Out  (ENTORNO=$entorno, SAP=$sapSrv/$sapDb)" -ForegroundColor Green
Write-Host "Abrilo/importalo en UiPath Studio o publicalo a Orchestrator." -ForegroundColor Green
