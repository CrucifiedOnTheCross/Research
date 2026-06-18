[CmdletBinding()]
param(
    [string]$ProjectDir = "C:\Users\lab-bio\Research",
    [string]$DataDir = "C:\Datasets\isic2019"
)

$ErrorActionPreference = "Stop"
$progressPreference = "SilentlyContinue"
$statusPath = Join-Path $ProjectDir "pipeline-status.json"
$logPath = Join-Path $ProjectDir "pipeline.log"

function Write-PipelineStatus {
    param([string]$State, [string]$Message)
    [PSCustomObject]@{
        state = $State
        message = $Message
        updated_utc = [datetime]::UtcNow.ToString("o")
    } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
    "$(Get-Date -Format o) [$State] $Message" | Add-Content -LiteralPath $logPath -Encoding UTF8
}

try {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $drive = Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($DataDir).TrimEnd(':\'))
    if ($drive.Free -lt 25GB) {
        throw "At least 25 GB free space is required; available: $([math]::Round($drive.Free / 1GB, 1)) GB"
    }

    $baseUrl = "https://isic-challenge-data.s3.amazonaws.com/2019"
    $downloads = @(
        @{ Name = "ISIC_2019_Training_Input.zip"; Size = 9771618190 },
        @{ Name = "ISIC_2019_Training_GroundTruth.csv"; Size = 1291479 },
        @{ Name = "ISIC_2019_Training_Metadata.csv"; Size = 1214351 }
    )
    foreach ($download in $downloads) {
        $destination = Join-Path $DataDir $download.Name
        if (-not (Test-Path -LiteralPath $destination) -or
            (Get-Item -LiteralPath $destination).Length -ne $download.Size) {
            Write-PipelineStatus "downloading" $download.Name
            & curl.exe --fail --location --retry 20 --retry-delay 10 --continue-at - `
                --output $destination "$baseUrl/$($download.Name)"
            if ($LASTEXITCODE -ne 0) { throw "Download failed: $($download.Name)" }
        }
        if ((Get-Item -LiteralPath $destination).Length -ne $download.Size) {
            throw "Downloaded size mismatch: $($download.Name)"
        }
    }

    $imagesDir = Join-Path $DataDir "ISIC_2019_Training_Input"
    if (-not (Test-Path -LiteralPath $imagesDir -PathType Container)) {
        Write-PipelineStatus "extracting" "ISIC_2019_Training_Input.zip"
        & tar.exe -xf (Join-Path $DataDir "ISIC_2019_Training_Input.zip") -C $DataDir
        if ($LASTEXITCODE -ne 0) { throw "Dataset extraction failed" }
    }
    $imageCount = (Get-ChildItem -LiteralPath $imagesDir -Filter "*.jpg" -File).Count
    if ($imageCount -ne 25331) { throw "Expected 25331 images, found $imageCount" }
    Remove-Item -LiteralPath (Join-Path $DataDir "ISIC_2019_Training_Input.zip") -Force

    Write-PipelineStatus "building" "Docker image"
    & (Join-Path $ProjectDir "scripts\train-server.ps1") -DataDir $DataDir -ProjectDir $ProjectDir
    Write-PipelineStatus "training" "Training container started"
    & (Join-Path $ProjectDir "scripts\tensorboard-server.ps1") -ProjectDir $ProjectDir
    Write-PipelineStatus "running" "Training and TensorBoard are running"
} catch {
    Write-PipelineStatus "failed" $_.Exception.Message
    throw
}
