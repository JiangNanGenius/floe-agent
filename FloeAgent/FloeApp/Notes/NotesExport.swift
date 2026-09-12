// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import UIKit
import SwiftUI
import PencilKit
import FloeNotes

@MainActor enum NotesExport {
    struct Artifact: Identifiable { let id = UUID(); let url: URL }

    /// Pages are read and drawn one at a time. Cancelled/failed exports never expose a partial PDF.
    static func pdf(document: NoteDocument, store: NotesStore, progress: (Int, Int) -> Void) async throws -> Artifact {
        guard document.kind == .notebook else { throw NoteError.invalidOperation("请从 Office 编辑器导出 Office PDF。") }
        try document.validate()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: folder) } }
        let temporary = folder.appendingPathComponent(".partial.pdf")
        guard let context = CGContext(temporary as CFURL, mediaBox: nil, [kCGPDFContextTitle: document.title] as CFDictionary) else {
            throw NoteError.invalidOperation("无法创建 PDF，请检查剩余空间。")
        }
        var closed = false
        defer { if !closed { context.closePDF() } }
        for (index, page) in document.pages.enumerated() {
            try Task.checkCancellation()
            let sourcePDF: CGPDFDocument?
            let sourcePage: CGPDFPage?
            let background: UIImage?
            if let index = page.pdfPageIndex, let resource = page.backgroundResourceID {
                let source = try await store.resourceURL(resource)
                sourcePDF = CGPDFDocument(source as CFURL)
                guard let pdfPage = sourcePDF?.page(at: index + 1) else { throw NoteError.resourceUnavailable }
                sourcePage = pdfPage; background = nil
            } else {
                sourcePDF = nil; sourcePage = nil
                background = (try await NoteFileImporter.background(page: page, store: store)).flatMap { UIImage(data: $0) }
            }
            let images = try await NoteFileImporter.elementImages(page: page, store: store).compactMapValues { UIImage(data: $0) }
            let drawing: PKDrawing?
            if let id = page.drawingResourceID {
                let url = try await store.resourceURL(id)
                let data = try await Task.detached { try Data(contentsOf: url) }.value
                drawing = try PKDrawing(data: data)
            } else { drawing = nil }
            try Task.checkCancellation()
            autoreleasepool {
                var box = CGRect(x: 0, y: 0, width: page.width, height: page.height)
                let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size)
                context.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
                context.saveGState()
                context.translateBy(x: 0, y: page.height); context.scaleBy(x: 1, y: -1)
                UIGraphicsPushContext(context)
                let drawPDF: (() -> Void)? = sourcePage.map { pdfPage in
                    return {
                        context.saveGState()
                        context.translateBy(x: 0, y: page.height); context.scaleBy(x: 1, y: -1)
                        context.concatenate(pdfPage.getDrawingTransform(.cropBox, rect: box, rotate: 0, preserveAspectRatio: true))
                        context.drawPDFPage(pdfPage)
                        context.restoreGState()
                    }
                }
                NotePageRenderer.draw(page, background: background, images: images, backgroundDrawing: drawPDF)
                // Bound ink rasterization independently of page size; text remains PDF text.
                let scale = min(2, 4096 / max(page.width, page.height))
                drawing?.image(from: box, scale: scale).draw(in: box)
                UIGraphicsPopContext()
                context.restoreGState(); context.endPDFPage()
            }
            progress(index + 1, document.pages.count)
            await Task.yield()
        }
        context.closePDF(); closed = true
        try Task.checkCancellation()
        guard let pdf = CGPDFDocument(temporary as CFURL), pdf.numberOfPages == document.pages.count,
              (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 > 0 else {
            throw NoteError.invalidDocument("导出的 PDF 无法重新读取。")
        }
        let final = folder.appendingPathComponent(fileName(document.title)).appendingPathExtension("pdf")
        try FileManager.default.moveItem(at: temporary, to: final)
        success = true
        return Artifact(url: final)
    }

    static func outline(document: NoteDocument) throws -> Artifact {
        guard document.kind == .mindMap else { throw NoteError.invalidOperation("此内容不是思维导图。") }
        try document.validate()
        let children = Dictionary(grouping: document.nodes, by: \.parentID)
        var lines = ["# \(document.title)", ""]
        var stack = (children[nil] ?? []).map { ($0, 0) }
        while let (node, depth) = stack.popLast() {
            let indent = String(repeating: "  ", count: depth)
            lines.append(indent + "- " + node.title.replacingOccurrences(of: "\n", with: " "))
            if !node.note.isEmpty { lines.append(indent + "  " + node.note.replacingOccurrences(of: "\n", with: "\n" + indent + "  ")) }
            stack.append(contentsOf: (children[node.id] ?? []).sorted { $0.order < $1.order }.reversed().map { ($0, depth + 1) })
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("notes-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(fileName(document.title)).appendingPathExtension("md")
        try Data(lines.joined(separator: "\n").utf8).write(to: url, options: .atomic)
        return Artifact(url: url)
    }

    static func fileName(_ name: String) -> String {
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:\n\r\0")).joined(separator: "-")
        return String((safe.isEmpty ? "手记" : safe).prefix(100))
    }
}
struct NotesShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
