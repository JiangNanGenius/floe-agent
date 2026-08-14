// FloeApp — Image editor view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Drives the non-destructive image editor: preview re-render, undo, and the
// local operation controls (crop/rotate/resize/convert/compress/adjust/
// metadata removal). Rendering goes through the deterministic ImagePipeline
// via FilesCenter; the source is never mutated.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import UIKit
import CoreGraphics
import FloeImages
import FloeModels

/// View model for the image editor.
@MainActor
final class ImageEditorViewModel: ObservableObject {

    @Published private(set) var preview: UIImage?
    @Published private(set) var canUndo = false
    @Published private(set) var operationCount = 0
    @Published var errorMessage: String?

    let attachment: AttachmentRef
    let center: FilesCenter
    private var sessionID: UUID?

    init(attachment: AttachmentRef, center: FilesCenter) {
        self.attachment = attachment
        self.center = center
    }

    /// Opens the image into an edit session and renders the source.
    func load() async {
        do {
            let id = try await center.openImage(attachment)
            sessionID = id
            await rerender()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Applies a validated local operation and re-renders.
    func apply(_ operation: ImageOperation) async {
        guard let sessionID else { return }
        do {
            try await center.apply(operation, to: sessionID)
            await rerender()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undo() async {
        guard let sessionID else { return }
        do {
            try await center.undo(sessionID: sessionID)
            await rerender()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Exports the current image in the given format. Returns the file URL.
    func export(format: ImageOperation.ImageFormat) async -> URL? {
        guard let sessionID else { return nil }
        do {
            return try await center.exportImage(sessionID: sessionID, format: format)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func rerender() async {
        guard let sessionID else { return }
        if let cgImage = try? center.render(sessionID: sessionID) {
            preview = UIImage(cgImage: cgImage)
        }
        if let session = center.imageSessions[sessionID] {
            canUndo = session.canUndo
            operationCount = session.appliedOperations.count
        }
    }
}
#endif
