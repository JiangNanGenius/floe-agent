# Floe Agent 1.8.24（345）交付与设备核对

2026-11-14（悉尼）已完成内部 TestFlight、正常 GitHub stable/latest 和 awaited Feather 交付。冻结源为 `663b1f8b78556c82d1112f01ef50d1d0c2105a34`，不可变标签为 `v1.8.24`，annotated tag object 为 `9d7bffc1780cc53a1f7bf78e6df192d819527a18`。后续文档和 Android 提交未进入这个冻结来源。

本版包含历史盘完整内容恢复与重新整理、字体单副本、旧组件退役、iCloud 设置补漏、以终端及作业为主的 Linux 清理流程，以及现代图片工作台修复。渠道交付已通过；M4 实际容量回收仍未通过验收。

## 已核验交付

| 渠道 | 真实结果 |
| --- | --- |
| 内部 TestFlight | [同源原产物签名上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/43538471103)成功；[独立 Apple GET](https://github.com/JiangNanGenius/floe-agent/actions/runs/43541088705)确认 `VALID`、未过期，既有 Floe QA 为 `IN_BETA_TESTING` |
| GitHub | [正常 unsigned 发布及 awaited Feather](https://github.com/JiangNanGenius/floe-agent/actions/runs/43541546475)通过；实际安装包的来源、摘要、大小、版本及 stable/latest 严格读回一致 |
| Feather | 在线更新源匹配同一个 345 unsigned IPA；实际 awaited workflow 成功 |
| M4 iPad | 经 TestFlight 安装，CoreDevice 独立确认 1.8.24（345）；安装与容量回收分别记录 |

[unsigned 安装包](https://github.com/JiangNanGenius/floe-agent/releases/download/v1.8.24/Floe-Agent-1.8.24-build345-unsigned.ipa)为 **649,692,748 字节**，SHA-256 为 `965c88d843085891470763df10f8d05ad90458562c627d6a6be153ef68f40326`，需要自行签名。实际 TestFlight signed IPA 为 649,839,484 字节，SHA-256 为 `97c9fa20b81ced65e571f472f029932f781e9828fdd31ccd16fbbd46d4649ad3`。

本线程未提交公开 TestFlight 或正式 App Store；既有正式版本和撤回的公开版本保持原安排。

## 构建与定向验证

本机 Xcode 27.2（27B52）／iOS SDK 27.2 完成实际 iphoneos Release 归档，6 个编译任务，用时 1,361.995 秒。受影响的三个 Core Swift 对象及一个 C 编译单元实际编译，App 链接和冻结来源已绑定；App 与 19 份符号在可选后续步骤前独立保存。严格封装、五个 App／扩展版本、隐私与原生依赖校验通过。真实 signed IPA 的 App UUID、Wi-Fi 授权和 production 推送配置与保全产物匹配。

容量修复在合并后 232 源的生产组件闭包中真实编译、链接并通过 4 项方法，跳过 0。完整 Simulator App 及测试对象编译和严格封装通过；63 个定向 App 方法按 62＋1 两批实际通过，跳过 0，覆盖 Linux 24、图片 6、字体 2、同步及直接受影响设置 23、退役工具 8。原始失败和纠正证据保留，没有重复运行已经通过的 62 项。

指定的既有 iPad 模拟器实际打开现代图片工作台，工具、图层、属性、导出入口及完整画布布局已核对；未进行手动绘画或导出。该模拟器已经关闭。组件和模拟器证据不替代物理语音、真实 Linux 客户机或跨设备 Keychain 验收。

## 实际软件包瘦身

同一审计口径的 raw App ZIP 从 343 的 916,562,211 字节降至 345 的 648,007,734 字节，减少 **268,554,477 字节**。展开文件合计减少 **377,792,626 字节**。23 份重复字体已去重，字体内容与许可证保留；活跃工程预览字体和其他有效引擎字体保留。

以上是软件包的实际变化，不是 iPad 用户数据回收，也不把 raw ZIP 与最终 signed／unsigned IPA 混为同一产物。

## M4 容量与后续限制

升级前后 13 份恢复盘的相对路径和逻辑大小逐项一致，总逻辑大小 223,338,299,392 字节；未复制盘体或删除旧资料。逻辑大小不等于独占分配或可回收容量。

安装后的独立 AFC 剩余空间读数为 185,781,760,000 字节，后续整理前基线为 183,189,311,488 字节；读数跨越了其他分配活动，不能据此认定安装或整理的净收益。

本次界面仍显示旧 343 的 `blocked / recovery-pending` 回执，原开始／结束时间、attempted=0 和 fileAllocationReduction=0 未变。一次界面操作实际展开了详情，**没有产生新的 345 整理调用或结果**。因此既不能把旧错误记作新 345 失败，也不能宣布新容量修复已通过。338 的历史 124,848,209,920 字节收益不重复计算。

设备已归还用户，Device Hub 已停止屏幕查看，键盘捕获为 0 且禁用。真实 Linux 终端清理／无模型回退、跨设备设置与 Keychain 到达，以及 M4 新一轮实际整理仍待各自验证。新增反馈“字体作品缺少删除入口”和“字体管理漏列内置字体”进入后续修复，不改 345 来源、标签或产物。

<!-- docs-updated: 2026-11-14 -->
