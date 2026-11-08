# Android 0.1.0-alpha.62 / code88

本版是 N01–N08 的中间预览，仍有已知问题，欢迎反馈实际使用结果。

- Linux／远程桌面使用一条紧凑工具栏，支持隐藏并通过悬浮入口重新呼出；连接详情、缩放及软件操作收进菜单。特殊按键合并为横滑键栏，调整系统键盘避让，文件返回和失败恢复提示在全屏时仍可见。关闭 Linux 查看器继续只隐藏画面，停止会话单独确认。
- Linux 运行环境准备失败时区分安装文件读取、校验、版本、复制和系统安装等原因，给出对应恢复提示；继续保留取消、权限、签名、版本及摘要检查。Android 9 外测的具体失败环节仍未确认，本版诊断改进不等同于已修复该设备故障，也不要求用户刷机。
- GitHub 浏览下载遇到网关／连接故障时，可使用经验证的官方 API 获取同一资产；自更新与 Office／CAD 组件保留所选镜像、取消和完整性验证。VNC 画面接收与输入写入分别串行处理。

本批 13 项组件诊断／安装策略检查和 Full／Play Kotlin 编译通过；沿用未改变的 37 项更新检查、4 项 BSD socket 宿主检查及 native23 ARM64 生产证据。精确 APK、三星新界面／升级行为和公开发行回执另记。

已知限制：此前图形会话断连的根因尚未确认；已有三星新会话、实际 X11 连接和键盘输入通过仅覆盖各自用例。自动解锁／重新锁屏、部分后台手机控制收尾、间歇性任务导出及全局视觉精修继续推进。当前最低 Android 版本声明为 9，不代表已经在所有旧设备验收。本版不能追溯修改已安装的旧更新器。

---

This intermediate N01–N08 preview still has known issues; feedback from actual use is welcome.

- Linux and remote desktops use one compact toolbar, with a floating restore handle when hidden. Connection details, zoom and application actions move into the options menu. Special keys use one scrolling strip, system-keyboard insets are adjusted, and file-return/recovery notices stay visible in fullscreen. Closing the Linux viewer hides it; stopping its session remains a separate confirmed action.
- Runtime preparation now distinguishes installer read, verification, version, copy and system-install failures with relevant recovery messages. Cancellation, permissions, signer, build and digest checks remain enforced. The reported Android 9 failure has no proven on-device cause yet; improved diagnostics do not certify that device as fixed or require flashing its system.
- If GitHub browser downloads hit gateway or connection failures, a validated official API can retrieve the same asset. Updates and Office/CAD components retain the selected mirror, cancellation and integrity checks. VNC frame reads and input writes use separate serial lanes.

13 focused component diagnostic/admission checks and Full/Play Kotlin compilation passed. Unchanged evidence includes 37 updater checks, 4 real BSD socket host checks and native23 ARM64 production. Exact APK, new Samsung UI/update behavior and public-delivery receipts are recorded separately.

Known limits: the earlier graphics disconnect has no proven root-cause fix. Successful Samsung session, direct X11 and keyboard cases cover those cases only. Automatic unlock/relock, some background phone-control completion, intermittent transcript export and broader visual refinement remain in progress. The declared minimum is Android 9, not acceptance of every older device. This version cannot retroactively repair older installed updaters.
