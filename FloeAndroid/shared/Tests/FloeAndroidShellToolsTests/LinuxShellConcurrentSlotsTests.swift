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
}
