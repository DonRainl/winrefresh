# Logger.ps1 unit tests
$ErrorActionPreference = 'Stop'
Push-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)
Push-Location ..

# Dot-source Logger
. ".\private\Logger.ps1"

$passed = 0
$failed = 0
$testLogDir = "$env:TEMP\WinRefresh_Test"

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
Write-Host "=== Logger.ps1 Unit Tests ===" -ForegroundColor Cyan
Write-Host ""

# Test 1: ConvertTo-Hashtable — flat object
Write-Host "[1] ConvertTo-Hashtable basic:" -ForegroundColor Cyan
$obj = [PSCustomObject]@{ key1 = 'val1'; key2 = 42 }
$ht = ConvertTo-Hashtable -InputObject $obj
Assert-Equal 'val1' $ht['key1'] "Flat object key1"
Assert-Equal 42 $ht['key2'] "Flat object key2"
Assert-True ($ht -is [hashtable]) "Result is hashtable"

# Test 2: ConvertTo-Hashtable — recursive nested
Write-Host "[2] ConvertTo-Hashtable recursive:" -ForegroundColor Cyan
$nested = [PSCustomObject]@{
    outer = 'top'
    inner = [PSCustomObject]@{ deep = 'bottom'; count = 99 }
}
$ht2 = ConvertTo-Hashtable -InputObject $nested
Assert-Equal 'top' $ht2['outer'] "Outer key"
Assert-True ($ht2['inner'] -is [hashtable]) "Inner is hashtable"
Assert-Equal 'bottom' $ht2['inner']['deep'] "Deep nested access"
Assert-Equal 99 $ht2['inner']['count'] "Deep nested count"

# Test 3: ConvertTo-Hashtable — null input
Write-Host "[3] ConvertTo-Hashtable edge cases:" -ForegroundColor Cyan
$ht3 = ConvertTo-Hashtable -InputObject $null
Assert-Equal 0 $ht3.Count "Null returns empty hashtable"

# Test 4: ConvertTo-Hashtable — empty object
$empty = [PSCustomObject]@{}
$ht4 = ConvertTo-Hashtable -InputObject $empty
Assert-Equal 0 $ht4.Count "Empty PSCustomObject returns empty hashtable"

# Test 5: Initialize-Logger creates directory
Write-Host "[4] Initialize-Logger:" -ForegroundColor Cyan
$origLogDir = $script:LogDir
$script:LogDir = "$testLogDir\logs"
if (Test-Path $script:LogDir) { Remove-Item $script:LogDir -Recurse -Force }
Initialize-Logger -MaxSizeMB 1 -Archives 2 -RetentionDays 1
Assert-True (Test-Path $script:LogDir) "Log directory created"
Assert-True ($script:CurrentLogFile -like "*$testLogDir*") "Log file path set"
Assert-Equal (1MB) $script:MaxLogSize "Max size set"
Assert-Equal 2 $script:MaxArchives "Max archives set"

# Test 6: Write-Log writes JSON Lines
Write-Host "[5] Write-Log JSON Lines:" -ForegroundColor Cyan
Write-Log -Level INFO -Operation "TestOp" -Message "Test message"
$content = Get-Content $script:CurrentLogFile -Encoding UTF8 -Raw
Assert-True ($content -like '*"lvl":"INFO"*') "Log contains INFO level"
Assert-True ($content -like '*"op":"TestOp"*') "Log contains operation"
Assert-True ($content -like '*"msg":"Test message"*') "Log contains message"
Assert-True ($content -like '*"ts":"*') "Log contains timestamp"

# Test 7: Write-Log — WARN level
Write-Log -Level WARN -Operation "TestWarn" -Message "Warning test"
$content = Get-Content $script:CurrentLogFile -Encoding UTF8 -Raw
Assert-True ($content -like '*"lvl":"WARN"*') "Log contains WARN level"

# Test 8: JSON Lines format (one line per entry)
Write-Host "[6] JSON Lines format:" -ForegroundColor Cyan
$lines = Get-Content $script:CurrentLogFile -Encoding UTF8
Assert-True ($lines.Count -ge 2) "At least 2 log entries"
foreach ($line in $lines) {
    try {
        $obj = $line | ConvertFrom-Json
        Assert-True ($obj.PSObject.Properties.Name -contains 'ts') "Line has ts key"
        Assert-True ($obj.PSObject.Properties.Name -contains 'lvl') "Line has lvl key"
        Assert-True ($obj.PSObject.Properties.Name -contains 'op') "Line has op key"
        Assert-True ($obj.PSObject.Properties.Name -contains 'msg') "Line has msg key"
    } catch {
        Write-Host "  FAIL: Invalid JSON on line: $line" -ForegroundColor Red
        $script:failed++
    }
    break  # Only check first line for keys
}

# Test 9: Get-WinRefreshLog query
Write-Host "[7] Get-WinRefreshLog:" -ForegroundColor Cyan
# @() wrapper handles PowerShell scalar-vs-array quirk
$logs = @(Get-WinRefreshLog)
Assert-True ($logs.Count -gt 0) "Query returns results (unfiltered)"
$logsInfo = @(Get-WinRefreshLog -Level INFO)
Assert-True ($logsInfo.Count -gt 0) "Query with INFO filter returns results"
Assert-True (@($logs | Where-Object { $_.op -eq 'TestOp' }).Count -gt 0) "Query finds TestOp entries"

# Cleanup test data
if (Test-Path $testLogDir) { Remove-Item $testLogDir -Recurse -Force }
$script:LogDir = $origLogDir

Pop-Location
Pop-Location

Write-Host ""
Write-Host "===================================="
Write-Host "Logger Tests: $($passed + $failed) total" -ForegroundColor Cyan
Write-Host "  Passed: $passed" -ForegroundColor Green
if ($failed -gt 0) {
    Write-Host "  Failed: $failed" -ForegroundColor Red
}
Write-Host "===================================="

exit $failed
