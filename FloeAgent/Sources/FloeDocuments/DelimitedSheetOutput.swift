// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools
import FloeWorkspace

/// Typed read values and interoperable arguments for EXISTING native tools.
/// This read never creates an artifact or claims an analysis has already run.
public enum DelimitedSheetOutput {
    public enum Analysis: String, Codable, Sendable { case summarize, linearRegression, histogram }
    public enum MissingPolicy: String, Codable, Sendable { case reject, omit }
    public struct NumericArguments: Codable, Sendable {
        public let action: Analysis
        public let values: [Double?]
        public let pairedValues: [Double?]?
        public let missingPolicy: MissingPolicy
        public let binCount: Int?
    }
    public struct NumericIssue: Codable, Sendable {
        public let record: Int
        public let lineStart: Int
        public let column: Int
        public let rawValue: String?
        public let code: String
    }
    public struct NumericSelection: Codable, Sendable {
        public let scope: String
        public let columns: [Int]
        public let recordNumbers: [Int]
        public let issueCount: Int
        public let issues: [NumericIssue]
        public let issuesTruncated: Bool
        public let arguments: NumericArguments?
        public let policy: String
    }
    public struct TableArguments: Codable, Sendable {
        public let kind: String
        public let title: String
        public let columns: [String]
        public let rows: [[String]]
    }
    public struct ChartArguments: Codable, Sendable {
        public struct Point: Codable, Sendable { public let label: String; public let value: Double }
        public struct Series: Codable, Sendable { public let name: String; public let points: [Point] }
        public let kind: String
        public let title: String
        public let chartType: String
        public let series: [Series]
    }
    public struct Presentation: Codable, Sendable {
        public let tableArguments: TableArguments?
        public let tableUnavailable: String?
        public let chartArguments: ChartArguments?
        public let chartUnavailable: String?
        public let scope: String
        public let chartAxis: String
    }
    public struct Receipt: Codable, Sendable {
        public let format: String
        public let schemaVersion: Int
        public let source: WorkspaceDelimitedFile.Source
        public let delimiter: DelimitedTable.Delimiter
        public let taskID: UUID?
        public let runID: UUID
        public let callID: String?
        public let environmentID: String?
        public let page: DelimitedTable.Page
        public let numericSelection: NumericSelection?
        public let presentation: Presentation
        public let valuePolicy: String
    }
    public struct FailureReceipt: Codable, Sendable {
        public let status: String
        public let path: String
        public let failure: DelimitedTable.Failure
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return try encoder.encode(value)
    }
    static func prepare(_ args: DocumentReadSheetTool.Arguments, pathGuard: WorkspacePathGuard,
                        context: ToolContext) throws -> Data {
        try validate(args)
        return try WorkspaceDelimitedFile.read(path: args.path, pathGuard: pathGuard, encoding: args.encoding,
                expectedSHA256: args.expectedSHA256,
                checkCancellation: { try context.cancellation.throwIfCancelled(); try Task.checkCancellation() },
                authorizeResolved: { url in
                    let prefix = pathGuard.rootURL.path + "/"
                    guard url.path.hasPrefix(prefix) else { throw WorkspaceToolError.escapesRoot(args.path) }
                    try context.authorizeWorkspacePath(String(url.path.dropFirst(prefix.count)))
                }) { source, text in
            let delimiter: DelimitedTable.Delimiter = URL(fileURLWithPath: source.resolvedWorkspacePath).pathExtension.lowercased() == "tsv" ? .tab : .comma
            let page = try DelimitedTable.page(text, delimiter: delimiter, hasHeader: args.hasHeader ?? false,
                offset: args.offset ?? 0, limit: args.maxRows ?? 200, maximumPageBytes: 16 * 1_024,
                checkCancellation: { try context.cancellation.throwIfCancelled(); try Task.checkCancellation() })
            let numeric = args.numericColumns.map { numericSelection(page: page, columns: $0,
                action: args.analysis ?? .summarize, missingPolicy: args.missingPolicy ?? .reject, binCount: args.binCount) }
            let presentation = presentations(page: page, source: source, numeric: numeric)
            let receipt = Receipt(format: "org.floe.delimited-sheet", schemaVersion: 1, source: source, delimiter: delimiter,
                taskID: context.conversationID, runID: context.runID, callID: context.toolCallID,
                environmentID: context.environmentID, page: page, numericSelection: numeric, presentation: presentation,
                valuePolicy: "Raw strings, empty fields and records remain unchanged. hasHeader is explicit. No formula evaluation, type inference, trimming, imputation or unit conversion. Analysis and presentation arguments cover returned rows only; invoke the existing tools to compute or save them.")
            let bytes = try encode(receipt)
            guard bytes.count <= 96 * 1_024 else { throw DelimitedTable.Failure("receipt_size_limit", "Request fewer maxRows; the complete typed page exceeds 96 KiB.") }
            return bytes
        }
    }
    static func validate(_ args: DocumentReadSheetTool.Arguments) throws {
        guard args.sheet == nil else { throw DelimitedTable.Failure("invalid_arguments", "sheet applies only to XLSX; CSV/TSV use explicit hasHeader and row offset.") }
        guard (args.offset ?? 0) >= 0, (1...1_000).contains(args.maxRows ?? 200) else {
            throw DelimitedTable.Failure("invalid_arguments", "offset must be nonnegative and maxRows must be 1...1000.")
        }
        if let hash = args.expectedSHA256 {
            guard hash.utf8.count == 64, hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw DelimitedTable.Failure("invalid_arguments", "expectedSHA256 must be the exact lowercase source SHA256.")
            }
        }
        guard (args.offset ?? 0) == 0 || args.expectedSHA256 != nil else {
            throw DelimitedTable.Failure("missing_revision", "Every continuation page requires expectedSHA256 from the previous page.")
        }
        if let columns = args.numericColumns {
            let action = args.analysis ?? .summarize
            guard columns.count == (action == .linearRegression ? 2 : 1), Set(columns).count == columns.count,
                  columns.allSatisfy({ (1...DelimitedTable.maximumColumns).contains($0) }) else {
                throw DelimitedTable.Failure("invalid_arguments", "Select one 1-based numeric column, or two distinct columns for linearRegression (x then y).")
            }
            if let bins = args.binCount, action != .histogram || !(1...128).contains(bins) {
                throw DelimitedTable.Failure("invalid_arguments", "binCount is only for histogram, in 1...128.")
            }
        } else if args.analysis != nil || args.missingPolicy != nil || args.binCount != nil {
            throw DelimitedTable.Failure("invalid_arguments", "Analysis options require explicit numericColumns.")
        }
    }
    private static func numericSelection(page: DelimitedTable.Page, columns: [Int], action: Analysis,
                                         missingPolicy: MissingPolicy, binCount: Int?) -> NumericSelection {
        var values: [[Double?]] = Array(repeating: [], count: columns.count)
        var issues: [NumericIssue] = [], count = 0
        for row in page.rows {
            for (series, column) in columns.enumerated() {
                let raw = column <= row.cells.count ? row.cells[column - 1] : nil
                let number = raw.flatMap(decimal)
                values[series].append(number)
                let code: String?
                if raw == nil { code = "missing_field" }
                else if raw == "" { code = missingPolicy == .omit ? nil : "empty_requires_omit" }
                else { code = number == nil ? "not_finite_decimal" : nil }
                if let code {
                    count += 1
                    if issues.count < 32 { issues.append(.init(record: row.number, lineStart: row.lineStart, column: column, rawValue: raw, code: code)) }
                }
            }
        }
        let arguments: NumericArguments? = count == 0 && !page.rows.isEmpty
            ? .init(action: action, values: values[0], pairedValues: columns.count == 2 ? values[1] : nil,
                    missingPolicy: missingPolicy, binCount: binCount) : nil
        return .init(scope: "returned-page-only", columns: columns, recordNumbers: page.rows.map(\.number),
            issueCount: count, issues: issues, issuesTruncated: count > issues.count, arguments: arguments,
            policy: "Decimal/scientific numeric text only, finite magnitude <=1e100, without trimming. Originals remain unchanged. Only explicit empty cells become null with missingPolicy=omit; paired row alignment is retained. No statistics for unreturned rows.")
    }
    private static func decimal(_ raw: String) -> Double? {
        guard let matched = raw.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression),
              matched == raw.startIndex..<raw.endIndex,
              let value = Double(raw), value.isFinite, abs(value) <= 1e100 else { return nil }
        // Do not silently replace a nonzero decimal below Double's range by zero.
        if value == 0, raw.prefix(while: { $0 != "e" && $0 != "E" }).utf8.contains(where: { (49...57).contains($0) }) { return nil }
        return value
    }
    private static func presentations(page: DelimitedTable.Page, source: WorkspaceDelimitedFile.Source,
                                      numeric: NumericSelection?) -> Presentation {
        let width = page.header?.cells.count ?? page.rows.first?.cells.count ?? 0
        let names = page.header?.cells ?? (0..<width).map { "Column \($0 + 1)" }
        let range = page.rows.isEmpty ? "no data rows" : "rows \(page.offset + 1)–\(page.offset + page.rows.count)"
        let title = String(URL(fileURLWithPath: source.path).lastPathComponent.prefix(100)) + " · " + range
        let table: TableArguments?
        let tableProblem: String?
        if width > 0, width <= 32, page.rows.count <= 500, names.allSatisfy({ $0.count <= 200 }),
           page.rows.allSatisfy({ $0.cells.count == width && $0.cells.allSatisfy { $0.count <= 1_000 } }) {
            table = .init(kind: "table", title: title, columns: names, rows: page.rows.map(\.cells)); tableProblem = nil
        } else {
            table = nil; tableProblem = "The page must have 1...32 columns, at most 500 rectangular rows and cells within the existing native table limits. Raw records above remain complete; no padding or truncation was applied."
        }
        var chart: ChartArguments?, chartProblem = "Select numeric columns with finite values in every returned row to prepare a native chart."
        if let numeric, let args = numeric.arguments {
            let series = [args.values, args.pairedValues].compactMap { $0 }
            if !series.isEmpty, series.reduce(0, { $0 + $1.count }) <= 2_000, series.allSatisfy({ $0.allSatisfy { $0 != nil } }) {
                chart = .init(kind: "chart", title: title, chartType: "line", series: series.enumerated().map { index, values in
                    .init(name: "Column \(numeric.columns[index])", points: zip(page.rows, values).map { row, value in
                        .init(label: "Record \(row.number)", value: value!)
                    })
                }); chartProblem = ""
            } else { chartProblem = "Native chart points require finite values; nulls and gaps were not silently dropped or interpolated." }
        }
        return .init(tableArguments: table, tableUnavailable: tableProblem, chartArguments: chart,
            chartUnavailable: chart == nil ? chartProblem : nil, scope: "returned-page-only",
            chartAxis: "Categorical source record number; not an inferred numeric x-axis or an already computed analysis.")
    }
}
