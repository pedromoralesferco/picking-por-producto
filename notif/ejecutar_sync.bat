@echo off
REM ejecutar_sync.bat - corre el sync de notificaciones una vez, a mano.
REM Clic derecho -> "Ejecutar como administrador" (el .env solo lo leen
REM Administradores y SYSTEM).
REM Se le pueden pasar las mismas opciones del script, por ejemplo:
REM   ejecutar_sync.bat -Silencioso
REM   ejecutar_sync.bat -DryRun
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0sync_notif.ps1" %*
echo.
echo Codigo de salida: %ERRORLEVEL%  (0 = OK). Log en %~dp0logs\
pause
