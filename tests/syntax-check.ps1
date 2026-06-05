# Syntax check all WinRefresh scripts
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location ..

$files = @(
    'WinRefresh.ps1',
    'private/Logger.ps1',
    'private/Diagnostics.ps1',
    'private/Cleanup.ps1',
    'private/DecisionEngine.ps1',
    'scripts/Install-ScheduledTask.ps1',
    'scripts/Uninstall-ScheduledTask.ps1'
)

$errors = 0
$warnings = 0

foreach ($f in $files) {
    $path = Resolve-Path $f -ErrorAction SilentlyContinue
    if (-not $path) {
        Write-Host "  MISSING: $f" -ForegroundColor Red
        $errors++
        continue
    }

    $tokens = $null
    $parseErrors = $null
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $path.Path,
            [ref]$tokens,
            [ref]$parseErrors
        )
        if ($parseErrors.Count -gt 0) {
            Write-Host "  FAIL: $f" -ForegroundColor Red
            foreach ($e in $parseErrors) {
                Write-Host "    Line $($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Yellow
            }
            $errors++
        } elseif ($ast) {
            Write-Host "  OK: $f" -ForegroundColor Green
        }
    } catch {
        Write-Host "  FAIL: $f - $_" -ForegroundColor Red
        $errors++
    }
}

Pop-Location
Pop-Location

Write-Host ""
Write-Host "===================================="
Write-Host "Syntax Check: $($files.Count) files" -ForegroundColor Cyan
Write-Host "  Passed: $($files.Count - $errors)" -ForegroundColor Green
if ($errors -gt 0) {
    Write-Host "  Failed: $errors" -ForegroundColor Red
}
Write-Host "===================================="

exit $errors
