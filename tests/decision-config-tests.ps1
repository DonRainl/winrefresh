# DecisionEngine + Config loading combined tests
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location ..

# Dot-source modules
. ".\private\Logger.ps1"
. ".\private\DecisionEngine.ps1"

$passed = 0
$failed = 0

function Assert-Equal {
    param($Expected, $Actual, $TestName)
    if ($Expected -eq $Actual) {
        Write-Host "  PASS: $TestName" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "  FAIL: $TestName" -ForegroundColor Red
        Write-Host "    Expected: $Expected" -ForegroundColor Yellow
        Write-Host "    Actual:   $Actual" -ForegroundColor Yellow
        $script:failed++
    }
}

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
Write-Host "=== DecisionEngine + Config Tests ===" -ForegroundColor Cyan
Write-Host ""

# ===== Mock Diagnostic Data =====

function New-MockDiagnostic {
    param(
        $TopGuiProcesses = @(),
        $TotalHandles = 25000,
        $HandleThreshold = 50000,
        $NonPagedPoolMB = 512,
        $DwmMetrics = $null,
        $ExplorerMetrics = $null,
        $FreeSystemPTE_MB = 2048,
        $PteThreshold = 512MB,
        $GpuVram = @(),
        $ShellExtensionCount = 30,
        $Uptime = $null
    )
    return [PSCustomObject]@{
        TopGuiProcesses     = $TopGuiProcesses
        TotalHandles        = $TotalHandles
        HandleThreshold     = $HandleThreshold
        NonPagedPoolMB      = $NonPagedPoolMB
        DwmMetrics          = $DwmMetrics
        ExplorerMetrics     = $ExplorerMetrics
        FreeSystemPTE_MB    = $FreeSystemPTE_MB
        PteThreshold        = $PteThreshold
        GpuVram             = $GpuVram
        ShellExtensionCount = $ShellExtensionCount
        Uptime              = $Uptime
    }
}

# ===== Test 0: Uptime check =====
Write-Host "[0] Uptime check:" -ForegroundColor Cyan
$diag0 = New-MockDiagnostic -Uptime (New-TimeSpan -Days 45)
$plan0 = Get-DecisionPlan -Diagnostics $diag0
Assert-True (($plan0.Summary -join ' ') -like '*System uptime high: 45 days*') "Summary mentions high uptime"

# ===== Test 1: All metrics normal → no actions =====
Write-Host "[1] All normal — no actions:" -ForegroundColor Cyan
$diag = New-MockDiagnostic
$plan = Get-DecisionPlan -Diagnostics $diag
Assert-True (-not $plan.ShouldRestartExplorer) "No explorer restart needed"
Assert-True (-not $plan.ShouldRestartDwm) "No DWM restart needed"
Assert-True ($plan.Level2Warnings.Count -eq 0) "No Level 2 warnings"
Assert-True ($plan.Level3Warnings.Count -eq 0) "No Level 3 warnings"

# ===== Test 2: High GDI process detected =====
Write-Host "[2] High GDI process:" -ForegroundColor Cyan
$highGdiProc = [PSCustomObject]@{
    ProcessName = 'chrome'
    Id = 9999
    GDI = 9500
    USER = 500
    Total = 10000
}
$diag2 = New-MockDiagnostic -TopGuiProcesses @($highGdiProc)
$plan2 = Get-DecisionPlan -Diagnostics $diag2 -IsManual $true
Assert-True ($plan2.Level2Warnings.Count -gt 0) "Level 2 warning for high GDI process"
Assert-True (($plan2.Level2Warnings -join ' ') -like '*chrome*') "Warning mentions process name"

# ===== Test 3: Explorer GDI high → restart needed =====
Write-Host "[3] Explorer GDI high:" -ForegroundColor Cyan
$explorerHigh = [PSCustomObject]@{
    ProcessName = 'explorer'
    Id = 1000
    GDI = 9500
    USER = 2000
    Total = 11500
}
$diag3 = New-MockDiagnostic -TopGuiProcesses @($explorerHigh)
$plan3 = Get-DecisionPlan -Diagnostics $diag3 -IsManual $true
Assert-True $plan3.ShouldRestartExplorer "Explorer restart flagged"

# ===== Test 4: Non-Paged Pool critical =====
Write-Host "[4] Non-Paged Pool critical:" -ForegroundColor Cyan
$diag4 = New-MockDiagnostic -NonPagedPoolMB 3000
$plan4 = Get-DecisionPlan -Diagnostics $diag4
Assert-True ($plan4.Level3Warnings.Count -gt 0) "Level 3 warning for NPP"
Assert-True (($plan4.Level3Warnings -join ' ') -like '*3000*') "Warning mentions NPP value"

# ===== Test 5: Total handles high =====
Write-Host "[5] Total handles high:" -ForegroundColor Cyan
$diag5 = New-MockDiagnostic -TotalHandles 80000 -HandleThreshold 50000
$plan5 = Get-DecisionPlan -Diagnostics $diag5
Assert-True ($plan5.Level3Warnings.Count -gt 0) "Level 3 warning for handles"
Assert-True (($plan5.Level3Warnings -join ' ') -like '*80000*') "Warning mentions handle count"

# ===== Test 6: DWM issues =====
Write-Host "[6] DWM issues:" -ForegroundColor Cyan
$dwmBad = [PSCustomObject]@{ WS_MB = 2048; Handles = 8000; FramesSkipped = 15 }
$diag6 = New-MockDiagnostic -DwmMetrics $dwmBad
$plan6 = Get-DecisionPlan -Diagnostics $diag6 -IsManual $true
Assert-True $plan6.ShouldRestartDwm "DWM restart flagged"
Assert-True (($plan6.Summary -join ' ') -like '*FramesSkipped*') "Summary mentions frames skipped"

# ===== Test 6b: DWM threads high =====
Write-Host "[6b] DWM threads high:" -ForegroundColor Cyan
$dwmHighThreads = [PSCustomObject]@{ WS_MB = 200; Handles = 1000; Threads = 120; FramesSkipped = 0 }
$diag6b = New-MockDiagnostic -DwmMetrics $dwmHighThreads
$plan6b = Get-DecisionPlan -Diagnostics $diag6b -IsManual $true
Assert-True $plan6b.ShouldRestartDwm "DWM restart flagged on high threads"
Assert-True (($plan6b.Summary -join ' ') -like '*Threads=120*') "Summary mentions DWM threads"

# ===== Test 7: Explorer GDI threshold (metric 5) =====
Write-Host "[7] Explorer GDI separate metric:" -ForegroundColor Cyan
$expHigh = [PSCustomObject]@{ Id = 1000; GDI = 9200; USER = 500; Handles = 2000; WS_MB = 100 }
$diag7 = New-MockDiagnostic -ExplorerMetrics $expHigh
$plan7 = Get-DecisionPlan -Diagnostics $diag7 -IsManual $true
Assert-True $plan7.ShouldRestartExplorer "Explorer restart from separate metric"

# ===== Test 7b: Explorer handles high =====
Write-Host "[7b] Explorer handles high:" -ForegroundColor Cyan
$expHighHandles = [PSCustomObject]@{ Id = 1000; GDI = 2000; USER = 500; Handles = 6000; Threads = 50; WS_MB = 100 }
$diag7b = New-MockDiagnostic -ExplorerMetrics $expHighHandles
$plan7b = Get-DecisionPlan -Diagnostics $diag7b -IsManual $true
Assert-True $plan7b.ShouldRestartExplorer "Explorer restart flagged on high handles"
Assert-True (($plan7b.Summary -join ' ') -like '*Handles=6000*') "Summary mentions Explorer handles"

# ===== Test 7c: Explorer threads high =====
Write-Host "[7c] Explorer threads high:" -ForegroundColor Cyan
$expHighThreads = [PSCustomObject]@{ Id = 1000; GDI = 2000; USER = 500; Handles = 2000; Threads = 200; WS_MB = 100 }
$diag7b = New-MockDiagnostic -ExplorerMetrics $expHighThreads
$plan7b = Get-DecisionPlan -Diagnostics $diag7b -IsManual $true
Assert-True $plan7b.ShouldRestartExplorer "Explorer restart flagged on high threads"
Assert-True (($plan7b.Summary -join ' ') -like '*Threads=200*') "Summary mentions Explorer threads"

# ===== Test 7d: Explorer working set high =====
Write-Host "[7d] Explorer WS_MB high:" -ForegroundColor Cyan
$expHighWs = [PSCustomObject]@{ Id = 1000; GDI = 2000; USER = 500; Handles = 2000; Threads = 50; WS_MB = 1200 }
$diag7c = New-MockDiagnostic -ExplorerMetrics $expHighWs
$plan7c = Get-DecisionPlan -Diagnostics $diag7c -IsManual $true
Assert-True $plan7c.ShouldRestartExplorer "Explorer restart flagged on high working set"
Assert-True (($plan7c.Summary -join ' ') -like '*WS=1200MB*') "Summary mentions Explorer memory"

# ===== Test 8: PTE critical =====
Write-Host "[8] PTE critical low:" -ForegroundColor Cyan
$diag8 = New-MockDiagnostic -FreeSystemPTE_MB 100 -PteThreshold 512MB
$plan8 = Get-DecisionPlan -Diagnostics $diag8
Assert-True ($plan8.Level3Warnings.Count -gt 0) "Level 3 warning for PTE"
Assert-True (($plan8.Level3Warnings -join ' ') -like '*save work*reboot*') "Warning suggests reboot"

# ===== Test 9: Shell extensions warning =====
Write-Host "[9] Shell extensions high:" -ForegroundColor Cyan
$diag9 = New-MockDiagnostic -ShellExtensionCount 80
$plan9 = Get-DecisionPlan -Diagnostics $diag9
Assert-True (($plan9.Summary -join ' ') -like '*Shell extension count*') "Summary mentions shell extensions"

# ===== Test 10: GPU VRAM diagnostic only =====
Write-Host "[10] GPU VRAM diagnostic-only:" -ForegroundColor Cyan
$gpu = [PSCustomObject]@{ Instance = 'gpu_0'; DedicatedMB = 2048 }
$diag10 = New-MockDiagnostic -GpuVram @($gpu)
$plan10 = Get-DecisionPlan -Diagnostics $diag10
Assert-True (($plan10.Summary -join ' ') -like '*GPU VRAM*gpu_0*') "Summary mentions GPU VRAM"
Assert-True ($plan10.Level3Warnings.Count -eq 0) "No Level 3 warnings from GPU VRAM (diagnostic only)"

# ===== Test 11: Unattended mode downgrades =====
Write-Host "[11] Unattended mode:" -ForegroundColor Cyan
$expHigh2 = [PSCustomObject]@{ Id = 1000; GDI = 9200; USER = 500; Handles = 2000; WS_MB = 100 }
$diag11 = New-MockDiagnostic -ExplorerMetrics $expHigh2
$plan11 = Get-DecisionPlan -Diagnostics $diag11 -IsManual $false
Assert-True (-not $plan11.ShouldRestartExplorer) "Explorer restart downgraded in unattended"
Assert-True (($plan11.Level2Warnings -join ' ') -like '*unattended*') "Warning mentions unattended skip"

# ===== Test 12: Custom thresholds from config =====
Write-Host "[12] Custom threshold config:" -ForegroundColor Cyan
$customTh = @{
    gdi_per_process = 5000
    non_paged_pool_mb = 1000
}
$diag12 = New-MockDiagnostic -NonPagedPoolMB 1500
$plan12 = Get-DecisionPlan -Diagnostics $diag12 -ConfigThresholds $customTh
Assert-True ($plan12.Level3Warnings.Count -gt 0) "Custom NPP threshold triggers warning at 1500MB"

# ===== Test 13: handle_threshold from config (not adaptive) =====
Write-Host "[13] Handle threshold override:" -ForegroundColor Cyan
$diag13 = New-MockDiagnostic -TotalHandles 40000 -HandleThreshold 50000
$plan13 = Get-DecisionPlan -Diagnostics $diag13 -ConfigThresholds @{ handle_threshold = 30000 }
Assert-True ($plan13.Level3Warnings.Count -gt 0) "Custom handle threshold triggers with 40000>30000"

# ===== Test 14: $null / 0 truthiness safety =====
Write-Host "[14] Null safety:" -ForegroundColor Cyan
$diag14 = New-MockDiagnostic -TotalHandles $null -HandleThreshold 50000
$plan14 = Get-DecisionPlan -Diagnostics $diag14
Assert-True ($plan14.Level3Warnings.Count -eq 0) "Null handles does NOT trigger false warning"

$diag15 = New-MockDiagnostic -TotalHandles 0 -HandleThreshold 50000
$plan15 = Get-DecisionPlan -Diagnostics $diag15
Assert-True ($plan15.Level3Warnings.Count -eq 0) "Zero handles does NOT trigger warning (below threshold)"

# ===== Config Loading Tests =====
Write-Host ""
Write-Host "[15] Config loading:" -ForegroundColor Cyan

# Test 15a: Valid config file
$configPath = ".\config\settings.json"
Assert-True (Test-Path $configPath) "settings.json exists"

try {
    $rawCfg = Get-Content $configPath -Raw -Encoding UTF8
    $cfgObj = $rawCfg | ConvertFrom-Json
    $cfg = ConvertTo-Hashtable -InputObject $cfgObj
    Assert-True ($cfg -is [hashtable]) "Config loaded as hashtable"
    Assert-True ($null -ne $cfg['thresholds']) "Thresholds section exists"
    Assert-True ($cfg['thresholds'] -is [hashtable]) "Thresholds is hashtable (recursive)"
    Assert-True ($null -ne $cfg['cleanup']) "Cleanup section exists"
    Assert-True ($cfg['cleanup'] -is [hashtable]) "Cleanup is hashtable (recursive)"
    Assert-True ($null -ne $cfg['logging']) "Logging section exists"
    Assert-True ($cfg['logging'] -is [hashtable]) "Logging is hashtable (recursive)"
    Write-Host "  PASS: Config recursive conversion verified" -ForegroundColor Green
    $script:passed++
} catch {
    Write-Host "  FAIL: Config loading failed: $_" -ForegroundColor Red
    $script:failed++
}

# Test 15b: Nested access works
$gdiVal = $cfg['thresholds']['gdi_per_process']
Assert-Equal 9000 $gdiVal "Nested hashtable access: gdi_per_process"

# Test 15c: Null handle_threshold means adaptive
Assert-True ($null -eq $cfg['thresholds']['handle_threshold']) "handle_threshold is null (adaptive)"

Pop-Location
Pop-Location

Write-Host ""
Write-Host "===================================="
Write-Host "Decision+Config Tests: $($passed + $failed) total" -ForegroundColor Cyan
Write-Host "  Passed: $passed" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "  Failed: $failed" -ForegroundColor Red
}
Write-Host "===================================="

exit $failed
