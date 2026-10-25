// FloeApp — native Impeccable capture service and task-owned bridge (A2).
//
// One `BrowserImpeccableCaptureService` lives on each `BrowserTaskSession`.
// The service is the authority for what a real capture is: it issues capture
// records bound to the trusted task/session/tab/document/generation (never to
// model input), runs the fixed digest-pinned producer in the session's
// isolated `WKContentWorld`, re-validates the returned bytes against the
// frozen v1 schema/privacy/identity rules at ingress, stages snapshot +
// identity + facts files in a capture-record-owned subtree of the task's
// artifact directory, and answers engine Needs only while the capture is
// unfenced.
//
// Fencing is synchronous at observable moments in this store (navigation
// commit, native scroll, user takeover, document handoff, tab close, session
// release), at the moment of *any* scroll/resize/zoom through a per-capture
// KVO observer on the tab's scroll view (user finger, page script, layout —
// every source, not just native commands), and atomic at answer time inside
// the fixed producer (a scroll or viewport drift detected at the instant of
// answering fences the capture and refuses every point). Result ingress
// re-checks the current live tab/document/generation, re-samples the native
// observer, verifies the result's full frozen identity echo field-by-field
// against the native-issued record (absent/foreign/malformed identity is a
// failure with zero usable findings), and re-measures the current CSS
// viewport/scroll through the fixed read-only probe — late results are
// refused even when every observer missed the change. Fenced facts are never
// merged. Raw DOM never leaves the bridge subtree: production captures stage
// under the trusted task workspace root supplied by the runtime tool context
// (symlinked parents/bridges and root mismatches are rejected), tool output
// carries relative paths plus a metadata-only native receipt, nothing is
// logged, and fencing/deletion remove the files.
//
// This file does not run the guest engine. Staging into the resolved Linux
// environment and `exec.shell` invocation of `floe-impeccable snapshot-scan`
// belong to Main's integration (the binary/launcher are pending in the H3
// lane); the proposed patch is in the lane handoff directory.

import Foundation
import UIKit
import WebKit
import FloeCore

// MARK: - Transport seam

/// Measurement returned by the fixed producer surface for one capture.
struct ImpeccableCaptureMeasurement: Sendable {
    var snapshotText: String
    var hostname: String
    var viewport: ImpeccableSize
    var scroll: ImpeccablePoint
    var redaction: ImpeccableRedactionReceipt?
    var elementsMeasured: Int
}

/// Outcome of the fixed read-only probe: the *current* CSS viewport/scroll
/// measured inside the isolated world that ran the capture, plus whether that
/// world still holds the capture run. Native compares these values against the
/// native-issued identity to refuse late results; it never infers CSS
/// coordinates from raw native points under zoom.
struct ImpeccableProbeOutcome: Sendable, Equatable {
    var holdsCapture: Bool
    var recordedDocumentId: String
    var viewport: ImpeccableSize
    var scroll: ImpeccablePoint
    var hostname: String
}

/// Outcome of one Needs answer attempt against a retained producer run.
enum ImpeccableAnswerOutcome: Sendable, Equatable {
    struct Hit: Sendable, Equatable {
        var top: Int
        var stack: [Int]
        var unanswerable: Bool
        var reason: String?
    }
    case answered(hits: [Hit])
    case fenced(reason: String)
    case rejected(code: String)
}

/// Producer invocation surface. The production implementation injects the
/// verified fixed script into the session's isolated content world through
/// `callAsyncJavaScript` with argument values only. Tests inject a
/// deterministic transport that returns prepared envelopes so the *real*
/// ingress validation, fencing, budget and facts-binding paths run without a
/// live page; production code never uses anything but the WebKit transport.
@MainActor
protocol ImpeccableMeasurementTransport: AnyObject {
    func runCapture(
        script: ImpeccableProducerScript.Loaded,
        arguments: [String: Any],
        in webView: WKWebView,
        contentWorld: WKContentWorld,
        captureId: UUID,
        deadline: ContinuousClock.Instant
    ) async throws -> ImpeccableCaptureMeasurement

    func runAnswer(
        script: ImpeccableProducerScript.Loaded,
        arguments: [String: Any],
        in webView: WKWebView,
        contentWorld: WKContentWorld,
        captureId: UUID,
        deadline: ContinuousClock.Instant
    ) async throws -> ImpeccableAnswerOutcome

    /// Read-only re-measurement of the current CSS viewport/scroll in the
    /// isolated world that ran the capture. Fixed op, data-only arguments;
    /// never a caller-supplied script.
    func runProbe(
        script: ImpeccableProducerScript.Loaded,
        arguments: [String: Any],
        in webView: WKWebView,
        contentWorld: WKContentWorld,
        captureId: UUID,
        deadline: ContinuousClock.Instant
    ) async throws -> ImpeccableProbeOutcome

    /// Fail every in-flight call for one capture (synchronous fence).
    func fenceInFlight(captureId: UUID, reason: String)
    func fenceAllInFlight(reason: String)
}

// MARK: - WebKit transport

/// Single-shot request with the same guarantees as `BrowserProbeRequest`:
/// exactly one resolution (callback, deadline, cancellation or fence), no
/// double resume, and no unbounded waiting for an uncooperative WebKit.
/// The payload is split in the callback: the snapshot crosses as one `String`
/// (never re-encoded wholesale) and only the small metadata branch is
/// JSON-rendered for MainActor-safe handoff.
@MainActor
final class ImpeccableCall {
    typealias Completion = @MainActor @Sendable (Result<Any, Error>) -> Void
    struct Payload: Sendable {
        var snapshotText: String?
        var metaJSON: String?
    }

    private var continuation: CheckedContinuation<Payload, Error>?
    private var deadlineTask: Task<Void, Never>?
    private var started = false

    func run(
        deadline: ContinuousClock.Instant,
        invoke: (@escaping Completion) -> Void
    ) async throws -> Payload {
        precondition(!started)
        started = true
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(.failure(ImpeccableCaptureError.cancelled))
                    return
                }
                guard ContinuousClock.now < deadline else {
                    finish(.failure(ImpeccableCaptureError.timedOut))
                    return
                }
                deadlineTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    self?.finish(.failure(ImpeccableCaptureError.timedOut))
                }
                invoke { [weak self] result in
                    switch result {
                    case .success(let value):
                        let dictionary = value as? [String: Any]
                        let snapshot = dictionary?["snapshotJson"] as? String
                        var meta: [String: Any] = [:]
                        for (key, object) in dictionary ?? [:] where key != "snapshotJson" {
                            meta[key] = object
                        }
                        var metaJSON: String?
                        if !meta.isEmpty,
                           let data = try? JSONSerialization.data(withJSONObject: meta, options: [.sortedKeys, .fragmentsAllowed]) {
                            metaJSON = String(data: data, encoding: .utf8)
                        }
                        self?.finish(.success(Payload(snapshotText: snapshot, metaJSON: metaJSON)))
                    case .failure(let error):
                        self?.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(ImpeccableCaptureError.cancelled)) }
        }
    }

    func fence(reason: String) {
        finish(.failure(ImpeccableCaptureError.superseded(reason)))
    }

    private func finish(_ result: Result<Payload, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class ImpeccableWebKitTransport: ImpeccableMeasurementTransport {
    private var calls: [UUID: [ImpeccableCall]] = [:]

    func runCapture(
        script: ImpeccableProducerScript.Loaded,
        arguments: [String: Any],
        in webView: WKWebView,
        contentWorld: WKContentWorld,
        captureId: UUID,
        deadline: ContinuousClock.Instant
    ) async throws -> ImpeccableCaptureMeasurement {
        let envelope = try await invoke(script: script, arguments: arguments, in: webView, contentWorld: contentWorld, captureId: captureId, deadline: deadline)
        guard let snapshotText = envelope.snapshotText else {
            throw ImpeccableCaptureError.invalidInput("capture", "producer returned no snapshot document")
        }
        let meta = impeccableMetaDictionary(from: envelope.metaJSON)
        guard (meta["ok"] as? Bool) == true else {
            if let error = meta["error"] as? String {
                if error.contains("more than") {
                    throw ImpeccableCaptureError.budgetExceeded(["elements: \(error)"])
                }
                if error.contains("bytes (limit") {
                    throw ImpeccableCaptureError.budgetExceeded(["bytes: \(error)"])
                }
                throw ImpeccableCaptureError.invalidInput("capture", error)
            }
            throw ImpeccableCaptureError.invalidInput("capture", "producer returned an unusable envelope")
        }
        let view = meta["view"] as? [String: Any] ?? [:]
        let hostname = meta["hostname"] as? String ?? ""
        let stats = meta["stats"] as? [String: Any] ?? [:]
        return ImpeccableCaptureMeasurement(
            snapshotText: snapshotText,
            hostname: hostname,
            viewport: ImpeccableSize(
                width: (view["innerWidth"] as? NSNumber)?.doubleValue ?? .nan,
                height: (view["innerHeight"] as? NSNumber)?.doubleValue ?? .nan
            ),
            scroll: ImpeccablePoint(
                x: (view["scrollX"] as? NSNumber)?.doubleValue ?? .nan,
                y: (view["scrollY"] as? NSNumber)?.doubleValue ?? .nan
            ),
            redaction: ImpeccableRedactionReceipt.decode(meta["redaction"]),
            elementsMeasured: (stats["elements"] as? NSNumber)?.intValue ?? 0
        )
    }

    func runAnswer(
        script: ImpeccableProducerScript.Loaded,
        arguments: [String: Any],
        in webView: WKWebView,
        contentWorld: WKContentWorld,
        captureId: UUID,
        deadline: ContinuousClock.Instant
    ) async throws -> ImpeccableAnswerOutcome {
        let envelope = try await invoke(script: script, arguments: arguments, in: webView, contentWorld: contentWorld, captureId: captureId, deadline: deadline)
        let meta = impeccableMetaDictionary(from: envelope.metaJSON)
        if (meta["fenced"] as? Bool) == true {
            return .fenced(reason: (meta["reason"] as? String) ?? "viewport-or-scroll-changed")
        }
        if (meta["ok"] as? Bool) == true, let rawHits = meta["hits"] as? [Any] {
            let hits = rawHits.compactMap { entry -> ImpeccableAnswerOutcome.Hit? in
                guard let hit = entry as? [String: Any] else { return nil }
                return ImpeccableAnswerOutcome.Hit(
                    top: (hit["top"] as? NSNumber)?.intValue ?? 0,
                    stack: (hit["stack"] as? [Any] ?? []).compactMap { ($0 as? NSNumber)?.intValue },
                    unanswerable: (hit["unanswerable"] as? Bool) ?? false,
                    reason: hit["reason"] as? String
                )
            }
            guard hits.count == rawHits.count else {
                throw ImpeccableCaptureError.factsRejected(["answer contained a malformed hit entry"])
            }
            return .answered(hits: hits)
        }
        if let rejected = meta["rejected"] as? String {
            return .rejected(code: rejected)
        }
        if let error = meta["error"] as? String {
            throw ImpeccableCaptureError.webKit(error)
        }
        throw ImpeccableCaptureError.webKit("answer returned an unusable envelope")
    }

    func runProbe(
        script: ImpeccableProducerScript.Loaded,
        arguments: [String: Any],
        in webView: WKWebView,
        contentWorld: WKContentWorld,
        captureId: UUID,
        deadline: ContinuousClock.Instant
    ) async throws -> ImpeccableProbeOutcome {
        let envelope = try await invoke(script: script, arguments: arguments, in: webView, contentWorld: contentWorld, captureId: captureId, deadline: deadline)
        let meta = impeccableMetaDictionary(from: envelope.metaJSON)
        guard (meta["ok"] as? Bool) == true else {
            if let error = meta["error"] as? String {
                throw ImpeccableCaptureError.invalidInput("probe", error)
            }
            throw ImpeccableCaptureError.invalidInput("probe", "producer returned an unusable probe envelope")
        }
        let view = meta["view"] as? [String: Any] ?? [:]
        guard let width = (view["innerWidth"] as? NSNumber)?.doubleValue,
              let height = (view["innerHeight"] as? NSNumber)?.doubleValue,
              let scrollX = (view["scrollX"] as? NSNumber)?.doubleValue,
              let scrollY = (view["scrollY"] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, scrollX.isFinite, scrollY.isFinite else {
            throw ImpeccableCaptureError.invalidInput("probe", "probe returned a non-finite or missing view")
        }
        return ImpeccableProbeOutcome(
            holdsCapture: (meta["holdsCapture"] as? Bool) ?? false,
            recordedDocumentId: (meta["recordedDocumentId"] as? String) ?? "",
            viewport: ImpeccableSize(width: width, height: height),
            scroll: ImpeccablePoint(x: scrollX, y: scrollY),
            hostname: (meta["hostname"] as? String) ?? ""
        )
    }

    func fenceInFlight(captureId: UUID, reason: String) {
        for call in calls[captureId] ?? [] { call.fence(reason: reason) }
        calls[captureId] = nil
    }

    func fenceAllInFlight(reason: String) {
        for (_, group) in calls {
            for call in group { call.fence(reason: reason) }
        }
        calls.removeAll()
    }

    private func invoke(
        script: ImpeccableProducerScript.Loaded,
        arguments: [String: Any],
        in webView: WKWebView,
        contentWorld: WKContentWorld,
        captureId: UUID,
        deadline: ContinuousClock.Instant
    ) async throws -> ImpeccableCall.Payload {
        let call = ImpeccableCall()
        calls[captureId, default: []].append(call)
        defer {
            if let group = calls[captureId], let index = group.firstIndex(where: { $0 === call }) {
                var remaining = group
                remaining.remove(at: index)
                if remaining.isEmpty { calls[captureId] = nil } else { calls[captureId] = remaining }
            }
        }
        return try await call.run(deadline: deadline) { completion in
            webView.callAsyncJavaScript(
                script.runSource,
                arguments: arguments,
                in: nil,
                in: contentWorld,
                completionHandler: completion
            )
        }
    }
}

private func impeccableMetaDictionary(from text: String?) -> [String: Any] {
    guard let text, let data = text.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
        return [:]
    }
    return dictionary
}

// MARK: - Native viewport/scroll observation

/// One native-side sample of the tab's scroll geometry. These are raw native
/// points/scales: they are a *change fence* only and are never converted to
/// CSS coordinates (CSS exactness belongs to the fixed isolated-world probe).
struct ImpeccableNativeViewSample: Sendable, Equatable {
    var contentOffsetX: Double
    var contentOffsetY: Double
    var viewportWidth: Double
    var viewportHeight: Double
    var zoomScale: Double

    @MainActor
    static func current(of scrollView: UIScrollView) -> ImpeccableNativeViewSample {
        ImpeccableNativeViewSample(
            contentOffsetX: Double(scrollView.contentOffset.x),
            contentOffsetY: Double(scrollView.contentOffset.y),
            viewportWidth: Double(scrollView.bounds.width),
            viewportHeight: Double(scrollView.bounds.height),
            zoomScale: Double(scrollView.zoomScale)
        )
    }
}

/// Synchronous native fence for one capture: KVO on the tab's scroll view
/// (`contentOffset`, `bounds`) and `zoomScale`. Any drift from the baseline
/// taken when the capture was issued fences *that capture* at the moment of
/// change — user finger scroll, page/script scroll, resize or pinch zoom —
/// without waiting for the next native command. `execute(.scroll)` fences
/// before the page moves; this observer covers every scroll/resize source the
/// native command path cannot see.
///
/// Lifetime and safety:
/// - one observer per capture record, owned strongly by that record;
/// - invalidated (tokens removed) on fence, cleanup, prune and session
///   release; `NSKeyValueObservation` also auto-invalidates on dealloc, so a
///   dropped record can never keep observing;
/// - handlers hold the observer weakly — no KVO retain cycle;
/// - an observer only ever reports drift for its own capture: an old capture
///   can never fence or delete a newer one;
/// - KVO delivery on the main thread fences synchronously (`assumeIsolated`);
///   an off-main delivery is re-dispatched to the main actor, and answer/
///   result ingress additionally re-sample via `recheckNow()` so a missed or
///   coalesced notification can never admit a late result.
@MainActor
final class ImpeccableViewportObserver {
    enum Drift: String, Sendable {
        case scroll
        case viewport
    }

    private weak var scrollView: UIScrollView?
    private let baseline: ImpeccableNativeViewSample
    private var tokens: [NSKeyValueObservation] = []
    private var invalidated = false
    private(set) var driftKind: Drift?

    /// Invoked on observed or rechecked drift. During measurement the service
    /// wires this to fail the in-flight call; once the record exists it is
    /// rewired to `fence(captureID:reason:)` for this capture only.
    var onChange: (@MainActor (ImpeccableViewportObserver) -> Void)?

    init(scrollView: UIScrollView, onChange: @escaping @MainActor (ImpeccableViewportObserver) -> Void) {
        self.scrollView = scrollView
        self.baseline = .current(of: scrollView)
        self.onChange = onChange
        tokens.append(scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.nativeChange()
        })
        tokens.append(scrollView.observe(\.bounds, options: [.new]) { [weak self] _, _ in
            self?.nativeChange()
        })
        tokens.append(scrollView.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
            self?.nativeChange()
        })
    }

    /// The fence reason for the observed drift; `.scroll` when only the
    /// content offset moved, `.viewport` when size or zoom changed.
    var driftReason: BrowserImpeccableCaptureService.FenceReason {
        driftKind == .viewport ? .viewport : .scroll
    }

    var hasDrifted: Bool { driftKind != nil }

    /// Synchronous drift re-sample used at answer/result ingress in case a
    /// KVO delivery was missed or coalesced. Reports (and latches) drift; the
    /// caller decides the fence so no double-firing occurs.
    func recheckNow() -> Bool {
        guard !invalidated else { return hasDrifted }
        if driftKind == nil, let scrollView {
            latchDrift(against: .current(of: scrollView))
        }
        return hasDrifted
    }

    /// Stop observing and release the fence wiring. Safe to call repeatedly.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        for token in tokens { token.invalidate() }
        tokens.removeAll()
        onChange = nil
        scrollView = nil
    }

    private nonisolated func nativeChange() {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.handleMainActorChange()
            }
        } else {
            Task { @MainActor [weak self] in
                self?.handleMainActorChange()
            }
        }
    }

    private func handleMainActorChange() {
        guard !invalidated, driftKind == nil, let scrollView else { return }
        latchDrift(against: .current(of: scrollView))
        if driftKind != nil {
            onChange?(self)
        }
    }

    private func latchDrift(against current: ImpeccableNativeViewSample) {
        guard current != baseline else { return }
        if current.viewportWidth != baseline.viewportWidth
            || current.viewportHeight != baseline.viewportHeight
            || current.zoomScale != baseline.zoomScale {
            driftKind = .viewport
        } else {
            driftKind = .scroll
        }
    }
}

// MARK: - Capture records

enum ImpeccableCaptureState: Sendable, Equatable {
    case active
    case fenced(reason: String)
}

struct ImpeccableCaptureTicket: Sendable {
    let captureID: UUID
    let binding: ImpeccableCaptureBinding
    /// The validated physical root that owns this capture's bridge files:
    /// the trusted task workspace root when production supplied one, or the
    /// session artifact directory for internal tests/legacy native captures.
    let bridgeRoot: URL
    /// True only when the caller supplied (and native validated) the trusted
    /// task workspace root — the production design path.
    let bridgeRootIsTaskWorkspace: Bool
    let bridgeDirectory: URL
    let snapshotFile: URL
    let identityFile: URL
    /// Paths relative to `bridgeRoot` for tool output; tool output carries
    /// these plus the native receipt, never absolute paths or raw DOM.
    let relativeDirectory: String
    let relativeSnapshotFile: String
    let relativeIdentityFile: String
    let documentGeneration: Int
    let elementCount: Int
    let snapshotBytes: Int
    let viewport: ImpeccableSize
    let scroll: ImpeccablePoint
    let redaction: ImpeccableRedactionReceipt
    let scriptDigest: String

    /// Metadata-only native receipt for model-facing tool output.
    var receipt: ImpeccableCaptureReceipt {
        ImpeccableCaptureReceipt(
            captureId: captureID.uuidString,
            binding: binding,
            bridgeRootIsTaskWorkspace: bridgeRootIsTaskWorkspace,
            relativeDirectory: relativeDirectory,
            relativeSnapshotFile: relativeSnapshotFile,
            relativeIdentityFile: relativeIdentityFile,
            documentGeneration: documentGeneration,
            elementCount: elementCount,
            snapshotBytes: snapshotBytes,
            viewport: viewport,
            scroll: scroll,
            redaction: redaction,
            scriptDigest: scriptDigest
        )
    }
}

/// The native receipt that tool output carries instead of content: binding,
/// workspace-relative bridge paths, counts and digests. No DOM, no absolute
/// host paths, no snapshot bytes.
struct ImpeccableCaptureReceipt: Codable, Sendable, Equatable {
    var captureId: String
    var binding: ImpeccableCaptureBinding
    var bridgeRootIsTaskWorkspace: Bool
    var relativeDirectory: String
    var relativeSnapshotFile: String
    var relativeIdentityFile: String
    var documentGeneration: Int
    var elementCount: Int
    var snapshotBytes: Int
    var viewport: ImpeccableSize
    var scroll: ImpeccablePoint
    var redaction: ImpeccableRedactionReceipt
    var scriptDigest: String

    func encodedJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

@MainActor
final class ImpeccableCaptureRecord {
    let captureID: UUID
    let binding: ImpeccableCaptureBinding
    let bridgeRoot: URL
    let bridgeRootIsTaskWorkspace: Bool
    let bridgeDirectory: URL
    let snapshotFile: URL
    let identityFile: URL
    let issuedAt: Date
    let viewport: ImpeccableSize
    let scroll: ImpeccablePoint
    let identity: ImpeccableIdentity
    let elementCount: Int
    let snapshotBytes: Int
    /// Per-capture synchronous native fence for scroll/resize/zoom drift.
    /// Owned by this record; invalidated on fence/cleanup/prune/release.
    var viewportObserver: ImpeccableViewportObserver?
    var state: ImpeccableCaptureState = .active
    var answeredRounds: Int = 0
    var totalAnsweredHits: Int = 0
    /// Round numbers already consumed, to refuse replays.
    var usedRounds: Set<Int> = []

    init(
        captureID: UUID,
        binding: ImpeccableCaptureBinding,
        bridgeRoot: URL,
        bridgeRootIsTaskWorkspace: Bool,
        bridgeDirectory: URL,
        snapshotFile: URL,
        identityFile: URL,
        issuedAt: Date,
        viewport: ImpeccableSize,
        scroll: ImpeccablePoint,
        identity: ImpeccableIdentity,
        elementCount: Int,
        snapshotBytes: Int,
        viewportObserver: ImpeccableViewportObserver?
    ) {
        self.captureID = captureID
        self.binding = binding
        self.bridgeRoot = bridgeRoot
        self.bridgeRootIsTaskWorkspace = bridgeRootIsTaskWorkspace
        self.bridgeDirectory = bridgeDirectory
        self.snapshotFile = snapshotFile
        self.identityFile = identityFile
        self.issuedAt = issuedAt
        self.viewport = viewport
        self.scroll = scroll
        self.identity = identity
        self.elementCount = elementCount
        self.snapshotBytes = snapshotBytes
        self.viewportObserver = viewportObserver
    }
}

// MARK: - Service

@MainActor
final class BrowserImpeccableCaptureService {
    enum FenceReason: String, Sendable {
        case navigation
        case reload
        case documentSwap
        case scroll
        case viewport
        case tabClosed
        case userTakeover
        case ownerHandoff
        case released
        case taskCancelled
    }

    /// Loads the verified fixed producer. Production always uses the real
    /// bundle-verified loader; focused tests inject a deterministic fixture
    /// with the same pinned-digest shape so the genuine ingress, fencing and
    /// budget paths can be exercised without the regenerated app bundle. The
    /// injected value must still be digest-consistent (tests build it via
    /// `fixtureLoadedScript`).
    private let scriptLoader: @MainActor () throws -> ImpeccableProducerScript.Loaded

    private weak var session: BrowserTaskSession?
    private let transport: ImpeccableMeasurementTransport
    private let fileManager: FileManager
    let budgets: ImpeccableBudgets
    private(set) var records: [UUID: ImpeccableCaptureRecord] = [:]
    private let maximumRetainedCaptures = 8

    init(
        session: BrowserTaskSession,
        transport: ImpeccableMeasurementTransport = ImpeccableWebKitTransport(),
        budgets: ImpeccableBudgets = .frozenV1,
        fileManager: FileManager = .default,
        scriptLoader: (@MainActor () throws -> ImpeccableProducerScript.Loaded)? = nil
    ) {
        self.session = session
        self.transport = transport
        self.budgets = budgets
        self.fileManager = fileManager
        self.scriptLoader = scriptLoader ?? { try ImpeccableProducerScript.loadVerified() }
    }

    /// A Loaded whose digests are self-consistent for a fixture source; real
    /// captures never use this path.
    static func fixtureLoadedScript(source: String = "fixture") -> ImpeccableProducerScript.Loaded {
        let runSource = source + "\n" + ImpeccableProducerScript.nativeDispatchLine
        let runDigest = FloeDigest.sha256Hex(Data(runSource.utf8))
        return ImpeccableProducerScript.Loaded(
            source: source,
            runSource: runSource,
            runDigest: runDigest,
            fileBytes: source.utf8.count,
            runBytes: runSource.utf8.count
        )
    }

    // MARK: Bridge root validation

    /// Validates one trusted bridge root. Production design captures pass the
    /// runtime-issued `ToolContext.workspaceRootURL` (supplied by Main-owned
    /// BrowserTools after task file-scope validation and the run's
    /// `TaskRootLease`; never a model-authored path). Rules:
    /// - file URL only;
    /// - an existing directory;
    /// - resolved to its physical path (iOS `/var` is a system symlink, so
    ///   the *canonical* root is the resolved one — a root whose resolved
    ///   form is not a directory is a mismatch and is rejected);
    /// - the bridge subtree is created and deleted only as real directories
    ///   strictly under that resolved root: a symlinked parent/bridge
    ///   component or a staged path escaping the root is rejected, never
    ///   followed (`ensureRealBridgeDirectories`, `deleteBridgeFiles`).
    /// The session artifact-directory default (`bridgeRoot == nil`) remains
    /// for internal tests and legacy native captures only.
    static func validatedBridgeRoot(_ candidate: URL, fileManager: FileManager = .default) throws -> URL {
        guard candidate.isFileURL else {
            throw ImpeccableCaptureError.invalidInput("bridge", "root is not a file URL")
        }
        let standardized = candidate.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ImpeccableCaptureError.invalidInput("bridge", "root is not an existing directory")
        }
        let resolved = standardized.resolvingSymlinksInPath()
        var resolvedIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolved.path, isDirectory: &resolvedIsDirectory),
              resolvedIsDirectory.boolValue else {
            throw ImpeccableCaptureError.invalidInput("bridge", "root does not resolve to a real directory (symlink mismatch)")
        }
        return resolved
    }

    /// After staging, every bridge component strictly under the validated
    /// root must be a real directory — never a symlink. A replaced/symlinked
    /// parent or bridge is rejected and never followed or deleted through.
    private func ensureRealBridgeDirectories(_ bridgeDirectory: URL, root: URL, components: [String]) throws {
        guard bridgeDirectory.path == (components.reduce(root) { $0.appendingPathComponent($1, isDirectory: true) }).path else {
            throw ImpeccableCaptureError.invalidInput("bridge", "bridge root mismatch: staged path is not under the validated root")
        }
        var current = root
        for component in components {
            current = current.appendingPathComponent(component, isDirectory: true)
            guard fileManager.fileExists(atPath: current.path) else { continue }
            let values = try? current.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink == false else {
                throw ImpeccableCaptureError.invalidInput("bridge", "bridge component '\(component)' is not a real directory (symlinked parent/bridge rejected)")
            }
        }
    }

    // MARK: Capture

    /// Runs one real capture.
    ///
    /// - Parameters:
    ///   - tabID: the live tab to measure.
    ///   - timeoutMilliseconds: bounded by `budgets.timeoutMs`.
    ///   - bridgeRoot: the trusted task workspace root (production design
    ///     path: Main-owned BrowserTools passes the runtime-issued
    ///     `context.workspaceRootURL` after task file-scope validation).
    ///     `nil` keeps the legacy session artifact-directory default for
    ///     internal tests/legacy native captures only.
    func capture(
        tabID: UUID,
        timeoutMilliseconds: Int? = nil,
        bridgeRoot: URL? = nil
    ) async throws -> ImpeccableCaptureTicket {
        guard let session, !session.isReleased else {
            throw ImpeccableCaptureError.released
        }
        guard let tab = session.tabs.first(where: { $0.id == tabID }) else {
            throw ImpeccableCaptureError.tabUnavailable("capture")
        }
        let timeoutMs = min(budgets.timeoutMs, max(1_000, timeoutMilliseconds ?? budgets.timeoutMs))
        let binding = ImpeccableCaptureBinding(
            taskId: session.conversationID.uuidString,
            sessionId: session.sessionID.uuidString,
            tabId: tab.id.uuidString,
            documentId: tab.documentID,
            documentGeneration: tab.documentGeneration,
            captureId: ""
        )
        let loaded: ImpeccableProducerScript.Loaded
        do {
            loaded = try scriptLoader()
        } catch {
            // Fixed-producer provenance failure: refuse, never fall back to
            // any other script or an inline copy.
            throw ImpeccableCaptureError.producerScriptRejected("\(error)")
        }
        // Resolve and validate the owner-bound bridge root before any
        // measurement work: production supplies the real task workspace.
        let rootIsTaskWorkspace = bridgeRoot != nil
        let resolvedRoot: URL
        if let bridgeRoot {
            resolvedRoot = try Self.validatedBridgeRoot(bridgeRoot, fileManager: fileManager)
        } else {
            resolvedRoot = session.artifactDirectory.standardizedFileURL.resolvingSymlinksInPath()
        }
        let captureID = UUID()
        var wireBinding = binding
        wireBinding.captureId = captureID.uuidString

        // Attach the synchronous native drift fence *before* measuring: a
        // scroll/resize/zoom during the run aborts the in-flight call and
        // refuses the late measurement below.
        let observer = ImpeccableViewportObserver(scrollView: tab.webView.scrollView) { [weak self] observed in
            guard let self else { return }
            self.transport.fenceInFlight(captureId: captureID, reason: observed.driftReason.rawValue)
        }
        var observerInstalled = false
        defer {
            if !observerInstalled { observer.invalidate() }
        }

        let arguments = ImpeccableProducerInvocation.captureArguments(
            ImpeccableProducerInvocation.CaptureArguments(
                captureId: captureID.uuidString,
                documentId: binding.documentId,
                contractVersion: ImpeccableContract.contractVersion,
                maxElements: budgets.maxElements,
                maxBytes: budgets.maxSnapshotBytes
            ),
            budgets: budgets
        )
        let measured = try await transport.runCapture(
            script: loaded,
            arguments: arguments,
            in: tab.webView,
            contentWorld: session.contentWorld,
            captureId: captureID,
            deadline: ContinuousClock.now.advanced(by: .milliseconds(timeoutMs))
        )

        // Late-result refusal: the capture must still be the same document on
        // the same live tab when the measurement comes back. `self.session`
        // is re-read after the suspension point (the weak property, not the
        // pre-await strong local) so a session released mid-measurement is
        // caught instead of being kept alive by this call.
        guard let liveSession = self.session, !liveSession.isReleased,
              let currentTab = liveSession.tabs.first(where: { $0.id == tabID }),
              currentTab.documentID == binding.documentId,
              currentTab.documentGeneration == binding.documentGeneration else {
            throw ImpeccableCaptureError.superseded("document changed during measurement")
        }
        // Native drift during measurement (observer latch or a re-sample in
        // case a KVO delivery was coalesced): refuse, never stage a snapshot
        // of a page that moved.
        guard !observer.recheckNow() else {
            throw ImpeccableCaptureError.superseded("viewport or scroll changed during measurement")
        }

        // Full ingress scan of the producer bytes.
        let snapshotData = Data(measured.snapshotText.utf8)
        guard snapshotData.count <= budgets.maxSnapshotBytes else {
            throw ImpeccableCaptureError.budgetExceeded(["snapshot bytes \(snapshotData.count) > \(budgets.maxSnapshotBytes)"])
        }
        let parsed = try? JSONSerialization.jsonObject(with: snapshotData, options: [.fragmentsAllowed])
        let (ingress, scanRejections) = ImpeccableSnapshotIngress.scan(
            parsed as Any,
            snapshotBytes: snapshotData.count,
            budgets: budgets
        )
        guard let ingress, scanRejections.isEmpty else {
            throw ImpeccableCaptureError.schemaMismatch(scanRejections)
        }
        guard ingress.stylePropsCount == ImpeccableContract.stylePropCount,
              ingress.columnParityBrokenCount == 0 else {
            throw ImpeccableCaptureError.schemaMismatch(["style column parity"])
        }
        guard ingress.elementCount == measured.elementsMeasured || measured.elementsMeasured == 0 else {
            throw ImpeccableCaptureError.schemaMismatch(["stats.elements disagrees with els"])
        }
        // The snapshot's own measured view must agree with the producer
        // envelope, and the hostname with the native tab URL.
        guard ingress.innerWidth.bitPattern == measured.viewport.width.bitPattern,
              ingress.innerHeight.bitPattern == measured.viewport.height.bitPattern,
              ingress.scrollX.bitPattern == measured.scroll.x.bitPattern,
              ingress.scrollY.bitPattern == measured.scroll.y.bitPattern else {
            throw ImpeccableCaptureError.schemaMismatch(["envelope view disagrees with snapshot fields"])
        }
        guard ingress.hostname == measured.hostname else {
            throw ImpeccableCaptureError.schemaMismatch(["envelope hostname disagrees with snapshot"])
        }
        let nativeURL = currentTab.webView.url?.absoluteString ?? ""
        let nativeHost = currentTab.webView.url?.host ?? ""
        guard !nativeURL.isEmpty, nativeHost.lowercased() == ingress.hostname.lowercased() else {
            throw ImpeccableCaptureError.identityRejected(["native tab URL host disagrees with the measured hostname"])
        }
        // floe binding block must echo this capture.
        guard ingress.floeCaptureId == captureID.uuidString,
              ingress.floeDocumentId == binding.documentId,
              ingress.floeContractVersion == ImpeccableContract.contractVersion else {
            throw ImpeccableCaptureError.identityRejected(["snapshot floe block does not echo this capture binding"])
        }
        guard let receipt = ingress.redaction, receipt.contractRejections.isEmpty else {
            throw ImpeccableCaptureError.identityRejected(["redaction receipt absent or invalid"])
        }
        guard ingress.redaction?.credentialAttributes.sorted() == measured.redaction?.credentialAttributes.sorted(),
              ingress.redaction?.passwordInputs == measured.redaction?.passwordInputs,
              ingress.redaction?.formValues == measured.redaction?.formValues,
              ingress.redaction?.textRuns == measured.redaction?.textRuns else {
            throw ImpeccableCaptureError.identityRejected(["redaction receipt in the snapshot disagrees with the producer envelope"])
        }

        let identity = ImpeccableIdentity(
            taskId: binding.taskId,
            sessionId: binding.sessionId,
            tabId: binding.tabId,
            documentId: binding.documentId,
            captureId: binding.captureId,
            documentGeneration: binding.documentGeneration,
            url: nativeURL,
            hostname: ingress.hostname,
            viewport: ImpeccableSize(width: ingress.innerWidth, height: ingress.innerHeight),
            scroll: ImpeccablePoint(x: ingress.scrollX, y: ingress.scrollY),
            capturedAtMs: Int64(Date().timeIntervalSince1970 * 1_000),
            producerTrust: ImpeccableContract.producerTrust,
            producer: ImpeccableProducerInfo(
                name: ImpeccableContract.producerName,
                version: ImpeccableContract.producerVersion,
                engine: ImpeccableContract.producerEngine,
                scriptDigest: loaded.runDigest
            ),
            redaction: receipt,
            fenced: false
        )
        let agreement = ImpeccableIdentity.SnapshotAgreement(
            hostname: ingress.hostname,
            innerWidth: ingress.innerWidth,
            innerHeight: ingress.innerHeight,
            scrollX: ingress.scrollX,
            scrollY: ingress.scrollY
        )
        let rejections = identity.ingressRejections(
            snapshot: agreement,
            expectedScriptDigest: loaded.runDigest
        )
        guard rejections.isEmpty else {
            throw ImpeccableCaptureError.identityRejected(rejections)
        }

        // Stage files in the capture-owned UUID-only subtree of the
        // validated root: <root>/Impeccable/<taskId>/<captureId>/.
        let bridgeComponents = ["Impeccable", binding.taskId, captureID.uuidString]
        let bridgeDirectory = bridgeComponents.reduce(resolvedRoot) { $0.appendingPathComponent($1, isDirectory: true) }
        let snapshotFile = bridgeDirectory.appendingPathComponent("snapshot.v1.json")
        let identityFile = bridgeDirectory.appendingPathComponent("identity.v1.json")
        do {
            try fileManager.createDirectory(at: bridgeDirectory, withIntermediateDirectories: true)
            try ensureRealBridgeDirectories(bridgeDirectory, root: resolvedRoot, components: bridgeComponents)
            try snapshotData.write(to: snapshotFile, options: .atomic)
            try identity.encodedJSON().write(to: identityFile, options: .atomic)
            try ensureRealBridgeDirectories(bridgeDirectory, root: resolvedRoot, components: bridgeComponents)
        } catch {
            removeRealBridgeDirectory(bridgeDirectory, under: resolvedRoot)
            if let impeccableError = error as? ImpeccableCaptureError { throw impeccableError }
            throw ImpeccableCaptureError.invalidInput("bridge", "staging failed: \(error.localizedDescription)")
        }

        let record = ImpeccableCaptureRecord(
            captureID: captureID,
            binding: wireBinding,
            bridgeRoot: resolvedRoot,
            bridgeRootIsTaskWorkspace: rootIsTaskWorkspace,
            bridgeDirectory: bridgeDirectory,
            snapshotFile: snapshotFile,
            identityFile: identityFile,
            issuedAt: Date(),
            viewport: identity.viewport,
            scroll: identity.scroll,
            identity: identity,
            elementCount: ingress.elementCount,
            snapshotBytes: snapshotData.count,
            viewportObserver: observer
        )
        // From now on the observer fences this capture record (and only this
        // record) synchronously at the moment of any native scroll/resize.
        observer.onChange = { [weak self, captureID] observed in
            self?.fence(captureID: captureID, reason: observed.driftReason)
        }
        observerInstalled = true
        records[captureID] = record
        pruneRetainedRecords()
        let relativeDirectory = bridgeComponents.joined(separator: "/")
        return ImpeccableCaptureTicket(
            captureID: captureID,
            binding: wireBinding,
            bridgeRoot: resolvedRoot,
            bridgeRootIsTaskWorkspace: rootIsTaskWorkspace,
            bridgeDirectory: record.bridgeDirectory,
            snapshotFile: record.snapshotFile,
            identityFile: record.identityFile,
            relativeDirectory: relativeDirectory,
            relativeSnapshotFile: relativeDirectory + "/snapshot.v1.json",
            relativeIdentityFile: relativeDirectory + "/identity.v1.json",
            documentGeneration: record.binding.documentGeneration,
            elementCount: record.elementCount,
            snapshotBytes: record.snapshotBytes,
            viewport: record.viewport,
            scroll: record.scroll,
            redaction: record.identity.redaction,
            scriptDigest: record.identity.producer.scriptDigest
        )
    }

    // MARK: Needs → Facts

    func answerNeeds(captureID: UUID, needsJSON: Data) async throws -> URL {
        guard let session, !session.isReleased else {
            throw ImpeccableCaptureError.released
        }
        guard let record = records[captureID] else {
            throw ImpeccableCaptureError.noSuchCapture(captureID.uuidString)
        }
        guard case .active = record.state else {
            transport.fenceInFlight(captureId: captureID, reason: "already fenced")
            throw ImpeccableCaptureError.superseded("capture \(captureID.uuidString) is fenced")
        }
        // Synchronous native drift re-sample before any work: a page/script/
        // user scroll or resize since issuance fences at the moment of
        // answering even when no lifecycle event fired.
        if let observer = record.viewportObserver, observer.recheckNow() {
            fence(captureID: captureID, reason: observer.driftReason)
            throw ImpeccableCaptureError.superseded("viewport or scroll changed before the answer")
        }
        let needs = try ImpeccableNeeds.decode(from: needsJSON)
        guard needs.round == record.answeredRounds + 1, !record.usedRounds.contains(needs.round) else {
            throw ImpeccableCaptureError.invalidInput("needs", "round \(needs.round) is out of sequence")
        }
        guard needs.round <= budgets.maxRounds else {
            throw ImpeccableCaptureError.budgetExceeded(["rounds \(needs.round) > \(budgets.maxRounds)"])
        }
        guard needs.hitTests.count <= budgets.maxHitTestsPerRound else {
            throw ImpeccableCaptureError.budgetExceeded(["hit tests \(needs.hitTests.count) > \(budgets.maxHitTestsPerRound) per round"])
        }
        guard record.totalAnsweredHits + needs.hitTests.count <= budgets.maxHitTestsTotal else {
            throw ImpeccableCaptureError.budgetExceeded(["total hit tests > \(budgets.maxHitTestsTotal)"])
        }
        let points = try needs.verifiedPoints()

        // Same-document check at the moment of answering.
        guard let liveTab = session.tabs.first(where: { $0.id.uuidString == record.binding.tabId }),
              liveTab.documentID == record.binding.documentId,
              liveTab.documentGeneration == record.binding.documentGeneration else {
            fence(captureID: captureID, reason: .documentSwap)
            throw ImpeccableCaptureError.superseded("document changed before answer")
        }
        let loaded: ImpeccableProducerScript.Loaded
        do {
            loaded = try scriptLoader()
        } catch {
            throw ImpeccableCaptureError.producerScriptRejected("\(error)")
        }
        // The fixed answer call is bound to the native frozen identity's
        // exact-bit recorded view: the same numbers the capture ingress
        // verified equal (bit-for-bit) to the producer envelope and the
        // snapshot's own view fields, which the pinned adapter's recorded
        // run view was measured from. A live-vs-recorded drift inside the
        // world fences the round; nothing here passes a placeholder.
        let arguments = ImpeccableProducerInvocation.answerArguments(
            ImpeccableProducerInvocation.AnswerArguments(
                captureId: captureID.uuidString,
                expectedDocumentId: record.binding.documentId,
                expectedViewportWidth: record.identity.viewport.width,
                expectedViewportHeight: record.identity.viewport.height,
                expectedScrollX: record.identity.scroll.x,
                expectedScrollY: record.identity.scroll.y,
                points: points.map { [$0.x, $0.y] }
            ),
            budgets: budgets
        )
        let outcome = try await transport.runAnswer(
            script: loaded,
            arguments: arguments,
            in: liveTab.webView,
            contentWorld: session.contentWorld,
            captureId: captureID,
            deadline: ContinuousClock.now.advanced(by: .milliseconds(budgets.timeoutMs))
        )
        switch outcome {
        case .fenced(let reason):
            // Atomic drift detection: fence now, refuse the whole round.
            fence(captureID: captureID, reason: .viewport)
            throw ImpeccableCaptureError.superseded("page moved at answer time (\(reason))")
        case .rejected(let code):
            fence(captureID: captureID, reason: .navigation)
            throw ImpeccableCaptureError.superseded("producer world no longer holds this capture (\(code))")
        case .answered(let hits):
            guard hits.count == points.count else {
                throw ImpeccableCaptureError.factsRejected(["answered \(hits.count) points for \(points.count) asked"])
            }
            var factHits: [ImpeccableFactHit] = []
            factHits.reserveCapacity(hits.count)
            for (index, hit) in hits.enumerated() {
                guard hit.top >= 0, hit.top <= record.elementCount,
                      hit.stack.allSatisfy({ $0 > 0 && $0 <= record.elementCount }) else {
                    throw ImpeccableCaptureError.factsRejected(["point \(index) references an id outside the capture"])
                }
                if hit.unanswerable && (hit.reason ?? "").isEmpty {
                    throw ImpeccableCaptureError.factsRejected(["point \(index) is unanswerable without a reason"])
                }
                if hit.top == 0 && hit.stack.isEmpty && !hit.unanswerable {
                    throw ImpeccableCaptureError.factsRejected(["point \(index) answered nothing without unanswerable + reason"])
                }
                factHits.append(ImpeccableFactHit(
                    x: points[index].x,
                    y: points[index].y,
                    xBits: needs.hitTestsBits?[index].first ?? ImpeccableDoubleBits.u64String(from: points[index].x),
                    yBits: needs.hitTestsBits?[index].last ?? ImpeccableDoubleBits.u64String(from: points[index].y),
                    top: hit.top,
                    stack: hit.stack,
                    unanswerable: hit.unanswerable ? true : nil,
                    reason: hit.unanswerable ? hit.reason : nil
                ))
            }
            // scrollProbes are never answered by v1: answering would move the
            // page and fence the capture, and inventing "shown" facts is
            // forbidden. The engine reports them as unanswered.
            let facts = ImpeccableFacts(
                taskId: record.binding.taskId,
                sessionId: record.binding.sessionId,
                tabId: record.binding.tabId,
                documentId: record.binding.documentId,
                captureId: record.binding.captureId,
                documentGeneration: record.binding.documentGeneration,
                fenced: false,
                hits: factHits,
                shownOnScroll: []
            )
            let rejections = facts.rejections(
                against: record.binding,
                askedPoints: points,
                elementCount: record.elementCount
            )
            guard rejections.isEmpty else {
                throw ImpeccableCaptureError.factsRejected(rejections)
            }
            // Final synchronous fence check before staging: the record, the
            // live document/generation, and a fresh native drift re-sample
            // (covering any scroll/resize that landed while the answer call
            // was suspended).
            if let observer = records[captureID]?.viewportObserver, observer.recheckNow() {
                fence(captureID: captureID, reason: observer.driftReason)
                throw ImpeccableCaptureError.superseded("viewport or scroll changed during the answer")
            }
            guard case .active = records[captureID]?.state,
                  let currentTab = session.tabs.first(where: { $0.id.uuidString == record.binding.tabId }),
                  currentTab.documentID == record.binding.documentId,
                  currentTab.documentGeneration == record.binding.documentGeneration else {
                throw ImpeccableCaptureError.superseded("capture fenced during answer")
            }
            let factsFile = record.bridgeDirectory.appendingPathComponent("facts.round\(needs.round).v1.json")
            do {
                try facts.encodedJSON().write(to: factsFile, options: .atomic)
            } catch {
                throw ImpeccableCaptureError.invalidInput("bridge", "facts staging failed: \(error.localizedDescription)")
            }
            records[captureID]?.answeredRounds = needs.round
            records[captureID]?.usedRounds.insert(needs.round)
            records[captureID]?.totalAnsweredHits += factHits.count
            return factsFile
        }
    }

    // MARK: Fencing

    func fence(captureID: UUID, reason: FenceReason) {
        guard let record = records[captureID], case .active = record.state else { return }
        record.state = .fenced(reason: reason.rawValue)
        // Stop this capture's native observer first: a fenced capture must
        // not keep observing, and only its own tokens are touched — other
        // captures on the same scroll view keep their own fences.
        record.viewportObserver?.invalidate()
        transport.fenceInFlight(captureId: captureID, reason: reason.rawValue)
        deleteBridgeFiles(of: record)
    }

    func fence(tabID: UUID, reason: FenceReason) {
        let tabKey = tabID.uuidString
        for record in records.values where record.binding.tabId == tabKey {
            fence(captureID: record.captureID, reason: reason)
        }
    }

    func fenceAll(reason: FenceReason) {
        for captureID in records.keys {
            fence(captureID: captureID, reason: reason)
        }
        transport.fenceAllInFlight(reason: reason.rawValue)
    }

    func status(captureID: UUID) -> ImpeccableCaptureState? {
        records[captureID]?.state
    }

    func captures(forTab tabID: UUID) -> [ImpeccableCaptureTicketSummary] {
        records.values
            .filter { $0.binding.tabId == tabID.uuidString }
            .sorted { $0.issuedAt < $1.issuedAt }
            .map {
                ImpeccableCaptureTicketSummary(
                    captureID: $0.captureID,
                    binding: $0.binding,
                    state: $0.state,
                    elementCount: $0.elementCount,
                    snapshotBytes: $0.snapshotBytes,
                    answeredRounds: $0.answeredRounds,
                    totalAnsweredHits: $0.totalAnsweredHits
                )
            }
    }

    struct ImpeccableCaptureTicketSummary: Sendable {
        let captureID: UUID
        let binding: ImpeccableCaptureBinding
        let state: ImpeccableCaptureState
        let elementCount: Int
        let snapshotBytes: Int
        let answeredRounds: Int
        let totalAnsweredHits: Int
    }

    // MARK: Result ingress

    /// The single result ingress for one engine result document. A result is
    /// usable only when *every* gate below passes; any refusal is a failure
    /// or superseded assessment with zero usable findings — never
    /// findings/inconclusive with counts:
    ///
    /// 1. the capture record must exist, be unfenced, and still match the
    ///    *current live* tab/document/generation (late results are refused
    ///    here even when no fence event or observer saw the change);
    /// 2. the per-capture native observer is re-sampled synchronously (a
    ///    missed/coalesced KVO delivery cannot admit a stale result);
    /// 3. the result document must parse and be this contract/version;
    /// 4. the full frozen-v1 `identity` echo must decode strictly and match
    ///    the native-issued capture identity field-by-field — task, session,
    ///    tab, document, generation, capture, url, hostname, exact-bit
    ///    viewport/scroll, capturedAtMs, producerTrust, producer provenance
    ///    incl. scriptDigest, and the complete redaction receipt. A missing,
    ///    malformed or foreign identity (including same captureId with any
    ///    foreign field) is a failure. The engine's own
    ///    `identityCheck.state == "verified"` claim never grants trust alone;
    /// 5. the fixed read-only producer probe re-measures the *current* CSS
    ///    viewport/scroll in the same isolated world: a world that no longer
    ///    holds the capture, or any exact-bit drift, fences and supersedes.
    ///    Native points under zoom are never converted to CSS coordinates;
    /// 6. only then does the truthful coverage assessment run (v1 can never
    ///    certify a page clean; the six required uncovered passes stay
    ///    reported honestly).
    func resultAssessment(captureID: UUID, resultJSON: Data) async -> ImpeccableResultAssessment {
        guard let record = records[captureID] else {
            return ImpeccableCoverage.failure(
                identityState: "absent",
                headline: "no such capture record: this result cannot belong to this session",
                identityRejections: ["no native capture record for \(captureID.uuidString)"]
            )
        }
        if case .fenced = record.state {
            return ImpeccableCoverage.assess(
                result: nil,
                parseFailure: nil,
                recordFenced: true,
                bindingMatches: false
            )
        }

        // Gate 1 — current live bindings (defense in depth: refuses late
        // results even when every fence wiring and observer missed a change).
        guard let session, !session.isReleased else {
            fence(captureID: captureID, reason: .released)
            return ImpeccableCoverage.superseded("the session was released before the result arrived")
        }
        guard let liveTab = session.tabs.first(where: { $0.id.uuidString == record.binding.tabId }) else {
            fence(captureID: captureID, reason: .tabClosed)
            return ImpeccableCoverage.superseded("the captured tab no longer exists")
        }
        guard liveTab.documentID == record.binding.documentId,
              liveTab.documentGeneration == record.binding.documentGeneration else {
            fence(captureID: captureID, reason: .documentSwap)
            return ImpeccableCoverage.superseded("the live document/generation no longer matches the capture")
        }

        // Gate 2 — synchronous native drift re-sample.
        if let observer = record.viewportObserver, observer.recheckNow() {
            fence(captureID: captureID, reason: observer.driftReason)
            return ImpeccableCoverage.superseded("the page scrolled or the viewport changed since the capture")
        }

        // Gate 3 — document shape.
        let parsed = try? ImpeccableResultDocument.parse(from: resultJSON)
        guard let parsed else {
            return ImpeccableCoverage.assess(
                result: nil,
                parseFailure: "result document malformed",
                recordFenced: false,
                bindingMatches: false
            )
        }

        // Gate 4 — full frozen identity verification against the native-issued
        // record. Absent, malformed or foreign identity is a failure with
        // zero usable findings.
        guard parsed.identityDecodingRejections.isEmpty else {
            return ImpeccableCoverage.failure(
                identityState: "mismatch",
                headline: "identityCheck mismatch: the result's identity echo is malformed (\(parsed.identityDecodingRejections.joined(separator: "; ")))",
                identityRejections: parsed.identityDecodingRejections
            )
        }
        guard let echo = parsed.identity else {
            return ImpeccableCoverage.failure(
                identityState: "absent",
                headline: "identity absent: a result without the full native-issued identity can never carry findings",
                identityRejections: ["result identity absent"]
            )
        }
        let identityMismatches = echo.mismatches(against: record.identity)
        guard identityMismatches.isEmpty else {
            return ImpeccableCoverage.failure(
                identityState: "mismatch",
                headline: "identityCheck mismatch: result identity differs from the native-issued capture record (\(identityMismatches.joined(separator: ", ")))",
                identityRejections: identityMismatches
            )
        }

        // Gate 5 — live CSS currency through the fixed read-only probe.
        let loaded: ImpeccableProducerScript.Loaded
        do {
            loaded = try scriptLoader()
        } catch {
            return ImpeccableCoverage.failure(
                identityState: "verified",
                headline: "failed: the fixed producer is unavailable; the live view cannot be re-measured (\(error))"
            )
        }
        let probe: ImpeccableProbeOutcome
        do {
            probe = try await transport.runProbe(
                script: loaded,
                arguments: ImpeccableProducerInvocation.probeArguments(
                    ImpeccableProducerInvocation.ProbeArguments(captureId: captureID.uuidString)
                ),
                in: liveTab.webView,
                contentWorld: session.contentWorld,
                captureId: captureID,
                deadline: ContinuousClock.now.advanced(by: .milliseconds(budgets.timeoutMs))
            )
        } catch {
            // Currency unproven is never a pass; the record stays active so a
            // retry can prove it, but this result is refused.
            return ImpeccableCoverage.failure(
                identityState: "verified",
                headline: "failed: the live view could not be re-measured (\(error))"
            )
        }
        // The probe suspended; a fence may have landed meanwhile.
        if let current = records[captureID], case .fenced = current.state {
            return ImpeccableCoverage.superseded("the capture was fenced while the live view was re-measured")
        }
        guard records[captureID] != nil else {
            return ImpeccableCoverage.failure(
                identityState: "absent",
                headline: "no such capture record: this result cannot belong to this session",
                identityRejections: ["capture record was released during assessment"]
            )
        }
        guard probe.holdsCapture, probe.recordedDocumentId == record.binding.documentId else {
            fence(captureID: captureID, reason: .navigation)
            return ImpeccableCoverage.superseded("the producer world no longer holds this capture; the result arrived too late")
        }
        guard probe.viewport.width.bitPattern == record.identity.viewport.width.bitPattern,
              probe.viewport.height.bitPattern == record.identity.viewport.height.bitPattern,
              probe.scroll.x.bitPattern == record.identity.scroll.x.bitPattern,
              probe.scroll.y.bitPattern == record.identity.scroll.y.bitPattern,
              probe.hostname == record.identity.hostname else {
            fence(captureID: captureID, reason: .viewport)
            return ImpeccableCoverage.superseded("the live viewport/scroll no longer matches the capture; the result arrived too late")
        }

        // Gate 6 — truthful coverage assessment (binding fully verified by
        // native; the engine's own mismatch/superseded claims are refused
        // inside `assess`, and v1 never certifies a page clean).
        return ImpeccableCoverage.assess(
            result: parsed,
            parseFailure: nil,
            recordFenced: false,
            bindingMatches: true
        )
    }

    /// Workspace-relative path of one staged bridge file, for tool output
    /// (relative to the capture's validated bridge root). `nil` when the file
    /// is not a strict descendant of that root — tool output carries relative
    /// paths plus the native receipt, never absolute paths or raw DOM.
    func relativeBridgePath(of file: URL, captureID: UUID) -> String? {
        guard let record = records[captureID] else { return nil }
        let prefix = record.bridgeRoot.path + "/"
        guard file.path.hasPrefix(prefix), file.path.count > prefix.count else { return nil }
        return String(file.path.dropFirst(prefix.count))
    }

    // MARK: Cleanup

    /// Delete the task-owned bridge subtree and drop the record. Fenced
    /// captures already lost their bytes; this removes the record itself.
    func cleanup(captureID: UUID) {
        guard let record = records.removeValue(forKey: captureID) else { return }
        record.viewportObserver?.invalidate()
        deleteBridgeFiles(of: record)
    }

    private func deleteBridgeFiles(of record: ImpeccableCaptureRecord) {
        removeRealBridgeDirectory(record.bridgeDirectory, under: record.bridgeRoot)
    }

    /// Deletes one bridge subtree only when it is still a real directory
    /// strictly under the root this capture owns. A symlinked or relocated
    /// bridge is never followed or removed through: the bytes are already
    /// untrusted at that point, and deleting through a substituted link could
    /// destroy unrelated data.
    private func removeRealBridgeDirectory(_ directory: URL, under root: URL) {
        guard directory.path.hasPrefix(root.path + "/") else { return }
        guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink == false else { return }
        try? fileManager.removeItem(at: directory)
    }

    /// The per-session retained set is bounded. Fenced records leave first;
    /// when only active records remain, the oldest active capture is fenced
    /// (files deleted) rather than letting state grow without limit.
    private func pruneRetainedRecords() {
        while records.count > maximumRetainedCaptures {
            let ordered = records.values.sorted { $0.issuedAt < $1.issuedAt }
            guard let candidate = ordered.first(where: { record in
                if case .fenced = record.state { return true }
                return false
            }) ?? ordered.first else { return }
            if case .active = candidate.state {
                fence(captureID: candidate.captureID, reason: .ownerHandoff)
            }
            cleanup(captureID: candidate.captureID)
        }
    }
}
