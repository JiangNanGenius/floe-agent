// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools

final class LinuxShellTimeoutReasonTests: XCTestCase {
    func testLocalDeadlineCarriesTimeoutCauseAndWaitsForEngineProof() async throws {
        let (outcome, transport) = try await run(timeout: 0.05, engineReason: "timeout")
        XCTAssertGreaterThan(transport.recordedCancelCount, 0)
        XCTAssertEqual(transport.lastCancelReason, .timeout)
        guard case .timedOut = outcome else {
            return XCTFail("A proven engine timeout must remain timeout: \(outcome)")
        }
    }

    func testEngineUserStopIsNotRewrittenFromTheLocalDeadline() async throws {
        let (outcome, transport) = try await run(timeout: 0.05, engineReason: "user-stop")
        XCTAssertGreaterThan(transport.recordedCancelCount, 0)
        XCTAssertEqual(transport.lastCancelReason, .timeout)
        XCTAssertEqual(outcome, .cancelled, "The actual engine receipt outranks the caller's intent")
    }

    func testOrdinaryCallerCancellationKeepsLegacyUserStopRequest() async throws {
        let token = CancellationToken()
        let (outcome, transport) = try await run(timeout: 5, engineReason: "user-stop", token: token)
        XCTAssertGreaterThan(transport.recordedCancelCount, 0)
        XCTAssertNil(transport.lastCancelReason)
        XCTAssertEqual(outcome, .cancelled)
    }

    private func run(
        timeout: TimeInterval, engineReason: String, token: CancellationToken? = nil
    ) async throws -> (ShellRunOutcome, FakeLinuxShellTransport) {
        let root = try ShellTestRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = FakeLinuxShellTransport()
        transport.cancelledStopReason = engineReason
        if let token {
            transport.pollScript = { _, _, nth in
                if nth == 1 { token.cancel() }
                return nil
            }
        }
        let backend = AndroidLinuxShellBackend(
            transport: transport,
            readiness: StaticLinuxShellReadiness(qualified: true),
            configuration: .init(pollIntervalNanos: 1_000_000, releaseGrace: 0.2)
        )
        let request = ShellRunRequest(
            command: "sleep 12", cwd: ".", rootURL: root, timeout: timeout,
            sessionID: "timeout-fixture", runID: UUID(), conversationID: UUID()
        )
        let outcome = await backend.run(request, cancellation: token)
        return (outcome, transport)
    }
}
