// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeBuildingEditor
import FloeBuildingRecords
import FloeBuildingWorkspace
import FloeCore
import FloeTools

private struct BuildingStudioPage: Encodable {
    let projectID: UUID
    let kind = "building"
    let revision: String
    let contentSHA256: String
    let contentJSON: String
    let nextOffset: Int?
    let readFormat = "The optional building field accepts {action:'overview'}, {action:'drawingPages'}, {action:'search',query,rowOffset?} (50 hits), {action:'observations',roomID} (latest 100 observations) or {action:'sourceText',sourceVersionID} (UTF-8). Outer offset/limit page the same JSON result in characters."
    let editFormat: String?
    let saveScope = "projectWorkingCopy"
}

private struct BuildingStudioMutationReceipt: Encodable {
    let projectID: UUID
    let revision: String
    let result: String
    let ids: [String: UUID]
    var detail: String? = nil
    let saveScope = "projectWorkingCopy"
}

extension StudioCoordinator {
    func readBuilding(_ mount: BuildingStudioMount, query: BuildingStudioReadQuery, offset: Int, limit: Int,
                      context: ToolContext) async throws -> ToolExecutionOutput {
        try await authorizedBuilding(mount, context: context, editing: false)
        let original = mount.context
        let snapshot = try await original.recordsSnapshot()
        let bytes: Data
        switch query.action {
        case .overview:
            bytes = try StudioToolOutput.data(BuildingStudioOverview(snapshot))
        case .search:
            let rowOffset = query.rowOffset ?? 0
            let maximumOffset = RecordsLimits().maxSearchOffset
            guard let text = query.query, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 1024, (0...maximumOffset).contains(rowOffset) else { throw BuildingStudioInputError.invalid("Supply a search query and a rowOffset within the native search window.") }
            guard case .searchHits(let rows) = try await original.executeRecordCommand(.search(query: text, limit: 50, offset: rowOffset)) else { throw PersonalContentError.changedDocument }
            struct Matches: Encodable { let hits: [RecordSearchHit]; let nextRowOffset: Int?; let reachedSearchWindow: Bool }
            let more = rows.count == 50
            bytes = try StudioToolOutput.data(Matches(hits: rows, nextRowOffset: more && rowOffset + 50 <= maximumOffset ? rowOffset + 50 : nil,
                reachedSearchWindow: more && rowOffset + 50 > maximumOffset))
        case .observations:
            guard let roomID = query.roomID, snapshot.rooms.contains(where: { $0.id.rawValue == roomID }) else { throw BuildingStudioInputError.invalid("Use a current roomID from overview.") }
            guard case .observations(let rows) = try await original.executeRecordCommand(.observations(roomID: RoomID(roomID))) else { throw PersonalContentError.changedDocument }
            bytes = try StudioToolOutput.data(rows)
        case .sourceText:
            guard let id = query.sourceVersionID else { throw BuildingStudioInputError.invalid("Supply a current sourceVersionID.") }
            let source = try await original.sourceContent(SourceVersionID(id))
            let mediaType = source.version.mediaType.lowercased()
            guard source.data.count <= 2 * 1024 * 1024, mediaType.hasPrefix("text/") || mediaType == "application/json",
                  let text = String(data: source.data, encoding: .utf8) else { throw BuildingStudioInputError.invalid("This source is not a readable UTF-8 text document within 2 MiB.") }
            struct TextSource: Encodable { let sourceVersionID: UUID; let originalName: String; let sha256: String; let text: String }
            bytes = try StudioToolOutput.data(TextSource(sourceVersionID: id, originalName: source.version.originalName,
                sha256: source.version.contentSHA256, text: text))
        case .drawingPages:
            struct Page: Encodable { let id: UUID; let title: String }
            bytes = try StudioToolOutput.data(original.projectDrawingPages().map { Page(id: $0.id, title: $0.title) })
        }
        if query.action != .overview {
            guard try await original.recordsSnapshot().project.revision == snapshot.project.revision else { throw PersonalContentError.changedDocument }
        }
        try buildingProjects.verify(mount)
        try context.cancellation.throwIfCancelled()
        guard bytes.count <= 32 * 1024 * 1024 else { throw BuildingStudioInputError.invalid("Use a narrower records query.") }
        let text = String(decoding: bytes, as: UTF8.self)
        guard let start = text.index(text.startIndex, offsetBy: offset, limitedBy: text.endIndex) else { throw BuildingStudioInputError.invalid("The page offset exceeds this result.") }
        let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        let canEdit = context.allowedToolNames?.contains("studio.edit") != false && context.frozenEffectiveCatalogNames?.contains("studio.edit") != false
        return try StudioToolOutput.make(BuildingStudioPage(projectID: mount.id, revision: String(snapshot.project.revision),
            contentSHA256: StudioToolOutput.hash(bytes), contentJSON: String(text[start..<end]),
            nextOffset: end == text.endIndex ? nil : offset + limit, editFormat: canEdit ? BuildingStudioEdit.guide : nil))
    }

    func editBuilding(_ mount: BuildingStudioMount, revision: String, operations: String, context: ToolContext) async throws -> ToolExecutionOutput {
        try await authorizedBuilding(mount, context: context, editing: true)
        guard let expected = Int(revision), expected >= 0, String(expected) == revision,
              let call = context.toolCallID, !call.isEmpty else { throw PersonalContentError.changedDocument }
        let edit = try JSONDecoder().decode(BuildingStudioEdit.self, from: Data(operations.utf8))
        let original = mount.context
        guard try await original.recordsSnapshot().project.revision == expected else { throw PersonalContentError.changedDocument }
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        try buildingProjects.verify(mount)
        let replay = "studio/\(context.runID)/\(call)"
        let result: BuildingStudioMutationReceipt
        switch edit {
        case .createRoom(let name):
            let room = try await original.createRoomRecord(name: name, expectedRevision: expected)
            let saved = try await original.recordsSnapshot()
            guard saved.rooms.contains(where: { $0.id == room }) else { throw PersonalContentError.changedDocument }
            result = .init(projectID: mount.id, revision: String(saved.project.revision), result: "roomCreated", ids: ["roomID":room.rawValue])
        case .recordObservation(let draft):
            guard case .recorded(let saved) = try await original.executeRecordCommand(.recordObservations([draft]), expectedRevision: expected),
                  let row = saved.value.first else { throw PersonalContentError.changedDocument }
            result = .init(projectID: mount.id, revision: String(saved.receipt.revision), result: "observationRecorded", ids: ["observationID":row.id.rawValue])
        case .adoptObservation(let id):
            guard case .adopted(let saved) = try await original.executeRecordCommand(.adoptObservation(id), expectedRevision: expected) else { throw PersonalContentError.changedDocument }
            result = .init(projectID: mount.id, revision: String(saved.receipt.revision), result: "observationAdopted", ids: ["observationID":id.rawValue,"adoptedValueID":saved.value.id.rawValue])
        case .addNote(let title, let text):
            let saved = try await original.importSource(.init(kind: .note, title: title, originalName: "Note.txt", mediaType: "text/plain", data: Data(text.utf8), idempotencyKey: replay), expectedRevision: expected)
            result = .init(projectID: mount.id, revision: String(saved.snapshot.project.revision), result: "noteArchived", ids: ["sourceID":saved.source.id.rawValue,"sourceVersionID":saved.version.id.rawValue])
        case .importBOMCSV(let name, let data, let target):
            do {
                let saved = try await original.intakeCSV(data, originalName: name, expectedRevision: expected, targetID: target, idempotencyKey: replay)
                result = .init(projectID: mount.id, revision: String(saved.snapshot.project.revision), result: "draftNeedsReview", ids: ["draftID":saved.draft.id.rawValue,"sourceVersionID":saved.draft.sourceVersionID.rawValue])
            } catch let failure as BuildingWorkspaceIntakeError {
                let saved = failure.archived
                result = .init(projectID: mount.id, revision: String(saved.snapshot.project.revision), result: "sourceArchivedDraftFailed", ids: ["sourceID":saved.source.id.rawValue,"sourceVersionID":saved.version.id.rawValue], detail: failure.underlying.localizedDescription)
                var output = try StudioToolOutput.make(result)
                output.exitStatus = 1
                return output
            }
        }
        return try StudioToolOutput.make(result)
    }
}
#endif
