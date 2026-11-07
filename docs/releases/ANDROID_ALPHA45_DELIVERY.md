# Android Alpha45 交付记录

2026-11-07，[Android 0.1.0-alpha.45](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.45) 已公开。版本 code64，固定源码 `cec45cdea1c6bbc536270374ee9883f74fc129f5`；主 APK 为 163926039 字节，SHA-256：`fb7ea465fe4a9749d7969669efef3ef9b304e64490fd3d32cc86f3349d9b8851`。

## 本包变化

- 手机设置使用更紧凑的字号、行间距和按钮外观，保留系统字体缩放及48dp点击范围。语音输入、朗读、媒体转写分别进入二级页面；模型路由移到模型与供应商中，草稿保存／取消在页头可见。手机逐级返回，平板保留两列。
- 充电条件监听使用真实充电状态，补插电暂停及不拔线恢复充电的变化；普通电量广播不重复创建条件事件。新条件任务与项目隔离仍待完整实机验收。
- 手机观察有效期覆盖模型决策与审批耗时，仍逐次校验所有者、授权、页面代次和真实节点。
- 修复系统语音可用性检测持有状态锁等待主线程、主线程切后台又等待该锁的互相等待。

## 编译与实际行为

Full APK 和 Play 相关编译通过。54项相关 JVM 结果包括最终修复新跑的16项语音契约，以及逐文件匹配未变源码后复用的31项手机围栏／策略与7项设置／条件策略结果。实际原生生产输入与native13相同，复用其对象／链接证据；58行实际封装、签名、ARM64/JNI及16KiB核对通过。

同一最终主包和运行时分别私有覆盖安装到三星 API33及现有 API37平板模拟器，安装字节和UID已核对。三星检查设置密度、语音二级返回、模型保存／取消及重开、深色与1.3倍字体；未变界面源的前一候选证据保留。最终修复包在两台设备完成前后台返回、进入设置，原平板语音锁无响应场景未再触发，原始系统现场继续保留。平板结果仅作界面及该生命周期场景参考。

Alpha44的一次新三星模型任务已通过计算器启动、界面观察和首次审批模式显示；首次点击因约32秒决策链超过30秒观察有效期而失败，未完成计算。Alpha45包含有效期修复，没有追加真实模型复测，不继续旧任务。该限制与条件计划、项目隔离、更多CAD／文档流程及全局视觉精修一起继续跟进；既有CAD实机证据仅覆盖一份STL，整轮N01–N08未完成。

## 更新与公开读回

Alpha44/code63→Alpha45/code64补丁为51846472字节，已真实重建至主 APK相同摘要；完整 APK供跨版本安装。六附件、注解标签→源码及匿名公开下载字节全部核对通过，iOS Latest保留为v1.7.74。真实客户端列表接口及请求参数的公开元数据确认可发现45；前两次其他读取路径的504诊断记录保留。这不是本轮设备在线升级证明，既有完整包与增量设备证据分别复用。

## 清理与恢复

本批实测回收8105619456字节，约8.1GB：退役10处旧公开安装产物、10处被替代的未公开安装产物，清理38处构建副本和18个打包目录，归并1处完全相同的Office组件副本。保留当前45、必要回滚44、原始日志／无响应现场、源码、摘要和符号，以及近期明确需要的缓存、SDK／AVD和用户文件。

清理时曾按构建成功误把一份出现无响应的未公开候选归为普通旧包，其APK原字节已退役；对应源码、原始现场、摘要、生产记录与原生符号保留，不能宣称可恢复这份旧APK的精确字节。其保留清单已更正。三星临时权限／应用范围／审批模型／外观及常亮已恢复，平板运行实例已关闭，AVD数据保留。

English: Alpha45 refines compact settings and nested navigation, charging-state observation, phone-observation timing and a speech-state lock inversion. Full/Play-related compilation, 54 relevant JVM results (38 reused for unchanged inputs), native binding and package checks passed. The same final APK was installed on Samsung/API33 and the reused API37 tablet; settings and foreground-return checks passed after the fix, with original ANR evidence retained. The complete phone calculation remains unverified after the timing fix. All six public assets and source binding were read back; iOS Latest is preserved. This remains an intermediate N01–N08 delivery, with no new device online-upgrade claim.
