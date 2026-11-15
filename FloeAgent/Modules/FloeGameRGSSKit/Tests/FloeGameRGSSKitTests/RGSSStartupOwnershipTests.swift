// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeGameCore
@testable import FloeGameRGSS

private enum StartupFixtureError: Error { case input, stop }
private struct StartupContext: RGSSGuestContextHost {
    let value: GameProjectContext
    func currentContext(for captured: GameProjectContext) async throws -> GameProjectContext { value }
}
private actor StartupPort: RGSSGuestRuntimePort {
    var stopFailures: Int
    let failedStatus: Bool
    private(set) var launches = 0
    private(set) var stops = 0
    init(stopFailures: Int, failedStatus: Bool = false) {
        self.stopFailures = stopFailures; self.failedStatus = failedStatus
    }
    func launch(_ request: RGSSGuestLaunchRequest) async throws -> RGSSGuestJobHandle {
        launches += 1
        return .init(jobID: request.jobID, ownerToken: UUID())
    }
    func status(_ handle: RGSSGuestJobHandle) async throws -> RGSSGuestJobStatus {
        .init(handle: handle, state: failedStatus ? .failed("fixture startup") : .running(frameRevision: 0))
    }
    func stop(_ handle: RGSSGuestJobHandle) async throws {
        stops += 1
        if stopFailures > 0 { stopFailures -= 1; throw StartupFixtureError.stop }
    }
}
private actor StartupInput: RGSSGuestInputSession {
    private(set) var invalidations = 0
    func sendChord(_ keys: [RGSSGuestInputKey]) async throws {}
    func releaseAll() async {}
    func invalidate() async { invalidations += 1 }
}
private actor StartupInputs: RGSSGuestInputPortProviding {
    let input = StartupInput()
    var failures: Int
    let blocked: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requested = false
    init(failures: Int = 0, blocked: Bool = false) { self.failures = failures; self.blocked = blocked }
    func makeInputSession(for session: RGSSGuestSession) async throws -> any RGSSGuestInputSession {
        requested = true
        if blocked { await withCheckedContinuation { continuation = $0 } }
        if failures > 0 { failures -= 1; throw StartupFixtureError.input }
        return input
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
final class RGSSStartupOwnershipTests: XCTestCase {
    private func context() throws -> GameProjectContext {
        let id = UUID()
        return try .init(projectID: id, owner: .space(recordID: id),
            rootURL: FileManager.default.temporaryDirectory.appendingPathComponent(id.uuidString),
            savedRevision: "startup-revision", environmentID: "startup-environment")
    }
    private func start(_ controller: RGSSGuestHostController, context: GameProjectContext) async throws -> RGSSGuestSession {
        try await controller.start(context: context, engine: .rpgMakerXP,
            displayServiceID: "startup-display", sourceDigest: String(repeating: "b", count: 64))
    }
    func testAdapterFailedStatusAndFailedCleanupKeepsAnActualRetryableSession() async throws {
        let value = try context(), port = StartupPort(stopFailures: 1, failedStatus: true)
        let adapter = RGSSGuestRuntimeAdapter(port: port, contexts: StartupContext(value: value))
        var retained: RGSSGuestSession?
        do {
            _ = try await adapter.run(context: value, engine: .rpgMakerXP,
                displayServiceID: "startup-display", sourceDigest: String(repeating: "b", count: 64))
            XCTFail("startup must fail")
        } catch let failure as RGSSGuestStartupCleanupError { retained = failure.session }
        let session = try XCTUnwrap(retained)
        let actual = await adapter.activeSession(session.jobID)
        XCTAssertEqual(actual, session)
        try await adapter.stop(session)
        let after = await adapter.activeSession(session.jobID)
        XCTAssertNil(after)
    }
    func testInputAttachmentFailureRetainsOwnerAndCannotSendNewInput() async throws {
        let value = try context(), port = StartupPort(stopFailures: 1)
        let controller = RGSSGuestHostController(port: port, inputs: StartupInputs(failures: 1), contexts: StartupContext(value: value))
        do { _ = try await start(controller, context: value); XCTFail("input failure") }
        catch { XCTAssertTrue(error is RGSSGuestStartupCleanupError) }
        let owned = await controller.retainedSession()
        let session = try XCTUnwrap(owned)
        do { try await controller.sendChord([], for: session); XCTFail("failed input may not send") }
        catch { XCTAssertEqual(error as? RGSSGuestHostError, .inputUnavailable) }
        try await controller.stop(session)
        let after = await controller.retainedSession()
        XCTAssertNil(after)
    }
    func testFailedAdapterStartReachesControllerOwnershipForRetry() async throws {
        let value = try context(), port = StartupPort(stopFailures: 1, failedStatus: true)
        let controller = RGSSGuestHostController(port: port, inputs: StartupInputs(), contexts: StartupContext(value: value))
        do { _ = try await start(controller, context: value); XCTFail("status failure") }
        catch { XCTAssertTrue(error is RGSSGuestStartupCleanupError) }
        let owned = await controller.retainedSession()
        try await controller.stop(XCTUnwrap(owned))
        let stops = await port.stops
        XCTAssertEqual(stops, 2)
    }
    func testConfirmedStartupCleanupPermitsASecondRealLaunch() async throws {
        let value = try context(), port = StartupPort(stopFailures: 0)
        let controller = RGSSGuestHostController(port: port, inputs: StartupInputs(failures: 1), contexts: StartupContext(value: value))
        do { _ = try await start(controller, context: value); XCTFail("input failure") }
        catch { XCTAssertEqual(error as? RGSSGuestHostError, .inputUnavailable) }
        let owned = await controller.retainedSession()
        XCTAssertNil(owned)
        let second = try await start(controller, context: value)
        let launches = await port.launches
        XCTAssertEqual(launches, 2)
        try await controller.stop(second)
    }
    func testConcurrentStartCannotOverwriteAnInputAttachmentInFlight() async throws {
        let value = try context(), port = StartupPort(stopFailures: 0), inputs = StartupInputs(blocked: true)
        let controller = RGSSGuestHostController(port: port, inputs: inputs, contexts: StartupContext(value: value))
        let first = Task { try await self.start(controller, context: value) }
        for _ in 0..<1000 { if await inputs.requested { break }; await Task.yield() }
        let requested = await inputs.requested
        XCTAssertTrue(requested)
        do { _ = try await start(controller, context: value); XCTFail("overlap") }
        catch { XCTAssertEqual(error as? RGSSGuestHostError, .staleSession) }
        await inputs.release()
        let session = try await first.value
        let launches = await port.launches
        XCTAssertEqual(launches, 1)
        try await controller.stop(session)
    }
    func testCancelledInputStartStillRetainsFailedCleanupForRetry() async throws {
        let value = try context(), port = StartupPort(stopFailures: 1), inputs = StartupInputs(blocked: true)
        let controller = RGSSGuestHostController(port: port, inputs: inputs, contexts: StartupContext(value: value))
        let task = Task { try await self.start(controller, context: value) }
        for _ in 0..<1000 { if await inputs.requested { break }; await Task.yield() }
        task.cancel()
        await inputs.release()
        do { _ = try await task.value; XCTFail("cancelled startup") }
        catch { XCTAssertTrue(error is RGSSGuestStartupCleanupError) }
        let owned = await controller.retainedSession()
        try await controller.stop(XCTUnwrap(owned))
        let after = await controller.retainedSession()
        XCTAssertNil(after)
    }
}
