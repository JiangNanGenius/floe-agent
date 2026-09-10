## Floe Agent 1.6.1 (Build 136)

### 简体中文

本版用于本轮大型升级的实际设备测试。签名上传、Apple 处理和 Floe QA 可见性分别核验；发布说明本身不代表已经可以安装。

- Office 接入本地原生 Word、Excel、PowerPoint 编辑前端：右侧直接只读查看，全屏后编辑真实页面、单元格和幻灯片对象，替代逐字段填写的界面。
- 增加工作区附件插入、文档内附件列表和导出，以及编辑副本、保存冲突检查和恢复入口。保存失败保留编辑副本；原文件提交必须通过校验。
- 新增工具与 Skill 分页目录、多条件搜索和所属指南提示；任务清单可在执行中修订，保留修订与完成记录，用户引导后可以调整后续步骤。
- 聊天优先加载最新片段，较早内容按需读取；修复重连后中间消息缺页，以及重新进入时丢弃已加载历史的问题。停在底部时跟随新内容，上滑阅读时停止跟随。
- 生图设置允许模型在已配置的供应商、模型和支持参数中选择，预设作为优先级和有限后备；目录完整提供参数范围。更新 GPT Image 2.5 预设，保留火山和阿里目录更新。
- 内置插件随软件更新检查版本，并保留用户修改；同步整理内部提示词、技能说明、素材预览和运行反馈。
- 延续上一版的本地 Markdown / Word / HTML / RTF / 文本 / PDF 转换、长文本写入、PDF 右侧阅读、长按批量管理和 iPhone 画布改进。

**已知限制：** PPTX 图表原生保存仍可能丢失数据关系；Floe 的保存及“另存副本”会拦截已识别的损坏导出并保留编辑副本，相关文件可能无法保存或导出。此校验尚未覆盖 Office 内部的格式导出菜单，测试时请使用 Floe 的“另存副本”。复杂图表、附件旋转/组合、随单元格变化和精确布局尚未全部验收。附件插入若中途失败，可能已产生部分修改，界面会提示检查或撤销后再试。完整 Office 功能目标保持开放，不把本次测试版描述为全部完成。

**测试时保存文档：** 请使用 Floe 顶部“返回”或“保存并返回”提交原文件。当前 Office 内部工具栏的保存只持久化编辑副本；统一两处保存行为仍在完善。独立 Mac 测试程序曾在无障碍/剪贴板操作中发生 WebContent 崩溃，保留了工作副本，物理 iPhone/iPad 是否受影响尚未确认。

本轮变更及直接调用链的代码审阅、已修正问题和必要检查见[代码审计](RELEASE_CODE_AUDIT_20260909.md)。[Office 截图索引](OFFICE_SCREENSHOT_INDEX.md)保留实际操作证据；[完整实施清单](WORKFLOW_UPGRADE_IMPLEMENTATION.md)继续跟踪剩余功能与真机验收。

### English

This beta delivers the current large upgrade for device testing. Signed upload, Apple processing and Floe QA visibility are verified separately; these notes do not establish install availability.

- Integrate a local native Word, Excel and PowerPoint frontend: read-only inline previews, then fullscreen editing of document pages, spreadsheet cells and slide objects instead of individual-field forms.
- Add workspace attachment insertion, embedded-attachment listing/export, working copies, conflict checks and document recovery. Failed saves retain the working copy; original-file writeback requires validation.
- Add paged tool/skill directories, multi-query discovery and workflow ownership. Revise task checklists during execution and respond to user steering while preserving revisions and completion records.
- Load recent conversation content first and fetch history on demand. Recover reconnect gaps without discarding loaded history. Follow new content at the bottom and stop following when reading older messages.
- Allow model-directed image provider/model/parameter selection among configured routes, with presets as priorities and bounded fallback. Return complete parameter catalogs and add GPT Image 2.5 presets alongside the refreshed Volcengine and Alibaba catalogs.
- Reconcile bundled plugin updates while preserving user edits; revise internal prompts, skill descriptions, asset previews and activity feedback.
- Retain the previous beta's local Markdown / DOCX / HTML / RTF / text / PDF conversion, long-text writing, inline PDF reading, long-press bulk management and iPhone canvas improvements.

**Known limitations:** native PPTX chart export can lose data relationships. Floe's save and Save a Copy actions reject recognized damaged exports and retain recovery copies, so affected presentations may not save/export. That check does not yet cover the Office engine's own format-export menu; use Floe's Save a Copy during testing. Complex charts, attachment rotation/grouping, cell-dependent positioning and exact layout remain under qualification. Attachment insertion may leave partial changes on failure; the UI asks users to inspect or undo before retrying. Full Office acceptance remains open.

**Saving during testing:** use Floe's top Back or Save and Return action to commit the original file. The Office toolbar currently persists the editing copy; unifying both save actions remains outstanding. An independent Mac probe encountered a WebContent crash during accessibility/clipboard interaction and retained working copies; physical iPhone/iPad impact is unconfirmed.

See the [code audit](RELEASE_CODE_AUDIT_20260909.md), [Office screenshot index](OFFICE_SCREENSHOT_INDEX.md) and [full implementation checklist](WORKFLOW_UPGRADE_IMPLEMENTATION.md) for evidence and outstanding work.
