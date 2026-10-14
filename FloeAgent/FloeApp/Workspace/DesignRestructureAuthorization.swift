// FloeApp — Trusted 重构 (restructure) preservation authority.
//
// A Codable `DesignPreservationConfirmation` is DATA: raw model JSON can
// mint one with a matching digest. Authority for a restructure lives ONLY in
// a single-use claim burned here over the EXISTING FloeSecurity
// `ApprovalGrantStore` — the same store the canvas/owner adoption
// confirmations use. The trusted UI (preservation-confirmation sheet) mints
// the grant after the user confirms the exact preservation requirements;
// `DesignOwnerWorkflow.propose` then pulls a `DesignRestructureAuthorityHandler`
// from this actor, which finds the ONE live grant whose tokens bind the
// entire request identity (target, original task, base revision,
// constraints digest, operation) and burns it atomically BEFORE any
// candidate bytes are staged.
//
// Invariants:
// - Data ≠ authority: no string/boolean/JSON field anywhere can mint or
//   substitute for the claim. The receipt crossing the service boundary is
//   NON-Codable, so tool arguments and imported metadata can never carry it.
// - Single-use: one confirmation authorizes exactly one propose. A replay
//   returns the recorded candidate WITHOUT calling the handler again (the
//   core service gates replay first), so a replay never burns a second
//   claim. A failed propose after a successful claim requires a FRESH
//   confirmation; the store never re-arms.
// - Whole-request binding: the grant tokens cover target stable key,
//   original task, base revision, constraints digest AND the frozen
//   operation identity. A stale base (manual edit landed in between) or a
//   different operation simply has no live claim → propose fails closed
//   with zero staged bytes.

import Foundation
import FloeCore
import FloeSecurity

actor DesignRestructureAuthorization {
    static let shared = DesignRestructureAuthorization()

    static let restructureToolName = "design.restructure"

    private let store: ApprovalGrantStore

    /// Tests and the panel pass explicit instances to share ONE confirmation
    /// service; `.shared` is the app composition default.
    init(store: ApprovalGrantStore = ApprovalGrantStore()) {
        self.store = store
    }

    private static func tokens(
        targetKey: String,
        operationID: String,
        baseRevisionID: String?,
        preservationDigest: String,
        originalTaskOwnerID: String?
    ) -> [String] {
        [
            "target:\(targetKey)",
            "operation:\(operationID)",
            "base:\(baseRevisionID ?? "-")",
            "digest:\(preservationDigest)",
            "origin:\(originalTaskOwnerID ?? "-")",
            "mode:\(DesignWorkMode.restructure.rawValue)"
        ]
    }

    /// Trusted UI only: mint the single-use preservation confirmation after
    /// the user approved the exact constraints for exactly this restructure.
    /// Agent tools never call this. Returns the grant id for the sheet's
    /// audit display.
    @discardableResult
    func issueRestructureConfirmation(
        targetKey: String,
        operationID: String,
        baseRevisionID: String?,
        preservationDigest: String,
        originalTaskOwnerID: String?,
        ttl: TimeInterval = 300
    ) async -> String {
        let grant = ApprovalGrant(
            scope: ApprovalScope(
                toolName: Self.restructureToolName,
                hostID: nil,
                paths: Self.tokens(
                    targetKey: targetKey, operationID: operationID,
                    baseRevisionID: baseRevisionID,
                    preservationDigest: preservationDigest,
                    originalTaskOwnerID: originalTaskOwnerID),
                singleUse: true,
                toolAuthorizationIdentity: nil),
            expiresAt: Date().addingTimeInterval(ttl),
            policyName: "design.restructure.user-minted")
        await store.add(grant)
        return grant.id.uuidString.lowercased()
    }

    /// Non-binding diagnostic only; never gates anything.
    func hasLiveClaim(
        targetKey: String,
        operationID: String,
        baseRevisionID: String?,
        preservationDigest: String,
        originalTaskOwnerID: String?
    ) async -> Bool {
        let expected = Self.tokens(
            targetKey: targetKey, operationID: operationID,
            baseRevisionID: baseRevisionID,
            preservationDigest: preservationDigest,
            originalTaskOwnerID: originalTaskOwnerID)
        let now = Date()
        let grants = await store.allGrants
        return grants.contains { grant in
            (grant.expiresAt ?? .distantFuture) > now
                && grant.scope.toolName == Self.restructureToolName
                && Set(grant.scope.paths) == Set(expected)
        }
    }

    /// The trusted authority handler the core service calls BEFORE staging
    /// any candidate bytes. The service builds the exact request (target,
    /// original task, resolved base revision, constraints digest, intent
    /// operation); this handler finds the ONE unexpired single-use grant
    /// whose tokens bind that ENTIRE identity and burns it atomically. No
    /// live claim → `claimRequired` (propose fails closed, zero staging).
    func makeAuthorityHandler() -> DesignRestructureAuthorityHandler {
        { [store] request in
            let expected = Self.tokens(
                targetKey: request.targetKey,
                operationID: request.operationID,
                baseRevisionID: request.baseRevisionID,
                preservationDigest: request.preservationDigest,
                originalTaskOwnerID: request.originalTaskOwnerID)
            let scopeToClaim = ApprovalScope(
                toolName: Self.restructureToolName,
                hostID: nil,
                paths: expected,
                singleUse: true,
                toolAuthorizationIdentity: nil)
            let now = Date()
            let candidates = await store.allGrants.filter { grant in
                (grant.expiresAt ?? .distantFuture) > now
                    && grant.scope.toolName == Self.restructureToolName
                    && Set(grant.scope.paths) == Set(expected)
            }
            // Burn the first live match atomically. claimSingleUse validates
            // the exact scope AND consumes it in one actor call, so two
            // racing proposes can never both succeed; the loser gets
            // claimRequired and must obtain a fresh confirmation.
            for candidate in candidates {
                if let grant = await store.claimSingleUse(id: candidate.id, matching: scopeToClaim) {
                    return DesignRestructureAuthorityReceipt(
                        request: request, claimID: grant.id)
                }
            }
            throw DesignRestructureAuthorityError.claimRequired(
                "no live trusted preservation claim for restructure \(request.targetKey) op=\(request.operationID); a matching Codable confirmation is data, never authority")
        }
    }
}
