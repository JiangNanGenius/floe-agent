# Build 283 local qualification and delivery / 本地核验与交付

日期 / Date: 2026-10-21。版本 / Version: **1.7.42 (283)**。

## 交付 / Delivery

- [内部 TestFlight](https://github.com/JiangNanGenius/floe-agent/actions/runs/39552556058)成功。Apple 回读为 `VALID`、未过期、现有 `Floe QA`／`IN_BETA_TESTING`；中英文测试说明已核对，**内部可安装**。The existing internal group can install this build.
- [稳定最新版 Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.42)仅含规范无签名 IPA、校验文件和精简来源文件。[同一次发布流程](https://github.com/JiangNanGenius/floe-agent/actions/runs/39552615636)已完成来源证明、发布回读及 awaited Feather。Independent readback verifies the real arm64 iphoneos executable, tag/source, remote bytes, attestation, latest pointer and live feed.
- IPA SHA-256: `bb69c39319d6d1eff2068c4f490045c70c4b636cb6d5c9cfd0e39cce5ce25f31`；大小 / bytes: `801552098`。Feather 版本、build、源码、大小、摘要和下载地址与该资产完全一致。The unsigned IPA requires the user's own signing.
- **公开 TestFlight 尚未提交。** 恢复网页认证后向现有 `publictest1` 提交一次并独立回读；不能把内部可安装写成外部已开放。275 正式提交和已有 281／282 申请均未改动。External submission remains pending; no production App Store publication is authorized.

## 源码与产物 / Source and artifacts

本地 Xcode **27A266a／iphoneos27.0／arm64** 归档源码为 `e4d778c7c799a33983c462c56b9c88ce6de60453`。归档成功后立即保存原始 App、App／扩展／原生组件匹配符号，核对宿主与扩展均为 1.7.42 (283)，以及实际编译的快捷指令导出元数据。

冻结标签最初遗漏两份已准备好的发布说明。用户明确授权一次仅补说明的修正后，`v1.7.42` 固定至 `c0d5612426bc039a61ca2cabfe7e0adeae0657b5`，只新增中英文 Release 说明及 What to Test JSON。两版本 `FloeAgent` 树均为 `0583409046728d21a495e160377640de9f185ee4`；没有重建 App。原标签对象及原始来源记录保留；修正后的传输包逐成员核验，除来源 JSON 外 App、资源和符号字节完全一致。GitHub 与 Gitee 标签均回读一致。

The original local archive and the corrected release tag have an identical App source tree. Only two release documents were added under explicit authorization; App binaries and symbols were reused unchanged. Original tag/provenance and byte-equivalence evidence are retained privately. Cloud steps only sign/upload or package/attest this archived App; they do not rebuild it.

## 改动与验证 / Changes and qualification

- Office 助手无标题编辑、空闲自动保存和指定屏幕外区域查看；普通发送不再自动附图。实际编辑、保存／重开和区域图像进入模型请求的证据保留。
- Excel 抬笔后的白底与颜色失真修复，使用默认产品配置保留原生 Calc 网格／背景绘制。`137ea88c` 的 7 项实际 App／引擎用例全部通过，0 失败、0 跳过：原表格连续两笔、已有底色、缩放后续写、Word 对照、助手真实 PDF／文件卡片、原生打印入口和范围／版面。原表格两笔颜色误差均为 0，各阶段网格保留率均为 100%，原文件未改动。
- PDF 导出与打印共用生成前设置，XLSX 支持工作表／工作簿／单元格范围、纸张、方向、适配与边距；Word／PowerPoint 支持最终 PDF 页码。实际文件与分页通过核验，不以截图或成功文字代替文件。
- 助手真实导出接入运行归属、快照和校验后的预览／分享；快捷指令获取指定运行的文件结果。保留旧运行文本接口、取消与恢复约束。此前 19 项打印副本、24 项 App 导出契约、手记冲突及搜索设置等定向证据保留，不重复无关历史矩阵。
- 云端版本检查夹具遗漏浏览器校验依赖的故障单独修复：原 14 项失败保留，补齐夹具后 **19／19** 通过。生产脚本、锁文件、门槛和负向断言未改动；该测试修正另作提交，不移动发布标签。

Relevant builds and focused behavior checks passed. Runtime evidence, source equivalence, archive, Apple availability and publication are recorded separately. Physical Pencil pressure, palm rejection and feel, physical printer output, and system Shortcuts automation dispatch remain distinct device/system acceptance; no broader guarantee is claimed.

## 主线与清理 / Integration and cleanup

[PR #10](https://github.com/JiangNanGenius/floe-agent/pull/10)已合并，`main` 回读包含功能修复、发布说明和测试夹具修正；本包分支本地与远端均删除，其他工作树保留。仅清理经核实无活动引用的任务缓存和重复产物；本次交付收尾实测内置盘净增约 **3.84 GiB**、外置盘约 **2.72 GiB**，不重复计入此前原生／模拟器候选的清理。APFS 克隆副本按实际空间变化记录，不把文件逻辑大小当回收量。

私有传输草稿在两个消费者成功后删除并回查 404，没有残留传输标签。当前原始 App ZIP、规范无签名 IPA、修正传输包、全部匹配符号、必要 282 回滚、用户原文件及原始成功／失败证据保留。共享 App 增量缓存与依赖仅为即将使用的 S4 系统入口验收保留；本轮独立 Release／原生生产缓存已删除。固定 iPad 已关闭，未删除设备或数据。

Source and delivery cleanup are complete. The remaining 283 external submission is tracked separately while independent S4 investigation proceeds; it must not be marked submitted until actual submission and readback.
