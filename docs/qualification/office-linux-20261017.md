# Office, Notes and Linux execution qualification / 验证记录

Status: implementation and local qualification in progress. This is not a release or physical-device acceptance record.
状态：实现及本地验证中。本记录不代表已发布或实机验收通过。

## Latest verified status / 最新验证状态（2026-10-18）

Actual Simulator App checks closed the earlier ink, exit, attachment and Linux gates. DOCX/XLSX/PPTX vector ink retained its colors and widths after save/reopen in all three formats, without the former native fatal exits. Later App runs also remained free of those exit failures. Six previously saved live-model Office outputs reopened with the newer component; no paid Office model calls were repeated. Manual Word attachment opening returned from the native editor to its original task and draft. HTML attachment → IDE → task-owned Linux service returned HTTP 200 with the exact 145-byte working file; stopping that service closed its listener without changing messages or starting a model run.

实际模拟器 App 已闭环此前的笔迹、退出、附件及 Linux 检查：DOCX/XLSX/PPTX 三格式矢量笔迹的颜色、线宽及保存重开全部通过，未再出现原生致命退出；后续 App 执行也未复现原退出故障。六份已留存的真实模型 Office 文件在新组件中重开通过，未重复付费调用 Office 模型。手动 Word 附件经原生编辑器返回原任务及草稿；HTML 附件经 IDE 启动任务所属 Linux 服务，HTTP 200 正文与 145 字节工作文件完全一致，停止后监听关闭、消息未变，也未启动模型。

The actual Linux guest completed signed distribution-package installation, apt/dpkg audits, Pillow/lxml imports, ordinary pip installation of three pinned packages and the full eight-node recursive dependency closure. Generated DOCX, XLSX, PPTX and PNG files reopened successfully; the owned environment and working state were cleaned up. A real model answered `2+2=` with `4` through the ordinary composer. Navigating to Notes while waiting and returning did not restore the consumed draft; a new unsent draft survived. Temporary QA configuration was removed.

真实 Linux 来宾已完成签名发行版软件包安装、apt/dpkg 核验、Pillow/lxml 导入、三个固定版本包的普通 pip 安装及完整八节点递归依赖检查；实际生成 DOCX、XLSX、PPTX、PNG 并重开通过，所属环境及工作状态已清理。普通输入框经真实模型完成 `2+2=` → `4`；等待时切换手记再返回，已发送草稿未恢复，新未发送草稿保留，临时 QA 配置已清理。

Native PPT chart rendering remains the only open code defect: the five-category source data and diagnostic PDF are complete, but actual painting before encoding still omits the first four bars. Chart value/series editing and save/reopen are therefore not accepted. The latest bitmap metadata experiment compiled as a native component and a locally signed full App, but did not improve rendering; its source changes were reverted and its binary is rejected for release. Graphics diagnosis continues with the existing binary. Compilation is not final component or release acceptance.

原生 PPT 图表显示仍是唯一未闭环的代码缺陷：五类别源数据和诊断 PDF 完整，但实际绘制在编码前已缺前四根柱；修改数值／系列及保存重开也尚未验收。最新位图元数据实验虽完成原生组件及本地签名完整 App 编译，显示未改善，源码改动已撤回，实验二进制不得用于发布；继续使用现有二进制观察图形行为。编译通过不代表最终组件或发布验收通过。

Earlier failures below are historical observations, superseded only where the latest status above records a completed check. Suites overlap and are not summed into a total. Physical Pencil pressure, palm rejection and feel remain user acceptance.

下文原失败均为历史时点记录，已闭环项目以本节为准；各组测试有重叠，不合计总数。实体 Pencil 的压感、掌拒及手感仍由用户验收。

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
| Office keyboard | Five App-host UIKit tests passed; actual Word keyboard dismissal restores document height. The original chat-keyboard-to-attachment transition still needs its own check. / 五项测试及 Word 自身键盘收起布局通过，原聊天附件入口另行验证。 |
| Conversion fonts | Eight checks passed against the real converter and independent OOXML reader. An additional actual App conversion/open test passed after observing decoded native tiles; image inspection confirms readable Chinese headings/body/bold and the bilingual table. The shipped bundle hash matches its inventory. / 八项转换检查通过；App 实际转换并等待原生绘制后，目视确认中文标题、正文、粗体及中英表格完整可见，打包哈希一致。 |
| iPad UI | Long input wraps and expands. Two marker strokes appear immediately, survive undo/redo, assistant-panel changes and cold reopening. / 长输入换行及展开；两笔高亮即时显示，撤销重做、面板切换和冷启动重开保留。 |
| Configured-model Office editing | Three actual configured-model cases produced six saved Word, Excel and PowerPoint files. Independent OOXML inspection verified repeated text edits, native tables, formula/error values, duplicated slides and notes. The run is not accepted as a whole because native teardown failed; the saved files will be reopened with the repaired component without repeating paid model calls. / 三个真实已配置模型场景生成六份文件，独立回读确认文本、原生表格、公式及错误值、复制幻灯片与备注。原生退出失败，整体验收仍未通过；修复后重开现有产物，不重复付费调用。 |
| Native drawing and charts | DOCX and XLSX saved drawing cases passed; PPTX saved no new drawing paths. Native chart save/reopen preserved data, but tile preview still omitted bars that were present in the same-session diagnostic PDF. Neither PPT drawing nor chart display is accepted. / DOCX、XLSX 笔迹保存用例通过；PPTX 未保存新增笔迹。图表保存重开保留数据，但预览缺柱，同会话诊断 PDF 则完整；PPT 笔迹与图表显示尚未验收通过。 |
| Installed Linux guide | The actual App upgraded the managed shell guide to 1.1.1 and read back the Linux execution instructions. / 实际 App 将受管理的 Shell 指南升级至 1.1.1，并回读确认 Linux 执行说明。 |
| Package installation | Offline installation and independent import passed in the actual Linux guest. The network diagnostic stopped during cold pip startup before reaching DNS, TLS or the package index; the separated-stage diagnostic still needs App execution. / 实际来宾离线安装及独立导入通过；网络诊断停在 pip 冷启动，尚未进入 DNS、TLS 或包索引阶段，分阶段诊断仍待 App 执行。 |

Historical failures included an early blank conversion capture taken before native paint, the OSL thread-identifier lock exception and document-broker destruction failure. The corrected conversion check later confirmed readable Chinese, and later native exit checks passed as recorded above. The original failures remain distinct from those later results.

历史失败包括原生绘制前过早截图导致的转换空白、OSL 线程标识锁异常及文档代理析构故障。后续转换检查已确认中文可读，原生退出检查也按上文通过；原失败与后续通过结果分别保留。

## Remaining / 当前待完成

Complete native PPT five-bar display and real value/series edit → save → reopen acceptance, then qualify the final device component and App from exact source. A new unused beta version/build, internal and external TestFlight checks, and the separately authorized stable GitHub release for the existing App Store review version remain with the primary release owner. The existing App Store submission is unchanged. No final device, all-Simulator or release acceptance is claimed; no website deployment or follow-up timer is authorized by this record.

完成原生 PPT 五柱图显示及真实修改数值／系列后的保存重开，再对最终设备组件和 App 做同源验证。新的未使用测试版本／构建号、内外 TestFlight 状态核验，以及另行授权的既有正式审核版本 GitHub 稳定发布，仍由主协调完成。现有 App Store 审核保持不变。本记录不声称最终设备、全模拟器或发布验收通过，不涉及网站部署或恢复跟进定时任务。
