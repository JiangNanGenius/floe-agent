# Floe Agent 1.7.0 (179)

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

本版本的验证范围与已知限制见 [修复记录](FLOE_BUILD178_FEEDBACK_REPAIR.md)。PHP 本地运行原型未随本版提供；真机 Apple Pencil、Office 操作及 iPad 本地模型仍需复核。

See the [repair record](FLOE_BUILD178_FEEDBACK_REPAIR.md) for evidence and limitations. The local PHP prototype is not included. Physical Pencil, native Office interaction and iPad local-model acceptance remain outstanding.
