// FloeAppTests — delegated-child execution through the real App composition.
//
// This is the App-level counterpart of the runtime package dispatch tests: a
// delegated child's calls run through the REAL `FloeAgentRuntime.dispatchChildTool`
// chain (catalog, effective ceiling, main-only boundary, approval policy,
// mutation lease, the same executor) and the executed tools are the App's REAL
// registered `exec.shell` / `shell.*`, routed by the
// production `ToolEnvironmentRouting` into the TinyEMU Linux guest prepared by
// the production platform services. A host-side Python or mock backend is
// never accepted: the file is written by the guest and the hash is computed in
// the guest, then verified from the host filesystem.
//
// Coverage:
//  * child guest shell + Python end to end (real guest artifacts/hashes);
//  * one guest shared by the parent run and TWO distinct delegated children
//    with IDENTICAL provider call ids (`call_1` in every client): genuine
//    temporal overlap, distinct PTY session identities, per-client output
//    isolation, a shared-file writer conflict with no interleaving, lifecycle
//    refusal while consumers are active, a per-session Ctrl-C that stops one
//    client while a sibling finishes and the guest stays usable, the
//    execution-cancellation case — cancelling one child's OWN cancellation
//    token interrupts that child's in-flight guest command while the sibling
//    and the VM are unaffected — and cross-client PTY ownership: a sibling
//    can neither exchange, signal nor close another client's live session,
//    and the denied attempt leaves the owner's session usable;
//  * the child-side autonomous workflow (tools.search → skill.search →
//    skill.read required-tool activation → guest shell/Python artifact) driven
//    by the REAL child loop against the App's REAL catalog, with a SCRIPTED
//    provider adapter (clearly NOT a real model) and the main-only `delegate`
//    boundary proven inside the same run.
//
// The real-guest tests are opt-in (`FLOE_REALVM_QUALIFICATION=1`) because the
// first run downloads and boots the pinned guest image; a plain disabled run is
// reported as disabled, never as a pass.

#if canImport(SwiftUI) && canImport(UIKit) && DEBUG
import Foundation
import Testing
import FloeCore
import FloeModels
import FloeProviders
import FloeTools
import FloeEnvironments
import FloeAgentRuntime
import FloeSecurity
import UserNotifications
import FloeExecution
import FloePersistence
import FloeSkills
@testable import FloeApp

// MARK: - Scripted provider adapters (never a real model)

/// An adapter that is never used: tests that drive the canonical child
/// dispatcher directly never enter a provider loop.
private struct UnusedProviderAdapter: ProviderAdapter {
    let protocolKind: ModelProtocol = .openAIChatCompletions
    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

/// Holds a real parent run open while the test exercises its child dispatcher.
/// The initial event crosses the real provider boundary; cancellation joins
/// the producer instead of leaving an idle-runtime fixture or a leaked task.
private struct QualificationHoldingProviderAdapter: ProviderAdapter {
    let protocolKind: ModelProtocol = .openAIChatCompletions
    let hold: CancellationToken

    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials)
        -> AsyncThrowingStream<AgentEvent, Error> {
        let hold = hold
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(.init(text: "Guest qualification parent is active.")))
            let producer = Task {
                // A deliberately open scripted stream still needs progress events:
                // production correctly terminates a silent provider after its idle
                // deadline. Keep this fixture alive without weakening that guard.
                var ticks = 0
                while !hold.isCancelled && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                    ticks += 1
                    if ticks % 100 == 0, !hold.isCancelled, !Task.isCancelled {
                        continuation.yield(.textDelta(.init(text: ".")))
                    }
                }
                if !Task.isCancelled {
                    continuation.yield(.completed(.init(stopReason: .endTurn)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

/// One scripted provider stream per call, in order. Used to drive the REAL
/// child loop with deterministic turns; the test labels this as a scripted
/// provider because no model inference happens. Each `stream` call records the
/// exact wire request, so the tests can assert the progressive schema set and
/// the full name ceiling that really reached the child.
private final class ScriptedProviderAdapter: ProviderAdapter, @unchecked Sendable {
    let protocolKind: ModelProtocol = .openAIChatCompletions

    private let lock = NSLock()
    private var turns: [[AgentEvent]]
    private var schemaNames: [[String]] = []
    private var ceilingNames: [[String]] = []
    private var systemPrompts: [String] = []
    /// Optional gate awaited before a turn at this index is delivered.
    private var gates: [Int: @Sendable () async -> Void]

    init(turns: [[AgentEvent]], gates: [Int: @Sendable () async -> Void] = [:]) {
        self.turns = turns
        self.gates = gates
    }

    var requestCount: Int { lock.withLock { schemaNames.count } }
    var firstSchemaNames: [String] { lock.withLock { schemaNames.first ?? [] } }
    var lastSchemaNames: [String] { lock.withLock { schemaNames.last ?? [] } }
    var firstCeilingCount: Int { lock.withLock { ceilingNames.first?.count ?? 0 } }
    var recordedSystemPrompts: [String] { lock.withLock { systemPrompts } }

    func stream(
        request: ProviderStreamRequest,
        credentials: ProviderCredentials
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let index = lock.withLock { schemaNames.count }
        lock.withLock {
            schemaNames.append(request.toolSchemas.map(\.name))
            ceilingNames.append(request.allToolNames)
            systemPrompts.append(request.messages.first(where: { $0.role == "system" })?.content ?? "")
        }
        let gate = lock.withLock { gates[index] }
        return AsyncThrowingStream { continuation in
            Task {
                if let gate { await gate() }
                let turn: [AgentEvent]? = self.lock.withLock {
                    self.turns.isEmpty ? nil : self.turns.removeFirst()
                }
                if let turn {
                    for event in turn { continuation.yield(event) }
                } else {
                    // Defensive terminal turn: a scripted run that asks for
                    // more input than its script provides ends with text, not
                    // an empty response loop.
                    continuation.yield(.textDelta(.init(text: "scripted provider exhausted its turns")))
                }
                continuation.yield(.completed(.init(stopReason: .endTurn)))
                continuation.finish()
            }
        }
    }

    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

private actor DiscardingAuditSink: AuditSink {
    func record(_ entry: AuditEntry) async throws {}
}

/// Records every audit entry the runtime produces. Audit entries carry the
/// run, tool name, decision and exit status (never a provider call id), so
/// this is used for counting real dispatches, not for per-client routing.
private actor RecordingAuditSink: AuditSink {
    private(set) var entries: [AuditEntry] = []
    func record(_ entry: AuditEntry) async throws { entries.append(entry) }
    func snapshot() -> [AuditEntry] { entries }
}

private actor EphemeralCheckpointStore: CheckpointStore {
    private var checkpoints: [UUID: AgentCheckpoint] = [:]
    func save(_ checkpoint: AgentCheckpoint) throws { checkpoints[checkpoint.runID] = checkpoint }
    func load(runID: UUID) throws -> AgentCheckpoint? { checkpoints[runID] }
}

@Suite("FloeApp.SubagentSimulatorExecution")
@MainActor
struct SubagentSimulatorExecutionTests {
    /// Pinned-image verified download + expand and a cold TinyEMU boot can
    /// take several minutes on a first run.
    private let bootTimeout: TimeInterval = 1200

    // MARK: - Workspace / guest helpers

    private func makeWorkspaceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("subagent-guest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Same owner key `prepareWorkspaceEnvironment` uses, so the test drives
    /// the container for its own root and never an unrelated environment.
    private func environmentID(forRoot root: URL, registry: EnvironmentRegistry) async -> String? {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let workspaceID = FloeDigest.sha256Hex(Data(canonical.path.utf8))
        let owned = await registry.containersOwned(by: workspaceID)
        return owned.first { $0.kind == .project && $0.state != .deleting }?.id
    }

    private func waitForAsync(timeout: TimeInterval, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return await condition()
    }

    /// Writes the test-owned helper scripts into the task workspace. The guest
    /// sees the same files through its mounted /workspace share; the scripts
    /// run INSIDE the guest (real python3), never on the host.
    private func writeHelperScripts(root: URL) throws {
        let directory = root.appendingPathComponent("mc", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = """
        import os, sys, time, pathlib

        label = sys.argv[1]
        seconds = float(sys.argv[2])
        shared_lines = int(sys.argv[3]) if len(sys.argv) > 3 else 0
        shared_prefix = sys.argv[4] if len(sys.argv) > 4 else ''
        base = pathlib.Path('mc')
        base.mkdir(exist_ok=True)
        timeline = base / (label.lower() + '.timeline')
        with timeline.open('a') as handle:
            handle.write('%s_START %.3f\\n' % (label, time.time()))
        if shared_lines:
            with (base / 'shared.txt').open('a') as handle:
                for index in range(1, shared_lines + 1):
                    handle.write('%s%02d\\n' % (shared_prefix, index))
                    handle.flush()
                    time.sleep(0.05)
        time.sleep(seconds)
        with timeline.open('a') as handle:
            handle.write('%s_END %.3f\\n' % (label, time.time()))
        print('%s_OK pid=%d' % (label, os.getpid()))
        """
        try Data(script.utf8).write(to: directory.appendingPathComponent("multiclient.py"))
    }

    /// Reads the guest-written timeline for one label; the values are the
    /// guest's own clock, so overlap is proven from inside the VM.
    private func timeline(_ label: String, root: URL) -> (start: Double?, end: Double?) {
        let url = root.appendingPathComponent("mc/\(label.lowercased()).timeline")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return (nil, nil) }
        var start: Double?, end: Double?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let value = Double(parts[1]) else { continue }
            if parts[0] == "\(label.uppercased())_START" { start = value }
            if parts[0] == "\(label.uppercased())_END" { end = value }
        }
        return (start, end)
    }

    private func waitForTimeline(
        _ label: String,
        marker: String,
        root: URL,
        timeout: TimeInterval
    ) async -> Bool {
        await waitForAsync(timeout: timeout) {
            let url = root.appendingPathComponent("mc/\(label.lowercased()).timeline")
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return text.contains(marker)
        }
    }

    /// Boots this test's own guest and returns its explicit environment id.
    private func bootGuest(root: URL) async throws -> String {
        let environment = try await appQualificationEnvironment()
        let services = FloePlatformServices.shared
        try await services.prepareWorkspaceEnvironment(root: root)
        guard let environmentID = await environmentID(
            forRoot: root, registry: environment.environmentRegistry
        ) else {
            throw FloeError.notFound("No Linux project environment exists for this test's workspace root")
        }
        try await services.activateLinuxGuestWithPreparation(
            id: environmentID, cancellation: CancellationToken())
        let ready = await waitForAsync(timeout: bootTimeout) {
            await services.linuxEnvironmentAvailable(id: environmentID)
        }
        guard ready else {
            let status = await services.linuxEnvironmentStatus(id: environmentID)
            throw FloeError.validationFailed("Linux guest never became available: \(String(describing: status))")
        }
        return environmentID
    }

    private func makeRuntime(
        root: URL,
        conversationID: UUID,
        runID: UUID,
        allowedToolNames: Set<String>?,
        environmentID: String?,
        adapter: any ProviderAdapter,
        auditSink: (any AuditSink)? = DiscardingAuditSink(),
        environmentLifecycleWait: TimeInterval = 30
    ) -> FloeAgentRuntime {
        let provider = ProviderProfile(
            kind: .openAI,
            wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://child-guest.example/v1")!,
            displayName: "Child Guest Provider")
        let model = ModelProfile(
            providerID: provider.id,
            remoteModelID: "child-guest-model",
            displayName: "Child Guest Model",
            limits: ModelLimits(contextTokens: 8_192, maxOutputTokens: 1_024),
            capabilities: [.tools])
        return FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                conversationID: conversationID,
                provider: provider,
                model: model,
                allowedToolNames: allowedToolNames,
                workspaceRootURL: root,
                environmentID: environmentID,
                environmentLifecycleWait: environmentLifecycleWait
            ),
            adapter: adapter,
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: CatalogToolExecutor(),
            auditSink: auditSink,
            checkpointStore: EphemeralCheckpointStore(),
            runID: runID
        )
    }

    private func toolCall(id: String, toolName: String, arguments: String) throws -> ToolCall {
        try ToolCall(
            id: id,
            toolName: toolName,
            argumentsJSON: Data(arguments.utf8),
            scope: .local
        )
    }

    private func clientContext(
        runID: UUID,
        conversationID: UUID,
        environmentID: String,
        root: URL,
        allowedToolNames: Set<String>,
        identity: ChildExecutionIdentity,
        dispatcher: ChildToolDispatcher,
        peers: PeerCollaborationHandle,
        cancellation: CancellationToken = CancellationToken()
    ) -> ToolContext {
        ToolContext(
            runID: runID,
            scope: .local,
            allowedToolNames: allowedToolNames,
            workspaceRootURL: root,
            cancellation: cancellation,
            environmentID: environmentID,
            conversationID: conversationID,
            childExecution: ChildExecutionHandoff(
                identity: identity, dispatcher: dispatcher, peers: peers
            ),
            clientSessionID: "child:\(identity.childID.uuidString)")
    }

    /// Requires the guest booted by the REAL App default boot-asset path is
    /// the qualified kernel. This is a prerequisite, never weakened.
    private func requireQualifiedKernel(
        runtime: FloeAgentRuntime,
        identity: ChildExecutionIdentity,
        context: ToolContext
    ) async throws {
        let unameCall = try toolCall(
            id: "kernel-check", toolName: "exec.shell", arguments: #"{"command":"uname -r"}"#)
        let unameResult = await runtime.dispatchChildTool(
            unameCall, identity: identity, childContext: context)
        try #require(unameResult.status == .ok, "guest uname failed: \(unameResult.outputSummary)")
        try #require(
            unameResult.outputSummary.contains("6.18.56"),
            "App did not boot the qualified kernel: \(unameResult.outputSummary)")
        print("FLOE_REALVM_UNAME=\(unameResult.outputSummary)")
    }

    // A large command must traverse the real tool, ownership routing and Linux
    // transport. A recording backend alone cannot catch framing or ARG_MAX
    // failures. This reuses the existing opt-in VM host and its owned cleanup.
    @Test(
        "large Unicode shell script preserves cwd, environment, stdin and exit code in the real guest",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_QUALIFICATION"] == "1")
    )
    func largeShellScriptEndToEnd() async throws {
        let root = try makeWorkspaceRoot()
        var ownedEnvironmentID = ""
        let services = FloePlatformServices.shared
        let parentHold = CancellationToken()
        var ownedRuntime: FloeAgentRuntime?
        var parentTask: Task<Void, Error>?
        func cleanup() async {
            if let ownedRuntime { await ownedRuntime.cancel() }
            parentHold.cancel()
            if let parentTask {
                parentTask.cancel()
                do { try await parentTask.value }
                catch is CancellationError { }
                catch let error as FloeError where error == .cancelled { }
                catch { Issue.record("Large-shell parent cleanup failed: \(error)") }
            }
            if !ownedEnvironmentID.isEmpty {
                do {
                    try await services.stopEnvironment(id: ownedEnvironmentID)
                    try await services.deleteEnvironment(id: ownedEnvironmentID)
                } catch {
                    Issue.record("Large-shell qualification cleanup failed: \(error)")
                    return
                }
            }
            do { try FileManager.default.removeItem(at: root) }
            catch { Issue.record("Large-shell workspace cleanup failed: \(error)") }
        }
        do {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID
            let runID = UUID(), conversationID = UUID()
            let ceiling: Set<String> = ["exec.shell"]
            let runtime = makeRuntime(
                root: root, conversationID: conversationID, runID: runID,
                allowedToolNames: ceiling, environmentID: environmentID,
                adapter: QualificationHoldingProviderAdapter(hold: parentHold))
            ownedRuntime = runtime
            parentTask = Task { try await runtime.start(goal: "Qualify large guest scripts") }
            let parentIsActive = await waitForAsync(timeout: 20) {
                if case .streamingModel = await runtime.state { return true }
                return false
            }
            try #require(parentIsActive, "Parent must be active before child execution")
            let context = ToolContext(
                runID: runID, scope: .local, allowedToolNames: ceiling,
                workspaceRootURL: root, cancellation: CancellationToken(),
                environmentID: environmentID, conversationID: conversationID)
            let identity = ChildExecutionIdentity(
                parentRunID: runID, rootTaskID: conversationID,
                delegateCallID: "large-shell-qualification")
            try await requireQualifiedKernel(runtime: runtime, identity: identity, context: context)

            let input = "中文 English 日本語"
            let comment = "# large script 中文 日本語 " + String(repeating: "x", count: 180) + "\n"
            // Over 1 MiB: exceeds both the former 16 KiB tool limit and a
            // typical shell argument/framing ceiling; never sent as host code.
            let script = String(repeating: comment, count: 6_000) + """
            IFS= read -r input
            printf '%s|%s' "$input" "$FLOE_LARGE_SCRIPT_TEST" > result.txt
            pwd
            sha256sum result.txt
            """
            #expect(script.utf8.count > 1_048_576)
            let expected = Data((input + "|environment-kept").utf8)
            let call = try toolCall(id: "large-script", toolName: "exec.shell",
                arguments: Self.json([
                    "command": script, "cwd": "nested",
                    "env": ["FLOE_LARGE_SCRIPT_TEST": "environment-kept"],
                    "stdin": input + "\n", "timeoutSeconds": 60,
                    "maxOutputBytes": 4096
                ]))
            let result = await runtime.dispatchChildTool(call, identity: identity, childContext: context)
            try #require(result.status == .ok, "Large guest script failed: \(result.outputSummary)")
            #expect(result.outputSummary.contains("/nested"))
            #expect(result.outputSummary.contains(FloeDigest.sha256Hex(expected)))
            #expect(try Data(contentsOf: root.appendingPathComponent("nested/result.txt")) == expected)

            let failureCall = try toolCall(id: "large-script-failure", toolName: "exec.shell",
                arguments: Self.json([
                    "command": String(repeating: comment, count: 200) + "exit 7\n",
                    "timeout": 60
                ]))
            let failure = await runtime.dispatchChildTool(
                failureCall, identity: identity, childContext: context)
            #expect(failure.status != .ok)
            #expect(failure.outputSummary.contains("exit=7"), "\(failure.outputSummary)")
            print("FLOE_REALVM_LARGE_SCRIPT_BYTES=\(script.utf8.count)")
            print("FLOE_REALVM_LARGE_SCRIPT_SHA256=\(FloeDigest.sha256Hex(expected))")
            await cleanup()
        } catch {
            Issue.record("Large-shell real guest execution threw: \(error)")
            await cleanup()
        }
    }

    // MARK: - Base child guest execution

    @Test(
        "delegated execute child runs real guest Shell and Python, writes a file and returns the guest hash",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_QUALIFICATION"] == "1")
    )
    func childGuestShellAndPythonEndToEnd() async throws {
        let root = try makeWorkspaceRoot()
        var ownedEnvironmentID = ""
        let services = FloePlatformServices.shared

        func cleanup() async {
            if !ownedEnvironmentID.isEmpty {
                do {
                    try await services.stopEnvironment(id: ownedEnvironmentID)
                    try await services.deleteEnvironment(id: ownedEnvironmentID)
                } catch {
                    Issue.record("Owned qualification environment cleanup failed: \(error)")
                    return // Preserve its workspace if shutdown/deletion did not finish.
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID

            let conversationID = UUID()
            let runID = UUID()
            let ceiling: Set<String> = ["exec.shell", "delegate", "conversation.spawn"]
            let runtime = makeRuntime(
                root: root, conversationID: conversationID, runID: runID,
                allowedToolNames: ceiling, environmentID: environmentID,
                adapter: UnusedProviderAdapter())
            let childContext = ToolContext(
                runID: runID,
                scope: .local,
                allowedToolNames: ceiling,
                workspaceRootURL: root,
                cancellation: CancellationToken(),
                environmentID: environmentID,
                conversationID: conversationID
            )
            let firstChild = ChildExecutionIdentity(
                parentRunID: runID, rootTaskID: conversationID, delegateCallID: "delegate-shell"
            )

            // Verify the kernel selected by the real App's default boot-asset
            // adoption path, before accepting child execution as new-kernel
            // proof. The 6.18.56 requirement itself is never weakened.
            try await requireQualifiedKernel(
                runtime: runtime, identity: firstChild, context: childContext)

            // 1. exec.shell: the GUEST writes the file and computes the hash.
            let payload = "hello from the guest child"
            let expectedHash = FloeDigest.sha256Hex(Data(payload.utf8))
            let shellCall = try toolCall(
                id: "child-shell-1",
                toolName: "exec.shell",
                arguments: #"{"command":"mkdir -p child && printf 'hello from the guest child' > child/out.txt && sha256sum child/out.txt"}"#)
            let shellResult = await runtime.dispatchChildTool(
                shellCall, identity: firstChild, childContext: childContext)
            #expect(shellResult.status == .ok, "child exec.shell failed: \(shellResult.outputSummary)")
            #expect(shellResult.outputSummary.contains(expectedHash),
                    "guest sha256sum output missing from: \(shellResult.outputSummary)")

            // Host-side verification of the guest's real side effect.
            let written = try Data(contentsOf: root.appendingPathComponent("child/out.txt"))
            #expect(String(decoding: written, as: UTF8.self) == payload)
            #expect(FloeDigest.sha256Hex(written) == expectedHash)

            // 2. python3 through exec.shell: the GUEST reads the file and reports the
            //    hash; a host/mock Python stand-in would not see the guest
            //    version string and the mounted workspace together.
            let pythonScript = """
            import hashlib, os, pathlib, sys
            candidates = [pathlib.Path('child/out.txt'), pathlib.Path('/workspace/child/out.txt')]
            p = next((c for c in candidates if c.exists()), None)
            assert p is not None, (os.getcwd(), sorted(os.listdir('.')), sys.version)
            data = p.read_bytes()
            print('FLOE_CHILD_PY_READ=' + data.decode())
            print('FLOE_CHILD_PY_HASH=' + hashlib.sha256(data).hexdigest())
            print('FLOE_CHILD_PY_PLATFORM=' + sys.platform)
            """
            let pythonCall = try toolCall(
                id: "child-python-1",
                toolName: "exec.shell",
                arguments: String(decoding: try JSONSerialization.data(withJSONObject: ["command": "python3 -", "stdin": pythonScript, "timeout": 60]), as: UTF8.self))
            let pythonResult = await runtime.dispatchChildTool(
                pythonCall, identity: firstChild, childContext: childContext)
            #expect(pythonResult.status == .ok, "child Linux Python failed: \(pythonResult.outputSummary)")
            #expect(pythonResult.outputSummary.contains("FLOE_CHILD_PY_READ=\(payload)"))
            #expect(pythonResult.outputSummary.contains("FLOE_CHILD_PY_HASH=\(expectedHash)"))
            #expect(pythonResult.outputSummary.contains("FLOE_CHILD_PY_PLATFORM=linux"))

            // 3. The main-only callable boundary through the real App
            //    composition: a delegated child can never delegate or spawn.
            let delegateCall = try toolCall(
                id: "child-delegate-1", toolName: "delegate", arguments: #"{"task":"nested"}"#)
            let deniedDelegate = await runtime.dispatchChildTool(
                delegateCall, identity: firstChild, childContext: childContext)
            #expect(deniedDelegate.status == .denied)
            let spawnCall = try toolCall(
                id: "child-spawn-1", toolName: "conversation.spawn",
                arguments: #"{"title":"nested","objective":"nested"}"#)
            let deniedSpawn = await runtime.dispatchChildTool(
                spawnCall, identity: firstChild, childContext: childContext)
            #expect(deniedSpawn.status == .denied)

            await cleanup()
        } catch {
            Issue.record("child guest execution threw: \(error)")
            await cleanup()
        }
    }

    // MARK: - One guest, two children, identical provider call ids

    /// The shared-VM multi-client contract: the parent run and TWO distinct
    /// delegated children work against ONE Linux guest environment at the same
    /// time. Every client's first provider call carries the identical call id
    /// `call_1` (providers are not globally unique), and each client is
    /// identified by its own trusted runtime identity, never by the provider
    /// id. The test proves, through the real App catalog + canonical
    /// dispatcher + real guest:
    ///
    ///  * genuine temporal overlap of three guest processes (guest clock);
    ///  * distinct PTY session identities and per-client output isolation;
    ///  * a shared-file writer conflict with no interleaved/corrupt lines;
    ///  * the environment lifecycle refuses an unsafe stop while consumers
    ///    are active (with the real active-consumer labels);
    ///  * Ctrl-C on ONE session stops that client's process while a sibling
    ///    command finishes and the guest stays usable.
    @Test(
        "one guest, parent + two children, identical call_1: real overlap, sessions, shared file and interrupt isolation",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_QUALIFICATION"] == "1")
    )
    func parentAndTwoChildrenShareOneGuest() async throws {
        let root = try makeWorkspaceRoot()
        try writeHelperScripts(root: root)
        var ownedEnvironmentID = ""
        let services = FloePlatformServices.shared

        func cleanup() async {
            if !ownedEnvironmentID.isEmpty {
                do {
                    try await services.stopEnvironment(id: ownedEnvironmentID)
                    try await services.deleteEnvironment(id: ownedEnvironmentID)
                } catch {
                    Issue.record("Owned qualification environment cleanup failed: \(error)")
                    return // Preserve its workspace if shutdown/deletion did not finish.
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID

            let conversationID = UUID()
            let runID = UUID()
            let ceiling: Set<String> = [
                "exec.shell", "shell.open", "shell.exchange",
                "shell.close", "shell.signal", "environment.stopLinux",
                "environment.linuxStatus",
            ]
            let auditSink = RecordingAuditSink()
            let parentCall = try toolCall(
                id: "call_1",
                toolName: "exec.shell",
                arguments: #"{"command":"echo \"$FLOE_CLIENT_TAG\" > mc/parent.env && pwd > mc/parent.cwd && python3 mc/multiclient.py PARENT 6 40 P","env":{"FLOE_CLIENT_TAG":"parent-run"},"timeout":60}"#)
            let parentFinalText = "parent finished: parent started while both children were running"
            let parentAdapter = ScriptedProviderAdapter(
                turns: [
                    [.toolRequest(parentCall)],
                    [.textDelta(.init(text: parentFinalText)), .completed(.init(stopReason: .endTurn))],
                ])
            let runtime = makeRuntime(
                root: root, conversationID: conversationID, runID: runID,
                allowedToolNames: ceiling, environmentID: environmentID,
                adapter: parentAdapter, auditSink: auditSink, environmentLifecycleWait: 1)
            // NOTE: the parent run is started only AFTER both children's guest
            // processes are really running (see below), so the three real
            // executions overlap without holding a provider stream open across
            // the children's setup.

            let executor = CatalogToolExecutor()
            let bus = SubagentPeerBus()

            func makeClient(
                identity: ChildExecutionIdentity,
                cancellation: CancellationToken = CancellationToken()
            ) -> ToolContext {
                clientContext(
                    runID: runID, conversationID: conversationID,
                    environmentID: environmentID, root: root,
                    allowedToolNames: ceiling, identity: identity,
                    dispatcher: ChildToolDispatcher(
                        descriptorProvider: { name in executor.descriptor(named: name) },
                        allDescriptors: { executor.allDescriptors },
                        dispatch: { call, context in
                            await runtime.dispatchChildTool(
                                call, identity: identity, childContext: context)
                        }),
                    peers: bus.handle(for: identity),
                    cancellation: cancellation)
            }

            // Kernel prerequisite through a dedicated child identity, before
            // the concurrency phase (so every client's first call can be
            // `call_1`).
            let kernelIdentity = ChildExecutionIdentity(
                parentRunID: runID, rootTaskID: conversationID, delegateCallID: "delegate-kernel")
            let kernelContext = makeClient(identity: kernelIdentity)
            try await requireQualifiedKernel(
                runtime: runtime, identity: kernelIdentity, context: kernelContext)

            // --- Client identities -----------------------------------------
            let child1 = ChildExecutionIdentity(
                parentRunID: runID, rootTaskID: conversationID, delegateCallID: "delegate-child-1")
            // The real per-child cancellation scope: this token is what the
            // child's own loop derives and passes as its execution context's
            // cancellation, so cancelling it must interrupt only this client.
            let child1Token = CancellationToken()
            let child1Context = makeClient(identity: child1, cancellation: child1Token)
            let child2 = ChildExecutionIdentity(
                parentRunID: runID, rootTaskID: conversationID, delegateCallID: "delegate-child-2")
            let child2Context = makeClient(identity: child2)

            // --- Isolation matrix: cwd / env / stdout / stderr / exit ------
            // Each client's call runs in the guest with its OWN cwd and env,
            // and each result carries only its own stdout/stderr/exit status.
            let iso1 = try toolCall(
                id: "call_1", toolName: "exec.shell",
                arguments: try Self.json([
                    "command": "echo \"$FLOE_CLIENT_TAG\" > child1.env && pwd > child1.cwd && echo CHILD1_ISO_OK",
                    "env": ["FLOE_CLIENT_TAG": "child-one"],
                    "cwd": "mc",
                ]))
            let iso1Result = await runtime.dispatchChildTool(
                iso1, identity: child1, childContext: child1Context)
            #expect(iso1Result.status == .ok && iso1Result.outputSummary.contains("CHILD1_ISO_OK"),
                    "child1 isolation call failed: \(iso1Result.outputSummary)")
            let iso2 = try toolCall(
                id: "call_1", toolName: "exec.shell",
                arguments: try Self.json([
                    "command": "echo \"$FLOE_CLIENT_TAG\" > child2.env && pwd > child2.cwd && echo CHILD2_ISO_OK",
                    "env": ["FLOE_CLIENT_TAG": "child-two"],
                    "cwd": ".",
                ]))
            let iso2Result = await runtime.dispatchChildTool(
                iso2, identity: child2, childContext: child2Context)
            #expect(iso2Result.status == .ok && iso2Result.outputSummary.contains("CHILD2_ISO_OK"),
                    "child2 isolation call failed: \(iso2Result.outputSummary)")
            #expect(!iso1Result.outputSummary.contains("CHILD2_ISO_OK")
                        && !iso2Result.outputSummary.contains("CHILD1_ISO_OK"),
                    "client results must never cross")

            let child1Env = (try? String(contentsOf: root.appendingPathComponent("mc/child1.env"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let child2Env = (try? String(contentsOf: root.appendingPathComponent("child2.env"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let child1Cwd = (try? String(contentsOf: root.appendingPathComponent("mc/child1.cwd"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let child2Cwd = (try? String(contentsOf: root.appendingPathComponent("child2.cwd"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(child1Env == "child-one", "child1 must see its own env, got \(String(describing: child1Env))")
            #expect(child2Env == "child-two", "child2 must see its own env, got \(String(describing: child2Env))")
            #expect(child1Cwd?.hasSuffix("/mc") == true, "child1 must run in its own cwd, got \(String(describing: child1Cwd))")
            #expect(child2Cwd?.hasSuffix("/workspace") == true, "child2 must run in the workspace root, got \(String(describing: child2Cwd))")

            // stderr + non-zero exit stay per client.
            let stderrCall = try toolCall(
                id: "call_2", toolName: "exec.shell",
                arguments: #"{"command":"echo CHILD1_STDERR_MARK >&2; exit 7"}"#)
            let stderrResult = await runtime.dispatchChildTool(
                stderrCall, identity: child1, childContext: child1Context)
            #expect(stderrResult.status == .failed, "a non-zero exit must stay a failure: \(stderrResult.outputSummary)")
            #expect(stderrResult.outputSummary.contains("CHILD1_STDERR_MARK"),
                    "the client's own stderr must be returned: \(stderrResult.outputSummary)")
            #expect(stderrResult.outputSummary.contains("exit=7"), "the exit status must be per client: \(stderrResult.outputSummary)")
            let otherCall = try toolCall(
                id: "call_3", toolName: "exec.shell",
                arguments: #"{"command":"echo CHILD2_STDOUT_MARK"}"#)
            let otherResult = await runtime.dispatchChildTool(
                otherCall, identity: child2, childContext: child2Context)
            #expect(otherResult.status == .ok && otherResult.outputSummary.contains("CHILD2_STDOUT_MARK"))
            #expect(!otherResult.outputSummary.contains("CHILD1_STDERR_MARK"),
                    "another client's stderr must never appear in this result")

            let open1 = try toolCall(id: "call_4", toolName: "shell.open", arguments: #"{"cwd":"."}"#)
            let open1Result = await runtime.dispatchChildTool(
                open1, identity: child1, childContext: child1Context)
            #expect(open1Result.status == .ok, "child1 shell.open failed: \(open1Result.outputSummary)")
            let session1 = try #require(
                Self.sessionID(from: open1Result.outputSummary), "child1 must return a sessionID")

            let start1 = try toolCall(
                id: "call_5", toolName: "shell.exchange",
                arguments: try Self.json(["sessionID": session1, "input": "python3 mc/multiclient.py CHILD1 10 0\n", "waitMs": 800]))
            let start1Result = await runtime.dispatchChildTool(
                start1, identity: child1, childContext: child1Context)
            #expect(start1Result.status == .ok, "child1 exchange failed: \(start1Result.outputSummary)")

            // --- Client 2: delegated child, PTY session, call_1 ------------
            let open2 = try toolCall(id: "call_6", toolName: "shell.open", arguments: #"{"cwd":"."}"#)
            let open2Result = await runtime.dispatchChildTool(
                open2, identity: child2, childContext: child2Context)
            #expect(open2Result.status == .ok, "child2 shell.open failed: \(open2Result.outputSummary)")
            let session2 = try #require(
                Self.sessionID(from: open2Result.outputSummary), "child2 must return a sessionID")
            #expect(session1 != session2, "each client must own a distinct session")

            let start2 = try toolCall(
                id: "call_7", toolName: "shell.exchange",
                arguments: try Self.json(["sessionID": session2, "input": "python3 mc/multiclient.py CHILD2 10 40 C\n", "waitMs": 800]))
            let start2Result = await runtime.dispatchChildTool(
                start2, identity: child2, childContext: child2Context)
            #expect(start2Result.status == .ok, "child2 exchange failed: \(start2Result.outputSummary)")

            // Both child processes are really running before the parent's
            // `call_1` is released.
            let child1Started = await waitForTimeline("CHILD1", marker: "CHILD1_START", root: root, timeout: 30)
            let child2Started = await waitForTimeline("CHILD2", marker: "CHILD2_START", root: root, timeout: 30)
            #expect(child1Started && child2Started, "both child session commands must start in the guest")
            try #require(child1Started && child2Started, "children never started")

            // The parent run starts NOW: its first provider turn dispatches
            // exec.shell immediately (provider call id `call_1`, identical to
            // the first call of both children), while both child processes are
            // still sleeping in their own PTY sessions.
            let parentTask = Task { try await runtime.start(goal: "parent multi-client task") }

            // --- Lifecycle refusal while consumers are active --------------
            let parentStarted = await waitForTimeline("PARENT", marker: "PARENT_START", root: root, timeout: 30)
            if !parentStarted {
                // Diagnose the parent run's real terminal state before failing:
                // the fixture must not be blamed for a run/dispatch failure.
                let parentState = await runtime.state
                let audit = await auditSink.snapshot()
                print("FLOE_MULTICLIENT_PARENT_NOT_STARTED state=\(parentState.name) "
                    + "adapterRequests=\(parentAdapter.requestCount) audits=\(audit.map { "\($0.toolName):\($0.decision)" })")
            }
            try #require(parentStarted, "the parent's call_1 never started in the guest")
            let stopIdentity = ChildExecutionIdentity(
                parentRunID: runID, rootTaskID: conversationID, delegateCallID: "delegate-lifecycle")
            let stopContext = makeClient(identity: stopIdentity)
            let stopCall = try toolCall(
                id: "lifecycle-check", toolName: "environment.stopLinux", arguments: "{}")
            let stopResult = await runtime.dispatchChildTool(
                stopCall, identity: stopIdentity, childContext: stopContext)
            #expect(stopResult.status == .failed, "an unsafe stop must fail: \(stopResult.outputSummary)")
            #expect(stopResult.outputSummary.contains("busy"), "the refusal must name the real consumers: \(stopResult.outputSummary)")
            #expect(stopResult.outputSummary.contains("exec.shell"), "the refusal must list the active consumer: \(stopResult.outputSummary)")

            // --- Wait for the scripts to finish, then prove overlap ---------
            let child1Finished = await waitForTimeline("CHILD1", marker: "CHILD1_END", root: root, timeout: 60)
            let child2Finished = await waitForTimeline("CHILD2", marker: "CHILD2_END", root: root, timeout: 60)
            let parentFinished = await waitForTimeline("PARENT", marker: "PARENT_END", root: root, timeout: 60)
            #expect(child1Finished && child2Finished && parentFinished, "all three scripts must complete")
            try #require(child1Finished && child2Finished && parentFinished, "not every client completed")

            let parent = timeline("PARENT", root: root)
            let first = timeline("CHILD1", root: root)
            let second = timeline("CHILD2", root: root)
            let starts = [parent.start, first.start, second.start].compactMap { $0 }
            let ends = [parent.end, first.end, second.end].compactMap { $0 }
            #expect(starts.count == 3 && ends.count == 3)
            let latestStart = starts.max() ?? 0
            let earliestEnd = ends.min() ?? 0
            print("FLOE_MULTICLIENT_TIMELINE parent=\(parent) child1=\(first) child2=\(second)")
            #expect(latestStart < earliestEnd,
                    "the three guest processes must genuinely overlap (latest start \(latestStart) < earliest end \(earliestEnd))")

            // The parent's own env/cwd reached the guest process too, isolated
            // from both children.
            let parentEnv = (try? String(contentsOf: root.appendingPathComponent("mc/parent.env"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let parentCwd = (try? String(contentsOf: root.appendingPathComponent("mc/parent.cwd"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(parentEnv == "parent-run", "the parent must see its own env, got \(String(describing: parentEnv))")
            #expect(parentCwd?.hasSuffix("/workspace") == true, "the parent cwd must be the workspace root, got \(String(describing: parentCwd))")

            // --- Per-client output isolation --------------------------------
            let end1 = try toolCall(
                id: "call_8", toolName: "shell.exchange",
                arguments: try Self.json(["sessionID": session1, "waitMs": 4000]))
            let end1Result = await runtime.dispatchChildTool(
                end1, identity: child1, childContext: child1Context)
            #expect(end1Result.outputSummary.contains("CHILD1_OK"), "child1 output must carry its own marker")
            #expect(!end1Result.outputSummary.contains("CHILD2_OK"), "child1 must never see child2's output")
            let end2 = try toolCall(
                id: "call_9", toolName: "shell.exchange",
                arguments: try Self.json(["sessionID": session2, "waitMs": 4000]))
            let end2Result = await runtime.dispatchChildTool(
                end2, identity: child2, childContext: child2Context)
            #expect(end2Result.outputSummary.contains("CHILD2_OK"), "child2 output must carry its own marker")
            #expect(!end2Result.outputSummary.contains("CHILD1_OK"), "child2 must never see child1's output")

            // Sessions are run-scoped and addressed by an unguessable id that
            // is returned only to the client that opened it; an unknown id is
            // refused, and the two clients hold distinct ids (asserted above).
            let bogus = try toolCall(
                id: "call_10", toolName: "shell.exchange",
                arguments: try Self.json(["sessionID": UUID().uuidString.lowercased(), "waitMs": 50]))
            let bogusResult = await runtime.dispatchChildTool(
                bogus, identity: child1, childContext: child1Context)
            #expect(bogusResult.status != .ok, "an unknown session must be refused")

            // --- Shared-file writer conflict: no interleaving --------------
            let sharedText = (try? String(contentsOf: root.appendingPathComponent("mc/shared.txt"), encoding: .utf8)) ?? ""
            let lines = sharedText.split(separator: "\n").map(String.init)
            let parentLines = lines.filter { $0.hasPrefix("P") }
            let childLines = lines.filter { $0.hasPrefix("C") }
            #expect(parentLines.count == 40, "the parent must write exactly its 40 lines, got \(parentLines.count)")
            #expect(childLines.count == 40, "child2 must write exactly its 40 lines, got \(childLines.count)")
            #expect(lines.allSatisfy { $0.range(of: "^[PC][0-9]{2}$", options: .regularExpression) != nil },
                    "no torn/interleaved line may appear: \(lines.filter { $0.range(of: "^[PC][0-9]{2}$", options: .regularExpression) == nil })")
            #expect(parentLines == (1...40).map { String(format: "P%02d", $0) }, "the parent's own line order must hold")
            #expect(childLines == (1...40).map { String(format: "C%02d", $0) }, "child2's own line order must hold")

            // --- Cross-client PTY ownership: a sibling client of the same run
            // must never exchange, close or signal another client's live
            // session, and a denied foreign attempt must not unregister or
            // replace the original session for its owner.
            let foreignExchange = try toolCall(
                id: "call_16", toolName: "shell.exchange",
                arguments: try Self.json(["sessionID": session1, "input": "echo HIJACKED_SESSION\n", "waitMs": 800]))
            let foreignExchangeResult = await runtime.dispatchChildTool(
                foreignExchange, identity: child2, childContext: child2Context)
            #expect(foreignExchangeResult.status != .ok
                        && foreignExchangeResult.outputSummary.contains("denied"),
                    "a different client must be explicitly denied another client's live session: \(foreignExchangeResult.outputSummary)")

            let foreignSignal = try toolCall(
                id: "call_17", toolName: "shell.signal",
                arguments: try Self.json(["sessionID": session1, "signal": "INT"]))
            let foreignSignalResult = await runtime.dispatchChildTool(
                foreignSignal, identity: child2, childContext: child2Context)
            #expect(foreignSignalResult.status != .ok
                        && foreignSignalResult.outputSummary.contains("denied"),
                    "a different client must not signal another client's live session: \(foreignSignalResult.outputSummary)")

            let foreignClose = try toolCall(
                id: "call_18", toolName: "shell.close",
                arguments: try Self.json(["sessionID": session2]))
            let foreignCloseResult = await runtime.dispatchChildTool(
                foreignClose, identity: child1, childContext: child1Context)
            #expect(foreignCloseResult.status != .ok
                        && foreignCloseResult.outputSummary.contains("denied"),
                    "a different client must not close another client's live session: \(foreignCloseResult.outputSummary)")

            // The owners still drive their own sessions after the denied
            // foreign attempts.
            let ownerProbe1 = try toolCall(
                id: "call_19", toolName: "shell.exchange",
                arguments: try Self.json(["sessionID": session1, "input": "echo OWNER1_STILL_HERE\n", "waitMs": 1500]))
            let ownerProbe1Result = await runtime.dispatchChildTool(
                ownerProbe1, identity: child1, childContext: child1Context)
            #expect(ownerProbe1Result.status == .ok
                        && ownerProbe1Result.outputSummary.contains("OWNER1_STILL_HERE"),
                    "the owning client must keep its session after denied foreign attempts: \(ownerProbe1Result.outputSummary)")
            let ownerProbe2 = try toolCall(
                id: "call_20", toolName: "shell.exchange",
                arguments: try Self.json(["sessionID": session2, "input": "echo OWNER2_STILL_HERE\n", "waitMs": 1500]))
            let ownerProbe2Result = await runtime.dispatchChildTool(
                ownerProbe2, identity: child2, childContext: child2Context)
            #expect(ownerProbe2Result.status == .ok
                        && ownerProbe2Result.outputSummary.contains("OWNER2_STILL_HERE"),
                    "the other owner must keep its session too: \(ownerProbe2Result.outputSummary)")

            // --- Per-session interrupt: Ctrl-C stops ONE client's running
            // command while a sibling finishes and the guest stays usable.
            // Observed behavior of this implementation: the interrupt cancels
            // the session's foreground work and may also close the session
            // itself (a later exchange reports an unknown/expired session), so
            // the assertions below cover the contract that matters — the
            // interrupted command never completes, the sibling client finishes
            // normally and the VM keeps working.
            let start1b = try toolCall(
                id: "call_11", toolName: "shell.exchange",
                arguments: try Self.json(["sessionID": session1, "input": "python3 mc/multiclient.py CHILD1B 60 0\n", "waitMs": 800]))
            let start1bResult = await runtime.dispatchChildTool(
                start1b, identity: child1, childContext: child1Context)
            #expect(start1bResult.status == .ok)
            try #require(await waitForTimeline("CHILD1B", marker: "CHILD1B_START", root: root, timeout: 30),
                         "child1's second command must start")

            let start2b = try toolCall(
                id: "call_12", toolName: "shell.exchange",
                arguments: try Self.json(["sessionID": session2, "input": "python3 mc/multiclient.py CHILD2B 4 0\n", "waitMs": 800]))
            let start2bResult = await runtime.dispatchChildTool(
                start2b, identity: child2, childContext: child2Context)
            #expect(start2bResult.status == .ok)
            try #require(await waitForTimeline("CHILD2B", marker: "CHILD2B_START", root: root, timeout: 30),
                         "child2's second command must start")

            // Ctrl-C is delivered to ONE session's foreground process group.
            let interrupt = try toolCall(
                id: "call_13", toolName: "shell.exchange",
                arguments: try Self.json(["sessionID": session1, "input": "\u{3}", "waitMs": 1500]))
            let interruptResult = await runtime.dispatchChildTool(
                interrupt, identity: child1, childContext: child1Context)
            #expect(interruptResult.status != .denied && interruptResult.status != .cancelled,
                    "the interrupt must be delivered to the session: \(interruptResult.outputSummary)")

            let child2bFinished = await waitForTimeline("CHILD2B", marker: "CHILD2B_END", root: root, timeout: 30)
            #expect(child2bFinished, "the sibling's command must still finish normally")
            // The interrupted child's command must NOT complete: its END
            // marker never appears while the sibling's did.
            let interrupted = timeline("CHILD1B", root: root)
            #expect(interrupted.start != nil, "the interrupted command must have started")
            #expect(interrupted.end == nil, "the interrupted command must not report a normal completion")

            // A fresh one-shot command still works: the VM is not torn down by
            // one client's interrupt (this holds whether or not the interrupted
            // session itself was closed).
            let usable = try toolCall(
                id: "call_15", toolName: "exec.shell",
                arguments: #"{"command":"echo VM_STILL_USABLE"}"#)
            let usableResult = await runtime.dispatchChildTool(
                usable, identity: child2, childContext: child2Context)
            #expect(usableResult.status == .ok && usableResult.outputSummary.contains("VM_STILL_USABLE"),
                    "the guest must remain usable: \(usableResult.outputSummary)")

            // Session 1 is closed BEFORE its owning token is cancelled, so the
            // cancel scope applies only to the in-flight command below.
            let close1 = try toolCall(
                id: "call_21", toolName: "shell.close",
                arguments: try Self.json(["sessionID": session1]))
            _ = await runtime.dispatchChildTool(
                close1, identity: child1, childContext: child1Context)

            // --- Cancelling the child's OWN token interrupts its in-flight
            // guest command (not only a separate PTY Ctrl-C). This is the
            // execution-cancellation case: the child context's cancellation
            // token must reach the tool execution for that child's call.
            let start2c = try toolCall(
                id: "call_22", toolName: "shell.exchange",
                arguments: try Self.json(["sessionID": session2, "input": "python3 mc/multiclient.py CHILD2C 6 0\n", "waitMs": 800]))
            let start2cResult = await runtime.dispatchChildTool(
                start2c, identity: child2, childContext: child2Context)
            #expect(start2cResult.status == .ok)
            try #require(await waitForTimeline("CHILD2C", marker: "CHILD2C_START", root: root, timeout: 30),
                         "the sibling's long command must start first")

            let cancellableCall = try toolCall(
                id: "call_23", toolName: "exec.shell",
                arguments: #"{"command":"python3 mc/multiclient.py CHILD1C 45 0","timeout":90}"#)
            let cancellableTask = Task {
                await runtime.dispatchChildTool(
                    cancellableCall, identity: child1, childContext: child1Context)
            }
            try #require(await waitForTimeline("CHILD1C", marker: "CHILD1C_START", root: root, timeout: 30),
                         "the cancellable command must start before the token is cancelled")
            child1Token.cancel()
            let cancelledResult = await cancellableTask.value
            let cancelledTimeline = timeline("CHILD1C", root: root)
            #expect(cancelledResult.status == .cancelled,
                    Comment(rawValue: "cancelling the child's own token must interrupt its in-flight guest command: "
                        + "\(cancelledResult.status) \(cancelledResult.outputSummary)"))
            #expect(cancelledTimeline.start != nil)
            #expect(cancelledTimeline.end == nil,
                    "the interrupted command must not report a normal completion")

            let child2cFinished = await waitForTimeline("CHILD2C", marker: "CHILD2C_END", root: root, timeout: 30)
            #expect(child2cFinished, "the sibling client must still finish normally")

            let usableAfterCancel = try toolCall(
                id: "call_24", toolName: "exec.shell",
                arguments: #"{"command":"echo VM_USABLE_AFTER_CHILD_CANCEL"}"#)
            let usableAfterCancelResult = await runtime.dispatchChildTool(
                usableAfterCancel, identity: child2, childContext: child2Context)
            #expect(
                usableAfterCancelResult.status == .ok
                    && usableAfterCancelResult.outputSummary.contains("VM_USABLE_AFTER_CHILD_CANCEL"),
                "the guest must remain usable after a child cancellation: \(usableAfterCancelResult.outputSummary)")

            // Close the remaining session (test-owned hygiene) before waiting
            // on the parent run.
            let close2 = try toolCall(
                id: "call_25", toolName: "shell.close",
                arguments: try Self.json(["sessionID": session2]))
            _ = await runtime.dispatchChildTool(
                close2, identity: child2, childContext: child2Context)

            try await parentTask.value
            let parentState = await runtime.state
            if case .completed = parentState {
                // The parent's own run completed with its gated call_1.
            } else {
                Issue.record("the parent run must complete: \(parentState.name)")
            }

            let entries = await auditSink.snapshot()
            let allowed = entries.filter { $0.decision.hasPrefix("allow") }
            #expect(allowed.count >= 10, "every real dispatch must be audited, got \(allowed.count)")
            let deduplicatedShell = entries.contains(
                where: { $0.toolName == "exec.shell" && $0.decision.contains("duplicate") })
            #expect(!deduplicatedShell,
                    "identical provider call ids must never be deduplicated across clients")

            await cleanup()
        } catch {
            // Preserve the failed repro's guest-written files in the log
            // before the workspace is removed.
            let directory = root.appendingPathComponent("mc")
            if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() {
                for name in names {
                    let url = directory.appendingPathComponent(name)
                    guard let data = try? Data(contentsOf: url), data.count < 262_144 else { continue }
                    print("FLOE_MULTICLIENT_FILE \(name) bytes=\(data.count) sha=\(FloeDigest.sha256Hex(data))")
                    if name.hasSuffix(".timeline") || name.hasSuffix(".env") || name.hasSuffix(".cwd") {
                        print("FLOE_MULTICLIENT_CONTENT \(name)=\(String(decoding: data, as: UTF8.self).prefix(400))")
                    }
                }
            }
            Issue.record("shared-guest multi-client execution threw: \(error)")
            await cleanup()
        }
    }

    // MARK: - Autonomous child workflow through the real App catalog

    // No guest/network/model needed. Reads the real installed App guide
    // through its normal version-aware seeder; never writes a synthetic Skill
    // over user data. A newer/locally modified install is preserved explicitly.
    @Test("installed shell guide reads current Linux instructions without downgrading protected content",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_BUNDLED_SKILL_QUALIFICATION"] == "1"))
    func installedShellGuideRetirementRead() async throws {
        let environment = try await appQualificationEnvironment()
        let before = try await environment.skillStore.all().first { $0.id == "floe-shell" }
        let rows = try await environment.skillsCenter.readSkills(id: "floe-shell")
        let guide = try #require(rows.first { $0.id == "floe-shell" })
        let after = try #require(try await environment.skillStore.all().first { $0.id == "floe-shell" })
        let currentVersion = "1.1.1"
        if let before,
           before.version.compare(currentVersion, options: .numeric) == .orderedDescending
             || before.sourceURL != "floe-builtin://floe-shell"
             || before.rewrittenDigest != before.sourceDigest {
            // Version/source/local-revision protection is acceptance too; do
            // not assert that user-authored Markdown equals our bundled text.
            #expect(after.version == before.version)
            #expect(after.sourceURL == before.sourceURL)
            #expect(after.sourceDigest == before.sourceDigest)
            #expect(after.rewrittenDigest == before.rewrittenDigest)
            #expect(guide.version == after.version && guide.currentDigest == after.rewrittenDigest)
            print("FLOE_SHELL_GUIDE_PROTECTED version=\(after.version) digest=\(after.rewrittenDigest) currentBundledBodyVerified=false")
            return
        }
        try #require(guide.version == currentVersion, "App-owned shell guide must upgrade to the current bundle")
        try #require(after.version == currentVersion)
        let markdown = try #require(guide.markdown)
        #expect(markdown.contains("selected task Linux guest"))
        #expect(markdown.contains("Python is `python3`, JavaScript is `node`"))
        #expect(markdown.contains("at most 120 seconds") && markdown.contains("at most 600 seconds"))
        #expect(markdown.contains("runtime=static"))
        for retired in ["exec.localPython", "exec.javascript", "exec.compatEvaluator", "exec.wasm", "python.packages"] {
            #expect(!markdown.contains(retired), "Installed guide still recommends retired executor: \(retired)")
        }
        #expect(!markdown.contains("bundled CPython") && !markdown.contains("native ELF binaries and daemons are unavailable"))
        #expect(guide.digest == after.rewrittenDigest && guide.currentDigest == after.rewrittenDigest)
        #expect(guide.requiredToolNames?.contains("exec.shell") == true)
        #expect(after.sourceDigest == after.rewrittenDigest)
        print("FLOE_SHELL_GUIDE_CURRENT version=\(guide.version) digest=\(guide.digest) linuxBodyVerified=true")
    }

    /// The App-level acceptance for the child autonomy contract: a delegated
    /// child starts from a small seed against the App's REAL catalog (hundreds
    /// of descriptors, far above the 48 KiB frozen schema allowance), discovers
    /// `exec.shell` with `tools.search`, reads the `floe-shell` guide with
    /// `skill.search`/`skill.read` (which activates the guide's declared tool
    /// dependencies INSIDE the child), executes those tools against the real
    /// TinyEMU guest, produces a verified guest artifact/hash, and is refused
    /// `delegate` at the callable boundary. The provider is SCRIPTED: this is
    /// the App composition chain, not a real-model autonomy claim.
    @Test(
        "scripted child traverses full catalog → tools.search → skill.read activation → real guest artifact",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_QUALIFICATION"] == "1")
    )
    func scriptedChildDiscoveryReachesRealGuestArtifact() async throws {
        let root = try makeWorkspaceRoot()
        var ownedEnvironmentID = ""
        let services = FloePlatformServices.shared

        func cleanup() async {
            if !ownedEnvironmentID.isEmpty {
                do {
                    try await services.stopEnvironment(id: ownedEnvironmentID)
                    try await services.deleteEnvironment(id: ownedEnvironmentID)
                } catch {
                    Issue.record("Owned qualification environment cleanup failed: \(error)")
                    return // Preserve its workspace if shutdown/deletion did not finish.
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            let environment = AppEnvironment.live()
            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID
            // The bundled guides are seeded asynchronously at bootstrap; read
            // the real installed guide by joining that seed first.
            await environment.skillsCenter.seedBuiltinDomainSkills()

            let conversationID = UUID()
            let runID = UUID()
            // The REAL App catalog is the child's universe (no narrowed
            // fixture ceiling): this is the production shape where the whole
            // catalog serializes far above the 48 KiB frozen-schema
            // allowance, so the child MUST discover progressively.
            let executor = CatalogToolExecutor()
            let fullCatalogCount = executor.allDescriptors.count
            try #require(fullCatalogCount > 100,
                         "the App catalog must be the real full catalog, got \(fullCatalogCount)")

            let payload = "scripted-child-guest-artifact"
            let expectedHash = FloeDigest.sha256Hex(Data(payload.utf8))
            let pythonScript = """
            import hashlib, json, pathlib, sys
            data = pathlib.Path('mc/child-artifact.txt').read_bytes()
            pathlib.Path('mc/python-proof.json').write_text(json.dumps({'platform':sys.platform,'sha256':hashlib.sha256(data).hexdigest()}))
            print('FLOE_SCRIPTED_CHILD_HASH=' + hashlib.sha256(data).hexdigest())
            print('FLOE_SCRIPTED_CHILD_READ=' + data.decode())
            print('FLOE_SCRIPTED_CHILD_PLATFORM=' + sys.platform)
            """
            let pythonArguments = try Self.json(["command": "python3 -", "stdin": pythonScript, "timeout": 60])
            let scriptedAdapter = ScriptedProviderAdapter(turns: [
                [.toolRequest(try scriptedCall(id: "call_1", name: "tools.search", arguments: #"{"query":"exec.shell"}"#))],
                [.toolRequest(try scriptedCall(id: "call_2", name: "skill.search", arguments: #"{"query":"shell"}"#))],
                [.toolRequest(try scriptedCall(id: "call_3", name: "skill.read", arguments: #"{"id":"floe-shell"}"#))],
                [.toolRequest(try scriptedCall(
                    id: "call_4", name: "exec.shell",
                    arguments: #"{"command":"mkdir -p mc && printf '%s' 'scripted-child-guest-artifact' > mc/child-artifact.txt && sha256sum mc/child-artifact.txt && uname -r && echo CHILD_ARTIFACT_OK","timeout":60}"#))],
                [.toolRequest(try scriptedCall(
                    id: "call_5", name: "exec.shell", arguments: pythonArguments))],
                [.toolRequest(try scriptedCall(id: "call_6", name: "delegate", arguments: #"{"task":"nested"}"#))],
                [.textDelta(.init(text: "scripted child finished with a verified guest artifact"))],
            ])

            let runtime = makeRuntime(
                root: root, conversationID: conversationID, runID: runID,
                allowedToolNames: nil, environmentID: environmentID,
                adapter: UnusedProviderAdapter())

            let identity = ChildExecutionIdentity(
                parentRunID: runID, rootTaskID: conversationID, delegateCallID: "delegate-scripted")
            let bus = SubagentPeerBus()
            let handoff = ChildExecutionHandoff(
                identity: identity,
                dispatcher: ChildToolDispatcher(
                    descriptorProvider: { name in executor.descriptor(named: name) },
                    allDescriptors: { executor.allDescriptors },
                    dispatch: { call, context in
                        await runtime.dispatchChildTool(call, identity: identity, childContext: context)
                    }),
                peers: bus.handle(for: identity))

            let frozenNames = Set(executor.allDescriptors.map(\.name))
            let runner = SubagentRunner(
                provider: ProviderProfile(
                    kind: .openAI,
                    wireProtocol: .openAIChatCompletions,
                    baseURL: URL(string: "https://child-guest.example/v1")!,
                    displayName: "Scripted Child Provider"),
                model: ModelProfile(
                    providerID: UUID(),
                    remoteModelID: "scripted-child-model",
                    displayName: "Scripted Child Model",
                    limits: ModelLimits(contextTokens: 32_768, maxOutputTokens: 2_048),
                    capabilities: [.tools]),
                adapter: scriptedAdapter,
                credentials: ProviderCredentials(),
                executor: executor)
            let context = ToolContext(
                runID: runID,
                scope: .local,
                allowedToolNames: nil,
                workspaceRootURL: root,
                cancellation: CancellationToken(),
                childBudget: ChildBudgetContext(maximumIterations: 8, reserve: { true }, finish: {}),
                environmentID: environmentID,
                conversationID: conversationID,
                childExecution: handoff,
                clientSessionID: "child:\(identity.childID.uuidString)",
                frozenEffectiveCatalogNames: frozenNames)

            // Kernel prerequisite through the canonical dispatcher.
            try await requireQualifiedKernel(
                runtime: runtime, identity: identity, context: context)

            let outcome = try await runner.runStructured(
                SubagentRequest(
                    task: "discover how to run a shell command and produce a verified artifact",
                    maxIterations: 8,
                    kind: .execute,
                    runID: runID),
                context: context)

            #expect(outcome.status == .completed, "scripted child must complete: \(outcome.status)")
            #expect(outcome.findings.contains("verified guest artifact"))

            // Progressive discovery: the full catalog is the ceiling, but the
            // first request carries only the bounded seed.
            let firstSchemas = scriptedAdapter.firstSchemaNames
            let firstCeiling = scriptedAdapter.firstCeilingCount
            print("FLOE_SCRIPTED_CHILD firstSchemas=\(firstSchemas.count) ceiling=\(firstCeiling) catalog=\(fullCatalogCount)")
            // The name ceiling covers the real catalog (minus main-run-only
            // boundaries), while the frozen SCHEMAS stay a bounded seed: that
            // is exactly the >48 KiB full-catalog regression fixed structurally.
            #expect(firstCeiling > 200, "the child's name ceiling must cover the real catalog, got \(firstCeiling)")
            #expect(firstSchemas.count < 25, "the child must start from a bounded seed, got \(firstSchemas)")
            #expect(!firstSchemas.contains("exec.localPython"), "unloaded schemas must not ride the first request")
            #expect(scriptedAdapter.requestCount >= 7, "every scripted turn must reach the child loop")

            // Discovery + skill activation evidence, produced by the child loop.
            let ranToolSearch = outcome.evidence.contains(where: { $0.hasPrefix("tools.search") })
            let ranSkillSearch = outcome.evidence.contains(where: { $0.hasPrefix("skill.search") })
            let activatedSkill = outcome.evidence.contains(
                where: { $0.contains("skill.read floe-shell") && $0.contains("loaded=") })
            let guestShellOK = outcome.evidence.contains(
                where: { $0.hasPrefix("exec.shell") && !$0.contains("[") })
            let guestPythonOK = outcome.evidence.filter { $0.hasPrefix("exec.shell") && !$0.contains("[") }.count == 2
            let childDelegateDenied = outcome.evidence.contains(
                where: { $0.hasPrefix("delegate") && $0.contains("[denied]") })
            #expect(ranToolSearch, "tools.search must run in the child: \(outcome.evidence)")
            #expect(ranSkillSearch, "skill.search must run in the child")
            #expect(activatedSkill,
                    "skill.read must activate declared tool dependencies inside the child: \(outcome.evidence)")
            #expect(guestShellOK, "the guest shell call must succeed: \(outcome.evidence)")
            #expect(guestPythonOK, "the guest Python call must succeed: \(outcome.evidence)")
            #expect(childDelegateDenied, "a child must never delegate: \(outcome.evidence)")

            // The guest artifact really exists, written by the guest, and the
            // host re-verifies the exact bytes and hash.
            let artifact = try Data(contentsOf: root.appendingPathComponent("mc/child-artifact.txt"))
            #expect(String(decoding: artifact, as: UTF8.self) == payload)
            #expect(FloeDigest.sha256Hex(artifact) == expectedHash)
            let proof = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("mc/python-proof.json"))) as? [String: String]
            #expect(proof?["platform"] == "linux")
            #expect(proof?["sha256"] == expectedHash)

            await cleanup()
        } catch {
            Issue.record("scripted child discovery chain threw: \(error)")
            await cleanup()
        }
    }

    // MARK: - Human browser takeover

    /// Human browser takeover through the App's real compiled browser
    /// toolchain (`BrowserSessionCenter` + the registered tools a delegated
    /// child also reaches through the same runner). During takeover every
    /// mutating interaction is denied with the explicit takeover state while
    /// read-only work continues, and the user's panel cannot be dismissed by
    /// the task.
    @Test("human browser takeover denies task mutations while read-only browser work continues")
    func browserTakeoverDeniesMutationsButAllowsReads() async throws {
        let center = BrowserSessionCenter(durableHandoffs: false)
        let conversationID = UUID()
        center.bind(to: conversationID)
        let registry = ToolRunnerRegistry()
        registerBrowserTools(center: center, registry: registry)
        let context = ToolContext(
            runID: UUID(),
            scope: .local,
            cancellation: CancellationToken(),
            conversationID: conversationID
        )

        func run(_ name: String, _ arguments: String) async throws -> String {
            let runner = try #require(registry.runner(named: name), "missing \(name)")
            let output = try await runner.execute(
                argumentsJSON: Data(arguments.utf8),
                context: context
            )
            return output.summary
        }

        // A task-owned tab exists before the human takes over.
        let created = try await run("browser.tab", #"{"action":"create"}"#)
        #expect(created.contains("\"status\":\"ok\""), "tab create failed: \(created)")

        // The user takes control of this task's browser.
        try center.requestUserInteraction(reason: "Sign in to continue", tabID: nil)

        // Mutating interaction is denied with the explicit takeover state...
        let navigate = try await run("browser.navigate", #"{"url":"https://example.com"}"#)
        #expect(navigate.contains("\"status\":\"needsUser\""), "takeover must deny navigate: \(navigate)")
        #expect(navigate.contains("takeover"))

        // ...while read-only inspection continues on the same session.
        let tabs = try await run("browser.tabs", "{}")
        #expect(!tabs.contains("takeover"), "read-only work must continue during takeover: \(tabs)")
        #expect(tabs.contains("\"status\":\"ok\""), "read-only tabs failed: \(tabs)")

        // The user's panel cannot be dismissed until control returns.
        do {
            _ = try await run("browser.panel", #"{"action":"hide"}"#)
            Issue.record("hide must wait for the user to return browser control")
        } catch {
            // Expected: control belongs to the user.
        }
    }

    // MARK: - Small helpers

    /// Extracts `sessionID=<uuid>` from a shell.open result summary.
    static func sessionID(from summary: String) -> String? {
        guard let range = summary.range(of: "sessionID=") else { return nil }
        let tail = summary[range.upperBound...]
        let token = tail.prefix { $0 != " " && $0 != "\n" }
        return token.isEmpty ? nil : String(token)
    }

    /// JSON-encodes a string dictionary for tool arguments.
    static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Builds one scripted `ToolCall` for the child chain.
private func scriptedCall(id: String, name: String, arguments: String) throws -> ToolCall {
    try ToolCall(
        id: id,
        toolName: name,
        argumentsJSON: Data(arguments.utf8),
        scope: .local
    )
}

// ==== Skill Hub guest qualification appended blocks ====
// ============================================================================
// Skill Hub guest qualification — PRIVATE PROPOSAL (job-f1b6a8e6bafa4285).
//
// Append-only content for FloeAgent/Tests/FloeAppTests/SubagentSimulatorExecutionTests.swift.
// Base bytes: source 37bdeb14 (file sha256 3879c0e9fedf5896132d44d5d86d9e2110778aea133e189be1c88b3a3517421c,
// 1420 lines; unchanged through ba01e73e/build12 per Main). Insert this block
// AFTER the `scriptedCall` function and BEFORE the final `#endif`, and add the
// four imports listed in each patch header. Main's line 76 `.textDelta(.init(text: …))`
// and line 478 interpolated-`Comment` fixes are untouched by these hunks.
//
// Opt-in, fail-closed (a plain disabled run is reported as disabled, never a
// pass — the existing real-guest policy in this file):
//   * FLOE_SKILLHUB_PY_QUALIFICATION=1       + FLOE_SKILL_HUB_SOURCES_DIR + FLOE_SKILL_HUB_WHEELS_ZIP
//   * FLOE_SKILLHUB_WEBAPP_QUALIFICATION=1   + FLOE_SKILL_HUB_SOURCES_DIR
//   * FLOE_SKILLHUB_MCP_NODE_QUALIFICATION=1 (bundled 1.0.1 template only)
//
// Everything executes through the REAL production chain already used above:
// bootGuest → makeRuntime → active parent → requireQualifiedKernel →
// dispatchChildTool (exec.shell / browser.* / jobs.status / jobs.cancel), the
// App's production BackgroundJobService.submit for long exec.shell stages and
// exec.localService (the same jobs.submit shape proven by
// FloeApp.LocalLinuxStaticServiceRealVMTests), the digest-gated
// MCPServiceTemplate/SignedContentArchive path, and the real MCPRemoteClient.
// No host interpreter, no fake guest, no copied executor, no model inference,
// no new tool or environment subsystem.
// ============================================================================

// MARK: - Skill Hub staging / pinned inputs (file scope, private)

/// One staged file with its exact bytes pinned by digest.
private struct SkillHubStagedFile: Encodable {
    let path: String
    let sha256: String
    let bytes: Int
}

/// The manifest the GUEST re-hashes: every staged path must match byte-exact.
private struct SkillHubStagingManifest: Encodable {
    let files: [SkillHubStagedFile]
}

/// Guest-side identity + manifest verification (stdlib only, executed INSIDE
/// the Linux guest through exec.shell; the host never interprets sources).
private let skillHubStageVerifyScript = """
import hashlib, json, pathlib, platform, sys
manifest = json.loads(pathlib.Path('/workspace/skill-hub-staging.json').read_text())
bad = []
for entry in manifest['files']:
    p = pathlib.Path('/workspace') / entry['path']
    try:
        data = p.read_bytes()
    except OSError:
        bad.append(entry['path'] + ' MISSING')
        continue
    if hashlib.sha256(data).hexdigest() != entry['sha256'] or len(data) != entry['bytes']:
        bad.append(entry['path'] + ' MISMATCH')
print('FLOE_GUEST_MACHINE=' + platform.machine())
print('FLOE_GUEST_SYSTEM=' + platform.system())
print('FLOE_GUEST_PYTHON=' + sys.version.replace('\\n', ' '))
print('FLOE_GUEST_STAGE files=%d bad=%d' % (len(manifest['files']), len(bad)))
for item in bad:
    print('FLOE_GUEST_STAGE_BAD ' + item)
sys.exit(0 if not bad else 1)
"""

/// Minimal `jobs.status` progress projection for exec.localService readiness.
private struct SkillHubServiceProgress: Decodable {
    let state: String
    let previewURL: String?
}

/// Resolves and fail-closes the environment-driven staging inputs. These are
/// test-only input fixture paths, never a model-facing host bypass.
private enum SkillHubInputs {
    static var sourcesDir: URL? {
        ProcessInfo.processInfo.environment["FLOE_SKILL_HUB_SOURCES_DIR"].map { URL(fileURLWithPath: $0) }
    }
    static var wheelsZip: URL? {
        ProcessInfo.processInfo.environment["FLOE_SKILL_HUB_WHEELS_ZIP"].map { URL(fileURLWithPath: $0) }
    }
    static let wheelsZipSHA256 =
        "fbcfe04038f0ea320afb5caa2a69b4deef27e1771a25c8f7b7e435fe755c5c5c"
    static let wheelsZipBytes = 7_153_675
    static let wheelNames: [String] = [
        "certifi-2026.10.23-py3-none-any.whl",
        "charset_normalizer-3.5.2-py3-none-any.whl",
        "idna-3.20-py3-none-any.whl",
        "mpmath-1.3.0-py3-none-any.whl",
        "requests-2.34.2-py3-none-any.whl",
        "sympy-1.14.0-py3-none-any.whl",
        "urllib3-2.8.0-py3-none-any.whl",
    ]

    static func requireSourcesDir() throws -> URL {
        let path = ProcessInfo.processInfo.environment["FLOE_SKILL_HUB_SOURCES_DIR"] ?? ""
        guard !path.isEmpty else {
            throw FloeError.validationFailed("FLOE_SKILLHUB qualification requires FLOE_SKILL_HUB_SOURCES_DIR")
        }
        let dir = URL(fileURLWithPath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FloeError.notFound("Skill Hub sources directory does not exist: \(dir.path)")
        }
        return dir
    }

    static func requireWheelsZip() throws -> URL {
        let path = ProcessInfo.processInfo.environment["FLOE_SKILL_HUB_WHEELS_ZIP"] ?? ""
        guard !path.isEmpty else {
            throw FloeError.validationFailed("The wheel transport test requires FLOE_SKILL_HUB_WHEELS_ZIP")
        }
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == wheelsZipBytes else {
            throw FloeError.validationFailed(
                "Wheel transport zip size is \(String(describing: values.fileSize)), expected \(wheelsZipBytes)")
        }
        let digest = FloeDigest.sha256Hex(try Data(contentsOf: url))
        guard digest == wheelsZipSHA256 else {
            throw FloeError.validationFailed("Wheel transport zip sha256 mismatch: \(digest)")
        }
        return url
    }
}

/// Byte-exact staging of hub sources into the test-owned native workspace;
/// the guest consumes them through the existing /workspace path mapping.
private enum SkillHubStager {
    static func stage(_ sourceRoot: URL, to workspaceRoot: URL, relativePrefix: String,
                      into manifest: inout [SkillHubStagedFile]) throws {
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot, includingPropertiesForKeys: [.isRegularFileKey], options: []) else {
            throw FloeError.notFound("Cannot enumerate \(sourceRoot.path)")
        }
        var staged = 0
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let relative = String(fileURL.path.dropFirst(sourceRoot.path.count + 1))
            let destination = workspaceRoot
                .appendingPathComponent(relativePrefix, isDirectory: true)
                .appendingPathComponent(relative, isDirectory: false)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try Data(contentsOf: fileURL)
            try bytes.write(to: destination, options: .atomic)
            manifest.append(SkillHubStagedFile(
                path: relativePrefix + "/" + relative,
                sha256: FloeDigest.sha256Hex(bytes),
                bytes: bytes.count))
            staged += 1
        }
        guard staged > 0 else {
            throw FloeError.notFound("No files found under \(sourceRoot.path)")
        }
    }

    static func stageBytes(_ bytes: Data, to workspaceRoot: URL, path: String,
                           into manifest: inout [SkillHubStagedFile]) throws {
        let destination = workspaceRoot.appendingPathComponent(path, isDirectory: false)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: destination, options: .atomic)
        manifest.append(SkillHubStagedFile(path: path, sha256: FloeDigest.sha256Hex(bytes),
                                           bytes: bytes.count))
    }

    static func writeManifest(_ files: [SkillHubStagedFile], at workspaceRoot: URL) throws {
        let data = try JSONEncoder().encode(SkillHubStagingManifest(files: files))
        try data.write(to: workspaceRoot.appendingPathComponent("skill-hub-staging.json"),
                       options: .atomic)
    }
}

// MARK: - Shared child-dispatch/service helpers

extension SubagentSimulatorExecutionTests {

    /// One `exec.shell` dispatch through the same active-parent child chain.
    func skillHubShell(
        runtime: FloeAgentRuntime,
        identity: ChildExecutionIdentity,
        context: ToolContext,
        tag: String,
        command: String,
        environment: [String: String] = [:],
        timeout: Int = 120
    ) async throws -> ToolResult {
        var arguments: [String: Any] = [
            "command": command, "timeout": timeout, "maxOutputBytes": 24_576,
        ]
        if !environment.isEmpty { arguments["env"] = environment }
        let call = try toolCall(id: tag, toolName: "exec.shell", arguments: try Self.json(arguments))
        return await runtime.dispatchChildTool(call, identity: identity, childContext: context)
    }

    /// A background `exec.shell` job through the production job service
    /// (the proven LocalLinuxStaticServiceRealVMTests submission shape).
    func skillHubSubmitShell(
        jobs: BackgroundJobService, runID: UUID, environmentID: String, root: URL,
        name: String, command: String, timeout: Int, cwd: String = "."
    ) async throws -> UUID {
        let job = try await jobs.submit(
            runID: runID,
            toolCallID: "skill-hub-" + name + "-" + UUID().uuidString,
            targetTool: "exec.shell",
            payloadJSON: JSONSerialization.data(withJSONObject: [
                "command": command, "cwd": cwd, "timeout": timeout, "maxOutputBytes": 24_576,
            ]),
            scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [],
            environmentID: environmentID,
            submissionSource: .nativeService,
            waitForCompletion: false)
        try #require(job.runID == runID && job.environmentID == environmentID,
                     "Skill Hub job ownership must match the submitted run and environment")
        return job.id
    }

    fileprivate func skillHubServiceProgress(_ data: Data?) -> SkillHubServiceProgress? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(SkillHubServiceProgress.self, from: data)
    }

    func skillHubWaitTerminal(
        _ jobs: BackgroundJobService, id: UUID, seconds: TimeInterval
    ) async throws -> BackgroundJob {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let job = try await jobs.job(id: id), job.state.isTerminal { return job }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw FloeError.validationFailed("Skill Hub job \(id) never reached a terminal state; preserve its environment")
    }

    /// `exec.localService` readiness exactly as the proven static-service test.
    /// previewURL is accepted only with the recorded "running" state, and every
    /// poll is retained as evidence.
    func skillHubWaitPreview(
        _ jobs: BackgroundJobService, id: UUID, samples: inout [[String: String]],
        timeout: TimeInterval
    ) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            guard let job = try await jobs.job(id: id) else {
                throw FloeError.notFound("Skill Hub service job disappeared")
            }
            if job.state.isTerminal {
                throw FloeError.validationFailed(
                    "Skill Hub service ended before readiness: \(job.lastError ?? job.state.rawValue)")
            }
            let progress = skillHubServiceProgress(job.progressJSON)
            samples.append([
                "at": ISO8601DateFormatter().string(from: Date()),
                "state": progress?.state ?? "unknown",
                "previewURL": progress?.previewURL ?? "",
            ])
            if let progress, progress.state == "running", let text = progress.previewURL,
               let url = URL(string: text) {
                return url
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        throw FloeError.validationFailed("Skill Hub service readiness deadline exceeded; inspect the retained poll samples, do not resubmit")
    }

    /// Creates the durable conversation + run rows the production job service
    /// and browser ownership require (the same rows the static-service and
    /// pip qualifications use and then remove).
    @discardableResult
    func skillHubCreateRunRows(
        app: AppEnvironment, conversationID: UUID, runID: UUID, title: String, goal: String
    ) async throws -> Bool {
        let date = Date()
        try await app.conversationStore.saveConversation(ConversationRecord(
            id: conversationID, title: title, createdAt: date, updatedAt: date, titleOrigin: .manual))
        try await app.database.writer { database in
            try database.execute(
                sql: "INSERT INTO runs (id, conversation_id, state, goal, started_at) VALUES (?, ?, 'running', ?, ?)",
                arguments: [runID.uuidString, conversationID.uuidString, goal,
                            ISO8601DateFormatter().string(from: date)])
        }
        return true
    }

    func skillHubFinishJobs(_ jobs: BackgroundJobService, _ ids: [UUID]) async throws {
        for id in ids {
            if let job = try await jobs.job(id: id), !job.state.isTerminal {
                _ = try await jobs.cancel(id: id)
                _ = try await skillHubWaitTerminal(jobs, id: id, seconds: 120)
            }
        }
    }

    /// Standard ordered teardown: parent first, then owned jobs, guest,
    /// records, workspace. A failed guest stop preserves the workspace.
    func skillHubCleanup(
        runtime: FloeAgentRuntime?, parentHold: CancellationToken?, parentTask: Task<Void, Error>?,
        jobs: BackgroundJobService?, jobIDs: [UUID], environmentID: String?, root: URL,
        conversationID: UUID?, app: AppEnvironment?
    ) async {
        await runtime?.cancel()
        parentHold?.cancel()
        if let parentTask {
            parentTask.cancel()
            do { try await parentTask.value }
            catch is CancellationError { }
            catch let error as FloeError where error == .cancelled { }
            catch { Issue.record("Skill Hub parent cleanup failed: \(error)") }
        }
        if let jobs, let app {
            do { try await skillHubFinishJobs(jobs, jobIDs) }
            catch {
                Issue.record("Skill Hub owned jobs did not settle; preserve environment and workspace: \(error)")
                return
            }
            let center = UNUserNotificationCenter.current()
            let identifiers = jobIDs.map { "jobs." + $0.uuidString }
            center.removePendingNotificationRequests(withIdentifiers: identifiers)
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
        let services = FloePlatformServices.shared
        if let environmentID {
            do {
                try await services.stopEnvironment(id: environmentID)
                try await services.deleteEnvironment(id: environmentID)
            } catch {
                Issue.record("Skill Hub owned environment cleanup failed; preserve its workspace: \(root.path): \(error)")
                return
            }
        }
        if let conversationID, let app {
            do { try await app.conversationStore.deleteConversation(id: conversationID) }
            catch {
                Issue.record("Skill Hub conversation cleanup failed; preserve workspace: \(error)")
                return
            }
        }
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Skill Hub workspace cleanup failed: \(error)") }
    }

    func skillHubFailureEvidence(_ evidence: [String: String], root: URL, label: String) {
        let data = (try? JSONEncoder().encode(evidence)) ?? Data("{}".utf8)
        try? data.write(to: root.appendingPathComponent("skill-hub-\(label)-evidence.json"), options: .atomic)
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) else { return }
        let directory = support.appendingPathComponent("FloeAgent/QualificationEvidence/SkillHubGuest", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(label + "-" + UUID().uuidString + ".json")
            try data.write(to: file, options: .atomic)
            print("FLOE_SKILLHUB_FAILURE_EVIDENCE=\(file.path)")
        } catch { Issue.record("Skill Hub failure evidence could not be retained: \(error)") }
    }

    // MARK: - Test 1 (patch A): pinned wheel transport + sympy/citation scripts

    /// Verifies the delivered seven-wheel transport and the two remote Skill
    /// sources exactly as integrated at hub commit 4210403: byte-exact staging
    /// (guest re-hash), hash-pinned offline installs, the fixed sympy verifier
    /// (derivative / exact roots / ODE residual plus the other named checks),
    /// the BibTeX formatter and validator, and ONE read-only keyless
    /// first-page OpenAlex search with one DOI content-negotiation lookup, all
    /// executed by the real guest. A genuine API or install failure stays a
    /// failure with its original output retained: no fallback success, no
    /// account creation, no host interpreter.
    @Test(
        "Skill Hub guest qualification: pinned wheel transport, hash installs, sympy verifier and citation scripts run in the real Linux guest",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_SKILLHUB_PY_QUALIFICATION"] == "1")
    )
    func skillHubWheelsSympyCitationGuestQualification() async throws {
        let sources = try SkillHubInputs.requireSourcesDir()
        let zip = try SkillHubInputs.requireWheelsZip()
        let root = try makeWorkspaceRoot()
        var evidence: [String: String] = [
            "kind": "skill-hub-python-guest-not-model-not-ui",
            "hubSources": sources.path,
            "wheelsZip": zip.path,
        ]
        var manifest: [SkillHubStagedFile] = []
        try SkillHubStager.stageBytes(try Data(contentsOf: zip), to: root,
                                      path: "transport/wheels.zip", into: &manifest)
        try SkillHubStager.stage(sources.appendingPathComponent("sympy", isDirectory: true),
                                 to: root, relativePrefix: "skill-src/sympy", into: &manifest)
        try SkillHubStager.stage(sources.appendingPathComponent("citation-management", isDirectory: true),
                                 to: root, relativePrefix: "skill-src/citation-management", into: &manifest)
        try SkillHubStager.writeManifest(manifest, at: root)
        // The transport's own locks must be byte-identical to the integrated
        // hub source locks (verified equal offline on 2026-10-26; the guest
        // check re-proves it on the actual device).
        let sympyLockSHA = try FloeDigest.sha256Hex(Data(contentsOf: root
            .appendingPathComponent("skill-src/sympy/references/requirements.lock.txt")))
        let citationLockSHA = try FloeDigest.sha256Hex(Data(contentsOf: root
            .appendingPathComponent("skill-src/citation-management/references/requirements.lock.txt")))

        var ownedEnvironmentID: String?
        var parentHold: CancellationToken?
        var ownedRuntime: FloeAgentRuntime?
        var parentTask: Task<Void, Error>?
        var jobIDs: [UUID] = []
        var conversationID: UUID?
        var app: AppEnvironment?
        var qualificationRunID: UUID?
        var ownedSitePrefixCreated = false
        func finish() async {
            await skillHubCleanup(runtime: ownedRuntime, parentHold: parentHold,
                                  parentTask: parentTask, jobs: app?.backgroundJobService,
                                  jobIDs: jobIDs, environmentID: ownedEnvironmentID, root: root,
                                  conversationID: conversationID, app: app)
        }
        do {
            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID
            let liveApp = try await appQualificationEnvironment()
            app = liveApp
            let jobs = try #require(liveApp.backgroundJobService, "Production job service is unavailable")
            let runID = UUID()
            qualificationRunID = runID
            let conversationUUID = UUID()
            conversationID = conversationUUID
            try await skillHubCreateRunRows(app: liveApp, conversationID: conversationUUID, runID: runID,
                title: "Skill Hub Python qualification",
                goal: "Skill Hub wheel installs and scripts through owned jobs; no model")

            let ceiling: Set<String> = ["exec.shell"]
            let hold = CancellationToken()
            parentHold = hold
            let runtime = makeRuntime(
                root: root, conversationID: conversationUUID, runID: runID,
                allowedToolNames: ceiling, environmentID: environmentID,
                adapter: QualificationHoldingProviderAdapter(hold: hold))
            ownedRuntime = runtime
            parentTask = Task { try await runtime.start(goal: "Skill Hub Python guest qualification") }
            try #require(await waitForAsync(timeout: 20) {
                if case .streamingModel = await runtime.state { return true }
                return false
            }, "Parent must be active before Skill Hub child execution")
            let context = ToolContext(
                runID: runID, scope: .local, allowedToolNames: ceiling,
                workspaceRootURL: root, cancellation: CancellationToken(),
                environmentID: environmentID, conversationID: conversationUUID)
            let identity = ChildExecutionIdentity(
                parentRunID: runID, rootTaskID: conversationUUID, delegateCallID: "skillhub-python")
            try await requireQualifiedKernel(runtime: runtime, identity: identity, context: context)

            // 1. Guest identity + byte-exact staging proof (guest re-hash).
            let stageResult = try await skillHubShell(
                runtime: runtime, identity: identity, context: context, tag: "stage-verify",
                command: "PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'\n" + skillHubStageVerifyScript + "\nPY",
                timeout: 120)
            try #require(stageResult.status == .ok,
                         "Guest staging verification failed: \(stageResult.outputSummary)")
            try #require(stageResult.outputSummary.contains("bad=0"),
                         "Guest re-hash found staged byte mismatches: \(stageResult.outputSummary)")
            try #require(stageResult.outputSummary.contains("FLOE_GUEST_MACHINE=riscv64"),
                         "Guest architecture is not riscv64: \(stageResult.outputSummary)")
            evidence["guestStage"] = String(stageResult.outputSummary.prefix(1_200))
            print("FLOE_SKILLHUB_STAGE \(stageResult.outputSummary.prefix(600))")

            // 2. Transport zip integrity inside the guest + exact locks.
            let zipHash = try await skillHubShell(
                runtime: runtime, identity: identity, context: context, tag: "zip-hash",
                command: "sha256sum transport/wheels.zip && ls -l transport/wheels.zip")
            try #require(zipHash.status == .ok
                            && zipHash.outputSummary.contains(SkillHubInputs.wheelsZipSHA256),
                         "Guest-side transport zip digest differs: \(zipHash.outputSummary)")
            let unpack = try await skillHubShell(
                runtime: runtime, identity: identity, context: context, tag: "zip-unpack",
                command: """
                set -e
                PYTHONDONTWRITEBYTECODE=1 python3 -m zipfile -e transport/wheels.zip transport/unpacked
                ls transport/unpacked/wheels | wc -l
                ls transport/unpacked/wheels
                sha256sum transport/unpacked/sympy/requirements.lock.txt transport/unpacked/citation-management/requirements.lock.txt
                """)
            try #require(unpack.status == .ok, "Guest unzip failed: \(unpack.outputSummary)")
            for name in SkillHubInputs.wheelNames {
                try #require(unpack.outputSummary.contains(name), "Missing wheel \(name): \(unpack.outputSummary)")
            }
            try #require(unpack.outputSummary.contains(sympyLockSHA),
                         "Transport sympy lock differs from the integrated hub source lock")
            try #require(unpack.outputSummary.contains(citationLockSHA),
                         "Transport citation lock differs from the integrated hub source lock")
            evidence["guestUnzip"] = String(unpack.outputSummary.prefix(1_200))

            // 2b. Resolve the OWNED environment write layer as the install
            //     prefix instead of the task workspace share: the 9p export
            //     must actually be mounted in THIS guest, the prefix is
            //     created explicitly, and its space is recorded. Fail-closed:
            //     no arbitrary first-environment, no silent temp fallback,
            //     and no host interpreter.
            let envProbe = try await skillHubShell(
                runtime: runtime, identity: identity, context: context, tag: "env-prefix",
                command: """
                set -e
                grep -q ' /floe/env ' /proc/mounts
                mkdir -p /floe/env/python/skill-qualification
                df -k /floe/env | tail -1
                echo FLOE_ENV_PREFIX_OK
                """)
            try #require(envProbe.status == .ok
                            && envProbe.outputSummary.contains("FLOE_ENV_PREFIX_OK"),
                         "Owned environment write layer is unavailable in the guest: \(envProbe.outputSummary)")
            ownedSitePrefixCreated = true
            evidence["envPrefix"] = String(envProbe.outputSummary.prefix(400))

            // Hash-pinned offline installation without pip's eager bytecode
            // pass. PYTHONDONTWRITEBYTECODE alone does not disable pip's
            // compileall calls. Actual script imports still run in the guest;
            // timings, rather than this source review, establish the effect.
            let pip = "env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/workspace/skill-env/home "
                + "PYTHONDONTWRITEBYTECODE=1 PIP_CONFIG_FILE=/dev/null python3 -u -m pip --isolated "
                + "--disable-pip-version-check --no-input --no-cache-dir install --no-index --require-hashes --no-compile "
                + "--find-links /workspace/transport/unpacked/wheels --target /floe/env/python/skill-qualification/site -r "
            let sympyInstall = try await skillHubSubmitShell(
                jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                name: "pip-sympy",
                command: "mkdir -p skill-env/home && " + pip
                    + "/workspace/transport/unpacked/sympy/requirements.lock.txt", timeout: 600)
            jobIDs.append(sympyInstall)
            let sympyJob = try await skillHubWaitTerminal(jobs, id: sympyInstall, seconds: 660)
            evidence["pipSympy"] = sympyJob.resultSummary ?? sympyJob.lastError ?? sympyJob.state.rawValue
            try #require(sympyJob.state == .completed,
                         "SymPy install job failed: \(evidence["pipSympy"] ?? "unknown")")
            try #require((sympyJob.resultSummary ?? "").contains("sympy-1.14.0")
                            && (sympyJob.resultSummary ?? "").contains("mpmath-1.3.0"),
                         "SymPy install did not report the pinned wheels: \(sympyJob.resultSummary ?? "")")
            let citationInstall = try await skillHubSubmitShell(
                jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                name: "pip-citation",
                command: pip + "/workspace/transport/unpacked/citation-management/requirements.lock.txt",
                timeout: 600)
            jobIDs.append(citationInstall)
            let citationJob = try await skillHubWaitTerminal(jobs, id: citationInstall, seconds: 660)
            evidence["pipCitation"] = citationJob.resultSummary ?? citationJob.lastError ?? citationJob.state.rawValue
            try #require(citationJob.state == .completed,
                         "Citation install job failed: \(evidence["pipCitation"] ?? "unknown")")
            for pin in ["requests-2.34.2", "certifi-2026.10.23", "charset-normalizer-3.5.2",
                        "idna-3.20", "urllib3-2.8.0"] {
                try #require((citationJob.resultSummary ?? "").contains(pin),
                             "Install summary missing \(pin): \(citationJob.resultSummary ?? "")")
            }

            // The actual verifier imports the installed packages below. Avoid
            // an unrelated eager compile of every module in the distribution;
            // import-time compilation remains real guest work.

            // 4. SymPy verifier in the guest: derivative, exact roots, ODE
            //    residual and the remaining named checks; host re-reads the
            //    guest-written JSON artifact for the real result.
            let sympyRun = try await skillHubSubmitShell(
                jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                name: "sympy-verify", command: """
                set -e
                mkdir -p skill-out
                PYTHONPATH=/floe/env/python/skill-qualification/site PYTHONDONTWRITEBYTECODE=1 \
                python3 skill-src/sympy/scripts/sympy_verify.py > skill-out/sympy-verify.json
                sha256sum skill-out/sympy-verify.json
                """, timeout: 600)
            jobIDs.append(sympyRun)
            let sympyResult = try await skillHubWaitTerminal(jobs, id: sympyRun, seconds: 660)
            evidence["sympyRun"] = sympyResult.resultSummary ?? sympyResult.lastError ?? sympyResult.state.rawValue
            try #require(sympyResult.state == .completed,
                         "Guest sympy verification failed: \(evidence["sympyRun"] ?? "unknown")")
            let sympyBytes = try Data(contentsOf: root.appendingPathComponent("skill-out/sympy-verify.json"))
            let sympyReport = try JSONSerialization.jsonObject(with: sympyBytes) as? [String: Any]
            try #require(sympyReport?["ok"] as? Bool == true,
                         "SymPy verifier ok is not true: \(String(decoding: sympyBytes, as: UTF8.self).prefix(600))")
            evidence["sympyReport"] = String(decoding: sympyBytes, as: UTF8.self)
            evidence["sympyReportSHA256"] = FloeDigest.sha256Hex(sympyBytes)
            let sympyChecks = sympyReport?["results"] as? [String: Any] ?? [:]
            // The frozen verifier serializes str(result), not JSON booleans.
            // Require every declared check and an empty failure list.
            for name in ["derivative", "solve", "ode", "exact_rational", "integral", "simplify", "matrix_det", "latex"] {
                try #require(sympyChecks[name] as? String == "True", "SymPy check \(name) did not pass")
            }
            try #require((sympyReport?["failures"] as? [String])?.isEmpty == true,
                         "SymPy verifier reported failures")
            try #require(sympyChecks["version"] as? String == "1.14.0",
                         "Guest sympy version is not the pinned 1.14.0: \(String(describing: sympyChecks["version"]))")
            print("FLOE_SKILLHUB_SYMPY sha256=\(FloeDigest.sha256Hex(sympyBytes)) checks=derivative,solve,ode")

            // 5. Citation formatter + validator (offline scripts, owned jobs).
            let formatRun = try await skillHubSubmitShell(
                jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                name: "format-bibtex", command: """
                set -e
                mkdir -p skill-out
                PYTHONPATH=/floe/env/python/skill-qualification/site PYTHONDONTWRITEBYTECODE=1 \
                python3 skill-src/citation-management/scripts/format_bibtex.py \
                skill-src/citation-management/assets/bibtex_template.bib -o skill-out/clean.bib
                grep -c '^@' skill-out/clean.bib
                """, timeout: 300)
            jobIDs.append(formatRun)
            let formatJob = try await skillHubWaitTerminal(jobs, id: formatRun, seconds: 360)
            evidence["formatBibtex"] = formatJob.resultSummary ?? formatJob.lastError ?? formatJob.state.rawValue
            try #require(formatJob.state == .completed,
                         "Guest BibTeX formatter failed: \(evidence["formatBibtex"] ?? "unknown")")
            let cleanBytes = try Data(contentsOf: root.appendingPathComponent("skill-out/clean.bib"))
            try #require(String(decoding: cleanBytes, as: UTF8.self).contains("@"),
                         "Formatted BibTeX output carries no entries")
            let validateRun = try await skillHubSubmitShell(
                jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                name: "validate-citations", command: """
                set -e
                mkdir -p skill-out
                PYTHONPATH=/floe/env/python/skill-qualification/site PYTHONDONTWRITEBYTECODE=1 \
                python3 skill-src/citation-management/scripts/validate_citations.py \
                skill-src/citation-management/assets/bibtex_template.bib --report skill-out/validation-report.json
                """, timeout: 300)
            jobIDs.append(validateRun)
            let validateJob = try await skillHubWaitTerminal(jobs, id: validateRun, seconds: 360)
            evidence["validateCitations"] = validateJob.resultSummary ?? validateJob.lastError ?? validateJob.state.rawValue
            try #require(validateJob.state == .completed,
                         "Guest citation validator failed (high-severity findings keep the original non-zero exit): \(evidence["validateCitations"] ?? "unknown")")
            let reportBytes = try Data(contentsOf: root.appendingPathComponent("skill-out/validation-report.json"))
            try #require(reportBytes.count > 2, "The validation report is empty")
            print("FLOE_SKILLHUB_CITATION clean=\(FloeDigest.sha256Hex(cleanBytes)) report=\(FloeDigest.sha256Hex(reportBytes))")

            // 6. One read-only keyless first-page OpenAlex search and one DOI
            //    lookup, executed by the GUEST. A real API/network failure must
            //    fail this qualification here with the original output retained.
            let openAlexRun = try await skillHubSubmitShell(
                jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                name: "openalex-first-page", command: """
                set -e
                mkdir -p skill-out
                PYTHONPATH=/floe/env/python/skill-qualification/site PYTHONDONTWRITEBYTECODE=1 \
                python3 skill-src/citation-management/scripts/search_openalex.py "CRISPR gene editing" \
                --limit 5 -o skill-out/openalex.json
                """, timeout: 300)
            jobIDs.append(openAlexRun)
            let openAlexJob = try await skillHubWaitTerminal(jobs, id: openAlexRun, seconds: 360)
            evidence["openalex"] = openAlexJob.resultSummary ?? openAlexJob.lastError ?? openAlexJob.state.rawValue
            try #require(openAlexJob.state == .completed,
                         "Keyless OpenAlex first-page lookup failed in the guest (no fallback is allowed): \(evidence["openalex"] ?? "unknown")")
            let openAlexBytes = try Data(contentsOf: root.appendingPathComponent("skill-out/openalex.json"))
            let openAlexJSON = try JSONSerialization.jsonObject(with: openAlexBytes) as? [String: Any]
            let openAlexCount = (openAlexJSON?["results"] as? [Any])?.count ?? 0
            try #require(openAlexCount >= 1,
                         "OpenAlex returned no works: \(String(decoding: openAlexBytes, as: UTF8.self).prefix(400))")
            print("FLOE_SKILLHUB_OPENALEX sha256=\(FloeDigest.sha256Hex(openAlexBytes)) count=\(openAlexCount)")
            let doiRun = try await skillHubSubmitShell(
                jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                name: "doi-lookup", command: """
                set -e
                mkdir -p skill-out
                PYTHONPATH=/floe/env/python/skill-qualification/site PYTHONDONTWRITEBYTECODE=1 \
                python3 skill-src/citation-management/scripts/doi_to_bibtex.py 10.1038/s41586-021-03819-2 \
                -o skill-out/doi.bib
                """, timeout: 300)
            jobIDs.append(doiRun)
            let doiJob = try await skillHubWaitTerminal(jobs, id: doiRun, seconds: 360)
            evidence["doi"] = doiJob.resultSummary ?? doiJob.lastError ?? doiJob.state.rawValue
            try #require(doiJob.state == .completed,
                         "DOI content-negotiation lookup failed in the guest: \(evidence["doi"] ?? "unknown")")
            let doiBytes = try Data(contentsOf: root.appendingPathComponent("skill-out/doi.bib"))
            let doiText = String(decoding: doiBytes, as: UTF8.self).lowercased()
            try #require(doiText.contains("@") && doiText.contains("10.1038/s41586-021-03819-2"),
                         "DOI lookup output lacks a BibTeX entry for the requested DOI")
            evidence["openalexSHA256"] = FloeDigest.sha256Hex(openAlexBytes)
            evidence["doiSHA256"] = FloeDigest.sha256Hex(doiBytes)
            print("FLOE_SKILLHUB_PYTHON_QUALIFIED wheels=7 sympy=ok citation=scripts-executed doi=\(FloeDigest.sha256Hex(doiBytes))")
            // 7. Remove the test-owned env-layer prefix through the SAME
            //    owned guest BEFORE teardown: the Runtime v2 layout keeps
            //    environments/<id>/data beyond deleteEnvironment, so this
            //    qualification cleans its own native files explicitly and
            //    claims no persistent product install (it was ephemeral).
            let purgeRun = try await skillHubSubmitShell(
                jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                name: "site-purge",
                command: "rm -rf /floe/env/python/skill-qualification && echo FLOE_SITE_PURGED",
                timeout: 600)
            jobIDs.append(purgeRun)
            let purgeJob = try await skillHubWaitTerminal(jobs, id: purgeRun, seconds: 660)
            evidence["sitePurge"] = purgeJob.resultSummary ?? purgeJob.lastError ?? purgeJob.state.rawValue
            try #require(purgeJob.state == .completed
                            && (purgeJob.resultSummary ?? "").contains("FLOE_SITE_PURGED"),
                         "Env-prefix purge failed; prefix retained at /floe/env/python/skill-qualification: \(evidence["sitePurge"] ?? "unknown")")
            ownedSitePrefixCreated = false
            print("FLOE_SKILLHUB_PURGE \(String((evidence["sitePurge"] ?? "").prefix(200)))")
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
                .appendingPathComponent("FloeAgent/QualificationEvidence/SkillHubGuest", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let successEvidence = support.appendingPathComponent("python-completed-\(runID.uuidString).json")
            try JSONEncoder().encode(evidence).write(to: successEvidence, options: .atomic)
            print("FLOE_SKILLHUB_PYTHON_EVIDENCE=\(successEvidence.path)")
            await finish()
        } catch {
            evidence["failure"] = String(describing: error)
            // Best-effort owned-prefix purge before teardown so a failing
            // run never stacks native leftovers. Its own failure is only
            // recorded into the evidence (never an extra expectation): the
            // original qualification failure always dominates.
            if ownedSitePrefixCreated, let liveJobs = app?.backgroundJobService,
               let qualificationRunID, let ownedEnvironmentID {
                do {
                    let cleanupPurge = try await skillHubSubmitShell(
                        jobs: liveJobs, runID: qualificationRunID,
                        environmentID: ownedEnvironmentID, root: root,
                        name: "site-purge-cleanup",
                        command: "rm -rf /floe/env/python/skill-qualification && echo FLOE_SITE_PURGED",
                        timeout: 600)
                    jobIDs.append(cleanupPurge)
                    let cleanupJob = try await skillHubWaitTerminal(liveJobs, id: cleanupPurge, seconds: 660)
                    evidence["sitePurge"] = cleanupJob.resultSummary ?? cleanupJob.lastError ?? cleanupJob.state.rawValue
                    if cleanupJob.state == .completed { ownedSitePrefixCreated = false }
                } catch {
                    evidence["sitePurge"] = "purge failed: \(error); prefix retained at /floe/env/python/skill-qualification"
                }
            }
            skillHubFailureEvidence(evidence, root: root, label: "python")
            Issue.record("Skill Hub Python guest qualification failed: \(error)")
            await finish()
        }
    }
}

// ============================================================================
// PART B — webapp-testing Level B + Level C. Applies on top of PART A.
// Requires PART A's helpers (skillHubShell / skillHubSubmitShell /
// skillHubWaitTerminal / skillHubWaitPreview / skillHubCreateRunRows /
// skillHubCleanup / skillHubFailureEvidence / SkillHubStager / SkillHubInputs).
// Opt-in: FLOE_SKILLHUB_WEBAPP_QUALIFICATION=1 + FLOE_SKILL_HUB_SOURCES_DIR.
// ============================================================================

// MARK: - Browser/service/record decoders (file scope, private)

/// Decodes the semantic browser tool JSON summary (`BrowserResult`).
private struct SkillHubBrowserResult: Decodable {
    struct Page: Decodable {
        struct Tab: Decodable { let id: UUID; let url: String; let isActive: Bool }
        struct Node: Decodable {
            let ref: String
            let role: String
            let name: String
            let text: String
            let value: String?
        }
        struct Artifact: Decodable {
            let relativePath: String
            let byteCount: Int
            let sha256: String
        }
        let documentID: String
        let url: String
        let tabs: [Tab]
        let nodes: [Node]
        let nextCursor: Int?
        let screenshotArtifact: Artifact?
        init(documentID: String, url: String, tabs: [Tab], nodes: [Node],
             nextCursor: Int?, screenshotArtifact: Artifact?) {
            self.documentID = documentID
            self.url = url
            self.tabs = tabs
            self.nodes = nodes
            self.nextCursor = nextCursor
            self.screenshotArtifact = screenshotArtifact
        }
    }
    let status: String
    let message: String?
    let page: Page?
}

/// Authoritative fixture-server `/state` document (guest loopback 127.0.0.1).
private struct SkillHubServerState: Decodable {
    struct Submission: Decodable { let receipt: String }
    let submissions: [Submission]
    let serverCount: Int
    let ready: String
}

/// One JSONL line written by the shipped `record_case.py`.
private struct SkillHubRecordedCase: Decodable {
    let caseName: String
    let status: String
    enum CodingKeys: String, CodingKey {
        case caseName = "case"
        case status
    }
}

extension SubagentSimulatorExecutionTests {

    fileprivate func skillHubDecodeBrowser(_ result: ToolResult) throws -> SkillHubBrowserResult {
        guard let start = result.outputSummary.firstIndex(of: "{"),
              let end = result.outputSummary.lastIndex(of: "}"), start < end,
              let data = result.outputSummary[start...end].data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SkillHubBrowserResult.self, from: data) else {
            throw FloeError.validationFailed("Browser result is not decodable JSON: \(result.outputSummary.prefix(400))")
        }
        return decoded
    }

    /// Full semantic observation, following `nextCursor` pagination; the
    /// returned page accumulates nodes across all observed pages.
    fileprivate func skillHubObserve(
        runtime: FloeAgentRuntime, identity: ChildExecutionIdentity, context: ToolContext,
        tag: String, tabID: UUID
    ) async throws -> SkillHubBrowserResult.Page {
        var nodes: [SkillHubBrowserResult.Page.Node] = []
        var latest: SkillHubBrowserResult.Page?
        var cursor: Int?
        for index in 0..<12 {
            var arguments: [String: Any] = ["tabID": tabID.uuidString]
            if let cursor { arguments["cursor"] = cursor }
            let result = try await skillHubBrowserCall(runtime: runtime, identity: identity,
                context: context, tag: "\(tag)-\(index)", tool: "browser.observe",
                arguments: arguments)
            let page = try #require(result.page, "semantic observation returned no page")
            latest = page
            nodes.append(contentsOf: page.nodes)
            guard let next = page.nextCursor else { break }
            cursor = next
        }
        let resolved = try #require(latest, "observation never returned a page")
        return SkillHubBrowserResult.Page(documentID: resolved.documentID, url: resolved.url,
                                         tabs: resolved.tabs, nodes: nodes,
                                         nextCursor: nil,
                                         screenshotArtifact: resolved.screenshotArtifact)
    }

    fileprivate func skillHubFindRef(
        in page: SkillHubBrowserResult.Page, namePrefix: String, role: String? = nil
    ) throws -> SkillHubBrowserResult.Page.Node {
        let lowered = namePrefix.lowercased()
        guard let node = page.nodes.first(where: {
            ($0.name.lowercased().hasPrefix(lowered) || $0.text.lowercased().hasPrefix(lowered))
                && (role == nil || $0.role == role)
        }) else {
            throw FloeError.notFound("No fresh node named '\(namePrefix)' (role \(role ?? "any")) in document \(page.documentID)")
        }
        return node
    }

    @discardableResult
    fileprivate func skillHubBrowserCall(
        runtime: FloeAgentRuntime, identity: ChildExecutionIdentity, context: ToolContext,
        tag: String, tool: String, arguments: [String: Any]
    ) async throws -> SkillHubBrowserResult {
        let call = try toolCall(id: tag, toolName: tool, arguments: try Self.json(arguments))
        let result = await runtime.dispatchChildTool(call, identity: identity, childContext: context)
        try #require(result.status == .ok, "\(tool) failed: \(result.outputSummary)")
        return try skillHubDecodeBrowser(result)
    }

    /// Dispatches a browser call EXPECTED to fail (stale/timeout halves of the
    /// contract); returns the raw result for honest assertion.
    func skillHubBrowserFailure(
        runtime: FloeAgentRuntime, identity: ChildExecutionIdentity, context: ToolContext,
        tool: String, arguments: [String: Any]
    ) async throws -> ToolResult {
        let call = try toolCall(id: "expected-failure-" + UUID().uuidString, toolName: tool,
                                arguments: try Self.json(arguments))
        return await runtime.dispatchChildTool(call, identity: identity, childContext: context)
    }

    /// `browser.wait` on a text marker with an explicit bounded timeout.
    fileprivate func skillHubWaitText(
        runtime: FloeAgentRuntime, identity: ChildExecutionIdentity, context: ToolContext,
        tag: String, tabID: UUID, marker: String, timeoutMilliseconds: Int = 8_000
    ) async throws -> SkillHubBrowserResult {
        try await skillHubBrowserCall(
            runtime: runtime, identity: identity, context: context, tag: tag,
            tool: "browser.wait",
            arguments: ["tabID": tabID.uuidString, "condition": "text", "value": marker,
                        "timeoutMilliseconds": timeoutMilliseconds])
    }

    /// Keeps recorded details safe for the single-quoted guest shell argument:
    /// bounded to benign characters, whitespace-collapsed, never a secret.
    func skillHubSanitize(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: " .=:/-_()[]{}<>,%+*'"))
        let filtered = String(String.UnicodeScalarView(
            text.unicodeScalars.filter { allowed.contains($0) && !"\n\r\t".unicodeScalars.contains($0) }))
        let collapsed = filtered.split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        return String(collapsed.prefix(300))
    }

    func skillHubFirstMatch(pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    /// Records one runbook case through the SHIPPED recorder, inside the guest.
    func skillHubRecordCase(
        runtime: FloeAgentRuntime, identity: ChildExecutionIdentity, context: ToolContext,
        name: String, index: Int, status: String, detail: String, sets: [String]
    ) async throws {
        var command = "PYTHONDONTWRITEBYTECODE=1 python3 webapp-testing/scripts/record_case.py "
            + "--results results/webapp-testing.jsonl --case \(name) --status \(status) "
            + "--detail '\(skillHubSanitize(detail))'"
        for set in sets { command += " --set " + set }
        let result = try await skillHubShell(runtime: runtime, identity: identity, context: context,
                                             tag: "record-\(index)-\(name)", command: command, timeout: 60)
        try #require(result.status == .ok, "record_case failed for \(name): \(result.outputSummary)")
    }

    /// Authoritative fixture-server read executed INSIDE the guest over the
    /// service's bound interface (no host interpreter, no page trust).
    func skillHubGuestFetch(
        runtime: FloeAgentRuntime, identity: ChildExecutionIdentity, context: ToolContext,
        tag: String, port: Int, path: String, readTimeout: Int = 8, shellTimeout: Int = 60
    ) async throws -> String {
        let command = "python3 -c \"import sys,urllib.request;"
            + "sys.stdout.write(urllib.request.urlopen(sys.argv[1],timeout=\(readTimeout)).read().decode())\" "
            + "'http://127.0.0.1:\(port)/\(path)'"
        let result = try await skillHubShell(runtime: runtime, identity: identity, context: context,
                                             tag: tag, command: command, timeout: shellTimeout)
        try #require(result.status == .ok, "guest /\(path) fetch failed: \(result.outputSummary)")
        guard let start = result.outputSummary.firstIndex(of: "{"),
              let end = result.outputSummary.lastIndex(of: "}"),
              let data = result.outputSummary[start...end].data(using: .utf8) else {
            throw FloeError.validationFailed("guest /\(path) returned no JSON: \(result.outputSummary.prefix(400))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    func skillHubCloseBrowserTabs(
        runtime: FloeAgentRuntime?, identity: ChildExecutionIdentity?,
        context: ToolContext?, tabs: [UUID]
    ) async {
        guard let runtime, let identity, let context else { return }
        for tab in tabs {
            guard let call = try? toolCall(id: "close-" + tab.uuidString, toolName: "browser.tab",
                                           arguments: try! Self.json(["action": "close",
                                                                      "tabID": tab.uuidString])) else { continue }
            _ = await runtime.dispatchChildTool(call, identity: identity, childContext: context)
        }
    }

    /// Loopback fetch exactly as the proven static-service test.
    func skillHubFetch(_ url: URL, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 3)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw FloeError.validationFailed("Preview did not return HTTP")
        }
        return (data, http)
    }

    // MARK: - Test 2: webapp-testing Level B + Level C (14 real cases)

    /// Runs the shipped webapp-testing contract through the REAL product
    /// surfaces: `exec.localService` readiness via the production job service,
    /// guest-loopback `/state` authority, all 14 runbook cases through the
    /// App's registered semantic `browser.*` tools under the active-parent
    /// child chain, the honest recording of the deliberately failing
    /// `absent-marker-fails` case (never PASS), the shipped recorder + gate,
    /// a live port-collision refusal, cancellation with guest/host endpoint
    /// closure, and re-hash of the real screenshot artifact bytes read back
    /// from disk. No user-device or persistent Simulator state changes: every
    /// tab, job, environment and conversation row it creates is test-owned and
    /// settled/removed in its cleanup path.
    @Test(
        "Skill Hub guest qualification: webapp-testing service, 14 real browser cases, recorder gate, collision and cancel",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_SKILLHUB_WEBAPP_QUALIFICATION"] == "1")
    )
    func skillHubWebappTestingGuestAndBrowserQualification() async throws {
        let sources = try SkillHubInputs.requireSourcesDir()
        let root = try makeWorkspaceRoot()
        var evidence: [String: String] = ["kind": "skill-hub-webapp-levelBC-not-model-not-ui",
                                          "hubSources": sources.path]
        var manifest: [SkillHubStagedFile] = []
        try SkillHubStager.stage(sources.appendingPathComponent("webapp-testing", isDirectory: true),
                                 to: root, relativePrefix: "webapp-testing", into: &manifest)
        try SkillHubStager.writeManifest(manifest, at: root)
        let ceiling: Set<String> = [
            "exec.shell", "jobs.status", "jobs.cancel",
            "browser.tab", "browser.tabs", "browser.navigate", "browser.observe",
            "browser.wait", "browser.type", "browser.click", "browser.screenshot", "browser.events",
        ]
        var ownedEnvironmentID: String?
        var parentHold: CancellationToken?
        var ownedRuntime: FloeAgentRuntime?
        var parentTask: Task<Void, Error>?
        var jobIDs: [UUID] = []
        var tabs: [UUID] = []
        var identity: ChildExecutionIdentity?
        var context: ToolContext?
        let app = try await appQualificationEnvironment()
        let conversationID = UUID()
        let runID = UUID()
        var recordsCreated = false
        let fixedIdentity = ChildExecutionIdentity(
            parentRunID: runID, rootTaskID: conversationID, delegateCallID: "skillhub-webapp")
        identity = fixedIdentity
        func finish() async {
            await skillHubCloseBrowserTabs(runtime: ownedRuntime, identity: identity,
                                           context: context, tabs: tabs)
            await skillHubCleanup(runtime: ownedRuntime, parentHold: parentHold,
                                  parentTask: parentTask, jobs: app.backgroundJobService,
                                  jobIDs: jobIDs, environmentID: ownedEnvironmentID, root: root,
                                  conversationID: recordsCreated ? conversationID : nil, app: app)
        }
        do {
            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID
            try await skillHubCreateRunRows(app: app, conversationID: conversationID, runID: runID,
                title: "Webapp-testing qualification",
                goal: "Real guest service plus real browser 14-case run; scripted parent")
            recordsCreated = true
            let jobs = try #require(app.backgroundJobService, "Production job service is unavailable")
            let hold = CancellationToken()
            parentHold = hold
            let runtime = makeRuntime(
                root: root, conversationID: conversationID, runID: runID,
                allowedToolNames: ceiling, environmentID: environmentID,
                adapter: QualificationHoldingProviderAdapter(hold: hold))
            ownedRuntime = runtime
            parentTask = Task { try await runtime.start(goal: "Qualify webapp-testing level B and C") }
            try #require(await waitForAsync(timeout: 20) {
                if case .streamingModel = await runtime.state { return true }
                return false
            }, "Parent must be active before browser child execution")
            let childContext = ToolContext(
                runID: runID, scope: .local, allowedToolNames: ceiling,
                workspaceRootURL: root, cancellation: CancellationToken(),
                environmentID: environmentID, conversationID: conversationID)
            context = childContext
            try await requireQualifiedKernel(runtime: runtime, identity: fixedIdentity,
                                             context: childContext)

            // Byte-exact staging proof + the shipped scripts compile in-guest.
            let stageResult = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "stage-verify",
                command: "PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'\n" + skillHubStageVerifyScript
                    + "\nPY", timeout: 120)
            try #require(stageResult.status == .ok && stageResult.outputSummary.contains("bad=0"),
                         "Guest staging verification failed: \(stageResult.outputSummary)")
            let compileResult = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "py-compile",
                command: "PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile webapp-testing/scripts/fixture_server.py webapp-testing/scripts/record_case.py webapp-testing/scripts/check_fixture.py && echo FLOE_WEBAPP_COMPILE_OK",
                timeout: 120)
            try #require(compileResult.status == .ok && compileResult.outputSummary.contains("FLOE_WEBAPP_COMPILE_OK"),
                         "Guest py_compile failed: \(compileResult.outputSummary)")

            // Level B: the real exec.localService submission and readiness.
            let port = Int.random(in: 20_000...45_000)
            let invocation = LocalServiceTool.Arguments(runtime: "python",
                entry: "webapp-testing/scripts/fixture_server.py", arguments: [], cwd: nil, port: port)
            let serviceJob = try await jobs.submit(
                runID: runID, toolCallID: "skillhub-fixture-server-" + UUID().uuidString,
                targetTool: "exec.localService", payloadJSON: JSONEncoder().encode(invocation),
                scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [],
                environmentID: environmentID, submissionSource: .nativeService, waitForCompletion: false)
            jobIDs.append(serviceJob.id)
            evidence["serviceJobID"] = serviceJob.id.uuidString
            evidence["servicePort"] = String(port)
            var progressSamples: [[String: String]] = []
            let preview = try await skillHubWaitPreview(jobs, id: serviceJob.id,
                                                        samples: &progressSamples, timeout: 180)
            try #require(preview.host == "127.0.0.1" && preview.port == port,
                         "PreviewURL must be the owned loopback endpoint, got \(preview)")
            // Readiness invariant across every retained poll: a previewURL is
            // never observed while the recorded state is anything but running.
            for sample in progressSamples {
                try #require(!(sample["previewURL"]?.isEmpty == false && sample["state"] != "running"),
                             "previewURL appeared before the running state: \(sample)")
            }
            let sampleData = (try? JSONEncoder().encode(progressSamples)) ?? Data()
            evidence["progressSamples"] = String(decoding: sampleData, as: UTF8.self)
            print("FLOE_SKILLHUB_WEBAPP_READY polls=\(progressSamples.count) preview=\(preview.absoluteString)")

            // Guest-side authority: the fresh server is authoritative-clean.
            let stateJSON = try await skillHubGuestFetch(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "state-ready", port: port, path: "state")
            let serverState = try JSONDecoder().decode(SkillHubServerState.self, from: Data(stateJSON.utf8))
            try #require(serverState.ready == "live" && serverState.submissions.isEmpty
                            && serverState.serverCount == 0,
                         "Fresh fixture server state is not authoritative-clean: \(stateJSON)")

            // Case 1 — nav-index.
            let created = try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case1-create", tool: "browser.tab",
                arguments: ["action": "create"])
            let tabID = try #require(created.page?.tabs.first(where: { $0.isActive })?.id,
                                     "tab create returned no active tab")
            tabs.append(tabID)
            try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case1-navigate", tool: "browser.navigate",
                arguments: ["url": preview.absoluteString, "tabID": tabID.uuidString])
            try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case1-load", tool: "browser.wait",
                arguments: ["tabID": tabID.uuidString, "condition": "load",
                            "timeoutMilliseconds": 15_000])
            var page = try await skillHubObserve(runtime: runtime, identity: fixedIdentity,
                                                 context: childContext, tag: "case1-observe",
                                                 tabID: tabID)
            let document1 = page.documentID
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "nav-index", index: 1, status: "PASS",
                detail: "tab create+navigate+wait load ok url " + preview.absoluteString,
                sets: ["document_id=" + document1])
            // Case 2 — wait-async-ready (delayed render).
            _ = try await skillHubWaitText(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case2-wait", tabID: tabID, marker: "ASYNC-READY-77")
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "wait-async-ready", index: 2, status: "PASS",
                detail: "browser.wait text resolved after the fixture delay",
                sets: ["marker=ASYNC-READY-77"])
            // Case 3 — observe-form-fields (all five named controls).
            page = try await skillHubObserve(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case3-observe", tabID: tabID)
            let nameNode = try skillHubFindRef(in: page, namePrefix: "Name", role: "input")
            let emailNode = try skillHubFindRef(in: page, namePrefix: "Email", role: "input")
            let planNode = try skillHubFindRef(in: page, namePrefix: "Plan")
            let termsNode = try skillHubFindRef(in: page, namePrefix: "Agree")
            let submitNode = try skillHubFindRef(in: page, namePrefix: "Save signup", role: "button")
            _ = try skillHubFindRef(in: page, namePrefix: "Register click", role: "button")
            _ = try skillHubFindRef(in: page, namePrefix: "Proceed to checkout", role: "a")
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "observe-form-fields", index: 3, status: "PASS",
                detail: "semantic refs present for name email plan terms submit",
                sets: ["document_id=" + page.documentID, "refs_found=5"])
            // Case 4 — input-signup-fields (values visible, no submit).
            let typedName = try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case4-type-name", tool: "browser.type",
                arguments: ["tabID": tabID.uuidString, "ref": nameNode.ref,
                            "documentID": page.documentID, "text": "Ada"])
            try #require(typedName.page?.nodes.contains { $0.ref == nameNode.ref && $0.value == "Ada" } == true,
                         "typed name value not visible in the returned snapshot")
            let typedEmail = try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case4-type-email", tool: "browser.type",
                arguments: ["tabID": tabID.uuidString, "ref": emailNode.ref,
                            "documentID": typedName.page?.documentID ?? page.documentID,
                            "text": "ada@example.invalid"])
            try #require(typedEmail.page?.nodes.contains {
                $0.ref == emailNode.ref && $0.value == "ada@example.invalid"
            } == true, "typed email value not visible in the returned snapshot")
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "input-signup-fields", index: 4, status: "PASS",
                detail: "type returned value-set snapshots without submit",
                sets: ["document_id=" + (typedEmail.page?.documentID ?? page.documentID)])
            // Case 5 — click-submit (page signal only; case 6 attests).
            let document5 = typedEmail.page?.documentID ?? page.documentID
            try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case5-click", tool: "browser.click",
                arguments: ["tabID": tabID.uuidString, "ref": submitNode.ref, "documentID": document5])
            _ = try await skillHubWaitText(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case5-wait", tabID: tabID, marker: "status: saved")
            page = try await skillHubObserve(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case5-observe", tabID: tabID)
            let statusText = page.nodes.first { $0.text.contains("status: saved") }?.text ?? ""
            let receipt = try #require(skillHubFirstMatch(pattern: "[0-9a-f]{12}", in: statusText),
                                       "post-click status carries no 12-hex receipt: \(statusText)")
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "click-submit", index: 5, status: "PASS",
                detail: "page showed saved status with receipt", sets: ["document_id=" + page.documentID])
            // Case 6 — attest-submit-state from the server authority.
            let stateAfterSubmit = try await skillHubGuestFetch(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "state-submit", port: port, path: "state")
            let submitState = try JSONDecoder().decode(SkillHubServerState.self,
                                                      from: Data(stateAfterSubmit.utf8))
            try #require(submitState.submissions.last?.receipt == receipt,
                         "server receipt does not match the page-displayed receipt: \(stateAfterSubmit.prefix(300))")
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "attest-submit-state", index: 6, status: "PASS",
                detail: "guest state submission matches the page receipt",
                sets: ["receipt=" + receipt])
            // Case 7 — click-counter.
            let countNode = try skillHubFindRef(in: page, namePrefix: "Register click", role: "button")
            try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case7-click", tool: "browser.click",
                arguments: ["tabID": tabID.uuidString, "ref": countNode.ref,
                            "documentID": page.documentID])
            _ = try await skillHubWaitText(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case7-wait", tabID: tabID, marker: "count: 1")
            page = try await skillHubObserve(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case7-observe", tabID: tabID)
            let countText = page.nodes.first { $0.text.contains("count:") }?.text ?? ""
            let countValue = try #require(skillHubFirstMatch(pattern: "count: [0-9]+", in: countText),
                                          "counter region missing after the click")
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "click-counter", index: 7, status: "PASS",
                detail: countValue, sets: ["document_id=" + page.documentID])
            // Case 8 — attest-counter-state (server counter, independent of page text).
            let stateAfterClick = try await skillHubGuestFetch(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "state-click", port: port, path: "state")
            let clickState = try JSONDecoder().decode(SkillHubServerState.self,
                                                     from: Data(stateAfterClick.utf8))
            try #require(clickState.serverCount >= 1, "server counter never incremented: \(stateAfterClick)")
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "attest-counter-state", index: 8, status: "PASS",
                detail: "guest state serverCount proves the click reached the server",
                sets: ["server_count=" + String(clickState.serverCount)])
            // Case 9 — screenshot-evidence with real artifact re-hash.
            let shot = try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case9-shot", tool: "browser.screenshot",
                arguments: ["tabID": tabID.uuidString])
            let artifact = try #require(shot.page?.screenshotArtifact, "screenshot returned no artifact reference")
            let support = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let artifactURL = support.appendingPathComponent("FloeAgent").appendingPathComponent(artifact.relativePath)
            let artifactBytes = try Data(contentsOf: artifactURL)
            try #require(artifactBytes.count == artifact.byteCount,
                         "screenshot bytes differ from the recorded byte count")
            let artifactSHA = FloeDigest.sha256Hex(artifactBytes)
            try #require(artifactSHA == artifact.sha256.lowercased(),
                         "screenshot re-hash differs from the recorded sha256: \(artifact.sha256) vs \(artifactSHA)")
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "screenshot-evidence", index: 9, status: "PASS",
                detail: "artifact retained and re-hashed from disk bytes",
                sets: ["screenshot_path=" + artifact.relativePath, "screenshot_sha256=" + artifactSHA])
            // Case 10 — navigate-checkout (main-frame commit to a new document).
            let checkoutLink = try skillHubFindRef(in: page, namePrefix: "Proceed to checkout", role: "a")
            try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case10-click", tool: "browser.click",
                arguments: ["tabID": tabID.uuidString, "ref": checkoutLink.ref,
                            "documentID": page.documentID])
            let waited10 = try await skillHubWaitText(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case10-wait", tabID: tabID, marker: "CHECKOUT-OK-222")
            try #require(waited10.page?.documentID != document1,
                         "checkout navigation never committed a new document")
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "navigate-checkout", index: 10, status: "PASS",
                detail: "new document after checkout click marker visible",
                sets: ["marker=CHECKOUT-OK-222"])
            // Case 11 — click-confirm.
            page = try await skillHubObserve(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case11-observe", tabID: tabID)
            let confirmNode = try skillHubFindRef(in: page, namePrefix: "Confirm order", role: "button")
            try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case11-click", tool: "browser.click",
                arguments: ["tabID": tabID.uuidString, "ref": confirmNode.ref,
                            "documentID": page.documentID])
            _ = try await skillHubWaitText(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case11-wait", tabID: tabID, marker: "CONFIRMED-OK-221")
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "click-confirm", index: 11, status: "PASS",
                detail: "confirm state visible after the click", sets: ["marker=CONFIRMED-OK-221"])
            // Case 12 — stale-after-reload: BOTH halves must really happen.
            page = try await skillHubObserve(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case12-observe", tabID: tabID)
            let backLink = try skillHubFindRef(in: page, namePrefix: "Back to signup", role: "a")
            try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case12-back", tool: "browser.click",
                arguments: ["tabID": tabID.uuidString, "ref": backLink.ref,
                            "documentID": page.documentID])
            _ = try await skillHubWaitText(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case12-wait-index", tabID: tabID,
                marker: "Register click", timeoutMilliseconds: 10_000)
            page = try await skillHubObserve(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case12-observe-2", tabID: tabID)
            let reloadNode = try skillHubFindRef(in: page, namePrefix: "Reload page", role: "button")
            try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case12-reload", tool: "browser.click",
                arguments: ["tabID": tabID.uuidString, "ref": reloadNode.ref,
                            "documentID": page.documentID])
            let staleAttempt = try await skillHubBrowserFailure(runtime: runtime,
                identity: fixedIdentity, context: childContext, tool: "browser.click",
                arguments: ["tabID": tabID.uuidString, "ref": reloadNode.ref,
                            "documentID": page.documentID])
            try #require(staleAttempt.status != .ok,
                         "a pre-reload ref/document pair must not succeed after the reload commits")
            try #require(staleAttempt.outputSummary.contains("The page changed")
                            || staleAttempt.outputSummary.contains("observe it again"),
                         "the stale half must surface the documented recovery message: \(staleAttempt.outputSummary)")
            let recoveryPage = try await skillHubObserve(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case12-recovery", tabID: tabID)
            _ = try skillHubFindRef(in: recoveryPage, namePrefix: "Register click", role: "button")
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "stale-after-reload", index: 12, status: "PASS",
                detail: "stale refusal observed then fresh observation recovered",
                sets: ["stale_observed=true", "recovery_observed=true"])
            // Case 13 — late-result-slow over the guest loopback + event read.
            let slowText = try await skillHubGuestFetch(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "state-slow", port: port, path: "slow",
                readTimeout: 8, shellTimeout: 40)
            try #require(slowText.contains("SLOW-DONE-45"), "late /slow answer missing: \(slowText)")
            let events = try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "case13-events", tool: "browser.events",
                arguments: ["tabID": tabID.uuidString, "afterSequence": 0, "limit": 50])
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "late-result-slow", index: 13, status: "PASS",
                detail: "slow answered after about two seconds events read status " + events.status,
                sets: ["marker=SLOW-DONE-45"])
            // Case 14 — the deliberate honest failure, recorded TIMEOUT.
            let absent = try await skillHubBrowserFailure(runtime: runtime, identity: fixedIdentity,
                context: childContext, tool: "browser.wait",
                arguments: ["tabID": tabID.uuidString, "condition": "text",
                            "value": "MARKER-NEVER-RENDERED", "timeoutMilliseconds": 1_500])
            try #require(absent.status != .ok,
                         "the absent-marker wait must NOT succeed (dishonest fixture state)")
            try await skillHubRecordCase(runtime: runtime, identity: fixedIdentity,
                context: childContext, name: "absent-marker-fails", index: 14, status: "TIMEOUT",
                detail: skillHubSanitize(absent.outputSummary), sets: ["error=timeout"])

            // The shipped deterministic gate + host-side JSONL check.
            let gate = try await skillHubShell(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "gate",
                command: "PYTHONDONTWRITEBYTECODE=1 python3 webapp-testing/scripts/check_fixture.py --results results/webapp-testing.jsonl",
                timeout: 120)
            evidence["gate"] = String(gate.outputSummary.prefix(2_000))
            try #require(gate.status == .ok,
                         "the shipped gate rejected the honest run (exit non-zero): \(gate.outputSummary.prefix(800))")
            let passCount = gate.outputSummary.components(separatedBy: "CHECK PASS").count - 1
            try #require(passCount >= 14, "expected 14 CHECK PASS lines, got \(passCount): \(gate.outputSummary.prefix(800))")
            try #require(gate.outputSummary.contains("absent-marker-fails status=TIMEOUT")
                            || gate.outputSummary.contains("absent-marker-fails status=FAIL"),
                         "the gate must read the failing case honestly: \(gate.outputSummary.prefix(500))")
            let resultsBytes = try Data(contentsOf: root.appendingPathComponent("results/webapp-testing.jsonl"))
            let records = String(decoding: resultsBytes, as: UTF8.self)
                .split(separator: "\n").compactMap { line in
                    try? JSONDecoder().decode(SkillHubRecordedCase.self, from: Data(String(line).utf8))
                }
            try #require(records.count == 14, "14 recorded cases expected, got \(records.count)")
            for record in records {
                if record.caseName == "absent-marker-fails" {
                    try #require(record.status == "TIMEOUT" || record.status == "FAIL",
                                 "the failing case must stay honestly recorded")
                } else {
                    try #require(record.status == "PASS",
                                 "case \(record.caseName) must reflect its real PASS, got \(record.status)")
                }
            }
            print("FLOE_SKILLHUB_WEBAPP_JSONL sha256=\(FloeDigest.sha256Hex(resultsBytes)) cases=14")

            // One deliberate live port collision: closed failure, no resubmit.
            let collision = try await jobs.submit(
                runID: runID, toolCallID: "skillhub-collision-" + UUID().uuidString,
                targetTool: "exec.localService", payloadJSON: JSONEncoder().encode(invocation),
                scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [],
                environmentID: environmentID, submissionSource: .nativeService, waitForCompletion: false)
            jobIDs.append(collision.id)
            let collisionJob = try await skillHubWaitTerminal(jobs, id: collision.id, seconds: 240)
            let collisionText = (collisionJob.lastError ?? "") + (collisionJob.resultSummary ?? "")
            evidence["collision"] = String(collisionText.prefix(500))
            try #require(collisionJob.state != .completed,
                         "a second service on the live port must fail closed, never start")
            try #require(collisionText.lowercased().contains("port"),
                         "the collision refusal must name the port conflict: \(collisionText.prefix(300))")

            // jobs.status while running through the same child chain (bounded
            // production view: state running + the owned previewURL document).
            let statusCall = try toolCall(id: "jobs-status-running", toolName: "jobs.status",
                arguments: try Self.json(["jobID": serviceJob.id.uuidString]))
            let statusResult = await runtime.dispatchChildTool(statusCall, identity: fixedIdentity,
                                                               childContext: childContext)
            try #require(statusResult.status == .ok
                            && statusResult.outputSummary.contains("http://127.0.0.1:\(port)"),
                         "jobs.status must expose the running previewURL: \(statusResult.outputSummary.prefix(400))")
            evidence["jobsStatusRunning"] = String(statusResult.outputSummary.prefix(1_200))

            // Cancellation: real guest process exit, endpoint closure both
            // sides, terminal cancelled reported by the production view.
            let cancelCall = try toolCall(id: "jobs-cancel-service", toolName: "jobs.cancel",
                arguments: try Self.json(["jobID": serviceJob.id.uuidString]))
            let cancelResult = await runtime.dispatchChildTool(cancelCall, identity: fixedIdentity,
                                                               childContext: childContext)
            try #require(cancelResult.status == .ok, "jobs.cancel dispatch failed: \(cancelResult.outputSummary)")
            let cancelled = try await skillHubWaitTerminal(jobs, id: serviceJob.id, seconds: 90)
            try #require(cancelled.state == .cancelled,
                         "cancellation did not settle honestly: \(cancelled.state.rawValue)")
            let closedStatus = await runtime.dispatchChildTool(
                try toolCall(id: "jobs-status-cancelled", toolName: "jobs.status",
                             arguments: try Self.json(["jobID": serviceJob.id.uuidString])),
                identity: fixedIdentity, childContext: childContext)
            try #require(closedStatus.outputSummary.contains("cancelled"),
                         "jobs.status must report the terminal cancellation: \(closedStatus.outputSummary.prefix(300))")
            // The final stored progress document nulls previewURL on exit
            // (LocalServiceTool runGuestService): runbook §6 closure evidence.
            try #require(!closedStatus.outputSummary.contains("http://127.0.0.1:\(port)"),
                         "previewURL must vanish from jobs.status once cancelled: \(closedStatus.outputSummary.prefix(400))")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 3
            configuration.timeoutIntervalForResource = 5
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let deadline = Date().addingTimeInterval(15)
            var stillReachable = true
            repeat {
                do { _ = try await skillHubFetch(preview, session: session); stillReachable = true }
                catch { stillReachable = false }
                if !stillReachable { break }
                try await Task.sleep(for: .milliseconds(250))
            } while Date() < deadline
            try #require(!stillReachable, "the cancelled fixture endpoint must not stay reachable from the host")
            let deadState = try await skillHubShell(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "state-dead",
                command: "python3 -c \"import sys,urllib.request;urllib.request.urlopen(sys.argv[1],timeout=4).read()\" 'http://127.0.0.1:\(port)/state' && echo GUEST_STATE_STILL_REACHABLE",
                timeout: 30)
            try #require(deadState.status != .ok || !deadState.outputSummary.contains("GUEST_STATE_STILL_REACHABLE"),
                         "the cancelled service endpoint must not stay reachable inside the guest")
            print("FLOE_SKILLHUB_WEBAPP_QUALIFIED service=\(serviceJob.id) receipt=\(receipt) gate=exit0 collision=\(collisionJob.state.rawValue) cancel=settled")
            await finish()
        } catch {
            evidence["failure"] = String(describing: error)
            skillHubFailureEvidence(evidence, root: root, label: "webapp")
            await skillHubCloseBrowserTabs(runtime: ownedRuntime, identity: identity,
                                           context: context, tabs: tabs)
            Issue.record("webapp-testing Level B+C qualification failed: \(error)")
            await finish()
        }
    }
}

// ============================================================================
// PART C — real guest node-http MCP service. Its logic uses ONLY PART A's
// helpers (no browser helper from PART B), but the delivered patch file
// 0003 applies sequentially after A+B because its diff context ends inside
// B's block. If Main wants A+C without B, request a regenerated context —
// no source change is needed, C never calls a B-only helper.
// Opt-in: FLOE_SKILLHUB_MCP_NODE_QUALIFICATION=1.
// ============================================================================

extension SubagentSimulatorExecutionTests {

    // MARK: - Test 3: real guest node-http MCP service (template, no model)

    /// Creates the bundled reviewed node-http MCP service the way the
    /// production creation chain stages it — digest-gated `MCPServiceTemplate`
    /// load, the same `SignedContentArchive` limits and allowed top level, the
    /// production launcher/build command bytes, the fixed immutable-project
    /// digest gate, the `exec.localService` node runtime through the real job
    /// service — then exercises it with the real `MCPRemoteClient` (initialize,
    /// tools/list, tools/call on the fixed `service_status` contract) and
    /// cancels it with verified endpoint closure. There is no fake Node
    /// substitute: if the guest cannot provide Node, this qualification fails
    /// unproven with the production provisioner error retained; it never
    /// silently skips. Registration into the user's persisted MCP connection
    /// store is deliberately excluded (no persistent Simulator state change);
    /// that remains coordinator-owned.
    @Test(
        "Skill Hub guest qualification: bundled node-http MCP template builds, serves and answers the real MCP client in the Linux guest",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_SKILLHUB_MCP_NODE_QUALIFICATION"] == "1")
    )
    func skillHubMCPNodeHTTPLiveGuestQualification() async throws {
        let root = try makeWorkspaceRoot()
        var evidence: [String: String] = ["kind": "skill-hub-mcp-node-guest-not-model-not-ui"]
        var ownedEnvironmentID: String?
        var parentHold: CancellationToken?
        var ownedRuntime: FloeAgentRuntime?
        var parentTask: Task<Void, Error>?
        var jobIDs: [UUID] = []
        var conversationID: UUID?
        var app: AppEnvironment?
        let operationDirectory = "MCPServices/" + UUID().uuidString.lowercased()

        func finish() async {
            await skillHubCleanup(runtime: ownedRuntime, parentHold: parentHold,
                                  parentTask: parentTask, jobs: app?.backgroundJobService,
                                  jobIDs: jobIDs, environmentID: ownedEnvironmentID, root: root,
                                  conversationID: conversationID, app: app)
        }
        do {
            // 1. Production digest-gated template load + byte-exact staging.
            let template = try MCPServiceTemplate.load()
            try #require(template.contract.templateID == "floe.mcp.node-http")
            try #require(template.contract.templateVersion == "1.0.1")
            try #require(template.contract.runtime.os == "linux")
            try #require(template.contract.runtime.node == ">=20.19.0")
            try #require(template.contract.sdk.package == "@modelcontextprotocol/sdk")
            try #require(template.contract.sdk.version == "1.32.2")
            try #require(template.contract.smokeTest.tool == "service_status")
            // The frozen contract stays honest until real guest runs land.
            try #require(template.contract.runtime.guestExecutionVerified == false,
                         "the template contract must still declare guest execution unproven")
            let archiveSHA = FloeDigest.sha256Hex(template.archive)
            evidence["templateArchiveSHA256"] = archiveSHA
            try #require(FloeDigest.sha256Hex(template.contractBytes)
                            == MCPServiceTemplate.immutableProjectDigests["contract.json"],
                         "contract bytes differ from the pinned immutable digest")
            var manifest: [SkillHubStagedFile] = []
            try SkillHubStager.stageBytes(template.archive, to: root,
                                          path: "mcp-template.zip", into: &manifest)
            _ = try SignedContentArchive.extract(
                template.archive,
                at: root.appendingPathComponent(operationDirectory, isDirectory: true),
                limits: .init(maximumEntries: 32, maximumFileBytes: 262_144,
                              maximumTotalBytes: 1_048_576),
                allowedTopLevel: ["README.md", "contract.json", "node-http"])
            let launcher = root.appendingPathComponent(operationDirectory)
                .appendingPathComponent("node-http/floe-start.mjs")
            try SkillHubStager.stageBytes(Data(MCPServiceCreationAppBackend.launcher.utf8), to: root,
                                          path: operationDirectory + "/node-http/floe-start.mjs",
                                          into: &manifest)
            for (path, expected) in MCPServiceTemplate.immutableProjectDigests {
                let file = root.appendingPathComponent(operationDirectory).appendingPathComponent(path)
                let bytes = try Data(contentsOf: file)
                try #require(FloeDigest.sha256Hex(bytes) == expected,
                             "staged \(path) differs from the pinned immutable digest")
                manifest.append(SkillHubStagedFile(path: operationDirectory + "/" + path,
                                                   sha256: expected, bytes: bytes.count))
            }
            _ = launcher // referenced through the manifest entry above
            try SkillHubStager.writeManifest(manifest, at: root)

            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID
            let liveApp = try await appQualificationEnvironment()
            app = liveApp
            let jobs = try #require(liveApp.backgroundJobService, "Production job service is unavailable")
            let runID = UUID()
            let conversationUUID = UUID()
            conversationID = conversationUUID
            try await skillHubCreateRunRows(app: liveApp, conversationID: conversationUUID, runID: runID,
                title: "MCP node-http qualification",
                goal: "Real guest node MCP service through owned jobs; no model")

            let ceiling: Set<String> = ["exec.shell", "jobs.status", "jobs.cancel"]
            let hold = CancellationToken()
            parentHold = hold
            let runtime = makeRuntime(
                root: root, conversationID: conversationUUID, runID: runID,
                allowedToolNames: ceiling, environmentID: environmentID,
                adapter: QualificationHoldingProviderAdapter(hold: hold))
            ownedRuntime = runtime
            parentTask = Task { try await runtime.start(goal: "Qualify the node-http MCP guest service") }
            try #require(await waitForAsync(timeout: 20) {
                if case .streamingModel = await runtime.state { return true }
                return false
            }, "Parent must be active before the MCP child checks")
            let context = ToolContext(
                runID: runID, scope: .local, allowedToolNames: ceiling,
                workspaceRootURL: root, cancellation: CancellationToken(),
                environmentID: environmentID, conversationID: conversationUUID)
            let identity = ChildExecutionIdentity(
                parentRunID: runID, rootTaskID: conversationUUID, delegateCallID: "skillhub-mcp")
            try await requireQualifiedKernel(runtime: runtime, identity: identity, context: context)

            let stageResult = try await skillHubShell(
                runtime: runtime, identity: identity, context: context, tag: "mcp-stage-verify",
                command: "PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'\n" + skillHubStageVerifyScript
                    + "\nPY", timeout: 120)
            try #require(stageResult.status == .ok && stageResult.outputSummary.contains("bad=0"),
                         "Guest staging verification failed: \(stageResult.outputSummary)")

            // 2. Guest Node must be REAL and production-provisioned. A missing
            //    or unprovisionable runtime fails this test explicitly.
            let services = FloePlatformServices.shared
            let runner = try #require(services.linuxCommandRunner(),
                                      "Production Linux command runner is unavailable")
            let node: LinuxGuestNodeEnvironment
            do {
                node = try await LinuxGuestNodeProvisioner.shared.ensure(
                    environmentID: environmentID, runner: runner, cancellation: CancellationToken())
            } catch {
                throw FloeError.validationFailed(
                    "guest Node is unavailable/unproven (this qualification must fail, not skip): \(error)")
            }
            try #require(!node.nodePath.isEmpty && !node.npmPath.isEmpty,
                         "guest node/npm paths are empty")
            evidence["guestNodePath"] = node.nodePath
            evidence["guestNodeVersion"] = node.version ?? "unknown"
            print("FLOE_SKILLHUB_NODE path=\(node.nodePath) version=\(node.version ?? "unknown")")

            // 3. The production fixed build contract runs in the guest.
            let build = try await skillHubSubmitShell(
                jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                name: "mcp-build", command: MCPServiceCreationAppBackend.buildCommand,
                timeout: 600, cwd: operationDirectory + "/node-http")
            jobIDs.append(build)
            let buildJob = try await skillHubWaitTerminal(jobs, id: build, seconds: 780)
            evidence["build"] = buildJob.resultSummary ?? buildJob.lastError ?? buildJob.state.rawValue
            try #require(buildJob.state == .completed,
                         "guest node-http template build/test contract failed: \(evidence["build"] ?? "unknown")")
            let dist = try await skillHubShell(
                runtime: runtime, identity: identity, context: context, tag: "dist-hash",
                command: "test -s \(operationDirectory)/node-http/dist/server.js && sha256sum \(operationDirectory)/node-http/dist/server.js",
                timeout: 60)
            try #require(dist.status == .ok, "built server missing after a completed build: \(dist.outputSummary)")
            evidence["distServer"] = String(dist.outputSummary.prefix(300))

            // 4. Serve the built MCP through the real exec.localService node runtime.
            let port = Int.random(in: 20_000...45_000)
            let invocation = LocalServiceTool.Arguments(
                runtime: "node", entry: operationDirectory + "/node-http/floe-start.mjs",
                arguments: [], cwd: operationDirectory + "/node-http", port: port)
            let serviceJob = try await jobs.submit(
                runID: runID, toolCallID: "skillhub-mcp-service-" + UUID().uuidString,
                targetTool: "exec.localService", payloadJSON: JSONEncoder().encode(invocation),
                scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [],
                environmentID: environmentID, submissionSource: .nativeService, waitForCompletion: false)
            jobIDs.append(serviceJob.id)
            evidence["serviceJobID"] = serviceJob.id.uuidString
            var samples: [[String: String]] = []
            let preview = try await skillHubWaitPreview(jobs, id: serviceJob.id,
                                                        samples: &samples, timeout: 180)
            try #require(preview.host == "127.0.0.1" && preview.port == port,
                         "preview endpoint must be the owned loopback, got \(preview)")
            for sample in samples {
                try #require(!(sample["previewURL"]?.isEmpty == false && sample["state"] != "running"),
                             "previewURL appeared before the running state: \(sample)")
            }
            let sampleData = (try? JSONEncoder().encode(samples)) ?? Data()
            evidence["progressSamples"] = String(decoding: sampleData, as: UTF8.self)

            // 5. The REAL production MCP client against the fixed contract.
            let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp")!
            let configuration = MCPServerConfiguration(
                id: UUID(), displayName: "Floe node-http qualification", endpoint: endpoint,
                enabled: true, allowInCanvas: false, allowInsecureHTTP: true, authentication: .none)
            let client = try MCPRemoteClient(configuration: configuration, credential: nil)
            do {
                try await client.prepareLegacySession()
                let tools = try await client.discoverTools()
                let status = try #require(tools.first(where: { $0.remoteName == "service_status" }),
                                          "the template's fixed status tool was not discovered: \(tools.map(\.remoteName))")
                try #require(status.readOnlyHint && !status.destructiveHint,
                             "service_status must stay read-only and non-destructive")
                let output = try await client.callTool(name: "service_status",
                    argumentsJSON: Data(#"{"label":"floe-native-verification"}"#.utf8))
                try #require(output.exitStatus == 0, "status call failed: \(output.summary.prefix(400))")
                let content = try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: String]
                try #require(content?["status"] == "ready"
                                && content?["service"] == "floe-mcp-service"
                                && content?["label"] == "floe-native-verification",
                             "structured content must match the pinned smoke contract: \(output.summary.prefix(400))")
                evidence["smokeSHA256"] = output.fullOutputSHA256
                // 6. Cancellation with honest closure: terminal cancelled, the
                //    guest endpoint refuses, and a post-cancel client call fails.
                _ = try await jobs.cancel(id: serviceJob.id)
                let terminal = try await skillHubWaitTerminal(jobs, id: serviceJob.id, seconds: 90)
                try #require(terminal.state == .cancelled,
                             "MCP service cancellation is not honest: \(terminal.state.rawValue)")
                let finalStatus = try toolCall(id: "jobs-status-mcp-final", toolName: "jobs.status",
                    arguments: try Self.json(["jobID": serviceJob.id.uuidString]))
                let finalResult = await runtime.dispatchChildTool(finalStatus, identity: identity,
                                                                  childContext: context)
                try #require(finalResult.outputSummary.contains("cancelled"),
                             "jobs.status must report the terminal cancelled service: \(finalResult.outputSummary.prefix(300))")
                try #require(!finalResult.outputSummary.contains("http://127.0.0.1:\(port)"),
                             "previewURL must vanish from jobs.status once cancelled: \(finalResult.outputSummary.prefix(400))")
                var refused = false
                do {
                    _ = try await client.callTool(name: "service_status",
                        argumentsJSON: Data(#"{"label":"post-cancel-probe"}"#.utf8))
                } catch { refused = true }
                try #require(refused, "the cancelled guest MCP endpoint must refuse real requests")
            } catch {
                await client.disconnect()
                throw error
            }
            await client.disconnect()
            print("FLOE_SKILLHUB_MCP_QUALIFIED service=\(serviceJob.id) node=\(node.version ?? "unknown") build=completed smoke=\(evidence["smokeSHA256"] ?? "missing")")
            await finish()
        } catch {
            evidence["failure"] = String(describing: error)
            skillHubFailureEvidence(evidence, root: root, label: "mcp-node")
            Issue.record("MCP node-http guest qualification failed: \(error)")
            await finish()
        }
    }
}


// ==== Impeccable engine guest + native capture loop qualification ====
// ============================================================================
// Impeccable engine qualification — PRIVATE PROPOSAL (job-c50410e5135949db).
//
// Append-only content for FloeAgent/Tests/FloeAppTests/SubagentSimulatorExecutionTests.swift.
// Insert this block AFTER the Skill Hub guest qualification blocks (the
// `skillHubMCPNodeHTTPLiveGuestQualification` function) and BEFORE the final
// `#endif`. Same-file extension: no project.yml or membership change.
//
// Frozen inputs (verified as DATA on the host on 2026-10-26; no host engine
// execution anywhere in this harness):
//   * FLOE_IMPECCABLE_TRANSPORT_ZIP -> Local/Artifacts/skill-hub-20261026/
//     impeccable-riscv64-qualification-0.1.17-floe1.0.0.zip
//     (3,376,092 bytes, sha256 38b0959119395d26dd2b8a8381e8c1d69e2724d7c0dcfdea5856b074a1237210,
//     128 safe relative entries). The engine dependency is a raw fixture
//     transport only, never a Skill ZIP: the normal Skill ZIP size/type caps
//     are untouched.
//   * engine/floe-impeccable: 5,579,704 bytes, sha256
//     af8795bf9636e763541c58ef90ee889941e468f453ec6580c32a89a5a758b87b,
//     static RISC-V ELF; probe stdout is exactly
//     "impeccable-engine 0.1.17+floe.1.0.0"; `contract` sha256 is
//     baf2453164be6162703af9d671be16da152fa874db53ce95ad5b3516d40de4a3.
//   * root Hub qemu/docker evidence is NOT guest proof: only the real App
//     TinyEMU guest below is. The root package stays unqualified/unpublished;
//     no catalog, claim or version is touched here.
//
// Opt-in, fail-closed (a plain disabled run is reported as disabled, never a
// pass — the existing real-guest policy in this file):
//   * FLOE_IMPECCABLE_ENGINE_QUALIFICATION=1  + FLOE_IMPECCABLE_TRANSPORT_ZIP
//   * FLOE_IMPECCABLE_CAPTURE_QUALIFICATION=1 + FLOE_IMPECCABLE_TRANSPORT_ZIP
//     + FLOE_SKILL_HUB_SOURCES_DIR (fixture server pages only)
//
// Everything executes through the SAME real production chain the Skill Hub
// blocks above use: bootGuest -> makeRuntime -> active parent ->
// requireQualifiedKernel -> dispatchChildTool(exec.shell / browser.*), the
// production BackgroundJobService.submit for exec.localService, and the real
// browser.observe profile=design capture/facts/release path. The engine runs
// ONLY inside the resolved Linux guest on its staged, guest-re-hashed bytes
// (chmod +x in the guest after the re-hash). No host engine execution, no
// fabricated outputs, no new model-facing tools, no permission bypass.
//
// Nonzero engine exits are semantic results, never crashes: 0 clean (unreachable
// in v1), 1 failed, 2 findings, 3 needs-facts, 4 inconclusive. The harness
// preserves those distinctions instead of flattening them.
// ============================================================================

// MARK: - Impeccable pinned transport + contract constants (file scope, private)

private enum ImpeccableInputs {
    static let transportZipSHA256 =
        "38b0959119395d26dd2b8a8381e8c1d69e2724d7c0dcfdea5856b074a1237210"
    static let transportZipBytes = 3_382_274
    static let engineSHA256 =
        "af8795bf9636e763541c58ef90ee889941e468f453ec6580c32a89a5a758b87b"
    static let engineBytes = 5_579_704
    static let engineProbeLine = "impeccable-engine 0.1.17+floe.1.0.0"
    static let engineVersionLine = "0.1.17+floe.1.0.0"
    static let contractSHA256 =
        "baf2453164be6162703af9d671be16da152fa874db53ce95ad5b3516d40de4a3"
    static let launcherSHA256 =
        "b317617bb9f473a4d80b3477543d015f8d7d2645f63f0998acbce43bcbf58cc4"

    // Frozen synthetic-golden fixtures and goldens (sha256 pinned, re-hashed
    // inside the guest after byte-exact staging from the verified zip).
    static let fixtureSnapshotSHA256 =
        "4c9fec636a1c0d8a8bc593d963501dbd51aca147cba1e9e25fbd93179944127d"
    static let fixtureIdentitySHA256 =
        "bbcc122bd96c86c395c50a23c47db6d4bd7f7de7da99a83f35ee58a5fa38c08b"
    static let fixtureOverlayFactsSHA256 =
        "a1aca5caaf8166bedd6391365382095ffa926d10949361b8890e3e749908e6df"
    static let fixtureNoAnswerFactsSHA256 =
        "64c5cce236dfd9ba1396b65bbd560c42a8dc70cdc6c20330a73978faa2612560"
    static let fixtureNoFindingsSnapshotSHA256 =
        "62300523e24248e3356b8250fb5c02df15079ea839d7680e1b450a02d4fd2689"
    static let fixtureNoFindingsIdentitySHA256 =
        "89f225516fd4cbca673cac0f983837ca36b4fed1f818c90e4dad1f6900be5f72"
    static let fixtureNoFindingsFactsSHA256 =
        "372ed6f8fe49fe0b5c74dda8225dc2d7e8035ea8958118a6e5f38253e4e3f572"
    static let goldenOverlayRound1SHA256 =
        "3b60240583f4ed26b76ac169a76e7994461cc99359d64d3f8bb7b827fa17fdcb"
    static let goldenOverlayRound2SHA256 =
        "7a7e6c420275cf66ebd4934bdfbd49a2fac78a8053a2ef3360e9de6cf2c80eb5"
    static let goldenNoFindingsSHA256 =
        "d87ff1559367c0328722ee239c35106e94b257fa962190e2579059ee488b4bc0"
    static let goldenNeedsPoints = 169

    /// The six v1 coverage gaps that can never be certified by the engine
    /// alone, from the frozen `no-findings` golden. v1 verdict `clean` is
    /// unreachable by design: 0 findings still exits 4 `inconclusive`.
    static let alwaysUncoveredRequired = [
        "pixel-contrast", "reveal-sweep", "content-hidden-at-rest-measure",
        "script-errors", "cross-origin-iframe", "same-origin-iframe",
    ]

    static func requireTransportZip() throws -> URL {
        let path = ProcessInfo.processInfo.environment["FLOE_IMPECCABLE_TRANSPORT_ZIP"] ?? ""
        guard !path.isEmpty else {
            throw FloeError.validationFailed(
                "Impeccable qualification requires FLOE_IMPECCABLE_TRANSPORT_ZIP")
        }
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == transportZipBytes else {
            throw FloeError.validationFailed(
                "Impeccable transport zip size is \(String(describing: values.fileSize)), expected \(transportZipBytes)")
        }
        let digest = FloeDigest.sha256Hex(try Data(contentsOf: url))
        guard digest == transportZipSHA256 else {
            throw FloeError.validationFailed("Impeccable transport zip sha256 mismatch: \(digest)")
        }
        return url
    }
}

/// Small result-document projection: exactly the fields this harness asserts.
private struct ImpeccableEngineResult: Decodable {
    struct Needs: Decodable {
        let hitTests: [[Double]]?
        let scrollProbes: [Int]?
    }
    struct Findings: Decodable {
        struct Counts: Decodable {
            let total: Int?
            let byRule: [String: Int]?
        }
        let counts: Counts?
    }
    struct Coverage: Decodable {
        let uncoveredRequired: [String]?
    }
    struct IdentityEcho: Decodable {
        let taskId: String?
        let captureId: String?
        let documentId: String?
    }
    struct Failure: Decodable {
        let code: String?
        let message: String?
    }
    let status: String?
    let verdict: String?
    let needs: Needs?
    let findings: Findings?
    let coverage: Coverage?
    let identity: IdentityEcho?
    let error: Failure?
}

private struct ImpeccableDesignCaptureResponse: Decodable {
    struct Capture: Decodable {
        struct Binding: Decodable {
            let taskId: String
            let sessionId: String
            let tabId: String
            let documentId: String
            let documentGeneration: Int
            let captureId: String
        }
        let captureId: String
        let binding: Binding
        let bridgeRootIsTaskWorkspace: Bool
        let relativeSnapshotFile: String
        let relativeIdentityFile: String
        let documentGeneration: Int
        let elementCount: Int
        let snapshotBytes: Int
        let scriptDigest: String
    }
    let profile: String
    let state: String
    let capture: Capture
}

private struct ImpeccableDesignFactsResponse: Decodable {
    let state: String
    let captureID: String
    let relativeFactsFile: String
}

/// Guest-side engine driver: runs one engine invocation, captures its exact
/// exit code, wall time (guest clock) and peak RSS sampled from /proc while
/// the process lives. RSS is reported as `unavailable` when /proc is not
/// readable — it is never synthesized. The sampler breaks on the zombie
/// state (or a gone /proc entry) before `wait`, so an exited engine can never
/// hang the driver until the shell timeout. stdout/stderr go to bounded files
/// so page text can never flood the tool summary.
private let impeccableEngineDriver = """
run_engine() {
    label="$1"; shift
    mkdir -p synthetic
    start=$(date +%s%N)
    "$@" >"synthetic/$label.stdout" 2>"synthetic/$label.stderr" &
    pid=$!
    peak=""
    while [ -d "/proc/$pid" ]; do
        v=$(awk '/VmHWM/{print $2}' "/proc/$pid/status" 2>/dev/null)
        if [ -n "$v" ]; then peak=$v; fi
        state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)
        if [ "$state" = "Z" ] || [ -z "$state" ]; then break; fi
        sleep 0.02
    done
    wait "$pid"; rc=$?
    end=$(date +%s%N)
    echo "FLOE_ENGINE label=$label rc=$rc elapsed_ms=$(( (end - start) / 1000000 )) vmhwm_kb=${peak:-unavailable}"
    return 0
}
"""

extension SubagentSimulatorExecutionTests {

    /// Reads an engine result document the guest wrote into the workspace.
    fileprivate func impeccableReadResult(_ root: URL, _ relative: String) throws -> ImpeccableEngineResult {
        let data = try Data(contentsOf: root.appendingPathComponent(relative))
        return try JSONDecoder().decode(ImpeccableEngineResult.self, from: data)
    }

    struct ImpeccableEngineRunStats {
        let rc: Int
        let elapsedMS: Int
        let vmhwmKB: Int?
    }

    /// Strict marker parse. The driver emits exactly one line of the form
    /// `FLOE_ENGINE label=<label> rc=<digits> elapsed_ms=<digits>
    ///  vmhwm_kb=<digits|unavailable>`; a regex prefix match would accept
    /// junk like `vmhwm_kb=12a` as `12`, so this tokenizes the whole line
    /// instead. The shared `skillHubFirstMatch` returns the WHOLE match and
    /// is deliberately not used here. Malformed markers throw — they are
    /// never guessed, and `unavailable` RSS stays nil (never synthesized).
    func impeccableParseEngineStats(label: String, output: String) throws -> ImpeccableEngineRunStats {
        guard let line = output.split(separator: "\n")
            .first(where: { $0.hasPrefix("FLOE_ENGINE label=\(label) ") })
            .map(String.init) else {
            throw FloeError.validationFailed(
                "Missing FLOE_ENGINE marker for \(label): \(output.prefix(400))")
        }
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        func digits(_ token: Substring, _ prefix: String) throws -> Int {
            let value = token.dropFirst(prefix.count)
            guard token.hasPrefix(prefix), !value.isEmpty, value.allSatisfy({ $0.isNumber }),
                  let parsed = Int(value) else {
                throw FloeError.validationFailed("Malformed \(prefix) in engine marker: \(line)")
            }
            return parsed
        }
        guard tokens.count == 5, tokens[0] == "FLOE_ENGINE",
              tokens[1] == "label=\(label)" else {
            throw FloeError.validationFailed("Malformed engine marker shape: \(line)")
        }
        let rc = try digits(tokens[2], "rc=")
        let elapsedMS = try digits(tokens[3], "elapsed_ms=")
        guard tokens[4].hasPrefix("vmhwm_kb=") else {
            throw FloeError.validationFailed("Malformed RSS field in engine marker: \(line)")
        }
        let vmhwmToken = tokens[4].dropFirst("vmhwm_kb=".count)
        let vmhwmKB: Int?
        if vmhwmToken == "unavailable" {
            vmhwmKB = nil
        } else {
            vmhwmKB = try digits(tokens[4], "vmhwm_kb=")
        }
        return ImpeccableEngineRunStats(rc: rc, elapsedMS: elapsedMS, vmhwmKB: vmhwmKB)
    }

    /// Runs one driver-wrapped engine invocation and returns the recorded
    /// exit code, guest elapsed ms and sampled VmHWM kb (nil = unavailable).
    @discardableResult
    func impeccableEngineRun(
        runtime: FloeAgentRuntime,
        identity: ChildExecutionIdentity,
        context: ToolContext,
        tag: String,
        label: String,
        arguments: [String],
        timeout: Int = 600
    ) async throws -> (rc: Int, elapsedMS: Int?, vmhwmKB: Int?, stderrSummary: String) {
        let command = impeccableEngineDriver + "\nrun_engine \(label) " + arguments.joined(separator: " ")
        let result = try await skillHubShell(
            runtime: runtime, identity: identity, context: context,
            tag: tag, command: command, timeout: timeout)
        try #require(result.status == .ok, "Impeccable engine driver failed to run: \(result.outputSummary)")
        let stats = try impeccableParseEngineStats(label: label, output: result.outputSummary)
        let stderrText = (try? String(contentsOf: context.workspaceRootURL!
            .appendingPathComponent("synthetic/\(label).stderr"), encoding: .utf8)) ?? ""
        let summary = stderrText.split(separator: "\n")
            .first(where: { $0.contains("floe-impeccable: snapshot-scan status=") })
            .map(String.init) ?? ""
        return (stats.rc, stats.elapsedMS, stats.vmhwmKB, summary)
    }

    /// Background-job variant for the scaling sample: the same driver runs
    /// through the production job service (proven 600 s guest command cap, the
    /// pip/static precedent), so a genuine TinyEMU sizing overrun fails as an
    /// honest timeout result instead of a harness grace extension.
    @discardableResult
    func impeccableEngineRunJob(
        jobs: BackgroundJobService,
        runID: UUID,
        environmentID: String,
        root: URL,
        label: String,
        arguments: [String],
        jobIDs: inout [UUID]
    ) async throws -> (rc: Int, elapsedMS: Int?, vmhwmKB: Int?, stderrSummary: String) {
        let command = impeccableEngineDriver + "\nrun_engine \(label) " + arguments.joined(separator: " ")
        let id = try await skillHubSubmitShell(
            jobs: jobs, runID: runID, environmentID: environmentID, root: root,
            name: "impeccable-\(label)", command: command, timeout: 600)
        jobIDs.append(id)
        let job = try await skillHubWaitTerminal(jobs, id: id, seconds: 660)
        let output = job.resultSummary ?? job.lastError ?? job.state.rawValue
        try #require(job.state == .completed,
                     "Impeccable engine job \(label) did not complete: \(output)")
        let stats = try impeccableParseEngineStats(label: label, output: output)
        let stderrText = (try? String(contentsOf: root
            .appendingPathComponent("synthetic/\(label).stderr"), encoding: .utf8)) ?? ""
        let summary = stderrText.split(separator: "\n")
            .first(where: { $0.contains("floe-impeccable: snapshot-scan status=") })
            .map(String.init) ?? ""
        return (stats.rc, stats.elapsedMS, stats.vmhwmKB, summary)
    }

    /// A raw browser call for the design profile; returns the decoded JSON
    /// summary string (the design tool answers with a metadata receipt, not
    /// the semantic page shape, so the shared browser decoder does not apply).
    func impeccableDesignCall(
        runtime: FloeAgentRuntime,
        identity: ChildExecutionIdentity,
        context: ToolContext,
        tag: String,
        arguments: [String: Any]
    ) async throws -> String {
        let call = try toolCall(id: tag, toolName: "browser.observe",
                                arguments: try Self.json(arguments))
        let result = await runtime.dispatchChildTool(call, identity: identity, childContext: context)
        try #require(result.status == .ok, "browser.observe design failed: \(result.outputSummary)")
        return result.outputSummary
    }

    /// Deterministic test-owned synthetic page for the scaling sample: ~2,000
    /// sections (about 6,001 elements), well inside the 30,000-element capture
    /// budget. Authored by the harness, staged byte-exact, served by the
    /// unmodified shipped fixture server.
    func impeccableLargeFixtureHTML() -> Data {
        var html = """
        <!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
        <title>Impeccable large synthetic</title>
        <style>body{font-family:system-ui;margin:2rem}section{margin:.25rem 0}h2{font-size:15px}p{font-size:13px;color:#333}</style>
        </head><body><h1>Impeccable large synthetic page</h1>
        """
        for index in 0..<2_000 {
            html += """
            <section id="s\(index)"><h2>Section \(index) heading</h2><p>Body copy \(index): synthetic design-capture scaling fixture with benign readable text.</p></section>
            """
        }
        html += "</body></html>"
        return Data(html.utf8)
    }
}

extension SubagentSimulatorExecutionTests {

    // MARK: - Test: real guest engine proof + frozen synthetic golden contract

    /// Real TinyEMU guest qualification of the delivered Impeccable engine:
    /// byte-exact transport staging (guest re-hash of the engine, launcher,
    /// fixtures and goldens), chmod +x only after the guest re-hash, probe and
    /// contract digests, launcher probe, and the frozen synthetic golden
    /// matrix — round 1 exit 3 with exactly 169 requested points, overlay
    /// round 2 exit 2 with exactly one text-occlusion finding, and the v1
    /// never-clean invariant (exit 4, 0 findings, the six always-uncovered
    /// passes) verified live against shipped fixtures. Every nonzero engine
    /// exit is asserted as its semantic meaning, never flattened to a crash.
    @Test(
        "Impeccable engine guest qualification: staged riscv64 engine probe/contract and the frozen synthetic golden contract in the real Linux guest",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_IMPECCABLE_ENGINE_QUALIFICATION"] == "1")
    )
    func impeccableEngineGuestQualification() async throws {
        let zip = try ImpeccableInputs.requireTransportZip()
        let root = try makeWorkspaceRoot()
        var evidence: [String: String] = [
            "kind": "impeccable-engine-guest-not-model-not-ui",
            "transportZip": zip.path,
        ]
        var stagingManifest: [SkillHubStagedFile] = []
        try SkillHubStager.stageBytes(try Data(contentsOf: zip), to: root,
                                      path: "transport/impeccable.zip", into: &stagingManifest)
        var ownedEnvironmentID: String?
        var parentHold: CancellationToken?
        var ownedRuntime: FloeAgentRuntime?
        var parentTask: Task<Void, Error>?
        let app = try await appQualificationEnvironment()
        let conversationID = UUID()
        let runID = UUID()
        var recordsCreated = false
        let fixedIdentity = ChildExecutionIdentity(
            parentRunID: runID, rootTaskID: conversationID, delegateCallID: "impeccable-engine")
        func finish() async {
            await skillHubCleanup(runtime: ownedRuntime, parentHold: parentHold,
                                  parentTask: parentTask, jobs: nil, jobIDs: [],
                                  environmentID: ownedEnvironmentID, root: root,
                                  conversationID: recordsCreated ? conversationID : nil, app: app)
        }
        do {
            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID
            try await skillHubCreateRunRows(app: app, conversationID: conversationID, runID: runID,
                title: "Impeccable engine qualification",
                goal: "Real guest engine probe, contract and synthetic golden contract; no model")
            recordsCreated = true
            let ceiling: Set<String> = ["exec.shell"]
            let hold = CancellationToken()
            parentHold = hold
            let runtime = makeRuntime(
                root: root, conversationID: conversationID, runID: runID,
                allowedToolNames: ceiling, environmentID: environmentID,
                adapter: QualificationHoldingProviderAdapter(hold: hold))
            ownedRuntime = runtime
            parentTask = Task { try await runtime.start(goal: "Qualify the Impeccable engine in the real guest") }
            try #require(await waitForAsync(timeout: 20) {
                if case .streamingModel = await runtime.state { return true }
                return false
            }, "Parent must be active before engine child execution")
            let context = ToolContext(
                runID: runID, scope: .local, allowedToolNames: ceiling,
                workspaceRootURL: root, cancellation: CancellationToken(),
                environmentID: environmentID, conversationID: conversationID)
            try await requireQualifiedKernel(runtime: runtime, identity: fixedIdentity, context: context)
            evidence["guestKernel"] = "6.18.56"

            // 1. Guest-side unpack + re-hash of every pinned byte.
            let setup = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: context, tag: "engine-stage",
                command: """
                set -e
                PYTHONDONTWRITEBYTECODE=1 python3 -m zipfile -e transport/impeccable.zip transport/unpacked
                sha256sum transport/impeccable.zip
                sha256sum transport/unpacked/engine/floe-impeccable
                sha256sum transport/unpacked/launcher/floe-impeccable
                sha256sum transport/unpacked/contract/fixtures/snapshot-needs-hit-tests.v1.json
                sha256sum transport/unpacked/contract/fixtures/identity-needs.v1.json
                sha256sum transport/unpacked/adapter-test-data/facts-overlay-round2.v1.json
                sha256sum transport/unpacked/contract/fixtures/facts-hit-tests.v1.json
                sha256sum transport/unpacked/adapter-test-data/snapshot-no-findings.v1.json
                sha256sum transport/unpacked/adapter-test-data/identity-no-findings.v1.json
                sha256sum transport/unpacked/adapter-test-data/facts-no-findings-round2.v1.json
                sha256sum transport/unpacked/contract/expected/riscv64-docker/overlay-round1.result.v1.json
                sha256sum transport/unpacked/contract/expected/riscv64-docker/overlay-round2.result.v1.json
                sha256sum transport/unpacked/contract/expected/riscv64-docker/no-findings-round2.result.v1.json
                chmod +x transport/unpacked/engine/floe-impeccable transport/unpacked/launcher/floe-impeccable
                mkdir -p synthetic
                """, timeout: 300)
            try #require(setup.status == .ok, "Guest engine staging failed: \(setup.outputSummary)")
            for pin in [ImpeccableInputs.transportZipSHA256, ImpeccableInputs.engineSHA256,
                        ImpeccableInputs.launcherSHA256, ImpeccableInputs.fixtureSnapshotSHA256,
                        ImpeccableInputs.fixtureIdentitySHA256, ImpeccableInputs.fixtureOverlayFactsSHA256,
                        ImpeccableInputs.fixtureNoAnswerFactsSHA256,
                        ImpeccableInputs.fixtureNoFindingsSnapshotSHA256,
                        ImpeccableInputs.fixtureNoFindingsIdentitySHA256,
                        ImpeccableInputs.fixtureNoFindingsFactsSHA256,
                        ImpeccableInputs.goldenOverlayRound1SHA256,
                        ImpeccableInputs.goldenOverlayRound2SHA256, ImpeccableInputs.goldenNoFindingsSHA256] {
                try #require(setup.outputSummary.contains(pin),
                             "Guest re-hash missing pinned digest \(pin): \(setup.outputSummary)")
            }
            evidence["guestStage"] = String(setup.outputSummary.prefix(1_200))

            // 2. Engine executable proof: probe + version + contract digest.
            let probe = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: context, tag: "engine-probe",
                command: """
                transport/unpacked/engine/floe-impeccable engine-probe
                echo FLOE_PROBE_RC=$?
                transport/unpacked/engine/floe-impeccable --version
                transport/unpacked/engine/floe-impeccable contract | sha256sum
                """, timeout: 120)
            try #require(probe.status == .ok, "Engine probe failed to run: \(probe.outputSummary)")
            try #require(probe.outputSummary.contains(ImpeccableInputs.engineProbeLine),
                         "Engine probe stdout mismatch: \(probe.outputSummary)")
            try #require(probe.outputSummary.contains("FLOE_PROBE_RC=0"),
                         "Engine probe exit was not 0: \(probe.outputSummary)")
            try #require(probe.outputSummary.contains(ImpeccableInputs.contractSHA256),
                         "Engine contract digest mismatch: \(probe.outputSummary)")
            let launcherProbe = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: context, tag: "launcher-probe",
                command: """
                FLOE_IMPECCABLE_ENGINE=/workspace/transport/unpacked/engine/floe-impeccable \
                IMPECCABLE_SKILL_DIR=/workspace/transport/unpacked/raw-skill \
                sh transport/unpacked/launcher/floe-impeccable engine-probe
                echo FLOE_LAUNCHER_PROBE_RC=$?
                """, timeout: 120)
            try #require(launcherProbe.status == .ok
                            && launcherProbe.outputSummary.contains(ImpeccableInputs.engineProbeLine)
                            && launcherProbe.outputSummary.contains("FLOE_LAUNCHER_PROBE_RC=0"),
                         "Launcher probe failed in the guest: \(launcherProbe.outputSummary)")
            evidence["engineProof"] = "probe+version+contract+launcher exact"
            print("FLOE_IMPECCABLE_ENGINE_PROOF contract=\(ImpeccableInputs.contractSHA256.prefix(12))…")

            // 3. Synthetic golden round 1: MUST exit 3 needs-facts, 169 points.
            let round1 = try await impeccableEngineRun(
                runtime: runtime, identity: fixedIdentity, context: context, tag: "golden-round1",
                label: "golden-round1",
                arguments: ["transport/unpacked/engine/floe-impeccable", "snapshot-scan",
                            "--snapshot", "transport/unpacked/contract/fixtures/snapshot-needs-hit-tests.v1.json",
                            "--identity", "transport/unpacked/contract/fixtures/identity-needs.v1.json",
                            "--out", "synthetic/result.golden-round1.v1.json", "--round", "1"])
            try #require(round1.rc == 3, "Golden round 1 must exit 3 needs-facts, got rc=\(round1.rc): \(round1.stderrSummary)")
            let round1Doc = try impeccableReadResult(root, "synthetic/result.golden-round1.v1.json")
            try #require(round1Doc.status == "needs-facts", "Golden round 1 status: \(String(describing: round1Doc.status))")
            try #require(round1Doc.needs?.hitTests?.count == ImpeccableInputs.goldenNeedsPoints,
                         "Golden round 1 must ask exactly \(ImpeccableInputs.goldenNeedsPoints) points, got \(String(describing: round1Doc.needs?.hitTests?.count))")
            evidence["goldenRound1"] = "rc=3 needs=\(round1Doc.needs?.hitTests?.count ?? -1) elapsed_ms=\(round1.elapsedMS ?? -1) vmhwm_kb=\(round1.vmhwmKB ?? -1)"

            // 4. Synthetic golden round 2 (facts overlay): MUST exit 2 with
            //    exactly one text-occlusion finding.
            let round2 = try await impeccableEngineRun(
                runtime: runtime, identity: fixedIdentity, context: context, tag: "golden-round2",
                label: "golden-round2",
                arguments: ["transport/unpacked/engine/floe-impeccable", "snapshot-scan",
                            "--snapshot", "transport/unpacked/contract/fixtures/snapshot-needs-hit-tests.v1.json",
                            "--identity", "transport/unpacked/contract/fixtures/identity-needs.v1.json",
                            "--facts", "transport/unpacked/adapter-test-data/facts-overlay-round2.v1.json",
                            "--out", "synthetic/result.golden-round2.v1.json", "--round", "2"])
            try #require(round2.rc == 2, "Golden round 2 must exit 2 findings, got rc=\(round2.rc): \(round2.stderrSummary)")
            let round2Doc = try impeccableReadResult(root, "synthetic/result.golden-round2.v1.json")
            try #require(round2Doc.status == "complete" && round2Doc.verdict == "findings",
                         "Golden round 2 status/verdict: \(String(describing: round2Doc.status))/\(String(describing: round2Doc.verdict))")
            try #require(round2Doc.findings?.counts?.total == 1
                            && round2Doc.findings?.counts?.byRule?["text-occlusion"] == 1,
                         "Golden round 2 must report exactly one text-occlusion finding: \(String(describing: round2Doc.findings?.counts))")
            evidence["goldenRound2"] = "rc=2 findings=\(round2Doc.findings?.counts?.total ?? -1) elapsed_ms=\(round2.elapsedMS ?? -1) vmhwm_kb=\(round2.vmhwmKB ?? -1)"

            // 5. Cross-check the live results against the frozen goldens on the
            //    normalized fields (elapsedMs is normalized to 0 in the goldens
            //    and is never compared).
            let golden1 = try impeccableReadResult(root, "transport/unpacked/contract/expected/riscv64-docker/overlay-round1.result.v1.json")
            let golden2 = try impeccableReadResult(root, "transport/unpacked/contract/expected/riscv64-docker/overlay-round2.result.v1.json")
            try #require(golden1.status == "needs-facts"
                            && golden1.needs?.hitTests?.count == ImpeccableInputs.goldenNeedsPoints,
                         "Frozen overlay-round1 golden mismatch: \(String(describing: golden1.status))")
            try #require(golden2.verdict == "findings" && golden2.findings?.counts?.total == 1
                            && golden2.findings?.counts?.byRule?["text-occlusion"] == 1,
                         "Frozen overlay-round2 golden mismatch: \(String(describing: golden2.findings?.counts))")

            // 6. v1 never certifies clean: a fully answered no-findings fixture stays inconclusive.
            let noClean = try await impeccableEngineRun(
                runtime: runtime, identity: fixedIdentity, context: context, tag: "golden-noclean",
                label: "golden-noclean",
                arguments: ["transport/unpacked/engine/floe-impeccable", "snapshot-scan",
                            "--snapshot", "transport/unpacked/adapter-test-data/snapshot-no-findings.v1.json",
                            "--identity", "transport/unpacked/adapter-test-data/identity-no-findings.v1.json",
                            "--facts", "transport/unpacked/adapter-test-data/facts-no-findings-round2.v1.json",
                            "--out", "synthetic/result.golden-noclean.v1.json", "--round", "2"])
            try #require(noClean.rc == 4, "Never-clean run must exit 4 inconclusive, got rc=\(noClean.rc): \(noClean.stderrSummary)")
            let noCleanDoc = try impeccableReadResult(root, "synthetic/result.golden-noclean.v1.json")
            try #require(noCleanDoc.status == "inconclusive" && noCleanDoc.verdict == "inconclusive",
                         "Never-clean status/verdict: \(String(describing: noCleanDoc.status))/\(String(describing: noCleanDoc.verdict))")
            try #require(noCleanDoc.findings?.counts?.total == 0,
                         "Never-clean run must report zero findings: \(String(describing: noCleanDoc.findings?.counts))")
            let uncovered = Set(noCleanDoc.coverage?.uncoveredRequired ?? [])
            for required in ImpeccableInputs.alwaysUncoveredRequired {
                try #require(uncovered.contains(required),
                             "Never-clean run lost the always-uncovered pass \(required): \(uncovered)")
            }
            let frozenNoFindings = try impeccableReadResult(
                root, "transport/unpacked/contract/expected/riscv64-docker/no-findings-round2.result.v1.json")
            try #require(frozenNoFindings.verdict == "inconclusive"
                            && frozenNoFindings.findings?.counts?.total == 0
                            && Set(frozenNoFindings.coverage?.uncoveredRequired ?? [])
                                == Set(ImpeccableInputs.alwaysUncoveredRequired),
                         "Frozen no-findings golden does not record the v1 never-clean shape")
            evidence["neverClean"] = "rc=4 uncovered=\(uncovered.count) elapsed_ms=\(noClean.elapsedMS ?? -1)"

            print("FLOE_IMPECCABLE_ENGINE_QUALIFIED round1=exit3/169p round2=exit2/text-occlusion never-clean=exit4/\(uncovered.count)uncovered")
            await finish()
        } catch {
            evidence["failure"] = String(describing: error)
            skillHubFailureEvidence(evidence, root: root, label: "impeccable-engine")
            Issue.record("Impeccable engine guest qualification failed: \(error)")
            await finish()
        }
    }

    // MARK: - Test: real native WebKit capture loop + scaling sample

    /// End-to-end native design-capture loop on real WebKit pages served by
    /// the shipped fixture server: browser.observe profile=design capture ->
    /// real guest engine snapshot-scan (exit 3 Needs) -> native facts for
    /// exactly the requested hit-test points -> engine rerun (exit 2/4),
    /// identity echo and snapshot digest preserved, release removes the
    /// bridge files. A second ~6,000-element synthetic page exercises the
    /// 5k-30k band under the unchanged production budgets (4,096 hit
    /// tests/round, 16,384 total, 120 s engine budget): a budget-exceeded or
    /// timeout outcome is recorded explicitly as the real result, never
    /// widened into a pass. Guest elapsed ms plus /proc-sampled peak RSS are
    /// honest resource sampling — never a performance acceptance claim.
    @Test(
        "Impeccable native capture loop qualification: real WebKit design capture, guest engine Needs, native facts, rerun and scaling sample",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_IMPECCABLE_CAPTURE_QUALIFICATION"] == "1")
    )
    func impeccableNativeCaptureLoopQualification() async throws {
        let zip = try ImpeccableInputs.requireTransportZip()
        let sources = try SkillHubInputs.requireSourcesDir()
        let root = try makeWorkspaceRoot()
        var evidence: [String: String] = [
            "kind": "impeccable-native-capture-loop-not-model-not-ui",
            "transportZip": zip.path,
            "hubSources": sources.path,
        ]
        var stagingManifest: [SkillHubStagedFile] = []
        try SkillHubStager.stageBytes(try Data(contentsOf: zip), to: root,
                                      path: "transport/impeccable.zip", into: &stagingManifest)
        try SkillHubStager.stageBytes(impeccableLargeFixtureHTML(), to: root,
                                      path: "webapp-testing-src/assets/fixtures/site/impeccable-large.html",
                                      into: &stagingManifest)
        try SkillHubStager.stage(sources.appendingPathComponent("webapp-testing", isDirectory: true),
                                 to: root, relativePrefix: "webapp-testing-src", into: &stagingManifest)
        try SkillHubStager.writeManifest(stagingManifest, at: root)

        var ownedEnvironmentID: String?
        var parentHold: CancellationToken?
        var ownedRuntime: FloeAgentRuntime?
        var parentTask: Task<Void, Error>?
        var jobIDs: [UUID] = []
        var tabs: [UUID] = []
        var captureIDs: [UUID] = []
        var identity: ChildExecutionIdentity?
        var context: ToolContext?
        let app = try await appQualificationEnvironment()
        let conversationID = UUID()
        let runID = UUID()
        var recordsCreated = false
        let fixedIdentity = ChildExecutionIdentity(
            parentRunID: runID, rootTaskID: conversationID, delegateCallID: "impeccable-capture")
        identity = fixedIdentity
        func finish() async {
            // Release design captures and close tabs through the real tools
            // while the parent runtime is still alive, then the standard
            // ordered teardown (jobs settle before the owned guest is stopped).
            if let runtime = ownedRuntime, let context {
                for captureID in captureIDs {
                    guard let release = try? toolCall(
                        id: "release-" + captureID.uuidString, toolName: "browser.observe",
                        arguments: try! Self.json([
                            "profile": "design", "designAction": "release",
                            "captureID": captureID.uuidString])) else { continue }
                    _ = await runtime.dispatchChildTool(release, identity: fixedIdentity,
                                                        childContext: context)
                }
            }
            await skillHubCloseBrowserTabs(runtime: ownedRuntime, identity: identity,
                                           context: context, tabs: tabs)
            await skillHubCleanup(runtime: ownedRuntime, parentHold: parentHold,
                                  parentTask: parentTask, jobs: app.backgroundJobService,
                                  jobIDs: jobIDs, environmentID: ownedEnvironmentID, root: root,
                                  conversationID: recordsCreated ? conversationID : nil, app: app)
        }
        do {
            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID
            try await skillHubCreateRunRows(app: app, conversationID: conversationID, runID: runID,
                title: "Impeccable native capture qualification",
                goal: "Real WebKit design capture loop with the guest engine; no model")
            recordsCreated = true
            let jobs = try #require(app.backgroundJobService, "Production job service is unavailable")
            let ceiling: Set<String> = [
                "exec.shell", "browser.tab", "browser.tabs", "browser.navigate",
                "browser.wait", "browser.observe",
            ]
            let hold = CancellationToken()
            parentHold = hold
            let runtime = makeRuntime(
                root: root, conversationID: conversationID, runID: runID,
                allowedToolNames: ceiling, environmentID: environmentID,
                adapter: QualificationHoldingProviderAdapter(hold: hold))
            ownedRuntime = runtime
            parentTask = Task { try await runtime.start(goal: "Qualify the Impeccable native capture loop") }
            try #require(await waitForAsync(timeout: 20) {
                if case .streamingModel = await runtime.state { return true }
                return false
            }, "Parent must be active before capture-loop child execution")
            let childContext = ToolContext(
                runID: runID, scope: .local, allowedToolNames: ceiling,
                workspaceRootURL: root, cancellation: CancellationToken(),
                environmentID: environmentID, conversationID: conversationID)
            context = childContext
            try await requireQualifiedKernel(runtime: runtime, identity: fixedIdentity, context: childContext)

            // Byte-exact staging proof (guest re-hash) + fixture server build.
            let stageResult = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "capture-stage-verify",
                command: "PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'\n" + skillHubStageVerifyScript
                    + "\nPY", timeout: 120)
            try #require(stageResult.status == .ok && stageResult.outputSummary.contains("bad=0"),
                         "Guest staging verification failed: \(stageResult.outputSummary)")
            let engineSetup = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "capture-engine-stage",
                command: """
                set -e
                PYTHONDONTWRITEBYTECODE=1 python3 -m zipfile -e transport/impeccable.zip transport/unpacked
                sha256sum transport/unpacked/engine/floe-impeccable
                chmod +x transport/unpacked/engine/floe-impeccable
                transport/unpacked/engine/floe-impeccable engine-probe
                transport/unpacked/engine/floe-impeccable contract | sha256sum
                mkdir -p synthetic
                """, timeout: 300)
            try #require(engineSetup.status == .ok
                            && engineSetup.outputSummary.contains(ImpeccableInputs.engineSHA256)
                            && engineSetup.outputSummary.contains(ImpeccableInputs.engineProbeLine)
                            && engineSetup.outputSummary.contains(ImpeccableInputs.contractSHA256),
                         "Guest engine staging/probe failed: \(engineSetup.outputSummary)")
            evidence["engineProof"] = "staged probe+contract exact in this guest"

            let port = Int.random(in: 20_000...45_000)
            let invocation = LocalServiceTool.Arguments(runtime: "python",
                entry: "webapp-testing-src/scripts/fixture_server.py", arguments: [], cwd: nil, port: port)
            let serviceJob = try await jobs.submit(
                runID: runID, toolCallID: "impeccable-fixture-server-" + UUID().uuidString,
                targetTool: "exec.localService", payloadJSON: JSONEncoder().encode(invocation),
                scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [],
                environmentID: environmentID, submissionSource: .nativeService, waitForCompletion: false)
            jobIDs.append(serviceJob.id)
            evidence["serviceJobID"] = serviceJob.id.uuidString
            var progressSamples: [[String: String]] = []
            let preview = try await skillHubWaitPreview(jobs, id: serviceJob.id,
                                                        samples: &progressSamples, timeout: 180)
            try #require(preview.host == "127.0.0.1" && preview.port == port,
                         "PreviewURL must be the owned loopback endpoint, got \(preview)")
            for sample in progressSamples {
                try #require(!(sample["previewURL"]?.isEmpty == false && sample["state"] != "running"),
                             "previewURL appeared before the running state: \(sample)")
            }

            // One closure over the whole capture -> scan -> facts -> rerun loop.
            func runCaptureLoop(tag: String, path: String, marker: String, large: Bool) async throws -> [String: String] {
                var loopEvidence: [String: String] = [:]
                let created = try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                    context: childContext, tag: "\(tag)-create", tool: "browser.tab",
                    arguments: ["action": "create"])
                let tabID = try #require(created.page?.tabs.first(where: { $0.isActive })?.id,
                                         "tab create returned no active tab")
                tabs.append(tabID)
                try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                    context: childContext, tag: "\(tag)-navigate", tool: "browser.navigate",
                    arguments: ["url": preview.absoluteString + path, "tabID": tabID.uuidString])
                try await skillHubBrowserCall(runtime: runtime, identity: fixedIdentity,
                    context: childContext, tag: "\(tag)-load", tool: "browser.wait",
                    arguments: ["tabID": tabID.uuidString, "condition": "load",
                                "timeoutMilliseconds": 15_000])
                _ = try await skillHubWaitText(runtime: runtime, identity: fixedIdentity,
                                               context: childContext, tag: "\(tag)-settle",
                                               tabID: tabID, marker: marker)

                // Native design capture: metadata receipt only, task-owned root.
                let captureSummary = try await impeccableDesignCall(
                    runtime: runtime, identity: fixedIdentity, context: childContext,
                    tag: "\(tag)-capture",
                    arguments: ["profile": "design", "tabID": tabID.uuidString])
                let captureData = try #require(captureSummary.data(using: .utf8),
                                               "Capture response was not UTF-8")
                let capture = try JSONDecoder().decode(ImpeccableDesignCaptureResponse.self,
                                                       from: captureData)
                try #require(capture.profile == "design" && capture.state == "captured",
                             "Capture response state mismatch: \(captureSummary.prefix(300))")
                try #require(capture.capture.bridgeRootIsTaskWorkspace,
                             "Capture must belong to this task workspace")
                let captureID = try #require(UUID(uuidString: capture.capture.captureId),
                                             "Capture id is not a UUID: \(capture.capture.captureId)")
                captureIDs.append(captureID)
                loopEvidence["captureId"] = captureID.uuidString
                loopEvidence["elementCount"] = String(capture.capture.elementCount)
                loopEvidence["snapshotBytes"] = String(capture.capture.snapshotBytes)
                loopEvidence["scriptDigest"] = capture.capture.scriptDigest
                if large {
                    try #require(capture.capture.elementCount >= 5_000,
                                 "Large fixture must really exceed 5,000 elements, got \(capture.capture.elementCount)")
                    try #require(capture.capture.elementCount <= 30_000,
                                 "Large fixture exceeds the 30,000-element capture budget: \(capture.capture.elementCount)")
                }

                // Snapshot digest preserved across the whole loop.
                let snapshotURL = root.appendingPathComponent(capture.capture.relativeSnapshotFile)
                let snapshotBytes = try Data(contentsOf: snapshotURL)
                let snapshotSHA = FloeDigest.sha256Hex(snapshotBytes)
                loopEvidence["snapshotSHA256"] = snapshotSHA
                try #require(snapshotBytes.count == capture.capture.snapshotBytes,
                             "Snapshot bytes differ from the native receipt")

                // Engine round 1: Needs on exactly the staged identity.
                let identityFile = capture.capture.relativeIdentityFile
                let relPrefix = "Impeccable/\(conversationID.uuidString)/\(captureID.uuidString)"
                // Production budgets only (4,096 hit tests/round, 16,384 total,
                // 120 s engine budget, 48 MiB snapshot): the scaling sample must
                // prove the actual App loop, not a relaxed one.
                let round1Arguments = ["transport/unpacked/engine/floe-impeccable", "snapshot-scan",
                                       "--snapshot", capture.capture.relativeSnapshotFile,
                                       "--identity", identityFile,
                                       "--out", "\(relPrefix)/result.round1.v1.json", "--round", "1"]
                let round1: (rc: Int, elapsedMS: Int?, vmhwmKB: Int?, stderrSummary: String)
                if large {
                    round1 = try await impeccableEngineRunJob(
                        jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                        label: "\(tag)-round1", arguments: round1Arguments, jobIDs: &jobIDs)
                } else {
                    round1 = try await impeccableEngineRun(
                        runtime: runtime, identity: fixedIdentity, context: childContext,
                        tag: "\(tag)-round1", label: "\(tag)-round1",
                        arguments: round1Arguments, timeout: 300)
                }
                let round1Doc = try impeccableReadResult(root, "\(relPrefix)/result.round1.v1.json")
                if large && round1.rc == 1 {
                    // Production-budget honesty: with the native 4,096 hit-test
                    // allowance and the 120 s engine budget unchanged, a large
                    // page may legitimately end as budget-exceeded/timeout.
                    // That is recorded as the real outcome — never widened,
                    // never skipped silently, and never a fabricated pass.
                    let code = round1Doc.error?.code
                    try #require(code == "budget-exceeded" || code == "timeout",
                                 "\(tag) round 1 failed unexpectedly: rc=1 code=\(code ?? "?"): \(round1.stderrSummary)")
                    loopEvidence["budgetLimited"] = "true"
                    loopEvidence["budgetCode"] = code ?? "unknown"
                    loopEvidence["round1ElapsedMS"] = String(round1.elapsedMS ?? -1)
                    loopEvidence["round1VmHWMKB"] = String(round1.vmhwmKB ?? -1)
                    loopEvidence["round1Summary"] = round1.stderrSummary
                    return loopEvidence
                }
                try #require(round1.rc == 3,
                             "\(tag) round 1 must exit 3 needs-facts, got rc=\(round1.rc): \(round1.stderrSummary)")
                let needsCount = try #require(round1Doc.needs?.hitTests?.count,
                                              "\(tag) round 1 asked no hit tests")
                try #require(round1Doc.identity?.captureId == captureID.uuidString,
                             "Round 1 identity must echo this captureId")
                if large {
                    // Production guard: the engine must not hand out more
                    // points than the native allowance it ran under.
                    try #require(needsCount <= 4_096,
                                 "\(tag) round 1 exceeded the 4,096 hit-test allowance without a budget failure: \(needsCount)")
                }
                loopEvidence["round1Needs"] = String(needsCount)
                loopEvidence["round1ElapsedMS"] = String(round1.elapsedMS ?? -1)
                loopEvidence["round1VmHWMKB"] = String(round1.vmhwmKB ?? -1)
                loopEvidence["round1Summary"] = round1.stderrSummary

                // Native facts for exactly the requested points.
                let factsSummary = try await impeccableDesignCall(
                    runtime: runtime, identity: fixedIdentity, context: childContext,
                    tag: "\(tag)-facts",
                    arguments: ["profile": "design", "designAction": "facts",
                                "captureID": captureID.uuidString,
                                "needsFile": "\(relPrefix)/result.round1.v1.json"])
                let factsData = try #require(factsSummary.data(using: .utf8))
                let facts = try JSONDecoder().decode(ImpeccableDesignFactsResponse.self, from: factsData)
                try #require(facts.state == "factsReady" && facts.captureID == captureID.uuidString,
                             "Facts response mismatch: \(factsSummary.prefix(300))")
                let factsURL = root.appendingPathComponent(facts.relativeFactsFile)
                let factsJSON = try Data(contentsOf: factsURL)
                let factsObject = try JSONSerialization.jsonObject(with: factsJSON) as? [String: Any]
                let factHits = factsObject?["hits"] as? [[String: Any]] ?? []
                try #require(factHits.count == needsCount,
                             "Native facts answered \(factHits.count) points, engine asked \(needsCount)")
                try #require((factsObject?["captureId"] as? String) == captureID.uuidString,
                             "Facts binding captureId must echo this capture")
                loopEvidence["factsSHA256"] = FloeDigest.sha256Hex(factsJSON)
                loopEvidence["factsHits"] = String(factHits.count)

                // Engine rerun with the native facts: semantic nonzero result.
                let round2Arguments = ["transport/unpacked/engine/floe-impeccable", "snapshot-scan",
                                       "--snapshot", capture.capture.relativeSnapshotFile,
                                       "--identity", identityFile,
                                       "--facts", facts.relativeFactsFile,
                                       "--out", "\(relPrefix)/result.round2.v1.json", "--round", "2"]
                let round2: (rc: Int, elapsedMS: Int?, vmhwmKB: Int?, stderrSummary: String)
                if large {
                    round2 = try await impeccableEngineRunJob(
                        jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                        label: "\(tag)-round2", arguments: round2Arguments, jobIDs: &jobIDs)
                } else {
                    round2 = try await impeccableEngineRun(
                        runtime: runtime, identity: fixedIdentity, context: childContext,
                        tag: "\(tag)-round2", label: "\(tag)-round2",
                        arguments: round2Arguments, timeout: 300)
                }
                try #require(round2.rc == 2 || round2.rc == 4,
                             "\(tag) rerun must exit 2 findings or 4 inconclusive, got rc=\(round2.rc): \(round2.stderrSummary)")
                let round2Doc = try impeccableReadResult(root, "\(relPrefix)/result.round2.v1.json")
                try #require(round2Doc.verdict == "findings" || round2Doc.verdict == "inconclusive",
                             "\(tag) rerun verdict must stay semantic: \(String(describing: round2Doc.verdict))")
                try #require(round2Doc.verdict != "clean" && round2.rc != 0,
                             "v1 must never certify clean")
                try #require(round2Doc.identity?.captureId == captureID.uuidString,
                             "Rerun identity must echo this captureId")
                // The snapshot digest is preserved end to end.
                let snapshotAfter = try FloeDigest.sha256Hex(Data(contentsOf: snapshotURL))
                try #require(snapshotAfter == snapshotSHA,
                             "Snapshot bytes changed during the capture loop")
                loopEvidence["round2RC"] = String(round2.rc)
                loopEvidence["round2Verdict"] = round2Doc.verdict ?? "missing"
                loopEvidence["round2Findings"] = String(round2Doc.findings?.counts?.total ?? 0)
                loopEvidence["round2ElapsedMS"] = String(round2.elapsedMS ?? -1)
                loopEvidence["round2VmHWMKB"] = String(round2.vmhwmKB ?? -1)
                loopEvidence["round2Summary"] = round2.stderrSummary
                let round2Data = try Data(contentsOf: root.appendingPathComponent("\(relPrefix)/result.round2.v1.json"))
                loopEvidence["round2SHA256"] = FloeDigest.sha256Hex(round2Data)
                return loopEvidence
            }

            // Small real page: the fixture index (form, text, delayed region).
            let smallLoop = try await runCaptureLoop(
                tag: "small", path: "", marker: "ASYNC-READY-77", large: false)
            for (key, value) in smallLoop { evidence["small.\(key)"] = value }
            print("FLOE_IMPECCABLE_CAPTURE_SMALL capture=\(smallLoop["captureId"] ?? "?") elements=\(smallLoop["elementCount"] ?? "?") needs=\(smallLoop["round1Needs"] ?? "?") round2=\(smallLoop["round2RC"] ?? "?")/\(smallLoop["round2Verdict"] ?? "?")")

            // Larger 5k-30k band sample under unchanged production budgets.
            let largeLoop = try await runCaptureLoop(
                tag: "large", path: "impeccable-large.html",
                marker: "Impeccable large synthetic page", large: true)
            for (key, value) in largeLoop { evidence["large.\(key)"] = value }
            if largeLoop["budgetLimited"] == "true" {
                print("FLOE_IMPECCABLE_CAPTURE_LARGE_BUDGET_LIMITED capture=\(largeLoop["captureId"] ?? "?") elements=\(largeLoop["elementCount"] ?? "?") snapshotBytes=\(largeLoop["snapshotBytes"] ?? "?") code=\(largeLoop["budgetCode"] ?? "?") round1_ms=\(largeLoop["round1ElapsedMS"] ?? "?")")
            } else {
                print("FLOE_IMPECCABLE_CAPTURE_LARGE capture=\(largeLoop["captureId"] ?? "?") elements=\(largeLoop["elementCount"] ?? "?") snapshotBytes=\(largeLoop["snapshotBytes"] ?? "?") needs=\(largeLoop["round1Needs"] ?? "?") round1_ms=\(largeLoop["round1ElapsedMS"] ?? "?") round1_vmhwm_kb=\(largeLoop["round1VmHWMKB"] ?? "?") round2=\(largeLoop["round2RC"] ?? "?")/\(largeLoop["round2Verdict"] ?? "?")")
            }

            // Release both captures through the real tool and verify removal.
            for captureID in captureIDs {
                let releaseSummary = try await impeccableDesignCall(
                    runtime: runtime, identity: fixedIdentity, context: childContext,
                    tag: "release-\(captureID.uuidString)",
                    arguments: ["profile": "design", "designAction": "release",
                                "captureID": captureID.uuidString])
                try #require(releaseSummary.contains("Design capture released"),
                             "Release did not confirm: \(releaseSummary.prefix(300))")
                let directory = root.appendingPathComponent(
                    "Impeccable/\(conversationID.uuidString)/\(captureID.uuidString)")
                try #require(!FileManager.default.fileExists(atPath: directory.path),
                             "Release left capture files behind: \(directory.path)")
            }
            captureIDs.removeAll()
            evidence["release"] = "both captures released, bridge files removed"
            print("FLOE_IMPECCABLE_CAPTURE_QUALIFIED small=\(smallLoop["round2Verdict"] ?? "?") large=\(largeLoop["round2Verdict"] ?? (largeLoop["budgetCode"].map { "budget-limited:\($0)" } ?? "?")) large_round1_ms=\(largeLoop["round1ElapsedMS"] ?? "?")")
            await finish()
        } catch {
            evidence["failure"] = String(describing: error)
            skillHubFailureEvidence(evidence, root: root, label: "impeccable-capture")
            Issue.record("Impeccable native capture loop qualification failed: \(error)")
            await finish()
        }
    }
}


// ============================================================================
// ==== Seven deep-skill guest qualification (job-5eb16a3dab9b4702) ==========
// ============================================================================
// Skill Hub seven-deep guest qualification - PRIVATE PROPOSAL.
//
// Append-only content for FloeAgent/Tests/FloeAppTests/SubagentSimulatorExecutionTests.swift,
// rebased onto the current full file at 8210968f (Main's applied guest-harness
// repairs: launched-App-graph bootGuest, Python/MCP sameApp, 127.0.0.1 guest
// loopback, chmod-before-probe, no-findings fixtures, new Impeccable transport
// pin). This block preserves every existing helper, transport pin and test
// above; it touches nothing. Real App-host qualification of the seven READY
// deep-adaptation packages in the frozen qualification transport (hub
// sourceCommit 6014c06882201c61a99219745b5a9c0a0fedb8c9):
// exploratory-data-analysis, statistical-analysis, scientific-visualization,
// markitdown and literature-review (H4 data five), canvas-design and
// algorithmic-art (H5 visual two). The five existing guest tests above (wheel
// transport + sympy/citation, webapp-testing 14 cases, MCP node-http,
// Impeccable engine, Impeccable native capture loop) are intentionally NOT
// duplicated here.
//
// Opt-in, fail-closed (a plain disabled run is reported as disabled, never a
// pass - the existing real-guest policy in this file):
//   * FLOE_SKILLHUB_DATAFIVE_GUEST_QUALIFICATION=1 + FLOE_SKILLHUB_SEVEN_TRANSPORT_ZIP
//   * FLOE_SKILLHUB_CANVAS_GUEST_QUALIFICATION=1     + FLOE_SKILLHUB_SEVEN_TRANSPORT_ZIP
//   * FLOE_SKILLHUB_ART_GUEST_QUALIFICATION=1        + FLOE_SKILLHUB_SEVEN_TRANSPORT_ZIP
//
// Single shared App graph: these tests reuse the corrected bootGuest(root:)
// and appQualificationEnvironment(); they never call AppEnvironment.live()
// and never re-bootstrap shared bindings. Everything executes through the
// REAL production chain already used above: bootGuest -> makeRuntime ->
// active parent -> requireQualifiedKernel (6.18.56) -> dispatchChildTool
// (exec.shell / document.convert / document.pdf.convert / browser.*), the
// production BackgroundJobService.submit for exec.localService static
// serving, and the proven signed-guest apt provisioning pattern from
// LocalLinuxStaticServiceRealVMTests. No host interpreter, no chat-time
// pip/uv/npm, no fake guest, no model inference, no new tool or environment
// subsystem, no p5.js parity claim, no riscv64 Chromium/Playwright.
// ============================================================================
// MARK: - Seven deep pinned transport + native fixtures (file scope, private)

/// Guest-side (stdlib-only) artifact-truth audit for the self-contained
/// canvas-design poster HTML, executed INSIDE the Linux guest: the embedded
/// @font-face base64 payloads must hash-equal the coverage registry, the OFL
/// notices and the declared-size export control must be present, and no
/// resource-bearing field may reference an external URL (license URLs are
/// inert disclosure text only).
private let sevenDeepPosterTruthScript = """
import base64, hashlib, json, re
from pathlib import Path
html = Path('poster-out/hero.html').read_text(encoding='utf-8')
cov = json.loads(Path('poster-out/hero.coverage.json').read_text(encoding='utf-8'))
expected = sorted(f['sha256'] for f in cov['fontsUsed'])
faces = re.search(r'<style id="faces"[^>]*>(.*?)</style>', html, re.S)
assert faces, 'id="faces" style block missing'
payloads = re.findall(r'url\\(data:font/ttf;base64,([A-Za-z0-9+/=]+)\\)', faces.group(1))
assert payloads, 'no embedded @font-face payloads found'
actual = sorted(hashlib.sha256(base64.b64decode(p)).hexdigest() for p in payloads)
assert actual == expected, 'embedded font hashes != coverage registry'
assert '<details class="notices">' in html, 'license notices disclosure missing'
assert 'id="export-png"' in html and 'Export PNG 3508×4961' in html, 'declared-size export control missing'
assert 'artifact-notices' in html, 'artifact notices JSON missing'
for bad in ('src="http', "src='http", 'url(http', '<script src', '<link '):
    assert bad not in html, 'external resource field present: ' + bad
print('ARTIFACT_TRUTH_OK fonts=%d' % len(actual))
"""

/// Pinned qualification-transport identity for all seven packages.
private enum SevenDeepInputs {
    static let transportZipSHA256 =
        "acc468eb493d10f8916b3d272b295e8964538f238bae25f440a14dce8ba004df"
    static let transportZipBytes = 1_558_241
    static let sourceCommit = "6014c06882201c61a99219745b5a9c0a0fedb8c9"

    /// Inner package pins from the transport SOURCE-MANIFEST (id -> sha256).
    static let packageSHA256: [String: String] = [
        "exploratory-data-analysis":
            "fce043d8b3157a868e4018be9b8f0ebbe79f12d8a3a624d2567f69dd250a8768",
        "statistical-analysis":
            "523456f5cd40b3d80629b49b404acdf455462951eb3c37df177372c018d8ebf4",
        "scientific-visualization":
            "eade5f2230682cb9fb528f0d12b77fbe5892b1ab960f3cfce31515ffb5622e90",
        "markitdown":
            "bd95560d5590d92b105fb07136b775923c4f25245b9d1ae3556cfdbbaab1db1b",
        "literature-review":
            "230b64a8b411dc34820557c79ad98dcb5114a2c39db16340c47fd72554925054",
        "canvas-design":
            "0b52ea004b75d8ba7575c54307dac5b76122d2ad2be7d710a61ff4fc2f55153d",
        "algorithmic-art":
            "0db4c668d6adb238a3f38789af14066dc4c447e5957a17dd254bc3d3a3dc346a",
    ]

    /// Runbook-pinned signed guest apt identities for the H4 data five.
    static let dataFiveAptPackages = [
        "python3-numpy", "python3-pandas", "python3-scipy", "python3-statsmodels",
        "python3-matplotlib", "python3-pil", "python3-pypdf", "python3-openpyxl",
        "python3-pdfminer", "fonts-noto-cjk",
    ]

    static func requireTransportZip() throws -> URL {
        let path = ProcessInfo.processInfo.environment["FLOE_SKILLHUB_SEVEN_TRANSPORT_ZIP"] ?? ""
        guard !path.isEmpty else {
            throw FloeError.validationFailed(
                "Seven-deep qualification requires FLOE_SKILLHUB_SEVEN_TRANSPORT_ZIP")
        }
        let url = URL(fileURLWithPath: path)
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, values.fileSize == transportZipBytes else {
            throw FloeError.validationFailed(
                "Seven-deep transport zip size is \(String(describing: values.fileSize)), expected \(transportZipBytes)")
        }
        let digest = FloeDigest.sha256Hex(try Data(contentsOf: url))
        guard digest == transportZipSHA256 else {
            throw FloeError.validationFailed("Seven-deep transport zip sha256 mismatch: \(digest)")
        }
        return url
    }
}

/// Synthetic first-party native acceptance fixtures for the markitdown
/// package (provenance + digests:
/// skill-hub-20261026/data-five/evidence/native-fixtures/README.md; embedded
/// here so the test stays hermetic). sample.docx and sample_native.pdf carry
/// extractable markers; scanned_stub.pdf has NO text operations and must be
/// refused by document.pdf.convert with the OCR-required message.
private enum MarkitdownNativeFixtures {
    static let sampleDocxSHA256 =
        "8bdeabe8d9fcd78be3b7c4cf5726a4699d7f571f64fa925e1a38fb70282c78d5"
    static let sampleDocxBase64 =
        "UEsDBBQAAAAIAGM8Wl0XmADX6wAAALIBAAATAAAAW0NvbnRlbnRfVHlwZXNdLnhtbH1QyU4DMQy98xWRr2gmAweEUKc9sByBQ/kAK/HMRM2mOC3t3+NpoQdUONpvs99itQ9e7aiwS7GHm7YDRdEk6+LYw8f6pbkHxRWjRZ8i9XAghtXyarE+ZGIl4sg9TLXmB63ZTBSQ25QpCjKkErDKWEad0WxwJH3bdXfapFgp1qbOHiBmTzTg1lf1vJf96ZJCnkE9nphzWA+Ys3cGq+B6F+2vmOY7ohXlkcOTy3wtBNCXI2bo74Qf4ZuUU5wl9Y6lvmIQmv5MxWqbzDaItP3f58KlaRicobN+dsslGWKW1oNvz0hAF88f6GPlyy9QSwMEFAAAAAgAYzxaXT+t/vqvAAAALAEAAAsAAABfcmVscy8ucmVsc43POw7CMAwA0J1TRN5pWgaEUEMXhNQVlQNEiZtWNB/F4dPbk4EBKgZG/57tunnaid0x0uidgKoogaFTXo/OCLh0p/UOGCXptJy8QwEzEjSHVX3GSaY8Q8MYiGXEkYAhpbDnnNSAVlLhA7pc6X20MuUwGh6kukqDfFOWWx4/DVigrNUCYqsrYN0c8B/c9/2o8OjVzaJLP3YsOrIso8Ek4OGj5vqdLjILPJ/Dv548vABQSwMEFAAAAAgAYzxaXUXD3yA4AQAAtQEAABEAAAB3b3JkL2RvY3VtZW50LnhtbIWQvU7DMBSFd57C8gQDdcsAKGrSBVUsSEjAAxjnto2If2S7SbshJMSCgKFiYClDJwRs/Ent00BCmXgFnNDCgsRi+8r3fOfeU2/0eIwS0CaSwse1ShUjEEyGkWj7eG+3ubyOkbFUhDSWAnzcB4MbwUI99ULJuhyERY4gjJf6uGOt8ggxrAOcmopUINxfS2pOrSt1m6RSh0pLBsY4Ax6TlWp1lXAaCRw45L4M+yVbFZXa1uW1Y/sxoNRLaOzjTaDFbDVMgjr56SkPGzRjCUhQGyWAKGOg3OAMUCvq2a6Got+WKv2t/bWa6TfmKzEpZpkgQ7ly9gYSEGhxbanyP+bt+S6/PMnvH6YXk8/xVX49zsbn08kt2qL6IJSpQNnZ8H0w/Lg5zQeP2eglO356PTz6C0xmoRSPeeDBF1BLAQIUAxQAAAAIAGM8Wl0XmADX6wAAALIBAAATAAAAAAAAAAAAAACAAQAAAABbQ29udGVudF9UeXBlc10ueG1sUEsBAhQDFAAAAAgAYzxaXT+t/vqvAAAALAEAAAsAAAAAAAAAAAAAAIABHAEAAF9yZWxzLy5yZWxzUEsBAhQDFAAAAAgAYzxaXUXD3yA4AQAAtQEAABEAAAAAAAAAAAAAAIAB9AEAAHdvcmQvZG9jdW1lbnQueG1sUEsFBgAAAAADAAMAuQAAAFsDAAAAAA=="

    static let sampleNativePDFSHA256 =
        "fd1aa5a62931f917bd0aca91e5b096e9a65a403b8792edb752f3d46bcac3e553"
    static let sampleNativePDFBase64 =
        "JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvQ29udGVudHMgNCAwIFIgL1Jlc291cmNlcyA8PCAvRm9udCA8PCAvRjEgNSAwIFIgPj4gPj4gPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCA5NSA+PgpzdHJlYW0KQlQKL0YxIDE4IFRmCjcyIDcyMCBUZAoyMCBUTAooRmxvZSBuYXRpdmUgYWNjZXB0YW5jZSBmaXh0dXJlIDcpIFRqCihleHRyYWN0YWJsZSB0ZXh0IHBhZ2UpICcKRVQKZW5kc3RyZWFtCmVuZG9iago1IDAgb2JqCjw8IC9UeXBlIC9Gb250IC9TdWJ0eXBlIC9UeXBlMSAvQmFzZUZvbnQgL0hlbHZldGljYSA+PgplbmRvYmoKeHJlZgowIDYKMDAwMDAwMDAwMCA2NTUzNSBmIAowMDAwMDAwMDA5IDAwMDAwIG4gCjAwMDAwMDAwNTggMDAwMDAgbiAKMDAwMDAwMDExNSAwMDAwMCBuIAowMDAwMDAwMjQxIDAwMDAwIG4gCjAwMDAwMDAzODYgMDAwMDAgbiAKdHJhaWxlcgo8PCAvU2l6ZSA2IC9Sb290IDEgMCBSID4+CnN0YXJ0eHJlZgo0NTYKJSVFT0YK"

    static let scannedStubPDFSHA256 =
        "49567e9841ba9fa48a127403b4264d1eb7a45b7e14bed61cd5490e5002560ba2"
    static let scannedStubPDFBase64 =
        "JVBERi0xLjQKMSAwIG9iago8PCAvVHlwZSAvQ2F0YWxvZyAvUGFnZXMgMiAwIFIgPj4KZW5kb2JqCjIgMCBvYmoKPDwgL1R5cGUgL1BhZ2VzIC9LaWRzIFszIDAgUl0gL0NvdW50IDEgPj4KZW5kb2JqCjMgMCBvYmoKPDwgL1R5cGUgL1BhZ2UgL1BhcmVudCAyIDAgUiAvTWVkaWFCb3ggWzAgMCA2MTIgNzkyXSAvQ29udGVudHMgNCAwIFIgL1Jlc291cmNlcyA8PCAvRm9udCA8PCAvRjEgNSAwIFIgPj4gPj4gPj4KZW5kb2JqCjQgMCBvYmoKPDwgL0xlbmd0aCAzMSA+PgpzdHJlYW0KQlQKL0YxIDE4IFRmCjcyIDcyMCBUZAoyMCBUTApFVAplbmRzdHJlYW0KZW5kb2JqCjUgMCBvYmoKPDwgL1R5cGUgL0ZvbnQgL1N1YnR5cGUgL1R5cGUxIC9CYXNlRm9udCAvSGVsdmV0aWNhID4+CmVuZG9iagp4cmVmCjAgNgowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwMDkgMDAwMDAgbiAKMDAwMDAwMDA1OCAwMDAwMCBuIAowMDAwMDAwMTE1IDAwMDAwIG4gCjAwMDAwMDAyNDEgMDAwMDAgbiAKMDAwMDAwMDMyMiAwMDAwMCBuIAp0cmFpbGVyCjw8IC9TaXplIDYgL1Jvb3QgMSAwIFIgPj4Kc3RhcnR4cmVmCjM5MgolJUVPRgo="

    static func stageAll(to root: URL, into manifest: inout [SkillHubStagedFile]) throws {
        try stage(base64: sampleDocxBase64, sha256: sampleDocxSHA256,
                  to: root, path: "native-fixtures/sample.docx", into: &manifest)
        try stage(base64: sampleNativePDFBase64, sha256: sampleNativePDFSHA256,
                  to: root, path: "native-fixtures/sample_native.pdf", into: &manifest)
        try stage(base64: scannedStubPDFBase64, sha256: scannedStubPDFSHA256,
                  to: root, path: "native-fixtures/scanned_stub.pdf", into: &manifest)
    }

    private static func stage(
        base64: String, sha256 expected: String, to root: URL, path: String,
        into manifest: inout [SkillHubStagedFile]
    ) throws {
        guard let bytes = Data(base64Encoded: base64) else {
            throw FloeError.validationFailed("Embedded fixture is not valid base64: \(path)")
        }
        guard FloeDigest.sha256Hex(bytes) == expected else {
            throw FloeError.validationFailed("Embedded fixture sha256 mismatch: \(path)")
        }
        try SkillHubStager.stageBytes(bytes, to: root, path: path, into: &manifest)
    }
}
extension SubagentSimulatorExecutionTests {

    // MARK: - Seven deep browser/screenshot helpers

    /// Projection of a `browser.screenshot` result: the on-device OCR regions
    /// (real rendered glyphs vs tofu boxes), the viewport size and the
    /// retained screenshot artifact descriptor.
    fileprivate struct SevenDeepScreenshot: Decodable {
        struct Region: Decodable { let reference: String; let text: String }
        struct Page: Decodable {
            let visualTextRegions: [Region]?
            let viewportWidth: Double?
            let viewportHeight: Double?
            let screenshotArtifact: SkillHubBrowserResult.Page.Artifact?
        }
        let page: Page?
    }

    fileprivate func sevenDeepDecodeScreenshot(_ result: ToolResult) throws -> SevenDeepScreenshot {
        guard let start = result.outputSummary.firstIndex(of: "{"),
              let end = result.outputSummary.lastIndex(of: "}"), start < end,
              let data = result.outputSummary[start...end].data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SevenDeepScreenshot.self, from: data) else {
            throw FloeError.validationFailed(
                "Screenshot result is not decodable JSON: \(result.outputSummary.prefix(400))")
        }
        return decoded
    }

    /// Reads the pixel size from a PNG's IHDR (stdlib parse, host-side
    /// evidence labeling only — never a guest-execution stand-in).
    fileprivate func sevenDeepPNGSize(_ bytes: Data) throws -> (width: Int, height: Int) {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard bytes.starts(with: signature), bytes.count > 24 else {
            throw FloeError.validationFailed("Artifact is not a PNG (\(bytes.count) bytes)")
        }
        let width = bytes[16..<20].reduce(0) { ($0 << 8) | Int($1) }
        let height = bytes[20..<24].reduce(0) { ($0 << 8) | Int($1) }
        guard width > 0, height > 0 else {
            throw FloeError.validationFailed("PNG IHDR has non-positive dimensions")
        }
        return (width, height)
    }


    /// Fixed read-only acceptance instrumentation of this task's actual WebKit
    /// canvas. Navigation and controls still use the public browser tool chain;
    /// no JavaScript execution surface is added to the model or production app.
    fileprivate func sevenDeepCanvasReadback(
        app: AppEnvironment, conversationID: UUID, tabID: UUID, root: URL, tag: String
    ) async throws -> String {
        guard let session = app.browserCenter.session(for: conversationID),
              let tab = session.tabs.first(where: { $0.id == tabID }) else {
            throw FloeError.notFound("Owned art browser tab is unavailable")
        }
        let encoded: String = try await withCheckedThrowingContinuation { continuation in
            tab.webView.evaluateJavaScript(
                #"document.getElementById('art-canvas').toDataURL('image/png')"#
            ) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value = value as? String { continuation.resume(returning: value) }
                else { continuation.resume(throwing: FloeError.validationFailed("Canvas readback is not a PNG data URL")) }
            }
        }
        let prefix = "data:image/png;base64,"
        guard encoded.hasPrefix(prefix),
              let bytes = Data(base64Encoded: String(encoded.dropFirst(prefix.count))) else {
            throw FloeError.validationFailed("Canvas readback is not valid PNG bytes")
        }
        let size = try sevenDeepPNGSize(bytes)
        try #require(size.width == 1200 && size.height == 1200,
                     "Canvas pixel dimensions differ from the declared 1200x1200")
        let file = root.appendingPathComponent("art-out/observed-\(tag).png")
        try bytes.write(to: file, options: .atomic)
        return FloeDigest.sha256Hex(bytes)
    }

    // MARK: - Seven deep shared helpers

    /// Reads one guest-written JSON output back from the mounted workspace.
    fileprivate func sevenDeepJSON(_ root: URL, _ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(relative))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FloeError.validationFailed("Seven-deep output is not a JSON object: \(relative)")
        }
        return object
    }

    /// Every shipped verifier records `{checks: [{name,status,...}]}`; a
    /// required-capability run must have every check `pass` — a missing or
    /// skipped layer is a failure, never a silent substitute.
    fileprivate func sevenDeepRequireAllChecksPass(_ report: [String: Any], label: String) throws -> Int {
        guard let ok = report["ok"] as? Bool, ok else {
            throw FloeError.validationFailed("\(label) verify report ok != true: \(report)")
        }
        guard let checks = report["checks"] as? [[String: Any]] else {
            throw FloeError.validationFailed("\(label) verify report has no checks array")
        }
        guard !checks.isEmpty else {
            throw FloeError.validationFailed("\(label) verify report has no executed checks")
        }
        for check in checks {
            guard (check["status"] as? String) == "pass",
                  let name = check["name"] as? String else {
                throw FloeError.validationFailed("\(label) check not pass: \(check)")
            }
            _ = name
        }
        return checks.count
    }

    /// Stages the transport zip and proves byte-exact guest unpack by
    /// re-hashing the transport plus every pinned inner package INSIDE the
    /// guest. Returns nothing; throws on any digest mismatch.
    fileprivate func sevenDeepStageAndRehash(
        runtime: FloeAgentRuntime, identity: ChildExecutionIdentity, context: ToolContext
    ) async throws -> String {
        var command = """
        set -e
        PYTHONDONTWRITEBYTECODE=1 python3 -m zipfile -e transport/seven-deep.zip transport/unpacked
        sha256sum transport/seven-deep.zip
        """
        for id in SevenDeepInputs.packageSHA256.keys.sorted() {
            command += "\nsha256sum transport/unpacked/packages/\(id)/1.0.0/\(id).zip"
        }
        let result = try await skillHubShell(
            runtime: runtime, identity: identity, context: context,
            tag: "seven-stage", command: command, timeout: 300)
        try #require(result.status == .ok, "Seven-deep guest staging failed: \(result.outputSummary)")
        try #require(result.outputSummary.contains(SevenDeepInputs.transportZipSHA256),
                     "Guest transport re-hash mismatch: \(result.outputSummary)")
        for (id, pin) in SevenDeepInputs.packageSHA256 {
            try #require(result.outputSummary.contains(pin),
                         "Guest re-hash missing \(id) digest \(pin): \(result.outputSummary)")
        }
        // The outer transport contains package ZIPs, not their installed trees.
        // Only unpack those immutable packages after every guest digest passed.
        var unpackCommand = "set -e"
        for id in SevenDeepInputs.packageSHA256.keys.sorted() {
            unpackCommand += "\nPYTHONDONTWRITEBYTECODE=1 python3 -m zipfile -e transport/unpacked/packages/\(id)/1.0.0/\(id).zip transport/unpacked/\(id)"
            unpackCommand += "\ntest -f transport/unpacked/\(id)/SKILL.md"
        }
        unpackCommand += "\necho SEVEN_PACKAGE_TREES_READY"
        let unpack = try await skillHubShell(
            runtime: runtime, identity: identity, context: context,
            tag: "seven-package-unpack", command: unpackCommand, timeout: 300)
        try #require(unpack.status == .ok
                        && unpack.outputSummary.contains("SEVEN_PACKAGE_TREES_READY"),
                     "Verified inner packages could not be unpacked: \(unpack.outputSummary)")
        return result.outputSummary + "\n" + unpack.outputSummary
    }

    /// Signed-guest apt provisioning exactly as proven by
    /// LocalLinuxStaticServiceRealVMTests: policy probe, one conditional
    /// index update, simulation, install at the proven 600 s guest budget,
    /// then an independent dpkg/apt consistency verification. A missing
    /// candidate or a broken dependency state stays a failure with the
    /// original apt output retained — never a stdlib-only green substitute.
    fileprivate func sevenDeepProvisionApt(
        runtime: FloeAgentRuntime, identity: ChildExecutionIdentity, context: ToolContext,
        jobs: BackgroundJobService, runID: UUID, environmentID: String,
        root: URL, jobIDs: inout [UUID]
    ) async throws -> String {
        let packages = SevenDeepInputs.dataFiveAptPackages
        let joined = packages.joined(separator: " ")
        let pyList = packages.map { "'\($0)'" }.joined(separator: ", ")
        let probe = """
        set -e
        python3 -u - <<'PY'
        import subprocess
        missing=[]
        for package in (\(pyList)):
            result=subprocess.run(['apt-cache','policy',package],text=True,capture_output=True)
            print('APT_POLICY',package,'exit',result.returncode,flush=True)
            print(result.stdout,flush=True)
            if result.stderr: print(result.stderr,flush=True)
            assert result.returncode==0,'apt-cache failed'
            candidate=next((line.split(':',1)[1].strip() for line in result.stdout.splitlines() if line.strip().startswith('Candidate:')),None)
            if not candidate or candidate=='(none)': missing.append(package)
            else: print('APT_CANDIDATE',package,candidate,flush=True)
        print('APT_NEEDS_INDEX_UPDATE' if missing else 'APT_CANDIDATES_READY',*missing,flush=True)
        PY
        """
        let policy = try await skillHubShell(
            runtime: runtime, identity: identity, context: context,
            tag: "apt-policy", command: probe, timeout: 180)
        try #require(policy.status == .ok, "apt policy probe failed: \(policy.outputSummary)")
        var output = policy.outputSummary
        if policy.outputSummary.contains("APT_NEEDS_INDEX_UPDATE") {
            let updateID = try await skillHubSubmitShell(
                jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                name: "seven-apt-update",
                command: "apt-get -o APT::Get::AllowUnauthenticated=false -o Acquire::AllowInsecureRepositories=false -o Acquire::AllowDowngradeToInsecureRepositories=false -o Acquire::Retries=0 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 update",
                timeout: 600)
            jobIDs.append(updateID)
            let update = try await skillHubWaitTerminal(jobs, id: updateID, seconds: 660)
            try #require(update.state == .completed,
                         "apt index update failed: \(update.resultSummary ?? update.lastError ?? update.state.rawValue)")
            output += "\n" + (update.resultSummary ?? "")
            let rechecked = try await skillHubShell(
                runtime: runtime, identity: identity, context: context,
                tag: "apt-policy-2", command: probe, timeout: 180)
            try #require(rechecked.status == .ok
                            && rechecked.outputSummary.contains("APT_CANDIDATES_READY"),
                         "Signed guest repository has no candidates after update: \(rechecked.outputSummary)")
            output += "\n" + rechecked.outputSummary
        }
        let simulate = try await skillHubShell(
            runtime: runtime, identity: identity, context: context, tag: "apt-simulate",
            command: "apt-get -s --no-install-recommends install \(joined)", timeout: 180)
        try #require(simulate.status == .ok, "apt simulate failed: \(simulate.outputSummary)")
        output += "\n" + simulate.outputSummary
        let installID = try await skillHubSubmitShell(
            jobs: jobs, runID: runID, environmentID: environmentID, root: root,
            name: "seven-apt-install",
            command: "env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends -o APT::Get::AllowUnauthenticated=false -o Acquire::AllowInsecureRepositories=false -o Acquire::AllowDowngradeToInsecureRepositories=false -o Acquire::Retries=0 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 install \(joined)",
            timeout: 600)
        jobIDs.append(installID)
        let install = try await skillHubWaitTerminal(jobs, id: installID, seconds: 660)
        try #require(install.state == .completed,
                     "apt install failed: \(install.resultSummary ?? install.lastError ?? install.state.rawValue)")
        output += "\n" + (install.resultSummary ?? "")
        let verifyList = packages.map { "'\($0)'" }.joined(separator: ", ")
        let verify = """
        set -e
        python3 -u - <<'PY'
        import subprocess
        audit=subprocess.run(['dpkg','--audit'],text=True,capture_output=True)
        print('DPKG_AUDIT_EXIT',audit.returncode,flush=True)
        if audit.stdout: print(audit.stdout,flush=True)
        if audit.stderr: print(audit.stderr,flush=True)
        assert audit.returncode==0 and not audit.stdout.strip(),'dpkg reports incomplete package configuration'
        check=subprocess.run(['apt-get','check'],text=True,capture_output=True)
        print('APT_DEPENDENCY_CHECK_EXIT',check.returncode,flush=True)
        print(check.stdout,flush=True)
        if check.stderr: print(check.stderr,flush=True)
        assert check.returncode==0,'apt dependency consistency failed'
        for package in (\(verifyList)):
            result=subprocess.run(['dpkg-query','-W','-f=${db:Status-Status}|${Version}|${Architecture}',package],text=True,capture_output=True)
            print('CONFIGURED_PACKAGE',package,result.returncode,result.stdout.strip(),flush=True)
            if result.stderr: print(result.stderr,flush=True)
            fields=result.stdout.strip().split('|')
            assert result.returncode==0 and len(fields)==3 and fields[0]=='installed' and fields[1] and fields[2] in ('riscv64','all'),package
        print('APT_REAL_CONFIGURATION_VERIFIED',flush=True)
        PY
        """
        let verified = try await skillHubShell(
            runtime: runtime, identity: identity, context: context,
            tag: "apt-verify", command: verify, timeout: 180)
        try #require(verified.status == .ok
                        && verified.outputSummary.contains("APT_REAL_CONFIGURATION_VERIFIED"),
                     "apt install verification failed: \(verified.outputSummary)")
        output += "\n" + verified.outputSummary
        return output
    }
}
extension SubagentSimulatorExecutionTests {

    // MARK: - Test 4a: H4 data five real guest + native qualification

    /// Real TinyEMU guest qualification of the five H4 data packages from the
    /// frozen seven-deep transport: signed-guest apt provisioning of the
    /// runbook-pinned layer, per-package verify goldens (`--require-optional`
    /// / `--require-layer` / `--require-cjk` — a missing layer is a failure,
    /// never a stdlib-only green substitute), real fixture workloads with
    /// cross-engine consistency, spec/input sha256 reproducibility records and
    /// honest encrypted-PDF refusal routed to the native unlock surface; then
    /// the markitdown native acceptance (document.convert DOCX markers,
    /// document.pdf.convert extractable-PDF marker, scanned-stub OCR-required
    /// refusal with no invented text and no output file) and the
    /// literature-review native PDF export (document.convert DOCX +
    /// document.pdf.convert PDF, source preserved). All seven inner package
    /// digests are re-hashed inside the guest before any execution.
    @Test(
        "Skill Hub seven-deep: data five (EDA, statistical, scientific-visualization, markitdown, literature-review) real guest goldens/workloads + markitdown native conversion/OCR refusal + literature native PDF export",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_SKILLHUB_DATAFIVE_GUEST_QUALIFICATION"] == "1")
    )
    func skillHubDataFiveGuestAndNativeQualification() async throws {
        let zip = try SevenDeepInputs.requireTransportZip()
        let root = try makeWorkspaceRoot()
        var evidence: [String: String] = [
            "kind": "skill-hub-seven-deep-datafive-not-model-not-ui",
            "transportZip": zip.path,
            "sourceCommit": SevenDeepInputs.sourceCommit,
        ]
        var manifest: [SkillHubStagedFile] = []
        try SkillHubStager.stageBytes(try Data(contentsOf: zip), to: root,
                                      path: "transport/seven-deep.zip", into: &manifest)
        try MarkitdownNativeFixtures.stageAll(to: root, into: &manifest)
        try SkillHubStager.writeManifest(manifest, at: root)

        let ceiling: Set<String> = ["exec.shell", "document.convert", "document.pdf.convert"]
        var ownedEnvironmentID: String?
        var parentHold: CancellationToken?
        var ownedRuntime: FloeAgentRuntime?
        var parentTask: Task<Void, Error>?
        var jobIDs: [UUID] = []
        var recordsCreated = false
        let app = try await appQualificationEnvironment()
        let runID = UUID()
        let conversationUUID = UUID()
        let fixedIdentity = ChildExecutionIdentity(
            parentRunID: runID, rootTaskID: conversationUUID, delegateCallID: "skillhub-datafive")
        func finish() async {
            await skillHubCleanup(runtime: ownedRuntime, parentHold: parentHold,
                                  parentTask: parentTask, jobs: app.backgroundJobService,
                                  jobIDs: jobIDs, environmentID: ownedEnvironmentID, root: root,
                                  conversationID: recordsCreated ? conversationUUID : nil, app: app)
        }
        do {
            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID
            try await skillHubCreateRunRows(app: app, conversationID: conversationUUID, runID: runID,
                title: "Seven-deep data five qualification",
                goal: "H4 five packages real guest verify and workloads plus native conversion; no model")
            recordsCreated = true
            let hold = CancellationToken()
            parentHold = hold
            let runtime = makeRuntime(
                root: root, conversationID: conversationUUID, runID: runID,
                allowedToolNames: ceiling, environmentID: environmentID,
                adapter: QualificationHoldingProviderAdapter(hold: hold))
            ownedRuntime = runtime
            parentTask = Task {
                try await runtime.start(goal: "Qualify the seven deep data five packages in the real guest")
            }
            try #require(await waitForAsync(timeout: 20) {
                if case .streamingModel = await runtime.state { return true }
                return false
            }, "Parent must be active before seven-deep child execution")
            let childContext = ToolContext(
                runID: runID, scope: .local, allowedToolNames: ceiling,
                workspaceRootURL: root, cancellation: CancellationToken(),
                environmentID: environmentID, conversationID: conversationUUID)
            try await requireQualifiedKernel(runtime: runtime, identity: fixedIdentity, context: childContext)

            // Byte-exact staging proof: guest re-hash of transport + all pins.
            evidence["guestStage"] = String(try await sevenDeepStageAndRehash(
                runtime: runtime, identity: fixedIdentity, context: childContext).prefix(1_000))

            // Signed-guest apt provisioning of the pinned runbook identities.
            let jobs = try #require(app.backgroundJobService, "Production job service is unavailable")
            evidence["aptProvision"] = String(try await sevenDeepProvisionApt(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                jobs: jobs, runID: runID, environmentID: environmentID,
                root: root, jobIDs: &jobIDs).prefix(1_500))
            print("FLOE_SEVEN_DEEP_APT packages=\(SevenDeepInputs.dataFiveAptPackages.count) state=verified")

            let base = "transport/unpacked"

            // ---- 1. exploratory-data-analysis: required optional numpy+pandas ----
            let edaVerify = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "eda-verify",
                command: "cd \(base)/exploratory-data-analysis && PYTHONDONTWRITEBYTECODE=1 python3 scripts/eda_verify.py --require-optional --output verify-eda.json; echo EDA_VERIFY_RC=$?",
                timeout: 300)
            try #require(edaVerify.status == .ok && edaVerify.outputSummary.contains("EDA_VERIFY_RC=0"),
                         "eda_verify failed: \(edaVerify.outputSummary)")
            let edaReport = try sevenDeepJSON(root, "\(base)/exploratory-data-analysis/verify-eda.json")
            let edaChecks = try sevenDeepRequireAllChecksPass(edaReport, label: "eda_verify")
            let edaPins = try #require(edaReport["declared_optional_pins"] as? [String: String],
                                       "eda declared_optional_pins missing")
            try #require(edaPins["numpy"] == "2.2.4" && edaPins["pandas"] == "2.2.3",
                         "eda pins mismatch: \(edaPins)")
            let edaCheckList = try #require(edaReport["checks"] as? [[String: Any]])
            let numpyLayer = try #require(edaCheckList.first { $0["name"] as? String == "numpy_layer_versions" },
                                          "numpy_layer_versions check missing")
            let numpyDetail = try #require(numpyLayer["detail"] as? [String: Any])
            try #require(numpyDetail["pin_matches_base_version"] as? Bool == true,
                         "numpy pin does not match the declared base version: \(numpyDetail)")
            let edaWorkload = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "eda-workload",
                command: "cd \(base)/exploratory-data-analysis && PYTHONDONTWRITEBYTECODE=1 python3 scripts/eda_analyzer.py assets/fixtures/profile_fixture.csv --root . --missing-token NA --output eda.json && PYTHONDONTWRITEBYTECODE=1 python3 scripts/pandas_profile.py assets/fixtures/profile_fixture.csv --root . --missing-token NA --output pandas.json && echo EDA_WORKLOAD_OK",
                timeout: 300)
            try #require(edaWorkload.status == .ok && edaWorkload.outputSummary.contains("EDA_WORKLOAD_OK"),
                         "eda real workload failed: \(edaWorkload.outputSummary)")
            let pandasReport = try sevenDeepJSON(root, "\(base)/exploratory-data-analysis/pandas.json")
            let crossEngine = try #require(pandasReport["cross_engine_check"] as? [String: Any],
                                           "pandas cross_engine_check missing")
            try #require(crossEngine["consistent"] as? Bool == true,
                         "pandas/stdlib cross-engine profile inconsistency: \(crossEngine)")
            evidence["eda"] = "checks=\(edaChecks) pins ok cross_engine consistent"
            print("FLOE_SEVEN_EDA checks=\(edaChecks) numpy=2.2.4 pandas=2.2.3 cross_engine=consistent")

            // ---- 2. statistical-analysis: golden battery + reproducibility ----
            let statsVerify = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "stats-verify",
                command: "cd \(base)/statistical-analysis && PYTHONDONTWRITEBYTECODE=1 python3 scripts/stats_verify.py --require-layer --output verify-stats.json; echo STATS_VERIFY_RC=$?",
                timeout: 300)
            try #require(statsVerify.status == .ok && statsVerify.outputSummary.contains("STATS_VERIFY_RC=0"),
                         "stats_verify failed: \(statsVerify.outputSummary)")
            let statsReport = try sevenDeepJSON(root, "\(base)/statistical-analysis/verify-stats.json")
            let statsChecks = try sevenDeepRequireAllChecksPass(statsReport, label: "stats_verify")
            try #require(statsChecks == 9, "stats_verify must run exactly 9 checks, got \(statsChecks)")
            let specData = try Data(contentsOf: root.appendingPathComponent(
                "\(base)/statistical-analysis/assets/fixtures/groups_spec.json"))
            let inputData = try Data(contentsOf: root.appendingPathComponent(
                "\(base)/statistical-analysis/assets/fixtures/groups_fixture.csv"))
            let specSHA = FloeDigest.sha256Hex(specData)
            let inputSHA = FloeDigest.sha256Hex(inputData)
            let statsRun = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "stats-run",
                command: "cd \(base)/statistical-analysis && PYTHONDONTWRITEBYTECODE=1 python3 scripts/stats_run.py assets/fixtures/groups_fixture.csv --spec assets/fixtures/groups_spec.json --output stats-results.json --report stats-report.md; echo STATS_RUN_RC=$?",
                timeout: 300)
            try #require(statsRun.status == .ok && statsRun.outputSummary.contains("STATS_RUN_RC=0"),
                         "stats_run failed: \(statsRun.outputSummary)")
            let statsResults = try sevenDeepJSON(root, "\(base)/statistical-analysis/stats-results.json")
            let repro = try #require(statsResults["reproducibility"] as? [String: Any],
                                     "stats reproducibility record missing")
            try #require(repro["spec_sha256"] as? String == specSHA,
                         "stats spec sha256 mismatch: \(repro)")
            try #require(repro["input_sha256"] as? String == inputSHA,
                         "stats input sha256 mismatch: \(repro)")
            let engines = try #require(repro["engine_versions"] as? [String: Any],
                                       "stats engine_versions missing")
            try #require(!(engines["scipy"] is NSNull) && (engines["scipy"] as? String) != nil,
                         "scipy engine version not recorded: \(engines)")
            try #require(!(engines["statsmodels"] is NSNull) && (engines["statsmodels"] as? String) != nil,
                         "statsmodels engine version not recorded: \(engines)")
            let statsMarkdown = try Data(contentsOf: root.appendingPathComponent(
                "\(base)/statistical-analysis/stats-report.md"))
            try #require(statsMarkdown.count > 100, "stats report.md missing or empty")
            evidence["stats"] = "checks=9 spec_sha+input_sha bound scipy+statsmodels recorded"
            print("FLOE_SEVEN_STATS checks=9 reproducibility=sha-bound engines=scipy,statsmodels")

            // ---- 3. scientific-visualization: layer+CJK goldens + real export ----
            let vizVerify = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "viz-verify",
                command: "cd \(base)/scientific-visualization && PYTHONDONTWRITEBYTECODE=1 python3 scripts/viz_verify.py --require-layer --require-cjk --output verify-viz.json; echo VIZ_VERIFY_RC=$?",
                timeout: 300)
            try #require(vizVerify.status == .ok && vizVerify.outputSummary.contains("VIZ_VERIFY_RC=0"),
                         "viz_verify failed: \(vizVerify.outputSummary)")
            let vizReport = try sevenDeepJSON(root, "\(base)/scientific-visualization/verify-viz.json")
            _ = try sevenDeepRequireAllChecksPass(vizReport, label: "viz_verify")
            let vizChecks = try #require(vizReport["checks"] as? [[String: Any]])
            let cjkProbe = try #require(vizChecks.first { $0["name"] as? String == "cjk_font_probe" },
                                       "cjk_font_probe check missing")
            let cjkDetail = try #require(cjkProbe["detail"] as? [String: Any])
            let cjkFonts = try #require(cjkDetail["cjk_fonts_discovered"] as? [String],
                                        "cjk_fonts_discovered missing: \(cjkDetail)")
            try #require(!cjkFonts.isEmpty,
                         "no CJK font discovered even though fonts-noto-cjk is provisioned")
            let vizExport = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "viz-export",
                command: "cd \(base)/scientific-visualization && PYTHONDONTWRITEBYTECODE=1 python3 scripts/figure_export.py --demo outputs/export-smoke --formats pdf,png,svg --dpi 300 --manifest && PYTHONDONTWRITEBYTECODE=1 python3 scripts/image_metadata.py outputs/export-smoke.png --format png --min-dpi 300 && PYTHONDONTWRITEBYTECODE=1 python3 scripts/palette_audit.py --palette okabe_ito_on_white --background FFFFFF --role graphical && echo VIZ_EXPORT_OK",
                timeout: 300)
            try #require(vizExport.status == .ok && vizExport.outputSummary.contains("VIZ_EXPORT_OK"),
                         "viz real export workload failed: \(vizExport.outputSummary)")
            for artifact in ["outputs/export-smoke.png", "outputs/export-smoke.svg",
                             "outputs/export-smoke.pdf"] {
                let url = root.appendingPathComponent("\(base)/scientific-visualization/\(artifact)")
                try #require(FileManager.default.fileExists(atPath: url.path),
                             "viz export artifact missing: \(artifact)")
            }
            evidence["viz"] = "layer+cjk pass cjk_fonts=\(cjkFonts.count) export png/svg/pdf dpi300"
            print("FLOE_SEVEN_VIZ cjk_fonts=\(cjkFonts.first ?? "?") exports=png,svg,pdf dpi=300")

            // ---- 4. markitdown: guest layer goldens + xlsx/pdf + honest refusal ----
            let mdVerify = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "md-verify",
                command: "cd \(base)/markitdown && PYTHONDONTWRITEBYTECODE=1 python3 scripts/md_verify.py --require-layer --output verify-md.json; echo MD_VERIFY_RC=$?",
                timeout: 300)
            try #require(mdVerify.status == .ok && mdVerify.outputSummary.contains("MD_VERIFY_RC=0"),
                         "md_verify failed: \(mdVerify.outputSummary)")
            let mdReport = try sevenDeepJSON(root, "\(base)/markitdown/verify-md.json")
            _ = try sevenDeepRequireAllChecksPass(mdReport, label: "md_verify")
            for fixture in ["sample.xlsx", "sample.pdf"] {
                let stem = fixture.replacingOccurrences(of: ".", with: "-")
                let convert = try await skillHubShell(
                    runtime: runtime, identity: fixedIdentity, context: childContext,
                    tag: "md-convert-\(stem)",
                    command: "cd \(base)/markitdown && PYTHONDONTWRITEBYTECODE=1 python3 scripts/md_convert.py assets/fixtures/\(fixture) --root . --output out-\(stem).md --receipt receipt-\(stem).json; echo MD_CONVERT_RC=$?",
                    timeout: 300)
                try #require(convert.status == .ok
                                && convert.outputSummary.contains("MD_CONVERT_RC=0"),
                             "md_convert \(fixture) failed: \(convert.outputSummary)")
                let receipt = try sevenDeepJSON(root, "\(base)/markitdown/receipt-\(stem).json")
                let inner = try #require(receipt["receipt"] as? [String: Any],
                                         "md receipt missing for \(fixture)")
                try #require(inner["status"] as? String == "converted",
                             "md receipt status != converted for \(fixture): \(inner)")
                try #require(inner["source_preserved"] as? Bool == true,
                             "md source not preserved for \(fixture): \(inner)")
            }
            // Protected PDFs are refused by the guest and routed to the native
            // unlock surface — never bypassed, never empty/invented text.
            let mdEncrypted = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "md-encrypted",
                command: "cd \(base)/markitdown && PYTHONDONTWRITEBYTECODE=1 python3 scripts/md_convert.py assets/fixtures/encrypted.pdf --root . --output out-encrypted.md --receipt receipt-encrypted.json; echo MD_ENCRYPT_RC=$?",
                timeout: 300)
            try #require(mdEncrypted.status == .ok
                            && mdEncrypted.outputSummary.contains("MD_ENCRYPT_RC=1"),
                         "encrypted.pdf must fail closed in the guest: \(mdEncrypted.outputSummary)")
            let encReceipt = try sevenDeepJSON(root, "\(base)/markitdown/receipt-encrypted.json")
            let encInner = try #require(encReceipt["receipt"] as? [String: Any])
            let encError = try #require(encInner["error"] as? String)
            try #require(encError.contains("encrypted/protected") && encError.contains("document.pdf.unlock"),
                         "encrypted refusal message mismatch: \(encError)")
            evidence["markitdownGuest"] = "verify pass xlsx+pdf converted source_preserved encrypted refused"
            print("FLOE_SEVEN_MARKITDOWN_GUEST xlsx=ok pdf=ok encrypted=refused->native-unlock")

            // ---- 5. literature-review: stdlib goldens + offline citation taxonomy ----
            let litVerify = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "lit-verify",
                command: "cd \(base)/literature-review && PYTHONDONTWRITEBYTECODE=1 python3 scripts/lit_verify.py --output verify-lit.json; echo LIT_VERIFY_RC=$?",
                timeout: 300)
            try #require(litVerify.status == .ok && litVerify.outputSummary.contains("LIT_VERIFY_RC=0"),
                         "lit_verify failed: \(litVerify.outputSummary)")
            let litReport = try sevenDeepJSON(root, "\(base)/literature-review/verify-lit.json")
            _ = try sevenDeepRequireAllChecksPass(litReport, label: "lit_verify")
            // Offline taxonomy against the bundled synthetic records: 5 DOIs
            // registered, the record-less 0005 honestly inconclusive (exit 1).
            let litOffline = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "lit-offline",
                command: "cd \(base)/literature-review && PYTHONDONTWRITEBYTECODE=1 python3 scripts/verify_citations.py assets/fixtures/review_fixture.md --offline-dir assets/fixtures/crossref -o lit-offline-report.json; echo LIT_OFFLINE_RC=$?",
                timeout: 300)
            try #require(litOffline.status == .ok
                            && litOffline.outputSummary.contains("LIT_OFFLINE_RC=1"),
                         "offline citation run must exit 1 (one unresolved synthetic DOI): \(litOffline.outputSummary)")
            let litCitation = try sevenDeepJSON(root, "\(base)/literature-review/lit-offline-report.json")
            try #require(litCitation["mode"] as? String == "offline", "mode != offline")
            let verified = try #require(litCitation["verified"] as? [String])
            try #require(verified.contains("10.99999/floe-synthetic-0001")
                            && verified.contains("10.99999/floe-synthetic-0004")
                            && verified.contains("10.99999/old(1998)style"),
                         "offline verified taxonomy mismatch: \(verified)")
            let failed = try #require(litCitation["failed"] as? [String])
            try #require(failed.contains("10.99999/floe-synthetic-0005"),
                         "record-less DOI 0005 must stay unresolved: \(failed)")
            let litMetadata = try #require(litCitation["metadata"] as? [String: Any])
            let meta1 = try #require(litMetadata["10.99999/floe-synthetic-0001"] as? [String: Any])
            try #require(meta1["status"] as? String == "registered"
                            && meta1["mode"] as? String == "offline"
                            && meta1["metadata_status"] as? String == "retrieved",
                         "synthetic record taxonomy mismatch: \(meta1)")
            // The real online-acceptance DOI has no offline record: it must be
            // reported unavailable with no invented title (2026-10-26 probe
            // truth: Handle registered, Crossref 404).
            let litTruth = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "lit-truth",
                command: "cd \(base)/literature-review && PYTHONDONTWRITEBYTECODE=1 python3 scripts/verify_citations.py assets/fixtures/online_acceptance.md --offline-dir assets/fixtures/crossref -o lit-truth-report.json; echo LIT_TRUTH_RC=$?",
                timeout: 300)
            try #require(litTruth.status == .ok && litTruth.outputSummary.contains("LIT_TRUTH_RC=1"),
                         "truth citation run must exit 1: \(litTruth.outputSummary)")
            let truthReport = try sevenDeepJSON(root, "\(base)/literature-review/lit-truth-report.json")
            try #require((truthReport["verified"] as? [String])?.isEmpty == true,
                         "unavailable DOI must never verify: \(truthReport)")
            let truthErrors = try #require(truthReport["errors"] as? [String: Any])
            let truthMeta = try #require(truthErrors["10.48550/arXiv.2609.00065"] as? [String: Any])
            try #require(truthMeta["status"] as? String == "inconclusive"
                            && truthMeta["offline_record"] as? String == "missing",
                         "truth DOI classification mismatch: \(truthMeta)")
            try #require(truthMeta["title"] == nil, "unavailable DOI must never carry an invented title")
            evidence["literature"] = "verify pass offline 5 registered 0005 inconclusive truth unavailable"
            print("FLOE_SEVEN_LITERATURE offline_taxonomy=5+1 truth=unavailable-no-title")

            // ---- 6. markitdown native acceptance (synthetic fixtures) ----
            let native1 = try toolCall(id: "native-docx", toolName: "document.convert",
                arguments: try Self.json([
                    "inputPath": "native-fixtures/sample.docx",
                    "outputPath": "native-fixtures/sample-docx.md",
                    "format": "markdown",
                ]))
            let native1Result = await runtime.dispatchChildTool(
                native1, identity: fixedIdentity, childContext: childContext)
            try #require(native1Result.status == .ok,
                         "native document.convert sample.docx failed: \(native1Result.outputSummary)")
            let docxMarkdown = try String(contentsOf: root.appendingPathComponent(
                "native-fixtures/sample-docx.md"), encoding: .utf8)
            try #require(docxMarkdown.contains("Floe native acceptance fixture")
                            && docxMarkdown.contains("Document conversion sample seven (7).")
                            && docxMarkdown.contains("中文段落：格式转 Markdown 原生验收夹具。"),
                         "native DOCX markdown markers missing: \(docxMarkdown.prefix(300))")
            try #require(FloeDigest.sha256Hex(try Data(contentsOf: root.appendingPathComponent(
                "native-fixtures/sample.docx"))) == MarkitdownNativeFixtures.sampleDocxSHA256,
                         "sample.docx source changed during conversion")

            let native2 = try toolCall(id: "native-pdf", toolName: "document.pdf.convert",
                arguments: try Self.json([
                    "inputPath": "native-fixtures/sample_native.pdf",
                    "outputPath": "native-fixtures/sample-native.md",
                    "format": "markdown",
                ]))
            let native2Result = await runtime.dispatchChildTool(
                native2, identity: fixedIdentity, childContext: childContext)
            try #require(native2Result.status == .ok,
                         "native document.pdf.convert sample_native.pdf failed: \(native2Result.outputSummary)")
            let pdfMarkdown = try String(contentsOf: root.appendingPathComponent(
                "native-fixtures/sample-native.md"), encoding: .utf8)
            try #require(pdfMarkdown.contains("Floe native acceptance fixture 7"),
                         "native PDF markdown marker missing: \(pdfMarkdown.prefix(300))")
            try #require(FloeDigest.sha256Hex(try Data(contentsOf: root.appendingPathComponent(
                "native-fixtures/sample_native.pdf"))) == MarkitdownNativeFixtures.sampleNativePDFSHA256,
                         "sample_native.pdf source changed during conversion")

            // Scanned stub: explicit OCR-required failure, never empty/invented
            // text, and no output file is written.
            let native3 = try toolCall(id: "native-scan", toolName: "document.pdf.convert",
                arguments: try Self.json([
                    "inputPath": "native-fixtures/scanned_stub.pdf",
                    "outputPath": "native-fixtures/scanned-stub.md",
                    "format": "markdown",
                ]))
            let native3Result = await runtime.dispatchChildTool(
                native3, identity: fixedIdentity, childContext: childContext)
            try #require(native3Result.status != .ok,
                         "scanned_stub.pdf must fail with the OCR-required refusal: \(native3Result.outputSummary)")
            try #require(native3Result.outputSummary.lowercased().contains("ocr"),
                         "scanned refusal must name the OCR workflow: \(native3Result.outputSummary)")
            try #require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
                "native-fixtures/scanned-stub.md").path),
                         "scanned conversion must not write an output file")
            try #require(FloeDigest.sha256Hex(try Data(contentsOf: root.appendingPathComponent(
                "native-fixtures/scanned_stub.pdf"))) == MarkitdownNativeFixtures.scannedStubPDFSHA256,
                         "scanned_stub.pdf source changed")
            evidence["markitdownNative"] = "docx markers pdf marker scanned OCR-refused sources unchanged"
            print("FLOE_SEVEN_MARKITDOWN_NATIVE docx=ok pdf=ok scanned=ocr-refused")

            // ---- 7. literature-review native PDF export (truthful delivery) ----
            try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "lit-review-copy",
                command: "cp \(base)/literature-review/assets/fixtures/review_fixture.md native-fixtures/review.md && echo LIT_REVIEW_COPIED",
                timeout: 60)
            let reviewSHA = FloeDigest.sha256Hex(try Data(contentsOf: root.appendingPathComponent(
                "native-fixtures/review.md")))
            let litDocx = try toolCall(id: "lit-docx", toolName: "document.convert",
                arguments: try Self.json([
                    "inputPath": "native-fixtures/review.md",
                    "outputPath": "native-fixtures/review.docx",
                    "format": "docx",
                ]))
            let litDocxResult = await runtime.dispatchChildTool(
                litDocx, identity: fixedIdentity, childContext: childContext)
            try #require(litDocxResult.status == .ok,
                         "literature document.convert review.md failed: \(litDocxResult.outputSummary)")
            try #require(FileManager.default.fileExists(atPath: root.appendingPathComponent(
                "native-fixtures/review.docx").path), "review.docx missing")
            let litPdf = try toolCall(id: "lit-pdf", toolName: "document.pdf.convert",
                arguments: try Self.json([
                    "inputPath": "native-fixtures/review.md",
                    "outputPath": "native-fixtures/review.pdf",
                    "format": "pdf",
                ]))
            let litPdfResult = await runtime.dispatchChildTool(
                litPdf, identity: fixedIdentity, childContext: childContext)
            try #require(litPdfResult.status == .ok,
                         "literature document.pdf.convert review.md failed: \(litPdfResult.outputSummary)")
            let reviewPDF = try Data(contentsOf: root.appendingPathComponent(
                "native-fixtures/review.pdf"))
            try #require(reviewPDF.count > 500 && reviewPDF.starts(with: [0x25, 0x50, 0x44, 0x46]),
                         "review.pdf is not a real PDF: \(reviewPDF.count) bytes")
            try #require(FloeDigest.sha256Hex(try Data(contentsOf: root.appendingPathComponent(
                "native-fixtures/review.md"))) == reviewSHA, "review.md source changed during export")
            evidence["literatureNative"] = "docx+pdf exported review.pdf=\(reviewPDF.count)B source preserved"
            print("FLOE_SEVEN_LITERATURE_NATIVE review.pdf=\(reviewPDF.count)B source=preserved")

            await finish()
        } catch {
            evidence["failure"] = String(describing: error)
            skillHubFailureEvidence(evidence, root: root, label: "seven-deep-datafive")
            Issue.record("Seven-deep data five qualification failed: \(error)")
            await finish()
        }
    }
}
extension SubagentSimulatorExecutionTests {

    // MARK: - Test 4b: canvas-design real guest + native browser qualification

    /// Real TinyEMU guest qualification of the canvas-design package: the
    /// full poster pipeline from the visual-two runbook — py_compile, the
    /// check-only report (canvasPx + metricBasis/artifactPolicy/notices), the
    /// hero poster (3508x4961, 5 licensed fonts with sha256 coverage), the CJK
    /// poster (exactly 22 fallback chars through the declared device stack),
    /// the `--require-embedded` useful-failure (exit 4), guest determinism
    /// (byte-identical svg/html), the closure-corrected 2x2 PNG -> PDF golden
    /// (verified pixels [2,2], pagePt [0.48,0.48], MediaBox readback) plus the
    /// overwrite guard (exit 3), and the self-containment artifact truth
    /// (embedded @font-face payloads hash-equal the coverage registry, OFL
    /// notices present, zero external resource-bearing fields). The native
    /// half serves the real guest output through exec.localService (static)
    /// and proves, through the App's real browser tools: the declared-size
    /// chrome and Export PNG button, an on-device OCR screenshot whose text
    /// contains the actual CJK glyphs (tofu boxes cannot OCR to 静默几何 /
    /// 结构即语言), and the truthful full-size export outcome (either the real
    /// 1080x1350 in-page raster or the engine's honest FAILED line — a
    /// viewport screenshot is recorded as preview-only evidence and is never
    /// claimed as the declared raster).
    @Test(
        "Skill Hub seven-deep: canvas-design poster pipeline in the real guest + native WebKit CJK OCR render and truthful full-size export",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_SKILLHUB_CANVAS_GUEST_QUALIFICATION"] == "1")
    )
    func skillHubCanvasDesignGuestAndNativeQualification() async throws {
        let zip = try SevenDeepInputs.requireTransportZip()
        let root = try makeWorkspaceRoot()
        var evidence: [String: String] = [
            "kind": "skill-hub-seven-deep-canvas-not-model-not-ui",
            "transportZip": zip.path,
            "sourceCommit": SevenDeepInputs.sourceCommit,
        ]
        var manifest: [SkillHubStagedFile] = []
        try SkillHubStager.stageBytes(try Data(contentsOf: zip), to: root,
                                      path: "transport/seven-deep.zip", into: &manifest)
        try SkillHubStager.writeManifest(manifest, at: root)

        let ceiling: Set<String> = [
            "exec.shell", "browser.tab", "browser.tabs", "browser.navigate", "browser.observe",
            "browser.wait", "browser.click", "browser.screenshot", "browser.events",
        ]
        var ownedEnvironmentID: String?
        var parentHold: CancellationToken?
        var ownedRuntime: FloeAgentRuntime?
        var parentTask: Task<Void, Error>?
        var jobIDs: [UUID] = []
        var tabs: [UUID] = []
        var identity: ChildExecutionIdentity?
        var context: ToolContext?
        var recordsCreated = false
        let app = try await appQualificationEnvironment()
        let jobs = try #require(app.backgroundJobService, "Production job service is unavailable")
        let runID = UUID()
        let conversationUUID = UUID()
        let fixedIdentity = ChildExecutionIdentity(
            parentRunID: runID, rootTaskID: conversationUUID, delegateCallID: "skillhub-canvas")
        identity = fixedIdentity
        func finish() async {
            await skillHubCloseBrowserTabs(runtime: ownedRuntime, identity: identity,
                                           context: context, tabs: tabs)
            await skillHubCleanup(runtime: ownedRuntime, parentHold: parentHold,
                                  parentTask: parentTask, jobs: app.backgroundJobService,
                                  jobIDs: jobIDs, environmentID: ownedEnvironmentID, root: root,
                                  conversationID: recordsCreated ? conversationUUID : nil, app: app)
        }
        do {
            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID
            try await skillHubCreateRunRows(app: app, conversationID: conversationUUID, runID: runID,
                title: "Seven-deep canvas-design qualification",
                goal: "canvas-design poster pipeline in the guest plus native CJK render/export; no model")
            recordsCreated = true
            let hold = CancellationToken()
            parentHold = hold
            let runtime = makeRuntime(
                root: root, conversationID: conversationUUID, runID: runID,
                allowedToolNames: ceiling, environmentID: environmentID,
                adapter: QualificationHoldingProviderAdapter(hold: hold))
            ownedRuntime = runtime
            parentTask = Task {
                try await runtime.start(goal: "Qualify canvas-design in the real guest and native browser")
            }
            try #require(await waitForAsync(timeout: 20) {
                if case .streamingModel = await runtime.state { return true }
                return false
            }, "Parent must be active before seven-deep child execution")
            let childContext = ToolContext(
                runID: runID, scope: .local, allowedToolNames: ceiling,
                workspaceRootURL: root, cancellation: CancellationToken(),
                environmentID: environmentID, conversationID: conversationUUID)
            context = childContext
            try await requireQualifiedKernel(runtime: runtime, identity: fixedIdentity, context: childContext)

            evidence["guestStage"] = String(try await sevenDeepStageAndRehash(
                runtime: runtime, identity: fixedIdentity, context: childContext).prefix(1_000))

            let base = "transport/unpacked"

            // 1. Guest compile of both shipped scripts.
            let compile = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "canvas-compile",
                command: "cd \(base)/canvas-design && PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile scripts/make_poster.py scripts/png_to_pdf.py && echo CANVAS_COMPILE_OK",
                timeout: 120)
            try #require(compile.status == .ok && compile.outputSummary.contains("CANVAS_COMPILE_OK"),
                         "canvas py_compile failed: \(compile.outputSummary)")

            // 2. check-only: JSON report, canvasPx 3508x4961, nothing written.
            let checkOnly = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "canvas-check",
                command: "cd \(base)/canvas-design && PYTHONDONTWRITEBYTECODE=1 python3 scripts/make_poster.py --check-only --spec assets/examples/hero-spec.json > check-hero.json && test ! -e poster-out && echo CANVAS_CHECK_OK",
                timeout: 120)
            try #require(checkOnly.status == .ok && checkOnly.outputSummary.contains("CANVAS_CHECK_OK"),
                         "canvas check-only failed or wrote files: \(checkOnly.outputSummary)")
            let checkReport = try sevenDeepJSON(root, "\(base)/canvas-design/check-hero.json")
            let canvasPx = try #require(checkReport["canvasPx"] as? [Int])
            try #require(canvasPx == [3_508, 4_961], "hero canvasPx != [3508,4961]: \(canvasPx)")
            for field in ["metricBasis", "artifactPolicy", "notices"] {
                try #require(checkReport[field] != nil, "check-only report missing \(field)")
            }

            // 3. Hero poster: three files, real SVG geometry, 5 licensed fonts.
            let hero = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "canvas-hero",
                command: "cd \(base)/canvas-design && PYTHONDONTWRITEBYTECODE=1 python3 scripts/make_poster.py --spec assets/examples/hero-spec.json --outdir poster-out --prefix hero; echo CANVAS_HERO_RC=$?",
                timeout: 300)
            try #require(hero.status == .ok && hero.outputSummary.contains("CANVAS_HERO_RC=0"),
                         "hero poster failed: \(hero.outputSummary)")
            let heroSVG = try String(contentsOf: root.appendingPathComponent(
                "\(base)/canvas-design/poster-out/hero.svg"), encoding: .utf8)
            try #require(heroSVG.contains("width=\"3508") && heroSVG.contains("height=\"4961")
                            && heroSVG.contains("viewBox=\"0 0 3508 4961"),
                         "hero.svg geometry mismatch: \(heroSVG.prefix(240))")
            let heroCoverage = try sevenDeepJSON(root, "\(base)/canvas-design/poster-out/hero.coverage.json")
            let fontsUsed = try #require(heroCoverage["fontsUsed"] as? [[String: Any]])
            try #require(fontsUsed.count == 5, "hero fontsUsed != 5: \(fontsUsed.count)")
            for font in fontsUsed {
                let digest = try #require(font["sha256"] as? String)
                try #require(digest.count == 64 && digest.allSatisfy(\.isHexDigit),
                             "hero font sha256 malformed: \(font)")
            }

            // 4. CJK poster: exactly 22 fallback chars through the device stack.
            let cjk = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "canvas-cjk",
                command: "cd \(base)/canvas-design && PYTHONDONTWRITEBYTECODE=1 python3 scripts/make_poster.py --spec assets/examples/cjk-poster-spec.json --outdir poster-out --prefix cjk; echo CANVAS_CJK_RC=$?",
                timeout: 300)
            try #require(cjk.status == .ok && cjk.outputSummary.contains("CANVAS_CJK_RC=0"),
                         "cjk poster failed: \(cjk.outputSummary)")
            try #require(cjk.outputSummary.contains("\"fallbackChars\": 22"),
                         "cjk fallbackChars != 22: \(cjk.outputSummary.prefix(400))")

            // 5. --require-embedded on the CJK spec is the honest useful failure.
            let embedded = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "canvas-embedded",
                command: "cd \(base)/canvas-design && PYTHONDONTWRITEBYTECODE=1 python3 scripts/make_poster.py --spec assets/examples/cjk-poster-spec.json --outdir poster-out --prefix cjk --require-embedded; echo CANVAS_EMBED_RC=$?",
                timeout: 120)
            try #require(embedded.status == .ok && embedded.outputSummary.contains("CANVAS_EMBED_RC=4"),
                         "--require-embedded must exit 4 on the CJK spec: \(embedded.outputSummary)")
            try #require(embedded.outputSummary.contains("--require-embedded"),
                         "--require-embedded refusal message missing: \(embedded.outputSummary.prefix(300))")

            // 6. Guest determinism: byte-identical svg/html across runs.
            let rerun = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "canvas-rerun",
                command: "cd \(base)/canvas-design && PYTHONDONTWRITEBYTECODE=1 python3 scripts/make_poster.py --spec assets/examples/hero-spec.json --outdir poster-out2 --prefix hero && cmp poster-out/hero.svg poster-out2/hero.svg && cmp poster-out/hero.html poster-out2/hero.html && echo CANVAS_DETERMINISTIC",
                timeout: 300)
            try #require(rerun.status == .ok && rerun.outputSummary.contains("CANVAS_DETERMINISTIC"),
                         "poster determinism failed: \(rerun.outputSummary)")

            // 7. png_to_pdf: closure-corrected 2x2 fixture literal, verified
            //    geometry, then the overwrite guard.
            let pngPDF = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "canvas-pngpdf",
                command: #"""
                cd TRANSPORT_BASE/canvas-design
                python3 - <<'EOF'
                import struct, zlib
                row1 = b"\x00" + b"\xff\x00\x00" * 2
                row2 = b"\x00" + b"\x00\xff\x00" * 2
                def chunk(t, d):
                    return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
                png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 2, 2, 8, 2, 0, 0, 0)) \
                      + chunk(b"IDAT", zlib.compress(row1 + row2, 9)) + chunk(b"IEND", b"")
                open("fixture.png", "wb").write(png)
                EOF
                PYTHONDONTWRITEBYTECODE=1 python3 scripts/png_to_pdf.py --input fixture.png --output fixture.pdf --dpi 300 > fixture-pdf.json
                echo CANVAS_PNGPDF_RC=$?
                PYTHONDONTWRITEBYTECODE=1 python3 scripts/png_to_pdf.py --input fixture.png --output fixture.pdf --dpi 300; echo CANVAS_PDF_OVERWRITE_RC=$?
                """#.replacingOccurrences(of: "TRANSPORT_BASE", with: base),
                timeout: 120)
            try #require(pngPDF.status == .ok
                            && pngPDF.outputSummary.contains("CANVAS_PNGPDF_RC=0")
                            && pngPDF.outputSummary.contains("CANVAS_PDF_OVERWRITE_RC=3"),
                         "png_to_pdf verify/overwrite-guard mismatch: \(pngPDF.outputSummary)")
            let fixturePDFReport = try sevenDeepJSON(root, "\(base)/canvas-design/fixture-pdf.json")
            try #require(fixturePDFReport["verified"] as? Bool == true,
                         "png_to_pdf self-verify false: \(fixturePDFReport)")
            try #require((fixturePDFReport["pixels"] as? [Int]) == [2, 2],
                         "png_to_pdf pixels != [2,2]: \(fixturePDFReport)")
            let pagePt = try #require(fixturePDFReport["pagePt"] as? [Double])
            try #require(abs(pagePt[0] - 0.48) < 0.01 && abs(pagePt[1] - 0.48) < 0.01,
                         "png_to_pdf pagePt != [0.48,0.48]: \(pagePt)")
            let fixturePDF = try Data(contentsOf: root.appendingPathComponent(
                "\(base)/canvas-design/fixture.pdf"))
            let mediaBox = String(decoding: fixturePDF, as: UTF8.self)
            try #require(mediaBox.contains("/MediaBox [0 0 0.48 0.48]"),
                         "fixture.pdf MediaBox mismatch: \(mediaBox.prefix(300))")

            // 8. Artifact truth on the self-contained hero.html.
            let truth = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "canvas-truth",
                command: "cd \(base)/canvas-design && PYTHONDONTWRITEBYTECODE=1 python3 - <<'PY'\n"
                    + sevenDeepPosterTruthScript + "\nPY",
                timeout: 120)
            try #require(truth.status == .ok && truth.outputSummary.contains("ARTIFACT_TRUTH_OK"),
                         "poster artifact truth failed: \(truth.outputSummary)")
            evidence["canvasGuest"] = "compile+check+hero(5fonts)+cjk(22)+embed4+determinism+pngpdf+truth"
            print("FLOE_SEVEN_CANVAS_GUEST hero=3508x4961 cjk_fallback=22 embed_rc=4 pngpdf=verified")

            // 9. Native browser: serve the real guest output statically.
            let port = Int.random(in: 20_000...45_000)
            let invocation = LocalServiceTool.Arguments(
                runtime: "static", entry: "transport/unpacked/canvas-design/poster-out/cjk.html",
                arguments: nil, cwd: nil, port: port)
            let serviceJob = try await jobs.submit(
                runID: runID, toolCallID: "seven-canvas-poster-" + UUID().uuidString,
                targetTool: "exec.localService", payloadJSON: JSONEncoder().encode(invocation),
                scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [],
                environmentID: environmentID, submissionSource: .nativeService, waitForCompletion: false)
            jobIDs.append(serviceJob.id)
            var progressSamples: [[String: String]] = []
            let preview = try await skillHubWaitPreview(
                jobs, id: serviceJob.id, samples: &progressSamples, timeout: 180)
            try #require(preview.host == "127.0.0.1" && preview.port == port,
                         "Preview must be the owned loopback endpoint, got \(preview)")

            let created = try await skillHubBrowserCall(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "canvas-create", tool: "browser.tab", arguments: ["action": "create"])
            let tabID = try #require(created.page?.tabs.first(where: { $0.isActive })?.id,
                                     "canvas tab create returned no active tab")
            tabs.append(tabID)
            try await skillHubBrowserCall(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "canvas-navigate", tool: "browser.navigate",
                arguments: ["url": preview.absoluteString, "tabID": tabID.uuidString])
            try await skillHubBrowserCall(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "canvas-load", tool: "browser.wait",
                arguments: ["tabID": tabID.uuidString, "condition": "load",
                            "timeoutMilliseconds": 15_000])

            // Declared-size chrome and the full-size export control.
            var page = try await skillHubObserve(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "canvas-observe", tabID: tabID)
            try #require(page.nodes.contains { $0.text.contains("Declared size: 1080 × 1350 px") },
                         "declared-size chrome missing: \(page.nodes.map(\.text).joined(separator: " | ").prefix(400))")
            let exportButton = try #require(
                page.nodes.first { $0.role == "button"
                    && ($0.name.contains("Export PNG 1080×1350") || $0.text.contains("Export PNG 1080×1350")) },
                "Export PNG 1080×1350 button missing: \(page.nodes.filter { $0.role == "button" }.map(\.name).joined(separator: " | "))")

            // OCR screenshot: real CJK glyphs must be recognized (tofu boxes
            // cannot OCR to the exact characters). The artifact is recorded
            // as a viewport-bounded preview, never the declared raster.
            let shotCall = try toolCall(id: "canvas-shot", toolName: "browser.screenshot",
                arguments: try Self.json(["tabID": tabID.uuidString]))
            let shotResult = await runtime.dispatchChildTool(
                shotCall, identity: fixedIdentity, childContext: childContext)
            try #require(shotResult.status == .ok,
                         "canvas screenshot failed: \(shotResult.outputSummary)")
            let shot = try sevenDeepDecodeScreenshot(shotResult)
            let regions = try #require(shot.page?.visualTextRegions,
                                       "screenshot carried no OCR regions")
            let ocrText = regions.map(\.text).joined(separator: " ")
            try #require(ocrText.contains("静默几何"),
                         "CJK title did not OCR from the render (tofu?): \(ocrText.prefix(300))")
            try #require(ocrText.contains("结构即语言"),
                         "CJK subline did not OCR from the render (tofu?): \(ocrText.prefix(300))")
            let viewportW = Int(try #require(shot.page?.viewportWidth))
            let viewportH = Int(try #require(shot.page?.viewportHeight))
            let artifact = try #require(shot.page?.screenshotArtifact)
            let artifactBytes = try Data(contentsOf: root.appendingPathComponent(artifact.relativePath))
            let artifactSize = try sevenDeepPNGSize(artifactBytes)
            evidence["canvasViewport"] = "\(viewportW)x\(viewportH) preview"
            evidence["canvasScreenshot"] = "\(artifactSize.width)x\(artifactSize.height) sha=\(artifact.sha256.prefix(16))… (viewport-bounded preview, NOT the 1080x1350 raster)"

            // Truthful full-size export: either the real 1080x1350 in-page
            // raster or the engine's honest FAILED line; both are passes.
            try await skillHubBrowserCall(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "canvas-export-click", tool: "browser.click",
                arguments: ["tabID": tabID.uuidString, "ref": exportButton.ref,
                            "documentID": page.documentID])
            try await Task.sleep(for: .milliseconds(4_000))
            page = try await skillHubObserve(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "canvas-export-observe", tabID: tabID)
            let exportStatus = page.nodes.first {
                $0.text.contains("Exported 1080x1350 PNG") || $0.text.hasPrefix("FAILED")
            }?.text ?? ""
            try #require(!exportStatus.isEmpty,
                         "export control reported no truthful outcome: \(page.nodes.map(\.text).joined(separator: " | ").prefix(400))")
            evidence["canvasExport"] = String(exportStatus.prefix(220))
            print("FLOE_SEVEN_CANVAS_EXPORT \(exportStatus.prefix(120))")

            await finish()
        } catch {
            evidence["failure"] = String(describing: error)
            skillHubFailureEvidence(evidence, root: root, label: "seven-deep-canvas")
            Issue.record("Seven-deep canvas qualification failed: \(error)")
            await finish()
        }
    }
}
extension SubagentSimulatorExecutionTests {

    // MARK: - Test 4c: algorithmic-art real guest + native viewer qualification

    /// Real TinyEMU guest qualification of the algorithmic-art package: the
    /// node --check surface, byte-exact mulberry32 PRNG stream equality
    /// between the guest Python generator and the guest Node core, canonical
    /// digest parity for both algorithms at both boundary seeds plus one
    /// override set (the runbook's mirror of the 100-combination host sweep),
    /// four-file artifact generation with guest determinism (byte-identical
    /// svg/html/primitives/params across runs), the three invalid-input
    /// classes (exit 2) and the --list-algos surface, then the shipped
    /// About & licenses + artifact-notices disclosures. The native half serves
    /// the real guest output through exec.localService (static) and drives
    /// the App's real browser tools against the live viewer: the seed
    /// display and ops status, next/prev seed navigation with digest change
    /// and exact return to the original digest (reversible deterministic
    /// redraw), and the Download PNG control. No p5.js parity claim and no
    /// riscv64 Chromium/Playwright anywhere in this test.
    @Test(
        "Skill Hub seven-deep: algorithmic-art python/node PRNG+digest parity and deterministic artifacts in the real guest + native viewer control truth",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_SKILLHUB_ART_GUEST_QUALIFICATION"] == "1")
    )
    func skillHubAlgorithmicArtGuestAndNativeQualification() async throws {
        let zip = try SevenDeepInputs.requireTransportZip()
        let root = try makeWorkspaceRoot()
        var evidence: [String: String] = [
            "kind": "skill-hub-seven-deep-art-not-model-not-ui",
            "transportZip": zip.path,
            "sourceCommit": SevenDeepInputs.sourceCommit,
        ]
        var manifest: [SkillHubStagedFile] = []
        try SkillHubStager.stageBytes(try Data(contentsOf: zip), to: root,
                                      path: "transport/seven-deep.zip", into: &manifest)
        try SkillHubStager.writeManifest(manifest, at: root)

        let ceiling: Set<String> = [
            "exec.shell", "browser.tab", "browser.tabs", "browser.navigate", "browser.observe",
            "browser.wait", "browser.click", "browser.screenshot", "browser.events",
        ]
        var ownedEnvironmentID: String?
        var parentHold: CancellationToken?
        var ownedRuntime: FloeAgentRuntime?
        var parentTask: Task<Void, Error>?
        var jobIDs: [UUID] = []
        var tabs: [UUID] = []
        var identity: ChildExecutionIdentity?
        var context: ToolContext?
        var recordsCreated = false
        let app = try await appQualificationEnvironment()
        let jobs = try #require(app.backgroundJobService, "Production job service is unavailable")
        let runID = UUID()
        let conversationUUID = UUID()
        let fixedIdentity = ChildExecutionIdentity(
            parentRunID: runID, rootTaskID: conversationUUID, delegateCallID: "skillhub-art")
        identity = fixedIdentity
        func finish() async {
            await skillHubCloseBrowserTabs(runtime: ownedRuntime, identity: identity,
                                           context: context, tabs: tabs)
            await skillHubCleanup(runtime: ownedRuntime, parentHold: parentHold,
                                  parentTask: parentTask, jobs: app.backgroundJobService,
                                  jobIDs: jobIDs, environmentID: ownedEnvironmentID, root: root,
                                  conversationID: recordsCreated ? conversationUUID : nil, app: app)
        }
        do {
            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID
            try await skillHubCreateRunRows(app: app, conversationID: conversationUUID, runID: runID,
                title: "Seven-deep algorithmic-art qualification",
                goal: "algorithmic-art parity and determinism in the guest plus native viewer truth; no model")
            recordsCreated = true
            let hold = CancellationToken()
            parentHold = hold
            let runtime = makeRuntime(
                root: root, conversationID: conversationUUID, runID: runID,
                allowedToolNames: ceiling, environmentID: environmentID,
                adapter: QualificationHoldingProviderAdapter(hold: hold))
            ownedRuntime = runtime
            parentTask = Task {
                try await runtime.start(goal: "Qualify algorithmic-art in the real guest and native browser")
            }
            try #require(await waitForAsync(timeout: 20) {
                if case .streamingModel = await runtime.state { return true }
                return false
            }, "Parent must be active before seven-deep child execution")
            let childContext = ToolContext(
                runID: runID, scope: .local, allowedToolNames: ceiling,
                workspaceRootURL: root, cancellation: CancellationToken(),
                environmentID: environmentID, conversationID: conversationUUID)
            context = childContext
            try await requireQualifiedKernel(runtime: runtime, identity: fixedIdentity, context: childContext)

            evidence["guestStage"] = String(try await sevenDeepStageAndRehash(
                runtime: runtime, identity: fixedIdentity, context: childContext).prefix(1_000))

            let base = "transport/unpacked"

            // 1. node --check on the browser core, the node parity driver and
            //    the viewer glue (node ships in the Debian 13 riscv64 image).
            let nodeCheck = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "art-node-check",
                command: "cd \(base)/algorithmic-art && node --check assets/floegart.js && node --check scripts/prng_parity.js && node --check assets/viewer-ui.js && echo ART_NODE_CHECK_OK",
                timeout: 120)
            try #require(nodeCheck.status == .ok && nodeCheck.outputSummary.contains("ART_NODE_CHECK_OK"),
                         "node --check failed: \(nodeCheck.outputSummary)")

            // 2. PRNG stream equality: guest python vs guest node.
            let prng = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "art-prng",
                command: "cd \(base)/algorithmic-art && PYTHONDONTWRITEBYTECODE=1 python3 scripts/generate_art.py --seed 987654321 --prng-stream > /tmp/seven-py.stream && node scripts/prng_parity.js --seed 987654321 --streams > /tmp/seven-js.stream && cmp /tmp/seven-py.stream /tmp/seven-js.stream && echo ART_PRNG_STREAM_OK",
                timeout: 120)
            try #require(prng.status == .ok && prng.outputSummary.contains("ART_PRNG_STREAM_OK"),
                         "PRNG stream parity failed: \(prng.outputSummary)")

            // 3. Canonical digest parity: both algos, both boundary seeds, one
            //    override set (mirrors the runbook's host 100-case sweep).
            let parity = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "art-parity",
                command: """
                cd \(base)/algorithmic-art
                set -e
                py_digest() { PYTHONDONTWRITEBYTECODE=1 python3 scripts/generate_art.py --digest "$@"; }
                js_digest() { node scripts/prng_parity.js "$@" | python3 -c 'import sys,json;print(json.load(sys.stdin)["digest"])'; }
                test "$(py_digest --seed 987654321 --algo flowfield --width 1200 --height 1200)" = "$(js_digest --seed 987654321 --algo flowfield --width 1200 --height 1200)" && echo PARITY_FLOWFIELD_OK
                test "$(py_digest --seed 4294967295 --algo orbitwash --width 100 --height 4096)" = "$(js_digest --seed 4294967295 --algo orbitwash --width 100 --height 4096)" && echo PARITY_ORBITWASH_OK
                test "$(py_digest --seed 987654321 --algo flowfield --width 1200 --height 1200 --overrides '{"particles":100,"palette":1}')" = "$(js_digest --seed 987654321 --algo flowfield --width 1200 --height 1200 --overrides '{"particles":100,"palette":1}')" && echo PARITY_OVERRIDES_OK
                """,
                timeout: 300)
            try #require(parity.status == .ok
                            && parity.outputSummary.contains("PARITY_FLOWFIELD_OK")
                            && parity.outputSummary.contains("PARITY_ORBITWASH_OK")
                            && parity.outputSummary.contains("PARITY_OVERRIDES_OK"),
                         "digest parity failed: \(parity.outputSummary)")

            // 4. Four-file artifacts + guest determinism across runs.
            let generate = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "art-generate",
                command: """
                cd \(base)/algorithmic-art
                set -e
                PYTHONDONTWRITEBYTECODE=1 python3 scripts/generate_art.py --seed 987654321 --algo flowfield --width 1200 --height 1200 --outdir art-out --prefix study
                PYTHONDONTWRITEBYTECODE=1 python3 scripts/generate_art.py --seed 987654321 --algo flowfield --width 1200 --height 1200 --outdir art-out2 --prefix study
                for f in study.svg study.html study.primitives.json study.params.json; do
                  cmp "art-out/$f" "art-out2/$f"
                done
                echo ART_DETERMINISTIC
                """,
                timeout: 300)
            try #require(generate.status == .ok && generate.outputSummary.contains("ART_DETERMINISTIC"),
                         "art generation/determinism failed: \(generate.outputSummary)")
            for artifact in ["study.svg", "study.html", "study.primitives.json", "study.params.json"] {
                let url = root.appendingPathComponent("\(base)/algorithmic-art/art-out/\(artifact)")
                try #require(FileManager.default.fileExists(atPath: url.path),
                             "art artifact missing: \(artifact)")
            }

            // 5. Invalid inputs stay exit 2 (seed bound, geometry bound,
            //    overrides shape) — never a silent substitute.
            let negatives = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "art-negatives",
                command: """
                cd \(base)/algorithmic-art
                PYTHONDONTWRITEBYTECODE=1 python3 scripts/generate_art.py --seed 4294967296 --algo flowfield --width 100 --height 100 --outdir bad-seed --prefix bad; echo ART_BAD_SEED_RC=$?
                PYTHONDONTWRITEBYTECODE=1 python3 scripts/generate_art.py --seed 1 --algo flowfield --width 50 --height 100 --outdir bad-width --prefix bad; echo ART_BAD_WIDTH_RC=$?
                PYTHONDONTWRITEBYTECODE=1 python3 scripts/generate_art.py --seed 1 --algo flowfield --width 100 --height 100 --overrides '[1,2]' --outdir bad-overrides --prefix bad; echo ART_BAD_OVERRIDES_RC=$?
                """,
                timeout: 120)
            try #require(negatives.status == .ok
                            && negatives.outputSummary.contains("ART_BAD_SEED_RC=2")
                            && negatives.outputSummary.contains("ART_BAD_WIDTH_RC=2")
                            && negatives.outputSummary.contains("ART_BAD_OVERRIDES_RC=2"),
                         "invalid-input exit codes wrong: \(negatives.outputSummary)")

            // 6. --list-algos lists both algorithms.
            let algos = try await skillHubShell(
                runtime: runtime, identity: fixedIdentity, context: childContext, tag: "art-algos",
                command: "cd \(base)/algorithmic-art && PYTHONDONTWRITEBYTECODE=1 python3 scripts/generate_art.py --list-algos > algos.txt && grep -q flowfield algos.txt && grep -q orbitwash algos.txt && echo ART_ALGOS_OK",
                timeout: 120)
            try #require(algos.status == .ok && algos.outputSummary.contains("ART_ALGOS_OK"),
                         "--list-algos missing an algorithm: \(algos.outputSummary)")

            // 7. Shipped disclosures inside the self-contained study.html.
            let studyHTML = try String(contentsOf: root.appendingPathComponent(
                "\(base)/algorithmic-art/art-out/study.html"), encoding: .utf8)
            try #require(studyHTML.contains("About &amp; licenses"),
                         "study.html About & licenses disclosure missing")
            try #require(studyHTML.contains("artifact-notices")
                            && studyHTML.contains("coreSha256") && studyHTML.contains("uiSha256")
                            && studyHTML.contains("digest"),
                         "study.html artifact-notices disclosures missing")
            evidence["artGuest"] = "node-check prng=bytes parity=3 det=4files negatives=2 algos=2 disclosures"
            print("FLOE_SEVEN_ART_GUEST prng=cmp parity=3 determinism=4files negatives=exit2")

            // 8. Native viewer: serve the real guest output statically.
            let port = Int.random(in: 20_000...45_000)
            let invocation = LocalServiceTool.Arguments(
                runtime: "static", entry: "transport/unpacked/algorithmic-art/art-out/study.html",
                arguments: nil, cwd: nil, port: port)
            let serviceJob = try await jobs.submit(
                runID: runID, toolCallID: "seven-art-viewer-" + UUID().uuidString,
                targetTool: "exec.localService", payloadJSON: JSONEncoder().encode(invocation),
                scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [],
                environmentID: environmentID, submissionSource: .nativeService, waitForCompletion: false)
            jobIDs.append(serviceJob.id)
            var progressSamples: [[String: String]] = []
            let preview = try await skillHubWaitPreview(
                jobs, id: serviceJob.id, samples: &progressSamples, timeout: 180)
            try #require(preview.host == "127.0.0.1" && preview.port == port,
                         "Preview must be the owned loopback endpoint, got \(preview)")

            let created = try await skillHubBrowserCall(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "art-create", tool: "browser.tab", arguments: ["action": "create"])
            let tabID = try #require(created.page?.tabs.first(where: { $0.isActive })?.id,
                                     "art tab create returned no active tab")
            tabs.append(tabID)
            try await skillHubBrowserCall(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "art-navigate", tool: "browser.navigate",
                arguments: ["url": preview.absoluteString, "tabID": tabID.uuidString])
            try await skillHubBrowserCall(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "art-load", tool: "browser.wait",
                arguments: ["tabID": tabID.uuidString, "condition": "load",
                            "timeoutMilliseconds": 15_000])

            // Initial viewer state: seed, ops status, artifact-notices digest.
            var page = try await skillHubObserve(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "art-observe", tabID: tabID)
            try #require(page.nodes.contains { $0.text == "987654321" },
                         "viewer seed display missing 987654321: \(page.nodes.map(\.text).joined(separator: " | ").prefix(400))")
            try #require(page.nodes.contains { $0.text.contains("1200x1200px") },
                         "viewer ops status missing 1200x1200px: \(page.nodes.map(\.text).joined(separator: " | ").prefix(400))")
            // The disclosure is immutable source provenance, not live viewer state.
            let noticeStart = try #require(studyHTML.range(of: #"<pre id="artifact-notices">"#))
            let noticeEnd = try #require(studyHTML.range(of: "</pre>", range: noticeStart.upperBound..<studyHTML.endIndex))
            let noticeBytes = Data(studyHTML[noticeStart.upperBound..<noticeEnd.lowerBound].utf8)
            let notice = try #require(try JSONSerialization.jsonObject(with: noticeBytes) as? [String: Any])
            let provenance = try #require(notice["provenance"] as? [String: Any])
            let params = try sevenDeepJSON(root, "art-out/study.params.json")
            let generatedOutput = try #require(params["output"] as? [String: Any])
            let sourceDigest = try #require(provenance["digest"] as? String)
            let generatedDigest = try #require(generatedOutput["digest"] as? String)
            try #require(sourceDigest.count == 64 && sourceDigest.allSatisfy { "0123456789abcdef".contains($0) }
                            && sourceDigest == generatedDigest,
                         "source provenance digest differs from guest output")
            let initialDigest = try await sevenDeepCanvasReadback(
                app: app, conversationID: conversationUUID, tabID: tabID, root: root, tag: "initial")

            // next → digest changes; ← prev returns the EXACT original digest:
            // the controls drive the real seeded engine reversibly.
            let nextRef = try skillHubFindRef(in: page, namePrefix: "next", role: "button")
            try await skillHubBrowserCall(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "art-seed-next", tool: "browser.click",
                arguments: ["tabID": tabID.uuidString, "ref": nextRef.ref,
                            "documentID": page.documentID])
            page = try await skillHubObserve(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "art-observe-next", tabID: tabID)
            try #require(page.nodes.contains { $0.text == "987654322" },
                         "seed-next did not advance the displayed seed")
            let nextDigest = try await sevenDeepCanvasReadback(
                app: app, conversationID: conversationUUID, tabID: tabID, root: root, tag: "next")
            try #require(nextDigest != initialDigest, "seed-next did not change the artwork digest")

            let prevRef = try skillHubFindRef(in: page, namePrefix: "← prev", role: "button")
            try await skillHubBrowserCall(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "art-seed-prev", tool: "browser.click",
                arguments: ["tabID": tabID.uuidString, "ref": prevRef.ref,
                            "documentID": page.documentID])
            page = try await skillHubObserve(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "art-observe-prev", tabID: tabID)
            try #require(page.nodes.contains { $0.text == "987654321" },
                         "seed-prev did not restore the displayed seed")
            let restoredDigest = try await sevenDeepCanvasReadback(
                app: app, conversationID: conversationUUID, tabID: tabID, root: root, tag: "restored")
            try #require(restoredDigest == initialDigest,
                         "seed-prev did not restore the exact original digest")

            // Download PNG control exists and stays functional after the
            // interactions (the in-app download target is outside the test
            // workspace; no artifact is claimed here — the full-size raster
            // truth is the canvas poster export control's honest outcome).
            let downloadRef = try skillHubFindRef(in: page, namePrefix: "Download PNG", role: "button")
            try await skillHubBrowserCall(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "art-download", tool: "browser.click",
                arguments: ["tabID": tabID.uuidString, "ref": downloadRef.ref,
                            "documentID": page.documentID])
            page = try await skillHubObserve(
                runtime: runtime, identity: fixedIdentity, context: childContext,
                tag: "art-observe-final", tabID: tabID)
            let finalDigest = try await sevenDeepCanvasReadback(
                app: app, conversationID: conversationUUID, tabID: tabID, root: root, tag: "after-download")
            try #require(finalDigest == initialDigest,
                         "viewer state corrupted after the download control click")
            evidence["artNative"] = "seed next/prev reversible actual canvas PNG; download control intact, file delivery unverified"
            evidence["artCanvasInitialSHA256"] = initialDigest
            evidence["artCanvasNextSHA256"] = nextDigest
            evidence["artCanvasRestoredSHA256"] = restoredDigest
            print("FLOE_SEVEN_ART_NATIVE seed=next/prev digest=reversible download=control-ok")

            await finish()
        } catch {
            evidence["failure"] = String(describing: error)
            skillHubFailureEvidence(evidence, root: root, label: "seven-deep-art")
            Issue.record("Seven-deep art qualification failed: \(error)")
            await finish()
        }
    }
}

// MARK: - Guest-local HTTP readiness diagnostic (proposal from job-717fcb8eeba940b3)

extension SubagentSimulatorExecutionTests {

    /// Bounded diagnostic for the recurring guest-local HTTP readiness failure
    /// (`app-tests-guest19-skill-webapp-real-browser-guest-summary.json` and
    /// `app-tests-repairguest18-...`: urllib self-fetch to the guest's own
    /// service times out while the host-side forward of the same port works).
    ///
    /// The test never touches host/device networking and leaks no secrets:
    /// proxy environment is scanned by KEY NAME ONLY. All timeouts are the
    /// original committed bounds (production-shape self-fetch keeps 8 s;
    /// extra matrix cells use 4 s; nothing is raised above the existing
    /// ceilings). It runs entirely through the real product surfaces:
    /// launched-App-graph `bootGuest`, `makeRuntime` + active parent,
    /// `skillHubShell` foreground `exec.shell`, the production
    /// `exec.localService` job and `jobs.cancel` — no new model-facing tool,
    /// no test-execution bypass, no host interpreter.
    ///
    /// It is a diagnostic: it classifies what it observes. It fails ONLY on
    /// product invariants (host readiness, non-empty foreground channel,
    /// cancelled-endpoint closure), never on a pre-repair negative, so a
    /// broken guest yields evidence, not a red herring.
    @Test("Guest-local HTTP readiness diagnostic",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_GUEST_LOCALHTTP_DIAGNOSTIC"] == "1"))
    func guestLocalHTTPReadinessDiagnostic() async throws {
        var evidence: [String: String] = ["kind": "guest-local-http-diagnostic-not-qualification"]
        let root = try makeWorkspaceRoot()
        var ownedEnvironmentID: String?
        var parentHold: CancellationToken?
        var ownedRuntime: FloeAgentRuntime?
        var parentTask: Task<Void, Error>?
        var jobIDs: [UUID] = []
        var identity: ChildExecutionIdentity?
        var context: ToolContext?
        let app = try await appQualificationEnvironment()
        let conversationID = UUID()
        let runID = UUID()
        var recordsCreated = false
        let fixedIdentity = ChildExecutionIdentity(
            parentRunID: runID, rootTaskID: conversationID, delegateCallID: "guest-http-diag")
        identity = fixedIdentity
        func finish() async {
            await skillHubCleanup(runtime: ownedRuntime, parentHold: parentHold,
                                  parentTask: parentTask, jobs: app.backgroundJobService,
                                  jobIDs: jobIDs, environmentID: ownedEnvironmentID, root: root,
                                  conversationID: recordsCreated ? conversationID : nil, app: app)
        }
        do {
            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID
            try await skillHubCreateRunRows(app: app, conversationID: conversationID, runID: runID,
                title: "Guest-local HTTP diagnostic",
                goal: "Classify the guest self-HTTP timeout cause; scripted parent")
            recordsCreated = true
            let jobs = try #require(app.backgroundJobService, "Production job service is unavailable")
            let hold = CancellationToken()
            parentHold = hold
            let ceiling: Set<String> = ["exec.shell", "jobs.status", "jobs.cancel"]
            let runtime = makeRuntime(
                root: root, conversationID: conversationID, runID: runID,
                allowedToolNames: ceiling, environmentID: environmentID,
                adapter: QualificationHoldingProviderAdapter(hold: hold))
            ownedRuntime = runtime
            parentTask = Task { try await runtime.start(goal: "Run the guest-local HTTP diagnostic") }
            try #require(await waitForAsync(timeout: 20) {
                if case .streamingModel = await runtime.state { return true }
                return false
            }, "Parent must be active before child exec execution")
            let childContext = ToolContext(
                runID: runID, scope: .local, allowedToolNames: ceiling,
                workspaceRootURL: root, cancellation: CancellationToken(),
                environmentID: environmentID, conversationID: conversationID)
            context = childContext
            try await requireQualifiedKernel(runtime: runtime, identity: fixedIdentity,
                                             context: childContext)

            // P0: actual runner binding. The shipped image identity used to be
            // claimed from the source plan; this is the live binary's truth.
            let p0 = try await skillHubShell(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "diag-p0",
                command: "uname -a; sha256sum /usr/local/bin/floe-exec 2>/dev/null || echo DIAG_RUNNER_HASH_MISSING; "
                    + "readlink /proc/1/exe 2>/dev/null || echo DIAG_PID1_EXE_UNREADABLE; "
                    + "tr '\\0' ' ' < /proc/cmdline; echo", timeout: 60)
            evidence["p0Runner"] = p0.outputSummary

            // P1: loopback state and routes. `ip route get 127.0.0.1` naming
            // eth0/via the gateway is the leak; `dev lo` is the healthy state.
            let p1Before = try await skillHubShell(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "diag-p1-before",
                command: "printf 'DIAG_LO_FLAGS='; cat /sys/class/net/lo/flags 2>/dev/null || echo missing; "
                    + "printf 'DIAG_LO_OPERSTATE='; cat /sys/class/net/lo/operstate 2>/dev/null || echo missing; "
                    + "grep -q -w 127.0.0.1 /proc/net/fib_trie 2>/dev/null && echo DIAG_127_IN_TRIE=yes || echo DIAG_127_IN_TRIE=no; "
                    + "if command -v ip >/dev/null 2>&1; then echo DIAG_IP=yes; ip -o link show lo 2>/dev/null; "
                    + "ip -o addr show 2>/dev/null; ip -o route get 127.0.0.1 2>/dev/null || echo DIAG_GET_127_FAIL; "
                    + "ip -o route get 10.0.2.15 2>/dev/null || echo DIAG_GET_15_FAIL; "
                    + "else echo DIAG_IP=no; fi", timeout: 60)
            evidence["p1InterfacesBefore"] = p1Before.outputSummary

            // P2: proxy exposure by key NAME only (never values).
            let p2 = try await skillHubShell(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "diag-p2-proxy",
                command: "env | cut -d= -f1 | grep -i proxy | sed 's/^/DIAG_PROXY_ENV_KEY=/'; "
                    + "echo DIAG_PROXY_ENV_SCAN_DONE", timeout: 30)
            evidence["p2ProxyEnvKeys"] = p2.outputSummary

            // P3: start a service through the REAL production supervisor path.
            // The entry mirrors the shipped fixture_server.py bind contract
            // (0.0.0.0 when FLOE_SERVICE_PORT is injected by the supervisor).
            let serverScript = """
            import json, os
            from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
            port = int(os.environ["FLOE_SERVICE_PORT"])
            bind = os.environ.get("FLOE_FIXTURE_BIND") or (
                "0.0.0.0" if os.environ.get("FLOE_SERVICE_PORT") else "127.0.0.1")
            class H(BaseHTTPRequestHandler):
                def do_GET(self):
                    if self.path == "/state":
                        body = json.dumps({"receipt": "diag", "bind": bind,
                                           "submissions": []}).encode()
                        self.send_response(200)
                        self.send_header("Content-Type", "application/json")
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                    else:
                        self.send_error(404)
                def log_message(self, *args):
                    pass
            server = ThreadingHTTPServer((bind, port), H)
            print("DIAG_BIND " + bind + " " + str(port), flush=True)
            server.serve_forever()
            """
            try Data(serverScript.utf8).write(to: root.appendingPathComponent("diag-http-svc.py"))
            let port = Int.random(in: 20_000...45_000)
            let invocation = LocalServiceTool.Arguments(runtime: "python",
                entry: "diag-http-svc.py", arguments: [], cwd: nil, port: port)
            let serviceJob = try await jobs.submit(
                runID: runID, toolCallID: "guest-http-diag-service-" + UUID().uuidString,
                targetTool: "exec.localService", payloadJSON: JSONEncoder().encode(invocation),
                scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [],
                environmentID: environmentID, submissionSource: .nativeService,
                waitForCompletion: false)
            jobIDs.append(serviceJob.id)
            evidence["serviceJobID"] = serviceJob.id.uuidString
            evidence["servicePort"] = String(port)
            var progressSamples: [[String: String]] = []
            let preview = try await skillHubWaitPreview(jobs, id: serviceJob.id,
                                                        samples: &progressSamples, timeout: 180)
            try #require(preview.host == "127.0.0.1" && preview.port == port,
                         "PreviewURL must be the owned loopback endpoint, got \(preview)")
            // Host-side baseline (the already-proven forward path): /state over
            // the 127.0.0.1 forward must answer while the guest self-fetch is
            // what previously hung. Bounded exactly like the committed tests
            // (3 s request / 5 s resource via skillHubFetch's ephemeral session).
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 3
            configuration.timeoutIntervalForResource = 5
            configuration.waitsForConnectivity = false
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let hostState = try await skillHubFetch(preview.appendingPathComponent("state"),
                                                    session: session)
            try #require(hostState.1.statusCode == 200
                            && String(decoding: hostState.0, as: UTF8.self).contains("\"bind\""),
                        "Host-side forward baseline must serve /state: \(hostState.1)")
            evidence["p3HostForward"] = "ok status=\(hostState.1.statusCode)"

            // P4+P5+P6 in one bounded guest script: self-connect matrix
            // BEFORE, owned in-guest loopback provisioning attempt (identical
            // ioctls to the runner's eth0 path; guest-local only), the same
            // matrix AFTER, plus the raw-socket discriminator and the
            // production-shape 8 s fetch. Every probe line is classified:
            // ok / refused / timeout / unreachable.
            let matrixScript = """
            import os, sys, socket, struct, fcntl, urllib.request, urllib.error
            port = int(sys.argv[1])
            def classify(exc):
                reason = exc
                if isinstance(exc, urllib.error.URLError):
                    reason = exc.reason
                if isinstance(reason, TimeoutError) or isinstance(reason, socket.timeout):
                    return "timeout"
                code = getattr(reason, "errno", None)
                if code == 111: return "refused"
                if code in (101, 113, 115): return "unreachable-%s" % code
                return "err-%s" % type(reason).__name__
            def http_probe(target, proxy, tmo):
                url = "http://%s:%d/state" % (target, port)
                try:
                    if proxy == "off":
                        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                        opener.open(url, timeout=tmo).read()
                    else:
                        urllib.request.urlopen(url, timeout=tmo).read()
                    return "ok"
                except Exception as exc:
                    return classify(exc)
            def raw_probe(target, tmo):
                sock = socket.socket()
                try:
                    sock.settimeout(tmo)
                    sock.connect((target, 9))
                    return "connected"
                except Exception as exc:
                    return classify(exc)
                finally:
                    sock.close()
            def matrix(phase):
                for target in ("127.0.0.1", "10.0.2.15"):
                    for proxy in ("off", "default"):
                        print("DIAG_PROBE phase=%s target=%s proxy=%s timeout=4 result=%s"
                              % (phase, target, proxy, http_probe(target, proxy, 4)), flush=True)
                print("DIAG_RAW phase=%s target=127.0.0.1 port=9 result=%s"
                      % (phase, raw_probe("127.0.0.1", 4)), flush=True)
            def lo_flags(op, value=None):
                name = b"lo" + b"\\x00" * 14
                if op == 0x8913:
                    buf = name + b"\\x00" * 24
                    return struct.unpack("16sH22s", fcntl.ioctl(SK, op, buf))[1]
                buf = struct.pack("16sH22s", name, value, b"\\x00" * 22)
                fcntl.ioctl(SK, op, buf)
                return None
            matrix("before")
            SK = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                before = lo_flags(0x8913)
                for op, ip in ((0x8916, "127.0.0.1"), (0x891C, "255.0.0.0")):
                    sa = struct.pack("HH4s8s", socket.AF_INET, 0, socket.inet_aton(ip), b"\\x00" * 8)
                    fcntl.ioctl(SK, op, b"lo" + b"\\x00" * 14 + sa + b"\\x00" * 8)
                lo_flags(0x8914, before | 1)
                after = lo_flags(0x8913)
                print("DIAG_REPAIR rc=0 lo_flags_before=%d lo_flags_after=%d up=%d"
                      % (before, after, after & 1), flush=True)
            except Exception as exc:
                print("DIAG_REPAIR rc=1 error=%s errno=%s"
                      % (type(exc).__name__, getattr(exc, "errno", "none")), flush=True)
            matrix("after")
            print("DIAG_PROD_SHAPE target=127.0.0.1 timeout=8 result=%s"
                  % http_probe("127.0.0.1", "default", 8), flush=True)
            """
            let p4 = try await skillHubShell(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "diag-p4-matrix",
                command: "PYTHONDONTWRITEBYTECODE=1 python3 - \(port) <<'PY'\n"
                    + matrixScript + "\nPY", timeout: 120)
            evidence["p4Matrix"] = p4.outputSummary
            let after127OK = p4.outputSummary.contains(
                "DIAG_PROBE phase=after target=127.0.0.1 proxy=off timeout=4 result=ok")
            let before127OK = p4.outputSummary.contains(
                "DIAG_PROBE phase=before target=127.0.0.1 proxy=off timeout=4 result=ok")
            if !p4.outputSummary.contains("DIAG_PROBE phase=before ")
                || !p4.outputSummary.contains("DIAG_PROBE phase=after ") {
                evidence["verdict"] = "inconclusive: the foreground command returned no complete matrix; "
                    + "loopback repair effect cannot be inferred from missing output"
            } else if before127OK {
                evidence["verdict"] = "loopback self-HTTP already healthy at probe time; "
                    + "the timeout cause is not lo state alone in this generation"
            } else if after127OK {
                evidence["verdict"] = "guest-local 127.0.0.1 self-HTTP restored by loopback "
                    + "provisioning only: missing lo bring-up/address is the confirmed cause"
            } else {
                evidence["verdict"] = "loopback provisioning did NOT restore self-HTTP: "
                    + "lo-down alone is insufficient; keep the p4Matrix classification as the lead"
            }

            // P5 channel isolation for the separate impeccable small-round1
            // empty-stdout finding: the driver-shaped foreground wrapper must
            // return its marker line while the real localService is running.
            // Strict by design — an empty result here reproduces the channel
            // defect with this harness as the witness.
            let p5 = try await skillHubShell(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "diag-p5-channel",
                command: "run_engine() { label=\"$1\"; shift; start=$(date +%s%N); "
                    + "\"$@\" >/dev/null 2>&1 & pid=$!; wait \"$pid\"; rc=$?; end=$(date +%s%N); "
                    + "echo \"FLOE_ENGINE label=$label rc=$rc elapsed_ms=$(( (end - start) / 1000000 )) vmhwm_kb=unavailable\"; }; "
                    + "run_engine diag-a python3 -c 'import time;time.sleep(1)'; "
                    + "run_engine diag-b python3 -c 'import time;time.sleep(1)'",
                timeout: 120)
            try #require(p5.status == .ok, "Foreground channel probe must run: \(p5.outputSummary)")
            try #require(p5.outputSummary.contains("FLOE_ENGINE label=diag-a ")
                            && p5.outputSummary.contains("FLOE_ENGINE label=diag-b "),
                         "Foreground exec.shell must return the driver markers while a localService runs (empty stdout here reproduces the small-round1 finding): \(p5.outputSummary.prefix(400))")
            evidence["p5ChannelForegroundWithService"] = "markers-present"

            // P6: production cancellation with endpoint closure (guest side
            // now checks the loopback target as the committed test does).
            let cancelCall = try toolCall(id: "diag-jobs-cancel", toolName: "jobs.cancel",
                arguments: try Self.json(["jobID": serviceJob.id.uuidString]))
            let cancelResult = await runtime.dispatchChildTool(cancelCall, identity: fixedIdentity,
                                                               childContext: childContext)
            try #require(cancelResult.status == .ok, "jobs.cancel dispatch failed: \(cancelResult.outputSummary)")
            let cancelled = try await skillHubWaitTerminal(jobs, id: serviceJob.id, seconds: 90)
            try #require(cancelled.state == .cancelled,
                         "cancellation did not settle honestly: \(cancelled.state.rawValue)")
            let deadState = try await skillHubShell(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "diag-state-dead",
                command: "python3 -c \"import sys,urllib.request;urllib.request.urlopen(sys.argv[1],timeout=4).read()\" "
                    + "'http://127.0.0.1:\(port)/state' && echo GUEST_STATE_STILL_REACHABLE",
                timeout: 30)
            try #require(deadState.status != .ok || !deadState.outputSummary.contains("GUEST_STATE_STILL_REACHABLE"),
                         "the cancelled service endpoint must not stay reachable inside the guest")
            let hostGone: Bool
            do { _ = try await skillHubFetch(preview.appendingPathComponent("state"), session: session); hostGone = false }
            catch { hostGone = true }
            try #require(hostGone, "the cancelled fixture endpoint must not stay reachable from the host")
            evidence["p6Cancellation"] = "settled-closed"

            let p1After = try await skillHubShell(runtime: runtime, identity: fixedIdentity,
                context: childContext, tag: "diag-p1-after",
                command: "printf 'DIAG_LO_FLAGS='; cat /sys/class/net/lo/flags 2>/dev/null || echo missing; "
                    + "grep -q -w 127.0.0.1 /proc/net/fib_trie 2>/dev/null && echo DIAG_127_IN_TRIE=yes || echo DIAG_127_IN_TRIE=no",
                timeout: 30)
            evidence["p1InterfacesAfterRepair"] = p1After.outputSummary

            evidence["diagnosticCompleted"] = "true"
            let evidenceRoot = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
                .appendingPathComponent("FloeAgent/QualificationEvidence/SkillHubGuest", isDirectory: true)
            try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
            let evidenceFile = evidenceRoot.appendingPathComponent("guest-http-diag-\(runID.uuidString).json")
            try JSONEncoder().encode(evidence).write(to: evidenceFile, options: .atomic)
            print("FLOE_GUEST_LOCALHTTP_DIAGNOSTIC_EVIDENCE=\(evidenceFile.path)")
            print("FLOE_GUEST_LOCALHTTP_DIAG verdict=\(evidence["verdict"]?.prefix(48) ?? "unset")")
            await finish()
        } catch {
            evidence["failure"] = String(describing: error)
            skillHubFailureEvidence(evidence, root: root, label: "guest-http-diag")
            Issue.record("Guest-local HTTP readiness diagnostic failed: \(error)")
            await finish()
        }
    }
}

#endif
