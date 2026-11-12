# Floe 1.8.16 (337)

## 简体中文

- 修复专用 Linux 清理任务初次启动时的环境绑定错误，正确显示检查失败与清理结果。
- 改善换机后的环境恢复，重建时显示实际阶段和下载进度，取消及失败状态及时更新。
- 修复旧环境占用检查对系统目录读取权限的额外要求，保留原有目录与文件身份验证。
- 完善储存优化的失败提示和反馈记录；资料、已安装软件及待恢复旧盘继续保留。
- 计划接受或转为目标后，收起待确认卡并在聊天中保留确认版本；增加仅收起卡片的关闭按钮，完善关键问题澄清和步骤细节。
- 完善文本文件预览和连续阅读，减少文件侧栏的重复标题与操作栏。
- 改善云端、本地模型及子智能体的工具发现，使加载状态与实际提供的工具保持一致。

请重点检查换机后重新下载或重建、Linux 缓存检查与清理、取消恢复，以及优化前后的实际占用。没有完成的清理和优化不会计为已释放空间。本版先供内部测试。

## English

- Fixes environment binding when a dedicated Linux cleanup task starts for the first time, and shows inspection failures and cleanup results accurately.
- Improves environment recovery after device migration, showing actual rebuild stages and download progress with timely cancellation and failure states.
- Removes an unnecessary requirement to read system ancestor directories during legacy storage checks, retaining directory and file identity validation.
- Improves storage optimization messages and diagnostic reports while preserving data, installed software and older recovery disks.
- Keeps an accepted plan in chat history instead of leaving its confirmation card pinned, adds a dismiss button without rejecting the plan, and improves clarification and actionable steps.
- Improves text-file previews and continuous reading, and removes duplicate titles and controls from the file sidebar.
- Improves tool discovery across cloud models, on-device models and subagents, keeping loading status consistent with the tools actually provided.

Please check redownload or rebuild after device migration, Linux cache inspection and cleanup, cancellation recovery, and actual storage before and after optimization. Incomplete work is not reported as reclaimed space. This build starts with internal testing.
