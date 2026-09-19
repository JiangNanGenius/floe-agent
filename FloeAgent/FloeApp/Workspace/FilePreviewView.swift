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
    @StateObject private var officeSession = OfficeFileSession()
    @State private var nativeOfficeURL: URL?
    @State private var content: FileContent?
    @State private var pdfURL: URL?
    @State private var binaryPreviewURL: URL?
    @State private var loadError: String?
    @State private var isIDEPresented = false
    @State private var isOfficeEditorPresented = false
    @State private var quickLookURL: URL?
    @State private var previewError: String?
    @State private var mediaEditorSource: URL?
    @State private var engineeringPackage: EngineeringPreviewPackage?
    @State private var isEngineeringFullScreen = false
    @State private var engineeringReview: EngineeringReviewCapture?
    @State private var engineeringRoot: URL?
    @State private var cadDirty = false
    @State private var confirmDiscardCAD = false
    @State private var shareURL: URL?
    @State private var isPreparingShare = false
    /// Sharing a cloud/network snapshot must not clear the preview copy that
    /// currently owns the visible document, so it uses its own temp store.
    @StateObject private var shareCopy = RemoteFilePreviewCopy()

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView {
                    Label("inspector.preview.error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                }
            } else if let engineeringPackage {
                if isEngineeringFullScreen {
                    Color.clear
                } else {
                    engineeringView(engineeringPackage)
                }
            } else if nativeOfficeURL != nil {
                if isOfficeEditorPresented {
                    ContentUnavailableView("正在全屏编辑", systemImage: "doc.richtext")
                } else {
                    VStack(spacing: 0) {
                        if officeSession.isRemoteSnapshot {
                            // Preview-only snapshot: no edit entry exists for
                            // this document anywhere in the preview; say why
                            // and how to get an editable copy.
                            Label(OfficeFileSession.remoteSnapshotHint, systemImage: "icloud.and.arrow.down")
                                .font(.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(.bar)
                                .accessibilityIdentifier("file.preview.office.remoteHint")
                        }
                        OfficeDocumentSurface(session: officeSession)
                    }
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
        .fullScreenCover(isPresented: $isEngineeringFullScreen, onDismiss: { Task { await load() } }) {
            if let engineeringPackage {
                NavigationStack {
                    engineeringView(engineeringPackage, editing: true)
                        .navigationTitle(fileName)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("engineering.done") {
                                    if cadDirty { confirmDiscardCAD = true } else { isEngineeringFullScreen = false }
                                }
                                    .accessibilityIdentifier("engineering.done")
                            }
                        }
                }
                .interactiveDismissDisabled(cadDirty)
                .confirmationDialog("engineering.cad.unsaved", isPresented: $confirmDiscardCAD, titleVisibility: .visible) {
                    Button("engineering.cad.discard", role: .destructive) { cadDirty = false; isEngineeringFullScreen = false }
                    Button("engineering.cad.keepEditing", role: .cancel) {}
                }
                .sheet(item: $engineeringReview) { capture in
                    EngineeringReviewSheet(capture: capture, conversationID: engineeringConversationID, center: center)
                }
            }
        }
        .sheet(item: Binding(get: { isEngineeringFullScreen ? nil : engineeringReview }, set: { engineeringReview = $0 })) { capture in
            EngineeringReviewSheet(capture: capture, conversationID: engineeringConversationID, center: center)
        }
        .fullScreenCover(item: $mediaEditorSource, onDismiss: { Task { await load() } }) { url in
            if let root = center.currentRootURL {
                NavigationStack { MediaEditorView(workspaceRoot: root, previewURL: url) }
            }
        }
        .sheet(item: $quickLookURL) { url in
            QuickLookView(url: url)
                .ignoresSafeArea()
        }
        .sheet(item: $shareURL) { url in
            PreviewShareSheet(items: [url])
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $isOfficeEditorPresented, onDismiss: {
            Task { await load() }
        }) {
            NavigationStack {
                OfficeDocumentEditorView(relativePath: relativePath,
                                         session: officeSession,
                                         stableInkIdentity: remoteInkIdentity)
            }
        }
        .onDisappear {
            if !isOfficeEditorPresented { Task { await officeSession.release() } }
        }
        .alert("无法预览文件", isPresented: Binding(
            get: { previewError != nil },
            set: { if !$0 { previewError = nil } }
        )) { Button("好", role: .cancel) {} } message: {
            Text(previewError ?? "")
        }
    }

    private var engineeringConversationID: UUID? {
        guard let id = conversationID ?? router.selectedConversationID,
              center.workspaceID(for: id) == center.currentWorkspace?.id else { return nil }
        return id
    }

    private func engineeringView(_ package: EngineeringPreviewPackage, editing: Bool = false) -> some View {
        EngineeringFilePreview(package: package, onReview: { capture in
            engineeringReview = EngineeringReviewCapture(context: "Workspace path: \(relativePath)\n" + capture.context, image: capture.image)
        }, onSave: editing && engineeringRoot != nil && (package.kind == .dxf || package.kind == .dwg) ? { data, baseline in
            guard let service = center.fileService, service.guardResolver.rootURL == engineeringRoot else {
                throw CocoaError(.fileReadNoPermission)
            }
            let path = relativePath
            let result = try await Task.detached(priority: .userInitiated) {
                try service.commitBinaryEdit(path: path, data: data, expectedSHA256: baseline)
            }.value
            return result.write.sha256
        } : nil, onDirty: { cadDirty = $0 })
    }

    private var fileName: String {
        (relativePath as NSString).lastPathComponent
    }

    private var isPDF: Bool {
        WorkspaceFileType.isPDF(relativePath)
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
        WorkspaceFileType.isOffice(relativePath)
    }

    private var officeEditingAvailable: Bool {
        isOfficeDocument
            && OfficeFileSession.available
            && !center.isCloudWorkspacePath(relativePath)
            && !center.isNetworkWorkspacePath(relativePath)
            && center.fileService != nil
    }

    /// Stable logical identity for a cloud/network Office document. Its local
    /// editing URL is a fresh `remotePreview.store` copy whose directory changes
    /// on every load, so the physical path can never key persisted ink settings.
    /// Local Office documents return nil and keep their physical-URL identity.
    private var remoteInkIdentity: OfficeInkDocumentIdentity? {
        guard center.isCloudWorkspacePath(relativePath) || center.isNetworkWorkspacePath(relativePath) else {
            return nil
        }
        return OfficeInkDocumentIdentity(workspaceIdentity: center.currentWorkspace?.id.uuidString,
                                         relativePath: relativePath)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if engineeringPackage != nil {
                Button { isEngineeringFullScreen = true } label: {
                    Label("engineering.fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .accessibilityIdentifier("file.preview.engineering.fullscreen")
            }
            if WorkspaceFileType.isMedia(relativePath),
               !center.isCloudWorkspacePath(relativePath), !center.isNetworkWorkspacePath(relativePath) {
                Button {
                    do {
                        guard let service = center.fileService else { throw CocoaError(.fileReadNoPermission) }
                        mediaEditorSource = try service.guardResolver.resolve(relativePath)
                    } catch { previewError = error.localizedDescription }
                } label: { Label("媒体工作台", systemImage: "film.stack") }
                .accessibilityIdentifier("file.preview.mediaEditor")
            }
            if isHTML, content != nil {
                Button {
                    startWebPreview()
                } label: {
                    Label("预览网页", systemImage: "safari")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("file.preview.html")
            }
            // Explicit share of the *current* file: the visible document is
            // resolved through the guard (local) or snapshotted (cloud/network)
            // and never re-decoded as text.
            Button {
                prepareShare()
            } label: {
                Label("file.preview.share", systemImage: "square.and.arrow.up")
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .disabled(isPreparingShare || center.fileService == nil)
            .accessibilityLabel("file.preview.share")
            .accessibilityIdentifier("file.preview.share")
            if allowsIDEExpansion,
               WorkspaceFileRouter.allowsCodeEditor(relativePath),
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
                .accessibilityIdentifier("file.preview.openIDE")
            }
            if officeEditingAvailable {
                Button {
                    isOfficeEditorPresented = true
                } label: {
                    Label("office.editor.open", systemImage: "square.and.pencil")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("office.editor.open")
                .disabled(!officeSession.canAct)
            }
            // Low-frequency actions live behind More instead of occupying a
            // permanent toolbar badge.
            Menu {
                if let onAddToContext {
                    Button {
                        onAddToContext()
                    } label: {
                        Label("inspector.context.add", systemImage: "text.badge.plus")
                    }
                    .accessibilityIdentifier("file.preview.addContext")
                }
                if !isTextual, nativeOfficeURL == nil, quickLookAvailable {
                    Button {
                        presentQuickLook()
                    } label: {
                        Label("inspector.preview.quicklook", systemImage: "eye")
                    }
                    .accessibilityIdentifier("file.preview.quicklook")
                }
            } label: {
                Label("file.preview.more", systemImage: "ellipsis.circle")
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("file.preview.more")
            .accessibilityIdentifier("file.preview.more")
            .disabled(onAddToContext == nil && (isTextual || nativeOfficeURL != nil || !quickLookAvailable))
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
        nativeOfficeURL = nil
        engineeringPackage = nil
        engineeringRoot = nil
        cadDirty = false
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
        if EngineeringPreviewKind.identify(relativePath) != nil, let service = center.fileService {
            do {
                let package: EngineeringPreviewPackage
                if center.isCloudWorkspacePath(relativePath) || center.isNetworkWorkspacePath(relativePath) {
                    let bytes = try await center.readRemotePreview(relativePath: relativePath)
                    package = try EngineeringPreviewPackage.single(name: fileName, bytes: bytes)
                } else {
                    engineeringRoot = service.guardResolver.rootURL
                    let path = relativePath
                    let work = Task.detached(priority: .userInitiated) {
                        try EngineeringPreviewPackage.load(path: path, service: service)
                    }
                    package = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                }
                try Task.checkCancellation()
                engineeringPackage = package
                await center.recordRecentFile(relativePath: relativePath, displayName: fileName)
            } catch is CancellationError {} catch { loadError = error.localizedDescription }
            return
        }
        if isOfficeDocument, OfficeFileSession.available, let service = center.fileService {
            do {
                // A cloud/network document is staged into a private temporary
                // copy; the session must treat it as a read-only snapshot and
                // never present edits as a successful remote save.
                let remote = center.isCloudWorkspacePath(relativePath) || center.isNetworkWorkspacePath(relativePath)
                let url: URL
                if remote {
                    let bytes = try await center.readRemotePreview(relativePath: relativePath)
                    try Task.checkCancellation()
                    url = try remotePreview.store(bytes, fileName: fileName)
                } else {
                    url = try service.guardResolver.resolve(relativePath)
                    try service.guardResolver.assertReadableSize(url)
                }
                officeSession.isRemoteSnapshot = remote
                nativeOfficeURL = url
                await officeSession.open(url)
                await center.recordRecentFile(relativePath: relativePath, displayName: fileName)
            } catch { loadError = error.localizedDescription }
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

    /// Shares the exact document currently on screen. Cloud/network paths are
    /// snapshotted into a private temporary copy (never re-decoded as text),
    /// and the visible preview copy is left untouched.
    private func prepareShare() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        Task {
            defer { isPreparingShare = false }
            let remote = center.isCloudWorkspacePath(relativePath) || center.isNetworkWorkspacePath(relativePath)
            do {
                if !remote, let pdfURL { shareURL = pdfURL; return }
                if !remote, let binaryPreviewURL { shareURL = binaryPreviewURL; return }
                if remote {
                    let bytes = try await center.readRemotePreview(relativePath: relativePath)
                    try Task.checkCancellation()
                    shareURL = try shareCopy.store(bytes, fileName: fileName)
                    return
                }
                guard let service = center.fileService else { throw CocoaError(.fileReadNoPermission) }
                let url = try service.guardResolver.resolve(relativePath)
                try service.guardResolver.assertReadableSize(url)
                shareURL = url
            } catch is CancellationError {
            } catch { previewError = error.localizedDescription }
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

/// Plain share sheet for the file currently shown by the preview.
private struct PreviewShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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
