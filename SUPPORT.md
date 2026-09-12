# Support

Floe Agent support is community and best-effort. Prerelease, development, and unsigned builds should not be used with production credentials or machines. [简体中文支持文档](SUPPORT.zh-CN.md)

## 1.7 问题报告 / Upgrade reports

Floe 1.7 remains under integration. Check [status](docs/FLOE_1_7_IMPLEMENTATION_STATUS.md) and [compatibility](docs/FLOE_1_7_COMPATIBILITY.md) first. For environment/package failures, include the layer, package version, failed stage and sanitized error. For media failures, include input codec, dimensions, frame rate, channels, requested operations and whether the output reopens. Distinguish model catalog visibility, installation, loading and successful inference.

Include the exact commit/build and device/SDK. Preserve recoverable copies and failed transaction evidence; follow [recovery guidance](docs/FLOE_1_7_MIGRATION.md) before deleting state. Never attach credentials or private media without reviewing the export.

## Where to ask

- Use a [GitHub issue](https://github.com/JiangNanGenius/floe-agent/issues/new/choose) for a reproducible bug, build problem, documentation gap, or scoped feature proposal.
- Check the [README](README.md), [user guide](docs/USER_GUIDE.md), and existing issues before opening a new report.
- Include the app version/build, branch or commit when relevant, iOS/macOS/Xcode versions, target device or simulator, reproduction steps, expected behavior, observed behavior, and sanitized logs.
- For background, voice, browser, or provider failures, identify the phase and attach a redacted diagnostics export when possible.

Never include API keys, passwords, private keys, hostnames, personal files, or other secrets. Report vulnerabilities privately using [SECURITY.md](SECURITY.md).
