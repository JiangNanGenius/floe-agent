#if canImport(SwiftUI) && canImport(Photos) && canImport(UIKit)
import SwiftUI
import Photos
import ImageIO
import FloeCore

/// Saves the original image bytes after a fresh read check. The permission
/// request is made only for this explicit action, and asks for add-only access.
@MainActor
struct SaveImageToPhotosButton: View {
    let imageURL: URL
    var expectedSHA256: String? = nil
    var validateRead: (() throws -> Void)? = nil
    @State private var saving = false
    @State private var saved = false
    @State private var failure: String?
    @State private var operationID = UUID()

    var body: some View {
        Button {
            let requestID = UUID()
            operationID = requestID
            Task { await save(requestID: requestID) }
        } label: {
            if saving { ProgressView().controlSize(.small) }
            else {
                Label(saved ? "files.photos.saved" : "files.photos.save",
                      systemImage: saved ? "checkmark" : "square.and.arrow.down")
            }
        }
        .disabled(saving || saved)
        .accessibilityIdentifier("image.save_to_photos")
        .alert("files.photos.failed", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("action.done", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        .onChange(of: imageURL) { _, _ in
            operationID = UUID(); saving = false; saved = false; failure = nil
        }
        .onDisappear { operationID = UUID() }
    }

    private func save(requestID: UUID) async {
        guard !saving else { return }
        saving = true
        defer { if operationID == requestID { saving = false } }
        let target = imageURL
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard operationID == requestID, !Task.isCancelled else { return }
        guard status == .authorized || status == .limited else {
            failure = FloeL10n.l("files.photos.permission")
            return
        }
        do {
            try validateRead?()
            let data = try Data(floeContentsOf: target)
            if let expectedSHA256,
               FloeDigest.sha256Hex(data).lowercased() != expectedSHA256.lowercased() {
                throw CocoaError(.fileReadCorruptFile)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) > 0 else {
                throw CocoaError(.fileReadUnknown)
            }
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
            }
            if operationID == requestID { saved = true }
        } catch {
            if operationID == requestID { failure = FloeL10n.l("files.photos.retry") }
        }
    }
}
#endif
