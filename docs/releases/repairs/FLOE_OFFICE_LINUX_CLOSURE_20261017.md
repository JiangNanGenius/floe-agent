# Office、手记与 Linux 执行修复 / Office, Notes and Linux execution repairs

Date: 2026-10-17. This is a source and qualification record, not a release announcement.

本轮保留现有正式审核版本；新测试版本须单独完成构建、上传及 Apple 状态核验。下列不同层级的验证不能互相替代。

The existing App Store review build remains unchanged. Any new beta requires its own build, upload and Apple status checks. The evidence levels below are distinct.

## Latest verified status / 最新验证状态（2026-10-18）

Actual Simulator App checks closed the earlier chart, ink, exit, attachment and Linux gates. Native PPT chart display now shows all five original bars after save/reopen; the native data dialog changed a category and value to `场地 QA` / `2100`, which persisted through the real PPTX chart and embedded workbook on reopen. The series case added `FLOE QA 新系列` with 101/202/303/404/505, saved and reopened with five distinct red values and the Chinese legend, then deleted the series and reopened back to the original five blue bars. The final typed run executed the series insert/delete/save/reopen case and the secondary-workbook typed comparison, with 0 failures, 0 skips and no native fatal markers. Primary inspection of the saved-copy reopen screenshots confirmed the data-edit, added and deleted states. The earlier two-case v3 phase remains a historical partial result because its series case failed; it is not a passed phase.

实际模拟器 App 已闭环此前的图表、笔迹、退出、附件及 Linux 检查：原生 PPT 图表保存重开后显示全部五根原始柱；原生数据对话框将类别及数值改为 `场地 QA` / `2100`，经真实 PPTX 图表及内嵌工作簿保存重开仍保留。系列用例新增 `FLOE QA 新系列` 及 101/202/303/404/505，保存重开后显示五个不同的红色数值及中文图例，随后删除该系列并重开，恢复原始五根蓝柱。最终类型化运行执行系列新增／删除／保存重开用例及第二工作簿类型化比较，0 失败、0 跳过，无原生致命标记；主协调对保存副本重开截图的实际检查确认了修改数据、新增及删除三种状态。较早的两用例 v3 阶段仍为历史部分结果，因其系列用例失败，不称该阶段通过。

The current native component was compiled from source `3e49c2cc`, strict canonical-v3 verified (4,785 files / 181 directories) with six exact members; archive-proof and packaging at `8ac97b3f` reused the same linked binary without recompilation. A full Simulator App built at `2b194756` passed the typed chart tests. The five-bar repair replaces the composition path's auxiliary tiny-layer read with an actual bitmap snapshot/crop; the host-only Core Graphics crop checks run on the host, not in the App. Chart-dialog decoded-Unicode JSON conversions now use UTF-8 instead of ASCII_US. The NotebookBar process-lifetime guard is iOS-only and leaves normal remove/erase unchanged. These are component and Simulator App results, not device, archive, signing, upload or release acceptance.

当前原生组件由源码 `3e49c2cc` 编译，六个成员来源与链接归属正确，严格 canonical-v3 校验通过（4,785 个文件／181 个目录）；`8ac97b3f` 的归档校验与打包复用同一已链接二进制，未重新编译。`2b194756` 的完整模拟器 App 通过类型化图表测试。五柱修复将合成路径原先读取辅助小图层改为实际位图快照／裁剪；仅宿主的 Core Graphics 裁剪检查只在宿主机运行，不在 App 内执行。图表对话框的已解码 Unicode JSON 转换改用 UTF-8，不再落到 ASCII_US；NotebookBar 进程生命周期保护仅作用于 iOS，正常 remove/erase 不变。以上为组件及模拟器 App 结果，不代表设备、归档、签名、上传或发布验收通过。

DOCX/XLSX/PPTX vector ink retained its colors and widths after save/reopen in all three formats, without the former native fatal exits. Later App runs also remained free of those exit failures. Six previously saved live-model Office outputs reopened with the newer component; no paid Office model calls were repeated. Manual Word attachment opening returned from the native editor to its original task and draft. HTML attachment → IDE → task-owned Linux service returned HTTP 200 with the exact 145-byte working file; stopping that service closed its listener without changing messages or starting a model run.

DOCX/XLSX/PPTX 三格式矢量笔迹的颜色、线宽及保存重开全部通过，未再出现原生致命退出；后续 App 执行也未复现原退出故障。六份已留存的真实模型 Office 文件在新组件中重开通过，未重复付费调用 Office 模型。手动 Word 附件经原生编辑器返回原任务及草稿；HTML 附件经 IDE 启动任务所属 Linux 服务，HTTP 200 正文与 145 字节工作文件完全一致，停止后监听关闭、消息未变，也未启动模型。

The actual Linux guest completed signed distribution-package installation, apt/dpkg audits, Pillow/lxml imports, ordinary pip installation of three pinned packages and the full eight-node recursive dependency closure. Generated DOCX, XLSX, PPTX and PNG files reopened successfully; the owned environment and working state were cleaned up. A real model answered `2+2=` with `4` through the ordinary composer. Navigating to Notes while waiting and returning did not restore the consumed draft; a new unsent draft survived. Temporary QA configuration was removed.

真实 Linux 来宾已完成签名发行版软件包安装、apt/dpkg 核验、Pillow/lxml 导入、三个固定版本包的普通 pip 安装及完整八节点递归依赖检查；实际生成 DOCX、XLSX、PPTX、PNG 并重开通过，所属环境及工作状态已清理。普通输入框经真实模型完成 `2+2=` → `4`；等待时切换手记再返回，已发送草稿未恢复，新未发送草稿保留，临时 QA 配置已清理。

The existing engine rewrites embedded-workbook default fonts, unused styles, empty A1 and calcPr on save. Value, type and formula checks are preserved, but byte or style identity is not claimed. Physical Pencil pressure, palm rejection and feel remain user acceptance. The delivery record below is separate from these component and Simulator results.

现有引擎在保存时会重写内嵌工作簿的默认字体、未使用样式、空 A1 及 calcPr；数值、类型及公式检查保留，但不声称字节或样式完全一致。实体 Pencil 的压感、掌拒及手感仍由用户验收。以下交付记录与上述组件及模拟器结果分开。

## Delivery and current Apple state / 交付与当前 Apple 状态（2026-10-18）

The 1.7.35 (276) candidate was built from exact source `06c7f2c833c524dca548821576e1542d76fa4406` (tag `v1.7.35`) with local Xcode 27.0 (27A266a), `iphoneos27.0`, Release, arm64 and minimum iOS 26.0. The unsigned transport ZIP is `bb062033446c404774ba93c00d068f6d721b90fb7834f329b9eb1c02200ac59f`, the raw App export is `fca4893981412cfeb1461eac01c3caeadc0f54358e23a429aa9a22ca7b44cf49`, and the signed IPA is `8d6d2d19976b71fa52506b0a69d53bad910700dfbcbd860ed61574540aa39851` (756,713,675 bytes); App/Office UUIDs are `EFE41A2D-5099-377D-9AA8-F6FD4024D19B` / `A44EC929-CF87-3678-900C-BFB2D0E73A18`. Signing/upload reused the exact artifact without rebuilding the App. Apple reports build `41557c7e-c971-473d-9242-6f602acadb9c` as `VALID`, unexpired and `APP_STORE_ELIGIBLE`, attached to the existing internal `Floe QA` group (`IN_BETA_TESTING`).

The primary submitted build 276 once to the existing external `publictest1` group. Independent GET-only inspect [run 39063023300](https://github.com/JiangNanGenius/floe-agent/actions/runs/39063023300) read back `WAITING_FOR_BETA_REVIEW`, `publictest1` attached, one submission in `pending_review`, and the prepared 1,359-byte review notes matching (SHA-256 `16f445546aaad6dffe4e7860a21559adfdb42bb65d3ac271457fec66e4d30332`; canonical comparison uses 1,358 characters). This is an external beta review submission, not approval or public availability. No further Apple write, submission or group change was made by this record.

1.7.35 (276) 候选版由精确源码 `06c7f2c833c524dca548821576e1542d76fa4406`（标签 `v1.7.35`）使用本地 Xcode 27.0 (27A266a)、`iphoneos27.0`、Release、arm64、最低 iOS 26.0 构建。未签名传输 ZIP 为 `bb062033446c404774ba93c00d068f6d721b90fb7834f329b9eb1c02200ac59f`，原始 App 导出为 `fca4893981412cfeb1461eac01c3caeadc0f54358e23a429aa9a22ca7b44cf49`，已签名 IPA 为 `8d6d2d19976b71fa52506b0a69d53bad910700dfbcbd860ed61574540aa39851`（756,713,675 字节）；App/Office UUID 为 `EFE41A2D-5099-377D-9AA8-F6FD4024D19B` / `A44EC929-CF87-3678-900C-BFB2D0E73A18`。签名和上传复用该精确产物，未重新构建 App。Apple 显示构建 `41557c7e-c971-473d-9242-6f602acadb9c` 为 `VALID`、未过期且 `APP_STORE_ELIGIBLE`，并已加入现有内部 `Floe QA` 组（`IN_BETA_TESTING`）。

主协调已向现有外部 `publictest1` 组提交构建 276 一次。独立只读检查（运行 [39063023300](https://github.com/JiangNanGenius/floe-agent/actions/runs/39063023300)）回读为 `WAITING_FOR_BETA_REVIEW`、已关联 `publictest1`、一份 `pending_review` 提交，且 1,359 字节审核备注与准备文本一致（SHA-256 `16f445546aaad6dffe4e7860a21559adfdb42bb65d3ac271457fec66e4d30332`；规范化比较为 1,358 个字符）。这是外部测试审核提交，不代表已批准或已公开；本记录之后未再写入、提交或更改测试组。

Earlier failures below are historical observations, superseded only where the latest status above records a completed check. Suites overlap and are not summed into a total.

下文原失败均为历史时点记录，已闭环项目以本节为准；各组测试有重叠，不合计总数。

## 已完成的修复 / Implemented repairs

- **输入框与草稿：** iPad 长输入换行和展开；发送接受后仅清除已消费的草稿版本，保留随后输入的文字及附件。覆盖视图重建、延迟启动及相同文字重新输入。
- **手记：** 保存回答时保留明确的 Markdown 格式及完整来源，编辑、分页、阅读、导出和 AI 修改共用文档状态；保留旧纯文本。荧光笔刷新不再依赖随后点击页面。
- **执行入口：** 模型代码统一使用任务所属 Linux 环境中的 `exec.shell`；耗时命令使用现有 jobs，网页服务使用现有 service/port 生命周期。旧的 App 内语言及重复包管理工具不再注册，旧任务不自动重放，不回退到宿主执行。
- **取消与清理：** 确认来宾命令组退出后再报告超时或取消，有界保留已捕获输出并脱敏；删除环境时清除该环境的残留工作区绑定，保留其他环境。
- **文件和预览：** 应用管理的设计文件使用明确归属及修订；首次读取保留实际源文件。HTML 从 IDE 接入已有静态网页服务，支持相对资源。
- **聊天附件：** 普通打开动作接入既有文件编辑器及 IDE，绑定原任务与具体附件；保留原件和已编辑副本。用户文件采用流式导入，模型写入大小限制保持不变。HTML 服务保留原任务归属；真实入口验收见最新状态。
- **Office：** 修复编辑器容器与键盘布局；实际转换器输出补齐中英文字体声明；原生笔输入、退出生命周期及五柱图表路径已修复。实际 App 的图表数据与系列修改→保存→重开通过并经主协调目视复核；内嵌工作簿格式不按字节保留。

- **Composer and drafts:** iPad wrapping and expansion; an accepted send clears only its consumed draft generation. Later text and attachments survive, including view reconstruction, delayed launch and retyping the same text.
- **Notes:** saved answers retain explicit Markdown and their full source. Editing, pagination, reading, export and AI changes share the document state; existing plain notes remain plain. Highlighter updates no longer require another tap.
- **Execution:** model code uses the task-owned Linux guest through `exec.shell`, existing jobs and service/port lifecycles. Retired in-App language and duplicate package tools are not registered or replayed. There is no host-execution fallback.
- **Cancellation and cleanup:** timeout/cancellation completion follows confirmed guest process-group termination. Captured output is bounded and sanitized. Environment removal clears its workspace bindings while preserving neighbours.
- **Files and preview:** app-managed design files carry explicit ownership and revision, with the actual initial source retained. IDE HTML preview uses the existing static service and relative assets.
- **Chat attachments:** ordinary opening reuses existing file editors and the IDE, bound to the original task and exact attachment. Originals and edited working copies remain intact. User imports stream from disk without relaxing model payload limits. HTML services retain task ownership; actual entry acceptance is recorded in the latest status above.
- **Office:** editor containment/keyboard layout and the actual converter's CJK font declarations are repaired. Native ink, exit lifetime and the five-bar chart path are repaired. Actual App chart data and series edit → save → reopen passed with primary visual review; embedded workbook formatting is not byte-preserved.

## 历史验证观察 / Earlier qualification observations（后续闭环前）

| 范围 / Scope | 实际证据 / Actual evidence |
| --- | --- |
| 模块 / Modules | Notes 74 checks; Linux execution 196 checks. A later focused original-source harness passed 8 timeout/cancellation XCTest cases and 4 registry Swift Testing cases, including Swift 6 object compilation on macOS. These are module results, not iPad results. |
| App 中 Linux / Linux in the App | Actual guest file/Python output and hash; parent plus two children sharing a guest with file/terminal/cancellation isolation; tool search and Skill discovery. Discovery used a scripted provider, not a live model. |
| 安装与超时 / Installation and timeout | Actual Simulator App installed a tiny local wheel through the production job service, independently imported it again, preserved stdout/stderr at a 5-second deadline, and confirmed the owned child exited without its delayed write. The owned guest and fixture were removed. This does not establish network package availability. |
| Skill 升级 / Skill upgrade | An existing unmodified 1.1.0 shell guide upgraded to 1.1.1. The actual App Skill read verified the current Linux instructions and persisted digest. Newer and user-edited content retains its existing protection. |
| 精确清理 / Owned cleanup | Production lifecycle removed one explicitly identified stopped qualification environment and its mapping; 139 other registry records remained. No broad registry or VM deletion was used. |
| 静态网页 / Static service | Actual App/guest HTTP responses for Chinese/spaced HTML paths and relative CSS; closing an observer keeps the service alive; explicit cancellation closes the forwarding port and removes the owned test environment. |
| App 和界面 / App and UI | Focused composer, Notes and ownership checks; iPad/iPhone wrapping and expansion; immediate highlighter visibility, undo/redo and cold reopen; Office keyboard container checks. |
| 真实模型 / Live model | Three actual configured-model scenarios passed: repeated Word edits plus a native table; Excel formula edits with saved numeric, zero and error results; presentation text/notes editing and slide duplication. Independent package reads retained formulas and native objects. The native process still failed at exit at that time, so the overall host gate was rejected then. |
| 笔迹 / Ink | Actual DOCX and XLSX input-bridge strokes retained distinct vector paths, two colors and widths after native save/reopen. Writer width dispatch now uses its actual core metric. The next component passed PPTX tool entry but saved no new vector paths; DOM dispatch counters do not prove core receipt. Physical Pencil is untested. |
| 图表 / Charts | Actual unedited native PPTX save/reopen retained chart data and embedded workbooks. A same-session native PDF contained all bars, while the editor bitmap still showed only the last bar. Edited-data and series operations were not accepted at that time. PDF is diagnostic evidence, not a substitute deliverable. |
| 组件恢复 / Component restoration | 45 focused checks passed for shared compiled-patch, source, platform and archive/member receipt validation. New device transport and pinning require this contract; historical Simulator receipts remain explicitly classified as legacy. These checks are not App or device acceptance. |
| 转换 / Conversion | Actual conversion tool → native Office rendering, after confirmed decoded tiles. Visual inspection found readable Chinese/Latin text and a bilingual table. An earlier blank capture was retained as a failed visual result. |

表中图表、原生退出及真实模型项目为历史观察；后续闭环情况以最新状态为准。各组可能重叠，不相加作为总测试数。模拟器笔迹不代表实体 Pencil 的压感、掌拒或手感通过。

Chart, native-exit and live-model items in this table are earlier observations; the latest status above records where they were later closed. Suites may overlap and are not summed into a total. Simulator strokes do not establish physical Pencil pressure, palm rejection or feel.

## 当前待完成 / Current remaining acceptance

- 构建 276 的外部测试版审核仍在等待；批准、拒绝、公开可用及任何 App Store 发布均为独立结果，本记录不作声明。现有 1.7.34 (275) App Store 审核版本及不可变标签保持不变。
- 实体 Pencil 压感、掌拒及手感由用户验收。本记录不代表最终设备、全模拟器或发布验收通过；不部署网站、不恢复跟进定时任务。

- External TestFlight beta review of build 276 is pending; approval, rejection, public availability and any App Store release remain separate outcomes and are not claimed here. The existing 1.7.34 (275) App Store review build and immutable tag remain unchanged.
- Physical Pencil pressure, palm rejection and feel remain user acceptance. This record does not claim final device, all-Simulator or release acceptance; no website deployment or follow-up timer is included.

## 原失败与当时待验收项 / Historical failures and pending checks

以下为闭环前观察，作为历史保留；后续图表、笔迹及原生退出结果以最新状态为准。

These are pre-closure observations retained as history; later chart, ink and native-exit results are recorded in the latest status above.

- 匹配后续修复的原生组件当时仍需构建。已完成编译、链接和严格校验的新模拟器组件，在真实 App 测试结束时仍出现原生 mutex 异常，保留为失败，不能用 Xcode 的成功退出码忽略。
- 实际调试在首次异常处确认调用来自线程登记服务；该诊断已收窄退出生命周期调查范围，但不是修复或正常验收通过。
- 三格式笔迹需实际经输入桥接保存为矢量、核对颜色与线宽并重开。图表需检查五类别实际显示、未编辑保存以及修改数据后保存重开；保持原有保存保护，不用图片、形状或旧工作簿替代真实编辑。
- 真实配置模型的 Word／Excel／PPT 典型用例及离线 pip、超时子进程、精确环境清理已在实际 App 中通过。原生退出故障当时仍单独阻止整体验收。
- 分阶段网络诊断在联网前因冷启动 pip 超出 30 秒而停止，保留了部分输出并完成所属环境清理；尚未验证 DNS、TLS、索引或三包网络安装。已准备区分冷启动与网络操作的后续诊断，不能据此归因为网络或内核故障。
- 实际聊天入口检查发现附件仅显示名称，已补齐普通打开动作源码和定向测试；新 App 当时尚待对象构建及运行。聊天键盘到 Office 附件、HTML IDE 预览、实体设备和物理 Pencil 当时仍分别验收，其他入口或模块测试不替代它们。

The compiled, linked and strictly verified Simulator component still produced an exit-time mutex exception; it remains a failure regardless of Xcode's command result. An actual first-throw debugger capture identified the thread registry call path, narrowing the teardown investigation without establishing a repair. DOCX/XLSX vector strokes and the three live-model Office cases passed their assertions. PPTX tool entry progressed, but its saved output contained no new strokes. Unedited native chart save/reopen passed; bitmap rendering and edited-data roundtrips remained open at that time. The staged network probe stopped during cold pip startup before any network operation; the original installation stall is not diagnosed from that result. Ordinary attachment opening and focused tests were implemented after actual UI inspection found passive labels; object compilation and actual App execution were pending at that time. Exact chat-to-Office and HTML IDE entry, physical devices and physical Pencil acceptance remain separate.

## 源码检查点 / Source checkpoints

- `52d47f42`: primary implementation checkpoint.
- `aef0f344`: bounded timeout output after reaping and stale environment-binding cleanup.
- `a6d0cd41`: current Linux documentation separated from historical native execution descriptions.
- `07536493`: native Office and Linux lifecycle qualification sources; later test observations and lazy-registry preparation are tracked separately.
- `939eaa49`: versioned upgrade of the unchanged bundled shell guide to Linux instructions.
- `f533e3d9`: hosted qualification joins the actual App environment; attachment fixtures carry canonical workspace ownership.
- `8809e628`: foreign-bitmap readback for chart composition; original five-bar render and three-format ink save/reopen passed in the Simulator App.
- `3e49c2cc`: chart-dialog UTF-8 edit preservation and NotebookBar process-lifetime repair; source of the current native component.
- `8ac97b3f`: archive-proof and packaging for the already linked native binary, without recompilation or relinking.
- `2b194756`: typed numeric cell comparison for the secondary chart workbook; qualification-only.

No new beta upload or installability is asserted by these source checkpoints.

## 历史后续本地检查 / Earlier subsequent local checks（后续闭环前）

- 新的完整 App 已通过本地 Xcode 27 对象构建。Word、Excel 各两笔的颜色、线宽、保存及重开检查通过；PPT 未保存新增笔迹，当时仍在修复。
- 先前真实模型生成的六份 Office 文件在新组件中重开检查通过，未重复调用模型。图表文件的数据保留与图表显示分开判断：原生页面当时仍只显示最后一根柱，尚未通过显示验收。
- 已捕获退出异常的真实调用栈，定位到 Office 轮询注册表的锁；即使测试断言通过，出现该异常的执行也不计为整轮通过。原始失败和后续修复分别留存。
- 真实 Linux 网络检查已通过解释器启动、DNS、TLS、索引以及三个固定版本主包的下载；依赖安装因目标平台缺少 Pillow 二进制包而停止。未以本地合成包或放宽断言替代真实安装。
- 本轮六个合成 Office 检查目录已逐文件核对导出副本后清理；其他文档和环境保持不变。新测试版尚未上传。

- The new full App passed a local Xcode 27 object build. Two-stroke colour, width, save and reopen checks passed for Word and Excel. PPT did not retain its new strokes and remained under repair at that time.
- Six previously generated live-model Office outputs reopened in the new component without another model call. Chart data preservation is distinct from display acceptance: the native page still displayed only its last bar at that time.
- A captured termination stack identifies the Office polling registry mutex. A run with that termination is not accepted merely because its test assertions pass. Original failures remain separate from later fixes.
- Actual guest checks passed interpreter startup, DNS, TLS, index access and downloads of the three pinned primary packages. Dependency installation stopped because the target platform has no compatible Pillow binary package. Synthetic packages and weakened assertions do not substitute for this installation.
- Six owned synthetic Office fixture directories were removed after per-file export verification. Other documents and environments were preserved. No new beta has been uploaded.

## 历史分项集成检查 / Earlier bounded integration checks（后续闭环前）

- 新原生组件已完成本地编译、链接、产物留存和严格校验，随后完整 App 对象构建通过。
- 同一模拟器 App 执行中，Word、Excel 笔迹保存重开通过，未再检测到此前的退出异常；PPT 笔迹和图表前四根柱当时仍失败，整体验收当时未通过。两项按独立故障继续处理。
- 附件身份、原任务归属、编辑副本、越界路径和导入上限的五项实际 App 测试全部通过。手动聊天入口和网页服务当时仍需单独验收。
- 任务已拆为限定补丁、独立复核、组件构建及主协调集成；云端 CI 不作为本轮等待门槛。未上传新的测试版。

- The new native component was locally compiled, linked, retained and strictly verified, followed by a successful full App object build.
- In the same Simulator App run, Word and Excel ink save/reopen passed without the previous termination markers. PPT ink and the first four chart bars still failed at that time; overall acceptance remained open then. They were investigated as separate defects.
- All five actual App checks for attachment identity, task ownership, edited copies, unsafe paths and import limits passed. Manual chat entry and web-service acceptance remained separate at that time.
- Work is split into bounded patches, independent review, component building and primary integration. Cloud CI is supplementary, not a waiting gate. No new beta has been uploaded.
