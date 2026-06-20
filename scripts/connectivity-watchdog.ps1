[CmdletBinding()]
param(
    [string]$Server = "lab-bio@10.200.1.180",
    [string]$RemoteProject = "C:/Users/lab-bio/Research",
    [string]$LocalRuns = "",
    [string]$TensorBoardUrl = "http://10.200.1.180:6006/",
    [int]$SyncIntervalMinutes = 10,
    [int]$CheckIntervalSeconds = 120,
    [int]$SyncTimeoutMinutes = 30
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
        tensorboard_url = $TensorBoardUrl
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

while ($true) {
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
        Start-Sleep -Seconds $CheckIntervalSeconds
        continue
    }

    try {
        $response = Invoke-WebRequest $TensorBoardUrl -UseBasicParsing -TimeoutSec 8
        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 500) {
            throw "TensorBoard returned HTTP $($response.StatusCode)."
        }
    } catch {
        Write-WatchdogLog "TensorBoard is unavailable at $TensorBoardUrl`: $($_.Exception.Message)"
    }

    $syncDue = $lastSyncUtc -eq [datetime]::MinValue -or
        ([datetime]::UtcNow - $lastSyncUtc).TotalMinutes -ge $SyncIntervalMinutes
    if ($syncDue) {
        Save-State "syncing" "" $lastSyncUtc
        $syncStdout = Join-Path $localRoot "result-sync.stdout.log"
        $syncStderr = Join-Path $localRoot "result-sync.stderr.log"
        $syncArguments = @(
            "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", "`"$syncScript`"", "-Server", "`"$Server`"",
            "-RemoteProject", "`"$RemoteProject`"", "-LocalRuns", "`"$localRoot`""
        ) -join " "
        $syncProcess = Start-Process powershell.exe -ArgumentList $syncArguments `
            -WindowStyle Hidden -RedirectStandardOutput $syncStdout `
            -RedirectStandardError $syncStderr -PassThru
        # Force PowerShell 5.1 to retain the native process handle so ExitCode is
        # populated after WaitForExit when streams are redirected.
        $null = $syncProcess.Handle
        if (-not $syncProcess.WaitForExit($SyncTimeoutMinutes * 60 * 1000)) {
            & taskkill.exe /PID $syncProcess.Id /T /F 2>$null | Out-Null
            throw "Result synchronization timed out after $SyncTimeoutMinutes minutes."
        }
        $syncProcess.WaitForExit()
        $syncProcess.Refresh()
        $syncExitCode = $syncProcess.ExitCode
        if ($syncExitCode -ne 0) {
            $syncError = if (Test-Path $syncStderr) { Get-Content $syncStderr -Tail 1 } else { "" }
            throw "Result synchronization exited with code $syncExitCode`: $syncError"
        }
        $lastSyncUtc = [datetime]::UtcNow
        Write-WatchdogLog "Results synchronized."
    }
    Save-State "online" "" $lastSyncUtc
} catch {
    Save-State "error" $_.Exception.Message $lastSyncUtc
    Write-WatchdogLog "ERROR: $($_.Exception.Message)"
}
Start-Sleep -Seconds $CheckIntervalSeconds
}
