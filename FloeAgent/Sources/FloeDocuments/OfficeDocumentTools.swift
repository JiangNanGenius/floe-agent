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
        return ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
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
        "Inspect editable text, slide text, notes, formulas and cells in a workspace .docx, .pptx or .xlsx file. Returns stable field IDs for document.office.updateText and preserves the original package. For a quick read-only dump of spreadsheet cell values use document.readSheet instead."
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
            guard let digest = snapshot.sha256 else {
                throw FloeError.validationFailed("Office inspection did not return a verified revision")
            }
            let lines = snapshot.fields.prefix(2_000).map {
                "id=\($0.id) section=\($0.section) label=\($0.label) text=\($0.text.replacingOccurrences(of: "\n", with: "\\n"))"
            }
            let note = snapshot.fields.isEmpty
                ? "note=This document has no editable text fields. It may contain only images, drawings, charts, form controls or protected content; document.office.updateText will report unknownField for guessed IDs.\n"
                : ""
            return OfficeToolSupport.output(
                "kind=\(snapshot.kind.rawValue) sha256=\(digest) fields=\(snapshot.fields.count) entries=\(snapshot.packageEntries) bytes=\(snapshot.packageBytes)\n"
                    + note
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
        public var expectedSHA256: String? = nil
    }
    public static let name = "document.office.updateText"
    public static let toolDescription =
        "Update exact fields in an existing workspace Office file after document.office.inspect. Pass expectedSHA256 from inspect to reject stale edits. Unknown field IDs fail closed. Floe preserves unchanged themes, layouts, images and relationships, writes atomically, then reopens the package to verify it."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string","description":"Workspace-relative .docx, .pptx or .xlsx path"},"expectedSHA256":{"type":"string","pattern":"^[a-fA-F0-9]{64}$","description":"sha256 returned by inspect; prevents overwriting a newer revision"},"updates":{"type":"object","description":"Map exact inspect field IDs to replacement text or formulas beginning with =","maxProperties":500,"additionalProperties":{"type":"string","maxLength":100000}}},"required":["path","updates","expectedSHA256"],"additionalProperties":false}"#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    public static let isSideEffecting = true
    private let rootProvider: @Sendable () -> URL?
    public init(rootProvider: @escaping @Sendable () -> URL?) { self.rootProvider = rootProvider }
    public func validate(_ args: Arguments) throws {
        try OfficeToolSupport.validatePath(args.path)
        guard let digest = args.expectedSHA256, digest.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw FloeError.validationFailed("Read document.office.inspect and supply its expectedSHA256 before editing an existing Office file")
        }
        guard !args.updates.isEmpty, args.updates.count <= 500,
              args.updates.values.allSatisfy({ $0.utf8.count <= 100_000 }) else {
            throw FloeError.validationFailed("updates must contain 1...500 bounded fields")
        }
    }
    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            try validate(args)
            let url = try OfficeToolSupport.resolve(args.path, context: context, fallback: rootProvider, mustExist: true)
            let result = try OfficeDocumentService.update(sourceURL: url, updates: args.updates, expectedSHA256: args.expectedSHA256)
            guard let digest = result.sha256 else {
                throw FloeError.validationFailed("Office save could not confirm the resulting revision; inspect before retrying")
            }
            return OfficeToolSupport.output("updated=\(args.path) sha256=\(digest) fields=\(args.updates.count) verifiedFields=\(result.fields.count)")
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
            // Generated Word files are plain styled paragraphs. Say so instead
            // of implying fillable form fields exist.
            return OfficeToolSupport.output("created=\(args.path) format=docx paragraphs=\(args.paragraphs.count + 1) fillableFields=0 titleStyle=Title verified=true note=Plain document; no fillable form fields. Use document.office.inspect/updateText for text edits.")
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
    public static let name = "document.presentation.createDeck"
    public static let toolDescription =
        "Create a native 16:9 .pptx with slide titles, bullet text, optional speaker notes and positioned slide objects. Each slide may add text boxes, preset shapes, PNG/JPEG/GIF images and editable native bar/line/pie charts. Objects use EMU geometry (914400 EMU = 1 inch, canvas 12192000 x 6858000) or a layout preset (full/left/right/top/bottom/center); explicit EMU overrides the preset. Charts embed a real .xlsx workbook with Sheet1 cell references and relationships, so they stay editable charts rather than pictures. Images may be supplied as a workspace imagePath or inline imageBase64. Floe validates the OOXML package; use document.office.inspect/updateText for existing text fields. For an inline conversation table/chart/web preview use document.presentation.createInline."
    public static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string","description":"New workspace-relative .pptx path"},"title":{"type":"string","maxLength":300},"slides":{"type":"array","minItems":1,"maxItems":100,"items":{"type":"object","properties":{"title":{"type":"string","maxLength":300},"bullets":{"type":"array","maxItems":12,"items":{"type":"string","maxLength":1000}},"notes":{"type":"string","description":"Optional speaker notes including [Sources] URLs","maxLength":20000},"objects":{"type":"array","maxItems":32,"description":"Positioned objects on this slide","items":{"type":"object","properties":{"kind":{"type":"string","enum":["text","shape","image","chart"]},"name":{"type":"string","maxLength":120},"layout":{"type":"string","enum":["full","left","right","top","bottom","center"]},"x":{"type":"integer"},"y":{"type":"integer"},"width":{"type":"integer"},"height":{"type":"integer"},"text":{"type":"array","maxItems":20,"items":{"type":"string","maxLength":2000}},"shape":{"type":"string","enum":["rect","roundRect","ellipse","triangle","diamond","arrow","chevron","star5"]},"fillColor":{"type":"string","pattern":"^#?[0-9A-Fa-f]{6}$"},"lineColor":{"type":"string","pattern":"^#?[0-9A-Fa-f]{6}$"},"textColor":{"type":"string","pattern":"^#?[0-9A-Fa-f]{6}$"},"fontSize":{"type":"number","minimum":1,"maximum":200},"bold":{"type":"boolean"},"imagePath":{"type":"string","description":"Workspace-relative PNG/JPEG/GIF path; resolved before building"},"imageBase64":{"type":"string","description":"Inline PNG/JPEG/GIF bytes, max 8 MiB decoded"},"chart":{"type":"object","properties":{"chartType":{"type":"string","enum":["bar","line","pie"]},"title":{"type":"string","maxLength":300},"categories":{"type":"array","minItems":1,"maxItems":64,"items":{"type":"string","maxLength":200}},"series":{"type":"array","minItems":1,"maxItems":8,"items":{"type":"object","properties":{"name":{"type":"string","maxLength":200},"values":{"type":"array","minItems":1,"maxItems":64,"items":{"type":"number"}}},"required":["name","values"],"additionalProperties":false}}},"required":["chartType","categories","series"],"additionalProperties":false}},"required":["kind"],"additionalProperties":false}}},"required":["title","bullets"],"additionalProperties":false}}},"required":["path","title","slides"],"additionalProperties":false}"#
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
        for (index, slide) in args.slides.enumerated() {
            let objects = slide.objects ?? []
            guard objects.count <= OfficeDocumentBuilder.maximumPresentationObjectsPerSlide else {
                throw FloeError.validationFailed("Slide \(index + 1) exceeds \(OfficeDocumentBuilder.maximumPresentationObjectsPerSlide) objects")
            }
            for object in objects {
                if let text = object.text, text.count > 20 || text.contains(where: { $0.utf8.count > 4_000 }) {
                    throw FloeError.validationFailed("Slide \(index + 1) object text exceeds the bounded limits")
                }
                if object.kind == .image {
                    let hasBase64 = !(object.imageBase64 ?? "").isEmpty
                    let hasPath = !(object.imagePath ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    guard hasBase64 || hasPath else {
                        throw FloeError.validationFailed("Slide \(index + 1) image object needs imagePath or imageBase64")
                    }
                    if let base64 = object.imageBase64, base64.utf8.count > OfficeDocumentBuilder.maximumImageBytes * 2 {
                        throw FloeError.validationFailed("Slide \(index + 1) image exceeds the 8 MiB limit")
                    }
                }
                if object.kind == .chart {
                    guard let chart = object.chart else {
                        throw FloeError.validationFailed("Slide \(index + 1) chart object needs a chart payload")
                    }
                    guard (1...OfficeDocumentBuilder.maximumChartCategories).contains(chart.categories.count),
                          (1...OfficeDocumentBuilder.maximumChartSeries).contains(chart.series.count),
                          chart.series.allSatisfy({ $0.values.count == chart.categories.count && $0.values.allSatisfy(\.isFinite) }) else {
                        throw FloeError.validationFailed(
                            "Slide \(index + 1) chart needs 1...\(OfficeDocumentBuilder.maximumChartCategories) categories, "
                                + "1...\(OfficeDocumentBuilder.maximumChartSeries) series and one finite value per category"
                        )
                    }
                }
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        do {
            try validate(args)
            let url = try OfficeToolSupport.resolve(args.path, context: context, fallback: rootProvider, mustExist: false)
            let slides = try resolveImages(args.slides, context: context)
            try OfficeDocumentBuilder.createPresentation(at: url, title: args.title, slides: slides)
            let objects = slides.compactMap(\.objects).flatMap { $0 }
            let charts = objects.filter { $0.kind == .chart }.count
            let images = objects.filter { $0.kind == .image }.count
            return OfficeToolSupport.output(
                "created=\(args.path) format=pptx slides=\(args.slides.count) objects=\(objects.count) charts=\(charts) images=\(images) verified=true"
            )
        } catch {
            return OfficeToolSupport.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    /// Resolves workspace image paths to inline bytes. The builder has no
    /// workspace context, so the tool owns the bounded file read.
    private func resolveImages(_ slides: [OfficePresentationSlide], context: ToolContext) throws -> [OfficePresentationSlide] {
        try slides.map { slide in
            guard let objects = slide.objects, objects.contains(where: { $0.imagePath != nil }) else { return slide }
            var copy = slide
            copy.objects = try objects.map { object in
                guard object.kind == .image,
                      let path = object.imagePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !path.isEmpty,
                      (object.imageBase64 ?? "").isEmpty else { return object }
                let url = try OfficeToolSupport.resolve(path, context: context, fallback: rootProvider, mustExist: true)
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true,
                      let size = values.fileSize, size > 0, size <= OfficeDocumentBuilder.maximumImageBytes else {
                    throw FloeError.validationFailed("Image \(path) must be a regular file of at most 8 MiB")
                }
                let data = try Data(contentsOf: url, options: [.mappedIfSafe])
                guard data.count <= OfficeDocumentBuilder.maximumImageBytes else {
                    throw FloeError.validationFailed("Image \(path) exceeds the 8 MiB limit")
                }
                var resolved = object
                resolved.imageBase64 = data.base64EncodedString()
                resolved.imagePath = nil
                return resolved
            }
            return copy
        }
    }
}
