# 为 Floe Agent 贡献代码

代码 Agent 的仓库工作约定见 [AGENTS.md](AGENTS.md)。

[English](CONTRIBUTING.md) · [中文 README](README.zh-CN.md) · [安全策略](SECURITY.zh-CN.md)

感谢参与 Floe Agent。项目已经发布预览版本，但接口仍在调整；涉及凭据、文件、浏览器控制或远程电脑的改动需要更严格的安全审阅。

## Floe 1.7 integration workflow

先检查实际 main、工作区状态与活动 worktree；需要新分支时使用聚焦任务的 `codex/` 分支。先阅读[实施状态](docs/FLOE_1_7_IMPLEMENTATION_STATUS.md)与[构建验收说明](docs/FLOE_1_7_BUILD_AND_ACCEPTANCE.md)，保留未验收修改、复现输入和恢复证据。不要用整分支覆盖重叠修改。

Use focused local tests and relevant local App builds; cloud CI supplies independent checks and release workflows. Update both language guides when user behavior changes. Report the tested commit, SDK, device/simulator and actual output; do not turn an artifact upload into a release claim. Runtime lock check mode must remain read-only. Generated Xcode changes must match `project.yml`.

## 开始之前

1. 阅读[产品定位](PRODUCT.md)、[当前状态](docs/CURRENT_STATUS.md)、[架构总览](docs/ARCHITECTURE_OVERVIEW.md)和[安全策略](SECURITY.zh-CN.md)。
2. 搜索已有 Issue 和 Pull Request，避免重复工作。
3. 大型功能、依赖、架构、数据库或安全边界改动应先创建 Issue。
4. PR 保持聚焦，并说明用户影响、取舍、安全影响和验证证据。

漏洞不要提交到公开 Issue，请按安全策略创建私有 GitHub Security Advisory。

## 开发环境

以当前 main 为基线，保留已有修改；安装渠道以当前版本状态为准：

```bash
git clone https://github.com/JiangNanGenius/floe-agent.git
cd floe-agent
cd FloeAgent
brew install xcodegen
bash scripts/gen_project.sh
scripts/local_build.sh
```

需要包含 iOS 26 SDK 或更新版本的完整 Xcode 与 Swift 6.2+。修改 `project.yml` 后必须重新生成并提交一致的 `.xcodeproj`：

```bash
swift build
swift test
bash scripts/gen_project.sh
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
