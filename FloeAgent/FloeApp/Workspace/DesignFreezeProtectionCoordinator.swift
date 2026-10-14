// FloeApp — Design freeze protection coordinator.
//
// Bridges the durable launch binding (typed target + frozen work mode) and
// the shared FloeCore `DesignFreezeRegistry` so ordinary workspace writes
// cannot overwrite a design original while its candidate is pending:
//
// - `establish` runs inside `ConversationCenter.startTask` right after the
//   launch binding is persisted: a fileDocument target's workspace file is
//   frozen (canonical path + device/inode identity + frozen SHA) BEFORE the
//   deferred run task can reach the provider or any tool.
// - `release` runs on the verified adoption commit (the trusted commit port)
//   and on candidate rejection, and wholesale when a design task ends.
// - `reconcile` runs at launch: protections whose conversation no longer
//   exists (or whose envelope has no pending candidate and no confirmed
//   restructure) are dropped, so a crash can never leave a source frozen
//   forever. The registry is durable, so this also covers restarts.
//
// Trusted manual edits never pass through the agent tool services, so they
// are not gated; they move the file and the adoption gate's frozen-SHA
// optimistic check fails closed instead.

import Foundation
import FloeCore
import FloePersistence

@MainActor
enum DesignFreezeProtectionCoordinator {
    /// Test seam: unit tests swap in an isolated registry; the app never
    /// sets it, so production always uses the shared durable registry.
    nonisolated(unsafe) static var registryOverride: DesignFreezeRegistry?
    static var registry: DesignFreezeRegistry { registryOverride ?? .shared }

    /// Freezes the binding's original source (fileDocument targets only —
    /// chat attachments live in app storage the workspace tools cannot
    /// address, and creative sources materialize at first bind).
    ///
    /// Returns true only when the required original is protected AND the
    /// protection is provably DURABLE (written through the registry store
    /// and read back). Directory originals (a webroot) freeze the whole
    /// tree of existing files; a regular-file original freezes its exact
    /// canonical path + (device, inode). Every failure mode (no workspace
    /// store, unresolvable bookmark, missing source, persistence failure)
    /// cleans up the in-memory half-entry and returns false: an explicit
    /// bound modification/restructure of a file original MUST fail closed at
    /// launch rather than run unprotected — the caller aborts the launch
    /// and the user retries.
    @discardableResult
    static func establish(
        binding: DesignLaunchBinding,
        conversationID: UUID,
        workspaceStore: (any WorkspaceStore)?
    ) async -> Bool {
        guard binding.target.kind == .fileDocument,
              let workspaceStore,
              let workspaceUUID = UUID(uuidString: binding.target.ownerID) else { return false }
        guard let record = try? await workspaceStore.workspace(id: workspaceUUID) else { return false }
        var isStale = false
        guard let root = try? URL(
            resolvingBookmarkData: record.rootBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return false }
        let accessing = root.startAccessingSecurityScopedResource()
        defer { if accessing { root.stopAccessingSecurityScopedResource() } }
        let relative = binding.target.sourceID
        guard !relative.isEmpty else { return false }
        let url = root.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        let owner = conversationID.uuidString.lowercased()
        let frozenSHA: String
        if isDirectory.boolValue {
            // Webroot original: the whole tree of existing files is frozen;
            // per-file digests live on the design revisions.
            frozenSHA = ""
        } else {
            guard let sha = try? WorkspaceFileOwnerCommitPortSHA.sha256(of: url) else {
                return false
            }
            frozenSHA = sha
        }
        let persistence = registry.protect(url, conversationID: owner, frozenSHA256: frozenSHA)
        // Durable proof through the actual store: an in-memory entry alone
        // is never accepted (a crash would leave the launch unprotected AND
        // the source frozen in-memory only — worse than no freeze).
        let verified = registry.verifyPersisted(url, conversationID: owner)
        guard case .persisted = persistence, verified else {
            registry.unprotect(url, conversationID: owner)
            return false
        }
        return true
    }

    /// Post-decision protection outcome for trusted UI / tool callers.
    enum DecisionResolution: Sendable, Equatable {
        /// Pending candidates remain: the freeze stays untouched.
        case keptPending
        /// No pending candidate and no active run: this target's scope was
        /// released for this owner.
        case released
        /// A verified adoption landed and the NEW approved baseline was
        /// re-frozen for this owner.
        case rearmed
        /// A verified adoption landed but the re-arm FAILED (persistence or
        /// resolution): the previous protection is KEPT (fail closed — model
        /// writes stay blocked), recoverable state is retained, and the
        /// caller must surface this error to the user.
        case rearmFailed
    }

    /// Releases ONE TARGET's source scope for ONE owner when its envelope
    /// has no pending candidate. A conversation can hold SEVERAL design
    /// targets (a file plus several attachments): resolving target A must
    /// never release target B's still-pending original in the same
    /// conversation, so this is never `unprotectAll`.
    static func releaseTargetScopeIfResolved(
        target: DesignTarget,
        conversationID: String,
        envelope: DesignOwnerEnvelope,
        workspaceStore: (any WorkspaceStore)?
    ) async {
        guard target.kind == .fileDocument else { return }
        let pending = envelope.project.candidates.contains { $0.status == .pending }
        guard !pending else { return }
        await releaseTargetScope(target: target, conversationID: conversationID, workspaceStore: workspaceStore)
    }

    /// Releases exactly the target's source scope (exact canonical path —
    /// the file, or the webroot root for a directory original) for one
    /// owner. Other targets of the same conversation and other owners of
    /// the same source keep their freezes.
    static func releaseTargetScope(
        target: DesignTarget,
        conversationID: String,
        workspaceStore: (any WorkspaceStore)?
    ) async {
        guard target.kind == .fileDocument,
              let workspaceStore,
              let workspaceUUID = UUID(uuidString: target.ownerID),
              let record = try? await workspaceStore.workspace(id: workspaceUUID) else { return }
        var isStale = false
        guard let root = try? URL(
            resolvingBookmarkData: record.rootBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return }
        let owner = conversationID.lowercased()
        guard !owner.isEmpty else { return }
        registry.unprotect(
            root.appendingPathComponent(target.sourceID),
            conversationID: owner)
    }

    /// Post-decision protection for TRUSTED UI sites (the owner panel):
    /// - pending candidates remain → keep the freeze (nothing to decide).
    /// - no pending + a design run is still active → keep the freeze: the
    ///   verified adoption replaced the bytes, so the baseline is
    ///   re-established (adoption) or left untouched (rejection), and the
    ///   active run must not gain direct-write rights (staged-adoption
    ///   contract holds until the run ends; the run-end hook then releases).
    /// - no pending + no active run → the design work is resolved NOW:
    ///   release exactly THIS target's scope (never a sibling target's).
    ///
    /// A re-arm failure KEEPS the previous protection (fail closed) and is
    /// reported to the caller as `.rearmFailed` — the model's next ordinary
    /// write is still refused, recoverable state is retained, and the user
    /// sees the real failure instead of an assumed-success void.
    static func resolveAfterDecision(
        binding: DesignLaunchBinding,
        conversationID: UUID,
        envelope: DesignOwnerEnvelope,
        runIsActive: Bool,
        workspaceStore: (any WorkspaceStore)?
    ) async -> DecisionResolution {
        let pending = envelope.project.candidates.contains { $0.status == .pending }
        if pending { return .keptPending }
        if runIsActive {
            if envelope.project.candidates.contains(where: { $0.status == .adopted }) {
                // A verified adoption landed: re-freeze the CURRENT bytes as
                // the approved baseline. Failure keeps the previous
                // protection and reports the failure — never a silent void.
                let rearmed = await establish(
                    binding: binding, conversationID: conversationID,
                    workspaceStore: workspaceStore)
                return rearmed ? .rearmed : .rearmFailed
            }
            return .keptPending
        }
        await releaseTargetScope(
            target: binding.target,
            conversationID: conversationID.uuidString,
            workspaceStore: workspaceStore)
        return .released
    }

    /// Run-end lifecycle: a COMPLETED design run whose envelope has no
    /// pending candidate is the safe resolution point — THIS target's scope
    /// lifts (never a sibling target's in the same conversation). A pending
    /// candidate keeps the original protected; failed/checkpointed runs keep
    /// theirs (a continuation re-establishes before its next I/O).
    static func releaseAfterCompletedRun(
        binding: DesignLaunchBinding,
        conversationID: UUID,
        envelope: DesignOwnerEnvelope?,
        workspaceStore: (any WorkspaceStore)?
    ) async {
        guard binding.target.kind == .fileDocument,
              binding.workMode == .modify || binding.workMode == .restructure,
              let envelope else { return }
        await releaseTargetScopeIfResolved(
            target: binding.target,
            conversationID: conversationID.uuidString,
            envelope: envelope,
            workspaceStore: workspaceStore)
    }

    /// Releases every freeze owned by the conversation (task ended, design
    /// cancelled, candidate rejected from the panel).
    static func release(conversationID: UUID) {
        registry.unprotectAll(conversationID: conversationID.uuidString.lowercased())
    }

    /// Releases one frozen source after a verified adoption commit.
    static func release(url: URL) {
        registry.unprotect(url)
    }

    /// Launch reconciliation: drop protections whose owning conversation is
    /// gone from the database.
    static func reconcile(
        conversationExists: (String) async -> Bool
    ) async {
        let protections = registry.allProtections()
        for protection in protections
        where !(await conversationExists(protection.conversationID)) {
            registry.unprotect(
                URL(fileURLWithPath: protection.canonicalPath))
        }
    }
}

/// Small file-SHA helper so the coordinator does not depend on the whole
/// workspace module (which the host adapter already owns).
enum WorkspaceFileOwnerCommitPortSHA {
    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return FloeDigest.sha256Hex(data)
    }
}
