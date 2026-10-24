// SPDX-License-Identifier: MPL-2.0
//
// G04GitToolBindings — the Root-bound composition for the ORIGINAL fourteen
// FloeGit model tools (git.status/git.diff/git.log/git.initialize/git.stage/
// git.commit/git.createBranch/git.switchBranch/git.fetch/git.pull/git.push/
// github.repositories/github.clone/github.createRepository).
//
// The frozen 14 names, descriptions, parameter schemas, risk labels, side
// effect flags, host-scope requirements, argument validation, workspace-path
// authorization (context.authorizeWorkspacePaths/allowedWorkspacePaths),
// stage-all restriction, clone containment and output digests are EXACTLY
// the originals: each runner is type-erased through the standard
// `AnyAgentTool(_ tool:)` initializer of the real tool type, and the
// composition registers the resulting descriptor verbatim through the
// ORIGINAL `ToolCatalog` + `ToolRunnerRegistry` lifecycle. No schema is
// re-authored here, so schema drift is impossible by construction.
//
// What this adapter adds is the G04 ownership chain a raw
// `registerGitTools(environment:)` would bypass:
//   * every call resolves the durable owner (ordinary conversation purpose +
//     the exact ORIGINAL private-task workspace binding) from the accepted
//     store cluster — payloads and model output never supply a root;
//   * the ORIGINAL `G04WorkspaceAccessPort` operation lease is acquired for
//     the call (read vs fileMutation by the tool's real effect class);
//   * `G04GitMetadataBoundary` validates `.git` containment before any run;
//   * working-tree writers (`git.switchBranch`, `git.pull`) additionally pass
//     MAIN's document mutation barrier, so a switch/merge can never strand
//     unsaved native drafts and the editor re-reads honestly afterwards;
//   * `context.workspaceRootURL` is verified equal to the resolved lease root
//     and injected when the runtime carried none — a stale or foreign run
//     root is refused, never silently replaced;
//   * temporary (ephemeral) runs are refused outright; a retired generation
//     stops advertising these names runnable through the same `isAvailable`
//     liveness mirror the accepted browser composition uses;
//   * local identity stays the ORIGINAL offline fallback — the adapter never
//     turns commit into a network or vault operation.
import Foundation
import FloeCore
import FloeTools
import FloeGit
import FloeWorkspace

/// All fourteen originals share this construction surface; the conformance
/// is declarative only (no behavior), so `bind` can be generic over it.
private protocol GitComposedAgentTool: AgentTool {
    init(environment: GitToolEnvironment)
}
extension GitStatusTool: GitComposedAgentTool {}
extension GitDiffTool: GitComposedAgentTool {}
extension GitLogTool: GitComposedAgentTool {}
extension GitInitializeTool: GitComposedAgentTool {}
extension GitStageTool: GitComposedAgentTool {}
extension GitCommitTool: GitComposedAgentTool {}
extension GitCreateBranchTool: GitComposedAgentTool {}
extension GitSwitchBranchTool: GitComposedAgentTool {}
extension GitFetchTool: GitComposedAgentTool {}
extension GitPullTool: GitComposedAgentTool {}
extension GitPushTool: GitComposedAgentTool {}
extension GitHubRepositoriesTool: GitComposedAgentTool {}
extension GitHubCloneTool: GitComposedAgentTool {}
extension GitHubCreateRepositoryTool: GitComposedAgentTool {}

/// Trusted routing facts for one accepted generation. Installed ONLY by the
/// live facade; a retired mirror makes all fourteen names honestly
/// non-runnable (no silent fall-through into a newer generation's services).
struct G04GitToolRouting: Sendable {
    let epoch: UInt64
    /// Synchronous liveness mirror (retirement + exact installed identity).
    let isLive: @Sendable () -> Bool
    /// The ORIGINAL durable ownership resolution: ordinary conversation +
    /// exact workspace binding + private-task kind. nil = no admitted owner.
    let resolveOwner: @Sendable (UUID) async -> G04WorkspaceOwner?
    /// The ONE real access port; attaches the original conversation-owned
    /// operation lease around every Git effect.
    let access: any G04WorkspaceAccessPort
    /// MAIN's document session for the SAME admitted owner (used only by the
    /// working-tree-barrier tools; nil means no live session → refuse).
    let session: @Sendable (G04WorkspaceOwner) async -> G04WorkspaceDocumentSession?
    /// The already-bound native services: one LocalGitService, one
    /// GitHubService and ONE vault-backed credential lease per generation.
    /// `rootProvider` is deliberately `{ nil }`: the ONLY root is the lease
    /// root the adapter injects into the context per call.
    let tools: GitToolEnvironment
}

enum G04GitToolBindings {
    /// Retirement handle. Retiring flips the liveness mirror BEFORE runners
    /// stop being callable through it; the registry entries themselves are
    /// replaced (not resurrected) by the next generation's install.
    struct Handle: Sendable {
        fileprivate let live: G04GitToolLiveness
        func retire() { live.set(false) }
        var isLive: Bool { live.get() }
    }

    /// Effect classes of the frozen fourteen (verified against each original
    /// descriptor's risk labels — this chooses the G04 LEASE intent and the
    /// document barrier, nothing model-facing):
    ///   * `.read` lease: status/diff/log/repositories/createRepository
    ///     (createRepository is a pure remote create; the lease is the
    ///     ownership proof only);
    ///   * `.fileMutation` lease: initialize/stage/commit/createBranch/
    ///     switchBranch/fetch/pull/push/clone;
    ///   * document mutation barrier: switchBranch + pull — exactly the
    ///     working-tree writers from the accepted `actions.*` wire set.
    private enum Effect { case read, file, fileBarrier }
    private static func effect(for name: String) -> Effect {
        switch name {
        case "git.status", "git.diff", "git.log", "github.repositories", "github.createRepository":
            return .read
        case "git.switchBranch", "git.pull":
            return .fileBarrier
        default:
            return .file
        }
    }

    @discardableResult
    static func install(routing: G04GitToolRouting, registry: ToolRunnerRegistry = .shared) -> Handle {
        let live = G04GitToolLiveness(true)
        let isLive: @Sendable () -> Bool = { [live] in live.get() && routing.isLive() }
        bind(GitStatusTool.self, routing: routing, live: isLive, registry: registry)
        bind(GitDiffTool.self, routing: routing, live: isLive, registry: registry)
        bind(GitLogTool.self, routing: routing, live: isLive, registry: registry)
        bind(GitInitializeTool.self, routing: routing, live: isLive, registry: registry)
        bind(GitStageTool.self, routing: routing, live: isLive, registry: registry)
        bind(GitCommitTool.self, routing: routing, live: isLive, registry: registry)
        bind(GitCreateBranchTool.self, routing: routing, live: isLive, registry: registry)
        bind(GitSwitchBranchTool.self, routing: routing, live: isLive, registry: registry)
        bind(GitFetchTool.self, routing: routing, live: isLive, registry: registry)
        bind(GitPullTool.self, routing: routing, live: isLive, registry: registry)
        bind(GitPushTool.self, routing: routing, live: isLive, registry: registry)
        bind(GitHubRepositoriesTool.self, routing: routing, live: isLive, registry: registry)
        bind(GitHubCloneTool.self, routing: routing, live: isLive, registry: registry)
        bind(GitHubCreateRepositoryTool.self, routing: routing, live: isLive, registry: registry)
        return Handle(live: live)
    }

    private static func bind<T: GitComposedAgentTool>(
        _ type: T.Type, routing: G04GitToolRouting,
        live: @escaping @Sendable () -> Bool, registry: ToolRunnerRegistry
    ) {
        // The ORIGINAL type-erased tool: descriptor fields, decoding and the
        // actionable decode-error text are exactly what the original
        // registration path would install.
        let original = AnyAgentTool(T(environment: routing.tools))
        let name = original.descriptor.name
        let effectClass = effect(for: name)
        ToolCatalog.register(T.self)
        registry.register(AnyAgentTool(
            descriptor: original.descriptor,
            run: { argumentsJSON, context in
                try await guarded(original: original.run, effect: effectClass,
                                  routing: routing, live: live,
                                  argumentsJSON: argumentsJSON, context: context)
            },
            validateArguments: original.validateArguments
        ).withAvailability(live))
    }

    /// One guard pipeline for every frozen name. Order is deliberate: the
    /// cheap liveness/temporary checks first, then the durable owner, the
    /// ORIGINAL lease, the metadata boundary, and only then the document
    /// mutation barrier for working-tree writers. The lease is released on
    /// EVERY path, including failures, and the barrier is finished so the
    /// editor state is re-read honestly even after a partial failure.
    private static func guarded(
        original: @escaping @Sendable (Data, ToolContext) async throws -> ToolExecutionOutput,
        effect: Effect, routing: G04GitToolRouting, live: @escaping @Sendable () -> Bool,
        argumentsJSON: Data, context: ToolContext
    ) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard live() else {
            throw FloeError.invalidConfiguration("This task's Git workspace is unavailable")
        }
        guard !context.temporaryReadOnly else {
            throw FloeError.validationFailed("Temporary chat cannot run local Git tools")
        }
        guard let conversationID = context.conversationID else {
            throw FloeError.validationFailed(
                "Git tools require a task-owned run. Open a task and use its workspace.")
        }
        guard let owner = await routing.resolveOwner(conversationID) else {
            throw FloeError.notFound("This task's selected workspace is no longer available")
        }
        let lease = try await routing.access.acquire(owner: owner,
            intent: effect == .read ? .read : .fileMutation, relativePath: nil)
        var session: G04WorkspaceDocumentSession?
        var mutation: UUID?
        do {
            try lease.cancellation.throwIfCancelled()
            guard live() else { throw G04DocumentError.retired }
            let root = lease.service.guardResolver.rootURL
            try G04GitMetadataBoundary.validate(root: root)
            if effect == .fileBarrier {
                guard let admitted = await routing.session(owner) else {
                    throw FloeError.notFound("This task's editor session is unavailable")
                }
                session = admitted
                mutation = try await admitted.beginExternalMutation()
            }
            var guardedContext = context
            if let provided = context.workspaceRootURL?.standardizedFileURL,
               provided != root.standardizedFileURL {
                throw FloeError.validationFailed(
                    "This run's workspace binding no longer matches the task's selected workspace")
            }
            // The ONLY root the original runners may see: the lease root of
            // the selected task. (rootProvider is { nil }, so nothing else
            // can supply one.)
            guardedContext.workspaceRootURL = root
            // Real IO settlement is owned by the operation lease: task
            // deletion/retirement cancels through this token, matching the
            // wire path.
            guardedContext.cancellation = lease.cancellation
            let output = try await original(argumentsJSON, guardedContext)
            if let token = mutation, let admitted = session {
                _ = try await admitted.finishExternalMutation(token, service: lease.service)
            }
            try lease.cancellation.throwIfCancelled()
            guard live() else { throw G04DocumentError.retired }
            await lease.release()
            return output
        } catch {
            if let token = mutation, let admitted = session {
                _ = try? await admitted.finishExternalMutation(token, service: lease.service)
            }
            await lease.release()
            throw error
        }
    }
}

/// Lock-protected boolean; the retirement mirror for `isAvailable`.
final class G04GitToolLiveness: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.withLock { value } }
    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}

extension AnyAgentTool {
    /// Attaches the liveness mirror without touching descriptor or run.
    func withAvailability(_ live: @escaping @Sendable () -> Bool) -> AnyAgentTool {
        var copy = self
        copy.isAvailable = live
        return copy
    }
}
