// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreGraphics
import ImageIO

/// One named native snapshot. `manual` slots are never removed by automatic
/// rotation; `autosave` slots have a finite per-scope rotation.
public enum GameSaveSlotKind: String, Codable, CaseIterable, Sendable {
    case manual
    case autosave
}

public enum GameSaveSlotError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidDate
    case invalidTitle
    case invalidSourceRevision
    case invalidState
    case invalidThumbnail
    case stateTooLarge(Int)
    case limitExceeded(String)
    case titleInUse
    case slotNotFound(UUID)
    case slotNotDeleted(UUID)
    case staleRevision(slotID: UUID, expected: UInt64, actual: UInt64)
    case corruptCatalog
    case unsupportedCatalogVersion(Int)
    case corruptSlot(UUID)
    case payloadMissing(UUID)
    case scopeMismatch
    case unsupportedBackupVersion(Int)
    case invalidBackup(String)
    case backupDigestMismatch
    case legacyStoreMissing
    case legacyStoreCorrupt
    case legacyScopeMismatch
    case storageFailure
}

extension GameSaveSlotError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The save store configuration is invalid."
        case .invalidDate:
            return "The save timestamp is invalid."
        case .invalidTitle:
            return "The save name is empty, too long or contains unsupported characters."
        case .invalidSourceRevision:
            return "The source revision metadata is invalid."
        case .invalidState:
            return "The snapshot is not valid JSON."
        case .invalidThumbnail:
            return "The thumbnail is not a bounded PNG image."
        case .stateTooLarge(let bytes):
            return "The snapshot is too large (\(bytes) bytes)."
        case .limitExceeded(let limit):
            return "The save store limit was reached: \(limit)."
        case .titleInUse:
            return "Another save already uses that name."
        case .slotNotFound(let id):
            return "The save slot \(id.uuidString.lowercased()) was not found."
        case .slotNotDeleted(let id):
            return "The save slot \(id.uuidString.lowercased()) is not in the deleted list."
        case .staleRevision(let id, let expected, let actual):
            return "Save \(id.uuidString.lowercased()) changed (expected revision \(expected), found \(actual))."
        case .corruptCatalog:
            return "The save index is damaged."
        case .unsupportedCatalogVersion(let version):
            return "The save index version \(version) is not supported."
        case .corruptSlot(let id):
            return "Save \(id.uuidString.lowercased()) is damaged."
        case .payloadMissing(let id):
            return "Save \(id.uuidString.lowercased()) is missing its snapshot."
        case .scopeMismatch:
            return "The save belongs to another game scope."
        case .unsupportedBackupVersion(let version):
            return "Backup version \(version) is not supported."
        case .invalidBackup(let detail):
            return "The backup is invalid: \(detail)."
        case .backupDigestMismatch:
            return "The backup snapshot does not match its digest."
        case .legacyStoreMissing:
            return "No legacy save exists for this game scope."
        case .legacyStoreCorrupt:
            return "The legacy save is damaged."
        case .legacyScopeMismatch:
            return "The legacy save belongs to another project or owner."
        case .storageFailure:
            return "The save store could not be updated."
        }
    }
}

/// Bounds validated once per repository. State bytes additionally follow the
/// fixed `GameWebRuntimePolicy` ceiling for the scoped engine.
public struct GameSaveSlotLimits: Equatable, Sendable {
    public let maximumSlots: Int
    public let maximumAutosaveSlots: Int
    public let maximumTrashSlots: Int
    public let maximumTotalBytes: Int
    public let maximumTitleBytes: Int
    public let maximumThumbnailBytes: Int
    public let maximumCatalogBytes: Int

    public init(maximumSlots: Int = 60,
                maximumAutosaveSlots: Int = 5,
                maximumTrashSlots: Int = 12,
                maximumTotalBytes: Int = 64 * 1_024 * 1_024,
                maximumTitleBytes: Int = 160,
                maximumThumbnailBytes: Int = 512 * 1_024,
                maximumCatalogBytes: Int = 4 * 1_024 * 1_024) throws {
        guard (2...512).contains(maximumSlots),
              (1...64).contains(maximumAutosaveSlots),
              maximumAutosaveSlots < maximumSlots,
              (1...128).contains(maximumTrashSlots),
              (1_048_576...256 * 1_024 * 1_024).contains(maximumTotalBytes),
              (8...512).contains(maximumTitleBytes),
              (16_384...2 * 1_024 * 1_024).contains(maximumThumbnailBytes),
              (262_144...16 * 1_024 * 1_024).contains(maximumCatalogBytes) else {
            throw GameSaveSlotError.invalidConfiguration
        }
        self.maximumSlots = maximumSlots
        self.maximumAutosaveSlots = maximumAutosaveSlots
        self.maximumTrashSlots = maximumTrashSlots
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumTitleBytes = maximumTitleBytes
        self.maximumThumbnailBytes = maximumThumbnailBytes
        self.maximumCatalogBytes = maximumCatalogBytes
    }
}

public struct GameSaveSlotDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let scopeID: UUID
    public let engine: GameEngineID
    public let title: String
    public let kind: GameSaveSlotKind
    public let createdAt: Date
    public let updatedAt: Date
    public let deletedAt: Date?
    public let sourceRevision: String
    public let stateBytes: Int
    public let stateDigest: String
    public let thumbnailBytes: Int
    public let thumbnailDigest: String?
    public let revision: UInt64
    public var isDeleted: Bool { deletedAt != nil }

    fileprivate init(record: GameSaveSlotRecord, scope: GameSaveBackupScope) {
        id = record.id
        scopeID = scope.scopeID
        engine = scope.engine
        title = record.title
        kind = record.kind
        createdAt = record.createdAt
        updatedAt = record.updatedAt
        deletedAt = record.deletedAt
        sourceRevision = record.sourceRevision
        stateBytes = record.stateBytes
        stateDigest = record.stateDigest
        thumbnailBytes = record.thumbnailBytes
        thumbnailDigest = record.thumbnailDigest
        revision = record.revision
    }
}

public struct GameSaveSlotCatalogSnapshot: Sendable {
    public let revision: UInt64
    public let slots: [GameSaveSlotDescriptor]
}

public struct GameSaveSlot: Sendable {
    public let descriptor: GameSaveSlotDescriptor
    public let state: Data
    public let thumbnail: Data?
}

/// The stable scope repeated in backups. It carries exactly the host-resolved
/// values that select the store directory; it is not a permission token.
public struct GameSaveBackupScope: Codable, Equatable, Sendable {
    public let scopeID: UUID
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let engine: GameEngineID
    public let environmentID: String?
    public let gameRoot: String

    public init(identity: GameWebStorageIdentity) {
        scopeID = identity.uuid
        projectID = identity.projectID
        owner = identity.owner
        engine = identity.engine
        environmentID = identity.environmentID
        gameRoot = identity.gameRoot
    }
}

public struct GameSaveBackupSummary: Equatable, Sendable {
    public let scope: GameSaveBackupScope
    public let title: String
    public let kind: GameSaveSlotKind
    public let sourceRevision: String
    public let stateBytes: Int
    public let stateDigest: String
    public let thumbnailBytes: Int
    public let fileBytes: Int
    /// SHA-256 of the exact exported JSON file.
    public let sha256: String
}

public struct GameSaveBackupPackage: Sendable {
    public let data: Data
    public let summary: GameSaveBackupSummary
    public let suggestedFileName: String
}

public struct GameSaveImportResult: Sendable {
    public let slot: GameSaveSlotDescriptor
    public let backup: GameSaveBackupSummary
}

public struct GameSaveLegacyImportResult: Sendable {
    public let slot: GameSaveSlotDescriptor
    public let alreadyImported: Bool
}

// MARK: - Private records

fileprivate struct GameSaveSlotRecord: Codable, Sendable {
    let id: UUID
    let title: String
    let kind: GameSaveSlotKind
    let createdAt: Date
    let updatedAt: Date
    let deletedAt: Date?
    let sourceRevision: String
    let stateBytes: Int
    let stateDigest: String
    let thumbnailBytes: Int
    let thumbnailDigest: String?
    let revision: UInt64
    /// Set only for an explicit legacy import. It makes the import idempotent
    /// for the exact legacy file bytes without modifying that file.
    let legacyDigest: String?
}

fileprivate struct GameSaveCatalog: Codable, Sendable {
    let version: Int
    let scope: GameSaveBackupScope
    var revision: UInt64
    var slots: [GameSaveSlotRecord]

    init(scope: GameSaveBackupScope) {
        version = 1
        self.scope = scope
        revision = 0
        slots = []
    }
}

fileprivate struct GameSaveLegacyRecord: Codable, Sendable {
    let version: Int
    let projectID: UUID
    let owner: GameProjectOwner
    let revision: UInt64
    let state: Data
}

fileprivate struct GameSaveBackupEnvelope: Codable, Sendable {
    let format: String
    let version: Int
    let scope: GameSaveBackupScope
    let title: String
    let kind: GameSaveSlotKind
    let createdAt: Date
    let sourceRevision: String
    let stateBytes: Int
    let stateDigest: String
    let stateBase64: String
    let thumbnailBytes: Int
    let thumbnailDigest: String?
    let thumbnailBase64: String?
}

private struct GameSaveDecodedBackup {
    let envelope: GameSaveBackupEnvelope
    let state: Data
    let thumbnail: Data?
    let summary: GameSaveBackupSummary
}

// MARK: - Repository

/// Multi-slot native save store for exactly one host-resolved
/// `GameWebStorageIdentity`. The host chooses the root directory; the identity
/// (never a project manifest) chooses the isolated subdirectory. Metadata lives
/// in one atomic catalog guarded by an advisory file lock and a monotonically
/// increasing revision. State and previews are content-addressed immutable
/// blobs. Deleted slots stay recoverable until the bounded trash window rolls.
public actor FileGameSaveSlotRepository {
    public static let formatVersion = 1

    public nonisolated let directory: URL
    public nonisolated let identity: GameWebStorageIdentity
    public nonisolated let limits: GameSaveSlotLimits
    public nonisolated let maximumStateBytes: Int
    public nonisolated let maximumBackupBytes: Int
    /// `<directory>/<scope-uuid>/slots-v1`. Only this scope is read or written.
    public nonisolated let storageDirectory: URL

    private static let lockName = "catalog.lock"
    private static let catalogName = "catalog-v1.json"
    private static let payloadFolder = "payloads"
    private static let thumbnailFolder = "thumbnails"
    private static let backupFormat = "floe.game-save-backup"

    public init(directory: URL,
                identity: GameWebStorageIdentity,
                limits: GameSaveSlotLimits = try! .init()) throws {
        guard directory.isFileURL else { throw GameSaveSlotError.invalidConfiguration }
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
        self.identity = identity
        self.limits = limits
        let stateLimit = GameWebRuntimePolicy(engine: identity.engine).maximumStateBytes
        guard stateLimit >= 1_024 else { throw GameSaveSlotError.invalidConfiguration }
        maximumStateBytes = stateLimit
        maximumBackupBytes = ((stateLimit + limits.maximumThumbnailBytes + 2) / 3) * 4 + 65_536
        storageDirectory = self.directory
            .appendingPathComponent(identity.originHost, isDirectory: true)
            .appendingPathComponent("slots-v1", isDirectory: true)
        try GameFileStorage.directory(self.directory)
        try GameFileStorage.directory(storageDirectory)
        // Actor initializers are nonisolated. Derive these immutable URLs
        // directly rather than reading actor-isolated computed properties.
        try GameFileStorage.directory(storageDirectory.appendingPathComponent(Self.payloadFolder, isDirectory: true))
        try GameFileStorage.directory(storageDirectory.appendingPathComponent(Self.thumbnailFolder, isDirectory: true))
    }

    private var scope: GameSaveBackupScope { GameSaveBackupScope(identity: identity) }
    private var catalogURL: URL { storageDirectory.appendingPathComponent(Self.catalogName) }
    private var payloadDirectory: URL { storageDirectory.appendingPathComponent(Self.payloadFolder, isDirectory: true) }
    private var thumbnailDirectory: URL { storageDirectory.appendingPathComponent(Self.thumbnailFolder, isDirectory: true) }

    // MARK: Public reads

    public func list(includeDeleted: Bool = false) throws -> GameSaveSlotCatalogSnapshot {
        try readCatalogSnapshot { catalog in
            let records = catalog.slots.filter { includeDeleted || $0.deletedAt == nil }
            let sorted = records.sorted { lhs, rhs in
                if lhs.deletedAt != nil || rhs.deletedAt != nil {
                    let left = lhs.deletedAt ?? lhs.updatedAt
                    let right = rhs.deletedAt ?? rhs.updatedAt
                    if left != right { return left > right }
                } else if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return GameSaveSlotCatalogSnapshot(revision: catalog.revision,
                slots: sorted.map { descriptor(for: $0) })
        }
    }

    public func load(_ id: UUID) throws -> GameSaveSlot {
        try readCatalogSnapshot { catalog in
            guard let record = catalog.slots.first(where: { $0.id == id }),
                  record.deletedAt == nil else { throw GameSaveSlotError.slotNotFound(id) }
            return GameSaveSlot(descriptor: descriptor(for: record),
                                state: try loadState(record),
                                thumbnail: try loadThumbnail(record))
        }
    }

    /// Preview bytes for either an active or a deleted slot. Nil means this
    /// slot was created without a preview.
    public func thumbnail(_ id: UUID) throws -> Data? {
        try readCatalogSnapshot { catalog in
            guard let record = catalog.slots.first(where: { $0.id == id }) else {
                throw GameSaveSlotError.slotNotFound(id)
            }
            return try loadThumbnail(record)
        }
    }

    // MARK: Public mutations

    public func create(state: Data,
                       title: String,
                       kind: GameSaveSlotKind = .manual,
                       sourceRevision: String,
                       thumbnail: Data? = nil,
                       at date: Date = Date()) throws -> GameSaveSlotDescriptor {
        try Task.checkCancellation()
        try validateDate(date)
        try validateSourceRevision(sourceRevision)
        try validateState(state)
        if let thumbnail { try validateThumbnail(thumbnail) }
        let normalizedTitle = try normalizeTitle(title)
        return try mutate { catalog in
            if kind == .autosave { try makeRoomForAutosave(&catalog) }
            let active = catalog.slots.filter { $0.deletedAt == nil }
            guard active.count < limits.maximumSlots else {
                throw GameSaveSlotError.limitExceeded("slots")
            }
            guard !active.contains(where: { sameTitle($0.title, normalizedTitle) }) else {
                throw GameSaveSlotError.titleInUse
            }
            let record = makeRecord(title: normalizedTitle, kind: kind, date: date,
                                    sourceRevision: sourceRevision, state: state,
                                    thumbnail: thumbnail, revision: 1, legacyDigest: nil)
            return try insert(record, state: state, thumbnail: thumbnail, into: &catalog)
        }
    }

    /// Automatic capture is a separate bounded kind. It rotates only older
    /// autosaves and never removes a manual slot.
    public func saveAutomatic(state: Data,
                              title: String,
                              sourceRevision: String,
                              at date: Date = Date(),
                              preserving preservedSlotID: UUID? = nil) throws -> GameSaveSlotDescriptor {
        try Task.checkCancellation()
        try validateDate(date)
        try validateSourceRevision(sourceRevision)
        try validateState(state)
        let base = try normalizeTitle(title)
        return try mutate { catalog in
            try makeRoomForAutosave(&catalog, preserving: preservedSlotID)
            let active = catalog.slots.filter { $0.deletedAt == nil }
            guard active.count < limits.maximumSlots else {
                throw GameSaveSlotError.limitExceeded("slots")
            }
            let unique = uniqueTitle(base, among: active)
            let record = makeRecord(title: unique, kind: .autosave, date: date,
                                    sourceRevision: sourceRevision, state: state,
                                    thumbnail: nil, revision: 1, legacyDigest: nil)
            return try insert(record, state: state, thumbnail: nil, into: &catalog)
        }
    }

    public func update(_ id: UUID,
                       state: Data,
                       thumbnail: Data?,
                       sourceRevision: String,
                       expectedRevision: UInt64,
                       at date: Date = Date()) throws -> GameSaveSlotDescriptor {
        try Task.checkCancellation()
        try validateDate(date)
        try validateSourceRevision(sourceRevision)
        try validateState(state)
        if let thumbnail { try validateThumbnail(thumbnail) }
        return try mutate { catalog in
            guard let index = catalog.slots.firstIndex(where: { $0.id == id }),
                  catalog.slots[index].deletedAt == nil else {
                throw GameSaveSlotError.slotNotFound(id)
            }
            let old = catalog.slots[index]
            guard old.revision == expectedRevision else {
                throw GameSaveSlotError.staleRevision(slotID: id, expected: expectedRevision, actual: old.revision)
            }
            guard old.revision < UInt64.max else {
                throw GameSaveSlotError.limitExceeded("revision")
            }
            try ensureCapacity(catalog, replacing: old,
                               addingState: state.count, thumbnail: thumbnail?.count ?? 0)
            let new = makeRecord(id: old.id, title: old.title, kind: old.kind, date: date,
                                 sourceRevision: sourceRevision, state: state,
                                 thumbnail: thumbnail, revision: old.revision + 1,
                                 legacyDigest: old.legacyDigest, createdAt: old.createdAt)
            try storeState(state, digest: new.stateDigest, slotID: id)
            if let thumbnail, let digest = new.thumbnailDigest {
                try storeThumbnail(thumbnail, digest: digest, slotID: id)
            }
            catalog.slots[index] = new
            return descriptor(for: new)
        }
    }

    public func rename(_ id: UUID,
                       to title: String,
                       expectedRevision: UInt64,
                       at date: Date = Date()) throws -> GameSaveSlotDescriptor {
        try Task.checkCancellation()
        try validateDate(date)
        let normalizedTitle = try normalizeTitle(title)
        return try mutate { catalog in
            guard let index = catalog.slots.firstIndex(where: { $0.id == id }),
                  catalog.slots[index].deletedAt == nil else {
                throw GameSaveSlotError.slotNotFound(id)
            }
            let old = catalog.slots[index]
            guard old.revision == expectedRevision else {
                throw GameSaveSlotError.staleRevision(slotID: id, expected: expectedRevision, actual: old.revision)
            }
            guard old.revision < UInt64.max else {
                throw GameSaveSlotError.limitExceeded("revision")
            }
            let active = catalog.slots.filter { $0.deletedAt == nil && $0.id != id }
            guard !active.contains(where: { sameTitle($0.title, normalizedTitle) }) else {
                throw GameSaveSlotError.titleInUse
            }
            let renamed = GameSaveSlotRecord(id: old.id, title: normalizedTitle, kind: old.kind,
                createdAt: old.createdAt, updatedAt: old.updatedAt, deletedAt: nil,
                sourceRevision: old.sourceRevision, stateBytes: old.stateBytes,
                stateDigest: old.stateDigest, thumbnailBytes: old.thumbnailBytes,
                thumbnailDigest: old.thumbnailDigest, revision: old.revision + 1,
                legacyDigest: old.legacyDigest)
            catalog.slots[index] = renamed
            return descriptor(for: renamed)
        }
    }

    /// Deletion is a reversible catalog move, not an eager byte delete. When
    /// the bounded trash window rolls, the oldest deleted records (and only
    /// unreferenced blobs) are removed.
    public func delete(_ id: UUID,
                       expectedRevision: UInt64,
                       at date: Date = Date()) throws -> GameSaveSlotDescriptor {
        try Task.checkCancellation()
        try validateDate(date)
        return try mutate { catalog in
            guard let index = catalog.slots.firstIndex(where: { $0.id == id }),
                  catalog.slots[index].deletedAt == nil else {
                throw GameSaveSlotError.slotNotFound(id)
            }
            let old = catalog.slots[index]
            guard old.revision == expectedRevision else {
                throw GameSaveSlotError.staleRevision(slotID: id, expected: expectedRevision, actual: old.revision)
            }
            guard old.revision < UInt64.max else {
                throw GameSaveSlotError.limitExceeded("revision")
            }
            let deleted = GameSaveSlotRecord(id: old.id, title: old.title, kind: old.kind,
                createdAt: old.createdAt, updatedAt: old.updatedAt, deletedAt: date,
                sourceRevision: old.sourceRevision, stateBytes: old.stateBytes,
                stateDigest: old.stateDigest, thumbnailBytes: old.thumbnailBytes,
                thumbnailDigest: old.thumbnailDigest, revision: old.revision + 1,
                legacyDigest: old.legacyDigest)
            catalog.slots[index] = deleted
            trimTrash(&catalog)
            return descriptor(for: deleted)
        }
    }

    public func recover(_ id: UUID,
                        expectedRevision: UInt64,
                        at date: Date = Date()) throws -> GameSaveSlotDescriptor {
        try Task.checkCancellation()
        try validateDate(date)
        return try mutate { catalog in
            guard let index = catalog.slots.firstIndex(where: { $0.id == id }),
                  catalog.slots[index].deletedAt != nil else {
                throw GameSaveSlotError.slotNotDeleted(id)
            }
            let old = catalog.slots[index]
            guard old.revision == expectedRevision else {
                throw GameSaveSlotError.staleRevision(slotID: id, expected: expectedRevision, actual: old.revision)
            }
            guard old.revision < UInt64.max else {
                throw GameSaveSlotError.limitExceeded("revision")
            }
            let active = catalog.slots.filter { $0.deletedAt == nil }
            guard active.count < limits.maximumSlots else {
                throw GameSaveSlotError.limitExceeded("slots")
            }
            let title = uniqueTitle(old.title, among: active)
            let restored = GameSaveSlotRecord(id: old.id, title: title, kind: old.kind,
                createdAt: old.createdAt, updatedAt: old.updatedAt, deletedAt: nil,
                sourceRevision: old.sourceRevision, stateBytes: old.stateBytes,
                stateDigest: old.stateDigest, thumbnailBytes: old.thumbnailBytes,
                thumbnailDigest: old.thumbnailDigest, revision: old.revision + 1,
                legacyDigest: old.legacyDigest)
            catalog.slots[index] = restored
            return descriptor(for: restored)
        }
    }

    // MARK: Backup

    public func exportBackup(_ id: UUID) throws -> GameSaveBackupPackage {
        try readCatalogSnapshot { catalog in
            guard let record = catalog.slots.first(where: { $0.id == id }),
                  record.deletedAt == nil else {
                throw GameSaveSlotError.slotNotFound(id)
            }
            let state = try loadState(record)
            let thumbnail = try loadThumbnail(record)
            let envelope = GameSaveBackupEnvelope(
                format: Self.backupFormat, version: Self.formatVersion, scope: scope,
                title: record.title, kind: record.kind, createdAt: record.createdAt,
                sourceRevision: record.sourceRevision, stateBytes: state.count,
                stateDigest: record.stateDigest, stateBase64: state.base64EncodedString(),
                thumbnailBytes: thumbnail?.count ?? 0,
                thumbnailDigest: record.thumbnailDigest,
                thumbnailBase64: thumbnail?.base64EncodedString())
            let data: Data
            do { data = try GameFileStorage.encode(envelope) }
            catch { throw GameSaveSlotError.storageFailure }
            guard data.count <= maximumBackupBytes else {
                throw GameSaveSlotError.limitExceeded("backupBytes")
            }
            let summary = GameSaveBackupSummary(scope: scope, title: record.title,
                kind: record.kind, sourceRevision: record.sourceRevision,
                stateBytes: state.count, stateDigest: record.stateDigest,
                thumbnailBytes: thumbnail?.count ?? 0, fileBytes: data.count,
                sha256: GameDigest.sha256(data))
            return GameSaveBackupPackage(data: data, summary: summary,
                suggestedFileName: suggestedFileName(title: record.title, id: record.id))
        }
    }

    /// Validates an exported JSON backup without touching the store.
    public func inspectBackup(_ data: Data) throws -> GameSaveBackupSummary {
        try decodeBackup(data).summary
    }

    /// Import always creates a new manual slot. A foreign scope, a modified
    /// state digest, an unknown version or an oversized payload is rejected
    /// before the store lock is taken.
    public func importBackup(_ data: Data,
                             title: String? = nil,
                             at date: Date = Date()) throws -> GameSaveImportResult {
        try Task.checkCancellation()
        try validateDate(date)
        let decoded = try decodeBackup(data)
        let requested = (try? normalizeTitle(title ?? decoded.envelope.title)) ?? "Imported save"
        return try mutate { catalog in
            let active = catalog.slots.filter { $0.deletedAt == nil }
            guard active.count < limits.maximumSlots else {
                throw GameSaveSlotError.limitExceeded("slots")
            }
            let unique = uniqueTitle(requested, among: active)
            let record = makeRecord(title: unique, kind: .manual, date: date,
                                    sourceRevision: decoded.envelope.sourceRevision,
                                    state: decoded.state, thumbnail: decoded.thumbnail,
                                    revision: 1, legacyDigest: nil)
            let descriptor = try insert(record, state: decoded.state,
                                        thumbnail: decoded.thumbnail, into: &catalog)
            return GameSaveImportResult(slot: descriptor, backup: decoded.summary)
        }
    }

    /// Explicit one-time import of the legacy single-checkpoint repository
    /// created by `GameWebSaveRepositories.open(directory:artifact:)`. The
    /// legacy file is read only and never rewritten or deleted.
    public func importLegacySave(title: String? = nil,
                                 at date: Date = Date()) throws -> GameSaveLegacyImportResult {
        try Task.checkCancellation()
        try validateDate(date)
        let legacyURL = storageDirectory.deletingLastPathComponent()
            .appendingPathComponent(legacyFileName)
        guard FileManager.default.fileExists(atPath: legacyURL.path) else {
            throw GameSaveSlotError.legacyStoreMissing
        }
        let bytes: Data
        do {
            bytes = try GameFileStorage.read(legacyURL, maximum: maximumStateBytes * 2 + 8_192)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GameSaveSlotError.legacyStoreCorrupt
        }
        let legacy: GameSaveLegacyRecord
        do { legacy = try JSONDecoder().decode(GameSaveLegacyRecord.self, from: bytes) }
        catch { throw GameSaveSlotError.legacyStoreCorrupt }
        guard legacy.version == 1,
              legacy.projectID == identity.projectID,
              legacy.owner == identity.owner else {
            throw GameSaveSlotError.legacyScopeMismatch
        }
        do { try validateState(legacy.state) } catch { throw GameSaveSlotError.legacyStoreCorrupt }
        let digest = GameDigest.sha256(bytes)
        let baseTitle = (try? normalizeTitle(title ?? "Imported legacy save")) ?? "Imported legacy save"
        return try mutate { catalog in
            if let existing = catalog.slots.first(where: { $0.legacyDigest == digest }) {
                return GameSaveLegacyImportResult(slot: descriptor(for: existing),
                                                  alreadyImported: true)
            }
            let active = catalog.slots.filter { $0.deletedAt == nil }
            guard active.count < limits.maximumSlots else {
                throw GameSaveSlotError.limitExceeded("slots")
            }
            let unique = uniqueTitle(baseTitle, among: active)
            let record = makeRecord(title: unique, kind: .manual, date: date,
                                    sourceRevision: "legacy-import",
                                    state: legacy.state, thumbnail: nil,
                                    revision: 1, legacyDigest: digest)
            let descriptor = try insert(record, state: legacy.state,
                                        thumbnail: nil, into: &catalog)
            return GameSaveLegacyImportResult(slot: descriptor, alreadyImported: false)
        }
    }

    // MARK: Catalog primitives

    private func readCatalogSnapshot<T>(_ body: (GameSaveCatalog) throws -> T) throws -> T {
        do {
            return try GameFileStorage.locked(root: storageDirectory, name: Self.lockName) {
                try Task.checkCancellation()
                return try body(try readCatalog())
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GameSaveSlotError {
            throw error
        } catch {
            throw GameSaveSlotError.storageFailure
        }
    }

    private func mutate<T>(_ body: (inout GameSaveCatalog) throws -> T) throws -> T {
        do {
            return try GameFileStorage.locked(root: storageDirectory, name: Self.lockName) {
                var catalog = try readCatalog()
                let value = try body(&catalog)
                guard catalog.revision < UInt64.max else {
                    throw GameSaveSlotError.limitExceeded("catalogRevision")
                }
                catalog.revision += 1
                try writeCatalog(catalog)
                let verified = try readCatalog()
                guard verified.revision == catalog.revision else {
                    throw GameSaveSlotError.corruptCatalog
                }
                collectGarbage(catalog: verified)
                return value
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as GameSaveSlotError {
            throw error
        } catch {
            throw GameSaveSlotError.storageFailure
        }
    }

    private func readCatalog() throws -> GameSaveCatalog {
        guard FileManager.default.fileExists(atPath: catalogURL.path) else {
            return GameSaveCatalog(scope: scope)
        }
        let data: Data
        do {
            data = try GameFileStorage.read(catalogURL, maximum: limits.maximumCatalogBytes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GameSaveSlotError.corruptCatalog
        }
        let catalog: GameSaveCatalog
        do { catalog = try JSONDecoder().decode(GameSaveCatalog.self, from: data) }
        catch { throw GameSaveSlotError.corruptCatalog }
        try validateCatalog(catalog)
        return catalog
    }

    private func writeCatalog(_ catalog: GameSaveCatalog) throws {
        let data: Data
        do { data = try GameFileStorage.encode(catalog) }
        catch { throw GameSaveSlotError.storageFailure }
        guard data.count <= limits.maximumCatalogBytes else {
            throw GameSaveSlotError.limitExceeded("catalogBytes")
        }
        do { try GameFileStorage.atomicWrite(data, to: catalogURL) }
        catch is CancellationError { throw CancellationError() }
        catch { throw GameSaveSlotError.storageFailure }
    }

    private func validateCatalog(_ catalog: GameSaveCatalog) throws {
        guard catalog.version == Self.formatVersion else {
            throw GameSaveSlotError.unsupportedCatalogVersion(catalog.version)
        }
        guard catalog.scope == scope else { throw GameSaveSlotError.scopeMismatch }
        guard catalog.revision < UInt64.max, catalog.slots.count <= 512 else {
            throw GameSaveSlotError.corruptCatalog
        }
        var identifiers = Set<UUID>()
        for record in catalog.slots {
            guard identifiers.insert(record.id).inserted,
                  record.revision > 0,
                  validDate(record.createdAt), validDate(record.updatedAt),
                  record.deletedAt.map(validDate) ?? true,
                  record.stateBytes > 0, record.stateBytes <= maximumStateBytes,
                  isDigest(record.stateDigest),
                  record.thumbnailBytes >= 0,
                  record.thumbnailBytes <= limits.maximumThumbnailBytes,
                  GameProjectContext.validIdentifier(record.sourceRevision) else {
                throw GameSaveSlotError.corruptCatalog
            }
            if record.thumbnailBytes == 0 {
                guard record.thumbnailDigest == nil else { throw GameSaveSlotError.corruptCatalog }
            } else {
                guard let digest = record.thumbnailDigest, isDigest(digest) else {
                    throw GameSaveSlotError.corruptCatalog
                }
            }
            if let legacy = record.legacyDigest, !isDigest(legacy) {
                throw GameSaveSlotError.corruptCatalog
            }
            guard let title = try? normalizeTitle(record.title), title == record.title else {
                throw GameSaveSlotError.corruptCatalog
            }
        }
    }

    private func collectGarbage(catalog: GameSaveCatalog) {
        let stateDigests = Set(catalog.slots.map(\.stateDigest))
        let thumbnailDigests = Set(catalog.slots.compactMap(\.thumbnailDigest))
        removeUnreferenced(in: payloadDirectory, extension: "json", keeping: stateDigests)
        removeUnreferenced(in: thumbnailDirectory, extension: "png", keeping: thumbnailDigests)
    }

    private func removeUnreferenced(in directory: URL, extension suffix: String, keeping: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
              names.count <= 4_096 else { return }
        for name in names {
            guard name.hasSuffix("." + suffix) else { continue }
            let digest = String(name.dropLast(suffix.count + 1))
            guard isDigest(digest), !keeping.contains(digest) else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    // MARK: Records

    private func descriptor(for record: GameSaveSlotRecord) -> GameSaveSlotDescriptor {
        GameSaveSlotDescriptor(record: record, scope: scope)
    }

    private func makeRecord(id: UUID = UUID(), title: String, kind: GameSaveSlotKind, date: Date,
                            sourceRevision: String, state: Data, thumbnail: Data?,
                            revision: UInt64, legacyDigest: String?,
                            createdAt: Date? = nil) -> GameSaveSlotRecord {
        GameSaveSlotRecord(id: id, title: title, kind: kind,
            createdAt: createdAt ?? date, updatedAt: date, deletedAt: nil,
            sourceRevision: sourceRevision, stateBytes: state.count,
            stateDigest: GameDigest.sha256(state),
            thumbnailBytes: thumbnail?.count ?? 0,
            thumbnailDigest: thumbnail.map(GameDigest.sha256),
            revision: revision, legacyDigest: legacyDigest)
    }

    private func insert(_ record: GameSaveSlotRecord, state: Data, thumbnail: Data?,
                        into catalog: inout GameSaveCatalog) throws -> GameSaveSlotDescriptor {
        try ensureCapacity(catalog, replacing: nil, addingState: state.count,
                           thumbnail: thumbnail?.count ?? 0)
        try storeState(state, digest: record.stateDigest, slotID: record.id)
        if let thumbnail, let digest = record.thumbnailDigest {
            try storeThumbnail(thumbnail, digest: digest, slotID: record.id)
        }
        catalog.slots.append(record)
        return descriptor(for: record)
    }

    private func ensureCapacity(_ catalog: GameSaveCatalog, replacing old: GameSaveSlotRecord?,
                                addingState: Int, thumbnail: Int) throws {
        let existing = catalog.slots.reduce(0) { $0 + $1.stateBytes + $1.thumbnailBytes }
        let base = existing - (old?.stateBytes ?? 0) - (old?.thumbnailBytes ?? 0)
        guard base >= 0 else { throw GameSaveSlotError.corruptCatalog }
        let addition = addingState + thumbnail
        guard addition >= 0, addition <= limits.maximumTotalBytes - base else {
            throw GameSaveSlotError.limitExceeded("bytes")
        }
    }

    private func makeRoomForAutosave(_ catalog: inout GameSaveCatalog,
                                     preserving preservedSlotID: UUID? = nil) throws {
        while true {
            let active = catalog.slots.filter { $0.deletedAt == nil }
            let autosaves = active.filter { $0.kind == .autosave }.sorted(by: isOlder)
            let overCount = active.count + 1 > limits.maximumSlots
            let overAutosaves = autosaves.count + 1 > limits.maximumAutosaveSlots
            guard overCount || overAutosaves else { return }
            let removable = autosaves.filter { $0.id != preservedSlotID }
            guard let oldest = removable.first,
                  let index = catalog.slots.firstIndex(where: { $0.id == oldest.id }) else {
                throw GameSaveSlotError.limitExceeded("autosaves")
            }
            // Automatic rotation is not a user deletion: it reclaims the
            // oldest autosave permanently so bounded autosave churn cannot
            // fill the trash and starve manual slots.
            catalog.slots.remove(at: index)
        }
    }

    private func trimTrash(_ catalog: inout GameSaveCatalog) {
        let deleted = catalog.slots.filter { $0.deletedAt != nil }.sorted { lhs, rhs in
            let left = lhs.deletedAt ?? .distantPast
            let right = rhs.deletedAt ?? .distantPast
            if left != right { return left < right }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        let excess = deleted.count - limits.maximumTrashSlots
        guard excess > 0 else { return }
        let removable = Set(deleted.prefix(excess).map(\.id))
        catalog.slots.removeAll { removable.contains($0.id) }
    }

    private func isOlder(_ lhs: GameSaveSlotRecord, _ rhs: GameSaveSlotRecord) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt < rhs.updatedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    // MARK: Payloads

    private func storeState(_ state: Data, digest: String, slotID: UUID) throws {
        try storeBlob(state, digest: digest, directory: payloadDirectory,
                      suffix: "json", slotID: slotID)
    }

    private func storeThumbnail(_ thumbnail: Data, digest: String, slotID: UUID) throws {
        try storeBlob(thumbnail, digest: digest, directory: thumbnailDirectory,
                      suffix: "png", slotID: slotID)
    }

    private func storeBlob(_ data: Data, digest: String, directory: URL,
                           suffix: String, slotID: UUID) throws {
        let url = directory.appendingPathComponent(digest + "." + suffix)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing: Data
            do { existing = try GameFileStorage.read(url, maximum: data.count) }
            catch is CancellationError { throw CancellationError() }
            catch { throw GameSaveSlotError.corruptSlot(slotID) }
            guard existing == data else { throw GameSaveSlotError.corruptSlot(slotID) }
            return
        }
        do { try GameFileStorage.atomicWrite(data, to: url) }
        catch is CancellationError { throw CancellationError() }
        catch { throw GameSaveSlotError.storageFailure }
        let readBack: Data
        do { readBack = try GameFileStorage.read(url, maximum: data.count) }
        catch is CancellationError { throw CancellationError() }
        catch { throw GameSaveSlotError.corruptSlot(slotID) }
        guard readBack == data else { throw GameSaveSlotError.corruptSlot(slotID) }
    }

    private func loadState(_ record: GameSaveSlotRecord) throws -> Data {
        let url = payloadDirectory.appendingPathComponent(record.stateDigest + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GameSaveSlotError.payloadMissing(record.id)
        }
        let data: Data
        do { data = try GameFileStorage.read(url, maximum: maximumStateBytes) }
        catch is CancellationError { throw CancellationError() }
        catch { throw GameSaveSlotError.corruptSlot(record.id) }
        guard data.count == record.stateBytes,
              GameDigest.sha256(data) == record.stateDigest else {
            throw GameSaveSlotError.corruptSlot(record.id)
        }
        do { try validateState(data) } catch { throw GameSaveSlotError.corruptSlot(record.id) }
        return data
    }

    private func loadThumbnail(_ record: GameSaveSlotRecord) throws -> Data? {
        guard let digest = record.thumbnailDigest else {
            guard record.thumbnailBytes == 0 else { throw GameSaveSlotError.corruptSlot(record.id) }
            return nil
        }
        let url = thumbnailDirectory.appendingPathComponent(digest + ".png")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GameSaveSlotError.corruptSlot(record.id)
        }
        let data: Data
        do { data = try GameFileStorage.read(url, maximum: limits.maximumThumbnailBytes) }
        catch is CancellationError { throw CancellationError() }
        catch { throw GameSaveSlotError.corruptSlot(record.id) }
        guard data.count == record.thumbnailBytes,
              GameDigest.sha256(data) == digest else {
            throw GameSaveSlotError.corruptSlot(record.id)
        }
        do { try validateThumbnail(data) } catch { throw GameSaveSlotError.corruptSlot(record.id) }
        return data
    }

    // MARK: Backup parsing

    private func decodeBackup(_ data: Data) throws -> GameSaveDecodedBackup {
        guard !data.isEmpty else { throw GameSaveSlotError.invalidBackup("empty") }
        guard data.count <= maximumBackupBytes else {
            throw GameSaveSlotError.limitExceeded("backupBytes")
        }
        let raw: Any
        do { raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw GameSaveSlotError.invalidBackup("not JSON") }
        guard let object = raw as? [String: Any] else {
            throw GameSaveSlotError.invalidBackup("root")
        }
        if let version = object["version"] as? Int, version != Self.formatVersion {
            throw GameSaveSlotError.unsupportedBackupVersion(version)
        }
        let envelope: GameSaveBackupEnvelope
        do { envelope = try JSONDecoder().decode(GameSaveBackupEnvelope.self, from: data) }
        catch { throw GameSaveSlotError.invalidBackup("fields") }
        guard envelope.format == Self.backupFormat else {
            throw GameSaveSlotError.invalidBackup("format")
        }
        guard envelope.version == Self.formatVersion else {
            throw GameSaveSlotError.unsupportedBackupVersion(envelope.version)
        }
        guard envelope.scope == scope else { throw GameSaveSlotError.scopeMismatch }
        guard validDate(envelope.createdAt) else { throw GameSaveSlotError.invalidBackup("time") }
        guard GameProjectContext.validIdentifier(envelope.sourceRevision) else {
            throw GameSaveSlotError.invalidBackup("source revision")
        }
        guard let state = Data(base64Encoded: envelope.stateBase64) else {
            throw GameSaveSlotError.invalidBackup("state encoding")
        }
        guard !state.isEmpty else { throw GameSaveSlotError.invalidBackup("empty state") }
        guard state.count <= maximumStateBytes else {
            throw GameSaveSlotError.stateTooLarge(state.count)
        }
        guard envelope.stateBytes == state.count,
              envelope.stateDigest == GameDigest.sha256(state) else {
            throw GameSaveSlotError.backupDigestMismatch
        }
        do { try validateState(state) } catch { throw GameSaveSlotError.invalidBackup("state") }
        var thumbnail: Data?
        if envelope.thumbnailBytes == 0 {
            guard envelope.thumbnailDigest == nil, envelope.thumbnailBase64 == nil else {
                throw GameSaveSlotError.invalidBackup("thumbnail fields")
            }
        } else {
            guard envelope.thumbnailBytes <= limits.maximumThumbnailBytes,
                  let encoded = envelope.thumbnailBase64,
                  let bytes = Data(base64Encoded: encoded),
                  bytes.count == envelope.thumbnailBytes,
                  let digest = envelope.thumbnailDigest,
                  digest == GameDigest.sha256(bytes) else {
                throw GameSaveSlotError.invalidBackup("thumbnail")
            }
            do { try validateThumbnail(bytes) }
            catch { throw GameSaveSlotError.invalidBackup("thumbnail") }
            thumbnail = bytes
        }
        let summary = GameSaveBackupSummary(scope: envelope.scope, title: envelope.title,
            kind: envelope.kind, sourceRevision: envelope.sourceRevision,
            stateBytes: state.count, stateDigest: envelope.stateDigest,
            thumbnailBytes: thumbnail?.count ?? 0, fileBytes: data.count,
            sha256: GameDigest.sha256(data))
        return GameSaveDecodedBackup(envelope: envelope, state: state,
                                     thumbnail: thumbnail, summary: summary)
    }

    // MARK: Validation

    private func validateDate(_ date: Date) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite else {
            throw GameSaveSlotError.invalidDate
        }
    }

    private func validateSourceRevision(_ value: String) throws {
        guard GameProjectContext.validIdentifier(value) else {
            throw GameSaveSlotError.invalidSourceRevision
        }
    }

    private func validateState(_ data: Data) throws {
        guard !data.isEmpty else { throw GameSaveSlotError.invalidState }
        guard data.count <= maximumStateBytes else {
            throw GameSaveSlotError.stateTooLarge(data.count)
        }
        do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw GameSaveSlotError.invalidState }
    }

    private func validateThumbnail(_ data: Data) throws {
        guard !data.isEmpty, data.count <= limits.maximumThumbnailBytes else {
            throw GameSaveSlotError.invalidThumbnail
        }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let type = CGImageSourceGetType(source),
              CFStringCompare(type, "public.png" as CFString, []) == .compareEqualTo,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw GameSaveSlotError.invalidThumbnail
        }
        let pixelWidth = width.intValue, pixelHeight = height.intValue
        guard pixelWidth > 0, pixelHeight > 0,
              pixelWidth <= 4_096, pixelHeight <= 4_096,
              Int64(pixelWidth) * Int64(pixelHeight) <= 16_777_216 else {
            throw GameSaveSlotError.invalidThumbnail
        }
    }

    private func normalizeTitle(_ raw: String) throws -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping
        guard !title.isEmpty,
              title.utf8.count <= limits.maximumTitleBytes,
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw GameSaveSlotError.invalidTitle
        }
        return title
    }

    private func sameTitle(_ lhs: String, _ rhs: String) -> Bool {
        lhs.lowercased() == rhs.lowercased()
    }

    private func uniqueTitle(_ base: String, among records: [GameSaveSlotRecord]) -> String {
        let used = Set(records.map { $0.title.lowercased() })
        guard used.contains(base.lowercased()) else { return base }
        for index in 2...999 {
            let suffix = " \(index)"
            let room = max(0, limits.maximumTitleBytes - suffix.utf8.count)
            let prefix = bytePrefix(base, maximumBytes: room)
            let candidate = prefix + suffix
            if !used.contains(candidate.lowercased()) { return candidate }
        }
        return bytePrefix(base, maximumBytes: max(0, limits.maximumTitleBytes - 10))
            + " " + UUID().uuidString.prefix(8)
    }

    private func bytePrefix(_ text: String, maximumBytes: Int) -> String {
        var result = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > maximumBytes { break }
            result.append(character)
            bytes += size
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }

    // MARK: Paths

    private var legacyFileName: String {
        identity.projectID.uuidString.lowercased() + "-"
            + GameDigest.sha256((try? GameFileStorage.encode(identity.owner)) ?? Data())
            + ".json"
    }

    private func suggestedFileName(title: String, id: UUID) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_ "))
        var cleaned = String(title.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined())
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "-")
        if cleaned.isEmpty { cleaned = "save" }
        cleaned = String(cleaned.prefix(40))
        return "FloeSave-\(identity.engine.rawValue)-\(cleaned)-\(id.uuidString.prefix(8)).json"
    }
}

extension GameWebSaveRepositories {
    /// Multi-slot repository for the same host-resolved scope used by the
    /// legacy single-checkpoint helper. `directory` remains the host's base
    /// save directory; the slot store adds `<scope>/slots-v1` internally.
    public static func openSlots(directory: URL,
                                 artifact: GamePreparedArtifact) throws -> FileGameSaveSlotRepository {
        let saveRoot = directory.standardizedFileURL.resolvingSymlinksInPath()
        let sourceRoot = artifact.source.rootURL
        guard !(saveRoot.path + "/").hasPrefix(sourceRoot.path + "/") else {
            throw GameSaveSlotError.invalidConfiguration
        }
        return try .init(directory: directory, identity: try artifact.storageIdentity())
    }
}

