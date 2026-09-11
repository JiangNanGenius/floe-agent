# Floe Agent 1.6.6 (142) 发布核验 / Release Verification

> 日期：2026-09-12（UTC）。结论：**TestFlight 已上架且可见性核验通过**。

## 源码与门禁

| 项 | 值 |
|---|---|
| 标签 | `v1.6.6`（annotated，指向 `3133938`） |
| 源码 SHA | `3133938`（main；后续 `e978ffa` 仅修复 CI workflow 换行） |
| 发布流 | run [34643832726](https://github.com/JiangNanGenius/floe-agent/actions/runs/34643832726) — 三 job 全绿（TestFlight job 首跑遇 BrowserProtocolTests WebKit 截图已知瞬时故障，rerun --failed 通过；该 flake 已连续 4 个版本复现） |
| 附加修复 | `xcode-cloud-control.yml` 的 `verify-testflight` 步骤缺换行导致 422，已在 `e978ffa` 修复 |

## Apple 侧核验

| 项 | 值 |
|---|---|
| ASC build ID | `fa026b83-fc17-4dbd-98ba-922fe97be3a2` |
| 版本/构建号 | 1.6.6 / 142 |
| processingState | **VALID** |
| buildAudienceType | APP_STORE_ELIGIBLE |
| Beta 组 | 恰好一个 `Floe QA`（internal=true，无公开链接），意外组 0 |
| 核验 run | discover [34659659703](https://github.com/JiangNanGenius/floe-agent/actions/runs/34659659703)；verify-testflight [34659762741](https://github.com/JiangNanGenius/floe-agent/actions/runs/34659762741) |

## 内容摘要

全局 reasoning 回放（Chat/Responses/Anthropic，修 thinking 模式 400）；PDFedit 稳定性（线程封闭 PDFKit 串行队列、ObjC++ 异常防火墙、主线程阅读器 + 编辑提交即时刷新、安全重排、每页内存池）；网络诊断纯设备化 + 设备 ICMP traceroute；工具修复（OCR artifact、readSheet 公式、pdf_export overwrite、preview 宽容解析、下载显式覆盖同意与重启书签重挂载）；内部收口（ProviderTraits/ToolNameSpelling/Digest/FileLimits/AtomicFileCommitter/FloeArtifactStore）+ PDF 操作日志与 TestFlight 崩溃反馈自动拉取；floe-network 1.1.3。

## 遗留跟踪

- BrowserProtocolTests WebKit 截图 flake（4 次）：需要测试侧重试/去抖。
- W5 清扫剩余：XLSX 双读者完全合并、31×output 工厂、内联 SHA 收敛、SSH 会话复用、NetSupport 抽取、PathGuard 访问策略全量迁移。
- PDF 加密写出仍走 PDFKit（已加异常防火墙 + autoreleasepool + 重开验证），CGPDFContext 替换待评估（会改变注解保真语义）。
