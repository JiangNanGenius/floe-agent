# Floe Agent 1.8.79（400）

本版减少长回复的重复解析和会话列表的冗余刷新，加快长文本用量估算、工具名称查找及工作区目录筛选，并统一目录分页的游标边界处理。 [双语发布说明](../notes/RELEASE_NOTES_1.8.79_BUILD_400.md)

## 构建与验证

`v1.8.79` 固定于 `4dddb7e4e3b1c517e66fb5535c3108f3ef1645ff`。使用 Xcode 27.2（27B52）完成 iPhoneOS arm64 Release 构建。App、四个扩展及 20 套调试符号已核对，签名包和无签名包来自同一份设备构建。

- 固定 iPad mini 模拟器（iPadOS 27.2）的 51 项定向测试全部通过，覆盖历史分页、长文本用量估算、定时器在回复中的归属、文件助手刷新、工具注册和执行前的可用性检查，以及目录筛选。
- 24 项封包测试通过，发布包的版本、资源、App UUID、签名和调试符号已核对。Xcode 仍提示部分 SDK 缓存的调试路径缺失，主 App 调试符号中的 `FloeAgentApp` 记录已抽查。

| 本机组件基准 | 优化前中位数 | 优化后中位数 |
| --- | ---: | ---: |
| 流式回复正文解析（151,200 字节） | 6.50 毫秒 | 2.14 毫秒 |
| 草稿用量估算（471,200 字节） | 2.02 毫秒 | 0.25 毫秒 |
| 工具名称解析（6,600 次） | 40.89 毫秒 | 0.45 毫秒 |
| 目录名称筛选与排序（4,800 个条目，200 项匹配） | 25.34 毫秒 | 5.98 毫秒 |

每项以同一组合成输入交替测量 15 轮。目录基准从条目名称准备完毕开始计时。实体设备帧率和端到端工具耗时仍待实测。

## 发布渠道

- **内部 TestFlight**。2026-11-25 00:03（悉尼时间）从 App Store Connect 独立读回，400 为 `VALID`、未过期，Floe QA 为 `IN_BETA_TESTING`，可安装。中英文测试说明与冻结源码一致。签名 IPA 的 SHA-256 为 `fb50e7271230e99a2fffb0d8c079ddf73b75b06eb6818e476c9a76af89685fd9`。 [签名与上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/45394062450)
- **GitHub 与 Feather**。无签名 IPA 已从最新正式 GitHub Release 的公开链接完整下载，文件长度为 736,113,741 字节，SHA-256 为 `0fc14fe43aa158d0563f8be879605d76d934c7f69c3d436f04b6745c2147705b`，构建证明已通过核验。在线 Feather 源的版本、构建号、源码、地址和文件摘要均匹配。 [GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.79) · [发布流程](https://github.com/JiangNanGenius/floe-agent/actions/runs/45397130783) · [Feather 源](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json)
