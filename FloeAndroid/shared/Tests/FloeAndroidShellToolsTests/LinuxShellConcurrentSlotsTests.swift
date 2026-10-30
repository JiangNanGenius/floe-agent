// SPDX-License-Identifier: MPL-2.0
//
// G07.3A focused backend regressions (authored, not executed by this job).
//
// These pin the CLIENT half of real concurrent terminal sessions: the role
// pool admits two interactive tabs and one Agent command independently, a third
// interactive open refuses BEFORE any dispatch, and closing one tab addresses
// only that tab's engine session. Everything rides the synthetic transport; no
// device, runtime component, model or credential is touched.

import XCTest
import Foundation
import FloeCore
import FloeTools
@testable import FloeAndroidShellTools

final class LinuxShellConcurrentSlotsTests: XCTestCase {

    private func makeBackend() -> (AndroidLinuxShellBackend, FakeLinuxShellTransport) {
        let transport = FakeLinuxShellTransport()
        let configuration = AndroidLinuxShellBackend.Configuration(
            pollIntervalNanos: 1_000_000,
            releaseGrace: 0.2,
            stdinWriteRetries: 8,
            reconcileIntervalNanos: 5_000_000,
            reconcileObservation: 30)
        let backend = AndroidLinuxShellBackend(
            transport: transport,
            readiness: StaticLinuxShellReadiness(qualified: true),
            configuration: configuration)
        return (backend, transport)
    }

    private func root() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("floe-concurrent-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func open(_ backend: AndroidLinuxShellBackend, _ transport: FakeLinuxShellTransport,
                      root: URL, session: String, engine: String,
                      conversation: UUID, role: LinuxShellLeaseRole = .interactive) async throws {
        transport.startReply = { _ in
            LinuxShellStartReply(sessionID: engine, environmentID: "env-shared",
                                 runtimeGeneration: "boot-gen-1",
                                 workspaceOwner: session == "session-a")
        }
        _ = try await backend.openSession(ShellOpenRequest(
            command: "", cwd: ".", rootURL: root, environment: [:], columns: 80, rows: 24,
            gateTimeout: 2, sessionID: session, runID: UUID(), toolEnvironment: nil,
            conversationID: conversation, prepareLinuxIfMissing: false,
            leaseRole: role), cancellation: nil)
    }

    func testTwoInteractiveTabsCoexistAndThirdRefusesBeforeDispatch() async throws {
        let (backend, transport) = makeBackend()
        let workspace = try root()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let conversationA = UUID()
        try await open(backend, transport, root: workspace, session: "session-a",
                       engine: "engine-a", conversation: conversationA)
        try await open(backend, transport, root: workspace, session: "session-b",
                       engine: "engine-b", conversation: conversationA)

        let owned = await backend.ownedSessions()
        XCTAssertEqual(Set(owned.map(\.engineSessionID)), ["engine-a", "engine-b"])
        XCTAssertEqual(Set(owned.map(\.role)), [.interactive])
        let agentCapacity = await backend.hasCapacity(for: .agent)
        XCTAssertTrue(agentCapacity, "two live terminals must not consume the Agent slot")
        let interactiveCapacity = await backend.hasCapacity(for: .interactive)
        XCTAssertFalse(interactiveCapacity)

        let third = UUID()
        do {
            _ = try await backend.openSession(ShellOpenRequest(
                command: "", cwd: ".", rootURL: workspace, environment: [:], columns: 80, rows: 24,
                gateTimeout: 0.2, sessionID: "session-c", runID: UUID(), toolEnvironment: nil,
                conversationID: third, prepareLinuxIfMissing: false, leaseRole: .interactive),
                cancellation: nil)
            XCTFail("the third interactive tab must refuse")
        } catch let error as FloeError {
            XCTAssertTrue(String(describing: error).contains("interactive terminal slots"),
                          String(describing: error))
        }
        XCTAssertEqual(transport.starts.count, 2, "a refused role slot never dispatches a start")

        // Closing tab A addresses ONLY engine-a.
        await backend.closeSession(sessionID: "session-a")
        XCTAssertEqual(transport.cancels.map(\.sessionID), ["engine-a"])
        let stillOwned = await backend.ownedSessions().map(\.engineSessionID)
        XCTAssertTrue(stillOwned.contains("engine-b"), "the sibling tab keeps its own session")
    }

    func testAgentCommandRunsConcurrentlyWithALiveInteractiveTab() async throws {
        let (backend, transport) = makeBackend()
        let workspace = try root()
        defer { try? FileManager.default.removeItem(at: workspace) }
        try await open(backend, transport, root: workspace, session: "session-interactive",
                       engine: "engine-interactive", conversation: UUID())

        transport.startReply = { _ in
            LinuxShellStartReply(sessionID: "engine-agent", environmentID: "env-shared",
                                 runtimeGeneration: "boot-gen-1", workspaceOwner: false)
        }
        transport.pollScript = { session, cursor, _ in
            session == "engine-agent"
                ? FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "ok\n",
                                               state: .terminated, released: true, exit: 0,
                                               workspaceStatus: "synced")
                : nil
        }
        let request = ShellRunRequest(
            command: "echo ok", cwd: ".", rootURL: workspace, environment: [:], stdin: nil,
            timeout: 2, gateTimeout: 1, maxOutputBytes: 16 * 1024,
            sessionID: "run-agent-1", runID: UUID(), toolEnvironment: nil,
            conversationID: UUID())
        let outcome = await backend.run(request, cancellation: nil)
        guard case .exited(let code, let stdout, _, _, _, _) = outcome else {
            return XCTFail("expected the Agent command to run concurrently, got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertTrue(stdout.contains("ok"))
        let owned = await backend.ownedSessions().map(\.engineSessionID)
        XCTAssertTrue(owned.contains("engine-interactive"),
                      "the interactive session is still alive after the Agent command settles")
    }

    func testAgentAndRunShareOneExecutionSlot() async throws {
        let (backend, transport) = makeBackend()
        let workspace = try root()
        defer { try? FileManager.default.removeItem(at: workspace) }
        // A live agent-role session holds the ONE execution slot.
        try await open(backend, transport, root: workspace, session: "session-execution",
                       engine: "engine-execution", conversation: UUID(), role: .agent)
        let agentCapacity = await backend.hasCapacity(for: .agent)
        let runCapacity = await backend.hasCapacity(for: .run)
        XCTAssertFalse(agentCapacity, "the Agent execution slot is held")
        XCTAssertFalse(runCapacity, "a run session shares the SAME execution slot")
        let interactiveCapacity = await backend.hasCapacity(for: .interactive)
        XCTAssertTrue(interactiveCapacity, "interactive tabs are a separate role")
    }

    func testDeferredSharedWorkspaceIsAnHonestSuccessNotAFailure() async throws {
        let (backend, transport) = makeBackend()
        let workspace = try root()
        defer { try? FileManager.default.removeItem(at: workspace) }
        transport.startReply = { _ in
            LinuxShellStartReply(sessionID: "engine-participant",
                                 environmentID: "env-shared",
                                 runtimeGeneration: "boot-gen-1",
                                 workspaceOwner: false)
        }
        transport.pollScript = { session, cursor, _ in
            FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "done\n",
                                         state: .terminated, released: true, exit: 0,
                                         workspaceStatus: "deferred")
        }
        let request = ShellRunRequest(
            command: "echo done", cwd: ".", rootURL: workspace, environment: [:], stdin: nil,
            timeout: 2, gateTimeout: 1, maxOutputBytes: 16 * 1024,
            sessionID: "run-shared-1", runID: UUID(), toolEnvironment: nil,
            conversationID: UUID())
        let outcome = await backend.run(request, cancellation: nil)
        guard case .exited(let code, let stdout, let stderr, _, _, _) = outcome else {
            return XCTFail("a deferred shared export must not be a failure, got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertTrue(stdout.contains("done"))
        XCTAssertTrue(stderr.contains("owned by another live session"),
                      "the deferral is stated as bounded metadata, not a saved-workspace claim")
    }

    // MARK: - Observed workspace owner selection (G07.3A owner/participant)

    /// Deterministic ordinal for synthetic start replies. The wire request
    /// does not carry the Center's client token, so the fake distinguishes
    /// opens by their actual dispatch order (all calls are serialized here).
    private final class OpenReplyOrdinal: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            value += 1
            return value
        }
    }

    private func engineSession(_ id: String, conversation: UUID?, owner: Bool?,
                               released: Bool = false) -> AndroidLinuxShellBackend.EngineSession {
        AndroidLinuxShellBackend.EngineSession(
            sessionKey: id, engineSessionID: id, environmentID: "env-shared",
            runID: nil, conversationID: conversation, cursor: 0, bytesRead: 0,
            bytesWritten: 0, state: released ? .terminated : .running,
            leaseReleased: released, cancelled: false, stopReason: nil,
            exitCode: nil, termSig: nil, stopRequested: false,
            workspaceOwner: owner)
    }

    /// The selection itself is order-independent: a participant record placed
    /// BEFORE the real owner must never be named, and no/default/duplicate
    /// observations fail closed instead of fabricating an owner hint.
    func testObservedWorkspaceReuseChoosesOnlyAProvenOwnerInAnyOrder() {
        let conversation = UUID()
        let owner = engineSession("engine-a", conversation: conversation, owner: true)
        let participant = engineSession("engine-b", conversation: conversation, owner: false)

        XCTAssertEqual(AndroidLinuxShellBackend.observedWorkspaceReuse(
            conversationID: conversation, sessions: [participant, owner]),
            LinuxShellWorkspaceReuse.shared(ownerSessionID: "engine-a"),
            "a participant first in the collection is skipped")
        XCTAssertEqual(AndroidLinuxShellBackend.observedWorkspaceReuse(
            conversationID: conversation, sessions: [owner, participant]),
            LinuxShellWorkspaceReuse.shared(ownerSessionID: "engine-a"),
            "the proven owner is selected in either order")

        XCTAssertNil(AndroidLinuxShellBackend.observedWorkspaceReuse(
            conversationID: conversation, sessions: [participant]),
            "an observed participant is not an owner")
        XCTAssertNil(AndroidLinuxShellBackend.observedWorkspaceReuse(
            conversationID: conversation,
            sessions: [engineSession("engine-b", conversation: conversation, owner: nil)]),
            "absent legacy metadata is never promoted to a proven owner")
        XCTAssertNil(AndroidLinuxShellBackend.observedWorkspaceReuse(
            conversationID: conversation,
            sessions: [engineSession("engine-a", conversation: conversation,
                                     owner: true, released: true)]),
            "a released lease is not a live owner")
        XCTAssertNil(AndroidLinuxShellBackend.observedWorkspaceReuse(
            conversationID: UUID(), sessions: [owner]),
            "another conversation's owner is never reused")
        XCTAssertNil(AndroidLinuxShellBackend.observedWorkspaceReuse(
            conversationID: nil, sessions: [owner]),
            "no conversation means no owner hint")
        XCTAssertNil(AndroidLinuxShellBackend.observedWorkspaceReuse(
            conversationID: conversation,
            sessions: [owner, engineSession("engine-c", conversation: conversation, owner: true)]),
            "two proven owners are inconsistent; never choose one arbitrarily")
    }

    /// End-to-end backend wiring: owner A and participant B coexist, then a
    /// run and a subsequent .run-role open must both name A, never B.
    func testRunAndNextOpenNameTheObservedOwnerNotAParticipant() async throws {
        let (backend, transport) = makeBackend()
        let workspace = try root()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let conversation = UUID()

        let opens = OpenReplyOrdinal()
        transport.startReply = { request in
            if request.hostLeaseRole == .agent {
                return LinuxShellStartReply(sessionID: "engine-run", environmentID: "env-shared",
                                            runtimeGeneration: "gen-1", workspaceOwner: false)
            }
            switch opens.next() {
            case 1:
                return LinuxShellStartReply(sessionID: "engine-a", environmentID: "env-shared",
                                            runtimeGeneration: "gen-1", workspaceOwner: true)
            case 2:
                return LinuxShellStartReply(sessionID: "engine-b", environmentID: "env-shared",
                                            runtimeGeneration: "gen-1", workspaceOwner: false)
            default:
                return LinuxShellStartReply(sessionID: "engine-c", environmentID: "env-shared",
                                            runtimeGeneration: "gen-1", workspaceOwner: false)
            }
        }
        transport.pollScript = { session, cursor, _ in
            session == "engine-run"
                ? FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "ok\n",
                                               state: .terminated, released: true, exit: 0,
                                               workspaceStatus: "synced")
                : nil
        }

        func open(_ session: String, role: LinuxShellLeaseRole = .interactive) async throws {
            _ = try await backend.openSession(ShellOpenRequest(
                command: "", cwd: ".", rootURL: workspace, environment: [:], columns: 80, rows: 24,
                gateTimeout: 2, sessionID: session, runID: UUID(), toolEnvironment: nil,
                conversationID: conversation, prepareLinuxIfMissing: false,
                leaseRole: role), cancellation: nil)
        }

        try await open("session-a")
        XCTAssertNil(transport.starts[0].workspaceReuse,
                     "the first session has no prior proven owner to name")
        try await open("session-b")
        XCTAssertEqual(transport.starts[1].workspaceReuse,
                       LinuxShellWorkspaceReuse.shared(ownerSessionID: "engine-a"),
                       "the participant open names the observed owner")

        let runRequest = ShellRunRequest(
            command: "echo ok", cwd: ".", rootURL: workspace, environment: [:], stdin: nil,
            timeout: 2, gateTimeout: 1, maxOutputBytes: 16 * 1024,
            sessionID: "run-owner-1", runID: UUID(), toolEnvironment: nil,
            conversationID: conversation)
        let outcome = await backend.run(runRequest, cancellation: nil)
        guard case .exited(let code, _, _, _, _, _) = outcome else {
            return XCTFail("expected the Agent command to settle, got \(outcome)")
        }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(transport.starts.last?.workspaceReuse,
                       LinuxShellWorkspaceReuse.shared(ownerSessionID: "engine-a"),
                       "the run names the proven owner even though participant B is also live")

        try await open("session-c", role: .run)
        XCTAssertEqual(transport.starts.last?.workspaceReuse,
                       LinuxShellWorkspaceReuse.shared(ownerSessionID: "engine-a"),
                       "the next open names the proven owner irrespective of survival order")
        XCTAssertFalse(transport.starts.contains {
            $0.workspaceReuse == LinuxShellWorkspaceReuse.shared(ownerSessionID: "engine-b")
        }, "a participant's lease id must never be minted as an owner hint")
    }

    /// With no session whose own reply proved workspaceOwner==true, the hint
    /// is omitted (the runtime resolves shared/deferred ownership itself)
    /// instead of naming a live participant.
    func testNoObservedOwnerOmitsTheReuseHint() async throws {
        let (backend, transport) = makeBackend()
        let workspace = try root()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let conversation = UUID()

        let opens = OpenReplyOrdinal()
        transport.startReply = { request in
            if request.hostLeaseRole == .agent {
                return LinuxShellStartReply(sessionID: "engine-run", environmentID: "env-shared",
                                            runtimeGeneration: "gen-1", workspaceOwner: false)
            }
            let engine = opens.next() == 1 ? "engine-b" : "engine-c"
            return LinuxShellStartReply(sessionID: engine, environmentID: "env-shared",
                                        runtimeGeneration: "gen-1", workspaceOwner: false)
        }
        transport.pollScript = { session, cursor, _ in
            session == "engine-run"
                ? FakeLinuxShellTransport.page(session: session, cursor: cursor, text: "ok\n",
                                               state: .terminated, released: true, exit: 0,
                                               workspaceStatus: "deferred")
                : nil
        }

        func open(_ session: String, role: LinuxShellLeaseRole) async throws {
            _ = try await backend.openSession(ShellOpenRequest(
                command: "", cwd: ".", rootURL: workspace, environment: [:], columns: 80, rows: 24,
                gateTimeout: 2, sessionID: session, runID: UUID(), toolEnvironment: nil,
                conversationID: conversation, prepareLinuxIfMissing: false,
                leaseRole: role), cancellation: nil)
        }

        try await open("session-b", role: .interactive)
        XCTAssertNil(transport.starts[0].workspaceReuse)

        let runRequest = ShellRunRequest(
            command: "echo ok", cwd: ".", rootURL: workspace, environment: [:], stdin: nil,
            timeout: 2, gateTimeout: 1, maxOutputBytes: 16 * 1024,
            sessionID: "run-owner-1", runID: UUID(), toolEnvironment: nil,
            conversationID: conversation)
        let outcome = await backend.run(runRequest, cancellation: nil)
        guard case .exited = outcome else {
            return XCTFail("expected the Agent command to settle, got \(outcome)")
        }
        XCTAssertNil(transport.starts.last?.workspaceReuse,
                     "a live participant is not a forged owner hint")

        try await open("session-c", role: .run)
        XCTAssertNil(transport.starts.last?.workspaceReuse,
                     "the next open also omits the hint with no proven owner")
    }
}
