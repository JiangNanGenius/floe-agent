# Floe 历史版本导览

本页保留原 `docs/README.md` 中逐 Build 的历史状态和索引。每段结论仅属于当时的源码与核验时间；当前交付状态见 [文档入口](../README.md)。

## 旧版交付与修复

Build240 的[原反馈修复及编辑器验证记录](repairs/FLOE_240_FEEDBACK_REPAIR.md)作为历史保留；它不替代本轮放映验收。

**历史 Build231 修复记录**：[Office 打开与字体](repairs/FLOE_231_OFFICE_REPAIR.md)、[本地模型回复与首条消息导航](repairs/FLOE_231_MLX_REPAIR.md)、[Linux 生命周期工具](repairs/FLOE_231_LINUX_LIFECYCLE.md)。其中结果属于当时源码与验证范围，当前状态以上面的候选记录为准。

**历史内部交付：1.7.0（218）**。2026-09-21T15:08:27Z 已核实 Apple VALID、未过期、唯一私有内部 Floe QA 组（无公开链接）及 IN_BETA_TESTING；原始证据保留在 [TestFlight 交付记录](testflight/TESTFLIGHT_1.7.0_BETA.md) 与 [Build 218 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_218.md)。

本轮公开 TestFlight 的[Build241 审核材料](../public-beta/build241/README.md)包含中英文介绍、测试重点与审核步骤；已送审，正在等待 Apple 审核；尚未公开可安装。

**Build 221 已交付**：它修复 Build 220 云端验收 SDK 设备编译的全部 14 条诊断，并补一处 Swift 6 非 Sendable 通知负载跨 actor 错误。发布 run [35678610685](https://github.com/JiangNanGenius/floe-agent/actions/runs/35678610685) 完成验收 SDK 构建、工件留存、签名与上传；Apple、Floe QA、GitHub 预发布和 Feather 状态见 [Build 221 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_221.md)。模拟器 UI 验收按加速发布要求跳过，Linux、PPTX、通知与后台行为仍由用户在真机验收。

**Build 220 候选元数据（已被 221 取代）**：合并后的 `main` 源码 `9e83fcfa` 在 `codex/build220-release-metadata` 分支上把四个出货目标统一为 1.7.0（220）并重新生成 Xcode 工程，同时加入 [Build 220 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_220.md)与双语 TestFlight 说明。其云端设备 App 编译失败（rebuild run 35673428023，14 条诊断，无工件、无签名、无上传），修复后的源码即 Build 221。219 之后的源码级改动包括 Linux 持久磁盘／缓存／9P／安装状态修复、显式后台模式与实测指标、任务完成通知、PPTX 可见渲染门禁与宿主重新固定 `f0ca71a7`、模拟器编译守卫 `67a37db3`，以及侧载链接与文档修复。在取得新的构建／TestFlight／预发布证据之前，不宣称 Build 220 已构建、已上传、已被 Apple 处理、可安装、通过真机验收或已发布；构建与云端口禁状态见 [Build 156 反馈修复记录](repairs/FLOE_156_FEEDBACK_REPAIR.md) 的 2026-09-22 更新。

### 历史交付记录（保留原始结论，不代表当前可用状态）

**Build 216 是 218 之前的内部交付**（`v1.7.0-beta.73`，`c2f20f6e`，9 月 21 日 07:55 UTC 核实 VALID/未过期/Floe QA/IN_BETA_TESTING）。Build 214 是首个 TinyEMU/Linux 主环境版本，Build 215 修复其真机反馈，Build 216 补齐发布路径兼容性；各版本原始记录均保留在交付档案中。Build 217 编译失败且从未上传。

此前内部 TestFlight **1.7.0（201）**，已核实 Apple VALID、未过期、唯一私有 Floe QA 组和 IN_BETA_TESTING（2026-09-19 17:44 UTC），中英文测试说明均已保存并读回。该构建的发布作业因冻结标签检出中缺少 `RELEASE_NOTES_1.7.0_BUILD_201.md` 而停止；[beta.58](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.58) 开发者包与 [Feather 源](../FEATHER_SOURCE.md)均由同一保留工件恢复（未重新构建、未二次上传）。Build 196（[beta.53](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.53)）仍在同一内部组保留原记录。上一交付 191 的历史结论为：三项界面失败仅获内部测试豁免。完整包/模型、RDP App 集成和部分真机验收仍未完成。[191 交付证据](../qualification/build191-release/README.md)，历史记录保持原结论。

**Build 196 曾在内部 Floe QA TestFlight 可安装**（Apple buildID `27355e88…`，`VALID`／未过期／唯一私有 Floe QA 组／`IN_BETA_TESTING`，2026-09-19 02:24 UTC 核实；中英文测试说明已读回）。Build 192/193 编译失败；Build 194/195 被 Apple 接受但从未发布；四个标签均作为证据保留，194–196 的 App 源码相同。工作区包含 191 反馈修复，[Build 196 发布说明](notes/RELEASE_NOTES_1.7.0_BUILD_196.md)区分已实现、宿主级验证与待真机验收；[TestFlight 测试说明](testflight/TESTFLIGHT_1.7_WHATS_NEW_BUILD_196.json)已附加到该构建。该构建的签名目录包含 `floe/ruby` 3.4.1 与 `floe/php` 8.2.33（签名 WASI 目录条目，不是原生运行时载荷；当前构建同样不包含原生 Python/Node/Ruby 载荷），安装与真机运行验收仍由测试者完成；语言状态详见 [LANGUAGES.md](../../capability-hub/LANGUAGES.md)。

**Build 197（1.7.0，`v1.7.0-beta.54`）编译失败，从未上传**：标签 `v1.7.0-beta.54` 固定在 `f05b02ac`（不得移动）。[run 35426497884](https://github.com/JiangNanGenius/floe-agent/actions/runs/35426497884) 的验收上传 SDK App 编译报 5 条诊断、2 个独立错误：`ExecutionEnvironmentView.swift:82/105/124/147` 找不到 `RuntimeInventoryEntry`（缺 `import FloeExecution`），`FileInspectorView.swift:132` 对已解包的 `previewPath` 重复条件绑定；编译之后的步骤全部跳过，无工件、无签名、无 TestFlight 上传。其功能实现范围 `1cff5665..11681a0f`（8 个功能提交）保持不变，[Build 197 发布说明](notes/RELEASE_NOTES_1.7.0_BUILD_197.md)保留原记录。

**Build 198（1.7.0，`v1.7.0-beta.55`）曾交付内部 Floe QA（Build 197 的替代）**：功能与 197 相同（思维导图触摸新增节点、视频公开候选与方舟凭据修复、跨 run 工具上下文恢复与摘要脱敏、执行环境真实版本与 APT 路由、妙控键盘 Return 发送／Shift+Return 换行、Office 首次预览／第二次直编与 IDE 集成、Pencil 墨迹与远端快照只读、移除无效“加入画布”入口），修复上述两处编译错误（`ExecutionEnvironmentView.swift` 增加 `import FloeExecution`；`FileInspectorView.swift` 去掉多余的第二处可选绑定），4 个 target 的版本／构建号统一为 1.7.0／198。[Build 198 发布说明](notes/RELEASE_NOTES_1.7.0_BUILD_198.md)与 [TestFlight 测试说明](testflight/TESTFLIGHT_1.7_WHATS_NEW_BUILD_198.json)记录本轮轻量校验（swiftc parse、xcodegen、版本／构建号一致性、JSON 校验、`git diff --check`）；本地 Qwen/GDN 首次消息崩溃仍待真机确认（尚未证实修复）。

**Build 199（`v1.7.0-beta.56`）未上传，Build 200（`v1.7.0-beta.57`，`45553423`）在验收上传 SDK App 编译内停止（无工件、无签名、无上传）**；其暴露的两处 Swift 6 诊断由 `3744103f` 修复。**Build 201（`be06cece`，`v1.7.0-beta.58`）为该轮内部交付**：单次验收上传 SDK 构建（[run 35453588806](https://github.com/JiangNanGenius/floe-agent/actions/runs/35453588806)）保留未签名 IPA 与匹配私有符号、TestFlight 接受上传；发布作业因冻结标签检出缺少发布说明文件而停止，GitHub 预发布与 Feather 源随后从同一保留工件恢复（未重新构建、未二次上传），复用重试暴露的 `testflight-direct.yml` 元数据校验调用缺陷已在该分支修复并加回归测试。[Build 201 发布说明](notes/RELEASE_NOTES_1.7.0_BUILD_201.md)记录完整恢复与核验证据。

| 文档 | 阅读目的 |
|---|---|
| [Build 242 内部 TestFlight 交付](testflight/TESTFLIGHT_1.7.1_BETA.md) | 固定源码、云端工件、Apple VALID、Floe QA 可安装及真机待验收边界 |
| [Build 242 双语发布说明](notes/RELEASE_NOTES_1.7.1_BUILD_242.md) | 本轮 Linux 停止、工具调用与语音波形修复 |
| [Build 241 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_241.md) | 当前正式 GitHub Release、私有 Floe QA、Feather 与待公开测试送审 |
| [Build 227 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_227.md) | 历史内部 Floe QA：云端构建、未签名 IPA、签名上传、Apple VALID、GitHub 预发布与设备回归边界 |
| [Build 227 测试说明](testflight/TESTFLIGHT_1.7_WHATS_NEW_BUILD_227.json) | 已交付内部构建的中英文 TestFlight 测试重点 |
| [Build 226 候选说明](notes/RELEASE_NOTES_1.7.0_BUILD_226.md) | 失败候选（云端编译缺少 `FloeTools` 导入，无 IPA、无上传）；镜像组件、原生 IDE 与专项修复的范围记录，修复即 Build 227 |
| [Build 225 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_225.md) | 上一内部交付：验收 SDK 编译、IPA、签名上传、Apple VALID 与 GitHub 预发布；真机缺陷以设备反馈为准 |
| [Build 225 测试说明](testflight/TESTFLIGHT_1.7_WHATS_NEW_BUILD_225.json) | 上一已交付内部构建的中英文 TestFlight 测试重点 |
| [下一版实施状态与验证边界](../FLOE_1_7_NEXT_RELEASE_STATUS.md) | 整合轮的已实现/已验证项（统一许可入口、原生优先路由）、其他工作包的明确设计与未验收边界、待最终刷新章节与已知阻塞；不预留构建号 |
| [Build 224 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_224.md) | 未编译成功的候选：`v1.7.0-beta.81`（`c36b7b24`）在 run 35767875337 因 LinuxGuestImageDownloader.swift:101 类型化抛错失败，记录保留，修复即 Build 225 |
| [Build 224 测试说明](testflight/TESTFLIGHT_1.7_WHATS_NEW_BUILD_224.json) | 失败候选的中英文 TestFlight 测试重点（保留） |
| [TinyEMU Runtime v2](../TINYEMU_RUNTIME_V2.md) | 目录归属、CoW、迁移、租约、VM 池、内存与恢复约束 |
| [Gitee 分片镜像](../FLOE_LINUX_GUEST_IMAGE_BUILD.md) | GitHub 主源与 Gitee 九分片镜像、清单/分片 SHA-512、续传与单向同步 |
| [Gitee 发行版镜像（refs 与资产）](../FLOE_GITEE_RELEASE_MIRROR.md) | GitHub 主源的 refs 与 Release 元数据/资产单向镜像：可直接下载的资产、分片重建（不可直装作 IPA）、幂等续传、Actions 触发路径与实测上传带宽限制 |
| [Build 223 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_223.md) | 历史内部构建（`v1.7.0-beta.80`）：Runtime v2 首次整合；Build 224 修复其启动回归 |
| [Build 223 测试说明](testflight/TESTFLIGHT_1.7_WHATS_NEW_BUILD_223.json) | 已被取代候选的中英文 TestFlight 测试重点（保留） |
| [Build 221 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_221.md) | 历史内部交付：Build 220 云端编译 14 条诊断的完整修复 + 1 处 Swift 6 并发修复；TestFlight、GitHub 预发布与 Feather 已完成 |
| [Build 221 测试说明](testflight/TESTFLIGHT_1.7_WHATS_NEW_BUILD_221.json) | 历史内部构建已保存并读回的中英文 TestFlight 测试说明 |
| [Build 220 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_220.md) | 已被取代：1.7.0（220）元数据已准备，但云端设备 App 编译失败（run 35673428023，14 条诊断，无工件、无上传） |
| [Build 220 测试说明](testflight/TESTFLIGHT_1.7_WHATS_NEW_BUILD_220.json) | Build 220 的中英文 TestFlight 测试说明（该构建未上传） |
| [Build 219 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_219.md) | 历史内部交付：Linux 首次使用自动准备、客体网络、MLX 内存/快照、IDE Git 刷新与 Office 独立编辑路径；TestFlight、GitHub 预发布与 Feather 已完成 |
| [Build 219 测试说明](testflight/TESTFLIGHT_1.7_WHATS_NEW_BUILD_219.json) | 对应构建的中英文 TestFlight 测试说明 |
| [Build 218 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_218.md) | 上一内部交付：真机反馈修复；TestFlight、GitHub 预发布和 Feather 已完成 |
| [Build 216 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_216.md) | 218 之前的内部交付：Build 215 修复集与发布路径兼容修复 |
| [Build 215 候选说明](notes/RELEASE_NOTES_1.7.0_BUILD_215.md) | 稳定性修复、轻量验证边界与待真机验收项 |
| [178 反馈修复与 179 验证](repairs/FLOE_BUILD178_FEEDBACK_REPAIR.md) | 历史修复、原始失败、定向验证与剩余门槛 |
| [本地模型/视频/工具上下文修复（2026-09-19）](repairs/FLOE_LOCAL_VIDEO_TOOLCHAIN_REPAIR_2026-09-19.md) | 本地聊天取消竞态、公开视频候选选择、工具证据回灌的根因、改动与待真机项 |
| [Build 201 发布说明](notes/RELEASE_NOTES_1.7.0_BUILD_201.md) | 该轮交付（1.7.0/201，`v1.7.0-beta.58`）：构建与上传接受、从保留工件恢复发布、Floe QA 核验与复用步骤修复 |
| [Build 198 发布说明](notes/RELEASE_NOTES_1.7.0_BUILD_198.md) | 该轮交付（1.7.0/198，`v1.7.0-beta.55`）：功能与 197 相同并修复两处编译错误 |
| [Build 197 发布说明](notes/RELEASE_NOTES_1.7.0_BUILD_197.md) | 编译失败的候选（`v1.7.0-beta.54` 固定于 `f05b02ac`，run 35426497884 报 2 个编译错误，未上传）：功能实现、轻量校验与待真机项 |
| [Build 196 发布说明](notes/RELEASE_NOTES_1.7.0_BUILD_196.md) | 191 反馈修复：已实现、宿主级验证与待真机验收（该轮交付内部 Floe QA；192/193 编译失败、194/195 上传未发布记录见各自说明） |
| [179 候选说明](beta/RELEASE_1.7.0_BETA_36.md) | 历史改动、已验证范围与发布状态 |
| [手记截图](../qualification/build178-feedback/full-app-955e346a/README.md) / [CAD 编辑验证](../qualification/build178-feedback/cad-layout/README.md) | 原始截图、固定源码与平台限制 |
| [未发布变更草稿](../FLOE_1_7_CHANGELOG_DRAFT.md) | 历史改动与分发前剩余工作 |
| [本轮继续实施状态](../FLOE_1_7_CONTINUATION_STATUS.md) | 手记、Office、Whisper 与剩余验收事实 |
| [实施状态](../FLOE_1_7_IMPLEMENTATION_STATUS.md) | 已验证路径、当前交付源码和剩余门槛 |
| [构建与验收](../FLOE_1_7_BUILD_AND_ACCEPTANCE.md) | 本地定向测试、云端 SDK 构建和 TestFlight 门槛 |
| [迁移与恢复](../FLOE_1_7_MIGRATION.md) | 分层语义、数据保护和故障恢复限制 |
| [兼容性说明](../FLOE_1_7_COMPATIBILITY.md) | 包、编码器、模型的真实支持范围 |
| [包与模型资格矩阵](../FLOE_1_7_QUALIFICATION_MATRIX.md) | 15 个包、33 个模型逐项状态与待验证门槛 |
| [TestFlight 交付记录](testflight/TESTFLIGHT_1.7.0_BETA.md) | 固定版本、构建尝试与 Apple 处理结果 |
| [界面截图与交互测试](../evidence/floe-1.7/interface/README.md) | 通用里的日夜主题、思考框和连续工具折叠 |
| [Node 运行时（已退役）](../FLOE_1_7_NODE_RUNTIME.md) | 进程内 NodeMobile 的历史证据；本地 Node 现运行于 Linux 客体 |
| [文档维护清单](../FLOE_1_7_DOCUMENTATION_AUDIT.md) | 当前说明、历史档案与生成内容的维护归属 |

## 发布档案（只追加、不回改）

- `RELEASE_NOTES_<版本>.md` — 每个测试版的发布说明（release workflow 依固定路径读取，**勿移动**）
- [RELEASE_NOTES_1.7.0_BUILD_227.md](notes/RELEASE_NOTES_1.7.0_BUILD_227.md) — 历史交付（1.7.0/227，`v1.7.0-beta.84`，`9c756864`；云端构建、未签名 IPA、签名上传、Apple VALID、Floe QA 可安装、GitHub 预发布与真机回归边界分别记录）
- [RELEASE_NOTES_1.7.0_BUILD_226.md](notes/RELEASE_NOTES_1.7.0_BUILD_226.md) — 未编译成功的候选（1.7.0/226，`v1.7.0-beta.83`，`b2b2fd75`；文件树压缩入口缺少 `FloeTools` 导入，无 IPA、无上传；记录保留，修复即 Build 227）
- [RELEASE_NOTES_1.7.0_BUILD_225.md](notes/RELEASE_NOTES_1.7.0_BUILD_225.md) — 上一内部交付；云端构建、上传、Apple 处理、GitHub 预发布和真机待验收边界分开记录
- [RELEASE_NOTES_1.7.0_BUILD_224.md](notes/RELEASE_NOTES_1.7.0_BUILD_224.md) — 未编译成功的候选（1.7.0/224，`v1.7.0-beta.81`，`c36b7b24`；run 35767875337 因 LinuxGuestImageDownloader.swift:101 类型化抛错失败，无工件无上传；记录保留，修复即 Build 225）
- [RELEASE_NOTES_1.7.0_BUILD_223.md](notes/RELEASE_NOTES_1.7.0_BUILD_223.md) — 历史内部构建（1.7.0/223，`v1.7.0-beta.80`；当时 VALID、Floe QA、IN_BETA_TESTING；Runtime v2 首次整合）
- [RELEASE_NOTES_1.7.0_BUILD_222.md](notes/RELEASE_NOTES_1.7.0_BUILD_222.md) — 已被取代的源码候选（1.7.0/222；验收 SDK App 编译阶段停止；发布与真机状态未取得）
- [RELEASE_NOTES_1.7.0_BUILD_221.md](notes/RELEASE_NOTES_1.7.0_BUILD_221.md) — 历史内部交付（1.7.0/221，Build 220 云端编译失败的完整修复；云端构建、TestFlight、GitHub 预发布与 Feather 已完成；真机验收待用户执行）
- [RELEASE_NOTES_1.7.0_BUILD_220.md](notes/RELEASE_NOTES_1.7.0_BUILD_220.md) — 已被 221 取代（1.7.0/220，源码 `9e83fcfa` 加元数据提交；云端设备 App 编译失败 run 35673428023，14 条诊断，无工件、无上传）
- [RELEASE_NOTES_1.7.0_BUILD_219.md](notes/RELEASE_NOTES_1.7.0_BUILD_219.md) — 上一内部交付（1.7.0/219，`v1.7.0-beta.76`；TestFlight、GitHub 预发布与 Feather 已发布，真机验收由用户完成）
- [RELEASE_NOTES_1.7.0_BUILD_218.md](notes/RELEASE_NOTES_1.7.0_BUILD_218.md) — 更早内部交付（1.7.0/218，`v1.7.0-beta.75`；已核实 Floe QA 可安装，GitHub 预发布与 Feather 已发布，真机验收由用户完成）
- [RELEASE_NOTES_1.7.0_BUILD_216.md](notes/RELEASE_NOTES_1.7.0_BUILD_216.md) — 218 之前的内部交付（1.7.0/216，`v1.7.0-beta.73`；原始交付记录保留）
- [RELEASE_NOTES_1.7.0_BUILD_215.md](notes/RELEASE_NOTES_1.7.0_BUILD_215.md) — 内部交付（1.7.0/215，`v1.7.0-beta.72`）：稳定性修复、验证边界与真机测试重点
- [RELEASE_NOTES_1.7.0_BUILD_201.md](notes/RELEASE_NOTES_1.7.0_BUILD_201.md) — 该轮交付（1.7.0/201，`v1.7.0-beta.58`；构建/上传接受、发布从保留工件恢复、Floe QA 核验与复用步骤修复）
- [RELEASE_NOTES_1.7.0_BUILD_198.md](notes/RELEASE_NOTES_1.7.0_BUILD_198.md) — 已交付内部 Floe QA（1.7.0/198，`v1.7.0-beta.55`；修复 197 的两处编译错误）
- [RELEASE_NOTES_1.7.0_BUILD_197.md](notes/RELEASE_NOTES_1.7.0_BUILD_197.md) — 编译失败记录（1.7.0/197，`v1.7.0-beta.54` 固定于 `f05b02ac`，run 35426497884 报 2 个编译错误；从未上传；标签不动）
- [RELEASE_NOTES_1.7.0_BUILD_196.md](notes/RELEASE_NOTES_1.7.0_BUILD_196.md) — 下一候选的完整说明（已冻结；发布工作流在冻结提交创建标签并上传，191 交付记录保持原样）
- [RELEASE_NOTES_1.7.0_BUILD_195.md](notes/RELEASE_NOTES_1.7.0_BUILD_195.md) — 已上传但未发布（GitHub 工件服务故障丢失 TestFlight 证据；App 源码与 196 相同；标签不动）
- [RELEASE_NOTES_1.7.0_BUILD_194.md](notes/RELEASE_NOTES_1.7.0_BUILD_194.md) — 已上传但未发布（发布工作流验证调用缺陷；App 源码与 195 相同；标签不动）
- [RELEASE_NOTES_1.7.0_BUILD_193.md](notes/RELEASE_NOTES_1.7.0_BUILD_193.md) — 第二次冻结的失败记录（7 个 App 目标编译错误，未上传；标签不动）
- [RELEASE_NOTES_1.7.0_BUILD_192.md](notes/RELEASE_NOTES_1.7.0_BUILD_192.md) — 首次冻结的失败记录（验收上传 SDK 编译区域隔离错误，未上传；标签不动）
- `RELEASE_VERIFICATION_<版本>.md`、`TESTFLIGHT_<版本>.md` — 对应核验与上传记录
- `RELEASE_CODE_AUDIT_20260909.md` — 1.6.1 代码审计
- [evidence/](../evidence/) — 逐版本证据包

## Floe 1.7 发布材料（含历史记录）

- [Build 221 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_221.md) — 历史内部交付（1.7.0/221）的改动、发布证据、验证边界与真机验收项
- [Build 220 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_220.md) — 被取代的候选（云端设备 App 编译失败 run 35673428023，无上传）
- [Build 219 版本说明](notes/RELEASE_NOTES_1.7.0_BUILD_219.md) — 历史内部交付的改动、验证范围与真机验收项
- [中英文功能介绍、版本说明及 TestFlight 测试描述](notes/RELEASE_NOTES_1.7.0.md)
- [手记、动态导图、语音与当前证据](../FLOE_1_7_CONTINUATION_STATUS.md)
- [升级和恢复，包括永久删除与资源回收](../FLOE_1_7_MIGRATION.md)
- [包与模型资格矩阵](../FLOE_1_7_QUALIFICATION_MATRIX.md)

历史加急交付记录（保留原结论）：[191 加急内部交付](../qualification/build191-release/README.md)原上传因发布 SDK 新增 iPhone 助手界面失败而在签名前停止；用户当时同意跳过全部三项失败，恢复任务 35347141494 上传成功，2026-09-16 13:43 UTC 核实 Apple VALID、未过期、Floe QA 和 IN_BETA_TESTING。[190 最终结果](../qualification/build190-release/final-results.json)与[封面截图](../qualification/build190-release/accepted-ipad-covers-after-relaunch.png)均已保留。此后版本与当前状态见文首交付记录。

- [同时编辑与冲突恢复](../FLOE_CONCURRENT_EDITING.md) — IDE、文本、Office、手记的保存规则与验证边界。

- [Engineering viewers: format matrix, offline architecture and qualification](../FLOE_ENGINEERING_VIEWERS.md)

- [Build 177 historical candidate record](notes/RELEASE_NOTES_1.7.0_BUILD_177.md): earlier personalization, CAD/IDE and UI qualification work; its recorded status is historical.
- [RDP integration status](../FLOE_RDP.md): pinned native bridge, real loopback evidence and remaining App integration.

- [Build 187 record](beta/RELEASE_1.7.0_BETA_44.md): progressive content covers, navigation identity and pre-build localization checks; tagged `d77aa11f`, run 35312393708 recorded component/UI failures and the build was never uploaded. Historical.
- [Build 186 failed qualification](beta/RELEASE_1.7.0_BETA_43.md): fixed source `d421fea2`, run `35306551280`; original evidence and unsigned recovery archive retained, not uploaded.
- [Build 185 candidate](beta/RELEASE_1.7.0_BETA_42.md): durable cloud jobs, WASI environment repair and content-cover qualification; both App regressions passed but UI failures blocked upload.
- [Build 184 failed candidate](beta/RELEASE_1.7.0_BETA_41.md): both SDK App builds passed; Lua runtime regression blocked upload.
- [Build 183 candidate](beta/RELEASE_1.7.0_BETA_40.md): durable IDE cloud builds, real library covers, runtime lifecycle checks; App compilation failed before upload.
- [IDE GitHub Actions](../IDE_GITHUB_ACTIONS.md): snapshots, workflow setup, restart recovery and cancellation.
- [Office/CAD covers](../NOTES_OFFICE_THUMBNAIL_ACCEPTANCE.md): per-format content and full-App evidence requirements.
- [Runtime lifecycle](../RUNTIME_LIFECYCLE_ACCEPTANCE.md): service restart, environment deletion and Lua execution acceptance.
- [Accepted-SDK recovery](../ACCEPTED_SDK_RELEASE_RECOVERY.md): immutable-source artifacts, per-device gates and host reuse.
