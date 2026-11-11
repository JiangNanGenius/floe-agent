<div align="center">
  <img src="docs/images/floe-agent-icon.png" width="88" alt="Floe Agent app icon">
  <h1>Floe Agent</h1>
  <p><strong>Your models. Your files. Your machines.</strong></p>
  <p>Floe Agent is an open-source on-device AI agent workspace for iOS and Android — iPad-first, with native iPhone support and a separate Android alpha. Bring AI tasks, Notes, Office documents, creative tools, development, voice conversations and skills together — with a real Linux environment on your device that runs code, packages and services, supported local models for on-device inference, and cloud AI using your own API keys (BYOK).</p>
  <p><a href="README.zh-CN.md">简体中文</a> · <a href="https://www.floe-agent.com/en?utm_source=github&utm_medium=referral&utm_campaign=readme_en">Website</a> · <a href="https://www.floe-agent.com/en?utm_source=github&utm_medium=referral&utm_campaign=beta_readme_en#beta">Apply for iOS beta</a> · <a href="docs/USER_GUIDE.md">User manual</a> · <a href="docs/README.md">Documentation</a> · <a href="docs/DISCLAIMER.md">Disclaimer</a></p>
</div>

[![Release](https://img.shields.io/github/v/release/JiangNanGenius/floe-agent?include_prereleases&label=release)](https://github.com/JiangNanGenius/floe-agent/releases)
[![iOS 26+](https://img.shields.io/badge/iOS%20%2F%20iPadOS-26%2B-0A84FF)](FloeAgent/project.yml)
[![Android 9+ ARM64 alpha](https://img.shields.io/badge/Android-9%2B%20ARM64%20alpha-3DDC84)](https://www.floe-agent.com/en/releases?platform=android&utm_source=github&utm_medium=referral&utm_campaign=readme_en)
[![MPL 2.0](https://img.shields.io/badge/license-MPL--2.0-4A5568)](LICENSE)

[Install](#get-started) · [Features](#features) · [Demo](#see-floe-at-work) · [Docs](#documentation) · [Develop](#build-from-source) · [Contribute](#contributing-and-license)

## Get started

[From installation to your first result](docs/QUICKSTART.md) · [Full manual](docs/USER_GUIDE.md)

Choose an installation channel on the [website](https://www.floe-agent.com/en?utm_source=github&utm_medium=referral&utm_campaign=readme_en#download). Explore the [iOS AI Agent workspace for iPad and iPhone](https://www.floe-agent.com/en/ios-ai-agent?utm_source=github&utm_medium=referral&utm_campaign=readme_en). Check [current status](docs/CURRENT_STATUS.md) and the installation page for each channel’s version, region and eligibility.

<p align="center">
  <a href="https://apps.apple.com/app/id6801209053"><img src="docs/images/badge-app-store.svg" alt="Download the official release on the App Store" height="52"></a>
  &nbsp;
  <a href="https://www.floe-agent.com/en?utm_source=github&amp;utm_medium=referral&amp;utm_campaign=beta_readme_en#beta"><img src="docs/images/badge-apply-testflight.svg" alt="Apply for TestFlight on the website" height="52"></a>
  &nbsp;
  <a href="https://altdirect.app/?url=https%3A%2F%2Fraw.githubusercontent.com%2FJiangNanGenius%2Ffloe-agent%2Fmain%2Ffeather.json&amp;r=feather"><img src="docs/images/badge-add-to-feather.png" alt="Add to Feather" height="52"></a>
  &nbsp;
  <a href="https://altdirect.app/?url=https%3A%2F%2Fraw.githubusercontent.com%2FJiangNanGenius%2Ffloe-agent%2Fmain%2Ffeather.json&amp;r=altstore"><img src="docs/images/badge-add-to-altstore.png" alt="Add to AltStore" height="52"></a>
</p>
<p align="center">
  <a href="https://github.com/JiangNanGenius/floe-agent/releases"><strong>Download releases</strong></a>
  &nbsp;·&nbsp;
  <a href="https://www.floe-agent.com/en?utm_source=github&amp;utm_medium=referral&amp;utm_campaign=beta_readme_en#beta"><strong>Apply for TestFlight on the website</strong></a>
</p>

<details>
<summary>Copy the source URL manually</summary>

```text
https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json
```

</details>

| Channel | Before you install |
| --- | --- |
| iOS / iPadOS · App Store | [Get the official release on the App Store](https://apps.apple.com/app/id6801209053). Install and update through the store; requires iOS / iPadOS 26+. Availability and versions follow your storefront. |
| iOS / iPadOS · TestFlight | [Apply for beta access on the website](https://www.floe-agent.com/en?utm_source=github&utm_medium=referral&utm_campaign=beta_readme_en#beta). Available builds and eligibility appear in TestFlight. |
| iOS / iPadOS · Feather / AltStore | Install the corresponding app, use a button above to add the source, then sign with your own setup. |
| iOS / iPadOS · GitHub IPA | Download the IPA and checksum from Releases. The IPA is unsigned and requires your own signing. |
| Android alpha | Android 9+ ARM64. BYOK cloud AI, Notes and Office, on-device Linux/IDE/project desktops, network tools and Android app workflows. Check the [selected release notes](https://www.floe-agent.com/en/releases?platform=android&utm_source=github&utm_medium=referral&utm_campaign=readme_en) for compatibility and actual save behavior. No local-model inference or assumed iOS editor parity. |

For your first iOS / iPadOS task: **install → connect a model → create a task → open the result**. Core Notes, file organization and Canvas work without an AI provider; AI features use your configured provider or a local model supported by your device. On Android: **install → add your cloud provider key → start chatting**; Basic Notes editing works without a provider; AI actions use your cloud configuration. Office files, the file workspace, the Linux terminal, the code IDE and the network workbench are already in the alpha.

[Installation steps](docs/USER_GUIDE.md#1-installation-and-first-use) · [Model setup](docs/USER_GUIDE.md#2-models-and-auxiliary-capabilities) · [Sources and signing](docs/FEATHER_SOURCE.md)

The iOS setup guide offers four recommendations to prefill choices for models, search, voice and workspaces, while keeping every section editable. Continue setup while voice packs, models or environments download, then check progress later. Apple Intelligence is off by default for new users.

## Features

**Stable and newer-feature builds.** See [channel versions and verification dates](docs/CURRENT_STATUS.md) for the App Store, GitHub/Feather and Android snapshots. The GitHub/Feather IPA requires your own signing. Follow the [Space and specialist workspaces guide](docs/WORKSPACES_GUIDE.md) and the selected release notes when choosing a channel. TestFlight access and versions follow your actual test group.

The features below describe Floe core workflows. Availability varies by platform and release; see the installation notes above and the [Android release](https://www.floe-agent.com/en/releases?platform=android&utm_source=github&utm_medium=referral&utm_campaign=readme_en) for the current Android alpha.

| Workflow | What you can do | Guide |
| --- | --- | --- |
| AI tasks | Continue a task with your material, tool actions and resulting files together. | [Tasks & workspaces](docs/USER_GUIDE.md#3-tasks-and-workspace-ownership) |
| On-device Linux | Run agent code in a persistent, task-owned Linux environment on your device: shell, Python, Node and apt packages, background jobs and local web previews. Requires the verified image download; packages must support the environment's architecture. | [Local terminal & Linux](docs/USER_GUIDE.md#9-local-terminal-and-linux-performance) |
| On-device AI | Run inference on your device with supported local models — the system model or downloaded models (Beta). Availability depends on your device and model status; local models share memory with Linux. | [Model setup](docs/USER_GUIDE.md#2-models-and-auxiliary-capabilities) |
| Notes | Import PDFs and images, search, annotate with Pencil and ask about documents. | [Notes](docs/USER_GUIDE.md#7-notes-import-search-and-handwriting) |
| Office | Create, edit and save DOCX, XLSX and PPTX. Check saved results with complex layouts. | [Documents, sheets & slides](docs/USER_GUIDE.md#8-office-edit-annotate-save-and-reopen) |
| Canvas & media | Organize material on a canvas and use focused image, video and audio workbenches. | [Canvas & media](docs/USER_GUIDE.md#15-canvas-images-audio-and-video) |
| Drawings & 3D | On iOS/iPadOS, edit 2D drawings and create native 3D models in one workbench — keep refining them with the assistant, apply materials and present or export the result. Operations vary by format. | [Native 3D editor](docs/USER_GUIDE.md#3d-models-one-unified-workbench) · [2D drawings](docs/USER_GUIDE.md#14-engineering-drawings-and-ai-review) |
| Code & remote | Edit code, track Git changes and work with authorized remote hosts. | [Terminal & ports](docs/USER_GUIDE.md#9-local-terminal-and-linux-performance) · [Remote connections](docs/USER_GUIDE.md#12-remote-hosts-desktops-and-diagnostics) |
| Voice | Dictate editable drafts, hold voice conversations and have final answers read aloud with system, enhanced on-device or configured online voices. Android includes system/configured cloud voice paths; provider and device behavior remains under validation, and Android has no App-managed local voice model. | [Voice input & read-aloud](docs/USER_GUIDE.md#16-voice-input-and-transcription) |
| Skills & Skill Hub | Install reviewed skills with declared dependencies and version management, keep them updated, and automate with MCP services and mail actions. Android includes the signed Hub client; compatible package supply and task Linux dependencies remain independently checked. | [Skills, MCP & automation](docs/USER_GUIDE.md#17-skills-mcp-mail-and-automation) |
| Space & specialist workspaces | Reach diagrams, mixed canvases, meetings, music, machining and print preparation through Space, Notes and Creative mode. Follow the relevant build requirements. | [Workspace tutorials](docs/WORKSPACES_GUIDE.md) |
| Specialist editors | LaTeX, GIS, font and electronics workflows have release-specific entry points and limits; check the workspace guide before choosing a build. | [Workflows and availability](docs/WORKSPACES_GUIDE.md) |

Cloud model requests go directly to your chosen provider; supported local models run inference on the device. Credentials stay in protected storage on your device. Files, uploads and remote actions follow task permissions, with consequential actions confirmed under the current policy. See [security](SECURITY.md).

## See Floe at work

Recorded on iOS; the Android alpha already includes chat, Office, files, terminal, IDE and network-diagnostic workflows and keeps growing.

[![Watch Floe: tasks, Office, code, Notes and Canvas](docs/assets/video/floe-en-20261108.jpg)](https://www.youtube.com/watch?v=nwesxhIiXuw)

[Watch on YouTube](https://www.youtube.com/watch?v=nwesxhIiXuw) · [Bilibili 中文版](https://www.bilibili.com/video/BV1mA4x6nETP/) · [Explore features on the website](https://www.floe-agent.com/en/features?utm_source=github&utm_medium=referral&utm_campaign=readme_en)

## Documentation

| Looking for | Start here |
| --- | --- |
| How to use Floe | [Illustrated user manual](docs/USER_GUIDE.md) · [中文手册](docs/USER_GUIDE.zh-CN.md) |
| Shared workflows | [Models, tasks and files](docs/SHARED_GUIDE.md) — one shared guide for both platforms |
| iOS / iPadOS guides | [Platform index](https://www.floe-agent.com/docs/ios/en.html?utm_source=github&utm_medium=referral&utm_campaign=ios_docs_readme_en) · [Full manual](docs/USER_GUIDE.md) |
| Android setup & features | [Android guide](docs/ANDROID_GUIDE.md) · [Platform index](https://www.floe-agent.com/docs/android/en.html?utm_source=github&utm_medium=referral&utm_campaign=android_guide_readme_en) — legacy USB activation, self-ADB, device control and on-device Linux |
| A topic | [Documentation hub](docs/README.md) |
| Installation & versions | [Channel status](docs/CURRENT_STATUS.md) · [Sources](docs/FEATHER_SOURCE.md) · [Release records](docs/releases/README.md) |
| Help & feedback | [Troubleshooting](docs/USER_GUIDE.md#20-troubleshooting) · [Support](SUPPORT.md) |
| Development & integration | [Engineering guide](FloeAgent/README.md) · [Architecture](docs/ARCHITECTURE_OVERVIEW.md) · [Versioned format reference](docs/FLOE_1_7_24_CREATIVE_TOOLS.md) |

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
