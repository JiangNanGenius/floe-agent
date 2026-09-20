# Floe Agent 1.7.0 (211) — internal device-test candidate

## 简体中文

包含本轮所有反馈项的代码修改：Office 打开/关闭与恢复副本、IDE 内部 PDF/Office 标签、
Git 初始化、原生思维导图的图标按钮与自由拖动、Shell 会话回收、跨任务历史读取到最终答复，
以及本地模型工具调用、上下文压缩和可恢复失败。

Linux、Python、Node、WASM 有独立包入口。可选 Linux 环境使用 TinyEMU；其 Shell、
local Python 与后台服务共用 guest 后端、Python venv 与文件。原生执行保持默认。
环境设置提供固定镜像下载入口，复用已有镜像安装服务；下载任务不依赖页面的存活。
启动时解析已验证镜像的绝对路径；每个环境使用独立持久磁盘，保留安装的软件包。
对应源码、版权文本和重新链接材料随 Linux 组件发布。

镜像采用 Linux4.15 内核与 Debian13 用户态，已通过两次真实云端启动、HTTPS APT/Python、
11 项命令操作与 6 项指令探针。SSH 只验证客户端版本，SCP 只验证失败连接；真实传输、
iPad 性能与全部交互由用户验收。Office 恢复副本会保留，但引擎进程真正失败后仍可能需要重启 App。

## English

This candidate includes code changes for every reported area: Office lifecycle and recovery copies;
internal IDE PDF/Office tabs; Git initialization; native mind-map icon controls and free node movement;
Shell session recovery; cross-task history lookup through final answers; and local-model tool calls,
context compression and recoverable failures.

Linux, Python, Node and WASM have distinct package entries. The optional TinyEMU Linux environment
shares its guest backend, Python venv and files between Shell, local Python and background services.
Native execution remains the default. Environment settings provide a fixed-image download entry
through the existing image service; the task survives dismissal of the view. Matching sources,
notices and relink materials are distributed with the Linux component. Verified boot artifacts use
absolute paths; each environment receives its own persistent writable disk, preserving installed packages.

The image uses Linux4.15 with Debian13 userland. Two real cloud boots, signed HTTPS APT/Python,
11 command operations and six instruction probes passed. SSH was a client-version check and SCP
a negative-connection probe; real transfers, iPad performance and interactions remain user acceptance.
Office recovery copies are retained, but an engine process failure can still require restarting the App.

## Verification and delivery

Only focused code checks and the accepted-SDK cloud App build are required here; simulator/UI
regression and the full test matrix are waived at the user's request. Build, retained IPA/symbols,
signed upload, Apple processing and existing Floe QA availability are recorded separately after they occur.

Build209 failed compilation. Build210 was cancelled before upload because settings lacked the
image-download button, although the installer and terminal command existed. Both immutable records
are retained; build207 remains independently available. This is an internal TestFlight delivery,
not an App Store production release.

Linux component: `floe-linux-guest-20260920.1`, image `floe-debian13-riscv64-202609202607`.
Archive: 572643214 bytes; SHA-512
`ad691732212fd4c229e62f71bb6d97fd41a54e1b1f9e2eb1e1aa47b3edaffb7ef21ae31948439bae2d8eba9ffe7d61b7b2e1a3049ecf57fec88996ce5641d34a`.
The [component release](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-guest-20260920.1)
and its corresponding source assets became public on 2026-09-20 at 10:37:28 UTC. The public image
URL returns HTTP 200 with the pinned 572643214-byte length; the source offer is publicly readable.
