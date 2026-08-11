# 贡献指南

感谢你愿意为 WinRefresh 贡献力量！在提交代码之前，请花几分钟阅读以下约定。

## 开发环境

- Windows 10 1607+ 或 Windows 11
- PowerShell 5.1 或 7.x
- Git

## 代码约定

WinRefresh 的目标是 **Windows PowerShell 5.1 完全兼容**（计划任务默认跑在 5.1 上），因此：

- ❌ 不使用 `??` 空合并运算符（PS 7+）
- ❌ 不使用 `-AsHashtable` 参数（PS 6+，用 `private/Logger.ps1` 中的 `ConvertTo-Hashtable`）
- ❌ 不使用 `Environment.TickCount64`（.NET Framework 4.x 没有该属性，见 `Diagnostics.ps1` 的注释）
- ✅ 所有模块必须可被 `WinRefresh.ps1` 通过 `. "$scriptDir\private\xxx.ps1"` 点源加载
- ✅ 对外部不可用的情况（WMI/Counter 失败、权限不足、事件日志源未注册）做容错，降级而非崩溃
- ✅ 新增可配置项时，遵循"缺失→默认 / 损坏→默认 / 越界→钳位"的 3 层防御
- ✅ 关键操作（重启 Explorer/DWM）必须经过安全检查，禁止移除保护逻辑

## 运行测试

所有测试脚本均返回「失败用例数」作为退出码（0 = 全部通过）：

```powershell
# 1. 语法检查（所有模块）
.\tests\syntax-check.ps1

# 2. Logger 单元测试
.\tests\logger-tests.ps1

# 3. 决策引擎 + 配置解析测试
.\tests\decision-config-tests.ps1

# 4. 跨模块集成测试（会调用真实系统 API）
.\tests\integration-test.ps1
```

提交 PR 前请确保 4 个测试全部通过（CI 也会自动运行）。

## 提交 PR 的流程

1. Fork 本仓库并 clone 到本地
2. 创建功能分支：`git checkout -b feat/your-feature`
3. 修改代码并补充/更新测试
4. 本地运行全部测试
5. 提交并 push：`git push origin feat/your-feature`
6. 在 GitHub 上发起 Pull Request，描述改动内容、动机和测试结果

### Commit message 规范

- 用简洁的中文或英文描述改动，建议带前缀：
  - `fix:` 缺陷修复
  - `feat:` 新功能
  - `test:` 测试相关
  - `docs:` 文档相关
  - `refactor:` 重构（不改变行为）
  - `chore:` 杂项（构建、依赖等）

## Issue 规范

- Bug 报告请附上：Windows 版本、PowerShell 版本、复现步骤、日志片段（`C:\ProgramData\WinRefresh\logs\`）
- 功能建议请说明：要解决的问题、期望的行为、可选的实现思路

## 安全相关

WinRefresh 以管理员权限运行并能重启 Explorer/DWM，属于**高风险工具**。涉及以下内容的改动请格外谨慎，并在 PR 描述中明确说明安全影响：

- 重启/终止进程的逻辑
- 删除文件/注册表项的逻辑
- P/Invoke 声明
- 计划任务与安装脚本

安全漏洞请通过 SECURITY.md 中的渠道私密报告，**不要**公开提交漏洞类 issue。
