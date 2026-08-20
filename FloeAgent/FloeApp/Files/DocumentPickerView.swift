// FloeApp — Document picker (UIDocumentPickerViewController wrapper).
//
// SPDX-License-Identifier: MPL-2.0
//
// Presents the system document picker for opening files into the app.
// Security-scoped access is granted by the picker; the picked URL is
// bookmarked by FilesCenter.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A UIViewControllerRepresentable wrapping the system document picker.
struct DocumentPickerView: UIViewControllerRepresentable {
    /// Content types the picker offers (documents + images).
    var contentTypes: [UTType] = [
        .pdf, .text, .image, .png, .jpeg, .heic,
        UTType(filenameExtension: "docx") ?? .data,
        UTType(filenameExtension: "xlsx") ?? .data,
        UTType(filenameExtension: "pptx") ?? .data
    ]
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}
#endif
