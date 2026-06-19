[CmdletBinding()]
param(
    [string]$ProjectDir = "C:\Users\lab-bio\Research",
    [string]$DataDir = "C:\Datasets\isic2019",
    [int]$Epochs = 3
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $ProjectDir

if (& docker ps -q --filter "name=queue-" --filter "status=running") {
    throw "A queue experiment is running. Benchmarks must not share the GPU with training."
}
if (& docker ps -q --filter "name=isic-trainer-" --filter "status=running") {
    throw "A training experiment is running. Benchmarks must run on an idle GPU."
}

$definition = Get-Content (Join-Path $ProjectDir "experiments\performance-benchmarks.json") -Raw |
    ConvertFrom-Json
$env:ISIC_DATA_DIR = $DataDir
$env:RUNS_DIR = Join-Path $ProjectDir "runs"
$env:MODEL_CACHE_DIR = Join-Path $ProjectDir ".cache\torch"
$results = [System.Collections.Generic.List[object]]::new()

foreach ($experiment in $definition.experiments) {
    $name = [string]$experiment.name
    $containerName = "benchmark-$($name.Replace('_','-'))"
    $arguments = @(
        "compose", "run", "--name", $containerName, "--rm", "trainer",
        "--config", "configs/train.yaml",
        "--set", "experiment.name=$name",
        "--set", "training.epochs=$Epochs",
        "--set", "training.early_stopping_patience=$Epochs",
        "--set", "training.checkpoint_interval=$Epochs"
    )
    foreach ($override in @($experiment.args)) {
        $arguments += @("--set", [string]$override)
    }

    $started = Get-Date
    & docker @arguments
    $exitCode = $LASTEXITCODE
    $run = Get-ChildItem (Join-Path $ProjectDir "runs") -Directory |
        Where-Object { $_.Name -like "*_$name" } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $throughput = $null
    if ($exitCode -eq 0 -and $run) {
        $metrics = @(Get-Content (Join-Path $run.FullName "metrics.jsonl") |
            ForEach-Object { $_ | ConvertFrom-Json })
        # Epoch one contains compilation and autotuning. Compare steady-state
        # throughput using all subsequent epochs.
        $steady = @($metrics | Select-Object -Skip 1)
        if ($steady.Count -gt 0) {
            $throughput = [math]::Round(
                ($steady.train_images_per_second | Measure-Object -Average).Average, 2
            )
        }
    }
    $results.Add([pscustomobject]@{
        name = $name
        exit_code = $exitCode
        train_images_per_second = $throughput
        wall_seconds = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        run_directory = if ($run) { $run.FullName } else { $null }
    })
}

$output = Join-Path $ProjectDir "performance-benchmark-results.json"
$results | ConvertTo-Json -Depth 4 | Set-Content $output -Encoding UTF8
$results | Sort-Object train_images_per_second -Descending | Format-Table -AutoSize
