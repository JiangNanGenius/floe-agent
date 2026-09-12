# Floe Agent 支持

[English](SUPPORT.md) · [使用指南](docs/USER_GUIDE.zh-CN.md)

Floe Agent 目前由社区尽力提供支持。预发布、开发和未签名版本不应使用生产凭据或连接生产主机。

## 1.7 问题报告 / Upgrade reports

1.7 仍在开发，先核对[实施状态](docs/FLOE_1_7_IMPLEMENTATION_STATUS.md)与[兼容性说明](docs/FLOE_1_7_COMPATIBILITY.md)。报告环境/包问题时附环境层、包版本、失败阶段及脱敏错误；媒体问题附输入编码、尺寸、帧率、声道、操作参数和是否能重新播放输出。模型问题区分目录可见、安装成功、加载成功与推理成功。

Include the exact commit/build and device/SDK. Preserve recoverable copies and failed transaction evidence; follow [recovery guidance](docs/FLOE_1_7_MIGRATION.md) before manually deleting state. Never attach credentials or private media without reviewing the export.

## 提交问题

- 可复现 Bug、构建问题、文档缺口或范围明确的功能建议，请创建 [GitHub Issue](https://github.com/JiangNanGenius/floe-agent/issues/new/choose)。
- 创建前先查看[中文 README](README.zh-CN.md)、[使用指南](docs/USER_GUIDE.zh-CN.md)和已有 Issue。
- 报告应包含 App 版本/Build、相关分支或提交、iOS/macOS/Xcode 版本、设备或模拟器、复现步骤、预期结果、实际结果和脱敏日志。
- 后台、语音、浏览器或服务商问题应注明失败阶段，并尽量附上从设置导出的脱敏诊断。

不要提交 API Key、密码、私钥、主机名、个人文件或其他秘密。安全漏洞请按[安全策略](SECURITY.zh-CN.md)私下报告。
