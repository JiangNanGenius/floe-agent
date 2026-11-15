# Floe Android 1.0.14（123）交付记录

2026-11-16，独立分发 Full 预发布已公开：[Android 1.0.14](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v1.0.14)。iOS Latest 保留。

- 不可变源码：`61e4a67d1fdb116fd235284e03179d1318367743`，标签 `android/v1.0.14`。
- ARM64 APK：`Floe-Android-1.0.14-full-arm64-v8a.apk`，166,915,491字节。
- SHA-256：`c9825484ebb0a4cc3170d3250819d21c3014f779567e378653d1b6edfb7e61f7`。
- 附件共五个：一个主安装包、按需 Office/CAD 组件、对应源码和 SHA256SUMS，总计296,181,507字节。本版不提供增量包；保留完整包更新和镜像选择。

后台命令省略超时时改用既有后台预算，显式短超时和前台上限不变；超时与主动停止保留不同原因。当前任务的作业查看、取消、等待停止及原运行接续已接通。手机等待栏与作业弹窗更紧凑；控制停止、任务结束和驱动不可用时清理浮球，展开面板保持四秒自动收起。

实际 Swift6 生产对象与16项定向测试、相关 Kotlin 生产对象与21项 JVM 测试通过。使用新构建的 native62 生成同源 Full APK；58项原生绑定检查包含50项实际封装库及8项明确排除的 SDK 测试库，16KiB封装和四包 API28–29签名检查通过。未改变组件复用先前证据；不声称新增16KiB设备运行时验收。

三星 Android13 已安装精确候选并独立读回安装字节、摘要和保留的 UID。真实必需后台命令运行超过10秒后完成，任务经一条持久系统通知在同一原运行自动接续，未点击继续。模型随后仍仅回复等待，没有交付要求的文件；因此完整成果目标未通过，不以原生接续通过替代。

真实可见浮球展开后约四秒收起；重新打开并点击接管，首次227毫秒采样中，两个浮窗和一条控制通知全部归零，无障碍服务当时仍开启，随后无晚回浮球。此项是控制呈现与停止验收，未计作计算器业务流程完成。旧自然长任务没有继续；在后续独立停止之后，实际读取其27项后台作业均为终态，原失败结论保留。

五个公开附件均完成匿名全字节下载与摘要核对；当前123、历史122及 Alpha65的实际生产更新器，合计12个安装版本样本，验证旧版发现完整包、当前版不重复升级及已知问题展示。覆盖安装和公开解析不等于新一轮应用内 OTA 安装验收。

复杂长任务、模型工具与应用选择、跨 App 成果交付、常驻服务及完整容器回收继续迭代；部分终态作业可能保留上一次进度阶段标签。完整自然目标录像另行推进。测试权限、浮球、自动控制、目标应用及电源基线已恢复；未保存锁屏凭据。已清理结束与过期打包暂存和四份精确核验的手机导出副本，保留当前、回滚、符号和原始失败证据。

English: Full1.0.14/code123 is publicly available from the immutable source above. All five public assets and twelve installed-version samples across three actual production updater readers passed read-back. Samsung verified required background work beyond ten seconds, automatic same-run continuation, real floating-panel collapse and control teardown while Accessibility remained enabled. The model did not deliver the requested file, so that complete goal and the natural recording remain unaccepted. New in-app OTA installation and16KiB runtime behavior are not claimed.
