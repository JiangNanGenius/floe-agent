import Foundation

public enum ChemistryError: Error, LocalizedError, Equatable, Sendable {
    case invalid(String), conflict(expected: UInt64, actual: UInt64), unavailable(String), corrupt(String), cancelled
    case requiresPrepared3DStructure
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .unavailable(let s), .corrupt(let s): s
        case .conflict(let expected, let actual): "Project changed: expected revision \(expected), found \(actual)."
        case .cancelled: "Cancelled."
        case .requiresPrepared3DStructure:
            Locale.current.language.languageCode?.identifier == "zh"
                ? "此结构尚未准备可用于计算的三维坐标。请先生成含显式氢的三维结构并应用结果，再运行力场计算。"
                : "This structure has no prepared 3D coordinates. Generate a 3D structure with explicit hydrogens and apply the result before running a force-field calculation."
        }
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> JSONValue? { if case .object(let v) = self { v[key] } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var number: Double? { if case .number(let v) = self { v } else { nil } }
    public var array: [JSONValue]? { if case .array(let v) = self { v } else { nil } }
}

public enum ChemicalKind: String, Codable, CaseIterable, Sendable {
    case molecule, crystal, biomolecule, reaction, spectrum, trajectory, note
}

public struct ChemicalObject: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var kind: ChemicalKind
    public var format: String
    public var source: String
    public var revision: UInt64
    public var facts: JSONValue?
    public var originalFormat: String?
    public var originalSource: String?
    /// Lossless drawing data, including stereochemistry, reaction arrows and annotations.
    public var sketchDocument: String?
    public var sketchSMILES: String?
    /// Connectivity can be valid without spatial coordinates (for example a
    /// freshly parsed SMILES). Viewing that graph does not prepare a force field.
    public var requires3DPreparation: Bool {
        if sketchDocument != nil || facts?["geometryDimension"]?.number == 2 { return true }
        if ["mol", "sdf", "sd"].contains(format.lowercased()),
           let generator = source.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).dropFirst().first,
           generator.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("2D") { return true }
        guard facts?["coordinateSetCount"]?.number == 0 else { return false }
        // Avogadro counts stored conformer/trajectory sets separately from
        // the current atom positions. A static XYZ/PDB/CJSON can have zero
        // sets and still contain valid 3D positions, including planar ones.
        guard let encoded = facts?["cjson"]?.string, encoded.utf8.count <= 16 * 1024 * 1024,
              let molecule = try? JSONDecoder().decode(JSONValue.self, from: Data(encoded.utf8)),
              let elements = molecule["atoms"]?["elements"]?["number"]?.array,
              !elements.isEmpty, elements.count <= 100_000,
              let coordinates = molecule["atoms"]?["coords"]?["3d"]?.array,
              coordinates.count == elements.count * 3 else { return true }
        return !coordinates.allSatisfy { $0.number?.isFinite == true }
    }
    public init(id: UUID = UUID(), title: String, kind: ChemicalKind = .molecule,
                format: String, source: String, revision: UInt64 = 0, facts: JSONValue? = nil) {
        self.id = id; self.title = title; self.kind = kind; self.format = format
        self.source = source; self.revision = revision; self.facts = facts
    }
}

public struct ChemistryBlock: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID = UUID()
    public var text: String
    public var objectID: UUID?
    public var runID: UUID?
    public init(text: String = "", objectID: UUID? = nil, runID: UUID? = nil) {
        self.text = text; self.objectID = objectID; self.runID = runID
    }
}

public struct ChemistryDrawingRecovery: Codable, Identifiable, Sendable {
    public var id = UUID()
    public var projectID: UUID
    public var createdAt = Date()
    public var object: ChemicalObject
    public init(projectID: UUID, object: ChemicalObject) { self.projectID = projectID; self.object = object }
}

public enum ChemistryRunStatus: String, Codable, Sendable { case queued, running, succeeded, failed, cancelled, interrupted }
public struct ChemistryRun: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID = UUID()
    public var input: ChemicalObject
    public var inputDigest: String
    public var method: String
    public var options: JSONValue
    public var environmentID: String
    public var engineVersion: String
    public var status: ChemistryRunStatus = .queued
    public var createdAt: Date = Date()
    public var finishedAt: Date?
    public var result: JSONValue?
    public var error: String?
    public var externalExecution: ChemistryExternalExecution?
    public init(input: ChemicalObject, inputDigest: String, method: String, options: JSONValue,
                environmentID: String, engineVersion: String) {
        self.input = input; self.inputDigest = inputDigest; self.method = method; self.options = options
        self.environmentID = environmentID; self.engineVersion = engineVersion
    }
}

public struct ChemistryProject: Codable, Identifiable, Sendable, Equatable {
    public var schemaVersion: Int = 1
    public var id: UUID
    public var title: String
    public var revision: UInt64 = 0
    public var modifiedAt: Date = Date()
    public var defaultEnvironmentID: String = "native.local"
    public var objects: [ChemicalObject] = []
    public var blocks: [ChemistryBlock] = []
    public var runs: [ChemistryRun] = []
    public init(id: UUID = UUID(), title: String) { self.id = id; self.title = title }

    public func validate() throws {
        guard schemaVersion == 1, !title.isEmpty, title.utf8.count <= 4096,
              objects.count <= 4096, blocks.count <= 16384, runs.count <= 16384,
              Set(objects.map(\.id)).count == objects.count,
              Set(blocks.map(\.id)).count == blocks.count,
              Set(runs.map(\.id)).count == runs.count else { throw ChemistryError.invalid("Invalid project structure.") }
        let ids = Set(objects.map(\.id)), runIDs = Set(runs.map(\.id))
        for object in objects {
            guard object.source.utf8.count <= 16 * 1024 * 1024, object.title.utf8.count <= 4096,
                  (object.sketchDocument?.utf8.count ?? 0) <= 16 * 1024 * 1024,
                  (object.sketchSMILES?.utf8.count ?? 0) <= 1024 * 1024,
                  !object.format.isEmpty, object.format.utf8.count <= 64 else { throw ChemistryError.invalid("Object exceeds input limits.") }
        }
        for block in blocks {
            guard block.objectID.map(ids.contains) ?? true, block.runID.map(runIDs.contains) ?? true,
                  block.text.utf8.count <= 1024 * 1024 else { throw ChemistryError.invalid("Invalid document reference.") }
        }
        for run in runs {
            if let execution = run.externalExecution {
                let identity = execution.identity
                guard identity.projectID == id, identity.runID == run.id,
                      identity.objectID == run.input.id, identity.objectRevision == run.input.revision,
                      identity.inputDigest == run.inputDigest, identity.environmentID == run.environmentID,
                      !identity.environmentID.isEmpty, identity.environmentID.utf8.count <= 4096,
                      execution.requestJSON.utf8.count <= 16 * 1024 * 1024,
                      execution.requestDigest == ChemistryProjectStore.digest(Data(execution.requestJSON.utf8)) else {
                    throw ChemistryError.corrupt("External calculation identity does not match its saved input.")
                }
            }
        }
    }
}
