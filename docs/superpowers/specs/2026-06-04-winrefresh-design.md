# WinRefresh — Windows 长时间不关机变卡的自动修复工具

## 元信息

| 字段 | 值 |
|------|-----|
| 日期 | 2026-06-04 |
| 版本 | v5 |
| 状态 | 设计阶段（待实现） |
| 审核轮次 | 4 轮 subagent 审核（Windows 底层 ×2 + PowerShell 工程 ×2） |

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
- `ProgramData` 放可写内容（日志、锁、状态）— SYSTEM 和 Administrators 默认可写
- 安装到固定路径避免目录移动导致 Task Scheduler 失效

---

## 诊断指标（9 项）

| # | 指标 | 采集方式 | 阈值 | 说明 |
|---|------|---------|------|------|
| 1 | 单进程 GDI/USER 对象数 | `GetGuiResources` (user32.dll P/Invoke) | GDI > 9000, USER > 9000 | 跳过 Session 0 进程 |
| 2 | 总句柄数 | `Get-Process` Handles 属性 | 自适应：`Max(30000, Min(RAM_GB×2500, 120000))` | 无外部依赖 |
| 3 | Non-Paged Pool | `Get-Counter '\Memory\Pool Nonpaged Bytes'` | > 2GB 绝对值 | 放弃百分比，用绝对值 |
| 4 | DWM 健康度 | `Get-Process dwm` + `\Desktop Window Manager\Composition frames skipped\*` | WS > 1GB / Handles > 5000 / 跳帧 > 0 | 跳帧率是直接指标 |
| 5 | Explorer GDI/USER/句柄 | `GetGuiResources` 定向查询 | GDI > 9000 | Explorer 在用户 session 内，查询可靠 |
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

---

## 清理操作（3 级分级）

### Level 1 — 始终安全执行（无人值守 + 手动）

| 操作 | 方法 | 条件 |
|------|------|------|
| 清 Temp 文件 | `Remove-Item`，逐文件 try/catch | > 500MB 且 > 24h 旧文件 |
| 清 DNS Cache | `Clear-DnsClientCache` | 始终 |
| 清 BITS 完成队列 | `Remove-BitsTransfer` | 已完成项 |
| 重建图标缓存 | `ie4uinit.exe -ClearIconCache` | 始终（不杀 Explorer，仅桌面图标瞬间刷新） |
| 重建缩略图缓存 | 删除 `thumbcache_*.db`，逐文件 try/catch 跳过锁定 | 每 30 天（基于 state.json 时间戳去重） |

### Level 2 — 无人值守 vs 手动行为分叉

**无人值守模式（Task Scheduler 触发）：全部降级为仅写 Event Log 警告。不执行任何自动重启。**

**手动模式（用户 .cmd 或直接运行 WinRefresh.ps1）：**

| 操作 | 方法 | 安全前置条件 |
|------|------|-------------|
| 某进程 GDI > 9000 | Toast 通知 + 询问用户是否重启该进程 | — |
| Explorer 超标 | 渐进式安全重启 | ① `SHQueryUserNotificationState` 非全屏/D3D ② `GetLastInputInfo` < 30s（用户在场）③ `OperationStatusWindow` 无文件复制 ④ `CloseMainWindow()` → 等 3 秒 → `Stop-Process`（不用 `-Force`）⑤ 15 秒倒计时 + 每 3 秒重检用户在场 |
| DWM 超标 | `Stop-Process -Name dwm` | 同上 ①②④⑤ + 24h 冷却（手动可覆盖） |

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
| Level 3 严重告警 | ✅ Event Log | ✅ 屏幕 + Event Log |
| DWM 24h 冷却 | ❌ 硬阻止 | ⚠️ 警告后可手动覆盖 |

---

## 工程安全机制

### 1. 并发协议（Mutex + running.lock）

```
1. Mutex.WaitOne(5000ms)           ← 获取 Global\WinRefresh_Mutex
2.   读取 running.lock
3.   if PID 存活 → Mutex.Release() + exit 0（已有实例运行）
4.   if PID 死亡 → 执行恢复模式（根据 phase 决定策略）
5.   写入新 running.lock (phase="Starting", pid=$PID, timestamp)
6.   执行清理操作（过程中更新 phase/subphase）
7.   删除 running.lock
8. Mutex.Release()                 ← 释放全局锁
```

### 2. 状态机锁文件 (running.lock)

```json
{
  "pid": 12345,
  "startTime": "2026-06-04T03:00:00Z",
  "phase": "ExplorerRestart",
  "subphase": "WaitingForShell",
  "lastHeartbeat": "2026-06-04T03:00:05Z",
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
- 全局 `trap {}` → 写 Event Log → exit 99
- Event Log 写入失败 → 回退到 `%TEMP%\WinRefresh_Fallback.log`
- `Add-Type` 编译前检查类型是否已存在（`[System.AppDomain]::CurrentDomain.GetAssemblies()`）

### 5. 配置防御（3 层）

1. **文件缺失** → 全部使用自适应默认值
2. **JSON 损坏** → 全部使用默认值 + 写 Event Log 警告
3. **值越界** → 边界钳位（`Max(min, Min(value, max))`）

settings.json 是**覆盖**不是定义 — 用户只改一个值，其他全部用自适应默认值。

### 6. 日志系统

- **格式**：JSON Lines（每行一个 JSON 对象，键名缩写以节省空间）
- **位置**：`%ProgramData%\WinRefresh\logs\`
- **轮转**：单文件 > 10MB → 归档为 `winrefresh_YYYYMMDD_HHmmss.jsonl`，保留 5 个归档
- **清理**：归档 > 30 天自动删除
- **Event Log**：WARN+ 级别写入 Application log，Source="WinRefresh"
- **回退**：Event Log 写入失败 → `%TEMP%\WinRefresh_Fallback.log`
- **查询**：提供 `Get-WinRefreshLog` 函数（按时间/级别筛选）+ `Export-WinRefreshLog -Format Csv`

### 7. 用户在场判定（手动模式 Explorer/DWM 重启前）

```
1. SHQueryUserNotificationState → QUNS_BUSY / QUNS_RUNNING_D3D_FULL_SCREEN → 阻止
2. GetLastInputInfo → >30s 无键鼠活动 → 判定用户离线 → 阻止
3. 用户在线 → Toast 通知 + 15 秒倒计时
4. 每 3 秒重新检测 GetLastInputInfo → 用户中途离开 → 立即阻止
5. 阻止 → 降级为写 Event Log
```

**已知局限**：无边框窗口化（borderless windowed）游戏可能不触发 QUNS_RUNNING_D3D_FULL_SCREEN，由倒计时 + 每 3 秒活动检测兜底。

### 8. DWM 冷却机制

- 无人值守：24h 硬阻止，不可绕过
- 手动模式：冷却期内显示警告，用户可显式覆盖
- 冷却时间戳存储在 `state.json`

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
2. 检测 ExecutionPolicy（MachinePolicy 是否覆盖了 Bypass）
3. 检测 Task Scheduler 服务状态
4. 检测 PowerShell 版本 ≥ 5.1
5. 复制整个模块到 `C:\Program Files\WinRefresh\`
6. 创建 `C:\ProgramData\WinRefresh\logs\`
7. 注册 Windows Event Log Source "WinRefresh"
8. 写入注册表 `HKLM\SOFTWARE\WinRefresh\InstallPath`
9. 注册 Scheduled Task：
   - 触发器：每日凌晨 3:00 + 登录时（补跑错过的）
   - Action：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\Program Files\WinRefresh\WinRefresh.ps1"`
   - 设置：`MultipleInstancesPolicy=IgnoreNew`, `StopOnBattery=$true`, `DisallowStartOnBattery=$true`
   - 运行账户：`NT AUTHORITY\SYSTEM`

### 卸载 (`Uninstall-ScheduledTask.ps1`)

卸载脚本执行前**先将自身复制到 `%TEMP%`**，从 TEMP 执行删除操作。清理清单：

1. `Unregister-ScheduledTask -TaskName "WinRefresh"`
2. `Remove-Item "HKLM:\SYSTEM\CurrentControlSet\Services\EventLog\Application\WinRefresh" -Force`
3. `Remove-Item "C:\Program Files\WinRefresh" -Recurse -Force`
4. `Remove-Item "C:\ProgramData\WinRefresh" -Recurse -Force`
5. `Remove-Item "HKLM:\SOFTWARE\WinRefresh" -Force`
6. 清理 `%TEMP%` 中的自身副本

---

## 边界情况覆盖

| 场景 | 处理 |
|------|------|
| 系统刚启动 5 分钟 | 所有指标低 → 仅 Level 1 健康检查，无其他操作 |
| 全屏游戏/演示中 | `SHQueryUserNotificationState` → 完全阻止 Level 2 操作 |
| 手动触发但人走开了 | `GetLastInputInfo` > 30s → 降级到 Event Log |
| 某进程 GDI=9200 用户在忙 | Toast 询问 → 用户选 No 跳过 |
| 缩略图缓存刚手动清过 | `state.json` 时间戳去重 |
| thumbcache_*.db 被 Explorer 锁定 | 逐文件 try/catch，跳过锁定的 |
| 无 GPU 的系统 | `Get-Counter` 失败 → 静默跳过 VRAM 监控 |
| iGPU 无性能计数器 | 同上 |
| Task Scheduler 服务未运行 | 安装时检测并报错 |
| ExecutionPolicy 被组策略锁定 | 安装时检测并给出明确说明 |
| Scheduled Task 与手动运行并发 | `Global\WinRefresh_Mutex` + running.lock 双重防护 |

### 已知局限（无法在用户态 PowerShell 中修复）

1. **Desktop Heap 无法直接监测** — 只能在 ring 0 读取，方案使用单进程 USER/GDI 对象数作为代理指标
2. **Shell 扩展无法识别慢的** — 只能计数，无法定位哪个扩展导致右键菜单延迟
3. **`OperationStatusWindow` 文件复制检测** — Explorer 内部窗口类名，微软未公开文档化，不同 Windows 版本行为可能不一致
4. **无边框全屏游戏可能漏检** — `SHQueryUserNotificationState` 对 borderless windowed 模式不触发 D3D_FULL_SCREEN，由倒计时 + 活动检测兜底

---

## 技术依赖

| 依赖 | 版本 | 说明 |
|------|------|------|
| Windows | Windows 10 1607+ / Windows 11 | `SHQueryUserNotificationState` 需要 Vista+，所有计数器 Win10+ |
| PowerShell | 5.1 或 7.x | 脚本兼容两者，.cmd 优先 PS7 |
| .NET Framework | 4.5+（PS 5.1 内置） | P/Invoke `Add-Type` 编译 |
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

---

## 待实现

- [ ] `WinRefresh.ps1` 主脚本
- [ ] `private/Diagnostics.ps1` — 9 项指标采集
- [ ] `private/Cleanup.ps1` — 3 级清理操作 + P/Invoke
- [ ] `private/DecisionEngine.ps1` — 决策逻辑 + 双模式分叉
- [ ] `private/Logger.ps1` — JSON Lines + Event Log + 轮转
- [ ] `config/settings.json` — 配置模板
- [ ] `scripts/Install-ScheduledTask.ps1` — 安装脚本
- [ ] `scripts/Uninstall-ScheduledTask.ps1` — 卸载脚本
- [ ] `WinRefresh.cmd` — 用户双击入口
- [ ] `README.md` — 使用说明
