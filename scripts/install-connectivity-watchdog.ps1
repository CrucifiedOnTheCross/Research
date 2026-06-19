[CmdletBinding()]
param(
    [string]$Server = "lab-bio@10.200.1.180",
    [string]$RemoteProject = "C:/Users/lab-bio/Research",
    [string]$LocalRuns = "",
    [int]$CheckIntervalMinutes = 2,
    [int]$SyncIntervalMinutes = 10,
    [string]$TaskName = "ISIC Research Connectivity"
)

$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($LocalRuns)) {
    $LocalRuns = Join-Path $PSScriptRoot "..\server-results"
}
$watchdog = (Resolve-Path (Join-Path $PSScriptRoot "connectivity-watchdog.ps1")).Path
$arguments = @(
    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden",
    "-File", "`"$watchdog`"", "-Server", "`"$Server`"",
    "-RemoteProject", "`"$RemoteProject`"", "-LocalRuns", "`"$LocalRuns`"",
    "-SyncIntervalMinutes", $SyncIntervalMinutes
) -join " "

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments -WorkingDirectory $PSScriptRoot
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes $CheckIntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Hours 1)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
    -LogonType Interactive -RunLevel Limited

# Replace a manually started tunnel so the managed process gets keepalive options.
foreach ($connection in @(Get-NetTCPConnection -LocalPort 6006 -State Listen -ErrorAction SilentlyContinue)) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($connection.OwningProcess)" -ErrorAction SilentlyContinue
    if ($process.Name -eq "ssh.exe" -and $process.CommandLine -like "*$Server*" -and
        $process.CommandLine -like "*6006:127.0.0.1:6006*") {
        Stop-Process -Id $connection.OwningProcess -Force -ErrorAction SilentlyContinue
    }
}

Stop-ScheduledTask -TaskName "ISIC Research Result Sync" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "ISIC Research Result Sync" -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action `
    -Trigger @($logonTrigger, $repeatTrigger) -Settings $settings -Principal $principal `
    -Description "Maintain TensorBoard SSH tunnel and synchronize ISIC results" -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 5
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State
