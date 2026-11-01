import Foundation
import GRDB
import FloeCore

/// Where an installed skill's bytes came from. Persistence derives this from
/// the authoritative `skills.source_url` column; a model-supplied string is
/// never used for this classification.
public enum SkillSourceTrust: String, Sendable, Codable, CaseIterable, Hashable {
    case bundled
    case officialHub
    case internalCreator
    case external
    case unknown
}

/// One trusted official publication location. Configuration identity binds to
/// the publisher repository plus the package/source path (and the installed
/// skill ID), never to a moveable commit pin: an ordinary same-publisher
/// update must keep its saved configuration.
public struct SkillOfficialSource: Sendable, Hashable, Codable {
    public var owner: String
    public var repository: String
    public var publisher: String

    public init(owner: String, repository: String, publisher: String) {
        self.owner = owner
        self.repository = repository
        self.publisher = publisher
    }
}

/// Stable installation identity for configuration scoping.
///
/// The identity namespace deliberately excludes version, content digest and
/// publication commit. Reviewed facts (content digest, source digest, commit
/// pin, reviewer identity) are carried beside it as provenance for display and
/// audit, never as the namespace. A different publisher, repository, import
/// location or URL authority produces a different identity and therefore
/// cannot inherit saved secrets.
public struct SkillInstallationIdentity: Sendable, Hashable, Codable {
    public let skillID: String
    public let installationID: String
    public let sourceBinding: String
    public let publisher: String?
    public let trust: SkillSourceTrust
    /// Reviewed content revision written by the trusted install path.
    public let reviewedDigest: String
    /// Original package digest, when known.
    public let sourceDigest: String?
    /// Immutable publication/commit pin observed at install, when known.
    public let sourcePin: String?
    /// Trusted install/review marker (for example `github-reviewed-<commit>`).
    public let rewriteModelID: String?

    public init(
        skillID: String,
        installationID: String,
        sourceBinding: String,
        publisher: String?,
        trust: SkillSourceTrust,
        reviewedDigest: String = "",
        sourceDigest: String? = nil,
        sourcePin: String? = nil,
        rewriteModelID: String? = nil
    ) {
        self.skillID = skillID
        self.installationID = installationID
        self.sourceBinding = sourceBinding
        self.publisher = publisher
        self.trust = trust
        self.reviewedDigest = reviewedDigest
        self.sourceDigest = sourceDigest
        self.sourcePin = sourcePin
        self.rewriteModelID = rewriteModelID
    }

    /// Unknown or unbound provenance is never a valid configuration
    /// namespace: without a trusted source binding the store fails closed
    /// instead of collapsing unrelated legacy imports into one identity.
    public var configurationAllowed: Bool {
        guard sourceBinding != "unbound" else { return false }
        return trust != .unknown
    }

    /// Canonical, storage-level derivation. Every input comes from the
    /// authoritative persisted skill row (written by the reviewed install
    /// path), never from a model argument.
    public static func derive(
        skillID: String,
        sourceURL: String?,
        reviewedDigest: String = "",
        sourceDigest: String? = nil,
        sourceTrackingJSON: String? = nil,
        rewriteModelID: String? = nil,
        officialSources: [SkillOfficialSource]
    ) -> SkillInstallationIdentity {
        let canonical = CanonicalSource(
            skillID: skillID,
            sourceURL: sourceURL,
            officialSources: officialSources
        )
        let installationID = FloeDigest.sha256Hex(
            Data("\(skillID)\u{1f}\(canonical.binding)".utf8)
        )
        let trackedPin = Self.trackedCommit(sourceTrackingJSON)
        return SkillInstallationIdentity(
            skillID: skillID,
            installationID: installationID,
            sourceBinding: canonical.binding,
            publisher: canonical.publisher,
            trust: canonical.trust,
            reviewedDigest: reviewedDigest,
            sourceDigest: sourceDigest,
            sourcePin: canonical.pin ?? trackedPin,
            rewriteModelID: rewriteModelID
        )
    }

    private static func trackedCommit(_ json: String?) -> String? {
        guard let json, json.utf8.count <= 16_384,
              let data = json.data(using: .utf8),
              let any = try? JSONSerialization.jsonObject(with: data),
              let object = any as? [String: Any],
              let commit = object["installedCommit"] as? String,
              commit.count == 40, commit.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return commit.lowercased()
    }

    private struct CanonicalSource {
        let binding: String
        let publisher: String?
        let trust: SkillSourceTrust
        let pin: String?

        init(
            skillID: String,
            sourceURL: String?,
            officialSources: [SkillOfficialSource]
        ) {
            guard let raw = sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty,
                  let components = URLComponents(string: raw),
                  let scheme = components.scheme?.lowercased() else {
                binding = "unbound"
                publisher = nil
                trust = .unknown
                pin = nil
                return
            }
            let host = components.host?.lowercased()
            let path = Self.canonicalPath(components.path)
            switch scheme {
            case "floe-builtin":
                let identifier = Self.canonicalPath((host ?? "") + components.path)
                binding = "builtin:\(identifier)"
                publisher = "Floe"
                trust = identifier == skillID ? .bundled : .unknown
                pin = nil
                return
            case "floe-creator":
                let identifier = Self.canonicalPath((host ?? "") + components.path)
                binding = "creator:\(identifier)"
                publisher = "local"
                trust = identifier == "local/\(skillID)" ? .internalCreator : .unknown
                pin = nil
                return
            case "floe-folder":
                // Preserve the full URL authority and path: basename-only
                // identities would collapse unrelated folder imports.
                let identifier = Self.canonicalPath((host ?? "") + components.path)
                binding = "folder:\(identifier)"
                publisher = host ?? "local"
                trust = .external
                pin = nil
                return
            case "https", "http":
                if host == "github.com",
                   let github = Self.gitHubBinding(path: path, officialSources: officialSources) {
                    binding = github.binding
                    publisher = github.publisher
                    trust = github.trust
                    pin = github.pin
                    return
                }
                var authority = host ?? ""
                if let port = components.port, port != 443, port != 80 {
                    authority += ":\(port)"
                }
                binding = "\(scheme)://\(authority)\(path)"
                publisher = host
                // Plain HTTP is not a trusted install source for
                // configuration; it fails closed like any unknown binding.
                trust = scheme == "https" ? .external : .unknown
                pin = nil
                return
            default:
                binding = "scheme:\(scheme):\(Self.canonicalPath((host ?? "") + components.path))"
                publisher = nil
                trust = .unknown
                pin = nil
            }
        }

        /// Recognizes the immutable GitHub package URL shape written by the
        /// reviewed import path (`/<owner>/<repo>/(blob|tree)/<commit>/<path>`)
        /// and drops the commit from the namespace while retaining it as a
        /// provenance pin. A plain repository URL keeps its path and is never
        /// certified official.
        private static func gitHubBinding(
            path: String,
            officialSources: [SkillOfficialSource]
        ) -> (binding: String, publisher: String, trust: SkillSourceTrust, pin: String?)? {
            let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3 else { return nil }
            let owner = parts[0].lowercased()
            let repository = parts[1].lowercased()
            if parts.count >= 5,
               parts[2] == "blob" || parts[2] == "tree",
               parts[3].count == 40,
               parts[3].allSatisfy(\.isHexDigit) {
                let kind = parts[2]
                let packagePath = parts[4...].joined(separator: "/")
                let isOfficial = officialSources.contains {
                    $0.owner.lowercased() == owner && $0.repository.lowercased() == repository
                }
                let binding = "github:\(owner)/\(repository)/\(kind)/\(packagePath)"
                if isOfficial,
                   let source = officialSources.first(where: {
                       $0.owner.lowercased() == owner && $0.repository.lowercased() == repository
                   }) {
                    return (binding, source.publisher, .officialHub, parts[3].lowercased())
                }
                return (binding, "github.com/\(owner)/\(repository)", .external, parts[3].lowercased())
            }
            let remaining = parts.dropFirst(2).joined(separator: "/")
            let binding = remaining.isEmpty
                ? "github:\(owner)/\(repository)"
                : "github:\(owner)/\(repository)/\(remaining)"
            return (binding, "github.com/\(owner)/\(repository)", .external, nil)
        }

        private static func canonicalPath(_ path: String) -> String {
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.isEmpty ? "/" : "/" + trimmed
        }
    }
}

public enum SkillConfigurationEntryKind: String, Sendable, Codable, CaseIterable, Hashable {
    case variable
    case secret
    case connection
}

public enum SkillConfigurationBindingRole: String, Sendable, Codable, CaseIterable, Hashable {
    /// Created for this exact profile field; released when no longer bound.
    case owned
    /// Explicitly reused existing credential; never deleted with the profile.
    case shared
}

public enum SkillConfigurationValidationStatus: String, Sendable, Codable, CaseIterable, Hashable {
    case validated
    case invalid
    case unsupported
}

public struct SkillConfigurationProfile: Sendable, Equatable, Identifiable, Hashable {
    public let id: UUID
    public let skillID: String
    public let installationID: String
    public let profile: String
    public let target: String
    public let revision: Int
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        skillID: String,
        installationID: String,
        profile: String,
        target: String,
        revision: Int,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.skillID = skillID
        self.installationID = installationID
        self.profile = profile
        self.target = target
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct SkillConfigurationEntry: Sendable, Equatable, Hashable {
    public let fieldKey: String
    public let kind: SkillConfigurationEntryKind
    /// Ordinary variable value only. Always nil for secret/connection rows.
    public let value: String?
    public let updatedAt: Date

    public init(
        fieldKey: String,
        kind: SkillConfigurationEntryKind,
        value: String?,
        updatedAt: Date
    ) {
        self.fieldKey = fieldKey
        self.kind = kind
        self.value = value
        self.updatedAt = updatedAt
    }
}

public struct SkillConfigurationBinding: Sendable, Equatable, Hashable {
    public let fieldKey: String
    public let credentialID: UUID
    public let role: SkillConfigurationBindingRole
    public let connectionKind: String?
    public let deviceBound: Bool
    public let createdAt: Date

    public init(
        fieldKey: String,
        credentialID: UUID,
        role: SkillConfigurationBindingRole,
        connectionKind: String?,
        deviceBound: Bool,
        createdAt: Date
    ) {
        self.fieldKey = fieldKey
        self.credentialID = credentialID
        self.role = role
        self.connectionKind = connectionKind
        self.deviceBound = deviceBound
        self.createdAt = createdAt
    }
}

public struct SkillConfigurationValidation: Sendable, Equatable, Hashable {
    public let fieldKey: String
    public let revision: Int
    public let status: SkillConfigurationValidationStatus
    public let validator: String
    public let detail: String?
    public let validatedAt: Date

    public init(
        fieldKey: String,
        revision: Int,
        status: SkillConfigurationValidationStatus,
        validator: String,
        detail: String?,
        validatedAt: Date
    ) {
        self.fieldKey = fieldKey
        self.revision = revision
        self.status = status
        self.validator = validator
        self.detail = detail
        self.validatedAt = validatedAt
    }
}

/// User/installation-owned supplemental field declaration. It is persisted
/// separately from the immutable package and never grants a capability,
/// script execution, native connection or access to an unrelated stored
/// secret. Same-source updates keep compatible declarations; a source change
/// creates a new profile and cannot inherit them.
public struct SkillConfigurationLocalDeclaration: Sendable, Equatable, Hashable {
    public let fieldKey: String
    public let kind: SkillConfigurationEntryKind
    public let valueType: String
    public let title: String?
    public let detail: String?
    public let required: Bool
    public let environmentName: String
    public let allowedValues: [String]
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        fieldKey: String,
        kind: SkillConfigurationEntryKind,
        valueType: String,
        title: String?,
        detail: String?,
        required: Bool,
        environmentName: String,
        allowedValues: [String],
        createdAt: Date,
        updatedAt: Date
    ) {
        self.fieldKey = fieldKey
        self.kind = kind
        self.valueType = valueType
        self.title = title
        self.detail = detail
        self.required = required
        self.environmentName = environmentName
        self.allowedValues = allowedValues
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Draft for a user-owned supplemental ENV declaration. The store validates
/// names/types and the service checks collisions with the installed manifest
/// before persisting. Connections are deliberately not representable.
public struct SkillLocalFieldDeclarationDraft: Sendable, Equatable, Hashable {
    public var fieldKey: String
    public var kind: SkillConfigurationEntryKind
    public var valueType: String
    public var title: String?
    public var detail: String?
    public var required: Bool
    public var environmentName: String
    public var allowedValues: [String]

    public init(
        fieldKey: String,
        kind: SkillConfigurationEntryKind,
        valueType: String = "string",
        title: String? = nil,
        detail: String? = nil,
        required: Bool = false,
        environmentName: String,
        allowedValues: [String] = []
    ) {
        self.fieldKey = fieldKey
        self.kind = kind
        self.valueType = valueType
        self.title = title
        self.detail = detail
        self.required = required
        self.environmentName = environmentName
        self.allowedValues = allowedValues
    }
}

public struct SkillConfigurationSnapshot: Sendable, Equatable {
    public let skillID: String
    public let installed: Bool
    public let currentInstallation: SkillInstallationIdentity?
    public let profile: SkillConfigurationProfile?
    public let entries: [SkillConfigurationEntry]
    public let bindings: [SkillConfigurationBinding]
    public let validations: [SkillConfigurationValidation]
    /// Supplemental declarations owned by this installation/profile/target.
    /// Values still live in `entries`/`bindings` above.
    public let localDeclarations: [SkillConfigurationLocalDeclaration]
    /// The saved profile belongs to another source (or only a previous
    /// source's profile exists). Configuration must be re-confirmed; old
    /// secret bindings are never reused for the new source.
    public let sourceChanged: Bool
    public let previousProfileCount: Int

    public init(
        skillID: String,
        installed: Bool,
        currentInstallation: SkillInstallationIdentity?,
        profile: SkillConfigurationProfile?,
        entries: [SkillConfigurationEntry],
        bindings: [SkillConfigurationBinding],
        validations: [SkillConfigurationValidation],
        localDeclarations: [SkillConfigurationLocalDeclaration] = [],
        sourceChanged: Bool,
        previousProfileCount: Int
    ) {
        self.skillID = skillID
        self.installed = installed
        self.currentInstallation = currentInstallation
        self.profile = profile
        self.entries = entries
        self.bindings = bindings
        self.validations = validations
        self.localDeclarations = localDeclarations
        self.sourceChanged = sourceChanged
        self.previousProfileCount = previousProfileCount
    }

    public func entry(_ fieldKey: String) -> SkillConfigurationEntry? {
        entries.first { $0.fieldKey == fieldKey }
    }

    public func binding(_ fieldKey: String) -> SkillConfigurationBinding? {
        bindings.first { $0.fieldKey == fieldKey }
    }
}

public struct SkillConfigurationReleasedCredentials: Sendable, Equatable {
    /// Owned credentials no longer referenced by any profile after this
    /// mutation. The caller releases them through the vault.
    public let ownedUnreferenced: [UUID]
    /// Shared credentials left untouched; another profile may still use them.
    public let sharedRetained: [UUID]

    public init(ownedUnreferenced: [UUID], sharedRetained: [UUID]) {
        self.ownedUnreferenced = ownedUnreferenced
        self.sharedRetained = sharedRetained
    }
}

public enum SkillConfigurationStoreError: Error, Sendable, Equatable, LocalizedError {
    case skillNotInstalled(String)
    case sourceUnverifiable(String)
    case profileNotFound
    case staleRevision(expected: Int, actual: Int)
    case invalidField(String)
    case invalidScope(String)
    case featureUnknown(String)
    case fieldKindMismatch(String)
    case fieldNotBound(String)
    case credentialNotFound(UUID)
    case credentialNotVaultOwned
    case credentialKindNotAllowed(String)
    case credentialAlreadyShared(UUID)
    case connectionMustBeDeviceBound(String)
    case connectionKindRequired(String)
    case invalidLocalField(String)
    case localFieldNotFound(String)
    case localFieldConflict(String)

    public var errorDescription: String? {
        switch self {
        case .skillNotInstalled(let id):
            "Skill '\(id)' is not installed."
        case .sourceUnverifiable(let id):
            "Skill '\(id)' has no trusted source binding. Reinstall or re-import it through the reviewed install path before saving configuration."
        case .profileNotFound:
            "No saved configuration profile matches that skill, profile and target."
        case .staleRevision(let expected, let actual):
            "Configuration changed (expected revision \(expected), current revision \(actual)). Re-read it before retrying."
        case .invalidField(let field):
            "Invalid configuration field: \(field)"
        case .invalidScope(let value):
            "Invalid configuration scope: \(value)"
        case .featureUnknown(let field):
            "Unknown configuration field: \(field)"
        case .fieldKindMismatch(let field):
            "Configuration field '\(field)' already has a different value kind."
        case .fieldNotBound(let field):
            "Configuration field '\(field)' is not bound to a credential."
        case .credentialNotFound(let id):
            "Credential \(id.uuidString) does not exist."
        case .credentialNotVaultOwned:
            "Only vault credentials can be bound to a skill configuration."
        case .credentialKindNotAllowed(let kind):
            "Credential kind '\(kind)' is not allowed for this field."
        case .credentialAlreadyShared(let id):
            "Credential \(id.uuidString) is already used by another skill configuration; explicit sharing is required."
        case .connectionMustBeDeviceBound(let field):
            "Connection field '\(field)' requires a device-bound, non-synchronizing credential."
        case .connectionKindRequired(let field):
            "Connection field '\(field)' requires a declared connection kind."
        case .invalidLocalField(let reason):
            "Invalid local configuration field: \(reason)"
        case .localFieldNotFound(let field):
            "No local configuration field '\(field)' exists in this profile."
        case .localFieldConflict(let reason):
            "Local configuration field conflicts with the installed skill: \(reason)"
        }
    }
}

/// Generic per-skill configuration persistence. Values and bindings are
/// transactional (single SQLite write); Keychain mutations are sequenced by
/// the service with compensating deletion so a failed metadata commit cannot
/// strand an unowned secret.
public actor SkillConfigurationStore {
    private let database: DatabaseManager
    private let officialSources: [SkillOfficialSource]

    public init(
        database: DatabaseManager,
        officialSources: [SkillOfficialSource] = []
    ) {
        self.database = database
        self.officialSources = officialSources
    }

    // MARK: - Read

    public func snapshot(
        skillID: String,
        profile: String = "default",
        target: String = "default"
    ) async throws -> SkillConfigurationSnapshot {
        try Self.validateScope(profile: profile, target: target)
        return try await database.reader { db in
            let row = try Self.skillProvenanceRow(db: db, skillID: skillID)
            let installed = row != nil
            let current = row.map {
                Self.identity(from: $0, skillID: skillID, officialSources: self.officialSources)
            }
            let profileRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM skill_config_profiles
                    WHERE skill_id = ? AND profile = ? AND target = ?
                    ORDER BY updated_at DESC
                    """,
                arguments: [skillID, profile, target]
            ).map { try Self.decodeProfile($0) }
            let chosen: SkillConfigurationProfile? = {
                guard let current else { return profileRows.first }
                return profileRows.first { $0.installationID == current.installationID }
                    ?? profileRows.first
            }()
            let previousProfileCount: Int
            if let current {
                previousProfileCount = profileRows.filter { $0.installationID != current.installationID }.count
            } else {
                previousProfileCount = profileRows.count
            }
            let sourceChanged: Bool
            if let current, let chosen {
                sourceChanged = chosen.installationID != current.installationID
            } else if current != nil {
                sourceChanged = previousProfileCount > 0
            } else {
                sourceChanged = false
            }
            guard let chosen else {
                return SkillConfigurationSnapshot(
                    skillID: skillID,
                    installed: installed,
                    currentInstallation: current,
                    profile: nil,
                    entries: [],
                    bindings: [],
                    validations: [],
                    localDeclarations: [],
                    sourceChanged: sourceChanged,
                    previousProfileCount: previousProfileCount
                )
            }
            let entries = try Row.fetchAll(
                db,
                sql: "SELECT * FROM skill_config_entries WHERE profile_id = ? ORDER BY field_key",
                arguments: [chosen.id.uuidString]
            ).map { try Self.decodeEntry($0) }
            let bindings = try Row.fetchAll(
                db,
                sql: "SELECT * FROM skill_config_bindings WHERE profile_id = ? ORDER BY field_key",
                arguments: [chosen.id.uuidString]
            ).map { try Self.decodeBinding($0) }
            let validations = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM skill_config_validations
                    WHERE profile_id = ? ORDER BY field_key, revision DESC
                    """,
                arguments: [chosen.id.uuidString]
            ).map { try Self.decodeValidation($0) }
            let localDeclarations = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM skill_config_local_declarations
                    WHERE profile_id = ? ORDER BY field_key
                    """,
                arguments: [chosen.id.uuidString]
            ).map { try Self.decodeLocalDeclaration($0) }
            return SkillConfigurationSnapshot(
                skillID: skillID,
                installed: installed,
                currentInstallation: current,
                profile: chosen,
                entries: entries,
                bindings: bindings,
                validations: validations,
                localDeclarations: localDeclarations,
                sourceChanged: sourceChanged,
                previousProfileCount: previousProfileCount
            )
        }
    }

    public func boundCredentialIDs() async throws -> Set<UUID> {
        try await database.reader { db in
            Set(
                try String.fetchAll(
                    db,
                    sql: "SELECT DISTINCT credential_id FROM skill_config_bindings"
                ).compactMap(UUID.init(uuidString:))
            )
        }
    }

    /// Every profile/field currently referencing a credential. Used by the
    /// configuration service to require explicit sharing and by the
    /// credential-card tool to avoid deleting a credential a skill depends on.
    public func bindingReferences(
        credentialID: UUID
    ) async throws -> [(profileID: UUID, fieldKey: String)] {
        try await database.reader { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT profile_id, field_key FROM skill_config_bindings
                    WHERE credential_id = ? ORDER BY profile_id, field_key
                    """,
                arguments: [credentialID.uuidString]
            ).compactMap { row in
                guard let profileID = UUID(uuidString: row["profile_id"]) else { return nil }
                let fieldKey: String = row["field_key"]
                return (profileID, fieldKey)
            }
        }
    }

    public func bindingCount(credentialID: UUID) async throws -> Int {
        try await database.reader { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM skill_config_bindings WHERE credential_id = ?",
                arguments: [credentialID.uuidString]
            ) ?? 0
        }
    }

    // MARK: - Mutations

    @discardableResult
    public func saveVariables(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        values: [String: String],
        clearedFields: [String] = [],
        expectedRevision: Int? = nil
    ) async throws -> SkillConfigurationProfile {
        try Self.validateScope(profile: profile, target: target)
        for (key, value) in values {
            guard Self.isValidFieldKey(key) else {
                throw SkillConfigurationStoreError.invalidField(key)
            }
            guard !value.isEmpty, value.utf8.count <= 4_096,
                  !value.utf8.contains(0) else {
                throw SkillConfigurationStoreError.invalidField(key)
            }
        }
        for key in clearedFields {
            guard Self.isValidFieldKey(key) else {
                throw SkillConfigurationStoreError.invalidField(key)
            }
        }
        if values.isEmpty, clearedFields.isEmpty {
            let current = try await snapshot(skillID: skillID, profile: profile, target: target)
            guard let existing = current.profile else {
                throw SkillConfigurationStoreError.profileNotFound
            }
            return existing
        }
        return try await database.writer { db in
            let (_, existing, created) = try Self.ensureProfile(
                db: db,
                skillID: skillID,
                profile: profile,
                target: target,
                officialSources: self.officialSources
            )
            try Self.checkRevision(existing, expected: expectedRevision)
            for key in values.keys.sorted() {
                if try Self.hasBinding(db: db, profileID: existing.id, fieldKey: key) {
                    throw SkillConfigurationStoreError.fieldKindMismatch(key)
                }
                let inserted = try Self.upsertVariableEntry(
                    db: db,
                    profileID: existing.id,
                    fieldKey: key,
                    value: values[key]!
                )
                guard inserted else {
                    throw SkillConfigurationStoreError.fieldKindMismatch(key)
                }
            }
            for key in clearedFields.sorted() {
                if try Self.hasBinding(db: db, profileID: existing.id, fieldKey: key) {
                    throw SkillConfigurationStoreError.fieldKindMismatch(key)
                }
                try db.execute(
                    sql: """
                        DELETE FROM skill_config_entries
                        WHERE profile_id = ? AND field_key = ? AND kind = 'variable'
                        """,
                    arguments: [existing.id.uuidString, key]
                )
            }
            return try Self.finishMutation(db: db, profileID: existing.id, created: created)
        }
    }

    @discardableResult
    public func bind(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        fieldKey: String,
        kind: SkillConfigurationEntryKind,
        connectionKind: String?,
        credentialID: UUID,
        role: SkillConfigurationBindingRole,
        allowedCredentialKinds: [CredentialKind] = [],
        expectedRevision: Int? = nil
    ) async throws -> SkillConfigurationProfile {
        try Self.validateScope(profile: profile, target: target)
        guard kind != .variable, Self.isValidFieldKey(fieldKey) else {
            throw SkillConfigurationStoreError.invalidField(fieldKey)
        }
        if kind == .connection {
            guard let connectionKind, Self.isValidConnectionKind(connectionKind) else {
                throw SkillConfigurationStoreError.connectionKindRequired(fieldKey)
            }
        } else if connectionKind != nil {
            throw SkillConfigurationStoreError.invalidField(fieldKey)
        }
        return try await database.writer { db in
            let (_, existing, created) = try Self.ensureProfile(
                db: db,
                skillID: skillID,
                profile: profile,
                target: target,
                officialSources: self.officialSources
            )
            try Self.checkRevision(existing, expected: expectedRevision)
            guard let credential = try Row.fetchOne(
                db,
                sql: """
                    SELECT kind, owner_kind, synchronizable, device_bound
                    FROM credential_records WHERE id = ?
                    """,
                arguments: [credentialID.uuidString]
            ) else {
                throw SkillConfigurationStoreError.credentialNotFound(credentialID)
            }
            let credentialOwner: String = credential["owner_kind"]
            guard credentialOwner == "vault" else {
                throw SkillConfigurationStoreError.credentialNotVaultOwned
            }
            let credentialKindValue: String = credential["kind"]
            guard let credentialKind = CredentialKind(rawValue: credentialKindValue) else {
                throw SkillConfigurationStoreError.credentialKindNotAllowed(credentialKindValue)
            }
            if !allowedCredentialKinds.isEmpty, !allowedCredentialKinds.contains(credentialKind) {
                throw SkillConfigurationStoreError.credentialKindNotAllowed(credentialKindValue)
            }
            let deviceBound: Bool = credential["device_bound"]
            let synchronizable: Bool = credential["synchronizable"]
            if kind == .connection, (!deviceBound || synchronizable) {
                throw SkillConfigurationStoreError.connectionMustBeDeviceBound(fieldKey)
            }
            if try Self.hasBinding(db: db, profileID: existing.id, fieldKey: fieldKey) {
                let existingKind = try Self.entryKind(
                    db: db,
                    profileID: existing.id,
                    fieldKey: fieldKey
                )
                guard existingKind == kind else {
                    throw SkillConfigurationStoreError.fieldKindMismatch(fieldKey)
                }
            } else if let existingKind = try Self.entryKind(
                db: db,
                profileID: existing.id,
                fieldKey: fieldKey
            ), existingKind != kind {
                throw SkillConfigurationStoreError.fieldKindMismatch(fieldKey)
            }
            if role == .owned {
                let otherBindings = try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM skill_config_bindings
                        WHERE credential_id = ? AND NOT (profile_id = ? AND field_key = ?)
                        """,
                    arguments: [credentialID.uuidString, existing.id.uuidString, fieldKey]
                ) ?? 0
                guard otherBindings == 0 else {
                    throw SkillConfigurationStoreError.credentialAlreadyShared(credentialID)
                }
            }
            try db.execute(
                sql: """
                    INSERT INTO skill_config_entries
                        (profile_id, field_key, kind, value_text, updated_at)
                    VALUES (?, ?, ?, NULL, ?)
                    ON CONFLICT(profile_id, field_key) DO UPDATE SET
                        kind = excluded.kind, value_text = NULL,
                        updated_at = excluded.updated_at
                    """,
                arguments: [existing.id.uuidString, fieldKey, kind.rawValue, Self.date(Date())]
            )
            try db.execute(
                sql: """
                    INSERT INTO skill_config_bindings
                        (profile_id, field_key, credential_id, role, connection_kind, device_bound, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(profile_id, field_key) DO UPDATE SET
                        credential_id = excluded.credential_id, role = excluded.role,
                        connection_kind = excluded.connection_kind,
                        device_bound = excluded.device_bound
                    """,
                arguments: [
                    existing.id.uuidString, fieldKey, credentialID.uuidString,
                    role.rawValue, connectionKind, deviceBound, Self.date(Date())
                ]
            )
            return try Self.finishMutation(db: db, profileID: existing.id, created: created)
        }
    }

    /// User-local supplemental declaration for an ordinary or secret ENV
    /// field. Connections are never local declarations: their supported kinds
    /// come only from compiled native adapters and the installed manifest.
    @discardableResult
    public func declareLocalField(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        draft: SkillLocalFieldDeclarationDraft,
        reservedFieldKeys: [String] = [],
        reservedEnvironmentNames: [String] = [],
        expectedRevision: Int? = nil
    ) async throws -> (
        profile: SkillConfigurationProfile,
        declaration: SkillConfigurationLocalDeclaration
    ) {
        try Self.validateScope(profile: profile, target: target)
        try Self.validateLocalDraft(
            draft,
            reservedFieldKeys: reservedFieldKeys,
            reservedEnvironmentNames: reservedEnvironmentNames
        )
        return try await database.writer { db in
            let (_, existing, created) = try Self.ensureProfile(
                db: db,
                skillID: skillID,
                profile: profile,
                target: target,
                officialSources: self.officialSources
            )
            try Self.checkRevision(existing, expected: expectedRevision)
            let reservedKeys = Set(reservedFieldKeys.map { $0.lowercased() })
            guard !reservedKeys.contains(draft.fieldKey.lowercased()) else {
                throw SkillConfigurationStoreError.localFieldConflict(
                    "'\(draft.fieldKey)' is already declared by the installed skill"
                )
            }
            let reservedEnvironment = Set(reservedEnvironmentNames.map { $0.uppercased() })
            guard !reservedEnvironment.contains(draft.environmentName.uppercased()) else {
                throw SkillConfigurationStoreError.localFieldConflict(
                    "'\(draft.environmentName)' is already declared by the installed skill"
                )
            }
            // Reuse the stored spelling when this is a case-only update of an
            // existing local field, so the primary key and the unique
            // environment index cannot drift into two rows.
            var fieldKey = draft.fieldKey
            if let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT field_key, kind FROM skill_config_local_declarations
                    WHERE profile_id = ? AND (
                        lower(field_key) = lower(?) OR upper(environment_name) = upper(?)
                    )
                    """,
                arguments: [existing.id.uuidString, draft.fieldKey, draft.environmentName]
            ) {
                let storedKey: String = row["field_key"]
                guard storedKey.caseInsensitiveCompare(draft.fieldKey) == .orderedSame else {
                    throw SkillConfigurationStoreError.localFieldConflict(
                        "environment '\(draft.environmentName)' is already used by local field '\(storedKey)'"
                    )
                }
                let storedKind: String = row["kind"]
                guard storedKind == draft.kind.rawValue else {
                    throw SkillConfigurationStoreError.localFieldConflict(
                        "field '\(storedKey)' already exists with a different kind"
                    )
                }
                fieldKey = storedKey
            }
            if let existingKind = try Self.entryKind(
                db: db,
                profileID: existing.id,
                fieldKey: fieldKey
            ), existingKind != draft.kind {
                throw SkillConfigurationStoreError.localFieldConflict(
                    "field '\(fieldKey)' already stores a different value kind"
                )
            }
            let now = Self.date(Date())
            let allowedJSON: String?
            if draft.valueType == "enumeration" {
                allowedJSON = String(
                    decoding: try JSONSerialization.data(
                        withJSONObject: draft.allowedValues,
                        options: [.sortedKeys]
                    ),
                    as: UTF8.self
                )
            } else {
                allowedJSON = nil
            }
            try db.execute(
                sql: """
                    INSERT INTO skill_config_local_declarations (
                        profile_id, field_key, kind, value_type, title, detail,
                        required, environment_name, allowed_values_json, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(profile_id, field_key) DO UPDATE SET
                        kind = excluded.kind, value_type = excluded.value_type,
                        title = excluded.title, detail = excluded.detail,
                        required = excluded.required,
                        environment_name = excluded.environment_name,
                        allowed_values_json = excluded.allowed_values_json,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    existing.id.uuidString, fieldKey, draft.kind.rawValue,
                    draft.valueType, draft.title, draft.detail, draft.required,
                    draft.environmentName, allowedJSON, now, now
                ]
            )
            let updated = try Self.finishMutation(
                db: db,
                profileID: existing.id,
                created: created
            )
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM skill_config_local_declarations
                    WHERE profile_id = ? AND field_key = ?
                    """,
                arguments: [existing.id.uuidString, fieldKey]
            ) else {
                throw FloeError.storageCorrupted("local skill configuration declaration")
            }
            return (profile: updated, declaration: try Self.decodeLocalDeclaration(row))
        }
    }

    @discardableResult
    public func removeLocalField(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        fieldKey: String,
        expectedRevision: Int? = nil
    ) async throws -> (
        profile: SkillConfigurationProfile,
        released: SkillConfigurationReleasedCredentials
    ) {
        try Self.validateScope(profile: profile, target: target)
        guard Self.isValidFieldKey(fieldKey) else {
            throw SkillConfigurationStoreError.invalidLocalField(fieldKey)
        }
        return try await database.writer { db in
            let existing = try Self.existingProfile(
                db: db,
                skillID: skillID,
                profile: profile,
                target: target,
                officialSources: self.officialSources
            )
            try Self.checkRevision(existing, expected: expectedRevision)
            let declaration = try Row.fetchOne(
                db,
                sql: """
                    SELECT field_key FROM skill_config_local_declarations
                    WHERE profile_id = ? AND lower(field_key) = lower(?)
                    """,
                arguments: [existing.id.uuidString, fieldKey]
            )
            guard let declaration else {
                throw SkillConfigurationStoreError.localFieldNotFound(fieldKey)
            }
            let storedKey: String = declaration["field_key"]
            let binding = try Self.bindingRow(db: db, profileID: existing.id, fieldKey: storedKey)
            try db.execute(
                sql: "DELETE FROM skill_config_local_declarations WHERE profile_id = ? AND field_key = ?",
                arguments: [existing.id.uuidString, storedKey]
            )
            try db.execute(
                sql: "DELETE FROM skill_config_entries WHERE profile_id = ? AND field_key = ?",
                arguments: [existing.id.uuidString, storedKey]
            )
            try db.execute(
                sql: "DELETE FROM skill_config_bindings WHERE profile_id = ? AND field_key = ?",
                arguments: [existing.id.uuidString, storedKey]
            )
            let released = try Self.releasedCredentials(
                db: db,
                deletedBindings: binding.map { [$0] } ?? []
            )
            let updated = try Self.bumpRevision(db: db, profileID: existing.id)
            return (updated, released)
        }
    }

    @discardableResult
    public func unbindField(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        fieldKey: String,
        expectedRevision: Int? = nil
    ) async throws -> (profile: SkillConfigurationProfile, released: SkillConfigurationReleasedCredentials) {
        try await unbindFields(skillID: skillID, profile: profile, target: target,
                               fieldKeys: [fieldKey], expectedRevision: expectedRevision)
    }

    /// One caller revision applies to the whole selection. No field is
    /// removed if validation or CAS fails; remaining shared bindings are
    /// counted only after every selected binding has been detached.
    @discardableResult
    public func unbindFields(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        fieldKeys: [String],
        expectedRevision: Int? = nil
    ) async throws -> (profile: SkillConfigurationProfile, released: SkillConfigurationReleasedCredentials) {
        try Self.validateScope(profile: profile, target: target)
        for key in fieldKeys where !Self.isValidFieldKey(key) {
            throw SkillConfigurationStoreError.invalidField(key)
        }
        return try await database.writer { db in
            let existing = try Self.existingProfile(
                db: db, skillID: skillID, profile: profile, target: target,
                officialSources: self.officialSources)
            try Self.checkRevision(existing, expected: expectedRevision)
            var bindings: [SkillConfigurationBinding] = []
            for key in Set(fieldKeys).sorted() {
                if let binding = try Self.bindingRow(db: db, profileID: existing.id, fieldKey: key) {
                    bindings.append(binding)
                }
                try db.execute(
                    sql: "DELETE FROM skill_config_entries WHERE profile_id = ? AND field_key = ?",
                    arguments: [existing.id.uuidString, key])
                try db.execute(
                    sql: "DELETE FROM skill_config_bindings WHERE profile_id = ? AND field_key = ?",
                    arguments: [existing.id.uuidString, key])
            }
            let released = try Self.releasedCredentials(db: db, deletedBindings: bindings)
            let updated = try Self.bumpRevision(db: db, profileID: existing.id)
            return (updated, released)
        }
    }

    @discardableResult
    public func unconfigureProfile(
        skillID: String,
        profile: String = "default",
        target: String = "default",
        expectedRevision: Int? = nil,
        expectedProfileID: UUID? = nil
    ) async throws -> SkillConfigurationReleasedCredentials {
        try Self.validateScope(profile: profile, target: target)
        return try await database.writer { db in
            let existing = try Self.existingProfile(
                db: db,
                skillID: skillID,
                profile: profile,
                target: target,
                officialSources: self.officialSources
            )
            try Self.checkRevision(existing, expected: expectedRevision)
            if let expectedProfileID, existing.id != expectedProfileID {
                throw SkillConfigurationStoreError.profileNotFound
            }
            let bindings = try Row.fetchAll(
                db,
                sql: "SELECT * FROM skill_config_bindings WHERE profile_id = ?",
                arguments: [existing.id.uuidString]
            ).map { try Self.decodeBinding($0) }
            try db.execute(
                sql: "DELETE FROM skill_config_profiles WHERE id = ?",
                arguments: [existing.id.uuidString]
            )
            return try Self.releasedCredentials(db: db, deletedBindings: bindings)
        }
    }

    public func recordValidation(
        profileID: UUID,
        fieldKey: String,
        revision: Int,
        status: SkillConfigurationValidationStatus,
        validator: String,
        detail: String?
    ) async throws {
        guard Self.isValidFieldKey(fieldKey) else {
            throw SkillConfigurationStoreError.invalidField(fieldKey)
        }
        let validator = String(validator.prefix(128))
        let detail = detail.map { String($0.prefix(500)) }
        try await database.writer { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT revision FROM skill_config_profiles WHERE id = ?",
                arguments: [profileID.uuidString]
            ) else {
                throw SkillConfigurationStoreError.profileNotFound
            }
            let current: Int = row["revision"]
            guard current == revision else {
                throw SkillConfigurationStoreError.staleRevision(expected: revision, actual: current)
            }
            guard try Self.hasBinding(db: db, profileID: profileID, fieldKey: fieldKey) else {
                throw SkillConfigurationStoreError.fieldNotBound(fieldKey)
            }
            try db.execute(
                sql: """
                    INSERT INTO skill_config_validations
                        (profile_id, field_key, revision, status, validator, detail, validated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(profile_id, field_key, revision) DO UPDATE SET
                        status = excluded.status, validator = excluded.validator,
                        detail = excluded.detail, validated_at = excluded.validated_at
                    """,
                arguments: [
                    profileID.uuidString, fieldKey, revision, status.rawValue,
                    validator, detail, Self.date(Date())
                ]
            )
        }
    }

    // MARK: - Transaction helpers

    private static func ensureProfile(
        db: Database,
        skillID: String,
        profile: String,
        target: String,
        officialSources: [SkillOfficialSource]
    ) throws -> (SkillInstallationIdentity, SkillConfigurationProfile, Bool) {
        guard let skillRow = try Self.skillProvenanceRow(db: db, skillID: skillID) else {
            throw SkillConfigurationStoreError.skillNotInstalled(skillID)
        }
        let identity = Self.identity(
            from: skillRow,
            skillID: skillID,
            officialSources: officialSources
        )
        guard identity.configurationAllowed else {
            throw SkillConfigurationStoreError.sourceUnverifiable(skillID)
        }
        let now = date(Date())
        try db.execute(
            sql: """
                INSERT INTO skill_config_installations
                    (installation_id, skill_id, source_binding, publisher, source_trust,
                     reviewed_digest, source_digest, source_pin, rewrite_model_id,
                     created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(skill_id, source_binding) DO UPDATE SET
                    publisher = excluded.publisher, source_trust = excluded.source_trust,
                    reviewed_digest = excluded.reviewed_digest,
                    source_digest = excluded.source_digest,
                    source_pin = excluded.source_pin,
                    rewrite_model_id = excluded.rewrite_model_id,
                    updated_at = excluded.updated_at
                """,
            arguments: [
                identity.installationID, skillID, identity.sourceBinding,
                identity.publisher, identity.trust.rawValue,
                identity.reviewedDigest, identity.sourceDigest,
                identity.sourcePin, identity.rewriteModelID, now, now
            ]
        )
        if let row = try Row.fetchOne(
            db,
            sql: """
                SELECT * FROM skill_config_profiles
                WHERE installation_id = ? AND profile = ? AND target = ?
                """,
            arguments: [identity.installationID, profile, target]
        ) {
            return (identity, try decodeProfile(row), false)
        }
        let profileID = UUID()
        try db.execute(
            sql: """
                INSERT INTO skill_config_profiles
                    (id, installation_id, skill_id, profile, target, revision, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 1, ?, ?)
                """,
            arguments: [
                profileID.uuidString, identity.installationID, skillID,
                profile, target, now, now
            ]
        )
        let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM skill_config_profiles WHERE id = ?",
            arguments: [profileID.uuidString]
        )
        guard let row else { throw FloeError.storageCorrupted("skill configuration profile") }
        return (identity, try decodeProfile(row), true)
    }

    private static func existingProfile(
        db: Database,
        skillID: String,
        profile: String,
        target: String,
        officialSources: [SkillOfficialSource]
    ) throws -> SkillConfigurationProfile {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT * FROM skill_config_profiles
                WHERE skill_id = ? AND profile = ? AND target = ?
                ORDER BY updated_at DESC
                """,
            arguments: [skillID, profile, target]
        ).map { try decodeProfile($0) }
        guard !rows.isEmpty else { throw SkillConfigurationStoreError.profileNotFound }
        if let skillRow = try Self.skillProvenanceRow(db: db, skillID: skillID) {
            let current = Self.identity(
                from: skillRow,
                skillID: skillID,
                officialSources: officialSources
            )
            if let matching = rows.first(where: { $0.installationID == current.installationID }) {
                return matching
            }
        }
        return rows[0]
    }

    private static func skillProvenanceRow(db: Database, skillID: String) throws -> Row? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT skills.source_url, skills.rewritten_digest, skills.source_digest,
                       skills.rewrite_model_id,
                       app_settings.value_json AS source_tracking_json
                FROM skills
                LEFT JOIN app_settings
                    ON app_settings.key = ? || skills.id
                WHERE skills.id = ?
                """,
            arguments: ["skills.update_source.", skillID]
        )
    }

    private static func identity(
        from row: Row,
        skillID: String,
        officialSources: [SkillOfficialSource]
    ) -> SkillInstallationIdentity {
        let sourceURL: String? = row["source_url"]
        let reviewedDigest: String = row["rewritten_digest"]
        let sourceDigest: String? = row["source_digest"]
        let tracking: String? = row["source_tracking_json"]
        let rewriteModelID: String? = row["rewrite_model_id"]
        return SkillInstallationIdentity.derive(
            skillID: skillID,
            sourceURL: sourceURL,
            reviewedDigest: reviewedDigest,
            sourceDigest: sourceDigest,
            sourceTrackingJSON: tracking,
            rewriteModelID: rewriteModelID,
            officialSources: officialSources
        )
    }

    private static func hasBinding(db: Database, profileID: UUID, fieldKey: String) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
                SELECT EXISTS(
                    SELECT 1 FROM skill_config_bindings WHERE profile_id = ? AND field_key = ?
                )
                """,
            arguments: [profileID.uuidString, fieldKey]
        ) ?? false
    }

    private static func entryKind(
        db: Database,
        profileID: UUID,
        fieldKey: String
    ) throws -> SkillConfigurationEntryKind? {
        try String.fetchOne(
            db,
            sql: "SELECT kind FROM skill_config_entries WHERE profile_id = ? AND field_key = ?",
            arguments: [profileID.uuidString, fieldKey]
        ).flatMap(SkillConfigurationEntryKind.init(rawValue:))
    }

    /// Returns false when an existing entry has a non-variable kind.
    private static func upsertVariableEntry(
        db: Database,
        profileID: UUID,
        fieldKey: String,
        value: String
    ) throws -> Bool {
        if let kind = try entryKind(db: db, profileID: profileID, fieldKey: fieldKey),
           kind != .variable {
            return false
        }
        try db.execute(
            sql: """
                INSERT INTO skill_config_entries (profile_id, field_key, kind, value_text, updated_at)
                VALUES (?, ?, 'variable', ?, ?)
                ON CONFLICT(profile_id, field_key) DO UPDATE SET
                    kind = 'variable', value_text = excluded.value_text,
                    updated_at = excluded.updated_at
                """,
            arguments: [profileID.uuidString, fieldKey, value, date(Date())]
        )
        return true
    }

    /// The first mutation establishes revision 1 without an extra bump; every
    /// later mutation advances the revision and invalidates older validation
    /// receipts.
    private static func finishMutation(
        db: Database,
        profileID: UUID,
        created: Bool
    ) throws -> SkillConfigurationProfile {
        if !created {
            return try bumpRevision(db: db, profileID: profileID)
        }
        try db.execute(
            sql: "UPDATE skill_config_profiles SET updated_at = ? WHERE id = ?",
            arguments: [date(Date()), profileID.uuidString]
        )
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM skill_config_profiles WHERE id = ?",
            arguments: [profileID.uuidString]
        ) else {
            throw FloeError.storageCorrupted("skill configuration profile")
        }
        return try decodeProfile(row)
    }

    private static func bumpRevision(db: Database, profileID: UUID) throws -> SkillConfigurationProfile {
        try db.execute(
            sql: """
                UPDATE skill_config_profiles
                SET revision = revision + 1, updated_at = ?
                WHERE id = ?
                """,
            arguments: [date(Date()), profileID.uuidString]
        )
        try db.execute(
            sql: """
                DELETE FROM skill_config_validations
                WHERE profile_id = ? AND revision <> (
                    SELECT revision FROM skill_config_profiles WHERE id = ?
                )
                """,
            arguments: [profileID.uuidString, profileID.uuidString]
        )
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT * FROM skill_config_profiles WHERE id = ?",
            arguments: [profileID.uuidString]
        ) else {
            throw FloeError.storageCorrupted("skill configuration profile")
        }
        return try decodeProfile(row)
    }

    private static func bindingRow(
        db: Database,
        profileID: UUID,
        fieldKey: String
    ) throws -> SkillConfigurationBinding? {
        try Row.fetchOne(
            db,
            sql: "SELECT * FROM skill_config_bindings WHERE profile_id = ? AND field_key = ?",
            arguments: [profileID.uuidString, fieldKey]
        ).map { try decodeBinding($0) }
    }

    private static func releasedCredentials(
        db: Database,
        deletedBindings: [SkillConfigurationBinding]
    ) throws -> SkillConfigurationReleasedCredentials {
        var owned: [UUID] = []
        var shared: [UUID] = []
        for binding in deletedBindings {
            switch binding.role {
            case .shared:
                shared.append(binding.credentialID)
            case .owned:
                let remaining = try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM skill_config_bindings WHERE credential_id = ?",
                    arguments: [binding.credentialID.uuidString]
                ) ?? 0
                if remaining == 0 { owned.append(binding.credentialID) }
            }
        }
        return SkillConfigurationReleasedCredentials(
            ownedUnreferenced: owned,
            sharedRetained: shared
        )
    }

    private static func checkRevision(
        _ profile: SkillConfigurationProfile,
        expected: Int?
    ) throws {
        guard let expected else { return }
        guard expected == profile.revision else {
            throw SkillConfigurationStoreError.staleRevision(
                expected: expected,
                actual: profile.revision
            )
        }
    }

    // MARK: - Row decoding

    private static func decodeProfile(_ row: Row) throws -> SkillConfigurationProfile {
        guard let id = UUID(uuidString: row["id"]) else {
            throw FloeError.storageCorrupted("skill configuration profile")
        }
        return SkillConfigurationProfile(
            id: id,
            skillID: row["skill_id"],
            installationID: row["installation_id"],
            profile: row["profile"],
            target: row["target"],
            revision: row["revision"],
            createdAt: try decodeDate(row["created_at"]),
            updatedAt: try decodeDate(row["updated_at"])
        )
    }

    private static func decodeEntry(_ row: Row) throws -> SkillConfigurationEntry {
        guard let kind = SkillConfigurationEntryKind(rawValue: row["kind"]) else {
            throw FloeError.storageCorrupted("skill configuration entry")
        }
        return SkillConfigurationEntry(
            fieldKey: row["field_key"],
            kind: kind,
            value: row["value_text"],
            updatedAt: try decodeDate(row["updated_at"])
        )
    }

    private static func decodeBinding(_ row: Row) throws -> SkillConfigurationBinding {
        guard let credentialID = UUID(uuidString: row["credential_id"]),
              let role = SkillConfigurationBindingRole(rawValue: row["role"]) else {
            throw FloeError.storageCorrupted("skill configuration binding")
        }
        return SkillConfigurationBinding(
            fieldKey: row["field_key"],
            credentialID: credentialID,
            role: role,
            connectionKind: row["connection_kind"],
            deviceBound: row["device_bound"],
            createdAt: try decodeDate(row["created_at"])
        )
    }

    private static func decodeLocalDeclaration(
        _ row: Row
    ) throws -> SkillConfigurationLocalDeclaration {
        guard let kind = SkillConfigurationEntryKind(rawValue: row["kind"]),
              kind != .connection else {
            throw FloeError.storageCorrupted("local skill configuration declaration")
        }
        let allowedJSON: String? = row["allowed_values_json"]
        let allowedValues: [String]
        if let allowedJSON,
           let data = allowedJSON.data(using: .utf8),
           let values = try? JSONSerialization.jsonObject(with: data) as? [String] {
            allowedValues = values
        } else {
            allowedValues = []
        }
        return SkillConfigurationLocalDeclaration(
            fieldKey: row["field_key"],
            kind: kind,
            valueType: row["value_type"],
            title: row["title"],
            detail: row["detail"],
            required: row["required"],
            environmentName: row["environment_name"],
            allowedValues: allowedValues,
            createdAt: try decodeDate(row["created_at"]),
            updatedAt: try decodeDate(row["updated_at"])
        )
    }

    private static func decodeValidation(_ row: Row) throws -> SkillConfigurationValidation {
        guard let status = SkillConfigurationValidationStatus(rawValue: row["status"]) else {
            throw FloeError.storageCorrupted("skill configuration validation")
        }
        return SkillConfigurationValidation(
            fieldKey: row["field_key"],
            revision: row["revision"],
            status: status,
            validator: row["validator"],
            detail: row["detail"],
            validatedAt: try decodeDate(row["validated_at"])
        )
    }

    // MARK: - Validation helpers

    private static let localValueTypes: Set<String> = [
        "string", "number", "boolean", "url", "enumeration"
    ]

    private static func validateLocalDraft(
        _ draft: SkillLocalFieldDeclarationDraft,
        reservedFieldKeys: [String],
        reservedEnvironmentNames: [String]
    ) throws {
        guard draft.kind != .connection else {
            throw SkillConfigurationStoreError.invalidLocalField(
                "connections cannot be declared locally"
            )
        }
        guard isValidFieldKey(draft.fieldKey) else {
            throw SkillConfigurationStoreError.invalidLocalField(
                "field key must be 1...64 ASCII letters, digits or underscores"
            )
        }
        guard !reservedFieldKeys.contains(where: {
            $0.caseInsensitiveCompare(draft.fieldKey) == .orderedSame
        }) else {
            throw SkillConfigurationStoreError.localFieldConflict(
                "'\(draft.fieldKey)' is reserved by the installed skill"
            )
        }
        guard localValueTypes.contains(draft.valueType) else {
            throw SkillConfigurationStoreError.invalidLocalField("unsupported value type")
        }
        guard isValidEnvironmentName(draft.environmentName) else {
            throw SkillConfigurationStoreError.invalidLocalField(
                "environment name must be 1...64 uppercase ASCII letters, digits or underscores"
            )
        }
        guard !reservedEnvironmentNames.contains(where: {
            $0.caseInsensitiveCompare(draft.environmentName) == .orderedSame
        }) else {
            throw SkillConfigurationStoreError.localFieldConflict(
                "'\(draft.environmentName)' is reserved by the installed skill"
            )
        }
        for value in [draft.title, draft.detail] {
            guard let value else { continue }
            guard value.utf8.count <= 600,
                  !value.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }) else {
                throw SkillConfigurationStoreError.invalidLocalField(
                    "title/detail contains control characters or is too long"
                )
            }
        }
        if draft.valueType == "enumeration" {
            guard !draft.allowedValues.isEmpty, draft.allowedValues.count <= 64 else {
                throw SkillConfigurationStoreError.invalidLocalField(
                    "enumeration requires 1...64 allowed values"
                )
            }
            var seen = Set<String>()
            for value in draft.allowedValues {
                guard !value.isEmpty, value.utf8.count <= 256,
                      !value.unicodeScalars.contains(where: {
                          CharacterSet.controlCharacters.contains($0)
                      }),
                      seen.insert(value).inserted else {
                    throw SkillConfigurationStoreError.invalidLocalField(
                        "invalid or duplicate allowed value"
                    )
                }
            }
        } else if !draft.allowedValues.isEmpty {
            throw SkillConfigurationStoreError.invalidLocalField(
                "allowedValues require value type enumeration"
            )
        }
    }

    private static func isValidEnvironmentName(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first),
              value.utf8.count <= 64 else { return false }
        return value.utf8.dropFirst().allSatisfy { byte in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_")
        }
    }

    private static func validateScope(profile: String, target: String) throws {
        try validateScopeComponent(profile, allowColon: false)
        // The App target resolver owns canonical task targets such as
        // `local-ios`, `local-linux`, `local-mac` and `ssh:<hostUUID>`.
        try validateScopeComponent(target, allowColon: true)
    }

    private static func validateScopeComponent(_ value: String, allowColon: Bool) throws {
        guard let first = value.utf8.first,
              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first),
              value.utf8.count <= 64 else {
            throw SkillConfigurationStoreError.invalidScope(value)
        }
        guard value.utf8.allSatisfy({ byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "_")
                || byte == UInt8(ascii: "-")
                || (allowColon && byte == UInt8(ascii: ":"))
        }) else {
            throw SkillConfigurationStoreError.invalidScope(value)
        }
    }

    private static func isValidFieldKey(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first),
              value.utf8.count <= 64 else { return false }
        return value.utf8.dropFirst().allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "_")
        }
    }

    private static func isValidConnectionKind(_ value: String) -> Bool {
        guard let first = value.utf8.first,
              (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first),
              value.utf8.count <= 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "_")
        }
    }

    private static func date(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }

    private static func decodeDate(_ value: String) throws -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value) else {
            throw FloeError.storageCorrupted("skill configuration date")
        }
        return date
    }
}
