// FloeApp — shared native Office preview and fullscreen editing session.
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Combine
import WebKit
import FloeDocuments
#if canImport(FloeOfficeNative)
import FloeOfficeNative
#endif

/// One-shot, main-queue close acknowledgement used to bound a native close.
/// The first resolver (engine callback or timeout) wins; later resolutions are
/// ignored so a completion arriving after a timeout can never resume twice.
/// The settled result is stored, so a resolution that lands before `wait()`
/// is still returned verbatim instead of being mistaken for a timeout.
@MainActor
private final class OfficeCloseAck {
    private var continuation: CheckedContinuation<OfficeFileSession.OfficeCloseResult, Never>?
    private var settledResult: OfficeFileSession.OfficeCloseResult?

    func wait() async -> OfficeFileSession.OfficeCloseResult {
        if let settledResult { return settledResult }
        return await withCheckedContinuation { continuation in
            if let settledResult {
                continuation.resume(returning: settledResult)
            } else {
                self.continuation = continuation
            }
        }
    }

    func resolve(_ result: OfficeFileSession.OfficeCloseResult) {
        guard settledResult == nil else { return }
        settledResult = result
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// One-shot, main-queue save receipt used to bound a native working-copy
/// save. The first resolver (engine receipt or timeout) wins; later resolutions
/// are ignored so a completion arriving after a timeout can never resume twice
/// or report over an already-settled result. A host that neither acknowledges
/// nor fails therefore surfaces a bounded, recoverable error instead of leaving
/// the editor on "正在保存…" indefinitely.
@MainActor
final class OfficeSaveReceipt {
    private var continuation: CheckedContinuation<Void, Error>?
    /// Result settled before any waiter attached; replayed to the first
    /// `wait()` so either ordering (resolve-first or wait-first) is safe.
    private var settledResult: Result<Void, Error>?
    private var settled = false

    func wait() async throws {
        if settled {
            let result = settledResult ?? .success(())
            settledResult = nil
            switch result {
            case .success: return
            case .failure(let error): throw error
            }
        }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }

    /// Settles the receipt exactly once; later resolutions are ignored.
    func resolve(_ result: Result<Void, Error>) {
        guard !settled else { return }
        if let continuation {
            settled = true
            self.continuation = nil
            switch result {
            case .success: continuation.resume()
            case .failure(let error): continuation.resume(throwing: error)
            }
        } else {
            // No waiter yet: retain the result for the first `wait()`.
            settled = true
            settledResult = result
        }
    }
}

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
    /// Floe-owned stroke settings for the current document. Independent from
    /// Notes and Canvas ink; persisted under its own defaults key.
    @Published private(set) var inkPreferences: OfficeInkPreferences
    @Published private(set) var inkApplyOutcome: OfficeExplicitSaveBridge.InkApplyOutcome?
    @Published var inkError: String?
    /// Set only when an explicit edit request could not be honoured by the
    /// engine (protected document / backend refusal). While non-nil the session
    /// stays in preview; Floe never fakes a writable document.
    @Published private(set) var editUnavailableReason: String?
    /// True when this session's document is a cloud/network snapshot staged in
    /// a private temporary copy. There is no real remote write-back yet, so
    /// entering edit would only mutate a throwaway copy and any later save
    /// would masquerade as a remote save. Owning surfaces set this before
    /// `open`; the session refuses editing and the UI shows the
    /// download-to-local hint instead of any edit affordance.
    @Published var isRemoteSnapshot = false
    private var workspace: SecurityScopedDocumentWorkspace?
    private var session: DocumentSession?
    private var requestedURL: URL?
    private var operating = false
    private var releaseRequested = false
    /// Terminal once `release()` is called (tab close / IDE close). A replayed
    /// queued intent must never re-open a working copy on a released session.
    private var released = false
    /// Engine-reported backing permission for the mounted session. `nil` means
    /// the host has not reported yet; it is never inferred from the App's own
    /// requested grant.
    private var engineSessionReadOnly: Bool?
    private var intentQueue = OfficeEditIntentQueue()
    private var intentWaiters: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var expectedClose = false
    private var runtimeFailed = false
    private var runtimeFailureObservation: AnyCancellable?
    private var explicitSaveBridge: OfficeExplicitSaveBridge?
    private var exportSnapshot: DocumentExportSnapshot?
    private var exportWorkspace: SecurityScopedDocumentWorkspace?
    /// Serializes/coalesces ink dispatches so an older completion can never
    /// publish over the latest stroke or a document that has since switched.
    private var inkSequencer = OfficeInkApplySequencer()
    /// Continuation awaiting the pinned host's verified engine permission for
    /// the controller this session just mounted. The host probes the backing
    /// permission, follows the engine's guarded mobile edit entry and reports
    /// the real state; racing it with an immediate JS probe reads an unopened
    /// page as read-only and is the root cause of the iPhone edit that silently
    /// fell back to preview.
    private var permissionWaiter: CheckedContinuation<Bool?, Never>?
    /// Bounded opening watchdog. A host that never reports readiness must not
    /// leave the surface on a spinner forever.
    private var openWatchdog: Task<Void, Never>?
    /// Invoked after a verified original-file commit. Owning surfaces use it to
    /// refresh sibling entries (IDE tabs, file tree, preview) so a save is
    /// visible from every entry point.
    var onCommitted: (() -> Void)?

    init() {
        inkPreferences = OfficeInkPreferences.session(forDocument: "")
        #if canImport(FloeOfficeNative)
        runtimeFailureObservation = NotificationCenter.default.publisher(for: .FloeOfficeNativeRuntimeDidFail)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.runtimeFailed = true
                    (self.controller as? FloeOfficeNativeViewController)?.cancelPendingSave()
                    self.error = OfficeInkText.t(
                        "文档服务已停止响应，编辑副本已保留；重启应用后可恢复。",
                        "The document service stopped responding. Your editing copies were retained; restart the app to recover.")
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

    /// Shared copy for every surface that hosts a cloud/network Office
    /// snapshot. Kept on the session so FilePreview, the IDE tab and the
    /// fullscreen editor all present the same truthful message.
    static let remoteSnapshotHint = OfficeInkText.t(
        "云端/网络文档当前为只读快照。要编辑，请先将文件下载到本地工作区后再打开。",
        "Cloud and network documents are read-only snapshots. To edit, download the file to a local workspace and open it there.")

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
        if enabled { await applyInkPreferences() } else { inkApplyOutcome = nil; inkError = nil }
    }

    /// Points the current document's stroke preferences at the given workspace
    /// document. Call before editing starts; settings persist per document and
    /// never read or write Canvas/Notes ink. The workspace identity keeps two
    /// same-named files in different workspaces separate while the digest keeps
    /// the raw path out of `UserDefaults`.
    ///
    /// `stableIdentity` is supplied by `FilePreviewView` for a cloud or
    /// network file, whose local editing URL is a fresh preview copy each
    /// load, and by Notes for its generated Office documents, whose staged
    /// working copy likewise lives in a fresh UUID folder on every open.
    /// Local Office documents pass nil, so their persisted settings keep
    /// following the stable `session.originalURL` physical path and can never
    /// be rebound to a transient workspace id.
    func useInkPreferences(stableIdentity: OfficeInkDocumentIdentity? = nil,
                           workspaceIdentity: String?,
                           documentKey: String) {
        let key = OfficeInkPreferences.resolvedDocumentKey(
            stableIdentity: stableIdentity,
            originalURL: session?.originalURL,
            fallbackWorkspaceIdentity: workspaceIdentity,
            fallbackDocumentKey: documentKey)
        guard inkPreferences.documentKey != key else { return }
        invalidateInkApply()
        inkPreferences = OfficeInkPreferences.session(forDocument: key)
        inkApplyOutcome = nil
        inkError = nil
    }

    /// Dispatches the current stroke to the engine's own freehand tool. Rapid
    /// slider/colour changes are coalesced: a request that arrives while a
    /// dispatch is in flight returns immediately and the running drain loop
    /// re-runs with the newest stroke. Only the newest generation may publish,
    /// so an older completion can never overwrite the latest settings.
    ///
    /// Pencil-only input is not gated: the pinned host owns the WebView pointer
    /// handlers and exposes no verified pen-vs-finger event hook, so no finger
    /// protection is claimed here.
    func applyInkPreferences() async {
        inkError = nil
        guard drawingMode, !readOnly, let controller, supportsDrawing else {
            inkApplyOutcome = nil
            return
        }
        let epoch = inkSequencer.epoch
        guard inkSequencer.begin() else { return }
        while let generation = inkSequencer.next(epoch: epoch) {
            let key = inkPreferences.documentKey
            let stroke = inkPreferences.stroke
            do {
                let outcome = try await OfficeExplicitSaveBridge.applyInk(stroke, controller: controller)
                guard inkSequencer.complete(generation, epoch: epoch),
                      key == inkPreferences.documentKey,
                      self.controller === controller,
                      drawingMode else { continue }
                inkApplyOutcome = outcome
                inkError = nil
            } catch {
                guard inkSequencer.complete(generation, epoch: epoch),
                      key == inkPreferences.documentKey,
                      self.controller === controller,
                      drawingMode else { continue }
                inkApplyOutcome = nil
                inkError = error.localizedDescription
            }
        }
    }

    /// Rejects any in-flight ink completion and clears its published result.
    /// Called whenever the session closes, switches document or replaces its
    /// controller so an older dispatch cannot describe the new document.
    private func invalidateInkApply() {
        inkSequencer.invalidate()
        inkApplyOutcome = nil
    }

    func exportDocument(format: String) async throws -> URL {
        guard canAct, exportFormats.contains(format), let controller else { throw CocoaError(.featureUnsupported) }
        operating = true; phase = .saving
        defer { phase = runtimeFailed || self.controller == nil ? .failed : .ready; finishOperation() }
        #if canImport(FloeOfficeNative)
        if !readOnly, let native = controller as? FloeOfficeNativeViewController {
            // Bounded; export flushes the working copy first and can be slow on
            // large documents, so allow a longer window than an ordinary save.
            try await Self.saveWorkingCopy(native, timeout: 60)
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
        // An explicit open starts a new lifecycle: views such as
        // FilePreviewView release on disappear and reopen on appear.
        released = false
        requestedURL = url
        await performIntent(.preview)
    }

    /// Terminal open failure reported by the owning surface when URL
    /// resolution or the open intent itself failed before any controller
    /// mounted. Publishes a recoverable `.failed` state (the surface offers
    /// Retry) instead of leaving the phase on `.idle`, which
    /// `OfficeDocumentSurface` renders as an endless "opening" spinner and
    /// which never re-arms the owning loader.
    func reportOpenFailure(_ error: Error) {
        self.error = error.localizedDescription
        phase = .failed
    }

    /// Queued edit-intent entry point. While an open/save/attachment operation
    /// owns the session the intent is remembered and replayed when it settles,
    /// so tapping Edit on a loading document is never silently dropped. An
    /// automatic preview reopen can never displace this explicit intent.
    @discardableResult
    func requestEditing() async -> Bool {
        await performIntent(.edit)
    }

    func enterEditing() async {
        _ = await requestEditing()
    }

    private func performIntent(_ intent: OfficeEditIntentQueue.Intent) async -> Bool {
        guard !released else { return false }
        switch intentQueue.begin(intent, isBusy: operating) {
        case .ignorePreview:
            return false
        case .runNow:
            return await execute(intent)
        case .queued(let ticket):
            if let superseded = ticket.supersededToken {
                intentWaiters.removeValue(forKey: superseded)?.resume(returning: false)
            }
            return await withCheckedContinuation { continuation in
                intentWaiters[ticket.token] = continuation
            }
        }
    }

    private func execute(_ intent: OfficeEditIntentQueue.Intent) async -> Bool {
        guard !released else { return false }
        guard !operating else {
            // Defensive: no caller may run a second owning operation. Keep the
            // intent for the current owner's finish instead of racing it.
            let token = intentQueue.allocateToken()
            intentQueue.restoreIfEmpty(intent: intent, token: token)
            return false
        }
        operating = true
        defer { finishOperation() }
        switch intent {
        case .preview:
            return await executePreview()
        case .edit:
            return await executeEdit()
        }
    }

    private func executePreview() async -> Bool {
        guard let url = requestedURL else { return false }
        if session?.originalURL == url, controller != nil, phase != .failed { return true }
        phase = .loading
        error = nil
        do {
            // Fullscreen has finished dismissing before the inspector mounts
            // this next controller. Retain the existing file/CAS session.
            if session?.originalURL == url, controller == nil {
                try await activate(readOnly: true)
                return true
            }
            if session != nil { try await releaseCurrent() }
            let files = try SecurityScopedDocumentWorkspace()
            let opened = try await files.open(securityScopedURL: url)
            workspace = files
            session = opened
            hasUncommittedChanges = false
            try await activate(readOnly: true)
            return true
        } catch { fail(error); return false }
    }

    private func executeEdit() async -> Bool {
        // No document yet: the open intent must complete first. A tap that
        // arrives while the open owns the session is queued by performIntent;
        // a tap that beats the open entirely (the standalone host's edit
        // intent can run before its parent's `.task` open) opens the requested
        // document here and then continues into edit. Dropping that intent
        // left the PPTX/Word/Excel editor on a preview with no edit entry.
        if session == nil {
            guard requestedURL != nil, await executePreview() else { return false }
        }
        guard session != nil else { return false }
        if !readOnly, controller != nil, phase == .ready { return true }
        // A cloud/network snapshot has no write-back target yet: editing would
        // only change the throwaway preview copy and a later save would look
        // like a successful remote save. Refuse with the download hint, keep
        // the truthful preview mounted, and never touch the temp copy.
        guard !isRemoteSnapshot else {
            editUnavailableReason = Self.remoteSnapshotHint
            return false
        }
        phase = .loading
        error = nil
        editUnavailableReason = nil
        do {
            try await closeController()
            try await activate(readOnly: false)
            // Only a verified editable engine session clears preview. The
            // probe result is the acknowledgement, never the requested flag.
            try await acknowledgeEditPermission()
            return !readOnly
        } catch {
            // A failed edit activation must never leave a writable claim on a
            // dead session: nothing verified as editable. Restore the truthful
            // read-only claim so the failed surface offers its preview retry,
            // the IDE shows the Edit entry again instead of dead Save/Discard
            // chrome, and a later explicit edit can be attempted.
            readOnly = true
            if editUnavailableReason == nil { editUnavailableReason = error.localizedDescription }
            fail(error)
            return false
        }
    }

    /// Waits for the pinned host's verified engine permission for the mounted
    /// controller, bounded. `nil` means the host did not report in time; that
    /// is not a denial and callers must probe once more before deciding.
    private func awaitEnginePermission(seconds: Double) async -> Bool? {
        if let engineSessionReadOnly { return engineSessionReadOnly }
        let nanoseconds = UInt64(max(0.1, seconds) * 1_000_000_000)
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            self?.resolveEnginePermission(nil)
        }
        let value: Bool? = await withCheckedContinuation { continuation in
            if let resolved = engineSessionReadOnly {
                continuation.resume(returning: resolved)
            } else if permissionWaiter != nil {
                // Defensive: an older wait can never hang; settle it first.
                resolveEnginePermission(nil)
                permissionWaiter = continuation
            } else {
                permissionWaiter = continuation
            }
        }
        timeout.cancel()
        return value
    }

    private func resolveEnginePermission(_ value: Bool?) {
        guard let waiter = permissionWaiter else { return }
        permissionWaiter = nil
        waiter.resume(returning: value)
    }

    #if canImport(FloeOfficeNative)
    /// A host that never reports an open must not leave the surface on a
    /// spinner forever. The watchdog only fires while this exact controller is
    /// still loading and reports a truthful failed open with retained copies.
    ///
    /// An editable open is not just a load: the engine must also leave preview
    /// mode, which a chart-heavy PPTX or a cold compact-layout start can take
    /// longer than a plain preview. The editable budget is therefore larger
    /// (45 s); the permission acknowledgement and save paths keep their own
    /// separate, smaller bounds.
    private func startOpenWatchdog(for native: FloeOfficeNativeViewController, readOnly: Bool) {
        cancelOpenWatchdog()
        let budget: UInt64 = readOnly ? 30_000_000_000 : 45_000_000_000
        openWatchdog = Task { @MainActor [weak self, weak native] in
            try? await Task.sleep(nanoseconds: budget)
            guard !Task.isCancelled, let self, let native, self.controller === native,
                  self.phase == .loading, !self.runtimeFailed else { return }
            self.runtimeFailed = true
            self.error = readOnly
                ? "文档引擎未能在限定时间内打开预览；原文件未被修改。"
                : "文档引擎未能在限定时间内打开编辑副本；编辑副本已保留。"
            self.phase = .failed
        }
    }
    #endif

    private func cancelOpenWatchdog() {
        openWatchdog?.cancel()
        openWatchdog = nil
    }

    /// Reads the pinned engine's real permission after an edit activation and
    /// attempts the engine's own mobile edit switch when it still reports
    /// readonly. A protected document or a switch the engine refuses returns
    /// to the preview controller with an explicit reason — the session never
    /// pretends to be writable.
    ///
    /// The host's verified permission callback is awaited first: the engine can
    /// take several seconds to boot and mount (cold start, compact/iPhone
    /// layout), and an immediate JS probe of a not-yet-opened page used to be
    /// read as read-only and bounce the editor back to preview.
    private func acknowledgeEditPermission() async throws {
        #if canImport(FloeOfficeNative)
        guard let native = controller as? FloeOfficeNativeViewController else { return }
        var hostReadOnly = await awaitEnginePermission(seconds: 20)
        if hostReadOnly == false {
            engineSessionReadOnly = false
            readOnly = false
            editUnavailableReason = nil
            return
        }
        guard native.isViewLoaded, let webView = OfficeExplicitSaveBridge.findWebView(in: native.view) else {
            // Without a mounted surface the engine has not opened yet. The host
            // callback (or the open watchdog) still owns this session; never
            // fabricate a read-only denial from a missing page.
            return
        }
        var probe = await Self.permissionProbe(webView)
        // Only a definite protected state takes this path; an unknown probe is
        // handled by the conservative checks below, which never read a missing
        // flag as an editable grant.
        if probe.documentProtected == true {
            try await fallBackToPreview(reason: OfficeInkText.t(
                "该文档受保护，只能预览；未修改任何内容。",
                "This document is protected. Preview only; nothing was changed."))
            return
        }
        // The host reports the engine's verified backing permission; the JS
        // probe is the fallback surface. An unverified (nil/unknown) state is
        // never read as an editable grant.
        if hostReadOnly == nil { hostReadOnly = probe.isKnown ? probe.isReadOnly : nil }
        if hostReadOnly == true {
            // Follow the engine's own guarded mobile entry through the host
            // API: it reports the engine state after the attempt and
            // distinguishes an edit-password challenge (error 42) from a
            // denied document. A read-only grant is never relaxed there.
            let entry = await Self.enterEditMode(native)
            if entry.pendingPassword {
                // The engine is challenging for the edit password; that is a
                // prompt, not a denial. Keep the editor mounted and explain,
                // instead of bouncing to the preview. The engine's permission
                // observer clears this once the password is supplied.
                editUnavailableReason = OfficeInkText.t(
                    "该文档需要编辑密码，请在编辑器中输入。",
                    "This document requires its edit password. Enter it in the editor.")
                return
            }
            engineSessionReadOnly = entry.readOnly
            hostReadOnly = entry.readOnly
            // The mobile UI switches modes asynchronously after the guarded
            // entry; give the engine a bounded settling window before
            // concluding that the document is denied. Cold starts and remounts
            // on compact layouts can take several seconds before the page
            // reports its real backing permission through the observer, so the
            // window must outlast them — the previous 3s budget read a slow
            // editable document as denied and bounced it back to preview,
            // which is why later edit attempts kept failing.
            for _ in 0..<60 {
                if Task.isCancelled { break }
                if hostReadOnly == false { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let reported = engineSessionReadOnly, reported == false {
                    hostReadOnly = false
                    break
                }
                probe = await Self.permissionProbe(webView)
                if probe.isKnown, !probe.isReadOnly {
                    hostReadOnly = false
                    break
                }
            }
        }
        // Only a verified state clears preview: the host's engine-truth report
        // first, then a known engine probe. Unknown is never editable, but an
        // unknown probe with no host report is left mounted (the host callback
        // still settles it) instead of forcing a close that can stall.
        if hostReadOnly == nil {
            // The engine never confirmed an editable grant. Never leave a
            // writable claim on an unverified session (a false save/close
            // state): restore the truthful read-only preview, settle the
            // surface onto the mounted controller, and stop the open watchdog,
            // which would otherwise turn this recoverable "unknown" into a
            // misleading hard failure after its timeout.
            readOnly = true
            editUnavailableReason = OfficeInkText.t(
                "编辑器尚未确认可编辑状态；若仍只读，请稍后重试或解除文档限制。",
                "The editor has not confirmed an editable state yet; retry shortly, or remove the document restriction.")
            cancelOpenWatchdog()
            phase = .ready
            return
        }
        if hostReadOnly == true {
            try await fallBackToPreview(reason: OfficeInkText.t(
                "编辑器以只读模式打开，无法安全进入编辑。可重试；若仍只读，请解除文档限制后重新打开。",
                "The editor opened read-only and could not safely switch to edit. Retry, or remove the document restriction and reopen."))
            return
        }
        engineSessionReadOnly = false
        readOnly = false
        editUnavailableReason = nil
        #endif
    }

    #if canImport(FloeOfficeNative)
    /// Runs the host's guarded mobile edit entry. `readOnly` is the engine's
    /// own state after the attempt; a pending edit password (error 42) is a
    /// challenge, not a denial. A session the host mounted read-only refuses
    /// (error 41) and stays read-only.
    private static func enterEditMode(_ native: FloeOfficeNativeViewController) async -> (readOnly: Bool, pendingPassword: Bool) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Bool), Never>) in
            native.enterEditMode { readOnly, error in
                let pendingPassword = (error as NSError?)?.code == 42
                continuation.resume(returning: (readOnly, pendingPassword))
            }
        }
    }
    #endif

    private struct PermissionProbe {
        let backendReadOnly: Bool?
        let permission: String?
        let isEditMode: Bool?
        let isReadOnlyMode: Bool?
        let shouldStartReadOnly: Bool?
        let documentProtected: Bool?

        /// No engine state at all (map missing, surface changed, JS error).
        /// Unknown is never treated as writable; the caller attempts the
        /// engine's guarded entry and re-probes before deciding.
        var isKnown: Bool {
            backendReadOnly != nil || permission != nil || isEditMode != nil || isReadOnlyMode != nil
        }

        var isReadOnly: Bool {
            if documentProtected == true { return true }
            if !isKnown { return true }
            // The backing permission is authoritative. The mobile editor's
            // viewing-first UI reports permission/isReadOnlyMode "readonly" for
            // editable documents too, so those fields alone are not denial.
            if backendReadOnly == true { return true }
            if backendReadOnly == nil, isReadOnlyMode == true { return true }
            if backendReadOnly == nil, permission == "readonly" { return true }
            return false
        }
    }

    private static func permissionProbe(_ webView: WKWebView) async -> PermissionProbe {
        let raw = try? await webView.evaluateJavaScript(OfficeExplicitSaveBridge.permissionProbeScript)
        guard let result = raw as? [String: Any] else {
            return PermissionProbe(backendReadOnly: nil, permission: nil, isEditMode: nil, isReadOnlyMode: nil,
                                   shouldStartReadOnly: nil, documentProtected: nil)
        }
        return PermissionProbe(
            backendReadOnly: result["backendReadOnly"] as? Bool,
            permission: result["permission"] as? String,
            isEditMode: result["isEditMode"] as? Bool,
            isReadOnlyMode: result["readOnlyMode"] as? Bool,
            shouldStartReadOnly: result["shouldStartReadOnly"] as? Bool,
            documentProtected: result["documentProtected"] as? Bool
        )
    }

    /// Returns to the read-only preview controller with an honest reason. The
    /// working copy is preserved; nothing is discarded or faked.
    private func fallBackToPreview(reason: String) async throws {
        readOnly = true
        editUnavailableReason = reason
        try await closeController()
        try await activate(readOnly: true)
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
            // Bounded: a save that neither acknowledges nor fails in time
            // surfaces a recoverable error instead of an endless "Saving…".
            try await Self.saveWorkingCopy(native)
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
            // Every owning surface refreshes its sibling entries after a
            // verified original-file commit (and only then).
            onCommitted?()
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
            // Bounded so a share/save-copy flush can never strand on "Saving…".
            try await Self.saveWorkingCopy(native)
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

    /// Immutable snapshot for the system share sheet. Unlike
    /// `prepareSaveCopy` a read-only preview may share too: its working copy
    /// holds exactly the last committed bytes, so the shared file is truthful
    /// in both modes. An editable session flushes the engine first so the
    /// shared copy includes every accepted edit. The original file is never
    /// handed out or mutated, and the snapshot is reclaimed by
    /// `finishSaveCopy()` when the sheet dismisses.
    func prepareShareCopy() async -> DocumentExportSnapshot? {
        guard canAct, exportSnapshot == nil, let workspace, let session else { return nil }
        operating = true
        defer { finishOperation() }
        phase = .saving
        error = nil
        do {
            #if canImport(FloeOfficeNative)
            if !readOnly, let native = controller as? FloeOfficeNativeViewController {
                native.view.isUserInteractionEnabled = false
                defer { native.view.isUserInteractionEnabled = true }
                // Bounded so a share flush can never strand on "Saving…".
                try await Self.saveWorkingCopy(native)
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
                // Bounded so a persist-and-leave can never strand on "Saving…".
                try await Self.saveWorkingCopy(native)
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
        // Terminal from here on: a queued/replayed intent must never re-open
        // a working copy on this session.
        released = true
        guard !operating else { releaseRequested = true; return }
        // Defensive: a queued intent can never run against a released session,
        // and its waiter must be resumed instead of hanging.
        if let token = intentQueue.cancelPending() {
            intentWaiters.removeValue(forKey: token)?.resume(returning: false)
        }
        operating = true
        defer { finishOperation() }
        do { try await releaseCurrent(); phase = .idle }
        catch { fail(error) }
    }

    func retryPreview() async {
        guard readOnly else { return }
        if session == nil, controller == nil, phase == .failed {
            // The open failed before a working copy ever existed. Drop back to
            // `.idle` so the owning surface's loader re-arms and retries the
            // open, rather than requiring a document that was never created.
            phase = .idle
            error = nil
            return
        }
        await previewCurrent()
    }

    /// Functional recovery for a failed session. A failed open/save/close can
    /// leave a dead or wedged native controller on a retained working copy:
    /// an engine close that timed out, an open watchdog timeout, or a runtime
    /// failure. The retained working copy is the user's data — never deleted
    /// here. Recovery tears the dead controller down (bounded, detached from
    /// the engine's unsettled state) and re-activates a fresh preview of the
    /// same working copy so unsaved content is visible again and the user can
    /// save, keep, or discard it through the normal actions. When the session
    /// itself is gone (open failed before a working copy existed) this simply
    /// re-arms the owning loader, exactly like `retryPreview()`.
    @discardableResult
    func recoverFailedSession() async -> Bool {
        guard phase == .failed else { return false }
        if session == nil, controller == nil {
            phase = .idle
            error = nil
            return true
        }
        guard !operating else { return false }
        operating = true
        defer { finishOperation() }
        runtimeFailed = false
        error = nil
        do {
            // closeController() is bounded and never blocks on the wedged
            // engine: an unacknowledged native close settles at its timeout
            // and frees this surface regardless.
            try await closeController()
            guard let session, let workspace else {
                phase = .idle
                return true
            }
            // Refresh the uncommitted marker from the actual working copy so
            // the recovered surface never claims a clean state it cannot
            // prove (a timed-out save may have written the copy without a
            // receipt).
            hasUncommittedChanges = (try? await workspace.hasUncommittedWorkingCopy(session)) ?? true
            readOnly = true
            editUnavailableReason = nil
            try await activate(readOnly: true)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    /// True when the failed state is recoverable at all: either a retained
    /// working copy exists (editable or preview failure), or the open failed
    /// before any copy existed and the owning loader can simply re-arm.
    var canRecoverFailedSession: Bool { phase == .failed }

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
            // Release owns the session from here: a queued intent can never
            // run, and its waiter must be resumed instead of hanging.
            if let token = intentQueue.cancelPending() {
                intentWaiters.removeValue(forKey: token)?.resume(returning: false)
            }
            Task { await release() }
            return
        }
        guard let next = intentQueue.takePending() else { return }
        // Replay the queued intent now that the owning operation settled.
        // The task re-checks `operating` before running so a newer operation
        // that started in the same turn can never run concurrently with it.
        Task { @MainActor in
            if self.operating {
                self.intentQueue.restoreIfEmpty(intent: next.intent, token: next.token)
                return
            }
            let result = await self.execute(next.intent)
            self.intentWaiters.removeValue(forKey: next.token)?.resume(returning: result)
        }
    }
    private func releaseCurrent() async throws {
        try await closeController()
        if let session, let workspace { await workspace.close(session) }
        session = nil
        workspace = nil
    }
    #if canImport(FloeOfficeNative)
    /// Runs `nativeOperation`, returning when its receipt settles or throwing
    /// at `timeout` — whichever happens first. Modeled on `closeWorkingCopy`:
    /// a one-shot receipt is resolved by either the native callback or the
    /// deadline, so the caller returns at the deadline even when the native
    /// callback never fires (a task group would keep waiting on it).
    private static func withNativeDeadline(
        _ timeout: TimeInterval,
        timeoutError: @escaping @autoclosure () -> NSError,
        _ nativeOperation: (@escaping (Result<Void, Error>) -> Void) -> Void
    ) async throws {
        let receipt = OfficeSaveReceipt()
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
            receipt.resolve(.failure(timeoutError()))
        }
        nativeOperation { result in
            receipt.resolve(result)
        }
        do {
            try await receipt.wait()
            timeoutTask.cancel()
        } catch {
            timeoutTask.cancel()
            throw error
        }
    }

    /// Bounds the native-runtime readiness wait. The runtime must become ready
    /// or fail within a limited window. Previously this wait was unbounded and
    /// the open watchdog was only armed *after* it returned, so a runtime that
    /// neither readied nor failed left the surface loading indefinitely.
    private static func prepareNativeRuntime(timeout: TimeInterval = 30) async throws {
        try await withNativeDeadline(
            timeout,
            timeoutError: NSError(domain: "org.floeagent.office.runtime", code: 1, userInfo: [
                NSLocalizedDescriptionKey: OfficeInkText.t(
                    "文档引擎未能在限定时间内启动；编辑副本已保留。请稍后重试，若仍失败请重启应用。",
                    "The document engine did not start in time. Your edits were retained. Retry shortly, or restart the app if it keeps failing.")
            ])
        ) { completion in
            FloeOfficeNativeRuntime.shared.prepare { error in
                completion(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    /// Bounds a native working-copy save. The pinned host's receipt normally
    /// settles in seconds; a save that neither acknowledges nor fails within
    /// the window surfaces a bounded, recoverable error instead of leaving the
    /// editor on "正在保存…". The original file is untouched on a timeout, the
    /// working copy is retained, and a later save can retry.
    private static func saveWorkingCopy(_ native: FloeOfficeNativeViewController,
                                        timeout: TimeInterval = 30) async throws {
        try await withNativeDeadline(
            timeout,
            timeoutError: NSError(domain: "org.floeagent.office.save", code: 1, userInfo: [
                NSLocalizedDescriptionKey: OfficeInkText.t(
                    "文档保存未能在限定时间内完成；编辑副本已保留，请重试。",
                    "The document did not finish saving in time. Your edits were retained; please retry.")
            ])
        ) { completion in
            native.saveWorkingCopy { error in
                completion(error.map { .failure($0) } ?? .success(()))
            }
        }
    }
    #endif

    private func activate(readOnly: Bool) async throws {
        guard let session else { throw CocoaError(.fileReadUnknown) }
        self.readOnly = readOnly
        drawingMode = false
        invalidateInkApply()
        inkError = nil
        phase = .loading
        error = nil
        #if canImport(FloeOfficeNative)
        try await Self.prepareNativeRuntime()
        let native = try FloeOfficeNativeViewController(
            workingFileURL: session.workingURL,
            sessionDirectory: session.workingURL.deletingLastPathComponent(), readOnly: readOnly)
        runtimeFailed = false
        engineSessionReadOnly = nil
        resolveEnginePermission(nil)
        startOpenWatchdog(for: native, readOnly: readOnly)
        // Readiness is claimed from the permission callback, not the raw
        // working-copy event: the host verifies the engine's actual backing
        // permission (and follows the guarded edit entry for an editable
        // session) before it reports. The plain open event only reports a hard
        // failure here.
        native.onWorkingCopyOpened = { [weak self, weak native] success in
            guard let self, let native, self.controller === native, !self.runtimeFailed else { return }
            if !success {
                self.cancelOpenWatchdog()
                self.resolveEnginePermission(nil)
                self.fail(CocoaError(.fileReadCorruptFile))
            }
        }
        native.onWorkingCopyOpenedWithPermission = { [weak self, weak native] success, readOnly in
            guard let self, let native, self.controller === native, !self.runtimeFailed else { return }
            self.cancelOpenWatchdog()
            self.engineSessionReadOnly = readOnly
            self.resolveEnginePermission(readOnly)
            if !success {
                self.fail(CocoaError(.fileReadCorruptFile))
                return
            }
            if readOnly, !native.isReadOnly {
                // The App asked for an editable session but the engine kept
                // the document read-only (protected format, mounted grant or
                // an edit password still pending). Never show an editable
                // claim; keep the engine's actual surface and offer retry.
                self.readOnly = true
                if self.editUnavailableReason == nil {
                    self.editUnavailableReason = OfficeInkText.t(
                        "编辑器以只读模式打开，无法安全进入编辑。可重试；若仍只读，请解除文档限制后重新打开。",
                        "The editor opened read-only and could not safely switch to edit. Retry, or remove the document restriction and reopen.")
                }
            } else if !readOnly, self.readOnly, !native.isReadOnly {
                // The engine granted editing later (for example the edit
                // password was supplied): return to the truthful editable
                // state instead of keeping a stale read-only claim.
                self.readOnly = false
                self.editUnavailableReason = nil
            }
            self.phase = .ready
        }
        native.onEnginePermissionChanged = { [weak self, weak native] readOnly in
            guard let self, let native, self.controller === native else { return }
            self.engineSessionReadOnly = readOnly
            self.resolveEnginePermission(readOnly)
            if !readOnly, !native.isReadOnly, self.readOnly {
                self.readOnly = false
                self.editUnavailableReason = nil
            }
        }
        native.onClosed = { [weak self, weak native] _ in
            guard let self, let native, self.controller === native, !self.expectedClose else { return }
            self.runtimeFailed = true
            self.error = OfficeInkText.t(
                "文档已被文档引擎关闭；编辑副本已保留，可在“保留的文档”中恢复。",
                "The document engine closed the document. Your editing copies were retained and can be recovered under Retained Documents.")
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
        cancelOpenWatchdog()
        resolveEnginePermission(nil)
        // No view means the upstream viewWillAppear has not opened a document.
        // Do not load a WebView merely to close an abandoned preview request.
        guard controller.isViewLoaded else {
            invalidateInkApply()
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
            let result = await Self.closeWorkingCopy(native, timeout: 8)
            switch result {
            case .acknowledged(let message):
                // Free the surface before reporting so a failed engine close
                // cannot keep a dead editor on screen.
                invalidateInkApply()
                explicitSaveBridge?.invalidate()
                explicitSaveBridge = nil
                self.controller = nil
                if let message {
                    throw NSError(domain: "org.floeagent.office.close", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: message
                    ])
                }
                return
            case .timedOut:
                // The engine did not settle within the bound. Nothing was
                // written back or deleted; its private copies stay on disk.
                // Release this surface so the UI can never sit on 正在关闭
                // forever, and report the unsettled close honestly.
                invalidateInkApply()
                explicitSaveBridge?.invalidate()
                explicitSaveBridge = nil
                self.controller = nil
                throw NSError(domain: "org.floeagent.office.close", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: OfficeInkText.t(
                        "文档引擎未在限定时间内完成关闭；编辑副本已保留，请重试。",
                        "The document engine did not finish closing in time. Your document copies were retained; please retry.")
                ])
            }
        }
        #endif
        invalidateInkApply()
        explicitSaveBridge?.invalidate()
        explicitSaveBridge = nil
        self.controller = nil
    }

    fileprivate enum OfficeCloseResult {
        /// The engine reported a result; the associated value is an error
        /// message when the close failed, nil when it succeeded.
        case acknowledged(String?)
        case timedOut
    }

    #if canImport(FloeOfficeNative)
    /// Bounded native close. The pinned host settles the UIDocument and calls
    /// back; a host that never calls back must not strand the session.
    private static func closeWorkingCopy(_ native: FloeOfficeNativeViewController,
                                         timeout: TimeInterval) async -> OfficeCloseResult {
        let ack = OfficeCloseAck()
        Task { @MainActor in
            native.closeWorkingCopy { error in
                ack.resolve(error.map { .acknowledged($0.localizedDescription) } ?? .acknowledged(nil))
            }
        }
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            ack.resolve(.timedOut)
        }
        let result = await ack.wait()
        timeoutTask.cancel()
        return result
    }
    #endif
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
                    Label(OfficeInkText.t("无法打开文档", "Document Unavailable"), systemImage: "doc.badge.ellipsis")
                } description: { Text(session.error ?? OfficeInkText.t("请稍后重试。", "Please try again.")) } actions: {
                    if session.canRecoverFailedSession {
                        // Functional recovery, not a reworded retry: tears down
                        // the wedged/dead controller (bounded), keeps the
                        // retained working copy, and re-opens a truthful
                        // preview of it so unsaved edits stay reachable.
                        Button(OfficeInkText.t("恢复文档", "Recover Document")) {
                            Task { _ = await session.recoverFailedSession() }
                        }
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

/// Standalone full-screen Office editor host for the workspace preview's
/// "Edit in Office" expansion. The preview releases its own session before
/// presenting; this host opens a fresh one against the already-resolved
/// document URL, and dismisses itself through the shared editor's own save /
/// unsaved-exit flow. Exactly one live working copy exists per document.
struct OfficeStandaloneEditorHost: View {
    let relativePath: String
    let documentURL: URL
    @ObservedObject var session: OfficeFileSession

    var body: some View {
        NavigationStack {
            OfficeDocumentEditorView(
                relativePath: relativePath,
                session: session,
                onSaved: nil,
                onClose: nil
            )
        }
        .task {
            // Opening while the editor's queued edit intent is pending is the
            // designed path: the intent replays once the working copy exists.
            await session.open(documentURL)
        }
    }
}

struct OfficeDocumentEditorView: View {
    let relativePath: String
    @ObservedObject var session: OfficeFileSession
    /// Set by `FilePreviewView` for a cloud/network document and by Notes for
    /// its generated Office documents, whose staged copies get fresh paths on
    /// every open; nil for local Office documents, which keep their
    /// physical-URL ink identity.
    var stableInkIdentity: OfficeInkDocumentIdentity? = nil
    var onSaved: (() async -> Bool)?
    var onClose: (() -> Void)? = nil
    /// A feature-owned tab strip replaces the standalone navigation title.
    var inlineHeader: AnyView? = nil
    /// When false the owning surface owns the first intent: Notes opens a
    /// remembered read-only preview and only enters editing from the App
    /// toolbar's Edit action; the fullscreen editor requests editing
    /// explicitly once its local open has settled. Editing is the default
    /// everywhere else, where mounting this surface is already an explicit
    /// edit action.
    var requestsEditingOnAppear: Bool = true
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @State private var confirmingDiscard = false
    @State private var confirmingClose = false
    @State private var comparingVersions = false
    @State private var convertedExport: OfficeConvertedExport?
    @State private var export: DocumentExportSnapshot?
    @State private var savedCopyNotice = false
    @State private var exportSucceeded = false
    @State private var choosingAttachment = false
    @State private var choosingWorkspaceAttachment = false
    @State private var showingAttachments = false
    @State private var showingInkControls = false
    @State private var attachmentError: String?
    /// In-flight share snapshot; reclaimed by `finishSaveCopy()` on dismiss.
    @State private var shareSnapshot: DocumentExportSnapshot?

    var body: some View {
        OfficeDocumentSurface(session: session)
            .navigationTitle((relativePath as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .background {
                // Command-S saves in place against the original workspace
                // file (same verified commit as the engine's own toolbar
                // save) without dismissing the editor. Hidden from the UI;
                // only the keyboard shortcut is exposed.
                Button {
                    Task { _ = await session.saveInPlace() }
                } label: { EmptyView() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(session.readOnly || !session.canAct)
                .accessibilityIdentifier("office.editor.saveInPlace")
                .hidden()
            }
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
            .task {
                session.useInkPreferences(
                    stableIdentity: stableInkIdentity,
                    workspaceIdentity: environment.workspaceCenter.currentWorkspace?.id.uuidString,
                    documentKey: relativePath)
                // Queued intent: a tap that lands while the document is still
                // opening is replayed instead of being dropped by `operating`.
                if requestsEditingOnAppear { await session.requestEditing() }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let reason = session.editUnavailableReason {
                    // Informational only: the edit entry lives in the App's top
                    // toolbar, not in a floating control over the document.
                    HStack(spacing: 10) {
                        Label(reason, systemImage: "lock")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.bar)
                    .accessibilityIdentifier("office.editor.readonlyReason")
                } else if session.isRemoteSnapshot {
                    // A cloud/network snapshot is preview-only until a real
                    // remote write-back exists; say so next to the document
                    // instead of offering edit affordances that would only
                    // touch the temporary copy.
                    HStack(spacing: 10) {
                        Label(OfficeFileSession.remoteSnapshotHint, systemImage: "icloud.and.arrow.down")
                            .font(.footnote).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.bar)
                    .accessibilityIdentifier("office.editor.remoteSnapshotHint")
                }
            }
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
            .sheet(item: $shareSnapshot, onDismiss: {
                Task { await session.finishSaveCopy() }
            }) { snapshot in
                OfficeDocumentShareSheet(url: snapshot.fileURL)
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
            .confirmationDialog("关闭前保存修改？", isPresented: $confirmingClose, titleVisibility: .visible) {
                Button("保存并关闭") {
                    Task { await saveAndDismiss() }
                }
                Button("放弃修改", role: .destructive) {
                    Task { if await session.discardAndReturn() { dismissEditor() } }
                }
                Button("取消", role: .cancel) {}
            } message: { Text("保存会通过共享保存流程写回原文件；放弃会删除编辑副本。") }
    }

    private var backButton: some View {
        Button("返回", systemImage: "chevron.left") {
            if session.phase == .failed { dismissEditor() }
            else if ownsStandaloneExit {
                // Save/discard/cancel instead of an implicit save: every
                // format (DOCX/XLSX/PPTX) reaches the same shared save
                // service, and the engine's modified flag decides whether the
                // prompt is needed at all.
                Task {
                    if await session.hasLocalEditsToProtect() { confirmingClose = true }
                    else { await saveAndDismiss() }
                }
            } else {
                Task { await saveAndDismiss() }
            }
        }
        .labelStyle(.iconOnly).frame(width: 44, height: 44)
        .disabled(!session.canAct && session.phase != .failed)
        .accessibilityIdentifier("office.editor.back")
        .accessibilityHint(session.phase == .failed ? "保留编辑副本并关闭" : "保存文档并返回预览")
    }

    /// The fully standalone workspace-preview editor owns its exit decision;
    /// feature-owned hosts (Notes, IDE) keep their own leave guards.
    private var ownsStandaloneExit: Bool { onSaved == nil && onClose == nil }

    /// The App owns the edit entry: a preview exposes one clear host-level
    /// Edit action in its own top chrome on every size class (never a floating
    /// engine button over the document). A cloud/network snapshot never
    /// exposes Edit at all: there is no real remote write-back, so editing
    /// could only change the temp copy.
    @ViewBuilder private var editAction: some View {
        if session.readOnly, session.phase == .ready, !session.isRemoteSnapshot {
            Button {
                Task { _ = await session.requestEditing() }
            } label: {
                Label(OfficeInkText.t("编辑", "Edit"), systemImage: "square.and.pencil")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!session.canAct)
            .accessibilityIdentifier("office.preview.edit")
        }
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
                showingInkControls = true
            } label: {
                Label(OfficeInkText.t("画笔批注", "Annotate"), systemImage: "pencil.tip")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!session.canAct && !session.drawingMode)
            .accessibilityIdentifier("office.drawing.toggle")
            .popover(isPresented: $showingInkControls, arrowEdge: .top) {
                OfficeInkControlPanel(session: session, ink: session.inkPreferences)
                    .presentationCompactAdaptation(.popover)
            }
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
            // A remote snapshot is read-only: nothing can be "saved back", so
            // the save/discard entries stay hidden. Export, save-copy and
            // share remain — those download truthfully to local files.
            if !session.isRemoteSnapshot {
                Button("保存并返回") { Task { await saveAndDismiss() } }
            }
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
            // Explicit share of the current document from every Office
            // surface (preview and edit): a verified snapshot copy goes to the
            // system share sheet; the original file is never handed out.
            Button(OfficeInkText.t("分享…", "Share…"), systemImage: "square.and.arrow.up") {
                Task { shareSnapshot = await session.prepareShareCopy() }
            }
            .accessibilityIdentifier("office.editor.share")
            if onSaved == nil, !session.isRemoteSnapshot {
                Button("保留修改并返回") {
                    Task { if await session.keepChangesAndReturn() { dismissEditor() } }
                }
            }
            if !session.isRemoteSnapshot {
                Button("放弃修改", role: .destructive) { confirmingDiscard = true }
            }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .disabled(!session.canAct)
            .accessibilityLabel("文档操作")
    }

    private var documentActions: some View {
        HStack(spacing: 4) {
            // The preview's single primary action stays visible on compact
            // layouts too; the remaining edit-mode actions keep their existing
            // compact menu placement.
            editAction
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

/// System share sheet for a verified Office snapshot copy. Shared by the
/// editor surface and the IDE's embedded Office action bar; the owning
/// session reclaims the snapshot when the sheet dismisses.
struct OfficeDocumentShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
private struct OfficeConvertedExportShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Compact app-owned pen panel. It only edits Floe's typed stroke settings and
/// starts/stops the engine's own editable freehand tool; it never draws a
/// screen-space overlay and never writes Notes/Canvas ink.
private struct OfficeInkControlPanel: View {
    @ObservedObject var session: OfficeFileSession
    let ink: OfficeInkPreferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button {
                    Task {
                        do { try await session.toggleDrawing() }
                        catch { session.inkError = error.localizedDescription }
                    }
                } label: {
                    Label(session.drawingMode
                          ? OfficeInkText.t("结束批注", "End annotations")
                          : OfficeInkText.t("开始批注", "Start annotations"),
                          systemImage: session.drawingMode ? "pencil.tip.crop.circle.badge.minus" : "pencil.tip")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canAct)
                .accessibilityIdentifier("office.ink.startStop")

                VStack(alignment: .leading, spacing: 8) {
                    Text(OfficeInkText.t("颜色", "Color")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        ForEach(OfficeInkColor.allCases) { color in
                            Button {
                                ink.setColor(color)
                                reapply()
                            } label: {
                                Circle()
                                    .fill(color.swatch)
                                    .frame(width: 28, height: 28)
                                    .overlay(Circle().strokeBorder(
                                        ink.color == color ? Color.accentColor : Color.secondary.opacity(0.35),
                                        lineWidth: ink.color == color ? 2.5 : 1))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(color.title)
                            .accessibilityAddTraits(ink.color == color ? .isSelected : [])
                            .accessibilityIdentifier("office.ink.color.\(color.rawValue)")
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(OfficeInkText.t("线宽", "Width")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text(String(format: "%.2f mm", ink.stroke.widthMillimeters))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    // Presets own a real 44pt tap target on their own row so
                    // `.controlSize(.small)` cannot shrink the hit area and the
                    // slider still gets the full 330pt panel width on compact
                    // screens. The frame is on the button's label, not outside
                    // the button, so the whole 44pt region is tappable.
                    HStack(spacing: 8) {
                        ForEach(OfficeInkWidthPreset.allCases) { preset in
                            Button {
                                ink.setWidthMillimeters(preset.rawValue)
                                reapply()
                            } label: {
                                Text(preset.title)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.bordered)
                            .tint(abs(ink.stroke.widthMillimeters - preset.rawValue) < 0.01 ? Color.accentColor : Color.gray)
                            .accessibilityIdentifier("office.ink.widthPreset.\(preset.title)")
                        }
                    }
                    Slider(value: Binding(get: { ink.stroke.widthMillimeters },
                                          set: { ink.setWidthMillimeters($0) }),
                           in: OfficeInkStroke.widthRange, step: 0.25,
                           onEditingChanged: { editing in if !editing { reapply() } })
                        .accessibilityIdentifier("office.ink.width")
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(OfficeInkText.t("透明度", "Transparency")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Text(ink.stroke.transparencyPercent == 0
                             ? OfficeInkText.t("0%（实心）", "0% (solid)")
                             : "\(ink.stroke.transparencyPercent)%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(ink.stroke.transparencyPercent) },
                        set: { ink.setTransparencyPercent(Int($0.rounded())) }),
                           in: 0...100, step: 1,
                           onEditingChanged: { editing in if !editing { reapply() } })
                        .accessibilityIdentifier("office.ink.transparency")
                    Text(OfficeInkText.t("0% 为实心，数值越大越透明",
                                         "0% is solid; higher values are more transparent"))
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if let inkError = session.inkError {
                    Label(inkError, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("office.ink.error")
                } else if session.drawingMode, let outcome = session.inkApplyOutcome {
                    Label(outcome == .verified
                          ? OfficeInkText.t("画笔设置已确认", "Pen settings confirmed")
                          : OfficeInkText.t("设置已发送，尚未确认生效", "Settings sent; awaiting confirmation"),
                          systemImage: outcome == .verified ? "checkmark.circle" : "clock")
                        .font(.caption2).foregroundStyle(.secondary)
                        .accessibilityIdentifier("office.ink.outcome")
                }
            }
            .padding(16)
        }
        .frame(idealWidth: 330, maxWidth: 330, idealHeight: 420, maxHeight: 420)
    }

    private func reapply() {
        guard session.drawingMode else { return }
        Task { await session.applyInkPreferences() }
    }
}
#endif
