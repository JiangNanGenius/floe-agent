<div align="center">
  <img src="docs/images/floe-agent-icon.png" width="88" alt="Floe Agent app icon">
  <h1>Floe Agent</h1>
  <p><strong>Your models. Your files. Your machines.</strong></p>
  <p>Floe Agent is an open-source AI agent workspace, designed for iPad and native on iPhone (iOS / iPadOS). Bring AI tasks, Notes, Office documents, creative tools and development together, using your own API keys (BYOK) for cloud AI. An Android alpha is available for basic cloud chat.</p>
  <p><a href="README.zh-CN.md">简体中文</a> · <a href="https://www.floe-agent.com/">Website</a> · <a href="docs/USER_GUIDE.md">User manual</a> · <a href="docs/README.md">Documentation</a></p>
</div>

[![Release](https://img.shields.io/github/v/release/JiangNanGenius/floe-agent?include_prereleases&label=release)](https://github.com/JiangNanGenius/floe-agent/releases)
[![iOS 26+](https://img.shields.io/badge/iOS%20%2F%20iPadOS-26%2B-0A84FF)](FloeAgent/project.yml)
[![Android 9+ ARM64 alpha](https://img.shields.io/badge/Android-9%2B%20ARM64%20alpha-3DDC84)](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.1)
[![MPL 2.0](https://img.shields.io/badge/license-MPL--2.0-4A5568)](LICENSE)

[Install](#get-started) · [Features](#features) · [Demo](#see-floe-at-work) · [Docs](#documentation) · [Develop](#build-from-source) · [Contribute](#contributing-and-license)

## Get started

Choose an installation channel on the [website](https://www.floe-agent.com/#download). Check [current status](docs/CURRENT_STATUS.md) and the installation page for each channel’s version, region and eligibility.

<p align="center">
  <a href="https://altdirect.app/?url=https%3A%2F%2Fraw.githubusercontent.com%2FJiangNanGenius%2Ffloe-agent%2Fmain%2Ffeather.json&amp;r=feather"><img src="docs/images/badge-add-to-feather.png" alt="Add to Feather" height="52"></a>
  &nbsp;
  <a href="https://altdirect.app/?url=https%3A%2F%2Fraw.githubusercontent.com%2FJiangNanGenius%2Ffloe-agent%2Fmain%2Ffeather.json&amp;r=altstore"><img src="docs/images/badge-add-to-altstore.png" alt="Add to AltStore" height="52"></a>
</p>
<p align="center">
  <a href="https://github.com/JiangNanGenius/floe-agent/releases"><strong>Download releases</strong></a>
</p>

<details>
<summary>Copy the source URL manually</summary>

```text
https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json
```

</details>

| Channel | Before you install |
| --- | --- |
| iOS / iPadOS · TestFlight | Requires valid beta access. Available builds and expiry appear in TestFlight. |
| iOS / iPadOS · Feather / AltStore | Install the corresponding app, use a button above to add the source, then sign with your own setup. |
| iOS / iPadOS · GitHub IPA | Download the IPA and checksum from Releases. The IPA is unsigned and requires your own signing. |
| Android alpha | Android 9+ (ARM64). Download the signed APK and checksum from the [Android release](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.1) and install it manually; updates are manual for now. Bring your own cloud API key; no local model is included. |

For your first iOS / iPadOS task: **install → connect a model → create a task → open the result**. Core Notes, file organization and Canvas work without an AI provider; AI features use your configured provider or a local model supported by your device. On Android: **install → add your cloud provider key → start chatting**.

[Installation steps](docs/USER_GUIDE.md#1-installation-and-first-use) · [Model setup](docs/USER_GUIDE.md#2-models-and-auxiliary-capabilities) · [Sources and signing](docs/FEATHER_SOURCE.md)

## Features

The table below walks through the iOS app. The Android alpha currently supports basic cloud chat with your own provider key, plus configuration and history restore; it will grow toward iOS parity over time, alongside Android-specific features.

| Workflow | What you can do | Guide |
| --- | --- | --- |
| AI tasks | Continue a task with your material, tool actions and resulting files together. | [Tasks & workspaces](docs/USER_GUIDE.md#3-tasks-and-workspace-ownership) |
| Notes | Import PDFs and images, search, annotate with Pencil and ask about documents. | [Notes](docs/USER_GUIDE.md#7-notes-import-search-and-handwriting) |
| Office | Create, edit and save DOCX, XLSX and PPTX. Check saved results with complex layouts. | [Documents, sheets & slides](docs/USER_GUIDE.md#8-office-edit-annotate-save-and-reopen) |
| Canvas & media | Organize material on a canvas and use focused image, video and audio workbenches. | [Canvas & media](docs/USER_GUIDE.md#15-canvas-images-audio-and-video) |
| Drawings & 3D | Inspect engineering files, edit supported entities and use Drawing Assistant. Operations vary by format. | [Engineering drawings](docs/USER_GUIDE.md#14-engineering-drawings-and-ai-review) |
| Code & remote | Edit code and work with local Linux, Git, web previews and authorized remote hosts. | [Local terminal](docs/USER_GUIDE.md#9-local-terminal-and-linux-performance) · [Remote connections](docs/USER_GUIDE.md#12-remote-hosts-desktops-and-diagnostics) |

Model requests go directly to your chosen provider; credentials stay in the device keychain. Files, uploads and remote actions follow task permissions, with consequential actions confirmed under the current policy. See [security](SECURITY.md).

## See Floe at work

Recorded on iOS; the Android alpha covers the basics described above.

[![Watch Floe: tasks, Office, code, Notes and Canvas](docs/assets/video/floe-en.jpg)](https://www.youtube.com/watch?v=OXHntB2dyvo)

[Watch on YouTube](https://www.youtube.com/watch?v=OXHntB2dyvo) · [Bilibili 中文版](https://www.bilibili.com/video/BV1YBpx6QEe1/) · [Explore features on the website](https://www.floe-agent.com/features)

## Documentation

| Looking for | Start here |
| --- | --- |
| How to use Floe | [Illustrated user manual](docs/USER_GUIDE.md) · [中文手册](docs/USER_GUIDE.zh-CN.md) |
| A topic | [Documentation hub](docs/README.md) |
| Installation & versions | [Channel status](docs/CURRENT_STATUS.md) · [Sources](docs/FEATHER_SOURCE.md) · [Release records](docs/releases/README.md) |
| Help & feedback | [Troubleshooting](docs/USER_GUIDE.md#20-troubleshooting) · [Support](SUPPORT.md) |
| Development & integration | [Engineering guide](FloeAgent/README.md) · [Architecture](docs/ARCHITECTURE_OVERVIEW.md) · [Formats & tools](docs/FLOE_1_7_24_CREATIVE_TOOLS.md) |

## Build from source

Use macOS, a full Xcode installation, Swift and XcodeGen. The current iOS 27 path requires Xcode 27; iOS/iPadOS 26 remains a compatibility target.

```bash
git clone https://github.com/JiangNanGenius/floe-agent.git
cd floe-agent/FloeAgent
bash scripts/gen_project.sh
open FloeAgent.xcodeproj
```

See the [engineering guide](FloeAgent/README.md) for dependencies, build parameters and focused tests. For the Android app, see [FloeAndroid/README.md](FloeAndroid/README.md). Gitee synchronizes source and release records; see the [sync guide](docs/FLOE_GITEE_RELEASE_MIRROR.md).

## Contributing and license

Read [contributing](CONTRIBUTING.md) before reporting an issue or working on the project. Use [support](SUPPORT.md) for general questions and report vulnerabilities privately through [security](SECURITY.md).

Original Floe code is licensed under [MPL 2.0](LICENSE). Third-party components retain their own licenses and notices, available in the app under Settings → Diagnostics & About → Third-Party Licenses.
