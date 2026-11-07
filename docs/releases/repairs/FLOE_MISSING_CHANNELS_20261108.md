# GitHub／Feather 遗漏渠道补发（2026-11-08）

按用户确认，GitHub App Release 与 Feather 作为内部测试交付渠道。本次复用原不可变标签与留存设备包，补齐下面八个既有 TestFlight 候选；没有重编 App、移动标签、改 App Store 或新增公开 TestFlight 提交。

| 版本／构建 | GitHub Release | 原来源提交 |
| --- | --- | --- |
| 1.7.75（316） | [v1.7.75](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.75) | [249c718875ac](https://github.com/JiangNanGenius/floe-agent/commit/249c718875acc31ceadbbfe50ca5fd486dead978) |
| 1.7.76（317） | [v1.7.76](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.76) | [90dec9806129](https://github.com/JiangNanGenius/floe-agent/commit/90dec98061297dd62278c84ad1fe35be25377f18) |
| 1.7.78（319） | [v1.7.78](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.78) | [c0aea38a8bed](https://github.com/JiangNanGenius/floe-agent/commit/c0aea38a8beda63bb6dcca32f6b4a84fe5dc7663) |
| 1.7.79（320） | [v1.7.79](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.79) | [89c8ad5a2971](https://github.com/JiangNanGenius/floe-agent/commit/89c8ad5a2971ca8d5630a0d94dcc7191fd38a313) |
| 1.8.2（322） | [v1.8.2](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.2) | [520afe01fce8](https://github.com/JiangNanGenius/floe-agent/commit/520afe01fce806fd5a3bdbe17f4d86f57f5384b3) |
| 1.8.3（323） | [v1.8.3](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.3) | [c828775b63da](https://github.com/JiangNanGenius/floe-agent/commit/c828775b63dab33779a2b9bb25ec5e584e4135b0) |
| 1.8.4（324） | [v1.8.4](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.4) | [e4d334904ae5](https://github.com/JiangNanGenius/floe-agent/commit/e4d334904ae59c17d3cf86a8e40ee0f60bf9dcc0) |
| 1.8.5（325） | [v1.8.5](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.5) | [950f0d7c782e](https://github.com/JiangNanGenius/floe-agent/commit/950f0d7c782eb1d67b4d0cb2dcfb0643a32c0217) |

每版均通过原标签的 unsigned producer、Actions 来源证明、严格发布读回及同步等待的 Feather 工作流；本机还实际下载并核对公开 IPA、校验文件、arm64 iOS 设备二进制、原标签来源与实时 Feed 的准确地址／摘要／大小。公开附件只含无签名 IPA、校验文件及最小来源说明，使用者仍需自行签名。

[GitHub Latest](https://github.com/JiangNanGenius/floe-agent/releases/latest) 与 [Feather Feed](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json) 已核对指向 **1.8.5（325）**，Feed 同时包含全部八个补发条目。消费完毕的八份私有传输草稿已删除，本地恢复包、符号及原始失败记录保留。

318 与 321 的当时失败尝试没有成功交付设备包，不冒充漏发候选补包。历史候选的原有已知问题与验证边界继续适用；例如 323 的签名 Wi-Fi 能力遗漏由 324 修复。本次补发不把后续物理／生物、LaTeX、新音乐或 PCB 研发变更计入冻结的 325。

## English

GitHub App Releases and Feather are internal-testing delivery channels under the user’s updated direction. Eight existing candidates were recovered from their original immutable tags and retained device artifacts. No App recompilation, tag movement, App Store change or new public TestFlight submission occurred.

Each normal publisher completed source-bound Actions attestation, strict release readback and the awaited Feather workflow. Independent downloads verified the actual unsigned IPA, checksum, arm64 iOS device executable, original source and live feed URL/digest/size. Latest and Feather now resolve to **1.8.5 (325)**; all eight recovered entries are present. Consumed private transports were removed while recovery bytes, symbols and original failures remain private.

Failed attempts 318 and 321 were not substituted with newly built packages. Original limitations remain applicable; 323’s signed Wi-Fi capability omission was addressed by 324. Subsequent development changes are separate from these historical packages.
