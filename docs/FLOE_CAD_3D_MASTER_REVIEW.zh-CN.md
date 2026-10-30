# Floe CAD／三维能力总评估与实施交接

更新：2026-10-31。本文件汇总原106项能力缺口、39组复用／许可证评估，以及新增的3D文件查看和模型视觉检查核查；作为本轮统一阅读入口。后续章节包含逐项内容，关联文件只作机器数据或证据补充，不要求读者拼接多个报告。

## 1. 结论与证据边界

现有应用已经有精确CAD、网格、材料、装配／图纸基础、3D只读查看、部分动画和截图工具；缺口集中在专业深度、不同入口的一致性、关联编辑、完整资产保真和真实AI连续检查。不能把原表的“planned”理解为整个功能不存在，也不能把库可用或组件测试通过写成完整App功能已闭环。

- 原106项编号及验收条件全部保留。M12四类孔是冻结源码、未编译验收；M13螺纹与M16／M17导轨／曲面仍仅有预研／探针源码。
- 已有240项唯一用例通过证据来自195项组件、43项未受影响宿主用例及2项修正新fixture后的复验，不是一次240项运行，也不是动画／完整App／实体设备全部验收。
- GLB／glTF已有本地只读查看路径；工具输出卡和“文件”页等入口未统一，复杂资源、动画／骨骼／Morph和压缩扩展没有完整查看合同。
- 静态CAD截图传视觉模型的源码路径存在，手动工程截图审阅也存在；任意原始3D文件的自主多视角检查及绑定对象修改仍不完整。动画帧图片目录与运行时注入规则、图片大小预算发现具体静态不一致，须优先复现修复。
- 开源复用优先现有OCCT／acadrust／Floe服务及必要系统SDK，其次MIT等许可清楚的小组件。许可证允许不等于已适合iOS；库不提供本项目的全部UI、稳定ID、撤销、保存和AI工具链。
- 本轮新增工作均为源码／依赖／许可与已有证据核对；未新构建、运行UI、调用真实模型进行视觉验收、安装候选或发布。没有改变当前MPL-2.0分发路线。

本线程限定代码资格来源为`33abe3e7`；总账／复用文档来源为`a0fc06c0`／`9f320a8f`。其上H1仍为本工作树未提交源码叠层，尚未编译；本次文档提交不把H1当作已交付代码。另一更新线程目标只读快照为`7b06c746`，收尾`4b72b1ba`是文档后续，本次核查的UI／Runtime关键路径未变；10份目标UI文件与本树逐字节一致，Runtime关键函数另做局部比较。不能据新测试源码或进程完成推断运行结果。接入时读取其最新交接，保留已有修正，不整份覆盖旧文件。

## 2. 3D查看：必须分清的五层

|层次|需要回答的问题|不能替代的验收|
|---|---|---|
|文件识别与缩略图|附件、输出卡、文件页、IDE、Canvas能否识别并路由同一格式？|扩展名识别和有封面不代表模型加载成功。|
|原文件只读查看|能否不改变原文件就旋转、缩放、选场景／镜头和查看资源缺失？|导入到.floecad后看到三角网格不等于保留完整原资产。|
|完整资产查看|是否保留层级／实例、材质、纹理、动画clip、skin／morph及所需解码器？|静态姿态、只渲染部分primitive不能表示完整支持。|
|模型视觉观察|是否产生真实图像、自动注入本次模型请求，并绑定来源、视角、时间和版本？|JSON模型摘要、artifact路径、proposal diff不是视觉输入本身。|
|基于证据继续编辑|模型能否用图像加稳定句柄／测量定位问题、修改同一对象并重看？|单次截图或人工“发送给AI”不等于自主闭环；照片不能证明制造／物理正确性。|

### 2.1 已确认的入口分叉

普通聊天附件／工作区／IDE：`ChatAttachmentOpen → FilePreviewView → EngineeringPreviewPackage → EngineeringFilePreview → 本地Online3DViewer`。GLB／glTF等可达只读旋转、缩放、平移和fit。STEP／IGES的该查看路径经本地OCCT worker转为显示网格。

工具运行输出卡和“文件”页另有直接QuickLook路径，未统一复用工程分派；USDZ／.blend在独立预览的自定义格式分派中也未覆盖。QuickLook被调用只说明走到系统预览，不能在没有实际文件／设备证据时承诺全部格式有效。手动CAD导入和工作区直接查看是不同入口。

局部源锚点：`FilePreviewView.swift:1032`、`EngineeringPreviewPackage.swift:9`、`RunOutputFileView.swift:173`、`FilesView.swift:177`、`Resources/EngineeringViewers/viewer.js:173–201`。源码路径均位于FloeAgent的既有模块中，完整格式表见下文。

|格式／资产|普通附件／工作区／IDE直接查看|原生CAD导入后的查看|模型可用视觉路径／剩余问题|
|---|---|---|---|
|.floecad|真实原生工作台／Present|原生权威文档|自主capture已有；对应模型／多轮和新孔包未本轮验收。|
|GLB|本地O3DV静态网格查看|Import Mesh静态parts|手动工程review可附图；原文件自主多角度、动画／skin／morph未闭环。|
|glTF|同上；本地可读限定siblings，附件／远程资源受限|手动可接资源；AI导入拒外部.bin／纹理|查看与导入合同不一致；缺资源／扩展需明确诊断。|
|OBJ／STL|本地O3DV静态查看|静态parts；不是参数历史|人工附图已有；OBJ材质依赖和STL单位需独立核对。|
|STEP／STP|OCCT worker转显示网格|原生STEP菜单／服务可导入精确实体|只读图像不保留精确面／颜色等全部信息；量测走原生内核。|
|IGES／IGS|OCCT worker转显示网格|服务可导入solid；shell／face为render-only；所查菜单未见明确IGES动作|已有人工附图，不能把壳当solid或把显示转换当制造验收。|
|USDZ|无自定义工程分派，落系统QuickLook|CAD菜单／ModelIO静态导入路径|系统是否能开具体文件未测；独立app观察／动画／资源保真未闭环。|
|Blender .blend|无自定义工程分派，落QuickLook；不承诺系统支持|CAD手动导入静态网格子集|不是运行Blender或完整读取节点／动画／场景；不能宣称无损再编辑。|
|FBX|分派到O3DV mesh|所查CAD原生菜单／工具未明确支持|静态识别不等于骨骼／动画可播；ufbx是评估候选而非已接入。|
|PLY／OFF／3DS／DAE／3MF／AMF／WRL／BIM|被识别并分派到mesh查看器|不能从viewer列表推定CAD导入支持|本轮未逐格式加载；点线／材质／实例／资源／扩展分别待验。|
|USD／USDA／USDC|未列自定义工程分派|底层MeshImportKit列出USD族；明确菜单入口／实际加载待验|不能从ModelIO存在推断完整USD场景／动画。|
|BREP|被识别为cadSurface显示转换|不能推定原生import支持|只读网格预览与精确建模格式入口分开声明。|
|FCSTD／IFC／3DM／DGN／DWT等|识别为明确unsupported|本轮未接入|不是因为上游工具宣称支持就自动纳入；若扩范围需单列验收与许可资格。|

**输出卡／“文件”页是上述表之外的入口维度**：所查代码直接QuickLook，不复用表中的自定义工程查看器。Notes工程封面已有GLB／glTF等离屏缩略图代码，输出卡inline封面主要只处理image MIME；两者也不是统一能力。本次全部为源码路径核对，没有逐格式真实加载或设备画面证明。

### 2.2 资源、静态导入与格式声明

本地预览包已有20MiB／32文件边界及同目录安全OBJ／MTL／glTF依赖读取；远程预览只有选定单文件，普通聊天附件也不会自动把分开发送的.bin／纹理重组成资源包。单文件GLB并不保证没有外部纹理或不支持的必需扩展。

原生`GLTFImporter`读取triangle primitive，烘焙节点世界矩阵后产生静态ImportedPart；这条路径不保留完整场景层级、骨骼／Morph／clip／相机编辑语义。原生GLBExporter主要接受bodies和面材质表，输出静态网格，未接动画数据。不能以原生CAD动画服务存在，推断GLB能保留该动画。

源码还显示：非triangle模式会跳过，未见必需扩展统一准入；无bufferView的float accessor会返回零，未见sparse覆盖应用。本次没有运行坏文件复现，故记录为静态风险：需对unsupported／sparse／压缩结构明确拒绝或给出完整性诊断，不能把静态子集当成完整GLB。

AI导入桥显式拒绝引用外部.bin／纹理的松散.gltf；本地预览能读部分siblings不意味着该工具导入已经支持。能力文案“self-contained .glb always works”应收窄到经验证的实际子集。

### 2.3 查看闭环的优先处理

1. 统一已存在的查看分派到普通附件、输出卡、“文件”页、工作区和IDE，保留各入口的receipt、来源与权限检查。
2. 只读源文件观察不应依赖先修改／导入用户模型；共享受控的文件、资源和预览服务，沿既有工具体系补观察合同，不新造执行框架。
3. 格式能力按“静态网格／场景资产／动画／skin／morph／压缩扩展”分别声明；未支持内容明确回执，不能静默省略后报告成功。
4. 资源打包、远程引用、缺纹理、解码器、容量与取消分别验收；不借助CDN或远端转换服务悄悄补齐本地能力。
5. 对每种格式保留原文件哈希，验证看完后原文件字节未变；导入、编辑、导出由相应独立事务承担。

## 3. 给模型的视觉检查链路

### 3.1 已有路径

- 原生文档：`cad.document capture → CadDocumentCenter → FloeCAD3DBridge实际renderer → PNG artifact → AgentRuntime图片证据 → 视觉模型payload`。回执包含revision、change_count、content/image SHA及renderer；非视觉模型只能用query／measure等数据，不能称为看图。
- 人工发起：工程查看器的review按钮通过真实WKWebView snapshot生成图像，连同来源hash和有限mesh context进入EngineeringReviewSheet，注册图片附件再startRun。可以不先导入.floecad，但仍是用户发起、当前视角的一张图；mesh context的bounds／计数不是完整选体handle或精确CAD参数。
- `preview`可能只是proposal的JSON／几何差分；`three_d_snapshot`是结构化快照。名字里有preview／snapshot不代表已经把光栅图传给模型。

人工review目前仍带二维“Whole drawing／Current selection”和engine handle提示语。3D mesh没有对应句柄时，应按实际资产收窄可选范围与说明，不能诱导模型虚构对象ID。文本主模型的人工附件可走已配置辅助视觉，得到的是辅助描述，并不等于主模型亲自看过图；这也不同于后续CAD工具产物的投递路径。

### 3.2 明确待处理的接缝

|问题|源码发现与边界|计划与验收|
|---|---|---|
|动画帧未自动内联|帧图写入CADAnimationFrames，而运行时图片证据前缀未包含该目录。本轮为静态不一致，未实际调用模型复现。|统一受信artifact分类／预算，测试真实provider请求中含帧图而不只是JSON路径；保留来源和权限校验。|
|截图预算不一致|工具可存16MiB图像，而运行时单图注入预算为8MiB，8–16MiB会遇到不内联分支。|明确拒绝或产生可追溯的受限预览衍生图；保留原图，记录缩放和摘要，不能静默声称已附图。|
|非视觉模型路线未贯通|CAD工具产物与已有附件visual-evidence辅助处理不是完全相同路径；模型能力与保存override必须尊重。|明确告知无视觉输入；如复用已配置且获授权的辅助视觉服务，要沿现有流程，不能自动改模型或转云端。|
|image.inspect补救不覆盖CAD|现有辅助图片工具的命名空间不含两类CAD截图目录，不能默认让文本模型用它补看CAD产物。|沿同一可信图像／辅助视觉服务接合，不另建绕过来源验证的读图入口。|
|任意模型自主观察不足|原生capture主要绑定live.floecad；人工GLB review有截图，但没有完整的模型自主重取多角度／时间帧／选体检查合同。|增加只读来源绑定、临时视角／时间覆盖、多视角和资源完整性回执，再与可编辑对象身份衔接。|
|视觉闭环运行证据不足|工具、附件和模型API代码存在，不证明实际选定模型收到图并可靠改同一对象。|对同一来源／版本执行“观察→query／measure→修改→复核图→撤销／保存重开”，分别留实际输入与产物证据。|

源锚点：`CadDocumentTool.swift:2346,2519,2588`、`AgentRuntime.swift:2733,3054–3077`、`ProviderImageEvidencePolicy.swift:19`、`RemoteImageTools.swift:325`；provider wire转换见`ProviderAdapter.swift:736,973,1192`。这些行号属于所查9f源码／冻结H1叠层，不与其他树混用。

还需保留三个运行语义：engineering截图是独立Metal渲染，可能使用已保存相机或bounds拟合，不能都称为用户刚转到的屏幕角度；Runtime只内联当前pending图片，后续文本历史／压缩上下文不保证保留或重送旧像素；哈希正确只证明那张图的字节与来源记录，不保证修改后仍是当前模型。复核必须主动取得新图与fresh query。

临时聊天的真实allowlist不包含cad.document。工具内部有只读／capture防御分支不等于获准在临时聊天读取本地CAD；不为补视觉链扩大临时聊天权限。已授权普通任务的只读观察可以产生app-owned图像证据，但不修改用户模型。

### 3.3 观察结果的最小合同

应包含来源路径／对象、源文件或模型摘要、实时修改代次、视角／投影／时间、显示与省略对象、缺失资源及不支持扩展、图像artifact与其摘要、是否真正进入当前视觉payload。截图和对象查询必须对应同一版本；来源变化后拒绝陈旧观察。

观察支持任意文件时保持只读。稳定句柄只能从真实场景／模型映射取得，不能从像素位置猜一个CAD面ID。尺寸、孔深、封闭性和BRep健康使用确定性测量与内核查询；多视角／剖切只补充可见证据，不给制造／动力学合格结论。

## 4. 统一实施顺序

|优先批|范围|交付边界|
|---|---|---|
|P0 查看与视觉证据一致性|统一文件分派；动画帧注入／图像预算；格式和资源诊断；只读观察合同|先使已有能力可发现且回执可信，核对真实payload及不改原文件。|
|P1 当前机械源码与关联基础|H1孔包资格；OpenShape基准构造器；更多基准／投影／曲线引用|保留已有FeatureGraph、服务、事务、身份和格式保护。|
|P1 产品动画编辑与出片|X23—X25、X28—X31，按真实依赖拆小批|先扩已有轨道／时间线／导出服务，不等待全部工程图完成。|
|P2 明确算法库资格|按需xatlas／meshoptimizer／Manifold／OndselSolver，以及ozz／Jolt／ufbx|固定实际模块／许可闭包，先device和arm64-simulator编译，再运行与文档回放。|
|P2 专业深度|其余机械、装配、工程图、二维与交换、网格／UV／材质|沿原编号独立验收，别把某个求值库当完整作者工具。|
|P3 重型专业后端|复杂曲面、完整骨骼／仿真、离线渲染、CAE／CFD、多轴车铣|成熟后端优先；本地平台未闭合就明确门槛，外部环境只能是明确选择的另一条路线。|

本表是工作批次而非预提交队列或时间承诺；与后文原A—H阶段的依赖保持对照。其他线程已做的修复／验收按其最新交接复用，不能重复重置或覆盖。

## 5. 验收与交接规则

源码／语法、对象编译、组件运行、完整App、真实模型payload与多轮行为、设备交互、实际输出文件以及发布是不同证据。新候选本轮没有构建，39组材料和新查看补评只证明所查源码／许可边界。

统一合同至少覆盖：支持子集和拒绝信息；所有入口一致；无网络／缺纹理／压缩／大模型；静态和动画场景；截图与查询同版本；模型真实收到图；失败／取消不改源；同对象修改、撤销、保存重开和独立读回。非视觉模型的文字回答不能冒充视觉验收。

只读观察不隐含修改权限；实际修改继续使用当前任务已授权的同一服务和事务，保留owner／revision／CAS校验，不为普通建模额外增加每步交互批准。文件内容、模型注释与图像中的文字不能授予工具权限。

保留本轮原始失败、源hash和限定范围的成功记录。7张原生编辑器关键PNG已按用户要求留在主仓库Local/Artifacts/cad-feature-intro-20261031，带来源／版本／用途索引；它们属于保留素材，不随缓存或工作树清理，正式用于功能介绍前核对正式App品牌与版本。

<!-- BEGIN CONSOLIDATED CONTENT -->

## 6. 3D查看器复用与许可证补评

检查基线：`9f320a8ff49c3aad782055e9547f9596f7799d9e`，H1 冻结修改全部保留。本包只调查查看器复用，不实施、不构建、不运行设备；不改变原 106 项状态。证据逐文件固定 URL、SHA256 见 `evidence/sources.json`。

结论：继续保留现有本地查看框架；普通静态网格沿用 Online3DViewer。需要 GLB/glTF 动画与层级预览时，优先评估在同一资源沙箱内使用现有版本 three.js 的 GLTFLoader，绕开 O3DV 静态中间模型。GLTFKit2 是原生条件候选，其预编译包的附带 libktx 许可尚未闭合，不能整体标成 MIT。

| 候选 | 固定来源与许可 | 已有能力与明确边界 |
| --- | --- | --- |
| A：现有 Online3DViewer | 0.18.0，commit `0473d9befb60975ad1fd3b08e89c9649e647c8ea`；MIT；实际依赖 three 0.176.0 | 已有本地文件、静态模型与 orbit/pan/zoom。其自有 glTF 导入器没有 skin/morph/animation 导入及播放；不能因为底层 three 支持就判定本 App 支持。 |
| B/C：本地 three.js GLTFLoader | 现有 r176，commit `bc58fecba18150103b95fbde5aaa3cc7cddf95a7`；three/loader 为 MIT | 返回 scene/scenes/animations/cameras，支持 SkinnedMesh、morph 与 STEP/LINEAR/CUBICSPLINE 轨道。Floe 仍须接 clip 选择、播放/暂停/seek/循环、镜头与生命周期；它不提供 Floe 的时间轴创作、绑定、权重或 IK 编辑。 |
| B/E：原生 GLTFKit2 | 当前源码 `be89e833aa85bde67bd27d4ecff3b7816c58ce56`；自身和 cgltf 为 MIT；SPM 指向预编译 0.5.15 | 有 SceneKit、RealityKit 桥接及 GLTFAsset 对象模型，源码声明 iOS 平台。资产层保留不等于渲染层保真；README 明确尚不符合全部 glTF 规范。RealityKit morph/morph 动画仍 TODO，骨骼动画采样且 hold 有 TODO；SceneKit cubic 不能保留显式切线。 |

### 当前产品证据

- `FloeAgent/ThirdParty/EngineeringViewers/package-lock.json:676` 固定 O3DV 0.18.0，`:687` 的嵌套 three 是 0.176.0；不要混同 DXF 依赖的另一 three 版本。`README.md:15,29` 明确额外 CDN 解码器未打包、20 MiB/32 引用上限、远端预览仅取选中文件。
- `FloeAgent/FloeApp/Resources/EngineeringViewers/viewer.js:185–201` 调用 EmbeddedViewer，仅有静态查看与 fit，没有动画播放器。`index.html:3` 限制本地脚本/资源，不允许外网 CDN；继续保留这个边界。
- 固定 O3DV 的 `source/engine/import/importergltf.js:265–310` required-extension 白名单仅 Draco、pbrSpecularGlossiness、texture_transform；required meshopt/Basis 不会因 three 版本而自动可用。Draco 动态加载也不等于当前 App 已离线打包。
- `FloeAgent/ThirdParty/EngineeringViewers/build.mjs:11` 只打包现有 mesh-entry，后续拷贝列表没有 Draco/Basis 解码器文件。MIT 主库许可不涵盖尚未选择的解码器资源。

### 解码器必须单列

three 的 [r176 GLTFLoader](https://github.com/mrdoob/three.js/blob/bc58fecba18150103b95fbde5aaa3cc7cddf95a7/examples/jsm/loaders/GLTFLoader.js) 有显式 `setDRACOLoader`、`setKTX2Loader`、`setMeshoptDecoder` 接口。选哪一种才打包哪一种，所有 JS/WASM/worker URL 保持本地。

| 可选依赖 | 已核许可 | 资格限制 |
| --- | --- | --- |
| Draco | Apache-2.0 | r176 README 分 default/glTF 两套编译文件。必须锁实际 JS/WASM、保留 Apache 许可和适用 NOTICE；当前上游 LICENSE 不能证明旧编译件来源。 |
| meshopt decoder | MIT | r176 随带模块有 MIT 头，已保存完整文件并哈希；仍需接入和设备行为验证。 |
| Basis Universal transcoder | Apache-2.0 | r176 README 要求 JS+WASM，两件缺一不可；不是直接加入整包 native libktx。 |
| ktx-parse | MIT | KTX2Loader 静态引入，不能只收 three 的许可证。 |
| zstddec + 内嵌 Zstandard | MIT AND BSD-3-Clause | KTX2Loader 静态引入；保留 wrapper 与 Zstandard 两份声明。 |

这些许可可保留各自声明与 Floe MPL-2.0 代码并存，不需要更换根许可。本包保存了上述固定源码 LICENSE 及 r176 选定 JS 的哈希；尚未选择、下载或验收 Draco/Basis 二进制，因此未给最终二进制 BOM 关闭结论。源文件/纹理资产本身的授权另算。

### GLTFKit2 的附加条款不是推测

[0.5.15 发布页](https://github.com/warrenm/GLTFKit2/releases/tag/0.5.15) 明确预编译包包括 BasisU/KTX2，并将额外许可链接到 KTX-Software。固定仓库内 `GLTFKit2/deps/libktx/VERSION` 是 **v4.2.1**；[其 LICENSE.md](https://github.com/warrenm/GLTFKit2/blob/be89e833aa85bde67bd27d4ecff3b7816c58ce56/GLTFKit2/deps/libktx/LICENSE.md) 指明 `lib/etcdec.cxx` 非开源，采用 Ericsson 限定用途条款。对应 [v4.2.1 CMakeLists:267](https://github.com/KhronosGroup/KTX-Software/blob/170e75893e3d232a2c4f241afe199256f8abb6f9/CMakeLists.txt#L267) 把它放入主源列表；不能套用当前主线可关闭该模块的选项，宣称旧包已排除。

本轮没有下载/检查 XCFramework，不能断言其二进制实际包含或已排除此对象。可以研究的较小范围是 GLTFKit2 自身 MIT 源码 + cgltf，先不链接可选 libktx；需要 KTX2 时再选择许可、构建来源与依赖 BOM 都明确的实现。`Package.swift` 宣告 iOS 12.1，RealityKit 源码有 iOS 15/17/18 与 Swift 6 条件，证明存在平台接入代码；不证明本 App 可编译或在 iPad/iPhone 已验收。

### 只读预览与 CAD 导入必须分开

只读预览应保留原 GLB/glTF 与许可范围内的 sibling 资源，使原始场景仍可再打开；播放导入动画只是查看功能。当前 native `MeshImportKit.swift:817–818` 仅接 TRIANGLES，`:836` 把 world 变换烘焙到顶点，`:872–895` 生成扁平 ImportedPart；部分 PBR/UV/贴图有保留，但原层级、skin、morph、动画并未成为 `.floecad` 权威编辑模型。提高预览保真度不会自动补上无损 CAD 导入、连续编辑或动画导出。

与原计划的关系保留原 ID：X19 场景读取不等于通用可编辑层级；X21 资产相机不等于 Present 多保存镜头；X23 导入 clip 播放不等于 Floe 轨道目标扩展；X26 skin/morph 预览不等于绑定/IK 创作；X29 未补动画格式输出；X32 未补自然语言布光。

后续最小验收需要同一 GLB 的静态/骨骼/morph/STEP/cubic/多镜头与分别压缩 fixtures，离线失败与成功读回、资源越界/缺失/超限、取消释放，以及 iPad/iPhone 实际播放。这里列的是尚未完成的验证，没有把上游能力记成 App 已完成项。

### 查看补评的固定许可指纹

|来源|固定commit／版本|实际许可边界|许可文件SHA256|
|---|---|---|---|
|[Online3DViewer](https://github.com/kovacsv/Online3DViewer/blob/0473d9befb60975ad1fd3b08e89c9649e647c8ea/LICENSE.md)|0473d9befb60975ad1fd3b08e89c9649e647c8ea / 0.18.0|MIT|`0ce9c1b7c467d106c30c0f4d514934912cd61dd252eef8e7b191a93b1a75d606`|
|[three.js local GLTFLoader](https://github.com/mrdoob/three.js/blob/bc58fecba18150103b95fbde5aaa3cc7cddf95a7/LICENSE)|bc58fecba18150103b95fbde5aaa3cc7cddf95a7 / r176 / 0.176.0|MIT (three and GLTFLoader only)|`bfe119ea4fd413f5f7ca3fcd63adb0c4a073ed39daa2fe7d3e6b769e21272601`|
|[GLTFKit2 native adapters](https://github.com/warrenm/GLTFKit2/blob/be89e833aa85bde67bd27d4ecff3b7816c58ce56/LICENSE)|be89e833aa85bde67bd27d4ecff3b7816c58ce56 / 0.5.15|MIT for own source, MIT for cgltf; optional libktx has additional terms|`a6477d7077b9c48c21068196ce3674f272fc7bdfd99e709d06cca1e914a5ee4b`|

### 新视觉核查的原编号映射

- `VISION-01` (X35, X33) / source_confirmed_gap: Animation frame namespace is omitted by providerImageEvidence.
- `VISION-02` (X35) / source_confirmed_contract_gap: Producer allows16MiB while inline consumer allows8MiB per image.
- `VISION-03` (X34, X35) / source_confirmed_route_limit: CAD tool outputs lack the attachment-ingress auxiliary-vision fallback.
- `VISION-04` (X35, M30) / partial_existing_manual_entry: Loose GLB/mesh manual visual review exists; autonomous readonly arbitrary-file observation is not this native capture API.
- `VISION-05` (X35, M30) / domain_workflow_gap: Single-view pixels and sparse mesh context are not a multi-angle measurement/occlusion inspection workflow.
- `VISION-06` (X35, M30) / existing_safety_plus_validation_gap: Capture freshness is guarded locally, but image hash validity is not a guarantee it matches the document at every later model turn.
- `VISION-07` (X33, X34) / known_discovery_model_limit: Global capability summary omits capture/animation although detailed schema and executor have them; local models differ.
- `VISION-08` (X34, X35) / intended_authorization_boundary: Temporary chat is not a supported CAD inspection/edit route despite permissive internal read-only comments.

上列新增项没有运行复现，也没有关闭原验收；具体处理与证据合同见第三节。

## 7. 原106项完整缺口、复用路径与验收表

保留全部原编号和原验收条件。进度针对限定切片，不表示完整App闭环；查看和视觉新发现已映射到原条目。

### A: 正确性基础 (4)

|编号／能力|状态与剩余工作|优先复用路径|原验收条件|
|---|---|---|---|
|M09 部分特征公式不会随变量重算|限定组件已验：已修公式重算遗漏；仍需全FloeApp、多轮工具与实机验证上述特征联动，新增孔Expr另随H1验收。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|为圆角/倒角/抽壳/斜度拉伸分别绑定w/2，改w后几何/查询/公式同步；撤销、保存重开保持一致。|
|M18 面编辑/分割路径丢失解析BRep|限定组件已验：精确平面推拉/法向移动/Split保BRep已验证；精确切向移动、缩放、旋转、径向修改仍拒绝，需逐项成熟内核扩展与App验收。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|精确带孔曲面实体执行每种面编辑/Split，query analyticBRep、体积与STEP曲面类型保持预期；无法保持时明确拒绝或标示转换且可撤销恢复。|
|M19 面旋转角度查询/更新单位冲突|限定组件已验：面旋转创建/查询/更新度弧度合同已修并组件验证；仍需实际UI/工具/重开与设备回归，不据此宣称所有面编辑已支持。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|创建30°面旋转→查询30deg→更新45°→实际几何45°，UI/工具/重开一致，避免重复degree/radian转换。|
|E39 读取包时实际内容完整性与存储身份|限定组件已验：实际document/blob完整性和只读身份已组件验收；仍需全App损坏打开/恢复copy体验，以及H1新schema写入后的当前组合验证。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|保持manifest不变，修改一个仍可解码mesh字节或移走brep后，storedIdentity必须拒绝或显式报告corrupt；只读打开保留证据并可恢复previous，不能把声明摘要当复验结果。|

### B: 关联事务与版本 (14)

|编号／能力|状态与剩余工作|优先复用路径|原验收条件|
|---|---|---|---|
|M05 外部几何投影与关联|缺口待实施：把外部投影从静态线段改为可解析源边/面的关联引用，验证源变更、删除、重选与解除关联。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|投影选定实体边为外部引用，源尺寸变更后同步，源删除显示断引用，能明确断开关联。|
|M07 持久化关联基准面|进行中：关联偏移面/草图支撑已验证；仍需角度面、三点面等定义及其关联、UI/AI/重开验收，不能把offset切片视作全部Datum。|既有Floe服务／事务；OpenShape新增MIT基准构造切片（关联层自接）|偏移/夹角/三点基准面保存引用和参数；修改父几何后平面及下游草图随动，断引用明确失效。|
|M08 关联基准轴与基准点|缺口待实施：补持久化关联轴/点与可编辑来源定义，使旋转和阵列引用构造轴/点并随源变化重建。|既有Floe服务／事务；OpenShape新增MIT基准构造切片（关联层自接）|由面/边/两点/两平面创建关联轴和基准点，能复选来源、改偏移并驱动旋转/阵列，重开关系不丢。|
|M10 变量扇出事务、类型单位与配置|部分切片已验：变量扇出单事务已验证；仍缺长度/角度/无量纲类型、维度分析、命名配置及设计表。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|一次改变量以一个文档事务更新所有依赖；失败恢复一致；可区分长度/角度变量，命名配置作为后续可选扩展验收。|
|M11 LLM变量与公式编辑入口|限定组件已验：变量CRUD/公式绑定服务和工具合同已验证；仍需真实LLM多轮与全App/设备链路，孔公式新增入口尚待H1运行。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|LLM创建width变量、把拉伸/孔径绑定width表达式、再改width，全程通过同一命令服务和undo，不拼包JSON。|
|M14 拉伸终止条件关联|缺口待实施：一般extrude仍需持久化throughAll/upToNext与目标关系并随动；H1专用throughAll孔源码不能算一般拉伸终止关系已完成。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|创建throughAll切除后把板厚改大，孔仍贯穿；upToNext目标面移动后拉伸自动跟随，重开保持定义。|
|M26 依赖编辑、稳定拓扑与恢复验收|部分切片已验：依赖检查和偏移面有限命名切片已验证；仍需任意曲面、相似重复面、分裂合并/消失面及旧包升级的稳定拓扑矩阵。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|变更上游尺寸/分裂/删面后下游只能命中原意图或明确失效；绝不绑定相似面；撤销/重开恢复同ID。|
|E32 原子保存与修订并发保护|部分切片已验：已有CAS/格式/原子写与成功receipt切片验证；仍需全App中断/外部改包恢复交互及未验证H1 format3组合回归。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|保存中断/外部提交/关闭竞态后至少一完整版本可打开，失败草稿可恢复且不覆盖较新文件。|
|E33 损坏包恢复与诊断交互|部分切片已验：缺manifest恢复及原字节保留已硬化；当前document损坏仍需用户可选previous预览/差异/恢复到新包的完整交互。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|破坏当前document.json后可预览并恢复previous到新包，原损坏包保留，报告未恢复字段。|
|E34 撤销历史与设计版本|缺口待实施：补用户命名设计版本、版本比较/恢复与跨会话undo明确边界；内存undo和previous快照不是版本系统。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|用户可创建设计版本并比较/恢复到新分支；明确跨会话undo能力边界。|
|E35 冲突合并与多端协作|缺口待实施：在现有CAS拒覆盖和导入合并之上补CAD版本比较、独立改动显式合并与冲突可视选择；不计划自动实时协同。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|两个副本分别改独立特征，能比较并显式合并，冲突不会静默选一方。|
|E36 Canvas可编辑包备份恢复|缺口待实施：当前App验证完整含材质/动画/装配/工程图包备份→删原Canvas→恢复及继续编辑，不能只验证PNG/身份绑定。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|备份含装配材质动画图纸工程，删除原Canvas后恢复，所有源资源与编辑操作正常。|
|E37 关闭后台保存与长任务所有权|部分切片已验：保存代次/receipt/预览取消等有限生命周期已验证；仍需全App后台/锁屏/强退/关闭与长任务、大文件性能组合验收。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|导出/保存中切后台、关闭与重开，任务归属和数据恢复正确，旧回调不复活已删文档。|
|X36 Canvas统一来源与遗留迁移|缺口待实施：本轮只有源码证据；迁移拒绝、取消、冲突、缺预览及重复打开等用户流程仍需对当前App构建验收。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|旧节点迁移保留ID与连接、失败不破坏原件、重复编辑同一包；新节点AI和手动打开同一来源。|

### C: 机械建模 (18)

|编号／能力|状态与剩余工作|优先复用路径|原验收条件|
|---|---|---|---|
|M01 实体种类与持续编辑|缺口待实施：补齐弧、椭圆、多边形、样条按原ID持续修改及删除/修剪/偏移/镜像工具，保留约束与失败回滚。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|同一轮廓中修改弧角、椭圆轴、样条点并删除指定实体；保留其余ID/约束，失败不留半次修改，撤销与重开一致。|
|M02 曲线约束与求解范围|缺口待实施：扩展样条内部控制与曲率/切向约束、弧端焊接，验证闭合曲线改尺寸后的DOF和连续性。|既有Floe服务／事务；仅资格PlaneGCS的LGPL闭包，不选GPL libslvs|用样条与弧构成闭合截面，约束连接与切向后修改尺寸，轮廓不裂开，显示正确剩余DOF与失败原因。|
|M03 修剪与延伸|缺口待实施：补椭圆/样条精确修剪、延伸及引用/约束映射，不能把离散交点或2D编辑能力当作3D闭环。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|修剪/延伸圆弧、椭圆、样条至选定边界，保持精确曲线和明确ID映射，不静默删除约束。|
|M04 精确偏移|缺口待实施：用成熟精确曲线后端补椭圆/样条等距偏移和持久关联，量测法向误差及自交/塌缩拒绝。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|椭圆/样条偏移沿法线保持设定距离，并能随源曲线变化，失效时报告自交/塌缩。|
|M06 求解诊断与尺度一致性|缺口待实施：做跨10^-3/1/10^3尺度、角长混合与大型草图求解诊断/性能矩阵，修正经复现的归一化缺口。|既有Floe服务／事务；仅资格PlaneGCS的LGPL闭包，不选GPL libslvs|同一草图按10^-3/1/10^3缩放后约束状态一致；冲突高亮对应实际约束，不把最佳拟合写成满足结果。|
|M12 孔的机械语义|源码就绪未编译：H1四类HoleSpec/feature.hole/UI/format3已写，立即做真实Swift6编译、16语义测试及孔面命名/方向/撤销/重开验收；再补钻尖、盲沉孔等专业范围。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|创建通孔/盲孔/沉孔/锥沉孔后保留同一孔ID，修改孔型、直径、位置与深度；源面改变后依赖正确重建。|
|M13 标准螺纹与持续编辑|仅预研：先运行私有8项现有精确螺旋/布尔探针，再决定Thread规格/牙型/旋向/配合/端部/持续编辑；当前无标准螺纹产品实现。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|标准内外螺纹有规格、螺距、旋向、有效长、端部策略；选择已有螺纹改规格，几何/示意模式可区分并能复读。|
|M15 扫掠路径和螺旋参数|缺口待实施：补关联曲线/边路径、更换路径及螺距/圈数/扭转可编辑服务，验证同一sweep重建、失败回滚和重开。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|选择原路径改点或替换边后同一sweep随动，能改螺距/圈数，失败保留原实体与引用。|
|M16 放样精确性和编辑|仅预研：先资格验证已捆绑OCCT的多截面+单辅助轨扫掠，再做截面重排/内环精确等级；任意多轨Gordon和端部G1/G2仍未接入。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|编辑/重排截面与导轨并保留同一特征ID；带内环放样保持明确精确等级；起止切向/曲率约束可量化检查。|
|M17 独立曲面特征工作流|仅预研：建立独立surface类型与开放放样/扫掠/补面/修剪/缝合/加厚历史，先验证成熟OCCT组合及格式隔离；readiness不是实现。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|独立开放截面放样成surface，修剪/补面/缝合后检查闭合，再按厚度生成精确实体；各步可撤销重开重建。|
|M20 圆柱面径向编辑|缺口待实施：实现可重放的圆柱径向参数特征及导入解析圆柱改径；当前cylinderRadial仍明确拒绝，H1改定位圆不替代该能力。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|选择已有圆柱孔壁改直径，保存为可重放径向offset/参数特征；无草图导入件亦保留BRep和撤销。|
|M21 圆角倒角范围与部分选边|缺口待实施：先明确逐边处理/拒绝清单，再补变半径圆角、两距离/角度倒角与高级拐角，验凹边和精确等级。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|多边圆角明确列全部处理/拒绝的边；支持所需两距离倒角/变半径作为扩展，凹边行为与精确等级清楚。|
|M22 抽壳开口与复杂壁厚|缺口待实施：补非平面开口抽壳及多区域壁厚；独立曲面加厚另验，不把现有单厚度实体shell当作完整覆盖。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|在曲面开口抽壳并量测壁厚，失效时保留原体；开口选择/厚度更新可重建重开。|
|M23 拔模与替换面的目标关联|缺口待实施：把拔模中性面、替换面目标从坐标升级为稳定关联引用，验证目标移动及断引用反馈。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|源面与目标/中性面都保存稳定引用，移动目标后同特征更新，断引用明确提示。|
|M24 Split与工具历史完整性|缺口待实施：补持久化Split特征、刀具引用、AI入口与结果ID重建；已有精确Split几何修复不等于Split历史完成。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|Split保留刀具/目标引用与结果ID；改刀具位置或源尺寸重建两体正确，重开后可继续编辑。|
|M25 关联定义与类型边界|缺口待实施：让阵列轴/中心、镜像面引用关联基准并可改，补种子拆分映射及沿曲线/特征级阵列。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|镜像/阵列引用关联基准，改轴/平面或源孔参数后各实例更新，种子拆分有明确关联映射。|
|M27 目录/内核工具到生产入口|缺口待实施：把wrap/offsetFace/offsetEdge等保留目标接到真实UI/Agent/撤销/重开，或从可用能力中如实隐藏未接入项。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|能力发现只宣称实际可执行路径；若保留wrap/offset工具目标，则在UI和Agent都能执行、撤销、重开。|
|M28 精确/网格布尔边界与性能验收|缺口待实施：验证精确/网格混合布尔等级、封闭性、50k三角边界与取消/耗时/内存；失败不得留半体或默默降级。|既有Floe服务／事务；Manifold（流形网格布尔与简化）|精确、mesh及混合对象布尔明确结果精确等级；失败/取消不留半体，重型对象可安全拒绝并说明。|

### D: 装配与工程图 (18)

|编号／能力|状态与剩余工作|优先复用路径|原验收条件|
|---|---|---|---|
|E01 子装配与外部零件引用|缺口待实施：补子装配层级和外部零件/版本引用、显式更新与缺引用诊断，保持配合/BOM身份。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|外部零件修改后显式更新两个子装配，保持实例、配合、BOM与缺失引用诊断。|
|E02 共享实例与独立副本|缺口待实施：对共享实例跟源、独立副本隔离和爆炸后基础放置做当前App→保存重开验收；不是从零实现实例。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|同源两实例随源更新，独立副本保持原样；爆炸预览后保存重开基础放置不变。|
|E03 配合类型与机械关节|缺口待实施：补铰链/滑块、行程限位及齿轮/齿条/螺旋等机械配合模型，验证拖动和重开约束。|既有Floe服务／事务；独立OndselSolver（LGPL，iOS待验）|创建铰链或滑块并设限位，拖动/参数修改和重开后仍保持机构约束。|
|E04 配合参考随零件几何变化关联|缺口待实施：把配合point/direction快照升级为持续可解析面/边身份，源变更自动跟随，歧义明确要求重选。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|改孔中心和基准面后，同轴/对齐配合跟随正确几何；歧义时明确要求重选。|
|E05 编辑已有配合参数|缺口待实施：新增保持ConstraintID的距离/角度/参考更新命令及UI/AI，验证单步撤销和持久化。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|将已有距离10改15并undo/redo，约束ID和引用不变，保存重开仍15。|
|E06 求解自由度与失败回滚|缺口待实施：验证复杂闭环/冗余约束和64实例/128约束边界，矛盾时几何、undo、文件不变且DOF诊断可信。|既有Floe服务／事务；独立OndselSolver（LGPL，iOS待验）|矛盾约束后几何、undo、文件不变；解除冲突后求解与自由度诊断一致。|
|E07 大装配与分组干涉检查|缺口待实施：补干涉实例子集/分组、进度与取消，突破全体配对32对限制并拒绝陈旧结果。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）；FCL collision / distance|按选中组件检查50实例中的指定子集，可取消并显示进度，代次变化拒绝旧结果。|
|E08 网格干涉精度与接触间隙|缺口待实施：复用成熟碰撞/距离后端补网格三角级碰撞、真实间隙和接触语义，避免把AABB当实体相交。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）；FCL collision / distance|中空嵌套网格不误判实体相交，报告真实最小距离并明确精度和单位。|
|E09 命名爆炸视图与BOM气泡|缺口待实施：完成两个命名爆炸视图→BOM/气泡→向量导出→重开的当前UI/AI整链验收。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|保存两个命名爆炸视图，对应BOM及气泡导出后数量和实例一致，重开仍可继续编辑。|
|E11 同页多视图和投影关联布局|缺口待实施：补同一图纸多view模型、投影对齐与拖动布局，改模型后全视图关联更新。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|A3同页布置正/俯/侧/剖视图，比例和投影对齐可编辑，改模型后更新全部视图。|
|E12 精确投影和隐藏线|缺口待实施：复用成熟BRep隐藏线/投影算法，补可见性分类与隐藏线型并与独立CAD逐线对照。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|对带遮挡内孔和曲面的模型，与独立CAD精确投影逐线对照，可切换隐藏线显示。|
|E13 网格实体剖视图|缺口待实施：补mesh剖切或在输出前阻止不完整混合剖面被当完整图纸交付，明确精度与缺失对象。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|含BRep与mesh混合总成出完整剖视，或出图前阻止把不完整剖面当完整图纸。|
|E14 剖面填充与复杂剖切类型|缺口待实施：补材料剖面线、阶梯/旋转/局部剖及断裂视图参数与标记关联，验证向量导出。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|双材料装配剖面具有可配置不同剖面线，阶梯切线与剖视标记同步保存导出。|
|E15 尺寸对上游几何的持续关联|缺口待实施：尺寸绑定改为特征/边/面语义并自动重测，源孔改径/删除时更新或明确悬空。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|Ø10改Ø8后同一尺寸自动显示Ø8；孔删除后明确悬空，不保留看似有效旧值。|
|E16 制造标注语义|缺口待实施：补结构化尺寸公差/配合、GD&T基准框、粗糙度、焊接与螺纹/沉孔标注，联动源并验证PDF/DXF符号。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|建立M6螺纹孔标注、尺寸公差和基准框，改源特征后关联更新，PDF/DXF保留符号。|
|E17 BOM工程属性与多级结构|缺口待实施：补材料/密度质量/规格/版本/供应属性及多级BOM，实例共享属性与数量更新后可导出。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|同一零件各实例共享料号/材料，独立件可分配版本，多级BOM更新数量并导出表格。|
|E18 图框模板与文档规范|缺口待实施：补可复用公司图框、修订栏、投影法、单位精度和样式模板，验证多图纸重开/导出一致。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|应用同一模板到多张图，修改修订栏/精度后保存重开和PDF/DXF一致。|
|E19 向量交付与图纸持久化|缺口待实施：对已有PDF/SVG/DXF输出做独立阅读器比例、中文符号、尺寸/BOM和跨版本可编辑重开验收。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|外部PDF/DXF阅读器读回尺寸比例及中文/符号，重开原包可继续编辑同一标注。|

### E: 二维CAD与交换 (12)

|编号／能力|状态与剩余工作|优先复用路径|原验收条件|
|---|---|---|---|
|E20 可编辑实体覆盖|缺口待实施：扩2D可编辑Spline/块内/纸空间/Hatch/MTEXT等范围，未支持Xref/代理/3D实体须原样保留并明确只读。|既有Floe服务／事务；现有MPL acadrust；MIT ezdxf仅外部DXF选项|打开含块/Xref/样条/填充图纸，支持范围内编辑并保存，其余实体保持且UI清楚标记只读。|
|E21 修剪延伸偏移与OCS|缺口待实施：补闭合bulge轮廓、样条、非默认OCS的trim/extend/offset，验证方向/拓扑/undo与同格式复读。|既有Floe服务／事务；现有MPL acadrust；MIT ezdxf仅外部DXF选项|对带bulge闭合轮廓偏移和修剪，原拓扑及方向正确，undo和同格式复读一致。|
|E22 尺寸引线后续编辑与语义关联|缺口待实施：为已有Dimension/Leader补保持句柄的文字、位置和几何关联更新接口，验证持续编辑。|既有Floe服务／事务；现有MPL acadrust；MIT ezdxf仅外部DXF选项|更新已有尺寸文字/位置并修改关联几何，保留句柄与标注关系，保存后同格式可继续编辑。|
|E23 DWG兼容和保真拒绝|缺口待实施：维护真实第三方DWG/DXF保真矩阵与独立CAD复读；拒写必须保留原件并提供可恢复草稿交付。|既有Floe服务／事务；现有MPL acadrust；MIT ezdxf仅外部DXF选项|覆盖真实含字体、布局、对象、Xref样例，成功者由独立CAD复读；失败者原件不变且草稿可导出恢复。|
|E24 STEP与精确实体保真|缺口待实施：STEP导出前给出BRep/mesh覆盖清单，独立CAD核验体数/解析曲面/单位；装配/PMI/特征历史不能冒充已保留。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|混合BRep/mesh文档导出前展示覆盖清单；独立CAD读回实体数/解析曲面/单位，明确未携带历史。|
|E25 装配实例和场景交换导出|缺口待实施：增加消费展开装配实例的交换导出路径，验证同源多实例数、世界放置和可用层级，不只导document.bodies。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|同源3个已放置实例导出后独立查看器对象数与世界位置一致；可选择零件/装配并保可用层级。|
|E26 IGES曲面交换|缺口待实施：补开放IGES曲面的可编辑链与导出，或在导入前明确render-only；不能把已有实体导入当曲面工作流。|既有Floe服务／事务；现有OCCT 7.8.1（新API组合仍待验）|带开放曲面的IGES可作为可编辑曲面处理并导回，或在导入前明确render-only限制。|
|E27 网格/Blender/USD导入语义|缺口待实施：明确静态mesh与完整场景/动画/skin/morph读取边界；原生GLTF导入会烘焙层级成parts，补required-extension/sparse/primitive子集诊断与适用完整资产读回。|既有Floe服务／事务；ufbx|导入前列出可保留/丢弃项，复杂场景的对象位置与材质通过独立比较，未支持数据保持源文件。|
|E28 UI与AI导入格式及资源一致性|缺口待实施：统一普通附件/输出卡/文件页/工作区/IDE查看分派，分别处理本地siblings、远端/分开发送资源与AI导入限制；USDZ/blend和非默认格式不能从识别表推定成功。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|同一授权文件组经UI与AI导入结果一致；不支持时返回实际缺资源而非静默少件。|
|E29 OBJ和USDZ材质贴图保真|部分切片已验：USDZ每body PBR/六贴图/UV/世界单位已有17项组件验收；仍缺OBJ vt/MTL、逐面/装配交换、跨renderer外观及全App/实机。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|使用带UV及六贴图模型分别导出，独立查看器核对映射和材质，未支持属性在保存前提示。|
|E30 单位坐标约定与无单位资产|缺口待实施：统一UI/AI对无单位OBJ/STL的显式单位选择，验证2mm零件和2m扫描；USDZ单位已修不能抵消导入1000倍差异。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|2mm零件和2m扫描均用明确单位导入，AI/手工/导出复读尺寸保持一致。|
|E31 导入计算取消与内存预算|缺口待实施：补ZIP/Blend/STEP统一解压/三角/内存预算与协作取消，做超限拒绝、无半提交和峰值内存实测。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|导入超预算压缩资产前拒绝并保留源；可取消且不留下半模型，测定设备内存峰值和UI响应。|

### F: 网格材质与场景 (24)

|编号／能力|状态与剩余工作|优先复用路径|原验收条件|
|---|---|---|---|
|X01 顶点边面拓扑编辑|缺口待实施：完整服务分派与特征类型中无可编辑多边形拓扑、边环/环切、Inset、顶点焊接选择和面挤出工作流。|既有Floe服务／事务；OpenMesh（半边网格/简化/细分）|建立稳定顶点/边/面ID，创建→选面挤出→环切→撤销→保存重开后继续编辑。|
|X02 细分曲面和非破坏修改器|缺口待实施：没有网格Subdivision/Mirror/Bevel等可重排修改器栈及控制笼。 原始修改器验收未明确可视程序化几何节点；ShapeScript文本脚本不等同节点编辑。可视节点列为X02候选子范围，需单独定义节点图/求值/资源/保存/UI与Agent验收后再纳入，当前不新增ID或实施。|既有Floe服务／事务；OpenSubdiv（细分曲面求值）|控制笼与最终网格分离，修改器开关/顺序及保存重开结果一致。|
|X03 重拓扑与体素重建|缺口待实施：服务路由无体素remesh、四边面重拓扑、表面投射编辑。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|用含坏边/非均匀密度扫描网格验证重建、法线、偏差、撤销及重开。|
|X04 雕刻与多分辨率|缺口待实施：网格动作与FeatureGraph均无雕刻笔刷、遮罩、多分辨率细分。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|笔压雕刻→平滑→遮罩→多级细分→撤销→离线保存重开。|
|X05 修复语义|缺口待实施：没有证据表明repair会自动补洞、修复自相交或把非流形变为封闭可制造实体。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|对开洞、自相交、反面、非流形分别检测、修复或明确拒绝，复测剩余缺陷。|
|X06 简化误差和外观保持|缺口待实施：没有几何偏差上界、边界/锐边/UV接缝/逐面材质保真目标；比例是目标而非保证。|既有Floe服务／事务；meshoptimizer（网格简化/优化）|薄壁带孔贴图模型简化后报告距离/体积/边界偏差，并校验材质接缝。|
|X07 文字转网格能力发现|缺口待实施：摘要及详细catalog均仍暴露text；详细页还称可创建文本mesh，执行器固定拒绝。应明确不可用，并给实际可发现的TextSketch→extrude替代链或实现真实动作。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|capabilities明确不可用/替代命令，模型通过文字草图→挤出产生可重开实体。|
|X08 重网格操作的主线程与取消|缺口待实施：未证明这些同步CPU循环能让UI/任务取消及时响应；截止时间不等于用户取消。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|近上限网格执行布尔/简化时测主线程停顿；用户取消/换任务后不提交迟到结果。|
|X09 UV展开和岛编辑|缺口待实施：没有接缝标记、自动展开、UV岛选择/打包/多UV集编辑。|既有Floe服务／事务；xatlas（自动 UV 展开与图集打包）|复杂曲面标缝→展开→编辑岛→贴图检查→导出与重开保持UV。|
|X10 纹理绘制和烘焙|缺口待实施：没有3D笔刷绘制、纹理图层、法线/AO/高低模烘焙服务。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|局部绘制→撤销→烘焙→重开与交换格式一致。|
|X11 高级材质与节点图|缺口待实施：没有材质节点图、位移/厚度/透射折射/各向异性等通用参数模型。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|新增每类材质参数均完成UI/LLM、预览、保存和目标格式保真或降级说明。|
|X12 贴图格式与容量|缺口待实施：没有EXR/HDR/KTX/UDIM或高位深贴图工作流；大纹理会被明确拒绝。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|多张大图导入应给明确转码选择、内存预算和回读外观，避免静默丢图。|
|X13 不同贴图垂直方向|缺口待实施：同材质仍共用一套UV，色彩图方向被用于全部贴图，混合方向没有逐图校正。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|同一材质用相反方向色彩/法线图，预览/Present/GLB采样位置一致。|
|X14 逐面独立UV映射|缺口待实施：Present逐面组仍优先mesh.renderTexcoords/texcoords，无UV时才生成面mapping投影。需明确优先规则并修正/验证已有UV情况下独立面投影、尺度、方向，在Edit/Present/GLB一致。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|同体两面设置不同投影/尺度，已有mesh UV和无UV两组均验证Edit/Present/GLB一致。|
|X15 材质库关联更新|缺口待实施：可选链接/共享材质模式仍缺，需明确链接/独立副本、批改、撤销重开语义；装配实例按源body共享材质的现有目标规则不等同通用链接库。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|若引入链接材质，明确区分链接/独立副本，批量更新及撤销重开可预期。|
|X16 HDRI环境工作流|缺口待实施：生成环境仅256×128八位RGB渐变；没有导入HDRI、旋转、独立反射/背景/曝光设置的正式模型。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|本地HDRI导入→旋转/强度→保存重开→截图/视频一致，资源丢失明确提示。|
|X17 自由多灯编辑|缺口待实施：灯不是可独立命名/定位/调色/开关/动画的场景对象；没有点光/聚光/面积灯编辑模型。|既有Floe服务／事务；既有Floe服务与平台API（新能力仍须接合）|创建多个灯、调整位置颜色强度并命名，UI/LLM、撤销、保存和动画产物一致。|
|X19 通用场景对象与层级|缺口待实施：缺通用可编辑场景图；只读完整资产查看另需保留层级/实例/镜头，不能把O3DV或原生扁平parts当作已完成。|既有Floe服务／事务；既有Floe服务与平台API（新能力仍须接合）|场景对象稳定ID/父子变换/资源引用及UI、AI命令共用同一保存权威。|
|X20 Present中直接选体选面|部分切片已验：placed face目前按instance选择，仍需instance-face语义；实际face/instance触控、完整FloeApp/实体设备、复杂大场景性能与渲染保真仍待验。无可信映射只选body，不捏造kernel face。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|Present点选体/面→材质预览→应用→AI读取同一选择，换模式仍保持可验证目标。|
|X21 正交展示与多个保存镜头|缺口待实施：没有Present正交相机、独立命名镜头集合或物理焦距/景深模型。|既有Floe服务／事务；既有Floe服务与平台API（新能力仍须接合）|保存正交和透视镜头、切换/改名并重开，导出保持选定投影与画幅。|
|X22 剖切和注记的展示导出一致性|缺口待实施：同一文档在Edit截图和Present/动画输出可能呈现不同剖切/注记范围，应给清楚模式语义。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|剖切/测量注记模型分别截图和导出，明确可导出内容或提供对应开关。|
|X32 环境灯光编辑工具链|缺口待实施：公共cad.document/typed mutation仍无环境/灯方向强度设置操作；需UI/LLM同一环境事务及预览、undo、save/reopen、capture验收。|既有Floe服务／事务；既有Floe服务与平台API（新能力仍须接合）|同一环境命令供UI与LLM使用，预览/授权/undo/save/reopen/capture完整一致。|
|X33 能力摘要与详细catalog一致性|缺口待实施：统一旧global catalog与详细分派/格式真实子集；package_schema_version1落后已验schema2和未编译H1schema3，GLB always works/文字网格等宣称需收窄，增加查看/视觉观察分层。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|从唯一catalog派生摘要，逐项比对真实executor和schema，不列必拒动作。|
|X34 本地模型能力分层|缺口待实施：按具体模型/vision override/工具能力区别MLX、Foundation及已配置辅助视觉；CAD工具产物尚未复用附件式辅助路线，image.inspect命名空间也不覆盖CAD产物；禁止默认换模型或转云。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|分别用工具型MLX与Foundation实测功能可达，UI明确模型能力，不伪造执行或视觉能力。|

### G: 动画出片与整链体验 (12)

|编号／能力|状态与剩余工作|优先复用路径|原验收条件|
|---|---|---|---|
|X23 轨道目标范围|缺口待实施：普通body直接轨道、scale、材质/灯光/visibility/特征参数通道，以及各通道持久化/基线隔离/导出一致性。|既有Floe服务／事务；既有Floe服务与平台API（新能力仍须接合）|各新增轨道值持久化、求值不改基线、撤销重开及导出帧一致。|
|X24 曲线插值与镜头运动控制|缺口待实施：Bezier/F-curve切线、路径/约束、速度曲线、NLA/clip混合；曲线可视编辑到导出逐帧一致性。|既有Floe服务／事务；既有Floe服务与平台API（新能力仍须接合）|曲线编辑→数值求值→时间线预览→导出逐帧位置与时间一致。|
|X25 关键帧服务与可视编辑覆盖|缺口待实施：轨道行和键帧点选择/移动/删除、实例录帧、插值选择、完整clip可视编辑；UI与AI编辑同一数据后撤销重开。|既有Floe服务／事务；既有Floe服务与平台API（新能力仍须接合）|UI手动创建零件轨道、移动删除键帧、选插值，AI查询同一数据并可再编辑。|
|X26 骨骼绑定与形变|缺口待实施：骨骼/权重/IK/shape-key编辑与持久形变求值未完成；还缺GLB/glTF/FBX的skin/morph/clip查看，播放与创作分别验收。|既有Floe服务／事务；ozz-animation；ufbx|引入骨骼/权重/形变文档模型后验证绑定编辑、求值和目标格式动画输出。|
|X27 物理仿真和粒子|缺口待实施：可编辑刚体运动/接触仿真、粒子、布料/软体/流体参数及缓存、确定性回放/取消/输出。|既有Floe服务／事务；既有Floe服务与平台API（新能力仍须接合）；Jolt Physics|选择仿真范围后保存物理参数/缓存，确定性回放、取消和离线导出。|
|X28 视频导出设置UI|缺口待实施：UI设置分辨率/横竖屏/fps/codec/bitrate入口，并实际媒体读回核对用户所选设置。|既有Floe服务／事务；既有Floe服务与平台API（新能力仍须接合）|UI选竖屏/分辨率/帧率/codec→导出后媒体读回核对实际参数。|
|X29 多媒体输出范围|缺口待实施：补音轨/透明视频/帧序列及动画资产交换合同；现有原生GLBExporter只写bodies静态网格，不因已有Floe动画服务而保留clip/skin/morph。|既有Floe服务／事务；既有Floe服务与平台API（新能力仍须接合）；ufbx|明确输出类型后读回轨道/Alpha/帧序列，保证时间同步和取消清理。|
|X30 后台与长动画恢复|缺口待实施：后台/锁屏继续策略、持久化中断状态与帧checkpoint、断点续出；前后台/源变更下回执一致性实测。|既有Floe服务／事务；既有Floe服务与平台API（新能力仍须接合）|明确前台限制并保留可恢复任务信息；前后台/文档编辑时结果和回执一致。|
|X31 大场景省略与产物完整性|缺口待实施：输出回执需包含renderer及animation-evaluation问题；文件查看/导入还应报告缺纹理、未支持扩展/primitive和资源省略，不把有效图片/媒体文件当完整模型。|既有Floe服务／事务；既有Floe服务与平台API（新能力仍须接合）|超限/无效mesh/缺纹理场景导出必须阻止或明确带完整性警告，并独立逐体核对。|
|X35 视觉反馈与长结果闭环验收|缺口待实施：静态capture→PNG→视觉payload及人工mesh review已有源码；修动画目录白名单和16MiB产物/8MiB内联合同，补任意文件只读自主多角度/目标/时间/版本观察及真实模型多轮纠正。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|真实模型完成创建→指定已有孔改径→看图修正→撤销→重开继续，长query分页和非视觉降级分别验证。|
|X37 iPad Pencil与紧凑界面验收|缺口待实施：实体iPad Pencil/悬停/系统取消、分屏大字/VoiceOver、iPhone复杂面板仍需产品验收。原生组件/模拟器证据不等于完整App或实体设备。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|同一代表模型在iPad Pencil/触控、iPhone竖屏、分屏大字完成选择→修改→撤销→保存，保留截图和失败。|
|M30 机械CAD整链实机/LLM验收空白|进行中：已有有限组件工作台/触控/保存/Present证据；仍需新目标的完整App/实际选定模型“观察→query/measure→改同一ID→新图→撤销/重开”与iPad/iPhone、独立格式读回。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|对孔/螺纹/曲面/基准等目标分别验证UI选中→LLM读/改→同服务事务→上游重建→保存重开→STEP/量测独立复读，保留失败与截图。|

### H: 专业制造与计算 (4)

|编号／能力|状态与剩余工作|优先复用路径|原验收条件|
|---|---|---|---|
|M29 钣金/焊件/齿轮与专用工具|缺口待实施：分别以成熟后端补钣金展开/K系数、焊件型材切割清单、齿轮特征与可编辑持久化，先过许可和平台资格门槛。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|仅在确定产品范围后定义可验收专业场景，例如带折弯半径的钣金件与展开尺寸一致、保存重开可改。|
|E10 机构运动分析和动力学|缺口待实施：引入成熟机构/动力学后端做配合驱动、接触、行程、运动包络与载荷分析；关键帧动画不替代机械求解。|既有Floe服务／事务；独立OndselSolver（LGPL，iOS待验）；Project Chrono core / mechanisms|驱动一个关节，其他零件由约束求解运动，能检查行程和干涉。|
|E38 CAE CAM制造分析|缺口待实施：按已选范围资格验证成熟CAE/CFD/多物理及多轴车铣CAM后端，完成材料/载荷/边界条件或刀具/刀路/加工仿真；不含机床专属G-code。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|若选入范围，明确材料/载荷/边界条件或刀具/机床契约，并用独立求解器/机床仿真验证。|
|X18 离线高质量渲染和后期|缺口待实施：离线路径追踪、采样/降噪、物理景深、渲染通道、合成后期仍无已实施生产链；该专业扩展仍需独立可行性与验收，当前只计实时renderer。|既有Floe服务／事务；无已选定的新引擎，保留后文条件候选|选定质量级别后，确定曝光色彩/采样、取消和输出保真；另行测设备资源。|

## 8. 完整复用决策与许可证原则

目标是为原106项缺口选择可复用的成熟组件和可审计的小范围源码，不引入第二套几何内核、文档模型或执行框架。项目根许可证仍为MPL-2.0；本次不修改许可证、依赖锁或发布方式。

本报告区分“许可允许”“源码可构建线索”“本项目设备／模拟器编译”“功能运行”和“实际分发合规”。新候选本轮没有构建或运行，固定版本及许可证哈希只证明所查源码的来源。

### 复用方式

|方式|适用情况|采用原则|
|---|---|---|
|复用现有组件|已集成OCCT、OpenShape3D来源代码、Euclid、ShapeScript及系统框架|先扩现有桥接和服务；不要为已有功能引入新引擎。已集成不表示所有未暴露API都已验收。|
|链接独立库|边界明确的UV、细分、简化、动画求值或物理算法|优先保持上游独立库边界，固定版本及所选模块，避免复制零散文件后失去更新与依赖信息。|
|挑取小范围源码|独立且许可证清楚的算法、原生控件或适配器|逐文件保留版权／许可证、来源commit、修改记录及所需依赖；不能凭仓库主许可证推断全部子目录相同。|
|独立外部工具|重型桌面CAD、离线渲染、CAE／CFD／CAM|只作为明确的选定外部环境方案；不算纯本地iOS能力，也不因使用子进程就自动免除许可义务。|
|暂不直接引入|强copyleft与当前分发路线不符、许可证或依赖未闭合、桌面编辑器移植成本过大|保留候选和原因，不能改头换面把来源代码标为MPL。|

### 许可证判断边界

1. **MIT／BSD／Apache不是“拿来后删掉许可”。** 保留版权、许可文本与适用声明。Apache-2.0还需标明修改，并保留原有适用NOTICE；各候选的依赖和资产另查。[Apache-2.0原文](https://www.apache.org/licenses/LICENSE-2.0)
2. **MPL按文件保护。** 本项目自身受MPL覆盖文件的义务继续适用。MPL第3.3节在特定条件下允许Secondary License组合，因此不能笼统说“GPL与MPL绝对不能组合”；但那不等于可以维持当前发布方式而随意混入GPL编辑器代码。[MPL-2.0原文](https://www.mozilla.org/en-US/MPL/2.0/)
3. **LGPL可以有条件链接。** 静态链接不是自动禁止，但须按实际库版本和分发组合落实源码、修改声明和重新链接等适用条件。现有OCCT例外针对特定头文件生成的对象代码，不是对整个LGPL的豁免，更不能套用到其他库。[固定OCCT 7.8.1所附LGPL文本](https://github.com/Open-Cascade-SAS/OCCT/blob/bd2a789f15235755ce4d1a3b07379a2e062fdc2e/LICENSE_LGPL_21.txt)、[OCCT例外](https://github.com/Open-Cascade-SAS/OCCT/blob/bd2a789f15235755ce4d1a3b07379a2e062fdc2e/OCCT_LGPL_EXCEPTION.txt)
4. **少量复制和语言翻译也需检查来源许可。** “只拿几段”“改成Swift”或让AI按原实现翻译都不是自动免责条件。优先链接成熟库，必要的源码提取建立逐文件出处及修改记录。
5. **代码、依赖、数据分别核对。** 字体、HDRI、模型、示例动作和标准尺寸表不能从代码仓库许可证直接推断可用。标准名称支持也不等于获准复制某份标准出版物的数据。

现有OCCT已经记录静态库来源、源码和relink路线，见[本仓库记录](../FloeAgent/ThirdParty/FloeCADKit/OCCT_RELINK.md)；该记录也明确未声称完成独立重建或法律认证。本次不将它扩展为对新库／所有发布渠道的合规结论。

### 产品层仍需完成的工作

成熟算法能减少几何与数值实现，但不会自动生成本项目的稳定对象身份、选择、参数UI、AI工具、撤销、格式升级、保存重开和输出一致性。尤其是：

- UV打包库不等于接缝／岛编辑器；细分库不等于完整修改器栈或雕刻系统。
- 骨骼求值库不等于绑定／权重绘制／动作编辑器；物理引擎支持的模拟类别必须分别核实。
- CAD内核不等于孔／螺纹标准表、工程图语义与装配文档。
- 可播放的渲染输出不等于包含全部实体、材质和动画的完整产物。

这些适配继续使用既有FeatureGraph、文档事务、服务、任务和原子保存；不通过引入桌面项目而并行创建另一套产品状态。

### 可复用资产

Poly Haven的可下载HDRI／材质／模型与ambientCG资产可作为后续环境／材质候选，两者官方均说明CC0；本次没有下载或选入产品。Poly Haven网页其他内容、预览图及API使用条款需与资产本身分开核对，不能整站复制。[Poly Haven许可](https://polyhaven.com/license)、[ambientCG许可](https://docs.ambientcg.com/license/)

### 与原计划的关系

每项候选必须映射到[原106项剩余清单](FLOE_CAD_3D_REMAINING_PLAN_20261031.zh-CN.md)。候选被推荐仅表示值得进入独立资格验证，不把任何原缺口标为已完成，也不自动派发后续任务。

本轮审阅39组候选路线，并为全部106项建立[机器可读复用对照](FLOE_CAD_3D_REUSE_LICENSE_MATRIX.json)。每条保留固定源码、许可文本哈希、依赖、平台证据、未覆盖范围及原验收条件。分组内可有多个许可不同的项目，不把“39组”当作39个已经可用的库。

### 优先选择

|功能缺口|复用来源|许可证／方式|当前决定|
|---|---|---|---|
|精确曲线、扫掠／放样、补面、隐藏线和STEP装配|现有OCCT 7.8.1|LGPL-2.1＋OCCT例外；A|继续扩现有shim。HLR／XDE／PipeShell／Filling有现成接口与本地头文件／符号证据；每项新组合仍需运行验收。|
|二维CAD编辑与DWG／DXF保真门|现有acadrust 0.5.5|MPL-2.0；A|先扩现有引擎。ezdxf是MIT外部DXF选项，不能替代DWG；libdxfrw／LibreDWG不是无许可成本的捷径。|
|更多基准面／轴|OpenShape3D新增Swift组件|MIT；C|优先挑取ConstructionPlaneKit及必要Axis／菜单增量，再接Floe既有关联层。|
|自动UV展开／打包|xatlas|MIT；C/B|优先。核心xatlas.cpp／xatlas.h及其包含的xatlas_c.h可独立审计；不带示例查看器依赖。|
|网格简化与属性误差|meshoptimizer|MIT；B|优先验证simplifyWithAttributes和误差读回。边界／接缝／材质保真仍需应用约束及验收。|
|mesh-only稳健布尔|Manifold|Apache-2.0；B|优先候选，保持与精确BRep分级；不默认替换Euclid，更不替代OCCT。|
|装配关节与约束求解|OndselSolver|LGPL-2.1；B|优先独立C++库资格；不搬FreeCAD的Qt／Python文档层。尚无本项目iOS编译证明。|
|骨骼采样／混合／局部IK／skinning|ozz-animation|MIT；B|优先限定骨骼后端资格；权重绘制、rig与时间线编辑另由产品实现。|
|刚体、限定软体／布料|现有RealityKit，必要时Jolt|Apple SDK／MIT；A/B|先验证系统能力覆盖；Jolt为独立候选，同一模拟世界保持一个求值权威。流体／专业CFD不由此覆盖。|
|FBX骨骼／动画资产导入|ufbx|MIT OR Unlicense，选MIT；C/B|两个C源／头文件边界清楚，先比较最小导入闭包；不是FBX exporter或骨骼编辑器。|
|细分曲面求值|OpenSubdiv|Tomorrow Open Source Technology License 1.0；B|条件性候选，先CPU求值；保留实际LICENSE／NOTICE，不能简写成标准Apache-2.0。|
|时间轴、轨道UI、视频设置／音轨|已有Floe动画服务＋AVFoundation／ImageIO|既有源码许可与Apple SDK；A|优先接现有数据与事务。无需为这些UI功能默认引入Godot、Filament或FFmpeg。|

上表许可证对应固定材料：[OpenShape3D](https://github.com/laanlabs/OpenShape3D/blob/fd988cc2743cc38cd0d7f537503ea5b287af3d53/LICENSE)、[acadrust](https://github.com/hakanaktt/acadrust/blob/04916cad827dccf688071c57af5b700dd5b3471c/LICENSE)、[xatlas](https://github.com/jpcy/xatlas/blob/f700c7790aaa030e794b52ba7791a05c085faf0c/LICENSE)、[meshoptimizer](https://github.com/zeux/meshoptimizer/blob/9e1f07b159d3cb777f1c67ed31fc11fd117986f4/LICENSE.md)、[Manifold](https://github.com/elalish/manifold/blob/ce50d78021d64507f89e8c9fc2c2e51018117857/LICENSE)、[OndselSolver](https://github.com/FreeCAD/OndselSolver/blob/4be80eef02a3486cda0d78f3ccbb308d207a9639/LICENSE)、[ozz](https://github.com/guillaumeblanc/ozz-animation/blob/744eb9d99f606eda849acb0b1204f7a3dc20bca1/LICENSE.md)、[Jolt](https://github.com/jrouwe/JoltPhysics/blob/fb915d8a9c68c54159b4b626fb8d3739a410f8f0/LICENSE)、[ufbx](https://github.com/ufbx/ufbx/blob/5955c5c0b042ac2dc6f32955ab206aaec0620cfc/LICENSE)、[OpenSubdiv](https://github.com/PixarAnimationStudios/OpenSubdiv/blob/1d90921ea32b9dcae31d30b907cbacefc0c616bf/LICENSE.txt)。

### 哪些确实适合“取一点”

**第一优先是OpenShape3D的新原生几何工具。** 固定旧pin`30b3c7c`与新pin`fd988cc2`对照后，ConstructionPlaneKit是新增文件（约14KB），包含中面、三点、沿曲线、垂直、绕边倾斜、平行等坐标构造；ConstructionAxisKit和Construct菜单有增量。相反，所查SketchOffset、SketchTrimmer、SketchSolverBridge、FeatureRefs逐字节相同，重抄它们不会补齐原缺口。

取新构造器不代表关联datum完成：它接收世界坐标快照，曲线输入是polyline；Floe仍需保存源身份、表达式、解析和重建关系。只取公用计算及必要枚举／控件适配，不整份覆盖EditorViewModel或Session。[构造器固定源码](https://github.com/laanlabs/OpenShape3D/blob/fd988cc2743cc38cd0d7f537503ea5b287af3d53/openshape3d/Kernel/ConstructionPlaneKit.swift)

其他可以审计挑取的小切片包括xatlas核心文件、ufbx两个文件、libigl里依赖干净的MPL文件，以及MIT的Godot数学／ImGuizmo／ImSequencer部分。后两者的编辑器／控件依赖成本较高：Godot整套轨道编辑器依赖其Resource／Variant／对象和GUI系统，ImSequencer依赖ImGui；并不因此成为可直接嵌入SwiftUI的完整时间线。

OpenMesh／geometry-central可作为临时工作网格或特定算法候选；不让其接管第二份稳定对象、文档与撤销状态。Instant Meshes的BSD代码和SculptGL的MIT代码在许可上允许进一步审计抽取，但前者是桌面应用，后者是已停止维护的WebGL／JS应用；本轮仅作研究／后续移植候选，不因许可证宽松就直接搬入。

### 需保留条件或本轮不选入

|候选|评估结论|
|---|---|
|FreeCAD／SheetMetal|所查PartDesign Hole、PlaneGCS、TechDraw部分、CAM部分可按LGPL边界继续评估；SheetMetalCmd／Text等文件是GPL，NewUnfolder的LGPL头不能消除其GPL导入依赖。根LICENSE不能代表全部工作台。|
|TiGL|Gordon／网络面代码为Apache-2.0，但实际路径涉及LGPL GEOMAlgo及TiXI／Boost／OCCT。先用现有单辅助导轨扫掠；任意多轨后端另做依赖和7.8.1兼容资格。|
|OpenUSD／SwiftUsd|当前OpenUSD实际是Tomorrow许可，SwiftUsd wrapper是Apache-2.0；预构建XCFramework及依赖另审。官方有iOS路线，但iOS与桌面模块覆盖不同，本项目未构建。保留场景／动画交换候选，不替换Floe文档权威。|
|Filament|Apache-2.0及官方iOS路线；是实时渲染器，不是离线路径追踪。仅在现有RealityKit出现具体阻碍时评估，第三方／host工具／格式插件逐项审。|
|Blender／独立Cycles|Blender整体发行与所查编辑器源受GPL约束，本次不抽取时间线／动画／几何节点代码；独立Cycles模块是Apache-2.0，可以另评。其依赖、Metal路径和资源预算未证明适合iOS，不能因使用Metal就当作iPad可用。|
|Chrono／FCL／Bullet／Assimp|分别是动力学、碰撞距离、物理备选、多格式导入候选；核心许可较宽松，但选定模块和依赖尚需闭合。只在对应缺口需要时采用，不同时堆入同类引擎。|
|libigl／CGAL／MeshLab|libigl有MPL核心和GPL模块；CGAL按包分GPL／LGPL。GPL部分本轮未选入，而非宣称与MPL普遍不能组合。MeshLab的桌面Qt／GPL应用代码不作为小库直接搬入。|
|Geogram默认配置|核心BSD不覆盖默认打开的HLBFGS非商业、TetGen AGPL、Triangle商业安排等条件。默认整包不选；若未来采用，应先关闭／替换受限组件并审计实际调用闭包。|
|MeshLib所查版本|实际为非商业评估／教育许可，不能按MIT／Apache自由修改和再分发。没有另行授权时不进入产品；公开仓库不等于开放源代码许可。|
|FFmpeg|默认LGPL路径、GPL开关／组件、version3和nonfree配置分别处理；不能只标LGPL。现有AVFoundation足以优先评估主要音视频需求，FFmpeg不解决ARView后台出帧。|
|CadQuery／build123d／cq_warehouse／ezdxf|所查根许可分别为Apache-2.0／MIT，但Python／OCP／OCCT／wheel闭包和标准数据另审。作为明确选定环境的成熟工具或限定数据／helper来源，不等于已可原生嵌入iOS。|
|Gmsh／CalculiX／OpenFOAM／CAMotics|成熟专业外部工具候选，有相应GPL与依赖条件；Gmsh还有官方iOS历史／构建路线及商业选项，但本次镜像到官方commit身份未完全闭合，不批准直接链接。不能把这些项目一概写成桌面only，也不能声称已满足本地iPad。|
|OpenCAMLib|LGPL成熟刀位算法是有限原生候选；尚未构建。所查3轴刀位／仿真能力不能抵销原计划的多轴车铣目标，FreeCAD CAM完整工作流与后处理器还需另审。|

以上各项的固定源码／许可证URL、SHA256、具体API、依赖条件和证据等级见[候选矩阵](FLOE_CAD_3D_REUSE_LICENSE_MATRIX.json)。对Gmsh镜像来源、历史iOS脚本、仅portable C++声明等限制保留原记录，不将其升级成Floe构建成功。

### 下一步建议与验收

先完成已有源码的集成边界与资格，再按需做独立小批：OpenShape基准几何切片；xatlas／meshoptimizer／Manifold；OndselSolver；骨骼／物理确需时ozz／Jolt／ufbx；之后才是细分、复杂场景交换和专业后端。时间轴与视频设置可先扩既有服务，不依赖这些所有库先完成。

每批固定实际版本、模块／feature flags、源码与通知材料，再验证device＋arm64 simulator、真实API与取消／内存、稳定ID、撤销／重开、格式和独立输出读回。需静态LGPL等额外材料时，跟随实际链接组合交付；许可或平台未闭合的候选继续保持待验证。本次仅评估，不安装／集成／编译／分发这些候选，不为填表预排后续worker。

## 9. 全39组候选的API、固定来源与限制

A=现有复用；B=独立库；C=有界源码提取；D=参考／明确外部工具；E=本轮未选入或门槛未闭合。所有新候选本轮均未在Floe构建或运行。成本来自源码／依赖判断，不是实测工期或设备性能承诺。下列API和上游证据保留其技术原名；许可边界不因表格归类而省略。

### 工程／CAD

#### engineering-ENG01 / Existing OCCT 7.8.1

对应原编号：M03、M04、M13、M14、M15、M16、M17、M18、M20、M21、M22、M23、M24、M25、M26、M27、E01、E07、E08、E12、E13、E24、E25、E26。

许可证：LGPL-2.1 + OCCT exception 1.0。复用方式：A。

建议：First choice: expose already bundled mature APIs through the existing shim; do not replace kernel or upgrade OCCT for this batch.

可复用API／文件：HLRBRep_Algo.Add/Projector/Update/Hide + HLRBRep_HLRToShape.VCompound/HCompound: exact BRep drawing visibility (E12).; XCAFDoc_ShapeTool.AddShape/AddComponent + STEPCAFControl_Writer/IGESCAFControl_Writer: names, colors, assembly instances/transforms for exchange (E01/E24/E25/E26); not a mate/history solver.; BRepOffsetAPI_MakePipeShell.SetMode(auxiliarySpine,...) + repeated Add(section) + Build/MakeSolid: multiple profiles, ONE auxiliary guide (M16).; BRepFill_Filling.Add(edge,supportFace,G1/G2,...) + Build/Face/error metrics; ThruSections solid=false, Sewing/ThickSolid for separate surface qualification (M17).; BRepAlgoAPI/Extrema exact collision/distance and Geom2d/offset operations should precede new collision/curve engines; advanced features require API-specific qualification.

许可／依赖边界：boundary: Reuse current static XCFramework/relink/source-offer path. Exception permits specified header-object uses; it does not waive all static-library/source/relink duties. No OCCT source edits. Final distribution compliance belongs to root.; hash_scope: bundled-sources hashes identify local shipped bytes; fixed upstream URLs are provenance references, not a claim of byte identity with upstream raw license text.

平台／成本：tier: I2_existing_bundled; device: ios-arm64 slice exists; simulator: ios-arm64-simulator slice exists; new_api_runtime: NOT run. ar -t confirms six named object units in BOTH archives; object presence is not adapter/link/geometry proof.；Low dependency delta; medium adapter/geometry/feature integration.

仍需产品接合：Stable semantic refs, feature replay/edit, surface-vs-solid document type, schema floor/opaque old readers, cancellation, undo and UI/Agent remain Floe work. HLR needs associative views/dimensions; XDE export needs current SceneSnapshot assembly placement and BOM IDs.


#### engineering-ENG02 / OpenShape3D native Swift components

对应原编号：M01、M02、M03、M04、M06、M07、M08、M25、M27、M30。

许可证：MIT; copyright/notice retained。复用方式：A/C。

建议：Highest-priority permissive file extraction: inspect new ConstructionPlaneKit + narrow ConstructionAxisKit/menu delta. Preserve Floe model/services rather than merge the upstream app.

可复用API／文件：NEW ConstructionPlaneKit.offset/midplane/throughPoints/onCurve/perpendicular/throughEdge(angle)/parallel/derive (14,079 bytes), absent at vendored pin.; ConstructionAxisKit current origin/direction/length/name/visibility and new AxisConstruction menu variants: adapt only needed geometry/UI.; ToolPaletteView Construct menu and spline/imprint entry wiring are integration references; their referenced feature APIs must be traced before copying UI.; SketchOffset, SketchTrimmer, SketchSolverBridge and FeatureRefs are byte-identical between the two fixed pins: no new solver/offset/trim benefit from recopying these.

许可／依赖边界：boundary: Swift components carry the upstream root MIT notice. OCCT/Euclid dependencies keep their own licenses; MIT app code is not a license for bundled OCCT.

平台／成本：tier: I1_upstream_native_ios_source_plus_existing_baseline; device: Upstream iPad/iPhone project and Floe vendored baseline; NEW files not compiled here; simulator: NEW files not compiled here；Low file-level geometry extraction; medium/high associative feature integration.

仍需产品接合：New kit receives world-value snapshots and does not store source references. Must add or adapt persistent definition/reference model, recompute, ID-preserving updates, undo, schema, bilingual native UI/AI. onCurve uses polyline sampling: cannot claim analytic curve frame accuracy. Retain Floe CAS/package/permission/transport services; do not copy upstream gallery/SwiftData/HTTP MCP server.

- [laanlabs/OpenShape3D / LICENSE](https://raw.githubusercontent.com/laanlabs/OpenShape3D/fd988cc2743cc38cd0d7f537503ea5b287af3d53/LICENSE); pin `fd988cc2743cc38cd0d7f537503ea5b287af3d53`; retained SHA256 `dbdeb16766c9aae5eb59d4f184e6222727a23a44698fdea275e4fd0857339a83`.
- [laanlabs/OpenShape3D / LICENSE](https://raw.githubusercontent.com/laanlabs/OpenShape3D/30b3c7c1784754f237466e093ab42ff085175d40/LICENSE); pin `30b3c7c1784754f237466e093ab42ff085175d40`; retained SHA256 `dbdeb16766c9aae5eb59d4f184e6222727a23a44698fdea275e4fd0857339a83`.

#### engineering-ENG03 / FreeCAD feature / TechDraw / SheetMetal files

对应原编号：M12、M13、M14、M21、M22、M26、M29、E11、E12、E14、E15、E16、E17、E18、E19、E38。

许可证：FreeCAD LICENSE LGPL-2.1; checked PartDesign Hole / Sketcher GCS / TechDraw DrawViewPart / CAM Base+Surface SPDX LGPL-2.1-or-later。复用方式：C/D/E。

建议：Use mature OCCT directly first. FreeCAD can provide carefully isolated LGPL library modules or design reference; do not transplant whole workbenches into native Swift.

可复用API／文件：PartDesign/App/FeatureHole.cpp includes hole/thread/revolve/pipe/cut logic; no separate FeatureThread.cpp found at the checked path. H1 HoleSpec already exists locally source-ready: avoid duplicate implementation.; TechDraw/App/DrawViewPart.cpp uses OCCT HLR; useful pipeline reference for projection, cosmetic geometry and regions, not a standalone drawing SDK.; SheetMetalNewUnfolder.py has unfold/K-factor related workflow but imports Part/TechDraw/SheetMetalTools AND SheetMetalText.

许可／依赖边界：file_overrides: SheetMetal LICENSE: LGPL-2.1 text; SheetMetalCmd.py: GPL-2.0-or-later; SheetMetalNewUnfolder.py: Lesser GPL v2-or-later header; SheetMetalTools.py: Lesser GPL v2-or-later header; SheetMetalText.py: GPL-2.0-or-later; boundary: NewUnfolder being LGPL does NOT make its imported GPL Text dependency disappear. Preserve exact notices and library boundary; actual extracted closure needs per-file review. Translation to Swift does not remove derivative-source obligations. GPL file copying is not cleared by the LGPL repo headline.

平台／成本：tier: I0_source_only; device: No current iOS embedding proof; simulator: No current iOS embedding proof；High as workbench port; medium only if a genuinely independent library closure is established.

仍需产品接合：Floe feature IDs/ref mapping/undo/store remain; drawing layout/GD&T/BOM/templates/native UI not provided by one HLR file. Thread profile/tolerance/standards data and sheetmetal validation need separate qualification.

- [FreeCAD/FreeCAD / LICENSE](https://raw.githubusercontent.com/FreeCAD/FreeCAD/bbc08916a0bab73fdb4b7f3dad7ff706a18924c9/LICENSE); pin `bbc08916a0bab73fdb4b7f3dad7ff706a18924c9`; retained SHA256 `7ffe1954587c77dfba1cf8eb9b2ea743671fa6e63f9e7a2f258119d42e14eefe`.
- [shaise/FreeCAD_SheetMetal / LICENSE](https://raw.githubusercontent.com/shaise/FreeCAD_SheetMetal/cbf6595b68ad015266923749c160c3555a72e1fd/LICENSE); pin `cbf6595b68ad015266923749c160c3555a72e1fd`; retained SHA256 `510ccb0ba9b0a9bf99343901040a8ec42f92310704203d2068cea815cbbabb8f`.

#### engineering-ENG04 / TiGL Gordon/network surfaces

对应原编号：M16、M17。

许可证：Apache-2.0 root + Gordon/network source notices。复用方式：B/D。

建议：Keep as mature future multi-guide backend; first ship qualified existing OCCT multi-section + single auxiliary guide. Do not copy two Gordon files and claim a standalone kernel.

可复用API／文件：CTiglInterpolateCurveNetwork(profiles,guides,spatialTolerance).Surface()/ParametersProfiles()/ParametersGuides().; CTiglMakeLoft.addProfiles/addGuides/setMakeSolid(false)/Shape().

许可／依赖边界：transitive: Actual commonfunctions path includes GEOMAlgo_Splitter with LGPL-2.1 notice. Full TiGL is not all-Apache. TiXI/Boost/OCCT and any optional build deps need full chosen closure review.; boundary: Reuse prior pinned small-source/license proof; no new source download/build. No SISL observed in this bounded network callchain, not a whole-tree exclusion.

平台／成本：tier: I0_source_only; device: No iOS target/proof in inspected config; simulator: No arm64-simulator proof；High dependency/build closure; cannot mix another OCCT ABI as shortcut.

仍需产品接合：Compatible >=2 profiles and >=2 guides, approximation/reparameterization error handling; no free endpoint support-face G1/G2 API. Surface model/ref/schema/undo/UI/Agent/export remain Floe work.


#### engineering-ENG05 / CadQuery / build123d / cq_warehouse

对应原编号：M12、M13、M14、M15、M16、M17、M21、M22、M29。

许可证：All THREE checked root licenses Apache-2.0 (CadQuery is not LGPL at this pin).。复用方式：D/C。

建议：Explicitly selected external Python environment or reference/data review. These are mature CAD abstractions but not ready Swift/iOS embedded SDKs.

可复用API／文件：CadQuery Workplane.hole/cboreHole/cskHole/sweep/loft/shell/fillet.; build123d operations_part.loft and part operations wrap OCP.; cq_warehouse IsoThread/AcmeThread/TrapezoidalThread and fastener classes/CSV lookup; useful thread/spec catalogue candidates after provenance review.

许可／依赖边界：transitive: cadquery-ocp/OCP embeds OCCT LGPL+exception; Python/OCP/nlopt/numpy/scipy and other selected wheels have separate licenses. build123d current dependency may use OCCT8, not Floe7.8.1 ABI.; data: Apache root alone is not proof every standards-derived table, diagram or bundled dimension dataset is redistributable without qualification. Trace CSV/source provenance, modifications and units before extracting standards data; no ISO text was copied.; boundary: Can isolate genuinely licensed data/helper files after review; direct translation of source keeps its license notices.

平台／成本：tier: I0_source_only; device: No native embedded iOS closure demonstrated; simulator: No native embedded iOS closure demonstrated；Medium for explicit external workflow; high and not selected for native embedding.

仍需产品接合：External STEP result is not parametric Floe feature history; need explicit source provenance/import loss list. Native ThreadSpec and persistent editable hole/thread remain Floe integration even with dimension data.

- [CadQuery/cadquery / LICENSE](https://raw.githubusercontent.com/CadQuery/cadquery/8178185a24a035c9af7f4679033be14267f6a6ef/LICENSE); pin `8178185a24a035c9af7f4679033be14267f6a6ef`; retained SHA256 `7345486c76eb0160046e06c9c77797294979e15fc7cd1502d5c9cb650931bb84`.
- [gumyr/build123d / LICENSE](https://raw.githubusercontent.com/gumyr/build123d/4f8c549b58cf6141fc536e22da202fbf5bef5746/LICENSE); pin `4f8c549b58cf6141fc536e22da202fbf5bef5746`; retained SHA256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`.
- [gumyr/cq_warehouse / LICENSE](https://raw.githubusercontent.com/gumyr/cq_warehouse/a57bb7a24762d367d66369f280a24c38a64e73dd/LICENSE); pin `a57bb7a24762d367d66369f280a24c38a64e73dd`; retained SHA256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`.

#### engineering-ENG06 / Constrained sketch solvers: PlaneGCS / libslvs / Ceres

对应原编号：M02、M03、M04、M06、E06。

许可证：PlaneGCS checked file LGPL-2.1-or-later; SolveSpace COPYING GPL-3.0; Ceres BSD-3-Clause.。复用方式：B/C/D/E。

建议：Retain existing MIT Swift solver for demonstrated scopes. If mature CAD solver is needed, first investigate isolating FreeCAD PlaneGCS under LGPL; libslvs is GPL. Ceres is a numeric backend, not a ready CAD solver and not authorization to invent one.

可复用API／文件：PlaneGCS GCS::System sketch constraints/diagnostics; checked GCS.cpp is coupled to FreeCAD Base/Tools/Console/FCConfig and Boost graph.; SolveSpace C slvs.h Slvs_Solve / Slvs_SolveSketch / constraint entities; exposed library shares GPL.; Ceres Problem/AddResidualBlock + Solve are least-squares infrastructure, with no full sketch topology/DOF/conflict/domain constraint layer supplied.

许可／依赖边界：transitive: PlaneGCS Eigen + Boost + FreeCAD Base closure remains to isolate/license. Ceres requires Eigen/Abseil, optional SuiteSparse/METIS/CUDA each own terms; do not enable optional copyleft by default or call BSD top-level sufficient.; boundary: Use intact mature constraint implementation rather than rewrite residual/solve algorithms. No GPL libslvs direct inclusion cleared under current MPL/release policy.

平台／成本：tier: I1_upstream_ios_docs_for_Ceres_only; device: Ceres upstream documented arm64; not compiled locally; simulator: Pinned preset lacks arm64 simulator; needs modern toolchain qualification; PlaneGCS_libslvs: No local iOS proof；Medium/high PlaneGCS isolation; high domain work for bare Ceres; prohibited self-built replacement solver not proposed.

仍需产品接合：Sketch entity/constraint refs and undo integration, scale/units normalization, DOF/redundancy/error explanation and large sketch budget still required.

- [solvespace/solvespace / COPYING.txt](https://raw.githubusercontent.com/solvespace/solvespace/0fa4c51c23ce9b39bc1624f9108fd06ead7f475a/COPYING.txt); pin `0fa4c51c23ce9b39bc1624f9108fd06ead7f475a`; retained SHA256 `ca372a7d92560b1fa9f6d832b440e8bcd62d9adfa8870c98287deab66d98310e`.
- [ceres-solver/ceres-solver / LICENSE](https://raw.githubusercontent.com/ceres-solver/ceres-solver/07a952622c2118433c783b1c3bd3fabe68420fc5/LICENSE); pin `07a952622c2118433c783b1c3bd3fabe68420fc5`; retained SHA256 `8b6853e74176ea2bc7cabd5acbc1b0a65aaa197531e4243b57fc266ad0354c25`.

#### engineering-ENG07 / 2D DWG/DXF: existing acadrust; ezdxf; GPL alternatives

对应原编号：E20、E21、E22、E23、E28、E30、E31。

许可证：acadrust MPL-2.0; ezdxf MIT; libdxfrw source header GPL-2.0-or-later; LibreDWG GPL-3.0 text.。复用方式：A/D/E。

建议：Expand already bundled acadrust narrow editing and preservation gates first. ezdxf is a permissive explicit-external DXF option. libdxfrw/LibreDWG are not license-free shortcuts.

可复用API／文件：acadrust 0.5.5 existing local WASM edit/read/write + same-format reparse gate, limited handles/types.; ezdxf Python DXF document/entity model, recover/audit/render helpers; not native DWG writer.; libdxfrw dxfRW reader/writer API; LibreDWG DWG API: GPL-family obligations remain even when taking a small header/implementation subset.

许可／依赖边界：acadrust_pin: crate0.5.5 archive hash6298485f7afd00af7880f285f01ab387143a1fbb20c42f9048830c95b19dda5d; tag object664a5a5afe38262b30fd9120cd153fae9f468331 peels to source04916cad827dccf688071c57af5b700dd5b3471c, matching crate .cargo_vcs_info.; acadrust_license_hashes: crate LICENSE 9e83d639d5f01d42bd019923d48cc485155f10d20c81f6294902976fe2715fca; upstream LICENSE65a46774b887ca24b234a211308f6b59148a34bc8fa706487155ec45528d2db3; normalized text identical, line endings differ.; boundary: MPL covered-file source/notice duties retained. GPL integrations need explicit root policy decision; do not infer all GPL use forbidden or merely-aggregated external tools automatically infect Floe.

平台／成本：tier: I2_existing_acadrust_local_runtime_baseline; device_sim: No new runtime/build test this task; alternatives source-only；Low dependency delta for acadrust; medium format/data/UI work; high alternative native port.

仍需产品接合：Editable/read-only entity matrix, preserve unsupported blocks/xrefs/proxies/layouts, associative dimensions, closed bulge/spline/OCS editing, original-byte recovery and independent third-party CAD review.

- [LibreCAD/libdxfrw / COPYING](https://raw.githubusercontent.com/LibreCAD/libdxfrw/d68fb1ed937ad2a74a54f6208277ec10a1b031b0/COPYING); pin `d68fb1ed937ad2a74a54f6208277ec10a1b031b0`; retained SHA256 `8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643`.
- [LibreDWG/libredwg / COPYING](https://raw.githubusercontent.com/LibreDWG/libredwg/8329b1248d67d136c356c7df85fec54195c438aa/COPYING); pin `8329b1248d67d136c356c7df85fec54195c438aa`; retained SHA256 `8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903`.
- [mozman/ezdxf / LICENSE](https://raw.githubusercontent.com/mozman/ezdxf/5265e6e6d02388a95f406c26983e5c39452ad003/LICENSE); pin `5265e6e6d02388a95f406c26983e5c39452ad003`; retained SHA256 `db97ca426fc0d2b8124145de0f36181db73e6e713ce642d42fed2efc442edf19`.
- [hakanaktt/acadrust / LICENSE](https://raw.githubusercontent.com/hakanaktt/acadrust/04916cad827dccf688071c57af5b700dd5b3471c/LICENSE); pin `04916cad827dccf688071c57af5b700dd5b3471c`; retained SHA256 `65a46774b887ca24b234a211308f6b59148a34bc8fa706487155ec45528d2db3`.

#### engineering-ENG08 / OndselSolver (actual FreeCAD Assembly backend)

对应原编号：E03、E04、E05、E06、E10。

许可证：LGPL-2.1 LICENSE; checked core headers refer to LICENSE (no stronger GPL header observed in selected files).。复用方式：B。

建议：Priority new mature assembly/kinematic library candidate. Qualify standalone OndselSolver before importing the desktop FreeCAD Assembly module.

可复用API／文件：MbD::ASMTAssembly::solve(), runPreDrag/runDragStep/runPostDrag, runKINEMATIC().; ASMTRevoluteJoint/ASMTTranslationalJoint/ASMTGearJoint, plus current FreeCAD integration includes rack-pinion, cylindrical, spherical, planar and other joint classes.; FreeCAD AssemblyObject.cpp includes these Ondsel headers; Assembly/App/CMakeLists links OndselSolver, .gitmodules points to FreeCAD/OndselSolver.

许可／依赖边界：boundary: Static/shared library boundary with complete pinned source, notices, changes and practical relink route needs release-owner review. FreeCAD AssemblyObject is separately LGPL-2.1-or-later; do not copy desktop document/Python wrapper if standalone core suffices. This is source-boundary review, not whole-tree clearance.

平台／成本：tier: I0_standalone_Cpp_source_and_real_desktop_consumer; device: No iOS arm64 build/runtime proof; simulator: No arm64-simulator proof；Medium native shim/build, high domain integration; lower desktop coupling than FreeCAD Assembly workbench.

仍需产品接合：Persistent face/edge mates, ConstraintID updates, units/scaling, DOF and redundant closed-loop diagnostics, deterministic drag/refuse/cancel transactions; motion time series->native animation is separate from solver.

- [FreeCAD/OndselSolver / LICENSE](https://raw.githubusercontent.com/FreeCAD/OndselSolver/4be80eef02a3486cda0d78f3ccbb308d207a9639/LICENSE); pin `4be80eef02a3486cda0d78f3ccbb308d207a9639`; retained SHA256 `299de7a97751fb7babe99f05580d6b1fe5be11d8113fe4b8f2dd2071d3931b2d`.

#### engineering-ENG09 / Project Chrono core / mechanisms

对应原编号：E03、E07、E08、E10、E38。

许可证：BSD-3-Clause root LICENSE。复用方式：B。

建议：Permissive mature multibody/contact candidate if E10 needs dynamics beyond the assembly solver. Select CPU core, not whole vehicle/robotics/GPU/FSI stack.

可复用API／文件：ChSystemNSC/SMC body/contact dynamics; ChLinkLockRevolute / prismatic-family and motor constraints.; Chrono_core CMake exposes Eigen dependency and optional FEA/multiphysics units; this is not proof of all professional CAE/CFD coverage.

许可／依赖边界：transitive: Eigen plus selected collision/math/serialization modules keep their own notices. CUDA/Thrust/FSI/Irrlicht/Vulkan/HDF5/optional libraries are NOT silently included/cleared by the BSD root.

平台／成本：tier: I0_source_only; device: No iOS build/runtime proof; simulator: No arm64-simulator proof；Medium/high build+native shim; high mechanics validation and study UI.

仍需产品接合：Rigid body inertia/mass/unit frames, contacts/friction/load definitions, solver choice, timeline results and undoable study persistence. Animation keyframes cannot substitute for validated mechanics.

- [projectchrono/chrono / LICENSE](https://raw.githubusercontent.com/projectchrono/chrono/aa43d3bfc6f21e567e5d68d8b7ae3569d7fa19ae/LICENSE); pin `aa43d3bfc6f21e567e5d68d8b7ae3569d7fa19ae`; retained SHA256 `5f625eb4c9e0ddf86db9d1ed9b6adb5b30296ea81919282b2f38c977136bf079`.

#### engineering-ENG10 / FCL collision / distance

对应原编号：E07、E08、E10。

许可证：BSD-3-Clause LICENSE。复用方式：B。

建议：Use for missing mesh-level collision/distance after checking existing OCCT exact-BRep and current mesh service. It complements, rather than replaces, exact kernel results.

可复用API／文件：fcl::collide / fcl::distance narrowphase with transformed CollisionObject/BVH triangle models; broadphase managers for candidate pairs.

许可／依赖边界：transitive: CMake requires Eigen and libccd; OctoMap enabled by default. Pin/audit their actual chosen source/licenses separately before inclusion; disable unneeded optional OctoMap. No dependency-closure clearance claimed here.

平台／成本：tier: I0_source_only; device: No iOS build/runtime proof; simulator: No arm64-simulator proof；Medium build/shim; medium query budget/integration.

仍需产品接合：World instance transforms, triangle grade/tolerance and clearance/contact semantics, pair filtering, cancellation/stale-result fence; resource budget and UI highlighting.

- [flexible-collision-library/fcl / LICENSE](https://raw.githubusercontent.com/flexible-collision-library/fcl/ae86ecde788086110f8a4cea54ae1949df8a21d3/LICENSE); pin `ae86ecde788086110f8a4cea54ae1949df8a21d3`; retained SHA256 `899258d09bf54d5d11eee2567e6cf72f7927a81267959db4baa3468a70fd8703`.

#### engineering-ENG11 / Gmsh / ONELAB meshing

对应原编号：E38、M17、M28。

许可证：GPL-2.0-or-later with listed external-library linking exception; commercial option described by official authors.。复用方式：B/D/E。

建议：Mature mesher with actual upstream iOS lineage, BUT GPL/commercial license and current toolchain/ABI qualification gate. No immediate direct integration approval.

可复用API／文件：gmsh::model::occ for OCC geometry bridge, gmsh::model::mesh::generate and getNodes/getElements for FE mesh.; ONELAB upstream mobile directory/app proves iOS history, not a turnkey current proprietary/permissive SDK nor a full FEA/CFD solver.

许可／依赖边界：boundary: Exception for specified external libraries does not convert Gmsh to permissive embedding. MPL Floe is not automatically incompatible, but whole combined-work/distribution terms need explicit root decision; preserving current approach favors external tool or separately negotiated license.; source_provenance: Official GitLab bot-gated during research. Fixed source snapshot from live-clones mirror; primary official gmsh.info corroborates APIs/license/iOS app, but mirror-to-official commit identity not independently closed. Not cleared as actual link/copy pin.

平台／成本：tier: I1_official_ios_app_and_mobile_source_lineage; device: Upstream iOS app exists; current selected pin not built by Floe; simulator: Current arm64-simulator unverified；High build/license configuration; medium mesh adapter; high CAE study workflow.

仍需产品接合：CAD boundary tagging, stable entity-to-mesh mapping, mesh quality/refinement controls, analysis study persistence/material/BC/solver/result visualization. Mesher alone is not CAE closure.

- [live-clones/gmsh / LICENSE.txt](https://raw.githubusercontent.com/live-clones/gmsh/f2625aae392e3ae86e3bcdad55f2f20d7ae39c3b/LICENSE.txt); pin `f2625aae392e3ae86e3bcdad55f2f20d7ae39c3b`; retained SHA256 `775884696671d8010c3377baaec12edd1f67204a72787ff71e59ae9075ccd0b5`.

#### engineering-ENG12 / CalculiX ccx FEA

对应原编号：E38。

许可证：GPL-2.0 root text; individual source notices/version choices require full selected closure review。复用方式：D/E。

建议：Mature solid/thermal/contact FEA example for an explicitly selected external environment. Native local iOS route is not qualified; no self-written replacement solver proposed.

可复用API／文件：ccx input-deck solver, static/dynamic/nonlinear/thermal/contact analyses; mesh/material/BC input and solver output pipeline.

许可／依赖边界：transitive: Pinned src/Makefile links SPOOLES, ARPACK, LAPACK/BLAS, pthread/OpenMP; each version/license/compiler runtime must be audited. GPL root not approved for current native distribution approach.

平台／成本：tier: I0_source_only; device: No native iOS arm64 closure; simulator: No native arm64-simulator closure；High native port; medium external executable workflow; high validation/UI.

仍需产品接合：Materials, constitutive models, loads/BC/contacts, mesh study IDs, convergence/failure results, stress interpretation and result units. Not all CFD/multiphysics requirements are satisfied.

- [Dhondtguido/CalculiX / LICENSE](https://raw.githubusercontent.com/Dhondtguido/CalculiX/00fc77776204f919f81b86a80b42fbc54af1d314/LICENSE); pin `00fc77776204f919f81b86a80b42fbc54af1d314`; retained SHA256 `8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643`.

#### engineering-ENG13 / OpenFOAM Foundation 13 CFD / multiphysics

对应原编号：E38。

许可证：GPL-3.0 COPYING; source headers describe GPLv3-or-later (selected files checked).。复用方式：D/E。

建议：Mature CFD/multiphysics external-tool candidate. Not a ready native iOS library, and not accepted as local iPad closure merely because C++ source is available.

可复用API／文件：OpenFOAM finite-volume solvers/modules, mesh utilities, transport/turbulence and selected coupled physics; actual physics menu depends on pinned modules.

许可／依赖边界：transitive: MPI/partitioners, Scotch/PTScotch, optional ParaView and compiler/runtime dependencies have their own license/build closure. No blanket GPL alternative/relicense assumed.

平台／成本：tier: I0_source_only; device: No supported native embedded iOS proof; simulator: No arm64-simulator proof；Very high native adaptation; medium/high explicit external job workflow; very high professional CFD validation.

仍需产品接合：Boundary/material/mesh/initial-condition/model UI, convergence/residuals, field visualization, units, case versioning and owned cancellable jobs. OpenFOAM name alone is not all multiphysics closure.

- [OpenFOAM/OpenFOAM-13 / COPYING](https://raw.githubusercontent.com/OpenFOAM/OpenFOAM-13/18870c24d21c6b982e2cdec27b2f59738cca5f90/COPYING); pin `18870c24d21c6b982e2cdec27b2f59738cca5f90`; retained SHA256 `a62f4262b9739f43478d025ed9fc5419585ec27b4b50e88f55e3186141e18ef1`.

#### engineering-ENG14 / CAM: OpenCAMLib / FreeCAD CAM / CAMotics

对应原编号：E38、M29。

许可证：OpenCAMLib LGPL-2.1-or-later checked source headers, LGPL2.1 COPYING; FreeCAD CAM Base/Surface LGPL-2.1-or-later; CAMotics GPL-2.0-or-later README + GPL2 COPYING.。复用方式：B/D/E。

建议：OpenCAMLib is the most bounded native toolpath-kernel candidate for 3-axis surfaces. FreeCAD CAM is reference/external workflow; CAMotics is external GPL 3-axis simulation. None proves multi-axis + turn-mill requirements.

可复用API／文件：OpenCAMLib ocl::BatchDropCutter (STLSurf+MillingCutter -> CLPoint collection) and ocl::Waterline; mature cutter-location generation.; FreeCAD Path/Op/Surface.py explicitly imports ocl/opencamlib; Base.py imports FreeCAD/Part/Path/PySide.; CAMotics README explicitly promises 3-axis NC simulation; no unsupported 5-axis/turn-mill claim.

许可／依赖边界：boundary: OpenCAMLib library can be investigated under same LGPL source/relink discipline; all actual C++ source dependencies still need pinned review. FreeCAD Path root LGPL does not pre-clear all workbench/libarea/postprocessor dependencies. CAMotics GPL direct linking not cleared by current policy.

平台／成本：tier: I0_source_only; device: OpenCAMLib no local iOS binary/runtime proof; simulator: No arm64-simulator proof；Medium/high OCL headless shim; high professional CAM adapter; full multi-axis/turn-mill route unresolved.

仍需产品接合：Tool/holder/stock/setup and work frames, feeds/speeds, operation history/rest machining, collisions/gouge verification, machining simulation and independent toolpath interchange. No machine-specific G-code needed per user scope; that exclusion does not create missing multi-axis or turning algorithms.

- [aewallin/opencamlib / COPYING](https://raw.githubusercontent.com/aewallin/opencamlib/1a450b7c3d3b669224a2a5d09aab7f319794574c/COPYING); pin `1a450b7c3d3b669224a2a5d09aab7f319794574c`; retained SHA256 `dc626520dcd53a22f727af3ee42c770e56c97a64fe3adb063799d8ab032fe551`.
- [CauldronDevelopmentLLC/CAMotics / COPYING](https://raw.githubusercontent.com/CauldronDevelopmentLLC/CAMotics/e84665f2fa9d1151f03282ac7e01320bc65e015b/COPYING); pin `e84665f2fa9d1151f03282ac7e01320bc65e015b`; retained SHA256 `8177f97513213526df2cf6184d8ff986c675afb514d4e68a404010521b880643`.

### 网格／UV／修改器

#### mesh-manifold / Manifold（流形网格布尔与简化）

对应原编号：M28、X05、X06、X08。

许可证：Apache-2.0。复用方式：native-library-shortlist。

建议：优先级最高的网格布尔候选：以静态库接入，作为 M28 的 mesh-only 稳健布尔后端；保留 Euclid 处理简单/既有路径，不静默替换。首版关闭 CrossSection 与 TBB，减少可选依赖。

可复用API／文件: headers: include/manifold/manifold.h; include/manifold/mesh.h; include/manifold/common.h; include/manifold/polygon.h; api: manifold::Manifold::Boolean(const Manifold&, OpType); manifold::Manifold::BatchBoolean(const std::vector<Manifold>&, OpType); manifold::Manifold::Simplify(double tolerance = 0); manifold::Manifold::GetMeshGL(int normalIdx = -1); manifold::Manifold::Status() / Error; manifold::Manifold::WithContext(const ExecutionContext&); manifold::ExecutionContext::Cancel()/Progress(); manifold::MeshGLP::Merge(); algorithms: guaranteed-manifold mesh CSG (union/difference/intersection, batch); BVH-based triangle collision and boolean result assembly; manifold-preserving simplification; best-effort merge-vector repair for slightly non-manifold input; SDF level-set extraction (ExecutionContext::LevelSet)

未覆盖: 不是精确 BRep：不保留解析曲面、特征历史或 OCCT 拓扑；结果必须标为 mesh 等级; 不是通用修复器：不保证补洞、自交消除、非流形到封闭实体; 不是编辑器/稳定拓扑模型：没有选择、边环、面挤出、持久 ID、撤销或文档事务; 不解决 UV、材质节点、雕刻、纹理烘焙或场景/灯光; 单个超大布尔可能在两次取消检查之间跑完；不是硬实时抢占

依赖: required: ; optional: name: Clipper2; license: BSL-1.0; pin: commit 46f639177fe418f9689e8ddb74f08a870c71f5b4 (builtin fetch); when: MANIFOLD_CROSS_SECTION=ON (default); license_file: path: evidence/deps/clipper2/LICENSE; bytes: 1338; sha256: c9bff75738922193e67fa726fa225535870d2aa1059f91452c411736284ad566; name: oneTBB; license: Apache-2.0; pin: v2022.3.0 (builtin fetch); when: MANIFOLD_PAR=ON (default OFF); license_file: path: evidence/deps/tbb-2022.3.0/LICENSE.txt; bytes: 11357; sha256: c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4; not_needed_for_core_zh: Nanobind（Python 绑定）; Emscripten（WASM）; GoogleTest（测试）; Assimp（extras 工具）; Tracy（性能分析）

许可义务: 随分发附 Apache-2.0 LICENSE；保留版权/AUTHORS；修改文件加显著变更说明。; 若启用默认 CrossSection：同时固定并遵守 Clipper2 的 BSL-1.0（其 LICENSE 需随分发）；若启用 TBB：Apache-2.0。; 源提供/relink：无（Apache-2.0 不要求 source offer）。

平台证据: proof_level: source-only; no iOS build in this task; notes_zh: 纯 C++17、无平台代码；未在本任务编译 device/arm64 simulator。可选 `MANIFOLD_NO_IOSTREAM=ON` 去掉 iostream/文件系统依赖；需自建 ObjC++/Swift 桥。

成本／接合: effort: medium; effort_zh: 中等：C++ 静态库 + ObjC++/Swift 桥 + MeshGL 转换 + 结果等级/错误映射；无第三方运行时。; cancellation_zh: `ExecutionContext` 可跨线程 Cancel/Progress；布尔树按子布尔检查，Hull/Minkowski 按阶段；构造新 Manifold 重试。; memory_zh: 随三角形数、BVH 与结果网格增长；有 `Error::ResultTooLarge` 防护；本任务未做 50k 三角/峰值内存实测。; undo_document_zh: 库无文档/撤销；调用方必须以事务方式生成新 body/新 revision，保留输入网格、操作与等级；失败不得提交半结果。

[https://github.com/elalish/manifold](https://github.com/elalish/manifold/tree/v3.5.4); commit `ce50d78021d64507f89e8c9fc2c2e51018117857`; [license](https://github.com/elalish/manifold/blob/v3.5.4/LICENSE).

- License archive evidence/manifold/LICENSE: SHA256 `c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4`.

#### mesh-xatlas / xatlas（自动 UV 展开与图集打包）

对应原编号：X09、X14、X10、X08。

许可证：MIT。复用方式：audited-file-extraction。

建议：X09 的首选算法源：核心只复制 `source/xatlas/xatlas.cpp` + `source/xatlas/xatlas.h`（MIT）；`source/xatlas/xatlas_c.h` 是 C 绑定头，且被 `xatlas.cpp` include（6618 bytes），未修改上游构建时需一并保留；不调用 C API 时可保持不用，若要移除需做本地 patch。不要复制 `source/thirdparty/**`。手动接缝/岛编辑、多 UV 集和逐面映射仍由产品实现。

可复用API／文件: headers: source/xatlas/xatlas.h; source/xatlas/xatlas.cpp; source/xatlas/xatlas_c.h; api: xatlas::Create() / Destroy(); xatlas::AddMesh(Atlas*, const MeshDecl&, uint32_t meshCountHint); xatlas::AddMeshJoin(Atlas*); xatlas::ComputeCharts(Atlas*, ChartOptions); xatlas::PackCharts(Atlas*, PackOptions); xatlas::Generate(Atlas*, ChartOptions, PackOptions); xatlas::SetProgressCallback(Atlas*, ProgressFunc, void*); xatlas::AddUvMesh(Atlas*, const UvMeshDecl&); algorithms: mesh segmentation into charts; chart parameterization; atlas packing with padding/resolution/texels-per-unit options; multi-atlas output; normal/texture seam weights as chart-growth heuristics; core_files: source/xatlas/xatlas.cpp; source/xatlas/xatlas.h; optional_c_binding: source/xatlas/xatlas_c.h（被 xatlas.cpp include；保留以匹配上游构建，C API 可不调用）

未覆盖: 不是接缝/岛编辑 UI：没有显式 seam-edge 输入；input UV 只是 hint，normal/texture seam 仅作为 chart 生长权重; 不做多 UV 集编辑、UV 岛选择/合并/重投影、逐面独立 UV 优先级; 不做纹理绘制、法线/AO/高低模烘焙、纹理图层或 EXR/UDIM; 不是稳定拓扑/文档模型：输出是派生 UV/atlas，需自行保存选项、撤销和重开; 不解决材质、灯光、HDRI 或渲染外观

依赖: required: ; optional: ; examples_only_zh: source/thirdparty 包含 bgfx/imgui/eigen/libigl/embree/nanogui 等示例依赖；不得与核心一起复制; source/examples 和 source/test 仅用于上游示例/测试

许可义务: 保留 MIT 版权与许可声明（源码/二进制分发均需）。; 复制时保留 `xatlas.h`/`xatlas.cpp` 的 MIT 头，记录上游 commit 与本地补丁；不得整体改标为 MPL-2.0。; 源提供/relink：无。

平台证据: proof_level: source-only; no iOS build in this task; notes_zh: 纯 C++11，使用 std::thread/atomic/mutex；未在 iOS 编译。可拷贝为 2 个核心文件 + C 头；需自建后台任务与取消桥。

成本／接合: effort: low-medium; effort_zh: 低到中：约 8 KLOC 单文件对（上游 README 自述），MIT；但接缝/岛 UI 与多 UV 集是主要产品工作量。; cancellation_zh: `ProgressFunc` 返回 false 取消；内部使用线程，仍需在工作队列中运行并把结果回主线程。; memory_zh: 随网格、chart 数与 atlas 分辨率增长；大图集需预算/上限；本任务未实测。; undo_document_zh: UV/atlas 为派生数据；保留输入网格、seam/选项与版本，撤销回到旧 UV；不得原地破坏原 mesh。

[https://github.com/jpcy/xatlas](https://github.com/jpcy/xatlas/tree/f700c7790aaa030e794b52ba7791a05c085faf0c); commit `f700c7790aaa030e794b52ba7791a05c085faf0c`; [license](https://github.com/jpcy/xatlas/blob/f700c7790aaa030e794b52ba7791a05c085faf0c/LICENSE).

- License archive evidence/xatlas/LICENSE: SHA256 `2c16d5b1c2808277fe975b4f70f0fd9afc9b3bcf04e6c676665a82cb2d5579e3`.

#### mesh-opensubdiv / OpenSubdiv（细分曲面求值）

对应原编号：X02、X04。

许可证：LicenseRef-Tomorrow-OSTL-1.0。复用方式：native-library-shortlist。

建议：X02 细分曲面的条件性候选：先做许可证与 NOTICE 审阅，再以 CPU evaluator 做最小 control cage→refine→patch/stencil 验证；Metal 后端作为后续。它只是求值后端，不构成修改器栈/几何节点/编辑器。

可复用API／文件: headers: opensubdiv/far/topologyRefinerFactory.h; opensubdiv/far/topologyRefiner.h; opensubdiv/far/patchTableFactory.h; opensubdiv/far/stencilTableFactory.h; opensubdiv/osd/cpuEvaluator.h; opensubdiv/osd/mtlComputeEvaluator.h; api: OpenSubdiv::Far::TopologyRefinerFactory<MESH>::Create(mesh, Options{Sdc::SCHEME_CATMARK,...}); OpenSubdiv::Far::TopologyRefiner::Refine/RefineAdaptive; OpenSubdiv::Far::PatchTableFactory::Create(refiner, options); OpenSubdiv::Far::StencilTableFactory::Create(refiner, options); OpenSubdiv::Osd::CpuEvaluator::EvalPatches/EvalStencils; OpenSubdiv::Osd::MTLComputeEvaluator (Metal compute); algorithms: Catmull-Clark / Loop subdivision schemes; adaptive refinement and patch tables; stencil evaluation of positions/normals/primitive variables; CPU and Metal compute evaluators

未覆盖: 不是完整修改器栈：没有 Subdivision/Mirror/Bevel 等可重排栈、开关/顺序/控制笼编辑; 不是几何节点图：没有节点图、求值调度、资源/保存/UI; 不是编辑器：没有稳定顶点/边/面 ID、选择、撤销、文档事务; 不解决 UV 展开、重拓扑、雕刻、布尔、材质或渲染; 不是 Apache-2.0；不能按 Apache 标签或普通 Apache NOTICE 处理

依赖: required: ; optional: name: oneTBB; license: Apache-2.0; when: Osd TBB backend (NO_TBB=OFF); note_zh: 若启用需固定版本并随分发许可; name: OpenMP; license: compiler runtime; when: Osd OpenMP backend; name: CUDA / OpenCL; license: vendor/driver terms; when: GPU backends；iOS 不使用; name: Metal; license: Apple platform framework; when: iOS/macOS Metal backend; name: GLFW / GLEW / Ptex / OpenGL; license: separate upstream licenses; when: examples/tutorials only；不进入产品核心; examples_only_zh: examples/、tutorials/、regression/ 含 GLFW/GLEW/Ptex/OpenGL 依赖与示例资产；不得整体复制; 若只要 CPU：设置 NO_EXAMPLES/NO_TUTORIALS/NO_GLFW/NO_OPENGL/NO_PTEX/NO_TBB/NO_OPENCL/NO_CUDA; 若要 iOS Metal：保留 Metal backend，但仍应关闭示例/GL

许可义务: 随分发附 Tomorrow OSTL 1.0 LICENSE 与 NOTICE；保留版权/归属。; 修改文件需加显著变更说明（§4(b) 与 Apache 风格条款）。; 不得使用 Pixar/DreamWorks/Autodesk/Google/DigitalFish 商标/名称为产品背书；§6 限制。; 源提供/relink：无；但 MPL-2.0 分发下的兼容性/商标解释需法务确认（见 open_questions）。

平台证据: proof_level: source-only; no iOS build in this task; notes_zh: CMake 明确识别 IOS（跳过 GLFW/OpenGL）并有 Metal backend（mtlComputeEvaluator.mm/.metal）；仍未在本任务编译 device/arm64 simulator，也未验证 Metal shader 编译/运行。

成本／接合: effort: high; effort_zh: 高：Far/Osd 的 TopologyRefiner/PatchTable/StencilTable 生命周期、ObjC++/Metal 桥、shader 编译、控制笼与产品修改器栈都要自建。; cancellation_zh: 库未提供任务级取消；需按 patch/stencil 分块或外层作业取消，不能承诺单次细化即时中断。; memory_zh: stencil/patch table 随控制笼与细分级别增长；自适应可降低但需预算；未实测。; undo_document_zh: 控制笼、修改器顺序/参数与求值结果是文档状态；库不保存这些，需自建撤销/重开。

[https://github.com/PixarAnimationStudios/OpenSubdiv](https://github.com/PixarAnimationStudios/OpenSubdiv/tree/v3_8_0); commit `1d90921ea32b9dcae31d30b907cbacefc0c616bf`; [license](https://github.com/PixarAnimationStudios/OpenSubdiv/blob/v3_8_0/LICENSE.txt).

- License archive evidence/opensubdiv/LICENSE.txt: SHA256 `9211071ceaea05cec948f44a025ede3030f41506960d68b50e7ddb6edc2abe5b`.

#### mesh-meshoptimizer / meshoptimizer（网格简化/优化）

对应原编号：X06、X08。

许可证：MIT。复用方式：native-library-shortlist。

建议：X06 的首选：静态链接 meshoptimizer，使用 `meshopt_simplifyWithAttributes` 处理位置/法线/UV/材质权重，读取 `result_error` 报告偏差；保留原网格并以后台任务运行。它是简化算法，不是修复/重拓扑/UV 工具。

可复用API／文件: headers: src/meshoptimizer.h; api: meshopt_simplify; meshopt_simplifyWithAttributes; meshopt_simplifyWithUpdate; meshopt_simplifySloppy; meshopt_simplifyPrune; meshopt_optimizeVertexCache; meshopt_optimizeOverdraw; meshopt_buildMeshlets; algorithms: quadric-style edge-collapse simplification with target error/result error; attribute-aware simplification (positions + arbitrary attributes/weights); border lock / sparse / absolute error / prune / regularize flags; vertex cache/overdraw optimization and meshlet generation

未覆盖: 不是修复器/重拓扑/UV 展开/雕刻; 没有取消回调、异步或主线程调度；需外层作业系统; 不保证逐面材质/UV 接缝的语义保真；需要拆分/锁定或属性权重，并做产品验收; 不提供稳定拓扑 ID、撤销或文档模型

依赖: required: ; optional: ; examples_only_zh: demo/、gltf/、js/ 为工具/示例，不是库依赖

许可义务: 保留 MIT 版权/许可声明。; 若复制源文件，保留文件头与上游 commit，记录本地补丁；不得改标为 MPL-2.0。; 源提供/relink：无。

平台证据: proof_level: source-only; no iOS build in this task; notes_zh: 纯 C/C++、无平台代码；未在 iOS 编译。接入成本最低，适合先做组件级 arm64 device/sim 验证。

成本／接合: effort: low; effort_zh: 低：单头 + 少量 cpp；C ABI 便于 Swift/ObjC++ 包装；无需第三方。; cancellation_zh: 无内建取消；需分块/外层 worker，取消后丢弃结果。; memory_zh: 线性于顶点/索引；适合移动端；未实测。; undo_document_zh: 简化结果是派生 mesh；保留原 mesh、目标/误差/锁定参数，撤销恢复原数组。

[https://github.com/zeux/meshoptimizer](https://github.com/zeux/meshoptimizer/tree/v1.3); commit `9e1f07b159d3cb777f1c67ed31fc11fd117986f4`; [license](https://github.com/zeux/meshoptimizer/blob/v1.3/LICENSE.md).

- License archive evidence/meshoptimizer/LICENSE.md: SHA256 `f03037ca7bad1e3eb7f4a63fa6084a8baabd5ba30d3c239a9a7f35705d873e26`.

#### mesh-geometry-central / geometry-central（半边网格与几何处理算法）

对应原编号：X01、X03、X09、X05。

许可证：MIT。复用方式：audited-file-extraction。

建议：作为算法/数据结构参考与有限抽取候选：若 X01 需要半边工作网格，可评估其 MutationManager；若 X03 需要各向同性三角重网格，可评估 remesh。不要直接把它当作文档网格内核；稳定 ID、撤销和序列化仍是产品层。

可复用API／文件: headers: include/geometrycentral/surface/manifold_surface_mesh.h; include/geometrycentral/surface/mutation_manager.h; include/geometrycentral/surface/remeshing.h; include/geometrycentral/surface/parameterize.h; include/geometrycentral/surface/intersection.h; api: geometrycentral::surface::ManifoldSurfaceMesh; MutationManager::splitEdge/collapseEdge/flipEdge/splitFace/repositionVertex; remesh(ManifoldSurfaceMesh&, VertexPositionGeometry&, RemeshOptions); parameterizeDisk(ManifoldSurfaceMesh&, IntrinsicGeometryInterface&); selfIntersections/intersections; algorithms: half-edge mesh with element data containers; local topology surgery (edge split/collapse/flip, face split); isotropic triangle remeshing with curvature adaptation; disk parameterization (no general cut/seam solver); triangle-triangle self/intersection queries

未覆盖: 不是完整 UV：`parameterizeDisk` 只处理 disk-like 面，带 cut 的通用参数化在头文件中标记 TODO; 不是四边面重拓扑/体素重建/工业雕刻; 不是编辑器：无稳定 ID、选择、撤销、文档事务；MutationManager 会使旧 handle 失效; 不提供材质/纹理/灯光/渲染; 不是生产级 API 承诺；研究库，需自行固定行为与回归

依赖: required: name: Eigen; license: MPL-2.0; pin: 3.3.9 (geometry-central fetch default); license_file: path: evidence/deps/eigen/COPYING.MPL2; bytes: 16726; sha256: fab3dd6bdab226f1c08630b1dd917e11fcb4ec5e1e020e2c16f83a0a13863e85; name: happly; license: MIT; license_file: path: evidence/deps/happly/LICENSE; bytes: 1067; sha256: 7bc48d156b135363116a2d78e4c34ac9cd5932d4612a0e13b8738b3b02a621e7; name: nanoflann; license: BSD-3-Clause; license_file: path: evidence/deps/nanoflann/COPYING; bytes: 1482; sha256: f8efea042b89cc7534abf51888747f87595e1616c63f0b42a2ead81da34e0237; name: nanort; license: MIT; license_file: path: evidence/deps/nanort/LICENSE; bytes: 1097; sha256: cdee4c798446ed8b99398783154db2abbb3476d83d9ab31e5f1eb0b4ffb71208; optional: name: SuiteSparse; license: LGPL/BSD components; when: SUITESPARSE=ON and found; 默认 ON，可设 OFF; note_zh: 若启用需逐组件审计（CHOLMOD 等 LGPL）；产品首版建议 OFF。; examples_only_zh: docs/、tests/、tutorial 资产不属于库运行时

许可义务: 保留 MIT 版权/许可；依赖 Eigen MPL-2.0（保留其许可；修改 Eigen 文件需公开修改）。; nanoflann BSD、nanort MIT、happly MIT 的声明随分发保留。; 若启用 SuiteSparse，逐组件处理 LGPL/BSD 义务；首版建议关闭。; 源提供/relink：MIT/BSD 无；Eigen MPL 仅对修改文件有源提供义务。

平台证据: proof_level: source-only; no iOS build in this task; notes_zh: C++11 + Eigen；未在 iOS 编译。Eigen 模板会增大编译时间；无平台代码。

成本／接合: effort: medium-high; effort_zh: 中高：需要 mesh 转换、半边生命周期、Eigen/依赖、异常/内存策略；只抽取少量算法可降低耦合。; cancellation_zh: 无内建任务取消；remesh/求解需外层 worker 或分块。; memory_zh: Eigen 稀疏求解与半边结构随网格增长；未实测。; undo_document_zh: 拓扑操作会重排索引；必须自建稳定 ID 映射、快照/事务和撤销。

[https://github.com/nmwsharp/geometry-central](https://github.com/nmwsharp/geometry-central/tree/019669ddabda05e0f71fa3587cfb3c1dadf19cb8); commit `019669ddabda05e0f71fa3587cfb3c1dadf19cb8`; [license](https://github.com/nmwsharp/geometry-central/blob/019669ddabda05e0f71fa3587cfb3c1dadf19cb8/LICENSE).

- License archive evidence/geometry-central/LICENSE: SHA256 `e931ec5b3d7773b274a3a1122d486538c8da76d182cebeb852efaa051272df7d`.

#### mesh-geogram / Geogram（网格修复/重网格/参数化）

对应原编号：X05、X03、X09、M28。

许可证：BSD-3-Clause。复用方式：defer-or-reject。

建议：不作为当前产品库接入。核心 BSD-3 可用，但默认构建包含 HLBFGS（非商业）、TetGen（AGPL）、Triangle（商业限制）；且 repair/remesh 依赖 Geogram 核心/OpenNL/CVT，不能当小文件抽取。若未来 X03/X05 需要，先做“关闭受限组件 + 全依赖审计 + iOS 构建”的独立可行性验证。

可复用API／文件: headers: src/lib/geogram/mesh/mesh_repair.h; src/lib/geogram/mesh/mesh_remesh.h; src/lib/geogram/parameterization/mesh_LSCM.h; src/lib/geogram/parameterization/mesh_atlas_maker.h; src/lib/geogram/mesh/mesh_CSG.h; api: GEO::mesh_repair(Mesh&, MeshRepairMode, double); GEO::mesh_reorient / mesh_detect_colocated_vertices / mesh_detect_degenerate_facets; GEO::remesh_smooth(...) / mesh_adjust_surface(...); GEO::mesh_LSCM(...) / atlas maker; GEO::mesh_CSG(...) (builder/compiler); algorithms: vertex colocation, degenerate removal, facet reorientation, connectivity repair; isotropic/anisotropic CVT remeshing; LSCM/ABF parameterization and atlas packing (bundled xatlas); CSG builder/compiler

未覆盖: 不是编辑器/稳定拓扑/撤销/文档模型; 不是四边面重拓扑或工业雕刻 UI; 不保证修复后封闭/可制造；仍要检测+拒绝+复测; 默认构建的 HLBFGS/TetGen/Triangle 在当前策略下不可选：HLBFGS 非商业、TetGen AGPL、Triangle 商业分发需单独安排；不能把根 BSD 当作全部; 不解决 UV 接缝/岛 UI、材质、纹理或渲染

依赖: required_core: name: OpenNL; license: BSD-3-Clause; pin: git submodule https://github.com/BrunoLevy/OpenNL; note_zh: LSCM/线性求解使用；未在固定 Geogram commit 内嵌，需单独固定。; restricted_third_party: name: HLBFGS; license: non-commercial (quoted upstream README); default: GEOGRAM_WITH_HLBFGS=ON; evidence: geogram/src_lib_geogram_third_party_HLBFGS_README.txt; name: TetGen; license: AGPL-3.0 (upstream README); default: GEOGRAM_WITH_TETGEN=ON; evidence: geogram/src_lib_geogram_third_party_tetgen_README.txt; name: Triangle; license: custom: commercial distribution only by arrangement; default: GEOGRAM_WITH_TRIANGLE=ON; evidence: geogram/src_lib_geogram_third_party_triangle_README; name: xatlas; license: MIT; default: bundled atlas maker; evidence: geogram/src_lib_geogram_third_party_xatlas_README.md (not saved; tree path); permissive_examples: name: PoissonRecon; license: BSD-3-like (Johns Hopkins); evidence: geogram/src_lib_geogram_third_party_PoissonRecon_LICENSE.txt; name: zlib; license: Zlib; evidence: geogram/src_lib_geogram_third_party_zlib_LICENSE; name: Lua; license: MIT; evidence: geogram/src_lib_geogram_third_party_lua_README; examples_only_zh: graphics/viewer 依赖 GLFW/OpenGL/imgui；iOS 产品应设 `GEOGRAM_WITH_GRAPHICS=OFF`、`GEOGRAM_LIB_ONLY=ON`。

许可义务: 若使用核心：保留 BSD-3 版权/许可；不得删除版权。; 若构建默认 HLBFGS/TetGen/Triangle：非商业/商业限制在无授权时不可用；AGPL 需 combined-work 分发评估；当前策略不采用。; PoissonRecon/zlib/Lua/xatlas 等按各自许可保留声明。; 若未来采用 LGPL 组件/静态链接：评估 relink/source offer；非本次范围。

平台证据: proof_level: source-only; no iOS build in this task; notes_zh: 仓库含 android_utils 等平台代码；未在 iOS 编译。默认图形/第三方依赖需裁剪，不能直接作为 iOS 库。

成本／接合: effort: high; effort_zh: 高：大体积 CMake 工程、第三方裁剪、OpenNL 子模块、图形依赖关闭、iOS 未验证；文件级抽取会牵出 mesh/points/voronoi/NL 核心。; cancellation_zh: 有 Progress 机制但未验证任务级取消；需外层 worker 与超时。; memory_zh: CVT/参数化/大网格内存较高；未实测。; undo_document_zh: 库无文档事务；修复/重网格会重排索引，需稳定 ID 映射、快照和撤销。

[https://github.com/BrunoLevy/geogram](https://github.com/BrunoLevy/geogram/tree/v1.10.1); commit `bbcacba146b357926b5524111f56cc70c42182a7`; [license](https://github.com/BrunoLevy/geogram/blob/v1.10.1/LICENSE).

- License archive evidence/geogram/LICENSE: SHA256 `02e62718d092ae4c49ed0a09cc8cac710161d099ee612822ecd1ac01f552681d`.

#### mesh-openmesh / OpenMesh（半边网格/简化/细分）

对应原编号：X01、X02、X06。

许可证：BSD-3-Clause。复用方式：native-library-shortlist。

建议：条件性短名单：若 X01 需要半边“工作网格”，可在文档模型之外用 OpenMesh 做局部编辑/抽取，但不要把 OpenMesh 变成第二个文档内核。X02 的 uniform Catmull-Clark/Loop 可作对照/轻量方案；高质量细分仍优先 OpenSubdiv。

可复用API／文件: headers: src/OpenMesh/Core/Mesh/TriMesh_ArrayKernelT.hh; src/OpenMesh/Tools/Decimater/DecimaterT.hh; src/OpenMesh/Tools/Decimater/ModQuadricT.hh; src/OpenMesh/Tools/Subdivider/Uniform/CatmullClarkT.hh; src/OpenMesh/Tools/Subdivider/Uniform/LoopT.hh; src/OpenMesh/Tools/Smoother/LaplaceSmootherT.hh; api: OpenMesh::TriMesh_ArrayKernelT<Traits>; OpenMesh::Decimater::DecimaterT<Mesh> + ModQuadricT/ModHausdorffT; DecimaterT::decimate_to(size_t n_vertices, bool only_selected); OpenMesh::Subdivider::Uniform::CatmullClarkT<Mesh>::subdivide; OpenMesh::Subdivider::Uniform::LoopT<Mesh>; OpenMesh::Smoother::LaplaceSmootherT; algorithms: half-edge mesh with attributes and iterators; quadric/Hausdorff/aspect-ratio decimation; Catmull-Clark / Loop uniform subdivision; Laplacian smoothing

未覆盖: 不是编辑器：无稳定 ID/选择/撤销/文档事务; 不是完整修改器栈/几何节点; 不是 UV 展开/接缝/岛编辑、雕刻、纹理或渲染; 作为第二套网格内核会与 OCCT/Euclid 转换和索引生命周期冲突; 自适应细分、高质量工业细分不如 OpenSubdiv

依赖: required: ; optional: name: Qt; license: LGPL/commercial (Qt); when: BUILD_APPS=ON 的 GUI apps；不做产品 UI 时关闭; examples_only_zh: Apps/、Doc/、Benchmark/ 不属于核心库；只需 Core + Tools（Decimater/Subdivider/Smoother）。

许可义务: 保留 BSD-3 版权/许可；二进制分发在文档/通知中复现。; 复制文件保留文件头；记录上游 tag/commit 与补丁；不得整体改标 MPL-2.0。; 若 BUILD_APPS=ON，Qt 许可另行处理；产品应关闭。; 源提供/relink：无。

平台证据: proof_level: source-only; no iOS build in this task; notes_zh: 核心 C++11、CMake；上游有 macOS M1 构建，但没有 iOS 目标/验证。未在本任务编译。

成本／接合: effort: medium-high; effort_zh: 中高：需要 mesh 双向转换、属性映射、索引失效处理；若只抽取 decimater/subdivider 可降低。; cancellation_zh: 无任务取消；decimate_to 长循环需外层 worker/分块。; memory_zh: 半边结构 + 优先队列；随网格增长；未实测。; undo_document_zh: 拓扑操作会使 handle/索引失效；需稳定 ID 映射、快照、事务。

[https://gitlab.vci.rwth-aachen.de:9000/OpenMesh/OpenMesh](https://gitlab.vci.rwth-aachen.de:9000/OpenMesh/OpenMesh/-/tree/OpenMesh-11.0); commit `f13a3bf79f8dc91cd453b74baa9dc6f97a5a3062`; [license](https://gitlab.vci.rwth-aachen.de:9000/OpenMesh/OpenMesh/-/raw/OpenMesh-11.0/LICENSE).

- License archive evidence/openmesh/LICENSE: SHA256 `768e6051e5d7a62fd4b0a14c0ce753a65c08218ade8e85bd1927d48c5ed9b750`.

#### mesh-libigl / libigl（几何处理算法集；MPL2 + GPL 模块边界）

对应原编号：X06、X09、X05、X01。

许可证：MPL-2.0 (main) + GPL-3.0 (copyleft modules)。复用方式：audited-file-extraction。

建议：只按文件抽取 MPL-2.0 且依赖干净的算法（如 decimate/lscm/harmonic）；不要把 `include/igl/copyleft/**` 或 CGAL/TetGen/CoMISo 带入。优先 meshoptimizer/xatlas，libigl 作为算法补充。

可复用API／文件: headers: include/igl/decimate.h; include/igl/lscm.h; include/igl/harmonic.h; include/igl/copyleft/cgal/mesh_boolean.h; api: igl::decimate(V, F, target, cost_and_placement, ...); igl::lscm(V, F, b, bc, UV); igl::harmonic(V, F, b, bc, k, W); igl::copyleft::cgal::mesh_boolean(...)（GPL/CGAL 边界）; algorithms: greedy edge-collapse decimation (MPL2 file header); LSCM / harmonic parameterization (MPL2 file header; Eigen); CGAL-backed mesh boolean/self-intersection (GPL module)

未覆盖: 不是编辑器/稳定拓扑/撤销/文档模型; copyleft 子目录含 GPL；`mesh_boolean.h` 文件头虽写 MPL2，但模块依赖 CGAL（GPL），不能按单文件头判断可用; 无任务取消、内存预算或移动端调度; 不解决完整 UV 图集/接缝 UI、重拓扑、雕刻、材质/渲染

依赖: required: name: Eigen; license: MPL-2.0; license_file: path: evidence/deps/eigen/COPYING.MPL2; bytes: 16726; sha256: fab3dd6bdab226f1c08630b1dd917e11fcb4ec5e1e020e2c16f83a0a13863e85; optional: name: CGAL; license: GPL-3.0+/LGPL per package; when: LIBIGL_COPYLEFT_CGAL; GPL boundary; name: Embree; license: Apache-2.0; when: LIBIGL_EMBREE (permissive module); name: TetGen; license: AGPL-3.0; when: LIBIGL_COPYLEFT_TETGEN; reject; name: CoMISo; license: GPL; when: LIBIGL_COPYLEFT_COMISO; reject; name: Triangle; license: commercial restriction; when: LIBIGL_RESTRICTED_TRIANGLE; reject; examples_only_zh: tutorial/、tests/、python/ 不属于产品运行时

许可义务: MPL-2.0 文件：保留文件头与许可；修改这些文件需继续 MPL-2.0 并公开修改源；不得整体改标为其他许可或去掉 MPL 头。; GPL/copyleft 文件：当前未选入（当前分发策略）；若未来选入，需按 MPL-2.0 §3.3 做 Larger Work/Secondary License 组合分发评估，不能笼统称为普遍不兼容。; Eigen MPL-2.0 声明保留。; 源提供/relink：MPL 仅对修改文件；无 LGPL relink。

平台证据: proof_level: source-only; no iOS build in this task; notes_zh: 头文件 + Eigen；未在 iOS 编译。模板实例化/编译时间需评估；无平台代码。

成本／接合: effort: low per file / medium overall; effort_zh: 单文件抽取低；但 Eigen 模板、头文件依赖闭包、版本漂移与 GPL 边界审计会增加成本。; cancellation_zh: 无内建取消；需外层 worker。; memory_zh: Eigen 稀疏/稠密求解随网格增长；未实测。; undo_document_zh: 算法输入输出数组；文档/撤销由调用方负责。

[https://github.com/libigl/libigl](https://github.com/libigl/libigl/tree/v2.6.4); commit `7100764c2a2833284a8bdfa9b948d2b3bf124624`; [license](https://github.com/libigl/libigl/blob/v2.6.4/LICENSE.MPL2).

- License archive evidence/libigl/LICENSE.MPL2: SHA256 `fab3dd6bdab226f1c08630b1dd917e11fcb4ec5e1e020e2c16f83a0a13863e85`.
- License archive evidence/libigl/LICENSE.GPL: SHA256 `8ceb4b9ee5adedde47b31e975c1d90c73ad27b6b165a1dcd80c7c545eb65b903`.

#### mesh-cgal / CGAL（精确几何/包级 GPL-LGPL 边界）

对应原编号：M28、X05、X03、X06。

许可证：per-package GPL-3.0-or-later / LGPL-3.0-or-later。复用方式：study-or-explicit-external-only。

建议：仅作离线对照/算法参考或明确的 GPL 外部工具；当前策略不选入产品。需要 exact 参考时可读算法/测试；若未来复制/选入 GPL 包，需按 MPL-2.0 §3.3 做 combined-work 分发评估。`Kernel_23` 虽是 LGPL，但单独使用不足以覆盖 PMP/布尔/重网格。

可复用API／文件: headers: CGAL/Polygon_mesh_processing/*; CGAL/Surface_mesh.h; CGAL/Exact_predicates_inexact_constructions_kernel.h; api: CGAL::Polygon_mesh_processing::corefine_and_compute_boolean_operations; CGAL::Surface_mesh; CGAL::Exact_predicates_inexact_constructions_kernel; CGAL::Polygon_mesh_processing::isotropic_remeshing/simplify; algorithms: exact predicates/constructions; BRep-free polygon mesh processing; boolean/remeshing/simplification/parameterization

未覆盖: 不是产品可用的 permissive 库：多数有用包为 GPL-3.0+; 不是 iOS 友好/轻量依赖：编译时间、GMP/MPFR、模板体积; 不是编辑器/稳定拓扑/撤销/UV/雕刻; LGPL 包若静态链接仍需 relink/source offer；不能当作无义务

依赖: required: Boost (BSL-1.0); GMP/MPFR (LGPL) for exact kernel; Eigen (MPL-2.0) for some packages; package_licenses: package: Polygon_mesh_processing; license: GPL-3.0-or-later; file: evidence/cgal/packages/Polygon_mesh_processing/license.txt; package: Surface_mesh; license: GPL-3.0-or-later; file: evidence/cgal/packages/Surface_mesh/license.txt; package: Triangulation_2; license: GPL-3.0-or-later; file: evidence/cgal/packages/Triangulation_2/license.txt; package: AABB_tree; license: GPL-3.0-or-later; file: evidence/cgal/packages/AABB_tree/license.txt; package: Surface_mesh_simplification; license: GPL-3.0-or-later; file: evidence/cgal/packages/Surface_mesh_simplification/license.txt; package: Heat_method_3; license: GPL-3.0-or-later; file: evidence/cgal/packages/Heat_method_3/license.txt; package: Kernel_23; license: LGPL-3.0-or-later; file: evidence/cgal/packages/Kernel_23/license.txt

许可义务: GPL 包：当前未选入；若未来选入，需做 combined-work 分发评估（GPL 源码/许可/NOTICE/App Store 条款），不能笼统称为普遍不兼容。; LGPL 包（如 Kernel_23）：若静态链接需 relink/source offer；仍需法务确认。; Boost/Eigen/GMP/MPFR 等依赖分别保留许可。

平台证据: proof_level: source-only; no iOS build in this task; notes_zh: header-only 但模板/精确核依赖重；未在 iOS 编译。当前不作为产品候选。

成本／接合: effort: very high; effort_zh: 极高：GPL/LGPL 组合分发评估 + 编译/依赖/iOS 适配；当前策略不建议进入产品。; cancellation_zh: 无任务取消；需外层。; memory_zh: 精确核/模板开销大；未实测。; undo_document_zh: 无文档模型。

[https://github.com/CGAL/cgal](https://github.com/CGAL/cgal/tree/v6.2.1); commit `28811b671a12b5caa9e3688569dadbc6b3728fe6`; [license](https://github.com/CGAL/cgal/blob/v6.2.1/Installation/LICENSE).

- License archive evidence/cgal/Installation__LICENSE: SHA256 `fd3dff464988799c21f65397a314eb48eae8288a69ac512967b161e79b92d89e`.

#### mesh-meshlab-vcglib / MeshLab / VCGlib（GPL 研究边界）

对应原编号：X05、X03、X09、X06。

许可证：GPL-3.0。复用方式：study-or-explicit-external-only。

建议：仅作为 GPL 研究/对照：阅读算法与测试思路可以；当前策略不复制代码进产品。若未来复制/嵌入，需按 GPL-3.0 做 combined-work 分发评估（源码/许可/NOTICE）；若需要外部桌面修复工具，应作为独立 GPL 工具交付，并明确不在 App 内链接。

可复用API／文件: headers: vcglib/vcg/*; src/meshlabplugins/filter_mesh_repair/*; api: VCG mesh algorithms and MeshLab filter plugins（非稳定库 API）; algorithms: hole filling; self-intersection/repair filters; remeshing/decimation/parameterization filters

未覆盖: GPL-3.0；当前策略不选入；若复制/嵌入需做 combined-work 分发评估; 桌面 Qt 应用，不是 iOS 库; 无稳定产品 API/文档模型

依赖: required: Qt (LGPL/commercial); VCGlib (GPL-3.0); optional: ; examples_only_zh: 整个应用是 GPL 参考实现; vcglib: name: VCGlib; license: GPL-3.0; license_file: path: evidence/meshlab/VCGLIB_LICENSE.txt; bytes: 35141; sha256: 589ed823e9a84c56feb95ac58e7cf384626b9cbf4fda2a907bc36e103de1bad2

许可义务: 如复制/分发：GPL-3.0 全套义务；当前策略不采用。; VCGlib 同为 GPL-3.0。

平台证据: proof_level: not applicable; desktop GPL app; notes_zh: 无 iOS 目标；不评估构建。

成本／接合: effort: n/a; effort_zh: 不集成；只读研究。; cancellation_zh: n/a; memory_zh: n/a; undo_document_zh: n/a

[https://github.com/cnr-isti-vclab/meshlab](https://github.com/cnr-isti-vclab/meshlab/tree/MeshLab-2025.07); commit `dc48b91ae562756a6988048c5d5c7f1d2b687256`; [license](https://github.com/cnr-isti-vclab/meshlab/blob/MeshLab-2025.07/LICENSE.txt).

- License archive evidence/meshlab/LICENSE.txt: SHA256 `589ed823e9a84c56feb95ac58e7cf384626b9cbf4fda2a907bc36e103de1bad2`.

#### mesh-instant-meshes / Instant Meshes（场对齐四边面重拓扑；应用级）

对应原编号：X03。

许可证：BSD-3-Clause。复用方式：study-or-explicit-external-only。

建议：X03 的四边面重拓扑参考；BSD-3 允许未来做有审计的小范围算法抽取，但本轮因应用级 GUI/无库 API/TBB/nanogui 集成成本高而不嵌入。当前只读/或作为外部工具。

可复用API／文件: headers: src/field.h; src/extract.h; src/hierarchy.h; src/meshio.h; api: 无稳定库 API；核心函数/类在 .cpp/.h 中，GUI 驱动; algorithms: orientation/position field optimization; field-aligned quad extraction; multi-resolution hierarchy; mesh I/O

未覆盖: 不是体素 remesh、不是雕刻/UV/编辑器; 无库 API/稳定 ABI（成本问题，不是许可禁止）; GUI/OpenGL/TBB 依赖重，iOS 未验证; 不解决稳定拓扑/撤销/文档模型

依赖: required: name: Eigen; license: MPL-2.0; license_file: path: evidence/deps/eigen/COPYING.MPL2; bytes: 16726; sha256: fab3dd6bdab226f1c08630b1dd917e11fcb4ec5e1e020e2c16f83a0a13863e85; name: oneTBB; license: Apache-2.0; license_file: path: evidence/deps/tbb/LICENSE.txt; bytes: 11357; sha256: c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4; name: nanogui; license: BSD-3-Clause; license_file: path: evidence/deps/nanogui/LICENSE.txt; bytes: 2190; sha256: c769c30e257f0f3218986cceba127275bd326a39991cd7051b154194660b694f; name: pcg32; license: Apache-2.0; license_file: path: evidence/deps/pcg32/pcg32.h; bytes: 7548; sha256: 47273535c04686dea687f794e397ca36a62272a44dfe5e3467d32185f11c5dc8; note_zh: Apache-2.0 许可头（头文件内）; name: pss; license: BSD-3-Clause-like; license_file: path: evidence/deps/pss/LICENSE.txt; bytes: 1491; sha256: ae01c8f22c57b44797ec1b47cd24a06fe3756466d321c2b0117113bfcaee3e65; optional: ; examples_only_zh: resources/、datasets 不属于代码；GUI 依赖不能进入 iOS 产品

许可义务: BSD-3：保留版权/许可；修改/分发需保留声明。; Eigen MPL-2.0、TBB Apache-2.0、nanogui BSD-3 等分别保留。

平台证据: proof_level: not applicable; desktop GUI app; notes_zh: 未在 iOS 编译；OpenGL/GLFW/nanogui GUI 与 iOS 不匹配。

成本／接合: effort: high; effort_zh: 高：应用级代码抽取、GUI/依赖剥离、算法验证。; cancellation_zh: 无任务取消；GUI 交互式。; memory_zh: 多分辨率/场优化内存较高；未实测。; undo_document_zh: 无文档事务；需自建。

[https://github.com/wjakob/instant-meshes](https://github.com/wjakob/instant-meshes/tree/7b3160864a2e1025af498c84cfed91cbfb613698); commit `7b3160864a2e1025af498c84cfed91cbfb613698`; [license](https://github.com/wjakob/instant-meshes/blob/7b3160864a2e1025af498c84cfed91cbfb613698/LICENSE.txt).

- License archive evidence/instant-meshes/LICENSE.txt: SHA256 `a4b8fca34e796e6a25b38d4be0eb60a607ecc4e642e191e44eafaad3f4ba0dd0`.

#### mesh-meshlib / MeshLib（非商业许可；拒绝）

对应原编号：。

许可证：LicenseRef-AMV-NonCommercial-Trial。复用方式：defer-or-reject。

建议：拒绝进入产品：当前 LICENSE 是非商业 trial，禁止再分发/修改；若未来业务决定采购商业许可，再单独做技术与依赖审计。不要因仓库公开就当作 MIT/Apache。

可复用API／文件: headers: ; api: ; algorithms: 网格修复/布尔/重网格等（未评估，因许可拒绝）

未覆盖: 许可不允许当前分发/修改/再许可; 无商业许可授权; 未做依赖/技术评估

依赖: required: ; optional: ; examples_only_zh: 不评估

许可义务: 如使用：必须取得 AMV 商业许可并遵守其条款；当前无此授权。

平台证据: proof_level: not evaluated; license reject; notes_zh: 不进行 iOS 验证。

成本／接合: effort: n/a; effort_zh: 不集成。; cancellation_zh: n/a; memory_zh: n/a; undo_document_zh: n/a

[https://github.com/MeshInspector/MeshLib](https://github.com/MeshInspector/MeshLib/tree/v3.1.4.297); commit `8e821cd007891259914777e2a162b90a1e1964d6`; [license](https://github.com/MeshInspector/MeshLib/blob/v3.1.4.297/LICENSE).

- License archive evidence/meshlib/LICENSE: SHA256 `b1065bbe18e0ae0631aa83893690638f499c1ff8448527b28fa78cf63d4d50ff`.

#### mesh-sculptgl / SculptGL（MIT；WebGL 雕刻研究）

对应原编号：X04。

许可证：MIT。复用方式：study-or-explicit-external-only。

建议：仅作 X04 的交互/算法参考。固定 LICENSE 为 MIT（不是 GPL），未来可做有审计的小范围算法移植；但它是停止维护的 WebGL/JS 应用，不是原生库，本轮因成本/平台不嵌入。

可复用API／文件: headers: ; api: 无原生 API；JS 模块 `src/editing/Remesh.js`、`Subdivision.js`、`tools/Brush.js`; algorithms: sculpt brushes; voxel remesh; subdivision; masking

未覆盖: 不是原生 iOS 库；无 C++/Swift API（成本/平台问题，不是许可禁止）; 不是生产级雕刻/多分辨率文档模型; 项目停止维护（README）; 不解决 UV/材质/渲染/撤销事务

依赖: required: npm deps (MIT/BSD 等，需逐个保留); optional: ; examples_only_zh: standalone/Electron 包装不属于 iOS

许可义务: 若移植代码：保留 MIT 版权/许可；记录修改。; npm 依赖分别保留许可。

平台证据: proof_level: not applicable; WebGL app; notes_zh: 不能直接用于 iOS 原生；仅可参考算法/交互，或移植 JS 逻辑（需重写）。

成本／接合: effort: n/a (study); effort_zh: 研究/移植成本高；不进入本轮集成。; cancellation_zh: n/a; memory_zh: WebGL/JS 内存模型不同；不可直接比较。; undo_document_zh: 仅有应用级 undo；不能作为产品文档事务。

[https://github.com/stephomi/sculptgl](https://github.com/stephomi/sculptgl/tree/8e45dafc0f7906e5238dfffc1a2df742bd25f29d); commit `8e45dafc0f7906e5238dfffc1a2df742bd25f29d`; [license](https://github.com/stephomi/sculptgl/blob/8e45dafc0f7906e5238dfffc1a2df742bd25f29d/LICENSE).

- License archive evidence/sculptgl/LICENSE: SHA256 `99ae6fd4cab305bb78329327a2fce4c7a1fd986586d9ccd7cef3b7467f2c1167`.

### 动画／场景／渲染／输出

#### animation-R01 / 现有 Apple RealityKit / AVFoundation；SceneKit 仅保留现有适配

对应原编号：X18、X19、X20、X21、X22、X23、X24、X25、X27、X28、X29、X30、X31、X32。

许可证：Apple SDK terms; not open source。复用方式：A。

建议：先复用已有本地renderer、动画服务、AVAssetWriter；新功能不引入整套引擎。

可复用范围: RealityKit的变换/JointTransforms动画、blend tree、PhysicsBody/Motion、particles、orthographic camera；AVMutableComposition/AudioMix与原Writer；ImageIO帧序列。

API／文件: FromToByAnimation<Transform/JointTransforms>; BlendTreeAnimation; PhysicsBodyComponent / PhysicsMotionComponent / ParticleEmitterComponent; OrthographicCameraComponent; AVMutableComposition / AVMutableAudioMix / AVAssetWriter / AVVideoCodecType.hevcWithAlpha; 现Floe CADAnimationModel/Service/Timeline/Export和文档事务

边界: 这些是Apple SDK框架，非开源，不从SDK抽实现源码；按Apple开发者/SDK许可调用。; 既有SceneKit USDZ writer可维护复用，但官方WWDC25已soft-deprecated，不以SceneKit作为新动画/渲染主引擎。; 音视频素材、字体、纹理、编码相关权利不由框架调用许可统一覆盖。

未覆盖: 没有可交付的完整timeline/rigging/weights authoring；这些必须适配Floe稳定ID/保存/undo/LLM。; 实时PBR不是Cycles/path tracing；AVFoundation不解决ARView后台渲染。; Alpha要求renderer保留alpha且匹配codec/container，不能只换hevc枚举；当前MP4输入不自动支持。

待资格验证: 保留既有相机/实例播放模型权威，扩充typed tracks；scene graph和参数事务仍归Floe。; X28设置UI和X29音轨/图像序列先复用现平台服务；验证实际媒体轨道/alpha/时码。; X30持久化任务/checkpoints与X31renderer+evaluation issues完整性需要Floe实现，不能由新库替代。

平台证据: level: I3-existing_Floe_foundation + I2-official_API; proof: 官方DocC JSON：FromToByAnimation iOS15；PhysicsBodyComponent iOS13；particles/orthographic iOS18；hevcWithAlpha iOS13。已存official-pages并hash。新API未在Floe构建/运行。

Official platform APIs: https://developer.apple.com/documentation/realitykit/fromtobyanimation; https://developer.apple.com/documentation/realitykit/blendtreeanimation; https://developer.apple.com/documentation/realitykit/orthographiccameracomponent; https://developer.apple.com/documentation/realitykit/physicsbodycomponent; https://developer.apple.com/documentation/realitykit/particleemittercomponent; https://developer.apple.com/documentation/avfoundation/avmutablecomposition; https://developer.apple.com/documentation/avfoundation/avvideocodectype/hevcwithalpha; https://developer.apple.com/videos/play/wwdc2025/288/; https://developer.apple.com/support/terms/apple-developer-program-license-agreement/

#### animation-R02 / ozz-animation

对应原编号：X23、X24、X26。

许可证：MIT。复用方式：B。

建议：骨骼求值优先资格候选；链接完整最小runtime子库，避免抠出依赖math/allocator的零散job。

可复用范围: Skeleton/Animation采样、blend/additive、local-to-model、Aim/TwoBone IK、skinning；可选offline builder/optimizer。

API／文件: ozz_base; ozz_animation: sampling_job, blending_job, ik_aim_job, ik_two_bone_job, local_to_model_job, track_sampling_job; ozz_geometry: skinning_job; include/ozz/animation/runtime/*.h + src/animation/runtime/*.cc

边界: MIT，保留版权/许可；runtime README明确仅C++17与C/C++标准库。; samples/tools/tests有glfw/tinygltf/Fbx SDK/jsoncpp/gtest等独立依赖，不随core自动带入。; 初始关闭ozz_build_tools/fbx/gltf/samples/howtos/tests/data；FBX SDK不是MIT，若启用要另审；可用ufbx独立导入。

未覆盖: 有Aim/TwoBone IK，不是完整全身IK、rig authoring、paint weights或shape-key编辑器。; 无SwiftUI timeline/F-curve editor/NLA文档、Floe撤销存储、PBR灯光或视频导出。

待资格验证: arm64 device/simulator与Swift6 C/ObjC++边界、内存与确定性采样资格；import bindpose/joint order/units和渲染skinning对应验证。; 保留Floe文档ID/undo/数据模型，不另造骨骼动画编辑状态权威。

平台证据: level: I1-portability_source; proof: README明示macOS/Linux/Windows/WASM和ARM测试、runtime无OS-specific code；本轮没有官方iOS产物/本机编译证明，不将ARM声明写作iOS通过。

- [ozz / LICENSE.md](https://raw.githubusercontent.com/guillaumeblanc/ozz-animation/744eb9d99f606eda849acb0b1204f7a3dc20bca1/LICENSE.md); commit `744eb9d99f606eda849acb0b1204f7a3dc20bca1`; MIT; SHA256 `3ddd93e9888fe70b9d61675ceb1c4278a579dc67171678f015de114efe815852`.

#### animation-R03 / Jolt Physics

对应原编号：X27、E10。

许可证：MIT。复用方式：B。

建议：X27刚体及限定softbody/cloth资格候选；专业机构分析不据此结项。

可复用范围: 成熟碰撞/刚体/约束、ragdoll、softbody，官方明确soft ball/piece of cloth；可生成固定step状态缓存。

API／文件: Jolt CPU PhysicsSystem/BodyInterface/Constraints/SoftBody; Jolt/Jolt.cmake; Build/cmake_xcode_ios.sh; .github/workflows/build.yml

边界: MIT core；样例/Viewer/外部资源不在core许可证推导范围。; CPU首包关闭TARGET_SAMPLES/VIEWER/HELLO_WORLD/PERFORMANCE_TEST等非runtime目标，并禁JPH_USE_DX12/VK/MTL/CPU_COMPUTE可选ComputeSystem以避免无关shader toolchain。; 当前ComputeSystem打开Metal需dxc+spirv-cross+Metal toolchain；这不是普通CPU刚体的必要功能，不能把整默认开发构建视为最小core。

未覆盖: 有softbody/cloth底层支持；仍无Floe cloth authoring、pin/weight工具、缓存资产、undo和流体/CFD。; 跨平台deterministic为显式配置/验证事项，不自动保证浮点完全一致；不是E10载荷/高精度机构分析。

待资格验证: 固定时间步、mm↔m、mass/inertia/collider、snapshot replay/cancel和文档基线隔离；真实iOS性能/内存。; E10后续由工程owner评估Chrono等，不能以关节/rigid demo替代。

平台证据: level: I2-official_iOS_target_and_CI_definition; proof: 官方ios脚本与workflow以CMAKE_SYSTEM_NAME=iOS、iphonesimulator arm64构建；README注明签名样例默认simulator。不是本轮Floe device/runtime资格。

- [jolt / LICENSE](https://raw.githubusercontent.com/jrouwe/JoltPhysics/fb915d8a9c68c54159b4b626fb8d3739a410f8f0/LICENSE); commit `fb915d8a9c68c54159b4b626fb8d3739a410f8f0`; MIT; SHA256 `800abe35d64ad9defd636ff1ee8c961e06f0ebca3ef8d10083e8aa0e8ef86ac3`.

#### animation-R04 / Bullet Physics

对应原编号：X27、E10。

许可证：Zlib (core; exclusions explicit)。复用方式：B。

建议：Jolt的备选，不同时引入两套默认物理世界；保留已有成熟core复用可能。

可复用范围: BulletCollision/BulletDynamics/LinearMath以及可选BulletSoftBody；成熟刚体、约束、软体。

API／文件: src/BulletCollision; src/BulletDynamics; src/LinearMath; src/BulletSoftBody

边界: zlib核心；LICENSE.txt明确排除Extras与examples/ThirdPartyLibs，不能把整仓标为zlib。; 禁示例/OpenGL/OpenCL/PyBullet/Extras和可选TBB路径可缩小闭包；启用任何额外模块重新列SBOM。; 修改版本按zlib要求标记，保留源通知，不声称原作。

未覆盖: 不提供完整cloth/fluid产品编辑缓存、可视rigging、timeline或视频。; 通用物理约束不等于专业CAD机构/载荷求解。

待资格验证: 与Jolt只选一个实际资格切片作比较，保持同一Floe模型/单位/固定step合同；无需现在实施。

平台证据: level: I1-portable_C++_core; proof: 当前CMake与core源可检查；本轮未取得与当前iOS SDK/arm64 simulator匹配的官方资格产物。不能以历史iOS使用推定当前通过。

- [bullet / LICENSE.txt](https://raw.githubusercontent.com/bulletphysics/bullet3/d3afe76132fc76b0f9b2359cbaef47a3766e7fbb/LICENSE.txt); commit `d3afe76132fc76b0f9b2359cbaef47a3766e7fbb`; Zlib (core; exclusions explicit); SHA256 `885cd516a8420acb7c3e0b1a7119913b686495001ae564e3229740460e8cff59`.

#### animation-R05 / OpenUSD + Apple SwiftUsd

对应原编号：X19、X21、X23、X26、X29。

许可证：LicenseRef-Tomorrow-Open-Source-Technology-1.0 (Apache2 modified Section6); Apache-2.0 (wrapper only)。复用方式：B。

建议：场景/动画交换的独立资格候选；不是替换OCCT或Floe文档/undo，也不是免费获得renderer/编辑器。

可复用范围: UsdStage/Xform/Camera/UsdShade/UsdSkel/timeSamples/references，可承载对象层级与动画交换；SwiftUsd提供Swift-C++互操作。

API／文件: pxr/usd/usdGeom; pxr/usd/usdSkel; pxr/usd/usdShade; apple/SwiftUsd Package.swift + Swift binding overlay

边界: 当前OpenUSD LICENSE.txt为Tomorrow Open Source Technology License1.0，声明与Apache2区别在Section6商标；保留LICENSE与NOTICE，不能标标准Apache2。; SwiftUsd wrapper自身Apache2不覆盖其OpenUSD或所有XCFramework依赖。; OpenUSD Packages.cmake有Threads/TBB，成像/插件可加OpenSubdiv/OpenEXR/Imath/OpenVDB/MaterialX/OSL/Alembic/Draco等；每项按实际启用闭包取原许可。; SwiftUsd Package.swift有SwiftSyntax host宏依赖和大量binaryTargets；_TBB/_OpenVDB仅macOS条件，OsdCPU/GPU不含iOS，而UsdSkel/UsdPhysics含iOS。不能假设桌面/iOS feature parity。预构建二进制内容/内含licenses本轮未下载审计。

未覆盖: UsdPhysics是schema不是求解器；UsdSkel数据不提供权重画笔/IK编辑。; 没有完整timeline、CAD参数重建、AA/渲染器帧一致、Floe事务与工具权限。

待资格验证: 如立项，优先限制USD scene/timeSamples/Skel交换，单独Swift-C++ bridge target，核对每个所需schema/API及device/sim slices。; 固定真实binary/source与transitive license/hash，单独确认修改商标条款；不要把这次README审查当成完整artifact SBOM批准。

平台证据: level: I2-official_iOS_build_and_package_manifest; proof: OpenUSD README/build_usd.py官方iOS embedded route；SwiftUsd platforms macOS14/iOS17，Package实际iOS条件targets。无Floe本机构建/实际API完整性证据。

- [openusd / LICENSE.txt](https://raw.githubusercontent.com/PixarAnimationStudios/OpenUSD/2d39590aac6dde875507d2a334ff6e5b9dc05fe1/LICENSE.txt); commit `2d39590aac6dde875507d2a334ff6e5b9dc05fe1`; LicenseRef-Tomorrow-Open-Source-Technology-1.0 (Apache2 modified Section6); SHA256 `4d6e8e3a9bd0104e10c48e3bc6af2f0976448a70a377d20cef674740f96f4452`.
- [swiftusd / LICENSE](https://raw.githubusercontent.com/apple/SwiftUsd/74661a8c7d5247bb1e5c156749dcc1a60b677c9e/LICENSE); commit `74661a8c7d5247bb1e5c156749dcc1a60b677c9e`; Apache-2.0 (wrapper only); SHA256 `4cd13f7a31e98f51c4fb960a115e9a9ab9c42284ca5d5c9b5ccbcf322de45bfd`.

#### animation-R06 / Filament

对应原编号：X18、X19、X21、X23、X26、X29。

许可证：Apache-2.0 (plus separate third_party)。复用方式：B。

建议：仅在确认RealityKit的具体阻碍或跨平台renderer决策后考虑；不为时间线UI/导出设置更换renderer。

可复用范围: 成熟实时PBR/灯光/相机/post-processing；gltfio Animator可处理glTF节点/skin/morph动画。

API／文件: filament + backend + filabridge + filaflat + utils (+geometry/ibl as selected); libs/gltfio/src/Animator.cpp; ios/samples

边界: Apache2主项目，保留NOTICE/修改说明；third_party按实际闭包独立核对。; Metal路径不必拉bluegl/bluevk/Vulkan；gltfio、KTX/BasisU、cgltf、stb、draco、shader compiler等是可选/不同闭包，不能由root LICENSE一笔覆盖。; matc/cmgen是额外host工具与资源流水线；示例环境/纹理注明CC0但其他assets逐件审。

未覆盖: 实时渲染，不是路径追踪/Cycles；骨骼/morph播放不等于绑定/shape-key编辑。; 不提供Floe稳定scene IDs、undo、timeline authoring、后台恢复和完整性回执。

待资格验证: 只有限定功能收益可量化才做renderer适配；当前RealityKit原生路径保留优先。; 核对alpha/readback/material parity、device/sim、实际shader与texture许可证闭包。

平台证据: level: I2-official_iOS_samples_backend; proof: README写iOS11+、CAMetalLayer/createSwapChain、Metal首选；官方iOS目录和CI定义。未本机资格。

- [filament / LICENSE](https://raw.githubusercontent.com/google/filament/852ef6b7ace3241af435825a0a211ff60a14cd7a/LICENSE); commit `852ef6b7ace3241af435825a0a211ff60a14cd7a`; Apache-2.0 (plus separate third_party); SHA256 `02d70b593dd8e9355dd8e1ca8d13c303bee5bcaf3065b66ff6e4f534e1e6a2c1`.

#### animation-R07 / Standalone Cycles 与 Blender GPL代码边界

对应原编号：X18、X24、X25、X26、X27、X29。

许可证：Apache-2.0 (standalone module); GPL-3.0-or-later whole binary; inspected source headers GPL-2.0-or-later。复用方式：D/E。

建议：Standalone Cycles许可可单独评估；当前不推荐原生iOS接入。Blender编辑器/动画代码仅行为参考或用户明确选定外部工具流程。

可复用范围: Cycles Apache模块可用于成熟离线路径追踪；Blender完整工具可在用户选择的外部本地环境完成复杂authoring/render。

API／文件: cycles LICENSE + src/scene/session/kernel/device modules; Blender source/blender/animrig/intern/fcurve.cc; Blender editors/space_action/action_select.cc, editors/space_graph/graph_edit.cc, nodes/geometry

边界: 独立blender/cycles LICENSE与所查Metal实现header为Apache2；这不把Blender integration/editor变成Apache。; Blender整体发行GPL3+；所查fcurve/DopeSheet/GraphEditor/GeometryNodes代码header为GPL-2.0-or-later。不能抽出逐行翻译后改标MPL；MPL允许某些GPL Larger Work但会增加GPL分发条件，不满足本次保持当前分发条款的约束。; Cycles dependencies按配置包括OIIO/OpenEXR/Imath/Boost/TBB/可选OSL/Embree/OpenSubdiv/OpenVDB/OIDN等，各自许可不能被Apache主模块覆盖。; 外部进程不是自动合规豁免：GPL FAQ按通信语义/共享内部结构判断组合；分发Blender/scripts/bpy也有各自条件。

未覆盖: iOSCPU/GPU路径、依赖移植、shader编译/内存、热限制均无资格；不是换掉一个Metalview即可。; Blender timeline/geometry nodes依赖DNA/RNA/BKE/BLI/MEM/context/undo/UI，不能作独立小文件runtime。

待资格验证: 原生iOS保持E：没有成熟可证路线则列门槛，不自研新路径追踪内核。; 只有用户显式选定外部环境才作为D替代，使用标准资产/任务交付并单独审查分发/脚本和通信边界，不自动回退/上传。

平台证据: level: I0-no_native_iOS_proof_for_Cycles; desktop_Metal_only_evidence; proof: Cycles external_libs使用macos_x64/macos_arm64依赖；Metal util用MTLCopyAllDevices与macOS13可用性，device代码按macOS14特性分支。Metal字样不能证明iOS backend可用。Blender官方平台为桌面。

- [cycles / LICENSE](https://raw.githubusercontent.com/blender/cycles/3eb35f85996baa6c1b2e19bf297b22745c85e321/LICENSE); commit `3eb35f85996baa6c1b2e19bf297b22745c85e321`; Apache-2.0 (standalone module); SHA256 `8c6db340475136df3c1201d458fa5755698eace76e510471ecc9d857d6083dac`.
- [blender / COPYING](https://raw.githubusercontent.com/blender/blender/191de40eec962f5793cf81c0720e239d98c7858e/COPYING); commit `191de40eec962f5793cf81c0720e239d98c7858e`; GPL-3.0-or-later whole binary; inspected source headers GPL-2.0-or-later; SHA256 `19e6f4b541772f9d7b98a52bdbca3ebd5ef9e404956a9a6de68bfc3c1a178387`.

#### animation-R08 / Godot

对应原编号：X19、X23、X24、X25、X26、X27。

许可证：MIT (project/inspected code; third_party separate)。复用方式：C/D。

建议：优先借鉴/有界抽取MIT数学与轨道语义；不直接搬整个editor作为SwiftUI时间线。

可复用范围: 有成熟Animation/Bezier/blending/AnimationTree和iOS engine；可审核纯插值函数小切片，或独立完整工具环境。

API／文件: scene/resources/animation.cpp: bezier_track_interpolate/interpolation routines (needs dependency cut); editor/animation/animation_track_editor.cpp (reference, not standalone); platform/ios/detect.py

边界: MIT主代码，已查Animation/editor目标文件本身保留MIT头；COPYRIGHT.txt列第三方，整体引擎不是只需一张MIT。; Animation依赖Resource/Variant/ClassDB/Vector/NodePath；editor依赖EditorNode/UndoRedo/GUI/resource pipeline，抽文件仍拖大闭包。; 完整iOS模板还涉及Metal/Vulkan/MoltenVK等按实际配置额外依赖，样例/字体/资产不自动MIT。

未覆盖: MIT可用不代表时间线editor可直接切下来；完整引擎会引入第二套对象/资源/undo权威。; 无Floe参数/精确CAD建模与文档事务语义。

待资格验证: C只允许逐文件header/hash/依赖切片审核后的插值/Bezier等算法；保留MIT来源和修改记录，与Floe现Expr/undo结合。; 完整Godot runtime仅在独立架构决策后考虑，当前不作为主要iOSeditor接入。

平台证据: level: I2-official_iOS_target_not_editor_embed; proof: 官方iOS编译文档导出template_debug/template_release与xcframework；platform/ios/detect.py设备/模拟器分支。不是Floe UIKit/SwiftUI内嵌editor证明。

- [godot / LICENSE.txt](https://raw.githubusercontent.com/godotengine/godot/95c0fa5fe8a019adc29d074c16b64469b04571f7/LICENSE.txt); commit `95c0fa5fe8a019adc29d074c16b64469b04571f7`; MIT (project/inspected code; third_party separate); SHA256 `b0435e3b3e4e55238f05f4b306f30524a1b2e20147810d436eaa554fa6855c80`.

#### animation-R09 / Dear ImGui / ImGuizmo / ImSequencer

对应原编号：X24、X25。

许可证：MIT; MIT (including inspected ImSequencer headers)。复用方式：C/D。

建议：可审核抽取MIT控件/算法；原生iPad主时间线以参考语义和小范围数学为主，不直接替换SwiftUI。

可复用范围: ImGui即时UI、ImGuizmo 3D gizmo、ImSequencer区间/帧序列控件。

API／文件: ImGuizmo src/ImGuizmo.{h,cpp}; ImGuizmo src/ImSequencer.{h,cpp}; DearImGui imgui*.cpp/headers + backends/imgui_impl_metal.mm

边界: DearImGui LICENSE.txt MIT；ImGuizmo LICENSE MIT；所查ImSequencer.h/cpp均有自己的MIT版权头，不能仅按名称推测。; ImSequencer.cpp依赖imgui.h与imgui_internal.h；还需ImGui核心、Metal/input backend和各imstb头通知。不要带demo字体/资源而忽略各自许可。

未覆盖: 序列区间控件不是完整F-curve/DopeSheet/rigging编辑器；不保存Floe关键帧、不提供undo/LLM绑定。; 即时绘制UI的触控、中文输入、辅助功能、hit testing和坐标互通代价不能忽略。

待资格验证: 抽取仅限已审核源文件+必要依赖，固定pin；MIT通知保留；Floe稳定ID/事务/取消/undo由adapter提供。; 若引入完整ImGui面板必须独立产品UI决策；不能声称一个ImSequencer.cpp就关闭X25。

平台证据: level: I2-official_Metal_iOS_OSX_example_for_ImGui; I1-for_widgets; proof: DearImGui example_apple_metal README明确iOS/OSX；不等于ImSequencer触控/Pencil/VoiceOver/紧凑尺寸已验证。

- [imgui / LICENSE.txt](https://raw.githubusercontent.com/ocornut/imgui/1023d3ddaa75072806f6d11c7b434ed031ea14c1/LICENSE.txt); commit `1023d3ddaa75072806f6d11c7b434ed031ea14c1`; MIT; SHA256 `173506a2d6f7fb67990d257fb2507f188690eca39060c39469ae7bef43aae2a3`.
- [imguizmo / LICENSE](https://raw.githubusercontent.com/CedricGuillemet/ImGuizmo/105e4fde45e4e74aae8973d98750820ef7aca7e2/LICENSE); commit `105e4fde45e4e74aae8973d98750820ef7aca7e2`; MIT (including inspected ImSequencer headers); SHA256 `b957968be18bbc4fde7705cfcbda10bea1a71614e62361ace0473bb97dd0b700`.

#### animation-R10 / ufbx

对应原编号：X26、X29。

许可证：MIT OR Unlicense; choose MIT。复用方式：C/B。

建议：动画资产导入最紧凑候选：两文件或独立静态C库，显式选择MIT。

可复用范围: FBX scene/node hierarchy/animation curves/skin clusters/blend shapes求值与导入；有限OBJ读取。

API／文件: ufbx.c; ufbx.h

边界: LICENSE提供MIT或Unlicense二选一，本计划选MIT并保留版权/许可；不因PublicDomain选项丢来源。; 核心两个C文件无外部库依赖，不需要Autodesk FBX SDK；源码提供内存限制/进度/取消等可用钩子。; FBX文件/模型/贴图/动画的著作权及商标/格式事项独立；不要发布不明授权test assets。

未覆盖: 导入/求值，不是FBX exporter或完整rigging/weight paint/timeline编辑器。; 转换骨架/材质/动画到Floe/RealityKit/USD仍需单位、轴、bind pose、interpolation、morph语义适配。

待资格验证: C/ObjC++边界、恶意文件资源上限、cancel、稳定joint/node映射与真实FBX资产视觉/数值读回资格。; 保留动画数据源与derived mesh的关系，不能只导静态mesh后声称支持动画交换。

平台证据: level: I1-portable_C_clang_ARM_not_iOS_qualified; proof: 官方README为portable C/C++，CI覆盖macOS和LinuxARM等，但所列CI不包含iOS；本轮未编译。

- [ufbx / LICENSE](https://raw.githubusercontent.com/ufbx/ufbx/5955c5c0b042ac2dc6f32955ab206aaec0620cfc/LICENSE); commit `5955c5c0b042ac2dc6f32955ab206aaec0620cfc`; MIT OR Unlicense; choose MIT; SHA256 `0dd48ebadf52273c736256325c8f078c03c8bb4facee22a4122de0ad3f615391`.

#### animation-R11 / Assimp

对应原编号：X19、X26、X29。

许可证：BSD-3-Clause (main library; explicit asset/contrib exceptions)。复用方式：B。

建议：确需多格式时才采用，单一FBX优先比较ufbx的较小闭包。

可复用范围: 多格式scene/node/mesh/bone/morph/animation导入转换。

API／文件: include/assimp/anim.h; code/AssetLib selected importers; aiScene/aiNodeAnim/aiMeshMorphAnim

边界: BSD3主库，保留binary/source notice与不背书条款；LICENSE明确test/models-nonbsd模型另审。; 实际闭包可含zlib/minizip、rapidjson、pugixml、poly2tri、stb，可选Draco和USD导入tinyusdz等；每个contrib须按选中importer/config独立license/SBOM。; 禁未需要的importers/exporters/tests/samples与Draco/USD等可缩小体积，但不在本轮编译或宣称最小配置完成。

未覆盖: 不是skeletal runtime/authoring或动画资产保真保证；不同importer对材质/animation/morph支持不一。

待资格验证: 固定importer闭包、当前SDK device/sim、OOM/cancel/fuzz safety、animation时间/轴/权重/材质转换保真。; 完成实际transitive SBOM再准入；不能只看到BSD3根license就批准整包。

平台证据: level: I2-official_historical_iOS_script_not_current_validation; proof: port/iOS README有build.sh/XCFramework但仍列armv7/i386/x86_64/libstdc++旧选项；不足证明当前arm64 simulator/Xcode27完整支持。

- [assimp / LICENSE](https://raw.githubusercontent.com/assimp/assimp/3f7811b685231d2b3cb36ab38f11bdd2bca03b96/LICENSE); commit `3f7811b685231d2b3cb36ab38f11bdd2bca03b96`; BSD-3-Clause (main library; explicit asset/contrib exceptions); SHA256 `21195d410708b82757d3e34c3a40c427f6e59339da862e9480d4fcdc79b7a1bd`.

#### animation-R12 / FFmpeg

对应原编号：X28、X29、X30。

许可证：LGPL-2.1-or-later default; build flags/dependencies can change it。复用方式：B/E。

建议：AVFoundation已经能完成当前主要音视频需求，不为音轨/HEVC默认引入FFmpeg；仅额外codec/filter/外部环境确需时另评。

可复用范围: 成熟解复用/音视频编码、filter、音轨混合、图像序列等；适合用户选定外部环境或受限原生构建。

API／文件: libavformat; libavcodec; libavfilter; libswresample; libswscale; configure feature allowlist

边界: 默认组合LGPL2.1+；--enable-gpl或libx264/libx265等会转为GPL组合，--enable-version3影响LGPL3/GPL3；--enable-nonfree得到不可再分发binary，不能进入当前发行。; 静态iOS链接LGPL需要对应源/修改、许可证通知与用户重新链接/替换所需对象等具体履约材料；现OCCT relink材料不自动覆盖FFmpeg。; 外部codec/filter库许可与codec专利/素材许可另审；必须冻结configure、依赖/二进制/hash/SBOM，禁自动探测意外拉入库。

未覆盖: 不解决ARView后台出帧，也不提供3D渲染、timeline authoring、模拟缓存或X31模型完整性。

待资格验证: 先证明native功能确实不足，再做严格受限LGPL闭包资格；GPL/nonfree profile为本次license/distribution约束下E。; 如仅用户显式选择外部工具环境，单独处理工具分发/通信/媒体数据，不作隐藏fallback。

平台证据: level: I1-source_portability_only_in_this_review; proof: 官方LICENSE/configure/legal已核对，无选定arm64device/sim产物或Floe接入证据；不使用废弃第三方FFmpegKit包装当平台证明。

- [ffmpeg / LICENSE.md](https://raw.githubusercontent.com/FFmpeg/FFmpeg/a3c5339578cb1d54322e06b6bd1c8852fc6abc29/LICENSE.md); commit `a3c5339578cb1d54322e06b6bd1c8852fc6abc29`; LGPL-2.1-or-later default; build flags/dependencies can change it; SHA256 `e6dc72d5665a1ebd6dcc841de59278dad4ca77ecc47b03f1064a55c3e9ea8bb8`.

## 10. 交接与保留材料

本文件是统一人读入口，机器总账仅为支持数据。新增查看／视觉子验收保留原编号，不自动开启工具或关闭功能缺口。原始失败、源码／许可指纹及限定资格证据继续保留。文档交接不授权发布、变更根许可证、安装全部候选或改动另一线程工作树；下一实施者按本文件优先批、现有所有权及最新源码差异选择独立可验工作。

<!-- END CONSOLIDATED CONTENT -->
