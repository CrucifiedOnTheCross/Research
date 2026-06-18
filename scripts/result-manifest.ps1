param(
    [string]$RunsDir = "C:\Users\lab-bio\Research\runs"
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path -LiteralPath $RunsDir).Path
$records = Get-ChildItem -LiteralPath $root -File -Recurse | ForEach-Object {
    $relative = $_.FullName.Substring($root.Length).TrimStart('\').Replace('\', '/')
    [PSCustomObject]@{
        relative = $relative
        length = $_.Length
        modified_utc = $_.LastWriteTimeUtc.ToString("o")
    }
}

@($records) | ConvertTo-Json -Compress
