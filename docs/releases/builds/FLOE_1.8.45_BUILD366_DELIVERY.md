# Floe Agent 1.8.45（366）交付 / Delivery

2026-11-19 Sydney 核验。`v1.8.45` 固定源码为 `cbfc626a5ccf852fc071dc313121cae24adcb97a`。 / Verified on 2026-11-19 Sydney. The tag binds the exact source above.

| 渠道 / Channel | 核验结果 / Observed result |
| --- | --- |
| 内部 TestFlight / Internal TestFlight | Apple 返回 `VALID`、未过期，Floe QA 已可安装。 / VALID, unexpired and installable through Floe QA. |
| 公开 TestFlight / Public TestFlight | 现有 publictest1 已关联 366 并送审。Apple 返回 `WAITING_FOR_BETA_REVIEW`，审核尚在进行。 / Submitted to the existing publictest1 group and awaiting beta review. |
| GitHub / Feather | 366 为最新稳定发行。完整 IPA 校验及在线 Feather 源读回通过。 / Stable/latest publication, full IPA verification and live Feather readback passed. [GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.45) |
| 正式 App Store / App Store | 此次交付范围为测试和 GitHub 分发。353 正式版关联及发布设置与送审前查询一致。 / This delivery covers beta and GitHub distribution. Readback confirmed the existing build 353 App Store binding and settings. |

每个新版本首次前台打开时显示中英文用户协议。选择同意后立即进入 App，设置 → 通用可回看。确认记录保存在本机，本版没有新增统计采集。游戏助手使用标准工作区工具读取文件，推荐引擎后由用户确认。缺少运行文件的 RPG Maker MV 工程可以自动获取所需资源。[发布说明](../notes/RELEASE_NOTES_1.8.45_BUILD_366.md) · [测试说明](../testflight/TESTFLIGHT_1.8_WHATS_NEW_BUILD_366.json)

The first foreground launch of each version presents the user agreement in Chinese or English. Acceptance opens the app immediately and is stored locally. The agreement remains available in General settings. This release adds no analytics. The game assistant uses standard workspace file tools and asks users to confirm the suggested engine. RPG Maker MV projects can fetch missing runtime files.

Xcode 27.2（27B52）完整 iPhoneOS Release 设备构建通过，保留原始 App 和 19 份符号。iPad mini 模拟器用正式协议视图及启动逻辑的聚焦宿主验证了首次提示、拒绝、重开、同意后立即进入、同版本重启和升级重询。365 曾复现同意后需重启，已在 366 修复，365 未上传。两项 MV 测试覆盖运行准备，多引擎图形试玩仍未全部验证。 / The full local device build passed and 19 symbols were retained. The iPad simulator exercised the production agreement view and gate in a focused host. Build 365 exposed a required relaunch, corrected before build 366. Two MV tests covered runtime preparation. Complete multi-engine gameplay remains unverified.

签名后的 UUID、程序、资源及五个 bundle 权限校验通过。公开 unsigned IPA 为 672,536,711 字节，SHA-256 为 `24421fe446aa5032528b41518af657f4a77a1fd1dbb3ceff143733f87abd71fd`。临时传输已清理，当前安装包、符号和失败证据保留。 / Signed binary, resource, entitlement and UUID checks passed. Temporary transport was retired and delivery and failure evidence were retained. [Signing and upload](https://github.com/JiangNanGenius/floe-agent/actions/runs/44327917130) · [GitHub and Feather](https://github.com/JiangNanGenius/floe-agent/actions/runs/44330790477)
