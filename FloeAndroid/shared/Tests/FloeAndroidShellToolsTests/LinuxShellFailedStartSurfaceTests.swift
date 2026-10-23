// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused suite: the ordinary exec.shell FAILURE surface for
// the G03-R3 failed-start receipt handoff (job-150dee8e1ed14ba1). The
// engine-side binding already happened in the trusted host pump; this pins
// ONLY the consumer rule: the concise first line stays byte-identical to
// the legacy `.remoteFailed(code:)` sentence, the bounded technical
// evidence rides BELOW it as the existing explicit tool-failure detail,
// and a legacy failure renders EXACTLY the old message (no fabricated
// evidence, no gate leak). All interaction rides the synthetic
// FakeLinuxShellTransport; nothing executes. NOT run by the authoring job.
import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools

final class LinuxShellFailedStartSurfaceTests: XCTestCase {

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
                        sessionID: "run:unit-test:failed-start",
                        runID: UUID(), toolEnvironment: nil,
                        conversationID: nil)
    }

    private let restore = LinuxShellImportRestore(
        failureCode: "importCancelled",
        sessionKey: String(repeating: "ab", count: 16),
        runID: "A1B2C3D4-0000-4000-9000-000000000004",
        trigger: "cancelRequested",
        restoredPriorChanges: 3, revertedNewEntries: 1, retainedFailures: 0)

    func testLegacyRemoteFailedMessageStaysByteIdentical() async throws {
        let root = try ShellTestRoot.make()
        let transport = FakeLinuxShellTransport()
        transport.startError = LinuxShellTransportError.remoteFailed(code: "runtime_start_stopped")
        let backend = makeBackend(transport)
        let outcome = await backend.run(runRequest(root: root), cancellation: nil)
        guard case .failed(let message) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertEqual(message, "engine reported the request failed (code=runtime_start_stopped)")
        let busy = await backend.isEngineSlotBusy()
        XCTAssertFalse(busy, "a refused start must not keep the gate")
    }

    func testTypedFailedStartEvidenceAppendsBoundedDetailBelowUnchangedFirstLine() async throws {
        let root = try ShellTestRoot.make()
        let transport = FakeLinuxShellTransport()
        transport.startError = LinuxShellTransportError.remoteFailedWithRestore(
            code: "runtime_start_stopped", restore: restore)
        let backend = makeBackend(transport)
        let outcome = await backend.run(runRequest(root: root), cancellation: nil)
        guard case .failed(let message) = outcome else {
            return XCTFail("expected failed, got \(outcome)")
        }
        let lines = message.components(separatedBy: "\n")
        // The concise legacy sentence keeps the FIRST line untouched — the
        // ordinary failure copy does not change when evidence is absent, and
        // the technical evidence only ever rides below it.
        XCTAssertEqual(lines.first, "engine reported the request failed (code=runtime_start_stopped)")
        XCTAssertTrue(message.contains("failed-start-recovery session="))
        XCTAssertTrue(message.contains("restoredPriorChanges=3"))
        XCTAssertTrue(message.contains("revertedNewEntries=1"))
        XCTAssertTrue(message.contains("retainedFailures=0"))
        // Only relative identities and bounded counters: no host paths.
        XCTAssertFalse(message.contains("/private"))
        XCTAssertFalse(message.contains("echo test"))
        let busy = await backend.isEngineSlotBusy()
        XCTAssertFalse(busy, "the typed evidence must not change gate ownership")
    }

    func testInteractiveMapBackendErrorCarriesEvidenceDetail() async throws {
        // openSession routes the SAME typed description through
        // FloeError.invalidConfiguration (mapBackendError): the first line
        // stays the existing sentence and the detail rides below it.
        let root = try ShellTestRoot.make()
        let transport = FakeLinuxShellTransport()
        transport.startError = LinuxShellTransportError.remoteFailedWithRestore(
            code: "runtime_start_interrupted", restore: restore)
        let backend = makeBackend(transport)
        do {
            _ = try await backend.openSession(
                ShellOpenRequest(cwd: ".", rootURL: root, sessionID: "sess-failed-start",
                                 runID: UUID()),
                cancellation: nil)
            XCTFail("expected the typed failed start to surface")
        } catch let floe as FloeError {
            let described: String
            if case .invalidConfiguration(let text) = floe { described = text }
            else { return XCTFail("expected invalidConfiguration, got \(floe)") }
            XCTAssertTrue(described.hasPrefix("engine reported the request failed (code=runtime_start_interrupted)"))
            XCTAssertTrue(described.contains("failed-start-recovery session="))
        }
    }
}
