// FloeCore — Shared background-work model.
//
// One model covers the three families of work the user expects to keep
// running outside the foreground conversation: provider/model runs, a
// background Linux session, and managed Linux services inside that session.
// The model is intentionally a value-type snapshot plus an actor registry:
// UI and Picture-in-Picture render snapshots, while the owners (run
// coordinator and the Linux session controller) remain the only writers.

import Foundation

/// The family of background work. Stable raw values are persisted in durable
/// state and notification deep links, so they must not be renamed.
public enum BackgroundWorkKind: String, Sendable, Codable, CaseIterable, Hashable {
    /// A provider/agent run owned by a conversation.
    case modelRun
    /// The Linux guest session itself.
    case linuxSession
    /// A managed long-running service (Node/Python) inside a Linux session.
    case linuxService
}

/// Durable lifecycle state. "Terminal" means the owner will not produce
/// further progress without an explicit new user/recovery action.
public enum BackgroundWorkState: String, Sendable, Codable, CaseIterable, Hashable {
    case queued
    case running
    /// Success has been produced; the surface may dwell before teardown.
    case completing
    case completed
    case failed
    /// User/system checkpoint: the durable run is resumable.
    case suspended
    /// iOS reclaimed the process or the guest stopped unexpectedly.
    case interrupted
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .interrupted, .cancelled: true
        default: false
        }
    }

    /// True when the surface must remain actionable (recover/resume) rather
    /// than showing a plain success/teardown.
    public var isUnfinished: Bool {
        switch self {
        case .failed, .suspended, .interrupted: true
        default: false
        }
    }
}

/// Honest interruption/recovery classification. We never claim the process
/// survived an app suspension; instead we say whether resuming is possible.
public enum BackgroundWorkInterruption: String, Sendable, Codable, Hashable {
    case none
    /// The run reached a durable checkpoint and can resume.
    case checkpointed
    /// The scene/app left the foreground; work may continue briefly under the
    /// system background allowance but is not promised to survive.
    case suspendedBySystem
    /// iOS terminated the process or the guest was torn down; recovery uses
    /// the last durable state, never the vanished process.
    case terminatedBySystem

    public var offersRecovery: Bool { self != .none }
}

/// Truthful guest accelerator status. TinyEMU interprets RISC-V with no GPU
/// passthrough, so Linux 3D/GPU work is unavailable; heavy graphics on this
/// device use native Apple frameworks instead. Reporting a fabricated 0%
/// would imply a measured GPU, so we model availability explicitly.
public enum BackgroundWorkGPUStatus: String, Sendable, Codable, Hashable {
    /// No guest GPU passthrough exists; graphics run native-only.
    case unavailableNativeOnly
}

/// Bounded, point-in-time resource sample for a Linux session. All values are
/// optional/upper-clamped by the sampler; a missing value renders as "—",
/// never 0. Sampling only runs while a consumer is registered.
public struct BackgroundWorkMetrics: Sendable, Codable, Hashable {
    /// Emulator thread CPU share (host-side proxy for vCPU), 0...1.
    public var emulatorCPUFraction: Double?
    /// Guest-reported aggregate CPU share from /proc, 0...1.
    public var guestCPUFraction: Double?
    public var guestMemoryUsedMB: Int?
    public var guestMemoryTotalMB: Int?
    public var networkRxKB: Double?
    public var networkTxKB: Double?
    public var gpu: BackgroundWorkGPUStatus

    public init(
        emulatorCPUFraction: Double? = nil,
        guestCPUFraction: Double? = nil,
        guestMemoryUsedMB: Int? = nil,
        guestMemoryTotalMB: Int? = nil,
        networkRxKB: Double? = nil,
        networkTxKB: Double? = nil,
        gpu: BackgroundWorkGPUStatus = .unavailableNativeOnly
    ) {
        self.emulatorCPUFraction = emulatorCPUFraction.map { Self.clamp($0) }
        self.guestCPUFraction = guestCPUFraction.map { Self.clamp($0) }
        self.guestMemoryUsedMB = guestMemoryUsedMB
        self.guestMemoryTotalMB = guestMemoryTotalMB
        self.networkRxKB = networkRxKB.map { max(0, $0) }
        self.networkTxKB = networkTxKB.map { max(0, $0) }
        self.gpu = gpu
    }

    static func clamp(_ value: Double) -> Double { min(1, max(0, value)) }
}

/// Deep-link identity carried in notifications and persisted state. A model
/// run routes to its conversation; a Linux session/service routes to the
/// execution-environment surface (optionally focused on one environment).
public struct BackgroundWorkDeepLink: Sendable, Codable, Hashable {
    public let kind: BackgroundWorkKind
    public var conversationID: UUID?
    public var runID: UUID?
    public var environmentID: String?
    public var serviceJobID: UUID?

    public init(
        kind: BackgroundWorkKind,
        conversationID: UUID? = nil,
        runID: UUID? = nil,
        environmentID: String? = nil,
        serviceJobID: UUID? = nil
    ) {
        self.kind = kind
        self.conversationID = conversationID
        self.runID = runID
        self.environmentID = environmentID
        self.serviceJobID = serviceJobID
    }

    /// Notification `userInfo` payload. Keys are part of the deep-link
    /// contract and must stay stable across releases.
    public var userInfo: [String: String] {
        var info: [String: String] = ["workKind": kind.rawValue]
        if let conversationID { info["conversationID"] = conversationID.uuidString }
        if let runID { info["runID"] = runID.uuidString }
        if let environmentID { info["environmentID"] = environmentID }
        if let serviceJobID { info["serviceJobID"] = serviceJobID.uuidString }
        return info
    }

    /// Parses a deep-link payload. Returns nil unless the kind is known.
    public static func parse(_ userInfo: [AnyHashable: Any]) -> BackgroundWorkDeepLink? {
        guard let raw = userInfo["workKind"] as? String,
              let kind = BackgroundWorkKind(rawValue: raw) else {
            // Backwards compatibility: legacy notifications carried only a
            // conversationID and always routed to the conversation.
            if let convRaw = userInfo["conversationID"] as? String,
               let conv = UUID(uuidString: convRaw) {
                return BackgroundWorkDeepLink(kind: .modelRun, conversationID: conv)
            }
            return nil
        }
        return BackgroundWorkDeepLink(
            kind: kind,
            conversationID: (userInfo["conversationID"] as? String).flatMap(UUID.init(uuidString:)),
            runID: (userInfo["runID"] as? String).flatMap(UUID.init(uuidString:)),
            environmentID: userInfo["environmentID"] as? String,
            serviceJobID: (userInfo["serviceJobID"] as? String).flatMap(UUID.init(uuidString:))
        )
    }
}

/// Immutable point-in-time view of one unit of background work.
public struct BackgroundWorkSnapshot: Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let kind: BackgroundWorkKind
    public var title: String
    public var state: BackgroundWorkState
    public var interruption: BackgroundWorkInterruption
    /// 0...1 where measurable; nil for indeterminate work.
    public var progress: Double?
    public var progressText: String
    public let startedAt: Date
    public var updatedAt: Date
    public var activeCommandCount: Int
    public var activeServiceCount: Int
    public var metrics: BackgroundWorkMetrics?
    public let deepLink: BackgroundWorkDeepLink

    public init(
        id: UUID,
        kind: BackgroundWorkKind,
        title: String,
        state: BackgroundWorkState = .running,
        interruption: BackgroundWorkInterruption = .none,
        progress: Double? = nil,
        progressText: String = "",
        startedAt: Date = Date(),
        updatedAt: Date = Date(),
        activeCommandCount: Int = 0,
        activeServiceCount: Int = 0,
        metrics: BackgroundWorkMetrics? = nil,
        deepLink: BackgroundWorkDeepLink
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.state = state
        self.interruption = interruption
        self.progress = progress.map { BackgroundWorkMetrics.clamp($0) }
        self.progressText = progressText
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.activeCommandCount = max(0, activeCommandCount)
        self.activeServiceCount = max(0, activeServiceCount)
        self.metrics = metrics
        self.deepLink = deepLink
    }

    public func elapsedSeconds(now: Date = Date()) -> Int {
        max(0, Int(now.timeIntervalSince(startedAt)))
    }

    /// Stable, human-facing elapsed-time label, e.g. "12:34" or "1:02:03".
    public func elapsedTimeLabel(now: Date = Date()) -> String {
        let total = elapsedSeconds(now: now)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }
}

public extension BackgroundWorkSnapshot {
    /// Deterministic id for work keyed by a stable string rather than a run
    /// UUID (a Linux environment id). The same environment maps to the same
    /// work id in every process, so durable records, the registry and deep
    /// links all address the same unit of work. One-way and not
    /// security-sensitive.
    static func stableID(for identifier: String) -> UUID {
        let hex = Array(FloeDigest.sha256Hex(Data(identifier.utf8)).prefix(32))
        guard hex.count == 32 else { return UUID() }
        let text = String(hex)
        let formatted = [
            text.prefix(8),
            text.dropFirst(8).prefix(4),
            text.dropFirst(12).prefix(4),
            text.dropFirst(16).prefix(4),
            text.dropFirst(20).prefix(12),
        ].joined(separator: "-")
        return UUID(uuidString: formatted) ?? UUID()
    }
}

/// App-lifetime registry shared by the run coordinator and the Linux session
/// controller. Observers receive the full current snapshot set on change.
public actor BackgroundWorkRegistry {    public static let shared = BackgroundWorkRegistry()

    private var works: [UUID: BackgroundWorkSnapshot] = [:]
    private var continuations: [UUID: AsyncStream<[BackgroundWorkSnapshot]>.Continuation] = [:]

    public init() {}

    public func snapshot(id: UUID) -> BackgroundWorkSnapshot? { works[id] }

    public func allSnapshots() -> [BackgroundWorkSnapshot] {
        works.values.sorted { $0.startedAt < $1.startedAt }
    }

    public func register(_ snapshot: BackgroundWorkSnapshot) {
        works[snapshot.id] = snapshot
        publish()
    }

    public func update(
        id: UUID,
        _ mutate: (inout BackgroundWorkSnapshot) -> Void
    ) {
        guard var snapshot = works[id] else { return }
        mutate(&snapshot)
        snapshot.updatedAt = Date()
        works[id] = snapshot
        publish()
    }

    /// Records a terminal state, keeping the snapshot for deep-link/recovery
    /// surfaces until the owner explicitly removes it.
    public func finish(
        id: UUID,
        state: BackgroundWorkState,
        interruption: BackgroundWorkInterruption = .none,
        progressText: String? = nil
    ) {
        guard var snapshot = works[id] else { return }
        snapshot.state = state
        snapshot.interruption = interruption
        snapshot.progress = state == .completed ? 1 : snapshot.progress
        if let progressText { snapshot.progressText = progressText }
        snapshot.activeCommandCount = state.isTerminal ? 0 : snapshot.activeCommandCount
        snapshot.updatedAt = Date()
        works[id] = snapshot
        publish()
    }

    public func remove(id: UUID) {
        guard works.removeValue(forKey: id) != nil else { return }
        publish()
    }

    public func snapshots() -> AsyncStream<[BackgroundWorkSnapshot]> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.yield(allSnapshots())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(token) }
            }
        }
    }

    private func removeObserver(_ token: UUID) {
        continuations.removeValue(forKey: token)
    }

    private func publish() {
        let current = allSnapshots()
        for continuation in continuations.values {
            continuation.yield(current)
        }
    }
}
