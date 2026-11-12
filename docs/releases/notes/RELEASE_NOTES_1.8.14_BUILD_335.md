# Floe 1.8.14 (335)

## 简体中文

- 完善储存占用检查和旧 Linux 环境的优化流程，在保留旧资料的前提下处理可回收项目。
- 增加 Linux 专用清理入口，可新建清理任务；没有可用模型时，可使用内置脚本清理常用缓存。清理范围限于 Linux 内部缓存和垃圾。
- 完善升级残留的识别、清理和中断恢复，保留仍需恢复的旧资料。
- 运行环境来源无法确认时提供重新下载入口，并保留原环境资料。重建后，原任务需经确认才会使用新环境继续。
- 加强计划与普通任务中的主动选择题问答，在需要澄清或用户处理时更及时询问。
- Apple Intelligence 不可用时自动停用并从模型选择列表隐藏，设置中的开关仍保留。

请重点反馈换机或升级后的占用变化与资料保留、Linux 清理和无模型回退、环境重新下载与任务继续确认，以及主动问答的实际体验。

## English

- Improves storage checks and optimization workflows for older Linux environments while preserving existing data.
- Adds a dedicated Linux cleanup entry that can create a cleanup task. When no model is available, a built-in script can clear common caches. Cleanup is limited to caches and junk inside Linux.
- Improves detection and cleanup of upgrade leftovers and recovery after interruption, while retaining older data needed for recovery.
- Adds a redownload option when the current environment's source cannot be verified, preserving the original environment data. Existing tasks require confirmation before continuing in a rebuilt environment.
- Improves proactive multiple-choice questions in planning and ordinary tasks when clarification or user action is needed.
- Automatically turns off and hides unavailable Apple Intelligence models from model selection while keeping the switch in Settings.

Please focus feedback on storage changes and data retention after migration or upgrade, Linux cleanup and its no-model fallback, environment redownload and task confirmation, and proactive questions.
