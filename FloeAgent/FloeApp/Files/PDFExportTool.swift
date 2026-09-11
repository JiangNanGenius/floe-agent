import Foundation
import PDFKit
import FloeCore
import FloeTools

struct PDFExportTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var inputPath: String
        var outputPath: String
        var format: String
        var pages: String?
        /// Explicit overwrite consent, asked for after the user confirms.
        var overwrite: Bool?
    }
    static let name = "document.pdf.export"
    static let toolDescription = "Export real PDF text to a new UTF-8 text or JSON file, preserving requested page order. JSON retains page boundaries. Maximum 500 pages / 8 MiB text. Scanned pages are reported, never invented; create a searchable OCR copy first when requested. Never overwrites unless the user explicitly confirms and overwrite=true is passed. This is not layout-preserving Word conversion. Use document.pdf.render for PNG/JPEG exports."
    static let parametersJSON = #"{"type":"object","properties":{"inputPath":{"type":"string"},"outputPath":{"type":"string"},"format":{"type":"string","enum":["text","json"]},"pages":{"type":"string","description":"1-based page selection, e.g. 3,1-2; omit for all pages"},"overwrite":{"type":"boolean","description":"Set true only after the user confirms replacing an existing output file"}},"required":["inputPath","outputPath","format"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    func validate(_ args: Arguments) throws {
        try PDFToolSupport.validatePath(args.inputPath)
        try PDFToolSupport.validatePath(args.outputPath)
        guard args.inputPath != args.outputPath, ["text", "json"].contains(args.format) else {
            throw FloeError.validationFailed("PDF export requires a new output and text/json format")
        }
    }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        let input = try PDFToolSupport.read(args.inputPath, context: context)
        let exported: (Data, Int, Int) = try await Task.detached {
            try PDFKitGate.run { () throws -> (Data, Int, Int) in
                guard let pdf = PDFDocument(data: input), !pdf.isLocked, (1...500).contains(pdf.pageCount), pdf.allowsCopying else {
                    throw FloeError.validationFailed("PDF must permit copying, be unlocked and contain 1...500 pages")
                }
                let selected = try args.pages.map { try PDFToolSupport.pageNumbers(from: $0, pageCount: pdf.pageCount) } ?? Array(1...pdf.pageCount)
                var records: [[String: Any]] = [], texts: [String] = [], total = 0, empty = 0
                for number in selected {
                    try context.cancellation.throwIfCancelled()
                    guard let page = pdf.page(at: number - 1) else { throw FloeError.validationFailed("PDF page unavailable") }
                    let text = page.string ?? ""
                    total += text.utf8.count
                    guard total <= 8_388_608 else { throw FloeError.validationFailed("PDF export text exceeds 8 MiB") }
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { empty += 1 }
                    records.append(["page": number, "text": text]); texts.append(text)
                }
                let data = args.format == "json" ? try JSONSerialization.data(withJSONObject: ["pages": records], options: [.sortedKeys]) : Data(texts.joined(separator: "\n\u{000C}\n").utf8)
                guard data.count <= 8_388_608 else { throw FloeError.validationFailed("PDF export exceeds 8 MiB") }
                return (data, selected.count, empty)
            }
        }.value
        try PDFToolSupport.write(exported.0, to: args.outputPath, context: context, overwrite: args.overwrite == true)
        return PDFToolSupport.output("Exported \(exported.1) pages to \(args.outputPath); pagesWithoutExtractableText=\(exported.2); originalPreserved=true", status: 0)
    }
}
