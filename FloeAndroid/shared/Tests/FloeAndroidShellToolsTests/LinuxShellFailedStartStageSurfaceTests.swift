// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused suite for the N02 A5 Samsung environmentTransaction
// start failure (job-46036bc8e99f4602): the typed transaction-stage token
// (bounded closed-vocabulary stage, optional numeric errno, optional bounded
// divergence axis) rides the SAME failed-start channel as the G03-R3
// restore evidence. This pins ONLY the consumer rule: the concise first
// line stays byte-identical to the legacy `.remoteFailed(code:)` sentence,
// the bounded technical evidence rides BELOW it as the existing explicit
// tool-failure detail, and a legacy failure renders EXACTLY the old message
// (no fabricated evidence, no gate leak). All interaction rides the
// synthetic FakeLinuxShellTransport; nothing executes. NOT run by the
// authoring job.
import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools

final class LinuxShellFailedStartStageSurfaceTests: XCTestCase {

    func testLongestProducedStageSurvivesTheRealParser() throws {
        let failure = try XCTUnwrap(LinuxShellStartFailure.parse(
            stage: "transaction_snapshot_verify_changed",
            errno: NSNumber(value: 28), detail: "modified"))
        XCTAssertEqual(failure.stage, "transaction_snapshot_verify_changed")
        XCTAssertEqual(failure.errno, 28)
        XCTAssertEqual(failure.detail, "modified")
    }

    func testMalformedDiagnosticCannotReplaceTheLegacyFailure() {
        XCTAssertNil(LinuxShellStartFailure.parse(stage: "/private/synthetic", errno: nil, detail: nil))
        XCTAssertNil(LinuxShellStartFailure.parse(stage: String(repeating: "x", count: 33), errno: nil, detail: nil))
        XCTAssertNil(LinuxShellStartFailure.parse(stage: "transaction_image_io", errno: nil, detail: String(repeating: "x", count: 33)))
        XCTAssertNil(LinuxShellStartFailure.parse(stage: "transaction_image_io", errno: NSNumber(value: true), detail: nil))
        XCTAssertNil(LinuxShellStartFailure.parse(stage: "transaction_image_io", errno: "28", detail: nil))
        XCTAssertNil(LinuxShellStartFailure.parse(stage: "transaction_image_io", errno: NSNumber(value: 1.5), detail: nil))
        XCTAssertNil(LinuxShellStartFailure.parse(stage: "transaction_image_io", errno: NSNumber(value: 4096), detail: nil))
    }

    func testAbsentOptionalEvidenceStaysAbsentAndDetailIsBounded() throws {
        let failure = try XCTUnwrap(LinuxShellStartFailure.parse(
            stage: "transaction_image_io", errno: nil, detail: nil))
        XCTAssertNil(failure.errno)
        XCTAssertNil(failure.detail)
        XCTAssertNil(LinuxShellStartFailure.parse(
            stage: "transaction_image_io", errno: nil, detail: "/private/synthetic"))
        XCTAssertNil(LinuxShellStartFailure.parse(
            stage: String(repeating: "a", count: 65), errno: nil, detail: nil))
    }

    private func makeBackend(_ transport: FakeLinuxShellTransport) -> AndroidLinuxShellBackend {
        AndroidLinuxShellBackend(
            transport: transport,
            readiness: StaticLinuxShellReadiness(qualified: true),
            configuration: AndroidLinuxShellBackend.Configuration(
                pollIntervalNanos: 1_000_000,
                releaseGrace: 0.2,
                stdinWriteRetries: 8,
                reconcileIntervalNanos: 5_000_000,
                reconcileObservation: 30))
    }

    private func runRequest(root: URL) -> ShellRunRequest {
        ShellRunRequest(command: "echo test", cwd: ".", rootURL: root,
                        environment: [:], stdin: nil,
                        timeout: 1, gateTimeout: 0.5,
                        maxOutputBytes: 64 * 1024,
                        sessionID: "run:unit-test:failed-start-stage",
                        runID: UUID(), toolEnvironment: nil,
                        conversationID: nil)
    }

    func testTypedTransactionStageKeepsLegacyFirstLineAndAppendsBoundedDetail() async throws {
        let root = try ShellTestRoot.make()
        let transport = FakeLinuxShellTransport()
        transport.startError = LinuxShellTransportError.remoteFailedWithStartFailure(
            code: "runtime_start_failed",
            stage: "transaction_snapshot_verify_changed",
            errno: 28, detail: "modified")
        let backend = makeBackend(transport)
        let outcome = await backend.run(runRequest(root: root), cancellation: nil)
        guard case .failed(let message) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        let lines = message.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "engine reported the request failed (code=runtime_start_failed)")
        XCTAssertTrue(message.contains("start-failure stage=transaction_snapshot_verify_changed"))
        XCTAssertTrue(message.contains("errno=28"))
        XCTAssertTrue(message.contains("detail=modified"))
        // Only closed tokens and bounded numbers: no host paths or commands.
        XCTAssertFalse(message.contains("/private"))
        XCTAssertFalse(message.contains("echo test"))
        let busy = await backend.isEngineSlotBusy()
        XCTAssertFalse(busy, "the typed stage evidence must not change gate ownership")
    }

    func testStageWithoutErrnoOrDetailOmitsThoseFields() async throws {
        let root = try ShellTestRoot.make()
        let transport = FakeLinuxShellTransport()
        transport.startError = LinuxShellTransportError.remoteFailedWithStartFailure(
            code: "runtime_start_failed",
            stage: "transaction_journal_present",
            errno: nil, detail: nil)
        let backend = makeBackend(transport)
        let outcome = await backend.run(runRequest(root: root), cancellation: nil)
        guard case .failed(let message) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertTrue(message.hasPrefix(
            "engine reported the request failed (code=runtime_start_failed)\nstart-failure stage=transaction_journal_present"))
        XCTAssertFalse(message.contains("errno="))
        XCTAssertFalse(message.contains("detail="))
    }
}
