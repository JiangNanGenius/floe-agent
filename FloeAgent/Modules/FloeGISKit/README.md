# FloeGISKit

离线 GIS 工程、矢量编辑、空间／栅格分析、DEM 与制图组件。SwiftUI 包提供 iPad／iPhone 原生宿主，内置 WKWebView 使用固定版本的 OpenLayers、Turf、proj4、GeoTIFF、官方 SQLite WASM 和 Three.js。空间及栅格计算是内置 JavaScript 实现，三维地形由 WebGL 绘制；没有声称集成原生 GDAL、PROJ 或 QGIS，也不需要远程 CDN。

Floe-authored sources are MPL-2.0. Third-party components retain their own notices; JSTS explicitly uses EDL-1.0. This is an independent component, with App navigation and release owned by the main integration.

## 使用与验证

- `GISWorkbench.descriptor`、`makeDocument`、`open` 与 `GISEditorView` 为 Swift 入口。
- `Integration/README.md` 定义宿主所有权、修订、文件与 AI 调用合同；`Integration/smoke-plan.json` 是可直接执行的同一 dispatcher 验证步骤。
- `node FloeAgent/Modules/FloeGISKit/Tests/run.mjs` 运行组件验证。默认复用主线固定的内部 Web 工具链，也可设置 `FLOE_EDITOR_WEB_TOOLCHAIN`。测试临时构件写入内部 SSD 缓存，不修改锁文件或安装依赖。
- `node FloeAgent/Qualification/HeavyEditors/WebBuild/build.mjs gis` 只重建本模块的离线资源与依赖声明。
- iOS 对象编译使用 Xcode 27.2（27B52）、Swift 6.4.2、`arm64-apple-ios26.0-simulator`，独立 scratch、2 jobs。没有启动 Simulator。

当前组件的 31 项 Node 功能验证通过，涵盖实际二进制重读和 `main.js` dispatcher；iOS arm64 对象编译通过。触摸／笔、WebGL、WKWebView PNG/PDF 导出与真实 App 导航的实际屏幕验收由主线资格宿主负责，不将 Node 或对象编译等同于设备通过。

## G01–G10 功能矩阵

| 项 | 实际实现与入口 | 验证与边界 |
| --- | --- | --- |
| G01 工程 | `model.js`：`createGIS`／`normalizeGIS`；`project.*`、`layer.*`、`group.properties`。多图层／字符串图层组，顺序、可见、锁定、透明度、CRS、范围、书签、源元数据。`document.save` 保存当前实际地图范围；共享 runtime 持久化可逆修订。 | 保存重开、空图层字段模式、撤销／重做、跨 CRS 剪切粘贴验证。`.floegis` 是带 `schemaVersion`、`data`、`history` 的 JSON 工程快照；宿主保存使用同一 payload。历史上限由共享 runtime 管理。 |
| G02 矢量编辑 | `model.js`：Point／MultiPoint／LineString／MultiLineString／Polygon holes／MultiPolygon／GeometryCollection，ID、属性、增删、多选、复制／剪切／跨图层粘贴、共同中心变换、节点插删改与原子批量更新。`view.js`：Draw、Modify、Translate、Snap；触摸插删点、完成／取消线面绘制、多选拖动。 | holes／Z／闭环／退化环拒绝、批量失败回滚、锁定、跨 CRS 粘贴均验证。`vector.split`／`mergeLines`／`difference` 提供切线、接线、挖洞；`query.measure` 测量面积／长度。实际触控精度待宿主验收。 |
| G03 表与样式 | `view.js` 属性表可直接编辑，搜索、排序、仅选区、分页与地图选区联动；`field.edit`／`calculate`、`attribute.set`、`query.attributes`／`sql`。`symbology.js` 为地图、图例、打印与瓦片共用单色／分类／等间隔分级、填充／线宽／点径／标签。 | 空图层字段、重命名、类型、JSON／布尔、引用字段名、SQL 只读／单语句及选区回流验证。SQL 表为当前图层的隔离 SQLite 快照，`_id`／`_geometry` 为查询保留列，不访问宿主文件。 |
| G04 格式 | `formats.js`：GeoJSON、CSV WKT／坐标列、GPX、KML／KMZ、真实 Shapefile、GeoPackage、GeoTIFF、ASCII Grid、PNG／JPEG／WebP＋world file、影像 MBTiles。 | 下表逐项列明编码变体。Shapefile／GeoPackage／GeoTIFF／MBTiles／CSV／world file 有实际写入重读；GPX／KML 使用内置 OpenLayers 格式实现，DOM 路径由宿主验收。没有用改后缀 JSON 冒充格式。 |
| G05 坐标 | `defineCRS`／`transformPosition`／`transformGeometry`／`projectedBounds`；EPSG:4326、3857、32601–32660／32701–32760 UTM、自定义 proj4／WKT。工程 CRS 实际用于地图；图层重投影、栅格 warp 和导出转换。 | 南半球 UTM 真坐标与投影往返、多波段 UTM GeoTIFF、3857 GeoPackage 重读验证。坐标始终为传统 GIS 的 X/Y，经纬度是经度／纬度，距离／面积分析输出米／平方米。日界线约定见下文。 |
| G06 空间与栅格 | `analysis.js`：buffer、clip、intersection、union、difference、dissolve、simplify、convex hull、spatial join／汇总、位置查询、最近边界距离、面积／线长；栅格采样、nearest／bilinear 重采样／warp、安全波段表达式／指数、阈值／分位数／等间隔分类、面裁切、拼接、统计与分区统计。 | 真实 union／intersection bbox、含洞差集、多线裁剪／切割、空间连接数值、真实最近边界、裁切／拼接像素、波段表达式、NoData、分区统计验证。改变数据的计算生成可继续编辑的新图层并选中；查询／全局统计返回表。 |
| G07 地形与图 | Horn 坡度／坡向／hillshade、marching-squares 等高线、采样剖面与结果图、Three.js 三维 DEM、无向矢量网络的交点连通／吸附起终点／Dijkstra 最短或字段倍率成本路径、IDW 插值。 | 平面 DEM 0 坡度／真实阴影、等高线坐标、线段内部起终点路径、成本／长度、常值 IDW、剖面高程验证。平地坡向为 -1；不将三维 mesh 声称为原生 GIS 引擎，GPU／手势实屏另验。 |
| G08 制图与导出 | `layout.settings`／`annotation`／`clearAnnotations`、`layout.export`。A4／A3／Letter、横竖版、当前实际范围／固定比例尺、指北针、共用分类图例、标签／文字标注，真实 SVG／PNG／PDF。 | SVG 是矢量要素＋重投影后的内嵌 PNG；数据 URI PNG 已重读。范围保持比例，透明度／分类颜色／holes／标签与地图一致。PNG／PDF 是浏览器实际栅格化的成品；PDF 按纸张大小居中适配，交给宿主既有保护预览。Node 不替代 WKWebView PNG/PDF 屏幕验收。 |
| G09 UI | `GISView`：图层栏、地图／属性表／3D／制图、属性／样式 inspector、参数化工具菜单。iPhone 可打开属性对话框；工具、表、节点与选区调用同一 `perform`。地图支持平移／缩放、绘制完成、吸附开关、触摸多选／拖动／节点插删，键盘 Cmd/Ctrl+C/X/V 和 Delete。 | 源码可达入口与结果 dispatcher 已核对；资源释放验证覆盖地图、离线 DB／Blob、3D 对象生命周期。iPad／iPhone 与笔的实际交互由主线验收，未宣称物理设备通过。 |
| G10 AI／宿主 | `main.js` 实际 `EditorEngine` dispatcher、可发现命令／字段／访问级别；共享 `HeavyEditorModelCalls` 与宿主 lease、owner／revision／authorize、真实导出回执。`GISWorkbench` 只开放当前绑定原件。 | 真实 bundled dispatcher 执行样例→计算面积→导出并重读 GeoPackage→导出包含 DEM 的 SVG；见 smoke-plan。宿主决定 owner／目录／文件身份，模型没有选择任意路径、授权自己或导入任意 base64 的旁路。App 导航与发布不在模块验证范围。 |

## 格式与计算约定

| 格式／功能 | 实际支持 | 明确边界 |
| --- | --- | --- |
| GeoJSON | geometry／Feature／FeatureCollection，全部上述几何及 null geometry、ID 与属性；输出 EPSG:4326。 | 非 4326 的导出要求使用 GeoPackage／Shapefile／CSV。属性值和几何结构检查在导入、编辑与 undo/redo 后执行。重复 feature ID 在图层内重新分配。 |
| CSV | UTF-8，带引号／换行／转义引号，WKT 或 x/y、lon/lat 等常用坐标列；空 WKT 为 null geometry；WKT 输出全部图层几何。 | CSV 自身没有标准类型模式；读取对非空数值自动识别，其余为文本。复杂属性输出 JSON 文本。坐标 CRS 由参数或图层设置决定。 |
| GPX／KML／KMZ | 内置 OpenLayers 读写 XML；KMZ 取内置 KML；拒绝外部实体／DOCTYPE。 | GPX 输出限点／轨迹，面／集合明确报错。KML 导入取几何与属性，不声称无损保留外部样式、网络链接或 KMZ 附属媒体。 |
| Shapefile | ZIP 或分开的 SHP／DBF／PRJ（SHX／CPG 可附入）。独立写入真实 SHP／SHX／DBF／PRJ／CPG，XY 点／多点／线／多线／面／多面／洞；混合几何输出分别完整文件组。 | 输出 XY，遇 Z/M 要求改用 GeoPackage；输入由固定 shpjs 解析，不承诺所有扩展类型无损保留。DBF 数字最多 8 位小数、文本最多 254 UTF-8 字节，超出明确报错；长字段名标准映射到 10 字符，附 Floe 字段／ID／null 元数据可在本模块恢复，其他软件读取标准 DBF 名称。 |
| GeoPackage | 真 SQLite application_id／核心表、矢量 WKB XY／XYZ／XYM／XYZM、洞／多部件／集合／null，保留实际 EPSG CRS；自定义 CRS 需 WKT。Floe 元数据保留字符串 ID／字段类型／JSON 属性。 | 不支持栅格 GeoPackage、曲线／扩展几何、加密 SQLite。第三方普通矢量表按核心标准读取；未知扩展不会被伪装为已支持。 |
| GeoTIFF | 第一 IFD、北向上且 Orientation=1、EPSG 地理／投影键；Float32 单／多波段与 NoData 实际往返。读取能力来自固定 geotiff 库；无配准 TIFF 可手工设置范围。 | 写入未压缩 IEEE Float32、north-up、PixelIsArea。PixelIsPoint 输入按像元中心校正。旋转／剪切／翻转方向明确要求先 warp，不把外包 bbox 当成正确像元配准；没有宣称所有压缩／IFD／CRS 变体都已验证。NaN NoData 转为未占用的有限标记，以便宿主 JSON 工程保存。 |
| 影像／world file | PNG／JPEG／WebP 读取 RGBA，导入 pgw/jgw/tfw/wld/pngw/jpgw 与 PRJ 配准；地理 PNG 导出带 PGW／PRJ。 | 北向上，无旋转／剪切。普通影像未配准时使用像素范围，必须设置范围或导入 world file 后才具备真实地理位置。 |
| ASCII Grid | ncols/nrows、corner／center、cellsize、NoData、单波段读写；导出 PRJ。 | 正方形 north-up 像元；输入未给 CRS 时默认 4326，可随后导入 PRJ 或设置配准。 |
| MBTiles | 真 SQLite metadata／tiles；PNG／JPEG／WebP 影像导入与原字节导出；栅格按当前样式实际生成 256px PNG 瓦片、Web Mercator、TMS Y 行号和元数据。 | 不接收 PBF 矢量瓦片。新输出限定 zoom 0–22、最多 4096 个瓦片；超出要求降低级别。显示重建／关闭时释放数据库、statement 与 Blob URL。 |
| 数值计算 | 每层最多 16,777,216 像元，IDW 输出最多 4,194,304 像元；表达式为独立算术／比较／逻辑解析器，支持 B1…、where、abs 等数学函数。 | 不执行 JavaScript 或任意代码。面操作是平面拓扑＋经纬度输入，度容差在 UI 明示；距离／面积为地理量。网络是无向图，成本是每米字段倍率，不声称支持方向约束或交通时刻。 |

经度跨 180° 使用显式展开约定：`layer.unwrap` 按共同中心经度输出连续经度（例如 179°→181°），地图和制图把要素放到当前视图所在世界。跨日界线的多图层分析应先对所有输入使用同一中心展开。工程／导出保留这个连续经度约定；没有声称自动把所有面、洞、Z/M 拆分成 RFC 7946 推荐的日界线两侧部件。

工程定义与图层定义分别保留；广泛 CRS 由内置 proj4 接收精确的定义，不猜测缺失的 EPSG，也不从网络下载。重投影／制版对包络边界加密取样，栅格输出按目标像元反投影采样。

## 依赖与许可

固定依赖、实际 bundle 输入及完整原文见 `Web/bundle-inputs.json` 和资源中的 `dependency-inventory.json`／`THIRD-PARTY-NOTICES.txt`。`THIRD_PARTY/JSTS` 另外保留 JSTS 原始 EDL、包声明、来源及 SHA-256，资源下有同字节分发副本；选择 EDL-1.0，不由 Turf 根 MIT 覆盖。实际完整传递闭包由主线构建统一采集。

格式实现参照 [OGC GeoPackage 1.3.1](https://www.geopackage.org/spec131/index.html) 与 [Mapbox MBTiles 1.3](https://github.com/mapbox/mbtiles-spec/blob/master/1.3/spec.md)。实现不是这些组织的认证声明。
