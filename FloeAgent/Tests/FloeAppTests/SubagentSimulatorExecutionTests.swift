// FloeAppTests — delegated-child execution through the real App composition.
//
// This is the App-level counterpart of the runtime package dispatch tests: a
// delegated child's calls run through the REAL `FloeAgentRuntime
// .dispatchChildTool` chain (catalog, effective ceiling, main-only boundary,
// approval policy, mutation lease, the same executor) and the executed tools
// are the App's REAL registered `exec.shell` / `exec.localPython`, routed by
// the production `ToolEnvironmentRouting` into the TinyEMU Linux guest
// prepared by the production platform services. A host-side Python or mock
// backend is never accepted: the file is written by the guest and the hash is
// computed in the guest, then verified from the host filesystem.
//
// The main-only boundary is exercised in the same composition: `delegate` and
// `conversation.spawn` are refused for a delegated child identity, and the
// App's compiled browser toolchain is exercised too — human takeover denies
// mutating browser interaction while read-only inspection continues.
//
// The real-guest test is opt-in (`FLOE_REALVM_QUALIFICATION=1`) because a
// first run downloads and boots the pinned guest image; a plain disabled run
// is reported as disabled, never as a pass.

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

/// An adapter that is never used: this test drives the canonical child
/// dispatcher directly and never enters the provider loop.
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

private actor DiscardingAuditSink: AuditSink {
    func record(_ entry: AuditEntry) async throws {}
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

    private func makeRuntime(
        root: URL,
        conversationID: UUID,
        runID: UUID,
        allowedToolNames: Set<String>
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
                workspaceRootURL: root
            ),
            adapter: UnusedProviderAdapter(),
            policy: FullControlPolicy(grant: .init(hostID: UUID(), expiresAt: nil)),
            executor: CatalogToolExecutor(),
            auditSink: DiscardingAuditSink(),
            checkpointStore: EphemeralCheckpointStore(),
            runID: runID
        )
    }

    @Test(
        "delegated execute child runs real guest Shell and Python, writes a file and returns the guest hash",
        .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_QUALIFICATION"] == "1")
    )
    func childGuestShellAndPythonEndToEnd() async throws {        let environment = AppEnvironment.live()
        await environment.bootstrap()
        let services = FloePlatformServices.shared
        let root = try makeWorkspaceRoot()
        var ownedEnvironmentID = ""

        func cleanup() async {
            if !ownedEnvironmentID.isEmpty {
                try? await services.stopEnvironment(id: ownedEnvironmentID)
            }
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try await services.prepareWorkspaceEnvironment(root: root)
            guard let environmentID = await environmentID(
                forRoot: root, registry: environment.environmentRegistry
            ) else {
                Issue.record("No Linux project environment exists for this test's workspace root")
                await cleanup()
                return
            }
            ownedEnvironmentID = environmentID
            try await services.activateLinuxGuestWithPreparation(
                id: environmentID, cancellation: CancellationToken())
            let ready = await waitForAsync(timeout: bootTimeout) {
                await services.linuxEnvironmentAvailable(id: environmentID)
            }
            guard ready else {
                let status = await services.linuxEnvironmentStatus(id: environmentID)
                Issue.record("Linux guest never became available: \(String(describing: status))")
                await cleanup()
                return
            }

            let conversationID = UUID()
            let runID = UUID()
            let ceiling: Set<String> = ["exec.shell", "exec.localPython", "delegate", "conversation.spawn"]
            let runtime = makeRuntime(
                root: root, conversationID: conversationID, runID: runID, allowedToolNames: ceiling
            )
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

            // 1. exec.shell: the GUEST writes the file and computes the hash.
            let payload = "hello from the guest child"
            let expectedHash = FloeDigest.sha256Hex(Data(payload.utf8))
            let shellCall = try ToolCall(
                id: "child-shell-1",
                toolName: "exec.shell",
                argumentsJSON: Data(#"{"command":"mkdir -p child && printf 'hello from the guest child' > child/out.txt && sha256sum child/out.txt"}"#.utf8),
                scope: .local
            ).withIDContext(runID: runID)
            let shellResult = await runtime.dispatchChildTool(
                shellCall, identity: firstChild, childContext: childContext
            )
            #expect(shellResult.status == .ok, "child exec.shell failed: \(shellResult.outputSummary)")
            #expect(shellResult.outputSummary.contains(expectedHash),
                    "guest sha256sum output missing from: \(shellResult.outputSummary)")

            // Host-side verification of the guest's real side effect.
            let written = try Data(contentsOf: root.appendingPathComponent("child/out.txt"))
            #expect(String(decoding: written, as: UTF8.self) == payload)
            #expect(FloeDigest.sha256Hex(written) == expectedHash)

            // 2. exec.localPython: the GUEST reads the file and reports the
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
            let pythonCall = try ToolCall(
                id: "child-python-1",
                toolName: "exec.localPython",
                argumentsJSON: try JSONSerialization.data(withJSONObject: ["script": pythonScript]),
                scope: .local
            ).withIDContext(runID: runID)
            let pythonResult = await runtime.dispatchChildTool(
                pythonCall, identity: firstChild, childContext: childContext
            )
            #expect(pythonResult.status == .ok, "child exec.localPython failed: \(pythonResult.outputSummary)")
            #expect(pythonResult.outputSummary.contains("FLOE_CHILD_PY_READ=\(payload)"))
            #expect(pythonResult.outputSummary.contains("FLOE_CHILD_PY_HASH=\(expectedHash)"))
            #expect(pythonResult.outputSummary.contains("FLOE_CHILD_PY_PLATFORM=linux"))

            // 3. Two live sibling children (different canonical targets) run
            //    through the same runtime; the mutation lease keeps each
            //    target serialized while both really execute.
            let sibling = ChildExecutionIdentity(
                parentRunID: runID, rootTaskID: conversationID, delegateCallID: "delegate-sibling"
            )
            let siblingCallA = try ToolCall(
                id: "child-shell-a",
                toolName: "exec.shell",
                argumentsJSON: Data(#"{"command":"mkdir -p siblings && printf 'a' > siblings/a.txt && echo SIBLING_A_OK"}"#.utf8),
                scope: .local
            ).withIDContext(runID: runID)
            let siblingCallB = try ToolCall(
                id: "child-shell-b",
                toolName: "exec.shell",
                argumentsJSON: Data(#"{"command":"mkdir -p siblings && printf 'b' > siblings/b.txt && echo SIBLING_B_OK"}"#.utf8),
                scope: .local
            ).withIDContext(runID: runID)
            async let siblingA = runtime.dispatchChildTool(
                siblingCallA, identity: sibling, childContext: childContext
            )
            async let siblingB = runtime.dispatchChildTool(
                siblingCallB, identity: sibling, childContext: childContext
            )
            let (resultA, resultB) = await (siblingA, siblingB)
            #expect(resultA.status == .ok && resultB.status == .ok)
            let siblingABytes = try Data(contentsOf: root.appendingPathComponent("siblings/a.txt"))
            let siblingBBytes = try Data(contentsOf: root.appendingPathComponent("siblings/b.txt"))
            #expect(String(decoding: siblingABytes, as: UTF8.self) == "a")
            #expect(String(decoding: siblingBBytes, as: UTF8.self) == "b")

            // 4. The main-only callable boundary through the real App
            //    composition: a delegated child can never delegate or spawn.
            let delegateCall = try ToolCall(
                id: "child-delegate-1",
                toolName: "delegate",
                argumentsJSON: Data(#"{"task":"nested"}"#.utf8),
                scope: .local
            ).withIDContext(runID: runID)
            let deniedDelegate = await runtime.dispatchChildTool(
                delegateCall, identity: firstChild, childContext: childContext
            )
            #expect(deniedDelegate.status == .denied)
            let spawnCall = try ToolCall(
                id: "child-spawn-1",
                toolName: "conversation.spawn",
                argumentsJSON: Data(#"{"title":"nested","objective":"nested"}"#.utf8),
                scope: .local
            ).withIDContext(runID: runID)
            let deniedSpawn = await runtime.dispatchChildTool(
                spawnCall, identity: firstChild, childContext: childContext
            )
            #expect(deniedSpawn.status == .denied)

            await cleanup()
        } catch {
            Issue.record("child guest execution threw: \(error)")
            await cleanup()
        }
    }

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
}
#endif
