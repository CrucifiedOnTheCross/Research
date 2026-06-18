param(
    [string]$InputFile = "C:\Users\lab-bio\Research\gpu-telemetry\gpu-snapshots.csv",
    [int]$LastMinutes = 10
)

$cutoff = (Get-Date).AddMinutes(-$LastMinutes)
$rows = Import-Csv $InputFile | Where-Object {
    try { [datetime]$_.timestamp -ge $cutoff } catch { $false }
}

if (-not $rows) {
    throw "No GPU samples in the last $LastMinutes minute(s)."
}

function Get-Percentile([double[]]$Values, [double]$Percentile) {
    $sorted = @($Values | Sort-Object)
    $index = [math]::Min($sorted.Count - 1, [math]::Floor(($sorted.Count - 1) * $Percentile))
    return $sorted[$index]
}

$gpu = [double[]]@($rows.gpu_util_pct)
$memory = [double[]]@($rows.memory_used_mb)
$power = [double[]]@($rows.power_w)
$temperature = [double[]]@($rows.temperature_c)
$powerLimit = [double]$rows[-1].power_limit_w
$memoryTotal = [double]$rows[-1].memory_total_mb

[pscustomobject]@{
    window_minutes = $LastMinutes
    samples = $rows.Count
    from = $rows[0].timestamp
    to = $rows[-1].timestamp
    gpu_avg_pct = [math]::Round(($gpu | Measure-Object -Average).Average, 1)
    gpu_p05_pct = [math]::Round((Get-Percentile $gpu 0.05), 1)
    gpu_p50_pct = [math]::Round((Get-Percentile $gpu 0.50), 1)
    gpu_p95_pct = [math]::Round((Get-Percentile $gpu 0.95), 1)
    samples_gpu_ge_90_pct = [math]::Round(100 * @($gpu | Where-Object { $_ -ge 90 }).Count / $gpu.Count, 1)
    samples_gpu_lt_50_pct = [math]::Round(100 * @($gpu | Where-Object { $_ -lt 50 }).Count / $gpu.Count, 1)
    vram_avg_mb = [math]::Round(($memory | Measure-Object -Average).Average)
    vram_avg_pct = [math]::Round(100 * ($memory | Measure-Object -Average).Average / $memoryTotal, 1)
    power_avg_w = [math]::Round(($power | Measure-Object -Average).Average, 1)
    power_avg_limit_pct = [math]::Round(100 * ($power | Measure-Object -Average).Average / $powerLimit, 1)
    temperature_max_c = [math]::Round(($temperature | Measure-Object -Maximum).Maximum, 1)
} | ConvertTo-Json
