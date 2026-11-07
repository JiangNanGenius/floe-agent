# FloeFontKit

独立、离线的字体设计模块。入口为 `FontWorkbench` / `FontEditorView`，工程扩展名为 `.floefont`。自有源码采用 MPL-2.0；原生 fontc 与 Web 依赖的原始许可证由统一宿主闭包记录，不能用本模块 SPDX 代替第三方许可。

原生库以真正的 `.a + Headers` XCFramework 交付，不把静态 archive 伪装成可嵌入 framework。producer 保留原薄 LTO；打包副本仅移除冗余 `__LLVM` 段，保留全部机器码/运行段、平台信息、非 STAB 符号和 DWARF，逐对象核对后才提交。实际 raw→consumer 哈希见 `Vendor/FloeFontCompiler.xcframework/normalization-manifest.json`。完整 Cargo、WOFF2 与实际 Rust 标准库版权原文入口见 [THIRD_PARTY.md](THIRD_PARTY.md)。

## 功能矩阵

| 范围 | 已实现 | 当前验证与边界 |
| --- | --- | --- |
| F01 工程 | 家族/样式/版权/许可/设计者等信息、em/水平 metrics、Unicode、字形 ID/排序、字符集模板、查找、复制/删除/重命名、静态字库合并；保存、历史、撤销/重做复用共享 dispatcher/store | Web 行为测试覆盖母版字距编辑后序列化重开与 undo/redo。重命名/删除已被 FEA 引用的字形前须先编辑特性程序，避免改写任意 FEA 命名空间。合并保留目标 metadata，把导入 FEA/许可和字形映射保存在 `mergedSources`，不自动拼接相冲突的 lookup/class 程序。 |
| F02 轮廓 | UFO point-pen 的直线/二次/三次 Bézier、控制柄、尖角/平滑/对称/切线、精确分割、插入/删除、开闭/分割/连接/反向/改起点/调顺序、选择/框选、变换、对齐、吸附、参考线、测量、组件添加/矩阵编辑/分解、锚点 | 精确 de Casteljau 分割、反转/开闭及全 off-curve 二次轮廓、跟随和切线拖柄、删点后结构均有行为验证。边距使用真实曲线极值，不把控制点包围盒当字形边距。 |
| F03 形状 | Paper 的布尔四操作、去重叠、简化、极值点、曲线转换、交点/方向/洞诊断和方向修正 | 实际并/差面积与范围、极值点和嵌套洞方向修正已测；三次转二次采用自适应细分，控制多边形误差给出几何误差上界。 |
| F04 metrics | 字宽/左右边距、竖排 advance/origin/vhea 参数、每母版独立字距、对字距/类字距、字符串打样与拖动字距、边框/基线对照、多字号 | 原生双轴 HVAR/VVAR、可编辑 VVAR 导入回读及 CoreText 变量字宽/字距/竖排 advance 已测。普通默认脚本 PairPos 1/2 字距可导入；上下文、多脚本组合、多个叠加 lookup 和设备修正不是无损可编辑还原。 |
| F05 OpenType | 标准 FEA 编辑与真实编译；连字/替代/小型大写/本地化等规则辅助生成、kern 类、mark 锚点；FontFace 实际打样、feature 开关、语言/双向/竖排 | fontc 1.0.0 原生编译产生有效 GSUB/GPOS；CoreText 已实测 `fi` 连字、`AV` 字距与 `A + U+0301` 锚点附着。完整任意 FEA 通过源程序编辑，错误程序返回真实编译失败。 |
| F06 变量字体 | 轴与坐标映射、母版/命名实例 CRUD、轮廓/组件/锚点/位置兼容检查、复制字形修正兼容、OpenType support-tent 源插值、静态实例工程和字体、变量 TTF/WOFF/WOFF2 | 双轴、角点与中间修正母版在真实 fontc 输出上交叉验证，包含 kerning/竖排 metrics。导入二进制变量字体的可编辑母版为轴端采样；未编辑时预览和实例轮廓读取原始 gvar/CFF2，不能把端点采样称为原始完整源。OTF 只导出静态 CFF。 |
| F07 格式 | TTF/OTF/WOFF/WOFF2、UFO ZIP/Designspace ZIP、SVG 字体及矢量字形导入；原件保留与逐字节导出；当前工程对应格式导出 | UFO/Designspace 的映射坐标、字形、组件、锚点、许可、每母版 kerning/info、垂直 origin/advance 有往返测试。Designspace 要与全部 UFO 一起 ZIP 导入。SVG 支持变换、圆弧、基本矢量形状与本地 use，文本/栅格须先转轮廓，不取远程资源。 |
| F08 输出 | 真正 glyf TTF、真正 CFF OTF、标准 WOFF/内置 WASM WOFF2、单字形 SVG、SVG 字体、UFO/Designspace ZIP、工程、字体/许可包、示字 PDF/SVG/PNG | 原生 TTF 与 CFF 经 CoreText 加载/成形；OTF sfnt checksum、CFF/GSUB/GPOS 回读，以及静态/变量 WOFF 与 WOFF2 实际编解码回读均通过。PDF/PNG 的可见 WebKit 导出交给统一宿主验收，不以 JSDOM 代替。 |
| F09 iPad UI | 字符网格/搜索侧栏、中央轮廓、控制柄、触摸/笔指针、双指缩放/平移、框选/吸附、键盘移动/多选/删除、metrics、features、masters/axes、导出和诊断；中英双语 | 六面板与 inspector 操作入口已做 DOM 行为检查；原生 WKWebView、触摸与真实 App 入口验收由统一宿主完成。本模块未启动 Simulator 或使用实体设备。 |
| F10 AI/宿主 | 与 UI 共用可发现字段和命令的 dispatcher、共享 revision/history、宿主授权的 `font.compile` 扩展、受控本地 fontc staging | 接入合同和有具体参数的 smoke plan 见 `Integration/`。模型只能得到绑定工程 lease；目录、owner、授权与文件服务不由工程或模型参数决定。 |

## 二进制导入与重建策略

导入原文件的字节始终单独保留，`original` 导出返回原件。编辑工程保存已解析的轮廓、字符映射、metrics、默认脚本可还原的普通 kerning、轴/实例信息及用户编辑的 FEA。未改动的二进制字体打样直接使用原始 sfnt，保留原有实际成形；编辑后重新编译当前源。

重建不会把未解析的 GSUB/GPOS/GDEF 程序、hinting、未知表、彩色字形程序或签名表无声复制为有效编辑结果。原件与重建结果是分别可导出的交付物。导入多轴二进制字体的轴端采样也不等同于完整设计源；需要原始设计源时导入 UFO/Designspace。

所有渲染入口严格要求坐标、advance、metrics、锚点与组件矩阵是有限数值；原始 JSON 文本不会成为 SVG 属性。特性 include 和越界/链接解压路径被拒绝。取消只围栏编译结果并保留 C 调用所需 staging 至返回，不声称可以立即终止原生 C/Rust 栈。

## 聚焦验证

```sh
node FloeAgent/Qualification/HeavyEditors/WebBuild/build.mjs font
node FloeAgent/Modules/FloeFontKit/Tests/Web/run-tests.mjs
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --package-path FloeAgent/Modules/FloeFontKit \
  --scratch-path ~/Library/Caches/CodexBuild/FloeHeavyEditors/shared-main/xcode-27B52/font \
  --jobs 2
```

完整格式行为回读先运行 Swift 测试并设置 `FLOE_FONT_TEST_ARTIFACTS` 为项目内私有证据目录，再将该目录的 `static-layout.ttf` 通过 `FLOE_FONT_NATIVE_TTF` 传给 Web 测试。测试会保存本轮真实 TTF/OTF/WOFF/WOFF2；其余核心行为测试不依赖该可选产物。原始失败和成功日志由统一交付者保留，不能用一次重试掩盖原失败。
