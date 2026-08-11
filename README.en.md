# WinRefresh

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)](https://github.com/PowerShell/PowerShell)
[![Windows](https://img.shields.io/badge/Windows-10%201607%2B%20%7C%2011-blue)](#system-requirements)
[![CI](https://github.com/DonRainl/winrefresh/actions/workflows/ci.yml/badge.svg)](https://github.com/DonRainl/winrefresh/actions/workflows/ci.yml)

> [简体中文](README.md) | English

Automatic Windows UI performance maintenance tool — fixes UI lag after long uptime **without rebooting your PC**.

## Problem

After 3–7 days of continuous uptime, Windows 11 UI becomes sluggish (window drag trails, slow Alt+Tab, delayed context menus) even when CPU and memory are mostly idle. WinRefresh automatically diagnoses and safely fixes these root causes:

- GDI/USER object leaks (processes hitting the 10,000 limit)
- Kernel Non-Paged Pool leaks
- DWM (Desktop Window Manager) issues
- Handle leaks
- Bloated icon/thumbnail caches

## System Requirements

- Windows 10 1607+ or Windows 11
- PowerShell 5.1 or 7.x
- Administrator privileges

## Installation

Run as administrator:

```powershell
.\scripts\Install-ScheduledTask.ps1
```

This will:

1. Copy scripts to `C:\Program Files\WinRefresh\`
2. Create the data directory `C:\ProgramData\WinRefresh\`
3. Register the "WinRefresh" Windows Event Log source
4. Register a Scheduled Task: **daily at 3:00 AM** + **at logon** (runs as the current user)

## Usage

### Manual run

Double-click `WinRefresh.cmd` or run in a terminal:

```powershell
.\WinRefresh.ps1 -Manual
```

Manual mode executes all Level 1 safe cleanups and, when necessary (after safety checks and a 15-second countdown), restarts Explorer or DWM.

### Forced operations

```powershell
# Force an Explorer restart (ignores diagnostic thresholds)
.\WinRefresh.ps1 -Manual -ForceExplorerRestart

# Force a DWM restart (ignores the 24h cooldown)
.\WinRefresh.ps1 -Manual -ForceDwmRestart -OverrideCoolDown
```

### Automatic runs

The scheduled task runs daily at 3:00 AM and performs **Level 1 cleanups only** (never restarts Explorer/DWM unattended).

## Cleanup Levels

| Level | Operation | Unattended | Manual |
|-------|-----------|:--:|:--:|
| Level 1 | Clear temp files, DNS cache, BITS queue, rebuild icon/thumbnail caches | ✅ | ✅ |
| Level 2 | Restart Explorer / DWM (requires safety checks) | ⚠️ warning only | ✅ |
| Level 3 | Non-Paged Pool / PTE critical warnings | ✅ | ✅ |

## Logs

- **JSON Lines logs**: `C:\ProgramData\WinRefresh\logs\winrefresh.log` (10 MB auto-rotation, 5 archives, 30-day retention)
- **Windows Event Log**: WARN+ summaries written to the Application log, Source="WinRefresh"

### Querying logs

```powershell
# From the directory containing WinRefresh.ps1:
. .\private\Logger.ps1
Get-WinRefreshLog -Level WARN,ERROR,CRITICAL -After (Get-Date).AddDays(-7)
Export-WinRefreshLog -Format Csv
```

## Uninstall

Run as administrator:

```powershell
.\scripts\Uninstall-ScheduledTask.ps1
```

## Running Tests

All test scripts exit with the number of failures as the exit code (0 = all passed):

```powershell
# 1. Syntax check (all modules)
.\tests\syntax-check.ps1

# 2. Logger unit tests
.\tests\logger-tests.ps1

# 3. Decision engine + config parsing tests
.\tests\decision-config-tests.ps1

# 4. Cross-module integration tests (calls real system APIs)
.\tests\integration-test.ps1
```

CI runs all four test suites on a Windows runner for every push/PR.

## Safety Design

- **Zero external dependencies**: pure PowerShell + Windows APIs (P/Invoke), no third-party tools installed
- **Concurrency safe**: `Global\WinRefresh_Mutex` global mutex + run state machine
- **Crash recovery**: auto-detects and recovers from a crashed previous instance
- **Safe Explorer restart**: user-presence detection → fullscreen/presentation detection → file-copy detection → 15-second countdown → graceful shutdown
- **Config resilience**: 3-layer defense (missing → default / corrupt → default / out-of-range → clamped)

## ⚠️ Risk Disclaimer

- WinRefresh **restarts Explorer and DWM** in manual mode when issues are detected. The screen may flicker and **unsaved work in Explorer-based windows could be affected**. Always save your work before running.
- DWM restart is limited by a 24-hour cooldown to avoid excessive disruption.
- Use at your own risk. The author is not liable for any damage caused by the use of this tool.

## File Structure

```
C:\Program Files\WinRefresh\
├── WinRefresh.ps1             Main script
├── WinRefresh.cmd             Double-click entry point
├── private/
│   ├── Diagnostics.ps1        System metrics collection (9 metrics)
│   ├── Cleanup.ps1            Cleanup operations (3 levels)
│   ├── DecisionEngine.ps1     Intelligent decision engine
│   └── Logger.ps1             Structured logging
├── config/
│   └── settings.json          Configuration template
└── scripts/
    ├── Install-ScheduledTask.ps1
    └── Uninstall-ScheduledTask.ps1

C:\ProgramData\WinRefresh\
├── logs/                      JSON Lines logs
├── running.lock               Run lock file
└── state.json                 Persistent state
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, coding conventions, and the PR process. All four test suites must pass before submitting.

## Security

See [SECURITY.md](SECURITY.md). Report vulnerabilities privately — do **not** open public issues for security bugs.

## License

[MIT](LICENSE) © DonRainl
