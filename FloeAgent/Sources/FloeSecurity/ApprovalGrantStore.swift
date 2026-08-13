// FloeSecurity — In-memory approval grant store with expiry enforcement.

import Foundation
import FloeCore

/// Holds active approval grants for the current process lifetime. Persistent
/// grants are mirrored into GRDB by the runtime; this store is the fast path
/// consulted during execution.
public actor ApprovalGrantStore {
    private var grants: [UUID: ApprovalGrant] = [:]
    private var burnedSingleUse: Set<UUID> = []

    public init() {}

    /// Registers a grant. Existing grants with the same id are replaced.
    public func add(_ grant: ApprovalGrant) {
        grants[grant.id] = grant
    }

    /// Looks up a live grant by id. Expired or burned grants return nil.
    public func grant(id: UUID, at now: Date = Date()) -> ApprovalGrant? {
        guard let grant = grants[id] else { return nil }
        guard !burnedSingleUse.contains(id) else { return nil }
        guard !grant.isExpired(at: now) else { return nil }
        return grant
    }

    /// Returns the first live grant matching the scope exactly on tool name
    /// and (when the scope specifies one) host.
    public func matchingGrant(for scope: ApprovalScope, at now: Date = Date()) -> ApprovalGrant? {
        for grant in grants.values {
            guard !burnedSingleUse.contains(grant.id) else { continue }
            guard !grant.isExpired(at: now) else { continue }
            guard grant.scope.toolName == scope.toolName else { continue }
            if let requiredHost = scope.hostID, grant.scope.hostID != requiredHost { continue }
            if !scope.paths.isEmpty {
                let granted = Set(grant.scope.paths)
                guard scope.paths.allSatisfy({ granted.contains($0) }) else { continue }
            }
            return grant
        }
        return nil
    }

    /// Burns a single-use grant after execution. No-op for reusable grants.
    public func consumeIfSingleUse(_ grant: ApprovalGrant) {
        if grant.scope.singleUse {
            burnedSingleUse.insert(grant.id)
        }
    }

    /// Removes a grant entirely (user revocation).
    public func revoke(id: UUID) {
        grants.removeValue(forKey: id)
        burnedSingleUse.remove(id)
    }

    /// Drops expired grants. Returns how many were purged.
    @discardableResult
    public func purgeExpired(at now: Date = Date()) -> Int {
        let expired = grants.values.filter { $0.isExpired(at: now) }.map(\.id)
        for id in expired {
            grants.removeValue(forKey: id)
            burnedSingleUse.remove(id)
        }
        return expired.count
    }

    public var allGrants: [ApprovalGrant] {
        grants.values.sorted { $0.decidedAt < $1.decidedAt }
    }
}
