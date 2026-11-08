// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Strict comma/tab records. Raw cell strings are never trimmed or inferred.
/// Record numbers and physical source lines are one based, including a header.
public enum DelimitedTable {
    public enum Delimiter: String, Codable, Sendable { case comma, tab
        var byte: UInt8 { self == .comma ? 44 : 9 }
    }
    public struct Record: Codable, Sendable, Equatable {
        public let number: Int
        public let lineStart: Int
        public let lineEnd: Int
        public let cells: [String]
        public init(number: Int, lineStart: Int, lineEnd: Int, cells: [String]) {
            self.number = number; self.lineStart = lineStart; self.lineEnd = lineEnd; self.cells = cells
        }
    }
    public struct Failure: Error, LocalizedError, Codable, Sendable, Equatable {
        public let code: String
        public let message: String
        public let record: Int?
        public let line: Int?
        /// One based Unicode-scalar column in the decoded physical line.
        public let column: Int?
        public init(_ code: String, _ message: String, record: Int? = nil, line: Int? = nil, column: Int? = nil) {
            self.code = code; self.message = message; self.record = record; self.line = line; self.column = column
        }
        public var errorDescription: String? {
            message + (line.map { " (record \(record ?? 0), line \($0), column \(column ?? 0))" } ?? "")
        }
    }
    public static let maximumRecords = 200_000
    public static let maximumColumns = 256
    public static let maximumCells = 1_000_000
    public static let maximumFieldBytes = 64 * 1_024
    public static let maximumRecordBytes = 128 * 1_024

    /// Scans the complete bounded text, retaining only one record at a time.
    /// Empty records, final empty fields, CR/LF/CRLF inside quotes and doubled
    /// quotes are preserved. A final record terminator creates no phantom row.
    public static func scan(_ text: String, delimiter: Delimiter,
                            checkCancellation: @Sendable () throws -> Void = {},
                            record receive: (Record) throws -> Void) throws {
        enum State { case start, plain, quoted, closed }
        let bytes = Array(text.utf8)
        var state = State.start, fields: [String] = [], field: [UInt8] = []
        var i = 0, line = 1, column = 1, firstLine = 1, number = 1
        var active = false, recordBytes = 0, totalCells = 0
        func fail(_ code: String, _ detail: String) -> Failure {
            Failure(code, detail, record: number, line: line, column: column)
        }
        func finishField() throws {
            guard fields.count < maximumColumns else { throw fail("column_limit", "A record exceeds 256 columns.") }
            fields.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true)
        }
        func finishRecord() throws {
            try checkCancellation()
            guard number <= maximumRecords else { throw fail("record_limit", "CSV exceeds 200000 records.") }
            try finishField(); totalCells += fields.count
            guard totalCells <= maximumCells else { throw fail("cell_limit", "CSV exceeds 1000000 cells.") }
            try receive(Record(number: number, lineStart: firstLine, lineEnd: line, cells: fields))
            fields.removeAll(keepingCapacity: true); number += 1; recordBytes = 0; active = false; state = .start
        }
        while i < bytes.count {
            if i & 4_095 == 0 { try checkCancellation() }
            let b = bytes[i]
            guard b != 0 else { throw fail("nul_character", "CSV contains a NUL character.") }
            recordBytes += 1
            guard recordBytes <= maximumRecordBytes else { throw fail("record_size_limit", "A CSV record exceeds 128 KiB.") }
            if b == 13 || b == 10 {
                let crlf = b == 13 && i + 1 < bytes.count && bytes[i + 1] == 10
                if state == .quoted {
                    field.append(b)
                    if crlf {
                        field.append(10); recordBytes += 1
                        guard recordBytes <= maximumRecordBytes else { throw fail("record_size_limit", "A CSV record exceeds 128 KiB.") }
                    }
                } else { try finishRecord() }
                i += crlf ? 2 : 1; line += 1; column = 1
                if state != .quoted { firstLine = line }
            } else {
                active = true
                if b == delimiter.byte && state != .quoted {
                    try finishField(); state = .start
                } else if b == 34 {
                    switch state {
                    case .start: state = .quoted
                    case .plain: throw fail("unexpected_quote", "A quote is only valid at the beginning of a field.")
                    case .quoted: state = .closed
                    case .closed: field.append(34); state = .quoted
                    }
                } else {
                    guard state != .closed else { throw fail("after_quote", "Only a delimiter or record terminator may follow a closing quote.") }
                    if state == .start { state = .plain }
                    field.append(b)
                }
                i += 1
                if b & 0xC0 != 0x80 { column += 1 }
            }
            guard field.count <= maximumFieldBytes else { throw fail("field_size_limit", "A CSV field exceeds 64 KiB.") }
        }
        try checkCancellation()
        guard state != .quoted else { throw fail("unterminated_quote", "The quoted field is not terminated.") }
        if active || !fields.isEmpty || !field.isEmpty { try finishRecord() }
    }

    public struct Page: Codable, Sendable {
        public let header: Record?
        public let rows: [Record]
        public let totalRecords: Int
        public let totalDataRows: Int
        public let offset: Int
        public let nextOffset: Int?
        public let wholeFileData: Bool
    }

    /// Whole-record paging, never substring or cell truncation. The budget
    /// includes actual JSON escaping of raw values and origin metadata.
    public static func page(_ text: String, delimiter: Delimiter, hasHeader: Bool,
                            offset: Int, limit: Int, maximumPageBytes: Int = 48 * 1_024,
                            checkCancellation: @Sendable () throws -> Void = {}) throws -> Page {
        guard offset >= 0, (1...1_000).contains(limit), maximumPageBytes >= 256 else {
            throw Failure("invalid_page", "offset must be nonnegative; maxRows must be 1...1000.")
        }
        var header: Record?, rows: [Record] = []
        var records = 0, dataRows = 0, size = 0, full = false
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try scan(text, delimiter: delimiter, checkCancellation: checkCancellation) { row in
            records += 1
            if hasHeader && records == 1 {
                header = row; size = try encoder.encode(row).count
                guard size < maximumPageBytes else { throw Failure("header_size_limit", "The complete header exceeds the page budget.", record: row.number, line: row.lineStart) }
                return
            }
            let index = dataRows; dataRows += 1
            guard index >= offset, rows.count < limit, !full else { return }
            let bytes = try encoder.encode(row).count + 1
            if size + bytes > maximumPageBytes {
                guard !rows.isEmpty else { throw Failure("page_record_size_limit", "The next complete record does not fit the page budget.", record: row.number, line: row.lineStart) }
                full = true; return
            }
            size += bytes; rows.append(row)
        }
        guard offset <= dataRows else { throw Failure("offset_out_of_range", "offset exceeds the actual data row count.") }
        let end = offset + rows.count
        return Page(header: header, rows: rows, totalRecords: records, totalDataRows: dataRows,
                    offset: offset, nextOffset: end < dataRows ? end : nil,
                    wholeFileData: offset == 0 && end == dataRows)
    }
}
