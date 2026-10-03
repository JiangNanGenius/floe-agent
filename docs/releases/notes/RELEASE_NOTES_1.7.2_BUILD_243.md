# Floe Agent 1.7.2 — Build 243

## 简体中文

- IDE 的 Git 面板现在使用当前文件工作区的源码管理状态；紧凑侧栏中的同步操作与仓库状态保持一致。
- 修复跨任务历史读取中长分页结果被工具输出边界截断的问题，保留可解析的 JSON 和继续读取所需的游标。
- 修复调用方取消任务但尚未发出显式停止时，模型流可能持续等待的问题；该运行会进入可恢复的失败状态。
- 本地模型不会把“不要调用 web.search”一类否定指令当作必须执行的搜索；提供商请求的 JSON 字段顺序保持稳定，减少相同工具定义造成的前缀缓存失效。

此构建先交付内部 TestFlight，随后按外部测试送审流程继续。上述行为仍需在实际 iPad 上验证；安装后的设备表现与自动化测试结果分别记录。

## English

- The IDE Git pane now follows the active file workspace's source-control state; sync actions in the compact sidebar stay aligned with that repository.
- Fixes long cross-task history pages being cut at the tool-output boundary, preserving parseable JSON and the cursor needed to continue reading.
- Fixes a model stream that could keep waiting after its calling task was cancelled without an explicit stop; the run now ends in a recoverable failure state.
- Local models no longer treat negated instructions such as “do not call web.search” as required searches. Provider request JSON now has stable key ordering so identical tool definitions can reuse prompt prefixes.

This build reached internal TestFlight first and is then handled by the external beta review flow. These behaviors still need verification on a physical iPad; device results are tracked separately from automated tests.
