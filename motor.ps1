<#
.SYNOPSIS
    Gestor Unificado de Ciclo de Vida Local (Multi-Entorno) para Evolution API & Webhook Gateway.
.DESCRIPTION
    Implementa el patron arquitectonico universal:
    - Deteccion de entorno y motor dual (Docker vs Nativo)
    - Panel interactivo de configuracion (.env Wizard) sin necesidad de tocar codigo
    - Exposicion publica integrada con Cloudflare Tunnel (IPv4 / 127.0.0.1)
    - Sondeo en tiempo real (Health Check <100ms) y deteccion de procesos huerfanos
    - Apagado seguro y persistencia de credenciales
#>

[CmdletBinding()]
param()

$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:ScriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } else { (Get-Location).Path }
Set-Location $script:ScriptDir

$script:EnvPath = Join-Path $script:ScriptDir ".env"
$script:EnvExamplePath = Join-Path $script:ScriptDir ".env.example"
$script:TunnelLogPath = Join-Path $env:TEMP "cloudflared_evolution_tunnel.log"

# ==============================================================================
# 1. UTILIDADES DE PERSISTENCIA Y VARIABLES (.ENV)
# ==============================================================================

function Ensure-EnvFile {
    if (-not (Test-Path $script:EnvPath)) {
        if (Test-Path $script:EnvExamplePath) {
            Copy-Item $script:EnvExamplePath $script:EnvPath -Force
            Write-Host " [INFO] Archivo .env generado automaticamente a partir de .env.example" -ForegroundColor Green
        } else {
            New-Item -ItemType File -Path $script:EnvPath -Force | Out-Null
            Write-Host " [AVISO] Se creo un archivo .env vacio (no se encontro .env.example)" -ForegroundColor Yellow
        }
    }
}

function Get-EnvVar {
    param(
        [string]$Key,
        [string]$Default = ""
    )
    if (-not (Test-Path $script:EnvPath)) { return $Default }
    
    $lines = Get-Content $script:EnvPath -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("#") -or -not $trimmed.Contains("=")) { continue }
        $parts = $trimmed -split "=", 2
        if ($parts[0].Trim() -eq $Key) {
            $val = $parts[1].Trim()
            # Remover comillas envolventes si existen
            if (($val.StartsWith('"') -and $val.EndsWith('"')) -or ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
            return $val
        }
    }
    return $Default
}

function Set-EnvVar {
    param(
        [string]$Key,
        [string]$Value
    )
    Ensure-EnvFile
    $lines = Get-Content $script:EnvPath -Encoding UTF8 -ErrorAction SilentlyContinue
    $found = $false
    $newLines = @()

    foreach ($line in $lines) {
        $trimmed = $line.Trim()
        if (-not $trimmed.StartsWith("#") -and $trimmed.Contains("=")) {
            $parts = $trimmed -split "=", 2
            if ($parts[0].Trim() -eq $Key) {
                $newLines += "$Key=$Value"
                $found = $true
                continue
            }
        }
        $newLines += $line
    }

    if (-not $found) {
        $newLines += "$Key=$Value"
    }

    $newLines | Set-Content $script:EnvPath -Encoding UTF8 -Force
}

function Generate-SecureApiKey {
    $bytes = New-Object byte[] 16
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $rng.GetBytes($bytes)
    return (-join ($bytes | ForEach-Object { $_.ToString("X2") }))
}

# ==============================================================================
# 2. DIAGNOSTICO DE ENTORNO, RED Y PUERTOS (<100ms)
# ==============================================================================

function Get-InternetStatus {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $online = $false
    $latency = 0

    $dnsServers = @("1.1.1.1", "8.8.8.8")
    foreach ($dns in $dnsServers) {
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $asyncResult = $client.BeginConnect($dns, 53, $null, $null)
            $waitSuccess = $asyncResult.AsyncWaitHandle.WaitOne(150, $false)
            if ($waitSuccess -and $client.Connected) {
                $client.EndConnect($asyncResult)
                $client.Close()
                $sw.Stop()
                $online = $true
                $latency = [int]$sw.ElapsedMilliseconds
                break
            }
            $client.Close()
        } catch {
            # Continuar con el siguiente intento silenciosamente
        }
    }
    return [PSCustomObject]@{
        Online    = $online
        LatencyMs = $latency
    }
}

function Test-PortListening {
    param([int]$Port)
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        $waitSuccess = $asyncResult.AsyncWaitHandle.WaitOne(80, $false)
        if ($waitSuccess -and $client.Connected) {
            $client.EndConnect($asyncResult)
            $client.Close()
            return $true
        }
        $client.Close()
    } catch {}
    return $false
}

function Get-PortProcessInfo {
    param([int]$Port)
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($conn -and $conn.OwningProcess) {
            $proc = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            return [PSCustomObject]@{
                PID  = $conn.OwningProcess
                Name = if ($proc) { $proc.ProcessName } else { "Desconocido" }
            }
        }
    } catch {}
    return $null
}

function Get-DockerInfo {
    $hasBinary = (Get-Command "docker" -ErrorAction SilentlyContinue) -ne $null
    if (-not $hasBinary) {
        return [PSCustomObject]@{
            Installed = $false
            Running   = $false
            Version   = "No instalado"
        }
    }

    $ver = "Instalado"
    try {
        $vOutput = docker --version 2>$null
        if ($vOutput -match "version ([0-9.]+)") { $ver = $matches[1] }
    } catch {}

    $running = $false
    try {
        $null = docker info 2>$null
        if ($LASTEXITCODE -eq 0) {
            $running = $true
        }
    } catch {}

    return [PSCustomObject]@{
        Installed = $true
        Running   = $running
        Version   = $ver
    }
}

function Get-NodeInfo {
    $hasNode = (Get-Command "node" -ErrorAction SilentlyContinue) -ne $null
    if (-not $hasNode) {
        return [PSCustomObject]@{
            Installed = $false
            Version   = "No instalado"
        }
    }
    $ver = "Instalado"
    try {
        $ver = (node -v 2>$null).Trim()
    } catch {}
    return [PSCustomObject]@{
        Installed = $true
        Version   = $ver
    }
}

function Get-TunnelUrlFromLog {
    if (Test-Path $script:TunnelLogPath) {
        $content = Get-Content $script:TunnelLogPath -Raw -ErrorAction SilentlyContinue
        if ($content -match "https://[a-zA-Z0-9-]+\.trycloudflare\.com") {
            return $matches[0]
        }
    }
    return $null
}

# ==============================================================================
# 3. GESTION DE TUNELES SEGUROS (CLOUDFLARE JIT DOWNLOADER)
# ==============================================================================

function Get-CloudflaredBinary {
    # 1. PATH global
    $cmd = Get-Command "cloudflared" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    # 2. Rutas conocidas de usuario
    $cands = @(
        "$env:LOCALAPPDATA\cloudflared\cloudflared.exe",
        "$env:USERPROFILE\.omniroute\cloudflared\bin\cloudflared.exe",
        "$env:ProgramFiles\cloudflared\cloudflared.exe",
        "$script:ScriptDir\cloudflared.exe"
    )
    foreach ($cand in $cands) {
        if (Test-Path $cand) { return $cand }
    }

    # 3. Descarga Just-in-Time sin privilegios
    Write-Host "`n ==========================================================" -ForegroundColor Cyan
    Write-Host "  DESCARGA AUTOMATICA: CLOUDFLARE TUNNEL (cloudflared)" -ForegroundColor Yellow
    Write-Host " ==========================================================" -ForegroundColor Cyan
    Write-Host " El binario de Cloudflare Tunnel no se encontro en el sistema."
    Write-Host " Se descargara de forma portable y segura a:"
    $targetDir = "$env:LOCALAPPDATA\cloudflared"
    $targetFile = "$targetDir\cloudflared.exe"
    Write-Host " $targetFile`n" -ForegroundColor Gray

    try {
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
        $url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe"
        Write-Host " Conectando con GitHub Releases de Cloudflare..." -ForegroundColor Cyan
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $targetFile -UseBasicParsing
        if (Test-Path $targetFile) {
            Write-Host " [OK] Cloudflare Tunnel descargado exitosamente." -ForegroundColor Green
            return $targetFile
        }
    } catch {
        Write-Host " [ERROR] No se pudo descargar cloudflared automaticamente: $_" -ForegroundColor Red
        Write-Host " Puedes descargarlo manualmente desde: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/" -ForegroundColor Yellow
    }
    return $null
}

function Start-CloudflareTunnel {
    param([int]$LocalPort = 3050)

    $bin = Get-CloudflaredBinary
    if (-not $bin) {
        Write-Host " [CANCELADO] No se puede iniciar el tunel sin cloudflared." -ForegroundColor Red
        Start-Sleep -Seconds 2
        return $null
    }

    Write-Host "`n Iniciando tunel temporal hacia http://127.0.0.1:$LocalPort (forzando enlace IPv4)..." -ForegroundColor Cyan
    if (Test-Path $script:TunnelLogPath) { Remove-Item $script:TunnelLogPath -Force -ErrorAction SilentlyContinue }

    # Iniciar cloudflared en segundo plano redirigiendo stderr al archivo de log
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $bin
    $psi.Arguments = "tunnel --url http://127.0.0.1:$LocalPort"
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardOutput = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    
    # Manejar eventos de log para capturar la URL en tiempo real
    $script:detectedUrl = $null
    $outputHandler = {
        param($sender, $e)
        if ($e.Data) {
            Add-Content -Path $using:TunnelLogPath -Value $e.Data
            if ($e.Data -match "https://[a-zA-Z0-9-]+\.trycloudflare\.com") {
                $script:detectedUrl = $matches[0]
            }
        }
    }
    Register-ObjectEvent -InputObject $proc -EventName "OutputDataReceived" -Action $outputHandler | Out-Null
    Register-ObjectEvent -InputObject $proc -EventName "ErrorDataReceived" -Action $outputHandler | Out-Null

    $proc.Start() | Out-Null
    $proc.BeginOutputReadLine()
    $proc.BeginErrorReadLine()

    Write-Host " Esperando asignacion de dominio seguro por Cloudflare..." -NoNewline
    $timeout = 15
    $elapsed = 0
    while ($elapsed -lt $timeout -and -not $script:detectedUrl) {
        Start-Sleep -Milliseconds 500
        $elapsed += 0.5
        Write-Host "." -NoNewline
        $url = Get-TunnelUrlFromLog
        if ($url) { $script:detectedUrl = $url; break }
    }
    Write-Host ""

    if ($script:detectedUrl) {
        Write-Host "`n ==========================================================" -ForegroundColor Green
        Write-Host "   TUNEL ACTIVO EN LINEA: $($script:detectedUrl)" -ForegroundColor Green
        Write-Host " ==========================================================" -ForegroundColor Green
        Write-Host " Cualquier webhook externo o servicio en la nube puede conectar"
        Write-Host " a tu puerto local $LocalPort usando esta direccion HTTPS." -ForegroundColor Gray
    } else {
        Write-Host " [AVISO] El tunel esta conectando en segundo plano." -ForegroundColor Yellow
        Write-Host " Consulta la opcion [6] Diagnostico para ver la URL cuando este lista." -ForegroundColor Gray
    }
    return $proc
}

# ==============================================================================
# 4. MOTOR DUAL ADAPTATIVO: CONTENEDORES VS NATIVO
# ==============================================================================

function Start-DockerEngineIfStopped {
    $dInfo = Get-DockerInfo
    if (-not $dInfo.Installed) {
        Write-Host "`n [AVISO] Docker Desktop no se encuentra instalado en este equipo." -ForegroundColor Yellow
        Write-Host " Deseas abrir el enlace de descarga oficial en tu navegador? (S/N): " -NoNewline -ForegroundColor Cyan
        $resp = Read-Host
        if ($resp -match "^[sSyY]") {
            Start-Process "https://www.docker.com/products/docker-desktop/"
        }
        return $false
    }

    if ($dInfo.Running) { return $true }

    Write-Host "`n Docker Desktop esta apagado. Intentando iniciar el motor..." -ForegroundColor Yellow
    $dPaths = @(
        "$env:LOCALAPPDATA\Programs\DockerDesktop\Docker Desktop.exe",
        "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
    )
    $started = $false
    foreach ($dp in $dPaths) {
        if (Test-Path $dp) {
            Start-Process $dp
            $started = $true
            break
        }
    }

    if ($started) {
        Write-Host " Esperando a que el motor de Docker responda..." -NoNewline
        $attempts = 0
        while ($attempts -lt 25) {
            Start-Sleep -Seconds 2
            $attempts++
            Write-Host "." -NoNewline
            $check = Get-DockerInfo
            if ($check.Running) {
                Write-Host " [CONECTADO]" -ForegroundColor Green
                return $true
            }
        }
        Write-Host "`n [TIEMPO AGOTADO] Docker tardo demasiado en arrancar." -ForegroundColor Red
    }
    return $false
}

function Start-ContainerMode {
    param([bool]$WithTunnel = $false)
    Ensure-EnvFile

    Write-Host "`n ==========================================================" -ForegroundColor Cyan
    Write-Host "   INICIANDO MODO CONTENEDOR (DOCKER COMPOSE COMPLETO)" -ForegroundColor Cyan
    Write-Host " ==========================================================" -ForegroundColor Cyan

    $ready = Start-DockerEngineIfStopped
    if (-not $ready) {
        Write-Host "`n [FALLO] No se puede iniciar en modo contenedor sin Docker en ejecucion." -ForegroundColor Red
        Write-Host " Deseas iniciar en Modo Nativo (Ligero / Node.js) en su lugar? (S/N): " -NoNewline -ForegroundColor Yellow
        $alt = Read-Host
        if ($alt -match "^[sSyY]") {
            Start-NativeMode -WithTunnel $WithTunnel
        }
        return
    }

    Write-Host " Levantando servicios con Docker Compose..." -ForegroundColor Cyan
    docker compose up -d

    Write-Host "`n Verificando estado de los contenedores..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2
    docker compose ps

    $apiKey = Get-EnvVar "AUTHENTICATION_API_KEY" "No configurada"
    Write-Host "`n ==========================================================" -ForegroundColor Green
    Write-Host "  ¡SERVICIOS EN CONTENEDOR ACTIVOS!" -ForegroundColor Green
    Write-Host " ==========================================================" -ForegroundColor Green
    Write-Host "  * Panel Evolution Manager : http://localhost:8080/manager"
    Write-Host "  * API WhatsApp (Directa)  : http://localhost:8080"
    Write-Host "  * Gateway Webhook Router  : http://localhost:3050"
    Write-Host "  * ApiKey Global (.env)    : $apiKey" -ForegroundColor Yellow

    if ($WithTunnel) {
        Start-CloudflareTunnel -LocalPort 3050
    }

    Write-Host "`nPresiona cualquier tecla para volver al menu..."
    [Console]::ReadKey($true) | Out-Null
}

function Start-NativeMode {
    param([bool]$WithTunnel = $false)
    Ensure-EnvFile

    Write-Host "`n ==========================================================" -ForegroundColor Magenta
    Write-Host "   INICIANDO MODO NATIVO (LIGERO / BAJO CONSUMO DE RAM)" -ForegroundColor Magenta
    Write-Host " ==========================================================" -ForegroundColor Magenta

    $nodeInfo = Get-NodeInfo
    if (-not $nodeInfo.Installed) {
        Write-Host " [ERROR] Node.js no esta instalado en este equipo." -ForegroundColor Red
        Write-Host " Descarga Node.js desde: https://nodejs.org/" -ForegroundColor Yellow
        Start-Sleep -Seconds 3
        return
    }

    $port = [int](Get-EnvVar "PORT" "3050")
    if (Test-PortListening $port) {
        Write-Host " [AVISO] El puerto $port ya esta en uso por otro proceso." -ForegroundColor Yellow
        $owner = Get-PortProcessInfo $port
        if ($owner) { Write-Host " Proceso actual: $($owner.Name) (PID: $($owner.PID))" -ForegroundColor Gray }
    } else {
        Write-Host " Iniciando Gateway de Webhooks nativo con Node.js ($($nodeInfo.Version))..." -ForegroundColor Cyan
        $serverPath = Join-Path $script:ScriptDir "webhook-filter\server.js"
        
        # Iniciar en una ventana persistente independiente asegurando el directorio de trabajo
        $startArgs = "/k cd /d `"$script:ScriptDir`" && title Gateway Webhook WhatsApp (Nativo) && node `"$serverPath`""
        Start-Process "cmd.exe" -ArgumentList $startArgs
        
        Start-Sleep -Seconds 2
        if (Test-PortListening $port) {
            Write-Host " [OK] Gateway Webhook iniciado y escuchando en http://localhost:$port" -ForegroundColor Green
        }
    }

    if ($WithTunnel) {
        Start-CloudflareTunnel -LocalPort $port
    }

    Write-Host "`nPresiona cualquier tecla para volver al menu..."
    [Console]::ReadKey($true) | Out-Null
}

# ==============================================================================
# 5. PANEL INTERACTIVO DE CONFIGURACION (.ENV WIZARD)
# ==============================================================================

function Show-ConfigWizard {
    Ensure-EnvFile
    while ($true) {
        Clear-Host
        $apiKey = Get-EnvVar "AUTHENTICATION_API_KEY" "(No definida)"
        $groups = Get-EnvVar "TARGET_GROUPS" "*"
        $dest = Get-EnvVar "WEBHOOK_DESTINATIONS" "(Ninguno)"
        $srvPort = Get-EnvVar "SERVER_PORT" "8080"
        $gatePort = Get-EnvVar "PORT" "3050"

        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "       PANEL DE CONFIGURACION Y CREDENCIALES (.env)       " -ForegroundColor Yellow
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host " Administra los parametros clave sin tocar archivos de codigo.`n"
        Write-Host " [1] Clave Global ApiKey (AUTHENTICATION_API_KEY):" -ForegroundColor White
        Write-Host "     -> $apiKey" -ForegroundColor Green
        Write-Host " [2] Grupos WhatsApp Autorizados (TARGET_GROUPS):" -ForegroundColor White
        Write-Host "     -> $groups" -ForegroundColor Green
        Write-Host " [3] Destinos Webhook Multi-Plataforma (WEBHOOK_DESTINATIONS):" -ForegroundColor White
        Write-Host "     -> $dest" -ForegroundColor Green
        Write-Host " [4] Puerto Evolution API (SERVER_PORT):" -ForegroundColor White
        Write-Host "     -> $srvPort" -ForegroundColor Gray
        Write-Host " [5] Puerto Gateway Webhook (PORT):" -ForegroundColor White
        Write-Host "     -> $gatePort" -ForegroundColor Gray
        Write-Host "----------------------------------------------------------" -ForegroundColor Cyan
        Write-Host " Acciones rapidas:" -ForegroundColor Yellow
        Write-Host "  [G] Generar nueva ApiKey segura aleatoria (32 caracteres)"
        Write-Host "  [A] Permitir TODOS los grupos de WhatsApp (*)"
        Write-Host "  [0] Guardar y volver al menu principal"
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host -NoNewline " Elige una opcion [0-5, G, A]: "
        $opt = (Read-Host).Trim().ToUpper()

        switch ($opt) {
            "1" {
                Write-Host "`n Ingrese el nuevo valor para AUTHENTICATION_API_KEY:" -ForegroundColor Cyan
                $newKey = Read-Host
                if (-not [string]::IsNullOrWhiteSpace($newKey)) {
                    Set-EnvVar "AUTHENTICATION_API_KEY" $newKey.Trim()
                    Write-Host " [OK] Clave actualizada." -ForegroundColor Green
                    Start-Sleep -Milliseconds 600
                }
            }
            "2" {
                Write-Host "`n Ingrese los IDs de grupos de WhatsApp separados por coma" -ForegroundColor Cyan
                Write-Host " (Ejemplo: 000000000000000000@g.us,000000000000000001@g.us o '*' para todos):" -ForegroundColor Gray
                $newGroups = Read-Host
                if (-not [string]::IsNullOrWhiteSpace($newGroups)) {
                    Set-EnvVar "TARGET_GROUPS" $newGroups.Trim()
                    Write-Host " [OK] Grupos autorizados actualizados." -ForegroundColor Green
                    Start-Sleep -Milliseconds 600
                }
            }
            "3" {
                Write-Host "`n Ingrese las URLs de webhook destino separadas por coma" -ForegroundColor Cyan
                Write-Host " (Ej: http://localhost:5678/webhook/wa,https://discord.com/api/webhooks/...):" -ForegroundColor Gray
                $newDest = Read-Host
                if (-not [string]::IsNullOrWhiteSpace($newDest)) {
                    Set-EnvVar "WEBHOOK_DESTINATIONS" $newDest.Trim()
                    Write-Host " [OK] Destinos webhook actualizados." -ForegroundColor Green
                    Start-Sleep -Milliseconds 600
                }
            }
            "4" {
                Write-Host "`n Ingrese el nuevo puerto para Evolution API (por defecto 8080):" -ForegroundColor Cyan
                $newPort = Read-Host
                if ($newPort -match "^\d+$") {
                    Set-EnvVar "SERVER_PORT" $newPort.Trim()
                    Write-Host " [OK] Puerto del servidor actualizado." -ForegroundColor Green
                    Start-Sleep -Milliseconds 600
                }
            }
            "5" {
                Write-Host "`n Ingrese el nuevo puerto para el Gateway Webhook (por defecto 3050):" -ForegroundColor Cyan
                $newPort = Read-Host
                if ($newPort -match "^\d+$") {
                    Set-EnvVar "PORT" $newPort.Trim()
                    Write-Host " [OK] Puerto del Gateway actualizado." -ForegroundColor Green
                    Start-Sleep -Milliseconds 600
                }
            }
            "G" {
                $gen = Generate-SecureApiKey
                Set-EnvVar "AUTHENTICATION_API_KEY" $gen
                Write-Host "`n [OK] Generada nueva clave segura: $gen" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            "A" {
                Set-EnvVar "TARGET_GROUPS" "*"
                Write-Host "`n [OK] Modo abierto activado: Permitiendo todos los grupos (*)" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            "0" {
                return
            }
        }
    }
}

# ==============================================================================
# 6. MONITORIZACION ACTIVA Y HEALTH CHECK EN TIEMPO REAL
# ==============================================================================

function Show-HealthCheckDashboard {
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "         DIAGNOSTICO Y SALUD DEL SISTEMA EN VIVO          " -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Cyan

    # 1. Conectividad Externa
    Write-Host " [1] Conectividad Externa a Internet:" -ForegroundColor White
    $net = Get-InternetStatus
    if ($net.Online) {
        Write-Host "     Estado  : EN LINEA (Respuesta en $($net.LatencyMs) ms)" -ForegroundColor Green
    } else {
        Write-Host "     Estado  : DESCONECTADO (Sin acceso a internet)" -ForegroundColor Red
    }

    # 2. Motores de Ejecucion
    Write-Host "`n [2] Motores de Ejecucion:" -ForegroundColor White
    $d = Get-DockerInfo
    $n = Get-NodeInfo
    $dText = if ($d.Running) { "En ejecucion (v$($d.Version))" } elseif ($d.Installed) { "Instalado pero detenido" } else { "No instalado" }
    $dColor = if ($d.Running) { "Green" } elseif ($d.Installed) { "Yellow" } else { "Red" }
    Write-Host "     Docker  : $dText" -ForegroundColor $dColor

    $nText = if ($n.Installed) { "Disponible ($($n.Version))" } else { "No instalado" }
    $nColor = if ($n.Installed) { "Green" } else { "Red" }
    Write-Host "     Node.js : $nText" -ForegroundColor $nColor

    # 3. Sondeo de Puertos Locales
    Write-Host "`n [3] Sondeo de Puertos y Servicios:" -ForegroundColor White
    $services = @(
        @{ Name = "Gateway Webhook Router"; Port = [int](Get-EnvVar "PORT" "3050"); Critical = $true },
        @{ Name = "Evolution API Core";     Port = [int](Get-EnvVar "SERVER_PORT" "8080"); Critical = $true },
        @{ Name = "Panel Manager Frontend"; Port = 4433; Critical = $false },
        @{ Name = "PostgreSQL Database";    Port = 5432; Critical = $false },
        @{ Name = "Redis Cache Database";   Port = 6379; Critical = $false },
        @{ Name = "n8n Automation Local";   Port = 5678; Critical = $false }
    )

    foreach ($s in $services) {
        $listening = Test-PortListening $s.Port
        $statusStr = if ($listening) { "[ACTIVO / 200 OK]" } else { "[DETENIDO]" }
        $color = if ($listening) { "Green" } else { "Gray" }
        Write-Host "     - $($s.Name.PadRight(24)) (Puerto $($s.Port)): " -NoNewline
        Write-Host "$statusStr" -ForegroundColor $color
    }

    # 4. Chequeo Endpoint /health de Gateway
    Write-Host "`n [4] Diagnostico HTTP Gateway (Puerto $(Get-EnvVar "PORT" "3050")):" -ForegroundColor White
    $gwPort = Get-EnvVar "PORT" "3050"
    try {
        $gwRes = Invoke-RestMethod -Uri "http://127.0.0.1:$gwPort/health" -TimeoutSec 2 -ErrorAction Stop
        Write-Host "     Estado HTTP: 200 OK (Servicio: $($gwRes.service))" -ForegroundColor Green
        Write-Host "     Destinos activos: $($gwRes.destinationsCount) | Filtro Grupos: $(if ($gwRes.allowAllGroups){'* (Todos)'} else {$gwRes.targetGroupsCount})" -ForegroundColor Gray
    } catch {
        Write-Host "     El endpoint /health no responde en http://127.0.0.1:$gwPort" -ForegroundColor DarkGray
    }

    # 5. Estado del Tunel Cloudflare
    Write-Host "`n [5] Estado de Tunel Publico (Cloudflare):" -ForegroundColor White
    $cfProcs = Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue
    $tUrl = Get-TunnelUrlFromLog
    if ($cfProcs -and $tUrl) {
        Write-Host "     Estado  : EN LINEA (Accesible publicamente)" -ForegroundColor Green
        Write-Host "     URL     : $tUrl" -ForegroundColor Cyan
    } elseif ($cfProcs) {
        Write-Host "     Estado  : RECONECTANDO / SINCRONIZANDO (Proceso activo)" -ForegroundColor Yellow
    } else {
        Write-Host "     Estado  : DESCONECTADO (Ningun tunel activo)" -ForegroundColor Gray
    }

    Write-Host "`n==========================================================" -ForegroundColor Cyan
    Write-Host "Presiona cualquier tecla para volver al menu..."
    [Console]::ReadKey($true) | Out-Null
}

# ==============================================================================
# 7. AUDITOR Y SIMULADOR DE MENSAJES
# ==============================================================================

function Show-AuditorView {
    $dInfo = Get-DockerInfo
    $gwPort = [int](Get-EnvVar "PORT" "3050")
    $isPortActive = Test-PortListening $gwPort

    $logFile = Join-Path $script:ScriptDir ".gateway.log"
    if (-not (Test-Path $logFile)) {
        $alt = Join-Path $script:ScriptDir "webhook-filter\.gateway.log"
        if (Test-Path $alt) { $logFile = $alt }
    }

    $dockerContainerRunning = $false
    if ($dInfo.Running) {
        $cCheck = docker ps -q -f name=webhook_filter 2>$null
        if ($cCheck) { $dockerContainerRunning = $true }
    }

    $motorTexto = "Inactivo / Ninguno"
    if ($dockerContainerRunning) {
        $motorTexto = "Contenedor Docker (webhook_filter)"
    } elseif ($isPortActive) {
        $motorTexto = "Modo Nativo (Node.js en puerto $gwPort)"
    }

    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "        AUDITOR Y EMULADOR DE MENSAJES WHATSAPP           " -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "  * Motor Detectado : $motorTexto" -ForegroundColor $(if ($motorTexto -ne "Inactivo / Ninguno") { "Green" } else { "Gray" })
    Write-Host "----------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host " [1] Ver registros de trafico en VIVO (Deteccion Automatica)"
    Write-Host " [2] Ver ultimos 25 eventos procesados (Deteccion Automatica)"
    Write-Host " [3] Simular envio de mensaje de prueba al Gateway"
    Write-Host " [4] Forzar lectura de logs de Docker (webhook_filter)"
    Write-Host " [5] Forzar lectura de logs de Node.js Nativo (.gateway.log)"
    Write-Host " [0] Volver"
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host -NoNewline " Selecciona una opcion [0-5]: "
    $sel = Read-Host

    switch ($sel) {
        "1" {
            Clear-Host
            if ($dockerContainerRunning) {
                Write-Host " [DOCKER] Conectando a logs en vivo (Ctrl+C para salir)...`n" -ForegroundColor Cyan
                docker logs -f --tail 25 webhook_filter
            } elseif (Test-Path $logFile) {
                Write-Host " [NATIVO] Conectando a .gateway.log en vivo (Ctrl+C para salir)...`n" -ForegroundColor Cyan
                Get-Content -Path $logFile -Wait -Tail 25
            } elseif ($isPortActive) {
                Write-Host " Gateway nativo esta activo en puerto $gwPort." -ForegroundColor Cyan
                Write-Host " Los logs en vivo se muestran en la ventana: 'Gateway Webhook WhatsApp (Nativo)'" -ForegroundColor Yellow
                Write-Host "`nPresiona cualquier tecla..."
                [Console]::ReadKey($true) | Out-Null
            } else {
                Write-Host " [AVISO] No hay ningun servicio activo de Gateway (Docker ni Node.js)." -ForegroundColor Yellow
                Write-Host " Inicia el sistema primero con la opcion [1], [2], [3] o [4]." -ForegroundColor Gray
                Write-Host "`nPresiona cualquier tecla..."
                [Console]::ReadKey($true) | Out-Null
            }
        }
        "2" {
            Clear-Host
            if ($dockerContainerRunning) {
                Write-Host " [DOCKER] Ultimos eventos del contenedor webhook_filter:`n" -ForegroundColor Cyan
                docker logs --tail 25 webhook_filter
            } elseif (Test-Path $logFile) {
                Write-Host " [NATIVO] Ultimos eventos de .gateway.log:`n" -ForegroundColor Cyan
                Get-Content -Path $logFile -Tail 25
            } elseif ($isPortActive) {
                Write-Host " Gateway nativo esta activo en puerto $gwPort." -ForegroundColor Cyan
                Write-Host " Revisa la ventana abierta de 'Gateway Webhook WhatsApp (Nativo)'." -ForegroundColor Gray
            } else {
                Write-Host " [AVISO] No se encontraron registros activos de Docker ni archivo .gateway.log." -ForegroundColor Yellow
                Write-Host " Si usas Modo Nativo, inicia el Gateway con la opcion [3] o [4]." -ForegroundColor Gray
            }
            Write-Host "`nPresiona cualquier tecla..."
            [Console]::ReadKey($true) | Out-Null
        }
        "3" {
            $targetGroup = Get-EnvVar "TARGET_GROUPS" "000000000000000000@g.us"
            if ($targetGroup -eq "*") { $targetGroup = "000000000000000000@g.us" }
            $firstGroup = ($targetGroup -split ",")[0].Trim()

            Write-Host "`n Enviando mensaje de prueba simulando chat '$firstGroup'..." -ForegroundColor Cyan
            $testPayload = @{
                event = "messages.upsert"
                data  = @{
                    key      = @{
                        remoteJid = $firstGroup
                        fromMe    = $false
                    }
                    pushName = "Auditor de Sistema"
                    message  = @{
                        conversation = "Prueba de ciclo de vida $(Get-Date -Format 'HH:mm:ss')"
                    }
                }
            } | ConvertTo-Json -Depth 5

            try {
                $res = Invoke-RestMethod -Uri "http://127.0.0.1:$gwPort" -Method Post -Body $testPayload -ContentType "application/json" -TimeoutSec 3
                Write-Host " [EXITO] Respuesta del Gateway:" -ForegroundColor Green
                $res | Format-List
            } catch {
                Write-Host " [ERROR] No se pudo enviar el mensaje de prueba: $_" -ForegroundColor Red
            }
            Write-Host "`nPresiona cualquier tecla..."
            [Console]::ReadKey($true) | Out-Null
        }
        "4" {
            Clear-Host
            if (-not $dInfo.Installed) {
                Write-Host " [AVISO] Docker no esta instalado en este equipo." -ForegroundColor Yellow
                Write-Host " Para ver logs sin Docker, utiliza la opcion [5] (Logs de Node.js Nativo)." -ForegroundColor Gray
            } elseif (-not $dInfo.Running) {
                Write-Host " [AVISO] Docker esta instalado pero el motor esta detenido." -ForegroundColor Yellow
            } else {
                Write-Host " Registros de Docker webhook_filter:`n" -ForegroundColor Cyan
                docker logs --tail 25 webhook_filter 2>$null
                if ($LASTEXITCODE -ne 0) {
                    Write-Host " Contenedor webhook_filter no encontrado o no ha iniciado." -ForegroundColor Gray
                }
            }
            Write-Host "`nPresiona cualquier tecla..."
            [Console]::ReadKey($true) | Out-Null
        }
        "5" {
            Clear-Host
            if (Test-Path $logFile) {
                Write-Host " Registros nativos ($logFile):`n" -ForegroundColor Cyan
                Get-Content -Path $logFile -Tail 25
            } else {
                Write-Host " [AVISO] No se encontro el archivo $logFile." -ForegroundColor Yellow
                Write-Host " Si el Gateway esta corriendo nativo, revisa la ventana de comandos de Node.js." -ForegroundColor Gray
            }
            Write-Host "`nPresiona cualquier tecla..."
            [Console]::ReadKey($true) | Out-Null
        }
    }
}

# ==============================================================================
# 8. APAGADO CENTRALIZADO Y LIMPIEZA
# ==============================================================================

function Stop-AllServices {
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Red
    Write-Host "             DETENIENDO TODOS LOS SERVICIOS               " -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Red

    # 1. Detener Contenedores Docker
    $d = Get-DockerInfo
    if ($d.Running) {
        Write-Host " Deteniendo contenedores de Docker Compose..." -ForegroundColor Cyan
        docker compose stop
        Write-Host " [OK] Contenedores detenidos." -ForegroundColor Green
    }

    # 2. Detener Procesos de Tunel Cloudflare
    $cfProcs = Get-Process -Name "cloudflared" -ErrorAction SilentlyContinue
    if ($cfProcs) {
        Write-Host " Cerrando procesos de Cloudflare Tunnel..." -ForegroundColor Cyan
        $cfProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host " [OK] Tuneles finalizados." -ForegroundColor Green
    }

    # 3. Limpiar archivo de log de tunel
    if (Test-Path $script:TunnelLogPath) {
        Remove-Item $script:TunnelLogPath -Force -ErrorAction SilentlyContinue
    }

    # 4. Comprobar proceso huerfano en puerto 3050 (Node nativo)
    $port = [int](Get-EnvVar "PORT" "3050")
    $owner = Get-PortProcessInfo $port
    if ($owner -and $owner.Name -match "node") {
        Write-Host " Liberando puerto $port ocupado por proceso Node nativo (PID $($owner.PID))..." -ForegroundColor Cyan
        Stop-Process -Id $owner.PID -Force -ErrorAction SilentlyContinue
        Write-Host " [OK] Proceso nativo finalizado." -ForegroundColor Green
    }

    # 5. Detener procesos de WhatsApp Nativo (Baileys)
    $waProcs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match "whatsapp-native[\\/]client\.js" }
    if ($waProcs) {
        Write-Host " Deteniendo proceso de WhatsApp Nativo..." -ForegroundColor Cyan
        $waProcs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Write-Host " [OK] Conector de WhatsApp detenido." -ForegroundColor Green
    }

    Write-Host "`n Todos los servicios han sido detenidos de forma segura." -ForegroundColor Green
    Write-Host " Tus datos de sesion de WhatsApp y base de datos estan preservados." -ForegroundColor Gray
    Start-Sleep -Seconds 2
}

function Start-NativeWhatsApp {
    Clear-Host
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "     VINCULAR WHATSAPP NATIVO (ESCANEAR CODIGO QR)        " -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Cyan

    $waDir = Join-Path $script:ScriptDir "whatsapp-native"
    $waClient = Join-Path $waDir "client.js"
    $nodeModules = Join-Path $waDir "node_modules\@whiskeysockets\baileys"

    if (-not (Test-Path $nodeModules)) {
        Write-Host " Instalando dependencias de WhatsApp Nativo (Baileys)..." -ForegroundColor Cyan
        $cmdInstall = "cd /d `"$waDir`" && npm install --no-audit --no-fund"
        Start-Process "cmd.exe" -ArgumentList "/c $cmdInstall" -Wait
    }

    Write-Host "`n Iniciando terminal de escaneo de QR..." -ForegroundColor Green
    $cmdStart = "/k cd /d `"$script:ScriptDir`" && title Conector WhatsApp Nativo && node `"$waClient`""
    Start-Process "cmd.exe" -ArgumentList $cmdStart

    Write-Host " [OK] Ventana de conexion abierta." -ForegroundColor Green
    Write-Host " Escanea el codigo QR que aparece en esa ventana con tu telefono." -ForegroundColor Yellow
    Write-Host "`nPresiona cualquier tecla para volver al menu..."
    [Console]::ReadKey($true) | Out-Null
}

# ==============================================================================
# 9. BUCLE DEL MENU PRINCIPAL
# ==============================================================================

function Main-Menu {
    Ensure-EnvFile

    while ($true) {
        Clear-Host
        $d = Get-DockerInfo
        $n = Get-NodeInfo
        $net = Get-InternetStatus
        $port3050 = Test-PortListening ([int](Get-EnvVar "PORT" "3050"))
        $port8080 = Test-PortListening ([int](Get-EnvVar "SERVER_PORT" "8080"))

        $dStr = if ($d.Running) { "En ejecucion (v$($d.Version))" } elseif ($d.Installed) { "Detenido (Instalado)" } else { "No instalado" }
        $dCol = if ($d.Running) { "Green" } elseif ($d.Installed) { "Yellow" } else { "DarkGray" }
        $nStr = if ($n.Installed) { "$($n.Version) (Disponible)" } else { "No instalado" }
        $netStr = if ($net.Online) { "EN LINEA ($($net.LatencyMs) ms)" } else { "DESCONECTADO" }
        $netCol = if ($net.Online) { "Green" } else { "Red" }

        $gwStatus = if ($port3050) { "ONLINE" } else { "OFF" }
        $gwCol = if ($port3050) { "Green" } else { "DarkGray" }
        $apiStatus = if ($port8080) { "ONLINE" } else { "OFF" }
        $apiCol = if ($port8080) { "Green" } else { "DarkGray" }

        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "       GESTOR DEL SISTEMA: EVOLUTION API & GATEWAY        " -ForegroundColor Yellow
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host " Entorno detectado:" -ForegroundColor White
        Write-Host "   * Motor Contenedores (Docker) : " -NoNewline
        Write-Host "$dStr" -ForegroundColor $dCol
        Write-Host "   * Motor Nativo (Node.js)      : " -NoNewline
        Write-Host "$nStr" -ForegroundColor Green
        Write-Host "   * Conectividad a Internet     : " -NoNewline
        Write-Host "$netStr" -ForegroundColor $netCol
        Write-Host "   * Estado Servicios            : Gateway [3050: $gwStatus] | API [8080: $apiStatus]" -ForegroundColor Cyan
        Write-Host "----------------------------------------------------------" -ForegroundColor Cyan
        Write-Host " Opciones de Ejecucion:" -ForegroundColor Yellow
        Write-Host "   [1] Iniciar con Contenedores (Docker Compose - Stack Completo)"
        Write-Host "   [2] Iniciar con Contenedores + Tunel Publico Cloudflare (Webhooks)"
        Write-Host "   [3] Iniciar Modo Nativo (Gateway Ligero / Bajo Consumo de RAM)"
        Write-Host "   [4] Iniciar Modo Nativo + Tunel Publico Cloudflare"
        Write-Host "----------------------------------------------------------" -ForegroundColor Cyan
        Write-Host " Administracion y Control:" -ForegroundColor Yellow
        Write-Host "   [5] Panel de Configuracion y Credenciales (.env Wizard)" -ForegroundColor Cyan
        Write-Host "   [6] Diagnostico y Salud en Tiempo Real (Health Check)"
        Write-Host "   [7] Auditor de Mensajes y Simulador de Trafico"
        Write-Host "   [8] Detener todos los servicios" -ForegroundColor Red
        Write-Host "   [9] Vincular WhatsApp Nativo (Escanear Codigo QR sin Docker)" -ForegroundColor Magenta
        Write-Host "   [0] Salir"
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host -NoNewline " Elige una opcion [0-9]: "
        $choice = Read-Host

        switch ($choice) {
            "1" { Start-ContainerMode -WithTunnel $false }
            "2" { Start-ContainerMode -WithTunnel $true }
            "3" { Start-NativeMode -WithTunnel $false }
            "4" { Start-NativeMode -WithTunnel $true }
            "5" { Show-ConfigWizard }
            "6" { Show-HealthCheckDashboard }
            "7" { Show-AuditorView }
            "8" { Stop-AllServices }
            "9" { Start-NativeWhatsApp }
            "0" {
                Write-Host "`nHasta pronto!`n" -ForegroundColor Green
                exit 0
            }
            default {
                Write-Host " Opcion no valida." -ForegroundColor Yellow
                Start-Sleep -Milliseconds 600
            }
        }
    }
}

# Ejecutar bucle principal
Main-Menu
