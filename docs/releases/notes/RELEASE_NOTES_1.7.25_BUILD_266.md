# 1.7.25 (266) — Design workflow on Canvas, storage diagnostics/cleanup, durable decisions

Candidate source preparation, 2026-10-10. **Not uploaded, not tagged and not
submitted to Apple yet.** Version/build changes and notes exist so the
reviewed source can become the next TestFlight candidate (`1.7.25`, build
`266`) after primary/coordinator acceptance. Build 265 remains the published
release; no release claim is made here.

## English

- **Design workflow on Canvas.** Brief/spec/DESIGN.md → import or generate →
  anchored feedback → revision-bound candidates → compare → adopt that updates
  the **real Canvas node content in one CAS commit** → verified export reopened
  with the real format parser. Office/presentation/CAD work binds an explicit
  Canvas-owned workspace document.
- **Canvas project brief/spec authority.** The project-level brief/spec now
  lives on the Canvas project itself. Applying it updates the authority and
  every existing design node in one project CAS; new nodes inherit on
  creation; repeated identical payloads dedupe, and reusing an operation with a
  different payload is rejected. Unrelated node edits never change the
  authoritative payload, and frozen runs keep their recorded spec hash.
- **Use current node.** New entry that freezes content already on a node
  (Markdown/text body, retained asset bytes, or the bound CAD/Office document)
  into a design revision with the existing editor guards — no external
  export/reimport. Missing content reports the exact reason; editor drafts are
  not touched.
- **Durable decisions.** Panel and agent adopt/reject share one transaction:
  the notice target is the candidate's persisted originating task (never the
  currently open chat), a durable intent with the exact node and full
  operation fingerprint is written before the Canvas commit, delivery is
  acknowledged only after the durable ingress persists, and crashes/failed
  deliveries are repaired by launch-time reconcile.
- **Templates.** Applying a stored or signed template now verifies the actual
  payload against its recorded digest before anything changes; signed packages
  must match the canonical package digest and contain the `DESIGN.md`
  entrypoint, and removal/rollback follows the signed content authority.
- **Storage diagnostics and cleanup (from the same development line).**
  Categorized, identity-deduplicated measurement with explicit logical vs
  host-allocated bytes and clone-sharing estimates; cleanup is limited to
  explicitly registered candidates over the task-owned scratch root with
  owner probes, per-path leases and fail-closed deletion. No whole-`tmp` or
  whole-`Caches` sweep.
- **Visual tool evidence.** Images returned by tools (PNG/JPEG/WebP/GIF) are
  size-bounded before decoding, MIME-spoof checked against the actual bytes,
  deduplicated, and delivered to vision models exactly once per result.

Please test: iPad split view and iPhone compact layouts, design import →
propose → adopt → export from the panel and from the assistant, project-spec
apply across several nodes, “Use current node content”, and the storage
scan/clean-report screen.

Limits: this is a candidate that has passed focused module tests and an App
compile; physical-device, real-provider and Apple acceptance gates are still
open. Cloud AI requires your configured provider. Proposed design edits
require explicit confirmation; candidates never overwrite current content
before adoption.

## 简体中文

- **画布设计流程。** 简报/规格/DESIGN.md → 导入或生成 → 锚定反馈 → 修订绑定的
  候选 → 比较 → 采纳（在**同一次 CAS 提交中更新真实画布节点内容**）→ 以真实格式
  解析器重新打开验证的导出。办公/演示/CAD 通过显式绑定的画布工作区文档接入。
- **画布工程简报/规格权威。** 工程级简报/规格保存在画布工程自身：应用时在同一次
  工程 CAS 中更新权威与所有既有设计节点，新节点创建时自动继承；负载相同去重，
  同一操作换负载会被拒绝。无关节点编辑不会改变权威内容；冻结运行保留其规格哈希。
- **使用当前节点。** 新入口把节点上已有的内容（Markdown/文本正文、已留存素材
  字节或已绑定的 CAD/Office 文档）经既有编辑器守卫冻结为设计修订，无需外部
  导出/再导入；没有可冻结内容时给出明确原因，且不改动编辑器草稿。
- **日志化决策。** 面板与 Agent 的采纳/拒绝共用同一事务：通知目标是候选自身
  持久化的原始任务（绝不回退到当前会话）；在画布提交前写入带精确节点与完整
  操作指纹的持久意图；只有持久入口真正写入后才确认送达，崩溃或送达失败由启动
  对账补送。
- **模板。** 应用存储/签名模板前先校验实际负载与记录摘要；签名包必须匹配包
  规范摘要并包含 `DESIGN.md` 入口，移除/回滚沿用签名内容权威。
- **储存诊断与清理（同一开发线）。** 分类、按文件身份去重的计量，显式区分逻辑
  长度与主机已分配字节并标注克隆共享估算；清理仅限显式注册的候选项（任务持有的
  专用 scratch 根），带所有者探针、逐路径租约和失败关闭删除，不做整目录 tmp 或
  Caches 清扫。
- **视觉工具证据。** 工具返回的图片（PNG/JPEG/WebP/GIF）在解码前先做大小上限
  检查、按真实字节校验 MIME 是否被伪造、按摘要去重，并在每条结果中恰好送达视觉
  模型一次。

请重点测试：iPad 分屏与 iPhone 窄屏布局、面板与助手的设计“导入 → 提案 → 采纳 →
导出”、多节点工程规格应用、“使用当前节点内容”，以及储存扫描/清理报告界面。

边界：本版是候选构建，已通过聚焦模块测试和 App 编译；真机、真实模型服务与
Apple 验收仍未完成。云端 AI 需自行配置服务；设计提案必须确认后才会覆盖当前内容。
