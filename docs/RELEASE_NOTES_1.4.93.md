## Floe Agent 1.4.93 (Build 124)

### 简体中文

- **二进制 Python 库正式本地内置**：exec.localPython 现在随包内置 **numpy 2.5.2** 与 **Pillow 11.0**（BeeWare 官方 CPython 3.13 iOS wheel，SHA-256 锁定，device+simulator 双切片）。每个扩展模块按既有机制打包为独立签名 XCFramework（24 个），纯 Python 部分进入只读 site-packages；运行时下载原生代码仍然不可能。工具描述已改为如实声明可直接 import；pandas/scipy/matplotlib 因上游暂无 cp313 iOS wheel 仍走 Pyodide 并如实标注。
- **压缩统一入口**：workspace.archive 一个工具覆盖全部常见格式——zip/tar 原生处理，tar.gz/tgz、tar.bz2/tbz2、tar.xz/txz 及单文件 gz/bz2/xz 经由内置 CPython 桥（tarfile/gzip/bz2/lzma）以相同限额（5000 条目/256MB、路径净化、绝不覆盖）处理；不再需要绕到 exec.localPython 手写代码。7z/rar 仍如实不可用。
- **命名修正**：presentation.create 更名 **presentation.createInline**（内联 table/chart/web，与 presentation.createDeck 的 .pptx 文件语义分清）；document.createDocument 更名 **document.createMarkdown**（名字与真实产物一致，createWord 才是 .docx）。旧名字的已保存授权范围不再匹配，再次使用时按常规重新授权一次即可。
- 构建链：scripts/install_python_binary_packages.sh 固定 numpy/Pillow 版本与哈希，project.yml 嵌入块自动生成；本地与 CI 使用完全相同的打包输入。
- 受影响九个 target 共 546 项测试全部通过。

这是内部测试版本，不开放外部公开 Beta。先完成自动测试、CI、签名上传，再分别核验 Apple VALID 与 Floe QA 可见性；numpy/Pillow 真机导入与计算、压缩格式互操作在真机安装此包后验收。

### English

- **Binary Python libraries are now bundled locally**: exec.localPython ships **numpy 2.5.2** and **Pillow 11.0** in the app (official BeeWare CPython 3.13 iOS wheels, SHA-256 pinned, device + simulator slices). Every extension module is packaged as its own signed XCFramework through the existing mechanism (24 frameworks); pure-Python trees live in the read-only site-packages. Runtime download of native code remains impossible. The tool description now honestly says to import them directly; pandas/scipy/matplotlib still route through Pyodide because upstream has not published cp313 iOS wheels.
- **Unified archive entry**: workspace.archive covers every common format in one tool — zip/tar natively, plus tar.gz/tgz, tar.bz2/tbz2, tar.xz/txz and single-file gz/bz2/xz through a bundled-CPython bridge (tarfile/gzip/bz2/lzma) with identical limits (5000 entries / 256 MB, name sanitization, never overwrite). No more detours through exec.localPython. 7z/rar remain honestly unavailable.
- **Naming fixes**: presentation.create is renamed **presentation.createInline** (inline table/chart/web, distinct from presentation.createDeck's .pptx files); document.createDocument is renamed **document.createMarkdown** (name now matches the actual artifact; createWord produces .docx). Saved approvals for the old names no longer match and will be re-confirmed once on next use.
- Build chain: scripts/install_python_binary_packages.sh pins versions and hashes, and regenerates the project.yml embed block so local and CI builds package identical inputs.
- 546 tests across nine affected targets all pass.

Internal testing only; no public beta distribution. Automated tests and CI precede signed upload, followed by separate Apple VALID and Floe QA visibility checks. numpy/Pillow on-device import and computation plus archive-format interop are verified on device after installing this build.
