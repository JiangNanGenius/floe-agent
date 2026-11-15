# 扶摇、Operit2、Rish、Lody 与 Floe 的本机交互对照

**回复下面默认只放一行「已更改 N 个文件」。** 点一下展开文件清单，再点具体文件才看内容。普通任务记下这轮实际改了什么。一个项目需要长期追版本时，使用工作区的 Git 仓库。用户始终在主对话补充要求，子任务由主模型调度。

对照日期为 2026-11-14。Floe 的原生交互依据为 iOS/iPadOS `main@35f28586d`。竞品依据为官方文档、示例与固定版本源码。配套原型使用虚构的讲义和练习单，可在本机浏览器打开。[可点的 Floe 交互稿](design/floe-chat-file-changes.zh-CN.html)

## 一轮回复之后怎么用

| 用户动作 | Floe 建议呈现 |
| --- | --- |
| 读完回复 | 只有这一行折叠摘要。这轮没有确认的文件变更时，回复到正文结束。 |
| 点「已更改 3 个文件」 | 在原位列出 `讲义.md　修改`、`练习单.md　新增`、`旧草稿.txt　删除`。同名时补上能区分文件的相对目录。再次点击收起。 |
| 点一个文件 | 已保存且能核对的本轮文本差异，显示「本轮差异」。只有工作区现有内容时，标明「当前文件」。如果是已交付的 PDF 或图纸，可复用那轮的产物预览。已删除又无旧内容时，仅显示删除记录。[差异与写入记录](../FloeAgent/Sources/FloeWorkspace/WorkspaceFileChangeEvidence.swift) · [产物预览](../FloeAgent/FloeApp/Chat/Render/RunOutputFileView.swift) |
| 看完接着说 | iPad 宽窗在右侧预览，聊天和草稿同时可见。iPhone 或 iPad 窄分屏用底部面板。关闭后回到刚点的文件，列表保持展开，主输入框里写了一半的话仍在。[Floe 分栏容器](../FloeAgent/FloeApp/App/FloeAgentApp.swift) · [会话草稿](../FloeAgent/FloeApp/Chat/ComposerDraftStore.swift) |

**怎样算一个文件。** Floe 目前的「变更」面板遍历整段会话，按能识别的工具操作逐条列出。同一轮内对同一工作区的同一路径写三次，只应在新列表出现一次。另一轮再改它，归到另一条回复。单纯读取、提出修改、失败写入、确认内容相同的保存，以及反复引用同一份产物，都不增加计数。终端或编辑器产生的改动同样需要能归属到本轮的文件记录，项目里其他人的未提交改动不能算进来。[现有变更面板](../FloeAgent/FloeApp/Workbench/TaskChangesInspectorView.swift) · [保存结果提示](../FloeAgent/FloeApp/Workspace/NativeSavedFilePreviewCard.swift)

**什么时候留版本。** 普通对话沿用现有的写入与产物记录，展示这份清单只需要文件身份、动作和该轮归属。为持续维护的项目保留里程碑时，在工作区的「源码管理」使用已有仓库，或点「初始化仓库」，挑选要暂存的文件后提交。查看一轮改动无需为所有文件复制旧内容，也无需每轮自动提交。[仓库入口与提交界面](../FloeAgent/FloeApp/Workspace/SourceControlView.swift)

## 四款产品各有哪一个交互值得拿来用

| 产品 | 在对方界面如何操作 | Floe 已经有什么，哪里值得改 |
| --- | --- | --- |
| **Lody** | 每轮结束，回复下给出当轮文件和增删行数，点文件直达对应差异。官方示例直接列出文件，另有整段会话的 Changes 视图。[官方图例](https://lody.ai/zh/docs/diff-viewer/) | Floe 已有整段会话「变更」、单次工具结果和文件预览。补上回复下的折叠入口即可把一次修改找回来。收起时只显示文件数，展开时给文件名和动作，用户点某个文件才进入细节。[会话变更](../FloeAgent/FloeApp/Workbench/TaskChangesInspectorView.swift) · [现有工具卡](../FloeAgent/FloeApp/Chat/ToolCallCardView.swift) |
| **Rish** | 同一段会话的文件和 Git 在宽窗右侧打开，窄窗改用底部面板。调整布局时沿用原有聊天记录和输入框。[工作区布局说明](https://github.com/ZSeven-W/rish-app/blob/3f6b40a537ed67694b384cc6299eecce1db8ae23/docs/gpui-migration.md#L37-L42) | Floe 的 iPad 已有按需打开的右侧栏。把从回复点开的预览放进同一块区域，iPad 缩到窄分屏也采用单栏返回。验收重点是切宽度、换看另一份文件、关闭预览之后，聊天位置和草稿都还在。[iPad 工作区](../FloeAgent/FloeApp/App/FloeAgentApp.swift) · [会话编辑状态](../FloeAgent/FloeApp/Chat/ComposerDraftStore.swift) |
| **Operit2** | 在 Markdown 链接和文件树中点同一份文件时，会在两个面板中查找已有标签。找到就切回去，保留正在编辑的草稿。[打开文件的实现](https://github.com/AAswordman/Operit2/blob/926e918ae58d6f56725d331b5e06fc7f1aeaf56b/apps/flutter/app/lib/ui/features/chat/components/workspace/WorkspaceSession.dart#L37-L83) | Floe 的工作区已有按路径激活标签、文本缓冲区和专用文件编辑器的机制。从变更列表选择「打开当前文件」时接到已有标签。例如一份已有手写改动的 Word 讲义，应回到用户正在编辑的那份。「本轮差异」则只供查看。[Floe 文件标签](../FloeAgent/FloeApp/Workspace/IDEWorkspaceTabs.swift) |
| **扶摇 Aether** | 在长对话里拖动轮次导航，能先看当轮提问与回复片段，再跳到那一轮。工具也可分别使用运行中、完成后两种自然语言标题。[按轮跳转](https://github.com/Zhou-Shilin/Aether/blob/b6681b8e5c7e738b91dc8982a0fc8ac1e2582d1d/shared/src/commonMain/kotlin/com/zhousl/aether/ui/ConversationTimeline.kt) · [工具标题](https://github.com/Zhou-Shilin/Aether/blob/b6681b8e5c7e738b91dc8982a0fc8ac1e2582d1d/docs/AETHER_EXTENSIONS.md#tool-titles) | Floe 已有会话内关键词查找、命中跳转和「回到最新」。可在现有会话菜单加一个「跳到提问」，列用户问题首句，忘了关键词也能找到前一版讲义。运行提示可在原工具卡上显示「正在整理讲义」「讲义已保存」。用户继续在主对话补充，调度交给主模型。[会话内查找](../FloeAgent/FloeApp/Chat/ThreadSearchBar.swift) · [消息跳转](../FloeAgent/FloeApp/Chat/ThreadDetailViewModel.swift) · [运行中输入](../FloeAgent/FloeApp/Chat/ThreadComposerView.swift) |

## 可以据此验收的三个场景

1. **改了三次，只算一份。** 一轮内先后改三次讲义，再新增练习单、删除旧草稿。最后一条回复只显示「已更改 3 个文件」。下一轮只问一道题的解释，回复下没有变更行。
2. **看旧回复时认得出当前文件。** 两轮都改了讲义。从第一轮打开保留下来的差异，看到第一轮记录。如果那轮仅有路径，打开现有文件时应标明「当前文件」。查看或关闭预览不触发 Git 提交。
3. **从文件回到同一句话。** 在主输入框写半句，展开文件列表、查看讲义、缩窄窗口、关闭面板，检查原草稿、已展开的列表与所选文件。需要补一句时发给主模型，由它决定后续工作。

已在本机浏览器实点原型的收起、展开、三种文件行、宽窗并排、窄窗底部面板、关闭返回及草稿保留。示例采用固定数据。本轮没有在原生 App 上验证逐轮统计，也没有修改 App 代码。[宽窗实图](design/floe-chat-file-changes-wide.jpg) · [窄窗实图](design/floe-chat-file-changes-narrow.jpg)

## 把 AI 的工作放回现有预览区

浏览器先行的实现边界见[任务浏览器独占控制计划](FLOE_BROWSER_CONTROL_PLAN_20261115.zh-CN.md)：第一次观察就取得控制，直到模型释放、运行结束或用户主动接管。

2026-11-15 对照 Floe iOS/iPadOS `main@4bcb5a2f33ae`。任务的右栏已有文件、修改、浏览器、终端、进度、子任务和权限七种内容；设计会话另有以产物为主、详情默认收起的预览页。现在模型请求人工操作时，若是当前会话，根视图会直接切到浏览器。用户主动接管的按钮却藏在浏览器的「更多」里。建议反过来：请求只改变状态，用户点击才切换自己的画面。下面是本机交互方案。[右栏入口](../FloeAgent/FloeApp/Shell/AppRouter.swift#L218) · [当前自动切换](../FloeAgent/FloeApp/App/FloeAgentApp.swift#L775) · [接管按钮](../FloeAgent/FloeApp/Browser/BrowserView.swift#L475) · [设计会话预览](../FloeAgent/FloeApp/Workspace/DesignConversationPageView.swift)

**一块主预览，一个按需出现的小窗。** 主预览标题始终是用户正在看的文件或页面。用户选中的讲义、页码、缩放、选区和手改草稿都归用户，AI 的进度不能换走它。AI 在同一任务里实际打开网页时，预览底边出现一扇只读小窗，显示当前页面局部、最近一次动作和点中的控件。小窗占自己的位置，内容可滚到它上方，键盘和批注工具不会被挡住。浏览器以外的短操作只更新一行文字；可供查看的结果出来，再交给原有预览。文件树、终端、完整进度和权限留在现有工具菜单。设计会话已有详情抽屉，用同一条状态即可，制作产物和任务浏览器继续各有自己的页面状态。Rish 的参考是面板随宽度变化时保住对话和草稿；Lody 的可取之处是从同一段会话看正在修改的页面。[Floe 宽屏右栏](../FloeAgent/FloeApp/App/FloeAgentApp.swift#L1439) · [Rish 布局](https://github.com/ZSeven-W/rish-app/blob/3f6b40a537ed67694b384cc6299eecce1db8ae23/docs/gpui-migration.md#L37-L42) · [Lody Preview](https://lody.ai/docs/preview/)

| 你看到或做的事 | 预览区的反应 | 网页由谁操作 |
| --- | --- | --- |
| AI 在网页点「30°」 | 小窗用动作对应的页面画面标出「30°」。你可以继续读讲义、选文字、打字。另一会话的工作不会出现在这里。 | AI |
| 点「放大观看」 | 在预览区放大这段画面，仍无网页输入。点「返回文件」回到原页和阅读位置；收起小窗也可以继续工作。 | AI |
| AI 碰到登录，或需要你选择 | 小窗改成「浏览器需要你操作」，说明具体原因。右栏收起时只更新一行；你方便时再打开。需要输入隐私信息时先撤掉缩略图。 | 浏览器相关步骤等待，其他已授权工作可以继续 |
| 点「我来操作」 | 先显示「正在接管」，停止派发浏览器动作，在途输入已结束或失效后再放行触摸、滚动和键盘。当前任务的同一标签交给你，可以直接操作。关掉面板、切文件或切会话都不会自动交还。 | 你 |
| 点「交还给 AI」 | 交接期间双方都不能点击。原任务从你留下的页面重新观察再继续，旧坐标和排队点击作废。如果原运行已结束，提供现有「继续任务」入口。失败则保留可重试的交接状态。 | 交接确认后归 AI |
| AI 改完讲义 | 小窗退场，回复下显示折叠的「已更改 1 个文件」。如果你还在读旧内容，原位提示「查看更新」；若正在编辑且有未保存改动，先保留草稿并比较两份修改。 | 文件阅读、选区和草稿仍归你 |

**宽窄窗口。** iPad 宽窗优先复用现有右栏。没有用户选定内容、右栏已打开且空闲时，可以直接显示 AI 的只读画面；一旦用户选文件就固定那里。右栏已被用户关掉时不自动重开。iPhone、iPad 窄分屏和读写空间不足时，只在输入区上方留一行；用户点开才展示观察或接管面板。如果当前是全屏编辑或正有其他系统面板，状态延后呈现，手势和输入焦点留在原处。VoiceOver 只播报需要你操作、交接成功或失败，逐次点击由用户按需查看。

**画面以真实操作为准。** 复用同一任务的浏览器会话。小窗显示只读的内存画面，接管时才挂可操作的网页。现有浏览器容器会把同一个 WebView 移到新容器，在两个位置同时挂它会把网页从用户手边抽走。已有的点击事件只记录动作类型，不能单凭它说点了「30°」；需要在实际操作处采集对应页面和视口下的目标位置，并与其画面对齐。布局变化、切页、结果未确认或截图拿不到时，清除点位，改为「正在加载」「已尝试点击」或只显示动作文字。小窗收起或 App 退后台时停止取画面，普通浏览不生成逐帧文件或 Git 提交。[浏览器容器](../FloeAgent/FloeApp/Browser/BrowserView.swift#L541) · [点击事件](../FloeAgent/FloeApp/Browser/BrowserTaskSessionStore.swift#L943) · [浏览器协议](FLOE_BROWSER_PROTOCOL.md)

**接管绑定到这次任务。** 当前实现已有以任务为单位的接管、浏览器写操作拦截、交还去重和旧页面引用失效。原生接入还需覆盖在途动作、地址栏和标签控件、任务切换后的迟到画面。个人接管期间停止旁观取帧，登录、验证码及个人表单只在用户控制的原页显示；如果需要隔离页面读取，现有接管状态仍允许部分只读工具，这个入口也要一起处理。首版优先跑通浏览器，再把同样的位置用于 PDF 页码和有可靠结果的文件编辑。[浏览器操作检查](../FloeAgent/FloeApp/Browser/BrowserTaskSessionStore.swift#L545) · [交还与原任务恢复](../FloeAgent/FloeApp/Browser/BrowserSessionCenter.swift#L621) · [工作区冲突处理](../FloeAgent/Sources/FloeWorkspace/WorkspaceEditConflict.swift#L68)

**可点的本机示例。** 打开后先在聊天里写半句话，观察 AI 点选角度；点「我来操作」选择 15°，回文件，再回浏览器交还。完成时查看当轮差异。浏览器中已实点宽屏的焦点保持、只读观看、主动接管、个人页隐藏、显式交还、讲义手动更新和文件计数，也试过窄屏收起重开仍保留控制权。示例的数据与动作在页面内演示，尚未接入原生 WebKit，实际取帧、点位同步及在途操作交接属于原生验收。[协作预览交互稿](design/floe-preview-collaboration.zh-CN.html) · [宽窗图](design/floe-preview-collaboration-wide.jpg) · [窄窗图](design/floe-preview-collaboration-narrow.jpg)

## 其他本机入口备选

- **普通项目的起步模板。** Operit2 的网页、Python 等工作区可以带入入口文件和项目配置。Floe 普通工作区已有选目录、IDE 运行和本机网页预览，LaTeX 也已有专用模板。可以先试一个“静态网页”模板，创建后直接打开可编辑首页，让用户改一个标题便能在这台设备上看到结果。[Operit2 模板创建](https://raw.githubusercontent.com/AAswordman/Operit2/926e918ae58d6f56725d331b5e06fc7f1aeaf56b/core/crates/runtime/application/src/ui/features/chat/webview/workspace/WorkspaceUtils.rs) · [Floe 工作区选择](../FloeAgent/FloeApp/Workspace/WorkspacePickerView.swift) · [本机网页预览](../FloeAgent/FloeApp/Workspace/IDEWebServiceView.swift) · [LaTeX 模板](../FloeAgent/Modules/FloeLaTeXKit/Sources/FloeLaTeXCore/Templates.swift)
- **从 Android 系统“文件”打开项目。** 扶摇将 Alpine 工作区列为系统文件选择器的来源。Floe Android 已能把指定文件交给外部编辑器并核对回写。对习惯先打开其他编辑器的用户，可让他们从系统选择器浏览自己指定的 Floe 项目，再选要打开的文件。[扶摇 Android 文件入口](https://github.com/Zhou-Shilin/Aether/blob/b6681b8e5c7e738b91dc8982a0fc8ac1e2582d1d/README_zh.md) · [Floe 外部编辑](../FloeAndroid/app/src/main/kotlin/com/floe/android/host/externaledit/ExternalEditController.kt) · [文件回写](../FloeAndroid/core/safgateway/src/main/java/com/floe/android/safgateway/SafWorkingCopyService.kt)
- **旧会话里的模型被移除。** Rish 在原处提示旧模型已不可用，用户可以带着原草稿选择替代模型。其上游记录覆盖 Android 的离线冷启动，iOS 记录到构建和启动。Floe 也有会话草稿与模型恢复逻辑，可在发送处提示实际要使用的模型。[Rish 验收记录](https://github.com/ZSeven-W/rish-app/blob/3f6b40a537ed67694b384cc6299eecce1db8ae23/docs/p0-model-retirement-2026-11-10.md) · [会话模型恢复](../FloeAgent/FloeApp/Chat/ThreadDetailViewModel.swift)
