// FloeApp — shared native Office preview and fullscreen editing session.
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Combine
import FloeDocuments
#if canImport(FloeOfficeNative)
import FloeOfficeNative
#endif

@MainActor
final class OfficeFileSession: ObservableObject {
    enum Phase { case idle, loading, ready, insertingAttachment, readingAttachments, saving, closing, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var controller: UIViewController?
    @Published private(set) var readOnly = true
    @Published private(set) var hasUncommittedChanges = false
    @Published var error: String?
    @Published private(set) var hasSaveConflict = false
    @Published private(set) var drawingMode = false
    private var workspace: SecurityScopedDocumentWorkspace?
    private var session: DocumentSession?
    private var operating = false
    private var releaseRequested = false
    private var expectedClose = false
    private var runtimeFailed = false
    private var runtimeFailureObservation: AnyCancellable?
    private var explicitSaveBridge: OfficeExplicitSaveBridge?
    private var exportSnapshot: DocumentExportSnapshot?
    private var exportWorkspace: SecurityScopedDocumentWorkspace?

    init() {
        #if canImport(FloeOfficeNative)
        runtimeFailureObservation = NotificationCenter.default.publisher(for: .FloeOfficeNativeRuntimeDidFail)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.runtimeFailed = true
                    (self.controller as? FloeOfficeNativeViewController)?.cancelPendingSave()
                    self.error = "文档服务已停止响应，编辑副本已保留。"
                    self.phase = .failed
                }
            }
        #endif
    }

    static var available: Bool {
        #if canImport(FloeOfficeNative)
        true
        #else
        false
        #endif
    }
    var canAct: Bool { phase == .ready && !operating }
    var supportsAttachmentInsertion: Bool {
        guard !readOnly, let session else { return false }
        return ["docx", "doc", "odt", "rtf", "xlsx", "xls", "ods", "pptx", "ppt", "odp"].contains(session.workingURL.pathExtension.lowercased())
    }

    var exportFormats: [String] {
        guard let controller, controller.responds(to: NSSelectorFromString("exportDocumentWithFormat:completion:")), let session else { return [] }
        switch session.workingURL.pathExtension.lowercased() {
        case "doc", "docx", "odt", "rtf": return ["pdf", "docx", "odt", "rtf", "txt"]
        case "ppt", "pptx", "odp": return ["pdf", "pptx", "odp"]
        case "xls", "xlsx", "ods": return ["pdf", "xlsx", "ods"]
        default: return []
        }
    }
    var supportsPresentation: Bool {
        guard let controller, controller.responds(to: NSSelectorFromString("startPresentationWithCompletion:")), let session else { return false }
        return ["ppt", "pptx", "odp"].contains(session.workingURL.pathExtension.lowercased())
    }

    var supportsDrawing: Bool {
        !readOnly && controller?.responds(to: NSSelectorFromString("setDrawingMode:completion:")) == true
    }
    func toggleDrawing() async throws {
        guard canAct, supportsDrawing, let controller else { throw CocoaError(.featureUnsupported) }
        operating = true
        defer { finishOperation() }
        let enabled = !drawingMode
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let callback: @convention(block) (NSError?) -> Void = { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            _ = controller.perform(NSSelectorFromString("setDrawingMode:completion:"), with: NSNumber(value: enabled), with: callback as AnyObject)
        }
        drawingMode = enabled
    }

    func exportDocument(format: String) async throws -> URL {
        guard canAct, exportFormats.contains(format), let controller else { throw CocoaError(.featureUnsupported) }
        operating = true; phase = .saving
        defer { phase = runtimeFailed || self.controller == nil ? .failed : .ready; finishOperation() }
        #if canImport(FloeOfficeNative)
        if !readOnly, let native = controller as? FloeOfficeNativeViewController {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                native.saveWorkingCopy { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
        #endif
        // The shipped host is pinned separately. A selector capability check keeps old hosts
        // functional until the newly compiled host is qualified, without rewriting its headers.
        let output: URL = try await withCheckedThrowingContinuation { continuation in
            let callback: @convention(block) (NSURL?, NSError?) -> Void = { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url as URL) }
                else { continuation.resume(throwing: CocoaError(.fileWriteUnknown)) }
            }
            _ = controller.perform(NSSelectorFromString("exportDocumentWithFormat:completion:"), with: format as NSString, with: callback as AnyObject)
        }
        if format == "pdf" {
            guard let pdf = CGPDFDocument(output as CFURL), pdf.numberOfPages > 0 else { throw CocoaError(.fileReadCorruptFile) }
        } else if ["docx", "pptx", "xlsx"].contains(format) {
            _ = try OfficeDocumentService.inspect(url: output)
        }
        return output
    }

    func startPresentation() async throws {
        guard canAct, supportsPresentation, let controller else { throw CocoaError(.featureUnsupported) }
        operating = true
        defer { finishOperation() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let callback: @convention(block) (NSError?) -> Void = { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            _ = controller.perform(NSSelectorFromString("startPresentationWithCompletion:"), with: callback as AnyObject)
        }
    }

    func insertAttachment(_ url: URL) async throws {
        guard canAct, supportsAttachmentInsertion else { throw CocoaError(.featureUnsupported) }
        operating = true
        phase = .insertingAttachment
        defer {
            phase = runtimeFailed || controller == nil ? .failed : .ready
            finishOperation()
        }
        #if canImport(FloeOfficeNative)
        guard let native = controller as? FloeOfficeNativeViewController else { throw CocoaError(.featureUnsupported) }
        do {
            try await withCheckedThrowingContinuation { (receipt: CheckedContinuation<Void, Error>) in
                native.insertAttachment(fromFileURL: url) { error in
                    if let error { receipt.resume(throwing: error) } else { receipt.resume() }
                }
            }
        } catch {
            // The engine may fail after creating the object but before its
            // metadata/undo receipt settles. Do not claim a failed callback
            // means nothing changed, or encourage a blind duplicate insertion.
            hasUncommittedChanges = true
            throw NSError(domain: "org.floeagent.office.attachment", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "附件插入未能完成，文档可能已有部分修改。请先检查当前文档，必要时撤销后再试；编辑副本已保留。",
                NSUnderlyingErrorKey: error
            ])
        }
        hasUncommittedChanges = true
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    func listAttachments() async throws -> [OfficeAttachmentItem] {
        guard canAct else { throw CocoaError(.featureUnsupported) }
        operating = true
        phase = .readingAttachments
        defer {
            phase = runtimeFailed || controller == nil ? .failed : .ready
            finishOperation()
        }
        #if canImport(FloeOfficeNative)
        guard let native = controller as? FloeOfficeNativeViewController else { throw CocoaError(.featureUnsupported) }
        return try await withCheckedThrowingContinuation { receipt in
            native.listAttachments { attachments, error in
                if let error { receipt.resume(throwing: error) }
                else if let attachments {
                    receipt.resume(returning: attachments.map { OfficeAttachmentItem(id: $0.identifier, name: $0.name, byteCount: $0.byteCount) })
                } else { receipt.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
        }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    func exportAttachment(id: String) async throws -> URL {
        guard canAct else { throw CocoaError(.featureUnsupported) }
        operating = true
        phase = .readingAttachments
        defer {
            phase = runtimeFailed || controller == nil ? .failed : .ready
            finishOperation()
        }
        #if canImport(FloeOfficeNative)
        guard let native = controller as? FloeOfficeNativeViewController else { throw CocoaError(.featureUnsupported) }
        return try await withCheckedThrowingContinuation { receipt in
            native.exportAttachment(withIdentifier: id) { url, error in
                if let error { receipt.resume(throwing: error) }
                else if let url { receipt.resume(returning: url) }
                else { receipt.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
        }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    func open(_ url: URL) async {
        guard !operating else { return }
        if session?.originalURL == url, controller != nil, phase != .failed { return }
        operating = true
        defer { finishOperation() }
        phase = .loading
        error = nil
        do {
            // Fullscreen has finished dismissing before the inspector mounts
            // this next controller. Retain the existing file/CAS session.
            if session?.originalURL == url, controller == nil {
                try await activate(readOnly: true)
                return
            }
            if session != nil { try await releaseCurrent() }
            let files = try SecurityScopedDocumentWorkspace()
            let opened = try await files.open(securityScopedURL: url)
            workspace = files
            session = opened
            hasUncommittedChanges = false
            try await activate(readOnly: true)
        } catch { fail(error) }
    }

    func enterEditing() async {
        guard !operating, session != nil else { return }
        if !readOnly, controller != nil, phase == .ready { return }
        operating = true
        defer { finishOperation() }
        do {
            try await closeController()
            try await activate(readOnly: false)
        } catch { fail(error) }
    }

    func saveAndReturn() async -> Bool {
        await save(returnToPreview: true)
    }

    func saveInPlace() async -> Bool {
        await save(returnToPreview: false)
    }

    private func save(returnToPreview: Bool) async -> Bool {
        guard canAct, !readOnly, let workspace, let session else { return false }
        operating = true
        defer { finishOperation() }
        phase = .saving
        error = nil
        hasSaveConflict = false
        do {
            #if canImport(FloeOfficeNative)
            guard let native = controller as? FloeOfficeNativeViewController else { throw CocoaError(.fileWriteUnknown) }
            native.view.isUserInteractionEnabled = false
            defer { native.view.isUserInteractionEnabled = true }
            try await withCheckedThrowingContinuation { (receipt: CheckedContinuation<Void, Error>) in
                native.saveWorkingCopy { error in
                    if let error { receipt.resume(throwing: error) } else { receipt.resume() }
                }
            }
            try await workspace.save(session)
            hasSaveConflict = false
            hasUncommittedChanges = try await workspace.hasUncommittedWorkingCopy(session)
            if !hasUncommittedChanges { await OfficeExplicitSaveBridge.didCommit(controller: native) }
            if returnToPreview {
                try await closeController()
                readOnly = true
                phase = .idle
            } else {
                phase = .ready
            }
            return true
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        } catch {
            if let officeError = error as? OfficeDocumentError, case .revisionConflict = officeError {
                hasSaveConflict = true
            }
            self.error = error.localizedDescription
            phase = runtimeFailed || controller == nil ? .failed : .ready
            return false
        }
    }

    // MARK: - External resource refresh

    /// Freezes the current editor and holds the session's operating lock across
    /// an external-revision decision and close. Returns false when another
    /// session operation (initial open, save, attachment) is in flight.
    func beginExternalRefresh() -> Bool {
        guard canAct else { return false }
        operating = true
        setEditorInteraction(false)
        return true
    }

    func endExternalRefresh() {
        guard operating else { return }
        setEditorInteraction(true)
        finishOperation()
    }

    /// True when the visible editor holds edits worth protecting. The engine's
    /// `.uno:ModifiedStatus` is authoritative because `hasUncommittedChanges`
    /// only tracks the working-copy file and ignores in-memory keyboard edits.
    /// A nil (unknown) engine answer must never be treated as clean.
    func hasLocalEditsToProtect() async -> Bool {
        if hasUncommittedChanges { return true }
        // Autosave can clear the engine's modified flag while the private
        // working copy still differs from Floe's last committed document.
        guard let workspace, let session else { return true }
        do {
            if try await workspace.hasUncommittedWorkingCopy(session) { return true }
        } catch { return true }
        switch await engineModifiedState() {
        case .some(false): return false
        default: return true
        }
    }

    /// Closes the current controller/working copy and reopens `url` while the
    /// caller still holds `beginExternalRefresh()`. On failure the editor is
    /// left in a recoverable failed state instead of silently discarding work.
    func replaceWithExternalVersion(url: URL, readOnly: Bool) async throws {
        try await closeController()
        if let session, let workspace { await workspace.close(session) }
        session = nil
        workspace = nil
        hasUncommittedChanges = false
        self.readOnly = true
        phase = .loading
        error = nil
        do {
            let files = try SecurityScopedDocumentWorkspace()
            let opened = try await files.open(securityScopedURL: url)
            workspace = files
            session = opened
            try await activate(readOnly: readOnly)
        } catch {
            self.readOnly = true
            fail(error)
            throw error
        }
    }

    private func engineModifiedState() async -> Bool? {
        #if canImport(FloeOfficeNative)
        guard let native = controller as? FloeOfficeNativeViewController, native.isViewLoaded,
              let webView = OfficeExplicitSaveBridge.findWebView(in: native.view) else { return nil }
        do {
            let value = try await webView.evaluateJavaScript(OfficeExplicitSaveBridge.modifiedStatusProbeScript)
            if let number = value as? NSNumber { return number.boolValue }
            if let text = value as? String {
                if text == "true" { return true }
                if text == "false" { return false }
            }
            return nil
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private func setEditorInteraction(_ enabled: Bool) {
        guard let controller, controller.isViewLoaded else { return }
        controller.view.isUserInteractionEnabled = enabled
        if !enabled { controller.view.endEditing(true) }
    }

    func discardAndReturn() async -> Bool {
        guard !operating, let session, let workspace else { return false }
        operating = true
        defer { finishOperation() }
        do {
            try await closeController()
            await workspace.discardChangesAndClose(session)
            self.session = try await workspace.open(securityScopedURL: session.originalURL)
            hasUncommittedChanges = false
            readOnly = true
            phase = .idle
            return true
        } catch { fail(error); return false }
    }

    func prepareSaveCopy() async -> DocumentExportSnapshot? {
        guard canAct, !readOnly, exportSnapshot == nil, let workspace, let session else { return nil }
        operating = true
        defer { finishOperation() }
        phase = .saving
        error = nil
        do {
            #if canImport(FloeOfficeNative)
            guard let native = controller as? FloeOfficeNativeViewController else { throw CocoaError(.fileWriteUnknown) }
            native.view.isUserInteractionEnabled = false
            defer { native.view.isUserInteractionEnabled = true }
            try await withCheckedThrowingContinuation { (receipt: CheckedContinuation<Void, Error>) in
                native.saveWorkingCopy { error in
                    if let error { receipt.resume(throwing: error) } else { receipt.resume() }
                }
            }
            let copy = try await workspace.prepareExport(session)
            exportSnapshot = copy
            exportWorkspace = workspace
            phase = .ready
            return copy
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        } catch {
            self.error = error.localizedDescription
            phase = runtimeFailed || controller == nil ? .failed : .ready
            return nil
        }
    }

    func conflictCopies() async throws -> OfficeConflictCopies {
        guard canAct, let workspace, let session else { throw CocoaError(.fileReadUnknown) }
        // The failed save already settled and preserved the native draft.
        let mine = try await workspace.prepareExport(session)
        do {
            let current = try await workspace.prepareCurrentExport(session)
            return OfficeConflictCopies(mine: mine, current: current, owner: workspace)
        } catch {
            await workspace.finishExport(mine)
            throw error
        }
    }

    func finishSaveCopy() async {
        guard let copy = exportSnapshot else { return }
        exportSnapshot = nil
        let owner = exportWorkspace
        exportWorkspace = nil
        await owner?.finishExport(copy)
    }

    func keepChangesAndReturn() async -> Bool {
        guard !operating, session != nil else { return false }
        operating = true
        defer { finishOperation() }
        do {
            // Persist the current editor contents when possible, but never
            // force a conflicting original writeback merely to leave the view.
            #if canImport(FloeOfficeNative)
            if let native = controller as? FloeOfficeNativeViewController, !readOnly, !runtimeFailed {
                native.view.isUserInteractionEnabled = false
                defer { native.view.isUserInteractionEnabled = true }
                try await withCheckedThrowingContinuation { (receipt: CheckedContinuation<Void, Error>) in
                    native.saveWorkingCopy { error in
                        if let error { receipt.resume(throwing: error) } else { receipt.resume() }
                    }
                }
            }
            #endif
            try await closeController()
            if let session, let workspace {
                hasUncommittedChanges = try await workspace.hasUncommittedWorkingCopy(session)
            }
            readOnly = true
            phase = .idle
            return true
        } catch { fail(error); return false }
    }

    /// View removal never deletes an unsettled edit or pretends it was saved.
    func release() async {
        guard !operating else { releaseRequested = true; return }
        operating = true
        defer { finishOperation() }
        do { try await releaseCurrent(); phase = .idle }
        catch { fail(error) }
    }

    func retryPreview() async {
        guard readOnly else { return }
        await previewCurrent()
    }

    func resumeRecovery(id: UUID) async {
        guard !operating else { return }
        operating = true
        defer { finishOperation() }
        phase = .loading
        error = nil
        do {
            if session != nil { try await releaseCurrent() }
            let files = try SecurityScopedDocumentWorkspace()
            let recovered = try await files.resumeRecovery(id: id)
            workspace = files
            session = recovered
            hasUncommittedChanges = try await files.hasUncommittedWorkingCopy(recovered)
            try await activate(readOnly: true)
        } catch { fail(error) }
    }

    func previewCurrent() async {
        guard !operating, session != nil else { return }
        operating = true
        defer { finishOperation() }
        do {
            try await closeController()
            try await activate(readOnly: true)
        } catch { fail(error) }
    }

    func recoveryVersions() async throws -> [DocumentRecoveryVersion] {
        guard canAct, readOnly, let workspace, let session else { throw CocoaError(.fileReadUnknown) }
        return try await workspace.recoveryVersions(session)
    }

    func useRecoveryVersion(_ version: DocumentRecoveryVersion) async -> Bool {
        guard canAct, readOnly, let workspace, let session else { return false }
        operating = true
        defer { finishOperation() }
        do {
            try await closeController()
            try await workspace.restoreRecoveryVersion(version, in: session)
            hasUncommittedChanges = try await workspace.hasUncommittedWorkingCopy(session)
            try await activate(readOnly: true)
            return true
        } catch { fail(error); return false }
    }

    private func finishOperation() {
        operating = false
        if releaseRequested {
            releaseRequested = false
            Task { await release() }
        }
    }
    private func releaseCurrent() async throws {
        try await closeController()
        if let session, let workspace { await workspace.close(session) }
        session = nil
        workspace = nil
    }
    private func activate(readOnly: Bool) async throws {
        guard let session else { throw CocoaError(.fileReadUnknown) }
        self.readOnly = readOnly
        drawingMode = false
        phase = .loading
        error = nil
        #if canImport(FloeOfficeNative)
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            FloeOfficeNativeRuntime.shared.prepare { error in
                if let error { ready.resume(throwing: error) } else { ready.resume() }
            }
        }
        let native = try FloeOfficeNativeViewController(
            workingFileURL: session.workingURL,
            sessionDirectory: session.workingURL.deletingLastPathComponent(), readOnly: readOnly)
        runtimeFailed = false
        native.onWorkingCopyOpened = { [weak self, weak native] success in
            guard let self, let native, self.controller === native, !self.runtimeFailed else { return }
            if success { self.phase = .ready }
            else { self.fail(CocoaError(.fileReadCorruptFile)) }
        }
        native.onClosed = { [weak self, weak native] _ in
            guard let self, let native, self.controller === native, !self.expectedClose else { return }
            self.runtimeFailed = true
            self.error = "文档已关闭，编辑副本已保留。"
            self.phase = .failed
        }
        try OfficeExplicitSaveBridge.installEmbeddedControls(controller: native)
        if !readOnly {
            explicitSaveBridge = try OfficeExplicitSaveBridge(controller: native) { [weak self, weak native] in
                guard let self, let native, self.controller === native else { return false }
                return await self.saveInPlace()
            }
        }
        controller = native
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
    private func closeController() async throws {
        guard let controller else { return }
        // No view means the upstream viewWillAppear has not opened a document.
        // Do not load a WebView merely to close an abandoned preview request.
        guard controller.isViewLoaded else {
            explicitSaveBridge?.invalidate()
            explicitSaveBridge = nil
            self.controller = nil
            return
        }
        phase = .closing
        expectedClose = true
        defer { expectedClose = false }
        #if canImport(FloeOfficeNative)
        if let native = controller as? FloeOfficeNativeViewController {
            try await withCheckedThrowingContinuation { (closed: CheckedContinuation<Void, Error>) in
                native.closeWorkingCopy { error in
                    if let error { closed.resume(throwing: error) } else { closed.resume() }
                }
            }
        }
        #endif
        explicitSaveBridge?.invalidate()
        explicitSaveBridge = nil
        self.controller = nil
    }
    private func fail(_ error: Error) {
        self.error = error.localizedDescription
        phase = .failed
    }
}

private struct OfficeControllerSurface: UIViewControllerRepresentable {
    let controller: UIViewController
    func makeUIViewController(context: Context) -> UIViewController { controller }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

struct OfficeDocumentSurface: View {
    @ObservedObject var session: OfficeFileSession
    var body: some View {
        ZStack {
            if let controller = session.controller {
                OfficeControllerSurface(controller: controller)
                    .id(ObjectIdentifier(controller))
                    .accessibilityIdentifier(session.readOnly ? "office.preview.native" : "office.editor.native")
            }
            if session.phase == .failed {
                ContentUnavailableView {
                    Label("无法打开文档", systemImage: "doc.badge.ellipsis")
                } description: { Text(session.error ?? "请稍后重试。") } actions: {
                    if session.readOnly {
                        Button("重试") { Task { await session.retryPreview() } }
                    }
                }
            } else if session.phase != .ready {
                ProgressView(session.phase == .saving ? "正在保存…" : session.phase == .closing ? "正在关闭…" : session.phase == .insertingAttachment ? "正在插入附件…" : session.phase == .readingAttachments ? "正在读取附件…" : "正在打开文档…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FloeTheme.readingSurface)
        .safeAreaInset(edge: .top, spacing: 0) {
            if session.readOnly && session.hasUncommittedChanges {
                Label("有未写回原文件的修改", systemImage: "doc.badge.clock")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(8)
                    .background(.regularMaterial)
            }
        }
    }
}

struct OfficeDocumentEditorView: View {
    let relativePath: String
    @ObservedObject var session: OfficeFileSession
    var onSaved: (() async -> Bool)?
    var onClose: (() -> Void)? = nil
    /// A feature-owned tab strip replaces the standalone navigation title.
    var inlineHeader: AnyView? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @State private var confirmingDiscard = false
    @State private var comparingVersions = false
    @State private var convertedExport: OfficeConvertedExport?
    @State private var export: DocumentExportSnapshot?
    @State private var savedCopyNotice = false
    @State private var exportSucceeded = false
    @State private var choosingAttachment = false
    @State private var choosingWorkspaceAttachment = false
    @State private var showingAttachments = false
    @State private var attachmentError: String?

    var body: some View {
        OfficeDocumentSurface(session: session)
            .navigationTitle((relativePath as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if inlineHeader == nil {
                    ToolbarItem(placement: .cancellationAction) { backButton }
                    ToolbarItem(placement: .primaryAction) { documentActions }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let inlineHeader {
                    VStack(spacing: 0) {
                        HStack(spacing: 4) {
                            backButton
                            inlineHeader.frame(maxWidth: .infinity, alignment: .leading)
                            documentActions
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.bar)
                        Divider()
                    }
                    .accessibilityIdentifier("office.editor.header")
                }
            }
            .interactiveDismissDisabled()
            .task { await session.enterEditing() }
            .sheet(item: $convertedExport) { OfficeConvertedExportShareSheet(url: $0.url) }
            .sheet(isPresented: $comparingVersions) { OfficeConflictReviewView(session: session) }
            .sheet(isPresented: $choosingWorkspaceAttachment) {
                OfficeWorkspaceAttachmentPicker(environment: environment) { url in
                    try await session.insertAttachment(url)
                }
            }
            .sheet(isPresented: $showingAttachments) { OfficeAttachmentListView(session: session) }
            .fileImporter(isPresented: $choosingAttachment, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task {
                        do { try await session.insertAttachment(url) }
                        catch { attachmentError = error.localizedDescription }
                    }
                case .failure(let error):
                    let failure = error as NSError
                    if failure.domain != NSCocoaErrorDomain || failure.code != NSUserCancelledError {
                        attachmentError = error.localizedDescription
                    }
                }
            }
            .alert("未能插入附件", isPresented: Binding(
                get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
                    Button("好", role: .cancel) { attachmentError = nil }
                } message: { Text(attachmentError ?? "") }
            .sheet(item: $export, onDismiss: {
                Task { await session.finishSaveCopy() }
                savedCopyNotice = exportSucceeded
                exportSucceeded = false
            }) { snapshot in
                OfficeCopyDestinationPicker(url: snapshot.fileURL) { saved in
                    exportSucceeded = saved
                    export = nil
                }
            }
            .alert("副本已保存", isPresented: $savedCopyNotice) {
                Button("好", role: .cancel) {}
            } message: { Text("当前编辑仍对应原文件。") }
            .alert("未能保存", isPresented: Binding(
                get: { session.error != nil && session.phase == .ready },
                set: { if !$0 { session.error = nil } })) {
                    Button("继续编辑", role: .cancel) { session.error = nil }
                    if session.hasSaveConflict {
                        Button("edit.conflict.compareVersions") { session.error = nil; comparingVersions = true }
                    }
                    Button("另存副本…") {
                        session.error = nil
                        Task { export = await session.prepareSaveCopy() }
                    }
                    if onSaved == nil {
                        Button("保留修改并返回") {
                            session.error = nil
                            Task { if await session.keepChangesAndReturn() { dismissEditor() } }
                        }
                    }
                } message: { Text(session.error ?? "") }
            .confirmationDialog("放弃未保存的修改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) {
                    Task { if await session.discardAndReturn() { dismissEditor() } }
                }
                Button("继续编辑", role: .cancel) {}
            }
    }

    private var backButton: some View {
        Button("返回", systemImage: "chevron.left") {
            if session.phase == .failed { dismissEditor() }
            else { Task { await saveAndDismiss() } }
        }
        .labelStyle(.iconOnly).frame(width: 44, height: 44)
        .disabled(!session.canAct && session.phase != .failed)
        .accessibilityIdentifier("office.editor.back")
        .accessibilityHint(session.phase == .failed ? "保留编辑副本并关闭" : "保存文档并返回预览")
    }

    @ViewBuilder private var primaryActions: some View {
        if session.supportsAttachmentInsertion {
            Menu {
                Button("从工作区选择", systemImage: "folder") { choosingWorkspaceAttachment = true }
                Button("从文件选择", systemImage: "doc") { choosingAttachment = true }
                Divider()
                Button("查看文档附件", systemImage: "paperclip") { showingAttachments = true }
            } label: { Label("附件", systemImage: "paperclip").frame(minWidth: 44, minHeight: 44) }
                .disabled(!session.canAct)
                .accessibilityIdentifier("office.editor.insertAttachment")
        }
        if session.supportsDrawing {
            Button {
                Task { do { try await session.toggleDrawing() } catch { session.error = error.localizedDescription } }
            } label: {
                Label(session.drawingMode ? "结束批注" : "画笔批注", systemImage: "pencil.tip")
                    .frame(minWidth: 44, minHeight: 44)
            }.disabled(!session.canAct).accessibilityIdentifier("office.drawing.toggle")
        }
        if session.supportsPresentation {
            Button {
                Task { do { try await session.startPresentation() } catch { session.error = error.localizedDescription } }
            } label: { Label("放映", systemImage: "play.rectangle").frame(minWidth: 44, minHeight: 44) }
                .disabled(!session.canAct).accessibilityIdentifier("office.presentation.start")
        }
    }

    private var documentMenu: some View {
        Menu {
            if inlineHeader != nil && sizeClass == .compact {
                primaryActions.labelStyle(.titleAndIcon)
                Divider()
            }
            Button("保存并返回") { Task { await saveAndDismiss() } }
            if !session.exportFormats.isEmpty {
                Menu("导出格式", systemImage: "square.and.arrow.up") {
                    ForEach(session.exportFormats, id: \.self) { format in
                        Button(format.uppercased()) {
                            Task {
                                do { convertedExport = .init(url: try await session.exportDocument(format: format)) }
                                catch { session.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            Button("另存副本…", systemImage: "doc.on.doc") { Task { export = await session.prepareSaveCopy() } }
            if onSaved == nil {
                Button("保留修改并返回") {
                    Task { if await session.keepChangesAndReturn() { dismissEditor() } }
                }
            }
            Button("放弃修改", role: .destructive) { confirmingDiscard = true }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .disabled(!session.canAct)
            .accessibilityLabel("文档操作")
    }

    private var documentActions: some View {
        HStack(spacing: 4) {
            if inlineHeader == nil || sizeClass != .compact { primaryActions }
            documentMenu
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    private func dismissEditor() {
        if let onClose { onClose() } else { dismiss() }
    }

    private func saveAndDismiss() async {
        // An owning Notes transaction may still reject its resource commit.
        // Keep the native editor mounted until that owner confirms success,
        // so a conflict/error leaves a usable editor and export path.
        let saved = onSaved == nil ? await session.saveAndReturn() : await session.saveInPlace()
        guard saved else { return }
        if await onSaved?() ?? true { dismissEditor() }
    }
}

struct OfficeCopyDestinationPicker: UIViewControllerRepresentable {
    let url: URL
    let completion: (Bool) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        picker.shouldShowFileExtensions = true
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Bool) -> Void
        private var finished = false
        init(completion: @escaping (Bool) -> Void) { self.completion = completion }
        private func finish(_ saved: Bool) {
            guard !finished else { return }
            finished = true
            completion(saved)
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(!urls.isEmpty)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
    }
}
private struct OfficeConvertedExport: Identifiable {
    let id = UUID()
    let url: URL
}
private struct OfficeConvertedExportShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
