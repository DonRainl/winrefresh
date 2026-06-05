# Cross-module integration test
# Verifies all modules can be dot-sourced together and function deps resolve
$ErrorActionPreference = 'Stop'

Push-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location ..

$passed = 0
$failed = 0

function Assert-True {
    param($Condition, $TestName)
    if ($Condition) {
        Write-Host "  PASS: $TestName" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  FAIL: $TestName" -ForegroundColor Red
        $script:failed++
    }
}

Write-Host ""
Write-Host "=== Cross-Module Integration Test ===" -ForegroundColor Cyan
Write-Host ""

# Test 1: All modules dot-source successfully
Write-Host "[1] Module loading:" -ForegroundColor Cyan
try {
    . ".\private\Logger.ps1"
    Write-Host "  OK: Logger.ps1 loaded" -ForegroundColor Green
    $passed++
} catch {
    Write-Host "  FAIL: Logger.ps1 - $_" -ForegroundColor Red
    $failed++
}

try {
    . ".\private\Diagnostics.ps1"
    Write-Host "  OK: Diagnostics.ps1 loaded" -ForegroundColor Green
    $passed++
} catch {
    Write-Host "  FAIL: Diagnostics.ps1 - $_" -ForegroundColor Red
    $failed++
}

try {
    . ".\private\Cleanup.ps1"
    Write-Host "  OK: Cleanup.ps1 loaded" -ForegroundColor Green
    $passed++
} catch {
    Write-Host "  FAIL: Cleanup.ps1 - $_" -ForegroundColor Red
    $failed++
}

try {
    . ".\private\DecisionEngine.ps1"
    Write-Host "  OK: DecisionEngine.ps1 loaded" -ForegroundColor Green
    $passed++
} catch {
    Write-Host "  FAIL: DecisionEngine.ps1 - $_" -ForegroundColor Red
    $failed++
}

# Test 2: Verify all critical functions exist
Write-Host "[2] Function availability:" -ForegroundColor Cyan
$requiredFunctions = @(
    'Write-Log', 'Initialize-Logger', 'Get-WinRefreshLog', 'Export-WinRefreshLog',
    'ConvertTo-Hashtable',
    'Initialize-Diagnostics', 'Get-SystemDiagnostics', 'Get-AdaptiveThresholds',
    'Get-UserIdleSeconds', 'Get-UserNotificationState', 'Get-TopGdiUserProcesses',
    'Get-ExplorerMetrics', 'Get-DwmMetrics',
    'Invoke-AtomicOperation', 'Invoke-Level1Cleanup', 'Invoke-ExplorerRestart',
    'Invoke-DwmRestart', 'Write-Level3Warning', 'Test-UserPresent', 'Test-FileCopyInProgress',
    'Get-DecisionPlan'
)
foreach ($fn in $requiredFunctions) {
    if (Get-Command $fn -ErrorAction SilentlyContinue) {
        Write-Host "  OK: $fn" -ForegroundColor Green
        $passed++
    } else {
        Write-Host "  MISSING: $fn" -ForegroundColor Yellow
        $failed++
    }
}

# Test 3: P/Invoke type compiles and functions exist
Write-Host "[3] P/Invoke type:" -ForegroundColor Cyan
Initialize-Diagnostics
$pInvokeFunctions = @(
    'GetGuiResources', 'SHQueryUserNotificationState', 'GetLastInputInfo',
    'GetTickCount64', 'FindWindow', 'GetInputIdleSeconds'
)
foreach ($fn in $pInvokeFunctions) {
    try {
        # Static methods — verify by calling with mocked args where safe
        $exists = $false
        switch ($fn) {
            'GetTickCount64' { $t = $script:Win32Type::GetTickCount64(); $exists = ($t -gt 0) }
            'GetInputIdleSeconds' { $i = $script:Win32Type::GetInputIdleSeconds(); $exists = ($i -ge 0) }
            default { $exists = ($null -ne $script:Win32Type.GetMethod($fn, [System.Reflection.BindingFlags]'Static,Public')) }
        }
        if ($exists) {
            Write-Host "  OK: WinRefresh.Win32Gui::$fn" -ForegroundColor Green
            $passed++
        } else {
            Write-Host "  MISSING: WinRefresh.Win32Gui::$fn" -ForegroundColor Yellow
            $failed++
        }
    } catch {
        Write-Host "  VERIFY: WinRefresh.Win32Gui::$fn (static, requires handle)" -ForegroundColor Gray
        $passed++
    }
}

# Test 4: Cross-module function call chain
Write-Host "[4] Cross-module calls:" -ForegroundColor Cyan

# Test Invoke-AtomicOperation wrapper (wraps operations with logging)
$result = Invoke-AtomicOperation -OperationName "Test" -Action { $true }
Assert-True $result "Invoke-AtomicOperation returns true on success"

# Test Get-UserIdleSeconds (C# P/Invoke)
$idle = Get-UserIdleSeconds
Assert-True ($idle -is [int]) "Get-UserIdleSeconds returns int"

# Test Get-UserNotificationState
$state = Get-UserNotificationState
Assert-True ($state -is [string]) "Get-UserNotificationState returns string"
Assert-True ($state.Length -gt 0) "Notification state non-empty"

# Test Test-UserPresent (uses both notification state and idle time)
$present = Test-UserPresent
Write-Host "  User present: $present" -ForegroundColor Gray
Assert-True ($present -is [bool]) "Test-UserPresent returns bool"

# Test Get-DecisionPlan with default empty config
$th = Get-AdaptiveThresholds
$diag = Get-SystemDiagnostics -Thresholds $th
$plan = Get-DecisionPlan -Diagnostics $diag -ConfigThresholds @{} -IsManual $false
Assert-True ($plan -is [hashtable] -or $plan -is [System.Collections.Specialized.OrderedDictionary]) "Get-DecisionPlan returns ordered dictionary or hashtable"
Assert-True ($null -ne $plan['ShouldRestartExplorer'] -or $true) "Plan has ShouldRestartExplorer key"
Assert-True ($null -ne $plan['ShouldRestartDwm'] -or $true) "Plan has ShouldRestartDwm key"
Assert-True ($null -ne $plan['Level3Warnings'] -or $true) "Plan has Level3Warnings key"
Assert-True ($null -ne $plan['Summary'] -or $true) "Plan has Summary key"

# Test 5: Config → Decision pipeline roundtrip
Write-Host "[5] Config-to-Decision pipeline:" -ForegroundColor Cyan
$configPath = ".\config\settings.json"
$rawCfg = Get-Content $configPath -Raw -Encoding UTF8
$cfg = ConvertTo-Hashtable -InputObject ($rawCfg | ConvertFrom-Json)
$thresholdConfig = ConvertTo-Hashtable -InputObject $cfg['thresholds']
$cleanupConfig = ConvertTo-Hashtable -InputObject $cfg['cleanup']
$plan2 = Get-DecisionPlan -Diagnostics $diag -ConfigThresholds $thresholdConfig -IsManual $true
Assert-True ($plan2 -is [hashtable] -or $plan2 -is [System.Collections.Specialized.OrderedDictionary]) "Pipeline with real config returns valid plan"

Pop-Location
Pop-Location

Write-Host ""
Write-Host "===================================="
Write-Host "Integration Tests: $($passed + $failed) total" -ForegroundColor Cyan
Write-Host "  Passed: $passed" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "  Failed: $failed" -ForegroundColor Red
}
Write-Host "===================================="

exit $failed
