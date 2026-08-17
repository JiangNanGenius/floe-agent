# 为 Floe Agent 贡献代码

[English](CONTRIBUTING.md) · [中文 README](README.zh-CN.md) · [安全策略](SECURITY.zh-CN.md)

感谢参与 Floe Agent。项目已经发布预览版本，但接口仍在调整；涉及凭据、文件、浏览器控制或远程电脑的改动需要更严格的安全审阅。

## 开始之前

1. 阅读[产品定位](PRODUCT.md)、[开发计划](docs/DEVELOPMENT_PLAN.md)、[架构总览](docs/ARCHITECTURE_OVERVIEW.md)和[安全策略](SECURITY.zh-CN.md)。
2. 搜索已有 Issue 和 Pull Request，避免重复工作。
3. 大型功能、依赖、架构、数据库或安全边界改动应先创建 Issue。
4. PR 保持聚焦，并说明用户影响、取舍、安全影响和验证证据。

漏洞不要提交到公开 Issue，请按安全策略创建私有 GitHub Security Advisory。

## 开发环境

当前 1.2.x 实现在 `agent/alpha-daily` 分支维护。选择基础分支前先查看最新 Release 或已打开的 Pull Request：

```bash
git clone https://github.com/JiangNanGenius/floe-agent.git
cd floe-agent
git switch agent/alpha-daily
cd FloeAgent
brew install xcodegen
xcodegen generate
scripts/local_build.sh
```

需要包含 iOS 26 SDK 或更新版本的完整 Xcode 与 Swift 6.2+。修改 `project.yml` 后必须重新生成并提交一致的 `.xcodeproj`：

```bash
swift build
swift test
xcodegen generate
```

部分 iOS-only 目标需要完整 Xcode 而非命令行 Swift 工具链。

## PR 检查表

- 为改动行为补充或更新测试，并报告实际运行命令和结果。
- 不提交 API Key、密码、私钥、主机名、个人路径、设备 ID 或未脱敏日志。
- 公共行为变化时同步更新英文和简体中文 README/使用指南。
- 新增网络目标、Entitlement、依赖、数据库、审批或隐私行为时明确说明。
- 保持任务权限的 Provider Schema 过滤与执行端授权双重校验。
- 不把模型输出、Skill 内容或远程内容当作可信指令。
- 不混入无关格式化或生成文件漂移。

提交贡献即表示同意按仓库的 [Mozilla Public License 2.0](LICENSE) 授权。
