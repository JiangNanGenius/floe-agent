# Floe 1.8.9 (331) — 交付 / Delivery · 2026-11-11 Sydney

冻结源码 / Frozen source：`8dcf7c38f77d43a76575e10f96be72807c1c6f47`。不可变标签 / Immutable tag：`v1.8.9`；标签对象 / Tag object：`71a8686d46d503d2e495811ae4388375d27e5053`。后续主线修改不属于此包。 / Later mainline changes are outside this artifact.

**后续用户决定：331公开测试已撤回。** 先通过API移除仅331的外部组，再在App Store Connect对331执行“从审核中移除”；独立GET于2026-11-11 12:01 UTC确认 `READY_FOR_BETA_SUBMISSION`、审核提交为空、独立测试员0，仅保留内部Floe QA，`VALID`、未过期、`IN_BETA_TESTING`。331不再续推公开；重点问题修好后另发新构建。下方原提交记录按当时状态保留，GitHub／Feather与App Store315不变。 / **The user subsequently withdrew public331.** External access was removed, then its beta review was withdrawn through App Store Connect. An independent GET confirmed no review submissions or individual testers, external state ready for submission, and the unexpired valid build retained in internal Floe QA. A new public build waits for priority fixes; the original submission below remains historical.

## 范围与验证 / Scope and qualification

本版修复330反馈的传感器生命周期、原生计时设置、化学工程文件删除及生物回收站残留，并补齐目标创建、输入模式恢复、暂停及继续。功能范围见[冻结双语说明](../notes/RELEASE_NOTES_1.8.9_BUILD_331.md)。不含新增Linux视频硬件解码；用户后续明确授权公开331，不再等待该独立研发。 / This build addresses the sensor lifecycle, timer setup, Chemistry deletion, Biology Trash cleanup and goal workflow. Its frozen notes define scope. New Linux hardware video decoding is excluded; the user subsequently authorized public331 without waiting for it.

使用Xcode27.2（27B52）及iOS Simulator27.2实际编译、链接App及测试包。相关8个App行为用例在App21至App23的对应检查点均取得通过：原始失败保留，只重验实际修复项，未变范围复用有效结果；不能表述为8项全在最后同一次产物重跑。另复用未受后续修改影响的App20生物永久删除及11项传感器组件结果。 / Actual App and test bundles compiled and linked with Xcode27.2 and Simulator SDK27.2. Eight affected App cases passed across the corresponding App21–23 checkpoints. Original failures were preserved and unchanged results reused, rather than claiming a single final-artifact run of all eight. The unaffected App20 Biology purge and eleven sensor component results were retained.

唯一指定iPad模拟器实测了计时器完整三列滚轮、秒数拖动、零时长禁用与取消；并从真实文件回收站逐项核对和永久删除三个本任务化学测试项目。没有使用用户物理iPhone或再次占用用户iPad；传感器精度、真实麦克风及目标行的全部像素交互不在本次实机验收声明内。 / The canonical iPad Simulator verified the three timer wheels, seconds adjustment, zero-duration disablement and cancellation, then purged three exact task-owned Chemistry fixtures through the real file UI. Physical sensor accuracy, microphone behavior and exhaustive goal-row visual acceptance are not claimed.

本地Release归档和正常封装通过后立即保留原始App及全部19份符号，签名和分发复用同一精确源码产物。实际签名包回读核对了App UUID、Wi-Fi权限、production推送与未过期描述文件。 / The successful local Release archive immediately retained the raw App and all nineteen symbol bundles. Signing and delivery reused the exact-source artifact; the signed IPA was checked for App UUID, Wi-Fi entitlement, production push and an unexpired profile.

## 渠道读回 / Distribution readback

| 渠道 / Channel | 已核实结果 / Observed result | 证据 / Evidence |
| --- | --- | --- |
| 内部TestFlight / Internal TestFlight | `VALID`、未过期；Floe QA `IN_BETA_TESTING`，可安装。 / Available internally. | [签名及上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/43006528169)及[独立Apple GET](https://github.com/JiangNanGenius/floe-agent/actions/runs/43011242406)通过。 |
| GitHub | 正常未签名producer、来源证明及严格公开读回通过，stable/latest。 / Normal unsigned producer, attestation and strict readback passed; stable/latest. | [发布流程](https://github.com/JiangNanGenius/floe-agent/actions/runs/43011548978)；[不可变Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.9)。 |
| Feather | 同次awaited下游通过；实时版本、源码、下载地址、大小和摘要与实际IPA匹配。 / Awaited downstream passed; the live feed matched the actual IPA. | [安装源](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json)及同次严格读回。 |
| 公开TestFlight / Public TestFlight | 向既有publictest1提交一次；独立复查 `pending_review`／`WAITING_FOR_BETA_REVIEW`，尚非公开可安装。 / Submitted once; independently confirmed pending review, not publicly installable yet. | [提交](https://github.com/JiangNanGenius/floe-agent/actions/runs/43012940822)；[独立复查](https://github.com/JiangNanGenius/floe-agent/actions/runs/43013282228)。 |

Apple内部核验为2026-11-11 11:22 UTC，GitHub／Feather为11:29 UTC，公开独立复查为11:36 UTC。公开组已关联该构建且链接启用，审核仍在等待，不能仅凭链接可打开声称新构建已可安装。 / Readbacks were saved at 11:22, 11:29 and 11:36 UTC, respectively. Group attachment and an enabled link do not establish approval or availability of this build.

公开未签名包 / Public unsigned IPA：[Floe-Agent-1.8.9-build331-unsigned.ipa](https://github.com/JiangNanGenius/floe-agent/releases/download/v1.8.9/Floe-Agent-1.8.9-build331-unsigned.ipa)，**914,457,675 bytes**。SHA-256：

```text
b3fed06e0d214ac5bfc3017897503f7fe5721b53935a62b78fad559708433f0a
```

该包需自行签名；签名TestFlight包和公开未签名包各有独立摘要，不混用。 / Your signing is required for the public package; it and the signed TestFlight IPA retain separate digests.

## 公开文案与后续范围 / Public copy and follow-up

公开授权晚于App冻结：最终文案由独立标签 `floe-testflight-metadata-1.8.9-build331-r2` 固定，仅添加两份公开测试文案，App树、原发布标签与产物不变。首次只读预检将“保留草稿”的产品说明误判为未定稿标记，在Apple写入前拒绝；改成等义的“保留未发送内容”后，使用未改动的正式校验器通过。原失败及旧metadata标签保留，未重编、重传或重复送审。 / Public authorization followed the App freeze. A separate immutable metadata tag adds only the final public copy. The first read-only check rejected product wording as a draft marker before Apple writes; equivalent final wording passed the unchanged validator. The original failure and metadata tag were retained, without rebuilding, reuploading or resubmitting.

331之后新报的后台服务显示、水平球／竖直水平仪、AR测量、中间路由跳点、深色图标、计时界面及二维码扫描继续独立修复，**不属于331**。见[后续需求FU01–FU11](../../FLOE_IOS_UPDATE_PLAN_20261111.zh-CN.md)。GPU／新增Linux视频硬解仍由原负责人继续；正式App Store Build315安排未改。 / These later service, Level, AR, Traceroute, dark-icon, timer-UI and QR reports are follow-up work outside331. GPU/video work continues separately; formal App Store Build315 remains unchanged.

清理只退役已完成且可恢复的330展开暂存；APFS共享块下实测仅约0.003GiB，不以目录逻辑大小冒充释放空间。当前／回退安装包、原始App、全部符号、失败证据和仍有明确复用用途的缓存保留；本任务使用的模拟器已关闭。 / Cleanup retired only verified recoverable staging. APFS shared blocks yielded about0.003GiB of measured free space, not the directory's logical size. Current/rollback packages, raw App, symbols, original failures and identified reusable caches were retained; task-owned Simulator sessions were shut down.
