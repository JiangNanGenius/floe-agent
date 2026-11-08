// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Lossless, bounded views and numeric-table export over an actual saved
/// chemistry result. This performs no new calculation or source mutation.
public enum ChemistryResultData {
    public static let maximumResultBytes = 64 * 1_024 * 1_024
    public static let maximumInlineBytes = 48 * 1_024
    public static let maximumPageItems = 1_000
    public struct Field: Codable, Sendable, Equatable {
        public let key: String
        public let kind: String
        public let count: Int?
    }
    public struct Snapshot: Sendable {
        public let data: Data
        public let sha256: String
        public let fields: [Field]
        public let preview: JSONValue
        public let complete: Bool
    }
    public struct Page: Codable, Sendable, Equatable {
        public let resultSHA256: String
        public let resultKey: String?
        public let fields: [Field]
        public let offset: Int
        public let totalItems: Int
        public let returnedItems: Int
        public let nextOffset: Int?
        public let selectionComplete: Bool
        public let requiresResultKey: Bool
        public let value: JSONValue
    }
    public struct NumericTable: Sendable {
        public let columns: [String]
        public let rowCount: Int
        public let csv: Data
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    public static func snapshot(_ result: JSONValue) throws -> Snapshot {
        let data = try encode(result)
        guard data.count <= maximumResultBytes else { throw ChemistryError.invalid("Saved result exceeds the 64 MiB export budget.") }
        var fields: [Field] = []
        if case .object(let object) = result {
            guard object.count <= 256 else { throw ChemistryError.invalid("Result has more than 256 fields; use its configured scientific backend.") }
            for key in object.keys.sorted() {
                guard key.utf8.count <= 1_024 else { throw ChemistryError.invalid("Result field name exceeds its budget.") }
                let value = object[key]!
                fields.append(.init(key: key, kind: kind(value), count: count(value)))
            }
        }
        // Never pretend a whitelist of scalar summaries is the full result.
        let complete = data.count <= maximumInlineBytes
        return .init(data: data, sha256: ChemistryProjectStore.digest(data), fields: fields,
                     preview: complete ? result : .null, complete: complete)
    }
    public static func page(_ result: JSONValue, resultKey: String? = nil, offset: Int = 0,
                            limit: Int = 200, expectedSHA256: String? = nil,
                            checkCancellation: @Sendable () throws -> Void = {}) throws -> Page {
        try checkCancellation()
        guard offset >= 0, (1...maximumPageItems).contains(limit) else { throw ChemistryError.invalid("Result offset must be nonnegative and limit 1...1000.") }
        let source = try snapshot(result)
        try checkCancellation()
        if let expectedSHA256, expectedSHA256 != source.sha256 { throw ChemistryError.invalid("The saved result changed; read its current checksum before continuing.") }
        if offset > 0 && expectedSHA256 == nil { throw ChemistryError.invalid("Continuation requires expectedResultSHA256 from the previous result page.") }
        guard let resultKey else {
            guard offset == 0 else { throw ChemistryError.invalid("Choose an actual resultKey before paging a field.") }
            return .init(resultSHA256: source.sha256, resultKey: nil, fields: source.fields, offset: 0,
                         totalItems: count(result) ?? 1, returnedItems: source.complete ? (count(result) ?? 1) : 0,
                         nextOffset: nil, selectionComplete: source.complete,
                         requiresResultKey: !source.complete, value: source.preview)
        }
        guard resultKey.utf8.count <= 1_024, case .object(let fields) = result,
              let selected = fields[resultKey] else { throw ChemistryError.invalid("Choose an exact resultKey from the saved result fields.") }
        let values: [JSONValue], keys: [String]?
        switch selected {
        case .array(let items): values = items; keys = nil
        case .object(let entries):
            let names = entries.keys.sorted(); keys = names; values = names.map { entries[$0]! }
        default:
            guard offset == 0 else { throw ChemistryError.invalid("A scalar result has no continuation.") }
            guard try encode(selected).count <= maximumInlineBytes else { throw ChemistryError.invalid("This scalar is too large to inline; export the full result JSON.") }
            try checkCancellation()
            return .init(resultSHA256: source.sha256, resultKey: resultKey, fields: source.fields, offset: 0,
                         totalItems: 1, returnedItems: 1, nextOffset: nil, selectionComplete: true,
                         requiresResultKey: false, value: selected)
        }
        guard offset <= values.count else { throw ChemistryError.invalid("Result offset is beyond the selected field.") }
        var page: [JSONValue] = [], object: [String: JSONValue] = [:], bytes = 2
        let end = min(values.count, offset + limit)
        for index in offset..<end {
            try checkCancellation()
            let keyBytes: Int
            if let keys { keyBytes = try encode(keys[index]).count } else { keyBytes = 0 }
            let size = try encode(values[index]).count + keyBytes + 2
            if bytes + size > maximumInlineBytes {
                guard !page.isEmpty else { throw ChemistryError.invalid("One result item exceeds the inline budget; export the full result JSON.") }
                break
            }
            bytes += size; page.append(values[index]); if let keys { object[keys[index]] = values[index] }
        }
        let next = offset + page.count
        try checkCancellation()
        return .init(resultSHA256: source.sha256, resultKey: resultKey, fields: source.fields,
                     offset: offset, totalItems: values.count, returnedItems: page.count,
                     nextOffset: next < values.count ? next : nil,
                     selectionComplete: offset == 0 && next == values.count,
                     requiresResultKey: false, value: keys == nil ? .array(page) : .object(object))
    }
    /// CSV exports only the explicitly selected actual numeric table. Nulls
    /// remain empty cells; strings/ragged/nested data fail, never become zero.
    public static func numericCSV(_ result: JSONValue, resultKey: String,
                                  checkCancellation: @Sendable () throws -> Void = {}) throws -> NumericTable {
        try checkCancellation()
        guard case .object(let fields) = result, let selected = fields[resultKey],
              case .array(let values) = selected, !values.isEmpty, values.count <= 500_000 else {
            throw ChemistryError.invalid("CSV requires a nonempty numeric array/table selected by an exact resultKey; use JSON for other results.")
        }
        let columns: [String]
        switch values[0] {
        case .number, .null: columns = ["value"]
        case .array(let row): columns = row.indices.map { "value" + String($0 + 1) }
        case .object(let row): columns = row.keys.sorted()
        default: throw ChemistryError.invalid("CSV supports only finite numbers and null cells; export strings or nested results as JSON.")
        }
        guard (1...256).contains(columns.count) else { throw ChemistryError.invalid("CSV requires 1...256 explicit numeric columns.") }
        func quote(_ value: String) -> String {
            guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" }) else { return value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var data = Data((columns.map(quote).joined(separator: ",") + "\r\n").utf8)
        for (index, value) in values.enumerated() {
            if index.isMultiple(of: 256) { try checkCancellation() }
            let row: [JSONValue]
            switch value {
            case .number, .null:
                switch values[0] { case .number, .null: break; default: throw ChemistryError.invalid("CSV rows have inconsistent shapes.") }; row = [value]
            case .array(let cells):
                guard case .array = values[0], cells.count == columns.count else { throw ChemistryError.invalid("CSV rows have inconsistent shapes.") }; row = cells
            case .object(let cells):
                guard case .object = values[0], cells.keys.sorted() == columns else { throw ChemistryError.invalid("CSV rows have inconsistent columns.") }; row = columns.map { cells[$0]! }
            default: throw ChemistryError.invalid("CSV rows must be a consistent numeric table.")
            }
            let text = try row.map { cell -> String in
                switch cell {
                case .number(let value): guard value.isFinite else { throw ChemistryError.invalid("CSV numbers must be finite.") }; return String(value)
                case .null: return ""
                default: throw ChemistryError.invalid("CSV cells must be finite numbers or null; no coercion is performed.")
                }
            }.joined(separator: ",") + "\r\n"
            guard text.utf8.count <= maximumResultBytes - data.count else { throw ChemistryError.invalid("CSV exceeds its 64 MiB export budget.") }
            data.append(contentsOf: text.utf8)
        }
        try checkCancellation()
        return .init(columns: columns, rowCount: values.count, csv: data)
    }
    private static func kind(_ value: JSONValue) -> String { switch value {
        case .null: "null"; case .bool: "boolean"; case .number: "number"; case .string: "string"; case .array: "array"; case .object: "object" } }
    private static func count(_ value: JSONValue) -> Int? { switch value {
        case .array(let items): items.count; case .object(let fields): fields.count; default: nil } }
}
