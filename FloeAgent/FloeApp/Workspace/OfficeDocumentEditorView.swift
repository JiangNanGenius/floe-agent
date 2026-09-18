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
        if enabled { await applyInkPreferences() } else { inkApplyOutcome = nil; inkError = nil }
    }

    /// Points the current document's stroke preferences at the given workspace
    /// document. Call before editing starts; settings persist per document and
    /// never read or write Canvas/Notes ink. The workspace identity keeps two
    /// same-named files in different workspaces separate while the digest keeps
    /// the raw path out of `UserDefaults`.
    ///
    /// `stableIdentity` is only supplied by `FilePreviewView` for a cloud or
    /// network file, whose local editing URL is a fresh preview copy each load.
    /// Local Office documents and Notes pass nil, so their persisted settings
    /// keep following the stable `session.originalURL` physical path and can
    /// never be rebound to a transient workspace id.
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
        // An explicit open starts a new lifecycle: views such as
        // FilePreviewView release on disappear and reopen on appear.
        released = false
        requestedURL = url
        await performIntent(.preview)
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
        // arrives while the open owns the session is queued by performIntent.
        guard session != nil else { return false }
        if !readOnly, controller != nil, phase == .ready { return true }
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
        } catch { fail(error); return false }
    }

    /// Reads the pinned engine's real permission after an edit activation and
    /// attempts the engine's own mobile edit switch when it still reports
    /// readonly. A protected document or a switch the engine refuses returns
    /// to the preview controller with an explicit reason — the session never
    /// pretends to be writable.
    private func acknowledgeEditPermission() async throws {
        #if canImport(FloeOfficeNative)
        guard let native = controller as? FloeOfficeNativeViewController, native.isViewLoaded,
              let webView = OfficeExplicitSaveBridge.findWebView(in: native.view) else { return }
        var probe = await Self.permissionProbe(webView)
        if probe.documentProtected {
            try await fallBackToPreview(reason: OfficeInkText.t(
                "该文档受保护，只能预览；未修改任何内容。",
                "This document is protected. Preview only; nothing was changed."))
            return
        }
        // The host reports the engine's verified backing permission; the JS
        // probe is the fallback surface. An unverified (nil/unknown) state is
        // never read as an editable grant.
        var hostReadOnly = engineSessionReadOnly
        if hostReadOnly == true || probe.isReadOnly {
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
            hostReadOnly = entry.readOnly
            for _ in 0..<10 {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: 150_000_000)
                probe = await Self.permissionProbe(webView)
                if let reported = engineSessionReadOnly { hostReadOnly = reported }
                if hostReadOnly == false { break }
            }
        }
        // Only a verified state clears preview: the host's engine-truth report
        // first, then a known engine probe. Unknown is never editable.
        let verifiedEditable = hostReadOnly == false
            || (hostReadOnly == nil && probe.isKnown && !probe.isReadOnly)
        if !verifiedEditable {
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
    private func activate(readOnly: Bool) async throws {
        guard let session else { throw CocoaError(.fileReadUnknown) }
        self.readOnly = readOnly
        drawingMode = false
        invalidateInkApply()
        inkError = nil
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
        engineSessionReadOnly = nil
        // Readiness is claimed from the permission callback, not the raw
        // working-copy event: the host verifies the engine's actual backing
        // permission (and follows the guarded edit entry for an editable
        // session) before it reports. The plain open event only reports a hard
        // failure here.
        native.onWorkingCopyOpened = { [weak self, weak native] success in
            guard let self, let native, self.controller === native, !self.runtimeFailed else { return }
            if !success { self.fail(CocoaError(.fileCorruptFile)) }
        }
        native.onWorkingCopyOpenedWithPermission = { [weak self, weak native] success, readOnly in
            guard let self, let native, self.controller === native, !self.runtimeFailed else { return }
            self.engineSessionReadOnly = readOnly
            if !success {
                self.fail(CocoaError(.fileCorruptFile))
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
            if !readOnly, !native.isReadOnly, self.readOnly {
                self.readOnly = false
                self.editUnavailableReason = nil
            }
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
        invalidateInkApply()
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
    /// Set by `FilePreviewView` only for a cloud/network document; nil for
    /// local Office and Notes so they keep their physical-URL ink identity.
    var stableInkIdentity: OfficeInkDocumentIdentity? = nil
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
    @State private var showingInkControls = false
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
            .task {
                session.useInkPreferences(
                    stableIdentity: stableInkIdentity,
                    workspaceIdentity: environment.workspaceCenter.currentWorkspace?.id.uuidString,
                    documentKey: relativePath)
                // Queued intent: a tap that lands while the document is still
                // opening is replayed instead of being dropped by `operating`.
                await session.requestEditing()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let reason = session.editUnavailableReason {
                    HStack(spacing: 10) {
                        Label(reason, systemImage: "lock")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if session.phase == .ready {
                            Button(OfficeInkText.t("重试编辑", "Retry editing")) {
                                Task { await session.requestEditing() }
                            }
                            .font(.footnote)
                            .accessibilityIdentifier("office.editor.retryEdit")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.bar)
                    .accessibilityIdentifier("office.editor.readonlyReason")
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
