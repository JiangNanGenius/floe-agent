# Android Alpha50 交付记录

2026-11-08，[Android 0.1.0-alpha.50](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.50) 已公开，code74，固定源码 `c8b3cb027f7b977610e8c9ebf5aa932bde00c064`。Full APK 为164031219字节，SHA-256：`b1dc0a97c34bc26297ccb9dfe78f2b35f70f76f8851f4c37ede8f6bedafc1a3c`。整轮N01–N08继续。

- 首页没有启用的定时任务时隐藏摘要卡片和占位；三星当前包画面已确认。任务中心保留管理入口。
- Office 关闭绑定文档回执、对应引擎退出和实际文件核对；页面关闭共用保存／放弃提示。匹配实现的code73在三星真实编辑DOCX并写回外部原件，放弃另一修改后原件摘要不变；code74释放来源授权后重开工作区副本，保存内容仍在，放弃内容未出现。
- code74手记DOCX实际编辑、保存返回并重开，新增内容同时出现在文档和手记列表预览。原两篇手记保留。本场景不代表XLSX/PPTX或全部恢复分支已验收。
- 对升级前取得的单文件长期授权增加明确确认。code73原失败保留；code74实际移除选中文件的系统持久授权，另一来源授权及两份外部文件摘要保持。正在使用和未完成恢复仍有代码及测试保护。
- Full生产组装、Play Kotlin编译、49项相关JVM测试通过；原生输入不变，复用native14生产证据，58项封装、签名、ARM64/JNI及16KiB检查通过。三星本包为工程联合安装，主程序、Office、CAD和运行环境实际字节及原UID已核对。
- 七附件匿名完整下载、不可变标签来源、实际客户端列表与非空已知问题均已读回；iOS Latest保留 `v1.7.74`。49→50补丁26915927字节，经生产端真实重建验证。完整包支持跨版本升级；本次没有重复未改在线安装实现的设备测试，沿用既有实机证据。
- 临时常亮恢复0，无障碍和无线调试保持关闭；编辑器和自有日志进程已停止。本批没有新增云端模型或媒体生成调用。
- 编译后移除19处重复构件，内置盘实测回收2712883200字节；发布后退役23处成功旧测试包、已导出的源码暂存和提取副本，外置盘实测回收931516416字节。当前包、必要回退、code73原始故障包、原生符号及下一步缓存/SDK/AVD保留。

手机观察间歇失效、系统条件任务、跨项目图形隔离、专业软件保存及全局UI精修继续按原编号推进。没有将这些有限实测扩大成全应用完成。

English: Alpha50 hides the empty Home schedule summary, strengthens Office close/save/discard reconciliation, and explicitly releases selected persistent file access across upgrades while retaining live-consumer and recovery gates. Samsung verified Notes DOCX save/return/reopen, saved content in the Notes library, actual grant removal, preserved external files and reopening the Core copy. Full production, Play Kotlin, 49 focused tests and package checks passed. All seven public downloads and update discovery were read back; iOS Latest is preserved. The 49-to-50 delta reconstructs the exact code74 package. This engineering installation is separate from earlier unchanged in-App update evidence. Settings were restored, owned processes stopped, and expired successful packages/staging removed. The full N01–N08 goal remains active.
