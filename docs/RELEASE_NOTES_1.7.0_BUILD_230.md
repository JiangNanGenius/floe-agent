# Floe 1.7.0 (230) — release notes / 发布说明

**Status / 状态：发布候选；真机功能待验收。** 本页记录 Build 230 的代码变化。IPA、TestFlight 和 GitHub 预发布状态以发布记录为准。

## 简体中文

- 本地 Qwen 推理的分段预填充现在会及时检查 MLX 错误。错误不会继续流入无效数组并引发越界闪退；设备内存不足时仍可能返回明确的失败。普通短消息的本地提示词按上下文预算缩短，保留工具定义、回执、当前工作区及必要运行信息。云端实权重验证完成了两轮独立的文件读取工具调用、真实回执和模型续答；这不是 iPad 推理验收。
- PPT 编辑宿主修正了首帧判定：布局切换后确实绘制的编辑画面可以被识别，即使引擎复用了预览图块。未确认绘制的页面仍不能报告可保存。IDE 连续切换 Office 标签会重新触发对应文件的加载；Office 会话关闭与保存回执继续按单次结算。
- 新的原生 Office 宿主和资源使用固定版本与摘要。云端完整 App 编译、Notes／工作区／IDE 的模拟器入口检查通过；当前宿主只提供 iPhoneOS 切片，模拟器无法运行真正的 PPT 编辑引擎，因此没有可编辑首帧、修改、保存、关闭重开的设备证明。
- Linux Guest 当前仍是单核内核与单 hart。双核选项继续受资格验证限制，不能把多线程进程并发写成多核加速。

请在 iPad 上重点复测：本地模型加载、测速、普通首轮及至少两轮工具调用；PPT 在工作区、手记和 IDE 的编辑首帧、切页、保存及重开；DOCX/XLSX 打开保存防回归。若再次失败，请从应用诊断导出对应日志；TestFlight 反馈提交记录与设备系统崩溃日志是不同来源。

## English

- Windowed Qwen prefill now checks MLX errors before building the next window, preventing an invalid array from reaching the observed indexing trap. Memory pressure can still produce a reported failure. The local short-chat envelope is bounded while retaining tool definitions, receipts, workspace identity and essential run context. A cloud host completed two distinct real-weight file-tool calls, receipts and continuations; this is not iPad inference acceptance.
- The PPT editor host now recognizes a genuinely painted edit surface after the engine changes layout, including cases where preview tiles are reused. An unverified frame is still not save-ready. Switching consecutive Office tabs in the IDE re-arms the selected file's loader; close and save acknowledgements remain single-settlement.
- The rebuilt native Office host and resources are pinned by version and digest. The full App compiled and simulator entry paths for Notes, Workspace and IDE passed. The pinned engine is iPhoneOS-only, so the simulator cannot prove a real editable slide, edit, save or reopen.
- The Linux guest still exposes one non-SMP hart. Dual-core remains gated; process concurrency is not evidence of multi-core speedup.

Please check on iPad: local-model load and benchmark, an ordinary first reply and at least two tool-enabled turns; PPT first frame, slide changes, save and reopen in Workspace, Notes and IDE; and DOCX/XLSX open-save regression. Export the App diagnostics if a failure recurs. A submitted TestFlight feedback report and an on-device crash log are separate evidence sources.
