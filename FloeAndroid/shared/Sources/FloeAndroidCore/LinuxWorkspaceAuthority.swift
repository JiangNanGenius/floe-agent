// SPDX-License-Identifier: MPL-2.0
//
// FloeAndroidCore — LinuxWorkspaceAuthority: the native Core workspace
// authority for the scoped Core<->runtime workspace bridge (G03-R2,
// job-ade884c46eb84ec1).
//
// Authority provenance (read at authoring time; NOTHING here invents a
// second source of truth):
//  * The accepted native root epoch is `G02NativeRootEpoch.readback()` —
//    the live un-fenced generation or nil (never 0-as-epoch).
//  * Run identity/currency is the ORIGINAL `SQLiteRunStore.run(id:)` in the
//    installed `G02OwnedStoreCluster` (terminal states are exactly the
//    ORIGINAL nonTerminalRuns set: completed | failed | checkpointed |
//    interrupted).
//  * Workspace identity is the ORIGINAL conversation-ownership row in
//    `SQLiteWorkspaceStore` (`workspaceID(conversationID:)` + `workspace(id:)`).
//    This resolver NEVER creates a conversation or workspace row and NEVER
//    guesses: absent ownership is fail-closed. Temporary chat has no
//    persisted conversation/workspace rows, so it can never obtain a grant
//    here (the public-web ceiling holds by construction).
//  * The private-task root has the ONE materialized owned shape
//    `<storageRoot>/Workspace/PrivateTasks/<conversation uuid>` validated by
//    the original G02WorkspaceCleaning containment discipline (componentwise
//    RAW validation, non-following lstat at every managed level; a symlink is
//    a typed refusal that touches nothing; only authoritative ENOENT creates
//    the missing final directory).
//  * The project identity is the SAME deterministic mapping as shell.start:
//    `LinuxShellProjectMapping.projectID(forCanonicalCoreWorkspaceRoot:)`
//    (SHA256 of the trusted canonical Core workspace root; no mapping DB).
//  * File replacement authority on commit is the ORIGINAL
//    `AtomicFileCommitter` with digest CAS (`replaceIfUnchanged`), driven by
//    the FloeAndroidWorkspaceTools engine. There is NO default-true gate:
//    before `LinuxWorkspaceAuthority.install` runs, the engine has no hooks
//    and refuses everything; after install, the gate ANDs the REAL native
//    checks below with the optional externally supplied predicate.
//
// What the runtime EVER sees: opaque relative paths, bounded headers, the
// session key, and grant receipts. Core absolute workspace paths, the storage
// root, credentials, history and job authority NEVER cross this surface.
//
// MARK: - Main integration hooks (exact)
//
// 1. After the accepted native generation installs G02RuntimeComposition and
//    before pumping shell.start grants (AndroidRuntimeBootstrap /
//    RuntimeFacadeLinuxBindings compose point, same serialized composition):
//
//        LinuxWorkspaceAuthority.install(storageRoot: <RuntimeStorageRoot>,
//                                        externalGate: <optional predicate Main wires
//                                        from the real run-lifecycle evidence>)
//
//    `install` is idempotent for the same root and refuses a different one.
//    `externalGate` may be nil; the internal gate (epoch + run + ownership +
//    grant currency) still runs and fail-closes. A non-nil gate ADDs
//    conditions only — it can never widen what the internal checks refuse.
//
// 2. Trusted workspace root for run configuration / LocalShellService
//    rootProvider (the nil-instead-of-guess contract):
//
//        LinuxWorkspaceAuthority.trustedWorkspaceRoot(runID:conversationID:)
//            await -> URL?    // nil when no ORIGINAL binding exists
//
//    Main threads this into `RuntimeFacadeLinuxBindings.compose(rootProvider:)`
//    (reading the ToolContext-bound run/conversation, never session text) and
//    into run configuration `workspaceRootURL` where a run is explicitly
//    bound. The engine-observed workspaceMappingSynced qualification field may
//    turn true ONLY from actual completed import+export receipts read back
//    from `floe_linux_workspace_stats` / grant outcomes — never from a flag.
//
// 3. Grant mint (Kotlin pump, per owned shell session, BEFORE the grant
//    binder is handed beside foregroundPermit on the RuntimeWire parcel):
//
//        floe_linux_workspace_binding(rootEpoch, runID, grantIDIn, outBuf, cap)
//        floe_linux_workspace_session_open(bindingJson, bindingLen, outBuf, cap)
//
//    and the matching `floe_linux_workspace_abort/close` on session teardown.
//    Exact Kotlin `external fun` declarations and the grant transaction table
//    are returned in SOURCE_READY.json (workspacebridge lane); the JNI lives
//    in the app bridge module (Main-owned), NOT in this file's scope.
//
// 4. Lifecycle: `LinuxWorkspaceAuthority.sweepStaleTransfers(nowSeconds:)`
//    from the existing owned-work quiescence path (same place that calls
//    drainLinuxShell/reconcileLedger).

import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
import FloeAndroidShellTools
import FloeAndroidJobTools
import FloeAndroidWorkspaceTools
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

// MARK: - Status

public enum LinuxWorkspaceStatus {
    /// Body written; byte length returned.
    public static let ok: Int32 = 0
    /// Shared ASCII/buffer rules (same values as the mailbox surface).
    public static let invalidArguments: Int32 = -105
    public static let bufferTooSmall: Int32 = -106
    /// The reply JSON itself carries {"ok":false,"code":...}; negative codes
    /// are reserved for transport-level faults (bad pointers/capacity).
}

// MARK: - Authority

/// Synchronized result slot for `bridge`. File scope because the compiler
/// forbids nested types inside generic functions; locked because the write
/// happens on the operation's Task while the read happens on the binder
/// worker after the semaphore hand-off (belt AND braces, per the Main
/// review).
final class WorkspaceBridgeBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value?
    var value: Value? {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

public enum LinuxWorkspaceAuthority {

    private static let lock = NSLock()
    // All four fields below are written and read EXCLUSIVELY under `lock`
    // (the same existing-condition-guarded precedent as
    // RunForegroundProjection.foregroundChangeSequence): install() holds the
    // lock across minting; isInstalled/currentStorageRootPath/
    // currentProofSecret/mint/consume all take the lock; no unlocked reader
    // remains in this file.
    nonisolated(unsafe) private static var installedRootPath: String?
    nonisolated(unsafe) private static var proofSecret: WorkspaceGrantProof?
    nonisolated(unsafe) private static var externalGate: WorkspaceCommitGate?
    /// One-shot grant mints: grantID -> minted binding envelope. A session
    /// open consumes its grant; a replayed grant JSON is refused.
    nonisolated(unsafe) private static var mintedGrants: [String: MintedGrant] = [:]
    private static let maximumMintedGrants = 64
    private static let mintLifetimeSeconds: TimeInterval = 15 * 60

    private struct MintedGrant {
        let projectID: UUID
        let runID: UUID
        let conversationID: UUID
        let workspaceID: UUID
        let toolCallID: String?
        let jobID: UUID?
        let rootEpoch: UInt64
        let workspaceRootPath: String
        let mintedAt: Date
    }

    // MARK: Install

    /// Idempotent process install. Refuses a storage root whose Workspace
    /// child is a symlink (never follows) and refuses to place the transfer
    /// root INSIDE the granted workspace tree (Core .private metadata can
    /// never live inside the exported guest workspace by construction).
    @discardableResult
    public static func install(storageRoot: RuntimeStorageRoot,
                               externalGate: WorkspaceCommitGate? = nil) -> Bool {
        let workspaceRoot = workspaceDirectory(storageRoot: storageRoot)
        guard workspaceRoot.hasPrefix(storageRoot.path + "/") else { return false }
        switch WorkspaceNoFollow.kind(workspaceRoot) {
        case .directory, .missing:
            break
        default:
            return false
        }
        let transferRoot = WorkspaceTransferPaths.transferRoot(storageRoot: storageRoot.path)
        guard !transferRoot.hasPrefix(workspaceRoot + "/") else { return false }
        lock.lock(); defer { lock.unlock() }
        if let existing = installedRootPath {
            guard existing == storageRoot.path else { return false }
            if let externalGate { self.externalGate = externalGate }
            return true
        }
        installedRootPath = storageRoot.path
        proofSecret = WorkspaceGrantProof.random()
        self.externalGate = externalGate
        let hooks = WorkspaceAuthorityHooks(
            revalidateLight: { binding in revalidateLight(binding) },
            revalidateRun: { binding in revalidateRun(binding) },
            commitGateProvider: { internalGate() }
        )
        return WorkspaceTransferEngine.shared.install(hooks: hooks, transferRoot: transferRoot)
    }

    public static var isInstalled: Bool {
        lock.lock()
        let installed = installedRootPath != nil
        lock.unlock()
        return installed
    }

    private static func workspaceDirectory(storageRoot: RuntimeStorageRoot) -> String {
        storageRoot.path + "/Workspace"
    }

    // MARK: - Resolution (fail closed everywhere)

    /// The terminal run states of the ORIGINAL store (RunStore.nonTerminalRuns
    /// WHERE clause). No other state counts as terminal here.
    private static let terminalRunStates: Set<String> = ["completed", "failed", "checkpointed", "interrupted"]

    /// Resolves the workspace physically bound to the ORIGINAL run identity
    /// through the ORIGINAL conversation ownership row. Returns nil for every
    /// unresolved shape (never creates rows, never guesses a directory).
    public static func resolveWorkspace(runID: UUID) async -> (workspaceID: UUID, conversationID: UUID, rootURL: URL)? {
        guard let composition = G02RuntimeComposition.shared.installedComposition else { return nil }
        let run: RunRecord?
        do { run = try await composition.cluster.runStore.run(id: runID) } catch { return nil }
        guard let run, !terminalRunStates.contains(run.state) else { return nil }
        return await resolveWorkspace(conversationID: run.conversationID)
    }

    public static func resolveWorkspace(conversationID: UUID) async -> (workspaceID: UUID, conversationID: UUID, rootURL: URL)? {
        guard let composition = G02RuntimeComposition.shared.installedComposition else { return nil }
        let store = composition.cluster.workspaceStore
        let workspaceID: UUID?
        do { workspaceID = try await store.workspaceID(conversationID: conversationID) } catch { return nil }
        guard let workspaceID else { return nil }
        let record: WorkspaceRecord?
        do { record = try await store.workspace(id: workspaceID) } catch { return nil }
        guard let record else { return nil }
        // Android G02 binds ONLY the ORIGINAL persisted private-task shape.
        // A project workspace with a security-scoped bookmark is NOT an
        // Android ingress authority (the same rule that refuses bookmark refs
        // in RuntimeFacadeRuns.reserveStagedHandles) — fail closed instead of
        // inventing a location.
        guard record.kind == .privateTask,
              let internalRelativePath = record.internalRelativePath else { return nil }
        let expected = "PrivateTasks/\(conversationID.uuidString)"
        guard internalRelativePath == expected else { return nil }
        guard let storagePath = currentStorageRootPath() else { return nil }
        let rootURL = URL(fileURLWithPath: storagePath)
            .appendingPathComponent("Workspace", isDirectory: true)
            .appendingPathComponent(internalRelativePath, isDirectory: true)
            .standardizedFileURL
        guard rootURL.path.hasPrefix(storagePath + "/Workspace/") else { return nil }
        // Materialize with the ORIGINAL non-following containment discipline
        // (G02WorkspaceCleaning): managed components must be real
        // directories; ENOENT only at the FINAL owned component may create.
        let workspaceRoot = storagePath + "/Workspace"
        let privateTasksRoot = workspaceRoot + "/PrivateTasks"
        let target = rootURL.path
        // Fresh-task materialization (Main review 2026-10-22): the resolver
        // creates ONLY the three explicitly managed components of the ONE
        // ORIGINAL owned shape under the ACCEPTED root — `<root>/Workspace`,
        // `<root>/Workspace/PrivateTasks`, then the canonical leaf. Any
        // existing entry that is not a real directory (symlink/file/special/
        // unreadable) refuses and is touched NOTHING, exactly like the
        // original G02WorkspaceCleaning containment rules. Nothing here ever
        // guesses a different workspace, bookmark or external location.
        guard ensureManagedDirectory(workspaceRoot, allowCreate: true),
              ensureManagedDirectory(privateTasksRoot, allowCreate: true),
              ensureManagedDirectory(target, allowCreate: true) else {
            return nil
        }
        return (workspaceID, conversationID, URL(fileURLWithPath: target, isDirectory: true))
    }

    /// Non-following managed-directory check/creation for ONE owned component
    /// chain. A symlink/file/special/unreadable at any managed level refuses
    /// (touching nothing). `allowCreate` applies only to the final component.
    private static func ensureManagedDirectory(_ path: String, allowCreate: Bool) -> Bool {
        switch WorkspaceNoFollow.kind(path) {
        case .directory:
            return true
        case .missing:
            guard allowCreate else { return false }
            if mkdir(path, 0o700) != 0, errno != EEXIST { return false }
            return WorkspaceNoFollow.kind(path) == .directory
        default:
            return false
        }
    }

    private static func currentStorageRootPath() -> String? {
        lock.lock()
        let path = installedRootPath
        lock.unlock()
        return path
    }

    /// Locked copy of the minted proof secret (no unlocked reader is left
    /// against the install-time mutation).
    private static func currentProofSecret() -> WorkspaceGrantProof? {
        lock.lock()
        let secret = proofSecret
        lock.unlock()
        return secret
    }

    /// The trusted-root provider Main threads into
    /// `RuntimeFacadeLinuxBindings.compose(rootProvider:)` and run-config
    /// workspace binding. Nil instead of a guess, exactly as the shell lane
    /// contract requires.
    public static func trustedWorkspaceRoot(runID: UUID?, conversationID: UUID?) async -> URL? {
        if let runID, let resolved = await resolveWorkspace(runID: runID) {
            return resolved.rootURL
        }
        if let conversationID, let resolved = await resolveWorkspace(conversationID: conversationID) {
            return resolved.rootURL
        }
        return nil
    }

    // MARK: - Proof + currency revalidation

    private static func revalidateLight(_ binding: WorkspaceGrantBinding) -> Bool {
        guard let proofSecret = currentProofSecret(), let current = G02NativeRootEpoch.readback() else { return false }
        guard current == binding.rootEpoch else { return false }
        return proofSecret.matches(binding)
    }

    /// Bounded synchronous bridge for the ORIGINAL async stores from binder
    /// threads. Never call from the main thread; this is invoked only on
    /// Binder/pump worker threads during grant transactions.
    ///
    /// A timeout is a cancellation REQUEST plus a REFUSAL — never proof the
    /// async work finished. The C call (and therefore the caller's Core
    /// grant IO latch / claimed mailbox token) is HELD until the underlying
    /// operation ACTUALLY settles: returning nil while a detached resolver
    /// was still running would let conversation/Root deletion race a late
    /// `resolveWorkspace` materialization. Cooperative store work settles
    /// promptly after cancellation; a hung operation parks the binder
    /// worker honestly instead of fabricating drain. No replay, no second
    /// operation, no MainActor anywhere.
    static func bridge<T: Sendable>(timeoutSeconds: Double = 2.0,
                                            _ operation: @escaping @Sendable () async -> T?) -> T? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = WorkspaceBridgeBox<T?>()
        let task = Task {
            box.value = await operation()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + timeoutSeconds) == .success {
            return box.value ?? nil
        }
        // Deadline reached: request the real operation to stop, then KEEP
        // this call held until the task has actually completed.
        task.cancel()
        semaphore.wait()
        // The refusal stands regardless of what the operation produced:
        // the transaction is failed, but only now is it safe for the
        // grant latch to go idle because nothing async still touches the
        // original stores or files.
        return nil
    }

    private static func revalidateRun(_ binding: WorkspaceGrantBinding) -> Bool {
        // Composition identity: the installed generation epoch must equal the
        // grant epoch (same accepted Root, same owner).
        guard let composition = G02RuntimeComposition.shared.installedComposition,
              composition.epoch == binding.rootEpoch else { return false }
        if binding.jobID != nil {
            // Durable-job grant: ORIGINAL live ownership instead of the
            // parent-run activity test. A terminal parent alone never
            // revokes; settlement/cancellation (gone from
            // ownedProcessorIDs / terminal row) does.
            guard revalidateJobRun(binding) else { return false }
            let jobConversationOK: Bool = bridge { () -> Bool? in
                guard let conversationID = binding.conversationID,
                      let resolved = try? await composition.cluster.workspaceStore.workspaceID(conversationID: conversationID),
                      resolved == binding.workspaceID else { return false }
                return true
            } ?? false
            return jobConversationOK
        }
        let runOK: Bool = bridge { () -> Bool? in
            guard let run = try? await composition.cluster.runStore.run(id: binding.runID) else { return false }
            return !terminalRunStates.contains(run.state) && run.conversationID == binding.conversationID
        } ?? false
        guard runOK else { return false }
        let ownershipOK: Bool = bridge { () -> Bool? in
            guard let conversationID = binding.conversationID,
                  let resolved = try? await composition.cluster.workspaceStore.workspaceID(conversationID: conversationID),
                  resolved == binding.workspaceID else { return false }
            return true
        } ?? false
        return ownershipOK
    }

    // MARK: - Commit gate (internal REAL checks)

    /// The internal gate composes ONLY original-authority evidence:
    ///  * the grant proof + live un-fenced root epoch (revalidateLight),
    ///  * original run currency + workspace ownership (revalidateRun),
    ///  * the workspace root still being the real no-follow directory that
    ///    the binding addresses,
    ///  * plus every condition of the optional externally installed gate.
    /// A missing external gate NEVER defaults true; it simply adds nothing.
    private static func internalGate() -> WorkspaceCommitGate {
        LinuxInternalCommitGate(external: externalGateSnapshot())
    }

    private static func externalGateSnapshot() -> WorkspaceCommitGate? {
        lock.lock()
        let gate = externalGate
        lock.unlock()
        return gate
    }

    static func workspaceRootStillValid(_ binding: WorkspaceGrantBinding) -> Bool {
        guard WorkspaceNoFollow.kind(binding.workspaceRootPath) == .directory else { return false }
        // The canonical mapping must still resolve the SAME project identity.
        let mapped = LinuxShellProjectMapping.projectID(
            forCanonicalCoreWorkspaceRoot: URL(fileURLWithPath: binding.workspaceRootPath, isDirectory: true))
        guard mapped == binding.projectID else { return false }
        // A path swap between managed components is impossible under the
        // app-private root (single UID); the no-follow kind check above plus
        // the mapping identity is the re-provable evidence at this boundary.
        return true
    }

    private struct LinuxInternalCommitGate: WorkspaceCommitGate {
        let external: WorkspaceCommitGate?
        func allow(_ request: WorkspaceCommitRequest) -> Bool {
            // The engine session table is the ONLY source for the live
            // binding; an unknown/finished session key refuses (no snapshot
            // guess). The request identities must equal the session's.
            guard let binding = WorkspaceTransferEngine.shared.binding(forSessionKey: request.sessionKey),
                  binding.projectID == request.projectID,
                  binding.runID == request.runID,
                  binding.rootEpoch == request.rootEpoch,
                  revalidateLight(binding),
                  revalidateRun(binding),
                  LinuxWorkspaceAuthority.workspaceRootStillValid(binding) else {
                return false
            }
            if let external, !external.allow(request) { return false }
            return true
        }
    }

    // MARK: - Grant mint + session

    /// Ordinary (in-run) grant mint: requires the ORIGINAL run to be
    /// non-terminal and conversation-ownership resolution to succeed.
    static func mintBinding(runID: UUID, grantID: String) -> WorkspaceGrantBinding? {
        mintBindingShared(runID: runID, grantID: grantID, toolCallID: nil, jobID: nil,
                          requireRunActive: true)
    }

    // MARK: - Durable-job grant support (Main integration contract 2026-10-22)
    //
    // exec.shell jobs OUTLIVE their submitting parent run by original design:
    // the BackgroundJobService processor owns the engine session until real
    // settlement, and the durable `jobs.<UUID>` call identity is set by the
    // ORIGINAL service (parsed via the original `JobProcessorIdentity`,
    // never a model string). Therefore:
    //  * a TERMINAL parent run alone never revokes a job-scoped grant;
    //  * real job settlement/cancellation DOES revoke — the ORIGINAL row
    //    turns terminal (`state.isTerminal`) or the job id disappears from
    //    BOTH original live signals (`BackgroundJobService.ownedProcessorIDs`
    //    and the `JobLiveWorkIndex` behind `RuntimeFacadeJobBindings.liveJobWork`).
    // No extra DB, no default-terminal bypass, no "active inferred from a row
    // alone": the row proves identity + frozen workspace binding; a live
    // signal proves continuing ownership. Same original service instance
    // (`RuntimeFacadeJobBindings.shared.service`) for the accepted generation.

    static func mintBindingForCall(runID: UUID, toolCallID: String, grantID: String) -> WorkspaceGrantBinding? {
        guard let jobID = JobProcessorIdentity.jobID(fromToolCallID: toolCallID) else { return nil }
        return mintBindingShared(runID: runID, grantID: grantID, toolCallID: toolCallID, jobID: jobID,
                                 requireRunActive: false)
    }

    static func mintBindingShared(runID: UUID, grantID: String, toolCallID: String?, jobID: UUID?,
                                  requireRunActive: Bool) -> WorkspaceGrantBinding? {
        guard let proofSecret = currentProofSecret(), isInstalled,
              let currentEpoch = G02NativeRootEpoch.readback(),
              currentEpoch > 0, currentEpoch <= UInt64(Int64.max),
              let resolved = resolveForGrant(runID: runID, jobID: jobID, requireRunActive: requireRunActive,
                                             expectedEpoch: currentEpoch) else {
            return nil
        }
        return finishMint(runID: runID, grantID: grantID, toolCallID: toolCallID, jobID: jobID,
                          resolved: resolved.binding, proofSecret: proofSecret, epoch: currentEpoch)
    }

    /// The ONE resolution route both the mint and `session_open` use, so a
    /// durable-job grant opens (and reopens nothing) under EXACTLY the same
    /// ORIGINAL identity checks that minted it: the run row's conversation
    /// identity always; an active parent only for ordinary grants; for a job
    /// grant the live ORIGINAL processor + the frozen row binding instead.
    struct GrantResolution {
        let binding: (workspaceID: UUID, conversationID: UUID, rootURL: URL)
        let jobRow: BackgroundJob?
    }

    /// Run-state truth for the C sweep handler: the ONE closed terminal set
    /// (`terminalRunStates`) behind a single internal accessor, so the sweep's
    /// `runProof` cannot drift from the mint's activity rule.
    static func isTerminalRunState(_ state: String) -> Bool {
        terminalRunStates.contains(state)
    }

    static func resolveForGrant(runID: UUID, jobID: UUID?, requireRunActive: Bool,
                                expectedEpoch: UInt64? = nil) -> GrantResolution? {
        let epoch = expectedEpoch ?? G02NativeRootEpoch.readback() ?? 0
        guard epoch > 0 else { return nil }
        guard let identity = bridge(timeoutSeconds: 4.0, { () -> (conversationID: UUID, state: String)? in
            guard let composition = G02RuntimeComposition.shared.installedComposition,
                  composition.epoch == epoch,
                  let run = try? await composition.cluster.runStore.run(id: runID) else { return nil }
            return (run.conversationID, run.state)
        }) else { return nil }
        if requireRunActive, terminalRunStates.contains(identity.state) { return nil }
        guard let resolved = bridge(timeoutSeconds: 4.0, {
            await LinuxWorkspaceAuthority.resolveWorkspace(conversationID: identity.conversationID)
        }) else { return nil }
        var jobRow: BackgroundJob?
        if let jobID {
            // The frozen job binding must equal the CURRENT original
            // ownership (deleting the conversation retires the private-task
            // directory/rows and this resolution fails — settlement revokes).
            guard let row = liveJobOwnership(id: jobID),
                  row.runID == runID,
                  row.conversationID == identity.conversationID,
                  let frozen = row.workspaceRootPath,
                  URL(fileURLWithPath: frozen, isDirectory: true).standardizedFileURL.path
                    == resolved.rootURL.path else {
                return nil
            }
            jobRow = row
        }
        return GrantResolution(binding: resolved, jobRow: jobRow)
    }

    /// ORIGINAL live job ownership plus a non-terminal row, or nil. Checks
    /// `BackgroundJobService.ownedProcessorIDs` first and the
    /// `JobLiveWorkIndex` snapshot (`liveJobWork()`) as the second live
    /// signal; the service is always the SAME original instance the jobs
    /// lane composed (`RuntimeFacadeJobBindings.shared.service`).
    static func liveJobOwnership(id: UUID) -> BackgroundJob? {
        guard let service = RuntimeFacadeJobBindings.shared.service else { return nil }
        let read: (job: BackgroundJob, processorOwned: Bool)? = bridge(timeoutSeconds: 4.0) {
            guard let row = try? await service.job(id: id) else { return nil }
            let owned = await service.ownedProcessorIDs().contains(id)
            return (row, owned)
        }
        guard let read, read.job.id == id, !read.job.state.isTerminal else { return nil }
        if read.processorOwned { return read.job }
        let tracked: Bool = bridge(timeoutSeconds: 2.0) {
            await RuntimeFacadeJobBindings.shared.liveJobWork().contains { $0.jobID == id }
        } ?? false
        return tracked ? read.job : nil
    }

    /// Currency branch for an open job-scoped grant (used by `revalidateRun`).
    static func revalidateJobRun(_ binding: WorkspaceGrantBinding) -> Bool {
        guard let jobID = binding.jobID else { return false }
        guard let row = liveJobOwnership(id: jobID),
              row.runID == binding.runID,
              row.conversationID == binding.conversationID,
              let frozen = row.workspaceRootPath,
              URL(fileURLWithPath: frozen, isDirectory: true).standardizedFileURL.path
                == binding.workspaceRootPath else {
            return false
        }
        return true
    }

    private static func finishMint(runID: UUID, grantID: String, toolCallID: String?, jobID: UUID?,
                                   resolved: (workspaceID: UUID, conversationID: UUID, rootURL: URL),
                                   proofSecret: WorkspaceGrantProof, epoch: UInt64) -> WorkspaceGrantBinding? {
        let projectID = LinuxShellProjectMapping.projectID(forCanonicalCoreWorkspaceRoot: resolved.rootURL)
        let binding = WorkspaceGrantBinding(
            projectID: projectID, runID: runID, conversationID: resolved.conversationID,
            workspaceID: resolved.workspaceID, toolCallID: toolCallID, jobID: jobID,
            rootEpoch: epoch, grantID: grantID,
            workspaceRootPath: resolved.rootURL.path,
            workspaceFingerprint: fingerprint(of: resolved.rootURL.path),
            proof: proofSecret.compute(projectID: projectID, runID: runID,
                                       conversationID: resolved.conversationID,
                                       workspaceID: resolved.workspaceID,
                                       toolCallID: toolCallID, jobID: jobID,
                                       rootEpoch: epoch,
                                       grantID: grantID, workspaceRootPath: resolved.rootURL.path,
                                       budgetsJSON: WorkspaceGrantProof.canonicalBudgets(.defaults)),
            budgets: .defaults)
        lock.lock()
        pruneMintsLocked(now: Date())
        mintedGrants[grantID] = MintedGrant(projectID: projectID, runID: runID,
                                            conversationID: resolved.conversationID,
                                            workspaceID: resolved.workspaceID,
                                            toolCallID: toolCallID, jobID: jobID,
                                            rootEpoch: epoch,
                                            workspaceRootPath: resolved.rootURL.path,
                                            mintedAt: Date())
        lock.unlock()
        return binding
    }

    /// The mint record must equal the fully validated binding (identity AND
    /// root AND epoch AND workspace), and the grant is consumed: exactly one
    /// session per minted grantID, no replay.
    static func consumeMint(grantID: String, binding: WorkspaceGrantBinding) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let mint = mintedGrants[grantID],
              mint.projectID == binding.projectID,
              mint.runID == binding.runID,
              mint.conversationID == binding.conversationID,
              mint.workspaceID == binding.workspaceID,
              mint.toolCallID == binding.toolCallID,
              mint.jobID == binding.jobID,
              mint.rootEpoch == binding.rootEpoch,
              mint.workspaceRootPath == binding.workspaceRootPath else {
            return false
        }
        mintedGrants.removeValue(forKey: grantID)
        return true
    }

    private static func pruneMintsLocked(now: Date) {
        for (key, mint) in mintedGrants where now.timeIntervalSince(mint.mintedAt) > mintLifetimeSeconds {
            mintedGrants.removeValue(forKey: key)
        }
        if mintedGrants.count > maximumMintedGrants {
            // Oldest-first eviction: a grant JSON older than the newest 64 is
            // no longer mintable; its session (if already open) is unaffected.
            let sorted = mintedGrants.sorted { $0.value.mintedAt < $1.value.mintedAt }
            for entry in sorted.prefix(mintedGrants.count - maximumMintedGrants) {
                mintedGrants.removeValue(forKey: entry.key)
            }
        }
    }

    private static func fingerprint(of path: String) -> String {
        let digest = SHA256ish(path)
        return String(digest.prefix(12))
    }

    private static func SHA256ish(_ text: String) -> String {
        FloeDigest.sha256Hex(Data(text.utf8))
    }
}

// MARK: - C ABI (trusted Kotlin host only; NEVER a model dispatch)

private func workspaceReply(_ object: [String: Any], buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else { return LinuxWorkspaceStatus.invalidArguments }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          data.count + 1 <= Int(capacity) else {
        return LinuxWorkspaceStatus.bufferTooSmall
    }
    for (index, byte) in data.enumerated() { buffer[index] = CChar(bitPattern: byte) }
    buffer[data.count] = 0
    return Int32(data.count)
}

private func workspaceError(_ code: String, buffer: UnsafeMutablePointer<CChar>?, capacity: Int32) -> Int32 {
    workspaceReply(["ok": false, "code": String(code.prefix(64))], buffer: buffer, capacity: capacity)
}

private func workspaceCString(_ pointer: UnsafePointer<CChar>?, maximum: Int) -> String? {
    guard let pointer else { return nil }
    var bytes: [UInt8] = []
    var index = 0
    while index < maximum {
        let byte = UInt8(bitPattern: pointer[index])
        if byte == 0 { break }
        bytes.append(byte)
        index += 1
    }
    guard index < maximum, let text = String(bytes: bytes, encoding: .utf8) else { return nil }
    return text
}

private func workspaceUUID(_ text: String?) -> UUID? {
    guard let text else { return nil }
    return UUID(uuidString: text)
}

/// Mint the proof-bound grant metadata for the trusted host. Returns the
/// binding JSON (without any Core path) or a bounded error body. The host
/// forwards ONLY this JSON to `CoreWorkspaceGrant.create` in workspacebridge;
/// metadata JSON cannot mint a grant (the grantID is single-use here).
@_cdecl("floe_linux_workspace_binding")
public func floe_linux_workspace_binding(_ rootEpoch: UInt64, _ runID: UnsafePointer<CChar>?,
                                         _ grantID: UnsafePointer<CChar>?,
                                         _ outBuffer: UnsafeMutablePointer<CChar>?,
                                         _ capacity: Int32) -> Int32 {
    guard rootEpoch > 0,
          let runText = workspaceCString(runID, maximum: 64), let runUUID = workspaceUUID(runText),
          let grantText = workspaceCString(grantID, maximum: 64),
          grantText.range(of: "^[0-9a-f]{16,64}$", options: .regularExpression) != nil
    else {
        return workspaceError("invalidArguments", buffer: outBuffer, capacity: capacity)
    }
    guard G02NativeRootEpoch.readback() == rootEpoch else {
        return workspaceError("epochNotCurrent", buffer: outBuffer, capacity: capacity)
    }
    guard let binding = LinuxWorkspaceAuthority.mintBinding(runID: runUUID, grantID: grantText) else {
        return workspaceError("bindingUnavailable", buffer: outBuffer, capacity: capacity)
    }
    var object = binding.dictionaryValue
    object["ok"] = true
    return workspaceReply(object, buffer: outBuffer, capacity: capacity)
}

/// Durable-job variant of the mint (Main JNI wrapper:
/// `LinuxWorkspaceNative.bindingForCall(epoch, runCString, toolCallCString,
/// grantCString, outBuf, cap)`). `toolCall` MUST carry the ORIGINAL captured
/// host call id in the exact frozen shape `jobs.<UUID>`
/// (`JobProcessorIdentity`; anything else is refused — no inferred job).
/// A NULL/empty `toolCall` behaves exactly like `floe_linux_workspace_binding`
/// (ordinary in-run grant, active parent required). For the job shape the
/// grant stays valid while the ORIGINAL job ownership stays live, even after
/// the parent run finished; settlement/cancellation revokes it.
@_cdecl("floe_linux_workspace_binding_for_call")
public func floe_linux_workspace_binding_for_call(_ rootEpoch: UInt64, _ runID: UnsafePointer<CChar>?,
                                                  _ toolCallID: UnsafePointer<CChar>?,
                                                  _ grantID: UnsafePointer<CChar>?,
                                                  _ outBuffer: UnsafeMutablePointer<CChar>?,
                                                  _ capacity: Int32) -> Int32 {
    guard rootEpoch > 0,
          let runText = workspaceCString(runID, maximum: 64), let runUUID = workspaceUUID(runText),
          let grantText = workspaceCString(grantID, maximum: 64),
          grantText.range(of: "^[0-9a-f]{16,64}$", options: .regularExpression) != nil
    else {
        return workspaceError("invalidArguments", buffer: outBuffer, capacity: capacity)
    }
    guard G02NativeRootEpoch.readback() == rootEpoch else {
        return workspaceError("epochNotCurrent", buffer: outBuffer, capacity: capacity)
    }
    let callText = workspaceCString(toolCallID, maximum: 80)
    let binding: WorkspaceGrantBinding?
    if callText == nil || callText?.isEmpty == true {
        binding = LinuxWorkspaceAuthority.mintBinding(runID: runUUID, grantID: grantText)
    } else {
        binding = LinuxWorkspaceAuthority.mintBindingForCall(runID: runUUID, toolCallID: callText!,
                                                             grantID: grantText)
    }
    guard let binding else {
        return workspaceError("bindingUnavailable", buffer: outBuffer, capacity: capacity)
    }
    var object = binding.dictionaryValue
    object["ok"] = true
    return workspaceReply(object, buffer: outBuffer, capacity: capacity)
}

/// Open the native session for a minted grant JSON. The Core path is
/// RE-DERIVED here from the ORIGINAL stores; the JSON never carries it and
/// the engine receives the authoritative value only after revalidation.
@_cdecl("floe_linux_workspace_session_open")
public func floe_linux_workspace_session_open(_ bindingJson: UnsafePointer<CChar>?, _ bindingLen: Int32,
                                              _ outBuffer: UnsafeMutablePointer<CChar>?,
                                              _ capacity: Int32) -> Int32 {
    guard bindingLen > 0, bindingLen <= 8_192, let bindingJson else {
        return workspaceError("invalidArguments", buffer: outBuffer, capacity: capacity)
    }
    let data = Data(bytes: bindingJson, count: Int(bindingLen))
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any],
          let grantID = dictionary["grantID"] as? String,
          let epochNumber = dictionary["rootEpoch"] as? NSNumber else {
        return workspaceError("bindingMalformed", buffer: outBuffer, capacity: capacity)
    }
    guard epochNumber.uint64Value > 0, G02NativeRootEpoch.readback() == epochNumber.uint64Value else {
        return workspaceError("epochNotCurrent", buffer: outBuffer, capacity: capacity)
    }
    guard let runID = (dictionary["runID"] as? String).flatMap(UUID.init(uuidString:)) else {
        return workspaceError("bindingMalformed", buffer: outBuffer, capacity: capacity)
    }
    // Same resolution route as the mint: ordinary grants need an active
    // parent; job grants need the ORIGINAL live processor + frozen row
    // binding instead (a terminal parent alone opens fine).
    let jobID = (dictionary["jobID"] as? String).flatMap(UUID.init(uuidString:))
    guard let resolution = LinuxWorkspaceAuthority.resolveForGrant(runID: runID, jobID: jobID,
                                                                   requireRunActive: jobID == nil,
                                                                   expectedEpoch: epochNumber.uint64Value),
          // STRICT original parse; `workspaceRootPath` is attached ONLY from
          // the store-re-derived resolution (never from the wire JSON), and
          // the parsed identities must equal what the ORIGINAL stores say
          // right now. The HMAC itself is checked by the engine's
          // revalidateLight hook against the live minted secret at open.
          let binding = WorkspaceGrantBinding.from(dictionary: dictionary,
                                                   workspaceRootPath: resolution.binding.rootURL.path),
          binding.workspaceID == resolution.binding.workspaceID,
          binding.conversationID == resolution.binding.conversationID,
          binding.runID == runID else {
        return workspaceError("bindingUnresolved", buffer: outBuffer, capacity: capacity)
    }
    // Exact job identity: the opened grant's toolCallID must equal the row's
    // ORIGINAL captured host call id when the row carries one.
    if let row = resolution.jobRow, let recorded = row.toolCallID,
       let claim = dictionary["toolCallID"] as? String, claim != recorded {
        return workspaceError("jobCallMismatch", buffer: outBuffer, capacity: capacity)
    }
    guard LinuxWorkspaceAuthority.consumeMint(grantID: grantID, binding: binding) else {
        return workspaceError("grantNotMinted", buffer: outBuffer, capacity: capacity)
    }
    do {
        let sessionKey = try WorkspaceTransferEngine.shared.openSession(binding: binding)
        return workspaceReply(["ok": true, "sessionKey": sessionKey], buffer: outBuffer, capacity: capacity)
    } catch let error as WorkspaceTransferError {
        return workspaceError(error.wireCode, buffer: outBuffer, capacity: capacity)
    } catch {
        return workspaceError("sessionOpenFailed", buffer: outBuffer, capacity: capacity)
    }
}



/// Shared body: resolve session key, run the engine call, serialize the
/// bounded {"ok":true,...} reply, or a bounded {"ok":false,"code":...} body.
/// Negative returns are reserved for pointer/capacity faults.
private func engineCall(sessionKey: UnsafePointer<CChar>?,
                        outBuffer: UnsafeMutablePointer<CChar>?,
                        capacity: Int32,
                        _ body: (String) throws -> [String: Any]) -> Int32 {
    guard let key = workspaceCString(sessionKey, maximum: 64) else {
        return workspaceError("invalidArguments", buffer: outBuffer, capacity: capacity)
    }
    do {
        var result = try body(key)
        result["ok"] = true
        return workspaceReply(result, buffer: outBuffer, capacity: capacity)
    } catch let error as WorkspaceTransferError {
        return workspaceError(error.wireCode, buffer: outBuffer, capacity: capacity)
    } catch {
        return workspaceError("engineCallFailed", buffer: outBuffer, capacity: capacity)
    }
}

@_cdecl("floe_linux_workspace_baseline_begin")
public func floe_linux_workspace_baseline_begin(_ sessionKey: UnsafePointer<CChar>?,
                                                _ outBuffer: UnsafeMutablePointer<CChar>?,
                                                _ capacity: Int32) -> Int32 {
    engineCall(sessionKey: sessionKey, outBuffer: outBuffer, capacity: capacity) { key in
        try WorkspaceTransferEngine.shared.baselineBegin(sessionKey: key)
    }
}

@_cdecl("floe_linux_workspace_baseline_header")
public func floe_linux_workspace_baseline_header(_ sessionKey: UnsafePointer<CChar>?, _ index: Int64,
                                                 _ outBuffer: UnsafeMutablePointer<CChar>?,
                                                 _ capacity: Int32) -> Int32 {
    guard let key = workspaceCString(sessionKey, maximum: 64) else {
        return workspaceError("invalidArguments", buffer: outBuffer, capacity: capacity)
    }
    do {
        guard let header = try WorkspaceTransferEngine.shared.baselineHeader(sessionKey: key, index: index) else {
            return workspaceReply(["ok": true, "end": true], buffer: outBuffer, capacity: capacity)
        }
        var object = header
        object["ok"] = true
        return workspaceReply(object, buffer: outBuffer, capacity: capacity)
    } catch let error as WorkspaceTransferError {
        return workspaceError(error.wireCode, buffer: outBuffer, capacity: capacity)
    } catch {
        return workspaceError("headerFailed", buffer: outBuffer, capacity: capacity)
    }
}

/// Opens the actual bytes for one baseline entry. Returns a NEW owned fd (the
/// Kotlin grant adopts it into a ParcelFileDescriptor and closes its copy
/// after the binder reply; the runtime receives the binder dup).
/// Negative: typed error code (-1 invalidArguments, -2 notConfigured/noSession,
/// -3 proofRefused, -4 budget, -5 io, -6 cancelled, -7 malformed,
/// -8 pathUnsafe, -9 commitRefused, -10 diskReserve).
@_cdecl("floe_linux_workspace_baseline_open_data")
public func floe_linux_workspace_baseline_open_data(_ sessionKey: UnsafePointer<CChar>?,
                                                    _ index: Int64) -> Int32 {
    guard let key = workspaceCString(sessionKey, maximum: 64) else { return -1 }
    do {
        let opened = try WorkspaceTransferEngine.shared.baselineOpenData(sessionKey: key, index: index)
        return opened.fd
    } catch let error as WorkspaceTransferError {
        switch error {
        case .notConfigured: return -2
        case .noSession: return -2
        case .proofRefused: return -3
        case .budgetExceeded: return -4
        case .ioFailed: return -5
        case .cancelled: return -6
        case .malformed: return -7
        case .pathUnsafe: return -8
        case .commitRefused: return -9
        case .diskReserveUnmet: return -10
        }
    } catch {
        return -5
    }
}

@_cdecl("floe_linux_workspace_baseline_finish")
public func floe_linux_workspace_baseline_finish(_ sessionKey: UnsafePointer<CChar>?,
                                                 _ appliedCount: Int64, _ appliedBytes: Int64,
                                                 _ outBuffer: UnsafeMutablePointer<CChar>?,
                                                 _ capacity: Int32) -> Int32 {
    engineCall(sessionKey: sessionKey, outBuffer: outBuffer, capacity: capacity) { key in
        try WorkspaceTransferEngine.shared.baselineFinish(sessionKey: key, appliedCount: appliedCount,
                                                          appliedBytes: appliedBytes)
    }
}

@_cdecl("floe_linux_workspace_export_begin")
public func floe_linux_workspace_export_begin(_ sessionKey: UnsafePointer<CChar>?,
                                              _ outBuffer: UnsafeMutablePointer<CChar>?,
                                              _ capacity: Int32) -> Int32 {
    engineCall(sessionKey: sessionKey, outBuffer: outBuffer, capacity: capacity) { key in
        try WorkspaceTransferEngine.shared.exportBegin(sessionKey: key)
    }
}

/// Stages one received entry. `fdIn` (>= 0, regular-file payload) is read to
/// EOF by the engine; the CALLER keeps ownership and closes it. The engine
/// records only the bytes it actually read.
@_cdecl("floe_linux_workspace_export_stage")
public func floe_linux_workspace_export_stage(_ sessionKey: UnsafePointer<CChar>?,
                                              _ headerJson: UnsafePointer<CChar>?, _ headerLen: Int32,
                                              _ fdIn: Int32,
                                              _ outBuffer: UnsafeMutablePointer<CChar>?,
                                              _ capacity: Int32) -> Int32 {
    guard let key = workspaceCString(sessionKey, maximum: 64),
          headerLen > 0, headerLen <= WorkspaceWireLimits.maximumControlBytes, let headerJson
    else {
        return workspaceError("invalidArguments", buffer: outBuffer, capacity: capacity)
    }
    let data = Data(bytes: headerJson, count: Int(headerLen))
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let header = object as? [String: Any] else {
        return workspaceError("headerMalformed", buffer: outBuffer, capacity: capacity)
    }
    let kindRaw = header["kind"] as? String
    if kindRaw == "file", fdIn < 0 {
        return workspaceError("dataFdMissing", buffer: outBuffer, capacity: capacity)
    }
    let effectiveFd: Int32? = (kindRaw == "file") ? fdIn : nil
    do {
        var result = try WorkspaceTransferEngine.shared.exportStage(sessionKey: key, header: header,
                                                                     dataFd: effectiveFd)
        result["ok"] = true
        return workspaceReply(result, buffer: outBuffer, capacity: capacity)
    } catch let error as WorkspaceTransferError {
        return workspaceError(error.wireCode, buffer: outBuffer, capacity: capacity)
    } catch {
        return workspaceError("stageFailed", buffer: outBuffer, capacity: capacity)
    }
}

@_cdecl("floe_linux_workspace_export_finish")
public func floe_linux_workspace_export_finish(_ sessionKey: UnsafePointer<CChar>?,
                                               _ outBuffer: UnsafeMutablePointer<CChar>?,
                                               _ capacity: Int32) -> Int32 {
    engineCall(sessionKey: sessionKey, outBuffer: outBuffer, capacity: capacity) { key in
        try WorkspaceTransferEngine.shared.exportFinish(sessionKey: key)
    }
}

@_cdecl("floe_linux_workspace_abort")
public func floe_linux_workspace_abort(_ sessionKey: UnsafePointer<CChar>?,
                                       _ reason: UnsafePointer<CChar>?,
                                       _ outBuffer: UnsafeMutablePointer<CChar>?,
                                       _ capacity: Int32) -> Int32 {
    guard let key = workspaceCString(sessionKey, maximum: 64) else {
        return workspaceError("invalidArguments", buffer: outBuffer, capacity: capacity)
    }
    let text = workspaceCString(reason, maximum: 64) ?? "host-abort"
    do {
        var result = try WorkspaceTransferEngine.shared.abort(sessionKey: key, reason: text)
        result["ok"] = true
        return workspaceReply(result, buffer: outBuffer, capacity: capacity)
    } catch {
        return workspaceError("abortFailed", buffer: outBuffer, capacity: capacity)
    }
}

/// Grant close without terminal removal (host keeps the session inspectable
/// until the sweep proves it stale). Used by CoreWorkspaceGrant.close().
@_cdecl("floe_linux_workspace_session_close")
public func floe_linux_workspace_session_close(_ sessionKey: UnsafePointer<CChar>?) -> Int32 {
    guard let key = workspaceCString(sessionKey, maximum: 64) else { return -1 }
    WorkspaceTransferEngine.shared.closeSession(sessionKey: key, terminal: true)
    return 0
}

@_cdecl("floe_linux_workspace_stats")
public func floe_linux_workspace_stats(_ outBuffer: UnsafeMutablePointer<CChar>?, _ capacity: Int32) -> Int32 {
    guard let outBuffer, capacity > 0 else { return LinuxWorkspaceStatus.invalidArguments }
    let text = WorkspaceTransferEngine.shared.statsJSON()
    let bytes = Array(text.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return LinuxWorkspaceStatus.bufferTooSmall }
    for (index, byte) in bytes.enumerated() { outBuffer[index] = CChar(bitPattern: byte) }
    outBuffer[bytes.count] = 0
    return Int32(bytes.count)
}

/// Stale TASK-OWNED staging sweep from the owned-work quiescence path.
/// Unknown/active owners are always preserved (never deleted "for space").
@_cdecl("floe_linux_workspace_sweep")
public func floe_linux_workspace_sweep(_ nowSeconds: Int64, _ graceSeconds: Int64,
                                       _ outBuffer: UnsafeMutablePointer<CChar>?,
                                       _ capacity: Int32) -> Int32 {
    guard nowSeconds > 0, graceSeconds >= 60 else {
        return workspaceError("invalidArguments", buffer: outBuffer, capacity: capacity)
    }
    let runProof: @Sendable (String) -> Int = { raw in
        guard let runID = workspaceUUID(raw) else { return -1 }
        let result: Bool? = LinuxWorkspaceAuthority.bridge(timeoutSeconds: 4.0) {
            guard let composition = G02RuntimeComposition.shared.installedComposition else { return nil }
            guard let record = try? await composition.cluster.runStore.run(id: runID) else { return nil }
            return LinuxWorkspaceAuthority.isTerminalRunState(record.state)
        }
        switch result {
        case .some(true): return 1
        case .some(false): return 0
        case .none: return -1
        }
    }
    do {
        var result = try WorkspaceTransferEngine.shared.sweepStaleStaging(nowSeconds: nowSeconds,
                                                                          runProof: runProof,
                                                                          graceSeconds: graceSeconds)
        result["ok"] = true
        return workspaceReply(result, buffer: outBuffer, capacity: capacity)
    } catch let error as WorkspaceTransferError {
        return workspaceError(error.wireCode, buffer: outBuffer, capacity: capacity)
    } catch {
        return workspaceError("sweepFailed", buffer: outBuffer, capacity: capacity)
    }
}


