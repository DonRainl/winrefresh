# Changelog

本项目的版本变更记录，格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- **Windows 音频服务（`audiosrv`）自动维护**：
  - 新增 `Restart-AudioService`，在 Level 1 清理中自动重置 Windows Audio 服务，彻底解决长期开机或睡眠唤醒后 USB 声卡/条形音箱时钟假死导致的 PotPlayer 等视频播放器音画同步幻灯片卡顿问题（可通过 `cleanup.restart_audio_service` 配置）
- **带安全守护的无人值守 Explorer 自动重启**：
  - 新增 `unattended_restart_explorer` 配置（默认开启），在凌晨或唤醒补跑检测到 Explorer 线程/句柄超限时，自动检查关键生产力软件（默认保护 `Adobe Premiere Pro`、`AfterFX`、`blender`、`Photoshop`、`obs64`）和文件传输状态；无敏感软件且无文件传输时安全静默重启 Explorer
- **一键桌面快捷方式与 UAC 提权**：
  - 安装脚本自动在当前用户桌面创建「WinRefresh 一键系统刷新」快捷方式
  - 优化 `WinRefresh.cmd`：双击自动请求管理员权限并在完成后暂停显示摘要，免去开启终端和手动敲命令
- **计划任务休眠与唤醒适配**：
  - 计划任务启用 `StartWhenAvailable`（睡眠错过后开机/唤醒立即自动补跑）与 `WakeToRun`（允许凌晨定时唤醒）
  - 解除对电池/交流电源的严苛限制（修复睡眠唤醒状态下抛出 `0x800710E0` 被拒绝错误的问题）

### Added

- 决策引擎规则增强与长时间不关机场景优化：
  - 新增系统运行时间（Uptime）诊断规则（默认 30 天超限预警）
  - 新增 Explorer 句柄数（`explorer_handles`，默认 5000）、线程数（`explorer_threads`，默认 150）及工作集（`explorer_working_set_mb`，默认 1024MB）判定规则，解决长期开机导致 Shell 跨窗口点击卡死、线程数暴增的问题
  - 新增 DWM 线程数（`dwm_threads`，默认 100）判定规则
  - 新增 `-BypassUserPresence` 参数，并在手动强制重启（`-ForceExplorerRestart` / `-ForceDwmRestart`）模式下默认放行，修复因倒计时自然流逝或输入卡死导致的用户空闲误判问题
- 开源发布准备：
  - 新增 MIT License、CONTRIBUTING.md、SECURITY.md、CHANGELOG.md
  - 新增英文版 README（README.en.md）
  - 新增 GitHub Actions CI（语法检查 + 单元测试 + 集成测试，Windows runner）
  - 新增 issue / PR 模板
  - 新增 docs/ARCHITECTURE.md 架构说明
  - 版本号统一从 `VERSION` 文件读取（主脚本横幅、日志、安装注册表）
  - 补充 `.gitignore`（运行时产物、本地工具目录）

## [1.0.0] - 2026-06-05

### Added

- 核心功能：9 项系统指标采集（GDI/USER 对象、句柄、Non-Paged Pool、DWM 健康、Explorer、PTE、GPU VRAM、Shell 扩展、Standby 列表）
- 三级清理体系：
  - Level 1：临时文件、DNS 缓存、BITS 队列、图标/缩略图缓存
  - Level 2：安全重启 Explorer / DWM（用户在场检测 + 全屏/演示检测 + 文件复制检测 + 15 秒倒计时）
  - Level 3：Non-Paged Pool / PTE 严重告警
- 智能决策引擎：自适应阈值（按物理内存调整）+ 配置可覆盖（config/settings.json）
- 双模式运行：手动模式（可执行 Level 2）与计划任务无人值守模式（仅 Level 1）
- 并发安全：`Global\WinRefresh_Mutex` 全局互斥锁 + JSON 运行锁 + 崩溃恢复
- 结构化日志：JSON Lines（10MB 轮转、保留 5 个归档、30 天清理）+ Windows Event Log 集成
- 安装/卸载脚本：复制到 Program Files、注册计划任务（每日 3:00 + 登录时）、事件日志源、注册表
- 测试套件：语法检查、Logger 单元测试、决策引擎/配置测试、跨模块集成测试

[Unreleased]: https://github.com/DonRainl/winrefresh/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/DonRainl/winrefresh/releases/tag/v1.0.0
