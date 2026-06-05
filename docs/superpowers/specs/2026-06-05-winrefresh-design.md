# WinRefresh — Windows 长时间不关机变卡的自动修复工具

## 元信息

| 字段 | 值 |
|------|-----|
| 日期 | 2026-06-05 |
| 版本 | v6 |
| 状态 | 设计阶段（待实现） |
| 审核轮次 | 5 轮 subagent 审核（Windows 底层 ×3 + PowerShell 工程 ×2） |

## 问题定义

### 症状
- **UI 交互卡顿**：窗口拖动拖影、点击响应延迟、文件管理器打开慢、右键菜单弹出慢
- **程序切换卡顿**：Alt+Tab 切换窗口慢、打开新程序慢
- **触发条件**：Windows 11 不关机运行 3-7 天后出现
- **关键特征**：CPU 和内存仍有大量空闲时依然卡

### 根因分析（按概率排序）

| 排名 | 根因 | 诊断方式 |
|------|------|---------|
| 1 | Desktop Heap 耗尽 — 每个桌面约 20MB，用完后窗口创建失败/变慢 | 通过单进程 USER/GDI 对象数作为代理指标 |
| 2 | 某进程 GDI/USER 对象泄漏 — 达到 10000 上限后 UI 操作失败 | `GetGuiResources` 逐进程检测 |
| 3 | 内核 Non-Paged Pool 泄漏 — 驱动程序泄漏内核内存 | `\Memory\Pool Nonpaged Bytes` |
| 4 | DWM 自身问题 — GPU VRAM 碎片、句柄泄漏导致合成卡顿 | `Get-Process dwm` + 跳帧率计数器 |
| 5 | Handle 泄漏 — 句柄表膨胀导致进程创建/查询变慢 | `Get-Process` Handles 属性 |
| 6 | Shell 扩展挂死 — 单个扩展阻塞 Explorer 消息泵 | 注册表枚举扩展数量 |
| 7 | GPU VRAM 耗尽 — DWM 降级到软件渲染 | `\GPU Adapter Memory\*` |

---

## 目录结构

```
C:\Program Files\WinRefresh\          ← 只读：脚本、配置模板
├── WinRefresh.ps1                     # 主入口脚本（Task Scheduler 目标 + 手动执行）
├── WinRefresh.cmd                     # 用户双击入口（PS7→PS5.1 回退链）
├── private/
│   ├── Diagnostics.ps1               # 系统指标采集（9 项）
│   ├── Cleanup.ps1                   # 清理操作（含 P/Invoke）
│   ├── DecisionEngine.ps1            # 智能决策引擎
│   └── Logger.ps1                    # 结构化日志
├── config/
│   └── settings.json                  # 用户可覆盖的阈值配置
└── scripts/
    ├── Install-ScheduledTask.ps1      # 安装：复制到 Program Files + 注册 Task
    └── Uninstall-ScheduledTask.ps1    # 卸载：清理全部产物

C:\ProgramData\WinRefresh\             ← 可写：日志、锁文件、运行时状态
├── logs/                              # JSON Lines 格式日志
├── running.lock                       # 执行状态机锁文件（JSON）
└── state.json                         # 持久化状态（上次清理时间等）
```

### 路径设计原则

- `Program Files` 只放只读内容（脚本、配置模板）— 符合 Windows 设计模式
- `ProgramData` 放可写内容（日志、锁、状态）— 默认可写
- 安装到固定路径避免目录移动导致 Task Scheduler 失效

### 关键设计决策：Task Scheduler 运行账户为登录用户

**不使用 `NT AUTHORITY\SYSTEM`**。原因：

1. `GetGuiResources` 只在同 Window Station 内有效 — SYSTEM 在 Session 0，用户进程在 Session 1+，跨 Session 调用**始终返回 0**
2. `ie4uinit.exe -ClearIconCache` 作用于调用者用户配置文件 — SYSTEM 清理的是 `systemprofile`，用户的图标缓存不受影响
3. 缩略图缓存路径在 SYSTEM 下指向 `systemprofile`，无法命中用户缓存
4. Session 0 隔离导致通知无法显示在用户桌面

**替代方案**：Task Scheduler 以登录用户身份运行（`Run only when user is logged on`）。触发器「每日凌晨 3:00」仅在用户登录时执行；「登录时」触发器补跑错过的任务。用户未登录时无需清理——没有交互会话就没有 UI 卡顿问题。

---

## 诊断指标（9 项）

| # | 指标 | 采集方式 | 阈值 | 说明 |
|---|------|---------|------|------|
| 1 | 单进程 GDI/USER 对象数 | `GetGuiResources` (user32.dll P/Invoke) | GDI > 9000, USER > 9000 | 跳过 Session 0 进程；因运行账户是登录用户，同 Session 查询可靠 |
| 2 | 总句柄数 | `Get-Process` Handles 属性 | 自适应：`Max(30000, Min(RAM_GB×2500, 120000))` | 无外部依赖 |
| 3 | Non-Paged Pool | `Get-Counter '\Memory\Pool Nonpaged Bytes'` | > 2GB 绝对值 | 放弃百分比，用绝对值 |
| 4 | DWM 健康度 | `Get-Process dwm` + `\Desktop Window Manager\Composition frames skipped\*` | WS > 1GB / Handles > 5000 / 跳帧 > 0 | 计数器名因 Windows 版本而异，提供回退探测 |
| 5 | Explorer GDI/USER/句柄 | `GetGuiResources` 定向查询 | GDI > 9000 | 同 Session，查询可靠 |
| 6 | PTE 剩余 | `\Memory\Free System Page Table Entries` | 自适应：`Max(512MB, Min(RAM/32, 2GB))` | 64 位系统极少耗尽 |
| 7 | GPU VRAM 使用率 | `\GPU Adapter Memory\*` | > 90% | try/catch 包裹，无 GPU 时静默跳过 |
| 8 | Shell 扩展数量 | `HKLM\...\ShellEx\Approved` 注册表枚举 | > 50 | 仅诊断，不操作 |
| 9 | Standby List 大小 | `\Memory\Standby Cache Core Bytes` | — | **仅监控不清理** |

### 自适应阈值公式

```powershell
$ramGB = [math]::Round($totalRam / 1GB)
$pteThreshold    = [math]::Max(512MB, [math]::Min($totalRam / 32, 2GB))
$handleThreshold = [math]::Max(30000, [math]::Min($ramGB * 2500, 120000))
```

### P/Invoke API 签名

```csharp
// GetGuiResources — 获取进程 GDI/USER 对象数
// 需要进程句柄有 PROCESS_QUERY_INFORMATION (0x0400) 访问权限
[DllImport("user32.dll", SetLastError = true)]
public static extern int GetGuiResources(IntPtr hProcess, int uiFlags);
// uiFlags: 0 = GR_GDIOBJECTS, 1 = GR_USEROBJECTS

// SHQueryUserNotificationState — 检测用户通知状态
[DllImport("shell32.dll")]
public static extern int SHQueryUserNotificationState(out int pquns);
// 返回值: 1=NOT_PRESENT, 2=BUSY, 3=RUNNING_D3D_FULL_SCREEN,
//         4=PRESENTATION_MODE, 5=ACCEPTS_NOTIFICATIONS, 6=QUIET_TIME

// GetLastInputInfo — 获取最后用户输入时间
[DllImport("user32.dll", SetLastError = true)]
public static extern bool GetLastInputInfo(out LASTINPUTINFO plii);

[DllImport("kernel32.dll")]
public static extern ulong GetTickCount64();
// 不使用 Environment.TickCount64 — 该属性在 .NET Framework 4.x 中不存在
// PS 5.1 运行在 .NET Framework 上，必须通过 P/Invoke 调用 GetTickCount64 (Vista+)

[StructLayout(LayoutKind.Sequential)]
public struct LASTINPUTINFO {
    public uint cbSize;  // = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO))
    public uint dwTime;  // GetTickCount() 值 — 用 GetTickCount64() + 无符号算术处理回绕
}
```

---

## 清理操作（3 级分级）

### Level 1 — 始终安全执行（无人值守 + 手动）

| 操作 | 方法 | 条件 |
|------|------|------|
| 清 Temp 文件 | `Remove-Item`，逐文件 try/catch | > 500MB 且 > 24h 旧文件 |
| 清 DNS Cache | `Clear-DnsClientCache` | 始终 |
| 清 BITS 完成队列 | `Remove-BitsTransfer`，try/catch 包裹（BITS 服务可能停用） | 已完成项 |
| 重建图标缓存 | `ie4uinit.exe -ClearIconCache` | 始终（不杀 Explorer，仅桌面图标瞬间刷新） |
| 重建缩略图缓存 | 枚举 `C:\Users\*\AppData\...\thumbcache_*.db`，逐文件 try/catch 跳过锁定 | 每 30 天（基于 state.json 时间戳去重） |

### Level 2 — 无人值守 vs 手动行为分叉

**无人值守模式（Task Scheduler 触发）：全部降级为仅写 Event Log 警告。不执行任何自动重启。**

**手动模式（用户 .cmd 或直接运行 WinRefresh.ps1）：**

| 操作 | 方法 | 安全前置条件 |
|------|------|-------------|
| 某进程 GDI > 9000 | `Write-Host` 彩色高亮警告 + Event Log | — |
| Explorer 超标 | 渐进式安全重启 | ① `SHQueryUserNotificationState` 检测：`NOT_PRESENT(1)`\|`BUSY(2)`\|`D3D_FULL_SCREEN(3)`\|`PRESENTATION(4)` → 阻止 ② `GetLastInputInfo` + `GetTickCount64` + 无符号比较：>30s 无活动 → 阻止 ③ `OperationStatusWindow` 无文件复制 ④ 15 秒倒计时 + 每 3 秒重检用户在场 ⑤ `[Task]::Run({ CloseMainWindow() }).Wait(3000)` → `WaitForExit(3000)` → 未退出则 `Stop-Process -Force` |
| DWM 超标 | `Stop-Process -Name dwm` | 同上 ①②③⑤ + 24h 冷却（手动可覆盖） |

**Explorer 重启详细流程**（修复了冗余 CloseMainWindow 和无超时阻塞）：

```
1. 全屏/演示/用户在场检测 → 不通过则阻止
2. 文件复制检测（OperationStatusWindow）→ 进行中则阻止
3. 15 秒倒计时（每 3 秒重检 GetLastInputInfo）
4. [Task]::Run({ $e.CloseMainWindow() }).Wait(3000)    ← 防御 hung 窗口（CloseMainWindow 只在 hung 时阻塞）
5. if (-not $e.WaitForExit(3000)) { Stop-Process -Id $e.Id -Force }  ← 真正等待进程退出
6. Start-Sleep 2; 确认 Explorer 已由 Session Manager 自动重启
```

### Level 3 — 任何模式均仅警告

| 条件 | 动作 |
|------|------|
| Non-Paged Pool > 2GB | Event Log CRITICAL + "建议尽快重启系统" |
| PTE 剩余 < 自适应阈值 | Event Log CRITICAL + "立即保存工作并重启" |
| GPU VRAM > 90% | Event Log WARNING |

---

## 双模式行为矩阵

| 操作 | 无人值守（Task Scheduler） | 手动（用户触发） |
|------|:--:|:--:|
| Level 1 清理 | ✅ 自动执行 | ✅ 自动执行 |
| Level 2 Explorer/DWM 重启 | ⚠️ 仅写 Event Log 警告 | ✅ 用户在场判定 + 确认后执行 |
| Level 3 严重告警 | ✅ Event Log | ✅ 屏幕（Write-Host 彩色）+ Event Log |
| DWM 24h 冷却 | ❌ 硬阻止 | ⚠️ 警告后可手动覆盖 |

---

## 工程安全机制

### 1. 并发协议（Mutex + running.lock）

```
1. try { $mutex.WaitOne(5000) }
   catch [AbandonedMutexException] {
       Write-Log WARN "Mutex abandoned — previous instance crashed"
       # 继续执行，进入 running.lock 恢复判定
   }
2.   读取 running.lock
3.   if PID 存活 → Mutex.Release() + exit 0（已有实例运行）
4.   if PID 死亡 → 执行恢复模式（根据 phase 决定策略）
5.   写入新 running.lock (phase="Starting", pid=$PID, timestamp)
6.   执行清理操作（过程中更新 phase/subphase）
7.   删除 running.lock
8. Mutex.Release()                 ← 释放全局锁
```

**WaitOne 超时 5000ms 后**：写 Event Log WARNING + `exit 0`（保守策略，不堆叠等待）。

### 2. 状态机锁文件 (running.lock)

```json
{
  "pid": 12345,
  "startTime": "2026-06-05T03:00:00Z",
  "phase": "ExplorerRestart",
  "subphase": "WaitingForShell",
  "lastHeartbeat": "2026-06-05T03:00:05Z",
  "attempt": 1
}
```

**恢复模式逻辑：**

| phase | 恢复动作 |
|-------|---------|
| `Level1Cleanup` | 安全重试 |
| `ExplorerRestart` / `subphase=Stopped` | 启动 Explorer 进程 |
| `DwmRestart` | 检查 DWM 进程是否存在，不存在则记录警告 |
| `CriticalError` | 不重试，写 Event Log 告警 |
| 不确定 | **保守策略**：写 Event Log 警告 + 退出 |

**僵尸锁处理**：PID 不存在 + Mutex 可获取 → 删除旧锁 + 进入恢复模式。

### 3. Invoke-AtomicOperation 包装器

```powershell
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
```

### 4. 错误处理

- `$ErrorActionPreference = 'Stop'`
- 启动时检测 `$ExecutionContext.SessionState.LanguageMode` — ConstrainedLanguage 下 `Add-Type` 失败 → 写 Event Log + exit
- 全局 `trap {}` → 写 Event Log（摘要）→ exit 99
- Event Log 写入失败 → 回退到 `%TEMP%\WinRefresh_Fallback.log`
- `Add-Type` 编译前检查类型是否已存在（`[System.AppDomain]::CurrentDomain.GetAssemblies()`）

### 5. 配置防御（3 层）

1. **文件缺失** → 全部使用自适应默认值
2. **JSON 损坏** → 全部使用默认值 + 写 Event Log 警告
3. **值越界** → 边界钳位（`Max(min, Min(value, max))`）

settings.json 是**覆盖**不是定义 — 用户只改一个值，其他全部用自适应默认值。

**state.json 同样有防御**：损坏时重建空状态文件，写 Event Log 警告，所有时间戳重置为当前时间。

### 6. 日志系统

- **格式**：JSON Lines（每行一个 JSON 对象，键名缩写以节省空间）
- **位置**：`%ProgramData%\WinRefresh\logs\`
- **轮转**：单文件 > 10MB → 归档为 `winrefresh_YYYYMMDD_HHmmss.jsonl`，保留 5 个归档
- **清理**：归档 > 30 天自动删除
- **Event Log**：WARN+ 级别写入 Application log，Source="WinRefresh"
  - **仅写摘要**（级别 + 操作名 + 退出码）— Event Log API 有 32766 字节硬限制
  - 完整数据只在 JSON Lines 文件中
- **回退**：Event Log 写入失败 → `%TEMP%\WinRefresh_Fallback.log`
- **查询**：提供 `Get-WinRefreshLog` 函数（按时间/级别筛选）+ `Export-WinRefreshLog -Format Csv`

### 7. 用户在场判定（手动模式 Explorer/DWM 重启前）

```
1. SHQueryUserNotificationState →
   QUNS_NOT_PRESENT(1) / QUNS_BUSY(2) / QUNS_RUNNING_D3D_FULL_SCREEN(3) /
   QUNS_PRESENTATION_MODE(4) → 阻止
2. GetLastInputInfo + GetTickCount64 → 无符号算术计算空闲时间
   >30s 无键鼠活动 → 判定用户离线 → 阻止
3. 用户在线 → Write-Host 彩色倒计时 15 秒
4. 每 3 秒重新检测 GetLastInputInfo → 用户中途离开 → 立即阻止
5. 阻止 → 降级为写 Event Log
```

**GetLastInputInfo 32 位回绕处理**：使用 P/Invoke `GetTickCount64()` 进行 64 位 tick 比较（非 `Environment.TickCount64` — 该属性在 .NET Framework 4.x 中不存在，PS 5.1 不可用）。`dwTime` 与 `(uint)(tick64 & 0xFFFFFFFF)` 在 32 位无符号空间内比较，利用无符号算术的自然回绕。

**已知局限**：无边框窗口化（borderless windowed）游戏可能不触发 `QUNS_RUNNING_D3D_FULL_SCREEN`，由倒计时 + 每 3 秒活动检测兜底。

### 8. DWM 冷却机制

- 无人值守：24h 硬阻止，不可绕过
- 手动模式：冷却期内显示警告，用户可显式覆盖
- 冷却时间戳存储在 `state.json`

### 9. 通知方式

**不使用 Toast 通知**（需要外部依赖或 AppUserModelID 注册，与"零外部依赖"冲突）。替代方案：
- **手动模式**：`Write-Host` 彩色高亮输出 + Event Log（用户正在看终端）
- **无人值守模式**：仅 Event Log（SYSTEM 上下文下 Toast 也不会显示）

---

## 已明确移除的危险操作

| 操作 | 移除原因 |
|------|---------|
| `NtSetSystemInformation` 清 Standby List | 未文档化 API，参数错误直接 BSOD |
| `EmptyWorkingSet` 清 Working Set | 无效反效果，页面立即 fault 回来 |
| 重启 SysMain/Superfetch | 清空预取数据库，应用启动反而变慢 |
| 停 Windows Search | 副作用（影响搜索），与 UI 卡顿无关 |
| 清事件日志 | 纯磁盘操作，与 UI 卡顿无关 |
| 清 Standby List | 反效果（强制后续 I/O 读盘）|
| Desktop Heap % 从注册表读取 | 技术上不可行（SharedSection 是静态配置，非运行时数据） |

---

## 安装和卸载

### 安装 (`Install-ScheduledTask.ps1`)

1. 检测管理员权限（自提权 `Start-Process powershell -Verb RunAs`）
2. 检测 `$ExecutionContext.SessionState.LanguageMode` — ConstrainedLanguage 下报错退出
3. 检测 ExecutionPolicy（MachinePolicy 是否覆盖了 Bypass）
4. 检测 Task Scheduler 服务状态
5. 检测 PowerShell 版本 ≥ 5.1
6. 检测是否已安装（覆盖/升级确认）
7. 复制整个模块到 `C:\Program Files\WinRefresh\`
8. 创建 `C:\ProgramData\WinRefresh\logs\`
9. 注册 Windows Event Log Source "WinRefresh"
10. 写入注册表 `HKLM\SOFTWARE\WinRefresh\InstallPath`
11. 注册 Scheduled Task：
    - 运行账户：**当前登录用户**（非 SYSTEM）
    - 选项：`Run only when user is logged on`
    - 触发器：每日凌晨 3:00 + 登录时（补跑错过的）
    - Action：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\WinRefresh\WinRefresh.ps1"`
    - 设置：`MultipleInstancesPolicy=IgnoreNew`, `StopOnBattery=$true`, `DisallowStartOnBattery=$true`, `ExecutionTimeLimit=00:10:00`

### 卸载 (`Uninstall-ScheduledTask.ps1`)

卸载脚本执行前**先将自身复制到 `%TEMP%`**，从 TEMP 执行删除操作。清理清单：

1. `Unregister-ScheduledTask -TaskName "WinRefresh" -Confirm:$false`
2. `Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\WinRefresh" -Force`
3. `Remove-Item "C:\Program Files\WinRefresh" -Recurse -Force -ErrorAction SilentlyContinue`
4. `Remove-Item "C:\ProgramData\WinRefresh" -Recurse -Force -ErrorAction SilentlyContinue`
5. `Remove-Item "HKLM:\SOFTWARE\WinRefresh" -Force -ErrorAction SilentlyContinue`
6. 清理 `%TEMP%` 中的自身副本
7. 每步失败写警告但不阻塞后续清理

---

## 边界情况覆盖

| 场景 | 处理 |
|------|------|
| 系统刚启动 5 分钟 | 所有指标低 → 仅 Level 1 健康检查，无其他操作 |
| 全屏游戏/演示中 | `SHQueryUserNotificationState`（含 PRESENTATION_MODE）→ 完全阻止 Level 2 |
| 手动触发但人走开了 | `GetLastInputInfo` + `TickCount64` > 30s → 降级到 Event Log |
| 某进程 GDI=9200 用户在忙 | `Write-Host` 彩色警告 + Event Log，不自动操作 |
| 缩略图缓存刚手动清过 | `state.json` 时间戳去重 |
| thumbcache_*.db 被 Explorer 锁定 | 逐文件 try/catch，跳过锁定的 |
| 无 GPU 的系统 | `Get-Counter` 失败 → 静默跳过 VRAM 监控 |
| iGPU 无性能计数器 | 同上 |
| Task Scheduler 服务未运行 | 安装时检测并报错 |
| ExecutionPolicy 被组策略锁定 | 安装时检测并给出明确说明 |
| Scheduled Task 与手动运行并发 | `Global\WinRefresh_Mutex` + running.lock 双重防护 |
| 上一个实例崩溃（AbandonedMutex） | catch `AbandonedMutexException` → WARN → 进入恢复模式 |
| state.json 损坏 | 重建空状态 + Event Log 警告 |
| BITS 服务未运行 | `Remove-BitsTransfer` 外包裹 try/catch |
| ConstrainedLanguage 模式 | 启动时检测 → Event Log + exit |
| 卸载时文件被锁定 | 每步 `-ErrorAction SilentlyContinue`，不阻塞 |

---

## 已知局限（无法在用户态 PowerShell 中修复）

1. **Desktop Heap 无法直接监测** — 只能在 ring 0 读取，方案使用单进程 USER/GDI 对象数作为代理指标
2. **Shell 扩展无法识别慢的** — 只能计数，无法定位哪个扩展导致右键菜单延迟
3. **`OperationStatusWindow` 文件复制检测** — Explorer 内部窗口类名，微软未公开文档化，不同 Windows 版本行为可能不一致
4. **无边框全屏游戏可能漏检** — `SHQueryUserNotificationState` 对 borderless windowed 模式不触发 D3D_FULL_SCREEN，由倒计时 + 活动检测兜底
5. **DWM 性能计数器名因版本而异** — 提供版本探测回退逻辑

---

## 技术依赖

| 依赖 | 版本 | 说明 |
|------|------|------|
| Windows | Windows 10 1607+ / Windows 11 | `SHQueryUserNotificationState` Vista+，计数器 Win10+ |
| PowerShell | 5.1 或 7.x | 脚本兼容两者，.cmd 优先 PS7 |
| .NET Framework | 4.5+（PS 5.1 内置） | P/Invoke `Add-Type` 编译；`GetTickCount64` 来自 kernel32 (Vista+)，不依赖 .NET 版本 |
| 管理员权限 | 必须 | `#Requires -RunAsAdministrator` |
| 外部工具 | **零** | 纯 PowerShell + Windows API |

---

## 审核历史

| 轮次 | 审核维度 | 结果 | 主要修复 |
|------|---------|------|---------|
| 1 (v1) | Windows 底层 | 🔴 致命 | 移除所有与 UI 无关的清理操作 |
| 1 (v1) | PowerShell 工程 | ⚠️ 多项 | 错误处理、Task Scheduler 配置 |
| 2 (v3) | Windows 底层 | ✅ 通过 | Desktop Heap 代理指标、DWM 冷却 |
| 2 (v3) | PowerShell 工程 | 🔴 4 项 | ProgramData 分离、状态机、.cmd 回退链、用户在场判定 |
| 3 (v4) | Windows 底层 | ✅ 通过 | 无新增问题 |
| 3 (v4) | PowerShell 工程 | 🔴 5 项 | 并发协议、模块路径、日志轮转、卸载安全、注册表清理 |
| 4 (v5 文档) | Windows 底层 | 🔴 2 项 | SYSTEM 跨 Session GDI 查询失效、缓存路径错误 |
| 4 (v5 文档) | PowerShell 工程 | 🔴 6 项 | SYSTEM 账户问题、AbandonedMutex、state.json/EventLog/CloseMainWindow 缺陷、Toast 依赖 |
| 5 (v6) | — | 待审核 | 修复全部上述问题：改为登录用户运行、完整 P/Invoke 签名、所有工程缺陷 |

---

## 待实现

- [ ] `WinRefresh.ps1` 主脚本
- [ ] `private/Diagnostics.ps1` — 9 项指标采集 + P/Invoke 签名
- [ ] `private/Cleanup.ps1` — 3 级清理操作
- [ ] `private/DecisionEngine.ps1` — 决策逻辑 + 双模式分叉
- [ ] `private/Logger.ps1` — JSON Lines + Event Log（摘要）+ 回退 + 轮转
- [ ] `config/settings.json` — 配置模板
- [ ] `scripts/Install-ScheduledTask.ps1` — 安装脚本
- [ ] `scripts/Uninstall-ScheduledTask.ps1` — 卸载脚本
- [ ] `WinRefresh.cmd` — 用户双击入口
- [ ] `README.md` — 使用说明
