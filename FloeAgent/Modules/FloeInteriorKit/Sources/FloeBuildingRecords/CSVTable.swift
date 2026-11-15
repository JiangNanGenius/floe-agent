import Foundation

public enum CSVDelimiter: String, Codable, Sendable, Hashable, CaseIterable {
    case comma
    case tab
    case semicolon
    case pipe
    case auto

    var character: Character? {
        switch self {
        case .comma: return ","
        case .tab: return "\t"
        case .semicolon: return ";"
        case .pipe: return "|"
        case .auto: return nil
        }
    }
}

public struct CSVParseOptions: Sendable, Equatable {
    public var delimiter: CSVDelimiter
    public var hasHeaderRow: Bool
    public var maxBytes: Int
    public var maxRows: Int
    public var maxColumns: Int
    public var maxFieldCharacters: Int
    public var maxRecordCharacters: Int

    public init(
        delimiter: CSVDelimiter = .auto,
        hasHeaderRow: Bool = true,
        maxBytes: Int = 16 * 1024 * 1024,
        maxRows: Int = 20_000,
        maxColumns: Int = 128,
        maxFieldCharacters: Int = 32_768,
        maxRecordCharacters: Int = 1_048_576
    ) {
        self.delimiter = delimiter
        self.hasHeaderRow = hasHeaderRow
        self.maxBytes = maxBytes
        self.maxRows = maxRows
        self.maxColumns = maxColumns
        self.maxFieldCharacters = maxFieldCharacters
        self.maxRecordCharacters = maxRecordCharacters
    }

    func validate() throws {
        guard maxBytes > 0 else {
            throw BuildingRecordsError.invalidValue(field: "csv.maxBytes", reason: "must be positive")
        }
        guard maxRows > 0 else {
            throw BuildingRecordsError.invalidValue(field: "csv.maxRows", reason: "must be positive")
        }
        guard maxColumns > 0 else {
            throw BuildingRecordsError.invalidValue(field: "csv.maxColumns", reason: "must be positive")
        }
        guard maxFieldCharacters > 0 else {
            throw BuildingRecordsError.invalidValue(field: "csv.maxFieldCharacters", reason: "must be positive")
        }
        guard maxRecordCharacters >= maxFieldCharacters else {
            throw BuildingRecordsError.invalidValue(
                field: "csv.maxRecordCharacters",
                reason: "must be greater than or equal to maxFieldCharacters"
            )
        }
    }
}

public enum CSVParseError: Error, Equatable, Sendable {
    case emptyInput
    case noRecords
    case inputTooLarge(limit: Int, actual: Int)
    case unsupportedEncoding
    case unterminatedQuotedField(recordIndex: Int)
    case quoteInUnquotedField(recordIndex: Int)
    case unexpectedCharacterAfterClosingQuote(recordIndex: Int)
    case tooManyRows(limit: Int)
    case tooManyColumns(recordIndex: Int, limit: Int)
    case fieldTooLong(recordIndex: Int, column: Int, limit: Int)
    case recordTooLong(recordIndex: Int, limit: Int)
    case ambiguousDelimiter
}

extension CSVParseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "The CSV input is empty."
        case .noRecords:
            return "The CSV input contains no records."
        case .inputTooLarge(let limit, let actual):
            return "The CSV input is \(actual) bytes; the limit is \(limit) bytes."
        case .unsupportedEncoding:
            return "The CSV text encoding is not supported."
        case .unterminatedQuotedField(let recordIndex):
            return "Record \(recordIndex + 1) has an unterminated quoted field."
        case .quoteInUnquotedField(let recordIndex):
            return "Record \(recordIndex + 1) has a quote inside an unquoted field."
        case .unexpectedCharacterAfterClosingQuote(let recordIndex):
            return "Record \(recordIndex + 1) has data after a closing quote."
        case .tooManyRows(let limit):
            return "The CSV has more than \(limit) data rows."
        case .tooManyColumns(let recordIndex, let limit):
            return "Record \(recordIndex + 1) has more than \(limit) columns."
        case .fieldTooLong(let recordIndex, let column, let limit):
            return "Record \(recordIndex + 1), column \(column + 1) exceeds \(limit) characters."
        case .recordTooLong(let recordIndex, let limit):
            return "Record \(recordIndex + 1) exceeds \(limit) characters."
        case .ambiguousDelimiter:
            return "The CSV delimiter is ambiguous; select comma, tab, semicolon or pipe explicitly."
        }
    }
}

public struct CSVRow: Sendable, Equatable {
    /// Zero-based logical record index. When a header row is present, the
    /// header is record 0 and the first data row is record 1.
    public let recordIndex: Int
    /// One-based physical starting line in the original text, accounting for
    /// quoted newlines in previous records.
    public let startLine: Int
    public let fields: [String]
    /// Exact decoded record text excluding the record terminator. Quoted
    /// embedded newlines remain in this value.
    public let rawRecord: String

    public init(recordIndex: Int, startLine: Int, fields: [String], rawRecord: String) {
        self.recordIndex = recordIndex
        self.startLine = startLine
        self.fields = fields
        self.rawRecord = rawRecord
    }
}

public struct CSVTable: Sendable, Equatable {
    public let delimiter: CSVDelimiter
    public let header: [String]?
    public let headerRecord: CSVRow?
    public let rows: [CSVRow]
    public let columnCount: Int
    public let byteCount: Int

    public init(
        delimiter: CSVDelimiter,
        header: [String]?,
        headerRecord: CSVRow?,
        rows: [CSVRow],
        columnCount: Int,
        byteCount: Int
    ) {
        self.delimiter = delimiter
        self.header = header
        self.headerRecord = headerRecord
        self.rows = rows
        self.columnCount = columnCount
        self.byteCount = byteCount
    }
}

/// A strict, bounded CSV reader: RFC-style quoted fields with doubled quotes,
/// quoted delimiters and newlines, UTF-8 (with optional BOM) or BOM-marked
/// UTF-16, CRLF/LF/CR records, and explicit delimiter selection or detection.
///
/// The reader preserves each record's raw text. It does not silently repair
/// malformed quoting, and it rejects input beyond configured byte, row, column,
/// field or record bounds.
public enum CSVTableReader {
    public static func parse(_ data: Data, options: CSVParseOptions = CSVParseOptions()) throws -> CSVTable {
        try options.validate()
        guard !data.isEmpty else { throw CSVParseError.emptyInput }
        guard data.count <= options.maxBytes else {
            throw CSVParseError.inputTooLarge(limit: options.maxBytes, actual: data.count)
        }

        let text = try decodeText(data)
        let characters = Array(text)
        guard !characters.isEmpty else { throw CSVParseError.emptyInput }

        let delimiter = try resolveDelimiter(characters, requested: options.delimiter)
        guard let delimiterCharacter = delimiter.character else {
            throw CSVParseError.ambiguousDelimiter
        }

        var index = 0
        var line = 1
        var logicalRecordIndex = 0
        var records: [CSVRow] = []
        var header: [String]?
        var headerRecord: CSVRow?
        var columnCount = 0

        while index < characters.count {
            let recordStart = index
            let recordStartLine = line
            var fields: [String] = []
            var fieldCharacters: [Character] = []
            var fieldWasQuoted = false
            var recordHadQuotedField = false
            var inQuotes = false
            var justClosedQuote = false
            var terminated = false
            var recordBodyEnd = index

            func appendCharacter(_ character: Character) throws {
                if fieldCharacters.count >= options.maxFieldCharacters {
                    throw CSVParseError.fieldTooLong(
                        recordIndex: logicalRecordIndex,
                        column: fields.count,
                        limit: options.maxFieldCharacters
                    )
                }
                fieldCharacters.append(character)
            }

            func finishField() throws {
                if fields.count >= options.maxColumns {
                    throw CSVParseError.tooManyColumns(
                        recordIndex: logicalRecordIndex,
                        limit: options.maxColumns
                    )
                }
                fields.append(String(fieldCharacters))
                fieldCharacters.removeAll(keepingCapacity: true)
                fieldWasQuoted = false
                justClosedQuote = false
            }

            while index < characters.count {
                let character = characters[index]
                if inQuotes {
                    if character == "\"" {
                        if index + 1 < characters.count, characters[index + 1] == "\"" {
                            try appendCharacter("\"")
                            index += 2
                        } else {
                            inQuotes = false
                            justClosedQuote = true
                            index += 1
                        }
                    } else if character == "\r\n" {
                        // Swift treats CRLF as one extended grapheme cluster.
                        index += 1; line += 1
                        try appendCharacter("\n")
                    } else if character == "\r" {
                        if index + 1 < characters.count, characters[index + 1] == "\n" {
                            index += 2
                        } else {
                            index += 1
                        }
                        line += 1
                        try appendCharacter("\n")
                    } else if character == "\n" {
                        index += 1
                        line += 1
                        try appendCharacter("\n")
                    } else {
                        try appendCharacter(character)
                        index += 1
                    }
                } else {
                    if justClosedQuote {
                        if character == delimiterCharacter {
                            try finishField()
                            index += 1
                        } else if character == "\r" || character == "\n" || character == "\r\n" {
                            try finishField()
                            recordBodyEnd = index
                            terminated = true
                            if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                                index += 2
                            } else {
                                index += 1
                            }
                            line += 1
                            break
                        } else {
                            throw CSVParseError.unexpectedCharacterAfterClosingQuote(
                                recordIndex: logicalRecordIndex
                            )
                        }
                    } else if character == "\"" {
                        if fieldCharacters.isEmpty {
                            inQuotes = true
                            fieldWasQuoted = true
                            recordHadQuotedField = true
                            index += 1
                        } else {
                            throw CSVParseError.quoteInUnquotedField(recordIndex: logicalRecordIndex)
                        }
                    } else if character == delimiterCharacter {
                        try finishField()
                        index += 1
                    } else if character == "\r" || character == "\n" || character == "\r\n" {
                        try finishField()
                        recordBodyEnd = index
                        terminated = true
                        if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" {
                            index += 2
                        } else {
                            index += 1
                        }
                        line += 1
                        break
                    } else {
                        try appendCharacter(character)
                        index += 1
                    }
                }
            }

            if inQuotes {
                throw CSVParseError.unterminatedQuotedField(recordIndex: logicalRecordIndex)
            }
            if !terminated {
                if !fieldCharacters.isEmpty || !fields.isEmpty || fieldWasQuoted || justClosedQuote {
                    try finishField()
                    recordBodyEnd = characters.count
                } else {
                    // Only an empty trailing line at EOF; no record.
                    break
                }
            }

            if recordBodyEnd - recordStart > options.maxRecordCharacters {
                throw CSVParseError.recordTooLong(
                    recordIndex: logicalRecordIndex,
                    limit: options.maxRecordCharacters
                )
            }
            let rawRecord = String(characters[recordStart..<recordBodyEnd])
            let row = CSVRow(
                recordIndex: logicalRecordIndex,
                startLine: recordStartLine,
                fields: fields,
                rawRecord: rawRecord
            )

            let isBlank = fields.count == 1 && fields[0].isEmpty && !recordHadQuotedField
            if isBlank {
                continue
            }

            if options.hasHeaderRow, header == nil {
                header = fields
                headerRecord = row
                columnCount = fields.count
            } else {
                guard records.count < options.maxRows else {
                    throw CSVParseError.tooManyRows(limit: options.maxRows)
                }
                if columnCount == 0 {
                    columnCount = fields.count
                }
                records.append(row)
            }
            logicalRecordIndex += 1
        }

        guard header != nil || !records.isEmpty else {
            throw CSVParseError.noRecords
        }

        return CSVTable(
            delimiter: delimiter,
            header: header,
            headerRecord: headerRecord,
            rows: records,
            columnCount: columnCount,
            byteCount: data.count
        )
    }

    private static func decodeText(_ data: Data) throws -> String {
        let bytes = [UInt8](data)
        if bytes.count >= 2,
           (bytes[0] == 0xFF && bytes[1] == 0xFE) || (bytes[0] == 0xFE && bytes[1] == 0xFF) {
            guard let text = String(data: data, encoding: .utf16) else {
                throw CSVParseError.unsupportedEncoding
            }
            guard !text.contains("\0") else { throw CSVParseError.unsupportedEncoding }
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }

        var payload = data
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            payload = data.subdata(in: 3..<data.count)
        }
        guard let text = String(data: payload, encoding: .utf8) else {
            throw CSVParseError.unsupportedEncoding
        }
        guard !text.contains("\0") else { throw CSVParseError.unsupportedEncoding }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }

    private static func resolveDelimiter(
        _ characters: [Character],
        requested: CSVDelimiter
    ) throws -> CSVDelimiter {
        if requested != .auto {
            return requested
        }

        let candidates: [CSVDelimiter] = [.comma, .tab, .semicolon, .pipe]
        var counts: [CSVDelimiter: Int] = [:]
        for candidate in candidates { counts[candidate] = 0 }

        var index = 0
        while index < characters.count, characters[index] == "\r" || characters[index] == "\n" || characters[index] == "\r\n" {
            index += 1
        }
        guard index < characters.count else { throw CSVParseError.noRecords }

        var inQuotes = false
        while index < characters.count {
            let character = characters[index]
            if inQuotes {
                if character == "\"" {
                    if index + 1 < characters.count, characters[index + 1] == "\"" {
                        index += 2
                        continue
                    }
                    inQuotes = false
                }
            } else if character == "\"" {
                inQuotes = true
            } else if character == "\r" || character == "\n" || character == "\r\n" {
                break
            } else {
                for candidate in candidates {
                    if let candidateCharacter = candidate.character, character == candidateCharacter {
                        counts[candidate, default: 0] += 1
                    }
                }
            }
            index += 1
        }

        let ranked = counts.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key.rawValue < rhs.key.rawValue }
            return lhs.value > rhs.value
        }
        guard let first = ranked.first, first.value > 0 else {
            throw CSVParseError.ambiguousDelimiter
        }
        if ranked.count > 1, ranked[1].value == first.value {
            throw CSVParseError.ambiguousDelimiter
        }
        return first.key
    }
}
