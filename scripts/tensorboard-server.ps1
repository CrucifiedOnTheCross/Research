[CmdletBinding()]
param(
    [string]$ProjectDir = "C:\Users\lab-bio\Research",
    [int]$Port = 6006
)

$ErrorActionPreference = "Stop"
$runsDir = Join-Path $ProjectDir "runs"
$existing = & docker ps -aq --filter "name=^isic-tensorboard$"
if ($existing) { & docker rm -f isic-tensorboard | Out-Null }

$container = & docker run -d --name isic-tensorboard --restart unless-stopped `
    -p "0.0.0.0:${Port}:6006" -v "${runsDir}:/runs:ro" `
    --entrypoint tensorboard isic2019-trainer:latest `
    --logdir /runs --host 0.0.0.0 --port 6006 --reload_interval 15
if ($LASTEXITCODE -ne 0) { throw "Cannot start TensorBoard container" }
Write-Host "TensorBoard container started: $container"
Write-Host "TensorBoard URL: http://$($env:COMPUTERNAME):$Port/"
