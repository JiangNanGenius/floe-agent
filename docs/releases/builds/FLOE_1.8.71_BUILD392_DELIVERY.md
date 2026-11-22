# Floe Agent 1.8.71（392）

源码冻结于 `bfde5af4017664df8f203f8f850e9ec4e4e1aa2d`，标签为 `v1.8.71`。本地使用 Xcode 27.2（27B52）完成 iPhoneOS Release 构建。主 App 与四个扩展版本一致，19 份调试符号与二进制匹配。

- **内部 TestFlight**。Apple 回读为 `VALID`，未过期，Floe QA 为 `IN_BETA_TESTING` 且可安装。签名包通过严格验证，与本地构建的 App UUID 相同。[签名与内部交付](https://github.com/JiangNanGenius/floe-agent/actions/runs/45009911894)
- **GitHub 与 Feather**。GitHub 的最新版为 `v1.8.71`，无签名 IPA 为 721,820,906 字节，SHA-256 为 `29bcaef3c61385a04f0bc0a7417287186b0b7989a2f025d80f80ab6fdc45c409`。已回读在线 Feather 的版本、下载地址和包摘要。[GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.71) · [发布与更新源核验](https://github.com/JiangNanGenius/floe-agent/actions/runs/45011176597)

设置向导修复在固定 iPad 模拟器上手动验证，覆盖空密钥定位、协议加粗和深浅色下的状态标签。同一实现通过 8 项离线连接探测测试。392 的同源调试构建通过模拟器签名检查，已交给录制任务继续复测。
