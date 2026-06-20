[CmdletBinding()]
param(
    [string]$Server = "lab-bio@10.200.1.180",
    [string]$RemoteProject = "C:/Users/lab-bio/Research",
    [string]$LocalRuns = "",
    [string]$TensorBoardUrl = "http://10.200.1.180:6006/",
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
    "-SyncIntervalMinutes", $SyncIntervalMinutes,
    "-CheckIntervalSeconds", ($CheckIntervalMinutes * 60),
    "-TensorBoardUrl", "`"$TensorBoardUrl`""
) -join " "

# Direct TensorBoard access replaces the old localhost SSH tunnel.
foreach ($connection in @(Get-NetTCPConnection -LocalPort 6006 -State Listen -ErrorAction SilentlyContinue)) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$($connection.OwningProcess)" -ErrorAction SilentlyContinue
    if ($process.Name -eq "ssh.exe" -and $process.CommandLine -like "*$Server*" -and
        $process.CommandLine -like "*6006:127.0.0.1:6006*") {
        Stop-Process -Id $connection.OwningProcess -Force -ErrorAction SilentlyContinue
    }
}

Stop-ScheduledTask -TaskName "ISIC Research Result Sync" -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName "ISIC Research Result Sync" -Confirm:$false -ErrorAction SilentlyContinue
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

# HKCU Run requires no administrator rights and reliably starts after the user
# signs in following a reboot. The watchdog itself remains alive, checks for
# connectivity periodically, and therefore handles networks appearing later.
$runKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runName = "ISICResearchConnectivity"
$runCommand = "powershell.exe $arguments"
Set-ItemProperty -Path $runKey -Name $runName -Value $runCommand -Type String

foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -like "*connectivity-watchdog.ps1*" -and
            $_.CommandLine -notlike "*install-connectivity-watchdog.ps1*" })) {
    Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
}
Start-Process -FilePath "powershell.exe" -ArgumentList $arguments `
    -WorkingDirectory $PSScriptRoot -WindowStyle Hidden | Out-Null
Start-Sleep -Seconds 5
[pscustomobject]@{
    AutoStart = "HKCU Run"
    RegistryName = $runName
    WatchdogStarted = $true
}
