[CmdletBinding()]
param(
    [string]$Server = "lab-bio@10.200.1.180",
    [string]$RemoteProject = "C:/Users/lab-bio/Research",
    [string]$LocalRuns = "",
    [int]$LocalPort = 6006,
    [int]$SyncIntervalMinutes = 10
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($LocalRuns)) {
    $LocalRuns = Join-Path $PSScriptRoot "..\server-results"
}
$localRoot = [System.IO.Path]::GetFullPath($LocalRuns)
$null = New-Item -ItemType Directory -Path $localRoot -Force
$statePath = Join-Path $localRoot "connectivity-state.json"
$logPath = Join-Path $localRoot "connectivity-watchdog.log"
$syncScript = Join-Path $PSScriptRoot "sync-results.ps1"

function Write-WatchdogLog([string]$Message) {
    "$(Get-Date -Format o) $Message" | Add-Content -Path $logPath -Encoding utf8
}

function Save-State([string]$Status, [string]$ErrorMessage = "", [datetime]$LastSyncUtc = [datetime]::MinValue) {
    [pscustomobject]@{
        status = $Status
        server = $Server
        local_port = $LocalPort
        checked_utc = [datetime]::UtcNow.ToString("o")
        last_sync_utc = if ($LastSyncUtc -eq [datetime]::MinValue) { $null } else { $LastSyncUtc.ToString("o") }
        error = $ErrorMessage
    } | ConvertTo-Json | Set-Content -Path $statePath -Encoding utf8
}

$previousState = $null
if (Test-Path $statePath) {
    try { $previousState = Get-Content $statePath -Raw | ConvertFrom-Json } catch { $previousState = $null }
}
$lastSyncUtc = [datetime]::MinValue
if ($previousState -and $previousState.last_sync_utc) {
    try { $lastSyncUtc = ([datetime]$previousState.last_sync_utc).ToUniversalTime() } catch { }
}

try {
    $serverHost = ($Server -split '@')[-1]
    $tcpClient = [System.Net.Sockets.TcpClient]::new()
    try {
        $connectTask = $tcpClient.ConnectAsync($serverHost, 22)
        $portReachable = $connectTask.Wait([timespan]::FromSeconds(6)) -and $tcpClient.Connected
    } catch {
        $portReachable = $false
    } finally {
        $tcpClient.Dispose()
    }
    if (-not $portReachable) {
        Save-State "offline" "SSH server is not reachable." $lastSyncUtc
        exit 0
    }

    $listener = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $tunnelHealthy = $false
    if ($listener) {
        try {
            $response = Invoke-WebRequest "http://127.0.0.1:$LocalPort/" -UseBasicParsing -TimeoutSec 5
            $tunnelHealthy = $response.StatusCode -ge 200 -and $response.StatusCode -lt 500
        } catch { $tunnelHealthy = $false }
    }

    if (-not $tunnelHealthy) {
        # Remove only a stale SSH listener belonging to this Research tunnel.
        foreach ($connection in @(Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue)) {
            $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($connection.OwningProcess)" -ErrorAction SilentlyContinue
            if ($process.Name -eq "ssh.exe" -and $process.CommandLine -like "*$Server*" -and
                $process.CommandLine -like "*6006:127.0.0.1:6006*") {
                Stop-Process -Id $connection.OwningProcess -Force -ErrorAction SilentlyContinue
            }
        }
        $sshArguments = @(
            "-N", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3",
            "-o", "ExitOnForwardFailure=yes",
            "-L", "$LocalPort`:127.0.0.1:6006", $Server
        )
        Start-Process -FilePath "ssh.exe" -ArgumentList $sshArguments -WindowStyle Hidden | Out-Null
        Start-Sleep -Seconds 3
        $listener = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $listener) { throw "SSH tunnel did not start on local port $LocalPort." }
        Write-WatchdogLog "TensorBoard tunnel started on http://localhost:$LocalPort/."
    }

    $syncDue = $lastSyncUtc -eq [datetime]::MinValue -or
        ([datetime]::UtcNow - $lastSyncUtc).TotalMinutes -ge $SyncIntervalMinutes
    if ($syncDue) {
        Save-State "syncing" "" $lastSyncUtc
        & $syncScript -Server $Server -RemoteProject $RemoteProject -LocalRuns $localRoot
        if ($LASTEXITCODE -ne 0) { throw "Result synchronization exited with code $LASTEXITCODE." }
        $lastSyncUtc = [datetime]::UtcNow
        Write-WatchdogLog "Results synchronized."
    }
    Save-State "online" "" $lastSyncUtc
} catch {
    Save-State "error" $_.Exception.Message $lastSyncUtc
    Write-WatchdogLog "ERROR: $($_.Exception.Message)"
    exit 1
}
