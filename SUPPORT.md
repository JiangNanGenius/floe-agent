# Support

Floe Agent support is community and best-effort. Prerelease, development, and unsigned builds should not be used with production credentials or machines. [简体中文支持文档](SUPPORT.zh-CN.md)

## 1.7 问题报告 / Upgrade reports

1.7 仍在开发，先核对[实施状态](docs/FLOE_1_7_IMPLEMENTATION_STATUS.md)与[兼容性说明](docs/FLOE_1_7_COMPATIBILITY.md)。报告环境/包问题时附环境层、包版本、失败阶段及脱敏错误；媒体问题附输入编码、尺寸、帧率、声道、操作参数和是否能重新播放输出。模型问题区分目录可见、安装成功、加载成功与推理成功。

Include the exact commit/build and device/SDK. Preserve recoverable copies and failed transaction evidence; follow [recovery guidance](docs/FLOE_1_7_MIGRATION.md) before manually deleting state. Never attach credentials or private media without reviewing the export.

## Where to ask

- Use a [GitHub issue](https://github.com/JiangNanGenius/floe-agent/issues/new/choose) for a reproducible bug, build problem, documentation gap, or scoped feature proposal.
- Check the [README](README.md), [user guide](docs/USER_GUIDE.md), and existing issues before opening a new report.
- Include the app version/build, branch or commit when relevant, iOS/macOS/Xcode versions, target device or simulator, reproduction steps, expected behavior, observed behavior, and sanitized logs.
- For background, voice, browser, or provider failures, identify the phase and attach a redacted diagnostics export when possible.

Never include API keys, passwords, private keys, hostnames, personal files, or other secrets. Report vulnerabilities privately using [SECURITY.md](SECURITY.md).
