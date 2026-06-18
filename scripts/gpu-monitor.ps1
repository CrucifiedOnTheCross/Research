param(
    [string]$OutputDirectory = "C:\Users\lab-bio\Research\gpu-telemetry",
    [int]$IntervalSeconds = 5
)

$ErrorActionPreference = "Continue"
$null = New-Item -ItemType Directory -Path $OutputDirectory -Force
$outputFile = Join-Path $OutputDirectory "gpu-snapshots.csv"
$errorFile = Join-Path $OutputDirectory "gpu-monitor-errors.log"

if (-not (Test-Path $outputFile)) {
    'timestamp,gpu_name,gpu_util_pct,memory_util_pct,memory_used_mb,memory_total_mb,power_w,power_limit_w,temperature_c,sm_clock_mhz,memory_clock_mhz,pcie_gen,pcie_width' | Set-Content -Path $outputFile -Encoding utf8
}

while ($true) {
    try {
        # Keep one nvidia-smi process alive. On this Windows host a fresh process
        # takes several seconds to initialize, which would distort the interval.
        & nvidia-smi `
            --query-gpu=timestamp,name,utilization.gpu,utilization.memory,memory.used,memory.total,power.draw,power.limit,temperature.gpu,clocks.sm,clocks.mem,pcie.link.gen.current,pcie.link.width.current `
            --format=csv,noheader,nounits `
            --loop=$IntervalSeconds 2>> $errorFile | ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_)) {
                    $_ | Add-Content -Path $outputFile -Encoding utf8
                }
            }
        "$(Get-Date -Format o) nvidia-smi exited with code $LASTEXITCODE; restarting." | Add-Content -Path $errorFile -Encoding utf8
    } catch {
        "$(Get-Date -Format o) $($_.Exception.Message)" | Add-Content -Path $errorFile -Encoding utf8
    }
    Start-Sleep -Seconds 2
}
