# Floe Agent 1.8.72（393）

源码冻结于 `258c0c51ffe59cd287d7db9188de440cce0f95e8`，标签为 `v1.8.72`。发布预检与 Xcode 27.2（27B52）的 iPhoneOS 27.2 arm64 Release 构建通过。主 App 与四个扩展版本一致，19 份调试符号与二进制匹配。

- **内部 TestFlight**。Apple 回读为 `VALID`，未过期，Floe QA 为 `IN_BETA_TESTING` 且可安装。签名 IPA 与本地构建的内容及 App UUID 核验通过。Apple 标记为 `APP_STORE_ELIGIBLE`。[签名与上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/45020987508)
- **GitHub 与 Feather**。GitHub 的最新版为 `v1.8.72`，无签名 IPA 为 721,843,642 字节，SHA-256 为 `07861300e17f4debcbdde73f74c80b25c4b39daec55378b1045c9c88011e07a3`。已核验发布资产，并从在线 Feather 回读版本、下载地址和摘要。[GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.72) · [发布与更新源核验](https://github.com/JiangNanGenius/floe-agent/actions/runs/45022096072)

用户确认升级 Linux 后，聊天显示进度并等待升级。升级完成且原运行位置核验通过后，待执行的命令从同一任务继续。若设置内已经开始升级，任务等待同一次升级完成。修复提交的 20 项定向测试通过，真机上的完整升级和接续流程待用户验收。

## App Store 正式审核

2026-11-23 00:41（悉尼时间）提交 1.8.72（393）。独立读回确认版本与审核单均为 `WAITING_FOR_REVIEW`，绑定原构建 393，发布方式为审核通过后手动发布。中英文更新说明与审核备注均已核对，商店页面沿用原排列的 60 张截图和 6 支预览。[App Store Connect 审核记录](https://appstoreconnect.apple.com/apps/6801209053/distribution/reviewsubmissions/details/8c2869fc-fae8-42de-add8-f24d788088f1)
