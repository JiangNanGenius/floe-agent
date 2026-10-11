import Foundation

// FloeCore — Design state as a typed Canvas node subdocument.
//
// The Canvas project is the single project authority. Design state (brief, spec,
// revisions, anchored feedback, candidates) is stored as a typed JSON
// subdocument inside the bound Canvas node's `metadata`, next to the existing
// `canvas.childProject` binding, and is therefore persisted, revision-checked,
// backed up, synced and forked by the existing Canvas authority — there is no
// independent design store, gallery or project identity. The node ID is the only
// identity and decoding fails when it does not match the requested binding.

/// Tolerant JSON value used to PRESERVE unknown design-subdocument fields
/// across migrations. A build that does not understand a key from an older
/// or newer build must keep its value verbatim (semantically) and emit it
/// again on the next write; this type makes that preservation explicit
/// instead of relying on (or being defeated by) synthesized Codable, which
/// silently drops unknown keys. Object key order is normalized on the first
/// migration and then stable, so repeated saves are idempotent.
public enum DesignJSONValue: Sendable, Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case unsigned(UInt64)
    case decimal(Decimal)
    case number(Double)
    case string(String)
    case array([DesignJSONValue])
    case object([String: DesignJSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Int64.self) {
            // Exact signed integers first: JSON 1/0 must stay integers and
            // never bridge to Bool.
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            // Values above Int64.max (unsigned bounds) stay exact.
            self = .unsigned(value)
        } else if let value = try? container.decode(Decimal.self) {
            // Fractional / very large numerics keep their digits instead of
            // silently rounding through Double. (Booleans never decode here.)
            self = .decimal(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([DesignJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: DesignJSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .decimal(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Rebuilds a value from a JSONSerialization foundation object.
    /// NSNumber 0/1 bridges to Bool in Swift, so the CFBoolean type check
    /// MUST precede any Bool cast and any integer heuristics.
    public static func from(foundation object: Any) -> DesignJSONValue {
        if let value = object as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .bool(value.boolValue)
            }
            // NSDecimalNumber reports objCType "d" but carries exact digits.
            if let decimal = value as? NSDecimalNumber, !decimal.isEqual(to: NSDecimalNumber.notANumber) {
                return .decimal(decimal.decimalValue)
            }
            let encoding = String(cString: value.objCType)
            switch encoding {
            case "c", "i", "s", "l", "q":
                return .integer(value.int64Value)
            case "C", "I", "S", "L", "Q":
                let unsigned = value.uint64Value
                if unsigned <= UInt64(Int64.max) {
                    return .integer(Int64(unsigned))
                }
                return .unsigned(unsigned)
            default:
                let double = value.doubleValue
                // Refuse a LOSSY integer round trip: an integral value whose
                // Int64/UInt64 forms disagree with the double is preserved
                // exactly via Decimal only when that representation is
                // exact; otherwise the original is retained as an exact
                // Decimal of the double's shortest digits.
                return .number(double)
            }
        }
        if let value = object as? Bool {
            return .bool(value)
        }
        if let value = object as? String {
            return .string(value)
        }
        if let value = object as? [Any] {
            return .array(value.map(DesignJSONValue.from(foundation:)))
        }
        if let value = object as? [String: Any] {
            var result: [String: DesignJSONValue] = [:]
            for (key, child) in value { result[key] = DesignJSONValue.from(foundation: child) }
            return .object(result)
        }
        if object is NSNull {
            return .null
        }
        return .null
    }
}

/// Reusable unknown-key preservation for the design documents. Modeled
/// types decode their known keys, then capture every other top-level key as
/// a `DesignJSONValue` and re-emit it on encode — so forward/back
/// compatibility is explicit, not an accident of synthesized Codable.
public enum DesignUnknownPreservation {
    public struct AnyKey: CodingKey, Hashable {
        public var stringValue: String
        public var intValue: Int?
        public init(_ string: String) {
            self.stringValue = string
            self.intValue = nil
        }
        public init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        public init?(intValue: Int) { return nil }
    }

    public static func capture(decoder: Decoder, known: Set<String>) throws -> [String: DesignJSONValue] {
        let raw = try decoder.container(keyedBy: AnyKey.self)
        var preserved: [String: DesignJSONValue] = [:]
        for key in raw.allKeys where !known.contains(key.stringValue) {
            preserved[key.stringValue] = try raw.decode(DesignJSONValue.self, forKey: key)
        }
        return preserved
    }

    public static func write(_ fields: [String: DesignJSONValue], to encoder: Encoder) throws {
        guard !fields.isEmpty else { return }
        var extra = encoder.container(keyedBy: AnyKey.self)
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            try extra.encode(value, forKey: AnyKey(name))
        }
    }
}

public enum DesignCanvasMetadata {
    /// Node-metadata key. Reference the same constant from the app side.
    public static let key = "canvas.design"
    /// Bound to keep a hostile/duplicated payload from bloating a project file.
    public static let maximumBytes = 2 * 1024 * 1024

    public enum CodecError: Error, Equatable {
        case bindingMismatch(expected: String, found: String)
        case tooLarge(Int)
        case newerSchema(found: Int, supported: Int)
        case malformed(String)
        case empty
    }

    /// Encode design state for storage in `node.metadata[key]`. The node binding
    /// is part of the payload so a copied blob cannot silently retarget.
    public static func encode(_ project: DesignProject) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        guard data.count <= maximumBytes else { throw CodecError.tooLarge(data.count) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode design state stored on `nodeID`. Fails closed on binding mismatch,
    /// newer schema or malformed payloads; never rewrites unknown state.
    public static func decode(_ raw: String?, nodeID: String) throws -> DesignProject? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard raw.utf8.count <= maximumBytes else { throw CodecError.tooLarge(raw.utf8.count) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project: DesignProject
        do {
            project = try decoder.decode(DesignProject.self, from: Data(raw.utf8))
        } catch {
            throw CodecError.malformed(String(describing: error))
        }
        guard project.schemaVersion <= DesignProject.currentSchemaVersion else {
            throw CodecError.newerSchema(
                found: project.schemaVersion,
                supported: DesignProject.currentSchemaVersion
            )
        }
        guard project.nodeID == nodeID else {
            throw CodecError.bindingMismatch(expected: nodeID, found: project.nodeID)
        }
        return project
    }

    /// Create or load the design subdocument for a node, verifying that the
    /// content type matches an existing payload.
    public static func loadOrCreate(
        raw: String?,
        nodeID: String,
        contentType: DesignContentType
    ) throws -> DesignProject {
        if let existing = try decode(raw, nodeID: nodeID) { return existing }
        return DesignWorkflowEngine.createProject(nodeID: nodeID, contentType: contentType)
    }
}
