// FloeSkills — run-pinned Skill bundle delivery into the task's Linux workspace.
//
// Android port of the reviewed iOS contract
// (FloeAgent/FloeApp/Skills/SkillWorkspaceResourceStager.swift at fixed source
// 3eb408bfb43a786b1df3bf79aeea9308e945fc6a). The digest-pinned per-run
// snapshot (SkillRunSnapshotStore) already carries every bundled file, but it
// is materialized only inside the app container, so the Linux guest never
// sees the scripts' sibling assets an upstream guide references. This actor
// stages the exact pinned snapshot bundle once into a reserved hidden cache
// tree under the ACTUAL Core workspace the run owns, from where the existing
// engine workspace import makes it visible in the guest at /workspace.
//
// Contract:
// - Staging is an internal cache preparation inside the workspace the run
//   already owns. It grants no execution, network or tool permission, never
//   runs anything, and writes nothing outside the task root.
// - The ACTUAL workspace and the local/remote decision come from the trusted
//   host resolver (FloeAndroidCore): the run's pinned C02 execution target
//   MUST be localLinux and LinuxWorkspaceAuthority.trustedWorkspaceRoot must
//   resolve the SAME root the run config exports. A remote (ssh) target is an
//   honest `remoteResourceStagingUnavailable` refusal — Core bytes are NEVER
//   silently staged for a remote task (the SSH adapter is exec-only; no
//   run-bound upload transport exists).
// - Reuse is granted only by full byte-for-byte verification against the
//   pinned snapshot (never by the `.markers` completion marker alone). A
//   foreign, damaged, symlinked or oversized tree at the staged path fails
//   closed and is left exactly as found.
// - Retention is workspace/task-scoped: a pinned tree stays until the
//   existing workspace-deletion lifecycle removes the workspace itself. Only
//   this helper's own abandoned `.staging-<canonical UUID>` temporaries are
//   ever removed; content bundles are never pruned by age, and marker
//   entries are never read or written through a planted symlink.
// - Publication is a single same-volume rename from a hidden staging tree, so
//   no reader ever observes a partial bundle; cancellation returns an honest
//   unavailable reason and never yields a staged path.
// - Guest visibility is NEVER assumed from the Core-side commit: the engine
//   workspace is physically distinct from the Core workspace and staged bytes
//   cross only at the existing import boundary (owner `importBeforeLaunch`
//   before the first exec.shell; participant `importNewInputs` adoption into
//   the shared live tree on later exec.shell calls). `visibleInGuest` is
//   reported only from the trusted live-files probe, and the model-facing
//   footer states the import boundary explicitly.
// - HOT PUBLISH (the R1 hot-session repair): when the probe reports a
//   definitive false — a LIVE same-task guest session answered and the path
//   is not there — the read does not stop at "next import boundary". The
//   pinned bundle is committed into the LIVE runtime-UID workspace through
//   the trusted host's `SkillGuestResourcePublishing` seam, which reuses the
//   SAME out-of-band verified filesystem transport as the participant
//   new-inputs import (journal staging, digest-verified fd streaming, atomic
//   missing-only publication, owner-baseline adoption; no bytes in Binder
//   control parcels, no second shell/GUI, no stdin injection, no path
//   repointing, no flag-only availability). The probe then re-answers and
//   stays the ONLY visibility authority: a live workspace that cannot be
//   synchronized (or an unconfirmed publish the probe cannot verify) is an
//   actionable failure, never a ready path; a workspace that settled between
//   probe and publish is the honest staged-for-first-use answer. The cold
//   path (no live session) is byte-for-byte unchanged.
//
// Foundation-only on purpose: FloeSkills must not import FloeAndroidCore
// (the Core target already imports FloeSkills). The trusted host binds the
// resolver/prober closures through C02SkillResourceStagingIntegration.

import Foundation
import FloeTools

// MARK: - Model-facing availability

/// Structured availability of the pinned bundle's staged resources, returned
/// on the exact `skill.read` of a run-pinned guide. Present only on exact
/// reads with a real run; discovery/list/search rows always carry nil. None
/// of the values ever carries a host path.
public struct SkillResourceAvailability: Codable, Sendable, Equatable {
    /// True when the pinned bytes were verified and committed into the task's
    /// Core workspace cache tree (or fully verified as already there).
    public var staged: Bool
    /// Guest-visible root (`/workspace/.floe/skills/<id>@<digest>`), present
    /// only when staged == true. This is the deterministic path the existing
    /// workspace import materializes; it is not claimed to be inside a
    /// running guest until `visibleInGuest` is true.
    public var guestRoot: String?
    /// The exact pinned revision these resources belong to (never the latest
    /// install digest when the run pin is older).
    public var pinnedSHA256: String
    public var fileCount: Int
    /// True only when a live same-project guest session actually listed the
    /// staged tree through the read-only live-files probe. False means the
    /// tree is committed Core-side and materializes at the next workspace
    /// import boundary (the task's first or next exec.shell).
    public var visibleInGuest: Bool
    /// Stable, model-facing refusal reason when staged == false.
    public var reason: String?

    public init(staged: Bool, guestRoot: String?, pinnedSHA256: String,
                fileCount: Int, visibleInGuest: Bool, reason: String?) {
        self.staged = staged
        self.guestRoot = guestRoot
        self.pinnedSHA256 = pinnedSHA256
        self.fileCount = fileCount
        self.visibleInGuest = visibleInGuest
        self.reason = reason
    }
}

/// Resource-staging slice of the trusted tool context. Built by SkillReadTool
/// from ToolContext; data-only, never carries the full context or authority.
public struct SkillResourceContext: Sendable {
    public var runID: UUID
    public var conversationID: UUID?
    public var environmentID: String?
    /// The root the run config exported for this task (trusted workspace
    /// binding). Nil for temporary/Notes runs without a workspace.
    public var workspaceRootURL: URL?
    /// Temporary (ephemeral) chat runs must never stage.
    public var temporaryReadOnly: Bool
    public var cancellation: CancellationToken

    public init(runID: UUID, conversationID: UUID? = nil, environmentID: String? = nil,
                workspaceRootURL: URL? = nil, temporaryReadOnly: Bool = false,
                cancellation: CancellationToken) {
        self.runID = runID
        self.conversationID = conversationID
        self.environmentID = environmentID
        self.workspaceRootURL = workspaceRootURL
        self.temporaryReadOnly = temporaryReadOnly
        self.cancellation = cancellation
    }
}

// MARK: - Outcomes

/// A bundle that was fully verified to match its pinned snapshot bytes and is
/// importable by the guest under the workspace share.
public struct SkillStagedBundle: Sendable, Equatable {
    public let guestRoot: String
    public let pinnedSHA256: String
    public let fileCount: Int
    /// See SkillResourceAvailability.visibleInGuest.
    public let visibleInGuest: Bool
}

public enum SkillStageOutcome: Sendable, Equatable {
    case staged(SkillStagedBundle)
    case unavailable(reason: String)
}

/// Stable, model-facing unavailable reasons. None of them ever carries a host
/// path, and none of them produces a guest path.
public enum SkillStageReason {
    public static let cancelled = "resource staging was cancelled"
    public static let temporaryReadOnlyRefused = "temporary chat cannot stage task resources"
    public static let noBoundEnvironment = "no local Linux execution environment is bound to this task"
    public static let workspaceMismatch = "the task workspace root does not match the workspace exported to the guest"
    public static let taskWorkspaceUnavailable = "the task workspace is unavailable or was rebound"
    public static let reservedConflict = "the reserved workspace cache path conflicts with existing entries"
    public static let pathBlocked = "an existing entry occupies the staged path and does not match the pinned bundle"
    public static let packageRejected = "the pinned bundle failed staging validation"
    public static let writeFailed = "staging the bundle into the task workspace failed"
    /// The run's pinned execution target is a remote SSH environment. The
    /// existing SSH adapter is exec-only and there is no run-bound upload
    /// transport, so staging MUST NOT silently happen locally. The pinned
    /// guide text remains readable; bundled files are not uploaded here.
    public static let remoteResourceStagingUnavailable =
        "remoteResourceStagingUnavailable: the pinned execution target is a remote SSH environment and no run-bound resource upload transport exists; the guide text remains readable, but bundled files have not been uploaded to that target"
    /// No execution target (or no live target matching the run pin) resolved.
    public static let noLocalExecutionTarget =
        "no local Linux execution target is pinned to this run; nothing was staged"
    /// The trusted host did not install the staging transport for this root
    /// generation (or it was retired); an honest capability refusal, never a
    /// fabricated stage.
    public static let stagingTransportUnavailable =
        "the task resource staging transport is not available in this runtime generation"
    /// A live same-task guest workspace exists but the trusted host installed
    /// no hot-publish transport for this root generation. The bundle is
    /// committed Core-side; the live guest cannot receive it in this read.
    public static let liveWorkspacePublishUnavailable =
        "liveWorkspacePublishUnavailable: a live task workspace is running but the resource publish transport is not available in this runtime generation; the pinned bundle is committed in the task workspace and materializes at the next workspace import boundary (run a new exec.shell), but it is NOT visible in the current live session"
    /// A live workspace REJECTED the hot publish. Actionable failure: the
    /// staged guest path must not be used in the current session.
    public static func liveWorkspaceSyncRefused(_ code: String) -> String {
        "liveWorkspaceSyncRefused: the pinned bundle is committed in the task workspace but the LIVE task workspace refused to receive it (\(Self.boundedCode(code))); it is NOT visible in the running guest. Do not read or run files under the staged guest path in the current session. Run a new exec.shell (a fresh workspace import materializes it) or close the live shell session and read this skill again."
    }
    /// The hot publish could not be confirmed (transport loss, bounded-wait
    /// expiry, or an applied transfer the probe still cannot see). Same
    /// actionable boundary as a refusal; the probe remains the authority.
    public static func liveWorkspaceSyncUnconfirmed(_ detail: String) -> String {
        "liveWorkspaceSyncUnconfirmed: the pinned bundle is committed in the task workspace but publishing it into the LIVE task workspace could not be confirmed (\(Self.boundedCode(detail))); it is NOT visible in the running guest now. Do not read or run files under the staged guest path in the current session. Run a new exec.shell (a fresh workspace import materializes it) or close the live shell session and read this skill again."
    }

    /// Model-facing engine codes stay bounded printable tokens (never a
    /// host path, payload or free text).
    static func boundedCode(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 48,
              trimmed.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else {
            return "engineRefused"
        }
        return trimmed
    }
}

// MARK: - Trusted host seams

/// Resolution of the run's ACTUAL execution target and task workspace,
/// answered fresh by the trusted host on every call (never cached, never a
/// first-project/UI-label/model-path fallback).
public enum SkillWorkspaceStageResolution: Sendable, Equatable {
    /// The run is pinned to a local Linux target. `workspaceRoot` is the
    /// trusted Core task workspace root; `guestWorkspaceRoot` is where the
    /// engine mounts it in the guest ("/workspace", the PRoot bind in
    /// runtimeapp LinuxRuntimeOperations).
    case local(workspaceRoot: URL, guestWorkspaceRoot: String)
    /// Honest refusal: remote target, unbound/retired runtime, rebound
    /// workspace or missing workspace. `reason` is one of the
    /// SkillStageReason constants.
    case unavailable(reason: String)
}

/// Optional post-commit probe over the EXISTING read-only live guest files
/// transport (workspace.files.tree). Implemented by the trusted host over
/// the SAME mailbox/runtime IPC as shell.start — no second channel.
public protocol SkillGuestVisibilityProbing: Sendable {
    /// - Returns: true/false when a live same-project guest session actually
    ///   answered for the workspace-relative path; nil when no live session
    ///   exists for this workspace or the probe could not be answered (the
    ///   caller reports visibility honestly as unconfirmed).
    func isPathVisible(workspaceRoot: URL, relativePath: String,
                       conversationID: UUID?, cancellation: CancellationToken) async -> Bool?
}

// MARK: - Hot publish into the LIVE runtime workspace

/// The engine's answer to one hot-publish request, mapped by the trusted
/// host from the bounded wire vocabulary. `applied`/`refused` are terminal
/// engine facts; `unconfirmed` means the request may still have completed
/// (transport loss or a bounded-wait expiry) — the caller re-probes and the
/// probe stays the ONLY visibility authority.
public enum SkillGuestPublishOutcome: Sendable, Equatable {
    /// The runtime confirmed the new-input transfer applied (the pinned
    /// bundle's entries were installed into the live runtime-UID workspace;
    /// pre-existing guest bytes were never touched).
    case applied
    /// No live same-project workspace existed at publish time (it settled
    /// between the visibility probe and the publish). The tree materializes
    /// at the next workspace import boundary — the honest staged-for-first-
    /// use answer, never a failure.
    case noLiveWorkspace
    /// A live workspace rejected the transfer (identity fence, budget,
    /// conflict, ownership revocation). `reason` is the engine's bounded
    /// code, never a host path.
    case refused(reason: String)
    /// The outcome is unknown (transport failure/timeout). The transfer may
    /// still have landed; only the probe can confirm.
    case unconfirmed
}

/// Hot-publish seam: commits the ALREADY Core-side-staged pinned bundle into
/// the LIVE runtime-UID task workspace over the EXISTING out-of-band
/// verified filesystem transport (the workspace bridge's participant
/// new-inputs import: journal staging, digest-verified PFD streaming,
/// atomic missing-only publication, owner-baseline adoption). Implemented by
/// the trusted host; no bytes ride Binder control parcels, no second shell
/// or GUI is started, no interactive program's stdin is injected, and no
/// availability flag is flipped without the real transfer.
public protocol SkillGuestResourcePublishing: Sendable {
    func publishStagedBundle(workspaceRoot: URL, runID: UUID,
                             conversationID: UUID?,
                             cancellation: CancellationToken) async -> SkillGuestPublishOutcome
}

// MARK: - Stager

/// One verified file shape check result: the normalized bundle the stager may
/// publish. Built only from the pinned snapshot's own manifest and bytes.
public struct SkillStagingBundle: Sendable {
    public struct File: Sendable {
        public let relativePath: String
        public let data: Data
    }
    public let skillID: String
    public let digest: String
    /// Sorted by relative path for deterministic writes.
    public let files: [File]
}

public actor SkillWorkspaceResourceStager {
    /// Reserved hidden cache tree inside the task workspace:
    /// `<workspace>/.floe/skills`. Entries whose name starts with "." are
    /// internal (`.staging-` temporaries, `.markers`) and never content
    /// bundles; content bundles are `<skillID>@<canonicalSHA256>`.
    public static let reservedComponents = [".floe", "skills"]
    public static let markerDirectory = ".markers"
    public static let stagingPrefix = ".staging-"
    /// Honest lifecycle bound: a content bundle is workspace/task-owned cache
    /// and is retained until the existing workspace-deletion lifecycle removes
    /// the workspace. NO pinned tree is pruned by age, so a run that lives
    /// longer than a day still executes against the tree it was given; growth
    /// per workspace equals the distinct `skillID@revision` bundles actually
    /// staged during the task's lifetime (each within the package caps), not
    /// an absolute storage limit. This age bound applies ONLY to abandoned
    /// `.staging-<canonical UUID>` temporaries from this helper's own
    /// generator: an in-flight stage renames within seconds, so an older one
    /// is provably left over.
    public static let staleStagingTemporaryAge: TimeInterval = 24 * 60 * 60

    /// Absolute staging-operation ceilings, mirroring the existing maximal
    /// workspace transfer envelope (WorkspaceTransferLimits.standard:
    /// 1 GiB total, 10_000 entries, 1 GiB per entry). These are NOT a
    /// package profile budget: the install-time validator (standard or
    /// signed large-source-v1 profile) remains the sole authority for what a
    /// package may contain, and the pinned snapshot is already
    /// digest-verified against that admission. The ceilings here only bound
    /// THIS staging operation itself, so one revision never receives
    /// another profile's budget and no admitted pinned bundle is
    /// re-narrowed at staging time.
    public static let stagingTotalBytesCeiling = 1 << 30
    public static let stagingFileCountCeiling = 10_000
    public static let stagingFileBytesCeiling = 1 << 30

    private let resolve: @Sendable (UUID, UUID?) async -> SkillWorkspaceStageResolution
    private let probeVisibility: (any SkillGuestVisibilityProbing)?
    private let publishVisibility: (any SkillGuestResourcePublishing)?

    public init(
        resolve: @escaping @Sendable (UUID, UUID?) async -> SkillWorkspaceStageResolution,
        probeVisibility: (any SkillGuestVisibilityProbing)? = nil,
        publishVisibility: (any SkillGuestResourcePublishing)? = nil
    ) {
        self.resolve = resolve
        self.probeVisibility = probeVisibility
        self.publishVisibility = publishVisibility
    }

    /// Prepare the pinned snapshot bundle in the task workspace. Never throws:
    /// every failure path returns an honest unavailable reason, publishes no
    /// partial tree and never removes anything this helper does not own.
    public func stage(
        snapshot: SkillContentSnapshot,
        runID: UUID,
        conversationID: UUID?,
        context: SkillResourceContext
    ) async -> SkillStageOutcome {
        let cancellation = context.cancellation
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }
        // Temporary (ephemeral) chat runs carry no task workspace and must
        // never write; refuse before any resolution or filesystem effect.
        guard !context.temporaryReadOnly else {
            return .unavailable(reason: SkillStageReason.temporaryReadOnlyRefused)
        }
        guard let exportedWorkspaceRoot = context.workspaceRootURL else {
            return .unavailable(reason: SkillStageReason.noBoundEnvironment)
        }
        guard let bundle = Self.stagingBundle(
            manifestID: snapshot.package.manifest.id,
            digest: snapshot.package.canonicalSHA256,
            declaredFiles: snapshot.package.files,
            bytes: snapshot.files
        ) else {
            return .unavailable(reason: SkillStageReason.packageRejected)
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }

        // The trusted host answers the run's ACTUAL pinned target and the
        // CURRENT trusted workspace root on every call. A remote target is an
        // honest unavailable here — never a silent local stage.
        let initialResolution = await resolve(runID, conversationID)
        let workspaceRoot: URL
        let guestWorkspaceRoot: String
        switch initialResolution {
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        case .local(let root, let guestRoot):
            workspaceRoot = root
            guestWorkspaceRoot = guestRoot
        }
        guard guestWorkspaceRoot.hasPrefix("/"),
              !guestWorkspaceRoot.split(separator: "/").contains("..") else {
            return .unavailable(reason: SkillStageReason.taskWorkspaceUnavailable)
        }
        // The run config's exported root and the authority's current root must
        // be the SAME directory, so a rebound/retired root can never receive
        // bytes through a stale context.
        let exportedCanonical = exportedWorkspaceRoot.resolvingSymlinksInPath().standardizedFileURL
        guard Self.sameDirectory(workspaceRoot, exportedCanonical) else {
            return .unavailable(reason: SkillStageReason.workspaceMismatch)
        }
        var isWorkspaceDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workspaceRoot.path, isDirectory: &isWorkspaceDirectory),
              isWorkspaceDirectory.boolValue else {
            return .unavailable(reason: SkillStageReason.workspaceMismatch)
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }
        guard let reservedRoot = Self.preparedReservedRoot(under: workspaceRoot) else {
            return .unavailable(reason: SkillStageReason.reservedConflict)
        }
        let leaf = "\(bundle.skillID)@\(bundle.digest)"
        let stagedRoot = reservedRoot.appendingPathComponent(leaf, isDirectory: true)
        let stagedRelativePath = Self.reservedComponents.joined(separator: "/") + "/" + leaf
        let guestRoot = guestWorkspaceRoot + "/" + stagedRelativePath

        if FileManager.default.fileExists(atPath: stagedRoot.path) {
            // Reuse is decided ONLY by full verification against the pinned
            // bytes. Anything else that sits here — foreign, damaged,
            // symlinked or partial — is left exactly as found, and staging
            // fails closed without a guest path.
            guard Self.verify(stagedRoot: stagedRoot, bundle: bundle) else {
                return .unavailable(reason: SkillStageReason.pathBlocked)
            }
            // A tree staged by an older build may carry 0644 entry scripts.
            // Re-apply the executable intent on reuse too: bytes and the
            // verification result are unchanged, and this is how an already
            // installed launcher is repaired without re-pinning its contents.
            Self.applyStagedPermissions(in: stagedRoot, bundle: bundle)
            // Fenced after verification and again immediately before the
            // staged return: a cancelled read never yields a path just
            // because a verified tree already exists.
            guard !cancellation.isCancelled, !Task.isCancelled else {
                return .unavailable(reason: SkillStageReason.cancelled)
            }
            Self.writeMarker(leaf: leaf, digest: bundle.digest, in: reservedRoot)
            Self.pruneStaleStagingTemps(in: reservedRoot)
            guard !cancellation.isCancelled, !Task.isCancelled else {
                return .unavailable(reason: SkillStageReason.cancelled)
            }
            return await resolvedVisibility(
                workspaceRoot: workspaceRoot, guestWorkspaceRoot: guestWorkspaceRoot,
                stagedRelativePath: stagedRelativePath, guestRoot: guestRoot,
                bundle: bundle, runID: runID, conversationID: conversationID,
                cancellation: cancellation)
        }

        let stagingRoot = reservedRoot.appendingPathComponent(
            Self.stagingPrefix + UUID().uuidString, isDirectory: true
        )
        // Fenced immediately before the first creation of this attempt.
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }
        do {
            try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: false)
            for file in bundle.files {
                guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
                let destination = stagingRoot.appendingPathComponent(file.relativePath)
                // Defense in depth: the bundle builder already rejected
                // traversal and absolute segments; re-check the resolved URL.
                guard destination.standardizedFileURL.path
                    .hasPrefix(stagingRoot.standardizedFileURL.path + "/") else {
                    throw CocoaError(.fileWriteInvalidFileName)
                }
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try file.data.write(to: destination, options: .atomic)
                let readBack = try Data(contentsOf: destination)
                guard readBack == file.data else { throw CocoaError(.fileWriteUnknown) }
                if let mode = Self.stagedPermissions(relativePath: file.relativePath, data: file.data) {
                    try? FileManager.default.setAttributes(
                        [.posixPermissions: mode], ofItemAtPath: destination.path
                    )
                }
            }
            // Verify the complete temporary tree (exact file/dir shape, no
            // symlinks, every byte equal) before any publication.
            guard Self.verify(stagedRoot: stagingRoot, bundle: bundle) else {
                throw CocoaError(.fileWriteUnknown)
            }
            Self.applyStagedPermissions(in: stagingRoot, bundle: bundle)
            guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }

            // A retired generation or a rebound task root must not receive
            // bytes: the host re-answers the SAME resolution immediately
            // before the publish rename (the C08 final-root fence). A changed
            // root or a lost local target refuses instead of publishing into
            // a tree another task now owns.
            let finalResolution = await resolve(runID, conversationID)
            switch finalResolution {
            case .unavailable(let reason):
                throw SkillStageRefusal(reason: reason)
            case .local(let finalRoot, let finalGuestRoot):
                guard Self.sameDirectory(finalRoot, workspaceRoot),
                      finalGuestRoot == guestWorkspaceRoot else {
                    throw SkillStageRefusal(reason: SkillStageReason.taskWorkspaceUnavailable)
                }
            }
            guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }

            // Single same-volume commit: a rename, never a partial publish.
            try FileManager.default.moveItem(at: stagingRoot, to: stagedRoot)
        } catch {
            // Remove only OUR staging temporary; the final path is untouched.
            try? FileManager.default.removeItem(at: stagingRoot)
            if let refusal = error as? SkillStageRefusal {
                return .unavailable(reason: refusal.reason)
            }
            if error is CancellationError {
                return .unavailable(reason: SkillStageReason.cancelled)
            }
            // A concurrent publisher may have won the rename (or an entry
            // appeared). Adopt only a tree that FULLY verifies; never overwrite.
            if FileManager.default.fileExists(atPath: stagedRoot.path) {
                if Self.verify(stagedRoot: stagedRoot, bundle: bundle) {
                    // A concurrent publisher already committed the same bytes.
                } else {
                    return .unavailable(reason: SkillStageReason.pathBlocked)
                }
            } else {
                return .unavailable(reason: SkillStageReason.writeFailed)
            }
        }
        // Advisory only: markers record OUR commits; reuse never trusts them,
        // so a failed marker write keeps the valid tree. Nothing is ever
        // deleted or trusted based on a marker.
        Self.writeMarker(leaf: leaf, digest: bundle.digest, in: reservedRoot)
        Self.pruneStaleStagingTemps(in: reservedRoot)
        // Fenced immediately before the staged return.
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }
        return await resolvedVisibility(
            workspaceRoot: workspaceRoot, guestWorkspaceRoot: guestWorkspaceRoot,
            stagedRelativePath: stagedRelativePath, guestRoot: guestRoot,
            bundle: bundle, runID: runID, conversationID: conversationID,
            cancellation: cancellation)
    }

    /// Visibility resolution for an ALREADY Core-side-committed bundle. The
    /// read-only probe is the ONLY visibility authority: a true answer
    /// reports visible; nil (no live same-task workspace answered) is the
    /// honest staged-for-first-use answer — the tree materializes at the
    /// next workspace import boundary. A definitive false means a LIVE
    /// same-task workspace does not have the bytes yet: the pinned bundle
    /// is then hot-published into the live runtime-UID workspace over the
    /// trusted host's out-of-band verified transport and the probe
    /// re-answers. A live workspace that still cannot be synchronized (or
    /// whose publish is unconfirmed and unprobed) yields an actionable
    /// failure, never a ready path; a workspace that settled between probe
    /// and publish is staged-for-first-use again, not a failure.
    private func resolvedVisibility(
        workspaceRoot: URL,
        guestWorkspaceRoot: String,
        stagedRelativePath: String,
        guestRoot: String,
        bundle: SkillStagingBundle,
        runID: UUID,
        conversationID: UUID?,
        cancellation: CancellationToken
    ) async -> SkillStageOutcome {
        func staged(_ visible: Bool) -> SkillStageOutcome {
            .staged(SkillStagedBundle(
                guestRoot: guestRoot, pinnedSHA256: bundle.digest,
                fileCount: bundle.files.count, visibleInGuest: visible))
        }
        guard let prober = probeVisibility else { return staged(false) }
        let first = await prober.isPathVisible(
            workspaceRoot: workspaceRoot, relativePath: stagedRelativePath,
            conversationID: conversationID, cancellation: cancellation)
        if first == true { return staged(true) }
        guard first == false else { return staged(false) }

        // A live same-task workspace answered a definitive false: publish the
        // pinned bytes into it NOW (the hot-session repair). The SAME fences
        // as the Core-side write apply: cancellation, then the pre-publish
        // revalidation of the run's ACTUAL workspace (a rebound/retired root
        // never publishes), then the trusted transport — which re-proves
        // run, root, session, target and runtime generation on its own side.
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }
        guard let publisher = publishVisibility else {
            return .unavailable(reason: SkillStageReason.liveWorkspacePublishUnavailable)
        }
        let publishResolution = await resolve(runID, conversationID)
        switch publishResolution {
        case .unavailable(let reason):
            return .unavailable(reason: reason)
        case .local(let publishRoot, let publishGuestRoot):
            guard Self.sameDirectory(publishRoot, workspaceRoot),
                  publishGuestRoot == guestWorkspaceRoot else {
                return .unavailable(reason: SkillStageReason.taskWorkspaceUnavailable)
            }
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }
        let outcome = await publisher.publishStagedBundle(
            workspaceRoot: workspaceRoot, runID: runID,
            conversationID: conversationID, cancellation: cancellation)
        if outcome == .noLiveWorkspace {
            // The live session settled between the probe and the publish:
            // the next workspace import boundary carries the tree.
            return staged(false)
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            return .unavailable(reason: SkillStageReason.cancelled)
        }
        // The probe is the ONLY visibility authority: re-probe before any
        // visible claim — including after a refused/unconfirmed publish (a
        // concurrent import boundary may have materialized the bytes).
        let confirmed = await prober.isPathVisible(
            workspaceRoot: workspaceRoot, relativePath: stagedRelativePath,
            conversationID: conversationID, cancellation: cancellation)
        if confirmed == true { return staged(true) }
        switch outcome {
        case .applied:
            // The engine confirmed the transfer but the live probe cannot
            // see the tree: an inconsistent engine state, reported as an
            // actionable failure rather than a ready path.
            return .unavailable(reason: SkillStageReason.liveWorkspaceSyncUnconfirmed(
                "appliedNotVisible"))
        case .refused(let reason):
            return .unavailable(reason: SkillStageReason.liveWorkspaceSyncRefused(reason))
        case .unconfirmed:
            return .unavailable(reason: SkillStageReason.liveWorkspaceSyncUnconfirmed(
                "transport"))
        case .noLiveWorkspace:
            return staged(false) // handled above; never reached
        }
    }

    /// Internal non-throwing carrier for the pre-publish resolution refusal.
    private struct SkillStageRefusal: Error {
        let reason: String
    }

    // MARK: - Bundle validation

    /// Normalizes the pinned snapshot into a writable bundle: valid skill id,
    /// lowercase 64-hex digest, safe relative paths, byte counts consistent
    /// with the validated manifest, and the staging-operation ceilings above
    /// (never a package profile budget — the install-time validator already
    /// enforced the admitting profile). The validator remains the authority
    /// for what a package may contain; this re-checks the staging safety
    /// boundary independently.
    public static func stagingBundle(
        manifestID: String,
        digest: String,
        declaredFiles: [SkillFile],
        bytes: [String: Data]
    ) -> SkillStagingBundle? {
        guard (try? SkillIdentifier.validate(manifestID)) != nil else { return nil }
        guard isCanonicalLowercaseHexDigest(digest) else { return nil }
        guard !declaredFiles.isEmpty, declaredFiles.count <= stagingFileCountCeiling else { return nil }
        var files: [SkillStagingBundle.File] = []
        var totalBytes = 0
        var seen: Set<String> = []
        for declared in declaredFiles.sorted(by: { $0.relativePath < $1.relativePath }) {
            let path = declared.relativePath
            guard seen.insert(path).inserted,
                  isSafeRelativePath(path) else { return nil }
            guard let data = bytes[path],
                  data.count == declared.byteCount,
                  data.count <= stagingFileBytesCeiling else { return nil }
            totalBytes += data.count
            guard totalBytes <= stagingTotalBytesCeiling else { return nil }
            files.append(.init(relativePath: path, data: data))
        }
        // Never carry bytes the pinned manifest does not declare.
        guard files.count == bytes.count else { return nil }
        return SkillStagingBundle(skillID: manifestID, digest: digest, files: files)
    }

    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= 512,
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\u{0}") else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment != "." && segment != ".."
        }
    }

    /// POSIX mode for a staged package file. The package model carries bytes
    /// and relative paths only (no SCM mode), so an executable shell/Python
    /// entry point under `scripts/` would otherwise lose its executable bit
    /// on every copy. A shebang-led file under `scripts/` is staged 0755;
    /// every other file keeps the platform default. This changes no byte, no
    /// digest and no verification result, and running the file still needs
    /// the normal approved exec.shell call.
    public static func stagedPermissions(relativePath: String, data: Data) -> Int? {
        guard relativePath.hasPrefix("scripts/"), data.count >= 2,
              data[data.startIndex] == 0x23,
              data[data.startIndex + 1] == 0x21 else { return nil }
        return 0o755
    }

    /// Best effort: a failed chmod never invalidates verified bytes. It only
    /// means direct execution still needs an explicit `sh <script>` until a
    /// later staging retry succeeds.
    private static func applyStagedPermissions(in root: URL, bundle: SkillStagingBundle) {
        for file in bundle.files {
            guard let mode = stagedPermissions(relativePath: file.relativePath, data: file.data) else {
                continue
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: mode],
                ofItemAtPath: root.appendingPathComponent(file.relativePath).path
            )
        }
    }

    // MARK: - Reserved root

    /// Creates the reserved `<workspace>/.floe/skills` tree step by step and
    /// refuses to proceed if any existing component is a symlink or a
    /// non-directory, so a planted link can never redirect writes outside the
    /// workspace. Concurrent stagers may race on creation; the loser simply
    /// validates the winner's directory instead of failing.
    public static func preparedReservedRoot(under workspaceRoot: URL) -> URL? {
        var current = workspaceRoot
        for component in reservedComponents {
            current = current.appendingPathComponent(component, isDirectory: true)
            if !FileManager.default.fileExists(atPath: current.path) {
                // A concurrent staging call may create it between the check and
                // the create; both outcomes are validated below.
                try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: false)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  !isSymbolicLink(current) else { return nil }
        }
        return current
    }

    // MARK: - Verification

    /// True only when `stagedRoot` is a non-symlink directory whose regular
    /// files exactly equal the bundle bytes, with the expected directory shape
    /// and no extra entry, symlink or special file anywhere.
    public static func verify(stagedRoot: URL, bundle: SkillStagingBundle) -> Bool {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: stagedRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              !isSymbolicLink(stagedRoot) else { return false }
        let prefix = stagedRoot.standardizedFileURL.path.hasSuffix("/")
            ? stagedRoot.standardizedFileURL.path
            : stagedRoot.standardizedFileURL.path + "/"
        var expected: [String: Data] = [:]
        var expectedDirectories: Set<String> = []
        for file in bundle.files {
            expected[file.relativePath] = file.data
            var parent = (file.relativePath as NSString).deletingLastPathComponent
            while !parent.isEmpty {
                expectedDirectories.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        guard let enumerator = fileManager.enumerator(
            at: stagedRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
            options: []
        ) else { return false }
        var foundFiles: Set<String> = []
        var foundDirectories: Set<String> = []
        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL
            guard standardized.path.hasPrefix(prefix) else { return false }
            let relative = String(standardized.path.dropFirst(prefix.count))
            guard isSafeRelativePath(relative) else { return false }
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey
            ]) } catch { return false }
            guard values.isSymbolicLink != true else { return false }
            if values.isDirectory == true {
                foundDirectories.insert(relative)
                continue
            }
            guard values.isRegularFile == true, let expectedData = expected[relative] else { return false }
            guard values.fileSize == expectedData.count else { return false }
            guard let onDisk = try? Data(contentsOf: url), onDisk == expectedData else { return false }
            foundFiles.insert(relative)
        }
        return foundFiles == Set(expected.keys) && foundDirectories == expectedDirectories
    }

    public static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true
    }

    /// A real directory: never a symlink (planted links must not be followed).
    public static func isPlainDirectory(_ url: URL) -> Bool {
        guard !isSymbolicLink(url) else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    public static func containsSymbolicLink(at root: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else { return true }
        for case let url as URL in enumerator {
            if isSymbolicLink(url) { return true }
        }
        return false
    }

    public static func sameDirectory(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.resolvingSymlinksInPath().standardizedFileURL ==
            rhs.resolvingSymlinksInPath().standardizedFileURL
    }

    // MARK: - Markers (advisory ownership records, never a trust source)

    private struct Marker: Codable {
        let digest: String
        let stagedAt: Date
    }

    public static func markerURL(leaf: String, in reservedRoot: URL) -> URL {
        reservedRoot
            .appendingPathComponent(markerDirectory, isDirectory: true)
            .appendingPathComponent("\(leaf).json")
    }

    /// Best effort. Markers are OUR advisory ownership records: nothing is
    /// ever trusted or deleted from them, so a missing or skipped marker never
    /// blocks reuse. A planted symlink at `.markers` or at the marker file is
    /// never followed, written through or replaced — the marker is simply not
    /// written and the verified tree stays valid.
    public static func writeMarker(leaf: String, digest: String, in reservedRoot: URL) {
        let markers = reservedRoot.appendingPathComponent(markerDirectory, isDirectory: true)
        if FileManager.default.fileExists(atPath: markers.path) {
            guard isPlainDirectory(markers) else { return }
        } else {
            try? FileManager.default.createDirectory(at: markers, withIntermediateDirectories: false)
            guard isPlainDirectory(markers) else { return }
        }
        let target = markerURL(leaf: leaf, in: reservedRoot)
        // An existing symlinked marker belongs to someone else: leave it.
        guard !isSymbolicLink(target) else { return }
        guard let data = try? JSONEncoder().encode(Marker(digest: digest, stagedAt: Date())) else { return }
        try? data.write(to: target, options: .atomic)
    }

    /// Exact ASCII lowercase hex SHA-256 shape: 64 UTF-8 bytes, each `0-9` or
    /// `a-f`. `Character.isLowercase` is FALSE for digits, so any case-property
    /// check rejects every real digest; the predicate must be byte-exact.
    public static func isCanonicalLowercaseHexDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { byte in
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
        }
    }

    /// Parses `<id>@<64hex>`; dot-prefixed internal entries never qualify.
    public static func parseLeaf(_ name: String) -> (skillID: String, digest: String)? {
        guard !name.hasPrefix("."), !name.hasPrefix("@"), !name.hasSuffix("@"),
              let at = name.lastIndex(of: "@") else { return nil }
        let id = String(name[..<at])
        let digest = String(name[name.index(after: at)...])
        guard (try? SkillIdentifier.validate(id)) != nil,
              isCanonicalLowercaseHexDigest(digest) else { return nil }
        return (id, digest)
    }

    // MARK: - Workspace-owned retention

    /// Removes ONLY this helper's abandoned staging temporaries. Ownership is
    /// proved by all of: the exact `.staging-` prefix plus a canonical
    /// `UUID().uuidString` round-trip (the prefix alone is never enough), a
    /// real non-symlink directory whose subtree contains no symlink, and an
    /// age beyond `staleStagingTemporaryAge` (an in-flight stage renames
    /// within seconds). Content-addressed bundles and markers are NEVER
    /// removed here: a pinned tree is retained for the task's lifetime and
    /// released with the workspace itself, so a long-running run keeps the
    /// tree it is executing from.
    public static func pruneStaleStagingTemps(in reservedRoot: URL, now: Date = Date()) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: reservedRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: []
        ) else { return }
        for url in entries {
            let name = url.lastPathComponent
            guard name.hasPrefix(stagingPrefix) else { continue }
            // Defense in depth: a well-formed content leaf is never removed.
            guard parseLeaf(name) == nil else { continue }
            let suffix = String(name.dropFirst(stagingPrefix.count))
            guard let uuid = UUID(uuidString: suffix), uuid.uuidString == suffix else { continue }
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey
            ])
            guard values?.isSymbolicLink != true,
                  values?.isDirectory == true,
                  let createdAt = values?.contentModificationDate,
                  now.timeIntervalSince(createdAt) > staleStagingTemporaryAge else { continue }
            // A temporary that grew a symlink is left exactly as found.
            guard !containsSymbolicLink(at: url) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Model-facing section (bounded; no host paths, no per-file hashes)

    /// One compact section appended to an exact read's Markdown. The guest can
    /// enumerate real staged files with `ls` once the workspace import has run;
    /// the structured `resources` metadata keeps the root visible even when
    /// this section is not on the first page. Bytes and digests remain pinned
    /// internally.
    public static func resourceFooter(
        id: String,
        pinnedSHA256: String,
        declaredFiles: [SkillFile],
        outcome: SkillStageOutcome
    ) -> String {
        var section = "\n\n## Package files (Linux task workspace)\n"
        switch outcome {
        case .staged(let bundle):
            section += "staged=true\npinnedSHA256=\(bundle.pinnedSHA256)\nguestRoot=\(bundle.guestRoot)\n"
            section += "visibleInGuest=\(bundle.visibleInGuest)\nfileCount=\(bundle.fileCount)\n"
            section += "rootContents: \(summarizeRootContents(declaredFiles))\n"
            section += "Upstream guide references to sibling package files resolve under this `guestRoot`. "
            if bundle.visibleInGuest {
                section += "The guest can list every staged file now with `ls -R \(bundle.guestRoot)`. "
            } else {
                section += "The tree is committed in the task workspace and becomes visible at the guest path at the next workspace import boundary — run any command through exec.shell (for example `ls -R \(bundle.guestRoot)`) to materialize it. "
            }
            section += "This tree is a Floe-managed cache inside the task workspace: do not edit or commit it. "
            section += "Nothing was executed; scripts run only through the normal exec.shell approval flow, "
            section += "either from the pasted audited source or the staged copy — both are the same pinned bytes.\n"
        case .unavailable(let reason):
            section += "staged=false\npinnedSHA256=\(pinnedSHA256)\n"
            section += "fileCount=\(declaredFiles.count)\nreason=\(reason)\n"
            section += "The bundled assets/references are not available as files in the guest for this read. "
            section += "The pasted audited script sources above remain the only fallback; do not invent replacement bytes.\n"
        }
        return section
    }

    public static func summarizeRootContents(_ files: [SkillFile]) -> String {
        var rootFiles: [String] = []
        var directories: [String: Int] = [:]
        for file in files.sorted(by: { $0.relativePath < $1.relativePath }) {
            let segments = file.relativePath.split(separator: "/")
            if segments.count == 1 {
                rootFiles.append(file.relativePath)
            } else {
                directories[String(segments[0]), default: 0] += 1
            }
        }
        let summary = directories.keys.sorted().map { "\($0) (\(directories[$0]!) files)" }
        return (rootFiles + summary).joined(separator: ", ")
    }
}
