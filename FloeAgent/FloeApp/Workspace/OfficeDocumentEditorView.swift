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
    private var workspace: SecurityScopedDocumentWorkspace?
    private var session: DocumentSession?
    private var operating = false
    private var releaseRequested = false
    private var expectedClose = false
    private var runtimeFailed = false
    private var runtimeFailureObservation: AnyCancellable?
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
        try await withCheckedThrowingContinuation { (receipt: CheckedContinuation<Void, Error>) in
            native.insertAttachment(fromFileURL: url) { error in
                if let error { receipt.resume(throwing: error) } else { receipt.resume() }
            }
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
        guard canAct, !readOnly, let workspace, let session else { return false }
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
            try await workspace.save(session)
            hasUncommittedChanges = try await workspace.hasUncommittedWorkingCopy(session)
            try await closeController()
            readOnly = true
            phase = .idle
            return true
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        } catch {
            self.error = error.localizedDescription
            phase = runtimeFailed || controller == nil ? .failed : .ready
            return false
        }
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
        controller = native
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }
    private func closeController() async throws {
        guard let controller else { return }
        // No view means the upstream viewWillAppear has not opened a document.
        // Do not load a WebView merely to close an abandoned preview request.
        guard controller.isViewLoaded else { self.controller = nil; return }
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
    var onSaved: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @State private var confirmingDiscard = false
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
                if session.supportsAttachmentInsertion {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("从工作区选择", systemImage: "folder") { choosingWorkspaceAttachment = true }
                            Button("从文件选择", systemImage: "doc") { choosingAttachment = true }
                            Divider()
                            Button("查看文档附件", systemImage: "paperclip") { showingAttachments = true }
                        } label: { Label("附件", systemImage: "paperclip") }
                            .disabled(!session.canAct)
                            .accessibilityIdentifier("office.editor.insertAttachment")
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("返回") {
                        if session.phase == .failed { dismiss() }
                        else { Task { if await session.saveAndReturn() { onSaved?(); dismiss() } } }
                    }
                    .disabled(!session.canAct && session.phase != .failed)
                    .accessibilityHint(session.phase == .failed ? "保留编辑副本并关闭" : "保存文档并返回预览")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Menu {
                        Button("保存并返回") {
                            Task { if await session.saveAndReturn() { onSaved?(); dismiss() } }
                        }
                        Button("另存副本…", systemImage: "doc.on.doc") {
                            Task { export = await session.prepareSaveCopy() }
                        }
                        Button("保留修改并返回") {
                            Task { if await session.keepChangesAndReturn() { dismiss() } }
                        }
                        Button("放弃修改", role: .destructive) { confirmingDiscard = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(!session.canAct)
                    .accessibilityLabel("文档操作")
                }
            }
            .interactiveDismissDisabled()
            .task { await session.enterEditing() }
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
                    Button("另存副本…") {
                        session.error = nil
                        Task { export = await session.prepareSaveCopy() }
                    }
                    Button("保留修改并返回") {
                        session.error = nil
                        Task { if await session.keepChangesAndReturn() { dismiss() } }
                    }
                } message: { Text(session.error ?? "") }
            .confirmationDialog("放弃未保存的修改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) {
                    Task { if await session.discardAndReturn() { dismiss() } }
                }
                Button("继续编辑", role: .cancel) {}
            }
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
#endif
