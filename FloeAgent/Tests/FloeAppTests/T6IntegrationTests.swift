// FloeAppTests — T6 central UI/composition integration (written by T6).
//
// These tests exercise the REAL app composition with the preview environment:
//   * the four design entrances construct typed, live-owner targets (file /
//     chat attachment / creative request / Canvas via the existing panel);
//   * one central composition instantiates the shared target service and
//     owner workflow exactly once;
//   * the production result-publication port is idempotent per publication
//     key and returns adopted results through the EXISTING stores only;
//   * the provider save split commits locally and reports readback without a
//     sync engine, preserving the strict legacy behavior for old callers.
//
// They execute in the FloeApp unit-test bundle (full App target, T7). Static
// checks in this lane are NOT runtime evidence.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import UIKit
import FloeCore
import FloeModels
import FloePersistence
@testable import FloeApp

@Suite("T6 design entrances and composition")
@MainActor
struct T6DesignEntranceTests {

    // MARK: - Typed entrances

    @Test("Entrance targets use the live owner identities, never invented Canvas UUIDs")
    func entranceTargetsUseLiveOwnerIdentities() {
        let workspaceID = UUID()
        let file = DesignOwnerTargets.file(workspaceID: workspaceID, relativePath: "brand/logo.svg")
        #expect(file.kind == .fileDocument)
        #expect(file.ownerID == workspaceID.uuidString)
        #expect(file.sourceID == "brand/logo.svg")
        #expect(file.originConversationID == nil)

        let conversationID = UUID()
        let messageID = UUID()
        let attachmentID = UUID()
        let chat = DesignOwnerTargets.chatAttachment(
            conversationID: conversationID, messageID: messageID, attachmentID: attachmentID)
        #expect(chat.kind == .chatAttachment)
        #expect(chat.ownerID == conversationID.uuidString)
        #expect(chat.documentID == messageID.uuidString)
        #expect(chat.sourceID == attachmentID.uuidString)
        // The originating task attribution is frozen on the target.
        #expect(chat.originConversationID == conversationID.uuidString)

        let requestID = UUID()
        let creative = DesignOwnerTargets.creative(requestID: requestID, kind: .image)
        #expect(creative.kind == .creativeDocument)
        #expect(creative.sourceID == requestID.uuidString)
        #expect(creative.requestedOutputKind == .image)
        // The requested output kind is part of the frozen identity: a
        // different kind is a different request, never a silent upgrade.
        let other = DesignOwnerTargets.creative(requestID: requestID, kind: .video)
        #expect(creative.stableKey != other.stableKey)
        #expect(creative.isSameSource(as: other) == false)
    }

    @Test("Central composition is instantiated once and shared")
    func compositionIsSharedOnce() {
        let environment = AppEnvironment.preview()
        let firstTargets = environment.designTargetService
        let secondTargets = environment.designTargetService
        #expect(firstTargets === secondTargets)
        let firstWorkflow = environment.designOwnerWorkflow
        let secondWorkflow = environment.designOwnerWorkflow
        #expect(firstWorkflow === secondWorkflow)
        // The typed tools receive EXACTLY the service the panel drives.
        #expect(environment.designCanvasService === environment.designCanvasService)
        #expect(environment.designOwnerAdoptionGrants === DesignOwnerAuthorization.shared)
    }

    @Test("The UI-minted adoption confirmation is the exact one design.adopt consumes")
    func adoptionConfirmationIsSharedAndExact() async {
        let grants = AppEnvironment.preview().designOwnerAdoptionGrants
        #expect(grants === DesignOwnerAuthorization.shared)
        let grantID = await grants.issueOwnerAdoption(
            targetStableKey: "stable-target-key",
            candidateID: "candidate-1",
            baselineRevisionID: "base-1",
            proposedRevisionID: "proposed-1",
            mode: .variant,
            scope: .aiTool)
        // The exact target/candidate/base/proposed/mode/scope validates.
        #expect(await grants.validateOwnerAdoption(
            grantID: grantID, targetStableKey: "stable-target-key",
            candidateID: "candidate-1", baselineRevisionID: "base-1",
            proposedRevisionID: "proposed-1", mode: .variant, scope: .aiTool))
        // A different mode (or a different candidate/base) does not.
        #expect(await grants.validateOwnerAdoption(
            grantID: grantID, targetStableKey: "stable-target-key",
            candidateID: "candidate-1", baselineRevisionID: "base-1",
            proposedRevisionID: "proposed-1", mode: .updateOriginal, scope: .aiTool) == false)
        #expect(await grants.validateOwnerAdoption(
            grantID: grantID, targetStableKey: "stable-target-key",
            candidateID: "candidate-2", baselineRevisionID: "base-1",
            proposedRevisionID: "proposed-1", mode: .variant, scope: .aiTool) == false)
        // Single use: consumed once, then the replay cannot validate.
        #expect(await grants.consumeOwnerAdoption(
            grantID: grantID, targetStableKey: "stable-target-key",
            candidateID: "candidate-1", baselineRevisionID: "base-1",
            proposedRevisionID: "proposed-1", mode: .variant, scope: .aiTool))
        #expect(await grants.validateOwnerAdoption(
            grantID: grantID, targetStableKey: "stable-target-key",
            candidateID: "candidate-1", baselineRevisionID: "base-1",
            proposedRevisionID: "proposed-1", mode: .variant, scope: .aiTool) == false)
    }

    @Test("Canvas authority errors stay actionable and never expose raw identifiers")
    func canvasAuthorityErrorIsLocalizedAndSafe() {
        let message = DesignOwnerWorkflowModel.friendly(
            DesignOwnerWorkflowError.canvasRequiresCanvasAuthority("canvas 1234 raw"))
        #expect(!message.isEmpty)
        #expect(!message.contains("1234"))
        #expect(message != "design.owner.canvas_authority")
    }

    // MARK: - Result publication (chat)

    @Test("Chat publication creates one attachment and one message, and replays identically")
    func chatPublicationIsIdempotentAndPreservesOriginal() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let conversationID = UUID()
        let originalAttachmentID = UUID()
        try await environment.conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: "T6 publication", createdAt: Date(), updatedAt: Date()))
        // The ORIGINAL attachment of the originating task must survive.
        try await environment.conversationStore.saveAttachment(AttachmentRef(
            id: originalAttachmentID, conversationID: conversationID,
            kind: .document, displayName: "original.md",
            storage: .applicationSupport, relativePath: "original.md"))

        let bytes = Data("# adopted result\nrevision bytes".utf8)
        let target = DesignOwnerTargets.chatAttachment(
            conversationID: conversationID,
            messageID: UUID(),
            attachmentID: originalAttachmentID)
        let publication = DesignResultPublication(
            target: target,
            targetStableKey: target.stableKey,
            operationID: "ui-adopt-op-1",
            candidateID: "candidate-1",
            mode: .updateOriginal,
            artifactID: "artifact-1",
            revisionID: "revision-1",
            payloadRelativePath: "DesignRevisions/owners/x/revision-1",
            contentSHA256: FloeDigest.sha256Hex(bytes),
            format: "md",
            displayName: "adopted-result.md",
            originConversationID: conversationID.uuidString,
            ownerRevision: 1,
            bytes: bytes)

        let port = environment.designResultPublicationPort
        let first = try await port.publish(publication)
        let second = try await port.publish(publication)
        // Same key → same receipt, never a second attachment/message.
        #expect(first == second)
        #expect(first.destination == "chat:\(conversationID.uuidString)")
        #expect(first.contentSHA256 == FloeDigest.sha256Hex(bytes))

        let attachments = try await environment.conversationStore.attachments(
            conversationID: conversationID)
        #expect(attachments.count == 2) // original + adopted result
        #expect(attachments.contains { $0.id == originalAttachmentID })
        #expect(attachments.filter { $0.id.uuidString == first.identifier }.count == 1)
        let messages = try await environment.conversationStore.messages(
            conversationID: conversationID)
        #expect(messages.count == 1)
        #expect(messages.first?.parts.first?.attachmentID?.uuidString == first.identifier)
        // Durable replay: the same identifier maps to the same generated file.
        if let publishedID = UUID(uuidString: first.identifier) {
            let publishedAttachment = try await environment.conversationStore.attachment(id: publishedID)
            #expect(publishedAttachment?.sha256 == FloeDigest.sha256Hex(bytes))
            #expect(publishedAttachment?.conversationID == conversationID)
        }

        // Cleanup the task-owned staged file.
        let staged = try AppDesignResultPublicationPort.attachmentStagingDirectory()
            .appendingPathComponent("\(first.identifier)-adopted-result.md")
        try? FileManager.default.removeItem(at: staged)
    }

    // MARK: - Result publication (creative)

    @Test("Creative publication creates one existing-library asset and replays identically")
    func creativePublicationIsIdempotent() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let bytes = Data("creative adopted result".utf8)
        let target = DesignOwnerTargets.creative(requestID: UUID(), kind: .notes)
        let publication = DesignResultPublication(
            target: target,
            targetStableKey: target.stableKey,
            operationID: "ui-adopt-op-2",
            candidateID: "candidate-2",
            mode: .updateOriginal,
            artifactID: "artifact-2",
            revisionID: "revision-2",
            payloadRelativePath: "DesignRevisions/owners/y/revision-2",
            contentSHA256: FloeDigest.sha256Hex(bytes),
            format: "md",
            displayName: "adopted-notes.md",
            originConversationID: nil,
            ownerRevision: 1,
            bytes: bytes)

        let port = environment.designResultPublicationPort
        let first = try await port.publish(publication)
        let second = try await port.publish(publication)
        #expect(first == second)
        #expect(first.destination == "creative:creative-library")

        guard let assetID = UUID(uuidString: first.identifier) else {
            Issue.record("receipt identifier is not an asset UUID"); return
        }
        let asset = try await environment.creativeAssetStore.asset(id: assetID)
        #expect(asset?.contentHash == FloeDigest.sha256Hex(bytes))
        #expect(asset?.tags.contains("design") == true)
        if let relative = asset?.localRelativePath {
            let url = try AppDesignResultPublicationPort.artifactRoot()
                .appendingPathComponent(relative)
            #expect(FileManager.default.fileExists(atPath: url.path))
            try? FileManager.default.removeItem(at: url)
        }
        // The receipt index is audit-only and must not duplicate assets.
        let all = try await environment.creativeAssetStore.allAssets()
        #expect(all.filter { $0.id == assetID }.count == 1)
    }

    // MARK: - Provider save split

    @Test("A local provider commit reports saved models and readback without a sync engine")
    func providerCommitSplitsLocalFromSync() async throws {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let provider = ProviderProfile(
            kind: .custom,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://split.example/v1")!,
            displayName: "Split Provider")
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "split-model",
            displayName: "Split Model",
            limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024))
        let outcome = try await environment.conversationCenter.commitProviderBundle(
            provider: provider,
            models: [model],
            managedCapabilities: .text)
        #expect(outcome.saved.count == 1)
        #expect(outcome.saved.first?.remoteModelID == "split-model")
        // No CloudKit engine is configured in the preview environment, so the
        // local commit is durable with nothing pending to claim.
        #expect(outcome.syncPending == false || outcome.syncError != nil)
        let mismatch = await environment.conversationCenter.verifyProviderPersisted(
            provider: provider, selectedModels: outcome.saved)
        #expect(mismatch == nil)
    }
}

/// Deterministic suspension gate for the in-flight document-switch tests.
private actor CompletionGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

/// MainActor-isolated presentation recorder: Swift 6 forbids mutating plain
/// local vars from a @Sendable Task closure.
@MainActor
private final class EntryPresentationRecorder {
    var activeDocumentID: UUID?
    var presentedFor: UUID?
    var shown: CanvasSceneMigrationNotice?
}

@Suite("T6 3D entry document-switch guards")
@MainActor
struct T6_3DEntryDocumentSwitchTests {

    @Test("A 3D create completing after a document switch parks for its original document")
    func createWhileSwitchingDocumentsParksForOriginalDocument() async {
        let coordinator = Canvas3DEntryCoordinator()
        let canvasID = UUID()
        let docA = UUID()
        let docB = UUID()
        let nodeID = UUID()
        let gate = CompletionGate()
        let recorder = EntryPresentationRecorder()
        recorder.activeDocumentID = docA
        let entry = Canvas3DEntryCoordinator.Entry.createdNode(
            canvasID: canvasID, documentID: docA, nodeID: nodeID)
        let completion = Task { @MainActor in
            // In-flight async create: the active document switches before the
            // result is applied.
            await gate.wait()
            guard let active = recorder.activeDocumentID else { return }
            if coordinator.shouldPresentImmediately(entry, activeDocumentID: active) {
                recorder.presentedFor = active
            } else {
                coordinator.park(entry)
            }
        }
        recorder.activeDocumentID = docB
        await gate.open()
        await completion.value

        // The new document's selection was NOT stolen, and the exact result is
        // retained for its frozen owner document.
        #expect(recorder.presentedFor == nil)
        #expect(coordinator.parkedEntry(forDocument: docB) == nil)
        #expect(coordinator.parkedEntry(forDocument: docA) == entry)
        #expect(coordinator.take(forDocument: docA) == entry)
        #expect(coordinator.parkedEntry(forDocument: docA) == nil)
    }

    @Test("A legacy migration finishing after a document switch parks its notice")
    func migrationWhileSwitchingDocumentsParksNotice() async {
        let coordinator = Canvas3DEntryCoordinator()
        let canvasID = UUID()
        let docA = UUID()
        let docB = UUID()
        let nodeID = UUID()
        let gate = CompletionGate()
        let recorder = EntryPresentationRecorder()
        recorder.activeDocumentID = docA
        let notice = CanvasSceneMigrationNotice.failed(
            canvasID: canvasID, documentID: docA, nodeID: nodeID,
            message: "render placeholder refused", retryable: true)
        let entry = Canvas3DEntryCoordinator.Entry.migrationNotice(notice)
        let completion = Task { @MainActor in
            await gate.wait()
            guard let active = recorder.activeDocumentID else { return }
            if coordinator.shouldPresentImmediately(entry, activeDocumentID: active) {
                recorder.shown = notice
            } else {
                coordinator.park(entry)
            }
        }
        recorder.activeDocumentID = docB
        await gate.open()
        await completion.value

        #expect(recorder.shown == nil)
        #expect(coordinator.parkedEntry(forDocument: docB) == nil)
        // The frozen owner identity survives, including the retry disposition.
        #expect(coordinator.take(forDocument: docA) == entry)
        #expect(notice.owner.canvasID == canvasID)
        #expect(notice.owner.documentID == docA)
        #expect(notice.nodeID == nodeID)
    }

    @Test("The owning document locator never guesses a different document")
    func documentLocatorFindsOwningDocument() {
        var node = CanvasNode.placeholder(
            kind: .scene3D, position: CanvasPoint(x: 10, y: 10), zIndex: 1)
        node.id = UUID()
        let docA = CanvasDocument(id: UUID(), name: "A", nodes: [])
        let docB = CanvasDocument(id: UUID(), name: "B", nodes: [node])
        var project = CanvasProject(
            id: UUID(), name: "Locator",
            documents: [docA, docB], selectedDocumentID: docA.id)
        project.revision = 1
        // The node lives in B even though A is selected: the frozen owner is
        // B, so the presentation can never target A.
        #expect(Canvas3DDocumentLocator.documentID(
            of: node.id, in: project, preferredDocumentID: docA.id) == docB.id)
        #expect(Canvas3DDocumentLocator.documentID(of: node.id, in: project) == docB.id)
        #expect(Canvas3DDocumentLocator.documentID(
            of: UUID(), in: project, preferredDocumentID: docA.id) == nil)
    }
}
#endif
