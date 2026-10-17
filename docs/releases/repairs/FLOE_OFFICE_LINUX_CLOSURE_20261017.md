# Office、手记与 Linux 执行修复 / Office, Notes and Linux execution repairs

Date: 2026-10-17. This is a source and qualification record, not a release announcement.

本轮保留现有正式审核版本；新测试版本须单独完成构建、上传及 Apple 状态核验。下列不同层级的验证不能互相替代。

The existing App Store review build remains unchanged. Any new beta requires its own build, upload and Apple status checks. The evidence levels below are distinct.

## 已完成的修复 / Implemented repairs

- **输入框与草稿：** iPad 长输入换行和展开；发送接受后仅清除已消费的草稿版本，保留随后输入的文字及附件。覆盖视图重建、延迟启动及相同文字重新输入。
- **手记：** 保存回答时保留明确的 Markdown 格式及完整来源，编辑、分页、阅读、导出和 AI 修改共用文档状态；保留旧纯文本。荧光笔刷新不再依赖随后点击页面。
- **执行入口：** 模型代码统一使用任务所属 Linux 环境中的 `exec.shell`；耗时命令使用现有 jobs，网页服务使用现有 service/port 生命周期。旧的 App 内语言及重复包管理工具不再注册，旧任务不自动重放，不回退到宿主执行。
- **取消与清理：** 确认来宾命令组退出后再报告超时或取消，有界保留已捕获输出并脱敏；删除环境时清除该环境的残留工作区绑定，保留其他环境。
- **文件和预览：** 应用管理的设计文件使用明确归属及修订；首次读取保留实际源文件。HTML 从 IDE 接入已有静态网页服务，支持相对资源。
- **聊天附件：** 普通打开动作接入既有文件编辑器及 IDE，绑定原任务与具体附件；保留原件和已编辑副本。用户文件采用流式导入，模型写入大小限制保持不变。HTML 服务保留原任务归属；真实入口验收待下节完成。
- **Office：** 修复编辑器容器与键盘布局；实际转换器输出补齐中英文字体声明。原生笔输入、图表和退出生命周期的最终验收仍见下节。

- **Composer and drafts:** iPad wrapping and expansion; an accepted send clears only its consumed draft generation. Later text and attachments survive, including view reconstruction, delayed launch and retyping the same text.
- **Notes:** saved answers retain explicit Markdown and their full source. Editing, pagination, reading, export and AI changes share the document state; existing plain notes remain plain. Highlighter updates no longer require another tap.
- **Execution:** model code uses the task-owned Linux guest through `exec.shell`, existing jobs and service/port lifecycles. Retired in-App language and duplicate package tools are not registered or replayed. There is no host-execution fallback.
- **Cancellation and cleanup:** timeout/cancellation completion follows confirmed guest process-group termination. Captured output is bounded and sanitized. Environment removal clears its workspace bindings while preserving neighbours.
- **Files and preview:** app-managed design files carry explicit ownership and revision, with the actual initial source retained. IDE HTML preview uses the existing static service and relative assets.
- **Chat attachments:** ordinary opening reuses existing file editors and the IDE, bound to the original task and exact attachment. Originals and edited working copies remain intact. User imports stream from disk without relaxing model payload limits. HTML services retain task ownership; actual entry acceptance remains pending below.
- **Office:** editor containment/keyboard layout and the actual converter's CJK font declarations are repaired. Final native drawing, chart and teardown acceptance remains pending below.

## 已观察的验证 / Observed qualification

| 范围 / Scope | 实际证据 / Actual evidence |
| --- | --- |
| 模块 / Modules | Notes 74 checks; Linux execution 196 checks. A later focused original-source harness passed 8 timeout/cancellation XCTest cases and 4 registry Swift Testing cases, including Swift 6 object compilation on macOS. These are module results, not iPad results. |
| App 中 Linux / Linux in the App | Actual guest file/Python output and hash; parent plus two children sharing a guest with file/terminal/cancellation isolation; tool search and Skill discovery. Discovery used a scripted provider, not a live model. |
| 安装与超时 / Installation and timeout | Actual Simulator App installed a tiny local wheel through the production job service, independently imported it again, preserved stdout/stderr at a 5-second deadline, and confirmed the owned child exited without its delayed write. The owned guest and fixture were removed. This does not establish network package availability. |
| Skill 升级 / Skill upgrade | An existing unmodified 1.1.0 shell guide upgraded to 1.1.1. The actual App Skill read verified the current Linux instructions and persisted digest. Newer and user-edited content retains its existing protection. |
| 精确清理 / Owned cleanup | Production lifecycle removed one explicitly identified stopped qualification environment and its mapping; 139 other registry records remained. No broad registry or VM deletion was used. |
| 静态网页 / Static service | Actual App/guest HTTP responses for Chinese/spaced HTML paths and relative CSS; closing an observer keeps the service alive; explicit cancellation closes the forwarding port and removes the owned test environment. |
| App 和界面 / App and UI | Focused composer, Notes and ownership checks; iPad/iPhone wrapping and expansion; immediate highlighter visibility, undo/redo and cold reopen; Office keyboard container checks. |
| 真实模型 / Live model | Three actual configured-model scenarios passed: repeated Word edits plus a native table; Excel formula edits with saved numeric, zero and error results; presentation text/notes editing and slide duplication. Independent package reads retained formulas and native objects. The native process still failed at exit, so the overall host gate remains rejected. |
| 笔迹 / Ink | Actual DOCX and XLSX input-bridge strokes retained distinct vector paths, two colors and widths after native save/reopen. Writer width dispatch now uses its actual core metric. The next component passed PPTX tool entry but saved no new vector paths; DOM dispatch counters do not prove core receipt. Physical Pencil is untested. |
| 图表 / Charts | Actual unedited native PPTX save/reopen retained chart data and embedded workbooks. A same-session native PDF contained all bars, while the editor bitmap still showed only the last bar. Edited-data and series operations are not yet accepted. PDF is diagnostic evidence, not a substitute deliverable. |
| 组件恢复 / Component restoration | 45 focused checks passed for shared compiled-patch, source, platform and archive/member receipt validation. New device transport and pinning require this contract; historical Simulator receipts remain explicitly classified as legacy. These checks are not App or device acceptance. |
| 转换 / Conversion | Actual conversion tool → native Office rendering, after confirmed decoded tiles. Visual inspection found readable Chinese/Latin text and a bilingual table. An earlier blank capture was retained as a failed visual result. |

各组可能重叠，不相加作为总测试数。模拟器笔迹不代表实体 Pencil 的压感、掌拒或手感通过。

Suites may overlap and are not summed into a total. Simulator strokes do not establish physical Pencil pressure, palm rejection or feel.

## 尚未闭环 / Remaining acceptance

- 匹配后续修复的原生组件仍需构建。已完成编译、链接和严格校验的新模拟器组件，在真实 App 测试结束时仍出现原生 mutex 异常，保留为失败，不能用 Xcode 的成功退出码忽略。
- 实际调试在首次异常处确认调用来自线程登记服务；该诊断已收窄退出生命周期调查范围，但不是修复或正常验收通过。
- 三格式笔迹需实际经输入桥接保存为矢量、核对颜色与线宽并重开。图表需检查五类别实际显示、未编辑保存以及修改数据后保存重开；保持原有保存保护，不用图片、形状或旧工作簿替代真实编辑。
- 真实配置模型的 Word／Excel／PPT 典型用例及离线 pip、超时子进程、精确环境清理已在实际 App 中通过。原生退出故障仍单独阻止整体验收。
- 分阶段网络诊断在联网前因冷启动 pip 超出 30 秒而停止，保留了部分输出并完成所属环境清理；尚未验证 DNS、TLS、索引或三包网络安装。已准备区分冷启动与网络操作的后续诊断，不能据此归因为网络或内核故障。
- 实际聊天入口检查发现附件仅显示名称，已补齐普通打开动作源码和定向测试；新 App 尚待对象构建及运行。聊天键盘到 Office 附件、HTML IDE 预览、实体设备和物理 Pencil 仍分别验收，其他入口或模块测试不替代它们。

The compiled, linked and strictly verified Simulator component still produced an exit-time mutex exception; it remains a failure regardless of Xcode's command result. An actual first-throw debugger capture identified the thread registry call path, narrowing the teardown investigation without establishing a repair. DOCX/XLSX vector strokes and the three live-model Office cases passed their assertions. PPTX tool entry progressed, but its saved output contained no new strokes. Unedited native chart save/reopen passed; bitmap rendering and edited-data roundtrips remain open. The staged network probe stopped during cold pip startup before any network operation; the original installation stall is not diagnosed from that result. Ordinary attachment opening and focused tests are implemented after actual UI inspection found passive labels; object compilation and actual App execution are pending. Exact chat-to-Office and HTML IDE entry, physical devices and physical Pencil acceptance remain separate.

## 源码检查点 / Source checkpoints

- `52d47f42`: primary implementation checkpoint.
- `aef0f344`: bounded timeout output after reaping and stale environment-binding cleanup.
- `a6d0cd41`: current Linux documentation separated from historical native execution descriptions.
- `07536493`: native Office and Linux lifecycle qualification sources; later test observations and lazy-registry preparation are tracked separately.
- `939eaa49`: versioned upgrade of the unchanged bundled shell guide to Linux instructions.
- `f533e3d9`: hosted qualification joins the actual App environment; attachment fixtures carry canonical workspace ownership.

No new beta upload or installability is asserted by these source checkpoints.

## 后续本地检查 / Subsequent local checks

- 新的完整 App 已通过本地 Xcode 27 对象构建。Word、Excel 各两笔的颜色、线宽、保存及重开检查通过；PPT 未保存新增笔迹，仍在修复。
- 先前真实模型生成的六份 Office 文件在新组件中重开检查通过，未重复调用模型。图表文件的数据保留与图表显示分开判断：原生页面仍只显示最后一根柱，尚未通过显示验收。
- 已捕获退出异常的真实调用栈，定位到 Office 轮询注册表的锁；即使测试断言通过，出现该异常的执行也不计为整轮通过。原始失败和后续修复分别留存。
- 真实 Linux 网络检查已通过解释器启动、DNS、TLS、索引以及三个固定版本主包的下载；依赖安装因目标平台缺少 Pillow 二进制包而停止。未以本地合成包或放宽断言替代真实安装。
- 本轮六个合成 Office 检查目录已逐文件核对导出副本后清理；其他文档和环境保持不变。新测试版尚未上传。

- The new full App passed a local Xcode 27 object build. Two-stroke colour, width, save and reopen checks passed for Word and Excel. PPT did not retain its new strokes and remains under repair.
- Six previously generated live-model Office outputs reopened in the new component without another model call. Chart data preservation is distinct from display acceptance: the native page still displays only its last bar.
- A captured termination stack identifies the Office polling registry mutex. A run with that termination is not accepted merely because its test assertions pass. Original failures remain separate from later fixes.
- Actual guest checks passed interpreter startup, DNS, TLS, index access and downloads of the three pinned primary packages. Dependency installation stopped because the target platform has no compatible Pillow binary package. Synthetic packages and weakened assertions do not substitute for this installation.
- Six owned synthetic Office fixture directories were removed after per-file export verification. Other documents and environments were preserved. No new beta has been uploaded.
