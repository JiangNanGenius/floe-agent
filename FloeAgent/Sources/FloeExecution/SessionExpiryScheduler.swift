import Foundation

/// One-shot session-expiry scheduler shared by raw TCP, interactive shell and
/// Bluetooth sessions (previously three hand-rolled 30-minute sleeps).
actor SessionExpiryScheduler {
    static let shared = SessionExpiryScheduler()
    private var tasks: [UUID: Task<Void, Never>] = [:]

    /// Schedules `onExpire` after `seconds`, replacing any prior schedule for
    /// the same id. Expiry is best-effort; callers must keep their own
    /// idempotent removal (a session closed early simply finds no entry).
    func schedule(
        id: UUID,
        after seconds: TimeInterval,
        onExpire: @escaping @Sendable () async -> Void
    ) {
        tasks[id]?.cancel()
        tasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.remove(id: id)
            await onExpire()
        }
    }

    func cancel(id: UUID) {
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    private func remove(id: UUID) {
        tasks[id] = nil
    }
}
