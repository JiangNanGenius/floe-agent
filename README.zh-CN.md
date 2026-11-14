<div align="center">
  <img src="docs/images/floe-agent-icon.png" width="88" alt="Floe Agent 应用图标">
  <h1>Floe Agent</h1>
  <p><strong>面向 iOS、iPadOS 和 Android 的设备端 AI 工作台。</strong></p>
  <p>你的模型，你的文件，你的电脑。</p>
  <p>Floe Agent 是面向 iOS、iPadOS 和 Android 的开源 AI 智能体。把文档、代码与创作项目放进同一处，在自己的设备上运行真实的 Linux 环境。以 iPadOS 与 Apple Pencil 体验为核心，原生支持 iPhone，并提供 Android 特有的设备协作流程。</p>
  <p><a href="README.md">English</a> · <a href="https://www.floe-agent.com/?utm_source=github&amp;utm_medium=referral&amp;utm_campaign=readme_zh">floe-agent.com</a> · <a href="https://www.floe-agent.com/releases?utm_source=github&amp;utm_medium=referral&amp;utm_campaign=readme_zh">版本与更新</a> · <a href="docs/README.md">文档中心</a> · <a href="docs/DISCLAIMER.zh-CN.md">免责声明</a></p>
</div>

<p align="center">
  <a href="https://apps.apple.com/app/id6801209053"><img src="docs/images/install/app-store.svg" alt="从 App Store 获取 Floe Agent 正式版" width="144" height="56"></a>
  <a href="https://www.floe-agent.com/?utm_source=github&amp;utm_medium=referral&amp;utm_campaign=beta_readme_zh#beta"><img src="docs/images/install/testflight.svg" alt="前往官网申请 TestFlight 内测" width="144" height="56"></a>
  <a href="https://altdirect.app/?url=https%3A%2F%2Fraw.githubusercontent.com%2FJiangNanGenius%2Ffloe-agent%2Fmain%2Ffeather.json"><img src="docs/images/install/self-signing-zh.svg" alt="自签名商店：Feather 与 AltStore" width="144" height="56"></a>
</p>

[![iOS / iPadOS 26+](https://img.shields.io/badge/iOS%20%2F%20iPadOS-26%2B-0A84FF)](FloeAgent/project.yml)
[![Android 9+ ARM64 · Full APK](https://img.shields.io/badge/Android-9%2B%20ARM64%20%C2%B7%20Full%20APK-3DDC84)](https://www.floe-agent.com/releases?platform=android&utm_source=github&utm_medium=referral&utm_campaign=readme_zh)
[![MPL 2.0](https://img.shields.io/badge/license-MPL--2.0-4A5568)](LICENSE)

[安装](#开始使用) · [功能](#主要功能) · [演示](#看看-floe-如何工作) · [文档](#文档导航) · [开发](#从源码构建) · [反馈](#贡献与许可证)

## 看看 Floe 如何工作

[![Floe 在 iPad 上完成任务并打开生成的网页](docs/assets/video/floe-zh-20261108.jpg)](https://www.floe-agent.com/features?utm_source=github&utm_medium=referral&utm_campaign=readme_demo_zh#film)

[在 Bilibili 观看](https://www.bilibili.com/video/BV1mA4x6nETP/) · [YouTube English](https://www.youtube.com/watch?v=nwesxhIiXuw) · [官网交互功能演示](https://www.floe-agent.com/features?utm_source=github&utm_medium=referral&utm_campaign=readme_zh)

演示录制于 iOS/iPadOS。Android 的具体流程与限制见[独立使用指南](docs/ANDROID_GUIDE.zh-CN.md)。

## 开始使用

在[版本中心](https://www.floe-agent.com/releases?utm_source=github&utm_medium=referral&utm_campaign=readme_zh)选择产品。最新版下载与更新日志会自动同步，Floe Agent 与两款 Bridge 各自保留独立记录。

| 产品 | 安装与介绍 | 使用前了解 |
| --- | --- | --- |
| **Floe Agent · iOS / iPadOS** | [App Store 正式版](https://apps.apple.com/app/id6801209053) · [申请 TestFlight](https://www.floe-agent.com/?utm_source=github&utm_medium=referral&utm_campaign=beta_readme_zh#beta) · [GitHub IPA 版本](https://www.floe-agent.com/releases?platform=ios&utm_source=github&utm_medium=referral&utm_campaign=readme_zh) | iOS/iPadOS 26+。商店可用性以所在地区为准，内测以实际测试组为准；GitHub IPA 需要自行签名。 |
| **Floe Agent · Android** | [下载 Full APK](https://www.floe-agent.com/releases?platform=android&utm_source=github&utm_medium=referral&utm_campaign=readme_zh) · [安装指南](docs/ANDROID_GUIDE.zh-CN.md) | Android 9+ ARM64，自行分发。测试版标记及安装要求以所选发布说明为准。 |
| **Floe Bridge · Mac** | [伴随程序介绍](https://www.floe-agent.com/bridge?utm_source=github&utm_medium=referral&utm_campaign=readme_zh) · [下载版本](https://www.floe-agent.com/releases?platform=bridge&utm_source=github&utm_medium=referral&utm_campaign=readme_zh) | 可选的菜单栏伴随程序，为运行在**同一台 Mac** 上的 Floe 提供终端、文件与 MCP。 |
| **Floe iOS Bridge** | [伴随程序介绍](https://www.floe-agent.com/ios-bridge?utm_source=github&utm_medium=referral&utm_campaign=readme_zh) · [安装指南](FloeIOSBridge/INSTALL.zh-CN.md) · [下载版本](https://www.floe-agent.com/releases?platform=ios-bridge&utm_source=github&utm_medium=referral&utm_campaign=readme_zh) | 独立的 iPhone/iPad 设备控制应用。首次设置需要电脑、签名与开发者配对；当前独立版本尚未接入 Floe 主应用。 |

App Store、TestFlight 和 GitHub 各自更新。请结合所选发布说明及[带日期的渠道状态](docs/CURRENT_STATUS.md)选择版本；GitHub 已发布不代表 Apple 渠道已经可用。

<details>
<summary>自签名商店：安装说明与软件源</summary>

点击顶部「自签名商店」，在同一页面选择 Feather 或 AltStore，再按所用签名方式添加软件源并完成安装。

也可以手动复制软件源地址：

```text
https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json
```

[软件源与签名说明](docs/FEATHER_SOURCE.md)

</details>

**完成第一个任务：** 安装 Floe → 配置模型 → 新建任务 → 打开成果。从[快速开始](docs/QUICKSTART.zh-CN.md)入手，或阅读 [iOS/iPadOS](docs/USER_GUIDE.zh-CN.md) 与 [Android](docs/ANDROID_GUIDE.zh-CN.md) 指南。基础文档与文件工作可以独立使用；AI 操作使用你配置的模型。

## 主要功能

以下功能按平台和所选版本开放，请按对应教程与发布说明选择构建。

### 设备端工作，自选模型

工作空间与持久化 Linux 环境运行在自己的设备上。使用 Shell、Python、Node、软件包和本地网页服务，把文件、执行过程与成果留在同一个任务中。环境镜像需要另行下载，软件包需支持对应架构。

云端 AI 使用你自行配置的服务商与 API Key（**BYOK：自备密钥**）。支持的 iOS/iPadOS 设备还可使用 Apple 系统模型或 Beta 阶段的下载式本地模型；Android 当前使用云端服务。本地选项以设备内存、模型准备状态和所选版本为准。

### 从任务走到可继续编辑的成果

| 工作流程 | 可以做什么 | 使用指南 |
| --- | --- | --- |
| **AI 任务与开发** | 在任务中整理资料、调用工具与保存成果，使用终端、代码编辑器、Git 和本地预览。 | [任务与工作空间](docs/USER_GUIDE.zh-CN.md#3-新建任务与选择工作区) · [Linux 与开发](docs/USER_GUIDE.zh-CN.md#9-本地终端与-linux-性能配置) |
| **手记与 Office** | 导入 PDF 和图片，在 iPad 上用 Pencil 批注并围绕文档提问，编辑 DOCX、XLSX 与 PPTX。 | [手记](docs/USER_GUIDE.zh-CN.md#7-手记导入搜索与书写) · [Office](docs/USER_GUIDE.zh-CN.md#8-office编辑批注保存和重新打开) |
| **图纸与 3D** | 在 iOS/iPadOS 上编辑二维图纸与原生 3D 模型，通过作品助手继续修改，再展示或导出成果。 | [二维图纸](docs/USER_GUIDE.zh-CN.md#14-工程图纸与图纸助手) · [3D 工作台](docs/USER_GUIDE.zh-CN.md#3d-模型统一工作台) |
| **画布与媒体** | 在画布中组织素材，通过专用编辑器处理图像、视频与音频项目。 | [画布与媒体](docs/USER_GUIDE.zh-CN.md#15-画布图像音视频) |
| **语音与会议** | 口述草稿、进行语音对话，录制会议，通过所选服务转写并整理笔记。 | [语音](docs/USER_GUIDE.zh-CN.md#16-语音输入与转录) · [会议流程](docs/WORKSPACES_GUIDE.zh-CN.md#2-会议录音转写与纪要--185) |
| **技能与自动化** | 查找已审阅的技能，管理依赖与版本，连接已配置的 MCP 和自动化服务。 | [网页版 Skill Hub](https://www.floe-agent.com/skills?utm_source=github&utm_medium=referral&utm_campaign=readme_zh) · [技能与 MCP](docs/USER_GUIDE.zh-CN.md#17-skillsmcp邮件与自动任务) |

[空间与专用工作台](docs/WORKSPACES_GUIDE.zh-CN.md)还提供图示、音乐、LaTeX、GIS、电子设计、加工与打印准备等流程，按所选构建开放。**各平台、各版本的功能范围不同。** Android 的手机控制、自身 ADB、项目 Linux 与外部编辑器协作有独立说明，CAD/3D 预览与 iOS 原生建模编辑器分别介绍。

## 文档导航

先选择自己的平台；模型、任务与文件的共通操作放在共享指南中。

| 想了解什么 | 从这里开始 |
| --- | --- |
| **第一个成果** | [快速开始](docs/QUICKSTART.zh-CN.md) · [English quickstart](docs/QUICKSTART.md) |
| **iOS / iPadOS** | [官网指南目录](https://www.floe-agent.com/docs/ios/zh.html?utm_source=github&utm_medium=referral&utm_campaign=ios_docs_readme_zh) · [完整手册](docs/USER_GUIDE.zh-CN.md) · [工作台教程](docs/WORKSPACES_GUIDE.zh-CN.md) |
| **Android** | [官网指南目录](https://www.floe-agent.com/docs/android/zh.html?utm_source=github&utm_medium=referral&utm_campaign=android_guide_readme_zh) · [Android 手册](docs/ANDROID_GUIDE.zh-CN.md) · [Android 9/10 USB 激活](docs/ANDROID_GUIDE.zh-CN.md#32-android-910电脑-usb-初始化) |
| **共通操作** | [模型、任务与文件](docs/SHARED_GUIDE.zh-CN.md) |
| **两款 Bridge** | [Mac Bridge](docs/USER_GUIDE.zh-CN.md#mac-bridge-快速开始) · [iOS Bridge](FloeIOSBridge/INSTALL.zh-CN.md) |
| **版本与安装** | [版本中心](https://www.floe-agent.com/releases?utm_source=github&utm_medium=referral&utm_campaign=readme_zh) · [渠道状态](docs/CURRENT_STATUS.md) · [软件源与签名](docs/FEATHER_SOURCE.md) |
| **故障排查** | [常见问题](docs/USER_GUIDE.zh-CN.md#20-常见问题与排查顺序) · [支持说明](SUPPORT.md) |
| **参与开发** | [工程指南](FloeAgent/README.md) · [架构](docs/ARCHITECTURE_OVERVIEW.md) · [文档中心](docs/README.md) |

## 模型、权限与隐私

云端模型请求直接发送到你配置的服务商；支持的本地模型在设备上完成推理。Floe 作者不提供模型 API、模型托管或 API 额度。密钥使用设备受保护的存储，上传与远程操作遵循你授予的权限。请在使用前检查 AI 生成的内容。

[免责声明与使用说明](docs/DISCLAIMER.zh-CN.md) · [安全策略](SECURITY.md)

## 从源码构建

iOS/iPadOS 开发需要 macOS、完整 Xcode 与 XcodeGen。SDK、依赖和签名要求以工程指南为准；iOS/iPadOS 26 仍是兼容目标。

```bash
git clone https://github.com/JiangNanGenius/floe-agent.git
cd floe-agent/FloeAgent
bash scripts/gen_project.sh
open FloeAgent.xcodeproj
```

[iOS 构建指南](FloeAgent/README.md) · [Android Full APK 构建指南](FloeAndroid/README.md) · [Mac Bridge 构建指南](docs/FLOE_MAC_BRIDGE.md#building-and-distributing) · [iOS Bridge 构建指南](FloeIOSBridge/README.md#build-and-sign)

Gitee 同步源码与发布记录，详见[镜像说明](docs/FLOE_GITEE_RELEASE_MIRROR.md)。

## 贡献与许可证

**[GitHub Issues](https://github.com/JiangNanGenius/floe-agent/issues) 是功能建议与故障报告的主要渠道。** 请附上版本、设备和复现步骤。App 内日志用于补充诊断资料，按维护精力处理。

参与开发前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)，安全漏洞请通过 [SECURITY.md](SECURITY.md) 私下报告。

Floe 原创代码采用 [MPL 2.0](LICENSE)。第三方组件保留各自许可证与声明，可在 App 的“设置 → 诊断与关于 → 第三方许可”中查看。


