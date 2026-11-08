# Android Alpha65 交付

[0.1.0-alpha.65／code91](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.65)已作为Android中间预发布交付，固定源码`729812f2a29ba1842b6594def5ad3cc30a07abfe`。七附件完整公开字节、不可变标签及实际生产更新解析器已读回，iOS Latest保持独立。实际结果在冻结后追加，不移动原标签或替换原包。

主包164,432,267字节，SHA-256：`e428ecfb181d7e4c96dfa220cb7e60955c9f27065a61cb1d49fd6d18418f8326`。

完整任务导出使用系统文件保存窗口，直接选择位置保存JSONL，无需借助第三方分享应用。沿用现有C07任务导出，保留工具结果、事件和成果引用；逐块写入后重新读取目标，字节和摘要一致才显示保存成功。文本与Markdown分享保持原有通路。

保存工作由App持有，并绑定原任务、会话和运行时；Activity重建不重复打开窗口，取消后的旧结果不能写入下一任务。进程退出后不从旧URI猜测任务或冒报成功，原任务保留，可以重新导出。失败不删除不确定的用户目标文件，生成的缓存沿用已有期限和容量限制。

Full／Play Kotlin及14项相关JVM检查通过，包括8项新保存／回调检查和6项原有真实导出协议检查。精确Full APK和同源Office/CAD组件已生产，58项封装／签名／16KiB检查通过，复用输入未变的native24。64→65真实增量重建出精确目标；本轮没有据此声明设备增量执行通过。

三星明确点击“下载完整更新”后，出现真实非零进度、完成校验并通过系统安装器联合更新主应用和运行环境至code91，两个UID及精确安装摘要匹配。既有五条对话、两个项目保留。Play保护的本次扫描选择与系统认证分别处理，没有全局关闭系统保护，也没有使用adb安装。

系统文件保存、取消后再次导出，以及选择位置时旋转屏幕后Activity实际销毁／重建均通过。实际保存的14,458字节JSONL已读回，原任务、运行ID和真实工具输出一致；不需要第三方分享应用，没有新增模型调用。进程退出、其他文件提供商和撤权组合未据此宣称通过。

测试任务和本次导出副本已清理，另按既存私有副本的精确字节／摘要删除六份过期设备导出。累计退役84个自建任务（三星37、模拟器47）及12个旧计划，原有记录与项目保持。手机旋转、常亮、权限恢复并休眠，未启动模拟器。21处完成构件／源码／增量暂存已退役，生产根级回执先保存；内置该删除窗口可用空间增加3,177,865,216字节，当前包、回退、符号和原失败保持。

模型继续优先用任务Linux的命令行；桌面主要供用户手动操作专业软件。本包不宣称已修复索尼Android9、原VNC断连、自动解锁、部分后台收尾、私有连接器及全局UI问题，整轮N01–N08继续。

English: Alpha65/code91 is published from immutable source729812f2,with seven public byte and production-feed read-backs;iOS Latest remains independent.Full/Play Kotlin,14 focused JVM cases and58 package checks pass,reusing unchanged native24.The real64-to65 patch reconstructs the exact target;device delta execution is not claimed.Samsung's explicit full-update button completed download,verification and joint App/runtime installation to91 with exact identities and data retained.Direct system-document save,cancel/reopen and actual Activity recreation during the picker pass;the14,458-byte transcript and original task/tool results were read back.No new model call was made.Own test data and exact duplicate exports were removed,settings restored and the phone left asleep.Process death,other providers and existing broader gaps remain open;N01–N08 stays active.
