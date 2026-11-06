# Android 0.1.0-alpha.44

本次中间版本补齐首次任务的审批状态显示，以及多步工具调用的审批上下文：

- 首次任务启动提交后重新读取真实审批模式，只更新当前任务的策略显示；后到的旧回复不覆盖新的用户选择、任务或执行状态。
- 审批模型可读取本轮任务已结算的工具回执，避免把已调用的前置步骤误判为跳过。回执经过限量和脱敏，观察与操作保留各自分类；返回成功或启动请求已接收仍不等于用户目标完成，也不扩大授权。
- 兼容不含新回执字段的旧数据，失败、取消和结果不确定的调用不作为成功回执。
- 提供完整 APK，以及 Alpha43 到 Alpha44 的增量包。

## Known issues / 已知问题

Alpha43 三星实测的计算任务在成功启动计算器后，被后续观察的审批误判中断；本版包含已定位原因的代码修复，新的付费跨 App 连贯执行尚未复测，继续保留该限制。首次审批模式显示的设备行为也与编译和本机回归分开记录。全局字号、菜单留白、开关尺寸、条件触发、项目隔离及其余 N01–N08 场景仍在迭代，既有 CAD 实机证据仅覆盖一份 STL。

## English

This intermediate prerelease refreshes the committed first-task approval mode without replacing newer user choices, task ownership or run state. Approval review receives bounded, redacted receipts for settled tool calls in the owning run, including read-only prerequisites. Receipts supply ordering context, never permission or proof that an external effect or the user's goal completed. Failed, cancelled and unknown outcomes remain excluded; older actions without receipts remain readable.

A full APK and an Alpha43-to-Alpha44 delta are provided. Alpha43's Samsung calculation task launched Calculator but stopped when approval incorrectly treated the next observation as skipping the initial launch. This version repairs the identified source path; a new paid end-to-end cross-App run has not been repeated. Physical behavior and local checks are recorded separately. Global typography, menu spacing, switches, conditional schedules, project isolation and the remaining N01–N08 scenarios remain in progress. Previous physical CAD evidence covers one STL only.
