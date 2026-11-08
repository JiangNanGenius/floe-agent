// FloeDocuments — document.readSheet agent tool.
//
// Reads saved XLSX values, or exact CSV/TSV records with revision-fenced paging.
// Formula evaluation and the semantic LibreOffice surface remain out of scope
// on iOS; cached formula values written by the workbook producer are readable.

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Crypto
import ZIPFoundation
import FloeCore
import FloeTools
import FloeWorkspace

/// Reads a spreadsheet's cell values into a text grid.
public struct DocumentReadSheetTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var sheet: String?
        public var maxRows: Int?
        public var offset: Int?
        public var expectedSHA256: String?
        public var hasHeader: Bool?
        public var encoding: ReaderTextEncoding?
        public var numericColumns: [Int]?
        public var analysis: DelimitedSheetOutput.Analysis?
        public var missingPolicy: DelimitedSheetOutput.MissingPolicy?
        public var binCount: Int?

        public init(path: String, sheet: String? = nil, maxRows: Int? = nil,
                    offset: Int? = nil, expectedSHA256: String? = nil, hasHeader: Bool? = nil,
                    encoding: ReaderTextEncoding? = nil, numericColumns: [Int]? = nil,
                    analysis: DelimitedSheetOutput.Analysis? = nil,
                    missingPolicy: DelimitedSheetOutput.MissingPolicy? = nil, binCount: Int? = nil) {
            self.path = path
            self.sheet = sheet
            self.maxRows = maxRows; self.offset = offset; self.expectedSHA256 = expectedSHA256
            self.hasHeader = hasHeader; self.encoding = encoding; self.numericColumns = numericColumns
            self.analysis = analysis; self.missingPolicy = missingPolicy; self.binCount = binCount
        }
    }

    public static let name = "document.readSheet"
    public static let toolDescription =
        "Read XLSX saved cells or CSV/TSV literal records. CSV/TSV returns complete structured JSON with raw strings, source SHA256/encoding/BOM, record numbers and physical source lines, total row counts and nextOffset. Continuation requires expectedSHA256 on every page; maxRows and a whole-record byte budget bound each page without skipping records. hasHeader defaults false; no type/header/formula inference. Optional numericColumns prepare current-page-only data.analyze arguments (one column, or two for linearRegression); nonempty nonnumeric values remain raw and block these arguments. Typed arguments for existing document.presentation.createInline can save actual native tables/charts, but this read creates no artifact and computes no statistics. XLSX retains its tab-separated grid and worksheet catalog. Returns a bounded worksheets JSON catalog with exact tab names, section/part and visibility; use these names rather than guessing. Pass a workspace-relative path and optionally an exact sheet name (omitting it selects the first sheet; a missing name fails, never falls back). Row output is capped. For editable fields/formulas and stable updateText IDs, use document.office.inspect."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path to an .xlsx, .csv or .tsv file"},
        "sheet": {"type": "string", "description": "XLSX only: exact sheet name; omit for the first sheet"},
        "maxRows": {"type": "integer", "minimum":1,"maximum":1000,"description": "Maximum rows to return (default 200, max 1000); CSV/TSV also uses a whole-record 16 KiB page budget"},
        "offset":{"type":"integer","minimum":0,"description":"CSV/TSV data-row offset excluding an explicit header; default zero."},
        "expectedSHA256":{"type":"string","pattern":"^[0-9a-f]{64}$","description":"CSV/TSV original source hash; required for every offset>0 page. Source changes fail, never mix pages."},
        "hasHeader":{"type":"boolean","description":"CSV/TSV only: explicitly use the first record as a header; default false."},
        "encoding":{"type":"string","enum":["utf8","utf16LittleEndian","utf16BigEndian","gb18030"],"description":"CSV/TSV only: optional explicit codec; full bytes validate and contradictory BOM fails. GB18030 requires the existing platform codec."},
        "numericColumns":{"type":"array","minItems":1,"maxItems":2,"uniqueItems":true,"items":{"type":"integer","minimum":1,"maximum":256},"description":"CSV/TSV 1-based numeric columns for RETURNED PAGE ONLY. One column, or two distinct columns x then y for linearRegression. Raw cells remain unchanged."},
        "analysis":{"type":"string","enum":["summarize","linearRegression","histogram"],"description":"Existing data.analyze operation to prepare; requires numericColumns. Default summarize."},
        "missingPolicy":{"type":"string","enum":["reject","omit"],"description":"Default reject; omit maps explicit empty cells to null with row/pair alignment preserved. Nonempty invalid numbers and missing fields still block analysis arguments."},
        "binCount":{"type":"integer","minimum":1,"maximum":128,"description":"Only for histogram."}
      },
      "required": ["path"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    public static let toolEffect: ToolEffect = .readOnly

    private let rootProvider: @Sendable () -> URL?

    public init(rootProvider: @escaping @Sendable () -> URL?) {
        self.rootProvider = rootProvider
    }

    public func validate(_ args: Arguments) throws {
        if args.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw FloeError.validationFailed("path must not be empty")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()

        guard let root = context.workspaceRootURL ?? rootProvider() else {
            return Self.output("status=error error=No workspace is open", exitStatus: 2)
        }

        do {
            try context.authorizeWorkspacePath(args.path)
            let pathGuard = WorkspacePathGuard(rootURL: root)
            let url = try pathGuard.resolve(args.path)
            let ext = url.pathExtension.lowercased()
            if ext == "csv" || ext == "tsv" {
                let canonicalPrefix = pathGuard.rootURL.path + "/"
                guard url.path.hasPrefix(canonicalPrefix) else { throw WorkspaceToolError.escapesRoot(args.path) }
                try context.authorizeWorkspacePath(String(url.path.dropFirst(canonicalPrefix.count)))
                let bytes = try await NativeValuePreparation.run {
                    try DelimitedSheetOutput.prepare(args, pathGuard: pathGuard, context: context)
                }
                try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
                try context.authorizeWorkspacePath(args.path)
                return ToolExecutionOutput(digesting: String(decoding: bytes, as: UTF8.self), exitStatus: 0,
                                           maximumSummaryCharacters: 96 * 1_024)
            }
            guard ext == "xlsx" else {
                return Self.output("status=error error=document.readSheet only supports .xlsx, .csv and .tsv files", exitStatus: 2)
            }
            guard args.offset == nil, args.expectedSHA256 == nil, args.hasHeader == nil, args.encoding == nil,
                  args.numericColumns == nil, args.analysis == nil, args.missingPolicy == nil, args.binCount == nil else {
                throw FloeError.validationFailed("CSV/TSV paging and numeric selection options do not apply to XLSX.")
            }
            try pathGuard.assertReadableSize(url)
            let limit = min(max(1, args.maxRows ?? 200), 1000)
            let grid = try XLSXValueReader(url: url).read(sheetNamed: args.sheet, maxRows: limit)
            let quotedName = OfficeWorksheetToolMetadata.quoted(grid.sheetName)
            let selectedSheet = quotedName.utf8.count <= 2_048 ? "sheet=\(quotedName)" : "sheetNameOmitted=true"
            var summary = "\(selectedSheet) rows=\(grid.rowCount) shown=\(grid.rows.count)\n"
            summary += grid.worksheetMetadata + "\n"
            summary += grid.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            return Self.output(summary, exitStatus: 0)
        } catch let failure as DelimitedTable.Failure {
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(DelimitedSheetOutput.FailureReceipt(status: "error", path: args.path, failure: failure))
            return Self.output(String(decoding: bytes, as: UTF8.self), exitStatus: 2)
        } catch {
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        return ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }
}

private struct XLSXGrid {
    let sheetName: String
    let worksheetMetadata: String
    let rowCount: Int
    let rows: [[String]]
}

private enum XLSXReadError: LocalizedError {
    case invalidWorkbook(String)
    case oversizedEntry(String)
    case sheetNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidWorkbook(let detail): "Invalid .xlsx workbook: \(detail)"
        case .oversizedEntry(let path): "Workbook entry is too large: \(path)"
        case .sheetNotFound(let metadata): "Worksheet not found. Use an exact name from worksheets.items; no other sheet was read.\n\(metadata)"
        }
    }
}

/// A deliberately small OOXML reader. It reads only workbook metadata,
/// shared strings, and cached cell values; it never evaluates formulas.
private struct XLSXValueReader {
    private static let metadataLimit: UInt32 = 1 * 1_024 * 1_024
    private static let sharedStringsLimit: UInt32 = 8 * 1_024 * 1_024
    private static let worksheetLimit: UInt32 = 16 * 1_024 * 1_024
    private static let maximumColumns = 256

    private let archive: Archive

    init(url: URL) throws {
        self.archive = try Archive(url: url, accessMode: .read)
    }

    func read(sheetNamed requestedName: String?, maxRows: Int) throws -> XLSXGrid {
        let workbookData = try data(at: "xl/workbook.xml", limit: Self.metadataLimit)
        let workbookParser = WorkbookXMLParser()
        try workbookParser.parse(workbookData)
        guard !workbookParser.sheets.isEmpty, !workbookParser.invalidSheet else {
            throw XLSXReadError.invalidWorkbook("workbook has no sheets")
        }

        let relationsData = try data(at: "xl/_rels/workbook.xml.rels", limit: Self.metadataLimit)
        let relationsParser = WorkbookRelationsXMLParser()
        try relationsParser.parse(relationsData)
        let metadata = OfficeWorksheetToolMetadata.line(workbookParser.sheets.map { sheet in
            let part = relationsParser.targets[sheet.relationshipID].flatMap(Self.normalizedWorksheetPath)
            return .init(
                name: sheet.name,
                section: part.map { "Sheet \(OfficePathOrder.trailingNumber($0) ?? 0)" },
                part: part,
                visibility: sheet.visibility
            )
        })
        let selected: WorkbookSheet
        if let requestedName {
            guard let match = workbookParser.sheets.first(where: { $0.name == requestedName }) else {
                throw XLSXReadError.sheetNotFound(metadata)
            }
            selected = match
        } else {
            selected = workbookParser.sheets[0]
        }

        guard let rawTarget = relationsParser.targets[selected.relationshipID],
              let worksheetPath = Self.normalizedWorksheetPath(rawTarget) else {
            throw XLSXReadError.invalidWorkbook("worksheet relationship is missing or unsafe")
        }

        var sharedStrings: [String] = []
        if archive["xl/sharedStrings.xml"] != nil {
            let stringsData = try data(at: "xl/sharedStrings.xml", limit: Self.sharedStringsLimit)
            let stringsParser = SharedStringsXMLParser()
            try stringsParser.parse(stringsData)
            sharedStrings = stringsParser.values
        }

        let worksheetData = try data(at: worksheetPath, limit: Self.worksheetLimit)
        let worksheetParser = WorksheetXMLParser(
            sharedStrings: sharedStrings,
            maximumRows: maxRows,
            maximumColumns: Self.maximumColumns
        )
        try worksheetParser.parse(worksheetData)
        return XLSXGrid(
            sheetName: selected.name,
            worksheetMetadata: metadata,
            rowCount: worksheetParser.rowCount,
            rows: worksheetParser.renderedRows()
        )
    }

    private func data(at path: String, limit: UInt32) throws -> Data {
        guard let entry = archive[path] else {
            throw XLSXReadError.invalidWorkbook("missing \(path)")
        }
        guard entry.uncompressedSize <= limit else {
            throw XLSXReadError.oversizedEntry(path)
        }
        var result = Data()
        result.reserveCapacity(Int(entry.uncompressedSize))
        _ = try archive.extract(entry) { chunk in
            guard result.count <= Int(limit) - chunk.count else {
                throw XLSXReadError.oversizedEntry(path)
            }
            result.append(chunk)
        }
        return result
    }

    private static func normalizedWorksheetPath(_ target: String) -> String? {
        let decoded = target.removingPercentEncoding ?? target
        let candidate = decoded.hasPrefix("/")
            ? String(decoded.dropFirst())
            : "xl/\(decoded)"
        let components = candidate.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count >= 2,
              components.first == "xl",
              !components.contains(".."),
              !components.contains(".") else { return nil }
        return components.joined(separator: "/")
    }
}

struct WorkbookSheet {
    let name: String
    let relationshipID: String
    let visibility: String
}

class XMLCollector: NSObject, XMLParserDelegate {
    private var parseError: Error?

    final func parse(_ data: Data) throws {
        guard data.range(of: Data("<!DOCTYPE".utf8)) == nil else {
            throw XLSXReadError.invalidWorkbook("DOCTYPE declarations are not allowed")
        }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else {
            throw parseError ?? parser.parserError
                ?? XLSXReadError.invalidWorkbook("malformed XML")
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        self.parseError = parseError
    }

    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) {
        self.parseError = validationError
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {}

    func parser(_ parser: XMLParser, foundCharacters string: String) {}

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {}
}

final class WorkbookXMLParser: XMLCollector {
    private(set) var sheets: [WorkbookSheet] = []
    private(set) var invalidSheet = false

    override func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "sheet" else { return }
        guard let name = attributeDict["name"], !name.isEmpty,
              let relationshipID = attributeDict["r:id"] ?? attributeDict["id"] else {
            invalidSheet = true
            return
        }
        sheets.append(WorkbookSheet(name: name, relationshipID: relationshipID, visibility: attributeDict["state"] ?? "visible"))
    }
}

private final class WorkbookRelationsXMLParser: XMLCollector {
    private(set) var targets: [String: String] = [:]

    override func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "Relationship",
              let identifier = attributeDict["Id"],
              let target = attributeDict["Target"] else { return }
        targets[identifier] = target
    }
}

private final class SharedStringsXMLParser: XMLCollector {
    private(set) var values: [String] = []
    private var insideItem = false
    private var insideText = false
    private var current = ""

    override func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "si" {
            insideItem = true
            current = ""
        } else if insideItem, elementName == "t" {
            insideText = true
        }
    }

    override func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideItem, insideText { current += string }
    }

    override func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "t" {
            insideText = false
        } else if elementName == "si" {
            values.append(current)
            insideItem = false
        }
    }
}

private final class WorksheetXMLParser: XMLCollector {
    private let sharedStrings: [String]
    private let maximumRows: Int
    private let maximumColumns: Int
    private var cells: [Int: [Int: String]] = [:]
    private var currentReference: String?
    private var currentType: String?
    private var currentValue = ""
    private var currentFormula = ""
    private var collectingValue = false
    private var collectingFormula = false
    private var collectingInlineText = false
    private(set) var rowCount = 0

    init(sharedStrings: [String], maximumRows: Int, maximumColumns: Int) {
        self.sharedStrings = sharedStrings
        self.maximumRows = maximumRows
        self.maximumColumns = maximumColumns
    }

    override func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "row":
            if let raw = attributeDict["r"], let row = Int(raw) {
                rowCount = max(rowCount, row)
            }
        case "c":
            currentReference = attributeDict["r"]
            currentType = attributeDict["t"]
            currentValue = ""
            currentFormula = ""
        case "v":
            collectingValue = currentReference != nil
        case "f":
            collectingFormula = currentReference != nil
        case "t":
            collectingInlineText = currentReference != nil && currentType == "inlineStr"
        default:
            break
        }
    }

    override func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingValue || collectingInlineText || collectingFormula { currentValue += string }
    }

    override func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "v" { collectingValue = false }
        if elementName == "t" { collectingInlineText = false }
        if elementName == "f" {
            collectingFormula = false
            currentFormula = currentValue
            currentValue = ""
        }
        guard elementName == "c", let reference = currentReference else { return }
        defer {
            currentReference = nil
            currentType = nil
            currentValue = ""
            currentFormula = ""
        }
        guard let (row, column) = Self.cellPosition(reference),
              row <= maximumRows,
              column < maximumColumns else { return }
        rowCount = max(rowCount, row)
        // One shared decoder with office.inspect: formulas display as
        // "=FORMULA" (cached values are not trusted) and shared strings,
        // booleans and inline strings decode identically in both readers.
        cells[row, default: [:]][column] = OOXMLCellDecoder.displayValue(
            type: currentType,
            rawValue: currentValue,
            formula: currentFormula,
            sharedStrings: sharedStrings
        )
    }

    func renderedRows() -> [[String]] {
        guard rowCount > 0 else { return [] }
        return (1...min(rowCount, maximumRows)).map { row in
            guard let rowCells = cells[row], let lastColumn = rowCells.keys.max() else { return [] }
            return (0...lastColumn).map { rowCells[$0] ?? "" }
        }
    }

    private static func cellPosition(_ reference: String) -> (row: Int, column: Int)? {
        var column = 0
        var index = reference.startIndex
        var sawLetter = false
        while index < reference.endIndex, let scalar = reference[index].unicodeScalars.first {
            let value = scalar.value
            guard value >= 65, value <= 90 else { break }
            sawLetter = true
            column = column * 26 + Int(value - 64)
            index = reference.index(after: index)
        }
        guard sawLetter, let row = Int(reference[index...]), row > 0 else { return nil }
        return (row, column - 1)
    }
}

/// Registers the document tools. `rootProvider` supplies the workspace root.
@discardableResult
public func registerDocumentTools(
    registry: ToolRunnerRegistry = .shared,
    rootProvider: @escaping @Sendable () -> URL?
) -> (@Sendable () -> URL?) {
    ToolCatalog.register(DocumentReadSheetTool.self)
    ToolCatalog.register(OfficeInspectTool.self)
    ToolCatalog.register(OfficeUpdateTextTool.self)
    ToolCatalog.register(DocumentCreateWordTool.self)
    ToolCatalog.register(DocumentCreateWorkbookTool.self)
    ToolCatalog.register(DocumentCreateTool.self)
    ToolCatalog.register(PresentationCreateDeckTool.self)
    ToolCatalog.register(OfficeCapabilitiesTool.self)
    registry.register(DocumentReadSheetTool(rootProvider: rootProvider))
    registry.register(OfficeInspectTool(rootProvider: rootProvider))
    registry.register(OfficeUpdateTextTool(rootProvider: rootProvider))
    registry.register(DocumentCreateWordTool(rootProvider: rootProvider))
    registry.register(DocumentCreateWorkbookTool(rootProvider: rootProvider))
    registry.register(DocumentCreateTool(rootProvider: rootProvider))
    registry.register(PresentationCreateDeckTool(rootProvider: rootProvider))
    registry.register(OfficeCapabilitiesTool())
    return rootProvider
}
