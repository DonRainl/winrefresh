# Changelog

本项目的版本变更记录，格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

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
