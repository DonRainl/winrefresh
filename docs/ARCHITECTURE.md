# WinRefresh 架构说明

本文档描述 WinRefresh 的模块划分、数据流与安全设计，帮助贡献者快速理解代码结构。

## 概览

```
┌─────────────────────────────────────────────────────────┐
│ WinRefresh.ps1 (主入口/编排)                              │
│  启动检查 → 并发协议 → 配置加载 → 诊断 → 决策 → 执行 → 汇总  │
└──────────────┬──────────────────┬───────────────────────┘
               │ 点源加载           │
      ┌────────▼────────┐  ┌───────▼────────┐
      │ private/        │  │ config/        │
      │  Diagnostics    │  │ settings.json  │── 阈值/清理/日志配置（可覆盖）
      │  DecisionEngine │  └────────────────┘
      │  Cleanup        │
      │  Logger         │
      └─────────────────┘
```

## 模块职责

| 模块 | 职责 | 关键函数 |
|------|------|----------|
| `WinRefresh.ps1` | 编排入口：参数解析、启动检查（ConstrainedLanguage）、并发协议、调用各阶段 | — |
| `private/Diagnostics.ps1` | 9 项系统指标采集；P/Invoke 类型编译（`WinRefresh.Win32Gui`）；自适应阈值计算 | `Get-SystemDiagnostics`, `Get-AdaptiveThresholds`, `Initialize-Diagnostics` |
| `private/DecisionEngine.ps1` | 将诊断结果与阈值比较，输出执行计划（是否重启 Explorer/DWM、各级告警）；按模式降级 | `Get-DecisionPlan` |
| `private/Cleanup.ps1` | 三级清理操作与安全检查；原子操作包装器 | `Invoke-Level1Cleanup`, `Invoke-ExplorerRestart`, `Invoke-DwmRestart` |
| `private/Logger.ps1` | JSON Lines 日志、轮转、Event Log 集成；`ConvertTo-Hashtable`（PS 5.1 递归转换） | `Write-Log`, `Get-WinRefreshLog`, `Export-WinRefreshLog` |
| `scripts/Install-ScheduledTask.ps1` | 安装：复制文件、注册事件日志源、写注册表、注册计划任务 | — |
| `scripts/Uninstall-ScheduledTask.ps1` | 卸载：自复制到 TEMP 后清理全部产物 | — |

## 数据流

```
Get-SystemDiagnostics (9 指标 + 用户状态)
        │
        ▼
Get-DecisionPlan (阈值比较 → 执行计划)
        │  plan.ShouldRestartExplorer / ShouldRestartDwm / Level2Warnings / Level3Warnings
        ▼
WinRefresh.ps1 按序执行：
  1. Invoke-Level1Cleanup            （始终执行）
  2. Explorer/DWM 重启                （仅手动模式，无人值守降级为告警）
  3. Write-Level3Warning             （仅告警，提示保存工作/重启）
```

### 9 项指标

| # | 指标 | 来源 | 决策用途 |
|---|------|------|----------|
| 1 | 各进程 GDI/USER 对象数 | `GetGuiResources` (P/Invoke) | 定位泄漏进程；explorer 超限 → 重启 |
| 2 | 系统总句柄数 | `Get-Process.Handles` 累加 | Level 3 告警 |
| 3 | Non-Paged Pool | `\Memory\Pool Nonpaged Bytes` | Level 3 告警（建议重启） |
| 4 | DWM 健康 | 进程指标 + 跳帧计数器（按路径匹配，规避本地化） | 超限 → 重启 DWM |
| 5 | Explorer 指标 | `GetGuiResources` + 进程句柄/线程/内存 | GDI/句柄/线程/内存超限 → 重启 |
| 6 | 空闲系统 PTE | `\Memory\Free System Page Table Entries` × 4096 | Level 3 告警（临界则建议保存工作） |
| 7 | GPU VRAM | `\GPU Adapter Memory\*` | 仅记录到摘要 |
| 8 | Shell 扩展数量 | 注册表 HKLM + Wow6432Node + HKCU | 摘要提示 |
| 9 | Standby 列表 | `\Memory\Standby Cache Core Bytes` | 仅记录 |

### 自适应阈值

`Get-AdaptiveThresholds` 按物理内存生成 PTE 与句柄阈值（PTE：`max(512MB, min(RAM/32, 2GB))`；句柄：`max(30000, min(RAM_GB×2500, 120000))`）。`config/settings.json` 中显式配置的值优先（`null` 表示走自适应）。

## 并发协议

1. 获取全局互斥锁 `Global\WinRefresh_Mutex`（5s 超时；`AbandonedMutexException` → 进入恢复模式）
2. 读取 `running.lock`：PID 存活 → 退出；PID 死亡 → 判定崩溃，删除锁进入恢复
3. 原子写锁（临时文件 + `Move-Item`，NTFS 原子重命名）
4. 运行中通过 `Update-LockPhase` 更新阶段与心跳
5. finally 块释放锁与互斥体

## 安全检查（Level 2 前置）

重启 Explorer/DWM 前依次检查，任一失败即中止：

1. `Test-UserPresent`：通知状态（全屏/演示/忙碌等拦截）+ 空闲时间 > 30s 拦截
2. `Test-FileCopyInProgress`：`FindWindow("OperationStatusWindow")` 检测文件复制
3. `Wait-Countdown`：15 秒倒计时，期间用户重新活跃或进入全屏则取消
4. DWM 额外有 24h 冷却期（`state.json` 记录 `DwmLastRestart`，先写时间戳再杀进程，防止驱动崩溃后状态丢失）

## 容错设计

| 层 | 策略 |
|----|------|
| 配置 | 缺失→默认 / JSON 损坏→默认 / 越界→钳位 |
| 系统 API | WMI/Counter/注册表失败 → 返回 `$null` 并记 WARN，决策引擎对 null 免疫 |
| 日志 | 文件写失败 → 回退 `%TEMP%\WinRefresh_Fallback.log`；Event Log 源未注册 → 静默跳过 |
| 清理 | `Invoke-AtomicOperation` 包装，按异常类型分级（拒绝访问/占用/其他） |
| 临时文件清理 | 跳过 ReparsePoint 防符号链接循环；`-Attributes` 失败回退属性位检查 |

## 兼容性约束

- **PS 5.1 严格兼容**：不用 `??`、`-AsHashtable`、`Environment.TickCount64`
- P/Invoke 类型只在 FullLanguage 模式下可编译（`ConstrainedLanguage` 启动即退出，exit 98）
- 计数器路径按 PATH 匹配而非本地化名称（德语系统 "Desktopfenster-Manager" 也能命中）
- 32 位 PS 在 64 位系统上通过 `SysNative` 解析 System32 路径
- 空闲时间计算在 C# 内完成，处理 32 位 `dwTime` 回绕（>49.7 天运行时长）

## 扩展点

- **新增指标**：在 `Diagnostics.ps1` 加采集函数并在 `Get-SystemDiagnostics` 挂载；在 `DecisionEngine.ps1` 消费
- **新增清理操作**：`Cleanup.ps1` 用 `Invoke-AtomicOperation` 包装；Level 1 加入 `Invoke-Level1Cleanup`
- **新增配置**：`settings.json` 对应小节加键，读取处做 null 防御 + 钳位
