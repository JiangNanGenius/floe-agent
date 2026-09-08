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
    /// Important-file shortcuts can open before the inspector column has
    /// mounted the task's private workspace. Bind it here as a fallback so
    /// SVG/PDF/text previews never depend on opening “All files” first.
    var conversationID: UUID? = nil
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var router: AppRouter
    /// Called when the user adds this file to the conversation context.
    var onAddToContext: (() -> Void)? = nil
    /// Disabled when the preview is already hosted inside WorkspaceIDEView.
    var allowsIDEExpansion = true

    @StateObject private var remotePreview = RemoteFilePreviewCopy()
    @State private var content: FileContent?
    @State private var pdfURL: URL?
    @State private var binaryPreviewURL: URL?
    @State private var loadError: String?
    @State private var isIDEPresented = false
    @State private var isOfficeEditorPresented = false
    @State private var quickLookURL: URL?
    @State private var previewError: String?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView {
                    Label("inspector.preview.error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                }
            } else if let pdfURL {
                InlinePDFReader(url: pdfURL, validateRead: {
                    if remotePreview.url == pdfURL { return }
                    guard let service = center.fileService else { throw CocoaError(.fileReadNoPermission) }
                    let resolved = try service.guardResolver.resolve(relativePath)
                    guard resolved.standardizedFileURL == pdfURL.standardizedFileURL else { throw CocoaError(.fileReadNoPermission) }
                    try service.guardResolver.assertReadableSize(resolved)
                }).id(pdfURL)
            } else if let binaryPreviewURL {
                QuickLookView(url: binaryPreviewURL)
                    .accessibilityIdentifier("file.preview.binary.inline")
            } else if let content {
                contentView(content)
            } else if !isTextual && !isPDF {
                binaryPlaceholder
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
        .fullScreenCover(isPresented: $isIDEPresented) {
            WorkspaceIDEView(
                initialRelativePath: relativePath,
                center: center
            ) {
                Task { await load() }
            }
        }
        .sheet(item: $quickLookURL) { url in
            QuickLookView(url: url)
                .ignoresSafeArea()
        }
        .sheet(isPresented: $isOfficeEditorPresented) {
            NavigationStack {
                OfficeDocumentEditorView(relativePath: relativePath, center: center) {
                    Task { await load() }
                }
            }
        }
        .alert("无法预览文件", isPresented: Binding(
            get: { previewError != nil },
            set: { if !$0 { previewError = nil } }
        )) { Button("好", role: .cancel) {} } message: {
            Text(previewError ?? "")
        }
    }

    private var fileName: String {
        (relativePath as NSString).lastPathComponent
    }

    private var isPDF: Bool {
        (relativePath as NSString).pathExtension.lowercased() == "pdf"
    }

    private var isMarkdown: Bool {
        WorkspaceFileType.isMarkdown(relativePath)
    }

    private var isHTML: Bool {
        WorkspaceFileType.isHTML(relativePath)
    }

    private var isTextual: Bool {
        WorkspaceFileType.isText(relativePath)
    }

    private var isOfficeDocument: Bool {
        ["docx", "xlsx", "pptx"].contains((relativePath as NSString).pathExtension.lowercased())
    }

    private var officeEditingAvailable: Bool {
        isOfficeDocument
            && !center.isCloudWorkspacePath(relativePath)
            && !center.isNetworkWorkspacePath(relativePath)
            && center.fileService != nil
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if isHTML, content != nil {
                Button {
                    startWebPreview()
                } label: {
                    Label("预览网页", systemImage: "safari")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("file.preview.html")
            }
            if let onAddToContext {
                Button {
                    onAddToContext()
                } label: {
                    Label("inspector.context.add", systemImage: "text.badge.plus")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("inspector.context.add")
            }
            if allowsIDEExpansion,
               isTextual,
               content != nil,
               !center.isCloudWorkspacePath(relativePath),
               !center.isNetworkWorkspacePath(relativePath) {
                Button {
                    isIDEPresented = true
                } label: {
                    Label("在编辑器中打开", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("在编辑器中打开")
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
            if officeEditingAvailable {
                Button {
                    isOfficeEditorPresented = true
                } label: {
                    Label("office.editor.open", systemImage: "square.and.pencil")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("office.editor.open")
            }
        }
    }

    private var quickLookAvailable: Bool {
        center.currentRootURL != nil
    }

    /// Placeholder for non-text files (Office documents, PDFs, images, …):
    /// never decode their bytes as text — offer system Quick Look instead.
    private var binaryPlaceholder: some View {
        ContentUnavailableView {
            Label(fileName, systemImage: "doc.richtext")
        } description: {
            Text("inspector.preview.binary")
        } actions: {
            Button {
                presentQuickLook()
            } label: {
                Label("inspector.preview.quicklook", systemImage: "eye")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!quickLookAvailable)
            if officeEditingAvailable {
                Button {
                    isOfficeEditorPresented = true
                } label: {
                    Label("office.editor.open", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        pdfURL = nil
        binaryPreviewURL = nil
        remotePreview.clear()
        if center.fileService == nil, let conversationID {
            do {
                try await center.openTaskWorkspace(conversationID: conversationID)
            } catch {
                loadError = error.localizedDescription
                return
            }
        }
        guard center.fileService != nil else {
            loadError = String(localized: "inspector.no_workspace")
            return
        }
        if isPDF, let service = center.fileService {
            do {
                if center.isCloudWorkspacePath(relativePath) || center.isNetworkWorkspacePath(relativePath) {
                    let bytes = try await center.readRemotePreview(relativePath: relativePath)
                    try Task.checkCancellation()
                    pdfURL = try remotePreview.store(bytes, fileName: fileName)
                } else {
                    let url = try service.guardResolver.resolve(relativePath)
                    try service.guardResolver.assertReadableSize(url)
                    pdfURL = url
                }
                await center.recordRecentFile(relativePath: relativePath, displayName: fileName)
            } catch { loadError = error.localizedDescription }
            return
        }
        guard isTextual else {
            // Embed the read-only renderer directly in the inspector. Full
            // Office editing remains a separate native-engine qualification.
            do {
                if center.isCloudWorkspacePath(relativePath) || center.isNetworkWorkspacePath(relativePath) {
                    let bytes = try await center.readRemotePreview(relativePath: relativePath)
                    try Task.checkCancellation()
                    binaryPreviewURL = try remotePreview.store(bytes, fileName: fileName)
                } else if let service = center.fileService {
                    let url = try service.guardResolver.resolve(relativePath)
                    try service.guardResolver.assertReadableSize(url)
                    binaryPreviewURL = url
                }
                await center.recordRecentFile(relativePath: relativePath, displayName: fileName)
            } catch { loadError = error.localizedDescription }
            return
        }
        do {
            content = try await center.readFile(relativePath: relativePath)
            await center.recordRecentFile(relativePath: relativePath, displayName: fileName)
        } catch let error as WorkspaceToolError {
            loadError = error.errorDescription ?? error.localizedDescription
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func presentQuickLook() {
        Task {
            do {
                if let pdfURL { quickLookURL = pdfURL; return }
                if center.isCloudWorkspacePath(relativePath) || center.isNetworkWorkspacePath(relativePath) {
                    let bytes = try await center.readRemotePreview(relativePath: relativePath)
                    quickLookURL = try remotePreview.store(bytes, fileName: fileName)
                } else {
                    guard let service = center.fileService else { throw CocoaError(.fileReadNoPermission) }
                    let url = try service.guardResolver.resolve(relativePath)
                    try service.guardResolver.assertReadableSize(url)
                    quickLookURL = url
                }
            } catch is CancellationError {
            } catch { previewError = error.localizedDescription }
        }
    }

    private func startWebPreview() {
        guard let root = center.currentRootURL else { return }
        Task {
            do {
                _ = try await environment.previewCenter.start(
                    root: root,
                    relativeRoot: nil,
                    entry: relativePath
                )
                router.showInspector(.browser)
            } catch {
                previewError = error.localizedDescription
            }
        }
    }
}

/// Lives through fullscreen/sheet presentation; never removes files merely
/// because SwiftUI temporarily hides the parent view.
final class RemoteFilePreviewCopy: ObservableObject {
    private var directory: URL?
    private(set) var url: URL?

    func store(_ bytes: Data, fileName: String) throws -> URL {
        clear()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-preview-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        directory = root
        let target = root.appendingPathComponent((fileName as NSString).lastPathComponent)
        try bytes.write(to: target, options: .atomic)
        url = target
        return target
    }

    func clear() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        url = nil
    }

    deinit { if let directory { try? FileManager.default.removeItem(at: directory) } }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}
#endif
