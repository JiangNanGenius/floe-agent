// FloeAppTests — Launch-time original-write fence for explicit bound design
// modification/restructure tasks. The freeze MUST be engaged inside
// `ConversationCenter.startTask` before the deferred run task can reach the
// provider or any tool, so the run's FIRST ordinary mutating call already
// hits the barrier: the original bytes stay unchanged, the write is refused
// with the structured design-freeze denial, reads and unrelated/staging
// writes stay open, and a task WITHOUT a design binding is unaffected.

#if canImport(UIKit)
import Foundation
import Testing
import UIKit
import FloeCore
import FloeModels
import FloePersistence
import FloeWorkspace
import FloeTools
@testable import FloeApp

@Suite("FloeApp.DesignFreezeLaunch")
@MainActor
struct DesignFreezeLaunchTests {
    private final class Fixture: @unchecked Sendable {
        let environment: AppEnvironment
        let workspaceRoot: URL
        let workspaceID: UUID
        let registry: DesignFreezeRegistry
        let registryStoreDirectory: URL

        init(environment: AppEnvironment) throws {
            self.environment = environment
            workspaceRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-freeze-launch-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: workspaceRoot, withIntermediateDirectories: true)
            let storeDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("floe-freeze-launch-store-\(UUID().uuidString)", isDirectory: true)
            registryStoreDirectory = storeDirectory
            registry = DesignFreezeRegistry(store: .init(directory: storeDirectory))
            workspaceID = UUID()
        }

        deinit {
            DesignFreezeProtectionCoordinator.registryOverride = nil
            try? FileManager.default.removeItem(at: workspaceRoot)
        }
    }

    private func makeFixture() async throws -> Fixture {
        let fixture = try Fixture(environment: AppEnvironment.preview())
        try await fixture.environment.database.migrate()
        DesignFreezeProtectionCoordinator.registryOverride = fixture.registry
        let bookmark = try fixture.workspaceRoot.bookmarkData(options: .minimalBookmark)
        let workspaceStore = SQLiteWorkspaceStore(database: fixture.environment.database)
        try await workspaceStore.saveWorkspace(WorkspaceRecord(
            id: fixture.workspaceID,
            name: "Freeze Launch Workspace",
            rootBookmark: bookmark,
            kind: .project))
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://freeze-launch.example/v1")!,
            displayName: "Freeze Launch Provider")
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "freeze-launch-model",
            displayName: "Freeze Launch Model",
            limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.tools])
        try await fixture.environment.configurationStore.saveProvider(provider)
        try await fixture.environment.configurationStore.saveModel(model)
        return fixture
    }

    private func model(_ fixture: Fixture) async throws -> (ProviderProfile, ModelProfile) {
        let provider = try #require(try await fixture.environment.configurationStore.providers().first)
        let model = try #require(try await fixture.environment.configurationStore.models(providerID: provider.id).first)
        return (provider, model)
    }

    private func writeOriginal(_ fixture: Fixture) throws {
        try "<h1>original</h1>".write(
            to: fixture.workspaceRoot.appendingPathComponent("index.html"),
            atomically: true, encoding: .utf8)
    }

    private func gatedService(_ fixture: Fixture) -> WorkspaceFileService {
        WorkspaceFileService(
            guard: WorkspacePathGuard(rootURL: fixture.workspaceRoot),
            mutationGuard: WorkspaceToolEnvironment.designFreezeGate(
                registry: fixture.registry))
    }

    @Test("startTask freezes the file target: the run's FIRST mutating call is refused and the original is unchanged")
    func launchFreezesBeforeFirstMutatingCall() async throws {
        let fixture = try await makeFixture()
        try writeOriginal(fixture)
        let original = fixture.workspaceRoot.appendingPathComponent("index.html")
        let center = fixture.environment.conversationCenter
        let (provider, model) = try await model(fixture)
        let binding = DesignLaunchBinding(
            target: DesignOwnerTargets.file(
                workspaceID: fixture.workspaceID, relativePath: "index.html"),
            workMode: .modify,
            originalConversationID: nil)

        let started = try await center.startTask(
            goal: "把首屏标题改得更有冲击力",
            title: "首屏修改",
            provider: provider,
            model: model,
            workspaceID: fixture.workspaceID,
            designLaunchBinding: binding,
            startOrigin: .explicitUserAction)
        defer {
            DesignFreezeProtectionCoordinator.release(conversationID: started.conversationID)
        }

        // The freeze is live BEFORE the deferred run task could reach any
        // tool: the registry holds the protection for the exact original.
        let protection = try #require(fixture.registry.protection(for: original))
        #expect(protection.conversationID == started.conversationID.uuidString.lowercased())

        // The run's FIRST ordinary mutating call is refused with the
        // structured design-freeze denial and the original bytes are intact.
        let service = gatedService(fixture)
        #expect(throws: DesignFreezeError.self) {
            _ = try service.writeFile("index.html", content: "<h1>clobbered</h1>")
        }
        #expect(try String(contentsOf: original, encoding: .utf8) == "<h1>original</h1>")

        // Reads, unrelated writes and staging writes stay open.
        let read = try service.readFile("index.html")
        #expect(read.text == "<h1>original</h1>")
        _ = try service.createFile("drafts/variant-a.html", content: "<h1>candidate</h1>")
    }

    @Test("a restructure-bound file task is frozen at launch with its whole-request identity")
    func restructureBindingFreezesAtLaunch() async throws {
        let fixture = try await makeFixture()
        try writeOriginal(fixture)
        let original = fixture.workspaceRoot.appendingPathComponent("index.html")
        let center = fixture.environment.conversationCenter
        let (provider, model) = try await model(fixture)
        let operationID = "restructure-\(UUID().uuidString.lowercased())"
        let binding = DesignLaunchBinding(
            target: DesignOwnerTargets.file(
                workspaceID: fixture.workspaceID, relativePath: "index.html"),
            workMode: .restructure,
            preservation: DesignPreservationConstraints(
                content: ["品牌标语"], data: [], behavior: ["导航链接"], formatBounds: ["html"]),
            originalConversationID: nil,
            frozenRestructureOperationID: operationID)

        let started = try await center.startTask(
            goal: "重构这个页面但保留品牌标语和导航",
            title: "首屏重构",
            provider: provider,
            model: model,
            workspaceID: fixture.workspaceID,
            designLaunchBinding: binding,
            startOrigin: .explicitUserAction)
        defer {
            DesignFreezeProtectionCoordinator.release(conversationID: started.conversationID)
        }
        let protection = try #require(fixture.registry.protection(for: original))
        #expect(protection.conversationID == started.conversationID.uuidString.lowercased())
        // The durable binding carries the whole-request restructure identity.
        let stored = try #require(DesignLaunchBindingStore.load(conversationID: started.conversationID))
        #expect(stored.workMode == .restructure)
        #expect(stored.frozenRestructureOperationID == operationID)
        #expect(stored.preservationDigest != nil)
    }

    @Test("an ordinary task without a design binding leaves the same file writable")
    func unboundTaskLeavesFileWritable() async throws {
        let fixture = try await makeFixture()
        try writeOriginal(fixture)
        let original = fixture.workspaceRoot.appendingPathComponent("index.html")
        let center = fixture.environment.conversationCenter
        let (provider, model) = try await model(fixture)
        let started = try await center.startTask(
            goal: "随便聊聊这个文件",
            title: "普通任务",
            provider: provider,
            model: model,
            workspaceID: fixture.workspaceID,
            startOrigin: .explicitUserAction)
        _ = started
        // No binding → no freeze → the ordinary write path is untouched.
        #expect(fixture.registry.protection(for: original) == nil)
        let service = gatedService(fixture)
        _ = try service.writeFile("index.html", content: "<h1>edited</h1>")
        #expect(try String(contentsOf: original, encoding: .utf8) == "<h1>edited</h1>")
    }

    @Test("chat-attachment bindings never freeze workspace files")
    func chatAttachmentBindingFreezesNothing() async throws {
        let fixture = try await makeFixture()
        try writeOriginal(fixture)
        let original = fixture.workspaceRoot.appendingPathComponent("index.html")
        let center = fixture.environment.conversationCenter
        let (provider, model) = try await model(fixture)
        let attachmentID = UUID()
        let binding = DesignLaunchBinding(
            target: DesignOwnerTargets.chatAttachment(
                conversationID: UUID(), messageID: UUID(), attachmentID: attachmentID),
            workMode: .modify,
            originalConversationID: nil)
        let started = try await center.startTask(
            goal: "基于这个附件做修改",
            title: "附件任务",
            provider: provider,
            model: model,
            workspaceID: fixture.workspaceID,
            designLaunchBinding: binding,
            startOrigin: .explicitUserAction)
        defer {
            DesignFreezeProtectionCoordinator.release(conversationID: started.conversationID)
        }
        // Chat attachments live in app storage: workspace files stay writable.
        #expect(fixture.registry.protection(for: original) == nil)
    }

    @Test("a modify/restructure launch whose original cannot be frozen FAILS CLOSED: no unprotected run starts")
    func launchFailsClosedWhenProtectionCannotBeEstablished() async throws {
        let fixture = try await makeFixture()
        // The original file does NOT exist: the freeze cannot be established.
        let center = fixture.environment.conversationCenter
        let (provider, model) = try await model(fixture)
        let binding = DesignLaunchBinding(
            target: DesignOwnerTargets.file(
                workspaceID: fixture.workspaceID, relativePath: "index.html"),
            workMode: .modify,
            originalConversationID: nil)
        await #expect(throws: (any Error).self) {
            _ = try await center.startTask(
                goal: "修改不存在的原文件",
                title: "冻结失败",
                provider: provider,
                model: model,
                workspaceID: fixture.workspaceID,
                designLaunchBinding: binding,
                startOrigin: .explicitUserAction)
        }
        // No protection half-exists, and nothing is frozen.
        #expect(fixture.registry.allProtections().isEmpty)
        // The original path is still writable by ordinary tools.
        let service = gatedService(fixture)
        _ = try service.createFile("index.html", content: "<h1>created later</h1>")
    }

    @Test("a bound modify launch persists the freeze durably: a fresh registry over the same store proves it")
    func launchFreezeIsDurableAcrossReload() async throws {
        let fixture = try await makeFixture()
        try writeOriginal(fixture)
        let original = fixture.workspaceRoot.appendingPathComponent("index.html")
        let center = fixture.environment.conversationCenter
        let (provider, model) = try await model(fixture)
        let binding = DesignLaunchBinding(
            target: DesignOwnerTargets.file(
                workspaceID: fixture.workspaceID, relativePath: "index.html"),
            workMode: .modify,
            originalConversationID: nil)
        let started = try await center.startTask(
            goal: "持久冻结验证",
            title: "持久冻结",
            provider: provider,
            model: model,
            workspaceID: fixture.workspaceID,
            designLaunchBinding: binding,
            startOrigin: .explicitUserAction)
        defer {
            DesignFreezeProtectionCoordinator.release(conversationID: started.conversationID)
        }
        // Durable proof: a fresh registry over the SAME store directory sees
        // the exact (path, owner) entry — in-memory presence alone is never
        // the acceptance.
        let reloaded = DesignFreezeRegistry(
            store: .init(directory: fixture.registryStoreDirectory))
        #expect(reloaded.verifyPersisted(
            original, conversationID: started.conversationID.uuidString))
    }

    // MARK: - Run lifecycle (continuation re-establish / safe resolution)

    @Test("continuation of a bound conversation re-establishes the freeze BEFORE provider/tool I/O")
    func continuationReestablishesProtection() async throws {
        let fixture = try await makeFixture()
        try writeOriginal(fixture)
        let original = fixture.workspaceRoot.appendingPathComponent("index.html")
        let center = fixture.environment.conversationCenter
        let (provider, model) = try await model(fixture)
        let binding = DesignLaunchBinding(
            target: DesignOwnerTargets.file(
                workspaceID: fixture.workspaceID, relativePath: "index.html"),
            workMode: .modify,
            originalConversationID: nil)
        let started = try await center.startTask(
            goal: "首屏修改",
            title: "首屏修改",
            provider: provider,
            model: model,
            workspaceID: fixture.workspaceID,
            designLaunchBinding: binding,
            startOrigin: .explicitUserAction)
        defer {
            DesignFreezeProtectionCoordinator.release(conversationID: started.conversationID)
        }
        #expect(fixture.registry.protection(for: original) != nil)

        // Simulate the safe resolution of the first run (completed, nothing
        // pending): the freeze lifts, THEN the user sends a follow-up.
        fixture.registry.unprotectAll(conversationID: started.conversationID.uuidString)
        #expect(fixture.registry.protection(for: original) == nil)

        // The continuation re-freezes BEFORE its deferred run can reach any
        // tool — protection is live the moment startRun returns.
        _ = try await center.startRun(
            goal: "再改一次标题",
            in: started.conversationID,
            provider: provider,
            model: model,
            workspaceID: fixture.workspaceID,
            startOrigin: .explicitUserAction)
        let protection = try #require(fixture.registry.protection(for: original))
        #expect(protection.conversationID == started.conversationID.uuidString.lowercased())
    }

    @Test("continuation FAILS CLOSED when the original can no longer be frozen")
    func continuationFailsClosed() async throws {
        let fixture = try await makeFixture()
        try writeOriginal(fixture)
        let original = fixture.workspaceRoot.appendingPathComponent("index.html")
        let center = fixture.environment.conversationCenter
        let (provider, model) = try await model(fixture)
        let binding = DesignLaunchBinding(
            target: DesignOwnerTargets.file(
                workspaceID: fixture.workspaceID, relativePath: "index.html"),
            workMode: .modify,
            originalConversationID: nil)
        let started = try await center.startTask(
            goal: "首屏修改",
            title: "首屏修改",
            provider: provider,
            model: model,
            workspaceID: fixture.workspaceID,
            designLaunchBinding: binding,
            startOrigin: .explicitUserAction)
        defer {
            DesignFreezeProtectionCoordinator.release(conversationID: started.conversationID)
        }
        // The original disappears (e.g. the workspace was removed): the
        // follow-up launch must refuse to start, never run unprotected.
        try FileManager.default.removeItem(at: original)
        await #expect(throws: (any Error).self) {
            _ = try await center.startRun(
                goal: "再改一次标题",
                in: started.conversationID,
                provider: provider,
                model: model,
                workspaceID: fixture.workspaceID,
                startOrigin: .explicitUserAction)
        }
        // The first launch's protection is untouched (the failed
        // continuation neither dropped nor duplicated it), and the missing
        // original was not recreated.
        let protections = fixture.registry.allProtections()
        #expect(protections.count == 1)
        #expect(protections.first?.conversationID == started.conversationID.uuidString.lowercased())
        #expect(!FileManager.default.fileExists(atPath: original.path))
    }

    @Test("a model-controlled reject decision never lifts the freeze; a completed run with nothing pending is the safe resolution")
    func rejectKeepsFreezeUntilSafeResolution() async throws {
        let fixture = try await makeFixture()
        try writeOriginal(fixture)
        let original = fixture.workspaceRoot.appendingPathComponent("index.html")
        let conversationID = UUID()
        let target = DesignOwnerTargets.file(
            workspaceID: fixture.workspaceID, relativePath: "index.html")
            .withOrigin(conversationID)
        let binding = DesignLaunchBinding(
            target: target, workMode: .modify,
            originalConversationID: conversationID.uuidString)
        try DesignLaunchBindingStore.save(binding, conversationID: conversationID)
        let protected = await DesignFreezeProtectionCoordinator.establish(
            binding: binding, conversationID: conversationID,
            workspaceStore: SQLiteWorkspaceStore(database: fixture.environment.database))
        #expect(protected)
        defer { DesignFreezeProtectionCoordinator.release(conversationID: conversationID) }

        // Real typed-service history: frozen input → pending candidate.
        let workflow = fixture.environment.designOwnerWorkflow
        let frozen = try await workflow.freezeInput(
            target: target,
            operationID: "lifecycle-freeze",
            expectedOwnerRevision: nil,
            displayName: "index.html")
        let proposed = try await workflow.propose(
            target: target,
            operationID: "lifecycle-propose",
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: Data("<h1>candidate</h1>".utf8),
            format: "html",
            summary: "候选")

        // The design.reject TOOL no longer touches protection at all: even
        // with nothing pending afterwards, the freeze survives a
        // model-controlled rejection while design work is active.
        let rejected = try await workflow.reject(
            target: target,
            operationID: "lifecycle-reject",
            expectedOwnerRevision: proposed.envelope.revision,
            candidateID: proposed.candidate.id)
        #expect(fixture.registry.protection(for: original) != nil)
        // A panel-style decision with an ACTIVE run also keeps it protected.
        let activeOutcome = await DesignFreezeProtectionCoordinator.resolveAfterDecision(
            binding: binding, conversationID: conversationID,
            envelope: rejected.envelope, runIsActive: true,
            workspaceStore: SQLiteWorkspaceStore(database: fixture.environment.database))
        #expect(activeOutcome == .keptPending)
        #expect(fixture.registry.protection(for: original) != nil)

        // The safe resolution: a COMPLETED run (or a panel decision with no
        // active run) and nothing pending lifts THIS target's scope only.
        await DesignFreezeProtectionCoordinator.releaseAfterCompletedRun(
            binding: binding, conversationID: conversationID,
            envelope: rejected.envelope,
            workspaceStore: SQLiteWorkspaceStore(database: fixture.environment.database))
        #expect(fixture.registry.protection(for: original) == nil)
    }

    @Test("resolving one target never releases a sibling target's pending original in the same conversation")
    func perTargetReleaseScope() async throws {
        let fixture = try await makeFixture()
        try writeOriginal(fixture)
        let otherDir = fixture.workspaceRoot.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
        try "<p>other</p>".write(
            to: otherDir.appendingPathComponent("page.html"), atomically: true, encoding: .utf8)
        let conversationID = UUID()
        let targetA = DesignOwnerTargets.file(
            workspaceID: fixture.workspaceID, relativePath: "index.html")
            .withOrigin(conversationID)
        let targetB = DesignOwnerTargets.file(
            workspaceID: fixture.workspaceID, relativePath: "other/page.html")
            .withOrigin(conversationID)
        let store = SQLiteWorkspaceStore(database: fixture.environment.database)
        let bindingA = DesignLaunchBinding(
            target: targetA, workMode: .modify,
            originalConversationID: conversationID.uuidString)
        try DesignLaunchBindingStore.save(bindingA, conversationID: conversationID)
        #expect(await DesignFreezeProtectionCoordinator.establish(
            binding: bindingA, conversationID: conversationID, workspaceStore: store))
        #expect(await DesignFreezeProtectionCoordinator.establish(
            binding: DesignLaunchBinding(
                target: targetB, workMode: .modify,
                originalConversationID: conversationID.uuidString),
            conversationID: conversationID, workspaceStore: store))
        defer { DesignFreezeProtectionCoordinator.release(conversationID: conversationID) }
        let originalA = fixture.workspaceRoot.appendingPathComponent("index.html")
        let originalB = fixture.workspaceRoot.appendingPathComponent("other/page.html")

        // Real envelopes: A has no pending candidate; B carries a PENDING
        // candidate (its original must outlive A's resolution).
        let workflow = fixture.environment.designOwnerWorkflow
        _ = try await workflow.freezeInput(
            target: targetA, operationID: "multi-a-freeze",
            expectedOwnerRevision: nil, displayName: "index.html")
        let frozenB = try await workflow.freezeInput(
            target: targetB, operationID: "multi-b-freeze",
            expectedOwnerRevision: nil, displayName: "page.html")
        let envelopeB0 = try #require(try await workflow.state(targetB))
        _ = try await workflow.propose(
            target: targetB, operationID: "multi-b-propose",
            expectedOwnerRevision: envelopeB0.revision,
            artifactID: frozenB.revision.artifactID,
            baseRevisionID: frozenB.revision.id,
            bytes: Data("<p>other v2</p>".utf8),
            format: "html", summary: "B 的候选")

        // Target A resolves (completed run, nothing pending): ONLY A lifts.
        let envelopeA = try #require(try await workflow.state(targetA))
        #expect(envelopeA.project.candidates.isEmpty)
        await DesignFreezeProtectionCoordinator.releaseAfterCompletedRun(
            binding: bindingA, conversationID: conversationID,
            envelope: envelopeA, workspaceStore: store)
        #expect(fixture.registry.protection(for: originalA) == nil)
        #expect(fixture.registry.protection(for: originalB) != nil,
                "a sibling target's still-pending original must stay frozen")

        // Resolving B with its candidate still pending keeps it frozen too.
        let envelopeB = try #require(try await workflow.state(targetB))
        await DesignFreezeProtectionCoordinator.releaseAfterCompletedRun(
            binding: DesignLaunchBinding(
                target: targetB, workMode: .modify,
                originalConversationID: conversationID.uuidString),
            conversationID: conversationID,
            envelope: envelopeB, workspaceStore: store)
        #expect(fixture.registry.protection(for: originalB) != nil)
    }

    @Test("re-arm failure after adoption keeps the freeze, reports the failure, and still blocks the first model write")
    func rearmFailureFailsClosed() async throws {
        let fixture = try await makeFixture()
        try writeOriginal(fixture)
        let original = fixture.workspaceRoot.appendingPathComponent("index.html")
        let conversationID = UUID()
        let target = DesignOwnerTargets.file(
            workspaceID: fixture.workspaceID, relativePath: "index.html")
            .withOrigin(conversationID)
        let store = SQLiteWorkspaceStore(database: fixture.environment.database)
        let binding = DesignLaunchBinding(
            target: target, workMode: .modify,
            originalConversationID: conversationID.uuidString)
        try DesignLaunchBindingStore.save(binding, conversationID: conversationID)
        #expect(await DesignFreezeProtectionCoordinator.establish(
            binding: binding, conversationID: conversationID, workspaceStore: store))
        defer { DesignFreezeProtectionCoordinator.release(conversationID: conversationID) }

        let workflow = fixture.environment.designOwnerWorkflow
        let frozen = try await workflow.freezeInput(
            target: target, operationID: "rearm-freeze",
            expectedOwnerRevision: nil, displayName: "index.html")
        let proposed = try await workflow.propose(
            target: target, operationID: "rearm-propose",
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: Data("<h1>adopted</h1>".utf8),
            format: "html", summary: "候选")
        let envelope = try #require(try await workflow.state(target))
        let adopted = try await workflow.adopt(
            target: target, operationID: "rearm-adopt",
            expectedOwnerRevision: envelope.revision,
            candidateID: proposed.candidate.id, mode: .updateOriginal,
            runID: nil,
            verifyReopen: DesignOwnerWorkflowFactory.verifier(
                adapters: fixture.environment.designAdapterCenter))
        // Simulate the persistence/resolution failure: the adopted file
        // disappears before the re-arm can run.
        try FileManager.default.removeItem(at: original)
        let outcome = await DesignFreezeProtectionCoordinator.resolveAfterDecision(
            binding: binding, conversationID: conversationID,
            envelope: adopted.envelope, runIsActive: true,
            workspaceStore: store)
        #expect(outcome == .rearmFailed)
        // Fail closed: a protection still governs the source path…
        #expect(!fixture.registry.allProtections()
            .filter { $0.conversationID == conversationID.uuidString.lowercased() }.isEmpty)
        // …so the model's next ordinary write is refused and the recoverable
        // state (the retained candidate + envelope) is intact.
        let service = gatedService(fixture)
        #expect(throws: DesignFreezeError.self) {
            _ = try service.writeFile("index.html", content: "<h1>clobber</h1>")
        }
        #expect(adopted.envelope.project.candidates.contains { $0.status == .adopted })
    }

    @Test("a verified adoption during an active run re-freezes the new approved baseline, not unlimited writes")
    func adoptionDuringActiveRunRefreezesBaseline() async throws {
        let fixture = try await makeFixture()
        try writeOriginal(fixture)
        let original = fixture.workspaceRoot.appendingPathComponent("index.html")
        let conversationID = UUID()
        let target = DesignOwnerTargets.file(
            workspaceID: fixture.workspaceID, relativePath: "index.html")
            .withOrigin(conversationID)
        let binding = DesignLaunchBinding(
            target: target, workMode: .modify,
            originalConversationID: conversationID.uuidString)
        try DesignLaunchBindingStore.save(binding, conversationID: conversationID)
        let protected = await DesignFreezeProtectionCoordinator.establish(
            binding: binding, conversationID: conversationID,
            workspaceStore: SQLiteWorkspaceStore(database: fixture.environment.database))
        #expect(protected)
        defer { DesignFreezeProtectionCoordinator.release(conversationID: conversationID) }

        let workflow = fixture.environment.designOwnerWorkflow
        let frozen = try await workflow.freezeInput(
            target: target,
            operationID: "adopt-freeze",
            expectedOwnerRevision: nil,
            displayName: "index.html")
        let proposed = try await workflow.propose(
            target: target,
            operationID: "adopt-propose",
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: Data("<h1>adopted baseline</h1>".utf8),
            format: "html",
            summary: "候选")
        // The verified adoption runs through the REAL owner adopt path (the
        // panel-shaped trusted call): the commit port writes the bytes and
        // records the candidate adopted; the decision layer then re-freezes
        // the NEW bytes as the approved baseline for the still-active run.
        let envelope = try #require(try await workflow.state(target))
        let adopted = try await workflow.adopt(
            target: target,
            operationID: "adopt-decision",
            expectedOwnerRevision: envelope.revision,
            candidateID: proposed.candidate.id,
            mode: .updateOriginal,
            runID: nil,
            verifyReopen: DesignOwnerWorkflowFactory.verifier(
                adapters: fixture.environment.designAdapterCenter))
        await DesignFreezeProtectionCoordinator.resolveAfterDecision(
            binding: binding, conversationID: conversationID,
            envelope: adopted.envelope, runIsActive: true,
            workspaceStore: SQLiteWorkspaceStore(database: fixture.environment.database))
        let protection = try #require(fixture.registry.protection(for: original))
        #expect(protection.frozenSHA256 == FloeDigest.sha256Hex(Data("<h1>adopted baseline</h1>".utf8)))
        // The still-active run cannot now raw-write the new baseline.
        let gated = gatedService(fixture)
        #expect(throws: DesignFreezeError.self) {
            _ = try gated.writeFile("index.html", content: "<h1>sneaky</h1>")
        }
        try #expect(String(contentsOf: original, encoding: .utf8) == "<h1>adopted baseline</h1>")
        // Nothing pending after the adoption: the completed-run resolution
        // lifts THIS target's re-frozen baseline.
        await DesignFreezeProtectionCoordinator.releaseAfterCompletedRun(
            binding: binding, conversationID: conversationID,
            envelope: adopted.envelope,
            workspaceStore: SQLiteWorkspaceStore(database: fixture.environment.database))
        #expect(fixture.registry.protection(for: original) == nil)
    }
}

private extension DesignTarget {
    /// Test/fixture convenience: the rebound origin identity a bound task
    /// carries (same shape ConversationCenter.startTask writes).
    func withOrigin(_ conversationID: UUID) -> DesignTarget {
        DesignTarget(
            kind: kind,
            ownerID: ownerID,
            documentID: documentID,
            sourceID: sourceID,
            environmentID: environmentID,
            revision: revision,
            originConversationID: conversationID.uuidString,
            requestedOutputKind: requestedOutputKind)
    }
}
#endif
