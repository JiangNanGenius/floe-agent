# Floe 1.7 构建与验收 / Build and acceptance

本说明适用于 1.7 整合分支；完整验收状态以[实施记录](FLOE_1_7_IMPLEMENTATION_STATUS.md)为准。最低系统为 iOS/iPadOS 26，数据库迁移至 v40。重型 App 构建与归档放在云端，本地仅做定向验证。正式发布不属于本轮自动动作。

## 本地准备

使用完整 Xcode，通过 `DEVELOPER_DIR` 指定安装路径，不必更改全局 `xcode-select`。先检查磁盘空间。以下命令从仓库根目录运行；Xcode 路径按本机调整。

```bash
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
bash FloeAgent/scripts/bootstrap_native_components.sh
python3 FloeAgent/scripts/audit_native_runtime_free.py --project
swift test --package-path FloeAgent/Qualification --scratch-path FloeAgent/.build --force-resolved-versions --jobs 2
swift build --package-path FloeAgent --target FloeExecution --force-resolved-versions --jobs 2
```

Phase 2（TinyEMU 迁移）后没有随包的原生 CPython/NodeMobile 构建输入：本地 Python/Node 在每个环境的 TinyEMU Linux 客体中运行，`audit_native_runtime_free.py` 会阻止原生 Python/Node 标记重新回到工程或安装包。退役的构建配方（锁定运行时引导、ios-wheelhouse、Node 工具）归档在 `FloeAgent/ThirdParty/NativeRuntimeArchive/`，不接入构建。Qualification 为环境、软件包、媒体和后台任务迁移提供独立测试入口，避免完整 App/MLX 构建。共享 `.build` 的 SwiftPM 命令串行执行。

原生 Node 最小 App（[NativeNode](../FloeAgent/Qualification/NativeNode/README.md)）属于已退役运行时历史资格宿主，仅随归档配方保留，不再接入当前构建。

## 工程与云端构建

`FloeAgent/project.yml` 是工程源；运行 `bash FloeAgent/scripts/gen_project.sh` 并提交匹配的 Xcode 工程。完整依赖准备由 `bootstrap_native_components.sh` 负责（PDFium、LibArchive、Office 宿主与 dash shell 框架）。Python/Node 不再有嵌入式构建输入；不要把 Node/npm/pnpm/yarn 的生成目录手工展开为 Xcode 源文件条目。

推送固定提交后检查 CI 的 Linux、开发 SDK 和发布 SDK 作业。每项记录提交 SHA、Xcode/SDK、测试结果、失败日志和产物。重跑使用同一提交；代码变化后结果属于新提交。构建产物上传、签名归档、App Store Connect 处理、TestFlight 可安装分别记录。

当前发布流水线先固定并校验标签，再并行验证 SDK 27 源码和 Xcode 26.6（17F113，实际 SDK 26.5）的上传构建。每个 SDK 只编译一次模拟器测试宿主，App 回归和 iPad／iPhone UI 使用 test-without-building；两套设备 Release 构建仍保留。两边均成功后，签名作业核对上传候选产物的 SHA-256、源码提交、包标识及版本号，复用已验证的应用，不再编译。`#if compiler(>=6.4)` 控制的 27 专属实现不会出现在这份上传包中，例如手记的新笔迹选择接口会走兼容选区入口。SDK 27 组件图不能用来证明 TestFlight 包含全部 27 专属能力；上传后记录中必须注明实际工具链。

## 完整验收门槛

| 范围 | 必须保留的证据 |
|---|---|
| 环境 | 两项目多会话、重启、模板/晋升、删除等待、配额及 CAS 引用 |
| 执行 | 循环、多段管道、stdin、未知命令、环境继承、取消与资源回收 |
| 软件包 | 同一发布器/客户端签名样本、篡改、依赖冲突、恢复、升级回滚、卸载归属 |
| 媒体 | 横竖屏、不同帧率/声道、长文件、后台、空间不足、取消；重读输出实际参数 |
| 模型 | 33 项评估；15 类各有真实输入、产物、真机耗时与内存 |
| 工作台 | 文件/附件入口、编辑保存重开、共享任务、取消/重试、导出播放/返回 |
| 回归 | 聊天与工具循环、Office 保存重开、中文文档、工作区、Canvas、PiP |
| 分发 | 同一固定提交的开发/发布 SDK 构建、签名上传、Apple 处理与内部测试组可见；用户安装后完成双端真机验收 |

不以“资源下载成功”“工具返回文本成功”替代真实处理证据。密钥、令牌、私人媒体及未脱敏日志不得加入证据包。

## 媒体工作台最小 App

[NativeMedia](../FloeAgent/Qualification/NativeMedia/README.md) 编译生产工作台/播放器，使用合成视频检查编辑模型保存重开和真实导出。`--model-smoke` 产出 `media-model-results.json`，与宿主媒体测试、完整 App UI 和真机结果分别记录。该测试不能证明共享队列或聊天附件已接通。

## 原生外观、容器和步骤框验证

[NativeManagement](../FloeAgent/Qualification/NativeManagement/README.md) 编译生产主题选择器、容器管理界面、思考框、工具框和连续步骤组。它使用合成环境和明确的 App 路由替身；不能替代完整 App 导航、审批执行、附件或真机验收。UI 测试实际点击主题选择、展开思考、折叠完成调用并追加运行中的调用。模块级 `EnvironmentManagementTests` 验证真实管理服务对不同项目、继承依赖和生命周期的处理。

## 当前描述文件与新链路验收

当前上传候选为 [Build 220 版本说明](RELEASE_NOTES_1.7.0_BUILD_220.md)（版本与发布元数据已准备，尚未构建、上传或取得 Apple／真机证据）；当前已交付版本说明见 [Build 219 版本说明](RELEASE_NOTES_1.7.0_BUILD_219.md)。上传后必须补入实际固定提交、构建号、Apple 处理结果与可安装状态，当前交付记录见 [TestFlight 交付记录](TESTFLIGHT_1.7.0_BETA.md)。1.7.0 系列的历史版本文件保留，不改写为新版本说明；较早的概述见 [RELEASE_NOTES_1.7.0.md](RELEASE_NOTES_1.7.0.md)。

### 192–196 结果（2026-09-19）

- 192 / `v1.7.0-beta.49` / `1dc6577a`：上传 SDK App 编译在 `FloeLocalModels/MLXTextEngine.swift` 因 Swift 6 区域隔离错误失败，未上传。
- 193 / `v1.7.0-beta.50` / `e0b4c8ca`：修复区域隔离后暴露 7 个 App 目标错误（媒体轮询符号、`ShellRunOutcome` 分支、`Identifiable` 隔离、可选权限探针与两个 `CocoaError` 代码），未上传。
- 194 / `v1.7.0-beta.51` / `b1e1bbdd`：单次验收上传 SDK 编译通过，未签名设备 IPA 与私有符号在签名前留存，TestFlight 运输层接受上传；发布步骤因验证器调用缺陷失败，未发布。
- 195 / `v1.7.0-beta.52` / `575211e9`：修复发布步骤后构建上传成功（`No errors uploading archive`），但 GitHub 工件服务临时故障（`Failed to CreateArtifact: ENOTFOUND`）导致 TestFlight 证据工件缺失，未能通过发布门禁。
- 196 / `v1.7.0-beta.53` / `0771aee5`：**内部 TestFlight 已交付**。run `35411629062` 单次验收 SDK 构建；未签名 IPA `Floe-Agent-1.7.0-build196-unsigned.ipa` sha256 `bd080ba7…80c4`、812 MB，私有符号 `release-symbols-1.7.0-build196`（App UUID `66F46B44…`）在签名前留存；来源证明签名工作流 `release-unsigned-ipa.yml`；GitHub prerelease `v1.7.0-beta.53` 仅含未签名资产；Feather run `35413736446` 发布 `feather.json`（sha256 `bd080ba7…`、sourceCommit `0771aee5…`）。ASC buildID `27355e88-2f37-4c60-8b6e-713db546773b`：`VALID`、未过期、唯一私有 Floe QA 组、`IN_BETA_TESTING`，中英文测试说明已读回（2026-09-19 02:24 UTC）。按要求跳过模拟器/界面验收，真机验收由用户完成；本地模型 Build191 Qwen 崩溃仍未证实修复。

### 186 最终结果与 187 准备（2026-09-18）

- 186 固定源码 `d421fea260523d063270e2d21d623bd011acd9ea` / `v1.7.0-beta.43` 的 run `35306551280` 已失败。发布 SDK App 回归 204/204；双端 Notes UI 均 3 通过、1 失败、1 原生 Office 预期跳过；组件 iPad 83/84、iPhone 84/84；SDK 27 模块发现一个本地化键错误。签名与上传未执行，[原始结果](qualification/build186-release/result.json)与恢复包身份均已留存。
- 187 已固定 `v1.7.0-beta.44` / `d77aa11f`，云端 run35312393708 进行中，尚无完成验收或上传结果。新版封面采用摘要首帧加系统预览升级；严格 Quick Look 诊断单列记录，缺失、漏跑、崩溃与非预期失败仍阻断。新的本地化预检先于重型构建执行。详见 [187 记录](RELEASE_1.7.0_BETA_44.md)。
- 组件 run `35304310882`（源码 `8d303197`）iPad 84/84、iPhone 83/84：唯一失败是直接读取暂存文件的 Word 请求 45.0958 s 超时；同一文件经真实封面服务（`NotesDocumentCoverService`）在同一次运行中以 3.278 s 首次尝试通过（iPad 直连请求经重试通过）。两端 OCR 用例通过，导出的 XCTest 会话日志证实有效计时器由 120 s 重置为 180 s（[保留的验收记录](qualification/build185-release/notes-followup.json)）。系统宿主停滞原因仍未证实，未加入重试或超时掩盖；完整 App 冷启动封面可靠性仍是必要门槛。
- 标签源码中的六个 Office 样例测试（`b06b3082`）已改为真实 importer/CAS/封面服务路径，仍严格要求真实 Quick Look 内容图（非回退摘要或图标）；它们尚未在任何地方执行，本次发布 run 的 Notes 组件作业是首次实跑结果。
- 历史记录不改写：组件 `35301809882` iPad 84/84、iPhone 83/84（120 秒扫描 OCR 超时）；185 / `v1.7.0-beta.42` 双 SDK App 回归 204/204，但界面验收失败、未上传。

### 上一候选（185）状态（2026-09-18 记录）

- 候选为 1.7.0 (185) / `v1.7.0-beta.42`，固定源码 `42ecc4527fdbeb171dd0aed1d0776375770f1572`。发布流水线 run `35292395886` 已启动：`prepare-release` 通过，App 构建与双 SDK 回归仍在进行；**尚未签名、未上传、不可安装**。
- 上一候选 1.7.0 (184) / `v1.7.0-beta.41` / `8e0cf69f`：两套 SDK 的 App 编译均通过，但两个 App 回归各 203/204，同一个 Lua 安装/运行用例命中旧 WASI 32 变量上限；`LocalServiceLifecycleTests` 两用例在两个 SDK 上均通过。设备恢复包已留存，未签名、未上传（[候选记录](RELEASE_1.7.0_BETA_41.md)、[回归证据](qualification/build184-release/sdk27-app-regression.json)、[恢复包](qualification/build184-release/device-recovery.json)）。
- Lua 修复 `f908cce1`：真实 macOS Swift Testing 7/7（含签名 Lua fixture），另加 11 项边界/真实 Lua 检查（[证据](qualification/build185-release/lua-environment.json)）；CI `0fff2c3b` 在模块测试前准备签名 fixture。完整 App 内该用例的重跑仍属 185 验收。
- NativeNotes 组件运行 `35290599088`（源码 `f4435d22`，开发 SDK 27，兼容作业未选择）在 iPad/iPhone 各 72/72；10 张真实内容封面保存于 `docs/qualification/build185-release/native-covers/`。其中 iPhone 早期思维导图文字截图整体黑帧，已排除；后续联动图有可见内容。组件通过只证明冷启动症状已修复，不证明原始失败原因，也不等于完整 App 或真机验收。
- 证据分类固定为：真实测试／组件 UI／完整 App／真机／上传，五者分别记录；自动化与模拟器结果不替代用户真机检查。

手记验收增加：回收站永久删除必须确认且检查修订；活动附件、其他文档和撤销历史不误删；多存储句柄共享读取保护，失败回收可重试。动态导图需在真实 WebKit 验证长文字、附图和分支无重叠，方向更新生效；iPhone 横屏保留阅读位置，以真实截图正文识别确认。

真机分工更新：由用户执行 iPad/iPhone 真机检查。本轮保留自动化测试、云端归档与 TestFlight 上传责任，交付时附上双端检查清单；不以自动化通过代替用户的真机检查结果。

TestFlight 就绪检查同时要求：`VALID`、未过期、现有私有内部 Floe QA 组可见，以及 `buildBetaDetail.internalBuildState == IN_BETA_TESTING`。`READY_FOR_BETA_TESTING` 继续等待分发状态更新，出口合规或异常状态明确保留。字段含义见 [Apple InternalBetaState](https://developer.apple.com/documentation/appstoreconnectapi/internalbetastate)。实际工作流状态判断通过 7 组就绪、等待、过期和合规阻塞样本检查。

### Build 156 分发恢复

Apple 校验前运行 `prepare_app_store_bundle.py`：按摘要移除 pnpm 非 iOS 资源，保留 libssh2 原有 arm64 切片并修正其最低版本占位符，不伪造 SDK 元数据。恢复工作流将固定应用源码与单独的打包策略提交绑定，验证原始云端作业的成功构建/测试后再复用证据。重新签名、上传与处理状态均须重新检查，参见[实际包验证记录](evidence/floe-1.7/release-156/distribution-recovery.md)。

## 加急 TestFlight 与产物恢复

常规发布仍按当轮约定完成验证。用户明确要求跳过模拟器验证时，`release-unsigned-ipa.yml` 提供两条独立入口：优先使用 `reuse_accepted_run` 重用同一固定 tag 的受支持上传 SDK 产物；只有没有可复用产物时才使用 `direct_testflight`，从固定 tag 构建设备 Release 包。不要同时填写两个入口，也不要移动 tag 或借用另一构建的验证结果。

`testflight-direct.yml` 保留签名、描述文件和 Apple 上传校验，并在签名前保存未签名恢复包。常规上传 SDK 路径在可选模拟器检查之前保留 `accepted-sdk-device-recovery-*`；该早期备份尚未经过最终 bundle 规范化，不能直接当作已验收分发包。产物来源、处理阶段与 SHA 必须一起保留。这样重试分发无需因为后续检查失败而丢失已编译文件。

构建完成、产物保存、上传成功、Apple 处理、测试组可安装是五个不同状态。Apple 回执并不等于 TestFlight 已可更新。公开 Beta 的验证约定需按下一版本重新确定，不自动继承 build 172 的加急豁免。
