// SPDX-License-Identifier: MPL-2.0
//
// FloeAndroidCore — claimed task-workspace APK staging for the G08 trusted
// App-platform tool lane (N02 transfer-only seam, job-7e41829c0b4b4a4d
// completion of job-6ed412544e5b40e4).
//
// This file completes the Swift side of `system.packages.stage` workspace
// sources: a CLAIMED platform-tool ticket names ONE workspace-relative `.apk`
// and this stager commits the CURRENT task Linux content into an App-owned
// verified inbox over ONE of TWO authoritative sources, chosen per claim by
// the pure `PlatformToolWorkspaceApkSourcePolicy`:
//
//   1. LIVE SESSION — while exactly one live, unreleased engine session of
//      THIS EXACT task run AND the CURRENT pinned target environment exists,
//      content streams through the REAL split-UID file lane (the SAME
//      `LinuxLiveFilesTransport` the G07.3A read-only snapshot uses — one
//      bounded, digest-verified page at a time, over the SAME
//      LinuxShellMailbox/runtime IPC). The runtime re-proves
//      session/project/environment/generation before every page.
//   2. VERIFIED EXPORTED SNAPSHOT — after an ordinary one-shot `exec.shell`
//      completed (the normal acceptance flow: download the APK with
//      exec.shell, THEN stage it) the backend has ALREADY removed the
//      settled session (`sessions.removeValue` on the proven `leaseReleased`
//      terminal), and the CURRENT exported Core workspace bytes are
//      authoritative ONLY under an explicit current-export proof: the most
//      recent terminal index of THIS run bound to the CURRENT workspace
//      project and the LIVE root epoch whose durable RESULT is "synced"
//      (the SAME original transfer-tree receipt authority
//      `LinuxWorkspaceAuthority.lookupTerminalReceipt` reads, selected by
//      binding instead of a claimed digest). A failed (conflict / aborted /
//      receiptIncomplete) or stale newest export refuses, because a failed
//      export may have retained OLD Core bytes that must never stage.
//      The read itself is fenced by a no-live-writer proof (zero unreleased
//      same-conversation sessions), a post-read re-probe, and fd-level stat
//      stability (size + mtime + inode) on every page.
//
// Only bounded metadata JSON (<= 8 KiB) ever crosses JNI; APK bytes never
// ride a Binder parcel, Data payload, or the model-visible result.
//
// Authority model (nothing here trusts model JSON):
//   * task/run/environment are re-derived from the runtime-issued
//     `PlatformToolOwner` of the CLAIMED ticket (never from argument text);
//   * the CURRENT persisted run target pin is re-proved against the CURRENT
//     target through the composition-installed
//     `PlatformToolWorkspaceApkTargetResolving` seam (the epoch-bound
//     `C02ExecutionTargetDomain` has no process singleton; Main installs the
//     domain-backed resolver once per accepted generation). The pin must
//     `matches` the CURRENT target, the target must be localLinux, the
//     session environment must equal the target environment (an explicit
//     migration RE-PINS nonterminal runs: same runID does NOT prove the
//     current environment), and the pin's `shellRootHash` must equal the
//     hash of the authority-resolved CURRENT workspace root — never runID
//     alone, never a same-conversation session of another environment;
//   * the workspace root resolves through the ORIGINAL
//     `LinuxWorkspaceAuthority.resolveWorkspace(runID:)` (fail-closed,
//     non-terminal run only) — the CURRENT bound workspace, never a guess;
//   * the model-supplied relative path is re-validated here WITHOUT granting
//     anything (the Kotlin `PackageStageArguments` parser already refused
//     absolute/parent/backslash/non-apk shapes; this guard mirrors it so a
//     compromised host can never widen the surface);
//   * the App-owned inbox is bound by the SAME trusted composition that binds
//     the platform-tool artifact root (`<owned root>/FloeAgent/
//     WorkspaceApkInbox`), generation-fenced and retired with it;
//   * the committed inbox file is named by its own SHA-256 and is adopted
//     (moved/copied + re-verified) by the existing Kotlin
//     `ApkStagingStore.adoptWorkspaceFile` — this file never installs,
//     uninstalls, chmods world-readable copies, or touches /data/local/tmp.
//
// Lifecycle: the caller (the `floe_platform_tool_stage_workspace_apk` C export)
// supplies a live `PlatformToolClaimContext`; every page re-proves currency
// (claimed + same epoch + not cancelled) and the ticket deadline. ANY
// failure — cancel, fence, expiry, refusal, digest/size/stat mismatch,
// missing/failed/stale export proof, mid-read live writer — deletes the
// partial inbox file and returns one typed, bounded code. Abandoned
// partials and un-adopted commits are swept on a bounded TTL.
import Foundation
import FloeCore
import FloeAndroidShellTools
import FloeAndroidWorkspaceTools
import Crypto
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

// MARK: - Contract

public struct PlatformToolWorkspaceApkMetadata: Sendable, Equatable {
    /// Absolute path of the committed App-owned inbox file (trusted-host
    /// handoff to Kotlin adoption only; never model-visible).
    public let absolutePath: String
    public let sha256: String
    public let sizeBytes: Int64

    public init(absolutePath: String, sha256: String, sizeBytes: Int64) {
        self.absolutePath = absolutePath
        self.sha256 = sha256
        self.sizeBytes = sizeBytes
    }
}

/// Typed, bounded failure codes for the trusted-host reply. Every case is a
/// stable token; no case ever carries a host path, guest path, or prose.
public enum PlatformToolWorkspaceApkError: Error, Sendable, Equatable {
    /// Claim not claimed / wrong tool / wrong run-task identity / no authority.
    case notAuthorized
    /// Malformed relative path (absolute, parent, symlink-shape, non-apk...).
    case invalidArguments
    /// Inbox unbound, workspace unresolvable, no resolution, or the CURRENT
    /// persisted run target pin is absent / fails to match the current
    /// target (unwired or stale target authority refuses, never guesses).
    case noConfig
    /// Source absent from the CURRENT task Linux workspace.
    case notFound
    /// Content raced a change (page digest/size/mtime/generation/stat
    /// mismatch, retry refusal, malformed page, mid-read live writer).
    case sourceChanged
    /// Declared or streamed size exceeds the shared APK ceiling.
    case tooLarge
    /// Owning tool call cancelled mid-transfer.
    case cancelled
    /// Root generation fenced (rebind/close/retire) mid-transfer.
    case fenced
    /// Ticket deadline expired mid-transfer.
    case timeout
    /// Runtime-side definitive refusal, ambiguous session selection, a live
    /// same-conversation writer, or a missing/failed/stale current-export
    /// receipt — the honest boundary, never a widened guess.
    case unavailable
    /// Runtime-side permission/ownership refusal.
    case permission
    /// Inbox filesystem failure (create/write/fsync/rename).
    case stagingUnavailable

    public var code: String {
        switch self {
        case .notAuthorized: return "not_authorized"
        case .invalidArguments: return "invalid_arguments"
        case .noConfig: return "no_config"
        case .notFound: return "not_found"
        case .sourceChanged: return "source_changed"
        case .tooLarge: return "too_large"
        case .cancelled: return "cancelled"
        case .fenced: return "fenced"
        case .timeout: return "timeout"
        case .unavailable: return "unavailable"
        case .permission: return "permission"
        case .stagingUnavailable: return "staging_unavailable"
        }
    }
}

public enum PlatformToolWorkspaceApkLimits {
    /// The SAME ceiling the existing Kotlin lanes enforce
    /// (`StagedApkPolicy.MAX_APK_BYTES` / `AndroidReleaseFeed.MAX_APK_BYTES`,
    /// 2 GiB). Kept as a literal here because the shared core cannot import
    /// the app/root feature modules; the value is pinned by the ABI.
    public static let maximumApkBytes: Int64 = 2 * 1024 * 1024 * 1024
    /// One bounded page per live-files read (the transport's own maximum).
    public static let pageBytes = LinuxLiveFilesRequest.maximumReadBytes
    /// Per-page live-files budget (same bound the existing read lane uses).
    public static let pageTimeoutMillis = 8_000
    /// Abandoned `.part` lifetime before sweep.
    public static let partialFileTTLSeconds: Double = 10 * 60
    /// Un-adopted committed-file lifetime before sweep (a crash between
    /// commit and Kotlin adoption is the only way one survives).
    public static let committedFileTTLSeconds: Double = 24 * 60 * 60
    /// The ONE tool this stager serves; the claim context must match exactly.
    public static let stageToolName = "system.packages.stage"
    /// Bounded terminal-session enumeration for the current-export receipt
    /// scan (the scan makes NO completeness claim past this bound; more
    /// terminal sessions than this refuses instead of guessing).
    public static let maximumReceiptScanSessions = 512
    /// The durable terminal index is bounded exactly like the authority's
    /// readback path (1 MiB).
    public static let maximumTerminalIndexBytes = 1_048_576
}

// MARK: - CURRENT target proof (composition-installed, generation-fenced)

/// The CURRENT persisted target facts ONE transfer is pinned to. Re-proved
/// per claim from the epoch-bound C02 domain; nothing here is model text.
public struct PlatformToolWorkspaceApkTargetFacts: Sendable, Equatable {
    public let environmentID: String
    public let shellRootHash: String
    public let revision: Int64
    public let localLinux: Bool

    public init(environmentID: String, shellRootHash: String, revision: Int64,
                localLinux: Bool) {
        self.environmentID = environmentID
        self.shellRootHash = shellRootHash
        self.revision = revision
        self.localLinux = localLinux
    }
}

/// Trusted composition seam for the CURRENT run target pin. The
/// `C02ExecutionTargetDomain` is epoch-bound and injected at composition
/// (there is intentionally NO process singleton), so Main installs ONE
/// domain-backed resolver per accepted generation; until then every claimed
/// workspace-APK transfer refuses `.noConfig` (fail closed, never a guess).
public protocol PlatformToolWorkspaceApkTargetResolving: Sendable {
    func currentTarget(owner: PlatformToolOwner) async -> PlatformToolWorkspaceApkTargetFacts?
}

/// Concrete production resolver over the ORIGINAL C02 domain: the run's
/// persisted pin must still `matches` the CURRENT target (an explicit
/// migration re-pins nonterminal runs, so a same-runID session can be a
/// pre-migration environment — this re-proof is the discriminator) and the
/// target must be localLinux (the honest remote boundary).
public struct PlatformToolWorkspaceApkDomainTargetResolver: PlatformToolWorkspaceApkTargetResolving {
    private let domain: C02ExecutionTargetDomain

    public init(domain: C02ExecutionTargetDomain) {
        self.domain = domain
    }

    public func currentTarget(owner: PlatformToolOwner) async -> PlatformToolWorkspaceApkTargetFacts? {
        guard let pin = try? await domain.runTargetPin(runID: owner.runID),
              let target = try? await domain.executionTarget(taskID: owner.taskID),
              pin.matches(target), target.kind == .localLinux else { return nil }
        return PlatformToolWorkspaceApkTargetFacts(
            environmentID: target.environmentID,
            shellRootHash: target.shellRootHash,
            revision: target.revision,
            localLinux: true)
    }
}

/// Generation-fenced install holder (the C02SkillResourceStagingIntegration
/// box pattern): a newer generation replaces the resolver; only the owning
/// generation may clear it; epoch 0 never matches.
public enum PlatformToolWorkspaceApkTargetComposition {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var installed: (epoch: UInt64, resolver: any PlatformToolWorkspaceApkTargetResolving)?
        private var highWater: UInt64 = 0
        func get(epoch: UInt64) -> (any PlatformToolWorkspaceApkTargetResolving)? {
            lock.lock(); defer { lock.unlock() }
            guard epoch != 0, let installed, installed.epoch == epoch else { return nil }
            return installed.resolver
        }
        func set(epoch: UInt64, resolver: any PlatformToolWorkspaceApkTargetResolving) {
            guard epoch != 0 else { return }
            lock.lock(); defer { lock.unlock() }
            guard epoch > highWater else { return }
            highWater = epoch
            installed = (epoch, resolver)
        }
        func clear(epoch: UInt64) {
            lock.lock()
            highWater = max(highWater, epoch)
            if installed?.epoch == epoch { installed = nil }
            lock.unlock()
        }
        func reset() {
            lock.lock()
            installed = nil
            highWater = 0
            lock.unlock()
        }
    }

    private static let box = Box()

    /// Main installs the domain-backed resolver ONCE per accepted generation
    /// (immediately after the C02 execution-target components are made).
    public static func install(epoch: UInt64,
                               resolver: any PlatformToolWorkspaceApkTargetResolving) {
        box.set(epoch: epoch, resolver: resolver)
    }

    public static func current(epoch: UInt64) -> (any PlatformToolWorkspaceApkTargetResolving)? {
        box.get(epoch: epoch)
    }

    public static func uninstall(epoch: UInt64) {
        box.clear(epoch: epoch)
    }

    static func resetForTesting() { box.reset() }
}

// MARK: - Source selection policy (pure; unit-testable)

/// The proven engine facts ONE selection decision reads. Produced by the
/// production resolver from `AndroidLinuxShellBackend.ownedSessions()`;
/// nothing here is derived from model text.
public struct PlatformToolWorkspaceApkSessionFacts: Sendable, Equatable {
    public let sessionID: String
    public let runID: UUID?
    public let conversationID: UUID?
    public let environmentID: String
    public let runtimeGeneration: String
    public let workspaceOwner: Bool
    public let running: Bool
    public let leaseReleased: Bool

    public init(sessionID: String, runID: UUID?, conversationID: UUID?,
                environmentID: String, runtimeGeneration: String,
                workspaceOwner: Bool, running: Bool, leaseReleased: Bool) {
        self.sessionID = sessionID
        self.runID = runID
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.runtimeGeneration = runtimeGeneration
        self.workspaceOwner = workspaceOwner
        self.running = running
        self.leaseReleased = leaseReleased
    }
}

/// The selection outcome for ONE claimed ticket against the CURRENT
/// workspace facts. `.useExportedSnapshot` is only decided when NO live
/// current-run/current-environment session exists AND no same-conversation
/// writer is live; the caller must still prove the current export receipt.
public enum PlatformToolWorkspaceApkDecision: Sendable, Equatable {
    case live(sessionID: String, environmentID: String, generation: String)
    case useExportedSnapshot
    case refuse(PlatformToolWorkspaceApkError)
}

/// Pure current-target / post-command policy. Mirrors the
/// `C02SkillResourceStagingPolicy` pattern: every refusal is a typed token,
/// never a guess, never an arbitrary session choice.
public enum PlatformToolWorkspaceApkSourcePolicy {

    /// Choose the authoritative source for ONE claimed ticket.
    ///
    /// `targetEnvironmentID` is the CURRENT pinned target environment
    /// (production always supplies it; nil only in isolated policy tests).
    /// The live set requires the CURRENT run AND the CURRENT environment:
    /// an explicit C02 migration re-pins nonterminal runs, so runID alone
    /// never proves currency. A stale-environment session of the same run is
    /// NOT selected; while it (or any same-conversation session) stays live
    /// it is an un-exported writer and the snapshot path refuses too.
    public static func decision(
        owner: PlatformToolOwner,
        targetEnvironmentID: String?,
        sessions: [PlatformToolWorkspaceApkSessionFacts]
    ) -> PlatformToolWorkspaceApkDecision {
        let live = sessions.filter {
            $0.running && !$0.leaseReleased
                && $0.conversationID == owner.taskID
                && $0.runID == owner.runID
                && !$0.runtimeGeneration.isEmpty
                && (targetEnvironmentID == nil
                    || $0.environmentID == targetEnvironmentID)
        }
        let owners = live.filter { $0.workspaceOwner }
        if owners.count == 1, let chosen = owners.first {
            return .live(sessionID: chosen.sessionID,
                         environmentID: chosen.environmentID,
                         generation: chosen.runtimeGeneration)
        }
        if owners.isEmpty, live.count == 1, let chosen = live.first {
            return .live(sessionID: chosen.sessionID,
                         environmentID: chosen.environmentID,
                         generation: chosen.runtimeGeneration)
        }
        // Anything else with live candidates is ambiguity (multiple owners,
        // or multiple participants with no proven owner): refuse rather than
        // choose an arbitrary session.
        guard live.isEmpty else { return .refuse(.unavailable) }

        // No live session of the CURRENT run in the CURRENT environment. This
        // is the ordinary post-command shape (a one-shot exec.shell completed
        // and the backend removed the settled session). The CURRENT exported
        // Core workspace snapshot is usable ONLY while NO unreleased session
        // of this conversation exists at all: any live session may still own
        // a deferred workspace export, so the exported bytes could never be
        // proven current. An old-environment session of the same run
        // (mid-migration drain) is exactly such a writer and refuses here.
        let writer = sessions.contains {
            !$0.leaseReleased && $0.conversationID == owner.taskID
        }
        guard !writer else { return .refuse(.unavailable) }
        return .useExportedSnapshot
    }
}

// MARK: - Resolved source

/// The proven runtime identities one transfer reads under. Every field is
/// runtime-issued; nothing here is derived from model text.
public struct PlatformToolWorkspaceApkSource: Sendable, Equatable {
    public enum Origin: Sendable, Equatable {
        /// Stream over the REAL live-files lane addressed by the engine
        /// lease id of the one live current-run/current-environment session.
        case liveSession(sessionID: String, environmentID: String, generation: String)
        /// Read the CURRENT exported Core workspace snapshot at the
        /// authority-resolved root (App-UID local read; no IPC, no execute).
        /// Selected only after the current-export receipt proof passed.
        case exportedSnapshot(workspaceRootPath: String)
    }

    /// The engine project identity the runtime re-proves per page.
    public let workspaceKey: String
    public let origin: Origin
    public let target: PlatformToolWorkspaceApkTargetFacts?
    public let exportDigest: String?

    public init(workspaceKey: String, origin: Origin,
                target: PlatformToolWorkspaceApkTargetFacts? = nil,
                exportDigest: String? = nil) {
        self.workspaceKey = workspaceKey
        self.origin = origin
        self.target = target
        self.exportDigest = exportDigest
    }
}

/// Resolver outcome: the authoritative source, or a typed refusal that
/// survives to the wire reply instead of collapsing into `no_config`.
public enum PlatformToolWorkspaceApkResolution: Sendable, Equatable {
    case source(PlatformToolWorkspaceApkSource)
    case refused(PlatformToolWorkspaceApkError)

    /// Convenience for the stager's guard: the typed refusal behind
    /// `.refused`, if any.
    var refusedError: PlatformToolWorkspaceApkError? {
        switch self {
        case .source: return nil
        case .refused(let error): return error
        }
    }
}

/// Injected source-resolution seam. Production resolves through the ORIGINAL
/// authority/composition path; tests inject fakes. The transport itself is
/// NOT re-abstracted: callers inject the REAL `LinuxLiveFilesTransport`
/// (production: `RuntimeFacadeLinuxBindings.shared.components.liveFiles`)
/// so the adapter contract under test is the actual wire protocol.
public protocol PlatformToolWorkspaceApkSourceResolving: Sendable {
    func resolve(owner: PlatformToolOwner) async -> PlatformToolWorkspaceApkResolution
}

/// Production resolver: ORIGINAL workspace authority + composition-installed
/// CURRENT target re-proof + ORIGINAL shell components + the pure selection
/// policy + the ORIGINAL transfer-tree current-export receipt. Fails closed
/// everywhere; never guesses a session, never reads an old App input mirror
/// as live truth, never trusts a failed export's retained bytes.
public struct PlatformToolWorkspaceApkProductionResolver: PlatformToolWorkspaceApkSourceResolving {
    public init() {}

    public func resolve(owner: PlatformToolOwner) async -> PlatformToolWorkspaceApkResolution {
        // 1. The CURRENT ticket's workspace (non-terminal run + ORIGINAL
        //    conversation-ownership row). Absent ownership refuses; the
        //    private-task root materializes with the original no-follow
        //    discipline inside the authority itself.
        guard let workspace = await LinuxWorkspaceAuthority.resolveWorkspace(
            runID: owner.runID) else { return .refused(.noConfig) }
        let canonicalRoot = workspace.rootURL.standardizedFileURL
        // 2. The SAME deterministic project identity shell.start derives.
        let projectID = LinuxShellProjectMapping.projectID(
            forCanonicalCoreWorkspaceRoot: canonicalRoot)
        let workspaceKey = projectID.uuidString
        // 3. Re-prove the CURRENT persisted run target pin against the
        //    CURRENT target (composition-installed; fail closed unwired).
        //    The pin's workspace hash must equal the authority-resolved
        //    CURRENT root hash — a rebound workspace or a stale pin refuses.
        guard let targetResolver = PlatformToolWorkspaceApkTargetComposition.current(
            epoch: owner.epoch),
              let target = await targetResolver.currentTarget(owner: owner),
              target.localLinux,
              target.shellRootHash == FloeDigest.sha256Hex(Data(canonicalRoot.path.utf8))
        else { return .refused(.noConfig) }
        // 4. The SAME composed components as the shell lane; session facts
        //    come from the backend's own unreleased-lease ledger.
        guard let components = RuntimeFacadeLinuxBindings.shared.components else {
            return .refused(.noConfig)
        }
        let sessions = await components.backend.ownedSessions().map {
            PlatformToolWorkspaceApkSessionFacts(
                sessionID: $0.engineSessionID,
                runID: $0.runID,
                conversationID: $0.conversationID,
                environmentID: $0.environmentID,
                runtimeGeneration: $0.runtimeGeneration ?? "",
                workspaceOwner: $0.workspaceOwner == true,
                running: $0.state == .running,
                leaseReleased: $0.leaseReleased)
        }
        // 5. Pure current-target / post-command selection.
        switch PlatformToolWorkspaceApkSourcePolicy.decision(
            owner: owner, targetEnvironmentID: target.environmentID, sessions: sessions) {
        case .live(let sessionID, let environmentID, let generation):
            return .source(PlatformToolWorkspaceApkSource(
                workspaceKey: workspaceKey,
                origin: .liveSession(sessionID: sessionID,
                                     environmentID: environmentID,
                                     generation: generation),
                target: target))
        case .useExportedSnapshot:
            // 6. Current-export receipt proof: the newest terminal index of
            //    THIS run bound to the CURRENT workspace project and the LIVE
            //    root epoch whose durable RESULT is "synced". Absent / failed
            //    (conflict/aborted/receiptIncomplete) / stale (foreign epoch,
            //    project or run) refuses — a failed export may have retained
            //    OLD Core bytes, which must never stage.
            guard let receipt = Self.currentSyncedTerminalReceipt(
                owner: owner, workspaceKey: workspaceKey) else {
                return .refused(.unavailable)
            }
            return .source(PlatformToolWorkspaceApkSource(
                workspaceKey: workspaceKey,
                origin: .exportedSnapshot(workspaceRootPath: canonicalRoot.path),
                target: target, exportDigest: receipt.indexDigest))
        case .refuse(let error):
            return .refused(error)
        }
    }

    // MARK: Current-export receipt proof (ORIGINAL transfer-tree authority)

    /// Global-state wrapper: proves the live generation and the ORIGINAL
    /// transfer authority, then scans the ORIGINAL transfer tree.
    static func currentSyncedTerminalReceipt(
        owner: PlatformToolOwner, workspaceKey: String
    ) -> WorkspaceTerminalReceipt? {
        guard let live = G02NativeRootEpoch.readback(), live != 0,
              live == owner.epoch,
              LinuxWorkspaceAuthority.transferAuthorityLive,
              WorkspaceTransferEngine.shared.isInstalled,
              let storage = LinuxWorkspaceAuthority.effectiveStorageRootPath()
        else { return nil }
        return scanCurrentSyncedTerminalReceipt(
            transferRoot: WorkspaceTransferPaths.transferRoot(storageRoot: storage),
            liveEpoch: live,
            workspaceKey: workspaceKey,
            runID: owner.runID)
    }

    /// The bounded, no-follow scan behind the current-export proof. Mirrors
    /// `LinuxWorkspaceAuthority.lookupTerminalReceipt`'s discipline exactly
    /// (same original tree, same marker/index checks, same 1 MiB index cap)
    /// but selects the NEWEST terminal index whose binding is (projectID ==
    /// CURRENT workspace project, runID == THIS run, marker rootEpoch ==
    /// LIVE epoch) and whose durable RESULT is "synced", because a staging
    /// claim has no digest source of its own. Exceeding the session bound
    /// refuses (nil) instead of guessing.
    static func scanCurrentSyncedTerminalReceipt(
        transferRoot: String, liveEpoch: UInt64,
        workspaceKey: String, runID: UUID
    ) -> WorkspaceTerminalReceipt? {
        guard liveEpoch != 0 else { return nil }
        let sessionsRoot = transferRoot + "/sessions"
        guard WorkspaceNoFollow.kind(transferRoot) == .directory,
              WorkspaceNoFollow.kind(sessionsRoot) == .directory else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: sessionsRoot)) ?? []
        guard names.count <= PlatformToolWorkspaceApkLimits.maximumReceiptScanSessions
        else { return nil }
        var best: (receipt: WorkspaceTerminalReceipt, stamp: ExportStamp, synced: Bool)?
        var ambiguous = false
        for name in names.sorted() {
            guard WorkspaceTransferPaths.isValidSessionKey(name),
                  WorkspaceNoFollow.kind(sessionsRoot + "/" + name) == .directory
            else { continue }
            let paths = WorkspaceTransferPaths(transferRoot: transferRoot, sessionKey: name)
            // Binding proof: owner marker structurally valid, TERMINAL, and
            // bound to THIS run, the CURRENT workspace project and the LIVE
            // root epoch. A foreign/stale marker is never current evidence.
            guard let marker = WorkspaceOwnerMarker.load(path: paths.ownerMarker),
                  marker.sessionKey == name,
                  marker.rootEpoch == liveEpoch,
                  marker.projectID == workspaceKey,
                  UUID(uuidString: marker.runID) == runID
            else { continue }
            guard marker.state == "terminal",
                  case .success(let fd) = WorkspaceNoFollow.openRegularNoFollow(paths.terminalIndex)
            else { return nil }
            defer { close(fd) }
            // Select the newest matching export before considering its
            // outcome. Skipping failed exports would revive stale bytes.
            guard let indexData = Self.readBounded(
                    fd: fd, maximumBytes: PlatformToolWorkspaceApkLimits.maximumTerminalIndexBytes),
                  let object = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
                  (object["record"] as? String) == "terminalIndex",
                  (object["sessionKey"] as? String) == name,
                  UUID(uuidString: object["runID"] as? String ?? "") == runID,
                  (object["projectID"] as? String) == workspaceKey,
                  let fileStat = PlatformToolWorkspaceApkStager.exportedFileStat(fd)
            else { return nil }
            let stamp = ExportStamp(seconds: fileStat.mtimeSeconds,
                                    nanoseconds: fileStat.mtimeNanoseconds)
            let synced = (object["result"] as? String) == "synced"
                && (object["partial"] as? Bool) != true
            let receipt = WorkspaceTerminalReceipt(
                sessionKey: name, projectID: marker.projectID, runID: marker.runID,
                grantID: marker.grantID, rootEpoch: marker.rootEpoch,
                indexDigest: FloeDigest.sha256Hex(indexData))
            if best == nil || stamp > best!.stamp {
                best = (receipt, stamp, synced)
                ambiguous = false
            } else if stamp == best!.stamp {
                ambiguous = true
            }
        }
        guard let best, best.synced, !ambiguous else { return nil }
        return best.receipt
    }

    private struct ExportStamp: Comparable {
        let seconds: Int64
        let nanoseconds: Int64
        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.seconds == rhs.seconds
                ? lhs.nanoseconds < rhs.nanoseconds
                : lhs.seconds < rhs.seconds
        }
    }

    /// Bounded fd read (EINTR-retrying) used by the receipt scan; nil when
    /// the read fails or exceeds the cap (never a partial index).
    static func readBounded(fd: Int32, maximumBytes: Int) -> Data? {
        _ = lseek(fd, 0, SEEK_SET)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { break }
            data.append(contentsOf: chunk.prefix(Int(count)))
            if data.count > maximumBytes { return nil }
        }
        return data
    }
}

// MARK: - Stager

public enum PlatformToolWorkspaceApkStager {

    /// Stream ONE workspace-relative APK into the bound App-owned inbox.
    ///
    /// - Parameters:
    ///   - context: live claimed-ticket context (re-proved per page).
    ///   - relativePathUTF8: the UTF-8 wire bytes of the model-supplied
    ///     relative path (strictly decoded here; never an authority source).
    ///   - resolver: injected source resolver (production resolver above).
    ///   - transport: the REAL live-files transport (production:
    ///     `components.liveFiles`); required only for the live-session
    ///     source; tests inject a protocol fake.
    ///   - inbox: the bound App-owned inbox (nil while unbound/fenced).
    ///   - liveConversationProbe: exported-snapshot consistency proof: after
    ///     the local read, `true` (a same-conversation session became live
    ///     during the read) fails the transfer with `.sourceChanged` and the
    ///     partial is discarded. nil skips the re-proof (tests).
    ///   - epochReader: production reads the REAL `G02NativeRootEpoch`;
    ///     isolated tests inject a fixed epoch (never a different authority).
    ///   - now: clock seam for the sweep and expiry checks.
    public static func stage(
        context: PlatformToolClaimContext,
        relativePathUTF8: Data,
        resolver: any PlatformToolWorkspaceApkSourceResolving,
        transport: (any LinuxLiveFilesTransport)?,
        inbox: PlatformToolWorkspaceApkInboxBinding?,
        liveConversationProbe: (@Sendable () async -> Bool)? = nil,
        epochReader: @escaping @Sendable () -> UInt64? = { G02NativeRootEpoch.readback() },
        now: @Sendable () -> Date = { Date() }
    ) async -> Result<PlatformToolWorkspaceApkMetadata, PlatformToolWorkspaceApkError> {
        // 1. The claim must be live, exact-tool, and unexpired.
        guard context.toolName == PlatformToolWorkspaceApkLimits.stageToolName,
              context.currency() == .current, !context.expired else {
            return .failure(.notAuthorized)
        }
        // 2. Strict UTF-8 + containment guard of the model-supplied path.
        //    This mirrors Kotlin `PackageStageArguments.normalizeWorkspaceRelative`
        //    so the runtime lane is never opened with a widened shape.
        guard let rawPath = Self.strictUTF8(relativePathUTF8),
              !rawPath.contains("\0"),
              let relativePath = Self.normalizeWorkspaceRelative(rawPath) else {
            return .failure(.invalidArguments)
        }
        // 3. App-owned inbox must be bound to the ticket's own generation.
        guard let inbox, inbox.epoch == context.owner.epoch,
              let live = epochReader(), live == inbox.epoch else {
            return .failure(.noConfig)
        }
        let inboxRoot = URL(fileURLWithPath: inbox.path, isDirectory: true)
        guard Self.directoryUsable(inboxRoot) else { return .failure(.stagingUnavailable) }
        // 4. Re-prove the claim, then resolve the authoritative source.
        if let error = Self.checked(context) { return .failure(error) }
        let resolution = await resolver.resolve(owner: context.owner)
        guard case .source(let source) = resolution else {
            return .failure(resolution.refusedError ?? .noConfig)
        }
        if case .liveSession = source.origin, transport == nil {
            return .failure(.noConfig)
        }
        if let error = Self.checked(context) { return .failure(error) }

        // 5. Stream bounded pages into a private partial file, verifying the
        //    per-page identity/digest (live lane) or fd-level stat stability
        //    (exported snapshot) on every page.
        let partialName = ".stage-\(context.claim)-\(UUID().uuidString.lowercased()).part"
        let partial = inboxRoot.appendingPathComponent(partialName, isDirectory: false)
        let outcome: Result<StagedBytes, PlatformToolWorkspaceApkError>
        switch source.origin {
        case .liveSession(let sessionID, let environmentID, let generation):
            outcome = await Self.streamLive(
                context: context,
                sessionID: sessionID,
                workspaceKey: source.workspaceKey,
                environmentID: environmentID,
                generation: generation,
                transport: transport!,
                relativePath: relativePath,
                partial: partial)
        case .exportedSnapshot(let workspaceRootPath):
            outcome = await Self.streamExported(
                context: context,
                workspaceRootPath: workspaceRootPath,
                relativePath: relativePath,
                partial: partial,
                liveConversationProbe: liveConversationProbe)
        }
        switch outcome {
        case .failure(let error):
            Self.discard(partial)
            return .failure(error)
        case .success(let staged):
            if let error = Self.checked(context) {
                Self.discard(partial)
                return .failure(error)
            }
            guard await resolver.resolve(owner: context.owner) == .source(source) else {
                Self.discard(partial)
                return .failure(.sourceChanged)
            }
            if let error = Self.checked(context) {
                Self.discard(partial)
                return .failure(error)
            }
            // 6. Commit ONLY after the full digest + size are known: name the
            //    file by its own SHA-256, atomically replacing an identical
            //    earlier commit (same digest => same bytes by construction).
            let finalName = staged.sha256 + ".apk"
            let finalURL = inboxRoot.appendingPathComponent(finalName, isDirectory: false)
            guard Self.commit(partial: partial, final: finalURL, expected: staged) else {
                Self.discard(partial)
                return .failure(.stagingUnavailable)
            }
            return .success(PlatformToolWorkspaceApkMetadata(
                absolutePath: finalURL.path, sha256: staged.sha256,
                sizeBytes: staged.sizeBytes))
        }
    }

    // MARK: Wire reply (trusted host only)

    /// Success reply: `{"version":1,"ok":true,"absolutePath":...,"sha256":...,
    /// "sizeBytes":...}` — bounded well under the 8 KiB ABI ceiling.
    public static func replyJSON(
        _ metadata: PlatformToolWorkspaceApkMetadata
    ) -> String? {
        Self.encodeJSON([
            "version": 1,
            "ok": true,
            "absolutePath": metadata.absolutePath,
            "sha256": metadata.sha256,
            "sizeBytes": metadata.sizeBytes,
        ])
    }

    /// Failure reply: `{"version":1,"ok":false,"code":<bounded token>}`.
    public static func replyJSON(_ error: PlatformToolWorkspaceApkError) -> String? {
        Self.encodeJSON(["version": 1, "ok": false, "code": error.code])
    }

    // MARK: Abandoned-inbox sweep

    /// Remove ONLY files this stager owns: `.part` files past their TTL and
    /// un-adopted `<64-hex>.apk` commits past theirs. Foreign names are never
    /// touched. Returns the removed names (bounded by the inbox listing).
    @discardableResult
    public static func sweepAbandoned(
        inbox: PlatformToolWorkspaceApkInboxBinding, now: Date = Date(),
        epochReader: @escaping @Sendable () -> UInt64? = { G02NativeRootEpoch.readback() }
    ) -> [String] {
        guard let live = epochReader(), live == inbox.epoch else { return [] }
        let root = URL(fileURLWithPath: inbox.path, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return [] }
        var removed: [String] = []
        for name in names {
            let url = root.appendingPathComponent(name, isDirectory: false)
            let values = try? url.resourceValues(forKeys: [
                .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isSymbolicLink != true, values?.isRegularFile == true,
                  let mtime = values?.contentModificationDate else { continue }
            let age = now.timeIntervalSince(mtime)
            let owned: Bool
            let stale: Bool
            if name.hasSuffix(".part") {
                owned = name.hasPrefix(".stage-")
                stale = age > PlatformToolWorkspaceApkLimits.partialFileTTLSeconds
            } else {
                owned = name.count == 68 && name.hasSuffix(".apk")
                    && name.prefix(64).allSatisfy({ $0.isHexDigit })
                stale = age > PlatformToolWorkspaceApkLimits.committedFileTTLSeconds
            }
            if owned && stale {
                if Self.removeFile(url) { removed.append(name) }
            }
        }
        return removed.sorted()
    }

    // MARK: - Internal transfer core

    struct StagedBytes: Sendable, Equatable {
        let sha256: String
        let sizeBytes: Int64
    }

    /// Re-prove the claim between phases; map the currency to the typed code.
    static func checked(_ context: PlatformToolClaimContext)
        -> PlatformToolWorkspaceApkError? {
        switch context.currency() {
        case .current:
            return context.expired ? .timeout : nil
        case .cancelled:
            return .cancelled
        case .fenced:
            return .fenced
        }
    }

    /// LIVE-SESSION source: bounded pages over the REAL split-UID live-files
    /// lane, per-page generation/path/offset/size/digest checks plus the
    /// cross-page identity tuple. (Completed streamer body, preserved.)
    static func streamLive(
        context: PlatformToolClaimContext,
        sessionID: String,
        workspaceKey: String,
        environmentID: String,
        generation: String,
        transport: any LinuxLiveFilesTransport,
        relativePath: String,
        partial: URL
    ) async -> Result<StagedBytes, PlatformToolWorkspaceApkError> {
        // O_EXCL creation keeps two concurrent stages from sharing a partial.
        let handle: FileHandle
        do {
            let fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { return .failure(.stagingUnavailable) }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        var hasher = SHA256()
        var offset: Int64 = 0
        var totalBytes: Int64 = 0
        var expectedSize: Int64 = -1
        var expectedMTime: Int64 = -1
        var expectedRevision: String? = nil
        var first = true
        do {
            while true {
                if let error = checked(context) { throw TransferFailure(error) }
                let request = LinuxLiveFilesRequest(
                    sessionID: sessionID,
                    workspaceKey: workspaceKey,
                    environmentID: environmentID,
                    generation: generation,
                    relativePath: relativePath,
                    maxEntries: 1,
                    maxDepth: 0,
                    offset: offset,
                    maxBytes: PlatformToolWorkspaceApkLimits.pageBytes)
                let page: LinuxLiveFilePage
                do {
                    page = try await transport.filesRead(
                        request, timeoutMillis: PlatformToolWorkspaceApkLimits.pageTimeoutMillis)
                } catch let error as LinuxLiveFilesError {
                    throw TransferFailure(Self.mapTransportError(error))
                }
                // The runtime fenced consistency of THIS page against its own
                // identity tuple; any deviation means the live content raced
                // the transfer and nothing may be committed from it.
                guard page.generation == generation,
                      page.path == relativePath,
                      page.offset == offset,
                      page.bytes == page.content.count,
                      page.digest == FloeDigest.sha256Hex(page.content),
                      page.size > 0 else {
                    throw TransferFailure(.sourceChanged)
                }
                if first {
                    expectedSize = page.size
                    expectedMTime = page.mtimeMillis
                    expectedRevision = page.fileRevision
                    first = false
                } else {
                    guard page.size == expectedSize,
                          page.mtimeMillis == expectedMTime,
                          page.fileRevision == expectedRevision else {
                        throw TransferFailure(.sourceChanged)
                    }
                }
                guard page.size <= PlatformToolWorkspaceApkLimits.maximumApkBytes,
                      offset + Int64(page.bytes) <= page.size else {
                    throw TransferFailure(.tooLarge)
                }
                if page.bytes > 0 {
                    try handle.write(contentsOf: page.content)
                    page.content.withUnsafeBytes { raw in
                        if let base = raw.baseAddress, raw.count > 0 {
                            hasher.update(bufferPointer: UnsafeRawBufferPointer(
                                start: base, count: raw.count))
                        }
                    }
                    offset += Int64(page.bytes)
                    totalBytes += Int64(page.bytes)
                }
                if !page.truncated { break }
                guard page.bytes > 0 else {
                    // A truncated zero-length page can never advance; refuse
                    // to spin instead of looping forever.
                    throw TransferFailure(.sourceChanged)
                }
            }
            guard offset == expectedSize, totalBytes == expectedSize,
                  totalBytes > 0 else {
                throw TransferFailure(.sourceChanged)
            }
            try handle.synchronize()
            try handle.close()
        } catch let failure as TransferFailure {
            try? handle.close()
            return .failure(failure.error)
        } catch {
            try? handle.close()
            return .failure(.stagingUnavailable)
        }
        let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .success(StagedBytes(sha256: sha, sizeBytes: totalBytes))
    }

    /// EXPORTED-SNAPSHOT source: the CURRENT Core workspace bytes read by
    /// the App UID, selected only after the current-export receipt proof. No
    /// IPC, no execution: open WITHOUT following symlinks (the runtime lane's
    /// no-follow discipline mirrored locally), fd-level stat stability
    /// (size + mtime + inode) on every page, claim re-proof per page, and a
    /// post-read no-live-writer probe. Any deviation is `.sourceChanged` and
    /// the partial is discarded — never a stale commit.
    static func streamExported(
        context: PlatformToolClaimContext,
        workspaceRootPath: String,
        relativePath: String,
        partial: URL,
        liveConversationProbe: (@Sendable () async -> Bool)?
    ) async -> Result<StagedBytes, PlatformToolWorkspaceApkError> {
        // O_EXCL partial + O_NOFOLLOW source: no symlink, no shared partial.
        let partialHandle: FileHandle
        do {
            let fd = open(partial.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard fd >= 0 else { return .failure(.stagingUnavailable) }
            partialHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        let sourceFD = Self.openContainedSource(
            rootPath: workspaceRootPath, relativePath: relativePath)
        guard sourceFD >= 0 else {
            let openError = errno
            try? partialHandle.close()
            switch openError {
            case ENOENT:
                return .failure(.notFound)
            case EACCES, EPERM:
                return .failure(.permission)
            case ELOOP, ENOTDIR, ENAMETOOLONG, EINVAL:
                return .failure(.invalidArguments)
            default:
                return .failure(.unavailable)
            }
        }
        let source = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        guard let base = Self.exportedFileStat(source.fileDescriptor) else {
            try? source.close()
            try? partialHandle.close()
            return .failure(.sourceChanged)
        }
        guard base.size > 0 else {
            try? source.close()
            try? partialHandle.close()
            return .failure(.notFound)
        }
        guard base.size <= PlatformToolWorkspaceApkLimits.maximumApkBytes else {
            try? source.close()
            try? partialHandle.close()
            return .failure(.tooLarge)
        }
        var hasher = SHA256()
        var totalBytes: Int64 = 0
        do {
            while true {
                if let error = checked(context) { throw TransferFailure(error) }
                // Stat stability on every page: size + mtime + inode must not
                // move for the whole read.
                guard let current = Self.exportedFileStat(source.fileDescriptor),
                      current == base else {
                    throw TransferFailure(.sourceChanged)
                }
                guard let chunk = try source.read(upToCount: PlatformToolWorkspaceApkLimits.pageBytes),
                      !chunk.isEmpty else { break }
                try partialHandle.write(contentsOf: chunk)
                chunk.withUnsafeBytes { raw in
                    if let address = raw.baseAddress, raw.count > 0 {
                        hasher.update(bufferPointer: UnsafeRawBufferPointer(
                            start: address, count: raw.count))
                    }
                }
                totalBytes += Int64(chunk.count)
            }
            guard totalBytes == base.size else {
                throw TransferFailure(.sourceChanged)
            }
            // Post-read no-live-writer re-proof: a same-conversation session
            // that became live during the read may own a deferred export, so
            // these bytes cannot be proven current anymore.
            if let probe = liveConversationProbe, await probe() {
                throw TransferFailure(.sourceChanged)
            }
            guard let finalStat = Self.exportedFileStat(source.fileDescriptor),
                  finalStat == base else {
                throw TransferFailure(.sourceChanged)
            }
            let currentFD = Self.openContainedSource(
                rootPath: workspaceRootPath, relativePath: relativePath)
            guard currentFD >= 0 else { throw TransferFailure(.sourceChanged) }
            let currentPathStat = Self.exportedFileStat(currentFD)
            close(currentFD)
            guard currentPathStat == base else { throw TransferFailure(.sourceChanged) }
            try partialHandle.synchronize()
            try partialHandle.close()
            try source.close()
        } catch let failure as TransferFailure {
            try? source.close()
            try? partialHandle.close()
            return .failure(failure.error)
        } catch {
            try? source.close()
            try? partialHandle.close()
            return .failure(.stagingUnavailable)
        }
        let sha = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .success(StagedBytes(sha256: sha, sizeBytes: totalBytes))
    }

    /// fd-level identity of the exported source file: regular-file kind,
    /// size, mtime (seconds + nanoseconds) and inode.
    struct ExportedFileStat: Sendable, Equatable {
        let size: Int64
        let mtimeSeconds: Int64
        let mtimeNanoseconds: Int64
        let inode: UInt64
        let device: UInt64
    }

    static func exportedFileStat(_ fd: Int32) -> ExportedFileStat? {
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        #if canImport(Darwin)
        let seconds = st.st_mtimespec.tv_sec
        let nanoseconds = st.st_mtimespec.tv_nsec
        #else
        let seconds = st.st_mtim.tv_sec
        let nanoseconds = st.st_mtim.tv_nsec
        #endif
        return ExportedFileStat(
            size: Int64(st.st_size),
            mtimeSeconds: Int64(seconds),
            mtimeNanoseconds: Int64(nanoseconds),
            inode: UInt64(st.st_ino),
            device: UInt64(truncatingIfNeeded: st.st_dev))
    }

    struct TransferFailure: Error {
        let error: PlatformToolWorkspaceApkError

        init(_ error: PlatformToolWorkspaceApkError) {
            self.error = error
        }
    }

    /// Bounded mapping from the REAL transport error vocabulary to the typed
    /// staging codes. `retry` always means "raced a change, nothing assumed".
    static func mapTransportError(_ error: LinuxLiveFilesError)
        -> PlatformToolWorkspaceApkError {
        switch error {
        case .notBound:
            return .noConfig
        case .awaitBudgetExpired:
            return .timeout
        case .replyMalformed:
            return .sourceChanged
        case .refused(let code):
            switch code {
            case "notFound", "missing", "noSuchFile":
                return .notFound
            case "pathOutOfScope", "outsideWorkspace", "invalidPath":
                return .invalidArguments
            case "permission", "notOwner", "denied", "forbidden":
                return .permission
            default:
                return .unavailable
            }
        case .retry:
            return .sourceChanged
        case .transport:
            return .unavailable
        }
    }

    // MARK: - Path guard (mirror of the Kotlin parser; grants nothing)

    static func strictUTF8(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            guard let base = raw.baseAddress, raw.count > 0 else { return nil }
            return NSString(bytes: base, length: raw.count,
                            encoding: String.Encoding.utf8.rawValue) as String?
        }
    }

    static func normalizeWorkspaceRelative(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= PlatformToolHostLimits.maximumStageWorkspaceApkPathBytes
        else { return nil }
        guard !trimmed.hasPrefix("/") else { return nil }
        guard !trimmed.contains("\\") else { return nil }
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { return nil }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !segments.isEmpty, segments.count <= 32 else { return nil }
        for segment in segments {
            guard !segment.isEmpty, segment != ".", segment != "..",
                  segment.count <= 255 else { return nil }
        }
        guard segments.last!.lowercased().hasSuffix(".apk") else { return nil }
        return segments.joined(separator: "/")
    }

    // MARK: - Inbox filesystem helpers (no Foundation fallbacks)

    /// Walk relative directories by held descriptors. O_NOFOLLOW on only
    /// the leaf would still follow an intermediate symlink outside the root.
    static func openContainedSource(rootPath: String, relativePath: String) -> Int32 {
        guard normalizeWorkspaceRelative(relativePath) == relativePath else {
            errno = EINVAL
            return -1
        }
        let components = relativePath.split(separator: "/").map(String.init)
        guard let leaf = components.last else { errno = EINVAL; return -1 }
        var directory = open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return -1 }
        defer {
            let saved = errno
            close(directory)
            errno = saved
        }
        for component in components.dropLast() {
            let next = openat(directory, component,
                              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return -1 }
            close(directory)
            directory = next
        }
        return openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    }

    /// Create only the two managed inbox directories, relative to held
    /// parent descriptors, before exposing the binding to the host.
    static func prepareInbox(ownedRootPath: String) -> URL? {
        var directory = open(ownedRootPath,
                             O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        for component in ["FloeAgent", "WorkspaceApkInbox"] {
            if mkdirat(directory, component, mode_t(0o700)) != 0, errno != EEXIST {
                return nil
            }
            let next = openat(directory, component,
                              O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { return nil }
            close(directory)
            directory = next
        }
        return URL(fileURLWithPath: ownedRootPath, isDirectory: true)
            .appendingPathComponent("FloeAgent/WorkspaceApkInbox", isDirectory: true)
    }

    static func directoryUsable(_ url: URL) -> Bool {
        var values: URLResourceValues?
        do {
            values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            return false
        }
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    static func commit(partial: URL, final: URL,
                       expected: StagedBytes) -> Bool {
        // Both names are in the same private inbox. Atomic replacement
        // preserves the old pathname when rename fails and never opens a
        // missing-file interval for another adoption of the same digest.
        guard rename(partial.path, final.path) == 0,
              WorkspaceNoFollow.fsyncDirectory(final.deletingLastPathComponent().path)
        else { return false }
        guard let size = (try? final.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
              Int64(size) == expected.sizeBytes else {
            Self.removeFile(final)
            return false
        }
        return true
    }

    static func discard(_ url: URL) { Self.removeFile(url) }

    @discardableResult
    static func removeFile(_ url: URL) -> Bool {
        ((try? FileManager.default.removeItem(at: url)) != nil)
            && !FileManager.default.fileExists(atPath: url.path)
    }

    static func encodeJSON(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}
