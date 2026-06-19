[CmdletBinding()]
param(
    [string]$Server = "lab-bio@10.200.1.180",
    [string]$RemoteProject = "C:/Users/lab-bio/Research",
    [string]$LocalRuns = "",
    [switch]$IncludeBestCheckpoint,
    [switch]$IncludeLastCheckpoint
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($LocalRuns)) {
    $LocalRuns = Join-Path $PSScriptRoot "..\server-results"
}
$localRoot = [System.IO.Path]::GetFullPath($LocalRuns)
New-Item -ItemType Directory -Force -Path $localRoot | Out-Null

$manifestCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$RemoteProject/scripts/result-manifest.ps1`" -RunsDir `"$RemoteProject/runs`""
$sshOptions = @(
    "-o", "BatchMode=yes", "-o", "ConnectTimeout=15",
    "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3"
)
$manifestJson = & ssh @sshOptions $Server $manifestCommand
if ($LASTEXITCODE -ne 0) {
    throw "Cannot obtain result manifest from $Server"
}

$decodedManifest = $manifestJson | ConvertFrom-Json
$manifest = [System.Collections.Generic.List[object]]::new()
foreach ($record in $decodedManifest) { $manifest.Add($record) }
Write-Verbose "manifest records=$($manifest.Count) raw_length=$(([string]$manifestJson).Length)"
$completedRuns = @{}
foreach ($entry in $manifest) {
    $runName = (([string]$entry.relative) -split '/', 2)[0]
    $completedRuns[$runName] = $entry.run_state -eq "completed"
}

$alwaysSync = @(
    "config.json", "environment.json", "data_summary.json", "metrics.jsonl",
    "best_metrics.json", "status.json"
)
$downloaded = 0
$skipped = 0

function Install-DownloadedFile([string]$Partial, [string]$Destination) {
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Destination) {
                Remove-Item -LiteralPath $Destination -Force
            }
            [System.IO.File]::Move($Partial, $Destination)
            return
        } catch {
            if ($attempt -eq 5) { throw }
            Start-Sleep -Seconds 1
        }
    }
}

foreach ($entry in $manifest) {
    $parts = $entry.relative -split '/', 2
    if ($parts.Count -ne 2) { continue }
    $runName, $fileWithinRun = $parts
    $leaf = Split-Path $fileWithinRun -Leaf
    $isCompleted = $completedRuns.ContainsKey($runName) -and $completedRuns[$runName]
    $isMutable = [string]$entry.run_state -eq "running"
    $wanted = $leaf -in $alwaysSync
    $wanted = $wanted -or ($isCompleted -and $IncludeBestCheckpoint -and $fileWithinRun -eq "best.pt")
    $wanted = $wanted -or ($isCompleted -and $IncludeLastCheckpoint -and $fileWithinRun -eq "last.pt")
    Write-Verbose "run=$runName file=$fileWithinRun state=$($entry.run_state) completed=$isCompleted wanted=$wanted"
    if (-not $wanted) { continue }

    $destination = Join-Path $localRoot ($entry.relative.Replace('/', '\'))
    $destinationDir = Split-Path $destination -Parent
    New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
    if (-not $isMutable -and (Test-Path -LiteralPath $destination) -and
        ((Get-Item -LiteralPath $destination).Length -eq [long]$entry.length)) {
        $skipped++
        continue
    }

    $partial = "$destination.part"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    $remotePath = "$Server`:$RemoteProject/runs/$($entry.relative)"
    & scp -q @sshOptions $remotePath $partial
    if ($LASTEXITCODE -ne 0) {
        throw "Download failed: $($entry.relative)"
    }
    # Files from an active run can grow after the manifest was generated. Exact
    # length is required only once a run is immutable/completed.
    if (-not $isMutable -and (Get-Item -LiteralPath $partial).Length -ne [long]$entry.length) {
        throw "Size check failed: $($entry.relative)"
    }
    Install-DownloadedFile $partial $destination
    (Get-Item -LiteralPath $destination).LastWriteTimeUtc = [datetime]::Parse($entry.modified_utc).ToUniversalTime()
    $downloaded++
}

# Keep a rolling local copy of the lightweight GPU telemetry. The remote file may
# grow during transfer; replacing it atomically still gives a consistent snapshot.
$telemetryDirectory = Join-Path $localRoot "gpu-telemetry"
$telemetryStamp = [datetime]::UtcNow.ToString("yyyyMMddTHHmmssZ")
$telemetryDestination = Join-Path $telemetryDirectory "gpu-snapshots-$telemetryStamp.csv"
$telemetryPartial = "$telemetryDestination.part"
New-Item -ItemType Directory -Force -Path $telemetryDirectory | Out-Null
Remove-Item -LiteralPath $telemetryPartial -Force -ErrorAction SilentlyContinue
& scp -q @sshOptions `
    "$Server`:$RemoteProject/gpu-telemetry/gpu-snapshots.csv" $telemetryPartial 2>$null
if ($LASTEXITCODE -eq 0) {
    Install-DownloadedFile $telemetryPartial $telemetryDestination
    Get-ChildItem $telemetryDirectory -Filter "gpu-snapshots-*.csv" |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 6 |
        Remove-Item -Force -ErrorAction SilentlyContinue
} else {
    Remove-Item -LiteralPath $telemetryPartial -Force -ErrorAction SilentlyContinue
    Write-Verbose "GPU telemetry is not available yet."
}

Write-Host "Result sync complete: downloaded=$downloaded unchanged=$skipped destination=$localRoot"
