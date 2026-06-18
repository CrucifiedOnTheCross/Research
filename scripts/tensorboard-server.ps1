[CmdletBinding()]
param(
    [string]$ProjectDir = "C:\Users\lab-bio\Research"
)

$ErrorActionPreference = "Stop"
$runsDir = Join-Path $ProjectDir "runs"
$existing = & docker ps -aq --filter "name=^isic-tensorboard$"
if ($existing) { & docker rm -f isic-tensorboard | Out-Null }

$container = & docker run -d --rm --name isic-tensorboard `
    -p "127.0.0.1:6006:6006" -v "${runsDir}:/runs:ro" `
    --entrypoint tensorboard isic2019-trainer:latest `
    --logdir /runs --host 0.0.0.0 --port 6006 --reload_interval 15
if ($LASTEXITCODE -ne 0) { throw "Cannot start TensorBoard container" }
Write-Host "TensorBoard container started: $container"
