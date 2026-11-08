// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloeExecution
import FloeProviders
import FloeSecurity
import FloePersistence
import FloeAgentRuntime
import FloeMarkdown
@testable import FloeApp

/// Only provider transport is scripted. The real runtime, registered tool,
/// producer file commit, service persistence and reopen resolver all run.
private final class InlineChartTransport: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIResponses
    private let lock = NSLock()
    private var turn = 0
    private var observedMarkdown: String?
    private var observedEnvelope = false
    var markdown: String? { lock.lock(); defer { lock.unlock() }; return observedMarkdown }
    var receivedTrustedReference: Bool { lock.lock(); defer { lock.unlock() }; return observedEnvelope }
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        lock.lock(); let index = turn; turn += 1; lock.unlock()
        return AsyncThrowingStream { continuation in
            do {
                if index == 0 {
                    let args = #"{"kind":"chart","title":"原生正文图表验收","chartType":"line","series":[{"name":"实测数据","points":[{"label":"一","value":2},{"label":"二","value":5},{"label":"三","value":3}]}]}"#
                    continuation.yield(.toolRequest(try ToolCall(id: "native-inline-chart", toolName: PresentationArtifactTool.name,
                        argumentsJSON: Data(args.utf8), scope: .local)))
                    continuation.yield(.completed(.init(stopReason: .toolUse)))
                } else if index == 1 {
                    let output = try #require(request.toolResults.first { $0.callID == "native-inline-chart" }?.output)
                    let envelopeText = try #require(output.split(separator: "\n", omittingEmptySubsequences: true).first)
                    let envelope = try #require(JSONSerialization.jsonObject(with: Data(envelopeText.utf8)) as? [String: Any])
                    let reference = try #require((envelope["inlineContent"] as? [[String: String]])?.first?["inlineMarkdown"])
                    #expect(envelope["toolName"] as? String == PresentationArtifactTool.name)
                    #expect(reference.contains("floe-content://artifact/"))
                    lock.lock(); observedMarkdown = reference; observedEnvelope = true; lock.unlock()
                    continuation.yield(.textDelta(.init(text: "这是原生图表前的一段说明。\n\n")))
                    continuation.yield(.textDelta(.init(text: reference + "\n\n")))
                    continuation.yield(.textDelta(.init(text: "这是原生图表后的一段说明。")))
                    continuation.yield(.completed(.init(stopReason: .endTurn)))
                } else { throw FloeError.validationFailed("Unexpected extra provider turn in native inline qualification") }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

@Suite("Native inline content production flow", .serialized)
@MainActor
struct ChatInlineContentProductionFlowTests {
    /// A single test-owned saved task remains visible for Root's UI check.
    /// Re-runs append a real run to this same task; they never replace history.
    static let fixtureTaskID = UUID(uuidString: "B5C1C2D4-79A0-4D4E-9C07-4ACBFA6B1808")!
    @Test func registeredChartRunsReachesModelAndReopensInsideAnswer() async throws {
        let environment = try await appQualificationEnvironment()
        try await environment.ensureDurableAutomationReady()
        let title = "正文插入验收 · 原生图表"
        if let existing = try await environment.conversationStore.conversation(id: Self.fixtureTaskID) {
            #expect(existing.title == title && existing.purpose == .ordinary)
            guard existing.title == title && existing.purpose == .ordinary else { throw FloeError.unauthorized }
        } else {
            try await environment.conversationStore.saveConversation(.init(id: Self.fixtureTaskID, title: title,
                createdAt: Date(), updatedAt: Date()))
        }
        let runner = try #require(ToolRunnerRegistry.shared.runner(named: PresentationArtifactTool.name))
        #expect(runner.descriptor.name == PresentationArtifactTool.name)
        let provider = ProviderProfile(id: UUID(), kind: .custom, wireProtocol: .openAIResponses,
            baseURL: URL(string: "https://localhost:8443")!, secretRef: nil, region: nil, nonSecretHeaders: [:],
            isEnabled: true, allowsPlainHTTP: false, createdAt: Date(), updatedAt: Date(), syncRevision: 0)
        let model = ModelProfile(id: UUID(), providerID: provider.id, remoteModelID: "inline-content-scripted-transport",
            displayName: "Inline content contract transport", limits: .init(contextTokens: 128_000, maxOutputTokens: 4_096),
            pricing: nil, capabilities: [.text, .tools], isEnabled: true)
        let runID = UUID(), transport = InlineChartTransport()
        let service = ConversationRunService(configuration: .init(conversationID: Self.fixtureTaskID,
                provider: provider, model: model, allowedToolNames: [PresentationArtifactTool.name],
                maxProviderRetries: 0),
            adapter: transport, policy: TaskFullAccessPolicy(), executor: CatalogToolExecutor(),
            conversationStore: environment.conversationStore, runStore: environment.runStore, runID: runID)
        try await service.start(goal: "生成原生折线图，并用返回的正文引用放在两段说明之间。")
        #expect(await service.snapshot().isTerminal)
        #expect(transport.receivedTrustedReference)
        let markdown = try #require(transport.markdown)
        let events = try await environment.runStore.events(runID: runID)
        let event = try #require(events.first { $0.kind == .toolResult })
        let payload = try #require(ChatInlineContentResolver.payload(event))
        #expect(payload["tool"] == PresentationArtifactTool.name && payload["status"] == "ok")
        let artifacts: [ToolArtifactReference] = ChatInlineContentResolver.decode(payload["artifactRefsJSON"])
        let artifact = try #require(artifacts.first)
        let reference = try #require(ChatContentReference(kind: .artifact, ownerID: runID, contentID: artifact.id.uuidString))
        #expect(markdown == reference.markdown(title: "Chart"))
        let expected = "这是原生图表前的一段说明。\n\n" + markdown + "\n\n这是原生图表后的一段说明。"
        let assistant = try #require(try await environment.conversationStore.messages(conversationID: Self.fixtureTaskID)
            .last { $0.role == "assistant" && $0.runID == runID })
        #expect(assistant.content == expected)
        let reopenedConversations = SQLiteConversationStore(database: environment.database)
        let reopenedRuns = SQLiteRunStore(database: environment.database)
        let reopened = try await ChatInlineContentResolver.resolve(reference,
            scope: .init(conversationID: Self.fixtureTaskID, isTemporary: false), conversations: reopenedConversations, runs: reopenedRuns)
        #expect(reopened == .artifact(artifact, runID: runID, tool: PresentationArtifactTool.name))
        let verified = try VerifiedChatInlineArtifact.load(artifact, runID: runID, tool: PresentationArtifactTool.name,
            root: FloeArtifactStore.root())
        let document = try JSONDecoder().decode(PresentationChartDocument.self, from: verified.data)
        #expect(document.type == .line && document.series.first?.points.count == 3)
        #expect(document.title == "原生正文图表验收")
        FileHandle.standardOutput.write(Data("FLOE_INLINE_CONTENT_FIXTURE|task=\(Self.fixtureTaskID)|run=\(runID)|artifact=\(artifact.id)|message=\(assistant.id)|sha256=\(artifact.sha256)\n".utf8))
    }
}

/// Scripts provider transport only. Every reference below is decoded from
/// the real runner's model-visible result; no tool receipt is manufactured.
private final class InlineMultitypeTransport: ProviderAdapter, @unchecked Sendable {
    enum Plan: Sendable { case produce, list(UUID, reject: Bool) }
    let protocolKind: ModelProtocol = .openAIResponses
    private let plan: Plan
    private let taskID: UUID
    private let runID: UUID
    private let lock = NSLock()
    private var turn = 0
    private var savedItems: [[String: String]] = []
    private var savedAnswer = ""
    private var denied = false
    var items: [[String: String]] { lock.lock(); defer { lock.unlock() }; return savedItems }
    var answer: String { lock.lock(); defer { lock.unlock() }; return savedAnswer }
    var receivedRejection: Bool { lock.lock(); defer { lock.unlock() }; return denied }

    init(plan: Plan, taskID: UUID, runID: UUID) { self.plan = plan; self.taskID = taskID; self.runID = runID }

    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        lock.lock(); let index = turn; turn += 1; lock.unlock()
        return AsyncThrowingStream { continuation in
            do {
                func call(_ id: String, _ tool: String, _ arguments: [String: Any]) throws {
                    continuation.yield(.toolRequest(try ToolCall(id: id, toolName: tool,
                        argumentsJSON: JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]), scope: .local)))
                    continuation.yield(.completed(.init(stopReason: .toolUse)))
                }
                func result(_ id: String, _ tool: String) throws -> (envelope: [String: Any], body: String) {
                    let output = try #require(request.toolResults.first { $0.callID == id }?.output)
                    let lines = output.split(separator: "\n", omittingEmptySubsequences: false)
                    let first = try #require(lines.first)
                    let envelope = try #require(JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any])
                    #expect(envelope["toolName"] as? String == tool)
                    #expect(envelope["taskID"] as? String == taskID.uuidString)
                    #expect(envelope["runID"] as? String == runID.uuidString)
                    return (envelope, lines.dropFirst().joined(separator: "\n"))
                }
                func remember(_ item: [String: String]) {
                    lock.lock(); savedItems.append(item); lock.unlock()
                }
                func reply() throws {
                    let observed = items
                    let table = try #require(observed.first { $0["mimeType"] == "application/vnd.floe.table+json" }?["inlineMarkdown"])
                    let web = try #require(observed.first { $0["mimeType"] == "text/html" }?["inlineMarkdown"])
                    let text = "这是表格前的说明。\n\n" + table + "\n\n这是表格与互动预览之间的说明。\n\n"
                        + web + "\n\n这是互动预览后的说明。"
                    lock.lock(); savedAnswer = text; lock.unlock()
                    continuation.yield(.textDelta(.init(text: text)))
                    continuation.yield(.completed(.init(stopReason: .endTurn)))
                }
                switch plan {
                case .produce:
                    switch index {
                    case 0:
                        try call("native-inline-table", PresentationArtifactTool.name,
                            ["kind": "table", "title": "原生正文表格验收", "columns": ["项目", "数量"],
                             "rows": [["苹果", "3"], ["梨", "5"]]])
                    case 1:
                        let item = try #require((try result("native-inline-table", PresentationArtifactTool.name)
                            .envelope["inlineContent"] as? [[String: String]])?.first)
                        #expect(item["mimeType"] == "application/vnd.floe.table+json")
                        remember(item)
                        try call("native-inline-web", PresentationArtifactTool.name,
                            ["kind": "web", "title": "原生正文互动预览验收", "html": """
                            <section><h2>安全本地互动</h2><button id="increment" type="button">增加</button>
                            <output id="count">0</output><script>document.getElementById('increment').onclick=()=>{
                            const value=document.getElementById('count');value.textContent=String(Number(value.textContent)+1);};</script></section>
                            """])
                    case 2:
                        let item = try #require((try result("native-inline-web", PresentationArtifactTool.name)
                            .envelope["inlineContent"] as? [[String: String]])?.first)
                        #expect(item["mimeType"] == "text/html")
                        remember(item)
                        try reply()
                    default: throw FloeError.validationFailed("Unexpected provider turn in multitype production")
                    }
                case .list(let sourceRun, let reject):
                    if index == 0 {
                        try call("native-inline-list", "chat.content.list",
                            ["runID": sourceRun.uuidString, "afterSequence": 0, "eventLimit": 100])
                    } else if index == 1 {
                        let output = try result("native-inline-list", "chat.content.list")
                        if reject {
                            #expect(output.body.contains("Unauthorized"))
                            #expect(!output.body.contains("floe-content://"))
                            #expect(!output.body.contains("\"contents\""))
                            lock.lock(); denied = true; lock.unlock()
                            continuation.yield(.textDelta(.init(text: "无法读取其他任务的内容。")))
                            continuation.yield(.completed(.init(stopReason: .endTurn)))
                        } else {
                            let listing = try #require(JSONSerialization.jsonObject(with: Data(output.body.utf8)) as? [String: Any])
                            let contents = try #require(listing["contents"] as? [[String: String]])
                            let pages = try #require(listing["pages"] as? [[String: String]])
                            let page = try #require(pages.first)
                            #expect(listing["truncated"] as? Bool == false)
                            #expect(pages.count == 1 && page["runID"] == sourceRun.uuidString)
                            #expect(page["startAfterSequence"] == "0" && page["hasMore"] == "false")
                            #expect(contents.count == 2)
                            for item in contents { remember(item) }
                            try reply()
                        }
                    } else { throw FloeError.validationFailed("Unexpected provider turn in saved content lookup") }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

private enum InlineMultitypeFixture {
    static let taskID = UUID(uuidString: "A02E1108-5829-46FD-B63C-A7287C3E9104")!
    static let title = "正文插入验收 · 原生表格与互动预览"
}

extension ChatInlineContentProductionFlowTests {
    @Test func registeredTableAndHTMLRecoverAcrossRunsAndRejectForeignTask() async throws {
        let app = try await appQualificationEnvironment()
        try await app.ensureDurableAutomationReady()
        let task = InlineMultitypeFixture.taskID
        if let existing = try await app.conversationStore.conversation(id: task) {
            guard existing.title == InlineMultitypeFixture.title, existing.purpose == .ordinary else { throw FloeError.unauthorized }
        } else {
            try await app.conversationStore.saveConversation(.init(id: task, title: InlineMultitypeFixture.title,
                createdAt: Date(), updatedAt: Date()))
        }
        for name in [PresentationArtifactTool.name, "chat.content.list"] {
            #expect(ToolRunnerRegistry.shared.runner(named: name)?.descriptor.name == name)
            guard ToolRunnerRegistry.shared.runner(named: name) != nil else { throw FloeError.notFound("Actual inline runner is not registered") }
        }
        let provider = ProviderProfile(id: UUID(), kind: .custom, wireProtocol: .openAIResponses,
            baseURL: URL(string: "https://localhost:8443")!, secretRef: nil, region: nil, nonSecretHeaders: [:],
            isEnabled: true, allowsPlainHTTP: false, createdAt: Date(), updatedAt: Date(), syncRevision: 0)
        let model = ModelProfile(id: UUID(), providerID: provider.id, remoteModelID: "inline-multitype-scripted-transport",
            displayName: "Inline multitype contract transport", limits: .init(contextTokens: 128_000, maxOutputTokens: 4_096),
            pricing: nil, capabilities: [.text, .tools], isEnabled: true)
        func run(_ id: UUID, taskID: UUID, adapter: InlineMultitypeTransport, tools: Set<String>, goal: String) async throws {
            let service = ConversationRunService(configuration: .init(conversationID: taskID, provider: provider, model: model,
                allowedToolNames: tools, maxProviderRetries: 0), adapter: adapter, policy: TaskFullAccessPolicy(),
                executor: CatalogToolExecutor(), conversationStore: app.conversationStore, runStore: app.runStore, runID: id)
            try await service.start(goal: goal)
            guard await service.snapshot().isTerminal else { throw FloeError.validationFailed("Inline QA run did not reach a terminal state") }
        }
        let producerRun = UUID(), producer = InlineMultitypeTransport(plan: .produce, taskID: task, runID: producerRun)
        try await run(producerRun, taskID: task, adapter: producer, tools: [PresentationArtifactTool.name],
            goal: "生成原生表格和安全本地互动预览，复制实际返回的正文引用放在说明段落之间。")
        #expect(Set(producer.items.compactMap { $0["mimeType"] }) == ["application/vnd.floe.table+json", "text/html"])
        let first = try #require(try await app.conversationStore.messages(conversationID: task)
            .last { $0.role == "assistant" && $0.runID == producerRun })
        #expect(!producer.answer.isEmpty && first.content == producer.answer)
        let conversations = SQLiteConversationStore(database: app.database), runs = SQLiteRunStore(database: app.database)
        let producedEvents = try await runs.events(runID: producerRun)
        var producedArtifacts: [ToolArtifactReference] = []
        for event in producedEvents where event.kind == .toolResult {
            let receipt = try #require(ChatInlineContentResolver.payload(event))
            #expect(receipt["tool"] == PresentationArtifactTool.name && receipt["status"] == "ok")
            let artifacts: [ToolArtifactReference] = ChatInlineContentResolver.decode(receipt["artifactRefsJSON"])
            producedArtifacts += artifacts
        }
        #expect(producedArtifacts.count == 2)
        let lookupRun = UUID(), lookup = InlineMultitypeTransport(plan: .list(producerRun, reject: false), taskID: task, runID: lookupRun)
        try await run(lookupRun, taskID: task, adapter: lookup, tools: ["chat.content.list"],
            goal: "用 chat.content.list 查找本任务刚才保存的表格和互动预览，将返回的实际引用再次放入正文。")
        #expect(lookupRun != producerRun)
        #expect(Set(lookup.items.compactMap { $0["inlineMarkdown"] }) == Set(producer.items.compactMap { $0["inlineMarkdown"] }))
        let reopenedMessage = try #require(try await conversations.messages(conversationID: task)
            .last { $0.role == "assistant" && $0.runID == lookupRun })
        #expect(!lookup.answer.isEmpty && reopenedMessage.content == lookup.answer)
        let blocks = InlineContentBlockParser.parse(reopenedMessage.content)
        let references = blocks.compactMap { block -> ChatContentReference? in
            guard case .reference(_, let uri) = block.content else { return nil }
            return ChatContentReference(uri)
        }
        #expect(references.count == 2)
        #expect(blocks.count == 5) // paragraph, table, paragraph, web, paragraph
        var paths: [String] = []
        for reference in references {
            #expect(reference.ownerID == producerRun)
            let resolved = try await ChatInlineContentResolver.resolve(reference,
                scope: .init(conversationID: task, isTemporary: false), conversations: conversations, runs: runs)
            guard case .artifact(let artifact, let owner, let tool) = resolved else { throw FloeError.validationFailed("Expected saved native artifact") }
            #expect(owner == producerRun && tool == PresentationArtifactTool.name)
            #expect(producedArtifacts.contains(artifact))
            let verified = try VerifiedChatInlineArtifact.load(artifact, runID: owner, tool: tool, root: FloeArtifactStore.root())
            paths.append(verified.fileURL.path)
            if artifact.mimeType == "application/vnd.floe.table+json" {
                let table = try JSONDecoder().decode(PresentationTableDocument.self, from: verified.data)
                #expect(table.title == "原生正文表格验收" && table.columns == ["项目", "数量"])
                #expect(table.rows == [["苹果", "3"], ["梨", "5"]])
            } else {
                #expect(artifact.mimeType == "text/html")
                let html = String(decoding: verified.data, as: UTF8.self)
                #expect(html.contains("Content-Security-Policy") && html.contains("default-src 'none'"))
                #expect(html.contains("connect-src 'none'") && html.contains("form-action 'none'"))
                #expect(html.contains("安全本地互动") && html.contains("id=\"increment\""))
                #expect(!html.contains("<iframe") && !html.contains("<form") && !html.contains("https://"))
            }
        }
        // This third run really invokes the registered index from a different
        // newly-owned task. No foreign receipts are seeded or borrowed.
        let foreignTask = UUID(), foreignRun = UUID(), foreignTitle = "正文插入验收 · 外部作用域拒绝"
        guard try await conversations.conversation(id: foreignTask) == nil else { throw FloeError.unauthorized }
        try await conversations.saveConversation(.init(id: foreignTask, title: foreignTitle, createdAt: Date(), updatedAt: Date()))
        let foreign = InlineMultitypeTransport(plan: .list(producerRun, reject: true), taskID: foreignTask, runID: foreignRun)
        try await run(foreignRun, taskID: foreignTask, adapter: foreign, tools: ["chat.content.list"],
            goal: "尝试索引另一个任务的 run；此查询必须拒绝，不应返回其正文引用。")
        let denialEvent = try #require(try await runs.events(runID: foreignRun).first { $0.kind == .toolResult })
        let denial = try #require(ChatInlineContentResolver.payload(denialEvent))
        #expect(denial["tool"] == "chat.content.list" && denial["status"] == "failed")
        #expect(foreign.receivedRejection)
        guard denial["status"] == "failed", foreign.receivedRejection else {
            throw FloeError.validationFailed("Foreign-task lookup was not refused; retain the QA task for inspection")
        }
        for reference in references {
            await #expect(throws: ChatInlineContentResolutionError.wrongOwner) {
                try await ChatInlineContentResolver.resolve(reference, scope: .init(conversationID: foreignTask, isTemporary: false),
                    conversations: conversations, runs: runs)
            }
        }
        // Successful negative probe owns exactly one terminal read-only run.
        // Keep the single multitype task and its real artifacts for UI review.
        let foreignOwned = try #require(try await conversations.conversation(id: foreignTask))
        let foreignRuns = try await runs.recentRuns(conversationID: foreignTask, limit: 2)
        guard foreignOwned.title == foreignTitle, foreignOwned.purpose == .ordinary,
              foreignRuns.count == 1, foreignRuns[0].id == foreignRun else { throw FloeError.unauthorized }
        try await conversations.deleteConversation(id: foreignTask)
        #expect(try await conversations.conversation(id: foreignTask) == nil)
        #expect(try await runs.run(id: foreignRun) == nil)
        let evidence: [String: Any] = ["taskID": task.uuidString, "producerRunID": producerRun.uuidString,
            "lookupRunID": lookupRun.uuidString, "firstMessageID": first.id.uuidString,
            "lookupMessageID": reopenedMessage.id.uuidString, "ownedArtifactPaths": paths,
            "artifactIDs": producedArtifacts.map { $0.id.uuidString }, "sha256": producedArtifacts.map(\.sha256),
            "foreignTaskID": foreignTask.uuidString, "foreignRunID": foreignRun.uuidString, "foreignProbeDeleted": true]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
        FileHandle.standardOutput.write(Data("FLOE_INLINE_MULTITYPE_FIXTURE|".utf8) + data + Data("\n".utf8))
    }
}
#endif
