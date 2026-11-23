// FloeApp — task-scoped WKWebView execution contexts.
//
// One BrowserTaskSession owns exactly one task's WebKit tabs, document
// identities, visual evidence, event buffers and user-control state. The
// session is selected from a trusted ToolContext identity, never from model
// input, and it outlives any SwiftUI view that happens to show it. The visible
// browser is a projection of one session; other tasks keep executing in their
// own sessions while it is on screen.

#if canImport(SwiftUI) && canImport(WebKit) && canImport(UIKit)
import Combine
import Foundation
import UIKit
import WebKit
import FloeCore
import FloeTools

/// Immutable engine settings shared by every task session. Values are copied
/// at session creation so a session never reaches back into the visible
/// center for protocol or buffer configuration.
struct BrowserTaskSessionConfiguration {
    let protocolVersion: String
    let contentWorld: WKContentWorld
    let artifactDirectory: URL
    let maximumTabs: Int
    let maximumEventsPerTab: Int
    /// Resolved on the MainActor when a tab is created. The default preserves
    /// the historical persistent store for fixtures/tests that construct this
    /// value directly; the app center injects the shared store provider.
    let websiteDataStoreProvider: @MainActor () -> WKWebsiteDataStore
    let userAgentProvider: @MainActor () -> String?
    let linkOpenBehaviorProvider: @MainActor () -> BrowserLinkOpenBehavior
    let usesWideLayout: @MainActor (URL?) -> Bool

    init(
        protocolVersion: String,
        contentWorld: WKContentWorld,
        artifactDirectory: URL,
        maximumTabs: Int,
        maximumEventsPerTab: Int,
        websiteDataStoreProvider: @escaping @MainActor () -> WKWebsiteDataStore = { .default() },
        userAgentProvider: @escaping @MainActor () -> String? = { nil },
        linkOpenBehaviorProvider: @escaping @MainActor () -> BrowserLinkOpenBehavior = { .inApp },
        usesWideLayout: @escaping @MainActor (URL?) -> Bool = { _ in false }
    ) {
        self.protocolVersion = protocolVersion
        self.contentWorld = contentWorld
        self.artifactDirectory = artifactDirectory
        self.maximumTabs = maximumTabs
        self.maximumEventsPerTab = maximumEventsPerTab
        self.websiteDataStoreProvider = websiteDataStoreProvider
        self.userAgentProvider = userAgentProvider
        self.linkOpenBehaviorProvider = linkOpenBehaviorProvider
        self.usesWideLayout = usesWideLayout
    }
}

/// Durable, per-task restorable browser pages, keyed by the trusted
/// conversation identity. Only committed plain-GET pages on public origins
/// are kept: loopback/private-network pages, local previews, `about:blank`,
/// credential URLs, authentication callbacks and form-committed documents are
/// excluded, so a relaunch can replay them as a harmless GET (or not at all)
/// without ever crossing tasks or sessions.
struct BrowserTaskPageSnapshot: Codable, Equatable {
    /// Restore-time bounds: only recent tasks are kept, each with at most
    /// the visible tab limit, and only page URLs below a generous byte cap.
    static let maximumSnapshots = 64
    static let maximumTabs = 6

    struct Tab: Codable, Equatable {
        let id: UUID
        let pageURL: URL
    }
    let conversationID: UUID
    var tabs: [Tab]
    var selectedTabID: UUID?
    var savedAt: Date
}

/// Narrow callback surface from an execution context back to the service that
/// owns durable handoff receipts. Ordinary browser state is published by the
/// session itself; this host callback exists only for identity-bearing user
/// control transitions that must be persisted and routed.
@MainActor
protocol BrowserTaskSessionHost: AnyObject {
    func browserSessionRequestedUserControl(_ session: BrowserTaskSession, reason: String)
    /// First real human input on the page, address bar or tab chrome. The
    /// control center registers the takeover before the input proceeds.
    func browserSessionUserStartedInput(_ session: BrowserTaskSession, reason: String)
    /// The tab set, order, selection or one tab's committed restorable URL
    /// changed. The owning center refreshes the durable restore snapshot.
    /// Ephemeral hosts (and the default) ignore this: only the single durable
    /// center persists browser pages.
    func browserSessionRestorableStateDidChange(_ session: BrowserTaskSession)
}

@MainActor
extension BrowserTaskSessionHost {
    /// Hosts that predate gesture-level input detection keep the single
    /// existing takeover path; the center implements the dedicated one.
    func browserSessionUserStartedInput(_ session: BrowserTaskSession, reason: String) {
        browserSessionRequestedUserControl(session, reason: reason)
    }

    func browserSessionRestorableStateDidChange(_ session: BrowserTaskSession) {}
}

/// One model run's control of this task's browser. `runID` is the
/// runtime-issued logical owner (the parent run when a delegated child acts
/// for it); `id` is the token only `browser.release` must present; `epoch`
/// fences a completion once control has been released, re-acquired or handed
/// to the user.
struct BrowserControlLease: Sendable, Equatable, Hashable {
    let id: UUID
    let runID: UUID
    let epoch: Int
}

/// Result of the atomic acquisition that precedes every model page read or
/// action. A session owned by the user or by another run never yields a lease,
/// so no tool can fall back to reading the page.
enum BrowserControlAcquisition: Equatable {
    case acquired(BrowserControlLease)
    case heldByAnotherRun
    case needsUser(String)
}

enum BrowserControlReleaseOutcome: Equatable {
    case released
    /// Repeating the same release, or presenting a token from an earlier
    /// holding period, has no effect on the current holder.
    case alreadyReleased
    case heldByAnotherRun
}

/// Publicly safe description of the last model action for the preview strip.
/// It never carries page text, typed content, credentials or coordinates.
struct BrowserModelActivity: Equatable {
    enum Kind: String {
        case observing, navigating, clicking, typing, scrolling, waiting, exporting, downloading
    }
    var kind: Kind
    var at: Date
}

/// Pixels of a confirmed, bounded page region. Kept only while a local viewer is visible.
struct BrowserLivePreviewFrame {
    let image: UIImage
    let clickedLabel: String?
    let normalizedTarget: CGRect?
}

/// The tab owns its one WebKit page across model control, spectator layout changes and human input.
@MainActor
final class BrowserExecutionViewport {
    /// WebKit can share the opener's preferences with its new window.
    @MainActor private final class Scheduling {
        let preferences: WKPreferences
        private var idlePolicy: WKPreferences.InactiveSchedulingPolicy
        private var lockedViewports = 0

        init(_ preferences: WKPreferences) {
            self.preferences = preferences
            idlePolicy = preferences.inactiveSchedulingPolicy
        }

        func acquire() {
            if lockedViewports == 0 {
                idlePolicy = preferences.inactiveSchedulingPolicy
                preferences.inactiveSchedulingPolicy = .none
            }
            lockedViewports += 1
        }

        func release() {
            lockedViewports -= 1
            if lockedViewports == 0 { preferences.inactiveSchedulingPolicy = idlePolicy }
        }
    }

    private let scheduling: Scheduling
    private weak var page: WKWebView?
    private var host: UIView?
    private var adaptiveSize: CGSize?
    private(set) var fixedSize: CGSize?
    private let presentations = NSHashTable<BrowserPageMount>.weakObjects()
    private weak var owner: BrowserPageMount?
    private var nextOrder: UInt64 = 0
    private var preferred: UUID?
    private var originalAccessibilityHidden = false

    init(preferences: WKPreferences, opener: BrowserExecutionViewport? = nil) {
        if let opener, opener.scheduling.preferences === preferences { scheduling = opener.scheduling }
        else { scheduling = Scheduling(preferences) }
    }

    static var defaultSize: CGSize {
        UIDevice.current.userInterfaceIdiom == .phone
            ? CGSize(width: 390, height: 720) : CGSize(width: 1024, height: 768)
    }

    func lock(_ webView: WKWebView, wide: Bool) {
        page = webView
        if fixedSize == nil {
            let size = webView.bounds.size
            adaptiveSize = size.width >= 280 && size.height >= 240 ? size : Self.defaultSize
        }
        guard let adaptiveSize else { return }
        let size = wide ? CGSize(width: max(1280, adaptiveSize.width), height: adaptiveSize.height) : adaptiveSize
        if host == nil {
            let holder = UIView(frame: CGRect(origin: .zero, size: size))
            holder.isUserInteractionEnabled = false
            holder.accessibilityElementsHidden = true
            originalAccessibilityHidden = webView.accessibilityElementsHidden
            webView.endEditing(true)
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = []
            holder.addSubview(webView)
            host = holder
            scheduling.acquire()
        }
        fixedSize = size
        webView.isUserInteractionEnabled = false
        webView.accessibilityElementsHidden = true
        host?.frame.size = size
        webView.frame = CGRect(origin: .zero, size: size)
        webView.layoutIfNeeded()
        refreshPresentations()
    }

    func release(_ webView: WKWebView) {
        guard let host else { return }
        if webView.superview === host { webView.removeFromSuperview() }
        host.removeFromSuperview()
        if let adaptiveSize { webView.frame = CGRect(origin: .zero, size: adaptiveSize) }
        webView.isUserInteractionEnabled = true
        webView.accessibilityElementsHidden = originalAccessibilityHidden
        scheduling.release()
        self.host = nil
        adaptiveSize = nil
        fixedSize = nil
        refreshPresentations()
    }

    func preferPresentation(_ id: UUID) {
        preferred = id
        refreshPresentations()
    }

    fileprivate func add(_ mount: BrowserPageMount, page: WKWebView) {
        self.page = page
        if !presentations.contains(mount) {
            nextOrder += 1
            mount.order = nextOrder
            presentations.add(mount)
        }
        refreshPresentations()
    }

    fileprivate func remove(_ mount: BrowserPageMount) {
        presentations.remove(mount)
        mount.show(nil, waiting: false)
        if owner === mount { owner = nil }
        refreshPresentations()
    }

    fileprivate func refreshPresentations() {
        let mounted = presentations.allObjects
        let eligible = mounted.filter { $0.isVisible && $0.readOnly == (host != nil) }
        let chosen = eligible.max { lhs, rhs in
            if (lhs.presentationID == preferred) != (rhs.presentationID == preferred) { return rhs.presentationID == preferred }
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            if (lhs === owner) != (rhs === owner) { return rhs === owner }
            return lhs.order < rhs.order
        }
        for mount in mounted where mount !== chosen {
            mount.show(nil, waiting: mount.isVisible && mount.readOnly == (host != nil))
        }
        owner = chosen
        if let chosen { chosen.show(host ?? page, waiting: false) }
    }
}

/// One identity per actual UIKit presentation. Window changes and teardown immediately reassign the single page.
@MainActor
final class BrowserPageMount: UIView {
    private(set) var presentationID = UUID()
    private(set) var readOnly = false
    private(set) var priority = 0
    private var active = false
    fileprivate var order: UInt64 = 0
    private weak var viewport: BrowserExecutionViewport?
    private weak var content: UIView?
    private var sceneID: String?
    var ownsPage: Bool { content?.superview === self }
    fileprivate var isVisible: Bool {
        active && window != nil && sceneID == window?.windowScene?.session.persistentIdentifier
    }
    private lazy var claim: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle(IDELanguageRunText.t("在此窗口显示网页", "Show page in this window"), for: .normal)
        button.accessibilityIdentifier = "browser.showInWindow"
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            viewport?.preferPresentation(presentationID)
        }, for: .touchUpInside)
        button.sizeToFit()
        return button
    }()

    func configure(tab: BrowserTaskSession.Tab?, id: UUID, readOnly: Bool, priority: Int, active: Bool) {
        if viewport !== tab?.viewport { detach() }
        presentationID = id
        self.readOnly = readOnly
        self.priority = priority
        self.active = active
        if let tab {
            viewport = tab.viewport
            viewport?.add(self, page: tab.webView)
        }
    }

    func detach() {
        let previous = viewport
        viewport = nil
        previous?.remove(self)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        sceneID = window?.windowScene?.session.persistentIdentifier
        viewport?.refreshPresentations()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if claim.superview === self { claim.center = CGPoint(x: bounds.midX, y: bounds.midY) }
    }

    fileprivate func show(_ view: UIView?, waiting: Bool) {
        if content !== view, content?.superview === self { content?.removeFromSuperview() }
        content = view
        if let view, view.superview !== self {
            view.removeFromSuperview()
            view.translatesAutoresizingMaskIntoConstraints = true
            if !readOnly {
                view.frame = bounds
                view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            }
            addSubview(view)
        }
        if waiting, claim.superview !== self {
            addSubview(claim)
            setNeedsLayout()
        } else if !waiting, claim.superview === self {
            claim.removeFromSuperview()
        }
        if readOnly {
            isAccessibilityElement = view != nil
            accessibilityIdentifier = view != nil ? "browser.live.page" : nil
            accessibilityTraits = .image
            accessibilityLabel = IDELanguageRunText.t("网页只读预览", "Read-only page preview")
        }
    }
}

/// Both coordinate spaces are sampled. On iOS the keyboard may only change visualViewport.
struct BrowserPageGeometry: Codable, Equatable {
    let page: String
    let epoch, revision: Int
    let layoutWidth, layoutHeight, width, height: Double
    let left, top, scale, pageLeft, pageTop, scrollX, scrollY: Double

    func supportsPointMapping(in size: CGSize) -> Bool {
        width > 0 && height > 0 && size.width > 0 && size.height > 0 &&
            abs(left) <= 0.5 && abs(top) <= 0.5 &&
            abs(size.height - size.width * height / width) <= 2
    }
}

private struct BrowserLivePreviewSource: Equatable {
    let actionID: UUID
    let lease: BrowserControlLease
    let tabID: UUID
    let documentID: String
    let documentGeneration: Int
    let revision: Int
    let clickedRef: String?
    let page: BrowserPreviewPageIdentity
}

struct BrowserPreviewPageIdentity: Equatable {
    let tabID: UUID
    let documentID: String
    let generation: Int
    let routeGeneration: Int
    let url: URL?
}

private struct BrowserLivePreviewRegion: Decodable, Equatable {
    let viewportWidth, viewportHeight, scrollX, scrollY: CGFloat
    let target: BrowserBounds?
    let label: String?
}

typealias BrowserPreviewSnapshot = @MainActor (
    WKWebView, WKSnapshotConfiguration, @escaping @MainActor (UIImage?) -> Void
) -> Void

@MainActor
private final class BrowserPreviewImageRequest {
    private var waiter: CheckedContinuation<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var image: UIImage?

    func wait(timeout: Duration, start: () -> Void) async -> UIImage? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter = continuation
                guard !Task.isCancelled else { finish(nil); return }
                timeoutTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(nil)
                }
                start()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(nil) }
        }
        return image
    }

    func finish(_ result: UIImage?) {
        guard let waiter else { return }
        self.waiter = nil
        image = result
        timeoutTask?.cancel()
        timeoutTask = nil
        waiter.resume()
    }
}

@MainActor
private final class BrowserPreviewInvalidationHandler: NSObject, WKScriptMessageHandler {
    weak var session: BrowserTaskSession?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView = message.webView,
              let action = message.body as? String, let id = UUID(uuidString: action) else { return }
        session?.invalidateLivePreview(actionID: id, from: webView)
    }
}

/// A callback may never arrive after a WebKit process/navigation failure.
/// Resolve a single Sendable JSON receipt on callback, deadline, cancellation,
/// or owner release; a late callback cannot resume it twice. No task group
/// waits for an uncooperative native callback before returning the failure.
enum BrowserProbeError: Error, Sendable, Equatable {
    case timedOut
    case released
}

@MainActor
final class BrowserProbeRequest {
    typealias Completion = @MainActor @Sendable (Result<Any, Error>) -> Void
    private var continuation: CheckedContinuation<Data, Error>?
    private var deadlineTask: Task<Void, Never>?
    private var started = false

    func run(
        deadline: ContinuousClock.Instant,
        invoke: (@escaping Completion) -> Void
    ) async throws -> Data {
        precondition(!started)
        started = true
        try Task.checkCancellation()
        let bytes = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                guard !Task.isCancelled else {
                    finish(.failure(CancellationError()))
                    return
                }
                guard ContinuousClock.now < deadline else {
                    finish(.failure(BrowserProbeError.timedOut))
                    return
                }
                deadlineTask = Task { @MainActor [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) }
                    catch { return }
                    self?.finish(.failure(BrowserProbeError.timedOut))
                }
                invoke { [weak self] result in
                    guard let self, self.continuation != nil else { return }
                    do {
                        // SDK Any stays on MainActor. Only JSON Data crosses
                        // the continuation; no unchecked Sendable wrapper.
                        let value = try result.get()
                        let data = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
                        self.finish(.success(data))
                    } catch {
                        self.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
        try Task.checkCancellation()
        return bytes
    }

    func invalidate() { finish(.failure(BrowserProbeError.released)) }

    private func finish(_ result: Result<Data, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadlineTask?.cancel()
        deadlineTask = nil
        continuation.resume(with: result)
    }
}

/// Identity of one native navigation. Redirects keep the same WKNavigation.
@MainActor
private final class BrowserNavigationReceipt {
    enum State {
        case waiting, committed(document: String, generation: Int, url: URL?), replaced, failed(String), timedOut, cancelled
    }

    let id = UUID()
    let page: WKWebView
    let navigation: WKNavigation
    var started = false
    private(set) var awaitingStop = false
    private var stopIssued = false
    private(set) var state = State.waiting
    private let signal = AsyncStream<Void>.makeStream()

    init(page: WKWebView, navigation: WKNavigation) { self.page = page; self.navigation = navigation }

    func settle(_ next: State) {
        switch state {
        case .waiting, .committed: state = next
        case .cancelled, .timedOut, .replaced, .failed: break
        }
        awaitingStop = false
        signal.continuation.finish()
    }

    func requestStop(_ reason: State) {
        guard case .waiting = state else { return }
        awaitingStop = true
        state = reason
        signal.continuation.finish()
        stopIfStarted()
    }

    func stopIfStarted() {
        // stopLoading addresses the view, not a WKNavigation. Wait for this
        // exact navigation's didStart and never stop a replacement navigation.
        guard awaitingStop, started, !stopIssued else { return }
        stopIssued = true
        page.stopLoading()
    }

    func wait(until deadline: ContinuousClock.Instant) async {
        let timeout = Task { @MainActor in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            requestStop(.timedOut)
        }
        defer { timeout.cancel() }
        for await _ in signal.stream {}
        if Task.isCancelled { requestStop(.cancelled) }
    }
}

/// A single task's independent browser. All WebKit/UI work is MainActor.
///
/// `generation` is the owner lifecycle generation this session was created
/// under. The owning center bumps it on every release and every explicit
/// trusted reactivation, so a completion fenced to an older session can never
/// authorize work after the owner moved on to a newer generation. The
/// authoritative fences remain `isReleased` and the exact `sessionID`; the
/// generation makes the owner-level continuity explicit and testable.
@MainActor
final class BrowserTaskSession: NSObject, ObservableObject {
    enum SurfaceState: Equatable {
        case unbound
        case ready
        case loading
        case failed(String)
        case needsUser(String)
    }
    struct VisualFallbackEvidence {
        var documentID: String
        var sha256: String
        var capturedAt: Date
        var pixelWidth: Int
        var pixelHeight: Int
        var viewportWidth: Double
        var viewportHeight: Double
        var revision: Int
        var visualTextRegions: [VisualTextRegion]
        let geometry: BrowserPageGeometry
        let routeGeneration: Int
        let documentGeneration: Int
        let nativeViewport: ImpeccableViewportObserver
    }
    struct Tab: Identifiable {
        let id: UUID
        let openerID: UUID?
        let webView: WKWebView
        let viewport: BrowserExecutionViewport
        var documentID: String
        /// Monotonic per-tab Impeccable document generation: bumped whenever
        /// the document is replaced (commit, handoff invalidation). A capture
        /// record binds the generation it measured; answers require it to be
        /// unchanged (contract `documentGeneration`).
        var documentGeneration: Int
        var routeGeneration = 0
        var revision: Int
        var nextEventSequence: Int
        var events: [BrowserProtocolEvent]
        var visualFallbackEvidence: VisualFallbackEvidence?
        /// The committed plain-GET page eligible for durable restore. Nil for
        /// blank, loopback/private, local-preview, credential, auth-callback
        /// and form-committed documents; those are never replayed on relaunch.
        var restorableURL: URL?
        /// The provisional main-frame load just allowed was a non-GET (form)
        /// submission, so its commit must not become restorable.
        var formSubmissionPending = false
    }

    let conversationID: UUID
    /// Owner lifecycle generation stamped at creation by the owning center.
    let generation: Int
    @Published private(set) var sessionID = UUID()
    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var activeTabID: UUID?
    @Published private(set) var isUserControlling = false
    @Published var addressText = ""
    @Published var surfaceState: SurfaceState = .unbound
    /// Native chrome state, republished from the active tab's WebKit getters.
    @Published private(set) var estimatedProgress: Double = 0
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var activeTabTitle = ""
    /// Bumped when a tab's title/URL/progress changes; the tab strip reads
    /// WebKit getters and needs one observable signal.
    @Published private(set) var tabStateRevision = 0
    @Published private(set) var tabLimitNotice: String?
    @Published private(set) var humanActivitySequence: UInt64 = 0
    var returningToModel = false {
        didSet { if oldValue && !returningToModel { finishClosedWindows() } }
    }
    private var deferredWindowClosures: [UUID] = []
    /// True while pages persisted by the owning center are being re-navigated
    /// after a relaunch. The last committed URL remains available even if a
    /// replayed page cannot load.
    private(set) var restoreInProgress = false
    /// Restored tabs whose replayed GET has not committed, failed or settled.
    private var restoredTabIDsPending = Set<UUID>()
    var isEditingAddress = false
    private(set) var isReleased = false
    private(set) var activeExecutionCount = 0
    private var pendingProbes: [UUID: BrowserProbeRequest] = [:]
    private(set) var lastActivityAt = Date()

    /// The model run currently allowed to read or act on this browser. It
    /// survives between tool calls, model thinking and view changes until an
    /// explicit release, this run's real terminal state, or a user takeover.
    @Published private(set) var modelControl: BrowserControlLease?
    /// A takeover is waiting for an already dispatched WebKit action. User
    /// input stays disabled until it settles or the user retries explicitly;
    /// an uncertain result is never replayed.
    @Published private(set) var takeoverPending = false
    @Published private(set) var usesFixedViewport = false
    /// A different tab the user is browsing while the model keeps its own
    /// active tab. Never use this as the default target for model commands.
    @Published private(set) var humanBrowsingTabID: UUID?
    @Published private(set) var lastModelActivity: BrowserModelActivity?
    @Published private(set) var livePreviewFrame: BrowserLivePreviewFrame?
    private var livePreviewSource: BrowserLivePreviewSource?
    private var livePreviewObservers = Set<UUID>()
    private var previewWorker: Task<Void, Never>?
    private var previewGeneration = 0
    private var previewAttemptedGeneration: Int?
    private let previewSnapshot: BrowserPreviewSnapshot
    private let previewSnapshotTimeout: Duration
    // A timed-out native callback can still arrive. Keep its per-tab slot until that callback or process termination.
    private var pendingNativePreviews: [UUID: BrowserPreviewImageRequest] = [:]
    // This private world answers only whether a shadow tree exists. It is never used by a browser tool.
    private lazy var previewPrivacyWorld: WKContentWorld? = {
        guard #available(iOS 27.0, *) else { return nil }
        let configuration = WKContentWorld.Configuration()
        configuration.allowAccessingClosedShadowRoots = true
        return WKContentWorld(configuration: configuration)
    }()
    private var controlEpochCounter = 0
    private var dispatchBusy = false
    private var dispatchWaiters: [DispatchWaiter] = []
    private struct DispatchWaiter {
        let id: UUID
        let epoch: Int
        let continuation: CheckedContinuation<Bool, Never>
    }

    // A lease can span multiple model turns. Only active tool work belongs in the UI.
    private struct VisibleOperation {
        let id: UUID
        let lease: BrowserControlLease
        let kind: BrowserModelActivity.Kind
    }
    @Published private var visibleOperations: [VisibleOperation] = []
    var visibleModelActivity: BrowserModelActivity.Kind? {
        guard isModelActive else { return nil }
        return visibleOperations.last(where: { $0.lease == modelControl })?.kind
    }

    func beginVisibleOperation(_ kind: BrowserModelActivity.Kind, lease: BrowserControlLease?) -> UUID? {
        guard let lease, isModelControlCurrent(lease) else { return nil }
        let id = UUID()
        visibleOperations.append(.init(id: id, lease: lease, kind: kind))
        return id
    }
    func endVisibleOperation(_ id: UUID?) {
        guard let id else { return }
        visibleOperations.removeAll { $0.id == id }
    }

    var hasModelControlHolder: Bool { modelControl != nil }
    var currentModelRunID: UUID? { modelControl?.runID }
    var isModelActive: Bool { modelControl != nil && !isUserControlling && !takeoverPending }

    /// Native Impeccable capture/Needs bridge for this task's browser.
    /// Records are fenced synchronously from the lifecycle points below;
    /// the service itself never issues work to other sessions.
    private(set) lazy var impeccableCaptures = BrowserImpeccableCaptureService(session: self)

    /// Task-owned staged-export pull service (`browser.exportFile`). Same
    /// fence discipline as the capture service: in-flight exports are fenced
    /// synchronously from the lifecycle points below, and a page can never
    /// start an export — only an authorized native tool call can.
    private(set) lazy var stagedExports = BrowserStagedExportService(session: self)
    private(set) lazy var downloads = BrowserDownloadService()

    private weak var host: BrowserTaskSessionHost?
    private let protocolVersion: String
    /// Internal for the task-owned Impeccable capture service only.
    let contentWorld: WKContentWorld
    let artifactDirectory: URL
    private let maximumTabs: Int
    private let maximumEventsPerTab: Int
    private let websiteDataStoreProvider: @MainActor () -> WKWebsiteDataStore
    private let userAgentProvider: @MainActor () -> String?
    private let linkOpenBehaviorProvider: @MainActor () -> BrowserLinkOpenBehavior
    private let usesWideLayout: @MainActor (URL?) -> Bool
    private let openSystemURL: @MainActor (URL) -> Void
    private var tabObservations: [UUID: [NSKeyValueObservation]] = [:]
    // Native command dispatch is serialized per session.
    private var navigationReceipt: BrowserNavigationReceipt?

    var tabLimit: Int { maximumTabs }
    var websiteDataStore: WKWebsiteDataStore {
        activeWebView?.configuration.websiteDataStore ?? websiteDataStoreProvider()
    }

    init(
        conversationID: UUID,
        generation: Int,
        configuration: BrowserTaskSessionConfiguration,
        host: BrowserTaskSessionHost,
        previewSnapshotTimeout: Duration = .seconds(2),
        previewSnapshot: @escaping BrowserPreviewSnapshot = { webView, configuration, finish in
            webView.takeSnapshot(with: configuration) { image, _ in finish(image) }
        },
        openSystemURL: @escaping @MainActor (URL) -> Void = {
            UIApplication.shared.open($0, options: [:], completionHandler: nil)
        }
    ) {
        self.conversationID = conversationID
        self.generation = generation
        self.host = host
        self.protocolVersion = configuration.protocolVersion
        self.contentWorld = configuration.contentWorld
        self.artifactDirectory = configuration.artifactDirectory
        self.maximumTabs = configuration.maximumTabs
        self.maximumEventsPerTab = configuration.maximumEventsPerTab
        self.websiteDataStoreProvider = configuration.websiteDataStoreProvider
        self.userAgentProvider = configuration.userAgentProvider
        self.linkOpenBehaviorProvider = configuration.linkOpenBehaviorProvider
        self.usesWideLayout = configuration.usesWideLayout
        self.openSystemURL = openSystemURL
        self.previewSnapshot = previewSnapshot
        self.previewSnapshotTimeout = previewSnapshotTimeout
        super.init()
    }

    // MARK: - Tabs

    var activeTab: Tab? {
        guard let activeTabID else { return nil }
        return tabs.first(where: { $0.id == activeTabID })
    }

    var activeWebView: WKWebView? { activeTab?.webView }
    var fixedViewportTab: Tab? { tabs.first { $0.viewport.fixedSize != nil } }
    var humanBrowsingTab: Tab? { tabs.first { $0.id == humanBrowsingTabID } }

    var previewPageIdentity: BrowserPreviewPageIdentity? {
        (isModelActive ? fixedViewportTab ?? activeTab : activeTab).map { BrowserPreviewPageIdentity(tabID: $0.id, documentID: $0.documentID,
            generation: $0.documentGeneration, routeGeneration: $0.routeGeneration, url: $0.webView.url) }
    }

    // MARK: - Durable page restore

    /// One restorable committed page of this task's browser.
    struct RestorablePage: Equatable {
        let id: UUID
        let pageURL: URL
    }

    /// The committed plain-GET pages, in tab order, eligible for restore.
    var restorablePages: [RestorablePage] {
        tabs.compactMap { tab in
            guard let url = tab.restorableURL, BrowserURLPolicy.isRestorablePageURL(url) else { return nil }
            return RestorablePage(id: tab.id, pageURL: url)
        }
    }

    /// The selection to persist: the active tab when it is restorable, else
    /// the first restorable tab.
    var restorableSelectedTabID: UUID? {
        if let activeTabID, tabs.contains(where: { $0.id == activeTabID && $0.restorableURL != nil }) {
            return activeTabID
        }
        return restorablePages.first?.id
    }

    /// Decides whether one committed document may be replayed after relaunch.
    /// A form-committed document never becomes restorable even on a public
    /// origin: a replayed GET cannot reproduce a submitted form.
    static func restorableCommitURL(loadURL: URL?, formSubmission: Bool) -> URL? {
        guard !formSubmission, let loadURL, BrowserURLPolicy.isRestorablePageURL(loadURL) else { return nil }
        return loadURL
    }

    /// Rebuilds this task's tabs after an app relaunch. Every tab gets a fresh
    /// WebKit page and re-navigates its persisted URL as a plain GET: tab IDs,
    /// order and the selection survive, while document identities, model
    /// control and receipts are all minted fresh by the new session.
    func restoreCommittedPages(_ snapshot: BrowserTaskPageSnapshot) {
        guard !isReleased, tabs.isEmpty, !restoreInProgress else { return }
        let entries = snapshot.tabs
            .filter { BrowserURLPolicy.isRestorablePageURL($0.pageURL) }
            .prefix(maximumTabs)
        guard !entries.isEmpty else {
            _ = createTab()
            surfaceState = .ready
            return
        }
        lastActivityAt = Date()
        restoreInProgress = true
        restoredTabIDsPending.removeAll()
        for entry in entries {
            guard let id = makeTab(selectForModel: false, restoredID: entry.id) else { continue }
            // Keep the validated pageURL on the tab from the start: an
            // offline or failed replay must not erase the durable snapshot
            // of a page that was legitimately committed before the relaunch.
            tabs[tabs.count - 1].restorableURL = entry.pageURL
            restoredTabIDsPending.insert(id)
            tabs[tabs.count - 1].webView.load(URLRequest(url: entry.pageURL))
        }
        guard !tabs.isEmpty else {
            restoreInProgress = false
            _ = createTab()
            surfaceState = .ready
            return
        }
        let selected = tabs.first(where: { $0.id == snapshot.selectedTabID }) ?? tabs[0]
        activate(selected.id)
        surfaceState = .loading
    }

    /// A restored tab's replayed navigation reached a terminal WebKit state.
    private func noteRestoreSettled(tabID: UUID) {
        guard restoreInProgress else { return }
        restoredTabIDsPending.remove(tabID)
        guard restoredTabIDsPending.isEmpty else { return }
        restoreInProgress = false
        if !isUserControlling, !takeoverPending, case .loading = surfaceState { surfaceState = .ready }
    }

    func focusModelPageForTakeover() {
        guard isModelActive, let modelTab = fixedViewportTab else { return }
        if activeTabID != modelTab.id { activate(modelTab.id) }
    }

    @discardableResult
    func createTab() -> UUID? {
        makeTab()
    }

    private func makeTab(for popup: (configuration: WKWebViewConfiguration, opener: Tab)? = nil,
                         selectForModel: Bool = true,
                         restoredID: UUID? = nil) -> UUID? {
        guard !isReleased, !takeoverPending, !returningToModel else { return nil }
        guard tabs.count < maximumTabs else {
            tabLimitNotice = IDELanguageRunText.t(
                "此浏览器最多支持 6 个标签页。关闭一个标签页后再打开新的标签页。",
                "This browser supports up to 6 tabs. Close a tab before opening another."
            )
            return nil
        }
        tabLimitNotice = nil
        lastActivityAt = Date()
        // The supplied window configuration preserves WebKit's opener relationship,
        // data store and already-installed user scripts and message handler.
        let configuration = popup?.configuration ?? newTabConfiguration()
        // Give off-screen/task-owned tabs a real viewport before SwiftUI
        // presents them. A zero-sized WKWebView makes every DOM node appear
        // invisible and breaks semantic observation during background work.
        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: BrowserExecutionViewport.defaultSize),
            configuration: configuration
        )
        webView.customUserAgent = userAgentProvider()
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        let id = restoredID ?? UUID()
        tabs.append(Tab(
            id: id,
            openerID: popup?.opener.id,
            webView: webView,
            viewport: BrowserExecutionViewport(preferences: configuration.preferences, opener: popup?.opener.viewport),
            documentID: UUID().uuidString,
            documentGeneration: 0,
            revision: 0,
            nextEventSequence: 1,
            events: [],
            visualFallbackEvidence: nil,
            restorableURL: nil
        ))
        if selectForModel {
            resetLivePreview()
            activeTabID = id
            if modelControl != nil, let tab = activeTab { lockViewport(tab) }
        } else if restoredID == nil {
            humanBrowsingTabID = id
        }
        installObservers(for: id, webView: webView)
        appendEvent(tabID: id, method: "Target.targetCreated")
        syncChromeState()
        if restoredID == nil { host?.browserSessionRestorableStateDidChange(self) }
        return id
    }

    /// Presentation-only selection; it never changes the model's target.
    func browseWhileModelRuns(_ id: UUID?) {
        guard modelControl != nil, !isUserControlling, !takeoverPending else { return }
        guard let id else { humanBrowsingTabID = nil; return }
        guard let tab = tabs.first(where: { $0.id == id }),
              tab.viewport.fixedSize == nil else { return }
        humanBrowsingTabID = id
    }

    @discardableResult func createHumanBrowsingTab() -> UUID? {
        guard modelControl != nil, !isUserControlling else { return nil }
        return makeTab(selectForModel: false)
    }

    func closeHumanBrowsingTab(_ id: UUID) {
        guard humanBrowsingTabID == id, modelControl != nil,
              let modelTab = fixedViewportTab, modelTab.id != id else { return }
        if activeTabID == id { activate(modelTab.id) }
        humanBrowsingTabID = nil
        close(id)
    }

    private func newTabConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStoreProvider()
        configuration.preferences.isElementFullscreenEnabled = true
        let invalidation = BrowserPreviewInvalidationHandler()
        invalidation.session = self
        configuration.userContentController.add(invalidation, contentWorld: contentWorld, name: "floePreviewChanged")
        configuration.userContentController.addUserScript(WKUserScript(
            source: Self.protocolProbeSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: contentWorld
        ))
        return configuration
    }

    func activate(_ id: UUID) {
        guard !isReleased, !takeoverPending, !returningToModel, tabs.contains(where: { $0.id == id }) else { return }
        // A user tab switch is presentation only. Any in-flight tool command
        // captured its own tabID/webView before awaiting, so switching here
        // never retargets a pending AI action.
        if id != activeTabID { resetLivePreview() }
        activeTabID = id
        if modelControl != nil, let tab = activeTab { lockViewport(tab) }
        isEditingAddress = false
        refreshVisibleAddress()
        syncChromeState()
        appendEvent(tabID: id, method: "Target.targetActivated")
        host?.browserSessionRestorableStateDidChange(self)
    }

    func close(_ id: UUID) {
        close(id, returningTo: nil)
    }

    private func close(_ id: UUID, returningTo openerID: UUID?, discarding stopped: BrowserNavigationReceipt? = nil) {
        guard !isReleased, (!takeoverPending || stopped != nil), !returningToModel,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let page = tabs[index].webView
        let receipt = navigationReceipt.flatMap { $0.page === page ? $0 : nil }
        if let stopped, receipt !== stopped || unresponsiveNavigationID != stopped.id { return }
        impeccableCaptures.fence(tabID: id, reason: .tabClosed)
        stagedExports.fenceTab(id, reason: .tabClosed)
        page.stopLoading()
        if tabs.count == 1, openerID == nil, receipt == nil {
            // Closing the last tab leaves an honest blank tab; the task's
            // browser session and its ownership remain intact.
            blank(tabID: id)
            return
        }
        tabObservations.removeValue(forKey: id)?.forEach { $0.invalidate() }
        tabs[index].viewport.release(tabs[index].webView)
        tabs[index].webView.navigationDelegate = nil
        tabs[index].webView.uiDelegate = nil
        tabs[index].webView.removeFromSuperview()
        page.isUserInteractionEnabled = false
        tabs.remove(at: index)
        noteRestoreSettled(tabID: id)
        if humanBrowsingTabID == id {
            humanBrowsingTabID = tabs.first(where: { $0.id == openerID && $0.viewport.fixedSize == nil })?.id
        }
        pendingNativePreviews.removeValue(forKey: id)?.finish(nil)
        if let receipt {
            settleNavigation(receipt, as: .replaced)
            if stopped != nil { finishTakeoverIfIdle() }
        }
        if tabs.isEmpty {
            // WebKit already closed the last script-opened window. Its page cannot be reused.
            activeTabID = nil
            _ = createTab()
            return
        }
        if activeTabID == id {
            let next = tabs.first(where: { $0.id == openerID }) ?? tabs[min(index, tabs.count - 1)]
            activate(next.id)
            return
        }
        syncChromeState()
        host?.browserSessionRestorableStateDidChange(self)
    }

    private func finishClosedWindows() {
        guard !isReleased, !takeoverPending, !returningToModel, !deferredWindowClosures.isEmpty else { return }
        let closed = deferredWindowClosures
        deferredWindowClosures.removeAll()
        for id in closed {
            if let opener = tabs.first(where: { $0.id == id })?.openerID { close(id, returningTo: opener) }
        }
    }

    private func blank(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        if tabID == activeTabID { resetLivePreview() }
        tabs[index].webView.stopLoading()
        tabs[index].documentID = UUID().uuidString
        tabs[index].documentGeneration += 1
        tabs[index].revision = 0
        tabs[index].visualFallbackEvidence = nil
        tabs[index].restorableURL = nil
        noteRestoreSettled(tabID: tabID)
        tabs[index].webView.load(URLRequest(url: URL(string: "about:blank")!))
        addressText = ""
        appendEvent(tabID: tabID, method: "Page.frameNavigated")
        syncChromeState()
        host?.browserSessionRestorableStateDidChange(self)
    }

    func clearTabLimitNotice() {
        tabLimitNotice = nil
    }

    func navigateFromAddressBar() {
        guard !isReleased, !takeoverPending, !returningToModel else { return }
        if let currentURL = activeWebView?.url,
           Self.isLocalPreview(currentURL),
           addressText == Self.visibleAddress(for: activeWebView) {
            if let activeTabID {
                impeccableCaptures.fence(tabID: activeTabID, reason: .reload)
                stagedExports.fenceTab(activeTabID, reason: .reload)
            }
            activeWebView?.reload()
            return
        }
        if let activeTabID {
            impeccableCaptures.fence(tabID: activeTabID, reason: .navigation)
            stagedExports.fenceTab(activeTabID, reason: .navigation)
        }
        let candidate = addressText.contains("://") ? addressText : "https://\(addressText)"
        guard let url = try? BrowserURLPolicy.validate(candidate, conversationID: conversationID, allowLocalNetwork: true),
              let activeWebView else { return }
        if let activeTabID { noteRestoreSettled(tabID: activeTabID) }
        activeWebView.load(URLRequest(url: url))
    }

    /// The title never replaces the navigable address, including loopback pages.
    var technicalAddress: String? { activeWebView?.url?.absoluteString }

    var isDisplayingLocalPreview: Bool {
        activeWebView?.url.map(Self.isLocalPreview) ?? false
    }

    func refreshVisibleAddress() {
        guard !isReleased, !isEditingAddress else { return }
        addressText = Self.visibleAddress(for: activeWebView)
    }

    private static func visibleAddress(for webView: WKWebView?) -> String {
        webView?.url?.absoluteString ?? ""
    }

    private static func isLocalPreview(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http" else { return false }
        return url.host == "127.0.0.1" || url.host?.lowercased() == "localhost"
    }

    /// Chrome state is derived from the active tab's public WebKit getters.
    /// KVO only schedules this; no model command path depends on it.
    private func syncChromeState() {
        guard let tab = tabs.first(where: { $0.id == activeTabID }) else {
            estimatedProgress = 0
            isLoading = false
            canGoBack = false
            canGoForward = false
            activeTabTitle = ""
            tabStateRevision &+= 1
            return
        }
        estimatedProgress = max(0, min(1, tab.webView.estimatedProgress))
        isLoading = tab.webView.isLoading
        canGoBack = tab.webView.canGoBack
        canGoForward = tab.webView.canGoForward
        activeTabTitle = tab.webView.title ?? ""
        if !isEditingAddress { addressText = tab.webView.url?.absoluteString ?? "" }
        tabStateRevision &+= 1
    }

    private func installObservers(for id: UUID, webView: WKWebView) {
        var observations: [NSKeyValueObservation] = []
        let schedule: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in _ = self?.syncChromeState() }
        }
        observations.append(webView.observe(\.estimatedProgress, options: [.initial, .new]) { _, _ in schedule() })
        observations.append(webView.observe(\.isLoading, options: [.initial, .new]) { _, _ in schedule() })
        observations.append(webView.observe(\.canGoBack, options: [.initial, .new]) { _, _ in schedule() })
        observations.append(webView.observe(\.canGoForward, options: [.initial, .new]) { _, _ in schedule() })
        observations.append(webView.observe(\.title, options: [.initial, .new]) { _, _ in schedule() })
        observations.append(webView.observe(\.url, options: [.old, .new]) { [weak self] _, change in
            guard change.oldValue != change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
                tabs[index].routeGeneration &+= 1
                if activeTabID == id { resetLivePreview() }
                syncChromeState()
            }
        })
        tabObservations[id] = observations
    }

    /// Applies the settings-managed User-Agent to existing tabs. Ordinary
    /// website data keeps the shared persistent store; advanced-AI OFF never
    /// replaces it or logs the user out.
    func applyBrowserSettings(userAgent: String?) {
        guard !isReleased else { return }
        for tab in tabs { tab.webView.customUserAgent = userAgent }
        syncChromeState()
    }

    /// Native authenticated download for this task's browser. The chosen tab's
    /// WKWebView supplies its website data store, so existing session cookies
    /// are used without putting them in model context.
    /// Advanced-browser OFF fences in-flight downloads owned by this surface.
    /// Cookie/storage reads revalidate their captured generation in the tool.
    func cancelAdvancedBrowserWork() {
        downloads.cancelAll()
    }

    func startDownload(
        tabID: UUID?,
        url: URL,
        destinationURL: URL,
        relativePath: String,
        maxBytes: Int,
        overwrite: Bool,
        cancellation: CancellationToken
    ) async throws -> BrowserDownloadReceipt {
        guard !isReleased else { throw FloeError.validationFailed("This task's browser was released") }
        guard !isUserControlling, !takeoverPending else {
            throw FloeError.validationFailed("Wait for the user to return browser control before downloading")
        }
        guard let selected = tabID ?? activeTabID,
              let tab = tabs.first(where: { $0.id == selected }) else {
            throw FloeError.validationFailed("The source browser tab is no longer available")
        }
        let suggested = url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent
        return try await downloads.start(
            webView: tab.webView,
            request: URLRequest(url: url),
            destinationURL: destinationURL,
            relativePath: relativePath,
            suggestedFilename: suggested,
            maxBytes: maxBytes,
            overwrite: overwrite,
            cancellation: cancellation
        )
    }

    // MARK: - Ownership lifecycle

    var userControlMessage: String? {
        if isUserControlling || takeoverPending {
            return "The user controls this browser; wait until the user returns control"
        }
        if navigationReceipt?.awaitingStop == true { return "The browser is waiting for its previous navigation to stop." }
        if isEditingAddress { return "The user is using the address bar; wait until they return control" }
        return nil
    }

    /// Acquire before a model reads or acts on the page. An existing holder
    /// or a user editing the browser keeps control of the same session.
    func acquireModelControl(runID: UUID) throws -> BrowserControlAcquisition {
        guard !isReleased else {
            throw FloeError.validationFailed("This task's browser session was released")
        }
        if let userControlMessage { return .needsUser(userControlMessage) }
        if let holder = modelControl {
            return holder.runID == runID ? .acquired(holder) : .heldByAnotherRun
        }
        // A new holding period after any earlier release/handoff must not
        // reuse element or visual evidence from the previous period.
        if controlEpochCounter > 0 {
            invalidateDocumentsForHandoff()
        }
        controlEpochCounter += 1
        let lease = BrowserControlLease(id: UUID(), runID: runID, epoch: controlEpochCounter)
        modelControl = lease
        if let tab = activeTab { lockViewport(tab) }
        if case .needsUser = surfaceState { surfaceState = .ready }
        return .acquired(lease)
    }

    /// Explicit model release. Releasing an already released holding period,
    /// or a token from an earlier holding period, is a no-op; it can never
    /// release the run's newer acquisition.
    func releaseModelControl(controlID: UUID, runID: UUID) -> BrowserControlReleaseOutcome {
        guard let holder = modelControl else { return .alreadyReleased }
        guard holder.runID == runID else { return .heldByAnotherRun }
        guard holder.id == controlID else { return .alreadyReleased }
        navigationReceipt?.requestStop(.cancelled)
        controlEpochCounter += 1
        modelControl = nil
        lastModelActivity = nil
        resetLivePreview()
        // In-flight page work of this holding period is fenced with it; an
        // uncommitted capture/export is never published after release.
        impeccableCaptures.fenceAll(reason: .ownerHandoff)
        stagedExports.fenceAll(reason: .ownerHandoff)
        downloads.cancelAll()
        fenceDispatchQueue()
        releaseViewportsIfIdle()
        return .released
    }

    /// The owning run reached a real terminal state (completed, failed,
    /// cancelled, or checkpointed). Only that exact logical run loses the
    /// page; the page, tabs, login and scroll position are preserved. A user
    /// takeover is never undone by a run ending.
    @discardableResult
    func endModelControl(runID: UUID) -> Bool {
        guard let holder = modelControl, holder.runID == runID else { return false }
        navigationReceipt?.requestStop(.cancelled)
        controlEpochCounter += 1
        modelControl = nil
        lastModelActivity = nil
        resetLivePreview()
        impeccableCaptures.fenceAll(reason: .ownerHandoff)
        stagedExports.fenceAll(reason: .ownerHandoff)
        downloads.cancelAll()
        fenceDispatchQueue()
        releaseViewportsIfIdle()
        return true
    }

    /// Whether this exact holding period still authorizes page access. Every
    /// page payload is checked against it immediately before it is returned
    /// or committed.
    func isModelControlCurrent(_ lease: BrowserControlLease?) -> Bool {
        guard !isReleased, !isUserControlling, !takeoverPending else { return false }
        guard let lease else { return true }
        guard let holder = modelControl, holder == lease,
              controlEpochCounter == lease.epoch else { return false }
        return true
    }

    func assertModelControlCurrent(_ lease: BrowserControlLease?) throws {
        guard isModelControlCurrent(lease) else {
            throw FloeError.validationFailed(
                "Browser control was released or returned to the user; stop and re-observe after control is returned"
            )
        }
    }

    /// First real human input: register the takeover before the input is
    /// allowed to change the page. Idle browsing that no model owns stays
    /// local and creates no handoff receipt.
    @discardableResult
    func registerUserInput(reason: String = "You started using this browser") -> Bool {
        guard !isReleased, !returningToModel else { return false }
        host?.browserSessionUserStartedInput(self, reason: reason)
        if !takeoverPending { humanActivitySequence &+= 1 }
        return !takeoverPending && modelControl == nil
    }

    @discardableResult
    func reloadFromUser() -> Bool {
        guard registerUserInput(reason: "You reloaded the page"), let webView = activeWebView else { return false }
        webView.reload()
        return true
    }

    /// Transfers the page to the user. The model holder is revoked
    /// synchronously, queued model dispatches are fenced, and user input is
    /// held back only while an action already sent to WebKit settles.
    func beginUserTakeover(reason: String?) {
        guard !isReleased else { return }
        resetLivePreview()
        controlEpochCounter += 1
        modelControl = nil
        lastModelActivity = nil
        fenceDispatchQueue()
        isUserControlling = true
        navigationReceipt?.requestStop(.cancelled)
        takeoverPending = activeExecutionCount > 0 || navigationReceipt?.awaitingStop == true
        releaseViewportsIfIdle()
        activeWebView?.isUserInteractionEnabled = !takeoverPending
        // The user can move any tab at any moment now; every capture bound to
        // this session fences at the instant of takeover.
        impeccableCaptures.fenceAll(reason: .userTakeover)
        stagedExports.fenceAll(reason: .userTakeover)
        downloads.cancelAll()
        surfaceState = .needsUser(reason ?? "User takeover is active")
    }

    /// The user returned control. Previous element/document references and
    /// visual evidence stay invalid; the next model acquisition is a new
    /// epoch. No new model run is started from here.
    func endUserControl() {
        guard !isReleased, isUserControlling, !takeoverPending else { return }
        resetLivePreview()
        isUserControlling = false
        takeoverPending = false
        isEditingAddress = false
        controlEpochCounter += 1
        modelControl = nil
        lastModelActivity = nil
        activeWebView?.isUserInteractionEnabled = true
        activeWebView?.endEditing(true)
        if case .needsUser = surfaceState { surfaceState = .ready }
    }

    func setUserControlling(_ value: Bool) {
        if value { beginUserTakeover(reason: "User takeover is active") }
        else { endUserControl() }
    }

    /// A manual retry and the WebKit completion share the same drain check.
    func finishTakeoverIfIdle() {
        releaseViewportsIfIdle()
        guard isUserControlling, takeoverPending, activeExecutionCount == 0 else { return }
        if navigationReceipt?.awaitingStop == true {
            objectWillChange.send()
            return
        }
        takeoverPending = false
        finishClosedWindows()
        activeWebView?.isUserInteractionEnabled = true
    }

    var unresponsiveNavigationID: UUID? {
        guard isUserControlling, takeoverPending, !returningToModel, activeExecutionCount == 0,
              let receipt = navigationReceipt, receipt.awaitingStop else { return nil }
        return receipt.id
    }

    func closeUnresponsiveNavigation(_ confirmedID: UUID) {
        guard unresponsiveNavigationID == confirmedID, let receipt = navigationReceipt,
              let tab = tabs.first(where: { $0.webView === receipt.page }) else { return }
        close(tab.id, returningTo: tab.openerID, discarding: receipt)
    }

    private func settleNavigation(_ receipt: BrowserNavigationReceipt, as state: BrowserNavigationReceipt.State) {
        let wasStopping = receipt.awaitingStop
        receipt.settle(state)
        if wasStopping, navigationReceipt === receipt {
            navigationReceipt = nil
            // The delegate may still be updating the tab by index. Process deferred
            // popup closures only after this callback has finished using that index.
            Task { @MainActor [weak self] in self?.finishTakeoverIfIdle() }
        }
    }

    private func lockViewport(_ tab: Tab, destination: URL? = nil) {
        guard modelControl != nil else { return }
        // Dispatch is serialized: once a new model target is selected, old
        // tabs no longer need a fixed viewport and remain available to users.
        for other in tabs where other.id != tab.id && other.viewport.fixedSize != nil {
            other.viewport.release(other.webView)
        }
        // Existing pages keep the dimensions chosen at acquisition. A new origin may have an explicit wide layout.
        if tab.viewport.fixedSize == nil || destination != nil {
            tab.viewport.lock(tab.webView, wide: usesWideLayout(destination ?? tab.webView.url))
        }
        if !usesFixedViewport { usesFixedViewport = true }
    }

    private func releaseViewportsIfIdle() {
        guard usesFixedViewport, modelControl == nil, activeExecutionCount == 0, navigationReceipt?.awaitingStop != true else { return }
        for tab in tabs { tab.viewport.release(tab.webView) }
        usesFixedViewport = false
        if let id = humanBrowsingTabID {
            humanBrowsingTabID = nil
            activate(id)
        }
    }

    private func targetsHumanBrowsingTab(_ command: BrowserCommand) -> Bool {
        guard let humanBrowsingTabID else { return false }
        switch command.action {
        case .activateTab(let id), .closeTab(let id): return id == humanBrowsingTabID
        case .protocolInfo, .create, .listTabs: return false
        default: return (command.tabID ?? activeTabID) == humanBrowsingTabID
        }
    }

    private func fenceDispatchQueue() {
        let waiters = dispatchWaiters
        dispatchWaiters.removeAll()
        for waiter in waiters { waiter.continuation.resume(returning: false) }
    }

    /// Serializes actions for this one browser session. A queued call is
    /// woken with `false` when control changed while it waited; it then
    /// returns stale/needsUser without touching the page.
    private func enterDispatch(epoch: Int) async -> Bool {
        if !dispatchBusy {
            dispatchBusy = true
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: false)
                } else {
                    dispatchWaiters.append(DispatchWaiter(
                        id: waiterID, epoch: epoch, continuation: continuation))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelDispatchWaiter(waiterID) }
        }
    }

    /// A cancelled tool call must not remain queued behind another action.
    private func cancelDispatchWaiter(_ id: UUID) {
        guard let index = dispatchWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = dispatchWaiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func leaveDispatch() {
        while !dispatchWaiters.isEmpty {
            let next = dispatchWaiters.removeFirst()
            if next.epoch == controlEpochCounter, !isUserControlling, !takeoverPending {
                next.continuation.resume(returning: true)
                return
            }
            next.continuation.resume(returning: false)
        }
        dispatchBusy = false
    }

    /// Invalidate every element/document reference before the user or a new
    /// run takes the page. Only this task's evidence is affected.
    func invalidateDocumentsForHandoff() {
        guard !isReleased else { return }
        resetLivePreview()
        for index in tabs.indices {
            tabs[index].documentID = UUID().uuidString
            tabs[index].documentGeneration += 1
            tabs[index].visualFallbackEvidence = nil
            impeccableCaptures.fence(tabID: tabs[index].id, reason: .ownerHandoff)
            stagedExports.fenceTab(tabs[index].id, reason: .ownerHandoff)
        }
    }

    /// Service-owned release. Stops only this task's WebViews and fences its
    /// delegate/probe callbacks; no other task session is touched.
    func release() {
        guard !isReleased else { return }
        resetLivePreview()
        livePreviewObservers.removeAll()
        pendingNativePreviews.values.forEach { $0.finish(nil) }
        pendingNativePreviews.removeAll()
        deferredWindowClosures.removeAll()
        isReleased = true
        restoreInProgress = false
        restoredTabIDsPending.removeAll()
        navigationReceipt?.settle(.replaced)
        navigationReceipt = nil
        for tab in tabs { tab.viewport.release(tab.webView) }
        usesFixedViewport = false
        controlEpochCounter += 1
        modelControl = nil
        lastModelActivity = nil
        fenceDispatchQueue()
        impeccableCaptures.fenceAll(reason: .released)
        stagedExports.fenceAll(reason: .released)
        downloads.cancelAll()
        tabObservations.values.forEach { $0.forEach { $0.invalidate() } }
        tabObservations.removeAll()
        let probes = Array(pendingProbes.values)
        pendingProbes.removeAll()
        probes.forEach { $0.invalidate() }
        isUserControlling = false
        takeoverPending = false
        surfaceState = .unbound
        for tab in tabs {
            tab.webView.stopLoading()
            tab.webView.navigationDelegate = nil
            tab.webView.uiDelegate = nil
            tab.webView.removeFromSuperview()
        }
        tabs.removeAll()
        activeTabID = nil
        addressText = ""
    }

    // MARK: - Command execution

    /// Unleased execution retained for native services and the existing
    /// protocol tests. It still obeys every user-control/lifecycle fence and
    /// never creates model control.
    func execute(_ command: BrowserCommand) async -> BrowserResult {
        await execute(command, control: nil)
    }

    /// Executes one command for a model holding a lease, or for a native
    /// service that already passed the same user-control fence. Dispatches
    /// are serialized; a takeover or release while queued returns without
    /// touching the page, and every page payload is rechecked before it is
    /// returned.
    func execute(_ command: BrowserCommand, control: BrowserControlLease?) async -> BrowserResult {
        guard !isReleased else {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        }
        lastActivityAt = Date()
        activeExecutionCount += 1
        defer {
            activeExecutionCount -= 1
            finishTakeoverIfIdle()
        }

        guard command.version == 1 else {
            return failure(command, status: .failed, code: "version", "Unsupported browser protocol version")
        }
        guard command.sessionID == sessionID else {
            return failure(command, status: .stale, code: "session", "Browser session is no longer active")
        }
        if command.action != .protocolInfo {
            if targetsHumanBrowsingTab(command) {
                return failure(command, status: .needsUser, code: "tab-in-use", "The user is using this tab; choose another tab or wait")
            }
            if isUserControlling || takeoverPending {
                return failure(command, status: .needsUser, code: "takeover", "The user currently controls the browser")
            }
            if let control {
                if !isModelControlCurrent(control) {
                    return failure(
                        command,
                        status: .stale,
                        code: "control",
                        "Browser control was released or handed to the user"
                    )
                }
            } else if modelControl != nil {
                // A native/protocol caller without a run identity must never
                // bypass the run that currently owns this page.
                return failure(
                    command,
                    status: .stale,
                    code: "control",
                    "This browser is in use by a run; it must release control first"
                )
            }
        }

        let epoch = controlEpochCounter
        guard await enterDispatch(epoch: epoch) else {
            let takenOver = isUserControlling || takeoverPending
            return failure(
                command,
                status: takenOver ? .needsUser : .stale,
                code: takenOver ? "takeover" : "control",
                takenOver
                    ? "The user currently controls the browser"
                    : "Browser control was released or handed to the user"
            )
        }
        defer { leaveDispatch() }
        if command.action != .protocolInfo, navigationReceipt?.awaitingStop == true {
            return failure(command, status: isUserControlling ? .needsUser : .blocked, code: "navigation-stopping",
                           "The previous navigation is still stopping. No new action was dispatched.")
        }

        // Recheck after waiting behind another action. A takeover, release or
        // newer holder while this call was queued must never reach the page.
        guard !isReleased else {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        }
        if command.action != .protocolInfo {
            if targetsHumanBrowsingTab(command) {
                return failure(command, status: .needsUser, code: "tab-in-use", "The user is using this tab; choose another tab or wait")
            }
            if isUserControlling || takeoverPending {
                return failure(command, status: .needsUser, code: "takeover", "The user currently controls the browser")
            }
            if let control {
                if !isModelControlCurrent(control) {
                    return failure(
                        command,
                        status: .stale,
                        code: "control",
                        "Browser control was released or handed to the user"
                    )
                }
            } else if modelControl != nil {
                return failure(
                    command,
                    status: .stale,
                    code: "control",
                    "This browser is in use by a run; it must release control first"
                )
            }
        }

        if command.action != .protocolInfo, (command.tabID ?? activeTabID) == activeTabID {
            resetLivePreview()
        }
        let kind = activityKind(for: command.action)
        let visible = command.action == .protocolInfo ? nil : beginVisibleOperation(kind, lease: control)
        defer { endVisibleOperation(visible) }
        let result = await executeAuthorized(command, control: control)
        if command.action != .protocolInfo, !isModelControlCurrent(control) {
            // A result that already says needsUser carries no page payload;
            // keep its specific reason (for example sensitive input).
            if result.status == .needsUser {
                if let artifact = result.page?.screenshotArtifact { discardArtifact(artifact) }
                return result
            }
            // A withheld capture must not leave a viewport thumbnail of the
            // user's page on disk.
            if let artifact = result.page?.screenshotArtifact { discardArtifact(artifact) }
            let takenOver = isUserControlling || takeoverPending
            return failure(
                command,
                status: takenOver ? .needsUser : .stale,
                code: takenOver ? "takeover" : "control",
                takenOver
                    ? "The user currently controls the browser; this result was withheld"
                    : "Browser control was released or handed to the user; this result was withheld"
            )
        }
        if result.status == .ok, let control, command.action != .protocolInfo,
           let page = result.page, let tab = tabs.first(where: { $0.documentID == page.documentID }) {
            lastModelActivity = BrowserModelActivity(kind: kind, at: Date())
            recordLivePreview(for: command, page: page, tab: tab, lease: control)
        }
        return result
    }

    /// Returns a needsUser/stale result when the page may no longer be read
    /// or touched at this exact await boundary.
    private func pageAccessFailure(
        _ command: BrowserCommand,
        control: BrowserControlLease?
    ) -> BrowserResult? {
        if targetsHumanBrowsingTab(command) {
            return failure(command, status: .needsUser, code: "tab-in-use", "The user is using this tab; choose another tab or wait")
        }
        if isReleased {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        }
        if isUserControlling || takeoverPending {
            return failure(command, status: .needsUser, code: "takeover", "The user currently controls the browser")
        }
        if let control, !isModelControlCurrent(control) {
            return failure(
                command,
                status: .stale,
                code: "control",
                "Browser control was released or handed to the user"
            )
        }
        return nil
    }

    func setLivePreviewObservation(_ observer: UUID, visible: Bool) {
        let wasEmpty = livePreviewObservers.isEmpty
        if visible {
            guard !isReleased, livePreviewObservers.insert(observer).inserted else { return }
        } else {
            guard livePreviewObservers.remove(observer) != nil else { return }
        }
        guard livePreviewObservers.isEmpty != wasEmpty else { return }
        previewGeneration &+= 1
        if livePreviewObservers.isEmpty {
            previewWorker?.cancel()
            if livePreviewFrame != nil { livePreviewFrame = nil }
        } else {
            scheduleLivePreview()
        }
    }

    #if DEBUG
    /// The native test host waits on the actual bounded work, including a denial before any pixels exist.
    func waitForCurrentPreviewUpdate() async {
        while let worker = previewWorker { await worker.value }
    }
    #endif

    private func resetLivePreview(clearActivity: Bool = true) {
        livePreviewSource = nil
        previewGeneration &+= 1
        previewWorker?.cancel()
        if livePreviewFrame != nil { livePreviewFrame = nil }
        if clearActivity, lastModelActivity != nil { lastModelActivity = nil }
    }

    fileprivate func invalidateLivePreview(actionID: UUID, from webView: WKWebView) {
        guard livePreviewSource?.actionID == actionID, activeWebView === webView else { return }
        resetLivePreview(clearActivity: false)
    }

    private func recordLivePreview(for command: BrowserCommand, page: PageSnapshot, tab: Tab, lease: BrowserControlLease) {
        guard !page.isLoading, !tab.webView.isLoading, let identity = previewPageIdentity,
              identity.tabID == tab.id, identity.url?.absoluteString == page.url else { return }
        var clickedRef: String?
        switch command.action {
        case .click(.element(let ref, let id)) where id == page.documentID:
            clickedRef = ref
        case .observe, .wait, .navigate, .reload, .back, .forward, .scroll, .screenshot, .activateTab:
            break
        default:
            return
        }
        livePreviewSource = BrowserLivePreviewSource(
            actionID: command.requestID, lease: lease, tabID: tab.id, documentID: tab.documentID,
            documentGeneration: tab.documentGeneration, revision: page.revision, clickedRef: clickedRef, page: identity)
        previewGeneration &+= 1
        scheduleLivePreview()
    }

    private func scheduleLivePreview() {
        guard previewWorker == nil, !livePreviewObservers.isEmpty, let source = livePreviewSource,
              previewAttemptedGeneration != previewGeneration else { return }
        let generation = previewGeneration
        previewAttemptedGeneration = generation
        previewWorker = Task { @MainActor [weak self] in
            guard let self else { return }
            await captureLivePreview(source, generation: generation)
            previewWorker = nil
            scheduleLivePreview()
        }
    }

    private func currentPreviewTab(_ source: BrowserLivePreviewSource, generation: Int) -> Tab? {
        guard !Task.isCancelled, generation == previewGeneration, !livePreviewObservers.isEmpty,
              livePreviewSource == source, previewPageIdentity == source.page, isModelControlCurrent(source.lease),
              let tab = activeTab, tab.id == source.tabID, tab.documentID == source.documentID,
              tab.documentGeneration == source.documentGeneration, !tab.webView.isLoading else { return nil }
        return tab
    }

    private func livePreviewRegion(_ source: BrowserLivePreviewSource, generation: Int, in webView: WKWebView) async throws -> BrowserLivePreviewRegion? {
        guard let previewPrivacyWorld else { return nil }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        let inspectable = try await probeValue("""
            if (!document.documentElement) return false;
            const walker = document.createTreeWalker(document.documentElement, NodeFilter.SHOW_ELEMENT);
            let count = 0;
            for (let el = document.documentElement; el; el = walker.nextNode()) {
              if (++count > 6000 || el.shadowRoot) return false;
            }
            return true;
            """, arguments: [:], in: webView, world: previewPrivacyWorld, deadline: deadline)
        guard inspectable as? Bool == true, currentPreviewTab(source, generation: generation) != nil else { return nil }
        let value = try await probeValue(
            "return globalThis.__floeProtocol?.previewRegion(documentID, revision, actionID, clickedRef) ?? null;",
            arguments: ["documentID": source.documentID, "revision": source.revision,
                        "actionID": source.actionID.uuidString, "clickedRef": source.clickedRef ?? ""],
            in: webView, deadline: deadline)
        guard let value = value as? [String: Any] else { return nil }
        return try JSONDecoder().decode(BrowserLivePreviewRegion.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func captureLivePreview(_ source: BrowserLivePreviewSource, generation: Int) async {
        guard let tab = currentPreviewTab(source, generation: generation),
              let region = try? await livePreviewRegion(source, generation: generation, in: tab.webView),
              currentPreviewTab(source, generation: generation) != nil,
              region.viewportWidth > 0, region.viewportHeight > 0 else { return }
        let bounds = tab.webView.bounds
        let scale = bounds.width / region.viewportWidth
        guard !bounds.isEmpty, abs(bounds.height - region.viewportHeight * scale) < 3 else { return }
        let config = WKSnapshotConfiguration()
        config.rect = bounds
        let outputScale = min(1, 720 / (max(bounds.width, bounds.height) * max(1, tab.webView.traitCollection.displayScale)))
        config.snapshotWidth = NSNumber(value: Double(bounds.width * outputScale))
        guard pendingNativePreviews[tab.id] == nil else { return }
        let image = await nativeSnapshot(of: tab, configuration: config, timeout: previewSnapshotTimeout)
        guard let image,
              currentPreviewTab(source, generation: generation) != nil, tab.webView.bounds == bounds,
              let after = try? await livePreviewRegion(source, generation: generation, in: tab.webView), after == region,
              currentPreviewTab(source, generation: generation) != nil else { return }
        let target = region.target.map {
            CGRect(x: $0.x / region.viewportWidth, y: $0.y / region.viewportHeight,
                   width: $0.width / region.viewportWidth, height: $0.height / region.viewportHeight)
        }
        livePreviewFrame = BrowserLivePreviewFrame(image: image, clickedLabel: region.label, normalizedTarget: target)
    }

    private func activityKind(for action: BrowserAction) -> BrowserModelActivity.Kind {
        let kind: BrowserModelActivity.Kind
        switch action {
        case .navigate, .create, .activateTab, .closeTab, .back, .forward, .reload:
            kind = .navigating
        case .click:
            kind = .clicking
        case .type:
            kind = .typing
        case .scroll:
            kind = .scrolling
        case .wait:
            kind = .waiting
        case .screenshot, .observe, .listTabs, .events, .listLinks, .readTable, .readText, .protocolInfo, .takeover:
            kind = .observing
        }
        return kind
    }

    private func executeAuthorized(_ command: BrowserCommand, control: BrowserControlLease?) async -> BrowserResult {
        switch command.action {
        case .protocolInfo:
            return BrowserResult(
                requestID: command.requestID,
                status: .ok,
                protocolVersion: protocolVersion
            )
        case .create:
            guard let id = createTab() else {
                return failure(command, status: .blocked, code: "tab-limit", "The six-tab limit was reached")
            }
            return await observeResult(command, tabID: id, cursor: nil)
        case .listTabs:
            return await observeResult(command, tabID: command.tabID ?? activeTabID, cursor: nil)
        case .activateTab(let id):
            activate(id)
            return await observeResult(command, tabID: id, cursor: nil)
        case .closeTab(let id):
            close(id)
            return await observeResult(command, tabID: activeTabID, cursor: nil)
        case .takeover:
            host?.browserSessionRequestedUserControl(self, reason: "Browser control was handed to the user")
            return failure(command, status: .needsUser, code: "takeover", "Browser control was handed to the user")
        default:
            break
        }

        guard let tabID = command.tabID ?? activeTabID,
              let index = tabs.firstIndex(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        let tab = tabs[index]
        if control != nil { lockViewport(tab) }
        if let expected = command.expectedDocumentID, expected != tab.documentID {
            return failure(command, status: .stale, code: "document", "The page changed; observe it again")
        }

        do {
            switch command.action {
            case .navigate(let value):
                let url = try BrowserURLPolicy.validate(value, conversationID: conversationID, allowLocalNetwork: true)
                if let denied = pageAccessFailure(command, control: control) { return denied }
                if control != nil { lockViewport(tab, destination: url) }
                impeccableCaptures.fence(tabID: tabID, reason: .navigation)
                stagedExports.fenceTab(tabID, reason: .navigation)
                return await navigateAndObserve(command, tab: tab, url: url, control: control)
            case .back:
                if let denied = pageAccessFailure(command, control: control) { return denied }
                impeccableCaptures.fence(tabID: tabID, reason: .navigation)
                stagedExports.fenceTab(tabID, reason: .navigation)
                tab.webView.goBack()
            case .forward:
                if let denied = pageAccessFailure(command, control: control) { return denied }
                impeccableCaptures.fence(tabID: tabID, reason: .navigation)
                stagedExports.fenceTab(tabID, reason: .navigation)
                tab.webView.goForward()
            case .reload:
                if let denied = pageAccessFailure(command, control: control) { return denied }
                impeccableCaptures.fence(tabID: tabID, reason: .reload)
                stagedExports.fenceTab(tabID, reason: .reload)
                tab.webView.reload()
            case .observe(let cursor):
                return await observeResult(command, tabID: tabID, cursor: cursor)
            case .screenshot:
                return try await captureVisualEvidence(command, in: tab, control: control).result
            case .click(let requestedTarget):
                let target: BrowserTarget
                if case .visualText(let reference) = requestedTarget {
                    let evidence = try validateVisualFallback(command, in: tab)
                    guard let region = evidence.visualTextRegions.first(where: { $0.reference == reference }) else {
                        throw BrowserPolicyError.blocked(
                            "The visual text reference is absent or stale; capture a new browser screenshot"
                        )
                    }
                    target = .point(x: Double(region.centerX), y: Double(region.centerY))
                } else {
                    target = requestedTarget
                }
                if case .point(let x, let y) = target {
                    let evidence = try validateVisualFallback(command, in: tab)
                    guard x >= 0, y >= 0,
                          x < Double(evidence.pixelWidth),
                          y < Double(evidence.pixelHeight) else {
                        throw BrowserPolicyError.blocked(
                            "Visual click coordinates are outside the referenced screenshot"
                        )
                    }
                    guard evidence.geometry.supportsPointMapping(in: tab.webView.bounds.size),
                          !evidence.nativeViewport.recheckNow() else {
                        throw BrowserInteractionError.stale("The visible page changed. Capture a new screenshot before clicking.")
                    }
                    let cssTarget = BrowserTarget.point(
                        x: x / Double(evidence.pixelWidth) * evidence.geometry.width,
                        y: y / Double(evidence.pixelHeight) * evidence.geometry.height
                    )
                    if let denied = pageAccessFailure(command, control: control) { return denied }
                    try await perform(
                        target: cssTarget, in: tab, operation: "click", text: nil, submit: false,
                        visualFallbackReason: command.visualFallbackReason, geometry: evidence.geometry
                    )
                    // The page may already have acted. Re-observe the outcome without issuing another input.
                    do {
                        try await Task.sleep(for: .milliseconds(250))
                    } catch { return unconfirmedClick(command, control: control) }
                    guard let postTab = tabs.first(where: { $0.id == tab.id }) else {
                        return unconfirmedClick(command, control: control)
                    }
                    let captured: (result: BrowserResult, evidence: VisualFallbackEvidence)
                    do {
                        captured = try await captureVisualEvidence(command, in: postTab, control: control)
                    } catch { return unconfirmedClick(command, control: control) }
                    var result = captured.result
                    let current = captured.evidence
                    let navigated = current.documentGeneration != evidence.documentGeneration
                    if !navigated && (current.geometry.epoch != evidence.geometry.epoch ||
                                      current.routeGeneration != evidence.routeGeneration || evidence.nativeViewport.recheckNow()) {
                        result.status = .failed
                        let message = "The click was dispatched. The viewport changed, so its effect is unconfirmed. Inspect the new screenshot before any further action."
                        result.error = BrowserFailure(code: "dispatched-unconfirmed", message: message)
                        result.message = message
                        return result
                    }
                    let changed = navigated || current.geometry.revision > evidence.geometry.revision || current.sha256 != evidence.sha256
                    if changed {
                        result.message = "Visual click produced an observable page change; the returned screenshot is post-click evidence."
                    } else {
                        let message = "Visual click produced no observable page change; the target was not confirmed. Use the returned post-click screenshot to choose a different point or hand control to the user."
                        result.status = .failed
                        result.message = message
                        result.error = BrowserFailure(code: "no-observable-effect", message: message)
                    }
                    return result
                }
                if let denied = pageAccessFailure(command, control: control) { return denied }
                try await perform(
                    target: target,
                    in: tab,
                    operation: "click",
                    text: nil,
                    submit: false,
                    visualFallbackReason: command.visualFallbackReason,
                    actionID: command.requestID
                )
            case .type(let target, let text, let submit):
                guard text.utf8.count <= 16 * 1024 else {
                    throw BrowserPolicyError.blocked("Browser input exceeds 16 KiB")
                }
                if let denied = pageAccessFailure(command, control: control) { return denied }
                try await perform(
                    target: target,
                    in: tab,
                    operation: "type",
                    text: text,
                    submit: submit,
                    visualFallbackReason: nil
                )
            case .scroll(let x, let y):
                if let denied = pageAccessFailure(command, control: control) { return denied }
                // Any scroll invalidates every outstanding capture on this
                // tab before the page actually moves.
                impeccableCaptures.fence(tabID: tabID, reason: .scroll)
                _ = try await tab.webView.callAsyncJavaScript(
                    "window.scrollBy(dx, dy); return true;",
                    arguments: ["dx": x, "dy": y],
                    in: nil,
                    contentWorld: contentWorld
                )
                appendEvent(tabID: tabID, method: "Input.dispatchMouseEvent", detail: "scroll")
            case .wait(let condition):
                return await waitResult(command, tabID: tabID, condition: condition)
            case .events(let afterSequence, let limit):
                return await eventsResult(
                    command,
                    tabID: tabID,
                    afterSequence: afterSequence,
                    limit: limit
                )
            case .listLinks(let cursor, let limit):
                return await linksResult(command, tabID: tabID, cursor: cursor, limit: limit)
            case .readTable(let index, let cursor, let limit):
                return await tableResult(command, tabID: tabID, index: index, cursor: cursor, limit: limit)
            case .readText(let start, let maxCharacters):
                return await textResult(command, tabID: tabID, start: start, maxCharacters: maxCharacters)
            case .protocolInfo, .create, .listTabs, .activateTab, .closeTab, .takeover:
                break
            }
            let observation = await observeResult(command, tabID: tabID, cursor: nil)
            if case .type(_, _, let submit) = command.action, submit,
               observation.status == .stale, observation.error?.code == "document" {
                return BrowserResult(
                    requestID: command.requestID,
                    status: .ok,
                    message: "Input and submit were dispatched. The page changed; observe it before the next action."
                )
            }
            return observation
        } catch BrowserProbeError.timedOut {
            return failure(command, status: .timeout, code: "timeout", "WebKit did not return a current viewport in time.")
        } catch BrowserInteractionError.needsUser(let message) {
            host?.browserSessionRequestedUserControl(self, reason: message)
            return failure(command, status: .needsUser, code: "takeover", message)
        } catch BrowserInteractionError.stale(let message) {
            return failure(command, status: .stale, code: "document", message)
        } catch BrowserInteractionError.uncertain(let message) {
            return failure(command, status: .failed, code: "dispatched-unconfirmed", message)
        } catch let error as BrowserPolicyError {
            return failure(command, status: .blocked, code: "policy", error.localizedDescription)
        } catch {
            return failure(command, status: .failed, code: "webkit", error.localizedDescription)
        }
    }

    /// CDP-shaped, allowlisted dispatch surface for integrations that prefer
    /// method/params requests over Floe's typed BrowserAction enum.
    func executeProtocol(_ request: FloeBrowserProtocolCommand) async -> FloeBrowserProtocolResponse {
        let action: BrowserAction
        let documentID = request.documentID
        switch request.method {
        case .getVersion:
            action = .protocolInfo
        case .getTargets, .getDocument:
            action = request.method == .getTargets ? .listTabs : .observe(cursor: nil)
        case .createTarget:
            action = .create
        case .activateTarget:
            guard let targetID = request.targetID else {
                return protocolFailure(request, "Target.activateTarget requires targetID")
            }
            action = .activateTab(targetID)
        case .closeTarget:
            guard let targetID = request.targetID else {
                return protocolFailure(request, "Target.closeTarget requires targetID")
            }
            action = .closeTab(targetID)
        case .navigate:
            guard let url = request.url, !url.isEmpty else {
                return protocolFailure(request, "Page.navigate requires url")
            }
            action = .navigate(url: url)
        case .reload:
            action = .reload
        case .captureScreenshot:
            action = .screenshot
        case .waitForLoad:
            action = .wait(.load)
        case .waitForDOM:
            action = .wait(.domContentLoaded)
        case .waitForIdle:
            action = .wait(.idle(milliseconds: min(5_000, max(100, request.timeoutMilliseconds ?? 500))))
        case .dispatchMouseEvent:
            if let ref = request.ref, let documentID {
                action = .click(.element(ref: ref, documentID: documentID))
            } else if let x = request.x, let y = request.y,
                      x.isFinite, y.isFinite, x >= 0, y >= 0,
                      request.screenshotSHA256?.isEmpty == false,
                      request.fallbackReason?.isEmpty == false {
                action = .click(.point(x: x, y: y))
            } else {
                return protocolFailure(request, "Coordinate Input.dispatchMouseEvent requires documentID, a fresh screenshotSHA256, and fallbackReason")
            }
        case .insertText:
            guard let ref = request.ref, !ref.isEmpty,
                  let documentID, !documentID.isEmpty,
                  let text = request.text, text.utf8.count <= 16 * 1024 else {
                return protocolFailure(request, "Input.insertText requires ref, documentID, and bounded text")
            }
            action = .type(
                .element(ref: ref, documentID: documentID),
                text: text,
                submit: request.submit ?? false
            )
        case .getEvents:
            action = .events(
                afterSequence: request.afterSequence,
                limit: min(100, max(1, request.limit ?? 50))
            )
        case .getLinks:
            action = .listLinks(
                cursor: request.cursor,
                limit: min(100, max(1, request.limit ?? 50))
            )
        case .getTable:
            action = .readTable(
                index: max(0, min(49, request.tableIndex ?? 0)),
                cursor: request.cursor,
                limit: min(100, max(1, request.limit ?? 50))
            )
        case .getTextRange:
            action = .readText(
                start: max(0, request.startCharacter ?? 0),
                maxCharacters: min(65_536, max(1_000, request.maxCharacters ?? 16_384))
            )
        }
        let command = BrowserCommand(
            requestID: UUID(),
            sessionID: request.sessionID,
            tabID: request.targetID,
            expectedDocumentID: documentID,
            timeoutMilliseconds: min(30_000, max(250, request.timeoutMilliseconds ?? 15_000)),
            visualEvidenceSHA256: request.screenshotSHA256,
            visualFallbackReason: request.fallbackReason,
            action: action
        )
        return FloeBrowserProtocolResponse(
            id: request.id,
            protocolVersion: protocolVersion,
            result: await execute(command)
        )
    }

    private func protocolFailure(
        _ request: FloeBrowserProtocolCommand,
        _ message: String
    ) -> FloeBrowserProtocolResponse {
        FloeBrowserProtocolResponse(
            id: request.id,
            protocolVersion: protocolVersion,
            result: BrowserResult(
                requestID: UUID(),
                status: .failed,
                message: message,
                error: BrowserFailure(code: "invalid-params", message: message),
                protocolVersion: protocolVersion
            )
        )
    }

    private func perform(
        target: BrowserTarget,
        in tab: Tab,
        operation: String,
        text: String?,
        submit: Bool,
        visualFallbackReason: String?,
        actionID: UUID? = nil,
        geometry: BrowserPageGeometry? = nil
    ) async throws {
        let script = """
        const protocol = globalThis.__floeProtocol;
        if (!protocol) return {status:'stale'};
        return protocol.perform(operation, target, documentID, text, submit, visualFallbackReason, actionID, expectedGeometry);
        """
        let targetObject: [String: Any]
        switch target {
        case .element(let ref, let documentID):
            targetObject = ["kind": "element", "ref": ref, "documentID": documentID]
        case .point(let x, let y):
            targetObject = ["kind": "point", "x": x, "y": y]
        case .visualText:
            throw BrowserPolicyError.blocked(
                "Visual text references must be resolved from fresh screenshot evidence"
            )
        }
        var arguments: [String: Any] = [
                "operation": operation,
                "target": targetObject,
                "documentID": tab.documentID,
                "text": text ?? "",
                "submit": submit,
                "visualFallbackReason": visualFallbackReason ?? "",
                "actionID": actionID?.uuidString ?? "", "expectedGeometry": NSNull()
        ]
        if let geometry {
            arguments["expectedGeometry"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(geometry))
        }
        let value: Any?
        do {
            value = try await tab.webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: contentWorld)
        } catch {
            throw BrowserInteractionError.uncertain("WebKit did not confirm whether the input ran. Observe the page before another action; do not repeat the input automatically.")
        }
        let status = (value as? [String: Any])?["status"] as? String
        if status == "needsUser" { throw BrowserInteractionError.needsUser("Sensitive input requires user takeover") }
        if status == "stale" { throw BrowserInteractionError.stale("The target is stale; observe the page again") }
        if status == "structured" {
            let ref = (value as? [String: Any])?["ref"] as? String ?? "unknown"
            throw BrowserPolicyError.blocked(
                "A structured target (\(ref)) is available at these coordinates; use browser.click"
            )
        }
        if status != "ok" { throw BrowserPolicyError.blocked("The target cannot accept this action") }
        appendEvent(
            tabID: tab.id,
            method: operation == "click" ? "Input.dispatchMouseEvent" : "Input.insertText"
        )
    }

    private func validateVisualFallback(
        _ command: BrowserCommand,
        in tab: Tab
    ) throws -> VisualFallbackEvidence {
        guard let reason = command.visualFallbackReason,
              ["noStructuredTarget", "insufficientStructuredInformation"].contains(reason) else {
            throw BrowserPolicyError.blocked(
                "Coordinate fallback requires a reason that structured information is absent or insufficient"
            )
        }
        guard let expectedDigest = command.visualEvidenceSHA256?.lowercased(),
              expectedDigest.count == 64,
              expectedDigest.allSatisfy(\.isHexDigit),
              let evidence = tab.visualFallbackEvidence,
              evidence.documentID == tab.documentID,
              evidence.sha256 == expectedDigest,
              evidence.pixelWidth > 0,
              evidence.pixelHeight > 0,
              evidence.viewportWidth > 0,
              evidence.viewportHeight > 0,
              Date().timeIntervalSince(evidence.capturedAt) <= 120 else {
            throw BrowserPolicyError.blocked(
                "Coordinate fallback requires a fresh screenshot from the current page"
            )
        }
        guard evidence.documentGeneration == tab.documentGeneration, evidence.routeGeneration == tab.routeGeneration,
              !evidence.nativeViewport.recheckNow() else {
            throw BrowserInteractionError.stale("The page or its viewport changed. Capture a new screenshot before clicking.")
        }
        return evidence
    }

    private func pageGeometry(_ tab: Tab, deadline: ContinuousClock.Instant) async throws -> BrowserPageGeometry {
        let value = try await probeValue("return globalThis.__floeProtocol?.geometry() ?? null;",
                                         arguments: [:], in: tab.webView, deadline: deadline)
        guard let object = value as? [String: Any] else {
            throw BrowserInteractionError.stale("The visible page is not ready for a screenshot.")
        }
        return try JSONDecoder().decode(BrowserPageGeometry.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func captureVisualEvidence(_ command: BrowserCommand, in tab: Tab, control: BrowserControlLease?) async throws
        -> (result: BrowserResult, evidence: VisualFallbackEvidence) {
        let deadline = readerDeadline(command)
        let native = ImpeccableViewportObserver(scrollView: tab.webView.scrollView) { _ in }
        let before = try await pageGeometry(tab, deadline: deadline)
        try assertModelControlCurrent(control)
        let artifact = try await saveSnapshot(of: tab, deadline: deadline, control: control)
        var committed = false
        defer { if !committed { discardArtifact(artifact) } }
        try assertModelControlCurrent(control)
        let regions = try recognizeVisualText(in: artifact)
        var result = await observeResult(command, tabID: tab.id, cursor: nil)
        let after = try await pageGeometry(tab, deadline: deadline)
        try assertModelControlCurrent(control)
        guard before == after, !native.recheckNow(), let page = result.page, result.status == .ok,
              let index = tabs.firstIndex(where: { $0.id == tab.id }), tabs[index].webView === tab.webView,
              tabs[index].documentGeneration == tab.documentGeneration, tabs[index].routeGeneration == tab.routeGeneration,
              page.documentID == tab.documentID, page.revision == before.revision else {
            throw BrowserInteractionError.stale("The page moved or changed during the screenshot. Capture it again.")
        }
        let evidence = VisualFallbackEvidence(
            documentID: page.documentID, sha256: artifact.sha256.lowercased(), capturedAt: Date(),
            pixelWidth: artifact.pixelWidth, pixelHeight: artifact.pixelHeight,
            viewportWidth: page.viewportWidth, viewportHeight: page.viewportHeight, revision: page.revision,
            visualTextRegions: regions, geometry: after, routeGeneration: tab.routeGeneration,
            documentGeneration: tab.documentGeneration, nativeViewport: native)
        tabs[index].visualFallbackEvidence = evidence
        result.page?.screenshotArtifact = artifact
        result.page?.visualTextRegions = regions
        committed = true
        return (result, evidence)
    }

    private func unconfirmedClick(_ command: BrowserCommand, control: BrowserControlLease?) -> BrowserResult {
        if let denied = pageAccessFailure(command, control: control) { return denied }
        return failure(command, status: .failed, code: "dispatched-unconfirmed",
                       "The click was dispatched, but its result could not be verified. Re-observe before deciding what to do; do not repeat the click automatically.")
    }

    private func navigateAndObserve(_ command: BrowserCommand, tab: Tab, url: URL,
                                    control: BrowserControlLease?) async -> BrowserResult {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(min(30_000, max(250, command.timeoutMilliseconds))))
        let epoch = controlEpochCounter
        guard !Task.isCancelled else { return failure(command, status: .failed, code: "cancelled", "Navigation was cancelled.") }
        if var destination = URLComponents(url: url, resolvingAgainstBaseURL: true), destination.fragment != nil,
           let currentURL = tab.webView.url, var current = URLComponents(url: currentURL, resolvingAgainstBaseURL: true) {
            destination.fragment = nil
            current.fragment = nil
            if current.url == destination.url {
                // A fragment jump can bypass every public WKNavigationDelegate completion.
                // Never start an unidentifiable native load or claim a new document.
                return failure(command, status: .blocked, code: "same-document",
                               "Use a link on the current page to go to this fragment.")
            }
        }
        noteRestoreSettled(tabID: tab.id)
        guard let navigation = tab.webView.load(URLRequest(url: url)) else {
            return failure(command, status: .failed, code: "navigation", "WebKit did not start the navigation.")
        }
        let receipt = BrowserNavigationReceipt(page: tab.webView, navigation: navigation)
        navigationReceipt = receipt
        defer { if navigationReceipt === receipt, !receipt.awaitingStop { navigationReceipt = nil } }
        await receipt.wait(until: deadline)
        var retriedRouteObservation = false
        while true {
            if let denied = pageAccessFailure(command, control: control) { return denied }
            guard !Task.isCancelled else { return failure(command, status: .failed, code: "cancelled", "Navigation was cancelled after dispatch.") }
            guard epoch == controlEpochCounter else { return failure(command, status: .stale, code: "control", "Browser control changed.") }
            switch receipt.state {
            case .committed(let document, let generation, let finalURL):
                guard let current = tabs.first(where: { $0.id == tab.id }), current.webView === tab.webView,
                      current.documentID == document, current.documentGeneration == generation, current.webView.url == finalURL else {
                    return failure(command, status: .stale, code: "document", "The navigation was replaced before observation.")
                }
                let result = await observeResult(command, tabID: tab.id, cursor: nil, until: deadline)
                if let denied = pageAccessFailure(command, control: control) { return denied }
                guard !Task.isCancelled else { return failure(command, status: .failed, code: "cancelled", "Navigation observation was cancelled.") }
                guard case .committed = receipt.state, epoch == controlEpochCounter,
                      let after = tabs.first(where: { $0.id == tab.id }), after.documentID == document,
                      after.documentGeneration == generation, after.webView.url == finalURL else {
                    return failure(command, status: .stale, code: "document", "The navigation was replaced during observation.")
                }
                // URL KVO may report this commit on the next actor turn. Only repeat the read
                // after one matching route notification for this same native navigation and document.
                if result.status == .stale, result.error?.code == "document", !retriedRouteObservation,
                   after.routeGeneration == current.routeGeneration &+ 1, ContinuousClock.now < deadline {
                    retriedRouteObservation = true
                    continue
                }
                return result
            case .failed(let detail):
                return failure(command, status: .failed, code: "navigation", detail)
            case .replaced:
                return failure(command, status: .stale, code: "document", "The requested navigation was replaced.")
            case .cancelled:
                return failure(command, status: .failed, code: "cancelled", "The navigation was stopped after dispatch.")
            case .waiting, .timedOut:
                return failure(command, status: .timeout, code: "timeout", "The navigation was dispatched but WebKit did not confirm a document in time.")
            }
        }
    }

    private func observeResult(_ command: BrowserCommand, tabID: UUID?, cursor: Int?,
                               until limit: ContinuousClock.Instant? = nil) async -> BrowserResult {
        guard let tabID, let tab = tabs.first(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        let deadline = limit ?? ContinuousClock.now.advanced(by: .milliseconds(min(30_000, max(250, command.timeoutMilliseconds))))
        let trace = command.requestID.uuidString
        let epoch = controlEpochCounter
        let owner = modelControl
        func accessFailure() -> BrowserResult? {
            if let denied = pageAccessFailure(command, control: owner) { return denied }
            guard controlEpochCounter == epoch else {
                return failure(command, status: .stale, code: "control", "Browser control changed during observation.")
            }
            guard let current = tabs.first(where: { $0.id == tabID }), current.webView === tab.webView,
                  current.documentGeneration == tab.documentGeneration, current.routeGeneration == tab.routeGeneration else {
                return failure(command, status: .stale, code: "document", "The page changed during observation.")
            }
            return nil
        }
        do {
            try Task.checkCancellation()
            if let denied = accessFailure() { return denied }
            FloeLogger(category: .tools).info("Browser observe request=\(trace) phase=drainEvents.begin")
            await collectProbeEvents(tabID: tabID, deadline: deadline)
            try Task.checkCancellation()
            if let denied = accessFailure() { return denied }
            FloeLogger(category: .tools).info("Browser observe request=\(trace) phase=drainEvents.end")
            FloeLogger(category: .tools).info("Browser observe request=\(trace) phase=snapshot.begin")
            let start = max(0, cursor ?? 0)
            let pageSize = 40
            let probe = try await semanticSnapshot(
                in: tab.webView,
                documentID: tab.documentID,
                cursor: start,
                limit: pageSize,
                deadline: deadline
            )
            try Task.checkCancellation()
            if let denied = accessFailure() { return denied }
            FloeLogger(category: .tools).info("Browser observe request=\(trace) phase=snapshot.end")
            guard let index = tabs.firstIndex(where: { $0.id == tabID }),
                  tabs[index].documentGeneration == tab.documentGeneration, tabs[index].routeGeneration == tab.routeGeneration else {
                return failure(command, status: .stale, code: "document", "The page changed during observation.")
            }
            tabs[index].revision = max(tabs[index].revision, probe.revision)
            let snapshot = PageSnapshot(
                documentID: tab.documentID,
                revision: max(tab.revision, probe.revision),
                url: tab.webView.url?.absoluteString ?? "",
                title: tab.webView.title ?? "",
                isLoading: tab.webView.isLoading,
                viewportWidth: probe.viewportWidth,
                viewportHeight: probe.viewportHeight,
                scrollX: Double(tab.webView.scrollView.contentOffset.x),
                scrollY: Double(tab.webView.scrollView.contentOffset.y),
                tabs: tabSnapshots(),
                nodes: probe.nodes,
                nextCursor: probe.nextCursor,
                screenshotArtifact: nil
            )
            return BrowserResult(requestID: command.requestID, status: .ok, page: snapshot)
        } catch BrowserProbeError.timedOut {
            FloeLogger(category: .tools).info("Browser observe request=\(trace) outcome=timeout")
            return failure(command, status: .timeout, code: "timeout", "Browser page observation timed out")
        } catch BrowserProbeError.released {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        } catch is CancellationError {
            return failure(command, status: .failed, code: "cancelled", "Browser page observation was cancelled")
        } catch {
            let native = error as NSError
            FloeLogger(category: .tools).info("Browser observe request=\(trace) errorDomain=\(native.domain) code=\(native.code)")
            return failure(command, status: .failed, code: "observe", error.localizedDescription)
        }
    }

    private func probeValue(
        _ script: String,
        arguments: [String: Any],
        in webView: WKWebView,
        world: WKContentWorld? = nil,
        deadline: ContinuousClock.Instant
    ) async throws -> Any? {
        guard !isReleased else { throw BrowserProbeError.released }
        let id = UUID()
        let request = BrowserProbeRequest()
        pendingProbes[id] = request
        defer { pendingProbes.removeValue(forKey: id) }
        let data = try await request.run(deadline: deadline) { completion in
            webView.callAsyncJavaScript(
                script, arguments: arguments, in: nil, in: world ?? self.contentWorld,
                completionHandler: completion
            )
        }
        return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
    }

    private func semanticSnapshot(
        in webView: WKWebView,
        documentID: String,
        cursor: Int,
        limit: Int,
        deadline: ContinuousClock.Instant
    ) async throws -> ProbeSnapshot {
        let script = """
        const protocol = globalThis.__floeProtocol;
        if (!protocol) return {
          revision:0,
          viewportWidth:Math.max(1, Number(window.innerWidth) || 1),
          viewportHeight:Math.max(1, Number(window.innerHeight) || 1),
          nodes:[],
          nextCursor:null
        };
        return protocol.snapshot(documentID, cursor, limit);
        """
        let value = try await probeValue(
            script,
            arguments: ["documentID": documentID, "cursor": cursor, "limit": limit],
            in: webView,
            deadline: deadline
        )
        guard JSONSerialization.isValidJSONObject(value as Any) else {
            return ProbeSnapshot(
                revision: 0,
                viewportWidth: max(1, webView.bounds.width),
                viewportHeight: max(1, webView.bounds.height),
                nodes: [],
                nextCursor: nil
            )
        }
        let data = try JSONSerialization.data(withJSONObject: value as Any)
        return try JSONDecoder().decode(ProbeSnapshot.self, from: data)
    }

    private func readerDeadline(_ command: BrowserCommand) -> ContinuousClock.Instant {
        ContinuousClock.now.advanced(
            by: .milliseconds(min(30_000, max(250, command.timeoutMilliseconds)))
        )
    }

    private func linksResult(
        _ command: BrowserCommand,
        tabID: UUID,
        cursor: Int?,
        limit: Int
    ) async -> BrowserResult {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        do {
            let value = try await probeValue(
                """
                if (!globalThis.__floeProtocol) return {revision:0, links:[], nextCursor:null};
                return globalThis.__floeProtocol.links(documentID, cursor, limit);
                """,
                arguments: [
                    "documentID": tab.documentID,
                    "cursor": max(0, cursor ?? 0),
                    "limit": min(100, max(1, limit))
                ],
                in: tab.webView,
                deadline: readerDeadline(command)
            )
            guard let dictionary = value as? [String: Any],
                  JSONSerialization.isValidJSONObject(dictionary) else {
                throw BrowserPolicyError.blocked("The page returned an invalid link list")
            }
            let data = try JSONSerialization.data(withJSONObject: dictionary)
            let decoded = try JSONDecoder().decode(LinkProbeResponse.self, from: data)
            var result = BrowserResult(
                requestID: command.requestID,
                status: .ok,
                protocolVersion: protocolVersion
            )
            result.links = decoded.links
            result.message = "links=\(decoded.links.count) nextCursor=\(decoded.nextCursor.map(String.init) ?? "none")"
            return result
        } catch BrowserProbeError.timedOut {
            return failure(command, status: .timeout, code: "timeout", "Link observation timed out")
        } catch BrowserProbeError.released {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        } catch is CancellationError {
            return failure(command, status: .failed, code: "cancelled", "Link observation was cancelled")
        } catch {
            return failure(command, status: .failed, code: "observe", error.localizedDescription)
        }
    }

    private func tableResult(
        _ command: BrowserCommand,
        tabID: UUID,
        index: Int,
        cursor: Int?,
        limit: Int
    ) async -> BrowserResult {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        do {
            let value = try await probeValue(
                """
                if (!globalThis.__floeProtocol) return {
                  revision:0, tableIndex:0, tableCount:0, caption:'', headers:[], rows:[], totalRows:0, nextCursor:null
                };
                return globalThis.__floeProtocol.table(documentID, tableIndex, cursor, limit);
                """,
                arguments: [
                    "documentID": tab.documentID,
                    "tableIndex": max(0, min(49, index)),
                    "cursor": max(0, cursor ?? 0),
                    "limit": min(100, max(1, limit))
                ],
                in: tab.webView,
                deadline: readerDeadline(command)
            )
            guard let dictionary = value as? [String: Any],
                  JSONSerialization.isValidJSONObject(dictionary) else {
                throw BrowserPolicyError.blocked("The page returned an invalid table")
            }
            let data = try JSONSerialization.data(withJSONObject: dictionary)
            let decoded = try JSONDecoder().decode(TableProbeResponse.self, from: data)
            var result = BrowserResult(
                requestID: command.requestID,
                status: .ok,
                protocolVersion: protocolVersion
            )
            result.table = BrowserTablePage(
                tableIndex: decoded.tableIndex,
                tableCount: decoded.tableCount,
                caption: decoded.caption,
                headers: decoded.headers,
                rows: decoded.rows,
                totalRows: decoded.totalRows,
                nextCursor: decoded.nextCursor
            )
            result.message = "table=\(decoded.tableIndex + 1)/\(decoded.tableCount) rows=\(decoded.rows.count) nextCursor=\(decoded.nextCursor.map(String.init) ?? "none")"
            return result
        } catch BrowserProbeError.timedOut {
            return failure(command, status: .timeout, code: "timeout", "Table observation timed out")
        } catch BrowserProbeError.released {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        } catch is CancellationError {
            return failure(command, status: .failed, code: "cancelled", "Table observation was cancelled")
        } catch {
            return failure(command, status: .failed, code: "observe", error.localizedDescription)
        }
    }

    private func textResult(
        _ command: BrowserCommand,
        tabID: UUID,
        start: Int,
        maxCharacters: Int
    ) async -> BrowserResult {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        do {
            let value = try await probeValue(
                """
                if (!globalThis.__floeProtocol) return {revision:0, start:0, text:'', totalCharacters:0, nextStart:null};
                return globalThis.__floeProtocol.textRange(documentID, start, maxCharacters);
                """,
                arguments: [
                    "documentID": tab.documentID,
                    "start": max(0, start),
                    "maxCharacters": min(65_536, max(1_000, maxCharacters))
                ],
                in: tab.webView,
                deadline: readerDeadline(command)
            )
            guard let dictionary = value as? [String: Any],
                  JSONSerialization.isValidJSONObject(dictionary) else {
                throw BrowserPolicyError.blocked("The page returned an invalid text range")
            }
            let data = try JSONSerialization.data(withJSONObject: dictionary)
            let decoded = try JSONDecoder().decode(TextProbeResponse.self, from: data)
            var result = BrowserResult(
                requestID: command.requestID,
                status: .ok,
                protocolVersion: protocolVersion
            )
            result.textPage = BrowserTextPage(
                start: decoded.start,
                text: decoded.text,
                totalCharacters: decoded.totalCharacters,
                nextStart: decoded.nextStart
            )
            result.message = "characters=\(decoded.text.count) total=\(decoded.totalCharacters) nextStart=\(decoded.nextStart.map(String.init) ?? "none")"
            return result
        } catch BrowserProbeError.timedOut {
            return failure(command, status: .timeout, code: "timeout", "Text range observation timed out")
        } catch BrowserProbeError.released {
            return failure(command, status: .stale, code: "released", "This task's browser session was released")
        } catch is CancellationError {
            return failure(command, status: .failed, code: "cancelled", "Text range observation was cancelled")
        } catch {
            return failure(command, status: .failed, code: "observe", error.localizedDescription)
        }
    }

    private func eventsResult(
        _ command: BrowserCommand,
        tabID: UUID,
        afterSequence: Int?,
        limit: Int
    ) async -> BrowserResult {
        await collectProbeEvents(tabID: tabID)
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
        }
        let floor = max(0, afterSequence ?? 0)
        let available = tab.events.filter { $0.sequence > floor }
        let boundedLimit = min(100, max(1, limit))
        let selected = Array(available.prefix(boundedLimit))
        return BrowserResult(
            requestID: command.requestID,
            status: .ok,
            events: selected,
            nextEventSequence: selected.last?.sequence ?? afterSequence,
            protocolVersion: protocolVersion
        )
    }

    private func waitResult(
        _ command: BrowserCommand,
        tabID: UUID,
        condition: BrowserWaitCondition
    ) async -> BrowserResult {
        let timeout = min(30_000, max(250, command.timeoutMilliseconds))
        let deadline = Date().addingTimeInterval(Double(timeout) / 1_000)
        repeat {
            guard !isReleased else {
                return failure(command, status: .stale, code: "released", "This task's browser session was released")
            }
            if isUserControlling || takeoverPending {
                return failure(command, status: .needsUser, code: "takeover", "The user currently controls the browser")
            }
            guard let tab = tabs.first(where: { $0.id == tabID }) else {
                return failure(command, status: .stale, code: "tab", "Browser tab is no longer available")
            }
            await collectProbeEvents(tabID: tabID)
            if case .documentChanged(let oldDocumentID) = condition,
               tab.documentID != oldDocumentID {
                appendEvent(tabID: tabID, method: "Runtime.waitConditionSatisfied")
                return await observeResult(command, tabID: tabID, cursor: nil)
            }
            do {
                let state = try await probeState(
                    in: tab.webView,
                    documentID: tab.documentID,
                    condition: condition
                )
                let satisfied: Bool
                switch condition {
                case .load:
                    // `readyState` is the page-world lifecycle signal that
                    // corresponds to CDP's load event. WKWebView.isLoading
                    // may lag for loadHTMLString and late subresources.
                    satisfied = state.readyState == "complete"
                case .domContentLoaded:
                    satisfied = state.readyState == "interactive" || state.readyState == "complete"
                case .selector:
                    satisfied = state.selectorFound
                case .text:
                    satisfied = state.textFound
                case .documentChanged:
                    satisfied = false
                case .idle(let milliseconds):
                    satisfied = !tab.webView.isLoading
                        && state.idleMilliseconds >= Double(min(5_000, max(100, milliseconds)))
                }
                if satisfied {
                    appendEvent(tabID: tabID, method: "Runtime.waitConditionSatisfied")
                    return await observeResult(command, tabID: tabID, cursor: nil)
                }
            } catch {
                // Document-start script injection and the isolated content
                // world can briefly race navigation commit. Treat that as a
                // not-yet-satisfied wait and retry until the bounded deadline.
                if Date() >= deadline {
                    return failure(command, status: .failed, code: "probe", error.localizedDescription)
                }
            }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline && !Task.isCancelled
        if Task.isCancelled {
            return failure(command, status: .failed, code: "cancelled", "Browser wait was cancelled")
        }
        return failure(command, status: .timeout, code: "timeout", "Browser wait condition timed out")
    }

    private func probeState(
        in webView: WKWebView,
        documentID: String,
        condition: BrowserWaitCondition
    ) async throws -> ProbeState {
        var selector = ""
        var text = ""
        switch condition {
        case .selector(let value): selector = String(value.prefix(512))
        case .text(let value): text = String(value.prefix(512))
        default: break
        }
        let value = try await webView.callAsyncJavaScript(
            """
            const protocol = globalThis.__floeProtocol;
            if (!protocol) return {readyState:'loading', selectorFound:false, textFound:false, idleMilliseconds:0, revision:0};
            return protocol.status(documentID, selector, text);
            """,
            arguments: ["documentID": documentID, "selector": selector, "text": text],
            in: nil,
            contentWorld: contentWorld
        )
        guard JSONSerialization.isValidJSONObject(value as Any) else {
            throw BrowserPolicyError.blocked("The browser probe returned an invalid status")
        }
        let data = try JSONSerialization.data(withJSONObject: value as Any)
        return try JSONDecoder().decode(ProbeState.self, from: data)
    }

    private func collectProbeEvents(tabID: UUID, deadline: ContinuousClock.Instant? = nil) async {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        let epoch = controlEpochCounter
        guard !isUserControlling, !takeoverPending, !isReleased, !Task.isCancelled else { return }
        do {
            let value = try await probeValue(
                "return globalThis.__floeProtocol ? globalThis.__floeProtocol.drainEvents(documentID) : [];",
                arguments: ["documentID": tab.documentID],
                in: tab.webView,
                deadline: deadline ?? ContinuousClock.now.advanced(by: .seconds(15))
            )
            guard !isReleased, !isUserControlling, !takeoverPending, !Task.isCancelled, epoch == controlEpochCounter,
                  let current = tabs.first(where: { $0.id == tabID }), current.webView === tab.webView,
                  current.documentID == tab.documentID, current.documentGeneration == tab.documentGeneration,
                  current.routeGeneration == tab.routeGeneration, JSONSerialization.isValidJSONObject(value as Any) else { return }
            let data = try JSONSerialization.data(withJSONObject: value as Any)
            let events = try JSONDecoder().decode([ProbeEvent].self, from: data)
            for event in events {
                appendEvent(
                    tabID: tabID,
                    method: event.method,
                    detail: event.detail,
                    revision: event.revision
                )
            }
        } catch {
            let native = error as NSError
            FloeLogger(category: .tools).info("Browser probe phase=drainEvents.error errorDomain=\(native.domain) code=\(native.code)")
            // A navigation may replace the JS world between lookup and call.
            // Native lifecycle events still describe that transition.
        }
    }

    /// Internal for the task-owned staged-export service receipts only
    /// (`Browser.exportDelivered` / `Browser.exportRejected` on the existing
    /// events surface); every other caller stays inside this session.
    func appendEvent(
        tabID: UUID,
        method: String,
        detail: String? = nil,
        revision: Int? = nil
    ) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let sequence = tabs[index].nextEventSequence
        tabs[index].nextEventSequence += 1
        tabs[index].events.append(BrowserProtocolEvent(
            sequence: sequence,
            timestamp: Date(),
            tabID: tabID,
            documentID: tabs[index].documentID,
            method: method,
            detail: detail.map { String($0.prefix(512)) },
            revision: revision
        ))
        if tabs[index].events.count > maximumEventsPerTab {
            tabs[index].events.removeFirst(tabs[index].events.count - maximumEventsPerTab)
        }
        if let revision {
            tabs[index].revision = max(tabs[index].revision, revision)
        }
    }

    /// Runs in a named isolated content world at document start. It maintains
    /// stable per-document node references and a small lifecycle/DOM queue,
    /// but deliberately exposes no arbitrary JavaScript evaluation endpoint.
    private static let protocolProbeSource = #"""
    (() => {
      if (globalThis.__floeProtocol) return;
      let documentID = '';
      let revision = 0;
      let pageIdentity = globalThis.crypto?.randomUUID?.() || (performance.timeOrigin + '-' + Math.random());
      let viewportEpoch = 0;
      const geometry = () => {
        const v = window.visualViewport;
        if (!v) return null;
        return {page:pageIdentity, epoch:viewportEpoch, revision, layoutWidth:innerWidth, layoutHeight:innerHeight,
          width:v.width, height:v.height, left:v.offsetLeft, top:v.offsetTop, scale:v.scale,
          pageLeft:v.pageLeft, pageTop:v.pageTop, scrollX, scrollY};
      };
      const viewportChanged = () => { ++viewportEpoch; invalidatePreview(); };
      let nextRef = 1;
      let lastMutation = performance.now();
      const references = new WeakMap();
      const observedMeaning = new WeakMap();
      const nodesByRef = new Map();
      const events = [];
      const selector = 'a,button,input,textarea,select,[role],[contenteditable="true"],[onclick],summary,label,h1,h2,h3,p';

      const push = (method, detail = null) => {
        events.push({method, detail, revision});
        if (events.length > 128) events.splice(0, events.length - 128);
      };
      const setDocument = id => {
        if (id && documentID !== id) documentID = id;
      };
      const roots = () => {
        const result = [document];
        const visit = root => {
          let all = [];
          try { all = Array.from(root.querySelectorAll('*')); } catch (_) {}
          for (const el of all) {
            if (el.shadowRoot) { result.push(el.shadowRoot); visit(el.shadowRoot); }
            if ((el.tagName || '').toLowerCase() === 'iframe') {
              try { if (el.contentDocument) { result.push(el.contentDocument); visit(el.contentDocument); } } catch (_) {}
            }
          }
        };
        visit(document);
        return result;
      };
      const visible = el => {
        try {
          const rect = el.getBoundingClientRect();
          const style = getComputedStyle(el);
          return rect.width > 0 && rect.height > 0 && style.visibility !== 'hidden' && style.display !== 'none';
        } catch (_) { return false; }
      };
      const elementMeaning = el => JSON.stringify([el.tagName, el.type || '', el.getAttribute('role'),
        el.getAttribute('aria-label'), el.getAttribute('name'), el.title || '',
        ['A','BUTTON'].includes(el.tagName) ? el.textContent.trim().slice(0,200) : '']);
      const ensureRef = el => {
        let ref = references.get(el);
        const meaning = elementMeaning(el);
        if (ref && observedMeaning.get(el) !== meaning) { nodesByRef.delete(ref); ref = null; }
        if (!ref) {
          if (nodesByRef.size >= 2048) {
            for (const [key, node] of nodesByRef) if (!node?.isConnected) nodesByRef.delete(key);
            while (nodesByRef.size >= 2048) nodesByRef.delete(nodesByRef.keys().next().value);
          }
          ref = `n${nextRef++}`;
          references.set(el, ref);
          observedMeaning.set(el, meaning);
          nodesByRef.set(ref, el);
        }
        return ref;
      };
      const findByRef = ref => {
        const found = nodesByRef.get(ref);
        return found?.isConnected && observedMeaning.get(found) === elementMeaning(found) ? found : null;
      };
      const allNodes = () => {
        const seen = new Set();
        const output = [];
        for (const root of roots()) {
          let candidates = [];
          try { candidates = Array.from(root.querySelectorAll(selector)); } catch (_) {}
          for (const el of candidates) {
            if (seen.has(el) || !visible(el)) continue;
            seen.add(el);
            output.push(el);
            if (output.length >= 400) return output;
          }
        }
        return output;
      };
      const serialize = el => {
        const rect = el.getBoundingClientRect();
        const type = (el.type || '').toLowerCase();
        const role = el.getAttribute('role') || (el.tagName || '').toLowerCase();
        const password = type === 'password' || (el.autocomplete || '').toLowerCase() === 'current-password';
        return {
          ref: ensureRef(el), role,
          name: String(el.getAttribute('aria-label') || el.title || '').slice(0, 300),
          text: password ? '' : String(el.innerText || el.textContent || '').trim().slice(0, 500),
          value: password ? null : (el.value == null ? null : String(el.value).slice(0, 500)),
          state: {disabled: !!el.disabled, checked: !!el.checked, selected: !!el.selected},
          bounds: {x:rect.x, y:rect.y, width:rect.width, height:rect.height}
        };
      };
      const snapshot = (id, cursor, limit) => {
        setDocument(id);
        const nodes = allNodes();
        const start = Math.max(0, Number(cursor) || 0);
        const count = Math.min(50, Math.max(1, Number(limit) || 40));
        const end = Math.min(nodes.length, start + count);
        return {
          revision,
          viewportWidth: Math.max(1, Number(window.innerWidth) || 1),
          viewportHeight: Math.max(1, Number(window.innerHeight) || 1),
          nodes: nodes.slice(start, end).map(serialize),
          nextCursor: end < nodes.length ? end : null
        };
      };
      let lastDispatch = null;
      let watchedPreview = '';
      const invalidatePreview = () => {
        if (!watchedPreview) return;
        const action = watchedPreview;
        watchedPreview = '';
        window.webkit?.messageHandlers?.floePreviewChanged?.postMessage(action);
      };
      // Article text stays in the user's local WebKit image. Form values never leave the page.
      // Only a short known control label may also appear in the separate status string.
      const publicControl = /^(?:[0-9]{1,3}(?:\\.[0-9])?°|[0-9]{1,3}%|[+−–-]|next|previous|back|forward|go control|zoom in|zoom out|play|pause|stop|reset|rotate|expand|collapse|preview|下一页|上一页|前进|后退|放大|缩小|播放|暂停|停止|重置|旋转|展开|收起|预览)$/i;
      const opaque = 'iframe,frame,object,embed,canvas,video,portal,fencedframe,[shadowrootmode],template[shadowrootmode]';
      const personal = 'input[type="password"],input[type="email"],input[type="tel"],input[type="file"],[autocomplete*="password" i],[autocomplete*="one-time-code" i],[autocomplete*="cc-" i],[autocomplete*="address" i],[autocomplete*="email" i],[autocomplete*="name" i],[id*="captcha" i],[class*="captcha" i],[aria-label*="captcha" i],[name*="otp" i],[id*="otp" i],[contenteditable]:not([contenteditable="false"]),[role="textbox"]:not(input):not(textarea)';
      const hasSensitiveSurface = () => {
        if (!document.body || document.designMode === 'on' ||
            document.querySelector(opaque + ',' + personal) ||
            /(?:login|sign.?in|auth|checkout|wallet|account|payment|password|verification|captcha|profile)/i.test(location.pathname)) return true;
        const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
        let count = 0;
        for (let el = document.body; el; el = walk.nextNode()) {
          if (++count > 6000 || el.shadowRoot || el.localName.includes('-') || el.hasAttribute('is')) return true;
          if (el instanceof HTMLInputElement) {
            const type = el.type;
            if (['button','submit','reset','hidden'].includes(type)) continue;
            if (['radio','checkbox'].includes(type) ? el.checked : el.value.length > 0) return true;
          }
          if ((el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement) && el.value.length > 0) return true;
        }
        return false;
      };
      const previewRegion = (id, expectedRevision, action, clickedRef) => {
        if (!action || documentID !== id || revision !== expectedRevision ||
            document.readyState !== 'complete' || hasSensitiveSurface()) return null;
        const vv = window.visualViewport;
        if (!vv || Math.abs(vv.width - innerWidth) > 1 || Math.abs(vv.offsetTop) > 1 || Math.abs(vv.offsetLeft) > 1) return null;
        let target = null, label = null;
        const el = clickedRef ? findByRef(clickedRef) : null;
        if (el && lastDispatch?.action === action && lastDispatch.el === el && el.ownerDocument === document &&
            !el.children.length && ['BUTTON','A'].includes(el.tagName)) {
          const b = el.getBoundingClientRect();
          if (b.width > 0 && b.height > 0 && b.left >= 0 && b.top >= 0 && b.right <= vv.width && b.bottom <= vv.height &&
              document.elementFromPoint(b.x+b.width/2,b.y+b.height/2) === el &&
              lastDispatch.box.every((v,i) => Math.abs(v-[b.x,b.y,b.width,b.height,scrollX,scrollY][i]) <= 0.5)) {
            const text = el.textContent.trim();
            if (text && text.length <= 48 && publicControl.test(text)) {
              label = text; target = {x:b.x,y:b.y,width:b.width,height:b.height};
            }
          }
        }
        watchedPreview = action;
        return {viewportWidth:innerWidth,viewportHeight:innerHeight,scrollX,scrollY,target,label};
      };
      const perform = (operation, target, expectedDocumentID, text, submit, visualFallbackReason, actionID, expectedGeometry) => {
        if (documentID !== expectedDocumentID) return {status:'stale'};
        if (target.kind === 'point') {
          const current = geometry();
          if (!current || !expectedGeometry || Object.keys(current).some(k => current[k] !== expectedGeometry[k]))
            return {status:'stale'};
        }
        if (target.kind === 'element' && target.documentID !== documentID) return {status:'stale'};
        const el = target.kind === 'element'
          ? findByRef(target.ref)
          : document.elementFromPoint(Number(target.x), Number(target.y));
        if (!el || !el.isConnected || !visible(el) || el.disabled) return {status:'stale'};
        if (operation === 'click') {
          if (target.kind === 'point' && visualFallbackReason === 'noStructuredTarget') {
            let structured = null;
            try { structured = el.closest(selector); } catch (_) {}
            const structuredTag = String((structured && structured.tagName) || '').toLowerCase();
            // A canvas can be observable as one structured DOM node while
            // containing many visual-only controls. browser.click on the
            // canvas ref cannot address those internal targets, so preserve
            // coordinate fallback for this exact boundary.
            if (structured && visible(structured) && structuredTag !== 'canvas') {
              return {status:'structured', ref:ensureRef(structured)};
            }
          }
          // A fresh screenshot point is already viewport-relative. Scrolling
          // its hit element before dispatch changes the coordinate and was
          // the main source of intermittent misses on long pages.
          if (target.kind === 'element') {
            el.scrollIntoView({block:'center', inline:'center'});
          }
          const rect = el.getBoundingClientRect();
          const x = target.kind === 'point' ? Number(target.x) : rect.x + rect.width / 2;
          const y = target.kind === 'point' ? Number(target.y) : rect.y + rect.height / 2;
          if (target.kind === 'element') {
            const root = el.getRootNode();
            const hit = root.elementFromPoint ? root.elementFromPoint(x,y) : el.ownerDocument.elementFromPoint(x,y);
            if (hit !== el && !el.contains(hit)) return {status:'stale'};
          }
          lastDispatch = actionID && target.kind === 'element' && document.elementFromPoint(x, y) === el
            ? {action:actionID, el, box:[rect.x,rect.y,rect.width,rect.height,scrollX,scrollY]} : null;
          for (const type of ['pointerover','pointerenter','pointerdown','pointerup']) {
            try { el.dispatchEvent(new PointerEvent(type, {bubbles:true, cancelable:true, clientX:x, clientY:y, pointerType:'mouse', isPrimary:true})); } catch (_) {}
          }
          if (target.kind === 'point') {
            // HTMLElement.click() manufactures a click at (0,0), which is
            // unusable for canvas hit-testing. Preserve the evidence-backed
            // viewport coordinates on the actual click event.
            el.dispatchEvent(new MouseEvent('click', {bubbles:true, cancelable:true, clientX:x, clientY:y, view:window}));
          } else {
            el.click();
          }
          return {status:'ok'};
        }
        const tag = (el.tagName || '').toLowerCase();
        const inputType = (el.type || '').toLowerCase();
        if (inputType === 'password' || (el.autocomplete || '').toLowerCase() === 'current-password') return {status:'needsUser'};
        if (el.readOnly || !(tag === 'input' || tag === 'textarea' || el.isContentEditable)) return {status:'blocked'};
        el.focus();
        if (el.isContentEditable) {
          el.textContent = text;
        } else {
          const prototype = tag === 'textarea' ? HTMLTextAreaElement.prototype : HTMLInputElement.prototype;
          const setter = Object.getOwnPropertyDescriptor(prototype, 'value')?.set;
          if (setter) setter.call(el, text); else el.value = text;
        }
        try { el.dispatchEvent(new InputEvent('beforeinput', {bubbles:true, inputType:'insertText', data:text})); } catch (_) {}
        el.dispatchEvent(new Event('input', {bubbles:true}));
        el.dispatchEvent(new Event('change', {bubbles:true}));
        if (submit) {
          el.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', code:'Enter', bubbles:true}));
          if (el.form?.requestSubmit) el.form.requestSubmit();
          el.dispatchEvent(new KeyboardEvent('keyup', {key:'Enter', code:'Enter', bubbles:true}));
        }
        return {status:'ok'};
      };
      const status = (id, query, expectedText) => {
        setDocument(id);
        let selectorFound = false;
        if (query) {
          for (const root of roots()) {
            try { if (root.querySelector(query)) { selectorFound = true; break; } } catch (_) {}
          }
        }
        const bodyText = expectedText ? String(document.body?.innerText || '') : '';
        return {
          readyState: document.readyState,
          selectorFound,
          textFound: !!expectedText && bodyText.includes(expectedText),
          idleMilliseconds: Math.max(0, performance.now() - lastMutation),
          revision
        };
      };
      const drainEvents = id => { setDocument(id); return events.splice(0, events.length); };
      const links = (id, cursor, limit) => {
        setDocument(id);
        const start = Math.max(0, Number(cursor) || 0);
        const count = Math.min(100, Math.max(1, Number(limit) || 50));
        const output = [];
        const seen = new Set();
        for (const root of roots()) {
          let candidates = [];
          try { candidates = Array.from(root.querySelectorAll('a[href]')); } catch (_) {}
          for (const el of candidates) {
            if (seen.has(el) || !visible(el)) continue;
            seen.add(el);
            let href = '';
            try { href = String(el.href || '').slice(0, 4096); } catch (_) {}
            if (!href) continue;
            const rect = el.getBoundingClientRect();
            output.push({
              ref: ensureRef(el),
              href,
              text: String(el.innerText || el.textContent || '').trim().slice(0, 500),
              title: String(el.getAttribute('title') || '').slice(0, 300),
              target: el.getAttribute('target') ? String(el.getAttribute('target')).slice(0, 64) : null,
              download: !!el.download,
              bounds: {x:rect.x, y:rect.y, width:rect.width, height:rect.height}
            });
            if (output.length >= 500) break;
          }
          if (output.length >= 500) break;
        }
        return {
          revision,
          links: output.slice(start, start + count),
          nextCursor: start + count < output.length ? start + count : null
        };
      };
      const table = (id, tableIndex, cursor, limit) => {
        setDocument(id);
        const tables = [];
        for (const root of roots()) {
          let candidates = [];
          try { candidates = Array.from(root.querySelectorAll('table')); } catch (_) {}
          for (const el of candidates) {
            if (!visible(el)) continue;
            tables.push(el);
            if (tables.length >= 50) break;
          }
          if (tables.length >= 50) break;
        }
        if (!tables.length) {
          return {revision, tableIndex:0, tableCount:0, caption:'', headers:[], rows:[], totalRows:0, nextCursor:null};
        }
        const index = Math.max(0, Math.min(tables.length - 1, Number(tableIndex) || 0));
        const element = tables[index];
        const rows = Array.from(element.rows || []);
        let headers = [];
        if (element.tHead) {
          for (const row of Array.from(element.tHead.rows)) {
            for (const cell of Array.from(row.cells)) {
              headers.push(String(cell.innerText || cell.textContent || '').trim().slice(0, 2000));
            }
          }
        } else if (rows.length) {
          headers = Array.from(rows[0].cells || []).map(cell => String(cell.innerText || cell.textContent || '').trim().slice(0, 2000));
        }
        const start = Math.max(0, Number(cursor) || 0);
        const count = Math.min(100, Math.max(1, Number(limit) || 50));
        const selected = rows.slice(start, start + count).map(row => {
          return Array.from(row.cells || []).slice(0, 50).map(cell => {
            return String(cell.innerText || cell.textContent || '').trim().slice(0, 2000);
          });
        });
        return {
          revision,
          tableIndex: index,
          tableCount: tables.length,
          caption: String(element.caption ? (element.caption.innerText || element.caption.textContent || '') : '').trim().slice(0, 500),
          headers: headers.slice(0, 50),
          rows: selected,
          totalRows: rows.length,
          nextCursor: start + count < rows.length ? start + count : null
        };
      };
      const textRange = (id, start, maxCharacters) => {
        setDocument(id);
        const source = String((document.body && (document.body.innerText || document.body.textContent)) || '');
        const offset = Math.max(0, Math.min(source.length, Number(start) || 0));
        const limit = Math.min(65536, Math.max(1000, Number(maxCharacters) || 16384));
        const slice = source.slice(offset, offset + limit);
        return {
          revision,
          start: offset,
          text: slice,
          totalCharacters: source.length,
          nextStart: offset + slice.length < source.length ? offset + slice.length : null
        };
      };

      new MutationObserver(records => {
        if (!records.length) return;
        invalidatePreview();
        revision += 1;
        lastMutation = performance.now();
        push('DOM.documentUpdated');
      }).observe(document, {subtree:true, childList:true, attributes:true, characterData:true});
      document.addEventListener('DOMContentLoaded', () => push('Page.domContentEventFired'), {once:true});
      addEventListener('load', () => push('Page.loadEventFired'), {once:true});
      addEventListener('hashchange', () => push('Page.navigatedWithinDocument'));
      addEventListener('popstate', () => push('Page.navigatedWithinDocument'));
      for (const name of ['scroll','resize']) {
        addEventListener(name, viewportChanged, {capture:true, passive:true});
        window.visualViewport?.addEventListener(name, viewportChanged, {passive:true});
      }
      for (const name of ['pagehide','hashchange','popstate','beforeinput','input','change','focusin']) {
        addEventListener(name, invalidatePreview, {capture:true, passive:true});
      }
      globalThis.__floeProtocol = {snapshot, perform, status, drainEvents, links, table, textRange, previewRegion, geometry};
      push('Runtime.executionContextCreated');
    })();
    """#

    /// Removes one of this session's own screenshot artifacts when a capture
    /// must not be retained (takeover/release while it was in flight).
    private func discardArtifact(_ artifact: BrowserArtifactReference) {
        let name = (artifact.relativePath as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { return }
        try? FileManager.default.removeItem(
            at: artifactDirectory.appendingPathComponent(name))
    }

    private func nativeSnapshot(of tab: Tab, configuration: WKSnapshotConfiguration, timeout: Duration) async -> UIImage? {
        guard pendingNativePreviews[tab.id] == nil, timeout > .zero else { return nil }
        let request = BrowserPreviewImageRequest()
        let generation = previewGeneration
        return await request.wait(timeout: timeout) { [self] in
            pendingNativePreviews[tab.id] = request
            previewSnapshot(tab.webView, configuration) { [weak self, weak request, tabID = tab.id] image in
                guard let self, let request, pendingNativePreviews[tabID] === request else { return }
                pendingNativePreviews.removeValue(forKey: tabID)
                request.finish(image)
                if previewGeneration != generation, activeTabID == tabID {
                    previewAttemptedGeneration = nil
                    scheduleLivePreview()
                }
            }
        }
    }

    private func saveSnapshot(of tab: Tab, deadline: ContinuousClock.Instant, control: BrowserControlLease?) async throws -> BrowserArtifactReference {
        let limit = min(deadline, ContinuousClock.now.advanced(by: previewSnapshotTimeout))
        while pendingNativePreviews[tab.id] != nil {
            try assertModelControlCurrent(control)
            guard ContinuousClock.now < limit else { throw BrowserProbeError.timedOut }
            try await Task.sleep(for: .milliseconds(30))
        }
        try assertModelControlCurrent(control)
        guard let image = await nativeSnapshot(of: tab, configuration: WKSnapshotConfiguration(), timeout: ContinuousClock.now.duration(to: limit)) else {
            try assertModelControlCurrent(control)
            throw BrowserProbeError.timedOut
        }
        try assertModelControlCurrent(control)
        guard let data = image.jpegData(compressionQuality: 0.78) else {
            throw BrowserPolicyError.blocked("The viewport could not be encoded")
        }
        guard data.count <= 8 * 1024 * 1024 else {
            throw BrowserPolicyError.blocked("The viewport snapshot exceeds 8 MiB")
        }
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
        let id = UUID()
        let name = "\(id.uuidString).jpg"
        try data.write(to: artifactDirectory.appendingPathComponent(name), options: .atomic)
        let digest = FloeDigest.sha256Hex(data)
        return BrowserArtifactReference(
            id: id,
            relativePath: "BrowserArtifacts/\(name)",
            mimeType: "image/jpeg",
            byteCount: data.count,
            sha256: digest,
            pixelWidth: image.cgImage?.width ?? Int(image.size.width * image.scale),
            pixelHeight: image.cgImage?.height ?? Int(image.size.height * image.scale)
        )
    }

    private func recognizeVisualText(in artifact: BrowserArtifactReference) throws -> [VisualTextRegion] {
        let filename = (artifact.relativePath as NSString).lastPathComponent
        return try VisualTextRecognizer.recognize(
            imageData: Data(contentsOf: artifactDirectory.appendingPathComponent(filename)),
            pixelWidth: artifact.pixelWidth,
            pixelHeight: artifact.pixelHeight
        )
    }

    private func tabSnapshots() -> [BrowserTabSnapshot] {
        tabs.map {
            BrowserTabSnapshot(
                id: $0.id,
                url: ($0.webView.url ?? $0.restorableURL)?.absoluteString ?? "",
                title: $0.webView.title ?? "",
                isActive: $0.id == activeTabID
            )
        }
    }

    private func failure(
        _ command: BrowserCommand,
        status: BrowserResult.Status,
        code: String,
        _ message: String
    ) -> BrowserResult {
        BrowserResult(
            requestID: command.requestID,
            status: status,
            message: message,
            error: BrowserFailure(code: code, message: message)
        )
    }
}

extension BrowserTaskSession: WKNavigationDelegate, WKUIDelegate {
    /// Consume callbacks from the old page during handoff. Only a link from the
    /// current human-controlled tab may leave the app, in this same actor turn.
    private func shouldConsumeLink(_ url: URL, from webView: WKWebView, canOpenExternally: Bool) -> Bool {
        if takeoverPending || returningToModel { return true }
        guard canOpenExternally, isUserControlling, linkOpenBehaviorProvider() == .systemBrowser else { return false }
        if activeWebView === webView { openSystemURL(url) }
        return true
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences
    ) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        let url = navigationAction.request.url
        let policy = navigationPolicy(for: url, type: navigationAction.navigationType, from: webView,
                                      canOpenExternally: Self.canOpenExternally(navigationAction.request))
        if navigationAction.targetFrame?.isMainFrame == true,
           let index = tabs.firstIndex(where: { $0.webView === webView }), policy == .allow, let url {
            let tab = tabs[index]
            let restoring = restoredTabIDsPending.contains(tab.id)
            let request = navigationAction.request
            let nonGETSubmission = (request.httpMethod ?? "GET").uppercased() != "GET"
                || request.httpBody != nil || request.httpBodyStream != nil
            // Automatic replays cannot redirect to a local endpoint or an
            // authentication callback. Explicit navigation uses the normal policy.
            if restoring, nonGETSubmission || !BrowserURLPolicy.isRestorablePageURL(url) {
                noteRestoreSettled(tabID: tab.id)
                return (.cancel, preferences)
            }
            if usesWideLayout(url) { preferences.preferredContentMode = .desktop }
            if !restoring || tab.id == activeTabID { lockViewport(tab, destination: url) }
            tabs[index].formSubmissionPending = nonGETSubmission
        }
        return (policy, preferences)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let index = tabs.firstIndex(where: { $0.webView === webView }) else { return }
        if let receipt = navigationReceipt, receipt.page === webView {
            settleNavigation(receipt, as: .failed("WebKit ended the page process."))
        }
        let id = tabs[index].id
        tabs[index].documentID = UUID().uuidString
        tabs[index].documentGeneration += 1
        tabs[index].visualFallbackEvidence = nil
        pendingNativePreviews.removeValue(forKey: id)?.finish(nil)
        if activeTabID == id { resetLivePreview() }
        impeccableCaptures.fence(tabID: id, reason: .navigation)
        stagedExports.fenceTab(id, reason: .navigation)
        noteRestoreSettled(tabID: id)
        host?.browserSessionRestorableStateDidChange(self)
    }

    func navigationPolicy(for destination: URL?, type: WKNavigationType, from webView: WKWebView,
                          canOpenExternally: Bool = true) -> WKNavigationActionPolicy {
        guard !isReleased, let url = destination else {
            return .cancel
        }
        // WebKit uses its own blank document while `loadHTMLString` commits.
        // It is not a tool-addressable URL and must remain available for
        // local fixtures/previews; all external navigations still pass the
        // normal http/https/private-network policy below.
        if url.absoluteString == "about:blank" {
            return type == .linkActivated && (takeoverPending || returningToModel) ? .cancel : .allow
        }
        // The owner is this session's trusted task, never the visible task.
        guard (try? BrowserURLPolicy.validate(url.absoluteString, conversationID: conversationID, allowLocalNetwork: true)) != nil else {
            return .cancel
        }
        // "Open in system browser" applies only while a human controls the
        // page, so an AI-driven click never gets rerouted into Safari.
        if type == .linkActivated, shouldConsumeLink(url, from: webView, canOpenExternally: canOpenExternally) {
            return .cancel
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard !isReleased, let tabID = tabs.first(where: { $0.webView === webView })?.id else { return }
        if let receipt = navigationReceipt, receipt.page === webView {
            if receipt.navigation === navigation {
                receipt.started = true
                receipt.stopIfStarted()
            } else if receipt.started { settleNavigation(receipt, as: .replaced) }
        }
        if tabID == activeTabID { resetLivePreview() }
        appendEvent(tabID: tabID, method: "Page.frameStartedLoading")
        surfaceState = .loading
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard !isReleased, let index = tabs.firstIndex(where: { $0.webView === webView }) else { return }
        if tabs[index].id == activeTabID { resetLivePreview() }
        tabs[index].documentID = UUID().uuidString
        tabs[index].documentGeneration += 1
        // The committed document becomes the durable restore candidate only
        // when the load was a plain GET to a public, credential-free page.
        tabs[index].restorableURL = Self.restorableCommitURL(
            loadURL: webView.url, formSubmission: tabs[index].formSubmissionPending
        )
        tabs[index].formSubmissionPending = false
        if let receipt = navigationReceipt, receipt.page === webView {
            if receipt.navigation === navigation {
                receipt.started = true
                settleNavigation(receipt, as: .committed(document: tabs[index].documentID, generation: tabs[index].documentGeneration, url: webView.url))
            } else if receipt.started { settleNavigation(receipt, as: .replaced) }
        }
        // Fence at the moment of the document change, before anything else
        // can answer against the replaced page.
        impeccableCaptures.fence(tabID: tabs[index].id, reason: .navigation)
        stagedExports.fenceTab(tabs[index].id, reason: .navigation)
        tabs[index].revision = 0
        tabs[index].visualFallbackEvidence = nil
        appendEvent(
            tabID: tabs[index].id,
            method: "Page.frameNavigated"
        )
        if tabs[index].id == activeTabID { syncChromeState() }
        noteRestoreSettled(tabID: tabs[index].id)
        host?.browserSessionRestorableStateDidChange(self)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !isReleased, let index = tabs.firstIndex(where: { $0.webView === webView }) else { return }
        // Some same-document navigations finish without replacing the native document.
        if let receipt = navigationReceipt, receipt.page === webView, receipt.navigation === navigation {
            receipt.started = true
            if receipt.awaitingStop {
                settleNavigation(receipt, as: .replaced)
            } else if case .waiting = receipt.state {
                settleNavigation(receipt, as: .committed(document: tabs[index].documentID, generation: tabs[index].documentGeneration, url: webView.url))
            }
        }
        appendEvent(tabID: tabs[index].id, method: "Page.loadEventFired")
        if tabs[index].id == activeTabID {
            refreshVisibleAddress()
            syncChromeState()
        }
        noteRestoreSettled(tabID: tabs[index].id)
        surfaceState = isUserControlling ? .needsUser("User takeover is active") : .ready
        // Title/back-forward availability are WebKit getters, not @Published
        // fields; notify the visible projection explicitly.
        objectWillChange.send()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard !isReleased, let tabID = tabs.first(where: { $0.webView === webView })?.id else { return }
        let stopped = recordNavigationFailure(navigation, in: webView, error: error)
        let nsError = error as NSError
        appendEvent(tabID: tabID, method: "Network.loadingFailed", detail: "\(nsError.domain):\(nsError.code)")
        noteRestoreSettled(tabID: tabID)
        if stopped { surfaceState = isUserControlling ? .needsUser("User takeover is active") : .ready }
        else { surfaceState = .failed("\(nsError.localizedDescription) (\(nsError.code))") }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: any Error
    ) {
        guard !isReleased, let tabID = tabs.first(where: { $0.webView === webView })?.id else { return }
        let stopped = recordNavigationFailure(navigation, in: webView, error: error)
        let nsError = error as NSError
        appendEvent(tabID: tabID, method: "Network.loadingFailed", detail: "\(nsError.domain):\(nsError.code)")
        noteRestoreSettled(tabID: tabID)
        if stopped { surfaceState = isUserControlling ? .needsUser("User takeover is active") : .ready }
        else { surfaceState = .failed("\(nsError.localizedDescription) (\(nsError.code))") }
    }

    private func recordNavigationFailure(_ navigation: WKNavigation?, in page: WKWebView, error: any Error) -> Bool {
        guard let receipt = navigationReceipt, receipt.page === page, receipt.navigation === navigation else { return false }
        if case .replaced = receipt.state { return false }
        let failure = error as NSError
        let stopped = receipt.awaitingStop
        if failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled { settleNavigation(receipt, as: .replaced) }
        else { settleNavigation(receipt, as: .failed(failure.localizedDescription)) }
        return stopped
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        openRequestedWindow(for: navigationAction.request, from: webView, configuration: configuration)
    }

    private static let browserNavigationHeaders: Set<String> = [
        "accept", "accept-encoding", "accept-language", "user-agent", "referer", "upgrade-insecure-requests",
        "priority", "dnt", "sec-gpc", "sec-fetch-dest", "sec-fetch-mode", "sec-fetch-site", "sec-fetch-user"
    ]

    private static func canOpenExternally(_ request: URLRequest) -> Bool {
        guard (request.httpMethod ?? "GET").uppercased() == "GET",
              request.httpBody == nil, request.httpBodyStream == nil else { return false }
        // Safari accepts only a URL. Standard browser metadata can be supplied by
        // that browser; an authorization, range or other request-specific header cannot.
        return request.allHTTPHeaderFields?.keys.allSatisfy { browserNavigationHeaders.contains($0.lowercased()) } ?? true
    }

    func openRequestedWindow(for request: URLRequest?, from webView: WKWebView,
                             configuration: WKWebViewConfiguration) -> WKWebView? {
        guard !isReleased, !takeoverPending, !returningToModel,
              let opener = tabs.first(where: { $0.webView === webView }) else { return nil }
        if let request, let url = request.url, url.absoluteString != "about:blank" {
            guard (try? BrowserURLPolicy.validate(url.absoluteString, conversationID: conversationID, allowLocalNetwork: true)) != nil,
                  !shouldConsumeLink(url, from: webView, canOpenExternally: Self.canOpenExternally(request)) else { return nil }
        }
        // A target=_blank / window.open request opens a real task tab. The
        // six-tab limit is honest: at capacity the popup is refused and the
        // user/model sees the limit notice instead of a fake success.
        let isHumanPopup = modelControl != nil && humanBrowsingTabID == opener.id
        guard let id = makeTab(for: (configuration, opener), selectForModel: !isHumanPopup),
              let created = tabs.first(where: { $0.id == id })?.webView else {
            if let activeTabID {
                appendEvent(tabID: activeTabID, method: "Target.targetLimitReached", detail: "maximumTabs")
            }
            return nil
        }
        // WebKit sends the original request (including any POST body) after this delegate returns.
        return created
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard !isReleased, let tab = tabs.first(where: { $0.webView === webView }), let opener = tab.openerID else { return }
        if takeoverPending || returningToModel {
            // The DOM window is already closed. Retire this tab after handoff without replaying the script.
            if !deferredWindowClosures.contains(tab.id) { deferredWindowClosures.append(tab.id) }
            return
        }
        close(tab.id, returningTo: opener)
    }
}

/// Registry of live task sessions. It never swaps one task's tabs into
/// another: entries are keyed by trusted conversation identity and released
/// only by their own task deletion or explicit release.
@MainActor
final class BrowserTaskSessionStore {
    private var sessions: [UUID: BrowserTaskSession] = [:]
    let maximumSessions: Int

    init(maximumSessions: Int) {
        self.maximumSessions = maximumSessions
    }

    var count: Int { sessions.count }

    func session(for conversationID: UUID) -> BrowserTaskSession? {
        sessions[conversationID]
    }

    func insert(_ session: BrowserTaskSession) throws {
        if let existing = sessions[session.conversationID] {
            guard existing === session else {
                throw FloeError.validationFailed("Another browser session already owns this task")
            }
            return
        }
        guard sessions.count < maximumSessions else {
            throw FloeError.validationFailed(
                "Too many task browsers are open; close a browser or delete a task you no longer use"
            )
        }
        sessions[session.conversationID] = session
    }

    @discardableResult
    func release(_ conversationID: UUID) -> BrowserTaskSession? {
        sessions.removeValue(forKey: conversationID)
    }

    /// Least-recently-used first, so a caller under capacity pressure can
    /// decide with explicit ownership guards. Never used to evict implicitly.
    func sessionsByLeastRecentActivity() -> [BrowserTaskSession] {
        sessions.values.sorted { $0.lastActivityAt < $1.lastActivityAt }
    }
}

private struct ProbeSnapshot: Decodable {
    var revision: Int
    var viewportWidth: Double
    var viewportHeight: Double
    var nodes: [BrowserNode]
    var nextCursor: Int?
}

private struct ProbeState: Decodable {
    var readyState: String
    var selectorFound: Bool
    var textFound: Bool
    var idleMilliseconds: Double
    var revision: Int
}

private struct ProbeEvent: Decodable {
    var method: String
    var detail: String?
    var revision: Int?
}

private struct LinkProbeResponse: Decodable {
    var revision: Int
    var links: [BrowserLink]
    var nextCursor: Int?
}

private struct TableProbeResponse: Decodable {
    var revision: Int
    var tableIndex: Int
    var tableCount: Int
    var caption: String
    var headers: [String]
    var rows: [[String]]
    var totalRows: Int
    var nextCursor: Int?
}

private struct TextProbeResponse: Decodable {
    var revision: Int
    var start: Int
    var text: String
    var totalCharacters: Int
    var nextStart: Int?
}

private enum BrowserInteractionError: Error {
    case needsUser(String)
    case stale(String)
    case uncertain(String)
}
#endif
