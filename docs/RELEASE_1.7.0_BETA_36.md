# Floe Agent 1.7.0 (179) — beta.36 internal candidate

**Tagged; upload pending.** `v1.7.0-beta.36` fixes source `a510ea6d`. Run `35228451173` produced the SDK 27 unsigned IPA, but the accepted-SDK Notes step exceeded its 20-minute limit. iPad passed after an import-test retry; iPhone was interrupted before completion. Signing/upload did not start. External Beta review has not been submitted.

**已固定标签，尚未上传。** SDK 27 构建与测试通过、安装包已留存；发布 SDK 的 iPad 手记测试重试后通过，iPhone 被共用时间上限中断。正在复用构件恢复剩余验收，不能视为 TestFlight 已可安装。

## 简体中文

- 手记已接入 Word、Excel、PPT 缩略图生成，但完整 App 文件列表的 Word／Excel 内容封面仍待专项验收，不能以 PDF 截图代替。支持导入 DXF／DWG 图纸并只读预览。
- 手记助手可分段读取长文档，并在页面指定位置添加或移动文字。
- Office 调整字体选择、保存、关闭与外部修改冲突处理；画笔颜色、线宽、透明度按文档保存，0% 透明度表示实心。
- IDE 可保存并运行当前文件、停止执行；Rust／Swift／C/C++／PHP 等语言使用已配置主机。紧凑布局的编辑器和终端入口位于“更多”。
- 图纸编辑把基础字段放在画笔参数之前，滚动时保留撤销、重做和保存控件。
- Shell 支持 `apt install floe/lua` 安装签名 Lua 5.4.8，并提供查询与 `lua` 命令。WASM 能力为应用共用，与环境中的语言依赖分开管理。
- 本地 MLX 模型调整推理内存释放方式。iPad 普通聊天闪退仍需真机复核，不宣称已根治。

## English

- Notes integrates Word, Excel and PPT thumbnail generation. Actual Word/Excel content covers in the full-App library still require dedicated acceptance; PDF screenshots do not establish this. DXF/DWG drawings can be imported with a read-only preview.
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
| Simulator selection repair, `b285c037`, run `35216642942` | Device selection succeeded and App host compiled; XCTest startup stalled before tests on both devices, then retry hit an existing diagnostic directory. No App test results in that run; corrected by the subsequent diagnostic/retry patch |
| Dual-device IDE qualification, `2e2a34c9`, run `35223435570` | Passed all three cases on both iPad and iPhone, first attempt; original screenshots and strict summaries retained. Targeted diagnostic run, not full release qualification |
| Immutable release `a510ea6d`, run `35228451173` | SDK 27 job passed; accepted-SDK device build and App regression passed; Notes iPad passed after retry, iPhone interrupted by the step deadline; no upload |
| Signing, upload, Apple processing and internal group availability | Pending build 179 recovery |

Original [Notes screenshots](qualification/build178-feedback/full-app-955e346a/README.md), [CAD layout and output evidence](qualification/build178-feedback/cad-layout/README.md), and the [repair ledger](FLOE_BUILD178_FEEDBACK_REPAIR.md) retain source identifiers and failure history.

The PHP 8.4.1 browser prototype is not shipped. Rust/Swift local compilation is not claimed; these languages route to a configured host. Native Office interactions, real SSH execution and physical Pencil behavior remain separate acceptance items. Public Beta materials contain no user API key.

[Release-source Notes screenshots and limitations](qualification/build179-release/sdk27-notes/README.md).
