# Floe LaTeX workbench

Reusable Apple-native editor and project services for personal writing with AI assistance. No human multiplayer collaboration is included. The module's UI and storage do not depend on Space, Notes, chat view state or AppEnvironment.

The **production package has no embedded native TeX binary**. The fixed full-toolchain worker uses the App's explicitly resolved Linux `exec.shell`/background jobs. The separate native Tectonic experiment passed engineering checks but contains copyleft dependencies; it is excluded from the production graph. Read [THIRD_PARTY.md](THIRD_PARTY.md) before changing that boundary.

## Implemented components

- Source files, templates, nested assets, main-file/engine selection, bounded ZIP import/export, validated paths and digests.
- Atomic multi-file revisions, compare-and-swap, stable mutation receipts, recoverable history, restore-as-new-revision and immutable build snapshots.
- Lossless LaTeX structure and inline projections; native source editor, visual prose, formatted text, math renderer injection, headings, abstracts, lists, ordinary tables, figures, citations and paper metadata. Custom macros/complex constructs remain editable as exact source.
- BibTeX parsing/editing, real citation keys, missing/duplicate checks, project-wide search/replace, diagnostics, build history and forward/reverse SyncTeX.
- Service-owned compilation/cancellation independent of editor lifetime. Unknown environment-worker termination retains the snapshot and blocks duplicate launches, including after process restart.
- Fixed worker orchestrates installed XeLaTeX, LuaLaTeX, pdfLaTeX and LaTeX/DVI, BibTeX/Biber, indexes, glossaries and reruns. Shell escape and project `.latexmkrc` execution are disabled. Offline compilation requires verified network isolation in the selected environment.
- Every TeX/helper process uses a verified Linux namespace: read-only toolchain/source, private writable output/cache, isolated network/PIDs and a fixed environment variable set. The selected Linux environment must provide working `bubblewrap`; missing isolation fails before compilation.
- Complete receipts and outputs are read back in bounded chunks, checked against exact lengths/digests, and saved in the project before remote staging cleanup. Failure logs remain available for repair.

## App composition

Add the single `FloeLaTeXKit` product. Native views use `LaTeXEditorSession` and `LaTeXWorkbench` with the host's existing protected PDF reader and formula renderer. The module does not construct another PDFKit rendering path or duplicate the host's SwiftMath font bundle.

The separate `Integration/FloeLaTeXHostAdapter` package provides `LaTeXHostServices`, `LaTeXHostHooks`, `LaTeXShellTransport` and these tools:

| Tool | Operation |
| --- | --- |
| `latex.create` | Create a complete template in the real invocation's owner |
| `latex.inspect` | Read project/revision, paged source/structure/references/search/history/builds |
| `latex.edit` | Typed multi-file transaction with revision and stable mutation ID |
| `latex.typeset` | Prepare actual toolchain capabilities; start/status/cancel with saved outcomes |
| `latex.restore` | Restore an inspected revision while preserving later history |
| `latex.export` | Publish an actual verified PDF or source ZIP through the host's file-return service |

The App supplies compiled hooks for current-run/binding checks, exact-original access/usage lease, owner-derived creation, file publication and metadata synchronization. Model JSON cannot select a host root or grant access. A newly created task artifact remains task-owned; a note attachment remains note-owned; placing or opening it in Space does not create a second original.

`LaTeXEditorSession.typesetAction` lets a genuine native Typeset callback enter the existing durable task/environment/approval route. Capability facts may be cached; prior call contexts, grants and transports are not reused for later execution. Main App route registration, Space/Notes ownership hooks and actual Linux engine qualification must be verified in that App; the independent qualification host does not prove them.

## Focused checks

Use a task-specific external scratch path for SwiftPM. The project resource policy serializes actual native builds and pinned-iPad tests.

```sh
swift test --package-path FloeAgent/Modules/FloeLaTeXKit --scratch-path <cache>/core --jobs 2
swift test --package-path FloeAgent/Modules/FloeLaTeXKit/Integration/FloeLaTeXHostAdapter --scratch-path <cache>/host-adapter --jobs 2
python3 -B FloeAgent/Modules/FloeLaTeXKit/Tests/WorkerProtocol/test_worker.py
python3 -B FloeAgent/Modules/FloeLaTeXKit/Native/Scripts/verify_production_boundary.py
python3 -B FloeAgent/Modules/FloeLaTeXKit/Native/Scripts/apply_host_patch.py --check
```

Worker protocol fixtures are explicitly synthetic. They verify transfer/orchestration, log retention, process termination and cleanup, not actual installed TeX engines. The [qualification guide](../../Qualification/LaTeX/README.md) separates the actual Linux engine/PDF/isolation checks from the independent iPad engineering host, which uses the quarantined native experiment. Neither replaces main-App acceptance or Apple review.

---

# 中文说明

该模块提供整个 App 可复用的原生 LaTeX 工作台：源码与可视化写作、工程文件、文献、公式、表格、图片、历史恢复、搜索替换、ZIP 与 PDF 导出，以及模型可调用的工程和排版工具。未知宏与复杂排版保持原始源码，最终论文版面以实际 TeX 生成的 PDF 为准。

正式包不嵌入原生 TeX 实验库。完整排版工具链复用 App 现有、明确绑定任务的 Linux 环境与 `exec.shell`／jobs；按真实探测结果提供四种引擎和辅助程序，不回退到宿主解释器。原生 Tectonic 实验虽然已生成真实 PDF，但依赖闭包含 GPL／LGPL，不能仅依据根 MIT 标签直接接入主 App；来源、版本、补丁及字体／宏包清单见许可文件。

TeX 与辅助进程使用经过实测的 Linux 文件、网络与进程命名空间，只挂载只读工具链／源码和本次输出／缓存，并移除无关环境变量。缺少可工作的 `bubblewrap` 时先明确提示准备环境，不以放宽文件访问或使用宿主解释器代替隔离。

宿主负责通过既有服务提供实际原件授权、任务／环境绑定、文件回传和受保护的 PDF 预览。工程归属沿用空间、任务或手记，不因调用编辑器而迁移或复制。共享服务不依赖视图生命周期；取消必须确认工作进程停止，状态不明则保留快照与占用。

当前独立宿主与协议测试的通过不能替代主 App 接入、真实 Linux 引擎验证或 Apple 审核。后续界面优化以同一工程和服务为基础进行。

## Main App integration status

The App now composes the shared services in `FloeApp/Space/LaTeX`: Space templates/import/file actions, task-owned originals, Notes-owned document lists, native source/visual editing, guarded PDF/SyncTeX, real saved run/environment ownership, six model tools and verified output publication. `latex.typeset prepare` can check or explicitly install the fixed standard/full Debian TeX Live profile through the existing `exec.shell`/jobs service. Offline typesetting does not request a network grant; package downloads retain the task network policy. Notes assistants keep their real `notes` purpose and NotesStore scope.

The frozen integration passed the actual local App and focused unit/UI runner build with Xcode 27.2. Eight new App/adapter contracts compiled but have not run. Mainline owns final Simulator, model and actual App Linux qualification. The independent real Linux matrix (11 cases) and isolation/timeout/cancellation checks (3 cases) remain separate evidence. No native Tectonic experimental dependency, version change or distribution is included.

中文：空间、任务、手记的共享原件和编辑器已接入主 App；常用／完整工具链只通过既有 Linux 执行服务准备。手记保留自己的归属和授权。冻结接线的主 App 及定向测试程序构建通过，8 项新增契约尚未运行；真实模型、App Linux 排版和最终模拟器验收由主线继续完成，不能把独立 Linux 或原生实验的结果当作整个 App 已可用。
