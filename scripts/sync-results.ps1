param(
    [string]$Server = "lab-bio@10.200.1.180",
    [string]$RemoteProject = "C:/Users/lab-bio/Research",
    [string]$LocalRuns = (Join-Path $PSScriptRoot "..\server-results"),
    [switch]$IncludeLastCheckpoint
)

$ErrorActionPreference = "Stop"
$localRoot = [System.IO.Path]::GetFullPath($LocalRuns)
New-Item -ItemType Directory -Force -Path $localRoot | Out-Null

$manifestCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$RemoteProject/scripts/result-manifest.ps1`" -RunsDir `"$RemoteProject/runs`""
$manifestJson = & ssh -o BatchMode=yes -o ConnectTimeout=15 $Server $manifestCommand
if ($LASTEXITCODE -ne 0) {
    throw "Cannot obtain result manifest from $Server"
}

$manifest = @($manifestJson | ConvertFrom-Json)
$completedRuns = @{}
foreach ($entry in $manifest) {
    if ($entry.relative -match '^([^/]+)/status\.json$') {
        $runName = $Matches[1]
        $statusText = & ssh -o BatchMode=yes $Server "type `"$RemoteProject\runs\$runName\status.json`""
        if ($LASTEXITCODE -eq 0) {
            try {
                $status = $statusText | ConvertFrom-Json
                $completedRuns[$runName] = $status.state -eq "completed"
            } catch {
                $completedRuns[$runName] = $false
            }
        }
    }
}

$alwaysSync = @(
    "config.json", "environment.json", "data_summary.json", "metrics.jsonl",
    "best_metrics.json", "status.json"
)
$downloaded = 0
$skipped = 0

foreach ($entry in $manifest) {
    $parts = $entry.relative -split '/', 2
    if ($parts.Count -ne 2) { continue }
    $runName, $fileWithinRun = $parts
    $leaf = Split-Path $fileWithinRun -Leaf
    $isCompleted = $completedRuns.ContainsKey($runName) -and $completedRuns[$runName]
    $wanted = $leaf -in $alwaysSync
    $wanted = $wanted -or ($isCompleted -and $fileWithinRun -eq "best.pt")
    $wanted = $wanted -or ($isCompleted -and $IncludeLastCheckpoint -and $fileWithinRun -eq "last.pt")
    if (-not $wanted) { continue }

    $destination = Join-Path $localRoot ($entry.relative.Replace('/', '\'))
    $destinationDir = Split-Path $destination -Parent
    New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
    if ((Test-Path -LiteralPath $destination) -and
        ((Get-Item -LiteralPath $destination).Length -eq [long]$entry.length)) {
        $skipped++
        continue
    }

    $partial = "$destination.part"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    $remotePath = "$Server`:$RemoteProject/runs/$($entry.relative)"
    & scp -q -o BatchMode=yes -o ConnectTimeout=15 $remotePath $partial
    if ($LASTEXITCODE -ne 0) {
        throw "Download failed: $($entry.relative)"
    }
    if ((Get-Item -LiteralPath $partial).Length -ne [long]$entry.length) {
        throw "Size check failed: $($entry.relative)"
    }
    Move-Item -LiteralPath $partial -Destination $destination -Force
    (Get-Item -LiteralPath $destination).LastWriteTimeUtc = [datetime]::Parse($entry.modified_utc).ToUniversalTime()
    $downloaded++
}

Write-Host "Result sync complete: downloaded=$downloaded unchanged=$skipped destination=$localRoot"
