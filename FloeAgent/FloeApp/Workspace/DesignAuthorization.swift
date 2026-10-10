// FloeApp — Design adoption authorization.
//
// A narrow adapter over the existing `FloeSecurity.ApprovalGrantStore`: the
// design panel mints a single-use, expiring grant bound to the exact
// canvas/node/candidate/baseline tokens, and `canvas.designAdopt` consumes it
// only after its transaction succeeds. This is a binding over the existing
// authorization store, not a parallel approval policy: nothing here grants
// permissions the approval pipeline did not already allow.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeSecurity

actor DesignAdoptionAuthorization {
    static let shared = DesignAdoptionAuthorization()

    private let store = ApprovalGrantStore()
    private var issuedGrantIDs: Set<UUID> = []
    private static let toolName = "canvas.designAdopt"

    private static func tokens(
        canvasID: UUID, nodeID: UUID, candidateID: String, baselineRevisionID: String
    ) -> [String] {
        [
            "canvas:\(canvasID.uuidString.lowercased())",
            "node:\(nodeID.uuidString.lowercased())",
            "candidate:\(candidateID)",
            "baseline:\(baselineRevisionID)"
        ]
    }

    @discardableResult
    func issue(
        canvasID: UUID,
        nodeID: UUID,
        candidateID: String,
        baselineRevisionID: String,
        ttl: TimeInterval = 300
    ) async -> String {
        let scope = ApprovalScope(
            toolName: Self.toolName,
            hostID: nil,
            paths: Self.tokens(
                canvasID: canvasID, nodeID: nodeID,
                candidateID: candidateID, baselineRevisionID: baselineRevisionID
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

    func validate(
        id: String,
        canvasID: UUID,
        nodeID: UUID,
        candidateID: String,
        baselineRevisionID: String
    ) async -> Bool {
        guard let uuid = UUID(uuidString: id), let grant = await store.grant(id: uuid) else { return false }
        return grant.scope.toolName == Self.toolName
            && grant.scope.paths == Self.tokens(
                canvasID: canvasID, nodeID: nodeID,
                candidateID: candidateID, baselineRevisionID: baselineRevisionID
            )
    }

    @discardableResult
    func consume(
        id: String,
        canvasID: UUID,
        nodeID: UUID,
        candidateID: String,
        baselineRevisionID: String
    ) async -> Bool {
        guard let uuid = UUID(uuidString: id), let grant = await store.grant(id: uuid) else { return false }
        guard grant.scope.toolName == Self.toolName,
              grant.scope.paths == Self.tokens(
                canvasID: canvasID, nodeID: nodeID,
                candidateID: candidateID, baselineRevisionID: baselineRevisionID
              ) else { return false }
        await store.consumeIfSingleUse(grant)
        issuedGrantIDs.remove(uuid)
        return true
    }

    func revokeAll() async {
        for id in issuedGrantIDs { await store.revoke(id: id) }
        issuedGrantIDs.removeAll()
    }
}
#endif
