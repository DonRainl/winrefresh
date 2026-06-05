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
