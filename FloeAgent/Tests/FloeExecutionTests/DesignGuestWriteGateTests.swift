// FloeExecutionTests — Pre-dispatch original-write barrier for frozen
// design tasks. A run that owns frozen design originals must not be able to
// mutate them through ANY execution backend (Linux guest or native): the
// gate denies arbitrary commands BEFORE dispatch with a structured
// unsupported result, allows strictly read-only inspection, and never
// touches runs without a freeze (ordinary tasks, unbound chats).

import Foundation
import Testing
@testable import FloeExecution
import FloeCore
import FloeTools

@Suite("FloeExecution.DesignGuestWriteGate", .serialized)
struct DesignGuestWriteGateTests {
    private func makeRegistry(conversationID: UUID, file: URL) -> DesignFreezeRegistry {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-guest-gate-\(UUID().uuidString)", isDirectory: true)
        let registry = DesignFreezeRegistry(store: .init(directory: directory))
        let sha = (try? Data(contentsOf: file)).map { FloeDigest.sha256Hex($0) } ?? "sha"
        registry.protect(file, conversationID: conversationID.uuidString.lowercased(), frozenSHA256: sha)
        return registry
    }

    private func makeFile() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-guest-gate-file-\(UUID().uuidString).html")
        try? "<h1>original</h1>".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func makeContext(conversationID: UUID?, workspaceRoot: URL? = nil) -> ToolContext {
        ToolContext(
            runID: UUID(),
            workspaceRootURL: workspaceRoot,
            cancellation: CancellationToken(),
            conversationID: conversationID)
    }

    /// Synchronous recorder for the fake backend (NSLock is unavailable in
    /// Swift 6 async contexts; DispatchQueue.sync gives the same atomic
    /// read-modify-write without actor hops).
    private final class CallRecorder: @unchecked Sendable {
        struct Entry: Sendable { let command: String }
        private let queue = DispatchQueue(label: "floe.guest-gate-recorder")
        private var entries: [Entry] = []
        func record(_ entry: Entry) { queue.sync { entries.append(entry) } }
        func snapshot() -> [Entry] { queue.sync { entries } }
    }

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-guest-gate-root-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("no freeze: every command dispatches unchanged")
    func unboundRunsAreUntouched() {
        let context = makeContext(conversationID: UUID())
        for command in [
            "rm -rf /workspace", "echo x > /workspace/index.html",
            "python3 -c \"open('f','w').write('x')\"",
            "git checkout .", "curl -o /workspace/a https://example.com",
        ] {
            #expect(DesignGuestWriteGate.evaluate(command: command, context: context) == nil)
        }
        #expect(DesignGuestWriteGate.arbitraryCodeDenial(context: context) == nil)
    }

    @Test("frozen run: mutating shell commands are denied before dispatch with recovery")
    func frozenRunDeniesMutatingShell() throws {
        let conversationID = UUID()
        let file = makeFile()
        let registry = makeRegistry(conversationID: conversationID, file: file)
        let frozen = makeContext(conversationID: conversationID)
        for command in [
            "echo clobbered > /workspace/index.html",
            "echo x >> /workspace/index.html",
            "rm /workspace/index.html",
            "mv /workspace/a /workspace/b",
            "cp /workspace/a /workspace/b",
            "touch /workspace/index.html",
            "sed -i 's/a/b/' /workspace/index.html",
            "tee /workspace/index.html",
            "mkdir -p /workspace/new",
            "chmod 755 /workspace/index.html",
            "python3 -c \"print(1)\"",
            "node build.js",
            "apt-get install -y nginx",
            "pip install pillow",
            "make build",
            "sh -c 'echo x > /workspace/index.html'",
            "bash deploy.sh",
            "curl -o /workspace/a https://example.com/x",
            "wget https://example.com/x",
            "patch -p1 < change.diff",
            "dd if=/dev/zero of=/workspace/blob",
            "find /workspace -name '*.html' -delete",
            "find /workspace -type f -exec rm {} +",
            "sort -o /workspace/out /workspace/in",
            "unknown-tool --frobnicate",
            "echo $(whoami)",
            "echo `id`",
            "cat <(ls /workspace)",
            "sleep 5 &",
            "export A=1 && rm /workspace/index.html",
            "ls && echo x > /workspace/index.html",
            "cat /workspace/index.html | tee /workspace/copy",
        ] {
            let denial = DesignGuestWriteGate.evaluate(command: command, context: frozen, registry: registry)
            try #require(denial != nil, "expected denial: \(command)")
            #expect(denial?.message.contains("status=unsupported") == true)
            #expect(denial?.message.contains("design.propose") == true)
            #expect(denial?.conversationID == conversationID.uuidString.lowercased())
        }
    }

    @Test("frozen run: read-only inspection still dispatches")
    func frozenRunAllowsReadOnlyInspection() {
        let conversationID = UUID()
        let file = makeFile()
        let registry = makeRegistry(conversationID: conversationID, file: file)
        let frozen = makeContext(conversationID: conversationID)
        for command in [
            "ls -la /workspace",
            "pwd",
            "cat /workspace/index.html",
            "head -20 /workspace/index.html",
            "tail -5 /workspace/index.html",
            "wc -l /workspace/index.html",
            "grep -n 'title' /workspace/index.html",
            "find /workspace -name '*.html'",
            "stat /workspace/index.html",
            "file /workspace/index.html",
            "command -v python3",
            "python3 --version",
            "node --version",
            "git --version",
            "ls | grep html | sort | uniq -c",
            "cat a.txt && cat b.txt || true",
            "FOO=bar ls -la",
            "sha256sum /workspace/index.html",
            "diff /workspace/a /workspace/b",
            "ps aux",
            "df -h",
            "echo reading 2>&1",
            "printf '%s' ok",
            "du -sh /workspace",
            "env",
            "uname -a",
        ] {
            #expect(
                DesignGuestWriteGate.evaluate(command: command, context: frozen, registry: registry) == nil,
                "expected allow: \(command)")
        }
    }

    @Test("arbitrary code (python) and interactive sessions are denied outright while frozen")
    func frozenRunDeniesArbitraryCodeAndSessions() {
        let conversationID = UUID()
        let file = makeFile()
        let registry = makeRegistry(conversationID: conversationID, file: file)
        let frozen = makeContext(conversationID: conversationID)
        #expect(DesignGuestWriteGate.arbitraryCodeDenial(context: frozen, registry: registry) != nil)
        // Session input is classified like a one-shot command.
        #expect(DesignGuestWriteGate.evaluate(
            interactiveInput: "rm -rf /workspace", context: frozen, registry: registry) != nil)
        #expect(DesignGuestWriteGate.evaluate(
            interactiveInput: "ls -la", context: frozen, registry: registry) == nil)
        // A DIFFERENT conversation's freeze does not restrict this run.
        let other = makeContext(conversationID: UUID())
        #expect(DesignGuestWriteGate.arbitraryCodeDenial(context: other, registry: registry) == nil)
    }

    @Test("ANY run whose resolved workspace can reach a frozen original is denied, not only the owner")
    func crossRunWorkspaceReachabilityIsDenied() {
        let owner = UUID()
        let unrelated = UUID()
        let file = makeFile()
        let registry = makeRegistry(conversationID: owner, file: file)
        let containingRoot = file.deletingLastPathComponent()

        // A DIFFERENT task (different conversation) whose workspace root
        // contains the frozen original can reach it through the guest share:
        // arbitrary execution is denied even though it does not own the freeze.
        let crossRun = makeContext(
            conversationID: unrelated, workspaceRoot: containingRoot)
        #expect(DesignGuestWriteGate.evaluate(
            command: "echo x > index.html", context: crossRun, registry: registry) != nil)
        #expect(DesignGuestWriteGate.arbitraryCodeDenial(context: crossRun, registry: registry) != nil)
        // Read-only inspection remains available to the cross-run.
        #expect(DesignGuestWriteGate.evaluate(
            command: "cat index.html", context: crossRun, registry: registry) == nil)

        // An UNRELATED safe root stays fully usable.
        let safeRoot = makeRoot()
        let safeRun = makeContext(conversationID: unrelated, workspaceRoot: safeRoot)
        #expect(DesignGuestWriteGate.evaluate(
            command: "echo x > anything.html", context: safeRun, registry: registry) == nil)
        #expect(DesignGuestWriteGate.arbitraryCodeDenial(context: safeRun, registry: registry) == nil)
    }

    @Test("children inherit the parent conversation freeze; model tags cannot bypass")
    func childRunsShareTheFreeze() {
        let conversationID = UUID()
        let file = makeFile()
        let registry = makeRegistry(conversationID: conversationID, file: file)
        // A delegated child keeps the parent conversation identity (the
        // subagent runner propagates conversationID), so the gate holds.
        let child = makeContext(conversationID: conversationID)
        #expect(DesignGuestWriteGate.evaluate(
            command: "echo x > /workspace/index.html", context: child, registry: registry) != nil)
    }

    // MARK: - Production dispatch boundary (LocalShellService)

    private final class RecordingBackend: LocalShellBackend, @unchecked Sendable {
        typealias Call = CallRecorder.Entry
        // Serializes the recording across the concurrent dispatch boundary;
        // an actor cannot satisfy LocalShellBackend's sync Sendable witness,
        // so recording uses a lock on a dedicated queue via an actor-free
        // synchronous path (run is async but never suspends before record).
        private let recorder = CallRecorder()

        var calls: [Call] { recorder.snapshot() }

        func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
            recorder.record(Call(command: request.command))
            return .exited(code: 0, stdout: "ran", stderr: "", truncated: false, stderrTruncated: false, durationMs: 1)
        }
        func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult {
            throw FloeError.invalidConfiguration("not used")
        }
        func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult {
            throw FloeError.invalidConfiguration("not used")
        }
        func closeSession(sessionID: String) async {}
    }

    private func shellService(
        backend: RecordingBackend,
        registry: DesignFreezeRegistry
    ) -> LocalShellService {
        // The gate reads the shared registry; tests swap it in through the
        // same seam the journal/policy use (no app-layer coordinator here).
        DesignGuestWriteGateTesting.installRegistryOverride(registry)
        return LocalShellService(
            backend: backend,
            journal: ShellOperationJournal(),
            rootProvider: { nil })
    }

    @Test("first mutating dispatch is refused BEFORE the backend: original write cannot happen")
    func deniedCommandNeverReachesTheBackend() async throws {
        let conversationID = UUID()
        let file = makeFile()
        let registry = makeRegistry(conversationID: conversationID, file: file)
        let backend = RecordingBackend()
        let service = shellService(backend: backend, registry: registry)
        let root = makeRoot()
        let frozen = makeContext(conversationID: conversationID, workspaceRoot: root)

        // The production dispatch path: LocalShellTool → LocalShellService.
        let tool = LocalShellTool(shell: service)
        let mutating = LocalShellTool.Arguments(command: "echo clobbered > /workspace/index.html")
        let denialOutput = try await tool.execute(mutating, context: frozen)
        #expect(denialOutput.exitStatus == 126)
        #expect(denialOutput.summary.contains("status=unsupported") == true)
        #expect(denialOutput.summary.contains("design_original_frozen") == true)
        // FIRST-WRITE PROOF: the backend never saw the command, so no guest
        // or native process could have touched the original.
        #expect(backend.calls.isEmpty)
        try #expect(String(contentsOf: file, encoding: .utf8) == "<h1>original</h1>")

        // Read-only inspection still reaches the backend.
        let read = LocalShellTool.Arguments(command: "cat /workspace/index.html")
        _ = try await tool.execute(read, context: frozen)
        #expect(backend.calls.map(\.command) == ["cat /workspace/index.html"])

        // A run WITHOUT the freeze dispatches the same mutating command.
        let ordinary = makeContext(conversationID: UUID(), workspaceRoot: root)
        _ = try await tool.execute(mutating, context: ordinary)
        #expect(backend.calls.count == 2)
        DesignGuestWriteGateTesting.removeRegistryOverride()
    }

    @Test("localPython and interactive session tools refuse while frozen, before any dispatch")
    func arbitraryCodeToolsRefuseFrozenRuns() async throws {
        let conversationID = UUID()
        let file = makeFile()
        let registry = makeRegistry(conversationID: conversationID, file: file)
        DesignGuestWriteGateTesting.installRegistryOverride(registry)
        defer { DesignGuestWriteGateTesting.removeRegistryOverride() }
        let frozen = makeContext(conversationID: conversationID)

        let python = LocalPythonTool(service: LocalPythonService(
            version: "test",
            runner: { _, _ in .ok(resultJSON: nil, stdout: "", stderr: "", truncated: false, stderrTruncated: false, durationMs: 0) }))
        let denied = try await python.execute(
            LocalPythonTool.Arguments(script: "open('/workspace/index.html','w').write('x')"),
            context: frozen)
        #expect(denied.exitStatus == 126)
        #expect(denied.summary.contains("status=unsupported"))

        let open = ShellOpenTool(center: ShellSessionCenter(
            backend: UnavailableShellBackend(), policy: ShellCommandPolicy()))
        let openDenied = try await open.execute(
            ShellOpenTool.Arguments(command: ""), context: frozen)
        #expect(openDenied.exitStatus == 126)

        let exchange = ShellExchangeTool(center: ShellSessionCenter(
            backend: UnavailableShellBackend(), policy: ShellCommandPolicy()))
        let exchangeDenied = try await exchange.execute(
            ShellExchangeTool.Arguments(sessionID: "s", input: "rm /workspace/index.html"),
            context: frozen)
        #expect(exchangeDenied.exitStatus == 126)
    }
}
