# Floe Agent 1.7.0 (179) — beta.36 internal candidate

**Preparation only: not tagged or uploaded.** Build 178 remains the latest Apple upload (queried 2026-09-17, `VALID`). This is a candidate description, not a delivery record. External Beta review has not been submitted.

**仅准备稿：尚未打标签或上传。** 2026-09-17 查询 Apple，最新上传仍为 Build 178，状态 `VALID`。本文不代表 179 已交付，也未提交外部 Beta 审核。

## 简体中文

- 手记新增 Word、Excel、PPT 封面预览，可导入 DXF／DWG 图纸并只读预览。
- 手记助手可分段读取长文档，并在页面指定位置添加或移动文字。
- Office 调整字体选择、保存、关闭与外部修改冲突处理；画笔颜色、线宽、透明度按文档保存，0% 透明度表示实心。
- IDE 可保存并运行当前文件、停止执行；Rust／Swift／C/C++／PHP 等语言使用已配置主机。紧凑布局的编辑器和终端入口位于“更多”。
- 图纸编辑把基础字段放在画笔参数之前，滚动时保留撤销、重做和保存控件。
- Shell 支持 `apt install floe/lua` 安装签名 Lua 5.4.8，并提供查询与 `lua` 命令。WASM 能力为应用共用，与环境中的语言依赖分开管理。
- 本地 MLX 模型调整推理内存释放方式。iPad 普通聊天闪退仍需真机复核，不宣称已根治。

## English

- Notes adds Word, Excel and PPT cover previews and imports DXF/DWG drawings with a read-only preview.
- The Notes assistant reads long documents in sections and adds or moves text at specified page positions.
- Office updates font selection, saving, closing and conflict handling. Pen color, width and transparency persist per document; 0% transparency is solid.
- The IDE saves and runs the current file and supports stopping execution. Rust, Swift, C/C++, PHP and other hosted languages use a configured remote host. Compact layouts place editor and terminal actions in More.
- Drawing editors place basic fields before pen settings and keep Undo, Redo and Save visible while scrolling.
- Shell installs signed Lua 5.4.8 with `apt install floe/lua`, with package queries and the `lua` command. App-wide WASM capabilities remain separate from environment language dependencies.
- Local MLX models update inference memory release behavior. The reported iPad ordinary-chat crash still requires physical-device verification and is not declared fixed.

## Evidence and remaining gates

| Evidence | Result and boundary |
| --- | --- |
| SDK 26.6 full App compatibility build, `59e24d61`, run `35199099305` | Passed; not an archive or upload, and before the later CAD layout patch |
| SDK 27 full App regression build and execution, `955e346a`, run `35202845926` | Passed these phases; the overall run failed IDE UI |
| Notes in that SDK 27 run | Three cases passed on each iPad/iPhone simulator; native Office skipped on each |
| IDE/CAD repair, `3eecf735` | Compact-menu test updated; CAD fields reordered and Save made sticky; Swift type check, 73 CAD checks and 29 asset hashes passed |
| Primary browser interaction, `3eecf735` | Narrow and wide layout inspected; real DWG edited, saved and reparsed with the bundled WASM engine; not native device evidence |
| IDE diagnostic CI, `a22e8c3e`, run `35212766190` | All three iPad IDE cases passed; workflow failed afterward because the exact iPhone simulator was absent. No iPhone result |
| Simulator selection repair, `b285c037`, run `35216642942` | Family and SDK matching repaired, 28 directed checks and workflow lint passed; dual-device IDE retest in progress |
| Final release source, both SDK gates, signing, upload, Apple processing and internal group availability | Not complete for build 179 |

Original [Notes screenshots](qualification/build178-feedback/full-app-955e346a/README.md), [CAD layout and output evidence](qualification/build178-feedback/cad-layout/README.md), and the [repair ledger](FLOE_BUILD178_FEEDBACK_REPAIR.md) retain source identifiers and failure history.

The PHP 8.4.1 browser prototype is not shipped. Rust/Swift local compilation is not claimed; these languages route to a configured host. Native Office interactions, real SSH execution and physical Pencil behavior remain separate acceptance items. Public Beta materials contain no user API key.
