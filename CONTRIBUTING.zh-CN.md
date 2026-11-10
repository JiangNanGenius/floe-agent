# 为 Floe Agent 贡献代码

代码 Agent 的仓库工作约定见 [AGENTS.md](AGENTS.md)。

[English](CONTRIBUTING.md) · [中文 README](README.zh-CN.md) · [安全策略](SECURITY.zh-CN.md)

感谢参与 Floe Agent。项目已有 App Store 正式版及独立测试渠道，接口仍在调整；涉及凭据、文件、浏览器控制或远程电脑的改动需要更严格的安全审阅。

<a id="floe-17-integration-workflow"></a>
## 当前开发流程

先检查实际 `main`、工作区状态、相关 diff 与活动 worktree；仅在需要隔离时创建聚焦任务的 `codex/` 分支。先阅读[工程指南](FloeAgent/README.md)、[架构](docs/ARCHITECTURE_OVERVIEW.md)与[本地验证说明](docs/FLOE_LOCAL_QUALIFICATION.zh-CN.md)，在研计划和旧快照分别从[文档入口](docs/README.md)访问。保留未验收修改、复现输入和恢复证据，不用整分支覆盖重叠修改。

按影响运行本地定向测试和相关 App 构建，云端 CI 补充独立检查与分发流程。用户行为变化时同步双语指南，记录源码、SDK、设备／模拟器和实际结果；产物上传不等于发布完成。运行时锁定检查保持只读，生成工程与 `project.yml` 一致。

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
brew install xcodegen
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
bash FloeAgent/scripts/gen_project.sh
open FloeAgent/FloeAgent.xcodeproj
```

使用 [AGENTS.md](AGENTS.md) 要求的已安装完整 Xcode 与工具链；App 兼容 iOS/iPadOS 26 及更新版本。修改 `project.yml` 的目标、资源、设置、版本或 scheme 后，重新生成并检查匹配的工程：

```bash
bash FloeAgent/scripts/gen_project.sh
git diff -- FloeAgent/project.yml FloeAgent/FloeAgent.xcodeproj/project.pbxproj
```

生成脚本先重新生成，再报告仍存在的已跟踪修改；检查输出，不丢弃无关工作。按影响选择验证，不要求每次运行整个 SwiftPM 套件。`FloeAgent/scripts/local_build.sh` 只覆盖跨平台 SwiftPM 子集，不构建 iOS App。模拟器运行遵守 AGENTS.md 的固定 iPad 与串行锁规则。

## PR 检查表

- 为改动行为补充或更新测试，并报告实际运行命令和结果。
- 不提交 API Key、密码、私钥、主机名、个人路径、设备 ID 或未脱敏日志。
- 公共行为变化时同步更新英文和简体中文 README/使用指南。
- 新增网络目标、Entitlement、依赖、数据库、审批或隐私行为时明确说明。
- 保持任务权限的 Provider Schema 过滤与执行端授权双重校验。
- 不把模型输出、Skill 内容或远程内容当作可信指令。
- 不混入无关格式化或生成文件漂移。

提交贡献即表示同意按仓库的 [Mozilla Public License 2.0](LICENSE) 授权。
