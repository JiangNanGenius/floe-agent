// FloeAppTests — Design entry state: REAL call chains through durable
// stores. The published presentation derives from the durable launch
// binding + durable owner envelope + real capability registry — covering
// ordinary Q&A, file/attachment design tasks, creative tasks before/after a
// real artifact, unknown/missing attachments, candidate resolution and
// RESTORE (a brand-new center instance republishes from durable state).

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeApp

@Suite("FloeApp.DesignEntryState")
@MainActor
struct DesignEntryStateTests {
    private struct World {
        let environment: AppEnvironment
        let workspaceID: UUID
        let workspaceRoot: URL
        let center: DesignEntryStateCenter
    }

    private func makeWorld() async throws -> World {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-entry-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bookmark = try root.bookmarkData(options: .minimalBookmark)
        let store = SQLiteWorkspaceStore(database: environment.database)
        let workspaceID = UUID()
        try await store.saveWorkspace(WorkspaceRecord(
            id: workspaceID,
            name: "Entry State",
            rootBookmark: bookmark,
            kind: .project))
        let center = DesignEntryStateCenter()
        return World(environment: environment, workspaceID: workspaceID, workspaceRoot: root, center: center)
    }

    private func fileBinding(_ world: World, relative: String, conversationID: UUID) -> DesignLaunchBinding {
        let target = DesignTarget(
            kind: .fileDocument,
            ownerID: world.workspaceID.uuidString,
            documentID: "",
            sourceID: relative,
            originConversationID: conversationID.uuidString)
        return DesignLaunchBinding(
            target: target, workMode: .modify,
            originalConversationID: conversationID.uuidString)
    }

    @Test("ordinary conversation with no binding shows no entry; restore keeps that")
    func ordinaryConversationNoEntry() async throws {
        let world = try await makeWorld()
        let conversation = UUID()
        try await world.environment.conversationStore.saveConversation(ConversationRecord(
            id: conversation, title: "普通问答", createdAt: Date(), updatedAt: Date()))
        await world.center.refresh(conversationID: conversation, environment: world.environment)
        #expect(world.center.presentation(for: conversation) == DesignEntryPresentation.none)
        // A fresh center (restart) derives the same from durable truth.
        let restored = DesignEntryStateCenter()
        await restored.refresh(conversationID: conversation, environment: world.environment)
        #expect(restored.presentation(for: conversation) == DesignEntryPresentation.none)
    }

    @Test("bound file modify task: default flow first; lightweight entry after a real artifact — including restore")
    func boundFileTaskEntryAndRestore() async throws {
        let world = try await makeWorld()
        let conversation = UUID()
        let file = world.workspaceRoot.appendingPathComponent("index.html")
        try "<h1>v1</h1>".write(to: file, atomically: true, encoding: .utf8)
        try await world.environment.conversationStore.saveConversation(ConversationRecord(
            id: conversation, title: "首屏修改", createdAt: Date(), updatedAt: Date()))
        let binding = fileBinding(world, relative: "index.html", conversationID: conversation)
        try DesignLaunchBindingStore.save(binding, conversationID: conversation)
        // Default original flow: no entry before the model produced anything.
        await world.center.refresh(conversationID: conversation, environment: world.environment)
        #expect(world.center.presentation(for: conversation) == DesignEntryPresentation.none)
        // The model freezes a real input → the lightweight entry appears.
        let workflow = world.environment.designOwnerWorkflow
        _ = try await workflow.freezeInput(
            target: binding.target, operationID: "entry-file-freeze",
            expectedOwnerRevision: nil, displayName: "index.html")
        await world.center.refresh(conversationID: conversation, environment: world.environment)
        #expect(world.center.presentation(for: conversation) == DesignEntryPresentation.viewArtifactEntry)
        // Restore: a brand-new center republishes from durable state.
        let restored = DesignEntryStateCenter()
        await restored.refresh(conversationID: conversation, environment: world.environment)
        #expect(restored.presentation(for: conversation) == DesignEntryPresentation.viewArtifactEntry)
    }

    @Test("creative task stays conversation-first until the durable envelope holds a real artifact")
    func creativeConversationFirstUntilArtifact() async throws {
        let world = try await makeWorld()
        let conversation = UUID()
        let requestID = UUID()
        let target = DesignTarget(
            kind: .creativeDocument,
            ownerID: "creative-library",
            documentID: "",
            sourceID: requestID.uuidString,
            originConversationID: conversation.uuidString,
            requestedOutputKind: .image)
        try await world.environment.conversationStore.saveConversation(ConversationRecord(
            id: conversation, title: "创意", createdAt: Date(), updatedAt: Date()))
        try DesignLaunchBindingStore.save(DesignLaunchBinding(
            target: target, workMode: .create,
            originalConversationID: conversation.uuidString), conversationID: conversation)
        await world.center.refresh(conversationID: conversation, environment: world.environment)
        #expect(world.center.presentation(for: conversation) == DesignEntryPresentation.none)
        // The model establishes a REAL artifact through the typed workflow.
        let workflow = world.environment.designOwnerWorkflow
        let begun = try await workflow.beginCreativeRequest(
            target: target, operationID: "entry-begin",
            expectedOwnerRevision: nil,
            brief: DesignBrief(goal: "做一张海报", audience: nil, constraints: []))
        let assetURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("entry-poster-\(UUID().uuidString).png")
        // A REAL decodable 1x1 PNG.
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        try png.write(to: assetURL)
        let asset = try await CreativeAssetIngestionService(
            assetStore: world.environment.creativeAssetStore).importLocalFile(assetURL)
        try? FileManager.default.removeItem(at: assetURL)
        _ = try await workflow.bindFirstResult(
            target: target, operationID: "entry-bind",
            expectedOwnerRevision: begun.envelope.revision,
            bytes: png, format: "png",
            displayName: asset.displayName, boundResultID: asset.id.uuidString)
        await world.center.refresh(conversationID: conversation, environment: world.environment)
        #expect(world.center.presentation(for: conversation) == DesignEntryPresentation.viewArtifactEntry)
        // And after restore.
        let restored = DesignEntryStateCenter()
        await restored.refresh(conversationID: conversation, environment: world.environment)
        #expect(restored.presentation(for: conversation) == DesignEntryPresentation.viewArtifactEntry)
    }

    @Test("unknown/missing attachment binding shows no entry (source not provable)")
    func missingAttachmentShowsNothing() async throws {
        let world = try await makeWorld()
        let conversation = UUID()
        let target = DesignTarget(
            kind: .chatAttachment,
            ownerID: conversation.uuidString,
            documentID: UUID().uuidString,
            sourceID: UUID().uuidString,
            originConversationID: conversation.uuidString)
        try await world.environment.conversationStore.saveConversation(ConversationRecord(
            id: conversation, title: "附件问答", createdAt: Date(), updatedAt: Date()))
        try DesignLaunchBindingStore.save(DesignLaunchBinding(
            target: target, workMode: .modify,
            originalConversationID: conversation.uuidString), conversationID: conversation)
        await world.center.refresh(conversationID: conversation, environment: world.environment)
        #expect(world.center.presentation(for: conversation) == DesignEntryPresentation.none)
    }

    @Test("candidate resolution republishes the entry from the durable envelope")
    func candidateResolutionRepublishes() async throws {
        let world = try await makeWorld()
        let conversation = UUID()
        let file = world.workspaceRoot.appendingPathComponent("index.html")
        try "<h1>v1</h1>".write(to: file, atomically: true, encoding: .utf8)
        try await world.environment.conversationStore.saveConversation(ConversationRecord(
            id: conversation, title: "首屏修改", createdAt: Date(), updatedAt: Date()))
        let binding = fileBinding(world, relative: "index.html", conversationID: conversation)
        try DesignLaunchBindingStore.save(binding, conversationID: conversation)
        let workflow = world.environment.designOwnerWorkflow
        let frozen = try await workflow.freezeInput(
            target: binding.target, operationID: "entry-freeze",
            expectedOwnerRevision: nil, displayName: "index.html")
        let proposed = try await workflow.propose(
            target: binding.target, operationID: "entry-propose",
            expectedOwnerRevision: frozen.envelope.revision,
            artifactID: frozen.revision.artifactID,
            baseRevisionID: frozen.revision.id,
            bytes: Data("<h1>v2</h1>".utf8), format: "html", summary: "候选")
        await world.center.refresh(conversationID: conversation, environment: world.environment)
        #expect(world.center.presentation(for: conversation) == DesignEntryPresentation.viewArtifactEntry)
        // The user rejects the candidate: the durable envelope no longer
        // holds a pending candidate; the entry republishes accordingly.
        let envelope = try #require(try await workflow.state(binding.target))
        _ = try await workflow.reject(
            target: binding.target, operationID: "entry-reject",
            expectedOwnerRevision: envelope.revision,
            candidateID: proposed.candidate.id)
        await world.center.refresh(conversationID: conversation, environment: world.environment)
        #expect(world.center.presentation(for: conversation) == DesignEntryPresentation.viewArtifactEntry)
    }

    @Test("preview-presentability: precise unsupported states never fake a connected entry")
    func previewPresentability() {
        // Real presentable paths.
        #expect(DesignPreviewPresentation.assess(contentType: .webpage, format: "html", isFileTarget: true) == .presentable)
        #expect(DesignPreviewPresentation.assess(contentType: .image, format: "png", isFileTarget: false) == .presentable)
        #expect(DesignPreviewPresentation.assess(contentType: .officeDocument, format: "docx", isFileTarget: true) == .presentable)
        #expect(DesignPreviewPresentation.assess(contentType: .pdf, format: "pdf", isFileTarget: false) == .presentable)
        #expect(DesignPreviewPresentation.assess(contentType: .cad, format: "step", isFileTarget: true) == .presentable)
        // Precise unsupported states.
        guard case .unsupported(let cadAttachment) = DesignPreviewPresentation.assess(
            contentType: .cad, format: "step", isFileTarget: false) else {
            Issue.record("CAD attachment must be unsupported"); return
        }
        #expect(cadAttachment.contains("workspace file"))
        guard case .unsupported(let unknownImage) = DesignPreviewPresentation.assess(
            contentType: .image, format: "xyz", isFileTarget: true) else {
            Issue.record("unknown image format must be unsupported"); return
        }
        #expect(unknownImage.contains("xyz"))
        guard case .unsupported = DesignPreviewPresentation.assess(
            contentType: .composition, format: "json", isFileTarget: true) else {
            Issue.record("composition must be unsupported"); return
        }
        // The entry follows the preview verdict: unsupported → no entry.
        let noEntry = DesignEntryPolicy.assess(
            intent: .singleShotMakeOrModify, hasRealTarget: true,
            capabilityConnected: false, hasPreviewableArtifact: true,
            hasPendingCandidate: true)
        #expect(noEntry.presentation == DesignEntryPresentation.none)
    }

    @Test("policy unit semantics: ordinary Q&A and missing capability never show entries")
    func policySemantics() {
        let qa = DesignEntryPolicy.assess(
            intent: .ordinaryQA, hasRealTarget: true, capabilityConnected: true,
            hasPreviewableArtifact: true, hasPendingCandidate: true)
        #expect(qa.presentation == .none)
        let low = DesignEntryPolicy.assess(
            intent: .singleShotMakeOrModify, hasRealTarget: true, capabilityConnected: true,
            hasPreviewableArtifact: false, hasPendingCandidate: false,
            lowConfidenceInteractionSignal: true)
        #expect(low.presentation == .lightweightHint)
        let noCapability = DesignEntryPolicy.assess(
            intent: .explicitInteractive, hasRealTarget: true, capabilityConnected: false,
            hasPreviewableArtifact: true, hasPendingCandidate: true)
        #expect(noCapability.presentation == .none)
    }
}
#endif
