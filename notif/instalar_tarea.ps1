# instalar_tarea.ps1 - registra la tarea programada "Ferco\NotifSync" (cada 10 min).
# Correr UNA vez, como administrador, desde la carpeta donde quedo sync_notif.ps1:
#   powershell -ExecutionPolicy Bypass -File .\instalar_tarea.ps1
# Para quitarla:  Unregister-ScheduledTask -TaskName NotifSync -TaskPath \Ferco\ -Confirm:$false
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'sync_notif.ps1'
if (-not (Test-Path $script)) { throw "No encuentro $script" }
if (-not (Test-Path (Join-Path $PSScriptRoot '.env'))) { throw "Falta el .env en $PSScriptRoot (copiar .env.example)" }

$accion = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`"" -WorkingDirectory $PSScriptRoot
$disparador = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
$ajustes = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
# SYSTEM: corre aunque nadie tenga sesion abierta. Se autentica en SQL con el usuario del .env.
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName 'NotifSync' -TaskPath '\Ferco\' -Action $accion -Trigger $disparador `
    -Settings $ajustes -Principal $principal -Description 'Notificaciones a clientes: SQL Server -> Supabase (cada 10 min)' -Force
Write-Host 'Tarea \Ferco\NotifSync registrada. Log en .\logs\' -ForegroundColor Green
