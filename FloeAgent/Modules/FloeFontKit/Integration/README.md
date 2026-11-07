# App 接入合同

此模块提供离线字体设计组件与原生编译扩展。App 唯一入口为 **设置→现有字体管理器** `FontManagementView`（`FloeApp/Settings/DataManagementView.swift`），从其字体记录或新建字体动作打开，再返回同一管理器。**不得在 Space、Notes 或 Creative 注册独立字体编辑器入口或工程类型入口。** 独立 Qualification 宿主只作组件验证，不代表产品入口。

`FontEditorView` 使用 SwiftUI 字形列表、搜索、字符网格、检查器和工具栏；轮廓、字距、特性程序与变量面板也由 SwiftUI 绘制。WebKit 继续运行同一个计算/格式引擎，仅在文本打样模式显示真实 FontFace 成形。原生快照 schema、暂态命令及边界见 [native-presentation.md](native-presentation.md)。不要改用裸 `HeavyEditorView` 绕过这些原生面板。

1. 字体管理宿主从 `DeviceFontStore.list()` 的真实记录选择输入，或新建空字体工程。宿主生成并持久绑定 `HeavyEditorOwner.fontLibrary(libraryOwnerID)`、工程 UUID、revision、输入字体 digest 与输出记录关系。目录只由宿主确定；导入数据中的 `owner`、路径或工具字段没有权限作用，不借用随机 Space/qualification 身份。
2. 首次创建用 `FontWorkbench.makeDocument(title:id:)`，经 `HeavyEditorProjectStore(directory:documentID:kind:.font).create` 写入。编辑项目和不可变输入副本保存在字体管理器拥有的独立目录，不能覆盖 `DeviceFontStore` 的 digest 字体文件或用户选择的原文件。已有工程调用 `FontWorkbench.open(directory:documentID:owner:hooks:)`，展示 `FontEditorView(controller:onClose:)`；完成后回到字体管理器。
3. `hooks.authorize` 核对当前字体管理域的 `documentID/owner/revision/access/command`，复用既有授权服务，不将全局字体库写入隐含授予任意 Notes/Space 工程。`hooks.didSave` 更新字体编辑工程记录；保存工程本身不安装、不卸载字体。
4. `hooks.export` 先经原文件服务提交文件并读回真实字节，再返回 `try HeavyEditorExportReceipt(fileID: actualFileID, artifact: artifact)`。不得将建议文件名或缓存路径当已交付文件 ID；回执提供真实 hash/byteCount。
5. AI 通过宿主绑定的 `HeavyEditorModelLease` 与 `HeavyEditorModelCalls.execute` 调用 `.font`。`describe` 取得当前 command catalog 和动态默认值/选项，随后按 `baseRevision` 调用已发现命令。宿主的 `font.project/font.glyph/font.metrics/font.features/font.variation/font.export` 命名空间可转发到下表的实际命令。读/编辑/导出仍受共享服务的 scope、取消和授权检查。
6. `font.import` 用字体管理器的已授权文件 resolver 或受管字体输入副本，把文件交给当前 controller 的 `file.import` 或 `file.merge`。共享 model invoke 不接受模型直塞任意 base64 来授予导入权限。UFO/Designspace 文件夹应作为包含伴随文件的 ZIP 交给此模块。
7. 只有当前已经授权执行的 editor 操作可调用原生 `font.compile`。前端自行写受控 UFO/Designspace ZIP；Swift 服务只使用固定 `font.designspace` / `master0.ufo`（静态）根，校验解压和 include 后调用内置 fontc。模型不能挑选原生路径、owner 或新令牌。
8. 关闭/取消复用共享 controller 生命周期。编译中的 Rust 库调用持有 staging 到返回；取消后不得把结果提交到另一工程。库中没有外部进程、Python、下载编译器或 host interpreter 回退。

## 字体管理器回流接点

当前 `DeviceFontStore` 的真实接口是 `list()`、`importFont(from:)`、`install(from:)`、`remove(id:)`。`importFont` 读取原件，在 `Fonts/<SHA256>.<ext>` 中保存自己的副本并作进程级 CoreText 注册；单件上限为 32 MiB，接收 TTF/OTF/TTC/OTC。`ManagedFontRecord.fileName` 是 digest 文件名，不是原外部文件名；库没有保存外部原件 URL。当前尚无受管原件读取、编辑工程保存或替换事务接口，不能把以下接线要求写成已存在能力。

1. **打开编辑。** App 宿主补一个仅按真实受管 ID 取输入的窄接口（例如 `editableSource(id:)`）：核对 digest、受管根内的普通文件及当前记录，返回不可变字节/副本，不给模型任意路径。当前 FontKit 可接 TTF/OTF；现有 TTC/OTC 的安装/管理继续保留，但编辑集合须另有明确的选面/拆面实现，不能默取第一面并冒充完整集合编辑。系统字体和 App bundled 字体不在该受管输入范围内。
2. **保存与编译。** `.floefont`、原始字节和 revision 留在字体编辑项目；`file.export(format:ttf)` 或静态 `otf` 产生新的导出物。宿主先保存并读回真实导出，再返回 `HeavyEditorExportReceipt`。一般导出不自动安装。WOFF/WOFF2、UFO、Designspace、SVG、PDF 和工程文件不能直接传给 `DeviceFontStore.importFont` 当安装成功。
3. **新增编辑版本。** 字体管理器的明确“安装编辑版本”动作选择已保存的 TTF/OTF，检查实际 PostScript 名不与系统、bundled 或既有版本冲突，再 `store.importFont(from: compiledURL)`。需要并存时使用独立 family/style 身份；不能只改文件名。返回的 `ManagedFontRecord.id` 是新安装记录，不能冒充原记录或导出文件服务的 fileID。完成后 `store.list()` 刷新原管理器，并沿用 `StorageDiagnosticService.shared.invalidate(.other("fontStore"))`。
4. **更新既有版本。** 当前没有替换 API。不能用“import 新 SHA→remove 旧 SHA”模拟同名替换：`CoreTextFontRegistration.outcome` 仅核对解析到的 PostScript 名，可能仍解析到旧字体。真正更新必须由字体库 actor 内的有界操作完成：限定一个明确受管 ID，保留旧字节；先验证新字体；只注销该受管旧 URL；注册新 URL 并核对 CoreText 实际解析到新文件（例如字体描述符的 `kCTFontURLAttribute`）；成功后才更新安装关系、退役旧库副本。失败恢复旧注册与记录；编辑项目中的输入原件始终保留。不得注销或替换 system/bundled/其他受管字体来腾出名字。

二进制原件导出仍逐字节保留；重建只承诺当前可编辑轮廓、metrics、kerning 与 FEA，不以安装/更新动作声称未知表和原始布局程序均已无损保留。

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
