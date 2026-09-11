import Foundation
import UIKit
import WebKit
import PDFKit
import ImageIO
import CryptoKit
import FloeCore
import FloeTools
import FloeWorkspace
import FloeDocuments

struct DocumentConversionArguments: Decodable, Sendable {
    var inputPath: String
    var outputPath: String
    var format: String
}

struct DocumentConvertTool: AgentTool {
    typealias Arguments = DocumentConversionArguments
    static let name = "document.convert"
    static let toolDescription = "Convert an existing workspace file directly between Markdown, DOCX (Word), HTML, RTF and plain text using bundled offline libraries. Pass paths, never regenerate or copy the document into tool arguments. Preserves semantic headings, lists, tables, emphasis, links and supported embedded/local images where the target supports them. Writes a new file, never overwrites; reports conversion limitations. RTF preserves basic rich text, not all table/layout semantics. For any PDF input or output use document.pdf.convert. Legacy .doc is unsupported."
    static let parametersJSON = #"{"type":"object","properties":{"inputPath":{"type":"string","description":"Existing workspace-relative .md/.markdown/.docx/.html/.rtf/.txt file"},"outputPath":{"type":"string","description":"New workspace-relative file; extension must match format"},"format":{"type":"string","enum":["markdown","docx","html","rtf","text"]}},"required":["inputPath","outputPath","format"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    func validate(_ args: Arguments) throws { try DocumentFileConverter.validate(args, requiresPDF: false) }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await DocumentFileConverter.convert(args, context: context)
    }
}

struct PDFConvertTool: AgentTool {
    typealias Arguments = DocumentConversionArguments
    static let name = "document.pdf.convert"
    static let toolDescription = "Convert Markdown, Word DOCX, HTML, RTF or text files to a paginated PDF, or extract a copy-permitted text PDF into Markdown, DOCX, HTML, RTF or text. Operates offline on existing files without model rewriting. Source is preserved and output must be new. PDF extraction retains page order and searchable text, not original layout, tables or images; image-only/scanned pages fail with an OCR-required message instead of silently disappearing. For non-PDF conversions use document.convert."
    static let parametersJSON = #"{"type":"object","properties":{"inputPath":{"type":"string"},"outputPath":{"type":"string","description":"New workspace-relative file; extension must match format"},"format":{"type":"string","enum":["pdf","markdown","docx","html","rtf","text"]}},"required":["inputPath","outputPath","format"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    func validate(_ args: Arguments) throws { try DocumentFileConverter.validate(args, requiresPDF: true) }
    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try validate(args)
        return try await DocumentFileConverter.convert(args, context: context)
    }
}

/// File-to-file conversion: document contents never enter model messages.
enum DocumentFileConverter {
    static let maximumBytes = 16 * 1_024 * 1_024
    static func format(_ path: String) -> String? {
        switch (path as NSString).pathExtension.lowercased() {
        case "md", "markdown": "markdown"
        case "docx": "docx"
        case "htm", "html": "html"
        case "rtf": "rtf"
        case "txt": "text"
        case "pdf": "pdf"
        default: nil
        }
    }
    static func validate(_ args: DocumentConversionArguments, requiresPDF: Bool) throws {
        try PDFToolSupport.validatePath(args.inputPath)
        try PDFToolSupport.validatePath(args.outputPath)
        guard args.inputPath.utf8.count <= 1024, args.outputPath.utf8.count <= 1024,
              let source = format(args.inputPath), format(args.outputPath) == args.format,
              args.inputPath != args.outputPath,
              (source == "pdf" || args.format == "pdf") == requiresPDF,
              !(source == "pdf" && args.format == "pdf") else {
            throw FloeError.validationFailed("Choose supported input and matching new output extension; use the PDF conversion tool when either format is PDF")
        }
    }

    static func convert(_ args: DocumentConversionArguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let root = context.workspaceRootURL else { throw FloeError.invalidConfiguration("No task workspace") }
        try context.authorizeWorkspacePath(args.inputPath)
        try context.authorizeWorkspacePath(args.outputPath)
        let guarder = WorkspacePathGuard(rootURL: root, maxReadBytes: maximumBytes, maxWriteBytes: maximumBytes)
        let sourceURL = try guarder.resolve(args.inputPath)
        let outputURL = try guarder.resolve(args.outputPath)
        guard sourceURL != outputURL, !FileManager.default.fileExists(atPath: outputURL.path) else {
            throw FloeError.validationFailed("Output exists; choose a new filename")
        }
        try guarder.assertReadableSize(sourceURL)
        let input = try Data(floeContentsOf: sourceURL)
        guard input.count <= maximumBytes else { throw FloeError.validationFailed("Conversion input exceeds 16 MiB") }
        if format(args.inputPath) == "docx" { _ = try OfficeDocumentService.inspect(url: sourceURL) }
        let result = try await render(input, sourceFormat: format(args.inputPath)!, target: args.format,
                                      sourceURL: sourceURL, root: root, context: context)
        try context.cancellation.throwIfCancelled()
        guard !result.data.isEmpty, result.data.count <= maximumBytes else { throw FloeError.validationFailed("Conversion produced empty or oversized output") }
        try PDFToolSupport.write(result.data, to: args.outputPath, context: context)
        let digest = SHA256.hash(data: result.data).map { String(format: "%02x", $0) }.joined()
        // Bounded status only: never put converted document text back in context.
        let warnings = result.warnings.prefix(8).map { String($0.prefix(400)) }.joined(separator: " | ")
        return PDFToolSupport.output("converted=\(args.outputPath) format=\(args.format) bytes=\(result.data.count) sha256=\(digest) originalPreserved=true offline=true modelRewrite=false warnings=\(warnings)", status: 0)
    }

    struct Result: Sendable { var data: Data; var warnings: [String] }

    @MainActor static func render(_ input: Data, sourceFormat: String, target: String,
                                   sourceURL: URL, root: URL, context: ToolContext) async throws -> Result {
        var inputData = input, format = sourceFormat, warnings: [String] = []
        if format == "pdf" {
            inputData = try await pdfHTML(input, cancellation: context.cancellation)
            format = "html"
            warnings.append("PDF text extracted in page order; page layout, images and table structure are not reconstructed.")
        } else if format == "rtf" {
            if String(decoding: input, as: UTF8.self).range(of: "INCLUDEPICTURE|INCLUDETEXT", options: [.regularExpression, .caseInsensitive]) != nil {
                throw FloeError.validationFailed("RTF external resource fields are unsupported; embed images before converting")
            }
            let rich = try NSAttributedString(data: input, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            inputData = Data(richHTML(rich).utf8)
            format = "html"
            warnings.append("RTF conversion preserves basic rich text; advanced tables and layout may differ.")
        }
        let engine = try DocumentConversionWebSession(cancellation: context.cancellation)
        defer { engine.close() }
        try await engine.load(DocumentConversionWebSession.shell)
        let prepared = try await engine.call("prepare", arguments: ["base64": inputData.base64EncodedString(), "format": format])
        guard let html = prepared["html"] as? String, html.utf8.count <= maximumBytes,
              let images = prepared["images"] as? [String] else {
            throw FloeError.validationFailed("Conversion engine returned an invalid document")
        }
        warnings += prepared["warnings"] as? [String] ?? []
        guard images.count <= 64 else { throw FloeError.validationFailed("Conversion supports at most 64 image references") }
        var resources: [String: String] = [:], resourceBytes = 0
        for path in images {
            try context.cancellation.throwIfCancelled()
            if path.hasPrefix("data:") { continue }
            guard !path.isEmpty, !path.hasPrefix("/"), !path.contains(":"), !path.hasPrefix("//"),
                  let decoded = path.removingPercentEncoding else {
                throw FloeError.validationFailed("Download external images to this workspace first, then reference the local file")
            }
            let imageURL = sourceURL.deletingLastPathComponent().appendingPathComponent(decoded).standardizedFileURL
            let prefix = root.standardizedFileURL.path + "/"
            guard imageURL.path.hasPrefix(prefix) else { throw FloeError.validationFailed("Image path escapes workspace") }
            let relative = String(imageURL.path.dropFirst(prefix.count))
            try context.authorizeWorkspacePath(relative)
            let guarder = WorkspacePathGuard(rootURL: root, maxReadBytes: 4 * 1_024 * 1_024)
            let resolved = try guarder.resolve(relative)
            try guarder.assertReadableSize(resolved)
            let data = try Data(floeContentsOf: resolved)
            guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 16_000_000,
                  let image = UIImage(data: data), let png = image.pngData(), png.count <= maximumBytes else {
                throw FloeError.validationFailed("Image is unsupported or conversion images exceed the size limit")
            }
            resourceBytes += png.count
            guard resourceBytes <= maximumBytes else { throw FloeError.validationFailed("Embedded images exceed 16 MiB") }
            resources[path] = "data:image/png;base64," + png.base64EncodedString()
        }
        let intermediate = ["pdf", "rtf"].contains(target) ? "html" : target
        let converted = try await engine.call("finish", arguments: ["html": html, "resources": resources, "format": intermediate])
        guard let base64 = converted["base64"] as? String, let data = Data(base64Encoded: base64), data.count <= maximumBytes else {
            throw FloeError.validationFailed("Invalid converted output")
        }
        try context.cancellation.throwIfCancelled()
        if target == "pdf" {
            guard let pageHTML = String(data: data, encoding: .utf8) else { throw FloeError.validationFailed("Invalid HTML output") }
            try await engine.load(pageHTML)
            guard let fontURL = Bundle.main.url(forResource: "FloeDocumentSans", withExtension: "woff2", subdirectory: "DocumentConversion") else { throw FloeError.validationFailed("Bundled PDF font is missing") }
            let font = try Data(contentsOf: fontURL)
            _ = try await engine.call("configurePDF", arguments: ["font": font.base64EncodedString()])
            let renderer = ConversionPrintRenderer()
            renderer.addPrintFormatter(engine.webView.viewPrintFormatter(), startingAtPageAt: 0)
            renderer.prepare(forDrawingPages: NSRange(location: 0, length: 1))
            let pages = renderer.numberOfPages
            guard (1...500).contains(pages) else { throw FloeError.validationFailed("PDF requires 1...500 pages") }
            // prepare() must cover exactly the pages drawn below.
            renderer.prepare(forDrawingPages: NSRange(location: 0, length: pages))
            let pdf = UIGraphicsPDFRenderer(bounds: renderer.paperRect).pdfData { ctx in
                for page in 0..<pages { ctx.beginPage(); renderer.drawPage(at: page, in: renderer.paperRect) }
            }
            let verifiedPages = PDFKitGate.run { PDFDocument(data: pdf)?.pageCount }
            guard verifiedPages == pages else { throw FloeError.validationFailed("Generated PDF failed verification") }
            return Result(data: pdf, warnings: warnings)
        }
        if target == "rtf" {
            let rich = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
            let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            _ = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            warnings.append("RTF retains basic rich text; table and CSS layout fidelity varies by reader.")
            return Result(data: rtf, warnings: warnings)
        }
        if target == "docx" {
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("floe-convert-\(UUID()).docx")
            defer { try? FileManager.default.removeItem(at: temp) }
            try data.write(to: temp, options: .withoutOverwriting)
            _ = try OfficeDocumentService.inspect(url: temp)
        }
        return Result(data: data, warnings: warnings)
    }

    static func pdfHTML(_ data: Data, cancellation: CancellationToken) async throws -> Data {
        try await Task.detached {
            try PDFKitGate.run { () throws -> Data in
                guard let pdf = PDFDocument(data: data), !pdf.isLocked, pdf.allowsCopying, (1...500).contains(pdf.pageCount) else {
                    throw FloeError.validationFailed("PDF must permit copying, be unlocked and contain 1...500 pages")
                }
                var parts: [String] = [], total = 0
                for n in 0..<pdf.pageCount {
                    try cancellation.throwIfCancelled()
                    guard let page = pdf.page(at: n), let text = page.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        throw FloeError.validationFailed("Page \(n + 1) has no extractable text. Create a searchable OCR copy before converting; no page was silently omitted")
                    }
                    total += text.utf8.count
                    guard total <= maximumBytes / 2 else { throw FloeError.validationFailed("PDF text exceeds conversion limit") }
                    parts.append("<section><h2>Page \(n + 1)</h2><p>" + escape(text).replacingOccurrences(of: "\n", with: "<br>") + "</p></section>")
                }
                return Data(parts.joined(separator: "\n").utf8)
            }
        }.value
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    @MainActor static func richHTML(_ rich: NSAttributedString) -> String {
        var html = ""
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attrs, range, _ in
            var value = escape((rich.string as NSString).substring(with: range)).replacingOccurrences(of: "\n", with: "<br>")
            if let attachment = attrs[.attachment] as? NSTextAttachment,
               let image = attachment.image ?? attachment.contents.flatMap(UIImage.init(data:)), let png = image.pngData() {
                value = "<img src=\"data:image/png;base64,\(png.base64EncodedString())\">"
            }
            var css: [String] = []
            if let font = attrs[.font] as? UIFont {
                css.append("font-size:\(font.pointSize)pt")
                if font.fontDescriptor.symbolicTraits.contains(.traitBold) { value = "<strong>\(value)</strong>" }
                if font.fontDescriptor.symbolicTraits.contains(.traitItalic) { value = "<em>\(value)</em>" }
            }
            if (attrs[.underlineStyle] as? Int ?? 0) != 0 { value = "<u>\(value)</u>" }
            for (key, property) in [(NSAttributedString.Key.foregroundColor,"color"), (.backgroundColor,"background-color")] {
                if let color = attrs[key] as? UIColor {
                    var r: CGFloat=0,g: CGFloat=0,b: CGFloat=0,a: CGFloat=0
                    if color.getRed(&r, green: &g, blue: &b, alpha: &a) { css.append("\(property):rgb(\(Int(r*255)),\(Int(g*255)),\(Int(b*255)))") }
                }
            }
            if let link = attrs[.link] { value = "<a href=\"\(escape(String(describing: link)))\">\(value)</a>" }
            html += "<span style=\"\(css.joined(separator: ";"))\">\(value)</span>"
        }
        return "<p>\(html)</p>"
    }
}

@MainActor private final class ConversionPrintRenderer: UIPrintPageRenderer {
    override var paperRect: CGRect { CGRect(x: 0, y: 0, width: 595.28, height: 841.89) }
    override var printableRect: CGRect { paperRect.insetBy(dx: 36, dy: 36) }
}

@MainActor final class DocumentConversionWebSession: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var navigation: CheckedContinuation<Void, Error>?
    private var evaluation: CheckedContinuation<String, Error>?
    private var deadline: Task<Void, Never>?
    private let cancellation: CancellationToken
    static let shell = "<!doctype html><html><head><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline'; img-src data:; style-src 'unsafe-inline'\"></head><body></body></html>"
    init(cancellation: CancellationToken = CancellationToken()) throws {
        self.cancellation = cancellation
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        guard let url = Bundle.main.url(forResource: "converter", withExtension: "js", subdirectory: "DocumentConversion") else {
            throw FloeError.validationFailed("Bundled conversion engine is missing")
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 523.28, height: 769.89), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }
    func load(_ html: String) async throws {
        let rules: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "floe-conversion-offline-v1", encodedContentRuleList: #"[{"trigger":{"url-filter":"^http"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"block"}},{"trigger":{"url-filter":"^ftp:"},"action":{"type":"block"}}]"#) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? FloeError.validationFailed("Offline conversion isolation unavailable")) }
            }
        }
        webView.configuration.userContentController.add(rules)
        try await withCheckedThrowingContinuation { continuation in
            navigation = continuation; armDeadline()
            webView.loadHTMLString(html, baseURL: nil)
        }
    }
    func call(_ operation: String, arguments: [String: Any]) async throws -> [String: Any] {
        let value: String = try await withCheckedThrowingContinuation { continuation in
            evaluation = continuation; armDeadline()
            self.webView.callAsyncJavaScript("return JSON.stringify(await window.FloeConversion[operation](input));", arguments: ["operation": operation, "input": arguments], in: nil, in: .page, completionHandler: { [weak self] result in
                guard let self, let pending = self.evaluation else { return }
                self.evaluation = nil; self.deadline?.cancel()
                switch result {
                case .success(let value):
                    if let string = value as? String { pending.resume(returning: string) }
                    else { pending.resume(throwing: FloeError.validationFailed("Invalid converter response")) }
                case .failure(let error): pending.resume(throwing: error)
                }
            })
        }
        guard let object = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            throw FloeError.validationFailed("Invalid conversion result")
        }
        return object
    }
    private func armDeadline() {
        deadline?.cancel()
        deadline = Task { [weak self] in
            for _ in 0..<360 {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                do { try self?.cancellation.throwIfCancelled() }
                catch { self?.fail(error); return }
            }
            self?.fail(FloeError.validationFailed("Document conversion timed out; source is unchanged"))
        }
    }
    private func fail(_ error: Error) {
        deadline?.cancel(); webView.stopLoading()
        let n = navigation; navigation = nil; n?.resume(throwing: error)
        let e = evaluation; evaluation = nil; e?.resume(throwing: error)
    }
    func close() { fail(CancellationError()); webView.navigationDelegate = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        deadline?.cancel(); let pending = self.navigation; self.navigation = nil; pending?.resume()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail(FloeError.validationFailed("Conversion process ended; retry with a smaller document")) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }
}
