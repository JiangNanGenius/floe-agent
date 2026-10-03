# Floe Agent 1.7.0 — Build 233 candidate / 候选版本

Status: expedited internal-beta release candidate; publication and Apple processing are pending. Build 232 remains the delivered version until those gates are verified.
状态：加快交付的内部测试候选；发布和 Apple 处理待完成，核实前已交付版本仍为 Build232。

## Changes / 改动

- Linux image preparation now checks actual Runtime v2 files, can reconstruct verified content, and keeps repair/download work in the shared cancellable service. Installed-image and running-VM states are separate; recoverable initialization and typed file errors improve retry and diagnosis. Existing Environment bases, private changes and Workspaces are preserved.
- Linux 镜像准备检查 Runtime v2 实际文件，可从已校验内容恢复；修复与下载归属同一个可取消服务。安装状态与 VM 运行状态分开，初始化失败可恢复，文件错误可区分。保留已有环境基底、私有修改与工作区。
- Local-model tool repair retains the admitted schema and runtime boundaries. A fresh explicit named-tool request is distinguished from capability questions and earlier receipts; quoted examples are not promoted to required calls. Cloud-provider implementations are unchanged.
- 本地模型工具修正保留准入 schema 和运行时边界，区分新一轮明确调用、工具介绍问题与旧回执；引用示例不会被强制执行。云端模型供应商实现未改动。
- Office records durable, content-free opening/rendering stages and memory samples, releases only idle unclaimed local-model residency before opening, and reports web-content termination without discarding editing copies. The rebuilt host includes corrected locale-scoped font substitutions.
- Office 增加持久化的打开、绘制阶段与内存诊断；打开前仅释放未被任务占用的空闲本地模型，内容进程退出时保留编辑副本并报告错误。新宿主包含纠正后的字体替代配置。

## Evidence and remaining limits / 验证与限制

- Host run [36391186085](https://github.com/JiangNanGenius/floe-agent/actions/runs/36391186085) compiled, linked and imported successfully. The retained host artifact and all 4,780 runtime-resource hashes were verified before pinning. This is not iPad rendering or stability acceptance.
- 原生宿主构建、链接和 Swift 导入通过；固定前已核验产物及 4,780 个运行时资源摘要。这不等于 iPad 绘制或稳定性验收。
- Model diagnostic run [36405120893](https://github.com/JiangNanGenius/floe-agent/actions/runs/36405120893) failed at search-receipt grounding after both real file-tool turns and the search invocation passed. Its source is `767950bdd545142e63fa111becd4f1ab58c7ddf7`, running actual model weights on macOS, with real file reads and synthetic search receipts. It is not iPad or live search-provider evidence.
- 模型诊断中，两轮真实文件工具调用和搜索调用通过，但搜索回执后的回答未依据结果，修复仍在进行。使用 macOS 实际权重及合成搜索回执，不能当作 iPad 或真实搜索服务验收。
- Follow-up diagnostic [36411749778](https://github.com/JiangNanGenius/floe-agent/actions/runs/36411749778), source `c7bca350d8b70f491da497fdb72c2ab68290a3f0`, also failed search-receipt grounding after a personally reviewed continuation repair and 26 focused tests; both file-tool turns passed. End-to-end model-input investigation continues.
- 追加修复经主线程审查且26项定向测试通过，但真实权重复测再次未能依据搜索回执回答；两轮文件工具通过。继续排查完整模型输入链路。
- Diagnostic-only [36420389436](https://github.com/JiangNanGenius/floe-agent/actions/runs/36420389436) compares prepared tokens, message representation and sampling. Its completion cannot replace the original tool/receipt acceptance gates.
- 新的云端对照仅用于诊断实际分词输入、消息表示和采样行为，不能替代原有工具及回执验收。
- PPT idle crashes remain unresolved. Font substitution does not provide every requested font; FangSong still uses a substitute. iPad glyph coverage, PPT/Excel editing, Word rendering and save/reopen need device verification.
- PPT 静置闪退仍未确认解决。字体替代不代表字体齐全，仿宋仍使用替代字体；iPad 字形覆盖、PPT/Excel 编辑、Word 显示及保存重开待真机验证。
- Full-App compilation, retained IPA, upload, Apple processing, private Floe QA availability and GitHub prerelease are pending. No release tag has been created for this candidate. Gitee remains an independent follow-up.
- 完整 App 编译、IPA 保留、上传、Apple 处理、私有 Floe QA 可安装状态与 GitHub 预发布均待完成；候选尚未创建发布标签。Gitee 独立跟进。

## Expedited delivery scope / 加快交付范围

This internal beta carries known unresolved local-search grounding and PPT idle-crash issues. The seven-case diagnostic completed but is not qualification. Full model qualification has not passed; no test assertion was weakened. Targeted component checks do not establish iPad acceptance. Full App compilation, signing and Apple validation remain required for delivery.

本次内测包含尚未解决的本地搜索回答失实和 PPT 静置闪退问题。七组诊断已完成，但不代表资格通过；完整模型资格未通过，没有放宽测试断言。定向组件检查不能替代 iPad 验收；交付仍要求完整 App 编译、签名及 Apple 校验。
