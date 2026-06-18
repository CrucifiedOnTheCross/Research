param(
    [string]$RunsDir = "C:\Users\lab-bio\Research\runs"
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path -LiteralPath $RunsDir).Path
$records = Get-ChildItem -LiteralPath $root -Directory | ForEach-Object {
    $runPath = $_.FullName
    $runName = $_.Name
    $runState = "unknown"
    $statusPath = Join-Path $runPath "status.json"
    if (Test-Path -LiteralPath $statusPath) {
        try { $runState = (Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).state }
        catch { $runState = "invalid" }
    }
    Get-ChildItem -LiteralPath $runPath -File -Recurse | ForEach-Object {
        $relative = $_.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
        [PSCustomObject]@{
            relative = $relative
            length = $_.Length
            modified_utc = $_.LastWriteTimeUtc.ToString("o")
            run_state = $runState
        }
    }
}

@($records) | ConvertTo-Json -Compress
