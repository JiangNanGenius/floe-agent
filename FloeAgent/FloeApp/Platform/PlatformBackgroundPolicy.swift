// FloeApp — Platform background policy abstraction (iOS-only).
// See blazing-aurora-darwin.md §10. Business code never touches
// BGTaskScheduler directly; everything routes through one of the two
// concrete policies (iPhone single-scene / iPad multi-scene).

#if canImport(UIKit)
import UIKit
import BackgroundTasks

/// Categories of scheduled background work.
public enum BackgroundTaskKind: String, Sendable, CaseIterable {
    /// BGAppRefreshTask — config sync fallback.
    case refresh = "org.floeagent.ios.refresh"
    /// BGProcessingTask — audit compaction.
    case processing = "org.floeagent.ios.processing"
    /// Media-only polling. Kept separate from config refresh and memory work.
    case mediaRefresh = "org.floeagent.ios.media-refresh"
    /// Media recovery/download preparation and urgent cloud release work.
    case mediaProcessing = "org.floeagent.ios.media-processing"
    /// BGContinuedProcessingTask (iOS 26+) — explicit foreground conversation
    /// runs with real progress suitable for a system Live Activity.
    case continued = "org.floeagent.ios.continued.*"

    /// Continued-processing registrations use a wildcard, while every
    /// foreground submission must carry a concrete unique suffix.
    var submissionIdentifier: String {
        guard self == .continued else { return rawValue }
        return rawValue.replacingOccurrences(of: "*", with: UUID().uuidString)
    }

    /// Concrete continued-processing requests share this app-owned prefix.
    /// Prefix matching is intentionally restricted to this namespace so
    /// cleanup never cancels refresh, media, or audit-processing requests.
    var submissionIdentifierPrefix: String {
        guard self == .continued else { return rawValue }
        return rawValue.replacingOccurrences(of: "*", with: "")
    }
}

/// Pure process-level bookkeeping for continued-processing submissions and
/// accepted system handles. The registry uses this state to coalesce the
/// repeated didStart/settings request paths into one outstanding
/// submission, while still retaining every legacy/racing accepted handle.
struct ContinuedProcessingLifecycle<HandleID: Hashable> {
    private(set) var submissionInFlight = false
    private(set) var pendingRequestIdentifiers: Set<String> = []
    private(set) var acceptedHandlesByIdentifier: [String: Set<HandleID>] = [:]

    var acceptedHandleCount: Int {
        acceptedHandlesByIdentifier.values.reduce(0) { $0 + $1.count }
    }

    var hasOutstandingWork: Bool {
        submissionInFlight
            || !pendingRequestIdentifiers.isEmpty
            || acceptedHandleCount > 0
    }

    var outstandingRequestIdentifiers: Set<String> {
        pendingRequestIdentifiers.union(acceptedHandlesByIdentifier.keys)
    }

    mutating func beginSubmission() -> Bool {
        guard !hasOutstandingWork else { return false }
        submissionInFlight = true
        return true
    }

    mutating func finishSubmission(identifier: String?) {
        submissionInFlight = false
        guard let identifier,
              acceptedHandlesByIdentifier[identifier]?.isEmpty != false else {
            return
        }
        pendingRequestIdentifiers.insert(identifier)
    }

    /// Returns false when the exact system object was already delivered.
    @discardableResult
    mutating func acceptHandle(identifier: String, handleID: HandleID) -> Bool {
        pendingRequestIdentifiers.remove(identifier)
        var handles = acceptedHandlesByIdentifier[identifier] ?? []
        let inserted = handles.insert(handleID).inserted
        acceptedHandlesByIdentifier[identifier] = handles
        return inserted
    }

    @discardableResult
    mutating func completeHandle(identifier: String, handleID: HandleID) -> Bool {
        guard var handles = acceptedHandlesByIdentifier[identifier],
              handles.remove(handleID) != nil else { return false }
        if handles.isEmpty {
            acceptedHandlesByIdentifier.removeValue(forKey: identifier)
        } else {
            acceptedHandlesByIdentifier[identifier] = handles
        }
        return true
    }

    mutating func completeAllAcceptedHandles() -> [String: Set<HandleID>] {
        let handles = acceptedHandlesByIdentifier
        acceptedHandlesByIdentifier.removeAll()
        return handles
    }

    mutating func cancelPendingRequests() -> Set<String> {
        submissionInFlight = false
        let identifiers = pendingRequestIdentifiers
        pendingRequestIdentifiers.removeAll()
        return identifiers
    }
}

/// Process-wide registration gate for `BGTaskScheduler`.
///
/// `submit(_:)` raises an Objective-C exception (and terminates the app) when
/// the request identifier has no matching launch handler. Continued tasks use
/// a concrete identifier per user-started run, so the exact identifier must be
/// registered before it is submitted; registering only the Info.plist wildcard
/// is not sufficient. Keeping this gate process-wide also prevents the second-
/// registration termination documented by BackgroundTasks.
@MainActor
enum BackgroundTaskRegistrar {
    private static var registeredIdentifiers: Set<String> = []

    static func register(
        identifier: String,
        launchHandler: @escaping (BGTask) -> Void
    ) -> Bool {
        if registeredIdentifiers.contains(identifier) { return true }
        let didRegister = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil,
            launchHandler: launchHandler
        )
        if didRegister {
            registeredIdentifiers.insert(identifier)
        }
        return didRegister
    }
}

/// All continued-processing requests use fail-fast delivery. Floe already
/// persists checkpoints and schedules ordinary BGProcessing recovery, so a
/// queued request would only surface a stale Live Activity in a later scene.
@available(iOS 26.0, *)
enum ContinuedProcessingRequestFactory {
    static func make(
        identifier: String,
        title: String,
        subtitle: String
    ) -> BGContinuedProcessingTaskRequest {
        let request = BGContinuedProcessingTaskRequest(
            identifier: identifier,
            title: title,
            subtitle: subtitle
        )
        request.strategy = .fail
        return request
    }
}

/// Time-boxed permission to finish work before suspension.
public struct BackgroundExecutionLease: Sendable {
    public var name: String
    public var expiresAt: Date
    /// Release the lease early (work finished).
    public var release: @MainActor @Sendable () -> Void

    public init(
        name: String,
        expiresAt: Date,
        release: @escaping @MainActor @Sendable () -> Void
    ) {
        self.name = name
        self.expiresAt = expiresAt
        self.release = release
    }
}

/// Long-lived connection categories governed by the policy.
public enum ConnectionKind: String, Sendable, CaseIterable {
    case ssh
    case vnc
    case providerStream
}

/// How a connection behaves across scene/app backgrounding.
public struct ConnectionPolicy: Sendable, Hashable {
    /// Suspend transport when the owning scene backgrounds.
    public var suspendOnSceneBackground: Bool
    /// Suspend transport only when the whole app backgrounds.
    public var suspendOnAppBackground: Bool
    /// Reconnect via helper output cursor on resume (helper-managed runs).
    public var resumeViaCursor: Bool

    public init(
        suspendOnSceneBackground: Bool,
        suspendOnAppBackground: Bool,
        resumeViaCursor: Bool
    ) {
        self.suspendOnSceneBackground = suspendOnSceneBackground
        self.suspendOnAppBackground = suspendOnAppBackground
        self.resumeViaCursor = resumeViaCursor
    }
}

/// Scene lifecycle phases mirrored from SwiftUI/UIKit.
public enum PolicyScenePhase: String, Sendable, Hashable {
    case active, inactive, background
}

/// Unified background-execution contract. Two implementations:
/// `iPhoneBackgroundPolicy` (single scene) and `iPadBackgroundPolicy`
/// (per-scene accounting). Never use audio/location/VoIP keep-alive.
@MainActor
public protocol PlatformBackgroundPolicy: Sendable {
    /// Registers BGTaskScheduler handlers for the three task kinds.
    func registerTasks()

    /// Schedules the next app-refresh wakeup.
    func scheduleRefresh(earliest: Date)

    func scheduleMediaRefresh(earliest: Date)

    func scheduleMediaProcessing(earliest: Date)

    /// Requests continued background processing for a foreground-initiated
    /// workload (iOS 26 BGContinuedProcessingTask with BGProcessingTask
    /// fallback).
    @discardableResult
    func requestContinuedProcessing(_ kind: BackgroundTaskKind) -> String?

    /// Cancels known queued requests and discovers stale queued requests from
    /// an earlier process using only the continued-processing namespace.
    func cancelContinuedProcessingRequests(
        _ identifiers: Set<String>,
        discoverUntrackedRequests: Bool
    )

    /// Begins a short (≤30s) completion window for legitimate pre-suspend
    /// wrap-up: last heartbeat, write-buffer flush, cursor save.
    func beginShortCompletion(name: String) -> BackgroundExecutionLease

    /// Feeds scene phase transitions. iPad implementations account per
    /// sceneID; iPhone implementations treat it as app-level.
    func handleScenePhase(_ phase: PolicyScenePhase, sceneID: String)

    /// Long-lived connection behavior for one connection kind.
    func longLivedConnectionPolicy(for kind: ConnectionKind) -> ConnectionPolicy
}

/// Shared registry bridging UIKit scene callbacks into the active policy.
@MainActor
public final class BackgroundPolicyRegistry {
    public static let shared = BackgroundPolicyRegistry()

    private var policy: (any PlatformBackgroundPolicy)?
    private var continuedTaskHandler: ((BGContinuedProcessingTask) -> Void)?
    private var refreshTaskHandler: ((BGAppRefreshTask) -> Void)?
    private var processingTaskHandler: ((BGProcessingTask) -> Void)?
    private var mediaRefreshTaskHandler: ((BGAppRefreshTask) -> Void)?
    private var mediaProcessingTaskHandler: ((BGProcessingTask) -> Void)?
    private var continuedLifecycle =
        ContinuedProcessingLifecycle<ObjectIdentifier>()
    private var hasDiscoveredUntrackedContinuedRequests = false

    private init() {}

    public func install(_ policy: any PlatformBackgroundPolicy) {
        self.policy = policy
    }

    public func handleScenePhase(_ phase: PolicyScenePhase, sceneID: String) {
        policy?.handleScenePhase(phase, sceneID: sceneID)
    }

    public func requestContinuedProcessing() {
        guard let policy else { return }
        if #available(iOS 26.0, *) {
            guard continuedLifecycle.beginSubmission() else { return }
            let identifier = policy.requestContinuedProcessing(.continued)
            continuedLifecycle.finishSubmission(identifier: identifier)
        } else {
            // Earlier systems use the existing fixed BGProcessing request;
            // there is no continued-task handle or Live Activity to track.
            _ = policy.requestContinuedProcessing(.continued)
        }
    }

    public func cancelContinuedProcessingRequests() {
        guard let policy else { return }
        let identifiers = continuedLifecycle.cancelPendingRequests()
        let discoverUntrackedRequests = !hasDiscoveredUntrackedContinuedRequests
        hasDiscoveredUntrackedContinuedRequests = true
        guard !identifiers.isEmpty || discoverUntrackedRequests else { return }
        policy.cancelContinuedProcessingRequests(
            identifiers,
            discoverUntrackedRequests: discoverUntrackedRequests
        )
    }

    /// Prefix discovery completes asynchronously. Protect any new request
    /// submitted after cleanup began so an old-request sweep cannot cancel
    /// current work that happens to enter the scheduler before its callback.
    func shouldCancelDiscoveredContinuedProcessingRequest(
        _ identifier: String
    ) -> Bool {
        !continuedLifecycle.outstandingRequestIdentifiers.contains(identifier)
    }

    public func scheduleRefresh(earliest: Date) {
        policy?.scheduleRefresh(earliest: earliest)
    }

    public func scheduleMediaRefresh(earliest: Date) {
        policy?.scheduleMediaRefresh(earliest: earliest)
    }

    public func scheduleMediaProcessing(earliest: Date = Date()) {
        policy?.scheduleMediaProcessing(earliest: earliest)
    }

    public func installRefreshTaskHandler(_ handler: @escaping (BGAppRefreshTask) -> Void) {
        refreshTaskHandler = handler
    }

    public func handleRefreshTask(_ task: BGAppRefreshTask) {
        guard let refreshTaskHandler else {
            task.setTaskCompleted(success: false)
            return
        }
        refreshTaskHandler(task)
    }

    public func installContinuedTaskHandler(
        _ handler: @escaping (BGContinuedProcessingTask) -> Void
    ) {
        continuedTaskHandler = handler
    }

    public func handleContinuedTask(_ task: BGContinuedProcessingTask) {
        let handleID = ObjectIdentifier(task)
        guard continuedLifecycle.acceptHandle(
            identifier: task.identifier,
            handleID: handleID
        ) else { return }
        guard let continuedTaskHandler else {
            task.setTaskCompleted(success: false)
            _ = continuedLifecycle.completeHandle(
                identifier: task.identifier,
                handleID: handleID
            )
            return
        }
        continuedTaskHandler(task)
    }

    /// Called immediately before the coordinator completes every retained
    /// system object. Draining as one operation prevents an expiration from
    /// leaving a sibling identifier marked active and blocking future work.
    @discardableResult
    func completeAllContinuedTaskHandles() -> [String: Set<ObjectIdentifier>] {
        continuedLifecycle.completeAllAcceptedHandles()
    }

    public func installProcessingTaskHandler(
        _ handler: @escaping (BGProcessingTask) -> Void
    ) {
        processingTaskHandler = handler
    }

    public func handleProcessingTask(_ task: BGProcessingTask) {
        guard let processingTaskHandler else {
            task.setTaskCompleted(success: false)
            return
        }
        processingTaskHandler(task)
    }

    public func installMediaRefreshTaskHandler(_ handler: @escaping (BGAppRefreshTask) -> Void) {
        mediaRefreshTaskHandler = handler
    }

    public func handleMediaRefreshTask(_ task: BGAppRefreshTask) {
        guard let mediaRefreshTaskHandler else {
            task.setTaskCompleted(success: false)
            return
        }
        mediaRefreshTaskHandler(task)
    }

    public func installMediaProcessingTaskHandler(_ handler: @escaping (BGProcessingTask) -> Void) {
        mediaProcessingTaskHandler = handler
    }

    public func handleMediaProcessingTask(_ task: BGProcessingTask) {
        guard let mediaProcessingTaskHandler else {
            task.setTaskCompleted(success: false)
            return
        }
        mediaProcessingTaskHandler(task)
    }

    public func beginShortCompletion(name: String) -> BackgroundExecutionLease? {
        policy?.beginShortCompletion(name: name)
    }
}
#endif
