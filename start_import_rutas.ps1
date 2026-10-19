# start_import_rutas.ps1
# Dispara el robot de UiPath "Planificacion_SAP Z5 Locales" (importacion de rutas: staging -> cuadros SAP).
# Lee las credenciales UIPATH_* del archivo .env que esta en la misma carpeta.
# Correr (local, Windows):  powershell -ExecutionPolicy Bypass -File .\start_import_rutas.ps1
$ErrorActionPreference = "Stop"

# --- cargar .env ---
$envPath = Join-Path $PSScriptRoot ".env"
if (-not (Test-Path $envPath)) { throw "No encuentro .env en $PSScriptRoot" }
$cfg = @{}
Get-Content $envPath | Where-Object { $_ -match '^\s*UIPATH_' } | ForEach-Object {
    $parts = $_ -split '=', 2
    $cfg[$parts[0].Trim()] = $parts[1].Trim()
}

# UA de navegador para pasar el filtro Cloudflare de UiPath Cloud
$UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- 1) token OAuth (client_credentials) ---
$body = @{
    grant_type    = "client_credentials"
    client_id     = $cfg["UIPATH_CLIENT_ID"]
    client_secret = $cfg["UIPATH_CLIENT_SECRET"]
    scope         = "OR.Jobs"
}
$tok = Invoke-RestMethod -Method Post -Uri $cfg["UIPATH_TOKEN_URL"] `
        -Body $body -ContentType "application/x-www-form-urlencoded" -UserAgent $UA
Write-Host "Token OK (expira en $($tok.expires_in)s, scopes: $($tok.scope))" -ForegroundColor Green

# --- 2) disparar el trigger de importacion de rutas ---
$headers = @{ Authorization = "Bearer $($tok.access_token)" }
$resp = Invoke-RestMethod -Method Post -Uri $cfg["UIPATH_IMPORT_RUTAS_TRIGGER"] `
        -Headers $headers -ContentType "application/json" -Body "{}" -UserAgent $UA
Write-Host "Robot de importacion de rutas disparado:" -ForegroundColor Green
$resp | ConvertTo-Json -Depth 6
