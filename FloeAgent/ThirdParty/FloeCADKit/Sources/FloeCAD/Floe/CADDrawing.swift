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

/// One independent drawing page. `modelRevision` records which document
/// revision the projected geometry was generated from; a page whose stored
/// revision differs from the live document is explicitly stale rather than
/// silently re-projected.
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
    /// Pinned model revision; nil means generated at the current revision.
    public var modelRevision: UInt64?
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
                modelRevision: UInt64? = nil,
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
        self.modelRevision = modelRevision
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
    public func isStale(comparedTo liveRevision: UInt64?) -> Bool {
        guard let modelRevision, let liveRevision else { return false }
        return modelRevision != liveRevision
    }
}

public nonisolated struct CADDrawingSet: Codable, Sendable, Equatable {
    public var pages: [CADDrawingPage]

    public init(pages: [CADDrawingPage] = []) {
        self.pages = pages
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
