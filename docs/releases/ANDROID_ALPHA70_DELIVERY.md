# Android Alpha70 / code96

修复Android 9／10读取安装包签名时未触发系统证书收集的问题，覆盖Linux运行组件安装及在线更新校验。继续以当前签名证书校验身份，不使用旧证书数组或跳过校验。索尼XZ的Alpha69报障已明确为`COMPONENT_CERTIFICATE_UNAVAILABLE`；修复后的索尼实机反馈仍待确认。

Fix Android 9/10 archive signing queries that did not trigger certificate collection,covering Linux component installation and online updates.Identity remains checked against current signing certificates.The Sony XZ Alpha69 report identifies `COMPONENT_CERTIFICATE_UNAVAILABLE`;updated Sony hardware behavior remains unverified.

等待用户回答时退出进程，继续任务会恢复原问题和原运行编号；不重新提问、不重放工具。恢复的答案或失败结果同时写入任务记录，避免任务已经结束而工具卡片仍停在等待中。

继续等待项时使用该项实际所属运行，不从尚未刷新的选中状态取编号。继续后关闭连续性弹窗，使问题或实际错误可见。应用启动已授权手机App时，工具说明引导使用原有的即时导航检查路径，保留旧观察和权限拒绝。

After process death during a required question,Continue reattaches the original persisted request and run instead of reissuing a question or tool action.Recovered answers and failures enter the task timeline.The wait action targets its actual owning run and closes the overlay so the question or real refusal remains visible.Existing phone-launch navigation,observation freshness and authorization checks remain authoritative.

## Known issues / 已知问题

- 中间版本；N01–N08整体尚未结束。自动解锁／条件重新锁屏、部分后台跨App接续、原VNC故障及全局UI精修继续推进。
- 本版完整App恢复及重启后指南隔离尚待三星实测；4项真实运行时／SQLite检查、1项运行归属JVM检查不等同设备通过。Alpha69的原始提问恢复失败保持独立记录。
- 索尼Android9的Alpha69组件签名读取修复仍待新包实机反馈；不以三星或宿主结果代替索尼验收。
- 部分远端签名指南含iOS内容；继续保留签名、平台及权限校验，用户配置的兼容服务正常开放。

- Intermediate build: automatic unlock/relock,some background cross-App continuation,the earlier VNC issue and whole-App visual refinement remain open.
- Full-App recovery and post-restart guide isolation await Samsung qualification.The four runtime/SQLite cases and one exact-run JVM case do not establish device acceptance.The original Alpha69 failure remains preserved.
- Sony Android9 component signing recovery still needs updated-device feedback.
- Some signed remote guides contain iOS-specific content.Signature,platform and permission checks remain;compatible user-configured services stay available.

准备记录：选择未占用的Alpha70/code96，同步Office对应源码入口及摘要。实际ARM64生产、Full／Play编译、最终包、设备与公开交付随后独立记录；本文件不单独表示已发版。

Preparation: Alpha70/code96 and its matching Office source offer are selected.Native production,Full/Play compilation,actual APK,device behavior and public delivery remain separate evidence.This file alone is not publication proof.

## Delivery evidence / 交付记录

已公开于[Android Alpha70](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.70)，不可变源码`84c5b00b327a3fbd90cc32c5ecbb59b50a538fb0`。一个Full APK、Office／CAD按需组件、69→70增量、更新清单、摘要和对应源码共七附件，已完整匿名读回；APK SHA-256为`41efe3509fee2ba84398dc7121cb0b603895c61391e8adbf6b403d2614962353`，iOS Latest保持`v1.8.6`。

4项实际运行时／SQLite、1项运行归属与10项签名检查通过；未改79项文件／诊断及29项身份／安装策略复用精确源码证据。实际ARM64生产、Full／Play Kotlin编译、58项封装、主包与运行组件API28／29签名验证、真实69→70重建及当前／保留Alpha65生产发现解析均通过。原打包预检／磁盘中止及早期夹具失败保持独立证据。

**Android9／10旧版在线更新若仍报签名不可用，请下载本Release的完整APK覆盖安装一次，无需卸载。** 三星仍装实际Alpha69/code95，本版设备OTA与提问恢复未验收；索尼Android9修复后实机反馈亦待确认，不以模拟器或宿主代替。已导出生产回执并清理22处本版重复构件／完成暂存，SDK、AVD、源码、符号、当前及必要回滚保持。

Published with seven exact anonymous-read-back assets on the immutable source above; iOS Latest remains unchanged.Four runtime/SQLite,one run-ownership and ten signing cases passed.Unchanged79 filesystem and29 policy cases were reused by exact inputs.ARM64 production,Full/Play compilation,58 package checks,API28/29 App/runtime signatures,actual69→70 reconstruction and current/retained Alpha65 discovery passed.Original failed attempts remain recorded.

**If Android9/10’s old updater still reports unavailable signing information,install the full APK over the existing app once without uninstalling.** Samsung remains on actual Alpha69;70 OTA and question-recovery behavior are pending,as is Sony hardware feedback.Completed duplicate outputs and staging were cleaned after exporting receipts;source,symbols,current/rollback packages and SDK/AVD are retained.
