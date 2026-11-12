// SPDX-License-Identifier: MPL-2.0
//
// Author-written (NOT executed by this source stage) regressions for the
// post112 FS01/FS12 owner/lease life cycle. A live shell session whose
// transport read failed may be retained for reconciliation, but it must not
// stay a live owner forever after the runtime PROCESS was replaced. The only
// accepted proof is the engine's measured boot token changing; a same-token
// failure keeps the original retention (no timer/error-string release).
import XCTest
@testable import FloeAndroidShellTools

final class LinuxShellGenerationRetirementTests: XCTestCase {

    private func makeBackend(
        pollError: Error,
        status: LinuxShellRuntimeStatus?
    ) -> (AndroidLinuxShellBackend, FakeLinuxShellTransport) {
        let transport = FakeLinuxShellTransport()
        transport.startReply = { request in
            LinuxShellStartReply(sessionID: "engine-owner",
                                 environmentID: request.environmentID ?? "env",
                                 runtimeGeneration: "boot-1",
                                 workspaceOwner: true)
        }
        transport.pollError = pollError
        transport.runtimeStatus = status
        return (AndroidLinuxShellBackend(
            transport: transport,
            readiness: StaticLinuxShellReadiness(qualified: true)), transport)
    }

    /// Wait until the scheduleReconciliation task has made its actual poll
    /// attempt and had time to resolve the status/recovery proof. This is a
    /// test synchronization only; the production decision has no timer.
    private func awaitReconciliationAttempt(_ transport: FakeLinuxShellTransport) async {
        _ = await shellWaitUntil { await Task.yield(); return transport.recordedPollCount >= 2 }
        try? await Task.sleep(nanoseconds: 120_000_000)
    }

    private func open(_ backend: AndroidLinuxShellBackend, workspace: URL) async throws {
        _ = try await backend.openSession(ShellOpenRequest(
            command: "", cwd: ".", rootURL: workspace, environment: [:],
            columns: 80, rows: 24, gateTimeout: 1,
            sessionID: "session-owner", runID: UUID(), toolEnvironment: nil,
            conversationID: UUID(), prepareLinuxIfMissing: false,
            leaseRole: .interactive), cancellation: nil)
    }

    /// A different measured boot token PLUS the successor's real whole-UID
    /// recovery proof retires the old local owner. NO terminal/workspace
    /// success is fabricated: the record stays visible as unreconciled with
    /// leaseReleased == false.
    func testDifferentRuntimeGenerationRetiresLocalOwnerWithoutFakeRelease() async throws {
        let workspace = try ShellTestRoot.make()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (backend, transport) = makeBackend(
            pollError: LinuxShellTransportError.remoteFailed(code: "runtime_unavailable"),
            status: LinuxShellRuntimeStatus(runtimeBootToken: "boot-2", active: true,
                                            runtimeRecoveryProven: true))

        do {
            try await open(backend, workspace: workspace)
            XCTFail("the failed initial drain must surface the transport failure")
        } catch {
            // Expected: the start was already admitted; the poll failed.
        }
        await awaitReconciliationAttempt(transport)
        let retired = await shellWaitUntil {
            (await backend.ownedSessions()).isEmpty
        }
        XCTAssertTrue(retired, "a proven new runtime generation releases the local owner slot")
        let unreconciled = await backend.unreconciledSessions()
        let record = try XCTUnwrap(unreconciled.first)
        XCTAssertTrue(record.generationRetired)
        XCTAssertFalse(record.leaseReleased, "retirement is not a fabricated lease release")
        XCTAssertEqual("boot-1", record.runtimeGeneration ?? "")
    }

    /// A changed boot token is NOT quiescence proof by itself. While the
    /// successor process has not completed its original whole-UID recovery/
    /// census, the old lease/foreground ownership and ledger record stay
    /// retained. This is the causal boundary Main's review requires.
    func testChangedGenerationWithoutSuccessorRecoveryRetainsOwnership() async throws {
        let workspace = try ShellTestRoot.make()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (backend, transport) = makeBackend(
            pollError: LinuxShellTransportError.remoteFailed(code: "runtime_unavailable"),
            status: LinuxShellRuntimeStatus(runtimeBootToken: "boot-2", active: true,
                                            runtimeRecoveryProven: false))

        do {
            try await open(backend, workspace: workspace)
            XCTFail("the failed initial drain must surface the transport failure")
        } catch {
            // Expected.
        }
        await awaitReconciliationAttempt(transport)
        let retained = await shellWaitUntil {
            !(await backend.unreconciledSessions()).isEmpty
        }
        XCTAssertTrue(retained)
        let owned = await backend.ownedSessions()
        XCTAssertEqual(["engine-owner"], owned.map(\.engineSessionID))
        XCTAssertFalse(owned[0].leaseReleased)
        XCTAssertFalse(owned[0].generationRetired)
        let unreconciled = await backend.unreconciledSessions()
        XCTAssertFalse(unreconciled.contains { $0.generationRetired })

        // The SAME captured record becomes retirable only when the successor
        // reports its real recovery/census proof. This is the public
        // drain/ledger proof pass, not a timer.
        transport.runtimeStatus = LinuxShellRuntimeStatus(
            runtimeBootToken: "boot-2", active: true, runtimeRecoveryProven: true)
        let retiredNow = await backend.retireFencedSessionsIfRuntimeGenerationChanged()
        XCTAssertEqual(1, retiredNow)
        let afterProof = await backend.ownedSessions()
        XCTAssertTrue(afterProof.isEmpty, "actual successor recovery permits retirement")
        let proofRecord = await backend.unreconciledSessions().first { $0.generationRetired }
        XCTAssertNotNil(proofRecord)
        XCTAssertFalse(proofRecord?.leaseReleased ?? true)
    }

    /// The same measured generation (or an unavailable status) never proves a
    /// release: the original reconciliation retention stays exactly as before.
    func testSameRuntimeGenerationKeepsTheOwnerForReconciliation() async throws {
        let workspace = try ShellTestRoot.make()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let (backend, transport) = makeBackend(
            pollError: LinuxShellTransportError.remoteFailed(code: "runtime_unavailable"),
            status: LinuxShellRuntimeStatus(runtimeBootToken: "boot-1", active: true,
                                            runtimeRecoveryProven: true))

        do {
            try await open(backend, workspace: workspace)
            XCTFail("the failed initial drain must surface the transport failure")
        } catch {
            // Expected.
        }
        await awaitReconciliationAttempt(transport)
        let reconciling = await shellWaitUntil {
            !(await backend.unreconciledSessions()).isEmpty
        }
        XCTAssertTrue(reconciling, "the same generation keeps the real reconciliation record")
        let owned = await backend.ownedSessions()
        XCTAssertEqual(["engine-owner"], owned.map(\.engineSessionID))
        XCTAssertFalse(owned[0].leaseReleased)
        XCTAssertFalse(owned[0].generationRetired)
    }
}
