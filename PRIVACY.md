# Privacy Policy · 隐私政策

**Effective date / 生效日期：2026-10-02**

This page describes Floe Agent (the iOS/iPadOS app, bundle identifier `org.floeagent.ios`) and the data flows in version 1.7.0. The English text comes first, followed by the Chinese version. The two language versions are intended to say the same thing; if they differ, please treat the specific wording with caution and contact us.

本页说明 Floe Agent（iOS/iPadOS 应用，Bundle ID `org.floeagent.ios`）1.7.0 版本的数据处理方式。先英文、后中文，两种语言表述保持一致；如存在差异，请通过下方方式联系我们确认。

---

## English

### 1. What this policy covers

This policy covers the Floe Agent app and its extensions (Share, Screen Broadcast, Shortcuts). It does not cover services operated by other companies that you choose to connect — your AI provider, search provider, your own servers, Apple services, GitHub, Hugging Face, and so on. Those services have their own privacy policies, which apply when the app connects to them on your behalf.

Floe Agent has **no Floe account system** and no sign-up. The app does not ask you to register with us, and it has no advertising, advertising identifiers, third-party analytics, or third-party crash-reporting SDKs.

### 2. Your content is stored on your device

Your conversations and task history, Notes (手记) notebooks and documents, PDFs and annotations, imported files and attachments, Canvas content, settings, downloaded models, and the app's working files are stored locally inside the app's protected sandbox on the device (local SQLite databases and app-managed files). This content is not sold and is not used for third-party advertising.

Deleting a conversation, Note, or other item inside the app removes the corresponding app-stored data. Settings → Privacy also provides "clear local history" and "clear model configuration" actions. Uninstalling the app removes its local sandbox data; items the system stores elsewhere (such as Keychain items or files in iCloud Drive) follow Apple's rules.

Removing a folder entry from a Floe workspace does not delete the original folder on your device, network storage, or iCloud Drive.

### 3. Optional iCloud synchronisation

If you are signed in to iCloud, the app can use Apple's iCloud services that you control in Settings:

- **Private CloudKit database:** non-secret configuration (provider/model profiles, preferences, remote-host profiles without secret values) and, when the canvas sync switch is enabled (on by default), canvas assets are synchronised through your private iCloud database. This data is tied to your Apple ID and is governed by Apple's privacy policy.
- **iCloud Keychain:** saved provider API keys and saved SSH/VNC secrets may synchronise through iCloud Keychain unless you turn that synchronisation off in the app's sync settings. Task- and project-scoped temporary credentials never leave the device, and the remote-link client identity is device-only.
- Small preference values may be stored through Apple's iCloud key-value store.

Conversations, Notes and documents are not synchronised through CloudKit. Turning canvas sync off does not delete canvas copies already stored in iCloud; deleting a canvas in the app removes its synced copy as well, after the deletion is confirmed remotely.

### 4. Cloud AI is bring-your-own-key (BYOK)

The app ships with no AI provider key and no prepaid credits. To use cloud AI, you add an API key for a provider you choose (a preset provider or a custom endpoint). Your key is stored in the iOS Keychain and is sent only to that provider, as an authorization header, when you run a task.

When a cloud model handles a request, the following can be sent to the provider you configured:

- the conversation and instructions involved in the task;
- images you attach (sent as image data within the request);
- file names and text extracted from documents, including OCR/PDF text;
- tool results, web-search results, and web pages the task reads;
- prompts and reference images for image or video generation.

What the provider does with that data is governed by that provider's terms and privacy policy, not by this policy. Please review them, and do not send sensitive content to a provider unless you accept its handling. You can review and delete provider keys in Settings; clearing model configuration removes them from the Keychain (including synced copies).

### 5. Other optional connections

Floe Agent can connect to other services only when you enable, configure, or direct them:

- **Web search:** searches go to the search provider you enable (such as Brave, Tavily, Exa, Google Programmable Search, Bocha, or Tencent WSA), using the key you supply.
- **Embedded browser and downloads:** the in-app browser opens addresses you or the task enter. Its cookies, cache and website storage use the system WebKit data store, managed by iOS like Safari website data (including in iOS Settings); Floe does not export that store. Separately, when an agent task uses the browser or an HTTP tool, the page text, DOM or screenshots the task reads, together with downloaded files, become task content: they can be stored in the task's local workspace, included in model requests to the AI provider you configured, or kept as task artifacts. Agent tasks may also make HTTPS requests and downloads you ask for, so only direct the agent at pages and files you are comfortable being handled this way.
- **Remote servers and the Linux environment:** SSH/VNC/SMB/WebDAV connections and paired remote helpers use only hosts and credentials you provide, over SSH, mutual TLS, or the protocols you configure. The on-device Linux environment downloads its guest image from the project's GitHub releases when you start it, and packages installed inside it are downloaded from the package registries (such as PyPI and npm) that the task uses.
- **Local network:** with your permission, the app can discover devices and services on your local network (for example terminals, printers, or Home Assistant).
- **GitHub integration:** if you sign in to GitHub, the app talks directly to GitHub using an OAuth token stored in the Keychain, for source-control and Actions features you invoke.
- **Downloaded models:** on-device MLX models and speech models are downloaded from Hugging Face over HTTPS, at your request, with pinned revisions and integrity checks. The catalogs of available skills and models are fetched from the project's public GitHub repository. Downloads mean that Hugging Face or GitHub receive the connection information their servers normally see, such as your IP address.
- **Media processing:** on-device media tools (transcoding, OCR, image processing) run locally; generative image/video features call the cloud provider you configure.

The agent performs actions on your behalf within the permissions you grant; imported documents, web pages, and tool output are treated as content, never as permission to access new accounts or services.

### 6. On-device processing

- Downloaded **MLX local models** run on the device. They are an optional, experimental Beta feature. Apart from the model download described above, prompts and content processed by a downloaded model do not travel to a cloud AI provider.
- **Apple's on-device Foundation model**, when available on your device and system, is a separate path provided by Apple. The app passes it only the bounded task content needed for an answer; processing is governed by Apple and iOS.
- Speech transcription can use a downloaded on-device model; depending on your iOS settings, dictation may also involve Apple's speech services.

On-device processing depends on device, system version, language, and the model used, so no feature should be assumed to work offline in every configuration.

### 7. Feedback and diagnostics

The app contains an optional feedback form. Nothing is uploaded from it until you press Submit; there is no automatic crash, analytics, or background upload. When you do submit, the report is collected by the developer at the feedback endpoint (`https://www.floe-agent.com/api/v1/public/reports`) and can include:

- the problem description you write;
- diagnostics, attached by default and controllable with the toggle shown in the form. Diagnostics may contain system/runtime information, recent log entries, and technical summaries of recent tasks; the app applies secret redaction before sending, but redaction is not guaranteed to catch every sensitive value, so please review the report;
- up to three images you explicitly pick.

Submitted reports are used to handle the feedback and any technical problem it describes. Their retention can vary with the issue and the service operating the endpoint, and this policy does not commit to a fixed retention period. If you do not want to send diagnostics or images, leave diagnostics off and attach none; you can also export diagnostics to a local file and share it yourself through the iOS share sheet without using the form.

### 8. Apple and TestFlight data

Floe Agent is distributed in beta through Apple TestFlight and through public releases on GitHub and Feather. When you test through TestFlight, Apple processes testing information (such as installation, crash, and usage data Apple collects) under Apple's own privacy policy and TestFlight terms. System permissions the app may request — Photos, local network, microphone/speech recognition, Face ID/passcode, notifications — are shown by iOS and can be changed in the iOS Settings app. Screen Broadcast and Share extensions operate on content you choose and make no independent network connections.

### 9. Security

Secrets are stored in the iOS Keychain; secret values are excluded from the app's databases, logs, feedback, and diagnostics. Network transport uses HTTPS for public endpoints, and local-network access requires the system permission. No method of transmission or storage is perfectly secure, however.

### 10. Children

The app is not directed to children and is not designed to knowingly collect data from children. Because there is no account and no advertising, no age-gated profile is created.

### 11. Changes and contact

We may update this policy as the product changes; the effective date at the top will change. Material changes will be reflected in this file in the public repository.

Questions and privacy requests:

- open an issue in the public repository: <https://github.com/JiangNanGenius/floe-agent/issues>; or
- use the in-app feedback form (see section 7).

GitHub issues are public and visible to everyone. Never post API keys, credentials, personal data, or confidential content in an issue; describe the matter generally there and use the in-app form for details.

Published policy: <https://github.com/JiangNanGenius/floe-agent/blob/main/PRIVACY.md>

---

## 中文

### 1. 政策范围

本政策适用于 Floe Agent 应用及其扩展（分享、屏幕广播、快捷指令）。它不适用于你主动连接的其他公司服务——你选择的 AI 服务商、搜索服务商、你自己的服务器、Apple 服务、GitHub、Hugging Face 等。应用代你连接这些服务时，适用它们各自的隐私政策。

Floe Agent **没有 Floe 账号体系**，也无需注册。应用不要求你向我们注册账号，不包含广告、广告标识符、第三方分析或第三方崩溃上报 SDK。

### 2. 你的内容存储在设备本地

你的对话与任务历史、手记（Notes）的笔记本与文档、PDF 与批注、导入的文件与附件、画布内容、设置、已下载模型以及应用工作文件，均存储在设备上受系统保护的应用沙盒内（本地 SQLite 数据库与应用管理的文件）。这些内容不会被出售，也不会用于第三方广告。

在应用内删除对话、手记或其他项目时，会删除应用保存的相应数据。"设置 → 隐私"还提供"清除本地历史"和"清除模型配置"操作。卸载应用会删除其本地沙盒数据；由系统另行保存的项目（如钥匙串项或 iCloud 云盘中的文件）按 Apple 的规则处理。

从 Floe 工作区移除文件夹入口，不会删除你设备、网络存储或 iCloud 云盘中的原始文件夹。

### 3. 可选的 iCloud 同步

登录 iCloud 后，应用可使用你可在设置中控制的 Apple iCloud 服务：

- **CloudKit 私有数据库：**非涉密配置（服务商/模型配置、偏好设置、不含密钥值的远程主机配置），以及在画布同步开关开启时（默认开启）的画布素材，通过你的 iCloud 私有数据库同步。这些数据与你的 Apple ID 关联，受 Apple 隐私政策约束。
- **iCloud 钥匙串：**已保存的服务商 API Key、SSH/VNC 密钥可通过 iCloud 钥匙串同步；你可以在应用的同步设置中关闭。任务级、项目级临时凭据不会离开设备，远程连接的客户端身份仅保存在本机。
- 少量偏好值可能通过 Apple 的 iCloud 键值存储保存。

对话、手记和文档不通过 CloudKit 同步。关闭画布同步不会删除已存入 iCloud 的画布副本；在应用中删除画布时，会在远程删除确认后一并删除其同步副本。

### 4. 云端 AI 采用自带密钥（BYOK）

应用不内置任何 AI 服务商密钥，也不附带预付费额度。使用云端 AI 时，你需要为自己选择的服务商（预设服务商或自定义接口）添加 API Key。密钥保存在 iOS 钥匙串中，仅在你执行任务时以授权头发送给该服务商。

云端模型处理请求时，以下内容可能发送给你配置的服务商：

- 任务相关的对话与指令；
- 你附加的图片（以图像数据形式随请求发送）；
- 文件名与从文档中提取的文本，包括 OCR/PDF 文本；
- 工具结果、联网搜索结果以及任务读取的网页；
- 图像或视频生成所用的提示词与参考图片。

服务商如何处理这些数据，受其自身条款与隐私政策约束，不受本政策约束。请事先阅读；除非你接受其处理方式，否则不要向该服务商发送敏感内容。你可以在设置中查看和删除服务商密钥；清除模型配置会从钥匙串（含已同步副本）中删除它们。

### 5. 其他可选连接

只有在你启用、配置或主动指示时，Floe Agent 才会连接以下服务：

- **联网搜索：**搜索请求发送到你启用的搜索服务商（如 Brave、Tavily、Exa、Google 可编程搜索、博查或腾讯 WSA），并使用你提供的密钥。
- **内置浏览器与下载：**应用内浏览器打开你或任务输入的网址。其 Cookie、缓存与网站存储使用系统 WebKit 数据存储，由 iOS 像 Safari 网站数据一样管理（也可在 iOS 设置中清理），Floe 不会导出该存储。另有一点需要区分：当代理任务使用浏览器或 HTTP 工具时，任务读取的网页文本、DOM 或截图以及下载的文件会成为任务内容——它们可能保存在任务的本地工作区、作为模型请求的一部分发送给你配置的 AI 服务商，或作为任务产物保留。代理任务也可按你的要求发起 HTTPS 请求与下载；因此，只应让代理访问与下载你同意按上述方式处理的页面和文件。
- **远程服务器与 Linux 环境：**SSH/VNC/SMB/WebDAV 连接及配对的远程助手，仅连接你提供的主机与凭据，通过 SSH、双向 TLS 或你配置的协议通信。设备本地 Linux 环境在你启动时从项目的 GitHub Releases 下载镜像；其中安装的软件包来自任务使用的软件源（如 PyPI、npm）。
- **本地网络：**经你许可后，应用可发现本地网络中的设备与服务（如终端、打印机、Home Assistant）。
- **GitHub 集成：**登录 GitHub 后，应用使用保存在钥匙串中的 OAuth 令牌直接与 GitHub 通信，用于你主动使用的源码管理与 Actions 功能。
- **模型下载：**设备本地 MLX 模型与语音模型在你主动操作时通过 HTTPS 从 Hugging Face 下载，版本固定并经过完整性校验。可用技能与模型目录从项目的公开 GitHub 仓库获取。下载时，Hugging Face 或 GitHub 的服务器会看到其通常记录的连接信息（如 IP 地址）。
- **媒体处理：**转码、OCR、图像处理等媒体工具在本地运行；生成式图像/视频功能会调用你配置的云端服务商。

代理在你授予的权限内代表你执行操作；导入的文档、网页和工具输出只被视为内容，绝不构成登录新账号或新服务的授权。

### 6. 设备本地处理

- 下载的 **MLX 本地模型**在设备上运行，属于可选的实验性 Beta 功能。除上述模型下载外，经已下载模型处理的提示词与内容不会发送到云端 AI 服务商。
- **Apple 设备端 Foundation 模型**（在你的设备与系统支持时）是 Apple 提供的独立路径。应用仅向其传递回答所需的、有边界的任务内容，处理过程受 Apple 与 iOS 约束。
- 语音转写可使用已下载的本地模型；根据你的 iOS 设置，听写也可能涉及 Apple 的语音服务。

本地处理取决于设备、系统版本、语言和所用模型，不应假定任何功能在所有配置下均可离线使用。

### 7. 反馈与诊断信息

应用提供可选的反馈表单。在你点击提交之前不会上传任何内容；不存在自动崩溃、分析数据或后台上传。你提交后，报告会由开发者通过反馈接口（`https://www.floe-agent.com/api/v1/public/reports`）收集，可能包含：

- 你填写的问题描述；
- 诊断信息：默认随反馈附加，可通过表单中显示的开关关闭。诊断信息可能包含系统/运行时信息、近期日志条目和近期任务的技术摘要；发送前应用会进行密钥脱敏，但脱敏无法保证识别所有敏感内容，请在发送前自行检查；
- 你明确选取的最多三张图片。

提交的报告仅用于处理反馈及其描述的技术问题。其保留时间可能因问题和接口运营服务而异，本政策不承诺固定的保留期限。如不希望发送诊断信息或图片，请关闭诊断开关且不附加图片；你也可以将诊断信息导出为本地文件，通过 iOS 分享面板自行发送而不使用该表单。

### 8. Apple 与 TestFlight 数据

Floe Agent 的 Beta 版本通过 Apple TestFlight 分发，正式版本通过 GitHub 与 Feather 公开发布。通过 TestFlight 测试时，Apple 依据其自身隐私政策与 TestFlight 条款处理测试信息（如安装、崩溃与使用数据）。应用可能请求的系统权限——照片、本地网络、麦克风/语音识别、Face ID/密码、通知——均由 iOS 展示，并可在 iOS 设置中更改。屏幕广播与分享扩展仅处理你选择的内容，不会独立建立网络连接。

### 9. 安全

密钥保存在 iOS 钥匙串中；密钥值不会进入应用数据库、日志、反馈和诊断信息。对公开端点的网络传输使用 HTTPS，本地网络访问需系统授权。但任何传输与存储方式都无法保证绝对安全。

### 10. 未成年人

本应用不面向儿童，也并非有意收集儿童数据。应用没有账号体系、没有广告，不会创建基于年龄的用户画像。

### 11. 变更与联系

产品变化时我们可能更新本政策，页首生效日期会相应变化。重大变更会在公开仓库的本文件中体现。

问题与隐私请求请通过：

- 公开仓库提交 issue：<https://github.com/JiangNanGenius/floe-agent/issues>；或
- 使用应用内反馈表单（见第 7 节）。

GitHub issue 是公开、所有人可见的。请勿在 issue 中发布 API Key、凭据、个人数据或机密内容；请只做概括描述，细节通过应用内反馈发送。

已发布政策：<https://github.com/JiangNanGenius/floe-agent/blob/main/PRIVACY.md>
