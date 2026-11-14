// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools

final class LinuxShellReconciliationRetryTests: XCTestCase {
    func testTransientReconciliationFailureCanStillConsumeRealReleaseReceipt() async throws {
        let root = try ShellTestRoot.make()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let transport = RetryReceiptTransport(releasesAfterFaults: true)
        let backend = makeBackend(transport)
        let outcome = await backend.run(request(root), cancellation: nil)
        guard case .failed = outcome else { return XCTFail("Original failed wait must stay failed") }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if await backend.ownedSessions().isEmpty { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let owned = await backend.ownedSessions()
        let polls = await transport.polls
        XCTAssertTrue(owned.isEmpty, "A later exact engine receipt must retire the retained lease")
        XCTAssertGreaterThanOrEqual(polls, 3, "Both the failed wait and failed reconciliation precede the receipt")
    }

    func testRepeatedFailedReadsNeverManufactureLeaseReleaseAtObservationDeadline() async throws {
        let root = try ShellTestRoot.make()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let transport = RetryReceiptTransport(releasesAfterFaults: false)
        let backend = makeBackend(transport, observation: 0.04)
        let outcome = await backend.run(request(root), cancellation: nil)
        guard case .failed = outcome else { return XCTFail("Unknown engine outcome must stay failed") }
        try await Task.sleep(nanoseconds: 100_000_000)
        let owned = await backend.ownedSessions()
        let polls = await transport.polls
        XCTAssertEqual(owned.count, 1, "Read errors and elapsed time cannot prove a remote stop")
        XCTAssertFalse(try XCTUnwrap(owned.first).leaseReleased)
        XCTAssertGreaterThanOrEqual(polls, 2)
    }

    private func makeBackend(_ transport: RetryReceiptTransport, observation: TimeInterval = 1) -> AndroidLinuxShellBackend {
        AndroidLinuxShellBackend(
            transport: transport, readiness: StaticLinuxShellReadiness(qualified: true),
            configuration: .init(pollIntervalNanos: 1_000_000, releaseGrace: 0.05,
                                 reconcileIntervalNanos: 5_000_000, reconcileObservation: observation))
    }

    private func request(_ root: URL) -> ShellRunRequest {
        ShellRunRequest(command: "printf test", cwd: ".", rootURL: root,
                        environment: [:], timeout: 1, gateTimeout: 0.5,
                        maxOutputBytes: 4096, sessionID: "reconcile-test", runID: UUID(),
                        toolEnvironment: nil, conversationID: UUID())
    }
}

private actor RetryReceiptTransport: LinuxShellTransport {
    let base = FakeLinuxShellTransport()
    let releasesAfterFaults: Bool
    private(set) var polls = 0

    init(releasesAfterFaults: Bool) { self.releasesAfterFaults = releasesAfterFaults }

    func shellStart(_ request: LinuxShellStartRequest) async throws -> LinuxShellStartReply {
        try await base.shellStart(request)
    }

    func shellPoll(_ request: LinuxShellPollRequest) async throws -> LinuxShellPollReply {
        polls += 1
        if polls <= 2 || !releasesAfterFaults { throw LinuxShellTransportError.waitBudgetExpired }
        return FakeLinuxShellTransport.page(session: request.sessionID, cursor: request.cursor,
                                           text: "", state: .terminated, released: true, exit: 0)
    }

    func shellInput(_ request: LinuxShellInputRequest) async throws -> LinuxShellInputReply {
        try await base.shellInput(request)
    }
    func shellResize(_ request: LinuxShellResizeRequest) async throws -> LinuxShellResizeReply {
        try await base.shellResize(request)
    }
    func shellCancel(_ request: LinuxShellCancelRequest) async throws -> LinuxShellCancelReply {
        try await base.shellCancel(request)
    }
}
