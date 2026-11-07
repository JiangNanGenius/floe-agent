# GIS 宿主接入合同

GIS 包只管理当前工程的内容与编辑器状态。Space、Notes、任务结果卡的稳定原件 ID、owner、目录、权限、文件索引、返回页面和 PDF 保护预览仍由 App 现有服务负责。不得让模型参数、导入文件或工具输出决定这些身份。

1. 宿主在原有原件服务中建立／解析 `HeavyEditorDocument(kind: .gis)`，先验证绑定 owner，再用 `GISWorkbench.open(directory:documentID:owner:hooks:)` 打开同一存储，显示 `GISEditorView`。不能复制成另一个聊天私有原件替代手记附件。
2. `HeavyEditorHostHooks.authorize` 接现有访问／修订策略；`didSave` 回写当前原件标题、修订与卡片缩略图。普通授权内编辑沿用同一授权，不引入 GIS 自己的逐动作审批系统。
3. `export` 使用现有托管文件服务提交、读回并索引 `HeavyEditorArtifact`，然后返回 `try HeavyEditorExportReceipt(fileID: actualOpaqueFileID, artifact: artifact)`。成功结果必须带真实 fileID／SHA-256／byteCount；不能只返回文件数或自行拼出一个路径。
4. 文件选择器通过 `controller.importFile(name:data:expectedRevision:)`，原文件保留。常规格式文件导入到当前工程；`.floegis` 明确替换工程内容，宿主仍拥有原件身份。导入源不会授予新的权限。
5. AI 通过宿主解析并持有 `HeavyEditorModelLease`，先 `HeavyEditorModelCalls.execute(.describe,kind:.gis,request:lease:)` 获取真实 catalog、选区和 `baseRevision`，再 `.invoke` 调用当前实际命令；导出使用 `.export`。模型只可指定已有工程 ID、预期修订、命令和参数。lease 在成功或失败后释放；不由模型创建 WKWebView、owner、目录或 hook。
6. 关闭、取消、导航或任务切换使用共享 controller 的取消／保存生命周期；Web `pagehide` 会释放地图、数据库、Blob 和 GPU 资源。回到 Notes／Space／任务结果时仍使用宿主保存的原件 ID。PDF 产物进入已有 `PDFKitGate` 或同等已保护预览，不由本模块新建 PDF 阅读路径。

`project.*` 管工程；`layer.*`／`group.*` 管图层；`feature.*`／`field.*`／`attribute.*` 是编辑；`query.*` 是读；`vector.*`／`raster.*`／`terrain.*` 是参数化分析；`layout.*` 是制图；`file.export`／`layout.export` 使用导出访问级别。实际描述符和访问级别来自 `EditorEngine.catalog()`，不能把 README 当成扩大工具权限的白名单。

`smoke-plan.json` 的每一步均经 `main.js` 同一 dispatcher 实际执行；GeoPackage 的 CRS、几何和面积字段已重读，SVG 的内嵌 DEM PNG 已解码。统一 NativeBridge 可按步骤依次调用，不需要知道样例随机图层 ID：样例首先选中面图层，后续命令使用当前选层。

组件证据不代表主 App 验收。主线需确认真实入口、原件绑定／返回、宿主授权、保存重开、工具发现／执行、真实导出回执；屏幕验收另覆盖触摸节点、多选拖动、表联动、三维手势、布局与 PNG/PDF 输出。已有组件通过项无需为每个入口重复全套检查。
