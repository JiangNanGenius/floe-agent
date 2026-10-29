// SPDX-License-Identifier: MPL-2.0
//
// G06 Notes native service — bounded wire support.
//
// The channel is deliberately separate from the frozen command-envelope
// versions: BridgeV4 carries a closed Notes action vocabulary, not task/run/
// provider authority. Requests stay inside the same 64 KiB JSON bound as the
// existing bridge; responses are bounded more generously because a validated
// note document can legitimately contain many pages/elements, but binary
// resources and archives always travel in explicit chunks.
import Foundation
import Crypto
import FloeCore
import FloeNotes

enum NotesDomainError: Error, Equatable, Sendable {
    case notBound
    case staleGeneration
    case unsupportedAction(String)
    case invalidPayload(String)
    case requestTooLarge
    case responseTooLarge
    case stageNotFound
    case stageExpired
    case storageUnavailable
    case busy
}

/// Strict JSON union. Foundation's `as? Bool`/`as? Int` bridging is not
/// trustworthy across the Android Foundation overlay; decoding through a
/// typed union keeps JSON booleans distinct from numbers and never coerces.
indirect enum NotesJSONValue: Codable, Sendable {
    case object([String: NotesJSONValue])
    case array([NotesJSONValue])
    case string(String)
    case integer(Int)
    case fractional(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .fractional(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([NotesJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: NotesJSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "unsupportedJSONValue")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .fractional(let value): try container.encode(value)
        case .boolean(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var objectValue: [String: NotesJSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var arrayValue: [NotesJSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var intValue: Int? {
        switch self {
        case .integer(let value): return value
        case .fractional(let value) where value.rounded() == value
            && value >= Double(Int.min) && value <= Double(Int.max):
            return Int(value)
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .fractional(let value): return value
        default: return nil
        }
    }

    var boolValue: Bool? {
        guard case .boolean(let value) = self else { return nil }
        return value
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

enum NotesWire {
    /// Same strict request bound as every existing bridge version.
    static let maximumRequestBytes = 65_536
    /// A validated document can be large (pages/elements/mind-map nodes).
    /// Binary payloads never use this bound; they use explicit chunks.
    static let maximumResponseBytes = 16_777_216
    /// base64 of 44,000 bytes is 58,668 chars, leaving room for the JSON
    /// envelope inside the 64 KiB request bound.
    static let maximumChunkBytes = 44_000
    static let defaultReadBytes = 262_144
    static let maximumReadBytes = 1_048_576
    static let maximumResourceBytes: Int64 = 536_870_912
    static let maximumArchiveBytes: Int64 = 2_147_483_648
    static let maximumEdits = 10_000

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder().decode(type, from: data)
    }

    static func data(from value: NotesJSONValue) throws -> Data {
        try encode(value)
    }

    static func data(from object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":"internal","reason":"encoding"}"#.utf8)
    }

    static func errorData(code: String, reason: String?, retryable: Bool,
                          extra: [String: Any] = [:]) -> Data {
        var object: [String: Any] = ["ok": false, "error": code, "retryable": retryable]
        if let reason, !reason.isEmpty { object["reason"] = bounded(reason) }
        for (key, value) in extra where key != "ok" && key != "error"
            && key != "reason" && key != "retryable" {
            object[key] = value
        }
        return data(from: object)
    }

    static func mappedError(_ error: Error) -> (code: String, reason: String?,
                                                retryable: Bool, extra: [String: Any]) {
        if let error = error as? NotesDomainError {
            switch error {
            case .notBound:
                return ("notesNotBound", "bindRequired", true, [:])
            case .staleGeneration:
                return ("staleGeneration", "rebindRequired", true, [:])
            case .unsupportedAction(let action):
                return ("unsupportedAction", bounded(action), false, [:])
            case .invalidPayload(let reason):
                return ("invalidPayload", bounded(reason), false, [:])
            case .requestTooLarge:
                return ("requestTooLarge", nil, false, [:])
            case .responseTooLarge:
                return ("responseTooLarge", nil, false, [:])
            case .stageNotFound:
                return ("stageNotFound", nil, false, [:])
            case .stageExpired:
                return ("stageExpired", nil, false, [:])
            case .storageUnavailable:
                return ("storageUnavailable", nil, true, [:])
            case .busy:
                return ("busy", nil, true, [:])
            }
        }
        if let error = error as? NoteError {
            switch error {
            case .notFound:
                return ("notFound", nil, false, [:])
            case .conflict:
                return ("conflict", "revisionOrSourceChanged", true, [:])
            case .invalidDocument(let reason):
                return ("invalidDocument", bounded(reason), false, [:])
            case .invalidOperation(let reason):
                return ("invalidOperation", bounded(reason), false, [:])
            case .resourceUnavailable:
                return ("resourceUnavailable", nil, false, [:])
            case .storageUnavailable(_):
                // Never echo an underlying path/errno string across the wire.
                return ("storageUnavailable", nil, true, [:])
            }
        }
        if error is DecodingError {
            return ("invalidPayload", "decodeFailed", false, [:])
        }
        return ("internal", "unexpectedFailure", false, [:])
    }

    static func bounded(_ value: String, limit: Int = 512) -> String {
        let scalars = value.unicodeScalars
        guard scalars.count > limit else { return value }
        var result = String.UnicodeScalarView()
        for scalar in scalars.prefix(limit) { result.append(scalar) }
        return String(result)
    }
}

/// Typed access to one action payload object. Missing and explicitly-null
/// values stay distinguishable where the action semantics require it.
struct NotesPayload {
    let object: [String: NotesJSONValue]

    init(_ value: NotesJSONValue?) throws {
        guard let value, !value.isNull else { object = [:]; return }
        guard case .object(let object) = value else {
            throw NotesDomainError.invalidPayload("payloadNotObject")
        }
        self.object = object
    }

    func has(_ key: String) -> Bool { object[key] != nil }

    func raw(_ key: String) -> NotesJSONValue? { object[key] }

    func string(_ key: String) throws -> String {
        guard let value = object[key]?.stringValue, !value.isEmpty else {
            throw NotesDomainError.invalidPayload("missingOrInvalid:\(key)")
        }
        return value
    }

    func stringOrNil(_ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        switch value {
        case .null: return nil
        case .string(let string): return string
        default: throw NotesDomainError.invalidPayload("invalidString:\(key)")
        }
    }

    func int(_ key: String) throws -> Int {
        guard let value = object[key]?.intValue else {
            throw NotesDomainError.invalidPayload("missingOrInvalid:\(key)")
        }
        return value
    }

    func intOrNil(_ key: String) throws -> Int? {
        guard let value = object[key], !value.isNull else { return nil }
        guard let int = value.intValue else {
            throw NotesDomainError.invalidPayload("invalidInteger:\(key)")
        }
        return int
    }

    func uint64(_ key: String) throws -> UInt64 {
        let value = try int64(key)
        guard value > 0 else { throw NotesDomainError.invalidPayload("invalidIdentity:\(key)") }
        return UInt64(value)
    }

    func int64(_ key: String) throws -> Int64 {
        guard let value = object[key], let number = value.intValue else {
            throw NotesDomainError.invalidPayload("missingOrInvalid:\(key)")
        }
        return Int64(number)
    }

    func double(_ key: String) throws -> Double {
        guard let value = object[key]?.doubleValue else {
            throw NotesDomainError.invalidPayload("missingOrInvalid:\(key)")
        }
        return value
    }

    func doubleOrNil(_ key: String) throws -> Double? {
        guard let value = object[key], !value.isNull else { return nil }
        guard let double = value.doubleValue else {
            throw NotesDomainError.invalidPayload("invalidNumber:\(key)")
        }
        return double
    }

    func bool(_ key: String) throws -> Bool {
        guard let value = object[key]?.boolValue else {
            throw NotesDomainError.invalidPayload("missingOrInvalid:\(key)")
        }
        return value
    }

    func boolOrNil(_ key: String) throws -> Bool? {
        guard let value = object[key], !value.isNull else { return nil }
        guard let bool = value.boolValue else {
            throw NotesDomainError.invalidPayload("invalidBoolean:\(key)")
        }
        return bool
    }

    func uuid(_ key: String) throws -> UUID {
        let raw = try string(key)
        guard let value = UUID(uuidString: raw) else {
            throw NotesDomainError.invalidPayload("invalidUUID:\(key)")
        }
        return value
    }

    func uuidOrNil(_ key: String) throws -> UUID? {
        guard let raw = try stringOrNil(key), !raw.isEmpty else { return nil }
        guard let value = UUID(uuidString: raw) else {
            throw NotesDomainError.invalidPayload("invalidUUID:\(key)")
        }
        return value
    }

    func array(_ key: String) throws -> [NotesJSONValue] {
        guard let value = object[key]?.arrayValue else {
            throw NotesDomainError.invalidPayload("missingOrInvalidArray:\(key)")
        }
        return value
    }

    func arrayOrNil(_ key: String) throws -> [NotesJSONValue]? {
        guard let value = object[key], !value.isNull else { return nil }
        guard let array = value.arrayValue else {
            throw NotesDomainError.invalidPayload("invalidArray:\(key)")
        }
        return array
    }

    func strings(_ key: String) throws -> [String] {
        try array(key).map {
            guard let value = $0.stringValue else {
                throw NotesDomainError.invalidPayload("invalidStringArray:\(key)")
            }
            return value
        }
    }

    func decode<T: Decodable>(_ type: T.Type, key: String) throws -> T {
        guard let value = object[key] else {
            throw NotesDomainError.invalidPayload("missing:\(key)")
        }
        return try NotesWire.decode(type, from: NotesWire.data(from: value))
    }

    func decodeOrNil<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        guard let value = object[key], !value.isNull else { return nil }
        return try NotesWire.decode(type, from: NotesWire.data(from: value))
    }

    func decodeArray<T: Decodable>(_ type: T.Type, key: String) throws -> [T] {
        guard let value = object[key] else {
            throw NotesDomainError.invalidPayload("missing:\(key)")
        }
        return try NotesWire.decode([T].self, from: NotesWire.data(from: value))
    }
}

/// Flat, closed edit schema shared with the Kotlin contract. Swift's
/// synthesized enum Codable shape is intentionally not exposed across the
/// bridge; each action maps to the original `NoteEdit` case here.
enum NotesEditWire {
    static func decode(_ value: NotesJSONValue?) throws -> [NoteEdit] {
        guard let value else { throw NotesDomainError.invalidPayload("missingEdits") }
        guard let items = value.arrayValue else {
            throw NotesDomainError.invalidPayload("editsNotArray")
        }
        guard !items.isEmpty, items.count <= NotesWire.maximumEdits else {
            throw NotesDomainError.invalidPayload("editCount")
        }
        return try items.map(decodeOne)
    }

    private static func decodeOne(_ value: NotesJSONValue) throws -> NoteEdit {
        guard let object = value.objectValue else {
            throw NotesDomainError.invalidPayload("editNotObject")
        }
        let payload = try NotesPayload(.object(object))
        switch try payload.string("action") {
        case "rename":
            return .rename(try payload.string("text"))
        case "moveToNotebook":
            return .moveToNotebook(try payload.uuidOrNil("notebookID"))
        case "favorite":
            return .favorite(try payload.bool("isFavorite"))
        case "tags":
            return .tags(try payload.strings("tags"))
        case "textSource":
            guard payload.has("text") else {
                throw NotesDomainError.invalidPayload("missingText")
            }
            return .textSource(id: try payload.uuid("id"),
                               text: try payload.stringOrNil("text"))
        case "insertPage":
            return .insertPage(try payload.decode(NotePage.self, key: "page"),
                               at: try payload.int("index"))
        case "updatePage":
            return .updatePage(try payload.decode(NotePage.self, key: "page"))
        case "movePage":
            return .movePage(try payload.uuid("pageID"), to: try payload.int("index"))
        case "duplicatePage":
            return .duplicatePage(try payload.uuid("pageID"))
        case "deletePage":
            return .deletePage(try payload.uuid("pageID"))
        case "drawing":
            return .drawing(pageID: try payload.uuid("pageID"),
                            resourceID: try payload.uuidOrNil("resourceID"))
        case "upsertElement":
            return .upsertElement(pageID: try payload.uuid("pageID"),
                                  element: try payload.decode(NoteElement.self, key: "element"))
        case "deleteElements":
            let ids = try payload.strings("ids").map { raw -> UUID in
                guard let id = UUID(uuidString: raw) else {
                    throw NotesDomainError.invalidPayload("invalidUUID:ids")
                }
                return id
            }
            return .deleteElements(pageID: try payload.uuid("pageID"), ids: ids)
        case "upsertNode":
            return .upsertNode(try payload.decode(MindMapNode.self, key: "node"))
        case "deleteBranch":
            return .deleteBranch(try payload.uuid("nodeID"))
        case "upsertConnection":
            return .upsertConnection(try payload.decode(MindMapConnection.self, key: "connection"))
        case "deleteConnection":
            return .deleteConnection(try payload.uuid("connectionID"))
        case "replaceMindMap":
            return .replaceMindMap(
                nodes: try payload.decodeArray(MindMapNode.self, key: "nodes"),
                connections: try payload.decodeArray(MindMapConnection.self, key: "connections"))
        case "linkMindMap":
            return .linkMindMap(try payload.decode(NoteMindMapLink.self, key: "link"))
        case "unlinkMindMap":
            return .unlinkMindMap(try payload.uuid("linkID"))
        case "replaceOfficeResource":
            return .replaceOfficeResource(try payload.uuid("resourceID"))
        case "mindMapLayout":
            return .mindMapLayout(
                direction: try payload.int("direction"),
                summaries: try payload.decodeArray(MindMapSummary.self, key: "summaries"))
        case let action:
            throw NotesDomainError.unsupportedAction("editAction:\(NotesWire.bounded(action, limit: 80))")
        }
    }
}
