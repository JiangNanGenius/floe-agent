// FloeExecutionTests — exec.remotePython: host resolution, capability
// errors, execution mapping, cancellation, the side-effecting descriptor
// contract, and the real RemotePythonProbe three states.
// Uses an in-memory fake RemotePythonSession — no live SSH needed.

import Foundation
import Testing
@testable import FloeExecution
@testable import FloeTools
@testable import FloeCore
@testable import FloeSSH
import FloeModels
import FloeAgentRuntime

/// NSLock wrapper usable from async contexts (raw NSLock is unavailable
/// in async on this SDK), mirroring the AsyncLock in AgentRuntimeTests.
private final class FakeLock<State>: @unchecked Sendable {
    private var state: State
    private let lock = NSLock()

    init(_ state: State) { self.state = state }

    nonisolated func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

/// In-memory fake SSH session: scripted exit code / stdout / stderr, and
/// records the command it was invoked with (stdin is not feedable on iOS;
/// scripts arrive base64-wrapped inside the command string).
private final class FakePythonSession: RemotePythonSession, @unchecked Sendable {
    private struct Storage {
        var commands: [String] = []
        var pythonVersion: String? = "Python 3.12.4"
        var exitCode: Int32 = 0
        var stdout = ""
        var stderr = ""
        var simulateTimeout = false
        var simulateCancel = false
        /// When true, only the script run (`python3 -c …`) times out while
        /// the `command -v python3` probe still succeeds.
        var timeoutOnScriptOnly = false
    }

    private let storage = FakeLock(Storage())

    var commands: [String] { storage.withLock { $0.commands } }
    var pythonVersion: String? {
        get { storage.withLock { $0.pythonVersion } }
        set { storage.withLock { $0.pythonVersion = newValue } }
    }
    var exitCode: Int32 {
        get { storage.withLock { $0.exitCode } }
        set { storage.withLock { $0.exitCode = newValue } }
    }
    var stdout: String {
        get { storage.withLock { $0.stdout } }
        set { storage.withLock { $0.stdout = newValue } }
    }
    var stderr: String {
        get { storage.withLock { $0.stderr } }
        set { storage.withLock { $0.stderr = newValue } }
    }
    var simulateTimeout: Bool {
        get { storage.withLock { $0.simulateTimeout } }
        set { storage.withLock { $0.simulateTimeout = newValue } }
    }
    var simulateCancel: Bool {
        get { storage.withLock { $0.simulateCancel } }
        set { storage.withLock { $0.simulateCancel = newValue } }
    }
    var timeoutOnScriptOnly: Bool {
        get { storage.withLock { $0.timeoutOnScriptOnly } }
        set { storage.withLock { $0.timeoutOnScriptOnly = newValue } }
    }

    func execute(
        _ command: String,
        timeout: TimeInterval,
        maxOutputBytes: Int,
        cancellation: CancellationToken?
    ) async throws -> SSHExecResult {
        let snapshot = storage.withLock { state -> Storage in
            state.commands.append(command)
            return state
        }

        if snapshot.simulateCancel { throw SSHExecError.cancelled }

        // Emulate the python3 probe.
        if command.hasPrefix("command -v python3") {
            if let version = snapshot.pythonVersion {
                return SSHExecResult(stdout: "/usr/bin/python3\n\(version)\n", stderr: "", exitCode: 0, truncated: false)
            }
            return SSHExecResult(stdout: "", stderr: "", exitCode: 1, truncated: false)
        }
        // Script run below.
        if snapshot.simulateTimeout || snapshot.timeoutOnScriptOnly { throw SSHExecError.timedOut }
        return SSHExecResult(
            stdout: snapshot.stdout,
            stderr: snapshot.stderr,
            exitCode: snapshot.exitCode,
            truncated: false
        )
    }
}

/// In-memory host directory backing the service's resolvers.
private final class FakeHosts: @unchecked Sendable {
    var hosts: [UUID: RemotePythonService.RemotePythonHost] = [:]
    var order: [UUID] = []
}

@Suite("FloeExecution.RemotePython")
struct RemotePythonToolTests {

    private let hostID = UUID()

    private func makeService(
        session: FakePythonSession,
        hosts: [UUID]
    ) -> RemotePythonService {
        let store = FakeHosts()
        for id in hosts {
            store.hosts[id] = .init(id: id, displayName: "host-\(id.uuidString.prefix(4))")
            store.order.append(id)
        }
        return RemotePythonService(
            sessionFactory: { _ in session },
            hostResolver: { id in store.hosts[id] },
            defaultHostProvider: { store.order.first }
        )
    }

    private func makeContext() -> ToolContext {
        ToolContext(runID: UUID(), cancellation: CancellationToken())
    }

    // MARK: Descriptor contract

    @Test("Descriptor: side-effecting, remote-command + network risk labels")
    func descriptorContract() {
        #expect(RemotePythonTool.name == "exec.remotePython")
        #expect(RemotePythonTool.isSideEffecting == true)
        #expect(RemotePythonTool.riskLabels == [.executesRemoteCommand, .networkAccess])
        #expect(RemotePythonTool.parametersJSON.contains("\"script\""))
        #expect(RemotePythonTool.parametersJSON.contains("\"hostID\""))
    }

    // MARK: Validation

    @Test("Empty script, oversized script and malformed hostID fail validation")
    func validation() throws {
        let tool = RemotePythonTool(service: makeService(session: FakePythonSession(), hosts: [hostID]))
        #expect(throws: FloeError.self) { try tool.validate(.init(script: "  ")) }
        let big = String(repeating: "x", count: RemotePythonTool.maxScriptBytes + 1)
        #expect(throws: FloeError.self) { try tool.validate(.init(script: big)) }
        #expect(throws: FloeError.self) { try tool.validate(.init(script: "print(1)", hostID: "not-a-uuid")) }
    }

    // MARK: Host resolution errors

    @Test("No host configured → status=error noHostConfigured")
    func noHost() async throws {
        let service = makeService(session: FakePythonSession(), hosts: [])
        let tool = RemotePythonTool(service: service)
        let output = try await tool.execute(.init(script: "print(1)"), context: makeContext())
        #expect(output.summary.contains("status=error"))
        #expect(output.summary.contains("No SSH host is configured"))
    }

    @Test("Unknown hostID → status=error hostNotFound")
    func hostNotFound() async throws {
        let service = makeService(session: FakePythonSession(), hosts: [UUID()])
        let tool = RemotePythonTool(service: service)
        let output = try await tool.execute(
            .init(script: "print(1)", hostID: hostID.uuidString),
            context: makeContext()
        )
        #expect(output.summary.contains("status=error"))
        #expect(output.summary.contains("Host not found"))
    }

    @Test("Host without python3 → status=error pythonNotFound")
    func pythonNotFound() async throws {
        let session = FakePythonSession()
        session.pythonVersion = nil
        let service = makeService(session: session, hosts: [hostID])
        let tool = RemotePythonTool(service: service)
        let output = try await tool.execute(
            .init(script: "print(1)", hostID: hostID.uuidString),
            context: makeContext()
        )
        #expect(output.summary.contains("status=error"))
        #expect(output.summary.contains("python3"))
    }

    // MARK: Real execution

    @Test("print(2+2) executes via a base64-wrapped python3 -c one-liner")
    func realExecution() async throws {
        let session = FakePythonSession()
        session.stdout = "4\n"
        let service = makeService(session: session, hosts: [hostID])
        let tool = RemotePythonTool(service: service)

        let output = try await tool.execute(
            .init(script: "print(2 + 2)", hostID: hostID.uuidString),
            context: makeContext()
        )
        #expect(output.summary.contains("status=ok"))
        #expect(output.summary.contains("4"))

        // The script travelled base64-wrapped inside `python3 -c` (stdin is
        // unavailable on iOS); decoding it recovers the script verbatim.
        let runCommand = session.commands.first { $0.hasPrefix("python3 -c") }
        #expect(runCommand != nil)
        #expect(runCommand?.contains("base64") == true)
        if let command = runCommand,
           let start = command.range(of: "b64decode('"),
           let end = command.range(of: "')", range: start.upperBound..<command.endIndex) {
            let encoded = String(command[start.upperBound..<end.lowerBound])
            let decoded = Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) }
            #expect(decoded == "print(2 + 2)")
        } else {
            Issue.record("could not locate the base64 payload in \(runCommand ?? "nil")")
        }
        // The python3 probe ran before the script.
        #expect(session.commands.first?.hasPrefix("command -v python3") == true)
    }

    @Test("Non-zero exit maps to a structured executionFailed result")
    func nonZeroExit() async throws {
        let session = FakePythonSession()
        session.exitCode = 2
        session.stderr = "SyntaxError: invalid syntax"
        let service = makeService(session: session, hosts: [hostID])
        let tool = RemotePythonTool(service: service)

        let output = try await tool.execute(
            .init(script: "def broken(", hostID: hostID.uuidString),
            context: makeContext()
        )
        #expect(output.summary.contains("status=error"))
        #expect(output.summary.contains("status 2") || output.summary.contains("exited with status 2"))
        #expect(output.summary.contains("SyntaxError"))
    }

    // MARK: Timeout / cancel

    @Test("Timeout on the script maps to status=timedOut")
    func timeoutMapping() async throws {
        let session = FakePythonSession()
        // Only the script run times out; the python3 probe succeeds.
        session.timeoutOnScriptOnly = true
        let service = makeService(session: session, hosts: [hostID])
        let tool = RemotePythonTool(service: service)
        let output = try await tool.execute(
            .init(script: "import time; time.sleep(999)", hostID: hostID.uuidString, timeout: 0.5),
            context: makeContext()
        )
        #expect(output.summary.contains("status=timedOut"))
        #expect(output.exitStatus == 124)
    }

    @Test("Cancellation propagates as FloeError.cancelled")
    func cancellationMapping() async throws {
        let session = FakePythonSession()
        session.simulateCancel = true
        let service = makeService(session: session, hosts: [hostID])
        let tool = RemotePythonTool(service: service)
        await #expect(throws: FloeError.self) {
            _ = try await tool.execute(
                .init(script: "print(1)", hostID: hostID.uuidString),
                context: makeContext()
            )
        }
    }

    // MARK: Registration

    @Test("registerExecutionTools wires both js and python when a python service is given")
    func registrationIncludesPython() {
        let registry = ToolRunnerRegistry()
        let service = makeService(session: FakePythonSession(), hosts: [hostID])
        registerExecutionTools(
            registry: registry,
            pythonService: service,
            includeOnDeviceJavaScript: true
        )

        #expect(ToolCatalog.descriptor(named: "exec.javascript") != nil)
        #expect(ToolCatalog.descriptor(named: "exec.remotePython") != nil)
        #expect(registry.runner(named: "exec.javascript") != nil)
        #expect(registry.runner(named: "exec.remotePython") != nil)
        #expect(ToolCatalog.descriptor(named: "exec.remotePython")?.isSideEffecting == true)
    }

    // MARK: Probe three states

    @Test("Probe: no host / no python3 / python3 → unavailable / unavailable / available")
    func probeThreeStates() async {
        // No host.
        let noHostProbe = RemotePythonProbe(
            service: makeService(session: FakePythonSession(), hosts: [])
        )
        guard case .unavailable(let reason) = await noHostProbe.probe() else {
            Issue.record("expected unavailable for no host")
            return
        }
        #expect(reason.contains("No SSH host"))

        // Host without python3.
        let noPython = FakePythonSession()
        noPython.pythonVersion = nil
        let noPythonProbe = RemotePythonProbe(
            service: makeService(session: noPython, hosts: [hostID]),
            hostID: hostID
        )
        guard case .unavailable(let reason2) = await noPythonProbe.probe() else {
            Issue.record("expected unavailable for missing python3")
            return
        }
        #expect(reason2.contains("python3"))

        // Host with python3.
        let okSession = FakePythonSession()
        okSession.pythonVersion = "Python 3.12.4"
        let okProbe = RemotePythonProbe(
            service: makeService(session: okSession, hosts: [hostID]),
            hostID: hostID
        )
        guard case .available(let version) = await okProbe.probe() else {
            Issue.record("expected available")
            return
        }
        #expect(version.contains("Python 3.12.4"))
    }
}
