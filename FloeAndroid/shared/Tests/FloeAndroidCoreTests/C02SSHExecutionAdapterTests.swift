// SPDX-License-Identifier: MPL-2.0
//
// C02 SSH execution adapter tests. AUTHORED, NOT RUN by this lane. They use
// a deterministic in-process fake transport to prove dispatch/outcome/receipt
// and session-ownership semantics; no real SSH server, credential, network or
// device participates.
import XCTest
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeSSH
import FloeTools
@testable import FloeAndroidCore

final class C02SSHExecutionAdapterTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let database: DatabaseManager
        let store: C02SQLiteExecutionTargetStore
        let hostStore: RemoteHostStore
        let taskID: UUID
        let runID: UUID
        let hostID: UUID
        let target: C02ExecutionTarget
        let profile: RemoteHostProfile
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("c02-ssh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let database = try DatabaseManager(path: root.appendingPathComponent("db.sqlite"))
        try await database.migrate()
        try await database.writer { db in
            for statement in C02ExecutionTargetSchema.createStatements {
                try db.execute(sql: statement)
            }
        }
        let taskID = UUID()
        let conversation = ConversationRecord(
            id: taskID, title: "Remote task",
            createdAt: Date(), updatedAt: Date(), purpose: .ordinary)
        try await SQLiteConversationStore(database: database).saveConversation(conversation)
        let runID = UUID()
        try await SQLiteRunStore(database: database).saveRun(RunRecord(
            id: runID, conversationID: taskID, state: "running",
            goal: "test", startedAt: Date()))
        let hostID = UUID()
        let profile = RemoteHostProfile(
            id: hostID,
            displayName: "Test SSH",
            address: "127.0.0.1",
            port: 22,
            user: "floe",
            auth: .password(SecretReference(
                keychainAccount: "floe.c02.test", synchronizable: false))
        )
        let hostStore = RemoteHostStore(database: database)
        try await hostStore.saveHost(profile.storedHost())
        let target = C02ExecutionTarget(
            taskID: taskID,
            revision: 1,
            kind: .ssh,
            environmentID: C02RemoteEnvironmentID.make(
                hostID: hostID,
                remoteRootPath: "/home/floe/.floe/tasks/\(taskID.uuidString.lowercased())"),
            projectID: nil,
            workspaceID: UUID(),
            shellRootHash: String(repeating: "a", count: 64),
            engineOwnerHash: String(repeating: "b", count: 64),
            rootEpoch: 7,
            remote: C02RemoteEnvironmentFacts(
                hostID: hostID,
                remoteRootPath: "/home/floe/.floe/tasks/\(taskID.uuidString.lowercased())",
                operatingSystem: "linux",
                architecture: "aarch64",
                runtimeGeneration: "boot-1",
                distribution: "debian"),
            provenance: .explicitUserSelection,
            createdAt: Date(),
            updatedAt: Date()
        )
        let store = C02SQLiteExecutionTargetStore(database: database)
        _ = try await store.pinRun(C02RunTargetPin(
            runID: runID,
            taskID: taskID,
            targetRevision: target.revision,
            environmentID: target.environmentID,
            shellRootHash: target.shellRootHash,
            engineOwnerHash: target.engineOwnerHash,
            rootEpoch: 7,
            pinnedAt: Date()
        ))
        do {
            try await body(Fixture(
                root: root,
                database: database,
                store: store,
                hostStore: hostStore,
                taskID: taskID,
                runID: runID,
                hostID: hostID,
                target: target,
                profile: profile
            ))
            try await database.close()
            try? FileManager.default.removeItem(at: root)
        } catch {
            try? await database.close()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private final class FakeExec: SSHSessionExec, @unchecked Sendable {
        let events: AsyncThrowingStream<SSHExecEvent, Error>
        private let continuation: AsyncThrowingStream<SSHExecEvent, Error>.Continuation
        private let lock = NSLock()
        private var cancelled = false

        init() {
            let pair = AsyncThrowingStream<SSHExecEvent, Error>.makeStream()
            events = pair.stream
            continuation = pair.continuation
        }

        func yield(_ event: SSHExecEvent) { continuation.yield(event) }
        func finish() { continuation.finish() }
        func fail(_ error: Error) { continuation.finish(throwing: error) }
        func cancel() {
            lock.lock(); cancelled = true; lock.unlock()
            continuation.finish()
        }
    }

    private final class FakeTransport: SSHSessionTransport, @unchecked Sendable {
        let exec: FakeExec
        private let lock = NSLock()
        private var connected = true
        private(set) var openCount = 0
        private(set) var closeCount = 0
        private(set) var lastCommand: String?
        private let openFailure: Error?

        init(exec: FakeExec, openFailure: Error? = nil) {
            self.exec = exec
            self.openFailure = openFailure
        }

        var isConnected: Bool {
            lock.lock(); defer { lock.unlock() }; return connected
        }

        func openPTY(term: String, columns: Int, rows: Int) async throws -> any SSHSessionPTY {
            throw TestError.unsupported
        }

        func openExec(_ command: String) async throws -> any SSHSessionExec {
            lock.lock(); openCount += 1; lastCommand = command; lock.unlock()
            if let openFailure { throw openFailure }
            return exec
        }

        func openDirectTCPIP(host: String, port: Int) async throws -> any SSHSessionByteChannel {
            throw TestError.unsupported
        }

        func close() async {
            lock.lock(); connected = false; closeCount += 1; lock.unlock()
        }
    }

    private struct FakeConnector: SSHTransportConnecting {
        let transport: FakeTransport
        let failure: SSHConnectionError?

        func connectTransport(
            profile: RemoteHostProfile,
            credentialResolver: @escaping SSHCredentialResolver,
            hostKeyDecision: @escaping HostKeyDecisionHandler
        ) async throws -> any SSHSessionTransport {
            if let failure { throw failure }
            return transport
        }
    }

    private enum TestError: Error {
        case unsupported
        case streamLost
    }

    private func makeAuthorization(
        fixture: Fixture,
        target: C02ExecutionTarget? = nil,
        targetRevision: Int64? = nil,
        sessionID: String? = nil,
        sessionOwnerToken: String? = nil
    ) -> C02SSHExecutionAuthorization {
        let chosen = target ?? fixture.target
        return C02SSHExecutionAuthorization(
            taskID: fixture.taskID,
            runID: fixture.runID,
            target: chosen,
            targetRevision: targetRevision ?? chosen.revision,
            rootEpoch: 7,
            ownerToken: "owner-token-0123456789",
            sessionID: sessionID,
            sessionOwnerToken: sessionOwnerToken,
            approvedHostKeyFingerprint: nil,
            permissionGrantID: UUID(),
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(60)
        )
    }

    private func makeRequest(
        fixture: Fixture,
        authorization: C02SSHExecutionAuthorization? = nil,
        command: String = "echo hello",
        timeout: TimeInterval = 5
    ) -> C02SSHExecutionRequest {
        C02SSHExecutionRequest(
            operationID: "run:\(fixture.runID.uuidString):call:call_1",
            authorization: authorization ?? makeAuthorization(fixture: fixture),
            command: command,
            cwd: ".",
            environment: [:],
            stdin: nil,
            timeout: timeout,
            maxOutputBytes: 64 * 1_024,
            cancellation: CancellationToken()
        )
    }

    private func makeAdapter(
        fixture: Fixture,
        connector: FakeConnector
    ) -> C02SSHExecutionAdapter {
        C02SSHExecutionAdapter(
            hostStore: fixture.hostStore,
            connectorFactory: { _ in connector },
            credentialResolver: { _ in Data("password".utf8) },
            pins: fixture.store,
            receipts: fixture.store
        )
    }

    private func waitForOpen(_ transport: FakeTransport) async throws {
        for _ in 0..<100 {
            if transport.openCount > 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("adapter never opened the exec channel")
    }

    func testNormalRemoteExitUsesRealExitAndImmutableReceipt() async throws {
        try await withFixture { fixture in
            let exec = FakeExec()
            let transport = FakeTransport(exec: exec)
            let adapter = makeAdapter(fixture: fixture, connector: FakeConnector(
                transport: transport, failure: nil))
            let task = Task { try await adapter.execute(makeRequest(fixture: fixture)) }
            try await waitForOpen(transport)
            exec.yield(.stdout(Data("hello\n".utf8)))
            exec.yield(.stderr(Data("warn\n".utf8)))
            exec.yield(.exited(7))
            let result = try await task.value
            guard case .exited(let code) = result.state else {
                return XCTFail("expected real exit, got \(result.state)")
            }
            XCTAssertEqual(code, 7)
            XCTAssertEqual(result.stdout, "hello\n")
            XCTAssertEqual(result.stderr, "warn\n")
            XCTAssertEqual(result.stopProof, .remoteExited)
            XCTAssertTrue(result.receiptPersisted)
            XCTAssertEqual(result.receiptState, .exited)
            let receipt = try await fixture.store.receipt(
                operationID: "run:\(fixture.runID.uuidString):call:call_1")
            XCTAssertEqual(receipt?.state, .exited)
            XCTAssertEqual(receipt?.exitCode, 7)
            let command = try XCTUnwrap(transport.lastCommand)
            XCTAssertTrue(command.hasPrefix("umask 077 && mkdir -p '/home/floe/.floe/tasks/"))
            XCTAssertTrue(command.contains("/bin/sh -lc 'echo hello'"))
        }
    }

    func testTransportLossAfterDispatchIsOutcomeUnknownNeverCleanExit() async throws {
        try await withFixture { fixture in
            let exec = FakeExec()
            let transport = FakeTransport(exec: exec)
            let adapter = makeAdapter(fixture: fixture, connector: FakeConnector(
                transport: transport, failure: nil))
            let request = makeRequest(fixture: fixture, command: "sleep 30")
            let task = Task { try await adapter.execute(request) }
            try await waitForOpen(transport)
            exec.yield(.stdout(Data("partial".utf8)))
            exec.fail(TestError.streamLost)
            let result = try await task.value
            guard case .outcomeUnknown = result.state else {
                return XCTFail("transport loss must be unknown, got \(result.state)")
            }
            XCTAssertEqual(result.stopProof, .unknownRemoteState)
            XCTAssertEqual(result.receiptState, .outcomeUnknown)
            let receipt = try await fixture.store.receipt(operationID: request.operationID)
            XCTAssertEqual(receipt?.state, .outcomeUnknown)
        }
    }

    func testTimeoutIsUnknownRemoteStateNotAStopProof() async throws {
        try await withFixture { fixture in
            let exec = FakeExec()
            let transport = FakeTransport(exec: exec)
            let adapter = makeAdapter(fixture: fixture, connector: FakeConnector(
                transport: transport, failure: nil))
            let request = makeRequest(fixture: fixture, command: "sleep 999", timeout: 0.1)
            let task = Task { try await adapter.execute(request) }
            try await waitForOpen(transport)
            let result = try await task.value
            guard case .timedOut = result.state else {
                return XCTFail("expected timeout, got \(result.state)")
            }
            XCTAssertEqual(result.stopProof, .unknownRemoteState)
            XCTAssertEqual(result.receiptState, .timedOut)
            XCTAssertTrue(result.dispatched)
        }
    }

    func testChannelOpenFailureClosesThePreDispatchReceiptAsNotStarted() async throws {
        try await withFixture { fixture in
            let exec = FakeExec()
            let transport = FakeTransport(exec: exec, openFailure: TestError.unsupported)
            let adapter = makeAdapter(fixture: fixture, connector: FakeConnector(
                transport: transport, failure: nil))
            do {
                _ = try await adapter.execute(makeRequest(fixture: fixture))
                XCTFail("a missing channel must not look dispatched")
            } catch let error as C02SSHAdapterError {
                guard case .notStarted = error else {
                    return XCTFail("unexpected error \(error)")
                }
            }
            let receipt = try await fixture.store.receipt(
                operationID: "run:\(fixture.runID.uuidString):call:call_1")
            XCTAssertEqual(receipt?.state, .notStarted)
            XCTAssertNil(receipt?.exitCode)
        }
    }

    func testHostKeyChallengeIsTypedAndNoReceiptIsWritten() async throws {
        try await withFixture { fixture in
            let challenge = HostKeyChallenge(
                hostID: fixture.hostID,
                address: "127.0.0.1",
                port: 22,
                keyType: "ssh-ed25519",
                fingerprintSHA256: "SHA256:abcdefghijklmnopqrstuvwxyz0123456789"
            )
            let exec = FakeExec()
            let transport = FakeTransport(exec: exec)
            let adapter = makeAdapter(fixture: fixture, connector: FakeConnector(
                transport: transport,
                failure: .hostKeyRejected(challenge)))
            do {
                _ = try await adapter.execute(makeRequest(fixture: fixture))
                XCTFail("first-use key must not be trusted implicitly")
            } catch let error as C02SSHAdapterError {
                guard case .hostKeyApprovalRequired(let surfaced) = error else {
                    return XCTFail("unexpected error \(error)")
                }
                XCTAssertEqual(surfaced.hostID, fixture.hostID)
                XCTAssertEqual(surfaced.kind, .firstUse)
            }
            let receipt = try await fixture.store.receipt(
                operationID: "run:\(fixture.runID.uuidString):call:call_1")
            XCTAssertNil(receipt)
        }
    }

    func testSessionIDAloneCannotRebindAnotherOwnedSession() async throws {
        try await withFixture { fixture in
            let exec = FakeExec()
            let transport = FakeTransport(exec: exec)
            let adapter = makeAdapter(fixture: fixture, connector: FakeConnector(
                transport: transport, failure: nil))
            let firstTask = Task { try await adapter.execute(makeRequest(fixture: fixture)) }
            try await waitForOpen(transport)
            exec.yield(.exited(0))
            _ = try await firstTask.value
            let sessionIDs = await adapter.sessionIDs(taskID: fixture.taskID)
            let sessionID = try XCTUnwrap(sessionIDs.first)
            let forged = makeAuthorization(
                fixture: fixture,
                sessionID: sessionID,
                sessionOwnerToken: "wrong-owner-token"
            )
            do {
                _ = try await adapter.execute(makeRequest(
                    fixture: fixture, authorization: forged, command: "id"))
                XCTFail("a supplied sessionID without the exact owner grant must be refused")
            } catch let error as C02SSHAdapterError {
                XCTAssertEqual(error, .sessionRebindRefused)
            }
        }
    }

    func testRunPinMismatchRefusesBeforeDispatch() async throws {
        try await withFixture { fixture in
            let exec = FakeExec()
            let transport = FakeTransport(exec: exec)
            let adapter = makeAdapter(fixture: fixture, connector: FakeConnector(
                transport: transport, failure: nil))
            let wrongTarget = C02ExecutionTarget(
                taskID: fixture.target.taskID,
                revision: 2,
                kind: .ssh,
                environmentID: fixture.target.environmentID,
                projectID: fixture.target.projectID,
                workspaceID: fixture.target.workspaceID,
                shellRootHash: fixture.target.shellRootHash,
                engineOwnerHash: fixture.target.engineOwnerHash,
                rootEpoch: fixture.target.rootEpoch,
                remote: fixture.target.remote,
                provenance: .migrated,
                createdAt: fixture.target.createdAt,
                updatedAt: fixture.target.updatedAt
            )
            let forged = makeAuthorization(fixture: fixture, target: wrongTarget)
            do {
                _ = try await adapter.execute(makeRequest(
                    fixture: fixture, authorization: forged))
                XCTFail("a run pin at revision 1 must not authorize revision 2")
            } catch let error as C02SSHAdapterError {
                XCTAssertEqual(error, .runPinMismatch)
            }
            XCTAssertEqual(transport.openCount, 0)
        }
    }

    func testCommandBuilderUsesExplicitRootCwdEnvironmentAndStdin() throws {
        let script = try C02RemoteCommandBuilder.build(
            command: "printf '%s' \"$A\"",
            remoteRootPath: "/srv/floe/task",
            cwd: "sub dir",
            environment: ["A": "b c", "EMPTY": ""],
            stdin: "hello",
            operatingSystem: "linux"
        )
        XCTAssertTrue(script.hasPrefix(
            "umask 077 && mkdir -p '/srv/floe/task' && cd '/srv/floe/task' && cd 'sub dir' && printf %s 'aGVsbG8=' | base64 -d | env "))
        XCTAssertTrue(script.contains("'A=b c'"))
        XCTAssertTrue(script.contains("'EMPTY='"))
        XCTAssertTrue(script.hasSuffix("/bin/sh -lc 'printf '\\''%s'\\'' \"$A\"'"))
        XCTAssertThrowsError(try C02RemoteCommandBuilder.build(
            command: "id", remoteRootPath: "/srv/task", cwd: "../escape",
            environment: [:], stdin: nil, operatingSystem: "linux"))
        XCTAssertThrowsError(try C02RemoteCommandBuilder.build(
            command: "id", remoteRootPath: "/srv/task", cwd: ".",
            environment: ["BAD KEY": "x"], stdin: nil, operatingSystem: "linux"))
        XCTAssertThrowsError(try C02RemoteCommandBuilder.build(
            command: "id", remoteRootPath: "/srv/../escape", cwd: ".",
            environment: [:], stdin: nil, operatingSystem: "linux"))
    }
}
