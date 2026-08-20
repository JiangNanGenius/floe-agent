// FloeApp — Files view model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Presentation state for the Files tab: recent files, picker/quick-look
// entry points, working-copy writeback and image-editor navigation. All
// work goes through FilesCenter.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeModels

/// View model for the Files tab.
@MainActor
final class FilesViewModel: ObservableObject {

    @Published var showingPicker = false
    @Published var quickLookAttachment: AttachmentRef?
    @Published var editingImage: AttachmentRef?
    @Published var errorMessage: String?

    let center: FilesCenter

    init(center: FilesCenter) {
        self.center = center
    }

    var recentFiles: [AttachmentRef] {
        center.recentFiles
    }

    /// Registers a picked document URL from the document picker.
    func didPickDocument(url: URL) async {
        do {
            _ = try await center.registerPickedDocument(url: url, displayName: url.lastPathComponent)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openQuickLook(_ attachment: AttachmentRef) {
        quickLookAttachment = attachment
    }

    func openImageEditor(_ attachment: AttachmentRef) {
        editingImage = attachment
    }

    func removeRecent(_ attachment: AttachmentRef) {
        center.recentFiles.removeAll { $0.id == attachment.id }
    }
}
#endif
