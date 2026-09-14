// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UIKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import FloeNotes
import FloeDocuments
import PencilKit
import Vision

enum NoteFileImporter {
    static func visualSearchText(page: NotePage, store: NotesStore) async throws -> String {
        let background = try await background(page: page, store: store)
        let images = try await elementImages(page: page, store: store)
        let ink: Data?
        if let resource = page.drawingResourceID { ink = try Data(contentsOf: await store.resourceURL(resource)) }
        else { ink = nil }
        try Task.checkCancellation()
        let composite = try await MainActor.run {
            let format = UIGraphicsImageRendererFormat(); format.scale = min(2, 2048 / max(page.width, page.height))
            let size = CGSize(width: page.width, height: page.height)
            let drawing = try ink.map { try PKDrawing(data: $0) }
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                NotePageRenderer.draw(page, background: background.flatMap(UIImage.init(data:)), images: images.compactMapValues(UIImage.init(data:)))
                drawing?.image(from: CGRect(origin: .zero, size: size), scale: format.scale).draw(in: CGRect(origin: .zero, size: size))
            }
            guard let data = image.pngData() else { throw NoteError.resourceUnavailable }
            return data
        }
        return try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            try Task.checkCancellation()
            try VNImageRequestHandler(data: composite).perform([request])
            try Task.checkCancellation()
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }

    static func officeSearchText(url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let snapshot = try OfficeDocumentService.inspect(url: url)
            var text = ""
            for field in snapshot.fields {
                try Task.checkCancellation()
                let remaining = 2_000_000 - text.count
                guard remaining > 0 else { throw NoteError.invalidOperation("Office 正文超过索引上限，请拆分文档后重试。") }
                text += String(field.text.prefix(remaining)) + "\n"
            }
            return text
        }.value
    }

    static func elementImages(page: NotePage, store: NotesStore) async throws -> [UUID: Data] {
        let ids = Set(page.elements.filter { $0.kind == .image }.compactMap(\.resourceID))
        return try await images(resourceIDs: ids, store: store)
    }
    static func images(resourceIDs ids: Set<UUID>, store: NotesStore) async throws -> [UUID: Data] {
        guard ids.count <= 64 else { throw NoteError.invalidOperation("单页或导图最多显示 64 张图片，请拆分内容。") }
        // Share a 16-megapixel decoded-image budget across the current page.
        let maximum = min(2048, max(128, Int(sqrt(16_777_216 / Double(max(1, ids.count))))))
        var result: [UUID: Data] = [:]
        for id in ids {
            try Task.checkCancellation()
            let url = try await store.resourceURL(id)
            result[id] = try await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximum] as CFDictionary),
                      let data = UIImage(cgImage: image).pngData() else { throw NoteError.resourceUnavailable }
                return data
            }.value
        }
        return result
    }
    static func attachment(_ url: URL, replacing id: UUID? = nil, store: NotesStore) async throws -> MindMapAttachment {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= 536_870_912 else {
            throw NoteError.invalidOperation("请选择不超过 512 MB 的单个文件。")
        }
        let type = values.contentType ?? .data
        let kind: MindMapAttachment.Kind
        if type.conforms(to: .image) { kind = .image }
        else if type.conforms(to: .audio) { kind = .audio }
        else if type.conforms(to: .movie) { kind = .video }
        else if type.conforms(to: .pdf) || type.conforms(to: .text) || ["docx", "pptx", "xlsx", "odt", "odp"].contains(url.pathExtension.lowercased()) { kind = .document }
        else { kind = .file }
        var attachment = MindMapAttachment(id: id ?? UUID(), resourceID: UUID(), fileName: url.lastPathComponent,
                                          mediaType: type.preferredMIMEType ?? "application/octet-stream", kind: kind)
        try attachment.validate()
        attachment.resourceID = try await store.importResource(from: url, mediaType: attachment.mediaType)
        if kind == .image { _ = try await images(resourceIDs: [attachment.resourceID], store: store) }
        return attachment
    }

    static func importFile(_ url: URL, notebookID: UUID?, store: NotesStore) async throws -> NoteDocument {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if url.pathExtension.lowercased() == "floenote" {
            return try await NotesArchive.importDocument(from: url, notebookID: notebookID, store: store)
        }
        let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .plainText) == true || ["txt", "md", "markdown", "csv", "json"].contains(url.pathExtension.lowercased()) {
            let count = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard count <= 2_000_000 else { throw NoteError.invalidOperation("文本文件超过 2 MB，请拆分后导入。") }
            let text = try String(contentsOf: url, encoding: .utf8)
            let resource = try await store.importResource(from: url, mediaType: type?.preferredMIMEType ?? "text/plain")
            var value = NoteDocument(title: url.deletingPathExtension().lastPathComponent)
            value.notebookID = notebookID
            value.pages = await MainActor.run { NotesTextLayout.pages(text: text, source: nil) }
            if value.pages.isEmpty { value.pages = [NotePage()] }
            for page in value.pages.indices {
                for element in value.pages[page].elements.indices { value.pages[page].elements[element].isAIGenerated = false }
            }
            if !value.pages[0].elements.isEmpty { value.pages[0].elements[0].resourceID = resource }
            try value.validate()
            return value
        }
        let officeExtensions = ["docx", "doc", "odt", "rtf", "xlsx", "xls", "ods", "pptx", "ppt", "odp"]
        if officeExtensions.contains(url.pathExtension.lowercased()) {
            let resourceID = try await store.importResource(from: url, mediaType: type?.preferredMIMEType ?? "application/octet-stream")
            var document = NoteDocument(kind: .office, notebookID: notebookID, title: url.deletingPathExtension().lastPathComponent)
            document.officeResourceID = resourceID
            document.officeFileName = url.lastPathComponent
            try document.validate()
            return document
        }
        let isPDF = type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf"
        let resourceID = try await store.importResource(from: url, mediaType: isPDF ? "application/pdf" : (type?.preferredMIMEType ?? "image/*"))
        let local = try await store.resourceURL(resourceID)
        let pages: [NotePage] = try await Task.detached(priority: .userInitiated) {
            if isPDF {
                return try PDFKitGate.run {
                    try withPDFExceptionGuard {
                        guard let pdf = PDFDocument(url: local), !pdf.isLocked, pdf.pageCount > 0 else {
                            throw NoteError.invalidDocument("PDF 已加密、损坏或没有页面。")
                        }
                        guard pdf.pageCount <= 5_000 else { throw NoteError.invalidDocument("PDF 超过 5000 页，请先拆分。") }
                        var remainingText = 2_000_000
                        return try (0..<pdf.pageCount).map { index in
                            guard let page = pdf.page(at: index) else { throw NoteError.invalidDocument("PDF 页面无法读取。") }
                            let bounds = page.bounds(for: .cropBox)
                            let rotated = abs(page.rotation % 180) == 90
                            let width = rotated ? bounds.height : bounds.width
                            let height = rotated ? bounds.width : bounds.height
                            guard width > 0, height > 0 else { throw NoteError.invalidDocument("PDF 页面尺寸无效。") }
                            let text = page.string ?? ""
                            let extracted = String(text.prefix(min(65_536, remainingText)))
                            remainingText -= extracted.count
                            return NotePage(width: Double(width), height: Double(height), backgroundResourceID: resourceID, pdfPageIndex: index,
                                            extractedText: extracted.isEmpty ? nil : extracted,
                                            textExtractionTruncated: extracted.count < text.count)
                        }
                    }
                }
            }
            guard let source = CGImageSourceCreateWithURL(local as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Double,
                  let height = properties[kCGImagePropertyPixelHeight] as? Double, width > 0, height > 0 else {
                throw NoteError.invalidDocument("图片无法读取。")
            }
            let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
            let rotated = (5...8).contains(orientation)
            let displayWidth = rotated ? height : width
            let displayHeight = rotated ? width : height
            let scale = min(1, 2048 / max(displayWidth, displayHeight))
            return [NotePage(width: displayWidth * scale, height: displayHeight * scale, backgroundResourceID: resourceID)]
        }.value
        var document = NoteDocument(notebookID: notebookID, title: url.deletingPathExtension().lastPathComponent)
        document.pages = pages
        try document.validate()
        return document
    }

    static func background(page: NotePage, store: NotesStore) async throws -> Data? {
        guard let resource = page.backgroundResourceID else { return nil }
        let url = try await store.resourceURL(resource)
        return try await Task.detached(priority: .userInitiated) {
            if let index = page.pdfPageIndex {
                return try PDFKitGate.run {
                    try withPDFExceptionGuard {
                        guard let pdf = PDFDocument(url: url), let pdfPage = pdf.page(at: index) else { throw NoteError.resourceUnavailable }
                        let scale = min(2, 2048 / max(page.width, page.height))
                        let size = CGSize(width: page.width * scale, height: page.height * scale)
                        guard let data = pdfPage.thumbnail(of: size, for: .cropBox).pngData() else { throw NoteError.resourceUnavailable }
                        return data
                    }
                }
            }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary) else {
                throw NoteError.resourceUnavailable
            }
            return UIImage(cgImage: image).pngData()
        }.value
    }
}
#endif
