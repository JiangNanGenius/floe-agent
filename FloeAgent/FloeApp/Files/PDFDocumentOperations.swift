import Foundation
import PDFKit
import UIKit
import CoreText
import Vision
import ImageIO
import FloeCore
import FloeTools

/// Bounded native PDF workflows. All coordinates are unrotated PDF points,
/// origin at the lower-left. No JavaScript, external links or embedded actions run.
enum PDFDocumentOperations {
    enum Action: String, Decodable, Sendable {
        case reorderPages, cropPage, insertBlankPage
        case addAnnotation, updateAnnotation, removeAnnotation
        case createField, setField, removeField
        case setMetadata, setBookmarks, flattenAnnotations
        case searchableOCR, rasterRedact
        case replaceRegion, addText, insertImage, replaceImage, removeImage
    }
    struct Bookmark: Decodable, Sendable {
        var title: String
        var page: Int
    }
    struct Region: Decodable, Sendable {
        var page: Int
        var bounds: [Double]
    }
    struct Operation: Decodable, Sendable {
        var action: Action
        var page: Int?
        var bounds: [Double]?
        var pages: [Int]?
        var annotationIndex: Int?
        var kind: String?
        var text: String?
        var fieldName: String?
        var checked: Bool?
        var choices: [String]?
        var color: [Double]?
        var fontSize: Double?
        var points: [[Double]]?
        var metadata: [String: String]?
        var bookmarks: [Bookmark]?
        var regions: [Region]?
        var acceptRasterization: Bool?
        var acceptFlattening: Bool?
        var languages: [String]?
        var imagePath: String?
        var expectedObjectCount: Int?
    }
    struct Result: Sendable {
        var data: Data
        var evidence: [String]
    }

    static func run(_ data: Data, operations: [Operation], images: [String: Data] = [:], cancellation: CancellationToken) async throws -> Result {
        let token = PDFOperationJournal.begin(
            tool: "document.pdf.workflow",
            detail: "ops=\(operations.count) inputSHA=\(PDFOperationJournal.digest(data)) bytes=\(data.count)"
        )
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                // PDFKit is not thread-safe; the entire workflow stays behind the
                // process-wide gate (the PDFium bridge has its own mutex).
                try PDFKitGate.run { try process(data, operations: operations, images: images, cancellation: cancellation) }
            }.value
            PDFOperationJournal.end(token, status: "ok")
            return result
        } catch {
            PDFOperationJournal.end(token, status: "error:\(type(of: error))")
            throw error
        }
    }

    private static func process(_ input: Data, operations: [Operation], images: [String: Data], cancellation: CancellationToken) throws -> Result {
        guard (1...30).contains(operations.count), input.count <= 64 * 1024 * 1024,
              var document = PDFDocument(data: input), !document.isLocked,
              (1...500).contains(document.pageCount) else { throw invalid("PDF workflow limits exceeded") }
        let inspection = try JSONSerialization.jsonObject(with: FloePDFiumBridge.inspect(input)) as? [String: Any]
        let signed = (inspection?["signatureCount"] as? Int ?? 0) > 0
        if signed && !(operations.count == 1 && operations[0].action == .rasterRedact && operations[0].acceptRasterization == true) {
            throw invalid("Signed PDFs require an explicitly accepted rasterized unsigned copy; editing does not preserve signature validity")
        }
        var evidence: [String] = []
        // PDFKit can rebuild a native PDF's ToUnicode map when serializing it
        // again (some SDKs map CJK glyphs to look-alike radical code points).
        // Preserve verified native bytes until an actual PDFKit mutation occurs.
        var nativeSnapshot: Data? = input
        for op in operations {
            try cancellation.throwIfCancelled()
            guard (op.text?.utf8.count ?? 0) <= 16_000, (op.fieldName?.count ?? 0) <= 200,
                  (op.fontSize ?? 12).isFinite, (6...96).contains(op.fontSize ?? 12) else { throw invalid("Invalid PDF text or font size") }
            let token = PDFOperationJournal.begin(
                tool: "pdf.action",
                detail: "action=\(op.action.rawValue) page=\(op.page.map(String.init) ?? "-") pages=\(document.pageCount)"
            )
            do {
            switch op.action {
            case .replaceRegion, .addText, .insertImage, .replaceImage, .removeImage: break
            default: nativeSnapshot = nil
            }
            switch op.action {
            case .replaceRegion, .addText, .insertImage, .replaceImage, .removeImage:
                let p = try page(op.page, in: document)
                let box = try rect(op.bounds, inside: p.bounds(for: .mediaBox))
                let isText = op.action == .replaceRegion || op.action == .addText
                let removes = op.action == .replaceRegion || op.action == .replaceImage || op.action == .removeImage
                let count = removes ? (op.expectedObjectCount ?? -1) : 0
                guard !removes || (1...500).contains(count) else { throw invalid("Replacing/removing a region requires expectedObjectCount from the inspected PDF") }
                var overlay: Data?
                let local = CGRect(origin: .zero, size: box.size)
                if isText {
                    guard let text = op.text, !text.isEmpty else { throw invalid("Text region requires nonempty text") }
                    let attributed = NSAttributedString(string: text, attributes: [
                        .font: UIFont.systemFont(ofSize: op.fontSize ?? 12), .foregroundColor: try color(op.color)])
                    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
                    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: local, transform: nil), nil)
                    guard CTFrameGetVisibleStringRange(frame).length == attributed.length else { throw invalid("Text does not fit inside this region; enlarge bounds or reduce fontSize") }
                    overlay = UIGraphicsPDFRenderer(bounds: local).pdfData { r in
                        r.beginPage(); let c = r.cgContext
                        c.translateBy(x: 0, y: local.height); c.scaleBy(x: 1, y: -1); c.textMatrix = .identity
                        CTFrameDraw(frame, c)
                    }
                } else if op.action != .removeImage {
                    guard let path = op.imagePath, let bytes = images[path], bytes.count <= 16 * 1024 * 1024,
                          let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceThumbnailMaxPixelSize: 4096,
                            kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { throw invalid("A bounded readable imagePath is required") }
                    let image = UIImage(cgImage: thumbnail)
                    overlay = UIGraphicsPDFRenderer(bounds: local).pdfData { r in r.beginPage(); image.draw(in: local) }
                    evidence.append("imageFit=stretch; image orientation normalized; maximumRasterDimension=4096")
                }
                let beforeWrite = nativeSnapshot == nil
                    ? (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" } : nil
                guard let current = nativeSnapshot ?? document.dataRepresentation() else { throw invalid("PDF serialization failed") }
                if let beforeWrite {
                    guard let serialized = PDFDocument(data: current) else { throw invalid("PDF serialization failed to reopen") }
                    try verifySavedText(beforeWrite, in: serialized)
                }
                let changed = try FloePDFiumBridge.replaceRegion(current, page: op.page!, bounds: [box.minX, box.minY, box.width, box.height].map { NSNumber(value: Double($0)) },
                    overlay: overlay, objectType: isText ? 1 : 3, expectedCount: count)
                guard let updated = PDFDocument(data: changed), updated.pageCount == document.pageCount else { throw invalid("Native region output failed to reopen") }
                if isText, let text = op.text {
                    let actual = updated.page(at: op.page! - 1)?.string ?? ""
                    let normalize: (String) -> String = { $0.components(separatedBy: .whitespacesAndNewlines).joined() }
                    guard normalize(actual).contains(normalize(text)) else { throw invalid("Region text/font verification failed") }
                }
                document = updated
                nativeSnapshot = changed
                evidence.append("nativeRegionRewrite=true; removedObjects=\(count); notSecureRedaction=true")
            case .reorderPages:
                guard let order = op.pages, order.count == document.pageCount,
                      Set(order) == Set(1...document.pageCount) else { throw invalid("reorderPages requires each existing page exactly once") }
                // Retain page objects before removal, preserving their annotations.
                let ordered = try order.map { try page($0, in: document) }
                while document.pageCount > 0 { document.removePage(at: document.pageCount - 1) }
                for p in ordered { document.insert(p, at: document.pageCount) }
            case .cropPage:
                let p = try page(op.page, in: document)
                p.setBounds(try rect(op.bounds, inside: p.bounds(for: .mediaBox)), for: .cropBox)
                evidence.append("cropOnly=true; cropping does not remove hidden content")
            case .insertBlankPage:
                guard document.pageCount < 500, let position = op.page, (1...document.pageCount + 1).contains(position) else { throw invalid("Invalid blank page insertion position") }
                let box = try rect(op.bounds)
                guard box.origin == .zero else { throw invalid("Blank page bounds must start at 0,0") }
                let blank = PDFPage()
                blank.setBounds(box, for: .mediaBox)
                document.insert(blank, at: position - 1)
            case .addAnnotation:
                let p = try page(op.page, in: document)
                let types: [String: PDFAnnotationSubtype] = ["note": .text, "freeText": .freeText,
                    "highlight": .highlight, "underline": .underline, "strikeOut": .strikeOut,
                    "square": .square, "circle": .circle, "ink": .ink, "line": .line]
                guard let kind = op.kind, let type = types[kind] else { throw invalid("Unsupported annotation kind") }
                let a = PDFAnnotation(bounds: try rect(op.bounds, inside: p.bounds(for: .mediaBox)), forType: type, withProperties: nil)
                a.setValue(UUID().uuidString, forAnnotationKey: .name)
                a.contents = op.text
                a.color = try color(op.color)
                a.font = .systemFont(ofSize: CGFloat(op.fontSize ?? 12))
                a.fontColor = a.color
                if type == .freeText { a.color = .clear }
                if type == .line || type == .ink {
                    guard let points = op.points, (2...500).contains(points.count) else { throw invalid("Line/ink requires 2-500 points relative to annotation bounds") }
                    let converted = try points.map { values -> CGPoint in
                        guard values.count == 2, values.allSatisfy(\.isFinite),
                              (0...a.bounds.width).contains(values[0]), (0...a.bounds.height).contains(values[1]) else { throw invalid("Invalid annotation point") }
                        return CGPoint(x: values[0], y: values[1])
                    }
                    if type == .line { a.startPoint = converted[0]; a.endPoint = converted[1] }
                    else {
                        let stroke = UIBezierPath(); stroke.move(to: converted[0])
                        for point in converted.dropFirst() { stroke.addLine(to: point) }
                        a.add(stroke)
                    }
                }
                p.addAnnotation(a)
            case .updateAnnotation, .removeAnnotation:
                let p = try page(op.page, in: document)
                guard let index = op.annotationIndex, p.annotations.indices.contains(index) else { throw invalid("Annotation index is stale or missing; inspect this document revision") }
                let a = p.annotations[index]
                guard !isWidget(a) else { throw invalid("Use field operations for form widgets") }
                if op.action == .removeAnnotation { p.removeAnnotation(a) }
                else {
                    if let text = op.text { a.contents = text }
                    if let bounds = op.bounds { a.bounds = try rect(bounds, inside: p.bounds(for: .mediaBox)) }
                    if op.color != nil { a.color = try color(op.color); a.fontColor = a.color }
                    if let size = op.fontSize { a.font = .systemFont(ofSize: size) }
                    a.modificationDate = Date()
                }
            case .createField:
                let p = try page(op.page, in: document)
                guard let name = op.fieldName, !name.isEmpty, fields(name, in: document).isEmpty else { throw invalid("Field name must be new and nonempty") }
                let a = PDFAnnotation(bounds: try rect(op.bounds, inside: p.bounds(for: .mediaBox)), forType: .widget, withProperties: nil)
                a.font = .systemFont(ofSize: op.fontSize ?? 12)
                a.fontColor = .black
                a.backgroundColor = .white
                switch op.kind {
                case "text": a.widgetFieldType = .text; a.widgetStringValue = op.text ?? ""
                case "checkbox": a.widgetFieldType = .button; a.widgetControlType = .checkBoxControl; a.buttonWidgetState = op.checked == true ? .onState : .offState
                case "choice":
                    guard let choices = op.choices, (1...100).contains(choices.count), choices.allSatisfy({ !$0.isEmpty && $0.count <= 200 }), Set(choices).count == choices.count,
                          op.text == nil || choices.contains(op.text!) else { throw invalid("Choice field requires unique choices and a listed value") }
                    a.widgetFieldType = .choice; a.choices = choices; a.widgetStringValue = op.text ?? choices[0]
                default: throw invalid("createField supports text, checkbox and choice; not signature fields")
                }
                p.addAnnotation(a)
                // PDFKit initializes the field dictionary when the widget type
                // and page are attached. Set its name after that initialization.
                a.fieldName = name
            case .setField, .removeField:
                guard let name = op.fieldName else { throw invalid("fieldName is required") }
                let matches = fields(name, in: document)
                guard !matches.isEmpty else { throw invalid("No field matches fieldName") }
                for (p, a) in matches {
                    guard a.widgetFieldType != .signature else { throw invalid("Signature widgets cannot be modified by form tools") }
                    if op.action == .removeField { p.removeAnnotation(a); continue }
                    guard !a.isReadOnly else { throw invalid("Field is read-only") }
                    if a.widgetFieldType == .button {
                        guard a.widgetControlType == .checkBoxControl, let checked = op.checked else { throw invalid("Only checkbox button values are editable; checked is required") }
                        a.buttonWidgetState = checked ? .onState : .offState
                    } else {
                        guard let text = op.text else { throw invalid("Field text is required") }
                        if a.widgetFieldType == .choice, !(a.choices ?? []).contains(text) { throw invalid("Value is not one of the field choices") }
                        a.widgetStringValue = text
                    }
                }
            case .setMetadata:
                let keys: [String: PDFDocumentAttribute] = ["title": .titleAttribute, "author": .authorAttribute,
                    "subject": .subjectAttribute, "creator": .creatorAttribute, "keywords": .keywordsAttribute]
                guard let metadata = op.metadata, metadata.count <= 5 else { throw invalid("Metadata is required") }
                var attributes = document.documentAttributes ?? [:]
                for (key, value) in metadata {
                    guard let pdfKey = keys[key], value.count <= 2000 else { throw invalid("Unsupported metadata key or length") }
                    if value.isEmpty { attributes.removeValue(forKey: pdfKey) }
                    else { attributes[pdfKey] = key == "keywords" ? value.split(separator: ",").map(String.init) as Any : value }
                }
                document.documentAttributes = attributes
            case .setBookmarks:
                guard let bookmarks = op.bookmarks, bookmarks.count <= 200 else { throw invalid("Bookmarks accept at most 200 entries") }
                let outline = PDFOutline()
                for (index, bookmark) in bookmarks.enumerated() {
                    guard !bookmark.title.isEmpty, bookmark.title.count <= 200 else { throw invalid("Invalid bookmark title") }
                    let p = try page(bookmark.page, in: document)
                    let child = PDFOutline(); child.label = bookmark.title
                    child.destination = PDFDestination(page: p, at: CGPoint(x: p.bounds(for: .mediaBox).minX, y: p.bounds(for: .mediaBox).maxY))
                    outline.insertChild(child, at: index)
                }
                document.outlineRoot = outline
            case .flattenAnnotations:
                guard op.acceptFlattening == true, let current = document.dataRepresentation() else { throw invalid("Flattening requires acceptFlattening=true; form and annotation interactivity will be removed") }
                let flat = try FloePDFiumBridge.flatten(current)
                guard let reopened = PDFDocument(data: flat), reopened.pageCount == document.pageCount,
                      (0..<reopened.pageCount).allSatisfy({ reopened.page(at: $0)?.annotations.isEmpty == true }) else { throw invalid("Flattened annotations failed structural verification") }
                document = reopened
                evidence.append("nativeFlatten=true; page content preserved; interactivity removed; notSecureRedaction=true")
            case .rasterRedact:
                guard operations.count == 1, op.acceptRasterization == true, let regions = op.regions, (1...100).contains(regions.count) else {
                    throw invalid("rasterRedact must be the only operation and requires explicit rasterization consent and 1-100 regions")
                }
                document = try rasterCopy(document, regions: regions, ocr: false, languages: nil, cancellation: cancellation)
                evidence.append("rasterRebuild=true; no original content streams, text layer, forms, annotations, attachments, bookmarks or signatures copied")
            case .searchableOCR:
                guard operations.count == 1, op.acceptRasterization == true else { throw invalid("searchableOCR must be the only operation; explicitly accept rasterized pages with a new OCR text layer") }
                document = try rasterCopy(document, regions: [], ocr: true, languages: op.languages, cancellation: cancellation)
                evidence.append("onDeviceOCR=true; recognized text may contain errors; page appearance is rasterized")
            }
            PDFOperationJournal.end(token, status: "ok")
            } catch {
                PDFOperationJournal.end(token, status: "error:\(type(of: error))")
                throw error
            }
            evidence.append("applied=\(op.action.rawValue)")
        }
        try cancellation.throwIfCancelled()
        // Capture expected text before serialization: checking the in-memory
        // document alone misses changes introduced by PDFKit's final write.
        let expectedText = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
        guard let data = nativeSnapshot ?? document.dataRepresentation(), data.count <= 64 * 1024 * 1024,
              let reopened = PDFDocument(data: data), reopened.pageCount == document.pageCount else { throw invalid("PDF save/reopen verification failed") }
        try verifySavedText(expectedText, in: reopened)
        if operations.contains(where: { $0.action == .rasterRedact }) {
            let native = try JSONSerialization.jsonObject(with: FloePDFiumBridge.inspect(data)) as? [String: Any]
            guard native?["imageObjectsOnly"] as? Bool == true,
                  native?["attachmentCount"] as? Int == 0, native?["signatureCount"] as? Int == 0,
                  (reopened.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (0..<reopened.pageCount).allSatisfy({ reopened.page(at: $0)?.annotations.isEmpty == true }) else {
                throw invalid("Raster rebuild structural verification failed; output not saved")
            }
            evidence.append("verifiedImageOnly=true")
        }
        return Result(data: data, evidence: evidence)
    }

    static func verifySavedText(_ expected: [String], in saved: PDFDocument) throws {
        guard saved.pageCount == expected.count else { throw invalid("PDF saved text page count changed") }
        let compact: (String) -> String = { $0.components(separatedBy: .whitespacesAndNewlines).joined() }
        for index in expected.indices {
            // Ignore layout whitespace only, never compatibility-normalize
            // radicals or other distinct Unicode characters into a false pass.
            guard compact(saved.page(at: index)?.string ?? "") == compact(expected[index]) else {
                throw invalid("PDF saved text differs from the verified document; output not saved")
            }
        }
    }

    private static func rasterCopy(_ source: PDFDocument, regions: [Region], ocr: Bool, languages: [String]?, cancellation: CancellationToken) throws -> PDFDocument {
        guard source.pageCount <= 50, (languages?.count ?? 0) <= 5 else { throw invalid("Raster/OCR accepts at most 50 pages and 5 languages") }
        for region in regions { _ = try rect(region.bounds, inside: page(region.page, in: source).bounds(for: .mediaBox)) }
        let output = PDFDocument()
        var bytes = 0
        for index in 0..<source.pageCount {
            try cancellation.throwIfCancelled()
            let p = try page(index + 1, in: source)
            // Refuse rotated/cropped page geometry rather than silently redact a different location.
            let box = p.bounds(for: .mediaBox)
            guard p.rotation == 0, box.origin == .zero, box == p.bounds(for: .cropBox),
                  box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
                throw invalid("Raster workflows currently require unrotated pages with matching media/crop boxes; normalize a separate copy first")
            }
            let scale = min(2, 3000 / max(box.width, box.height))
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let image = UIGraphicsImageRenderer(size: CGSize(width: box.width * scale, height: box.height * scale), format: format).image { r in
                UIColor.white.setFill(); r.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
                let c = r.cgContext
                c.translateBy(x: 0, y: box.height * scale); c.scaleBy(x: scale, y: -scale)
                p.draw(with: .mediaBox, to: c)
                c.setFillColor(UIColor.black.cgColor)
                for region in regions where region.page == index + 1 {
                    // Expand half a point to cover antialiasing at the selected edge.
                    let b = region.bounds
                    c.fill(CGRect(x: b[0], y: b[1], width: b[2], height: b[3]).insetBy(dx: -0.5, dy: -0.5))
                }
            }
            guard let png = image.pngData(), let clean = UIImage(data: png) else { throw invalid("Raster encoding failed") }
            bytes += png.count
            guard bytes <= 48 * 1024 * 1024 else { throw invalid("Raster output exceeds memory limit; process fewer pages") }
            let pdf = UIGraphicsPDFRenderer(bounds: box).pdfData { r in
                r.beginPage()
                clean.draw(in: box)
            }
            guard let pageDocument = PDFDocument(data: pdf), let rendered = pageDocument.page(at: 0) else { throw invalid("Raster page rebuild failed") }
            if ocr {
                guard let cg = clean.cgImage else { throw invalid("OCR image could not be decoded") }
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                if let languages {
                    let supported = try request.supportedRecognitionLanguages()
                    guard languages.allSatisfy(supported.contains) else { throw invalid("Unsupported on-device OCR language") }
                    request.recognitionLanguages = languages
                } else { request.automaticallyDetectsLanguage = true }
                try VNImageRequestHandler(cgImage: cg).perform([request])
                try cancellation.throwIfCancelled()
                let observations = request.results ?? []
                guard observations.count <= 2000 else { throw invalid("OCR page text limit") }
                // CoreText invisible drawing adds actual searchable text, not annotations.
                let searchable = UIGraphicsPDFRenderer(bounds: box).pdfData { r in
                    r.beginPage(); clean.draw(in: box)
                    let c = r.cgContext
                    c.translateBy(x: 0, y: box.height); c.scaleBy(x: 1, y: -1)
                    c.textMatrix = .identity; c.setTextDrawingMode(.invisible)
                    for observation in observations {
                        guard let candidate = observation.topCandidates(1).first else { continue }
                        let b = observation.boundingBox
                        let rect = CGRect(x: b.minX * box.width, y: b.minY * box.height, width: b.width * box.width, height: b.height * box.height)
                        let string = NSAttributedString(string: candidate.string, attributes: [.font: UIFont.systemFont(ofSize: max(1, rect.height * 0.8))])
                        let line = CTLineCreateWithAttributedString(string)
                        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
                        c.saveGState(); c.translateBy(x: rect.minX, y: rect.minY)
                        if width > 0 { c.scaleBy(x: rect.width / width, y: 1) }
                        c.textPosition = .zero; CTLineDraw(line, c); c.restoreGState()
                    }
                }
                guard let searchDoc = PDFDocument(data: searchable), let searchPage = searchDoc.page(at: 0) else { throw invalid("Searchable OCR PDF failed to reopen") }
                output.insert(searchPage, at: output.pageCount)
            } else { output.insert(rendered, at: output.pageCount) }
        }
        output.documentAttributes = [:]
        return output
    }

    private static func page(_ number: Int?, in document: PDFDocument) throws -> PDFPage {
        guard let number, number >= 1, let page = document.page(at: number - 1) else { throw invalid("Page is outside the document") }
        return page
    }
    private static func rect(_ values: [Double]?, inside page: CGRect? = nil) throws -> CGRect {
        guard let v = values, v.count == 4, v.allSatisfy(\.isFinite), v[2] > 0, v[3] > 0,
              v.allSatisfy({ abs($0) <= 14400 }) else { throw invalid("bounds requires finite [x,y,width,height] PDF points") }
        let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        if let page, !page.contains(r) { throw invalid("Bounds must fit inside the page") }
        return r
    }
    private static func color(_ values: [Double]?) throws -> UIColor {
        guard let values else { return .black }
        guard values.count == 3 || values.count == 4, values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw invalid("color requires RGB or RGBA values in 0...1") }
        return UIColor(red: values[0], green: values[1], blue: values[2], alpha: values.count == 4 ? values[3] : 1)
    }
    private static func fields(_ name: String, in document: PDFDocument) -> [(PDFPage, PDFAnnotation)] {
        (0..<document.pageCount).compactMap { document.page(at: $0) }.flatMap { p in
            p.annotations.filter { $0.fieldName == name }.map { (p, $0) }
        }
    }
    private static func isWidget(_ annotation: PDFAnnotation) -> Bool {
        annotation.type?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "Widget"
    }
    private static func invalid(_ message: String) -> FloeError { .validationFailed(message) }
}
