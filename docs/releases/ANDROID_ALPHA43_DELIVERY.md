# Android Alpha43 交付记录

2026-11-07，[Android 0.1.0-alpha.43](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.43) 已公开。版本为 code62，固定源码 `c78b3e166c6bd2409115666af3f8d1b642f56436`，主 APK SHA-256 为 `411b26a40ef96784d9d6430e95119be52fc552a6880cb7d69be5ca5937a70419`。

## 本包变化与验证

- 手机工具在审批后重新发现当前任务的真实接管问题；保持人工确认及任务、运行、会话代次和停止边界。
- 补齐预绑空任务的首次审批模式事务保存，仅更新模式与时间戳，不扩大其他权限；11 项策略回归包含真实 GRDB 迁移、事务回滚、已用任务不覆盖及解码／接线检查，不全部属于数据库行为测试。
- 手机设置中长模型名称与标题共享宽度，保留字体缩放、完整无障碍文案及平板原布局。
- 实际 Full APK、Play Kotlin 编译、2 项会话 JVM 检查和 ARM64 Swift 对象／链接通过。原生打包逐项核对 58 行，签名及 16 KiB 对齐检查通过。首轮 Cupertino 空插槽类型错误的失败记录保留，修复后才生成当前包。

## 三星实际结果与未完成项

同一份主包与运行时通过私有 ADB 联合安装，安装字节和 UID 核对一致，原任务及配置保留。默认字号侧栏和 1.3 倍字体、深色模式的长值排版通过本包检查；平板布局复用未改的 Alpha42 界面参考。

仅运行一次新的 Ark Plan／`ark-code-latest` 任务。接管问题正常出现，提交确认后 Agent 启动指定计算器成功。原始事件中，启动成功在序号 17，唯一一次后续观察在序号 26 被审批理由误判拒绝；计算没有完成，观察工具没有重试，提供商未切换。任务以明确失败说明结束，旧暂停任务未恢复。测试服务、应用选择、临时审批模型、字体、主题和常亮设置已恢复。

首次发送前明确选择“自动允许”后，运行结束仍显示“每次询问”，这条完整入口未验收。Alpha42 的选中界面与本包数据库测试均不能替代首轮实际策略／投影验证。下一批先查清首页、启动、冻结策略和投影的断点，再判断审批上下文缺口的修复范围；连贯代码收齐后统一编译，不为每个小改动重建 APK。

## 更新、公开读回与清理

Alpha42/code61→Alpha43/code62 补丁为 66820591 字节，已实际重建目标字节；完整 APK 为 163888847 字节。三星这次私有安装不作为在线升级证明，既有 Alpha37 完整包及 Alpha36 增量安装证据继续分开保留。

六附件匿名下载的字节、摘要、标签来源与更新发现已读回。发布说明开头列出两项实际问题；iOS Latest 仍为 `v1.7.74`。附件仅包含一个主安装包、按需 Office 组件、增量及必要校验／更新／许可源码文件。

本轮清理实测释放 4148121600 字节：13 处旧安装产物、19 处构建暂存、6 个打包目录，并合并 11 处完全相同的副本。保留 Alpha43、Alpha42 回滚、独立失败候选、符号与原始证据，以及紧接的权限／审批修复需要的缓存。旧安装产物保留公开恢复摘要与链接，不删除不可恢复的失败材料。

N01–N08 整轮继续，手机多步任务、条件触发、项目隔离、CAD 其余场景及全局界面精修不因本包公开而销账。

English: Alpha43 is an intermediate prerelease. Physical Samsung evidence confirms handover and calculator launch, followed by one denied observation; the requested calculation did not complete. The first-send approval display still reverts to Ask. These limits lead the public release body. Package checks, exact public bytes and update discovery passed independently; neither the private ADB install nor reused tablet UI evidence is treated as new online-upgrade or whole-goal acceptance.
