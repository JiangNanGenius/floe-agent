// SPDX-License-Identifier: MPL-2.0
// Focused regression for the OPTIONAL bounded recovery evidence inside the
// reconciled engine-terminal section (job-5b987a08b1df40b2). Author-written
// against the 951f2f68/bacbaf91 baseline for the FloeAndroidJobToolsTests
// suite; reuses the existing JobTestSupport scripted gate. NOT executed by
// this lane (Main owns the Swift 6 object compile).
import XCTest
import Foundation
import FloeTools
@testable import FloeAndroidJobTools
@testable import FloeAndroidShellTools

final class ExecShellRecoveryDetailTests: XCTestCase {
    private func parsedRecovery(preserved: Bool) -> LinuxShellWorkspaceRecovery? {
        let key = String(repeating: "b", count: 32)
        let d64 = String(repeating: "c", count: 64)
        let text = preserved
            ? """
              {"sessionKey":"\(key)",
               "import":{"outcome":"swappedPreserved","created":0,"replacedSynced":1,"preservedUnsynced":1,
                         "unchanged":0,"appliedBytes":57,
                         "preserved":[{"path":"r3cas/marker.txt","action":"swappedPreserved",
                           "preservedSha256":"\(d64)","preservedBytes":30,
                           "installedBaselineSha256":"\(d64)","installedBaselineBytes":27}]},
               "export":{"result":"aborted","source":"core-export-finish"}}
              """
            : """
              {"sessionKey":"\(key)",
               "import":{"outcome":"clean","created":1,"replacedSynced":0,"preservedUnsynced":0,
                         "unchanged":0,"appliedBytes":4},
               "export":{"failureCode":"budgetExceeded","stagedPreserved":true}}
              """
        let data = text.data(using: .utf8)!
        return LinuxShellWorkspaceRecovery.parse(try! JSONSerialization.jsonObject(with: data))
    }

    /// The reconciled terminal section gains the bounded evidence block when
    /// the engine proved a preservation (never for a nil legacy proof).
    func testReconciledReleaseWithRecoveryShowsBoundedEvidence() async throws {
        let root = try JobTestRoot.make()
        let recovery = try XCTUnwrap(parsedRecovery(preserved: true))
        let gate = ScriptedJobGate(answers: [
            .released(sessionID: "lease-1", cancelled: false, stopReason: nil,
                      exitCode: 0, termSig: nil, waitErrno: nil,
                      workspaceStatus: "aborted", workspaceRecoveryRef: recovery.sessionKey,
                      recovery: recovery),
        ])
        let index = JobLiveWorkIndex()
        let (transport, _, runner) = makeExecShellRunner(root: root, gate: gate, index: index)
        transport.startError = LinuxShellTransportError.waitBudgetExpired
        let output = try await runner.run(jobPayload(), jobContext(
            runID: UUID(), jobID: UUID(), root: root, cancellation: CancellationToken()))
        XCTAssertTrue(output.summary.contains("workspace=aborted"), output.summary)
        XCTAssertTrue(output.summary.contains("recovery-evidence session="), output.summary)
        XCTAssertTrue(output.summary.contains("r3cas/marker.txt"), output.summary)
        XCTAssertFalse(output.summary.contains("/data/"), "no host paths in tool detail")
    }

    /// A legacy terminal proof (no OPTIONAL metadata) keeps the section
    /// byte-compatible: same fields, no evidence block.
    func testReconciledReleaseWithoutRecoveryStaysLegacy() async throws {
        let root = try JobTestRoot.make()
        let gate = ScriptedJobGate(answers: [
            .released(sessionID: "lease-1", cancelled: false, stopReason: nil,
                      exitCode: 0, termSig: nil, waitErrno: nil, workspaceStatus: "synced"),
        ])
        let index = JobLiveWorkIndex()
        let (transport, _, runner) = makeExecShellRunner(root: root, gate: gate, index: index)
        transport.startError = LinuxShellTransportError.waitBudgetExpired
        let output = try await runner.run(jobPayload(), jobContext(
            runID: UUID(), jobID: UUID(), root: root, cancellation: CancellationToken()))
        XCTAssertTrue(output.summary.contains("status=reconciledExit"), output.summary)
        XCTAssertFalse(output.summary.contains("recovery-evidence"),
                       "absent metadata must never fabricate a block")
    }

    /// A budgetExceeded pre-apply abort is shown with its ORIGINAL typed
    /// failure token and NO false "both revisions" claim (no preserved list).
    func testPreapplyAbortIsTypedNotRollbackOfAppliedChanges() async throws {
        let root = try JobTestRoot.make()
        let recovery = try XCTUnwrap(parsedRecovery(preserved: false))
        let gate = ScriptedJobGate(answers: [
            .released(sessionID: "lease-1", cancelled: false, stopReason: nil,
                      exitCode: 0, termSig: nil, waitErrno: nil,
                      workspaceStatus: "error", workspaceRecoveryRef: recovery.sessionKey,
                      recovery: recovery),
        ])
        let index = JobLiveWorkIndex()
        let (transport, _, runner) = makeExecShellRunner(root: root, gate: gate, index: index)
        transport.startError = LinuxShellTransportError.waitBudgetExpired
        let output = try await runner.run(jobPayload(), jobContext(
            runID: UUID(), jobID: UUID(), root: root, cancellation: CancellationToken()))
        XCTAssertTrue(output.summary.contains("failure=budgetExceeded"), output.summary)
        XCTAssertFalse(output.summary.contains("preserved:"), "no preserved copies existed to claim")
    }
}
