# Floe Agent 1.7.1 — Build 242

## 简体中文

- 修复停止 Linux 工作区时，已停止的磁盘捕获可能因调用方任务取消而失败的问题。实际磁盘读写故障仍会保留恢复数据并提示修复。
- 改进模型工具调用的错误处理：参数 JSON 无效或流片段无法可靠归属时，整批调用不会执行，并给模型一次有界的纠正机会。清单证据数量和长度限制保持不变。
- 语音输入波形改由麦克风实测电平驱动；等待说话和静音时保持静止。聊天与画布入口共用该行为。

这些修复已通过针对性测试及模拟器 App 编译。Linux、模型和麦克风在实际 iPad 上的表现仍需安装后验证。本构建先提供内部 TestFlight 测试，不代表公开测试或正式 App Store 发布。

## English

- Fixes a Linux workspace stop path where cancellation of the calling task could interrupt capture of an already stopped disk. Genuine disk failures still preserve recovery data and require repair.
- Improves model tool-call handling: when argument JSON is invalid or a stream fragment cannot be attributed safely, the entire response batch is withheld and the model gets one bounded correction attempt. Checklist evidence limits remain enforced.
- Drives the voice-input waveform from measured microphone level, keeping it still while waiting for speech and during silence. Chat and Canvas use the same behavior.

Focused tests and a Simulator App build passed. Linux, model and microphone behavior on a physical iPad remains to be checked after installation. This build is for internal TestFlight testing; public beta and App Store release are separate steps.
