param(
    [int]$IntervalMinutes = 10,
    [string]$Server = "lab-bio@10.200.1.180",
    [string]$RemoteProject = "C:/Users/lab-bio/Research",
    [string]$LocalRuns = "",
    [switch]$IncludeBestCheckpoint,
    [switch]$IncludeLastCheckpoint
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($LocalRuns)) {
    $LocalRuns = Join-Path $PSScriptRoot "..\server-results"
}
$syncScript = (Resolve-Path (Join-Path $PSScriptRoot "sync-results.ps1")).Path
$arguments = @(
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$syncScript`"",
    "-Server", "`"$Server`"", "-RemoteProject", "`"$RemoteProject`"",
    "-LocalRuns", "`"$LocalRuns`""
)
if ($IncludeBestCheckpoint) { $arguments += "-IncludeBestCheckpoint" }
if ($IncludeLastCheckpoint) { $arguments += "-IncludeLastCheckpoint" }

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument ($arguments -join ' ')
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName "ISIC Research Result Sync" -Action $action `
    -Trigger $trigger -Settings $settings -Description "Pull ISIC experiment results over SSH" `
    -Force | Out-Null

Write-Host "Installed scheduled task 'ISIC Research Result Sync' (every $IntervalMinutes minutes)."
Write-Host "Results will appear in: $([System.IO.Path]::GetFullPath($LocalRuns))"
