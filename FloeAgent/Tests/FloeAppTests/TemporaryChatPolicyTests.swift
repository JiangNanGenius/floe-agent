// FloeAppTests — Temporary chat public-web ceiling and RAM-only ownership.
//
// A temporary (ephemeral) chat offers only public web search/fetch
// (`web.search` and the Bocha AI-summary `web.searchAI` when configured, plus
// `web.fetch`). Personal-data, workspace, device and discovery reads are
// outside that ceiling even though ordinary runs may still use them.
//
// The paging ownership cases below are retained as defense-in-depth for the
// RAM snapshot mechanism (`ApplePersonalListPaging` +
// `PersonalToolOwnerID(context:)`): if a personal tool were ever invoked with
// a temporary context, its snapshot must still be owned per run, must never
// cross a session epoch, and must be revoked with the session. The policy and
// composition tests prove that this surface is not reachable in the first
// place.

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeExecution
import FloeEnvironments
import FloeTools
import FloeSecurity
import FloeAgentRuntime
@testable import FloeApp

@Suite("FloeApp.TemporaryChatPolicy")
struct TemporaryChatPolicyTests {

    private func temporaryContext(
        conversationID: UUID,
        runID: UUID = UUID()
    ) -> ToolContext {
        ToolContext(
            runID: runID,
            publicWebOnly: true,
            cancellation: CancellationToken(),
            conversationID: conversationID,
            temporaryReadOnly: true
        )
    }

    private func ordinaryContext(
        conversationID: UUID,
        runID: UUID = UUID()
    ) -> ToolContext {
        ToolContext(
            runID: runID,
            cancellation: CancellationToken(),
            conversationID: conversationID
        )
    }

    private func beginPage(context: ToolContext) async throws -> PersonalToolPage {
        try await ApplePersonalListPaging.begin(
            kind: "calendar",
            filterKey: "start=none end=none query=",
            lines: ["row-1", "row-2", "row-3"],
            context: context,
            pageSize: 2
        )
    }

    @Test("A temporary run owns its snapshots per run, not per ephemeral conversation id")
    func temporaryOwnerIsPerRun() async throws {
        // The ephemeral conversation id is reused by a later session epoch.
        let ephemeralConversation = UUID()
        let firstRun = temporaryContext(conversationID: ephemeralConversation)
        let owner = PersonalToolOwnerID(context: firstRun)
        #expect(owner.conversationID == nil)
        #expect(owner.environmentID == nil)
        #expect(owner.fallbackRunID == firstRun.runID)

        let page = try await beginPage(context: firstRun)
        let cursor = try #require(page.nextCursor)

        // The SAME run may keep paging its own snapshot.
        let continued = try await ApplePersonalListPaging.next(
            cursor: cursor,
            context: temporaryContext(conversationID: ephemeralConversation, runID: firstRun.runID),
            kind: "calendar",
            filterKey: nil,
            pageSize: 2
        )
        #expect(continued.returnedCount == 1)
        #expect(!continued.hasMore)

        // A replacement session (or a later run of the same ephemeral id) is
        // NOT the owner: it must never read the previous run's personal rows.
        do {
            _ = try await ApplePersonalListPaging.next(
                cursor: cursor,
                context: temporaryContext(conversationID: ephemeralConversation),
                kind: "calendar",
                filterKey: nil,
                pageSize: 2
            )
            Issue.record("a replacement temporary run must not page another run's snapshot")
        } catch let error as PersonalToolCursorError {
            #expect(error == .notOwned)
        }
    }

    @Test("Ordinary runs keep conversation-scoped continuation across runs")
    func ordinaryOwnerKeepsConversationOwnership() async throws {
        let conversation = UUID()
        let first = ordinaryContext(conversationID: conversation)
        let page = try await beginPage(context: first)
        let cursor = try #require(page.nextCursor)
        let owner = PersonalToolOwnerID(context: first)
        #expect(owner.conversationID == conversation)
        // A new run of the SAME ordinary conversation continues the snapshot.
        let continued = try await ApplePersonalListPaging.next(
            cursor: cursor,
            context: ordinaryContext(conversationID: conversation),
            kind: "calendar",
            filterKey: nil,
            pageSize: 2
        )
        #expect(continued.returnedCount == 1)
    }

    @Test("Revoking by run identity drops temporary snapshots without touching others")
    func revokeByRunIdentityIsScoped() async throws {
        let temporaryRun = temporaryContext(conversationID: UUID())
        let otherTemporaryRun = temporaryContext(conversationID: UUID())
        let ordinary = ordinaryContext(conversationID: UUID())
        let temporaryPage = try await beginPage(context: temporaryRun)
        let otherPage = try await beginPage(context: otherTemporaryRun)
        let ordinaryPage = try await beginPage(context: ordinary)
        let temporaryCursor = try #require(temporaryPage.nextCursor)
        let otherCursor = try #require(otherPage.nextCursor)
        let ordinaryCursor = try #require(ordinaryPage.nextCursor)

        // Ending one temporary session revokes exactly its runs.
        await PersonalToolCursorStore.shared.revoke(
            fallbackRunIDs: [temporaryRun.runID]
        )

        do {
            _ = try await ApplePersonalListPaging.next(
                cursor: temporaryCursor,
                context: temporaryContext(conversationID: UUID(), runID: temporaryRun.runID),
                kind: "calendar",
                filterKey: nil,
                pageSize: 2
            )
            Issue.record("the revoked temporary snapshot must be gone")
        } catch let error as PersonalToolCursorError {
            #expect(error == .unknown)
        }

        // Another temporary session's snapshot and the ordinary snapshot are
        // untouched by that revocation.
        let otherContinued = try await ApplePersonalListPaging.next(
            cursor: otherCursor,
            context: temporaryContext(conversationID: UUID(), runID: otherTemporaryRun.runID),
            kind: "calendar",
            filterKey: nil,
            pageSize: 2
        )
        #expect(otherContinued.returnedCount == 1)
        let ordinaryContinued = try await ApplePersonalListPaging.next(
            cursor: ordinaryCursor,
            context: ordinaryContext(conversationID: ordinary.conversationID ?? UUID()),
            kind: "calendar",
            filterKey: nil,
            pageSize: 2
        )
        #expect(ordinaryContinued.returnedCount == 1)

        // Empty revocation sets are a no-op.
        await PersonalToolCursorStore.shared.revoke(fallbackRunIDs: [])
        let stillThere = try await ApplePersonalListPaging.next(
            cursor: otherCursor,
            context: temporaryContext(conversationID: UUID(), runID: otherTemporaryRun.runID),
            kind: "calendar",
            filterKey: nil,
            pageSize: 2
        )
        #expect(stillThere.returnedCount == 1)
    }

    @Test("The temporary policy keeps only public web search/fetch, never private or write tools")
    func temporaryCeilingIsPublicWebOnly() {
        let descriptors: [ToolCatalog.Descriptor] = [
            ToolCatalog.Descriptor(
                name: "web.fetch",
                riskLabels: [.networkAccess],
                isSideEffecting: false,
                effect: .readOnly
            ),
            ToolCatalog.Descriptor(
                name: "web.search",
                riskLabels: [.networkAccess],
                isSideEffecting: false,
                effect: .readOnly
            ),
            ToolCatalog.Descriptor(
                name: "web.searchAI",
                riskLabels: [.networkAccess],
                isSideEffecting: false,
                effect: .readOnly
            ),
            ToolCatalog.Descriptor(
                name: "apple.calendar.list",
                riskLabels: [.persistsPersonalData],
                isSideEffecting: false
            ),
            ToolCatalog.Descriptor(
                name: "mail.read",
                parametersJSON: #"{"type":"object","properties":{"action":{"type":"string","enum":["folders","list","message"]}},"required":["action"],"additionalProperties":false}"#,
                riskLabels: [.networkAccess, .accessesCredentials],
                isSideEffecting: false
            ),
            ToolCatalog.Descriptor(
                name: "notes.read",
                riskLabels: [.readsFiles],
                isSideEffecting: false
            ),
            ToolCatalog.Descriptor(
                name: "skill.list",
                riskLabels: [],
                isSideEffecting: false
            ),
            ToolCatalog.Descriptor(
                name: "apple.calendar.update",
                riskLabels: [.persistsPersonalData],
                isSideEffecting: true
            ),
            ToolCatalog.Descriptor(
                name: "mail.setRead",
                riskLabels: [.networkAccess, .accessesCredentials, .persistsPersonalData],
                isSideEffecting: true
            ),
            ToolCatalog.Descriptor(
                name: "mail.download",
                riskLabels: [.networkAccess, .accessesCredentials, .writesFiles],
                isSideEffecting: true
            ),
        ]
        let ceiling = TemporaryChatToolPolicy.allowedToolNames(from: descriptors)
        #expect(ceiling == ["web.fetch", "web.search", "web.searchAI"])
        for name in [
            "apple.calendar.list", "mail.read", "notes.read",
            "skill.list", "apple.calendar.update", "mail.setRead", "mail.download",
        ] {
            #expect(!ceiling.contains(name), "\(name) is outside temporary chat")
        }
        // Private reads are refused at execution even with ordinary-looking
        // read arguments; the public pair is accepted when the provider is.
        for name in ["apple.calendar.list", "mail.read", "notes.read", "skill.list"] {
            let descriptor = descriptors.first { $0.name == name }!
            #expect(TemporaryChatToolPolicy.denialReason(
                descriptor: descriptor,
                arguments: Data(#"{"action":"message"}"#.utf8)
            ) != nil, "\(name) must be denied")
        }
        let webFetch = descriptors.first { $0.name == "web.fetch" }!
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: webFetch,
            arguments: Data(#"{"url":"https://example.com"}"#.utf8)
        ) == nil)
        let aiSearch = descriptors.first { $0.name == "web.searchAI" }!
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: aiSearch,
            arguments: Data(#"{"query":"weather summary"}"#.utf8)
        ) == nil)
    }
}

// MARK: - Public web App composition

/// Temporary chat always keeps the public-web-only ceiling, but provider
/// readiness is a separate gate: each provider-backed search tool is removed
/// until its provider is configured, while `web.fetch` remains usable without
/// any provider. These tests pin the real `ConversationCenter` composition
/// against the real settings store (`WebSearchSettingsCenter.toolIsAvailable`),
/// not a synthetic policy-only fixture.
@Suite("FloeApp.TemporaryChatComposition")
struct TemporaryChatCompositionTests {

    private func descriptor(
        _ name: String,
        schema: String = #"{"type":"object","additionalProperties":false}"#,
        risks: Set<RiskLabel>,
        sideEffecting: Bool = false,
        effect: ToolEffect? = nil
    ) -> ToolCatalog.Descriptor {
        ToolCatalog.Descriptor(
            name: name,
            parametersJSON: schema,
            riskLabels: risks,
            isSideEffecting: sideEffecting,
            effect: effect
        )
    }

    /// The real catalog slice a temporary chat offers: provider-backed search,
    /// public fetch, private reads and one denied write. Only public web
    /// search/fetch tools may survive composition.
    private func offeredDescriptors() -> [ToolCatalog.Descriptor] {
        [
            descriptor("web.search", risks: [.networkAccess], effect: .readOnly),
            descriptor("web.searchAI", risks: [.networkAccess], effect: .readOnly),
            descriptor("web.fetch", risks: [.networkAccess], effect: .readOnly),
            descriptor("apple.calendar.list", risks: [.persistsPersonalData]),
            descriptor(
                "mail.read",
                schema: #"{"type":"object","properties":{"action":{"type":"string","enum":["folders","list","message"]}},"required":["action"],"additionalProperties":false}"#,
                risks: [.networkAccess, .accessesCredentials]
            ),
            descriptor("notes.read", risks: [.readsFiles]),
            descriptor("skill.list", risks: []),
            descriptor("workspace.writeFile", risks: [.writesFiles], sideEffecting: true),
        ]
    }

    @Test("An unconfigured search provider leaves exactly the public fetch tool")
    func unconfiguredSearchKeepsPublicFetchOnly() {
        let ceiling = ConversationCenter.temporaryToolCeiling(
            offeredDescriptors: offeredDescriptors(),
            webSearchAvailable: { _ in false }
        )
        // Both provider-backed search tools are absent...
        #expect(!ceiling.contains("web.search"))
        #expect(!ceiling.contains("web.searchAI"))
        // ...and no private read fills the gap. `web.fetch` needs no provider
        // and stays available for an ordinary public page research turn.
        #expect(ceiling == ["web.fetch"])
    }

    @Test("Each configured provider adds only its own public search tool")
    func configuredProvidersAddOnlyTheirSearchTool() {
        let webOnly = ConversationCenter.temporaryToolCeiling(
            offeredDescriptors: offeredDescriptors(),
            webSearchAvailable: { $0 == "web.search" }
        )
        #expect(webOnly == ["web.search", "web.fetch"])
        // Provider-filter probe: Bocha's AI-summary tool is a public web read,
        // and it survives when the composition is told only that tool's
        // provider is ready. (The real `toolIsAvailable` treats any ready
        // search provider as enabling web.search too; that any-ready case is
        // covered below.)
        let bochaOnly = ConversationCenter.temporaryToolCeiling(
            offeredDescriptors: offeredDescriptors(),
            webSearchAvailable: { $0 == "web.searchAI" }
        )
        #expect(bochaOnly == ["web.searchAI", "web.fetch"])
        // Any-ready covers the ordinary any-provider case (including Bocha,
        // whose provider also satisfies web.search's availability check).
        let anyReady = ConversationCenter.temporaryToolCeiling(
            offeredDescriptors: offeredDescriptors(),
            webSearchAvailable: { _ in true }
        )
        #expect(anyReady == ["web.search", "web.searchAI", "web.fetch"])
        // No private read fills any provider gap.
        for ceiling in [webOnly, bochaOnly, anyReady] {
            #expect(!ceiling.contains("apple.calendar.list"))
            #expect(!ceiling.contains("mail.read"))
            #expect(!ceiling.contains("notes.read"))
            #expect(!ceiling.contains("workspace.writeFile"))
        }
    }

    @Test("The real settings store reports a seeded provider as available")
    func realSettingsStoreComposition() throws {
        let defaults = UserDefaults.standard
        let key = WebSearchSettingsCenter.defaultsKey
        let original = defaults.data(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        // SearXNG needs no credential: an enabled provider with a valid HTTPS
        // endpoint is "configured" through the same function the run uses.
        defaults.set(try JSONEncoder().encode([
            WebSearchProviderConfiguration(
                kind: .searxng,
                displayName: "Test SearXNG",
                endpoint: URL(string: "https://searx.example.org")!,
                credentialAccount: "web-search.searxng",
                enabled: true,
                priority: 0
            )
        ]), forKey: key)
        #expect(WebSearchSettingsCenter.toolIsAvailable("web.search"))
        let ceiling = ConversationCenter.temporaryToolCeiling(
            offeredDescriptors: offeredDescriptors()
        )
        #expect(ceiling == ["web.search", "web.fetch"])
        #expect(!ceiling.contains("apple.calendar.list"))
        #expect(!ceiling.contains("mail.read"))
        #expect(!ceiling.contains("notes.read"))
        #expect(!ceiling.contains("workspace.writeFile"))
    }
}

// MARK: - Explicit run environment binding

/// `ConversationCenter.runBoundExecutionEnvironmentID` turns the runtime's
/// explicit `environmentID` into an actual binding. It must resolve EXACTLY
/// this conversation's own Linux session container for EXACTLY this task
/// workspace root: never "the first project environment", never another
/// conversation's container and never a container of a different workspace.
@Suite("FloeApp.RunEnvironmentBinding")
@MainActor
struct RunEnvironmentBindingTests {

    @Test("Only this conversation's own Linux container for this workspace root binds")
    func bindingRequiresOwnContainerAndMatchingRoot() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("env-binding-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let registry = EnvironmentRegistry(
            roots: EnvironmentRoots(rootURL: base), baseRevision: "test-binding")
        let workspaceA = base.appendingPathComponent("workspaceA", isDirectory: true)
        let workspaceB = base.appendingPathComponent("workspaceB", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceB, withIntermediateDirectories: true)
        let workspaceAID = FloeDigest.sha256Hex(
            Data(workspaceA.resolvingSymlinksInPath().standardizedFileURL.path.utf8))

        let conversation = UUID()
        let session = try await registry.ensureSessionContainer(
            conversationID: conversation.uuidString,
            workspaceID: workspaceAID,
            workspaceRootPath: workspaceA.path,
            executionBackend: .linuxVM)

        // Own container + the same root → bound.
        #expect(await ConversationCenter.runBoundExecutionEnvironmentID(
            registry: registry, conversationID: conversation, workspaceRoot: workspaceA) == session.id)
        // A different task root never falls back to that container.
        #expect(await ConversationCenter.runBoundExecutionEnvironmentID(
            registry: registry, conversationID: conversation, workspaceRoot: workspaceB) == nil)
        // No container for this conversation → nil.
        #expect(await ConversationCenter.runBoundExecutionEnvironmentID(
            registry: registry, conversationID: UUID(), workspaceRoot: workspaceA) == nil)

        // Another conversation's container for the same root is never used.
        _ = try await registry.ensureSessionContainer(
            conversationID: UUID().uuidString,
            workspaceID: workspaceAID,
            workspaceRootPath: workspaceA.path,
            executionBackend: .linuxVM)
        #expect(await ConversationCenter.runBoundExecutionEnvironmentID(
            registry: registry, conversationID: conversation, workspaceRoot: workspaceA) == session.id)

        // A native-backend session is not the explicit Linux VM binding.
        let nativeConversation = UUID()
        _ = try await registry.ensureSessionContainer(
            conversationID: nativeConversation.uuidString,
            workspaceID: workspaceAID,
            workspaceRootPath: workspaceA.path,
            executionBackend: .native)
        #expect(await ConversationCenter.runBoundExecutionEnvironmentID(
            registry: registry, conversationID: nativeConversation, workspaceRoot: workspaceA) == nil)
    }

    /// The fresh-run regression: a brand-new ordinary run (no session
    /// container yet) must be explicitly bound BEFORE the runtime is
    /// configured, for exactly its own root, without starting any VM and
    /// without ever selecting another conversation's or root's container.
    @Test("A fresh ordinary run is bound to its own root with no VM started")
    func freshRunGetsExplicitBindingWithoutVM() async throws {
        let environment = AppEnvironment.live()
        await environment.bootstrap()
        let services = FloePlatformServices.shared
        let registry = environment.environmentRegistry
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fresh-run-root-\(UUID().uuidString)", isDirectory: true)
        let unrelated = FileManager.default.temporaryDirectory
            .appendingPathComponent("unrelated-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: unrelated)
        }

        let conversation = UUID()
        // The App's own workspace-open path creates the project container; no
        // session container exists for this conversation yet.
        try await services.prepareWorkspaceEnvironment(root: root)

        let bound = await ConversationCenter.ensureRunEnvironmentBinding(
            registry: registry, conversationID: conversation, taskRoot: root)
        let environmentID = try #require(bound, "a fresh ordinary run must be explicitly bound")
        let record = try #require(await registry.record(id: environmentID))
        #expect(record.kind == .session)
        #expect(record.ownerID == conversation.uuidString)
        #expect(record.effectiveExecutionBackend == .linuxVM)
        let recordedRoot = try #require(try await registry.workspaceRoot(for: environmentID))
        #expect(recordedRoot.resolvingSymlinksInPath().standardizedFileURL
                == root.resolvingSymlinksInPath().standardizedFileURL,
                "the binding must be exactly this run's root")

        // Metadata creation must not have started the guest.
        #expect(await services.linuxEnvironmentAvailable(id: environmentID) == false,
                "creating the environment metadata must not start a VM")

        // Another conversation on an unrelated root gets its own container;
        // neither binding moves, and an unrelated root is never chosen.
        let otherConversation = UUID()
        try await services.prepareWorkspaceEnvironment(root: unrelated)
        let otherBound = try #require(await ConversationCenter.ensureRunEnvironmentBinding(
            registry: registry, conversationID: otherConversation, taskRoot: unrelated))
        #expect(otherBound != environmentID)
        let otherRecord = try #require(await registry.record(id: otherBound))
        #expect(otherRecord.ownerID == otherConversation.uuidString)
        let otherRoot = try #require(try await registry.workspaceRoot(for: otherBound))
        #expect(otherRoot.resolvingSymlinksInPath().standardizedFileURL
                == unrelated.resolvingSymlinksInPath().standardizedFileURL)
        #expect(await ConversationCenter.ensureRunEnvironmentBinding(
            registry: registry, conversationID: conversation, taskRoot: root) == environmentID,
                "the run's own binding must stay stable")

        // Temporary-style nil root and canvas-style exclusion: nil binding and
        // no container invented.
        #expect(await ConversationCenter.ensureRunEnvironmentBinding(
            registry: registry, conversationID: UUID(), taskRoot: nil) == nil)

        // Cleanup: remove only the containers this test created.
        _ = try? await registry.remove(id: otherBound)
        _ = try? await registry.remove(id: environmentID)
        for temporaryRoot in [root, unrelated] {
            let workspaceID = FloeDigest.sha256Hex(
                Data(temporaryRoot.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
            if let project = await registry.containersOwned(by: workspaceID)
                .first(where: { $0.kind == .project }) {
                _ = try? await registry.remove(id: project.id)
            }
        }
    }
}

// MARK: - Temporary chat at the canonical dispatcher

/// The public-web ceiling is enforced twice in the real runtime: the derived
/// name set narrows the offered catalog, and the canonical dispatcher
/// re-validates the public web tools (descriptor AND arguments) before any
/// effect. This test exercises the SECOND layer through the production
/// `FloeAgentRuntime` with a recording executor: even if a wider name set
/// reaches the runtime (a wrapper, alias or batch trying to widen it), private
/// reads, writes and executions are refused with no real side effect, while
/// `web.fetch` still executes. A recording executor avoids any real network
/// request while preserving the exact runtime dispatch path under test.
@Suite("FloeApp.TemporaryChatRuntimeDispatch")
@MainActor
struct TemporaryChatRuntimeDispatchTests {

    /// Scripted provider: one stream per scripted turn, then a final text
    /// turn. Never a real model.
    private final class ScriptedDispatchAdapter: ProviderAdapter, @unchecked Sendable {
        let protocolKind: ModelProtocol = .openAIChatCompletions
        private let lock = NSLock()
        private var turns: [[AgentEvent]]
        private var requestStorage: [ProviderStreamRequest] = []
        var requests: [ProviderStreamRequest] { lock.withLock { requestStorage } }
        init(turns: [[AgentEvent]]) { self.turns = turns }
        func stream(
            request: ProviderStreamRequest,
            credentials: ProviderCredentials
        ) -> AsyncThrowingStream<AgentEvent, Error> {
            let turn: [AgentEvent]? = lock.withLock {
                requestStorage.append(request)
                return turns.isEmpty ? nil : turns.removeFirst()
            }
            return AsyncThrowingStream { continuation in
                if let turn {
                    for event in turn { continuation.yield(event) }
                } else {
                    continuation.yield(.textDelta(.init(text: "scripted final answer")))
                }
                continuation.yield(.completed(.init(stopReason: .endTurn)))
                continuation.finish()
            }
        }
        func listModels(
            provider: ProviderProfile,
            credentials: ProviderCredentials
        ) async throws -> [ModelProfile] { [] }
    }

    private actor DispatchAuditRecorder: AuditSink {
        private(set) var entries: [AuditEntry] = []
        func record(_ entry: AuditEntry) async throws { entries.append(entry) }
        func snapshot() -> [AuditEntry] { entries }
    }

    /// Records the calls the canonical dispatcher actually executed. Its
    /// descriptors mirror the production metadata for the public pair and the
    /// private/write tools; execution itself is inert.
    private final class DispatchRecordingExecutor: ToolExecutor, @unchecked Sendable {
        struct Entry {
            var call: ToolCall
            var context: ToolContext
        }

        private let lock = NSLock()
        private var storage: [Entry] = []
        private let descriptors: [String: ToolCatalog.Descriptor] = [
            "web.fetch": .init(
                name: "web.fetch", riskLabels: [.networkAccess],
                isSideEffecting: false, effect: .readOnly),
            "web.searchAI": .init(
                name: "web.searchAI", riskLabels: [.networkAccess],
                isSideEffecting: false, effect: .readOnly),
            "notes.read": .init(
                name: "notes.read", riskLabels: [.readsFiles],
                isSideEffecting: false, effect: .readOnly),
            "skill.list": .init(
                name: "skill.list", riskLabels: [],
                isSideEffecting: false, effect: .readOnly),
            "workspace.writeFile": .init(
                name: "workspace.writeFile", riskLabels: [.writesFiles],
                isSideEffecting: true, effect: .mutating),
            "exec.shell": .init(
                name: "exec.shell", riskLabels: [.executesLocalCode],
                isSideEffecting: true, effect: .mutating),
        ]

        var entries: [Entry] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        func descriptor(named name: String) -> ToolCatalog.Descriptor? { descriptors[name] }
        var allDescriptors: [ToolCatalog.Descriptor] {
            descriptors.values.sorted { $0.name < $1.name }
        }

        func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
            try context.cancellation.throwIfCancelled()
            lock.withLock { storage.append(Entry(call: call, context: context)) }
            return ToolResult(callID: call.id, status: .ok, outputSummary: "ok", outputDigest: "d")
        }
    }

    @Test("Only web.fetch executes; private reads, writes and executions are refused")
    func temporaryDispatchRefusesPrivateReadsAndWrites() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("temporary-dispatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://temporary-dispatch.example/v1")!,
            displayName: "Scripted Temporary Provider")
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "scripted-temporary-model",
            displayName: "Scripted Temporary Model",
            limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.tools])

        let readCall = try ToolCall(
            id: "temp-read-1",
            toolName: "web.fetch",
            argumentsJSON: Data(#"{"url":"https://example.com"}"#.utf8),
            scope: .local)
        let aiSearchCall = try ToolCall(
            id: "temp-ai-1",
            toolName: "web.searchAI",
            argumentsJSON: Data(#"{"query":"weather summary"}"#.utf8),
            scope: .local)
        // These names are deliberately INSIDE the passed ceiling to prove the
        // dispatcher's own temporary validation (not merely the name set) is
        // what refuses them.
        let notesCall = try ToolCall(
            id: "temp-notes-1",
            toolName: "notes.read",
            argumentsJSON: Data("{}".utf8),
            scope: .local)
        let skillCall = try ToolCall(
            id: "temp-skill-1",
            toolName: "skill.list",
            argumentsJSON: Data("{}".utf8),
            scope: .local)
        let writeCall = try ToolCall(
            id: "temp-write-1",
            toolName: "workspace.writeFile",
            argumentsJSON: Data(#"{"path":"denied.txt","content":"must not be written"}"#.utf8),
            scope: .local)
        let execCall = try ToolCall(
            id: "temp-exec-1",
            toolName: "exec.shell",
            argumentsJSON: Data(#"{"command":"printf executed > denied-exec.txt"}"#.utf8),
            scope: .local)
        let adapter = ScriptedDispatchAdapter(turns: [
            [.toolRequest(readCall), .toolRequest(aiSearchCall), .toolRequest(notesCall),
             .toolRequest(skillCall), .toolRequest(writeCall), .toolRequest(execCall)],
            [.textDelta(.init(text: "temporary run finished"))],
        ])
        let sink = DispatchAuditRecorder()
        let executor = DispatchRecordingExecutor()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: provider,
                model: model,
                allowedToolNames: [
                    "web.fetch", "web.searchAI", "notes.read", "skill.list",
                    "workspace.writeFile", "exec.shell",
                ],
                workspaceRootURL: root,
                publicWebOnly: true,
                temporaryReadOnly: true),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: executor,
            auditSink: sink,
            checkpointStore: nil,
            runID: UUID())

        try await runtime.start(goal: "用 web.searchAI 搜索并用 web.fetch 打开公共网页")

        let entries = await sink.snapshot()
        // Evidence line: every decision this run really recorded.
        for entry in entries {
            print("FLOE_TEMP_DISPATCH tool=\(entry.toolName) decision=\(entry.decision) exit=\(String(describing: entry.exitStatus))")
        }
        // Only the public web tools reached the executor.
        #expect(Set(executor.entries.map(\.call.id)) == ["temp-read-1", "temp-ai-1"])
        #expect(executor.entries.first?.context.temporaryReadOnly == true)
        #expect(executor.entries.first?.context.publicWebOnly == true)
        for name in ["web.fetch", "web.searchAI"] {
            let allowed = try #require(
                entries.first { $0.toolName == name && $0.decision.hasPrefix("allow") })
            #expect(!allowed.outputDigestSHA256.isEmpty,
                    "\(name) must have produced real output")
        }
        for name in ["notes.read", "skill.list", "workspace.writeFile", "exec.shell"] {
            let denied = try #require(entries.first { $0.toolName == name })
            #expect(denied.decision == "deny:temporary-readonly",
                    "\(name) must be refused: \(denied.decision)")
        }
        // The provider wire never advertises the private or write tools.
        let wire = try #require(adapter.requests.first)
        let wireNames = Set(wire.toolSchemas.map(\.name)).union(wire.allToolNames)
        #expect(wireNames.contains("web.fetch"))
        #expect(wireNames.contains("web.searchAI"))
        for name in ["notes.read", "skill.list", "workspace.writeFile", "exec.shell"] {
            #expect(!wireNames.contains(name), "\(name) must not reach the wire")
        }

        // No real side effect from the refused calls.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("denied.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("denied-exec.txt").path))
    }
}
#endif
