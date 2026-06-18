[CmdletBinding()]
param(
    [string]$DataDir = "C:\Datasets\isic2019",
    [string]$ProjectDir = "C:\Users\lab-bio\Research",
    [string]$Resume = ""
)

$ErrorActionPreference = "Stop"
Set-Location -LiteralPath $ProjectDir
if (-not (Test-Path -LiteralPath $DataDir -PathType Container)) {
    throw "ISIC data directory does not exist: $DataDir"
}

$env:ISIC_DATA_DIR = (Resolve-Path -LiteralPath $DataDir).Path
$env:RUNS_DIR = Join-Path $ProjectDir "runs"
$env:MODEL_CACHE_DIR = Join-Path $ProjectDir ".cache\torch"
$env:HOST_UID = "1000"
$env:HOST_GID = "1000"
New-Item -ItemType Directory -Force -Path $env:RUNS_DIR, $env:MODEL_CACHE_DIR | Out-Null

& docker compose build
if ($LASTEXITCODE -ne 0) { throw "Docker image build failed" }

$trainingArguments = @("--config", "configs/train.yaml")
if (-not [string]::IsNullOrWhiteSpace($Resume)) {
    $normalizedResume = $Resume.Replace('\', '/').TrimStart('/')
    $trainingArguments += @("--resume", "/workspace/runs/$normalizedResume")
}

$containerName = "isic-trainer-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$containerId = & docker compose run -d --name $containerName trainer @trainingArguments
if ($LASTEXITCODE -ne 0) { throw "Cannot start training container" }
$containerId = ([string]$containerId).Trim()
$containerId | Set-Content -LiteralPath (Join-Path $ProjectDir "last-container-id.txt")

Write-Host "Training started in detached container: $containerId"
Write-Host "Follow logs: ssh lab-bio@10.200.1.180 docker logs -f $containerId"
Write-Host "Results are synchronized automatically to the local server-results directory."
