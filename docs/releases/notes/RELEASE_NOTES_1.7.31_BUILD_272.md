# Floe 1.7.31 (272) — Capability closure and temporary chat

Internal TestFlight candidate. Upload, Apple processing and Floe QA availability are recorded separately; this note does not claim delivery.

## 简体中文

- 新增临时会话：新建聊天后从顶部开关进入，纯文字问答，仅开放已配置的公开网页搜索与抓取。切后台返回保留原会话；切换会话或新建任务立即取消并丢弃。可明确保留为正式会话，包含排队追问及未发送草稿，不重复请求模型。应用被系统终止后不恢复临时内容。
- 服务商搜索融入添加文本、图片和视频模型时的供应商选择器；支持一次选择是否同时配置实际兼容的其他用途，保留现有连接、凭据及默认模型。
- 接通插帧、图片及视频超分处理路径、输出回读和取消。可用性取决于设备、系统及实际安装的处理器或模型；不把普通缩放冒充模型超分，也不捆绑许可尚未确认的模型权重。
- 已授权的 Office、图片和视频任务复用原有编辑、修订及验证服务自动处理副本；完善 Excel 重算值核验、原生长任务查询与取消，并同步 Office Skill 说明。
- 日历和提醒读取支持分页及完整性标记；邮件补充按服务器能力提供的搜索、移动、归档和移入废纸篓。
- 执行型子助手继承主任务实际可用权限并复用审批、环境与修改调度，可互发同一主任务内的消息；子助手不能继续派生助手。
- 修复 Brave 搜索摘要与来源读取，区分日期字段是否可用及其实际含义；搜索摘要不冒充已核实的页面正文。改进系统通知的冷启动路由与回调生命周期；原始设备异常未复现，不将其归因于 Linux。
- 升级 Linux 内核及固件组合，修复模拟器引擎的固件保留内存、网络发送队列和共享目录枚举兼容问题；更新采用与回退遵守停机、哈希、版本和原子提交保护，不覆盖用户磁盘。

验证边界：本地 Xcode 27 完整 App 编译、相关模块及 App 测试与模拟器交互分开记录。macOS 原生媒体处理证据不替代 iPad 实机；实体设备性能、真实邮件服务器及模型服务效果仍需对应环境验证。本轮仅内部 Floe QA，不提交外部公测或发布内容包。

## English

- Adds temporary chat through a compact top toggle after New Chat: text-only with configured public web search/fetch. Background return preserves the same live chat; switching chats or starting a new task cancels and discards it. Explicit Keep saves queued follow-ups and unsent drafts without resending. Process termination does not restore temporary content.
- Embeds provider search in the existing text/image/video model provider picker. A one-time optional multi-role setup preserves existing connections, credentials and defaults.
- Connects interpolation and image/video upscaling pipelines, output verification and cancellation. Availability reflects actual device/system/backend/model support; ordinary resizing is not presented as model super-resolution. Weights with unresolved distribution licensing are not bundled.
- Authorized Office and media tasks reuse existing editing, revision and verification services to produce copies. Improves Excel cached-result verification, native-job status/cancellation and Office Skill capability descriptions.
- Adds pagination/completeness to calendar and reminder reads, plus protocol-aware mail search, move, archive and trash operations.
- Executing subagents inherit the main task's effective permissions through the same approval/environment/mutation paths, and may exchange same-root-task messages. Subagents cannot delegate again.
- Repairs Brave search metadata parsing. Improves cold-start system-notification routing and completion lifetime; the original device exception was not reproduced and is not attributed to Linux.
- Updates the Linux kernel/firmware pair and fixes emulator reserved-memory, network transmit-queue and shared-directory compatibility. Adoption/rollback respects stopped-state, hashes, version precedence and atomic commits without replacing user disks.

Qualification limits: local Xcode 27 App compilation, module/App tests and Simulator interaction are reported separately. macOS native media evidence does not replace physical-iPad acceptance. Device performance, real mail servers and provider output need their respective environments. Internal Floe QA only; no external beta or content-package publication in this round.
