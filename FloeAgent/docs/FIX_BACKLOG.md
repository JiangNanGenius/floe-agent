# FloeAgent 修复与更新清单（待完成）

> 整理日期：2026-08-19。下一次开发按此清单逐项完成。
> **验收标准（重要）**：不要用编译/单元测试当验收。每个修复都要**真机实测**——给模型发一条消息（如"说 hello world"），确认模型真的能回复、功能真的生效。

---

## 验收方式（所有修复统一遵循）

- 每个修复完成后，在真机上做对应的真实操作验证，不看编译绿不绿。
- 涉及模型对话的：给模型发"说 hello world"，确认能收到回复。
- 涉及特定功能的：做那个功能的真实操作（发图片、开自动审批、多步骤任务），确认行为正确。

---

## A. 运行时显示/交互问题（真机复现）

### A1. 文字输出被强制在最下（顺序错乱）
- **现象**：模型输出一段文字后，后续的思考/工具过程显示在那段文字**上面**而不是下面，直到下一段文字出现。
- **根因**：`ThreadTimeline.swift:148` 把"最后一条 assistantText"拔出原位插到 run 末尾；verifyFinalAnswer 路径把草稿存成 message 而非 assistantText 事件，导致顺序倒置。
- **修法**：
  1. `ThreadTimeline.swift:161-179` 所有 assistantText 按序列原位渲染，取消"最后一条特殊化"。
  2. verifyFinalAnswer 草稿轮也走 flushAssistantSegment（assistantText 事件）——`ConversationRunService.swift:344-357` / `AgentRuntime.swift:970`。
  3. `.reasoningSummary` 到达时也 flushAssistantSegment（现在只在 toolRequest/error/completed flush）——`ConversationRunService.swift:503/570/581`。
- **验收**：发一个需要多步工具调用的任务，确认"文字→思考/工具→文字"按时间顺序从上到下排列。

### A2. 多步骤折叠
- **现象**：多次工具调用/思考平铺成一长串卡片，拉上去费劲。
- **修法**：
  1. `ThreadTimeline.swift` 把连续 reasoning/toolRequest/toolResult 聚合成 `stepGroup(events:)`（assistantText/userMessage 作组边界）。
  2. 新增 StepGroupView：折叠态显示"N 个步骤 · 最后：工具名/状态"；**只有最新一组默认展开，历史组默认折叠**。
  3. `ThreadDetailView.timelineRow` 加 .stepGroup 分支。
- **验收**：多步任务时历史步骤默认折叠，能一键展开。

### A3. 消息快速复制
- **现象**：助手消息只有"朗读"没有"复制"。
- **修法**：`AssistantMessageView.swift` 朗读按钮旁加"复制"按钮（UIPasteboard.general.string = text）。
- **验收**：助手消息能一键复制。

---

## B. 审批问题

### B1. 自动审批没生效 + 无状态/结果
- **根因1**：模式只在新会话首条消息固化（`RunLaunchStore.swift:203-215` 只对 createdConversation INSERT task_policies）；Home 的 `draftPolicy` 默认 `.ask`（`HomeLaunchpadViewModel.swift:45`）且无 UI 入口。
- **根因2**：`AutomaticApprovalPolicy` 把联网/远程/GUI 操作归为 ambiguous，未配审批模型时一律升级人工（`ApprovalPolicy.swift:96-103`）。
- **修法**：
  1. Home 的 `draftPolicy` 初值跟随 `settingsCenter.defaultAgentMode`。
  2. `AgentRuntime.swift:1053` `.allow` 分支追加 `autoApproved` 事件（含 tool/policyName），ThreadTimeline 渲染"已自动批准"。
  3. 顶栏 chip 显示当前 policy 名 + 自动批准了哪些。
- **验收**：开自动审批后发任务，确认低风险操作不弹卡、且有"已自动批准"记录。

---

## C. 读图 / 模型配置

### C1. 读图不行（512KB 预算丢图）
- **根因**：`ConversationHistoryAssembler.swift:18-22,49` 的 512KiB 预算，真实照片 base64 后 3-6MB 被静默丢弃，模型收不到图也无报错。
- **修法**：图片预算单独设上限（8MiB）或发送前降采样到 ≤1-2MB 再内联；图片被丢时记日志/系统提示。
- **验收**：发一张照片，模型能描述图内容。

### C2. DeepSeek 不能用（配置陷阱）
- **根因**：非代码 bug。可能是 ① Keychain 读写 namespace 不一致（切过 iCloud Keychain）；② baseURL 填错（含完整路径）；③ 协议切成 OpenAI Responses；④ 模型 ID 不对。
- **修法**：统一 `resolveCredentials` 与 `KeychainSecretStore` 的 namespace；配置页加引导"baseURL 填 API 根（如 https://api.deepseek.com 或 /v1），不要含 /chat/completions"。
- **验收**：配好 DeepSeek 后发"说 hello world"能收到回复。

### C3. 图片模型设置项不全
- **缺的**：模型 ID 无下拉/自动发现（主流程有 discoverModels 但弹窗没用）、尺寸 sizeHint、生成张数、水印开关、单模型启用开关、保存前测试按钮。
- **「视觉输入」灰的**：非 disabled，是 applySupportedOperations 在 provider 支持图像时不自动开 vision（默认 false），UI 无说明。
- **修法**：AuxiliaryModelEditorView 复用 discoverModels 做模型 ID 下拉；补上述字段；视觉输入开关加说明文字。
- **验收**：能添加图片模型并成功生成一张图。

---

## D. 记忆 / 设置导航

### D1. 记忆页用户画像/SOUL.md 点了没用（iPad 专属）
- **根因**：`MemoryView` 的 NavigationLink 在 iPad NavigationSplitView detail 列里外面没有 NavigationStack（`SettingsRootView.swift:66-80`），链接被静默丢弃。iPhone 正常。
- **修法**：SettingsRootView detail 分支包 NavigationStack。
- **验收**：iPad 设置→记忆与个性化，点用户画像/SOUL.md 能进详情页。

---

## E. 日志 / 错误

### E1. 「无法读取」错误残留（10+ 处裸读）
- **根因**：上一轮只修了 SkillsCenter，还有多处裸 `Data(contentsOf:)`：FilesCenter.swift:205/302、SkillPackageValidator.swift:32/131/322、AgentRuntime.swift:165/783、ConversationHistoryAssembler.swift:114、TaskChangesInspectorView.swift:89、CatastrophicActionGate.swift:48、WorkspaceFileService.swift:245/410。
- **修法**：加统一入口 `Data(floeContentsOf:)`，把 CocoaError(fileReadCorruptFile/NoSuchFile/NoPermission) 映射成可读文案（带文件名），全部替换。
- **验收**：不再出现"未能打开该文件，因为它的格式不正确"横幅。

### E2. 日志服务器鉴权防滥用
- **现状**：FeedbackUploadService 端点无鉴权，session_id 每次随机，无法设备级限流。
- **推荐方案**：App Attest（DCAppAttestService）换匿名令牌 + Bearer + 服务器按令牌限流。需 Apple Developer 开 App Attest + entitlements + 服务器 attestation 校验端点。
- **过渡方案**：服务器 challenge + 每安装随机 secret（Keychain）+ 时间戳 + HMAC。
- **验收**：未授权请求被服务器拒绝，正常设备能上传。

---

## F. 本地能力做全（已定方向，待开工）

按优先级（详见 .workbuddy/memory/2026-08-19.md 的完整研究）：
1. 内网请求放开（自动审核，iOS 本地网络权限）
2. Bonjour 设备发现工具 network.scanLAN（NWBrowser，替代 arp）
3. Python 装包（--target 到 workspace + sys.path 白名单，装包走审批）
4. npm 纯 JS 包（预置高频 + CDN 自动拉取 + 预检拦 Node 原生 require）

## G. 高频工具（Python 做不到的）
- OCR（Vision VNRecognizeTextRequest，必须原生）
- 二维码生成/识别（CIFilter + Vision）
- 设备信息进诊断日志（可选包含）
- PDF 读写（PDFKit）、WebSocket（URLSessionWebSocketTask）

## H. 日常功能（已研究，见记忆）
- 小工作量：对话全文搜索 UI（FTS5 现成，注意中文换 trigram）、朗读控制（语速/音调/音色）、结果导出（Markdown/PDF 用 UIPrintPageRenderer/产物打包）
- 中工作量：快捷指令、分享扩展、Widget、用量统计页、SSH 断联续跑（screen/tmux，注入引导命令 + 降级）

---

## 已砍掉（不再做）
剪贴板工具、独立设备信息工具、QEMU 完整 Linux、arp、Node.js 本地。
