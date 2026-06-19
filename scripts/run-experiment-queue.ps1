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

function Find-CompletedRun([string]$ExperimentName) {
    foreach ($directory in @(Get-ChildItem (Join-Path $ProjectDir "runs") -Directory |
            Sort-Object LastWriteTime -Descending)) {
        $configPath = Join-Path $directory.FullName "config.json"
        $statusPath = Join-Path $directory.FullName "status.json"
        if (-not (Test-Path $configPath) -or -not (Test-Path $statusPath)) { continue }
        try {
            $config = Get-Content $configPath -Raw | ConvertFrom-Json
            $status = Get-Content $statusPath -Raw | ConvertFrom-Json
            if ([string]$config.experiment.name -eq $ExperimentName -and
                [string]$status.state -eq "completed") {
                return $directory
            }
        } catch { continue }
    }
    return $null
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
    $containerName = "queue-$($name.Replace('_','-'))"
    $completedRun = Find-CompletedRun $name
    if ($completedRun) {
        if (-not $completed.Contains($name)) { $completed.Add($name) }
        $lastCheckpoint = Join-Path $completedRun.FullName "last.pt"
        if (Test-Path $lastCheckpoint) { Remove-Item $lastCheckpoint -Force }
        $staleContainer = & docker ps -aq --filter "name=^/$containerName$"
        if ($staleContainer) { & docker rm -f $staleContainer | Out-Null }
        Save-State "between_experiments"
        continue
    }

    $staleContainer = & docker ps -aq --filter "name=^/$containerName$"
    if ($staleContainer) { & docker rm -f $staleContainer | Out-Null }
    Save-State "running" $name
    $stdoutPath = Join-Path $logsDir "$name.stdout.log"
    $stderrPath = Join-Path $logsDir "$name.stderr.log"
    $arguments = @("compose", "run", "--name", $containerName, "trainer",
                   "--config", "configs/train.yaml", "--set", "experiment.name=$name")
    $overrides = @($experiment.args | ForEach-Object { [string]$_ })
    # One-view 224px runs keep effective optimizer batch 32 while avoiding the
    # overhead of a second microbatch and gradient-accumulation iteration.
    if ($overrides -contains "training.two_views=false") {
        $overrides += @("training.batch_size=32", "training.gradient_accumulation_steps=1")
    }
    foreach ($override in $overrides) { $arguments += @("--set", $override) }
    $process = Start-Process -FilePath (Get-Command docker.exe).Source `
        -ArgumentList $arguments -WorkingDirectory $ProjectDir -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath `
        -Wait -PassThru
    $exitCode = $process.ExitCode
    if ($exitCode -eq 0) {
        $completed.Add($name)
        $finishedRun = Find-CompletedRun $name
        if (-not $finishedRun) { throw "Container succeeded but completed run was not found: $name" }
        $lastCheckpoint = Join-Path $finishedRun.FullName "last.pt"
        if (Test-Path $lastCheckpoint) { Remove-Item $lastCheckpoint -Force }
    } else {
        $failed.Add([pscustomobject]@{
            name=$name; exit_code=$exitCode; stdout=$stdoutPath; stderr=$stderrPath
        })
    }
    & docker rm -f $containerName | Out-Null
    Save-State "between_experiments"
}

Save-State "completed"
