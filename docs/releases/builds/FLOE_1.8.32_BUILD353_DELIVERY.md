# Floe Agent 1.8.32（353）内部 TestFlight 交付

2026 年 11 月 15 日，App Store Connect 返回构建有效（`VALID`）且未过期。Floe QA 是该构建唯一的测试组，内部状态为 `IN_BETA_TESTING`。Apple 返回 `APP_STORE_ELIGIBLE`，可供后续正式送审选择。本次仅交付内部 TestFlight。[签名与上传记录](https://github.com/JiangNanGenius/floe-agent/actions/runs/43673115222)

打开或刷新尚未初始化 Git 的工作区时，源码管理直接显示初始化和克隆入口。暂存、提交和四个同步操作使用同一按钮样式。普通字号下，按钮按两列对齐，按钮表面高约 32 点，点按区至少 44 点。[本版更新说明](../notes/RELEASE_NOTES_1.8.32_BUILD_353.md)

在 iPad mini 模拟器（iPadOS 27.2）上，7 个仓库状态用例和原界面流程通过。统一按钮样式后再次验证了空仓库刷新、打开和取消克隆、初始化、按钮列对齐和三个同步按钮的实际点击。未配置远端时，主动执行同步会显示相应错误。

Xcode 27.2（27B52）从 `v1.8.32` 的源码 `5e2014b5bd3f66b8ecab2f9bf6912c408a55de4c` 编译了 iPhoneOS Release。主 App 和四个扩展均为 1.8.32（353），19 份 dSYM 已核对。签名 IPA 的主程序 UUID 与本地设备版一致，SHA-256 为 `790ac3d74bae0e553b46ee1bf71da45539c687ce54b4151fb51dfcae5f7a9d1a`。
