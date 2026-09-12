// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UIKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import FloeNotes

enum NoteFileImporter {
    static func importFile(_ url: URL, notebookID: UUID?, store: NotesStore) async throws -> NoteDocument {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let type = try url.resourceValues(forKeys: [.contentTypeKey]).contentType
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
