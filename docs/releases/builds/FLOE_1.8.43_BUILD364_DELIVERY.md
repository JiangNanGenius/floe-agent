# Floe Agent 1.8.43（364）交付 / Delivery

2026-11-18 Sydney 核验。冻结源码为 `00629979157db5aa738b4c11fc5fde4d18ec7278`，不可变标签为 `v1.8.43`。以下为各渠道独立读回的状态。 / Verified on 2026-11-18 Sydney. The immutable tag binds the exact source above; channel states were checked separately.

| 渠道 / Channel | 核验结果 / Observed result |
| --- | --- |
| 内部 TestFlight / Internal TestFlight | Apple `VALID`、未过期，现有 Floe QA 为 `IN_BETA_TESTING`，可安装。 / VALID, unexpired and installable in the existing Floe QA group. |
| 公开 TestFlight / Public TestFlight | 现有 publictest1 已关联 364，已提交审核；独立 GET 为 `WAITING_FOR_BETA_REVIEW`，尚未确认公开可安装。 / Submitted to the existing group; awaiting beta review, not yet verified publicly installable. |
| GitHub / Feather | [v1.8.43](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.43) 为 stable/latest，发布与后续 Feather 作业均成功，实际安装包校验与在线源读回匹配。 / Stable/latest publication, complete IPA verification and awaited live-feed readback passed. |
| 正式 App Store / App Store | 未创建或提交新正式版本，353 原关联和发布设置未改动。 / No new formal submission; build 353 bindings and release settings were preserved. |

本版让游戏助手使用工程的标准工作区文件与 Git 工具，并改进工程根目录选择、试玩前状态刷新和自带运行文件的提示。[双语说明](../notes/RELEASE_NOTES_1.8.43_BUILD_364.md)与[测试说明](../testflight/TESTFLIGHT_1.8_WHATS_NEW_BUILD_364.json)均在冻结源码中。 / The game assistant uses standard workspace and Git tools, with improved root selection, pre-play refresh and runtime guidance. Both release and test copy were frozen with the source.

本地 Xcode 27.2（27B52）、iphoneos27.2 完整 Release 设备构建通过。原始 App 与 19 份匹配符号已保全；签名后逐项比较了 35 个 Mach-O、5974 个资源及五个应用／扩展的权限与 profile。[签名与上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/44227596827)和[公开安装包及 Feather](https://github.com/JiangNanGenius/floe-agent/actions/runs/44229791743)均完成。 / The full local device build passed; the App and 19 symbol bundles were retained. Signed-content, signature and entitlement comparisons passed.

公开 unsigned IPA 为 672,521,480 字节，SHA-256 为 `f0e323e5c8dcd3fe2b3b2b839bee35f9cc97ce549aa0b4a3cdb6d466e37c5ad5`。完整成品读取及来源证明复用已通过的 Feather 作业；独立读取的 GitHub 元数据及实时源与之匹配。 / The published IPA size and digest above match the completed full-binary provenance check and independent live metadata/feed reads.

四个 MV 样例通过导入／准备检查；多引擎真实图形试玩与完整真机验收仍未全部完成，不能由构建或组件结果替代。临时传输草稿和本轮构建分支已退役，原始失败、恢复包、当前安装包及符号保留。 / Four MV samples passed import/preparation checks. Complete multi-engine gameplay and physical-device acceptance remain unverified. Temporary transport and build branches were retired with recovery and delivery evidence retained.
