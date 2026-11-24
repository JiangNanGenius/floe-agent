# Floe Agent 1.8.72（393）

源码冻结于 `258c0c51ffe59cd287d7db9188de440cce0f95e8`，标签为 `v1.8.72`。发布预检与 Xcode 27.2（27B52）的 iPhoneOS 27.2 arm64 Release 构建通过。主 App 与四个扩展版本一致，19 份调试符号与二进制匹配。

- **内部 TestFlight**。Apple 回读为 `VALID`，未过期，Floe QA 为 `IN_BETA_TESTING` 且可安装。签名 IPA 与本地构建的内容及 App UUID 核验通过。Apple 标记为 `APP_STORE_ELIGIBLE`。[签名与上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/45020987508)
- **公开 TestFlight**。2026-11-23 01:20（悉尼时间）将同一构建加入 `publictest1` 并提交 Beta 审核。独立回读为 `WAITING_FOR_BETA_REVIEW`，已确认公开链接启用，审核通过后自动开放。中英文测试说明沿用冻结版本。[公开测试入口](https://testflight.apple.com/join/nz6qeT2J) · [Beta 审核备注](../../public-beta/build393/REVIEW_NOTES.txt)
- **GitHub 与 Feather**。GitHub 的最新版为 `v1.8.72`，无签名 IPA 为 721,843,642 字节，SHA-256 为 `07861300e17f4debcbdde73f74c80b25c4b39daec55378b1045c9c88011e07a3`。已核验发布资产，并从在线 Feather 回读版本、下载地址和摘要。[GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.72) · [发布与更新源核验](https://github.com/JiangNanGenius/floe-agent/actions/runs/45022096072)

用户确认升级 Linux 后，聊天显示进度并等待升级。升级完成且原运行位置核验通过后，待执行的命令从同一任务继续。若设置内已经开始升级，任务等待同一次升级完成。修复提交的 20 项定向测试通过，真机上的完整升级和接续流程待用户验收。

## App Store 正式审核

2026-11-23 01:02（悉尼时间）撤下首次审核单，用同一构建 393 连同新版 iPad 宣传图重新送审。独立读回确认版本与新审核单均为 `WAITING_FOR_REVIEW`，发布方式为审核通过后自动发布（`AFTER_APPROVAL`）。[App Store Connect 审核记录](https://appstoreconnect.apple.com/apps/6801209053/distribution/reviewsubmissions/details/04e784af-b37e-4141-aff2-f6f48d3c70a0)

2026-11-25 00:28（悉尼时间）从正式审核队列撤下 393。待审商品页的宣传材料保留在 1.8.79（400）草稿，正式送审因新报告的滚动问题暂停。 [后续交付记录](FLOE_1.8.80_BUILD401_DELIVERY.md)

iPad 的简体中文和英文第 4 张以代码 IDE 为主，右侧为原生游戏编辑器完整窗口。已回读两张新图的资产编号和位置，核对六套素材的排列及总计 60 张截图、6 支预览，并再次核对中英文更新说明。
