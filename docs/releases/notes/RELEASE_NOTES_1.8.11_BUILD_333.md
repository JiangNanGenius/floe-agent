# Floe 1.8.11 (333)

## 简体中文

- 改善会议录音、转写提示与页面布局。回放加入可拖动时间轴、前后跳转和播放／暂停；调整语音输入的中断处理。
- 改进计划与目标的衔接，目标可编辑、暂停、继续和删除。暂停或删除目标只影响后续自动推进，当前这轮工作继续；输入框的停止会停止本轮并暂停对应目标。同轮继续不会自动重新开启长期目标。
- 记忆列表用“已保留”区分保存与实际使用。浏览不再延长保留期限，已删除任务的旧信息逐步淡化与归档，固定内容、长期偏好和当前任务引用受到保护。
- 完善二维 CAD、地图及原理图／PCB 助手的编辑、查询与操作反馈，加入三维元件库。独立二维图纸隐藏不适用的三维草图提示栏。
- 整理图片编辑菜单与小屏参数入口，区分新建文字和更新文字；助手可查看编辑历史、撤销和重做。
- 改善生物编辑器中已保存序列与运行结果的显示和选择，统一化学、生物计算对所选环境的使用。
- 改进 Office 公式结果更新与 Word 标题转换，以及部分模型服务的工具请求兼容性和任务停止、恢复提示。
- 模型设置增加“不发送思考参数”开关，用于不兼容的自定义接口；按实际能力选择支持的思考强度，并保留模型返回的思考内容。
- 改善长文档的分段读取、追加写入和校验保存，优先使用原生文件工具。文件已保存但预览暂不可用时，不再误报整次写入失败。
- Mac Bridge 支持按授权读取 Mac 上指定的文件和图片，包括其它工作区；旧 Mac 端不支持时会提示更新。
- 普通 PDF 手记移除不相关的 LaTeX 编辑入口。帮助内容按 iOS、Android 整理，保留 iPhone Duo 的展开布局和草稿连续性。

请重点反馈录音与回放、目标暂停／继续／停止的区别、旧记忆保留、编辑器助手的结果显示与撤销，以及 Office、Mac Bridge 和 Duo 布局的实际使用情况。

## English

- Refines meeting recording, transcription messages and page layout. Playback adds a draggable timeline, skip controls and play/pause. Improves voice-input interruption handling.
- Improves the transition from plans to goals, with goal editing, pause, resume and delete. Pausing or deleting a goal stops future automatic progress while the current round continues. Stop beside the message box stops that round and pauses its goal; continuing the same round does not restart long-term goal progress.
- Memory entries show “Retained” to distinguish storage from active use. Browsing no longer renews retention. Older information from deleted tasks gradually fades and can be archived, while pins, lasting preferences and memories used by current work are protected.
- Improves editing, queries and feedback for 2D CAD, map and schematic/PCB assistants, and adds a 3D component library. Standalone 2D drawings hide the unsuitable 3D sketch-session bar.
- Organizes image-editing menus and compact-screen controls, separates creating text from updating it, and lets the assistant inspect edit history, undo and redo.
- Improves display and selection of saved sequences and run results in the biology editor. Chemistry and biology calculations use the selected environment consistently.
- Improves Office formula-result updates and Word heading conversion, tool-request compatibility with some model services, and task stop/recovery messages.
- Adds a per-model “Omit thinking parameters” setting for incompatible custom endpoints. Maps supported reasoning levels from reported capabilities while preserving returned reasoning.
- Improves native paged reading, chunked writing and verified saving for long documents. A saved file is no longer reported as a failed write when its optional preview is unavailable.
- Mac Bridge can read authorized files and images at specified Mac locations, including other workspaces. Older Mac companions show an update requirement when unsupported.
- Removes the unrelated LaTeX editor entry from ordinary PDF Notes. Organizes Help by iOS and Android, while retaining iPhone Duo's expanded layout and draft continuity.

Please focus feedback on recording and playback, goal pause/resume/Stop behavior, old-memory retention, editor-assistant results and undo, and everyday use of Office, Mac Bridge and the Duo layout.
