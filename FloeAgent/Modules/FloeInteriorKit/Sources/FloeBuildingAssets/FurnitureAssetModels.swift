// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeInteriorCore

/// A stored furniture resource format. The first admission path is OBJ with
/// its MTL and texture closure; other formats stay explicit rather than being
/// inferred from a file extension or silently treated as OBJ.
public enum FurnitureAssetFormat: String, Codable, Equatable, Sendable, CaseIterable {
    case obj
}

public enum FurnitureAssetFileRole: String, Codable, Equatable, Sendable, CaseIterable {
    case mainModel = "main_model"
    case materialLibrary = "material_library"
    case texture
    case license
    case thumbnail
    case other
}

/// An explicitly declared length unit. No source is assumed to be centimetres
/// merely because a catalog happens to publish centimetre-like values.
public enum FurnitureLengthUnit: String, Codable, Equatable, Sendable, CaseIterable {
    case millimetre = "mm"
    case centimetre = "cm"
    case metre = "m"
    case inch = "in"

    public var millimetresPerUnit: Double {
        switch self {
        case .millimetre: return 1
        case .centimetre: return 10
        case .metre: return 1_000
        case .inch: return 25.4
        }
    }
}

/// Author/catalog dimensions with the unit in which they were declared. The
/// millimetre value is derived only through `unit`, never through a guessed
/// source-file convention.
public struct FurnitureDeclaredDimensions: Codable, Equatable, Sendable {
    public var width: Double
    public var depth: Double
    public var height: Double
    public var unit: FurnitureLengthUnit

    public init(width: Double, depth: Double, height: Double, unit: FurnitureLengthUnit) {
        self.width = width
        self.depth = depth
        self.height = height
        self.unit = unit
    }

    public var millimetres: FurnitureDimensions {
        let scale = unit.millimetresPerUnit
        return FurnitureDimensions(widthMM: width * scale, depthMM: depth * scale, heightMM: height * scale)
    }
}

public enum FurniturePermission: String, Codable, Equatable, Sendable, CaseIterable {
    case allowed
    case notAllowed = "not_allowed"
    case unknown
}

public enum FurnitureAssetLicenseEvidence: String, Codable, Equatable, Sendable, CaseIterable {
    case licenseFile = "license_file"
    case recordedStatement = "recorded_statement"
    case userProvided = "user_provided"
}

/// License identity plus the separate hosting and project-sharing decisions.
/// A public download, a catalog label or an unverified URL never upgrades an
/// `unknown` permission by itself.
public struct FurnitureAssetLicense: Codable, Equatable, Sendable {
    public var identifier: String
    public var evidence: FurnitureAssetLicenseEvidence
    public var mayHost: FurniturePermission
    public var mayShareInProject: FurniturePermission
    public var basis: String

    public init(
        identifier: String,
        evidence: FurnitureAssetLicenseEvidence,
        mayHost: FurniturePermission,
        mayShareInProject: FurniturePermission,
        basis: String
    ) {
        self.identifier = identifier
        self.evidence = evidence
        self.mayHost = mayHost
        self.mayShareInProject = mayShareInProject
        self.basis = basis
    }
}

public struct FurnitureAssetAttribution: Codable, Equatable, Sendable {
    public var author: String?
    public var title: String?
    public var sourceURL: String?
    public var notice: String?

    public init(author: String? = nil, title: String? = nil, sourceURL: String? = nil, notice: String? = nil) {
        self.author = author
        self.title = title
        self.sourceURL = sourceURL
        self.notice = notice
    }
}

public struct FurnitureAssetProvenance: Codable, Equatable, Sendable {
    public var source: String
    public var sourceReference: String?
    public var license: FurnitureAssetLicense
    public var attribution: FurnitureAssetAttribution?

    public init(
        source: String,
        sourceReference: String? = nil,
        license: FurnitureAssetLicense,
        attribution: FurnitureAssetAttribution? = nil
    ) {
        self.source = source
        self.sourceReference = sourceReference
        self.license = license
        self.attribution = attribution
    }

    /// A user-supplied import without a recorded redistribution decision. It is
    /// deliberately not promoted to a public-library asset.
    public static func userProvided(source: String, licenseIdentifier: String = "user-provided") -> Self {
        .init(
            source: source,
            sourceReference: nil,
            license: .init(
                identifier: licenseIdentifier,
                evidence: .userProvided,
                mayHost: .unknown,
                mayShareInProject: .unknown,
                basis: "User supplied this file; no hosting or redistribution evidence is recorded."
            ),
            attribution: nil
        )
    }
}

public struct FurnitureAssetFile: Codable, Equatable, Sendable {
    /// Path relative to the immutable version root, for example
    /// `files/models/chair.obj` or `metadata/license/LICENSE.txt`.
    public var relativePath: String
    /// Path relative to the selected source root. OBJ/MTL/texture layout is
    /// preserved so a native mesh importer can resolve references from the
    /// stored main file without rewriting the author's package.
    public var sourceRelativePath: String
    public var role: FurnitureAssetFileRole
    public var byteCount: Int
    public var sha256: String

    public init(
        relativePath: String,
        sourceRelativePath: String,
        role: FurnitureAssetFileRole,
        byteCount: Int,
        sha256: String
    ) {
        self.relativePath = relativePath
        self.sourceRelativePath = sourceRelativePath
        self.role = role
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public enum FurnitureAssetIssueKind: String, Codable, Equatable, Sendable, CaseIterable {
    case missingDependency = "missing_dependency"
    case unsafeReference = "unsafe_reference"
    case unreadableDependency = "unreadable_dependency"
    case dependencyTooLarge = "dependency_too_large"
    case invalidMaterialLibrary = "invalid_material_library"
    case unsupportedMapOption = "unsupported_map_option"
    case invalidTextureReference = "invalid_texture_reference"
    case caseCollision = "case_collision"
}

/// A recoverable admission defect. The version may be read for inspection, but
/// it is never reported as admitted, pinnable or placeable while an issue is
/// present.
public struct FurnitureAssetIssue: Codable, Equatable, Sendable {
    public var kind: FurnitureAssetIssueKind
    public var sourceRelativePath: String?
    public var role: FurnitureAssetFileRole?
    public var detail: String

    public init(
        kind: FurnitureAssetIssueKind,
        sourceRelativePath: String? = nil,
        role: FurnitureAssetFileRole? = nil,
        detail: String
    ) {
        self.kind = kind
        self.sourceRelativePath = sourceRelativePath
        self.role = role
        self.detail = detail
    }
}

public enum FurnitureAssetAdmission: String, Codable, Equatable, Sendable, CaseIterable {
    case ready
    case needsRepair = "needs_repair"
}

public struct FurnitureAssetManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var assetID: String
    public var version: String
    public var name: String
    public var category: String?
    public var format: FurnitureAssetFormat
    public var provenance: FurnitureAssetProvenance
    /// Raw geometry bounds in the OBJ's own coordinate values. They are never
    /// reinterpreted as millimetres here.
    public var sourceBounds: FurnitureSourceBounds
    /// The explicit unit of the raw bounds when one is known; nil means the
    /// source values have no declared unit.
    public var sourceBoundsUnit: FurnitureLengthUnit?
    public var sourceOrientation: FurnitureSourceOrientation
    public var declaredDimensions: FurnitureDeclaredDimensions?
    public var mainFile: FurnitureAssetFile
    public var dependencies: [FurnitureAssetFile]
    public var thumbnail: FurnitureAssetFile?
    public var licenseFile: FurnitureAssetFile?
    public var issues: [FurnitureAssetIssue]

    public init(
        schemaVersion: Int = 1,
        assetID: String,
        version: String,
        name: String,
        category: String?,
        format: FurnitureAssetFormat,
        provenance: FurnitureAssetProvenance,
        sourceBounds: FurnitureSourceBounds,
        sourceBoundsUnit: FurnitureLengthUnit?,
        sourceOrientation: FurnitureSourceOrientation,
        declaredDimensions: FurnitureDeclaredDimensions?,
        mainFile: FurnitureAssetFile,
        dependencies: [FurnitureAssetFile],
        thumbnail: FurnitureAssetFile?,
        licenseFile: FurnitureAssetFile?,
        issues: [FurnitureAssetIssue]
    ) {
        self.schemaVersion = schemaVersion
        self.assetID = assetID
        self.version = version
        self.name = name
        self.category = category
        self.format = format
        self.provenance = provenance
        self.sourceBounds = sourceBounds
        self.sourceBoundsUnit = sourceBoundsUnit
        self.sourceOrientation = sourceOrientation
        self.declaredDimensions = declaredDimensions
        self.mainFile = mainFile
        self.dependencies = dependencies
        self.thumbnail = thumbnail
        self.licenseFile = licenseFile
        self.issues = issues
    }

    public var admission: FurnitureAssetAdmission {
        issues.isEmpty ? .ready : .needsRepair
    }

    /// The dependency map consumed by `FurniturePlacementInput`. Keys are the
    /// source-relative paths, matching the identity used before import.
    public var dependencySHA256: [String: String] {
        var result: [String: String] = [:]
        for dependency in dependencies where dependency.role != .license && dependency.role != .thumbnail {
            result[dependency.sourceRelativePath] = dependency.sha256
        }
        return result
    }
}

public struct FurnitureAssetSummary: Codable, Equatable, Sendable {
    public var assetID: String
    public var version: String
    public var name: String
    public var category: String?
    public var admission: FurnitureAssetAdmission
    public var issueCount: Int
    public var mainFileSHA256: String
    public var dependencyCount: Int
    public var declaredDimensions: FurnitureDeclaredDimensions?
    public var sourceBounds: FurnitureSourceBounds
    public var licenseIdentifier: String
    public var mayHost: FurniturePermission
    public var mayShareInProject: FurniturePermission

    public init(
        assetID: String,
        version: String,
        name: String,
        category: String?,
        admission: FurnitureAssetAdmission,
        issueCount: Int,
        mainFileSHA256: String,
        dependencyCount: Int,
        declaredDimensions: FurnitureDeclaredDimensions?,
        sourceBounds: FurnitureSourceBounds,
        licenseIdentifier: String,
        mayHost: FurniturePermission,
        mayShareInProject: FurniturePermission
    ) {
        self.assetID = assetID
        self.version = version
        self.name = name
        self.category = category
        self.admission = admission
        self.issueCount = issueCount
        self.mainFileSHA256 = mainFileSHA256
        self.dependencyCount = dependencyCount
        self.declaredDimensions = declaredDimensions
        self.sourceBounds = sourceBounds
        self.licenseIdentifier = licenseIdentifier
        self.mayHost = mayHost
        self.mayShareInProject = mayShareInProject
    }

    public init(manifest: FurnitureAssetManifest) {
        self.init(
            assetID: manifest.assetID,
            version: manifest.version,
            name: manifest.name,
            category: manifest.category,
            admission: manifest.admission,
            issueCount: manifest.issues.count,
            mainFileSHA256: manifest.mainFile.sha256,
            dependencyCount: manifest.dependencies.count,
            declaredDimensions: manifest.declaredDimensions,
            sourceBounds: manifest.sourceBounds,
            licenseIdentifier: manifest.provenance.license.identifier,
            mayHost: manifest.provenance.license.mayHost,
            mayShareInProject: manifest.provenance.license.mayShareInProject
        )
    }
}

/// A project pin. It binds the exact manifest and every admitted source file;
/// adding later versions never changes an existing pin.
public struct FurnitureAssetPin: Codable, Equatable, Sendable {
    public var assetID: String
    public var version: String
    public var manifestSHA256: String
    public var sourceSHA256: String
    public var dependencySHA256: [String: String]

    public init(
        assetID: String,
        version: String,
        manifestSHA256: String,
        sourceSHA256: String,
        dependencySHA256: [String: String]
    ) {
        self.assetID = assetID
        self.version = version
        self.manifestSHA256 = manifestSHA256
        self.sourceSHA256 = sourceSHA256
        self.dependencySHA256 = dependencySHA256
    }
}

public struct FurnitureAssetVersion: Codable, Equatable, Sendable {
    public var manifest: FurnitureAssetManifest
    public var manifestSHA256: String

    public init(manifest: FurnitureAssetManifest, manifestSHA256: String) {
        self.manifest = manifest
        self.manifestSHA256 = manifestSHA256
    }

    public var admission: FurnitureAssetAdmission { manifest.admission }

    public func pin() throws -> FurnitureAssetPin {
        guard manifest.admission == .ready else {
            throw FurnitureAssetLibraryError.notAdmitted(
                assetID: manifest.assetID,
                version: manifest.version,
                issueCount: manifest.issues.count
            )
        }
        return .init(
            assetID: manifest.assetID,
            version: manifest.version,
            manifestSHA256: manifestSHA256,
            sourceSHA256: manifest.mainFile.sha256,
            dependencySHA256: manifest.dependencySHA256
        )
    }
}

public struct FurnitureAssetVerification: Codable, Equatable, Sendable {
    public var assetID: String
    public var version: String
    public var manifestSHA256: String
    public var verifiedFileCount: Int
    public var verifiedDependencyCount: Int
    public var totalBytes: Int
    public var admission: FurnitureAssetAdmission

    public init(
        assetID: String,
        version: String,
        manifestSHA256: String,
        verifiedFileCount: Int,
        verifiedDependencyCount: Int,
        totalBytes: Int,
        admission: FurnitureAssetAdmission
    ) {
        self.assetID = assetID
        self.version = version
        self.manifestSHA256 = manifestSHA256
        self.verifiedFileCount = verifiedFileCount
        self.verifiedDependencyCount = verifiedDependencyCount
        self.totalBytes = totalBytes
        self.admission = admission
    }
}

public enum FurnitureAssetDependencyChange: String, Codable, Equatable, Sendable {
    case added
    case removed
    case contentChanged = "content_changed"
    case roleChanged = "role_changed"
}

public struct FurnitureAssetDependencyDifference: Codable, Equatable, Sendable {
    public var sourceRelativePath: String
    public var change: FurnitureAssetDependencyChange
    public var fromSHA256: String?
    public var toSHA256: String?
    public var fromRole: FurnitureAssetFileRole?
    public var toRole: FurnitureAssetFileRole?

    public init(
        sourceRelativePath: String,
        change: FurnitureAssetDependencyChange,
        fromSHA256: String? = nil,
        toSHA256: String? = nil,
        fromRole: FurnitureAssetFileRole? = nil,
        toRole: FurnitureAssetFileRole? = nil
    ) {
        self.sourceRelativePath = sourceRelativePath
        self.change = change
        self.fromSHA256 = fromSHA256
        self.toSHA256 = toSHA256
        self.fromRole = fromRole
        self.toRole = toRole
    }
}

public struct FurnitureAssetVersionDifference: Codable, Equatable, Sendable {
    public var assetID: String
    public var fromVersion: String
    public var toVersion: String
    public var fromManifestSHA256: String
    public var toManifestSHA256: String
    public var mainFileChanged: Bool
    public var fromMainFileSHA256: String
    public var toMainFileSHA256: String
    public var dependencyDifferences: [FurnitureAssetDependencyDifference]
    public var nameChanged: Bool
    public var categoryChanged: Bool
    public var declaredDimensionsChanged: Bool
    public var sourceBoundsChanged: Bool
    public var sourceOrientationChanged: Bool
    public var provenanceChanged: Bool
    public var thumbnailChanged: Bool
    public var licenseChanged: Bool
    public var admissionChanged: Bool

    public init(
        assetID: String,
        fromVersion: String,
        toVersion: String,
        fromManifestSHA256: String,
        toManifestSHA256: String,
        mainFileChanged: Bool,
        fromMainFileSHA256: String,
        toMainFileSHA256: String,
        dependencyDifferences: [FurnitureAssetDependencyDifference],
        nameChanged: Bool,
        categoryChanged: Bool,
        declaredDimensionsChanged: Bool,
        sourceBoundsChanged: Bool,
        sourceOrientationChanged: Bool,
        provenanceChanged: Bool,
        thumbnailChanged: Bool,
        licenseChanged: Bool,
        admissionChanged: Bool
    ) {
        self.assetID = assetID
        self.fromVersion = fromVersion
        self.toVersion = toVersion
        self.fromManifestSHA256 = fromManifestSHA256
        self.toManifestSHA256 = toManifestSHA256
        self.mainFileChanged = mainFileChanged
        self.fromMainFileSHA256 = fromMainFileSHA256
        self.toMainFileSHA256 = toMainFileSHA256
        self.dependencyDifferences = dependencyDifferences
        self.nameChanged = nameChanged
        self.categoryChanged = categoryChanged
        self.declaredDimensionsChanged = declaredDimensionsChanged
        self.sourceBoundsChanged = sourceBoundsChanged
        self.sourceOrientationChanged = sourceOrientationChanged
        self.provenanceChanged = provenanceChanged
        self.thumbnailChanged = thumbnailChanged
        self.licenseChanged = licenseChanged
        self.admissionChanged = admissionChanged
    }

    public var manifestChanged: Bool {
        fromManifestSHA256 != toManifestSHA256
    }

    public var hasChanges: Bool {
        manifestChanged || mainFileChanged || !dependencyDifferences.isEmpty || nameChanged || categoryChanged
            || declaredDimensionsChanged || sourceBoundsChanged || sourceOrientationChanged
            || provenanceChanged || thumbnailChanged || licenseChanged || admissionChanged
    }
}

public enum FurnitureAssetImportPhase: String, Codable, Equatable, Sendable, CaseIterable {
    case validatingSource = "validating_source"
    case parsingSource = "parsing_source"
    case resolvingDependencies = "resolving_dependencies"
    case stagingFiles = "staging_files"
    case verifyingStaging = "verifying_staging"
    case committing
}

public typealias FurnitureAssetPhaseObserver = @Sendable (FurnitureAssetImportPhase) throws -> Void

public struct FurnitureAssetLibraryLimits: Equatable, Sendable {
    public var maximumFiles: Int
    public var maximumTotalBytes: Int
    public var maximumMainFileBytes: Int
    public var maximumDependencyBytes: Int
    public var maximumMetadataBytes: Int
    public var maximumVertices: Int
    public var maximumPathBytes: Int
    public var maximumLineBytes: Int
    public var maximumManifestBytes: Int
    public var lockTimeoutSeconds: Double
    public var lockRetryMilliseconds: Int

    public init(
        maximumFiles: Int = 256,
        maximumTotalBytes: Int = 256 * 1_024 * 1_024,
        maximumMainFileBytes: Int = 64 * 1_024 * 1_024,
        maximumDependencyBytes: Int = 64 * 1_024 * 1_024,
        maximumMetadataBytes: Int = 16 * 1_024 * 1_024,
        maximumVertices: Int = 2_000_000,
        maximumPathBytes: Int = 1_024,
        maximumLineBytes: Int = 64 * 1_024,
        maximumManifestBytes: Int = 1 * 1_024 * 1_024,
        lockTimeoutSeconds: Double = 10,
        lockRetryMilliseconds: Int = 25
    ) {
        self.maximumFiles = maximumFiles
        self.maximumTotalBytes = maximumTotalBytes
        self.maximumMainFileBytes = maximumMainFileBytes
        self.maximumDependencyBytes = maximumDependencyBytes
        self.maximumMetadataBytes = maximumMetadataBytes
        self.maximumVertices = maximumVertices
        self.maximumPathBytes = maximumPathBytes
        self.maximumLineBytes = maximumLineBytes
        self.maximumManifestBytes = maximumManifestBytes
        self.lockTimeoutSeconds = lockTimeoutSeconds
        self.lockRetryMilliseconds = lockRetryMilliseconds
    }

    public static let standard = FurnitureAssetLibraryLimits()

    public func validate() throws {
        let positive = [
            maximumFiles, maximumTotalBytes, maximumMainFileBytes, maximumDependencyBytes,
            maximumMetadataBytes, maximumVertices, maximumPathBytes, maximumLineBytes,
            maximumManifestBytes, lockRetryMilliseconds
        ]
        guard positive.allSatisfy({ $0 > 0 }) else {
            throw FurnitureAssetLibraryError.invalidValue(field: "library limits", reason: "all limits must be positive")
        }
        guard maximumMainFileBytes <= maximumTotalBytes,
              maximumDependencyBytes <= maximumTotalBytes,
              maximumMetadataBytes <= maximumTotalBytes else {
            throw FurnitureAssetLibraryError.invalidValue(field: "library limits", reason: "a per-file limit exceeds the total byte limit")
        }
        guard lockTimeoutSeconds.isFinite, lockTimeoutSeconds > 0, lockTimeoutSeconds <= 300 else {
            throw FurnitureAssetLibraryError.invalidValue(field: "lock timeout", reason: "must be greater than zero and at most 300 seconds")
        }
    }
}
