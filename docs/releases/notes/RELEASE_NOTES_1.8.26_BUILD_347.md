# Floe Agent 1.8.26（347）

## 简体中文

改善换机后旧 Linux 环境的容量整理：区分历史记录缺失与无法读取，安全识别旧命名空间中的原生回执，并在详细信息中显示具体失败阶段。整理仍会核对旧环境归属与磁盘身份，保留不能安全确认的资料。

修复从设置发起的 Linux 缓存清理无法打开共享环境的问题。专用清理任务可使用终端检查 apt、pip、npm 缓存；没有模型时保留应用内自动清理流程。

修复选择题自定义回答偶发显示“未保存答案”，并仅在运行环境确实支持 GPU 时展示显存设置。

本次只提供内部 TestFlight 测试。请在换机后的 iPad 上核对真实可回收量、设置清理任务、自定义回答与执行环境设置。未提交公开 TestFlight 或正式 App Store 审核。

## English

Improves storage optimization after device migration. The app distinguishes missing history from unreadable history, recognizes native receipts in legacy namespaces, and shows the exact failure stage in details. Ownership and disk identity checks still protect data whose origin cannot be confirmed.

Fixes the Linux cache cleanup task launched from Settings so it can open the shared environment. The dedicated task can inspect apt, pip, and npm caches through the terminal; an in-app cleanup path remains available without a model.

Fixes custom answers in choice prompts occasionally appearing unsaved, and shows GPU memory controls only when the runtime actually supports GPU acceleration.

This is an internal TestFlight build only. On a migrated iPad, verify actual reclaimed storage, the Settings cleanup task, custom answers, and execution environment controls. No public TestFlight or formal App Store submission.
