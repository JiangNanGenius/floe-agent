// SPDX-License-Identifier: MPL-2.0
//
// RB2 — ModelConfigurationCommitter: the ACTUAL Android implementation of the
// ORIGINAL FloeCore `ProviderBundleCommitting` seam (FloeCore
// ProviderSaveRunner.swift:48-61) over the ORIGINAL
// `ModelConfigurationStore` (FloePersistence ModelConfigurationStore.swift —
// symlinked UNMODIFIED upstream; the RB2-REPAIR candidate ships an overlay
// mirror whose ONLY delta is the Main-authorized narrow additive
// `expectedSyncRevision` same-writer CAS overload, default preserving every
// existing caller — see the mirror header + REPORT §symlinks). (private
// source candidate; NOT compiled, NOT executed; see REPORT.md limitations.)
//
// MC-R1 repair delta over the parent (job-d02beb16bd1840a9):
// * Provider edits now go through the ORIGINAL writer transaction's compare-
//   and-swap: `expectedSyncRevision` = the actual observed base revision the
//   ORIGINAL draft/runner chain produced (ProviderSaveDraft carries
//   `existingSyncRevision` verbatim — the runner and draft stay the
//   authority, unchanged). The store ADVANCES the persisted revision to
//   base+1 (Main settlement rule: "provider edits MUST advance a persisted
//   supported revision (overflow typed), stale requests rejected"), inside
//   the SAME `DatabaseManager.writer` transaction that performs the bundle
//   write — no separate read-then-unconditional-write window.
// * A durable CAS rejection that arrives AFTER the secret write is reported
//   truthfully: the bundle transaction wrote NOTHING (single transaction,
//   preflight + in-transaction gate before any mutation), the secret state
//   comes from its own physical assessment, and `databaseRowWritten` is
//   derived from the committer's ACTUAL committed-stage evidence, never
//   assumed false.
// * The preset sidecar failure no longer masquerades as a bundle failure:
//   the bundle transaction is already durable at that point, so the failure
//   is recorded as an honest `presetSidecarRecorded = false` diagnostic on
//   the committed reply (and a typed localCommit would have implied the
//   row rolled back — the parent's behavior was a real defect, fixed here).
// * Readback verification accepts EXACTLY the advanced revision
//   (base+1 == persisted), rejecting both unchanged-revision replays and
//   oversized jumps.
//
// Everything else stays the parent's frozen chain:
// * `commitProviderBundle` delegates the whole provider+models write to the
//   ORIGINAL single-transaction `saveProviderBundle(provider:models:
//   managedCapabilities:)` semantics (ModelConfigurationStore.swift:102-162),
//   which keeps the stable-UUID merge by provider+remoteModelID (:504-556),
//   the stale-row disable-instead-of-delete rule for FK-referenced rows
//   (:97-101,:126-156), and the complete preflight validation BEFORE
//   opening the write transaction (:108-113). No parallel write path is
//   invented; the original source/schema is not modified (mirror delta is
//   narrow-additive only).
// * Cross-store honesty (contract config.provider.save syncSemantics /
//   crossStoreHonesty): Keystore-class storage and SQLite are NOT one
//   transaction. A secret committed while the bundle write fails leaves an
//   orphan secret under the deterministic reference with NO DB row — that is
//   exactly what the ORIGINAL runner reports as `localCommit`; the retry
//   converges because the deterministic reference write is idempotent and
//   the bundle save is a single transaction. A readback failure leaves
//   row+secret in place and is reported as `readbackMismatch` — never
//   converted into a claim of no-effect, never a metadata-only key-presence
//   success.
// * ACTUAL canonical models only after commit AND readback: the effect
//   projection the facade emits is built from the store's canonical write
//   result RE-VERIFIED against the persisted rows; the deleted/disabled
//   split from the original `ProviderBundleResult` is carried honestly.
// * Local-only sync (BRIDGE_V3_MAIN_DECISIONS.localSync): every commit
//   reports `syncPending = false, syncError = nil` for ordinary saves. A
//   sync-true REQUEST is refused upstream BEFORE any secret/DB effect, so no
//   phantom unsupported error rides on a save that never asked for sync and
//   cross-device success is never claimed.

import Foundation
import GRDB
import FloeCore
import FloePersistence

// MARK: - Commit fault points (test/qualification seams only)

public enum ProviderCommitFaultPoint: Sendable, Equatable {
    /// Throw BEFORE opening the original bundle transaction: proves the
    /// documented orphan state (secret already committed upstream by the
    /// runner's phase order, zero DB rows) with real durable stores.
    case beforeBundle
    /// Throw AFTER the original bundle transaction committed but BEFORE the
    /// result is returned: proves the runner's `localCommit` classification
    /// against an actually-committed DB state. Production never uses this.
    case afterBundleCommitted
}

// MARK: - ModelConfigurationCommitter

public actor ModelConfigurationCommitter: ProviderBundleCommitting {
    private let database: DatabaseManager
    private let store: ModelConfigurationStore
    private let presetSidecar: ProviderPresetSidecar
    /// Internal, qualification-only fault seam (never reachable from the
    /// public initializer and never a production path).
    private let faultPoint: ProviderCommitFaultPoint?

    public init(database: DatabaseManager) {
        self.database = database
        self.store = ModelConfigurationStore(database: database)
        self.presetSidecar = ProviderPresetSidecar(database: database)
        self.faultPoint = nil
    }

    init(database: DatabaseManager, faultPoint: ProviderCommitFaultPoint?) {
        self.database = database
        self.store = ModelConfigurationStore(database: database)
        self.presetSidecar = ProviderPresetSidecar(database: database)
        self.faultPoint = faultPoint
    }

    // MARK: Last bundle bookkeeping (read by the facade after a run)

    /// The ORIGINAL store's full bundle result for the most recent commit of
    /// one provider (canonical saved rows + deleted/disabled stale split)
    /// plus the MC-R1 durable revision outcome. The frozen
    /// `ProviderBundleCommitResult` cannot carry the disabled/deleted split,
    /// so the facade reads it here instead of inventing a second DTO. The
    /// ORIGINAL runner's per-provider single-flight (ProviderSaveRunner.swift
    /// :390-395) plus the facade's lease gate guarantee at most one live
    /// commit per provider id.
    public struct BundleRecord: Sendable, Equatable {
        public let canonicalSaved: [ModelProfile]
        public let deletedModelIDs: [UUID]
        public let disabledModelIDs: [UUID]
        /// Set true once `verifyProviderPersisted` accepted the state.
        public var readbackVerified: Bool
        /// MC-R1: the revision ACTUALLY persisted by the same-writer CAS
        /// (base + 1). Recorded BEFORE the post-commit fault seam so partial
        /// failure states can report the durable truth.
        public let persistedSyncRevision: Int64
        /// MC-R1 fix: false when the bundle transaction committed but the
        /// preset sidecar write failed (honest partial state; never relabels
        /// the commit as a rollback).
        public var presetSidecarRecorded: Bool

        init(_ result: ModelConfigurationStore.ProviderBundleResult,
             persistedSyncRevision: Int64) {
            self.canonicalSaved = result.saved
            self.deletedModelIDs = result.deletedModelIDs
            self.disabledModelIDs = result.disabledModelIDs
            self.readbackVerified = false
            self.persistedSyncRevision = persistedSyncRevision
            self.presetSidecarRecorded = false
        }
    }

    private var lastBundleRecords: [UUID: BundleRecord] = [:]
    /// MC-R1: providers whose LAST bundle transaction ACTUALLY committed
    /// (stage evidence for truthful `databaseRowWritten` on post-commit
    /// failures). Consumed exactly once per run by the executor.
    private var committedStages: Set<UUID> = []
    /// Providers whose LAST gated write was refused by the durable
    /// same-writer CAS (nothing was mutated). Consumed exactly once.
    private var revisionConflicts: [UUID: ModelConfigurationRevisionConflict] = [:]
    /// MC-R1: the pre-effect expectation staged by the executor's prepare
    /// (which actually observed the row). The store distinguishes create
    /// ("row must STILL be absent") from edit ("row at exactly base") so the
    /// revision-0 dual meaning (original initial value vs absent marker) can
    /// never conflate a racing creator with a first edit. When NO
    /// expectation is staged (direct/legacy callers) the committer derives
    /// `.editAtRevision(base)` — a create through that path simply conflicts
    /// (fail-closed), never silently overwrites an absent-row expectation.
    enum NextBundleExpectation: Sendable, Equatable {
        case createExpectedAbsent
        case editAtRevision(Int64)
    }
    private var nextBundleExpectations: [UUID: NextBundleExpectation] = [:]

    func stageNextBundleExpectation(providerID: UUID,
                                    expectation: NextBundleExpectation) {
        nextBundleExpectations[providerID] = expectation
    }

    func clearNextBundleExpectation(providerID: UUID) {
        nextBundleExpectations[providerID] = nil
    }

    public func bundleRecord(providerID: UUID) -> BundleRecord? {
        lastBundleRecords[providerID]
    }

    func clearBundleRecord(providerID: UUID) {
        lastBundleRecords[providerID] = nil
    }

    /// Read + clear: did the last chain for this provider reach the durable
    /// bundle commit stage (transaction accepted)?
    func consumeCommittedStage(providerID: UUID) -> Bool {
        committedStages.remove(providerID) != nil
    }

    /// Read + clear: the typed durable CAS rejection of the last chain (if
    /// any). Lets the executor report `staleRevision` honestly instead of a
    /// generic localCommit, while the partial-commit facts stay available.
    func consumeRevisionConflict(providerID: UUID) -> ModelConfigurationRevisionConflict? {
        revisionConflicts.removeValue(forKey: providerID)
    }

    // MARK: ProviderBundleCommitting

    /// Applies provider + models through the ORIGINAL one-SQLite-transaction
    /// bundle save — now gated by the Main-settled same-writer CAS
    /// (`expectedSyncRevision` = the observed base the frozen draft/runner
    /// chain carries) — then records the narrow preset identity sidecar
    /// (fixed whitelisted key; ConfigSettingsKeys.providerPresetIDs
    /// provenance). Never throws for a "sync" reason: Android local commits
    /// always report `syncPending = false / syncError = nil`.
    public func commitProviderBundle(_ request: ProviderSaveRequest) async throws
        -> ProviderBundleCommitResult
    {
        if faultPoint == .beforeBundle {
            throw FloeError.storageCorrupted("injected pre-bundle fault")
        }
        // MC-R1: resolve the durable expected state. The staged expectation
        // comes from the executor's PREPARE read (under the held ownership
        // gate); without one we derive the edit form (fail-closed for
        // creates). Overflow refuses with a typed error BEFORE opening the
        // transaction (the store mirror re-checks inside the transaction as
        // defense in depth; neither path can wrap).
        let base = request.profile.syncRevision
        let expectation = nextBundleExpectations.removeValue(forKey: request.profile.id)
            ?? .editAtRevision(base)
        let storeState: ModelConfigurationStore.ProviderBundleExpectedState
        let advanced: Int64
        switch expectation {
        case .createExpectedAbsent:
            storeState = .absent
            advanced = 1
        case .editAtRevision(let observedBase):
            guard observedBase == base else {
                // The staged base must be the value the frozen draft actually
                // carries; a divergence means the observation and the write
                // disagree and NOTHING may proceed.
                throw ConfigDomainError(code: .staleRevision,
                                       reason: "providerExpectationDivergence")
            }
            guard ConfigProviderRevisionRules.advanced(fromBase: base) != nil else {
                throw ConfigDomainError(code: .staleRevision,
                                        reason: "providerRevisionExhausted")
            }
            storeState = .revision(base)
            advanced = base + 1
        }
        let result: ModelConfigurationStore.ProviderBundleResult
        do {
            result = try await store.saveProviderBundle(
                provider: request.profile,
                models: request.selectedModels,
                managedCapabilities: request.managedCapabilities,
                expectedState: storeState
            )
        } catch let conflict as ModelConfigurationRevisionConflict {
            // Nothing was mutated (single transaction, preflight + in-tx
            // gate before any write). Record the typed refusal; the executor
            // maps it to `staleRevision` and reports the secret-side truth
            // from its own physical assessment.
            revisionConflicts[request.profile.id] = conflict
            throw conflict
        }
        lastBundleRecords[request.profile.id] = BundleRecord(
            result, persistedSyncRevision: advanced)
        committedStages.insert(request.profile.id)
        if faultPoint == .afterBundleCommitted {
            throw FloeError.storageCorrupted("injected post-commit fault")
        }
        // Sidecar failure policy (MC-R1 fix): the bundle is already durable.
        // A sidecar write failure must NOT be reported through the runner as
        // a bundle/localCommit failure (that would falsely imply the row
        // rolled back); it is recorded honestly on the committed reply and
        // converges on the next save (the record is idempotent).
        do {
            try await presetSidecar.record(presetID: request.profile.presetID,
                                           for: request.profile.id)
            if var record = lastBundleRecords[request.profile.id] {
                record.presetSidecarRecorded = true
                lastBundleRecords[request.profile.id] = record
            }
        } catch {
            if var record = lastBundleRecords[request.profile.id] {
                record.presetSidecarRecorded = false
                lastBundleRecords[request.profile.id] = record
            }
        }
        return ProviderBundleCommitResult(
            saved: result.saved,
            syncPending: false,
            syncError: nil
        )
    }

    /// Re-reads the provider and the selected models through the ORIGINAL
    /// store decoding and returns a secret-free mismatch reason, or nil when
    /// the persisted bytes match the frozen request. Only the persisted
    /// SecretReference IDENTITY participates (the same codec columns
    /// secret_ref_account/secret_ref_synchronizable,
    /// ModelConfigurationStore.swift:432-436,:488-489); no secret body is
    /// ever read here. MC-R1: the provider revision must be EXACTLY the
    /// advanced persisted value (base+1), never the frozen base.
    public func verifyProviderPersisted(_ request: ProviderSaveRequest) async -> String? {
        let provider: ProviderProfile?
        let persistedModels: [ModelProfile]
        do {
            provider = try await store.provider(id: request.profile.id)
            persistedModels = try await store.models(providerID: request.profile.id)
        } catch {
            return "readbackQueryFailed"
        }
        guard let provider else {
            return "providerRowMissing"
        }
        if let reason = Self.providerMismatch(request.profile, provider) {
            return reason
        }
        var persistedByRemoteID = [String: ModelProfile]()
        for model in persistedModels {
            persistedByRemoteID[model.remoteModelID] = model
        }
        for selected in request.selectedModels {
            guard let persisted = persistedByRemoteID[selected.remoteModelID] else {
                return "modelRowMissing.\(Self.safeModelLabel(selected))"
            }
            if let reason = Self.modelMismatch(selected, persisted) {
                return "\(reason).\(Self.safeModelLabel(selected))"
            }
        }
        if var record = lastBundleRecords[request.profile.id] {
            record.readbackVerified = true
            lastBundleRecords[request.profile.id] = record
        }
        return nil
    }

    // MARK: Field-wise comparison (secret-free, deterministic)

    private static func providerMismatch(_ frozen: ProviderProfile,
                                         _ persisted: ProviderProfile) -> String? {
        guard frozen.id == persisted.id else { return "providerIDMismatch" }
        guard frozen.kind == persisted.kind else { return "providerKindMismatch" }
        guard frozen.wireProtocol == persisted.wireProtocol else { return "providerProtocolMismatch" }
        guard frozen.baseURL.absoluteString == persisted.baseURL.absoluteString else {
            return "providerBaseURLMismatch"
        }
        guard frozen.displayName == persisted.displayName else { return "providerNameMismatch" }
        guard frozen.region == persisted.region else { return "providerRegionMismatch" }
        guard frozen.nonSecretHeaders == persisted.nonSecretHeaders else {
            return "providerHeadersMismatch"
        }
        guard frozen.isEnabled == persisted.isEnabled else { return "providerEnabledMismatch" }
        guard frozen.allowsPlainHTTP == persisted.allowsPlainHTTP else {
            return "providerPlainHTTPMismatch"
        }
        guard frozen.toolNameCompatibility == persisted.toolNameCompatibility else {
            return "providerToolNameCompatMismatch"
        }
        // MC-R1: the gated write ADVANCES the persisted revision; the only
        // honest match is EXACTLY base+1 (never the frozen base, never a
        // larger jump — a jump would mean an editor landed in between and
        // the durable CAS should have refused it).
        guard ConfigProviderRevisionRules.readbackMatches(base: frozen.syncRevision,
                                                          persisted: persisted.syncRevision)
        else { return "providerRevisionMismatch" }
        switch (frozen.secretRef, persisted.secretRef) {
        case (nil, nil):
            break
        case let (frozenRef?, persistedRef?):
            guard frozenRef.keychainAccount == persistedRef.keychainAccount else {
                return "providerSecretAccountMismatch"
            }
            guard frozenRef.synchronizable == persistedRef.synchronizable else {
                return "providerSyncFlagMismatch"
            }
        default:
            return "providerSecretPresenceMismatch"
        }
        return nil
    }

    private static func modelMismatch(_ frozen: ModelProfile,
                                      _ persisted: ModelProfile) -> String? {
        guard frozen.id == persisted.id else { return "modelIDMismatch" }
        guard frozen.providerID == persisted.providerID else { return "modelProviderMismatch" }
        guard frozen.remoteModelID == persisted.remoteModelID else { return "modelRemoteIDMismatch" }
        guard frozen.displayName == persisted.displayName else { return "modelNameMismatch" }
        guard frozen.limits == persisted.limits else { return "modelLimitsMismatch" }
        guard frozen.pricing == persisted.pricing else { return "modelPricingMismatch" }
        guard frozen.capabilities == persisted.capabilities else { return "modelCapabilitiesMismatch" }
        // explicitCapabilities COALESCE semantics (reproduced faithfully):
        // a frozen nil means "no provenance change" — the ORIGINAL write
        // keeps the existing mask (ModelConfigurationStore.swift:539-541/
        // :550-552), so readback can only assert equality when the frozen
        // value carries an explicit mask; nil is "whatever was persisted",
        // never a mismatch invention and never a silent clear.
        if let frozenExplicit = frozen.explicitCapabilities,
           frozenExplicit != persisted.explicitCapabilities {
            return "modelExplicitCapabilitiesMismatch"
        }
        guard frozen.useSurfaces == persisted.useSurfaces else { return "modelUseSurfacesMismatch" }
        guard frozen.reasoningEffort == persisted.reasoningEffort else { return "modelReasoningMismatch" }
        guard frozen.isEnabled == persisted.isEnabled else { return "modelEnabledMismatch" }
        guard (frozen.isHiddenFromPrimaryPicker ?? false)
                == (persisted.isHiddenFromPrimaryPicker ?? false) else {
            return "modelHiddenFlagMismatch"
        }
        return nil
    }

    /// Model labels in diagnostics carry only the remote id when it is
    /// plain-ASCII bounded; otherwise an opaque constant (never content).
    static func safeModelLabel(_ model: ModelProfile) -> String {
        let candidate = model.remoteModelID
        let isPlain = candidate.utf8.count <= 64
            && candidate.unicodeScalars.allSatisfy { $0.isASCII && !$0.properties.isWhitespace }
        return isPlain ? candidate : "model"
    }
}

// MARK: - Preset identity sidecar (fixed whitelist key)

/// Stores `provider.<uuid>` → presetID inside the ONE existing schema-46
/// `app_settings` table under the single whitelisted key
/// `ConfigSettingsKeys.providerPresetIDs`. The statements MIRROR the exact
/// original SettingsStore single-key upsert/read (FloePersistence
/// SettingsStore.swift:52-60/:64-73) — same columns, same ISO-8601
/// fractional-seconds timestamp form (PersistenceCodec, reproduced narrowly
/// like the accepted sibling adapter at RuntimeFacadeSettingsDefaults.swift
/// :486-495). NO schema change, NO second database, NO arbitrary-key API:
/// this type only touches its one fixed key, and only with provider UUID →
/// bounded preset id strings.
///
/// MC-R2 discipline applied (justified defect, same class as the ledger):
/// a PRESENT-but-corrupt map is preserved byte-for-byte — record/remove
/// REFUSE to rewrite corrupt bytes instead of silently persisting a filtered
/// view. Reads stay tolerant (this is a display/filter hint, not a recovery
/// intent, so catalog search must keep serving), but no destructive rewrite
/// can happen while corruption stands.
public actor ProviderPresetSidecar {
    static let key = ConfigSettingsKeys.providerPresetIDs
    /// Schema bound: 256 provider UUIDs × (36 + 64 + separators) < 32 KiB.
    static let maximumJSONBytes = 32_768

    private let database: DatabaseManager

    init(database: DatabaseManager) {
        self.database = database
    }

    /// Idempotent record. A nil presetID removes an existing entry (an edit
    /// that deliberately cleared the preset selection); a missing entry with
    /// a nil presetID is a no-op. Read-modify-write happens inside ONE
    /// original writer transaction, so back-to-back saves cannot lose an
    /// entry to interleaving. Corruption ⇒ refuse (bytes preserved).
    func record(presetID: String?, for providerID: UUID) async throws {
        let key = Self.key
        let id = providerID.uuidString
        try await database.writer { db in
            switch try Self.readStatus(db, key: key) {
            case .corrupt:
                throw ConfigDomainError(code: .persistenceUnavailable,
                                        reason: "presetSidecarCorrupt")
            case .absent:
                if let presetID {
                    try Self.write(db, key: key, map: [id: presetID])
                }
            case .valid(var map):
                if let presetID {
                    if map[id] == presetID { return }
                    map[id] = presetID
                } else {
                    guard map.removeValue(forKey: id) != nil else { return }
                }
                try Self.write(db, key: key, map: map)
            }
        }
    }

    func remove(providerID: UUID) async throws {
        let key = Self.key
        let id = providerID.uuidString
        try await database.writer { db in
            switch try Self.readStatus(db, key: key) {
            case .corrupt:
                throw ConfigDomainError(code: .persistenceUnavailable,
                                        reason: "presetSidecarCorrupt")
            case .absent:
                return
            case .valid(var map):
                guard map.removeValue(forKey: id) != nil else { return }
                try Self.write(db, key: key, map: map)
            }
        }
    }

    /// The CURRENT configured preset ids joined against LIVE provider rows
    /// inside ONE original reader transaction: an entry whose provider row
    /// no longer exists is stale (the delete flow removes it; this filter
    /// guarantees a dangling entry can never mark a catalog entry
    /// "configured" during an interrupted cleanup). Corrupt bytes degrade to
    /// "no configured ids" for READS only (never a rewrite).
    func configuredPresetIDs() async throws -> Set<String> {
        let key = Self.key
        return try await database.reader { db in
            let raw = try Row.fetchOne(
                db,
                sql: "SELECT value_json FROM app_settings WHERE key = ?",
                arguments: [key]
            )
            let map = Self.decodeMap(raw?["value_json"] as String?)
            guard !map.isEmpty else { return [] }
            var live: Set<String> = []
            for providerID in map.keys {
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM providers WHERE id = ?)",
                    arguments: [providerID]
                ) ?? false
                if exists, let preset = map[providerID] {
                    live.insert(preset)
                }
            }
            return live
        }
    }

    /// The CURRENT provider -> preset map joined against LIVE provider rows
    /// inside ONE original reader transaction (the same stale-entry filter as
    /// `configuredPresetIDs`). This sidecar is the PERSISTED source of a
    /// provider's catalog preset identity: the `providers` table has no
    /// preset column, and the ORIGINAL save records the frozen request's
    /// `profile.presetID` here. Corrupt bytes degrade to "no presets" for
    /// READS only (never a rewrite).
    func presetIDsByProvider() async throws -> [UUID: String] {
        let key = Self.key
        return try await database.reader { db in
            let raw = try Row.fetchOne(
                db,
                sql: "SELECT value_json FROM app_settings WHERE key = ?",
                arguments: [key]
            )
            let map = Self.decodeMap(raw?["value_json"] as String?)
            guard !map.isEmpty else { return [:] }
            var live: [UUID: String] = [:]
            for (providerID, preset) in map {
                guard let id = UUID(uuidString: providerID) else { continue }
                let exists = try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM providers WHERE id = ?)",
                    arguments: [providerID]
                ) ?? false
                if exists { live[id] = preset }
            }
            return live
        }
    }

    private enum SidecarStatus {
        case absent
        case valid([String: String])
        case corrupt
    }

    private static func readStatus(_ db: Database, key: String) throws -> SidecarStatus {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT value_json FROM app_settings WHERE key = ?",
            arguments: [key]
        ) else { return .absent }
        let text: String? = row["value_json"]
        guard let text else { return .corrupt }
        guard text.utf8.count <= maximumJSONBytes else { return .corrupt }
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .corrupt }
        var map: [String: String] = [:]
        for (providerID, value) in object {
            // STRICT for the write path: a map we CANNOT faithfully rewrite
            // must be preserved, so any malformed element marks the whole
            // value corrupt (MC-R2 discipline).
            guard let preset = value as? String,
                  UUID(uuidString: providerID) != nil,
                  preset.utf8.count <= 64 else {
                return .corrupt
            }
            map[providerID] = preset
        }
        return .valid(map)
    }

    /// Tolerant read for catalog projection only (never feeds a rewrite).
    private static func decodeMap(_ text: String?) -> [String: String] {
        guard let text, let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        var map: [String: String] = [:]
        for (providerID, value) in object {
            guard let preset = value as? String,
                  UUID(uuidString: providerID) != nil,
                  preset.utf8.count <= 64 else { continue }
            map[providerID] = preset
        }
        return map
    }

    /// Mirrors SettingsStore.swift:64-73 (INSERT ... ON CONFLICT(key) DO
    /// UPDATE value_json + updated_at) for the ONE fixed key.
    private static func write(_ db: Database, key: String, map: [String: String]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(decoding: try encoder.encode(map), as: UTF8.self)
        guard json.utf8.count <= maximumJSONBytes else {
            throw ConfigDomainError(code: .persistenceUnavailable,
                                    reason: "presetSidecarSaturated")
        }
        try db.execute(
            sql: """
                INSERT INTO app_settings (key, value_json, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(key) DO UPDATE SET
                    value_json = excluded.value_json,
                    updated_at = excluded.updated_at
                """,
            arguments: [key, json, Self.timestamp(Date())]
        )
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}