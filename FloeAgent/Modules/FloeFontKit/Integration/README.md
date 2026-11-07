# App 接入合同

此模块提供独立字体编辑器与原生编译扩展，不修改 App 路由、用户工程索引、AI 账户/权限或发布版本。

1. Notes/Space/Creative 从既有文件/工程服务解析真实目录、工程 ID、owner 与 revision。目录只能来自宿主；导入文件中的 `owner`、路径或工具字段没有权限作用。
2. 首次创建用 `FontWorkbench.makeDocument(title:id:)`，经 `HeavyEditorProjectStore(directory:documentID:kind:.font).create` 写入。已有工程调用 `FontWorkbench.open(directory:documentID:owner:hooks:)`，展示 `FontEditorView(controller:)`。宿主保留其原导航/文件返回路径。
3. `hooks.authorize` 复用当前任务/Notes/Space 的权限体系，核对 `documentID/owner/revision/access/command`，不为普通已授权编辑逐条引入新审批。`hooks.didSave` 更新同一个真实工程索引和标题。
4. `hooks.export` 先经原文件服务提交文件并读回真实字节，再返回 `try HeavyEditorExportReceipt(fileID: actualFileID, artifact: artifact)`。不得将建议文件名或缓存路径当已交付文件 ID；回执提供真实 hash/byteCount。
5. AI 通过宿主绑定的 `HeavyEditorModelLease` 与 `HeavyEditorModelCalls.execute` 调用 `.font`。`describe` 取得当前 command catalog 和动态默认值/选项，随后按 `baseRevision` 调用已发现命令。宿主的 `font.project/font.glyph/font.metrics/font.features/font.variation/font.export` 命名空间可转发到下表的实际命令。读/编辑/导出仍受共享服务的 scope、取消和授权检查。
6. `font.import` 继续用既有附件/文件 resolver，把已授权解析到的文件传给当前 controller 的 `file.import` 或 `file.merge`。共享 model invoke 不接受模型直塞任意 base64 来授予导入权限。UFO/Designspace 文件夹应作为包含伴随文件的 ZIP 交给此模块。
7. 只有当前已经授权执行的 editor 操作可调用原生 `font.compile`。前端自行写受控 UFO/Designspace ZIP；Swift 服务只使用固定 `font.designspace` / `master0.ufo`（静态）根，校验解压和 include 后调用内置 fontc。模型不能挑选原生路径、owner 或新令牌。
8. 关闭/取消复用共享 controller 生命周期。编译中的 Rust 库调用持有 staging 到返回；取消后不得把结果提交到另一工程。库中没有外部进程、Python、下载编译器或 host interpreter 回退。

| 宿主工具族 | 实际命令 |
| --- | --- |
| font.project | `document.inspect/save/rename`、`history.undo/redo/list`、`project.sample`、`font.info/validate/glyphOrder` |
| font.glyph | `glyph.create/delete/encoding/rename/duplicate/charset/transform/component/componentEdit/decompose/anchor/guideline/guidelineRemove`；`point.edit/move/insert/delete/smooth`；`contour.reverse/start/reorder/openClose/split/join`；`segment.split`；`outline.shape/unite/intersect/subtract/exclude/removeOverlap/simplify/extrema/convert/align/measure/winding/inspect` |
| font.metrics | `metrics.edit/vertical`、`font.vertical/preview`、`kerning.pair/group` |
| font.features | `features.edit/substitution/merged`、`font.preview` |
| font.variation | `variation.axis/master/masterEdit/copyGlyph/instance/validate/generate` |
| font.import | `file.import/merge`，仅经宿主文件 resolver |
| font.export | `file.export`、`glyph.exportSVG`、`specimen.export`、`variation.generate` |

`smoke-plan.json` 是统一原生宿主的有界验收步骤。使用自有几何样例，变换保持母版轮廓兼容，再实际编译和导出 TTF、静态 CFF OTF、变量 WOFF2、示字 PDF；宿主必须保存实际输出并回读。它不替代模块的算法/格式行为测试，也不是完整 Floe App 或实体 iPad 验收声明。
