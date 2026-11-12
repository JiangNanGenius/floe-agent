# Floe 1.8.17 (338)

## 简体中文

- 改善会议连续转写的分段、实时草稿和静音处理，完善停止补写、录音恢复及所选转写服务的错误提示。
- 调整会议工作台布局，分开显示录音与转写状态；回放保留拖动时间轴、前进和后退控制。
- 修复执行计划仍沿用规划权限的问题。生成计划后，输入框切回智能体；后续手动选择计划模式仍然有效。
- 计划进度跟随当前一轮运行，保留历史；增加模型可调用的清空与重建能力。
- 补齐子任务生成文件的消息卡引用和重开预览，改善大文本文件的连续阅读。
- 扩展原生 Workspace 文本工具的格式识别和说明，支持代码、脚本、网页、配置及其他纯文本文件，保留换行和 UTF-8 字节标记。
- 修复旧环境资料检查中的数据库读取与引用判断，完善无损优化的进度、受阻原因和容量估算显示。原资料、已安装软件和恢复盘继续保留。
- 修复任务仍在重试时过早显示失败，以及恢复后残留旧失败通知的问题；停止、挂起和最终失败分别呈现。

本版先供内部测试。请重点核对会议录音与回放、执行计划后的实际编辑、TXT／网页／代码文件卡，以及迁移设备优化前后的实际占用和资料完整性。

## English

- Improves continuous meeting transcription, draft display and silence handling, with better stop-tail settlement, recording recovery and errors from the selected transcription service.
- Refines the meeting workbench, separates recording and transcription status, and keeps a seekable playback timeline with forward and back controls.
- Fixes plan execution retaining planning-only permissions. A new plan returns the composer to Agent; a later manual Plan selection remains respected.
- Scopes checklist progress to the current run, preserves history, and adds a native reset-and-rebuild capability for the assistant.
- Preserves inline file references produced by subagents across reopening and improves continuous reading of large text files.
- Expands native Workspace text recognition and tool guidance for source code, scripts, webpages, configuration and other plain-text files, preserving newlines and UTF-8 byte-order marks.
- Fixes database reading and reference classification during legacy environment checks, and improves data-preserving optimization progress, blocked-state details and storage estimates. Existing data, installed software and recovery disks remain preserved.
- Prevents premature failure alerts while a run is retrying and clears stale alerts after recovery, keeping cancellation, suspension and final failure distinct.

This build starts with internal testing. Please check meeting recording and playback, actual edits after executing a plan, TXT/web/code file cards, and actual storage and data integrity before and after optimizing a migrated device.
