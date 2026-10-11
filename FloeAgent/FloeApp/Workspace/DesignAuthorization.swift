// FloeApp — Design adoption authorization.
//
// A narrow adapter over the existing `FloeSecurity.ApprovalGrantStore`: the
// design panel mints a single-use, expiring grant bound to the exact
// canvas/node/candidate/baseline/proposed-revision/mode tokens, and
// `canvas.designAdopt` CLAIMS it atomically inside the shared Canvas
// transaction, after every read-only pre-flight check and before the first
// side effect. This is a binding over the existing authorization store, not a
// parallel approval policy: nothing here grants permissions the approval
// pipeline did not already allow.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeSecurity

actor DesignAdoptionAuthorization {
    static let shared = DesignAdoptionAuthorization()

    private let store = ApprovalGrantStore()
    private var issuedGrantIDs: Set<UUID> = []
    private static let toolName = "canvas.designAdopt"

    /// The exact operation tokens. `mode` and the proposed revision are part
    /// of the binding: a grant minted for one mode/revision can never be
    /// replayed for another (an old process-local grant that lacks them simply
    /// never matches and requires a fresh confirmation — never a bypass).
    private static func tokens(
        canvasID: UUID, nodeID: UUID, candidateID: String,
        baselineRevisionID: String, proposedRevisionID: String, mode: DesignAdoptMode
    ) -> [String] {
        [
            "canvas:\(canvasID.uuidString.lowercased())",
            "node:\(nodeID.uuidString.lowercased())",
            "candidate:\(candidateID)",
            "baseline:\(baselineRevisionID)",
            "proposed:\(proposedRevisionID)",
            "mode:\(mode.rawValue)"
        ]
    }

    @discardableResult
    func issue(
        canvasID: UUID,
        nodeID: UUID,
        candidateID: String,
        baselineRevisionID: String,
        proposedRevisionID: String,
        mode: DesignAdoptMode,
        ttl: TimeInterval = 300
    ) async -> String {
        let scope = ApprovalScope(
            toolName: Self.toolName,
            hostID: nil,
            paths: Self.tokens(
                canvasID: canvasID, nodeID: nodeID,
                candidateID: candidateID, baselineRevisionID: baselineRevisionID,
                proposedRevisionID: proposedRevisionID, mode: mode
            ),
            singleUse: true,
            toolAuthorizationIdentity: nil
        )
        let grant = ApprovalGrant(
            scope: scope,
            expiresAt: Date().addingTimeInterval(ttl),
            policyName: "design.adoption.user-minted"
        )
        await store.add(grant)
        issuedGrantIDs.insert(grant.id)
        return grant.id.uuidString.lowercased()
    }

    /// Read-only diagnostic; reserves nothing. The authoritative gate for a
    /// run/AI adoption is `claim`, which validates AND burns atomically.
    func validate(
        id: String,
        canvasID: UUID,
        nodeID: UUID,
        candidateID: String,
        baselineRevisionID: String,
        proposedRevisionID: String,
        mode: DesignAdoptMode
    ) async -> Bool {
        guard let uuid = UUID(uuidString: id), let grant = await store.grant(id: uuid) else { return false }
        return grant.scope.toolName == Self.toolName
            && grant.scope.paths == Self.tokens(
                canvasID: canvasID, nodeID: nodeID,
                candidateID: candidateID, baselineRevisionID: baselineRevisionID,
                proposedRevisionID: proposedRevisionID, mode: mode
            )
    }

    /// THE authoritative single-use gate: one actor call through the existing
    /// `ApprovalGrantStore.claimSingleUse` validates the exact
    /// canvas/node/candidate/baseline/proposed/mode binding and burns the
    /// grant in the same step (never a read-then-burn pair with a window in
    /// between). A mismatch/expiry/revocation/concurrent second claim returns
    /// false and burns nothing. A caller that fails after a successful claim
    /// must obtain a FRESH confirmation; the store never re-arms it.
    @discardableResult
    func claim(
        id: String,
        canvasID: UUID,
        nodeID: UUID,
        candidateID: String,
        baselineRevisionID: String,
        proposedRevisionID: String,
        mode: DesignAdoptMode
    ) async -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        let scopeToClaim = ApprovalScope(
            toolName: Self.toolName,
            hostID: nil,
            paths: Self.tokens(
                canvasID: canvasID, nodeID: nodeID,
                candidateID: candidateID, baselineRevisionID: baselineRevisionID,
                proposedRevisionID: proposedRevisionID, mode: mode
            ),
            singleUse: true,
            toolAuthorizationIdentity: nil
        )
        guard await store.claimSingleUse(id: uuid, matching: scopeToClaim) != nil else {
            return false
        }
        issuedGrantIDs.remove(uuid)
        return true
    }

    /// Compatibility wrapper with the SAME atomic semantics as `claim`
    /// (kept so the published name keeps its meaning; it never resurrects the
    /// old read-then-burn window).
    @discardableResult
    func consume(
        id: String,
        canvasID: UUID,
        nodeID: UUID,
        candidateID: String,
        baselineRevisionID: String,
        proposedRevisionID: String,
        mode: DesignAdoptMode
    ) async -> Bool {
        await claim(
            id: id, canvasID: canvasID, nodeID: nodeID,
            candidateID: candidateID, baselineRevisionID: baselineRevisionID,
            proposedRevisionID: proposedRevisionID, mode: mode
        )
    }

    func revokeAll() async {
        for id in issuedGrantIDs { await store.revoke(id: id) }
        issuedGrantIDs.removeAll()
    }
}

/// Narrow composition over the EXISTING approval grant store for non-canvas
/// design targets (workspace file sources). It grants no new permission: a
/// file read/adopt through the design workflow is allowed only when the
/// caller already holds an unexpired single-use or path grant for that tool
/// and normalized workspace-relative reference. Canvas nodes keep their
/// run→canvas closure; chat/creative sources keep their origin checks.
actor DesignOwnerAuthorization {
    static let shared = DesignOwnerAuthorization()

    private let store: ApprovalGrantStore

    /// The store is the existing in-memory approval grant store. Tests and
    /// the panel pass explicit instances to share ONE confirmation service;
    /// `.shared` is the app composition default.
    init(store: ApprovalGrantStore = ApprovalGrantStore()) {
        self.store = store
    }

    private static func pathTokens(
        workspaceID: UUID,
        reference: String
    ) -> [String] {
        ["workspace:\(workspaceID.uuidString.lowercased())", "file:\(reference)"]
    }

    /// True when an unexpired grant for `toolName` carries the exact
    /// workspace + normalized reference tokens (or a workspace-wide token).
    func isAuthorized(
        toolName: String,
        workspaceID: UUID,
        reference: String
    ) async -> Bool {
        let normalized = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.contains(".."),
              !normalized.hasPrefix("/") else { return false }
        let required = Self.pathTokens(workspaceID: workspaceID, reference: normalized)
        let workspaceWide = "workspace:\(workspaceID.uuidString.lowercased())"
        return await isAuthorized(
            toolName: toolName,
            tokens: required,
            alternativeTokens: [workspaceWide]
        )
    }

    /// Generic token grant check used by the creative START flow: an
    /// unexpired grant for `toolName` must carry every required token (or
    /// one of the alternative tokens). No new permission semantics are
    /// introduced — this is the same `ApprovalGrantStore` consulted by the
    /// canvas adoption grant.
    func isAuthorized(
        toolName: String,
        tokens: [String],
        alternativeTokens: [String] = []
    ) async -> Bool {
        guard !tokens.isEmpty else { return false }
        let required = Set(tokens)
        let alternatives = Set(alternativeTokens)
        let now = Date()
        let grants = await store.allGrants
        return grants.contains { grant in
            guard (grant.expiresAt ?? .distantFuture) > now else { return false }
            guard grant.scope.toolName == toolName else { return false }
            let paths = Set(grant.scope.paths)
            return paths.isSuperset(of: required)
                || (!alternatives.isEmpty && !paths.isDisjoint(with: alternatives))
        }
    }

    // MARK: - Typed-owner adoption confirmation (T5)
    //
    // The user's CONCRETE confirmation for adopting a candidate on a
    // non-canvas target. It is deliberately the SAME `ApprovalGrantStore`
    // instance as the other owner checks (and the same single-use/expiry
    // pattern as `DesignAdoptionAuthorization` for canvas), so the trusted
    // UI panel and the AI tool share one confirmation service: the panel
    // mints a grant after the user confirms the exact change, the run
    // presents its id, and `design.adopt` CLAIMS it atomically inside the
    // shared adoption transaction, before the first side effect. This does
    // not widen source access: file/chat/creative containment is still
    // enforced live by the owner adapters; this only proves the user
    // confirmed this exact candidate, baseline and mode.

    static let ownerAdoptToolName = "design.ownerAdopt"

    /// Which caller surface the confirmation was minted for. A grant minted
    /// for one surface can never be consumed by another.
    public enum OwnerAdoptScope: String, Sendable {
        case aiTool = "ai-tool"
        case trustedUI = "trusted-ui"
    }

    private static func ownerAdoptTokens(
        targetStableKey: String,
        candidateID: String,
        baselineRevisionID: String,
        proposedRevisionID: String,
        mode: DesignAdoptMode,
        scope: OwnerAdoptScope
    ) -> [String] {
        [
            "target:\(targetStableKey)",
            "candidate:\(candidateID)",
            "baseline:\(baselineRevisionID)",
            "proposed:\(proposedRevisionID)",
            "mode:\(mode.rawValue)",
            "scope:\(scope.rawValue)"
        ]
    }

    /// Trusted UI mints the single-use confirmation after the user approves
    /// the exact candidate/base/proposed-revision/mode. Agent tools never
    /// call this. Returns the grant id handed to the run as `grantID`.
    @discardableResult
    func issueOwnerAdoption(
        targetStableKey: String,
        candidateID: String,
        baselineRevisionID: String,
        proposedRevisionID: String,
        mode: DesignAdoptMode,
        scope: OwnerAdoptScope = .trustedUI,
        ttl: TimeInterval = 300
    ) async -> String {
        let grant = ApprovalGrant(
            scope: ApprovalScope(
                toolName: Self.ownerAdoptToolName,
                paths: Self.ownerAdoptTokens(
                    targetStableKey: targetStableKey, candidateID: candidateID,
                    baselineRevisionID: baselineRevisionID,
                    proposedRevisionID: proposedRevisionID,
                    mode: mode, scope: scope),
                singleUse: true),
            expiresAt: Date().addingTimeInterval(ttl),
            policyName: "design.owner-adoption.user-minted")
        await store.add(grant)
        return grant.id.uuidString.lowercased()
    }

    /// Validates a confirmation WITHOUT consuming it (used only as a
    /// non-binding diagnostic and by the trusted-UI direct path; it does
    /// NOT reserve anything). Checks tool name, exact target/candidate/
    /// baseline/proposed-revision/mode/scope tokens, expiry and single-use
    /// state against the current store. The authoritative gate for any
    /// run/AI adoption is `claimOwnerAdoption`, which reserves atomically.
    func validateOwnerAdoption(
        grantID: String,
        targetStableKey: String,
        candidateID: String,
        baselineRevisionID: String,
        proposedRevisionID: String,
        mode: DesignAdoptMode,
        scope: OwnerAdoptScope
    ) async -> Bool {
        guard let uuid = UUID(uuidString: grantID),
              let grant = await store.grant(id: uuid) else { return false }
        return grant.scope.toolName == Self.ownerAdoptToolName
            && Set(grant.scope.paths) == Set(Self.ownerAdoptTokens(
                targetStableKey: targetStableKey, candidateID: candidateID,
                baselineRevisionID: baselineRevisionID,
                proposedRevisionID: proposedRevisionID,
                mode: mode, scope: scope))
    }

    /// THE authoritative single-use gate: atomically validates AND burns the
    /// user's confirmation through the EXISTING `ApprovalGrantStore`
    /// (`claimSingleUse`), before the caller performs its first side effect.
    /// - A valid grant authorizes exactly the one frozen operation it names
    ///   (target/candidate/baseline/proposed revision/mode/caller scope);
    ///   any other operation cannot reuse it.
    /// - A mismatch, a missing/revoked/expired grant, or an already claimed
    ///   grant returns false WITHOUT burning anything (a mismatched claim
    ///   never consumes the user's confirmation).
    /// - Revocation or expiry that lands before the claim blocks the write:
    ///   the check and the burn are one actor call, never a read-then-burn
    ///   pair with a window in between.
    /// - The claim is immutable: a caller that fails after claiming (even a
    ///   proven zero-write failure) must obtain a FRESH concrete
    ///   confirmation to retry; the store never re-arms a claimed grant
    ///   automatically. Replays of an already applied operation do not
    ///   reach this gate at all (the shared service returns the recorded
    ///   result first).
    @discardableResult
    func claimOwnerAdoption(
        grantID: String,
        targetStableKey: String,
        candidateID: String,
        baselineRevisionID: String,
        proposedRevisionID: String,
        mode: DesignAdoptMode,
        scope: OwnerAdoptScope
    ) async -> Bool {
        guard let uuid = UUID(uuidString: grantID) else { return false }
        let scopeToClaim = ApprovalScope(
            toolName: Self.ownerAdoptToolName,
            paths: Self.ownerAdoptTokens(
                targetStableKey: targetStableKey, candidateID: candidateID,
                baselineRevisionID: baselineRevisionID,
                proposedRevisionID: proposedRevisionID,
                mode: mode, scope: scope),
            singleUse: true)
        return await store.claimSingleUse(id: uuid, matching: scopeToClaim) != nil
    }

    /// Compatibility wrapper: atomically claims the single-use confirmation
    /// (same semantics as `claimOwnerAdoption`). Kept so existing callers
    /// keep the published name; new code should call `claimOwnerAdoption`
    /// at the transaction boundary instead of validate-then-consume.
    @discardableResult
    func consumeOwnerAdoption(
        grantID: String,
        targetStableKey: String,
        candidateID: String,
        baselineRevisionID: String,
        proposedRevisionID: String,
        mode: DesignAdoptMode,
        scope: OwnerAdoptScope
    ) async -> Bool {
        await claimOwnerAdoption(
            grantID: grantID, targetStableKey: targetStableKey,
            candidateID: candidateID, baselineRevisionID: baselineRevisionID,
            proposedRevisionID: proposedRevisionID, mode: mode, scope: scope)
    }
}
#endif
