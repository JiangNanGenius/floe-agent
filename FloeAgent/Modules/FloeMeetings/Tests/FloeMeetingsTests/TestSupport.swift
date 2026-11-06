// SPDX-License-Identifier: MPL-2.0
import Foundation
@testable import FloeMeetings

/// Deterministic backend with controllable flush behavior. Test-only:
/// a locked class so flags are readable/mutable from the test without await.
final class FakeCaptureBackend: MeetingCaptureBackend, @unchecked Sendable {
    var emitStartedAutomatically = true
    var flushOnRequestStop = true
    private(set) var stopRequested = false
    private(set) var cancelCount = 0
    private(set) var beginCount = 0

    private var sink: (@Sendable (CaptureEvent) -> Void)?
    private var session: CaptureSessionID?
    private let lock = NSLock()

    func begin(
        session: CaptureSessionID,
        configuration: CaptureConfiguration,
        sink: @escaping @Sendable (CaptureEvent) -> Void
    ) throws {
        lock.lock(); defer { lock.unlock() }
        beginCount += 1
        self.session = session
        self.sink = sink
        if emitStartedAutomatically {
            sink(.started(session: session))
        }
    }

    func requestStop() {
        lock.lock(); defer { lock.unlock() }
        stopRequested = true
        if flushOnRequestStop, let session {
            sink?(.stopped(session: session, reason: .userStopped))
        }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelCount += 1
    }

    func emit(_ event: CaptureEvent) {
        lock.lock(); defer { lock.unlock() }
        sink?(event)
    }
}

/// Append-only event log safe to capture from @Sendable closures.
actor EventLog {
    private(set) var events: [CaptureEvent] = []
    func append(_ event: CaptureEvent) { events.append(event) }
}

enum TestWait {
    static func until(_ condition: @escaping @Sendable () async -> Bool, timeout: TimeInterval = 3) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }
}
