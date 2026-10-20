<div align="center">
  <img src="docs/images/floe-agent-icon.png" width="88" alt="Floe Agent 应用图标">
  <h1>Floe Agent</h1>
  <p><strong>你的模型，你的文件，你的电脑。</strong></p>
  <p>Floe Agent 是面向 iPad 和 iPhone（iOS / iPadOS）的开源 AI 智能体工作空间，以 iPad 体验为先。把 AI 任务、手记、Office 文档、创作与开发放进同一处，云端 AI 使用自备 API Key（BYOK）。Android Alpha 测试版现已推出，目前支持基础云端对话。</p>
  <p><a href="README.md">English</a> · <a href="https://www.floe-agent.com/">官网</a> · <a href="docs/USER_GUIDE.zh-CN.md">使用手册</a> · <a href="docs/README.md">文档中心</a></p>
</div>

[![Release](https://img.shields.io/github/v/release/JiangNanGenius/floe-agent?include_prereleases&label=release)](https://github.com/JiangNanGenius/floe-agent/releases)
[![iOS 26+](https://img.shields.io/badge/iOS%20%2F%20iPadOS-26%2B-0A84FF)](FloeAgent/project.yml)
[![Android 9+ ARM64 测试版](https://img.shields.io/badge/Android-9%2B%20ARM64%20alpha-3DDC84)](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.1)
[![MPL 2.0](https://img.shields.io/badge/license-MPL--2.0-4A5568)](LICENSE)

[安装](#开始使用) · [功能](#主要功能) · [演示](#看看-floe-如何工作) · [文档](#文档导航) · [开发](#从源码构建) · [参与贡献](#贡献与许可证)

## 开始使用

从[官网](https://www.floe-agent.com/#download)选择安装方式；各渠道的版本、地区和资格分别以[当前状态](docs/CURRENT_STATUS.md)及安装页面为准。

<p align="center">
  <a href="https://altdirect.app/?url=https%3A%2F%2Fraw.githubusercontent.com%2FJiangNanGenius%2Ffloe-agent%2Fmain%2Ffeather.json&amp;r=feather"><img src="docs/images/badge-add-to-feather.png" alt="添加到 Feather" height="52"></a>
  &nbsp;
  <a href="https://altdirect.app/?url=https%3A%2F%2Fraw.githubusercontent.com%2FJiangNanGenius%2Ffloe-agent%2Fmain%2Ffeather.json&amp;r=altstore"><img src="docs/images/badge-add-to-altstore.png" alt="添加到 AltStore" height="52"></a>
</p>
<p align="center">
  <a href="https://github.com/JiangNanGenius/floe-agent/releases"><strong>下载发布版本</strong></a>
</p>

<details>
<summary>手动复制软件源地址</summary>

```text
https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json
```

</details>

| 安装方式 | 使用前准备 |
| --- | --- |
| iOS / iPadOS · TestFlight | 需要有效测试资格；可安装构建与到期时间以 TestFlight 为准。 |
| iOS / iPadOS · Feather / AltStore | 先安装对应 App，点击上方按钮添加源，再按自己的签名方式安装。 |
| iOS / iPadOS · GitHub IPA | 从发布页下载 IPA 和校验文件；IPA 未签名，需要自行签名。 |
| Android 测试版 | Android 9+（ARM64）。从 [Android 发布页](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.1) 下载签名 APK 与校验文件并手动安装；目前更新也需手动。需自备云端 API Key，不含本地模型。 |

iOS / iPadOS 首次使用：**安装 → 配置模型 → 新建任务 → 打开成果**。核心手记、文件整理和画布无需 AI 服务商；AI 功能使用你配置的服务商或设备支持的本地模型。Android 首次使用：**安装 → 添加云端模型 Key → 开始对话**。

[详细安装步骤](docs/USER_GUIDE.zh-CN.md#1-安装与首次使用) · [模型配置](docs/USER_GUIDE.zh-CN.md#2-配置模型与辅助能力) · [软件源与签名](docs/FEATHER_SOURCE.md)

## 主要功能

下表介绍 iOS 版功能。Android 测试版目前支持使用自备云端 Key 的基础对话，以及配置与历史恢复；后续会逐步对齐 iOS 能力，并发展 Android 特色功能。

| 工作方式 | 在 Floe 中做什么 | 操作指南 |
| --- | --- | --- |
| AI 任务 | 在同一任务中连续提问、使用资料、执行工具并保留成果。 | [任务与工作区](docs/USER_GUIDE.zh-CN.md#3-新建任务与选择工作区) |
| 手记 | 导入 PDF 与图片，搜索、Pencil 批注，并围绕文档提问。 | [手记](docs/USER_GUIDE.zh-CN.md#7-手记导入搜索与书写) |
| Office | 创建、编辑、保存 DOCX、XLSX 与 PPTX。复杂格式需检查保存结果。 | [文档、表格与演示](docs/USER_GUIDE.zh-CN.md#8-office编辑批注保存和重新打开) |
| 画布与媒体 | 在画布组织素材，进入图像、视频和音频工作台处理细节。 | [画布与媒体](docs/USER_GUIDE.zh-CN.md#15-画布图像音视频) |
| 图纸与 3D | 查看工程文件，编辑支持的图元，使用图纸助手。能力随格式而异。 | [工程图纸](docs/USER_GUIDE.zh-CN.md#14-工程图纸与图纸助手) |
| 开发与远程 | 编辑代码，使用本地 Linux、Git、网页预览与授权的远程主机。 | [本地终端](docs/USER_GUIDE.zh-CN.md#9-本地终端与-linux-性能配置) · [远程连接](docs/USER_GUIDE.zh-CN.md#12-远程设备桌面与网络诊断) |

模型请求直接发送至你选择的服务商；密钥保存在设备钥匙串。文件、上传与远程操作遵循任务权限，重要操作按当前策略确认。详见[安全说明](SECURITY.zh-CN.md)。

## 看看 Floe 如何工作

演示视频基于 iOS 版录制；Android 测试版目前覆盖上述基础能力。

[![观看 Floe：任务、Office、代码、手记与画布](docs/assets/video/floe-zh.jpg)](https://www.bilibili.com/video/BV1YBpx6QEe1/)

[在 B 站观看](https://www.bilibili.com/video/BV1YBpx6QEe1/) · [Watch on YouTube](https://www.youtube.com/watch?v=OXHntB2dyvo) · [官网功能介绍](https://www.floe-agent.com/features)

## 文档导航

| 想了解什么 | 从这里开始 |
| --- | --- |
| 如何使用 | [中文图文手册](docs/USER_GUIDE.zh-CN.md) · [English manual](docs/USER_GUIDE.md) |
| 按主题找内容 | [文档中心](docs/README.md) |
| 安装与版本 | [渠道状态](docs/CURRENT_STATUS.md) · [软件源](docs/FEATHER_SOURCE.md) · [发布记录](docs/releases/README.md) |
| 问题与反馈 | [常见问题](docs/USER_GUIDE.zh-CN.md#20-常见问题与排查顺序) · [支持](SUPPORT.zh-CN.md) |
| 工程与集成 | [工程指南](FloeAgent/README.md) · [架构](docs/ARCHITECTURE_OVERVIEW.md) · [格式与工具能力](docs/FLOE_1_7_24_CREATIVE_TOOLS.md) |

## 从源码构建

需要 macOS、完整 Xcode、Swift 与 XcodeGen。当前源码的 iOS 27 路径需使用 Xcode 27；iOS/iPadOS 26 保持兼容目标。

```bash
git clone https://github.com/JiangNanGenius/floe-agent.git
cd floe-agent/FloeAgent
bash scripts/gen_project.sh
open FloeAgent.xcodeproj
```

依赖准备、构建参数与定向测试见[工程指南](FloeAgent/README.md)。Android 应用见 [FloeAndroid/README.md](FloeAndroid/README.md)。Gitee 仅用于源码与发行记录同步，见[同步说明](docs/FLOE_GITEE_RELEASE_MIRROR.md)。

## 贡献与许可证

提交问题或参与开发前，请阅读[贡献指南](CONTRIBUTING.zh-CN.md)；一般问题见[支持入口](SUPPORT.zh-CN.md)，安全问题请按[安全策略](SECURITY.zh-CN.md)私下报告。

Floe 原创代码采用 [MPL 2.0](LICENSE)。第三方组件保留各自许可证与声明，App 内可在“设置 → 诊断与关于 → 第三方开源许可”查看。
