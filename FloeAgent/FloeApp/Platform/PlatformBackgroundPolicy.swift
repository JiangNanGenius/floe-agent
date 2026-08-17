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
    /// BGContinuedProcessingTask (iOS 26+) — foreground-initiated exports,
    /// image batches, remote bulk commands, with Live Activity progress.
    case continued = "org.floeagent.ios.continued.*"

    /// Continued-processing registrations use a wildcard, while every
    /// foreground submission must carry a concrete unique suffix.
    var submissionIdentifier: String {
        guard self == .continued else { return rawValue }
        return rawValue.replacingOccurrences(of: "*", with: UUID().uuidString)
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

    /// Requests continued background processing for a foreground-initiated
    /// workload (iOS 26 BGContinuedProcessingTask with BGProcessingTask
    /// fallback).
    func requestContinuedProcessing(_ kind: BackgroundTaskKind)

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

    private init() {}

    public func install(_ policy: any PlatformBackgroundPolicy) {
        self.policy = policy
    }

    public func handleScenePhase(_ phase: PolicyScenePhase, sceneID: String) {
        policy?.handleScenePhase(phase, sceneID: sceneID)
    }

    public func requestContinuedProcessing() {
        policy?.requestContinuedProcessing(.continued)
    }

    public func scheduleRefresh(earliest: Date) {
        policy?.scheduleRefresh(earliest: earliest)
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
        guard let continuedTaskHandler else {
            task.setTaskCompleted(success: false)
            return
        }
        continuedTaskHandler(task)
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

    public func beginShortCompletion(name: String) -> BackgroundExecutionLease? {
        policy?.beginShortCompletion(name: name)
    }
}
#endif
