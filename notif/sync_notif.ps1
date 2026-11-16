# ====================================================================
# sync_notif.ps1 - Notificaciones a clientes: SQL Server -> Supabase
#
# Proceso independiente del app de Picking (tarea programada cada ~10 min).
# En cada corrida:
#   1) SP_NotifDetectarSAP por pais  -> OV nuevas en '03' (SAP), datos del
#      cliente y cancelaciones.
#   2) SP_NotifHitos                 -> planificado / picking / despacho
#      desde las tablas del app de Picking.
#   3) Sube a Supabase (notif.upsert_pedidos) lo que cambio, en lotes de
#      500, y lo marca como subido solo si Supabase respondio bien.
#
# Uso (en el servidor, Windows PowerShell 5.1):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\sync_notif.ps1
#   ... -DryRun       no sube nada: muestra cuantas filas subiria y un ejemplo
#   ... -Silencioso   primera corrida: lo detectado no genera WhatsApp
#   ... -Pais GT      solo un pais
#
# Configuracion: .env en esta misma carpeta (ver .env.example).
# Log: .\logs\notif_AAAAMMDD.log (se guardan 30 dias).
# ====================================================================
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$Silencioso,
    [string]$Pais
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -- Log -------------------------------------------------------------
$logDir = Join-Path $PSScriptRoot 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir ("notif_{0:yyyyMMdd}.log" -f (Get-Date))
function Log([string]$msg, [string]$nivel = 'INFO') {
    $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $nivel, $msg
    Write-Host $line
    # Si no se puede escribir el log (permisos, archivo abierto), la corrida sigue
    try { Add-Content -Path $logFile -Value $line -Encoding UTF8 -ErrorAction Stop }
    catch {
        if (-not $script:avisoLog) {
            Write-Host "AVISO: no se pudo escribir en $logFile ($($_.Exception.Message)). Correr como administrador." -ForegroundColor Yellow
            $script:avisoLog = $true
        }
    }
}
Get-ChildItem $logDir -Filter 'notif_*.log' |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } | Remove-Item -ErrorAction SilentlyContinue

# -- Una sola corrida a la vez (si la anterior sigue, esta se salta) -
$mutex = New-Object System.Threading.Mutex($false, 'Global\SACWhatsappSync')
if (-not $mutex.WaitOne(0)) { Log 'Otra corrida sigue en curso; me salto este ciclo.' 'WARN'; exit 0 }

try {
    # -- .env --------------------------------------------------------
    $envPath = Join-Path $PSScriptRoot '.env'
    if (-not (Test-Path $envPath)) { throw "No encuentro .env en $PSScriptRoot" }
    $cfg = @{}
    Get-Content $envPath -Encoding UTF8 | Where-Object { $_ -match '^\s*NOTIF_[A-Z_]+\s*=' } | ForEach-Object {
        $k, $v = $_ -split '=', 2
        # Quitar caracteres de control (p. ej. el ^V que deja pegar con Ctrl+V en la consola)
        $v = ($v -replace '[\x00-\x1F\x7F]', '').Trim()
        # Quitar comillas solo si envuelven todo el valor (una contrasena puede
        # empezar o terminar con comilla y no hay que tocarla)
        if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
            $v = $v.Substring(1, $v.Length - 2)
        }
        $cfg[$k.Trim()] = $v
    }
    foreach ($req in 'NOTIF_DB_SERVER','NOTIF_DB_NAME','NOTIF_DB_USER','NOTIF_DB_PASSWORD',
                     'NOTIF_SUPABASE_URL','NOTIF_SUPABASE_KEY','NOTIF_PAISES') {
        if (-not $cfg[$req]) { throw "Falta $req en .env" }
    }
    $k0 = $cfg['NOTIF_SUPABASE_KEY']
    if (-not ($k0.StartsWith('sb_secret_') -or $k0.StartsWith('eyJ'))) {
        throw ("NOTIF_SUPABASE_KEY no parece la llave secreta de Supabase (debe empezar con sb_secret_ o eyJ; " +
               "tiene {0} caracteres y empieza con '{1}'). Volver a pegarla en el .env." -f $k0.Length, $k0.Substring(0, [Math]::Min(4, $k0.Length)))
    }
    if ($k0.StartsWith('sb_publishable_')) { throw 'NOTIF_SUPABASE_KEY es la publishable; se necesita la secret.' }
    $soloRuta = if ($cfg['NOTIF_SOLO_RUTA'] -eq '1') { 1 } else { 0 }   # por defecto: todos los tipos de entrega

    # NOTIF_PAISES=pais:baseSAP:almacenes, varios paises separados por coma y
    # varios almacenes de un pais separados por +. Sin almacenes = todos.
    #   NOTIF_PAISES=GT:sboferco:138
    #   NOTIF_PAISES=GT:sboferco:138+01,SV:sbointergres
    $paises = @()
    foreach ($p in ($cfg['NOTIF_PAISES'] -split ',')) {
        $partes = $p.Trim() -split ':', 3
        if ($partes.Count -ge 2 -and $partes[0] -and $partes[1]) {
            $alm = if ($partes.Count -ge 3) { ($partes[2] -replace '\s', '' -replace '\+', ',').Trim(',') } else { '' }
            $paises += [pscustomobject]@{ Pais = $partes[0].Trim().ToUpper(); SapDb = $partes[1].Trim(); Almacenes = $alm }
        }
    }
    if ($Pais) { $paises = @($paises | Where-Object { $_.Pais -eq $Pais.ToUpper() }) }
    if (-not $paises) { throw "No hay paises para procesar (NOTIF_PAISES / -Pais)" }

    # -- Celulares: prefijo y primer digito de un movil por pais -----
    $tel = @{
        GT = @{ Cod = '502'; Movil = '^[345]' }
        SV = @{ Cod = '503'; Movil = '^[67]'  }
        HN = @{ Cod = '504'; Movil = '^[3789]' }
    }
    function Normalizar-Celular([string]$crudo, [string]$pais) {
        # Devuelve +CCCNNNNNNNN o $null. Toma el primer numero que parezca movil
        # (un fijo no recibe WhatsApp). Acepta "5555-1234", "+502 5555 1234",
        # "5555 1234 / 2222 3333", etc.
        if ([string]::IsNullOrWhiteSpace($crudo) -or -not $tel.ContainsKey($pais)) { return $null }
        $t = $tel[$pais]
        # Todos los digitos seguidos y se leen en bloques de 8 (saltando el
        # codigo de pais si viene delante de un numero).
        $dig = $crudo -replace '\D', ''
        $i = 0
        while ($i + 8 -le $dig.Length) {
            if ($dig.Substring($i).StartsWith($t.Cod) -and $i + 11 -le $dig.Length) {
                $d = $dig.Substring($i + 3, 8); $i += 11
            } else {
                $d = $dig.Substring($i, 8); $i += 8
            }
            if ($d -match $t.Movil) { return "+$($t.Cod)$d" }
        }
        return $null
    }

    # -- SQL ---------------------------------------------------------
    # El builder escapa ; " ' { } en la contrasena (armarla a mano rompe con esos caracteres)
    $csb = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $csb['Data Source']      = $cfg['NOTIF_DB_SERVER']
    $csb['Initial Catalog']  = $cfg['NOTIF_DB_NAME']
    $csb['User ID']          = $cfg['NOTIF_DB_USER']
    $csb['Password']         = $cfg['NOTIF_DB_PASSWORD']
    $csb['Application Name'] = 'SACWhatsappSync'
    $csb['Connect Timeout']  = 30
    $cn = New-Object System.Data.SqlClient.SqlConnection $csb.ConnectionString
    $cn.Open()

    function Exec-SP([string]$nombre, [hashtable]$params, [int]$timeout = 600) {
        $cmd = $cn.CreateCommand()
        $cmd.CommandType = [System.Data.CommandType]::StoredProcedure
        $cmd.CommandText = $nombre
        $cmd.CommandTimeout = $timeout
        foreach ($k in $params.Keys) { [void]$cmd.Parameters.AddWithValue("@$k", $params[$k]) }
        [void]$cmd.ExecuteNonQuery()
    }
    function Iso($v) {
        # DATETIME local del servidor -> ISO 8601 con zona (timestamptz en Supabase)
        if ($v -is [DBNull] -or $null -eq $v) { return $null }
        return ([DateTimeOffset]::new([datetime]$v)).ToString('yyyy-MM-ddTHH:mm:sszzz')
    }
    function Val($v) { if ($v -is [DBNull]) { $null } else { $v } }

    # -- 1) Detectar en SAP, por pais --------------------------------
    # En DryRun no se corre ningun SP: solo se muestra lo que ya esta pendiente.
    if ($DryRun) { Log '[DryRun] No se corren los SPs ni se marca nada; solo se muestra lo pendiente.' }
    foreach ($p in $paises) {
        if ($DryRun) { break }
        $t0 = Get-Date
        try {
            $alm = if ($p.Almacenes) { $p.Almacenes } else { [DBNull]::Value }
            Exec-SP 'dbo.SP_NotifDetectarSAP' @{ Pais = $p.Pais; SapDb = $p.SapDb; Almacenes = $alm; SoloRuta = $soloRuta; Silencioso = [int][bool]$Silencioso }
            $txtAlm = if ($p.Almacenes) { $p.Almacenes } else { 'todos' }
            Log ("Detectar {0} ({1}, almacenes {2}) OK en {3:n0}s" -f $p.Pais, $p.SapDb, $txtAlm, ((Get-Date) - $t0).TotalSeconds)
        } catch {
            Log ("Detectar {0} fallo: {1}" -f $p.Pais, $_.Exception.Message) 'ERROR'
        }
    }

    # -- 2) Hitos desde el app de Picking ----------------------------
    if (-not $DryRun) {
        $t0 = Get-Date
        Exec-SP 'dbo.SP_NotifHitos' @{}
        Log ("Hitos OK en {0:n0}s" -f ((Get-Date) - $t0).TotalSeconds)
    }

    # -- 3) Subir a Supabase lo pendiente ----------------------------
    $listaPaises = ($paises | ForEach-Object { "'" + ($_.Pais -replace "'", '') + "'" }) -join ','
    $url = $cfg['NOTIF_SUPABASE_URL'].TrimEnd('/') + '/rest/v1/rpc/upsert_pedidos'
    $key = $cfg['NOTIF_SUPABASE_KEY']
    $headers = @{ apikey = $key; 'Content-Profile' = 'notif'; Prefer = 'return=representation' }
    if ($key.StartsWith('eyJ')) { $headers['Authorization'] = "Bearer $key" }   # llave legacy (JWT)

    # Lotes de 500: se sube un lote, se marca, y se lee el siguiente hasta que
    # no quede nada (501 pendientes = un lote de 500 y otro de 1). Tope de 20
    # lotes (10,000 filas) por corrida; lo que pase de eso sale en la siguiente.
    $totalSubidas = 0; $sinCelular = 0
    for ($lote = 1; $lote -le 20; $lote++) {
        $cmd = $cn.CreateCommand()
        $cmd.CommandTimeout = 120
        $cmd.CommandText = @"
SELECT TOP 500 Pais, DocType, DocNum, ClienteNombre, Celular, VendedorNombre, VendedorEmail, Direccion, FechaEntrega, Almacen,
       CuadroActual, Placa, FechaRecibido, FechaPlanificado, FechaPickingInicio, FechaPickingFin,
       FechaDespacho, FechaCancelado, Silencioso, HashActual
FROM dbo.NotifPedido
WHERE Pais IN ($listaPaises) AND (HashSync IS NULL OR HashSync <> HashActual)
ORDER BY FechaRecibido
"@
        $dt = New-Object System.Data.DataTable
        (New-Object System.Data.SqlClient.SqlDataAdapter $cmd).Fill($dt) | Out-Null
        if ($dt.Rows.Count -eq 0) { break }

        $filas = @(foreach ($r in $dt.Rows) {
            $cel = Normalizar-Celular ([string](Val $r.Celular)) $r.Pais
            if (-not $cel) { $sinCelular++ }
            [ordered]@{
                pais                 = $r.Pais
                doc_type             = $r.DocType
                doc_num              = [int]$r.DocNum
                cliente_nombre       = Val $r.ClienteNombre
                celular_original     = Val $r.Celular
                celular_e164         = $cel
                notificable          = [bool]$cel
                vendedor_nombre      = Val $r.VendedorNombre
                vendedor_email       = Val $r.VendedorEmail
                direccion            = Val $r.Direccion
                fecha_entrega        = if ($r.FechaEntrega -is [DBNull]) { $null } else { ([datetime]$r.FechaEntrega).ToString('yyyy-MM-dd') }
                centro               = Val $r.Almacen      # codigo de almacen SAP, ej. '138'
                cuadro_actual        = Val $r.CuadroActual
                placa                = Val $r.Placa
                fecha_recibido       = Iso $r.FechaRecibido
                fecha_planificado    = Iso $r.FechaPlanificado
                fecha_picking_inicio = Iso $r.FechaPickingInicio
                fecha_picking_fin    = Iso $r.FechaPickingFin
                fecha_despacho       = Iso $r.FechaDespacho
                fecha_cancelado      = Iso $r.FechaCancelado
                silencioso           = [bool]$r.Silencioso
            }
        })
        $json = ConvertTo-Json -InputObject @{ filas = $filas; silencioso = [bool]$Silencioso } -Depth 5 -Compress

        if ($DryRun) {
            Log ("[DryRun] Lote {0}: subiria {1} filas. Ejemplo: {2}" -f $lote, $dt.Rows.Count,
                 (ConvertTo-Json -InputObject $filas[0] -Compress))
            break   # en DryRun no se marca nada, asi que no se avanza de lote
        }

        try {
            $bytes = [Text.Encoding]::UTF8.GetBytes($json)
            $resp = Invoke-RestMethod -Method Post -Uri $url -Headers $headers -Body $bytes `
                        -ContentType 'application/json; charset=utf-8' -TimeoutSec 120
        } catch {
            $detalle = $_.ErrorDetails.Message
            Log ("Supabase rechazo el lote {0}: {1} {2}" -f $lote, $_.Exception.Message, $detalle) 'ERROR'
            break   # no se marca nada: se reintenta en la proxima corrida
        }

        # Marcar como subido con el hash que se leyo (si la fila cambio mientras
        # tanto, su HashActual ya es otro y vuelve a subir en la proxima corrida).
        $tx = $cn.BeginTransaction()
        try {
            $up = $cn.CreateCommand()
            $up.Transaction = $tx
            $up.CommandText = 'UPDATE dbo.NotifPedido SET HashSync=@h, FechaSync=GETDATE(), Silencioso=0 WHERE Pais=@p AND DocType=@t AND DocNum=@n'
            [void]$up.Parameters.Add('@h', [System.Data.SqlDbType]::Int)
            [void]$up.Parameters.Add('@p', [System.Data.SqlDbType]::NVarChar, 10)
            [void]$up.Parameters.Add('@t', [System.Data.SqlDbType]::NVarChar, 10)
            [void]$up.Parameters.Add('@n', [System.Data.SqlDbType]::Int)
            foreach ($r in $dt.Rows) {
                $up.Parameters['@h'].Value = $r.HashActual
                $up.Parameters['@p'].Value = $r.Pais
                $up.Parameters['@t'].Value = $r.DocType
                $up.Parameters['@n'].Value = $r.DocNum
                [void]$up.ExecuteNonQuery()
            }
            $tx.Commit()
        } catch { $tx.Rollback(); throw }

        $totalSubidas += $dt.Rows.Count
        Log ("Lote {0}: {1} filas subidas (Supabase proceso {2})" -f $lote, $dt.Rows.Count, $resp)
        if ($dt.Rows.Count -lt 500) { break }
    }

    Log ("Fin. Subidas: {0}. Sin celular valido (no se les escribe): {1}." -f $totalSubidas, $sinCelular)
    $cn.Close()
}
catch {
    Log ("Corrida abortada: {0}" -f $_.Exception.Message) 'ERROR'
    exit 1
}
finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
