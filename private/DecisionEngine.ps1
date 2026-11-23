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

    # --- Metric 0: System uptime ---
    $uptimeDays = if ($Diagnostics.Uptime) { $Diagnostics.Uptime.TotalDays } else { 0 }
    $uptimeThreshold = if ($null -ne $th['uptime_warning_days']) { [int]$th['uptime_warning_days'] } else { 30 }
    if ($uptimeDays -gt $uptimeThreshold) {
        $daysInt = [math]::Floor($uptimeDays)
        $plan.Summary += "System uptime high: ${daysInt} days > ${uptimeThreshold} days"
    }

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
    $dwmThreadThreshold = if ($null -ne $th['dwm_threads']) { [int]$th['dwm_threads'] } else { 100 }
    $dwmCpuThreshold = if ($null -ne $th['dwm_cpu_percent']) { [int]$th['dwm_cpu_percent'] } else { 50 }
    if ($Diagnostics.DwmMetrics) {
        $dwm = $Diagnostics.DwmMetrics
        $issues = @()
        if ($dwm.WS_MB -gt $dwmWsThreshold) { $issues += "WS=$($dwm.WS_MB)MB" }
        if ($dwm.Handles -gt $dwmHandleThreshold) { $issues += "Handles=$($dwm.Handles)" }
        if ($null -ne $dwm.Threads -and $dwm.Threads -gt $dwmThreadThreshold) { $issues += "Threads=$($dwm.Threads)" }
        if ($null -ne $dwm.CpuPercent -and $dwm.CpuPercent -gt $dwmCpuThreshold) { $issues += "CPU=$($dwm.CpuPercent)%" }
        if ($dwm.FramesSkipped -gt 0) { $issues += "FramesSkipped=$($dwm.FramesSkipped)" }
        if ($issues.Count -gt 0) {
            $plan.ShouldRestartDwm = $true
            $plan.Summary += "DWM issues: $($issues -join ', ')"
        }
    }

    # --- Metric 5: Explorer ---
    $explorerGdiThreshold = if ($null -ne $th['explorer_gdi']) { [int]$th['explorer_gdi'] } else { 9000 }
    $explorerHandleThreshold = if ($null -ne $th['explorer_handles']) { [int]$th['explorer_handles'] } else { 5000 }
    $explorerThreadThreshold = if ($null -ne $th['explorer_threads']) { [int]$th['explorer_threads'] } else { 150 }
    $explorerWsThreshold = if ($null -ne $th['explorer_working_set_mb']) { [int]$th['explorer_working_set_mb'] } else { 1024 }

    if ($Diagnostics.ExplorerMetrics) {
        $exp = $Diagnostics.ExplorerMetrics
        $expIssues = @()
        if ($exp.GDI -gt $explorerGdiThreshold) { $expIssues += "GDI=$($exp.GDI) > $explorerGdiThreshold" }
        if ($null -ne $exp.Handles -and $exp.Handles -gt $explorerHandleThreshold) { $expIssues += "Handles=$($exp.Handles) > $explorerHandleThreshold" }
        if ($null -ne $exp.Threads -and $exp.Threads -gt $explorerThreadThreshold) { $expIssues += "Threads=$($exp.Threads) > $explorerThreadThreshold" }
        if ($null -ne $exp.WS_MB -and $exp.WS_MB -gt $explorerWsThreshold) { $expIssues += "WS=$($exp.WS_MB)MB > ${explorerWsThreshold}MB" }

        if ($expIssues.Count -gt 0) {
            $plan.ShouldRestartExplorer = $true
            $plan.Summary += "Explorer issues: $($expIssues -join ', ')"
        }
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

    # --- Metric 9: High CPU GPU / WebView2 processes ---
    $gpuProcCpuThreshold = if ($null -ne $th['gpu_process_cpu_seconds']) { [int]$th['gpu_process_cpu_seconds'] } else { 3600 }
    if ($Diagnostics.GpuProcesses) {
        foreach ($gp in $Diagnostics.GpuProcesses) {
            if ($gp.CpuSeconds -gt $gpuProcCpuThreshold) {
                $msg = "$($gp.Name) (PID $($gp.Id), Parent: $($gp.Parent)): CPU=$($gp.CpuSeconds)s WS=$($gp.WS_MB)MB"
                $plan.Level2Warnings += $msg
                $plan.Summary += "High CPU GPU process: $msg"
            }
        }
    }

    # --- Metric 10: Virtual Display Adapters ---
    $virtualDisplayThreshold = if ($null -ne $th['virtual_display_warning_count']) { [int]$th['virtual_display_warning_count'] } else { 1 }
    if ($Diagnostics.VirtualDisplayAdapters) {
        $activeVirtual = @($Diagnostics.VirtualDisplayAdapters | Where-Object { $_.ErrorCode -eq 0 -or $_.Status -eq 'OK' })
        if ($activeVirtual.Count -ge $virtualDisplayThreshold) {
            foreach ($v in $activeVirtual) {
                $msg = "$($v.Name) (Device: $($v.DeviceID)) active"
                $plan.Level2Warnings += $msg
                $plan.Summary += "Active Virtual Display: $msg"
            }
        }
    }

    # --- Update restart decisions based on mode ---
    $allowUnattendedExp = if ($null -ne $th['unattended_restart_explorer']) { [bool]$th['unattended_restart_explorer'] } else { $false }
    if (-not $IsManual) {
        if ($plan.ShouldRestartExplorer) {
            if ($allowUnattendedExp) {
                $plan.Summary += "Explorer restart scheduled (unattended allowed)"
            } else {
                # Unattended: downgrade Level 2 to warnings only
                $plan.Level2Warnings += "Explorer needs restart (unattended — skipped)"
                $plan.ShouldRestartExplorer = $false
            }
        }
        if ($plan.ShouldRestartDwm) {
            $plan.Level2Warnings += "DWM needs restart (unattended — skipped)"
            $plan.ShouldRestartDwm = $false
        }
    }

    return $plan
}
