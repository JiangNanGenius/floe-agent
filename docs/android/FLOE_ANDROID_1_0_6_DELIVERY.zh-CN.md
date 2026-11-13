# Floe Android 1.0.6／114 交付记录

2026-11-14，[Android 1.0.6 预发布](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v1.0.6) 已公开。仅发行自行分发 Full；iOS Latest 保持 `v1.8.21`，没有 Play 构建或其他平台发行变更。

应用源码及不可变标签：`bfcbdda9667aea2000cac2bbe2103bcab31005b5`／`android/v1.0.6`。native52 的实际生产来源仍为 `11c241b9210837bc8eb427924fb559dd0f7dc214`，规范生产输入已与最终应用源逐项绑定。

本版修复普通本地 Linux 任务因未经请求的清理停留在人工审批的问题：命令在执行前可被拒绝，模型继续尝试保留文件的办法；显式删除请求、手动审批、远程目标和停止边界不变。终端说明同步明确实际 POSIX shell、显式目录参数及退出状态。1.0.5 的计划转执行、进度重置、主／子任务成果预览、轻量文本与通知恢复继续保留。

| 交付或验证 | 实际结果 |
| --- | --- |
| Full 安装包 | 166,432,319 字节；SHA-256 `f86fdb8f4f3fe14d0c51e293443f9552d4ac1a016501e36f63099bf2fdb556b6`。 |
| 原生与封装 | 实际 ARM64 对象／链接、Full APK、58 项原生绑定、16 KiB 及 API28／29 主包与运行组件签名通过。 |
| 定向宿主检查 | 首轮实际 24 项为 23 通过／1 个指南大小写匹配失败；仅修该匹配并单项复测通过。生产输入未漂移，原失败保留，零跳过。未改授权模块的五个原用例及 79 项输入证据直接复用。 |
| 三星实际安装 | 正常签名双包覆盖升级至 114，保留原 UID／数据，主包及运行组件实际字节一致。 |
| 新任务与成果 | Ark Plan／`ark-code-latest`，唯一发送、零人工业务接续；两次真实 Linux 命令完成目录与文件校验，发布 14 字节稳定成果并在手机原生预览打开；运行正常结束、队列计数归零。 |
| 原五项功能 | 保留 113 的计划执行、进度重置／子任务隔离、密封成果预览、文本保存重开和通知冷启动证据；没有改称在 114 全部重跑。 |
| 公开交付 | 五附件共 295,698,201 字节，所有匿名完整下载字节、摘要、远端资产与标签均一致，未使用下载备用路由。 |
| 更新发现 | 114／113／108／65 的真实生产解析器从 65／81／1.0.0／1.0.5 发现完整 1.0.6；1.0.6 自身为当前版本，已知问题和校验信息一致。一次微型驱动编译后串行运行，class 已清理。 |

附件仅一个主 APK、Office 与 CAD 按需预览组件、对应源码和 `SHA256SUMS`。本次跨版本下载完整 APK，未附增量包或增量清单，保留原有完整包回退与镜像选择。本次 ADB 安装和公开更新发现不等同于一次新的 OTA 下载／安装验收，原 107→108 在线升级证据继续保留。

完整录像使用同一安装 114 的新项目／新任务进行，尚未通过全部媒体、跨应用与两条日历保存重开验收；不恢复 113 的失败任务，也不将小任务通过记作完整视频完成。没有实际清理请求的小用例不构成设备触发拒绝分支的证据，拒绝与安全替代由真实宿主运行时用例验证。硬件、第三方应用和模型效率的已知限制保留在 Release 中。

源码／许可准备暂存、运行组件临时提取包及确认相同的内部安装副本已退役，保留当前精确产物、必要回滚、符号、生产记录和原始失败。iOS342 的七条变化路径（四条生产／许可、两条工程版本及一条测试）已登记至[增量差异记录](../FLOE_ANDROID_IOS_DELTA_AUDIT.zh-CN.md)，没有引入 VM、重型编辑器、本地模型或双端实时同步。

English: Full1.0.6/code114 is publicly available at immutable source bfcbdda9. Native52 retains its original11c241b provenance with equivalent production inputs. Focused host checks, package/signature checks, a fresh one-send Samsung Linux/output/native-preview task, all five anonymous public assets and current/legacy production update readers passed. Prior113 five-feature evidence, current ADB installation, original failures and pending complete recording remain distinct; no fresh OTA or complete-video success is claimed.
