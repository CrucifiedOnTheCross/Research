[CmdletBinding()]
param(
    [string]$ProjectDir = "C:\Users\lab-bio\Research",
    [string]$DataDir = "C:\Datasets\isic2019"
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $ProjectDir
$queue = Get-Content (Join-Path $ProjectDir "experiments\queue.json") -Raw | ConvertFrom-Json
$statePath = Join-Path $ProjectDir "experiment-queue-state.json"
$logsDir = Join-Path $ProjectDir "queue-logs"
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

$completed = [System.Collections.Generic.List[string]]::new()
$failed = [System.Collections.Generic.List[object]]::new()
if (Test-Path $statePath) {
    $previous = Get-Content $statePath -Raw | ConvertFrom-Json
    foreach ($name in @($previous.completed)) { $completed.Add([string]$name) }
    foreach ($item in @($previous.failed)) { $failed.Add($item) }
}

function Save-State([string]$status, [string]$current = "") {
    [pscustomobject]@{
        protocol = $queue.protocol
        status = $status
        current = $current
        completed = @($completed)
        failed = @($failed)
        updated_utc = [datetime]::UtcNow.ToString("o")
    } | ConvertTo-Json -Depth 6 | Set-Content $statePath -Encoding UTF8
}

Save-State "waiting_for_active_anchor"
while (& docker ps -q --filter "name=isic-trainer-" --filter "status=running") {
    Start-Sleep -Seconds 60
}

$env:ISIC_DATA_DIR = $DataDir
$env:RUNS_DIR = Join-Path $ProjectDir "runs"
$env:MODEL_CACHE_DIR = Join-Path $ProjectDir ".cache\torch"
& docker compose build
if ($LASTEXITCODE -ne 0) { throw "Docker build failed before experiment queue" }

foreach ($experiment in $queue.experiments) {
    $name = [string]$experiment.name
    if ($completed.Contains($name)) { continue }
    Save-State "running" $name
    $containerName = "queue-$($name.Replace('_','-'))"
    $logPath = Join-Path $logsDir "$name.log"
    $arguments = @("compose", "run", "--name", $containerName, "trainer",
                   "--config", "configs/train.yaml", "--set", "experiment.name=$name")
    foreach ($override in $experiment.args) { $arguments += @("--set", [string]$override) }
    & docker @arguments 2>&1 | Tee-Object -FilePath $logPath
    $exitCode = $LASTEXITCODE
    if ($exitCode -eq 0) {
        $completed.Add($name)
        $finishedRun = Get-ChildItem (Join-Path $ProjectDir "runs") -Directory |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        $lastCheckpoint = Join-Path $finishedRun.FullName "last.pt"
        if (Test-Path $lastCheckpoint) { Remove-Item $lastCheckpoint -Force }
    } else {
        $failed.Add([pscustomobject]@{name=$name; exit_code=$exitCode; log=$logPath})
    }
    & docker rm -f $containerName 2>$null | Out-Null
    Save-State "between_experiments"
}

Save-State "completed"
