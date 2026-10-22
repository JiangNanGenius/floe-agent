// FloeAndroidShellToolsTests — G03-R2 deletion-lifetime cohort
// (job-4d35db884ec64d95, coordinator steer 20261022).
//
// Focused, host-runnable proof of the ORIGINAL conversation-deletion fence's
// shell leg: a detached exec.shell whose dispatch already SETTLED (parent
// run timed out / went terminal) while its engine lease is unreconciled must
// (a) stay owned by the shell ledger with a REAL RuntimeOwnedWorkRegistry
// receipt, (b) receive only TARGET-ONLY cooperative stop requests, (c) end
// only when THIS run's release is actually proven — never on cancel,
// timeout, or EOF — and (d) admission must FAIL CLOSED when the ORIGINAL
// ToolContext lacks the exact conversation binding. No device, no network,
// no model calls.
import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidCore
import FloeAndroidShellTools

final class LinuxShellConversationDeletionTests: XCTestCase {

    private func makeBindings() -> (RuntimeFacadeLinuxBindings, FacadeToolWorkCoordinator,
                                    FakeLinuxShellTransport, URL) {
        let root = try! ShellTestRoot.make()
        let transport = FakeLinuxShellTransport()
        transport.releaseAfterCancel = false
        let bindings = RuntimeFacadeLinuxBindings()
        let coordinator = FacadeToolWorkCoordinator()
        // Same lane-only permission override as the bindings ledger tests:
        // REAL minted receipts, unchanged exact-token detach semantics.
        AndroidRuntimeBootstrap.ownedWorkAttachGateOverrideForTesting = { epoch in
            epoch == 0 ? .notInstalled : nil
        }
        return (bindings, coordinator, transport, root)
    }

    override func tearDown() {
        AndroidRuntimeBootstrap.ownedWorkAttachGateOverrideForTesting = nil
        RuntimeOwnedWorkRegistry.shared.removeAllForTesting()
        super.tearDown()
    }

    /// Retained settled shell work blocks ONLY its own conversation's drain.
    /// The engine legitimately owns ONE workload slot per backend (production
    /// admission bound, AndroidLinuxShellBackend), so the valid target-only
    /// proof retains real work for conversation A and asserts an UNRELATED
    /// conversation B (no shell work) drains immediately without touching
    /// A's token, receipt, or cooperative cancellation; then A's own tick
    /// refuses until the ACTUAL release proof ends the exact receipt.
    /// (Main steer 20261022: never two forbidden sessions on one backend;
    /// never global-count gating; never cancel==release.)
    func testRetainedShellWorkDrainsTargetOnlyAndEndsOnRealRelease() async throws {
        let (bindings, coordinator, transport, root) = makeBindings()
        let readiness = LinuxShellInjectedReadiness { true }
        _ = bindings.compose(transport: transport, coordinator: coordinator,
                             rootProvider: { root }, readiness: readiness,
                             journal: ShellOperationJournal(rootURL: root))
        // Authoritative dynamic bind: XCTest runs methods alphabetically, so a
        // fixed per-class epoch can collide with the shared mailbox's last
        // bound generation. Bind strictly above the CURRENT shared epoch.
        let epoch = LinuxShellMailbox.shared.snapshotForTesting().epoch + 1
        XCTAssertTrue(bindings.bindMailboxEpoch(epoch))
        // G03-R3: no wholesale-override setter exists (the allTrue seam was
        // removed). This suite exercises the ledger/deletion legs over the
        // INJECTED test readiness predicate; capability qualification is
        // covered by the R3 ingress regression instead.
        let components = try XCTUnwrap(bindings.components)

        let runA = UUID(); let convA = UUID()
        let convB = UUID() // unrelated conversation: legitimately NO shell work here
        let tokenA = CancellationToken()
        let contextA = ToolContext(runID: runA, toolCallID: "del-call-A",
                                   workspaceRootURL: root, cancellation: tokenA,
                                   conversationID: convA, clientSessionID: "run:main")
        // Foreground timeout against a busy engine: backend.run returns with
        // the lease UNRECONCILED; the settle closure runs, the ledger AND the
        // REAL registry receipt stay retained (timeout is not release).
        _ = await components.service.run(command: "sleep 300", cwd: ".", environment: [:],
                                         stdin: nil, timeout: 1, maxOutputBytes: nil,
                                         isBackground: false, context: contextA)
        XCTAssertEqual(transport.recordedStartCount, 1)
        let held = await shellWaitUntil(timeoutMillis: 2_000) {
            let a = await components.backend.ownedSessions(runID: runA)
            return !a.isEmpty
        }
        XCTAssertTrue(held)

        let tokensA = bindings.tokensForConversation(convA, epoch: epoch)
        let registry = RuntimeOwnedWorkRegistry.shared
        guard tokensA.count == 1 else {
            return XCTFail("the retained dispatch must own exactly one live receipt, "
                           + "got \(tokensA.count) (admission must have failed earlier)")
        }
        XCTAssertTrue(registry.isAttached(tokensA[0]))

        // The foreground timeout ALREADY requested the remote cooperative
        // stop through the production backend (AndroidLinuxShellBackend's
        // timeout branch: a stop REQUEST only, never proof of release).
        // That stop must stay on record (never removed) and target exactly
        // THIS run's engine session — the target-only leg of the proof.
        let timeoutStop = transport.recordedCancelCount
        XCTAssertEqual(timeoutStop, 1,
                       "the timed-out dispatch must have requested the remote cooperative stop once")
        let heldSessions = await components.backend.ownedSessions(runID: runA)
        let heldEngineA = try XCTUnwrap(heldSessions.first?.engineSessionID)
        XCTAssertEqual(transport.lastCancelSessionID, heldEngineA,
                       "the stop request targets exactly this run's engine session, never another's")

        // 1) UNRELATED conversation tick: immediately drained, and it must
        //    not touch A (this is the direct anti-global-count,
        //    anti-cross-conversation-cancellation proof). Compare against
        //    the BEFORE-B-TICK baseline: the invariant is NO ADDITIONAL
        //    cancellation from ticking convB, not a zero count that would
        //    contradict the retained timeout stop above.
        let bDrained = await bindings.drainConversationTick(conversationID: convB, epoch: epoch)
        XCTAssertTrue(bDrained, "a conversation without shell work is never blocked by A")
        XCTAssertTrue(registry.isAttached(tokensA[0]))
        XCTAssertFalse(tokenA.isCancelled, "ticking another conversation must not cancel A")
        XCTAssertEqual(transport.recordedCancelCount, timeoutStop,
                       "ticking an unrelated conversation must issue no cancellation of its own")
        XCTAssertEqual(bindings.tokensForConversation(convA, epoch: epoch).count, 1)

        // 2) A's own tick: NOT drained while the lease is unreconciled. The
        //    dispatch already settled and its remote stop was requested by
        //    the timeout (baseline above); the deletion fence must treat
        //    that stop as NEVER a release — the REAL receipt stays attached
        //    and the refusal stands. A settled target receives no duplicate
        //    stop (the production tick requests cooperative stops only for
        //    unsettled dispatches; the per-call token-chain routing of
        //    those stops is proven in ExecShellJobSettlementTests).
        let firstTick = await bindings.drainConversationTick(conversationID: convA, epoch: epoch)
        XCTAssertFalse(firstTick, "retained shell work must block its own conversation's deletion")
        XCTAssertTrue(registry.isAttached(tokensA[0]),
                      "cancel never counts as release: the receipt stays attached")
        XCTAssertEqual(transport.recordedCancelCount, timeoutStop,
                       "the fence tick adds no duplicate stop to the already-requested timeout stop")

        // 3) The trusted pump proves A's ACTUAL release; the next tick ends
        //    exactly A with the exact-token detach, once.
        let engineAID = heldEngineA
        transport.markReleased(engineAID)
        let drained = await shellWaitUntil(timeoutMillis: 4_000) {
            await bindings.drainConversationTick(conversationID: convA, epoch: epoch)
        }
        XCTAssertTrue(drained, "settled + proven-released target ends on the tick")
        XCTAssertFalse(registry.isAttached(tokensA[0]),
                       "the receipt is detached ONLY at real release, exactly once")
        XCTAssertTrue(bindings.tokensForConversation(convA, epoch: epoch).isEmpty)
        let retired = await bindings.drainLinuxShell(timeoutMillis: 1_000)
        XCTAssertTrue(retired, "process retirement may complete only now that the target released")
        let attached = await coordinator.snapshotCountsForTesting()
        XCTAssertEqual(attached, 0)
    }

    /// Admission fails closed WITHOUT the original conversation binding:
    /// nothing dispatches, nothing attaches, no workspace is guessed.
    func testDispatchWithoutConversationBindingFailsClosedAtAdmission() async throws {
        let (bindings, coordinator, transport, root) = makeBindings()
        let readiness = LinuxShellInjectedReadiness { true }
        _ = bindings.compose(transport: transport, coordinator: coordinator,
                             rootProvider: { root }, readiness: readiness,
                             journal: ShellOperationJournal(rootURL: root))
        let epoch = LinuxShellMailbox.shared.snapshotForTesting().epoch + 1
        XCTAssertTrue(bindings.bindMailboxEpoch(epoch))
        // G03-R3: no wholesale-override setter exists (the allTrue seam was
        // removed). This suite exercises the ledger/deletion legs over the
        // INJECTED test readiness predicate; capability qualification is
        // covered by the R3 ingress regression instead.
        let components = try XCTUnwrap(bindings.components)

        let context = ToolContext(runID: UUID(), toolCallID: "unbound-call",
                                  workspaceRootURL: root, cancellation: CancellationToken(),
                                  clientSessionID: "run:main")   // NO conversationID
        let result = await components.service.run(command: "echo x", cwd: ".", environment: [:],
                                                  stdin: nil, timeout: 1, maxOutputBytes: nil,
                                                  isBackground: false, context: context)
        guard case .outcome(.failed(let message)) = result else {
            return XCTFail("unbound dispatch must refuse honestly, got \(result)")
        }
        XCTAssertTrue(message.contains("Nothing was executed"))
        XCTAssertEqual(transport.recordedStartCount, 0)
        let attached = await coordinator.snapshotCountsForTesting()
        XCTAssertEqual(attached, 0)
        let tokens = bindings.tokensForConversation(UUID(), epoch: epoch)
        XCTAssertTrue(tokens.isEmpty)
    }
}
