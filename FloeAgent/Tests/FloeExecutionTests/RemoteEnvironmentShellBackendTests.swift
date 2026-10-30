// FloeExecutionTests — pinned remote-SSH shell backend contract.
//
// Authored regressions (source/static lane: not executed here) cover the
// routing authority, no-fallback behavior, cancellation, full-output/small-
// preview, oversized staging, after-sync unknown outcome, PTY ownership and
// late-session/new-generation rejection.

import Foundation
import Testing
import FloeCore
import FloeTools
import FloeSSH
@testable import FloeExecution

// MARK: - Fakes

private struct FakeChunk: Sendable {
    var channel: SSHStreamChannel
    var data: Data
}

private struct FakeExecutionReply: Sendable {
    var result: SSHStreamExecResult
    var chunks: [FakeChunk] = []
    var failure: SSHStreamExecFailure?
}

private struct FakeExecution: Sendable, Equatable {
    var command: String
    var deadline: SSHStreamExecDeadline
    var previewLimit: Int
}

private final class FakeRemoteShellPTY: SSHRemoteShellPTY, @unchecked Sendable {
    let output: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let lock = NSLock()
    private var writtenData: [Data] = []
    private var resizeSizes: [(columns: Int, rows: Int)] = []
    private var response: Data?
    private var closedFlag = false

    init(initial: Data = Data()) {
        var captured: AsyncThrowingStream<Data, Error>.Continuation!
        self.output = AsyncThrowingStream { captured = $0 }
        self.continuation = captured
        if !initial.isEmpty { captured.yield(initial) }
    }

    var written: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return writtenData
    }

    var resized: [(columns: Int, rows: Int)] {
        lock.lock()
        defer { lock.unlock() }
        return resizeSizes
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedFlag
    }

    func setResponse(_ data: Data?) {
        lock.lock()
        response = data
        lock.unlock()
    }

    func write(_ data: Data) async throws {
        let reply = lock.withLock { writtenData.append(data); return response }
        if let reply, !reply.isEmpty { continuation.yield(reply) }
    }

    func resize(columns: Int, rows: Int) async throws {
        lock.withLock { resizeSizes.append((columns, rows)) }
    }

    func close() async {
        let shouldFinish = lock.withLock { if closedFlag { return false }; closedFlag = true; return true }
        if shouldFinish { continuation.finish() }
    }
}

private final class FakeRemoteShellConnection: SSHRemoteShellConnection, @unchecked Sendable {
    typealias Handler = @Sendable (String) async throws -> FakeExecutionReply

    private let pty: FakeRemoteShellPTY
    private let handler: Handler
    private let lock = NSLock()
    private var executions: [FakeExecution] = []
    private var closedFlag = false

    init(
        pty: FakeRemoteShellPTY = FakeRemoteShellPTY(),
        handler: @escaping Handler = { _ in FakeExecutionReply(result: SSHStreamExecResult()) }
    ) {
        self.pty = pty
        self.handler = handler
    }

    var isConnected: Bool { true }

    var recordedExecutions: [FakeExecution] {
        lock.lock()
        defer { lock.unlock() }
        return executions
    }

    var recordedCommands: [String] { recordedExecutions.map(\.command) }
    var recordedDeadlines: [SSHStreamExecDeadline] { recordedExecutions.map(\.deadline) }
    var userExecutionCount: Int {
        recordedCommands.filter { $0.contains("/bin/sh") }.count
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedFlag
    }

    func executeStreaming(
        _ command: String,
        deadline: SSHStreamExecDeadline,
        cancellation: CancellationToken?,
        maxPreviewBytes: Int,
        onOutput: @escaping SSHRemoteShellOutputHandler
    ) async throws -> SSHStreamExecResult {
        let execution = FakeExecution(command: command, deadline: deadline, previewLimit: maxPreviewBytes)
        lock.withLock { executions.append(execution) }
        let reply = try await handler(command)
        for chunk in reply.chunks {
            try await onOutput(chunk.channel, chunk.data)
        }
        if let failure = reply.failure { throw failure }
        return reply.result
    }

    func openRemotePTY(term: String, columns: Int, rows: Int) async throws -> any SSHRemoteShellPTY {
        pty
    }

    func close() async {
        lock.withLock { closedFlag = true }
    }
}

private final class FakeDefaultBackend: LocalShellBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var runCountStorage = 0
    private var closeCountStorage = 0

    var runCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return runCountStorage
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closeCountStorage
    }

    func normalizedRunDeadline(_ requested: ShellExecutionDeadline) -> ShellExecutionDeadline {
        requested
    }

    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        lock.withLock { runCountStorage += 1 }
        return .exited(
            code: 0,
            stdout: "default",
            stderr: "",
            truncated: false,
            stderrTruncated: false,
            durationMs: 0
        )
    }

    func openSession(
        _ request: ShellOpenRequest,
        cancellation: CancellationToken?
    ) async throws -> ShellOpenResult {
        ShellOpenResult(sessionID: request.sessionID, initialOutput: "", alive: true, terminalOutput: Data())
    }

    func exchangeSession(
        _ request: ShellExchangeRequest,
        cancellation: CancellationToken?
    ) async throws -> ShellExchangeResult {
        ShellExchangeResult(output: "default", alive: true)
    }

    func closeSession(sessionID: String) async {
        lock.withLock { closeCountStorage += 1 }
    }

    func signalSession(sessionID: String, signal: ShellSignal) async {}
    func resizeSession(sessionID: String, columns: Int, rows: Int) async {}
}

private actor TargetState {
    private var resolution: SSHShellTargetResolution

    init(_ resolution: SSHShellTargetResolution) {
        self.resolution = resolution
    }

    func current() -> SSHShellTargetResolution { resolution }
    func set(_ value: SSHShellTargetResolution) { resolution = value }
}

private actor HostRecorder {
    private var hosts: [UUID] = []
    func record(_ hostID: UUID) { hosts.append(hostID) }
    func snapshot() -> [UUID] { hosts }
}

private actor SyncRecorder {
    private var phases: [RemoteWorkspaceSyncPhase] = []
    private var failOn: RemoteWorkspaceSyncPhase?

    func setFailure(_ phase: RemoteWorkspaceSyncPhase?) { failOn = phase }

    func record(_ phase: RemoteWorkspaceSyncPhase) throws {
        phases.append(phase)
        if failOn == phase { throw FloeError.validationFailed("simulated sync failure") }
    }

    func snapshot() -> [RemoteWorkspaceSyncPhase] { phases }
}

// MARK: - Helpers

private func makeTarget(
    hostID: UUID = UUID(),
    environmentID: String = "env-ssh",
    root: String = "/remote/task",
    generation: String = "1"
) -> SSHShellTarget {
    guard let target = SSHShellTarget(
        hostID: hostID,
        remoteTaskRoot: root,
        environmentID: environmentID,
        generation: generation
    ) else {
        preconditionFailure("test target constants must be valid")
    }
    return target
}

private func makeToolEnvironment(_ id: String, root: URL) -> ToolEnvironment {
    ToolEnvironment(id: id, writableLayerURL: root, layerURLs: [], variables: [:])
}

private func makeRequest(
    root: URL,
    environmentID: String = "env-ssh",
    command: String = "echo hello",
    stdin: String? = nil,
    deadline: ShellExecutionDeadline = .unlimited,
    maxOutputBytes: Int = 1024
) -> ShellRunRequest {
    ShellRunRequest(
        command: command,
        cwd: ".",
        rootURL: root,
        environment: [:],
        stdin: stdin,
        deadline: deadline,
        gateTimeout: 5,
        maxOutputBytes: maxOutputBytes,
        sessionID: "shell-session",
        runID: UUID(),
        toolEnvironment: makeToolEnvironment(environmentID, root: root)
    )
}

private func makeTempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("floe-ssh-shell-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeConnection(
    pty: FakeRemoteShellPTY = FakeRemoteShellPTY(),
    handler: @escaping FakeRemoteShellConnection.Handler
) -> FakeRemoteShellConnection {
    FakeRemoteShellConnection(pty: pty, handler: handler)
}

// MARK: - Tests

@Suite("FloeExecution.RemoteEnvironmentShell")
struct RemoteEnvironmentShellBackendTests {

    @Test("selected SSH host is used and the default backend is never reached")
    func selectedTargetUsesTrustedHost() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        let target = makeTarget(hostID: hostID)
        let state = TargetState(.ssh(target))
        let hosts = HostRecorder()
        let connection = makeConnection { _ in
            let bytes = Data("ok".utf8)
            return FakeExecutionReply(
                result: SSHStreamExecResult(
                    exitCode: 0,
                    stdoutPreview: bytes,
                    stdoutBytes: Int64(bytes.count)
                ),
                chunks: [FakeChunk(channel: .stdout, data: bytes)]
            )
        }
        let defaultBackend = FakeDefaultBackend()
        let router = RemoteEnvironmentShellRouter(
            defaultBackend: defaultBackend,
            resolver: { _ in await state.current() },
            sessionFactory: { received in
                await hosts.record(received.hostID)
                return connection
            },
            outputRoot: root
        )
        var request = makeRequest(root: root)
        request.environment = [
            "FLOE_EXECUTION_BACKEND": "macBridge",
            "FLOE_ENVIRONMENT_ID": "spoofed",
            "FLOE_REMOTE_TASK_ROOT": "/tmp/spoofed",
            "FLOE_TARGET_GENERATION": "999",
            "PATH": "/local/bin",
            "HOME": "/local/home",
            "TMPDIR": "/local/tmp",
            "PS1": "local$ "
        ]
        let outcome = await router.run(request, cancellation: nil)
        guard case .exited(let code, let stdout, _, _, _, _) = outcome else {
            Issue.record("unexpected outcome: \(outcome)")
            return
        }
        #expect(code == 0)
        #expect(stdout == "ok")
        #expect(defaultBackend.runCount == 0)
        let recordedHosts = await hosts.snapshot()
        #expect(recordedHosts == [hostID])
        #expect(connection.recordedDeadlines == [.unlimited])
        let command = connection.recordedCommands.first ?? ""
        #expect(command.contains("FLOE_EXECUTION_BACKEND='ssh'"))
        #expect(command.contains("FLOE_ENVIRONMENT_ID='env-ssh'"))
        #expect(command.contains("FLOE_REMOTE_TASK_ROOT='/remote/task'"))
        #expect(command.contains("FLOE_TARGET_GENERATION='1'"))
        #expect(!command.contains("macBridge"))
        #expect(!command.contains("spoofed"))
        #expect(!command.contains("/local"))
        let facts = await router.targetFacts(environmentID: "env-ssh")
        #expect(facts?.isRemote == true)
        #expect(facts?.backendIdentifier == "remoteSSH")
        #expect(facts?.hostID == hostID)
        #expect(facts?.generation == "1")
    }

    @Test("an explicit unavailable SSH target fails without Linux or Mac fallback")
    func unavailableTargetDoesNotFallBack() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = TargetState(.unavailable(environmentID: "env-ssh", reason: "the pinned host is stopped"))
        let hosts = HostRecorder()
        let defaultBackend = FakeDefaultBackend()
        let router = RemoteEnvironmentShellRouter(
            defaultBackend: defaultBackend,
            resolver: { _ in await state.current() },
            sessionFactory: { target in
                await hosts.record(target.hostID)
                return makeConnection { _ in FakeExecutionReply(result: SSHStreamExecResult()) }
            },
            outputRoot: root
        )
        let outcome = await router.run(makeRequest(root: root), cancellation: nil)
        guard case .failed(let message) = outcome else {
            Issue.record("unexpected outcome: \(outcome)")
            return
        }
        #expect(message.contains("pinned host is stopped"))
        #expect(defaultBackend.runCount == 0)
        let recordedHosts = await hosts.snapshot()
        #expect(recordedHosts.isEmpty)
    }

    @Test("a non-SSH environment keeps the existing default backend")
    func notSSHUsesDefaultBackend() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let state = TargetState(.notSSH)
        let defaultBackend = FakeDefaultBackend()
        let router = RemoteEnvironmentShellRouter(
            defaultBackend: defaultBackend,
            resolver: { _ in await state.current() },
            sessionFactory: { _ in
                Issue.record("SSH factory must not be used for a non-SSH environment")
                return makeConnection { _ in FakeExecutionReply(result: SSHStreamExecResult()) }
            },
            outputRoot: root
        )
        let outcome = await router.run(
            makeRequest(root: root, environmentID: "env-native"),
            cancellation: nil
        )
        guard case .exited(let code, let stdout, _, _, _, _) = outcome else {
            Issue.record("unexpected outcome: \(outcome)")
            return
        }
        #expect(code == 0)
        #expect(stdout == "default")
        #expect(defaultBackend.runCount == 1)
    }

    @Test("a connect failure is not-started and never falls back")
    func connectFailureDoesNotFallBack() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = makeTarget()
        let state = TargetState(.ssh(target))
        let defaultBackend = FakeDefaultBackend()
        let router = RemoteEnvironmentShellRouter(
            defaultBackend: defaultBackend,
            resolver: { _ in await state.current() },
            sessionFactory: { _ in throw FloeError.validationFailed("host offline") },
            outputRoot: root
        )
        let outcome = await router.run(makeRequest(root: root), cancellation: nil)
        guard case .notStarted(let reason) = outcome else {
            Issue.record("unexpected outcome: \(outcome)")
            return
        }
        #expect(reason.contains("host offline"))
        #expect(defaultBackend.runCount == 0)
    }

    @Test("cancellation is terminal and does not run after-run synchronization")
    func cancellationIsTerminal() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = makeTarget()
        let state = TargetState(.ssh(target))
        let sync = SyncRecorder()
        let connection = makeConnection { _ in
            FakeExecutionReply(result: SSHStreamExecResult(), failure: .cancelled)
        }
        let backend = RemoteEnvironmentShellBackend(
            resolver: { _ in await state.current() },
            sessionFactory: { _ in connection },
            sync: RemoteWorkspaceSyncCallbacks { _, phase, _ in
                try await sync.record(phase)
            },
            outputRoot: root
        )
        let outcome = await backend.run(makeRequest(root: root), cancellation: CancellationToken())
        #expect(outcome == .cancelled)
        let phases = await sync.snapshot()
        #expect(phases == [.beforeRun])
    }

    @Test("closing SSH after dispatch is an unknown outcome, never proof of remote termination")
    func interruptedRemoteTerminationIsNotInvented() async throws {
        for failure: SSHStreamExecFailure in [.cancelled, .timedOut] {
            let root = try makeTempRoot()
            defer { try? FileManager.default.removeItem(at: root) }
            let target = makeTarget()
            let connection = makeConnection { command in
                if command.contains("DISPATCH_SENTINEL") {
                    return FakeExecutionReply(result: SSHStreamExecResult(), failure: failure)
                }
                return FakeExecutionReply(result: SSHStreamExecResult())
            }
            let sync = SyncRecorder()
            let backend = RemoteEnvironmentShellBackend(resolver: { _ in .ssh(target) },
                sessionFactory: { _ in connection },
                sync: RemoteWorkspaceSyncCallbacks { _, phase, _ in try await sync.record(phase) }, outputRoot: root)
            let result = await backend.run(makeRequest(root: root, command: "printf DISPATCH_SENTINEL"), cancellation: nil)
            guard case .outcomeUnknown(_, let reason) = result else {
                Issue.record("A dispatched SSH interruption must retain uncertain external state: \(result)")
                continue
            }
            #expect(reason.contains("after dispatch") || reason.contains("after dispatch;"))
            #expect(await sync.snapshot() == [.beforeRun])
            #expect(connection.isClosed)
        }
    }

    @Test("full output is saved to disk while the returned preview stays bounded")
    func fullOutputIsSavedWithSmallPreview() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = makeTarget()
        let state = TargetState(.ssh(target))
        let full = Data(repeating: 0x61, count: 3072)
        let warning = Data("warning\n".utf8)
        let connection = makeConnection { _ in
            FakeExecutionReply(
                result: SSHStreamExecResult(
                    exitCode: 0,
                    stdoutPreview: Data(full.prefix(248)),
                    stderrPreview: warning,
                    stdoutBytes: Int64(full.count),
                    stderrBytes: Int64(warning.count),
                    stdoutTruncated: true,
                    stderrTruncated: false
                ),
                chunks: [
                    FakeChunk(channel: .stderr, data: warning),
                    FakeChunk(channel: .stdout, data: Data(full.prefix(2048))),
                    FakeChunk(channel: .stdout, data: Data(full.dropFirst(2048)))
                ]
            )
        }
        let backend = RemoteEnvironmentShellBackend(
            resolver: { _ in await state.current() },
            sessionFactory: { _ in connection },
            outputRoot: root
        )
        let outcome = await backend.run(
            makeRequest(root: root, maxOutputBytes: 256),
            cancellation: nil
        )
        guard case .exited(let code, let stdout, let stderr, let truncated, let stderrTruncated, _) = outcome else {
            Issue.record("unexpected outcome: \(outcome)")
            return
        }
        #expect(code == 0)
        #expect(stdout.utf8.count == 248)
        #expect(stderr.hasPrefix("warning"))
        #expect(truncated)
        #expect(!stderrTruncated)
        #expect(stderr.contains("warning"))
        #expect(stderr.contains("Full remote output:"))
        let terminal = root.appendingPathComponent(".floe/terminal", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(at: terminal, includingPropertiesForKeys: nil)
        #expect(files.count == 1)
        let saved = try Data(contentsOf: files[0])
        #expect(saved.count == full.count + warning.count)
    }

    @Test("oversized commands and stdin are staged separately inside the remote task root")
    func oversizedCommandStagesInsideRemoteRoot() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = makeTarget()
        let state = TargetState(.ssh(target))
        let connection = makeConnection { command in
            if command.hasPrefix("exec /bin/sh '") {
                let bytes = Data("script".utf8)
                return FakeExecutionReply(
                    result: SSHStreamExecResult(
                        exitCode: 3,
                        stdoutPreview: bytes,
                        stdoutBytes: Int64(bytes.count)
                    ),
                    chunks: [FakeChunk(channel: .stdout, data: bytes)]
                )
            }
            return FakeExecutionReply(result: SSHStreamExecResult(exitCode: 0))
        }
        let backend = RemoteEnvironmentShellBackend(
            resolver: { _ in await state.current() },
            sessionFactory: { _ in connection },
            outputRoot: root
        )
        let bigCommand = "echo " + String(repeating: "a", count: 60_000)
        let outcome = await backend.run(
            makeRequest(root: root, command: bigCommand, stdin: "stdin bytes"),
            cancellation: nil
        )
        guard case .exited(let code, _, _, _, _, _) = outcome else {
            Issue.record("unexpected outcome: \(outcome)")
            return
        }
        #expect(code == 3)
        let commands = connection.recordedCommands
        #expect(commands.contains { $0.contains(".floe-shell/") && $0.contains(".stdin.b64") })
        #expect(commands.contains { $0.contains(".floe-shell/") && $0.contains(".sh.b64") })
        #expect(commands.contains { $0.hasPrefix("exec /bin/sh '") && $0.contains(".floe-shell/") && $0.contains(".sh'") })
        #expect(!commands.contains { $0.contains(root.path) })
        #expect(connection.userExecutionCount == 1)
    }

    @Test("a post-exit sync failure reports unknown and never reruns the command")
    func afterSyncFailureIsUnknown() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = makeTarget()
        let state = TargetState(.ssh(target))
        let sync = SyncRecorder()
        await sync.setFailure(.afterRun)
        let bytes = Data("done".utf8)
        let connection = makeConnection { _ in
            FakeExecutionReply(
                result: SSHStreamExecResult(
                    exitCode: 0,
                    stdoutPreview: bytes,
                    stdoutBytes: Int64(bytes.count)
                ),
                chunks: [FakeChunk(channel: .stdout, data: bytes)]
            )
        }
        let backend = RemoteEnvironmentShellBackend(
            resolver: { _ in await state.current() },
            sessionFactory: { _ in connection },
            sync: RemoteWorkspaceSyncCallbacks { _, phase, _ in
                try await sync.record(phase)
            },
            outputRoot: root
        )
        let outcome = await backend.run(makeRequest(root: root), cancellation: nil)
        guard case .outcomeUnknown(let jobID, let message) = outcome else {
            Issue.record("unexpected outcome: \(outcome)")
            return
        }
        #expect(!jobID.isEmpty)
        #expect(message.contains("do not rerun"))
        #expect(message.contains("workspace synchronization failed"))
        #expect(connection.userExecutionCount == 1)
        let phases = await sync.snapshot()
        #expect(phases == [.beforeRun, .afterRun])
    }

    @Test("a PTY session preserves output, resize, interrupt and close ownership")
    func ptySessionLifecycle() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = makeTarget()
        let state = TargetState(.ssh(target))
        let pty = FakeRemoteShellPTY(initial: Data("prompt$ ".utf8))
        let connection = FakeRemoteShellConnection(pty: pty)
        let backend = RemoteEnvironmentShellBackend(
            resolver: { _ in await state.current() },
            sessionFactory: { _ in connection },
            outputRoot: root
        )
        let openRequest = ShellOpenRequest(
            command: "",
            cwd: ".",
            rootURL: root,
            environment: [:],
            columns: 120,
            rows: 40,
            gateTimeout: 5,
            sessionID: "pty-session",
            runID: UUID(),
            toolEnvironment: makeToolEnvironment("env-ssh", root: root)
        )
        let opened = try await backend.openSession(openRequest, cancellation: nil)
        #expect(opened.alive)
        #expect(opened.initialOutput.contains("prompt"))
        pty.setResponse(Data("pong\n".utf8))

        let exchange = try await backend.exchangeSession(
            ShellExchangeRequest(sessionID: "pty-session", input: "ping\n", waitMs: 2_000, maxBytes: 1024),
            cancellation: nil
        )
        #expect(exchange.alive)
        #expect(exchange.output.contains("pong"))
        #expect(exchange.bytesWritten >= "ping\n".utf8.count)

        await backend.resizeSession(sessionID: "pty-session", columns: 100, rows: 30)
        #expect(pty.resized.last?.columns == 100)
        #expect(pty.resized.last?.rows == 30)

        await backend.signalSession(sessionID: "pty-session", signal: .interrupt)
        #expect(pty.written.contains(Data([0x03])))

        await backend.closeSession(sessionID: "pty-session")
        #expect(pty.isClosed)
        #expect(connection.isClosed)
    }

    @Test("a late session from an old generation is closed and refuses the new target")
    func lateOldSessionAfterNewGeneration() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hostID = UUID()
        let oldTarget = makeTarget(hostID: hostID, generation: "1")
        let newTarget = makeTarget(hostID: hostID, generation: "2")
        let state = TargetState(.ssh(oldTarget))
        let hosts = HostRecorder()
        let pty = FakeRemoteShellPTY(initial: Data("old$ ".utf8))
        let connection = FakeRemoteShellConnection(pty: pty)
        let defaultBackend = FakeDefaultBackend()
        let router = RemoteEnvironmentShellRouter(
            defaultBackend: defaultBackend,
            resolver: { _ in await state.current() },
            sessionFactory: { target in
                await hosts.record(target.hostID)
                return connection
            },
            outputRoot: root
        )
        let openRequest = ShellOpenRequest(
            command: "",
            cwd: ".",
            rootURL: root,
            environment: [:],
            columns: 80,
            rows: 24,
            gateTimeout: 5,
            sessionID: "late-session",
            runID: UUID(),
            toolEnvironment: makeToolEnvironment("env-ssh", root: root)
        )
        let opened = try await router.openSession(openRequest, cancellation: nil)
        #expect(opened.alive)
        await state.set(.ssh(newTarget))
        await #expect(throws: (any Error).self) {
            _ = try await router.exchangeSession(
                ShellExchangeRequest(sessionID: "late-session", input: "x", waitMs: 10, maxBytes: 10),
                cancellation: nil
            )
        }
        #expect(pty.isClosed)
        let recordedHosts = await hosts.snapshot()
        #expect(recordedHosts == [hostID])
        await router.closeSession(sessionID: "late-session")
        #expect(defaultBackend.closeCount == 1)
    }

    @Test("a hard deadline reaches the streaming seam without a 300-second clamp")
    func hardDeadlineIsNotClamped() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = makeTarget()
        let state = TargetState(.ssh(target))
        let connection = makeConnection { _ in FakeExecutionReply(result: SSHStreamExecResult()) }
        let backend = RemoteEnvironmentShellBackend(
            resolver: { _ in await state.current() },
            sessionFactory: { _ in connection },
            outputRoot: root
        )
        let outcome = await backend.run(
            makeRequest(root: root, deadline: .seconds(900)),
            cancellation: nil
        )
        guard case .exited(_, _, _, _, _, _) = outcome else {
            Issue.record("unexpected outcome: \(outcome)")
            return
        }
        guard let recorded = connection.recordedDeadlines.first,
              case .seconds(let seconds) = recorded else {
            Issue.record("the finite deadline was not forwarded")
            return
        }
        #expect(seconds > 890)
        #expect(seconds <= 900)
    }
}
