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
#endif
