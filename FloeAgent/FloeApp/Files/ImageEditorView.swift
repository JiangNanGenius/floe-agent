// FloeApp — Image editor.
//
// SPDX-License-Identifier: MPL-2.0
//
// Non-destructive image editing: preview, undo, and local controls
// (crop/rotate/resize/convert/compress/adjust/metadata removal). Remote
// (provider) operations that the committed adapter cannot perform show the
// honest RemoteImageUnavailableView — never a fake success.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeImages
import FloeModels

/// The image editor screen for one attachment.
struct ImageEditorView: View {
    @StateObject private var viewModel: ImageEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showExport = false
    @State private var exportedURL: IdentifiableURL?

    init(attachment: AttachmentRef, center: FilesCenter) {
        _viewModel = StateObject(
            wrappedValue: ImageEditorViewModel(attachment: attachment, center: center)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            previewArea
            Divider()
            controls
        }
        .navigationTitle("files.edit_image")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("action.done") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("files.export") { showExport = true }
                    .disabled(viewModel.preview == nil)
            }
        }
        .task { await viewModel.load() }
        .confirmationDialog("files.export", isPresented: $showExport) {
            Button("PNG") { export(.png) }
            Button("JPEG") { export(.jpeg) }
            Button("HEIC") { export(.heic) }
        }
        .sheet(item: $exportedURL) { item in
            ShareSheet(items: [item.url])
        }
    }

    private var previewArea: some View {
        Group {
            if let preview = viewModel.preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(FloeTheme.readingSurface)
            } else if let error = viewModel.errorMessage {
                ContentUnavailableView {
                    Label("files.unavailable", systemImage: "photo")
                } description: {
                    Text(error)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var controls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                controlButton("editor.crop", icon: "crop") {
                    await viewModel.apply(.crop(rect: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8)))
                }
                controlButton("editor.rotate", icon: "rotate.right") {
                    await viewModel.apply(.rotate(degrees: 90))
                }
                controlButton("editor.resize", icon: "arrow.up.left.and.arrow.down.right") {
                    await viewModel.apply(.resize(width: 1024, height: 1024, preserveAspect: true))
                }
                controlButton("editor.adjust", icon: "slider.horizontal.3") {
                    await viewModel.apply(.adjustColor(saturation: 1.1, contrast: 1.05, brightness: 0.02))
                }
                controlButton("editor.strip", icon: "eye.slash") {
                    await viewModel.apply(.removeMetadata)
                }
                controlButton("editor.undo", icon: "arrow.uturn.backward", disabled: !viewModel.canUndo) {
                    await viewModel.undo()
                }
            }
            .padding()
        }
        .background(FloeTheme.chromeMaterial)
    }

    private func controlButton(
        _ labelKey: LocalizedStringKey,
        icon: String,
        disabled: Bool = false,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(labelKey)
                    .font(FloeTheme.Typography.metadata)
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .foregroundStyle(disabled ? .secondary : FloeTheme.primary)
    }

    private func export(_ format: ImageOperation.ImageFormat) {
        Task {
            if let url = await viewModel.export(format: format) {
                exportedURL = IdentifiableURL(url: url)
            }
        }
    }
}

/// A system share sheet for the exported image.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Wraps a URL for `.sheet(item:)` presentation.
private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
#endif
