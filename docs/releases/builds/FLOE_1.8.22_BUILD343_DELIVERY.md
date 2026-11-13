# Floe Agent 1.8.22（343）交付与真机记录

2026-11-14（悉尼）完成内部TestFlight、正常GitHub stable/latest及awaited Feather交付。冻结源为 `53c3b83625ec5f8e94690ae15f5a0f3881f85589`，不可变标签为 `v1.8.22`，annotated tag object为 `9f579aadf5dba84624b004a0e47f0992193e8ef6`。后续交付文档与Android提交未进入该冻结源。

本次修复更新后整理服务无法启动：仅有原生关闭回执、没有未完成intent的命名空间，先前被当成未知历史。现在以有界文件读取、原根身份与回执契约验证这些记录；该命名空间仍加入全历史锁集合，并在持锁后重验。旧回执不替代当前运行权限，原盘、引用、伴随元数据和未完成作业的保护保持。

## 已核验交付

| 渠道 | 真实结果 |
| --- | --- |
| 内部TestFlight | [同一原产物签名上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/43478548059)成功；[独立Apple GET](https://github.com/JiangNanGenius/floe-agent/actions/runs/43483085373)确认 `VALID`、未过期、既有Floe QA为 `IN_BETA_TESTING` |
| GitHub | [正常unsigned producer及awaited Feather](https://github.com/JiangNanGenius/floe-agent/actions/runs/43483448749)通过；实际下载、来源、摘要、大小、版本与stable/latest严格读回一致 |
| Feather | 在线当前版本与旧客户端头部均为343，来源、下载地址、大小和摘要与真实安装包一致；main的单独Feather提交已fast-forward接回 |
| M4 iPad | 通过真实TestFlight更新；CoreDevice独立确认1.8.22（343）。启动问题已修复，实际整理仍受下一项恢复检查阻断，容量未结项 |

[unsigned安装包](https://github.com/JiangNanGenius/floe-agent/releases/download/v1.8.22/Floe-Agent-1.8.22-build343-unsigned.ipa)为918,244,256字节，SHA-256为 `feb7320b22ead22648da21a01fd211e8b811f8b6943cd43d0071a5273cb488c0`，需要自行签名。内部可安装与unsigned下载分别核验，不代表公开TestFlight或正式App Store已发布。

## 构建与验证

本机Xcode27.2（27B52）／iOS SDK27.2完成实际iphoneos Release归档，用时980.37秒、6个编译任务。相关C源实际编译一次，受影响Swift对象、App链接与冻结源已绑定；App与19份符号在分发前独立保全。严格封装、五个App／扩展版本、隐私声明、UUID与原生依赖校验通过；真实signed IPA中的App UUID、现有Wi-Fi授权及production推送配置与保全产物匹配。

真实Darwin生产组件编译、链接及6项定向方法通过，跳过0，包括原生回执生成、重启／容器地址变化、历史活锁、异常或链接回执及持锁后的目录变化。耗时48.73秒。这是组件证据；既有App界面仅在未变化的范围复用原证据，没有新增Simulator或物理语音验收。

原工具准备与绑定拒绝、测试及操作失败记录保留；没有为分发重建App或移动标签。

## 真机容量仍未闭环

343首次实际启动记录为 `registered / rootCheck=verified / histories=2 / pending=2`，确认342的启动历史识别问题已修复。整理前文件分配估算为208.31GB。一次“优化占用”实际生成343新结果，但恢复返回 `source-preserving-abort-source-ctime`，随后 `handler_unresolved`；结果为 `blocked / recovery-pending`，attempted=0、optimized=0、fileAllocationReduction=0。

系统AFC剩余空间在按钮前后分别为184,257,830,912和184,254,222,336字节，净变化-3,608,576字节，不能据此声称有GB级回收。此前338的124,848,209,920字节收益不重复计入本版。

已取回有界原生恢复元数据，未复制盘体；两个原盘、runtime元数据和997作业的精确暂存副本仍在。两份旧journal均保留完整原始SHA-512，后续修复将核对当前完整内容及稳定文件身份；ctime变化来源尚未证实，不能仅凭系统扩展属性归因，也不能跳过校验结束旧作业。旧资料与13份恢复盘继续保留。

真机证据取齐后已停止Device Hub屏幕共享，键盘捕获为0并禁用。343源、标签、产物及本次失败保持不变。本线程未提交公开TestFlight或正式App Store，315既有安排、331撤回状态及独立预研范围保持。
