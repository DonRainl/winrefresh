# Cleanup.ps1 — 3-level cleanup operations with safety checks
# Functions: Invoke-AtomicOperation, Invoke-Level1Cleanup, Invoke-ExplorerRestart, Invoke-DwmRestart

function Invoke-AtomicOperation {
    param([string]$OperationName, [scriptblock]$Action, [bool]$IsCritical = $false)
    try {
        Write-Log -Level INFO -Operation $OperationName -Message "Started"
        & $Action
        Write-Log -Level INFO -Operation $OperationName -Message "OK"
        return $true
    } catch [UnauthorizedAccessException] {
        Write-Log -Level WARN -Operation $OperationName -Message "Access denied: $_"
    } catch [System.IO.IOException] {
        Write-Log -Level WARN -Operation $OperationName -Message "File in use: $_"
    } catch {
        if ($IsCritical) { throw }
        Write-Log -Level ERROR -Operation $OperationName -Message "Failed: $_"
    }
    return $false
}

# ===== Level 1: Always Safe =====

function Clear-TempFiles {
    param([int]$MinAgeHours = 24, [long]$MinSizeMB = 500)
    $tempDir = [System.IO.Path]::GetTempPath()
    $cutoff = (Get-Date).AddHours(-$MinAgeHours)

    # Measure — single pass, skip reparse points to avoid infinite loops
    $totalSize = [long]0
    $oldFileList = [System.Collections.Generic.List[object]]::new()
    try {
        $allItems = Get-ChildItem -Path $tempDir -Recurse -File -ErrorAction SilentlyContinue `
            -Attributes !ReparsePoint
        foreach ($f in $allItems) {
            if ($f.LastWriteTime -lt $cutoff) {
                $totalSize += $f.Length
                $oldFileList.Add($f)
            }
        }
    } catch {
        # Fallback when -Attributes fails (permission denied, corrupted filesystem entries, etc.)
        $allItems = Get-ChildItem -Path $tempDir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -eq 0 }
        foreach ($f in $allItems) {
            if ($f.LastWriteTime -lt $cutoff) {
                $totalSize += $f.Length
                $oldFileList.Add($f)
            }
        }
    }

    if ($totalSize -lt ($MinSizeMB * 1MB)) {
        Write-Log -Level INFO -Operation "ClearTempFiles" -Message "Skipped: $([math]::Round($totalSize/1MB,1))MB < ${MinSizeMB}MB threshold"
        return
    }

    Write-Log -Level INFO -Operation "ClearTempFiles" -Message "Clearing $([math]::Round($totalSize/1MB,1))MB from $tempDir"
    $cleared = 0
    foreach ($f in $oldFileList) {
        try { Remove-Item -Path $f.FullName -Force -ErrorAction Stop; $cleared++ } catch {}
    }
    Write-Log -Level INFO -Operation "ClearTempFiles" -Message "OK: removed $cleared files"
}

function Clear-DnsCache {
    Invoke-AtomicOperation -OperationName "ClearDnsCache" -Action {
        Clear-DnsClientCache
    }
}

function Clear-BitsQueue {
    Invoke-AtomicOperation -OperationName "ClearBitsQueue" -Action {
        try {
            Get-BitsTransfer | Where-Object { $_.JobState -eq 'Transferred' } | Complete-BitsTransfer
            Get-BitsTransfer | Where-Object { $_.JobState -in @('Error','Cancelled') } | Remove-BitsTransfer
        } catch [System.Runtime.InteropServices.COMException] {
            # BITS service not running — expected, skip silently
        }
    }
}

function Clear-IconCache {
    Invoke-AtomicOperation -OperationName "ClearIconCache" -Action {
        # Resolve true System32 path: SysNative for 32-bit PS on 64-bit OS, else SystemDirectory
        $systemDir = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
            "$env:SystemRoot\SysNative"
        } else {
            [Environment]::SystemDirectory
        }
        $ie4u = Join-Path $systemDir "ie4uinit.exe"
        if (Test-Path $ie4u) {
            $proc = Start-Process -FilePath $ie4u -ArgumentList "-ClearIconCache" -NoNewWindow -PassThru
            if (-not $proc.WaitForExit(10000)) {
                Write-Log -Level WARN -Operation "ClearIconCache" -Message "ie4uinit.exe timed out after 10s, terminating"
                try { $proc.Kill() } catch {}
            }
        }
    }
}

function Clear-ThumbnailCache {
    param([string]$StatePath = "$env:ProgramData\WinRefresh\state.json", [int]$IntervalDays = 30)

    # Check if we cleared recently
    $lastClear = $null
    if (Test-Path $StatePath) {
        try {
            $state = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $lastClear = [DateTime]$state.ThumbnailCacheLastClear
        } catch {}
    }
    if ($lastClear -and ((Get-Date) - $lastClear).TotalDays -lt $IntervalDays) {
        Write-Log -Level INFO -Operation "ClearThumbnailCache" -Message "Skipped: last clear was $($lastClear.ToString('yyyy-MM-dd'))"
        return
    }

    # Read profiles directory from registry (may not be C:\Users on enterprise deployments)
    $profilesDir = "$env:SystemDrive\Users"
    try {
        $regProfiles = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" `
            -Name "ProfilesDirectory" -ErrorAction SilentlyContinue
        if ($regProfiles -and $regProfiles.ProfilesDirectory) {
            $profilesDir = $regProfiles.ProfilesDirectory
        }
    } catch {}

    $deleted = 0
    $skipped = 0
    $userDirs = Get-ChildItem -Path $profilesDir -Directory -ErrorAction SilentlyContinue
    foreach ($userDir in $userDirs) {
        $thumbPath = Join-Path $userDir.FullName "AppData\Local\Microsoft\Windows\Explorer"
        if (-not (Test-Path $thumbPath)) { continue }
        $thumbFiles = Get-ChildItem -Path $thumbPath -Filter "thumbcache_*.db" -ErrorAction SilentlyContinue
        foreach ($tf in $thumbFiles) {
            try {
                Remove-Item -Path $tf.FullName -Force -ErrorAction Stop
                $deleted++
            } catch {
                $skipped++
            }
        }
    }
    Write-Log -Level INFO -Operation "ClearThumbnailCache" -Message "OK: deleted $deleted, skipped $skipped (locked)"

    # Update state timestamp
    Update-ThumbnailClearTimestamp -StatePath $StatePath
}

function Update-ThumbnailClearTimestamp {
    param([string]$StatePath)
    $state = @{}
    if (Test-Path $StatePath) {
        try {
            $obj = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $state = ConvertTo-Hashtable -InputObject $obj
        } catch {}
    }
    $state['ThumbnailCacheLastClear'] = (Get-Date -Format 'o')
    $stateJson = $state | ConvertTo-Json -Compress
    Set-Content -Path $StatePath -Value $stateJson -Encoding UTF8 -Force
}

function Invoke-Level1Cleanup {
    param([hashtable]$Config = @{})
    # Null guard — PowerShell passes $null for explicitly-passed $null even when default is @{}
    if ($null -eq $Config) { $Config = @{} }
    $minAge = if ($null -ne $Config['temp_min_age_hours']) { [int]$Config['temp_min_age_hours'] } else { 24 }
    $minSize = if ($null -ne $Config['temp_min_size_mb']) { [long]$Config['temp_min_size_mb'] } else { 500 }
    $thumbInterval = if ($null -ne $Config['thumbnail_cache_interval_days']) { [int]$Config['thumbnail_cache_interval_days'] } else { 30 }

    Clear-TempFiles -MinAgeHours $minAge -MinSizeMB $minSize
    Clear-DnsCache
    Clear-BitsQueue
    Clear-IconCache
    Clear-ThumbnailCache -IntervalDays $thumbInterval
}

# ===== Level 2: User Presence + Confirmation Required =====

function Test-UserPresent {
    # Returns $true if user is present and NOT in a blocking state
    $state = Get-UserNotificationState
    Write-Log -Level INFO -Operation "TestUserPresent" -Message "NotificationState=$state"

    if ($state -in @('NOT_PRESENT','BUSY','D3D_FULL_SCREEN','PRESENTATION_MODE','QUNS_APP')) {
        Write-Log -Level WARN -Operation "TestUserPresent" -Message "Blocked: notification state is $state"
        return $false
    }

    $idle = Get-UserIdleSeconds
    Write-Log -Level INFO -Operation "TestUserPresent" -Message "IdleSeconds=$idle"
    if ($idle -gt 30) {
        Write-Log -Level WARN -Operation "TestUserPresent" -Message "Blocked: idle $idle seconds > 30"
        return $false
    }

    return $true
}

function Test-FileCopyInProgress {
    # Check for OperationStatusWindow — Explorer's file copy status window class
    # Uses FindWindow from the common WinRefresh.Win32Gui P/Invoke class (no dynamic Add-Type)
    try {
        $hwnd = [WinRefresh.Win32Gui]::FindWindow("OperationStatusWindow", $null)
        if ($hwnd -and $hwnd -ne [IntPtr]::Zero) {
            Write-Log -Level WARN -Operation "TestFileCopy" -Message "Blocked: file copy in progress"
            return $true
        }
    } catch {
        Write-Log -Level WARN -Operation "TestFileCopy" -Message "FindWindow failed: $_"
    }
    return $false
}

function Wait-Countdown {
    param([int]$Seconds = 15, [int]$CheckInterval = 3)
    Write-Host ""
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host "  WARNING: Explorer/DWM will be restarted" -ForegroundColor Yellow
    Write-Host "  Save any unsaved work. Screen may flicker." -ForegroundColor Yellow
    Write-Host "========================================" -ForegroundColor Yellow
    Write-Host ""

    for ($i = $Seconds; $i -gt 0; $i -= $CheckInterval) {
        $remaining = [math]::Min($CheckInterval, $i)
        Write-Host "Restarting in $i seconds... (press Ctrl+C to cancel)" -ForegroundColor Cyan
        Start-Sleep -Seconds $remaining

        # Re-check both user activity AND notification state (not just idle time)
        $idle = Get-UserIdleSeconds
        $notifState = Get-UserNotificationState
        if ($idle -gt 30 -or $notifState -in @('D3D_FULL_SCREEN', 'PRESENTATION_MODE', 'QUNS_APP')) {
            Write-Host "User state changed — restart cancelled" -ForegroundColor Yellow
            Write-Log -Level WARN -Operation "ExplorerRestart" -Message "Cancelled: user state changed during countdown (idle=$idle s, state=$notifState)"
            return $false
        }
    }
    return $true
}

function Invoke-ExplorerRestart {
    # Returns: 'restarted', 'blocked', 'skipped'
    if (-not (Test-UserPresent)) {
        Write-Log -Level WARN -Operation "ExplorerRestart" -Message "Blocked: user not present"
        return 'blocked'
    }
    if (Test-FileCopyInProgress) {
        Write-Host "File copy in progress — Explorer restart blocked" -ForegroundColor Yellow
        Write-Log -Level WARN -Operation "ExplorerRestart" -Message "Blocked: file copy in progress"
        return 'blocked'
    }

    if (-not (Wait-Countdown)) { return 'blocked' }

    Write-Log -Level WARN -Operation "ExplorerRestart" -Message "Starting safe restart"

    $currentSessionId = (Get-Process -Id $PID).SessionId
    $explorer = Get-Process -Name explorer -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $currentSessionId } | Select-Object -First 1
    if (-not $explorer) {
        Write-Log -Level WARN -Operation "ExplorerRestart" -Message "Explorer not running — attempting to start"
        Start-Process explorer.exe
        return 'restarted'
    }

    # Graceful close with timeout — correctly capture CloseMainWindow return value
    $closeSucceeded = $false
    try {
        $task = [System.Threading.Tasks.Task]::Run({
            return $explorer.CloseMainWindow()
        })
        $finished = $task.Wait(3000)

        if (-not $finished) {
            Write-Log -Level WARN -Operation "ExplorerRestart" -Message "CloseMainWindow timed out (window hung), forcing stop"
            Stop-Process -Id $explorer.Id -Force -ErrorAction SilentlyContinue
        } elseif (-not $task.Result) {
            Write-Log -Level WARN -Operation "ExplorerRestart" -Message "CloseMainWindow returned false (main window handle invalid)"
            Stop-Process -Id $explorer.Id -Force -ErrorAction SilentlyContinue
        } else {
            $closeSucceeded = $true
        }
    } catch {
        Write-Log -Level WARN -Operation "ExplorerRestart" -Message "CloseMainWindow exception: $_"
        Stop-Process -Id $explorer.Id -Force -ErrorAction SilentlyContinue
    }

    if ($closeSucceeded) {
        # Wait for actual exit
        if (-not $explorer.WaitForExit(3000)) {
            Write-Log -Level WARN -Operation "ExplorerRestart" -Message "WaitForExit timed out, forcing stop"
            Stop-Process -Id $explorer.Id -Force -ErrorAction SilentlyContinue
        }
    }

    # Session Manager auto-restarts Explorer
    Start-Sleep -Seconds 2
    $newExplorer = Get-Process -Name explorer -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $currentSessionId } | Select-Object -First 1
    if ($newExplorer) {
        Write-Log -Level INFO -Operation "ExplorerRestart" -Message "OK: Explorer restarted, PID=$($newExplorer.Id)"
    } else {
        Write-Log -Level ERROR -Operation "ExplorerRestart" -Message "Explorer did not auto-restart"
    }
    return 'restarted'
}

function Invoke-DwmRestart {
    param([bool]$OverrideCoolDown = $false, [string]$StatePath = "$env:ProgramData\WinRefresh\state.json")

    # Check cooldown
    if (-not $OverrideCoolDown) {
        $lastRestart = $null
        if (Test-Path $StatePath) {
            try {
                $obj = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                $lastRestart = [DateTime]$obj.DwmLastRestart
            } catch {}
        }
        if ($lastRestart -and ((Get-Date) - $lastRestart).TotalHours -lt 24) {
            $since = [math]::Round(((Get-Date) - $lastRestart).TotalHours, 1)
            Write-Log -Level WARN -Operation "DwmRestart" -Message "Cooldown: last restart was $since hours ago (< 24h)"
            Write-Host "DWM was restarted $since hours ago. 24h cooldown active. Use -OverrideCoolDown to bypass." -ForegroundColor Yellow
            return 'cooldown'
        }
    }

    if (-not (Test-UserPresent)) {
        Write-Log -Level WARN -Operation "DwmRestart" -Message "Blocked: user not present"
        return 'blocked'
    }
    if (Test-FileCopyInProgress) {
        Write-Log -Level WARN -Operation "DwmRestart" -Message "Blocked: file copy in progress"
        return 'blocked'
    }

    if (-not (Wait-Countdown)) { return 'blocked' }

    # Write cooldown timestamp BEFORE killing DWM (in case kill triggers display driver crash)
    $state = @{}
    if (Test-Path $StatePath) {
        try {
            $obj = Get-Content $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $state = ConvertTo-Hashtable -InputObject $obj
        } catch {}
    }
    $state['DwmLastRestart'] = (Get-Date -Format 'o')
    $stateJson = $state | ConvertTo-Json -Compress
    Set-Content -Path $StatePath -Value $stateJson -Encoding UTF8 -Force

    Write-Log -Level WARN -Operation "DwmRestart" -Message "Stopping DWM"
    # Stop only current session's DWM — not other users' sessions
    $currentSessionId = (Get-Process -Id $PID).SessionId
    $dwmProcesses = Get-Process -Name dwm -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $currentSessionId }
    foreach ($dwp in $dwmProcesses) {
        Stop-Process -Id $dwp.Id -Force -ErrorAction SilentlyContinue
    }

    # Verify DWM auto-restarted in current session (up to 10 seconds)
    $dwmRestarted = $false
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Seconds 1
        $dwm = Get-Process -Name dwm -ErrorAction SilentlyContinue |
            Where-Object { $_.SessionId -eq $currentSessionId } | Select-Object -First 1
        if ($dwm) {
            $dwmRestarted = $true
            Write-Log -Level INFO -Operation "DwmRestart" -Message "OK: DWM restarted, PID=$($dwm.Id)"
            break
        }
    }
    if (-not $dwmRestarted) {
        Write-Log -Level CRITICAL -Operation "DwmRestart" -Message "DWM did not auto-restart within 10 seconds — system may require reboot"
    }
    return 'restarted'
}

# ===== Level 3: Warnings Only =====

function Write-Level3Warning {
    param([string]$Condition, [string]$Advice, [ValidateSet('WARN','CRITICAL')][string]$Severity = 'WARN')

    $level = if ($Severity -eq 'CRITICAL') { 'CRITICAL' } else { 'WARN' }
    Write-Log -Level $level -Operation "Level3_$Condition" -Message $Advice

    $color = if ($Severity -eq 'CRITICAL') { 'Red' } else { 'Yellow' }
    Write-Host ""
    Write-Host "  [$Severity] $Condition : $Advice" -ForegroundColor $color
    Write-Host ""
}
