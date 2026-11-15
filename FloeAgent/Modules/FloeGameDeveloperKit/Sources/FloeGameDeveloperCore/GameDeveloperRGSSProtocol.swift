// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// One guest file directory owned by a single run. The host's existing scoped
/// guest file service resolves this absolute path; this package never mounts a
/// host filesystem or spawns a process.
public struct GameDeveloperGuestDirectory: Equatable, Sendable {
    public let absolutePath: String
    public let ownerToken: UUID

    public init(absolutePath: String, ownerToken: UUID) throws {
        guard absolutePath.hasPrefix("/"), absolutePath.utf8.count <= 4_096,
              !absolutePath.contains(".."), !absolutePath.contains("\\"),
              !absolutePath.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              absolutePath.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ $0 != "." }) else {
            throw GameDeveloperError.invalidConfiguration("guest directory")
        }
        self.absolutePath = absolutePath.hasSuffix("/") ? String(absolutePath.dropLast()) : absolutePath
        self.ownerToken = ownerToken
    }

    /// Files are addressed relative to the overlay directory
    /// (`<run>/floe-developer`), never relative to the project root.
    public var requestsRelativeDirectory: String { "requests" }
    public var responsesRelativeDirectory: String { "responses" }
}

/// Implemented by the host over its existing scoped Linux guest file service.
/// `writeFile` must create parent directories and should publish atomically.
public protocol GameDeveloperGuestFilePort: Sendable {
    func writeFile(_ data: Data, relativePath: String,
                   directory: GameDeveloperGuestDirectory) async throws
    func readFile(relativePath: String, directory: GameDeveloperGuestDirectory,
                  maximumBytes: Int) async throws -> Data?
    func removeFile(relativePath: String,
                    directory: GameDeveloperGuestDirectory) async throws
}

public enum GameDeveloperRGSSOperation: UInt8, Sendable {
    case probe = 1
    case read = 2
    case write = 3
    case invoke = 4
    case snapshot = 5
    case restore = 6
    case reset = 7
    case detach = 8
    case diagnostics = 9
}

public enum GameDeveloperRGSSRecordValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case binary(Data)
    case null

    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var integerValue: Int? { if case .integer(let value) = self { return value }; return nil }
    public var numberValue: Double? {
        switch self {
        case .integer(let value): return Double(value)
        case .number(let value): return value
        default: return nil
        }
    }
    public var booleanValue: Bool? { if case .boolean(let value) = self { return value }; return nil }
    public var binaryValue: Data? { if case .binary(let value) = self { return value }; return nil }
}

public struct GameDeveloperRGSSRecord: Equatable, Sendable {
    public let key: String
    public let value: GameDeveloperRGSSRecordValue
    public init(_ key: String, _ value: GameDeveloperRGSSRecordValue) {
        self.key = key; self.value = value
    }
}

public enum GameDeveloperRGSSCodec {
    public static let requestMagic: [UInt8] = [0x46, 0x4C, 0x44, 0x52] // FLDR
    public static let responseMagic: [UInt8] = [0x46, 0x4C, 0x44, 0x53] // FLDS
    public static let version: UInt8 = 1
    public static let maximumRecords = 512
    public static let maximumKeyBytes = 128
    public static let maximumStringBytes = 65_536
    public static let maximumBinaryBytes = 4 * 1_024 * 1_024

    public static func encodeRequest(operation: GameDeveloperRGSSOperation,
                                     requestID: UUID,
                                     records: [GameDeveloperRGSSRecord],
                                     limits: GameDeveloperLimits = .default) throws -> Data {
        guard records.count <= maximumRecords else {
            throw GameDeveloperError.payloadTooLarge("guest request records")
        }
        var body = Data()
        body.appendUInt16(UInt16(records.count))
        for record in records {
            try append(record: record, to: &body)
        }
        guard body.count <= limits.maximumRequestBytes else {
            throw GameDeveloperError.payloadTooLarge("guest request")
        }
        var data = Data(requestMagic)
        data.append(version)
        data.append(operation.rawValue)
        data.append(contentsOf: Array(requestID.uuidString.lowercased().utf8))
        data.appendUInt32(UInt32(body.count))
        data.append(body)
        return data
    }

    public static func encodeResponse(requestID: UUID,
                                      records: [GameDeveloperRGSSRecord],
                                      limits: GameDeveloperLimits = .default) throws -> Data {
        guard records.count <= maximumRecords else {
            throw GameDeveloperError.payloadTooLarge("guest response records")
        }
        var body = Data()
        body.appendUInt16(UInt16(records.count))
        for record in records {
            try append(record: record, to: &body)
        }
        guard body.count <= limits.maximumResponseBytes else {
            throw GameDeveloperError.payloadTooLarge("guest response")
        }
        var data = Data(responseMagic)
        data.append(version)
        data.append(contentsOf: Array(requestID.uuidString.lowercased().utf8))
        data.appendUInt32(UInt32(body.count))
        data.append(body)
        return data
    }

    public static func decodeResponse(_ data: Data, expectedRequestID: UUID,
                                      limits: GameDeveloperLimits = .default) throws -> [GameDeveloperRGSSRecord] {
        guard data.count >= 4 + 1 + 36 + 4,
              Array(data.prefix(4)) == responseMagic else {
            throw GameDeveloperError.invalidRequest("guest response magic")
        }
        let bytes = [UInt8](data)
        guard bytes[4] == version else {
            throw GameDeveloperError.invalidRequest("guest response version")
        }
        let uuidStart = 5, uuidEnd = uuidStart + 36
        guard let uuid = UUID(uuidString: String(decoding: bytes[uuidStart..<uuidEnd], as: UTF8.self)),
              uuid == expectedRequestID else {
            throw GameDeveloperError.staleSession
        }
        let length = Int(readUInt32(bytes, at: uuidEnd))
        guard length >= 2, uuidEnd + 4 + length == bytes.count,
              length + uuidEnd + 4 <= limits.maximumResponseBytes + 1_024 else {
            throw GameDeveloperError.invalidRequest("guest response length")
        }
        let payload = Data(bytes[(uuidEnd + 4)..<(uuidEnd + 4 + length)])
        return try decodeRecords(payload, limits: limits)
    }

    public static func decodeRecords(_ data: Data, limits: GameDeveloperLimits = .default) throws -> [GameDeveloperRGSSRecord] {
        let bytes = [UInt8](data)
        guard bytes.count >= 2 else { throw GameDeveloperError.invalidRequest("guest payload") }
        let count = Int(readUInt16(bytes, at: 0))
        guard count <= maximumRecords else {
            throw GameDeveloperError.payloadTooLarge("guest response records")
        }
        var offset = 2
        var records: [GameDeveloperRGSSRecord] = []
        records.reserveCapacity(count)
        for _ in 0..<count {
            guard offset + 1 + 2 <= bytes.count else { throw GameDeveloperError.invalidRequest("guest record header") }
            let type = bytes[offset]; offset += 1
            let keyLength = Int(readUInt16(bytes, at: offset)); offset += 2
            guard keyLength > 0, keyLength <= maximumKeyBytes, offset + keyLength + 4 <= bytes.count else {
                throw GameDeveloperError.invalidRequest("guest record key")
            }
            let key = String(decoding: bytes[offset..<(offset + keyLength)], as: UTF8.self)
            offset += keyLength
            let valueLength = Int(readUInt32(bytes, at: offset)); offset += 4
            guard valueLength >= 0, valueLength <= maximumBinaryBytes,
                  offset + valueLength <= bytes.count else {
                throw GameDeveloperError.payloadTooLarge("guest record value")
            }
            let valueBytes = Data(bytes[offset..<(offset + valueLength)])
            offset += valueLength
            let value: GameDeveloperRGSSRecordValue
            switch type {
            case 1:
                guard valueBytes.count <= maximumStringBytes else {
                    throw GameDeveloperError.payloadTooLarge("guest string")
                }
                value = .string(String(decoding: valueBytes, as: UTF8.self))
            case 2:
                guard let text = String(data: valueBytes, encoding: .ascii),
                      let number = Int(text) else {
                    throw GameDeveloperError.invalidRequest("guest integer")
                }
                value = .integer(number)
            case 3:
                guard let text = String(data: valueBytes, encoding: .ascii),
                      let number = Double(text), number.isFinite else {
                    throw GameDeveloperError.invalidRequest("guest number")
                }
                value = .number(number)
            case 4:
                guard valueBytes.count == 1 else { throw GameDeveloperError.invalidRequest("guest boolean") }
                value = .boolean(valueBytes[0] != 0)
            case 5:
                guard valueBytes.count <= maximumBinaryBytes else {
                    throw GameDeveloperError.payloadTooLarge("guest binary")
                }
                value = .binary(valueBytes)
            case 6:
                guard valueBytes.isEmpty else { throw GameDeveloperError.invalidRequest("guest null") }
                value = .null
            default:
                throw GameDeveloperError.invalidRequest("guest record type \(type)")
            }
            records.append(.init(key, value))
        }
        guard offset == bytes.count else { throw GameDeveloperError.invalidRequest("guest trailing bytes") }
        return records
    }

    public static func dictionary(_ records: [GameDeveloperRGSSRecord]) -> [String: GameDeveloperRGSSRecordValue] {
        var result: [String: GameDeveloperRGSSRecordValue] = [:]
        for record in records { result[record.key] = record.value }
        return result
    }

    public static func repeatedStrings(_ records: [GameDeveloperRGSSRecord], prefix: String) -> [String] {
        records.compactMap { record in
            guard record.key.hasPrefix(prefix), let value = record.value.stringValue else { return nil }
            return value
        }
    }

    private static func append(record: GameDeveloperRGSSRecord, to data: inout Data) throws {
        guard !record.key.isEmpty, record.key.utf8.count <= maximumKeyBytes,
              !record.key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw GameDeveloperError.invalidRequest("guest record key")
        }
        let type: UInt8
        var value = Data()
        switch record.value {
        case .string(let text):
            guard text.utf8.count <= maximumStringBytes else {
                throw GameDeveloperError.payloadTooLarge("guest string")
            }
            type = 1; value.append(contentsOf: Array(text.utf8))
        case .integer(let number):
            type = 2; value.append(contentsOf: Array(String(number).utf8))
        case .number(let number):
            guard number.isFinite else { throw GameDeveloperError.invalidRequest("guest number") }
            type = 3; value.append(contentsOf: Array(String(format: "%.17g", number).utf8))
        case .boolean(let flag):
            type = 4; value.append(flag ? 1 : 0)
        case .binary(let bytes):
            guard bytes.count <= maximumBinaryBytes else {
                throw GameDeveloperError.payloadTooLarge("guest binary")
            }
            type = 5; value = bytes
        case .null:
            type = 6
        }
        let key = Array(record.key.utf8)
        data.append(type)
        data.appendUInt16(UInt16(key.count))
        data.append(contentsOf: key)
        data.appendUInt32(UInt32(value.count))
        data.append(value)
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16) |
        (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8)); append(UInt8(value & 0xFF))
    }
    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}

/// Closure-backed adapter for a host that already exposes scoped guest file
/// read/write/remove operations. It creates no filesystem service of its own.
public struct GameDeveloperGuestFilePortAdapter: GameDeveloperGuestFilePort {
    public typealias WriteOperation = @Sendable (Data, String, GameDeveloperGuestDirectory) async throws -> Void
    public typealias ReadOperation = @Sendable (String, GameDeveloperGuestDirectory, Int) async throws -> Data?
    public typealias RemoveOperation = @Sendable (String, GameDeveloperGuestDirectory) async throws -> Void

    private let writeOperation: WriteOperation
    private let readOperation: ReadOperation
    private let removeOperation: RemoveOperation

    public init(write: @escaping WriteOperation,
                read: @escaping ReadOperation,
                remove: @escaping RemoveOperation) {
        self.writeOperation = write
        self.readOperation = read
        self.removeOperation = remove
    }

    public func writeFile(_ data: Data, relativePath: String,
                          directory: GameDeveloperGuestDirectory) async throws {
        try await writeOperation(data, relativePath, directory)
    }

    public func readFile(relativePath: String, directory: GameDeveloperGuestDirectory,
                         maximumBytes: Int) async throws -> Data? {
        try await readOperation(relativePath, directory, maximumBytes)
    }

    public func removeFile(relativePath: String,
                           directory: GameDeveloperGuestDirectory) async throws {
        try await removeOperation(relativePath, directory)
    }
}
