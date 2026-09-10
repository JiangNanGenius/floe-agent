## Floe Agent 1.6.2 (Build 137)

### 简体中文

本版为工具链可靠性与中文文档体验的整体升级。签名上传、Apple 处理和 Floe QA 可见性分别核验；发布说明本身不代表已经可以安装。

- 新增后台任务（jobs.*）：大文件下载与 Python 数据抓取/清洗可提交为后台任务，立即返回 jobID，不再阻塞当前任务；支持进度查询、结果回收、取消与应用挂起后续传（断点透明续传，上限 2 GB）。任务完成自动回注对话并发送本地通知。
- 内置 9 族核心可商用中文字体的精选字重（思源黑体/宋体简繁、霞鹜文楷、HarmonyOS Sans、MiSans、阿里巴巴普惠体 3.0、更纱黑体 Mono，约 340MB），Office 预览/编辑的中文不再显示方框；同一套字体同时注册进系统文字管线，新建 Office 文档默认东亚字体改为思源黑体。另有 19 族展示/书法字体可通过 font.install 自助安装。
- 修复历史会话全文检索（conversation.search 的 SQLite 辅助函数上下文错误）；修复 Office 文档提取/编辑对自闭合 XML 元素（如空白单元格、空段落）的吞并错位——此前会导致提取错位与静默内容丢失。
- 工具调用结果现在作为正式历史随对话回放：模型在多轮后仍能引用此前读取到的内容，不再反复枚举工具目录；schema 预算卸载会明确提示，目录类重复枚举会被护栏拦截，任务清单修订冲突会直接返回当前修订号。常用工具的已加载定义跨任务保留。
- 提示词按静态/动态严格分层，Anthropic 通道增加显式缓存断点，降低长任务 token 开销；单任务工具迭代引入 100 步软预算，失控循环会被强制收尾。
- Office 引擎在启动后空闲时段预热，首次打开文档不再卡主线程数秒。

**已知限制：** 后台任务中的 Python 仍共享单一解释器（串行执行）；PPTX 图表导出限制沿用 1.6.1 说明。scipy/scikit-learn 因 iOS 无 Fortran 工具链不可内置，继续使用 Pyodide 或远程主机。本版安装包因字体与引擎载荷明显增大。

**测试入口：** 后台任务可在任意任务中要求"后台下载/后台跑脚本"；jobs.status/jobs.result 查看进度与结果。字体覆盖可在含中文的 docx/xlsx/pptx 预览与编辑中直接观察。

### English

This beta is a toolchain-reliability and Chinese-document experience upgrade. Signed upload, Apple processing and Floe QA visibility are verified separately; these notes do not establish install availability.

- Add background jobs (jobs.*): large downloads and Python data pulls/cleaning run off the task's critical path with an immediate jobID return, progress/status checks, result collection, cancellation, and suspension-surviving downloads (transparent resume, 2 GB cap). Completion is re-injected into the conversation and posted as a local notification.
- Bundle curated weights of 9 core commercially usable Chinese font families (Source Han Sans/Serif SC+TC, LXGW WenKai, HarmonyOS Sans, MiSans, Alibaba PuHuiTi 3.0, Sarasa Mono; ~340 MB). 19 more display/calligraphy families stay available for on-demand install via font.install. Office preview/editing no longer shows boxes for CJK text; the same set registers into the system text pipeline, and new Office documents default to Source Han Sans SC for East Asian text.
- Fix full-text search over past conversations (SQLite auxiliary-function context error in conversation.search). Fix Office extraction/editing merging self-closing XML elements (empty styled cells, empty paragraphs) into siblings, which caused misaligned extraction and silent content loss.
- Tool results now replay as first-class conversation history: the model retains previously read evidence across turns instead of re-enumerating the catalog; schema-budget eviction is announced; repeated catalog enumeration is intercepted; checklist revision conflicts return the current revision directly; loaded tool definitions persist across runs of one conversation.
- Prompts are strictly layered into static/volatile sections with an explicit Anthropic cache breakpoint, reducing long-task token cost; a 100-step soft tool-iteration budget forces degenerate loops to wrap up.
- The Office engine prewarms after launch so the first document open no longer stalls the main thread for seconds.

**Known limitations:** background Python jobs still share a single interpreter (serialized); the 1.6.1 PPTX chart-export limitation still applies. scipy/scikit-learn cannot ship natively on iOS (no Fortran toolchain) and remain on the Pyodide/remote route. The installer grows noticeably due to the font and engine payloads.

**Try it:** ask any task to "download in the background" or "run a script in the background"; inspect with jobs.status/jobs.result. Font coverage is visible directly in CJK docx/xlsx/pptx preview and editing.
