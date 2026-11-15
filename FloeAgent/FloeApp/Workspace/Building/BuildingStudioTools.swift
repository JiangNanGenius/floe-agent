// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeBuildingEditor
import FloeCAD
import FloeBuildingRecords
import FloeBuildingWorkspace
import FloeInteriorCore
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
    let buildingChangeCount: Int?
    let wallRevision: Int?
    let generationID: String?
    var saveScope = "projectWorkingCopy"
}

private struct BuildingStudioMutationReceipt: Encodable {
    let projectID: UUID
    let revision: String
    let result: String
    let ids: [String: UUID]
    var detail: String? = nil
    var buildingChangeCount: Int? = nil
    var wallRevision: Int? = nil
    var copies: [BuildingProjectCopyReceipt]? = nil
    var saveScope = "projectWorkingCopy"
}

extension StudioCoordinator {
    func readBuilding(_ mount: BuildingStudioMount, query: BuildingStudioReadQuery, offset: Int, limit: Int,
                      context: ToolContext) async throws -> ToolExecutionOutput {
        try await authorizedBuilding(mount, context: context, editing: false)
        let original = mount.context
        let snapshot = try await original.recordsSnapshot()
        let walls = try original.wallSnapshot()
        let bytes: Data
        switch query.action {
        case .overview:
            bytes = try StudioToolOutput.data(BuildingStudioOverview(snapshot, walls: walls))
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
        case .walls:
            bytes = try StudioToolOutput.data(walls)
        case .exportOptions:
            struct Option: Encodable { let id: UUID; let name: String; let storeyID: UUID; let discipline: String }
            struct Options: Encodable { let storeys: [CADBuildingStorey]; let elements: [Option]; let nextRow: Int? }
            let selection = try original.nativeDocument.buildingExportSelection(.wholeProject)
            let start = min(max(0, query.rowOffset ?? 0), selection.elements.count)
            let rows = selection.elements.dropFirst(start).prefix(100)
            bytes = try StudioToolOutput.data(Options(storeys: selection.storeys, elements: rows.map {
                Option(id: $0.id, name: $0.name, storeyID: $0.storeyID, discipline: $0.kind.exportDiscipline.rawValue)
            }, nextRow: start + rows.count < selection.elements.count ? start + rows.count : nil))
        case .copies:
            bytes = try StudioToolOutput.data(original.listProjectCopies())
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
            nextOffset: end == text.endIndex ? nil : offset + limit,
            editFormat: canEdit ? BuildingStudioEdit.guide : nil,
            buildingChangeCount: walls.changeCount,
            wallRevision: walls.wallRevision,
            generationID: walls.generationID))
    }

    func editBuilding(_ mount: BuildingStudioMount, revision: String, operations: String, context: ToolContext) async throws -> ToolExecutionOutput {
        try await authorizedBuilding(mount, context: context, editing: true)
        guard let expected = Int(revision), expected >= 0, String(expected) == revision,
              let call = context.toolCallID, !call.isEmpty else { throw PersonalContentError.changedDocument }
        let edit = try JSONDecoder().decode(BuildingStudioEdit.self, from: Data(operations.utf8))
        let original = mount.context
        guard try await original.recordsSnapshot().project.revision == expected else { throw PersonalContentError.changedDocument }
        if let generation = edit.expectedGenerationID, generation != original.generationID {
            throw PersonalContentError.changedDocument
        }
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
        case let .addWall(storeyID, a, b, thicknessMM, heightMM, name, changeCount, wallRevision):
            let value = try await original.applyWallCommand(
                .addWall(storeyID: storeyID, a: a, b: b, thicknessMM: thicknessMM,
                         heightMM: heightMM, name: name),
                expectedChangeCount: changeCount, expectedWallRevision: wallRevision)
            result = try await wallResult(value, mount: mount, original: original,
                                          outcome: "wallAdded", wallID: value.wallID)
        case let .moveWallEndpoint(wallID, end, point, changeCount, wallRevision):
            let value = try await original.applyWallCommand(
                .moveEndpoint(wallID: wallID, end: end, point: point),
                expectedChangeCount: changeCount, expectedWallRevision: wallRevision)
            result = try await wallResult(value, mount: mount, original: original,
                                          outcome: "wallEndpointMoved", wallID: wallID)
        case let .updateWall(wallID, thicknessMM, heightMM, name, changeCount, wallRevision):
            let value = try await original.applyWallCommand(
                .updateWall(wallID: wallID, thicknessMM: thicknessMM, heightMM: heightMM, name: name),
                expectedChangeCount: changeCount, expectedWallRevision: wallRevision)
            result = try await wallResult(value, mount: mount, original: original,
                                          outcome: "wallUpdated", wallID: wallID)
        case let .deleteWall(wallID, changeCount, wallRevision):
            let value = try await original.applyWallCommand(
                .deleteWall(wallID: wallID),
                expectedChangeCount: changeCount, expectedWallRevision: wallRevision)
            result = try await wallResult(value, mount: mount, original: original,
                                          outcome: "wallDeleted", wallID: wallID)
        case let .setWallFinish(wallID, side, finishID, changeCount, wallRevision):
            let value = try await original.applyWallCommand(
                .setFinish(wallID: wallID, side: side, finishID: finishID),
                expectedChangeCount: changeCount, expectedWallRevision: wallRevision)
            result = try await wallResult(value, mount: mount, original: original,
                                          outcome: finishID == nil ? "wallFinishCleared" : "wallFinishSet",
                                          wallID: wallID)
        case let .swapWallFinishes(wallID, changeCount, wallRevision):
            let value = try await original.applyWallCommand(
                .swapFinishes(wallID: wallID),
                expectedChangeCount: changeCount, expectedWallRevision: wallRevision)
            result = try await wallResult(value, mount: mount, original: original,
                                          outcome: "wallFinishesSwapped", wallID: wallID)
        case let .saveAsBuilding(title, _):
            let saved = try await original.recordsSnapshot()
            let copy = try await original.saveBuildingCopy(title: title)
            result = .init(projectID: mount.id, revision: String(saved.project.revision),
                           result: "buildingCopySaved", ids: ["copyID": copy.id],
                           detail: copy.losses.joined(separator: "\n"), copies: [copy], saveScope: "independentSpaceProject")
        case let .exportExchange(format, pageID, title, scope, _):
            let file = try await original.exportExchangeFile(format: format, scope: scope, pageID: pageID, title: title)
            let published = try await StudioResultPublication.publish(
                file: file.url, projectRoot: file.url.deletingLastPathComponent(), action: "buildingExchange",
                fileKey: file.url.lastPathComponent, context: context,
                validateSource: { @MainActor in
                    try context.cancellation.throwIfCancelled()
                    try self.buildingProjects.verify(mount)
                    try await self.authorizedBuilding(mount, context: context, editing: true)
                })
            var output = try StudioToolOutput.make(BuildingStudioMutationReceipt(
                projectID: mount.id, revision: revision, result: "exchangeFileSaved", ids: [:],
                detail: ([file.url.lastPathComponent, file.sha256] + file.losses).joined(separator: "\n"), saveScope: "runOutputFile"))
            output.outputFiles = [published.file]
            return output
        case let .exportCADCopy(kind, pageID, title, scope, _):
            guard kind != .building else {
                throw BuildingStudioInputError.invalid("Use saveAsBuilding for a building package.")
            }
            let saved = try await original.recordsSnapshot()
            let copy = try await original.exportCADCopy(kind: kind, pageID: pageID, title: title, scope: scope)
            result = .init(projectID: mount.id, revision: String(saved.project.revision),
                           result: kind == .cad2D ? "cad2DCopySaved" : "cad3DCopySaved",
                           ids: ["copyID": copy.id],
                           detail: copy.losses.joined(separator: "\n"), copies: [copy], saveScope: "independentSpaceProject")
        }
        return try StudioToolOutput.make(result)
    }

    private func wallResult(_ value: BuildingWallEditResult, mount: BuildingStudioMount,
                            original: BuildingEditorToolContext, outcome: String,
                            wallID: UUID?) async throws -> BuildingStudioMutationReceipt {
        let saved = try await original.recordsSnapshot()
        var ids: [String: UUID] = [:]
        if let wallID { ids["wallID"] = wallID }
        return .init(projectID: mount.id, revision: String(saved.project.revision),
                     result: outcome, ids: ids, buildingChangeCount: value.changeCount,
                     wallRevision: value.wallRevision)
    }
}
#endif
