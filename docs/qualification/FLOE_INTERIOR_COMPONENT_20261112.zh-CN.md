# 室内组件预研：柜体、独立成果与家具资料

日期：2026-11-12。状态：独立组件预研，未接入完整 App。首阶段从 `59c57650e` 工作树读取；本次继续阶段基线为 `349d61b36d1df6033a718167e41ebafad6c91c1d`，均保留其他任务既有修改。最终原生验证使用现有 CAD 源码的私有副本与一个来源保存补丁，不能作为未改动主线 CAD 或完整 App 的通过证据。

## 一、本轮可核验结果

| 范围 | 实际结果 | 限制 |
| --- | --- | --- |
| FloeInteriorCore | 13 项 XCTest 通过，0 失败；Swift 6 实际编译 | 固定柜体构造规则，未覆盖全部柜型或制造 |
| 原生组件宿主 | 私有 CAD 补丁下 3 项通过、0 失败、0 跳过 | 主线 CAD 未由本任务修改；默认宿主仍需导入体移动修复 |
| 柜体与保存 | 19 个解析 BRep，逐板体积／坐标核对，保存重开一致 | 新建草稿，未绑定完整空间项目数据库与整体撤销 |
| 独立 STEP | 19 实体导出、毫米单位、异步解析到新文档，逐实体范围／体积匹配；副本真实移动 10 mm 后保存，原件身份／变更数不动 | 当前 STEP writer 不保留历史、部件名称或装配层级，不是完整建筑语义导出 |
| 三张样图 | 柜内立面、侧剖、顶板轮廓各生成 SVG／DXF／PDF；实际宽高及纸面位置核对，三份 PDF 逐页查看 | 技术几何样图，未完成完整组合图、柜体斜视、正式尺寸标注、图签、索引与成套生产图 |
| 整柜出图预算 | 19 来源返回 `too_many_bodies`，模型保留 19 板，不产生残缺图页 | 当前每页来源预算仍为 12，没有绕过或删除部件 |
| 成熟墙面算法 | 固定 OpenPlan3D 原始源码 10 场景通过 | Node 执行，未原生移植、未运行 RoomPlan 导入 |
| 家具资料 | 官方 CC0 包 175 条，169 条基础引用完整、6 条待修复；175 版本进入可中文检索的 SQLite 暂存库 | 原生导入、外观和 App 入库均未验证；`asset_release` 为 0 |

领域测试包括几何尺寸／不重叠、稳定身份、材料依赖、预算、制造条件缺失、输入拒绝、版本往返、快照防篡改、CSV 转义，以及本次增加的视图方向／原点合同和非有限值拒绝。新增两项没有用此前 11 项结果替代。

## 二、组件与坐标

研究源码为 `FloeAgent/Modules/FloeInteriorKit/`，宿主为 `FloeAgent/Qualification/Interior/`。它们没有主 App、主项目或根 Package 引用；曾在并行发布窗口按摘要保全，之后原位恢复。本任务没有改 App、主 CAD 源码、版本、Git 或发布状态。

标准示例柜宽／高 2400 mm、柜身深 600 mm，三格各三层板，含三个门面，共 19 板。宽改为 2600 后 ID 保持，顶底板长度由 2364 变为 2564 mm；门面加间距使整体深 620 mm。CSV 是设计尺寸，制造标志一直为 false。

领域坐标为 X 宽、Y 前到后的深度、Z 高；原生地面草图映射到 `(x,0,-v)`，沿 +Y 拉伸。`InteriorDrawingFrame` 统一转换法向、水平轴和原点，明确处理 CAD 出图当前将 `viewUp` 用作平面内 X 轴提示的接口约定。

新图纸用宽 2400、高 2100 的七板柜身，避免正方形掩盖轴向错误。1:20 下的实际范围为：

| 样图 | 模型宽 × 高 mm | 纸面宽 × 高 mm |
| --- | --- | --- |
| 内部立面 | 2400 × 2100 | 120 × 105 |
| 侧剖 | 600 × 2100 | 30 × 105 |
| 顶板轮廓 | 2364 × 600 | 118.2 × 30 |

原生几何回执检查了宽高及纸面中心；导出 SVG 的直线／M-L-Z 路径范围另行核对，PDF 按 110 dpi 渲染逐页观察，样例标签未重叠或裁切。此观察不扩大为全部曲线／图纸类型验收。

## 三、实际发现的导入体移动缺口

主线 `CADCommandExecutor.transform` 使用 `bodyRef`，未找到特征生产者时会构造临时 FeatureID；精确 STEP 导入体此时可能只有实体而没有生产者。首轮完整几何导入匹配已通过，但移动返回非成功。

结合源码定位，私有副本将这一分支改为复用已有镜像操作使用的 `preservedBodyReference`：保存导入来源，与移动节点一起进入同一个可撤销编辑。其余 CAD 源码没有由本任务改动；主线该文件摘要仍与复制前相同。

补丁：`interior-component-research-20261112/private-cad-transform-proof/imported-transform-source.patch`。实际测试与项目在该私有目录，原生证据为 `frame-fix04-private/`。保留原移动成功断言，并增加实际包围盒 X 方向 +10 mm、其余轴不变和实体总数 19 的断言；没有用保存摘要变化假装几何已移动。

**补丁尚未由本任务合入主线。** 默认宿主指向未修复主线时仍可复现该缺口。后续整合须带入此补丁或等效修复，再按真实主线运行，不能只借用私有宿主产物称为 App 已修复。

源比较同时观察到并行主线的 `FloeCADEditorView.swift` 后续变化；未吸收到私有验证副本，也未改动该文件。交件只包含来源保存的单文件补丁，不要求用旧私有包覆盖当前主线 UI。源码摘要记录了这一范围差异。

## 四、原始失败全部保留

- manifest 初稿 tools 6.0 不支持 iOS 26 常量，修为 6.2。
- canonical 选择未提供 stdin 库存而失败；按合同使用库存管道／with-lock，未改配置或另创设备。
- `native-run01` 宿主缺 Scene 生命周期，启动失败；补 Scene 配置后编译执行。
- `native-run02` 三项接口测试通过，但只验非空。PDF 复查显示默认方向错误，三张原样图及失败观察保留。
- `frame-fix03`：13 领域／原生编译通过；原生 1 项通过、2 项失败、共 3 个断言。两断言来自检查器误认 API 图层名，另一为 STEP 导入体移动失败。Xcode 还报告诊断收集时找不到 simctl，原日志保留。
- 旧 `frame-fix03/step-independence.json` 所在结果中的 `copyEdited` 仅基于保存身份，不能单独作成功移动证明；`VALIDATION_STATUS.json` 已明确该轮失败。最终通过使用实际几何位移断言。

原始数据库、包、生成文件、源代码快照和 xcresult 均没有覆盖。新结果使用独立目录。

## 五、成熟算法与真实家具数据

固定 [OpenPlan3D b0727b54](https://github.com/laanlabs/openPlan3D/blob/b0727b54da5f0f642722dcc88cc52d7236fadc9e/src/lib/utils/wallProfiles.ts) 的墙面源码，原字节 Git blob／SHA256 已核验，仅替换一个导入路径后运行 10 场景。厘米输入、弧墙 16 段近似仍须原生适配，不能当作精确 CAD 弧线。

继续沿 OpenCutList 找到其固定 MIT PackingSolver C++ 依赖。已核对源码、包装接口和依赖；未构建优化器或运行排板。制造的局部坐标、逐边封边、木纹、完成尺寸／基材尺寸／开料尺寸合同见[制造与排板预研](../FLOE_INTERIOR_MANUFACTURING_REUSE_20261112.zh-CN.md)。

真实 CC0 素材包、文件摘要、6 条材质问题、中文检索和数据库备份见[家具目录原型](../FLOE_INTERIOR_FURNITURE_INTAKE_20261112.zh-CN.md)。资产检索新增 `asset_version_id` 外键后，原 24 项数据库检查在新目录重新通过，8 类表单有效；无效资产关联拒绝、175 条版本检索及备份重开另有实际回执。尚未验证原生 GRDB、通用中文分词或 App AI 工具调用。

## 六、命令与交件

- 工具链：Xcode 27.2（27B52）／Swift 6.4.2，显式 `DEVELOPER_DIR`。
- 领域：`swift test --package-path FloeAgent/Modules/FloeInteriorKit --scratch-path <本任务SSD缓存>/core --jobs 6`。
- 原生：独立工程 `build-for-testing`，generic Simulator、6 jobs、arm64；随后 `test-without-building`，单一 canonical iPad、禁止并行目标。
- 所有实际构建／运行经共享 native 锁，设备操作另经 canonical 锁；结束先导出必要成果并关闭本任务启动的运行实例，再释放资源。未创建／克隆／重置设备，未使用物理 iPhone。
- 最终 `frame-fix04-private/native-run/run-receipt.json` 为成功与 Shutdown；当前观察到启动设备库存为空。
- 精确 Simulator 宿主与 xctestrun 已保存为 `frame-fix04-private/InteriorNativeHost-simulator-arm64.tar.gz`，摘要与包内测试可执行文件读回已核验；它不是设备 IPA 或完整 App。

本地根目录：`interior-component-research-20261112/`。

| 路径 | 内容 |
| --- | --- |
| `native-run01/`、`native-run02/` | 启动原失败、旧非空测试和错误方向样图 |
| `frame-fix03/` | 未修主线的断言失败、13 项领域通过记录及当时源码 |
| `frame-fix04-private/` | 最终 3 原生通过、13 项相同源码复用证明、三页新样图／几何、STEP 和独立副本 |
| `private-cad-transform-proof/` | 可评审单文件补丁、固定私有源码和项目 |
| `upstream/`、`manufacturing-upstream/` | 已执行墙面算法和仅读取的制造／排板源码，分别标明状态 |
| `asset-intake/` | 原素材包、基础检查、来源版本／目录暂存数据库与备份 |
| `source-snapshot/` | 第一阶段源码；不替代本阶段实际来源 |

剩余重点：主线整合、12 来源以上的同场景遮挡出图与取消／内存预算，正式尺寸／图签／索引，制造与五金规则、排板原生封装、家具原生呈现及项目数据库与 CAD 的可恢复联合提交。完整 QA 目标保留，没有将技术样图视为成套施工或制造成果。
