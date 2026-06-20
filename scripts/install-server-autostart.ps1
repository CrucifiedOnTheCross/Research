[CmdletBinding()]
param(
    [string]$ProjectDir = "C:\Users\lab-bio\Research",
    [string]$DataDir = "C:\Datasets\isic2019",
    [string]$TaskName = "ISIC Server Services"
)

$ErrorActionPreference = "Stop"
$script = Join-Path $ProjectDir "scripts\ensure-server-services.ps1"
$arguments = @(
    "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
    "-WindowStyle", "Hidden", "-File", "`"$script`"",
    "-ProjectDir", "`"$ProjectDir`"", "-DataDir", "`"$DataDir`""
) -join " "
$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments `
    -WorkingDirectory $ProjectDir
$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$bootTrigger = New-ScheduledTaskTrigger -AtStartup
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $currentUser
$repeatTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
    -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
    -RestartCount 5 -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 4)
$principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType S4U `
    -RunLevel Limited

Register-ScheduledTask -TaskName $TaskName -Action $action `
    -Trigger @($bootTrigger, $logonTrigger, $repeatTrigger) -Settings $settings -Principal $principal `
    -Description "Restore Docker, TensorBoard and the ISIC experiment queue" -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State
