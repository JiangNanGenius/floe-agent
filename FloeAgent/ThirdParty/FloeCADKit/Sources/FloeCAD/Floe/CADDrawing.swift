//
//  CADDrawing.swift
//  FloeCADKit
//
//  Drawing-set model for FloeCAD: independent pages, a v4 shared-sheet view
//  list with per-view scale and projection alignment, explicit paper/title,
//  and model-revision associativity. Geometry generation and export
//  (PDF/SVG/DXF) live in CADDrawingService; this file is the persisted
//  contract, shared by the UI, the AI tool and the file store.
//

import Foundation

public nonisolated enum CADDrawingViewKind: String, Codable, Sendable, CaseIterable {
    case front, top, side, iso, section, detail, exploded

    public var title: String {
        switch self {
        case .front: return "Front"
        case .top: return "Top"
        case .side: return "Side"
        case .iso: return "Isometric"
        case .section: return "Section"
        case .detail: return "Detail"
        case .exploded: return "Exploded"
        }
    }

    /// Projection kinds that share the orthographic silhouette/edge path.
    public var isOrthographic: Bool {
        switch self {
        case .front, .top, .side, .iso, .exploded: return true
        case .section, .detail: return false
        }
    }
}

public nonisolated enum CADPaperSize: String, Codable, Sendable, CaseIterable {
    case a4, a3, a2, a1, a0, letter, tabloid, custom

    /// Paper size in millimetres (portrait). `custom` uses the page's stored
    /// width/height.
    public var millimetres: (width: Double, height: Double) {
        switch self {
        case .a4: return (210, 297)
        case .a3: return (297, 420)
        case .a2: return (420, 594)
        case .a1: return (594, 841)
        case .a0: return (841, 1189)
        case .letter: return (215.9, 279.4)
        case .tabloid: return (279.4, 431.8)
        case .custom: return (297, 420)
        }
    }
}

/// Ordered fingerprint of a page's source geometry: one entry per source body
/// (in `sourceBodyIDs` order) with the render-mesh content hash and the
/// placement hash captured when the view was projected. This is the page's
/// staleness identity — it notices a changed NON-maximum source, survives
/// reopen (content hashes are durable identities, unlike per-session revision
/// counters) and records a missing source explicitly.
public nonisolated struct CADDrawingSourceFingerprint: Codable, Sendable, Equatable {
    public nonisolated struct Source: Codable, Sendable, Equatable {
        public var bodyID: UUID
        public var missing: Bool
        /// SHA-256 of the persisted render-mesh blob at projection time.
        public var renderSHA256: String?
        /// SHA-256 of the body's placement transform at projection time.
        public var placementSHA256: String?

        public init(bodyID: UUID, missing: Bool,
                    renderSHA256: String? = nil, placementSHA256: String? = nil) {
            self.bodyID = bodyID
            self.missing = missing
            self.renderSHA256 = renderSHA256
            self.placementSHA256 = placementSHA256
        }
    }

    /// One placed assembly instance's durable identity for an assembly-aware
    /// page. `placementSHA256` covers the world placement INCLUDING the named
    /// exploded-view offset, so switching/previewing a view marks the page
    /// stale until it is re-projected.
    public nonisolated struct InstanceSource: Codable, Sendable, Equatable {
        public var instanceID: UUID
        public var bodyID: UUID
        public var missing: Bool
        public var placementSHA256: String?
        public var explodedViewID: UUID?

        public init(instanceID: UUID, bodyID: UUID, missing: Bool,
                    placementSHA256: String? = nil,
                    explodedViewID: UUID? = nil) {
            self.instanceID = instanceID
            self.bodyID = bodyID
            self.missing = missing
            self.placementSHA256 = placementSHA256
            self.explodedViewID = explodedViewID
        }
    }

    public var sources: [Source]
    /// Present only for assembly-aware pages; nil on ordinary pages and on
    /// pages written before assembly projection existed.
    public var instances: [InstanceSource]?

    public init(sources: [Source] = [], instances: [InstanceSource]? = nil) {
        self.sources = sources
        self.instances = instances
    }

    /// Compare against the live fingerprint. A legacy page without a recorded
    /// fingerprint is stale until it is re-projected.
    public func matches(_ live: CADDrawingSourceFingerprint?) -> Bool {
        guard let live else { return false }
        return self == live
    }
}

// MARK: - Shared-sheet views (schema v4)

/// Where an aligned view sits relative to its reference view. `free` uses the
/// view's own `offset` directly; every other case re-derives the placement
/// from the reference view's LIVE projected bounds, so changing the model (or
/// the reference view's scale) moves the aligned view with it.
public nonisolated enum CADDrawingViewPlacement: String, Codable, Sendable, CaseIterable {
    case free, above, below, left, right
}

/// Projection alignment for one view on a shared sheet. The cross axis is
/// always centred on the reference view's projected bounds; `gapMM` is the
/// clear sheet-space gap along the placement axis.
public nonisolated struct CADDrawingViewAlignment: Codable, Sendable, Equatable {
    public var referenceViewID: UUID?
    public var placement: CADDrawingViewPlacement
    public var gapMM: Double

    public init(referenceViewID: UUID? = nil,
                placement: CADDrawingViewPlacement = .free,
                gapMM: Double = 14) {
        self.referenceViewID = referenceViewID
        self.placement = placement
        self.gapMM = gapMM
    }

    enum CodingKeys: String, CodingKey {
        case referenceViewID, placement, gapMM
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        referenceViewID = try container.decodeIfPresent(UUID.self, forKey: .referenceViewID)
        placement = try container.decodeIfPresent(CADDrawingViewPlacement.self,
                                                  forKey: .placement) ?? .free
        gapMM = try container.decodeIfPresent(Double.self, forKey: .gapMM) ?? 14
    }
}

/// Stable, radius-independent identity of a kernel face used by a linked
/// drawing dimension. The centroid/axis pair survives a diameter edit (the
/// cylinder's axis and axial centre do not move when its radius changes), so
/// Ø10 → Ø8 remeasures on the SAME dimension id. Radius is kept as provenance
/// only and is never part of the match.
public nonisolated enum CADDrawingFeatureKind: String, Codable, Sendable {
    case cylindricalFace
}

public nonisolated struct CADDrawingFeatureAnchor: Codable, Sendable, Equatable {
    /// Body-local face centroid (mm).
    public var centroid: SIMD3<Double>
    /// Body-local cylindrical axis direction.
    public var direction: SIMD3<Double>
    /// Captured radius (provenance; a radius edit does not invalidate it).
    public var radiusMM: Double?
    /// Re-find tolerance in model mm. The axis direction is compared
    /// separately with a fixed angular tolerance.
    public var toleranceMM: Double

    public init(centroid: SIMD3<Double>, direction: SIMD3<Double>,
                radiusMM: Double? = nil, toleranceMM: Double = 0.5) {
        self.centroid = centroid
        self.direction = direction
        self.radiusMM = radiusMM
        self.toleranceMM = toleranceMM
    }
}

/// A linked drawing dimension's semantic source. Resolution is by the live
/// kernel face anchor, never by a stale numeric index. `sketchID` /
/// `sketchEntityID` / `featureID` are provenance and diagnosis; the measured
/// value always comes from the resolved kernel face.
public nonisolated struct CADDrawingFeatureReference: Codable, Sendable, Equatable {
    public var kind: CADDrawingFeatureKind
    /// The document body that owns the face (for an assembly occurrence this
    /// is the source body id, not the occurrence id).
    public var bodyID: UUID
    /// Assembly occurrence, when the dimension lives on a placed instance.
    public var instanceID: UUID?
    public var anchor: CADDrawingFeatureAnchor
    public var featureID: UUID?
    public var sketchID: UUID?
    public var sketchEntityID: UUID?
    /// Mesh revision the face was captured from (information only).
    public var sourceRevision: UInt64?

    public init(kind: CADDrawingFeatureKind = .cylindricalFace,
                bodyID: UUID, instanceID: UUID? = nil,
                anchor: CADDrawingFeatureAnchor,
                featureID: UUID? = nil,
                sketchID: UUID? = nil,
                sketchEntityID: UUID? = nil,
                sourceRevision: UInt64? = nil) {
        self.kind = kind
        self.bodyID = bodyID
        self.instanceID = instanceID
        self.anchor = anchor
        self.featureID = featureID
        self.sketchID = sketchID
        self.sketchEntityID = sketchEntityID
        self.sourceRevision = sourceRevision
    }
}

/// One independently placed projection on a shared drawing sheet. `offset` is
/// in sheet mm. For `free` views it is the absolute translation; for an
/// aligned view it is an additional nudge applied after the alignment solve.
/// `scale` is drawing mm per model mm for THIS view, so a sheet can show the
/// same model at different scales without duplicating an editable model.
public nonisolated struct CADDrawingSheetView: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: CADDrawingViewKind
    public var scale: Double
    public var offset: SIMD2<Double>
    public var viewNormal: SIMD3<Double>
    public var viewUp: SIMD3<Double>
    public var sectionOrigin: SIMD3<Double>?
    public var sectionNormal: SIMD3<Double>?
    public var detailOrigin: SIMD3<Double>?
    public var detailSizeMM: SIMD2<Double>?
    /// Per-view source filter; nil/empty inherits the page's `sourceBodyIDs`.
    public var sourceBodyIDs: [UUID]?
    public var alignment: CADDrawingViewAlignment

    public init(id: UUID = UUID(), name: String, kind: CADDrawingViewKind,
                scale: Double = 1, offset: SIMD2<Double> = .zero,
                viewNormal: SIMD3<Double> = SIMD3(0, 0, 1),
                viewUp: SIMD3<Double> = SIMD3(0, 1, 0),
                sectionOrigin: SIMD3<Double>? = nil,
                sectionNormal: SIMD3<Double>? = nil,
                detailOrigin: SIMD3<Double>? = nil,
                detailSizeMM: SIMD2<Double>? = nil,
                sourceBodyIDs: [UUID]? = nil,
                alignment: CADDrawingViewAlignment = CADDrawingViewAlignment()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.scale = scale
        self.offset = offset
        self.viewNormal = viewNormal
        self.viewUp = viewUp
        self.sectionOrigin = sectionOrigin
        self.sectionNormal = sectionNormal
        self.detailOrigin = detailOrigin
        self.detailSizeMM = detailSizeMM
        self.sourceBodyIDs = sourceBodyIDs
        self.alignment = alignment
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, scale, offset, viewNormal, viewUp
        case sectionOrigin, sectionNormal, detailOrigin, detailSizeMM
        case sourceBodyIDs, alignment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "View"
        kind = try container.decodeIfPresent(CADDrawingViewKind.self, forKey: .kind) ?? .front
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        offset = try container.decodeIfPresent(SIMD2<Double>.self, forKey: .offset) ?? .zero
        viewNormal = try container.decodeIfPresent(SIMD3<Double>.self, forKey: .viewNormal)
            ?? SIMD3(0, 0, 1)
        viewUp = try container.decodeIfPresent(SIMD3<Double>.self, forKey: .viewUp)
            ?? SIMD3(0, 1, 0)
        sectionOrigin = try container.decodeIfPresent(SIMD3<Double>.self, forKey: .sectionOrigin)
        sectionNormal = try container.decodeIfPresent(SIMD3<Double>.self, forKey: .sectionNormal)
        detailOrigin = try container.decodeIfPresent(SIMD3<Double>.self, forKey: .detailOrigin)
        detailSizeMM = try container.decodeIfPresent(SIMD2<Double>.self, forKey: .detailSizeMM)
        sourceBodyIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceBodyIDs)
        alignment = try container.decodeIfPresent(CADDrawingViewAlignment.self,
                                                  forKey: .alignment)
            ?? CADDrawingViewAlignment()
        if viewNormal == .zero { viewNormal = SIMD3(0, 0, 1) }
        if viewUp == .zero { viewUp = SIMD3(0, 1, 0) }
        if !scale.isFinite || scale <= 0 { scale = 1 }
    }
}

// MARK: - Assembly annotations

/// Binds a drawing annotation to live assembly geometry. `modelPoints` are
/// BODY-LOCAL (part-frame) points; projection re-applies the page's live
/// instance placement (and its exploded offset) so an annotation follows a
/// moved or exploded instance. `sourceRevision` is the body mesh revision the
/// points were picked from; a mismatch is reported as stale, never re-bound
/// to an unrelated surface.
public nonisolated struct CADDrawingBinding: Codable, Sendable, Equatable {
    public var instanceID: UUID?
    public var bodyID: UUID?
    public var modelPoints: [SIMD3<Double>]
    public var sourceRevision: UInt64?

    public init(instanceID: UUID? = nil, bodyID: UUID? = nil,
                modelPoints: [SIMD3<Double>] = [], sourceRevision: UInt64? = nil) {
        self.instanceID = instanceID
        self.bodyID = bodyID
        self.modelPoints = modelPoints
        self.sourceRevision = sourceRevision
    }
}

public nonisolated enum CADDrawingDimensionKind: String, Codable, Sendable, CaseIterable {
    case length, angle, radius, diameter

    public var title: String {
        switch self {
        case .length: return "Length"
        case .angle: return "Angle"
        case .radius: return "Radius"
        case .diameter: return "Diameter"
        }
    }
}

/// A manually placed basic dimension. `value` is captured in model units (mm,
/// or degrees for angle) and is never silently rewritten; a live projection
/// recomputes geometry positions and reports a stale binding when the source
/// part changed.
public nonisolated struct CADDrawingManualDimension: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: CADDrawingDimensionKind
    /// Drawing-space reference points captured at creation. They are LOCAL to
    /// `viewID` (before that view's sheet offset), matching
    /// `binding.modelPoints` order.
    public var drawingPoints: [SIMD2<Double>]
    public var value: Double
    public var textPosition: SIMD2<Double>
    public var textOverride: String?
    public var binding: CADDrawingBinding?
    /// Shared-sheet view this annotation belongs to. Nil on legacy pages and
    /// on single-view pages; a multi-view sheet requires it for new edits.
    public var viewID: UUID?
    /// Linked kernel-face source. When present this is the measurement
    /// authority: a live remeasure replaces `value` in every reply and a
    /// missing/ambiguous face is reported as dangling (never the old value).
    public var feature: CADDrawingFeatureReference?

    public init(id: UUID = UUID(), kind: CADDrawingDimensionKind,
                drawingPoints: [SIMD2<Double>], value: Double,
                textPosition: SIMD2<Double>, textOverride: String? = nil,
                binding: CADDrawingBinding? = nil,
                viewID: UUID? = nil,
                feature: CADDrawingFeatureReference? = nil) {
        self.id = id
        self.kind = kind
        self.drawingPoints = drawingPoints
        self.value = value
        self.textPosition = textPosition
        self.textOverride = textOverride
        self.binding = binding
        self.viewID = viewID
        self.feature = feature
    }
}

/// A balloon keyed by BOM item number and, when available, a concrete
/// assembly instance. The leader target is recomputed from live projected
/// instance geometry; a missing instance is reported, never silently dropped.
public nonisolated struct CADDrawingBalloon: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var itemNumber: Int
    public var bomEntryID: UUID?
    public var instanceID: UUID?
    /// Drawing-space balloon centre (page mm).
    public var anchor: SIMD2<Double>
    /// Explicit leader target; nil = nearest point of the instance's live
    /// projected bounds.
    public var target: SIMD2<Double>?
    public var text: String?
    /// Shared-sheet view this balloon belongs to (coordinates are view-local).
    public var viewID: UUID?

    public init(id: UUID = UUID(), itemNumber: Int, bomEntryID: UUID? = nil,
                instanceID: UUID? = nil, anchor: SIMD2<Double>,
                target: SIMD2<Double>? = nil, text: String? = nil,
                viewID: UUID? = nil) {
        self.id = id
        self.itemNumber = itemNumber
        self.bomEntryID = bomEntryID
        self.instanceID = instanceID
        self.anchor = anchor
        self.target = target
        self.text = text
        self.viewID = viewID
    }
}

public nonisolated struct CADDrawingBOMEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var itemNumber: Int
    public var name: String
    public var partNumber: String
    /// Stable part-definition identity this row groups, when known. For a
    /// shared external reference this is the reference id; for an ordinary
    /// shared body or an independent copy it is that body id. Nil only on
    /// legacy rows written before engineering metadata existed; readers fall
    /// back to `bodyID` without merging distinct definitions.
    public var partDefinitionID: UUID?
    /// Engineering material captured when the row was derived (never the PBR
    /// appearance). Live reports prefer the assembly's current record.
    public var material: String?
    /// Explicit engineering revision captured for this definition.
    public var version: String?
    /// The part definition's shared source body. Kept for the existing body
    /// picker/missing-body diagnostics and legacy rows.
    public var bodyID: UUID
    /// The assembly instances that make up this item. Shared instances of one
    /// body are one row with a quantity; an independent copy is its own row.
    public var instanceIDs: [UUID]
    /// Quantity captured when the BOM was derived; live reports also compute
    /// the current count and flag a difference.
    public var quantity: Int

    public init(id: UUID = UUID(), itemNumber: Int, name: String,
                partNumber: String = "", bodyID: UUID,
                instanceIDs: [UUID] = [], quantity: Int = 1,
                partDefinitionID: UUID? = nil, material: String? = nil,
                version: String? = nil) {
        self.id = id
        self.itemNumber = itemNumber
        self.name = name
        self.partNumber = partNumber
        self.partDefinitionID = partDefinitionID
        self.material = material
        self.version = version
        self.bodyID = bodyID
        self.instanceIDs = instanceIDs
        self.quantity = quantity
    }

    /// The identity used to match this row to live occurrences. Legacy rows
    /// resolve their old body-id key; the fallback never guesses by name or
    /// geometry.
    public var resolvedPartDefinitionID: UUID { partDefinitionID ?? bodyID }
}

public nonisolated struct CADDrawingBOM: Codable, Sendable, Equatable {
    public var entries: [CADDrawingBOMEntry]

    public init(entries: [CADDrawingBOMEntry] = []) {
        self.entries = entries
    }

    public func entry(itemNumber: Int) -> CADDrawingBOMEntry? {
        entries.first { $0.itemNumber == itemNumber }
    }

    public func entry(id: UUID) -> CADDrawingBOMEntry? {
        entries.first { $0.id == id }
    }

    /// Row bound to one stable part definition, if the page already has one.
    public func entry(partDefinitionID: UUID) -> CADDrawingBOMEntry? {
        entries.first { $0.resolvedPartDefinitionID == partDefinitionID }
    }
}

/// Free text placed on the sheet. An optional binding anchors it to live
/// assembly geometry; loose text is a plain manual annotation.
public nonisolated struct CADDrawingTextAnnotation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var position: SIMD2<Double>
    public var heightMM: Double
    public var binding: CADDrawingBinding?
    /// Shared-sheet view this annotation belongs to (position is view-local).
    public var viewID: UUID?

    public init(id: UUID = UUID(), text: String, position: SIMD2<Double>,
                heightMM: Double = 3.5, binding: CADDrawingBinding? = nil,
                viewID: UUID? = nil) {
        self.id = id
        self.text = text
        self.position = position
        self.heightMM = heightMM
        self.binding = binding
        self.viewID = viewID
    }
}

/// One independent drawing page. `modelRevision` records which document
/// revision the projected geometry was generated from (informational);
/// `sourceFingerprint` is the staleness authority. A page whose fingerprint
/// differs from the live model is explicitly stale rather than silently
/// re-projected.
public nonisolated struct CADDrawingPage: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: CADDrawingViewKind
    public var scale: Double
    public var paper: CADPaperSize
    public var customWidthMM: Double?
    public var customHeightMM: Double?
    public var title: String
    public var partNumbers: [String]
    public var sourceBodyIDs: [UUID]
    /// World-space view direction (camera looking along -normal) and up vector.
    public var viewNormal: SIMD3<Double>
    public var viewUp: SIMD3<Double>
    /// Section plane (origin + normal) for `section` pages.
    public var sectionOrigin: SIMD3<Double>?
    public var sectionNormal: SIMD3<Double>?
    /// Detail window for `detail` pages: model-space center + size (mm,
    /// width/height). Typed fields — never aliased into the section plane.
    public var detailOrigin: SIMD3<Double>?
    public var detailSizeMM: SIMD2<Double>?
    /// Pinned model revision; nil means generated at the current revision.
    public var modelRevision: UInt64?
    /// Ordered per-source content/placement identity (see above).
    public var sourceFingerprint: CADDrawingSourceFingerprint?
    public var showCenterlines: Bool
    public var showDimensions: Bool

    // Additive v3 assembly/annotation state. Every field decodes to a
    // default when missing, so a v1/v2 page opens unchanged; the service
    // never infers assembly projection for a page that did not ask for it.

    /// Project the live assembly placements (not the raw body transforms).
    /// `sourceBodyIDs` stays the optional filter; empty = every visible
    /// instance.
    public var assemblyMode: Bool
    /// Named exploded view applied to this page's placements. A missing view
    /// is reported on projection and falls back to the base placement.
    public var explodedViewID: UUID?
    /// Captured view name for display when the view no longer exists.
    public var explodedViewName: String?
    public var showBOM: Bool
    public var bom: CADDrawingBOM?
    public var balloons: [CADDrawingBalloon]
    public var manualDimensions: [CADDrawingManualDimension]
    public var annotations: [CADDrawingTextAnnotation]

    // Additive v4 shared-sheet state. Nil/empty = a legacy single-view page
    // whose one view is derived from the page fields above. A multi-view page
    // stores every view here; its page-level `sourceBodyIDs` is deliberately
    // empty so an older reader cannot present one bare view as the complete
    // sheet (older builds also refuse to edit a v4 set).
    public var sheetViews: [CADDrawingSheetView]?

    public init(id: UUID = UUID(),
                name: String,
                kind: CADDrawingViewKind,
                scale: Double = 1,
                paper: CADPaperSize = .a3,
                title: String = "",
                partNumbers: [String] = [],
                sourceBodyIDs: [UUID] = [],
                viewNormal: SIMD3<Double> = SIMD3(0, 0, 1),
                viewUp: SIMD3<Double> = SIMD3(0, 1, 0),
                sectionOrigin: SIMD3<Double>? = nil,
                sectionNormal: SIMD3<Double>? = nil,
                detailOrigin: SIMD3<Double>? = nil,
                detailSizeMM: SIMD2<Double>? = nil,
                modelRevision: UInt64? = nil,
                sourceFingerprint: CADDrawingSourceFingerprint? = nil,
                showCenterlines: Bool = false,
                showDimensions: Bool = false,
                assemblyMode: Bool = false,
                explodedViewID: UUID? = nil,
                explodedViewName: String? = nil,
                showBOM: Bool = false,
                bom: CADDrawingBOM? = nil,
                balloons: [CADDrawingBalloon] = [],
                manualDimensions: [CADDrawingManualDimension] = [],
                annotations: [CADDrawingTextAnnotation] = [],
                sheetViews: [CADDrawingSheetView]? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.scale = scale
        self.paper = paper
        self.title = title
        self.partNumbers = partNumbers
        self.sourceBodyIDs = sourceBodyIDs
        self.viewNormal = viewNormal
        self.viewUp = viewUp
        self.sectionOrigin = sectionOrigin
        self.sectionNormal = sectionNormal
        self.detailOrigin = detailOrigin
        self.detailSizeMM = detailSizeMM
        self.modelRevision = modelRevision
        self.sourceFingerprint = sourceFingerprint
        self.showCenterlines = showCenterlines
        self.showDimensions = showDimensions
        self.assemblyMode = assemblyMode
        self.explodedViewID = explodedViewID
        self.explodedViewName = explodedViewName
        self.showBOM = showBOM
        self.bom = bom
        self.balloons = balloons
        self.manualDimensions = manualDimensions
        self.annotations = annotations
        self.sheetViews = sheetViews
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, scale, paper, title, partNumbers, sourceBodyIDs
        case customWidthMM, customHeightMM
        case viewNormal, viewUp, sectionOrigin, sectionNormal
        case detailOrigin, detailSizeMM, modelRevision, sourceFingerprint
        case showCenterlines, showDimensions
        case assemblyMode, explodedViewID, explodedViewName, showBOM
        case bom, balloons, manualDimensions, annotations, sheetViews
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(CADDrawingViewKind.self, forKey: .kind)
        scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        paper = try container.decodeIfPresent(CADPaperSize.self, forKey: .paper) ?? .a3
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        partNumbers = try container.decodeIfPresent([String].self, forKey: .partNumbers) ?? []
        sourceBodyIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceBodyIDs) ?? []
        viewNormal = try container.decodeIfPresent(SIMD3<Double>.self, forKey: .viewNormal)
            ?? SIMD3(0, 0, 1)
        viewUp = try container.decodeIfPresent(SIMD3<Double>.self, forKey: .viewUp)
            ?? SIMD3(0, 1, 0)
        sectionOrigin = try container.decodeIfPresent(SIMD3<Double>.self, forKey: .sectionOrigin)
        sectionNormal = try container.decodeIfPresent(SIMD3<Double>.self, forKey: .sectionNormal)
        detailOrigin = try container.decodeIfPresent(SIMD3<Double>.self, forKey: .detailOrigin)
        detailSizeMM = try container.decodeIfPresent(SIMD2<Double>.self, forKey: .detailSizeMM)
        modelRevision = try container.decodeIfPresent(UInt64.self, forKey: .modelRevision)
        sourceFingerprint = try container.decodeIfPresent(CADDrawingSourceFingerprint.self,
                                                          forKey: .sourceFingerprint)
        showCenterlines = try container.decodeIfPresent(Bool.self, forKey: .showCenterlines) ?? false
        showDimensions = try container.decodeIfPresent(Bool.self, forKey: .showDimensions) ?? false
        customWidthMM = try container.decodeIfPresent(Double.self, forKey: .customWidthMM)
        customHeightMM = try container.decodeIfPresent(Double.self, forKey: .customHeightMM)
        assemblyMode = try container.decodeIfPresent(Bool.self, forKey: .assemblyMode) ?? false
        explodedViewID = try container.decodeIfPresent(UUID.self, forKey: .explodedViewID)
        explodedViewName = try container.decodeIfPresent(String.self, forKey: .explodedViewName)
        showBOM = try container.decodeIfPresent(Bool.self, forKey: .showBOM) ?? false
        bom = try container.decodeIfPresent(CADDrawingBOM.self, forKey: .bom)
        balloons = try container.decodeIfPresent([CADDrawingBalloon].self, forKey: .balloons) ?? []
        manualDimensions = try container.decodeIfPresent([CADDrawingManualDimension].self,
                                                         forKey: .manualDimensions) ?? []
        annotations = try container.decodeIfPresent([CADDrawingTextAnnotation].self,
                                                    forKey: .annotations) ?? []
        sheetViews = try container.decodeIfPresent([CADDrawingSheetView].self,
                                                   forKey: .sheetViews)
        if viewNormal == .zero { viewNormal = SIMD3(0, 0, 1) }
        if viewUp == .zero { viewUp = SIMD3(0, 1, 0) }
    }

    public var paperWidthMM: Double {
        customWidthMM ?? paper.millimetres.width
    }
    public var paperHeightMM: Double {
        customHeightMM ?? paper.millimetres.height
    }

    /// True when the page stores more than one sheet view. A v1/v2/v3 page
    /// (and a single-view v4 page) is still one legacy projection.
    public var isMultiViewSheet: Bool {
        (sheetViews?.count ?? 0) > 1
    }

    /// The page's views, materialising the legacy single view when the v4
    /// `sheetViews` field is absent. The synthesized view is not persisted, so
    /// old pages stay byte-compatible until they are edited.
    public var effectiveSheetViews: [CADDrawingSheetView] {
        if let sheetViews, !sheetViews.isEmpty { return sheetViews }
        return [CADDrawingSheetView(
            name: name,
            kind: kind,
            scale: scale,
            offset: .zero,
            viewNormal: viewNormal,
            viewUp: viewUp,
            sectionOrigin: sectionOrigin,
            sectionNormal: sectionNormal,
            detailOrigin: detailOrigin,
            detailSizeMM: detailSizeMM,
            sourceBodyIDs: sourceBodyIDs.isEmpty ? nil : sourceBodyIDs,
            alignment: CADDrawingViewAlignment())]
    }

    /// Source filter used for page-level staleness when the page has several
    /// views: a view with no filter means "all sources", so the union is also
    /// unfiltered. Single-view pages keep the historical page array.
    public var effectiveSourceBodyIDs: [UUID] {
        guard let sheetViews, !sheetViews.isEmpty else { return sourceBodyIDs }
        if sheetViews.contains(where: { ($0.sourceBodyIDs ?? []).isEmpty })
            && sourceBodyIDs.isEmpty {
            return []
        }
        var seen = Set<UUID>()
        var result: [UUID] = []
        for view in sheetViews {
            let ids = view.sourceBodyIDs ?? sourceBodyIDs
            for id in ids where seen.insert(id).inserted { result.append(id) }
        }
        return result
    }

    /// A page is stale when it pins a revision older than the live document.
    /// Kept for callers that only have revisions; `isStale(against:)` is the
    /// fingerprint-based authority the drawing service uses.
    public func isStale(comparedTo liveRevision: UInt64?) -> Bool {
        guard let modelRevision, let liveRevision else { return false }
        return modelRevision != liveRevision
    }

    /// Fingerprint staleness: a missing recorded fingerprint (legacy page) or
    /// any content/placement/missing-source difference is stale.
    public func isStale(against live: CADDrawingSourceFingerprint?) -> Bool {
        guard let recorded = sourceFingerprint else { return true }
        return !recorded.matches(live)
    }
}

public nonisolated struct CADDrawingSet: Codable, Sendable, Equatable {
    /// Drawing schema. v1 pages carry no detail fields and no source
    /// fingerprint; v2 adds typed detail windows and the fingerprint; v3 adds
    /// assembly-aware projection, exploded views, BOM/balloons and manual
    /// annotation; v4 adds shared-sheet multi-view layout, per-view scale and
    /// projection alignment, view-scoped annotations and linked kernel-face
    /// dimensions. Every v4 field decodes to a default, so v1/v2/v3 pages open
    /// unchanged. A newer value opens for reading and blocks edits (the
    /// service refuses). v4 is a DRAWING-JSON floor only: the surrounding
    /// `.floecad` package format is unchanged, and no App version is encoded
    /// here.
    public static let currentSchemaVersion = 4
    public var schemaVersion: Int
    public var pages: [CADDrawingPage]

    public init(pages: [CADDrawingPage] = [],
                schemaVersion: Int = CADDrawingSet.currentSchemaVersion) {
        self.schemaVersion = schemaVersion
        self.pages = pages
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, pages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Missing key = legacy document (v1); never fail a decode on it.
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        pages = try container.decodeIfPresent([CADDrawingPage].self, forKey: .pages) ?? []
    }

    public static func decode(from data: Data?) throws -> CADDrawingSet {
        guard let data, !data.isEmpty else { return CADDrawingSet() }
        return try JSONDecoder().decode(CADDrawingSet.self, from: data)
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Standard drawing sheet: the four default projections for a body.
    public static func standardSheet(for bodyID: UUID, title: String) -> CADDrawingSet {
        let views: [(CADDrawingViewKind, SIMD3<Double>)] = [
            (.front, SIMD3(0, -1, 0)),
            (.top, SIMD3(0, 0, 1)),
            (.side, SIMD3(1, 0, 0)),
            (.iso, SIMD3(1, -1, 1)),
        ]
        return CADDrawingSet(pages: views.map { kind, normal in
            CADDrawingPage(name: kind.title, kind: kind, title: title,
                           sourceBodyIDs: [bodyID], viewNormal: normal)
        })
    }

    /// One A3-style shared sheet: front, top, side and section views on the
    /// SAME page. Each view carries its own scale and projection alignment;
    /// `bodyIDs` filter every view. Page-level `sourceBodyIDs` is intentionally
    /// empty so an older v3 reader shows no fabricated single-view geometry.
    public static func multiViewSheet(bodyIDs: [UUID],
                                      title: String,
                                      scale: Double = 1,
                                      paper: CADPaperSize = .a3,
                                      sectionOrigin: SIMD3<Double>,
                                      sectionNormal: SIMD3<Double>,
                                      assemblyMode: Bool = false,
                                      explodedViewID: UUID? = nil,
                                      explodedViewName: String? = nil) -> CADDrawingSet {
        let front = CADDrawingSheetView(name: "Front", kind: .front,
                                        scale: scale, offset: SIMD2(30, 150),
                                        viewNormal: SIMD3(0, -1, 0),
                                        viewUp: SIMD3(0, 1, 0),
                                        sourceBodyIDs: bodyIDs)
        let top = CADDrawingSheetView(name: "Top", kind: .top,
                                      scale: scale, offset: .zero,
                                      viewNormal: SIMD3(0, 0, 1),
                                      viewUp: SIMD3(0, 1, 0),
                                      sourceBodyIDs: bodyIDs,
                                      alignment: CADDrawingViewAlignment(referenceViewID: front.id,
                                                                         placement: .above))
        let side = CADDrawingSheetView(name: "Side", kind: .side,
                                       scale: scale, offset: .zero,
                                       viewNormal: SIMD3(1, 0, 0),
                                       viewUp: SIMD3(0, 1, 0),
                                       sourceBodyIDs: bodyIDs,
                                       alignment: CADDrawingViewAlignment(referenceViewID: front.id,
                                                                          placement: .right))
        let section = CADDrawingSheetView(name: "Section", kind: .section,
                                          scale: scale, offset: .zero,
                                          viewNormal: sectionNormal,
                                          viewUp: SIMD3(0, 1, 0),
                                          sectionOrigin: sectionOrigin,
                                          sectionNormal: sectionNormal,
                                          sourceBodyIDs: bodyIDs,
                                          alignment: CADDrawingViewAlignment(referenceViewID: front.id,
                                                                             placement: .below))
        let page = CADDrawingPage(name: "Sheet", kind: .front, scale: scale,
                                  paper: paper, title: title,
                                  sourceBodyIDs: [],
                                  viewNormal: SIMD3(0, -1, 0),
                                  viewUp: SIMD3(0, 1, 0),
                                  assemblyMode: assemblyMode,
                                  explodedViewID: explodedViewID,
                                  explodedViewName: explodedViewName,
                                  sheetViews: [front, top, side, section])
        return CADDrawingSet(pages: [page], schemaVersion: currentSchemaVersion)
    }

    /// Assembly-aware sheet: front/top/side/iso plus a dedicated exploded
    /// view. All five pages project the SAME placed instances/transforms (and
    /// the named exploded offsets), never raw body transforms. `bodyIDs`
    /// optionally filters the instance source bodies; empty = every visible
    /// instance.
    public static func assemblySheet(bodyIDs: [UUID] = [],
                                     title: String,
                                     explodedViewID: UUID? = nil,
                                     explodedViewName: String? = nil,
                                     scale: Double = 1,
                                     paper: CADPaperSize = .a3) -> CADDrawingSet {
        let views: [(CADDrawingViewKind, SIMD3<Double>)] = [
            (.front, SIMD3(0, -1, 0)),
            (.top, SIMD3(0, 0, 1)),
            (.side, SIMD3(1, 0, 0)),
            (.iso, SIMD3(1, -1, 1)),
            (.exploded, SIMD3(1, -1, 1)),
        ]
        let pages = views.map { kind, normal in
            CADDrawingPage(name: kind.title, kind: kind, scale: scale, paper: paper,
                           title: title, sourceBodyIDs: bodyIDs, viewNormal: normal,
                           assemblyMode: true,
                           explodedViewID: explodedViewID,
                           explodedViewName: explodedViewName,
                           showBOM: true)
        }
        return CADDrawingSet(pages: pages, schemaVersion: currentSchemaVersion)
    }
}
