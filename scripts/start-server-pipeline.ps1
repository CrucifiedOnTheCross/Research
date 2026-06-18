[CmdletBinding()]
param(
    [string]$ProjectDir = "C:\Users\lab-bio\Research",
    [string]$DataDir = "C:\Datasets\isic2019"
)

$ErrorActionPreference = "Stop"
$script = Join-Path $ProjectDir "scripts\prepare-and-train-server.ps1"
$arguments = "-NoProfile -ExecutionPolicy Bypass -File $script -ProjectDir $ProjectDir -DataDir $DataDir"
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Days 7)
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $currentUser `
    -LogonType S4U -RunLevel Limited
Register-ScheduledTask -TaskName "ISIC Dataset and Training Pipeline" -Action $action `
    -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
Start-ScheduledTask -TaskName "ISIC Dataset and Training Pipeline"
Write-Host "Dataset/training pipeline started as Windows scheduled task."
