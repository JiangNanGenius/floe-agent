# Floe Agent 1.7.0 — Build 234 candidate / 候选版本

Build234 supersedes the failed Build233 App compilation. It retains the Runtime v2 recovery, local-model tool-call improvements and rebuilt Office font/diagnostic host described in [Build233 notes](RELEASE_NOTES_1.7.0_BUILD_233.md), and corrects the escaping cancellation callback contract in Linux image repair wiring. Build233 produced no IPA or TestFlight upload; its tag remains immutable.

Build234 接续编译失败的 Build233，保留其 Runtime v2 恢复、本地模型工具调用改进及重新构建的 Office 字体和诊断宿主，并修正 Linux 镜像修复回调的可逃逸取消检查约定。Build233 未产生 IPA 或 TestFlight 上传，原标签保持不变。

Known issues remain: local-model search-result grounding, PPT idle crashes and incomplete font coverage. No iPad acceptance or complete model qualification is claimed. Compilation, package preservation, signing, Apple validation and private Floe QA availability must be verified separately before claiming delivery.

已知问题仍包括本地模型搜索回答失实、PPT 静置闪退及字体覆盖不完整。不宣称 iPad 验收或完整模型资格通过。编译、安装包保留、签名、Apple 校验及私有 Floe QA 可安装状态分别核实后再报告交付。
