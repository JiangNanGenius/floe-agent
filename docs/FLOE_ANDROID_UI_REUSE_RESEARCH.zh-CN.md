# Floe Android：SwiftUI 与 iOS 视觉复用调研

日期：2026-10-18。状态：上游仓库、官方文档、发布元数据和实际Floe源码适配已核查；Cupertino 3.3.1独立小样在现有工具链编译通过，API37平板组件渲染/交互冒烟也已通过，产品接入与两渠道构建已完成。首轮独立审查结论为`fix`；同一批修正后经两轮定向复核，七项基础问题（G01-F01..G01-F07）在G01代表界面范围内全部关闭，最终结论`ship`。早期简化外壳与iPad界面差距明显，已作为历史反馈被替换，**不作为视觉对齐成果**；整体产品与未来页面仍需后续目标按同一方向实现，G14负责全页复核。

## 结论与执行顺序

找到了可以复用的项目，但已检查的项目中，没有经过本项目验证、能直接把整个Floe SwiftUI应用搬到Android并保证外观完全相同的替代品。源码复用、组件外观和平台服务是三个不同问题，必须分别验证。

本次选择 **Compose Cupertino维护分支3.3.1 + Floe页面/组件层** 作为代表页面的实现基础，已在设计系统接入并严格锁定。独立组件运行和两渠道构建已通过；首轮Floe手机/平板对照发现七项基础布局问题，同一批修正后经两轮定向复核全部关闭（G01代表界面范围）。**SkipUI不作为本轮整个App外壳的直接转换方案**：已核查的版本存在Floe必需容器的占位实现，且默认外观为Material3；以后可隔离的纯SwiftUI子树仍可按实际收益单独评估。保留已验证的Swift共享业务与Android原生服务边界。

G01先完成当前iPad参考、代表页面和组件选型；整体视觉、大布局、排版层级、控件样式及功能位置通过后再铺G02–G11。G14用于全页面复核与细节/性能收敛，不承担第一轮换组件、重做布局。

## 候选仓库与边界

| 项目 | 可直接复用什么 | 对Floe的判断与未验证事项 |
| --- | --- | --- |
| [SkipUI](https://github.com/skiptools/skip-ui) / [Skip](https://github.com/skiptools/skip) | SwiftUI兼容视图/状态接口、部分现有SwiftUI子树、Swift与Compose互操作 | 优先核算纯SwiftUI子树的真实收益。官方明确Android底层使用Material3，默认可使用动态色；源码共用不保证iOS外观。UIKit视图不受支持，不能因此原样搬PDFKit/PencilKit等宿主。已核查的主分支`NavigationSplitView`和`ContentUnavailableView`仍为占位实现，不能直接承载当前Floe外壳；新版玻璃和自定义输入也需平台适配。 |
| [Compose Cupertino原版](https://github.com/alexzhirkevich/compose-cupertino) | 基于Compose Foundation的iOS风格控件；包括按钮、表单、选择器等组件体系 | 适合减少控件重造，不提供整个Floe应用。GitHub当前未归档，但主分支最后提交为2025-10-05；不能仅因名称吻合就锁原版旧依赖。 |
| [RobinPcrd维护分支](https://github.com/RobinPcrd/compose-cupertino) | Cupertino组件、主题和部分后续修正；可通过Maven消费Android AAR | 当前优先验证候选。最新发布3.3.1，2026-03-09；元数据确认为Kotlin2.2.10，Compose Multiplatform依赖并非本工程当前BOM版本，现工具链下真实解析与编译已通过，运行与产品视觉另行验收。采用显式Cupertino控件，不能让Adaptive在Android自动返回Material样式。维护频率与新版材质覆盖仍需评估。 |
| [AndroidLiquidGlass / Backdrop](https://github.com/Kyant0/AndroidLiquidGlass) | Compose玻璃背景与折射效果、示例控件实现 | 可用于Floe对应的少数材质表面。官方明确库不包含高层组件，不能将效果库当作整套SwiftUI。需检查Kotlin/Compose要求、旧设备回退、滚动/输入性能和可读性；不为加入最新效果整体升级工具链。 |
| [OpenSwiftUI](https://github.com/OpenSwiftUIProject/OpenSwiftUI) | SwiftUI兼容实现的研究代码 | 当前README的Android状态为不支持；不进入Floe Android交付依赖。 |
| [SwiftCrossUI](https://github.com/moreSwift/swift-cross-ui) | Swift声明式跨平台UI与AndroidBackend | 官方明确不追求完整复刻SwiftUI API，各平台使用自身后端；不满足直接复用整个Floe界面且同样式的要求，暂不作为主UI方案。 |
| [Tokamak](https://github.com/TokamakUI/Tokamak) | SwiftUI兼容的浏览器等渲染体系 | 当前仓库已归档，缺少本项目所需的已验证Android原生路线，不选作主界面基础。 |
| [Flutter Cupertino](https://docs.flutter.dev/ui/widgets/cupertino) | 现成iOS风格控件 | 控件可复用，但不能直接消费Floe SwiftUI页面，会新增Dart UI及引擎集成；当前没有证据表明比现有Compose路线更省改造，保留为对照而非立即全量切换。 |

已通过浏览器查看维护分支的实际Web/Wasm组件演示：分组列表、搜索框、开关和底部导航确实采用iOS风格，并非仅README宣称。但该演示是组件目录，不能证明Floe多栏布局或Android运行效果，也不等于当前iPad新版材质。

上述维护状态来自本次GitHub API查询，不以星数作为可用性证据。具体版本固定应在代表页面验证通过后进行。

## 实际Floe源码给出的实现边界

本次核对的iOS来源为`2199859f`工作树；原先冻结的根界面/主题等五项文件哈希仍一致。具体实现应引用该批源码而非猜测SwiftUI默认行为。

- `FloeAgentApp.swift`的`iPadRoot`是稳定的两列`NavigationSplitView`，右侧检查器在详情内按需出现；不固定为三个并列页面。侧栏源码宽度最小260、默认320、最大460；检查器360/430/520，Android按逻辑尺寸与窗口适配对照。
- 侧栏包括固定入口、项目展开、会话列表与状态，设置通过底部齿轮打开独立设置页层。完整内容结构不能由几个导航文字替代。
- `ThreadComposerView`输入区圆角22，分隔描边0.5，水平/垂直内边距12/8；消息气泡圆角12、主色14%透明度。输入使用UIKit的自定义UITextView，有中文组合输入保护、快捷发送和紧凑6行/常规8行增长等行为，需要Android等效实现。
- 现有Floe视图还包含PDFKit、PencilKit、WebKit等原生宿主。直接共享Swift业务、路由/状态契约和视觉常量有价值；不能把Apple平台视图当作Android可直接运行的组件。
- 已检查SkipUI快照`f054c5f8`：`NavigationSplitView`初始化为`fatalError`、body为占位；`ContentUnavailableView`同样未渲染。这个结论针对本次修订，不据此否认未来版本或局部SwiftUI复用。

## 独立编译小样结果

`io.github.robinpcrd:cupertino:3.3.1`在Gradle9.6.0、AGP9.4.0、Kotlin Compose插件2.2.10、Compose BOM2026.09.00、compile/target37、min28下编译通过。实际用了显式Cupertino主题、分组行、开关、分段、文本输入、按钮和弹窗；未引入Adaptive、受限图标包或玻璃库。

依赖正常解析到AndroidX Compose1.12.1及Material3 1.4.0，无force/exclude、上游修改或工具链升级；未出现第二套JetBrains Compose运行时类。随后主负责人在API37 ARM64 Pixel Tablet AVD安装并实际检查：页面渲染、开关状态、分段选择、ASCII输入及输入法开关、弹窗打开/确认均通过，未观察到NoClassDefFoundError/NoSuchMethodError。该结果限于组件小样，不代表Floe布局、中文组合输入、深浅主题、大字号、重建恢复、旧设备及完整视觉验收。上游默认44dp交互尺寸也要在Floe封装中适配Android至少48dp的实际点击区。

小样为独立开发探针，未替换现有App、生产依赖锁或iOS源码；单个debug APK约32.4MB，不能据此估计完整Floe包体。冒烟结束后已移除仅含合成输入的探针安装，保留APK、源码和证据；之后已用相同控件接入Floe代表页面，首轮审查要求修正输入栏、设置分栏、实际点击区等七项问题；同一批修正后两轮定向复核全部关闭（最终`ship`），范围仅限G01代表页面。组件小样通过仍不等于产品通过。

## 可复用资产与依赖管理

- Skip当前已免费开源，不能沿用过去需要商业许可证或试用密钥的旧判断。SkipUI当前标示MPL-2.0；集成时保留所选修订的许可证与修改记录。
- Compose Cupertino核心代码为Apache-2.0。原版README另行说明`cupertino-icons-extended`包含受版权限制的SF Symbols；不把这一图标包或Apple系统字体直接打进Android。优先用Floe可分发资产或匹配的开放图标。
- Backdrop当前为Apache-2.0，固定版本后再检查其自身及传递依赖。不能因效果展示相似就宣称与Apple系统材质逐像素相同。
- 业务页面依赖Floe组件API，候选库只在设计系统/适配模块内接入。首批就定义侧栏、工具栏、输入区、列表/分组、菜单、表单、面板和状态表现，避免把上游API铺进所有功能页后再换库。

## G01代表页面验证

1. **建立真实参考**：记录实际iOS来源、版本/源码、窗口逻辑尺寸、主题、语言、字号、内容与状态。当前源码提取与参考截图分别记录；历史宣传图或单独读取FloeTheme不等于当前视觉验收。
2. **比较同一页面**：iPad导航侧栏、任务/项目区域、主工作区与输入区；设置中的分组、行、开关和弹层。手机同时检查收起/展开和键盘状态。未实现业务只作明确标注的预览样例，不伪装已完成操作。
3. **先验证复用接缝**：Skip只选实际使用、可隔离的SwiftUI子树；Cupertino只接代表控件，查明解析到的真实Compose依赖及ABI/运行结果。不得为完成对照破坏iOS工程或已通过的full/play和JNI边界。
4. **结构先通过**：区域位置与比例、内容密度、阅读宽度、字体层级、间距、按钮与列表几何、图标视觉重量、深浅主题。默认不启用改变品牌色的动态配色；系统授权弹窗保留真实Android界面。
5. **状态与交互**：选择/空态/错误/加载、输入法及中文组合输入、旋转与重建、滚动、Android返回、无障碍语义及至少48dp实际点击区；可见形状可以贴近iOS，不靠缩小点击区域达成。
6. **材质后验证**：在正确布局上比较少量玻璃表面；保持正文清晰。硬件或减少动态/透明设置采用可读回退；基础布局和组件不能因回退改变。
7. **输出选型记录**：同内容成对截图、差异对象、原因、采用的上游版本、必要适配及编译/设备结果。原样集成、局部源码复用、Floe自行实现分别标记。只有已验证选型进入后续功能页。

## 本次主要依据

- [SkipUI：实现方式、支持表、Material颜色和UIKit限制](https://skip.dev/docs/modules/skip-ui/)
- [Skip的下一代UI说明：iOS Liquid Glass与Android Material分别演进](https://skip.dev/blog/skip-next-gen-mobile-ui/)
- [Skip已免费开源公告](https://skip.dev/blog/skip-is-free/)与[许可证FAQ](https://skip.dev/docs/faq/)
- [Compose Cupertino原版README](https://github.com/alexzhirkevich/compose-cupertino#readme)、[维护分支README](https://github.com/RobinPcrd/compose-cupertino#readme)与[3.3.1发布](https://github.com/RobinPcrd/compose-cupertino/releases/tag/3.3.1)
- [Maven版本清单](https://repo.maven.apache.org/maven2/io/github/robinpcrd/cupertino/maven-metadata.xml)与[Android 3.3.1 POM](https://repo.maven.apache.org/maven2/io/github/robinpcrd/cupertino-android/3.3.1/cupertino-android-3.3.1.pom)
- [Backdrop当前README](https://github.com/Kyant0/AndroidLiquidGlass/tree/kmp#readme)
- [OpenSwiftUI支持平台表](https://github.com/OpenSwiftUIProject/OpenSwiftUI#supported-platforms)、[SwiftCrossUI后端说明](https://github.com/moreSwift/swift-cross-ui#backends)与[Tokamak仓库](https://github.com/TokamakUI/Tokamak)

本报告不把调研、依赖存在或组件演示当成Floe当前已完成UI复用。源码审计、独立编译和API37组件运行证据已保留；代表页面已集成并取得真实iPad成对证据；首轮`fix`、两轮定向复核结果与限制均已记录，七项基础问题在G01代表界面范围内关闭。G01最终关闭交接、G14全页复核和后续页面实现仍分别由主负责人、G14和各功能目标承担。
