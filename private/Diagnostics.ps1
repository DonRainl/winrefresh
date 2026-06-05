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
    $os = Get-CimInstance -Class Win32_OperatingSystem -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty LastBootUpTime
    if (-not $os) {
        Write-Log -Level WARN -Operation "Diagnostics" -Message "Cannot read system uptime — CIM/WMI unavailable"
        return $null
    }
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
