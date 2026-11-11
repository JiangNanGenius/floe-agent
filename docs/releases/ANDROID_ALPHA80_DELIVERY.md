# Android Alpha80 / code106

## Source preparation / 源码准备

本中间版准备自行分发的 Full ARM64 包，未在此检查点宣称已构建、已发布或已通过全轮验收。仅发行 Full，不推进 Play；最终 1.0.0 等 N01–N08 的既定收尾完成后再提升。

This intermediate candidate prepares the independently distributed Full ARM64 APK. This source checkpoint is not a build, publication or whole-round acceptance claim. Play remains discontinued; final1.0.0 follows the agreed N01–N08 closure.

## Changes / 改动

- ADB：应用安装、覆盖更新、批量卸载、所选应用的启停、权限及 AppOps、设备设置沿现有授权工作。系统应用按用户移除默认保留数据，恢复可识别已移除的系统映像。UID 范围使用同一总开关、类别及目标多选，不添加重复权限开关。
- Linux：修正 Android 不可用的空间查询 API，保留事务快照、空间下限及回滚约束；热资源同步轮询解开真实 IPC 回执，持续终端不必重开。
- 回执：保留应用级、UID 级和有效模式的区别；追加修改前后字段及缺失值说明，供模型按原范围恢复。
- 界面：手机设置压缩状态／动作和说明占位；待安装 APK 在二级页面显示名称、大小和包名，路径及摘要在详情内查看。

ADB app management retains existing authorization and selected targets, with keep-data system-app removal, real restoration and UID-scoped AppOps. Linux fixes portable transaction space checks and live-resource receipt polling without restarting the terminal. Receipts preserve separate package/UID/effective modes and restoration metadata. Phone settings use compact status/action rows and a staged-APK child sheet with opened diagnostics.

## Existing physical evidence / 已有实机证据

工程候选06／07分别绑定源码3049602c9／25f569a84，仍为code105，不能冒充本版code106安装字节：

- E2：91条原始记录、6项系统回执；真实移除／恢复，UID、版本、默认启用和非零CE目录inode保持。目录元数据保持不等于内容备份；E1的原失败及旧路径数据清理记录保留。
- A6：108条原始记录、13项成功结果；在真实任务 Linux 安装curl与CA、下载并校验两份APK、从工作区暂存、安装、卸载及独立确认消失。4项自动审批，没有人工确认。
- C2：158条原始记录、9项系统回执；UID模式修改／同范围恢复及应用层覆盖保持通过。旧摘要遗漏前后字段已保留为缺口，本版源码补齐，不倒填为旧合同通过。
- R4：93条原始记录；同一PTY热加载Office并读回原PDF，完整捕获的内容与去除动态交付说明的指南正文一致，只关闭一次。指南没有结尾换行，结束标记拼在末句的格式偏差保留，不当作热同步失败。

These private code105 candidates provide actual system-app restoration, Linux-to-APK installation/removal, UID-mode restoration and same-PTY hot-resource evidence. Their exact sources/bytes remain distinct from code106. C2's missing summary fields are a retained follow-up; R4's end-marker formatting is separately recorded from its exact guide-content proof.

## Remaining / 仍待完成

本版新UI、摘要字段、code106生产包、真实升级和公开附件／发现读回仍待执行。R4冷启动命令准备约57秒，未宣称解决首命令性能。自动解锁／结束重锁、跨App编辑保存、其余定时／恢复组合和整体UI精修继续按原编号推进；本中间版不关闭总目标。保留当前／回滚包、原失败及符号，发布保持当时的iOS Latest。

The new UI/summary fields, actual code106 package, upgrade and public read-back remain pending. R4 still measured roughly57 seconds of cold command preparation; no startup-performance fix is claimed. Unlock/relock, cross-app saves, remaining scheduling/recovery combinations and broader visual refinement remain open. Preserve recovery/evidence/symbols and the contemporaneous iOS Latest.
