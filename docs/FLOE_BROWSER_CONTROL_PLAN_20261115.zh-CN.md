# Floe 任务浏览器：从第一次观察到交还

本机任务浏览器已接入按运行持有的控制权。模型首次观察或操作页面时取得控制权，连续调用之间保持持有。模型可调用 `browser.release` 释放，运行结束时由服务释放，用户也可随时接管。三种操作都会保留当前页面和标签。

## 设计基线（2026-11-15，`4ce3cd264`）

| 入口 | 实际行为 | 这次要补什么 |
| --- | --- | --- |
| 模型工具 | 原生 App 把 21 个 `browser.*` 工具同时注册到目录和执行器。普通命令由运行时提供任务 ID，找到该任务的浏览器；送进执行器的命令有会话和标签身份，没有持有控制权的运行身份。工作流已教模型先观察、用页面引用操作。 | 保留现有工具。把实际调用者带到浏览器，补上 `browser.release` 及其发现和使用说明。[工具注册](../FloeAgent/FloeApp/Browser/BrowserTools.swift#L1381) · [命令入口](../FloeAgent/FloeApp/Browser/BrowserTools.swift#L380) · [模型指引](../FloeAgent/Sources/FloeAgentRuntime/ToolWorkflowGuidance.swift#L21) |
| 用户接管 | 已有任务级人工接管、交还通知和旧页面引用失效。现在人工接管仍放行 `observe`、列标签、事件、链接、表格和正文；列标签本身也会生成页面观察结果。当前测试明确期望 A 被人接管后，模型还能读到 A 的文档 ID。 | 保住任务隔离、交还通知和去重；人工操作时，模型连页面都读不到。[现有放行分支](../FloeAgent/FloeApp/Browser/BrowserTaskSessionStore.swift#L559) · [相反的旧断言](../FloeAgent/Tests/FloeAppTests/BrowserTaskSessionTests.swift#L594) · [交还流程](../FloeAgent/FloeApp/Browser/BrowserSessionCenter.swift#L621) |
| 右侧浏览器 | 显示的是真实 `WKWebView`。地址栏、刷新、前进后退和标签可直接操作；「接管浏览器」在更多菜单里。模型请求人工操作时，当前任务可自动切到浏览器。 | 网页输入和工具栏服从同一份控制状态；把「我来操作」提到看得见的位置。打开观看与取得操作权分开。[网页容器](../FloeAgent/FloeApp/Browser/BrowserView.swift#L133) · [原生导航](../FloeAgent/FloeApp/Browser/BrowserView.swift#L401) · [面板路由](../FloeAgent/FloeApp/App/FloeAgentApp.swift#L775) |
| 生命周期 | `activeExecutionCount` 只覆盖一次命令；空闲回收也看这个计数。现有 `BrowserTaskSession.release()` 停下载、拆 WebView、清标签；任务的 `discard` 还会清交还记录。 | 新增“只交回控制权”的操作。正常交还、单轮结束都不能调用上述销毁路径。活跃持有人在两次调用之间也不应被当作空闲回收。[命令计数与销毁](../FloeAgent/FloeApp/Browser/BrowserTaskSessionStore.swift#L519) · [容量回收](../FloeAgent/FloeApp/Browser/BrowserSessionCenter.swift#L293) · [任务销毁](../FloeAgent/FloeApp/Browser/BrowserSessionCenter.swift#L705) |

## 一张页面，同一时刻只有一方能操作

控制范围是**当前任务的整个浏览器会话**。切换标签会改变后续观察的目标，所以不能按单个标签上锁。任务 A 和任务 B 各自独立；工具箱的[个人浏览器](../FloeAgent/FloeApp/Space/Toolbox/ToolboxBrowserOwner.swift#L8)照常由用户操作。

| 当前状态 | 发生什么 | 接下来谁能操作 |
| --- | --- | --- |
| 空闲 | 模型首次调用观察、导航、列标签、截图等，且有权执行 | 在首次创建标签、读页面或派发动作**之前**，原子地把该会话交给本次运行。模型直接调用原工具，无需先调 `acquire`。 |
| 空闲 | 用户直接点网页、滚动、在地址栏开始输入或操作标签 | 第一笔实际输入先登记人工控制再放行；键盘仍有焦点或输入法正在组字时，模型不能取走页面。仅打开或放大观看不占用。同一时刻发生争用时优先处理接管，触摸不穿透。 |
| AI 操作中 | 同一运行继续调用、等待模型、切去处理文件，或用户收起右栏 | 控制权不变。同一浏览器的调用依次执行。另一运行收到「浏览器正由其他运行使用」，不排队等着抢回；用户仍能看、写聊天、编辑其他文件。 |
| AI 操作中 | 模型显式释放，或持有它的本次运行结束 | 变为空闲。保留标签、登录状态、当前页和滚动位置。用户可直接接着用；模型以后确有新操作时可重新取得控制。 |
| AI 操作中 | 用户点「我来操作」，或模型通过现有 `browser.panel(requestUser)` 请求人处理 | 先撤销模型继续派发的资格，再交给人。同一标签留在原处。交接中显示「正在接管」；此时新的模型观察、截图和点击一律不执行。模型请求协助时不自动把用户正在看的文件换走。 |
| 你在操作 | 模型再调浏览器；用户关闭面板、切聊天，或原运行结束 | 保持人工控制。模型得到 `needsUser`，没有页面、截图和事件；可以做其他已授权工作，不循环重试。原运行结束也不能把人踢下线。 |
| 你在操作 | 用户点「交还给 AI」 | 停止人工输入，作废之前的页面引用和视觉证据，按原任务、原运行投递一次交还通知。仍在运行的模型先重新 `observe` 再动手；原运行已结束则提供「继续任务」，不自行启动新任务。如果是用户在空闲浏览器上开始操作、从未有模型持有人，结束后只回到空闲。 |

**例子。** 模型正在看一个表单，点了「15°」，停下来思考。你可以继续在聊天里打字，小窗仍显示刚才的动作。你点「我来操作」，自己改成「30°」；这时模型既不能点回去，也不能读你正在填的值。你交还后，它重新观察到「30°」，从这个状态往下做。模型最后释放时，页面还停在这里。

## 工具链怎样接

1. **把控制状态放在任务浏览器服务。** 由 `BrowserSessionCenter` 和它持有的 `BrowserTaskSession` 统一处理模型、原生界面和回调。锁以任务和浏览器会话为范围，持有人绑定运行时签发的主运行身份、本次执行及控制轮次。普通调用从 [ToolContext](../FloeAgent/Sources/FloeTools/ToolContext.swift#L87) 取身份；不要由模型传入，也不要从当前可见会话或“最近一次运行”猜。主模型仍负责调度：已有[受托调用身份](../FloeAgent/FloeApp/Browser/BrowserTools.swift#L363)校验通过后，受托动作可代表主运行排入同一序列；主运行负责释放，子调用结束不释放主运行的浏览器控制权。用户主动接管时，把真实持有人的原运行写入交还通知；目前的[最近运行回退](../FloeAgent/FloeApp/Browser/BrowserSessionCenter.swift#L592)不能充当证明。
2. **先判定能否执行，再原子取权。** 参数、任务权限、取消状态及适用的提供方授权先检查；等待授权本身不占住页面。在查会话、必要时创建第一个 WebView 和开始读取之间不能插入另一个持有人；已经交给人的会话从这里直接返回 `needsUser`。还要读页面才能判断的条件（例如旧元素引用）在取权后复核。单步失败或超时不会把整个浏览器交给别人；运行拿到的控制标记仍可用于释放。临时聊天及仅限公共网页的模式保持原有限制。
3. **只给模型加一个工具：`browser.release(controlID)`。** 每个取得控制的工具结果附同一段操作的轻量标记；只在释放时需要传它，普通点击、读取不多一个参数。工具校验真实调用者与标记。重复释放同一段无副作用；即使同一个运行已经再次取得控制，旧标记也不能释放新的持有期。交接或重新取权后，涉及元素或点位的动作必须有新证据。没有现存页面时不创建浏览器，用户持有时不替用户交还。

   同步接入工具目录、执行器、[模型实际收到的工具定义](../FloeAgent/Sources/FloeAgentRuntime/AgentRuntime.swift#L3360)和[内置浏览器指引](../FloeAgent/Sources/FloeSkills/BundledDomainSkills.swift#L135)。现有[任务策略](../FloeAgent/FloeApp/Remote/ConversationCenter.swift#L4500)会筛掉浏览器工具。持有期间，要把只对当前主运行有效的标记和释放定义留给其下一次推理，包括上下文压缩后；不能借释放工具取得页面权限。用完即释放，遇 `needsUser` 等交还。列工具、查工具说明、查协议版本只返回静态信息，不取权。释放自己的持有期不弹额外确认。
4. **所有实际接触同一浏览器的入口都经过同一判断。** 除常规命令和协议分发外，[`observe(profile: design)`、导出和下载](../FloeAgent/FloeApp/Browser/BrowserTools.swift#L67)、Cookie、网页存储与站点数据都有专用路径。[本地预览](../FloeAgent/FloeApp/Browser/LocalPreviewServer.swift#L185)会导航、刷新，取消时还可能尝试恢复旧页；[设计取页](../FloeAgent/FloeApp/Workspace/DesignAdapters.swift#L893)会观察真实标签。标清调用来自模型、用户还是服务清理，模型一律经过同一入口，清理也不能绕过新持有人重新导航。`web.fetch` 和 `http.request` 仅在显式借用[任务浏览器 Cookie](../FloeAgent/FloeApp/Browser/BrowserSessionCenter.swift#L779)时纳入，校验覆盖传出请求与结果返回。普通公开请求、纯文件服务不用这把锁。`panel.hide` 只是显示动作，不能关闭用户主动打开的页面；`requestUser` 是让权动作，不能抢标签；`observe(designAction: release)` 清理的是一次测量，都不能当作释放浏览器。
5. **处理在途动作和真正的运行终点。** 同一浏览器一次只派发一个动作。接管、释放或取消时立即使旧轮次失效、移除排队动作；在 WebKit 真实派发前、异步返回后、提交文件或发布画面前复核。已送进 WebKit 的点击无法保证撤销：交接要等它完成或可证明失效才放开人工输入；结果不明不重放。若 WebKit 一直没有回执，保留页面并给「重试接管」；需要隔离旧页面并重新载入时，由用户选择，并提示未提交的输入可能丢失。

   正常执行、恢复执行都以服务的[真实终态](../FloeAgent/Sources/FloeAgentRuntime/ConversationRunService.swift#L2432)为准；[取消](../FloeAgent/FloeApp/Remote/ConversationCenter.swift#L8865)先挡住新派发，再按确切持有人清理。成功、失败、取消、保存检查点并结束本次执行均释放模型持有；模型思考、普通等待、App 切后台、视图重建不释放。恢复即使沿用原 runID，也建立新的执行轮次。进程退出不恢复旧模型锁；已有人工交还记录沿用原去重机制。删除、归档或容量回收仍按原有规则销毁会话，不能误用来交还。

## 实施顺序和过关条件

| 顺序 | 交付 | 怎么判断做对 |
| --- | --- | --- |
| ① 控制权与工具 | 先落实任务级状态、首次原子取权、显式释放、运行终态回收；接入普通读写、特殊入口和模型实际能发现的工具目录。 | 以 `observe`、`navigate`、`tabs` 分别作为首个调用，在首次读取/创建之前就观察到持有人。跨调用、模型思考、单步失败仍持有；显式释放或运行结束后同页仍在。过期释放、排队请求、取消后的回调都不能影响新持有人。 |
| ② 接通原生输入与交还 | 在现有任务浏览器上做出完整双向交接，所有触摸、滚动、键盘、辅助功能、地址栏、标签和刷新共用同一状态。保留上面的「我来操作」和「交还给 AI」，面板的收起、放大、关闭始终可用。 | 改掉[允许人工接管期间继续观察的测试](../FloeAgent/Tests/FloeAppTests/BrowserTaskSessionTests.swift#L594)：改为断言没有页面数据而 B 仍工作。补一次在途点击被接管、一次在途读取不能返回内容、一次人工先打字时 AI 不能插入操作。交还后旧引用失效、只通知原运行一次；[个人浏览器隔离](../FloeAgent/Tests/FloeAppTests/NextRoundBrowserModeTests.swift#L10)和[预览取消恢复](../FloeAgent/Tests/FloeAppTests/BrowserPreviewOwnershipTests.swift#L474)仍成立。前两步一起通过再开放给用户。 |
| ③ 接进现有预览区 | 浏览器真实开始工作后，在现有预览底边加一条状态：「AI 正在查看网页」「AI 点击了『15°』」。现有[输入事件](../FloeAgent/FloeApp/Browser/BrowserTaskSessionStore.swift#L943)只记动作种类；小窗应取这次已执行动作对应的可公开目标和画面。有画面才展示，放大仍只观看，收起不改变控制权。窄屏先显示同一行，点「我来操作」或协助请求里的「去操作」才打开可输入的网页。 | 在复用的 iPad 模拟器上用实际工具跑上面的表单例子：点位或控件名来自同一标签、同一页面、同一动作；没有目标证据只写「正在操作网页」，不模拟点击。接管时立即停止模型画面采集，敏感输入不留缩略图；文件阅读位置和聊天草稿不变。结束不落整轮快照。 |

本轮只把上述边界核对到源码并编写计划。实现后的验收以真实工具注册路径、任务浏览器和原生输入为准，现有[可点交互稿](design/floe-preview-collaboration.zh-CN.html)仅用于讨论布局。
