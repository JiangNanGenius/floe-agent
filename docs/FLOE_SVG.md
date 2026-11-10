# Floe SVG 渲染与 PNG/JPEG 转换 / Floe SVG Rendering & PNG/JPEG Conversion

聊天预览与图片导出共用本地渲染器。
Chat previews and image exports share the local renderer.

## 聊天内 SVG 预览 / Fenced SVG chat preview

- ```` ```svg ```` 代码围栏在聊天中通过共享的原生有界渲染器显示实际图形；源码仍然完整可见、可选中、可复制，预览失败或不完整时自动回退到源码并给出简明双语提示。
- A ` ```svg ` fence renders its picture through one shared, bounded native renderer; the source stays fully visible, selectable and copyable, and any incomplete or rejected document falls back to the source with one concise bilingual line.
- 流式生成的 SVG 尚不完整时显示源码；相同字节命中有界预览缓存，重复刷新不会重复渲染。取消按钮会通过原生取消令牌真正中止渲染，并对迟到回调设代际围栏。
- An incomplete streamed SVG stays on the source surface; identical bytes replay from the bounded preview cache. The Cancel button cancels the native render token and fences late completions by generation.
- 预览图片在内存中直接分享（PNG Transferable），不写临时文件；渲染尺寸即真实像素尺寸（例如 `120×80`）。
- The preview shares the in-memory PNG via Transferable — no temp file — and states the real pixel size (e.g. `120×80`).

## AI 工具 `image.renderSVG` / The `image.renderSVG` tool

- 输入：`svg`（内联源码）或 `path`（工作区 `.svg`）二选一；输出 `png`（保留 alpha，可选透明/白色/`#rrggbb` 底色）或 `jpeg`（始终白色底）。`width`/`height` 为目标像素（16–4096，单边缺省时按文档宽高比推导；总量 ≤ 40 MP）。
- Input: exactly one of inline `svg` or workspace `path`. Output `png` (alpha preserved; optional backdrop) or `jpeg` (always over white). One requested edge follows the document aspect; ceilings 16–4096 per edge, ≤ 40 MP total.
- 产出真实可重开的文件：写入前用 ImageIO 重开校验容器/尺寸/alpha；写入采用同目录独占 staging + `link` 提交，绝不覆盖既有输出；摘要返回 `width/height/alpha/mime/bytes/sha256` 均来自实际字节。绑定运行沿用标准 run-output 收据链（与 `image.qr.generate` 相同的 S3-D 契约），聊天卡片可直接预览/分享/复用。
- Outputs are truthfully reopened with ImageIO before writing; the commit is an exclusive same-directory staged link that never overwrites. Reported size/alpha/MIME/bytes/SHA-256 are measured from the written bytes. Bound runs publish a standard S3-D run-output receipt (same contract as `image.qr.generate`), so the chat card can preview, share and re-read it.
- 默认输出名由受信任的调用身份 + 渲染参数派生：同一调用重试可幂等恢复收据，任何参数变化落到不同路径；无绑定的直接调用使用随机身份。
- Default file names derive from the trusted call identity plus the exact render options: a same-call retry is idempotent, any option change lands on a different path, and unbound direct use gets a random identity.

## 安全模型 / Safety model

所有 SVG 均为不可信输入。共享验证器 `SVGDocumentValidator`（FloeImages）在任何渲染前强制执行：

All SVG is untrusted input. The shared `SVGDocumentValidator` (FloeImages) enforces, before anything renders:

- 正向静态白名单：几何、文字、渐变/图案、裁剪/蒙版与常用静态滤镜；未知元素、未知命名空间、非白名单属性一律拒绝。
- Positive static allowlists: geometry, text, gradients/patterns, clip/mask and a common filter subset; unknown elements, namespaces and attributes are rejected.
- 拒绝：脚本/事件、`animate/set` 等动画、DTD/实体、处理指令、外部/`file:`/`data:` 引用；`href` 仅允许内部 `#fragment`。
- Rejected: scripts/events, animation, DTD/entities, processing instructions, external/file/data references; `href` only as internal `#fragment`.
- CSS 保守验证：完整累积 `<style>` 文本后统一校验，解码注释与反斜杠转义，拒绝 `@`-规则、`url(非#)` 与外链。CSP 仅为纵深防御，不是放行依据。
- Conservative CSS: the full accumulated `<style>` text is validated once (comment/escape decoding first); `@`-rules, non-fragment `url()` and remote loads are rejected. CSP is defense in depth, not evidence.
- 资源上限：源码 ≤ 1 MiB，元素 ≤ 20 000，深度 ≤ 64，`<style>` ≤ 256 KiB；内部引用图必须无环、链深 ≤ 32、聚合展开 ≤ 50 000；重复 id 拒绝。渲染并发 ≤ 2，导航/快照各有硬超时，并接受原生取消旗标（非仅 Swift Task）。
- Ceilings: 1 MiB source, 20 000 elements, depth 64, 256 KiB `<style>`; the internal reference graph must be cycle-free, chain depth ≤ 32 and aggregate expansion ≤ 50 000; duplicate ids are rejected. Rendering is capped at 2 concurrent renders with hard timeouts and honors the native cancellation flag (not only Swift Task cancellation).

渲染本身使用禁用 JavaScript 的 WKWebView：无 baseURL、严格 CSP、导航代理只放行首个主文档加载；WebKit 在内存生成透明 PDF，再由 CoreGraphics 按指定像素尺寸栅格化；该 PDF 不作为外部文档打开或落盘，输出尺寸经重开校验。

Rendering uses a JavaScript-disabled WKWebView: no baseURL, strict CSP, and the navigation delegate admits only the first main-document load. WebKit produces a transparent PDF in memory, then CoreGraphics rasterizes that generated page at the requested pixel dimensions. The generated PDF is never opened as an external document or saved; reported sizes are verified real pixels.

## 相关代码 / Where

| 文件 | 角色 |
| --- | --- |
| `FloeAgent/Sources/FloeImages/SVGDocument.swift` | 验证器、尺寸与上限（纯 Foundation，跨平台） |
| `FloeAgent/Sources/FloeImages/SVGRenderer.swift` | 共享有界渲染器（WebKit、门限、缓存、取消） |
| `FloeAgent/Sources/FloeImages/SVGRenderTool.swift` | `image.renderSVG` 工具（独占提交、重开校验、S3-D 收据） |
| `FloeAgent/FloeApp/Chat/Render/SVGCodeBlockView.swift` | 聊天 SVG 围栏预览/回退面 |
| `FloeAgent/FloeApp/Chat/Render/CodeBlockView.swift` | svg 围栏路由（其余行为不变） |
| `FloeAgent/FloeApp/Chat/Render/RunOutputImagePreviewLoader.swift` | SVG run-output 收据的有界预览分支 |

遗留 `image.svgDocument`（FloeExecution Compatibility）仍只做 XML 检查/编辑、`compatibilityOnly` 注册；它不渲染，也未被本能力取代或复活任何已移除的执行别名。

The legacy `image.svgDocument` (FloeExecution Compatibility) still only inspects/edits XML and stays `compatibilityOnly`; it does not render, and this capability revives no removed execution alias.
