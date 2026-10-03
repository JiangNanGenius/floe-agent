# Floe Agent 1.6.4 (140) 发布核验 / Release Verification

> 日期：2026-09-11（UTC）。结论：**TestFlight 已上架且可见性核验通过**。

## 源码与门禁

| 项 | 值 |
|---|---|
| 标签 | `v1.6.4`（annotated） |
| 源码 SHA | `57440d8`（main；含 1.6.4 版本重生成） |
| 主 CI | run [34580181100](https://github.com/JiangNanGenius/floe-agent/actions/runs/34580181100) — 三 job 全绿 |
| 发布流 | run [34582829492](https://github.com/JiangNanGenius/floe-agent/actions/runs/34582829492) — 三 job 全绿（TestFlight job 首跑遇 BrowserProtocolTests WebKit 截图已知瞬时故障，rerun --failed 通过；与 1.6.2 同一 flake） |

## Apple 侧核验

| 项 | 值 |
|---|---|
| ASC build ID | `922cbe80-f7e7-46c6-af2f-64f783c12406` |
| 版本/构建号 | 1.6.4 / 140 |
| processingState | **VALID** |
| buildAudienceType | APP_STORE_ELIGIBLE |
| Beta 组 | 恰好一个 `Floe QA`（internal=true，无公开链接），意外组 0 |
| 核验 run | discover [34597559181](https://github.com/JiangNanGenius/floe-agent/actions/runs/34597559181)；verify-testflight [34597824440](https://github.com/JiangNanGenius/floe-agent/actions/runs/34597824440) |

## 内容摘要

兼容模式工具命名全链路（三通道统一正反向映射 + 反向映射覆盖权限上限全集 + tools.list/search 兼容游标与双拼写 + 本地回退名归一化与发现工具纳入）；PDF 稳定面（PDFKitGate 进程级串行、渲染 20 页上限、merge 生命周期、阅读器解析移出主线程、convert prepare/draw 契约）；网络诊断（设备端真实 ICMP ping、BSD/Linux -W 修正、traceroute -n -q 2、有界回退、dnsLookup 截止）；任务列表实时刷新；floe-network 1.1.2 签名目录重发。

## 遗留跟踪

- BrowserProtocolTests WebKit 截图 flake 已在两次发布复现（1.6.2/1.6.4），值得做正式去抖。
- SSH 看门狗超时仍关闭整个 client（Citadel 无 channel 级关闭 API），见 NetworkDiagnosticTools 注释。
- 设备 ping 仅 IPv4；设备 traceroute 仍需主机。
