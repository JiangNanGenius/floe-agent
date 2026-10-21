// SPDX-License-Identifier: MPL-2.0
//
// G02 trusted-host PROVIDER MODEL-SET staging seam (large profiles),
// required by MAIN_PROVIDER_LARGE_MODELSET_DIRECTION_20261021 +
// Main's 2026-10-21 full-fidelity large-profile review.
//
// Problem it solves: the frozen save-candidate/ingress budgets stay exactly
// what they are (`ProviderSaveCandidate` supports up to 512 selectedModels
// while the raw candidate is capped at 16,384 bytes, and the vault intent
// JSON / `config.provider.save` payload share that same 16,384 bound). A
// valid large profile therefore cannot be inlined through the public JSON
// ingress at all — not for Set, Keep, Clear or the draft candidate builder.
// This seam prepares the full selected-model body through a NARROW
// TRUSTED-HOST JNI service (never model-callable: no command name, no
// payload vocabulary, no permission, unreachable from the V3 bridge), and
// the frozen candidate then carries ONLY a small opaque reference that is
// mutually exclusive with inline `selectedModels`.
//
// Authority & binding (direction-conformant, nothing invented):
//  * begin/append/seal/cancel all require the caller's own live `rt:v1:`
//    provider-editor route handle, re-validated through the SAME
//    `G02HostRouteContextProvider.assertLiveProviderRoute` authority the
//    secure ingress and the draft probe already use: accepted Root epoch +
//    ONE live editor incarnation. A stale/foreign/replaced route refuses
//    before any stage exists or mutates.
//  * Every stage binds the ACTUAL provider UUID, the captured Root epoch,
//    the route token+generation and the editor identity, plus the actual
//    baseRevision (create ⇒ resource `provider.<uuid>` version "0") and the
//    create-intent. Resolution re-checks the live route/epoch AND (for the
//    save path) the envelope/lease base revision and create intent: a
//    stale/foreign/expired/unsealed/tampered ref is refused BEFORE any
//    DB/secret effect, never consumed destructively.
//  * Only a SEALED stage is resolvable, and sealing is the immutable
//    transition: the canonical digest is computed over the ORIGINAL
//    `ConfigModelSnapshot` codec encoding (sorted-key `ModelProfile`
//    Codable — the same decode path `ProviderSaveCandidate` uses) and the
//    frozen reference is `ms:v1:<32hex-id>.<64hex-digest>`. The candidate
//    (and therefore the one-shot secure-lease copy) freezes that exact
//    identity + digest: the same token can never resolve different bytes.
//  * Resolution is a COPY: the accepted save's typed `ProviderSaveRequest`
//    already retains the immutable models through physical settlement
//    (confirmedNativePath); editor close / Root retirement sweeps only
//    UNCONSUMED stage records (the accepted copy lives on), mirroring the
//    vault's live-intent discard and the draft-probe retirement sweep.
//
// Bounds — DERIVED FROM THE ACTUAL ORIGINAL LIMITS, no silently raised
// budgets, no assumed example math:
//  * `maximumModels = 512` is the UNCHANGED explicit `ProviderSaveCandidate`
//    parser bound.
//  * The per-model bound is NOT the 16,384 candidate bound: the original
//    single-model wire is `config.model.save`, whose payload is ONE
//    `ModelProfile` snapshot bounded by `ConfigJSON.object` at
//    `ConfigPageBudget.maximumCommandPayloadBytes = 61_440 bytes. Every
//    staged row and every staged chunk therefore carries that proven
//    ceiling; a row larger than it could never be persisted by ANY
//    original command either, so it is a typed refusal, never a silent
//    drop or budget increase.
//  * Aggregate per stage: 512 × 61,440 = 31,469,312 bytes (about 30 MiB) —
//    a pure product of the supported count and the proven per-row limit,
//    measured on canonical serialized bytes.
//  * At most TWO live (staging or sealed, uncancelled/unexpired) stages per
//    accepted Root epoch: the route registry admits exactly one live editor
//    incarnation at a time, so two stages cover a re-stage-before-retry
//    transition; a third begin refuses typed `saturated` with NO mutation.
//    Expired/cancelled records free capacity at the next sweep.
//  * Stage TTL: 30 minutes absolute. An accepted save owns its typed copy,
//    so expiry can only ever discard an un-consumed draft stage — never
//    "accepted-save data". Failed-before-effect saves retry by RE-STAGING
//    (the App cancels its previous stage first; a spent stage is never
//    implicitly reused for an unknown mutation).
//  * No plaintext is ever persisted: stages are RAM-only like the vault
//    lease and the draft probe; process death loses them and the durable
//    reconciliation ledgers behave exactly as before. No secret bytes
//    enter staging (this carries model metadata rows only).
//
// Ordered/idempotent chunks:
//  * `append(stageID, index, chunk)`: index must equal the stage's next
//    expected index; a resend of an ALREADY-ACCEPTED index is idempotent
//    ONLY under byte-equal sha256 of the exact chunk payload; a divergent
//    same-index resend or a gap refuses typed (no partial accept, no
//    silent reorder, no duplicate row ingestion).
//  * Each chunk is the closed JSON ARRAY of ORIGINAL ModelProfile shapes
//    (`ConfigModelSnapshot.decode`, context "modelSet.chunk") — the exact
//    codec the inline candidate uses; malformed rows refuse before seal,
//    and resolution re-checks the digest over the decoded canonical array.
//
// This source is a private candidate: NOT compiled, NOT executed by this
// package (batch-first policy). The C ABI exports below are the only new
// native surface; route-retirement sweeps land as additive private patches
// for Main (see the code batch HANDOFF).
import Foundation
import Dispatch
import FloeCore

// MARK: - Frozen status surface (bridge-local numeric, draft-probe class)

public enum ProviderModelSetStatus {
    public static let ok: Int32 = 0
    public static let invalidArgument: Int32 = -105
    /// Malformed chunk: not a JSON array, or a row the original codec
    /// refuses (same decode the inline candidate uses).
    public static let invalidChunk: Int32 = -110
    /// More than `maximumLiveStagesPerEpoch` live stages for the accepted
    /// epoch: refused BEFORE any stage mutation.
    public static let saturated: Int32 = -112
    /// Index gap or a same-index resend with divergent bytes.
    public static let orderViolation: Int32 = -113
    /// Seal count divergent from staged rows, or count over the proven
    /// supported bound.
    public static let countMismatch: Int32 = -114
    /// Append/seal/cancel against a sealed stage, or resolve of an
    /// unsealed stage (sealed is the only immutable, consumable state).
    public static let sealedStateViolation: Int32 = -115
    /// Chunk over the proven per-chunk byte bound.
    public static let chunkTooLarge: Int32 = -116
    /// Unknown / retired / expired / cancelled stage, or the stage's route
    /// handle is no longer the live accepted-epoch provider editor.
    public static let stageUnavailable: Int32 = -117
    /// The frozen ref's digest does not equal the sealed canonical digest.
    public static let digestMismatch: Int32 = -119
    /// provider / create-intent / base-revision divergence between the
    /// candidate context and the stage's recorded binding.
    public static let bindingDivergence: Int32 = -120
    /// Canonical `msb:v1:<32hex>` stage id capacity including the NUL.
    public static let handleCapacity: Int32 = 40
    /// Canonical `ms:v1:<32hex>.<64hex>` frozen ref capacity including NUL.
    public static let refCapacity: Int32 = 128
}

// MARK: - Proven bounds

public enum ProviderModelSetLimits {
    /// The ACTUAL original single-model wire bound: `config.model.save`
    /// accepts ONE ModelProfile snapshot payload, capped by
    /// ConfigJSON.object at ConfigPageBudget.maximumCommandPayloadBytes.
    public static let maximumModelRowBytes = 61_440
    /// One staged chunk is an array of those same row shapes; it carries
    /// the same proven class bound (measured on the submitted bytes).
    public static let maximumChunkBytes = 61_440
    /// UNCHANGED original `ProviderSaveCandidate.selectedModels` count
    /// bound. Never raised, never lowered.
    public static let maximumModels = 512
    /// 512 × 61,440 — a pure product of the supported count and the
    /// proven per-row bound (canonical serialized bytes).
    public static let maximumStageBytes = 512 * 61_440   // 31_469_312
    /// Live (staging|sealed, uncancelled/unexpired) stages per accepted
    /// Root epoch. See the header rationale (one live editor + retry
    /// headroom); a third begin refuses before mutation.
    public static let maximumLiveStagesPerEpoch = 2
    /// Absolute un-consumed stage lifetime in milliseconds. Accepted saves
    /// own typed copies, so this can only ever discard a draft stage.
    public static let stageTTLMillis: UInt64 = 1_800_000
    public static let stageIDPrefix = "msb:v1:"
    public static let frozenRefPrefix = "ms:v1:"
    /// Frozen ref: "ms:v1:" + 32 hex + "." + 64 hex.
    public static let frozenRefBytes = 6 + 32 + 1 + 64
}

// MARK: - Errors

public enum ProviderModelSetError: Error, Equatable {
    case invalidArgument
    case stageUnavailable
    case saturated
    case invalidChunk
    case chunkTooLarge
    case orderViolation
    case countMismatch
    case sealedStateViolation
    case digestMismatch
    case bindingDivergence
}

/// The live authority snapshot a stage is bound to (captured at begin AND
/// re-asserted at every mutation and at resolve). Production fills it from
/// the trusted route registry; qualification tests bind a scripted double
/// (same pattern as `G02HostDraftProbeRegistry.facadeProviderForTesting`).
public struct ProviderModelSetAuthority: Sendable, Equatable {
    public let rootEpoch: UInt64
    public let routeToken: String
    public let routeGeneration: UInt64
    public let editorID: String

    public init(rootEpoch: UInt64, routeToken: String,
                routeGeneration: UInt64, editorID: String) {
        self.rootEpoch = rootEpoch
        self.routeToken = routeToken
        self.routeGeneration = routeGeneration
        self.editorID = editorID
    }
}

// MARK: - Frozen reference grammar

public enum ProviderModelSetRef {
    /// Parses the canonical frozen ref `ms:v1:<32hex>.<64hex>` (exact).
    public static func parse(_ raw: String) -> (stageID: String, digest: String)? {
        guard raw.utf8.count == ProviderModelSetLimits.frozenRefBytes,
              raw.hasPrefix(ProviderModelSetLimits.frozenRefPrefix) else { return nil }
        let body = String(raw.dropFirst(ProviderModelSetLimits.frozenRefPrefix.count))
        guard let dot = body.firstIndex(of: ".") else { return nil }
        let idPart = String(body[..<dot])
        let digestPart = String(body[body.index(after: dot)...])
        guard isLowerHex(idPart, length: 32), isLowerHex(digestPart, length: 64) else {
            return nil
        }
        return (ProviderModelSetLimits.frozenRefPrefix + idPart, digestPart)
    }

    /// Parses the canonical stage id `msb:v1:<32hex>` (exact).
    public static func parseStageID(_ raw: String) -> Bool {
        guard raw.utf8.count == 7 + 32,
              raw.hasPrefix(ProviderModelSetLimits.stageIDPrefix) else { return false }
        return isLowerHex(String(raw.dropFirst(7)), length: 32)
    }

    static func isLowerHex(_ value: String, length: Int) -> Bool {
        value.count == length && value.allSatisfy {
            ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f")
        }
    }
}

// MARK: - Registry

/// Process-wide trusted host stage registry. One lock linearizes begin /
/// append / seal / cancel / resolve / sweeps, so a concurrent Root
/// retirement or editor close can never half-mutate a stage or resolve a
/// record mid-transition. RAM-only payloads; no logging of content.
public final class ProviderModelSetRegistry: @unchecked Sendable {
    public static let shared = ProviderModelSetRegistry()

    private enum State {
        case staging
        case sealed(digest: String)
    }

    private struct Stage {
        let id: String
        let providerID: UUID
        let authority: ProviderModelSetAuthority
        let baseResourceID: String
        let baseVersion: String
        let createIntent: Bool
        var nextIndex: Int = 0
        /// index -> sha256 of the EXACT accepted chunk bytes (idempotence +
        /// tamper evidence for a same-index resend).
        var chunkDigests: [Int: String] = [:]
        var rows: [ModelProfile] = []
        var canonicalBytesTotal: Int = 0
        var state: State = .staging
        let createdAtMillis: UInt64
    }

    private let lock = NSLock()
    private var stages: [String: Stage] = [:]
    /// Insertion order for bounded sweeps (expiry before eviction order).
    private var order: [String] = []

    /// Test-only authority override (production path is the trusted route
    /// registry). NEVER settable from any wire/model path.
    nonisolated(unsafe) public static var authorityForTesting:
        (@Sendable (String) -> ProviderModelSetAuthority?)?

    /// Test-only millisecond clock (same class as the vault clockOverride).
    nonisolated(unsafe) public static var clockForTesting: (@Sendable () -> UInt64)?

    private init() {}

    private func nowMillis() -> UInt64 {
        if let clock = Self.clockForTesting { return clock() }
        return DispatchTime.now().uptimeNanoseconds / 1_000_000
    }

    private func authority(token: String) -> ProviderModelSetAuthority? {
        if let override = Self.authorityForTesting { return override(token) }
        guard let binding = G02HostSecureIngress.registry.assertLiveProviderRoute(
            token: token) else { return nil }
        return ProviderModelSetAuthority(
            rootEpoch: binding.rootEpoch,
            routeToken: binding.route.token,
            routeGeneration: binding.route.generation,
            editorID: binding.editorID)
    }

    // MARK: Begin

    /// Freeze a new stage bound to the live provider-editor route + the
    /// actual provider id / base revision / create intent. Refused BEFORE
    /// any mutation on: non-canonical arguments, no live authority,
    /// revision/intent divergence, or epoch saturation.
    public func begin(providerID: UUID, baseResourceID: String, baseVersion: String,
                      createIntent: Bool, routeAssertion: String) throws -> String {
        guard G02HostRouteContextProvider.isCanonicalRouteToken(routeAssertion) else {
            throw ProviderModelSetError.invalidArgument
        }
        // Canonical provider resource identity: `provider.<uuid>` with the
        // SAME UUID. Compared by parsed UUID (Swift `uuidString` is
        // uppercase; the App may legitimately hand back either case for a
        // freshly minted id) — never a case-sensitive string accident.
        guard baseResourceID.hasPrefix("provider."),
              let resourceUUID = UUID(uuidString: String(baseResourceID
                .dropFirst("provider.".count))),
              resourceUUID == providerID else {
            throw ProviderModelSetError.bindingDivergence
        }
        guard baseVersion.utf8.count <= 256, !baseVersion.isEmpty else {
            throw ProviderModelSetError.invalidArgument
        }
        // Version must be the exact decimal the ORIGINAL provider CAS
        // vocabulary uses: "0" ONLY for a create intent; a plain decimal
        // base for an edit.
        if createIntent {
            guard baseVersion == "0" else {
                throw ProviderModelSetError.bindingDivergence
            }
        } else {
            guard baseVersion.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                  Int64(baseVersion) != nil else {
                throw ProviderModelSetError.invalidArgument
            }
        }
        guard let live = authority(token: routeAssertion) else {
            throw ProviderModelSetError.stageUnavailable
        }
        lock.lock()
        defer { lock.unlock() }
        sweepExpiredLocked()
        let liveCount = stages.values.reduce(into: 0) { count, stage in
            if stage.authority.rootEpoch == live.rootEpoch { count += 1 }
        }
        guard liveCount < ProviderModelSetLimits.maximumLiveStagesPerEpoch else {
            throw ProviderModelSetError.saturated
        }
        let id = Self.makeStageID()
        stages[id] = Stage(id: id, providerID: providerID, authority: live,
                           baseResourceID: baseResourceID, baseVersion: baseVersion,
                           createIntent: createIntent,
                           createdAtMillis: nowMillis())
        order.append(id)
        return id
    }

    // MARK: Append

    /// Ordered idempotent chunk append. `chunk` carries an array of original
    /// ModelProfile shapes, or ONE bare original snapshot when the array's
    /// two enclosure bytes would exceed the unchanged single-model bound. Every check (bytes, order, count,
    /// aggregate, codec) happens BEFORE any mutation of the stage's row
    /// set; a refusal never partially accepts.
    public func append(stageID: String, routeAssertion: String,
                       index: Int, chunk: Data) throws {
        guard ProviderModelSetRef.parseStageID(stageID),
              G02HostRouteContextProvider.isCanonicalRouteToken(routeAssertion) else {
            throw ProviderModelSetError.invalidArgument
        }
        guard index >= 0 else { throw ProviderModelSetError.invalidArgument }
        guard !chunk.isEmpty,
              chunk.count <= ProviderModelSetLimits.maximumChunkBytes else {
            throw ProviderModelSetError.chunkTooLarge
        }
        // Decode FIRST (pure): only original snapshot object(s) are accepted;
        // malformed content is a typed refusal.
        let decoded: [ModelProfile]
        var rowBytesTotal = 0
        do {
            guard let object = try? JSONSerialization.jsonObject(with: chunk) else {
                throw ProviderModelSetError.invalidChunk
            }
            let array: [Any]
            if let rows = object as? [Any] {
                array = rows
            } else if let row = object as? [String: Any] {
                // config.model.save accepts this exact bare snapshot up to
                // 61,440 bytes. No wrapper tax or public-budget increase.
                array = [row]
            } else {
                throw ProviderModelSetError.invalidChunk
            }
            guard !array.isEmpty else { throw ProviderModelSetError.invalidChunk }
            decoded = try array.map {
                try ConfigModelSnapshot.decode($0, context: "modelSet.chunk")
            }
            for model in decoded {
                let rowObject = try ConfigModelSnapshot.jsonObject(model)
                guard let canonical = ConfigJSON.canonicalData(rowObject) else {
                    throw ProviderModelSetError.invalidChunk
                }
                // Per-row proven bound (config.model.save payload class).
                guard canonical.count <= ProviderModelSetLimits.maximumModelRowBytes else {
                    throw ProviderModelSetError.invalidChunk
                }
                rowBytesTotal += canonical.count
            }
        } catch let error as ProviderModelSetError {
            throw error
        } catch {
            throw ProviderModelSetError.invalidChunk
        }
        let chunkDigest = ConfigJSON.sha256Hex(chunk)
        // Lock order (draft-probe precedent): the route authority is read
        // BEFORE the stage lock is ever taken; the stage lock is NEVER held
        // across a route-registry call.
        guard let fetched = authority(token: routeAssertion) else {
            throw ProviderModelSetError.stageUnavailable
        }
        lock.lock()
        defer { lock.unlock() }
        guard var stage = stages[stageID] else {
            throw ProviderModelSetError.stageUnavailable
        }
        guard stage.authority == fetched else {
            throw ProviderModelSetError.stageUnavailable
        }
        guard case .staging = stage.state else {
            throw ProviderModelSetError.sealedStateViolation
        }
        if index < stage.nextIndex {
            // Duplicate resend: idempotent ONLY under byte-equal digest.
            guard stage.chunkDigests[index] == chunkDigest else {
                throw ProviderModelSetError.orderViolation
            }
            return
        }
        guard index == stage.nextIndex else {
            throw ProviderModelSetError.orderViolation
        }
        guard stage.rows.count + decoded.count <= ProviderModelSetLimits.maximumModels,
              stage.canonicalBytesTotal + rowBytesTotal
                <= ProviderModelSetLimits.maximumStageBytes else {
            throw ProviderModelSetError.countMismatch
        }
        stage.rows.append(contentsOf: decoded)
        stage.canonicalBytesTotal += rowBytesTotal
        stage.chunkDigests[index] = chunkDigest
        stage.nextIndex = index + 1
        stages[stageID] = stage
    }

    // MARK: Seal

    /// Freeze the immutable set: verifies the caller's expected total count
    /// against what actually staged, computes the canonical digest over
    /// the decoded rows (sorted-key ModelProfile Codable — the original
    /// codec), and returns the frozen reference the candidate may carry.
    /// A second seal is idempotent ONLY for the identical frozen ref.
    public func seal(stageID: String, routeAssertion: String,
                     expectedCount: Int) throws -> String {
        guard ProviderModelSetRef.parseStageID(stageID),
              G02HostRouteContextProvider.isCanonicalRouteToken(routeAssertion),
              expectedCount >= 0 else {
            throw ProviderModelSetError.invalidArgument
        }
        let fetched = authority(token: routeAssertion)
        lock.lock()
        defer { lock.unlock() }
        guard var stage = stages[stageID] else {
            throw ProviderModelSetError.stageUnavailable
        }
        guard let fetched, stage.authority == fetched else {
            throw ProviderModelSetError.stageUnavailable
        }
        guard expectedCount <= ProviderModelSetLimits.maximumModels else {
            throw ProviderModelSetError.countMismatch
        }
        let digest: String
        switch stage.state {
        case .sealed(let existing):
            // Idempotent re-seal: only the identical count converges.
            guard stage.rows.count == expectedCount else {
                throw ProviderModelSetError.countMismatch
            }
            digest = existing
        case .staging:
            guard stage.rows.count == expectedCount else {
                throw ProviderModelSetError.countMismatch
            }
            let objects: [[String: Any]]
            do {
                objects = try stage.rows.map { try ConfigModelSnapshot.jsonObject($0) }
            } catch {
                throw ProviderModelSetError.invalidChunk
            }
            guard let canonical = ConfigJSON.canonicalData(objects) else {
                throw ProviderModelSetError.invalidChunk
            }
            digest = ConfigJSON.sha256Hex(canonical)
            stage.state = .sealed(digest: digest)
            stages[stageID] = stage
        }
        // Short id form: strip the "msb:v1:" prefix down to the 32 hex.
        let hexID = String(stageID.dropFirst(ProviderModelSetLimits.stageIDPrefix.count))
        return "\(ProviderModelSetLimits.frozenRefPrefix)\(hexID).\(digest)"
    }

    // MARK: Cancel

    /// Exact-owner discard of an UNCONSUMED draft stage. Idempotent for
    /// the same authority; a stale/foreign handle is refused (never clears
    /// a newer stage). An accepted save already owns its typed copy, so a
    /// late cancel cannot corrupt an in-flight or parked operation.
    @discardableResult
    public func cancel(stageID: String, routeAssertion: String) -> Bool {
        guard ProviderModelSetRef.parseStageID(stageID),
              G02HostRouteContextProvider.isCanonicalRouteToken(routeAssertion) else {
            return false
        }
        let fetched = authority(token: routeAssertion)
        lock.lock()
        defer { lock.unlock() }
        guard let stage = stages[stageID] else { return true } // already gone
        guard let fetched, stage.authority == fetched else {
            return false
        }
        removeLocked(stageID)
        return true
    }

    /// Editor-close sweep (called by the trusted route registry's
    /// exact-ownership clear, additive private patch for Main): discards
    /// every un-consumed stage bound to the retired route. Accepted-save
    /// data is not here — it lives in the retained typed request.
    public func cancelAll(routeToken: String) {
        lock.lock()
        defer { lock.unlock() }
        for (id, stage) in stages where stage.authority.routeToken == routeToken {
            removeLocked(id)
        }
    }

    /// Root-retirement sweep (same additive patch, retirement fence): the
    /// retiring epoch's stages are RAM-only and can never resolve under a
    /// newer epoch.
    public func cancelAll(rootEpoch: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        for (id, stage) in stages where stage.authority.rootEpoch == rootEpoch {
            removeLocked(id)
        }
    }

    private func removeLocked(_ id: String) {
        // Drop the record; staged content is secret-free model metadata
        // (value types) with no durable copy anywhere by design.
        stages.removeValue(forKey: id)
        order.removeAll { $0 == id }
    }

    private func sweepExpiredLocked() {
        let now = nowMillis()
        for id in order {
            guard let stage = stages[id] else { continue }
            if now >= stage.createdAtMillis + ProviderModelSetLimits.stageTTLMillis {
                removeLocked(id)
            }
        }
    }

    // MARK: Resolve

    /// Resolve a frozen reference into the immutable typed models.
    /// NON-DESTRUCTIVE: repeatable while the stage lives (a before-effect
    /// failure may retry), and NEVER counts as a save or consumes any
    /// credential intent. A draft probe BORROWS the same frozen set.
    ///
    /// Save path (`isDraftProbe == false`): the effective base revision
    /// (lease base preferred, else envelope) MUST be present and equal to
    /// the stage's recorded binding, and the create intent must match.
    /// Probe path: read-only borrow — provider/epoch/route/seal/digest are
    /// still enforced; the CAS axes are decided later by the original
    /// machinery on any actual save.
    public func resolve(frozenRef: String, providerID: UUID, createIntent: Bool,
                        baseRevision: ConfigRevision?,
                        isDraftProbe: Bool) throws -> [ModelProfile] {
        guard let parsed = ProviderModelSetRef.parse(frozenRef) else {
            throw ProviderModelSetError.invalidArgument
        }
        // The frozen ref's id part is the 32 hex shared with the stage id;
        // rebuild the canonical `msb:v1:<32hex>` registry key exactly.
        let hexID = String(parsed.stageID
            .dropFirst(ProviderModelSetLimits.frozenRefPrefix.count))
        let normalizedID = ProviderModelSetLimits.stageIDPrefix + hexID
        // Phase 1: under the stage lock, take an immutable COPY (a sealed
        // stage's rows/chunks never mutate; cancel/retire only removes the
        // record). The route authority is NEVER consulted while this lock
        // is held (route -> stage is the only allowed direction).
        enum Phase1 {
            case stage(Stage)
            case unavailable
            case unsealed
            case digestMismatch
        }
        let phase1: Phase1
        lock.lock()
        sweepExpiredLocked()
        if let stage = stages[normalizedID] {
            switch stage.state {
            case .staging:
                phase1 = .unsealed
            case .sealed(let sealedDigest):
                if sealedDigest == parsed.digest {
                    phase1 = .stage(stage)
                } else {
                    phase1 = .digestMismatch
                }
            }
        } else {
            phase1 = .unavailable
        }
        lock.unlock()
        let snapshot: Stage
        switch phase1 {
        case .unavailable: throw ProviderModelSetError.stageUnavailable
        case .unsealed: throw ProviderModelSetError.sealedStateViolation
        case .digestMismatch: throw ProviderModelSetError.digestMismatch
        case .stage(let stage): snapshot = stage
        }
        // Phase 2 (no stage lock): re-assert the live authority for this
        // stage's recorded route. Root epoch advanced, route replaced or
        // closed ⇒ retired.
        guard authority(token: snapshot.authority.routeToken) == snapshot.authority else {
            throw ProviderModelSetError.stageUnavailable
        }
        // Digest re-check over the decoded rows (defense in depth: a stored
        // ref can never resolve divergent bytes).
        let recheck: String
        do {
            let objects = try snapshot.rows.map { try ConfigModelSnapshot.jsonObject($0) }
            guard let canonical = ConfigJSON.canonicalData(objects) else {
                throw ProviderModelSetError.invalidChunk
            }
            recheck = ConfigJSON.sha256Hex(canonical)
        } catch let error as ProviderModelSetError {
            throw error
        } catch {
            throw ProviderModelSetError.invalidChunk
        }
        guard recheck == parsed.digest else {
            throw ProviderModelSetError.digestMismatch
        }
        // Binding checks.
        guard snapshot.providerID == providerID else {
            throw ProviderModelSetError.bindingDivergence
        }
        guard snapshot.createIntent == createIntent else {
            throw ProviderModelSetError.bindingDivergence
        }
        if !isDraftProbe {
            if createIntent {
                // Create binding: the expected-absent "0" marker IS the
                // base; the durable row-absent CAS is enforced later by
                // the original prepare (unchanged). No optimistic bypass:
                // a create stage can only be consumed by a create.
                guard snapshot.baseVersion == "0", snapshot.baseResourceID.count > 0 else {
                    throw ProviderModelSetError.bindingDivergence
                }
            } else {
                // The edit save path must carry its CAS binding: absent
                // base revision is NEVER an optimistic bypass for a
                // staged set.
                guard let effective = baseRevision else {
                    throw ProviderModelSetError.bindingDivergence
                }
                guard effective.resourceID == snapshot.baseResourceID,
                      effective.version == snapshot.baseVersion else {
                    throw ProviderModelSetError.bindingDivergence
                }
            }
        }
        return snapshot.rows   // value-type array copy; immutable after seal
    }

    // MARK: Test seam

    /// Test-only live stage count (bounded surface, never the content).
    public var liveStageCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return stages.count
    }

    public func resetForTesting() {
        lock.lock()
        for id in Array(stages.keys) { removeLocked(id) }
        stages.removeAll()
        order.removeAll()
        lock.unlock()
        Self.authorityForTesting = nil
        Self.clockForTesting = nil
    }

    private static func makeStageID() -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(16)
        for _ in 0..<16 { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
        return ProviderModelSetLimits.stageIDPrefix
            + bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Wire-side consumer mapping (facade/executor shared)

/// Maps the registry's typed errors onto the frozen closed wire refusal
/// codes. Reasons are closed identifiers only — never a path, token, row
/// content or secret.
enum ProviderModelSetConsumer {
    struct Context {
        let providerID: UUID
        let createIntent: Bool
        /// Lease base (Set) or envelope revision (Keep/Clear); nil is only
        /// valid on the draft-probe borrow. Both carry the same
        /// resource/version pair.
        let baseRevision: ConfigRevision?
        let isDraftProbe: Bool
    }

    /// Resolve a frozen-ref candidate into typed models. Returns `nil`
    /// when the candidate carries no reference (inline path unchanged).
    static func resolveIfReferenced(_ candidate: ProviderSaveCandidate,
                                    context: Context) throws -> [ModelProfile]? {
        guard let raw = candidate.modelSetRef else { return nil }
        guard let parsed = ProviderModelSetRef.parse(raw) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "modelSetRefMalformed")
        }
        do {
            let models = try ProviderModelSetRegistry.shared.resolve(
                frozenRef: raw,
                providerID: context.providerID,
                createIntent: context.createIntent,
                baseRevision: context.baseRevision,
                isDraftProbe: context.isDraftProbe)
            guard models.count <= ProviderModelSetLimits.maximumModels else {
                // Unreachable (seal enforces it) — honest belt.
                throw ConfigDomainError(code: .payloadTooLarge, reason: "modelSetCount")
            }
            return models
        } catch let error as ProviderModelSetError {
            throw mapError(error)
        }
    }

    static func mapError(_ error: ProviderModelSetError) -> ConfigDomainError {
        switch error {
        case .invalidArgument:
            return ConfigDomainError(code: .invalidEnvelope, reason: "modelSetRefMalformed")
        case .stageUnavailable:
            return ConfigDomainError(code: .runtimeUnavailable, reason: "modelSetStageUnavailable")
        case .saturated:
            return ConfigDomainError(code: .mailboxSaturated, reason: "modelSetSaturated")
        case .invalidChunk:
            return ConfigDomainError(code: .invalidEnvelope, reason: "modelSetChunkInvalid")
        case .chunkTooLarge:
            return ConfigDomainError(code: .payloadTooLarge, reason: "modelSetChunkTooLarge")
        case .orderViolation:
            return ConfigDomainError(code: .invalidEnvelope, reason: "modelSetOrderViolation")
        case .countMismatch:
            return ConfigDomainError(code: .invalidEnvelope, reason: "modelSetCountMismatch")
        case .sealedStateViolation:
            return ConfigDomainError(code: .invalidEnvelope, reason: "modelSetUnsealed")
        case .digestMismatch:
            return ConfigDomainError(code: .invalidEnvelope, reason: "modelSetDigestMismatch")
        case .bindingDivergence:
            return ConfigDomainError(code: .invalidEnvelope, reason: "modelSetBindingDivergence")
        }
    }
}

// MARK: - Trusted host C ABI (App process only; not a V3 command)

private func modelSetCLength(_ pointer: UnsafePointer<CChar>, maximum: Int) -> Int? {
    var length = 0
    while length <= maximum {
        if pointer[length] == 0 { return length }
        length += 1
    }
    return nil
}

private func modelSetCString(_ pointer: UnsafePointer<CChar>, maximum: Int) -> String? {
    guard let length = modelSetCLength(pointer, maximum: maximum), length > 0 else {
        return nil
    }
    return String(decoding: UnsafeBufferPointer(start: pointer, count: length)
        .map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private func modelSetWrite(_ value: String, into out: UnsafeMutablePointer<CChar>,
                           _ cap: Int32) -> Int32 {
    guard value.utf8.count + 1 <= Int(cap) else { return ProviderModelSetStatus.invalidArgument }
    for (index, byte) in value.utf8.enumerated() { out[index] = CChar(bitPattern: byte) }
    out[value.utf8.count] = 0
    return ProviderModelSetStatus.ok
}

private func modelSetStatus(_ error: Error) -> Int32 {
    if let stageError = error as? ProviderModelSetError {
        switch stageError {
        case .invalidArgument: return ProviderModelSetStatus.invalidArgument
        case .stageUnavailable: return ProviderModelSetStatus.stageUnavailable
        case .saturated: return ProviderModelSetStatus.saturated
        case .invalidChunk: return ProviderModelSetStatus.invalidChunk
        case .chunkTooLarge: return ProviderModelSetStatus.chunkTooLarge
        case .orderViolation: return ProviderModelSetStatus.orderViolation
        case .countMismatch: return ProviderModelSetStatus.countMismatch
        case .sealedStateViolation: return ProviderModelSetStatus.sealedStateViolation
        case .digestMismatch: return ProviderModelSetStatus.digestMismatch
        case .bindingDivergence: return ProviderModelSetStatus.bindingDivergence
        }
    }
    return ProviderModelSetStatus.invalidArgument
}

/// Freeze a new stage bound to the live provider editor route + the actual
/// provider id / base revision / create intent. Returns the canonical
/// `msb:v1:<32hex>` stage id into `outHandle`.
@_cdecl("floe_host_model_set_begin")
public func floeHostModelSetBegin(_ providerID: UnsafePointer<CChar>?,
                                  _ baseResourceID: UnsafePointer<CChar>?,
                                  _ baseVersion: UnsafePointer<CChar>?,
                                  _ createIntent: Int32,
                                  _ routeToken: UnsafePointer<CChar>?,
                                  _ outHandle: UnsafeMutablePointer<CChar>?,
                                  _ outCap: Int32) -> Int32 {
    guard let providerID, let baseResourceID, let baseVersion, let routeToken,
          let outHandle, outCap >= ProviderModelSetStatus.handleCapacity else {
        return ProviderModelSetStatus.invalidArgument
    }
    guard let idString = modelSetCString(providerID, maximum: 64),
          let providerUUID = UUID(uuidString: idString) else {
        return ProviderModelSetStatus.invalidArgument
    }
    guard let resource = modelSetCString(baseResourceID, maximum: 256),
          let version = modelSetCString(baseVersion, maximum: 256),
          let route = modelSetCString(routeToken, maximum: 64) else {
        return ProviderModelSetStatus.invalidArgument
    }
    do {
        let stageID = try ProviderModelSetRegistry.shared.begin(
            providerID: providerUUID,
            baseResourceID: resource,
            baseVersion: version,
            createIntent: createIntent != 0,
            routeAssertion: route)
        return modelSetWrite(stageID, into: outHandle, outCap)
    } catch {
        return modelSetStatus(error)
    }
}

/// Ordered idempotent chunk append. `chunk` is the closed JSON ARRAY of
/// original ModelProfile shapes (binary JNI bytes, within the proven
/// per-chunk bound; NEVER through the 16 KiB JSON ingress).
@_cdecl("floe_host_model_set_append")
public func floeHostModelSetAppend(_ stageID: UnsafePointer<CChar>?,
                                   _ routeToken: UnsafePointer<CChar>?,
                                   _ index: Int32,
                                   _ chunk: UnsafePointer<UInt8>?,
                                   _ chunkLen: Int32) -> Int32 {
    guard let stageID, let routeToken, let chunk, index >= 0, chunkLen > 0,
          Int(chunkLen) <= ProviderModelSetLimits.maximumChunkBytes,
          let stageString = modelSetCString(stageID, maximum: 64),
          let route = modelSetCString(routeToken, maximum: 64) else {
        return ProviderModelSetStatus.invalidArgument
    }
    do {
        try ProviderModelSetRegistry.shared.append(
            stageID: stageString,
            routeAssertion: route,
            index: Int(index),
            chunk: Data(bytes: UnsafeRawPointer(chunk), count: Int(chunkLen)))
        return ProviderModelSetStatus.ok
    } catch {
        return modelSetStatus(error)
    }
}

/// Seal the stage into the immutable set and write the frozen reference
/// `ms:v1:<32hex>.<64hex>` into `outRef` (capacity 128). `expectedCount`
/// is the caller's total row count; divergence refuses typed.
@_cdecl("floe_host_model_set_seal")
public func floeHostModelSetSeal(_ stageID: UnsafePointer<CChar>?,
                                 _ routeToken: UnsafePointer<CChar>?,
                                 _ expectedCount: Int32,
                                 _ outRef: UnsafeMutablePointer<CChar>?,
                                 _ outCap: Int32) -> Int32 {
    guard let stageID, let routeToken, let outRef,
          outCap >= ProviderModelSetStatus.refCapacity,
          expectedCount >= 0,
          let stageString = modelSetCString(stageID, maximum: 64),
          let route = modelSetCString(routeToken, maximum: 64) else {
        return ProviderModelSetStatus.invalidArgument
    }
    do {
        let frozenRef = try ProviderModelSetRegistry.shared.seal(
            stageID: stageString,
            routeAssertion: route,
            expectedCount: Int(expectedCount))
        return modelSetWrite(frozenRef, into: outRef, outCap)
    } catch {
        return modelSetStatus(error)
    }
}

/// Exact-owner cancel of this editor's un-consumed stage (retry re-stage
/// / editor discard). Idempotent for the same authority; stale/foreign
/// handles are refused and never clear a newer stage.
@_cdecl("floe_host_model_set_cancel")
public func floeHostModelSetCancel(_ stageID: UnsafePointer<CChar>?,
                                   _ routeToken: UnsafePointer<CChar>?) -> Int32 {
    guard let stageID, let routeToken,
          let stageString = modelSetCString(stageID, maximum: 64),
          let route = modelSetCString(routeToken, maximum: 64) else {
        return ProviderModelSetStatus.invalidArgument
    }
    return ProviderModelSetRegistry.shared.cancel(stageID: stageString,
                                                  routeAssertion: route)
        ? ProviderModelSetStatus.ok
        : ProviderModelSetStatus.stageUnavailable
}
