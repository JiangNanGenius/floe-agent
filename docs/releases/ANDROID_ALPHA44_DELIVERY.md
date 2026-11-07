# Android Alpha44 交付记录

2026-11-07，[Android 0.1.0-alpha.44](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.44) 已公开。版本 code63，固定源码 `0c7bf50e1844572117633af8f41e676525e9e9ce`；主 APK 为 163893275 字节，SHA-256：`880d6e0f4888022872267a70a02cc24dc9060465cc419ddf53c166f39534d453`。

## 本包变化与证据

- 首次任务提交后读取已保存的审批模式，只更新策略投影；新用户操作、不同会话与旧执行回复继续隔离，不用旧会话页覆盖运行、队列或策略版本。
- 审批上下文加入当前运行中已结算的工具回执，包含只读前置步骤；限量、脱敏并保留操作分类。回执不能授予权限，成功返回或启动请求被接收不等于用户目标完成。旧编码兼容，失败、取消和结果未知记录不计为成功。
- 7 项 Swift host 回归及 13 项会话 JVM 回归通过；实际 ARM64 对象／链接、Full APK、Play Kotlin 编译通过。原生生产检查点 d2d91fd0e 的全部输入与该 APK 源码相同，58 行封装对账、签名和 16 KiB 检查通过。未改模块继续复用证据。

## 三星结果与保留限制

实际主包和运行时由私有 ADB 联合安装，逐包核对安装字节和原有 UID。新包启动、既有任务及项目可见、设置／通用页打开关闭和返回首页通过；临时常亮已恢复，已重新锁屏，无障碍保持关闭。没有新建付费模型任务，也没有继续旧测试任务。

Alpha43 原计算任务在启动计算器后，被唯一一次后续观察的审批误判中断。本包包含原因明确的代码修复，但首次启动后的模式显示和完整跨 App 多步任务仍未在新包完成实测。手机设置底部分类需滚动，通用页主题区、字号、留白和开关仍需统一精修。条件触发、项目隔离、CAD 新工具栏及其余 N01–N08 场景继续；模拟器没有新增验收。

## 更新、公开读回与清理

Alpha43/code62→Alpha44/code63 增量包为 43562595 字节，已实际重建至主 APK 的相同摘要；另有跨版本完整 APK。六个白名单附件、注解标签→源码和公开更新元数据均独立读回，iOS Latest 保留为 v1.7.74。私有 ADB 安装不作为新的在线升级证明；既有 Alpha37 完整包和 Alpha36 增量设备证据分别保留。

本包完成后再清理 3508285440 字节，连同此前同轮清理累计 7656407040 字节。累计退役 20 处本地旧安装产物、清理 38 处构建暂存和 12 个打包目录，合并 14 处相同副本。另删除误选旧基线产生但未发布的补丁，保留原报告。保留当前44、回滚43、独立失败候选、原生符号与原始证据；被退役的公开安装产物保留摘要和恢复链接，不删除公开 Release。仅保留紧接 N03／N08 所需的可复用缓存、SDK／AVD 和用户文件。

English: Alpha44 repairs first-task policy projection and approval ordering context. Seven Swift host and thirteen conversation JVM regressions passed, along with actual Full/Play-related compilation, ARM64 production and package integrity checks. Samsung confirms startup, retained-data navigation and settings return; no paid end-to-end phone task was repeated. All six public asset bytes, source-tag binding and update metadata were verified, with iOS Latest preserved. The complete N01–N08 goal and global phone UI refinement remain open.
