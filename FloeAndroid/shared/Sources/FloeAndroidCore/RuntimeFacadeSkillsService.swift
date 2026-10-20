// SPDX-License-Identifier: MPL-2.0
//
// RB-6 skills domain — the REAL Skills administration service behind the
// frozen `skills.list` / `skills.install` / `skills.uninstall` command rules
// (private source candidate; NOT compiled, NOT executed, NOT registered by
// this package).
//
// Reuse (service-map "reuse"/"reuse-global"; FloeSkills and the SkillStore
// are BYTE-IDENTICAL ports verified against FloeAgent/Sources — provenance/
// PINS.json):
// * SkillPackageValidator — the ONLY structural/traversal/symlink/size/
//   schema/native-payload gate: validate(packageAt:requireManifest:
//   manifestOverride:), parseSkillMarkdown(_:), canonicalDigest(files:).
// * SkillInstallStagingService — the install funnel itself: validate →
//   staged copy → RE-validate → digest gate → atomic move → metadata
//   SECOND (SkillInstallationMetadataStore) → full rollback of the prior
//   valid version on failure (:138-150). Never re-implemented here.
// * SignedContentArchive/OfficialSkillHub.unpack/stage — hub ZIP gates.
// * SkillContentSnapshot — immutable-bytes snapshot bases for upgrades.
// * GitHubSkillDownload.stage + SkillUpgradeCandidate — original upgrade
//   staging/diff. The module-internal verifiedSource init stays UNREACHABLE
//   from here: an app-callable path cannot manufacture an official update
//   (public init rejects official ids, SkillUpgrade.swift:76-77).
// * SQLiteSkillStore — the ONE original DB's skills/skill_permissions tables
//   with digest CAS; permission rows are only re-persisted as objects READ
//   (the type is Codable but has no public initializer by design — the
//   journal round-trips through JSONDecoder, never a fabricated init).
// * SkillCompatibility.evaluate + SkillAutomaticInstallPolicy +
//   SkillIdentifier + SkillManageTool.validateID/ManagedSkill/SkillCreating
//   /SkillManaging — called through their ORIGINAL public APIs.
//
// ios-reference extractions (behavior mirrored; the App class is NEVER
// imported): SkillsCenter install funnel (:938-1021), pending-installation
// review confirm/cancel (:550-628), upgrade journal + apply/restore/rollback
// (:110-350), recoverable RemovedSkills backup (:716-728), FinderEnvelope
// path-safe materialize (:1120-1149), identifier transliteration
// (:1188-1199), auto-apply gate (:83-106), hourly catalog gate (:44-49),
// official new-install auto-apply NEVER widens permissions (:99-106).
//
// ANDROID DELTAS (narrow, evidence-pinned in provenance/CLASSIFICATION.md):
// 1. SkillRuntimeEnvironment.platform is `.linux` (the overlay is the Linux
//    family Swift runtime; iOS hardcodes `.iOS` at SkillsCenter:1166).
//    Consequence kept honest: manifests declaring only platforms:["ios"]
//    evaluate INCOMPATIBLE and are refused with the ORIGINAL problem
//    vocabulary — never silently widened. Product re-authoring is Main's.
// 2. registeredTools come from ToolRunnerRegistry.shared.allDescriptors
//    (availability-filtered RUNTIME truth) instead of the compile-time
//    ToolCatalog list (SkillsCenter:1169): "discover/usable" must reflect
//    what THIS device can actually run; no Play-absent/G03 capability is
//    listed or advertised.
// 3. UserDefaults/NSUbiquitousKeyValueStore-backed values (the auto-scripted
//    updates toggle) map onto the canonical SINGLE existing app_settings
//    table via SQLiteSettingsStore under the ORIGINAL key string
//    (ContentUpdateCenter.scriptedAutoInstallDefaultsKey =
//    "floe.content.update.autoScriptedSkills", ContentUpdateCenter.swift:125)
//    — the same provenance pattern RB2 documented for
//    WebSearchSettingsCenter.defaultsKey (RuntimeFacadeConfigModels.swift
//    :402-439). No second store; the Settings UI toggle itself stays in the
//    settings domain parity plan; only the ONE canonical value is projected.
// 4. appVersion (Bundle.main CFBundleShortVersionString on iOS) arrives
//    through the trusted host seam SkillsHostContextProviding, bounded to a
//    dotted numeric version; unbound ⇒ official/catalog flows refuse typed
//    needsConfiguration BEFORE any network or file effect.
// 5. Finder model rewrite requires the bound SkillModelRewriting port (RB4/
//    qualified provider routing). Unbound ⇒ a rewrite-requiring request
//    refuses BEFORE any network or file effect — never a silently skipped
//    rewrite. rewriteModelID == nil ⇒ no rewrite, full original validation
//    still gates the package.
// 6. ManagedPythonPackageInspector (FloeExecution) is not in the overlay.
//    It is UNREACHABLE for accepted Android installs: every manifest with
//    pythonPackages requires the remote runtime pairing (validator
//    :446-447) and the G02 environment has no remote execution ⇒
//    compatibility refuses first. No wheel-audit is faked.
// 7. Review tokens are domain-minted opaque ids bound to the CURRENT root
//    generation. The Kotlin holder's UI reviewId fences locally; the host
//    maps it onto this wire token (binding-map installReview fence).
// 8. Install staging trees live OUTSIDE the installation root (the original
//    staging service enforces sourceMustBeTemporary, SkillInstallStaging
//    Service.swift:94-96): the host supplies a scratch root; the removed
//    backup stays at installationRoot/../RemovedSkills and the upgrade
//    journal at installationRoot/.upgrade-history — the ORIGINAL relative
//    locations under a trusted root (SkillsCenter:342-346, :716).
//
// Permission honesty: signature/structure/validation NEVER grants tool
// permission. The ORIGINAL permission store remains the only authority;
// install persists the declared ceiling exactly as the original
// InitialSkillMetadata does (:1018 store.save(skill, grantCapabilities:
// declared)), and every runtime use re-intersects granted ∩ declared ∩
// registered. Imported SKILL.md text, MCP schemas and model output are
// untrusted data. "Queue accepted == installed" is impossible here: a
// staged review returns committed == false; only the staging-service +
// store chain returning a SkillInstallationRecord produces committed state.
import Foundation
import Crypto
import FloeCore
import FloeSkills
import FloeTools
import FloePersistence

// MARK: - Trusted host seams (Main binds; honest-unavailable defaults)

/// Bounded app version + accepted-root identity for the ORIGINAL signed
/// content gates and the root-generation binding every RB6 object records.
public protocol SkillsHostContextProviding: Sendable {
    /// Semantic version "major.minor[.patch]" (≤64 ASCII digits/dots).
    /// nil until the trusted host binds it — catalog/official flows refuse
    /// typed needsConfiguration before any effect.
    func appVersion() -> String?
    /// The CURRENT accepted root fingerprint for the epoch (from the trusted
    /// host that called `AndroidRuntimeBootstrap.start`). Never envelope-fed.
    func rootFingerprint(epoch: UInt64) -> String?
}

public struct SkillsHostContextUnavailable: SkillsHostContextProviding {
    public init() {}
    public func appVersion() -> String? { nil }
    public func rootFingerprint(epoch: UInt64) -> String? { nil }
}

/// GitHub hub fetch transport. Production binds the ORIGINAL WebTools
/// bounded HTTP path (RuntimeFacadeSkillsTransport.swift — the qualified
/// FloeAndroidWebTools session over FloeTransport, NOT a second simple-HTTP
/// tool). Private/connector-credential fetch (the iOS
/// SourceControlCenter.skillRepositoryData path) remains a declared
/// unavailable host/G03 dependency: fetch refuses typed BEFORE any effect
/// while the capability definition is retained.
public protocol SkillsRemoteTransport: Sendable {
    func resolveCommit(_ source: GitHubSkillSource) async throws -> String
    func fetch(_ source: GitHubSkillSource, commit: String, path: String) async throws -> Data
    func fetchFinderEnvelope(url: URL) async throws -> Data
}

public struct SkillsRemoteTransportUnavailable: SkillsRemoteTransport {
    public init() {}
    public func resolveCommit(_ source: GitHubSkillSource) async throws -> String {
        throw SkillsDomainRefusal.transportUnavailable
    }
    public func fetch(_ source: GitHubSkillSource, commit: String, path: String) async throws -> Data {
        throw SkillsDomainRefusal.transportUnavailable
    }
    public func fetchFinderEnvelope(url: URL) async throws -> Data {
        throw SkillsDomainRefusal.transportUnavailable
    }
}

/// Finder model rewrite seam (ORIGINAL contract SkillsCenter
/// rewriteForCurrentDevice :1043-1114 — provider stream, no tools, 512 KiB
/// output cap; may only SHRINK capabilities/tools; files byte-identical,
/// re-verified here).
public protocol SkillModelRewriting: Sendable {
    func rewrite(markdown: String, manifestJSON: Data?,
                 modelID: String) async throws -> SkillModelRewrite
}

public struct SkillModelRewrite: Sendable {
    public let markdown: String
    public let manifestJSON: Data?
    public init(markdown: String, manifestJSON: Data?) {
        self.markdown = markdown
        self.manifestJSON = manifestJSON
    }
}

public struct SkillModelRewritingUnavailable: SkillModelRewriting {
    public init() {}
    public func rewrite(markdown: String, manifestJSON: Data?,
                        modelID: String) async throws -> SkillModelRewrite {
        throw SkillsDomainRefusal.rewriteUnavailable
    }
}

/// Typed domain refusals; the router maps them onto frozen wire codes.
public enum SkillsDomainRefusal: Error, Sendable, Equatable {
    case runtimeNotReady
    case staleGeneration
    case transportUnavailable
    case rewriteUnavailable
    case appVersionUnbound
}

// MARK: - Finder envelope (ios-reference extraction, closed)

/// Field-identical mirror of the ORIGINAL private FinderEnvelope
/// (SkillsCenter.swift:1245-1271) — a narrow extraction of App-side code the
/// overlay cannot import, NOT a new format.
public struct FinderSkillEnvelope: Sendable {
    public struct PayloadFile: Sendable {
        public let base64: String
        public let mimeType: String
    }
    public let skillMarkdown: String
    public let manifest: Data?
    public let files: [String: PayloadFile]

    /// The ORIGINAL envelope cap (SkillsCenter:454-455).
    public static let maximumEnvelopeBytes = 262_144
    public static let allowedTopKeys: Set<String> =
        ["SKILL.md", "floe.json", "references", "assets", "scripts", "agents"]

    public static func decode(_ data: Data) throws -> FinderSkillEnvelope {
        guard data.count <= maximumEnvelopeBytes else {
            throw SkillValidationError.packageTooLarge(limit: maximumEnvelopeBytes)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SkillValidationError.invalidFrontmatter("finderEnvelope")
        }
        guard Set(object.keys).isSubset(of: ["skillMarkdown", "manifest", "files"]),
              let markdown = object["skillMarkdown"] as? String, !markdown.isEmpty else {
            throw SkillValidationError.invalidFrontmatter("finderEnvelope")
        }
        var manifestJSON: Data?
        switch object["manifest"] {
        case .none, is NSNull:
            manifestJSON = nil
        case let manifestObject as [String: Any]:
            guard JSONSerialization.isValidJSONObject(manifestObject) else {
                throw SkillValidationError.invalidManifest("finderManifest")
            }
            manifestJSON = try? JSONSerialization.data(withJSONObject: manifestObject,
                                                      options: [.sortedKeys])
        default:
            throw SkillValidationError.invalidManifest("finderManifest")
        }
        var files: [String: PayloadFile] = [:]
        if let filesObject = object["files"] as? [String: Any] {
            guard filesObject.count <= 256 else {
                throw SkillValidationError.tooManyFiles(limit: 256)
            }
            for (path, value) in filesObject {
                try validateRelativePath(path)
                guard let entry = value as? [String: Any],
                      Set(entry.keys).isSubset(of: ["data", "mimeType"]),
                      let encoded = entry["data"] as? String,
                      let decoded = Data(base64Encoded: encoded,
                                         options: [.ignoreUnknownCharacters]),
                      decoded.count <= 2_097_152 else {
                    throw SkillValidationError.unsafePath(path)
                }
                let mime = (entry["mimeType"] as? String) ?? "application/octet-stream"
                files[path] = PayloadFile(base64: encoded, mimeType: mime)
            }
        }
        return FinderSkillEnvelope(skillMarkdown: markdown, manifest: manifestJSON, files: files)
    }

    /// The ORIGINAL path-safety rule (materialize :1120-1149 + validator
    /// relative-path :231-246): non-empty, no leading "/", no "\", no "..",
    /// no NUL, UTF-8 ≤512, top-level entry inside allowedTopKeys.
    public static func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              path.utf8.count <= 512, !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        else { throw SkillValidationError.unsafePath(path) }
        let top = String(path.split(separator: "/", omittingEmptySubsequences: false).first ?? "")
        guard allowedTopKeys.contains(top) else { throw SkillValidationError.unsafePath(path) }
    }

    public func materialize(into packageRoot: URL, fileManager: FileManager) throws {
        var written: [String] = []
        do {
            try write(Data(skillMarkdown.utf8), to: "SKILL.md", in: packageRoot,
                      fileManager: fileManager)
            written.append("SKILL.md")
            if let manifest {
                try write(manifest, to: "floe.json", in: packageRoot,
                          fileManager: fileManager)
                written.append("floe.json")
            }
            for (path, file) in files {
                guard let bytes = Data(base64Encoded: file.base64,
                                       options: [.ignoreUnknownCharacters]) else {
                    throw SkillValidationError.unsafePath(path)
                }
                try write(bytes, to: path, in: packageRoot, fileManager: fileManager)
                written.append(path)
            }
        } catch {
            for path in written {
                try? fileManager.removeItem(at: packageRoot.appendingPathComponent(path))
            }
            throw error
        }
    }

    private func write(_ data: Data, to relativePath: String, in root: URL,
                       fileManager: FileManager) throws {
        try Self.validateRelativePath(relativePath)
        let url = root.appendingPathComponent(relativePath)
        let directory = url.deletingLastPathComponent()
        if directory.path != root.path {
            guard directory.standardizedFileURL.path
                .hasPrefix(root.standardizedFileURL.path + "/") else {
                throw SkillValidationError.unsafePath(relativePath)
            }
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Persisted review state

struct SkillsReview: Sendable {
    enum Kind: Sendable {
        /// `manifestOverride` is the ORIGINAL sidecar/derived-manifest
        /// mechanism (prepareCanonicalPackage override → installRewritten
        /// Package(manifestOverride:)): a staged tree WITHOUT floe.json on
        /// disk commits with the manifest derived by the validator, exactly
        /// like the original Finder/traditional path.
        case install(stagedPackageURL: URL, canonicalSHA256: String,
                     sourceURL: String, sourceDigest: String?,
                     rewriteModelID: String, manifestOverride: SkillManifest?)
        case upgrade(candidate: SkillUpgradeCandidate, stagingRoot: URL)
    }
    let token: String
    let skillID: String
    let createdAtEpoch: UInt64
    let kind: Kind
}

extension SkillsReview {
    /// Closed projection vocabulary for the skills.list pending-review rows
    /// (never a raw path, never content).
    var kindName: String {
        switch kind {
        case .install: return "install"
        case .upgrade: return "upgrade"
        }
    }
    /// The honest CAS value the confirm/discard command must echo (the
    /// staged canonical digest, or the upgrade base digest).
    var expectedDigest: String {
        switch kind {
        case .install(_, let canonical, _, _, _, _): return canonical
        case .upgrade(let candidate, _): return candidate.expectedInstalledDigest
        }
    }
}

/// Bounded result of a staging/confirm step. `committed == true` only after
/// the ORIGINAL staging-service + store chain REALLY landed; staged reviews
/// always report committed == false (no "queue accepted == installed").
public struct SkillsReviewProjection: Sendable {
    public let token: String
    public let skillID: String
    public let version: String
    public let committed: Bool
    public let changedFiles: [String]
    public let addedCapabilities: [String]
    public let addedTools: [String]
    public let releaseNotes: [String: String]

    public init(token: String, skillID: String, version: String, committed: Bool,
                changedFiles: [String], addedCapabilities: [String],
                addedTools: [String], releaseNotes: [String: String]) {
        self.token = token
        self.skillID = skillID
        self.version = version
        self.committed = committed
        self.changedFiles = changedFiles
        self.addedCapabilities = addedCapabilities
        self.addedTools = addedTools
        self.releaseNotes = releaseNotes
    }

    public func jsonObject() -> sending [String: Any] {
        ["reviewToken": committed ? NSNull() : token,
         "skillID": skillID,
         "version": version,
         "committed": committed,
         "changedFiles": changedFiles,
         "addedCapabilities": addedCapabilities,
         "addedTools": addedTools,
         "releaseNotes": releaseNotes]
    }
}

/// Host-issued folder staging contract (RB7 SAF handoff). The wire NEVER
/// carries a path: the host copies the picked tree into the domain scratch
/// root, then calls `registerStagedFolder` through this module API. Only the
/// opaque `stg:v1:` token may re-enter the wire. Arrival installs NOTHING.
public struct SkillsFolderStagingReceipt: Sendable, Equatable {
    public let canonicalSHA256: String   // validator canonicalDigest over files
    public let fileCount: Int
    public let totalBytes: Int
    public let ttlSeconds: Int           // ≤ SkillsMcpLimits.maximumStagingReceiptTTLSec
    public init(canonicalSHA256: String, fileCount: Int, totalBytes: Int, ttlSeconds: Int) {
        self.canonicalSHA256 = canonicalSHA256
        self.fileCount = fileCount
        self.totalBytes = totalBytes
        self.ttlSeconds = ttlSeconds
    }
}

// MARK: - Metadata sink (the staging service's ORIGINAL commit hook)

/// Implements the ORIGINAL SkillInstallationMetadataStore
/// (SkillInstallStagingService.swift:60-62). File move first, metadata
/// second; the staging service owns the rollback (:138-150).
final class SkillInstallMetadataSink: SkillInstallationMetadataStore, @unchecked Sendable {
    private let store: SQLiteSkillStore
    private let skill: PersistedSkill
    private let grantCapabilities: [String]

    init(store: SQLiteSkillStore, skill: PersistedSkill, grantCapabilities: [String]) {
        self.store = store
        self.skill = skill
        self.grantCapabilities = grantCapabilities
    }

    func persist(_ record: SkillInstallationRecord) async throws {
        // Identity gate (defense in depth over the service's own digest/
        // identity checks): the record MUST describe the very skill being
        // persisted.
        guard record.skillID == skill.id, record.version == skill.version else {
            throw SkillValidationError.invalidIdentifier("installationIdentity")
        }
        try await store.save(skill,
                             grantCapabilities: grantCapabilities,
                             replaceGrants: false)
    }
}

// MARK: - Upgrade journal (original transaction.json shape, extracted)

/// Mirrors SkillsCenter.UpgradeJournal (:111-123) + the phase vocabulary
/// ("prepared"/"complete"/"rollingBack"/"rolledBack"; startup recovery of
/// interrupted transactions mirrors :301-350 with the "interrupted-<uuid>"
/// quarantine). Written atomically as canonical sorted-key JSON under
/// `<installationRoot>/.upgrade-history/<UUID>/transaction.json` with the
/// previous package bytes snapshotted at `previous/` — the ORIGINAL layout.
struct SkillUpgradeJournal: Sendable {
    var oldSkill: PersistedSkill
    var oldGrants: [String]
    var oldPermissions: [PersistedSkillPermission]
    var newDigest: String
    var source: String
    var commit: String
    var phase: String
    var createdAt: Date

    func jsonObject() throws -> sending [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let skillData = try encoder.encode(oldSkill)
        let permissionsData = try encoder.encode(oldPermissions)
        guard let skillObject = try? JSONSerialization.jsonObject(with: skillData),
              let permissionsObject = try? JSONSerialization.jsonObject(with: permissionsData)
        else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "journalEncode")
        }
        return ["oldSkill": skillObject,
                "oldGrants": oldGrants,
                "oldPermissions": permissionsObject,
                "newDigest": newDigest,
                "source": source,
                "commit": commit,
                "phase": phase,
                "createdAt": SkillUpgradeJournal.iso8601String(from: createdAt)]
    }

    static func decode(_ object: [String: Any]) -> SkillUpgradeJournal? {
        guard JSONSerialization.isValidJSONObject(object["oldSkill"] as Any ?? NSNull()),
              let skillData = try? JSONSerialization.data(
                withJSONObject: object["oldSkill"] as Any, options: []),
              var skill = try? isoDecoding().decode(PersistedSkill.self, from: skillData) else {
            return nil
        }
        _ = skill
        guard JSONSerialization.isValidJSONObject(object["oldPermissions"] as Any ?? NSNull()),
              let permissionsData = try? JSONSerialization.data(
                withJSONObject: object["oldPermissions"] as Any ?? [], options: []),
              let permissions = try? isoDecoding().decode([PersistedSkillPermission].self,
                                                          from: permissionsData) else {
            return nil
        }
        guard let createdAt = Self.iso8601Date(from: (object["createdAt"] as? String) ?? "") else {
            return nil
        }
        skill.createdAt = createdAt
        return SkillUpgradeJournal(
            oldSkill: skill,
            oldGrants: (object["oldGrants"] as? [String]) ?? [],
            oldPermissions: permissions,
            newDigest: object["newDigest"] as? String ?? "",
            source: object["source"] as? String ?? "",
            commit: object["commit"] as? String ?? "",
            phase: object["phase"] as? String ?? "",
            createdAt: createdAt)
    }

    private static func isoDecoding() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    static func iso8601Date(from text: String) -> Date? {
        ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - Catalog cache (RAM; honest-unavailable until refreshed)

struct SkillsCatalogCache: Sendable {
    struct Entry: Sendable {
        let id: String
        let version: String
        let path: String
        let size: Int
        let sha256: String
        let contentDigest: String
        let minimumAppVersion: String
        let releaseNotes: [String: String]
    }
    var commit: String
    var checkedAt: Date
    var entries: [Entry]
    var lastFailure: String?
    var retryAfter: Date?
}

// MARK: - SkillsDomain

public actor SkillsDomain {

    // Original stores/services (ONE owned DatabaseManager; the approved
    // service-map constructors — exactly the pattern RuntimeFacadeStores
    // uses for the store cluster).
    private let store: SQLiteSkillStore
    private let settingsStore: SQLiteSettingsStore
    private let installationRoot: URL
    private let stagingRoot: URL
    private let validator: SkillPackageValidator
    private let fileManager: FileManager

    // Trusted host seams + ownership ports.
    private let hostContext: any SkillsHostContextProviding
    private let transport: any SkillsRemoteTransport
    private let rewriter: any SkillModelRewriting
    private let ownedWork: ConfigOwnedWorkLifecycle
    private let toolWork: FacadeToolWorkCoordinator
    private let registry: ToolRunnerRegistry
    /// Signed-content trust roots. The compiled original literal
    /// (OfficialSkillHub.trustedKeys — a generated 32-byte Ed25519 public
    /// key inside FloeSkills, no Bundle.module) is the DEFAULT. The trusted
    /// APK host may inject validated roots instead (keyID → raw 32-byte
    /// public key; validated bounds: ≤16 entries, keyID ≤64 ASCII,
    /// value count == 32); a model envelope can NEVER reach this parameter
    /// and raw keys never appear in JSON/logs.
    private let trustedKeys: [String: Data]

    // Bounded domain state, generation-fenced.
    private var reviews: [String: SkillsReview] = [:]
    private var stagingReceipts: [String: StagedFolder] = [:]
    private var catalogCache: SkillsCatalogCache?
    private var inflightSkills: Set<String> = []
    private let autoUpdatesKey = "floe.content.update.autoScriptedSkills"

    private struct StagedFolder {
        let directory: URL
        let canonicalSHA256: String
        let expiresAt: Date
        let epoch: UInt64
    }

    public struct Services: Sendable {
        public let database: DatabaseManager
        /// Canonical existing Skills install location on Android: under the
        /// SAME trusted RuntimeStorageRoot that owns the DB
        /// (iOS: applicationSupportDirectory + "FloeAgent/Skills" —
        /// SkillsCenter:342-346). Main binds `<root>/FloeAgent/Skills`.
        public let installationRoot: URL
        /// App-private scratch root for staged installs/reviews/folder
        /// receipts (the original staging service requires the install
        /// SOURCE to live outside the installation root —
        /// SkillInstallStagingService.swift:94-96). Main binds a cache
        /// directory under the same trusted root.
        public let stagingRoot: URL
        public let hostContext: any SkillsHostContextProviding
        public let transport: any SkillsRemoteTransport
        public let rewriter: any SkillModelRewriting
        public let ownedWork: ConfigOwnedWorkLifecycle
        public let toolWork: FacadeToolWorkCoordinator
        public let registry: ToolRunnerRegistry
        public let trustedKeys: [String: Data]?
        public init(database: DatabaseManager, installationRoot: URL, stagingRoot: URL,
                    hostContext: any SkillsHostContextProviding,
                    transport: any SkillsRemoteTransport,
                    rewriter: any SkillModelRewriting,
                    ownedWork: ConfigOwnedWorkLifecycle,
                    toolWork: FacadeToolWorkCoordinator,
                    registry: ToolRunnerRegistry = .shared,
                    trustedKeys: [String: Data]? = nil) {
            self.database = database
            self.installationRoot = installationRoot
            self.stagingRoot = stagingRoot
            self.hostContext = hostContext
            self.transport = transport
            self.rewriter = rewriter
            self.ownedWork = ownedWork
            self.toolWork = toolWork
            self.registry = registry
            self.trustedKeys = trustedKeys
        }
    }

    public init(services: Services) throws {
        self.store = SQLiteSkillStore(database: services.database)
        self.settingsStore = SQLiteSettingsStore(database: services.database)
        self.installationRoot = services.installationRoot
        self.stagingRoot = services.stagingRoot
        self.validator = SkillPackageValidator()
        self.fileManager = .default
        self.hostContext = services.hostContext
        self.transport = services.transport
        self.rewriter = services.rewriter
        self.ownedWork = services.ownedWork
        self.toolWork = services.toolWork
        self.registry = services.registry
        if let injected = services.trustedKeys {
            self.trustedKeys = try Self.validatedTrustRoots(injected)
        } else {
            // DEFAULT: the compiled original root (validated at init too).
            self.trustedKeys = try Self.validatedTrustRoots(OfficialSkillHub.trustedKeys)
        }
    }

    /// Host-injected trust roots validated with the ORIGINAL schema +
    /// reasonable bounds: ≤16 roots, keyID ≤64 ASCII identifier chars,
    /// value exactly 32 bytes (Curve25519 raw public key shape used by
    /// SignedContentFeedVerifier:213-216). Anything else fails closed at
    /// construction; a model envelope can never reach this seam.
    static func validatedTrustRoots(_ roots: [String: Data]) throws -> [String: Data] {
        guard roots.count <= 16, !roots.isEmpty else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "trustRootsCount")
        }
        for (keyID, value) in roots {
            guard keyID.utf8.count <= 64,
                  keyID.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }),
                  value.count == 32 else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "trustRootShape")
            }
        }
        return roots
    }

    // MARK: Admission — every entry point runs this first

    private func requireBinding() throws -> FacadeRootGeneration {
        guard let pumps = AndroidRuntimeBootstrap.currentPumps(), pumps.storeReady,
              let fingerprint = hostContext.rootFingerprint(epoch: pumps.epoch),
              let binding = FacadeRootGeneration(epoch: pumps.epoch,
                                                 rootFingerprint: fingerprint) else {
            throw SkillsDomainRefusal.runtimeNotReady
        }
        return binding
    }

    // MARK: skills.list

    /// Installed rows (metadata-only like the native list view; description
    /// parsed via the ORIGINAL parseSkillMarkdown, ≤1024 like
    /// ManagedSkill.discoveryMetadata) + hub cache state + live review count
    /// + the single auto-updates flag. Stop-at-budget page (RB2
    /// ConfigPageBudget numbers: 48 KiB ACTUAL serialized UTF-8,
    /// nextCursor/hasMore, never a truncated item).
    public func snapshot(cursor: String?) async throws -> sending [String: Any] {
        _ = try requireBinding()
        let rows = try await store.all()
        let start = try Self.cursorIndex(cursor, count: rows.count)
        var objects: [[String: Any]] = []
        var bytes = 0
        var index = start
        while index < rows.count, objects.count < ConfigPageBudget.maximumItemsPerPage {
            let row = rows[index]
            var descriptionText = ""
            if let metadata = try? validator.parseSkillMarkdown(Data(row.skillMarkdown.utf8)) {
                descriptionText = String(metadata.description.prefix(1_024))
            }
            let object: [String: Any] = [
                "id": row.id,
                "name": row.name,
                "version": row.version,
                "enabled": row.status == "enabled",
                "digest": row.rewrittenDigest,
                "revision": ["resourceID": "skill.\(row.id)",
                             "version": row.rewrittenDigest],
                "updatedAt": Self.iso8601String(from: row.updatedAt),
                "official": OfficialSkillHub.skillIDs.contains(row.id),
                "bundledSeedSuppressed": try await store.wasBundledSkillRemoved(id: row.id),
                "description": descriptionText,
            ]
            let candidate = try Self.canonicalData(object)
            let overhead = objects.isEmpty ? 2 : 1
            if bytes + candidate.count + overhead > ConfigPageBudget.maximumPageItemsBytes {
                if objects.isEmpty {
                    throw ConfigDomainError(code: .payloadTooLarge, reason: "itemDoesNotFitPage")
                }
                break
            }
            objects.append(object)
            bytes += candidate.count + overhead
            index += 1
        }
        return [
            "skills": objects,
            "hasMore": index < rows.count,
            "nextCursor": index < rows.count ? String(index) : NSNull(),
            "catalog": catalogProjection(),
            "pendingReviews": reviews.values.map { review in
                ["reviewToken": review.token,
                 "skillID": review.skillID,
                 "kind": review.kindName,
                 // The echoed revision lets the UI confirm/discard with the
                 // honest CAS value instead of a fabricated one.
                 "revision": ["resourceID": "skill.\(review.skillID)",
                              "version": review.expectedDigest]]
            },
            "settings": try await settingsDocument(),
        ]
    }

    /// Bounded markdown detail window (byteOffset / maxBytes ≤ 32 KiB owned
    /// chunk per the P0 SettingsDomainV1.maximumChunkBytes rule; UTF-8
    /// scalar-safe; hasMore honest). Wire equivalent of the original
    /// skill.read pagination (SkillManagement.swift:120-133).
    public func detail(skillID: String, byteOffset: Int, maxBytes: Int) async throws -> sending [String: Any] {
        _ = try requireBinding()
        try SkillManageTool.validateID(skillID)
        guard byteOffset >= 0, maxBytes >= 1,
              maxBytes <= SkillsMcpLimits.maximumWindowBytes else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "detailWindow")
        }
        let rows = try await store.all()
        guard let row = rows.first(where: { $0.id == skillID }) else {
            throw ConfigDomainError(code: .notFound, reason: "skillRowMissing")
        }
        let bytes = Array(row.skillMarkdown.utf8)
        guard byteOffset <= bytes.count else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "detailOffsetOutOfRange")
        }
        let end = min(bytes.count, byteOffset + maxBytes)
        var window = Data(bytes[byteOffset..<end])
        // Never split a scalar at the tail.
        while !window.isEmpty, String(data: window, encoding: .utf8) == nil {
            window.removeLast()
        }
        return [
            "id": row.id,
            "byteOffset": byteOffset,
            "bytesReturned": window.count,
            "totalBytes": bytes.count,
            "hasMore": end < bytes.count,
            "text": String(decoding: window, as: UTF8.self),
        ]
    }

    // MARK: skills.list — catalog refresh (async effect; honest failure)

    /// The ORIGINAL hub refresh (SkillsCenter.refreshOfficialCatalog:44-81):
    /// hourly gate unless forced; immutable-commit fetch of
    /// skill-hub/catalog.json + catalog.sig; per-id verified signature with
    /// the COMPILED trust root (no Bundle.module on the overlay — the key is
    /// the generated Swift literal already inside FloeSkills). On ANY
    /// failure the PREVIOUS cache stays authoritative and the result carries
    /// a typed reason + retryAfter (never an empty catalog lie, never a
    /// "refreshed" claim).
    public func refreshCatalog(force: Bool, now: Date = Date()) async throws -> sending [String: Any] {
        _ = try requireBinding()
        if !force, let cache = catalogCache {
            if now.timeIntervalSince(cache.checkedAt) < 3_600 {
                return ["state": "upToDate", "catalog": catalogProjection()]
            }
            if let retryAfter = cache.retryAfter, now < retryAfter {
                return ["state": "retryBackoff",
                        "retryAfter": Self.iso8601String(from: retryAfter),
                        "catalog": catalogProjection()]
            }
        }
        guard let appVersion = Self.validatedAppVersion(hostContext.appVersion()) else {
            throw SkillsDomainRefusal.appVersionUnbound
        }
        let source = try OfficialSkillHub.source()
        let commit: String
        let catalogBytes: Data
        let signature: Data
        do {
            commit = try await transport.resolveCommit(source)
            catalogBytes = try await transport.fetch(source, commit: commit,
                                                     path: OfficialSkillHub.catalogPath)
            signature = try await transport.fetch(source, commit: commit,
                                                  path: "skill-hub/catalog.sig")
        } catch let refusal as SkillsDomainRefusal {
            recordCatalogFailure(reason: Self.safe(refusal), now: now)
            throw refusal
        } catch {
            recordCatalogFailure(reason: Self.redacted(error), now: now)
            return ["state": "failed", "reason": "catalogFetch",
                    "catalog": catalogProjection()]
        }
        var entries: [SkillsCatalogCache.Entry] = []
        do {
            for id in OfficialSkillHub.skillIDs.sorted() {
                let package = try OfficialSkillHub.verifiedPackage(
                    catalog: catalogBytes, signature: signature, id: id,
                    appVersion: appVersion, trustedKeys: self.trustedKeys)
                entries.append(.init(id: package.id, version: package.version,
                                     path: package.path, size: package.size,
                                     sha256: package.sha256,
                                     contentDigest: package.contentDigest,
                                     minimumAppVersion: package.minimumAppVersion,
                                     releaseNotes: package.releaseNotes))
            }
        } catch let failure as OfficialSkillHub.Failure {
            recordCatalogFailure(reason: "hub.\(Self.safe(failure))", now: now)
            return ["state": "failed", "reason": "catalogValidation",
                    "catalog": catalogProjection()]
        } catch {
            recordCatalogFailure(reason: "catalogValidation", now: now)
            return ["state": "failed", "reason": "catalogValidation",
                    "catalog": catalogProjection()]
        }
        catalogCache = SkillsCatalogCache(commit: commit, checkedAt: now, entries: entries,
                                          lastFailure: nil, retryAfter: nil)
        return ["state": "refreshed", "checkedAt": Self.iso8601String(from: now),
                "catalog": catalogProjection()]
    }

    // MARK: skills.install — official hub (new install review or upgrade review)

    public func installOfficial(skillID: String, revision: ConfigRevision?,
                                createIntent: Bool) async throws -> SkillsReviewProjection {
        let binding = try requireBinding()
        guard OfficialSkillHub.skillIDs.contains(skillID) else {
            throw ConfigDomainError(code: .notFound, reason: "officialSkillUnknown")
        }
        guard let appVersion = Self.validatedAppVersion(hostContext.appVersion()) else {
            throw SkillsDomainRefusal.appVersionUnbound
        }
        guard inflightSkills.insert(skillID).inserted else {
            throw ConfigDomainError(code: .duplicateInFlight, reason: "skillOperationActive")
        }
        defer { inflightSkills.remove(skillID) }
        let rows = try await store.all()
        let existing = rows.first { $0.id == skillID }
        try Self.checkRevision(existing: existing, revision: revision,
                               createIntent: createIntent, skillID: skillID)
        guard let cache = catalogCache, !cache.commit.isEmpty,
              let entry = cache.entries.first(where: { $0.id == skillID }) else {
            throw ConfigDomainError(code: .needsConfiguration, reason: "catalogRefreshRequired")
        }
        if let existing {
            try Self.rejectVersionRegression(oldVersion: existing.version,
                                             newVersion: entry.version)
        }
        let reviewToken = FacadeCapabilityToken.make(namespace: FacadeCapabilityToken.effectPrefix)
        // The hub stage/unpack APIs create their destination themselves and
        // refuse a pre-existing root (SignedContentArchive.swift:40-43).
        let stagingRoot = try makeStagingDirectory(namespace: "hub")
        let packageRoot = stagingRoot.appendingPathComponent("package")
        do {
            if let existing {
                let installed = try SkillContentSnapshot(
                    root: Self.packageDirectory(installationRoot: installationRoot, id: skillID),
                    expectedDigest: existing.rewrittenDigest,
                    manifestOverride: Self.sidecarManifest(for: existing))
                let candidate = try await OfficialSkillHub.stage(
                    id: skillID, appVersion: appVersion, installed: installed,
                    at: packageRoot, trustedKeys: self.trustedKeys,
                    resolve: { [transport] source in try await transport.resolveCommit(source) },
                    fetch: { [transport] source, commit, path in
                        try await transport.fetch(source, commit: commit, path: path)
                    })
                registerUpgradeReview(token: reviewToken, candidate: candidate,
                                      stagingRoot: stagingRoot, binding: binding)
                // Auto-apply ONLY under the exact original rule: the flag on
                // AND no added capabilities/tools (SkillsCenter:83-106).
                if await autoScriptedUpdatesEnabled(),
                   candidate.addedCapabilities.isEmpty, candidate.addedTools.isEmpty {
                    _ = try await upgradeApply(reviewToken: reviewToken,
                                               effectToken: nil, revision: nil)
                    return SkillsReviewProjection(token: reviewToken, skillID: skillID,
                                                  version: candidate.snapshot.package.manifest.version,
                                                  committed: true,
                                                  changedFiles: candidate.changedFiles,
                                                  addedCapabilities: [], addedTools: [],
                                                  releaseNotes: candidate.releaseNotes)
                }
                return Self.project(candidate: candidate, token: reviewToken)
            }
            // New identity review: fetch + unpack + validate through the
            // ORIGINAL gates; commit happens only via reviewCommit.
            let zip = try await fetchHubZip(entry: entry, commit: cache.commit)
            let proposed = try OfficialSkillHub.unpack(zip, at: packageRoot)
            guard proposed.package.manifest.id == skillID,
                  proposed.package.manifest.version == entry.version,
                  proposed.package.canonicalSHA256 == entry.contentDigest else {
                throw OfficialSkillHub.Failure.immutableVersion
            }
            try requireCompatibility(proposed.package)
            registerInstallReview(token: reviewToken, packageDirectory: packageRoot,
                                  canonicalSHA256: proposed.package.canonicalSHA256,
                                  sourceURL: Self.hubSourceURL(source: try OfficialSkillHub.source(),
                                                                commit: cache.commit,
                                                                entry: entry),
                                  sourceDigest: entry.sha256,
                                  rewriteModelID: "official-hub",
                                  manifestOverride: nil,
                                  binding: binding)
            return SkillsReviewProjection(token: reviewToken, skillID: skillID,
                                          version: entry.version, committed: false,
                                          changedFiles: proposed.files.keys.sorted(),
                                          addedCapabilities: proposed.package.manifest.capabilities,
                                          addedTools: proposed.package.manifest.tools,
                                          releaseNotes: entry.releaseNotes)
        } catch {
            cleanup(stagingRoot)
            throw Self.mapSkillError(error)
        }
    }

    // MARK: skills.install — review commit / discard

    /// ⇄ confirmPendingInstallation / applyReviewedUpgrade. A committed
    /// token retires exactly once; stale/foreign/old-generation tokens are a
    /// typed notFound — never a replayed install. The envelope create-intent
    /// and revision MUST agree with the staged kind: install reviews are new
    /// identities (explicit create intent, no fabricated version), upgrade
    /// reviews are existing identities (digest CAS). A mismatch is refused
    /// BEFORE any effect (no silent reinterpretation).
    public func reviewCommit(token: String, createIntent: Bool,
                             revision: ConfigRevision?) async throws -> sending [String: Any] {
        let binding = try requireBinding()
        guard let review = reviews[token], review.createdAtEpoch == binding.epoch else {
            throw ConfigDomainError(code: .notFound, reason: "reviewUnknown")
        }
        switch review.kind {
        case .install:
            guard createIntent, revision == nil else {
                throw ConfigDomainError(code: .invalidEnvelope,
                                        reason: "reviewConfirmCreateIntentExpected")
            }
        case .upgrade(let candidate, _):
            guard !createIntent, let revision,
                  revision.resourceID == "skill.\(candidate.snapshot.package.manifest.id)",
                  revision.version == candidate.expectedInstalledDigest else {
                throw ConfigDomainError(code: .staleRevision,
                                        reason: "reviewConfirmUpgradeRevision")
            }
        }
        switch review.kind {
        case .install(let packageDirectory, let canonicalSHA256, let sourceURL,
                      let sourceDigest, let rewriteModelID, let manifestOverride):
            let record = try await commitInstalledPackage(
                stagedPackageDirectory: packageDirectory,
                canonicalSHA256: canonicalSHA256,
                sourceURL: sourceURL, sourceDigest: sourceDigest,
                rewriteModelID: rewriteModelID,
                manifestOverride: manifestOverride,
                replaceExisting: false, verifiedUpgrade: nil)
            retireReview(token)
            return ["state": "installed", "skillID": record.skillID,
                    "version": record.version,
                    "digest": record.canonicalSHA256,
                    "revision": ["resourceID": "skill.\(record.skillID)",
                                 "version": record.canonicalSHA256]]
        case .upgrade:
            return try await upgradeApply(reviewToken: token, effectToken: nil,
                                          revision: nil)
        }
    }

    /// ⇄ cancelPendingInstallation: drop the staged review only. An install
    /// already CONFIRMED is owned by its worker, never by this call.
    public func reviewDiscard(token: String) throws -> sending [String: Any] {
        let binding = try requireBinding()
        guard let review = reviews[token], review.createdAtEpoch == binding.epoch else {
            throw ConfigDomainError(code: .notFound, reason: "reviewUnknown")
        }
        retireReview(token)
        return ["state": "discarded", "skillID": review.skillID]
    }

    // MARK: skills.install — setEnabled (original digest CAS)

    public func setEnabled(skillID: String, revision: ConfigRevision,
                           enabled: Bool) async throws -> sending [String: Any] {
        _ = try requireBinding()
        try SkillManageTool.validateID(skillID)
        guard revision.resourceID == "skill.\(skillID)" else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "skillRevisionResource")
        }
        do {
            try await store.setEnabled(enabled, id: skillID, expectedDigest: revision.version)
        } catch is SkillStoreConflict {
            throw ConfigDomainError(code: .staleRevision, reason: "skillCAS")
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "skillWrite")
        }
        return ["state": "applied", "skillID": skillID, "enabled": enabled]
    }

    // MARK: skills.uninstall — recoverable remove (original ordering)

    /// ⇄ remove(skill) (SkillsCenter:716-728): quiesce owned workers FIRST,
    /// move the package to a recoverable RemovedSkills backup OUTSIDE the
    /// store root, then row-remove with digest CAS; on DB failure the files
    /// are restored (no half state). Official ids suppress the bundled
    /// re-seed — the ORIGINAL user-intent policy, cleared only through the
    /// original requestBundledSkillInstallation (host bind path, unchanged).
    public func uninstall(skillID: String, revision: ConfigRevision) async throws -> sending [String: Any] {
        let binding = try requireBinding()
        try SkillManageTool.validateID(skillID)
        guard revision.resourceID == "skill.\(skillID)" else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "skillRevisionResource")
        }
        let rows = try await store.all()
        guard let row = rows.first(where: { $0.id == skillID }) else {
            throw ConfigDomainError(code: .notFound, reason: "skillRowMissing")
        }
        guard row.rewrittenDigest == revision.version else {
            throw ConfigDomainError(code: .staleRevision, reason: "skillCAS")
        }
        guard inflightSkills.insert(skillID).inserted else {
            throw ConfigDomainError(code: .duplicateInFlight, reason: "skillOperationActive")
        }
        defer { inflightSkills.remove(skillID) }
        // Stop owned install/upgrade workers before touching files
        // (AGENTS.md: stop owned workers before unregister/delete files).
        // The drain WAITS for real completions; a leftover live worker is a
        // typed refusal, never a destructive race.
        await toolWork.drainSkillWorkers(ownerID: skillID, epoch: binding.epoch)
        if await toolWork.hasLiveSkillWorkers(ownerID: skillID, epoch: binding.epoch) {
            throw ConfigDomainError(code: .duplicateInFlight, reason: "skillWorkerStillLive")
        }
        let package = Self.packageDirectory(installationRoot: installationRoot, id: skillID)
        let exists = fileManager.fileExists(atPath: package.path)
        var backupToken: String?
        var backup: URL?
        if exists {
            backupToken = FacadeCapabilityToken.make(namespace: "bkp:v1:")
            let destination = installationRoot.deletingLastPathComponent()
                .appendingPathComponent("RemovedSkills")
                .appendingPathComponent("\(skillID)-\(backupToken!)")
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try fileManager.moveItem(at: package, to: destination)
                backup = destination
            } catch {
                throw ConfigDomainError(code: .persistenceUnavailable, reason: "skillBackupMove")
            }
        }
        let official = OfficialSkillHub.skillIDs.contains(skillID)
        do {
            try await store.remove(id: skillID, expectedDigest: revision.version,
                                   suppressBundledSeed: official)
        } catch is SkillStoreConflict {
            restoreBackup(backup, to: package, exists: exists)
            throw ConfigDomainError(code: .staleRevision, reason: "skillCAS")
        } catch {
            restoreBackup(backup, to: package, exists: exists)
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "skillRemove")
        }
        for token in Array(reviews.keys) where reviews[token]?.skillID == skillID {
            retireReview(token)
        }
        return ["state": "removed", "skillID": skillID,
                "recoveryAvailable": exists,
                "recoveryToken": backupToken ?? NSNull(),
                "bundledSeedSuppressed": official]
    }

    // MARK: skills.install — creator (direct materialization; original funnel)

    /// ⇄ SkillsCenter.create/createSkill (:354-436): deterministic local
    /// materialization (SKILL.md + floe.json; python scripts only under the
    /// ORIGINAL path rules and the ORIGINAL remote-runtime manifest), NO
    /// model output, then the same funnel with sourceURL
    /// "floe-creator://local/<id>". Side-effecting packages route to an
    /// explicit review (original automatic policy). The agent-facing
    /// skill.create tool registration stays unbound until Main binds the
    /// real RB4 processor (no hardcoded generated skill).
    public func createSkill(draft: SkillCreationRequest) async throws -> SkillsReviewProjection {
        let binding = try requireBinding()
        let skillID = try Self.identifier(for: draft.name)
        guard !BundledDomainSkills.all.contains(where: { $0.id == skillID }),
              !OfficialSkillHub.skillIDs.contains(skillID) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "reservedSkillID")
        }
        guard inflightSkills.insert(skillID).inserted else {
            throw ConfigDomainError(code: .duplicateInFlight, reason: "skillOperationActive")
        }
        defer { inflightSkills.remove(skillID) }
        let stagingRoot = try makeStagingDirectory(namespace: "creator")
        let packageRoot = stagingRoot.appendingPathComponent("package")
        try fileManager.createDirectory(at: packageRoot, withIntermediateDirectories: false)
        do {
            var files: [String: Data] = [:]
            // ORIGINAL creator shape (SkillsCenter:376-380): the frontmatter
            // name IS the derived identifier; the display name lives in the
            // agents/openai.yaml policy file. The validator enforces
            // `metadata.name == manifest.id` exactly.
            let markdown = "---\nname: \(skillID)\n"
                + "description: \(Self.yamlScalar(draft.description))\n---\n\n\(draft.instructions)\n"
            files["SKILL.md"] = Data(markdown.utf8)
            var capabilities = ["workspace.read"]
            var tools: [String] = []
            var scriptRuntime = "none"
            if !draft.pythonScripts.isEmpty || !draft.pythonPackages.isEmpty {
                capabilities = ["execution.remote"]
                tools = ["exec.shell"]
                scriptRuntime = "remote"
                for script in draft.pythonScripts {
                    let relative = "scripts/\(script.relativePath)"
                    try FinderSkillEnvelope.validateRelativePath(relative)
                    files[relative] = Data(script.source.utf8)
                }
            }
            let manifestObject: [String: Any] = [
                "schemaVersion": 1, "id": skillID, "version": "1.0.0",
                "capabilities": capabilities, "tools": tools,
                "platforms": ["linux"], "scriptRuntime": scriptRuntime,
                "pythonPackages": draft.pythonPackages.map {
                    ["spec": $0.spec, "purpose": $0.purpose,
                     "capabilities": $0.capabilities] as [String: Any]
                },
            ]
            files["floe.json"] = try Self.canonicalData(manifestObject)
            try Self.writeFiles(files, into: packageRoot, fileManager: fileManager)
            let package = try validator.validate(packageAt: packageRoot, requireManifest: true)
            try requireCompatibility(package)
            let reviewToken = FacadeCapabilityToken.make(namespace: FacadeCapabilityToken.effectPrefix)
            let policyAllows = SkillAutomaticInstallPolicy.mayInstallWithoutConfirmation(
                package, descriptors: registry.allDescriptors)
            if policyAllows {
                let record = try await commitInstalledPackage(
                    stagedPackageDirectory: packageRoot,
                    canonicalSHA256: package.canonicalSHA256,
                    sourceURL: "floe-creator://local/\(skillID)",
                    sourceDigest: nil,
                    rewriteModelID: "local-skill-creator",
                    manifestOverride: nil,
                    replaceExisting: false, verifiedUpgrade: nil)
                cleanup(stagingRoot)
                return SkillsReviewProjection(token: reviewToken,
                                              skillID: record.skillID,
                                              version: record.version, committed: true,
                                              changedFiles: Array(files.keys).sorted(),
                                              addedCapabilities: capabilities,
                                              addedTools: tools, releaseNotes: [:])
            }
            registerInstallReview(token: reviewToken, packageDirectory: packageRoot,
                                  canonicalSHA256: package.canonicalSHA256,
                                  sourceURL: "floe-creator://local/\(skillID)",
                                  sourceDigest: nil, rewriteModelID: "local-skill-creator",
                                  manifestOverride: nil, binding: binding)
            // The review owns the staging tree now — do not clean it up.
            return SkillsReviewProjection(token: reviewToken, skillID: skillID,
                                          version: package.manifest.version,
                                          committed: false,
                                          changedFiles: Array(files.keys).sorted(),
                                          addedCapabilities: capabilities,
                                          addedTools: tools, releaseNotes: [:])
        } catch {
            cleanup(stagingRoot)
            throw Self.mapSkillError(error)
        }
    }

    // MARK: skills.install — Finder URL ingest

    /// ⇄ installFromFinder (:438-504): https-only bounded GET through the
    /// qualified WebTools transport (the production port revalidates
    /// redirects inside the session; LAN targets are refused by
    /// PublicNetworkTargetPolicy), envelope ≤262 KiB, manifest-less derive
    /// via requireManifest:false, rewrite ONLY through the bound port with
    /// the original shrink-only rules RE-VERIFIED here. Arrival NEVER
    /// auto-runs; auto-install only under the original automatic policy.
    public func finderImport(urlText: String, rewriteModelID: String?) async throws
        -> SkillsReviewProjection {
        let binding = try requireBinding()
        guard urlText.utf8.count <= 4_096,
              let url = URL(string: urlText), url.scheme == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "finderURLPolicy")
        }
        let envelopeBytes: Data
        do {
            envelopeBytes = try await transport.fetchFinderEnvelope(url: url)
        } catch let refusal as SkillsDomainRefusal {
            throw refusal
        } catch {
            throw ConfigDomainError(code: .transportUnavailable, reason: Self.redacted(error))
        }
        let envelope: FinderSkillEnvelope
        do {
            envelope = try FinderSkillEnvelope.decode(envelopeBytes)
        } catch {
            throw Self.mapSkillError(error)
        }
        var markdown = envelope.skillMarkdown
        var manifestOverride = envelope.manifest
        var effectiveRewriteModel = "local"
        if let rewriteModelID {
            // Bound port or refuse BEFORE any file effect — never a silently
            // skipped rewrite.
            let rewrite: SkillModelRewrite
            do {
                rewrite = try await rewriter.rewrite(markdown: markdown,
                                                     manifestJSON: manifestOverride,
                                                     modelID: rewriteModelID)
            } catch {
                throw Self.mapSkillError(error)
            }
            try Self.validateRewrite(originalMarkdown: envelope.skillMarkdown,
                                     originalManifest: manifestOverride,
                                     rewrittenMarkdown: rewrite.markdown,
                                     rewrittenManifest: rewrite.manifestJSON)
            markdown = rewrite.markdown
            if let rewrittenManifest = rewrite.manifestJSON { manifestOverride = rewrittenManifest }
            effectiveRewriteModel = rewriteModelID
        }
        let stagingRoot = try makeStagingDirectory(namespace: "finder")
        let packageRoot = stagingRoot.appendingPathComponent("package")
        try fileManager.createDirectory(at: packageRoot, withIntermediateDirectories: false)
        do {
            let staged = FinderSkillEnvelope(skillMarkdown: markdown,
                                             manifest: manifestOverride,
                                             files: envelope.files)
            try staged.materialize(into: packageRoot, fileManager: fileManager)
            let package = try validator.validate(packageAt: packageRoot,
                                                 requireManifest: false,
                                                 manifestOverride: nil)
            try requireCompatibility(package)
            let reviewToken = FacadeCapabilityToken.make(namespace: FacadeCapabilityToken.effectPrefix)
            let derivedOverride: SkillManifest? = manifestOverride == nil ? package.manifest : nil
            let policyAllows = SkillAutomaticInstallPolicy.mayInstallWithoutConfirmation(
                package, descriptors: registry.allDescriptors)
            if policyAllows {
                let record = try await commitInstalledPackage(
                    stagedPackageDirectory: packageRoot,
                    canonicalSHA256: package.canonicalSHA256,
                    sourceURL: url.absoluteString, sourceDigest: nil,
                    rewriteModelID: effectiveRewriteModel,
                    manifestOverride: derivedOverride,
                    replaceExisting: false, verifiedUpgrade: nil)
                cleanup(stagingRoot)
                return SkillsReviewProjection(token: reviewToken,
                                              skillID: record.skillID,
                                              version: record.version, committed: true,
                                              changedFiles: package.files.map(\.relativePath).sorted(),
                                              addedCapabilities: package.manifest.capabilities,
                                              addedTools: package.manifest.tools,
                                              releaseNotes: [:])
            }
            registerInstallReview(token: reviewToken, packageDirectory: packageRoot,
                                  canonicalSHA256: package.canonicalSHA256,
                                  sourceURL: url.absoluteString, sourceDigest: nil,
                                  rewriteModelID: effectiveRewriteModel,
                                  manifestOverride: derivedOverride, binding: binding)
            return SkillsReviewProjection(token: reviewToken,
                                          skillID: package.manifest.id,
                                          version: package.manifest.version,
                                          committed: false,
                                          changedFiles: package.files.map(\.relativePath).sorted(),
                                          addedCapabilities: package.manifest.capabilities,
                                          addedTools: package.manifest.tools,
                                          releaseNotes: [:])
        } catch {
            cleanup(stagingRoot)
            throw Self.mapSkillError(error)
        }
    }

    // MARK: skills.install — folder staging (host-issued receipt only)

    /// Module API the RB7 SAF host calls AFTER copying the picked directory
    /// into `directory` inside the domain scratch root
    /// (`<stagingRoot>/<host-issued name>`). The domain re-computes the
    /// ORIGINAL canonical digest over the copied bytes and only then issues
    /// the opaque wire token. NOTHING installs on arrival; the token expires
    /// at its announced TTL (≤30 min) and with the root generation.
    public func registerStagedFolder(directory: URL,
                                     receipt: SkillsFolderStagingReceipt,
                                     now: Date = Date()) throws -> String {
        let binding = try requireBinding()
        guard directory.standardizedFileURL.path
            .hasPrefix(stagingRoot.standardizedFileURL.path + "/"),
            directory.path != stagingRoot.standardizedFileURL.path,
            receipt.ttlSeconds > 0,
            receipt.ttlSeconds <= SkillsMcpLimits.maximumStagingReceiptTTLSec,
            receipt.fileCount > 0, receipt.fileCount <= 256,
            receipt.totalBytes > 0,
            receipt.canonicalSHA256.count == 64,
            receipt.canonicalSHA256.allSatisfy(\.isHexDigit) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "stagingReceiptShape")
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ConfigDomainError(code: .notFound, reason: "stagingDirectoryMissing")
        }
        let files = try Self.collectDirectoryFiles(directory, fileManager: fileManager)
        let digest = SkillPackageValidator.canonicalDigest(files: files)
        let totalBytes = files.values.reduce(0) { partial, chunk in partial + chunk.count }
        guard digest == receipt.canonicalSHA256,
              files.count == receipt.fileCount,
              totalBytes == receipt.totalBytes else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "stagingDigestMismatch")
        }
        purgeExpiredStaging(now: now)
        let token = FacadeCapabilityToken.make(namespace: FacadeCapabilityToken.stagingPrefix)
        stagingReceipts[token] = StagedFolder(
            directory: directory, canonicalSHA256: digest,
            expiresAt: now.addingTimeInterval(TimeInterval(receipt.ttlSeconds)),
            epoch: binding.epoch)
        return token
    }

    /// ⇄ importStagedPackage (the fileImporter copy step behind
    /// installTraditionalPackage :510-535): validate requireManifest:false →
    /// ORIGINAL funnel with sourceDigest == package digest.
    public func importStagedFolder(token: String, now: Date = Date()) async throws
        -> SkillsReviewProjection {
        let binding = try requireBinding()
        guard FacadeCapabilityToken.isValid(token, prefix: FacadeCapabilityToken.stagingPrefix),
              let staged = stagingReceipts[token] else {
            throw ConfigDomainError(code: .notFound, reason: "stagingHandleUnknown")
        }
        guard staged.epoch == binding.epoch, staged.expiresAt > now else {
            stagingReceipts[token] = nil
            try? fileManager.removeItem(at: staged.directory)
            throw ConfigDomainError(code: .notFound, reason: "stagingHandleExpired")
        }
        let package: ValidatedSkillPackage
        do {
            package = try validator.validate(packageAt: staged.directory, requireManifest: false)
            try requireCompatibility(package)
        } catch {
            throw Self.mapSkillError(error)
        }
        let reviewToken = FacadeCapabilityToken.make(namespace: FacadeCapabilityToken.effectPrefix)
        let derivedOverride: SkillManifest? =
            fileManager.fileExists(atPath: staged.directory
                .appendingPathComponent("floe.json").path) ? nil : package.manifest
        let policyAllows = SkillAutomaticInstallPolicy.mayInstallWithoutConfirmation(
            package, descriptors: registry.allDescriptors)
        if policyAllows {
            let record = try await commitInstalledPackage(
                stagedPackageDirectory: staged.directory,
                canonicalSHA256: package.canonicalSHA256,
                sourceURL: "local-file://staged",
                sourceDigest: package.canonicalSHA256,
                rewriteModelID: "traditional-package",
                manifestOverride: derivedOverride,
                replaceExisting: false, verifiedUpgrade: nil)
            stagingReceipts[token] = nil
            try? fileManager.removeItem(at: staged.directory)
            return SkillsReviewProjection(token: reviewToken, skillID: record.skillID,
                                          version: record.version, committed: true,
                                          changedFiles: package.files.map(\.relativePath).sorted(),
                                          addedCapabilities: package.manifest.capabilities,
                                          addedTools: package.manifest.tools, releaseNotes: [:])
        }
        // The review owns an INDEPENDENT copy: the staged folder remains
        // deletable by the host until consumed or expired.
        let reviewStaging = try makeStagingDirectory(namespace: "pending")
        let reviewPackage = reviewStaging.appendingPathComponent("package")
        try fileManager.copyItem(at: staged.directory, to: reviewPackage)
        stagingReceipts[token] = nil
        registerInstallReview(token: reviewToken, packageDirectory: reviewPackage,
                              canonicalSHA256: package.canonicalSHA256,
                              sourceURL: "local-file://staged",
                              sourceDigest: package.canonicalSHA256,
                              rewriteModelID: "traditional-package",
                              manifestOverride: derivedOverride, binding: binding)
        return SkillsReviewProjection(token: reviewToken, skillID: package.manifest.id,
                                      version: package.manifest.version, committed: false,
                                      changedFiles: package.files.map(\.relativePath).sorted(),
                                      addedCapabilities: package.manifest.capabilities,
                                      addedTools: package.manifest.tools, releaseNotes: [:])
    }

    /// Picker dismissed without import: drop the staged tree (the host calls
    /// this through the module API on SAF-cancel; the UI never names paths).
    public func discardStagedFolder(token: String) throws -> sending [String: Any] {
        guard let staged = stagingReceipts.removeValue(forKey: token) else {
            throw ConfigDomainError(code: .notFound, reason: "stagingHandleUnknown")
        }
        try? fileManager.removeItem(at: staged.directory)
        return ["state": "discarded"]
    }

    // MARK: skills.install — upgrade check / apply / discard / rollback

    /// ⇄ checkGitHubUpgrade (:138-179). Third-party sources use the ORIGINAL
    /// PUBLIC SkillUpgradeCandidate init, which REFUSES official ids
    /// (:76-77): no app-callable path can forge an official update.
    public func checkUpgrade(skillID: String, source: GitHubSkillSource?) async throws
        -> SkillsReviewProjection {
        let binding = try requireBinding()
        guard let appVersion = Self.validatedAppVersion(hostContext.appVersion()) else {
            throw SkillsDomainRefusal.appVersionUnbound
        }
        let rows = try await store.all()
        guard let row = rows.first(where: { $0.id == skillID }) else {
            throw ConfigDomainError(code: .notFound, reason: "skillRowMissing")
        }
        guard inflightSkills.insert(skillID).inserted else {
            throw ConfigDomainError(code: .duplicateInFlight, reason: "skillOperationActive")
        }
        defer { inflightSkills.remove(skillID) }
        let installed = try SkillContentSnapshot(
            root: Self.packageDirectory(installationRoot: installationRoot, id: skillID),
            expectedDigest: row.rewrittenDigest,
            manifestOverride: Self.sidecarManifest(for: row))
        let reviewToken = FacadeCapabilityToken.make(namespace: FacadeCapabilityToken.effectPrefix)
        let stagingRoot = try makeStagingDirectory(namespace: "upgrade")
        let packageRoot = stagingRoot.appendingPathComponent("package")
        do {
            let candidate: SkillUpgradeCandidate
            if OfficialSkillHub.skillIDs.contains(skillID) {
                candidate = try await OfficialSkillHub.stage(
                    id: skillID, appVersion: appVersion, installed: installed,
                    at: packageRoot, trustedKeys: self.trustedKeys,
                    resolve: { [transport] source in try await transport.resolveCommit(source) },
                    fetch: { [transport] source, commit, path in
                        try await transport.fetch(source, commit: commit, path: path)
                    })
            } else {
                guard let source else {
                    throw ConfigDomainError(code: .notFound, reason: "upgradeSourceMissing")
                }
                let (commit, proposed) = try await GitHubSkillDownload.stage(
                    source: source, at: packageRoot, markdownBase: installed,
                    resolve: { [transport] src in try await transport.resolveCommit(src) },
                    fetch: { [transport] src, commit, path in
                        try await transport.fetch(src, commit: commit, path: path)
                    })
                candidate = try SkillUpgradeCandidate(source: source, commit: commit,
                                                      installed: installed, proposed: proposed)
                try requireCompatibility(candidate.snapshot.package)
            }
            registerUpgradeReview(token: reviewToken, candidate: candidate,
                                  stagingRoot: stagingRoot, binding: binding)
            return Self.project(candidate: candidate, token: reviewToken)
        } catch {
            cleanup(stagingRoot)
            throw Self.mapSkillError(error)
        }
    }

    /// ⇄ applyReviewedUpgrade (:204-236). Sequence kept: base-digest CAS →
    /// journal("prepared") + previous bytes snapshot → staging-service commit
    /// (replaceExisting) → post-verify at the new digest → journal
    /// ("complete"). ANY failure restores through the journal
    /// (restoreUpgrade :287-299). The `effectToken` echo lets the host fence
    /// late outcomes against a newer sheet (binding-map upgradeEffect
    /// fence); it identifies nothing and grants nothing.
    public func upgradeApply(reviewToken: String, effectToken: String?,
                             revision: ConfigRevision?) async throws -> sending [String: Any] {
        let binding = try requireBinding()
        guard let review = reviews[reviewToken], review.createdAtEpoch == binding.epoch,
              case .upgrade(let candidate, let stagingRoot) = review.kind else {
            throw ConfigDomainError(code: .notFound, reason: "reviewUnknown")
        }
        let skillID = candidate.snapshot.package.manifest.id
        guard inflightSkills.insert(skillID).inserted else {
            throw ConfigDomainError(code: .duplicateInFlight, reason: "skillOperationActive")
        }
        defer { inflightSkills.remove(skillID) }
        let rows = try await store.all()
        guard let current = rows.first(where: { $0.id == skillID }) else {
            throw ConfigDomainError(code: .notFound, reason: "skillRowMissing")
        }
        guard current.rewrittenDigest == candidate.expectedInstalledDigest else {
            throw ConfigDomainError(code: .staleRevision, reason: "upgradeBaseDigest")
        }
        if let revision {
            guard revision.resourceID == "skill.\(skillID)",
                  revision.version == current.rewrittenDigest else {
                throw ConfigDomainError(code: .staleRevision, reason: "upgradeEnvelopeRevision")
            }
        }
        let lease: ConfigOwnedWorkLease
        switch ownedWork.begin(kind: .tool, ownerID: skillID) {
        case .success(let started): lease = started
        case .failure(let rejection): throw Self.ownedWorkAttachError(rejection)
        }
        defer { ownedWork.settle(lease) }
        let journalDirectory = try makeJournalDirectory()
        let previousDirectory = journalDirectory.appendingPathComponent("previous")
        let permissions = try await store.permissions(skillID: skillID)
        let grants = permissions.filter { $0.decision == "allow" }.map(\.capability)
        var journal = SkillUpgradeJournal(
            oldSkill: current, oldGrants: grants, oldPermissions: permissions,
            newDigest: candidate.snapshot.package.canonicalSHA256,
            source: "\(candidate.source.owner)/\(candidate.source.repository)",
            commit: candidate.commit, phase: "prepared", createdAt: Date())
        do {
            try Self.writeSnapshotFiles(candidate.installedSnapshot.files,
                                        into: previousDirectory,
                                        fileManager: fileManager)
            try Self.canonicalData(try journal.jsonObject())
                .write(to: journalDirectory.appendingPathComponent("transaction.json"),
                       options: .atomic)
            let record = try await commitInstalledPackage(
                stagedPackageDirectory: stagingRoot.appendingPathComponent("package"),
                canonicalSHA256: candidate.snapshot.package.canonicalSHA256,
                sourceURL: Self.upgradeSourceURL(for: candidate),
                sourceDigest: candidate.expectedInstalledDigest,
                rewriteModelID: OfficialSkillHub.skillIDs.contains(skillID)
                    ? "official-hub" : "github-upgrade",
                manifestOverride: nil,
                initialStatus: current.status,
                replaceExisting: true, verifiedUpgrade: candidate)
            // Post-verify (original :229): snapshot at the NEW digest.
            _ = try SkillContentSnapshot(
                root: Self.packageDirectory(installationRoot: installationRoot, id: skillID),
                expectedDigest: record.canonicalSHA256)
            journal.phase = "complete"
            try Self.canonicalData(try journal.jsonObject())
                .write(to: journalDirectory.appendingPathComponent("transaction.json"),
                       options: .atomic)
            retireReview(reviewToken)
            return ["state": "upgraded", "skillID": skillID,
                    "version": candidate.snapshot.package.manifest.version,
                    "digest": record.canonicalSHA256,
                    "revision": ["resourceID": "skill.\(skillID)",
                                 "version": record.canonicalSHA256],
                    "effectEcho": effectToken ?? NSNull()]
        } catch is SkillStoreConflict {
            await restoreUpgrade(journal: journal, journalDirectory: journalDirectory)
            retireReview(reviewToken)
            throw ConfigDomainError(code: .staleRevision, reason: "upgradeCAS")
        } catch {
            await restoreUpgrade(journal: journal, journalDirectory: journalDirectory)
            retireReview(reviewToken)
            throw Self.mapSkillError(error)
        }
    }

    /// ⇄ cancelUpgrade (:191-202): tear down the staged review tree; the
    /// installed version is untouched.
    public func upgradeDiscard(skillID: String) throws -> sending [String: Any] {
        _ = try requireBinding()
        var removed = 0
        for token in Array(reviews.keys) where reviews[token]?.skillID == skillID {
            retireReview(token)
            removed += 1
        }
        return ["state": "cancelled", "skillID": skillID, "droppedReviews": removed]
    }

    /// ⇄ rollbackLatestUpgrade (:238-285): newest journal entry for the
    /// skill, digest-equality CAS against the CURRENT row, quarantine the
    /// interrupted package directory, restore previous bytes, re-persist the
    /// OLD row + grants + permission rows (the ORIGINAL
    /// restoringPermissions rollback of the previous valid version).
    public func upgradeRollback(skillID: String, revision: ConfigRevision?) async throws
        -> sending [String: Any] {
        let binding = try requireBinding()
        try SkillManageTool.validateID(skillID)
        let historyRoot = installationRoot.appendingPathComponent(".upgrade-history")
        let names = (try? fileManager.contentsOfDirectory(atPath: historyRoot.path)) ?? []
        var newest: (name: String, journal: SkillUpgradeJournal)?
        for name in names where !name.hasPrefix("interrupted-") {
            let url = historyRoot.appendingPathComponent(name)
                .appendingPathComponent("transaction.json")
            guard let data = try? Data(floeContentsOf: url, options: [.mappedIfSafe]),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let journal = SkillUpgradeJournal.decode(object),
                  journal.oldSkill.id == skillID else { continue }
            if newest == nil || journal.createdAt > newest!.journal.createdAt {
                newest = (name, journal)
            }
        }
        guard let rollback = newest else {
            throw ConfigDomainError(code: .notFound, reason: "upgradeJournalMissing")
        }
        let rows = try await store.all()
        guard let current = rows.first(where: { $0.id == skillID }) else {
            throw ConfigDomainError(code: .notFound, reason: "skillRowMissing")
        }
        if let revision {
            guard revision.resourceID == "skill.\(skillID)",
                  revision.version == current.rewrittenDigest else {
                throw ConfigDomainError(code: .staleRevision, reason: "rollbackEnvelopeRevision")
            }
        }
        if current.rewrittenDigest == rollback.journal.oldSkill.rewrittenDigest {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "alreadyRolledBack")
        }
        guard current.rewrittenDigest == rollback.journal.newDigest else {
            throw ConfigDomainError(code: .staleRevision, reason: "rollbackDigest")
        }
        guard inflightSkills.insert(skillID).inserted else {
            throw ConfigDomainError(code: .duplicateInFlight, reason: "skillOperationActive")
        }
        defer { inflightSkills.remove(skillID) }
        await toolWork.drainSkillWorkers(ownerID: skillID, epoch: binding.epoch)
        let lease: ConfigOwnedWorkLease
        switch ownedWork.begin(kind: .tool, ownerID: skillID) {
        case .success(let started): lease = started
        case .failure(let rejection): throw Self.ownedWorkAttachError(rejection)
        }
        defer { ownedWork.settle(lease) }
        var mutated = rollback.journal
        mutated.phase = "rollingBack"
        let journalDirectory = historyRoot.appendingPathComponent(rollback.name)
        try? Self.canonicalData(try mutated.jsonObject())
            .write(to: journalDirectory.appendingPathComponent("transaction.json"),
                   options: .atomic)
        do {
            try await performRestore(journal: mutated, journalDirectory: journalDirectory)
        } catch is SkillStoreConflict {
            throw ConfigDomainError(code: .staleRevision, reason: "rollbackCAS")
        } catch {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "rollbackApply")
        }
        mutated.phase = "rolledBack"
        try? Self.canonicalData(try mutated.jsonObject())
            .write(to: journalDirectory.appendingPathComponent("transaction.json"),
                   options: .atomic)
        return ["state": "rolledBack", "skillID": skillID,
                "version": mutated.oldSkill.version,
                "digest": mutated.oldSkill.rewrittenDigest]
    }

    // MARK: bind-time recovery (original recoverUpgrades :301-350)

    /// Completes or restores interrupted upgrade transactions BEFORE the
    /// domain serves commands. Startup order: after the owned store is
    /// ready, before ordinary admission (RB1 bootstrap order + owned-work
    /// guide). Attachments go through the owned-work lifecycle.
    public func recoverInterruptedUpgrades() async throws {
        _ = try requireBinding()
        let historyRoot = installationRoot.appendingPathComponent(".upgrade-history")
        let names = (try? fileManager.contentsOfDirectory(atPath: historyRoot.path)) ?? []
        for name in names where !name.hasPrefix("interrupted-") {
            let directory = historyRoot.appendingPathComponent(name)
            let url = directory.appendingPathComponent("transaction.json")
            guard let data = try? Data(floeContentsOf: url, options: [.mappedIfSafe]),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  var journal = SkillUpgradeJournal.decode(object) else { continue }
            switch journal.phase {
            case "prepared":
                let rows = try await store.all()
                if let current = rows.first(where: { $0.id == journal.oldSkill.id }),
                   current.rewrittenDigest == journal.newDigest {
                    journal.phase = "complete"
                    try? Self.canonicalData(try journal.jsonObject())
                        .write(to: url, options: .atomic)
                } else {
                    await restoreUpgrade(journal: journal, journalDirectory: directory)
                }
            case "rollingBack":
                await restoreUpgrade(journal: journal, journalDirectory: directory)
            default:
                break
            }
        }
    }

    /// The restore body shared by rollback + recovery: quarantine the
    /// current directory, write the journaled previous bytes, re-persist
    /// the OLD row + grants + permissions atomically-ordered (files then
    /// metadata, like the install funnel).
    private func performRestore(journal: SkillUpgradeJournal,
                                journalDirectory: URL) async throws {
        let packageDirectory = Self.packageDirectory(installationRoot: installationRoot,
                                                     id: journal.oldSkill.id)
        let previous = journalDirectory.appendingPathComponent("previous")
        let quarantine = journalDirectory
            .appendingPathComponent("interrupted-\(UUID().uuidString)")
        let hadPackage = fileManager.fileExists(atPath: packageDirectory.path)
        if hadPackage {
            try fileManager.moveItem(at: packageDirectory, to: quarantine)
        }
        do {
            try Self.writeSnapshotFiles(
                Self.collectDirectoryFiles(previous, fileManager: fileManager),
                into: packageDirectory, fileManager: fileManager)
            try await store.save(journal.oldSkill,
                                 grantCapabilities: journal.oldGrants,
                                 replaceGrants: true,
                                 restoringPermissions: journal.oldPermissions)
        } catch {
            // Never leave the skill without bytes: restore the quarantine
            // (original :727 file-restore pattern) before rethrowing.
            if hadPackage {
                try? fileManager.moveItem(at: quarantine, to: packageDirectory)
            }
            throw error
        }
        try? fileManager.removeItem(at: quarantine)
    }

    private func restoreUpgrade(journal: SkillUpgradeJournal,
                                journalDirectory: URL) async {
        try? await performRestore(journal: journal, journalDirectory: journalDirectory)
    }

    // MARK: skills settings document (ONE canonical value + honest CAS)

    /// The settings document projected for `skills.list`. Its revision
    /// follows the ESTABLISHED RB2 digest-of-actual-value pattern
    /// (ConfigRevision.webSearch(digest:) — "settings.websearch"/value
    /// digest, RuntimeFacadeConfigModels.swift:226-228): resourceID
    /// "skills.settings", version = SHA-256 over the canonical persisted
    /// document. No fabricated counter; the backing value remains the ONE
    /// original key "floe.content.update.autoScriptedSkills"
    /// (ContentUpdateCenter.swift:125).
    public func settingsDocument() async throws -> sending [String: Any] {
        _ = try requireBinding()
        let enabled = await autoScriptedUpdatesEnabled()
        let digest = Self.settingsRevisionDigest(autoScriptedUpdates: enabled)
        return ["autoScriptedUpdates": enabled,
                "revision": ["resourceID": SkillsDomain.settingsResourceID,
                             "version": digest]]
    }

    static let settingsResourceID = "skills.settings"

    static func settingsRevisionDigest(autoScriptedUpdates: Bool) -> String {
        let canonical = "{\"autoScriptedUpdates\":\(autoScriptedUpdates ? "true" : "false")}"
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// skills.install operation "settings.set": stateful CAS against the
    /// ACTUAL persisted document (stale revision ⇒ typed staleRevision,
    /// same-value replay refuses honestly like the websearch digest gate).
    public func setAutoScriptedUpdates(enabled: Bool, revision: ConfigRevision) async throws
        -> sending [String: Any] {
        _ = try requireBinding()
        guard revision.resourceID == Self.settingsResourceID else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "settingsRevisionResource")
        }
        let current = await autoScriptedUpdatesEnabled()
        guard revision.version == Self.settingsRevisionDigest(autoScriptedUpdates: current) else {
            throw ConfigDomainError(code: .staleRevision, reason: "settingsCAS")
        }
        try await settingsStore.setValue(enabled ? "true" : "false", forKey: autoUpdatesKey)
        let newDigest = Self.settingsRevisionDigest(autoScriptedUpdates: enabled)
        return ["state": "applied", "enabled": enabled,
                "revision": ["resourceID": Self.settingsResourceID, "version": newDigest]]
    }

    private func autoScriptedUpdatesEnabled() async -> Bool {
        ((try? await settingsStore.value(forKey: autoUpdatesKey)) == "true")
    }

    // MARK: RB4 binding surface (per-run skill projection; NOT a run loop)

    /// The ORIGINAL runtimeSelection projection (SkillsCenter:575-627) for
    /// the runtime Configuration the RB4 run service builds: enabled ∩
    /// granted ∩ registered semantics through the ORIGINAL tool-authorization
    /// shape; python preapprovals are EMPTY on Android G02 (no local/remote
    /// execution — honest absence, the runtime Configuration defaults exist).
    public func runtimeSelection(runID: UUID) async throws -> SkillsRuntimeSelection {
        _ = try requireBinding()
        let rows = try await store.all()
        let registered = Set(registry.allDescriptors.map(\.name))
        var activeIDs: Set<String> = []
        var relatedByTool: [String: [String]] = [:]
        var allowedNames: Set<String> = []
        for row in rows where row.status == "enabled" {
            guard let manifest = Self.sidecarManifest(for: row) else { continue }
            activeIDs.insert(row.id)
            // The ORIGINAL runtimeSelection shape (SkillsCenter:593-596):
            // effective = declared ∩ granted is recorded for the row, while
            // the tool-name map unions manifest.tools ∩ registered (per-call
            // capability enforcement stays inside the runtime's approval
            // path — the ceiling is NOT capability-gated here, matching the
            // original exactly).
            let granted = try await store.allowedCapabilities(skillID: row.id)
            _ = Set(manifest.capabilities).intersection(granted)
            for tool in manifest.tools where registered.contains(tool) {
                allowedNames.insert(tool)
                if !relatedByTool[tool, default: []].contains(row.id) {
                    relatedByTool[tool, default: []].append(row.id)
                }
            }
            if let definition = BundledDomainSkills.all.first(where: { $0.id == row.id }) {
                for tool in definition.automaticallyLoadedToolNames where registered.contains(tool) {
                    allowedNames.insert(tool)
                    if !relatedByTool[tool, default: []].contains(row.id) {
                        relatedByTool[tool, default: []].append(row.id)
                    }
                }
            }
        }
        _ = runID
        return SkillsRuntimeSelection(activeSkillIDs: activeIDs,
                                      relatedSkillIDsByTool: relatedByTool,
                                      allowedToolNames: allowedNames,
                                      preapprovedPythonScriptSHA256: [],
                                      preapprovedPythonPackages: [])
    }

    // MARK: - Funnel + staging internals

    /// THE install funnel — a narrow composition of the ORIGINAL pieces
    /// (header). Every failure path leaves the previous valid version intact
    /// (the staging service owns that behavior).
    private func commitInstalledPackage(stagedPackageDirectory: URL,
                                        canonicalSHA256: String,
                                        sourceURL: String,
                                        sourceDigest: String?,
                                        rewriteModelID: String,
                                        manifestOverride: SkillManifest?,
                                        initialStatus: String = "enabled",
                                        replaceExisting: Bool,
                                        verifiedUpgrade: SkillUpgradeCandidate?) async throws
        -> SkillInstallationRecord {
        let package = try validator.validate(packageAt: stagedPackageDirectory,
                                             requireManifest: manifestOverride == nil,
                                             manifestOverride: manifestOverride)
        guard package.canonicalSHA256 == canonicalSHA256 else {
            throw SkillValidationError.digestMismatch
        }
        if (BundledDomainSkills.all.contains { $0.id == package.manifest.id }
            || OfficialSkillHub.skillIDs.contains(package.manifest.id)),
           verifiedUpgrade == nil, replaceExisting {
            throw ConfigDomainError(code: .invalidEnvelope,
                                    reason: "reservedIDReplaceRequiresVerifiedUpgrade")
        }
        try requireCompatibility(package)
        let compatibility = try Self.compatibilityJSON(package,
                                                       registered: registry.allDescriptors)
        let markdownText = Self.text(at: stagedPackageDirectory
            .appendingPathComponent("SKILL.md"), fileManager: fileManager)
        let now = Date()
        let skill = PersistedSkill(
            id: package.manifest.id,
            name: package.metadata.name,
            version: package.manifest.version,
            // ORIGINAL: upgrades preserve the existing status
            // (SkillsCenter:226 passes current.status); new installs are
            // enabled (creator respects its own flag at the App layer).
            status: initialStatus,
            skillMarkdown: markdownText,
            manifestJSON: String(decoding: try Self.canonicalData(
                Self.manifestObject(package.manifest)), as: UTF8.self),
            declaredCapabilitiesJSON: try Self.canonicalString(package.manifest.capabilities),
            effectiveCapabilitiesJSON: try Self.canonicalString(package.manifest.capabilities),
            sourceURL: sourceURL,
            sourceDigest: sourceDigest,
            rewrittenDigest: package.canonicalSHA256,
            rewriteModelID: rewriteModelID,
            compatibilityReportJSON: compatibility)
        let staging = SkillInstallStagingService(
            installationRoot: installationRoot,
            validator: validator,
            metadataStore: SkillInstallMetadataSink(
                store: store, skill: skill,
                grantCapabilities: package.manifest.capabilities))
        let lease: ConfigOwnedWorkLease
        switch ownedWork.begin(kind: .tool, ownerID: package.manifest.id) {
        case .success(let started): lease = started
        case .failure(let rejection): throw Self.ownedWorkAttachError(rejection)
        }
        defer { ownedWork.settle(lease) }
        return try await staging.installRewrittenPackage(
            at: stagedPackageDirectory,
            provenance: SkillInstallProvenance(
                sourceURL: Self.provenanceURL(sourceURL),
                originalSHA256: sourceDigest ?? package.canonicalSHA256,
                expectedRewrittenSHA256: package.canonicalSHA256,
                rewriteModelID: rewriteModelID,
                compatibilitySummary: String(compatibility.prefix(4_096))),
            replaceExisting: replaceExisting,
            manifestOverride: manifestOverride ?? (Self.hasFloeJSON(at: stagedPackageDirectory)
                ? nil : package.manifest),
            now: now)
    }

    private static func hasFloeJSON(at directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("floe.json").path)
    }

    private func registerInstallReview(token: String, packageDirectory: URL,
                                       canonicalSHA256: String, sourceURL: String,
                                       sourceDigest: String?, rewriteModelID: String,
                                       manifestOverride: SkillManifest?,
                                       binding: FacadeRootGeneration) {
        guard reviews.count < SkillsMcpLimits.maximumLiveReviews else {
            cleanup(packageDirectory.deletingLastPathComponent())
            return
        }
        reviews[token] = SkillsReview(
            token: token,
            skillID: manifestOverride?.id ?? Self.readManifestID(at: packageDirectory) ?? "unknown",
            createdAtEpoch: binding.epoch,
            kind: .install(stagedPackageURL: packageDirectory,
                           canonicalSHA256: canonicalSHA256,
                           sourceURL: sourceURL, sourceDigest: sourceDigest,
                           rewriteModelID: rewriteModelID,
                           manifestOverride: manifestOverride))
    }

    private func registerUpgradeReview(token: String, candidate: SkillUpgradeCandidate,
                                       stagingRoot: URL, binding: FacadeRootGeneration) {
        guard reviews.count < SkillsMcpLimits.maximumLiveReviews else { return }
        reviews[token] = SkillsReview(
            token: token, skillID: candidate.snapshot.package.manifest.id,
            createdAtEpoch: binding.epoch,
            kind: .upgrade(candidate: candidate, stagingRoot: stagingRoot))
    }

    private func retireReview(_ token: String) {
        guard let review = reviews.removeValue(forKey: token) else { return }
        switch review.kind {
        case .install(let packageURL, _, _, _, _, _):
            cleanup(packageURL.deletingLastPathComponent())
        case .upgrade(_, let stagingRoot):
            cleanup(stagingRoot)
        }
    }

    private func fetchHubZip(entry: SkillsCatalogCache.Entry, commit: String) async throws -> Data {
        let source = try OfficialSkillHub.source()
        let zip = try await transport.fetch(source, commit: commit, path: entry.path)
        guard zip.count == entry.size else { throw OfficialSkillHub.Failure.archive }
        let digest = SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        guard digest == entry.sha256 else { throw OfficialSkillHub.Failure.archive }
        return zip
    }

    private func makeStagingDirectory(namespace: String) throws -> URL {
        let base = stagingRoot.appendingPathComponent(namespace)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let directory = base.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func makeJournalDirectory() throws -> URL {
        let base = installationRoot.appendingPathComponent(".upgrade-history")
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let directory = base.appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func cleanup(_ directory: URL) {
        try? fileManager.removeItem(at: directory)
    }

    private func restoreBackup(_ backup: URL?, to package: URL, exists: Bool) {
        guard exists, let backup else { return }
        try? fileManager.moveItem(at: backup, to: package)
    }

    private func purgeExpiredStaging(now: Date) {
        for (token, staged) in stagingReceipts where staged.expiresAt <= now {
            stagingReceipts[token] = nil
            try? fileManager.removeItem(at: staged.directory)
        }
    }

    private func catalogProjection() -> sending [String: Any] {
        guard let cache = catalogCache else {
            return ["state": "unavailable"]
        }
        let entries = cache.entries.map { entry in
            [
                "id": entry.id, "version": entry.version, "path": entry.path,
                "size": entry.size, "sha256": entry.sha256,
                "contentDigest": entry.contentDigest,
                "minimumAppVersion": entry.minimumAppVersion,
                "releaseNotes": entry.releaseNotes,
            ] as [String: Any]
        }
        var projection: [String: Any] = [
            "state": cache.lastFailure != nil ? "staleCached" : "ready",
            "checkedAt": Self.iso8601String(from: cache.checkedAt),
            "packages": entries,
        ]
        projection["lastFailure"] = cache.lastFailure ?? NSNull()
        projection["retryAfter"] = cache.retryAfter.map { Self.iso8601String(from: $0) } ?? NSNull()
        return projection
    }

    private func recordCatalogFailure(reason: String, now: Date) {
        // Additive backoff mirrored from ContentUpdatePolicy.nextRetry
        // (base 15 min, cap 24 h — ContentUpdatePolicy.swift:13-21/64-70):
        // the previous cache stays; only the failure window updates.
        let prior = catalogCache?.retryAfter.map { max(0, $0.timeIntervalSinceNow) } ?? 0
        let interval = min(24 * 60 * 60, 15 * 60 + prior)
        if let cache = catalogCache {
            catalogCache = SkillsCatalogCache(commit: cache.commit, checkedAt: cache.checkedAt,
                                              entries: cache.entries,
                                              lastFailure: reason,
                                              retryAfter: now.addingTimeInterval(interval))
        } else {
            catalogCache = SkillsCatalogCache(commit: "", checkedAt: now, entries: [],
                                              lastFailure: reason,
                                              retryAfter: now.addingTimeInterval(interval))
        }
    }

    /// ORIGINAL compatibility gate with ANDROID DELTAS 1/2 (see header).
    private func requireCompatibility(_ package: ValidatedSkillPackage) throws {
        let report = SkillCompatibility.evaluate(package, in: androidRuntimeEnvironment())
        guard report.isRunnable else {
            let kinds = report.problems.map { Self.safe($0) }.prefix(8)
            throw ConfigDomainError(code: .needsConfiguration,
                                    reason: "skillCompat[\(Array(kinds).joined(separator: ";"))]")
        }
    }

    private func androidRuntimeEnvironment() -> SkillRuntimeEnvironment {
        SkillRuntimeEnvironment(
            platform: .linux,
            supportedCapabilities: [.workspaceRead, .workspaceWrite, .workspaceDelete,
                                    .network, .browserObserve, .browserInteract],
            registeredTools: Set(registry.allDescriptors.map(\.name)),
            supportsJavaScriptCore: false,
            hasRemoteExecutionHost: false)
    }

    // MARK: static helpers (pure; reused by the authored tests)

    static func packageDirectory(installationRoot: URL, id: String) -> URL {
        installationRoot.appendingPathComponent(id)
    }

    static func hubSourceURL(source: GitHubSkillSource, commit: String,
                             entry: SkillsCatalogCache.Entry) -> String {
        // The ORIGINAL immutable blob shape accepted by
        // OfficialSkillHub.acceptsBundledUpgrade (OfficialSkillHub.swift:21-26).
        "https://github.com/\(source.owner)/\(source.repository)/blob/\(commit)/\(entry.path)"
    }

    static func upgradeSourceURL(for candidate: SkillUpgradeCandidate) -> String {
        "https://github.com/\(candidate.source.owner)/\(candidate.source.repository)"
            + "/blob/\(candidate.commit)/\(candidate.source.path)"
    }

    static func sidecarManifest(for row: PersistedSkill) -> SkillManifest? {
        try? JSONDecoder().decode(SkillManifest.self, from: Data(row.manifestJSON.utf8))
    }

    static func manifestObject(_ manifest: SkillManifest) -> sending [String: Any] {
        ["schemaVersion": manifest.schemaVersion, "id": manifest.id,
         "version": manifest.version, "capabilities": manifest.capabilities,
         "tools": manifest.tools, "platforms": manifest.platforms,
         "scriptRuntime": manifest.scriptRuntime.rawValue,
         "pythonPackages": manifest.pythonPackages.map {
             ["spec": $0.spec, "purpose": $0.purpose,
              "capabilities": $0.capabilities] as [String: Any]
         }]
    }

    static func compatibilityJSON(_ package: ValidatedSkillPackage,
                                  registered: [ToolCatalog.Descriptor]) throws -> String {
        let environment = SkillRuntimeEnvironment(
            platform: .linux,
            supportedCapabilities: [.workspaceRead, .workspaceWrite, .workspaceDelete,
                                    .network, .browserObserve, .browserInteract],
            registeredTools: Set(registered.map(\.name)),
            supportsJavaScriptCore: false,
            hasRemoteExecutionHost: false)
        let report = SkillCompatibility.evaluate(package, in: environment)
        let problems = report.problems.map { problem -> [String: String] in
            ["kind": safe(problem)]
        }
        return try canonicalString(["isRunnable": report.isRunnable, "problems": problems])
    }

    /// The ORIGINAL revision gate for skill.<id> mutations. New identity ⇒
    /// explicit create intent only (never a fabricated version); existing ⇒
    /// digest CAS against the actual row (SkillStore expectedDigest).
    static func checkRevision(existing: PersistedSkill?, revision: ConfigRevision?,
                              createIntent: Bool, skillID: String) throws {
        if let existing {
            guard !createIntent else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "createConflict")
            }
            guard let revision, revision.resourceID == "skill.\(skillID)",
                  revision.version == existing.rewrittenDigest else {
                throw ConfigDomainError(code: .staleRevision, reason: "skillEnvelopeRevision")
            }
        } else {
            guard createIntent else {
                throw ConfigDomainError(code: .notFound, reason: "skillRowMissing")
            }
            guard revision == nil else {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "revisionForNewIdentity")
            }
        }
    }

    static func rejectVersionRegression(oldVersion: String, newVersion: String) throws {
        let old = oldVersion.split(separator: ".").compactMap { Int($0) }
        let new = newVersion.split(separator: ".").compactMap { Int($0) }
        if let difference = zip(old, new).first(where: { $0.0 != $0.1 }),
           difference.1 < difference.0 {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "versionRegression")
        }
    }

    static func identifier(for name: String) throws -> String {
        // ⇄ SkillsCenter.identifier (:1188-1199) EXACT original rule:
        // Latin-fold, lowercase, every non-ASCII-alphanumeric becomes "-",
        // collapse empty pieces. The Foundation `.toLatin`/`.stripDiacritics`
        // transforms are the ones the original used; an unavailable
        // transform degrades to the raw name (still ASCII-normalized below).
        let latin = name.applyingTransform(.toLatin, reverse: false)?
            .applyingTransform(.stripDiacritics, reverse: false) ?? name
        let normalized = latin.lowercased().map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber)
                ? character : "-"
        }
        let id = String(normalized).split(separator: "-")
            .filter { !$0.isEmpty }.joined(separator: "-")
        try SkillIdentifier.validate(id)
        return id
    }

    static func yamlScalar(_ value: String) -> String {
        // Defensive single-line scalar (the original writes the same shape
        // from name/description strings; newlines would corrupt frontmatter).
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    static func writeFiles(_ files: [String: Data], into root: URL,
                           fileManager: FileManager) throws {
        for (path, data) in files {
            try FinderSkillEnvelope.validateRelativePath(path)
            let url = root.appendingPathComponent(path)
            let directory = url.deletingLastPathComponent()
            if directory.path != root.path {
                guard directory.standardizedFileURL.path
                    .hasPrefix(root.standardizedFileURL.path + "/") else {
                    throw SkillValidationError.unsafePath(path)
                }
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try data.write(to: url, options: .atomic)
        }
    }

    static func writeSnapshotFiles(_ files: [String: Data], into directory: URL,
                                   fileManager: FileManager) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeFiles(files, into: directory, fileManager: fileManager)
        // The ORIGINAL validator accepts manifest-less packages through the
        // deterministic derivation (requireManifest: false); snapshots of
        // such packages must restore identically.
        _ = try SkillPackageValidator().validate(packageAt: directory, requireManifest: false)
    }

    static func collectDirectoryFiles(_ directory: URL, fileManager: FileManager = .default)
        throws -> [String: Data] {
        var files: [String: Data] = [:]
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw ConfigDomainError(code: .notFound, reason: "stagingDirectoryMissing")
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                throw SkillValidationError.symbolicLink(url.path)
            }
            guard values?.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path
                .dropFirst(directory.standardizedFileURL.path.count + 1))
            guard !relative.isEmpty else { continue }
            files[relative] = try Data(floeContentsOf: url, options: [.mappedIfSafe])
        }
        return files
    }

    static func text(at url: URL, fileManager: FileManager) -> String {
        _ = fileManager
        guard let data = try? Data(floeContentsOf: url, options: [.mappedIfSafe]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func readManifestID(at directory: URL) -> String? {
        let url = directory.appendingPathComponent("floe.json")
        guard let data = try? Data(floeContentsOf: url, options: [.mappedIfSafe]),
              let manifest = try? JSONDecoder().decode(SkillManifest.self, from: data) else {
            return nil
        }
        return manifest.id
    }

    /// The ORIGINAL provenance init takes a URL and sanitizes userinfo/
    /// query/fragment (SkillInstallStagingService.swift:17-22). Sources are
    /// the closed ours-schemes or validated https URLs; an unparseable
    /// source falls back to a non-network sentinel URL (never a path).
    static func provenanceURL(_ raw: String) -> URL {
        URL(string: raw) ?? URL(string: "floe-source://invalid")!
    }

    static func canonicalData(_ object: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.sortedKeys]) else {
            throw ConfigDomainError(code: .persistenceUnavailable, reason: "jsonEncode")
        }
        return data
    }

    static func canonicalString(_ object: Any) throws -> String {
        String(decoding: try canonicalData(object), as: UTF8.self)
    }

    /// ORIGINAL rewrite rule (SkillsCenter:468-474): only shrink; identity
    /// and version fixed; missing→present manifest is a widening.
    static func validateRewrite(originalMarkdown: String, originalManifest: Data?,
                                rewrittenMarkdown: String, rewrittenManifest: Data?) throws {
        guard !rewrittenMarkdown.isEmpty else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "rewriteEmpty")
        }
        guard originalManifest != nil || rewrittenManifest == nil else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "rewriteAddedManifest")
        }
        guard let originalManifest, let rewrittenManifest else { return }
        guard let before = try? JSONDecoder().decode(SkillManifest.self, from: originalManifest),
              let after = try? JSONDecoder().decode(SkillManifest.self, from: rewrittenManifest)
        else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "rewriteManifestShape")
        }
        guard Set(after.capabilities).isSubset(of: Set(before.capabilities)),
              Set(after.tools).isSubset(of: Set(before.tools)),
              after.id == before.id, after.version == before.version else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "rewriteWidened")
        }
    }

    static func validatedAppVersion(_ raw: String?) -> String? {
        guard let raw, raw.utf8.count <= 64,
              raw.allSatisfy({ $0.isNumber || $0 == "." }),
              !raw.split(separator: ".").isEmpty,
              raw.split(separator: ".").count >= 2 else { return nil }
        return raw
    }

    static func project(candidate: SkillUpgradeCandidate, token: String) -> SkillsReviewProjection {
        SkillsReviewProjection(token: token,
                               skillID: candidate.snapshot.package.manifest.id,
                               version: candidate.snapshot.package.manifest.version,
                               committed: false,
                               changedFiles: candidate.changedFiles,
                               addedCapabilities: candidate.addedCapabilities.sorted(),
                               addedTools: candidate.addedTools.sorted(),
                               releaseNotes: candidate.releaseNotes)
    }

    static func ownedWorkAttachError(_ rejection: ConfigOwnedWorkLifecycle.BeginRejection)
        -> ConfigDomainError {
        switch rejection {
        case .noAdmittedEpoch:
            return ConfigDomainError(code: .runtimeUnavailable, reason: "noAdmittedRuntimeEpoch")
        case .invalidOwnerIdentity:
            return ConfigDomainError(code: .invalidEnvelope, reason: "ownedWorkInvalidOwner")
        case .rejected(let code):
            return ConfigDomainError(code: .runtimeUnavailable, reason: "ownedWorkRejected.\(code)")
        }
    }

    /// Maps ORIGINAL typed errors onto frozen wire codes. Names/enums only —
    /// never file contents, paths or secret material.
    static func mapSkillError(_ error: Error) -> Error {
        if let domain = error as? ConfigDomainError { return domain }
        if let refusal = error as? SkillsDomainRefusal { return ConfigDomainError(refusal) }
        if error is CancellationError {
            return ConfigDomainError(code: .runtimeUnavailable, reason: "cancelled")
        }
        if error is SkillValidationError {
            return ConfigDomainError(code: .invalidEnvelope, reason: "package.\(safe(error))")
        }
        if error is OfficialSkillHub.Failure || error is SignedContentFailure {
            return ConfigDomainError(code: .invalidEnvelope, reason: "hub.\(safe(error))")
        }
        if error is SkillUpgradeError || error is SkillInstallError {
            return ConfigDomainError(code: .invalidEnvelope, reason: "upgrade.\(safe(error))")
        }
        if error is SkillStoreConflict {
            return ConfigDomainError(code: .staleRevision, reason: "skillCAS")
        }
        if error is FloeError {
            return ConfigDomainError(code: .invalidEnvelope, reason: "validation")
        }
        return ConfigDomainError(code: .runtimeUnavailable, reason: redacted(error))
    }

    static func cursorIndex(_ cursor: String?, count: Int) throws -> Int {
        guard let cursor else { return 0 }
        guard let value = Int(cursor), value >= 0, value <= count else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "cursorOutOfRange")
        }
        return value
    }

    /// Closed machine identifier projection: enum reflection filtered to
    /// identifier characters; content strings NEVER pass through here.
    static func safe(_ value: Any) -> String {
        let described = String(describing: value)
        var result = ""
        for scalar in described.unicodeScalars.prefix(96) {
            let isIdentifierChar = (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
                || scalar == "." || scalar == "_"
            if isIdentifierChar { result.unicodeScalars.append(scalar) }
        }
        return result.isEmpty ? "typed" : result
    }

    static func redacted(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        return "failed.\(safe(String(describing: type(of: error))))"
    }

    static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - RB4 runtime selection projection (public DTO for binding)

/// The exact Configuration inputs the ORIGINAL runtime consumes
/// (FloeAgentRuntime.Configuration:357-365), computed from the ORIGINAL
/// stores only. RB4/Main binds it; this package never runs a model loop.
public struct SkillsRuntimeSelection: Sendable, Equatable {
    public let activeSkillIDs: Set<String>
    public let relatedSkillIDsByTool: [String: [String]]
    public let allowedToolNames: Set<String>
    public let preapprovedPythonScriptSHA256: Set<String>
    public let preapprovedPythonPackages: Set<String>
}

// MARK: - SkillCreating / SkillManaging tool-seam facades

/// The ORIGINAL tool seam (SkillToolRegistration.registerSkillTools). Main
/// calls it ONLY once a real RB4 run processor is bound for creator flows;
/// the facades carry no hardcoded generated skill and reuse the same
/// funnels/CAS as the wire path (the App LocalSkillCreator bridge shape,
/// behavior reference only).
public struct SkillsDomainCreatingFacade: SkillCreating, Sendable {
    public let domain: SkillsDomain
    public init(domain: SkillsDomain) { self.domain = domain }
    public func create(_ request: SkillCreationRequest) async throws -> CreatedSkill {
        let projection = try await domain.createSkill(draft: request)
        return CreatedSkill(id: projection.skillID, name: request.name,
                            version: projection.version)
    }
}

public struct SkillsDomainManagingFacade: SkillManaging, Sendable {
    public let domain: SkillsDomain
    public init(domain: SkillsDomain) { self.domain = domain }
    public func read(id: String?) async throws -> [ManagedSkill] {
        try await domain.readManaged(id: id)
    }
    public func manage(_ request: SkillManageTool.Arguments) async throws -> String {
        try await domain.manageViaTool(request)
    }
}

extension SkillsDomain {
    /// The ORIGINAL SkillManaging.read shape minus the G03 python probe
    /// enrichment (SkillsCenter:669-695): metadata for list reads; full
    /// markdown + requiredToolNames for an exact id read.
    func readManaged(id: String?) async throws -> [ManagedSkill] {
        let rows = try await store.all()
        var output: [ManagedSkill] = []
        for row in rows {
            if let id, row.id != id { continue }
            var required = Set(Self.sidecarManifest(for: row)?.tools ?? [])
            if let definition = BundledDomainSkills.all.first(where: { $0.id == row.id }) {
                required.formUnion(definition.automaticallyLoadedToolNames)
            }
            var descriptionText: String?
            if let metadata = try? validator.parseSkillMarkdown(Data(row.skillMarkdown.utf8)) {
                descriptionText = String(metadata.description.prefix(1_024))
            }
            let packageURL = Self.packageDirectory(installationRoot: installationRoot, id: row.id)
            output.append(ManagedSkill(
                id: row.id, name: row.name, version: row.version,
                enabled: row.status == "enabled",
                digest: row.rewrittenDigest,
                markdown: id == nil ? nil : Self.text(at: packageURL
                    .appendingPathComponent("SKILL.md"), fileManager: .default),
                requiredToolNames: required.isEmpty ? nil : required.sorted(),
                currentDigest: row.rewrittenDigest,
                description: descriptionText))
        }
        return output
    }

    /// The ORIGINAL tool-path manage (SkillsCenter.manageSkill :697-757).
    /// The SkillManageTool.execute approval gate (context.approvalGrantID)
    /// stays in the tool layer; this is what the gate protects. Official
    /// ids are read-only for content updates (original :730-732).
    func manageViaTool(_ request: SkillManageTool.Arguments) async throws -> String {
        let revision = ConfigRevision(resourceID: "skill.\(request.id)",
                                      version: request.expectedDigest)
        switch request.action {
        case .setEnabled:
            guard let enabled = request.enabled else {
                throw FloeError.validationFailed("enabled required")
            }
            _ = try await setEnabled(skillID: request.id, revision: revision, enabled: enabled)
            return "status=applied id=\(request.id)"
        case .remove:
            let reply = try await uninstall(skillID: request.id, revision: revision)
            let recoveryAvailable = (reply["recoveryAvailable"] as? Bool) ?? false
            return "status=removed id=\(request.id) recoverable=\(recoveryAvailable)"
        case .update:
            guard let markdown = request.instructions else {
                throw FloeError.validationFailed("instructions required")
            }
            _ = try await updateInstructions(skillID: request.id, markdown: markdown,
                                             expectedDigest: request.expectedDigest)
            return "status=applied id=\(request.id)"
        }
    }

    /// ⇄ the original update branch (:730-757): official ids refused;
    /// frontmatter preserved and body swapped; staged revalidation with the
    /// sidecar manifest; staging-service commit with rewriteModelID
    /// "instruction-update"; store.updateInstructions CAS.
    private func updateInstructions(skillID: String, markdown: String,
                                    expectedDigest: String) async throws -> sending [String: Any] {
        _ = try requireBinding()
        guard !OfficialSkillHub.skillIDs.contains(skillID) else {
            throw ConfigDomainError(code: .invalidEnvelope, reason: "officialReadOnly")
        }
        try SkillManageTool.validateID(skillID)
        let rows = try await store.all()
        guard let row = rows.first(where: { $0.id == skillID }) else {
            throw ConfigDomainError(code: .notFound, reason: "skillRowMissing")
        }
        guard row.rewrittenDigest == expectedDigest else {
            throw ConfigDomainError(code: .staleRevision, reason: "skillCAS")
        }
        guard inflightSkills.insert(skillID).inserted else {
            throw ConfigDomainError(code: .duplicateInFlight, reason: "skillOperationActive")
        }
        defer { inflightSkills.remove(skillID) }
        let packageDirectory = Self.packageDirectory(installationRoot: installationRoot, id: skillID)
        let existingText = Self.text(at: packageDirectory.appendingPathComponent("SKILL.md"),
                                     fileManager: fileManager)
        let combined = Self.preservingFrontmatter(existingMarkdown: existingText,
                                                  newBody: markdown)
        let stagingRoot = try makeStagingDirectory(namespace: "update")
        let packageRoot = stagingRoot.appendingPathComponent("package")
        do {
            var files = try Self.collectDirectoryFiles(packageDirectory, fileManager: fileManager)
            files["SKILL.md"] = Data(combined.utf8)
            try fileManager.createDirectory(at: packageRoot, withIntermediateDirectories: false)
            try Self.writeFiles(files, into: packageRoot, fileManager: fileManager)
            let override = Self.sidecarManifest(for: row)
            let package = try validator.validate(packageAt: packageRoot,
                                                 requireManifest: override == nil,
                                                 manifestOverride: override)
            try requireCompatibility(package)
            let staging = SkillInstallStagingService(installationRoot: installationRoot,
                                                     validator: validator)
            let lease: ConfigOwnedWorkLease
            switch ownedWork.begin(kind: .tool, ownerID: skillID) {
            case .success(let started): lease = started
            case .failure(let rejection): throw Self.ownedWorkAttachError(rejection)
            }
            defer { ownedWork.settle(lease) }
            _ = try await staging.installRewrittenPackage(
                at: packageRoot,
                provenance: SkillInstallProvenance(
                    sourceURL: Self.provenanceURL(row.sourceURL ?? "local-file://update"),
                    originalSHA256: expectedDigest,
                    expectedRewrittenSHA256: package.canonicalSHA256,
                    rewriteModelID: "instruction-update",
                    compatibilitySummary: "instruction-update"),
                replaceExisting: true,
                manifestOverride: override,
                now: Date())
            try await store.updateInstructions(id: skillID, markdown: combined,
                                               digest: package.canonicalSHA256,
                                               expectedDigest: expectedDigest)
            cleanup(stagingRoot)
            return ["state": "applied", "skillID": skillID, "digest": package.canonicalSHA256]
        } catch {
            cleanup(stagingRoot)
            throw Self.mapSkillError(error)
        }
    }

    /// ORIGINAL frontmatter preservation (SkillsCenter:736-741): keep the
    /// existing `---` YAML block, replace the body.
    static func preservingFrontmatter(existingMarkdown: String, newBody: String) -> String {
        if existingMarkdown.hasPrefix("---") {
            let searchRange = existingMarkdown.index(after: existingMarkdown.startIndex)..<existingMarkdown.endIndex
            if let end = existingMarkdown.range(of: "\n---", options: [], range: searchRange) {
                let frontmatter = String(existingMarkdown[..<end.upperBound])
                return frontmatter + "\n\n" + newBody
            }
        }
        return newBody
    }
}

// MARK: - Wire-code mapping at the router boundary

extension ConfigDomainError {
    /// Maps a domain refusal onto the frozen vocabulary (no new codes).
    init(_ refusal: SkillsDomainRefusal) {
        switch refusal {
        case .runtimeNotReady:
            self.init(code: .runtimeUnavailable, reason: "storeNotReady")
        case .staleGeneration:
            self.init(code: .runtimeUnavailable, reason: "staleGeneration")
        case .transportUnavailable:
            self.init(code: .transportUnavailable, reason: "remoteTransport")
        case .rewriteUnavailable:
            self.init(code: .needsConfiguration, reason: "modelRewriteUnbound")
        case .appVersionUnbound:
            self.init(code: .needsConfiguration, reason: "appVersionUnbound")
        }
    }
}
