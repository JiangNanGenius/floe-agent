// FloeApp — Quick Look preview (QLPreviewController wrapper).
//
// SPDX-License-Identifier: MPL-2.0
//
// Previews a security-scoped attachment via the system Quick Look. The URL
// is resolved from the stored bookmark by FilesCenter before presentation.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import QuickLook

/// A UIViewControllerRepresentable wrapping QLPreviewController.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        var url: URL

        nonisolated func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            .disabled
        }

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }
    }
}
#endif
