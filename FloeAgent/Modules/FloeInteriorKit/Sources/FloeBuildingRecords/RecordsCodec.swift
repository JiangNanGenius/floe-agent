import CryptoKit
import Foundation
import GRDB

enum RecordsCodec {
    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint<T: Encodable>(_ value: T) throws -> String {
        sha256Hex(Data(try json(value).utf8))
    }

    static func isSHA256Hex(_ value: String) -> Bool {
        guard value.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

extension Row {
    func requiredString(_ column: String) throws -> String {
        let value: String = self[column]
        return value
    }

    func optionalString(_ column: String) -> String? {
        let value: String? = self[column]
        return value
    }

    func requiredInt(_ column: String) throws -> Int {
        let value: Int = self[column]
        return value
    }

    func optionalInt(_ column: String) -> Int? {
        let value: Int? = self[column]
        return value
    }

    func requiredDouble(_ column: String) throws -> Double {
        let value: Double = self[column]
        return value
    }

    func optionalDouble(_ column: String) -> Double? {
        let value: Double? = self[column]
        return value
    }

    func requiredBool(_ column: String) throws -> Bool {
        let value: Int = self[column]
        return value != 0
    }

    func requiredDate(_ column: String) throws -> Date {
        let value: Date = self[column]
        return value
    }

    func optionalDate(_ column: String) -> Date? {
        let value: Date? = self[column]
        return value
    }

    func recordID<Tag: Sendable>(_ column: String) throws -> RecordID<Tag> {
        let raw = try requiredString(column)
        guard let uuid = UUID(uuidString: raw) else {
            throw BuildingRecordsError.invalidValue(field: column, reason: "invalid record identifier")
        }
        return RecordID(rawValue: uuid)
    }

    func optionalRecordID<Tag: Sendable>(_ column: String) throws -> RecordID<Tag>? {
        guard let raw = optionalString(column) else { return nil }
        guard let uuid = UUID(uuidString: raw) else {
            throw BuildingRecordsError.invalidValue(field: column, reason: "invalid record identifier")
        }
        return RecordID(rawValue: uuid)
    }

    func requiredEnum<E: RawRepresentable>(_ column: String, as type: E.Type) throws -> E
    where E.RawValue == String {
        let raw = try requiredString(column)
        guard let value = E(rawValue: raw) else {
            throw BuildingRecordsError.invalidValue(field: column, reason: "unknown value \(raw)")
        }
        return value
    }

    func optionalEnum<E: RawRepresentable>(_ column: String, as type: E.Type) throws -> E?
    where E.RawValue == String {
        guard let raw = optionalString(column) else { return nil }
        guard let value = E(rawValue: raw) else {
            throw BuildingRecordsError.invalidValue(field: column, reason: "unknown value \(raw)")
        }
        return value
    }
}

extension Sequence {
    func stableUniqueSorted() -> [Element] where Element: Comparable & Hashable {
        Array(Set(self)).sorted()
    }
}
