import Foundation

/// Admission/lifetime coordination only, not an authorization source. Every
/// actual use still checks the installed Skill, vault binding and native lease.
actor NativeExternalOAuthLifecycle {
    struct Scope: Sendable, Hashable {
        let skillID: String
        let profile: String
        let target: String
    }
    struct Ticket: Sendable, Equatable { let id: UUID; let scope: Scope }
    enum Failure: Error, Sendable { case busy, changing, stale, stopUnconfirmed }
    private var owner: Ticket?
    private var mutations: [String: Set<UUID>] = [:]

    func begin(_ scope: Scope, ownerID: UUID = UUID()) throws -> Ticket {
        guard mutations[scope.skillID]?.isEmpty != false else { throw Failure.changing }
        guard owner == nil else { throw Failure.busy }
        let ticket = Ticket(id: ownerID, scope: scope); owner = ticket; return ticket
    }

    func isCurrent(_ ticket: Ticket) -> Bool {
        owner == ticket && mutations[ticket.scope.skillID]?.isEmpty != false
    }

    func current(skillID: String? = nil, ownerID: UUID? = nil) -> Ticket? {
        guard let owner, skillID == nil || owner.scope.skillID == skillID,
              ownerID == nil || owner.id == ownerID else { return nil }
        return owner
    }

    func finish(_ ticket: Ticket, stopped: Bool) throws {
        guard owner == ticket else { throw Failure.stale }
        guard stopped else { throw Failure.stopUnconfirmed }
        owner = nil
    }

    /// Concurrent/late cleanup is idempotent and cannot retire a new owner.
    func retire(_ ticket: Ticket, stopped: Bool) -> Bool {
        guard owner == ticket else { return true }
        guard stopped else { return false }
        owner = nil
        return true
    }

    func beginMutation(skillID: String) -> UUID {
        let id = UUID(); mutations[skillID, default: []].insert(id); return id
    }
    func finishMutation(skillID: String, id: UUID) {
        mutations[skillID]?.remove(id)
        if mutations[skillID]?.isEmpty == true { mutations[skillID] = nil }
    }
    func allowsUse(skillID: String) -> Bool { mutations[skillID]?.isEmpty != false }
}

/// A real before/after mutation fence spans the existing store transaction.
/// Finishing this lease does not grant credential or execution permission.
struct SkillConfigurationMutationLease: Sendable {
    let finish: @Sendable () async -> Void
}
