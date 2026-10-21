// FloeApp — shared native Office preview and fullscreen editing session.
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import Combine
import WebKit
import FloeDocuments
import FloeCore
import FloeTools
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
                // Defensive only: this acknowledgement admits one waiter. A
                // second concurrent wait must never orphan the earlier
                // continuation — the exact wedge a lost close callback could
                // otherwise leave behind — so the stale waiter is settled
                // with the bounded outcome and the new wait continues.
                if let stale = self.continuation {
                    stale.resume(returning: .timedOut)
                }
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

/// One-shot, main-queue acknowledgement that bounds the host's guarded mobile
/// edit entry. The first resolver (host callback or timeout) wins. A host that
/// never calls back reads as unverified-read-only so the caller's re-probe and
/// fallback decide from the engine's real state — a lost native completion can
/// never wedge the edit acknowledgement and leave `operating` stuck (which
/// would refuse every later recovery).
@MainActor
final class OfficeEditEntryAck {
    private var continuation: CheckedContinuation<(readOnly: Bool, pendingPassword: Bool), Never>?
    private var settledResult: (readOnly: Bool, pendingPassword: Bool)?

    func wait() async -> (readOnly: Bool, pendingPassword: Bool) {
        if let settledResult { return settledResult }
        return await withCheckedContinuation { continuation in
            if let settledResult {
                continuation.resume(returning: settledResult)
            } else {
                // Defensive only: this acknowledgement admits one waiter. A
                // second concurrent wait must never orphan the earlier
                // continuation — the same wedge the close and save receipts
                // already defend against — so a stale waiter settles as
                // unverified-read-only (the conservative outcome, never an
                // editing grant) and the new wait continues.
                if let stale = self.continuation {
                    stale.resume(returning: (readOnly: true, pendingPassword: false))
                }
                self.continuation = continuation
            }
        }
    }

    func resolve(_ result: (readOnly: Bool, pendingPassword: Bool)) {
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
            // The settled result is replayed verbatim, never consumed and
            // never degraded to a fabricated success: every caller observes
            // the one real outcome (a timeout failure keeps failing late
            // waiters, so a bounded save can never read as an unverified
            // commit).
            switch settledResult ?? .success(()) {
            case .success: return
            case .failure(let error): throw error
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            // Defensive only: this receipt admits one waiter. A second
            // concurrent wait must never orphan the earlier continuation —
            // the wedge a lost engine receipt would otherwise leave behind —
            // so the stale waiter fails fast and the new wait continues.
            if let stale = self.continuation {
                stale.resume(throwing: CocoaError(.coderInvalidValue))
            }
            self.continuation = continuation
        }
    }

    /// Settles the receipt exactly once; later resolutions are ignored. The
    /// result is retained whether or not a waiter is attached, so a `wait()`
    /// that starts after the settle replays the real outcome.
    func resolve(_ result: Result<Void, Error>) {
        guard !settled else { return }
        settled = true
        settledResult = result
        if let continuation {
            self.continuation = nil
            continuation.resume(with: result)
        }
    }
}

// FLOE_VISIBLE_RENDER_GATE_BEGIN
/// How a document's readiness is proven. Presentations start in the engine's
/// file-based view (endless slide scrolling / slide sorter), where page
/// skeletons are painted before any document tile arrives, so `docloaded`, an
/// open event, a sized canvas and the engine's backing permission are not proof
/// of a rendered document. Those formats require the host's visible-render
/// signal; Word/Excel keep their existing open-only contract.
enum OfficeRenderRequirement: Equatable {
    case visibleRenderRequired
    case openOnly

    /// Mirrors `FloeDocumentRequiresVisibleRender` in
    /// `FloeAgent/ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm`;
    /// `office_render_readiness.py` asserts both lists stay identical.
    static let renderRequiredExtensions: Set<String> = [
        "ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx",
        "odp", "otp", "fodp", "odg", "otg", "fodg",
    ]

    static func forDocument(pathExtension: String) -> OfficeRenderRequirement {
        renderRequiredExtensions.contains(pathExtension.lowercased()) ? .visibleRenderRequired : .openOnly
    }
}

/// Monotonic open generation for one Office session. Every `activate` advances
/// it; a native callback carries the generation it was installed for, so a
/// stale callback from a controller an earlier generation mounted can never
/// settle the current session — independently of the controller identity
/// check, which it backs with an explicit, testable generation rule.
struct OfficeOpenGeneration: Equatable {
    private(set) var current = 0

    @discardableResult
    mutating func advance() -> Int {
        current += 1
        return current
    }

    func isCurrent(_ generation: Int) -> Bool { generation == current }
}

/// Truthful readiness state machine for one mounted native session. The open
/// event, the engine permission and a save receipt never make a
/// `.visibleRenderRequired` session ready on their own: only the host's real
/// painted-surface signal does. A host that never reports it leaves the session
/// `.failed` (recoverable, working copy retained) instead of blank-but-ready.
struct OfficeVisibleRenderGate: Equatable {
    enum State: Equatable {
        case waitingForOpen
        case waitingForRender
        case ready
        case failed
    }

    let requirement: OfficeRenderRequirement
    private(set) var state: State = .waitingForOpen

    init(requirement: OfficeRenderRequirement) {
        self.requirement = requirement
    }

    /// The UIDocument open (and the engine permission report) settled.
    @discardableResult
    mutating func openSettled() -> State {
        if state == .waitingForOpen {
            state = requirement == .visibleRenderRequired ? .waitingForRender : .ready
        }
        return state
    }

    /// The host observed a decoded document tile on a sized document canvas.
    /// A real paint always wins, including over the bounded failure: the
    /// deadline outcome means "no paint yet", never "this surface can never
    /// paint", so a genuinely slow render repairs the session instead of
    /// staying failed (the same "a late observation always wins" contract
    /// `OfficeOpeningPolicy.renderObserved` documents).
    @discardableResult
    mutating func visibleRenderObserved() -> State {
        if state != .ready { state = .ready }
        return state
    }

    /// The bounded render deadline elapsed with no visible-render signal.
    @discardableResult
    mutating func deadlineExceeded() -> State {
        if state == .waitingForRender { state = .failed }
        return state
    }

    /// The host reported a bounded render failure.
    @discardableResult
    mutating func hostFailed() -> State {
        if state != .ready { state = .failed }
        return state
    }

    var isReady: Bool { state == .ready }
    var awaitsVisibleRender: Bool { state == .waitingForRender }
    var hasFailed: Bool { state == .failed }
    /// A save may only start from a settled, rendered session: this is the same
    /// condition `OfficeFileSession.canAct` enforces through `phase == .ready`,
    /// so a presentation that never painted cannot reach the save path (and the
    /// bounded failure keeps the editing copy for retry/recovery).
    var permitsSave: Bool { isReady }
}

@MainActor
enum OfficeRenderFailure {
    /// Actionable, bilingual copy for a presentation that never painted. It
    /// must state that the working copy was retained and offer recovery.
    static func noVisibleRender(readOnly: Bool) -> NSError {
        let description = readOnly
            ? OfficeInkText.t(
                "演示文稿未能在限定时间内完成渲染，未显示空白编辑界面；编辑副本已保留，可重试或从“保留的文档”恢复。",
                "The presentation did not finish rendering in time. Your editing copy was retained; retry, or recover it under Retained Documents.")
            : OfficeInkText.t(
                "编辑副本未能在限定时间内完成渲染；编辑副本已保留，可重试或恢复。",
                "The editing copy did not finish rendering in time. Your editing copy was retained; retry or recover it.")
        return NSError(domain: "org.floeagent.office.render", code: 1,
                       userInfo: [NSLocalizedDescriptionKey: description])
    }

    /// Build 233 R3: the editor's web content process died. The engine session
    /// cannot recover in place; this is a bounded, recoverable failure and the
    /// working copy stays on disk for retry/recovery. Never presented as a
    /// successful or still-ready editor.
    static func webContentProcessTerminated() -> NSError {
        let description = OfficeInkText.t(
            "文档渲染进程已停止；编辑副本已保留，可重试或稍后从“保留的文档”恢复。",
            "The document renderer stopped. Your editing copy was retained; retry now or recover it later under Retained Documents.")
        return NSError(domain: "org.floeagent.office.render", code: 2,
                       userInfo: [NSLocalizedDescriptionKey: description])
    }
}
// FLOE_VISIBLE_RENDER_GATE_END

@MainActor
final class OfficeFileSession: ObservableObject {
    enum Phase { case idle, loading, ready, insertingAttachment, readingAttachments, saving, closing, failed }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var controller: UIViewController?
    @Published private(set) var readOnly = true
    @Published private(set) var hasUncommittedChanges = false
    @Published var error: String?
    /// An actual native toolbar Print request for this mounted generation.
    /// The view observes the edge and presents the same options as Export PDF.
    @Published private(set) var printRequestGeneration = 0
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
    /// Snapshot of the pre-batch working copy, kept with the exact expected
    /// post-commit SHA. The pinned bundle has no undo-group command, so a
    /// whole-batch revert restores these bytes with a CAS instead of guessing
    /// an engine undo depth. Cleared when the document changes or closes.
    private var engineBatchSnapshotURL: URL?
    private var engineBatchCommittedSHA: String?
    private var engineBatchJournalID: String?
    /// True while a committed batch can still be reverted: the file SHA is the
    /// batch's committed SHA and no later edit/commit happened.
    @Published private(set) var canRevertLastEngineBatch = false
    /// Set when a failed command batch could not be proven restored; the
    /// working copy is quarantined and manual save refuses until the document
    /// is reloaded from the committed bytes or the edits are discarded.
    @Published private(set) var engineBatchRestoreFailed = false
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
    /// Build 233 R2: the owning surface installs this AppEnvironment-backed
    /// idle-model shed before the first intent. The implementation releases
    /// only a physically idle resident local model — never an active
    /// inference, a benchmark or a retained tool continuation — and answers
    /// nil without waiting when the mapping is claimed. A session without an
    /// installed shed (tests, qualification hosts) simply does nothing.
    var shedIdleLocalModelForOffice: (@MainActor (String) async -> String?)?
    /// Build 233 R1: owner-installed provider for the device font-library
    /// facts recorded beside the engine's own discovery numbers. Counts only;
    /// an import that happens after the engine cached its font list is the
    /// open refresh question this fact makes inspectable.
    var officeDeviceFontFacts: (@MainActor () async -> [String: String])?
    /// Build 233 R2: system memory-warning observation for this session. It
    /// only fires while an Office controller is mounted.
    private var memoryWarningObservation: AnyCancellable?
    /// Memory warnings observed for this session (diagnostics only).
    private var memoryWarningShedCount = 0
    private var explicitSaveBridge: OfficeExplicitSaveBridge?
    /// The one autosave owner coordinator for the CURRENT editable mounted
    /// generation. It is session-owned (never a transient SwiftUI task):
    /// created when an editable controller mounts and invalidated when that
    /// generation's controller closes or the session releases. Without an
    /// installed owner (IDE/workspace hosts, previews) it stays inert and the
    /// host's save behavior is bit-for-bit unchanged.
    private var autosaveCoordinator: OfficeAutosaveCoordinator?
    /// The document-bound owner transaction installed by the Notes surface;
    /// it survives a same-session remount so the new generation inherits it.
    private var autosaveOwner: OfficeAutosaveOwner?
    /// True when this mounted editable session has a Notes autosave owner:
    /// explicit saves then run the serialized flush -> draft -> Notes CAS
    /// promotion transaction instead of only flushing the engine copy.
    var autosaveActive: Bool { !readOnly && autosaveCoordinator?.hasOwner == true }

    func installAutosaveOwner(_ owner: OfficeAutosaveOwner?) {
        autosaveOwner = owner
        autosaveCoordinator?.installOwner(owner)
    }

    /// Serialized owner transaction entry for explicit triggers. A missing
    /// coordinator (preview or host-less generation) is a truthful refusal,
    /// never an implicit direct-save substitution by the caller's caller.
    func requestAutosaveTransaction(reason: String) async -> OfficeSavedProof {
        if let autosaveCoordinator {
            return await autosaveCoordinator.requestTransaction(reason: reason)
        }
        return OfficeSavedProof(outcome: .refused, reason: "autosave.coordinatorUnavailable",
                                documentID: autosaveOwner?.documentID, sessionGeneration: nil,
                                sessionCorrelationID: stageSessionID, revision: nil, resourceID: nil,
                                packageSHA256: nil, nativeFlushOccurred: false, changesPromoted: false,
                                dirtyAfterTransaction: nil, retryScheduled: false, error: nil)
    }

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
    /// Truthful readiness for this mounted document. A presentation is only
    /// ready once the host observed a decoded document tile on a sized canvas;
    /// the open event and the engine permission are not render evidence.
    private var renderGate: OfficeVisibleRenderGate?
    /// Actual document-action readiness, including the same-generation paint gate.
    var documentActionsReady: Bool { canAct && (renderGate?.permitsSave ?? false) }
    /// Bounded Swift-side safety net for a host that reports neither render
    /// outcome. It only fires while this session still awaits a render.
    private var renderWatchdog: Task<Void, Never>?
    /// Bounded, user-facing opening contract for the mounted session
    /// (`FloeDocuments.OfficeOpeningPolicy`). It owns the budgets the watchdogs
    /// use and the recoverable outcome a bounded presentation must reach.
    private var openingPolicy: OfficeOpeningPolicy?
    /// Set when a presentation settled without the host's visible-render
    /// evidence. The engine surface stays mounted and interactive and every
    /// owning surface shows a visible, recoverable notice with retry/recovery
    /// instead of an unbounded spinner or a dead-end error. A late render
    /// observation clears it.
    @Published private(set) var renderUnverified = false
    /// Set when the host's fenced visible-render callback observed a decoded
    /// document tile for the CURRENT open generation; cleared on every
    /// `activate`. Read-only cover backfills key off this exact signal
    /// instead of racing the engine's document load (open-only formats used
    /// to export into a half-loaded document and fail the native conversion,
    /// code 32). A host without the visible-render contract cannot send the
    /// signal, so `activate` presets this to preserve the previous
    /// open-settled trigger for such pins.
    @Published private(set) var coverRenderObserved = false
    /// True only while a committed-cover export (the passive read-only Notes
    /// cover backfill) holds the session fence. A save, an attachment insert
    /// or an external refresh never sets this: unlike those, the cover export
    /// changes no user data, so a host that installed `prepareForPassiveClose`
    /// keeps its primary exit enabled and parks the intent on the host's
    /// FULL preview settlement instead of dropping it on the `canAct` gate.
    @Published private(set) var coverExportInFlight = false
    /// True when the pinned host exposes the visible-render contract. The
    /// framework is pinned separately from this source: an older host keeps the
    /// previous open-only readiness (and the release gate keeps the Office
    /// capability unqualified) until the rebuilt framework is pinned.
    private var hostSupportsVisibleRender = false
    /// Monotonic open generation. Every `activate` advances it; the native
    /// callbacks it installs capture their generation, so a callback from a
    /// controller an earlier generation mounted can never settle this session.
    private var openGeneration = OfficeOpenGeneration()
    private let proposalSessionID = UUID()
    /// Durable correlation identity for this session's bounded stage trace
    /// (`OfficeStageRecorder`). The pinned host logs its own per-controller
    /// identity; this one orders the App-side chain (intent -> working copy ->
    /// controller -> engine -> permission -> first paint -> exit interlock)
    /// and carries the host's `renderDiagnostics` snapshot when the App reads
    /// it. Never document contents.
    private let stageSessionID = UUID().uuidString
    /// Records one observed stage with this session's correlation identity and
    /// the current open generation. Content-free by construction.
    ///
    /// `withMemory` attaches the process headroom sample (`OfficeMemorySample`)
    /// at the stages a memory-related termination would need to be read from:
    /// controller mount, engine open/render, edit entry and memory warnings.
    private func recordStage(_ stage: String,
                             _ detail: [String: String] = [:],
                             withMemory: Bool = false) {
        var facts = detail
        if withMemory {
            for (key, value) in OfficeMemorySample.facts() where facts[key] == nil {
                facts[key] = value
            }
        }
        OfficeStageRecorder.shared.record(session: stageSessionID,
                                          generation: openGeneration.current,
                                          stage: stage,
                                          detail: facts)
    }
    /// Build 233 R1: maps one content-free native breadcrumb onto this
    /// session's durable trace. The host's own session/generation ride along as
    /// bounded facts so a native sequence can be ordered independently; the
    /// caller already rejected callbacks from a replaced controller.
    private func recordNativeStage(_ event: [String: Any]) {
        guard let stage = event["stage"] as? String, !stage.isEmpty else { return }
        var facts: [String: String] = [:]
        if let raw = event["facts"] as? [String: Any] {
            for (key, value) in raw {
                switch value {
                case let number as NSNumber: facts[key] = number.stringValue
                case let text as String: facts[key] = text
                default: continue
                }
            }
        }
        if let nativeSession = event["session"] as? String, !nativeSession.isEmpty {
            facts["hostSession"] = String(nativeSession.prefix(8))
        }
        if let nativeGeneration = event["generation"] as? NSNumber {
            facts["hostGeneration"] = nativeGeneration.stringValue
        }
        recordStage("host.\(stage)", facts)
    }
    /// Owning surfaces (Notes, IDE) record their bracket stages under the same
    /// correlation identity, so one trace carries the whole chain.
    func recordOwnerStage(_ stage: String, _ detail: [String: String] = [:]) {
        recordStage(stage, detail)
    }
    /// The correlation identity of this session's durable stage trace.
    var stageTraceSessionID: String { stageSessionID }
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
                    // Errors are part of the durable stage trace: the runtime
                    // death and its generation, never document contents.
                    self.recordStage("runtime.failed", ["phase": String(describing: self.phase)])
                    self.error = OfficeInkText.t(
                        "文档服务已停止响应，编辑副本已保留；重启应用后可恢复。",
                        "The document service stopped responding. Your editing copies were retained; restart the app to recover.")
                    self.phase = .failed
                }
            }
        #endif
        // Build 233 R2: a system memory warning while an Office surface is
        // mounted asks for an idle-model shed. The runtime call never waits on
        // or interrupts active inference, and it never cancels a task, a VM or
        // a retained tool continuation; a refused shed is recorded, not forced.
        memoryWarningObservation = NotificationCenter.default
            .publisher(for: UIApplication.didReceiveMemoryWarningNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleOfficeMemoryWarning()
                }
            }
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

    /// The visible, recoverable notice for the current bounded outcome, if any.
    /// Only the render-unverified presentation state uses the inline banner; a
    /// failed session keeps its full-surface error view.
    var openingWarning: OfficeOpeningWarning? {
        renderUnverified ? openingPolicy?.warning : nil
    }
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
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let callback: @convention(block) (NSError?) -> Void = { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
                _ = controller.perform(NSSelectorFromString("setDrawingMode:completion:"), with: NSNumber(value: enabled), with: callback as AnyObject)
            }
        } catch {
            // A rejected toggle can still have disarmed or half-armed the
            // native gate. Never keep publishing On (or stale ink results)
            // while the caller reports that failure.
            drawingMode = false
            invalidateInkApply()
            inkError = nil
            throw error
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
    /// The native host owns contact routing and blocks canvas palm input;
    /// settings wait until the previous contact is no longer selected.
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

    /// Commit completed live edits, then freeze the exact saved source for
    /// the pre-generation options form. No source page setup is rewritten.
    func preparePDFExport() async throws -> OfficePDFExportPreparation {
        guard canAct, documentActionsReady, let controller, let currentSession = session else {
            throw FloeError.validationFailed(OfficeInkText.t("文档尚未就绪，请稍后重试。", "The document is not ready. Try again shortly."))
        }
        let fence = capturePassiveExitFence()
        let activePen = readOnly ? false : await hasActivePenContact()
        guard !activePen else {
            throw FloeError.validationFailed(OfficeInkText.t("请抬笔后重试。", "Lift the pen and try again."))
        }
        // Read the editor's own part before saving. A missing current part
        // hides Current Sheet; it never becomes a first-sheet fallback.
        var selectedPart: Int?
        if let web = OfficeExplicitSaveBridge.findWebView(in: controller.view) {
            let value = try? await web.evaluateJavaScript("""
            (() => {
                const map = window.app && window.app.map;
                if (!map) return null;
                const n = typeof map.getCurrentPartNumber === 'function'
                    ? map.getCurrentPartNumber() : map._docLayer && map._docLayer._selectedPart;
                return Number.isSafeInteger(n) && n >= 0 ? n : null;
            })()
            """)
            if let number = value as? NSNumber { selectedPart = number.intValue }
        }
        if !readOnly {
            if autosaveActive {
                let proof = await requestAutosaveTransaction(reason: "pdfExport")
                guard proof.isCommittedState, proof.dirtyAfterTransaction == false else {
                    throw FloeError.validationFailed(proof.error ?? OfficeInkText.t("尚未保存完成，请稍后重试。", "Saving has not finished. Try again shortly."))
                }
            } else {
                guard await saveInPlace() else {
                    throw FloeError.validationFailed(error ?? OfficeInkText.t("未能保存文档，请重试。", "The document could not be saved. Try again."))
                }
            }
        }
        guard passiveExitFenceIsCurrent(fence), beginExternalRefresh(resigningFirstResponder: false) else {
            throw OfficePDFExportScreenError.sourceChanged
        }
        defer { endExternalRefresh() }
        let quiescentBefore = readOnly ? true : await verifyQuiescentForExternalRewrite()
        guard quiescentBefore else {
            throw FloeError.validationFailed(OfficeInkText.t("文档仍在编辑，请稍后重试。", "The document is still being edited. Try again shortly."))
        }
        let sourceURL = currentSession.workingURL
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeOfficePDF-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lease = OfficePDFExportLease(directory: directory)
        let ext = sourceURL.pathExtension.lowercased()
        let copyURL = directory.appendingPathComponent("source").appendingPathExtension(ext)
        let sha = try await Task.detached(priority: .userInitiated) {
            let values = try sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0, size <= 128 * 1024 * 1024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            let before = try FloeDigest.sha256Hex(ofFileAt: sourceURL)
            try FileManager.default.copyItem(at: sourceURL, to: copyURL)
            guard try FloeDigest.sha256Hex(ofFileAt: copyURL) == before,
                  try FloeDigest.sha256Hex(ofFileAt: sourceURL) == before else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return before
        }.value
        try Task.checkCancellation()
        let quiescentAfter = readOnly ? true : await verifyQuiescentForExternalRewrite()
        guard passiveExitFenceIsCurrent(fence), quiescentAfter else {
            throw OfficePDFExportScreenError.sourceChanged
        }
        let sheets: [OfficeRegionWorkbookSheet]
        if ext == "xlsx" {
            sheets = try await Task.detached(priority: .userInitiated) {
                try OfficeRegionExport.workbookSheets(sourceURL: copyURL, expectedSHA256: sha)
            }.value
        } else {
            sheets = []
        }
        try Task.checkCancellation()
        guard passiveExitFenceIsCurrent(fence) else { throw OfficePDFExportScreenError.sourceChanged }
        let activeName = selectedPart.flatMap { index in sheets.first(where: { $0.index == index && $0.isVisible })?.name }
        return OfficePDFExportPreparation(
            sourceURL: copyURL, sourceSHA256: sha, fileExtension: ext,
            displayName: currentSession.originalURL.deletingPathExtension().lastPathComponent,
            sheets: sheets, activeSheetName: activeName, lease: lease,
            isCurrent: { [weak self] in
                guard let self, self.passiveExitFenceIsCurrent(fence), !self.runtimeFailed else { return false }
                guard (try? await Task.detached(priority: .userInitiated, operation: {
                    try FloeDigest.sha256Hex(ofFileAt: sourceURL)
                }).value) == sha else { return false }
                if self.readOnly { return true }
                return await self.verifyQuiescentForExternalRewrite()
            })
    }

    func exportConfiguredPDF(_ source: OfficePDFExportPreparation,
                             choices: OfficePDFExportChoices,
                             cancellation: CancellationToken) async throws -> OfficePDFPreparedDelivery {
        #if canImport(FloeOfficeNative)
        let plan: OfficePDFPrintPlan
        do {
            plan = try choices.plan(activeSheetName: source.activeSheetName)
            try plan.validate(forExtension: source.fileExtension)
        } catch {
            throw FloeError.validationFailed(OfficeInkText.t(
                "请检查工作表、单元格区域和 PDF 页码。", "Check the sheet, cell range and PDF pages."))
        }
        try cancellation.throwIfCancelled()
        guard await source.isCurrent(), let controller,
              beginExternalRefresh(resigningFirstResponder: false) else {
            throw OfficePDFExportScreenError.sourceChanged
        }
        defer { endExternalRefresh() }
        do {
            let result: OfficePDFExportResult
            if OfficePDFExportService.capability(forExtension: source.fileExtension)?.savedIsolatedExport == true {
                result = try await OfficePDFExportService.export(.init(
                    sourceURL: source.sourceURL, sourceSHA256: source.sourceSHA256,
                    formatExtension: source.fileExtension, plan: plan,
                    ownedDirectory: source.lease.directory, cancellation: cancellation))
            } else {
                // Legacy packages keep the native route that already opens
                // this exact file; shared validation still applies the final
                // page selection. Never relabel an ODS/XLS as an XLSX.
                let nativePDF = try await Self.exportNativeDocument(controller: controller, format: "pdf")
                defer { try? FileManager.default.removeItem(at: nativePDF) }
                result = try await OfficePDFExportService.finalizeExistingPDF(.init(
                    exportedPDFURL: nativePDF, sourceURL: source.sourceURL,
                    sourceSHA256: source.sourceSHA256, formatExtension: source.fileExtension,
                    plan: plan, ownedDirectory: source.lease.directory, cancellation: cancellation))
            }
            try cancellation.throwIfCancelled()
            try Task.checkCancellation()
            guard self.controller === controller, await source.isCurrent() else {
                throw OfficePDFExportScreenError.sourceChanged
            }
            let exportedName = source.displayName.isEmpty ? "Document.pdf" : source.displayName + ".pdf"
            let delivery = source.lease.directory.appendingPathComponent(exportedName)
            // Preview regeneration replaces the leased slot: the previous
            // preview file is fenced stale output (the options view never
            // presents share/print while a generation runs), so removing it
            // before copying the newly verified bytes is required cleanup,
            // not an overwrite of foreign content. The source document is
            // never a destination on any path.
            if FileManager.default.fileExists(atPath: delivery.path) {
                try FileManager.default.removeItem(at: delivery)
            }
            // Unique leased directory, with the same no-overwrite rule as the
            // backend. Re-measure after giving the file its user-facing name.
            let producedURL = result.pdfURL, producedSHA = result.pdfSHA256
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.copyItem(at: producedURL, to: delivery)
                guard try FloeDigest.sha256Hex(ofFileAt: delivery) == producedSHA else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }.value
            try cancellation.throwIfCancelled()
            try Task.checkCancellation()
            guard self.controller === controller, await source.isCurrent() else {
                throw OfficePDFExportScreenError.sourceChanged
            }
            // The service child only carried the produced PDF; the leased
            // delivery now holds the verified bytes. Remove the child so a
            // regenerate cycle never accumulates duplicate copies, with the
            // same quarantine retention as the error path.
            let producedDirectory = producedURL.deletingLastPathComponent()
            if !(await OfficeAutomaticExecutionGate.shared.isQuarantined) {
                try? FileManager.default.removeItem(at: producedDirectory)
            }
            return OfficePDFPreparedDelivery(
                url: delivery, lease: source.lease,
                pageCount: result.pageCount, byteCount: result.byteCount,
                pdfSHA256: producedSHA)
        } catch {
            if await OfficeAutomaticExecutionGate.shared.isQuarantined {
                // The service retained a native session that did not close.
                // The outer share lease must not delete that recovery input.
                source.lease.preserveForRecovery()
            }
            throw error
        }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
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
        let output = try await Self.exportNativeDocument(controller: controller, format: format)
        if format == "pptx", let workspace, let session,
           session.originalURL.pathExtension.lowercased() == "pptx" {
            // The engine owns workingURL while open. Preserve workbook styling
            // only in this completed, independent export snapshot.
            try await workspace.preserveChartWorkbookFormatting(in: output, for: session)
        }
        if format == "pdf" {
            guard let pdf = CGPDFDocument(output as CFURL), pdf.numberOfPages > 0 else { throw CocoaError(.fileReadCorruptFile) }
        } else if ["docx", "pptx", "xlsx"].contains(format) {
            _ = try OfficeDocumentService.inspect(url: output)
        }
        return output
    }

    /// A cover belongs to already committed bytes, never to a newer unsaved
    /// canvas. Hold the existing input/operation fence through export and
    /// check the working copy and engine before and after. Do not re-save:
    /// another serialization could change the package being identified.
    func exportCommittedCoverPDF(expectedSHA256: String) async throws -> URL {
        guard exportFormats.contains("pdf"), let controller,
              let workingURL = session?.workingURL, beginExternalRefresh(resigningFirstResponder: false) else {
            throw CocoaError(.featureUnsupported)
        }
        coverExportInFlight = true
        defer {
            // Clear the passive-export carve-out before handing the operating
            // fence back. The retained close now waits on the host's full
            // preview settlement, so the export deliberately settles NOTHING
            // itself: it owns no completion signal for the PNG render, cache
            // and card binding that follow it, and must never poison or
            // pre-resolve any host-side wait.
            coverExportInFlight = false
            endExternalRefresh()
        }
        let wasReadOnly = readOnly
        var hadEdits = wasReadOnly ? false : await hasLocalEditsToProtect()
        // Writer can deliver its post-save ModifiedStatus after the save
        // receipt. Keep input fenced while waiting for a real clean state;
        // expiry still refuses capture, without clearing any dirty flag.
        let settleDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while hadEdits, ContinuousClock.now < settleDeadline {
            try await Task.sleep(for: .milliseconds(50))
            hadEdits = await hasLocalEditsToProtect()
        }
        guard let web = OfficeExplicitSaveBridge.findWebView(in: controller.view),
              (try await web.evaluateJavaScript("window.__floeOfficePenState ? window.__floeOfficePenState().activeStroke : false")) as? Bool == false,
              !hadEdits else {
            recordStage("cover.refused", ["reason": "active-or-dirty", "dirty": String(hadEdits),
                                            "workingCopyDirty": String(hasUncommittedChanges),
                                            "engineDirty": (await engineModifiedState()).map(String.init) ?? "unknown"])
            throw CocoaError(.fileWriteFileExists)
        }
        let before = try await Task.detached(priority: .userInitiated) {
            try FloeDigest.sha256Hex(ofFileAt: workingURL)
        }.value
        guard before == expectedSHA256, self.controller === controller else {
            recordStage("cover.refused", ["reason": "source-changed"])
            throw CocoaError(.fileWriteFileExists)
        }
        let output = try await Self.exportNativeDocument(controller: controller, format: "pdf")
        do {
            let after = try await Task.detached(priority: .userInitiated) {
                try FloeDigest.sha256Hex(ofFileAt: workingURL)
            }.value
            let hasNewEdits = wasReadOnly ? false : await hasLocalEditsToProtect()
            guard after == before, self.controller === controller,
                  readOnly == wasReadOnly, !hasNewEdits else {
                recordStage("cover.refused", ["reason": "export-changed", "dirty": String(hasNewEdits),
                                                "sameBytes": String(after == before)])
                throw CocoaError(.fileWriteFileExists)
            }
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    private static func exportNativeDocument(controller: UIViewController, format: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let callback: @convention(block) (NSURL?, NSError?) -> Void = { url, error in
                if let error { continuation.resume(throwing: error) }
                else if let url { continuation.resume(returning: url as URL) }
                else { continuation.resume(throwing: CocoaError(.fileWriteUnknown)) }
            }
            _ = controller.perform(NSSelectorFromString("exportDocumentWithFormat:completion:"), with: format as NSString, with: callback as AnyObject)
        }
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
                NSLocalizedDescriptionKey: FloeL10n.l("workspace.office_document_editor_view.the_attachment_insertion_did_not_finish"),
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
        recordStage("intent.preview", ["format": url.pathExtension.lowercased()])
        await performIntent(.preview)
    }

    /// Terminal open failure reported by the owning surface when URL
    /// resolution or the open intent itself failed before any controller
    /// mounted. Publishes a recoverable `.failed` state (the surface offers
    /// Retry) instead of leaving the phase on `.idle`, which
    /// `OfficeDocumentSurface` renders as an endless "opening" spinner and
    /// which never re-arms the owning loader.
    func reportOpenFailure(_ error: Error) {
        recordStage("open.resolutionFailed", ["domain": (error as NSError).domain,
                                              "code": String((error as NSError).code)])
        self.error = error.localizedDescription
        phase = .failed
    }

    /// Queued edit-intent entry point. While an open/save/attachment operation
    /// owns the session the intent is remembered and replayed when it settles,
    /// so tapping Edit on a loading document is never silently dropped. An
    /// automatic preview reopen can never displace this explicit intent.
    @discardableResult
    func requestEditing() async -> Bool {
        recordStage("intent.edit")
        return await performIntent(.edit)
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
            recordStage("workingCopy.open", ["format": url.pathExtension.lowercased()])
            let files = try SecurityScopedDocumentWorkspace()
            let opened = try await files.open(securityScopedURL: url)
            workspace = files
            session = opened
            hasUncommittedChanges = false
            recordStage("workingCopy.ready")
            try await activate(readOnly: true)
            return true
        } catch {
            recordStage("workingCopy.failed", ["domain": (error as NSError).domain])
            fail(error)
            return false
        }
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
            recordStage("edit.refused.remoteSnapshot")
            editUnavailableReason = Self.remoteSnapshotHint
            return false
        }
        phase = .loading
        error = nil
        editUnavailableReason = nil
        recordStage("edit.attempt", withMemory: true)
        do {
            try await closeController()
            try await activate(readOnly: false)
            // Only a verified editable engine session clears preview. The
            // probe result is the acknowledgement, never the requested flag.
            try await acknowledgeEditPermission()
            recordStage("edit.acknowledged", ["readOnly": readOnly ? "true" : "false"])
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

    /// The bounded wait for the host's verified engine-permission report. For
    /// an editable presentation the report legitimately follows the first
    /// painted document tile — the guarded edit entry is paint-gated on the
    /// host, so the open-permission report arrives after the engine proved a
    /// real paint, not at page-init time. The wait therefore tracks the
    /// opening contract's budget with a margin that keeps the open watchdog
    /// the outer, harder bound: the recoverable "not confirmed yet" outcome
    /// always wins over a hard timeout failure for a merely slow host.
    static func permissionReportBudget(openingPolicy: OfficeOpeningPolicy?,
                                       readOnly: Bool) -> TimeInterval {
        (openingPolicy?.openingBudget ?? (readOnly ? 30 : 45)) - 5
    }

    private func resolveEnginePermission(_ value: Bool?) {
        guard let waiter = permissionWaiter else { return }
        permissionWaiter = nil
        waiter.resume(returning: value)
    }

    /// Build 233 R2: handles one system memory warning while this session's
    /// Office surface is mounted. The shed is idle-only and non-blocking: the
    /// runtime refuses an active inference/benchmark/retained task without
    /// waiting for it, so the warning path can never stall the UI or steal a
    /// mapping an in-flight operation owns. Nothing here cancels a task, a
    /// guest or a tool continuation.
    private func handleOfficeMemoryWarning() async {
        guard controller != nil, phase != .failed, !runtimeFailed else { return }
        memoryWarningShedCount += 1
        recordStage("memory.warning", ["count": String(memoryWarningShedCount)], withMemory: true)
        guard hasShedHandler else { return }
        let released = await shedIdleModel(reason: "office.memoryWarning")
        recordStage(released == nil ? "memory.warningShedSkipped" : "memory.warningShed",
                    ["released": released == nil ? "false" : "true",
                     "count": String(memoryWarningShedCount)],
                    withMemory: true)
    }

    /// The owner-injected shed when one was installed, otherwise the
    /// process-wide coordination seam `AppEnvironment` installs at launch (the
    /// preview and IDE surfaces never resolve the environment themselves).
    private var hasShedHandler: Bool {
        shedIdleLocalModelForOffice != nil || OfficeMemoryCoordination.shared.isInstalled
    }

    @discardableResult
    private func shedIdleModel(reason: String) async -> String? {
        if let shed = shedIdleLocalModelForOffice {
            return await shed(reason)
        }
        return await OfficeMemoryCoordination.shared.shedIdleResidentEngine(reason: reason)
    }

    #if canImport(FloeOfficeNative)
    /// Build 233: the pinned host's own font-discovery facts (staged/resolved
    /// counts and catalog fingerprint), recorded into this session's durable
    /// trace after the runtime settles. An older pinned framework does not
    /// expose the class method and yields an empty snapshot.
    static func hostFontDiscoveryFacts() -> [String: String] {
        let selector = NSSelectorFromString("fontDiscoveryFacts")
        guard FloeOfficeNativeRuntime.responds(to: selector) else { return [:] }
        // Safe after the class-method probe: the pinned framework may predate
        // this Build 233 API, and the probe keeps an old host from trapping on
        // an unrecognized selector.
        let raw = FloeOfficeNativeRuntime.fontDiscoveryFacts
        var facts: [String: String] = [:]
        for (key, value) in raw {
            switch value {
            case let number as NSNumber: facts[key] = number.stringValue
            case let text as String: facts[key] = text
            default: continue
            }
        }
        return facts
    }
    #endif

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
        // One source of budgets: the bounded opening contract this session was
        // mounted with. The fallback matches the historical 30 s preview /
        // 45 s editable bound for a session that never built a policy.
        let seconds = openingPolicy?.openingBudget ?? (readOnly ? 30 : 45)
        let budget = UInt64(max(1, seconds) * 1_000_000_000)
        openWatchdog = Task { @MainActor [weak self, weak native] in
            try? await Task.sleep(nanoseconds: budget)
            guard !Task.isCancelled, let self, let native, self.controller === native,
                  self.phase == .loading, !self.runtimeFailed else { return }
            self.runtimeFailed = true
            self.recordStage("open.watchdog", ["budget": String(Int(seconds)),
                                               "readOnly": readOnly ? "true" : "false"])
            if var policy = self.openingPolicy {
                _ = policy.openingDeadlineElapsed()
                self.openingPolicy = policy
            }
            self.error = self.openingPolicy?.warning.map { OfficeInkText.t($0.detailZh, $0.detailEn) }
                ?? (readOnly
                    ? FloeL10n.l("workspace.office_document_editor_view.the_document_engine_could_not_open")
                    : FloeL10n.l("workspace.office_document_editor_view.the_document_engine_could_not_open_2"))
            self.phase = .failed
        }
    }
    #endif

    private func cancelOpenWatchdog() {
        openWatchdog?.cancel()
        openWatchdog = nil
    }

    // Both watchdogs and the capability probe take the host controller, which
    // only exists when the pinned framework is available (device builds). The
    // simulator target compiles this file without `FloeOfficeNative`, so every
    // host-typed reference must stay inside this import guard; the plain
    // `cancel…` helpers above/below it deliberately remain unguarded because
    // they only touch app-owned state.
    #if canImport(FloeOfficeNative)
    /// True when the pinned host exposes the visible-render contract. The
    /// framework is qualified separately from this source, so an older host is
    /// detected at runtime and keeps the previous open-only readiness instead
    /// of waiting for a signal that host can never send.
    private static func hostSupportsVisibleRender(_ native: FloeOfficeNativeViewController) -> Bool {
        native.responds(to: NSSelectorFromString("setOnVisibleRenderReady:"))
            && native.responds(to: NSSelectorFromString("setOnVisibleRenderFailed:"))
            && native.responds(to: NSSelectorFromString("renderDiagnostics"))
    }

    /// Bounded safety net for a host that reports neither render outcome (a
    /// lost callback, or a host killed mid-open). It never fires once the
    /// session settled, so a slow but successful render cannot be failed after
    /// the fact. Its outcome is the recoverable `renderUnverified` state, never
    /// an unbounded spinner or a dead end.
    private func startRenderWatchdog(for native: FloeOfficeNativeViewController) {
        cancelRenderWatchdog()
        let seconds = openingPolicy?.renderBudget ?? (readOnly ? 25 : 30)
        let budget = UInt64(max(1, seconds) * 1_000_000_000)
        renderWatchdog = Task { @MainActor [weak self, weak native] in
            try? await Task.sleep(nanoseconds: budget)
            guard !Task.isCancelled, let self, let native, self.controller === native,
                  self.phase == .loading, !self.runtimeFailed,
                  self.renderGate?.awaitsVisibleRender == true else { return }
            guard self.renderGate?.deadlineExceeded() == .failed else { return }
            self.markRenderUnverified()
        }
    }
    #endif

    /// Settles a presentation whose bounded render wait elapsed without the
    /// host's visible-render evidence. The engine surface stays mounted and
    /// interactive; the owning surface shows the policy's visible, recoverable
    /// notice (retry preview / recover / dismiss) instead of failing the
    /// session. Nothing claims a verified paint, and the retained working copy
    /// is never touched, so a late render observation can still settle it ready.
    private func markRenderUnverified() {
        guard var policy = openingPolicy, policy.requiresVisibleRender else { return }
        guard policy.renderDeadlineElapsed() == .renderUnverified else { return }
        openingPolicy = policy
        renderUnverified = true
        cancelOpenWatchdog()
        if phase == .loading { phase = .ready }
        recordStage("render.unverified", ["phase": phase == .ready ? "ready" : "loading",
                                          "generation": String(openGeneration.current)])
    }

    /// Clears the recoverable notice without changing the mounted engine
    /// session. The render gate still reports that no paint was observed.
    func dismissRenderUnverified() {
        renderUnverified = false
    }

    private func cancelRenderWatchdog() {
        renderWatchdog?.cancel()
        renderWatchdog = nil
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
    ///
    /// An editable *backing* permission is not an editable *UI*: the mobile
    /// editor starts every editable document in its viewing-first UI, and
    /// Impress/Draw additionally start in the file-based (endless slide
    /// scrolling) layout. Only `map.isEditMode()` proves the edit surface is
    /// live, so this follows the engine's guarded entry once more when the UI
    /// mode has not switched yet.
    private func acknowledgeEditPermission() async throws {
        #if canImport(FloeOfficeNative)
        guard let native = controller as? FloeOfficeNativeViewController else { return }
        var hostReadOnly = await awaitEnginePermission(
            seconds: Self.permissionReportBudget(openingPolicy: openingPolicy, readOnly: readOnly))
        guard native.isViewLoaded, let webView = OfficeExplicitSaveBridge.findWebView(in: native.view) else {
            // Without a mounted surface the engine has not opened yet. The host
            // callback (or the open watchdog) still owns this session; never
            // fabricate a read-only denial from a missing page.
            if hostReadOnly == false {
                engineSessionReadOnly = false
                readOnly = false
                editUnavailableReason = nil
            }
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
        let requiresPresentationEditLayout = OfficeRenderRequirement.forDocument(
            pathExtension: session?.workingURL.pathExtension ?? "") == .visibleRenderRequired
        if hostReadOnly == false, probe.isEditMode != true,
           requiresPresentationEditLayout || probe.isEditMode == false {
            // The engine's backing permission is editable but its UI is still
            // in the viewing-first (or file-based presentation) mode. Follow
            // the engine's own guarded mobile entry, which retains its
            // format/password/lock checks, and then re-read the UI mode. For
            // Word/Excel a genuinely unknown probe keeps the previous
            // behaviour instead of forcing an entry that could bounce a
            // healthy editor back to preview.
            let entry = await Self.enterEditMode(native)
            recordStage("edit.entry", ["readOnly": entry.readOnly ? "true" : "false",
                                       "pendingPassword": entry.pendingPassword ? "true" : "false",
                                       "branch": "paint-gated"])
            if entry.pendingPassword {
                editUnavailableReason = OfficeInkText.t(
                    "该文档需要编辑密码，请在编辑器中输入。",
                    "This document requires its edit password. Enter it in the editor.")
                return
            }
            if entry.readOnly == false {
                engineSessionReadOnly = false
                readOnly = false
                editUnavailableReason = nil
                return
            }
            // The engine refused the switch: fall through to the truthful
            // read-only/denied handling below instead of claiming editable.
            hostReadOnly = true
        } else if hostReadOnly == false {
            // Backing permission editable and the engine's edit UI is live.
            // The host may already have completed its guarded mobile entry
            // before this probe. Record that observed entry just as we record
            // an explicit enterEditMode result above; do not call it again.
            // An unknown UI mode (allowed for non-presentation documents)
            // must not produce a verified entry breadcrumb.
            if probe.isEditMode == true {
                recordStage("edit.entry", ["readOnly": "false",
                                           "pendingPassword": "false",
                                           "uiEdit": "true",
                                           "branch": "already-editable-probe"])
            }
            engineSessionReadOnly = false
            readOnly = false
            editUnavailableReason = nil
            return
        }
        if hostReadOnly == true {
            // Follow the engine's own guarded mobile entry through the host
            // API: it reports the engine state after the attempt and
            // distinguishes an edit-password challenge (error 42) from a
            // denied document. A read-only grant is never relaxed there.
            let entry = await Self.enterEditMode(native)
            recordStage("edit.entry", ["readOnly": entry.readOnly ? "true" : "false",
                                       "pendingPassword": entry.pendingPassword ? "true" : "false",
                                       "branch": "readonly-recheck"])
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
            // concluding that the document is denied. Cold starts, remounts
            // on compact layouts and the close-then-reopen document switch
            // can take well past ten seconds before the page reports its real
            // backing permission through the observer, so the window must
            // outlast them — the previous 3s budget read a slow editable
            // document as denied and bounced it back to preview, which is why
            // later edit attempts kept failing.
            for _ in 0..<100 {
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
            // state): restore the truthful read-only claim, settle the
            // surface onto the mounted controller, and stop the open watchdog,
            // which would otherwise turn this recoverable "unknown" into a
            // misleading hard failure after its timeout.
            readOnly = true
            editUnavailableReason = OfficeInkText.t(
                "编辑器尚未确认可编辑状态；若仍只读，请稍后重试或解除文档限制。",
                "The editor has not confirmed an editable state yet; retry shortly, or remove the document restriction.")
            cancelOpenWatchdog()
            if renderGate?.requirement == .visibleRenderRequired {
                // A presentation may never claim a bare ready on an engine
                // that never confirmed: it gets the same recoverable,
                // banner-backed outcome as a bounded render miss (the gate
                // itself stays unready, so saving stays refused until a real
                // paint arrives). Word/Excel keep their historical open-only
                // readiness, which never waited on a render signal.
                markRenderUnverified()
            } else {
                phase = .ready
            }
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
    /// (error 41) and stays read-only. Bounded: a host that never acknowledges
    /// reads as unverified-read-only so the edit acknowledgement can never
    /// wedge the session (a stuck `operating` refuses every later recovery);
    /// the caller's re-probe and fallback then decide from the engine's state.
    private static func enterEditMode(_ native: FloeOfficeNativeViewController) async -> (readOnly: Bool, pendingPassword: Bool) {
        let ack = OfficeEditEntryAck()
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            ack.resolve((true, false))
        }
        Task { @MainActor in
            native.enterEditMode { readOnly, error in
                let pendingPassword = (error as NSError?)?.code == 42
                ack.resolve((readOnly, pendingPassword))
            }
        }
        let result = await ack.wait()
        timeoutTask.cancel()
        return result
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
        recordStage("edit.fallback.preview")
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
        // The loaded/editable/visible distinction is explicit at the save
        // boundary: a session that never reached its verified ready state (an
        // unrendered presentation included) must never flush the engine — an
        // unloaded or unrendered document is not saved, and the retained
        // working copy is never overwritten by an unverified state.
        guard canAct, !readOnly, renderGate?.permitsSave ?? true, let workspace, let session else {
            recordStage("save.refused", ["ready": canAct ? "true" : "false",
                                         "readOnly": readOnly ? "true" : "false",
                                         "permitsSave": (renderGate?.permitsSave ?? true) ? "true" : "false"])
            return false
        }
        guard !engineBatchRestoreFailed else {
            // A partial batch left an unverified working copy; committing it
            // would silently publish an unverified engine state.
            error = OfficeInkText.t(
                "上一次批量编辑未能恢复，已暂停保存以保护文档。请重新打开文档（丢弃未验证的编辑副本）后再试。",
                "A previous command batch could not be restored, so saving is paused to protect the document. Reopen the document to discard the unverified working copy, then retry.")
            recordStage("save.refused.unverifiedBatch")
            return false
        }
        operating = true
        defer { finishOperation() }
        phase = .saving
        error = nil
        hasSaveConflict = false
        recordStage("save.started", ["returnToPreview": returnToPreview ? "true" : "false"])
        do {
            #if canImport(FloeOfficeNative)
            guard let native = controller as? FloeOfficeNativeViewController else { throw CocoaError(.fileWriteUnknown) }
            native.view.isUserInteractionEnabled = false
            defer { native.view.isUserInteractionEnabled = true }
            // Bounded: a save that neither acknowledges nor fails in time
            // surfaces a recoverable error instead of an endless "Saving…".
            // A save dispatched while another tracked save is still open is
            // rejected pre-dispatch (native error 9, the engine's one-save
            // admission); retry that proven busy signal exactly once after
            // the activity settles. Generic completion failures (code 8) are
            // surfaced, never masked: they can be genuine save defects.
            let saveAttempts = try await OfficeSaveAdmissionRetry.run(
                onRetry: { [weak self] in
                    Task { @MainActor [weak self] in self?.recordStage("save.busyRetry", [:]) }
                }
            ) {
                try await Self.saveWorkingCopy(native)
            }
            if saveAttempts > 1 {
                recordStage("save.busyRetry.ok", ["attempts": "\(saveAttempts)"])
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
            // Every owning surface refreshes its sibling entries after a
            // verified original-file commit (and only then).
            onCommitted?()
            recordStage("save.ok", ["returnToPreview": returnToPreview ? "true" : "false"])
            return true
            #else
            throw CocoaError(.featureUnsupported)
            #endif
        } catch {
            if let officeError = error as? OfficeDocumentError, case .revisionConflict = officeError {
                hasSaveConflict = true
            }
            recordStage("save.failed", ["domain": (error as NSError).domain,
                                        "code": String((error as NSError).code),
                                        "conflict": hasSaveConflict ? "true" : "false"])
            self.error = error.localizedDescription
            phase = runtimeFailed || controller == nil ? .failed : .ready
            return false
        }
    }

    // MARK: - External resource refresh

    /// Freezes the current editor and holds the session's operating lock across
    /// an external-revision decision and close. Returns false when another
    /// session operation (initial open, save, attachment) is in flight.
    func beginExternalRefresh(resigningFirstResponder: Bool = true) -> Bool {
        guard canAct else { return false }
        operating = true
        setEditorInteraction(false, resigningFirstResponder: resigningFirstResponder)
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

    /// Flushes the engine's working copy and reports the saved package's
    /// formula-error cells (cell + error text). Read-only; the source file is
    /// never touched.
    func formulaErrorCells() async throws -> [OfficeErrorCell] {
        #if canImport(FloeOfficeNative)
        guard canAct, let workspace, let session, let controller else {
            throw FloeError.validationFailed("The document is not ready")
        }
        guard let native = controller as? FloeOfficeNativeViewController else {
            throw CocoaError(.featureUnsupported)
        }
        if !readOnly {
            native.view.isUserInteractionEnabled = false
            defer { native.view.isUserInteractionEnabled = true }
            try await Self.saveWorkingCopy(native)
        }
        _ = workspace
        let snapshot = try OfficeOutputSnapshot.capture(url: session.workingURL)
        return snapshot.errorCells
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    // MARK: - Shared engine command surface (UI + document.office.edit)

    /// Workspace-relative identity of the open document and its owner,
    /// installed by the owning surface so the shared command center can bind
    /// tool calls to this exact live session (and refuse another task).
    private(set) var liveDocumentID: String?
    private(set) var liveWorkspaceRoot: URL?
    private(set) var liveOwnerConversationID: UUID?

    /// True when this session can dispatch engine commands and commit their
    /// verified output (editable, rendered, controller mounted).
    var commandReady: Bool {
        canAct && !readOnly && controller != nil && phase == .ready
            && (renderGate?.permitsSave ?? true)
    }

    func registerLiveDocument(relativePath: String, root: URL?, conversationID: UUID?) {
        liveDocumentID = relativePath
        liveWorkspaceRoot = root
        liveOwnerConversationID = conversationID
        OfficeLiveSessionRegistry.shared.register(session: self, root: root, relativePath: relativePath)
    }

    private func unregisterLiveDocument() {
        guard let liveDocumentID else { return }
        OfficeLiveSessionRegistry.shared.unregister(session: self, root: liveWorkspaceRoot,
                                                    relativePath: liveDocumentID)
        self.liveDocumentID = nil
        self.liveWorkspaceRoot = nil
        self.liveOwnerConversationID = nil
    }

    /// Refuse an alias registration that does not describe the actual open file.
    var proposalReviewBinding: OfficeProposalSessionBinding? {
        guard let root = liveWorkspaceRoot, let path = liveDocumentID,
              let session, let controller,
              OfficeLiveSessionRegistry.shared.session(root: root, relativePath: path) === self,
              root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
                == session.originalURL.standardizedFileURL.resolvingSymlinksInPath() else { return nil }
        return OfficeProposalSessionBinding(
            documentKey: root.standardizedFileURL.resolvingSymlinksInPath().path + "|"
                + session.originalURL.standardizedFileURL.resolvingSymlinksInPath().path,
            sessionID: proposalSessionID, controllerID: ObjectIdentifier(controller),
            generation: openGeneration.current)
    }

    struct OfficeLiveEngineStatus {
        var sha256: String
        var readOnly: Bool
        var editable: Bool
        var unsavedChanges: Bool
        var unavailableReason: String?
    }

    /// Live status for the shared command center: the exact committed SHA the
    /// proposal must bind, the engine's read-only/edit state and whether the
    /// session holds unsaved edits.
    func liveEngineStatus() async throws -> OfficeLiveEngineStatus {
        guard let session else {
            throw FloeError.validationFailed("The Office document is not open")
        }
        let sha = try FloeDigest.sha256Hex(ofFileAt: session.originalURL)
        let unsaved = await hasLocalEditsToProtect()
        return OfficeLiveEngineStatus(sha256: sha,
                                      readOnly: readOnly,
                                      editable: commandReady,
                                      unsavedChanges: unsaved,
                                      unavailableReason: editUnavailableReason)
    }

    /// The engine's opaque selection/cursor identity for this session, or nil
    /// when the page exposes none. Proposals for selection-relative commands
    /// bind this value; apply refuses a changed selection.
    func liveSelectionFingerprint() async -> String? {
        guard let controller else { return nil }
        return await OfficeCommandBridge.selectionFingerprint(controller: controller)
    }

    // MARK: - Live page readout (document assistant input)

    /// One snapshot of the CURRENT live document view, captured through the
    /// mounted Office WKWebView's own `takeSnapshot`. It therefore shows the
    /// engine's active sheet/slide/page at its actual scroll position,
    /// including strokes that are visible but not yet saved. This is a
    /// snapshot of the App's own document view — not a device screen capture,
    /// no new permissions, no cover/thumbnail side channel, and the file on
    /// disk is never touched by the readout.
    struct OfficeLiveRenderedPage: Sendable {
        let pngData: Data
        let pixelWidth: Int
        let pixelHeight: Int
        let sha256: String
        /// "documentCanvasCrop" when the engine document container bounded the
        /// snapshot, "liveViewFull" when the full document view was captured.
        let boundsMode: String
    }

    struct OfficeLivePageReadout: Sendable {
        let page: OfficeLiveRenderedPage
        /// SHA-256 of the committed original file at capture time.
        let committedSHA256: String
        /// True when the engine reported unsaved edits before the capture.
        let hadUnsavedChanges: Bool
        /// Identity of the mounted controller this readout was captured from,
        /// so the calling surface can re-check that the same editor is still
        /// open before handing the result to a model.
        let controllerObjectID: ObjectIdentifier
        /// Engine selection/cursor identity sampled before the snapshot and
        /// re-checked after. Non-nil and equal fences a selection/cursor move
        /// during the capture; the pinned host exposes no viewport-change
        /// event, so a pure scroll without any selection change cannot be
        /// fenced from the App side (reported here instead of being hidden).
        let selectionFenceObserved: Bool
        let engineViewFingerprint: String?
        /// Truthful scope label: the live document view as the engine rendered
        /// it at capture instant.
        let captureScope: String
    }

    /// Captures the live session's current document view. A controller
    /// replacement, phase change, selection/cursor move or cancellation
    /// during the capture fails the readout instead of returning a stale
    /// image. Never falls back to an older cover or saved thumbnail.
    func liveEnginePageReadout() async throws -> OfficeLivePageReadout {
        guard canAct, phase == .ready, let controller else {
            throw CocoaError(.featureUnsupported)
        }
        try Task.checkCancellation()
        let hadUnsavedChanges = readOnly ? false : await hasLocalEditsToProtect()
        // The engine's own selection/cursor/cell identity is the strongest
        // view-position signal the pinned host exposes today. When the page
        // reports none, the capture proceeds but the fence is declared
        // unavailable downstream — never silently claimed.
        let fingerprintBefore = await liveSelectionFingerprint()
        guard let session else { throw CocoaError(.featureUnsupported) }
        let committedSHA256 = try FloeDigest.sha256Hex(ofFileAt: session.originalURL)
        let controllerObjectID = ObjectIdentifier(controller)
        guard let web = OfficeExplicitSaveBridge.findWebView(in: controller.view) else {
            throw CocoaError(.featureUnsupported)
        }
        let crop = await Self.liveDocumentCropRect(in: web)
        let captured = try await Self.snapshotLiveDocumentView(web, cropRect: crop)
        try Task.checkCancellation()
        let fingerprintAfter = await liveSelectionFingerprint()
        // The snapshot no longer describes this editor if the controller was
        // replaced, the session left ready state, or the observed selection
        // moved during the capture window.
        guard phase == .ready, self.controller === controller else {
            throw FloeError.validationFailed("The Office editor changed during capture")
        }
        if let fingerprintBefore, let fingerprintAfter, fingerprintBefore != fingerprintAfter {
            throw FloeError.validationFailed("The Office editor changed during capture")
        }
        return OfficeLivePageReadout(
            page: captured,
            committedSHA256: committedSHA256,
            hadUnsavedChanges: hadUnsavedChanges,
            controllerObjectID: controllerObjectID,
            selectionFenceObserved: fingerprintBefore != nil && fingerprintAfter != nil,
            engineViewFingerprint: fingerprintAfter,
            captureScope: "liveDocumentViewSnapshot")
    }

    /// True when the engine reports an in-progress pen contact — or when that
    /// state cannot be read at all (missing probe, missing web view, JS
    /// failure): fail closed. The assistant commit/rewrite paths must never
    /// save, cancel or fence underneath a stroke that is still being drawn;
    /// the ordinary completed-stroke save path is unaffected.
    func hasActivePenContact() async -> Bool {
        guard let controller,
              let web = OfficeExplicitSaveBridge.findWebView(in: controller.view) else { return true }
        let activeStroke = (try? await web.evaluateJavaScript(
            "window.__floeOfficePenState ? window.__floeOfficePenState().activeStroke : null")) as? Bool
        guard let activeStroke else { return true }
        return activeStroke
    }

    /// Post-fence quiescence check for the assistant's external-rewrite path.
    /// The caller has already committed the visible content and frozen input
    /// through `beginExternalRefresh`; a stroke or pen contact can still have
    /// landed in the commit→fence gap. Both the engine's active-contact state
    /// (fail closed on unknown) and the protected-edits probe must read clean
    /// NOW, so the caller can release the fence and fail with a
    /// refresh-required outcome instead of silently rewriting content that
    /// moved underneath it. Same probes the committed-cover export uses.
    func verifyQuiescentForExternalRewrite() async -> Bool {
        guard !(await hasActivePenContact()) else { return false }
        return !(await hasLocalEditsToProtect())
    }

    /// Bounded read-only geometry probe of the engine's own document
    /// container (same in-session `evaluateJavaScript` precedent as the
    /// cover-export pen-state read). Returns nil — full-view capture — unless
    /// the container reports a finite rect inside the view bounds.
    private static func liveDocumentCropRect(in web: WKWebView) async -> CGRect? {
        let probe = """
        (() => { try {
          const el = document.getElementById('document-container') || document.getElementById('map');
          if (!el) return null;
          const r = el.getBoundingClientRect();
          if (!Number.isFinite(r.left) || !Number.isFinite(r.top) ||
              !Number.isFinite(r.width) || !Number.isFinite(r.height)) return null;
          return JSON.stringify({x:r.left,y:r.top,width:r.width,height:r.height});
        } catch (_) { return null; } })()
        """
        guard let raw = try? await web.evaluateJavaScript(probe) as? String,
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(CropValues.self, from: data),
              value.width >= 64, value.height >= 64,
              value.x >= 0, value.y >= 0,
              value.x + value.width <= web.bounds.width * 1.01,
              value.y + value.height <= web.bounds.height * 1.01 else { return nil }
        return CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
    }

    private struct CropValues: Decodable { let x: Double; let y: Double; let width: Double; let height: Double }

    /// `takeSnapshot` on the document web view (product-code precedent:
    /// EngineeringFilePreview), downscaled to a bounded size for OCR/visual
    /// handoff. Only a bounded encoded PNG leaves this function.
    private static func snapshotLiveDocumentView(_ web: WKWebView, cropRect: CGRect?) async throws -> OfficeLiveRenderedPage {
        let configuration = WKSnapshotConfiguration()
        if let cropRect { configuration.rect = cropRect }
        configuration.afterScreenUpdates = true
        let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
            web.takeSnapshot(with: configuration) { image, error in
                if let image, image.size.width >= 64, image.size.height >= 64 {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CocoaError(.fileReadInapplicableStringEncoding))
                }
            }
        }
        try Task.checkCancellation()
        guard let source = image.cgImage else { throw CocoaError(.fileReadCorruptFile) }
        let maximumPixelWidth = 1_536
        let maximumPixelHeight = 2_048
        let scale = min(1.0, min(CGFloat(maximumPixelWidth) / CGFloat(source.width),
                                 CGFloat(maximumPixelHeight) / CGFloat(source.height)))
        let targetSize = CGSize(width: max(1, CGFloat(source.width) * scale),
                                height: max(1, CGFloat(source.height) * scale))
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: {
            // scale = 1: targetSize is already the FINAL pixel budget. The
            // default renderer format would multiply by the device display
            // scale (2x–3x), contradicting the bounded image and inflating
            // staging/OCR cost.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        let downscaled = renderer.image { context in
            context.cgContext.interpolationQuality = .high
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        guard let cg = downscaled.cgImage, cg.width > 0, cg.height > 0,
              let png = downscaled.pngData(), png.count <= 8 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return OfficeLiveRenderedPage(pngData: png, pixelWidth: cg.width, pixelHeight: cg.height,
                                      sha256: FloeDigest.sha256Hex(png),
                                      boundsMode: cropRect == nil ? "liveViewFull" : "documentCanvasCrop")
    }

    struct OfficeEngineApplyResult {
        var facts: [String]
        var freshStateCommands: Set<String>
        var sha256: String
    }

    /// Dispatches one validated command batch through the live engine, flushes
    /// the working copy, verifies the SAVED package against the promises, then
    /// commits the original with the workspace CAS. Any failure before the
    /// commit leaves the original untouched and the working copy preserved.
    /// `expectedSelectionFingerprint` re-checks the live selection after
    /// interaction is suspended, so a selection-relative command cannot be
    /// redirected to a different paragraph/cell/object.
    func applyEngineCommands(_ commands: [OfficeEngineCommand],
                             expectedSelectionFingerprint: String? = nil,
                             batchID: String? = nil,
                             expectedSHA256: String? = nil,
                             expectedProposalBinding: OfficeProposalSessionBinding? = nil) async throws -> OfficeEngineApplyResult {
        #if canImport(FloeOfficeNative)
        guard commandReady, !readOnly, let workspace, let session, let controller else {
            throw FloeError.validationFailed(
                "The document is not ready for engine edits (preview, read-only or still opening)")
        }
        guard !commands.isEmpty else {
            throw FloeError.validationFailed("No commands were supplied")
        }
        // The operation guard is taken BEFORE any await: a second operation
        // started from the UI or a tool while this one is between awaits must
        // be rejected, not interleaved.
        guard !operating else {
            throw FloeError.validationFailed("Another document operation is in progress; retry when it finishes")
        }
        operating = true
        phase = .saving
        error = nil
        defer { phase = runtimeFailed || self.controller == nil ? .failed : .ready; finishOperation() }
        // A command batch starts from the committed revision: an uncommitted
        // working copy would make the OOXML expectations ambiguous and could
        // silently include unrelated edits in the commit.
        if try await workspace.hasUncommittedWorkingCopy(session) {
            throw FloeError.validationFailed(
                "The editor already has uncommitted changes; save or discard them before applying a proposal")
        }
        guard let native = controller as? FloeOfficeNativeViewController else {
            throw CocoaError(.featureUnsupported)
        }
        native.view.isUserInteractionEnabled = false
        defer { native.view.isUserInteractionEnabled = true }

        // The selection is frozen from here: re-read the engine's opaque
        // identity and refuse a proposal whose target changed.
        if let expectedSelectionFingerprint {
            let current = await OfficeCommandBridge.selectionFingerprint(controller: native)
            guard let current, current == expectedSelectionFingerprint else {
                throw FloeError.validationFailed(
                    "The document selection changed after the proposal was created, so it was not applied. "
                        + "Select the target again and ask for a fresh proposal.")
            }
        }

        // The input fence is held: proposals cannot cross a reopen, a save or
        // an in-memory edit that arrived while the confirmation was visible.
        if let expectedSHA256 {
            guard !(await hasLocalEditsToProtect()), !(await hasActivePenContact()),
                  let expectedProposalBinding,
                  proposalReviewBinding == expectedProposalBinding,
                  try FloeDigest.sha256Hex(ofFileAt: session.originalURL).lowercased()
                    == expectedSHA256.lowercased() else {
                throw FloeError.validationFailed(OfficeInkText.t(
                    "文档已变化，请让助手重新准备修改。",
                    "The document changed. Ask the assistant to prepare the edit again."))
            }
        }
        // Baseline from the committed working copy (== original bytes). A
        // failure after dispatch restores exactly these bytes.
        let before = try OfficeOutputSnapshot.capture(url: session.workingURL)
        if let expectedSHA256, before.sha256.lowercased() != expectedSHA256.lowercased() {
            throw FloeError.validationFailed("The proposal no longer matches the saved document")
        }
        // Persisted pre-batch snapshot: the pinned bundle has no undo-group
        // command, so the only honest whole-batch revert is restoring these
        // exact bytes with a CAS — never a guessed count of engine undos. The
        // snapshot must be copied AND hashed successfully BEFORE any dispatch;
        // a batch with no way back is refused, and the previous recoverable
        // snapshot state is left intact until this batch actually commits.
        let snapshotDirectory = session.workingURL.deletingLastPathComponent()
            .appendingPathComponent("batch-snapshots", isDirectory: true)
        let journalBatchID = batchID ?? UUID().uuidString
        let snapshotURL = snapshotDirectory
            .appendingPathComponent("\(journalBatchID).\(session.workingURL.pathExtension)")
        do {
            try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: snapshotURL)
            try FileManager.default.copyItem(at: session.workingURL, to: snapshotURL)
            let copied = try FloeDigest.sha256Hex(ofFileAt: snapshotURL)
            guard copied == before.sha256 else {
                throw FloeError.validationFailed("the copied snapshot does not match the committed bytes")
            }
        } catch {
            try? FileManager.default.removeItem(at: snapshotURL)
            throw FloeError.validationFailed(
                "A verified pre-batch snapshot could not be created, so the command batch was not started: \(error.localizedDescription)")
        }
        let snapshotSHA = before.sha256
        do {
            let outcome = try await OfficeCommandBridge.dispatch(commands, controller: native)
            try await Self.saveWorkingCopy(native)
            // The engine's private copy is now flushed into workingURL; reopen it.
            let after = try OfficeOutputSnapshot.capture(url: session.workingURL)
            var expectations: [OfficeOutputExpectation] = []
            for command in commands {
                expectations.append(contentsOf: OfficeOutputExpectation.forCommand(command, before: before))
            }
            let facts = try OfficeOutputValidator.verify(before: before, after: after, expectations: expectations)
            let fresh = await OfficeCommandBridge.freshStateCommands(token: outcome.token, controller: native)
            // The verified post-edit bytes are the expected commit result.
            let expectedSHA = after.sha256
            // COMMIT BOUNDARY: the write-ahead entry is PREPARED before the
            // file commit with the canonical document identity and the
            // verified expected SHA. A prepare failure refuses the commit.
            let prepared = OfficeCommittedBatchJournal.Entry(
                batchID: journalBatchID,
                documentID: liveDocumentID ?? session.originalURL.lastPathComponent,
                workspacePath: liveWorkspaceRoot?.path,
                operationID: batchID ?? journalBatchID,
                expectedSHA256: expectedSHA,
                snapshotPath: snapshotURL.path,
                snapshotSHA256: snapshotSHA,
                commands: commands.map(\.id),
                preparedAt: Date(), committedAt: nil, note: nil)
            do {
                try OfficeCommittedBatchJournal.shared.prepare(prepared)
            } catch {
                try? FileManager.default.removeItem(at: snapshotURL)
                throw FloeError.storageCorrupted(
                    "The batch could not be journaled before the commit, so it was not applied: \(error.localizedDescription)")
            }
            // Commit only after verification. The workspace save re-checks the
            // original digest and preserves a conflicting/unguarded copy.
            try await workspace.save(session)
            // A lost completion marker is recoverable: reconciliation compares
            // the file SHA with the prepared expected SHA.
            try? OfficeCommittedBatchJournal.shared.complete(batchID: journalBatchID)
            // Adopt the new revert point only after the commit; the previous
            // recoverable snapshot is retired only now.
            if let previous = engineBatchSnapshotURL, previous != snapshotURL {
                try? FileManager.default.removeItem(at: previous)
            }
            engineBatchSnapshotURL = snapshotURL
            engineBatchCommittedSHA = expectedSHA
            engineBatchJournalID = journalBatchID
            canRevertLastEngineBatch = true
            // Post-commit bookkeeping is best-effort only; the committed SHA is
            // the verified post-edit SHA, never the pre-batch one.
            hasUncommittedChanges = (try? await workspace.hasUncommittedWorkingCopy(session)) ?? false
            if !hasUncommittedChanges { await OfficeExplicitSaveBridge.didCommit(controller: native) }
            onCommitted?()
            recordStage("engine.commands.ok", ["count": "\(commands.count)"])
            return OfficeEngineApplyResult(facts: facts, freshStateCommands: fresh, sha256: expectedSHA)
        } catch {
            // The pre-batch snapshot is the validated way back. Restoration
            // rebuilds the working copy from the committed original (verified
            // against the baseline SHA) — never a guessed count of engine
            // undos, which could reverse unrelated earlier user edits.
            let restored = await restoreFailedEngineBatch(session: session, baseline: before)
            if restored {
                try? FileManager.default.removeItem(at: snapshotURL)
            } else {
                // Keep the snapshot: it is the recoverable pre-batch state.
                engineBatchRestoreFailed = true
                hasUncommittedChanges = true
                canRevertLastEngineBatch = false
                throw FloeError.validationFailed(
                    "The command batch failed and the document could NOT be restored automatically; the unverified working copy was quarantined and saving is paused. The recoverable pre-batch snapshot was preserved. Reopen the document to recover: \(error.localizedDescription)")
            }
            throw FloeError.validationFailed(
                "The command batch failed and the document was restored to the committed revision: \(error.localizedDescription)")
        }
        #else
        throw CocoaError(.featureUnsupported)
        #endif
    }

    private func clearEngineBatchSnapshot() {
        if let engineBatchSnapshotURL { try? FileManager.default.removeItem(at: engineBatchSnapshotURL) }
        engineBatchSnapshotURL = nil
        engineBatchCommittedSHA = nil
        engineBatchJournalID = nil
        canRevertLastEngineBatch = false
    }

    /// Restores after a failed engine batch. The original was never committed
    /// on this path, so the validated recovery is: verify the original still
    /// has the pre-batch bytes, then rebuild the working copy from it. If the
    /// original changed externally, fail closed and keep the snapshot.
    private func restoreFailedEngineBatch(session: DocumentSession,
                                          baseline: OfficeOutputSnapshot) async -> Bool {
        guard let current = try? FloeDigest.sha256Hex(ofFileAt: session.originalURL),
              current == baseline.sha256 else { return false }
        do {
            try await replaceWithExternalVersion(url: session.originalURL, readOnly: false)
            return true
        } catch {
            return false
        }
    }

    /// Reloads the mounted editor from the committed bytes after a confirmed
    /// engine apply (including panel-driven proposals). The proposal flow
    /// refuses a dirty editor, so there is no unsaved work to discard; the
    /// reload keeps the visible editor on the new revision instead of stale
    /// pre-apply content.
    func reloadAfterEngineApply() async throws {
        guard let session, !readOnly else { return }
        let url = session.originalURL
        guard beginExternalRefresh() else { return }
        defer { endExternalRefresh() }
        try await replaceWithExternalVersion(url: url, readOnly: false)
    }

    /// Reverts the last committed command batch by restoring the persisted
    /// pre-batch bytes with a CAS. This is deliberately NOT a guessed number of
    /// engine undos: the pinned bundle has no undo-group command, and any
    /// later user edit would make N undos reverse unrelated work. It refuses
    /// unless the file still has the batch's exact committed SHA and the live
    /// editor has no unsaved edits.
    @discardableResult
    func revertLastEngineBatch() async -> Bool {
        #if canImport(FloeOfficeNative)
        guard !operating, let workspace, let session, let controller,
              controller is FloeOfficeNativeViewController else { return false }
        // The revert point survives a restart: fall back to the durable
        // committed journal entry for this document when the in-memory state
        // was lost.
        let documentKey = liveDocumentID ?? session.originalURL.lastPathComponent
        let resolved: (snapshot: URL, committedSHA: String, batchID: String)?
        if let snapshotURL = engineBatchSnapshotURL, let committedSHA = engineBatchCommittedSHA {
            resolved = (snapshotURL, committedSHA, engineBatchJournalID ?? documentKey)
        } else if let entry = OfficeCommittedBatchJournal.shared.latestCommitted(documentID: documentKey),
                  let path = entry.snapshotPath {
            resolved = (URL(fileURLWithPath: path), entry.expectedSHA256, entry.batchID)
        } else {
            resolved = nil
        }
        guard let resolved else { return false }
        let snapshotURL = resolved.snapshot
        let committedSHA = resolved.committedSHA
        operating = true
        phase = .saving
        error = nil
        defer { phase = runtimeFailed || self.controller == nil ? .failed : .ready; finishOperation() }
        do {
            guard FileManager.default.fileExists(atPath: snapshotURL.path) else {
                error = OfficeInkText.t("批次前快照已不可用。", "The pre-batch snapshot is no longer available.")
                return false
            }
            let currentSHA = try FloeDigest.sha256Hex(ofFileAt: session.originalURL)
            guard currentSHA.lowercased() == committedSHA.lowercased() else {
                error = OfficeInkText.t(
                    "文档在该批次之后又发生了变化，未自动撤销以避免覆盖后续编辑。",
                    "The document changed after this batch, so it was not reverted automatically to avoid overwriting later work.")
                return false
            }
            guard await !hasLocalEditsToProtect() else {
                error = OfficeInkText.t(
                    "编辑器有未保存的修改，无法撤销该批次；请先保存或放弃这些修改。",
                    "The editor has unsaved changes; save or discard them before reverting the batch.")
                return false
            }
            let staged = session.workingURL.deletingLastPathComponent()
                .appendingPathComponent(".floe-batch-revert-\(UUID().uuidString).\(session.workingURL.pathExtension)")
            defer { try? FileManager.default.removeItem(at: staged) }
            try FileManager.default.copyItem(at: snapshotURL, to: staged)
            _ = try FileManager.default.replaceItemAt(session.workingURL, withItemAt: staged)
            try await workspace.save(session)
            OfficeCommittedBatchJournal.shared.remove(batchID: resolved.batchID)
            try? FileManager.default.removeItem(at: snapshotURL)
            clearEngineBatchSnapshot()
            try? await replaceWithExternalVersion(url: session.originalURL, readOnly: false)
            recordStage("engine.batch.reverted")
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
        #else
        return false
        #endif
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
            engineBatchRestoreFailed = false
            clearEngineBatchSnapshot()
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

    private func setEditorInteraction(_ enabled: Bool, resigningFirstResponder: Bool = true) {
        guard let controller, controller.isViewLoaded else { return }
        controller.view.isUserInteractionEnabled = enabled
        if !enabled && resigningFirstResponder { controller.view.endEditing(true) }
    }

    func discardAndReturn() async -> Bool {
        guard !operating, let session, let workspace else {
            recordStage("exit.discard.refused", ["operating": operating ? "true" : "false"])
            return false
        }
        operating = true
        defer { finishOperation() }
        recordStage("exit.discard.started")
        do {
            try await closeController()
            await workspace.discardChangesAndClose(session)
            self.session = try await workspace.open(securityScopedURL: session.originalURL)
            hasUncommittedChanges = false
            engineBatchRestoreFailed = false
            clearEngineBatchSnapshot()
            readOnly = true
            phase = .idle
            recordStage("exit.discard.ok")
            return true
        } catch {
            recordStage("exit.discard.failed", ["domain": (error as NSError).domain])
            fail(error)
            return false
        }
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
        guard !operating, session != nil else {
            recordStage("exit.keep.refused", ["operating": operating ? "true" : "false"])
            return false
        }
        operating = true
        defer { finishOperation() }
        recordStage("exit.keep.started")
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
            recordStage("exit.keep.ok")
            return true
        } catch {
            recordStage("exit.keep.failed", ["domain": (error as NSError).domain])
            fail(error)
            return false
        }
    }

    /// Identity of the mounted surface, captured when a read-only close
    /// intent is accepted by `saveAndDismiss`. Release state is deliberately
    /// NOT snapshotted: `release()` sets `released` immediately and defers the
    /// teardown as `releaseRequested` while an operation (the export) holds
    /// the fence, so both flags are re-read live by the checks below.
    struct PassiveExitFence {
        let generation: Int
        let controllerID: ObjectIdentifier?
        let workingCopyPath: String?
    }

    func capturePassiveExitFence() -> PassiveExitFence {
        PassiveExitFence(generation: openGeneration.current,
                         controllerID: controller.map { ObjectIdentifier($0) },
                         workingCopyPath: session?.workingURL.path)
    }

    /// True while a retained intent still owns the exact mounted surface:
    /// same open generation (every `activate` — reopen, external-version
    /// replacement, recovery — advances it), same mounted controller
    /// instance, same working copy, and neither released nor
    /// teardown-requested. A parked close re-checks this after every await
    /// and before it touches the session.
    func passiveExitFenceIsCurrent(_ fence: PassiveExitFence) -> Bool {
        !released && !releaseRequested
            && openGeneration.isCurrent(fence.generation)
            && controller.map { ObjectIdentifier($0) } == fence.controllerID
            && session?.workingURL.path == fence.workingCopyPath
    }

    /// True directly before dismissal: the intent's own truthful close
    /// (`keepChangesAndReturn`) legitimately tears the controller down while
    /// it runs, so this revalidation keeps the generation, the live release
    /// state and the working-copy identity but not the controller instance.
    /// A released, teardown-requested or re-opened surface still refuses.
    func passiveExitCloseRemainsOwn(_ fence: PassiveExitFence) -> Bool {
        !released && !releaseRequested
            && openGeneration.isCurrent(fence.generation)
            && session?.workingURL.path == fence.workingCopyPath
    }

    /// View removal never deletes an unsettled edit or pretends it was saved.
    func release() async {
        // Terminal from here on: a queued/replayed intent must never re-open
        // a working copy on this session.
        released = true
        unregisterLiveDocument()
        recordStage("session.release")
        renderUnverified = false
        openingPolicy = nil
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
        // Recovery also covers the bounded render-unverified outcome: the
        // mounted surface is usable but the engine never painted it, and the
        // user asked for a fresh preview of the retained working copy.
        guard phase == .failed || renderUnverified else { return false }
        recordStage("recovery.started", ["renderUnverified": renderUnverified ? "true" : "false"])
        if session == nil, controller == nil {
            renderUnverified = false
            phase = .idle
            error = nil
            return true
        }
        guard !operating else { return false }
        operating = true
        defer { finishOperation() }
        runtimeFailed = false
        renderUnverified = false
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
        recordStage("engine.runtime.prepare.started",
                    ["readOnly": readOnly ? "true" : "false"],
                    withMemory: true)
        // Build 233 R2: before the engine runtime and the document import
        // allocate, ask for an immediate unload of an *idle* resident local
        // model. The shed is non-blocking and claim-checked: active inference,
        // a benchmark or a retained tool continuation keeps its mapping and the
        // Office open proceeds unchanged. Nothing is cancelled. The owner may
        // have injected the handler; otherwise the AppEnvironment process-wide
        // seam covers preview/IDE surfaces too.
        if hasShedHandler {
            let released = await shedIdleModel(
                reason: readOnly ? "office.prepare.readOnly" : "office.prepare.editable")
            recordStage(released == nil ? "engine.memory.shedSkipped" : "engine.memory.shed",
                        ["released": released == nil ? "false" : "true"],
                        withMemory: true)
        }
        do {
            try await Self.prepareNativeRuntime()
        } catch {
            recordStage("engine.runtime.prepare.failed", ["domain": (error as NSError).domain])
            throw error
        }
        var discovery = Self.hostFontDiscoveryFacts()
        if let deviceFontFacts = officeDeviceFontFacts {
            for (key, value) in await deviceFontFacts() where discovery[key] == nil {
                discovery[key] = value
            }
        }
        recordStage("engine.runtime.ready", discovery, withMemory: true)
        let native = try FloeOfficeNativeViewController(
            workingFileURL: session.workingURL,
            sessionDirectory: session.workingURL.deletingLastPathComponent(), readOnly: readOnly)
        // Every mounted controller owns one open generation. Callbacks below
        // capture it, so a stale callback from a controller an earlier
        // generation mounted can never settle this session's state.
        let generation = openGeneration.advance()
        coverRenderObserved = false
        runtimeFailed = false
        engineSessionReadOnly = nil
        resolveEnginePermission(nil)
        cancelRenderWatchdog()
        hostSupportsVisibleRender = Self.hostSupportsVisibleRender(native)
        recordStage("controller.mounted", ["generation": String(generation),
                                           "readOnly": readOnly ? "true" : "false",
                                           "hostRenderContract": hostSupportsVisibleRender ? "true" : "false"],
                    withMemory: true)
        // The pinned framework is qualified separately from this source. An
        // older host cannot report a painted surface, so its session keeps the
        // previous open-only contract and the release gate keeps the Office
        // capability unqualified until the rebuilt framework is pinned.
        var requirement = OfficeRenderRequirement.forDocument(
            pathExtension: session.workingURL.pathExtension)
        if requirement == .visibleRenderRequired, !hostSupportsVisibleRender {
            requirement = .openOnly
        }
        renderGate = OfficeVisibleRenderGate(requirement: requirement)
        // The user-facing contract follows the same capability decision: a host
        // without the render contract keeps the open-only readiness, so such a
        // session can never be told to wait for a signal that host cannot send.
        openingPolicy = OfficeOpeningPolicy(
            requiresVisibleRender: requirement == .visibleRenderRequired,
            readOnly: readOnly)
        // A host that cannot report a painted surface keeps the previous
        // open-settled cover trigger; a host with the contract waits for the
        // real fenced signal (see `coverRenderObserved`).
        coverRenderObserved = !hostSupportsVisibleRender
        renderUnverified = false
        recordStage("render.gate", ["requirement": requirement == .visibleRenderRequired
                                        ? "visibleRenderRequired" : "openOnly",
                                    "generation": String(generation)])
        // Build 233 R3: the pinned host reports an editor web-content-process
        // death through its own upstream navigation delegate (never a stolen
        // delegate). The engine session cannot recover in place; the bounded
        // recoverable failure keeps the working copy and remounts on retry.
        if native.responds(to: NSSelectorFromString("setOnWebContentProcessTerminated:")) {
            let terminated: @convention(block) () -> Void = { [weak self, weak native] in
                Task { @MainActor in
                    guard let self, let native, self.controller === native,
                          self.openGeneration.isCurrent(generation), !self.runtimeFailed else { return }
                    self.runtimeFailed = true
                    self.cancelOpenWatchdog()
                    self.cancelRenderWatchdog()
                    self.resolveEnginePermission(nil)
                    self.recordStage("host.webContent.terminated",
                                     ["generation": String(generation)],
                                     withMemory: true)
                    self.fail(OfficeRenderFailure.webContentProcessTerminated())
                }
            }
            _ = native.perform(NSSelectorFromString("setOnWebContentProcessTerminated:"),
                               with: terminated as AnyObject)
        }
        if native.responds(to: NSSelectorFromString("setOnPrintRequested:")) {
            let printRequested: @convention(block) () -> Void = { [weak self, weak native] in
                Task { @MainActor in
                    guard let self, let native, self.controller === native,
                          self.openGeneration.isCurrent(generation), !self.runtimeFailed else { return }
                    guard self.canAct, self.documentActionsReady else {
                        self.error = OfficeInkText.t("文档正忙，请稍后重试打印。", "The document is busy. Try printing again shortly.")
                        return
                    }
                    self.printRequestGeneration &+= 1
                }
            }
            _ = native.perform(NSSelectorFromString("setOnPrintRequested:"), with: printRequested as AnyObject)
        }
        if native.responds(to: NSSelectorFromString("setOnStageEvent:")) {
            // The native breadcrumbs carry the host's own session/generation;
            // this session's trace keeps one App correlation identity and the
            // controller/generation guard rejects late callbacks from a
            // replaced or already-failed controller.
            let onStage: @convention(block) (NSDictionary) -> Void = { [weak self, weak native] event in
                Task { @MainActor in
                    guard let self, let native, self.controller === native,
                          self.openGeneration.isCurrent(generation), !self.runtimeFailed else { return }
                    self.recordNativeStage(event as? [String: Any] ?? [:])
                }
            }
            _ = native.perform(NSSelectorFromString("setOnStageEvent:"), with: onStage as AnyObject)
        }
        if hostSupportsVisibleRender {
            // Installed through the runtime selectors: the framework is pinned
            // separately from this source, so the app must keep compiling
            // against a host that predates the visible-render contract (see
            // `hostSupportsVisibleRender`). Each callback fires at most once;
            // a late real paint may follow the bounded unverified notice.
            // Neither callback is an open or save event.
            let ready: @convention(block) (NSString?, TimeInterval) -> Void = { [weak self, weak native] docType, elapsed in
                Task { @MainActor in
                    // Reachability of this repair, per watchdog state: the
                    // render watchdog and the host's bounded render failure
                    // both settle into `markRenderUnverified()` and never set
                    // `runtimeFailed`, so a late real paint passes this guard
                    // and `visibleRenderObserved()` repairs the gate from
                    // `.failed`. The open watchdog, a runtime-death notice
                    // and an unexpected engine close set `runtimeFailed` and
                    // are terminal by design (the only outcomes with explicit
                    // recovery, never an auto-revive); a dead runtime cannot
                    // produce a paint, so the guard never blocks a repair
                    // that could actually arrive.
                    guard let self, let native, self.controller === native,
                          self.openGeneration.isCurrent(generation), !self.runtimeFailed else { return }
                    self.cancelRenderWatchdog()
                    guard self.renderGate?.visibleRenderObserved() == .ready else { return }
                    // A real paint always wins, including after a bounded
                    // unverified outcome: a slow render is never a failure.
                    if var policy = self.openingPolicy {
                        _ = policy.renderObserved()
                        self.openingPolicy = policy
                    }
                    self.renderUnverified = false
                    self.phase = .ready
                    self.coverRenderObserved = true
                    #if DEBUG
                    OfficeTouchQualificationProbe.shared.installIfNeeded(for: native)
                    #endif
                    var facts = Self.hostRenderDiagnostics(native)
                    facts["docType"] = (docType as String?) ?? "unknown"
                    facts["elapsed"] = String(format: "%.1f", elapsed)
                    facts["generation"] = String(generation)
                    self.recordStage("engine.visibleRender", facts, withMemory: true)
                }
            }
            _ = native.perform(NSSelectorFromString("setOnVisibleRenderReady:"), with: ready as AnyObject)
            let failed: @convention(block) (NSError) -> Void = { [weak self, weak native] error in
                Task { @MainActor in
                    guard let self, let native, self.controller === native,
                          self.openGeneration.isCurrent(generation), !self.runtimeFailed else { return }
                    self.cancelRenderWatchdog()
                    guard self.renderGate?.hostFailed() == .failed else { return }
                    // The host's bounded outcome is the engine's own report that
                    // no paint was observed. The mounted surface stays usable
                    // with a visible, recoverable notice (retry/recovery); the
                    // retained working copy is never touched.
                    var facts = Self.hostRenderDiagnostics(native)
                    facts["code"] = String(error.code)
                    facts["generation"] = String(generation)
                    self.recordStage("engine.visibleRenderFailed", facts)
                    self.markRenderUnverified()
                }
            }
            _ = native.perform(NSSelectorFromString("setOnVisibleRenderFailed:"), with: failed as AnyObject)
        }
        startOpenWatchdog(for: native, readOnly: readOnly)
        // Readiness is claimed from the permission callback, not the raw
        // working-copy event: the host verifies the engine's actual backing
        // permission (and follows the guarded edit entry for an editable
        // session) before it reports. The plain open event only reports a hard
        // failure here.
        native.onWorkingCopyOpened = { [weak self, weak native] success in
            guard let self, let native, self.controller === native,
                  self.openGeneration.isCurrent(generation), !self.runtimeFailed else { return }
            if !success {
                self.cancelOpenWatchdog()
                self.resolveEnginePermission(nil)
                self.fail(CocoaError(.fileReadCorruptFile))
            }
        }
        native.onWorkingCopyOpenedWithPermission = { [weak self, weak native] success, readOnly in
            guard let self, let native, self.controller === native,
                  self.openGeneration.isCurrent(generation), !self.runtimeFailed else { return }
            self.recordStage("engine.open", ["success": success ? "true" : "false",
                                             "engineReadOnly": readOnly ? "true" : "false",
                                             "requestedReadOnly": native.isReadOnly ? "true" : "false",
                                             "generation": String(generation)],
                             withMemory: true)
            // The host's own bounded render-probe facts at the open report:
            // engine type, tile/canvas counters, probe stage/attempts and the
            // edit-entry bookkeeping. This is what makes a PPT/Excel open that
            // never produces a visible render attributable from the export.
            self.recordStage("host.renderDiagnostics", Self.hostRenderDiagnostics(native))
            self.engineSessionReadOnly = readOnly
            self.resolveEnginePermission(readOnly)
            if !success {
                self.cancelOpenWatchdog()
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
            // The open event is not render evidence. A presentation stays
            // loading until the host's painted-surface signal arrives, bounded
            // by the host deadline and this session's render watchdog; the
            // bounded outcome is the recoverable notice, never a dead end.
            if var policy = self.openingPolicy {
                _ = policy.openSettled()
                self.openingPolicy = policy
            }
            let state = self.renderGate?.openSettled() ?? .ready
            if state == .ready {
                self.cancelOpenWatchdog()
                self.phase = .ready
                #if DEBUG
                OfficeTouchQualificationProbe.shared.installIfNeeded(for: native)
                #endif
            } else {
                self.cancelOpenWatchdog()
                self.startRenderWatchdog(for: native)
            }
        }
        native.onEnginePermissionChanged = { [weak self, weak native] readOnly in
            guard let self, let native, self.controller === native,
                  self.openGeneration.isCurrent(generation) else { return }
            self.engineSessionReadOnly = readOnly
            self.resolveEnginePermission(readOnly)
            if !readOnly, !native.isReadOnly, self.readOnly {
                self.readOnly = false
                self.editUnavailableReason = nil
            }
        }
        native.onClosed = { [weak self, weak native] _ in
            guard let self, let native, self.controller === native,
                  self.openGeneration.isCurrent(generation), !self.expectedClose else { return }
            self.runtimeFailed = true
            self.recordStage("engine.closed.unexpected")
            self.error = OfficeInkText.t(
                "文档已被文档引擎关闭；编辑副本已保留，可在“保留的文档”中恢复。",
                "The document engine closed the document. Your editing copies were retained and can be recovered under Retained Documents.")
            self.phase = .failed
        }
        try OfficeExplicitSaveBridge.installEmbeddedControls(controller: native)
        // The validated command adapter (AI/host edits) is a document-start
        // user script; without this injection the engine page has no dispatch
        // function and every command dispatch fails as an invalid response.
        try OfficeCommandBridge.install(controller: native)
        if !readOnly {
            // One autosave coordinator per mounted editable generation.
            // Signals (the engine's own accepted-content modified edge, raw
            // persistence hints, lifecycle exits) only schedule a debounced
            // RECHECK; the transaction is the single serialized
            // verified-flush -> draft commit -> async Notes owner CAS
            // promotion owned by the installed document owner.
            let controllerID = ObjectIdentifier(native)
            let boundWorkingCopy = session.workingURL.path
            let coordinator = OfficeAutosaveCoordinator(
                binding: OfficeAutosaveCoordinator.Binding(
                    generation: generation,
                    controllerID: controllerID,
                    workingCopyPath: boundWorkingCopy,
                    sessionCorrelationID: stageSessionID),
                signals: OfficeAutosaveSignals(
                    sessionState: { [weak self] in
                        guard let self, !self.released else { return .closed }
                        guard self.openGeneration.isCurrent(generation), self.controller === native else { return .closed }
                        if self.runtimeFailed || self.phase == .failed { return .notReady }
                        if self.operating || self.phase != .ready { return .busy }
                        if self.readOnly || !(self.renderGate?.permitsSave ?? true)
                            || self.engineBatchRestoreFailed { return .notReady }
                        return .ready
                    },
                    fenceCurrent: { [weak self] in
                        guard let self, !self.released, !self.releaseRequested else { return false }
                        return self.openGeneration.isCurrent(generation)
                            && self.controller.map { ObjectIdentifier($0) } == controllerID
                            && self.session?.workingURL.path == boundWorkingCopy
                    },
                    recordStage: { [weak self] stage, facts in
                        self?.recordOwnerStage(stage, facts)
                    },
                    lastFlushError: { [weak self] in
                        self?.error
                    }))
            autosaveCoordinator?.invalidate()
            autosaveCoordinator = coordinator
            coordinator.installOwner(autosaveOwner)
            // Raw engine/autosave persistence event: explicitly NOT proof.
            // It only schedules the debounced recheck against the real dirty
            // truth (working-copy difference + ModifiedStatus latch).
            native.onWorkingCopySaved = { [weak coordinator] success in
                coordinator?.recheck(reason: success ? "workingCopySaved" : "workingCopySaveHint")
            }
            explicitSaveBridge = try OfficeExplicitSaveBridge(controller: native) { [weak self, weak native] in
                guard let self, let native, self.controller === native else { return false }
                if let coordinator = self.autosaveCoordinator, coordinator.hasOwner {
                    // The engine's own Save entries (toolbar, file menu,
                    // keyboard dispatcher) serialize with the debounce and
                    // assistant transactions: one owner transaction flushes
                    // the working copy/draft AND promotes the Notes revision.
                    let proof = await coordinator.requestTransaction(reason: "engineSave")
                    return proof.isCommittedState
                }
                return await self.saveInPlace()
            }
            explicitSaveBridge?.onDocumentModified = { [weak coordinator] in
                coordinator?.recheck(reason: "modified")
            }
        } else {
            autosaveCoordinator?.invalidate()
            autosaveCoordinator = nil
        }
        controller = native
        #else
        // The pinned native engine is linked into iphoneos builds only. This is
        // the exact first missing stage when the App runs without it (iOS
        // Simulator and host-less build variants): intent and working copy are
        // local, and nothing after the controller mount exists to observe.
        recordStage("engine.unavailable", ["host": "native-office",
                                           "build": "without-native-office",
                                           "format": session.workingURL.pathExtension.lowercased()])
        throw CocoaError(.featureUnsupported)
        #endif
    }

    #if canImport(FloeOfficeNative)
    /// Bounded, content-free snapshot of the pinned host's own render
    /// diagnostics (document type, tile/canvas counters, probe stage and the
    /// edit-surface paint evidence). The host builds this dictionary from
    /// engine facts only — never document text, paths or bytes. An older host
    /// that does not expose the selector yields an empty snapshot.
    static func hostRenderDiagnostics(_ native: FloeOfficeNativeViewController) -> [String: String] {
        guard native.responds(to: NSSelectorFromString("renderDiagnostics")),
              let raw = native.perform(NSSelectorFromString("renderDiagnostics"))?
                  .takeUnretainedValue() as? [String: Any] else { return [:] }
        var facts: [String: String] = [:]
        for (key, value) in raw {
            switch value {
            case let number as NSNumber: facts[key] = number.stringValue
            case let text as String: facts[key] = text
            default: continue
            }
        }
        return facts
    }
    #endif
    private func closeController() async throws {
        guard let controller else { return }
        // Generation teardown: cancel the autosave debounce/pass. An explicit
        // caller awaiting the in-flight transaction receives a truthful
        // `cancelled` proof; no callback can touch a reopened or other document.
        autosaveCoordinator?.invalidate()
        autosaveCoordinator = nil
        #if DEBUG
        OfficeTouchQualificationProbe.shared.removeTouchTelemetry(for: controller)
        #endif
        cancelOpenWatchdog()
        cancelRenderWatchdog()
        renderGate = nil
        resolveEnginePermission(nil)
        // No view means the upstream viewWillAppear has not opened a document.
        // Do not load a WebView merely to close an abandoned preview request.
        guard controller.isViewLoaded else {
            recordStage("close.skippedUnmounted")
            invalidateInkApply()
            explicitSaveBridge?.invalidate()
            explicitSaveBridge = nil
            self.controller = nil
            return
        }
        phase = .closing
        expectedClose = true
        defer { expectedClose = false }
        recordStage("close.started")
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
                recordStage(message == nil ? "close.acked" : "close.failed",
                            message == nil ? [:] : ["reason": "engine-reported"])
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
                recordStage("close.timedOut")
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
        recordStage("session.failed", ["domain": (error as NSError).domain,
                                       "code": String((error as NSError).code)])
        self.error = error.localizedDescription
        phase = .failed
    }
}

/// Feature-owned containment keeps the engine session stable while its UIKit
/// geometry follows the CURRENT SwiftUI allocation, including keyboard exits.
@MainActor
final class OfficeKeyboardLayoutHostController: UIViewController {
    let officeController: UIViewController
    var claimsKeyboardOnEntry: Bool
    private var completedEntryHandoff = false
    private var viewportRefreshScheduled = false
    private var lastHostedSize = CGSize.zero
    private(set) var viewportRefreshCount = 0

    init(controller: UIViewController, claimsKeyboardOnEntry: Bool) {
        self.officeController = controller
        self.claimsKeyboardOnEntry = claimsKeyboardOnEntry
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // A session has one live surface. Never detach it from another
        // presenter merely because SwiftUI asks to build a second host.
        guard officeController.parent == nil else {
            let message = UILabel()
            message.text = OfficeInkText.t("文档已在其他位置打开，请先关闭原来的编辑窗口。",
                                          "This document is already open. Close its other editor first.")
            message.numberOfLines = 0; message.textAlignment = .center
            message.accessibilityIdentifier = "office.editor.alreadyMounted"
            message.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(message)
            NSLayoutConstraint.activate([
                message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
                message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
                message.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            return
        }
        addChild(officeController)
        let content = officeController.view!
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: view.topAnchor),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        officeController.didMove(toParent: self)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardSettled(_:)),
                                               name: UIResponder.keyboardDidChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardSettled(_:)),
                                               name: UIResponder.keyboardDidHideNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        if let window = viewIfLoaded?.window { handOffExternalResponder(in: window) }
        super.viewWillAppear(animated)
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if let window = view.window { handOffExternalResponder(in: window) }
        scheduleViewportRefresh()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        if size.width > 0, size.height > 0, size != lastHostedSize {
            lastHostedSize = size
            scheduleViewportRefresh()
        }
    }

    /// Never use UIApplication-wide resign: another window or the Office
    /// editor's own text input must retain its first responder.
    func handOffExternalResponder(in window: UIWindow) {
        guard claimsKeyboardOnEntry, !completedEntryHandoff, officeController.parent === self,
              viewIfLoaded?.window === window else { return }
        completedEntryHandoff = true
        func firstResponder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for child in view.subviews {
                if let found = firstResponder(in: child) { return found }
            }
            return nil
        }
        guard let responder = firstResponder(in: window),
              !responder.isDescendant(of: officeController.view) else { return }
        _ = responder.resignFirstResponder()
        scheduleViewportRefresh()
    }

    @objc private func keyboardSettled(_ notification: Notification) {
        guard let window = viewIfLoaded?.window, window.isKeyWindow,
              (notification.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool) != false else { return }
        // SwiftUI still owns keyboard safe-area avoidance and bottom toolbars.
        // After its transition, ask UIKit/WebKit to consume the real new bounds.
        scheduleViewportRefresh()
    }

    func scheduleViewportRefresh() {
        guard !viewportRefreshScheduled else { return }
        viewportRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.viewportRefreshScheduled = false }
            guard self.isViewLoaded, self.officeController.parent === self else { return }
            // Ask the presenting SwiftUI allocation to settle as well as the
            // child. Do not replace its frame with window bounds: an Office
            // text keyboard and feature toolbars still legitimately reduce it.
            let container = self.parent?.viewIfLoaded ?? self.view.superview
            container?.setNeedsUpdateConstraints()
            container?.setNeedsLayout()
            self.view.invalidateIntrinsicContentSize()
            self.view.setNeedsUpdateConstraints()
            self.view.setNeedsLayout()
            container?.layoutIfNeeded()
            self.view.layoutIfNeeded()
            self.officeController.view.setNeedsLayout()
            self.officeController.view.layoutIfNeeded()
            guard self.view.bounds.width > 0, self.view.bounds.height > 0 else { return }
            self.viewportRefreshCount += 1
            if let webView = OfficeExplicitSaveBridge.findWebView(in: self.officeController.view) {
                webView.setNeedsLayout(); webView.layoutIfNeeded()
                // Standard DOM resize only: no engine command, zoom, content
                // inset reset, document mutation or private WebKit selector.
                webView.evaluateJavaScript("window.dispatchEvent(new Event('resize'));") { _, _ in }
            }
        }
    }

    func detachOfficeController() {
        guard officeController.parent === self else { return }
        officeController.willMove(toParent: nil)
        officeController.view.removeFromSuperview()
        officeController.removeFromParent()
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

private struct OfficeControllerSurface: UIViewControllerRepresentable {
    let controller: UIViewController
    let claimsKeyboardOnEntry: Bool
    func makeUIViewController(context: Context) -> OfficeKeyboardLayoutHostController {
        OfficeKeyboardLayoutHostController(controller: controller, claimsKeyboardOnEntry: claimsKeyboardOnEntry)
    }
    func updateUIViewController(_ host: OfficeKeyboardLayoutHostController, context: Context) {
        host.claimsKeyboardOnEntry = claimsKeyboardOnEntry
    }
    static func dismantleUIViewController(_ host: OfficeKeyboardLayoutHostController, coordinator: ()) {
        host.detachOfficeController()
    }
}

struct OfficeDocumentSurface: View {
    @ObservedObject var session: OfficeFileSession
    var ownsInputFocusOnEntry = false
    /// Owning-surface retry, invoked after `recoverFailedSession()` returns.
    /// A pre-mount open failure only re-arms the session to `.idle`; the
    /// surface's own open task has already run and will not re-run while the
    /// surface stays mounted, so the owner must re-drive its resolve+open
    /// loader or the surface returns to an unowned spinner. Owners whose
    /// loader re-runs on their own (workspace preview's `task(id:)`, Notes'
    /// explicit `prepare(force:)`) leave this nil; the IDE tab, whose loader
    /// runs once per appearance, injects it. A mounted recovery keeps its
    /// controller, and the loader's open guard makes the retry a no-op there.
    var retryOpen: (() -> Void)? = nil
    var body: some View {
        ZStack {
            if let controller = session.controller {
                OfficeControllerSurface(controller: controller, claimsKeyboardOnEntry: ownsInputFocusOnEntry)
                    .id(ObjectIdentifier(controller))
                    .accessibilityIdentifier(session.readOnly ? "office.preview.native" : "office.editor.native")
                    .accessibilityValue(session.documentActionsReady
                        ? OfficeInkText.t("文档已就绪", "Document ready")
                        : OfficeInkText.t("文档尚未就绪", "Document not ready"))
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
                            Task {
                                _ = await session.recoverFailedSession()
                                retryOpen?()
                            }
                        }
                    }
                }
            } else if session.phase != .ready {
                ProgressView(session.phase == .saving ? "workspace.office_document_editor_view.saving" : session.phase == .closing ? "workspace.office_document_editor_view.closing" : session.phase == .insertingAttachment ? "workspace.office_workspace_attachment_picker.inserting_attachment" : session.phase == .readingAttachments ? "workspace.office_attachment_list_view.reading_attachment" : "workspace.office_document_editor_view.opening_document")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            #if DEBUG
            // Launch-argument-gated injected-pen fixture seam for the actual
            // Main-App saved-ink library-card UI loop acceptance. Compiles
            // out of release builds and renders nothing at all without the
            // explicit fixture family; the passive office.touch-qualification
            // probe family is disjoint and untouched. See OfficeInkCardSeam.
            OfficeInkCardSeamOverlay(session: session)
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FloeTheme.readingSurface)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if session.renderUnverified, let warning = session.openingWarning {
                    OfficeRenderUnverifiedBanner(session: session, warning: warning)
                }
                if session.readOnly && session.hasUncommittedChanges {
                    Label("workspace.office_document_editor_view.changes_have_not_been_saved_to", systemImage: "doc.badge.clock")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity).padding(8)
                        .background(.regularMaterial)
                }
            }
        }
    }
}

/// Visible, recoverable notice for a presentation that settled without the
/// host's visible-render evidence. Every owning surface (Workspace preview,
/// IDE tab, Notes, fullscreen editor) hosts `OfficeDocumentSurface`, so this is
/// the one place the bounded outcome is shown. It never blocks the mounted
/// engine surface, never claims a verified paint, and always offers an exit:
/// retry a truthful preview of the retained working copy, or dismiss and keep
/// looking at the current surface.
private struct OfficeRenderUnverifiedBanner: View {
    @ObservedObject var session: OfficeFileSession
    let warning: OfficeOpeningWarning

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(OfficeInkText.t(warning.titleZh, warning.titleEn), systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            Text(OfficeInkText.t(warning.detailZh, warning.detailEn))
                .font(.footnote)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                if warning.actions.contains(.retryPreview) || warning.actions.contains(.recover) {
                    Button(OfficeInkText.t("重试预览", "Retry Preview")) {
                        Task { _ = await session.recoverFailedSession() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("office.render.retry")
                }
                if warning.actions.contains(.dismiss) {
                    Button(OfficeInkText.t("继续查看", "Keep Viewing")) {
                        session.dismissRenderUnverified()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("office.render.dismiss")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("office.render.unverified")
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

/// Appears only for a proposal belonging to this exact mounted document.
private struct OfficePendingProposalReview: View {
    @ObservedObject var session: OfficeFileSession
    @EnvironmentObject private var environment: AppEnvironment
    @State private var proposals: [OfficeCommandProposal] = []
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        Group {
            if !proposals.isEmpty, session.proposalReviewBinding != nil {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(proposals, id: \.id) { proposal in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(proposal.summary).font(.callout)
                            Text(proposal.targetSummary).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button(OfficeInkText.t("应用修改", "Apply edit")) {
                                    Task { await decide(proposal, apply: true) }
                                }.buttonStyle(.borderedProminent)
                                Button(OfficeInkText.t("放弃", "Discard"), role: .destructive) {
                                    Task { await decide(proposal, apply: false) }
                                }.buttonStyle(.bordered)
                            }.frame(minHeight: 44)
                        }
                    }
                    if let failure { Text(failure).font(.footnote).foregroundStyle(.secondary) }
                }
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar).disabled(busy || !session.commandReady)
                .accessibilityIdentifier("office.assistant.pendingReview")
            }
        }
        .task(id: session.proposalReviewBinding) { await refresh() }
        .onChange(of: session.phase) { _, _ in Task { await refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: OfficeCommandCenter.proposalsDidChange)
            .receive(on: DispatchQueue.main)) { _ in
            Task { await refresh() }
        }
    }

    @MainActor private func refresh() async {
        guard let binding = session.proposalReviewBinding else {
            proposals = []; failure = nil; return
        }
        let pending = await environment.officeCommandCenter.pendingProposals(binding: binding)
        guard !Task.isCancelled, session.proposalReviewBinding == binding else { return }
        proposals = pending
        if pending.isEmpty { failure = nil }
    }

    @MainActor private func decide(_ proposal: OfficeCommandProposal, apply: Bool) async {
        guard !busy, let binding = session.proposalReviewBinding else { return }
        busy = true
        failure = nil
        defer { busy = false }
        let center = environment.officeCommandCenter
        // Discard removes the stored origin; capture it before either decision.
        let owner = await center.proposalOwnerConversation(proposalID: proposal.id)
        guard session.proposalReviewBinding == binding else { return }
        do {
            var sha256: String?
            if apply {
                let receipt = try await center.approveAndApply(proposal: proposal, expectedBinding: binding)
                sha256 = receipt.sha256
            } else {
                try await center.discardProposal(id: proposal.id, expectedBinding: binding)
            }
            if let owner {
                try? await environment.conversationCenter.recordProposalDecision(
                    conversationID: owner, proposalID: proposal.id,
                    decision: apply ? "applied" : "rejected", revision: nil, sha256: sha256)
            }
        } catch {
            if session.proposalReviewBinding == binding { failure = error.localizedDescription }
        }
        await refresh()
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
    /// Host-owned prepare-for-close allowance for the read-only surface.
    /// Notes installs it so a Back intent arriving while passive cover work
    /// runs is accepted, coalesced and parked on the host's FULL preview
    /// result (native export + PNG render + cache + immutable source/
    /// revision binding) before the unchanged truthful close path runs.
    /// Default nil: FilePreview, IDE, standalone, recovery and qualification
    /// hosts keep the previous behavior bit-for-bit — same drop-on-busy
    /// disable, no coalescing, no wait, no carve-out.
    var prepareForPassiveClose: (@MainActor () async -> Bool)? = nil
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var environment: AppEnvironment
    @State private var confirmingDiscard = false
    @State private var confirmingClose = false
    @State private var comparingVersions = false
    @State private var convertedExport: OfficeConvertedExport?
    @State private var pdfExportPurpose: OfficePDFExportPurpose?
    @State private var export: DocumentExportSnapshot?
    @State private var savedCopyNotice = false
    @State private var exportSucceeded = false
    @State private var choosingAttachment = false
    @State private var choosingWorkspaceAttachment = false
    @State private var showingAttachments = false
    @State private var showingInkControls = false
    @State private var attachmentError: String?
    /// Coalesces the WHOLE retained read-only close intent — host
    /// preparation, the existing close path and dismissal — for the
    /// duration of one `saveAndDismiss`, so a repeat that arrives after the
    /// export flag cleared (or while the truthful close already runs) can
    /// neither start a second dismissal nor bypass the wait. The claim is
    /// released at function exit, including refusals, so a retry tap on
    /// the still-mounted surface always reaches the fresh state.
    @State private var passiveCloseIntentInFlight = false
    /// In-flight share snapshot; reclaimed by `finishSaveCopy()` on dismiss.
    @State private var shareSnapshot: DocumentExportSnapshot?

    var body: some View {
        OfficeDocumentSurface(session: session, ownsInputFocusOnEntry: true)
            .navigationTitle((relativePath as NSString).lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .background {
                // Command-S saves in place against the original workspace
                // file (same verified commit as the engine's own toolbar
                // save) without dismissing the editor. Hidden from the UI;
                // only the keyboard shortcut is exposed. For a Notes-owned
                // session the same explicit intent runs the one serialized
                // owner transaction (flush -> draft -> Notes CAS promotion),
                // so it can never double-promote with the idle debounce.
                Button {
                    Task {
                        if session.autosaveActive {
                            _ = await session.requestAutosaveTransaction(reason: "commandS")
                        } else {
                            _ = await session.saveInPlace()
                        }
                    }
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
                    // Give the header its own accessibility container. An
                    // identifier on a virtual VStack otherwise propagates to
                    // its buttons and hides their Edit/Back identifiers.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("office.editor.header")
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                OfficePendingProposalReview(session: session)
            }
            .interactiveDismissDisabled()
            .task {
                // Build 233 R2 seam: install the AppEnvironment-backed idle-model
                // shed before the first intent. The implementation releases only
                // a physically idle resident model; it never unloads active
                // inference, a benchmark or a retained tool continuation, and a
                // refused shed leaves the Office open unchanged.
                session.shedIdleLocalModelForOffice = { reason in
                    await environment.shedIdleLocalModelForOffice(reason: reason)
                }
                session.officeDeviceFontFacts = { await environment.officeDeviceFontFacts() }
                session.useInkPreferences(
                    stableIdentity: stableInkIdentity,
                    workspaceIdentity: environment.workspaceCenter.currentWorkspace?.id.uuidString,
                    documentKey: relativePath)
                // Register the live document for the shared Office command
                // center (document.office.edit), so proposals/apply target this
                // exact workspace file and owner.
                session.registerLiveDocument(
                    relativePath: relativePath,
                    root: environment.workspaceCenter.fileService?.guardResolver.rootURL,
                    conversationID: nil)
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
            .sheet(item: $pdfExportPurpose) { purpose in
                OfficePDFExportOptionsView(purpose: purpose,
                    prepare: { try await session.preparePDFExport() },
                    export: { prepared, choices, cancellation in
                        try await session.exportConfiguredPDF(prepared, choices: choices, cancellation: cancellation)
                    })
            }
            .onChange(of: session.printRequestGeneration) { _, _ in
                guard pdfExportPurpose == nil else { return }
                pdfExportPurpose = .printDocument
            }
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
            .alert("workspace.office_workspace_attachment_picker.could_not_insert_the_attachment", isPresented: Binding(
                get: { attachmentError != nil }, set: { if !$0 { attachmentError = nil } })) {
                    Button("workspace.office_document_editor_view.ok", role: .cancel) { attachmentError = nil }
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
            .alert("workspace.office_document_editor_view.copy_saved", isPresented: $savedCopyNotice) {
                Button("workspace.office_document_editor_view.ok", role: .cancel) {}
            } message: { Text("workspace.office_document_editor_view.this_edit_still_matches_the_original") }
            .alert("workspace.office_document_editor_view.could_not_save", isPresented: Binding(
                get: { session.error != nil && session.phase == .ready },
                set: { if !$0 { session.error = nil } })) {
                    Button("workspace.office_document_editor_view.keep_editing", role: .cancel) { session.error = nil }
                    if session.hasSaveConflict {
                        Button("edit.conflict.compareVersions") { session.error = nil; comparingVersions = true }
                    }
                    Button("workspace.office_document_editor_view.save_a_copy") {
                        session.error = nil
                        Task { export = await session.prepareSaveCopy() }
                    }
                    if onSaved == nil {
                        Button("workspace.office_document_editor_view.keep_changes_and_return") {
                            session.error = nil
                            Task { if await session.keepChangesAndReturn() { dismissEditor() } }
                        }
                    }
                } message: { Text(session.error ?? "") }
            .confirmationDialog("workspace.office_document_editor_view.discard_unsaved_changes", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("engineering.cad.discard", role: .destructive) {
                    Task { if await session.discardAndReturn() { dismissEditor() } }
                }
                Button("workspace.office_document_editor_view.keep_editing", role: .cancel) {}
            }
            .confirmationDialog("workspace.office_document_editor_view.save_changes_before_closing", isPresented: $confirmingClose, titleVisibility: .visible) {
                Button("ide.save.close") {
                    Task { await saveAndDismiss() }
                }
                Button("engineering.cad.discard", role: .destructive) {
                    Task { if await session.discardAndReturn() { dismissEditor() } }
                }
                Button("workspace.workspace_canvas_view.cancel", role: .cancel) {}
            } message: { Text("workspace.office_document_editor_view.save_writes_changes_to_the_original") }
    }

    private var backButton: some View {
        Button {
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
        } label: {
            Label("settings.document_recovery_list_view.back", systemImage: "chevron.left")
                .labelStyle(.iconOnly)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        // A passive read-only cover export changes no user data, so it must
        // not drop the primary exit — but only for hosts that installed the
        // prepare-for-close allowance, which park the intent on the host's
        // full preview settlement instead of racing it. Without the callback
        // the disable is bit-identical to before for every other host; with
        // it, saves, attachments, external refreshes and editable sessions
        // still keep the previous disable exactly.
        .disabled(!session.canAct && session.phase != .failed && !(session.readOnly && session.coverExportInFlight && prepareForPassiveClose != nil))
        .accessibilityIdentifier("office.editor.back")
        .accessibilityHint(session.phase == .failed ? "workspace.office_document_editor_view.keep_an_edited_copy_and_close" : "workspace.office_document_editor_view.save_document_and_return_to_preview")
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
                Button("workspace.office_document_editor_view.choose_from_workspace", systemImage: "folder") { choosingWorkspaceAttachment = true }
                Button("workspace.office_document_editor_view.choose_from_files", systemImage: "doc") { choosingAttachment = true }
                Divider()
                Button("workspace.office_document_editor_view.view_document_attachments", systemImage: "paperclip") { showingAttachments = true }
            } label: { Label("settings.data_management_view.attachments", systemImage: "paperclip").frame(minWidth: 44, minHeight: 44) }
                .disabled(!session.canAct)
                .accessibilityIdentifier("office.editor.insertAttachment")
        }
        if session.supportsPresentation {
            Button {
                Task { do { try await session.startPresentation() } catch { session.error = error.localizedDescription } }
            } label: { Label("workspace.office_document_editor_view.slide_show", systemImage: "play.rectangle").frame(minWidth: 44, minHeight: 44) }
                .disabled(!session.canAct).accessibilityIdentifier("office.presentation.start")
        }
    }

    @ViewBuilder private var drawingActions: some View {
        if session.supportsDrawing {
            Button {
                Task {
                    do { try await session.toggleDrawing() }
                    catch { session.error = error.localizedDescription }
                }
            } label: {
                Label(OfficeInkText.t(session.drawingMode ? "停止书写" : "开始书写",
                                      session.drawingMode ? "Stop drawing" : "Start drawing"),
                      systemImage: session.drawingMode ? "pencil.tip.crop.circle.fill" : "pencil.tip")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .tint(session.drawingMode ? Color.accentColor : Color.primary)
            .disabled(!session.canAct)
            .accessibilityValue(OfficeInkText.t(session.drawingMode ? "已开启" : "已关闭",
                                               session.drawingMode ? "On" : "Off"))
            .accessibilityIdentifier("office.drawing.toggle")
            Button { showingInkControls = true } label: {
                Label(OfficeInkText.t("画笔设置", "Pen settings"), systemImage: "slider.horizontal.3")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .disabled(!session.canAct)
            .accessibilityIdentifier("office.drawing.settings")
            .popover(isPresented: $showingInkControls, arrowEdge: .top) {
                OfficeInkControlPanel(session: session, ink: session.inkPreferences) {
                    showingInkControls = false
                }
                .presentationCompactAdaptation(.popover)
            }
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
                Button("workspace.office_document_editor_view.save_and_return") { Task { await saveAndDismiss() } }
            }
            if !session.exportFormats.isEmpty {
                Menu("workspace.office_document_editor_view.export_format", systemImage: "square.and.arrow.up") {
                    ForEach(session.exportFormats, id: \.self) { format in
                        Button(format.uppercased()) {
                            if format == "pdf" {
                                pdfExportPurpose = .export
                                return
                            }
                            Task {
                                do { convertedExport = .init(url: try await session.exportDocument(format: format)) }
                                catch { session.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }
            if session.exportFormats.contains("pdf") {
                Button(OfficeInkText.t("打印…", "Print…"), systemImage: "printer") {
                    pdfExportPurpose = .printDocument
                }
                .accessibilityIdentifier("office.editor.print")
            }
            Button("workspace.office_document_editor_view.save_a_copy", systemImage: "doc.on.doc") { Task { export = await session.prepareSaveCopy() } }
            // Explicit share of the current document from every Office
            // surface (preview and edit): a verified snapshot copy goes to the
            // system share sheet; the original file is never handed out.
            Button(OfficeInkText.t("分享…", "Share…"), systemImage: "square.and.arrow.up") {
                Task { shareSnapshot = await session.prepareShareCopy() }
            }
            .accessibilityIdentifier("office.editor.share")
            if onSaved == nil, !session.isRemoteSnapshot {
                Button("workspace.office_document_editor_view.keep_changes_and_return") {
                    Task { if await session.keepChangesAndReturn() { dismissEditor() } }
                }
            }
            if !session.isRemoteSnapshot {
                Button("engineering.cad.discard", role: .destructive) { confirmingDiscard = true }
            }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
            .disabled(!session.canAct)
            .accessibilityLabel("workspace.office_document_editor_view.document_actions")
    }

    private var documentActions: some View {
        HStack(spacing: 4) {
            // The preview's single primary action stays visible on compact
            // layouts too; the remaining edit-mode actions keep their existing
            // compact menu placement.
            editAction
            drawingActions
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
        // Host-allowed passive close (read-only surfaces that installed
        // `prepareForPassiveClose`): the whole retained intent — host
        // preparation plus the existing truthful close/dismiss below — is
        // coalesced and fenced. Every other host, and every editable
        // session, skips this entirely and runs the pre-existing path
        // unchanged.
        let prepare = prepareForPassiveClose
        let passiveExitSurface = session.readOnly && prepare != nil
        if passiveExitSurface {
            guard !passiveCloseIntentInFlight else { return }
            passiveCloseIntentInFlight = true
        }
        // The claim covers preparation AND the close/dismiss path: it is
        // released only when this function exits (success, refusal or
        // dismissal), never between the wait and the close.
        defer { if passiveExitSurface { passiveCloseIntentInFlight = false } }
        var passiveFence: OfficeFileSession.PassiveExitFence?
        if passiveExitSurface, let prepare {
            passiveFence = session.capturePassiveExitFence()
            // Wait for the FULL host-owned preview result commit (export,
            // PNG render, cache and immutable source/revision binding), not
            // just the export fence. The host answers instantly when no
            // backfill is running and refuses — keeping the editor mounted
            // with its existing actionable state — on a bounded timeout or
            // a superseded context, so this never waits artificially and
            // never blocks an ordinary opening cancel.
            guard await prepare() else { return }
            // Re-fence after the wait and before any close mutation runs:
            // a canceled intent and a released, teardown-requested,
            // reopened or swapped surface cannot continue.
            guard !Task.isCancelled, let fence = passiveFence,
                  session.passiveExitFenceIsCurrent(fence) else { return }
        }
        // An owning Notes transaction may still reject its resource commit.
        // Keep the native editor mounted until that owner confirms success,
        // so a conflict/error leaves a usable editor and export path.
        let saved = onSaved == nil ? await session.saveAndReturn() : await session.saveInPlace()
        if saved {
            if await onSaved?() ?? true, passiveCloseMayDismiss(passiveFence) { dismissEditor() }
            return
        }
        // The save was refused before it could start — a still-read-only
        // session, a presentation whose render stayed unverified, or a
        // transient operating lock — rather than failing with an error. The
        // primary exit must never dead-end on that refusal. A real save
        // failure already sets `session.error` and keeps the editor mounted
        // so the user can retry, compare versions or export.
        guard session.error == nil else { return }
        if onSaved != nil, !session.readOnly {
            // An owning surface (Notes) still owes its original-document
            // commit after an editable session. Auto-dismissing here would
            // read as "saved" while the immutable resource was never
            // updated, so the retained-copy outcome is surfaced instead and
            // the editor stays mounted for the owner's retry ("重试保存到
            // 手记") or an explicit keep/export through the save alert.
            if session.phase == .ready {
                session.error = OfficeInkText.t(
                    "暂时无法保存；编辑副本已保留，未写回原文件。",
                    "Saving is unavailable right now. Your editing copy was retained; nothing was written back to the original file.")
            }
            return
        }
        // Standalone workspace editor, or a read-only session with no owner
        // commit pending: the bounded persist-and-leave path is truthful —
        // the retained working copy keeps any edits, the original file stays
        // untouched, and nothing claims a save that did not run.
        // The persist-and-leave itself suspends the MainActor for a bounded
        // engine close: re-fence directly before dismissal so a released,
        // teardown-requested or re-opened surface can never be dismissed by
        // this retained intent.
        if await session.keepChangesAndReturn(), passiveCloseMayDismiss(passiveFence) { dismissEditor() }
    }

    /// Directly-before-dismissal fence for a retained read-only close
    /// intent. A nil fence means the intent never entered the passive path
    /// (no host callback, or the surface was editable at entry): the
    /// pre-existing dismissal runs untouched. Otherwise only the intent's
    /// own truthful close — which legitimately released the controller
    /// while it ran — may still dismiss the still-owned mounted surface.
    private func passiveCloseMayDismiss(_ fence: OfficeFileSession.PassiveExitFence?) -> Bool {
        guard let fence else { return true }
        return !Task.isCancelled && session.passiveExitCloseRemainsOwn(fence)
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

/// Compact app-owned pen panel. It only edits Floe's typed stroke settings,
/// never draws a screen-space overlay and never writes Notes/Canvas ink. The
/// header owns the explicit Done action, so closing the popover never depends
/// on a coordinate tap or on toggling the drawing mode.
///
/// Ordinary rows stay inline so the panel is roughly a third shorter than the
/// former fixed 420pt card. Apply acknowledgements and explanatory copy are
/// intentionally absent; only an actionable error can add a row.
private struct OfficeInkControlPanel: View {
    @ObservedObject var session: OfficeFileSession
    let ink: OfficeInkPreferences
    let onDone: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Beyond the default size the inline label/slider/value row can clip its
    /// English label. Stack the label above the slider instead of shrinking
    /// the control or truncating the copy.
    private var usesStackedRows: Bool { dynamicTypeSize >= .xLarge }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if dynamicTypeSize.isAccessibilitySize {
                // Accessibility sizes may exceed the popover's usable height,
                // so only that genuinely constrained case scrolls.
                ScrollView {
                    controls
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 400)
            } else {
                controls
            }
        }
        .frame(idealWidth: 330, maxWidth: 330)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(OfficeInkText.t("画笔设置", "Pen settings"))
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("office.ink.panel")
            Spacer(minLength: 8)
            Button(action: onDone) {
                Text(OfficeInkText.t("完成", "Done"))
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .accessibilityIdentifier("office.ink.done")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            presetRow
            colorRow
            widthRow
            transparencyRow
            if let inkError = session.inkError {
                Label(inkError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("office.ink.error")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
    }

    /// One compact row of real native styles. Each choice writes the preset's
    /// ordinary width/transparency scalars through the same preference API as
    /// the sliders, so no synthetic brush or overlay is involved. The row only
    /// stacks vertically at accessibility sizes, where a single line cannot
    /// keep three readable labels.
    private var presetRow: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 4) { presetButtons }
            } else {
                HStack(spacing: 6) { presetButtons }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("office.ink.type")
        .frame(minHeight: 44)
    }

    @ViewBuilder private var presetButtons: some View {
        ForEach(OfficeInkStylePreset.allCases) { preset in
            let selected = ink.stroke.preset == preset
            Button {
                ink.setPreset(preset)
                reapply()
            } label: {
                Text(preset.title)
                    .font(.subheadline.weight(selected ? .semibold : .regular))
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(selected ? Color.accentColor : Color.primary)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selected ? Color.accentColor.opacity(0.14)
                                           : Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                                          lineWidth: selected ? 2 : 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(preset.title)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("office.ink.type.\(preset.rawValue)")
        }
    }

    private var colorRow: some View {
        Group {
            if usesStackedRows {
                stackedColorRow
            } else {
                // A narrow iPhone popover cannot fit the inline label plus five
                // 44pt targets; fall back to the same stacked layout instead of
                // clipping a swatch.
                ViewThatFits(in: .horizontal) {
                    inlineColorRow
                    stackedColorRow
                }
            }
        }
        .frame(minHeight: 44)
    }

    private var inlineColorRow: some View {
        HStack(spacing: 4) {
            fieldLabel(OfficeInkText.t("颜色", "Color"))
                .frame(width: 80, alignment: .leading)
            swatches
        }
    }

    private var stackedColorRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                fieldLabel(OfficeInkText.t("颜色", "Color"))
                Spacer(minLength: 0)
            }
            swatches
        }
    }

    private var swatches: some View {
        HStack(spacing: 0) {
            ForEach(OfficeInkColor.allCases) { color in
                Button {
                    ink.setColor(color)
                    reapply()
                } label: {
                    Circle()
                        .fill(color.swatch)
                        .frame(width: 24, height: 24)
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

    /// Width keeps both real controls: five one-tap 44pt size dots and the
    /// fine-grained slider. The dots own a compact row; the slider, value and
    /// a real colour/alpha/width preview share the next row. Large text splits
    /// the slider row rather than clipping the value or preview.
    private var widthRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            widthDotRow
            widthSliderRow
        }
        .frame(minHeight: 44)
    }

    private var widthDotRow: some View {
        HStack(spacing: 4) {
            ForEach(OfficeInkWidthPreset.allCases) { preset in
                let selected = abs(ink.stroke.widthMillimeters - preset.rawValue) < 0.01
                Button {
                    ink.setWidthMillimeters(preset.rawValue)
                    reapply()
                } label: {
                    ZStack {
                        Circle()
                            .strokeBorder(selected ? Color.accentColor : Color.clear,
                                          lineWidth: 2)
                            .frame(width: 26, height: 26)
                        Circle()
                            .fill(selected ? Color.accentColor : Color.primary)
                            .frame(width: widthDotDiameter(preset),
                                   height: widthDotDiameter(preset))
                    }
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(preset.title)
                .accessibilityValue(String(format: "%.2f mm", preset.rawValue))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier(preset.accessibilityID)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(OfficeInkText.t("线宽快捷选择", "Width presets"))
        .accessibilityIdentifier("office.ink.widthPresets")
    }

    /// Dot size is driven by the real millimetre value inside the shared
    /// width range, using a square-root curve so both small and large tips
    /// remain visibly distinct. The 44pt target never changes.
    private func widthDotDiameter(_ preset: OfficeInkWidthPreset) -> CGFloat {
        let clamped = OfficeInkStroke.clampedWidth(preset.rawValue)
        let span = OfficeInkStroke.widthRange.upperBound - OfficeInkStroke.widthRange.lowerBound
        let normalized = (clamped - OfficeInkStroke.widthRange.lowerBound) / span
        return 6 + 12 * CGFloat(normalized.squareRoot())
    }

    private var widthSliderRow: some View {
        Group {
            if usesStackedRows {
                VStack(alignment: .leading, spacing: 4) {
                    widthSlider
                    HStack(spacing: 8) {
                        valueText(widthValue)
                        Spacer(minLength: 8)
                        widthPreview
                    }
                }
            } else {
                HStack(spacing: 8) {
                    widthSlider
                    valueText(widthValue)
                        .frame(width: 54, alignment: .trailing)
                    widthPreview
                }
            }
        }
        .frame(minHeight: 44)
    }

    private var widthSlider: some View {
        Slider(value: Binding(get: { ink.stroke.widthMillimeters },
                              set: { ink.setWidthMillimeters($0) }),
               in: OfficeInkStroke.widthRange, step: 0.25,
               onEditingChanged: { editing in if !editing { reapply() } })
            .accessibilityLabel(OfficeInkText.t("线宽", "Width"))
            .accessibilityIdentifier("office.ink.width")
    }

    private var widthValue: String {
        String(format: "%.2f mm", ink.stroke.widthMillimeters)
    }

    /// A short real stroke: the current colour at its real opacity and the
    /// current millimetre width converted to points (72/25.4). It is a preview
    /// only, never a second drawing surface.
    private var widthPreview: some View {
        let points = ink.stroke.widthMillimeters * 72 / 25.4
        let opacity = 1 - Double(ink.stroke.transparencyPercent) / 100
        let color = Color(officeHex: ink.stroke.colorHex).opacity(opacity)
        return ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.secondary.opacity(0.08))
                .frame(width: 48, height: 24)
            Capsule()
                .fill(color)
                .frame(width: 40, height: CGFloat(points))
        }
        .frame(width: 48, height: 44)
        .accessibilityElement()
        .accessibilityLabel(OfficeInkText.t("笔迹预览", "Ink preview"))
        .accessibilityValue("\(widthValue), \(ink.stroke.transparencyPercent)%")
        .accessibilityIdentifier("office.ink.widthPreview")
    }

    private var transparencyRow: some View {
        sliderRow(label: OfficeInkText.t("透明度", "Transparency"),
                  value: "\(ink.stroke.transparencyPercent)%") {
            Slider(value: Binding(
                get: { Double(ink.stroke.transparencyPercent) },
                set: { ink.setTransparencyPercent(Int($0.rounded())) }),
                   in: 0...100, step: 1,
                   onEditingChanged: { editing in if !editing { reapply() } })
                .accessibilityIdentifier("office.ink.transparency")
        }
    }

    private func sliderRow<Control: View>(label: String,
                                          value: String,
                                          @ViewBuilder control: () -> Control) -> some View {
        Group {
            if usesStackedRows {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        fieldLabel(label)
                        Spacer(minLength: 8)
                        valueText(value)
                    }
                    control()
                }
            } else {
                HStack(spacing: 8) {
                    fieldLabel(label)
                        .frame(width: 80, alignment: .leading)
                    control()
                    valueText(value)
                        .frame(width: 54, alignment: .trailing)
                }
            }
        }
        .frame(minHeight: 44)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.medium))
            // Primary keeps the small control labels readable on the popover's
            // material. Hierarchy comes from size/weight, not a faint tint.
            .foregroundStyle(.primary)
            .lineLimit(usesStackedRows ? 2 : 1)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private func reapply() {
        guard session.drawingMode else { return }
        Task { await session.applyInkPreferences() }
    }
}

#endif
