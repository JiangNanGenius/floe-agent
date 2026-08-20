// FloeDocuments — document.readSheet agent tool.
//
// Reads saved values from an .xlsx workbook into a tab-separated text grid.
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

        public init(path: String, sheet: String? = nil, maxRows: Int? = nil) {
            self.path = path
            self.sheet = sheet
            self.maxRows = maxRows
        }
    }

    public static let name = "document.readSheet"
    public static let toolDescription =
        "Read an .xlsx spreadsheet's cell values as a tab-separated text grid. Pass a workspace-relative path and optionally a sheet name (defaults to the first sheet). Row output is capped to avoid huge responses."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path to the .xlsx file"},
        "sheet": {"type": "string", "description": "Sheet name; omit for the first sheet"},
        "maxRows": {"type": "integer", "description": "Maximum rows to return (default 200, max 1000)"}
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
            guard url.pathExtension.lowercased() == "xlsx" else {
                return Self.output("status=error error=document.readSheet only supports .xlsx files", exitStatus: 2)
            }
            try pathGuard.assertReadableSize(url)
            let limit = min(max(1, args.maxRows ?? 200), 1000)
            let grid = try XLSXValueReader(url: url).read(sheetNamed: args.sheet, maxRows: limit)
            var summary = "sheet=\(grid.sheetName) rows=\(grid.rowCount) shown=\(grid.rows.count)\n"
            summary += grid.rows.map { $0.joined(separator: "\t") }.joined(separator: "\n")
            return Self.output(summary, exitStatus: 0)
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }
}

private struct XLSXGrid {
    let sheetName: String
    let rowCount: Int
    let rows: [[String]]
}

private enum XLSXReadError: LocalizedError {
    case invalidWorkbook(String)
    case oversizedEntry(String)

    var errorDescription: String? {
        switch self {
        case .invalidWorkbook(let detail): "Invalid .xlsx workbook: \(detail)"
        case .oversizedEntry(let path): "Workbook entry is too large: \(path)"
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
        guard !workbookParser.sheets.isEmpty else {
            throw XLSXReadError.invalidWorkbook("workbook has no sheets")
        }

        let selected: WorkbookSheet
        if let requestedName {
            guard let match = workbookParser.sheets.first(where: { $0.name == requestedName }) else {
                throw XLSXReadError.invalidWorkbook("sheet '\(requestedName)' not found")
            }
            selected = match
        } else {
            selected = workbookParser.sheets[0]
        }

        let relationsData = try data(at: "xl/_rels/workbook.xml.rels", limit: Self.metadataLimit)
        let relationsParser = WorkbookRelationsXMLParser()
        try relationsParser.parse(relationsData)
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

private struct WorkbookSheet {
    let name: String
    let relationshipID: String
}

private class XMLCollector: NSObject, XMLParserDelegate {
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

private final class WorkbookXMLParser: XMLCollector {
    private(set) var sheets: [WorkbookSheet] = []

    override func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard elementName == "sheet",
              let name = attributeDict["name"],
              let relationshipID = attributeDict["r:id"] ?? attributeDict["id"] else { return }
        sheets.append(WorkbookSheet(name: name, relationshipID: relationshipID))
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
    private var collectingValue = false
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
        case "v":
            collectingValue = currentReference != nil
        case "t":
            collectingInlineText = currentReference != nil && currentType == "inlineStr"
        default:
            break
        }
    }

    override func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingValue || collectingInlineText { currentValue += string }
    }

    override func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "v" { collectingValue = false }
        if elementName == "t" { collectingInlineText = false }
        guard elementName == "c", let reference = currentReference else { return }
        defer {
            currentReference = nil
            currentType = nil
            currentValue = ""
        }
        guard let (row, column) = Self.cellPosition(reference),
              row <= maximumRows,
              column < maximumColumns else { return }
        rowCount = max(rowCount, row)
        cells[row, default: [:]][column] = decodedValue(currentValue, type: currentType)
    }

    func renderedRows() -> [[String]] {
        guard rowCount > 0 else { return [] }
        return (1...min(rowCount, maximumRows)).map { row in
            guard let rowCells = cells[row], let lastColumn = rowCells.keys.max() else { return [] }
            return (0...lastColumn).map { rowCells[$0] ?? "" }
        }
    }

    private func decodedValue(_ rawValue: String, type: String?) -> String {
        switch type {
        case "s":
            guard let index = Int(rawValue), sharedStrings.indices.contains(index) else { return "" }
            return sharedStrings[index]
        case "b":
            return rawValue == "1" ? "true" : "false"
        default:
            return rawValue
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
    ToolCatalog.register(DocumentCreateTool.self)
    registry.register(DocumentReadSheetTool(rootProvider: rootProvider))
    registry.register(DocumentCreateTool(rootProvider: rootProvider))
    return rootProvider
}
