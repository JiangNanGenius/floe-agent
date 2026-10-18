// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import UIKit
import PDFKit
import FloeNotes

enum OfficeSavedCoverRenderer {
    /// The exported PDF is temporary. PDFKit objects never escape the shared
    /// affinity gate or exception boundary; only a bounded encoded image does.
    nonisolated static func firstPageData(at url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let bytes = values.fileSize,
              bytes > 0, bytes <= 128 * 1_024 * 1_024 else { throw NoteError.resourceUnavailable }
        return try PDFKitGate.run {
            try withPDFExceptionGuard {
                guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0,
                      let page = document.page(at: 0) else { throw NoteError.resourceUnavailable }
                let bounds = page.bounds(for: .cropBox)
                guard bounds.width.isFinite, bounds.height.isFinite,
                      bounds.width > 0, bounds.height > 0 else { throw NoteError.resourceUnavailable }
                let image = page.thumbnail(of: CGSize(width: 640, height: 840), for: .cropBox)
                guard let cg = image.cgImage, cg.width > 0, cg.height > 0,
                      cg.width <= 2_048, cg.height <= 2_048,
                      let encoded = image.pngData(), encoded.count <= 8 * 1_024 * 1_024 else {
                    throw NoteError.resourceUnavailable
                }
                return encoded
            }
        }
    }
}
#endif
