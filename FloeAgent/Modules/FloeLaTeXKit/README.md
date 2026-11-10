# Floe LaTeX workbench

Reusable Apple-native editor and project services for personal writing with AI assistance. No human multiplayer collaboration is included. The module's UI and storage do not depend on Space, Notes, chat view state or AppEnvironment.

The production App uses the reviewed native XeTeX/BibTeX → XDV → Apple PDF path. It resolves the current document's packages, fonts and transitive dependencies on demand and reuses verified cached files; it has no minimal/full installation choice and does not prefetch another document's missing resources. The old experimental GPL PDF archive remains excluded. Source, selected licenses and actual archive audits are recorded in [Native/README.md](Native/README.md) and [THIRD_PARTY.md](THIRD_PARTY.md).

## Implemented components

- Source files, templates, nested assets, main-file/engine selection, bounded ZIP import/export, validated paths and digests.
- Atomic multi-file revisions, compare-and-swap, stable mutation receipts, recoverable history, restore-as-new-revision and immutable build snapshots.
- Lossless LaTeX structure and inline projections; native source editor, visual prose, formatted text, math renderer injection, headings, abstracts, lists, ordinary tables, figures, citations and paper metadata. Custom macros/complex constructs remain editable as exact source.
- BibTeX parsing/editing, real citation keys, missing/duplicate checks, project-wide search/replace, diagnostics, build history and forward/reverse SyncTeX.
- Service-owned compilation/cancellation independent of editor lifetime. Unknown environment-worker termination retains the snapshot and blocks duplicate launches, including after process restart.
- The App's native route supports XeLaTeX and BibTeX, real embedded font glyphs and legacy math outlines, images/PDF pages, document metadata, named destinations, bookmarks and internal links. Unsupported engines, helpers or PDF specials fail explicitly; this route never silently switches to Linux.
- The separate legacy Linux worker retains its installed-engine orchestration and namespace checks for explicitly composed hosts. Its broader engine/helper matrix is independent of native App capability and is not an automatic fallback.
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

`LaTeXEditorSession.typesetAction` enters the existing durable task/original authorization route. Native typesetting owns no Linux environment, shell job or package-installation profile. Capability facts may be cached; prior call contexts and grants are not reused for later execution. Space, task and Notes originals keep their existing ownership and revision checks.

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

主 App 使用已替换 PDF 底层的原生 XeTeX／BibTeX → XDV → Apple PDF 链路。按照当前文章实际引用的宏包、字体及传递依赖按需下载，已有缓存直接复用；没有“精简／完整”档位，也不顺带预取其他文章缺失的资源。旧原生实验中的 GPL PDF 静态库继续隔离，正式构件有独立的来源、所选许可证和实际对象审计记录。

原生路径支持 XeLaTeX、BibTeX、字体与传统数学字形、图片／PDF 页面、文档信息、命名目标、目录与内部链接。不支持的引擎、辅助程序或 PDF 指令明确报错，不自动转到 Linux。另保留给独立宿主明确组合的旧 Linux worker，其能力与隔离验证不代表主 App 原生能力。

宿主负责通过既有服务提供实际原件授权、任务／环境绑定、文件回传和受保护的 PDF 预览。工程归属沿用空间、任务或手记，不因调用编辑器而迁移或复制。共享服务不依赖视图生命周期；取消必须确认工作进程停止，状态不明则保留快照与占用。

主 App 的实际普通文章与公式排版、资源补齐、保存重开和进入 C 引擎后的取消已在固定 iPad 模拟器通过；PDF 绘制、目录和链接另有实际读回测试。模拟器结果不等于实物设备、全部宏包或 Apple 审核通过。

## Main App integration status

The App composes the shared services in `FloeApp/Space/LaTeX`: Space templates/import/file actions, task-owned originals, Notes-owned document lists, native source/visual editing, protected PDF/SyncTeX, durable run ownership, six model tools and verified output publication. `latex.typeset prepare` resolves an immutable revision through the native engine and document-resource cache. Resource downloads respect the task networking policy and offline setting. Notes assistants retain their actual `notes` purpose and NotesStore scope.

The native replacement passed both actual arm64 platform builds and Cargo/object closure audits. The actual App/runner object build, four PDF renderer cases, ordinary article/math PDF preparation and same-original reopen, and cancellation after C entry passed with Xcode 27.2. The earlier Linux matrix and old experimental host remain separate historical evidence; they are not used as native App qualification or publication proof.

中文：空间、任务和手记使用各自授权的同一原件；排版使用新原生链路，缺少的资源按文章补齐。新构件的两个 arm64 平台、主 App 对象构建、实际 PDF 与取消均有独立通过记录；实物设备、其他引擎及分发状态另行核验。
