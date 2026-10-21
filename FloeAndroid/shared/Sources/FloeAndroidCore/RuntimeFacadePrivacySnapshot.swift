// SPDX-License-Identifier: MPL-2.0
//
// RuntimeFacadePrivacySnapshot — exact identity/state snapshot engine and
// bounded, verified clear-target spool for the G02 privacy commands.
//
// Contract authority: settings-domain-main-acceptance-20261019/input-final/
// contract.json — digestEncoding (floe.canonical-digest.v1),
// wireConventions.digestDomains (floe.privacy-history.v3 /
// floe.privacy-modelconfig.v3), commandTable[24..26], plus Main's
// MAIN_PRIVACY_REPORT_STREAMING_DECISION_20261019 required repairs:
//
//   * ONE original-DB reader transaction per attempt. Every set is walked
//     with a bounded KEYSET page (ORDER BY raw id, `id > ?`, LIMIT). No
//     `Row.fetchAll`, no full row inventory, no permanent history cap, and
//     no COUNT/MAX aggregate anywhere in the identity stream.
//   * The digest is accumulated through the ONE canonical encoder
//     (`SettingsDomainV1.CanonicalDigest.record`) with an incremental
//     SHA-256 sink; `finalize()` is byte-identical to `token(domain:
//     records:)` for the same ordered records.
//   * g1 in-memory grant snapshot -> the DB reader transaction -> g2; the
//     canonical grant streams must be equal or the WHOLE snapshot retries
//     (bounded 3) and then fails typed `unstableGrantSnapshot` with nothing
//     deleted.
//   * privacy.summary.get captures NO deletion targets. Clear captures the
//     exact enumerated target into a root-owned STAGED/VERIFIED spool
//     (section files + manifest with byte/length/SHA-256 evidence), never a
//     second business database and never an unbounded in-RAM inventory.
//   * A failed/cancelled capture removes its staged directory; a process
//     death can only leave an orphan spool, which the next clear removes
//     (an orphan can never be replayed as a successful clear).
import Foundation
import GRDB
import Crypto
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeAgentRuntime

// MARK: - Root identity token (never the raw path on the wire)

public enum PrivacyRootIdentity {
    /// Stable opaque token for the exact normalized app-private root. Used
    /// to bind a trusted confirmation to one root without exposing a path.
    public static func token(rootPath: String) -> String {
        let standardized = URL(fileURLWithPath: rootPath).standardizedFileURL.path
        let digest = SHA256.hash(data: Data(standardized.utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Capture results

public struct PrivacyProviderSecretReference: Sendable, Equatable {
    public var account: String
    public var synchronizable: Bool

    public init(account: String, synchronizable: Bool) {
        self.account = account
        self.synchronizable = synchronizable
    }
}

public struct PrivacyHistorySnapshotCapture: Sendable {
    /// `sha256:<hex>` floe.privacy-history.v3 (computed over g2, equal to g1).
    public var digest: String
    public var conversationCount: Int
    public var runCount: Int
    public var persistedGrantCount: Int
    public var inMemoryGrantCount: Int
    /// Exact root-owned target spool for a CLEAR capture; nil for a summary
    /// capture (no deletion target is ever materialized for a read).
    public var spool: PrivacyClearSpoolDescriptor?
    /// Bracket truth carried into the reply: 1 on first-attempt success.
    public var attemptsUsed: Int

    public init(digest: String, conversationCount: Int, runCount: Int,
                persistedGrantCount: Int, inMemoryGrantCount: Int,
                spool: PrivacyClearSpoolDescriptor?, attemptsUsed: Int) {
        self.digest = digest
        self.conversationCount = conversationCount
        self.runCount = runCount
        self.persistedGrantCount = persistedGrantCount
        self.inMemoryGrantCount = inMemoryGrantCount
        self.spool = spool
        self.attemptsUsed = attemptsUsed
    }
}

public struct PrivacyModelConfigSnapshotCapture: Sendable {
    /// `sha256:<hex>` floe.privacy-modelconfig.v3.
    public var digest: String
    public var providerCount: Int
    public var modelCount: Int
    public var secretReferenceCount: Int
    public var preferencesSyncRevision: Int
    /// The snapshot-observed preferences singleton record (declared column
    /// order) used by the reset's same-writer expected-state CAS; nil when
    /// no singleton exists.
    public var preferencesRecord: [SettingsDomainV1.CanonicalDigest.Field]?
    /// Exact root-owned target spool for a CLEAR capture; nil for summary.
    public var spool: PrivacyClearSpoolDescriptor?

    public init(digest: String, providerCount: Int, modelCount: Int,
                secretReferenceCount: Int, preferencesSyncRevision: Int,
                preferencesRecord: [SettingsDomainV1.CanonicalDigest.Field]?,
                spool: PrivacyClearSpoolDescriptor?) {
        self.digest = digest
        self.providerCount = providerCount
        self.modelCount = modelCount
        self.secretReferenceCount = secretReferenceCount
        self.preferencesSyncRevision = preferencesSyncRevision
        self.preferencesRecord = preferencesRecord
        self.spool = spool
    }
}

// MARK: - Section row carriers (bounded page size)

private struct ConversationStreamRow: Sendable {
    let fields: [SettingsDomainV1.CanonicalDigest.Field]
    let id: UUID
}

private struct RunStreamRow: Sendable {
    let fields: [SettingsDomainV1.CanonicalDigest.Field]
    let id: UUID
    let conversationID: UUID
}

private struct PersistedGrantStreamRow: Sendable {
    let fields: [SettingsDomainV1.CanonicalDigest.Field]
    let id: UUID
}

private struct ProviderStreamRow: Sendable {
    let fields: [SettingsDomainV1.CanonicalDigest.Field]
    let id: UUID
    let secret: PrivacyProviderSecretReference?
    let syncRevision: Int64
}

private struct ModelStreamRow: Sendable {
    let fields: [SettingsDomainV1.CanonicalDigest.Field]
    let id: UUID
    let providerID: UUID
}

// MARK: - Snapshot engine

public actor PrivacySnapshotEngine {
    /// Bounded bracket retries per the frozen contract.
    public static let maximumBracketAttempts = 3
    /// Bounded keyset page. A larger history only means more pages, never a
    /// permanent row cap and never an unbounded materialized array.
    static let pageSize = 256

    /// Declared column order of the model_preferences row used by the
    /// canonical digest AND by the reset's same-writer expected-state CAS.
    static let preferenceColumns: [String] = [
        "id", "onboarding_status", "default_agent_model_id",
        "general_auxiliary_llm_model_id", "canvas_agent_model_id",
        "vision_model_id", "canvas_vision_model_id", "approval_model_id",
        "package_review_model_id", "autonomous_image_routing",
        "auxiliary_image_mode", "shared_image_model_id",
        "image_generation_model_id", "image_editing_model_id",
        "default_video_model_id", "updated_at", "sync_revision",
    ]

    private let database: DatabaseManager
    private let inMemoryGrants: any PrivacyInMemoryGrantStore
    private let rootPath: String
    private let epoch: UInt64

    public init(database: DatabaseManager,
                inMemoryGrants: any PrivacyInMemoryGrantStore,
                rootPath: String, epoch: UInt64) {
        self.database = database
        self.inMemoryGrants = inMemoryGrants
        self.rootPath = rootPath
        self.epoch = epoch
    }

    // MARK: Raw DatabaseValue access (storage-class exact, no CAST)

    private nonisolated static func value(_ row: Row, _ name: String) throws
        -> DatabaseValue
    {
        // Pinned-GRDB API repair (2026-10-21): the old
        // `databaseValue(atIndex:)` no longer exists; `hasColumn` +
        // DatabaseValue subscript give the same storage-class-exact value.
        guard row.hasColumn(name) else {
            throw PrivacyDomainError.persistenceUnavailable("columnMissing:\(name)")
        }
        return row[name] as DatabaseValue
    }

    private nonisolated static func field(_ value: DatabaseValue)
        -> SettingsDomainV1.CanonicalDigest.Field
    {
        switch value.storage {
        case .null: return .null
        case .int64(let value): return .integer(value)
        case .double(let value): return .real(value)
        case .string(let value): return .text(value)
        case .blob(let value): return .blob(value)
        }
    }

    private nonisolated static func uuid(_ value: DatabaseValue) throws -> UUID {
        guard case .string(let raw) = value.storage,
              let id = UUID(uuidString: raw) else {
            throw PrivacyDomainError.persistenceUnavailable("identityCorrupt")
        }
        return id
    }

    nonisolated static func iso8601Fractional(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    // MARK: In-memory grant records (floe.privacy-history.v3 subset)

    /// [id, tool_name, host_id, single_use, toolAuthorizationIdentity,
    ///  decided_at, expires_at, policyName, pathCount, paths…]
    private nonisolated static func inMemoryGrantRecord(_ grant: ApprovalGrant)
        -> [SettingsDomainV1.CanonicalDigest.Field]
    {
        var fields: [SettingsDomainV1.CanonicalDigest.Field] = []
        fields.reserveCapacity(9 + grant.scope.paths.count)
        fields.append(.text(grant.id.uuidString))
        fields.append(.text(grant.scope.toolName))
        if let hostID = grant.scope.hostID {
            fields.append(.text(hostID.uuidString))
        } else {
            fields.append(.null)
        }
        fields.append(.integer(grant.scope.singleUse ? 1 : 0))
        if let identity = grant.scope.toolAuthorizationIdentity {
            fields.append(.text(identity))
        } else {
            fields.append(.null)
        }
        fields.append(.text(iso8601Fractional(grant.decidedAt)))
        if let expiresAt = grant.expiresAt {
            fields.append(.text(iso8601Fractional(expiresAt)))
        } else {
            fields.append(.null)
        }
        fields.append(.text(grant.policyName))
        fields.append(.integer(Int64(grant.scope.paths.count)))
        for path in grant.scope.paths {
            fields.append(.text(path))
        }
        return fields
    }

    private nonisolated static func sortedGrants(_ grants: [ApprovalGrant])
        -> [ApprovalGrant]
    {
        grants.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    private nonisolated static func grantStreamToken(_ grants: [ApprovalGrant])
        -> String
    {
        var hasher = SettingsDomainV1.CanonicalDigest.IncrementalToken(
            domain: SettingsDomainV1.CanonicalDigest.domainPrivacyHistory)
        for grant in sortedGrants(grants) {
            hasher.append(inMemoryGrantRecord(grant))
        }
        return hasher.finalize()
    }

    // MARK: privacy.history.v3 capture

    /// ONE reader transaction per attempt computes the digest, the display
    /// counts and (only for a clear) the exact target spool, bracketed by
    /// g1/g2 in-memory grant snapshots.
    public func captureHistory(
        captureTargets: Bool = false,
        operationID: UUID = UUID(),
        maxAttempts: Int = PrivacySnapshotEngine.maximumBracketAttempts
    ) async throws -> PrivacyHistorySnapshotCapture {
        for attempt in 1...max(1, maxAttempts) {
            let g1 = try await inMemoryGrants.snapshotGrants()
            let writer: PrivacyClearSpoolWriter?
            if captureTargets {
                writer = try PrivacyClearSpoolWriter(
                    rootPath: rootPath, epoch: epoch,
                    operationID: operationID,
                    digestPlaceholder: "sha256:" + String(repeating: "0", count: 64))
            } else {
                writer = nil
            }
            do {
                let dbPart: HistoryDBPart = try await database.reader { db in
                    var hasher = SettingsDomainV1.CanonicalDigest.IncrementalToken(
                        domain: SettingsDomainV1.CanonicalDigest.domainPrivacyHistory)
                    var conversations = 0
                    var runs = 0
                    var grants = 0
                    var conversationCursor: String?
                    while true {
                        let page = try Self.conversationPage(db,
                                                             after: conversationCursor,
                                                             limit: Self.pageSize)
                        for row in page {
                            hasher.append(row.fields)
                            writer?.appendConversation(id: row.id)
                            conversations += 1
                        }
                        guard page.count == Self.pageSize else { break }
                        conversationCursor = page.last?.id.uuidString
                    }
                    var runCursor: String?
                    while true {
                        let page = try Self.runPage(db, after: runCursor,
                                                    limit: Self.pageSize)
                        for row in page {
                            hasher.append(row.fields)
                            writer?.appendRun(id: row.id,
                                              conversationID: row.conversationID)
                            runs += 1
                        }
                        guard page.count == Self.pageSize else { break }
                        runCursor = page.last?.id.uuidString
                    }
                    var grantCursor: String?
                    while true {
                        let page = try Self.persistedGrantPage(
                            db, after: grantCursor, limit: Self.pageSize)
                        for row in page {
                            hasher.append(row.fields)
                            writer?.appendPersistedGrant(id: row.id)
                            grants += 1
                        }
                        guard page.count == Self.pageSize else { break }
                        grantCursor = page.last?.id.uuidString
                    }
                    return HistoryDBPart(hasher: hasher,
                                         conversations: conversations,
                                         runs: runs,
                                         persistedGrants: grants)
                }

                let g2 = try await inMemoryGrants.snapshotGrants()
                // Canonical bracket: the in-memory grant set must be stable
                // across the reader transaction. Equal-size replacement is
                // caught because the stream binds ids + full state.
                guard Self.grantStreamToken(g1) == Self.grantStreamToken(g2) else {
                    writer?.abort()
                    continue
                }
                let sorted = Self.sortedGrants(g2)
                var hasher = dbPart.hasher
                for grant in sorted {
                    hasher.append(Self.inMemoryGrantRecord(grant))
                    writer?.appendInMemoryGrant(id: grant.id)
                }
                let digest = hasher.finalize()
                let spool: PrivacyClearSpoolDescriptor?
                if let writer {
                    spool = try writer.finalize(digest: digest)
                } else {
                    spool = nil
                }
                return PrivacyHistorySnapshotCapture(
                    digest: digest,
                    conversationCount: dbPart.conversations,
                    runCount: dbPart.runs,
                    persistedGrantCount: dbPart.persistedGrants,
                    inMemoryGrantCount: sorted.count,
                    spool: spool,
                    attemptsUsed: attempt)
            } catch {
                writer?.abort()
                throw error
            }
        }
        throw PrivacyDomainError.persistenceUnavailable("unstableGrantSnapshot")
    }

    private struct HistoryDBPart: Sendable {
        var hasher: SettingsDomainV1.CanonicalDigest.IncrementalToken
        var conversations: Int
        var runs: Int
        var persistedGrants: Int
    }

    // MARK: floe.privacy-modelconfig.v3 capture

    /// ONE reader transaction per capture computes the model-config digest,
    /// the display counts and (only for a clear) the exact provider/model
    /// target spool. Secret VALUES never appear: only the opaque provider
    /// secret reference and its synchronizable flag.
    public func captureModelConfiguration(
        captureTargets: Bool = false,
        operationID: UUID = UUID()
    ) async throws -> PrivacyModelConfigSnapshotCapture {
        let writer: PrivacyClearSpoolWriter?
        if captureTargets {
            writer = try PrivacyClearSpoolWriter(
                rootPath: rootPath, epoch: epoch,
                operationID: operationID,
                digestPlaceholder: "sha256:" + String(repeating: "0", count: 64))
        } else {
            writer = nil
        }
        do {
            let part: ModelConfigDBPart = try await database.reader { db in
                var hasher = SettingsDomainV1.CanonicalDigest.IncrementalToken(
                    domain: SettingsDomainV1.CanonicalDigest.domainPrivacyModelConfiguration)
                var providers = 0
                var models = 0
                var secrets = 0
                var providerCursor: String?
                while true {
                    let page = try Self.providerPage(db, after: providerCursor,
                                                     limit: Self.pageSize)
                    for row in page {
                        hasher.append(row.fields)
                        if let secret = row.secret {
                            writer?.appendProvider(
                                id: row.id, secret: secret,
                                syncRevision: row.syncRevision)
                            secrets += 1
                        } else {
                            writer?.appendProvider(
                                id: row.id, secret: nil,
                                syncRevision: row.syncRevision)
                        }
                        providers += 1
                    }
                    guard page.count == Self.pageSize else { break }
                    providerCursor = page.last?.id.uuidString
                }
                var modelCursor: String?
                while true {
                    let page = try Self.modelPage(db, after: modelCursor,
                                                  limit: Self.pageSize)
                    for row in page {
                        hasher.append(row.fields)
                        writer?.appendModel(id: row.id,
                                            providerID: row.providerID)
                        models += 1
                    }
                    guard page.count == Self.pageSize else { break }
                    modelCursor = page.last?.id.uuidString
                }
                let preferences = try Self.preferencesRecord(db)
                if let preferences {
                    hasher.append(preferences.fields)
                }
                return ModelConfigDBPart(
                    hasher: hasher, providers: providers, models: models,
                    secrets: secrets,
                    preferencesRevision: preferences?.syncRevision ?? 0,
                    preferencesFields: preferences?.fields)
            }
            var hasher = part.hasher
            let digest = hasher.finalize()
            let spool: PrivacyClearSpoolDescriptor?
            if let writer {
                spool = try writer.finalize(digest: digest)
            } else {
                spool = nil
            }
            return PrivacyModelConfigSnapshotCapture(
                digest: digest,
                providerCount: part.providers,
                modelCount: part.models,
                secretReferenceCount: part.secrets,
                preferencesSyncRevision: part.preferencesRevision,
                preferencesRecord: part.preferencesFields,
                spool: spool)
        } catch {
            writer?.abort()
            throw error
        }
    }

    private struct ModelConfigDBPart: Sendable {
        var hasher: SettingsDomainV1.CanonicalDigest.IncrementalToken
        var providers: Int
        var models: Int
        var secrets: Int
        var preferencesRevision: Int
        var preferencesFields: [SettingsDomainV1.CanonicalDigest.Field]?
    }

    private struct PreferencesRow: Sendable {
        var fields: [SettingsDomainV1.CanonicalDigest.Field]
        var syncRevision: Int
    }

    // MARK: - Bounded keyset pages (SQL ORDER BY supplies canonical order)

    private nonisolated static func conversationPage(
        _ db: Database, after: String?, limit: Int
    ) throws -> [ConversationStreamRow] {
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT c.id AS id, c.purpose AS purpose,
                       c.archived_at AS archived_at,
                       o.workspace_id AS workspace_id,
                       o.assigned_at AS assigned_at
                FROM conversations c
                LEFT JOIN conversation_workspace_ownership o
                  ON o.conversation_id = c.id
                WHERE c.purpose = 'ordinary' AND c.archived_at IS NULL
                  AND (? IS NULL OR c.id > ?)
                ORDER BY c.id
                LIMIT ?
                """,
            arguments: [after, after, limit])
        var rows: [ConversationStreamRow] = []
        rows.reserveCapacity(limit)
        while let row = try cursor.next() {
            let id = try uuid(try value(row, "id"))
            let fields: [SettingsDomainV1.CanonicalDigest.Field] = [
                field(try value(row, "id")),
                field(try value(row, "purpose")),
                field(try value(row, "archived_at")),
                field(try value(row, "workspace_id")),
                field(try value(row, "assigned_at")),
            ]
            rows.append(ConversationStreamRow(fields: fields, id: id))
        }
        return rows
    }

    private nonisolated static func runPage(
        _ db: Database, after: String?, limit: Int
    ) throws -> [RunStreamRow] {
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT r.id AS id, r.conversation_id AS conversation_id,
                       r.state AS state, r.started_at AS started_at,
                       r.ended_at AS ended_at
                FROM runs r
                WHERE r.conversation_id IN (
                    SELECT c.id FROM conversations c
                    WHERE c.purpose = 'ordinary' AND c.archived_at IS NULL
                )
                  AND (? IS NULL OR r.id > ?)
                ORDER BY r.id
                LIMIT ?
                """,
            arguments: [after, after, limit])
        var rows: [RunStreamRow] = []
        rows.reserveCapacity(limit)
        while let row = try cursor.next() {
            let id = try uuid(try value(row, "id"))
            let conversationID = try uuid(try value(row, "conversation_id"))
            let fields: [SettingsDomainV1.CanonicalDigest.Field] = [
                field(try value(row, "id")),
                field(try value(row, "conversation_id")),
                field(try value(row, "state")),
                field(try value(row, "started_at")),
                field(try value(row, "ended_at")),
            ]
            rows.append(RunStreamRow(fields: fields, id: id,
                                     conversationID: conversationID))
        }
        return rows
    }

    private nonisolated static func persistedGrantPage(
        _ db: Database, after: String?, limit: Int
    ) throws -> [PersistedGrantStreamRow] {
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT id, workspace_id, host_id, tool_name,
                       policy_name, single_use, decided_at,
                       expires_at, paths_json
                FROM approval_grants
                WHERE (? IS NULL OR id > ?)
                ORDER BY id
                LIMIT ?
                """,
            arguments: [after, after, limit])
        var rows: [PersistedGrantStreamRow] = []
        rows.reserveCapacity(limit)
        while let row = try cursor.next() {
            let id = try uuid(try value(row, "id"))
            let fields: [SettingsDomainV1.CanonicalDigest.Field] = [
                field(try value(row, "id")),
                field(try value(row, "workspace_id")),
                field(try value(row, "host_id")),
                field(try value(row, "tool_name")),
                field(try value(row, "policy_name")),
                field(try value(row, "single_use")),
                field(try value(row, "decided_at")),
                field(try value(row, "expires_at")),
                field(try value(row, "paths_json")),
            ]
            rows.append(PersistedGrantStreamRow(fields: fields, id: id))
        }
        return rows
    }

    private nonisolated static func providerPage(
        _ db: Database, after: String?, limit: Int
    ) throws -> [ProviderStreamRow] {
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT id, kind, wire_protocol, base_url,
                       secret_ref_account, secret_ref_synchronizable,
                       region, non_secret_headers_json, display_name,
                       is_enabled, allows_plain_http,
                       tool_name_compatibility, created_at, updated_at,
                       sync_revision
                FROM providers
                WHERE (? IS NULL OR id > ?)
                ORDER BY id
                LIMIT ?
                """,
            arguments: [after, after, limit])
        var rows: [ProviderStreamRow] = []
        rows.reserveCapacity(limit)
        while let row = try cursor.next() {
            let id = try uuid(try value(row, "id"))
            let accountValue = try value(row, "secret_ref_account")
            let secret: PrivacyProviderSecretReference?
            if case .string(let account) = accountValue.storage {
                let syncStorage = (try value(row, "secret_ref_synchronizable")).storage
                secret = PrivacyProviderSecretReference(
                    account: account,
                    synchronizable: syncStorage == .int64(1))
            } else {
                secret = nil
            }
            let revisionValue = try value(row, "sync_revision")
            let syncRevision: Int64
            if case .int64(let raw) = revisionValue.storage {
                syncRevision = raw
            } else {
                syncRevision = 0
            }
            let fields: [SettingsDomainV1.CanonicalDigest.Field] = [
                field(try value(row, "id")),
                field(try value(row, "kind")),
                field(try value(row, "wire_protocol")),
                field(try value(row, "base_url")),
                field(accountValue),
                field(try value(row, "secret_ref_synchronizable")),
                field(try value(row, "region")),
                field(try value(row, "non_secret_headers_json")),
                field(try value(row, "display_name")),
                field(try value(row, "is_enabled")),
                field(try value(row, "allows_plain_http")),
                field(try value(row, "tool_name_compatibility")),
                field(try value(row, "created_at")),
                field(try value(row, "updated_at")),
                field(revisionValue),
            ]
            rows.append(ProviderStreamRow(fields: fields, id: id, secret: secret,
                                          syncRevision: syncRevision))
        }
        return rows
    }

    private nonisolated static func modelPage(
        _ db: Database, after: String?, limit: Int
    ) throws -> [ModelStreamRow] {
        let cursor = try Row.fetchCursor(
            db,
            sql: """
                SELECT id, provider_id, remote_model_id, display_name,
                       context_tokens, max_output_tokens, pricing_json,
                       capabilities, explicit_capabilities, is_enabled,
                       reasoning_effort
                FROM models
                WHERE (? IS NULL OR id > ?)
                ORDER BY id
                LIMIT ?
                """,
            arguments: [after, after, limit])
        var rows: [ModelStreamRow] = []
        rows.reserveCapacity(limit)
        while let row = try cursor.next() {
            let id = try uuid(try value(row, "id"))
            let providerID = try uuid(try value(row, "provider_id"))
            let fields: [SettingsDomainV1.CanonicalDigest.Field] = [
                field(try value(row, "id")),
                field(try value(row, "provider_id")),
                field(try value(row, "remote_model_id")),
                field(try value(row, "display_name")),
                field(try value(row, "context_tokens")),
                field(try value(row, "max_output_tokens")),
                field(try value(row, "pricing_json")),
                field(try value(row, "capabilities")),
                field(try value(row, "explicit_capabilities")),
                field(try value(row, "is_enabled")),
                field(try value(row, "reasoning_effort")),
            ]
            rows.append(ModelStreamRow(fields: fields, id: id,
                                       providerID: providerID))
        }
        return rows
    }

    private nonisolated static func preferencesRecord(_ db: Database) throws
        -> PreferencesRow?
    {
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM model_preferences WHERE id = 'default'") else {
            return nil
        }
        var fields: [SettingsDomainV1.CanonicalDigest.Field] = []
        fields.reserveCapacity(preferenceColumns.count)
        for name in preferenceColumns {
            fields.append(field(try value(row, name)))
        }
        var revision = 0
        if case .int64(let raw) = (try value(row, "sync_revision")).storage {
            revision = Int(raw)
        }
        return PreferencesRow(fields: fields, syncRevision: revision)
    }
}

// MARK: - Root-owned staged/verified clear target spool

public struct PrivacyClearSpoolCounts: Sendable, Equatable, Codable {
    public var conversations: Int
    public var runs: Int
    public var persistedGrants: Int
    public var inMemoryGrants: Int
    public var providers: Int
    public var models: Int

    public init(conversations: Int, runs: Int, persistedGrants: Int,
                inMemoryGrants: Int, providers: Int, models: Int) {
        self.conversations = conversations
        self.runs = runs
        self.persistedGrants = persistedGrants
        self.inMemoryGrants = inMemoryGrants
        self.providers = providers
        self.models = models
    }
}

public struct PrivacyClearSpoolDescriptor: Sendable, Equatable {
    public var directoryPath: String
    public var operationID: UUID
    public var digest: String
    public var counts: PrivacyClearSpoolCounts

    public init(directoryPath: String, operationID: UUID, digest: String,
                counts: PrivacyClearSpoolCounts) {
        self.directoryPath = directoryPath
        self.operationID = operationID
        self.digest = digest
        self.counts = counts
    }
}

enum PrivacyClearSpoolLimits {
    static let schema = "floe.privacy-clear-spool/1"
    static let directoryPrefix = "clear-"
    static let writeBufferBytes = 64 * 1024
    static let readBufferBytes = 64 * 1024
    static let sections = ["conversations", "runs", "persistedGrants",
                           "inMemoryGrants", "providers", "models"]
}

struct PrivacyClearSpoolSection: Sendable, Codable, Equatable {
    var bytes: Int
    var lines: Int
    var sha256: String
}

struct PrivacyClearSpoolManifest: Sendable, Codable, Equatable {
    var schema: String
    var operationID: UUID
    var epoch: UInt64
    var root: String
    var digest: String
    var createdAt: String
    var sections: [String: PrivacyClearSpoolSection]
}

/// Synchronous, single-writer, bounded buffer. The instance is created
/// before the DB reader transaction and consumed inside its `@Sendable`
/// closure on one thread; `@unchecked Sendable` documents that exact use.
final class PrivacyClearSpoolWriter: @unchecked Sendable {
    private let directory: URL
    private let operationID: UUID
    private let epoch: UInt64
    private let root: String
    private let digestPlaceholder: String
    private var handles: [String: FileHandle] = [:]
    private var buffers: [String: Data] = [:]
    private var hashers: [String: SHA256] = [:]
    private var bytes: [String: Int] = [:]
    private var lines: [String: Int] = [:]
    private var finished = false

    init(rootPath: String, epoch: UInt64, operationID: UUID,
         digestPlaceholder: String) throws {
        self.operationID = operationID
        self.epoch = epoch
        self.root = PrivacyRootIdentity.token(rootPath: rootPath)
        self.digestPlaceholder = digestPlaceholder
        let parent = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("PrivacyClearStaging", isDirectory: true)
        let directory = parent.appendingPathComponent(
            PrivacyClearSpoolLimits.directoryPrefix + operationID.uuidString,
            isDirectory: true)
        self.directory = directory
        let fileManager = FileManager.default
        // Bounded stale cleanup: an orphan from a process death can never be
        // replayed as a success. The current operation directory is new.
        PrivacyClearSpool.removeStale(rootPath: rootPath,
                                      keeping: operationID)
        do {
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            for section in PrivacyClearSpoolLimits.sections {
                let url = directory.appendingPathComponent(section + ".staged")
                guard fileManager.createFile(
                    atPath: url.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]) else {
                    throw PrivacyDomainError.persistenceUnavailable("spoolCreate")
                }
                let handle = try FileHandle(forWritingTo: url)
                handles[section] = handle
                buffers[section] = Data()
                hashers[section] = SHA256()
                bytes[section] = 0
                lines[section] = 0
            }
        } catch {
            abort()
            throw PrivacyDomainError.persistenceUnavailable("spoolCreate")
        }
    }

    deinit {
        if !finished { abort() }
    }

    func appendConversation(id: UUID) { append("conversations", "c \(id.uuidString)") }

    func appendRun(id: UUID, conversationID: UUID) {
        append("runs", "r \(id.uuidString) \(conversationID.uuidString)")
    }

    func appendPersistedGrant(id: UUID) {
        append("persistedGrants", "p \(id.uuidString)")
    }

    func appendInMemoryGrant(id: UUID) {
        append("inMemoryGrants", "i \(id.uuidString)")
    }

    func appendProvider(id: UUID, secret: PrivacyProviderSecretReference?,
                        syncRevision: Int64) {
        let flag = secret == nil ? "0" : "1"
        let account = secret.map { Self.hex($0.account) } ?? ""
        let sync = (secret?.synchronizable ?? false) ? "1" : "0"
        // The row revision is part of the target identity: a newer Set that
        // keeps the deterministic provider.<uuid> account is still a NEW
        // secret generation and must never be raced by a stale clear.
        append("providers",
               "v \(id.uuidString) \(flag) \(sync) \(account) \(syncRevision)")
    }

    func appendModel(id: UUID, providerID: UUID) {
        append("models", "m \(id.uuidString) \(providerID.uuidString)")
    }

    private func append(_ section: String, _ line: String) {
        guard !finished, var buffer = buffers[section] else { return }
        buffer.append(contentsOf: line.utf8)
        buffer.append(0x0A)
        buffers[section] = buffer
        lines[section, default: 0] += 1
        if buffer.count >= PrivacyClearSpoolLimits.writeBufferBytes {
            flush(section)
        }
    }

    private func flush(_ section: String) {
        guard var buffer = buffers[section], !buffer.isEmpty else { return }
        guard let handle = handles[section] else { return }
        do {
            try handle.write(contentsOf: buffer)
            if var hasher = hashers[section] {
                hasher.update(data: buffer)
                hashers[section] = hasher
            }
            bytes[section, default: 0] += buffer.count
            buffer.removeAll(keepingCapacity: true)
            buffers[section] = buffer
        } catch {
            // A write failure is surfaced by finalize() as a typed refusal;
            // the caller aborts and never deletes anything.
            buffers[section] = buffer
        }
    }

    func finalize(digest: String) throws -> PrivacyClearSpoolDescriptor {
        guard !finished else {
            throw PrivacyDomainError.persistenceUnavailable("spoolAlreadyFinalized")
        }
        finished = true
        var sections: [String: PrivacyClearSpoolSection] = [:]
        var counts = PrivacyClearSpoolCounts(
            conversations: 0, runs: 0, persistedGrants: 0,
            inMemoryGrants: 0, providers: 0, models: 0)
        do {
            for name in PrivacyClearSpoolLimits.sections {
                flush(name)
                guard let handle = handles[name] else {
                    throw PrivacyDomainError.persistenceUnavailable("spoolHandle")
                }
                try handle.synchronize()
                try handle.close()
                handles[name] = nil
                let staged = directory.appendingPathComponent(name + ".staged")
                let final = directory.appendingPathComponent(name + ".dat")
                try FileManager.default.moveItem(at: staged, to: final)
                var hash = String(repeating: "0", count: 64)
                if var hasher = hashers[name] {
                    hash = hasher.finalize()
                        .map { String(format: "%02x", $0) }.joined()
                }
                sections[name] = PrivacyClearSpoolSection(
                    bytes: bytes[name] ?? 0, lines: lines[name] ?? 0,
                    sha256: "sha256:" + hash)
            }
            counts = PrivacyClearSpoolCounts(
                conversations: lines["conversations"] ?? 0,
                runs: lines["runs"] ?? 0,
                persistedGrants: lines["persistedGrants"] ?? 0,
                inMemoryGrants: lines["inMemoryGrants"] ?? 0,
                providers: lines["providers"] ?? 0,
                models: lines["models"] ?? 0)
            let manifest = PrivacyClearSpoolManifest(
                schema: PrivacyClearSpoolLimits.schema,
                operationID: operationID,
                epoch: epoch,
                root: root,
                digest: digest,
                createdAt: PrivacySnapshotEngine.iso8601Fractional(Date()),
                sections: sections)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(manifest)
            let manifestURL = directory.appendingPathComponent("manifest.json")
            try data.write(to: manifestURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
            // VERIFY what was staged: byte count, line count and SHA-256 are
            // re-read from disk before the caller may delete a single row.
            _ = try PrivacyClearSpool.verify(directory: directory,
                                             manifest: manifest)
            return PrivacyClearSpoolDescriptor(
                directoryPath: directory.path,
                operationID: operationID, digest: digest, counts: counts)
        } catch {
            abort()
            throw PrivacyDomainError.persistenceUnavailable("spoolFinalize")
        }
    }

    func abort() {
        if !finished { finished = true }
        for (_, handle) in handles {
            try? handle.close()
        }
        handles.removeAll()
        buffers.removeAll()
        hashers.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    static func hex(_ string: String) -> String {
        string.utf8.map { String(format: "%02x", $0) }.joined()
    }

    static func unhex(_ raw: String) -> String? {
        guard raw.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(raw.count / 2)
        var index = raw.startIndex
        while index < raw.endIndex {
            let next = raw.index(index, offsetBy: 2)
            guard let byte = UInt8(raw[index..<next], radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

/// Verified read side. It never trusts the manifest alone: every section is
/// re-hashed from disk before the first destructive effect.
struct PrivacyClearSpool {
    let directory: URL
    let manifest: PrivacyClearSpoolManifest

    static func open(descriptor: PrivacyClearSpoolDescriptor) throws
        -> PrivacyClearSpool
    {
        let directory = URL(fileURLWithPath: descriptor.directoryPath,
                            isDirectory: true)
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL) else {
            throw PrivacyDomainError.persistenceUnavailable("spoolMissing")
        }
        let decoder = JSONDecoder()
        guard let manifest = try? decoder.decode(PrivacyClearSpoolManifest.self,
                                                 from: data),
              manifest.schema == PrivacyClearSpoolLimits.schema,
              manifest.operationID == descriptor.operationID,
              manifest.digest == descriptor.digest else {
            throw PrivacyDomainError.persistenceUnavailable("spoolManifestInvalid")
        }
        let verified = try verify(directory: directory, manifest: manifest)
        guard verified == manifest else {
            throw PrivacyDomainError.persistenceUnavailable("spoolVerificationMismatch")
        }
        return PrivacyClearSpool(directory: directory, manifest: manifest)
    }

    static func verify(directory: URL,
                       manifest: PrivacyClearSpoolManifest) throws
        -> PrivacyClearSpoolManifest
    {
        var sections: [String: PrivacyClearSpoolSection] = [:]
        for name in PrivacyClearSpoolLimits.sections {
            guard let recorded = manifest.sections[name] else {
                throw PrivacyDomainError.persistenceUnavailable("spoolSectionMissing")
            }
            let url = directory.appendingPathComponent(name + ".dat")
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                throw PrivacyDomainError.persistenceUnavailable("spoolSectionMissing")
            }
            var hasher = SHA256()
            var total = 0
            var lineCount = 0
            var lastByte: UInt8 = 0x0A
            while true {
                let chunk = try handle.read(upToCount: PrivacyClearSpoolLimits.readBufferBytes)
                guard let chunk, !chunk.isEmpty else { break }
                total += chunk.count
                hasher.update(data: chunk)
                for byte in chunk {
                    if byte == 0x0A { lineCount += 1 }
                }
                lastByte = chunk.last ?? lastByte
            }
            try? handle.close()
            // A staged line always ends with a newline; a missing final
            // newline is a truncated write, never a valid short line.
            guard lastByte == 0x0A || total == 0 else {
                throw PrivacyDomainError.persistenceUnavailable("spoolTruncated")
            }
            let hash = "sha256:" + hasher.finalize()
                .map { String(format: "%02x", $0) }.joined()
            guard total == recorded.bytes, lineCount == recorded.lines,
                  hash == recorded.sha256 else {
                throw PrivacyDomainError.persistenceUnavailable("spoolVerificationMismatch")
            }
            sections[name] = PrivacyClearSpoolSection(
                bytes: total, lines: lineCount, sha256: hash)
        }
        var verified = manifest
        verified.sections = sections
        return verified
    }

    static func removeStale(rootPath: String, keeping operationID: UUID?) {
        let parent = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("PrivacyClearStaging", isDirectory: true)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent
            .hasPrefix(PrivacyClearSpoolLimits.directoryPrefix) {
            if let operationID,
               entry.lastPathComponent == PrivacyClearSpoolLimits.directoryPrefix
                    + operationID.uuidString {
                continue
            }
            try? FileManager.default.removeItem(at: entry)
        }
    }

    static func remove(descriptor: PrivacyClearSpoolDescriptor) {
        try? FileManager.default.removeItem(
            at: URL(fileURLWithPath: descriptor.directoryPath,
                    isDirectory: true))
    }

    func reader(section: String) throws -> PrivacySpoolLineReader {
        guard manifest.sections[section] != nil else {
            throw PrivacyDomainError.persistenceUnavailable("spoolSectionMissing")
        }
        return try PrivacySpoolLineReader(
            url: directory.appendingPathComponent(section + ".dat"))
    }
}

/// Bounded streaming line reader. It keeps at most one 64 KiB read chunk
/// plus the current partial line; no section is ever materialized whole.
final class PrivacySpoolLineReader: @unchecked Sendable {
    private let handle: FileHandle
    private var buffer = Data()
    private var eof = false

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit { try? handle.close() }

    func forEachLine(_ body: (String) throws -> Void) throws {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                try body(String(decoding: lineData, as: UTF8.self))
                continue
            }
            if eof {
                if !buffer.isEmpty {
                    let remainder = buffer
                    buffer.removeAll(keepingCapacity: false)
                    try body(String(decoding: remainder, as: UTF8.self))
                }
                return
            }
            let chunk = try handle.read(upToCount: PrivacyClearSpoolLimits.readBufferBytes)
            if let chunk, !chunk.isEmpty {
                buffer.append(chunk)
            } else {
                eof = true
            }
        }
    }

    /// Bounded page of lines. Returns [] at EOF; the final page may be
    /// shorter. The reader keeps its position across calls.
    func nextPage(limit: Int) throws -> [String] {
        var page: [String] = []
        page.reserveCapacity(limit)
        while page.count < limit {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                page.append(String(decoding: lineData, as: UTF8.self))
                continue
            }
            if eof { break }
            let chunk = try handle.read(upToCount: PrivacyClearSpoolLimits.readBufferBytes)
            if let chunk, !chunk.isEmpty {
                buffer.append(chunk)
            } else {
                eof = true
            }
        }
        return page
    }
}
