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
import FloeImages
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
    /// Standalone Office editor expansion ("Edit in Office"). The preview
    /// session is released before it presents and a fresh session is released
    /// again on dismiss, so one document never has two live working copies.
    @State private var isOfficeEditorPresented = false
    @State private var editorSession: OfficeFileSession?
    @State private var quickLookURL: URL?
    @State private var previewError: String?
    @State private var mediaEditorSource: URL?
    /// Archive tree browser for this preview's archive (bounded extraction).
    @State private var isArchiveBrowserPresented = false
    @State private var imageEditRequest: WorkspaceImageEditRequest?
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
                if isIDEPresented || isOfficeEditorPresented {
                    // The standalone Office editor (or the IDE's internal tab
                    // for non-Office routing) owns the document now; the
                    // embedded preview session was released before it opened,
                    // so exactly one live session exists per file.
                    ContentUnavailableView("office.editor.openedElsewhere", systemImage: "doc.richtext")
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
                VStack(spacing: 0) {
                    // Read-only/unsupported image locations keep the Quick Look
                    // preview but say why no edit entry exists, instead of
                    // offering an edit that could never be written back.
                    if let reason = imageEditUnavailableReason {
                        Label(reason, systemImage: "lock")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.bar)
                            .accessibilityIdentifier("file.preview.imageEditUnavailable")
                    }
                    QuickLookView(url: binaryPreviewURL)
                        .accessibilityIdentifier("file.preview.binary.inline")
                }
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
        .fullScreenCover(isPresented: $isIDEPresented, onDismiss: {
            // The IDE can be swipe-dismissed on a clean session without
            // invoking onSaved. The Office preview session was released
            // before the IDE opened, so reload here to restore the embedded
            // preview instead of leaving the "opening in editor" placeholder.
            Task { await load() }
        }) {
            WorkspaceIDEView(
                initialRelativePath: relativePath,
                center: center
            ) {
                Task { await load() }
            }
        }
        .fullScreenCover(isPresented: $isArchiveBrowserPresented) {
            NavigationStack {
                ArchiveBrowserView(relativePath: relativePath, center: center)
            }
        }
        .fullScreenCover(isPresented: $isOfficeEditorPresented, onDismiss: {
            // The standalone editor owns its own save/exit flow; releasing the
            // session here frees the working copy and the reload restores the
            // embedded preview against the committed bytes.
            let finished = editorSession
            editorSession = nil
            Task {
                await finished?.release()
                await load()
            }
        }) {
            if let editorSession, let nativeOfficeURL {
                OfficeStandaloneEditorHost(
                    relativePath: relativePath,
                    documentURL: nativeOfficeURL,
                    session: editorSession
                )
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
        // The built-in image workbench edits the selected workspace file in
        // place; dismissing it reloads the preview against the committed
        // bytes without leaving the inspector/document-tab context.
        .fullScreenCover(item: $imageEditRequest, onDismiss: { Task { await load() } }) { request in
            FloeImageEditorView(sourceURL: request.sourceURL) { data in
                try await saveEditedImage(request, editorPNG: data)
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
        .onDisappear {
            if !isIDEPresented, !isOfficeEditorPresented { Task { await officeSession.release() } }
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

    /// Opens the document in the standalone Office editor. The embedded
    /// preview session is released first so the same original file never has
    /// two live document sessions (two working copies that would conflict on
    /// save); dismissing the editor reloads the preview against the committed
    /// bytes.
    private func presentOfficeEditor() {
        guard !isOfficeEditorPresented, !isIDEPresented else { return }
        Task {
            await officeSession.release()
            editorSession = OfficeFileSession()
            isOfficeEditorPresented = true
        }
    }

    // MARK: - Image editing

    /// Who may edit this preview's image: the local workspace when the file
    /// has a writable raster container, or the localized reason it cannot be
    /// overwritten (cloud/network snapshots, read-only mounts, unsupported
    /// formats). Nil for non-image previews so their toolbars stay unchanged.
    private var imageEditAvailability: ImageEditAvailability? {
        guard WorkspaceFileType.isImage(relativePath) else { return nil }
        guard center.fileService != nil else {
            return .unavailable(OfficeInkText.t(
                "当前工作区不可用，无法编辑。",
                "The workspace is unavailable, so editing is unavailable."
            ))
        }
        if center.isCloudWorkspacePath(relativePath) {
            return .unavailable(OfficeInkText.t(
                "云工作区文件仅供只读预览，本版本不支持写回原文件。",
                "Cloud workspace files are preview-only here; writing back is not supported in this version."
            ))
        }
        if center.isNetworkWorkspacePath(relativePath) {
            if let mount = center.networkWorkspaceMount(for: relativePath), mount.readOnly {
                return .unavailable(OfficeInkText.t(
                    "“\(mount.name)”是只读网络挂载，无法写回文件。",
                    "“\(mount.name)” is a read-only network mount, so the file cannot be written back."
                ))
            }
            return .unavailable(OfficeInkText.t(
                "网络挂载文件仅供只读预览，本版本不支持写回原文件。",
                "Network mount files are preview-only here; writing back is not supported in this version."
            ))
        }
        guard ImageFileFormat(pathExtension: WorkspaceFileType.pathExtension(for: relativePath)) != nil else {
            return .unavailable(OfficeInkText.t(
                "此图片格式暂不支持编辑（支持 PNG、JPEG、HEIC）。",
                "This image format can't be edited yet (PNG, JPEG and HEIC are supported)."
            ))
        }
        return .editable
    }

    private var imageEditUnavailableReason: String? {
        if case .unavailable(let reason) = imageEditAvailability { return reason }
        return nil
    }

    /// Opens the built-in image workbench on the exact workspace file. The
    /// guard-resolved URL keeps the workspace's security-scoped access, and
    /// the pre-edit digest travels with the request so the commit can never
    /// overwrite a file that changed while the editor was open.
    private func presentImageEditor() {
        guard let service = center.fileService else {
            previewError = OfficeInkText.t(
                "当前工作区不可用，无法编辑。",
                "The workspace is unavailable, so editing is unavailable."
            )
            return
        }
        guard let format = ImageFileFormat(
            pathExtension: WorkspaceFileType.pathExtension(for: relativePath)
        ) else {
            previewError = OfficeInkText.t(
                "此图片格式暂不支持编辑（支持 PNG、JPEG、HEIC）。",
                "This image format can't be edited yet (PNG, JPEG and HEIC are supported)."
            )
            return
        }
        let path = relativePath
        Task {
            do {
                let request = try await Task.detached(priority: .userInitiated) {
                    let url = try service.guardResolver.resolve(path)
                    try service.guardResolver.assertReadableSize(url)
                    let metadata = try service.metadata(path)
                    guard !metadata.isDirectory else { throw CocoaError(.fileReadNoPermission) }
                    guard FileManager.default.isWritableFile(atPath: url.path) else {
                        throw ImageEditSaveFailure(message: OfficeInkText.t(
                            "该文件在当前位置不可写，请先调整权限或复制到可写位置。",
                            "This file is not writable in its current location; adjust permissions or copy it somewhere writable first."
                        ))
                    }
                    return WorkspaceImageEditRequest(
                        relativePath: path,
                        sourceURL: url,
                        baselineSHA256: metadata.sha256,
                        rootURL: service.guardResolver.rootURL,
                        format: format
                    )
                }.value
                guard request.relativePath == relativePath else { return }
                imageEditRequest = request
            } catch { previewError = error.localizedDescription }
        }
    }

    /// Re-encodes the editor's verified PNG into the destination file's own
    /// raster container, then commits it atomically through the workspace
    /// file service against the pre-edit digest.
    private func saveEditedImage(_ request: WorkspaceImageEditRequest, editorPNG: Data) async throws {
        guard request.relativePath == relativePath,
              let service = center.fileService,
              service.guardResolver.rootURL == request.rootURL else {
            throw CocoaError(.fileReadNoPermission)
        }
        do {
            let payload = try await Task.detached(priority: .userInitiated) {
                try ImageFileEncoder.reencode(editorPNG, as: request.format)
            }.value
            let path = request.relativePath
            let baseline = request.baselineSHA256
            _ = try await Task.detached(priority: .userInitiated) {
                try service.commitBinaryEdit(path: path, data: payload, expectedSHA256: baseline)
            }.value
        } catch let error as WorkspaceToolError {
            if case .tooLarge(let limit) = error {
                let mebibytes = limit / (1024 * 1024)
                throw ImageEditSaveFailure(message: OfficeInkText.t(
                    "编辑后的图片超过工作区单次写入上限（\(mebibytes) MiB），请先压缩原图再编辑。",
                    "The edited image exceeds the workspace write limit (\(mebibytes) MiB); compress the original before editing."
                ))
            }
            throw error
        }
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
            if imageEditAvailability?.isEditable == true {
                Button {
                    presentImageEditor()
                } label: {
                    Label(
                        OfficeInkText.t("编辑图片", "Edit Image"),
                        systemImage: "square.and.pencil"
                    )
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel(OfficeInkText.t("编辑图片", "Edit Image"))
                .accessibilityIdentifier("file.preview.imageEdit")
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
            // A PDF expands into the IDE's internal document tab (native
            // overlay inside the workbench), never an outer task page.
            if allowsIDEExpansion,
               isPDF,
               pdfURL != nil,
               center.fileService != nil {
                Button {
                    isIDEPresented = true
                } label: {
                    Label("在编辑器中打开", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("在编辑器中打开")
                .accessibilityIdentifier("file.preview.pdf.openIDE")
            }
            if officeEditingAvailable {
                Button {
                    presentOfficeEditor()
                } label: {
                    Label("office.editor.open", systemImage: "square.and.pencil")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("office.editor.open")
                .accessibilityIdentifier("file.preview.office.edit")
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

    /// The archive browser needs a pinned workspace root and an archive
    /// extension the browser can route (other formats still open there to
    /// report their own truthful unsupported reason).
    private var isArchiveBrowsable: Bool {
        WorkspaceFileType.isArchive(relativePath)
            && (center.fileService?.guardResolver.rootURL ?? center.currentRootURL) != nil
    }

    /// Placeholder for non-text files (Office documents, PDFs, images, …):
    /// never decode their bytes as text — offer system Quick Look instead.
    private var binaryPlaceholder: some View {
        ContentUnavailableView {
            Label(fileName, systemImage: "doc.richtext")
        } description: {
            Text("inspector.preview.binary")
        } actions: {
            if WorkspaceFileType.isArchive(relativePath), isArchiveBrowsable {
                Button {
                    isArchiveBrowserPresented = true
                } label: {
                    Label("archive.browse", systemImage: "doc.zipper")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("file.preview.archive.browse")
            }
            if isArchiveBrowsable {
                quickLookButton.buttonStyle(.bordered)
            } else {
                quickLookButton.buttonStyle(.borderedProminent)
            }
            if officeEditingAvailable {
                Button {
                    presentOfficeEditor()
                } label: {
                    Label("office.editor.open", systemImage: "square.and.pencil")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Quick Look is the primary action unless the archive browser button
    /// above it is already the prominent one. The style is chosen with an
    /// explicit if/else because `.bordered` and `.borderedProminent` are
    /// different style types and cannot be selected in one ternary.
    private var quickLookButton: some View {
        Button {
            presentQuickLook()
        } label: {
            Label("inspector.preview.quicklook", systemImage: "eye")
        }
        .disabled(!quickLookAvailable)
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

/// Whether the preview may offer its image edit entry, or the localized
/// reason it cannot write the file back.
private enum ImageEditAvailability: Equatable {
    case editable
    case unavailable(String)

    var isEditable: Bool { self == .editable }
}

/// Everything one image edit session needs to commit back to the exact file
/// it opened: the guard-resolved URL, the pre-edit digest, the workspace
/// root it belongs to and the raster container matching the path.
private struct WorkspaceImageEditRequest: Sendable, Identifiable {
    let id = UUID()
    let relativePath: String
    let sourceURL: URL
    let baselineSHA256: String
    let rootURL: URL
    let format: ImageFileFormat
}

/// Bilingual save failure raised inside the editor's save closure; the
/// editor surfaces `localizedDescription` in its alert.
private struct ImageEditSaveFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
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
