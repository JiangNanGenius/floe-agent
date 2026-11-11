# Android Alpha80 / code106

## Delivery / 交付

[Alpha80/code106 已公开](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.80)，固定 App 源码 `ee2057c91872abd31044bd3e0b9e4be38fcd9f85`。仅分发 Full ARM64，Android 预发布不替换 iOS Latest；1.0.0 等整轮既定功能验收后再提升。该标签与已发布安装包保持不变。

Alpha80/code106 is public from the immutable source above. Only Full ARM64 is distributed, preserving the iOS Latest pointer. Final1.0.0 still follows the agreed whole-round verification; this tag/package is unchanged.

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

## Production and physical delivery / 生产及实机交付

- 实际 Full 构建通过（4分20秒）；精确复用 native40，58项原生封装、ARM64/16KiB、API28/29签名和对应源码／许可校验通过。源码绑定清单原先仍指向79的失败保留，已修正匹配80后正常生产，未放宽校验。
- 79→80增量真实重建通过；七附件的匿名下载字节、不可变标签、新生产客户端及保留的65客户端更新发现分别读回通过。App／运行组件实际符号与native40未裁剪库保存，公开附件维持一个APK和必要组件／校验／更新／源码文件。
- 三星由code105工程候选经App的GH-Proxy完整包更新至106，主App与Linux运行组件的实际安装摘要、原UID均匹配。该工程基包与公开79不同，不冒充手机增量重建；主机增量证据单列。两项系统确认和运行组件的系统扫描均完成，可选Office/CAD旧split按提示退役，用户文档保留。
- 原5条任务、2个项目保留；手机设置的状态／动作同行、详情折叠及APK二级页实际可达，打开摘要后完成移除并回到父页的0项状态。复用保存的配对启动服务，实际显示UID2000；AS与Root保持关闭，未设置解锁凭据。这不是全应用视觉或UID修改的新包验收。
- 本轮7条自建任务、下载目录5个自建APK和5项暂存清理完毕；后者包含3个校验后删除并确认路径消失的共享暂存文件，以及2个已退役A6任务的工作区引用，未从相对引用推定设备路径。清理6处完成产物，保存8份生产回执；当前／必要回滚、符号、原失败、SDK/AVD及下一明确用途缓存保留。未启动模拟器。

Actual Full production, exact native40/package/source/signature checks,79-to80 host reconstruction and all seven anonymous download bytes passed. Current and retained65 clients discover80. Samsung completed the real engineering105-to-public106 in-App joint full update, preserving exact main/runtime bytes, UIDs, five original tasks and two projects. Optional preview splits reinstall on demand. Compact Phone controls, the staged-APK child page, details/removal/parent return and saved-pairing service startup were observed. This is not an on-device delta, whole-App visual or new UID-mutation claim. Owned task/download/staging residue and six completed output areas were retired; required artifacts, symbols and original failures remain.

## Remaining / 仍待完成

自动解锁／结束重锁、跨App编辑保存、Linux图形与文件接力及其余定时／恢复组合继续。冷启动准备仍可能约57秒。新的ADB服务会话虽显示UID2000，UID范围权限提示仍要求重启，继续核对实时能力刷新与实际通路，不销账为平台不支持。新摘要字段已编译，但不倒填C2旧回执合同通过。

用户已确认保留当前整体美术和布局，界面后续仅做局部修整。完成／圆形工具按钮默认外圈描边已在后续主线取消，实际设计系统Release编译通过；底色、形状、语义及48dp点击范围保持。该小修尚不在已冻结80包中，随下一批APK交付，不为它重跑未改组件矩阵。N01–N08总目标继续。

Unlock/relock, cross-App saves, Linux graphics/file return and remaining schedule/recovery combinations stay open, as does roughly57-second cold preparation. The fresh ADB session's UID capability hint needs live-peer/refresh verification; no missing implementation is called unsupported. The new summary fields are compiled, without backfilling C2's old contract. The user approved the overall visual direction: keep it and make small refinements. A subsequent source-only change removes default sheet-action/round-button outlines while retaining fills, shapes, semantics and48dp targets; its real Release design-system compilation passes. It is not in frozen80 and will ship with the next coherent batch. The whole goal remains active.
