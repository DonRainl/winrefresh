# Uninstall-ScheduledTask.ps1 — WinRefresh uninstallation script
# Copies itself to %TEMP% before removing Program Files
# Usage: .\Uninstall-ScheduledTask.ps1
#Requires -RunAsAdministrator

$ErrorActionPreference = 'Continue'

Write-Host "WinRefresh Uninstallation" -ForegroundColor Yellow
Write-Host "=========================" -ForegroundColor Yellow
Write-Host ""

$confirmation = Read-Host "This will completely remove WinRefresh. Continue? (y/n)"
if ($confirmation -notmatch '^[yY]') {
    Write-Host "Uninstallation cancelled."
    exit 0
}

# Check if WinRefresh is currently running before proceeding
try {
    $checkMutex = New-Object System.Threading.Mutex($false, "Global\WinRefresh_Mutex")
    if (-not $checkMutex.WaitOne(1000)) {
        Write-Host "WARNING: WinRefresh appears to be currently running." -ForegroundColor Yellow
        Write-Host "Please wait for it to finish, then retry uninstallation." -ForegroundColor Yellow
        exit 1
    }
    $checkMutex.ReleaseMutex()
    $checkMutex.Dispose()
} catch {
    # If we can't check, proceed with caution
}

# Self-copy to TEMP (so we can delete Program Files while running from it)
$tempScript = Join-Path $env:TEMP "WinRefresh_Uninstall.ps1"
if ($MyInvocation.MyCommand.Path -ne $tempScript) {
    Copy-Item -Path $MyInvocation.MyCommand.Path -Destination $tempScript -Force
    Write-Host "Relocating to TEMP for safe removal..." -ForegroundColor Gray
    Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$tempScript`"" -Verb RunAs -Wait
    Remove-Item -Path $tempScript -Force -ErrorAction SilentlyContinue
    exit $LASTEXITCODE
}

Write-Host "Removing WinRefresh..." -ForegroundColor Gray

# 1. Remove Scheduled Task
Write-Host "  Removing Scheduled Task..." -ForegroundColor Gray
try {
    Unregister-ScheduledTask -TaskName "WinRefresh" -Confirm:$false -ErrorAction Stop
    Write-Host "    Scheduled Task removed." -ForegroundColor Green
} catch {
    Write-Host "    WARNING: Cannot remove task: $_" -ForegroundColor Yellow
}

# 2. Remove Event Log source
Write-Host "  Removing Event Log source..." -ForegroundColor Gray
try {
    Remove-EventLog -Source "WinRefresh" -ErrorAction Stop
    Write-Host "    Event Log source removed." -ForegroundColor Green
} catch {
    Write-Host "    WARNING: Cannot remove Event Log: $_" -ForegroundColor Yellow
}

# 3. Remove Program Files
Write-Host "  Removing Program Files..." -ForegroundColor Gray
try {
    Remove-Item "$env:ProgramFiles\WinRefresh" -Recurse -Force -ErrorAction Stop
    Write-Host "    Program Files removed." -ForegroundColor Green
} catch {
    Write-Host "    WARNING: Cannot remove Program Files: $_" -ForegroundColor Yellow
}

# 4. Remove ProgramData
Write-Host "  Removing ProgramData..." -ForegroundColor Gray
try {
    Remove-Item "$env:ProgramData\WinRefresh" -Recurse -Force -ErrorAction Stop
    Write-Host "    ProgramData removed." -ForegroundColor Green
} catch {
    Write-Host "    WARNING: Cannot remove ProgramData: $_" -ForegroundColor Yellow
}

# 5. Remove registry
Write-Host "  Removing registry..." -ForegroundColor Gray
try {
    Remove-Item "HKLM:\SOFTWARE\WinRefresh" -Recurse -Force -ErrorAction Stop
    Write-Host "    Registry removed." -ForegroundColor Green
} catch {
    Write-Host "    WARNING: Cannot remove registry: $_" -ForegroundColor Yellow
}

# 6. Self-cleanup (TEMP copy already scheduled for removal in parent process)
Write-Host ""
Write-Host "Uninstallation complete." -ForegroundColor Green
Write-Host "  Logs and data have been removed." -ForegroundColor Gray
Write-Host "  The scheduled task has been removed — WinRefresh will no longer run automatically." -ForegroundColor Gray
