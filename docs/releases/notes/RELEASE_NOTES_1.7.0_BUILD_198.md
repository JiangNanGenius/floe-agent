# Floe Agent 1.7.0 (198) / beta.55 — frozen internal-testing candidate

> **状态：已交付内部 TestFlight（Floe QA）。/ Status: delivered to internal TestFlight (Floe QA).**
> 单次验收上传 SDK App 构建在冻结提交 `ce3574f36f954bb64c100754ff17295cead7c238` 上执行
> （[run 35428858014](https://github.com/JiangNanGenius/floe-agent/actions/runs/35428858014)），
> 未签名的设备 IPA `Floe-Agent-1.7.0-build198-unsigned.ipa`（sha256
> `92af2a99d99daa1d5962e8e783be6d3bab49971360340a0d039d83eba881ec9a`，811,481,871 B）与其
> 匹配的私有符号包在签名前已保留。经来源证明的未签名 GitHub 预发布 `v1.7.0-beta.55` 与
> Feather 源均来自同一工件（Feather run 35430911661；`feather.json` sha256 `92af2a99…`，
> sourceCommit `ce3574f3…`）。Apple buildID `efbad369-6908-4c7a-950b-597c03716e5b` 已核验为
> `VALID`、未过期、仅一个私有 Floe QA 组且 `IN_BETA_TESTING`（2026-09-19 08:32 UTC，
> [prepare 35432200199](https://github.com/JiangNanGenius/floe-agent/actions/runs/35432200199)、
> [verify 35432243630](https://github.com/JiangNanGenius/floe-agent/actions/runs/35432243630)），
> 英文与简体中文测试说明均已写入并读回。模拟器／UI 资格按用户明确要求跳过，因此这是内部
> 设备测试而非完整验收；真机验收属于用户，Build191 本地模型前台中断仍未证实修复。
>
> **Status: delivered to internal TestFlight (Floe QA).** The single accepted-SDK
> App build ran in [run 35428858014](https://github.com/JiangNanGenius/floe-agent/actions/runs/35428858014)
> from the frozen commit `ce3574f36f954bb64c100754ff17295cead7c238`. The unsigned
> device IPA `Floe-Agent-1.7.0-build198-unsigned.ipa` (sha256
> `92af2a99d99daa1d5962e8e783be6d3bab49971360340a0d039d83eba881ec9a`, 811,481,871 B)
> and its matching private symbols were retained **before** signing. The attested
> unsigned GitHub prerelease `v1.7.0-beta.55` and the Feather source were published
> from that same artifact (Feather run 35430911661; `feather.json` sha256 `92af2a99…`,
> sourceCommit `ce3574f3…`). Apple buildID `efbad369-6908-4c7a-950b-597c03716e5b` was
> verified `VALID`, unexpired, exactly one private Floe QA group and `IN_BETA_TESTING`
> at 2026-09-19 08:32 UTC, and both English and Chinese test notes were saved and read
> back. Simulator/UI qualification was skipped by explicit user request, so this is
> internal device testing, not full acceptance; physical-device acceptance belongs to
> the user and the build 191 local-model abort remains unproven fixed.

功能实现范围 / Implementation range：`1cff5665..11681a0f`（当前分支
`codex/build192-feedback-round2`，8 个功能提交 / 8 implementation commits），加上 Build 197
编译失败后的两处最小源码修复与 198 版本／文档准备提交；Build 198 的对外功能与 Build 197
候选相同，最终冻结提交另记于发布证据。内部 TestFlight、GitHub
开发者包与 Feather 是相互独立的交付物；不含公开 Beta 提交。

## Build 197（`v1.7.0-beta.54`）编译失败与 Build 198 修复 / Build 197 (`v1.7.0-beta.54`) compile failure and the build 198 fix

- Build 197（提交 `f05b02ac`，标签 `v1.7.0-beta.54` 已创建并固定在该提交）在
  [run 35426497884](https://github.com/JiangNanGenius/floe-agent/actions/runs/35426497884)
  的 “Rebuild the exact tag with the accepted App Store SDK” 步骤于 2026-09-19 06:52 UTC
  编译失败：5 条诊断、2 个独立错误 ——
  1. `FloeAgent/FloeApp/Settings/ExecutionEnvironmentView.swift` 第 82/105/124/147 行
     `cannot find type 'RuntimeInventoryEntry' in scope`：该类型定义在 `FloeExecution`
     模块（`FloeAgent/Sources/FloeExecution/RuntimeInventory.swift`），而视图只导入了
     `FloeCore`／`FloeEnvironments`／`FloeSSH`，缺少 `import FloeExecution`；
  2. `FloeAgent/FloeApp/Workspace/FileInspectorView.swift:132:24`
     `initializer for conditional binding must have Optional type, not 'String'`：
     `previewPath` 已被外层 `if let previewPath` 解包为非可选值，行内再次
     `if let previewPath` 属于对非可选值的条件绑定。
- 该次运行没有产出 App 工件、没有签名、没有 TestFlight 上传（编译之后的步骤全部跳过），
  **Build 197／beta.54 从未上传**。标签 `v1.7.0-beta.54` 停在 `f05b02ac`，不得移动；
  Build 198／`v1.7.0-beta.55` 是其替代候选。
- Build 198 的修复保持最小：`ExecutionEnvironmentView.swift` 增加 `import FloeExecution`；
  `FileInspectorView.swift` 去掉行内多余的第二次绑定（不改变行为）。只有验收上传 SDK 的
  云端 App 编译才能最终确认这两处修复；本轮只做了 `swiftc -parse`，不得当作编译通过。

Build 197 at `f05b02ac` (tag `v1.7.0-beta.54`, created and fixed at that commit) failed
the accepted-upload-SDK App compile inside
[run 35426497884](https://github.com/JiangNanGenius/floe-agent/actions/runs/35426497884)
at 2026-09-19 06:52 UTC with five diagnostics and two distinct errors: the missing
`FloeExecution` import for `RuntimeInventoryEntry` in
`ExecutionEnvironmentView.swift:82/105/124/147`, and the duplicate conditional binding
of `previewPath` at `FileInspectorView.swift:132:24` ("initializer for conditional
binding must have Optional type, not 'String'"). No App artifact was produced, nothing
was signed and nothing was uploaded (every step after the compile was skipped): **build
197 / beta.54 was never uploaded**. The tag `v1.7.0-beta.54` stays at `f05b02ac` and is
not moved; build 198 (`v1.7.0-beta.55`) is the replacement candidate. The build 198 fix
is minimal: add `import FloeExecution`; remove the redundant second binding (no behavior
change). Only the accepted-upload-SDK cloud App compile can confirm the fix; this round
ran `swiftc -parse` only and does not claim a passing compile.

## 简体中文

- **思维导图：触摸直接新增节点**：编辑器左上角固定提供“新增子节点”和“新增同级节点”，
  使用指针事件，手指与 Apple Pencil 均可操作。选中主题后点按即创建节点并进入文字编辑，
  不需要再点画布；未选主题、对中心主题新增同级或导图仍在保存时给出明确提示。新增后连线
  重新排布，修改可撤销并在同一次保存中落盘，原生提交往返不会打断正在编辑的文字
  （`FloeAgent/FloeApp/Resources/MindElixir/floe.js`、`floe.css`）。
- **视频：公开候选自动选择与方舟凭据**：
  - 视频路由不再要求内部 UUID：`video.models` 返回公开模型名
    （`publicModelID`／`publicCandidates`），`video.generate` 接受可选 `model`
    （remoteModelID 或显示名，忽略大小写与分隔符的精确／前缀／包含匹配）；歧义或未知时
    返回公开候选列表且不回显内部 UUID。画布 `canvas.generate` 同样支持公开选择，画布
    ceiling 增加只读 `video.models` 供挑选；发现层新增 `video` 同义词与选择说明。当前
    对话模型在公开候选间自行选择，不再向用户索要 UUID。
  - 方舟 401 的根因是视频提交／轮询读取了错误的 Keychain 命名空间：旧路径读
    `org.floeagent.ios.providers`，而唯一写入路径（供应商编辑器）写
    `org.floeagent.ios.secrets`。修复后 `videoCredential(for:)` 改走
    `KeychainSecretStore.readSecret(reference:)`（声明域优先、另一域兜底；空／空白密钥
    归一为 `nil`）；日志只记录 provider/model、keychainAccount 与密钥是否存在，不记录
    密钥内容。真实付费视频调用与真机复测未执行。
- **工具调用历史、上下文恢复与摘要脱敏**：
  - 跨 run 恢复有界脱敏工具证据：只读同一会话最近 4 个 run 的 `.toolResult` 事件，仅取
    tool/status/callID 与 2,400 字符预算内的 head+tail 截断摘要，作为
    `priorToolEvidencePrefix` 系统消息注入；压缩摘要与手动快照在前缀白名单放行；本地模型
    按 tier 回放 2–6 对、600–2,000 字符的最新工具对，Apple FM 重建 transcript 同步；
    回放字节计入压缩预算；重试快照补齐 `allToolNames`。会话隔离：只按同一
    `conversationID` 且仅普通 run，画布／手记专用会话不读取普通聊天证据。
  - 持久脱敏：写入 run 事件的工具结果摘要经 `SecretRedactor.redact` 脱敏（工具输出不可信、
    可能意外回显凭据），本轮运行仍拿到原始结果；新增
    `toolEvidenceReplayed`／`toolEvidenceRecovered` 等日志只含计数、工具名与公开模型名。
- **执行环境版本与 APT 工具路由**：设置 → 执行环境页不再使用固定占位行，合并真实来源
  （内置 JavaScriptCore、内置 CPython 3.13.x、内置 Node 18.20.4 与 npm/pnpm/yarn、配对
  远程主机 Python、用户安装的签名目录版本与激活回执、项目环境层清单），并标注
  “内置／远程主机／用户安装／项目环境”。更新状态只在比较两个真实版本后出现；缺失或损坏的
  清单被跳过而不是猜测。`capability-hub/tool-catalog.json` 与 App 内
  `ToolCapabilityCatalog.json` 保持同一字节，路由分 `direct`／`floe-precompiled`／
  `remote`／`unsupported`，26 个常用命令被覆盖；`ManagedPackageTool` 描述扩展
  `route=`／`local=`／`installable=`。`CapabilityInstaller` 按路由给出真实回执或拒绝
  原因，direct 命令“安装”只确认已可用。APT 仍是 Shell 下的包管理能力，未新增 Agent 工具。
- **妙控键盘：Return 发送、Shift+Return 换行**：新增共享
  `ComposerReturnField`（聊天输入框与画布助手）。硬件键盘：无修饰 Return 发送（仅在可发送
  时），Shift+Return 换行，任何修饰键（Shift/Control/Option/Command）都保持换行；输入法
  仍在组字时 Return 只提交组字、不发送。软件键盘保持经典多行换行，仅此前使用
  `.submitLabel(.send)` 的画布助手继续软件 Return 发送；画布提示更新为
  “Return 发送 · Shift+Return 换行”。
- **Office：首次预览／第二次编辑、新建直编**：Notes 中的既有／导入 Office 文档第一次进入
  为只读预览，第二次起直接进入编辑器（即使第一次只看过预览）；只有在 App 内新建的文档
  首次即直编。规则位于纯类型 `OfficeDocumentModeMemory`（有单测），App 侧用
  `OfficeDocumentModeStore`（UserDefaults）持久化；键由作用域＋文档身份派生、无原始路径、
  有界，损坏数据降级为空记忆，失败打开不计数，临时草稿目录不会改写状态。预览态“编辑”入口
  在 App 顶部工具栏；编辑判定先等待原生宿主回传真实引擎权限（有界等待），不再把未打开页面
  误判为只读（此前 iPhone 编辑静默回退预览的根因）；打开看门狗避免宿主不回应时无限转圈。
- **Office：IDE 内嵌、Git、分享、文件管理直达、Pencil、远端快照只读**：
  - IDE：Office 始终内嵌在各自的 IDE 标签，打开不会再弹第二个窗口，全屏是标签操作栏的
    显式动作；未保存圆点直接观察共享 Office 会话；经校验的原文件提交会刷新同级的文件树／
    预览／标签。
  - Git：IDE 工具栏新增“源码管理”入口，打开该固定工作区的源码管理（状态、差异、暂存、
    提交、分支）。
  - 分享：预览、编辑器与 IDE 内嵌操作栏都提供显式“分享”，输出经校验的快照副本到系统分享
    面板；只读预览分享最后一次已提交字节，可编辑会话先让引擎落盘；原始文件不会被交出或
    修改，快照在面板关闭后回收。
  - 文件管理直达：文件检查器对 Office 文档的展开动作直接打开原生全屏编辑器，不再进入 IDE，
    也绝不把 Office 字节交给代码工作台。
  - Pencil：`stableInkIdentity` 让云端／网络快照与 Notes 生成文档在每次新建预览／草稿路径
    时保持同一墨迹设置；本地文档继续按物理路径身份；作用域＋文档键去路径化、有界，跨工作区
    不串用。
  - 远端快照只读：云端／网络 Office 文档先落到私有临时副本，任何入口都只呈现只读快照并给出
    “下载到本地工作区再编辑”的说明；编辑、保存、放弃入口隐藏，导出／另存／分享保留；临时
    副本的编辑永远不会伪装成远端保存。
- **画布：移除无效入口**：画布助手不再对研究结果显示“加入画布”按钮，`addResearchNote`
  路径删除；研究结果保持只读并留在助手对话中，不会自动写入画布；定向节点的显式应用保持
  不变（双语 `USER_GUIDE` 已同步）。
- **本地模型（部分修复，未证实）**：on-device provider 不再启动 120 s 云看门狗（保留用户
  取消），等待文案改为 on-device 语义；系统信封按 tier 截断以缩小首次 prefill。**Build191
  的前台 Qwen GatedDeltaNet（`gatedDeltaUpdate`）abort 仍未证实修复，必须真机确认；不得
  按已修复对待。**

### 设备手动检查清单（精简）

1. 思维导图：选中主题后点“新增子节点／新增同级节点”，确认立即创建并进入文字编辑；分别用
   手指与 Apple Pencil；验证未选主题／中心主题同级／保存中的提示，以及撤销与重开后的保存。
2. 视频：确认 `video.models` 显示公开模型名；不带 `model` 提交一次方舟视频生成（真实费用，
   使用自己的凭据），观察成功提交与控制台任务；重启后 `video.status` 仍能续查。
3. 长对话工具上下文：制造多次工具调用后重启 App 继续同一会话，确认模型记得此前的工具结果；
   在触发压缩的长对话中确认压缩摘要仍在。
4. 执行环境：打开设置 → 执行环境，核对内置／远程／用户安装来源与版本；执行一次
   `apt install floe/ruby`（或 `floe/php`）确认签名安装回执；对 direct 命令确认“安装”只报告
   已可用。
5. 键盘：外接键盘在聊天输入框测试无修饰 Return 发送、Shift+Return 换行、输入法组字时 Return
   不发送；画布助手确认软件 Return 仍可发送、Shift+Return 换行。
6. Office：打开既有／导入文档确认第一次为只读预览、第二次直接编辑；新建 Office 文档确认
   首次即直编；在预览与编辑态各点一次“编辑”，确认不再静默回退。
7. Office 集成：在 IDE 中打开 Office（应内嵌且不弹窗），确认未保存圆点、保存后同级刷新、
   “源码管理”面板与“分享”面板；从文件管理器的展开动作确认直达全屏编辑器。
8. 远端快照：打开云端／网络 Office 文档，确认只读提示、无编辑／保存入口、分享与导出可用；
   下载到本地工作区后再打开确认可编辑。Pencil 墨迹设置在重新打开后保持不变。

### 已执行的轻量验证（仅此清单；非 App 或真机证据）

Build 198 准备轮只做了以下轻量校验：

- `swiftc -parse` 解析本轮触及的两个 Swift 源文件
  （`ExecutionEnvironmentView.swift`、`FileInspectorView.swift`）；
- xcodegen 项目生成（`FloeAgent/project.yml` ↔ 已提交的 `FloeAgent.xcodeproj`，
  pbxproj 的 diff 仅 197→198 的 8 处构建号）；
- 精确版本／构建号一致性：4 个 target 全部 `MARKETING_VERSION` 1.7.0、
  `CURRENT_PROJECT_VERSION` 198（Debug/Release 共 8 处）；
- 本 TestFlight JSON 的 JSON 校验；
- `git diff --check`。

**未执行**：App 目标云端编译、`xcodebuild`、SwiftPM、模拟器／真机 UI、双 SDK、
本地归档／打包、任何云工作流派发与 TestFlight 上传；真实供应商调用（含方舟视频付费提交）
本轮也未执行；197 轮的功能级夹具检查本轮不重复
执行，其结论保持原记录。App 云编译与用户真机验收待后续；本地 Qwen/GDN 首次消息崩溃
仍待真机确认，尚未证实修复。本文不替代冻结源码后的云端构建与真机证据。

## English

- **Mind maps: touch creates nodes directly**: the editor keeps **Add child node** and
  **Add sibling node** at the top-left, driven by pointer events so both a finger and
  Apple Pencil work. With a topic selected, one tap creates the node and opens its text
  editor with no extra canvas tap; a missing selection, a center-topic sibling or a
  still-saving map gets an explicit hint. Connectors re-flow, the change stays undoable
  and lands in the same save, and the native commit round-trip never interrupts active
  typing (`FloeAgent/FloeApp/Resources/MindElixir/floe.js`, `floe.css`).
- **Video: public-candidate selection and Ark credentials**:
  - Video routing no longer demands an internal UUID: `video.models` returns public model
    names (`publicModelID` / `publicCandidates`) and `video.generate` accepts an optional
    `model` (remoteModelID or display name, matched exactly / by prefix / by contained
    name with case and separators ignored); ambiguous or unknown input returns the public
    candidate list without echoing internal UUIDs. `canvas.generate` accepts the same
    public choice and the canvas ceiling gains read-only `video.models`; discovery adds
    `video` synonyms and selection guidance. The current chat model picks among the
    public candidates instead of asking the user for a UUID.
  - The Ark 401 root cause was a wrong Keychain namespace for video submit/poll: the old
    path read `org.floeagent.ios.providers`, while the only writer (the provider editor)
    writes `org.floeagent.ios.secrets`. `videoCredential(for:)` now uses
    `KeychainSecretStore.readSecret(reference:)` (declared synchronizable domain first,
    the other domain as a fallback; empty/blank keys normalize to `nil`), and logs record
    only provider/model, keychainAccount and key presence, never key material. No paid
    provider call or device re-check was performed.
- **Tool-call history, context recovery and summary redaction**:
  - Cross-run bounded, sanitized tool evidence is recovered from the same conversation's
    last 4 runs of `.toolResult` events (tool/status/callID plus a head+tail summary
    within a 2,400-character budget) and injected as the `priorToolEvidencePrefix`
    system message; the compaction-summary prefix and manual snapshots are allow-listed;
    local models replay 2–6 of the newest pairs (600–2,000 characters per tier) and the
    Apple FM rebuilt transcript receives the same tool history; replayed bytes count
    toward the compaction trigger; the dispatch snapshot persists `allToolNames`.
    Isolation: same `conversationID` only, ordinary runs only — canvas/Notes surfaces
    never receive ordinary-chat evidence.
  - Persisted tool result summaries written to run events now pass through
    `SecretRedactor.redact` (tool output is untrusted and may echo a credential); the
    live runtime still receives the original result for that turn. New
    `toolEvidenceReplayed` / `toolEvidenceRecovered` logs carry only counts, tool names
    and public model names.
- **Execution-environment versions and APT tool routes**: Settings → Execution
  Environment no longer shows three fixed placeholder rows; it merges real sources
  (bundled JavaScriptCore, bundled CPython 3.13.x, bundled Node 18.20.4 with
  npm/pnpm/yarn, paired remote-host Python, user-installed signed-catalog versions plus
  activation receipts, and project-layer manifests) and labels each as
  Bundled / Remote / User / Project. Update state only appears after two real versions
  are compared; missing or corrupt manifests are skipped, never guessed.
  `capability-hub/tool-catalog.json` and the app-side
  `ToolCapabilityCatalog.json` stay byte-identical; routes are `direct` /
  `floe-precompiled` / `remote` / `unsupported`, covering the 26 required commands;
  `ManagedPackageTool` descriptions gained `route=` / `local=` / `installable=`, and
  `CapabilityInstaller` reports a real receipt or rejection per route — installing a
  `direct` command only confirms availability. APT remains a Shell package capability;
  no new agent tool was added.
- **Magic Keyboard: Return sends, Shift+Return inserts a newline**: the shared
  `ComposerReturnField` replaces the chat `TextField` and backs the canvas assistant.
  Hardware keyboard: unmodified Return sends (only while sendable), Shift+Return inserts
  a newline, and any modifier (Shift/Control/Option/Command) keeps the newline; Return
  while an input method is composing marked text commits the composition instead of
  sending. The software keyboard keeps its classic multiline behavior except the canvas
  assistant, which previously used `.submitLabel(.send)` and keeps software Return
  sending; its hint now reads “Return 发送 · Shift+Return 换行”.
- **Office: first-entry preview / second-entry edit; new documents edit directly**: an
  existing or imported Office document in Notes opens as a read-only preview on its
  first entry and directly in the editor from the second entry onwards, even when the
  first visit only previewed; only a document created inside the app opens straight in
  the editor on its first entry. The rule lives in the pure
  `OfficeDocumentModeMemory` type (unit-tested) with the App-side
  `OfficeDocumentModeStore` (UserDefaults) persisting path-free, bounded, scope + document
  keys; corrupt payloads degrade to an empty memory, a failed open is never counted, and
  transient draft directories cannot rebind state. The preview Edit entry sits in the
  App's top toolbar, and the editable decision first awaits the native host's verified
  engine permission (bounded) instead of reading a not-yet-opened page as read-only (the
  root cause of the silently reverted iPhone edit); an open watchdog prevents a
  never-reporting host from spinning forever.
- **Office: IDE embedding, Git, share, file-manager direct entry, Pencil, read-only
  remote snapshots**:
  - IDE: an Office document stays embedded in its own IDE tab; opening it never spawns a
    second window and fullscreen is an explicit tab action. The unsaved dot observes the
    shared Office session, and a verified original-file commit refreshes sibling file
    tree / preview / tabs.
  - Git: the IDE toolbar adds a **Source control** entry for the pinned workspace
    (status, diff, stage, commit, branch).
  - Share: preview, editor and the IDE embedded action bar all offer an explicit Share
    that sends a verified snapshot copy to the system share sheet; a read-only preview
    shares the last committed bytes, an editable session flushes the engine first, the
    original file is never handed out or mutated, and the snapshot is reclaimed when the
    sheet dismisses.
  - File-manager direct entry: the file inspector's expand action for an Office document
    opens the native fullscreen editor directly — never the IDE and never a text decode.
  - Pencil: `stableInkIdentity` keeps the same ink settings for cloud/network snapshots
    and Notes-generated documents across fresh preview/draft paths, while local documents
    keep their physical-path identity; the scope + document keys are path-free, bounded
    and never shared across workspaces.
  - Read-only remote snapshots: cloud/network Office documents are staged into a private
    temporary copy and every entry point presents them as read-only snapshots with a
    download-to-local-workspace hint; edit/save/discard entries are hidden while
    export/save-copy/share remain, and a temp-copy edit can never masquerade as a remote
    save.
- **Canvas: removed the ineffective entry**: the canvas assistant no longer shows an
  **Add to canvas** button for research results and the `addResearchNote` path is gone;
  research results stay read-only in the assistant conversation and are never written to
  the canvas automatically, while explicit node-targeted application is unchanged (both
  `USER_GUIDE` languages are updated).
- **Local models (partial, unproven)**: on-device providers no longer start the 120 s
  cloud watchdog (user cancellation is kept) and the waiting copy uses on-device
  semantics; the harness system envelope is truncated by tier to shrink the first
  prefill. **The build 191 foreground Qwen GatedDeltaNet (`gatedDeltaUpdate`) abort
  remains unproven fixed and needs device confirmation; do not treat it as fixed.**

### Device manual-test checklist (compact)

1. Mind maps: with a topic selected, tap **Add child node / Add sibling node** and
   confirm the node is created and its text editor opens immediately; repeat with a
   finger and with Apple Pencil; verify the no-selection / center-topic sibling /
   still-saving hints, plus undo and save after reopen.
2. Video: confirm `video.models` lists public model names, submit one Ark generation
   without `model` (real charges; use your own credentials) and confirm success plus the
   provider-console job; confirm `video.status` still resumes after a restart.
3. Long-conversation tool context: after several tool calls, restart the app and continue
   the same conversation; the model should remember earlier tool results, including
   across a compaction summary.
4. Execution environment: open Settings → Execution Environment and check the
   Bundled/Remote/User versions and sources; run `apt install floe/ruby` (or `floe/php`)
   and confirm the signed-install receipt; for a `direct` command confirm “install”
   only reports availability.
5. Keyboard: with an external keyboard, test unmodified Return sending, Shift+Return
   newline and Return during IME composition in the chat composer; in the canvas
   assistant confirm software Return still sends and Shift+Return inserts a newline.
6. Office: open an existing/imported document and confirm the first entry is a read-only
   preview and the second opens the editor; create a new Office document and confirm it
   edits directly; tap Edit from preview and from editing and confirm no silent revert.
7. Office integration: open Office in the IDE (embedded, no extra window) and verify the
   unsaved dot, sibling refresh after save, the **Source control** panel and the Share
   sheet; use the file inspector's expand action and confirm it opens the fullscreen
   editor.
8. Remote snapshots: open a cloud/network Office document and confirm the read-only hint,
   the absence of edit/save entries and working share/export; download it to a local
   workspace and confirm it becomes editable. Pencil ink settings must survive reopen.

### Verification performed (only this list; not App or device evidence)

The build 198 preparation round ran only these light checks:

- `swiftc -parse` on the two Swift sources touched by this round
  (`ExecutionEnvironmentView.swift`, `FileInspectorView.swift`);
- xcodegen (`FloeAgent/project.yml` ↔ the committed `FloeAgent.xcodeproj`; the pbxproj
  diff is exactly the eight 197→198 build settings);
- exact version/build consistency: all four targets are `MARKETING_VERSION` 1.7.0 and
  `CURRENT_PROJECT_VERSION` 198 (eight settings across Debug/Release);
- JSON validation of this test note;
- `git diff --check`.

**Not run**: App-target cloud compile, `xcodebuild`, SwiftPM, simulator/device UI,
dual-SDK, local archive/package, any cloud workflow dispatch or TestFlight upload, or
real provider calls (including paid Ark video submission). The
build 197 round's feature-level fixture checks were not re-run and their recorded
results stand. The App cloud build and the user's device acceptance remain pending; the
local Qwen/GDN first-message crash still needs device confirmation and is not claimed
fixed.
This document is no substitute for the frozen-source cloud build and device evidence.
