// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeBuildingRecords
import FloeBuildingWorkspace

struct BuildingStudioReadQuery: Decodable, Sendable {
    enum Action: String, Decodable, Sendable { case overview, search, observations, sourceText, drawingPages }
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

/// Tool fields are converted to native records commands. Storage locations and
/// physical measurement provenance are deliberately not model-provided fields.
enum BuildingStudioEdit: Decodable, Sendable {
    case createRoom(String)
    case recordObservation(ObservationDraft)
    case adoptObservation(ObservationID)
    case addNote(String, String)
    case importBOMCSV(String, Data, BOMTargetID?)

    private enum Key: String, CodingKey {
        case action, name, roomID, propertyKey, rawValue, normalizedValue, origin, sourceVersionID, locator, note
        case observationID, title, text, originalName, csv, targetID
    }
    private enum Action: String, Decodable { case createRoom, recordObservation, adoptObservation, addNote, importBOMCSV }
    private enum AIOrigin: String, Decodable { case inferred = "ai_inferred", extracted = "ai_extracted" }

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
        }
    }

    static let guide = "Use one JSON object with an action and the exact records revision. Actions and fields: createRoom(name); recordObservation(roomID,propertyKey,rawValue,optional normalizedValue/origin/sourceVersionID/locator/note); adoptObservation(observationID); addNote(title,text); importBOMCSV(originalName,csv,optional targetID). Example: {\"action\":\"createRoom\",\"name\":\"Study\"}. An observation defaults to ai_inferred. Specify ai_extracted only for direct extraction from an actual sourceVersionID. Example normalizedValue: {\"kind\":\"number\",\"number\":2450,\"unit\":\"mm\"}. Copy IDs from the current project. A created room is a records row. Adoption requires a normalized value. CSV creates an archived source and a review draft. The native project Save checkpoints the complete project, including pending editor drafts."
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

    init(_ value: BuildingWorkspaceSnapshot) {
        project = value.project; rooms = value.rooms; sources = value.sources; targets = value.targets
        drafts = value.drafts; items = value.items; selectedTargetID = value.selectedTargetID
        sourcesHaveMore = value.sourcesHaveMore; draftsHaveMore = value.draftsHaveMore; itemsHaveMore = value.itemsHaveMore
    }
}
