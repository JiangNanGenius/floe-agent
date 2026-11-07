// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation

public nonisolated struct CADBuildingWallInput: Codable, Sendable {
    public var name: String
    public var a: [Double]
    public var b: [Double]
    public var thicknessMM: Double
    public var heightMM: Double
    public var storeyID: UUID?
    public var baseOffsetMM: Double?
}

public nonisolated struct CADBuildingRoomInput: Codable, Sendable {
    public var name: String
    /// Opposite corners of the authored space, in the building plan's mm.
    public var min: [Double]
    public var max: [Double]
    public var heightMM: Double
    public var wallThicknessMM: Double
    /// Explicit: false is semantic space only; true adds four real walls.
    public var withWalls: Bool
    public var storeyID: UUID?
    public var baseOffsetMM: Double?
}

/// Thin typed adapter over the SAME Building workbench model and transaction.
/// The host's existing parameters bridge supplies task scope, checkpoint,
/// native store/CAS save and its truthful commit/rollback receipt.
@MainActor public final class CADBuildingToolService {
    public static let actions = ["building.catalog", "building.inspect", "building.addWall", "building.addRoom"]
    public static let reads: Set<String> = ["building.catalog", "building.inspect"]
    private static let envelope: Set<String> = ["action", "revision", "expected_revision", "expected_change_count", "expected_source_sha256"]
    private static let wallFields: Set<String> = ["name", "a", "b", "thicknessMM", "heightMM", "storeyID", "baseOffsetMM"]
    private static let roomFields: Set<String> = ["name", "min", "max", "heightMM", "wallThicknessMM", "withWalls", "storeyID", "baseOffsetMM"]
    private let document: FloeCADDocument
    public init(document: FloeCADDocument) { self.document = document }

    public static func catalogObject() -> [String: Any] {
        ["actions": actions, "route": "cad.document action=parameters, payload is a JSON string with action=building.*",
         "units": "Plan [u,v] mm; CAD world [u,elevation,-v] mm",
         "mutationPins": ["expected_revision": "integer from fresh building.inspect", "expected_change_count": "integer from the SAME inspection", "expected_source_sha256": "optional exact saved content SHA from that inspection"],
         "floorSelection": "storeyID is optional only for a new building or one existing storey; multiple storeys require an actual ID from inspection",
         "addWall": ["required": ["name", "a:[u,v]", "b:[u,v]", "thicknessMM", "heightMM"], "optional": ["storeyID", "baseOffsetMM"], "shape": "straight wall centre line; native analytic box through setBuilding"],
         "addRoom": ["required": ["name", "min:[u,v]", "max:[u,v]", "heightMM", "wallThicknessMM", "withWalls:boolean"], "optional": ["storeyID", "baseOffsetMM"], "shape": "axis-aligned authored rectangular space; withWalls=true adds four native walls outside the clear rectangle, false creates space metadata only"],
         "inspection": "building.inspect accepts storeyOffset, elementOffset and limit (1...16, default 8); follows separate next offsets; no source file bytes are echoed",
         "persistence": "same native document, one Building undo transaction; require saved=true and actual revision/content_sha256 from the host receipt, then inspect/query",
         "limits": "existing Building validation: <=1000 elements, <=128 storeys; positive finite mm dimensions; wall length >0.1mm and <=1000000mm; thickness/height 1...100000mm",
         "unsupported": ["arbitrary room boundary inference", "automatic wall joining/door design", "enclosure or regulatory certification", "full BIM/IFC authoring"],
         "examples": [
            "wall": ["action": "building.addWall", "name": "Wall A", "a": [0, 0], "b": [4000, 0], "thicknessMM": 200, "heightMM": 3000, "expected_revision": 0, "expected_change_count": 0],
            "room": ["action": "building.addRoom", "name": "Room A", "min": [5000, 0], "max": [9000, 3000], "wallThicknessMM": 200, "heightMM": 3000, "withWalls": true, "expected_revision": 0, "expected_change_count": 0]],
         "examplePins": "Replace example zeros with fresh actual inspection pins; do not guess filenames or identities for a managed Space original."]
    }

    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        do {
            guard Self.actions.contains(action) else { throw Failure("unknown_building_action", "Use building.catalog, building.inspect, building.addWall or building.addRoom.") }
            if action == "building.catalog" {
                try keys(args, allowed: ["action", "revision", "expected_revision"])
                return ["ok": true, "mutated": false, "building": Self.catalogObject()]
            }
            guard !document.isClosed else { throw Failure("document_closed", "Reopen this CAD document.") }
            if action == "building.inspect" { return try inspection(args) }
            try pins(args)
            guard !document.isReadOnly, document.session.writeBlock == nil else { throw Failure("read_only", "This CAD document cannot be edited.") }
            let fields = action == "building.addWall" ? Self.wallFields : Self.roomFields
            try keys(args, allowed: Self.envelope.union(fields))
            let payload = try JSONSerialization.data(withJSONObject: args.filter { fields.contains($0.key) })
            var model = try document.building() ?? CADBuildingDocument(name: document.name)
            let created: [CADBuildingElement]
            if action == "building.addWall" {
                let input = try JSONDecoder().decode(CADBuildingWallInput.self, from: payload)
                let floor = try storey(input.storeyID, model: model)
                created = [CADBuildingElement(storeyID: floor.id, kind: .wall, name: input.name,
                    a: input.a, b: input.b, thicknessMM: input.thicknessMM, heightMM: input.heightMM,
                    baseOffsetMM: input.baseOffsetMM ?? 0)]
            } else {
                let input = try JSONDecoder().decode(CADBuildingRoomInput.self, from: payload)
                let floor = try storey(input.storeyID, model: model)
                guard input.min.count == 2, input.max.count == 2,
                      (input.min + input.max).allSatisfy(\.isFinite),
                      input.max[0] > input.min[0] + 0.1, input.max[1] > input.min[1] + 0.1 else {
                    throw Failure("invalid_room", "Use finite min:[u,v], max:[u,v] with both max coordinates larger than min, in millimetres.")
                }
                let space = CADBuildingElement(storeyID: floor.id, kind: .space, name: input.name,
                    a: input.min, b: input.max, thicknessMM: input.wallThicknessMM, heightMM: input.heightMM,
                    baseOffsetMM: input.baseOffsetMM ?? 0)
                var elements = [space]
                if input.withWalls {
                    let h = input.wallThicknessMM / 2
                    let u0 = input.min[0] - h, u1 = input.max[0] + h
                    let v0 = input.min[1] - h, v1 = input.max[1] + h
                    let lines = [([u0, v0], [u1, v0]), ([u1, v0], [u1, v1]), ([u1, v1], [u0, v1]), ([u0, v1], [u0, v0])]
                    for (index, line) in lines.enumerated() {
                        elements.append(CADBuildingElement(storeyID: floor.id, kind: .wall, name: "\(input.name) · \(index + 1)",
                            a: line.0, b: line.1, thicknessMM: input.wallThicknessMM, heightMM: input.heightMM,
                            baseOffsetMM: input.baseOffsetMM ?? 0))
                    }
                }
                created = elements
            }
            guard created.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw Failure("invalid_name", "Use a nonempty wall or room name.")
            }
            model.elements += created
            _ = try document.setBuilding(model, expectedChangeCount: document.buildingChangeCount)
            var reply = identity()
            reply["ok"] = true; reply["mutated"] = true
            reply["buildingID"] = model.id.uuidString
            reply["createdElements"] = try created.map(describe)
            reply["createdElementIDs"] = created.map { $0.id.uuidString }
            reply["createdBodyIDs"] = created.flatMap(\.bodyIDs).map(\.uuidString)
            reply["roomSemantics"] = "Authored rectangular space; optional four explicit walls. No enclosure inference, automatic joining or compliance certification."
            return reply
        } catch let failure as Failure { return ["ok": false, "mutated": false, "error": failure.code, "message": failure.message] }
        catch let error as DecodingError {
            let path: [any CodingKey], message: String
            switch error {
            case .keyNotFound(let key, let context): path = context.codingPath + [key]; message = "required field is missing"
            case .typeMismatch(let type, let context): path = context.codingPath; message = "expected \(type)"
            case .valueNotFound(let type, let context): path = context.codingPath; message = "expected non-null \(type)"
            case .dataCorrupted(let context): path = context.codingPath; message = context.debugDescription
            @unknown default: path = []; message = "invalid typed input"
            }
            return ["ok": false, "mutated": false, "error": "invalid_building_input", "message": "Building field \(path.map(\.stringValue).joined(separator: ".")): \(message). See building.catalog."]
        }
        catch { return ["ok": false, "mutated": false, "error": "invalid_building", "message": error.localizedDescription] }
    }

    private struct Failure: Error { let code: String; let message: String; init(_ code: String, _ message: String) { self.code = code; self.message = message } }
    private func keys(_ args: [String: Any], allowed: Set<String>) throws {
        let unknown = Set(args.keys).subtracting(allowed)
        guard unknown.isEmpty else { throw Failure("unknown_building_field", "Unsupported building fields: " + unknown.sorted().joined(separator: ", ")) }
    }
    private func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return Int(exactly: n.doubleValue)
    }
    private func pins(_ args: [String: Any]) throws {
        guard let revision = integer(args["expected_revision"]), let count = integer(args["expected_change_count"]) else {
            throw Failure("missing_building_pins", "First call building.inspect, then send its integer expected_revision and expected_change_count.")
        }
        guard revision == document.revision, count == document.buildingChangeCount else {
            throw Failure("stale_building", "The CAD document changed. Inspect the same document again before editing its building.")
        }
        if let hash = args["expected_source_sha256"] {
            guard let hash = hash as? String, hash == document.contentSHA256 else {
                throw Failure("stale_building", "The saved source changed. Inspect this document again.")
            }
        }
    }
    private func storey(_ id: UUID?, model: CADBuildingDocument) throws -> CADBuildingStorey {
        if let id, let floor = model.storeys.first(where: { $0.id == id }) { return floor }
        if id == nil, model.storeys.count == 1 { return model.storeys[0] }
        throw Failure("invalid_storey", "Use an actual storeyID from building.inspect; multiple floors need an explicit selection.")
    }
    private func identity() -> [String: Any] {
        ["revision": document.revision, "content_sha256": document.contentSHA256,
         "change_count": document.buildingChangeCount, "hasUnsavedChanges": document.hasUnsavedChanges]
    }
    private func describe(_ element: CADBuildingElement) throws -> [String: Any] {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard var row = try JSONSerialization.jsonObject(with: encoder.encode(element)) as? [String: Any] else {
            throw Failure("building_encoding_failed", "The existing building element could not be inspected.")
        }
        row["bodyIDs"] = element.bodyIDs.map(\.uuidString)
        let represented = Set(document.session.document.bodies.map { $0.id.raw })
        row["representedBodyCount"] = element.bodyIDs.filter { represented.contains($0) }.count
        row["representation"] = element.kind == .space ? "semanticSpace" : "nativeModelGeometry"
        if element.kind == .space { row["authoredAreaM2"] = element.areaM2 }
        return row
    }
    private func inspection(_ args: [String: Any]) throws -> [String: Any] {
        try keys(args, allowed: Self.envelope.union(["storeyOffset", "elementOffset", "limit"]))
        if args["expected_change_count"] != nil || args["expected_source_sha256"] != nil { try pins(args) }
        func pageInteger(_ key: String, fallback: Int) throws -> Int {
            guard let raw = args[key] else { return fallback }
            guard let value = integer(raw), value >= 0 else { throw Failure("invalid_page", "Use nonnegative integer building page offsets and limit 1...16.") }
            return value
        }
        let floorOffset = try pageInteger("storeyOffset", fallback: 0), elementOffset = try pageInteger("elementOffset", fallback: 0)
        let limit = try pageInteger("limit", fallback: 8)
        guard (1...16).contains(limit) else { throw Failure("invalid_page", "Building inspection limit must be 1...16.") }
        var reply = identity(); reply["ok"] = true; reply["mutated"] = false
        guard let model = try document.building() else {
            reply["hasBuilding"] = false; reply["storeys"] = [] as [Any]; reply["elements"] = [] as [Any]; reply["storeyCount"] = 0; reply["elementCount"] = 0
            return reply
        }
        reply["hasBuilding"] = true; reply["buildingID"] = model.id.uuidString; reply["name"] = model.name
        reply["storeyCount"] = model.storeys.count; reply["elementCount"] = model.elements.count
        reply["storeys"] = model.storeys.dropFirst(floorOffset).prefix(limit).map { ["id": $0.id.uuidString, "name": $0.name, "elevationMM": $0.elevationMM, "heightMM": $0.heightMM] as [String: Any] }
        reply["elements"] = try model.elements.dropFirst(elementOffset).prefix(limit).map(describe)
        if floorOffset < model.storeys.count - limit { reply["nextStoreyOffset"] = floorOffset + limit }
        if elementOffset < model.elements.count - limit { reply["nextElementOffset"] = elementOffset + limit }
        reply["roomSemantics"] = "A space is authored plan metadata, not a synthetic solid or proof of enclosure/compliance. Query its explicit wall body IDs for actual geometry."
        return reply
    }
}
