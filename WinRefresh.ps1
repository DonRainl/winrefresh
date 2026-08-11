# WinRefresh.ps1 — Windows UI lag auto-fixer
# Usage: .\WinRefresh.ps1 [-Manual] [-ForceExplorerRestart] [-ForceDwmRestart] [-OverrideCoolDown]
# Scheduled Task runs without -Manual (unattended mode)
# All PS 5.1 compatible — no ??, no -AsHashtable
#Requires -RunAsAdministrator

param(
    [switch]$Manual,
    [switch]$ForceExplorerRestart,
    [switch]$ForceDwmRestart,
    [switch]$OverrideCoolDown
)

$ErrorActionPreference = 'Stop'
$script:StartTime = Get-Date

# Version — read from VERSION file (single source of truth, shared with installer)
$script:Version = '1.0.0'
$versionFile = Join-Path $PSScriptRoot 'VERSION'
if (Test-Path $versionFile) {
    try { $script:Version = (Get-Content $versionFile -Raw).Trim() } catch {}
}

# ===== Startup Checks =====

# Check ConstrainedLanguage mode (Add-Type won't work)
if ($ExecutionContext.SessionState.LanguageMode -eq 'ConstrainedLanguage') {
    try {
        Write-EventLog -LogName Application -Source WinRefresh -EntryType Error `
            -EventId 1000 -Message "WinRefresh: ConstrainedLanguage mode — P/Invoke unavailable" `
            -ErrorAction Stop
    } catch {}
    Write-Host "FATAL: ConstrainedLanguage mode. P/Invoke (Add-Type) is unavailable." -ForegroundColor Red
    exit 98
}

# Determine mode
$IsManual = $Manual -or $ForceExplorerRestart -or $ForceDwmRestart

# Dot-source private modules
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
. "$scriptDir\private\Logger.ps1"
. "$scriptDir\private\Diagnostics.ps1"
. "$scriptDir\private\Cleanup.ps1"
. "$scriptDir\private\DecisionEngine.ps1"

# Initialize logger
$logConfig = @{}
$configPath = "$scriptDir\config\settings.json"
if (Test-Path $configPath) {
    try {
        $rawLogCfg = Get-Content $configPath -Raw -Encoding UTF8
        if ($rawLogCfg.Trim()) {
            $logCfgObj = $rawLogCfg | ConvertFrom-Json
            $logSection = $logCfgObj.logging
            if ($logSection) {
                $logConfig = ConvertTo-Hashtable -InputObject $logSection
            }
        }
    } catch {}
}
$logMaxSize = if ($null -ne $logConfig['max_log_size_mb']) { [int]$logConfig['max_log_size_mb'] } else { 10 }
$logArchives = if ($null -ne $logConfig['max_archives']) { [int]$logConfig['max_archives'] } else { 5 }
$logRetention = if ($null -ne $logConfig['archive_retention_days']) { [int]$logConfig['archive_retention_days'] } else { 30 }
Initialize-Logger -MaxSizeMB $logMaxSize -Archives $logArchives -RetentionDays $logRetention

Write-Log -Level INFO -Operation "Startup" -Message "WinRefresh v$script:Version starting, Manual=$IsManual, PID=$PID"

# ===== Concurrency Protocol =====

$ProgramData = "$env:ProgramData\WinRefresh"
$lockFile = Join-Path $ProgramData "running.lock"

# Ensure ProgramData directory exists
if (-not (Test-Path $ProgramData)) {
    New-Item -ItemType Directory -Force -Path $ProgramData | Out-Null
}

$mutexName = "Global\WinRefresh_Mutex"
$mutex = $null
$mutexAcquired = $false
$wroteOwnLock = $false

try {
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    try {
        $mutexAcquired = $mutex.WaitOne(5000)
    } catch [System.Threading.AbandonedMutexException] {
        Write-Log -Level WARN -Operation "Concurrency" -Message "Mutex abandoned — previous instance crashed, entering recovery"
        $mutexAcquired = $true
        # Mutex is already owned by this thread after AbandonedMutexException.
        # Do NOT re-create or re-acquire — that would double the acquire count.
    }

    if (-not $mutexAcquired) {
        Write-Log -Level WARN -Operation "Concurrency" -Message "Another instance is running — exiting"
        exit 0
    }

    # Read and handle existing lock
    if (Test-Path $lockFile) {
        $existingLock = $null
        try { $existingLock = Get-Content $lockFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}

        if ($existingLock -and $existingLock.pid) {
            $existingPid = [int]$existingLock.pid
            $proc = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Log -Level WARN -Operation "Concurrency" -Message "Instance PID=$existingPid still running — exiting"
                $mutex.ReleaseMutex()
                $mutexAcquired = $false
                exit 0
            } else {
                # PID dead — recovery mode
                Write-Log -Level WARN -Operation "Concurrency" -Message "Previous instance PID=$existingPid crashed at phase=$($existingLock.phase)"
                Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue
            }
        } else {
            # Stale lock with no PID
            Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue
        }
    }

    # Write new lock — atomic via temp file + Move-Item (NTFS atomic)
    $lockData = @{
        pid = $PID
        startTime = (Get-Date -Format 'o')
        phase = 'Starting'
        subphase = ''
        lastHeartbeat = (Get-Date -Format 'o')
        attempt = 1
    }
    $lockJson = $lockData | ConvertTo-Json -Compress
    $lockTemp = "$lockFile.tmp"
    Set-Content -Path $lockTemp -Value $lockJson -Encoding UTF8 -Force
    Move-Item -Path $lockTemp -Destination $lockFile -Force
    $wroteOwnLock = $true

    # Update lock helper — also atomic
    function Update-LockPhase {
        param([string]$Phase, [string]$Subphase = '')
        $lockData.phase = $Phase
        $lockData.subphase = $Subphase
        $lockData.lastHeartbeat = (Get-Date -Format 'o')
        $newJson = $lockData | ConvertTo-Json -Compress
        $tmp = "$lockFile.tmp"
        Set-Content -Path $tmp -Value $newJson -Encoding UTF8 -Force
        Move-Item -Path $tmp -Destination $lockFile -Force
    }

    # ===== Load Configuration =====
    $config = @{}
    if (Test-Path $configPath) {
        try {
            $rawConfig = Get-Content $configPath -Raw -Encoding UTF8
            if ($rawConfig.Trim()) {
                $cfgObj = $rawConfig | ConvertFrom-Json
                $config = ConvertTo-Hashtable -InputObject $cfgObj
            }
        } catch {
            Write-Log -Level WARN -Operation "Config" -Message "Config parse failed: $_. Using defaults."
        }
    }

    # ===== Diagnostics =====
    Update-LockPhase -Phase "Diagnostics"
    Write-Log -Level INFO -Operation "Main" -Message "Running diagnostics..."
    Write-Host "WinRefresh v$script:Version — Windows UI Performance Refresh" -ForegroundColor Green
    Write-Host "  Mode: $(if ($IsManual) { 'Manual' } else { 'Unattended (Task Scheduler)' })" -ForegroundColor Gray
    Write-Host ""

    # Recursively convert nested config sections (thresholds/cleanup are PSCustomObjects after ConvertFrom-Json)
    $thresholdConfig = if ($null -ne $config['thresholds']) { ConvertTo-Hashtable -InputObject $config['thresholds'] } else { @{} }
    $cleanupConfig = if ($null -ne $config['cleanup']) { ConvertTo-Hashtable -InputObject $config['cleanup'] } else { @{} }
    $diag = Get-SystemDiagnostics
    Write-Log -Level INFO -Operation "Diagnostics" -Message "Uptime: $($diag.Uptime.Days)d $($diag.Uptime.Hours)h, RAM: $($diag.TotalRAM_GB)GB"

    # Print key metrics
    Write-Host "  Uptime: $($diag.Uptime.Days)d $($diag.Uptime.Hours)h $($diag.Uptime.Minutes)m" -ForegroundColor Gray
    Write-Host "  RAM: $($diag.TotalRAM_GB) GB" -ForegroundColor Gray
    Write-Host "  Non-Paged Pool: $($diag.NonPagedPoolMB) MB" -ForegroundColor Gray
    Write-Host "  Total Handles: $($diag.TotalHandles) (threshold: $($diag.HandleThreshold))" -ForegroundColor Gray
    if ($diag.DwmMetrics) {
        Write-Host "  DWM: WS=$($diag.DwmMetrics.WS_MB)MB Handles=$($diag.DwmMetrics.Handles) FramesSkipped=$($diag.DwmMetrics.FramesSkipped)" -ForegroundColor Gray
    }
    if ($diag.ExplorerMetrics) {
        Write-Host "  Explorer: GDI=$($diag.ExplorerMetrics.GDI) USER=$($diag.ExplorerMetrics.USER) Handles=$($diag.ExplorerMetrics.Handles)" -ForegroundColor Gray
    }
    Write-Host "  User state: $($diag.NotificationState), Idle: $($diag.UserIdleSeconds)s" -ForegroundColor Gray
    Write-Host ""

    # ===== Decision =====
    Update-LockPhase -Phase "Decision"
    Write-Log -Level INFO -Operation "Main" -Message "Running decision engine..."
    $plan = Get-DecisionPlan -Diagnostics $diag -ConfigThresholds $thresholdConfig -IsManual $IsManual

    # ===== Level 1 Cleanup (always) =====
    Update-LockPhase -Phase "Level1Cleanup"
    Write-Log -Level INFO -Operation "Main" -Message "Executing Level 1 cleanup..."
    Invoke-Level1Cleanup -Config $cleanupConfig

    # ===== Level 2 Actions =====
    if ($plan.Level2Warnings.Count -gt 0) {
        Write-Host "Level 2 Warnings:" -ForegroundColor Yellow
        foreach ($w in $plan.Level2Warnings) {
            Write-Host "  - $w" -ForegroundColor Yellow
        }
    }

    # Explorer restart (manual mode only)
    if ($plan.ShouldRestartExplorer -or $ForceExplorerRestart) {
        Update-LockPhase -Phase "ExplorerRestart" -Subphase "Starting"
        if ($IsManual) {
            Write-Log -Level INFO -Operation "Main" -Message "Explorer needs restart — executing"
            $result = Invoke-ExplorerRestart
            Write-Log -Level INFO -Operation "Main" -Message "Explorer restart result: $result"
        } else {
            Write-Log -Level WARN -Operation "Main" -Message "Explorer needs restart (unattended — skipped)"
        }
    }

    # DWM restart (manual mode only)
    if ($plan.ShouldRestartDwm -or $ForceDwmRestart) {
        Update-LockPhase -Phase "DwmRestart" -Subphase "Starting"
        if ($IsManual) {
            Write-Log -Level INFO -Operation "Main" -Message "DWM needs restart — executing"
            $result = Invoke-DwmRestart -OverrideCoolDown ($OverrideCoolDown -or $ForceDwmRestart)
            Write-Log -Level INFO -Operation "Main" -Message "DWM restart result: $result"
        } else {
            Write-Log -Level WARN -Operation "Main" -Message "DWM needs restart (unattended — skipped)"
        }
    }

    # ===== Level 3 Warnings =====
    foreach ($w in $plan.Level3Warnings) {
        $severity = if ($w -match 'save work|reboot|restart system|critically') { 'CRITICAL' } else { 'WARN' }
        $condition = if ($w -match 'Non-Paged') { 'NonPagedPool' }
                     elseif ($w -match 'PTE') { 'PTE' }
                     elseif ($w -match 'handles' -or $w -match 'Handles') { 'TotalHandles' }
                     else { 'System' }
        Write-Level3Warning -Condition $condition -Advice $w -Severity $severity
    }

    # ===== Summary =====
    Write-Host ""
    Write-Host "=== WinRefresh Summary ===" -ForegroundColor Green
    foreach ($s in $plan.Summary) {
        Write-Host "  $s" -ForegroundColor Gray
    }
    Write-Host "Level 1 cleanup: completed" -ForegroundColor Green
    if ($plan.ShouldRestartExplorer) {
        Write-Host "Explorer restart: $(if ($IsManual) { 'executed' } else { 'skipped (unattended)' })" -ForegroundColor $(if ($IsManual) { 'Green' } else { 'Yellow' })
    }
    Write-Host "Duration: $([math]::Round(((Get-Date) - $script:StartTime).TotalSeconds, 1))s" -ForegroundColor Gray
    Write-Host ""

    Write-Log -Level INFO -Operation "Main" -Message "WinRefresh complete, duration=$([math]::Round(((Get-Date) - $script:StartTime).TotalSeconds,1))s"

} catch {
    Write-Log -Level CRITICAL -Operation "GlobalTrap" -Message "Unhandled exception: $_"
    Write-Host "FATAL ERROR: $_" -ForegroundColor Red
    exit 99
} finally {
    # Cleanup lock and mutex
    if ($wroteOwnLock -and (Test-Path $lockFile)) {
        Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue
    }
    if ($mutex -and $mutexAcquired) {
        try { $mutex.ReleaseMutex() } catch {}
    }
}
