# Floe Agent 1.6.4

> 2026-09-11。本轮为快速迭代修复版：按真机实测反馈修复兼容模式工具命名、PDF 稳定性、网络诊断与任务列表刷新。
> English summary follows the Chinese section.

### 简体中文

## 修复

- **兼容模式工具命名全链路修复**（"部分工具用不了 / tools.list 概率空值"）：
  - 兼容模式（点号→下划线）此前仅 OpenAI Chat 通道生效且反向映射只看当次请求的裁剪 schema——被预算驱逐或未加载的工具以兼容名调用时被拒为"未知工具"。现在三通道（OpenAI Responses / Chat / Anthropic）统一正反向映射，反向映射对整个权限上限集合（tools.list 枚举的同一集合）是全量的。
  - tools.list 兼容感知：下划线拼写的翻页游标正确归一（不再概率性空页），条目附带 wireName 供模型学习正确拼写；tools.search 精确名匹配支持大小写与点/下划线变体。
  - 本地文本回退模式：工具名归一化（大小写/下划线/别名），不再静默丢弃拼写漂移；白名单纳入 tools.list/tools.search/task.*——本地模型现在能自己发现工具。
- **PDF 概率性闪退**：全部 PDFKit 触点（工具渲染/编辑/合并/拆分/表单与内置阅读器解析）统一经进程级 PDFKitGate 串行化——修复与主线程 PDFView 渲染竞态；pdf.render 单次调用上限 20 页 + 每页 autoreleasepool（治 OOM）；pdf.merge 保留源文档至序列化完成（治 use-after-free）；退化/NaN 媒体盒显式报错；内置阅读器大文件解析移出主线程且上限对齐 64MB；pdf.convert 修复 prepare/draw 范围不一致的未定义行为。
- **网络诊断**：
  - 设备端 ping 真实落地（数据报 ICMP，无需主机）：逐跳 RTT、丢包率、min/avg/max 汇总；IPv4。
  - 主机 ping 修正 macOS/BSD 与 Linux 的 `-W` 语义差异（毫秒 vs 秒），看门狗从 count×timeout+5 收紧到 count+timeout+15。
  - traceroute 加 `-n -q 2`（消除逐跳 PTR 反查停顿），看门狗按实际预算 hops×2×wait+15；tracepath 回退包上远端 timeout。
  - 设备 dnsLookup 加 10 秒截止，不再无限挂起。
- **任务列表更新不及时**：会话（任务）列表随运行活动实时刷新——单记录重读换入排序，不再等待手动 reload。
- floe-network 技能更新至 1.1.2（签名目录已重新发布）。

### English

Rapid-iteration fixes from on-device feedback: compat-mode tool naming is now total and bidirectional across all three wire protocols (reverse mapping covers the full permission ceiling, not just the trimmed schema set); tools.list/search normalize underscored spellings and expose wire names; the local text-fallback parser normalizes mangled names and admits discovery tools so weak models can self-discover. PDF stability: every PDFKit touch is serialized through a process-wide gate (no more racing the main-thread PDFView), render is capped at 20 pages/call with per-page autoreleasepool, merge retains sources through serialization, degenerate media boxes fail cleanly, the inline reader parses off-main with a 64MB cap, and pdf.convert's prepare/draw range contract is fixed. Network: real device-side datagram-ICMP ping (per-reply RTT, loss%, min/avg/max), correct BSD-vs-Linux ping -W semantics, tighter watchdogs, traceroute with -n -q 2, bounded tracepath fallback, and a 10s deadline for device dnsLookup. The task list now refreshes live as runs progress. floe-network skill bumped to 1.1.2.
