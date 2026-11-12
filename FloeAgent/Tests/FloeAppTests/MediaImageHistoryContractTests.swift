// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeSecurity
import FloeTools
import FloeWorkbench
@testable import FloeApp

@Suite("Managed media saved-history contracts", .serialized)
@MainActor struct MediaImageHistoryContractTests {
    @MainActor private struct Fixture: Sendable {
        let root: URL
        let session: MediaV2Session
        let authority: StudioDocumentAccess
        let taskID: UUID
        var projectURL: URL { session.store.projectURL(id: session.id) }
        func validate(taskID: UUID, editing: Bool) async throws {
            guard try await authority.canAccess(conversationID: taskID, projectID: session.id, editing: editing) else {
                throw FloeError.validationFailed("This task does not own the original")
            }
        }
    }
    @MainActor private final class InterleavingState {
        var committedBytes: Data?
        var ownerChecks = 0
        var publications = 0
    }

    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-history-\(UUID())")
        let media = PersonalMediaFactory.mediaRoot(directory: root)
        try FileManager.default.createDirectory(at: media.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        let store = MediaProjectStore(directory: media.appendingPathComponent("Projects"))
        let id = UUID(), taskID = UUID()
        let project = try MediaPreparedUpgrade.upgrade(MediaProject(id: id, kind: .image, name: "History fixture",
            canvas: .init(width: 64, height: 48), ownerKind: "files", ownerID: id, taskWorkspacePath: media.path))
        try await store.save(project)
        let session = try await PersonalMediaFactory.session(id: id, directory: root)
        let authority = try StudioDocumentAccess(root: root.appendingPathComponent("Authority"))
        try await authority.finishCreation(conversationID: taskID, projectID: id)
        return .init(root: root, session: session, authority: authority, taskID: taskID)
    }
    private func request(_ action: StudioMediaHistoryAction, revision: Int64, groupID: UUID? = nil, limit: Int = 20) throws -> StudioMediaHistoryRequest {
        var value: [String:Any] = ["expectedRevision": String(revision), "limit": limit]
        if let groupID { value["groupID"] = groupID.uuidString }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try StudioMediaHistory.decode(String(decoding: data, as: UTF8.self), action: action)
    }
    private func invoke(_ action: StudioMediaHistoryAction, fixture: Fixture, revision: Int64,
                        taskID: UUID? = nil, groupID: UUID? = nil, limit: Int = 20,
                        cancellation: CancellationToken = CancellationToken()) async throws -> StudioMediaHistoryReceipt {
        let value = try request(action, revision: revision, groupID: groupID, limit: limit)
        return try await StudioMediaHistory.perform(action: action, request: value, projectID: fixture.session.id,
            directory: fixture.root, expectedKind: .image,
            cancellation: cancellation, validateOwner: {
                try await fixture.validate(taskID: taskID ?? fixture.taskID, editing: action.isMutation)
            })
    }

    @Test func savedMediaEditHistoryUndoRedoKeepsProjectAndRefusesStaleOrForeignRequests() async throws {
        let f = try await fixture()
        defer { f.session.stopPlayback(); try? FileManager.default.removeItem(at: f.root) }
        let id = f.session.id
        let layer = MediaPreparedLayer(name: "Saved editable text", content: .text(.init(text: "History payload sentinel", fontSize: 8)))
        let edit = try await PersonalMediaFactory.apply(id: id, directory: f.root,
            operations: [.init(action: .insertLayer(layer: layer, parentID: nil, index: nil))], expectedRevision: f.session.document.revision)
        let editedRevision = f.session.document.revision
        let history = try await invoke(.history, fixture: f, revision: editedRevision, limit: 1)
        #expect(history.projectID == id && history.history.canUndo && !history.history.canRedo)
        #expect(history.history.nextUndoGroupID == edit.groupID && history.history.groups.count == 1)
        let before = try Data(contentsOf: f.projectURL)
        do {
            _ = try await invoke(.undo, fixture: f, revision: editedRevision, taskID: UUID())
            Issue.record("A foreign task undid the original")
        } catch { }
        #expect(try Data(contentsOf: f.projectURL) == before)

        let undo = try await invoke(.undo, fixture: f, revision: editedRevision, groupID: edit.groupID)
        #expect(undo.performedGroupID == edit.groupID && undo.committedRevision == undo.revision)
        #expect(f.session.id == id && f.session.document.layer(layer.id) == nil)
        #expect(undo.history.canRedo && undo.history.nextRedoGroupID == edit.groupID)
        let coldStore = MediaProjectStore(directory: f.session.root.appendingPathComponent("Projects"))
        let undone = try #require(try await coldStore.loadProject(id: id))
        #expect(undone.prepared?.layer(layer.id) == nil && undone.preparedJournal?.entry(edit.groupID)?.status == .undone)
        let undoneBytes = try Data(contentsOf: f.projectURL)
        do {
            _ = try await invoke(.redo, fixture: f, revision: editedRevision, groupID: edit.groupID)
            Issue.record("A stale revision redid the original")
        } catch { }
        #expect(try Data(contentsOf: f.projectURL) == undoneBytes)

        let redo = try await invoke(.redo, fixture: f, revision: f.session.document.revision, groupID: edit.groupID)
        #expect(redo.projectID == id && redo.performedGroupID == edit.groupID)
        #expect(f.session.document.layer(layer.id)?.content == layer.content)
        let reopened = try #require(try await coldStore.loadProject(id: id))
        #expect(reopened.id == id && reopened.prepared?.layer(layer.id)?.content == layer.content)
        #expect(reopened.preparedJournal?.entry(edit.groupID)?.status == .committed)
    }

    @Test func historyAtomicRevisionAndCancellationRefuseWithoutUndoingOrOverwriting() async throws {
        let f = try await fixture()
        defer { f.session.stopPlayback(); try? FileManager.default.removeItem(at: f.root) }
        let layer = MediaPreparedLayer(name: "Original", content: .strokes(.init()))
        let edit = try await f.session.apply([.init(action: .insertLayer(layer: layer, parentID: nil, index: nil))])
        let oldRevision = f.session.document.revision
        let other = MediaPreparedLayer(name: "Interleaved edit", content: .strokes(.init()))
        let state = InterleavingState()
        let input = try request(.undo, revision: oldRevision, groupID: edit.groupID)
        do {
            _ = try await StudioMediaHistory.perform(action: .undo, request: input, projectID: f.session.id,
                directory: f.root, expectedKind: .image,
                cancellation: CancellationToken(), validateOwner: {
                    try await f.validate(taskID: f.taskID, editing: true)
                    state.ownerChecks += 1
                    guard state.ownerChecks == 2 else { return }
                    // Real same-coordinator change after the caller's revision
                    // check proves the inner document-gate CAS is required.
                    _ = try await f.session.coordinator.applyUserOperations([.init(action: .insertLayer(layer: other, parentID: nil, index: nil))], to: f.session.id)
                    state.committedBytes = try Data(contentsOf: f.projectURL)
                })
            Issue.record("Undo accepted a revision changed while validating ownership")
        } catch { }
        #expect(try Data(contentsOf: f.projectURL) == state.committedBytes)
        try await f.session.reload()
        #expect(f.session.document.layer(layer.id) != nil && f.session.document.layer(other.id) != nil)
        #expect(f.session.project.preparedJournal?.entry(edit.groupID)?.status == .committed)
        #expect(!f.session.saving)

        let before = try Data(contentsOf: f.projectURL)
        let cancellation = CancellationToken()
        let current = try request(.undo, revision: f.session.document.revision)
        do {
            _ = try await StudioMediaHistory.perform(action: .undo, request: current, projectID: f.session.id,
                directory: f.root, expectedKind: .image,
                cancellation: cancellation, validateOwner: {
                    try await f.validate(taskID: f.taskID, editing: true)
                    cancellation.cancel()
                })
            Issue.record("Cancelled history operation committed")
        } catch { }
        #expect(try Data(contentsOf: f.projectURL) == before && !f.session.saving)
        do {
            _ = try await invoke(.undo, fixture: f, revision: f.session.document.revision, groupID: UUID())
            Issue.record("An unknown/non-boundary group was restored")
        } catch { }
        #expect(try Data(contentsOf: f.projectURL) == before)
    }

    @Test func historyPayloadAndPoliciesStayBoundedAndMutationScoped() async throws {
        let f = try await fixture()
        defer { f.session.stopPlayback(); try? FileManager.default.removeItem(at: f.root) }
        for index in 0..<2 {
            let layer = MediaPreparedLayer(name: "Private content \(index)", content: .text(.init(text: "Payload must not enter history \(index)", fontSize: 8)))
            _ = try await f.session.apply([.init(action: .insertLayer(layer: layer, parentID: nil, index: nil))])
        }
        let before = try Data(contentsOf: f.projectURL)
        let observation = InterleavingState()
        f.session.onCommit = { _ in observation.publications += 1 }
        let selected = f.session.selectedLayerID
        let result = try await invoke(.history, fixture: f, revision: f.session.document.revision, limit: 1)
        #expect(result.performedGroupID == nil && result.history.totalGroups == 2 && result.history.truncated)
        #expect(result.history.groups.count == 1 && result.history.groups[0].operationCount == 1)
        let encoded = try JSONEncoder().encode(result)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("Payload must not enter") && !text.contains("changes") && !text.contains("operationIDs"))
        #expect(try Data(contentsOf: f.projectURL) == before)
        #expect(observation.publications == 0 && f.session.selectedLayerID == selected)
        for json in ["{}", #"{"expectedRevision":-1}"#, #"{"expectedRevision":true}"#, #"{"expectedRevision":"0","limit":51}"#, #"{"expectedRevision":"0","limit":0}"#, #"{"expectedRevision":"0","path":"/tmp/elsewhere"}"#] {
            do { _ = try StudioMediaHistory.decode(json, action: .history); Issue.record("Malformed/path-shaped history input was accepted") } catch { }
        }
        let valid = try JSONSerialization.data(withJSONObject: ["expectedRevision": String(f.session.document.revision)])
        for action in ["history", "undo", "redo"] {
            let arguments: [String:Any] = ["projectID": f.session.id.uuidString, "action": action, "inputJSON": String(decoding: valid, as: UTF8.self)]
            let role = OrdinaryDocumentActionProfile.role(forToolName: "studio.run", arguments: arguments)
            let targets = TypedMutationContract.specs(for: "studio.run", arguments: arguments)
            if action == "history" {
                #expect(role == .readOnly && targets.isEmpty)
            } else {
                #expect(role == nil && targets.count == 1)
                #expect(targets.first?.storeKey == TypedMutationContract.nativeStudioLibraryStoreKey)
                #expect(targets.first?.role == .sourceWrite)
            }
        }
    }
}
#endif
