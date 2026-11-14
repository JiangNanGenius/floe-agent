// FloeApp — Workspace file preview.
//
// SPDX-License-Identifier: MPL-2.0
//
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §4: text files (Markdown / JSON /
// Swift / Python / JS / plain text) stream bounded reader pages through
// the existing workspace authority; everything else goes through system Quick Look. Markdown reuses
// the FloeMarkdown renderer from T02.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore
import FloeImages
import FloeWorkspace
import FloeCAD

/// Unknown extensions are candidates, not a text verdict. Validate the
/// complete stream with the existing reader codecs, using bounded chunks.
/// Only a content/encoding refusal routes to Quick Look; read failures,
/// permissions, size limits and cancellation keep their real errors.
enum WorkspacePreviewContentProbe {
    static func usesTextReader(source: any ReaderByteSource, limits: ReaderLimits = .default,
                               cancellation: ReaderCancellation = .never) throws -> Bool {
        try cancellation.throwIfCancelled()
        guard source.byteLength >= 0 else { throw ReaderError.sourceUnavailable("Invalid file size") }
        guard source.byteLength <= limits.maxFileBytes else { throw ReaderError.fileTooLarge(limit: limits.maxFileBytes) }
        if source.byteLength == 0 { return true }
        let sampleCount = Int(min(source.byteLength, 64 * 1_024))
        let sample = try source.read(offset: 0, length: sampleCount)
        guard sample.count == sampleCount else { throw ReaderError.sourceUnavailable("Incomplete preview read") }
        guard let probe = ReaderTextCodec.probe(sample) else { return false }
        var candidates = [probe.encoding]
        if probe.encoding == .utf8, !probe.fromBOM, ReaderTextCodec.gb18030CodecAvailable { candidates.append(.gb18030) }
        for encoding in candidates {
            let start = encoding == probe.encoding ? probe.bomLength : 0
            var validator = ReaderTextValidator(encoding: encoding, startOffset: Int64(start),
                rejectsNUL: encoding.isASCIICompatible)
            var offset = Int64(start), valid = true
            while offset < source.byteLength {
                try cancellation.throwIfCancelled()
                let count = Int(min(Int64(64 * 1_024), source.byteLength - offset))
                let bytes = try source.read(offset: offset, length: count)
                guard bytes.count == count else { throw ReaderError.sourceUnavailable("Incomplete preview read") }
                let last = offset + Int64(count) == source.byteLength
                if validator.consume(bytes, isLast: last) != nil { valid = false; break }
                offset += Int64(count)
            }
            try cancellation.throwIfCancelled()
            if valid { return true }
        }
        return false
    }
}

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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Called when the user adds this file to the conversation context.
    var onAddToContext: (() -> Void)? = nil
    var onDeleted: (() -> Void)? = nil
    /// Optional captured source scope for a preview hosted by another editor.
    /// Ordinary browser entries keep their existing current-workspace behavior.
    var expectedDeletionScope: WorkspaceFileActionScope? = nil
    /// Disabled when the preview is already hosted inside WorkspaceIDEView.
    var allowsIDEExpansion = true
    /// The inspector already owns the filename, Back, expand and Close.
    var embeddedInInspector = false
    /// Disabled when the preview is already hosted INSIDE the design
    /// conversation page's editor handoff: the page is presenting this
    /// view, so re-presenting the same design page from here would
    /// recursively stack a second one. The design entry is the page
    /// owner's job, never the nested handoff's.
    var allowsDesignPage = true

    @StateObject private var remotePreview = RemoteFilePreviewCopy()
    @StateObject private var officeSession = OfficeFileSession()
    @State private var nativeOfficeURL: URL?
    @State private var content: FileContent?
    @State private var textPreviewSource: TextReaderSource?
    @State private var unknownBinaryContent = false
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
    @State private var deletionRequest: WorkspaceFileDeletionRequest?
    @State private var deletingFile = false
    @State private var deletionGeneration = UUID()
    @State private var deletionPreparationTask: Task<Void, Never>?
    @State private var mediaEditorSource: URL?
    /// Reading mode: a read-only alternate view of this same original file
    /// (never an editor, and never a conversion of the original bytes).
    @State private var isReadingModePresented = false
    /// Archive tree browser for this preview's archive (bounded extraction).
    @State private var isArchiveBrowserPresented = false
    @State private var imageEditRequest: WorkspaceImageEditRequest?
    @State private var engineeringPackage: EngineeringPreviewPackage?
    @State private var largePreviewPath: String?
    @State private var mayOpenLargeModel = false
    private var usesExpandedReadOnly: Bool { largePreviewPath == relativePath }

    /// Native FloeCAD document (`.floecad` package) opened in the workbench.
    @State private var floecadDocument: FloeCADDocument?
    @State private var nativeModelImportPath: String?
    @State private var importedModelPath: String?
    @State private var isBuildingPresented = false
    @State private var incomingBuildingPlan: CADSketchTransferEnvelope?
    @State private var drawingTransferTask: Task<Void,Never>?
    @State private var drawingTransferGeneration = UUID()
    /// Bound before the Worker's asynchronous selection extraction starts.
    /// A late page callback cannot mint a fresh operation after navigation.
    @State private var drawingTransferSourceEpoch = UUID()
    @State private var transferringDrawing = false
    @State private var drawingTransferDestination: CADFromDrawingDestination?
    @State private var isDrawingTransferPresented = false
    @State private var waitingForDrawingCoverDismissal = false
    @State private var isEngineeringFullScreen = false
    @State private var engineeringReview: EngineeringReviewCapture?
    @State private var engineeringRoot: URL?
    @State private var cadDirty = false
    @State private var confirmDiscardCAD = false
    /// E33: a verified previous save found by the non-mutating inspection.
    /// Present only while the damaged package is still the target; the sheet
    /// decides whether to create a new copy.
    @State private var recoveryPreview: CADRecoveryPreview?
    @State private var recoverySheet: CADRecoverySheet?
    @State private var recoveredCopyNotice: CADRecoveryRestoreResult?
    /// Fences every inspection/restore completion to the load that started it
    /// and records the one-way switch from the damaged package to the verified
    /// new copy. A late result can never present a stale sheet, open a second
    /// copy, or make the preview act on the damaged original again.
    @State private var recoveryFence = CADRecoveryPresentationFence()
    @State private var recoveryTicket: CADRecoveryPresentationFence.Ticket?
    @State private var recoveredCopyPath: String?
    @State private var recoveredCopyOrigin: String?
    /// Restarts the bounded `.task` load after a sheet asks for a refresh
    /// without spawning an untracked task that can outlive this view.
    @State private var reloadGeneration = 0
    @StateObject private var engineeringSession = EngineeringWebSession()
    @State private var shareURL: URL?
    @State private var isPreparingShare = false
    /// Sharing a cloud/network snapshot must not clear the preview copy that
    /// currently owns the visible document, so it uses its own temp store.
    @StateObject private var shareCopy = RemoteFilePreviewCopy()
    /// T6 design entrance: the current workspace file as a typed design
    /// target (workspace-scoped, permission re-derived by the adapter).
    @State private var designTarget: DesignTarget?
    /// File entry without a conversation: presents the conversational start
    /// bound to this file (a genuine ordinary task, no old form).
    @State private var fileDesignTarget: DesignTarget?
    @State private var basicMachiningSelection: CADSelectionContext?
    @State private var printPreparation: PrintPreparationRequest?

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView {
                    Label("inspector.preview.error", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadError)
                } actions: {
                    if let preview = recoveryPreview {
                        Button("cad.recovery.action.review") {
                            recoverySheet = .decision(preview)
                        }
                        .accessibilityIdentifier("cad.recovery.reviewButton")
                    }
                    if mayOpenLargeModel {
                        Button("engineering.large_model.open") { largePreviewPath = displayedPath }
                    }
                }
            } else if let floecadDocument {
                // The Canvas entry path (Apply to canvas / Make variant) is
                // host-injected: FloeCADKit never sees app Canvas types. The
                // closures export a real projected drawing page and commit
                // through the same atomic patch primitives as the 2D flow.
                // Floe-level chrome (save status + fullscreen) is the SAME
                // shared modifier the qualification fixture presents.
                FloeCADWorkbenchView(
                    document: floecadDocument,
                    canvasActions: CADCanvasActionBridge.actions(
                        assetStore: environment.creativeAssetStore),
                    onSelectionContextChange: {basicMachiningSelection=$0})
                    .modifier(FloeCADHostChrome(document: floecadDocument,
                                                canvasActions: CADCanvasActionBridge.actions(
                                                    assetStore: environment.creativeAssetStore),
                                                onSelectionContextChange: {basicMachiningSelection=$0},
                                                workspaceRoot:center.fileService?.guardResolver.rootURL,
                                                workspaceID:center.currentWorkspace?.id,
                                                conversationID:engineeringConversationID,
                                                externalCoverPresented:isBuildingPresented || printPreparation != nil,
                                                manufacturingAvailable:canPreparePrint,onPreparePrint:prepareWorkspacePrint))
                    .modifier(CADSelectionAssistantEntry(document: floecadDocument, selection: basicMachiningSelection,
                        relativePath: displayedPath, root: center.fileService?.guardResolver.rootURL,
                        workspaceID: center.currentWorkspace?.id, conversationID: conversationID))
                    .modifier(CADManufacturingEntry(document: floecadDocument, available: canPreparePrint, onPreparePrint: prepareWorkspacePrint))
                    .safeAreaInset(edge: .top) {
                        VStack(spacing: 0) {
                            recoveredCopyBanner
                            nativeCADProposalBanner
                        }
                    }
            } else if let nativeModelImportPath, let service = center.fileService {
                CADUnifiedModelImportEntry(sourcePath:nativeModelImportPath,service:service) { document,path in
                    guard relativePath == nativeModelImportPath,
                          center.fileService?.guardResolver.rootURL == service.guardResolver.rootURL else {
                        Task { await FloeCAD3DBridge.shared.releaseDocument(at:document.url,expected:document) };return
                    }
                    importedModelPath=path
                    self.nativeModelImportPath=nil
                    floecadDocument=document
                    Task { await center.recordRecentFile(relativePath:path,displayName:(path as NSString).lastPathComponent) }
                }.id(nativeModelImportPath)
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
                    let resolved = try service.guardResolver.resolve(displayedPath)
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
            } else if let textPreviewSource {
                TextReaderView(source: textPreviewSource, chrome: .contentOnly)
                    .id("\(textPreviewSource.ownerID)#\(displayedPath)#\(reloadGeneration)")
            } else if !isTextual && !isPDF {
                binaryPlaceholder
            } else {
                ProgressView("inspector.preview.loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(FloeTheme.readingSurface)
        .navigationTitle(embeddedInInspector ? "" : fileName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(embeddedInInspector)
        .toolbar { if !embeddedInInspector { toolbarContent } }
        .safeAreaInset(edge: .top, spacing: 0) {
            if embeddedInInspector {
                HStack { Spacer(minLength: 0); previewActions }
                    .labelStyle(.iconOnly).padding(.horizontal, 8).background(.bar)
            }
        }
        .sheet(item: $printPreparation) { request in
            PrintPreparationSheet(request: request)
        }
        .sheet(item: $designTarget) { target in
            // In-conversation file design opens the original task's design
            // page (preview + conversation); the standalone owner form is
            // not the chat entry anymore.
            if let conversationID = engineeringConversationID {
                DesignConversationPageView(
                    target: target, conversationID: conversationID,
                    environment: environment)
            } else {
                DesignOwnerWorkflowSheet(target: target, environment: environment)
            }
        }
        .sheet(item: $fileDesignTarget) { target in
            CreativeDesignStartView(previousTarget: nil, fileTarget: target)
        }
        .task(id: "\(relativePath)-\(usesExpandedReadOnly)-\(reloadGeneration)") { await load() }
        .onChange(of: relativePath) { _, _ in
            cancelDeletionPreparation()
            printPreparation = nil
            invalidateDrawingTransferRoute()
            isBuildingPresented=false;incomingBuildingPlan=nil
            nativeModelImportPath = nil
            importedModelPath = nil
            // The caller retargeted this preview to another file. No result
            // from the old recovery presentation may surface in the new one.
            recoveryFence.invalidate()
            recoveryTicket = nil
            recoveredCopyPath = nil
            recoveredCopyOrigin = nil
            recoveryPreview = nil
            recoverySheet = nil
            recoveredCopyNotice = nil
        }
        .onChange(of: center.currentWorkspace?.id) { _, _ in cancelDeletionPreparation(); printPreparation = nil; invalidateDrawingTransferRoute() }
        .onChange(of: center.fileService?.guardResolver.rootURL) { _, _ in cancelDeletionPreparation(); printPreparation = nil; invalidateDrawingTransferRoute() }
        .onChange(of: engineeringConversationID) { _, _ in printPreparation = nil; invalidateDrawingTransferRoute() }
        .fullScreenCover(isPresented: $isDrawingTransferPresented, onDismiss: finishDrawingTransferPresentation) {
            if let destination = drawingTransferDestination {
                CADFromDrawingWorkspaceView(destination: destination).id(destination.id)
            }
        }
        .fullScreenCover(isPresented:$isBuildingPresented,onDismiss:{ incomingBuildingPlan=nil }) {
            if let document=floecadDocument {
                CADBuildingWorkspaceView(document:document,incomingPlan:incomingBuildingPlan,
                    root:center.fileService?.guardResolver.rootURL,workspaceID:center.currentWorkspace?.id,
                    conversationID:engineeringConversationID)
            }
        }
        .overlay { if transferringDrawing { ProgressView().padding(20).background(.bar,in:RoundedRectangle(cornerRadius:12)) } }
        .fullScreenCover(isPresented: $isIDEPresented, onDismiss: {
            // The IDE can be swipe-dismissed on a clean session without
            // invoking onSaved. The Office preview session was released
            // before the IDE opened, so reload here to restore the embedded
            // preview instead of leaving the "opening in editor" placeholder.
            Task { await load() }
        }) {
            WorkspaceIDEView(
                initialRelativePath: displayedPath,
                center: center
            ) {
                Task { await load() }
            }
        }
        .fullScreenCover(isPresented: $isArchiveBrowserPresented) {
            NavigationStack {
                ArchiveBrowserView(relativePath: displayedPath, center: center)
            }
        }
        .fullScreenCover(isPresented: $isReadingModePresented) {
            TextReaderView(source: readingSource)
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
                    relativePath: displayedPath,
                    documentURL: nativeOfficeURL,
                    session: editorSession
                )
            }
        }
        .fullScreenCover(isPresented: $isEngineeringFullScreen, onDismiss: drawingCoverDidDismiss) {
            if let engineeringPackage {
                NavigationStack {
                    engineeringView(engineeringPackage, editing: true)
                        .navigationTitle(fileName)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                // Done is a SIZING transition back to the
                                // embedded preview: the same live WKWebView
                                // session (including unsaved edits) is
                                // re-adopted, so a dirty drawing is never
                                // confronted with a discard dialog here.
                                // Dirty state still blocks the interactive
                                // swipe; discarding is a separate explicit
                                // choice in the confirmation dialog.
                                Button("engineering.done") {
                                    if cadDirty { confirmDiscardCAD = true }
                                    else { isEngineeringFullScreen = false }
                                }
                                    .accessibilityIdentifier("engineering.done")
                            }
                        }
                }
                .interactiveDismissDisabled(cadDirty)
                .confirmationDialog("engineering.cad.unsaved", isPresented: $confirmDiscardCAD, titleVisibility: .visible) {
                    Button("engineering.cad.keepSession") {
                        // Preserve the live unsaved session and only change
                        // the presentation size; edits stay open in the
                        // re-adopted embedded preview.
                        isEngineeringFullScreen = false
                    }
                    Button("engineering.cad.discard", role: .destructive) {
                        // True close: drop the unsaved session and reload
                        // from the last committed bytes.
                        cadDirty = false
                        isEngineeringFullScreen = false
                        Task { await load() }
                    }
                    Button("engineering.cad.keepEditing", role: .cancel) {}
                }
                .sheet(item: $engineeringReview,
                       onDismiss: { Task { await refreshDrawingAssistantBinding() } }) { capture in
                    EngineeringReviewSheet(capture: capture,
                                           conversationID: drawingAssistantConversationID,
                                           center: center, webSession: engineeringSession)
                }
            }
        }
        .sheet(item: Binding(get: { isEngineeringFullScreen ? nil : engineeringReview }, set: { engineeringReview = $0 }),
               onDismiss: { Task { await refreshDrawingAssistantBinding() } }) { capture in
            EngineeringReviewSheet(capture: capture,
                                   conversationID: drawingAssistantConversationID,
                                   center: center, webSession: engineeringSession)
        }
        // The unified media workbench replaces the old parameter form and
        // single-file image editor; export drives the actual render.
        // When this preview is mounted for a chat task (a conversation
        // recorded against the current workspace), the project records that
        // conversation as its owner so the agent in the SAME task reaches it
        // and another task is refused. A genuinely workspace-only preview
        // keeps workspace ownership. No environment id exists on the
        // conversation API, so none is invented.
        .fullScreenCover(item: $mediaEditorSource, onDismiss: { Task { await load() } }) { url in
            if ["wav", "mp3", "m4a", "aac", "aiff", "aif", "flac", "ogg", "mid", "midi"].contains(url.pathExtension.lowercased()) {
                MusicWorkbenchBootstrapSheet(center: environment.workbenchCenter, title: url.lastPathComponent,
                    sourceURL: url, owner: workbenchOwner)
            } else {
                WorkbenchBootstrapSheet(center: environment.workbenchCenter, title: url.lastPathComponent,
                    kind: .video, urls: [url], owner: workbenchOwner)
            }
        }
        // The workbench edits the selected workspace file and writes the
        // re-encoded result back through the same digest-checked commit path;
        // dismissing reloads the preview against the committed bytes.
        .fullScreenCover(item: $imageEditRequest, onDismiss: { Task { await load() } }) { request in
            WorkbenchBootstrapSheet(
                center: environment.workbenchCenter,
                title: request.relativePath,
                kind: .image,
                urls: [request.sourceURL],
                owner: workbenchOwner,
                onSaveToSource: { options in
                    let data = try await environment.workbenchCenter.exportImageData(options: options)
                    try await saveEditedImage(request, editorPNG: data)
                })
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
            cancelDeletionPreparation()
            // This also runs for modal transitions. Only the source callback
            // epoch changes: an already accepted route keeps its operation.
            drawingTransferSourceEpoch = UUID()
            if !isIDEPresented, !isOfficeEditorPresented { Task { await officeSession.release() } }
            // A modal cover is a sizing/domain transition. Actual navigation
            // fences a pending route; workspace/path changes are fenced above.
            if !isEngineeringFullScreen, !isDrawingTransferPresented,
               !waitingForDrawingCoverDismissal, !isBuildingPresented {
                invalidateDrawingTransferRoute()
            }
        }
        .sheet(item: $recoverySheet) { sheet in
            switch sheet {
            case .decision(let preview):
                CADRecoveryPreviewSheet(
                    preview: preview,
                    mode: .decide,
                    restore: { try await restoreRecoveryCopy(preview) },
                    onRestored: { result in
                        // Only the presentation that ACTUALLY adopted this
                        // exact copy may show the post-restore notice. A late
                        // result for another file is never presented here.
                        guard recoveredCopyOrigin == relativePath,
                              recoveredCopyPath != nil,
                              recoveryFence.activeCopyURL
                                == result.packageURL.standardizedFileURL else { return }
                        recoverySheet = nil
                        recoveredCopyNotice = result
                        loadError = nil
                    },
                    onClose: { recoverySheet = nil },
                    onRefresh: {
                        recoverySheet = nil
                        recoveryTicket = nil
                        // Restart the bounded `.task` load instead of spawning
                        // an untracked task that can outlive this view.
                        reloadGeneration &+= 1
                    })
            case .report(let preview):
                CADRecoveryPreviewSheet(
                    preview: preview,
                    mode: .report,
                    restore: nil,
                    onRestored: { _ in },
                    onClose: { recoverySheet = nil })
            }
        }
        .confirmationDialog(IDELanguageRunText.t("删除文件？", "Delete file?"),
            isPresented: Binding(get: { deletionRequest != nil }, set: { if !$0 { deletionRequest = nil } }),
            titleVisibility: .visible, presenting: deletionRequest) { request in
                Button(IDELanguageRunText.t("删除", "Delete"), role: .destructive) {
                    deletionRequest = nil; Task { await deletePreviewFile(request) }
                }.accessibilityIdentifier("file.preview.delete.confirm")
                Button(IDELanguageRunText.t("取消", "Cancel"), role: .cancel) { deletionRequest = nil }
            } message: { request in
                Text(IDELanguageRunText.t("“\(request.name)”将从当前工作区删除，此操作不能撤销。", "“\(request.name)” will be deleted from this workspace. This cannot be undone."))
            }
        .alert("inspector.preview.error", isPresented: Binding(
            get: { previewError != nil },
            set: { if !$0 { previewError = nil } }
        )) { Button("workspace.office_document_editor_view.ok", role: .cancel) {} } message: {
            Text(previewError ?? "")
        }
    }

    /// The initiating task conversation (explicit preview binding, else the
    /// router's selected chat when it belongs to this workspace). Used for
    /// workbench ownership and for the explicit "preview website" action —
    /// NOT for the Drawing Assistant chat, which is drawing-specific to avoid
    /// cross-file context bleed.
    private var engineeringConversationID: UUID? {
        guard let id = conversationID ?? router.selectedConversationID,
              center.workspaceID(for: id) == center.currentWorkspace?.id else { return nil }
        return id
    }

    /// Durable, drawing-specific assistant conversation, validated against
    /// the conversation store (a deleted conversation drops the binding).
    @State private var drawingAssistantConversationID: UUID?

    @MainActor
    private func refreshDrawingAssistantBinding() async {
        guard let workspaceID = center.currentWorkspace?.id else {
            drawingAssistantConversationID = nil
            return
        }
        guard let stored = DrawingAssistantConversationStore.shared
            .conversationID(workspaceID: workspaceID, relativePath: displayedPath) else {
            drawingAssistantConversationID = nil
            return
        }
        let exists = (try? await center.environment.conversationStore.conversation(id: stored)) != nil
        drawingAssistantConversationID = exists ? stored : nil
    }

    /// Ownership recorded on workbench projects opened from this preview:
    /// chat ownership when a conversation belonging to the current workspace
    /// is known, otherwise workspace ownership. The project's media root stays
    /// the current workspace either way; only the owner id changes.
    private var workbenchOwner: WorkbenchCenter.Owner {
        WorkbenchCenter.Owner(kind: engineeringConversationID == nil ? .workspace : .chat,
                              id: engineeringConversationID,
                              environmentID: nil)
    }

    /// Reading mode opens the same original file read-only. Local files are
    /// streamed by the reader through the existing guard-resolved URL; cloud
    /// and network text goes through the existing bounded remote reader and
    /// is marked as a staged snapshot. Task-private workspace files are
    /// readable but their reading position is not persisted.
    private var readingSource: TextReaderSource {
        let path = displayedPath
        let remote = center.isCloudWorkspacePath(path) || center.isNetworkWorkspacePath(path)
        let persistsPosition = center.currentWorkspace?.kind != .privateTask
        return TextReaderSource(
            kind: .workspaceFile,
            ownerID: center.currentWorkspace?.id.uuidString ?? "workspace",
            documentKey: path,
            displayName: displayedFileName,
            format: WorkspaceFileType.pathExtension(for: path),
            markdown: isMarkdown,
            isRemoteSnapshot: remote,
            persistsPosition: persistsPosition,
            hasNonTextContent: false,
            limits: ReaderLimits(chunkBytes: 64 * 1024),
            makeBytes: { [center] in
                if remote {
                    let data = try await center.readRemotePreview(relativePath: path)
                    return TextReaderBytes(
                        source: ReaderDataByteSource(data: data),
                        fingerprint: TextReaderSource.dataFingerprint(data)
                    )
                }
                guard let service = center.fileService else {
                    throw ReaderError.sourceUnavailable("workspace unavailable")
                }
                let url = try service.guardResolver.resolve(path)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                return TextReaderBytes(
                    source: try ReaderFileByteSource(url: url),
                    fingerprint: TextReaderSource.fileFingerprint(url: url, byteLength: size, mtime: mtime)
                )
            }
        )
    }

    private func engineeringView(_ package: EngineeringPreviewPackage, editing: Bool = false) -> some View {
        let sourceEpoch = drawingTransferSourceEpoch
        let sourceRoot = engineeringRoot
        let sourceWorkspaceID = center.currentWorkspace?.id
        let sourceConversationID = engineeringConversationID
        let sourceDocumentKey = EngineeringWebSession.documentKey(
            rootPath: sourceRoot?.path, relativePath: displayedPath)
        return EngineeringFilePreview(
            package: package,
            onReview: { capture in
            engineeringReview = EngineeringReviewCapture(
                context: "Workspace path: \(displayedPath)\n" + capture.context,
                image: capture.image, documentID: displayedPath, workspaceRoot: engineeringRoot)
        }, onSave: editing && engineeringRoot != nil && (package.kind == .dxf || package.kind == .dwg) ? { data, baseline in
            guard let service = center.fileService, service.guardResolver.rootURL == engineeringRoot else {
                throw CocoaError(.fileReadNoPermission)
            }
            let path = displayedPath
            let result = try await Task.detached(priority: .userInitiated) {
                try service.commitBinaryEdit(path: path, data: data, expectedSHA256: baseline)
            }.value
            return result.write.sha256
        } : nil, onDirty: { cadDirty = $0 },
        onDrawingTransfer: sourceRoot != nil ? { transfer in
            guard drawingTransferSourceEpoch == sourceEpoch,
                  center.currentWorkspace?.id == sourceWorkspaceID,
                  center.fileService?.guardResolver.rootURL == sourceRoot,
                  engineeringConversationID == sourceConversationID,
                  transfer.sourceIdentity == sourceDocumentKey,
                  engineeringSession.loadedDocumentKey == sourceDocumentKey,
                  engineeringSession.presentationHost?.window != nil else { return }
            openDrawingTransfer(transfer)
        } : nil,
        session: engineeringSession,
        identity: sourceDocumentKey)
    }

    private func drawingTransferContextMatches(_ destination: CADFromDrawingDestination) -> Bool {
        relativePath == destination.sourcePath
            && center.fileService?.guardResolver.rootURL == destination.sourceRoot
            && center.currentWorkspace?.id == destination.workspaceID
            && engineeringConversationID == destination.conversationID
    }

    private func openDrawingTransfer(_ transfer: CADSketchTransferEnvelope) {
        guard !transferringDrawing, drawingTransferDestination == nil,
              let service = center.fileService, service.guardResolver.rootURL == engineeringRoot else { return }
        let path = displayedPath, root = service.guardResolver.rootURL, origin = relativePath
        let workspaceID = center.currentWorkspace?.id, conversationID = engineeringConversationID
        let wasFullScreen = isEngineeringFullScreen, generation = UUID()
        drawingTransferGeneration = generation; transferringDrawing = true
        drawingTransferTask = Task { @MainActor in
            var opened: FloeCADDocument?
            defer {
                if drawingTransferGeneration == generation { transferringDrawing = false; drawingTransferTask = nil }
            }
            do {
                let result = try await CADFromDrawingImport.open(transfer, sourcePath: path, service: service)
                opened = result.document
                guard !Task.isCancelled, drawingTransferGeneration == generation,
                      relativePath == origin, center.fileService?.guardResolver.rootURL == root,
                      center.currentWorkspace?.id == workspaceID, engineeringConversationID == conversationID,
                      !wasFullScreen || isEngineeringFullScreen else {
                    await FloeCAD3DBridge.shared.releaseDocument(at: result.document.url, expected: result.document); return
                }
                // Keep the original preview/path/session untouched. The entire
                // 2D draft (including unselected edits) stays in its Worker.
                drawingTransferDestination = CADFromDrawingDestination(id: generation, document: result.document,
                    path: result.path, transfer: transfer, sourcePath: origin, sourceRoot: root,
                    workspaceID: workspaceID, conversationID: conversationID,
                    returnToDrawingFullScreen: wasFullScreen)
                if wasFullScreen {
                    waitingForDrawingCoverDismissal = true
                    isEngineeringFullScreen = false
                } else { isDrawingTransferPresented = true }
                await center.recordRecentFile(relativePath: result.path, displayName: (result.path as NSString).lastPathComponent)
            } catch {
                if let opened { await FloeCAD3DBridge.shared.releaseDocument(at: opened.url, expected: opened) }
                if drawingTransferGeneration == generation, !Task.isCancelled { previewError = error.localizedDescription }
            }
        }
    }

    private func drawingCoverDidDismiss() {
        if waitingForDrawingCoverDismissal, let destination = drawingTransferDestination {
            waitingForDrawingCoverDismissal = false
            guard drawingTransferContextMatches(destination) else { invalidateDrawingTransferRoute(); return }
            // The previous cover is now gone. No load()/teardown is allowed in
            // this branch: it would clear cadDirty and release the live draft.
            isDrawingTransferPresented = true
        } else if drawingTransferDestination == nil {
            Task { await load() }
        }
    }

    private func finishDrawingTransferPresentation() {
        guard let destination = drawingTransferDestination else { return }
        let generation = drawingTransferGeneration
        Task { @MainActor in
            if !destination.document.isClosed {
                let outcome = await FloeCAD3DBridge.shared.releaseDocumentOutcome(
                    at: destination.document.url, expected: destination.document)
                if !destination.document.isClosed, drawingTransferContextMatches(destination),
                   drawingTransferGeneration == generation {
                    previewError = outcome?.error ?? "The model is still open. Save it before returning."
                    // The bridge retained the only editable draft. Keep its
                    // owner visible instead of returning a false save success.
                    isDrawingTransferPresented = true
                    return
                }
            }
            guard drawingTransferGeneration == generation else { return }
            drawingTransferDestination = nil
            if drawingTransferContextMatches(destination), destination.returnToDrawingFullScreen {
                isEngineeringFullScreen = true
            }
        }
    }

    private func invalidateDrawingTransferRoute() {
        drawingTransferSourceEpoch = UUID()
        drawingTransferTask?.cancel(); drawingTransferTask = nil
        drawingTransferGeneration = UUID(); transferringDrawing = false
        waitingForDrawingCoverDismissal = false
        isDrawingTransferPresented = false
        if let destination = drawingTransferDestination {
            drawingTransferDestination = nil
            Task { @MainActor in
                if destination.document.isReadOnly {
                    _ = FloeCAD3DBridge.shared.releaseReadOnlyDocument(destination.document)
                } else if !destination.document.isClosed {
                    _ = await FloeCAD3DBridge.shared.releaseDocumentOutcome(
                        at: destination.document.url, expected: destination.document)
                }
                // A failed save remains owned by the existing bridge cache.
            }
        }
    }

    /// Interactive confirmation for a native CAD proposal drafted by the
    /// assistant. The grant is issued and consumed by the shared
    /// CadDocumentCenter store; the model never sees a token. Pending
    /// proposals restore from the durable store after a restart, and reject
    /// notifies the originating task through the shared decision outbox.
    @ViewBuilder
    private var nativeCADProposalBanner: some View {
        if let proposal = floecadDocument
            .flatMap({ FloeCAD3DBridge.shared.pendingProposals(for: $0.url).last }) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "cube.transparent")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(proposal.summary)
                        .font(.subheadline.weight(.semibold))
                    // Import proposals name the source, the format and the
                    // geometry class explicitly; a mesh import has no
                    // parametric history and says so.
                    if proposal.preview.serviceOperation == "document.import",
                       let spec = FloeCAD3DBridge.shared.importSpec(for: proposal.id) {
                        // Use the ACTUAL preview classes, never the file
                        // extension: an IGES file can carry solids, surfaces
                        // or both, and a surface body is not a "B-rep solid".
                        let message = proposal.preview.serviceMessage ?? ""
                        let isMesh = message.localizedCaseInsensitiveContains("mesh")
                        let legacySurface = message.contains("IGES surfaces are not solids")
                        let geometryClass = proposal.preview.importGeometryClass
                            ?? (isMesh ? "mesh" : legacySurface ? "surface" : "solid")
                        let geometryLabel: String = switch geometryClass {
                        case "mesh":
                            String(localized: "cad.native.import_geometry_mesh")
                        case "surface":
                            String(localized: "cad.native.import_geometry_surface")
                        case "mixed":
                            String(localized: "cad.native.import_geometry_mixed")
                        default:
                            String(localized: "cad.native.import_geometry_solid")
                        }
                        Text(String(format: String(localized: "cad.native.import_detail"),
                                    spec.fileName ?? spec.sourceRelativePath,
                                    spec.format.uppercased(),
                                    geometryLabel,
                                    proposal.preview.addedBodyNames.count))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("cad.native.importDetail")
                        let openSurfaceCount = proposal.preview.importOpenSurfaceBodyCount
                            ?? (legacySurface ? proposal.preview.addedBodyNames.count : 0)
                        if openSurfaceCount > 0 {
                            Text(String(localized: "cad.native.import_surface_limit"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("cad.native.importSurfaceLimit")
                        }
                    } else {
                        Text("\(proposal.preview.bodyCountBefore) → \(proposal.preview.bodyCountAfter) bodies · "
                             + String(format: "%+.1f mm³", proposal.preview.volumeDeltaMM3))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button("Discard") {
                    Task {
                        await environment.cadDocumentCenter
                            .rejectNativeCADProposal(proposal.id)
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("cad.native.discard")
                Button("Apply") {
                    confirmNativeCADProposal(proposal.id)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("cad.native.apply")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
            // Keep the banner identity on an explicit accessibility CONTAINER.
            // Applied to a plain layout container, the identifier is copied
            // onto every descendant instead of identifying the banner, so the
            // real Apply/Discard buttons and the source/limit text stopped
            // answering to their own identifiers. Children stay individually
            // reachable with their own identifiers here, exactly like the
            // recovery sheet's container identity.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("cad.native.proposalBanner")
        }
    }

    private func confirmNativeCADProposal(_ proposalID: UUID) {
        Task {
            do {
                let grant = try await environment.cadDocumentCenter
                    .issueNativeCADGrant(proposalID: proposalID)
                _ = try await environment.cadDocumentCenter
                    .applyNativeCAD(proposalID: proposalID, grantID: grant)
            } catch {
                loadError = error.localizedDescription
                FloeCAD3DBridge.shared.noteError(error.localizedDescription)
            }
        }
    }

    /// The file this preview is ACTUALLY showing. After a successful restore
    /// this is the verified new copy, never the damaged package the view was
    /// originally opened for, so the title, save/close, export/share,
    /// Quick Look, design, IDE and recent-item paths all target the document
    /// that is really open.
    private var displayedPath: String {
        guard recoveredCopyOrigin == relativePath, let recoveredCopyPath else {
            return importedModelPath ?? relativePath
        }
        return recoveredCopyPath
    }

    private var displayedFileName: String {
        (displayedPath as NSString).lastPathComponent
    }

    private var isPresentingRecoveredCopy: Bool {
        recoveredCopyOrigin == relativePath && recoveredCopyPath != nil
    }

    /// Workspace-relative path for a URL proven to be below this workspace's
    /// exact root. Nil keeps the caller from inventing a prefix match.
    private func workspaceRelativePath(for url: URL) -> String? {
        guard let service = center.fileService else { return nil }
        let root = service.guardResolver.rootURL.standardizedFileURL
            .resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    private var fileName: String {
        displayedFileName
    }

    private var isPDF: Bool {
        WorkspaceFileType.isPDF(displayedPath)
    }

    private var isMarkdown: Bool {
        WorkspaceFileType.isMarkdown(displayedPath)
    }

    private var isHTML: Bool {
        WorkspaceFileType.isHTML(displayedPath)
    }

    private var isTextual: Bool {
        WorkspaceFileType.isText(displayedPath) && !unknownBinaryContent
    }

    private var isOfficeDocument: Bool {
        WorkspaceFileType.isOffice(displayedPath)
    }

    private var officeEditingAvailable: Bool {
        isOfficeDocument
            && OfficeFileSession.available
            && !center.isCloudWorkspacePath(displayedPath)
            && !center.isNetworkWorkspacePath(displayedPath)
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
        guard WorkspaceFileType.isImage(displayedPath) else { return nil }
        guard center.fileService != nil else {
            return .unavailable(OfficeInkText.t(
                "当前工作区不可用，无法编辑。",
                "The workspace is unavailable, so editing is unavailable."
            ))
        }
        if center.isCloudWorkspacePath(displayedPath) {
            return .unavailable(OfficeInkText.t(
                "云工作区文件仅供只读预览，本版本不支持写回原文件。",
                "Cloud workspace files are preview-only here; writing back is not supported in this version."
            ))
        }
        if center.isNetworkWorkspacePath(displayedPath) {
            if let mount = center.networkWorkspaceMount(for: displayedPath), mount.readOnly {
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
        guard ImageFileFormat(pathExtension: WorkspaceFileType.pathExtension(for: displayedPath)) != nil else {
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
            pathExtension: WorkspaceFileType.pathExtension(for: displayedPath)
        ) else {
            previewError = OfficeInkText.t(
                "此图片格式暂不支持编辑（支持 PNG、JPEG、HEIC）。",
                "This image format can't be edited yet (PNG, JPEG and HEIC are supported)."
            )
            return
        }
        let path = displayedPath
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
                    return await WorkspaceImageEditRequest(
                        relativePath: path,
                        sourceURL: url,
                        baselineSHA256: metadata.sha256,
                        rootURL: service.guardResolver.rootURL,
                        format: format
                    )
                }.value
                guard request.relativePath == displayedPath else { return }
                imageEditRequest = request
            } catch { previewError = error.localizedDescription }
        }
    }

    /// Re-encodes the editor's verified PNG into the destination file's own
    /// raster container, then commits it atomically through the workspace
    /// file service against the pre-edit digest.
    private func saveEditedImage(_ request: WorkspaceImageEditRequest, editorPNG: Data) async throws {
        guard imageEditRequest?.id == request.id,
              request.relativePath == displayedPath,
              let service = center.fileService,
              service.guardResolver.rootURL == request.rootURL else {
            throw CocoaError(.fileReadNoPermission)
        }
        do {
            let format = request.format
            let payload = try await Task.detached(priority: .userInitiated) {
                try ImageFileEncoder.reencode(editorPNG, as: format)
            }.value
            try await request.commit(payload, using: service)
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

    private var hasCompactPreviewActions: Bool {
        (isHTML && content != nil) || isTextual
        || (allowsDesignPage && center.currentWorkspace != nil && center.fileService != nil
            && !center.isCloudWorkspacePath(displayedPath) && !center.isNetworkWorkspacePath(displayedPath))
    }

    @ViewBuilder
    private var previewSaveImageAction: some View {
        if WorkspaceFileType.isImage(displayedPath), let imageURL = binaryPreviewURL {
            SaveImageToPhotosButton(imageURL: imageURL, validateRead: {
                if remotePreview.url == imageURL { return }
                guard let service = center.fileService else { throw CocoaError(.fileReadNoPermission) }
                let resolved = try service.guardResolver.resolve(displayedPath)
                guard resolved.standardizedFileURL == imageURL.standardizedFileURL else {
                    throw CocoaError(.fileReadNoPermission)
                }
                try service.guardResolver.assertReadableSize(resolved)
            }).frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
        }
    }

    @ViewBuilder
    private var previewReadActions: some View {
        if isHTML, content != nil {
            Button {
                startWebPreview()
            } label: {
                Label("workspace.file_preview_view.preview_website", systemImage: "safari")
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityIdentifier("file.preview.html")
        }
        // Reading mode for text documents: the same original file opened
        // read-only with bounded windows. The edit entries above/below are
        // unchanged, and an over-limit file that the bounded preview
        // cannot show is still readable here.
        if isTextual {
            Button {
                isReadingModePresented = true
            } label: {
                Label(
                    OfficeInkText.t("阅读模式", "Reading Mode"),
                    systemImage: "book"
                )
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel(OfficeInkText.t("阅读模式", "Reading Mode"))
            .accessibilityIdentifier("file.preview.readingMode")
        }
    }

    @ViewBuilder
    private var previewDesignAction: some View {
        // T6 design entrance for a real workspace file. Only shown when
        // the file is addressable through the live workspace authority;
        // cloud/network stubs are read-only copies without a design owner.
        // With a conversation context the design page opens for the same
        // task; without one, a genuine ordinary task bound to this file
        // starts through the conversational entry (no old form).
        if allowsDesignPage,
           let workspace = center.currentWorkspace,
           center.fileService != nil,
           !center.isCloudWorkspacePath(displayedPath),
           !center.isNetworkWorkspacePath(displayedPath) {
            Button {
                let target = DesignOwnerTargets.file(
                    workspaceID: workspace.id, relativePath: displayedPath)
                if engineeringConversationID != nil {
                    designTarget = target
                } else {
                    fileDesignTarget = target
                }
            } label: {
                Label("design.owner.open", systemImage: "square.on.square.dashed")
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("design.owner.open")
            .accessibilityIdentifier("file.preview.design")
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) { previewActions }
    }

    private var previewActions: some View {
        Group {
            previewSaveImageAction
            if engineeringPackage != nil {
                Button { isEngineeringFullScreen = true } label: {
                    Label("engineering.fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityIdentifier("file.preview.engineering.fullscreen")
            }
            if WorkspaceFileType.isMedia(displayedPath),
               !center.isCloudWorkspacePath(displayedPath), !center.isNetworkWorkspacePath(displayedPath) {
                Button {
                    do {
                        guard let service = center.fileService else { throw CocoaError(.fileReadNoPermission) }
                        mediaEditorSource = try service.guardResolver.resolve(displayedPath)
                    } catch { previewError = error.localizedDescription }
                } label: { Label("media.media_editor_view.media_workbench", systemImage: "film.stack") }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
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
            if horizontalSizeClass != .compact { previewReadActions }
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
            if horizontalSizeClass != .compact { previewDesignAction }
            if allowsIDEExpansion, !embeddedInInspector,
               WorkspaceFileRouter.allowsCodeEditor(displayedPath),
               (content != nil || textPreviewSource != nil),
               !center.isCloudWorkspacePath(displayedPath),
               !center.isNetworkWorkspacePath(displayedPath) {
                Button {
                    isIDEPresented = true
                } label: {
                    Label("workspace.file_preview_view.open_in_editor", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("workspace.file_preview_view.open_in_editor")
                .accessibilityIdentifier("file.preview.openIDE")
            }
            // A PDF expands into the IDE's internal document tab (native
            // overlay inside the workbench), never an outer task page.
            if allowsIDEExpansion, !embeddedInInspector,
               isPDF,
               pdfURL != nil,
               center.fileService != nil {
                Button {
                    isIDEPresented = true
                } label: {
                    Label("workspace.file_preview_view.open_in_editor", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .accessibilityLabel("workspace.file_preview_view.open_in_editor")
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
                if embeddedInInspector, allowsIDEExpansion,
                   WorkspaceFileRouter.allowsCodeEditor(displayedPath),
                   textPreviewSource != nil,
                   !center.isCloudWorkspacePath(displayedPath), !center.isNetworkWorkspacePath(displayedPath) {
                    Button { isIDEPresented = true } label: {
                        Label("workspace.file_preview_view.open_in_editor", systemImage: "square.and.pencil")
                    }.accessibilityIdentifier("file.preview.openIDE")
                }
                if horizontalSizeClass == .compact, hasCompactPreviewActions {
                    previewReadActions
                    previewDesignAction
                    Divider()
                }
                // The parent's callback is bound to the file this preview was
                // opened for. After a restore it would add the damaged
                // package, so it stays available only for the original file.
                if let onAddToContext, !isPresentingRecoveredCopy {
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
                if onDeleted != nil {
                    Divider()
                    Button(role: .destructive) {
                        deletionPreparationTask?.cancel()
                        deletionPreparationTask = Task { await requestPreviewFileDeletion() }
                    } label: {
                        Label(IDELanguageRunText.t("删除", "Delete"), systemImage: "trash")
                    }.disabled(deletingFile).accessibilityIdentifier("file.preview.delete")
                }
            } label: {
                Label("file.preview.more", systemImage: "ellipsis.circle")
            }
            .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
            .accessibilityLabel("file.preview.more")
            .accessibilityIdentifier("file.preview.more")
            .disabled(deletingFile || (!embeddedInInspector && (horizontalSizeClass != .compact || !hasCompactPreviewActions)
                      && onDeleted == nil && !canPreparePrint && (onAddToContext == nil || isPresentingRecoveredCopy)
                      && (isTextual || nativeOfficeURL != nil || !quickLookAvailable)))
        }
    }

    @MainActor private func cancelDeletionPreparation() {
        deletionGeneration = UUID(); deletionRequest = nil
        deletionPreparationTask?.cancel(); deletionPreparationTask = nil
    }
    @MainActor private func requestPreviewFileDeletion() async {
        guard onDeleted != nil, !deletingFile else { return }
        let generation = UUID(); deletionGeneration = generation
        let path = displayedPath
        do {
            let scope: WorkspaceFileActionScope
            if let expectedDeletionScope {
                // Recovery may display a newly created copy. A captured design
                // handoff can delete only the original source it was opened for.
                guard path == relativePath else { throw WorkspaceFileDeletionError.changed }
                try expectedDeletionScope.validate(center)
                scope = expectedDeletionScope
            } else {
                scope = try WorkspaceFileActionScope(center: center)
            }
            let request = try await WorkspaceFileDeletion.prepare(path: path, scope: scope, center: center)
            guard generation == deletionGeneration, displayedPath == path else { throw WorkspaceFileDeletionError.changed }
            deletionRequest = request
        } catch { if generation == deletionGeneration { previewError = error.localizedDescription } }
    }
    @MainActor private func deletePreviewFile(_ request: WorkspaceFileDeletionRequest) async {
        guard !deletingFile, onDeleted != nil else { return }
        deletingFile = true; defer { deletingFile = false }
        let generation = deletionGeneration
        do {
            guard displayedPath == request.relativePath, !isIDEPresented, !isOfficeEditorPresented,
                  !isEngineeringFullScreen, !isDrawingTransferPresented, !transferringDrawing,
                  mediaEditorSource == nil, imageEditRequest == nil, printPreparation == nil,
                  !isBuildingPresented, floecadDocument == nil else { throw WorkspaceFileDeletionError.closeFirst }
            try request.scope.validate(center)
            if officeSession.phase != .idle {
                guard officeSession.canAct else { throw WorkspaceFileDeletionError.closeFirst }
                // Editing is explicitly saved through the existing conflict-safe
                // Office lifecycle. It is never discarded to make delete pass.
                if officeSession.hasUncommittedChanges {
                    guard await officeSession.saveInPlace() else { throw WorkspaceFileDeletionError.closeFirst }
                    // A save changes the selected disk version. Keep the file
                    // and require a fresh visible confirmation for that version.
                    throw WorkspaceFileDeletionError.changed
                }
                await officeSession.release()
                guard officeSession.phase == .idle else { throw WorkspaceFileDeletionError.closeFirst }
            }
            guard generation == deletionGeneration, displayedPath == request.relativePath else { throw WorkspaceFileDeletionError.changed }
            try WorkspaceFileDeletion.commit(request, center: center)
            nativeOfficeURL = nil; content = nil; pdfURL = nil; binaryPreviewURL = nil
            onDeleted?()
        } catch {
            if generation == deletionGeneration { previewError = error.localizedDescription }
        }
    }

    private func prepareWorkspacePrint() {
        do {
            guard canPreparePrint else { throw FloeError.unauthorized }
            let sourceConversation = engineeringConversationID, sourceEnvironment = environment
            printPreparation = try PrintProjectHandoff.workspaceRequest(center: center,
                path: displayedPath, conversationID: sourceConversation, document: floecadDocument,
                validateAccess: { [weak sourceEnvironment] in
                    guard let sourceEnvironment else { throw FloeError.unauthorized }
                    if let id = sourceConversation, sourceEnvironment.conversationCenter.isTemporaryConversation(id) {
                        throw FloeError.unauthorized
                    }
                })
        } catch { previewError = error.localizedDescription }
    }

    private var canPreparePrint: Bool {
        if let id = engineeringConversationID, environment.conversationCenter.isTemporaryConversation(id) { return false }
        guard loadError == nil, center.currentWorkspace != nil, center.currentRootURL != nil else { return false }
        guard let floecadDocument else { return false }
        return !floecadDocument.isClosed
    }

    private var quickLookAvailable: Bool {
        center.currentRootURL != nil
    }

    /// The archive browser needs a pinned workspace root and an archive
    /// extension the browser can route (other formats still open there to
    /// report their own truthful unsupported reason).
    private var isArchiveBrowsable: Bool {
        WorkspaceFileType.isArchive(displayedPath)
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
            if WorkspaceFileType.isArchive(displayedPath), isArchiveBrowsable {
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

    /// E33: create the atomic new package through the store seam, then open
    /// that copy in the existing shared native session. The damaged package is
    /// only read; the sheet's fingerprint CAS refuses a changed source.
    ///
    /// The atomic copy is allowed to finish even if the presentation is
    /// canceled mid-step (aborting between staging and promotion would be
    /// worse). Its result is recorded as a real recent file first; only the
    /// still-current ticket may then open and ADOPT it. A late result therefore
    /// never retargets another view, never opens a second copy, and never
    /// leaves a bridge session without an owner.
    @MainActor
    private func restoreRecoveryCopy(_ preview: CADRecoveryPreview) async throws
    -> CADRecoveryRestoreResult {
        let origin = relativePath
        guard let ticket = recoveryTicket,
              recoveryFence.accepts(ticket),
              ticket.sourceURL == preview.sourceURL.standardizedFileURL,
              recoveredCopyPath == nil,
              !Task.isCancelled else {
            throw CancellationError()
        }
        let destination = CADRecoveryCopyDestination.suggestedURL(
            for: preview.sourceURL,
            suffix: FloeL10n.l("cad.recovery.copySuffix"))
        let result = try await FloeCADDocument.restorePreviousCopy(preview, to: destination)

        // The copy exists now. Record the honest outcome before any
        // presentation check so a canceled/retargeted view cannot lose it.
        guard let copyPath = workspaceRelativePath(for: result.packageURL) else {
            throw CADRecoveryOpenError(message: FloeL10n.l(
                "cad.recovery.error.openFailed", result.packageURL.lastPathComponent))
        }
        await center.recordRecentFile(
            relativePath: copyPath,
            displayName: (copyPath as NSString).lastPathComponent)

        guard recoveryFence.accepts(ticket), !Task.isCancelled,
              origin == relativePath, recoveredCopyPath == nil else {
            // The atomic step finished, but this presentation moved on. Do
            // not open or attach the copy to whatever is displayed now.
            return result
        }
        do {
            let document = try await FloeCAD3DBridge.shared.openDocument(at: result.packageURL)
            guard recoveryFence.accepts(ticket), !Task.isCancelled,
                  origin == relativePath, recoveredCopyPath == nil,
                  recoveryFence.adopt(ticket,
                                      copyURL: result.packageURL,
                                      resultSourceURL: result.sourceURL) != nil else {
                // A session was opened for a result this view can no longer
                // present. Release that exact new owner; never a different
                // file and never the damaged package.
                await FloeCAD3DBridge.shared.releaseDocument(
                    at: result.packageURL, expected: document)
                return result
            }
            floecadDocument = document
            recoveredCopyOrigin = origin
            recoveredCopyPath = copyPath
            return result
        } catch is CancellationError {
            // The copy was recorded above; no bridge owner was adopted.
            return result
        } catch {
            throw CADRecoveryOpenError(message: FloeL10n.l(
                "cad.recovery.error.openFailed", result.packageURL.lastPathComponent))
        }
    }

    /// Post-restore notice: the copy is open, the damaged package and its
    /// previous commit are unchanged, and the same report stays reachable.
    @ViewBuilder
    private var recoveredCopyBanner: some View {
        if recoveredCopyNotice != nil, isPresentingRecoveredCopy,
           let preview = recoveryPreview {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("cad.recovery.restored.title")
                        .font(.caption.weight(.semibold))
                    Text("cad.recovery.restored.detail")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("cad.recovery.action.details") {
                    recoverySheet = .report(preview)
                }
                .font(.caption)
                .accessibilityIdentifier("cad.recovery.restored.detailsButton")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityIdentifier("cad.recovery.restored.banner")
        }
    }

    private func load() async {
        // A view retargeted to another file must not keep showing (or acting
        // on) the previous file's recovered copy.
        if recoveredCopyOrigin != relativePath {
            recoveredCopyOrigin = nil
            recoveredCopyPath = nil
            recoveryFence.invalidate()
        }
        // No ticket from an earlier load may survive into this one, including
        // a load that fails before it can begin its own ticket. The adopted
        // copy keeps its state; its own reload begins a fresh ticket below.
        if recoveredCopyPath == nil {
            recoveryFence.invalidate()
        }
        loadError = nil
        content = nil
        textPreviewSource = nil
        unknownBinaryContent = false
        pdfURL = nil
        binaryPreviewURL = nil
        nativeOfficeURL = nil
        engineeringPackage = nil
        nativeModelImportPath = nil
        mayOpenLargeModel = false
        engineeringRoot = nil
        cadDirty = false
        recoveryPreview = nil
        recoverySheet = nil
        recoveryTicket = nil
        recoveredCopyNotice = nil
        let path = displayedPath
        let name = (path as NSString).lastPathComponent
        // Flush the document this preview owned BEFORE releasing it: a failed
        // commit keeps the preview and its error visible instead of being
        // dropped behind a fire-and-forget task. Release through the bridge so
        // the shared owner forgets the saved, closed session: a later open of
        // the same path must create a fresh document, never hand back a
        // closed instance.
        if let previous = floecadDocument {
            if FloeCAD3DBridge.shared.releaseReadOnlyDocument(previous) {
                // A read-only copy (newer/opaque previous save) has nothing to
                // commit; releasing it must not look like a failed save.
            } else if let outcome = await FloeCAD3DBridge.shared
                .releaseDocumentOutcome(at: previous.url, expected: previous) {
                if let error = outcome.error {
                    loadError = "CAD save failed: \(error)"
                    return
                }
            } else if previous.isReadOnly {
                // A read-only session the bridge did not cache: close it
                // without pretending a commit could succeed.
                previous.close()
            } else {
                // Not owned by the bridge (should not happen for a session it
                // opened): save and close locally.
                let outcome = await previous.save()
                if let error = outcome.error {
                    loadError = "CAD save failed: \(error)"
                    return
                }
                guard !previous.hasUnsavedChanges else {
                    loadError = String(localized: "cad.recovery.release.changed")
                    return
                }
                previous.close()
            }
            floecadDocument = nil
        }
        remotePreview.clear()
        await refreshDrawingAssistantBinding()
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
        if (path as NSString).pathExtension.lowercased() == "floecad" {
            // Native FloeCAD package: a directory with JSON metadata and
            // separate binary B-rep/mesh blobs. Open it as a live document;
            // remote/cloud packages are not staged for editing yet and say so
            // instead of silently opening a stale copy.
            guard let service = center.fileService else {
                loadError = String(localized: "inspector.no_workspace")
                return
            }
            if center.isCloudWorkspacePath(path) || center.isNetworkWorkspacePath(path) {
                loadError = "FloeCAD documents must be downloaded to a local workspace before editing."
                return
            }
            do {
                // Authorized canonical resolution: traversal/symlink checks,
                // workspace-boundary enforcement and read-size guards all live
                // in the resolver; never concatenate a relative path onto the
                // root by hand.
                let resolved = try service.guardResolver.resolve(path)
                guard resolved.standardizedFileURL.path.hasPrefix(
                    service.guardResolver.rootURL.standardizedFileURL.path) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                // A package must carry a manifest (current or recoverable
                // previous) before it is offered as an editable document.
                // The rotated previous commit lives at `previous/manifest.json`
                // (the layout `FileCADDocumentStore.restorePrevious` verifies);
                // `previous/snapshot` is the replaced-package backup written by
                // an overwrite create. Both keep the file openable enough to
                // reach the read-only recovery inspection below.
                let manifest = resolved.appendingPathComponent("manifest.json")
                let rotatedPrevious = resolved.appendingPathComponent("previous/manifest.json")
                let replacedOriginal = resolved.appendingPathComponent("previous/snapshot/manifest.json")
                guard FileManager.default.fileExists(atPath: manifest.path)
                        || FileManager.default.fileExists(atPath: rotatedPrevious.path)
                        || FileManager.default.fileExists(atPath: replacedOriginal.path) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                // Every load owns a ticket. A canceled/older inspection can
                // never present its sheet or attach its document to a newer
                // load of this same preview.
                let ticket = recoveryFence.begin(sourceURL: resolved)
                // E33: inspect BEFORE the store's ordinary open. Ordinary
                // open promotes a verified previous commit in place; the
                // interactive route must show the real previous save first and
                // let the user decide whether to create a new copy. The
                // inspection is strictly read-only.
                switch await FloeCADDocument.recoveryInspection(at: resolved) {
                case .intact:
                    break
                case .damaged(_, let preview):
                    guard recoveryFence.accepts(ticket), !Task.isCancelled else { return }
                    if let preview {
                        recoveryPreview = preview
                        recoveryTicket = ticket
                        recoverySheet = .decision(preview)
                        loadError = FloeL10n.l("cad.recovery.unavailable")
                    } else {
                        loadError = FloeL10n.l("cad.recovery.error.noPrevious")
                    }
                    return
                }
                guard recoveryFence.accepts(ticket), !Task.isCancelled else { return }
                // One live session: the bridge owns it so the workbench and
                // the assistant route operate on the same in-memory document.
                let document = try await FloeCAD3DBridge.shared.openDocument(at: resolved)
                CADDrawingModelBridge.configure(document)
                guard recoveryFence.accepts(ticket), !Task.isCancelled else {
                    // A canceled load of the recovered copy would otherwise
                    // leave the bridge owning a session no view presents. The
                    // originally selected package keeps the existing shared
                    // session lifetime.
                    if recoveredCopyPath != nil, path != relativePath {
                        await FloeCAD3DBridge.shared.releaseDocument(
                            at: resolved, expected: document)
                    }
                    return
                }
                floecadDocument = document
                // Restore durable pending proposals (post-restart recovery)
                // and surface ones invalidated by manual edits.
                await environment.cadDocumentCenter.pendingNativeProposals(for: resolved)
                await center.recordRecentFile(relativePath: path, displayName: name)
            } catch is CancellationError {
            } catch {
                loadError = error.localizedDescription
            }
            return
        }
        if CADUnifiedModelImport.extensions.contains((path as NSString).pathExtension.lowercased()),
           !center.isCloudWorkspacePath(path), !center.isNetworkWorkspacePath(path), let service = center.fileService {
            do {
                _ = try service.guardResolver.resolve(path, for: .read(maxBytes:128*1024*1024))
                nativeModelImportPath=path
                engineeringRoot=service.guardResolver.rootURL
            } catch { loadError=error.localizedDescription }
            return
        }
        if EngineeringPreviewKind.identify(path) != nil, let service = center.fileService {
            do {
                let package: EngineeringPreviewPackage
                if center.isCloudWorkspacePath(path) || center.isNetworkWorkspacePath(path) {
                    let bytes = try await center.readRemotePreview(relativePath: path)
                    package = try EngineeringPreviewPackage.single(name: name, bytes: bytes)
                } else {
                    engineeringRoot = service.guardResolver.rootURL
                    let limits: EngineeringPreviewLimits = usesExpandedReadOnly ? .expandedReadOnly : .standard
                    let previewService = WorkspaceFileService(guard: service.guardResolver.withReadLimit(limits.maximumBytes))
                    let work = Task.detached(priority: .userInitiated) {
                        try EngineeringPreviewPackage.load(path: path, service: previewService, limits: limits)
                    }
                    package = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                }
                try Task.checkCancellation()
                engineeringPackage = package
                await center.recordRecentFile(relativePath: path, displayName: name)
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                let tooLarge = (error as NSError).domain == NSCocoaErrorDomain
                    && (error as NSError).code == NSFileReadTooLargeError
                mayOpenLargeModel = tooLarge && !usesExpandedReadOnly
                    && !center.isCloudWorkspacePath(path) && !center.isNetworkWorkspacePath(path)
                    && [EngineeringPreviewKind.mesh, .cadSurface].contains(where: { $0 == EngineeringPreviewKind.identify(path) })
                loadError = usesExpandedReadOnly && tooLarge
                    ? String(localized: "engineering.large_model.limit") : error.localizedDescription
            }
            return
        }
        if isOfficeDocument, !OfficeFileSession.available {
            // The real engine host is not linked into this build (iOS
            // Simulator). The Workspace preview falls back to the system
            // renderer below; record the exact first missing stage so one
            // durable trace explains the surface instead of a silent
            // substitution.
            OfficeStageRecorder.shared.record(
                session: "workspace-preview-\(UUID().uuidString)",
                generation: 0,
                stage: "engine.unavailable",
                detail: ["surface": "workspace-preview",
                         "format": (path as NSString).pathExtension.lowercased()])
        }
        if isOfficeDocument, OfficeFileSession.available, let service = center.fileService {
            do {
                // A cloud/network document is staged into a private temporary
                // copy; the session must treat it as a read-only snapshot and
                // never present edits as a successful remote save.
                let remote = center.isCloudWorkspacePath(path) || center.isNetworkWorkspacePath(path)
                let url: URL
                if remote {
                    let bytes = try await center.readRemotePreview(relativePath: path)
                    try Task.checkCancellation()
                    url = try remotePreview.store(bytes, fileName: name)
                } else {
                    url = try service.guardResolver.resolve(path)
                    try service.guardResolver.assertReadableSize(url)
                }
                officeSession.isRemoteSnapshot = remote
                nativeOfficeURL = url
                await officeSession.open(url)
                await center.recordRecentFile(relativePath: path, displayName: name)
            } catch { loadError = error.localizedDescription }
            return
        }
        if isPDF, let service = center.fileService {
            do {
                if center.isCloudWorkspacePath(path) || center.isNetworkWorkspacePath(path) {
                    let bytes = try await center.readRemotePreview(relativePath: path)
                    try Task.checkCancellation()
                    pdfURL = try remotePreview.store(bytes, fileName: name)
                } else {
                    let url = try service.guardResolver.resolve(path)
                    try service.guardResolver.assertReadableSize(url)
                    pdfURL = url
                }
                await center.recordRecentFile(relativePath: path, displayName: name)
            } catch { loadError = error.localizedDescription }
            return
        }
        var admittedTextSource: TextReaderSource?
        var admittedRemoteBytes: Data?
        if WorkspaceFileType.kind(for: path) == .unknown {
            do {
                let workspaceID = center.currentWorkspace?.id
                let workspaceRoot = center.fileService?.guardResolver.rootURL
                var source = readingSource
                let bytes = try await source.makeBytes()
                let limits = source.limits
                let worker = Task.detached(priority: .utility) {
                    try WorkspacePreviewContentProbe.usesTextReader(source: bytes.source, limits: limits, cancellation: .task())
                }
                let isText = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard displayedPath == path, center.currentWorkspace?.id == workspaceID,
                      center.fileService?.guardResolver.rootURL == workspaceRoot else { return }
                unknownBinaryContent = !isText
                if isText {
                    // Retain the actual admitted snapshot instead of fetching
                    // a different remote version for the reader a second time.
                    source.makeBytes = { bytes }
                    admittedTextSource = source
                } else if let remote = bytes.source as? ReaderDataByteSource {
                    admittedRemoteBytes = remote.data
                }
            } catch is CancellationError { return }
            catch ReaderError.cancelled { return }
            catch { loadError = error.localizedDescription; return }
        }
        guard isTextual else {
            // Embed the read-only renderer directly in the inspector. Full
            // Office editing remains a separate native-engine qualification.
            do {
                if center.isCloudWorkspacePath(path) || center.isNetworkWorkspacePath(path) {
                    let bytes: Data
                    if let admittedRemoteBytes { bytes = admittedRemoteBytes }
                    else { bytes = try await center.readRemotePreview(relativePath: path) }
                    try Task.checkCancellation()
                    binaryPreviewURL = try remotePreview.store(bytes, fileName: name)
                } else if let service = center.fileService {
                    let url = try service.guardResolver.resolve(path)
                    try service.guardResolver.assertReadableSize(url)
                    binaryPreviewURL = url
                }
                await center.recordRecentFile(relativePath: path, displayName: name)
            } catch { loadError = error.localizedDescription }
            return
        }
        do {
            // HTML keeps its existing bounded website-preview DTO. The
            // text surface itself always reads the original in bounded pages.
            if isHTML { content = try await center.readFile(relativePath: path) }
            try Task.checkCancellation()
            textPreviewSource = admittedTextSource ?? readingSource
            await center.recordRecentFile(relativePath: path, displayName: name)
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
            let remote = center.isCloudWorkspacePath(displayedPath) || center.isNetworkWorkspacePath(displayedPath)
            do {
                if !remote, let pdfURL { shareURL = pdfURL; return }
                if !remote, let binaryPreviewURL { shareURL = binaryPreviewURL; return }
                if remote {
                    let bytes = try await center.readRemotePreview(relativePath: displayedPath)
                    try Task.checkCancellation()
                    shareURL = try shareCopy.store(bytes, fileName: fileName)
                    return
                }
                guard let service = center.fileService else { throw CocoaError(.fileReadNoPermission) }
                let url = try service.guardResolver.resolve(displayedPath)
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
                if center.isCloudWorkspacePath(displayedPath) || center.isNetworkWorkspacePath(displayedPath) {
                    let bytes = try await center.readRemotePreview(relativePath: displayedPath)
                    quickLookURL = try remotePreview.store(bytes, fileName: fileName)
                } else {
                    guard let service = center.fileService else { throw CocoaError(.fileReadNoPermission) }
                    let url = try service.guardResolver.resolve(displayedPath)
                    try service.guardResolver.assertReadableSize(url)
                    quickLookURL = url
                }
            } catch is CancellationError {
            } catch { previewError = error.localizedDescription }
        }
    }

    private func startWebPreview() {
        // The preview belongs to the file's own task, never to whichever task
        // happens to be visible in the browser panel. A file opened outside a
        // task of this workspace has no preview owner and is refused instead
        // of borrowing an unrelated session.
        guard let workspaceID = center.currentWorkspace?.id,
              let owner = engineeringConversationID,
              let root = center.currentRootURL else {
            previewError = OfficeInkText.t(
                "请在这个文件所属的任务中打开以预览网页",
                "Open this file from its task to preview the website"
            )
            return
        }
        Task {
            do {
                _ = try await environment.previewCenter.start(
                    root: root,
                    relativeRoot: nil,
                    entry: displayedPath,
                    owner: owner
                )
                // The start can outlive the user's route. Only project its
                // result while this view's task and workspace are still the
                // selected ones; a late completion never selects or opens a
                // different task's browser.
                guard !Task.isCancelled,
                      router.selectedConversationID == owner,
                      center.currentWorkspace?.id == workspaceID,
                      center.workspaceID(for: owner) == workspaceID else { return }
                environment.previewCenter.select(owner)
                router.showInspector(.browser)
            } catch FloeError.cancelled {
            } catch is CancellationError {
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
@MainActor
final class WorkspaceImageEditRequest: Identifiable {
    let id = UUID()
    let relativePath: String
    let sourceURL: URL
    private(set) var baselineSHA256: String
    let rootURL: URL
    let format: ImageFileFormat

    init(relativePath: String, sourceURL: URL, baselineSHA256: String,
         rootURL: URL, format: ImageFileFormat) {
        self.relativePath = relativePath
        self.sourceURL = sourceURL
        self.baselineSHA256 = baselineSHA256
        self.rootURL = rootURL
        self.format = format
    }

    /// Advance only after a real guarded commit. A later external change must
    /// still conflict; refreshing from the current file would hide that change.
    func commit(_ payload: Data, using service: WorkspaceFileService) async throws {
        guard service.guardResolver.rootURL == rootURL,
              try service.guardResolver.resolve(relativePath).standardizedFileURL == sourceURL.standardizedFileURL else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let path = relativePath, baseline = baselineSHA256
        let outcome = try await Task.detached(priority: .userInitiated) {
            try service.commitBinaryEdit(path: path, data: payload, expectedSHA256: baseline)
        }.value
        baselineSHA256 = outcome.write.sha256
    }
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
