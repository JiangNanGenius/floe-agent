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
- **Office：** 修复编辑器容器与键盘布局；实际转换器输出补齐中英文字体声明。原生笔输入、图表和退出生命周期的最终验收仍见下节。

- **Composer and drafts:** iPad wrapping and expansion; an accepted send clears only its consumed draft generation. Later text and attachments survive, including view reconstruction, delayed launch and retyping the same text.
- **Notes:** saved answers retain explicit Markdown and their full source. Editing, pagination, reading, export and AI changes share the document state; existing plain notes remain plain. Highlighter updates no longer require another tap.
- **Execution:** model code uses the task-owned Linux guest through `exec.shell`, existing jobs and service/port lifecycles. Retired in-App language and duplicate package tools are not registered or replayed. There is no host-execution fallback.
- **Cancellation and cleanup:** timeout/cancellation completion follows confirmed guest process-group termination. Captured output is bounded and sanitized. Environment removal clears its workspace bindings while preserving neighbours.
- **Files and preview:** app-managed design files carry explicit ownership and revision, with the actual initial source retained. IDE HTML preview uses the existing static service and relative assets.
- **Office:** editor containment/keyboard layout and the actual converter's CJK font declarations are repaired. Final native drawing, chart and teardown acceptance remains pending below.

## 已观察的验证 / Observed qualification

| 范围 / Scope | 实际证据 / Actual evidence |
| --- | --- |
| 模块 / Modules | Notes 74 checks; Linux execution 196 checks. A later focused original-source harness passed 8 timeout/cancellation XCTest cases and 4 registry Swift Testing cases, including Swift 6 object compilation on macOS. These are module results, not iPad results. |
| App 中 Linux / Linux in the App | Actual guest file/Python output and hash; parent plus two children sharing a guest with file/terminal/cancellation isolation; tool search and Skill discovery. Discovery used a scripted provider, not a live model. |
| 安装与超时 / Installation and timeout | Actual Simulator App installed a tiny local wheel through the production job service, independently imported it again, preserved stdout/stderr at a 5-second deadline, and confirmed the owned child exited without its delayed write. The owned guest and fixture were removed. This does not establish network package availability. |
| 精确清理 / Owned cleanup | Production lifecycle removed one explicitly identified stopped qualification environment and its mapping; 139 other registry records remained. No broad registry or VM deletion was used. |
| 静态网页 / Static service | Actual App/guest HTTP responses for Chinese/spaced HTML paths and relative CSS; closing an observer keeps the service alive; explicit cancellation closes the forwarding port and removes the owned test environment. |
| App 和界面 / App and UI | Focused composer, Notes and ownership checks; iPad/iPhone wrapping and expansion; immediate highlighter visibility, undo/redo and cold reopen; Office keyboard container checks. |
| 真实模型 / Live model | Three actual configured-model scenarios passed: repeated Word edits plus a native table; Excel formula edits with saved numeric, zero and error results; presentation text/notes editing and slide duplication. Independent package reads retained formulas and native objects. The native process still failed at exit, so the overall host gate remains rejected. |
| 笔迹 / Ink | Actual DOCX and XLSX input-bridge strokes retained distinct vector paths, two colors and widths after native save/reopen. Writer width dispatch now uses its actual core metric. PPTX remains blocked before its first stroke by the old engine default-object path. Physical Pencil is untested. |
| 转换 / Conversion | Actual conversion tool → native Office rendering, after confirmed decoded tiles. Visual inspection found readable Chinese/Latin text and a bilingual table. An earlier blank capture was retained as a failed visual result. |

各组可能重叠，不相加作为总测试数。模拟器笔迹不代表实体 Pencil 的压感、掌拒或手感通过。

Suites may overlap and are not summed into a total. Simulator strokes do not establish physical Pencil pressure, palm rejection or feel.

## 尚未闭环 / Remaining acceptance

- 匹配当前源码的原生组件仍在重建。新模拟器组件的真实测试结束时仍出现原生 mutex 异常保留为失败，不能用 Xcode 的成功退出码忽略。
- 三格式笔迹需实际经输入桥接保存为矢量、核对颜色与线宽并重开。图表需检查五类别实际显示、未编辑保存以及修改数据后保存重开；保持原有保存保护，不用图片、形状或旧工作簿替代真实编辑。
- 真实配置模型的 Word／Excel／PPT 典型用例及离线 pip、超时子进程、精确环境清理已在实际 App 中通过。原生退出故障仍单独阻止整体验收。
- 原三包网络安装超时的具体下载或包源原因未证实；120 秒前台上限与后台有效超时是已区分的行为，不能据此归因为内核故障。
- 聊天键盘到 Office 附件的具体入口、实体设备和物理 Pencil 仍单独记录；其他入口或模块测试不替代它们。

The matching native components are still being rebuilt. The new Simulator component still produced an exit-time mutex exception; it remains a failure regardless of Xcode's command result. DOCX/XLSX vector strokes and the three live-model Office cases passed their assertions, while the native exit gate remains rejected. PPTX drawing, chart rendering and edited-data roundtrips still require successful qualification. App offline pip/process cleanup and exact owned-environment cleanup have passed. Existing save protections remain. The original network package-install stall is not diagnosed from its timeout alone. Exact chat-to-Office entry, physical devices and physical Pencil acceptance remain separate.

## 源码检查点 / Source checkpoints

- `52d47f42`: primary implementation checkpoint.
- `aef0f344`: bounded timeout output after reaping and stale environment-binding cleanup.
- `a6d0cd41`: current Linux documentation separated from historical native execution descriptions.
- `07536493`: native Office and Linux lifecycle qualification sources; later test observations and lazy-registry preparation are tracked separately.

No new beta upload or installability is asserted by these source checkpoints.
