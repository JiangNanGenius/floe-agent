# 1.7.29 (270) — Unified 3D workbench, design workflow hardening, provider/runtime delivery

Source preparation, 2026-10-11, from the accepted unified-3D/design/provider/Harness
development line. This candidate carries the unified native 3D workbench, the shared design
workflow and its publication/decision hardening, the CAD fullscreen/camera lifecycle fixes
and the provider/runtime delivery hardening. It replaces the internal-only 1.7.28 (269)
line for the next TestFlight update; 269 was never submitted to external review. Release,
Apple and physical-device gates are recorded in
[the current status page](../../CURRENT_STATUS.md) once observed.

## English

- **Unified 3D workbench.** The two old top-of-canvas 3D creation controls are removed.
  The bottom insertion menu (**+ ▸ 3D Model**) creates one native `.floecad` node owned by
  the canvas and opens the same fullscreen workbench used by every other entry point.
  **3D Panorama** stays a separate viewer node. Existing legacy 3D scene nodes are not
  deleted or converted by the update; they keep a read-only preview until an explicit
  first edit migrates them transactionally (recoverable backup, capability check, known
  visual differences sheet), and the original node stays intact until you apply a result.
- **CAD model lifecycle.** Fullscreen editing preserves the exact camera you were using
  (no automatic diagonal re-fit) and hands the visible viewport controls, orientation-cube
  labels and thumbnail/screenshot providers back to the presenting editor when you tap
  Done. Saving a model with no drawn geometry commits a real (honest) preview instead of a
  missing-thumbnail error, and a save failure keeps the recoverable draft instead of
  discarding it. Cancelling an untouched new model in fullscreen no longer leaves an empty
  draft; returning to an already-saved node saves normally without an alert.
- **Shared design workflow.** Brief/spec/DESIGN.md → import or generate → anchored feedback
  → revision-bound candidates → compare → adopt that updates the real Canvas node content
  in one CAS commit → verified export reopened with the real parser. Four entrances
  (Creative start, current file, original chat attachment, Canvas node) share one workflow
  and one set of services with explicit owner, document, node, task, environment and
  revision identity. Project-level brief/spec authority applies to every design node in
  one commit; new nodes inherit; identical payloads dedupe.
- **Durable decisions and publication.** Adopt/reject notices target the candidate's
  persisted originating task, are written as a durable intent before the Canvas commit,
  acknowledged only after the durable ingress persists, and are repaired on the next
  launch. Assistant adoption requires an explicit authorization step; recovery keeps
  canonical output bytes, a frozen real UUID/owner revision, and truthful cancellation /
  stop-waiting semantics for unknown remote outcomes.
- **Provider and runtime delivery.** Provider configuration validation and the save runner
  separate local commit from sync enqueue, report concrete invalid-configuration and
  concurrent-save outcomes, and never write a half-applied profile. Background runs are
  durable with reconciled metrics; tool-loop hardening bounds repeated/failed tool
  attempts, keeps capability lifetime honest across disable/disconnect, and freezes an
  unknown-outcome ledger instead of retrying non-idempotent remote effects.
- **Storage, evidence and diagnostics.** Categorized, deduplicated storage measurement with
  explicit logical vs host-allocated bytes; cleanup stays limited to explicitly registered
  task-owned candidates with owner probes and fail-closed deletion. Tool-returned images
  are size- and format-checked against the real bytes and delivered once per result.
  Assistant decision notices and exported diagnostics distinguish the originating task from
  the currently open chat.

Please test: iPad portrait/landscape/split view and iPhone compact layouts; create a 3D
model from the bottom insertion menu, orbit/zoom and switch views, enter fullscreen, change
the camera, tap Done and confirm the presenting viewport keeps that camera with working
face controls; save, close and reopen an edited model; cancel an untouched new model from
fullscreen; open an existing legacy 3D scene and migrate it on first edit; run a design
import → propose → adopt → export with and without a configured provider; check the storage
scan/cleanup report; and try a cloud provider after saving its configuration.

Limits: candidate build whose source passed focused module/App suites and a local
exact-source Release device build; the precise executed suites and remaining
physical-device/real-provider/Apple gates are recorded in the release evidence and
[CURRENT_STATUS.md](../../CURRENT_STATUS.md). Cloud AI requires your configured provider.
Proposed design edits apply only after confirmation. iPad split-window and large-font
interaction are not yet qualified; physical-device fluidity remains testing.

## 简体中文

- **统一 3D 工作台。** 画布顶部原来的两个 3D 创建按钮已移除；底部插入菜单
  （**+ ▸ 3D 模型**）会在画布内创建一个原生 `.floecad` 节点，并打开与其他入口
  相同的全屏工作台。**3D 全景** 仍是独立查看节点。既有旧版 3D 场景节点不会因
  升级被删除或自动转换：在你明确首次编辑之前保持只读预览，首次编辑会先做
  可恢复备份、能力校验，并显示已知视觉差异面板；在你应用结果之前，原节点保持
  不变。
- **CAD 模型生命周期。** 全屏编辑保留你进入前的精确相机（不再自动回到默认
  斜视角）；点按完成时，可见视口的方向立方体标签与缩略图/截图回调会正确交还给
  呈现编辑器。没有绘制几何的模型保存时会提交真实（如实）的预览，而不是
  缺缩略图错误；保存失败会保留可恢复草稿而不是丢弃。对全新未编辑模型在全屏中
  取消不再残留空草稿；对已保存节点返回后正常保存、不再弹错。
- **共享设计流程。** 简报/规格/DESIGN.md → 导入或生成 → 锚定反馈 → 修订绑定的
  候选 → 比较 → 采纳（在同一次 CAS 提交中更新真实画布节点内容）→ 以真实格式
  解析器重新打开验证的导出。四个入口（创作起始、当前文件、原始聊天附件、
  画布节点）共用同一套流程与服务，并显式携带所有者、文档、节点、任务、环境与
  修订身份。工程级简报/规格权威一次提交应用到所有设计节点，新节点自动继承，
  内容相同去重。
- **日志化决策与发布。** 采纳/拒绝通知目标是候选自身持久化的原始任务；在画布
  提交前写入持久意图，只有持久入口真正写入后才确认送达，崩溃或失败由下次启动
  补送。助手采纳需要明确的授权动作；恢复过程保留规范输出字节、冻结真实
  UUID/所有者修订，并对未知远端结果给出如实的取消/停止等待语义。
- **供应商与运行时交付。** 供应商配置校验与保存运行器把本地提交与同步入队分开，
  给出明确的不合法配置与并发保存结果，绝不写入半套配置。后台任务持久化并如实
  对账指标；工具循环加固限制重复/失败的工具尝试，在禁用/断开时如实维护能力
  生命周期，并用未知结果账本代替对非幂等远端效果的盲目重试。
- **储存、证据与诊断。** 分类、按文件身份去重的储存计量，显式区分逻辑长度与
  主机已分配字节；清理仅限显式注册的任务持有候选项，带所有者探针和失败关闭
  删除。工具返回的图片按真实字节做大小与格式校验，每条结果恰好送达一次。
  助手决策通知与导出诊断会区分原始任务与当前打开的会话。

请重点测试：iPad 横竖屏/分屏与 iPhone 窄屏；从底部插入菜单创建 3D 模型，
旋转/缩放并切换视角，进入全屏后改变相机，点按完成后确认呈现视口保持该相机且
面选择正常；保存、关闭并重新打开已编辑模型；对全新未编辑模型在全屏中取消；
打开既有旧版 3D 场景并首次编辑迁移；分别在配置/未配置供应商时走一遍设计
"导入 → 提案 → 采纳 → 导出"；查看储存扫描/清理报告；保存供应商配置后测试
云端 AI。

边界：本候选版本的源码已通过聚焦模块/App 测试与本机精确源码 Release 设备构建；
实际执行的测试与尚未完成的真机/真实模型服务/Apple 验收记录在发布证据与
[CURRENT_STATUS.md](../../CURRENT_STATUS.md)。云端 AI 需自行配置服务；设计提案
必须确认后才会生效。iPad 分屏与大字体交互尚未验收；实体设备流畅度仍待测试。
