# Android Alpha81 / code107

## Delivery / 交付

[Alpha81/code107 已公开](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.81)，固定源码 `fd37a3ca5998dff5800cc5ae76583ba05c203dc2`，新的 native41。Full构建、精确主／运行组件安装、七附件匿名下载字节、当前及保留Alpha65客户端的更新发现均通过；iOS Latest仍为`v1.8.9`。该中间版本不表示N01–N08总目标完成。

Alpha81/code107 is public from the immutable source above and fresh native41. Actual Full production, exact Samsung main/runtime installation, all seven anonymous asset downloads and current/retained65 update discovery pass. iOS Latest remains v1.8.9; the whole goal stays active.

## Changes / 改动

- 手机和平板工具统一为 `device.observe`、`device.act`、`device.screenshot`；目录、派发、审批、等待恢复、脱敏和指南使用同一命名。旧任务的三个旧名保留精确兼容，新目录不重复展示。
- 修正助手启动外部应用被误认作用户接管、导致任务结束不重锁的问题；改为监听实际输入，保留真实用户接管后的让路行为。
- 接入新的ADB服务会话后刷新实际能力；去掉完成和圆形工具按钮的默认外圈描边，保留原布局和点击范围。

Phone/tablet tools share the device.observe/act/screenshot namespace across discovery, dispatch, approval, restoration, redaction and guides. Three exact legacy aliases preserve old tasks without duplicate discovery. The relock repair distinguishes actual input from Activity lifecycle callbacks. New ADB sessions refresh live capabilities. Small button-outline refinements preserve the existing design and hit targets.

## Verification / 验证

实际Swift对象／测试编译45项及Android Full Release Kotlin消费端／46项相关检查通过；ARM64对象／链接、58项原生封装、16KiB、API28/29签名和对应源码／许可校验通过。80→81增量已在主机实际重建，不冒充三星增量安装。未改组件复用已有证据，不重跑全量矩阵。

三星P2实际运行使用Ark套餐／ark-code-latest，115条原始记录确认12项成功结果（2次`device.observe`、10次`device.act`），每次动作使用最新观察，最终读到计算结果4、任务正常完成；被动记录确认自动解锁后自然重锁，没有中途人工输入。模型最初选中标注为“1”的节点，随后在动作限额内清除并更正；保留原误选，不宣称每次选点都正确。P1因测试准备漏设审批策略而停在人工审批，已停止、导出且未恢复，不归因于更名。

新ADB会话复用配对启动UID2000，旧的能力重启提示消失，权限页及UID选项可用。读取此前已退役测试包得到`package_not_found`，保留该结果；不宣称本包新UID修改通过，原C2功能证据继续复用。临时凭据、无障碍、自动化和控制范围已恢复，两个自建任务及设备导出已清，原5条任务保留；无线调试、常亮和超时恢复，手机自然锁屏。

Actual Swift/Kotlin checks, fresh ARM64 production,58 native bindings,16KiB, API28/29 signatures and source/license closure pass. Host80-to81 reconstruction is distinct from the engineering Samsung joint installation. Fresh P2 completes12 canonical-device calls using current observations, reads actual4 and naturally relocks with no intervening host input. The model's initial selection of1 and its bounded correction remain recorded. P1 was stopped at a mistakenly unconfigured human-approval policy, without resuming it. Saved ADB pairing startsUID2000 and fresh capability UI works; the retired fixture's package-not-found result is retained rather than claimed as a new UID mutation pass. Owned task/export residue and sensitive configuration were restored; original tasks remain.

## Scope / 范围

仅自行分发Full ARM64。此中间版本仍保留既定收口事项；完成整轮功能验证后再提升1.0.0。公开80标签、安装包和历史故障不变；Android预发布保留iOS Latest。

Self-distributed Full ARM64 only. This intermediate candidate retains the agreed remaining work; final1.0.0 follows whole-round functional verification. Public80, its tag/package and original failure evidence stay immutable; Android prereleases preserve iOS Latest.
