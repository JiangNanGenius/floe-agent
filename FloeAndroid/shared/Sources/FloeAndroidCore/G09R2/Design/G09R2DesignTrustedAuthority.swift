// SPDX-License-Identifier: MPL-2.0
//
// G09-R2 — trusted-UI authority for design RESTRUCTURE (CABI/JNI seam).
//
// The shared `DesignRestructureAuthorityReceipt` is intentionally NON-Codable:
// model-authored bridge JSON can therefore never manufacture it. This file
// provides the host-only native half of that seam:
//
//  1. The App shows the ACTUAL preservation constraints and the exact
//     target/operation/base revision this restructure is bound to.
//  2. The user confirms. The App calls the privileged design-authority JNI
//     with its live accepted Root epoch + full process owner token.
//  3. Native re-validates the owner proof and the live target state, then
//     records an exact `DesignRestructureAuthorityRequest` and returns only
//     display data + an opaque token.
//  4. `confirm(token)` mints ONE single-use grant through the EXISTING
//     `ApprovalGrantStore` type, bound field-for-field to that request.
//  5. The design service claims/burns it through
//     `ApprovalGrantStore.claimSingleUse` immediately before freeze/propose/
//     adopt. A missing, stale, replayed, wrong-target or wrong-digest claim is
//     refused BEFORE payload bytes or a CAS mutation.
//
// The store is deliberately design-restructure-scoped. It is NOT a second
// general approval engine, has no V6 action/model tool, and its records are
// process/Root-generation memory only.
import Foundation
import FloeCore
import FloeSecurity

public enum G09R2DesignAuthorityStatus {
    public static let ok: Int32 = 0
    public static let invalidArgument: Int32 = -105
    /// The presented owner epoch/token is not the live accepted generation.
    public static let ownerProofInvalid: Int32 = -120
    /// No live design generation/authority store for this epoch.
    public static let notReady: Int32 = -121
    public static let saturated: Int32 = -122
    public static let notFound: Int32 = -123
    public static let expired: Int32 = -124
    public static let mismatch: Int32 = -125
    public static let retired: Int32 = -126
}

public enum G09R2DesignAuthorityLimits {
    public static let maximumRecords = 64
    public static let maximumConstraintEntriesPerList = 32
    public static let maximumConstraintEntryBytes = 256
    public static let maximumTokenBytes = 64
    public static let maximumPrepareJSONBytes = 64 * 1024
    public static let maximumDisplayJSONBytes = 64 * 1024
    public static let confirmationTTLSeconds: TimeInterval = 5 * 60
}

/// Typed refusal for the host-only prepare validation. Distinct from the
/// shared consent errors, which are mapped at the design service boundary.
public enum G09R2DesignAuthorityError: Error, Sendable, Equatable {
    case invalidConfirmation(String)
}

public enum G09R2DesignAuthorityOperationKind: String, Codable, Sendable {
    case propose
    case freeze
    case adopt
}

/// Host-only prepare input. Encoded by the trusted App callback, decoded by
/// native. `preservation` is the user's explicit preservation requirements;
/// the model layer never supplies it through the ordinary design bridge.
public struct G09R2DesignAuthorityPrepareInput: Codable, Sendable, Equatable {
    public var binding: G09R2DesignBindingDTO
    public var operationKind: G09R2DesignAuthorityOperationKind
    public var opID: String
    public var artifactID: String?
    public var candidateID: String?
    /// For propose/adopt: the resolved base revision the restructure starts
    /// from (nil = current at prepare time). For freeze it is the exact
    /// `inputRevisionID` the frozen run will record (Canvas requires it).
    public var baseRevisionID: String?
    public var preservation: DesignPreservationConstraints

    public init(
        binding: G09R2DesignBindingDTO,
        operationKind: G09R2DesignAuthorityOperationKind,
        opID: String,
        artifactID: String? = nil,
        candidateID: String? = nil,
        baseRevisionID: String? = nil,
        preservation: DesignPreservationConstraints
    ) {
        self.binding = binding
        self.operationKind = operationKind
        self.opID = opID
        self.artifactID = artifactID
        self.candidateID = candidateID
        self.baseRevisionID = baseRevisionID
        self.preservation = preservation
    }
}

/// Display + opaque token returned to the trusted App. It contains NO claim,
/// authority flag or editable token field: the user confirms exactly these
/// values through the host callback.
public struct G09R2DesignTrustedConfirmationDTO: Codable, Sendable, Equatable {
    public var token: String
    public var targetKey: String
    public var operationID: String
    public var originalTaskOwnerID: String?
    public var baseRevisionID: String?
    public var preservationDigest: String
    public var preservation: DesignPreservationConstraints
    public var expiresAt: Date
}

/// One per accepted design generation. All state is memory-only and retired on
/// Root stop, so a late/old grant can never affect a replacement Root.
public final class G09R2DesignRestructureAuthorityStore: @unchecked Sendable {
    public let epoch: UInt64
    public let rootFingerprint: String
    public let serviceID: UUID
    public let clock: @Sendable () -> Date

    private struct Key: Hashable {
        let targetKey: String
        let operationID: String
    }

    private enum State {
        case prepared
        case confirmed
        case claimed
    }

    private struct Record {
        let token: String
        let operationKind: G09R2DesignAuthorityOperationKind
        let request: DesignRestructureAuthorityRequest
        let constraints: DesignPreservationConstraints
        let expiresAt: Date
        var state: State
        var grant: ApprovalGrant?
        var confirmedAt: Date?
    }

    private let grants = ApprovalGrantStore()
    private let lock = NSLock()
    private var recordsByToken: [String: Record] = [:]
    private var tokensByKey: [Key: String] = [:]
    private var order: [String] = []
    private var retired = false

    public init(
        epoch: UInt64,
        rootFingerprint: String,
        serviceID: UUID = UUID(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.epoch = epoch
        self.rootFingerprint = rootFingerprint
        self.serviceID = serviceID
        self.clock = clock
    }

    // MARK: - Prepare / confirm (host-only ingress)

    /// Records the exact request after the service validated the LIVE target.
    /// Returns the opaque token and its display DTO data.
    public func prepare(
        request: DesignRestructureAuthorityRequest,
        constraints: DesignPreservationConstraints,
        operationKind: G09R2DesignAuthorityOperationKind
    ) throws -> (token: String, expiresAt: Date) {
        guard Self.isValidRequest(request), Self.isBounded(constraints),
              !constraints.isEmpty else {
            throw DesignTargetError.invalidReference(
                "restructure authority requires a bounded, non-empty confirmation")
        }
        lock.lock()
        defer { lock.unlock() }
        guard !retired else {
            throw DesignTargetError.unavailable("the design authority was retired")
        }
        purgeExpiredLocked()
        let key = Key(targetKey: request.targetKey,
                      operationID: request.operationID)
        if let previousToken = tokensByKey[key] {
            recordsByToken.removeValue(forKey: previousToken)
            order.removeAll { $0 == previousToken }
        }
        while recordsByToken.count >= G09R2DesignAuthorityLimits.maximumRecords,
              let oldest = order.first {
            let token = oldest
            order.removeFirst()
            if let removed = recordsByToken.removeValue(forKey: token) {
                tokensByKey.removeValue(forKey: Key(
                    targetKey: removed.request.targetKey,
                    operationID: removed.request.operationID))
            }
        }
        let token = Self.mintToken()
        guard recordsByToken[token] == nil else {
            throw DesignTargetError.unavailable(
                "design authority token collision")
        }
        let expiresAt = clock().addingTimeInterval(
            G09R2DesignAuthorityLimits.confirmationTTLSeconds)
        recordsByToken[token] = Record(
            token: token, operationKind: operationKind,
            request: request, constraints: constraints,
            expiresAt: expiresAt, state: .prepared,
            grant: nil, confirmedAt: nil)
        tokensByKey[key] = token
        order.append(token)
        return (token, expiresAt)
    }

    /// Mints the EXISTING single-use approval grant bound to the exact prepared
    /// request. The grant is installed + burned atomically at the effect
    /// boundary (`claim`), not here, so a confirmed-but-unused confirmation
    /// cannot be consumed by any other code path.
    public func confirm(token: String) -> Int32 {
        guard Self.isValidToken(token) else { return G09R2DesignAuthorityStatus.invalidArgument }
        lock.lock()
        defer { lock.unlock() }
        guard !retired else { return G09R2DesignAuthorityStatus.retired }
        guard var record = recordsByToken[token] else {
            return G09R2DesignAuthorityStatus.notFound
        }
        guard record.state == .prepared else {
            return G09R2DesignAuthorityStatus.notFound
        }
        let now = clock()
        guard record.expiresAt > now else {
            removeLocked(token: token)
            return G09R2DesignAuthorityStatus.expired
        }
        let scope = Self.scope(
            for: record.request, operationKind: record.operationKind)
        let grant = ApprovalGrant(
            id: UUID(),
            scope: scope,
            expiresAt: min(record.expiresAt,
                           now.addingTimeInterval(
                            G09R2DesignAuthorityLimits.confirmationTTLSeconds)),
            decidedAt: now,
            policyName: "design.restructure.trustedUI")
        record.state = .confirmed
        record.grant = grant
        record.confirmedAt = now
        recordsByToken[token] = record
        return G09R2DesignAuthorityStatus.ok
    }

    /// Exact-token revoke (user cancel / superseded sheet). Never touches
    /// another confirmation.
    @discardableResult
    public func revoke(token: String) -> Bool {
        guard Self.isValidToken(token) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard recordsByToken[token] != nil else { return false }
        removeLocked(token: token)
        return true
    }

    /// Root stop: no prepared/confirmed record survives and no pending claim
    /// may mint a receipt. A newer Root registers a different store.
    public func retire() {
        lock.lock()
        retired = true
        recordsByToken.removeAll()
        tokensByKey.removeAll()
        order.removeAll()
        lock.unlock()
    }

    public var liveCount: Int {
        lock.lock(); defer { lock.unlock() }
        purgeExpiredLocked()
        return recordsByToken.count
    }

    // MARK: - Service-side preflight / claim

    /// Exact confirmed record for one target/operation. Used by the design
    /// service to build its typed intent from the USER-confirmed preservation
    /// constraints (never from model JSON) and to refuse stale baselines before
    /// reading payload bytes. Claimed/expired records return nil.
    public func confirmedRecord(
        targetKey: String,
        operationID: String,
        operationKind: G09R2DesignAuthorityOperationKind
    ) -> (request: DesignRestructureAuthorityRequest,
          constraints: DesignPreservationConstraints,
          confirmedAt: Date)? {
        lock.lock(); defer { lock.unlock() }
        purgeExpiredLocked()
        let key = Key(targetKey: targetKey, operationID: operationID)
        guard let token = tokensByKey[key],
              let record = recordsByToken[token],
              record.state == .confirmed,
              record.operationKind == operationKind,
              record.expiresAt > clock() else { return nil }
        return (record.request, record.constraints,
                record.confirmedAt ?? clock())
    }

    /// Non-burning binding check used to refuse stale/wrong claims BEFORE
    /// payload bytes are read or staged. The authoritative burn is `claim`.
    public func preflight(
        _ request: DesignRestructureAuthorityRequest,
        operationKind: G09R2DesignAuthorityOperationKind,
        at now: Date? = nil
    ) throws {
        lock.lock(); defer { lock.unlock() }
        try validateLocked(
            request, operationKind: operationKind, at: now ?? clock())
    }

    /// Atomic user-confirmation claim, called immediately before the first
    /// side effect. The `ApprovalGrantStore.claimSingleUse` check-and-burn is
    /// one actor call on the EXISTING store; a mismatched grant is never
    /// burned.
    public func claim(
        _ request: DesignRestructureAuthorityRequest,
        operationKind: G09R2DesignAuthorityOperationKind,
        at now: Date? = nil
    ) async throws -> DesignRestructureAuthorityReceipt {
        let claimTime = now ?? clock()
        // Swift 6 forbids NSLock.lock/unlock in an async function. Both lock
        // sections live in synchronous helpers; only the grant store awaits.
        let pending = try claimPending(
            request, operationKind: operationKind, at: claimTime)

        // Install then burn the EXACT single-use grant through the existing
        // approval-grant store. A missing/expired/already-burned/mismatched
        // grant answers nil and is NOT burned here.
        await grants.add(pending.grant)
        guard await grants.claimSingleUse(
            id: pending.grant.id,
            matching: Self.scope(for: request, operationKind: operationKind),
            at: claimTime
        ) != nil else {
            throw DesignRestructureAuthorityError.claimRequired(
                "the trusted-UI claim was expired, replayed or did not match this exact restructure")
        }
        return try consumeClaim(
            token: pending.token,
            request: request,
            claimTime: claimTime,
            grantID: pending.grant.id)
    }

    /// First synchronous lock section of `claim`: validate the exact request
    /// and capture the confirmed token/grant without consuming it.
    private func claimPending(
        _ request: DesignRestructureAuthorityRequest,
        operationKind: G09R2DesignAuthorityOperationKind,
        at claimTime: Date
    ) throws -> (token: String, grant: ApprovalGrant) {
        lock.lock()
        defer { lock.unlock() }
        try validateLocked(
            request, operationKind: operationKind, at: claimTime)
        let key = Key(targetKey: request.targetKey,
                      operationID: request.operationID)
        guard let resolvedToken = tokensByKey[key],
              let record = recordsByToken[resolvedToken],
              record.state == .confirmed,
              let pendingGrant = record.grant else {
            throw DesignRestructureAuthorityError.claimRequired(
                "no confirmed trusted-UI claim exists for this restructure")
        }
        return (resolvedToken, pendingGrant)
    }

    /// Second synchronous lock section of `claim`: atomically move the exact
    /// record to claimed after the one-shot grant was burned.
    private func consumeClaim(
        token: String,
        request: DesignRestructureAuthorityRequest,
        claimTime: Date,
        grantID: UUID
    ) throws -> DesignRestructureAuthorityReceipt {
        lock.lock()
        defer { lock.unlock() }
        guard !retired else {
            // The grant is burned, but Root retired before the effect; the
            // service will refuse the operation, and a new Root never sees it.
            throw DesignRestructureAuthorityError.claimRequired(
                "the design authority retired while the claim was being burned")
        }
        guard var record = recordsByToken[token],
              record.state == .confirmed else {
            throw DesignRestructureAuthorityError.claimRequired(
                "the trusted-UI claim was already consumed")
        }
        record.state = .claimed
        recordsByToken[token] = record
        return DesignRestructureAuthorityReceipt(
            request: request, claimID: grantID, issuedAt: claimTime)
    }

    // MARK: - Locked helpers

    private func validateLocked(
        _ request: DesignRestructureAuthorityRequest,
        operationKind: G09R2DesignAuthorityOperationKind,
        at now: Date
    ) throws {
        guard !retired else {
            throw DesignRestructureAuthorityError.claimRequired(
                "the design authority for this Root generation was retired")
        }
        guard Self.isValidRequest(request) else {
            throw DesignRestructureAuthorityError.claimRequired(
                "the restructure authority request is malformed")
        }
        let key = Key(targetKey: request.targetKey,
                      operationID: request.operationID)
        guard let token = tokensByKey[key],
              let record = recordsByToken[token] else {
            throw DesignRestructureAuthorityError.claimRequired(
                "restructure of \(request.targetKey) requires a trusted-UI confirmation for operation \(request.operationID)")
        }
        guard record.operationKind == operationKind else {
            throw DesignRestructureAuthorityError.claimMismatch(
                "the trusted-UI confirmation is for a different restructure operation")
        }
        guard record.request == request else {
            throw DesignRestructureAuthorityError.claimMismatch(
                "the trusted-UI confirmation does not bind this exact target/operation/task/base/digest")
        }
        guard record.expiresAt > now else {
            removeLocked(token: token)
            throw DesignRestructureAuthorityError.claimRequired(
                "the trusted-UI confirmation expired; confirm the preservation constraints again")
        }
        guard record.state == .confirmed, record.grant != nil else {
            throw DesignRestructureAuthorityError.claimRequired(
                "the restructure confirmation was not confirmed by the user")
        }
    }

    private func removeLocked(token: String) {
        guard let removed = recordsByToken.removeValue(forKey: token) else {
            return
        }
        tokensByKey.removeValue(forKey: Key(
            targetKey: removed.request.targetKey,
            operationID: removed.request.operationID))
        order.removeAll { $0 == token }
    }

    private func purgeExpiredLocked() {
        let now = clock()
        let expired = recordsByToken.compactMap { token, record in
            record.expiresAt <= now ? token : nil
        }
        for token in expired { removeLocked(token: token) }
    }

    // MARK: - Closed validation

    static func scope(
        for request: DesignRestructureAuthorityRequest,
        operationKind: G09R2DesignAuthorityOperationKind
    ) -> ApprovalScope {
        ApprovalScope(
            toolName: "design.restructure",
            hostID: nil,
            paths: [
                "kind:\(operationKind.rawValue)",
                "target:\(request.targetKey)",
                "operation:\(request.operationID)",
                "task:\(request.originalTaskOwnerID ?? "")",
                "base:\(request.baseRevisionID ?? "")",
                "digest:\(request.preservationDigest)"
            ],
            singleUse: true,
            toolAuthorizationIdentity: "design.restructure.trustedUI.v1")
    }

    static func isValidRequest(
        _ request: DesignRestructureAuthorityRequest
    ) -> Bool {
        isValidKeyToken(request.targetKey, maximum: 256)
            && isValidKeyToken(request.operationID, maximum: 200)
            && (request.originalTaskOwnerID == nil
                || isValidKeyToken(request.originalTaskOwnerID!, maximum: 200))
            && (request.baseRevisionID == nil
                || isValidKeyToken(request.baseRevisionID!, maximum: 200))
            && isValidDigest(request.preservationDigest)
    }

    static func isBounded(_ constraints: DesignPreservationConstraints) -> Bool {
        let lists = [
            constraints.content, constraints.data,
            constraints.behavior, constraints.formatBounds
        ]
        guard !constraints.isEmpty else { return false }
        return lists.allSatisfy { values in
            values.count <= G09R2DesignAuthorityLimits.maximumConstraintEntriesPerList
                && values.allSatisfy { value in
                    !value.isEmpty
                        && value.utf8.count
                            <= G09R2DesignAuthorityLimits.maximumConstraintEntryBytes
                        && !value.unicodeScalars.contains(where: {
                            CharacterSet.controlCharacters.contains($0)
                        })
                }
        }
    }

    static func isValidDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
                || ($0 >= "A" && $0 <= "F")
        }
    }

    static func isValidToken(_ value: String) -> Bool {
        value.hasPrefix("dra:v1:")
            && value.utf8.count <= G09R2DesignAuthorityLimits.maximumTokenBytes
            && value.dropFirst("dra:v1:".count).allSatisfy {
                ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
            }
    }

    private static func isValidKeyToken(_ value: String, maximum: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    static func mintToken() -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return "dra:v1:" + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Process-wide registry keyed by accepted Root epoch. The design service
/// registers on bind and unregisters on Root stop/deinit; the JNI ingress can
/// only reach the live generation's exact store.
public final class G09R2DesignAuthorityRegistry: @unchecked Sendable {
    public static let shared = G09R2DesignAuthorityRegistry()

    public struct Entry {
        public let epoch: UInt64
        public let rootFingerprint: String
        public let serviceID: UUID
        public let store: G09R2DesignRestructureAuthorityStore
        weak var service: G09R2DesignService?
    }

    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]

    private init() {}

    public func register(
        epoch: UInt64,
        rootFingerprint: String,
        serviceID: UUID,
        store: G09R2DesignRestructureAuthorityStore,
        service: G09R2DesignService
    ) {
        lock.lock()
        entries[epoch] = Entry(
            epoch: epoch, rootFingerprint: rootFingerprint,
            serviceID: serviceID, store: store, service: service)
        lock.unlock()
    }

    public func unregister(epoch: UInt64, serviceID: UUID) {
        lock.lock()
        if entries[epoch]?.serviceID == serviceID {
            entries[epoch] = nil
        }
        lock.unlock()
    }

    public func entry(epoch: UInt64) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[epoch]
    }

    public func store(epoch: UInt64) -> G09R2DesignRestructureAuthorityStore? {
        lock.lock(); defer { lock.unlock() }
        return entries[epoch]?.store
    }
}
