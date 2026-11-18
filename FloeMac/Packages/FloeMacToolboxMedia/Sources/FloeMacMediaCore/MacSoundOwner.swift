import Foundation
import Observation

/// App-owned microphone lifecycle. A stop is not complete until the source
/// confirms teardown; a timed-out drain retains the pending worker and lease.
@MainActor @Observable
public final class MacSoundOwner {
    public let session: MacSoundSession
    private enum State { case active, preparing, terminal }
    private var state: State = .active
    private var visible = false
    private var ticket = UUID()
    private var windowAvailable: @MainActor () -> Bool = { false }
    private var stopWaiter: Task<Void, Never>?
    private var stopResult: Bool?

    public init(session: MacSoundSession) { self.session = session }

    public func appear(windowAvailable: @escaping @MainActor () -> Bool) {
        visible = true
        ticket = UUID()
        self.windowAvailable = windowAvailable
        installGate()
    }

    public func disappear() {
        visible = false
        ticket = UUID()
        session.stop()
    }

    public func makeStartTicket() -> UUID? { usable ? ticket : nil }

    @discardableResult
    public func start(ticket: UUID) async -> Bool {
        guard ticket == self.ticket, usable else { return false }
        return await session.start()
    }

    public func beginTermination() {
        guard state == .active else { return }
        state = .preparing
        ticket = UUID()
        session.stop()
    }

    public func cancelTermination() {
        guard state == .preparing else { return }
        state = .active
        ticket = UUID()
        installGate()
    }

    public func shutdown() {
        state = .terminal
        ticket = UUID()
        session.stop()
    }

    public func drain(timeout: TimeInterval = 5) async -> Bool {
        guard state == .preparing else { return false }
        if stopWaiter == nil {
            stopResult = nil
            stopWaiter = Task { @MainActor [self] in
                stopResult = await session.waitUntilStopped()
                stopWaiter = nil
            }
        }
        let deadline = ContinuousClock.now + .seconds(max(0, timeout))
        while stopWaiter != nil {
            guard state == .preparing, ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return state == .preparing && stopResult == true
    }

    private var usable: Bool { state == .active && visible && windowAvailable() }

    private func installGate() {
        session.setCaptureAvailability { [weak self] in self?.usable == true }
    }
}
