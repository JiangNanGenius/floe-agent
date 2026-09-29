# Floe Agent 1.7.0 — Build 235

## 简体中文

本候选版本改进 Linux 镜像校验的内存使用、取消与原生下载进度刷新。本地模型现在区分错误工具名称，隐藏未执行的调用 JSON，并通过一次受限纠正请求真实工具。Floe 助手入口统一使用手记的双对话气泡图标。

Office 宿主恢复上游 WebKit 终止清理，并增加有界渲染停滞诊断；已完成宿主编译、链接和资源校验。PPT 静置闪退根因仍未确认，字体覆盖及 iPad 编辑保存仍需验收。本地模型搜索回答可靠性也不能由受控测试证明，真实权重复测通过两轮文件工具，但搜索回执回答仍失败，第二次搜索未执行；测试平台为 macOS，非 iPad。上述遗留问题不宣称已经解决。

完整 App 编译、IPA 保留、Apple 校验和私有 Floe QA 可安装状态仍须分别核实。详见[候选修复证据](FLOE_235_FEEDBACK_REPAIR.md)。

## English

This candidate improves memory use, cancellation and native progress updates during Linux image verification and installation. Local-model handling now distinguishes rejected tool names, withholds unexecuted call JSON and allows one bounded correction using an admitted tool. Floe assistant entries consistently use the Notes double-bubble icon.

The Office host restores upstream WebKit termination cleanup and adds bounded render-stall diagnostics. Host compilation, linking and resource verification are complete. The PPT idle-crash cause remains unconfirmed; font coverage and iPad editing/save behavior still require acceptance. Deterministic tests do not establish local-model search-answer reliability; real-weight testing passed two file-tool rounds but failed the first search-answer receipt check; the second search was not reached. That test ran on macOS, not iPad. These outstanding issues are not claimed as resolved.

Full App compilation, saved IPA, Apple validation and private Floe QA availability require separate verification. See the [candidate evidence](FLOE_235_FEEDBACK_REPAIR.md).
