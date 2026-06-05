# WinRefresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a PowerShell-based Windows maintenance toolchain (10 files) that diagnoses and safely fixes UI lag caused by GDI/USER object leaks, kernel pool exhaustion, DWM issues, and handle leaks — without requiring a reboot.

**Architecture:** Modular PowerShell scripts separated by responsibility: Logger (all I/O), Diagnostics (9-metric collection + P/Invoke), Cleanup (3-level safe operations), DecisionEngine (threshold comparison + dual-mode routing), and WinRefresh.ps1 (orchestration + concurrency). Install/Uninstall scripts handle system integration. Zero external dependencies — pure PowerShell 5.1+ with Windows API P/Invoke.

**Tech Stack:** PowerShell 5.1/7.x, .NET Framework 4.5+ (built-in), Windows API (user32.dll, shell32.dll, kernel32.dll P/Invoke), Task Scheduler, Windows Event Log

**PS 5.1 Compatibility Note:** All code uses PS 5.1-compatible syntax only. The `??` operator and `-AsHashtable` parameter are PS 6+/7+ features and are NOT used. A `ConvertTo-Hashtable` helper function is provided for PSObject→hashtable conversion.

---

## File Responsibility Map

| File | Responsibility | Depends On |
|------|---------------|------------|
| `config/settings.json` | User-overridable thresholds (optional, all have adaptive defaults) | — |
| `private/Logger.ps1` | JSON Lines file logging, Event Log (summary), rotation, fallback | `config/settings.json` (log path) |
| `private/Diagnostics.ps1` | 9 diagnostic metrics, P/Invoke signatures, adaptive thresholds | `private/Logger.ps1` |
| `private/Cleanup.ps1` | Level 1 safe cleanup, Level 2 Explorer/DWM restart, user presence checks | `private/Logger.ps1` |
| `private/DecisionEngine.ps1` | Threshold comparison, dual-mode routing (unattended/manual), decision output | `private/Diagnostics.ps1`, `private/Cleanup.ps1`, `private/Logger.ps1` |
| `WinRefresh.ps1` | Main orchestration: mutex, lock, config loading, execution order | All `private/*.ps1` |
| `WinRefresh.cmd` | User double-click launcher (PS7 → PS5.1 fallback) | `WinRefresh.ps1` |
| `scripts/Install-ScheduledTask.ps1` | Installation: copy files, register task, create Event Log source | — |
| `scripts/Uninstall-ScheduledTask.ps1` | Uninstallation: remove task, files, registry, self-cleanup from %TEMP% | — |
| `README.md` | User documentation | — |

---

### Task 1: Configuration Template

**Files:**
- Create: `E:\project\windows-refresh\config\settings.json`

- [ ] **Step 1: Create config directory and settings.json**

```powershell
New-Item -ItemType Directory -Force -Path "E:\project\windows-refresh\config"
```

- [ ] **Step 2: Write settings.json with documented defaults**

```json
{
    "_comment": "WinRefresh configuration — all values are OVERRIDES. Omit any key (or set to null) to use adaptive defaults.",
    "thresholds": {
        "gdi_per_process": 9000,
        "user_per_process": 9000,
        "non_paged_pool_mb": 2048,
        "dwm_working_set_mb": 1024,
        "dwm_handles": 5000,
        "explorer_gdi": 9000,
        "handle_threshold": null,
        "shell_extensions_count": 50
    },
    "cleanup": {
        "temp_min_age_hours": 24,
        "temp_min_size_mb": 500,
        "thumbnail_cache_interval_days": 30,
        "dwm_cooldown_hours": 24
    },
    "logging": {
        "max_log_size_mb": 10,
        "max_archives": 5,
        "archive_retention_days": 30
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add config/settings.json
git commit -m "feat: add WinRefresh configuration template"
```

---

### Task 2: Logger Module

**Files:**
- Create: `E:\project\windows-refresh\private\Logger.ps1`

- [ ] **Step 1: Create private directory**

```powershell
New-Item -ItemType Directory -Force -Path "E:\project\windows-refresh\private"
```

- [ ] **Step 2: Write Logger.ps1 — full implementation**

```powershell
# Logger.ps1 — JSON Lines logging with Event Log integration and rotation
# Functions: Write-Log, Get-WinRefreshLog, Export-WinRefreshLog, ConvertTo-Hashtable

# PS 5.1-compatible PSCustomObject → Hashtable conversion (replaces -AsHashtable from PS 6+)
# RECURSIVE: nested PSCustomObjects are converted to nested hashtables
function ConvertTo-Hashtable {
    param([Parameter(Mandatory)][object]$InputObject)
    $ht = @{}
    if ($null -eq $InputObject) { return $ht }
    foreach ($prop in $InputObject.PSObject.Properties) {
        if ($prop.Value -is [System.Management.Automation.PSCustomObject]) {
            $ht[$prop.Name] = ConvertTo-Hashtable -InputObject $prop.Value
        } else {
            $ht[$prop.Name] = $prop.Value
        }
    }
    return $ht
}

$script:LogDir = "$env:ProgramData\WinRefresh\logs"
$script:FallbackLog = "$env:TEMP\WinRefresh_Fallback.log"
$script:CurrentLogFile = $null
$script:MaxLogSize = 10MB
$script:MaxArchives = 5
$script:ArchiveRetentionDays = 30

function Initialize-Logger {
    param([int]$MaxSizeMB = 10, [int]$Archives = 5, [int]$RetentionDays = 30)
    $script:MaxLogSize = $MaxSizeMB * 1MB
    $script:MaxArchives = $Archives
    $script:ArchiveRetentionDays = $RetentionDays
    if (-not (Test-Path $script:LogDir)) {
        New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
    }
    $script:CurrentLogFile = Join-Path $script:LogDir "winrefresh.log"
}

function Write-Log {
    param(
        [ValidateSet('DEBUG','INFO','WARN','ERROR','CRITICAL')]
        [string]$Level = 'INFO',
        [string]$Operation = '',
        [string]$Message = ''
    )
    if (-not $script:CurrentLogFile) { Initialize-Logger }

    $entry = [ordered]@{
        ts  = (Get-Date -Format 'o')
        lvl = $Level
        op  = $Operation
        msg = $Message
    }

    # Write to JSON Lines file — use File.AppendAllText to avoid BOM-per-line in PS 5.1
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    try {
        $json = $entry | ConvertTo-Json -Compress
        [System.IO.File]::AppendAllText($script:CurrentLogFile, $json + [Environment]::NewLine, $utf8NoBom)
    } catch {
        try { [System.IO.File]::AppendAllText($script:FallbackLog, $json + [Environment]::NewLine, $utf8NoBom) } catch {}
    }

    # Write WARN+ to Event Log (summary only, 32766 byte limit)
    if ($Level -in @('WARN','ERROR','CRITICAL')) {
        $eventLevel = switch ($Level) { 'WARN' { 2 } 'ERROR' { 1 } 'CRITICAL' { 1 } }
        $summary = "[$Level] $Operation : $Message"
        if ($summary.Length -gt 32766) { $summary = $summary.Substring(0, 32763) + '...' }
        try {
            Write-EventLog -LogName Application -Source "WinRefresh" -EventId 1000 `
                -EntryType $([System.Diagnostics.EventLogEntryType]$eventLevel) `
                -Message $summary -ErrorAction Stop
        } catch [System.InvalidOperationException] {
            # Source not registered — this is expected before install, skip silently
        } catch {
            try { [System.IO.File]::AppendAllText($script:FallbackLog, "[EventLogFail] $json" + [Environment]::NewLine, $utf8NoBom) } catch {}
        }
    }

    # Check rotation
    Rotate-LogIfNeeded
}

function Rotate-LogIfNeeded {
    if (-not (Test-Path $script:CurrentLogFile)) { return }
    $size = (Get-Item $script:CurrentLogFile).Length
    if ($size -lt $script:MaxLogSize) { return }

    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $archiveName = "winrefresh_$timestamp.jsonl"
    $archivePath = Join-Path $script:LogDir $archiveName
    try {
        Move-Item -Path $script:CurrentLogFile -Destination $archivePath -Force -ErrorAction Stop
        # Remove old archives
        $archives = Get-ChildItem -Path $script:LogDir -Filter "winrefresh_*.jsonl" |
            Sort-Object LastWriteTime -Descending
        if ($archives.Count -gt $script:MaxArchives) {
            $archives | Select-Object -Skip $script:MaxArchives | Remove-Item -Force
        }
        # Remove archives older than 30 days
        $cutoff = (Get-Date).AddDays(-$script:ArchiveRetentionDays)
        Get-ChildItem -Path $script:LogDir -Filter "winrefresh_*.jsonl" |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        # Rotation failed — continue with new log (old log will stay, we just append)
    }
}

function Get-WinRefreshLog {
    param(
        [DateTime]$After,
        [DateTime]$Before,
        [ValidateSet('DEBUG','INFO','WARN','ERROR','CRITICAL')]
        [string[]]$Level
    )
    $files = @()
    if (Test-Path $script:LogDir) {
        $files = Get-ChildItem -Path $script:LogDir -Filter "*.jsonl" | Sort-Object LastWriteTime
    }
    $results = @()
    foreach ($file in $files) {
        Get-Content $file.FullName -Encoding UTF8 | ForEach-Object {
            try {
                $obj = $_ | ConvertFrom-Json
                if ($After -and [DateTime]$obj.ts -lt $After) { return }
                if ($Before -and [DateTime]$obj.ts -gt $Before) { return }
                if ($Level -and $obj.lvl -notin $Level) { return }
                $results += $obj
            } catch {}
        }
    }
    $results
}

function Export-WinRefreshLog {
    param(
        [ValidateSet('Csv','Json')]
        [string]$Format = 'Csv',
        [string]$OutputPath
    )
    $logs = Get-WinRefreshLog
    if (-not $OutputPath) {
        $OutputPath = Join-Path $env:TEMP "WinRefresh_Export.$($Format.ToLower())"
    }
    switch ($Format) {
        'Csv' { $logs | Export-Csv -Path $OutputPath -NoTypeInformation }
        'Json' { $logs | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8 }
    }
    Write-Host "Exported $($logs.Count) entries to $OutputPath"
}
```

- [ ] **Step 3: Commit**

```bash
git add private/Logger.ps1
git commit -m "feat: add Logger module with JSON Lines logging, Event Log, rotation"
```

---

### Task 3: Diagnostics Module (P/Invoke + 9 Metrics)

**Files:**
- Create: `E:\project\windows-refresh\private\Diagnostics.ps1`

- [ ] **Step 1: Write diagnostics with embedded P/Invoke type — all C# in one class**

```powershell
# Diagnostics.ps1 — 9 diagnostic metrics collection with P/Invoke
# Functions: Initialize-Diagnostics, Get-SystemDiagnostics, Get-AdaptiveThresholds

# Compile P/Invoke type once
$script:Win32Type = $null

function Initialize-Diagnostics {
    if ($script:Win32Type) { return }

    # Check if type already exists from a previous run
    $existing = [System.AppDomain]::CurrentDomain.GetAssemblies() |
        ForEach-Object { try { $_.GetTypes() } catch { @() } } |
        Where-Object { $_.FullName -eq 'WinRefresh.Win32Gui' }
    if ($existing) {
        $script:Win32Type = $existing[0]
        return
    }

    $code = @'
using System;
using System.Runtime.InteropServices;

namespace WinRefresh {
    public class Win32Gui {
        // GetGuiResources — per-process GDI/USER object counts
        // hProcess needs PROCESS_QUERY_INFORMATION (0x0400)
        [DllImport("user32.dll", SetLastError = true)]
        public static extern int GetGuiResources(IntPtr hProcess, int uiFlags);
        // uiFlags: 0 = GR_GDIOBJECTS, 1 = GR_USEROBJECTS

        // SHQueryUserNotificationState — user notification/activity state
        [DllImport("shell32.dll")]
        public static extern int SHQueryUserNotificationState(out int pquns);
        // Returns: 1=NOT_PRESENT, 2=BUSY, 3=RUNNING_D3D_FULL_SCREEN,
        //          4=PRESENTATION_MODE, 5=ACCEPTS_NOTIFICATIONS, 6=QUIET_TIME

        // GetLastInputInfo — ticks since last user input
        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool GetLastInputInfo(out LASTINPUTINFO plii);

        // GetTickCount64 — 64-bit tick count (Vista+)
        // NOT Environment.TickCount64 — that property doesn't exist in .NET Framework 4.x
        [DllImport("kernel32.dll")]
        public static extern ulong GetTickCount64();

        // FindWindow — locate window by class name (used for OperationStatusWindow detection)
        // CharSet.Unicode ensures FindWindowW is called (Explorer registers Unicode window classes)
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

        // GetInputIdleSeconds — safe idle-time calculation with 32-bit wraparound handling
        // Moved into C# because PowerShell's [uint] casting throws OverflowException on negative values
        public static uint GetInputIdleSeconds() {
            LASTINPUTINFO lii = new LASTINPUTINFO();
            lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(out lii))
                return 999;
            ulong tick64 = GetTickCount64();
            // Reconstruct full 64-bit dwTime: combine upper 32 bits of tick64 with dwTime,
            // then step back through 32-bit epochs (each ~49.7 days) until < tick64.
            // Handles >49.7 day uptime with idle periods crossing multiple wraparounds.
            ulong fullDwTime = (tick64 & 0xFFFFFFFF00000000) | lii.dwTime;
            while (fullDwTime > tick64)
                fullDwTime -= 0x100000000;
            return (uint)((tick64 - fullDwTime) / 1000);
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct LASTINPUTINFO {
            public uint cbSize;
            public uint dwTime;
        }
    }
}
'@
    try {
        Add-Type -TypeDefinition $code -ErrorAction Stop | Out-Null
        # Resolve type explicitly instead of relying on -PassThru ordering
        $script:Win32Type = [WinRefresh.Win32Gui]
    } catch {
        Write-Log -Level CRITICAL -Operation "PInvoke" -Message "Failed to compile Win32Gui: $_"
        throw
    }
}

function Get-AdaptiveThresholds {
    $ram = Get-CimInstance -Class Win32_ComputerSystem -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty TotalPhysicalMemory
    if (-not $ram -or $ram -le 0) {
        Write-Log -Level WARN -Operation "AdaptiveThresholds" -Message "Could not read physical RAM, using conservative defaults"
        return @{ PteThreshold = 512MB; HandleThreshold = 50000; RamGB = 0; TotalRAM = 0 }
    }
    $ramGB = [math]::Round($ram / 1GB)
    return @{
        PteThreshold    = [math]::Max(512MB, [math]::Min($ram / 32, 2GB))
        HandleThreshold = [math]::Max(30000, [math]::Min($ramGB * 2500, 120000))
        RamGB           = $ramGB
        TotalRAM        = $ram
    }
}

function Get-SystemUptime {
    $os = Get-CimInstance -Class Win32_OperatingSystem | Select-Object -ExpandProperty LastBootUpTime
    return (Get-Date) - $os
}

function Get-TopGdiUserProcesses {
    # Returns processes sorted by GDI+USER objects, skipping Session 0 (services)
    $results = @()
    $processes = Get-Process -ErrorAction SilentlyContinue
    $currentSessionId = (Get-Process -Id $PID).SessionId
    foreach ($p in $processes) {
        try {
            # Skip Session 0 processes (services) — GetGuiResources returns 0 cross-station
            if ($p.SessionId -eq 0) { continue }
            # Skip processes not in current session (Fast User Switching)
            if ($p.SessionId -ne $currentSessionId) { continue }
            # Skip processes we can't query (protected/system)
            $handle = $null
            try {
                $handle = $p.Handle
            } catch { continue }
            if ($handle -eq [IntPtr]::Zero) { continue }

            $gdi = $script:Win32Type::GetGuiResources($handle, 0)
            $usr = $script:Win32Type::GetGuiResources($handle, 1)
            if ($gdi -lt 0) { $gdi = 0 }
            if ($usr -lt 0) { $usr = 0 }

            $results += [PSCustomObject]@{
                ProcessName = $p.ProcessName
                Id          = $p.Id
                GDI         = $gdi
                USER        = $usr
                Total       = $gdi + $usr
            }
        } catch {}
    }
    return $results | Sort-Object Total -Descending
}

function Get-ExplorerMetrics {
    # Filter by current session to avoid picking wrong instance on multi-session systems
    $currentSessionId = (Get-Process -Id $PID).SessionId
    $exp = Get-Process -Name explorer -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $currentSessionId } | Select-Object -First 1
    if (-not $exp) { return $null }
    try {
        $handle = $exp.Handle
        return [PSCustomObject]@{
            Id      = $exp.Id
            GDI     = [math]::Max(0, $script:Win32Type::GetGuiResources($handle, 0))
            USER    = [math]::Max(0, $script:Win32Type::GetGuiResources($handle, 1))
            Handles = $exp.Handles
            WS_MB   = [math]::Round($exp.WorkingSet64 / 1MB, 1)
        }
    } catch { return $null }
}

function Get-DwmMetrics {
    $currentSessionId = (Get-Process -Id $PID).SessionId
    $dwm = Get-Process -Name dwm -ErrorAction SilentlyContinue |
        Where-Object { $_.SessionId -eq $currentSessionId } | Select-Object -First 1
    if (-not $dwm) { return $null }

    $skipped = 0
    try {
        # Enumerate ALL counter sets and match by PATH pattern — set NAMES are localised
        # ("Desktop Window Manager" → "Desktopfenster-Manager" on German Windows).
        # Counter path components (category\counter names) are invariant across languages.
        $allSets = Get-Counter -ListSet * -ErrorAction Stop
        $dwmSet = $allSets | Where-Object {
            ($_.Paths -join ' ') -match 'frame.*skip|skip.*frame'
        } | Select-Object -First 1
        if ($dwmSet) {
            $frameSkipPaths = $dwmSet.Paths | Where-Object { $_ -match 'frame.*skip' -or $_ -match 'skip.*frame' }
            foreach ($path in $frameSkipPaths) {
                try {
                    $counter = Get-Counter -Counter $path -ErrorAction Stop
                    # Sum across all instances (multi-GPU systems may return >1 sample)
                    foreach ($sample in $counter.CounterSamples) {
                        $skipped += [int]$sample.CookedValue
                    }
                    break
                } catch {}
            }
        }
    } catch {}

    return [PSCustomObject]@{
        Id            = $dwm.Id
        Handles       = $dwm.Handles
        WS_MB         = [math]::Round($dwm.WorkingSet64 / 1MB, 1)
        FramesSkipped = $skipped
    }
}

function Get-NonPagedPoolMB {
    try {
        $raw = (Get-Counter -Counter '\Memory\Pool Nonpaged Bytes' -ErrorAction Stop).CounterSamples[0].CookedValue
        return [math]::Round($raw / 1MB, 1)
    } catch { return $null }
}

function Get-FreeSystemPteMB {
    # Free System Page Table Entries returns a COUNT of entries, NOT bytes.
    # Multiply by page size (4096) to get actual bytes, then convert to MB.
    try {
        $raw = (Get-Counter -Counter '\Memory\Free System Page Table Entries' -ErrorAction Stop).CounterSamples[0].CookedValue
        $bytes = $raw * 4096
        return [math]::Round($bytes / 1MB, 1)
    } catch { return $null }
}

function Get-GpuVramUsage {
    $results = @()
    try {
        $counters = Get-Counter -Counter '\GPU Adapter Memory\*' -ErrorAction Stop
        foreach ($s in $counters.CounterSamples) {
            if ($s.InstanceName -and $s.CookedValue -gt 0) {
                $results += [PSCustomObject]@{
                    Instance       = $s.InstanceName
                    DedicatedMB    = [math]::Round($s.CookedValue / 1MB, 1)
                }
            }
        }
    } catch {}
    return $results
}

function Get-ShellExtensionCount {
    $total = 0
    # HKLM 64-bit
    try {
        $path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved"
        $items = Get-ItemProperty -Path $path -ErrorAction Stop
        $total += ($items.PSObject.Properties | Where-Object { $_.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider','(default)') }).Count
    } catch {}
    # HKLM 32-bit on 64-bit OS (Wow6432Node)
    try {
        $path32 = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved"
        $items32 = Get-ItemProperty -Path $path32 -ErrorAction Stop
        $total += ($items32.PSObject.Properties | Where-Object { $_.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider','(default)') }).Count
    } catch {}
    # HKCU (per-user)
    try {
        $pathUser = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved"
        $itemsUser = Get-ItemProperty -Path $pathUser -ErrorAction Stop
        $total += ($itemsUser.PSObject.Properties | Where-Object { $_.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider','(default)') }).Count
    } catch {}
    return $total
}

function Get-StandbyListMB {
    try {
        $raw = (Get-Counter -Counter '\Memory\Standby Cache Core Bytes' -ErrorAction Stop).CounterSamples[0].CookedValue
        return [math]::Round($raw / 1MB, 1)
    } catch { return $null }
}

function Get-TotalHandleCount {
    try {
        $total = 0
        Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            try { $total += $_.Handles } catch {}
        }
        return $total
    } catch { return $null }
}

function Get-UserIdleSeconds {
    # Delegates to C# method for safe 32-bit wraparound handling
    return [int]$script:Win32Type::GetInputIdleSeconds()
}

function Get-UserNotificationState {
    $state = 0
    $hr = $script:Win32Type::SHQueryUserNotificationState([ref]$state)
    # COM success is HRESULT >= 0, not HRESULT == 0
    if ($hr -lt 0) { return 'UNKNOWN' }
    switch ($state) {
        1 { return 'NOT_PRESENT' }
        2 { return 'BUSY' }
        3 { return 'D3D_FULL_SCREEN' }
        4 { return 'PRESENTATION_MODE' }
        5 { return 'ACCEPTS_NOTIFICATIONS' }
        6 { return 'QUIET_TIME' }
        7 { return 'QUNS_APP' }
        default { return "UNKNOWN_$state" }
    }
}

function Get-SystemDiagnostics {
    param([hashtable]$Thresholds)
    if (-not $Thresholds) { $Thresholds = Get-AdaptiveThresholds }

    Initialize-Diagnostics

    return [PSCustomObject]@{
        Timestamp           = Get-Date -Format 'o'
        Uptime              = Get-SystemUptime
        TotalRAM_GB         = $Thresholds.RamGB
        # Metric 1: Top GDI/USER processes
        TopGuiProcesses     = Get-TopGdiUserProcesses | Select-Object -First 10
        # Metric 2: Total handles
        TotalHandles        = Get-TotalHandleCount
        HandleThreshold     = $Thresholds.HandleThreshold
        # Metric 3: Non-Paged Pool
        NonPagedPoolMB      = Get-NonPagedPoolMB
        # Metric 4: DWM health
        DwmMetrics          = Get-DwmMetrics
        # Metric 5: Explorer
        ExplorerMetrics     = Get-ExplorerMetrics
        # Metric 6: Free PTE (now correctly in bytes→MB)
        FreeSystemPTE_MB    = Get-FreeSystemPteMB
        PteThreshold        = $Thresholds.PteThreshold
        # Metric 7: GPU VRAM
        GpuVram             = Get-GpuVramUsage
        # Metric 8: Shell extensions (now HKLM + Wow6432Node + HKCU)
        ShellExtensionCount = Get-ShellExtensionCount
        # Metric 9: Standby list
        StandbyListMB       = Get-StandbyListMB
        # User state
        UserIdleSeconds     = Get-UserIdleSeconds
        NotificationState   = Get-UserNotificationState
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add private/Diagnostics.ps1
git commit -m "feat: add Diagnostics module with 9 metrics and P/Invoke signatures"
```

---

### Task 4: Cleanup Module

**Files:**
- Create: `E:\project\windows-refresh\private\Cleanup.ps1`

- [ ] **Step 1: Write Cleanup.ps1 — full implementation**

```powershell
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
```

- [ ] **Step 2: Commit**

```bash
git add private/Cleanup.ps1
git commit -m "feat: add Cleanup module with 3-level operations and safety checks"
```

---

### Task 5: Decision Engine

**Files:**
- Create: `E:\project\windows-refresh\private\DecisionEngine.ps1`

- [ ] **Step 1: Write DecisionEngine.ps1**

```powershell
# DecisionEngine.ps1 — threshold comparison and dual-mode routing
# Functions: Get-DecisionPlan
# All PS 5.1 compatible — no ?? operator, no -AsHashtable

function Get-DecisionPlan {
    param(
        [PSObject]$Diagnostics,
        [hashtable]$ConfigThresholds = @{},
        [bool]$IsManual = $false
    )

    $plan = [ordered]@{
        Level2Warnings     = @()
        Level3Warnings     = @()
        ShouldRestartExplorer = $false
        ShouldRestartDwm      = $false
        Summary               = @()
    }

    $th = $ConfigThresholds

    # --- Metric 1: Top GDI/USER processes ---
    $gdiThreshold = if ($null -ne $th['gdi_per_process']) { [int]$th['gdi_per_process'] } else { 9000 }
    foreach ($p in $Diagnostics.TopGuiProcesses) {
        if ($p.GDI -gt $gdiThreshold -or $p.USER -gt $gdiThreshold) {
            $msg = "$($p.ProcessName) (PID $($p.Id)): GDI=$($p.GDI) USER=$($p.USER)"
            if ($p.ProcessName -eq 'explorer') {
                $plan.ShouldRestartExplorer = $true
                $plan.Summary += "Explorer GDI/USER objects high: $msg"
            } else {
                $plan.Level2Warnings += $msg
                $plan.Summary += "High GDI/USER process: $msg"
            }
        }
    }

    # --- Metric 2: Total handles ---
    $handleThreshold = if ($null -ne $th['handle_threshold']) { [int]$th['handle_threshold'] } else { $Diagnostics.HandleThreshold }
    if ($null -ne $Diagnostics.TotalHandles -and $Diagnostics.TotalHandles -gt $handleThreshold) {
        $plan.Level3Warnings += "Total handles $($Diagnostics.TotalHandles) > $handleThreshold"
        $plan.Summary += "Total handles high: $($Diagnostics.TotalHandles)"
    }

    # --- Metric 3: Non-Paged Pool ---
    $nppThreshold = if ($null -ne $th['non_paged_pool_mb']) { [long]$th['non_paged_pool_mb'] } else { 2048 }
    if ($null -ne $Diagnostics.NonPagedPoolMB -and $Diagnostics.NonPagedPoolMB -gt $nppThreshold) {
        $plan.Level3Warnings += "Non-Paged Pool: $($Diagnostics.NonPagedPoolMB) MB > $nppThreshold MB — suggest system restart"
        $plan.Summary += "Non-Paged Pool critical: $($Diagnostics.NonPagedPoolMB) MB"
    }

    # --- Metric 4: DWM ---
    $dwmWsThreshold = if ($null -ne $th['dwm_working_set_mb']) { [int]$th['dwm_working_set_mb'] } else { 1024 }
    $dwmHandleThreshold = if ($null -ne $th['dwm_handles']) { [int]$th['dwm_handles'] } else { 5000 }
    if ($Diagnostics.DwmMetrics) {
        $dwm = $Diagnostics.DwmMetrics
        $issues = @()
        if ($dwm.WS_MB -gt $dwmWsThreshold) { $issues += "WS=$($dwm.WS_MB)MB" }
        if ($dwm.Handles -gt $dwmHandleThreshold) { $issues += "Handles=$($dwm.Handles)" }
        if ($dwm.FramesSkipped -gt 0) { $issues += "FramesSkipped=$($dwm.FramesSkipped)" }
        if ($issues.Count -gt 0) {
            $plan.ShouldRestartDwm = $true
            $plan.Summary += "DWM issues: $($issues -join ', ')"
        }
    }

    # --- Metric 5: Explorer ---
    $explorerGdiThreshold = if ($null -ne $th['explorer_gdi']) { [int]$th['explorer_gdi'] } else { 9000 }
    if ($Diagnostics.ExplorerMetrics -and $Diagnostics.ExplorerMetrics.GDI -gt $explorerGdiThreshold) {
        $plan.ShouldRestartExplorer = $true
        $plan.Summary += "Explorer GDI=$($Diagnostics.ExplorerMetrics.GDI) > $explorerGdiThreshold"
    }

    # --- Metric 6: Free PTE ---
    $pteThreshold = $Diagnostics.PteThreshold
    if ($null -ne $Diagnostics.FreeSystemPTE_MB -and $Diagnostics.FreeSystemPTE_MB -lt ($pteThreshold / 1MB)) {
        $plan.Level3Warnings += "Free PTE: $($Diagnostics.FreeSystemPTE_MB) MB < $([math]::Round($pteThreshold/1MB)) MB — save work and reboot"
        $plan.Summary += "PTE critically low: $($Diagnostics.FreeSystemPTE_MB) MB"
    }

    # --- Metric 7: GPU VRAM (diagnostic-only — reports dedicated memory usage) ---
    foreach ($gpu in $Diagnostics.GpuVram) {
        if ($gpu.DedicatedMB -gt 0) {
            $plan.Summary += "GPU VRAM: $($gpu.Instance)=$($gpu.DedicatedMB)MB"
        }
    }

    # --- Metric 8: Shell extensions ---
    $shellThreshold = if ($null -ne $th['shell_extensions_count']) { [int]$th['shell_extensions_count'] } else { 50 }
    if ($Diagnostics.ShellExtensionCount -and $Diagnostics.ShellExtensionCount -gt $shellThreshold) {
        $plan.Summary += "Shell extension count high: $($Diagnostics.ShellExtensionCount)"
    }

    # --- Update restart decisions based on mode ---
    if (-not $IsManual) {
        # Unattended: downgrade Level 2 to warnings only
        if ($plan.ShouldRestartExplorer) {
            $plan.Level2Warnings += "Explorer needs restart (unattended — skipped)"
            $plan.ShouldRestartExplorer = $false
        }
        if ($plan.ShouldRestartDwm) {
            $plan.Level2Warnings += "DWM needs restart (unattended — skipped)"
            $plan.ShouldRestartDwm = $false
        }
    }

    return $plan
}
```

- [ ] **Step 2: Commit**

```bash
git add private/DecisionEngine.ps1
git commit -m "feat: add DecisionEngine with threshold comparison and dual-mode routing"
```

---

### Task 6: Main Script

**Files:**
- Create: `E:\project\windows-refresh\WinRefresh.ps1`

- [ ] **Step 1: Write WinRefresh.ps1 — orchestration with concurrency protocol**

```powershell
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

Write-Log -Level INFO -Operation "Startup" -Message "WinRefresh starting, Manual=$IsManual, PID=$PID"

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
    Write-Host "WinRefresh — Windows UI Performance Refresh" -ForegroundColor Green
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
```

- [ ] **Step 2: Commit**

```bash
git add WinRefresh.ps1
git commit -m "feat: add main WinRefresh.ps1 with concurrency protocol and orchestration"
```

---

### Task 7: User Launcher (CMD)

**Files:**
- Create: `E:\project\windows-refresh\WinRefresh.cmd`

- [ ] **Step 1: Write WinRefresh.cmd — PS7 → PS5.1 fallback chain, forwards arguments on elevation**

```batch
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
```

- [ ] **Step 2: Commit**

```bash
git add WinRefresh.cmd
git commit -m "feat: add WinRefresh.cmd launcher with PS7 to PS5.1 fallback"
```

---

### Task 8: Installation Script

**Files:**
- Create: `E:\project\windows-refresh\scripts\Install-ScheduledTask.ps1`

- [ ] **Step 1: Create scripts directory**

```powershell
New-Item -ItemType Directory -Force -Path "E:\project\windows-refresh\scripts"
```

- [ ] **Step 2: Write Install-ScheduledTask.ps1**

```powershell
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
if (-not (Test-Path "HKLM:\SOFTWARE\WinRefresh")) {
    New-Item -Path "HKLM:\SOFTWARE\WinRefresh" -Force | Out-Null
}
Set-ItemProperty -Path "HKLM:\SOFTWARE\WinRefresh" -Name "InstallPath" -Value $installPath -Force
Set-ItemProperty -Path "HKLM:\SOFTWARE\WinRefresh" -Name "Version" -Value "1.0.0" -Force
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
    -StopIfGoingOnBatteries:$true `
    -Compatibility Win8

$taskPrincipal = New-ScheduledTaskPrincipal -UserId $currentUserSid `
    -LogonType InteractiveToken `
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
```

- [ ] **Step 3: Commit**

```bash
git add scripts/Install-ScheduledTask.ps1
git commit -m "feat: add installation script with task registration and Event Log setup"
```

---

### Task 9: Uninstallation Script

**Files:**
- Create: `E:\project\windows-refresh\scripts\Uninstall-ScheduledTask.ps1`

- [ ] **Step 1: Write Uninstall-ScheduledTask.ps1 with self-copy-to-TEMP and running-instance check**

```powershell
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
```

- [ ] **Step 2: Commit**

```bash
git add scripts/Uninstall-ScheduledTask.ps1
git commit -m "feat: add uninstallation script with self-copy-to-TEMP and running-instance check"
```

---

### Task 10: README Documentation

**Files:**
- Create: `E:\project\windows-refresh\README.md`

- [ ] **Step 1: Write README.md**

(README content unchanged — same as initial plan)

```markdown
# WinRefresh

Windows UI 性能自动维护工具 — 解决长时间不关机后 UI 交互卡顿问题，无需重启电脑。

## 解决的问题

Windows 11 连续运行 3-7 天后出现 UI 卡顿（窗口拖动拖影、Alt+Tab 切换慢、右键菜单延迟），即使 CPU 和内存仍有大量空闲。WinRefresh 自动诊断并安全修复以下根因：

-   GDI/USER 对象泄漏（进程达到 10000 上限）
-   内核 Non-Paged Pool 泄漏
-   DWM（桌面窗口管理器）问题
-   句柄泄漏
-   图标/缩略图缓存膨胀

## 系统要求

-   Windows 10 1607+ 或 Windows 11
-   PowerShell 5.1 或 7.x
-   管理员权限

## 安装

以管理员身份运行：

```powershell
.\scripts\Install-ScheduledTask.ps1
```

这会：
1.  将脚本安装到 `C:\Program Files\WinRefresh\`
2.  创建数据目录 `C:\ProgramData\WinRefresh\`
3.  注册 Windows Event Log 源 "WinRefresh"
4.  创建计划任务：**每日凌晨 3:00** + **登录时**（以当前用户身份运行）

## 使用

### 手动运行

双击 `WinRefresh.cmd` 或在终端中运行：

```powershell
.\WinRefresh.ps1 -Manual
```

手动模式会执行所有 Level 1 安全清理，并在必要时（经过安全检查和 15 秒倒计时）重启 Explorer 或 DWM。

### 强制操作

```powershell
# 强制重启 Explorer（忽略诊断阈值）
.\WinRefresh.ps1 -Manual -ForceExplorerRestart

# 强制重启 DWM（忽略 24 小时冷却）
.\WinRefresh.ps1 -Manual -ForceDwmRestart -OverrideCoolDown
```

### 自动运行

计划任务每天凌晨 3:00 自动运行，仅执行 Level 1 安全清理（不重启 Explorer/DWM）。

## 清理级别

| 级别 | 操作 | 无人值守 | 手动 |
|------|------|:--:|:--:|
| Level 1 | 清临时文件、DNS 缓存、BITS 队列、重建图标/缩略图缓存 | ✅ | ✅ |
| Level 2 | 重启 Explorer / DWM（需安全检查） | ⚠️ 仅警告 | ✅ |
| Level 3 | Non-Paged Pool / PTE 严重告警 | ✅ | ✅ |

## 日志

-   **JSON Lines 日志**：`C:\ProgramData\WinRefresh\logs\winrefresh.log`（10MB 自动轮转，保留 5 个归档，30 天清理）
-   **Windows Event Log**：WARN+ 级别摘要写入 Application 日志，Source="WinRefresh"

### 查询日志

```powershell
# 在 WinRefresh.ps1 所在目录：
. .\private\Logger.ps1
Get-WinRefreshLog -Level WARN,ERROR,CRITICAL -After (Get-Date).AddDays(-7)
Export-WinRefreshLog -Format Csv
```

## 卸载

以管理员身份运行：

```powershell
.\scripts\Uninstall-ScheduledTask.ps1
```

## 安全设计

-   **零外部依赖**：纯 PowerShell + Windows API（P/Invoke），不安装任何第三方工具
-   **并发安全**：`Global\WinRefresh_Mutex` 全局互斥锁 + 运行状态机
-   **崩溃恢复**：自动检测崩溃的上一实例并恢复
-   **Explorer 安全重启**：用户在场检测 → 全屏/演示检测 → 文件复制检测 → 15 秒倒计时 → 渐进式关闭
-   **配置容错**：3 层防御（缺失→默认 / 损坏→默认 / 越界→钳位）

## 文件结构

```
C:\Program Files\WinRefresh\
├── WinRefresh.ps1             主脚本
├── WinRefresh.cmd             用户双击入口
├── private/
│   ├── Diagnostics.ps1        系统指标采集（9 项）
│   ├── Cleanup.ps1            清理操作（3 级）
│   ├── DecisionEngine.ps1     智能决策引擎
│   └── Logger.ps1             结构化日志
├── config/
│   └── settings.json          配置模板
└── scripts/
    ├── Install-ScheduledTask.ps1
    └── Uninstall-ScheduledTask.ps1

C:\ProgramData\WinRefresh\
├── logs/                      JSON Lines 日志
├── running.lock               运行锁文件
└── state.json                 持久化状态
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add README with installation, usage, and safety documentation"
```

---

## Implementation Order

```
Task 1 (config) → Task 2 (Logger) → Task 3 (Diagnostics) → Task 4 (Cleanup)
                                        ↘                        ↙
                                         Task 5 (DecisionEngine)
                                                  ↓
                                          Task 6 (WinRefresh.ps1)
                                          ↙         ↓          ↘
                                Task 7 (.cmd)  Task 8 (Install)  Task 9 (Uninstall)
                                                                    ↓
                                                              Task 10 (README)
```

Tasks 7-10 can run in parallel after Task 6 completes.

## Review Fixes Applied (from Subagent Audit Rounds 1 & 2)

### FATAL fixes
| # | Issue | Fix |
|---|-------|-----|
| F1 | `??` operator PS 7+ only | All 15 occurrences replaced with `if ($null -ne $x) { $x } else { $y }` |
| F2 | `-AsHashtable` PS 6+ only | `ConvertTo-Hashtable` helper function added; all call sites updated |
| F3 | `-DisallowStartOnBattery` doesn't exist | Removed; `-AllowStartIfOnBatteries:$false` covers the intent |

### CRITICAL fixes
| # | Issue | Fix |
|---|-------|-----|
| C1 | DWM counter paths malformed | Changed to runtime discovery via `Get-Counter -ListSet 'Desktop Window Manager'` |
| C2 | PTE unit mismatch (entries vs bytes) | Multiply entry count by page size (4096) before converting to MB |
| C3 | Dynamic Add-Type leak in Test-FileCopyInProgress | `FindWindow` moved into common `WinRefresh.Win32Gui` class |
| C4 | `handle_threshold` missing from settings.json | Added with `null` default (uses adaptive computation) |
| C5 | HRESULT check `$hr -ne 0` | Changed to `$hr -lt 0` (COM success is HRESULT >= 0) |

### Additional fixes
| # | Issue | Fix |
|---|-------|-----|
| M1 | 32-bit tick wraparound OverflowException | Idle calculation moved into C# `GetInputIdleSeconds()` method |
| M2 | CloseMainWindow return value not captured | Now uses `$task.Result` to check actual CloseMainWindow success |
| M3 | DWM restart not verified | Added 10-second verification loop after DWM stop |
| M4 | ie4uinit.exe indefinite hang | Added 10-second `WaitForExit` timeout with Kill fallback |
| M5 | DWM cooldown written after kill | Cooldown timestamp now written BEFORE Stop-Process |
| M6 | Cross-session GDI queries silently return 0 | Added `$currentSessionId` filter in `Get-TopGdiUserProcesses` |
| M7 | Wait-Countdown only checks idle time | Now re-checks both idle time AND notification state |
| M8 | ShellExtensionCount misses 32-bit + HKCU | Now enumerates HKLM + Wow6432Node + HKCU |
| M9 | CMD elevation drops user arguments | Uses `%*` to forward arguments to elevated instance |
| M10 | User name for Task Scheduler breaks on rename | Uses SID string (`User.Value`) instead of username |
| M11 | Install script always uses powershell.exe | Detects pwsh.exe and prefers it when available |
| M12 | Uninstall doesn't check for running instance | Added mutex check before deletion |
| M13 | Hardcoded C:\Users for thumbnail cache | Reads ProfilesDirectory from registry |
| M14 | Set-Content without -Encoding UTF8 | All Set-Content calls now use `-Encoding UTF8` |
| M15 | Lock file writes not atomic | Write to .tmp then Move-Item (atomic on NTFS) |
| M16 | ConvertTo-Json without -Depth | Export-WinRefreshLog now uses `-Depth 10` |
| M17 | $null passed as argument bypasses default @{} | Added null guard in `Invoke-Level1Cleanup` |
| M18 | Get-TotalHandleCount returns 0 on failure | Wrapped in try/catch, returns $null on failure |

### Round 2 fixes (from second subagent audit)
| # | Issue | Fix |
|---|-------|-----|
| R2-F1 | `ConvertTo-Hashtable` shallow — nested PSCustomObjects cause [hashtable] binding failure | Made `ConvertTo-Hashtable` recursive; WinRefresh.ps1 recursively converts threshold/cleanup config sections |
| R2-C1 | DWM counter set name localised on non-English Windows | Enumerate ALL counter sets, match by path pattern containing 'frame.*skip' |
| R2-C2 | `thumbnail_cache_interval_days` read but never passed | Added `-IntervalDays` param to `Clear-ThumbnailCache`, wired from `Invoke-Level1Cleanup` |
| R2-M1 | `Add-Content -Encoding UTF8` writes BOM on every line in PS 5.1 | Replaced with `[System.IO.File]::AppendAllText` + UTF8Encoding($false) |
| R2-M2 | `Get-Content` lacks `-Encoding UTF8` | Added `-Encoding UTF8` to log file reads |
| R2-M3 | `GetTypes()` can throw ReflectionTypeLoadException | Wrapped in try/catch returning @() |
| R2-M4 | Hardcoded `C:\Program Files` and `C:\ProgramData` paths | Changed to `$env:ProgramFiles` and `$env:ProgramData` |
| R2-M5 | `FindWindow` DllImport uses default ANSI CharSet | Added `CharSet = CharSet.Unicode` |
| R2-M6 | Multi-instance counter samples break `[int]` cast | Sum all CounterSamples in a foreach loop |
| R2-M7 | `ie4uinit.exe` path broken under WOW64 | Use `[Environment]::SystemDirectory` to get true System32 |
| R2-M8 | Config parse errors silently swallow exception text | Added `$_` to config error log message |
| R2-M9 | Explorer/DWM metrics pick wrong session on multi-session | Added `$_.SessionId -eq $currentSessionId` filter |
| R2-M10 | `net session` requires Server service | Changed to `whoami /groups \| findstr "S-1-16-12288"` |
| R2-M11 | `GetInputIdleSeconds` handles only single 32-bit epoch | Changed `if` to `while` loop for multi-epoch wraparound |
| R2-M12 | `$plan.Level1Actions` dead code | Removed from DecisionEngine.ps1 — Level 1 always runs unconditionally |

## Self-Review Checklist

- [x] **Spec coverage**: All 9 diagnostic metrics, 3-level cleanup, dual-mode behavior, 9 engineering safety mechanisms, install/uninstall, boundary cases — all covered in Tasks 1-10
- [x] **Placeholder scan**: No "TBD", "TODO", or vague references — every step has actual code
- [x] **PS 5.1 compatibility**: All `??` and `-AsHashtable` removed; `ConvertTo-Hashtable` helper provided; idle-time calculation in C#; `GetTickCount64` P/Invoke used throughout
- [x] **Type consistency**: `Write-Log` signature identical across all modules; `Get-SystemDiagnostics` return type consistent; `Invoke-AtomicOperation` definition matches usage
- [x] **Audit fixes verified**: 3 FATAL + 5 CRITICAL + 13 additional fixes applied and cross-referenced
