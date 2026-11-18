import Combine
import Foundation
import UserNotifications
import FloeToolboxUtilities
import FloeToolboxWorkbenches

/// App-owned, independent of any timer window. The owner starts it with the
/// timekeeping service and forwards machine wake / app activation events.
@MainActor
public final class MacSilentTimerCoordinator {
    private let service: ToolboxTimekeepingService
    private let now: @MainActor () -> ToolboxTimeSample
    private let sleep: @MainActor (TimeInterval) async throws -> Void
    private var subscription: AnyCancellable?
    private var deadlineTask: Task<Void, Never>?

    public init(service: ToolboxTimekeepingService,
                now: @escaping @MainActor () -> ToolboxTimeSample = { .now },
                sleep: @escaping @MainActor (TimeInterval) async throws -> Void = {
                    try await Task.sleep(for: .seconds($0))
                }) {
        self.service = service
        self.now = now
        self.sleep = sleep
    }

    /// May be called before or after loading; subsequent calls are harmless.
    public func start() {
        guard subscription == nil else { return }
        subscription = Publishers.CombineLatest(service.$state, service.$loaded)
            .sink { [weak self] _, _ in
                // @Published emits before the property is assigned. Read the
                // finished service state on the next main-actor turn.
                Task { @MainActor [weak self] in self?.reschedule() }
            }
        reschedule()
    }

    /// Reconcile elapsed continuous time after wake or app activation.
    public func wake() {
        guard subscription != nil else { return }
        reschedule()
    }

    public func stop() {
        subscription?.cancel()
        subscription = nil
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private func reschedule() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard service.loaded else { return }
        let sample = now()
        service.reconcile(at: sample)
        guard let delay = service.state.timers
            .filter({ !$0.reminder && $0.phase == .running })
            .map({ $0.remaining(at: sample) }).min() else { return }
        let sleeper = sleep
        deadlineTask = Task { @MainActor [weak self] in
            do { try await sleeper(delay) } catch { return }
            guard !Task.isCancelled else { return }
            self?.reschedule()
        }
    }
}

public enum MacTimerAuthorization: Equatable, Sendable {
    case unknown, denied, authorized, provisional
}

public enum MacTimerNotificationError: LocalizedError, Equatable {
    case invalid
    case permission
    case notScheduled

    public var errorDescription: String? {
        let chinese = Locale.current.language.languageCode?.identifier == "zh"
        switch self {
        case .invalid:
            return chinese ? "当前时长无法设置通知，请检查计时。" : "The timer could not be scheduled with the current values."
        case .permission:
            return chinese ? "请在系统设置中允许 Floe 通知，以便计时结束时提醒。" : "Allow Floe notifications in System Settings to ring when a timer ends."
        case .notScheduled:
            return chinese ? "系统尚未确认计时通知，请重试。" : "The system did not confirm the timer notification."
        }
    }
}

/// A parent task can be cancelled from any executor while the notification
/// center is suspended. Record that fact synchronously, independently of
/// when a subsequent pause/delete operation reaches the main actor.
private final class MacTimerCancellationFence: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    var isCancelled: Bool { lock.withLock { cancelled } }
}

/// The small part of UserNotifications the timer bridge needs. Tests use a
/// deterministic gateway; production uses the system notification center.
public protocol MacUserNotificationGateway: Sendable {
    func authorization() async -> MacTimerAuthorization
    func requestAuthorization() async throws -> Bool
    func add(identifier: String, title: String, body: String, fireAfter: TimeInterval) async throws
    func pendingIdentifiers() async -> Set<String>
    func deliveredIdentifiers() async -> Set<String>
    func removePending(_ identifiers: [String]) async
    func removeDelivered(_ identifiers: [String]) async
}

public struct MacSystemNotificationGateway: MacUserNotificationGateway {
    public init() {}

    private var center: UNUserNotificationCenter { .current() }

    public func authorization() async -> MacTimerAuthorization {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized: return .authorized
        case .provisional, .ephemeral: return .provisional
        case .denied: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    public func add(identifier: String, title: String, body: String, fireAfter: TimeInterval) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireAfter), repeats: false)
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }

    public func pendingIdentifiers() async -> Set<String> {
        Set(await center.pendingNotificationRequests().map(\.identifier))
    }

    public func deliveredIdentifiers() async -> Set<String> {
        Set(await center.deliveredNotifications().map(\.request.identifier))
    }

    public func removePending(_ identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func removeDelivered(_ identifiers: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Owns the mapping between Floe timers and macOS notification requests.
/// Every externally visible mutation is read back before it is reported.
@MainActor
public final class MacTimerNotificationController: ObservableObject {
    public static let identifierPrefix = MacTimerPresentationPolicy.identifierPrefix

    private let gateway: any MacUserNotificationGateway
    private let clockNow: @MainActor () -> ContinuousClock.Instant
    @Published public private(set) var authorization: MacTimerAuthorization = .unknown
    // Gate every OS mutation through one ordered queue. A newer timer action
    // fences an older suspended operation before it can schedule an alert.
    private var operationTail: Task<Void, Never>?
    private var latestOperation: [UUID: UUID] = [:]

    public init(gateway: any MacUserNotificationGateway = MacSystemNotificationGateway(),
                clockNow: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.gateway = gateway
        self.clockNow = clockNow
    }

    public func refreshAuthorization() async {
        authorization = await gateway.authorization()
    }

    /// Requests permission only when the user explicitly enables a timer
    /// reminder. A previously denied choice is never bypassed.
    public func authorize() async throws -> Bool {
        let current = await gateway.authorization()
        authorization = current
        switch current {
        case .authorized, .provisional:
            return true
        case .denied:
            return false
        case .unknown:
            let granted = try await gateway.requestAuthorization()
            authorization = await gateway.authorization()
            return granted && (authorization == .authorized || authorization == .provisional)
        }
    }

    public func synchronize(_ request: ToolboxTimerAlarmRequest) async throws -> ToolboxTimerAlarmState? {
        guard request.remaining.isFinite, (0...ToolboxCountdown.maximumDuration).contains(request.remaining),
              !request.label.isEmpty, request.label.utf8.count <= 256 else {
            throw MacTimerNotificationError.invalid
        }
        guard !Task.isCancelled else { throw CancellationError() }
        let token = UUID()
        let cancellation = MacTimerCancellationFence()
        // Capture the deadline before waiting behind other notification work.
        let deadline = clockNow().advanced(by: .seconds(request.remaining))
        latestOperation[request.timerID] = token
        return try await withTaskCancellationHandler {
            try await enqueue { [self] in
                defer { finishOperation(request.timerID, token: token) }
                return try await synchronizeQueued(request, token: token, cancellation: cancellation, deadline: deadline)
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func synchronizeQueued(_ request: ToolboxTimerAlarmRequest, token: UUID,
                                   cancellation: MacTimerCancellationFence,
                                   deadline: ContinuousClock.Instant) async throws -> ToolboxTimerAlarmState? {
        try requireCurrent(request.timerID, token: token, cancellation: cancellation)
        let identifier = Self.identifier(for: request.timerID, generation: request.generation)
        let pending = await gateway.pendingIdentifiers()
        let delivered = await gateway.deliveredIdentifiers()
        try requireCurrent(request.timerID, token: token, cancellation: cancellation)
        let timerPending = pending.filter { Self.belongs($0, to: request.timerID) }
        let timerDelivered = delivered.filter { Self.belongs($0, to: request.timerID) }

        if request.action == .reset || request.action == .pause || !request.isRunning {
            try await removeAndConfirm(pending: timerPending, delivered: timerDelivered)
            try requireCurrent(request.timerID, token: token, cancellation: cancellation)
            return .init(timerID: request.timerID, generation: request.generation, phase: .paused,
                         remaining: request.remaining)
        }

        // A delivered request is positive evidence that the alert fired.
        // An explicit restart replaces stale delivered evidence; only refresh
        // reports the alerting state.
        if timerDelivered.contains(identifier) {
            try await removeAndConfirm(pending: [], delivered: timerDelivered)
            try requireCurrent(request.timerID, token: token, cancellation: cancellation)
            if request.action == .refresh {
                return .init(timerID: request.timerID, generation: request.generation, phase: .alerting, remaining: 0)
            }
        }

        // Always remove legacy and stale generations. Only the current
        // generation may be interpreted as evidence of a running timer.
        let retainCurrent = request.action == .refresh && timerPending.contains(identifier)
        let stalePending = retainCurrent ? timerPending.subtracting([identifier]) : timerPending
        let staleDelivered = timerDelivered.subtracting([identifier])
        try await removeAndConfirm(pending: stalePending, delivered: staleDelivered)
        try requireCurrent(request.timerID, token: token, cancellation: cancellation)
        if retainCurrent {
            let remaining = remainingUntil(deadline)
            guard remaining > 0 else {
                return .init(timerID: request.timerID, generation: request.generation, phase: .unverified, remaining: nil)
            }
            return .init(timerID: request.timerID, generation: request.generation, phase: .running,
                         remaining: remaining)
        }

        guard remainingUntil(deadline) > 0 else {
            // No pending request and no delivered request is not proof that
            // an alert fired. Do not claim success or ring unexpectedly.
            return .init(timerID: request.timerID, generation: request.generation, phase: .unverified, remaining: nil)
        }

        let state = await gateway.authorization()
        try requireCurrent(request.timerID, token: token, cancellation: cancellation)
        authorization = state
        guard state == .authorized || state == .provisional else {
            return .init(timerID: request.timerID, generation: request.generation, phase: .unverified, remaining: nil)
        }

        let remaining = remainingUntil(deadline)
        guard remaining > 0 else {
            return .init(timerID: request.timerID, generation: request.generation, phase: .unverified, remaining: nil)
        }

        let title = Locale.current.language.languageCode?.identifier == "zh" ? "计时结束" : "Timer finished"
        do {
            try await gateway.add(identifier: identifier, title: title, body: request.label,
                                  fireAfter: max(1, remaining))
        } catch {
            // An error does not prove the system failed before committing.
            try await removeAndConfirm(pending: [identifier], delivered: [identifier])
            throw error
        }
        if latestOperation[request.timerID] != token || cancellation.isCancelled {
            // The OS request may have committed while a newer pause/delete
            // arrived. The queued successor has not run yet, so remove this
            // exact generation and verify the compensating cleanup first.
            try await removeAndConfirm(pending: [identifier], delivered: [identifier])
            throw CancellationError()
        }
        guard await gateway.pendingIdentifiers().contains(identifier) else {
            throw MacTimerNotificationError.notScheduled
        }
        if latestOperation[request.timerID] != token || cancellation.isCancelled {
            try await removeAndConfirm(pending: [identifier], delivered: [identifier])
            throw CancellationError()
        }
        let confirmedRemaining = remainingUntil(deadline)
        guard confirmedRemaining > 0 else {
            return .init(timerID: request.timerID, generation: request.generation, phase: .unverified, remaining: nil)
        }
        return .init(timerID: request.timerID, generation: request.generation, phase: .running,
                     remaining: confirmedRemaining)
    }

    private func remainingUntil(_ deadline: ContinuousClock.Instant) -> TimeInterval {
        let components = clockNow().duration(to: deadline).components
        return max(0, Double(components.seconds) + Double(components.attoseconds) / 1e18)
    }

    public func cancel(timerID: UUID) async throws {
        let token = UUID()
        latestOperation[timerID] = token
        try await enqueue { [self] in
            defer { finishOperation(timerID, token: token) }
            let pending = await gateway.pendingIdentifiers().filter { Self.belongs($0, to: timerID) }
            let delivered = await gateway.deliveredIdentifiers().filter { Self.belongs($0, to: timerID) }
            try requireCurrent(timerID, token: token)
            try await removeAndConfirm(pending: pending, delivered: delivered)
            try requireCurrent(timerID, token: token)
        }
    }

    /// Removes only requests owned by this feature. Notifications created by
    /// other Floe features or other apps are never touched.
    public func prune(keeping timerIDs: [UUID]) async throws {
        let kept = Set(timerIDs)
        try await enqueue { [self] in
            let pending = await gateway.pendingIdentifiers().filter { $0.hasPrefix(Self.identifierPrefix) }
            let delivered = await gateway.deliveredIdentifiers().filter { $0.hasPrefix(Self.identifierPrefix) }
            // A timer action registered after this prune was queued wins.
            let stalePending = pending.filter { identifier in
                guard let id = Self.timerID(from: identifier) else { return true }
                return !kept.contains(id) && latestOperation[id] == nil
            }
            let staleDelivered = delivered.filter { identifier in
                guard let id = Self.timerID(from: identifier) else { return true }
                return !kept.contains(id) && latestOperation[id] == nil
            }
            try await removeAndConfirm(pending: stalePending, delivered: staleDelivered)
        }
    }

    /// Legacy identifier remains recognized for cleanup, never as proof that
    /// a particular new generation fired.
    public static func identifier(for timerID: UUID) -> String {
        identifierPrefix + timerID.uuidString
    }

    public static func identifier(for timerID: UUID, generation: UInt64) -> String {
        identifier(for: timerID) + "." + String(generation)
    }

    private static func belongs(_ identifier: String, to timerID: UUID) -> Bool {
        identifier == self.identifier(for: timerID) || identifier.hasPrefix(self.identifier(for: timerID) + ".")
    }

    private static func timerID(from identifier: String) -> UUID? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        let rest = identifier.dropFirst(identifierPrefix.count)
        guard let first = rest.split(separator: ".", maxSplits: 1).first else { return nil }
        return UUID(uuidString: String(first))
    }

    private func removeAndConfirm(pending: Set<String>, delivered: Set<String>) async throws {
        if !pending.isEmpty { await gateway.removePending(Array(pending)) }
        if !delivered.isEmpty { await gateway.removeDelivered(Array(delivered)) }
        let pendingNow = await gateway.pendingIdentifiers()
        let deliveredNow = await gateway.deliveredIdentifiers()
        guard pending.isDisjoint(with: pendingNow), delivered.isDisjoint(with: deliveredNow) else {
            throw MacTimerNotificationError.notScheduled
        }
    }

    private func requireCurrent(_ timerID: UUID, token: UUID,
                                cancellation: MacTimerCancellationFence? = nil) throws {
        guard latestOperation[timerID] == token, cancellation?.isCancelled != true else { throw CancellationError() }
    }

    private func finishOperation(_ timerID: UUID, token: UUID) {
        if latestOperation[timerID] == token { latestOperation.removeValue(forKey: timerID) }
    }

    private func enqueue<Value: Sendable>(
        _ action: @escaping @MainActor @Sendable () async throws -> Value
    ) async throws -> Value {
        let previous = operationTail
        let task = Task { @MainActor in
            if let previous { await previous.value }
            return try await action()
        }
        operationTail = Task { @MainActor in _ = await task.result }
        return try await task.value
    }
}

public extension MacTimerNotificationController {
    /// Bridges the existing cross-platform timekeeping service to macOS
    /// UserNotifications without introducing a second timer model.
    var reminderBridge: ToolboxTimerReminderBridge {
        ToolboxTimerReminderBridge(
            authorize: { [weak self] in try await self?.authorize() ?? false },
            synchronize: { [weak self] request in try await self?.synchronize(request) },
            cancel: { [weak self] timerID in try await self?.cancel(timerID: timerID) },
            prune: { [weak self] timerIDs in try await self?.prune(keeping: timerIDs) },
            updates: nil
        )
    }
}
