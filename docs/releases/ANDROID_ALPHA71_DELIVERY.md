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

## 2026-11-09 交付读回 / Delivery read-back

- 固定源码 `e9f94bd602efda39be91a39e4486bf60abc578ee`，Full APK：164629419字节，SHA-256 `ce6019cf08ff0480577a47f37b9de9b0e3e5b0f15e59ce767631e87a2e6d25ff`。未修改已发布70或本版冻结标签。
- Full／Play及运行组件Kotlin编译通过；32项聚焦用例通过，包含组件交接3、安装策略10、进度计量6、归档进度／完整性3、解锁生命周期10。原始测试导入编译失败保留，修正导入后实际执行；没有跳过或放宽断言。
- 复用输入相同的native33，58项实际原生库字节绑定和发布包检查通过；主包及嵌入运行组件均通过API28／29签名验证。签名验证不等于索尼实机行为验收。
- [公开预发布](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.71)七附件已逐一匿名下载校验；70→71增量真实重建并与完整包一致。当前及保留65生产更新发现器实际读回本版和已知问题；iOS Latest保持。
- 22处已完成构建副本／源码和增量暂存已清理，8份生产回执先导出；内置盘删除窗口实测增加3191689216字节。当前／回退包、原始故障、源码、符号及SDK／AVD保留；旧暂存路径不可盲目重跑。
- 三星已通过实际70客户端在线升级，正常确认两包并经Play保护扫描安全后完成；主应用／运行组件均为97，安装字节与公开包完全一致，原UID保持。重开显示更新已安装，原5个任务／2个项目可见，本地环境弹窗正常显示已安装。未捕获设备实际传输模式，不将宿主增量重建当成手机增量证据；已有环境检查不等于全新下载或索尼实机通过。自动解锁与索尼反馈仍待完成，整轮N01–N08继续。

Exact-source Full APK,32 focused tests,Full/Play/runtime compilation,native binding,API28/29 signatures,seven anonymous public downloads,70→71 reconstruction and current/legacy discovery passed.Real Samsung70→71 OTA,exact package bytes/UIDs,baseline task/project visibility and existing-environment settings passed.Fresh installation and unlock checks remain separate.Sony feedback remains open.N01–N08 is active.
