// FloeDocuments — compiled Office creation, inspection and editing tools.

import Foundation
import Crypto
import FloeCore
import FloeTools
import FloeWorkspace

private enum OfficeToolSupport {
    static let maximumOfficeBytes = 128 * 1_024 * 1_024

    static func root(_ context: ToolContext, fallback: @Sendable () -> URL?) throws -> URL {
        guard let root = context.workspaceRootURL ?? fallback() else {
            throw FloeError.validationFailed("No workspace is open")
        }
        return root
    }

    static func resolve(
        _ path: String,
        context: ToolContext,
        fallback: @Sendable () -> URL?,
        mustExist: Bool
    ) throws -> URL {
        try context.authorizeWorkspacePath(path)
        let root = try root(context, fallback: fallback)
        let guarder = WorkspacePathGuard(
            rootURL: root,
            maxReadBytes: maximumOfficeBytes,
            maxWriteBytes: maximumOfficeBytes
        )
        let url = try guarder.resolve(path)
        try guarder.assertWritable(url)
        if mustExist {
            try guarder.assertReadableSize(url)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw FloeError.validationFailed("Office document does not exist: \(path)")
            }
        }
        return url
    }

    static func output(_ text: String, exitStatus: Int32 = 0) -> ToolExecutionOutput {
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return ToolExecutionOutput(summary: text, fullOutputSHA256: digest, exitStatus: exitStatus)
    }

    static func validatePath(_ path: String, extension expected: String? = nil) throws {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 1_024 else {
            throw FloeError.validationFailed("path must contain 1...1024 bytes")
        }
        if let expected, (trimmed as NSString).pathExtension.lowercased() != expected {
            throw FloeError.validationFailed("path must end in .\(expected)")
        }
    }
}

public struct OfficeInspectTool: AgentTool {
    public struct Arguments: Decodable, Sendable { public var path: String }
    public static let name = "document.office.inspect"
    public static let toolDescription =
        "Inspect editable text, slide text, notes, formulas and cells in a workspace .docx, .pptx or .xlsx file. Returns stable field IDs for document.office.updateText and preserves the original package."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative .docx, .pptx or .xlsx path"}},"required":["path"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    private let rootProvider: @Sendable () -> URL?
    public init(rootProvider: @escaping @Sendable () -> URL?) { self.rootProvider = rootProvider }
    public func validate(_ args: Arguments) throws { try OfficeToolSupport.validatePath(args.path) }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            let url = try OfficeToolSupport.resolve(args.path, context: context, fallback: rootProvider, mustExist: true)
            let snapshot = try OfficeDocumentService.inspect(url: url)
            let lines = snapshot.fields.prefix(2_000).map {
                "id=\($0.id) section=\($0.section) label=\($0.label) text=\($0.text.replacingOccurrences(of: "\n", with: "\\n"))"
            }
            return OfficeToolSupport.output(
                "kind=\(snapshot.kind.rawValue) fields=\(snapshot.fields.count) entries=\(snapshot.packageEntries) bytes=\(snapshot.packageBytes)\n"
                    + lines.joined(separator: "\n")
            )
        } catch {
            return OfficeToolSupport.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }
}

public struct OfficeUpdateTextTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var updates: [String: String]
    }
    public static let name = "document.office.updateText"
    public static let toolDescription =
        "Update exact fields in an existing workspace Office file after document.office.inspect. Unknown or stale IDs fail closed. Floe preserves unchanged themes, layouts, images and relationships, writes atomically, then reopens the package to verify it."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative .docx, .pptx or .xlsx path"},"updates":{"type":"object","description":"Map exact inspect field IDs to replacement text or formulas beginning with =","maxProperties":500,"additionalProperties":{"type":"string","maxLength":100000}}},"required":["path","updates"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    private let rootProvider: @Sendable () -> URL?
    public init(rootProvider: @escaping @Sendable () -> URL?) { self.rootProvider = rootProvider }
    public func validate(_ args: Arguments) throws {
        try OfficeToolSupport.validatePath(args.path)
        guard !args.updates.isEmpty, args.updates.count <= 500,
              args.updates.values.allSatisfy({ $0.utf8.count <= 100_000 }) else {
            throw FloeError.validationFailed("updates must contain 1...500 bounded fields")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            let url = try OfficeToolSupport.resolve(args.path, context: context, fallback: rootProvider, mustExist: true)
            let result = try OfficeDocumentService.update(sourceURL: url, updates: args.updates)
            return OfficeToolSupport.output("updated=\(args.path) fields=\(args.updates.count) verifiedFields=\(result.fields.count)")
        } catch {
            return OfficeToolSupport.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }
}

public struct DocumentCreateWordTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var title: String
        public var paragraphs: [String]
    }
    public static let name = "document.createWord"
    public static let toolDescription =
        "Create an editable native .docx in the workspace with a clear title and paragraphs. Use web.search/web.fetch first when source material is needed. The file is generated locally, validated as OOXML, and can be manually edited in Floe."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string","description":"New workspace-relative .docx path"},"title":{"type":"string","maxLength":300},"paragraphs":{"type":"array","maxItems":500,"items":{"type":"string","maxLength":100000}}},"required":["path","title","paragraphs"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    private let rootProvider: @Sendable () -> URL?
    public init(rootProvider: @escaping @Sendable () -> URL?) { self.rootProvider = rootProvider }
    public func validate(_ args: Arguments) throws {
        try OfficeToolSupport.validatePath(args.path, extension: "docx")
        guard !args.title.isEmpty, args.title.count <= 300, args.paragraphs.count <= 500,
              args.paragraphs.allSatisfy({ $0.utf8.count <= 100_000 }) else {
            throw FloeError.validationFailed("Word content exceeds the bounded creation limits")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            let url = try OfficeToolSupport.resolve(args.path, context: context, fallback: rootProvider, mustExist: false)
            try OfficeDocumentBuilder.createWord(at: url, title: args.title, paragraphs: args.paragraphs)
            return OfficeToolSupport.output("created=\(args.path) format=docx paragraphs=\(args.paragraphs.count + 1) verified=true")
        } catch {
            return OfficeToolSupport.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }
}

public struct DocumentCreateWorkbookTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var sheets: [OfficeWorkbookSheet]
    }
    public static let name = "document.createWorkbook"
    public static let toolDescription =
        "Create an editable native .xlsx in the workspace. Values remain typed when numeric, strings remain editable, and entries beginning with = become formulas. Prefer auditable formulas and separate input/calculation sheets."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string","description":"New workspace-relative .xlsx path"},"sheets":{"type":"array","minItems":1,"maxItems":32,"items":{"type":"object","properties":{"name":{"type":"string","maxLength":31},"rows":{"type":"array","maxItems":10000,"items":{"type":"array","maxItems":256,"items":{"type":"string","maxLength":100000}}}},"required":["name","rows"],"additionalProperties":false}}},"required":["path","sheets"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    private let rootProvider: @Sendable () -> URL?
    public init(rootProvider: @escaping @Sendable () -> URL?) { self.rootProvider = rootProvider }
    public func validate(_ args: Arguments) throws {
        try OfficeToolSupport.validatePath(args.path, extension: "xlsx")
        guard !args.sheets.isEmpty, args.sheets.count <= 32,
              args.sheets.allSatisfy({ !$0.name.isEmpty && $0.name.count <= 31 && $0.rows.count <= 10_000 && $0.rows.allSatisfy({ $0.count <= 256 }) }),
              args.sheets.flatMap({ $0.rows }).flatMap({ $0 }).allSatisfy({ $0.utf8.count <= 100_000 }) else {
            throw FloeError.validationFailed("Workbook exceeds the bounded creation limits")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            let url = try OfficeToolSupport.resolve(args.path, context: context, fallback: rootProvider, mustExist: false)
            try OfficeDocumentBuilder.createWorkbook(at: url, sheets: args.sheets)
            return OfficeToolSupport.output("created=\(args.path) format=xlsx sheets=\(args.sheets.count) verified=true")
        } catch {
            return OfficeToolSupport.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }
}

public struct PresentationCreateDeckTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var title: String
        public var slides: [OfficePresentationSlide]
    }
    public static let name = "presentation.createDeck"
    public static let toolDescription =
        "Create an editable native 16:9 .pptx in the workspace. First ground claims and assets with web.search/web.fetch, then plan a concise storyboard, vary slide content, keep audience-facing copy clean, and add source URLs to slide notes. Floe creates a local OOXML deck, validates it, and exposes its text for manual editing."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string","description":"New workspace-relative .pptx path"},"title":{"type":"string","maxLength":300},"slides":{"type":"array","minItems":1,"maxItems":100,"items":{"type":"object","properties":{"title":{"type":"string","maxLength":300},"bullets":{"type":"array","maxItems":12,"items":{"type":"string","maxLength":1000}},"notes":{"type":"string","description":"Optional speaker notes including [Sources] URLs","maxLength":20000}},"required":["title","bullets"],"additionalProperties":false}}},"required":["path","title","slides"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true
    private let rootProvider: @Sendable () -> URL?
    public init(rootProvider: @escaping @Sendable () -> URL?) { self.rootProvider = rootProvider }
    public func validate(_ args: Arguments) throws {
        try OfficeToolSupport.validatePath(args.path, extension: "pptx")
        guard !args.title.isEmpty, args.title.count <= 300, !args.slides.isEmpty, args.slides.count <= 100,
              args.slides.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 300 && $0.bullets.count <= 12 && $0.bullets.allSatisfy({ $0.count <= 1_000 }) && ($0.notes?.count ?? 0) <= 20_000 }) else {
            throw FloeError.validationFailed("Presentation exceeds the bounded creation limits")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            let url = try OfficeToolSupport.resolve(args.path, context: context, fallback: rootProvider, mustExist: false)
            try OfficeDocumentBuilder.createPresentation(at: url, title: args.title, slides: args.slides)
            return OfficeToolSupport.output("created=\(args.path) format=pptx slides=\(args.slides.count) verified=true")
        } catch {
            return OfficeToolSupport.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }
}
