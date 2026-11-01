// SPDX-License-Identifier: MPL-2.0
//
// G09-R1 — additive creative (Canvas + media project) bridge vocabulary.
//
// This is a HOST-ONLY channel dispatched from the existing
// `floe_bridge_exchange` C ABI (BridgeV5 in Bridge.swift). It adds no C++,
// no JNI and no model-facing tool: only the trusted Android host adapter can
// reach it, like `floe.notes/4`.
//
// Bounds are explicit and closed:
// * request JSON ≤ 64 KiB (the existing bridge buffer bound);
// * response JSON ≤ 16 MiB (Canvas documents are the only large payload);
// * Canvas project files ≤ 15 MiB and media project files ≤ 8 MiB so a
//   response can never be truncated into a false success;
// * asset bytes NEVER travel in JSON — the host stages bounded bytes under
//   the accepted root and passes only an opaque token + digest.
import Foundation
import FloeCore

public enum G09CreativeLimits {
    public static let requestBytes = 65_536
    public static let responseBytes = 16 * 1024 * 1024
    public static let canvasProjectBytes = 15 * 1024 * 1024
    public static let mediaProjectBytes = 8 * 1024 * 1024
    public static let assetBytes = 64 * 1024 * 1024
    public static let libraryEntries = 500
    public static let batchOperations = 100
    public static let mediaCommands = 64
    public static let nameBytes = 120
    public static let sessionTokenBytes = 128
    public static let stagingTokenBytes = 200
    public static let requestIDBytes = 256
    public static let recoveryOperations = 512
    public static let receiptCount = 256
}

/// Closed host wire vocabulary. Codes are stable identifiers, never paths or
/// raw content.
public enum G09CreativeError: Error, Sendable, Equatable {
    case unsupportedVersion
    case requestTooLarge
    case responseTooLarge
    case invalidRequest(String)
    case unsupportedOperation
    case unsupportedAction(String)
    case invalidPayload(String)
    case runtimeUnavailable
    case acceptedRootNotLive
    case staleGeneration
    case sessionRequired
    case staleSession
    case sessionLimit
    case canvasNotFound
    case mediaProjectNotFound
    case corruptProject
    case unsupportedSchema
    case projectTooLarge
    case revisionConflict
    case untrustedOwner
    case crossOwnerRefused
    case storageLayerRequired
    case invalidOrigin(String)
    case outcomeUnknown
    case workspaceStorageUnavailable
    case provenanceMismatch
    case assetTooLarge
    case assetEmpty
    case assetDigestMismatch
    case assetStagingUnavailable
    case assetStagingInvalid
    case assetMissing
    case assetReferenceInvalid
    case storageUnavailable
    case writeFailed

    public var code: String {
        switch self {
        case .unsupportedVersion: "unsupportedVersion"
        case .requestTooLarge: "requestTooLarge"
        case .responseTooLarge: "responseTooLarge"
        case .invalidRequest: "invalidRequest"
        case .unsupportedOperation: "unsupportedOperation"
        case .unsupportedAction: "unsupportedAction"
        case .invalidPayload: "invalidPayload"
        case .runtimeUnavailable: "runtimeUnavailable"
        case .acceptedRootNotLive: "acceptedRootNotLive"
        case .staleGeneration: "staleGeneration"
        case .sessionRequired: "sessionRequired"
        case .staleSession: "staleSession"
        case .sessionLimit: "sessionLimit"
        case .canvasNotFound: "canvasNotFound"
        case .mediaProjectNotFound: "mediaProjectNotFound"
        case .corruptProject: "corruptProject"
        case .unsupportedSchema: "unsupportedSchema"
        case .projectTooLarge: "projectTooLarge"
        case .revisionConflict: "revisionConflict"
        case .untrustedOwner: "untrustedOwner"
        case .crossOwnerRefused: "crossOwnerRefused"
        case .storageLayerRequired: "storageLayerRequired"
        case .invalidOrigin: "invalidOrigin"
        case .outcomeUnknown: "outcomeUnknown"
        case .workspaceStorageUnavailable: "workspaceStorageUnavailable"
        case .provenanceMismatch: "provenanceMismatch"
        case .assetTooLarge: "assetTooLarge"
        case .assetEmpty: "assetEmpty"
        case .assetDigestMismatch: "assetDigestMismatch"
        case .assetStagingUnavailable: "assetStagingUnavailable"
        case .assetStagingInvalid: "assetStagingInvalid"
        case .assetMissing: "assetMissing"
        case .assetReferenceInvalid: "assetReferenceInvalid"
        case .storageUnavailable: "storageUnavailable"
        case .writeFailed: "writeFailed"
        }
    }

    public var reason: String? {
        switch self {
        case .invalidRequest(let detail), .invalidPayload(let detail),
             .unsupportedAction(let detail), .invalidOrigin(let detail):
            detail
        default:
            nil
        }
    }

    public var retryable: Bool {
        switch self {
        case .runtimeUnavailable, .acceptedRootNotLive, .staleGeneration,
             .sessionRequired, .assetStagingUnavailable, .storageUnavailable:
            true
        default:
            false
        }
    }

    /// Maps a lower-level failure without leaking a raw path or SQL text.
    /// Storage corruption is reported as a corrupt project so callers keep the
    /// original bytes and surface recovery instead of retrying a destructive
    /// write; validation failures retain only a bounded structural reason.
    public static func map(_ error: Error) -> G09CreativeError {
        if let typed = error as? G09CreativeError { return typed }
        if let floe = error as? FloeError {
            switch floe {
            case .cancelled:
                return .staleGeneration
            case .unauthorized:
                return .crossOwnerRefused
            case .notFound:
                return .canvasNotFound
            case .storageCorrupted:
                return .corruptProject
            case .validationFailed(let detail):
                if detail.contains("revision") || detail.contains("Revision") {
                    return .revisionConflict
                }
                return .invalidPayload("rejected")
            case .invalidConfiguration, .syncUnavailable, .internalError:
                return .storageUnavailable
            }
        }
        return .storageUnavailable
    }
}

/// Minimal JSON value used only for bridge payload transport. Typed request
/// bodies are decoded from it with the same Codable models the storage layer
/// uses; this type never carries storage authority.
public enum G09CreativeJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([G09CreativeJSON])
    case object([String: G09CreativeJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([G09CreativeJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: G09CreativeJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public func data() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public var objectValue: [String: G09CreativeJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

/// Exact `floe.creative/5` request envelope. The fixed `operation` selector
/// mirrors v4: handshake/status are read-only, bind is epoch-exact, and every
/// data call is a closed `action` under `command`.
struct G09CreativeRequest: Decodable {
    let version: Int
    let operation: String
    let requestID: String?
    let epoch: UInt64?
    let action: String?
    let payload: G09CreativeJSON?
}

public enum G09CreativeActions {
    public static let schema = "floe.creative/5"
    public static let version = 5

    /// Closed action list. No action creates an AI task/run/environment and
    /// no action is advertised as a model tool.
    public static let all: [String] = [
        "canvas.library",
        "canvas.load",
        "canvas.create",
        // Additive R1 source-import creation: one atomic, idempotent project
        // from a staged user file. Explicit New Blank stays `canvas.create`.
        "canvas.createFromStaged",
        "canvas.patch",
        "canvas.rename",
        "canvas.delete",
        "canvas.session.close",
        "creative.asset.importStaged",
        "creative.asset.discard",
        "creative.asset.referenceOp",
        "creative.recovery",
        "media.project.library",
        "media.project.load",
        "media.project.create",
        // Additive R1 source-import creation (image/video from a staged file).
        "media.project.createFromStaged",
        "media.project.apply",
        "media.project.undo",
        "media.project.redo",
        "media.project.rename",
        "media.project.delete",
        "media.session.close",
        "media.asset.importStaged",
        "media.asset.relink",
    ]

    public static func isCommand(_ action: String) -> Bool { all.contains(action) }
}

public enum G09CreativeWire {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func decode<T: Decodable>(_ type: T.Type, payload: G09CreativeJSON?) throws -> T {
        guard let payload else { throw G09CreativeError.invalidPayload("missingPayload") }
        do {
            return try decoder().decode(type, from: payload.data())
        } catch let typed as G09CreativeError {
            throw typed
        } catch {
            throw G09CreativeError.invalidPayload("malformedPayload")
        }
    }

    public static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data: Data
        do {
            data = try encoder().encode(value)
        } catch {
            throw G09CreativeError.storageUnavailable
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw G09CreativeError.storageUnavailable
        }
        return object
    }

    public static func failure(_ error: G09CreativeError) -> [String: Any] {
        var value: [String: Any] = [
            "ok": false,
            "error": error.code,
            "retryable": error.retryable,
        ]
        if let reason = error.reason { value["reason"] = bounded(reason, limit: 96) }
        return value
    }

    public static func bounded(_ value: String, limit: Int) -> String {
        guard value.utf8.count > limit else { return value }
        var result = ""
        for character in value {
            let next = result + String(character)
            if next.utf8.count > limit { break }
            result = next
        }
        return result
    }

    /// Exact UUID helper that accepts only the canonical textual form.
    public static func uuid(_ raw: String) -> UUID? {
        guard raw.count == 36, let value = UUID(uuidString: raw),
              value.uuidString.lowercased() == raw.lowercased() else { return nil }
        return value
    }

    public static func validSessionToken(_ raw: String) -> Bool {
        !raw.isEmpty && raw.utf8.count <= G09CreativeLimits.sessionTokenBytes &&
            raw.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "."
            }
    }
}
