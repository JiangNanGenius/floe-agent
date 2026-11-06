# FloeInteractiveContent — 独立预研模块

本包为聊天内交互内容提供可独立编译的核心与 WebKit 容器，供主线后续收取。当前不在 Floe 主 App 中注册，不改变既有模型、问答、权限或文件服务。

需求来源：docs/FLOE_CHAT_INTERACTIVE_CONTENT_QA_PLAN.zh-CN.md，CQA01–08。范围包括交互图表、信息讲解、即时试算、参数与过程演示、可点击界面预览；示例目录不限制模型生成其他内容。

## 产品与入口

- FloeInteractiveContentCore：版本化描述、有序内容引用、状态仓储合同、内存/文件适配、会话隔离、HTML 封装与导出、五种代表性内容。
- FloeInteractiveContentWebKit：原生 WKWebView 控制器与 SwiftUI 展示，脚本仅能报告 ready/state/resize。原生“继续分析”“保存”通过调用者提供的回调出现。
- floe-interactive-examples：向明确指定的绝对目录生成离线 HTML 和 JSON 数据文件。

采用 Swift 6、iOS/iPadOS 26+、macOS 15+。没有外部包依赖、在线 CDN 或模型账户要求。源码沿用仓库 MPL-2.0。

## 组件使用

    import FloeInteractiveContentCore
    import FloeInteractiveContentWebKit

    let owner = ContentOwner(
        conversationID: conversationID, runID: runID,
        messageID: messageID, contentID: contentID, contentRevision: revision
    )
    let document = try InteractiveDocument(
        owner: owner, kind: "parameter-explanation", title: title,
        html: verifiedHTML, fallbackText: textAlternative
    )
    let repository = try FileInteractiveStateRepository(directory: explicitStateDirectory)
    let session = try InteractiveSession(
        document: document, expectedOwner: owner,
        persistence: .durable, durableRepository: repository
    )
    let controller = InteractiveWebController(document: document, session: session)
    InteractiveContentView(controller: controller)

身份、修订和状态根目录由可信宿主提供。生产接入可用现有 SQLite 事务实现 InteractiveStateRepository；文件适配用于独立组件与显式选择的 sidecar，使用每内容文件锁、锁内重读/CAS和原子替换，不声称它已接上主 App 数据库。

临时聊天使用 persistence: .temporary。即使调用者误传文件仓储，临时会话也始终使用独立内存。服务结束/离开临时会话时调用 session.close()；后台/锁屏不等于离开聊天。Keep、删除和历史归属仍由主线现有事务服务统筹，组件不另做提升流程。

会话和 controller 应由所属聊天的服务/模型持有。重建或扩大时沿用同一 session；每个新 renderer 获得新 lease，旧实例消息失效。不要将同一个 WKWebView 同时挂在两个视图树上。SwiftUI surface 离开时 flush 后卸载文档，计时器随文档销毁；重新显示时恢复已提交状态。

保存失败时 hasUnsavedChanges 会提示，离屏和返回保留原页面中的输入，不自动销毁未提交草稿。存储恢复后再次编辑可提交；CAS 冲突不自动覆盖对方状态，主线可在用户明确选择后调用 discardUncommittedStateAndReload()。实际导航、删除或临时会话丢弃调用 controller.close()，立即隔离页面并由 session 处理存储生命周期；它与保留会话的 suspend() 不同。

## 内容脚本合同

    floeInteractive.ready(function (state) {
        // 从 state.privateContent 恢复输入/筛选，随后绑定交互。
    });
    await floeInteractive.setState({
        modelContent: { selectedScenario: "B", total: 2100 },
        privateContent: { slider: 20, expanded: true }
    });
    floeInteractive.onActive(function (active) {
        // 动画可以在 inactive 时先停下；宿主还会卸载文档。
    });

setState 是完整语义快照的保存请求：省略一个字段则保留该字段；传 null 则清空。快速更新会合并，Promise 在宿主确认提交后完成。输入控件、图表选区、草稿等需要由内容作者在交互时调用；组件不能推断任意 DOM/Canvas 的完整业务状态。不要在 ready/重载回调中自动保存或执行外部动作。

modelContent 是后续提问需要的简短 JSON，privateContent 是恢复界面需要的 JSON；每项不超过 32 KiB，嵌套深度不超过 20。宿主读取模型上下文时只选 modelContent，不能把整个页面或 privateContent 自动塞进提示词。库自身不会发起模型调用。

脚本没有文件、网络、账户、工具或问答提交接口。HTML 在仅 allow-scripts 的不透明源 iframe 内执行，外层受控脚本转发有界消息；原生入口核对主 frame、真实 WKWebView、当前 lease 和序号。WKContentWorld 不是 DOM 安全边界。页面只能改自己的 UI 状态，不能声明新的动作权限。

## 原生动作与导出

InteractiveContentView 的 onContinue、onSave 为可选原生回调。调用者应按内容类型和当前任务决定是否提供：

- onContinue 收到经保存屏障读取的状态，由主线将必要 modelContent 交给对应会话。
- onSave 收到自持资源/状态的 HTML Data，由主线现有文件/分享服务处理。
- controller.exportData() 生成不带会话身份的 JSON；controller.exportHTML() 导出的浏览器模式不调用原生桥。

导出的 HTML 支持离线本地交互，不依赖原聊天路径。它捕获当前状态；文件内继续操作保存在该页面运行期间的内存，不宣称重新保存浏览器文件或跨设备同步。原生图片/PDF、分享面板和个人文件区接线由后续主线完成。

## 主线集成位置

1. 复用 document.presentation.createInline 的工具注册、产物所有权与摘要，不凭任意 Markdown HTML 代码块激活内容。先验证真实产物路径/大小/digest，再构造描述。大内容用受验证文件引用，避免绕开现有 ToolCall 参数上限。
2. 在消息服务中建立 InteractiveResponsePart 的文本/交互/既有问题引用顺序，再由正文渲染消费。这个包不擅自识别文本占位符，不宣称已修改 AssistantMessageView 或 MarkdownBlockParser。
3. 用主线现有 user.ask / UserQuestionCoordinator / UserQuestionStore 解析 ExistingQuestionReference，保留逐题提交、取消、去重和恢复，不生成另一套 HTML 问答状态机。
4. 将状态仓储适配到所属聊天生命周期，沿用临时会话 incarnation、导航围栏与 Keep 原子事务。独立文件仓储不能替代主线业务事务。
5. 通过主线工程源配置引入本地 package 产品，按项目约定再生项目；随后完成真实模型、正文布局、扩大/返回、iPhone/iPad、保存分享与辅助功能验收。

主线接入时重新核对最新源代码。本轮既有路径研究基线为 0e26b0e0000054bf94e66c43d7fa6b63e1ac4bd2；库本身不依赖此提交的整个 App 构建图。

## 验证

将 scratch 放在主机缓存下，并串行使用同一目录：

    DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
    swift test --package-path /absolute/path/to/FloeInteractiveContent \
      --scratch-path /explicit/internal-ssd/cache --jobs 6

    DEVELOPER_DIR=/Applications/Xcode-27.1.app/Contents/Developer \
    swift run --package-path /absolute/path/to/FloeInteractiveContent \
      --scratch-path /explicit/internal-ssd/cache --skip-build \
      floe-interactive-examples /absolute/path/to/output

测试覆盖状态重开、真实跨实例 CAS、损坏记录保留、路径保护、临时 RAM、旧 lease/重复消息、离线导出，以及 macOS 原生 WebKit 中的子框交互、隔离和状态恢复。WebKit 测试用测试专属消息探针取得公开 WKFrameInfo，再用公开 frame-targeted JS API操作，不减弱 iframe 隔离，不使用私有接口。

资格结果、iOS 对象编译、失败保留、源文件哈希和收取说明见本轮交付记录。组件通过不等于完整 Floe App、真实模型或物理 iPad 验收。

iOS 泛目标编译可用 Scripts/compile_ios.py，必须显式指定内部缓存和证据目录；该脚本不启动 Simulator、不签名或发布。
