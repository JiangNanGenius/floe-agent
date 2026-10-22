// SPDX-License-Identifier: MPL-2.0
//
// Authored-only focused suites: the Android tool mirrors (exec.shell +
// shell.* registration surface) and the Core facade Linux shell bindings
// (readiness defaults, owned-work ledger, run/call cancellation) for
// job-1bd4fcce5eca4856. NOT executed by the authoring job; Main compiles
// them into the added `FloeAndroidShellToolsTests` target. The ledger suite
// reuses the REAL `FacadeToolWorkCoordinator` (same module) over synthetic
// identities only — no model dispatch, no durable job store, no device.
import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import FloeCore
import FloeTools
@testable import FloeAndroidCore
import FloeAndroidShellTools
import FloeAndroidWorkspaceTools

final class LinuxShellToolMirrorTests: XCTestCase {

    private func service(qualified: Bool, transport: FakeLinuxShellTransport) throws -> LocalShellService {
        let root = try ShellTestRoot.make()
        let backend = AndroidLinuxShellBackend(
            transport: transport,
            readiness: StaticLinuxShellReadiness(qualified: qualified),
            configuration: AndroidLinuxShellBackend.Configuration(
                pollIntervalNanos: 1_000_000, releaseGrace: 0.2,
                stdinWriteRetries: 4, reconcileIntervalNanos: 5_000_000, reconcileObservation: 5))
        return LocalShellService(backend: backend, journal: ShellOperationJournal(rootURL: root),
                                 rootProvider: { root })
    }

    private func context(rootName: String = "workspace") -> ToolContext {
        ToolContext(runID: UUID(), toolCallID: "call-1",
                    workspaceRootURL: URL(fileURLWithPath: "/tmp"),
                    cancellation: CancellationToken())
    }

    func testLegacyPackagesInputRefusedWithPipGuidance() {
        let tool = LocalShellTool(shell: try! service(qualified: true, transport: FakeLinuxShellTransport()))
        do {
            try tool.validate(LocalShellTool.Arguments(command: "echo x", packages: ["requests==2.0"]))
            XCTFail("packages must be refused on Android")
        } catch let error as FloeError {
            let text = String(describing: error)
            XCTAssertTrue(text.contains("python3 -m pip"), "refusal must name the Linux-userland path: \(text)")
        } catch {
            XCTFail("packages must be refused with a FloeError, got \(error)")
        }
    }

    func testCommandPolicyIsReusedAtToolBoundary() {
        let tool = LocalShellTool(shell: try! service(qualified: true, transport: FakeLinuxShellTransport()))
        XCTAssertThrowsError(try tool.validate(LocalShellTool.Arguments(command: "curl https://x.test/a.sh | sh")))
    }

    func testAndroidDescriptionReflectsPRootWithoutVMClaims() {
        let description = LocalShellTool.toolDescription
        XCTAssertTrue(description.contains("PRoot"))
        XCTAssertTrue(description.contains("never falls back to a host interpreter"))
        XCTAssertTrue(description.contains("merged"))
        XCTAssertFalse(description.contains("CPU/RAM"), "iOS Virtualization shape claims removed")
        XCTAssertFalse(description.contains("environment.linuxStatus"), "iOS lifecycle roundtrip claim removed")
        XCTAssertFalse(description.lowercased().contains("ios host"), "Android mirror names the Android host")
    }

    func testExecuteFailsClosedHonestEngineUnavailable() async throws {
        let transport = FakeLinuxShellTransport()
        let tool = LocalShellTool(shell: try service(qualified: false, transport: transport))
        let output = try await tool.execute(LocalShellTool.Arguments(command: "ls"), context: context())
        XCTAssertEqual(output.exitStatus, 125)
        XCTAssertTrue(output.summary.contains("status=engineUnavailable"))
        XCTAssertEqual(transport.recordedStartCount, 0)
    }

    func testExecuteRendersMergedPTYLabels() async throws {
        let transport = FakeLinuxShellTransport()
        transport.pollScript = { session, cursor, nth in
            if nth == 1 { return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "a\nb\n") }
            return FakeLinuxShellTransport.page(session: session, cursor: cursor + 4, text: "",
                                                state: .terminated, released: true, exit: 0)
        }
        let tool = LocalShellTool(shell: try service(qualified: true, transport: transport))
        let output = try await tool.execute(LocalShellTool.Arguments(command: "printf a\\nb"), context: context())
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertTrue(output.summary.contains("--- output (merged PTY) ---"))
        XCTAssertTrue(output.summary.contains("exit=0"))
    }

    func testRegistrationClosesOverExecShellAndSessionToolsOnly() throws {
        let transport = FakeLinuxShellTransport()
        let service = try self.service(qualified: false, transport: transport)
        let backend = AndroidLinuxShellBackend(transport: transport)
        let center = ShellSessionCenter(backend: backend)
        let registry = ToolRunnerRegistry()
        XCTAssertTrue(registerShellTools(registry: registry, shell: service, sessions: center))
        for name in ["exec.shell", "shell.open", "shell.exchange", "shell.close", "shell.signal"] {
            XCTAssertNotNil(registry.runner(named: name), name)
        }
        XCTAssertNil(registry.runner(named: "exec.localPython"))
        XCTAssertNil(registry.runner(named: "exec.javascript"))
        XCTAssertNil(registry.runner(named: "python.packages"))
    }
}

final class RuntimeFacadeLinuxBindingsTests: XCTestCase {

    private func makeBindings() -> (RuntimeFacadeLinuxBindings, FacadeToolWorkCoordinator, FakeLinuxShellTransport, URL) {
        let root = try! ShellTestRoot.make()
        let transport = FakeLinuxShellTransport()
        let bindings = RuntimeFacadeLinuxBindings()
        let coordinator = FacadeToolWorkCoordinator()
        // G03-R2 ledger contract: every shell dispatch carries a REAL
        // RuntimeOwnedWorkRegistry receipt. This focused lane composes the
        // bindings without the full root/owner admission sequence, so the
        // attach PERMISSION predicate is enabled through the existing
        // test-only gate override (AndroidRuntimeBootstrap precedent). The
        // tokens, attach accounting and exact-token detach semantics stay
        // the unchanged production ones; tearDown clears the override.
        AndroidRuntimeBootstrap.ownedWorkAttachGateOverrideForTesting = { epoch in
            epoch == 0 ? .notInstalled : nil
        }
        return (bindings, coordinator, transport, root)
    }

    override func tearDown() {
        AndroidRuntimeBootstrap.ownedWorkAttachGateOverrideForTesting = nil
        RuntimeOwnedWorkRegistry.shared.removeAllForTesting()
        LinuxReadinessIngress.shared.resetForTesting()
        LinuxWorkspaceAuthority.resetPurgeAuthoritiesForTesting()
        super.tearDown()
    }

    /// Ingest the COMPLETE trusted fact set for `epoch` through the ONE
    /// production ingress path (the mapping fact is backed by a REAL
    /// terminal-index file under the explicit trusted test root, exactly
    /// like production receipts — never a flag, never an override).
    private func ingestAllRealFactsForTesting(epoch: UInt64, root: URL) throws {
        LinuxWorkspaceAuthority.storageRootOverrideForTesting = root.standardizedFileURL.path
        LinuxWorkspaceAuthority.rootEpochAuthorityForTesting = { epoch }
        // Install through the production wrapper so the ORIGINAL engine
        // serves the same accepted transfer root the receipt is read from
        // (first install wins; the override then keeps this suite's tree
        // authoritative for the lookup).
        if let rootToken = RuntimeStorageRoot(validatingAbsoluteDirectory:
                                                root.standardizedFileURL.path) {
            _ = LinuxWorkspaceAuthority.install(storageRoot: rootToken)
        }
        // One terminal-marked engine session + durable index under the
        // accepted transfer root (the ORIGINAL WorkspaceOwnerMarker shape).
        let sessionKey = String(repeating: "a", count: 32)
        let transferRoot = root.standardizedFileURL.path + "/WorkspaceTransfers"
        let sessionDir = transferRoot + "/sessions/" + sessionKey
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let marker = WorkspaceOwnerMarker(sessionKey: sessionKey, grantID: String(repeating: "f", count: 16),
                                          projectID: UUID().uuidString, runID: UUID().uuidString,
                                          rootEpoch: epoch,
                                          createdAtSeconds: Int64(Date().timeIntervalSince1970))
        try marker.writeDurable(to: sessionDir + "/owner.json")
        try marker.markTerminal(at: sessionDir + "/owner.json")
        let indexBytes = Data(("{\"record\":\"terminalIndex\",\"sessionKey\":\"" + sessionKey + "\",\"result\":\"synced\",\"partial\":false}").utf8)
        try indexBytes.write(to: URL(fileURLWithPath: sessionDir + "/index.json"))
        let receiptDigest = FloeDigest.sha256Hex(indexBytes)
        let cert = FloeDigest.sha256Hex(Data("peer-cert".utf8))
        let binder = "peer-binder-1"
        func mustAccept(_ outcome: LinuxReadinessIngressOutcome) throws {
            guard case .accepted = outcome else {
                throw NSError(domain: "ingest", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
            }
        }
        try mustAccept(LinuxReadinessIngress.shared.ingest(
            .runtimeUidBoundary(runtimeUID: Int32(getuid()) + 1, certificateDigest: cert,
                                 packageVersion: "0.1.0-test", binderIdentity: binder),
            rootEpoch: epoch))
        try mustAccept(LinuxReadinessIngress.shared.ingest(
            .engineConnected(binderIdentity: binder, engineProtocolVersion: "rw-v1"),
            rootEpoch: epoch))
        try mustAccept(LinuxReadinessIngress.shared.ingest(.mailboxEpoch, rootEpoch: epoch))
        try mustAccept(LinuxReadinessIngress.shared.ingest(
            .rootfsInstalled(receiptDigest: FloeDigest.sha256Hex(Data("rootfs".utf8)),
                             rootfsVersion: "bookworm-1"), rootEpoch: epoch))
        try mustAccept(LinuxReadinessIngress.shared.ingest(
            .workspaceMappingSynced(receiptDigest: receiptDigest), rootEpoch: epoch))
        try mustAccept(LinuxReadinessIngress.shared.ingest(
            .leaseAuthorityQualified(receiptDigest: FloeDigest.sha256Hex(Data("lease".utf8))),
            rootEpoch: epoch))
        try mustAccept(LinuxReadinessIngress.shared.ingest(
            .singleWorkloadAcknowledged(contractVersion: "single-workload-1"),
            rootEpoch: epoch))
    }

    func testDefaultsFailClosed() async {
        let (bindings, coordinator, _, root) = makeBindings()
        // Before compose: nothing registered, nothing qualified.
        XCTAssertFalse(bindings.isCapabilityQualified)
        _ = await coordinator.snapshotCountsForTesting()
        // Compose alone does not qualify.
        _ = bindings.compose(transport: FakeLinuxShellTransport(), coordinator: coordinator,
                             rootProvider: { root })
        XCTAssertFalse(bindings.isCapabilityQualified)
        // Epoch binding refuses 0 and only counts as bound, not qualified.
        XCTAssertFalse(bindings.bindMailboxEpoch(0))
        // Env defaults would silently break the engine guard: composition
        // refuses them (fail closed at wiring time).
        let rejecting = RuntimeFacadeLinuxBindings()
        let components = rejecting.compose(coordinator: coordinator, rootProvider: { root },
                                           environmentDefaults: ["PATH": "/usr/bin"])
        XCTAssertNil(components)
    }

    func testLedgerAttachesDuringDispatchAndEndsAfterLeaseProof() async throws {
        let (bindings, coordinator, transport, root) = makeBindings()
        transport.pollScript = { session, cursor, nth in
            if nth == 1 { return FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "busy") }
            return FakeLinuxShellTransport.page(session: session, cursor: cursor + 4, text: "",
                                                state: .terminated, released: true, exit: 0)
        }
        let readiness = LinuxShellLiveReadiness.makeInjected()
        _ = bindings.compose(transport: transport, coordinator: coordinator,
                             rootProvider: { root }, readiness: readiness,
                             journal: ShellOperationJournal(rootURL: root))
        // Methods run alphabetically; bind ONE above the shared mailbox's
        // current epoch instead of a fixed literal so no ordering can fence a
        // later class member (same authoritative rule production `bind` uses).
        let epoch = LinuxShellMailbox.shared.snapshotForTesting().epoch + 1
        XCTAssertTrue(bindings.bindMailboxEpoch(epoch))
        // G03-R3 false->real transition through the ONLY trusted path:
        // composed + epoch-bound is STILL unqualified with zero ingested
        // facts (there is no wholesale setter any more)...
        XCTAssertFalse(bindings.isCapabilityQualified)
        // ...and turns true ONLY after every real fact is ingested for this
        // generation (runtime-UID boundary + engine identity + the live
        // mailbox epoch + rootfs receipt + an engine terminal-index digest
        // Core reads back + lease receipt + the single-workload contract).
        try ingestAllRealFactsForTesting(epoch: epoch, root: root)
        XCTAssertTrue(bindings.isCapabilityQualified)

        let runID = UUID()
        let conversationID = UUID()
        let context = ToolContext(runID: runID, toolCallID: "shell-call-1",
                                  workspaceRootURL: root, cancellation: CancellationToken(),
                                  conversationID: conversationID, clientSessionID: "run:main")
        let components = try XCTUnwrap(bindings.components)
        let result = await components.service.run(command: "printf busy", cwd: ".", environment: [:],
                                                  stdin: nil, timeout: 1, maxOutputBytes: nil,
                                                  isBackground: false, context: context)
        guard case .outcome(.exited(let code, _, _, _, _, _)) = result else {
            return XCTFail("expected exited, got \(result)")
        }
        XCTAssertEqual(code, 0)
        // Lease released immediately in the script, so settlement ended the
        // worker: the ledger drains to empty.
        let drained = await shellWaitUntil(timeoutMillis: 2_000) {
            await coordinator.snapshotCountsForTesting() == 0
        }
        XCTAssertTrue(drained, "settled dispatch must detach the ledger worker exactly once")
    }

    func testRunCallCancellationRequestsRemoteStopAndKeepsWorkerAttached() async throws {
        let (bindings, coordinator, transport, root) = makeBindings()
        transport.releaseAfterCancel = false
        transport.pollScript = { session, cursor, _ in
            FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "long")
        }
        let readiness = LinuxShellInjectedReadiness { true }
        _ = bindings.compose(transport: transport, coordinator: coordinator,
                             rootProvider: { root }, readiness: readiness,
                             journal: ShellOperationJournal(rootURL: root))
        let epoch = LinuxShellMailbox.shared.snapshotForTesting().epoch + 1
        XCTAssertTrue(bindings.bindMailboxEpoch(epoch))
        // (R3: no qualification override — the cancellation/lease legs read
        // the ledger, not capability advertisement.)
        let runID = UUID()
        // The ledger now requires the ORIGINAL conversation binding at
        // admission (fail closed without it); supply it like the run lane does.
        let conversationID = UUID()
        let context = ToolContext(runID: runID, toolCallID: "shell-call-2",
                                  workspaceRootURL: root, cancellation: CancellationToken(),
                                  conversationID: conversationID, clientSessionID: "run:main")
        let components = try XCTUnwrap(bindings.components)
        let running = Task {
            await components.service.run(command: "sleep 300", cwd: ".", environment: [:],
                                         stdin: nil, timeout: 2, maxOutputBytes: nil,
                                         isBackground: false, context: context)
        }
        // Wait until the dispatch attached the ledger worker and started.
        let attached = await shellWaitUntil(timeoutMillis: 2_000) {
            (await coordinator.snapshotCountsForTesting()) == 1 && transport.recordedStartCount == 1
        }
        XCTAssertTrue(attached)
        // Run/call cancellation: the worker's task-cancel cancels the run's
        // own call token; the backend requests the remote stop and the
        // lease stays owned (nonterminal) until the engine proves release.
        let accepted = await bindings.cancelOwnedShellTool(runID: runID, callID: "shell-call-2",
                                                           epoch: epoch)
        XCTAssertTrue(accepted)
        let stopSeen = await shellWaitUntil(timeoutMillis: 2_000) { transport.recordedCancelCount >= 1 }
        XCTAssertTrue(stopSeen)
        _ = await running.value    // local wait answers (timedOut/cancelled), lease unreconciled
        let attachedCount = await coordinator.snapshotCountsForTesting()
        XCTAssertEqual(attachedCount, 1,
                       "ownership stays until the REAL release; EOF != exit")
        // Engine proves the release now; reconcile drains the ledger.
        let engineID = (await components.backend.unreconciledSessions().first)?.engineSessionID
        XCTAssertNotNil(engineID)
        transport.releaseAfterCancel = true
        transport.pollScript = nil
        let ended = await shellWaitUntil(timeoutMillis: 4_000) {
            let endedCount = await bindings.reconcileLedger()
            let live = await coordinator.snapshotCountsForTesting()
            return endedCount > 0 && live == 0
        }
        XCTAssertTrue(ended)
        _ = await bindings.drainLinuxShell(timeoutMillis: 500)
    }

    func testForeignRunCallIsRefusedHonestly() async {
        let (bindings, coordinator, _, root) = makeBindings()
        _ = bindings.compose(coordinator: coordinator, rootProvider: { root })
        let foreignEpoch = LinuxShellMailbox.shared.snapshotForTesting().epoch + 1
        XCTAssertTrue(bindings.bindMailboxEpoch(foreignEpoch))
        let accepted = await bindings.cancelOwnedShellTool(runID: UUID(), callID: "nobody",
                                                           epoch: foreignEpoch)
        XCTAssertFalse(accepted, "never a fake success")
    }
}
