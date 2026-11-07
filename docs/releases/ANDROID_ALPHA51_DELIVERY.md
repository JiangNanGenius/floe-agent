# Android Alpha51 交付记录

2026-11-08，[Android 0.1.0-alpha.51](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.51) 已公开，code76，固定源码 `c6409b7b65b5db6a6b62b70be17f2baf246747fd`。Full APK 为164045515字节，SHA-256：`074e9313ea2f668bd21a31442c21386fc004cd820063d7eef6f4f742dd6d277d`。整轮N01–N08继续。

- 修复系统条件命令未进入两端路由的问题；原有115项生产命令和权限边界保留，新增项继续要求计划修订。旧台账漏记的既有`run.events`另行补正，原五项测试失败及code75实机拒绝均保留。
- 三星实际离开App、锁屏、断开并重连Wi-Fi，持久事件被接受并创建新任务。Ark Plan／ark-code-latest真实调用`exec.shell`，返回exit0及18字节标记文件；App文件列表可见并实际重开内容，运行历史最终为已完成。没有点“立即运行”。
- 本次自动审批配置缺少审批模型，故通过一次明确授权继续；不能据此宣称自动审批已验收。测试中出现后台保护不可用提示，其具体原因、长期待机和全程无人值守仍在调查；未用记录的时间代替后台模型调用时间证据。上述限制已加入实际更新客户端读取的已知问题段落。
- 触发菜单完整可读，模型带提供商，项目／审批保存并重开保持。环境选择携带真实归属并按项目筛选；本机本次仅显示自动跟随工作区，多个合法显式目标场景未验证。未改界面复用code75实机证据及11项定向测试，不将代码过滤规则当作完整设备覆盖。
- 实际ARM64生产对象／链接、Full组装、Play Kotlin及21项当前入口／契约测试通过；58项原生封装、签名、ARM64/JNI及16KiB检查通过。三星工程联合安装核对主包、Office、CAD、运行组件字节和原UID；未改Office路径复用Alpha50证据。
- 七附件匿名完整下载、不可变标签来源、实际更新列表和非空已知问题读回通过，iOS Latest保留`v1.7.74`。50→51补丁58792297字节，真实重建为精确code76包；完整包支持跨版本升级。更新实现未改，本批工程安装不作为新的App内在线升级实测。
- 五个测试计划均暂停，测试编辑标签关闭，临时常亮恢复0，无障碍和无线调试未启用；未设置App自动解锁，未启动模拟器。本批仅使用已授权Ark套餐，没有新增付费媒体生成调用。
- 两次成功编译后各移除19处不用的打包副本，内置盘分别实测回收2714062848和2712449024字节。发布后退役20处完成暂存／提取副本，三处相同原生字节合并为硬链接，外置盘实测回收1082273792字节；共享链接不作为独立备份。当前包、回退、原始故障、源码、符号和下一步缓存／SDK／AVD保留。

下一有界修复继续后台保护提示及任务等待／恢复；手机观察间歇失效、跨项目图形隔离、专业软件与全局UI精修保留原编号，未以本次中间版本结束整轮目标。

English: Alpha51 connects real system-condition events through both schedule command gates. Samsung verified a locked-screen network edge creating a task, an authorized Ark terminal write/read, reopening the resulting file and completed history. One manual approval was needed because no reviewer model was configured; a background-protection warning and fully unattended behavior remain under investigation. Full/Play, actual ARM64 production,21 focused tests and package checks passed. All seven public downloads, immutable source and update discovery were read back; iOS Latest is preserved. The50-to51 delta reconstructs exact code76. The engineering installation is separate from unchanged updater device evidence. Device settings were restored and unused outputs cleaned. N01–N08 remains active.
