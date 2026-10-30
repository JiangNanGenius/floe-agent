// SPDX-License-Identifier: MPL-2.0
// Authored production-flow regressions for RUN-LESS terminal first entry.
// Real accepted bootstrap, real migrated SQLite/run operation receipts and
// real mailbox admission; ONLY the engine transport is a deterministic fake.
// Nothing here configures a provider, creates a model run or touches a device.
import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif
import GRDB
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
import FloeAndroidShellTools
import FloeAndroidWorkspaceTools
// The role-aware engine-slot admission vocabulary lives in FloeAgentRuntime.
import FloeAgentRuntime
@testable import FloeAndroidCore

private final class FirstEntryFlowSink: G04TerminalEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var controls: [[String: Any]] = []
    func emitControl(_ object: [String: Any]) {
        lock.lock(); controls.append(object); lock.unlock()
    }
    func emitOutput(sessionToken: String, seq: Int64, bytes: Data) {}
    func reply(_ requestID: String) -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        return controls.last {
            ($0["type"] as? String) == "actionReply" &&
                ($0["requestID"] as? String) == requestID
        }
    }
}

private final class FirstEntryHostControl: @unchecked Sendable {
    private let lock = NSLock()
    private var claims = 0
    private var released = true
    init(holdForRelease: Bool) { released = !holdForRelease }
    func noteClaim() { lock.lock(); claims += 1; lock.unlock() }
    var claimCount: Int { lock.lock(); defer { lock.unlock() }; return claims }
    var mayReply: Bool { lock.lock(); defer { lock.unlock() }; return released }
    func release() { lock.lock(); released = true; lock.unlock() }
}

private final class FirstEntryFlowBoot {
    let epoch: UInt64
    let root: URL
    let token: String
    var retired = false
    init(epoch: UInt64, root: URL, token: String) {
        self.epoch = epoch; self.root = root; self.token = token
    }
}

final class G04TerminalFirstUseProductionFlowTests: XCTestCase {
    private var boots: [FirstEntryFlowBoot] = []
    private var stores: [G04TerminalStore] = []
    private var hostControls: [FirstEntryHostControl] = []
    private var hosts: [Task<Void, Never>] = []

    override func tearDown() async throws {
        hostControls.forEach { $0.release() }
        hostControls.removeAll()
        for host in hosts { await host.value }
        hosts.removeAll()
        for store in stores { await store.retire() }
        stores.removeAll()
        for boot in boots.reversed() where !boot.retired {
            await shutdown(boot)
        }
        boots.removeAll()
        LinuxShellMailbox.shared.close()
        LinuxReadinessIngress.shared.resetForTesting()
        RuntimeOwnedWorkRegistry.shared.removeAllForTesting()
        G02RuntimeComposition.shared.resetForTesting()
        AndroidRuntimeBootstrap.resetForTesting()
        try await super.tearDown()
    }

    private func shutdown(_ boot: FirstEntryFlowBoot) async {
        guard !boot.retired else { return }
        boot.retired = true
        RuntimeFacadeLinuxBindings.shared.fenceGeneration(epoch: boot.epoch)
        _ = AndroidRuntimeBootstrap.shutdown(expectedEpoch: boot.epoch, ownerToken: boot.token)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if AndroidRuntimeBootstrap.currentGenerationForTesting() == nil { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("first-entry flow generation did not close")
    }

    private func boot() async throws -> FirstEntryFlowBoot {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("terminal-first-entry-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let epoch = DispatchTime.now().uptimeNanoseconds
        let token = String(format: "%016llx", UInt64.random(in: 1...UInt64.max))
        guard case .accepted = AndroidRuntimeBootstrap.start(
            rootPath: root.standardizedFileURL.path, ownerToken: token, epoch: epoch) else {
            throw NSError(domain: "firstEntryFlow", code: 1)
        }
        let boot = FirstEntryFlowBoot(epoch: epoch, root: root, token: token)
        boots.append(boot)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if let installed = G02RuntimeComposition.shared.installedComposition,
               installed.epoch == epoch,
               AndroidRuntimeBootstrap.currentPumps()?.storeReady == true,
               RunDomainFacade.current(epoch: epoch) != nil {
                return boot
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw NSError(domain: "firstEntryFlow", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: AndroidRuntimeBootstrap.statusSnapshotJSON()])
    }

    private static func accept(_ outcome: LinuxReadinessIngressOutcome) throws {
        guard case .accepted = outcome else {
            throw NSError(domain: "firstEntryFlowIngress", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(outcome)"])
        }
    }

    /// The FIVE consumed prerequisites only. Mapping + lease are deliberately
    /// absent until the real mailbox preflight produces them.
    private static func ingestPrerequisites(epoch: UInt64) throws {
        let cert = FloeDigest.sha256Hex(Data("first-entry-peer-cert".utf8))
        let binder = "first-entry-peer-binder"
        try accept(LinuxReadinessIngress.shared.ingest(
            .runtimeUidBoundary(runtimeUID: Int32(getuid()) + 1,
                                certificateDigest: cert, packageVersion: "0.1.0-test",
                                binderIdentity: binder), rootEpoch: epoch))
        try accept(LinuxReadinessIngress.shared.ingest(
            .engineConnected(binderIdentity: binder, engineProtocolVersion: "rw-v1"),
            rootEpoch: epoch))
        try accept(LinuxReadinessIngress.shared.ingest(.mailboxEpoch, rootEpoch: epoch))
        try accept(LinuxReadinessIngress.shared.ingest(
            .rootfsInstalled(receiptDigest: FloeDigest.sha256Hex(Data("first-entry-rootfs".utf8)),
                             rootfsVersion: "bookworm-1"), rootEpoch: epoch))
        try accept(LinuxReadinessIngress.shared.ingest(
            .singleWorkloadAcknowledged(contractVersion: "single-workload-1"),
            rootEpoch: epoch))
    }

    /// Real terminal-index bytes under the ORIGINAL transfer authority. The
    /// returned digest is what the host reply echoes; Core independently reads
    /// its own ingress and never qualifies from that echo alone.
    @discardableResult
    private static func ingestProducedFacts(epoch: UInt64, root: URL) throws -> String {
        let sessionKey = String(repeating: "a", count: 32)
        let sessionDir = root.standardizedFileURL.path +
            "/WorkspaceTransfers/sessions/" + sessionKey
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        let marker = WorkspaceOwnerMarker(
            sessionKey: sessionKey, grantID: String(repeating: "f", count: 16),
            projectID: UUID().uuidString, runID: UUID().uuidString,
            rootEpoch: epoch, createdAtSeconds: Int64(Date().timeIntervalSince1970))
        try marker.writeDurable(to: sessionDir + "/owner.json")
        try marker.markTerminal(at: sessionDir + "/owner.json")
        let indexBytes = Data(("{\"record\":\"terminalIndex\",\"sessionKey\":\"" +
            sessionKey + "\",\"result\":\"synced\",\"partial\":false}").utf8)
        try indexBytes.write(to: URL(fileURLWithPath: sessionDir + "/index.json"))
        let indexDigest = FloeDigest.sha256Hex(indexBytes)
        try accept(LinuxReadinessIngress.shared.ingest(
            .workspaceMappingSynced(receiptDigest: indexDigest), rootEpoch: epoch))
        try accept(LinuxReadinessIngress.shared.ingest(
            .leaseAuthorityQualified(receiptDigest: FloeDigest.sha256Hex(
                Data("first-entry-lease".utf8))), rootEpoch: epoch))
        return indexDigest
    }

    private func compose(_ boot: FirstEntryFlowBoot,
                         transport: FakeTerminalTransport) throws {
        _ = RuntimeFacadeLinuxBindings.shared.compose(
            transport: transport,
            coordinator: FacadeToolWorkCoordinator(),
            rootProvider: { nil },
            readiness: LinuxShellLiveReadiness.makeInjected())
        XCTAssertTrue(RuntimeFacadeLinuxBindings.shared.bindMailboxEpoch(boot.epoch))
        try Self.ingestPrerequisites(epoch: boot.epoch)
        XCTAssertFalse(RuntimeFacadeLinuxBindings.shared.isCapabilityQualified)
    }

    /// One REAL mailbox host claim. It performs no command and no model work;
    /// its only effect is ingesting the measured mapping/lease facts that the
    /// production preflight producer would have established.
    private func startPreflightHost(_ boot: FirstEntryFlowBoot,
                                    control: FirstEntryHostControl) -> Task<Void, Never> {
        hostControls.append(control)
        let mailbox = LinuxShellMailbox.shared
        let root = boot.root
        let epoch = boot.epoch
        let task = Task.detached {
            let claim = mailbox.nextClaim(timeoutMillis: 5_000)
            guard claim > 0 else { return }
            let length = mailbox.payloadLength(claim: claim)
            guard length > 0 else { return }
            var bytes = [UInt8](repeating: 0, count: Int(length))
            let copied = bytes.withUnsafeMutableBufferPointer { raw in
                mailbox.takePayload(claim: claim, buffer: raw.baseAddress, capacity: length)
            }
            guard copied == length else { return }
            let payload = Data(bytes)
            guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let operationText = object["operationID"] as? String,
                  let uiText = object["uiRunID"] as? String,
                  let conversationText = object["conversationID"] as? String,
                  let operation = UUID(uuidString: operationText),
                  let ui = UUID(uuidString: uiText),
                  let conversation = UUID(uuidString: conversationText) else { return }
            control.noteClaim()
            while !control.mayReply {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            do {
                let digest = try Self.ingestProducedFacts(epoch: epoch, root: root)
                let frame = try JSONSerialization.data(withJSONObject: [
                    "status": "ready", "rootEpoch": epoch,
                    "operationID": operation.uuidString, "uiRunID": ui.uuidString,
                    "conversationID": conversation.uuidString,
                    "workspaceIndexDigest": digest,
                    "leaseProofDigest": FloeDigest.sha256Hex(Data("first-entry-lease".utf8)),
                    "shellRegistered": true, "ownershipReleased": true,
                ] as [String: Any], options: [.sortedKeys])
                _ = frame.withUnsafeBytes { raw in
                    mailbox.complete(claim: claim, status: 0,
                                     value: raw.bindMemory(to: UInt8.self).baseAddress,
                                     valueLen: Int32(frame.count))
                }
            } catch {
                return
            }
        }
        hosts.append(task)
        return task
    }

    private func waitForClaim(_ control: FirstEntryHostControl) async -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if control.claimCount == 1 { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return control.claimCount == 1
    }

    private func makeConversation(_ id: UUID,
                                  purpose: ConversationPurpose = .ordinary,
                                  title: String = "Cold task") async throws {
        let installed = try XCTUnwrap(G02RuntimeComposition.shared.installedComposition)
        try await installed.cluster.conversationStore.saveConversation(ConversationRecord(
            id: id, title: title, createdAt: Date(), updatedAt: Date(), purpose: purpose))
    }

    func testZeroWorkspaceOrdinaryTaskBindsPreflightsOpensAndWarmReuses() async throws {
        let boot = try await boot()
        let transport = FakeTerminalTransport()
        try compose(boot, transport: transport)
        let hostControl = FirstEntryHostControl(holdForRelease: false)
        let host = startPreflightHost(boot, control: hostControl)
        let conversation = UUID()
        try await makeConversation(conversation)
        let installed = try XCTUnwrap(G02RuntimeComposition.shared.installedComposition)
        let workspaceIDBeforeOpen = try await installed.cluster.workspaceStore.workspaceID(
            conversationID: conversation)
        XCTAssertNil(workspaceIDBeforeOpen)
        let runCountBeforeOpen = try await PrivacyTestBed.count(installed.cluster.database,
            "SELECT COUNT(*) FROM runs WHERE conversation_id = ?", [conversation.uuidString])
        XCTAssertEqual(runCountBeforeOpen, 0)

        let sink = FirstEntryFlowSink()
        let store = G04TerminalStore(epoch: boot.epoch, sink: sink)
        stores.append(store)
        await store.open(conversationID: conversation, workspaceID: nil,
                         purpose: .interactive, command: "", cwd: ".",
                         columns: 80, rows: 24, requestID: "cold-open")
        await host.value
        let opened = try XCTUnwrap(sink.reply("cold-open"))
        XCTAssertEqual(opened["ok"] as? Bool, true)
        XCTAssertEqual(hostControl.claimCount, 1)
        XCTAssertEqual(transport.dispatches.filter { $0.operation == "shell.start" }.count, 1)
        let workspaceIDAfterOpen = try await installed.cluster.workspaceStore.workspaceID(
            conversationID: conversation)
        let binding = try XCTUnwrap(workspaceIDAfterOpen)
        let workspaceRecord = try await installed.cluster.workspaceStore.workspace(id: binding)
        let record = try XCTUnwrap(workspaceRecord)
        XCTAssertEqual(record.kind, .privateTask)
        XCTAssertEqual(record.internalRelativePath, "PrivateTasks/\(conversation.uuidString)")
        XCTAssertTrue(RuntimeFacadeLinuxBindings.shared.isCapabilityQualified)
        let runCountAfterOpen = try await PrivacyTestBed.count(installed.cluster.database,
            "SELECT COUNT(*) FROM runs WHERE conversation_id = ?", [conversation.uuidString])
        XCTAssertEqual(runCountAfterOpen, 0)

        // Warm preparation is a no-op: no second import/preflight and the same
        // persisted association is returned untouched.
        let warmPreparation = await store.prepareFirstEntry(conversationID: conversation,
                                                             expectedWorkspaceID: nil)
        XCTAssertEqual(warmPreparation, .proceed)
        XCTAssertEqual(hostControl.claimCount, 1)
        let workspaceIDAfterWarm = try await installed.cluster.workspaceStore.workspaceID(
            conversationID: conversation)
        XCTAssertEqual(workspaceIDAfterWarm, binding)

        // Ordinary-purpose / foreign-workspace ceilings run through the SAME
        // production open route and never submit another preflight.
        let notes = UUID()
        try await makeConversation(notes, purpose: .notes, title: "Notes")
        await store.open(conversationID: notes, workspaceID: nil, purpose: .interactive,
                         command: "", cwd: ".", columns: 80, rows: 24, requestID: "notes")
        XCTAssertEqual(sink.reply("notes")?["code"] as? String, "purposeNotOrdinary")
        // A temporary chat is RAM-only by design: the V41 conversations CHECK
        // admits only ordinary/notes, so it has NO durable row to persist here
        // (the pure eligibility rule already proves persisted:false is
        // .notEligible). The SAME production open route must therefore keep the
        // ORIGINAL admission refusal for its unpersisted identity, create no
        // binding and dispatch nothing.
        let temporary = UUID()
        await store.open(conversationID: temporary, workspaceID: nil, purpose: .interactive,
                         command: "", cwd: ".", columns: 80, rows: 24, requestID: "temporary")
        XCTAssertEqual(sink.reply("temporary")?["code"] as? String, "workspaceUnbound")
        let temporaryWorkspaceID = try await installed.cluster.workspaceStore.workspaceID(
            conversationID: temporary)
        XCTAssertNil(temporaryWorkspaceID)
        let foreign = UUID()
        try await makeConversation(foreign, title: "Foreign expectation")
        await store.open(conversationID: foreign, workspaceID: UUID(), purpose: .interactive,
                         command: "", cwd: ".", columns: 80, rows: 24, requestID: "foreign")
        XCTAssertEqual(sink.reply("foreign")?["code"] as? String, "workspaceUnbound")
        let foreignWorkspaceID = try await installed.cluster.workspaceStore.workspaceID(conversationID: foreign)
        XCTAssertNil(foreignWorkspaceID)
        XCTAssertEqual(hostControl.claimCount, 1)
        XCTAssertEqual(transport.dispatches.filter { $0.operation == "shell.start" }.count, 1)

        // The editor Run action has the SAME cold-binding requirement. Close
        // the interactive owner first so the single engine slot is genuinely
        // free; runDraft must create the binding BEFORE its original admit,
        // then reach the real center/backend without any provider/run row.
        let sessionToken = try XCTUnwrap(opened["sessionToken"] as? String)
        await store.close(sessionToken: sessionToken, requestID: "close-interactive")
        // `close` above is the ORIGINAL stop REQUEST, not a proven stop: the
        // single engine slot stays owned by the backend's reconciliation until
        // the engine reports `leaseReleased`. Hand the fake host the honest
        // terminal/release pages and wait for that REAL proof instead of
        // pretending close is instant — `runDraft`'s isEngineSlotBusy refusal
        // below is the same single-workload contract.
        let released = LinuxShellPollReply(
            sessionID: "engine-session-1", mergedOutput: Data(), cursor: 0,
            gapBytes: 0, more: false, droppedBytes: 0, state: .terminated,
            leaseReleased: true, cancelled: true, stopReason: "user-stop")
        transport.replacePollScript(Array(repeating: released, count: 16))
        var releasedSlot = false
        let releaseDeadline = Date().addingTimeInterval(6)
        while Date() < releaseDeadline {
            if let backend = RuntimeFacadeLinuxBindings.shared.components?.backend,
               await backend.isEngineSlotBusy() == false {
                releasedSlot = true
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(releasedSlot, "the explicit close must reach its real engine release before the slot is reused")
        // The reconciliation consumed its release proof; drop any remaining
        // scripted pages so the DRAFT session's own initial drain cannot read
        // a stale terminal as if it belonged to the new engine lease.
        transport.clearPollScript()
        let draft = UUID()
        try await makeConversation(draft, title: "Draft task")
        let draftWorkspaceIDBeforeRun = try await installed.cluster.workspaceStore.workspaceID(conversationID: draft)
        XCTAssertNil(draftWorkspaceIDBeforeRun)
        await store.runDraft(conversationID: draft, workspaceID: nil,
                             relativePath: "main.py", languageID: "python", requestID: "draft-run")
        let draftReply = try XCTUnwrap(sink.reply("draft-run"))
        XCTAssertEqual(draftReply["ok"] as? Bool, true)
        let draftWorkspaceIDAfterRun = try await installed.cluster.workspaceStore.workspaceID(conversationID: draft)
        XCTAssertNotNil(draftWorkspaceIDAfterRun)
        XCTAssertEqual(hostControl.claimCount, 1)
        XCTAssertEqual(transport.dispatches.filter { $0.operation == "shell.start" }.count, 2)
        let draftRunCount = try await PrivacyTestBed.count(installed.cluster.database,
            "SELECT COUNT(*) FROM runs WHERE conversation_id = ?", [draft.uuidString])
        XCTAssertEqual(draftRunCount, 0)
        await store.retire()
    }

    func testLateGlobalQualificationCannotOverrideRealOperationCancellation() async throws {
        let boot = try await boot()
        let transport = FakeTerminalTransport()
        try compose(boot, transport: transport)
        let hostControl = FirstEntryHostControl(holdForRelease: true)
        let host = startPreflightHost(boot, control: hostControl)
        let conversation = UUID()
        try await makeConversation(conversation)
        let sink = FirstEntryFlowSink()
        let store = G04TerminalStore(epoch: boot.epoch, sink: sink)
        stores.append(store)
        let opening = Task {
            await store.open(conversationID: conversation, workspaceID: nil,
                             purpose: .interactive, command: "", cwd: ".",
                             columns: 80, rows: 24, requestID: "cancelled-open")
        }
        let claimObserved = await waitForClaim(hostControl)
        XCTAssertTrue(claimObserved)
        let installed = try XCTUnwrap(G02RuntimeComposition.shared.installedComposition)
        // Binding really happened before the host claim; no model run exists.
        let conversationWorkspaceID = try await installed.cluster.workspaceStore.workspaceID(
            conversationID: conversation)
        XCTAssertNotNil(conversationWorkspaceID)
        let (domain, _) = try XCTUnwrap(RunDomainFacade.current(epoch: boot.epoch))
        let lifecycle = RunDomainDeletionLifecycle(domain: domain)
        let fence = try await lifecycle.beginDeletionFence(
            conversationID: conversation, epoch: boot.epoch, operationID: UUID())
        // NOW let the host produce every fact and answer ready. The operation's
        // OWN cancellation must still be a HARD retired refusal, with no open.
        hostControl.release()
        await opening.value
        await host.value
        XCTAssertTrue(RuntimeFacadeLinuxBindings.shared.isCapabilityQualified)
        let refused = try XCTUnwrap(sink.reply("cancelled-open"))
        XCTAssertEqual(refused["ok"] as? Bool, false)
        XCTAssertEqual(refused["code"] as? String, "retired")
        XCTAssertEqual(refused["reason"] as? String, "leaseCancelled")
        XCTAssertTrue(transport.dispatches.filter { $0.operation == "shell.start" }.isEmpty)
        _ = await lifecycle.abortDeletionFence(fence)
        await store.retire()
    }

    /// G07.3A Agent admission role-pool regression (job-2ea65c020ee447b2):
    /// the REAL terminal store plus the REAL role-aware backend decision.
    /// Two admitted interactive tabs must never become an engine-slot conflict
    /// for the free dedicated Agent execution slot. When a live Agent/run lease
    /// really owns that execution slot, the probe must stay silent because
    /// ending a terminal cannot free it (the ORIGINAL backend `.notStarted`
    /// serialization remains the truthful refusal). Backend capacities are
    /// pinned too: 2 interactive + 1 shared execution, never a fabricated
    /// extra execution slot.
    func testAgentAdmissionIgnoresTwoInteractiveTabsAndNeverMisoffersTTYHandoff() async throws {
        let boot = try await boot()
        let transport = FakeTerminalTransport()
        try compose(boot, transport: transport)
        let hostControl = FirstEntryHostControl(holdForRelease: false)
        let host = startPreflightHost(boot, control: hostControl)
        let conversation = UUID()
        try await makeConversation(conversation)
        let sink = FirstEntryFlowSink()
        let store = G04TerminalStore(epoch: boot.epoch, sink: sink)
        stores.append(store)

        transport.startReply = LinuxShellStartReply(
            sessionID: "engine-tty-a", environmentID: "env-shared",
            runtimeGeneration: "boot-gen-1")
        await store.open(conversationID: conversation, workspaceID: nil,
                         purpose: .interactive, command: "", cwd: ".",
                         columns: 80, rows: 24, requestID: "tty-a")
        let ttyA = try XCTUnwrap(sink.reply("tty-a"))
        XCTAssertEqual(ttyA["ok"] as? Bool, true)

        // Warm same-conversation second tab: no second host preflight.
        transport.startReply = LinuxShellStartReply(
            sessionID: "engine-tty-b", environmentID: "env-shared",
            runtimeGeneration: "boot-gen-1")
        await store.open(conversationID: conversation, workspaceID: nil,
                         purpose: .interactive, command: "", cwd: ".",
                         columns: 80, rows: 24, requestID: "tty-b")
        let ttyB = try XCTUnwrap(sink.reply("tty-b"))
        XCTAssertEqual(ttyB["ok"] as? Bool, true)
        await host.value
        XCTAssertEqual(hostControl.claimCount, 1)

        let backend = try XCTUnwrap(RuntimeFacadeLinuxBindings.shared.components?.backend)
        let twoTabsOwned = await backend.ownedSessions()
        XCTAssertEqual(twoTabsOwned.filter { $0.role == .interactive }.count, 2)
        XCTAssertEqual(twoTabsOwned.filter { $0.role == .agent || $0.role == .run }.count, 0)
        let interactiveCapacityWithTwoTabs = await backend.hasCapacity(for: .interactive)
        let agentCapacityWithTwoTabs = await backend.hasCapacity(for: .agent)
        let runCapacityWithTwoTabs = await backend.hasCapacity(for: .run)
        XCTAssertFalse(interactiveCapacityWithTwoTabs,
                       "both interactive slots are genuinely occupied")
        XCTAssertTrue(agentCapacityWithTwoTabs,
                      "two interactive leases must not consume the dedicated execution slot")
        XCTAssertTrue(runCapacityWithTwoTabs,
                      "the shared Agent/run execution slot is still free")
        let freeExecutionBlocker = await backend.capacityBlockingRole(for: .agent)
        XCTAssertNil(freeExecutionBlocker,
                     "two live TTY leases are not the role blocking Agent admission")

        // Exact production probe + registry path (isolated instance; never the
        // process-wide shared registry).
        let registry = LinuxEngineSlotRegistry()
        XCTAssertTrue(registry.register(
            G04TerminalSlotConflictProbe(store: store, epoch: boot.epoch),
            epoch: boot.epoch))
        let freeExecutionConflict = await registry.interactiveTerminalConflict(
            conversationID: conversation, toolName: "exec.shell")
        XCTAssertNil(freeExecutionConflict,
                     "a full TTY pool with a free dedicated execution slot must not escalate")

        // Genuinely hold the ONE shared Agent/run execution slot from another
        // conversation. Closing this conversation's TTY cannot free it, so the
        // probe must remain nil instead of offering a misleading TTY handoff.
        transport.startReply = LinuxShellStartReply(
            sessionID: "engine-agent-holder", environmentID: "env-agent",
            runtimeGeneration: "boot-gen-1", workspaceOwner: false)
        let agentOpen = try await backend.openSession(ShellOpenRequest(
            command: "", cwd: ".", rootURL: boot.root, environment: [:],
            columns: 80, rows: 24, gateTimeout: 1, sessionID: "agent-holder",
            runID: UUID(), toolEnvironment: nil, conversationID: UUID(),
            prepareLinuxIfMissing: false, leaseRole: .agent), cancellation: nil)
        XCTAssertTrue(agentOpen.alive)

        let executionOwned = await backend.ownedSessions()
        XCTAssertEqual(executionOwned.filter { $0.role == .interactive }.count, 2,
                       "the two TTY leases are unchanged while execution runs")
        XCTAssertEqual(executionOwned.filter { $0.role == .agent || $0.role == .run }.count, 1)
        let interactiveCapacityWithExecution = await backend.hasCapacity(for: .interactive)
        let agentCapacityWithExecution = await backend.hasCapacity(for: .agent)
        let runCapacityWithExecution = await backend.hasCapacity(for: .run)
        XCTAssertFalse(interactiveCapacityWithExecution)
        XCTAssertFalse(agentCapacityWithExecution,
                       "genuine execution occupancy is still 0/1")
        XCTAssertFalse(runCapacityWithExecution)
        let busyExecutionBlocker = await backend.capacityBlockingRole(for: .agent)
        XCTAssertEqual(busyExecutionBlocker, LinuxShellLeaseRole.agent,
                       "the live Agent lease, never a TTY, is the real execution blocker")

        let busyExecutionConflict = await registry.interactiveTerminalConflict(
            conversationID: conversation, toolName: "exec.shell")
        XCTAssertNil(busyExecutionConflict,
                     "another Agent/run lease is not this conversation's TTY; a terminal handoff cannot free it")
        let directStoreTruth = await store.interactiveTerminalHoldingEngineSlot(
            conversationID: conversation)
        XCTAssertNil(directStoreTruth,
                     "the production store must not report the TTY as holding the execution slot")
        let afterProbeOwned = await backend.ownedSessions()
        XCTAssertEqual(afterProbeOwned.filter { $0.role == .interactive }.count, 2,
                       "the probe must never stop or close the TTY leases")
        XCTAssertEqual(afterProbeOwned.filter { $0.role == .agent }.count, 1,
                       "the probe must not stop or hand off the unrelated execution lease")

        await backend.closeSession(sessionID: "agent-holder")
        await store.retire()
    }
}
