# Linux download source qualification / Linux 下载源核验

This change follows frozen build 238; it is not part of tag `v1.7.0-beta.97`.
此改动晚于已冻结的 Build238，不属于该标签。

Gitee remains synchronized for source and Releases but is removed from bundled download fallbacks, including the legacy image entry. GitHub remains the primary source. The proposed SMP fallback order is `gh-proxy.com`, then `ghproxy.net`.
Gitee 继续同步源码及 Release，但从内置下载后备源移除，包括旧镜像条目。GitHub 仍为主源，SMP 后备顺序为上述两个站点。

## Evidence / 证据

On 2026-09-30, the primary streamed the entire immutable SMP archive anonymously through each endpoint, with proxy environment settings disabled, no login, credentials or cookies, and a bounded 1 MiB buffer.
主线程以无登录、无凭据、无 Cookie、禁用环境代理的请求逐一流式下载完整 SMP 压缩包，使用 1 MiB 有界缓冲区。

| Endpoint | Bytes | SHA-512 match | Observed elapsed time |
| --- | ---: | --- | ---: |
| gh-proxy.com | 587,162,397 | Yes | 71.50 s |
| ghproxy.net | 587,162,397 | Yes | 214.73 s |
| ghfast.top | 83,901,547 (truncated) | No | 394.67 s |

The truncated candidate was excluded. `gh-proxy.org` also passed, but is associated with the first service and was not counted as an independent fallback.
截断候选未纳入；同属首个服务的 `gh-proxy.org` 虽通过，也未作为独立后备源。

Archive: `floe-linux-guest-smp-20260928.1/floe-linux-guest-floe-debian13-riscv64-202609202607-basic-r572a77382feb-b36330566148-1.zip`.

Pinned SHA-512:
`4f19064f764ed400194a830b38af57236c5cd3145f463f2352834c0c834c90f7d4c6df078cd7d831acf42b6620de09d758c62dc3dbed90694f5ea63ff21d84a8`.

A [November 2023 firsthand report](https://github.com/lzwme/scoop-proxy-cn/issues/29) names both selected endpoints. Current operator pages describe release-asset support: [gh-proxy documentation](https://gh-proxy.com/docs/github-accelerator), [ghproxy.net](https://ghproxy.net/). This establishes documented multi-year use, not continuous uptime or an SLA. A successful download from this Mac is not proof of reachability on every iPad network.
2023 年公开使用记录与当前服务说明构成年份依据，不代表连续在线保证或 SLA；本机下载成功也不等于所有 iPad 网络均可达。

All sources retain the same pinned archive digest. Cancellation, integrity failure and local disk errors must not silently trigger another download source. Only bounded availability failures advance to the next endpoint. No Gitee URLs will be added after synchronization completes.
所有来源共用固定摘要；取消、完整性失败、本地磁盘错误不能悄悄换源，仅明确的可用性错误推进后备列表。Gitee 同步完成也不再加入软件来源。
