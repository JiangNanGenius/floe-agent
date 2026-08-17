// FloeDocuments — document.readSheet agent tool.
//
// Reads an .xlsx workbook's cells into a tab-separated text grid using
// Cuneiform. This is the honest on-device slice of the document surface —
// the semantic LibreOffice engine remains out of scope on iOS, while
// spreadsheet reading is fully local and deterministic.

import Foundation
import Crypto
import Cuneiform
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
            let workbook = try Workbook.open(url: url)
            let sheet: Sheet
            let sheetName: String
            if let name = args.sheet {
                guard let found = try workbook.sheet(named: name) else {
                    return Self.output("status=error error=Sheet '\(name)' not found", exitStatus: 2)
                }
                sheet = found
                sheetName = name
            } else {
                guard let first = try workbook.sheet(at: 0) else {
                    return Self.output("status=error error=Workbook has no sheets", exitStatus: 2)
                }
                sheet = first
                sheetName = workbook.sheets.first?.name ?? "Sheet1"
            }

            let limit = min(max(1, args.maxRows ?? 200), 1000)
            var lines: [String] = []
            var shown = 0
            for row in sheet.rows() {
                guard shown < limit else { break }
                let cells = row.map { Self.cellText($0.value) }
                lines.append(cells.joined(separator: "\t"))
                shown += 1
            }
            var summary = "sheet=\(sheetName) rows=\(sheet.rowCount) shown=\(shown)\n"
            summary += lines.joined(separator: "\n")
            return Self.output(summary, exitStatus: 0)
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    private static func cellText(_ value: CellValue) -> String {
        switch value {
        case .text(let s): s
        case .richText(let rt): rt.plainText
        case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
        case .boolean(let b): b ? "true" : "false"
        case .date(let d): d
        case .error(let e): e
        case .empty: ""
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
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
