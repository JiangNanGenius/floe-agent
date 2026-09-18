// feedback_RuntimeShellGateTests — Build 191 feedback repair (runtime part).
//
// Regression coverage for the shell run gate, cooperative cancellation and
// interactive-session diagnostics:
//  - a gate that is still owned by another worker reports "not started"
//    (exit 75), never a fabricated execution timeout (exit 124);
//  - the gate queue window is independent from the execution timeout;
//  - after a timed-out worker the next command stays not-started until the
//    worker really stops, then runs again;
//  - exchange results carry bounded byte counters so "no output" is
//    distinguishable from "output drained";
//  - download-based installs observe a cancellation token;
//  - node package-manager selection prefers an explicit environment
//    preference, then the project lock file, then the invoked command.

import Foundation
import Testing
import Crypto
import FloeCore
import FloeTools
@testable import FloeExecution

@Suite("feedback runtime shell gate and cancellation")
struct FeedbackRuntimeShellGateTests {

    // MARK: - Gate / timeout distinction

    @Test func gateBusyIsNotAnExecutionTimeout() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let backend = BusyShellBackend()
        let journal = ShellOperationJournal(rootURL: root)
        let service = LocalShellService(backend: backend, journal: journal, rootProvider: { root })
        let context = ToolContext(runID: UUID(), toolCallID: "call-busy", scope: .local, cancellation: CancellationToken())
        let result = await service.run(command: "printf hi", cwd: ".", environment: [:], stdin: nil,
            timeout: 1, maxOutputBytes: 1024, isBackground: false, context: context)
        guard case .outcome(.notStarted(let reason)) = result else {
            Issue.record("Busy gate must be reported as notStarted, got \(result)"); return
        }
        #expect(reason.contains("nothing was started"))

        // The agent-facing render must use exit 75, never 124.
        let tool = LocalShellTool(shell: service)
        let output = try? await tool.execute(.init(command: "printf hi"), context: context)
        #expect(output?.exitStatus == 75)
        #expect(output?.summary.contains("status=notStarted") == true)
        #expect(output?.summary.contains("exit=124") == false)

        // The journal distinguishes the outcomes as well.
        let entries = (try? String(contentsOf: root.appendingPathComponent(ShellOperationJournal.defaultFileName), encoding: .utf8))?
            .split(separator: "\n").compactMap { line -> String? in
                guard let data = String(line).data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
                return object["outcome"] as? String
            } ?? []
        #expect(entries.contains { $0.hasPrefix("notStarted:") })
        #expect(entries.contains("timedOut") == false)
    }

    @Test func gateWaitWindowIsSeparateFromExecutionTimeout() {
        let service = LocalShellService(
            backend: BusyShellBackend(),
            configuration: .init(gateWaitTimeout: 5),
            rootProvider: { FileManager.default.temporaryDirectory }
        )
        #expect(service.normalizedGateWait(nil) == 5)
        #expect(service.normalizedGateWait(30) == 5)
        #expect(service.normalizedGateWait(0.01) == 0.25)
        // The execution timeout is unchanged and independent.
        #expect(service.normalizedTimeout(nil, isBackground: false) == 10)
        #expect(service.normalizedTimeout(999, isBackground: true) == 600)
        // Requests carry both values independently.
        let request = ShellRunRequest(command: "true", cwd: ".", rootURL: URL(fileURLWithPath: "/"), timeout: 2, gateTimeout: 1, sessionID: "s")
        #expect(request.timeout == 2)
        #expect(request.gateTimeout == 1)
    }

    /// Contract double for the app-target bridge gate: after a worker outlives
    /// its caller's deadline it keeps the process-wide gate, so the next
    /// command is not-started (never a second fabricated timeout) and the gate
    /// opens again only when that worker actually stops. The real bridge gate
    /// runs in FloeAgent/scripts/tests/feedback_shell_bridge_host.mm.
    @Test func timedOutWorkerKeepsGateUntilItStops() async {
        let gate = SimulatedGateBackend()
        let service = LocalShellService(backend: gate, configuration: .init(gateWaitTimeout: 0.25),
            rootProvider: { FileManager.default.temporaryDirectory })
        let context = ToolContext(runID: UUID(), scope: .local, cancellation: CancellationToken())

        await gate.runWorkerThatOutlivesItsDeadline()
        let first = await service.run(command: "sleep 60", cwd: ".", environment: [:], stdin: nil,
            timeout: 0.05, maxOutputBytes: 1024, isBackground: false, context: context)
        guard case .outcome(.timedOut) = first else {
            Issue.record("Started worker must time out, got \(first)"); return
        }
        let second = await service.run(command: "printf after", cwd: ".", environment: [:], stdin: nil,
            timeout: 1, maxOutputBytes: 1024, isBackground: false, context: context)
        guard case .outcome(.notStarted(let reason)) = second else {
            Issue.record("Gate still owned: expected notStarted, got \(second)"); return
        }
        #expect(reason.contains("nothing was started"))
        await gate.finishWorker()
        let third = await service.run(command: "printf after", cwd: ".", environment: [:], stdin: nil,
            timeout: 1, maxOutputBytes: 1024, isBackground: false, context: context)
        guard case .outcome(.exited(let code, let stdout, _, _, _, _)) = third else {
            Issue.record("Released gate must run again, got \(third)"); return
        }
        #expect(code == 0)
        #expect(stdout == "after")
    }

    // MARK: - Session diagnostics

    @Test func exchangeCarriesByteCounters() async throws {
        let backend = CountingSessionBackend()
        let center = ShellSessionCenter(backend: backend)
        let runID = UUID()
        let opened = try await center.open(command: "", cwd: ".", environment: [:], columns: 80, rows: 24,
            runID: runID, rootURL: FileManager.default.temporaryDirectory, cancellation: nil)
        #expect(opened.alive)

        let quiet = try await center.exchange(sessionID: opened.sessionID, input: nil, waitMs: 50, maxBytes: 4096,
            runID: runID, cancellation: nil)
        #expect(quiet.output.isEmpty)
        #expect(quiet.bytesRead == 0)
        #expect(quiet.bytesWritten == 0)

        let typed = try await center.exchange(sessionID: opened.sessionID, input: "echo hi\n", waitMs: 50, maxBytes: 4096,
            runID: runID, cancellation: nil)
        #expect(typed.output == "hi\n")
        #expect(typed.bytesRead == 3)
        #expect(typed.bytesWritten == 8)
        await center.close(sessionID: opened.sessionID, runID: runID)
        #expect(await backend.closeCount == 1)
        // A closed session is gone before the backend teardown runs.
        await #expect(throws: FloeError.self) {
            _ = try await center.exchange(sessionID: opened.sessionID, input: nil, waitMs: 50, maxBytes: 4096,
                runID: runID, cancellation: nil)
        }
    }

    @Test func immediatelyExitedSessionIsClosedNotLeaked() async throws {
        let backend = CountingSessionBackend(openAlive: false)
        let center = ShellSessionCenter(backend: backend)
        let runID = UUID()
        let opened = try await center.open(command: "", cwd: ".", environment: [:], columns: 80, rows: 24,
            runID: runID, rootURL: FileManager.default.temporaryDirectory, cancellation: nil)
        #expect(!opened.alive)
        #expect(await backend.closeCount == 1)
        let active = await center.activeSessionIDs(runID: runID)
        #expect(active.isEmpty)
    }

    // MARK: - Cooperative download cancellation

    @Test func downloadHonorsPreCancelledTokenBeforeAnyNetworkWork() async {
        let token = CancellationToken()
        token.cancel()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            _ = try await HTTPRequestService().download(
                url: URL(string: "https://example.invalid/never")!,
                timeout: 5, maxBytes: 1024, to: destination, cancellation: token
            )
            Issue.record("A cancelled download must not start")
        } catch FloeError.cancelled {
            // Expected.
        } catch {
            Issue.record("Expected FloeError.cancelled, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func wasmInstallForwardsCancellationTokenToDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00])
        let entry = SignedWasmCatalog.Entry(
            id: "floe/test", version: "1.0.0", command: "floe-test",
            url: URL(string: "https://example.invalid/floe-test.wasm")!,
            sha256: FloeDigest.sha256Hex(bytes), minimumAppVersion: "1.6.7"
        )
        let data = try JSONEncoder().encode(SignedWasmCatalog(packages: [entry]))
        let key = Curve25519.Signing.PrivateKey()
        let signature = try key.signature(for: Data("FLOE-CAPABILITY-CATALOG-V1\n".utf8) + data)
        let recorder = TokenRecorder()
        let store = try SignedWasmCapabilityStore(
            catalogData: data, signature: signature,
            publicKey: key.publicKey.rawRepresentation, appVersion: "1.6.7",
            root: root.appendingPathComponent("wasm", isDirectory: true)
        ) { _, target, cancellation in
            await recorder.record(cancellation)
            try bytes.write(to: target)
        }
        let token = CancellationToken()
        try await store.install(id: entry.id, cancellation: token)
        #expect(await recorder.observed != nil)
        #expect(await recorder.observed === token)
    }

    // MARK: - Node project manager selection

    @Test func explicitCommandManagerIsAuthoritativeWhileAutomaticUsesHints() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: empty)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        // Automatic selection with no hints: npm.
        #expect(try NodePackageManagerPolicy.resolve(.automatic(preference: .automatic), workspace: empty) == .npm)
        // A project lock is an automatic hint only.
        try Data().write(to: root.appendingPathComponent("pnpm-lock.yaml"))
        #expect(try NodePackageManagerPolicy.resolve(.automatic(preference: .automatic), workspace: root) == .pnpm)
        // The configured default wins over the project hint, but only here.
        #expect(try NodePackageManagerPolicy.resolve(.automatic(preference: .npm), workspace: root) == .npm)
        #expect(try NodePackageManagerPolicy.resolve(.automatic(preference: .pnpm), workspace: empty) == .pnpm)

        // An explicit shell command is never silently swapped for another
        // manager by the project lock or by the configured default.
        #expect(try NodePackageManagerPolicy.resolve(.explicit(.npm), workspace: root) == .npm)
        #expect(try NodePackageManagerPolicy.resolve(.explicit(.pnpm), workspace: empty) == .pnpm)

        // An unsupported project manager is reported honestly for automatic
        // selection; it does not override an explicitly typed command.
        try FileManager.default.removeItem(at: root.appendingPathComponent("pnpm-lock.yaml"))
        try Data().write(to: root.appendingPathComponent("yarn.lock"))
        #expect(throws: FloeError.self) {
            try NodePackageManagerPolicy.resolve(.automatic(preference: .automatic), workspace: root)
        }
        #expect(try NodePackageManagerPolicy.resolve(.explicit(.npm), workspace: root) == .npm)
    }
}

// MARK: - Fakes

private actor BusyShellBackend: LocalShellBackend {
    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        .notStarted(reason: "The local shell is still stopping another command; nothing was started (exit 75). Retry after it stops. gate owner=other heldMs=9000")
    }
    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        .init(sessionID: request.sessionID, initialOutput: "", alive: true)
    }
    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        .init(output: "", alive: false, exitCode: 0)
    }
    func closeSession(sessionID: String) async {}
}

private actor SimulatedGateBackend: LocalShellBackend {
    private var workerRunning = false
    func runWorkerThatOutlivesItsDeadline() { workerRunning = true }
    func finishWorker() { workerRunning = false }

    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        if workerRunning {
            // The worker that timed out is still holding the gate.
            if request.command.contains("sleep") {
                return .timedOut(partialStdout: "", partialStderr: "", durationMs: 50)
            }
            return .notStarted(reason: "The local shell is still stopping another command; nothing was started (exit 75). Retry after it stops.")
        }
        return .exited(code: 0, stdout: request.command.replacingOccurrences(of: "printf ", with: ""),
                       stderr: "", truncated: false, stderrTruncated: false, durationMs: 1)
    }
    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        .init(sessionID: request.sessionID, initialOutput: "", alive: true)
    }
    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        .init(output: "", alive: false, exitCode: 0)
    }
    func closeSession(sessionID: String) async {}
}

private actor CountingSessionBackend: LocalShellBackend {
    private var bytesRead = 0
    private(set) var closeCount = 0
    private let openAlive: Bool
    init(openAlive: Bool = true) { self.openAlive = openAlive }
    func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
        .exited(code: 0, stdout: "", stderr: "", truncated: false, stderrTruncated: false, durationMs: 0)
    }
    func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
        .init(sessionID: request.sessionID, initialOutput: "$ ", alive: openAlive)
    }
    func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
        if let input = request.input, !input.isEmpty {
            bytesRead += 3
            return ShellExchangeResult(output: "hi\n", alive: true, exitCode: nil, terminalOutput: Data("hi\n".utf8),
                bytesRead: bytesRead, bytesWritten: 8)
        }
        return ShellExchangeResult(output: "", alive: true, exitCode: nil, terminalOutput: Data(),
            bytesRead: bytesRead, bytesWritten: 0)
    }
    func closeSession(sessionID: String) async { closeCount += 1 }
}

private actor TokenRecorder {
    private(set) var observed: CancellationToken?
    func record(_ token: CancellationToken?) { observed = token }
}
