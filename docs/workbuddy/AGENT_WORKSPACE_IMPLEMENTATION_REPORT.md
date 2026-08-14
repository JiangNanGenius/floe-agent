# Floe Agent — Agent Workspace 实现报告（贪心推进）

> WorkBuddy 实现报告，面向 Codex 独立审核。本报告区分**生产行为 / 诚实不可用行为 / 无法在当前环境验证的行为**，如实记录已完成与未完成项。
> **本报告不含任何安全/隐私/UX/发布结论**——"审计通过""安全无问题""可发布"等判断全部由 Codex 独立作出。

## Summary

- **分支与最终提交**：`agent/alpha-daily` @ `2b59e27`（18 个实现提交 + 1 个文档提交，基线 `afb0bc7`）。
- **实现起止**：2026-08-15，单次贪心推进（多智能体团队 SOP：主理人编排，产品经理/架构师/工程师×3/QA 分工）。
- **本轮目标**：把 Floe 从"功能入口+调试页面集合"推进为可日常使用的 iPhone/iPad AI Agent 工作空间。
- **测试状态**：**368 个 SPM 测试全绿、0 失败**（基线 224 → 368，净增 144）。QA 两轮独立验证通过。
- **最大已知缺口**：xcodebuild 在本环境被 sandbox 拦截（`sandbox_apply: Operation not permitted`），**iOS App target 的整机编译、双端 Debug/Release 构建、全部真机/模拟器交互路径均未能在本环境验证**。App 层改动以 SPM 全量绿 + `swiftc -parse`（iphonesimulator SDK）零语法错 + 跨文件符号核对作为缓解，但这**不等价于真机构建**——需 Codex 在可跑 xcodebuild 的环境终验。

## 团队与工作方式

| 成员 | 角色 | 本轮产出 |
|---|---|---|
| 许清楚 | 产品经理 | `FloeAgent/docs/PRD_AGENT_WORKSPACE.md`（66 条需求池 + 6 验收场景 + SEC-01~14） |
| 高见远 | 架构师 | `ARCHITECTURE_AGENT_WORKSPACE.md`（P0/P1）、`ARCHITECTURE_SETTINGS.md`（P2）、`ARCHITECTURE_EXECUTION.md`（P3） |
| 寇豆码×3 | 工程师 | T01–T15 + P4 全部实现 |
| 严过关 | QA | 两轮独立验证（发现并跟踪 2 个偏差至修复） |

所有跨成员信息流经主理人中转；并行工程师用独立 build-path 与分离文件区域。过程中发生 3 起跨成员直连与若干并行写入中间态，均已由主理人介入纠正清理（见"已知限制")。

## Commits（19 个，基线 `afb0bc7`）

| SHA | 主题 | 任务 |
|---|---|---|
| `650aaf9` | feat(workspace): T01 data + execution foundation (v5 schema, tool registry) | T01 |
| `59ede94` | feat(workspace): T04 path guard + agent file tools | T04 |
| `6b25308` | feat(chat): T02 markdown rendering + thread components | T02 |
| `6f0909f` | feat(home): T03 chat-first home + composer + inline approval | T03 |
| `9e71a12` | feat(workspace): T05 file inspector + diff + context | T05 |
| `af4249a` | feat(settings): T06 settings storage + v6 migration | T06 |
| `17c0a46` | feat(settings): T07 SettingsCenter + probes + destructive actions | T07 |
| `5ede613` | feat(runtime): T12 tool-loop hardening | T12 |
| `8edb337` | feat(settings): T08 settings shell + general/providers/auxiliary | T08 |
| `e7a4254` | feat(execution): T11 javascript engine | T11 |
| `17fb1c3` | feat(execution): T13 javascript tool wiring | T13 |
| `c43b219` | feat(settings): T09 permissions/execution/files/remote/privacy | T09 |
| `784eff8` | feat(settings): T10 diagnostics + about + export | T10 |
| `6fc6a19` | feat(execution): T14 remote python | T14 |
| `b33d1df` | feat(polish): P4 visual + localization completeness | P4 |
| `b0a1da8` | feat(execution): wire execution tools + remote python probe | T15 |
| `37d664f` | feat(execution): capture js stderr separately | Bug-2 |
| `018bd57` | fix(ipad): route settings/privacy/runs to real screens | Bug-1 |
| `2b59e27` | docs(workbuddy): agent workspace PRD + architecture + progress plan | 文档 |

## 实际完成的功能

### P0 — Chat-first 首页与线程体验（生产行为，SPM 测试覆盖）
- **Chat-first 首页**：打开即可输入；底部 `safeAreaInset` 常驻多行 composer；最近线程列表；发送即 `createConversation` + `router.openConversation` 进线程；生成中发送键变停止键；无模型时完整 App 可用、仅禁 AI 发送并显示模型设置入口（Files/Hosts/Settings 不被锁定）。
- **Composer**：附件（DocumentPicker→安全作用域书签）、模型选择、项目选择、执行目标、Agent 模式。
- **线程组件**：用户气泡 / 助手回答（Markdown 视觉主体）/ 推理折叠"思考过程"块 / 工具调用卡片（名称+状态+耗时+输入/结果摘要）/ 内联授权卡片 / 错误卡片，分类渲染。
- **Markdown 真渲染**：自写 `FloeMarkdown` 块级解析器（标题/列表/嵌套/引用/围栏代码块/GFM 管道表格/分隔线）+ 系统内联渲染；代码块带语言标签+复制按钮；不再把 `###` 等原样显示。
- **状态本地化**：`RunStateLocalizer` 唯一收口（preparing→正在准备、executingTool→正在调用工具、completed→已完成、failed→已失败…）；出现 error/failed 立即结束加载态。
- **内联授权**：只读工具 auto-allow 不弹卡；副作用工具内联卡片显示目标/参数摘要/授权范围四档（仅这一次/本次任务/当前项目/主机）；灾难门禁 `.stopped` 红显且不削弱。
- 关键文件：`FloeApp/Home/ChatHomeView.swift`、`Chat/ThreadComposerView.swift`、`Chat/Render/MarkdownRendererView.swift`、`Chat/{AssistantMessageView,ReasoningBlockView,ToolCallCardView,ErrorEventView,RunStateLocalizer}.swift`、`Sources/FloeMarkdown/*`。

### P1 — 项目工作空间与文件检查器（生产行为，SPM 测试覆盖）
- **Workspace 模型 + v5 迁移**：`workspaces`/`workspace_conversations`/`workspace_recent_files`/`approval_grants` 四张 STRICT 表，追加式，v1–v4 冻结。文件正文与秘密不入库。
- **路径安全层** `WorkspacePathGuard`：拒绝对路径、展开 `..`、`resolvingSymlinksInPath` 防符号链接逃逸、根前缀校验、秘密文件排除清单（.env/.pem/id_rsa/.ssh 等）、读 10MiB/写 4MiB 上限——所有文件访问唯一收口。
- **9 个真实文件工具**（不模拟）：`workspace.{listDirectory,readFile,searchFiles,inspectFileMetadata,createFile,writeFile,applyPatch,moveFile,deleteFile}`，真实读写文件系统，结果回传模型+写 run_events，写操作 mtime+sha256 冲突检测，删除仅文件/空目录。
- **文件检查器**：iPad 可折叠右栏/iPhone Sheet；书签恢复+stale 刷新；懒加载可搜索文件树；文本/Markdown/JSON/Swift/Python/JS 预览 + Quick Look；文本编辑保存（冲突弹窗）；Diff 渲染（LCS）；加入对话上下文。
- 关键文件：`Sources/FloePersistence/{Migrations/V5Workspace,WorkspaceStore}.swift`、`Sources/FloeWorkspace/*`、`FloeApp/Workspace/*`。

### P2 — 完整设置中心（生产行为，SPM 测试覆盖）
- **v6 迁移**：`app_settings(key, value_json, updated_at)` STRICT 键值表，追加式。
- **存储三分层**：DB（app_settings 跨会话行为偏好）/ UserDefaults（即时 UI 偏好）/ 只读探测（能力状态）。凭证只进 Keychain 绝不入库。
- **9 分类全部真实存储或诚实不可用，无占位**：通用 / 模型与供应商（复用 ProviderListView）/ 辅助模型（复用 AuxiliaryModelsView）/ Agent 与权限（授权管理+门禁状态）/ 执行环境（JS 真实探测、Python 诚实 unavailable）/ 文件与 iCloud（工作空间+同步状态+临时文件清理）/ 主机与远程会话 / 隐私与安全（Keychain 状态+清除记录/模型配置+脱敏导出）/ 诊断与关于（版本/构建/DB 版本 v6/能力摘要/日志环形缓冲/许可）。
- **危险操作**：清除本地记录/清除模型配置二次确认 + ClearReport 逐项计数 + Keychain 级联删除。
- iPad 主从 / iPhone 标准导航（**Bug-1 修复后双端一致**）。
- 关键文件：`Sources/FloePersistence/{Migrations/V6AppSettings,SettingsStore}.swift`、`Sources/FloeCore/{AppSettings,CapabilityProbe,SettingsProbes}.swift`、`FloeApp/Settings/*`。

### P3 — JavaScript / Python / Agent 工具闭环（生产行为，SPM 测试覆盖）
- **JavaScript（JSCore 真实执行）**：专用串行队列 + 每次新建 JSContext（隔离）；console.log/info→stdout、warn/error→stderr（双独立有界流各自截断）；inputJSON 注入 + printJSON 收集；超时/取消竞态（实测 `while(true){}` 0.507s 按时返回 timedOut，不卡死）；不注入任何 Swift 对象（JSCore 默认无 FS/网络，天然沙箱）。`exec.javascript` 非副作用 auto-allow。
- **远程 Python（真实执行）**：复用 SSH 长连接；`command -v python3 && python3 --version` 真实探测；base64 包裹 `python3 -c`（iOS 上 stdin 不可行——Citadel `withExec` 是 macOS-15-only，已验证）。`exec.remotePython` 副作用工具，过完整 gate→policy→授权链。无主机→noHostConfigured、无 python3→pythonNotFound、非零退出→executionFailed(exitCode,stderr)，全部结构化诚实报错。
- **本地 Python：诚实不可用，不模拟**。调研结论：PythonKit 仅 macOS 否决；自编译 CPython/MicroPython 需 iOS arm64 交叉编译链 + 体积 +30–80MB + 能力打折，超本轮范围；iOS 禁下载可执行代码排除按需路线。落地为运行时协议 + UI + 能力探测 + 远程 Python + 明确不可用提示。
- **Agent 工具循环补强**：`maxToolSteps=32` 防无限循环（所有工具请求计数，含被拒的）；每步耗时 durationMs 写入 toolResult 事件；运行上下文 system 消息注入（workspace/选中文件/执行目标/工具列表，不持久化）。
- **统一工具目录**：编译期 ToolCatalog Descriptor + 运行期 ToolRunnerRegistry 双注册；CatalogToolExecutor 填实（不再存根）。
- 关键文件：`Sources/FloeExecution/*`、`Sources/FloeSSH/SSHExecService.swift`、`Sources/FloeAgentRuntime/{AgentRuntime,ConversationRunService}.swift`。

### P4 — 视觉、本地化、测试收尾（生产行为）
- 全库纯 SF Symbols 无 Emoji 图标；FloeTheme 语义 token 无散落硬编码色；44pt 触控；Dynamic Type/VoiceOver/Reduce Motion 审查补强。
- `LocalizationCompletenessTests`：462 个 key 全部 en + zh-Hans 双语非空、点分层命名约定；修复 6 个 T03 遗留裸 key（→`editor.*`）。

## 数据库迁移
- 当前 `user_version = 6`。本轮新增 **v5**（workspaces/workspace_conversations/workspace_recent_files/approval_grants）与 **v6**（app_settings），均追加式，v1–v4 冻结。
- 迁移测试：v1→v5、v1→v6 逐版本无损、存量数据存活、外键级联、幂等、STRICT 负例，全部通过。
- 秘密零入库：全部迁移 SQL 经 QA 人工审计，仅存 Keychain 引用（secret_ref_account/synchronizable），无秘密正文列。

## 验证证据（真实命令与结果）

所有命令在 `/Volumes/TECLAST/IOS AI AGENT/FloeAgent` 下运行：

- **SPM 全量测试**（368 绿 / 0 失败 / 47 suite）：
  ```
  SWIFTPM_NO_SANDBOX=1 DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
    swift test --disable-sandbox --build-path /tmp/floe-build
  # → ✔ 368 / ✘ 0，exit=0（QA 两轮独立复跑确认）
  ```
- **git diff --check**：干净。
- **project.pbxproj**：`plutil -lint` 通过。
- **Localizable.xcstrings**：JSON 解析验证 462 key 双语合法（plutil 不支持 xcstrings 格式，已注明）。
- **App 层语法**：改动文件 `swiftc -parse`（iphonesimulator SDK）零错误；跨文件符号逐核对。

## 无法在当前环境执行的验证（如实标注，留 Codex/CI）

- **xcodebuild iOS 双端 Debug/Release 构建**：本环境 sandbox 拦截 xcodebuild 包解析。**最高优先级待 Codex 在可跑 xcodebuild 的机器上做整机编译终验**——App 层（FloeApp/）全部改动只经 SPM macOS 模块测试 + parse 校验，未经过 iOS target 真实编译。
- 全部真机/模拟器交互路径：冷启动向导、键盘遮挡、iPad 三栏实机渲染、杀进程重启持久化（存储层有往返测试）、iCloud 重连、Quick Look、VoiceOver、深色模式实机。
- 活 SSH 主机端到端：`print(2+2)=4` 真实远程执行（无实验主机）。
- 活供应商流式对话端到端（无凭证）。
- XCUITest 覆盖：6 个验收场景仅场景 1 有 2 例 UI 测试，其余无 UI 测试。

## QA 发现的偏差与处置（已闭环）

| 偏差 | 严重度 | 处置 | 回归 |
|---|---|---|---|
| iPad 侧边栏 Settings/Privacy/Runs 路由到占位而非真实页面 | 中 | engineer 修 `018bd57`（双端路由一致） | QA 第 2 轮 PASS |
| JS 执行未单独捕获 stderr | 低 | engineer-t04 修 `37d664f`（双有界流分离） | QA 第 2 轮 PASS |

## 已知限制（诚实记录）

1. **iOS 整机编译未在本环境验证**（最高风险）——见上。
2. **并行工程师协作摩擦**：过程中发生 3 起跨成员直连 DM + 一次 T11 运行中止（留下指向不存在目录的 Package.swift target，已由主理人回滚 manifest）+ 一次工程师 stash 验证与他人中间态冲突（已无损恢复）。主理人已介入建立"独立 build-path + 分离文件区域 + 不直连 + 不 stash 他人区域"纪律。这些是过程问题，最终产物经 QA 两轮验证干净。
3. **工程师顺手修复的潜伏 bug**（好事但需 Codex 知晓）：T01 的 InspectorState 合成 Codable 忽略默认值导致 `inspector_state_json DEFAULT '{}'` 解码失败（T06 修复）；T07 的 setDefaultWorkspace 因 Swift String/UUID 重载决议存裸 UUID（T10 修复）；T13 的 JS flaky 因共享队列被 abandoned run 饿死（T15 改 per-run 队列修复）。
4. **FloeCore 的占位 RemotePythonProbe 未删**（恒 unavailable，已无人引用；真实探针在 FloeExecution，UI 已切换）。建议 Codex 决定删除或标注废弃。
5. **approvalModel/fullControl 授权模式当前 fail-closed 到 human**：缺 ModelApprovalPolicy 的 DecisionBackend 与 fullControl 的 UI 铸造流程，诚实回退 human 而非造假通道。门禁未削弱。
6. **远程 Python 脚本经 base64 `-c` 而非 stdin**（iOS 平台限制，设计预留退路）。

## Codex 重点审核的高风险区域

1. **`Sources/FloeWorkspace/WorkspacePathGuard.swift`** —— 路径逃逸/符号链接/秘密文件/大小上限的唯一收口，所有文件工具与检查器都依赖它。
2. **`Sources/FloeAgentRuntime/AgentRuntime.swift` 的 `handleToolRequest`** —— 灾难门禁 → 授权策略 → 执行的顺序与 maxToolSteps 计数位置（确认门禁仍在 policy 之前、未削弱）。
3. **`Sources/FloeExecution/JavaScriptEngine.swift` + `SSHExecService.swift` + `RemotePythonService.swift`** —— JS 沙箱隔离（无 Swift 对象注入）、SSH exec 的 Swift 6 并发（@unchecked Sendable 盒子）、远程执行的取消/超时竞态。
4. **`Sources/FloePersistence/Migrations/{V5Workspace,V6AppSettings}.swift`** —— 追加式正确性、外键级联、秘密零入库。
5. **凭证边界**：`ConversationCenter.resolveCredentials`、`SettingsCenter.credentialProjection`、`KeychainStore`——确认 API Key/SSH/VNC 凭证只进 Keychain、SSH/VNC 用不同引用、删供应商级联删 Key。

**建议 Codex 优先独立核查的三个流程**：① 在可跑 xcodebuild 的环境做 iOS 双端 Debug/Release 整机编译；② 活 SSH 主机端到端 `print(2+2)=4`；③ 路径安全层的 `../`/符号链接/秘密文件越界在真机上的行为。

**Xcode Cloud/TestFlight 状态**：本轮**未触发**任何 Xcode Cloud 工作流、TestFlight 构建或 App Store Connect 操作；未合并 PR、未发版。云端分发保留给 Codex 独立审核后决定。

---

_工作区在 `2b59e27` 干净。分支待推送（见下）。_
