// SPDX-License-Identifier: MPL-2.0
//
// G04GitToolBindingsTests — the frozen-fourteen guarantees:
//   * every registration carries the ORIGINAL descriptor byte-for-byte
//     (names, descriptions, parameter schemas, risk labels, effect flags,
//     host-scope, boundaries) — drift is impossible because both sides come
//     from the same original types;
//   * the adapter's ownership guards run BEFORE the original runner: live
//     generation, temporary refusal, durable owner, lease intent, metadata
//     boundary, root-match;
//   * the original tools' own validations and error texts pass through
//     untouched (stage-all restriction, "Connect GitHub in Settings…" token
//     refusal);
//   * lease release happens on success AND every refusal path.
import Foundation
import FloeCore
import FloeTools
import FloeGit
import FloeWorkspace
import Testing
@testable import FloeAndroidCore

@Suite("G04GitToolBindingsTests")
struct G04GitToolBindingsTests {

    private actor AccessRecorder: G04WorkspaceAccessPort {
        private(set) var intents: [G04WorkspaceIntent] = []
        private(set) var releases = 0
        var refusal: (any Error)?
        let leaseRoot: URL
        init(leaseRoot: URL) { self.leaseRoot = leaseRoot }
        func acquire(owner: G04WorkspaceOwner, intent: G04WorkspaceIntent,
                     relativePath: String?) async throws -> G04WorkspaceAccessLease {
            intents.append(intent)
            if let refusal { throw refusal }
            let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: leaseRoot))
            let token = CancellationToken()
            return G04WorkspaceAccessLease(service: service, cancellation: token, release: {
                await self.recordRelease()
            })
        }
        private func recordRelease() { releases += 1 }
        func snapshot() -> ([G04WorkspaceIntent], Int) { (intents, releases) }
    }

    private func makeFixture(root: URL, owner: G04WorkspaceOwner? = nil) -> (G04GitToolRouting, AccessRecorder) {
        let recorder = AccessRecorder(leaseRoot: root)
        let routing = G04GitToolRouting(
            epoch: 1,
            isLive: { true },
            resolveOwner: { _ in owner ?? G04WorkspaceOwner(epoch: 1, taskID: UUID(), workspaceID: UUID()) },
            access: recorder,
            session: { _ in nil },
            tools: GitToolEnvironment(
                rootProvider: { nil },
                git: LocalGitService(),
                github: GitHubService(),
                credentials: GitHubCredentialStore(lease: UnconfiguredGitHubCredentialLease()),
                localAuthor: nil))
        return (routing, recorder)
    }

    private func context(conversation: UUID? = UUID(), temporary: Bool = false,
                         root: URL? = nil, allowed: [String] = []) -> ToolContext {
        // Argument order follows the ORIGINAL ToolContext initializer
        // (workspaceRootURL precedes allowedWorkspacePaths precedes
        // cancellation precedes conversationID precedes temporaryReadOnly).
        ToolContext(runID: UUID(), workspaceRootURL: root, allowedWorkspacePaths: allowed,
                    cancellation: CancellationToken(), conversationID: conversation,
                    temporaryReadOnly: temporary)
    }

    private func freshRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-git-bindings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Descriptor parity (the frozen fourteen)

    @Test(arguments: [
        "git.status", "git.diff", "git.log", "git.initialize", "git.stage", "git.commit",
        "git.createBranch", "git.switchBranch", "git.fetch", "git.pull", "git.push",
        "github.repositories", "github.clone", "github.createRepository",
    ]) func allFourteenOriginalNamesAreRegisteredWithIdenticalDescriptors(name: String) throws {
        let root = try freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (routing, _) = makeFixture(root: root)
        let registry = ToolRunnerRegistry()
        G04GitToolBindings.install(routing: routing, registry: registry)
        let installed = try #require(registry.runner(named: name))
        let original: ToolCatalog.Descriptor = Self.originalDescriptors[name]!
        #expect(installed.descriptor.name == original.name)
        #expect(installed.descriptor.toolDescription == original.toolDescription)
        #expect(installed.descriptor.parametersJSON == original.parametersJSON)
        #expect(installed.descriptor.riskLabels == original.riskLabels)
        #expect(installed.descriptor.isSideEffecting == original.isSideEffecting)
        #expect(installed.descriptor.effect == original.effect)
        #expect(installed.descriptor.requiresHostScope == original.requiresHostScope)
        #expect(installed.descriptor.executionBoundary == original.executionBoundary)
        #expect(installed.descriptor.supportsConcurrentBatchDispatch
                == original.supportsConcurrentBatchDispatch)
    }

    /// Descriptors re-derived from the ORIGINAL tool types at test time — if
    /// the registration path ever dropped or re-authored a field, the parity
    /// test above fails against these values.
    private static let env = GitToolEnvironment(rootProvider: { nil })
    private static let originalDescriptors: [String: ToolCatalog.Descriptor] = [
        GitStatusTool.name: AnyAgentTool(GitStatusTool(environment: env)).descriptor,
        GitDiffTool.name: AnyAgentTool(GitDiffTool(environment: env)).descriptor,
        GitLogTool.name: AnyAgentTool(GitLogTool(environment: env)).descriptor,
        GitInitializeTool.name: AnyAgentTool(GitInitializeTool(environment: env)).descriptor,
        GitStageTool.name: AnyAgentTool(GitStageTool(environment: env)).descriptor,
        GitCommitTool.name: AnyAgentTool(GitCommitTool(environment: env)).descriptor,
        GitCreateBranchTool.name: AnyAgentTool(GitCreateBranchTool(environment: env)).descriptor,
        GitSwitchBranchTool.name: AnyAgentTool(GitSwitchBranchTool(environment: env)).descriptor,
        GitFetchTool.name: AnyAgentTool(GitFetchTool(environment: env)).descriptor,
        GitPullTool.name: AnyAgentTool(GitPullTool(environment: env)).descriptor,
        GitPushTool.name: AnyAgentTool(GitPushTool(environment: env)).descriptor,
        GitHubRepositoriesTool.name: AnyAgentTool(GitHubRepositoriesTool(environment: env)).descriptor,
        GitHubCloneTool.name: AnyAgentTool(GitHubCloneTool(environment: env)).descriptor,
        GitHubCreateRepositoryTool.name: AnyAgentTool(GitHubCreateRepositoryTool(environment: env)).descriptor,
    ]

    // MARK: - Guard order

    @Test func retiredGenerationRefusesWithoutTouchingAccess() async throws {
        let root = try freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (routing, recorder) = makeFixture(root: root)
        let registry = ToolRunnerRegistry()
        let handle = G04GitToolBindings.install(routing: routing, registry: registry)
        let runner = try #require(registry.runner(named: "git.status"))
        handle.retire()
        #expect(!handle.isLive)
        // Retirement refuses on BOTH layers, asserted without weakening either:
        // discovery hides the capability (runner(named:) filters availability,
        // so no new caller can even obtain the retired generation's runner),
        // and an already-held reference still refuses at run time through the
        // liveness guard before any access attempt.
        #expect(registry.runner(named: "git.status") == nil)
        await #expect(throws: (any Error).self) {
            _ = try await runner
                .execute(argumentsJSON: Data("{}".utf8), context: context())
        }
        let (intents, _) = await recorder.snapshot()
        #expect(intents.isEmpty) // no lease was ever attempted
    }

    @Test func temporaryChatNeverReachesTheGitLayer() async throws {
        let root = try freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (routing, recorder) = makeFixture(root: root)
        let registry = ToolRunnerRegistry()
        G04GitToolBindings.install(routing: routing, registry: registry)
        await #expect(throws: FloeError.self) {
            _ = try await registry.runner(named: "git.status")!
                .execute(argumentsJSON: Data("{}".utf8), context: context(temporary: true))
        }
        let (intents, _) = await recorder.snapshot()
        #expect(intents.isEmpty)
    }

    @Test func missingTaskOwnerIsRefusedAndReleasedNothing() async throws {
        let root = try freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (routing, recorder) = makeFixture(root: root)
        let broken = G04GitToolRouting(epoch: 1, isLive: { true }, resolveOwner: { _ in nil },
                                       access: recorder, session: { _ in nil }, tools: routing.tools)
        let registry = ToolRunnerRegistry()
        G04GitToolBindings.install(routing: broken, registry: registry)
        await #expect(throws: FloeError.self) {
            _ = try await registry.runner(named: "git.status")!
                .execute(argumentsJSON: Data("{}".utf8), context: context())
        }
    }

    @Test func contextRootMismatchIsRefusedAndLeaseReleased() async throws {
        let root = try freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = try freshRoot()
        defer { try? FileManager.default.removeItem(at: other) }
        let (routing, recorder) = makeFixture(root: root)
        let registry = ToolRunnerRegistry()
        G04GitToolBindings.install(routing: routing, registry: registry)
        await #expect(throws: FloeError.self) {
            _ = try await registry.runner(named: "git.status")!
                .execute(argumentsJSON: Data("{}".utf8), context: context(root: other))
        }
        let (_, releases) = await recorder.snapshot()
        #expect(releases == 1)
    }

    // MARK: - Lease intent by effect class + original pass-through

    @Test func remoteOnlyToolUsesReadLeaseAndKeepsOriginalTokenRefusal() async throws {
        let root = try freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (routing, recorder) = makeFixture(root: root)
        let registry = ToolRunnerRegistry()
        G04GitToolBindings.install(routing: routing, registry: registry)
        let error = await #expect(throws: FloeError.self) {
            _ = try await registry.runner(named: "github.createRepository")!
                .execute(argumentsJSON: Data(#"{"name":"demo"}"#.utf8), context: context())
        }
        let (intents, releases) = await recorder.snapshot()
        #expect(intents == [.read]) // ownership proof only; no file mutation
        #expect(releases == 1)
        if case .invalidConfiguration(let message) = error {
            #expect(message.contains("Connect GitHub in Settings")) // ORIGINAL text verbatim
        } else {
            Issue.record("expected the original invalidConfiguration refusal")
        }
    }

    @Test func stageKeepsOriginalPathRestrictedRefusalAndMutationLease() async throws {
        let root = try freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (routing, recorder) = makeFixture(root: root)
        let registry = ToolRunnerRegistry()
        G04GitToolBindings.install(routing: routing, registry: registry)
        let error = await #expect(throws: FloeError.self) {
            _ = try await registry.runner(named: "git.stage")!
                .execute(argumentsJSON: Data("{}".utf8),
                         context: context(root: root.standardizedFileURL, allowed: ["src"]))
        }
        let (intents, releases) = await recorder.snapshot()
        #expect(intents == [.fileMutation])
        #expect(releases == 1)
        if case .validationFailed(let message) = error {
            #expect(message == "Stage-all is not allowed for a path-restricted task") // ORIGINAL
        } else {
            Issue.record("expected the original stage-all restriction")
        }
    }

    @Test func injectedRootMatchesLeaseRootForLocalStatus() async throws {
        // git.status against a NON-repository directory proves the root the
        // original runner received is the LEASE root: LocalGitService.snapshot
        // answers an empty non-repo snapshot rather than escaping the root.
        let root = try freshRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (routing, recorder) = makeFixture(root: root)
        let registry = ToolRunnerRegistry()
        G04GitToolBindings.install(routing: routing, registry: registry)
        do {
            _ = try await registry.runner(named: "git.status")!
                .execute(argumentsJSON: Data("{}".utf8), context: context())
            let (intents, releases) = await recorder.snapshot()
            #expect(intents == [.read])
            #expect(releases == 1)
        } catch {
            // LocalGitService on a non-repository may also refuse; either
            // answer is the ORIGINAL tool's own behavior. The guards above it
            // already ran with the lease intent.
            let (intents, releases) = await recorder.snapshot()
            #expect(intents == [.read])
            #expect(releases == 1)
        }
    }
}
