// SPDX-License-Identifier: MPL-2.0
//
// G04-R1 network mount credential lease — the protocol-neutral approved
// lease adapter over the ONE existing credential authority
// (`AndroidCredentialVault` behind `G04NetworkSecretAuthority`). This is NOT
// a second vault, NOT a secret cache and NOT a copy of the Git
// `G04GitCredentialLease` shape: SMB/WebDAV passwords are arbitrary Unicode
// text, so the Git ASCII printable-token validation is deliberately absent
// here (only the vault's own byte ceiling applies). Every secret read re-
// consults the live mount configuration (no cached grant truth); staged
// secret bytes exist only in process RAM inside this actor, are consumed
// exactly once, and are zeroed on consume/abort/retire. No secret bytes ever
// enter SQLite, JSON replies, labels, logs or files on disk.
//
// Physical operation receipts are the vault's OWN (capture/replace/delete
// run under the shared account lease + RB1 `.vaultMaintenance` owned-work
// attach exactly as delivered); this adapter never fakes completion, never
// detaches an unsettled effect and maps vault outcomes onto typed tokens.
import Foundation
import FloeCore
import FloePersistence
import FloeWorkspace

// MARK: - Approved authority seam

/// Deletion terminal, projected from the ORIGINAL vault receipt.
public enum G04NetworkSecretDeletion: String, Sendable, Equatable {
    /// Metadata and secret effect provably settled (or nothing existed).
    case deleted
    /// The vault kept a durable cleanup-intent row: the secret may still
    /// exist and restart drain owns it. Honest pending, never a lie.
    case durablePending
    /// A typed vault refusal (for example contention); nothing was decided.
    case refused
}

/// Typed, byte-free credential failures. Tokens cross the C boundary; the
/// underlying vault error (which may carry ids) is reduced here and never
/// re-emitted verbatim.
public enum G04NetworkSecretFailure: Error, Sendable, Equatable {
    case notFound
    case cleanupPending
    case gatewayUnavailable
    case gatewayRejected
    /// The gateway effect is unknown; the vault's durable bookkeeping owns
    /// the decision. Callers must NOT treat this as success or as absence.
    case gatewayEffectUnknown
    case invalidLabel
    /// Staged ticket absent/consumed. Never "captured anyway".
    case invalidTicket
    case leaseRetired
}

/// The ONE secret authority this lane may use. Production is
/// `G04VaultNetworkSecretAuthority` (the installed composition's vault);
/// component tests inject a synthetic actor with identical typed semantics.
public protocol G04NetworkSecretAuthority: Sendable {
    func captureNetworkSecret(_ secret: Data, id: UUID, label: String,
                              workspaceID: UUID) async throws
    /// Rotate the bytes behind an EXISTING reference (vault replace path:
    /// one durable account lease around the gateway write, same receipts).
    func replaceNetworkSecret(_ secret: Data, id: UUID, label: String) async throws
    func resolveNetworkSecret(id: UUID) async throws -> Data
    func deleteNetworkSecret(id: UUID) async throws -> G04NetworkSecretDeletion
    /// Existence WITHOUT bytes: used for revalidation reads. Never a grant
    /// promise — the resolve call below is the only path to secret bytes.
    func networkSecretAvailable(id: UUID) async throws -> Bool
}

/// Production authority: forwards every operation to the SAME
/// `AndroidCredentialVault` that owns provider/SSH/website secrets, with the
/// workspace-owned generic-token shape the delivered iOS mount flow used
/// (`kind .genericToken`, `owner .workspace(id)`, origin tag identifying the
/// feature for vault-side coarse classification only).
public struct G04VaultNetworkSecretAuthority: G04NetworkSecretAuthority {
    private let vault: AndroidCredentialVault
    public init(vault: AndroidCredentialVault) { self.vault = vault }

    public func captureNetworkSecret(_ secret: Data, id: UUID, label: String,
                                     workspaceID: UUID) async throws {
        do {
            _ = try await vault.capture(secret, kind: .genericToken,
                                        owner: .workspace(workspaceID),
                                        label: label, id: id,
                                        origin: "network-workspace-mount")
        } catch let error as AndroidCredentialVaultError {
            throw Self.project(error)
        }
    }

    public func replaceNetworkSecret(_ secret: Data, id: UUID, label: String) async throws {
        do {
            try await vault.replaceSecret(CredentialHandle(id: id), secret: secret)
            if !label.isEmpty { try await vault.updateLabel(CredentialHandle(id: id), label: label) }
        } catch let error as AndroidCredentialVaultError {
            throw Self.project(error)
        }
    }

    public func resolveNetworkSecret(id: UUID) async throws -> Data {
        do {
            return try await vault.resolveForApprovedUse(CredentialHandle(id: id))
        } catch let error as AndroidCredentialVaultError {
            throw Self.project(error)
        }
    }

    public func deleteNetworkSecret(id: UUID) async throws -> G04NetworkSecretDeletion {
        do {
            let outcome = try await vault.delete(CredentialHandle(id: id))
            switch outcome.secretCleanup {
            case .completed: return .deleted
            case .pendingDurableQueue: return .durablePending
            case .unknown: return .refused
            }
        } catch let error as AndroidCredentialVaultError {
            throw Self.project(error)
        }
    }

    public func networkSecretAvailable(id: UUID) async throws -> Bool {
        do {
            _ = try await vault.status(CredentialHandle(id: id))
            return true
        } catch let error as AndroidCredentialVaultError {
            throw Self.project(error)
        }
    }

    /// Byte-free projection. `effectUnknown` keeps its own kind: an
    /// unresponsive gateway is NOT proof of "no secret" and NOT proof of a
    /// completed effect (the vault's CV-R4 rule, honored at this layer too).
    static func project(_ error: AndroidCredentialVaultError) -> G04NetworkSecretFailure {
        switch error {
        case .credentialNotFound, .secretMissing: return .notFound
        case .referenceCleanupPending, .durableCleanupIntentMissing: return .cleanupPending
        case let .gatewayFailure(_, kind):
            switch kind {
            case .unavailable: return .gatewayUnavailable
            case .rejected: return .gatewayRejected
            case .effectUnknown: return .gatewayEffectUnknown
            }
        case .invalidSecret, .invalidAccount: return .invalidLabel
        default: return .gatewayRejected
        }
    }
}

// MARK: - Redaction

/// Secret-free endpoint/label projection. Query items and fragments are
/// treated as secret-bearing (signed WebDAV URLs put tokens in the query),
/// and userinfo is refused long before this point; the label keeps only
/// scheme/host[:port]/path.
enum G04NetworkSecretRedaction {
    static func endpoint(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = url.scheme?.lowercased()
        components.host = url.host?.lowercased()
        components.port = url.port
        components.path = url.path
        var text = components.string ?? "\(url.scheme?.lowercased() ?? "")://"
        // Trailing slash kept for readability, query/fragment/userinfo gone.
        if text.hasSuffix("/") { text = String(text.dropLast()) }
        return text
    }

    static func safeMountLabel(name: String, transport: NetworkWorkspaceProtocol,
                               endpoint: URL) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? (endpoint.host ?? "network") : trimmed
        return "\(base) (\(transport == .smb ? "SMB" : "WebDAV")) "
            + endpointLabelSuffix(endpoint)
    }

    private static func endpointLabelSuffix(_ endpoint: URL) -> String {
        let host = endpoint.host?.lowercased() ?? "host"
        let lastPath = endpoint.path.split(separator: "/").last.map(String.init) ?? ""
        return lastPath.isEmpty ? "[\(host)]" : "[\(host)/\(lastPath)]"
    }

    /// Vault-side label guard: reject empty/oversize labels and anything that
    /// structurally looks like it smuggles a URL credential or a signed-query
    /// token into the metadata row.
    static func labelLooksSafe(_ label: String) -> Bool {
        guard !label.isEmpty, label.utf8.count <= 512 else { return false }
        if label.range(of: #"://[^/\s]+:[^/\s]+@"#, options: .regularExpression) != nil { return false }
        if label.range(of: #"[?&](sig|token|key|password|pass)="#,
                       options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return true
    }
}

// MARK: - The lease

/// Epoch-fenced credential lease owned by exactly one live
/// `G04NetworkWorkspace`. Staged RAM tickets mirror the trusted-host ingress
/// discipline: positive opaque ids, consume-once, zeroize-after-use, and a
/// retire that refuses to leave captured secrets addressable.
public actor G04NetworkCredentialLease {
    private struct Stage {
        var bytes: Data
        var consumed = false
    }

    private let epoch: UInt64
    private let authority: any G04NetworkSecretAuthority
    private var stages: [Int64: Stage] = [:]
    private var counter: Int64 = 0
    private var retired = false

    /// Bounded counters only (no lengths, no ids, no bytes).
    private(set) var counters = (staged: 0, consumed: 0, aborted: 0, captured: 0,
                                  resolved: 0, revoked: 0, refused: 0, zeroized: 0,
                                  liveStages: 0)

    public init(epoch: UInt64, authority: any G04NetworkSecretAuthority) {
        self.epoch = epoch
        self.authority = authority
    }

    public var leaseEpoch: UInt64 { epoch }

    // MARK: staged RAM ingress

    /// Accepts ONE secret body into process RAM. Size ceiling is the vault's
    /// own `maximumSecretBytes`; Unicode passes untouched (this is exactly
    /// where the Git ASCII shape must NOT be reused). Returns an opaque
    /// positive ticket or a typed negative.
    public func stage(_ secret: Data) -> Int64 {
        guard !retired else { counters.refused += 1; return -1 }
        guard !secret.isEmpty, secret.count <= SecretGatewayLimits.maximumSecretBytes,
              stages.count < 8 else {
            counters.refused += 1
            return -2
        }
        counter &+= 1
        // Never hand back 0 or negative tickets.
        if counter <= 0 { counter = 1 }
        stages[counter] = Stage(bytes: secret)
        counters.staged += 1
        counters.liveStages = stages.count
        return counter
    }

    /// Honest abandon: clear the actor's own buffer binding in place (unique
    /// storage at this point unless the App-side caller still holds the same
    /// bytes) and release the ticket. A second abort is a typed false, never
    /// a fake success.
    @discardableResult
    public func abortStage(_ ticket: Int64) -> Bool {
        guard stages[ticket]?.consumed == false, var stage = stages.removeValue(forKey: ticket) else {
            return false
        }
        stage.bytes.resetBytes(in: 0 ..< stage.bytes.count)
        counters.aborted += 1
        counters.zeroized += 1
        counters.liveStages = stages.count
        return true
    }

    /// One-shot consumption. A second call for the same ticket returns nil —
    /// the table no longer holds the body and no code path can re-read it
    /// through this actor. The single handed-out binding is the caller's
    /// transient copy; the capture/replace paths below zeroize it in their
    /// `defer` (the delivered Git-lease single-binding discipline — Swift
    /// copy-on-write makes best-effort clearing the honest claim, never
    /// advertised as a memory-forensics guarantee).
    func consumeStage(_ ticket: Int64) -> Data? {
        guard var stage = stages.removeValue(forKey: ticket), !stage.consumed else { return nil }
        stage.consumed = true
        counters.consumed += 1
        counters.liveStages = stages.count
        return stage.bytes
    }

    // MARK: durable capture through the vault

    /// Captures the staged secret into the ONE vault under a fresh
    /// credential reference. Returns the exact ref that the durable mount
    /// config may store. NEVER stores bytes itself.
    func capture(ticket: Int64, credentialRef: UUID, label: String,
                 workspaceID: UUID) async throws -> UUID {
        guard !retired else { throw G04NetworkSecretFailure.leaseRetired }
        guard labelLooksValid(label) else {
            _ = consumeStage(ticket)   // consumed even on refusal: no leak
            counters.refused += 1
            throw G04NetworkSecretFailure.invalidLabel
        }
        guard ticket != 0, var secret = consumeStage(ticket) else {
            counters.refused += 1
            throw G04NetworkSecretFailure.invalidTicket
        }
        defer { secret.resetBytes(in: 0 ..< secret.count); counters.zeroized += 1 }
        try await authority.captureNetworkSecret(secret, id: credentialRef, label: label,
                                                 workspaceID: workspaceID)
        counters.captured += 1
        return credentialRef
    }

    /// Rotate the bytes behind an EXISTING reference from a fresh staged
    /// ticket (mount edit with a new password). The reference — and every
    /// durable record naming it — stays unchanged; the vault's own account
    /// lease makes the replacement atomic per receipt.
    func replaceSecret(ticket: Int64, credentialRef: UUID, label: String) async throws -> UUID {
        guard !retired else { throw G04NetworkSecretFailure.leaseRetired }
        guard labelLooksValid(label) else {
            _ = consumeStage(ticket)
            counters.refused += 1
            throw G04NetworkSecretFailure.invalidLabel
        }
        guard ticket != 0, var secret = consumeStage(ticket) else {
            counters.refused += 1
            throw G04NetworkSecretFailure.invalidTicket
        }
        defer { secret.resetBytes(in: 0 ..< secret.count); counters.zeroized += 1 }
        try await authority.replaceNetworkSecret(secret, id: credentialRef, label: label)
        counters.captured += 1
        return credentialRef
    }

    /// Resolve a mount's credential for REAL transport IO. The caller passes
    /// the credential ref EXACTLY as it stands in the live durable config
    /// for this mount right now; a mismatch (revoked, replaced, forgotten or
    /// edited between adapter construction and this request) refuses typed
    /// WITHOUT consulting the vault. Nothing is cached: every adapter
    /// request re-enters this function.
    func resolve(credentialRef: UUID, liveConfigCredentialRef: UUID?) async throws -> Data {
        guard !retired else { throw G04NetworkSecretFailure.leaseRetired }
        guard credentialRef == liveConfigCredentialRef else {
            counters.refused += 1
            throw G04NetworkSecretFailure.notFound
        }
        let data = try await authority.resolveNetworkSecret(id: credentialRef)
        counters.resolved += 1
        return data
    }

    /// Existence revalidation WITHOUT bytes (reconnect/re-pick honesty: a
    /// saved ref is re-proved against the live vault, never trusted from the
    /// durable record alone).
    func revalidate(credentialRef: UUID, liveConfigCredentialRef: UUID?) async throws -> Bool {
        guard !retired else { throw G04NetworkSecretFailure.leaseRetired }
        guard credentialRef == liveConfigCredentialRef else {
            counters.refused += 1
            return false
        }
        return try await authority.networkSecretAvailable(id: credentialRef)
    }

    /// Revocation/replacement terminal. The vault's durable cleanup queue
    /// owns uncertainty; a `.durablePending` receipt is reported honestly
    /// and the config layer never claims the secret is gone.
    func revoke(credentialRef: UUID) async throws -> G04NetworkSecretDeletion {
        guard !retired else { throw G04NetworkSecretFailure.leaseRetired }
        let outcome = try await authority.deleteNetworkSecret(id: credentialRef)
        counters.revoked += 1
        return outcome
    }

    /// Exact-epoch retirement: zeroize every unconsumed staged body. There
    /// is no "flush later": an unconsumed ticket is an abandoned user
    /// secret and must not outlive the generation.
    public func retire() {
        retired = true
        // Clear each stored binding IN PLACE through the dictionary (the
        // actor's table is the sole holder), then drop the entries. The
        // ticket list AND each byte count are read into local values BEFORE
        // any write access: `stages[ticket]?.bytes.resetBytes(in:)` takes an
        // exclusive modify access over the whole table, so re-reading
        // `stages` inside the same statement (or while iterating
        // `stages.keys`) is a simultaneous-access conflict that traps
        // (host cohort evidence test-145137.log:379-393). The zeroize
        // semantics are unchanged: every stored binding is cleared through
        // the dictionary's own storage before removal.
        let tickets = Array(stages.keys)
        for ticket in tickets {
            guard let byteCount = stages[ticket]?.bytes.count else { continue }
            stages[ticket]?.bytes.resetBytes(in: 0 ..< byteCount)
        }
        counters.zeroized += tickets.count
        counters.liveStages = 0
        stages.removeAll()
    }

    public var isRetired: Bool { retired }

    var stats: (staged: Int, consumed: Int, aborted: Int, captured: Int,
                resolved: Int, revoked: Int, refused: Int, zeroized: Int,
                liveStages: Int) {
        (counters.staged, counters.consumed, counters.aborted, counters.captured,
         counters.resolved, counters.revoked, counters.refused, counters.zeroized,
         stages.count)
    }

    private func labelLooksValid(_ label: String) -> Bool {
        G04NetworkSecretRedaction.labelLooksSafe(label)
    }
}
