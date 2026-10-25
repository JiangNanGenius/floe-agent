#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
import FloeSkills
@testable import FloeApp

@MainActor private final class AuthoringDraftFixture: SkillAuthoringDraftManaging {
    var entries: [UUID: SkillAuthoringDraft] = [:]
    var canFlush = true
    func authoringDraft(for id: UUID) -> SkillAuthoringDraft { entries[id] ?? .init(text: "", attachments: [], revision: 0) }
    func saveAuthoringDraft(_ text: String, attachments: [AttachmentRef], id: UUID) throws -> Int {
        let revision = authoringDraft(for: id).revision + 1
        entries[id] = .init(text: text, attachments: attachments, revision: revision); return revision
    }
    func flushAuthoringDrafts() -> Bool { canFlush }
}
@MainActor private final class AuthoringBackendFixture: SkillAuthoringBackend {
    var resolveCount = 0, startCount = 0, installCount = 0, prepareCount = 0
    var prepared: SkillsCenter.PreparedImport?
    func resolveAuxiliaryRoute() throws -> SkillAuthoringModelRoute { resolveCount += 1; throw SkillAuthoringFlowError.auxiliaryUnavailable }
    func startGeneration(ownerID: UUID, runID: UUID, prompt: String, route: SkillAuthoringModelRoute, attachments: [AttachmentRef]) async throws -> StartedConversationRun {
        startCount += 1; throw SkillAuthoringFlowError.runFailed
    }
    func prepareImport(urlText: String) async throws -> SkillsCenter.PreparedImport {
        prepareCount += 1
        guard let prepared else { throw SkillAuthoringFlowError.sourceUnavailable }
        return prepared
    }
    func finalBody(ownerID: UUID, runID: UUID) async throws -> String { throw SkillAuthoringFlowError.noFinalReply }
    func observe(runID: UUID) async throws -> SkillAuthoringExecutionObservation { .init(state: .unavailable) }
    func cancel(runID: UUID) async {}
    func liveRunIDs() async throws -> Set<UUID> { [] }
    func installReviewedPackage(_ package: SkillAuthoringPackageDescriptor, at root: URL, modelID: UUID?) async throws -> SkillWorkspaceInstallCommit {
        installCount += 1; throw SkillAuthoringFlowError.installationMismatch
    }
}
@Suite("Skill authoring app ownership") @MainActor
struct SkillAuthoringFlowTests {
    private func setup() async throws -> (SkillAuthoringCoordinator, SQLiteSkillAuthoringStore, AuthoringDraftFixture, AuthoringBackendFixture, URL) {
        let database = try DatabaseManager.inMemory(); try await database.migrate()
        let store = SQLiteSkillAuthoringStore(database: database), drafts = AuthoringDraftFixture(), backend = AuthoringBackendFixture()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (SkillAuthoringCoordinator(store: store, drafts: drafts, backend: backend,
                    storage: { SkillAuthoringPackageStorage(root: root) }), store, drafts, backend, root)
    }
    private func awaitSettlement(_ flow: SkillAuthoringCoordinator, id: UUID) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while flow.isWorking(id), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!flow.isWorking(id))
    }
    @Test func closeReturnReusesOwnerAndDraft() async throws {
        let (flow, _, _, backend, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        await flow.open(kind: .creation)
        let id = try #require(flow.presentation?.id)
        flow.updateDraft(id: id, text: "Keep my input")
        flow.close(id: id); await flow.reload()
        #expect(flow.presentation == nil)
        await flow.open(kind: .importing)
        #expect(flow.presentation?.id == id)
        #expect(flow.draftText(id) == "Keep my input")
        #expect(flow.taskCenterRecords.count == 1)
        #expect(backend.startCount == 0)
    }
    @Test func missingAuxiliaryNeverStartsFallback() async throws {
        let (flow, _, _, backend, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        await flow.open(kind: .creation); let id = try #require(flow.presentation?.id)
        flow.updateDraft(id: id, text: "Create a skill")
        flow.generate(id: id)
        try await awaitSettlement(flow, id: id)
        #expect(!flow.isWorking(id)); #expect(backend.resolveCount == 1); #expect(backend.startCount == 0)
        #expect(flow.draftText(id) == "Create a skill"); #expect(flow.errors[id] != nil)
    }
    @Test func unflushedDraftNeverStartsProvider() async throws {
        let (flow, _, drafts, backend, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        await flow.open(kind: .creation); let id = try #require(flow.presentation?.id)
        flow.updateDraft(id: id, text: "Preserve"); drafts.canFlush = false
        flow.generate(id: id)
        try await awaitSettlement(flow, id: id)
        #expect(backend.resolveCount == 0 && backend.startCount == 0)
        #expect(flow.draftText(id) == "Preserve")
    }
    @Test func staleReviewCannotInstall() async throws {
        let (flow, _, _, backend, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        await flow.open(kind: .creation); let id = try #require(flow.presentation?.id)
        await flow.add(id: id, reviewedSnapshotID: UUID(), reviewedDigest: String(repeating: "0", count: 64))
        #expect(backend.installCount == 0); #expect(flow.errors[id] != nil)
    }
    @Test func cancellingDraftReleasesSlotWithoutLosingInput() async throws {
        let (flow, store, _, _, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        await flow.open(kind: .creation); let id = try #require(flow.presentation?.id)
        flow.updateDraft(id: id, text: "Recoverable"); await flow.cancel(id: id)
        #expect(try await store.active() == nil); #expect(flow.record(id)?.phase == .stopped)
        #expect(flow.draftText(id) == "Recoverable")
    }
    @Test func failedURLStagePreservesDraftAndNeverUsesModel() async throws {
        let (flow, store, _, backend, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        await flow.open(kind: .importing); let id = try #require(flow.presentation?.id)
        flow.updateDraft(id: id, text: "https://example.invalid/skill.json")
        flow.importURL(id: id)
        try await awaitSettlement(flow, id: id)
        #expect(flow.record(id)?.phase == .failed)
        #expect(flow.draftText(id) == "https://example.invalid/skill.json")
        #expect(backend.prepareCount == 1 && backend.resolveCount == 0 && backend.startCount == 0 && backend.installCount == 0)
        #expect(try await store.record(id: id)?.generatedArtifactIDs.isEmpty == true)
    }
    @Test func preparedURLUsesSameSlotAndRequiresExplicitAdd() async throws {
        let (flow, _, _, backend, root) = try await setup(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("---\nname: remote-fixture\ndescription: Synthetic remote fixture\n---\nHelp the user.\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
        let validated = try SkillPackageValidator().validate(packageAt: source, requireManifest: false)
        let snapshot = try SkillContentSnapshot(root: source, expectedDigest: validated.canonicalSHA256, manifestOverride: validated.manifest)
        backend.prepared = .init(snapshot: snapshot, sourceURL: URL(string: "https://example.invalid/skill.json")!, gitHubBinding: nil)
        await flow.open(kind: .importing); let id = try #require(flow.presentation?.id)
        flow.updateDraft(id: id, text: "https://example.invalid/skill.json")
        // Another create/import entry reopens this owner rather than spawning a second task.
        await flow.open(kind: .creation); #expect(flow.presentation?.id == id)
        flow.importURL(id: id)
        try await awaitSettlement(flow, id: id)
        #expect(flow.record(id)?.phase == .ready)
        #expect(flow.packages[id]?.sourceURL?.host == "example.invalid")
        #expect(backend.prepareCount == 1 && backend.startCount == 0 && backend.installCount == 0)
    }

}
#endif
