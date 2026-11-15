// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBuildingRecords
import FloeBuildingWorkspace
import FloeInteriorCore
import FloeBuildingEditor
import FloeCAD

struct BuildingStudioReadQuery: Decodable, Sendable {
    enum Action: String, Decodable, Sendable {
        case overview, search, observations, sourceText, drawingPages, walls, copies, exportOptions
    }
    var action: Action = .overview
    var query: String?
    var rowOffset: Int?
    var roomID: UUID?
    var sourceVersionID: UUID?
}

enum BuildingStudioInputError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let message): message } }
}

/// Tool fields are converted to native records or wall commands. Storage
/// locations and physical measurement provenance are deliberately not
/// model-provided fields.
enum BuildingStudioEdit: Decodable, Sendable {
    case createRoom(String)
    case recordObservation(ObservationDraft)
    case adoptObservation(ObservationID)
    case addNote(String, String)
    case importBOMCSV(String, Data, BOMTargetID?)
    case addWall(storeyID: UUID?, a: [Double], b: [Double],
                 thicknessMM: Double?, heightMM: Double?, name: String?, expectedChangeCount: Int,
                 expectedWallRevision: Int)
    case moveWallEndpoint(wallID: UUID, end: InteriorWallEndpoint, point: [Double], expectedChangeCount: Int,
                          expectedWallRevision: Int)
    case updateWall(wallID: UUID, thicknessMM: Double?, heightMM: Double?, name: String?, expectedChangeCount: Int,
                    expectedWallRevision: Int)
    case deleteWall(wallID: UUID, expectedChangeCount: Int, expectedWallRevision: Int)
    case setWallFinish(wallID: UUID, side: InteriorWallSide, finishID: String?, expectedChangeCount: Int,
                       expectedWallRevision: Int)
    case swapWallFinishes(wallID: UUID, expectedChangeCount: Int, expectedWallRevision: Int)
    case saveAsBuilding(title: String?, expectedGenerationID: String?)
    case exportCADCopy(kind: BuildingProjectCopyKind, pageID: UUID?, title: String?, scope: CADBuildingExportScope, expectedGenerationID: String?)

    case exportExchange(format: BuildingInterchangeFormat, pageID: UUID?, title: String?, scope: CADBuildingExportScope, expectedGenerationID: String?)

    private enum Key: String, CodingKey {
        case action, name, roomID, propertyKey, rawValue, normalizedValue, origin, sourceVersionID, locator, note
        case observationID, title, text, originalName, csv, targetID
        case storeyID, a, b, thicknessMM, heightMM, end, point, wallID, side, finishID
        case format, kind, pageID, scope, elementIDs, discipline, expectedGenerationID, expectedChangeCount, expectedWallRevision
    }
    private enum Action: String, Decodable {
        case createRoom, recordObservation, adoptObservation, addNote, importBOMCSV
        case addWall, moveWallEndpoint, updateWall, deleteWall, setWallFinish, swapWallFinishes
        case saveAsBuilding, exportCADCopy, exportExchange
    }
    private enum AIOrigin: String, Decodable { case inferred = "ai_inferred", extracted = "ai_extracted" }
    private enum Endpoint: String, Decodable { case start, end }
    private enum Side: String, Decodable { case left, right }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: Key.self)
        switch try fields.decode(Action.self, forKey: .action) {
        case .createRoom:
            self = .createRoom(try fields.decode(String.self, forKey: .name))
        case .recordObservation:
            let source = try fields.decodeIfPresent(SourceVersionID.self, forKey: .sourceVersionID)
            let origin = try fields.decodeIfPresent(AIOrigin.self, forKey: .origin) ?? .inferred
            guard origin != .extracted || source != nil else {
                throw BuildingStudioInputError.invalid("An extracted observation requires its actual sourceVersionID.")
            }
            self = .recordObservation(.init(roomID: try fields.decode(RoomID.self, forKey: .roomID),
                propertyKey: try fields.decode(String.self, forKey: .propertyKey),
                rawValue: try fields.decode(String.self, forKey: .rawValue),
                normalizedValue: try fields.decodeIfPresent(RecordedValue.self, forKey: .normalizedValue),
                origin: origin == .extracted ? .aiExtracted : .aiInferred, sourceVersionID: source,
                locator: try fields.decodeIfPresent(SourceLocator.self, forKey: .locator),
                note: try fields.decodeIfPresent(String.self, forKey: .note) ?? ""))
        case .adoptObservation:
            self = .adoptObservation(try fields.decode(ObservationID.self, forKey: .observationID))
        case .addNote:
            let title = try fields.decode(String.self, forKey: .title)
            let text = try fields.decode(String.self, forKey: .text)
            guard !text.isEmpty, text.utf8.count <= 64 * 1024 else {
                throw BuildingStudioInputError.invalid("Supply 1–65536 UTF-8 bytes of note text.")
            }
            self = .addNote(title, text)
        case .importBOMCSV:
            let name = try fields.decode(String.self, forKey: .originalName)
            let csv = try fields.decode(String.self, forKey: .csv)
            guard !csv.isEmpty, csv.utf8.count <= 256 * 1024, name.lowercased().hasSuffix(".csv"),
                  !name.contains("/"), !name.contains("\\") else {
                throw BuildingStudioInputError.invalid("Supply a CSV filename and 1–262144 UTF-8 bytes of CSV text.")
            }
            self = .importBOMCSV(name, Data(csv.utf8), try fields.decodeIfPresent(BOMTargetID.self, forKey: .targetID))
        case .addWall:
            let expected = try fields.decode(Int.self, forKey: .expectedChangeCount)
            let wallRevision = try fields.decode(Int.self, forKey: .expectedWallRevision)
            guard expected >= 0, wallRevision >= 0 else {
                throw BuildingStudioInputError.invalid("expectedChangeCount and expectedWallRevision must be nonnegative.")
            }
            self = .addWall(
                storeyID: try fields.decodeIfPresent(UUID.self, forKey: .storeyID),
                a: try fields.decode([Double].self, forKey: .a),
                b: try fields.decode([Double].self, forKey: .b),
                thicknessMM: try fields.decodeIfPresent(Double.self, forKey: .thicknessMM),
                heightMM: try fields.decodeIfPresent(Double.self, forKey: .heightMM),
                name: try fields.decodeIfPresent(String.self, forKey: .name),
                expectedChangeCount: expected,
                expectedWallRevision: wallRevision
            )
        case .moveWallEndpoint:
            let expected = try fields.decode(Int.self, forKey: .expectedChangeCount)
            let wallRevision = try fields.decode(Int.self, forKey: .expectedWallRevision)
            let end = try fields.decode(Endpoint.self, forKey: .end)
            self = .moveWallEndpoint(
                wallID: try fields.decode(UUID.self, forKey: .wallID),
                end: end == .start ? .start : .end,
                point: try fields.decode([Double].self, forKey: .point),
                expectedChangeCount: expected,
                expectedWallRevision: wallRevision
            )
        case .updateWall:
            let expected = try fields.decode(Int.self, forKey: .expectedChangeCount)
            let wallRevision = try fields.decode(Int.self, forKey: .expectedWallRevision)
            self = .updateWall(
                wallID: try fields.decode(UUID.self, forKey: .wallID),
                thicknessMM: try fields.decodeIfPresent(Double.self, forKey: .thicknessMM),
                heightMM: try fields.decodeIfPresent(Double.self, forKey: .heightMM),
                name: try fields.decodeIfPresent(String.self, forKey: .name),
                expectedChangeCount: expected,
                expectedWallRevision: wallRevision
            )
        case .deleteWall:
            self = .deleteWall(
                wallID: try fields.decode(UUID.self, forKey: .wallID),
                expectedChangeCount: try fields.decode(Int.self, forKey: .expectedChangeCount),
                expectedWallRevision: try fields.decode(Int.self, forKey: .expectedWallRevision)
            )
        case .setWallFinish:
            let side = try fields.decode(Side.self, forKey: .side)
            self = .setWallFinish(
                wallID: try fields.decode(UUID.self, forKey: .wallID),
                side: side == .left ? .left : .right,
                finishID: try fields.decodeIfPresent(String.self, forKey: .finishID),
                expectedChangeCount: try fields.decode(Int.self, forKey: .expectedChangeCount),
                expectedWallRevision: try fields.decode(Int.self, forKey: .expectedWallRevision)
            )
        case .swapWallFinishes:
            self = .swapWallFinishes(
                wallID: try fields.decode(UUID.self, forKey: .wallID),
                expectedChangeCount: try fields.decode(Int.self, forKey: .expectedChangeCount),
                expectedWallRevision: try fields.decode(Int.self, forKey: .expectedWallRevision)
            )
        case .saveAsBuilding:
            self = .saveAsBuilding(
                title: try fields.decodeIfPresent(String.self, forKey: .title),
                expectedGenerationID: try fields.decodeIfPresent(String.self, forKey: .expectedGenerationID)
            )
        case .exportCADCopy, .exportExchange:
            let scope: CADBuildingExportScope
            switch try fields.decodeIfPresent(String.self, forKey: .scope) ?? "wholeProject" {
            case "wholeProject": scope = .wholeProject
            case "storey": scope = .storey(try fields.decode(UUID.self, forKey: .storeyID))
            case "elements":
                let ids = try fields.decode([UUID].self, forKey: .elementIDs)
                guard (1...4096).contains(ids.count) else { throw BuildingStudioInputError.invalid("Select 1 to 4096 current elements.") }
                scope = .elements(Set(ids))
            case "discipline": scope = .discipline(try fields.decode(CADBuildingExportDiscipline.self, forKey: .discipline))
            default: throw BuildingStudioInputError.invalid("Use wholeProject, storey, elements or discipline.")
            }
            let page = try fields.decodeIfPresent(UUID.self, forKey: .pageID)
            let title = try fields.decodeIfPresent(String.self, forKey: .title)
            let generation = try fields.decodeIfPresent(String.self, forKey: .expectedGenerationID)
            if try fields.decode(Action.self, forKey: .action) == .exportExchange {
                let raw = try fields.decode(String.self, forKey: .format).lowercased()
                guard let format = BuildingInterchangeFormat(rawValue: raw) else {
                    throw BuildingStudioInputError.invalid("Use dwg, dxf, pdf, ifc, step, glb, obj or stl.")
                }
                self = .exportExchange(format: format, pageID: page, title: title, scope: scope, expectedGenerationID: generation)
            } else {
                guard let kind = BuildingProjectCopyKind(rawValue: try fields.decode(String.self, forKey: .kind)), kind != .building else {
                    throw BuildingStudioInputError.invalid("Use kind cad2D or cad3D.")
                }
                self = .exportCADCopy(kind: kind, pageID: page, title: title, scope: scope, expectedGenerationID: generation)
            }
        }
    }

    var expectedChangeCount: Int? {
        switch self {
        case let .addWall(_, _, _, _, _, _, expected, _): return expected
        case let .moveWallEndpoint(_, _, _, expected, _): return expected
        case let .updateWall(_, _, _, _, expected, _): return expected
        case let .deleteWall(_, expected, _): return expected
        case let .setWallFinish(_, _, _, expected, _): return expected
        case let .swapWallFinishes(_, expected, _): return expected
        default: return nil
        }
    }

    var expectedWallRevision: Int? {
        switch self {
        case let .addWall(_, _, _, _, _, _, _, revision): return revision
        case let .moveWallEndpoint(_, _, _, _, revision): return revision
        case let .updateWall(_, _, _, _, _, revision): return revision
        case let .deleteWall(_, _, revision): return revision
        case let .setWallFinish(_, _, _, _, revision): return revision
        case let .swapWallFinishes(_, _, revision): return revision
        default: return nil
        }
    }

    var expectedGenerationID: String? {
        switch self {
        case let .saveAsBuilding(_, generation): return generation
        case let .exportCADCopy(_, _, _, _, generation), let .exportExchange(_, _, _, _, generation): return generation
        default: return nil
        }
    }

    static let guide = "Use one JSON object with an action. Record actions use the exact records revision from the current studio.read overview. Wall actions also require expectedChangeCount from buildingChangeCount and expectedWallRevision from wallRevision (or the walls result) and must use current wall IDs; the wall revision also advances on finish-only edits. Actions: createRoom(name); recordObservation(roomID,propertyKey,rawValue,optional normalizedValue/origin/sourceVersionID/locator/note); adoptObservation(observationID); addNote(title,text); importBOMCSV(originalName,csv,optional targetID); addWall(a,b,optional storeyID/thicknessMM/heightMM/name,expectedChangeCount,expectedWallRevision); moveWallEndpoint(wallID,end:start|end,point,expectedChangeCount,expectedWallRevision); updateWall(wallID,optional thicknessMM/heightMM/name,expectedChangeCount,expectedWallRevision); deleteWall(wallID,expectedChangeCount,expectedWallRevision); setWallFinish(wallID,side:left|right,optional finishID,expectedChangeCount,expectedWallRevision) — null finishID clears the face; swapWallFinishes(wallID,expectedChangeCount,expectedWallRevision); saveAsBuilding(optional title, optional expectedGenerationID); exportCADCopy(kind:cad2D|cad3D, optional pageID/title/expectedGenerationID, scope wholeProject|storey|elements|discipline, corresponding storeyID|elementIDs|discipline). exportExchange(format:dwg|dxf|pdf|ifc|step|glb|obj|stl, same scope fields) delivers an independent file. Copy actions never overwrite the original; they return independent copy receipts with new IDs. 2D defaults to an editable floor plan from the selected geometry. A pageID selects an existing drawing page for a whole-project 2D copy. Use studio.read exportOptions for current IDs. Finish IDs must come from finishCatalog in the walls result. Example: {\"action\":\"createRoom\",\"name\":\"Study\"}. Geometry examples: {\"action\":\"addWall\",\"a\":[0,0],\"b\":[4000,0],\"thicknessMM\":200,\"heightMM\":2700,\"expectedChangeCount\":12,\"expectedWallRevision\":0}. The native project Save checkpoints the complete project, including wall finishes and pending drafts."
}

struct BuildingStudioOverview: Encodable {
    let project: ProjectRecord
    let rooms: [RoomRecord]
    let sources: [SourceRecord]
    let targets: [BOMTarget]
    let drafts: [BOMDraftSummary]
    let items: [BOMItem]
    let selectedTargetID: BOMTargetID?
    let sourcesHaveMore: Bool
    let draftsHaveMore: Bool
    let itemsHaveMore: Bool
    let buildingChangeCount: Int?
    let wallRevision: Int?
    let wallCount: Int?
    let wallFinishCount: Int?
    let generationID: String?

    init(_ value: BuildingWorkspaceSnapshot, walls: BuildingWallSnapshot?) {
        project = value.project; rooms = value.rooms; sources = value.sources; targets = value.targets
        drafts = value.drafts; items = value.items; selectedTargetID = value.selectedTargetID
        sourcesHaveMore = value.sourcesHaveMore; draftsHaveMore = value.draftsHaveMore; itemsHaveMore = value.itemsHaveMore
        buildingChangeCount = walls?.changeCount
        wallRevision = walls?.wallRevision
        wallCount = walls?.walls.count
        wallFinishCount = walls.map { snapshot in
            snapshot.walls.reduce(0) { count, wall in
                count + (wall.leftFinishID == nil ? 0 : 1) + (wall.rightFinishID == nil ? 0 : 1)
            }
        }
        generationID = walls?.generationID
    }
}
