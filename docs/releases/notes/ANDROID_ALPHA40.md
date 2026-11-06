# Android 0.1.0-alpha.40

CAD／三维预览组件替换时保留上一份缓存；新目录提交失败会恢复，进程中断后可在再次使用时继续恢复。卸载同步清除回退目录，避免重启后恢复已卸载的组件。空间统计包括回退与未完成缓存，提供清理入口，用户文档独立保留。

取消下载显示真实停止状态，网络关闭在后台执行；恢复、清理、卸载失败分别提示。文件系统故障、取消、重启状态及卸载的10项定向检查通过，构建前尚未完成本包三星下载和离线预览实测。

## Known issues / 已知问题

这是 N01–N08 中间版本。三星实际下载取消、CAD按需安装／离线打开及卸载仍待本包验收；没有将源码和JVM检查当作设备通过。手机多步自动化、条件触发、跨项目隔离及其他既定场景继续推进。手机自动控制同意不改变任务审批模式；手机验收须先核对自动审批及已配置审批模型。本轮不重放付费图片／视频生成。

## English

CAD/3D preview installation retains the previous component until directory promotion finishes. Failed promotion restores it, and interrupted swaps recover on the next use. Uninstall removes fallback directories so they cannot resurrect after restart. Usage includes retained and partial caches, with a cleanup entry; user documents remain separate.

Download cancellation reports the real stopping state and closes network responses off the UI thread. Restore, cleanup and uninstall failures have distinct messages. Ten focused filesystem cases passed; Samsung download and offline-preview acceptance is pending at source freeze.

This is an intermediate N01–N08 build. Device cancellation, on-demand CAD installation, offline reopening and uninstall still require acceptance. Phone multi-step automation, system conditions, project isolation and other agreed flows continue. Phone consent does not replace task approval policy; verify automatic approval and its configured review model before phone acceptance. No paid image/video generation is replayed.
