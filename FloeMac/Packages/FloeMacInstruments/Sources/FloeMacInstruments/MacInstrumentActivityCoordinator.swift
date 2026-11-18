// SPDX-License-Identifier: MPL-2.0
import Foundation
import Observation

/// Host-owned admission and drain barrier for instrument writes and exports.
/// Existing operations remain registered until their async work has returned.
@MainActor
@Observable
public final class MacInstrumentActivityCoordinator {
    private var closed = false
    private var activities: [UUID: (@MainActor () -> Void)?] = [:]
    private var stopLocation: (@MainActor () -> Void)?
    private(set) var locationFailure: MacInstrumentNotice?
    private(set) var rulerFailure: MacRulerStorageFailure?

    public init() {}

    public var acceptsNewWork: Bool { !closed }

    func begin() -> UUID? {
        guard !closed else { return nil }
        let id = UUID()
        activities[id] = .some(nil)
        return id
    }

    func onCancel(_ id: UUID, _ action: @escaping @MainActor () -> Void) {
        guard activities.keys.contains(id) else { return }
        activities[id] = .some(action)
        if closed { action() }
    }

    func finish(_ id: UUID) { activities.removeValue(forKey: id) }

    /// Reserve synchronously in the button action, before scheduling a task,
    /// so a quit cannot overtake an already accepted user operation.
    @discardableResult
    func enqueue(_ operation: @escaping @MainActor () async -> Void) -> Bool {
        guard let id = begin() else { return false }
        Task { [self] in
            defer { finish(id) }
            await operation()
        }
        return true
    }

    func registerLocationStop(_ action: @escaping @MainActor () -> Void) {
        stopLocation = action
        if closed { action() }
    }

    func recordLocationFailure(_ notice: MacInstrumentNotice) { locationFailure = notice }
    func acknowledgeLocationFailure() { locationFailure = nil }
    func recordRulerFailure(_ failure: MacRulerStorageFailure) { rulerFailure = failure }
    func acknowledgeRulerFailure() { rulerFailure = nil }

    public func closeAdmissions() {
        closed = true
        stopLocation?()
        for action in activities.values { action?() }
    }

    public func resumeAfterCancelledTermination() { closed = false }

    /// A timeout keeps the app open. It never treats cancellation as proof
    /// that a file commit or storage operation actually finished.
    public func drain(timeout: TimeInterval = 5) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(max(0, timeout))
        while !activities.isEmpty {
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(20)) }
            catch { return false }
        }
        return locationFailure == nil && rulerFailure == nil
    }
}
