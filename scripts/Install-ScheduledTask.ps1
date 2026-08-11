# Install-ScheduledTask.ps1 — WinRefresh installation script
# Usage: .\Install-ScheduledTask.ps1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Stop'

Write-Host "WinRefresh Installation" -ForegroundColor Green
Write-Host "=======================" -ForegroundColor Green
Write-Host ""

# 1. Detect admin rights (already checked by #Requires)

# 2. Check LanguageMode
if ($ExecutionContext.SessionState.LanguageMode -eq 'ConstrainedLanguage') {
    Write-Host "FATAL: ConstrainedLanguage mode detected. WinRefresh requires FullLanguage mode for P/Invoke." -ForegroundColor Red
    Write-Host "This is typically set by AppLocker or Device Guard. Please contact your administrator." -ForegroundColor Red
    exit 1
}

# 3. Check ExecutionPolicy
try {
    $machinePolicy = Get-ExecutionPolicy -Scope MachinePolicy -ErrorAction SilentlyContinue
    if ($machinePolicy -eq 'Restricted' -or $machinePolicy -eq 'AllSigned') {
        Write-Host "WARNING: MachinePolicy ExecutionPolicy is $machinePolicy." -ForegroundColor Yellow
        Write-Host "Task Scheduler uses -ExecutionPolicy Bypass, which may be overridden by MachinePolicy." -ForegroundColor Yellow
        Write-Host "If the scheduled task fails, run: Set-ExecutionPolicy -Scope MachinePolicy -ExecutionPolicy RemoteSigned" -ForegroundColor Yellow
    }
} catch {
    Write-Host "WARNING: Cannot read ExecutionPolicy — may be locked by group policy." -ForegroundColor Yellow
}

# 4. Check Task Scheduler service
$tsService = Get-Service -Name Schedule -ErrorAction SilentlyContinue
if (-not $tsService -or $tsService.Status -ne 'Running') {
    Write-Host "FATAL: Task Scheduler service is not running." -ForegroundColor Red
    exit 1
}

# 5. Check PowerShell version
if ($PSVersionTable.PSVersion.Major -lt 5 -or ($PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -lt 1)) {
    Write-Host "FATAL: PowerShell 5.1 or later required. Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    exit 1
}

# 6. Check if already installed
$installPath = "$env:ProgramFiles\WinRefresh"
$existingReg = Get-ItemProperty -Path "HKLM:\SOFTWARE\WinRefresh" -Name "InstallPath" -ErrorAction SilentlyContinue
if ($existingReg -or (Test-Path $installPath)) {
    Write-Host "WinRefresh appears to be already installed." -ForegroundColor Yellow
    $response = Read-Host "Do you want to overwrite? (y/n)"
    if ($response -notmatch '^[yY]') {
        Write-Host "Installation cancelled."
        exit 0
    }
    Write-Host "Overwriting existing installation..." -ForegroundColor Yellow
}

# 7. Copy files to Program Files
Write-Host "Copying files to $installPath..." -ForegroundColor Gray
$sourcePath = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceRoot = Split-Path -Parent $sourcePath

if (Test-Path $installPath) {
    Remove-Item $installPath -Recurse -Force -ErrorAction Stop
}
Copy-Item -Path $sourceRoot -Destination $installPath -Recurse -Force -ErrorAction Stop
Write-Host "  Done." -ForegroundColor Green

# 8. Create ProgramData directories
$dataPath = "$env:ProgramData\WinRefresh"
$logPath = "$dataPath\logs"
if (-not (Test-Path $logPath)) {
    New-Item -ItemType Directory -Force -Path $logPath | Out-Null
}
Write-Host "  Created $logPath" -ForegroundColor Gray

# 9. Register Event Log source
Write-Host "Registering Event Log source..." -ForegroundColor Gray
try {
    Remove-EventLog -Source "WinRefresh" -ErrorAction SilentlyContinue
} catch {}
try {
    New-EventLog -LogName Application -Source "WinRefresh" -ErrorAction Stop
    Write-Host "  Event Log source 'WinRefresh' registered." -ForegroundColor Green
} catch {
    Write-Host "  WARNING: Cannot register Event Log source: $_" -ForegroundColor Yellow
    Write-Host "  This is expected if the source already exists or on some locked-down systems." -ForegroundColor Gray
}

# 10. Write registry
Write-Host "Writing registry..." -ForegroundColor Gray
# Version — read from VERSION file (single source of truth, shared with main script)
$version = '1.0.0'
$versionFile = Join-Path $sourceRoot 'VERSION'
if (Test-Path $versionFile) {
    try { $version = (Get-Content $versionFile -Raw).Trim() } catch {}
}
if (-not (Test-Path "HKLM:\SOFTWARE\WinRefresh")) {
    New-Item -Path "HKLM:\SOFTWARE\WinRefresh" -Force | Out-Null
}
Set-ItemProperty -Path "HKLM:\SOFTWARE\WinRefresh" -Name "InstallPath" -Value $installPath -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\WinRefresh" -Name "Version" -Value $version -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\WinRefresh" -Name "InstallDate" -Value (Get-Date -Format 'o') -Force
Write-Host "  Done." -ForegroundColor Green

# 11. Register Scheduled Task
Write-Host "Registering Scheduled Task..." -ForegroundColor Gray

# Use SID (not username) for robustness against renames/domain changes
$currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$currentUserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

# Prefer pwsh.exe if available (PS 5.1 is the minimum, PS 7 is better)
$psExePath = (Get-Command powershell).Source
if (Get-Command pwsh -ErrorAction SilentlyContinue) {
    $psExePath = (Get-Command pwsh).Source
    Write-Host "  Using PowerShell 7: $psExePath" -ForegroundColor Gray
}

$taskName = "WinRefresh"
$taskAction = New-ScheduledTaskAction -Execute $psExePath `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$installPath\WinRefresh.ps1`""

$taskTrigger1 = New-ScheduledTaskTrigger -Daily -At "03:00"
$taskTrigger2 = New-ScheduledTaskTrigger -AtLogOn

$taskSettings = New-ScheduledTaskSettingsSet `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
    -AllowStartIfOnBatteries:$false `
    -Compatibility Win8

$taskPrincipal = New-ScheduledTaskPrincipal -UserId $currentUserSid `
    -LogonType Interactive `
    -RunLevel Highest

try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $taskName `
        -Action $taskAction `
        -Trigger $taskTrigger1, $taskTrigger2 `
        -Settings $taskSettings `
        -Principal $taskPrincipal `
        -Description "WinRefresh — Windows UI performance maintenance" `
        -ErrorAction Stop
    Write-Host "  Scheduled Task 'WinRefresh' registered:" -ForegroundColor Green
    Write-Host "    - Triggers: Daily 3:00 AM + At Logon" -ForegroundColor Gray
    Write-Host "    - Runs as: $currentUserName (Interactive, SID-based)" -ForegroundColor Gray
    Write-Host "    - PowerShell: $psExePath" -ForegroundColor Gray
    Write-Host "    - Execution time limit: 10 minutes" -ForegroundColor Gray
} catch {
    Write-Host "  ERROR: Failed to register scheduled task: $_" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "Installation complete!" -ForegroundColor Green
Write-Host ""
Write-Host "  Files installed to: $installPath" -ForegroundColor Gray
Write-Host "  Data directory:    $dataPath" -ForegroundColor Gray
Write-Host "  Logs:              $logPath" -ForegroundColor Gray
Write-Host ""
Write-Host "  To run manually:   Double-click WinRefresh.cmd in $installPath" -ForegroundColor Gray
Write-Host "  To uninstall:      Run scripts\Uninstall-ScheduledTask.ps1 in $installPath" -ForegroundColor Gray
