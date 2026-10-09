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
    case front, top, side, iso, section, detail

    public var title: String {
        switch self {
        case .front: return "Front"
        case .top: return "Top"
        case .side: return "Side"
        case .iso: return "Isometric"
        case .section: return "Section"
        case .detail: return "Detail"
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

    public var sources: [Source]

    public init(sources: [Source] = []) {
        self.sources = sources
    }

    /// Compare against the live fingerprint. A legacy page without a recorded
    /// fingerprint is stale until it is re-projected.
    public func matches(_ live: CADDrawingSourceFingerprint?) -> Bool {
        guard let live else { return false }
        return self == live
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
                showDimensions: Bool = false) {
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
    /// fingerprint; v2 adds typed detail windows and the fingerprint. A newer
    /// value opens for reading and blocks edits (the service refuses).
    public static let currentSchemaVersion = 2
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
}
