# Floe Agent 1.7.0 (194) / beta.51 — frozen internal-testing candidate

Build 194 carries the build 191 feedback repair plus the accepted-SDK compile
fixes for the two earlier freezes, none of which uploaded:

- build 192 (`v1.7.0-beta.49` at `1dc6577a`) stopped in `FloeLocalModels/MLXTextEngine.swift`
  with a Swift 6 region-isolation error ("sending 'input' risks causing data races");
- build 193 (`v1.7.0-beta.50` at `e0b4c8ca`) then exposed seven App-target errors that the
  earlier compile never reached: two missing media-polling symbols in
  `BackgroundRunCoordinator`, a non-exhaustive `ShellRunOutcome` switch in
  `FloeShellCommands`, an isolated `Identifiable` conformance in `IDEWorkspaceTabs`, an
  optional `Bool?` permission probe and two invalid `CocoaError` codes in
  `OfficeDocumentEditorView`.

Both immutable tags and their failure evidence stay recorded. Build 194 applies
those fixes and is the candidate that proceeds.

The release pipeline creates the reserved tag `v1.7.0-beta.51` at the frozen
commit this document ships in, performs the **single** accepted-upload-SDK App
build (Xcode 26.6 / 17F113), and retains the unsigned device IPA with its matching
private symbols **before** signing or upload; reuse of a retained exact artifact is
preferred over a rebuild. It then uploads to the internal TestFlight build and,
after the upload is accepted, publishes the attested unsigned GitHub prerelease
and requests the Feather source publication.

- the frozen source is one immutable commit; the tag is created at that commit
  by `release-unsigned-ipa.yml` and is never moved or re-pointed;
- the validation recorded below is host-level and fixture-level and does not
  replace the accepted-SDK App compile or device evidence;
- internal TestFlight, the GitHub developer IPA and Feather are separate
  deliverables and each is verified for the frozen source after the run; Apple
  processing, `VALID`, the private Floe QA group and the bilingual note readback
  are confirmed separately and recorded in the TestFlight record;
- no public Beta submission is included; the public Beta materials remain
  drafts, not a submission.

The notes below separate implemented behavior, host-level validation and open
device acceptance. **Physical-device acceptance belongs to the user.**

## 简体中文

- **Office 真实可编辑状态**：未知或缺失的只读标志不再被当作可编辑；受保护文档、
  只读挂载和引擎拒绝的切换会回到预览并说明原因；需要编辑密码时提示输入，而不是
  当作拒绝。新的原生宿主 API（会话只读状态、打开时权限回调、权限变化回调、受保护
  进入编辑）已在云端组件工作流 `35373122891`（提交 `b494897c`）编译链接通过；
  保存／关闭／重开与真机编辑仍待验证。
- **导入的复杂工作簿**：只有 Floe 自己生成、带 `floe-chart-data-<n>.xlsx` 标记的
  图表工作簿才会被重新生成。导入的多工作表／带公式工作簿不会被静默改写：严格保存
  校验失败时会**拒绝保存并保留原文件**，而不是丢弃内容。图表往返真机验证未完成。
- **IDE 路由与标签**：文件只会进入对应工作面（Office 编辑器、PDF 阅读器、图纸
  查看器、图片查看器、媒体工作台、快速查看、代码编辑器）；代码工作台不再接收
  Office 或二进制字节，读和写都会先做类型与二进制检查（原生与网页侧同一策略）。
  IDE 内代码、Office、文档各有原生标签；Office 标签的内嵌预览与全屏编辑共用
  一个工作副本，关闭有未保存修改的标签会先询问保存或放弃。
- **共享**：文件预览新增“共享”，分享当前屏幕上的文档；云端／网络文件会先在本地
  保存一份临时副本，屏幕上正在使用的副本不受影响；低频操作移入“更多”菜单。
- **Git**：快进现在真正移动 HEAD 与工作树（此前会报成功但没有任何变化）；冲突
  文件路径解析与冲突列表修复；放弃暂存行的修改会同时恢复索引和工作树，并在
  `.git/floe-recovery` 保留恢复副本；新增暂存／未暂存分区、暂存差异、合并冲突
  编辑与中止合并。仍不提供 reset/clean、强制推送或历史改写。
- **终端与 Shell**：交互会话描述符竞态修复（先声明所有权再操作，失败即取消）；
  立即退出命令的最后输出不再丢失；IDE 底部可嵌入终端并复用应用级会话，关闭面板
  不会结束 shell；引擎忙时返回 exit 75（notStarted），不再伪装成执行超时；取消
  的包命令返回 130 且不会继续执行。
- **包**：显式 `npm install`／`pnpm install` 始终按你输入的管理器执行，项目锁文件
  和偏好只用于自动选择；WASM 能力按签名条目限制模块大小、内存与超时（默认
  4 MiB／64 MiB／30 s，解释器上限 64 MiB／1 GiB／600 s），解释器启动可能需要更长
  `timeout` 或后台任务。Python 依赖的可写路径优先于受管基线，导入版本与当前激活
  环境一致。
- **模型回退**：默认／草稿模型被禁用、删除或隐藏时，按“当前选择 → 已存默认 →
  最近运行使用 → 第一个可用”修复，不再把不可用的模型留在默认位置；运行中的请求
  保持自己的模型，不受影响。
- **视频（普通对话）**：新增 `video.models`、`video.generate`、`video.status`、
  `video.cancel`；只列出已启用且已适配的模型；支持一张参考图（工作区路径或对话
  附件，PNG/JPEG/WebP，≤ 8 MiB，内联传输），不支持参考图的模型会明确拒绝而不是
  忽略；同一工具调用重放会复用已有任务（不会重复付费），新请求创建新任务；取消
  优先于提交，下载中被取消的任务不会被宣告就绪；过期的结果地址如实标记。GIF 可
  检查真实帧数、循环与时长，`gif(fps,width)` 会真实合成并重采样为固定帧率，属于
  本地确定性转换而非 AI 生成。
- **本地语言**：`floe/ruby` 3.4.1（34,719,962 B）与 `floe/php` 8.2.33（CLI SAPI，4,077,891 B）已推进到签名目录并随本构建打包（签名批次 `capability-hub.yml` run 35399070312，源提交 `96be231e`；`FloeAgent/FloeApp/Resources/Capabilities` 为本构建导入了该批次的签名副本）。`apt install floe/ruby`／`floe/php` 会从签名条目下载并校验工件后安装；解释器启动可能超过 Shell 默认超时，请提高 `timeout` 或改用后台任务。PHP 8.2 为安全维护版本（官方支持至 2026-12-31），已重放到最新 8.2.33 并带 21 个已复核补丁。Rust／C／C++／Go／Swift 单文件走云端编译路线，工件仍为未签名 `cloud-staging`。真机安装与运行验收由你完成。
- **本地模型**：新增前台状态检查与后台取消保护，避免后台继续提交本地 GPU 推理；取消不会标记为模型失败。MLX 错误处理、释放前 GPU 排空与诊断已加强。生命周期测试 39 项、诊断测试 15 项通过，UIKit 分支已生成 SIL／目标文件。Build191 的前台 Qwen GatedDeltaNet 崩溃仍未证实修复，需真机确认。
- **发布流程（内部）**：预检查改用可移植的 plist 读取（不再依赖 macOS `plutil`）；
  未签名设备工件在 dSYM 捕获之前先行留存；复用路径要求符号证据，重复的已接受上传
  会被拒绝；Feather 发布拒绝非 `-unsigned.ipa` 资产。

### 设备手动检查清单（精简）

1. Office：打开 docx/xlsx/pptx 副本；只读／受保护文档应停留在预览并说明原因；
   可编辑文档进入全屏编辑并保存重开；需要编辑密码时应出现输入提示。
2. 导入工作簿：打开带公式或多工作表图表的 pptx 副本并尝试保存；预期可能拒绝保存
   并保留原文件（不得静默丢数据）。
3. IDE 路由：分别从文件检查器、预览工具栏、文件树和 IDE 打开 `.swift`、`.xlsx`、
   `.pdf`、`.dxf`、`.png`、`.mp4`、`.zip`，确认进入正确工作面且代码编辑器不显示乱码。
4. IDE 标签：打开两个 Office 文档切换，嵌入预览后全屏编辑再返回；关闭有未保存
   修改的标签，确认询问保存／放弃。
5. 共享：分别分享本地文件与云端工作区文件，确认分享内容与屏幕一致。
6. Git：在测试仓库验证快进（工作树确实更新）、制造一次冲突并解决、放弃一条暂存
   修改，确认索引与文件都恢复且 `.git/floe-recovery` 留有副本。
7. 终端：在 IDE 底部打开终端，运行 `dash -i` 等交互命令并发送输入；关闭面板再
   打开确认会话仍在；运行一个不响应协作取消的长命令，确认显示 Busy／exit 75
   而不是超时。
8. 包：在 pnpm 项目中显式执行 `npm install`，确认使用 npm；取消 apt 安装确认立即
   停止且不执行。
9. 模型：禁用当前默认模型，确认自动选择另一个可用模型且新任务可以发送。
10. 视频：配置视频服务商后用 `video.models` 查看模型，提交一次带参考图的生成
    （会产生真实费用），确认任务持久、重放不重复、取消有效；GIF 检查与转换不需要
    云端费用。
11. 语言：确认 `apt install floe/lua` 可安装且 `lua` 别名可用；再 `apt install floe/ruby`（约 34.7 MB 下载）与 `apt install floe/php`，分别用 `ruby -e 'puts 1+1'` 和 `php -r 'echo 1+1;'` 验证；解释器启动超时可提高 `timeout` 或改用后台任务。安装失败时应给出明确错误。

### 已执行的验证（宿主级／夹具级，非 App 或真机证据）

FloeShellBridge 宿主 20/20；运行时聚焦 Swift 测试 10/10；传输中取消探针在 0.47 s
返回取消（URLSession 超时 30 s）；Python runner 13/13；Git 真实 libgit2 检查
71/71（两套工具链）与 21/21 不变量检查；媒体夹具 156/156（providers 89、
ownership 45、GIF 22）；语言兼容套件 12/12；capability-hub 27 项；签名目录与
本构建内置的 `Resources/Capabilities` 副本已用固定公钥验证（签名批次
35399070312）；发布流程 39 项（含 32 项新增复核）与 278 项既有回归检查；Office
原生宿主云端运行 `35373122891` 成功。App 目标编译、模拟器／真机 UI 与真实供应
商调用均未执行。

## English

- **Truthful Office editability**: an unknown or missing read-only flag is no
  longer treated as editable. Protected documents, read-only mounts and an
  engine-refused switch return to preview with a reason, and an edit password is
  requested instead of being treated as a denial. The new native host API
  (session read-only state, open-with-permission callback, permission observer,
  guarded edit entry) compiled and linked in cloud component run `35373122891`
  (commit `b494897c`); save/close/reopen and device editing remain pending.
- **Imported advanced workbooks**: only a Floe-generated chart workbook carrying
  the `floe-chart-data-<n>.xlsx` marker is regenerated. An imported workbook
  with multiple sheets, formulas or other embeddings is never silently
  rewritten: strict save validation **rejects the save and preserves the
  original file** instead of discarding content. Chart roundtrip on device is
  not yet qualified.
- **IDE routing and tabs**: every entry point routes a file to its own surface
  (Office editor, PDF reader, drawing viewer, image viewer, media workbench,
  Quick Look, code editor). The code workbench no longer receives Office or
  binary bytes, and reads and writes are typed and binary-checked (the native
  and web policies agree). The IDE gives code, Office and document files native
  tabs; an Office tab shares one working copy between its embedded preview and
  full-screen editing, and closing a tab with unsaved changes asks first.
- **Share**: file preview adds **Share** for the document currently on screen.
  Cloud/network files are snapshotted into a local temporary copy first, so the
  visible preview copy is untouched; low-frequency actions moved into a **More**
  menu.
- **Git**: fast-forward now actually moves HEAD and the working tree (it used to
  report success without changing anything); conflicted-path parsing and the
  conflict list are fixed; discarding a staged row now restores both index and
  working tree and keeps a recovery copy under `.git/floe-recovery`; staged and
  unstaged sections, staged diffs, merge-conflict editing and abort-merge were
  added. Destructive reset/clean, force-push and history rewriting remain
  unavailable.
- **Terminal and Shell**: the interactive session descriptor race is fixed
  (ownership is claimed before any descriptor work, and a failed claim cancels);
  the final output of an immediately exiting command is no longer dropped; the
  IDE bottom panel embeds the local terminal and reuses the app-lifetime
  session, so closing the panel does not end the shell; a busy engine returns
  exit 75 (notStarted) instead of pretending to be an execution timeout; a
  cancelled package command returns 130 without running.
- **Packages**: an explicit `npm install`/`pnpm install` always runs the manager
  you named; project locks and preferences only guide automatic selection. WASM
  capabilities carry per-entry module size, memory and timeout limits (defaults
  4 MiB/64 MiB/30 s; interpreter ceilings 64 MiB/1 GiB/600 s), and interpreter
  startup may need a longer `timeout` or a background job. Python's writable
  dependency path leads the managed baseline so the imported version matches the
  active environment.
- **Model fallback**: when the stored default or draft model is disabled,
  deleted or hidden, Floe repairs it in a fixed order (current selection →
  stored default → most recent run → first usable). A running request keeps its
  own model.
- **Video in ordinary chat**: `video.models`, `video.generate`, `video.status`
  and `video.cancel` list only enabled, adapter-backed models and accept one
  reference image (workspace path or conversation attachment; PNG/JPEG/WebP,
  ≤ 8 MiB, sent inline). Models without reference support reject the argument
  instead of ignoring it; a replayed tool call reuses the existing job (no
  double billing) while a new request creates a new job; cancellation wins over
  an in-flight submit, a cancelled download is never announced ready, and an
  expired result URL is reported truthfully. `video.inspect` reads real GIF
  frames, loop count and timing, and `gif(fps,width)` performs a real composite
  conversion resampled to a constant rate — a deterministic local conversion,
  not AI generation.
- **Local languages**: `floe/ruby` 3.4.1 (34,719,962 B) and `floe/php` 8.2.33
  (CLI SAPI, 4,077,891 B) are promoted into the signed catalog bundled by this
  build (signing run `capability-hub.yml` 35399070312 at revision `96be231e`;
  `FloeAgent/FloeApp/Resources/Capabilities` imports that signed copy). An
  `apt install floe/ruby` / `floe/php` downloads the signed artifact, verifies
  its digest and installs it app-wide; interpreter startup may exceed the shell
  default timeout, so raise `timeout` or use a background job. PHP 8.2 is the
  current security-maintenance release line (supported through 2026-12-31) and
  the 21 reviewed patches are replayed onto 8.2.33. Rust/C/C++/Go/Swift single
  files use the cloud-compile route and stay unsigned under `cloud-staging`.
  Device install and runtime acceptance remain yours.
- **Local models**: foreground admission and lifecycle cancellation prevent continued local GPU submission while inactive; cancellation is not a model failure. Scoped MLX error handling, GPU draining and diagnostics are strengthened. All 39 lifecycle and 15 diagnostic checks passed; the UIKit branch compiled to SIL/object. The build191 foreground Qwen GatedDeltaNet abort remains unproven fixed and needs device confirmation.
- **Release pipeline (internal)**: preflight now uses a portable plist read
  (no macOS `plutil`); the unsigned device artifact is retained before dSYM
  capture; reuse requires symbols evidence; a duplicate accepted upload is
  rejected; the Feather publish refuses any asset that is not the single
  `-unsigned.ipa`.

### Device manual-test checklist (compact)

1. Office: open docx/xlsx/pptx copies; a read-only or protected document must
   stay in preview with a reason, an editable one must enter full-screen editing
   and survive save/reopen, and an edit-password document must prompt.
2. Imported workbook: open a pptx copy with formula or multi-sheet charts and
   try to save; a rejected save that preserves the original file is expected —
   data must not be silently discarded.
3. IDE routing: open `.swift`, `.xlsx`, `.pdf`, `.dxf`, `.png`, `.mp4`, `.zip`
   from the inspector, preview toolbar, file tree and IDE; each must land in its
   own surface and the code editor must not show mojibake.
4. IDE tabs: open two Office documents, switch, edit full-screen from the
   embedded preview and return; closing a tab with unsaved changes must ask.
5. Share: share a local file and a cloud-workspace file; the shared content must
   match what is on screen.
6. Git: verify fast-forward actually updates the working tree, create and
   resolve a conflict, and discard a staged change; the index and files must be
   restored with a `.git/floe-recovery` copy.
7. Terminal: open the IDE bottom terminal, run an interactive command such as
   `dash -i` and send input; close and reopen the panel and confirm the session
   survives; run a command that ignores cooperative cancellation and confirm
   Busy/exit 75 rather than a timeout.
8. Packages: run an explicit `npm install` inside a pnpm project and confirm
   npm is used; cancel an apt install and confirm it stops immediately without
   running.
9. Models: disable the current default model and confirm a usable model is
   selected and a new task can send.
10. Video: with a provider configured, inspect `video.models`, submit one
    reference-image generation (real charges apply), and confirm durable
    tracking, no duplicate on replay and effective cancellation. GIF inspect and
    conversion are local and need no provider spend.
11. Languages: confirm `apt install floe/lua` installs and the `lua` alias
    works; then `apt install floe/ruby` (about 34.7 MB download) and
    `apt install floe/php`, and check `ruby -e 'puts 1+1'` and
    `php -r 'echo 1+1;'`. Raise `timeout` or use a background job if interpreter
    startup exceeds the default shell timeout. A failed install must report a
    clear error.

### Verification performed (host-level/fixture-level, not App or device evidence)

FloeShellBridge host 20/20; focused runtime Swift tests 10/10; in-flight
cancellation probe returned cancelled in 0.47 s against a 30 s URLSession
timeout; Python runner 13/13; real libgit2 Git checks 71/71 on two toolchains
plus 21/21 invariant checks; media fixtures 156/156 (providers 89, ownership 45,
GIF 22); language compatibility suite 12/12; capability-hub 27 tests; the signed
catalog and the `Resources/Capabilities` copy bundled by this build were verified
against the pinned public key (signing run 35399070312); release workflow 39
checks (including 32 new review tests) plus 278 existing regression tests; the
native Office host cloud run `35373122891` succeeded. No App-target compile,
simulator/device UI run, or paid provider call was performed.
