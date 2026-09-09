// FloeApp — shared native Office preview and fullscreen editing session.
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import Combine
import FloeDocuments
#if canImport(FloeOfficeNative)
import FloeOfficeNative
#endif

@MainActor
final class OfficeFileSession: ObservableObject {
    enum Phase { case idle, loading, ready, saving, closing, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var controller: UIViewController?
    @Published private(set) var readOnly = true
    @Published var error: String?
    private var workspace: SecurityScopedDocumentWorkspace?
    private var session: DocumentSession?
    private var operating = false
    private var releaseRequested = false
    private var expectedClose = false
    private var runtimeFailed = false
    private var runtimeFailureObservation: AnyCancellable?

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
            try await activate(readOnly: true)
        } catch { fail(error) }
    }

    func enterEditing() async {
        guard !operating, session != nil else { return }
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
        guard readOnly, let url = session?.originalURL else { return }
        await open(url)
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
        native.onWorkingCopyOpened = { [weak self, weak native] success in
            guard let self, let native, self.controller === native else { return }
            if success { self.phase = .ready }
            else { self.fail(CocoaError(.fileReadCorruptFile)) }
        }
        native.onClosed = { [weak self, weak native] _ in
            guard let self, let native, self.controller === native, !self.expectedClose else { return }
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
                ProgressView(session.phase == .saving ? "正在保存…" : session.phase == .closing ? "正在关闭…" : "正在打开文档…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FloeTheme.readingSurface)
    }
}

struct OfficeDocumentEditorView: View {
    let relativePath: String
    @ObservedObject var session: OfficeFileSession
    var onSaved: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDiscard = false

    var body: some View {
        OfficeDocumentSurface(session: session)
            .navigationTitle((relativePath as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
                        Button("放弃修改", role: .destructive) { confirmingDiscard = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .disabled(!session.canAct)
                    .accessibilityLabel("文档操作")
                }
            }
            .interactiveDismissDisabled()
            .task { await session.enterEditing() }
            .alert("未能保存", isPresented: Binding(
                get: { session.error != nil && session.phase == .ready },
                set: { if !$0 { session.error = nil } })) {
                    Button("继续编辑", role: .cancel) { session.error = nil }
                } message: { Text(session.error ?? "") }
            .confirmationDialog("放弃未保存的修改？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) {
                    Task { if await session.discardAndReturn() { dismiss() } }
                }
                Button("继续编辑", role: .cancel) {}
            }
    }
}
#endif
