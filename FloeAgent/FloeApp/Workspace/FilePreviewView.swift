// FloeApp — Workspace file preview.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §4: text files (Markdown / JSON /
// Swift / Python / JS / plain text, ≤10 MiB through the guard) render
// inline; everything else goes through system Quick Look. Markdown reuses
// the FloeMarkdown renderer from T02.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeWorkspace

/// Previews one workspace file. Loaded through WorkspaceCenter's guarded
/// file service; offers edit (text files), Quick Look, and "add to
/// conversation context".
struct FilePreviewView: View {
    let relativePath: String
    @ObservedObject var center: WorkspaceCenter
    /// Called when the user adds this file to the conversation context.
    var onAddToContext: (() -> Void)? = nil

    @State private var content: FileContent?
    @State private var loadError: String?
    @State private var isEditing = false
    @State private var quickLookURL: URL?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView {
                    Label("inspector.preview.error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                }
            } else if let content {
                contentView(content)
            } else {
                ProgressView("inspector.preview.loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task(id: relativePath) { await load() }
        .sheet(isPresented: $isEditing) {
            NavigationStack {
                TextFileEditorView(relativePath: relativePath, center: center) {
                    Task { await load() }
                }
            }
        }
        .sheet(item: $quickLookURL) { url in
            QuickLookView(url: url)
                .ignoresSafeArea()
        }
    }

    private var fileName: String {
        (relativePath as NSString).lastPathComponent
    }

    private var isMarkdown: Bool {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        return ext == "md" || ext == "markdown"
    }

    private var isTextual: Bool {
        let ext = (relativePath as NSString).pathExtension.lowercased()
        return [
            "txt", "md", "markdown", "json", "swift", "py", "js", "ts",
            "c", "h", "cpp", "html", "htm", "css", "xml", "yaml", "yml",
            "toml", "sh", "log", "csv"
        ].contains(ext)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if let onAddToContext {
                Button {
                    onAddToContext()
                } label: {
                    Label("inspector.context.add", systemImage: "text.badge.plus")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("inspector.context.add")
            }
            if isTextual, content != nil {
                Button {
                    isEditing = true
                } label: {
                    Label("inspector.preview.edit", systemImage: "pencil")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("inspector.preview.edit")
            }
            if !isTextual, quickLookAvailable {
                Button {
                    presentQuickLook()
                } label: {
                    Label("inspector.preview.quicklook", systemImage: "eye")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("inspector.preview.quicklook")
            }
        }
    }

    private var quickLookAvailable: Bool {
        center.currentRootURL != nil
    }

    @ViewBuilder
    private func contentView(_ content: FileContent) -> some View {
        ScrollView {
            Group {
                if isMarkdown {
                    MarkdownRendererView(source: content.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(content.text)
                        .font(FloeTheme.Typography.evidence)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .safeAreaInset(edge: .bottom) {
            if content.truncated {
                Label(
                    "inspector.preview.truncated",
                    systemImage: "arrow.down.doc"
                )
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(FloeTheme.pending)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background(FloeTheme.chromeMaterial)
            }
        }
    }

    private func load() async {
        loadError = nil
        content = nil
        guard let service = center.fileService else {
            loadError = String(localized: "inspector.no_workspace")
            return
        }
        do {
            content = try service.readFile(relativePath, byteOffset: 0)
            await center.recordRecentFile(relativePath: relativePath, displayName: fileName)
        } catch let error as WorkspaceToolError {
            loadError = error.errorDescription ?? error.localizedDescription
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func presentQuickLook() {
        guard let root = center.currentRootURL else { return }
        quickLookURL = root.appendingPathComponent(relativePath)
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
#endif
