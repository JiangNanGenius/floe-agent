# Office, Notes and Linux execution qualification / 验证记录

Status: implementation and local Simulator qualification closed for the Office, Notes and Linux defects; device packaging and distribution acceptance remain pending. This is not a release, TestFlight or physical-device acceptance record.
状态：Office、手记与 Linux 缺陷的实现及本地模拟器验证已闭环；设备打包与分发验收仍待完成。本记录不代表已发布、已上测试或实机验收通过。

## Latest verified status / 最新验证状态（2026-10-18）

Actual Simulator App checks closed the earlier chart, ink, exit, attachment and Linux gates. Native PPT chart display now shows all five original bars after save/reopen; the native data dialog changed a category and value to `场地 QA` / `2100`, which persisted through the real PPTX chart and embedded workbook on reopen. The series case added `FLOE QA 新系列` with 101/202/303/404/505, saved and reopened with five distinct red values and the Chinese legend, then deleted the series and reopened back to the original five blue bars. The final typed run executed the series insert/delete/save/reopen case and the secondary-workbook typed comparison, with 0 failures, 0 skips and no native fatal markers. Primary inspection of the saved-copy reopen screenshots confirmed the data-edit, added and deleted states. The earlier two-case v3 phase remains a historical partial result because its series case failed; it is not a passed phase.

实际模拟器 App 已闭环此前的图表、笔迹、退出、附件及 Linux 检查：原生 PPT 图表保存重开后显示全部五根原始柱；原生数据对话框将类别及数值改为 `场地 QA` / `2100`，经真实 PPTX 图表及内嵌工作簿保存重开仍保留。系列用例新增 `FLOE QA 新系列` 及 101/202/303/404/505，保存重开后显示五个不同的红色数值及中文图例，随后删除该系列并重开，恢复原始五根蓝柱。最终类型化运行执行系列新增／删除／保存重开用例及第二工作簿类型化比较，0 失败、0 跳过，无原生致命标记；主协调对保存副本重开截图的实际检查确认了修改数据、新增及删除三种状态。较早的两用例 v3 阶段仍为历史部分结果，因其系列用例失败，不称该阶段通过。

DOCX/XLSX/PPTX vector ink retained its colors and widths after save/reopen in all three formats, without the former native fatal exits. Later App runs also remained free of those exit failures. Six previously saved live-model Office outputs reopened with the newer component; no paid Office model calls were repeated. Manual Word attachment opening returned from the native editor to its original task and draft. HTML attachment → IDE → task-owned Linux service returned HTTP 200 with the exact 145-byte working file; stopping that service closed its listener without changing messages or starting a model run.

DOCX/XLSX/PPTX 三格式矢量笔迹的颜色、线宽及保存重开全部通过，未再出现原生致命退出；后续 App 执行也未复现原退出故障。六份已留存的真实模型 Office 文件在新组件中重开通过，未重复付费调用 Office 模型。手动 Word 附件经原生编辑器返回原任务及草稿；HTML 附件经 IDE 启动任务所属 Linux 服务，HTTP 200 正文与 145 字节工作文件完全一致，停止后监听关闭、消息未变，也未启动模型。

The current native component was compiled from source `3e49c2cc`, strict canonical-v3 verified (4,785 files / 181 directories) with six exact members; archive-proof and packaging at `8ac97b3f` reused the same linked binary without recompiling or relinking it. A full Simulator App built at `2b194756` with this component passed the typed chart tests. The five-bar display repair takes an actual bitmap snapshot/crop instead of reading an auxiliary tiny layer; chart-dialog UTF-8 and NotebookBar lifetime repairs are also in this source line. These are component and Simulator App results, not device, archive, signing, upload or release acceptance.

当前原生组件由源码 `3e49c2cc` 编译，六个成员来源与链接归属正确，严格 canonical-v3 校验通过（4,785 个文件／181 个目录）；`8ac97b3f` 的归档校验与打包复用同一已链接二进制，未重新编译或链接。`2b194756` 的完整模拟器 App 使用该组件并通过类型化图表测试。五柱显示修复改用实际位图快照／裁剪，不再读取辅助小图层；图表对话框 UTF-8 及 NotebookBar 生命周期修复也在同一源码线。以上为组件及模拟器 App 结果，不代表设备、归档、签名、上传或发布验收通过。

The actual Linux guest completed signed distribution-package installation, apt/dpkg audits, Pillow/lxml imports, ordinary pip installation of three pinned packages and the full eight-node recursive dependency closure. Generated DOCX, XLSX, PPTX and PNG files reopened successfully; the owned environment and working state were cleaned up. A real model answered `2+2=` with `4` through the ordinary composer. Navigating to Notes while waiting and returning did not restore the consumed draft; a new unsent draft survived. Temporary QA configuration was removed.

真实 Linux 来宾已完成签名发行版软件包安装、apt/dpkg 核验、Pillow/lxml 导入、三个固定版本包的普通 pip 安装及完整八节点递归依赖检查；实际生成 DOCX、XLSX、PPTX、PNG 并重开通过，所属环境及工作状态已清理。普通输入框经真实模型完成 `2+2=` → `4`；等待时切换手记再返回，已发送草稿未恢复，新未发送草稿保留，临时 QA 配置已清理。

The chart result is bounded by the existing engine's save behavior: embedded workbooks rewrite default fonts, unused styles, empty A1 and calcPr. Value, type and formula checks are preserved, but byte or style identity is not claimed. Physical Pencil pressure, palm rejection and feel remain user acceptance. No device, archive, upload, TestFlight or App Store result is claimed here.

图表结果限于现有引擎的实际保存行为：内嵌工作簿会重写默认字体、未使用样式、空 A1 及 calcPr；数值、类型及公式检查保留，但不声称字节或样式完全一致。实体 Pencil 的压感、掌拒及手感仍由用户验收。本记录不声称设备、归档、上传、测试版或 App Store 结果。

Earlier failures below are historical observations, superseded only where the latest status above records a completed check. Suites overlap and are not summed into a total.

下文原失败均为历史时点记录，已闭环项目以本节为准；各组测试有重叠，不合计总数。

## Scope / 范围

- Office Pencil, chart preservation and converted DOCX East Asian text; keyboard handoff without recreating editor sessions.
- iPad multiline composer, launch-time draft ownership, editable Markdown Notes and immediate ink refresh.
- Task-owned Linux execution, static HTML preview and managed private-workspace design source binding.
- Office 笔迹、图表保留、转换后中文字体，以及保持编辑会话的键盘布局修复。
- iPad 多行输入、发送草稿归属、可编辑 Markdown 手记与笔迹即时显示。
- 任务所属 Linux 执行、静态网页预览与私有工作区设计源文件绑定。

## Execution contract / 执行契约

Model code runs through `exec.shell` in the resolved task-owned Linux environment. Python, Node and package installation use ordinary guest commands. The retired `exec.localPython`, `exec.javascript`, `exec.compatEvaluator`, raw `exec.wasm`, `python.packages` and `wasm.packages` names cannot be registered or discovered, including their historical wire spellings. Historical records remain readable; outstanding retired jobs are not replayed. Internal business processors still referenced by document/media features remain intact. No old approval fingerprint authorizes a different shell command.

模型代码统一通过任务所属 Linux 环境的 `exec.shell` 执行；Python、Node 和安装包使用来宾命令。六个退役工具及其历史名称不再注册或发现；历史记录可读，旧任务不自动重放。文档与媒体仍引用的内部处理服务继续保留，旧审批记录不能授权新的 Shell 命令。

## Earlier qualification observations / 历史验证记录（后续闭环前）

Toolchain: local Xcode 27, arm64 iOS 27 Simulator, Swift 6 object compilation. Full App test-build succeeds. A failed generic dual-architecture build exposed unavailable x86_64 CAD symbols; qualification uses the host-supported arm64 architecture. Original failures are retained.

工具链：本地 Xcode 27、arm64 iOS 27 模拟器、Swift 6 对象编译；完整 App 测试构建通过。初次双架构构建缺少 x86_64 CAD 符号，后续按宿主实际架构验证，保留原失败。

| Area / 项目 | Actual evidence / 实际证据 |
| --- | --- |
| Notes | 74 module tests; 7 App Markdown tests covering saved source, pagination and AI replacement; 5 ink-refresh App tests passed. / 模块及 App 测试通过，覆盖保存、分页、AI 修改和笔迹刷新。 |
| Composer and source binding | App tests passed after fixing UIKit lazy-font measurement and canonical private-root comparison. Launch acceptance/failure and replacement drafts use controlled continuation gates. / 修复实际 iOS 字体测量和路径比较后通过；发送归属使用可控异步测试。 |
| Execution | 196 module checks; 4 additional registry/security tests; 13 audit-script checks passed. Overlapping App regressions are not counted as additional unique coverage. / 模块、注册审批与审计通过；重叠回归不重复计数。 |
| Real Linux child execution | One App test passed: child shell write, guest Python stdin read/hash/platform, recursive delegation denied. / 实际子代理执行、文件哈希及禁止再次委派验证通过。 |
| Concurrent Linux clients | One App test passed: parent and two children share a guest, including terminal and cancellation isolation. / 主任务与两个子代理共享来宾并发及取消隔离通过。 |
| Child discovery | One App test passed: full catalog → tools.search → skill.read → real Linux artifact. Provider responses are scripted; guest execution is real. / 工具与 Skill 发现及真实来宾产物通过；供应商响应为脚本，不冒充真实模型。 |
| Static HTML service | One real Linux App test passed: nested Unicode HTML/CSS, exact HTTP bytes, observer cancellation preserves service, job cancellation closes endpoint, owned environment removed. / 真实 Linux 页面、资源、生命周期与清理验证通过。 |
| Office keyboard | Five App-host UIKit tests passed; actual Word keyboard dismissal restores document height. The original chat-keyboard-to-attachment transition required its own check at that time. / 五项测试及 Word 自身键盘收起布局通过，原聊天附件入口当时另行验证。 |
| Conversion fonts | Eight checks passed against the real converter and independent OOXML reader. An additional actual App conversion/open test passed after observing decoded native tiles; image inspection confirms readable Chinese headings/body/bold and the bilingual table. The shipped bundle hash matches its inventory. / 八项转换检查通过；App 实际转换并等待原生绘制后，目视确认中文标题、正文、粗体及中英表格完整可见，打包哈希一致。 |
| iPad UI | Long input wraps and expands. Two marker strokes appear immediately, survive undo/redo, assistant-panel changes and cold reopening. / 长输入换行及展开；两笔高亮即时显示，撤销重做、面板切换和冷启动重开保留。 |
| Configured-model Office editing | Three actual configured-model cases produced six saved Word, Excel and PowerPoint files. Independent OOXML inspection verified repeated text edits, native tables, formula/error values, duplicated slides and notes. The run was not accepted as a whole because native teardown failed; the saved files were later reopened with the repaired component without repeating paid model calls. / 三个真实已配置模型场景生成六份文件，独立回读确认文本、原生表格、公式及错误值、复制幻灯片与备注。原生退出失败，整体验收当时未通过；后续已用修复组件重开现有产物，未重复付费调用。 |
| Native drawing and charts | DOCX and XLSX saved drawing cases passed; PPTX initially saved no new drawing paths. Native chart save/reopen preserved data, but tile preview still omitted bars that were present in the same-session diagnostic PDF. Neither PPT drawing nor chart display was accepted at that time. / DOCX、XLSX 笔迹保存用例通过；PPTX 起初未保存新增笔迹。图表保存重开保留数据，但预览缺柱，同会话诊断 PDF 则完整；当时 PPT 笔迹与图表显示尚未验收通过。 |
| Installed Linux guide | The actual App upgraded the managed shell guide to 1.1.1 and read back the Linux execution instructions. / 实际 App 将受管理的 Shell 指南升级至 1.1.1，并回读确认 Linux 执行说明。 |
| Package installation | Offline installation and independent import passed in the actual Linux guest. The network diagnostic stopped during cold pip startup before reaching DNS, TLS or the package index; the separated-stage diagnostic later ran to completion in the actual guest. / 实际来宾离线安装及独立导入通过；网络诊断停在 pip 冷启动，尚未进入 DNS、TLS 或包索引阶段；后续分阶段诊断已在真实来宾完成。 |

These rows are earlier observations; later chart, ink, native-exit and Linux results are recorded in the latest status above.

以上为历史观察；后续图表、笔迹、原生退出及 Linux 结果以最新状态为准。

Historical failures included an early blank conversion capture taken before native paint, the OSL thread-identifier lock exception and document-broker destruction failure. The corrected conversion check later confirmed readable Chinese, and later native exit checks passed as recorded above. The original failures remain distinct from those later results.

历史失败包括原生绘制前过早截图导致的转换空白、OSL 线程标识锁异常及文档代理析构故障。后续转换检查已确认中文可读，原生退出检查也按上文通过；原失败与后续通过结果分别保留。

## Remaining / 当前待完成

Current remaining acceptance is the release chain: qualify the final device component and local App archive from exact source; complete the minimal distribution signing/upload step where local capability is missing; verify Apple `VALID`, unexpired status and internal availability in the existing Floe QA group; then submit once to the existing external beta group and read back the review state. No new beta version/build has been selected or reserved, and no upload or submission has occurred in this round. The existing 1.7.34 (275) App Store review build and its immutable tag remain unchanged. The separately authorized stable GitHub release for 275 is a source-only follow-up after this round. Physical Pencil pressure, palm rejection and feel remain user acceptance. No final device, all-Simulator or release acceptance is claimed; no website deployment or follow-up timer is authorized by this record.

当前剩余验收为发布链路：由同源源码完成最终设备组件及本地 App 归档；在本地缺少分发能力时完成最小必要的分发签名／上传；核验 Apple `VALID`、未过期及现有 Floe QA 内部可用；随后向现有外部测试组提交一次并回读审核状态。本轮尚未选择或预留新的测试版本／构建号，也未发生上传或提交。现有 1.7.34 (275) App Store 审核版本及其不可变标签保持不变；另行授权的 275 GitHub 稳定发布在本轮之后以纯源码方式进行。实体 Pencil 的压感、掌拒及手感仍由用户验收。本记录不声称最终设备、全模拟器或发布验收通过，不涉及网站部署或恢复跟进定时任务。
