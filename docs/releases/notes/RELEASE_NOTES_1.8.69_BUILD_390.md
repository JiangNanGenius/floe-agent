# Floe Agent 1.8.69（390）

## 简体中文

- 密集到达的消息和互动卡片按消息 ID 合并。聊天保留已加载的内容，跳到搜索结果和返回最新消息都使用稳定的滚动定位。
- 游戏工作台可识别和运行完整的 TyranoScript 网页导出。兼容的 Ren’Py 桌面游戏可从编译后的 RPA 档案准备网页运行版本。
- 游戏工程缺少可获取的运行资源时，可以在运行前准备。模型可以用 `game.runtime` 为尚未完成的工程下载对应的已校验资源。Ren’Py 会一并准备 SDK 和 Web 支持包。
- 工作区接受单文件 Git 补丁。行号移动时可按唯一的完整上下文定位，保留 UTF-8 BOM 和原换行。
- 已验证重建凭证且任务仍绑定原 Linux 位置时，可以在下一次执行前接续原任务。
- Linux 虚拟 CPU 在支持的设备上使用预编译指令加速 AES 和 64 位多项式乘法。虚拟机继续使用无 JIT 的解释器。

## English

- Merge bursts of messages and interactive cards by message ID. Chat keeps the loaded transcript visible and uses stable scroll positions when jumping to search hits or returning to the latest message.
- Open and run complete TyranoScript web exports in the game workbench. Compatible Ren’Py desktop games can prepare a web build from their compiled RPA archives.
- Prepare available runtime resources before running a project. The model can use `game.runtime` to acquire verified resources while a game is still in progress. Ren’Py prepares the SDK together with its matching Web support.
- Apply single-file Git patches. When line numbers shift, match unique exact context and preserve the file’s UTF-8 BOM and line endings.
- Resume a task at its saved Linux location when the committed recovery is verified and the location still matches.
- Use ahead-of-time instructions for AES and 64-bit polynomial multiplication on supported devices. The Linux guest continues to run with the JIT-free interpreter.
