[CmdletBinding()]
param(
    [string]$ProjectDir = "C:\Users\lab-bio\Research",
    [string]$DataDir = "C:\Datasets\isic2019"
)

$ErrorActionPreference = "Stop"
$logPath = Join-Path $ProjectDir "server-services.log"
function Write-ServiceLog([string]$Message) {
    "$(Get-Date -Format o) $Message" | Add-Content -LiteralPath $logPath -Encoding utf8
}

try {
    & docker info *> $null
    if ($LASTEXITCODE -ne 0) {
        $desktop = Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"
        if (Test-Path -LiteralPath $desktop) {
            Start-Process -FilePath $desktop -WindowStyle Hidden
            Write-ServiceLog "Docker Desktop start requested."
        }
        $ready = $false
        for ($attempt = 0; $attempt -lt 24; $attempt++) {
            Start-Sleep -Seconds 5
            & docker info *> $null
            if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        }
        if (-not $ready) { throw "Docker did not become ready within two minutes." }
    }

    $tensorboardRunning = & docker ps -q --filter "name=^/isic-tensorboard$" --filter "status=running"
    if (-not $tensorboardRunning) {
        & (Join-Path $ProjectDir "scripts\tensorboard-server.ps1") -ProjectDir $ProjectDir
        Write-ServiceLog "TensorBoard restored."
    }

    $queueStatePath = Join-Path $ProjectDir "experiment-queue-state.json"
    $queueComplete = $false
    if (Test-Path -LiteralPath $queueStatePath) {
        try {
            $queueState = Get-Content $queueStatePath -Raw | ConvertFrom-Json
            $queueComplete = [string]$queueState.status -eq "completed"
        } catch { }
    }
    if (-not $queueComplete) {
        $queueTask = Get-ScheduledTask -TaskName "ISIC Experiment Queue" -ErrorAction SilentlyContinue
        if (-not $queueTask) {
            & (Join-Path $ProjectDir "scripts\start-experiment-queue.ps1") `
                -ProjectDir $ProjectDir -DataDir $DataDir
            Write-ServiceLog "Experiment queue task registered."
        } elseif ($queueTask.State -ne "Running") {
            Start-ScheduledTask -TaskName "ISIC Experiment Queue"
            Write-ServiceLog "Experiment queue restarted."
        }
    }
    Write-ServiceLog "Server services healthy."
} catch {
    Write-ServiceLog "ERROR: $($_.Exception.Message)"
    throw
}
