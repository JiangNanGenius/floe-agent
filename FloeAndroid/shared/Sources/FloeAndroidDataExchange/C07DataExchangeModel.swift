// SPDX-License-Identifier: MPL-2.0
//
// C07 manual data exchange — versioned, staged, validated user-data packages.
//
// The archive is UNTRUSTED input. It carries no tool permission, SAF grant,
// network authority or model authority. Every path is package-relative,
// validated without following links, and the manifest must describe the exact
// regular-file entry set before any byte reaches live App storage.
//
// The app backup deliberately does NOT contain floe.sqlite / notes.sqlite /
// WAL files or any other live database. User projects, portable Notes archives
// and an explicit non-secret preference allowlist are exported through their
// real owning formats instead. Credential values, device keys, cookies,
// sessions, grants, run records and provider secrets are never part of a
// package.
import Foundation
import Crypto

// MARK: - Bounds

public enum C07DataExchangeLimits {
    public static let backupFormat = "floe.appbackup"
    public static let backupFormatVersion = 2
    public static let legacyBackupFormatVersion = 1
    public static let backupExtension = "floebackup"
    public static let notesExtension = "floenote"

    public static let maximumManifestBytes = 16 * 1_024 * 1_024
    public static let maximumEntries = 200_000
    public static let maximumProjects = 10_000
    public static let maximumEntryBytes: Int64 = 4 * 1_024 * 1_024 * 1_024
    public static let maximumTotalBytes: Int64 = 16 * 1_024 * 1_024 * 1_024
    public static let maximumPathBytes = 1_024
    public static let maximumProjectNameBytes = 512
    public static let maximumNotebookTitleBytes = 65_536
    public static let maximumNoteTitleBytes = 65_536
    public static let maximumSettingsBytes: Int64 = 1_024 * 1_024
    public static let maximumNotebooks = 20_000
    public static let maximumNoteDocuments = 100_000
    public static let maximumNestedNoteManifestBytes = 16 * 1_024 * 1_024
    public static let maximumNoteResourceBytes: Int64 = 512 * 1_024 * 1_024
    public static let maximumNoteArchiveBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    public static let copyChunkBytes = 1_048_576
    public static let freeSpaceHeadroom: Int64 = 512 * 1_024 * 1_024
    public static let maximumCompressionRatio = 200.0
    public static let compressionRatioProbeBytes: Int64 = 1_048_576
}

/// Closed roles accepted in a package. Unknown roles fail the whole read.
public enum C07EntryRole: String, Codable, Sendable, CaseIterable {
    case projectFile
    case projectDirectory
    case notesArchive
    case settings
}

public enum C07ProjectOrigin: String, Codable, Sendable, CaseIterable {
    /// A live C01 project row: `Projects/<projectUUID>`.
    case managed
    /// A retained `Projects/<projectUUID>` directory with no live row.
    /// C01 project deletion intentionally keeps these bytes; they are user
    /// data, not garbage, and restore must establish new explicit ownership.
    case retained
}

// MARK: - Typed failures

public enum C07DataExchangeError: Error, Equatable, Sendable {
    case invalidManifest(String)
    case unsupportedFormat(String)
    case unsupportedVersion(Int)
    case unsafePath(String)
    case duplicateEntry(String)
    case caseCollision(String)
    case entryTooLarge(String)
    case totalTooLarge
    case tooManyEntries
    case hashMismatch(String)
    case sizeMismatch(String)
    case symlinkUnsupported(String)
    case specialFileUnsupported(String)
    case freeSpaceInsufficient(required: Int64, available: Int64)
    case corruptArchive(String)
    case notesArchive(String)
    case cancelled
    case storageUnavailable(String)
    case invalidScope(String)
    case credentialExcluded(String)
    case notFound
    case restoreBusy
    case restoreIncomplete
    case rollbackFailed(String)
    case unsupportedFeature(String)
    case duplicateIdentity(String)
    case referenceMissing(String)
    case artifactCollision(String)
    case documentPackage(String)
    case schemaMismatch(Int)
    case planTooLarge
}

extension C07DataExchangeError: LocalizedError {
    /// Machine-readable diagnostic only. User-facing copy lives in the
    /// feature string resources so EN/ZH stay aligned.
    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): return "invalidManifest:\(reason)"
        case .unsupportedFormat(let format): return "unsupportedFormat:\(format)"
        case .unsupportedVersion(let version): return "unsupportedVersion:\(version)"
        case .unsafePath(let path): return "unsafePath:\(path)"
        case .duplicateEntry(let path): return "duplicateEntry:\(path)"
        case .caseCollision(let path): return "caseCollision:\(path)"
        case .entryTooLarge(let path): return "entryTooLarge:\(path)"
        case .totalTooLarge: return "totalTooLarge"
        case .tooManyEntries: return "tooManyEntries"
        case .hashMismatch(let path): return "hashMismatch:\(path)"
        case .sizeMismatch(let path): return "sizeMismatch:\(path)"
        case .symlinkUnsupported(let path): return "symlinkUnsupported:\(path)"
        case .specialFileUnsupported(let path): return "specialFileUnsupported:\(path)"
        case .freeSpaceInsufficient(let required, let available):
            return "freeSpaceInsufficient:\(required):\(available)"
        case .corruptArchive(let reason): return "corruptArchive:\(reason)"
        case .notesArchive(let reason): return "notesArchive:\(reason)"
        case .cancelled: return "cancelled"
        case .storageUnavailable(let reason): return "storageUnavailable:\(reason)"
        case .invalidScope(let reason): return "invalidScope:\(reason)"
        case .credentialExcluded(let key): return "credentialExcluded:\(key)"
        case .notFound: return "notFound"
        case .restoreBusy: return "restoreBusy"
        case .restoreIncomplete: return "restoreIncomplete"
        case .rollbackFailed(let reason): return "rollbackFailed:\(reason)"
        case .unsupportedFeature(let feature): return "unsupportedFeature:\(feature)"
        case .duplicateIdentity(let identity): return "duplicateIdentity:\(identity)"
        case .referenceMissing(let reference): return "referenceMissing:\(reference)"
        case .artifactCollision(let path): return "artifactCollision:\(path)"
        case .documentPackage(let reason): return "documentPackage:\(reason)"
        case .schemaMismatch(let expected): return "schemaMismatch:\(expected)"
        case .planTooLarge: return "planTooLarge"
        }
    }

    /// Stable bridge code used by the Kotlin feature to select localized copy.
    public var code: String {
        switch self {
        case .invalidManifest: return "invalidManifest"
        case .unsupportedFormat: return "unsupportedFormat"
        case .unsupportedVersion: return "unsupportedVersion"
        case .unsafePath: return "unsafePath"
        case .duplicateEntry: return "duplicateEntry"
        case .caseCollision: return "caseCollision"
        case .entryTooLarge: return "entryTooLarge"
        case .totalTooLarge: return "totalTooLarge"
        case .tooManyEntries: return "tooManyEntries"
        case .hashMismatch: return "hashMismatch"
        case .sizeMismatch: return "sizeMismatch"
        case .symlinkUnsupported: return "symlinkUnsupported"
        case .specialFileUnsupported: return "specialFileUnsupported"
        case .freeSpaceInsufficient: return "freeSpaceInsufficient"
        case .corruptArchive: return "corruptArchive"
        case .notesArchive: return "notesArchive"
        case .cancelled: return "cancelled"
        case .storageUnavailable: return "storageUnavailable"
        case .invalidScope: return "invalidScope"
        case .credentialExcluded: return "credentialExcluded"
        case .notFound: return "notFound"
        case .restoreBusy: return "restoreBusy"
        case .restoreIncomplete: return "restoreIncomplete"
        case .rollbackFailed: return "rollbackFailed"
        case .unsupportedFeature: return "unsupportedFeature"
        case .duplicateIdentity: return "duplicateIdentity"
        case .referenceMissing: return "referenceMissing"
        case .artifactCollision: return "artifactCollision"
        case .documentPackage: return "documentPackage"
        case .schemaMismatch: return "schemaMismatch"
        case .planTooLarge: return "planTooLarge"
        }
    }
}

// MARK: - Paths

public enum C07Path {
    /// Returns the exact package-relative spelling after validation. Callers
    /// must use the returned value, never the raw input.
    @discardableResult
    public static func validateRelative(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.utf8.count <= C07DataExchangeLimits.maximumPathBytes,
              !raw.hasPrefix("/"), !raw.hasSuffix("/"),
              !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: {
                  $0.value < 32 || $0.value == 127 || CharacterSet.controlCharacters.contains($0)
              }) else {
            throw C07DataExchangeError.unsafePath(String(raw.prefix(240)))
        }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { throw C07DataExchangeError.unsafePath(raw) }
        for part in parts {
            guard !part.isEmpty, part != ".", part != "..",
                  part.utf8.count <= 255,
                  part.precomposedStringWithCanonicalMapping == String(part) else {
                throw C07DataExchangeError.unsafePath(String(raw.prefix(240)))
            }
        }
        return raw
    }

    /// Case-insensitive duplicate/collision key. The actual Android storage
    /// is case-sensitive, but package validation must also stop a package that
    /// would collide on a provider or a future case-insensitive destination.
    public static func collisionKey(_ relative: String) -> String {
        relative.precomposedStringWithCanonicalMapping.lowercased()
    }

    public static func archivePath(origin: C07ProjectOrigin,
                                   projectID: UUID,
                                   relativePath: String) -> String {
        let root = origin == .managed ? "projects" : "retained"
        return "\(root)/\(projectID.uuidString)/\(relativePath)"
    }

    public static func noteArchivePath(documentID: UUID) -> String {
        "notes/\(documentID.uuidString).\(C07DataExchangeLimits.notesExtension)"
    }

    public static let settingsArchivePath = "Settings/safe-settings.json"
    public static let manifestArchivePath = "manifest.json"
}

// MARK: - Hashing and bounded copy

public enum C07Digest {
    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func file(_ url: URL,
                            expectedSize: Int64? = nil,
                            maximum: Int64 = C07DataExchangeLimits.maximumEntryBytes)
        throws -> (sha256: String, byteCount: Int64)
    {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw C07DataExchangeError.specialFileUnsupported(url.lastPathComponent)
        }
        if let expectedSize, let size = values.fileSize, Int64(size) != expectedSize {
            throw C07DataExchangeError.sizeMismatch(url.lastPathComponent)
        }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw C07DataExchangeError.storageUnavailable("read") }
        defer { try? handle.close() }
        var hasher = SHA256()
        var count: Int64 = 0
        do {
            while let chunk = try handle.read(upToCount: C07DataExchangeLimits.copyChunkBytes),
                  !chunk.isEmpty {
                if Task.isCancelled { throw C07DataExchangeError.cancelled }
                count += Int64(chunk.count)
                guard count <= maximum else {
                    throw C07DataExchangeError.entryTooLarge(url.lastPathComponent)
                }
                hasher.update(data: chunk)
            }
        } catch let error as C07DataExchangeError {
            throw error
        } catch {
            throw C07DataExchangeError.storageUnavailable("read")
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
}

// MARK: - Manifest (write side and untrusted read side share this shape)

public struct C07ExcludedScope: Codable, Sendable, Equatable {
    public var id: String
    public var reason: String
    public var count: Int?

    public init(id: String, reason: String, count: Int? = nil) {
        self.id = id
        self.reason = reason
        self.count = count
    }
}

public struct C07BackupScope: Codable, Sendable, Equatable {
    public static let legacyIncludedIDs = [
        "managedProjects", "retainedProjects", "notesDocuments",
        "safePreferences",
    ]
    /// The 2026-10-17 v2 declaration. Kept verbatim so an archive written by
    /// that build still validates on restore after coverage expanded.
    public static let legacyV2IncludedIDs = [
        "managedProjects", "retainedProjects", "notesDocuments",
        "safePreferences", "taskGraph", "chatHistory", "runHistory",
        "actionReceipts", "canvasMediaDocuments", "appOwnedArtifacts",
        "savedSchedules", "providerConfiguration",
    ]
    public static let includedIDs = legacyV2IncludedIDs + [
        "calendarTodos", "toolResultRetention", "appArtifactFiles",
        "captureFiles", "safeRemoteConfiguration", "safeMailConfiguration",
        "voicePreferences", "canvasOpaqueCAD",
    ]

    public var included: [String]
    public var excluded: [C07ExcludedScope]
    /// Always `none`: no live SQLite/WAL file is a payload.
    public var database: String
    /// `logicalRows` for v2: typed rows read from one consistent GRDB read
    /// transaction, never a file copy. Nil in a legacy v1 package.
    public var databaseMode: String?

    public init(included: [String] = C07BackupScope.includedIDs,
                excluded: [C07ExcludedScope],
                database: String = "none",
                databaseMode: String? = "logicalRows") {
        self.included = included
        self.excluded = excluded
        self.database = database
        self.databaseMode = databaseMode
    }
}

public struct C07ProjectFileRecord: Codable, Sendable, Equatable {
    public var relativePath: String
    public var byteCount: Int64
    public var sha256: String
    /// Permission bits only (`& 0o777`); nil in older packages means 0o644.
    /// Setuid/setgid/sticky bits are never carried or applied.
    public var mode: Int?

    public init(relativePath: String, byteCount: Int64, sha256: String,
                mode: Int? = nil) {
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.mode = mode
    }
}

public struct C07ProjectRecord: Codable, Sendable, Equatable {
    public var projectID: UUID
    public var name: String
    public var origin: C07ProjectOrigin
    public var createdAt: Date?
    public var files: [C07ProjectFileRecord]
    public var directories: [String]
    /// Truthful omissions: a root that disappeared or became unsafe during
    /// export. The backup is then explicitly partial, never silently complete.
    public var warnings: [String]

    public init(projectID: UUID, name: String, origin: C07ProjectOrigin,
                createdAt: Date? = nil,
                files: [C07ProjectFileRecord] = [],
                directories: [String] = [],
                warnings: [String] = []) {
        self.projectID = projectID
        self.name = name
        self.origin = origin
        self.createdAt = createdAt
        self.files = files
        self.directories = directories
        self.warnings = warnings
    }
}

public struct C07NotebookRecord: Codable, Sendable, Equatable {
    public var notebookID: UUID
    public var title: String

    public init(notebookID: UUID, title: String) {
        self.notebookID = notebookID
        self.title = title
    }
}

public struct C07NoteDocumentRecord: Codable, Sendable, Equatable {
    public var documentID: UUID
    public var notebookID: UUID?
    public var title: String
    public var byteCount: Int64
    public var sha256: String

    public init(documentID: UUID, notebookID: UUID?, title: String,
                byteCount: Int64, sha256: String) {
        self.documentID = documentID
        self.notebookID = notebookID
        self.title = title
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct C07FailedNote: Codable, Sendable, Equatable {
    public var documentID: UUID
    public var title: String
    public var reason: String

    public init(documentID: UUID, title: String, reason: String) {
        self.documentID = documentID
        self.title = title
        self.reason = reason
    }
}

public struct C07NotesRecord: Codable, Sendable, Equatable {
    public var notebooks: [C07NotebookRecord]
    public var documents: [C07NoteDocumentRecord]
    /// Trash is not silently dropped: the count is declared and the UI shows
    /// it in the scope review.
    public var trashedDocumentsExcluded: Int
    public var failedDocuments: [C07FailedNote]

    public init(notebooks: [C07NotebookRecord],
                documents: [C07NoteDocumentRecord],
                trashedDocumentsExcluded: Int = 0,
                failedDocuments: [C07FailedNote] = []) {
        self.notebooks = notebooks
        self.documents = documents
        self.trashedDocumentsExcluded = trashedDocumentsExcluded
        self.failedDocuments = failedDocuments
    }
}

/// Display metadata only. No provider/model identifier is an authority and no
/// secretRef/API key/base path is carried. Restore never auto-creates a
/// provider: the entry is a disabled "needs credential" reminder.
public struct C07ProviderAdvisory: Codable, Sendable, Equatable {
    public var displayName: String
    public var wireProtocol: String
    public var baseURLHost: String?
    public var modelNames: [String]
    public var requiresCredential: Bool

    public init(displayName: String, wireProtocol: String,
                baseURLHost: String?, modelNames: [String]) {
        self.displayName = String(displayName.prefix(160))
        self.wireProtocol = String(wireProtocol.prefix(64))
        self.baseURLHost = baseURLHost.map { String($0.prefix(240)) }
        self.modelNames = Array(modelNames.prefix(64).map { String($0.prefix(160)) })
        self.requiresCredential = true
    }
}

public struct C07SettingsRecord: Codable, Sendable, Equatable {
    /// Nil when the allowlist produced no values. A present entry must decode
    /// as a JSON object of string values whose keys are exactly `keys`.
    public var entry: String?
    public var byteCount: Int64
    public var sha256: String?
    public var keys: [String]
    public var providerCatalog: [C07ProviderAdvisory]

    public init(entry: String?, byteCount: Int64, sha256: String?,
                keys: [String], providerCatalog: [C07ProviderAdvisory]) {
        self.entry = entry
        self.byteCount = byteCount
        self.sha256 = sha256
        self.keys = keys
        self.providerCatalog = providerCatalog
    }
}

public struct C07EntryReference: Codable, Sendable, Equatable {
    public var entry: String
    public var byteCount: Int64
    public var sha256: String

    public init(entry: String, byteCount: Int64, sha256: String) {
        self.entry = entry
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct C07ArtifactCatalog: Codable, Sendable, Equatable {
    public var format: String
    public var formatVersion: Int
    public var records: [C07ArtifactRecord]

    public init(format: String = "floe.artifacts",
                formatVersion: Int = 1,
                records: [C07ArtifactRecord]) {
        self.format = format
        self.formatVersion = formatVersion
        self.records = records
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> C07ArtifactCatalog {
        guard data.count <= C07DataExchangeLimits.maximumManifestBytes else {
            throw C07DataExchangeError.entryTooLarge("artifactCatalog")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(C07ArtifactCatalog.self, from: data) }
        catch { throw C07DataExchangeError.invalidManifest("artifactCatalogDecode") }
    }

    public func validate() throws {
        guard format == "floe.artifacts",
              formatVersion == 1,
              records.count <= C07OwnedDataLimits.maximumArtifacts else {
            throw C07DataExchangeError.invalidManifest("artifactCatalog")
        }
        var entries = Set<String>()
        var total: Int64 = 0
        for record in records {
            let expectedEntry = try C07ArtifactPath.entry(
                role: record.role, containerID: record.containerID,
                ownerID: record.ownerID, logicalPath: record.logicalPath)
            guard expectedEntry == record.entry,
                  entries.insert(C07Path.collisionKey(record.entry)).inserted,
                  record.byteCount >= 0,
                  record.byteCount <= C07OwnedDataLimits.maximumArtifactBytes,
                  C07SHA256Hex.isSHA256(record.sha256) else {
                throw C07DataExchangeError.invalidManifest(
                    "artifactRecord:\(record.entry)")
            }
            total += record.byteCount
            guard total <= C07OwnedDataLimits.maximumArtifactTotal else {
                throw C07DataExchangeError.totalTooLarge
            }
        }
    }
}

public struct C07BackupManifest: Codable, Sendable, Equatable {
    public var format: String
    public var formatVersion: Int
    public var createdAt: Date
    public var appSchemaVersion: Int
    public var scope: C07BackupScope
    public var projects: [C07ProjectRecord]
    public var notes: C07NotesRecord
    public var settings: C07SettingsRecord
    /// v2 owned-data manifest reference. Nil in a legacy v1 package.
    public var dataManifest: C07EntryReference?
    /// v2 Canvas/media/attachment/receipt artifact catalog reference.
    public var artifactCatalog: C07EntryReference?
    /// Non-fatal export failures already reflected in the component records.
    public var warnings: [String]

    public init(format: String = C07DataExchangeLimits.backupFormat,
                formatVersion: Int = C07DataExchangeLimits.backupFormatVersion,
                createdAt: Date = Date(),
                appSchemaVersion: Int,
                scope: C07BackupScope,
                projects: [C07ProjectRecord],
                notes: C07NotesRecord,
                settings: C07SettingsRecord,
                dataManifest: C07EntryReference? = nil,
                artifactCatalog: C07EntryReference? = nil,
                warnings: [String] = []) {
        self.format = format
        self.formatVersion = formatVersion
        self.createdAt = createdAt
        self.appSchemaVersion = appSchemaVersion
        self.scope = scope
        self.projects = projects
        self.notes = notes
        self.settings = settings
        self.dataManifest = dataManifest
        self.artifactCatalog = artifactCatalog
        self.warnings = warnings
    }

    private enum CodingKeys: String, CodingKey {
        case format, formatVersion, createdAt, appSchemaVersion, scope
        case projects, notes, settings, dataManifest, artifactCatalog, warnings
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        appSchemaVersion = try values.decode(Int.self, forKey: .appSchemaVersion)
        scope = try values.decode(C07BackupScope.self, forKey: .scope)
        projects = try values.decode([C07ProjectRecord].self, forKey: .projects)
        notes = try values.decode(C07NotesRecord.self, forKey: .notes)
        settings = try values.decode(C07SettingsRecord.self, forKey: .settings)
        dataManifest = try values.decodeIfPresent(
            C07EntryReference.self, forKey: .dataManifest)
        artifactCatalog = try values.decodeIfPresent(
            C07EntryReference.self, forKey: .artifactCatalog)
        warnings = try values.decodeIfPresent(
            [String].self, forKey: .warnings) ?? []
    }

    /// Canonical, deterministic encoding used for the manifest entry and its
    /// recorded digest.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> C07BackupManifest {
        guard data.count <= C07DataExchangeLimits.maximumManifestBytes else {
            throw C07DataExchangeError.entryTooLarge(C07Path.manifestArchivePath)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(C07BackupManifest.self, from: data) }
        catch { throw C07DataExchangeError.invalidManifest("decode") }
    }
}

// MARK: - Scope and settings policy (fixed, not archive-controlled)

public enum C07ScopePolicy {
    /// V2 full owned-data scope. Every exclusion is explicit; an archive can
    /// never shrink the declared scope silently.
    public static let excluded: [C07ExcludedScope] = [
        .init(id: "appDatabase", reason: "logicalRowsOnlyNoLiveSQLiteOrWALCopy"),
        .init(id: "notesDatabase", reason: "portableDocumentsOnly"),
        .init(id: "credentials", reason: "neverExported"),
        .init(id: "deviceKeys", reason: "deviceBound"),
        .init(id: "sessionSecrets", reason: "neverExported"),
        .init(id: "cookies", reason: "neverExported"),
        .init(id: "cloudKeys", reason: "neverExported"),
        .init(id: "approvalGrants", reason: "currentAuthorizationNeverRestored"),
        .init(id: "taskPolicies", reason: "permissionsNeverRestored"),
        .init(id: "executionTargetAuthorization", reason: "evidenceOnlyNotLiveAuthorization"),
        .init(id: "remoteHostTrust", reason: "hostsAndKnownHostsNeverRestored"),
        .init(id: "externalWorkspaceTokens", reason: "regrantRequired"),
        .init(id: "browserSessions", reason: "cookiesAndSessionState"),
        .init(id: "mailCredentials", reason: "mailOwnerSecrets"),
        .init(id: "mailDraftsAndTransfers", reason: "notReadOnlyReceipts"),
        .init(id: "runCheckpointsAndPendingInputs", reason: "noRunResume"),
        .init(id: "mediaGenerationJobs", reason: "notReplayed"),
        .init(id: "mediaGenerationCandidates", reason: "generationOwner"),
        .init(id: "creativeAssetIndex", reason: "derivedMediaIndex"),
        .init(id: "canvasRunContexts", reason: "runResumeState"),
        .init(id: "personalizationMemory",
              reason: "separateMemoryAuthorityNotInThisPackage"),
        .init(id: "skillsLibrary", reason: "reinstallableSkillPackages"),
        .init(id: "taskChecklistRevisions", reason: "runPlanStateNotResumable"),
        .init(id: "modelPreferences", reason: "derivedUiChoice"),
        .init(id: "workspaceRecentFiles", reason: "derivedUiHistory"),
        .init(id: "runDependencies", reason: "executionGraphNotResumable"),
        // C02 continuity is execution-control state, not reusable user data:
        // a pause marker carries a root epoch/fingerprint and a
        // resumeInProgress CAS claim. Restoring it under new ids would let a
        // historical task look resumable; the table is deliberately absent
        // from the C07 graph and never recreated. Nonterminal runs are
        // restored as `interrupted` with no marker or target pin.
        .init(id: "taskContinuityExecutionControl",
              reason: "pauseMarkersRootFingerprintsAndResumeCASNeverRestored"),
        .init(id: "realtimeSync", reason: "explicitExchangeOnly"),
        .init(id: "systemPersonalData", reason: "notAppOwned"),
        .init(id: "externalFileBookmarks", reason: "regrantRequired"),
        .init(id: "voiceTransientStaging", reason: "tenMinuteStagingNotDurable"),
        .init(id: "privilegedPacketCaptureBuffers", reason: "rootOwnerNotAppData"),
        .init(id: "rdpTrustPins", reason: "freshTrustRequired"),
        .init(id: "toolResultExecutionReplay", reason: "captureOnlyNeverReExecuted"),
        .init(id: "cadEditingKernel", reason: "opaqueReadOnlyPreservationOnly"),
        .init(id: "environmentImages", reason: "c01CheckpointPortRequired"),
        .init(id: "trash", reason: "declaredSeparately"),
    ]

    public static func validate(_ scope: C07BackupScope,
                                formatVersion: Int = C07DataExchangeLimits.backupFormatVersion) throws {
        guard scope.database == "none" else {
            throw C07DataExchangeError.invalidScope("databaseMustBeNone")
        }
        let expected: [String]
        switch formatVersion {
        case 1:
            expected = C07BackupScope.legacyIncludedIDs
            guard scope.databaseMode == nil || scope.databaseMode == "none" else {
                throw C07DataExchangeError.invalidScope("legacyDatabaseMode")
            }
        case 2:
            expected = C07BackupScope.includedIDs
            guard scope.databaseMode == "logicalRows" else {
                throw C07DataExchangeError.invalidScope("databaseMode")
            }
        default:
            throw C07DataExchangeError.unsupportedVersion(formatVersion)
        }
        let provided = Set(scope.included)
        let acceptedV2 = formatVersion == 2
            && provided == Set(C07BackupScope.legacyV2IncludedIDs)
        guard scope.included.count == provided.count,
              (provided == Set(expected) && scope.included.count == expected.count)
                || acceptedV2 else {
            throw C07DataExchangeError.invalidScope("included")
        }
        let excludedIDs = Set(scope.excluded.map(\.id))
        let required: Set<String> = [
            "appDatabase", "notesDatabase", "credentials", "deviceKeys",
            "sessionSecrets", "cookies", "approvalGrants",
            "externalWorkspaceTokens", "remoteHostTrust", "cloudKeys",
        ]
        guard required.isSubset(of: excludedIDs),
              excludedIDs.count == scope.excluded.count else {
            throw C07DataExchangeError.invalidScope("excluded")
        }
    }
}

public enum C07SettingsPolicy {
    /// Only closed-prefix, non-secret UI/editor preferences are exported.
    /// Anything else is omitted and counted, never guessed to be safe.
    public static let allowedPrefixes = [
        "ui.",
        "general.",
        "editor.",
        "notes.view.",
        "canvas.view.",
        "workbench.view.",
        "shortcuts.",
    ]

    /// Exact, reviewed non-secret settings keys that do not use a broad UI
    /// prefix. `voice.settings.v1` is the C03 voice picker/preference record;
    /// it contains no credential reference (validated again below).
    public static let explicitSafeKeys: Set<String> = [
        "voice.settings.v1",
    ]

    public static let forbiddenFragments = [
        "credential", "secret", "token", "cookie", "password", "apikey",
        "api_key", "auth", "session", "bearer", "privatekey", "devicekey",
        "mail.", "remote.", "github.", "provider.",
    ]

    public static func isAllowedKey(_ key: String) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 256,
              key.unicodeScalars.allSatisfy({
                  $0.value < 128 && !CharacterSet.controlCharacters.contains($0)
              }) else { return false }
        if explicitSafeKeys.contains(key) { return true }
        let lower = key.lowercased()
        guard !forbiddenFragments.contains(where: { lower.contains($0) }) else { return false }
        return allowedPrefixes.contains(where: { lower.hasPrefix($0) })
    }

    public static func sanitize(_ values: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in values where isAllowedKey(key) {
            guard value.utf8.count <= 65_536 else { continue }
            guard let data = value.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil else { continue }
            // An object whose own keys look secret is not a safe preference.
            if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               object.keys.contains(where: { key in
                   let lower = key.lowercased()
                   return forbiddenFragments.contains(where: { lower.contains($0) })
               }) {
                continue
            }
            result[key] = value
        }
        return result
    }
}

/// Sendable chunk result for the bridge/host (tuples are not used as a
/// cross-task generic payload).
public struct C07JobReadResult: Sendable, Equatable {
    public var data: Data
    public var nextOffset: Int64
    public var totalBytes: Int64
    public var eof: Bool
    public init(data: Data, nextOffset: Int64, totalBytes: Int64, eof: Bool) {
        self.data = data
        self.nextOffset = nextOffset
        self.totalBytes = totalBytes
        self.eof = eof
    }
}

public struct C07StageAppendResult: Sendable, Equatable {
    public var receivedBytes: Int64
    public var totalBytes: Int64
    public init(receivedBytes: Int64, totalBytes: Int64) {
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }
}

// MARK: - Source descriptors (producer side only)

public struct C07SourceProject: Sendable, Equatable {
    public var projectID: UUID
    public var name: String
    public var origin: C07ProjectOrigin
    public var createdAt: Date?
    public var rootURL: URL?
    /// When non-nil the project root was missing or unsafe at export time.
    public var unavailableReason: String?

    public init(projectID: UUID, name: String, origin: C07ProjectOrigin,
                createdAt: Date? = nil, rootURL: URL? = nil,
                unavailableReason: String? = nil) {
        self.projectID = projectID
        self.name = name
        self.origin = origin
        self.createdAt = createdAt
        self.rootURL = rootURL
        self.unavailableReason = unavailableReason
    }
}

public struct C07SourceNote: Sendable, Equatable {
    public var documentID: UUID
    public var notebookID: UUID?
    public var title: String
    /// A real `.floenote` archive produced by the shared iOS-format writer.
    public var archiveURL: URL

    public init(documentID: UUID, notebookID: UUID?, title: String, archiveURL: URL) {
        self.documentID = documentID
        self.notebookID = notebookID
        self.title = title
        self.archiveURL = archiveURL
    }
}

public struct C07BackupSource: Sendable {
    public var appSchemaVersion: Int
    public var createdAt: Date
    public var projects: [C07SourceProject]
    public var notebooks: [C07NotebookRecord]
    public var notes: [C07SourceNote]
    public var trashedNotesExcluded: Int
    public var failedNotes: [C07FailedNote]
    public var settingsValues: [String: String]
    public var providerCatalog: [C07ProviderAdvisory]
    public var ownedData: C07SourceOwnedData?
    public var warnings: [String]

    public init(appSchemaVersion: Int,
                createdAt: Date = Date(),
                projects: [C07SourceProject],
                notebooks: [C07NotebookRecord],
                notes: [C07SourceNote],
                trashedNotesExcluded: Int = 0,
                failedNotes: [C07FailedNote] = [],
                settingsValues: [String: String] = [:],
                providerCatalog: [C07ProviderAdvisory] = [],
                ownedData: C07SourceOwnedData? = nil,
                warnings: [String] = []) {
        self.appSchemaVersion = appSchemaVersion
        self.createdAt = createdAt
        self.projects = projects
        self.notebooks = notebooks
        self.notes = notes
        self.trashedNotesExcluded = trashedNotesExcluded
        self.failedNotes = failedNotes
        self.settingsValues = settingsValues
        self.providerCatalog = providerCatalog
        self.ownedData = ownedData
        self.warnings = warnings
    }
}

// MARK: - Small filesystem helpers

public enum C07FileSystem {
    public static func ensureDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw C07DataExchangeError.storageUnavailable("createDirectory")
        }
    }

    public static func removeIfPresent(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public static func availableBytes(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: url.path),
              let free = attributes[.systemFreeSize] as? NSNumber else { return nil }
        return free.int64Value
    }

    public static func requireFreeSpace(at url: URL, bytes: Int64) throws {
        guard bytes >= 0 else { throw C07DataExchangeError.totalTooLarge }
        guard let available = availableBytes(at: url) else {
            throw C07DataExchangeError.storageUnavailable("freeSpace")
        }
        let required = bytes > Int64.max - C07DataExchangeLimits.freeSpaceHeadroom
            ? Int64.max
            : bytes + C07DataExchangeLimits.freeSpaceHeadroom
        guard available >= required else {
            throw C07DataExchangeError.freeSpaceInsufficient(
                required: required, available: available)
        }
    }

    public static func isRegularFile(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    public static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// Streams one verified source file into a new destination that must not
    /// already exist. The caller owns cleanup of a partial destination.
    public static func copyVerified(source: URL, destination: URL,
                                    expectedSize: Int64? = nil,
                                    maximum: Int64 = C07DataExchangeLimits.maximumEntryBytes)
        throws -> (sha256: String, byteCount: Int64)
    {
        let values = try source.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
            .contentModificationDateKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw C07DataExchangeError.specialFileUnsupported(source.lastPathComponent)
        }
        if let expectedSize, let size = values.fileSize, Int64(size) != expectedSize {
            throw C07DataExchangeError.sizeMismatch(source.lastPathComponent)
        }
        let sourceSize = values.fileSize.map { Int64($0) }
        let sourceModified = values.contentModificationDate
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) }
        catch { throw C07DataExchangeError.storageUnavailable("openSource") }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw C07DataExchangeError.storageUnavailable("createDestination")
        }
        let output: FileHandle
        do { output = try FileHandle(forWritingTo: destination) }
        catch {
            removeIfPresent(destination)
            throw C07DataExchangeError.storageUnavailable("openDestination")
        }
        var hasher = SHA256()
        var count: Int64 = 0
        do {
            defer { try? output.close() }
            while let chunk = try input.read(upToCount: C07DataExchangeLimits.copyChunkBytes),
                  !chunk.isEmpty {
                if Task.isCancelled {
                    removeIfPresent(destination)
                    throw C07DataExchangeError.cancelled
                }
                count += Int64(chunk.count)
                guard count <= maximum else {
                    removeIfPresent(destination)
                    throw C07DataExchangeError.entryTooLarge(source.lastPathComponent)
                }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
        } catch let error as C07DataExchangeError {
            removeIfPresent(destination)
            throw error
        } catch {
            removeIfPresent(destination)
            throw C07DataExchangeError.storageUnavailable("copy")
        }
        // A file that changed while it was streamed would produce a
        // manifest that is internally consistent but not a point-in-time
        // snapshot. Refuse it instead of silently mixing two revisions.
        let after = try? source.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey,
        ])
        if let sourceSize, let afterSize = after?.fileSize,
           Int64(afterSize) != sourceSize {
            removeIfPresent(destination)
            throw C07DataExchangeError.storageUnavailable("sourceChanged")
        }
        if let sourceModified, let afterModified = after?.contentModificationDate,
           afterModified != sourceModified {
            removeIfPresent(destination)
            throw C07DataExchangeError.storageUnavailable("sourceChanged")
        }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
}
