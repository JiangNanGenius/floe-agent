// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

public enum InteractiveError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case invalidDocument
    case invalidJSON
    case limitExceeded
    case ownershipMismatch
    case contentChanged
    case staleRevision(expected: UInt64, actual: UInt64)
    case staleRuntime
    case invalidSequence
    case closed
    case unsafeStorage
    case storageFailure
    case missingResource
}

/// JSON only: no executable values, URLs with authority, or implicit permissions.
public enum JSONValue: Codable, Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String)
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self), n.isFinite { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw InteractiveError.invalidJSON }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            guard n.isFinite else { throw InteractiveError.invalidJSON }
            try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(_ key: String) -> JSONValue? {
        guard case .object(let values) = self else { return nil }
        return values[key]
    }
}

public enum InteractiveLimits {
    public static let documentBytes = 512 * 1_024
    public static let stateBytes = 32 * 1_024
    public static let bridgeBytes = 72 * 1_024
    public static let depth = 20
    public static let maximumBridgeInteger: UInt64 = 9_007_199_254_740_991

    public static func checkJSON(_ data: Data, maximum: Int) throws {
        guard data.count <= maximum else { throw InteractiveError.limitExceeded }
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw InteractiveError.invalidJSON }
        func walk(_ value: Any, depth: Int) throws {
            guard depth <= InteractiveLimits.depth else { throw InteractiveError.limitExceeded }
            if let object = value as? [String: Any] {
                for (key, child) in object {
                    guard key.utf8.count <= 1_024 else { throw InteractiveError.limitExceeded }
                    try walk(child, depth: depth + 1)
                }
            } else if let array = value as? [Any] {
                for child in array { try walk(child, depth: depth + 1) }
            } else if let number = value as? NSNumber {
                guard number.doubleValue.isFinite else { throw InteractiveError.invalidJSON }
            }
        }
        try walk(value, depth: 0)
    }

    public static func checkState(_ value: JSONValue) throws {
        try checkJSON(JSONEncoder().encode(value), maximum: stateBytes)
    }
}

public enum InteractiveDigest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Minted by the host, never adopted from a script message.
public struct ContentOwner: Codable, Equatable, Hashable, Sendable {
    public let conversationID: UUID
    public let runID: UUID
    public let messageID: UUID
    public let contentID: UUID
    public let contentRevision: UInt64

    public init(conversationID: UUID, runID: UUID, messageID: UUID,
                contentID: UUID = UUID(), contentRevision: UInt64 = 1) {
        self.conversationID = conversationID
        self.runID = runID
        self.messageID = messageID
        self.contentID = contentID
        self.contentRevision = contentRevision
    }

    public var storageKey: String {
        let identity = [conversationID.uuidString, runID.uuidString, messageID.uuidString,
                        contentID.uuidString, String(contentRevision)].joined(separator: ":")
        return InteractiveDigest.sha256(Data(identity.utf8))
    }
}

public struct InteractiveDocument: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let owner: ContentOwner
    /// Classification only. A new kind does not require a new executable tool.
    public let kind: String
    public let title: String
    public let html: String
    public let fallbackText: String
    public let initialModelContent: JSONValue
    public let initialPrivateContent: JSONValue

    public init(owner: ContentOwner, kind: String, title: String, html: String,
                fallbackText: String, initialModelContent: JSONValue = .null,
                initialPrivateContent: JSONValue = .null, schemaVersion: Int = 1) throws {
        self.schemaVersion = schemaVersion
        self.owner = owner
        self.kind = kind
        self.title = title
        self.html = html
        self.fallbackText = fallbackText
        self.initialModelContent = initialModelContent
        self.initialPrivateContent = initialPrivateContent
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw InteractiveError.unsupportedVersion(schemaVersion) }
        guard owner.contentRevision > 0, !kind.isEmpty, kind.utf8.count <= 80,
              title.utf8.count <= 640, !html.isEmpty,
              html.utf8.count <= InteractiveLimits.documentBytes,
              !fallbackText.isEmpty, fallbackText.utf8.count <= 16_384 else {
            throw InteractiveError.invalidDocument
        }
        try InteractiveLimits.checkState(initialModelContent)
        try InteractiveLimits.checkState(initialPrivateContent)
    }

    public var digest: String {
        // Includes ownership, defaults and fallback, not merely HTML bytes.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return InteractiveDigest.sha256((try? encoder.encode(self)) ?? Data())
    }

    public static func decode(_ data: Data) throws -> Self {
        try InteractiveLimits.checkJSON(data, maximum: documentBytesWithEnvelope)
        let document = try JSONDecoder().decode(Self.self, from: data)
        try document.validate()
        return document
    }

    private static let documentBytesWithEnvelope = InteractiveLimits.documentBytes + 100 * 1_024
}

public struct InteractiveReference: Codable, Equatable, Sendable {
    public let owner: ContentOwner
    public let documentSHA256: String
    public init(document: InteractiveDocument) {
        owner = document.owner
        documentSHA256 = document.digest
    }
}

/// Does not execute or settle a question; the App resolves this through user.ask.
public struct ExistingQuestionReference: Codable, Equatable, Sendable {
    public let requestID: String
    public let questionID: String?
    public init(requestID: String, questionID: String? = nil) {
        self.requestID = requestID
        self.questionID = questionID
    }
}

public enum InteractiveResponsePart: Codable, Equatable, Sendable {
    case text(String)
    case interactive(InteractiveReference)
    case existingQuestion(ExistingQuestionReference)
}
