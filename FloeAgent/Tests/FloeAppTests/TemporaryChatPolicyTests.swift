// FloeAppTests — Temporary chat read-only query ownership.
//
// A temporary (ephemeral) chat may run currently-authorized read-only tools,
// including personal-data queries. Those queries page through stable RAM-only
// snapshots, so their ownership must never outlive — or cross into — a
// different session epoch: the ephemeral conversation id is reused when an
// empty ordinary chat is converted in place and later converted again, and a
// snapshot from the previous incarnation must not be readable by the new one.
//
// The tests exercise the exact production seam the calendar/reminder handlers
// call (`ApplePersonalListPaging` + `PersonalToolOwnerID(context:)`).

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

    @Test("The temporary policy allows read-only personal tools and never the write variants")
    func temporaryCeilingAllowsPersonalReads() {
        let descriptors: [ToolCatalog.Descriptor] = [
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
        #expect(ceiling.contains("apple.calendar.list"))
        #expect(ceiling.contains("mail.read"))
        #expect(!ceiling.contains("apple.calendar.update"))
        #expect(!ceiling.contains("mail.setRead"))
        #expect(!ceiling.contains("mail.download"))
        // The read-only query must never carry an implicit mark-seen action.
        let mailRead = descriptors.first { $0.name == "mail.read" }!
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: mailRead,
            arguments: Data(#"{"action":"message"}"#.utf8)
        ) == nil)
        #expect(TemporaryChatToolPolicy.denialReason(
            descriptor: mailRead,
            arguments: Data(#"{"action":"setRead"}"#.utf8)
        ) != nil)
    }
}

// MARK: - Weather/search App composition

/// The user-visible weather/search gap was an EMPTY composed tool ceiling:
/// the old fixed web pair collapsed when no search provider was configured.
/// These tests pin the real `ConversationCenter` composition against the real
/// settings store (`WebSearchSettingsCenter.toolIsAvailable`), not a
/// synthetic policy fixture.
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
    /// public fetch, personal queries and one denied write.
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
            descriptor("workspace.writeFile", risks: [.writesFiles], sideEffecting: true),
        ]
    }

    @Test("An unconfigured search provider never leaves an empty ceiling")
    func unconfiguredSearchKeepsReadOnlyQueries() {
        let ceiling = ConversationCenter.temporaryToolCeiling(
            offeredDescriptors: offeredDescriptors(),
            webSearchAvailable: { _ in false }
        )
        // Both provider-backed search tools are absent...
        #expect(!ceiling.contains("web.search"))
        #expect(!ceiling.contains("web.searchAI"))
        // ...but the run still has real read-only capabilities, so an
        // ordinary weather/search turn can fetch or query authorized data
        // instead of facing an empty tool directory.
        #expect(ceiling.contains("web.fetch"))
        #expect(ceiling.contains("apple.calendar.list"))
        #expect(ceiling.contains("mail.read"))
        #expect(!ceiling.contains("workspace.writeFile"))
        #expect(!ceiling.isEmpty)
    }

    @Test("A configured search provider puts web.search back in the ceiling")
    func configuredSearchWidensAvailabilityOnly() {
        let ceiling = ConversationCenter.temporaryToolCeiling(
            offeredDescriptors: offeredDescriptors(),
            webSearchAvailable: { $0 == "web.search" }
        )
        #expect(ceiling.contains("web.search"))
        // bocha-only availability must not invent web.searchAI's provider.
        let bochaOnly = ConversationCenter.temporaryToolCeiling(
            offeredDescriptors: offeredDescriptors(),
            webSearchAvailable: { $0 == "web.searchAI" }
        )
        #expect(!bochaOnly.contains("web.search"))
        #expect(bochaOnly.contains("web.searchAI"))
        #expect(!bochaOnly.contains("workspace.writeFile"))
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
        #expect(ceiling.contains("web.search"))
        #expect(ceiling.contains("web.fetch"))
        #expect(ceiling.contains("apple.calendar.list"))
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

/// The read-only ceiling is enforced twice in the real runtime: the derived
/// name set narrows the offered catalog, and the canonical dispatcher
/// re-validates the descriptor AND arguments before any effect. These tests
/// exercise the SECOND layer through the production `FloeAgentRuntime` with
/// the App's real `CatalogToolExecutor`: even if a name reaches the ceiling
/// (a wrapper, alias or batch trying to widen it), a write/execution call is
/// refused and produces NO real side effect, while a verified read executes.
@Suite("FloeApp.TemporaryChatRuntimeDispatch")
@MainActor
struct TemporaryChatRuntimeDispatchTests {

    /// Scripted provider: one stream per scripted turn, then a final text
    /// turn. Never a real model.
    private final class ScriptedDispatchAdapter: ProviderAdapter, @unchecked Sendable {
        let protocolKind: ModelProtocol = .openAIChatCompletions
        private let lock = NSLock()
        private var turns: [[AgentEvent]]
        init(turns: [[AgentEvent]]) { self.turns = turns }
        func stream(
            request: ProviderStreamRequest,
            credentials: ProviderCredentials
        ) -> AsyncThrowingStream<AgentEvent, Error> {
            let turn: [AgentEvent]? = lock.withLock {
                turns.isEmpty ? nil : turns.removeFirst()
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

    @Test("A real read executes; a write and an execution are refused with no side effect")
    func temporaryDispatchRefusesWritesAndExecutions() async throws {
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

        // A verified read that is actually part of the offered catalog
        // (`crypto.hash` is a compatibility-only alias and therefore not in
        // the run's visible catalog identity).
        let readCall = try ToolCall(
            id: "temp-read-1",
            toolName: "skill.list",
            argumentsJSON: Data("{}".utf8),
            scope: .local)
        // The name is deliberately INSIDE the passed ceiling to prove the
        // dispatcher's own temporary validation (not merely the name set) is
        // what refuses it.
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
            [.toolRequest(readCall), .toolRequest(writeCall), .toolRequest(execCall)],
            [.textDelta(.init(text: "temporary run finished"))],
        ])
        let sink = DispatchAuditRecorder()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: UUID(),
                provider: provider,
                model: model,
                allowedToolNames: ["skill.list", "workspace.writeFile", "exec.shell"],
                workspaceRootURL: root,
                temporaryReadOnly: true),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: CatalogToolExecutor(),
            auditSink: sink,
            checkpointStore: nil,
            runID: UUID())

        try await runtime.start(goal: "帮我查一下天气")

        let entries = await sink.snapshot()
        // Evidence line: every decision this run really recorded.
        for entry in entries {
            print("FLOE_TEMP_DISPATCH tool=\(entry.toolName) decision=\(entry.decision) exit=\(String(describing: entry.exitStatus))")
        }
        let read = try #require(
            entries.first { $0.toolName == "skill.list" && $0.decision.hasPrefix("allow") }
                ?? entries.first { $0.toolName == "skill.list" })
        #expect(read.decision.hasPrefix("allow"), "a verified read must execute: \(read.decision)")
        // The read really produced output (its digest is recorded); its exit
        // status is tool-defined and may legitimately be absent.
        #expect(!read.outputDigestSHA256.isEmpty, "the allowed read must have produced real output")
        let write = try #require(entries.first { $0.toolName == "workspace.writeFile" })
        #expect(write.decision == "deny:temporary-readonly", "a write must be refused: \(write.decision)")
        let exec = try #require(entries.first { $0.toolName == "exec.shell" })
        #expect(exec.decision == "deny:temporary-readonly", "execution must be refused: \(exec.decision)")

        // No real side effect from the refused calls.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("denied.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("denied-exec.txt").path))
    }
}
#endif
