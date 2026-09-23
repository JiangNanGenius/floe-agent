// FloeExecution — Runtime v2 immutable software templates and private
// environment reuse.
//
// Reuse hierarchy (one direction, no growing chains):
//
//   verified base image (content-addressed blobs + rebuildable expanded view)
//     → immutable software template version: a COMPLETE installed disk (real
//       in-guest installs plus the guest's own package DB) stored once as a
//       content-addressed blob. The version row records the content digest,
//       architecture, parent source, package listing, verification state,
//       measured logical/allocated/download bytes and its reference counts.
//       A verified version is never mutated: a new install is a new version.
//     → environment: an APFS clone of exactly one pinned template version plus
//       the environment's private block delta (environments/<id>/system/
//       delta.*). Several sessions of one environment share that install and
//       its localhost services but only one holds the write lease; separate
//       environments never share apt/global-npm/managed-venv state, and
//       project dependencies stay in workspaces (reference-only).
//
// Download caches (cache/{apt,pip,npm,cargo}) hold shared download objects
// only — never install state. A cache hit is not a reuse claim, and nothing
// here deduplicates arbitrary installs: only byte-identical content shares a
// blob.
//
// Build orchestration: staging clones the parent disk first (APFS clonefile,
// with a space-checked byte-copy fallback whose mode is recorded), the
// installer runs the real installs over that clone, and completion verifies
// the recipe against the real package listing before the atomic registry
// switch. Private state (home, workspace mounts, credentials, shell history)
// is never a clone source: only verified base images and verified template
// versions can be parents, and a clean rebuild re-runs the recorded recipe
// from the original verified parent.
//
// Official templates ("basic", "dev-document") are registered from the actual
// image artifact via `registerOfficialTemplate`; until that artifact exists
// the status is an explicit dependency-missing report (owner D), never a
// placeholder or an empty recipe.

import Foundation
import FloeCore

// MARK: - Immutable pin

/// The immutable identity an environment is pinned to: exactly this template
/// version and content digest, or fail closed. Never "latest".
public struct RuntimeV2TemplatePin: Codable, Sendable, Equatable, Hashable {
    public var templateID: String
    public var version: Int
    public var digest: String

    public init(templateID: String, version: Int, digest: String) {
        self.templateID = templateID
        self.version = version
        self.digest = digest
    }

    public var slot: String { "\(templateID)@\(version)" }

    public var describedIdentity: String { "\(slot) (\(digest.prefix(16))…)" }
}

// MARK: - Software manifest (recipe)

/// The software manifest a template version is built from. Schema mirrors the
/// CI-side recipe files (`FloeAgent/LinuxGuest/image/templates/<name>.json`):
/// package name → null (any version) or `{"min_version": "X"}`.
public struct RuntimeV2TemplateRecipe: Codable, Sendable, Equatable {
    public struct Requirement: Sendable, Equatable {
        public var minVersion: String?

        public init(minVersion: String? = nil) {
            self.minVersion = minVersion
        }
    }

    public var schema: Int
    public var name: String
    public var description: String?
    public var packages: [String: Requirement]

    public static let currentSchema = 1

    public init(
        schema: Int = RuntimeV2TemplateRecipe.currentSchema,
        name: String,
        description: String? = nil,
        packages: [String: Requirement]
    ) {
        self.schema = schema
        self.name = name
        self.description = description
        self.packages = packages
    }

    public enum CodingKeys: String, CodingKey {
        case schema, name, description, packages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schema = try container.decodeIfPresent(Int.self, forKey: .schema) ?? Self.currentSchema
        self.name = try container.decode(String.self, forKey: .name)
        self.description = try container.decodeIfPresent(String.self, forKey: .description)
        self.packages = try container.decode([String: Requirement].self, forKey: .packages)
    }

    /// Validates the recipe shape. An empty requirement set is NOT a recipe:
    /// the CI qualifier and this build path both refuse it so a missing image
    /// can never be papered over with a placeholder.
    public func validate() throws {
        guard schema == Self.currentSchema else {
            throw RuntimeV2Error.templateRecipeInvalid(reason: "unsupported recipe schema \(schema)")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == name else {
            throw RuntimeV2Error.templateRecipeInvalid(reason: "recipe name is empty or padded")
        }
        guard !packages.isEmpty else {
            throw RuntimeV2Error.templateRecipeInvalid(reason: "an empty requirement set is not a recipe")
        }
        for (package, requirement) in packages {
            guard !package.isEmpty,
                  package.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." || $0 == "+" }) else {
                throw RuntimeV2Error.templateRecipeInvalid(reason: "invalid package name '\(package)'")
            }
            if let minimum = requirement.minVersion {
                guard !minimum.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw RuntimeV2Error.templateRecipeInvalid(
                        reason: "package '\(package)' declares an empty min_version"
                    )
                }
            }
        }
    }

    /// Deterministic JSON used for the content digest and for storage. Sorted
    /// keys and no timestamps: two identical manifests always hash identically.
    public func canonicalJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard let text = String(data: data, encoding: .utf8) else {
            throw RuntimeV2Error.templateRecipeInvalid(reason: "recipe is not UTF-8 encodable")
        }
        return text
    }

    /// Loads and validates a recipe file (the CI-side template JSON).
    public static func load(from url: URL, fileManager: FileManager = .default) throws -> RuntimeV2TemplateRecipe {
        guard fileManager.fileExists(atPath: url.path) else {
            throw RuntimeV2Error.templateRecipeInvalid(
                reason: "recipe file missing at \(url.lastPathComponent); the official template image is provided by "
                    + RuntimeV2TemplateCatalog.dependencyOwner
            )
        }
        let recipe: RuntimeV2TemplateRecipe
        do {
            recipe = try JSONDecoder().decode(RuntimeV2TemplateRecipe.self, from: Data(contentsOf: url))
        } catch {
            throw RuntimeV2Error.templateRecipeInvalid(
                reason: "recipe \(url.lastPathComponent) does not decode: \(error.localizedDescription)"
            )
        }
        try recipe.validate()
        return recipe
    }
}

extension RuntimeV2TemplateRecipe.Requirement: Codable {
    enum CodingKeys: String, CodingKey {
        case minVersion = "min_version"
    }

    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), single.decodeNil() {
            self.minVersion = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.minVersion = try container.decodeIfPresent(String.self, forKey: .minVersion)
    }

    public func encode(to encoder: Encoder) throws {
        guard let minVersion else {
            var single = encoder.singleValueContainer()
            try single.encodeNil()
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(minVersion, forKey: .minVersion)
    }
}

/// Version ordering for recipe requirements. Handles dotted numeric versions,
/// Debian-style epochs and text suffixes without claiming full dpkg semantics.
public enum RuntimeV2VersionOrder {
    private enum Segment: Equatable {
        case numeric(String)
        case text(String)
    }

    public static func satisfies(_ version: String, atLeast minimum: String) -> Bool {
        compare(version, minimum) >= 0
    }

    public static func compare(_ lhs: String, _ rhs: String) -> Int {
        let (leftEpoch, leftVersion) = splitEpoch(lhs)
        let (rightEpoch, rightVersion) = splitEpoch(rhs)
        if leftEpoch != rightEpoch { return leftEpoch < rightEpoch ? -1 : 1 }
        return compareSegments(segments(of: leftVersion), segments(of: rightVersion))
    }

    private static func splitEpoch(_ version: String) -> (Int, String) {
        guard let index = version.firstIndex(of: ":") else { return (0, version) }
        let prefix = version[version.startIndex..<index]
        guard !prefix.isEmpty, prefix.allSatisfy(\.isNumber), let epoch = Int(prefix) else {
            return (0, version)
        }
        return (epoch, String(version[version.index(after: index)...]))
    }

    private static func compareSegments(_ left: [Segment], _ right: [Segment]) -> Int {
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : nil
            let b = index < right.count ? right[index] : nil
            switch (a, b) {
            case (nil, nil):
                return 0
            case (nil, .some(.numeric(let text))):
                if text.allSatisfy({ $0 == "0" }) { continue }
                return -1
            case (.some(.numeric(let text)), nil):
                if text.allSatisfy({ $0 == "0" }) { continue }
                return 1
            case (nil, .some(.text)):
                return -1
            case (.some(.text), nil):
                return 1
            case (.some(.numeric(let l)), .some(.numeric(let r))):
                if l.count != r.count { return l.count < r.count ? -1 : 1 }
                if l != r { return l < r ? -1 : 1 }
            case (.some(.text(let l)), .some(.text(let r))):
                if l != r { return l < r ? -1 : 1 }
            case (.some(.numeric), .some(.text)), (.some(.text), .some(.numeric)):
                // A numeric run outranks a text run at the same position, so
                // "3.11" > "3.11rc1" while "3.11.0" > "3.11".
                if case .numeric = a { return 1 }
                return -1
            }
        }
        return 0
    }

    private static func segments(of version: String) -> [Segment] {
        var result: [Segment] = []
        var current = ""
        var currentIsNumeric = false
        func flush() {
            guard !current.isEmpty else { return }
            if currentIsNumeric {
                let stripped = String(current.drop { $0 == "0" })
                result.append(.numeric(stripped.isEmpty ? "0" : stripped))
            } else {
                result.append(.text(current))
            }
            current = ""
        }
        for character in version {
            let isNumeric = character.isNumber
            if current.isEmpty {
                currentIsNumeric = isNumeric
                current.append(character)
            } else if isNumeric == currentIsNumeric {
                current.append(character)
            } else {
                flush()
                currentIsNumeric = isNumeric
                current.append(character)
            }
        }
        flush()
        return result
    }
}

// MARK: - Template installer seam

/// The guest-side install runner. Production runs the real package managers
/// inside a TinyEMU guest over the cloned staging disk and returns the guest's
/// own package listing; tests inject a scripted runner. It must not claim
/// `verified` unless the installs were actually verified in the guest.
public protocol RuntimeV2TemplateInstaller: Sendable {
    func install(
        build: RuntimeV2TemplateStore.BuildHandle,
        request: RuntimeV2TemplateStore.BuildRequest
    ) async throws -> RuntimeV2TemplateStore.InstallOutcome
}

/// Official-template catalog facts. The recipes live in the repository and the
/// actual images are produced by owner D; neither is invented here.
public enum RuntimeV2TemplateCatalog {
    public static let officialTemplateIDs = ["basic", "dev-document"]
    /// Integration contract K → D: recipes under
    /// `FloeAgent/LinuxGuest/image/templates/<name>.json`.
    public static let recipesRelativeDirectory = "FloeAgent/LinuxGuest/image/templates"
    public static let dependencyOwner = "job-6f5ac974858c47c2 (D)"

    public static func recipeURL(templateID: String, templatesDirectory: URL) -> URL {
        templatesDirectory.appendingPathComponent("\(templateID).json")
    }
}

// MARK: - Template store

public actor RuntimeV2TemplateStore {
    // MARK: types

    public struct ParentSource: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable {
            case baseImage = "base-image"
            case templateVersion = "template-version"
        }

        public var kind: Kind
        public var id: String
        public var version: Int?
        /// The parent's verified content digest at build time (base rootfs
        /// SHA-512 or template content digest).
        public var digest: String

        public init(kind: Kind, id: String, version: Int?, digest: String) {
            self.kind = kind
            self.id = id
            self.version = version
            self.digest = digest
        }
    }

    public enum CloneMode: String, Codable, Sendable {
        /// APFS copy-on-write clone of the parent disk (no byte copy).
        case clone
        /// Space-checked byte copy fallback when cloning is unavailable.
        case copy
        /// A prebuilt artifact imported from outside this host (official
        /// template image); no local clone/copy was performed.
        case imported
    }

    public struct CloneReport: Sendable, Equatable {
        public var mode: CloneMode
        public var sourceBytes: RuntimeV2FileBytes
        public var resultBytes: RuntimeV2FileBytes
        public var availableBeforeCopy: Int64?

        public init(mode: CloneMode, sourceBytes: RuntimeV2FileBytes, resultBytes: RuntimeV2FileBytes, availableBeforeCopy: Int64?) {
            self.mode = mode
            self.sourceBytes = sourceBytes
            self.resultBytes = resultBytes
            self.availableBeforeCopy = availableBeforeCopy
        }
    }

    public struct InstalledSoftware: Codable, Sendable, Equatable {
        public var name: String
        public var version: String
        public var architecture: String?
        public var source: String?
        public var installState: String
        public var digest: String?

        public init(
            name: String, version: String, architecture: String? = nil,
            source: String? = nil, installState: String = "installed", digest: String? = nil
        ) {
            self.name = name
            self.version = version
            self.architecture = architecture
            self.source = source
            self.installState = installState
            self.digest = digest
        }
    }

    public struct BuildRequest: Sendable, Equatable {
        public var templateID: String
        public var version: Int
        public var recipe: RuntimeV2TemplateRecipe
        public var parent: ParentSource
        public var architecture: String
        public var targetCapacityBytes: Int64
        /// Provenance label only (e.g. the environment an official image was
        /// derived from). Never a clone source.
        public var environmentID: String?
        public var provenance: String?
        /// Set when this build is a clean rebuild of an earlier version: the
        /// recipe and parent are reused from that version.
        public var cleanRebuildOf: Int?
        /// Official/catalog templates retain a catalog reference so they are
        /// never collected while the app still offers them.
        public var retainCatalogReference: Bool

        public init(
            templateID: String, version: Int, recipe: RuntimeV2TemplateRecipe,
            parent: ParentSource, architecture: String, targetCapacityBytes: Int64,
            environmentID: String? = nil, provenance: String? = nil,
            cleanRebuildOf: Int? = nil, retainCatalogReference: Bool = false
        ) {
            self.templateID = templateID
            self.version = version
            self.recipe = recipe
            self.parent = parent
            self.architecture = architecture
            self.targetCapacityBytes = targetCapacityBytes
            self.environmentID = environmentID
            self.provenance = provenance
            self.cleanRebuildOf = cleanRebuildOf
            self.retainCatalogReference = retainCatalogReference
        }
    }

    public struct BuildHandle: Sendable, Equatable {
        public var buildID: String
        public var migrationID: String
        public var stagingDirectory: URL
        public var workingDiskURL: URL
        public var parentDiskURL: URL
        public var parentDigest: String
        public var cloneMode: CloneMode
        public var logicalBytes: Int64
        public var allocatedBytes: Int64?
        public var buildStartedAt: Date
        /// Private state that is deliberately NOT part of the clone.
        public var privateStateExcluded: [String]
    }

    public struct InstallOutcome: Sendable, Equatable {
        public var packages: [InstalledSoftware]
        public var downloadBytes: Int64
        /// Software that was requested but could not be obtained. Recorded as
        /// an explicit omission; a non-empty list fails verification.
        public var missingPackages: [String]
        public var notes: [String]
        /// True only after the installer verified the installs in the guest.
        public var verified: Bool
        public var runnerCapabilities: String?

        public init(
            packages: [InstalledSoftware], downloadBytes: Int64,
            missingPackages: [String] = [], notes: [String] = [],
            verified: Bool, runnerCapabilities: String? = nil
        ) {
            self.packages = packages
            self.downloadBytes = downloadBytes
            self.missingPackages = missingPackages
            self.notes = notes
            self.verified = verified
            self.runnerCapabilities = runnerCapabilities
        }
    }

    public struct Registration: Sendable, Equatable {
        public var pin: RuntimeV2TemplatePin
        public var parent: ParentSource
        public var packages: [InstalledSoftware]
        public var missingPackages: [String]
        public var logicalBytes: Int64
        public var allocatedBytes: Int64?
        public var downloadBytes: Int64
        public var buildMode: CloneMode
        public var diskDigest: String
        public var referenceCount: Int
        public var privateStateExcluded: [String]
        public var provenance: String?
    }

    public struct RebuildPlan: Sendable, Equatable {
        public var templateID: String
        public var sourceVersion: Int
        public var newVersion: Int
        public var parent: ParentSource
        public var recipe: RuntimeV2TemplateRecipe
        /// Always excluded from a clean rebuild: no private home, workspace,
        /// credentials or history is ever cloned into a template.
        public var excludedPrivateState: [String]
    }

    public struct OfficialTemplateStatus: Sendable, Equatable {
        public enum State: String, Sendable {
            case verified
            case registeredNotVerified = "registered-not-verified"
            case dependencyMissing = "dependency-missing"
        }

        public var templateID: String
        public var state: State
        public var version: Int?
        public var digest: String?
        public var reason: String?
    }

    public struct OfficialTemplateArtifact: Sendable {
        public var templateID: String
        public var version: Int
        public var recipe: RuntimeV2TemplateRecipe
        public var parent: ParentSource
        public var architecture: String
        public var diskURL: URL
        public var packages: [InstalledSoftware]
        public var downloadBytes: Int64
        public var missingPackages: [String]
        public var installVerified: Bool
        public var provenance: String

        public init(
            templateID: String, version: Int, recipe: RuntimeV2TemplateRecipe,
            parent: ParentSource, architecture: String, diskURL: URL,
            packages: [InstalledSoftware], downloadBytes: Int64,
            missingPackages: [String] = [], installVerified: Bool, provenance: String
        ) {
            self.templateID = templateID
            self.version = version
            self.recipe = recipe
            self.parent = parent
            self.architecture = architecture
            self.diskURL = diskURL
            self.packages = packages
            self.downloadBytes = downloadBytes
            self.missingPackages = missingPackages
            self.installVerified = installVerified
            self.provenance = provenance
        }
    }

    public struct PinnedDiskClone: Sendable, Equatable {
        public var pin: RuntimeV2TemplatePin
        public var mode: CloneMode
        public var logicalBytes: Int64
        public var allocatedBytes: Int64?
        public var rootBaseImageID: String
    }

    /// The exact base disk an environment's private delta is captured against
    /// and applied onto: the pinned template version's immutable disk, or the
    /// verified base image's rootfs for base-only environments. Keeping this
    /// identity in one place means a pinned environment's delta contains ONLY
    /// its private changes — never a second copy of the shared install — and
    /// an old delta can never be replayed over another base.
    public struct DeltaBase: Sendable, Equatable {
        public var diskURL: URL
        /// SHA-512 of `diskURL`'s bytes (the template disk digest or the base
        /// rootfs digest), recorded in the delta header.
        public var digest: String
        public var templatePin: RuntimeV2TemplatePin?
    }

    public struct EnvironmentSessionSharing: Sendable, Equatable {
        public var environmentID: String
        public var pin: RuntimeV2TemplatePin?
        public var writeLeaseRuntimeID: String?
        public var writeLeaseSessionToken: String?
        public var state: String
    }

    public struct TemplateGCReport: Sendable, Equatable {
        public var collected: [String]
        public var skippedPinned: [String]
        public var skippedQuarantined: [String]
        public var releasedBlobDigests: [String]
        public var reclaimableBytes: Int64
        public var notes: [String]
    }

    /// Injectable host seams so clone-failure fallbacks and space checks are
    /// testable without a specific filesystem.
    public struct Seams: Sendable {
        public var cloneFile: @Sendable (String, String) -> Bool
        public var availableBytes: @Sendable (URL) -> Int64?

        public init(
            cloneFile: @escaping @Sendable (String, String) -> Bool,
            availableBytes: @escaping @Sendable (URL) -> Int64?
        ) {
            self.cloneFile = cloneFile
            self.availableBytes = availableBytes
        }

        public static let production = Seams(
            cloneFile: { source, destination in
                #if canImport(Darwin)
                return clonefile(source, destination, 0) == 0
                #else
                return false
                #endif
            },
            availableBytes: { directory in
                (try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                    .volumeAvailableCapacityForImportantUsage
            }
        )
    }

    /// Private state that is never a clone source nor part of a template.
    public static let excludedPrivateState = [
        "home", "workspaces", "credentials", "shell-history", "caches", "conversations"
    ]
    public static let catalogReferenceID = "official-catalog"
    public static let copySpaceMarginBytes: Int64 = 32 << 20
    public static let maximumParentDepth = 4
    public static let defaultGCGrace: TimeInterval = 7 * 24 * 3600

    private let layout: RuntimeV2Layout
    private let registry: RuntimeV2Registry
    private let blobs: RuntimeV2BlobStore
    private let images: RuntimeV2ImageStore
    private let deltas: RuntimeV2DeltaStore
    private let seams: Seams
    private var fileManager: FileManager { .default }

    public init(
        layout: RuntimeV2Layout,
        registry: RuntimeV2Registry,
        blobs: RuntimeV2BlobStore,
        images: RuntimeV2ImageStore,
        deltas: RuntimeV2DeltaStore,
        seams: Seams = .production
    ) {
        self.layout = layout
        self.registry = registry
        self.blobs = blobs
        self.images = images
        self.deltas = deltas
        self.seams = seams
    }

    // MARK: queries

    public func version(templateID: String, version: Int) async throws -> RuntimeV2Registry.SoftwareTemplateRow? {
        try await registry.template(templateID: templateID, version: version)
    }

    public func versions(templateID: String) async throws -> [RuntimeV2Registry.SoftwareTemplateRow] {
        try await registry.templateVersions(templateID: templateID)
    }

    public func latestVerified(templateID: String) async throws -> RuntimeV2Registry.SoftwareTemplateRow? {
        try await registry.latestTemplate(templateID: templateID, state: .verified)
    }

    public func packages(templateID: String, version: Int) async throws -> [InstalledSoftware] {
        try await registry.templatePackages(templateID: templateID, version: version).map {
            InstalledSoftware(
                name: $0.name, version: $0.packageVersion, architecture: $0.architecture,
                source: $0.source, installState: $0.installState, digest: $0.digest
            )
        }
    }

    public func referenceCount(templateID: String, version: Int) async throws -> Int {
        try await registry.templateReferences(templateID: templateID, version: version).count
    }

    /// The base image at the root of a template version's parent chain. A
    /// pinned environment boots the template's rootfs with exactly this
    /// image's kernel/BIOS, and capability claims are evaluated against it.
    public func baseImageID(templateID: String, version: Int) async throws -> String {
        guard let row = try await registry.template(templateID: templateID, version: version) else {
            throw RuntimeV2Error.templateNotFound(templateID: templateID, version: version)
        }
        return try await rootBaseImageID(row)
    }

    public func references(templateID: String, version: Int) async throws -> [RuntimeV2Registry.TemplateReferenceRow] {
        try await registry.templateReferences(templateID: templateID, version: version)
    }

    // MARK: build orchestration

    /// Phase 1: validate, resolve the parent (verified only), clone the parent
    /// disk (clonefile, with a space-checked copy fallback whose mode is
    /// recorded) and open the build in the registry. The returned handle is
    /// what the installer receives; nothing is registered as verified yet.
    public func stageBuild(_ request: BuildRequest) async throws -> BuildHandle {
        try validate(request)
        let resolvedParent = try await resolveParent(request.parent)
        let existing = try await registry.template(templateID: request.templateID, version: request.version)
        switch existing?.state {
        case .verified:
            throw RuntimeV2Error.templateVersionImmutable(
                templateID: request.templateID, version: request.version,
                existingDigest: existing?.digest ?? "", newDigest: "pending-build"
            )
        case .quarantined:
            throw RuntimeV2Error.templateNotVerified(
                templateID: request.templateID, version: request.version,
                reason: existing?.reason ?? "the version was quarantined"
            )
        case .building:
            throw RuntimeV2Error.templateBuildInFlight(
                templateID: request.templateID, version: request.version
            )
        case .failed, .none:
            break
        }

        let buildID = "b-\(UUID().uuidString.lowercased())"
        let staging = layout.runtimeTmpDirectory.appendingPathComponent(
            "template-build-\(buildID)", isDirectory: true
        )
        let workingDisk = staging.appendingPathComponent("disk.img")
        let cloneReport: CloneReport
        do {
            if fileManager.fileExists(atPath: staging.path) {
                try fileManager.removeItem(at: staging)
            }
            try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
            cloneReport = try cloneOrCopy(from: resolvedParent.diskURL, to: workingDisk)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
        if request.targetCapacityBytes > 0 {
            let capacity = min(request.targetCapacityBytes, LinuxGuestDiskLayout.maximumLogicalCapacityBytes)
            try? LinuxGuestRuntimeImagePreparer.growSparseFile(
                at: workingDisk, capacityBytes: capacity, fileManager: fileManager
            )
        }

        let envelope = try Self.envelopeJSON(
            recipe: request.recipe, provenance: request.provenance,
            notes: [], cleanRebuildOf: request.cleanRebuildOf
        )
        let began: Bool
        if existing == nil {
            began = try await registry.beginTemplateVersion(
                templateID: request.templateID, version: request.version, digest: "",
                architecture: request.architecture,
                parentKind: request.parent.kind.rawValue, parentID: request.parent.id,
                parentVersion: request.parent.version, parentDigest: request.parent.digest,
                manifestJSON: envelope, buildID: buildID, stagingPath: staging.path
            )
        } else {
            began = try await registry.reopenTemplateVersion(
                templateID: request.templateID, version: request.version,
                architecture: request.architecture,
                parentKind: request.parent.kind.rawValue, parentID: request.parent.id,
                parentVersion: request.parent.version, parentDigest: request.parent.digest,
                manifestJSON: envelope, buildID: buildID, stagingPath: staging.path
            )
        }
        guard began else {
            try? fileManager.removeItem(at: staging)
            throw RuntimeV2Error.templateBuildInFlight(
                templateID: request.templateID, version: request.version
            )
        }

        let migrationID = "template-\(request.templateID)-v\(request.version)"
        do {
            try await registry.beginMigration(
                id: migrationID, kind: "template-build",
                sourcePath: resolvedParent.diskURL.path, targetPath: staging.path,
                detail: "\(request.templateID)@\(request.version)"
            )
            try await registry.setMigrationPhase(id: migrationID, phase: .copied)
            try await registry.addTemplateReference(
                templateID: request.templateID, version: request.version,
                kind: "build", refID: buildID
            )
        } catch {
            try await registry.failTemplateVersion(
                templateID: request.templateID, version: request.version,
                reason: "build staging failed before the installer ran: \(error.localizedDescription)",
                stagingPath: staging.path
            )
            try? fileManager.removeItem(at: staging)
            throw error
        }

        return BuildHandle(
            buildID: buildID, migrationID: migrationID, stagingDirectory: staging,
            workingDiskURL: workingDisk, parentDiskURL: resolvedParent.diskURL,
            parentDigest: resolvedParent.digest, cloneMode: cloneReport.mode,
            logicalBytes: cloneReport.resultBytes.logicalBytes,
            allocatedBytes: cloneReport.resultBytes.allocatedBytes,
            buildStartedAt: Date(), privateStateExcluded: Self.excludedPrivateState
        )
    }

    /// Phase 2: verify the install outcome against the recipe and the real
    /// package DB, ingest the complete disk, then switch the registry
    /// atomically. A recipe gap or an unverified installer fails the version
    /// with the exact missing software — it is never registered as verified.
    public func completeBuild(
        handle: BuildHandle,
        request: BuildRequest,
        outcome: InstallOutcome
    ) async throws -> Registration {
        guard let row = try await registry.template(templateID: request.templateID, version: request.version),
              row.state == .building, row.buildID == handle.buildID else {
            throw RuntimeV2Error.templateNotVerified(
                templateID: request.templateID, version: request.version,
                reason: "no matching in-flight build for this handle"
            )
        }
        // The parent must not have changed under the build: a template version
        // may never be silently re-based on different bytes.
        let resolvedParent = try await resolveParent(request.parent)
        guard resolvedParent.digest == handle.parentDigest, resolvedParent.digest == row.parentDigest else {
            let failure = RuntimeV2Error.templateParentDigestChanged(
                templateID: request.templateID, version: request.version,
                recorded: row.parentDigest, resolved: resolvedParent.digest
            )
            try await failBuild(handle: handle, request: request, reason: failure.localizedDescription)
            throw failure
        }

        let evidence = Self.evaluate(recipe: request.recipe, outcome: outcome)
        if !outcome.verified {
            let failure = RuntimeV2Error.templateInstallerUnverified(
                reason: "the installer did not confirm an in-guest verification"
            )
            try await failBuild(handle: handle, request: request, reason: failure.localizedDescription)
            throw failure
        }
        // A requirement that is absent OR below its min_version fails the
        // build: the template is never registered as satisfying a recipe it
        // does not actually satisfy.
        let gaps = evidence.missing + evidence.unsatisfied
        if !gaps.isEmpty {
            let failure = RuntimeV2Error.templateRequirementMissing(
                templateID: request.templateID, version: request.version, missing: gaps
            )
            try await failBuild(handle: handle, request: request, reason: failure.localizedDescription)
            throw failure
        }
        if let duplicate = try await conflictingVerifiedVersion(request: request, packages: outcome.packages) {
            let failure = RuntimeV2Error.templateVersionImmutable(
                templateID: request.templateID, version: request.version,
                existingDigest: duplicate, newDigest: "recomputed"
            )
            try await failBuild(handle: handle, request: request, reason: failure.localizedDescription)
            throw failure
        }

        return try await finishRegistration(RegistrationInputs(
            request: request,
            diskURL: handle.workingDiskURL,
            cloneMode: handle.cloneMode,
            packages: outcome.packages,
            missing: gaps,
            downloadBytes: outcome.downloadBytes,
            installVerified: outcome.verified,
            provenance: request.provenance ?? "installer:\(handle.buildID)",
            notes: outcome.notes,
            buildID: handle.buildID,
            migrationID: handle.migrationID,
            stagingDirectory: handle.stagingDirectory
        ))
    }

    /// Full build: stage → installer → complete.
    public func build(
        using installer: any RuntimeV2TemplateInstaller,
        request: BuildRequest
    ) async throws -> Registration {
        let handle = try await stageBuild(request)
        let outcome: InstallOutcome
        do {
            outcome = try await installer.install(build: handle, request: request)
        } catch {
            try? await failBuild(handle: handle, request: request, reason: "installer failed: \(error.localizedDescription)")
            throw error
        }
        return try await completeBuild(handle: handle, request: request, outcome: outcome)
    }

    /// The clean-rebuild interface: a new version rebuilds from the recorded
    /// recipe and the ORIGINAL verified parent (never from a private
    /// environment disk and never by layering on an old version).
    public func cleanRebuildPlan(templateID: String, version: Int, newVersion: Int) async throws -> RebuildPlan {
        guard let row = try await registry.template(templateID: templateID, version: version) else {
            throw RuntimeV2Error.templateNotFound(templateID: templateID, version: version)
        }
        guard let manifestJSON = row.manifestJSON,
              let envelope = Self.decodeEnvelope(manifestJSON) else {
            throw RuntimeV2Error.templateNotVerified(
                templateID: templateID, version: version,
                reason: "the recorded software manifest is missing; a clean rebuild cannot be planned"
            )
        }
        try envelope.recipe.validate()
        return RebuildPlan(
            templateID: templateID, sourceVersion: version, newVersion: newVersion,
            parent: ParentSource(
                kind: ParentSource.Kind(rawValue: row.parentKind) ?? .baseImage,
                id: row.parentID, version: row.parentVersion, digest: row.parentDigest
            ),
            recipe: envelope.recipe,
            excludedPrivateState: Self.excludedPrivateState
        )
    }

    public func rebuild(
        using installer: any RuntimeV2TemplateInstaller,
        templateID: String, version: Int, newVersion: Int,
        architecture: String, targetCapacityBytes: Int64,
        provenance: String? = nil
    ) async throws -> Registration {
        let plan = try await cleanRebuildPlan(templateID: templateID, version: version, newVersion: newVersion)
        let request = BuildRequest(
            templateID: templateID, version: newVersion, recipe: plan.recipe,
            parent: plan.parent, architecture: architecture,
            targetCapacityBytes: targetCapacityBytes,
            provenance: provenance ?? "clean-rebuild-of-\(templateID)@\(version)",
            cleanRebuildOf: version,
            retainCatalogReference: RuntimeV2TemplateCatalog.officialTemplateIDs.contains(templateID)
        )
        return try await build(using: installer, request: request)
    }

    // MARK: official templates (actual images only)

    /// Registers an official template from the image artifact owner D produced
    /// (a complete installed disk plus the guest's own package listing). The
    /// artifact must exist and its digest must match the bytes; a missing
    /// artifact or an unverified install fails with the explicit reason — no
    /// placeholder is ever registered.
    public func registerOfficialTemplate(_ artifact: OfficialTemplateArtifact) async throws -> Registration {
        guard RuntimeV2TemplateCatalog.officialTemplateIDs.contains(artifact.templateID) else {
            throw RuntimeV2Error.templateNotOfficial(templateID: artifact.templateID)
        }
        try artifact.recipe.validate()
        guard !artifact.provenance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeV2Error.templateInstallerUnverified(
                reason: "the official artifact carries no provenance/qualification record"
            )
        }
        guard fileManager.fileExists(atPath: artifact.diskURL.path) else {
            throw RuntimeV2Error.templateNotFound(templateID: artifact.templateID, version: artifact.version)
        }
        let resolvedParent = try await resolveParent(artifact.parent)
        let evidence = Self.evaluate(
            recipe: artifact.recipe,
            outcome: InstallOutcome(
                packages: artifact.packages, downloadBytes: artifact.downloadBytes,
                missingPackages: artifact.missingPackages, notes: [],
                verified: artifact.installVerified
            )
        )
        guard artifact.installVerified else {
            throw RuntimeV2Error.templateInstallerUnverified(
                reason: "the official artifact was not qualified as an installed template"
            )
        }
        let gaps = evidence.missing + evidence.unsatisfied
        guard gaps.isEmpty else {
            throw RuntimeV2Error.templateRequirementMissing(
                templateID: artifact.templateID, version: artifact.version, missing: gaps
            )
        }
        let request = BuildRequest(
            templateID: artifact.templateID, version: artifact.version,
            recipe: artifact.recipe, parent: ParentSource(
                kind: artifact.parent.kind, id: artifact.parent.id,
                version: artifact.parent.version, digest: resolvedParent.digest
            ),
            architecture: artifact.architecture, targetCapacityBytes: 0,
            provenance: artifact.provenance, retainCatalogReference: true
        )
        let diskDigest = try FloeDigest.sha512Hex(ofFileAt: artifact.diskURL)
        let contentDigest = Self.contentDigest(
            parent: request.parent, architecture: request.architecture,
            recipe: request.recipe, packages: artifact.packages
        )
        let existing = try await registry.template(
            templateID: artifact.templateID, version: artifact.version
        )
        if let existing {
            if existing.state == .verified {
                // Identical content re-registers idempotently; anything else
                // under the same version is refused (immutability).
                guard existing.digest == contentDigest, existing.diskDigest == diskDigest else {
                    throw RuntimeV2Error.templateVersionImmutable(
                        templateID: artifact.templateID, version: artifact.version,
                        existingDigest: existing.digest, newDigest: contentDigest
                    )
                }
                return try await registration(from: existing, request: request)
            }
            if existing.state == .building {
                throw RuntimeV2Error.templateBuildInFlight(
                    templateID: artifact.templateID, version: artifact.version
                )
            }
            if existing.state == .quarantined {
                throw RuntimeV2Error.templateNotVerified(
                    templateID: artifact.templateID, version: artifact.version, reason: existing.reason
                )
            }
        }
        let migrationID = "template-\(artifact.templateID)-v\(artifact.version)"
        let importID = "import-\(UUID().uuidString.lowercased())"
        let manifestJSON = try Self.envelopeJSON(
            recipe: artifact.recipe, provenance: artifact.provenance,
            notes: [], cleanRebuildOf: nil
        )
        let began: Bool
        if existing == nil {
            began = try await registry.beginTemplateVersion(
                templateID: artifact.templateID, version: artifact.version,
                digest: contentDigest, architecture: artifact.architecture,
                parentKind: artifact.parent.kind.rawValue, parentID: artifact.parent.id,
                parentVersion: artifact.parent.version, parentDigest: resolvedParent.digest,
                manifestJSON: manifestJSON, buildID: importID, stagingPath: nil
            )
        } else {
            began = try await registry.reopenTemplateVersion(
                templateID: artifact.templateID, version: artifact.version,
                architecture: artifact.architecture,
                parentKind: artifact.parent.kind.rawValue, parentID: artifact.parent.id,
                parentVersion: artifact.parent.version, parentDigest: resolvedParent.digest,
                manifestJSON: manifestJSON, buildID: importID, stagingPath: nil
            )
        }
        guard began else {
            throw RuntimeV2Error.templateBuildInFlight(
                templateID: artifact.templateID, version: artifact.version
            )
        }
        try await registry.beginMigration(
            id: migrationID, kind: "template-import",
            sourcePath: artifact.diskURL.path, targetPath: nil,
            detail: "\(artifact.templateID)@\(artifact.version) from \(artifact.provenance)"
        )
        try await registry.setMigrationPhase(id: migrationID, phase: .copied)
        try await registry.addTemplateReference(
            templateID: artifact.templateID, version: artifact.version,
            kind: "build", refID: importID
        )
        return try await finishRegistration(RegistrationInputs(
            request: request,
            diskURL: artifact.diskURL,
            cloneMode: .imported,
            packages: artifact.packages,
            missing: gaps,
            downloadBytes: artifact.downloadBytes,
            installVerified: true,
            provenance: artifact.provenance,
            notes: [],
            buildID: importID,
            migrationID: migrationID,
            stagingDirectory: nil
        ))
    }

    /// Rebuilds the registration view of an already verified version (used by
    /// an idempotent official re-registration; nothing is re-ingested).
    private func registration(
        from row: RuntimeV2Registry.SoftwareTemplateRow, request: BuildRequest
    ) async throws -> Registration {
        let packages = try await packages(templateID: row.templateID, version: row.version)
        let referenceCount = try await registry.templateReferences(
            templateID: row.templateID, version: row.version
        ).count
        return Registration(
            pin: RuntimeV2TemplatePin(
                templateID: row.templateID, version: row.version, digest: row.digest
            ),
            parent: ParentSource(
                kind: ParentSource.Kind(rawValue: row.parentKind) ?? .baseImage,
                id: row.parentID, version: row.parentVersion, digest: row.parentDigest
            ),
            packages: packages,
            missingPackages: [],
            logicalBytes: row.logicalBytes,
            allocatedBytes: row.allocatedBytes > 0 ? row.allocatedBytes : nil,
            downloadBytes: row.downloadBytes,
            buildMode: CloneMode(rawValue: row.buildMode ?? "") ?? .imported,
            diskDigest: row.diskDigest ?? "",
            referenceCount: referenceCount,
            privateStateExcluded: Self.excludedPrivateState,
            provenance: request.provenance
        )
    }

    /// Honest catalog status for the two official templates. Before D's actual
    /// image is registered this reports `dependency-missing` naming the owner;
    /// it never fabricates a version, digest or package list.
    public func officialTemplateStatus() async throws -> [OfficialTemplateStatus] {
        var statuses: [OfficialTemplateStatus] = []
        for templateID in RuntimeV2TemplateCatalog.officialTemplateIDs {
            if let verified = try await registry.latestTemplate(templateID: templateID, state: .verified) {
                statuses.append(OfficialTemplateStatus(
                    templateID: templateID, state: .verified,
                    version: verified.version, digest: verified.digest, reason: nil
                ))
                continue
            }
            if let latest = try await registry.latestTemplate(templateID: templateID) {
                statuses.append(OfficialTemplateStatus(
                    templateID: templateID, state: .registeredNotVerified,
                    version: latest.version, digest: latest.digest.isEmpty ? nil : latest.digest,
                    reason: latest.reason ?? "the registered version has not been verified"
                ))
                continue
            }
            statuses.append(OfficialTemplateStatus(
                templateID: templateID, state: .dependencyMissing,
                version: nil, digest: nil,
                reason: "no actual template image registered; recipes are "
                    + "\(RuntimeV2TemplateCatalog.recipesRelativeDirectory)/\(templateID).json and the image owner is "
                    + RuntimeV2TemplateCatalog.dependencyOwner
            ))
        }
        return statuses
    }

    /// Loads a recipe file from the repository/CI template directory.
    public nonisolated static func loadRecipe(
        templateID: String, templatesDirectory: URL, fileManager: FileManager = .default
    ) throws -> RuntimeV2TemplateRecipe {
        let recipe = try RuntimeV2TemplateRecipe.load(
            from: RuntimeV2TemplateCatalog.recipeURL(templateID: templateID, templatesDirectory: templatesDirectory),
            fileManager: fileManager
        )
        guard recipe.name == templateID else {
            throw RuntimeV2Error.templateRecipeInvalid(
                reason: "recipe \(recipe.name) does not match template id \(templateID)"
            )
        }
        return recipe
    }

    // MARK: environment pinning

    public func environmentPin(environmentID: String) async throws -> RuntimeV2TemplatePin? {
        guard let row = try await registry.environment(id: environmentID) else { return nil }
        guard let templateID = row.templateID,
              let version = row.templateVersion,
              let digest = row.templateDigest else { return nil }
        return RuntimeV2TemplatePin(templateID: templateID, version: version, digest: digest)
    }

    /// Pins an environment to exactly one verified template version. The
    /// environment's recorded base image must be the template's root base
    /// image, so a pinned boot can never mix a template rootfs with another
    /// image's kernel/BIOS.
    @discardableResult
    public func pinEnvironment(
        environmentID: String, templateID: String, version: Int
    ) async throws -> RuntimeV2TemplatePin {
        guard let environment = try await registry.environment(id: environmentID) else {
            throw RuntimeV2Error.environmentNotFound(environmentID)
        }
        guard let row = try await registry.template(templateID: templateID, version: version) else {
            throw RuntimeV2Error.templateNotFound(templateID: templateID, version: version)
        }
        guard row.state == .verified, row.diskDigest != nil else {
            throw RuntimeV2Error.templateNotVerified(
                templateID: templateID, version: version, reason: row.reason
            )
        }
        let rootImage = try await rootBaseImageID(row)
        if let baseImageID = environment.baseImageID, baseImageID != rootImage {
            throw RuntimeV2Error.templateBaseImageMismatch(
                environmentID: environmentID, templateBaseImage: rootImage,
                environmentBaseImage: baseImageID
            )
        }
        let pin = RuntimeV2TemplatePin(templateID: templateID, version: version, digest: row.digest)
        guard try await registry.pinEnvironmentTemplate(
            environmentID: environmentID, templateID: templateID,
            version: version, digest: row.digest
        ) else {
            throw RuntimeV2Error.environmentNotFound(environmentID)
        }
        try await registry.addTemplateReference(
            templateID: templateID, version: version, kind: "environment", refID: environmentID
        )
        recordPinInMetadata(environmentID: environmentID, pin: pin)
        return pin
    }

    /// Removes the pin (the environment falls back to its base image). Refused
    /// while the environment holds a live write lease: an install state is
    /// never switched under a running guest.
    public func unpinEnvironment(environmentID: String) async throws {
        if let lease = try await registry.lease(environmentID: environmentID), lease.state == "held" {
            throw RuntimeV2Error.templateEnvironmentRunning(environmentID: environmentID)
        }
        if let pin = try await environmentPin(environmentID: environmentID) {
            try await registry.removeTemplateReference(
                templateID: pin.templateID, version: pin.version,
                kind: "environment", refID: environmentID
            )
        }
        try await registry.clearEnvironmentTemplatePin(environmentID: environmentID)
        recordPinInMetadata(environmentID: environmentID, pin: nil)
    }

    /// Read model for the multi-session rule: sessions of one environment
    /// share the install and its localhost services, and exactly one write
    /// lease exists at a time.
    public func sessionSharing(environmentID: String) async throws -> EnvironmentSessionSharing {
        let pin = try await environmentPin(environmentID: environmentID)
        let lease = try await registry.lease(environmentID: environmentID)
        let state = (try await registry.environment(id: environmentID)?.state) ?? "missing"
        return EnvironmentSessionSharing(
            environmentID: environmentID, pin: pin,
            writeLeaseRuntimeID: lease?.state == "held" ? lease?.runtimeID : nil,
            writeLeaseSessionToken: lease?.state == "held" ? lease?.sessionToken : nil,
            state: state
        )
    }

    /// Resolves the base an environment's delta must bind to. For a pinned
    /// environment that is the template version's immutable disk blob (so the
    /// delta holds only the environment's own changes); for a base-only
    /// environment it is the verified base image rootfs the caller resolved.
    public func deltaBase(
        environmentID: String, imageID: String,
        baseRootfs: URL, baseRootfsSHA512: String
    ) async throws -> DeltaBase {
        guard let pin = try await environmentPin(environmentID: environmentID) else {
            return DeltaBase(diskURL: baseRootfs, digest: baseRootfsSHA512.lowercased(), templatePin: nil)
        }
        guard let row = try await registry.template(templateID: pin.templateID, version: pin.version),
              row.state == .verified, let diskDigest = row.diskDigest, row.digest == pin.digest else {
            throw RuntimeV2Error.templatePinUnavailable(
                environmentID: environmentID, templateID: pin.templateID, version: pin.version,
                reason: "the pinned version is not verified and cannot provide a delta base"
            )
        }
        let rootImage = try await rootBaseImageID(row)
        guard rootImage == imageID else {
            throw RuntimeV2Error.templateBaseImageMismatch(
                environmentID: environmentID, templateBaseImage: rootImage,
                environmentBaseImage: imageID
            )
        }
        return DeltaBase(
            diskURL: try await blobs.verifiedBlobURL(digest: diskDigest),
            digest: diskDigest.lowercased(),
            templatePin: pin
        )
    }

    /// Clones the environment's pinned template disk into the working disk
    /// path (APFS clone, or space-checked copy). Returns nil when the
    /// environment has no pin (the caller then clones the verified base image
    /// exactly as before). The caller applies the environment's private delta
    /// afterwards.
    public func clonePinnedTemplateDisk(
        environmentID: String, runtimeID: String, imageID: String, into diskURL: URL
    ) async throws -> PinnedDiskClone? {
        guard let pin = try await environmentPin(environmentID: environmentID) else { return nil }
        guard let row = try await registry.template(templateID: pin.templateID, version: pin.version) else {
            throw RuntimeV2Error.templatePinUnavailable(
                environmentID: environmentID, templateID: pin.templateID, version: pin.version,
                reason: "the pinned version no longer exists"
            )
        }
        guard row.state == .verified, let diskDigest = row.diskDigest else {
            throw RuntimeV2Error.templatePinUnavailable(
                environmentID: environmentID, templateID: pin.templateID, version: pin.version,
                reason: row.reason ?? "the pinned version is not verified"
            )
        }
        guard row.digest == pin.digest else {
            throw RuntimeV2Error.templatePinUnavailable(
                environmentID: environmentID, templateID: pin.templateID, version: pin.version,
                reason: "content digest changed from \(pin.digest.prefix(16))… to \(row.digest.prefix(16))…; "
                    + "the environment is never silently re-pointed"
            )
        }
        let rootImage = try await rootBaseImageID(row)
        guard rootImage == imageID else {
            throw RuntimeV2Error.templateBaseImageMismatch(
                environmentID: environmentID, templateBaseImage: rootImage,
                environmentBaseImage: imageID
            )
        }
        // The blob is the immutable template disk. Clone it to the working
        // path; the environment's delta is applied on top by the caller.
        try await blobs.materialize(digest: diskDigest, at: diskURL, writable: true)
        let bytes = RuntimeV2FileBytes.measure(fileAt: diskURL)
        return PinnedDiskClone(
            pin: pin,
            mode: bytes.measuredSavingsBytes == nil ? .copy : .clone,
            logicalBytes: bytes.logicalBytes, allocatedBytes: bytes.allocatedBytes,
            rootBaseImageID: rootImage
        )
    }

    // MARK: reference recycling + GC

    /// Collects verified versions that nothing references any more (after the
    /// grace window). Environment pins, catalog offers, in-flight builds,
    /// recovery points and quarantine are all protected; a collected version
    /// is quarantined (never hard-deleted) and its blob reference released so
    /// the blob store's own GC may reclaim the bytes.
    public func collectGarbage(
        grace: TimeInterval = RuntimeV2TemplateStore.defaultGCGrace,
        now: Date = Date()
    ) async throws -> TemplateGCReport {
        var report = TemplateGCReport(
            collected: [], skippedPinned: [], skippedQuarantined: [],
            releasedBlobDigests: [], reclaimableBytes: 0, notes: []
        )
        for row in try await registry.unreferencedTemplateVersions() {
            guard row.state == .verified, let diskDigest = row.diskDigest else { continue }
            guard let verifiedAt = row.verifiedAt,
                  now.timeIntervalSince(verifiedAt) >= grace else { continue }
            // Belt and braces: an environment pin is a reference even if the
            // reference row was lost.
            let pinnedByEnvironment = try await registry.environments().contains {
                $0.templateID == row.templateID && $0.templateVersion == row.version
            }
            if pinnedByEnvironment {
                report.skippedPinned.append(row.slotDescription)
                continue
            }
            try await registry.quarantineTemplateVersion(
                templateID: row.templateID, version: row.version,
                reason: "collected: no environment, catalog, build, recovery or quarantine reference after \(Int(grace))s"
            )
            try? await blobs.release(digest: diskDigest)
            report.collected.append(row.slotDescription)
            report.releasedBlobDigests.append(diskDigest)
            if let blob = try await registry.blob(digest: diskDigest), blob.refs == 0 {
                report.reclaimableBytes += blob.bytes
            } else {
                report.notes.append(
                    "blob \(diskDigest.prefix(16))… is still referenced after release; bytes were not counted as reclaimable"
                )
            }
        }
        for row in try await registry.templates(state: .quarantined) {
            report.skippedQuarantined.append(row.slotDescription)
        }
        return report
    }

    /// Finalizes a template build once its replacement proved itself: the
    /// evidence rollback point moves to recovery/trash (still not a hard
    /// delete) and the migration record reaches `done`.
    public func finalizeBuilds() async throws -> Int {
        var finalized = 0
        let pending = try await registry.migrations(inPhases: [.cleanupPending])
        for migration in pending where migration.kind == "template-build" {
            let rollback = layout.recoveryMigrationsDirectory.appendingPathComponent(
                migration.id, isDirectory: true
            )
            if fileManager.fileExists(atPath: rollback.path) {
                let trash = layout.trashDirectory.appendingPathComponent(
                    "\(migration.id)-\(UUID().uuidString)", isDirectory: true
                )
                try? fileManager.moveItem(at: rollback, to: trash)
            }
            if let (templateID, version) = Self.templateSlot(fromMigrationID: migration.id) {
                try? await registry.removeTemplateReference(
                    templateID: templateID, version: version,
                    kind: "recovery", refID: migration.id
                )
            }
            try await registry.setMigrationPhase(id: migration.id, phase: .done)
            finalized += 1
        }
        return finalized
    }

    // MARK: startup recovery

    /// Marks every interrupted build failed honestly and sweeps its temporary
    /// clone (the install was never verified, so nothing may become verified
    /// from it). Returns notes for the startup report.
    public func recoverInterruptedBuilds() async throws -> [String] {
        var notes: [String] = []
        for row in try await registry.templates(state: .building) {
            let reason = "build interrupted before verification; the incomplete install was not registered"
            let staging = row.stagingPath.flatMap { URL(fileURLWithPath: $0) }
            if let staging, fileManager.fileExists(atPath: staging.path) {
                let quarantine = layout.quarantineDirectory.appendingPathComponent(
                    "template-\(row.templateID)-v\(row.version)-\(UUID().uuidString)", isDirectory: true
                )
                do {
                    try fileManager.moveItem(at: staging, to: quarantine)
                    notes.append(
                        "template \(row.templateID)@\(row.version): interrupted build staging quarantined at \(quarantine.lastPathComponent)"
                    )
                } catch {
                    notes.append(
                        "template \(row.templateID)@\(row.version): interrupted build staging could not be quarantined: \(error.localizedDescription)"
                    )
                }
            }
            try await registry.failTemplateVersion(
                templateID: row.templateID, version: row.version, reason: reason
            )
            if let buildID = row.buildID {
                try? await registry.removeTemplateReference(
                    templateID: row.templateID, version: row.version, kind: "build", refID: buildID
                )
            }
            let migrationID = "template-\(row.templateID)-v\(row.version)"
            try? await registry.setMigrationPhase(id: migrationID, phase: .failed, error: reason)
            notes.append("template \(row.templateID)@\(row.version): \(reason)")
        }
        // Orphaned build directories (no building row): temporary clones whose
        // build row is gone are removed after the in-flight window; they are
        // regenerable from the verified parent, and their recipe evidence
        // never lived only here.
        if let entries = try? fileManager.contentsOfDirectory(atPath: layout.runtimeTmpDirectory.path) {
            let cutoff = Date().addingTimeInterval(-Self.orphanedBuildSweepWindow)
            for entry in entries where entry.hasPrefix("template-build-") {
                let url = layout.runtimeTmpDirectory.appendingPathComponent(entry, isDirectory: true)
                let modified = (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
                    ?? .distantPast
                let referenced = (try? await registry.templates(state: .building))?.contains {
                    $0.stagingPath == url.path
                } ?? false
                if !referenced, modified < cutoff {
                    try? fileManager.removeItem(at: url)
                    notes.append("swept orphaned template build directory \(entry)")
                }
            }
        }
        return notes
    }

    // MARK: helpers

    private static let orphanedBuildSweepWindow: TimeInterval = 24 * 3600

    /// Mirrors the pin into the environment's repairable metadata sidecar so a
    /// damaged registry can be rebuilt from verified files. A missing or
    /// undecodable sidecar is left untouched (the registry is the truth).
    private func recordPinInMetadata(environmentID: String, pin: RuntimeV2TemplatePin?) {
        guard let url = try? layout.environmentMetadataURL(environmentID: environmentID),
              let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var metadata = try? decoder.decode(
            RuntimeV2EnvironmentMigrator.EnvironmentMetadata.self, from: data
        ) else { return }
        guard metadata.environmentID == environmentID else { return }
        metadata.templateID = pin?.templateID
        metadata.templateVersion = pin?.version
        metadata.templateDigest = pin?.digest
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let encoded = try? encoder.encode(metadata) {
            try? encoded.write(to: url, options: .atomic)
        }
    }

    private func validate(_ request: BuildRequest) throws {
        try RuntimeV2Identifier.validate(request.templateID, kind: .template)
        guard request.version >= 1 else {
            throw RuntimeV2Error.templateRecipeInvalid(
                reason: "template version must be >= 1 (got \(request.version))"
            )
        }
        guard !request.architecture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuntimeV2Error.templateRecipeInvalid(reason: "architecture is empty")
        }
        try request.recipe.validate()
        // Private state is never a clone source: only verified base images and
        // verified template versions may be parents, and the environment label
        // is provenance only.
        guard request.parent.digest.count == 128,
              request.parent.digest.allSatisfy({ $0.isHexDigit }) else {
            throw RuntimeV2Error.templateRecipeInvalid(reason: "parent digest is not SHA-512 hex")
        }
        try RuntimeV2Identifier.validate(request.parent.id, kind: .image)
        if let environmentID = request.environmentID {
            try RuntimeV2Identifier.validate(environmentID, kind: .environment)
        }
    }

    private struct ResolvedParent: Sendable {
        var diskURL: URL
        var digest: String
        var baseImageID: String
    }

    private func resolveParent(_ parent: ParentSource) async throws -> ResolvedParent {
        switch parent.kind {
        case .baseImage:
            guard try await images.isImageVerified(imageID: parent.id) else {
                throw RuntimeV2Error.unverifiedImageReferenced(parent.id)
            }
            guard let manifest = try await images.manifest(imageID: parent.id),
                  let ref = manifest.artifacts["rootfs"] ?? manifest.artifacts["disk"] else {
                throw RuntimeV2Error.imageNotFound(parent.id)
            }
            guard ref.sha512.lowercased() == parent.digest.lowercased() else {
                throw RuntimeV2Error.templateParentDigestChanged(
                    templateID: parent.id, version: 0,
                    recorded: parent.digest, resolved: ref.sha512
                )
            }
            let expanded = try await images.ensureExpanded(imageID: parent.id)
            let disk = expanded.appendingPathComponent(ref.expandedPath)
            guard fileManager.fileExists(atPath: disk.path) else {
                throw RuntimeV2Error.blobMissing(ref.sha512)
            }
            return ResolvedParent(diskURL: disk, digest: ref.sha512.lowercased(), baseImageID: parent.id)
        case .templateVersion:
            guard let version = parent.version,
                  let row = try await registry.template(templateID: parent.id, version: version) else {
                throw RuntimeV2Error.templateNotFound(templateID: parent.id, version: parent.version ?? 0)
            }
            guard row.state == .verified, let diskDigest = row.diskDigest else {
                throw RuntimeV2Error.templateNotVerified(
                    templateID: parent.id, version: version, reason: row.reason
                )
            }
            guard row.digest == parent.digest else {
                throw RuntimeV2Error.templateParentDigestChanged(
                    templateID: parent.id, version: version,
                    recorded: parent.digest, resolved: row.digest
                )
            }
            return ResolvedParent(
                diskURL: try await blobs.verifiedBlobURL(digest: diskDigest),
                digest: row.digest,
                baseImageID: try await rootBaseImageID(row)
            )
        }
    }

    /// The base image at the root of a template's parent chain. The boot path
    /// must boot a template's rootfs with the SAME image's kernel/BIOS.
    private func rootBaseImageID(_ row: RuntimeV2Registry.SoftwareTemplateRow) async throws -> String {
        var current = row
        var depth = 0
        while current.parentKind == ParentSource.Kind.templateVersion.rawValue {
            guard depth < Self.maximumParentDepth, let version = current.parentVersion,
                  let parent = try await registry.template(templateID: current.parentID, version: version) else {
                throw RuntimeV2Error.templateParentDigestChanged(
                    templateID: row.templateID, version: row.version,
                    recorded: row.parentID, resolved: "parent chain exceeds \(Self.maximumParentDepth) levels"
                )
            }
            current = parent
            depth += 1
        }
        return current.parentID
    }

    private func cloneOrCopy(from source: URL, to destination: URL) throws -> CloneReport {
        let sourceBytes = RuntimeV2FileBytes.measure(fileAt: source)
        guard sourceBytes.logicalBytes > 0 else {
            throw RuntimeV2Error.migrationFailed(
                id: "template-clone", phase: "discovered",
                reason: "the parent disk is empty; nothing was built"
            )
        }
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        if seams.cloneFile(source.path, destination.path),
           fileManager.fileExists(atPath: destination.path) {
            // clonefile preserves the source mode: the parent disk is a
            // read-only verified artifact, so the writable clone must be
            // re-opened for the installer explicitly.
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
            let resultBytes = RuntimeV2FileBytes.measure(fileAt: destination)
            guard resultBytes.logicalBytes == sourceBytes.logicalBytes else {
                throw RuntimeV2Error.migrationFailed(
                    id: "template-clone", phase: "copied",
                    reason: "clone size \(resultBytes.logicalBytes) does not match the parent \(sourceBytes.logicalBytes)"
                )
            }
            return CloneReport(mode: .clone, sourceBytes: sourceBytes, resultBytes: resultBytes, availableBeforeCopy: nil)
        }
        // Copy fallback: the volume does not support clones (or the clone
        // failed). Check the space honestly before writing, then verify the
        // copy size and record the mode as copy.
        let available = seams.availableBytes(destination.deletingLastPathComponent())
        let required = sourceBytes.logicalBytes + Self.copySpaceMarginBytes
        if let available, available < required {
            throw RuntimeV2Error.insufficientSpace(required: required, available: available)
        }
        try? fileManager.removeItem(at: destination)
        try fileManager.copyItem(at: source, to: destination)
        try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
        let resultBytes = RuntimeV2FileBytes.measure(fileAt: destination)
        guard resultBytes.logicalBytes == sourceBytes.logicalBytes else {
            throw RuntimeV2Error.migrationFailed(
                id: "template-clone", phase: "copied",
                reason: "copy size \(resultBytes.logicalBytes) does not match the parent \(sourceBytes.logicalBytes)"
            )
        }
        return CloneReport(mode: .copy, sourceBytes: sourceBytes, resultBytes: resultBytes, availableBeforeCopy: available)
    }

    private struct RegistrationInputs {
        var request: BuildRequest
        var diskURL: URL
        var cloneMode: CloneMode
        var packages: [InstalledSoftware]
        var missing: [String]
        var downloadBytes: Int64
        var installVerified: Bool
        var provenance: String
        var notes: [String]
        var buildID: String?
        var migrationID: String
        var stagingDirectory: URL?
    }

    private func finishRegistration(_ inputs: RegistrationInputs) async throws -> Registration {
        let request = inputs.request
        let bytes = RuntimeV2FileBytes.measure(fileAt: inputs.diskURL)
        guard bytes.logicalBytes > 0 else {
            throw RuntimeV2Error.migrationFailed(
                id: inputs.migrationID, phase: "verified",
                reason: "the installed disk is empty; nothing was registered"
            )
        }
        let diskDigest = try FloeDigest.sha512Hex(ofFileAt: inputs.diskURL)
        // Ingest stages + verifies + atomically renames; identical content is
        // reused, never duplicated.
        let storedDigest = try await blobs.ingest(
            sourceURL: inputs.diskURL, expectedSHA512: diskDigest,
            expectedBytes: bytes.logicalBytes,
            retainFor: "template:\(request.templateID)@\(request.version)"
        )
        let contentDigest = Self.contentDigest(
            parent: request.parent, architecture: request.architecture,
            recipe: request.recipe, packages: inputs.packages
        )
        try await registry.setTemplatePackages(
            templateID: request.templateID, version: request.version,
            packages: inputs.packages.map {
                RuntimeV2Registry.TemplatePackageRow(
                    templateID: request.templateID, version: request.version,
                    name: $0.name, packageVersion: $0.version,
                    architecture: $0.architecture, source: $0.source,
                    installState: $0.installState, digest: $0.digest
                )
            }
        )
        try await registry.setMigrationPhase(id: inputs.migrationID, phase: .switched)
        try await registry.markTemplateVerified(
            templateID: request.templateID, version: request.version,
            digest: contentDigest, diskDigest: storedDigest,
            logicalBytes: bytes.logicalBytes,
            allocatedBytes: bytes.allocatedBytes ?? 0,
            downloadBytes: inputs.downloadBytes,
            buildMode: inputs.cloneMode.rawValue,
            packageCount: inputs.packages.count
        )
        // Evidence + recovery point: the recipe/outcome snapshot moves out of
        // the temporary build directory and stays until finalized.
        try retainEvidence(inputs: inputs, diskDigest: storedDigest, contentDigest: contentDigest)
        if let buildID = inputs.buildID {
            try await registry.removeTemplateReference(
                templateID: request.templateID, version: request.version,
                kind: "build", refID: buildID
            )
        }
        try await registry.addTemplateReference(
            templateID: request.templateID, version: request.version,
            kind: "recovery", refID: inputs.migrationID
        )
        if request.retainCatalogReference {
            try await registry.addTemplateReference(
                templateID: request.templateID, version: request.version,
                kind: "catalog", refID: Self.catalogReferenceID
            )
        }
        try await registry.setMigrationPhase(id: inputs.migrationID, phase: .cleanupPending)
        // The blob is the immutable template now; the large temporary clone
        // (if any) can go.
        if let staging = inputs.stagingDirectory, fileManager.fileExists(atPath: staging.path) {
            try? fileManager.removeItem(at: staging)
        }
        return Registration(
            pin: RuntimeV2TemplatePin(
                templateID: request.templateID, version: request.version, digest: contentDigest
            ),
            parent: request.parent,
            packages: inputs.packages,
            missingPackages: inputs.missing,
            logicalBytes: bytes.logicalBytes,
            allocatedBytes: bytes.allocatedBytes,
            downloadBytes: inputs.downloadBytes,
            buildMode: inputs.cloneMode,
            diskDigest: storedDigest,
            referenceCount: try await registry.templateReferences(
                templateID: request.templateID, version: request.version
            ).count,
            privateStateExcluded: Self.excludedPrivateState,
            provenance: inputs.provenance
        )
    }

    private func retainEvidence(
        inputs: RegistrationInputs, diskDigest: String, contentDigest: String
    ) throws {
        let rollback = layout.recoveryMigrationsDirectory.appendingPathComponent(
            inputs.migrationID, isDirectory: true
        )
        try fileManager.createDirectory(at: rollback, withIntermediateDirectories: true)
        let envelope = try Self.envelopeJSON(
            recipe: inputs.request.recipe, provenance: inputs.provenance,
            notes: inputs.notes, cleanRebuildOf: inputs.request.cleanRebuildOf
        )
        let evidence: [String: Any] = [
            "template": "\(inputs.request.templateID)@\(inputs.request.version)",
            "content_digest": contentDigest,
            "disk_digest": diskDigest,
            "parent_kind": inputs.request.parent.kind.rawValue,
            "parent_id": inputs.request.parent.id,
            "parent_digest": inputs.request.parent.digest,
            "architecture": inputs.request.architecture,
            "build_mode": inputs.cloneMode.rawValue,
            "logical_bytes": String(RuntimeV2FileBytes.measure(fileAt: inputs.diskURL).logicalBytes),
            "install_verified": String(inputs.installVerified),
            "missing_packages": inputs.missing,
            "notes": inputs.notes,
            "recipe": envelope
        ]
        let data = try JSONSerialization.data(
            withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]
        )
        try data.write(to: rollback.appendingPathComponent("template-evidence.json"), options: .atomic)
    }

    private func failBuild(handle: BuildHandle, request: BuildRequest, reason: String) async throws {
        // Preserve the incomplete install as quarantine evidence, never as a
        // bootable version: the bytes were not verified.
        var quarantinePath: String?
        if fileManager.fileExists(atPath: handle.stagingDirectory.path) {
            let quarantine = layout.quarantineDirectory.appendingPathComponent(
                "template-\(request.templateID)-v\(request.version)-\(UUID().uuidString)", isDirectory: true
            )
            if (try? fileManager.moveItem(at: handle.stagingDirectory, to: quarantine)) != nil {
                quarantinePath = quarantine.path
            }
        }
        try? await registry.failTemplateVersion(
            templateID: request.templateID, version: request.version,
            reason: reason, stagingPath: quarantinePath
        )
        try? await registry.removeTemplateReference(
            templateID: request.templateID, version: request.version,
            kind: "build", refID: handle.buildID
        )
        try? await registry.setMigrationPhase(id: handle.migrationID, phase: .failed, error: reason)
    }

    private func conflictingVerifiedVersion(
        request: BuildRequest, packages: [InstalledSoftware]
    ) async throws -> String? {
        guard let existing = try await registry.template(
            templateID: request.templateID, version: request.version
        ), existing.state == .verified, !existing.digest.isEmpty else { return nil }
        let digest = Self.contentDigest(
            parent: request.parent, architecture: request.architecture,
            recipe: request.recipe, packages: packages
        )
        return digest == existing.digest ? nil : existing.digest
    }

    // MARK: pure helpers (nonisolated + testable)

    /// Recipe evaluation against the real package listing. Every requirement
    /// must be installed at >= min_version; anything else is an explicit
    /// missing/unsatisfied entry.
    public nonisolated static func evaluate(
        recipe: RuntimeV2TemplateRecipe, outcome: InstallOutcome
    ) -> (missing: [String], unsatisfied: [String]) {
        var installed: [String: InstalledSoftware] = [:]
        for package in outcome.packages {
            if installed[package.name] == nil { installed[package.name] = package }
        }
        var missing: [String] = []
        var unsatisfied: [String] = []
        for (name, requirement) in recipe.packages.sorted(by: { $0.key < $1.key }) {
            guard let package = installed[name], package.installState == "installed" else {
                missing.append(name)
                continue
            }
            if let minimum = requirement.minVersion, !RuntimeV2VersionOrder.satisfies(package.version, atLeast: minimum) {
                unsatisfied.append("\(name) (\(package.version) < \(minimum))")
            }
        }
        for reported in outcome.missingPackages.sorted() where !missing.contains(reported) {
            missing.append(reported)
        }
        return (missing, unsatisfied)
    }

    /// Deterministic content digest: parent + architecture + recipe + the real
    /// installed package list. Timestamps, host paths and download counts are
    /// deliberately excluded so the same software hashes identically.
    public nonisolated static func contentDigest(
        parent: ParentSource, architecture: String,
        recipe: RuntimeV2TemplateRecipe, packages: [InstalledSoftware]
    ) -> String {
        var lines: [String] = ["floe-software-template:v1"]
        lines.append("architecture=\(architecture)")
        let parentVersion = parent.version.map { String($0) } ?? "-"
        lines.append(
            "parent=\(parent.kind.rawValue):\(parent.id)@\(parentVersion):\(parent.digest.lowercased())"
        )
        lines.append("recipe=\((try? recipe.canonicalJSON()) ?? "")")
        for package in packages.sorted(by: { $0.name < $1.name }) {
            let state = package.installState
            let source = package.source ?? ""
            lines.append("package=\(package.name)|\(package.version)|\(source)|\(state)")
        }
        return FloeDigest.sha512Hex(Data(lines.joined(separator: "\n").utf8))
    }

    struct BuildEnvelope: Codable, Sendable, Equatable {
        var schema: Int
        var recipe: RuntimeV2TemplateRecipe
        var provenance: String?
        var notes: [String]
        var cleanRebuildOf: Int?
    }

    private nonisolated static func envelopeJSON(
        recipe: RuntimeV2TemplateRecipe, provenance: String?, notes: [String], cleanRebuildOf: Int?
    ) throws -> String {
        let envelope = BuildEnvelope(
            schema: 1, recipe: recipe, provenance: provenance,
            notes: notes, cleanRebuildOf: cleanRebuildOf
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let text = String(data: try encoder.encode(envelope), encoding: .utf8) else {
            throw RuntimeV2Error.templateRecipeInvalid(reason: "manifest envelope is not UTF-8 encodable")
        }
        return text
    }

    nonisolated static func decodeEnvelope(_ json: String) -> BuildEnvelope? {
        try? JSONDecoder().decode(BuildEnvelope.self, from: Data(json.utf8))
    }

    nonisolated static func templateSlot(fromMigrationID migrationID: String) -> (String, Int)? {
        // "template-<templateID>-v<version>"
        guard migrationID.hasPrefix("template-"), let range = migrationID.range(of: "-v", options: .backwards) else {
            return nil
        }
        let templateID = String(migrationID.dropFirst("template-".count)[..<range.lowerBound])
        guard let version = Int(migrationID[range.upperBound...]) else { return nil }
        return (templateID, version)
    }

    /// Environment-facing note: whether an environment's install state is
    /// shared (one template version + one private delta) or private to a base
    /// image. Never a claim that downloads were reused.
    public func environmentReuseSummary(environmentID: String) async throws -> String {
        guard let environment = try await registry.environment(id: environmentID) else {
            return "environment \(environmentID) is not registered"
        }
        if let pin = try await environmentPin(environmentID: environmentID) {
            return "environment \(environmentID) boots template \(pin.describedIdentity) plus its private delta; "
                + "installs are shared with every session of this environment only"
        }
        return "environment \(environmentID) boots base image \(environment.baseImageID ?? "(none)") with a private delta"
    }
}

extension RuntimeV2Registry.SoftwareTemplateRow {
    /// Reference-independent version label used in reports.
    public var slotDescription: String { "\(templateID)@\(version)" }
}
