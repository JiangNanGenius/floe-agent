// FloeWorkbench — Trusted user-confirmation grants for AI proposals.
//
// The model-facing tool can never apply a proposal on its own authority.
// Acceptance is a server-owned, single-use, expiring, opaque grant:
//   * Only the interactive UI (after the user taps accept) calls
//     `issueGrant(...)`; a Codable value arriving in a tool request is not
//     authority and cannot mint a token.
//   * The tool presents the opaque `grantID` it received from the UI; the
//     store validates project, proposal, exact revision and expiry, consumes
//     the grant exactly once, and only then returns `.authorized`.
//   * Any revision change (including undo/redo, which always advances the
//     revision) invalidates the grant: proposals cannot apply after a manual
//     change.

import Foundation
import FloeCore

public struct MediaProposalGrant: Sendable {
    public let grantID: String
    public let projectID: UUID
    public let proposalID: UUID
    public let revision: Int64
    public let issuedAt: Date
    public let expiresAt: Date
}

public enum MediaGrantDecision: Sendable, Equatable {
    case authorized
    case unknownGrant
    case expired
    case revisionMismatch(expected: Int64, actual: Int64)
    case alreadyConsumed
}

public actor MediaProposalGrantStore {
    private struct Entry {
        let projectID: UUID
        let proposalID: UUID
        let revision: Int64
        let expiresAt: Date
        var consumed: Bool
    }

    private var entries: [String: Entry] = [:]
    private let timeToLive: TimeInterval
    private let idProvider: @Sendable () -> String

    public init(timeToLive: TimeInterval = 300, idProvider: @escaping @Sendable () -> String = {
        // 256-bit opaque identifier; UUID is acceptable but we add 16 random
        // bytes so a caller cannot infer or enumerate identifiers.
        (0..<4).map { _ in UUID().uuidString }.joined(separator: "")
    }) {
        self.timeToLive = timeToLive
        self.idProvider = idProvider
    }

    /// Issues a grant from the TRUSTED interactive path (user tapped accept
    /// in the UI, after reviewing the proposal preview).
    @discardableResult
    public func issueGrant(projectID: UUID, proposalID: UUID, revision: Int64, now: Date = Date()) -> MediaProposalGrant {
        sweep(now: now)
        let id = idProvider()
        let expires = now.addingTimeInterval(timeToLive)
        entries[id] = Entry(projectID: projectID, proposalID: proposalID,
                            revision: revision, expiresAt: expires, consumed: false)
        return MediaProposalGrant(grantID: id, projectID: projectID, proposalID: proposalID,
                                  revision: revision, issuedAt: now, expiresAt: expires)
    }

    /// Validates and atomically consumes a grant. Returns a decision rather
    /// than throwing so callers can report exactly why confirmation failed.
    public func consume(grantID: String, projectID: UUID, proposalID: UUID,
                        revision: Int64, now: Date = Date()) -> MediaGrantDecision {
        sweep(now: now)
        guard var entry = entries[grantID] else { return .unknownGrant }
        guard entry.projectID == projectID, entry.proposalID == proposalID else { return .unknownGrant }
        if entry.consumed { return .alreadyConsumed }
        if entry.expiresAt <= now { return .expired }
        if entry.revision != revision { return .revisionMismatch(expected: entry.revision, actual: revision) }
        entry.consumed = true
        entries[grantID] = entry
        return .authorized
    }

    /// Allows a user to dismiss a pending confirmation; subsequent apply
    /// attempts fail with `.unknownGrant`.
    public func revoke(grantID: String) {
        entries.removeValue(forKey: grantID)
    }

    public func pendingCount(now: Date = Date()) -> Int {
        sweep(now: now)
        return entries.values.filter { !$0.consumed }.count
    }

    @discardableResult
    private func sweep(now: Date) -> Int {
        let expired = entries.filter { $0.value.expiresAt <= now }.map(\.key)
        for key in expired { entries.removeValue(forKey: key) }
        return expired.count
    }
}
