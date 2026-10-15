// FloeExecutionTests — same-run client ownership for interactive shell
// sessions.
//
// The parent run and every delegated child of ONE task share a run id but are
// distinct trusted clients (`ToolContext.clientSessionID`: run:<uuid> /
// child:<uuid>; the model can never mint one). These regressions drive the
// REAL `ShellSessionCenter` and the REAL shell.open/exchange/close/signal
// tools over a recording backend and prove:
//
//  * three clients of one run — all presenting the same raw provider call id
//    `call_1`, as independent provider conversations legitimately may — each
//    open and use their OWN session; results stay isolated;
//  * a sibling's exchange/close/signal on another client's session is an
//    explicit `status=denied reason=session-owner-mismatch` (126) and NEVER
//    reaches the backend, while the owner's session stays alive;
//  * the typed center outcomes (`AccessOutcome`, `OwnerMismatch`) carry the
//    same refusal without any backend dispatch;
//  * nil-client legacy sessions (the existing UI/older callers) still work
//    for nil callers and are not reachable through a child client id;
//  * root-owned lifecycle cleanup (`closeAll(runID:)`) still closes every
//    session of the run regardless of which client opened it.

import Foundation
import XCTest
import FloeCore
import FloeTools
@testable import FloeExecution

// MARK: - recording backend

/// Records every session operation that REACHES the backend, so the tests can
/// prove a denied cross-client call never dispatched (and an allowed one did).
private actor RecordingSessionBackend: LocalShellBackend {
    private(set) var opened: [String] = []
    private(set) var exchanges: [String] = []
    private(set) var closes: [String] = []
    private(set) var signals: [String] = []
    private(set) var resizes: [String] = []

    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        .failed(message: "the ownership regressions use interactive sessions only")
    }

    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        opened.append(request.sessionID)
        return ShellOpenResult(sessionID: request.sessionID, initialOutput: "ready\n", alive: true)
    }

    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        exchanges.append(request.sessionID)
        return ShellExchangeResult(
            output: "backend:\(request.sessionID)", alive: true, exitCode: nil,
            bytesRead: 1, bytesWritten: 2
        )
    }

    func closeSession(sessionID: String) async { closes.append(sessionID) }

    func signalSession(sessionID: String, signal: ShellSignal) async {
        signals.append("\(sessionID):\(signal.rawValue)")
    }

    func resizeSession(sessionID: String, columns: Int, rows: Int) async {
        resizes.append("\(sessionID):\(columns)x\(rows)")
    }
}

private func ownershipRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-session-ownership-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// The tool context one client would carry: same run, same raw provider call
/// id, runtime-issued client identity (nil = legacy/UI caller).
private func ownershipContext(
    runID: UUID,
    client: String?,
    callID: String,
    root: URL
) -> ToolContext {
    ToolContext(
        runID: runID,
        toolCallID: callID,
        scope: .local,
        workspaceRootURL: root,
        cancellation: CancellationToken(),
        clientSessionID: client
    )
}

// MARK: - same-run client ownership

final class ShellSessionOwnershipTests: XCTestCase {
    /// Parent + two full-power children of ONE task, all with the same raw
    /// provider call id `call_1`: sessions are per client, cross-client
    /// exchange/close/signal is denied before the backend sees anything, and
    /// the owner's session keeps working while siblings are refused.
    func testThreeClientsOfOneRunWithIdenticalCallIDOwnIsolatedSessions() async throws {
        let root = try ownershipRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = RecordingSessionBackend()
        let center = ShellSessionCenter(backend: backend)
        let runID = UUID()
        let clients = [
            "run:\(runID.uuidString)",
            "child:\(UUID().uuidString)",
            "child:\(UUID().uuidString)",
        ]
        let contexts = clients.map {
            ownershipContext(runID: runID, client: $0, callID: "call_1", root: root)
        }
        let openTool = ShellOpenTool(center: center)
        let exchangeTool = ShellExchangeTool(center: center)
        let closeTool = ShellCloseTool(center: center)
        let signalTool = ShellSignalTool(center: center)

        // Each client opens its own session (distinct runtime-generated ids)
        // even though every context presents the same provider call id.
        var sessionByClient: [String: String] = [:]
        var known = Set<String>()
        for (client, context) in zip(clients, contexts) {
            let opened = try await openTool.execute(ShellOpenTool.Arguments(command: ""), context: context)
            XCTAssertEqual(opened.exitStatus, 0, "open must succeed for \(client): \(opened.summary)")
            let current = Set(await center.activeSessionIDs(runID: runID))
            let fresh = current.subtracting(known)
            XCTAssertEqual(fresh.count, 1, "each client's open adds exactly one live session")
            sessionByClient[client] = fresh.first
            known = current
        }
        XCTAssertEqual(sessionByClient.count, 3)

        // Every owner reaches its OWN session, and only its own result comes
        // back (the backend echoes the session id).
        var ownerResults: [String] = []
        for (client, context) in zip(clients, contexts) {
            let session = try XCTUnwrap(sessionByClient[client])
            let result = try await exchangeTool.execute(
                ShellExchangeTool.Arguments(sessionID: session, input: "echo own\n"),
                context: context
            )
            XCTAssertEqual(result.exitStatus, 0)
            XCTAssertTrue(
                result.summary.contains("output:\nbackend:\(session)"),
                "owner \(client) must read its own session, got: \(result.summary)"
            )
            ownerResults.append(session)
        }
        let exchangesAfterOwners = await backend.exchanges
        XCTAssertEqual(exchangesAfterOwners.sorted(), ownerResults.sorted())

        // A sibling (and the parent, for the children's sessions) cannot
        // touch another client's session: explicit denial, no dispatch.
        let ownerClient = clients[0]
        let ownerSession = try XCTUnwrap(sessionByClient[ownerClient])
        for (intruder, context) in zip(clients.dropFirst(), contexts.dropFirst()) {
            let exchange = try await exchangeTool.execute(
                ShellExchangeTool.Arguments(sessionID: ownerSession, input: "echo hijack\n"),
                context: context
            )
            XCTAssertEqual(exchange.exitStatus, 126)
            XCTAssertTrue(exchange.summary.contains("status=denied reason=session-owner-mismatch"),
                          "sibling \(intruder) exchange: \(exchange.summary)")
            XCTAssertFalse(exchange.summary.contains("backend:\(ownerSession)"),
                           "a denied exchange must never return the other client's output")

            let close = try await closeTool.execute(ShellCloseTool.Arguments(sessionID: ownerSession), context: context)
            XCTAssertEqual(close.exitStatus, 126)
            XCTAssertTrue(close.summary.contains("reason=session-owner-mismatch"))

            let signal = try await signalTool.execute(
                ShellSignalTool.Arguments(sessionID: ownerSession, signal: "KILL"),
                context: context
            )
            XCTAssertEqual(signal.exitStatus, 126)
            XCTAssertTrue(signal.summary.contains("reason=session-owner-mismatch"))
        }
        let exchangesAfterDenials = await backend.exchanges
        XCTAssertEqual(exchangesAfterDenials, exchangesAfterOwners,
                       "no denied exchange may reach the backend")
        let closesAfterDenials = await backend.closes
        XCTAssertEqual(closesAfterDenials, [], "no denied close may reach the backend")
        let signalsAfterDenials = await backend.signals
        XCTAssertEqual(signalsAfterDenials, [], "no denied signal may reach the backend")
        let liveAfterDenials = Set(await center.activeSessionIDs(runID: runID))
        XCTAssertEqual(liveAfterDenials, known, "every owner session must survive the sibling attempts")

        // Typed center-level refusals without any backend dispatch, including
        // the plain exchange that must throw rather than return an empty
        // result.
        let childClient = clients[1]
        let closeOutcome = await center.close(sessionID: ownerSession, runID: runID, clientSessionID: childClient)
        XCTAssertEqual(closeOutcome, .ownerMismatch)
        let signalOutcome = await center.signal(sessionID: ownerSession, signal: .kill, runID: runID, clientSessionID: childClient)
        XCTAssertEqual(signalOutcome, .ownerMismatch)
        let resizeOutcome = await center.resize(sessionID: ownerSession, columns: 100, rows: 30, runID: runID, clientSessionID: childClient)
        XCTAssertEqual(resizeOutcome, .ownerMismatch)
        do {
            _ = try await center.exchange(
                sessionID: ownerSession, input: nil, waitMs: 50, maxBytes: 1024,
                runID: runID, cancellation: nil, clientSessionID: childClient
            )
            XCTFail("a cross-client exchange must throw")
        } catch let mismatch as ShellSessionCenter.OwnerMismatch {
            XCTAssertEqual(mismatch.sessionID, ownerSession)
        }
        let exchangesAfterTypedDenials = await backend.exchanges
        XCTAssertEqual(exchangesAfterTypedDenials, exchangesAfterOwners)

        // The owner can close its own session; the backend sees exactly that
        // close, and each remaining client closes its own session only.
        let ownerClose = try await closeTool.execute(ShellCloseTool.Arguments(sessionID: ownerSession), context: contexts[0])
        XCTAssertEqual(ownerClose.exitStatus, 0)
        let closesAfterOwner = await backend.closes
        XCTAssertEqual(closesAfterOwner, [ownerSession])
        for (client, context) in zip(clients.dropFirst(), contexts.dropFirst()) {
            let session = try XCTUnwrap(sessionByClient[client])
            let close = try await closeTool.execute(ShellCloseTool.Arguments(sessionID: session), context: context)
            XCTAssertEqual(close.exitStatus, 0)
        }
        let liveAtEnd = await center.activeSessionIDs(runID: runID)
        XCTAssertTrue(liveAtEnd.isEmpty)
        let allCloses = Set(await backend.closes)
        XCTAssertEqual(allCloses, Set(sessionByClient.values))
    }

    /// Nil-client sessions (the existing UI terminals and older callers) keep
    /// their previous nil→nil behavior, are not reachable through a child
    /// client id, and root-owned lifecycle cleanup still closes every session
    /// of the run whichever client opened it.
    func testLegacyNilClientSessionStaysUsableAndRootCleanupClosesEveryClient() async throws {
        let root = try ownershipRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = RecordingSessionBackend()
        let center = ShellSessionCenter(backend: backend)
        let runID = UUID()
        let childID = "child:\(UUID().uuidString)"

        // Legacy caller: opens with no client identity, exactly as
        // LocalTerminalOwner/IDEWorkbenchState do today.
        let legacy = try await center.open(
            command: "", cwd: ".", environment: [:], columns: 80, rows: 24,
            runID: runID, rootURL: root, cancellation: nil
        )
        XCTAssertTrue(legacy.alive)
        let exchanged = try await center.exchange(
            sessionID: legacy.sessionID, input: nil, waitMs: 50, maxBytes: 1024,
            runID: runID, cancellation: nil
        )
        XCTAssertEqual(exchanged.output, "backend:\(legacy.sessionID)")
        let legacySignal = await center.signal(sessionID: legacy.sessionID, signal: .interrupt, runID: runID)
        XCTAssertEqual(legacySignal, .applied)
        let legacyResize = await center.resize(sessionID: legacy.sessionID, columns: 100, rows: 30, runID: runID)
        XCTAssertEqual(legacyResize, .applied)
        let signalCount = await backend.signals.count
        XCTAssertEqual(signalCount, 1)
        let resizeCount = await backend.resizes.count
        XCTAssertEqual(resizeCount, 1)

        // The nil identity is not a wildcard: a child client is refused.
        let childClose = await center.close(sessionID: legacy.sessionID, runID: runID, clientSessionID: childID)
        XCTAssertEqual(childClose, .ownerMismatch)
        do {
            _ = try await center.exchange(
                sessionID: legacy.sessionID, input: nil, waitMs: 50, maxBytes: 1024,
                runID: runID, cancellation: nil, clientSessionID: childID
            )
            XCTFail("a child client must not exchange a legacy nil-owned session")
        } catch is ShellSessionCenter.OwnerMismatch {
            // expected
        }
        let legacyStillLive = await center.activeSessionIDs(runID: runID)
        XCTAssertTrue(legacyStillLive.contains(legacy.sessionID),
                      "the refused child must leave the legacy session alive")

        // Parent- and child-owned sessions on the same run; root-owned
        // cleanup closes all three (legacy + parent + child) in one sweep.
        let openTool = ShellOpenTool(center: center)
        let parentContext = ownershipContext(runID: runID, client: "run:\(runID.uuidString)", callID: "call_1", root: root)
        let childContext = ownershipContext(runID: runID, client: childID, callID: "call_1", root: root)
        let parentOpen = try await openTool.execute(ShellOpenTool.Arguments(command: ""), context: parentContext)
        XCTAssertEqual(parentOpen.exitStatus, 0)
        let childOpen = try await openTool.execute(ShellOpenTool.Arguments(command: ""), context: childContext)
        XCTAssertEqual(childOpen.exitStatus, 0)
        let liveBeforeCleanup = await center.activeSessionIDs(runID: runID)
        XCTAssertEqual(liveBeforeCleanup.count, 3)

        await center.closeAll(runID: runID)
        let liveAfterCleanup = await center.activeSessionIDs(runID: runID)
        XCTAssertTrue(liveAfterCleanup.isEmpty)
        let closed = Set(await backend.closes)
        XCTAssertEqual(closed.count, 3, "root cleanup closes every client's session")
        let opened = Set(await backend.opened)
        XCTAssertEqual(closed, opened, "every opened session was torn down")
    }
}
