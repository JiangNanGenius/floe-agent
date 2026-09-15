# Floe Agent 1.7.0 (176) — document assistant candidate

Candidate only: not uploaded or available in TestFlight. Build 172 remains the last confirmed internal delivery. Build 175 was stopped before upload after preserving its accepted-SDK device artifact (`34945701373`, artifact `10388835194`); it lacks the additional document-assistant changes below. Previous qualification evidence remains attached to its original source.

## 简体中文

- 手记助手在宽屏 iPad 中使用完整右栏；iPhone 和较窄分屏使用独立面板。去掉嵌套卡片和通用任务的模式、权限控件。
- “重新开始当前文档会话”停止旧会话的运行，再建立新的专属会话；保留文档和旧消息，并撤销旧会话的文档编辑授权。
- 当前文档中的可撤销编辑使用文档专属授权，不需要另设任务权限；其他工具继续执行正常权限检查。
- 助手提交修改后，手记编辑器自动读取新版本。本地书写保存期间的变更通知会延后处理，避免丢失；未保存笔迹不会被旧资源覆盖，当前页和视图状态保持独立。
- 保留 Build 175 的 Ark DeepSeek 工具调用 ID 修复与之前的运行环境、包安装、手记历史隔离修复。

## English

- A full-height assistant column on wide iPads and a sheet on iPhones or narrow windows replace the nested floating card. Document composition omits generic task mode and permission controls.
- Restarting a document conversation stops its previous run, retains the document and messages, creates a dedicated conversation, and revokes the previous document grant.
- Undoable edits to the assistant's own document use its native document grant. Other tools retain normal permission checks.
- Committed assistant edits refresh the editor automatically. Notifications received during local saves are deferred, not discarded; unsaved ink remains protected and the current page and viewport are retained.
- Includes Build 175's Ark tool-call identity fix and preceding runtime, package and dedicated Notes history changes.

## Verification and limits

Targeted source parsing and whitespace checks passed locally; new full-App tests cover live document refresh, page/viewport retention, document permission boundaries and restart revocation. Simulator UI checks exercise the restart control and retain screenshots. These tests require cloud execution before acceptance; source parsing is not compilation or device evidence.

Native Office binary edits are outside `notes.edit`; its existing editor and save/recovery path remain separate. Simulator builds do not include the native Office engine. Qwen iPad recovery, complete native npm/WASI and APT publication, full media-model qualification and official log-service deployment remain incomplete. No provider credential is included in public Beta reviewer access. Public Beta submission awaits the owner's review.

The previous immutable source `8958d8f1` passed 172/172 full-App regressions and the iPhone Notes case. Its iPad Notes case exceeded the 180-second allowance after progressing to tab closure. Build 176 splits all existing assertions into three independent cases, with the same timeout; the gate requires every case. [Original evidence](evidence/floe-1.7/build172-repair/app-build175.json).
