# Android Alpha66 / code92 交付检查点

本版为N01–N08持续迭代的中间预发布，整轮目标仍未完成。[公开版本及七个附件](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.66)。

- 固定App源：`3f93f73abc20d27a06772e1433464ee45b74fca8`；主包SHA-256：`886fbcb9bc98ef608f455a5085ec98cb9982c26e9e955d1bc03442dca56d0676`，164490815字节。
- 技能GitHub来源保存／清除、匿名完整目录及原始二进制、同提交文件摘要、传统Android清单和备份来源身份映射已接入。目录加载／刷新和已安装行入口已接通；本地同名不能被目录接管，同版本真实文件变动仍可审阅更新。
- 37个不同的相关组件／投影用例通过（连接器16、目录完整性10、备份来源策略6、JVM投影5），Full／Play Kotlin及实际ARM64原生对象／链接通过，58项实际封装检查通过。复用未改SQLite等证据，不重复计数；六个原有完整Domain测试和整包设备备份恢复尚未运行。
- 三星实际完成：自建技能、保存来源、公开目录检查、许可证和四份示例读取、同版本应用、冷启动后来源及最新内容读回、回退恢复原内容；缺失目录提示可操作错误。本轮没有模型／付费调用。主包通过ADB替换并核对精确字节和原UID，运行组件字节未变而复用；这不是一次新的66手机OTA证明。
- 刚应用更新后的旧页面未刷新回退入口，冷启动后出现且实际回退成功。原现场及失败保留，公开已知问题明确说明。**本闭环提交另外修复旧页面的安装版本／回退状态投影，并通过Full／Play编译和5个既有合同用例；此后续源码尚未进入公开66 APK，留待下一包实测。**
- 65→66增量实际重建为完整APK相同字节。七个公开附件全部匿名完整下载并核对摘要／来源，当前生产解析器和保留的实际Alpha65解析器均发现66完整包、增量及全部已知问题。iOS Latest读回仍为`v1.8.5`。
- 本轮自建技能与来源已通过App移除，没有创建新的聊天测试任务。三星权限／常亮等恢复原值，确认锁屏及屏幕关闭（Samsung Dozing），没有开启自动解锁或模拟器。已用完的暂存、组件宿主和重复打包输出清理，保留当前与必要回退、原故障、源码及符号。

模型继续优先任务Linux命令行和`exec.shell`，图形桌面主要供用户手动使用专业软件；内置轻编辑与Android原生应用交接保留。私有仓库真实账户、全设备恢复、Sony Android9组件故障、早期VNC断连、部分后台／解锁接续及整体UI精修仍按原编号推进。既有iOS增量登记及未对账区间保持，本次不冒充整轮目标关闭或重启全量审计。

Alpha66 is an intermediate delivery on the immutable source above. Physical Samsung qualification covers real public-directory staging, same-version installation, cold reopen and rollback; immediate rollback visibility required a restart. The following source-only snapshot fixes that stale UI projection and compiles for Full/Play, but is not part of the published APK. All seven public asset bytes, the real delta round trip and both current/retained Alpha65 discovery parsers pass. ADB installation, host discovery and phone OTA remain separate evidence. N01–N08 and the explicitly listed limitations remain open.
