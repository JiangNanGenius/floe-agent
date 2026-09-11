# Floe Agent 1.6.6

> 2026-09-12。大体量稳定性升级：修复 thinking 模式 400、PDFedit 闪退面、网络诊断设备化与一批工具缺陷，并收口多处重复实现。
> English summary follows the Chinese section.

### 简体中文

## 修复

- **thinking 模式 400（reasoning 全局回放）**：带工具的请求必须回传历史所有 assistant 轮次的 reasoning。现在 Chat（`reasoning_content`，含网关 `reasoning` 字段）、Responses（纯文本 reasoning item + `response.reasoning_text.delta`）与 Anthropic（`thinking` 块）三通道统一回放；工具调用批次把该轮 reasoning 随记录持久化并在后续请求重放；空字符串一律按缺失处理；旧检查点缺少 reasoning 时降级为非权威历史注记而不是发出非法请求。
- **PDFedit 闪退面**：
  - PDFKit 全部操作改为专属串行队列执行（对象不再跨线程迁移）。
  - 新增 Objective-C++ 异常防火墙：PDFKit 抛出的 NSException 转为普通工具错误，不再终止进程（注解/表单/畸形文档）。
  - 内置阅读器文档由主线程独占创建与使用；编辑提交后通过修订通知即时刷新（页面/缩放保持），不再跨线程共享 PDFDocument。
  - 重排页改为重建文档，消除"先清空再插回"的 use-after-free；raster/OCR 每页独立 autoreleasepool；加密写出加池化与重开验证；批量注解按稳定校验（前序删除自动校正索引）。
- **网络诊断完全设备化**：`ping`/`traceroute`/`dnsLookup`/`tcpProbe` 不再依赖 SSH 主机（删除 hostID/executionTarget/远端命令分支）。**Traceroute 设备实现落地**：未连接的数据报 ICMP 套接字 + 逐跳 IP_TTL，读取中间跳 Time Exceeded 源地址，两探针/跳、逐跳 RTT。四个工具不再带远端执行标签（远端被禁时仍可用，本地只读诊断不触发人工审批）。
- **工具缺陷**：
  - `image.ocr` 可直接读取生成图/浏览器与 VNC 截图的应用存储 artifact（此前提示"文件不存在"）；本地模型与检索支持 `createImage` 别名。
  - `readSheet` 对无缓存值的公式单元格返回 `=公式`（与 inspect 一致）。
  - `pdf_export` 新增 `overwrite` 显式覆盖（默认不覆盖）。
  - `preview.start` 宽容解析：root 传文件自动取父目录、entry 支持工作区相对路径与常见入口回退、错误信息带目录清单；修复入口失败时的监听器泄漏。
  - 下载类工具（前台 `network.download` 与后台 `jobs.submit`）：冲突不再静默搬到应用存储；无 `overwrite=true` 时显式失败并提示用户确认后重试，同意后原子替换；后台下载加 HTTP 2xx 校验、重启后经工作区书签重新挂载，并只中断已无系统任务的孤儿下载。
- **内部收口**：厂商识别（ProviderTraits）与工具名拼写（ToolNameSpelling）唯一实现；SHA 摘要、文件限额、原子提交器、artifact 存储共享；PDF 操作仓前日志（崩溃归因）与 TestFlight 崩溃反馈自动拉取。

### English

Large stability upgrade: global reasoning replay fixes the thinking-mode 400 across Chat/Responses/Anthropic; PDFedit crash surface hardened (thread-confined serial PDFKit queue, ObjC exception firewall, main-owned reader with near-real-time refresh, safe page reorder, per-page memory pools, pooled encrypted writes); network diagnostics are fully device-local with a real device ICMP traceroute; OCR reads app-storage artifacts, readSheet exposes uncached formulas, pdf export gained explicit overwrite, preview resolution is forgiving, and downloads require explicit overwrite consent instead of silently relocating. Provider/name-spelling logic, digests, file limits, atomic commits and the artifact store are now single shared implementations, with PDF operation journaling and automatic TestFlight crash-feedback retrieval.
