// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Per-reference outcome of a completed push, as reported by the server.
///
/// `git_remote_push` returns `0` whenever the transport itself succeeded,
/// even when the server rejected every ref update; the only channel that
/// carries a rejection is the `push_update_reference` callback (pinned
/// vendored header contract: a non-NULL `status` means the server rejected
/// that ref). These value types capture that callback stream so a rejected
/// push can never be presented as a success, while keeping tokens, remote
/// URLs and the server's raw status text out of receipts, logs and UI — only
/// the bounded closed classifications in `GitPushRejection` survive.
public enum GitPushRefOutcome: String, Codable, Sendable, Hashable {
    /// The server accepted the ref update (NULL status).
    case accepted
    /// The server rejected the ref update (non-NULL status).
    case rejected
}

/// Bounded, closed classification of a server push refusal. Derived from the
/// refname shape and a keyword scan of the server status text only; the raw
/// message is discarded immediately and is never retained anywhere.
public enum GitPushRejection: String, Codable, Sendable, Hashable, CaseIterable {
    /// Remote history has commits the local branch does not (the
    /// "non-fast-forward" / "fetch first" family).
    case nonFastForward
    /// The ref is protected on the server (branch protection, protected ref).
    case protectedBranch
    /// The credential is not allowed to push (permission denied, forbidden).
    case permissionDenied
    /// A server-side rule or policy declined the update (rulesets, required
    /// checks, file-size or path policy).
    case repositoryRule
    /// The server failed transiently while processing the push.
    case serverUnavailable
    /// The refusal does not match any bounded classification above.
    case other
}

/// One ref update reported by the server for a single push.
public struct GitPushRefUpdate: Codable, Sendable, Hashable {
    /// Remote refname as reported (`refs/heads/…`); bounded to 256 characters.
    public let refname: String
    public let outcome: GitPushRefOutcome
    /// Closed classification; non-nil exactly when `outcome == .rejected`.
    public let rejection: GitPushRejection?

    public init(refname: String, outcome: GitPushRefOutcome, rejection: GitPushRejection? = nil) {
        self.refname = refname
        self.outcome = outcome
        self.rejection = rejection
    }
}

/// Immutable summary of one push's per-ref server report.
public struct GitPushReceipt: Codable, Sendable, Hashable {
    /// Updates in the exact order the server reported them.
    public let updates: [GitPushRefUpdate]

    public init(updates: [GitPushRefUpdate]) {
        self.updates = updates
    }

    public var rejected: [GitPushRefUpdate] { updates.filter { $0.outcome == .rejected } }
    /// True when at least one ref was rejected by the server. A push with no
    /// reported ref updates is NOT a success; it is unreported (see
    /// `GitPushUnreportedError`) so an ambiguous outcome can never be
    /// presented as a completed push.
    public var isRejected: Bool { !rejected.isEmpty }
}

/// Typed failure thrown when the server rejected one or more refs. Carries
/// only the bounded receipt — never the raw server message, tokens or URLs.
public struct GitPushRefusedError: Error, Sendable, Hashable {
    public let receipt: GitPushReceipt

    public init(receipt: GitPushReceipt) { self.receipt = receipt }

    /// Dominant classification for mapping to one actionable refusal code.
    public var classification: GitPushRejection {
        receipt.rejected.first?.rejection ?? .other
    }
}

extension GitPushRefusedError: LocalizedError {
    public var errorDescription: String? {
        "The server rejected the Git push (\(classification.rawValue))."
    }
}

/// Typed failure thrown when the transport completed but the server reported
/// no ref update at all. The push outcome is unknown, so it is surfaced as a
/// failure rather than silently counted as a success.
public struct GitPushUnreportedError: Error, Sendable, Hashable {
    /// Refs that were sent and left unconfirmed by the server report.
    public let pushedRefs: [String]

    public init(pushedRefs: [String]) { self.pushedRefs = pushedRefs }
}

extension GitPushUnreportedError: LocalizedError {
    public var errorDescription: String? { "The server did not confirm the Git push result." }
}

// MARK: - Callback seam (internal)

/// Keyword-only classifier. The server status text is consumed here and
/// nowhere else; only the closed enum leaves this function.
enum GitPushRejectionClassifier {
    static func classify(refname: String, status: String) -> GitPushRejection {
        let text = status.lowercased()
        // Order matters: the first matching bounded bucket wins.
        if text.contains("non-fast-forward") || text.contains("non fast forward") ||
            text.contains("not fast-forwardable") || text.contains("fetch first") ||
            text.contains("non-fastforward") {
            return .nonFastForward
        }
        if text.contains("protected branch") || text.contains("protected ref") ||
            text.contains("branch protection") || text.contains("protected tag") {
            return .protectedBranch
        }
        if text.contains("permission") || text.contains("not permitted") ||
            text.contains("denied") || text.contains("forbidden") ||
            text.contains("read-only") || text.contains("read only") ||
            text.contains("403") {
            return .permissionDenied
        }
        if text.contains("internal server error") || text.contains("service unavailable") ||
            text.contains("bad gateway") || text.contains("try again later") ||
            text.contains("temporarily") || text.contains("502") || text.contains("503") {
            return .serverUnavailable
        }
        if text.contains("rule") || text.contains("policy") || text.contains("required") ||
            text.contains("workflow") || text.contains("signature") {
            return .repositoryRule
        }
        _ = refname // refname reserved for future bounded buckets; never stored raw beyond the receipt.
        return .other
    }
}

/// Per-operation accumulator for the `push_update_reference` callback.
/// A fresh recorder is created for every push call and installed only on
/// that call's credential payload, so concurrent (serialized) remote
/// operations can never observe or mutate each other's updates.
final class GitPushUpdateRecorder: @unchecked Sendable {
    /// Refnames are server-reported; bound them so receipts stay bounded.
    private static let refnameLimit = 256
    private static let maximumUpdates = 16

    private var updates: [GitPushRefUpdate] = []

    func record(accepted refname: String) {
        guard updates.count < Self.maximumUpdates else { return }
        updates.append(GitPushRefUpdate(refname: Self.bounded(refname), outcome: .accepted))
    }

    func record(rejected refname: String, reason: GitPushRejection) {
        guard updates.count < Self.maximumUpdates else { return }
        updates.append(GitPushRefUpdate(refname: Self.bounded(refname), outcome: .rejected, rejection: reason))
    }

    var snapshot: [GitPushRefUpdate] { updates }

    private static func bounded(_ refname: String) -> String {
        refname.count > refnameLimit ? String(refname.prefix(refnameLimit)) : refname
    }
}

/// Terminal decision for a completed push transport call. Pure and
/// synchronous: evaluated only after `git_remote_push` has returned, using
/// the updates the callback recorded during the call.
enum GitPushOutcomeEvaluator {
    /// - Throws: `GitPushRefusedError` when any ref was rejected,
    ///   `GitPushUnreportedError` when the server confirmed nothing.
    static func evaluate(updates: [GitPushRefUpdate], pushedRefs: [String]) throws -> GitPushReceipt {
        guard !updates.isEmpty else {
            throw GitPushUnreportedError(pushedRefs: pushedRefs)
        }
        let receipt = GitPushReceipt(updates: updates)
        if receipt.isRejected {
            throw GitPushRefusedError(receipt: receipt)
        }
        let expected = Set(pushedRefs)
        guard !expected.isEmpty, expected.count == pushedRefs.count,
              updates.count == expected.count,
              Set(updates.map(\.refname)) == expected else {
            throw GitPushUnreportedError(pushedRefs: pushedRefs)
        }
        return receipt
    }
}
