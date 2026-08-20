// FloeApp — Files tab root.
//
// SPDX-License-Identifier: MPL-2.0
//
// Recent files, a document picker entry, Quick Look preview and the image
// editor. Honest empty state; every file action goes through FilesCenter
// (security-scoped bookmarks, conflict-safe writeback).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels

/// The Files tab root.
struct FilesView: View {
    @StateObject private var viewModel: FilesViewModel
    @StateObject private var center: FilesCenter
    @State private var showingImageCreation = false

    init(center: FilesCenter) {
        self._center = StateObject(wrappedValue: center)
        _viewModel = StateObject(wrappedValue: FilesViewModel(center: center))
    }

    var body: some View {
        Group {
            if viewModel.recentFiles.isEmpty {
                ContentUnavailableView {
                    Label("tab.files", systemImage: "folder")
                } description: {
                    Text("empty.files")
                } actions: {
                    HStack {
                        Button("files.open") { viewModel.showingPicker = true }
                        Button("生成图片") { showingImageCreation = true }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                recentList
            }
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle("tab.files")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("files.open", systemImage: "doc.badge.plus") {
                        viewModel.showingPicker = true
                    }
                    Button("生成图片", systemImage: "wand.and.stars") {
                        showingImageCreation = true
                    }
                } label: {
                    Image(systemName: "plus.circle")
                }
                .accessibilityLabel("files.open")
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            }
        }
        .sheet(isPresented: $viewModel.showingPicker) {
            DocumentPickerView { url in
                viewModel.showingPicker = false
                Task { await viewModel.didPickDocument(url: url) }
            }
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showingImageCreation) {
            RemoteImageCreationView(center: center)
        }
        .sheet(item: $viewModel.quickLookAttachment) { attachment in
            quickLookSheet(for: attachment)
        }
        .sheet(item: $viewModel.editingImage) { attachment in
            NavigationStack {
                ImageEditorView(attachment: attachment, center: center)
            }
        }
        .alert(item: $center.conflict) { conflict in
            Alert(
                title: Text("files.conflict.title"),
                message: Text(conflict.displayName),
                dismissButton: .default(Text("action.done")) {
                    center.conflict = nil
                }
            )
        }
    }

    private var recentList: some View {
        List {
            ForEach(viewModel.recentFiles) { attachment in
                HStack {
                    Image(systemName: icon(for: attachment))
                        .foregroundStyle(FloeTheme.primary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(attachment.displayName)
                            .font(FloeTheme.Typography.body)
                            .lineLimit(1)
                        Text(byteCount(attachment.byteCount))
                            .font(FloeTheme.Typography.metadata)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button {
                            viewModel.openQuickLook(attachment)
                        } label: {
                            Label("files.preview", systemImage: "eye")
                        }
                        if attachment.kind == .image {
                            Button {
                                viewModel.openImageEditor(attachment)
                            } label: {
                                Label("files.edit_image", systemImage: "wand.and.stars")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .foregroundStyle(.secondary)
                    }
                    .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                }
                .frame(minHeight: FloeTheme.minimumTarget)
            }
            .onDelete { offsets in
                let targets = offsets.map { viewModel.recentFiles[$0] }
                for attachment in targets {
                    viewModel.removeRecent(attachment)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func quickLookSheet(for attachment: AttachmentRef) -> some View {
        Group {
            if let url = try? center.resolveURL(for: attachment) {
                NavigationStack {
                    QuickLookView(url: url)
                        .navigationTitle(attachment.displayName)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("action.done") { viewModel.quickLookAttachment = nil }
                            }
                        }
                }
            } else {
                ContentUnavailableView {
                    Label("files.unavailable", systemImage: "doc.questionmark")
                } description: {
                    Text("files.unavailable.hint")
                }
            }
        }
    }

    private func icon(for attachment: AttachmentRef) -> String {
        switch attachment.kind {
        case .image: "photo"
        case .document: "doc"
        case .audio: "waveform"
        case .other: "doc"
        }
    }

    private func byteCount(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
#endif
