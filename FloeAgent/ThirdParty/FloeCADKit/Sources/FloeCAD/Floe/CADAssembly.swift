//
//  CADAssembly.swift
//  FloeCADKit
//
//  Assembly model for FloeCAD: shared immutable part instances with their own
//  transforms, explicit independent copies, positioning constraints and
//  interference checks. Instances reference document bodies by stable
//  `BodyID`; a "shared" instance never mutates the source body — only its own
//  placement. The persisted contract is JSON in the document package
//  (`assembly.json`-equivalent `project.assemblyData`), separate from the
//  binary B-rep blobs.
//
//  ADDITIVE E01/E02 EXTENSION (2026-10-31)
//
//  The historical flat model is preserved byte-for-byte for documents that do
//  not use the new features: every added field decodes to its old default and
//  empty `children` / `constraints` arrays are not encoded. Two new durable
//  concepts are added:
//
//  * A nested subassembly is an ordinary `CADAssemblyInstance` with a stable
//    `subassemblyID`; its placed parts live in `children` and its local
//    positioning constraints live in `constraints`. Its `bodyID` is a
//    placeholder equal to `subassemblyID` (it intentionally never resolves a
//    document body — callers must use `isSubassembly`). This keeps the
//    existing instance/constraint/BOM identity model and lets arbitrary depth
//    be represented without flattening or renumbering anything.
//  * An external native part is a `CADPartReference` (stable ID, source
//    document/body identity, pinned writer/schema version, source content
//    hash, staged local body + staged geometry hash). Instances point at the
//    reference through `sourceReferenceID`; their `bodyID` is the staged local
//    body so existing body-oriented render/measure/drawing paths keep
//    working. The staged body is immutable from the kernel's point of view:
//    only the App-owned reference bridge replaces it, and only through the
//    one-undo command in `CADAssemblyReferenceCommands.swift`.
//
//  No filesystem authority lives here: references carry opaque identity and
//  hashes, never paths, and the kernel never opens an external document.
//

import Foundation
import simd

/// Rigid placement of an instance: translation + unit quaternion (+ uniform
/// scale, normally 1). Double precision because constraint solves and
/// interference checks run on exact geometry.
public nonisolated struct CADTransform: Codable, Sendable, Equatable {
    public var position: SIMD3<Double>
    /// Quaternion (x, y, z, w).
    public var rotation: SIMD4<Double>
    public var scale: SIMD3<Double>

    public init(position: SIMD3<Double> = .zero,
                rotation: SIMD4<Double> = SIMD4(0, 0, 0, 1),
                scale: SIMD3<Double> = SIMD3(1, 1, 1)) {
        self.position = position
        self.rotation = rotation
        self.scale = scale
    }

    public static let identity = CADTransform()

    /// Parent-local placement composed with this child placement
    /// (`parent ∘ child`). This is the same convention as
    /// `Transform3D.composed(onto:)`, expressed in the persisted assembly
    /// value type so nested occurrences can be resolved without touching the
    /// kernel. Non-finite output is left as-is for the existing
    /// `isPlaceable` validation to reject.
    public func concatenating(_ child: CADTransform) -> CADTransform {
        let parentRotation = normalizedQuaternion(rotation)
        let childRotation = normalizedQuaternion(child.rotation)
        let product = parentRotation * childRotation
        let resultRotation = normalizedQuaternion(
            SIMD4(product.imag.x, product.imag.y,
                  product.imag.z, product.real))
        let parentScale = scale.x
        return CADTransform(
            position: position + parentRotation.act(child.position * parentScale),
            rotation: SIMD4(resultRotation.imag.x, resultRotation.imag.y,
                            resultRotation.imag.z, resultRotation.real),
            scale: scale * child.scale)
    }

    private func normalizedQuaternion(_ value: SIMD4<Double>) -> simd_quatd {
        let length = simd_length(value)
        guard length.isFinite, length > 1e-12 else {
            return simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        }
        return simd_quatd(ix: value.x / length, iy: value.y / length,
                          iz: value.z / length, r: value.w / length)
    }
}

/// One placed part in the assembly.
public nonisolated struct CADAssemblyInstance: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// The document body this instance places (the shared part definition).
    /// For a subassembly container this is a placeholder equal to
    /// `subassemblyID`; for a reference instance it is the staged local body.
    public var bodyID: UUID
    public var transform: CADTransform
    public var isHidden: Bool
    /// True when this instance was created as an explicit independent COPY:
    /// it owns a duplicated body rather than referencing the shared one.
    public var isIndependentCopy: Bool
    /// Body created for an independent copy (nil for shared instances).
    public var copiedBodyID: UUID?
    /// `meshRevision` of the placed body at the last solve/refresh, used to
    /// detect a stale source part. Optional so assembly JSON written before
    /// this field existed still decodes; nil reads as "unrecorded".
    /// Revisions are session-scoped (they are re-minted on document load), so
    /// a reopened document legitimately reports every instance stale until the
    /// next `sourceUpdate` apply.
    public var sourceRevision: UInt64?
    /// External native part reference this instance places. The reference is
    /// shared by every non-independent instance pointing at it; an
    /// independent copy keeps this provenance but resolves its own
    /// `copiedBodyID`, so a source update never overwrites it.
    public var sourceReferenceID: UUID?
    /// Stable identity of this subassembly when the instance is a container.
    /// nil for a leaf part. The container's geometry is the union of its
    /// `children`; it never resolves a document body itself.
    public var subassemblyID: UUID?
    /// Local child occurrences of a nested subassembly. Empty for a leaf.
    /// Additive: old assembly JSON decodes this as empty and empty arrays are
    /// omitted on encode, so a flat document round-trips unchanged.
    public var children: [CADAssemblyInstance]
    /// Positioning constraints local to this subassembly (between its direct
    /// children). Additive and omitted when empty. Root constraints stay in
    /// `CADAssembly.constraints`; moving a constraint between scopes never
    /// changes its stable ID.
    public var constraints: [CADAssemblyConstraint]

    public init(id: UUID = UUID(),
                name: String,
                bodyID: UUID,
                transform: CADTransform = .identity,
                isHidden: Bool = false,
                isIndependentCopy: Bool = false,
                copiedBodyID: UUID? = nil,
                sourceRevision: UInt64? = nil,
                sourceReferenceID: UUID? = nil,
                subassemblyID: UUID? = nil,
                children: [CADAssemblyInstance] = [],
                constraints: [CADAssemblyConstraint] = []) {
        self.id = id
        self.name = name
        self.bodyID = bodyID
        self.transform = transform
        self.isHidden = isHidden
        self.isIndependentCopy = isIndependentCopy
        self.copiedBodyID = copiedBodyID
        self.sourceRevision = sourceRevision
        self.sourceReferenceID = sourceReferenceID
        self.subassemblyID = subassemblyID
        self.children = children
        self.constraints = constraints
    }

    public var isSubassembly: Bool { subassemblyID != nil }

    /// The body this instance actually draws. A container has no body.
    public var resolvedBodyID: UUID? {
        if isSubassembly { return nil }
        return copiedBodyID ?? bodyID
    }

    /// True when this instance uses semantics an older writer could drop on
    /// re-save: a nested container, local children/constraints, or an external
    /// reference provenance. Flat shared/independent body instances stay on
    /// the existing format floor.
    public var requiresNestedFormat: Bool {
        if subassemblyID != nil || sourceReferenceID != nil
            || !children.isEmpty || !constraints.isEmpty {
            return true
        }
        return children.contains { $0.requiresNestedFormat }
    }

    /// Stable BOM identity for this occurrence: a shared external reference
    /// groups by the reference, an independent copy groups by its own body,
    /// and an ordinary part groups by its shared body. A container groups by
    /// its stable subassembly identity (its children carry their own rows).
    public var bomIdentity: UUID {
        if let subassemblyID { return subassemblyID }
        if isIndependentCopy { return copiedBodyID ?? bodyID }
        if let sourceReferenceID { return sourceReferenceID }
        return bodyID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, bodyID, transform, isHidden, isIndependentCopy
        case copiedBodyID, sourceRevision
        case sourceReferenceID, subassemblyID, children, constraints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        bodyID = try container.decode(UUID.self, forKey: .bodyID)
        transform = try container.decodeIfPresent(CADTransform.self, forKey: .transform) ?? .identity
        isHidden = try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        isIndependentCopy = try container.decodeIfPresent(Bool.self, forKey: .isIndependentCopy) ?? false
        copiedBodyID = try container.decodeIfPresent(UUID.self, forKey: .copiedBodyID)
        sourceRevision = try container.decodeIfPresent(UInt64.self, forKey: .sourceRevision)
        sourceReferenceID = try container.decodeIfPresent(UUID.self, forKey: .sourceReferenceID)
        subassemblyID = try container.decodeIfPresent(UUID.self, forKey: .subassemblyID)
        children = try container.decodeIfPresent([CADAssemblyInstance].self, forKey: .children) ?? []
        constraints = try container.decodeIfPresent([CADAssemblyConstraint].self,
                                                    forKey: .constraints) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(bodyID, forKey: .bodyID)
        try container.encode(transform, forKey: .transform)
        try container.encode(isHidden, forKey: .isHidden)
        try container.encode(isIndependentCopy, forKey: .isIndependentCopy)
        try container.encodeIfPresent(copiedBodyID, forKey: .copiedBodyID)
        try container.encodeIfPresent(sourceRevision, forKey: .sourceRevision)
        try container.encodeIfPresent(sourceReferenceID, forKey: .sourceReferenceID)
        try container.encodeIfPresent(subassemblyID, forKey: .subassemblyID)
        if !children.isEmpty { try container.encode(children, forKey: .children) }
        if !constraints.isEmpty { try container.encode(constraints, forKey: .constraints) }
    }
}

// MARK: - External part references

/// First concrete external source kind. A native `.floecad` package is the
/// only source this round stages; STEP hierarchy fidelity is a separate item.
public nonisolated enum CADPartReferenceKind: String, Codable, Sendable {
    case nativeDocument
}

/// One durable external native part reference.
///
/// Identity/version/hash fields are facts supplied by the App-owned staging
/// bridge after it verified a user-authorized source document. `stagedBodyID`
/// is a local, immutable display/measure body inside the target document; the
/// kernel never reads the source package. `sourceDocumentID` is an opaque
/// App-issued stable identity, NOT a filesystem path. Missing sources keep the
/// staged body, so cached geometry, mates and BOM identities survive.
public nonisolated struct CADPartReference: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: CADPartReferenceKind
    /// Opaque stable identity of the source document (App-issued).
    public var sourceDocumentID: UUID
    /// Stable body identity inside the source document.
    public var sourceBodyID: UUID
    public var sourceDocumentName: String
    public var sourceBodyName: String
    /// Writer/schema versions observed when this pin was taken.
    public var sourceWriterVersion: Int
    public var sourceSchemaVersion: Int
    public var sourceRevision: Int
    /// Verified content identity (SHA-256) of the source package at pin time.
    public var sourceContentHash: String
    /// Staged local body used for display/measure/interference.
    public var stagedBodyID: UUID
    /// Render-buffer digest of the staged body at pin time. Detects a local
    /// tamper or a different staged body without confusing reopened
    /// session-scoped mesh revisions.
    public var stagedGeometryHash: String
    /// `meshRevision` observed after the last bridge apply (informational).
    public var stagedRevision: UInt64
    public var pinnedAt: Date
    /// Last available source observed by an explicit bridge check. Nil until
    /// the user checks/updates; never inferred by the kernel.
    public var availableSourceRevision: Int?
    public var availableSourceContentHash: String?
    public var availableWriterVersion: Int?
    public var availableSchemaVersion: Int?
    public var lastCheckedAt: Date?
    /// Non-nil after an explicit check found the source unavailable. The
    /// staged body is deliberately retained.
    public var missingReason: String?

    public init(id: UUID = UUID(),
                name: String,
                kind: CADPartReferenceKind = .nativeDocument,
                sourceDocumentID: UUID,
                sourceBodyID: UUID,
                sourceDocumentName: String,
                sourceBodyName: String,
                sourceWriterVersion: Int,
                sourceSchemaVersion: Int,
                sourceRevision: Int,
                sourceContentHash: String,
                stagedBodyID: UUID,
                stagedGeometryHash: String,
                stagedRevision: UInt64 = 0,
                pinnedAt: Date = Date(),
                availableSourceRevision: Int? = nil,
                availableSourceContentHash: String? = nil,
                availableWriterVersion: Int? = nil,
                availableSchemaVersion: Int? = nil,
                lastCheckedAt: Date? = nil,
                missingReason: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sourceDocumentID = sourceDocumentID
        self.sourceBodyID = sourceBodyID
        self.sourceDocumentName = sourceDocumentName
        self.sourceBodyName = sourceBodyName
        self.sourceWriterVersion = sourceWriterVersion
        self.sourceSchemaVersion = sourceSchemaVersion
        self.sourceRevision = sourceRevision
        self.sourceContentHash = sourceContentHash
        self.stagedBodyID = stagedBodyID
        self.stagedGeometryHash = stagedGeometryHash
        self.stagedRevision = stagedRevision
        self.pinnedAt = pinnedAt
        self.availableSourceRevision = availableSourceRevision
        self.availableSourceContentHash = availableSourceContentHash
        self.availableWriterVersion = availableWriterVersion
        self.availableSchemaVersion = availableSchemaVersion
        self.lastCheckedAt = lastCheckedAt
        self.missingReason = missingReason
    }

    /// True when an explicit check observed a different committed source.
    public var hasAvailableUpdate: Bool {
        guard let availableSourceContentHash else { return false }
        return availableSourceContentHash != sourceContentHash
    }

    /// Stable BOM/definition identity for shared instances of this part.
    public var bomIdentity: UUID { id }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, sourceDocumentID, sourceBodyID
        case sourceDocumentName, sourceBodyName
        case sourceWriterVersion, sourceSchemaVersion, sourceRevision
        case sourceContentHash, stagedBodyID, stagedGeometryHash, stagedRevision
        case pinnedAt, availableSourceRevision, availableSourceContentHash
        case availableWriterVersion, availableSchemaVersion, lastCheckedAt, missingReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(CADPartReferenceKind.self, forKey: .kind) ?? .nativeDocument
        sourceDocumentID = try container.decodeIfPresent(UUID.self, forKey: .sourceDocumentID) ?? UUID()
        sourceBodyID = try container.decodeIfPresent(UUID.self, forKey: .sourceBodyID) ?? UUID()
        sourceDocumentName = try container.decodeIfPresent(String.self, forKey: .sourceDocumentName) ?? ""
        sourceBodyName = try container.decodeIfPresent(String.self, forKey: .sourceBodyName) ?? ""
        sourceWriterVersion = try container.decodeIfPresent(Int.self, forKey: .sourceWriterVersion) ?? 0
        sourceSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .sourceSchemaVersion) ?? 0
        sourceRevision = try container.decodeIfPresent(Int.self, forKey: .sourceRevision) ?? 0
        sourceContentHash = try container.decodeIfPresent(String.self, forKey: .sourceContentHash) ?? ""
        stagedBodyID = try container.decodeIfPresent(UUID.self, forKey: .stagedBodyID) ?? UUID()
        stagedGeometryHash = try container.decodeIfPresent(String.self, forKey: .stagedGeometryHash) ?? ""
        stagedRevision = try container.decodeIfPresent(UInt64.self, forKey: .stagedRevision) ?? 0
        pinnedAt = try container.decodeIfPresent(Date.self, forKey: .pinnedAt) ?? Date(timeIntervalSince1970: 0)
        availableSourceRevision = try container.decodeIfPresent(Int.self, forKey: .availableSourceRevision)
        availableSourceContentHash = try container.decodeIfPresent(String.self,
                                                                   forKey: .availableSourceContentHash)
        availableWriterVersion = try container.decodeIfPresent(Int.self, forKey: .availableWriterVersion)
        availableSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .availableSchemaVersion)
        lastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .lastCheckedAt)
        missingReason = try container.decodeIfPresent(String.self, forKey: .missingReason)
    }
}

public nonisolated enum CADAssemblyConstraintKind: String, Codable, Sendable, CaseIterable {
    /// Instance A is fixed in world space.
    case fixed
    /// A's axis is collinear with B's axis.
    case coaxial
    /// A's reference plane is coplanar (align) with B's plane.
    case planarAlign
    /// Distance between A's reference point and B's reference point.
    case distance
    /// Angle between A's axis and B's axis, degrees.
    case angle
}

/// A positioning constraint. Geometry references are stored in each instance's
/// LOCAL frame (point + direction), so they survive instance moves and replay
/// against the solved placement.
public nonisolated struct CADAssemblyConstraint: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: CADAssemblyConstraintKind
    public var instanceA: UUID
    public var instanceB: UUID?
    /// Local-frame reference on A / B (axis point + direction, or plane origin
    /// + normal).
    public var pointA: SIMD3<Double>
    public var directionA: SIMD3<Double>
    public var pointB: SIMD3<Double>?
    public var directionB: SIMD3<Double>?
    /// Distance (mm) or angle (degrees) for the driven kinds.
    public var value: Double?
    public var isSuppressed: Bool
    /// Mesh revision of the placed source body when the reference was picked.
    /// Optional so constraint JSON written before this field existed decodes;
    /// nil reads as "unrecorded" (legacy hand-entered geometry). A mismatch is
    /// reported as a stale reference, never silently re-bound.
    public var sourceRevisionA: UInt64?
    public var sourceRevisionB: UInt64?

    public init(id: UUID = UUID(),
                kind: CADAssemblyConstraintKind,
                instanceA: UUID,
                instanceB: UUID? = nil,
                pointA: SIMD3<Double> = .zero,
                directionA: SIMD3<Double> = SIMD3(0, 0, 1),
                pointB: SIMD3<Double>? = nil,
                directionB: SIMD3<Double>? = nil,
                value: Double? = nil,
                isSuppressed: Bool = false,
                sourceRevisionA: UInt64? = nil,
                sourceRevisionB: UInt64? = nil) {
        self.id = id
        self.kind = kind
        self.instanceA = instanceA
        self.instanceB = instanceB
        self.pointA = pointA
        self.directionA = directionA
        self.pointB = pointB
        self.directionB = directionB
        self.value = value
        self.isSuppressed = isSuppressed
        self.sourceRevisionA = sourceRevisionA
        self.sourceRevisionB = sourceRevisionB
    }
}

// MARK: - Exploded views

/// One instance's override inside an exploded view. A nil direction/distance
/// inherits the view default; the offset itself is still explicit per
/// instance, so a named view never depends on assembly order or viewport
/// state.
public nonisolated struct CADExplodedViewEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var instanceID: UUID
    /// World-space direction; nil = the view's default direction.
    public var direction: SIMD3<Double>?
    /// Offset length in mm; nil = the view's default distance.
    public var distanceMM: Double?

    public init(id: UUID = UUID(), instanceID: UUID,
                direction: SIMD3<Double>? = nil,
                distanceMM: Double? = nil) {
        self.id = id
        self.instanceID = instanceID
        self.direction = direction
        self.distanceMM = distanceMM
    }
}

/// A persisted, named exploded view. It is DISPLAY/DRAWING state only: the
/// view never rewrites `CADAssemblyInstance.transform` or any body geometry.
/// Preview offsets are derived from this value on demand; reset simply stops
/// using them. An entry may target a root instance or a nested child; a
/// parent's offset displaces its whole subtree.
public nonisolated struct CADExplodedView: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Unit world-space direction used by entries without their own.
    public var direction: SIMD3<Double>
    /// Default offset length in mm.
    public var distanceMM: Double
    public var entries: [CADExplodedViewEntry]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(),
                name: String,
                direction: SIMD3<Double> = SIMD3(1, 1, 1),
                distanceMM: Double = 40,
                entries: [CADExplodedViewEntry] = [],
                createdAt: Date = Date(),
                updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.direction = direction
        self.distanceMM = distanceMM
        self.entries = entries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func entry(for instanceID: UUID) -> CADExplodedViewEntry? {
        entries.first { $0.instanceID == instanceID }
    }

    /// Resolved world-space offset for one instance. Only instances listed in
    /// `entries` are displaced — an unlisted instance stays at its base
    /// placement, which is what makes the per-instance include list honest.
    /// Non-finite/zero input directions resolve to no offset rather than a
    /// NaN placement.
    public func offset(for instanceID: UUID) -> SIMD3<Double> {
        guard let entry = entry(for: instanceID) else { return .zero }
        let rawDirection = entry.direction ?? direction
        let rawDistance = entry.distanceMM ?? distanceMM
        guard rawDistance.isFinite, rawDistance != 0,
              rawDirection.x.isFinite, rawDirection.y.isFinite, rawDirection.z.isFinite else {
            return .zero
        }
        let length = simd_length(rawDirection)
        guard length > 1e-12 else { return .zero }
        return (rawDirection / length) * rawDistance
    }
}

// MARK: - Resolved hierarchy

/// One resolved occurrence in the persisted instance tree. Placement is the
/// composition of every ancestor instance transform (`parent ∘ child`). The
/// exploded placement additionally applies the named view's offset at the
/// level where it is authored, so a displaced subassembly carries its children
/// and a displaced child moves only itself.
public nonisolated struct CADAssemblyOccurrence: Sendable, Equatable, Identifiable {
    public var instance: CADAssemblyInstance
    /// Root-to-self instance identity path.
    public var path: [UUID]
    /// Root-to-self display names (for UI); never used as identity.
    public var pathNames: [String]
    public var parentInstanceID: UUID?
    public var depth: Int
    /// Base placement in assembly/document space.
    public var worldTransform: CADTransform
    /// Placement with the named exploded view applied; nil when no view.
    public var explodedWorldTransform: CADTransform?
    /// False when this occurrence or any ancestor is hidden.
    public var isVisible: Bool
    public var effectiveBodyID: UUID?
    public var sourceReferenceID: UUID?
    public var subassemblyID: UUID?
    /// True for a leaf part that resolves drawable geometry.
    public var isDrawablePart: Bool { subassemblyID == nil && effectiveBodyID != nil }
    /// Stable BOM identity for this occurrence.
    public var bomIdentity: UUID
    /// Stable identity for render/selection; the instance ID is unique across
    /// the inline tree even when a definition-like subassembly is placed more
    /// than once by duplicating its children.
    public var id: UUID { instance.id }
}

/// One structural problem found in persisted hierarchy data. Reported, never
/// silently repaired by the reader.
public nonisolated struct CADAssemblyIntegrityIssue: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: String
    public var instanceID: UUID?
    public var referenceID: UUID?
    public var message: String

    public init(id: UUID = UUID(), kind: String, instanceID: UUID? = nil,
                referenceID: UUID? = nil, message: String) {
        self.id = id
        self.kind = kind
        self.instanceID = instanceID
        self.referenceID = referenceID
        self.message = message
    }
}

public nonisolated struct CADAssembly: Codable, Sendable, Equatable {
    public static let maxExplodedViews = 32
    public static let maxExplodedEntriesPerView = 128
    /// Bounded recursion for decoded/hand-authored hierarchy. Deeper data is
    /// left untouched and reported as an integrity issue, never truncated.
    public static let maxHierarchyDepth = 16

    public var instances: [CADAssemblyInstance]
    public var constraints: [CADAssemblyConstraint]
    /// Additive persisted exploded views. Missing in older assembly JSON;
    /// the custom decoder below defaults it to empty instead of failing.
    public var explodedViews: [CADExplodedView]
    /// Additive durable external part references. Missing in older assembly
    /// JSON; empty for every flat document.
    public var partReferences: [CADPartReference]

    public init(instances: [CADAssemblyInstance] = [],
                constraints: [CADAssemblyConstraint] = [],
                explodedViews: [CADExplodedView] = [],
                partReferences: [CADPartReference] = []) {
        self.instances = instances
        self.constraints = constraints
        self.explodedViews = explodedViews
        self.partReferences = partReferences
    }

    enum CodingKeys: String, CodingKey {
        case instances, constraints, explodedViews, partReferences
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        instances = try container.decodeIfPresent([CADAssemblyInstance].self,
                                                  forKey: .instances) ?? []
        constraints = try container.decodeIfPresent([CADAssemblyConstraint].self,
                                                    forKey: .constraints) ?? []
        explodedViews = try container.decodeIfPresent([CADExplodedView].self,
                                                      forKey: .explodedViews) ?? []
        partReferences = try container.decodeIfPresent([CADPartReference].self,
                                                       forKey: .partReferences) ?? []
    }

    public static func decode(from data: Data?) throws -> CADAssembly {
        guard let data, !data.isEmpty else { return CADAssembly() }
        return try JSONDecoder().decode(CADAssembly.self, from: data)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public func instance(_ id: UUID) -> CADAssemblyInstance? {
        Self.findInstance(id, in: instances)
    }

    /// Root-to-self identity path, or nil when no such instance exists.
    public func instancePath(_ id: UUID) -> [UUID]? {
        Self.findPath(id, in: instances, prefix: [])
    }

    public func parentInstanceID(of id: UUID) -> UUID? {
        guard let path = instancePath(id), path.count > 1 else { return nil }
        return path[path.count - 2]
    }

    public func directChildren(of id: UUID) -> [CADAssemblyInstance]? {
        instance(id)?.children
    }

    /// True when `ancestorID` is `descendantID` or one of its ancestors.
    public func isAncestor(_ ancestorID: UUID, of descendantID: UUID) -> Bool {
        guard let path = instancePath(descendantID) else { return false }
        return path.contains(ancestorID)
    }

    public func partReference(_ id: UUID) -> CADPartReference? {
        partReferences.first { $0.id == id }
    }

    /// Persisted semantics that a format-3 (or older) writer cannot be trusted
    /// to preserve: durable part references and any nested subassembly tree.
    /// Used by `CADDocumentFormat.requiredFormat` to raise ONLY these
    /// documents to format 4. Ordinary flat documents keep their older floor.
    public var requiresNestedFormat: Bool {
        if !partReferences.isEmpty { return true }
        return instances.contains { $0.requiresNestedFormat }
    }

    public func explodedView(_ id: UUID) -> CADExplodedView? {
        explodedViews.first { $0.id == id }
    }

    public func constraint(_ id: UUID) -> CADAssemblyConstraint? {
        if let root = constraints.first(where: { $0.id == id }) { return root }
        for occurrence in occurrences(includeHidden: true) {
            if let local = occurrence.instance.constraints.first(where: { $0.id == id }) {
                return local
            }
        }
        return nil
    }

    /// All constraints with their owning subassembly (nil = root scope).
    public func constraintsWithScope()
    -> [(parentID: UUID?, constraint: CADAssemblyConstraint)] {
        var result: [(UUID?, CADAssemblyConstraint)] = constraints.map { (nil, $0) }
        for occurrence in occurrences(includeHidden: true) where !occurrence.instance.constraints.isEmpty {
            for constraint in occurrence.instance.constraints {
                result.append((occurrence.instance.id, constraint))
            }
        }
        return result
    }

    /// Flattened occurrence list. Order is depth-first pre-order, which keeps
    /// the historical flat order exactly when no instance has children.
    public func occurrences(viewID: UUID? = nil,
                            includeHidden: Bool = true) -> [CADAssemblyOccurrence] {
        let view = viewID.flatMap { explodedView($0) }
        var result: [CADAssemblyOccurrence] = []
        var visited = Set<UUID>()

        func walk(_ list: [CADAssemblyInstance],
                  parentBase: CADTransform,
                  parentExploded: CADTransform?,
                  parentPath: [UUID],
                  parentNames: [String],
                  parentID: UUID?,
                  depth: Int,
                  parentVisible: Bool) {
            guard depth <= Self.maxHierarchyDepth else { return }
            for instance in list {
                guard visited.insert(instance.id).inserted else { continue }
                let baseWorld = parentBase.concatenating(instance.transform)
                var explodedWorld: CADTransform?
                if let view {
                    var value = (parentExploded ?? parentBase).concatenating(instance.transform)
                    let offset = view.offset(for: instance.id)
                    if offset != .zero { value.position += offset }
                    explodedWorld = value
                }
                let path = parentPath + [instance.id]
                let names = parentNames + [instance.name]
                let visible = parentVisible && !instance.isHidden
                if includeHidden || visible {
                    result.append(CADAssemblyOccurrence(
                        instance: instance,
                        path: path,
                        pathNames: names,
                        parentInstanceID: parentID,
                        depth: depth,
                        worldTransform: baseWorld,
                        explodedWorldTransform: explodedWorld,
                        isVisible: visible,
                        effectiveBodyID: instance.resolvedBodyID,
                        sourceReferenceID: instance.sourceReferenceID,
                        subassemblyID: instance.subassemblyID,
                        bomIdentity: instance.bomIdentity))
                }
                walk(instance.children,
                     parentBase: baseWorld,
                     parentExploded: explodedWorld,
                     parentPath: path,
                     parentNames: names,
                     parentID: instance.id,
                     depth: depth + 1,
                     parentVisible: visible)
            }
        }

        walk(instances, parentBase: .identity, parentExploded: nil,
             parentPath: [], parentNames: [], parentID: nil,
             depth: 0, parentVisible: true)
        return result
    }

    /// Occurrence lookup by instance ID, including nested children.
    public func occurrence(_ id: UUID, viewID: UUID? = nil) -> CADAssemblyOccurrence? {
        occurrences(viewID: viewID, includeHidden: true).first { $0.instance.id == id }
    }

    /// Base world placement of a nested occurrence.
    public func worldTransform(for instanceID: UUID) -> CADTransform? {
        occurrence(instanceID)?.worldTransform
    }

    /// World placement including one named exploded view.
    public func explodedWorldTransform(for instanceID: UUID,
                                       viewID: UUID?) -> CADTransform? {
        guard let occurrence = occurrence(instanceID, viewID: viewID) else { return nil }
        return occurrence.explodedWorldTransform ?? occurrence.worldTransform
    }

    /// Local placement with the named view's own offset. Retained for the
    /// historical flat API; nested consumers should use the world helpers.
    public func explodedTransform(for instanceID: UUID,
                                  viewID: UUID?) -> CADTransform? {
        guard let instance = instance(instanceID) else { return nil }
        guard let viewID, let view = explodedView(viewID) else { return instance.transform }
        var transform = instance.transform
        transform.position += view.offset(for: instanceID)
        return transform
    }

    // MARK: Integrity

    /// Report structural problems without mutating anything. The caller
    /// decides whether to refuse an edit; a reader never drops the data.
    public func integrityIssues(documentBodyIDs: Set<UUID>? = nil) -> [CADAssemblyIntegrityIssue] {
        var issues: [CADAssemblyIntegrityIssue] = []
        var seen = Set<UUID>()
        let references = Set(partReferences.map(\.id))
        var duplicatedReferences = Set<UUID>()

        for reference in partReferences {
            if !duplicatedReferences.insert(reference.id).inserted {
                issues.append(CADAssemblyIntegrityIssue(
                    kind: "duplicate_reference", referenceID: reference.id,
                    message: "Part reference \(reference.id.uuidString) appears more than once."))
            }
            if documentBodyIDs != nil, !documentBodyIDs!.contains(reference.stagedBodyID) {
                issues.append(CADAssemblyIntegrityIssue(
                    kind: "missing_staged_body", referenceID: reference.id,
                    message: "Part reference '\(reference.name)' has no staged local body; "
                        + "cached geometry is unavailable but the pin is retained."))
            }
        }

        let rootIDs = Set(instances.map(\.id))
        let nestedIDs = Set(occurrences(includeHidden: true)
            .filter { $0.parentInstanceID != nil }
            .map(\.instance.id))

        func walk(_ list: [CADAssemblyInstance], depth: Int, parentID: UUID?) {
            for instance in list {
                if !seen.insert(instance.id).inserted {
                    issues.append(CADAssemblyIntegrityIssue(
                        kind: "duplicate_instance", instanceID: instance.id,
                        message: "Assembly instance \(instance.id.uuidString) appears more than once."))
                }
                if depth > Self.maxHierarchyDepth {
                    issues.append(CADAssemblyIntegrityIssue(
                        kind: "depth_exceeded", instanceID: instance.id,
                        message: "Subassembly '\(instance.name)' exceeds the supported nesting depth."))
                    continue
                }
                if let referenceID = instance.sourceReferenceID,
                   !references.contains(referenceID) {
                    issues.append(CADAssemblyIntegrityIssue(
                        kind: "missing_reference", instanceID: instance.id,
                        referenceID: referenceID,
                        message: "Instance '\(instance.name)' points at a part reference that is not stored."))
                }
                if instance.isSubassembly {
                    if instance.bodyID != instance.subassemblyID {
                        issues.append(CADAssemblyIntegrityIssue(
                            kind: "subassembly_body_placeholder", instanceID: instance.id,
                            message: "Subassembly '\(instance.name)' has a body placeholder that differs "
                                + "from its stable subassembly identity; no document body is opened for it."))
                    }
                } else if instance.children.isEmpty == false {
                    issues.append(CADAssemblyIntegrityIssue(
                        kind: "children_without_subassembly", instanceID: instance.id,
                        message: "Instance '\(instance.name)' has children but no subassembly identity."))
                }

                for constraint in instance.constraints where instance.isSubassembly {
                    let childIDs = Set(instance.children.map(\.id))
                    if !childIDs.contains(constraint.instanceA)
                        || (constraint.instanceB != nil && !childIDs.contains(constraint.instanceB!)) {
                        issues.append(CADAssemblyIntegrityIssue(
                            kind: "constraint_scope", instanceID: instance.id,
                            message: "Constraint \(constraint.id.uuidString) targets a part outside its "
                                + "owning subassembly's direct children."))
                    }
                }
                walk(instance.children, depth: depth + 1, parentID: instance.id)
            }
        }

        walk(instances, depth: 0, parentID: nil)

        for constraint in constraints {
            if !rootIDs.contains(constraint.instanceA)
                || (constraint.instanceB != nil && !rootIDs.contains(constraint.instanceB!)) {
                issues.append(CADAssemblyIntegrityIssue(
                    kind: "constraint_scope", instanceID: constraint.instanceA,
                    message: "Root constraint \(constraint.id.uuidString) targets a nested instance; "
                        + "move it into the owning subassembly instead of silently flattening it."))
            }
        }
        _ = nestedIDs
        return issues
    }

    // MARK: Mutating tree helpers

    /// Apply a mutation to one instance (root or nested). Returns false when
    /// the id is absent.
    @discardableResult
    public mutating func updateInstance(_ id: UUID,
                                        _ mutate: (inout CADAssemblyInstance) -> Void) -> Bool {
        Self.updateInstance(id, in: &instances, mutate)
    }

    /// Remove one instance and its entire child subtree. Returns the removed
    /// root value (children included) or nil.
    @discardableResult
    public mutating func removeSubtree(_ id: UUID) -> CADAssemblyInstance? {
        Self.removeSubtree(id, from: &instances)
    }

    /// Append an instance at the root or under an existing subassembly.
    /// Refuses a non-subassembly parent and duplicate IDs.
    @discardableResult
    public mutating func appendInstance(_ instance: CADAssemblyInstance,
                                        parentID: UUID?) -> Bool {
        guard self.instance(instance.id) == nil else { return false }
        guard let parentID else {
            instances.append(instance)
            return true
        }
        guard let parent = self.instance(parentID), parent.isSubassembly else { return false }
        return updateInstance(parentID) { target in
            target.children.append(instance)
        }
    }

    /// Move an existing instance (with its subtree) under another
    /// subassembly, or back to the root. Cycles, self-parenting and duplicate
    /// identities are refused. The caller is responsible for refusing a move
    /// that would strand an out-of-scope constraint.
    @discardableResult
    public mutating func moveInstance(_ id: UUID, toParent parentID: UUID?) -> Bool {
        guard instance(id) != nil else { return false }
        if let parentID {
            guard parentID != id else { return false }
            guard let parent = instance(parentID), parent.isSubassembly else { return false }
            // The target may not be inside the subtree being moved.
            if isAncestor(id, of: parentID) { return false }
        }
        if parentInstanceID(of: id) == parentID { return true }
        guard let removed = removeSubtree(id) else { return false }
        return appendInstance(removed, parentID: parentID)
    }

    // MARK: Private tree helpers

    private static func findInstance(_ id: UUID,
                                     in list: [CADAssemblyInstance]) -> CADAssemblyInstance? {
        for instance in list {
            if instance.id == id { return instance }
            if let nested = findInstance(id, in: instance.children) { return nested }
        }
        return nil
    }

    private static func findPath(_ id: UUID, in list: [CADAssemblyInstance],
                                 prefix: [UUID]) -> [UUID]? {
        for instance in list {
            let path = prefix + [instance.id]
            if instance.id == id { return path }
            if let nested = findPath(id, in: instance.children, prefix: path) { return nested }
        }
        return nil
    }

    private static func updateInstance(_ id: UUID,
                                       in list: inout [CADAssemblyInstance],
                                       _ mutate: (inout CADAssemblyInstance) -> Void) -> Bool {
        for index in list.indices {
            if list[index].id == id {
                mutate(&list[index])
                return true
            }
            if updateInstance(id, in: &list[index].children, mutate) { return true }
        }
        return false
    }

    private static func removeSubtree(_ id: UUID,
                                      from list: inout [CADAssemblyInstance]) -> CADAssemblyInstance? {
        if let index = list.firstIndex(where: { $0.id == id }) {
            return list.remove(at: index)
        }
        for index in list.indices {
            if let removed = removeSubtree(id, from: &list[index].children) {
                return removed
            }
        }
        return nil
    }
}

/// Result of a constraint solve. `invalidReferences` lists constraints whose
/// instance/geometry no longer resolves; `conflicting` lists constraints that
/// cannot be satisfied together (DOF conflict).
public nonisolated struct CADAssemblySolveResult: Sendable, Equatable {
    public var updatedInstances: [CADAssemblyInstance]
    public var invalidReferences: [UUID]
    public var conflicting: [UUID]
    public var solved: Bool

    public init(updatedInstances: [CADAssemblyInstance],
                invalidReferences: [UUID] = [],
                conflicting: [UUID] = [],
                solved: Bool) {
        self.updatedInstances = updatedInstances
        self.invalidReferences = invalidReferences
        self.conflicting = conflicting
        self.solved = solved
    }
}

// MARK: - Placement

extension CADTransform {
    /// The kernel TRS placement of this instance transform (uniform scale),
    /// mirroring `CADAssemblySolver.transform3D(from:)` so the VIEWPORT and the
    /// solver/derived code compute the identical placement. Non-finite or
    /// degenerate rotations fall back to identity rotation rather than
    /// poisoning the render matrix.
    nonisolated func placement3D() -> Transform3D {
        let length = simd_length(rotation)
        let quaternion = length > 1e-12
            ? simd_quatd(ix: rotation.x / length,
                         iy: rotation.y / length,
                         iz: rotation.z / length,
                         r: rotation.w / length)
            : simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        return Transform3D(translation: position,
                           rotation: quaternion,
                           scale: scale.x)
    }

    /// True when this transform is finite with positive uniform scale — the
    /// same validity rule the assembly solver applies before placement.
    nonisolated var isPlaceable: Bool {
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite,
              rotation.x.isFinite, rotation.y.isFinite, rotation.z.isFinite, rotation.w.isFinite,
              scale.x.isFinite, scale.y.isFinite, scale.z.isFinite,
              scale.x > 0, scale.y > 0, scale.z > 0 else { return false }
        let spread = max(scale.x, max(scale.y, scale.z))
        guard abs(scale.x - scale.y) <= 1e-9 * spread,
              abs(scale.y - scale.z) <= 1e-9 * spread,
              simd_length(rotation) > 1e-12 else { return false }
        return true
    }
}
