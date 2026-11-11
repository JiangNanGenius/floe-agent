# Android Alpha81 / code107

## Changes / 改动

- 手机和平板工具统一为 `device.observe`、`device.act`、`device.screenshot`；目录、派发、审批、等待恢复、脱敏和指南使用同一命名。旧任务的三个旧名保留精确兼容，新目录不重复展示。
- 修正助手启动外部应用被误认作用户接管、导致任务结束不重锁的问题；改为监听实际输入，保留真实用户接管后的让路行为。
- 接入新的ADB服务会话后刷新实际能力；去掉完成和圆形工具按钮的默认外圈描边，保留原布局和点击范围。

Phone/tablet tools share the device.observe/act/screenshot namespace across discovery, dispatch, approval, restoration, redaction and guides. Three exact legacy aliases preserve old tasks without duplicate discovery. The relock repair distinguishes actual input from Activity lifecycle callbacks. New ADB sessions refresh live capabilities. Small button-outline refinements preserve the existing design and hit targets.

## Verification / 验证

实际Swift对象／测试编译45项及Android Full Release Kotlin消费端／46项相关检查通过。新的ARM64生产、APK、三星行为及公开更新读回尚待完成；不以源码检查替代实机结果。未改组件复用已有证据，不重跑全量矩阵。

Actual Swift object/test compilation passes45 focused cases; the Full Release Kotlin consumer and46 affected JVM cases pass. ARM64 production, packaging, fresh Samsung behavior and public update read-back are pending. Unchanged component evidence is reused.

## Scope / 范围

仅自行分发Full ARM64。此中间版本仍保留既定收口事项；完成整轮功能验证后再提升1.0.0。公开80标签、安装包和历史故障不变；Android预发布保留iOS Latest。

Self-distributed Full ARM64 only. This intermediate candidate retains the agreed remaining work; final1.0.0 follows whole-round functional verification. Public80, its tag/package and original failure evidence stay immutable; Android prereleases preserve iOS Latest.
