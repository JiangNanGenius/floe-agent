# Android Alpha52 交付记录

2026-11-08，[Android 0.1.0-alpha.52](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.52) 已公开，code77，固定源码 `e150a7034b7c0975fbfa75c37034fa6f1b29c701`。Full APK 为164066455字节，SHA-256：`e5cd9efc20718ced9cf5b7280277a7c0ce33fc0a4318bb6f3c83ce55505ca96a`。整轮N01–N08继续。

- 图形会话服务在新连接完成后启动所选软件。三星关闭基础组件安装后，文件管理器直接显示当前项目的真实文件；重开界面保持同一组进程，App停止后相关进程退出。此次证明默认文件管理器及本项目原组件在升级后可用，不扩大为所有专业软件、跨任务软件复用或编辑写回通过。
- 首页保留既有的空定时卡片隐藏规则。三星同包实际确认无启用计划时整块隐藏，启用网络计划后显示，暂停后再次隐藏；Task Center的永久管理入口保留。
- 后台诊断将实际申请、系统拒绝、服务确认与界面通知按同一次申请关联；不使用全局“最新申请”，不记录任务正文、路径或凭据，不触发普通任务异常上传。37项生命周期回归通过，Full Debug编译通过，之后完整Full组装与Play Kotlin编译通过；新启动接线已在该Full包实际运行。
- 新的锁屏网络条件计划实际记录断开／重连并被接受，随后原生启动的保护申请返回`START_DENIED / START_RESTRICTED`。实际锁屏与前台服务不存在分别核对；回到App后才出现后续服务确认，历史仍显示等待，没有新的模型终端成果。即使已临时配置Ark审批模型，本次也不能算审批模型或无人值守验收。原等待、原拒绝和醒屏边界均保留，未点“立即运行”。
- 系统拒绝符合[Android后台启动前台服务限制](https://developer.android.com/develop/background-work/services/fgs/restrictions-bg-start)。后续修复继续真实作业所有权、等待／恢复及用户可操作设置，不把重复启动或换用WorkManager前台服务当作绕过系统限制的办法；[官方后台任务指南](https://developer.android.com/develop/background-work/background-tasks)明确其前台服务仍受同样限制。
- 三星精确联合安装核对主包、Office、CAD及运行组件77，UID与原数据保留。未改的native17输入与当前App源码逐项匹配，58项原生封装／签名／ARM64/JNI／16KiB检查通过，复用原生产对象／链接证据。未重跑未改的Office、云媒体或旧在线升级路径。
- 七附件匿名完整下载、不可变标签来源、真实客户端更新列表、非空已知问题与更新清单字节读回通过，iOS Latest保持`v1.7.74`。51→52补丁24169816字节，约为完整包14.73%，真实重建为精确code77包；完整APK支持跨版本升级。当前工程安装不代替新的App内在线升级实测。
- 六个测试计划均暂停，临时审批模型恢复未配置，常亮恢复0，无障碍及无线调试未启用，图形／终端与前台服务均已退出；App首页不显示定时卡片。未设置App自动解锁，未启动模拟器。
- 19处构建副本移除实测释放内置2712350720字节，另清理无引用的旧宿主索引／Debug缓存1155039232字节。8处完成源码暂存／安装提取移除实测释放外置161681408字节，生产回执另存；这些旧stage路径不再是可用输入。当前／回退、原失败、原生符号、SDK／AVD及明确下一用途缓存保留。

已从原登记iOS锚点`eb3bb7bca…`对照到主集成`9b016097…`，1481条路径按实际影响分类，见[iOS增量记录](../FLOE_ANDROID_IOS_DELTA_AUDIT.zh-CN.md#2026-11-08-alpha52-候选的有界-ios-增量)。保留固定视觉参照和原编号；新增独立重型工作台不增加当前APK发布门槛。下一有界修复优先后台作业接续，手机观察失效、项目软件连续性与全局UI仍按原编号推进。

English: Alpha52 opens the selected Linux application after a new graphical session connects. Samsung verified the default file manager, identical processes after reopening, proper stop and the conditional Home schedule card. A new locked network launch reached the scheduler but was denied a foreground-service start; it remained waiting, without a new model-terminal outcome or unattended acceptance.37 lifecycle regressions, actual Full/Play compilation and package checks passed; unchanged native17 production evidence was bound to current inputs. All seven public downloads, immutable source, update discovery and known issues were read back; iOS Latest is preserved. The51-to52 delta reconstructs exact code77. Device configuration was restored and unused outputs cleaned. N01–N08 remains active.
