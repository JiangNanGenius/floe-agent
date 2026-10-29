//
//  FloeCADDocument+Capture.swift
//  FloeCADKit
//
//  Real viewport capture, bound to the live document identity. This uses the
//  SAME `Renderer.makeSceneSnapshotPNG` path as the Canvas thumbnail
//  (`ViewportBridge.viewportThumbnailPNG`), never a drawing-page renderer and
//  never a fabricated image. A capture is refused when the viewport renderer is
//  unavailable, when the requested revision no longer matches, or when a live
//  edit races the capture.
//

import Foundation
import ImageIO

public nonisolated struct CADViewportCaptureResult: Sendable, Equatable {
    public var pngData: Data
    public var width: Int
    public var height: Int
    /// Last committed package revision the capture is bound to.
    public var revision: Int
    /// Live in-memory generation at capture time (detects unsaved edits).
    public var changeCount: Int
    public var contentSHA256: String
    public var sha256: String
    /// Which actual renderer produced the pixels: `engineering` (Metal
    /// viewport snapshot) or `presentation` (live RealityKit Present). Never
    /// guessed; the host reports this exact value.
    public var renderer: String
    public var note: String

    public init(pngData: Data, width: Int, height: Int, revision: Int,
                changeCount: Int, contentSHA256: String, sha256: String,
                renderer: String = "engineering", note: String) {
        self.pngData = pngData
        self.width = width
        self.height = height
        self.revision = revision
        self.changeCount = changeCount
        self.contentSHA256 = contentSHA256
        self.sha256 = sha256
        self.renderer = renderer
        self.note = note
    }
}

@MainActor
public extension FloeCADDocument {
    /// Actual offscreen viewport PNG of the live scene (bodies, materials,
    /// grid/floor, assembly placements). `expectedRevision` (when supplied)
    /// must equal the last committed revision; the live change count is also
    /// checked across the render so a concurrent edit fails the capture rather
    /// than returning an image of a half-applied state.
    func captureViewportPNG(width: Int = 1024, height: Int = 768,
                            expectedRevision: Int? = nil) throws -> CADViewportCaptureResult {
        guard width >= 64, width <= 4096, height >= 64, height <= 4096 else {
            throw CADDocumentError(code: "bad_capture_size",
                                   message: "Viewport capture dimensions must be 64…4096 points.")
        }
        if let expectedRevision, expectedRevision != revision {
            throw CADDocumentError(
                code: "revision_mismatch",
                message: "The document is at revision \(revision), not the requested "
                    + "\(expectedRevision). Re-read the document before capturing.")
        }
        guard !isReadOnly else {
            throw CADDocumentError(code: "document_read_only",
                                   message: "A document from a newer app version opens read-only; "
                                    + "it cannot be rendered as the live editable scene.")
        }
        let beforeChange = session.changeCount
        guard let png = Self._floeViewportPNG(self, width: width, height: height),
              !png.isEmpty else {
            throw CADDocumentError(
                code: "viewport_unavailable",
                message: "The actual viewport renderer is unavailable on this device/build "
                    + "(Metal context could not be created). No image was fabricated.")
        }
        if let expectedRevision, expectedRevision != revision {
            throw CADDocumentError(code: "revision_mismatch",
                                   message: "The document revision changed during capture; nothing was returned.")
        }
        guard session.changeCount == beforeChange else {
            throw CADDocumentError(code: "document_changed",
                                   message: "The document changed during capture; re-read and capture again.")
        }
        let actual = Self.pngPixelSize(png) ?? (width, height)
        return CADViewportCaptureResult(
            pngData: png, width: actual.0, height: actual.1,
            revision: revision, changeCount: session.changeCount,
            contentSHA256: contentSHA256,
            sha256: CADMaterialTexture.digest(png),
            renderer: "engineering",
            note: "Actual offscreen viewport render of the live document scene "
                + "(not a drawing page and not an imported preview image).")
    }
}


@MainActor
private extension FloeCADDocument {
    static func _floeViewportPNG(_ document: FloeCADDocument,
                                 width: Int, height: Int) -> Data? {
        #if canImport(MetalKit)
        return document.viewportThumbnailPNG(width: width, height: height)
        #else
        return nil
        #endif
    }

    static func pngPixelSize(_ data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else { return nil }
        return (image.width, image.height)
    }
}

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
@MainActor
public extension FloeCADDocument {
    /// A PNG from the ACTUAL live Present (RealityKit) render, or nil when
    /// Present is not showing this document. A stale/failed presentation
    /// capture throws and must not fall back to an older image or to the
    /// engineering renderer. The engineering fallback is used only when this
    /// returns nil (Present inactive).
    func capturePresentedPNG(width: Int = 2048,
                             expectedRevision: Int? = nil) async throws
    -> CADPresentationCapture? {
        guard CADPresentationCaptureRegistry.shared.isActive(for: self) else {
            return nil
        }
        if let expectedRevision, expectedRevision != revision {
            throw CADDocumentError(
                code: "revision_mismatch",
                message: "The document is at revision \(revision), not the requested "
                    + "\(expectedRevision). Re-read before capturing.")
        }
        do {
            return try await CADPresentationCaptureRegistry.shared.capture(
                document: self, width: max(64, min(width, 4096)))
        } catch let error as CADPresentationCaptureError {
            switch error {
            case .notActive:
                throw CADDocumentError(
                    code: "presentation_not_active",
                    message: "Present stopped showing this document before the capture; "
                        + "the engineering renderer was not substituted.")
            case .stale:
                throw CADDocumentError(
                    code: "presentation_stale",
                    message: "The document changed during the Present capture; the image was discarded.")
            case .failed(let message):
                throw CADDocumentError(code: "presentation_failed", message: message)
            }
        }
    }
}
#endif
