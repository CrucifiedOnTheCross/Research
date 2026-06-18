[CmdletBinding()]
param(
    [string]$ProjectDir = "C:\Users\lab-bio\Research",
    [string]$DataDir = "C:\Datasets\isic2019"
)

$runner = Join-Path $ProjectDir "scripts\run-experiment-queue.ps1"
$arguments = "-NoProfile -ExecutionPolicy Bypass -File $runner -ProjectDir $ProjectDir -DataDir $DataDir"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 14) `
    -RestartCount 20 -RestartInterval (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName "ISIC Experiment Queue" -Action $action -Trigger $trigger `
    -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName "ISIC Experiment Queue"
Write-Host "Experiment queue registered and waiting for the active run to finish."
