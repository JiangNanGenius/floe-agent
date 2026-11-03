// SPDX-License-Identifier: MPL-2.0
#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Observation
import SwiftUI
import FloeCAD
import FloeCore
import FloeModels
import FloePersistence

@MainActor @Observable final class CADM30SelectedTargetUIFixture {
    static let argument = "--ui-test-cad-m30-selected"
    let document: FloeCADDocument
    let descriptor: CADM30TargetDescriptor
    let nonce: UUID
    let conversationID: UUID
    let workspaceID: UUID
    var status = "awaiting real History tap"
    var observed: CADSelectionContext?
    var rowIdentifier: String { (descriptor.targetKind == "datum_plane" ? "HistoryPlane-" : "HistoryRow-") + descriptor.targetName }
    var selected: Bool {
        guard let context = observed, context.historySelectionGeneration > 0 else { return false }
        if descriptor.targetKind == "datum_plane" { return context.datumPlane?.id == descriptor.targetID && context.features.isEmpty && context.bodies.isEmpty }
        return context.features.count == 1 && context.features.first?.id == descriptor.targetID
    }
    private init(document: FloeCADDocument, descriptor: CADM30TargetDescriptor,
                 nonce: UUID, conversationID: UUID, workspaceID: UUID) {
        self.document = document; self.descriptor = descriptor; self.nonce = nonce
        self.conversationID = conversationID; self.workspaceID = workspaceID
    }
    static func prepare(in environment: AppEnvironment) async throws -> CADM30SelectedTargetUIFixture {
        let nonce = try CADM30SelectionWitness.nonce()
        guard let raw = ProcessInfo.processInfo.environment["FLOE_M30_TARGET"],
              let target = CADM30TargetDescriptor.Target(rawValue: raw) else { throw CADM30SelectedTargetFixture.fail("Missing explicit M30 target") }
        let directory = try CADM30SelectionWitness.directory(nonce)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let witnessURL = directory.appendingPathComponent(target.rawValue + ".json")
        guard !FileManager.default.fileExists(atPath: witnessURL.path) else { throw CADM30SelectedTargetFixture.fail("Fresh nonce required; never overwrite an existing UI witness") }
        let deadline = Date().addingTimeInterval(90)
        while !environment.persistenceReady {
            guard Date() < deadline else { throw CADM30SelectedTargetFixture.fail("Database unavailable") }
            try await Task.sleep(for: .milliseconds(100))
        }
        let conversationID = UUID()
        try await environment.conversationStore.saveConversation(ConversationRecord(id: conversationID,
            title: "M30 TEST-CREATED \(target.rawValue) \(nonce.uuidString)", createdAt: Date(), updatedAt: Date()))
        ComposerDraftStore.shared.save(text: "M30 synthetic unsent draft", conversationID: conversationID)
        try await environment.workspaceCenter.openTaskWorkspace(conversationID: conversationID)
        guard let workspace = environment.workspaceCenter.currentWorkspace,
              workspace.kind == .privateTask,
              workspace.internalRelativePath == "PrivateTasks/\(conversationID.uuidString)",
              let root = environment.workspaceCenter.currentRootURL else { throw CADM30SelectedTargetFixture.fail("Workspace ownership mismatch") }
        let (doc, descriptor) = try await CADM30SelectedTargetFixture.seed(target,
            at: root.appendingPathComponent("M30-\(target.rawValue).floecad", isDirectory: true))
        return .init(document: doc, descriptor: descriptor, nonce: nonce,
                     conversationID: conversationID, workspaceID: workspace.id)
    }
    func didAttach(_ attachment: AttachmentRef) {
        do {
            let file = try CADM30SelectionWitness.directory(nonce).appendingPathComponent(descriptor.target.rawValue + ".json")
            var witness = try JSONDecoder().decode(CADM30SelectionWitness.self, from: Data(contentsOf: file))
            guard selected, witness.modelSHA256 == document.modelSHA256,
                  witness.revision == document.revision,
                  ComposerDraftStore.shared.text(for: conversationID) == "M30 synthetic unsent draft",
                  ComposerDraftStore.shared.attachments(for: conversationID).contains(where: { $0 == attachment }) else {
                throw CADM30SelectedTargetFixture.fail("Real composer attachment adoption mismatch")
            }
            witness.selectionAttachment = attachment
            let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
            try encoder.encode(witness).write(to: file, options: .atomic)
            status = "witness ready with attachment \(descriptor.target.rawValue)"
        } catch { status = "witness FAILED: \(error.localizedDescription)" }
    }

    func observe(_ context: CADSelectionContext) { observed = context; status = selected ? "real target selected; press Save" : "awaiting real History tap" }
    /// Called by the shipped host Save action only, after the ordinary save.
    func didSave(_ outcome: CADSaveOutcome) {
        do {
            guard outcome.succeeded, selected, let previous = observed else { throw CADM30SelectedTargetFixture.fail(outcome.error ?? "Select the actual target before Save") }
            let context = document.assistantSelectionContext()
            guard context.historySelectionGeneration == previous.historySelectionGeneration,
                  context.features == previous.features, context.datumPlane == previous.datumPlane,
                  !document.hasUnsavedChanges else { throw CADM30SelectedTargetFixture.fail("Selection changed or save is incomplete") }
            let contextData = try JSONSerialization.data(withJSONObject: context.jsonObject(), options: [.sortedKeys])
            let witness = CADM30SelectionWitness(nonce: nonce, conversationID: conversationID,
                workspaceID: workspaceID, documentName: document.url.lastPathComponent, descriptor: descriptor,
                revision: document.revision, changeCount: context.changeCount,
                contentSHA256: document.contentSHA256, modelSHA256: document.modelSHA256,
                documentJSONSHA256: try FloeDigest.sha256Hex(ofFileAt: document.url.appendingPathComponent("document.json")),
                selectionContextJSON: String(decoding: contextData, as: UTF8.self),
                historyGeneration: context.historySelectionGeneration)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try encoder.encode(witness).write(to: CADM30SelectionWitness.directory(nonce)
                .appendingPathComponent(descriptor.target.rawValue + ".json"), options: .atomic)
            status = "witness saved \(descriptor.target.rawValue) \(document.modelSHA256)"
        } catch { status = "witness FAILED: \(error.localizedDescription)" }
    }
}
struct CADM30SelectedTargetReadback: View {
    let fixture: CADM30SelectedTargetUIFixture
    var body: some View {
        VStack(alignment: .leading) {
            Text(fixture.rowIdentifier).accessibilityIdentifier("M30TargetRow")
            Text(fixture.descriptor.targetID).accessibilityIdentifier("M30TargetID")
            Text(fixture.selected ? "selected" : "unselected").accessibilityIdentifier("M30SelectionState")
            Text(fixture.status).accessibilityIdentifier("M30WitnessStatus")
        }
        .font(.system(size: 9, design: .monospaced)).padding(5)
        .background(.regularMaterial).allowsHitTesting(false)
    }
}
#endif
