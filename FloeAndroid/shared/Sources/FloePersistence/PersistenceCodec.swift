// FloePersistence — shared encoding helpers for store row mapping.

import Foundation
import FloeCore

/// Shared ISO-8601 (fractional seconds) coding and small JSON helpers used
/// by the v3 stores. Centralised so every store persists dates identically.
enum PersistenceCodec {
    static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func decodeDate(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        guard let date = standard.date(from: value) else {
            throw FloeError.storageCorrupted("Invalid ISO-8601 date in persistence layer")
        }
        return date
    }

    static func jsonObject(_ dictionary: [String: String]) throws -> String {
        let data = try JSONEncoder().encode(dictionary)
        guard let string = String(data: data, encoding: .utf8) else {
            throw FloeError.internalError("Could not encode metadata as UTF-8")
        }
        return string
    }

    static func jsonDictionary(_ string: String) throws -> [String: String] {
        let data = Data(string.utf8)
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}
