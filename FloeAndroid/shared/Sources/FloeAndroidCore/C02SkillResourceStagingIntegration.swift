// SPDX-License-Identifier: MPL-2.0
//
// N07 — production composition of run-pinned Skill resource staging.
//
// This binds the FloeSkills `SkillWorkspaceResourceStager` to the REAL
// Android execution facts, following the C02ToolResultIntegration box
// pattern (install once per accepted root generation, `current` accessor,
// epoch-fenced uninstall):
//
//   * TARGET GATE — the run's pinned C02 execution target MUST be
//     localLinux. A remote (ssh) target is the honest
//     `remoteResourceStagingUnavailable` boundary: the existing
//     C02SSHExecutionAdapter is exec-only and no internal run-bound upload
//     exists (the model-facing SFTP lane refuses the environment target),
//     so pinned bytes are NEVER silently staged for a remote task.
//   * WORKSPACE — LinuxWorkspaceAuthority.trustedWorkspaceRoot answers the
//     SAME Core task root the run config exports (nil instead of a guess).
//     The stager re-asks immediately before publish, so a retired/rebound
//     root can never receive bytes (the C08 final-root fence).
//   * GUEST VISIBILITY — never assumed from the Core-side commit: the
//     engine workspace is physically distinct and staged bytes cross only
//     at the existing import boundary (owner importBeforeLaunch before the
//     first exec.shell; participant importNewInputs adoption into the
//     shared live tree on later exec.shell calls). The optional prober
//     confirms visibility through the EXISTING read-only live-files
//     transport (workspace.files.tree, same mailbox as shell.start): no
//     second channel, no bytes in Binder control Parcels.
//
// Main calls `install` once per accepted generation AFTER
// C02ExecutionTargetProduction.make (the resolver needs the target domain)
// and retires it with `uninstall(epoch:)` exactly like the other C02
// integrations.
import Foundation
import FloeCore
import FloeTools
import FloeSkills
import FloeAndroidShellTools

// MARK: - Guest mount constant

public enum C02SkillResourceStaging {
    /// The guest mount of the engine workspace: the PRoot bind
    /// `LinuxBind(workspace, "/workspace")` in runtimeapp
    /// LinuxRuntimeOperations (shell start spec). Reserved staged bundles
    /// are addressed guest-relative beneath it.
    public static let guestWorkspaceRoot = "/workspace"
}

// MARK: - Pure policy (unit-testable without any runtime infrastructure)

/// The local/remote/workspace decision as a pure function of the facts the
/// trusted host read. Never invents support: every nil/mismatch is a precise
/// reason string from SkillStageReason.
public enum C02SkillResourceStagingPolicy {
    public static func resolution(
        pin: C02RunTargetPin?,
        target: C02ExecutionTarget?,
        workspaceRoot: URL?
    ) -> SkillWorkspaceStageResolution {
        guard let pin else {
            return .unavailable(reason: SkillStageReason.noLocalExecutionTarget)
        }
        guard let target, pin.matches(target) else {
            // No live target for this run, or the target was rebound past the
            // pin (revision/identity mismatch): never stage against stale
            // facts.
            return .unavailable(reason: SkillStageReason.noLocalExecutionTarget)
        }
        switch target.kind {
        case .ssh:
            // Honest remote boundary (N07 spec): no silent local staging.
            return .unavailable(reason: SkillStageReason.remoteResourceStagingUnavailable)
        case .localLinux:
            guard let workspaceRoot else {
                return .unavailable(reason: SkillStageReason.taskWorkspaceUnavailable)
            }
            return .local(
                workspaceRoot: workspaceRoot,
                guestWorkspaceRoot: C02SkillResourceStaging.guestWorkspaceRoot)
        }
    }
}

// MARK: - Production resolver / prober

public enum C02SkillResourceStagingComposition {
    /// Answers the run's ACTUAL pinned target kind and CURRENT trusted
    /// workspace root on every call (fresh reads, never cached), so the
    /// stager's initial check and its pre-publish re-check both observe
    /// live truth.
    public static func productionResolver(
        executionTargets: C02ExecutionTargetDomain
    ) -> @Sendable (UUID, UUID?) async -> SkillWorkspaceStageResolution {
        { runID, conversationID in
            let pin = try? await executionTargets.runTargetPin(runID: runID)
            guard let pin else {
                return C02SkillResourceStagingPolicy.resolution(
                    pin: nil, target: nil, workspaceRoot: nil)
            }
            let target = try? await executionTargets.executionTarget(taskID: pin.taskID)
            guard let target, target.kind == .localLinux, pin.matches(target) else {
                return C02SkillResourceStagingPolicy.resolution(
                    pin: pin, target: target, workspaceRoot: nil)
            }
            // Local target: only now resolve the workspace (a remote-pinned
            // task never pays for, nor sees, a local root).
            let root = await LinuxWorkspaceAuthority.trustedWorkspaceRoot(
                runID: runID, conversationID: conversationID)
            return C02SkillResourceStagingPolicy.resolution(
                pin: pin, target: target, workspaceRoot: root)
        }
    }

    /// The read-only guest-visibility probe over the SAME mailbox transport
    /// as shell.start. Returns nil (unconfirmed) whenever no live
    /// same-workspace engine session exists or the probe cannot be answered;
    /// a `pathOutOfScope` refusal on a live session is a definitive false.
    public static func productionProber() -> any SkillGuestVisibilityProbing {
        C02LiveGuestVisibilityProber()
    }
}

private struct C02LiveGuestVisibilityProber: SkillGuestVisibilityProbing {
    /// Best-effort bounded probe: workspace.files.tree calls on the live
    /// candidates, 8 s budget each. Any transport failure or stale identity
    /// skips to the next candidate; nothing here writes, executes or opens a
    /// second channel.
    func isPathVisible(workspaceRoot: URL, relativePath: String,
                       conversationID: UUID?, cancellation: CancellationToken) async -> Bool? {
        guard !cancellation.isCancelled, !Task.isCancelled,
              let components = RuntimeFacadeLinuxBindings.shared.components,
              let transport = components.liveFiles else { return nil }
        let projectID = LinuxShellProjectMapping
            .projectID(forCanonicalCoreWorkspaceRoot: workspaceRoot)
        // Every live, unreleased engine session of this exact workspace
        // addresses the same shared guest tree (owner and participants share
        // the project workspace directory). Runtime-side re-proves session,
        // project, environment and generation before touching any path, so a
        // wrong-project candidate refuses with pathOutOfScope and we move on.
        let candidates = components.backend.ownedSessions().filter {
            $0.state == .running && !$0.leaseReleased
                && !($0.runtimeGeneration ?? "").isEmpty
        }
        for session in candidates {
            guard !cancellation.isCancelled, !Task.isCancelled else { return nil }
            let request = LinuxLiveFilesRequest(
                sessionID: session.engineSessionID,
                workspaceKey: projectID.uuidString,
                environmentID: session.environmentID,
                generation: session.runtimeGeneration ?? "",
                relativePath: relativePath,
                maxEntries: 4,
                maxDepth: 1)
            do {
                let tree = try await transport.filesTree(request, timeoutMillis: 8_000)
                return !tree.entries.isEmpty || !tree.truncated
            } catch let error as LinuxLiveFilesError {
                switch error {
                case .refused(let code) where code == "pathOutOfScope":
                    // Definitive only for THIS task's own session: the path
                    // is not in the guest yet (the next workspace import
                    // materializes it). A foreign-project candidate refusing
                    // the same code is skipped, not read as visibility.
                    if session.conversationID == conversationID { return false }
                    continue
                default:
                    continue
                }
            } catch {
                continue
            }
        }
        return nil
    }
}

// MARK: - Generation-bound runtime (C02ToolResultIntegration box pattern)

public final class C02SkillResourceStagingRuntime: @unchecked Sendable {
    public let epoch: UInt64
    private let resolve: @Sendable (UUID, UUID?) async -> SkillWorkspaceStageResolution
    private let prober: (any SkillGuestVisibilityProbing)?
    private let liveEpoch: @Sendable () -> UInt64

    init(
        epoch: UInt64,
        resolve: @escaping @Sendable (UUID, UUID?) async -> SkillWorkspaceStageResolution,
        prober: (any SkillGuestVisibilityProbing)?,
        liveEpoch: @escaping @Sendable () -> UInt64
    ) {
        self.epoch = epoch
        self.resolve = resolve
        self.prober = prober
        self.liveEpoch = liveEpoch
    }

    public func isLive() -> Bool {
        epoch > 0 && liveEpoch() == epoch
    }

    /// Fresh target/workspace resolution; a retired generation refuses
    /// instead of answering from stale facts.
    func resolution(runID: UUID, conversationID: UUID?) async -> SkillWorkspaceStageResolution {
        guard isLive() else {
            return .unavailable(reason: SkillStageReason.stagingTransportUnavailable)
        }
        return await resolve(runID, conversationID)
    }

    /// The guest-visibility probe for THIS live generation only.
    func visibilityProber() -> (any SkillGuestVisibilityProbing)? {
        isLive() ? prober : nil
    }
}

public enum C02SkillResourceStagingIntegration {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var runtime: C02SkillResourceStagingRuntime?
        func get() -> C02SkillResourceStagingRuntime? {
            lock.lock(); defer { lock.unlock() }; return runtime
        }
        func set(_ value: C02SkillResourceStagingRuntime?) {
            lock.lock(); runtime = value; lock.unlock()
        }
        func clear(epoch: UInt64) {
            lock.withLock {
                guard runtime?.epoch == epoch else { return }
                runtime = nil
            }
        }
    }

    private static let box = Box()

    public static var current: C02SkillResourceStagingRuntime? { box.get() }

    /// Installs (or replaces) the generation's resource staging. Main calls
    /// this once per accepted root generation AFTER the execution-target
    /// domain exists; a newer generation replaces an older one, and only the
    /// owning generation may clear it.
    public static func install(
        epoch: UInt64,
        executionTargets: C02ExecutionTargetDomain,
        liveEpoch: @escaping @Sendable () -> UInt64 = { G02NativeRootEpoch.readback() ?? 0 }
    ) -> C02SkillResourceStagingRuntime {
        let runtime = C02SkillResourceStagingRuntime(
            epoch: epoch,
            resolve: C02SkillResourceStagingComposition.productionResolver(
                executionTargets: executionTargets),
            prober: C02SkillResourceStagingComposition.productionProber(),
            liveEpoch: liveEpoch)
        box.set(runtime)
        return runtime
    }

    /// Test/qualification seam: installs explicit resolver/prober closures
    /// over the same generation fencing. Production never calls this.
    public static func install(
        epoch: UInt64,
        resolve: @escaping @Sendable (UUID, UUID?) async -> SkillWorkspaceStageResolution,
        prober: (any SkillGuestVisibilityProbing)?,
        liveEpoch: @escaping @Sendable () -> UInt64
    ) -> C02SkillResourceStagingRuntime {
        let runtime = C02SkillResourceStagingRuntime(
            epoch: epoch, resolve: resolve, prober: prober, liveEpoch: liveEpoch)
        box.set(runtime)
        return runtime
    }

    /// Clears the binding for one retiring generation. A newer generation is
    /// never cleared by an old retirement callback.
    public static func uninstall(epoch: UInt64) {
        box.clear(epoch: epoch)
    }
}
