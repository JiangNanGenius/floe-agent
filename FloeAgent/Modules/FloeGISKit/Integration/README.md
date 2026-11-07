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

## 原生界面合同

`GISEditorView` 把 `GISNativeOutline`、`GISNativeCanvasToolbar`、`GISNativeInspector`、`GISNativeStatusBar` 传给共享 `HeavyEditorView` 的原生槽位；属性表模式另外用 `GISNativeAttributeTable` 覆盖中央画布。`controller.presentation` 是 `configuration.nativeSnapshot` 的显示投影。普通按钮使用 `controller.runCommand`，参数化操作使用 `controller.showCommand`；两者都复用同一 service-owned dispatcher、访问控制与保存链。视图不执行任意 JavaScript，也不维护第二份工程模型。

| 快照字段 | 内容与边界 |
| --- | --- |
| `kind` / `crs` | 固定 `gis` 与工程坐标系。空工程返回空列表／空选层，可在初始化时读取。 |
| `ui` | `mode`、`tool`、`multiselect`、`snapping`、`page`、`filter`、`sort`、`sortDescending`、`onlySelected`、`columns`、`terrainFactor`、`vertexAction`、`drawing`。只存在运行时，不进入 payload／历史。 |
| `layers` / `groups` | 每层的 `id`、`name`、`kind`、`group`、0 起 `index`、`visible`、`locked`、`opacity`、`crs`，及适用的 `count`／`width`／`height`／`bandCount`；组包含 `id`、`name`、聚合显示／锁定状态与 `layerIDs`。 |
| `selectedLayer` | 上述图层摘要、受支持的 `style` 字段、完整字段模式 `fields`、最多 20 条 `legend` 与 `legendCount`；无选层时为 null。不会复制任意导入样式附带的未知内容。 |
| `selection` | `layerID`、规范字符串 `featureIDs`、`count`、`hasClipboard`；最多 4 个要素摘要，包含 `rawID`、名称、几何类型、最多 24 个属性摘要与 `attributeCount`。属性文本最多 512 个 UTF-16 单元，保持代理对完整，带 `truncated`／`isNull`。 |
| `table` | `layerID`、完整 `fields`、选定 `columns`、当前页 `rows`、`total`、`filteredCount`、0 起 `page`、`pageSize=25`、`pageCount` 及筛选／排序设置。默认 8 列、最多 12 列，也可只显示 ID。行包含字符串 `id`、原始 `rawID`、`selected` 与单元格摘要；单元格文本最多 256 个 UTF-16 单元。 |
| `bookmarks` / `layout` / `view` / `terrain` | 书签 ID／名称；受支持的纸张／比例尺／标题／图例设置与 `annotationCount`；实际地图中心／缩放／范围；地形来源层 ID／名称与夸大倍率。排除标注正文、几何坐标、波段样本、瓦片字节、离线数据库和历史。 |

所有 `gis.ui.*` 命令均有显式参数字段，并设置 `access: read`、`sideEffecting: true`、`hidden: true`。它们不写内容或修订，也不会作为普通分析工具出现在菜单中。`features` 和 `columns` 字段是 JSON 数组，调用时传原生数组。

| 命令 | 参数 |
| --- | --- |
| `gis.ui.mode` | `mode`: `map` / `table` / `terrain` / `layout`。 |
| `gis.ui.tool` | `tool`: `select` / `Point` / `LineString` / `Polygon` / `modify` / `translate`。 |
| `gis.ui.options` | 可选 Bool `multiselect`、`snapping`。 |
| `gis.ui.selectLayer` | `layer`: 实际图层 ID；清空原选区并重置表格页／列／筛选。 |
| `gis.ui.selection` | `layer`: 实际矢量图层 ID，`features`: 原始或字符串要素 ID 数组；只保留当前层实际存在的规范 ID。 |
| `gis.ui.table` | 可选 `filter`、`sort`、Bool `sortDescending`／`onlySelected`、字符串数组 `columns`、0 起 `page`；页码按实际结果约束。 |
| `gis.ui.terrain` | `factor`: 0.1–20。 |
| `gis.ui.drawing` | Bool `active`；由实际 Draw 事件通知原生完成／取消按钮状态。 |
| `gis.ui.canvas` | `action`: `fitLayer` / `zoomIn` / `zoomOut` / `finishDrawing` / `abortDrawing` / `insertVertex` / `deleteVertex` / `clearSelection`。只调用固定画布动作。 |

地图点击和原生表格选区互相回流；修改节点／平移等写入仍使用原 `feature.*` 命令。长文本或 JSON 单元格打开 `attribute.set` 原生表单时，动态默认值从当前原件取完整值，不以显示用截断文本回写。原生组显示／锁定按钮只传被修改的属性，不覆盖组内另一项的混合状态。

共享宿主在首次 reload 前设置 `nativeChrome`；GIS 在该模式不生成 Web 图层栏、检查器、模式栏、绘图工具栏或属性表，中央 OpenLayers／Three.js／SVG 绘制保留。fallback Web 宿主仍可使用原有完整 HTML 界面。新增面板的对象编译与屏幕验收归主线，此次 Node 证据只验证显示投影、命令语义及实际数据编辑。
