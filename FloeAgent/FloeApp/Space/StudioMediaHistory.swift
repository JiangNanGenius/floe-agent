// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeWorkbench

nonisolated enum StudioMediaHistoryAction: String, CaseIterable, Codable, Sendable {
    case history, undo, redo
    var isMutation: Bool { self != .history }
}

nonisolated struct StudioMediaHistoryRequest: Sendable {
    let expectedRevision: Int64
    let groupID: UUID?
    let limit: Int
}

nonisolated struct StudioMediaHistoryOptions: Decodable, Sendable {
    let groupID: UUID?
    let limit: Int?
}

nonisolated struct StudioMediaHistoryGroup: Codable, Sendable {
    let id: UUID
    let actor: MediaPreparedActorKind
    let status: MediaPreparedJournalStatus
    let baseRevision: Int64
    let committedRevision: Int64
    let operationCount: Int
    let touchedObjectCount: Int
    let committedAtUnixSeconds: Double
}

nonisolated struct StudioMediaHistorySummary: Codable, Sendable {
    let canUndo: Bool
    let canRedo: Bool
    let nextUndoGroupID: UUID?
    let nextRedoGroupID: UUID?
    let unavailableReason: String?
    let totalGroups: Int
    let truncated: Bool
    let groups: [StudioMediaHistoryGroup]
}

nonisolated struct StudioMediaHistoryReceipt: Codable, Sendable {
    let projectID: UUID
    let action: StudioMediaHistoryAction
    let revision: String
    let committedRevision: String?
    let performedGroupID: UUID?
    let history: StudioMediaHistorySummary
}

/// The public coordinator retains the saved-task, grant, exact original/use
/// lease and mutation gate. This helper never accepts a path or creates a copy.
@MainActor enum StudioMediaHistory {
    static func decode(_ inputJSON: String?, action: StudioMediaHistoryAction) throws -> StudioMediaHistoryRequest {
        guard let inputJSON, inputJSON.utf8.count <= 4_096,
              let object = try JSONSerialization.jsonObject(with: Data(inputJSON.utf8)) as? [String:Any],
              Set(object.keys).isSubset(of: ["expectedRevision", "groupID", "limit"]),
              let rawRevision = object["expectedRevision"] else {
            throw FloeError.validationFailed("Use inputJSON {expectedRevision, groupID?:UUID, limit?:1...50}; no paths or edit payloads")
        }
        // Share the existing exact decimal-string/integer revision grammar.
        let revisionJSON = try JSONSerialization.data(withJSONObject: ["expectedRevision": rawRevision])
        let input = try StudioMediaToolContract.decode(String(decoding: revisionJSON, as: UTF8.self))
        guard let revision = input.expectedRevision else { throw PersonalContentError.changedDocument }
        let options = try JSONDecoder().decode(StudioMediaHistoryOptions.self, from: Data(inputJSON.utf8))
        let limit = options.limit ?? 20
        guard (1...50).contains(limit), action.isMutation || options.groupID == nil else {
            throw FloeError.validationFailed("History limit is1...50; groupID is only for the current undo/redo boundary")
        }
        return .init(expectedRevision: revision, groupID: options.groupID, limit: limit)
    }

    static func perform(action: StudioMediaHistoryAction, request: StudioMediaHistoryRequest,
                        projectID: UUID, directory: URL, expectedKind: MediaProjectKind, cancellation: CancellationToken,
                        validateOwner: @escaping @MainActor @Sendable () async throws -> Void) async throws -> StudioMediaHistoryReceipt {
        try Task.checkCancellation(); try cancellation.throwIfCancelled()
        guard (1...50).contains(request.limit) else { throw PersonalContentError.invalidProject }
        try await validateOwner()
        try Task.checkCancellation(); try cancellation.throwIfCancelled()
        let commit: MediaPreparedCommit?
        let source: MediaProject
        let blocked: String?
        if action.isMutation {
            let session = try await PersonalMediaFactory.session(id: projectID, directory: directory)
            guard session.project.kind == expectedKind, session.compoundScopeID == nil else { throw PersonalContentError.invalidProject }
            commit = try await session.restoreManagedHistory(redo: action == .redo, groupID: request.groupID,
                expectedRevision: request.expectedRevision, cancellation: cancellation, validateOwner: validateOwner)
            source = session.project
            blocked = session.managedHistoryUnavailableReason
        } else {
            // Unlike session.open/reload, history inspection must not create
            // a default selection, refresh playback or publish onCommit.
            let root = PersonalMediaFactory.mediaRoot(directory: directory)
            let store = MediaProjectStore(directory: root.appendingPathComponent("Projects"))
            guard let project = try await store.loadProject(id: projectID), project.id == projectID,
                  project.kind == expectedKind, project.prepared != nil,
                  project.revision == request.expectedRevision else { throw PersonalContentError.changedDocument }
            try MediaPreparedIntegrity.validateEnvelope(project)
            try await validateOwner()
            try Task.checkCancellation(); try cancellation.throwIfCancelled()
            source = project
            blocked = try MediaV2Session.existingForAudioObservation(id: projectID, root: root)?.managedHistoryUnavailableReason
            commit = nil
        }
        // A completed durable mutation is never rolled back because a later
        // cancellation arrives. Return the actual commit and saved readback.
        let journal = source.preparedJournal ?? .init()
        let groups = journal.entries.sorted {
            if $0.committedRevision != $1.committedRevision { return $0.committedRevision > $1.committedRevision }
            return $0.id.uuidString < $1.id.uuidString
        }.prefix(request.limit).map {
            StudioMediaHistoryGroup(id: $0.id, actor: $0.actor, status: $0.status,
                baseRevision: $0.baseRevision, committedRevision: $0.committedRevision,
                operationCount: $0.operationIDs.count, touchedObjectCount: $0.changes.count,
                committedAtUnixSeconds: $0.committedAt.timeIntervalSince1970)
        }
        return .init(projectID: source.id, action: action, revision: String(source.revision),
            committedRevision: commit.map { String($0.revision) }, performedGroupID: commit?.groupID,
            history: .init(canUndo: blocked == nil && journal.nextUndo != nil,
                canRedo: blocked == nil && journal.nextRedo != nil,
                nextUndoGroupID: journal.nextUndo?.id, nextRedoGroupID: journal.nextRedo?.id,
                unavailableReason: blocked, totalGroups: journal.entries.count,
                truncated: journal.entries.count > request.limit, groups: groups))
    }
}
#endif
