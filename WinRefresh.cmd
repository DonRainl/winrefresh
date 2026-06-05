@echo off
setlocal
title WinRefresh

:: Ensure admin rights — forward arguments on elevation
:: Uses High Mandatory Level SID check (works without Server service)
whoami /groups | findstr /c:"S-1-16-12288" >nul 2>&1
if %errorlevel% neq 0 (
    echo WinRefresh requires Administrator privileges.
    echo Requesting elevation...
    powershell -Command "Start-Process cmd -WorkingDirectory \"%~dp0\" -ArgumentList '/c \"%~f0\" %*' -Verb RunAs"
    exit /b
)

:: Try PowerShell 7 first
where pwsh >nul 2>&1
if %errorlevel% equ 0 (
    pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinRefresh.ps1" -Manual %*
    goto :done
)

:: Fallback to Windows PowerShell 5.1
where powershell >nul 2>&1
if %errorlevel% equ 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinRefresh.ps1" -Manual %*
    goto :done
)

echo ERROR: PowerShell not found.
pause
exit /b 1

:done
endlocal
