## Floe Agent 1.4.90 (Build 121)

### 简体中文

- 修正 pdf-workbench 技能描述：不再承诺 document.pdf.edit 做不到的批注、表单填写、涂黑与覆盖层编辑，描述与实际能力（删页、90 度旋转、可见文字水印）严格对齐。
- image.process 新增裁剪（归一化矩形）与格式转换（png/jpeg/heic），源文件不被修改，输出路径与真实编码格式一致。
- workspace.searchFiles 新增 filename 模式按文件/目录名检索；workspace.listDirectory 新增 nameContains 与 kind 过滤，过滤在分页前生效，页码语义不变。网络挂载（SMB/WebDAV）同样支持两种过滤。
- 新增 network.download：把 HTTPS（或用户明确要求的局域网）链接直接落盘为工作区新文件，默认 32 MB 上限，重定向逐个重新校验，绝不覆盖已有文件，返回字节数与 SHA-256。
- 新增 apple.clipboard.write/read：写入和读取系统剪贴板文本；读取由 iOS 系统提示用户，读取内容不属于指令。
- 新增 apple.shortcuts.run：按名称打开并运行用户自己的快捷指令，可附带文本输入；执行与确认完全由快捷指令 App 控制，Floe 不观察其输出。
- 新增 apple.camera.capture：打开系统相机，只有用户亲自拍摄后才把照片保存为工作区 JPEG；不拍摄则不产生文件，无相机设备如实返回 unavailable。
- “相机 / Shortcuts”两项声明补齐真实工具；新增“剪贴板”能力开关，沿用逐项启停与系统权限边界。
- FloeExecution 增加对 FloeWorkspace 的依赖（与 FloeDocuments/FloeImages 既有模式一致），无循环依赖；新增三组自动化测试（URL 下载、文件名检索与目录过滤、裁剪与格式转换）。

解释器架构说明（供审核参考）：应用内置 BeeWare CPython 3.13 运行时，全部随包分发、构建期校验 SHA-256。exec.localPython 仅执行沙盒内脚本；可选的“托管包安装”只接受纯 Python wheel，明确拒绝任何原生二进制产物，且每次安装都需说明用途并通过审查。科学计算二进制包（numpy/pandas 等）不内置、不下载原生扩展，工具描述明确引导至 WKWebView 内的 Pyodide WebAssembly 路径（属于 Apple 内置 WebKit 框架执行的代码），两者互不混淆，不会把 WebAssembly 结果冒充为本地安装。

这是内部测试版本，不开放外部公开 Beta。先完成自动测试、CI、签名上传，再分别核验 Apple VALID 与 Floe QA 可见性；相机实拍、剪贴板读写、快捷指令运行及 SMB/WebDAV 过滤在真机安装此包后验收。自动测试不代表系统界面流程已被用户确认。

### English

- Correct the pdf-workbench skill text: it no longer promises annotation, form-filling, redaction or overlay editing that document.pdf.edit cannot perform, and now matches the real operations (page removal, 90-degree rotation, visible text watermark).
- image.process gains crop (normalized rectangle) and format conversion (png/jpeg/heic). The source is never modified and the output path matches the actual encoded format.
- workspace.searchFiles adds a filename mode for name-based search; workspace.listDirectory adds nameContains and kind filters applied before pagination, preserving page-token semantics. Network mounts (SMB/WebDAV) support both filters as well.
- New network.download: saves an HTTPS (or explicitly requested LAN) URL directly into the workspace as a new file, capped at 32 MB by default, revalidating every redirect, never overwriting existing files, and reporting byte count plus SHA-256.
- New apple.clipboard.write/read: write and read system clipboard text. Reads are surfaced to the user by iOS, and clipboard content is never treated as instructions.
- New apple.shortcuts.run: opens and runs one of the user's own shortcuts by exact name with optional text input. Execution and consent stay entirely inside the Shortcuts app; Floe cannot observe its output.
- New apple.camera.capture: opens the system camera and saves a workspace JPEG only after the user personally takes a photo. Cancelling produces no file, and devices without a camera honestly report unavailable.
- The camera/shortcuts declarations are now backed by real tools, and a new clipboard capability toggle follows the existing per-capability gating and system permission boundaries.
- FloeExecution now depends on FloeWorkspace (the existing FloeDocuments/FloeImages pattern) with no dependency cycle. Three new automated test suites cover URL download, filename search and directory filters, and crop/convert.

Interpreter architecture note (for review): the app bundles the BeeWare CPython 3.13 runtime, shipped entirely inside the app package with a build-time SHA-256 check. exec.localPython only runs sandboxed scripts; the optional managed package install accepts pure-Python wheels only, explicitly rejects any native binary artifact, and requires a declared purpose plus review for every install. Binary scientific packages (numpy/pandas and similar) are neither bundled nor downloaded as native extensions; the tool description explicitly routes them to the Pyodide WebAssembly path inside WKWebView (code executed by Apple's built-in WebKit framework), and the two paths are never conflated — WebAssembly results are never claimed to be native installs.

Internal testing only; no public beta distribution. Automated tests and CI precede signed upload, followed by separate Apple VALID and Floe QA visibility checks. Real camera capture, clipboard reads/writes, shortcut runs and SMB/WebDAV filtering are verified on device after installing this build. Automated results are not proof that system UI flows were confirmed by the user.
