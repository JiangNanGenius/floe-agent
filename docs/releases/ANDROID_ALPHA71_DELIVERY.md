# Android Alpha71 / code97

环境组件安装回调按真实系统会话和App版本处理；提交安装与回调串行交接，旧安装的取消不再覆盖新确认。确认入口在等待期间保留，可查看Android安装窗口中的确认／安全扫描，也可取消本次安装。

环境准备显示真实阶段、下载百分比、处理大小和测得速度；解压显示已处理项数及字节。未知总量不伪造百分比；低速连接也持续更新收到的字节，失败保留真实阶段和计数。进度属于应用服务，关闭设置弹窗不取消操作。

自动解锁的任务取消路径会清除待输入凭据，并观察可能稍后完成的系统解锁；仅本任务仍持有手机时收尾重锁。重锁使用真实系统状态回执，拒绝／超时提示手动处理；用户接管后停止重锁。任务结束同时释放真实控制占用，避免下一任务一直繁忙。

Runtime installation callbacks are scoped to the exact OS session and App build.The commit-to-UI handoff is serialized;old cancellation cannot replace current confirmation.The installation window remains reachable for Android confirmation/scanning,and the current installation can be cancelled.

Environment setup shows real stages,transfer percentage,bytes and measured rate,with extraction item/byte counts.Unknown totals do not invent percentages.Low-speed transfers update real counters,and failures retain their stage/counts.Closing the settings sheet does not cancel service-owned work.

Task-owned unlock cancellation wipes pending input and settles a possibly delayed system transition.Relocking requires retained ownership and an observed system result;user takeover stops it.Task termination also releases the real phone-control fence.

## Known issues / 已知问题

- 中间版本；N01–N08整体尚未完成。索尼Android9此次安装／准备修复仍待更新后的实机反馈，不能以三星或宿主代替。
- 自动解锁／重锁及本版新进度的完整设备流程待实测；过程死亡后的指南隔离、部分后台跨App接续、原VNC故障和全局UI精修继续推进。
- Android9／10旧版若仍在在线更新时报签名不可用，可从本Release下载完整APK覆盖安装，无需卸载。

- Intermediate build;Sony Android9 installation/setup recovery still needs updated hardware feedback.
- Full-device unlock/relock and setup-progress flows are pending.Process-death guide isolation,some background cross-App continuation,the earlier VNC issue and global visual refinement remain open.
- If an older Android9/10 updater reports missing signing information,install this Release’s full APK over the existing app without uninstalling.

准备记录：选择Alpha71/code97，Office对应源码入口与摘要同步；复用输入完全相同的native33。N02已有9项真实组件用例及Full／Play消费者编译，新增环境回调／计量／下载完整性检查与最终APK随后独立记录。本文件不单独代表已发版或设备通过。

Preparation: Alpha71/code97 and matching source offers are selected.Native33 inputs are unchanged.Nine N02 cases and Full/Play consumer compilation exist;new setup checks,final APK and actual delivery/device results are recorded separately.This file alone is not publication proof.
