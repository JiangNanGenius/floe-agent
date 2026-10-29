// FloeTools — Runtime-issued task authority.
//
// A scoped grant for one concrete task operation (apply/edit/export/job) that
// is minted ONLY by the running runtime, after the existing canonical
// approval path already produced its permission result. It binds:
//
// - the actual run and task (conversation);
// - the concrete environment/workspace identity the operation runs against;
// - the canonical target (file path / document id / workspace root), so two
//   equal-content files that share a base SHA are still different targets;
// - the exact approved tool, operation label, provider call id and
//   idempotency key;
// - the base revision the target was approved against; and
// - a canonical digest of the approved payload, so the same target/base with
//   a different edit command can never validate.
//
// Codable is intentionally NOT conformed: a token can never be reconstructed
// from model output, a transcript, a checkpoint, a job payload or any other
// serialized data. A model writing `"confirmed": true`, a plausible UUID or
// an approval-looking field creates nothing. Validation consults the issuing
// actor-local store, so even an in-process value that was never issued
// resolves to `.unknown`.
//
// This is deliberately NOT a second approval store: it never decides whether
// an action is allowed. The existing ApprovalPolicy / ApprovalGrant flow is
// the only thing that can produce the permission result a token references;
// the runtime mints a token only AFTER that path approved the exact call, and
// the token only preserves that result across the tool boundary. The UI
// interactive grant path is unchanged.

import Foundation
import FloeCore
import FloeModels

/// Result of validating a `RuntimeTaskAuthority` against its issuing store
/// and the concrete operation that is about to run.
public enum RuntimeAuthorityValidation: Sendable, Equatable {
    /// The token was issued by this store and binds exactly this operation.
    case valid
    /// No such token was issued (forged, serialized, or from another process).
    case unknown
    /// The token's bounded lifetime elapsed.
    case expired
    /// The runtime or user revoked the token.
    case revoked
    /// The token exists but does not bind this concrete operation.
    case mismatch(String)
    /// The single-use token was already consumed by an earlier dispatch.
    case alreadyConsumed

    public var isValid: Bool { self == .valid }

    public var failureReason: String? {
        switch self {
        case .valid: return nil
        case .unknown: return "runtime authority was not issued by this runtime"
        case .expired: return "runtime authority expired"
        case .revoked: return "runtime authority was revoked"
        case .mismatch(let detail): return detail
        case .alreadyConsumed: return "runtime authority was already consumed"
        }
    }
}

/// The concrete operation a consumer is about to perform. Consumers MUST
/// derive every field from real current values (resolved target, current
/// revision, canonical approved payload) — never from model text, a
/// `confirmed` flag or a claim inside tool arguments.
public struct RuntimeAuthorityBinding: Sendable, Hashable {
    public var runID: UUID
    public var taskID: UUID?
    /// Environment identity derivation key. See
    /// `RuntimeAuthorityDigest.environmentBinding`.
    public var environmentBinding: String
    /// Canonical target identity, e.g. `file:/abs/path`, `document:office:42`
    /// or `workspace:/abs/root`.
    public var canonicalTarget: String
    public var toolName: String
    public var operation: String
    /// Provider call id of the approved call (the exact dispatched operation).
    public var operationID: String
    public var idempotencyKey: String
    /// Base revision the target was approved against, when applicable.
    public var baseRevision: String?
    /// Canonical digest of the approved payload (see
    /// `RuntimeAuthorityDigest.payloadDigest`).
    public var payloadDigest: String

    public init(
        runID: UUID,
        taskID: UUID?,
        environmentBinding: String,
        canonicalTarget: String,
        toolName: String,
        operation: String,
        operationID: String,
        idempotencyKey: String,
        baseRevision: String?,
        payloadDigest: String
    ) {
        self.runID = runID
        self.taskID = taskID
        self.environmentBinding = environmentBinding
        self.canonicalTarget = canonicalTarget
        self.toolName = toolName
        self.operation = operation
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.baseRevision = baseRevision
        self.payloadDigest = payloadDigest
    }
}

/// Evidence the runtime must derive before minting a token. Every field is a
/// real resolved value: the runtime fills this AFTER the canonical approval
/// path returned `.approved(grant:)` for exactly this call, from its own run
/// state, the approved call and the canonical target resolution — never from
/// a model-supplied confirmation.
public struct RuntimeAuthorityEvidence: Sendable, Hashable {
    public var runID: UUID
    public var taskID: UUID?
    public var environmentBinding: String
    public var canonicalTarget: String
    public var toolName: String
    public var operation: String
    public var operationID: String
    public var idempotencyKey: String
    public var baseRevision: String?
    public var payloadDigest: String
    /// The existing approval grant this operation was authorized under.
    /// Required for effectful operations: a token is never minted without the
    /// canonical permission result.
    public var approvalGrantID: UUID

    public init(
        runID: UUID,
        taskID: UUID?,
        environmentBinding: String,
        canonicalTarget: String,
        toolName: String,
        operation: String,
        operationID: String,
        idempotencyKey: String,
        baseRevision: String?,
        payloadDigest: String,
        approvalGrantID: UUID
    ) {
        self.runID = runID
        self.taskID = taskID
        self.environmentBinding = environmentBinding
        self.canonicalTarget = canonicalTarget
        self.toolName = toolName
        self.operation = operation
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.baseRevision = baseRevision
        self.payloadDigest = payloadDigest
        self.approvalGrantID = approvalGrantID
    }
}

/// One runtime-issued operation authority. See the file header: not Codable
/// on purpose, and only the issuing store can create a value that validates.
public struct RuntimeTaskAuthority: Sendable, Hashable, Identifiable {
    public internal(set) var id: UUID
    public internal(set) var runID: UUID
    /// Business task identity (conversation), when known.
    public internal(set) var taskID: UUID?
    public internal(set) var environmentBinding: String
    public internal(set) var canonicalTarget: String
    public internal(set) var toolName: String
    /// Stable operation label, e.g. "apply", "export", "job.submit".
    public internal(set) var operation: String
    /// Provider call id of the approved call.
    public internal(set) var operationID: String
    public internal(set) var idempotencyKey: String
    public internal(set) var baseRevision: String?
    public internal(set) var payloadDigest: String
    /// The existing approval grant this authority was derived from. Never a
    /// new approval: the runtime mints the token only AFTER the canonical
    /// approval path allowed the call.
    public internal(set) var approvalGrantID: UUID?
    public internal(set) var issuedAt: Date
    public internal(set) var expiresAt: Date

    public init(
        id: UUID,
        runID: UUID,
        taskID: UUID?,
        environmentBinding: String,
        canonicalTarget: String,
        toolName: String,
        operation: String,
        operationID: String,
        idempotencyKey: String,
        baseRevision: String?,
        payloadDigest: String,
        approvalGrantID: UUID?,
        issuedAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.runID = runID
        self.taskID = taskID
        self.environmentBinding = environmentBinding
        self.canonicalTarget = canonicalTarget
        self.toolName = toolName
        self.operation = operation
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.baseRevision = baseRevision
        self.payloadDigest = payloadDigest
        self.approvalGrantID = approvalGrantID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    /// Exact binding comparison used by validate/consume. Any difference —
    /// including task, environment, target path, operation id or payload —
    /// fails the operation.
    func matches(_ binding: RuntimeAuthorityBinding) -> RuntimeAuthorityValidation {
        guard runID == binding.runID else {
            return .mismatch("runtime authority belongs to a different run")
        }
        guard taskID == binding.taskID else {
            return .mismatch("runtime authority belongs to a different task")
        }
        guard environmentBinding == binding.environmentBinding else {
            return .mismatch("runtime authority binds a different environment/workspace")
        }
        guard canonicalTarget == binding.canonicalTarget else {
            return .mismatch("runtime authority binds a different canonical target")
        }
        guard toolName == binding.toolName else {
            return .mismatch("runtime authority is bound to tool '\(toolName)', not '\(binding.toolName)'")
        }
        guard operation == binding.operation else {
            return .mismatch("runtime authority is bound to operation '\(operation)', not '\(binding.operation)'")
        }
        guard operationID == binding.operationID else {
            return .mismatch("runtime authority is bound to a different approved call")
        }
        guard idempotencyKey == binding.idempotencyKey else {
            return .mismatch("runtime authority is bound to a different idempotency key")
        }
        guard baseRevision == binding.baseRevision else {
            return .mismatch("runtime authority is bound to base revision '\(baseRevision ?? "none")'")
        }
        guard payloadDigest == binding.payloadDigest else {
            return .mismatch("runtime authority does not match the approved payload")
        }
        return .valid
    }
}

/// Canonical helpers shared by the runtime (mint side) and tool consumers
/// (consume side) so both derive byte-identical binding values.
public enum RuntimeAuthorityDigest {
    /// Digest of the approved payload in canonical JSON form (sorted keys), so
    /// a reordered-but-identical object matches while a different edit
    /// command never does. Falls back to the raw bytes when the payload is not
    /// a JSON object.
    public static func payloadDigest(_ argumentsJSON: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: argumentsJSON),
           let canonical = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            return FloeDigest.sha256Hex(canonical)
        }
        return FloeDigest.sha256Hex(argumentsJSON)
    }

    /// Canonical target identity for a call: the narrow file/document target
    /// when resolvable, the workspace wildcard for wildcard writes, and the
    /// tool scope identity otherwise. Two equal-content files at different
    /// paths therefore get different targets.
    ///
    /// `stagedDocument` carries the run's explicitly authorized Canvas staged
    /// document: a `cad.document` call addressing exactly that document pins
    /// to the staged draft root (see `MutationTargetResolver.resolve`), which
    /// the tool side mirrors. Nil keeps the plain workspace resolution.
    public static func canonicalTarget(
        for call: ToolCall,
        descriptor: ToolCatalog.Descriptor?,
        workspaceRootURL: URL?,
        stagedDocument: CanvasStagedDocumentAccess? = nil
    ) -> String {
        if let key = MutationTargetResolver.resolve(
            for: call,
            descriptor: descriptor,
            workspaceRootURL: workspaceRootURL,
            stagedDocument: stagedDocument
        ).keys.first {
            switch key.family {
            case .file: return "file:\(key.identity)"
            case .workspace: return "workspace:\(key.identity)"
            case .document: return "document:\(key.identity)"
            }
        }
        return scopeIdentity(call.scope)
    }

    /// Environment identity derivation key. The runtime and a consumer that
    /// holds the same real context derive the same value from the canonical
    /// workspace root and task identity — the exact inputs the environment
    /// router uses to select a task-owned environment.
    public static func environmentBinding(workspaceRootURL: URL?, conversationID: UUID?) -> String {
        let workspace = workspaceRootURL.map {
            String(FloeDigest.sha256Hex(Data($0.standardizedFileURL.resolvingSymlinksInPath().path.utf8)).prefix(16))
        } ?? "*"
        let task = conversationID?.uuidString ?? "-"
        return "task:\(task)|ws:\(workspace)"
    }

    /// Base revision carried by the approved arguments, when the tool's
    /// contract declares one. Part of the approved payload; the consumer must
    /// compare it against the real current revision.
    public static func baseRevision(in argumentsJSON: Data) -> String? {
        let keys = ["baseRevision", "expectedRevision", "expectedSHA256", "baseSHA256", "revision"]
        guard let object = try? JSONSerialization.jsonObject(with: argumentsJSON) as? [String: Any] else {
            return nil
        }
        for key in keys {
            if let value = object[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let value = object[key] as? Int { return String(value) }
        }
        return nil
    }

    private static func scopeIdentity(_ scope: ToolScope) -> String {
        switch scope {
        case .local: return "workspace:*"
        case .host(let id): return "host:\(id.uuidString)"
        case .hostPath(let id, let path): return "host:\(id.uuidString):\(path)"
        }
    }
}

/// Issues, validates, consumes and revokes `RuntimeTaskAuthority` tokens for
/// one process. The store is the single authority: a token validates only
/// when a record with the SAME id and the SAME complete value was issued
/// here, so constructing a struct-like twin elsewhere can never pass.
public actor RuntimeAuthorityStore {
    /// Process-wide store used by the app runtime and tools. Tests may
    /// construct an isolated instance and pass it through the runtime.
    public static let shared = RuntimeAuthorityStore()

    /// Hard bound on live records; expired records are purged on every issue
    /// and the oldest are evicted first, so a long-lived process cannot grow
    /// this ledger without limit.
    static let maxRecords = 512

    private var records: [UUID: RuntimeTaskAuthority] = [:]
    private var consumed: Set<UUID> = []
    private var revoked: Set<UUID> = []

    public init() {}

    /// Mints a token for one already-approved task operation. Call this ONLY
    /// after the canonical permission path produced its result for exactly
    /// this call; the store does not itself decide anything, and evidence
    /// fields are compared verbatim at every consume.
    @discardableResult
    public func issue(
        _ evidence: RuntimeAuthorityEvidence,
        ttl: TimeInterval = 15 * 60,
        at now: Date = Date()
    ) -> RuntimeTaskAuthority {
        purgeExpired(at: now)
        let token = RuntimeTaskAuthority(
            id: UUID(),
            runID: evidence.runID,
            taskID: evidence.taskID,
            environmentBinding: evidence.environmentBinding,
            canonicalTarget: evidence.canonicalTarget,
            toolName: evidence.toolName,
            operation: evidence.operation,
            operationID: evidence.operationID,
            idempotencyKey: evidence.idempotencyKey,
            baseRevision: evidence.baseRevision,
            payloadDigest: evidence.payloadDigest,
            approvalGrantID: evidence.approvalGrantID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(max(1, ttl))
        )
        if records.count >= Self.maxRecords, records[token.id] == nil {
            let oldest = records.values
                .sorted { $0.issuedAt < $1.issuedAt }
                .prefix(records.count - Self.maxRecords + 1)
            for record in oldest {
                records.removeValue(forKey: record.id)
                consumed.remove(record.id)
                revoked.remove(record.id)
            }
        }
        records[token.id] = token
        consumed.remove(token.id)
        revoked.remove(token.id)
        return token
    }

    /// Read-only validation against the concrete binding. Does not consume.
    public func validate(
        _ authority: RuntimeTaskAuthority,
        binding: RuntimeAuthorityBinding,
        at now: Date = Date()
    ) -> RuntimeAuthorityValidation {
        guard let record = records[authority.id] else { return .unknown }
        // Full-value equality: any mutated field (including the approval
        // grant) fails, so a partially edited token is never accepted.
        guard record == authority else {
            return .mismatch("runtime authority fields do not match the issued record")
        }
        if revoked.contains(authority.id) { return .revoked }
        if now >= record.expiresAt { return .expired }
        if consumed.contains(authority.id) { return .alreadyConsumed }
        return record.matches(binding)
    }

    /// Validates and claims a single-use token. A token that fails any binding
    /// is NEVER consumed; a valid token is burned atomically so two
    /// concurrent consumers cannot both succeed and a replayed operation
    /// cannot run twice under the same authority.
    public func consume(
        _ authority: RuntimeTaskAuthority,
        binding: RuntimeAuthorityBinding,
        at now: Date = Date()
    ) -> RuntimeAuthorityValidation {
        let validation = validate(authority, binding: binding, at: now)
        guard validation == .valid else { return validation }
        consumed.insert(authority.id)
        return .valid
    }

    /// Revokes one token. A revoked token never validates again.
    public func revoke(id: UUID) {
        guard records[id] != nil else { return }
        revoked.insert(id)
        consumed.remove(id)
    }

    /// Revokes every token for one run (run completion / user revocation).
    @discardableResult
    public func revoke(runID: UUID) -> Int {
        let ids = records.values.filter { $0.runID == runID }.map(\.id)
        for id in ids { revoke(id: id) }
        return ids.count
    }

    /// Drops expired records. Called on every `issue`; the runtime also calls
    /// it at run start and run end.
    @discardableResult
    public func purgeExpired(at now: Date = Date()) -> Int {
        let expired = records.values.filter { now >= $0.expiresAt }.map(\.id)
        for id in expired {
            records.removeValue(forKey: id)
            consumed.remove(id)
            revoked.remove(id)
        }
        return expired.count
    }

    /// Test/audit introspection only; never used for authorization decisions.
    public var activeCount: Int {
        records.values.filter { !revoked.contains($0.id) && !consumed.contains($0.id) }.count
    }

    public var recordCount: Int { records.count }
}

public extension ToolContext {
    /// Read-only validation of this context's runtime-issued authority against
    /// the exact concrete operation a tool is about to perform. Tools that
    /// only inspect should use this; tools that own a single effect must use
    /// `consumeRuntimeAuthority` instead.
    func validatedRuntimeAuthority(
        binding: RuntimeAuthorityBinding,
        store: RuntimeAuthorityStore = .shared
    ) async -> RuntimeAuthorityValidation {
        guard let runtimeAuthority else { return .unknown }
        return await store.validate(runtimeAuthority, binding: binding)
    }

    /// Validates and claims this context's runtime-issued authority. Reusable
    /// consume contract for effectful tools (Office/media apply, exports, job
    /// handlers): returns `.valid` exactly once per issued token.
    func consumeRuntimeAuthority(
        binding: RuntimeAuthorityBinding,
        store: RuntimeAuthorityStore = .shared
    ) async -> RuntimeAuthorityValidation {
        guard let runtimeAuthority else { return .unknown }
        return await store.consume(runtimeAuthority, binding: binding)
    }

    /// Builds the binding this context implies for one concrete operation.
    /// `canonicalTarget`, `baseRevision` and `payloadDigest` must be derived
    /// from the real resolved target and the exact approved payload by the
    /// consumer (for example after re-reading the document's current
    /// revision). This helper only fills the runtime-owned identity fields.
    func runtimeAuthorityBinding(
        toolName: String,
        operation: String,
        canonicalTarget: String,
        baseRevision: String?,
        payloadDigest: String
    ) -> RuntimeAuthorityBinding {
        RuntimeAuthorityBinding(
            runID: runID,
            taskID: conversationID,
            environmentBinding: RuntimeAuthorityDigest.environmentBinding(
                workspaceRootURL: workspaceRootURL,
                conversationID: conversationID
            ),
            canonicalTarget: canonicalTarget,
            toolName: toolName,
            operation: operation,
            operationID: toolCallID ?? "",
            idempotencyKey: toolIdempotencyKey,
            baseRevision: baseRevision,
            payloadDigest: payloadDigest
        )
    }
}
