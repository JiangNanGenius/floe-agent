# Office, Notes and Linux execution qualification / 验证记录

Status: implementation and local qualification in progress. This is not a release or physical-device acceptance record.
状态：实现及本地验证中。本记录不代表已发布或实机验收通过。

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

## Evidence recorded so far / 已完成验证

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

## Remaining / 待完成

PPT drawing, chart display, native teardown, the original chat-to-Office/HTML attachment transition, final saved-file reopening, final device packaging and Apple distribution still require current acceptance evidence. Attachment buttons and task-owned editor routing are implemented and pushed, but their new App tests and actual UI flow have not run. The initial open-only conversion snapshot was blank. The corrected test waits for native paint and visual inspection now confirms readable Chinese. Actual debugger captures identified separate shutdown failures in the OSL thread-identifier lock and document-broker destruction; repairs are not yet qualified. Future qualification rejects either native failure even when the test command returns success. Compilation, a dispatched engine command and a successful upload are separate states. Simulator finger drawing does not prove Apple Pencil pressure, latency or physical-device behavior. No physical-device result is claimed.

PPT 笔迹、图表显示、原生退出、原聊天至 Office／HTML 附件的入口切换、最终产物重开、设备打包与 Apple 分发仍需当前验收证据。附件按钮及原任务编辑器路径已实现推送，新增 App 测试和实际界面流程尚未执行。首次转换快照过早而为空白；补充等待实际绘制后，中文截图检查已通过。调试器分别捕获线程标识锁和文档代理析构的退出故障，修复尚未验证；后续即使测试命令成功，出现任一原生异常也拒绝通过。编译、命令下发和上传是不同状态；模拟器手指书写不代表实体 Pencil 压感、延迟或真机表现。
