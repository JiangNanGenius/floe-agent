// SPDX-License-Identifier: MPL-2.0
// Building semantics share the CAD document's geometry, undo and atomic store.
// Plan coordinates are [u,v] millimetres. CAD world is [u,elevation,-v]; IFC
// world is [u,v,elevation] metres. No drawing units are guessed.
import Foundation
import CryptoKit

public nonisolated struct CADBuildingStorey: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public var elevationMM: Double
    public var heightMM: Double
    public init(name: String, elevationMM: Double = 0, heightMM: Double = 3000) {
        self.name = name; self.elevationMM = elevationMM; self.heightMM = heightMM
    }
}

public nonisolated struct CADBuildingElement: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case wall, slab, roof, stair, column, beam, door, window, space, pipe, duct
    }
    public var id: UUID = UUID()
    public var storeyID: UUID
    public var kind: Kind
    public var name: String
    /// Walls/beams/pipes/ducts/stairs use a centre line; slabs/roofs/spaces
    /// use opposite rectangle corners. All are editable authored geometry.
    public var a: [Double]
    public var b: [Double]
    public var thicknessMM: Double
    public var heightMM: Double
    public var baseOffsetMM: Double
    /// Door/window host and distance of the opening's START along its wall.
    public var hostID: UUID?
    public var offsetMM: Double?
    public var widthMM: Double?
    public var sourceHandle: String?
    public var stepCount: Int?

    public init(storeyID: UUID, kind: Kind, name: String, a: [Double], b: [Double],
                thicknessMM: Double = 200, heightMM: Double = 3000,
                baseOffsetMM: Double = 0, hostID: UUID? = nil,
                offsetMM: Double? = nil, widthMM: Double? = nil, stepCount: Int? = nil) {
        self.storeyID = storeyID; self.kind = kind; self.name = name
        self.a = a; self.b = b; self.thicknessMM = thicknessMM
        self.heightMM = heightMM; self.baseOffsetMM = baseOffsetMM
        self.hostID = hostID; self.offsetMM = offsetMM; self.widthMM = widthMM
        self.stepCount = stepCount
    }
    public var lengthMM: Double { a.count == 2 && b.count == 2 ? hypot(b[0] - a[0], b[1] - a[1]) : .nan }
    public var areaM2: Double { a.count == 2 && b.count == 2 ? abs((b[0]-a[0]) * (b[1]-a[1])) / 1_000_000 : .nan }
    public var bodyID: UUID { CADBuildingIdentity.uuid(id, "body") }
    public var bodyIDs: [UUID] {
        if kind == .space { return [] }
        guard kind == .stair else { return [bodyID] }
        return (0..<max(2,min(64,stepCount ?? 12))).map { $0 == 0 ? bodyID : CADBuildingIdentity.uuid(id,"step-body-\($0)") }
    }
}

public nonisolated struct CADBuildingJurisdiction: Codable, Equatable, Sendable {
    public var country: String
    public var subdivision: String
    public var buildingUse: String
    public var edition: String
    public init(country: String = "AU", subdivision: String = "", buildingUse: String = "", edition: String = "") {
        self.country = country; self.subdivision = subdivision; self.buildingUse = buildingUse; self.edition = edition
    }
}

/// Explicit project rules supplied with a clause/source. These are measurable
/// checks, never an assertion that every law in a country has been evaluated.
public nonisolated struct CADBuildingRule: Codable, Equatable, Identifiable, Sendable {
    public enum Metric: String, Codable, CaseIterable, Sendable { case doorWidth, stairWidth, storeyHeight, spaceArea }
    public var id: UUID = UUID()
    public var metric: Metric
    public var minimum: Double
    public var clause: String
    public var sourceURL: String
    public init(metric: Metric, minimum: Double, clause: String, sourceURL: String) {
        self.metric = metric; self.minimum = minimum; self.clause = clause; self.sourceURL = sourceURL
    }
}

public nonisolated struct CADBuildingDocument: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var id: UUID = UUID()
    public var name: String
    public var storeys: [CADBuildingStorey]
    public var elements: [CADBuildingElement] = []
    public var sources: [CADSketchTransferEnvelope] = []
    public var jurisdiction = CADBuildingJurisdiction()
    public var rules: [CADBuildingRule] = []
    public init(name: String = FloeCADStrings.text("cad.building.defaultName","Building")) {
        self.name = name
        storeys = [CADBuildingStorey(name: FloeCADStrings.text("cad.building.groundFloor","Ground floor"))]
    }
    public static func decode(_ data: Data?) throws -> Self? {
        guard let data else { return nil }
        guard data.count <= 32 * 1024 * 1024 else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.theBuildingDocumentIsTooLarge","The building document is too large.")) }
        let raw = try JSONSerialization.jsonObject(with: data)
        try validateStoredJSONObject(raw)
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate(); return value
    }
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 32 * 1024 * 1024 else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.theBuildingDocumentIsTooLarge","The building document is too large.")) }
        return data
    }
    public func validate() throws {
        func validText(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= 1024 }
        guard schemaVersion == 1, validText(name), (1...128).contains(storeys.count), elements.count <= 1000,
              sources.count <= 8, rules.count <= 256,
              Set(storeys.map(\.id)).count == storeys.count,
              Set(elements.map(\.id)).count == elements.count else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.unsupportedOrInvalidBuildingRecords","Unsupported or invalid building records.")) }
        let floorIDs = Set(storeys.map(\.id))
        for floor in storeys {
            guard validText(floor.name), floor.elevationMM.isFinite, abs(floor.elevationMM) <= 10_000_000,
                  floor.heightMM.isFinite, (100...100_000).contains(floor.heightMM) else {
                throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.useAValidFloorElevationAndHeight","Use a valid floor elevation and height in millimetres."))
            }
        }
        for element in elements {
            guard floorIDs.contains(element.storeyID), validText(element.name),
                  element.a.count == 2, element.b.count == 2,
                  (element.a + element.b).allSatisfy({ $0.isFinite && abs($0) <= 10_000_000 }),
                  element.lengthMM > 0.1, element.lengthMM <= 1_000_000,
                  element.thicknessMM.isFinite, (1...100_000).contains(element.thicknessMM),
                  element.heightMM.isFinite, (1...100_000).contains(element.heightMM),
                  element.baseOffsetMM.isFinite, abs(element.baseOffsetMM) <= 100_000,
                  (element.sourceHandle?.utf8.count ?? 0) <= 128 else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.useFinitePositiveBuildingDimensionsInMillimetres","Use finite, positive building dimensions in millimetres.")) }
            if [.slab, .roof, .space].contains(element.kind) {
                guard abs(element.b[0]-element.a[0]) > 0.1, abs(element.b[1]-element.a[1]) > 0.1 else {
                    throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.aFloorRoofOrSpaceNeedsTwo","A floor, roof or space needs two opposite rectangle corners."))
                }
            }
            if element.kind == .stair, !(2...64).contains(element.stepCount ?? 12) {
                throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.use264StairSteps","Use 2–64 stair steps."))
            }
            if [.door, .window].contains(element.kind) {
                guard let hostID = element.hostID, let wall = elements.first(where: { $0.id == hostID && $0.kind == .wall }),
                      wall.storeyID == element.storeyID, let offset = element.offsetMM, offset.isFinite, offset >= 0,
                      let width = element.widthMM, width.isFinite, width > 1,
                      offset + width <= wall.lengthMM, element.baseOffsetMM >= 0,
                      element.baseOffsetMM + element.heightMM <= wall.heightMM else {
                    throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.placeEachDoorOrWindowInsideA","Place each door or window inside a wall on the same floor."))
                }
            } else if element.hostID != nil || element.offsetMM != nil || element.widthMM != nil {
                throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.onlyDoorsAndWindowsMayReferenceA","Only doors and windows may reference a wall opening."))
            }
        }
        for source in sources { try source.validate() }
        guard sources.reduce(0, { $0 + $1.sourceBytes.count }) <= 20 * 1024 * 1024,
              [jurisdiction.country, jurisdiction.subdivision, jurisdiction.buildingUse, jurisdiction.edition].allSatisfy({ $0.utf8.count <= 1024 }) else {
            throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.buildingSourceOrJurisdictionDataExceedsIts","Building source or jurisdiction data exceeds its budget."))
        }
        for rule in rules {
            guard rule.minimum.isFinite, rule.minimum > 0, validText(rule.clause),
                  let url = URL(string: rule.sourceURL), url.scheme == "https", url.host != nil else {
                throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.aProjectRuleNeedsAPositiveLimit","A project rule needs a positive limit, clause and HTTPS source."))
            }
        }
    }
    /// Unknown nested keys are not lost to Codable's permissive decoder.
    static func validateStoredJSONObject(_ raw: Any) throws {
        func object(_ value: Any, _ keys: Set<String>) throws -> [String: Any] {
            guard let row = value as? [String: Any], Set(row.keys).isSubset(of: keys) else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.thisBuildingContainsNewerOrInvalidRecords","This building contains newer or invalid records.")) }; return row
        }
        let root = try object(raw, ["schemaVersion","id","name","storeys","elements","sources","jurisdiction","rules"])
        guard root["schemaVersion"] as? Int == 1 else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.thisBuildingUsesANewerFormat","This building uses a newer format.")) }
        for row in root["storeys"] as? [Any] ?? [] { _ = try object(row, ["id","name","elevationMM","heightMM"]) }
        for row in root["elements"] as? [Any] ?? [] { _ = try object(row, ["id","storeyID","kind","name","a","b","thicknessMM","heightMM","baseOffsetMM","hostID","offsetMM","widthMM","sourceHandle","stepCount"]) }
        for row in root["sources"] as? [Any] ?? [] { try CADSketchTransferEnvelope.validateStoredJSONObject(row) }
        if let row = root["jurisdiction"] { _ = try object(row, ["country","subdivision","buildingUse","edition"]) }
        for row in root["rules"] as? [Any] ?? [] { _ = try object(row, ["id","metric","minimum","clause","sourceURL"]) }
    }
}

public nonisolated enum CADBuildingError: Error, LocalizedError, Sendable {
    case invalid(String)
    public var errorDescription: String? { switch self { case let .invalid(text): return text } }
}

nonisolated enum CADBuildingIdentity {
    static func uuid(_ owner: UUID, _ role: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("floe.building.\(owner.uuidString).\(role)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}

struct SetBuildingDataCommand: DocumentCommand {
    let title = "Building"
    let before: Data?
    let after: Data?
    func apply(to document: inout DesignDocument) { document.buildingData = after }
    func revert(in document: inout DesignDocument) { document.buildingData = before }
}
