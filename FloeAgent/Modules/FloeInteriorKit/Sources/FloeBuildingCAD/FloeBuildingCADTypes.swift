// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import FloeInteriorCore

// MARK: - Errors

/// Stable, typed refusals for the native building/CAD bridge. They describe
/// what blocked the operation; no case silently falls back to a new draft.
public enum FloeBuildingCADError: Error, LocalizedError, Equatable, Sendable {
    case existingOutput(String)
    case documentClosed
    case readOnly
    case invalidInput(String)
    case invalidBinding(String)
    case staleBinding(String)
    case externalModification(String)
    case identityNotPreserved(String)
    case missingNativeIdentity
    case unsupportedFeature(String)
    case invalidNativeState(String)
    case projectionIncomplete(String)
    case exportFailed(String)
    case sourceNotSaved
    case cancelled
    case rollbackFailed(String)
    case duplicateBinding(String)
    case missingAssetDependency(String)
    case assetHashMismatch(String)
    case unsupportedFurnitureFit(String)
    case busy

    public var errorDescription: String? {
        switch self {
        case let .existingOutput(path):
            return "An output already exists at \(path); nothing was overwritten."
        case .documentClosed:
            return "The CAD document is closed."
        case .readOnly:
            return "The CAD document is read-only."
        case let .invalidInput(message):
            return message
        case let .invalidBinding(message):
            return "The cabinet binding is not internally consistent: \(message)"
        case let .staleBinding(message):
            return "The cabinet binding is stale: \(message)"
        case let .externalModification(message):
            return "The native cabinet was changed outside this bridge; the update was refused: \(message)"
        case let .identityNotPreserved(message):
            return "The requested update would not preserve native identity: \(message)"
        case .missingNativeIdentity:
            return "The native document has no verified modelSHA256 identity yet; save it first."
        case let .unsupportedFeature(message):
            return message
        case let .invalidNativeState(message):
            return "The native document is not in the expected state: \(message)"
        case let .projectionIncomplete(message):
            return "The drawing projection is incomplete; no complete sheet was published: \(message)"
        case let .exportFailed(message):
            return "The independent export failed: \(message)"
        case .sourceNotSaved:
            return "The native document has unsaved changes; save it before an independent copy/export."
        case .cancelled:
            return "The operation was cancelled; nothing partial was published."
        case let .rollbackFailed(message):
            return "The operation failed and its own writes could not be fully rolled back: \(message)"
        case let .duplicateBinding(message):
            return "A binding with the same native/library identity already exists: \(message)"
        case let .missingAssetDependency(name):
            return "The pinned furniture dependency is missing: \(name)"
        case let .assetHashMismatch(name):
            return "The furniture source bytes do not match the pinned SHA-256: \(name)"
        case let .unsupportedFurnitureFit(message):
            return "The furniture catalog fit cannot be represented by the native uniform-scale placement: \(message)"
        case .busy:
            return "Another bridge operation is already mutating this CAD document."
        }
    }
}

// MARK: - Native identity and binding records

public nonisolated struct FloeBuildingCADNativeIdentity: Codable, Equatable, Sendable {
    public var revision: Int
    public var contentSHA256: String
    public var modelSHA256: String

    public init(revision: Int, contentSHA256: String, modelSHA256: String) {
        self.revision = revision
        self.contentSHA256 = contentSHA256
        self.modelSHA256 = modelSHA256
    }
}

/// One cabinet panel's stable native identity. `moverFeatureIDs` is additive:
/// a height change that moves a panel in +Y appends one owned transform step
/// instead of rebuilding the body under a new id.
public nonisolated struct FloeBuildingCADPanelBinding: Codable, Equatable, Sendable {
    public var panelID: String
    public var role: String
    public var bodyID: UUID
    public var sketchID: UUID
    public var entityID: UUID
    public var extrudeFeatureID: UUID
    public var moverFeatureIDs: [UUID]
    public var instanceID: UUID
    public var sketchRectMin: [Double]
    public var sketchRectMax: [Double]
    public var extrusionMM: Double
    public var originMM: [Double]
    public var sizeMM: [Double]
    public var worldBoundsMin: [Double]
    public var worldBoundsMax: [Double]
    public var volumeMM3: Double
    public var materialID: String
    public var materialVersion: String
    public var materialThicknessMM: Double

    public init(panelID: String, role: String, bodyID: UUID, sketchID: UUID,
                entityID: UUID, extrudeFeatureID: UUID, moverFeatureIDs: [UUID],
                instanceID: UUID, sketchRectMin: [Double], sketchRectMax: [Double],
                extrusionMM: Double, originMM: [Double], sizeMM: [Double],
                worldBoundsMin: [Double], worldBoundsMax: [Double], volumeMM3: Double,
                materialID: String, materialVersion: String, materialThicknessMM: Double) {
        self.panelID = panelID
        self.role = role
        self.bodyID = bodyID
        self.sketchID = sketchID
        self.entityID = entityID
        self.extrudeFeatureID = extrudeFeatureID
        self.moverFeatureIDs = moverFeatureIDs
        self.instanceID = instanceID
        self.sketchRectMin = sketchRectMin
        self.sketchRectMax = sketchRectMax
        self.extrusionMM = extrusionMM
        self.originMM = originMM
        self.sizeMM = sizeMM
        self.worldBoundsMin = worldBoundsMin
        self.worldBoundsMax = worldBoundsMax
        self.volumeMM3 = volumeMM3
        self.materialID = materialID
        self.materialVersion = materialVersion
        self.materialThicknessMM = materialThicknessMM
    }
}

public nonisolated struct FloeBuildingCADCabinetBinding: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var cabinetID: UUID
    public var name: String
    public var recipe: CabinetRecipe
    public var geometryFingerprint: String
    public var scheduleFingerprint: String
    public var panelBindings: [FloeBuildingCADPanelBinding]
    public var createdAtIdentity: FloeBuildingCADNativeIdentity
    public var updatedAtIdentity: FloeBuildingCADNativeIdentity

    public init(schemaVersion: Int = 1, cabinetID: UUID, name: String,
                recipe: CabinetRecipe, geometryFingerprint: String,
                scheduleFingerprint: String,
                panelBindings: [FloeBuildingCADPanelBinding],
                createdAtIdentity: FloeBuildingCADNativeIdentity,
                updatedAtIdentity: FloeBuildingCADNativeIdentity) {
        self.schemaVersion = schemaVersion
        self.cabinetID = cabinetID
        self.name = name
        self.recipe = recipe
        self.geometryFingerprint = geometryFingerprint
        self.scheduleFingerprint = scheduleFingerprint
        self.panelBindings = panelBindings
        self.createdAtIdentity = createdAtIdentity
        self.updatedAtIdentity = updatedAtIdentity
    }

    public func panelBinding(_ panelID: String) -> FloeBuildingCADPanelBinding? {
        panelBindings.first { $0.panelID == panelID }
    }
}

public nonisolated struct FloeBuildingCADDimensionBinding: Codable, Equatable, Sendable {
    public var role: String
    public var dimensionID: UUID
    public var viewID: UUID
    public var textPosition: [Double]
    public var textOverride: String?

    public init(role: String, dimensionID: UUID, viewID: UUID,
                textPosition: [Double], textOverride: String? = nil) {
        self.role = role
        self.dimensionID = dimensionID
        self.viewID = viewID
        self.textPosition = textPosition
        self.textOverride = textOverride
    }
}

public nonisolated struct FloeBuildingCADAnnotationBinding: Codable, Equatable, Sendable {
    /// Logical id retained across a snapshot rebuild.
    public var stableID: UUID
    /// Native annotation id in the current page snapshot (nil when orphaned).
    public var currentID: UUID?
    public var viewRole: String?
    public var text: String
    public var localPosition: [Double]
    public var orphaned: Bool

    public init(stableID: UUID, currentID: UUID?, viewRole: String?,
                text: String, localPosition: [Double], orphaned: Bool) {
        self.stableID = stableID
        self.currentID = currentID
        self.viewRole = viewRole
        self.text = text
        self.localPosition = localPosition
        self.orphaned = orphaned
    }
}

public nonisolated struct FloeBuildingCADSheetBinding: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var cabinetID: UUID
    public var pageID: UUID
    /// Keyed by `CabinetTechnicalView.rawValue` for the five implemented views.
    public var viewIDs: [String: UUID]
    public var dimensionBindings: [FloeBuildingCADDimensionBinding]
    public var paper: String
    public var title: String
    /// `project` when the page lives in the project `.floecad`; otherwise
    /// `verified-snapshot` for an independent, instance-scoped native copy.
    public var documentScope: String
    /// Relative to the project document's parent directory. Nil for a
    /// project-scoped page.
    public var snapshotRelativePath: String?
    /// Project identity captured before the snapshot copy was made.
    public var sourceIdentity: FloeBuildingCADNativeIdentity?
    /// Verified identity of the snapshot document holding this page.
    public var snapshotIdentity: FloeBuildingCADNativeIdentity?
    /// Assembly instances deliberately excluded from the snapshot because
    /// they are not part of this cabinet.
    public var excludedAssemblyInstanceIDs: [UUID]
    /// Cabinet identity the page was last generated from. A mismatch means
    /// the sheet must be refreshed before it is presented/exported.
    public var sourceCabinetUpdatedAtIdentity: FloeBuildingCADNativeIdentity?
    /// Core manual sheet notes persist with the binding and are reconciled
    /// onto the page without moving existing user text.
    public var manualNotes: [CabinetManualSheetNote]
    /// Logical note ids and their current native annotation ids. A snapshot
    /// rebuild that cannot remap a note records it as orphaned and keeps the
    /// previous snapshot file.
    public var annotationBindings: [FloeBuildingCADAnnotationBinding]
    /// The cabinet binding captured in this snapshot. It lets a later refresh
    /// update the SAME snapshot document in place, preserving page/view/note
    /// ids, before any fallback rebuild is considered.
    public var snapshotCabinetBinding: FloeBuildingCADCabinetBinding?
    /// Additive detail pages (internal elevation, assembly and exploded).
    /// Nil on a sheet persisted before detail pages existed; every field below
    /// therefore decodes with a compatible default.
    public var detailSheets: [FloeBuildingCADDetailSheet]?
    public var createdAtIdentity: FloeBuildingCADNativeIdentity
    public var updatedAtIdentity: FloeBuildingCADNativeIdentity

    public init(schemaVersion: Int = 1, cabinetID: UUID, pageID: UUID,
                viewIDs: [String: UUID],
                dimensionBindings: [FloeBuildingCADDimensionBinding],
                paper: String, title: String,
                documentScope: String = "project",
                snapshotRelativePath: String? = nil,
                sourceIdentity: FloeBuildingCADNativeIdentity? = nil,
                snapshotIdentity: FloeBuildingCADNativeIdentity? = nil,
                excludedAssemblyInstanceIDs: [UUID] = [],
                sourceCabinetUpdatedAtIdentity: FloeBuildingCADNativeIdentity? = nil,
                manualNotes: [CabinetManualSheetNote] = [],
                annotationBindings: [FloeBuildingCADAnnotationBinding] = [],
                snapshotCabinetBinding: FloeBuildingCADCabinetBinding? = nil,
                detailSheets: [FloeBuildingCADDetailSheet]? = nil,
                createdAtIdentity: FloeBuildingCADNativeIdentity,
                updatedAtIdentity: FloeBuildingCADNativeIdentity) {
        self.schemaVersion = schemaVersion
        self.cabinetID = cabinetID
        self.pageID = pageID
        self.viewIDs = viewIDs
        self.dimensionBindings = dimensionBindings
        self.paper = paper
        self.title = title
        self.documentScope = documentScope
        self.snapshotRelativePath = snapshotRelativePath
        self.sourceIdentity = sourceIdentity
        self.snapshotIdentity = snapshotIdentity
        self.excludedAssemblyInstanceIDs = excludedAssemblyInstanceIDs
        self.sourceCabinetUpdatedAtIdentity = sourceCabinetUpdatedAtIdentity
        self.manualNotes = manualNotes
        self.annotationBindings = annotationBindings
        self.snapshotCabinetBinding = snapshotCabinetBinding
        self.detailSheets = detailSheets
        self.createdAtIdentity = createdAtIdentity
        self.updatedAtIdentity = updatedAtIdentity
    }

    public func dimensionBinding(role: String) -> FloeBuildingCADDimensionBinding? {
        dimensionBindings.first { $0.role == role }
    }

    public func detailSheet(role: FloeBuildingCADDetailSheet.Role) -> FloeBuildingCADDetailSheet? {
        detailSheets?.first { $0.role == role.rawValue }
    }

    public func detailSheet(role: String) -> FloeBuildingCADDetailSheet? {
        detailSheets?.first { $0.role == role }
    }
}

/// One independently persisted detail page for a cabinet: the internal
/// elevation set (front/side/top with the front panels deliberately absent),
/// the assembly page, or the named-exploded page.
///
/// The record is additive: a sheet persisted before these pages existed has
/// `detailSheets == nil` and still decodes. The `excludedPanelIDs` /
/// `excludedPanelInstanceIDs` lists make an intentional omission auditable so
/// an internal elevation is never mistaken for a page with missing parts.
public nonisolated struct FloeBuildingCADDetailSheet: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable, CaseIterable {
        case internalElevation = "internal-elevation"
        case assembly = "assembly"
        case exploded = "exploded"
    }

    public var schemaVersion: Int
    public var cabinetID: UUID
    /// `Role.rawValue`. A string rather than the enum keeps an unknown future
    /// role readable instead of failing the whole manifest decode.
    public var role: String
    public var pageID: UUID
    public var viewIDs: [String: UUID]
    public var paper: String
    public var title: String
    public var documentScope: String
    public var snapshotRelativePath: String?
    public var snapshotIdentity: FloeBuildingCADNativeIdentity?
    public var sourceIdentity: FloeBuildingCADNativeIdentity?
    /// For the internal snapshot: the detail snapshot it was derived from.
    public var sourceDetailSnapshotRelativePath: String?
    public var excludedPanelIDs: [String]
    public var excludedPanelInstanceIDs: [UUID]
    public var excludedAssemblyInstanceIDs: [UUID]
    public var explodedViewID: UUID?
    public var explodedViewName: String?
    public var dimensionBindings: [FloeBuildingCADDimensionBinding]
    public var annotationBindings: [FloeBuildingCADAnnotationBinding]
    public var snapshotCabinetBinding: FloeBuildingCADCabinetBinding?
    public var sourceCabinetUpdatedAtIdentity: FloeBuildingCADNativeIdentity?
    public var createdAtIdentity: FloeBuildingCADNativeIdentity
    public var updatedAtIdentity: FloeBuildingCADNativeIdentity

    public init(schemaVersion: Int = 1, cabinetID: UUID,
                role: String, pageID: UUID,
                viewIDs: [String: UUID],
                paper: String, title: String,
                documentScope: String = "verified-snapshot",
                snapshotRelativePath: String? = nil,
                snapshotIdentity: FloeBuildingCADNativeIdentity? = nil,
                sourceIdentity: FloeBuildingCADNativeIdentity? = nil,
                sourceDetailSnapshotRelativePath: String? = nil,
                excludedPanelIDs: [String] = [],
                excludedPanelInstanceIDs: [UUID] = [],
                excludedAssemblyInstanceIDs: [UUID] = [],
                explodedViewID: UUID? = nil,
                explodedViewName: String? = nil,
                dimensionBindings: [FloeBuildingCADDimensionBinding] = [],
                annotationBindings: [FloeBuildingCADAnnotationBinding] = [],
                snapshotCabinetBinding: FloeBuildingCADCabinetBinding? = nil,
                sourceCabinetUpdatedAtIdentity: FloeBuildingCADNativeIdentity? = nil,
                createdAtIdentity: FloeBuildingCADNativeIdentity,
                updatedAtIdentity: FloeBuildingCADNativeIdentity) {
        self.schemaVersion = schemaVersion
        self.cabinetID = cabinetID
        self.role = role
        self.pageID = pageID
        self.viewIDs = viewIDs
        self.paper = paper
        self.title = title
        self.documentScope = documentScope
        self.snapshotRelativePath = snapshotRelativePath
        self.snapshotIdentity = snapshotIdentity
        self.sourceIdentity = sourceIdentity
        self.sourceDetailSnapshotRelativePath = sourceDetailSnapshotRelativePath
        self.excludedPanelIDs = excludedPanelIDs
        self.excludedPanelInstanceIDs = excludedPanelInstanceIDs
        self.excludedAssemblyInstanceIDs = excludedAssemblyInstanceIDs
        self.explodedViewID = explodedViewID
        self.explodedViewName = explodedViewName
        self.dimensionBindings = dimensionBindings
        self.annotationBindings = annotationBindings
        self.snapshotCabinetBinding = snapshotCabinetBinding
        self.sourceCabinetUpdatedAtIdentity = sourceCabinetUpdatedAtIdentity
        self.createdAtIdentity = createdAtIdentity
        self.updatedAtIdentity = updatedAtIdentity
    }

    public var typedRole: Role? { Role(rawValue: role) }

    public func dimensionBinding(role: String) -> FloeBuildingCADDimensionBinding? {
        dimensionBindings.first { $0.role == role }
    }
}

public nonisolated struct FloeBuildingCADRoomBinding: Codable, Equatable, Sendable {
    public var roomID: UUID
    public var name: String
    public var storeyID: UUID
    public var wallIDs: [UUID]
    public var openingIDs: [UUID]

    public init(roomID: UUID, name: String, storeyID: UUID,
                wallIDs: [UUID], openingIDs: [UUID]) {
        self.roomID = roomID
        self.name = name
        self.storeyID = storeyID
        self.wallIDs = wallIDs
        self.openingIDs = openingIDs
    }
}

public nonisolated struct FloeBuildingCADBuildingBinding: Codable, Equatable, Sendable {
    public var buildingID: UUID
    public var name: String
    public var storeyIDs: [UUID]
    public var elementIDs: [UUID]
    public var rooms: [FloeBuildingCADRoomBinding]
    public var nativeIdentity: FloeBuildingCADNativeIdentity

    public init(buildingID: UUID, name: String, storeyIDs: [UUID],
                elementIDs: [UUID], rooms: [FloeBuildingCADRoomBinding],
                nativeIdentity: FloeBuildingCADNativeIdentity) {
        self.buildingID = buildingID
        self.name = name
        self.storeyIDs = storeyIDs
        self.elementIDs = elementIDs
        self.rooms = rooms
        self.nativeIdentity = nativeIdentity
    }
}

public nonisolated struct FloeBuildingCADBounds: Codable, Equatable, Sendable {
    public var minimum: [Double]
    public var maximum: [Double]

    public init(minimum: [Double], maximum: [Double]) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public var extent: [Double] {
        [maximum[0] - minimum[0], maximum[1] - minimum[1], maximum[2] - minimum[2]]
    }
}

public nonisolated struct FloeBuildingCADTransformBinding: Codable, Equatable, Sendable {
    public var position: [Double]
    public var rotation: [Double]
    public var scale: [Double]

    public init(position: [Double], rotation: [Double], scale: [Double]) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
    }

    public static let identity = FloeBuildingCADTransformBinding(
        position: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1])
}

/// Exact source-root resource set for one furniture asset. Keys are the
/// asset manifest's full source-relative paths (for example
/// `Models/chair.obj` is the primary URL and `Textures/a/wood.png` is a
/// dependency key); there is deliberately no basename fallback.
public nonisolated struct FloeBuildingCADFurnitureResources: Codable, Equatable, Sendable {
    public var rootURL: URL
    public var dependencyFiles: [String: URL]

    public init(rootURL: URL, dependencyFiles: [String: URL] = [:]) {
        self.rootURL = rootURL
        self.dependencyFiles = dependencyFiles
    }
}

public nonisolated struct FloeBuildingCADFurnitureBinding: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var instanceID: UUID
    public var assemblyInstanceIDs: [UUID]
    public var bodyIDs: [UUID]
    public var assetID: String
    public var assetVersion: String
    public var sourceSHA256: String
    public var dependencySHA256: [String: String]
    public var placementInput: FurniturePlacementInput
    public var placementPlan: FurniturePlacementPlan
    public var importUnitScale: Double
    public var appliedUniformScale: Double
    public var instanceTransform: FloeBuildingCADTransformBinding
    public var importedBodyBounds: [FloeBuildingCADBounds]
    public var nativeEnvelopeMinimum: [Double]
    public var nativeEnvelopeMaximum: [Double]
    public var planResidualMM: Double
    /// Catalog-fit approximation actually achieved by the native uniform
    /// placement. This is reported, never described as a strict per-axis fit.
    public var actualDimensionsMM: FurnitureDimensions
    public var sizingErrorMM: Double
    public var maximumSizingErrorMM: Double
    public var uniformApproximationUsed: Bool
    /// The native body/instance import and its actual bounds were checked in
    /// this document. Physical fit, clearance and manufacturing remain
    /// unverified.
    public var nativeImportVerified: Bool
    public var physicalVerified: Bool
    public var manufacturingVerified: Bool
    public var nativeIdentity: FloeBuildingCADNativeIdentity

    public init(schemaVersion: Int = 1, instanceID: UUID,
                assemblyInstanceIDs: [UUID], bodyIDs: [UUID],
                assetID: String, assetVersion: String, sourceSHA256: String,
                dependencySHA256: [String: String],
                placementInput: FurniturePlacementInput,
                placementPlan: FurniturePlacementPlan,
                importUnitScale: Double, appliedUniformScale: Double,
                instanceTransform: FloeBuildingCADTransformBinding,
                importedBodyBounds: [FloeBuildingCADBounds],
                nativeEnvelopeMinimum: [Double], nativeEnvelopeMaximum: [Double],
                planResidualMM: Double,
                actualDimensionsMM: FurnitureDimensions,
                sizingErrorMM: Double, maximumSizingErrorMM: Double,
                uniformApproximationUsed: Bool,
                nativeImportVerified: Bool,
                physicalVerified: Bool = false, manufacturingVerified: Bool = false,
                nativeIdentity: FloeBuildingCADNativeIdentity) {
        self.schemaVersion = schemaVersion
        self.instanceID = instanceID
        self.assemblyInstanceIDs = assemblyInstanceIDs
        self.bodyIDs = bodyIDs
        self.assetID = assetID
        self.assetVersion = assetVersion
        self.sourceSHA256 = sourceSHA256
        self.dependencySHA256 = dependencySHA256
        self.placementInput = placementInput
        self.placementPlan = placementPlan
        self.importUnitScale = importUnitScale
        self.appliedUniformScale = appliedUniformScale
        self.instanceTransform = instanceTransform
        self.importedBodyBounds = importedBodyBounds
        self.nativeEnvelopeMinimum = nativeEnvelopeMinimum
        self.nativeEnvelopeMaximum = nativeEnvelopeMaximum
        self.planResidualMM = planResidualMM
        self.actualDimensionsMM = actualDimensionsMM
        self.sizingErrorMM = sizingErrorMM
        self.maximumSizingErrorMM = maximumSizingErrorMM
        self.uniformApproximationUsed = uniformApproximationUsed
        self.nativeImportVerified = nativeImportVerified
        self.physicalVerified = physicalVerified
        self.manufacturingVerified = manufacturingVerified
        self.nativeIdentity = nativeIdentity
    }
}

// MARK: - Manifest

/// The portable binding record the project/Records layer stores and publishes
/// with its generation. It is not embedded in the `.floecad` schema; the
/// native document remains the geometry owner.
public nonisolated struct FloeBuildingCADManifest: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var documentName: String
    public var documentIdentity: FloeBuildingCADNativeIdentity?
    public var building: FloeBuildingCADBuildingBinding?
    public var cabinets: [FloeBuildingCADCabinetBinding]
    public var sheets: [FloeBuildingCADSheetBinding]
    public var furniture: [FloeBuildingCADFurnitureBinding]
    public var updatedAtISO8601: String?

    public init(schemaVersion: Int = 1, documentName: String = "",
                documentIdentity: FloeBuildingCADNativeIdentity? = nil,
                building: FloeBuildingCADBuildingBinding? = nil,
                cabinets: [FloeBuildingCADCabinetBinding] = [],
                sheets: [FloeBuildingCADSheetBinding] = [],
                furniture: [FloeBuildingCADFurnitureBinding] = [],
                updatedAtISO8601: String? = nil) {
        self.schemaVersion = schemaVersion
        self.documentName = documentName
        self.documentIdentity = documentIdentity
        self.building = building
        self.cabinets = cabinets
        self.sheets = sheets
        self.furniture = furniture
        self.updatedAtISO8601 = updatedAtISO8601
    }

    public func cabinet(id: UUID) -> FloeBuildingCADCabinetBinding? {
        cabinets.first { $0.cabinetID == id }
    }

    public func sheet(cabinetID: UUID) -> FloeBuildingCADSheetBinding? {
        sheets.first { $0.cabinetID == cabinetID }
    }

    public func furniture(instanceID: UUID) -> FloeBuildingCADFurnitureBinding? {
        furniture.first { $0.instanceID == instanceID }
    }
}

public nonisolated struct FloeBuildingCADCabinetUpdate: Codable, Equatable, Sendable {
    public var cabinet: FloeBuildingCADCabinetBinding
    public var sheet: FloeBuildingCADSheetBinding?
    /// A verified-snapshot sheet is regenerated explicitly after the cabinet
    /// save; the cabinet update itself is already committed and verified.
    public var sheetRefreshRequired: Bool
    public var notes: [String]
    public var manifest: FloeBuildingCADManifest

    public init(cabinet: FloeBuildingCADCabinetBinding,
                sheet: FloeBuildingCADSheetBinding?,
                sheetRefreshRequired: Bool = false,
                notes: [String] = [],
                manifest: FloeBuildingCADManifest) {
        self.cabinet = cabinet
        self.sheet = sheet
        self.sheetRefreshRequired = sheetRefreshRequired
        self.notes = notes
        self.manifest = manifest
    }
}

// MARK: - Sheet options and limitations

public nonisolated struct FloeBuildingCADSheetOptions: Codable, Equatable, Sendable {
    public var paper: String
    public var title: String?
    public var includeClearanceDimensions: Bool
    public var includeThicknessDimensions: Bool
    public var includeCarcassDepthDimension: Bool
    public var manualNotes: [CabinetManualSheetNote]
    /// Generate the independent detail pages (internal elevation, assembly,
    /// exploded) together with the five-view combination page. Additive with
    /// a compatible default so existing callers keep their behaviour.
    public var includeDetailSheets: Bool

    public init(paper: String = "a2", title: String? = nil,
                includeClearanceDimensions: Bool = true,
                includeThicknessDimensions: Bool = true,
                includeCarcassDepthDimension: Bool = true,
                manualNotes: [CabinetManualSheetNote] = [],
                includeDetailSheets: Bool = true) {
        self.paper = paper
        self.title = title
        self.includeClearanceDimensions = includeClearanceDimensions
        self.includeThicknessDimensions = includeThicknessDimensions
        self.includeCarcassDepthDimension = includeCarcassDepthDimension
        self.manualNotes = manualNotes
        self.includeDetailSheets = includeDetailSheets
    }

    enum CodingKeys: String, CodingKey {
        case paper, title, includeClearanceDimensions, includeThicknessDimensions
        case includeCarcassDepthDimension, manualNotes, includeDetailSheets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paper = try container.decodeIfPresent(String.self, forKey: .paper) ?? "a2"
        title = try container.decodeIfPresent(String.self, forKey: .title)
        includeClearanceDimensions = try container.decodeIfPresent(
            Bool.self, forKey: .includeClearanceDimensions) ?? true
        includeThicknessDimensions = try container.decodeIfPresent(
            Bool.self, forKey: .includeThicknessDimensions) ?? true
        includeCarcassDepthDimension = try container.decodeIfPresent(
            Bool.self, forKey: .includeCarcassDepthDimension) ?? true
        manualNotes = try container.decodeIfPresent(
            [CabinetManualSheetNote].self, forKey: .manualNotes) ?? []
        includeDetailSheets = try container.decodeIfPresent(
            Bool.self, forKey: .includeDetailSheets) ?? true
    }
}

public nonisolated struct FloeBuildingCADLimitation: Codable, Equatable, Sendable {
    public var id: String
    public var summary: String
    public var requiredHook: String

    public init(id: String, summary: String, requiredHook: String) {
        self.id = id
        self.summary = summary
        self.requiredHook = requiredHook
    }
}

// MARK: - Export receipt

public nonisolated struct FloeBuildingCADExportFile: Codable, Equatable, Sendable {
    public var role: String
    public var format: String
    public var relativePath: String
    public var byteCount: Int
    public var sha256: String
    public var verified: Bool
    public var unsupportedLosses: [String]

    public init(role: String, format: String, relativePath: String,
                byteCount: Int, sha256: String, verified: Bool,
                unsupportedLosses: [String]) {
        self.role = role
        self.format = format
        self.relativePath = relativePath
        self.byteCount = byteCount
        self.sha256 = sha256
        self.verified = verified
        self.unsupportedLosses = unsupportedLosses
    }
}

/// One page represented by a multi-page delivery. `role` is `main`,
/// `internal-elevation`, `assembly`, `exploded` or `whole-project`.
public nonisolated struct FloeBuildingCADReceiptPage: Codable, Equatable, Sendable {
    public var role: String
    public var pageID: UUID
    public var title: String
    public var documentScope: String
    public var documentIdentity: FloeBuildingCADNativeIdentity?
    /// The exact assembly instances the page projection was verified against.
    public var sourceInstanceIDs: [UUID]?
    public var excludedPanelIDs: [String]
    public var excludedPanelInstanceIDs: [UUID]
    public var explodedViewID: UUID?
    public var explodedViewName: String?
    /// True only after a real page projection and source fingerprint check.
    public var projectionVerified: Bool?

    public init(role: String, pageID: UUID, title: String,
                documentScope: String,
                documentIdentity: FloeBuildingCADNativeIdentity? = nil,
                sourceInstanceIDs: [UUID]? = nil,
                excludedPanelIDs: [String] = [],
                excludedPanelInstanceIDs: [UUID] = [],
                explodedViewID: UUID? = nil,
                explodedViewName: String? = nil,
                projectionVerified: Bool? = nil) {
        self.role = role
        self.pageID = pageID
        self.title = title
        self.documentScope = documentScope
        self.documentIdentity = documentIdentity
        self.sourceInstanceIDs = sourceInstanceIDs
        self.excludedPanelIDs = excludedPanelIDs
        self.excludedPanelInstanceIDs = excludedPanelInstanceIDs
        self.explodedViewID = explodedViewID
        self.explodedViewName = explodedViewName
        self.projectionVerified = projectionVerified
    }
}

/// A requested capability that this build deliberately refused. It is a
/// typed record, never an empty-but-successful artifact.
public nonisolated struct FloeBuildingCADUnsupportedOperation: Codable, Equatable, Sendable {
    public var code: String
    public var scope: String
    public var message: String

    public init(code: String, scope: String, message: String) {
        self.code = code
        self.scope = scope
        self.message = message
    }
}

/// Evidence for the independently authored native 2D document. Geometry is
/// real native sketch geometry; layers are sketch names; annotation text is
/// native outline geometry (not an associative text object) when included.
public nonisolated struct FloeBuildingCADNative2DReceipt: Codable, Equatable, Sendable {
    public var scope: String
    public var units: String
    public var sourcePageID: UUID
    public var sourcePageIdentity: FloeBuildingCADNativeIdentity
    public var documentIdentity: FloeBuildingCADNativeIdentity
    public var sketchIDs: [UUID]
    public var layers: [String]
    public var entityCount: Int
    public var textCount: Int
    public var losses: [String]

    public init(scope: String, units: String = "mm", sourcePageID: UUID,
                sourcePageIdentity: FloeBuildingCADNativeIdentity,
                documentIdentity: FloeBuildingCADNativeIdentity,
                sketchIDs: [UUID], layers: [String], entityCount: Int,
                textCount: Int, losses: [String]) {
        self.scope = scope
        self.units = units
        self.sourcePageID = sourcePageID
        self.sourcePageIdentity = sourcePageIdentity
        self.documentIdentity = documentIdentity
        self.sketchIDs = sketchIDs
        self.layers = layers
        self.entityCount = entityCount
        self.textCount = textCount
        self.losses = losses
    }
}

public nonisolated struct FloeBuildingCADDeliveryReceipt: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var scope: String
    public var pageID: UUID
    public var pageTitle: String
    public var units: String
    public var sourceIdentity: FloeBuildingCADNativeIdentity
    public var pageDocumentIdentity: FloeBuildingCADNativeIdentity?
    public var files: [FloeBuildingCADExportFile]
    public var unsupported: [String]
    public var createdAtISO8601: String
    public var outputDirectory: String
    public var notes: [String]
    /// Additive page manifest for a multi-page delivery. Nil on a receipt
    /// written before page roles existed.
    public var pages: [FloeBuildingCADReceiptPage]?
    /// Additive native 2D evidence. Nil when that deliverable was not made.
    public var native2D: FloeBuildingCADNative2DReceipt?
    /// Structured unsupported operations; the `unsupported` strings remain
    /// for older readers.
    public var unsupportedOperations: [FloeBuildingCADUnsupportedOperation]?

    public init(schemaVersion: Int = 1, scope: String, pageID: UUID,
                pageTitle: String, units: String,
                sourceIdentity: FloeBuildingCADNativeIdentity,
                pageDocumentIdentity: FloeBuildingCADNativeIdentity? = nil,
                files: [FloeBuildingCADExportFile], unsupported: [String],
                createdAtISO8601: String, outputDirectory: String,
                notes: [String],
                pages: [FloeBuildingCADReceiptPage]? = nil,
                native2D: FloeBuildingCADNative2DReceipt? = nil,
                unsupportedOperations: [FloeBuildingCADUnsupportedOperation]? = nil) {
        self.schemaVersion = schemaVersion
        self.scope = scope
        self.pageID = pageID
        self.pageTitle = pageTitle
        self.units = units
        self.sourceIdentity = sourceIdentity
        self.pageDocumentIdentity = pageDocumentIdentity
        self.files = files
        self.unsupported = unsupported
        self.createdAtISO8601 = createdAtISO8601
        self.outputDirectory = outputDirectory
        self.notes = notes
        self.pages = pages
        self.native2D = native2D
        self.unsupportedOperations = unsupportedOperations
    }
}

/// Options for the independent native 2D document. Text is a real native
/// outline conversion; if disabled the exact text loss is recorded instead of
/// claiming the annotation survived.
public nonisolated struct FloeBuildingCADNative2DOptions: Codable, Equatable, Sendable {
    public var includeAnnotationText: Bool
    public var maximumEntityCount: Int
    public var maximumTextCount: Int

    public init(includeAnnotationText: Bool = true,
                maximumEntityCount: Int = 20_000,
                maximumTextCount: Int = 160) {
        self.includeAnnotationText = includeAnnotationText
        self.maximumEntityCount = maximumEntityCount
        self.maximumTextCount = maximumTextCount
    }
}

/// Options for the multi-page cabinet/whole-project deliverable set.
public nonisolated struct FloeBuildingCADDetailExportOptions: Codable, Equatable, Sendable {
    public var formats: [String]
    public var includeNative2D: Bool
    public var includeNative3D: Bool
    public var native2D: FloeBuildingCADNative2DOptions
    /// Whole-project native/vector work needs an explicit project drawing
    /// page. Nil keeps the whole-project 2D path a typed unsupported result.
    public var projectPageID: UUID?

    public init(formats: [String] = ["pdf", "svg", "dxf"],
                includeNative2D: Bool = true,
                includeNative3D: Bool = true,
                native2D: FloeBuildingCADNative2DOptions = .init(),
                projectPageID: UUID? = nil) {
        self.formats = formats
        self.includeNative2D = includeNative2D
        self.includeNative3D = includeNative3D
        self.native2D = native2D
        self.projectPageID = projectPageID
    }
}

// MARK: - Basic building authoring input

public nonisolated struct FloeBuildingCADOpeningSpec: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case door, window
    }

    public var id: UUID
    public var kind: Kind
    public var name: String
    /// 0 = south, 1 = east, 2 = north, 3 = west, in the room's generated wall order.
    public var wallIndex: Int
    public var offsetMM: Double
    public var widthMM: Double
    public var heightMM: Double
    public var baseOffsetMM: Double

    public init(id: UUID, kind: Kind, name: String, wallIndex: Int,
                offsetMM: Double, widthMM: Double, heightMM: Double,
                baseOffsetMM: Double) {
        self.id = id
        self.kind = kind
        self.name = name
        self.wallIndex = wallIndex
        self.offsetMM = offsetMM
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.baseOffsetMM = baseOffsetMM
    }
}

public nonisolated struct FloeBuildingCADRoomSpec: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// Clear interior opposite corners in plan millimetres.
    public var minimum: [Double]
    public var maximum: [Double]
    public var heightMM: Double
    public var wallThicknessMM: Double
    public var openings: [FloeBuildingCADOpeningSpec]

    public init(id: UUID, name: String, minimum: [Double], maximum: [Double],
                heightMM: Double, wallThicknessMM: Double,
                openings: [FloeBuildingCADOpeningSpec] = []) {
        self.id = id
        self.name = name
        self.minimum = minimum
        self.maximum = maximum
        self.heightMM = heightMM
        self.wallThicknessMM = wallThicknessMM
        self.openings = openings
    }
}

public nonisolated struct FloeBuildingCADStoreySpec: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var elevationMM: Double
    public var heightMM: Double
    public var rooms: [FloeBuildingCADRoomSpec]

    public init(id: UUID, name: String, elevationMM: Double, heightMM: Double,
                rooms: [FloeBuildingCADRoomSpec]) {
        self.id = id
        self.name = name
        self.elevationMM = elevationMM
        self.heightMM = heightMM
        self.rooms = rooms
    }
}

public nonisolated struct FloeBuildingCADSpec: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var storeys: [FloeBuildingCADStoreySpec]

    public init(id: UUID, name: String, storeys: [FloeBuildingCADStoreySpec]) {
        self.id = id
        self.name = name
        self.storeys = storeys
    }
}
#endif
