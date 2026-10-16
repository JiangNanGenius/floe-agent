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

## Remaining / 待完成

Native Office drawing and chart engine behavior, the original chat-to-Office keyboard transition, live-provider Office edit/save/reopen, final device packaging and Apple distribution must receive their own current evidence before delivery. The initial open-only conversion snapshot was blank. The corrected test waits for native paint and visual inspection now confirms readable Chinese. Its test command returned success while native Office teardown logged a C++ mutex failure; this independent fault remains tracked and is not ignored. Compilation, a dispatched engine command and a successful upload are separate states. Simulator finger drawing does not prove Apple Pencil pressure, latency or physical-device behavior. No physical-device result is claimed.

原生 Office 笔迹及图表、原聊天至 Office 的键盘切换、真实模型编辑保存重开及最终设备打包与 Apple 分发分别验收。首次转换快照过早而为空白；补充等待实际绘制后，App 测试及中文截图检查已通过。该命令返回成功，原生 Office 退出却记录了 C++ 互斥锁异常，另列故障继续修复。编译、命令下发和上传是不同状态；模拟器手指书写不代表实体 Pencil 压感、延迟或真机表现。
