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
                while !hold.isCancelled && !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
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
        let environment = AppEnvironment.live()
        await environment.bootstrap()
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

    func skillHubServiceProgress(_ data: Data?) -> SkillHubServiceProgress? {
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
        runtime?.cancel()
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
        func finish() async {
            await skillHubCleanup(runtime: ownedRuntime, parentHold: parentHold,
                                  parentTask: parentTask, jobs: app?.backgroundJobService,
                                  jobIDs: jobIDs, environmentID: ownedEnvironmentID, root: root,
                                  conversationID: conversationID, app: app)
        }
        do {
            let environmentID = try await bootGuest(root: root)
            ownedEnvironmentID = environmentID
            let liveApp = AppEnvironment.live()
            app = liveApp
            try #require(liveApp.persistenceReady, "Production persistence bootstrap failed")
            let jobs = try #require(liveApp.backgroundJobService, "Production job service is unavailable")
            let runID = UUID()
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

            // 3. Hash-pinned offline installs (CPU-heavy -> background jobs).
            let pip = "env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/workspace/skill-env/home "
                + "PYTHONDONTWRITEBYTECODE=1 PIP_CONFIG_FILE=/dev/null python3 -u -m pip --isolated "
                + "--disable-pip-version-check --no-input --no-cache-dir install --no-index --require-hashes "
                + "--find-links /workspace/transport/unpacked/wheels --target /workspace/skill-env/site -r "
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

            // 4. SymPy verifier in the guest: derivative, exact roots, ODE
            //    residual and the remaining named checks; host re-reads the
            //    guest-written JSON artifact for the real result.
            let sympyRun = try await skillHubSubmitShell(
                jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                name: "sympy-verify", command: """
                set -e
                mkdir -p skill-out
                PYTHONPATH=/workspace/skill-env/site PYTHONDONTWRITEBYTECODE=1 \
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
            let sympyChecks = sympyReport?["results"] as? [String: Any] ?? [:]
            for name in ["derivative", "solve", "ode", "exact_rational", "integral", "simplify"] {
                try #require(sympyChecks[name] as? Bool == true, "SymPy check \(name) did not pass")
            }
            try #require(sympyChecks["version"] as? String == "1.14.0",
                         "Guest sympy version is not the pinned 1.14.0: \(String(describing: sympyChecks["version"]))")
            print("FLOE_SKILLHUB_SYMPY sha256=\(FloeDigest.sha256Hex(sympyBytes)) checks=derivative,solve,ode")

            // 5. Citation formatter + validator (offline scripts, owned jobs).
            let formatRun = try await skillHubSubmitShell(
                jobs: jobs, runID: runID, environmentID: environmentID, root: root,
                name: "format-bibtex", command: """
                set -e
                mkdir -p skill-out
                PYTHONPATH=/workspace/skill-env/site PYTHONDONTWRITEBYTECODE=1 \
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
                PYTHONPATH=/workspace/skill-env/site PYTHONDONTWRITEBYTECODE=1 \
                python3 skill-src/citation-management/scripts/validate_citations.py \
                skill-src/citation-management/assets/bibtex_template.bib --report skill-out/validation-report.json
                """, timeout: 300)
            jobIDs.append(validateRun)
            let validateJob = try await skillHubWaitTerminal(jobs, id: validateRun, seconds: 360)
            evidence["validateCitations"] = validateJob.resultSummary ?? validateJob.lastError ?? validateJob.state.rawValue
            try #require(validateJob.state == .completed,
                         "Guest citation validator failed (high-severity findings keep the original non-zero exit): "
                             + "\(evidence["validateCitations"] ?? "unknown")")
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
                PYTHONPATH=/workspace/skill-env/site PYTHONDONTWRITEBYTECODE=1 \
                python3 skill-src/citation-management/scripts/search_openalex.py "CRISPR gene editing" \
                --limit 5 -o skill-out/openalex.json
                """, timeout: 300)
            jobIDs.append(openAlexRun)
            let openAlexJob = try await skillHubWaitTerminal(jobs, id: openAlexRun, seconds: 360)
            evidence["openalex"] = openAlexJob.resultSummary ?? openAlexJob.lastError ?? openAlexJob.state.rawValue
            try #require(openAlexJob.state == .completed,
                         "Keyless OpenAlex first-page lookup failed in the guest (no fallback is allowed): "
                             + "\(evidence["openalex"] ?? "unknown")")
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
                PYTHONPATH=/workspace/skill-env/site PYTHONDONTWRITEBYTECODE=1 \
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
            await finish()
        } catch {
            evidence["failure"] = String(describing: error)
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

/// Authoritative fixture-server `/state` document (guest loopback 10.0.2.15).
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

    func skillHubDecodeBrowser(_ result: ToolResult) throws -> SkillHubBrowserResult {
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
    func skillHubObserve(
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

    func skillHubFindRef(
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
    func skillHubBrowserCall(
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
    func skillHubWaitText(
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
            + "'http://10.0.2.15:\(port)/\(path)'"
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
                command: "python3 -c \"import sys,urllib.request;urllib.request.urlopen(sys.argv[1],timeout=4).read()\" 'http://10.0.2.15:\(port)/state' && echo GUEST_STATE_STILL_REACHABLE",
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
            let liveApp = AppEnvironment.live()
            app = liveApp
            try #require(liveApp.persistenceReady, "Production persistence bootstrap failed")
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
//     (3,376,092 bytes, sha256 7b09d78470e4df3cffe3d015a995489f07ae5bd565d1e42d7e851ff0c7310aa0,
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
        "7b09d78470e4df3cffe3d015a995489f07ae5bd565d1e42d7e851ff0c7310aa0"
    static let transportZipBytes = 3_376_092
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
    func impeccableReadResult(_ root: URL, _ relative: String) throws -> ImpeccableEngineResult {
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
                        ImpeccableInputs.fixtureNoAnswerFactsSHA256, ImpeccableInputs.goldenOverlayRound1SHA256,
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

            // 6. v1 never certifies clean: answering nothing is still inconclusive.
            let noClean = try await impeccableEngineRun(
                runtime: runtime, identity: fixedIdentity, context: context, tag: "golden-noclean",
                label: "golden-noclean",
                arguments: ["transport/unpacked/engine/floe-impeccable", "snapshot-scan",
                            "--snapshot", "transport/unpacked/contract/fixtures/snapshot-needs-hit-tests.v1.json",
                            "--identity", "transport/unpacked/contract/fixtures/identity-needs.v1.json",
                            "--facts", "transport/unpacked/contract/fixtures/facts-hit-tests.v1.json",
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
                transport/unpacked/engine/floe-impeccable engine-probe
                transport/unpacked/engine/floe-impeccable contract | sha256sum
                chmod +x transport/unpacked/engine/floe-impeccable
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
                    loopEvidence["round1ElapsedMS"] = String(round1.elapsedMS)
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
                loopEvidence["round1ElapsedMS"] = String(round1.elapsedMS)
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
                loopEvidence["round2ElapsedMS"] = String(round2.elapsedMS)
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

#endif
