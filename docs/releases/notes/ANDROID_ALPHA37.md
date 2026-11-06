# Android 0.1.0-alpha.37

较大的任务历史使用有界续读，在完整校验后显示，保留更早记录入口；不会重新执行旧工具或审批。文件管理器改为先初始化当前图形会话的服务，再发出一次窗口请求，替代仅判断进程已启动。

相关 Full/Play 编译、6项历史与1项图形脚本检查、2项真实存储宿主检查及实际 Android ARM64 对象／链接通过。本冻结候选的三星验收在构建后进行。上一版四张大图反馈已取得手机和服务端真实回执，本次没有新增模型或媒体生成调用。

## Known issues / 已知问题

这是 N01–N08 中间版。图形首次启动的新实现尚待三星复测；单条历史内存上限4MiB，更大记录仍明确失败并保留完整任务导出。完整跨 App 流程、条件触发、跨项目图形隔离和组件生命周期继续验收。全局 UI 精修后置。

## English

Large journal events use bounded, ownership-checked continuation and are displayed after complete integrity validation. Earlier records remain accessible; replay never executes old tools or approvals. The graphical file manager initializes its per-session service before one window request.

Targeted Kotlin and native-store checks and actual Android ARM64 object/link production passed. Samsung acceptance of this immutable candidate follows its build. The previous four-image upload received a real device/server receipt. No new model or media-generation call was made. This is an intermediate release: first graphical launch remains under acceptance, individual history materialization is bounded at4MiB with complete task export retained, and remaining workflows and visual refinement continue.
