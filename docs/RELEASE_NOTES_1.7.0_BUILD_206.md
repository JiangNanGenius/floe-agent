# Floe Agent 1.7.0 (206) — internal device test candidate

Not uploaded yet. This replaces the [failed Build205 candidate](qualification/build205-release/build205-bootstrap-failure.md).
Its Office native framework was rebuilt in run35495484711 and pinned to the
changed source; native compile/link, Swift import and local artifact inventory
verification passed. The App and its three extensions use build 206.

Included repairs: Office close during an in-flight open; PDF/Office in IDE
internal document tabs; local Git initialization without GitHub login and
repository lifetime protection; native mind-map icon controls and persistent
free node positions; Shell gate/input/EOF/cancellation handling and service
submission preflight. Detailed evidence: [September20 repair record](FLOE_FEEDBACK_2026_09_20.md).

Cross-task reading, local-model compaction and the new Linux/package architecture
are still being implemented and are not claimed fixed by this build. The
incomplete cross-task patch is excluded from this release source.

Only focused code checks and the accepted-SDK cloud App build precede delivery.
Simulator/UI regression is skipped at the user's request; physical-device
acceptance is the user's next step. Preserve the unsigned IPA and matching private
symbols before signing; verify Apple processing and Floe QA availability separately.

本候选替代未上传的 Build205。包含 Office 生命周期、IDE 内部文档标签、
本地 Git 初始化、原生思维导图与 Shell 修复；Office 原生宿主已按新源码
重新构建并校验、锁定工件。跨任务、本地模型与 Linux／安装架构继续处理，不计作
本包已完成。只做必要代码检查、云 App 编译和上传校验，真机操作由用户验收。
