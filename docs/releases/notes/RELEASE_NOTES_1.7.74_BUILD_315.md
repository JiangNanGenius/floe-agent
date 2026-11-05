# Floe Agent 1.7.74 (315)

## 简体中文

- 优化本机运行环境的任务调度，减少计算过程中的线程交接和重复唤醒。
- 修复部分技能处理符号链接文件失败的问题，保留目录访问边界和只读保护。
- 修正助手读取 Office 页面时图像上下颠倒的问题。
- 保留现有项目文件、已安装依赖和运行环境，无需重新下载或重置。

## English

- Optimized local runtime scheduling to reduce worker handoffs and redundant wakeups during computation.
- Fixed symbolic-link file operations used by some skills while retaining directory containment and read-only protection.
- Corrected vertically flipped Office page images sent to the assistant.
- Preserves existing project files, installed dependencies and the runtime without downloading or resetting the environment.
