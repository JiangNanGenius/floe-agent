# Home / Chat 分离、语音输入重构与流式时间线 — 交接报告

日期：2026-08-15
分支：`agent/alpha-daily`（当前工作区，未提交）
执行者：WorkBuddy 代码实现工程师（本轮只改代码与测试代码，未编译、未提交、未推送、未发布）

---

## 1. 变更概要

本轮一次性解决三个核心问题，并补齐界面、诊断、本地化与测试代码：

1. **Home 与 Chat 真正分离**：Home 变为“开始工作”的启动台（居中大输入框 + 欢迎语 + 真实快捷入口），iPad 第二列改为任务概览（进行中任务 / 待审批 / 最近任务），不再复用 `ConversationListView`；Chat 独立拥有可搜索的对话历史列表、选中态与空状态。两页拥有独立的导航栈与选中状态。
2. **语音输入崩溃修复**：删除嵌在 `ThreadComposerView` 中的旧 `SpeechInputController`（SFSpeechRecognizer + AVAudioEngine），替换为协议化、可测试的 `VoiceInputController` + iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` 实现。音频 tap 安装前验证 `sampleRate > 0 && channelCount > 0`，start/stop 幂等，任意时刻最多一个 session。
3. **流式平滑与统一时间线**：新增 `StreamingTextAnimator`（FloeCore，按 grapheme cluster 顺序显示，terminal 后先排空再切换持久消息）；新增 `ThreadTimelineItem` 统一时间线投影，严格按 `RunEvent.sequence` 排序，最终 assistant 回复（`.assistantText` 事件）永远在 `.terminal` 之前持久化和渲染。

## 2. 修改的文件列表

### 新增

| 文件 | 说明 |
| --- | --- |
| `FloeAgent/Sources/FloeCore/StreamingTextAnimator.swift` | MainActor 流式显示协调器 + 诊断协议 |
| `FloeAgent/FloeApp/Chat/ThreadTimeline.swift` | `ThreadTimelineItem` / `ThreadTimelineBuilder` 统一时间线投影 |
| `FloeAgent/FloeApp/Voice/VoiceInput.swift` | 语音状态机、协议（授权/转写/采集/诊断）、失败分类 |
| `FloeAgent/FloeApp/Voice/VoiceInputController.swift` | 语音生命周期控制器（无音频内部实现，可测试） |
| `FloeAgent/FloeApp/Voice/VoiceInputLive.swift` | 生产实现：系统授权、SpeechAnalyzer 转写、单 tap 采集、日志转发 |
| `FloeAgent/FloeApp/Home/HomeLaunchpadView.swift` | Home 启动台视图（iPhone Home 根 / iPad Home 第三列） |
| `FloeAgent/FloeApp/Home/HomeLaunchpadViewModel.swift` | Home 启动台 ViewModel + `HomeTaskStarting` 任务创建 seam |
| `FloeAgent/FloeApp/Home/HomeOverviewView.swift` | iPad Home 第二列任务概览（由旧 ChatHomeView.swift 重写而来） |
| `FloeAgent/Tests/FloeCoreTests/StreamingTextAnimatorTests.swift` | 流式动画单元测试（swift-testing） |
| `FloeAgent/Tests/FloeAgentUITests/ThreadTimelineTests.swift` | 时间线投影逻辑测试 |
| `FloeAgent/Tests/FloeAgentUITests/VoiceInputControllerTests.swift` | 语音状态机测试（全 fake，无真实麦克风） |
| `FloeAgent/Tests/FloeAgentUITests/HomeChatSeparationTests.swift` | Home/Chat 导航分离与任务创建契约测试 |
| `FloeAgent/Tests/FloeAgentUITests/HomeChatVoiceUITests.swift` | iPad Air 13-inch 与 iPhone 的 XCUITest 用例 |

### 修改

| 文件 | 说明 |
| --- | --- |
| `FloeAgent/FloeApp/App/FloeAgentApp.swift` | Home/Chat 分栈导航（`homePath`/`chatPath`）、iPad Home 第二列改 `HomeOverviewView`、第三列 Home 用 launchpad/自家 detail；新增 `ChatDetailEmptyView`；UITest 布局固定开关 |
| `FloeAgent/FloeApp/Shell/AppRouter.swift` | 新增 `homePath`、`homeDetailConversationID`、`openThreadFromHome`；`openConversation` 不再触碰 Home 状态 |
| `FloeAgent/FloeApp/Chat/ConversationListView.swift` | 增加搜索、iPad 选中态高亮、accessibilityIdentifier；删除逻辑不变 |
| `FloeAgent/FloeApp/Chat/ConversationListViewModel.swift` | 增加 `searchText` 与 `filteredConversations` |
| `FloeAgent/FloeApp/Chat/ThreadComposerView.swift` | 删除旧 `SpeechInputController`；接入 `VoiceInputController`；权限失败横幅带“打开设置”；VoiceOver 状态值；scenePhase 后台安全停止 |
| `FloeAgent/FloeApp/Chat/ThreadDetailView.swift` | 改为渲染统一 `timeline`；新增 `TerminalEventRow`（quiet 状态行）与 `MissingFinalMessageRow`；滚动跟随 animator |
| `FloeAgent/FloeApp/Chat/ThreadDetailViewModel.swift` | 接入 `StreamingTextAnimator`；terminal 后 `drain()` 再落盘刷新；删除 `revealStreamText`；重开历史线程不继续计时/stream |
| `FloeAgent/FloeApp/Chat/RunStateLocalizer.swift` | 新增 `terminalTitle(stopReason:)`（endTurn→已完成、cancelled→已停止、length→已达上限） |
| `FloeAgent/Sources/FloeAgentRuntime/ConversationRunService.swift` | completed 时先持久化 assistant 消息 + `.assistantText` 事件，再写 `.terminal`；无最终文本时写 `.error`(noFinalText)；新增 runStateChanged / finalMessagePersisted / finalMessageMissing / terminalPersisted 日志 |
| `FloeAgent/FloeApp/Resources/Localizable.xcstrings` | 新增 22 个键（中英双语，extractionState: manual） |
| `FloeAgent/Tests/FloeAgentRuntimeTests/ConversationRunServiceTests.swift` | 断言 assistantText 事件在 terminal 之前；工具轮后仍有最终回复；无最终文本写 error 事件 |

### 删除

- `FloeAgent/FloeApp/Home/ChatHomeView.swift`（其 iPad 概览职责由 `HomeOverviewView.swift` 承接）
- `FloeAgent/FloeApp/Home/HomeWorkbenchView.swift`
- `FloeAgent/FloeApp/Home/HomeWorkbenchViewModel.swift`

## 3. Home / Chat 新架构

```
iPhone（TabView，5 个锁定 tab）
├─ Home tab: NavigationStack(path: router.homePath)
│   └─ HomeLaunchpadView（欢迎语 + App 图标 + 大 composer + 快捷入口）
│      └─ 发送第一条消息 → openThreadFromHome → push ThreadDetailView
├─ Chat tab: NavigationStack(path: router.chatPath)
│   └─ ConversationListView（搜索/新建/删除）
│      └─ 选择 → openConversation → push ThreadDetailView
└─ Files / Hosts / More 不变

iPad（NavigationSplitView 三列）
├─ 列1 全局侧边栏（不变）
├─ 列2
│   ├─ Home → HomeOverviewView（进行中任务/待审批/最近任务，空则干净留白）
│   └─ Chat → ConversationListView（带选中高亮）
└─ 列3
    ├─ Home → homeDetailConversationID ? ThreadDetailView : HomeLaunchpadView
    └─ Chat → selectedConversationID ? ThreadDetailView : ChatDetailEmptyView（简洁空态 + 新建）
```

分离边界：

- 导航状态：`homePath`/`homeDetailConversationID`（Home）vs `chatPath`/`selectedConversationID`（Chat），互不污染。
- ViewModel：`HomeLaunchpadViewModel`（任务创建 + 概览）vs `ConversationListViewModel`（历史管理）vs `ThreadDetailViewModel`（线程）。
- 任务创建：`HomeTaskStarting` 协议 + 单 flight `isSending` 守卫；发送失败删除刚建的空会话、保留草稿，不留下无限计时的空线程。
- 复用：仅低层级 `ThreadComposerView`、行组件被复用；页面容器/空态/创建逻辑均独立。

快捷入口诚实性：工作区文件 → 真实文件检查器；远程主机 → Hosts tab；模型提供商 → More；图片处理 → 无已实现功能，**禁用且标注“尚未提供”**，不模拟成功。

## 4. 语音状态机

```
idle ──start──▶ requestingPermission ──授权通过──▶ preparing ──▶ listening
 ▲                     │失败                          │失败            │
 │                     ▼                              ▼              │ stop()
 │            failed(mic/speech denied)      unavailable(语言/模型)   ▼
 │            failed(noAudioInput/…)                          stopping ──▶ idle
 │                     │
 └────── 用户显式 stop ◀┘（失败后再次 stop 复位到 idle）
```

保证：

- `start()`/`stop()` 幂等；`startToken` 单调递增，过期的 preparation 不会激活 session（stop-during-preparation 必然获胜）。
- 任意时刻至多一个采集/转写 session；快速连点不会重复 installTap。
- `AudioEngineCapturer` 是 AVAudioEngine 唯一 owner；installTap 前验证输入格式（sampleRate>0、channelCount>0），不可用 → `VoiceSessionError.failure(.noAudioInput)` 友好失败，绝不触发 ObjC 异常崩溃。
- 页面消失（`.onDisappear`）、scenePhase 非 active（后台/失活）→ `handleInterruption` 安全停止。
- 权限拒绝：横幅说明 + “打开设置”跳转；输入框始终可键入，麦克风按钮恢复可操作。
- 不保存原始音频；转写仅在用户点发送后才进入模型；部分结果按序整体替换 staged transcript（与手工前缀拼接，不重复、不覆盖已有输入）。
- 无 force unwrap / fatalError / precondition 处理音频状态。

诊断事件（脱敏，无音频/无转写正文）：`permissionRequested`、`permissionDenied`、`sessionPreparing`、`listeningStarted`、`interruption`、`routeChanged`、`listeningStopped`、`speechFailed`（category=app）。

## 5. 时间线排序规则

`ThreadTimelineBuilder.build(...)` 输出 `[ThreadTimelineItem]`：

1. 选中 run 的用户目标消息（按 `run.goal` 内容匹配，不依赖时间戳）。
2. 持久化事件**严格按 `RunEventRecord.sequence` 升序**（status/reasoning/toolRequest/toolResult/approval/error 原位渲染）。
3. 最新 `.assistantText` 事件 → 最终回复行（内容与持久化 assistant 消息匹配，只渲染一次，**重开页面不重复**）。
4. 旧 run 无 `.assistantText` → 回退到持久化 assistant 消息，插入 terminal 之前（不删除旧数据）。
5. run=completed 且两者都无 → `missingFinalMessage` 行（“模型未返回最终回复”），绝不静默成功。
6. live 槽位（liveReasoning → liveAssistantTail → liveThinking）在持久行之后、仅 run 活跃或 drain 中显示。
7. pendingApprovals 在 live 槽位之后（决策点）。
8. `.terminal` 永远是 run 块的最后一行（quiet 状态行，非大卡片）。

ForEach ID 稳定：持久行用记录 UUID，live 行用固定字符串，刷新不重建整个列表。

`ConversationRunService` 持久化顺序（actor 串行保证）：assistant 消息 → `.assistantText` 事件 → `.terminal` 事件。`finalMessagePersisted` / `terminalPersisted` 日志佐证。

## 6. 流式动画规则

`StreamingTextAnimator`（FloeCore，无 UI 依赖）：

- `update(target:)` 只接受前缀扩展；非前缀更新 → `streamNonPrefixDetected` 诊断 + 安全重建（从首屏 24 个 cluster 起重新流出，不乱序不重复）。
- 单动画任务；约 16ms/cluster（clamp 12–20ms）；积压自适应 1/2/4/6 cluster 每 tick，但**绝不**一次显示整段。
- 以 Swift `Character`（grapheme cluster）为单位推进：中文、emoji、ZWJ 序列（👨‍👩‍👧‍👦）、旗帜（🇨🇳）、组合字符不拆坏。
- 网络 terminal ≠ 显示终止：`ThreadDetailViewModel` 在 terminal 时先 `await animator.drain()`（`streamDrainStarted`/`streamDrainCompleted` 日志），排空期间 `isDraining=true` 保持 live tail 挂载，排空后一次性切换为持久消息——无闪烁、无重复、无短暂消失。
- `cancel()`（离开页面）立即停止，不跳到完整目标。
- 不按 token/字符写数据库；滚动只在 `displayedText.count` 变化且 live tail 在底部时跟随，不逐字符强抢用户滚动。

## 7. 新增测试列表

### 单元/逻辑测试（swift-testing / XCTest 代码，未执行）

| 文件 | 覆盖点（对应需求编号） |
| --- | --- |
| `Tests/FloeCoreTests/StreamingTextAnimatorTests.swift` | 4 流式顺序；5 中文/emoji/组合字符；6 terminal 先排空；非前缀重建；cancel 不跳变；单动画任务；大批次有界 |
| `Tests/FloeAgentUITests/ThreadTimelineTests.swift` | 7 最终回复在 terminal 前；9 重开不重复；10 旧 run 兼容；缺失回复显式行；ID 稳定；sequence 优先于时间戳 |
| `Tests/FloeAgentUITests/VoiceInputControllerTests.swift` | 12 start/stop 幂等；13 快速连点单 session；14 权限拒绝/格式不可用/识别失败不崩溃；15 中断/路由变化安全停止；16 部分结果按序不重复；preparation 中 stop 获胜；识别服务主动结束清理 |
| `Tests/FloeAgentUITests/HomeChatSeparationTests.swift` | 1 Home/Chat 独立导航投影；返回互不污染；任务创建 seam 单次调用与失败契约（2、3 的 store 级覆盖在 runtime 测试） |
| `Tests/FloeAgentRuntimeTests/ConversationRunServiceTests.swift`（修改） | 7、8 assistantText 在 terminal 前、工具轮后仍有最终回复；无最终文本写 error 事件 |

计时停止（11）：由 `ThreadDetailViewModel.startPolling` 终态 break + 无 live service 时 `isRunning=false` 保证；UI 状态文案全部经 `RunStateLocalizer`。建议在 Codex 侧补一个 AppEnvironment 测试夹具后加强 Home 任务创建（2、3）与计时断言——当前工程没有 app 级单元测试 target，逻辑测试编在 UI 测试 bundle 中。

### UI 测试（XCUITest 代码，未执行）

`Tests/FloeAgentUITests/HomeChatVoiceUITests.swift`：

- iPad（`-ui-testing -ui-testing-ipad`，请在 iPad Air 13-inch 模拟器运行）：Home/Chat 结构差异、首页直接开始任务、terminal 位于最终回复之后（有 fixture 时）、连点语音不崩溃、导航后语音 session 清理。
- iPhone（`-ui-testing`）：Home/Chat tab 独立、Chat 列表/新建入口、键盘下 composer 布局、麦克风 VoiceOver label/value 与设置跳转。

## 8. 仍需 Codex 编译验证的风险点

1. **SpeechAnalyzer API 形状**（最高风险）：`SpeechAnalyzer(inputSequence:modules:options:)`、`SpeechAnalyzer.Options(priority:)`、`analyzer.start(inputSequence:)`、`finalizeAndThroughEndOfInput`/`finalizeAndFinishThroughEndOfInput`、`AssetInventory.assetInstallationRequest(supporting:)` 的确切签名以 iOS 26 SDK 为准。我用了 WWDC25 公开 API 的最可能形状，需要按编译器报错微调。`SpeechTranscriber.results` 元素 `result.text` 是 `AttributedString`，`String(result.text.characters)` 的取法需确认。
2. **Swift 6 并发**：`VoiceInputController` 的 `makeTranscriber` 是 `@MainActor () throws ->`，内部 await 非隔离的 async init——若报 actor 隔离错误，把 `SpeechAnalyzerTranscriber.init` 标 `@MainActor` 或调整闭包隔离即可。`AudioEngineCapturer` 用 NSLock 保护状态，被标 `@unchecked Sendable`。
3. **FloeApp 逻辑测试的位置**：`ThreadTimelineTests` / `VoiceInputControllerTests` / `HomeChatSeparationTests` 使用 `@testable import FloeApp`，放在 `FloeAgentUITests` bundle 中。**若 `TEST_TARGET_NAME` 的 @testable 导入在 ui-testing bundle 不可用**，需要把这三个文件移到一个新的 app 单元测试 target（project.yml 增加 `bundle.unit-test` target 并重新生成工程）。
4. `Image(uiImage:)` 读 AppIcon：若 `CFBundleIcons` 解析失败回退 `UIImage(named: "AppIcon")`，需真机/模拟器确认图标显示。
5. `.searchable` 在 iPad NavigationSplitView content 列的 placement 可能需要视觉微调。
6. `HomeOverviewView` 与 `HomeLaunchpadView` 各自持有 `HomeLaunchpadViewModel`（iPad 会加载两遍概览数据）；数据量小可接受，如介意可提为共享实例。
7. 未验证 `UIApplication.openSettingsURLString` 在 composer 中的跳转表现（权限拒绝路径）。

## 9. 建议 Codex 执行的命令

```bash
cd FloeAgent
xcodegen generate            # 若 project.yml 有变动（本轮未改 project.yml，可跳过）
scripts/local_build.sh       # 或：xcodebuild -scheme FloeAgent -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M3)' build

# 单元/逻辑测试
xcodebuild test -scheme FloeAgent \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:FloeAgentUITests/ThreadTimelineTests \
  -only-testing:FloeAgentUITests/VoiceInputControllerTests \
  -only-testing:FloeAgentUITests/HomeChatSeparationTests

swift test --filter StreamingTextAnimator   # FloeCore 目标（若该 target 支持 macOS 宿主）
swift test --filter ConversationRunService  # 运行时持久化顺序

# UI 测试
xcodebuild test -scheme FloeAgent \
  -destination 'platform=iOS Simulator,name=iPad Air 13-inch (M3)' \
  -only-testing:FloeAgentUITests/HomeChatVoiceIPadUITests
xcodebuild test -scheme FloeAgent \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:FloeAgentUITests/HomeChatVoiceIPhoneUITests
```

真机必测项：语音识别（设备端模型下载）、权限拒绝→设置跳转、蓝牙耳机切换中断、键盘/Dynamic Type/Reduce Motion/VoiceOver 全路径。

## 10. 数据库迁移说明

**无需迁移**。所有新事件（`.assistantText`、noFinalText `.error`）都写入既有 `run_events` 表；旧 run 无 `.assistantText` 时由时间线投影回退到持久化 assistant 消息。未删除或改写任何旧数据。

## 11. 当前 git 状态

### `git status --short`

```
 M FloeAgent/FloeApp/App/FloeAgentApp.swift
 M FloeAgent/FloeApp/Chat/ConversationListView.swift
 M FloeAgent/FloeApp/Chat/ConversationListViewModel.swift
 M FloeAgent/FloeApp/Chat/RunStateLocalizer.swift
 M FloeAgent/FloeApp/Chat/ThreadComposerView.swift
 M FloeAgent/FloeApp/Chat/ThreadDetailView.swift
 M FloeAgent/FloeApp/Chat/ThreadDetailViewModel.swift
 D FloeAgent/FloeApp/Home/ChatHomeView.swift
 D FloeAgent/FloeApp/Home/HomeWorkbenchView.swift
 D FloeAgent/FloeApp/Home/HomeWorkbenchViewModel.swift
 M FloeAgent/FloeApp/Resources/Localizable.xcstrings
 M FloeAgent/FloeApp/Shell/AppRouter.swift
 M FloeAgent/Sources/FloeAgentRuntime/ConversationRunService.swift
 M FloeAgent/Tests/FloeAgentRuntimeTests/ConversationRunServiceTests.swift
?? FloeAgent/FloeApp/Chat/ThreadTimeline.swift
?? FloeAgent/FloeApp/Home/HomeLaunchpadView.swift
?? FloeAgent/FloeApp/Home/HomeLaunchpadViewModel.swift
?? FloeAgent/FloeApp/Home/HomeOverviewView.swift
?? FloeAgent/FloeApp/Voice/
?? FloeAgent/Sources/FloeCore/StreamingTextAnimator.swift
?? FloeAgent/Tests/FloeAgentUITests/HomeChatSeparationTests.swift
?? FloeAgent/Tests/FloeAgentUITests/HomeChatVoiceUITests.swift
?? FloeAgent/Tests/FloeAgentUITests/ThreadTimelineTests.swift
?? FloeAgent/Tests/FloeAgentUITests/VoiceInputControllerTests.swift
?? FloeAgent/Tests/FloeCoreTests/StreamingTextAnimatorTests.swift
```

### `git diff --stat`

```
 FloeAgent/FloeApp/App/FloeAgentApp.swift           |  90 +++-
 FloeAgent/FloeApp/Chat/ConversationListView.swift  |  90 ++--
 .../FloeApp/Chat/ConversationListViewModel.swift   |  12 +
 FloeAgent/FloeApp/Chat/RunStateLocalizer.swift     |  17 +
 FloeAgent/FloeApp/Chat/ThreadComposerView.swift    | 222 ++++------
 FloeAgent/FloeApp/Chat/ThreadDetailView.swift      | 180 +++++---
 FloeAgent/FloeApp/Chat/ThreadDetailViewModel.swift | 110 +++--
 FloeAgent/FloeApp/Home/ChatHomeView.swift          | 250 -----------
 FloeAgent/FloeApp/Home/HomeWorkbenchView.swift     |  75 ----
 .../FloeApp/Home/HomeWorkbenchViewModel.swift      | 174 --------
 FloeAgent/FloeApp/Resources/Localizable.xcstrings  | 458 ++++++++++++++++++++-
 FloeAgent/FloeApp/Shell/AppRouter.swift            |  19 +
 .../FloeAgentRuntime/ConversationRunService.swift  |  24 +-
 .../ConversationRunServiceTests.swift              |  60 ++-
 14 files changed, 1003 insertions(+), 778 deletions(-)
```

（另有 10 个未跟踪新文件，见上方 status；新文件合计约 1900 行。）
