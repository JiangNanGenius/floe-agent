import Foundation

// FloeCore — Registry and resolution service for typed design targets.
//
// `DesignTargetService` is the single lookup T5 tools and T6 entrances use to
// turn a frozen `DesignTarget` into verified source bytes. It owns nothing
// itself: it dispatches to the registered `DesignOwnerAdapter`s, which
// re-derive permission and containment from live services. Resolution is
// idempotent and safe to retry; every call re-checks the frozen revision so
// concurrent manual edits surface as `DesignTargetError.moved` instead of a
// silent overwrite.

public actor DesignTargetService {
    private var adapters: [DesignTargetKind: any DesignOwnerAdapter]

    public init(adapters: [any DesignOwnerAdapter] = []) {
        self.adapters = [:]
        for adapter in adapters {
            self.adapters[adapter.kind] = adapter
        }
    }

    /// Registers (or replaces) the adapter for one kind. Replacing an
    /// adapter is an explicit app-wiring action, never a per-run mutation.
    public func register(_ adapter: any DesignOwnerAdapter) {
        adapters[adapter.kind] = adapter
    }

    public func isRegistered(_ kind: DesignTargetKind) -> Bool {
        adapters[kind] != nil
    }

    public func registeredKinds() -> [DesignTargetKind] {
        DesignTargetKind.allCases.filter { adapters[$0] != nil }
    }

    public func adapter(for kind: DesignTargetKind) -> (any DesignOwnerAdapter)? {
        adapters[kind]
    }

    /// The retained Canvas owner adapter, when wired.
    public func canvasAdapter() -> DesignCanvasOwnerAdapter? {
        adapters[.canvasNode] as? DesignCanvasOwnerAdapter
    }

    /// Resolves a frozen target to verified source bytes. Throws
    /// `DesignTargetError.unsupportedKind` when no adapter is connected
    /// (callers surface the honest capability reason), `.moved` when the
    /// owner changed since freeze, or the adapter's authorization/verification
    /// failure.
    public func resolve(_ target: DesignTarget, runID: UUID? = nil) async throws -> DesignResolvedSource {
        guard let adapter = adapters[target.kind] else {
            throw DesignTargetError.unsupportedKind(
                "No owner adapter is connected for \(target.kind.rawValue)"
            )
        }
        return try await adapter.resolve(target, runID: runID)
    }

    /// Resolve AND require that the caller's capability gate allows the
    /// resolved content family/operation. The content family comes from
    /// the verified resolved bytes (`resolved.contentType`), never from a
    /// hard-coded webpage assumption; a non-nil reason aborts with
    /// `.unavailable(reason)`.
    public func requireResolved(
        _ target: DesignTarget,
        runID: UUID? = nil,
        operation: DesignOperation,
        operationAllowed: @Sendable (DesignContentType, DesignOperation) -> String?
    ) async throws -> DesignResolvedSource {
        let resolved = try await resolve(target, runID: runID)
        if let reason = operationAllowed(resolved.contentType, operation) {
            throw DesignTargetError.unavailable(reason)
        }
        return resolved
    }

    /// Containment/authorization probe without surfacing bytes.
    public func contains(_ target: DesignTarget, runID: UUID? = nil) async -> Bool {
        guard let adapter = adapters[target.kind] else { return false }
        return await adapter.contains(target, runID: runID)
    }

    /// Authoritative verification for a creative first-result binding,
    /// dispatched to the registered adapter BEFORE the shared bind
    /// transaction writes any payload or envelope revision. Fails closed
    /// when the kind has no binding-verification authority.
    public func verifyCreativeFirstResultBinding(
        _ target: DesignTarget,
        boundResultID: String,
        bytes: Data,
        format: String,
        runID: UUID?
    ) async throws -> DesignCreativeResultProvenance {
        guard let adapter = adapters[target.kind] else {
            throw DesignTargetError.unsupportedKind(
                "No owner adapter is connected for \(target.kind.rawValue)"
            )
        }
        return try await adapter.verifyFirstResultBinding(
            target,
            boundResultID: boundResultID,
            bytes: bytes,
            format: format,
            runID: runID
        )
    }

    /// LIVE authorization at every shared-service boundary. This is not
    /// the initial freeze: each read/mutation calls it again so a revoked
    /// run grant, a task switch, or a deleted source is re-checked against
    /// the owner services immediately before use.
    /// - Canvas: the retained run→canvas closure.
    /// - File: the workspace file port's live permission/ containment.
    /// - Chat attachment: the attachment must still belong to the exact
    ///   originating task (and the run, when present, to that task).
    /// - Creative: the creation target must still exist.
    public func authorize(_ target: DesignTarget, runID: UUID? = nil) async -> Bool {
        guard let adapter = adapters[target.kind] else { return false }
        return await adapter.contains(target, runID: runID)
    }

    /// Existence probe (owner still has the source).
    public func exists(_ target: DesignTarget) async -> Bool {
        guard let adapter = adapters[target.kind] else { return false }
        return await adapter.exists(target)
    }

    /// Reads the owner's current revision token WITHOUT resolving bytes,
    /// used by late-candidate detection. Implemented via a lightweight
    /// resolve on adapters that only read cheap metadata; the default path
    /// resolves and discards data. Returns nil when the source is gone
    /// (deleted node/file) — callers treat that as "candidate can no longer
    /// be adopted update-original".
    public func currentRevisionToken(_ target: DesignTarget, runID: UUID? = nil) async -> String? {
        guard let adapter = adapters[target.kind] else { return nil }
        guard let source = try? await adapter.resolve(target.freezing(revision: nil), runID: runID) else {
            return nil
        }
        return source.baseRevisionToken
    }
}

// MARK: - Non-canvas owner persistence contract

/// Envelope persisting one typed target's design state. The inner
/// `DesignProject` REUSES the existing state machine unchanged (its `nodeID`
/// is the target's stable key); the envelope adds owner CAS revisioning so
/// file/chat/creative workflows have the same replay-before-conflict and
/// single-advance guarantees as the Canvas CAS, without a second project
/// model.
public struct DesignOwnerEnvelope: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    /// Snapshot of the target identity at bind time.
    public var target: DesignTarget
    /// Monotonic owner-side revision; each successful mutation advances by 1.
    public var revision: Int64
    public var project: DesignProject
    /// Authoritative provenance of the CREATIVE first-result binding recorded
    /// by the shared bind transaction AFTER the app port verified the real
    /// retained asset. nil means unproven (legacy or never verified): a run
    /// must not treat the bound identity as authority. Optional so envelopes
    /// written before this field decode unchanged.
    public var creativeFirstResultProvenance: DesignCreativeResultProvenance?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        target: DesignTarget,
        project: DesignProject,
        revision: Int64 = 0,
        creativeFirstResultProvenance: DesignCreativeResultProvenance? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.target = target
        self.project = project
        self.revision = revision
        self.creativeFirstResultProvenance = creativeFirstResultProvenance
        self.createdAt = Date()
        self.updatedAt = createdAt
    }
}

/// Owner CAS implemented by the app over the existing artifact authority
/// (namespace `DesignRevisions/owners/...`). Core never assumes file layout.
public protocol DesignOwnerProjectStore: Sendable {
    func load(targetKey: String) async throws -> DesignOwnerEnvelope?
    /// Compare-and-swap: nil expectedRevision means create-only. Returns the
    /// new revision. A mismatch throws (caller maps to a conflict error).
    @discardableResult
    func save(
        _ envelope: DesignOwnerEnvelope,
        targetKey: String,
        expectedRevision: Int64?
    ) async throws -> Int64
}

// MARK: - Capability bridge for owner kinds

/// Maps owner kinds to the honest availability text the UI/tools show. The
/// app constructs one of these while wiring adapters; an unregistered kind
/// reports exactly why instead of pretending an entrance exists.
public struct DesignTargetCapabilityView: Sendable {
    public let registered: Set<DesignTargetKind>
    public let reasons: [DesignTargetKind: String]

    public init(registered: Set<DesignTargetKind>, reasons: [DesignTargetKind: String] = [:]) {
        self.registered = registered
        self.reasons = reasons
    }

    public func isAvailable(_ kind: DesignTargetKind) -> Bool { registered.contains(kind) }

    public func reason(_ kind: DesignTargetKind) -> String {
        if registered.contains(kind) { return "" }
        return reasons[kind] ?? "Not connected for \(kind.rawValue) in this build"
    }
}
