# Android 0.1.0-alpha.45

本次中间版本整理手机设置的密度、导航和保存入口，并补充充电条件的实际状态监听：

- 设置标题、正文、行间距及按钮外观更紧凑，保留系统字体缩放和可点击范围。
- 通用页的语音输入、朗读和媒体转写各自进入二级页面；模型角色移到模型设置中。手机返回先回上一层，平板保留分类与详情两列。
- 模型角色和辅助模型有未保存修改时，在页头提供原有保存、取消操作，保留草稿及版本冲突处理。
- 条件计划按真实充电状态观察，覆盖插电但暂停充电以及不拔线恢复充电的变化；电量变化不重复创建条件事件。
- 提供完整 APK，以及 Alpha44 到 Alpha45 的增量包。

## Known issues / 已知问题

该版本属于持续修复的中间版本。既有多步手机任务、条件计划及项目隔离的完整实机验收仍按实际结果单独记录；Alpha43 原审批故障保留，不继续旧任务。全局界面仍需逐页精修，CAD 既有实机证据仅覆盖一份 STL。系统权限、第三方编辑器及不同厂商行为不能仅凭编译结果宣布通过。

## English

This intermediate prerelease makes phone settings denser while preserving system font scaling and usable touch targets. Speech input, read-aloud and media transcription open separate pages; model roles move into model settings. Back returns through the nested page, and tablets retain the category/detail split. Existing role drafts, explicit save/discard and conflict handling remain in use, with pending actions available in the page header.

Charging schedules observe actual charging transitions, including paused charging while plugged in and resumption without reconnecting the cable. Battery-level changes alone do not create duplicate condition events. A full APK and an Alpha44-to-Alpha45 delta are provided.

This is an intermediate version. End-to-end physical-device results for multi-step phone tasks, conditional schedules and project isolation are tracked separately. Alpha43's original approval failure remains recorded and its task is not resumed. Further visual refinement remains; existing physical CAD evidence covers one STL. Compilation alone does not verify permissions, third-party editors or manufacturer-specific behavior.
