[CmdletBinding()]
param(
    [string]$ProjectDir = "C:\Users\lab-bio\Research",
    [string]$DataDir = "C:\Datasets\isic2019"
)

$ErrorActionPreference = "Stop"
$script = Join-Path $ProjectDir "scripts\prepare-and-train-server.ps1"
$stdout = Join-Path $ProjectDir "pipeline-stdout.log"
$stderr = Join-Path $ProjectDir "pipeline-stderr.log"
$arguments = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$script`"",
    "-ProjectDir", "`"$ProjectDir`"", "-DataDir", "`"$DataDir`""
)
$process = Start-Process -FilePath "powershell.exe" -ArgumentList ($arguments -join ' ') `
    -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$process.Id | Set-Content -LiteralPath (Join-Path $ProjectDir "pipeline.pid")
Write-Host "Dataset/training pipeline started, PID=$($process.Id)"
