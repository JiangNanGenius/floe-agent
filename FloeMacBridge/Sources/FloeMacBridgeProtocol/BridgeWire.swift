import Foundation
import CryptoKit

public enum BridgeValue: Codable, Sendable, Equatable {
    case string(String), integer(Int64), bool(Bool), array([BridgeValue]), object([String: BridgeValue]), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Int64.self) { self = .integer(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([BridgeValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: BridgeValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .integer(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var integer: Int64? { if case .integer(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var object: [String: BridgeValue]? { if case .object(let v) = self { v } else { nil } }
    public var array: [BridgeValue]? { if case .array(let v) = self { v } else { nil } }
}

public enum BridgeWire {
    public static let version = 1
    public static let port: UInt16 = 43871
    public static let endpoint = URL(string: "http://127.0.0.1:43871/rpc")!
    public static let maximumFrameBytes = 4 * 1_024 * 1_024
    public static let pageBytes = 64 * 1_024
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func pairingVerification(clientKey: Data, serverKey: Data, nonce: String) -> String {
        let identity = Data("Floe bridge pairing v1\0".utf8) + clientKey + serverKey + Data(nonce.utf8)
        let hex = String(digest(identity).prefix(12)).uppercased()
        return stride(from: 0, to: 12, by: 4).map { offset in
            String(hex.dropFirst(offset).prefix(4))
        }.joined(separator: " ")
    }
    public static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0)
        } && id != "." && id != ".."
    }
}

public struct BridgeRequestBody: Codable, Sendable {
    public var version: Int
    public var id: UUID
    public var clientKey: Data
    public var issuedAt: Int64
    public var method: String
    public var payload: [String: BridgeValue]
    public init(clientKey: Data, method: String, payload: [String: BridgeValue], id: UUID = UUID()) {
        self.version = BridgeWire.version; self.id = id; self.clientKey = clientKey
        self.issuedAt = Int64(Date().timeIntervalSince1970 * 1_000)
        self.method = method; self.payload = payload
    }
}
public struct BridgeRequest: Codable, Sendable {
    public var body: BridgeRequestBody
    public var signature: Data
    public init(body: BridgeRequestBody, key: Curve25519.Signing.PrivateKey) throws {
        self.body = body; self.signature = try key.signature(for: BridgeWire.encode(body))
    }
    public func verify(now: Date = Date()) throws {
        guard body.version == BridgeWire.version,
              abs(now.timeIntervalSince1970 - Double(body.issuedAt) / 1_000) <= 90,
              try Curve25519.Signing.PublicKey(rawRepresentation: body.clientKey)
                .isValidSignature(signature, for: BridgeWire.encode(body)) else { throw BridgeFailure.authentication }
    }
}
public struct BridgeResponseBody: Codable, Sendable {
    public var version: Int = BridgeWire.version
    public var id: UUID
    public var serverKey: Data
    public var result: [String: BridgeValue]
    public var error: String?
    public init(id: UUID, serverKey: Data, result: [String: BridgeValue] = [:], error: String? = nil) {
        self.id = id; self.serverKey = serverKey; self.result = result; self.error = error
    }
}
public struct BridgeResponse: Codable, Sendable {
    public var body: BridgeResponseBody
    public var signature: Data
    public init(body: BridgeResponseBody, key: Curve25519.Signing.PrivateKey) throws {
        self.body = body; self.signature = try key.signature(for: BridgeWire.encode(body))
    }
    public func verified(for request: BridgeRequestBody, pinnedKey: Data?) throws -> [String: BridgeValue] {
        guard body.version == BridgeWire.version, body.id == request.id,
              pinnedKey == nil || pinnedKey == body.serverKey,
              try Curve25519.Signing.PublicKey(rawRepresentation: body.serverKey)
                .isValidSignature(signature, for: BridgeWire.encode(body)) else { throw BridgeFailure.authentication }
        if let error = body.error { throw BridgeFailure.remote(error) }
        return body.result
    }
}
public enum BridgeFailure: Error, LocalizedError, Sendable {
    case authentication, disconnected, pending, remote(String), unsafePath, incompatible, ambiguous
    public var errorDescription: String? {
        switch self {
        case .authentication: "The Mac connection could not be verified. Reconnect in Settings."
        case .disconnected: "The Mac bridge is disconnected. Reconnect or choose a backup environment."
        case .pending: "Confirm this connection in Floe Bridge on this Mac."
        case .remote(let text): text
        case .unsafePath: "This file is outside the selected workspace."
        case .incompatible: "Update Floe and Floe Bridge to compatible versions."
        case .ambiguous: "The connection ended before the result arrived. Reconnect and inspect the existing job; it was not run again."
        }
    }
}
