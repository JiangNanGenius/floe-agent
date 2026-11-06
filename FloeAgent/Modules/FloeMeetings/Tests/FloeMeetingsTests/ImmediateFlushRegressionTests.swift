// SPDX-License-Identifier: MPL-2.0
import XCTest
@testable import FloeMeetings

actor TestGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        let current = waiters
        waiters = []
        for waiter in current { waiter.resume() }
    }
}

actor SuspendedCaptureBackend: MeetingCaptureBackend {
    let beginGate: TestGate?
    let stopGate: TestGate?
    let cancelGate: TestGate?
    let emitStopped: Bool
    let failBegin: Bool
    private(set) var beginEntered = false
    private(set) var stopEntered = false
    private(set) var cancelEntered = false
    private var sink: (@Sendable (CaptureEvent) -> Void)?
    private var session: CaptureSessionID?
    init(begin: TestGate? = nil, stop: TestGate? = nil, cancel: TestGate? = nil,
         emitStopped: Bool = false, failBegin: Bool = false) {
        beginGate = begin; stopGate = stop; cancelGate = cancel
        self.emitStopped = emitStopped; self.failBegin = failBegin
    }
    func begin(session: CaptureSessionID, configuration: CaptureConfiguration,
               sink: @escaping @Sendable (CaptureEvent) -> Void) async throws {
        beginEntered = true; self.session = session; self.sink = sink
        await beginGate?.wait()
        if failBegin { throw MeetingError.captureBackendFailed("intentional test failure") }
        sink(.started(session: session))
    }
    func requestStop() async {
        stopEntered = true
        if emitStopped, let session { sink?(.stopped(session: session, reason: .userStopped)) }
        await stopGate?.wait()
    }
    func cancel() async { cancelEntered = true; await cancelGate?.wait() }
    func emit(_ event: CaptureEvent) { sink?(event) }
}

actor CompletionFlag {
    private(set) var complete = false
    func mark() { complete = true }
}

final class ImmediateFlushRegressionTests: XCTestCase {
    // This test also compiles against the original package. The backend
    // acknowledges stop while its requestStop call is deliberately suspended.
    // The original implementation fails the bounded assertion deterministically.
    func testStopAcknowledgementDoesNotWaitForRequestStopToReturn() async throws {
        let controller = MeetingCaptureController()
        let gate = TestGate()
        let backend = SuspendedCaptureBackend(stop: gate, emitStopped: true)
        try await controller.start(session: CaptureSessionID(),
            configuration: .init(directory: URL(fileURLWithPath: NSTemporaryDirectory()), stopTimeout: 0.1),
            backend: backend) { _ in }
        let flag = CompletionFlag()
        let operation = Task { _ = await controller.stop(); await flag.mark() }
        let finished = await TestWait.until({ await flag.complete }, timeout: 1)
        XCTAssertTrue(finished, "stop acknowledgement was lost while requestStop was suspended")
        await gate.release()
        if finished { await operation.value }
    }
}
