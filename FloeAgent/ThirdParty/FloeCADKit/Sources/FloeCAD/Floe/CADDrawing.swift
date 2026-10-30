//
//  CADDrawing.swift
//  FloeCADKit
//
//  Drawing-set model for FloeCAD: independent pages with named standard views,
//  explicit scale/paper/title, and model-revision associativity. Geometry
//  generation and export (PDF/SVG/DXF) live in CADDrawingService; this file is
//  the persisted contract, shared by the UI, the AI tool and the file store.
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
    /// Drawing-space reference points captured at creation (page mm), matching
    /// `binding.modelPoints` order.
    public var drawingPoints: [SIMD2<Double>]
    public var value: Double
    public var textPosition: SIMD2<Double>
    public var textOverride: String?
    public var binding: CADDrawingBinding?

    public init(id: UUID = UUID(), kind: CADDrawingDimensionKind,
                drawingPoints: [SIMD2<Double>], value: Double,
                textPosition: SIMD2<Double>, textOverride: String? = nil,
                binding: CADDrawingBinding? = nil) {
        self.id = id
        self.kind = kind
        self.drawingPoints = drawingPoints
        self.value = value
        self.textPosition = textPosition
        self.textOverride = textOverride
        self.binding = binding
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

    public init(id: UUID = UUID(), itemNumber: Int, bomEntryID: UUID? = nil,
                instanceID: UUID? = nil, anchor: SIMD2<Double>,
                target: SIMD2<Double>? = nil, text: String? = nil) {
        self.id = id
        self.itemNumber = itemNumber
        self.bomEntryID = bomEntryID
        self.instanceID = instanceID
        self.anchor = anchor
        self.target = target
        self.text = text
    }
}

public nonisolated struct CADDrawingBOMEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var itemNumber: Int
    public var name: String
    public var partNumber: String
    /// The part definition this item groups (the shared source body, or an
    /// independent copy's own body).
    public var bodyID: UUID
    /// The assembly instances that make up this item. Shared instances of one
    /// body are one row with a quantity; an independent copy is its own row.
    public var instanceIDs: [UUID]
    /// Quantity captured when the BOM was derived; live reports also compute
    /// the current count and flag a difference.
    public var quantity: Int

    public init(id: UUID = UUID(), itemNumber: Int, name: String,
                partNumber: String = "", bodyID: UUID,
                instanceIDs: [UUID] = [], quantity: Int = 1) {
        self.id = id
        self.itemNumber = itemNumber
        self.name = name
        self.partNumber = partNumber
        self.bodyID = bodyID
        self.instanceIDs = instanceIDs
        self.quantity = quantity
    }
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
}

/// Free text placed on the sheet. An optional binding anchors it to live
/// assembly geometry; loose text is a plain manual annotation.
public nonisolated struct CADDrawingTextAnnotation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var text: String
    public var position: SIMD2<Double>
    public var heightMM: Double
    public var binding: CADDrawingBinding?

    public init(id: UUID = UUID(), text: String, position: SIMD2<Double>,
                heightMM: Double = 3.5, binding: CADDrawingBinding? = nil) {
        self.id = id
        self.text = text
        self.position = position
        self.heightMM = heightMM
        self.binding = binding
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
                annotations: [CADDrawingTextAnnotation] = []) {
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
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, scale, paper, title, partNumbers, sourceBodyIDs
        case customWidthMM, customHeightMM
        case viewNormal, viewUp, sectionOrigin, sectionNormal
        case detailOrigin, detailSizeMM, modelRevision, sourceFingerprint
        case showCenterlines, showDimensions
        case assemblyMode, explodedViewID, explodedViewName, showBOM
        case bom, balloons, manualDimensions, annotations
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
        if viewNormal == .zero { viewNormal = SIMD3(0, 0, 1) }
        if viewUp == .zero { viewUp = SIMD3(0, 1, 0) }
    }

    public var paperWidthMM: Double {
        customWidthMM ?? paper.millimetres.width
    }
    public var paperHeightMM: Double {
        customHeightMM ?? paper.millimetres.height
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
    /// annotation. Every v3 page field has a decoding default, so v1/v2 pages
    /// open unchanged. A newer value opens for reading and blocks edits (the
    /// service refuses).
    public static let currentSchemaVersion = 3
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
