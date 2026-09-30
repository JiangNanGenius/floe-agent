# Floe 1.7.0 Build239 — Linux download sources / Linux 下载源

## 简体中文

- Gitee 继续同步源码和 Release，但不再作为软件内置加速或后备源，旧镜像条目的 Gitee 地址也已移除。
- 默认 SMP 镜像在 GitHub 出现明确的网络可用性错误时，依次尝试 gh-proxy.com 和 ghproxy.net。主线程已分别验证匿名完整下载及固定 SHA-512。所有来源保留相同完整性校验；取消、内容错误及本地磁盘错误不会触发换源。
- 支持直接下载的通用镜像，保留分片恢复能力并补齐取消检查。

验证：执行模块编译、19 项镜像回归及 6 项分片回归通过；这是 macOS 模块与网络验证，不等于 iPad 验收。请测试 GitHub 不可达时的下载、进度刷新、取消和重试。

沿用 Build238 的其他修复及限制：PPT 编辑闪退根因仍未确认；本地模型两轮文件工具通过，但真实权重搜索回执回答失败；中文字体用户已确认恢复。软重启未提供，旧环境不会自动更换基础镜像。本轮不宣称这些问题全部修好。

## English

Gitee continues source and Release synchronization but is removed from all bundled image fallbacks, including the legacy entry. The default SMP image tries gh-proxy.com and then ghproxy.net after bounded GitHub availability failures. The primary independently verified anonymous complete downloads against the pinned SHA-512. Cancellation, invalid content and local disk failures do not switch sources. Generic direct mirrors are supported while verified shard reconstruction and owner cancellation are retained.

The execution module compiled; 19 mirror and six shard regression tests passed. These are macOS module/network checks, not iPad acceptance. Please test download, progress, cancellation and retry when GitHub is unavailable.

Build238 limitations remain: the PPT edit crash is not confirmed resolved; real-weight local search receipt grounding failed despite two successful file-tool turns. The user confirmed Chinese glyphs fixed. Soft reboot is unavailable and existing environments retain their base image.
