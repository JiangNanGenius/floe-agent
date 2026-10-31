//
//  CADDrawingManufacturing.swift
//  FloeCADKit
//
//  Persisted manufacturing-annotation semantics shared by the drawing model,
//  the service, the native editor and the PDF/SVG/DXF exporters.
//
//  Design rules enforced here (and by CADDrawingService):
//  * Structured data, never free text pretending to be a frame. A datum,
//    feature-control frame, surface finish, weld or hole callout has typed
//    fields with bounded values; an arbitrary string cannot stand in for a
//    tolerance or a GD&T symbol.
//  * A dimension tolerance is a real interval: symmetric, explicit deviations,
//    absolute limits or a computed ISO 286 hole-basis fit. The computed limits
//    are exposed to the caller and drawn next to the nominal value.
//  * A thread/counterbore callout is BOUND to the live mechanical-hole feature
//    that owns it. A counterbore's diameter/depth and a thread's pilot relation
//    are re-read from the current feature on every projection; a missing or
//    changed source becomes visibly stale/dangling instead of keeping an old
//    value. A thread callout is a drafting annotation only: it never claims a
//    geometric helical thread (M13 owns that separate capability).
//  * Symbols are vector linework (not raster and not a font gamble) so the
//    native preview and the PDF/SVG/DXF exporters carry the same mark. Text is
//    limited to Latin-1-safe characters (Ø, ±, °, ×) that the existing
//    Helvetica/CoreText and UTF-8 DXF paths already handle.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation
import simd

// MARK: - Kinds and structured payloads

public nonisolated enum CADDrawingManufacturingKind: String, Codable, Sendable, CaseIterable {
    case datumFeature
    case featureControlFrame
    case surfaceFinish
    case weld
    case threadCallout
    case counterboreCallout

    public var title: String {
        switch self {
        case .datumFeature: return "Datum feature"
        case .featureControlFrame: return "Feature control frame"
        case .surfaceFinish: return "Surface finish"
        case .weld: return "Weld"
        case .threadCallout: return "Thread callout"
        case .counterboreCallout: return "Counterbore callout"
        }
    }

    /// Callouts that only make sense when they name a live mechanical hole.
    public var requiresHoleSource: Bool {
        self == .threadCallout || self == .counterboreCallout
    }
}

public nonisolated enum CADDrawingGDTSymbol: String, Codable, Sendable, CaseIterable {
    case straightness
    case flatness
    case circularity
    case cylindricity
    case profileLine
    case profileSurface
    case angularity
    case perpendicularity
    case parallelism
    case position
    case concentricity
    case symmetry
    case runout
    case totalRunout

    public var title: String {
        switch self {
        case .straightness: return "Straightness"
        case .flatness: return "Flatness"
        case .circularity: return "Circularity"
        case .cylindricity: return "Cylindricity"
        case .profileLine: return "Profile of a line"
        case .profileSurface: return "Profile of a surface"
        case .angularity: return "Angularity"
        case .perpendicularity: return "Perpendicularity"
        case .parallelism: return "Parallelism"
        case .position: return "Position"
        case .concentricity: return "Concentricity"
        case .symmetry: return "Symmetry"
        case .runout: return "Circular runout"
        case .totalRunout: return "Total runout"
        }
    }

    /// Short drafting label for the native picker. The exported mark is drawn
    /// as vector linework, never by depending on a symbol font.
    public var draftingCode: String {
        switch self {
        case .straightness: return "—"
        case .flatness: return "▱"
        case .circularity: return "○"
        case .cylindricity: return "⌭"
        case .profileLine: return "⌒"
        case .profileSurface: return "⌓"
        case .angularity: return "∠"
        case .perpendicularity: return "⊥"
        case .parallelism: return "∥"
        case .position: return "⌖"
        case .concentricity: return "◎"
        case .symmetry: return "⌯"
        case .runout: return "↗"
        case .totalRunout: return "⇗"
        }
    }
}

public nonisolated enum CADDrawingMaterialCondition: String, Codable, Sendable, CaseIterable {
    case maximumMaterial
    case leastMaterial
    case regardless

    public var title: String {
        switch self {
        case .maximumMaterial: return "Maximum material (M)"
        case .leastMaterial: return "Least material (L)"
        case .regardless: return "Regardless of feature size"
        }
    }

    public var shortCode: String {
        switch self {
        case .maximumMaterial: return "M"
        case .leastMaterial: return "L"
        case .regardless: return "RFS"
        }
    }
}

public nonisolated struct CADDrawingDatumReference: Codable, Sendable, Equatable {
    public var letter: String
    public var modifier: CADDrawingMaterialCondition?

    public init(letter: String, modifier: CADDrawingMaterialCondition? = nil) {
        self.letter = letter
        self.modifier = modifier
    }
}

public nonisolated struct CADDrawingDatumFeature: Codable, Sendable, Equatable {
    /// Single capital A-Z. Rendered in a rectangular datum box.
    public var letter: String
    /// Optional explicit arrow tip in VIEW mm. Nil uses the resolved source
    /// face centre; a free datum (no feature) falls back to the box position.
    public var leaderTarget: SIMD2<Double>?

    public init(letter: String, leaderTarget: SIMD2<Double>? = nil) {
        self.letter = letter
        self.leaderTarget = leaderTarget
    }
}

public nonisolated struct CADDrawingFeatureControlFrame: Codable, Sendable, Equatable {
    public var characteristic: CADDrawingGDTSymbol
    /// Tolerance zone size in model millimetres (or degrees never: GD&T here is
    /// a linear/zone tolerance).
    public var toleranceMM: Double
    /// True draws the diameter-zone symbol in front of the value.
    public var diameterZone: Bool
    public var materialCondition: CADDrawingMaterialCondition?
    /// Up to three datum references, in frame order.
    public var datumReferences: [CADDrawingDatumReference]
    public var leaderTarget: SIMD2<Double>?

    public init(characteristic: CADDrawingGDTSymbol = .position,
                toleranceMM: Double = 0.2,
                diameterZone: Bool = true,
                materialCondition: CADDrawingMaterialCondition? = nil,
                datumReferences: [CADDrawingDatumReference] = [],
                leaderTarget: SIMD2<Double>? = nil) {
        self.characteristic = characteristic
        self.toleranceMM = toleranceMM
        self.diameterZone = diameterZone
        self.materialCondition = materialCondition
        self.datumReferences = datumReferences
        self.leaderTarget = leaderTarget
    }
}

public nonisolated struct CADDrawingSurfaceFinish: Codable, Sendable, Equatable {
    /// Arithmetic average roughness Ra in micrometres (> 0, <= 1000).
    public var raMicrometres: Double
    /// Optional process note drawn with the symbol (<= 40 characters).
    public var machiningMethod: String?
    /// The all-around circle is optional; it is a drafting mark, not geometry.
    public var allAround: Bool

    public init(raMicrometres: Double = 1.6, machiningMethod: String? = nil,
                allAround: Bool = false) {
        self.raMicrometres = raMicrometres
        self.machiningMethod = machiningMethod
        self.allAround = allAround
    }
}

public nonisolated enum CADDrawingWeldType: String, Codable, Sendable, CaseIterable {
    case fillet
    case squareButt
    case vButt
    case bevelButt
    case uButt
    case plug
    case spot
    case seam

    public var title: String {
        switch self {
        case .fillet: return "Fillet"
        case .squareButt: return "Square butt"
        case .vButt: return "V butt"
        case .bevelButt: return "Bevel butt"
        case .uButt: return "U butt"
        case .plug: return "Plug"
        case .spot: return "Spot"
        case .seam: return "Seam"
        }
    }
}

public nonisolated struct CADDrawingWeld: Codable, Sendable, Equatable {
    public var type: CADDrawingWeldType
    /// Leg/throat size in mm (> 0, <= 1000).
    public var sizeMM: Double
    /// Optional weld length in mm.
    public var lengthMM: Double?
    /// Optional pitch (centre-to-centre) in mm.
    public var pitchMM: Double?
    public var allAround: Bool
    public var fieldWeld: Bool
    /// Free tail note (procedure/spec), <= 80 characters.
    public var tailNote: String?
    public var leaderTarget: SIMD2<Double>?

    public init(type: CADDrawingWeldType = .fillet, sizeMM: Double = 6,
                lengthMM: Double? = nil, pitchMM: Double? = nil,
                allAround: Bool = false, fieldWeld: Bool = false,
                tailNote: String? = nil, leaderTarget: SIMD2<Double>? = nil) {
        self.type = type
        self.sizeMM = sizeMM
        self.lengthMM = lengthMM
        self.pitchMM = pitchMM
        self.allAround = allAround
        self.fieldWeld = fieldWeld
        self.tailNote = tailNote
        self.leaderTarget = leaderTarget
    }
}

public nonisolated enum CADDrawingThreadHandedness: String, Codable, Sendable, CaseIterable {
    case rightHand
    case leftHand
}

public nonisolated struct CADDrawingThreadCallout: Codable, Sendable, Equatable {
    /// ISO metric designation without the class or pitch, e.g. "M6". The
    /// parser accepts a full "M6x1.0" form too and stores the resolved pitch
    /// in `pitchMM` so a later standards-catalog change cannot reinterpret it.
    public var designation: String
    public var pitchMM: Double
    /// Internal/external tolerance class such as "6H" or "6g".
    public var threadClass: String
    public var handedness: CADDrawingThreadHandedness
    /// True for a through thread. When false `depthMM` is the thread depth.
    public var through: Bool
    public var depthMM: Double?
    public var leaderTarget: SIMD2<Double>?

    public init(designation: String = "M6", pitchMM: Double = 1.0,
                threadClass: String = "6H",
                handedness: CADDrawingThreadHandedness = .rightHand,
                through: Bool = true, depthMM: Double? = nil,
                leaderTarget: SIMD2<Double>? = nil) {
        self.designation = designation
        self.pitchMM = pitchMM
        self.threadClass = threadClass
        self.handedness = handedness
        self.through = through
        self.depthMM = depthMM
        self.leaderTarget = leaderTarget
    }
}

/// Counterbore callout payload. The dimensions are deliberately absent: they
/// are read from the linked mechanical hole on every projection. Only drafting
/// placement is user-authored.
public nonisolated struct CADDrawingCounterboreCallout: Codable, Sendable, Equatable {
    public var leaderTarget: SIMD2<Double>?

    public init(leaderTarget: SIMD2<Double>? = nil) {
        self.leaderTarget = leaderTarget
    }
}

// MARK: - Tolerances

public nonisolated enum CADDrawingToleranceKind: String, Codable, Sendable, CaseIterable {
    case symmetric
    case deviation
    case limits
    case fit

    public var title: String {
        switch self {
        case .symmetric: return "Symmetric (±)"
        case .deviation: return "Upper/lower deviation"
        case .limits: return "Absolute limits"
        case .fit: return "ISO 286 fit"
        }
    }
}

/// A bounded hole-basis ISO 286 fit. Only the supported letters/grades are
/// accepted; the service computes real IT values and deviations from the
/// published ISO 286 bands in `CADDrawingToleranceRules`.
public nonisolated struct CADDrawingISO286Fit: Codable, Sendable, Equatable {
    /// Hole tolerance grade IT5…IT11. Hole fundamental deviation is H (EI = 0).
    public var holeGrade: Int
    /// Shaft fundamental-deviation letter: h, g, f, e or d.
    public var shaftLetter: String
    /// Shaft tolerance grade IT5…IT11.
    public var shaftGrade: Int

    public init(holeGrade: Int = 7, shaftLetter: String = "h", shaftGrade: Int = 6) {
        self.holeGrade = holeGrade
        self.shaftLetter = shaftLetter
        self.shaftGrade = shaftGrade
    }
}

public nonisolated struct CADDrawingTolerance: Codable, Sendable, Equatable {
    public var kind: CADDrawingToleranceKind
    /// Symmetric deviation (mm or degrees), non-negative.
    public var deviationMM: Double?
    /// Explicit signed deviations (mm or degrees), upper >= lower.
    public var upperDeviationMM: Double?
    public var lowerDeviationMM: Double?
    /// Absolute limits (mm or degrees), upper > lower.
    public var upperLimitMM: Double?
    public var lowerLimitMM: Double?
    public var fit: CADDrawingISO286Fit?

    public init(kind: CADDrawingToleranceKind = .symmetric,
                deviationMM: Double? = nil,
                upperDeviationMM: Double? = nil,
                lowerDeviationMM: Double? = nil,
                upperLimitMM: Double? = nil,
                lowerLimitMM: Double? = nil,
                fit: CADDrawingISO286Fit? = nil) {
        self.kind = kind
        self.deviationMM = deviationMM
        self.upperDeviationMM = upperDeviationMM
        self.lowerDeviationMM = lowerDeviationMM
        self.upperLimitMM = upperLimitMM
        self.lowerLimitMM = lowerLimitMM
        self.fit = fit
    }

    private enum CodingKeys: String, CodingKey {
        case kind, deviationMM, upperDeviationMM, lowerDeviationMM
        case upperLimitMM, lowerLimitMM, fit
    }
}

/// Resolved, render-ready tolerance information. `lines` are additional text
/// lines drawn under the nominal value; `primarySuffix` is appended to the
/// nominal text on the same line (for example "±0.05" or "H7/h6").
public nonisolated struct CADDrawingToleranceDisplay: Codable, Sendable, Equatable {
    public var primarySuffix: String?
    public var lines: [String]
    public var designation: String?
    public var upperLimitMM: Double?
    public var lowerLimitMM: Double?
    public var upperDeviationMM: Double?
    public var lowerDeviationMM: Double?
    public var minClearanceMM: Double?
    public var maxClearanceMM: Double?
    public var consistentWithNominal: Bool

    public init(primarySuffix: String? = nil, lines: [String] = [],
                designation: String? = nil,
                upperLimitMM: Double? = nil, lowerLimitMM: Double? = nil,
                upperDeviationMM: Double? = nil, lowerDeviationMM: Double? = nil,
                minClearanceMM: Double? = nil, maxClearanceMM: Double? = nil,
                consistentWithNominal: Bool = true) {
        self.primarySuffix = primarySuffix
        self.lines = lines
        self.designation = designation
        self.upperLimitMM = upperLimitMM
        self.lowerLimitMM = lowerLimitMM
        self.upperDeviationMM = upperDeviationMM
        self.lowerDeviationMM = lowerDeviationMM
        self.minClearanceMM = minClearanceMM
        self.maxClearanceMM = maxClearanceMM
        self.consistentWithNominal = consistentWithNominal
    }
}

// MARK: - Annotation

/// One manufacturing annotation. Exactly one payload matching `kind` is
/// required; the others must be nil. This keeps the persisted record typed
/// instead of a free-form dictionary, and lets the format gate distinguish a
/// known record from an unknown future one.
public nonisolated struct CADDrawingManufacturingAnnotation: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: CADDrawingManufacturingKind
    /// Shared-sheet view for the anchor/leader coordinates. Nil on legacy
    /// single-view pages.
    public var viewID: UUID?
    /// Annotation box/callout anchor in VIEW mm.
    public var position: SIMD2<Double>
    public var heightMM: Double
    /// The live kernel face that makes this annotation associative. Datum,
    /// FCF, surface and weld marks may be free; thread/counterbore callouts
    /// require it.
    public var feature: CADDrawingFeatureReference?
    public var datum: CADDrawingDatumFeature?
    public var featureControlFrame: CADDrawingFeatureControlFrame?
    public var surfaceFinish: CADDrawingSurfaceFinish?
    public var weld: CADDrawingWeld?
    public var thread: CADDrawingThreadCallout?
    public var counterbore: CADDrawingCounterboreCallout?

    public init(id: UUID = UUID(), kind: CADDrawingManufacturingKind,
                viewID: UUID? = nil, position: SIMD2<Double>,
                heightMM: Double = 3.0,
                feature: CADDrawingFeatureReference? = nil,
                datum: CADDrawingDatumFeature? = nil,
                featureControlFrame: CADDrawingFeatureControlFrame? = nil,
                surfaceFinish: CADDrawingSurfaceFinish? = nil,
                weld: CADDrawingWeld? = nil,
                thread: CADDrawingThreadCallout? = nil,
                counterbore: CADDrawingCounterboreCallout? = nil) {
        self.id = id
        self.kind = kind
        self.viewID = viewID
        self.position = position
        self.heightMM = heightMM
        self.feature = feature
        self.datum = datum
        self.featureControlFrame = featureControlFrame
        self.surfaceFinish = surfaceFinish
        self.weld = weld
        self.thread = thread
        self.counterbore = counterbore
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, viewID, position, heightMM, feature
        case datum, featureControlFrame, surfaceFinish, weld, thread, counterbore
    }

    /// The payload matching `kind`, when present.
    public var hasMatchingPayload: Bool {
        switch kind {
        case .datumFeature: return datum != nil
        case .featureControlFrame: return featureControlFrame != nil
        case .surfaceFinish: return surfaceFinish != nil
        case .weld: return weld != nil
        case .threadCallout: return thread != nil
        case .counterboreCallout: return counterbore != nil
        }
    }

    /// True only when the matching payload is present and every non-matching
    /// payload is absent. Used by creation/update and the format gate.
    public var payloadIsExclusive: Bool {
        let payloads: [Bool] = [datum != nil, featureControlFrame != nil,
                                surfaceFinish != nil, weld != nil,
                                thread != nil, counterbore != nil]
        guard payloads.filter({ $0 }).count == 1 else { return false }
        return hasMatchingPayload
    }
}

// MARK: - Validation / formatting rules

public nonisolated enum CADDrawingManufacturingRules {

    // MARK: Basic bounded strings

    public static func trimmed(_ value: String, maxLength: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLength else { return nil }
        return trimmed
    }

    public static func datumLetter(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.count == 1,
              let scalar = trimmed.unicodeScalars.first,
              scalar.value >= 65, scalar.value <= 90 else { return nil }
        return trimmed
    }

    public static func threadClass(_ raw: String) -> String? {
        let pattern = "^[0-9]{1,2}[HGgh]$"
        guard raw.range(of: pattern, options: .regularExpression) != nil else { return nil }
        return raw
    }

    // MARK: Metric thread standards

    /// ISO 261 coarse pitch (mm) for common metric nominal diameters. This is
    /// a bounded drafting catalog, not a thread-geometry implementation.
    public static func coarseMetricPitch(nominalMM: Double) -> Double? {
        let table: [(Double, Double)] = [
            (1, 0.25), (1.2, 0.25), (1.4, 0.3), (1.6, 0.35), (1.8, 0.35),
            (2, 0.4), (2.5, 0.45), (3, 0.5), (3.5, 0.6), (4, 0.7),
            (5, 0.8), (6, 1.0), (7, 1.0), (8, 1.25), (10, 1.5),
            (12, 1.75), (14, 2.0), (16, 2.0), (18, 2.5), (20, 2.5),
            (22, 2.5), (24, 3.0), (27, 3.0), (30, 3.5), (33, 3.5),
            (36, 4.0), (39, 4.0), (42, 4.5), (45, 4.5), (48, 5.0),
            (52, 5.0), (56, 5.5), (60, 5.5), (64, 6.0),
        ]
        return table.first { abs($0.0 - nominalMM) < 1e-9 }?.1
    }

    /// Parse an ISO metric designation. Accepts "M6", "M6x1.0" and the
    /// multiplication-sign spelling. Rejects arbitrary text and non-metric
    /// designations; the caller must still compare the result to the linked
    /// hole before persisting.
    public static func parseThreadDesignation(_ raw: String)
        -> (nominalMM: Double, pitchMM: Double?, canonical: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "X", with: "x")
        let pattern = "^[Mm]([0-9]+(?:\\.[0-9]+)?)(?:x([0-9]+(?:\\.[0-9]+)?))?$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: trimmed,
                                           range: NSRange(trimmed.startIndex..., in: trimmed)),
              match.numberOfRanges >= 2,
              let nominalRange = Range(match.range(at: 1), in: trimmed),
              let nominal = Double(trimmed[nominalRange]),
              nominal > 0 else { return nil }
        var pitch: Double?
        if match.numberOfRanges >= 3, match.range(at: 2).location != NSNotFound,
           let pitchRange = Range(match.range(at: 2), in: trimmed),
           let value = Double(trimmed[pitchRange]) {
            pitch = value
        }
        let canonical = "M" + trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)...]
        return (nominal, pitch, canonical)
    }

    /// Structural validation only: designation, pitch, class, through/depth.
    /// This runs at creation/update and again on persisted JSON, so an
    /// arbitrary string can never masquerade as a metric thread callout.
    public static func validateThreadStructure(_ thread: CADDrawingThreadCallout) -> [String] {
        var issues: [String] = []
        guard let parsed = parseThreadDesignation(thread.designation) else {
            return ["thread.designation must be an ISO metric designation such as M6 or M6x1.0."]
        }
        let nominal = parsed.nominalMM
        let pitch = thread.pitchMM
        guard pitch.isFinite, pitch > 0, pitch <= 6 else {
            return ["thread.pitchMM must be a positive finite millimetre value."]
        }
        if let coarse = coarseMetricPitch(nominalMM: nominal) {
            if abs(pitch - coarse) > 1e-6 {
                let fineTable: [Double] = [0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5, 0.6,
                                          0.7, 0.75, 0.8, 1.0, 1.25, 1.5, 1.75, 2.0]
                if !fineTable.contains(where: { abs($0 - pitch) < 1e-6 }) {
                    issues.append("thread.pitchMM is not a supported metric pitch.")
                }
            }
        }
        guard threadClass(thread.threadClass) != nil else {
            issues.append("thread.threadClass must look like 6H, 6g, 4H or 6G.")
            return issues
        }
        if thread.through {
            if thread.depthMM != nil {
                issues.append("A through thread must not carry depthMM.")
            }
        } else {
            guard let depth = thread.depthMM, depth.isFinite, depth > 0, depth <= 1000 else {
                issues.append("A blind thread needs a positive depthMM (<= 1000).")
                return issues
            }
        }
        return issues
    }

    /// Validate a thread callout against the live hole metadata.
    /// `pilotDiameterMM` is the hole's actual pilot/tap-drill diameter.
    public static func validateThread(_ thread: CADDrawingThreadCallout,
                                      kind: CADDrawingDimensionKind?,
                                      value: Double?,
                                      pilotDiameterMM: Double?,
                                      sourceThrough: Bool?,
                                      sourceDepthMM: Double?) -> [String] {
        var issues = validateThreadStructure(thread)
        guard let parsed = parseThreadDesignation(thread.designation) else { return issues }
        let nominal = parsed.nominalMM
        let pitch = thread.pitchMM
        if !thread.through, let depth = thread.depthMM,
           let sourceDepth = sourceDepthMM, depth > sourceDepth + 1e-6 {
            issues.append("thread.depthMM exceeds the linked hole depth.")
        }
        if let sourceThrough {
            if thread.through != sourceThrough {
                issues.append(thread.through
                    ? "The linked hole is blind; a through thread callout conflicts with it."
                    : "The linked hole is through; a blind thread callout conflicts with it.")
            }
        }
        guard let pilot = pilotDiameterMM else {
            issues.append("The thread callout needs a linked hole with a measurable pilot diameter.")
            return issues
        }
        let tapDrill = nominal - pitch
        let nominalMatch = abs(pilot - nominal) <= 0.35
        let tapDrillMatch = abs(pilot - tapDrill) <= 0.35
        if !nominalMatch && !tapDrillMatch {
            issues.append("The linked hole diameter \(formatNumber(pilot)) mm does not match "
                          + "\(thread.designation) nominal or tap-drill size.")
        }
        if let kind, kind == .angle {
            issues.append("A thread callout cannot dimension an angle.")
        }
        if let kind, kind == .radius {
            issues.append("A thread callout cannot be a radius dimension.")
        }
        return issues
    }

    public static func threadVerification(thread: CADDrawingThreadCallout,
                                          pilotDiameterMM: Double?)
        -> String? {
        guard let pilot = pilotDiameterMM,
              let parsed = parseThreadDesignation(thread.designation) else { return nil }
        let nominal = parsed.nominalMM
        let tapDrill = nominal - thread.pitchMM
        if abs(pilot - nominal) <= 0.35 { return "linkedHoleNominal" }
        if abs(pilot - tapDrill) <= 0.35 { return "linkedHoleTapDrill" }
        return nil
    }

    // MARK: Tolerance validation

    public static func validateTolerance(_ tolerance: CADDrawingTolerance,
                                         kind: CADDrawingDimensionKind,
                                         nominal: Double) -> [String] {
        var issues: [String] = []
        guard nominal.isFinite, nominal >= 0 else {
            return ["The dimension value is not finite."]
        }
        if tolerance.kind == .fit {
            // ISO 286 is defined for a cylinder (diameter) or the distance
            // between two opposite parallel surfaces (length). A radius value
            // is already half a diameter: feeding it into the diameter bands
            // would silently manufacture a doubled radius, so it is refused
            // rather than approximated.
            switch kind {
            case .diameter, .length:
                break
            case .radius:
                return ["An ISO 286 fit applies to a diameter or a length between parallel "
                        + "surfaces, not a radius value."]
            case .angle:
                return ["An ISO 286 fit applies to a diameter or a length, not an angle."]
            }
            guard let fit = tolerance.fit else {
                return ["A fit tolerance needs a fit object."]
            }
            guard (5...11).contains(fit.holeGrade), (5...11).contains(fit.shaftGrade) else {
                issues.append("ISO 286 grades must be between IT5 and IT11.")
                return issues
            }
            guard ["h", "g", "f", "e", "d"].contains(fit.shaftLetter.lowercased()) else {
                issues.append("Only hole-basis H with shaft h/g/f/e/d is supported.")
                return issues
            }
            guard nominal > 0, nominal <= 500 else {
                issues.append("ISO 286 limits are implemented for nominal sizes (0, 500] mm.")
                return issues
            }
            if iso286Limits(fit: fit, nominalMM: nominal) == nil {
                issues.append("The ISO 286 band could not be computed for this size.")
            }
            return issues
        }
        switch tolerance.kind {
        case .symmetric:
            guard let deviation = tolerance.deviationMM,
                  deviation.isFinite, deviation >= 0, deviation <= 10 else {
                issues.append("symmetric tolerance needs deviationMM in [0, 10].")
                return issues
            }
        case .deviation:
            guard let upper = tolerance.upperDeviationMM,
                  let lower = tolerance.lowerDeviationMM,
                  upper.isFinite, lower.isFinite, upper >= lower,
                  abs(upper) <= 10, abs(lower) <= 10 else {
                issues.append("deviation tolerance needs finite upper/lower values in ±10 "
                              + "with upper >= lower.")
                return issues
            }
        case .limits:
            guard let upper = tolerance.upperLimitMM,
                  let lower = tolerance.lowerLimitMM,
                  upper.isFinite, lower.isFinite, upper > lower,
                  lower >= 0, upper <= 1_000_000 else {
                issues.append("limits tolerance needs finite absolute limits with upper > lower.")
                return issues
            }
            // Absolute limits are a real interval, not a band centred on the
            // basic size. A valid pair may sit entirely above or below the
            // nominal (for example 40.20/40.10 around a 40 basic size), so the
            // nominal is deliberately NOT required to lie inside. The signed
            // deviations are exposed from the limits and the nominal instead
            // of turning a legitimate one-sided band into a warning.
        case .fit:
            break
        }
        return issues
    }

    // MARK: ISO 286

    /// IT grade values in micrometres for the standard nominal-size bands.
    /// Source: ISO 286-1/-2 published grade table (IT5…IT11).
    private static let itBands: [(upper: Double, values: [Int])] = [
        (3, [4, 6, 10, 14, 25, 40, 60]),
        (6, [5, 8, 12, 18, 30, 48, 75]),
        (10, [6, 9, 15, 22, 36, 58, 90]),
        (18, [8, 11, 18, 27, 43, 70, 110]),
        (30, [9, 13, 21, 33, 52, 84, 130]),
        (50, [11, 16, 25, 39, 62, 100, 160]),
        (80, [13, 19, 30, 46, 74, 120, 190]),
        (120, [15, 22, 35, 54, 87, 140, 220]),
        (180, [18, 25, 40, 63, 100, 160, 250]),
        (250, [20, 29, 46, 72, 115, 185, 290]),
        (315, [23, 32, 52, 81, 130, 210, 320]),
        (400, [25, 36, 57, 89, 140, 230, 360]),
        (500, [27, 40, 63, 97, 155, 250, 400]),
    ]

    /// Fundamental deviations (micrometres) for shaft letters d/e/f/g/h.
    private static let shaftDeviationBands: [(upper: Double, values: [Int])] = [
        (3, [-20, -14, -6, -2, 0]),
        (6, [-30, -20, -10, -4, 0]),
        (10, [-40, -25, -13, -5, 0]),
        (18, [-50, -32, -16, -6, 0]),
        (30, [-65, -40, -20, -7, 0]),
        (50, [-80, -50, -25, -9, 0]),
        (80, [-100, -60, -30, -10, 0]),
        (120, [-120, -72, -36, -12, 0]),
        (180, [-145, -85, -43, -14, 0]),
        (250, [-170, -100, -50, -15, 0]),
        (315, [-190, -110, -56, -17, 0]),
        (400, [-210, -125, -62, -18, 0]),
        (500, [-230, -135, -68, -20, 0]),
    ]

    public static func iso286IT(grade: Int, nominalMM: Double) -> Double? {
        guard (5...11).contains(grade),
              nominalMM > 0, nominalMM <= 500,
              let band = itBands.first(where: { nominalMM <= $0.upper }) else { return nil }
        return Double(band.values[grade - 5]) / 1000
    }

    public static func shaftFundamentalDeviation(letter: String,
                                                 nominalMM: Double) -> Double? {
        let normalized = letter.lowercased()
        guard let index = ["d", "e", "f", "g", "h"].firstIndex(of: normalized),
              nominalMM > 0, nominalMM <= 500,
              let band = shaftDeviationBands.first(where: { nominalMM <= $0.upper }) else {
            return nil
        }
        return Double(band.values[index]) / 1000
    }

    public static func iso286Limits(fit: CADDrawingISO286Fit, nominalMM: Double)
        -> (holeLower: Double, holeUpper: Double,
            shaftLower: Double, shaftUpper: Double,
            minClearance: Double, maxClearance: Double)? {
        guard nominalMM > 0, nominalMM <= 500,
              (5...11).contains(fit.holeGrade),
              (5...11).contains(fit.shaftGrade),
              let holeIT = iso286IT(grade: fit.holeGrade, nominalMM: nominalMM),
              let shaftIT = iso286IT(grade: fit.shaftGrade, nominalMM: nominalMM),
              let shaftES = shaftFundamentalDeviation(letter: fit.shaftLetter,
                                                      nominalMM: nominalMM) else { return nil }
        let holeLower = nominalMM
        let holeUpper = nominalMM + holeIT
        let shaftUpper = nominalMM + shaftES
        let shaftLower = shaftUpper - shaftIT
        return (holeLower, holeUpper, shaftLower, shaftUpper,
                holeLower - shaftUpper, holeUpper - shaftLower)
    }

    // MARK: Display

    public static func formatNumber(_ value: Double, precision: Int? = nil) -> String {
        guard value.isFinite, abs(value) < 1e12 else { return "—" }
        let digits = max(0, min(6, precision ?? 4))
        if precision == nil {
            let rounded = (value * 10_000).rounded() / 10_000
            if abs(rounded - rounded.rounded()) < 1e-9 {
                return String(Int(rounded.rounded()))
            }
            var text = String(format: "%.4f", rounded)
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
            return text
        }
        return String(format: "%.\(digits)f", value)
    }

    public static func displayValue(_ millimetres: Double, unit: CADDrawingUnit) -> Double {
        millimetres / unit.millimetresPerUnit
    }

    /// Decimal places that print `value` without losing its meaningful digits,
    /// with the page precision as a floor. The value must already be in the
    /// display unit (millimetres, inches or micrometres). Tolerance, fit-limit
    /// and roughness text use this rule so a valid 0.001 never prints as 0.00
    /// and a 40.025 mm limit never rounds to 40.03 at "2 dp". Six places is the
    /// normal `formatNumber` bound; only the explicit round-trip fallback in
    /// `formatMeaningful` can produce a longer spelling.
    private static func meaningfulDecimals(for value: Double, minimum: Int) -> Int {
        let floor = max(0, min(6, minimum))
        guard value.isFinite else { return floor }
        let magnitude = abs(value)
        let epsilon = max(1e-9, magnitude * 1e-9)
        for digits in floor...6 {
            let scale = pow(10.0, Double(digits))
            let rounded = (value * scale).rounded() / scale
            if abs(rounded - value) <= epsilon {
                return digits
            }
        }
        return 6
    }

    /// Format a value already expressed in display units using the page
    /// precision as a floor plus any extra places the value genuinely needs.
    static func formatMeaningful(_ value: Double, minimum: Int) -> String {
        // `-0.0` is a zero deviation, not a negative one.
        let clean = value == 0 ? 0 : value
        let digits = meaningfulDecimals(for: clean, minimum: minimum)
        guard clean.isFinite, abs(clean) < 1e12 else {
            return formatNumber(clean, precision: digits)
        }
        let scale = pow(10.0, Double(digits))
        let rounded = (clean * scale).rounded() / scale
        if clean != 0 && rounded == 0 {
            // The bounded six-place spelling would erase a real nonzero value.
            // Fall back to Swift's shortest round-trip representation, which
            // uses a scientific exponent for sub-microscopic values and is
            // bounded by the 17 significant digits of a Double.
            return roundTripText(clean)
        }
        return formatNumber(clean, precision: digits)
    }

    /// Shortest round-trip spelling that uniquely identifies this Double. Used
    /// only as a bounded fallback for underflow/collapsed intervals, never for
    /// ordinary page-precision text.
    private static func roundTripText(_ value: Double) -> String {
        let clean = value == 0 ? 0 : value
        return String(clean)
    }

    /// Format interval endpoints with the normal page-precision spelling, but
    /// if two distinct values would produce the same text, use the round-trip
    /// spelling for both so a real interval never appears to be zero-width.
    private static func distinctTexts(_ values: [Double], minimum: Int) -> [String] {
        let texts = values.map { formatMeaningful($0, minimum: minimum) }
        guard Set(values).count == values.count,
              Set(texts).count < texts.count else { return texts }
        return values.map { roundTripText($0) }
    }

    /// Feature-control-frame zone text exactly as the resolved rows and the
    /// PDF/SVG/DXF exporters use it. The historical GD&T spelling keeps at
    /// least two decimal places; a real 0.001 zone keeps its third place.
    static func featureControlToleranceText(_ toleranceMM: Double,
                                            diameterZone: Bool,
                                            pagePrecision: Int?) -> String {
        let floor = max(2, min(4, pagePrecision ?? 2))
        return (diameterZone ? "Ø" : "")
            + formatMeaningful(toleranceMM, minimum: floor)
    }

    /// Surface-finish Ra text in micrometres. Page precision is a floor, so a
    /// nonzero 0.025 µm never becomes 0.03/0.00 at a coarse page setting.
    static func surfaceFinishRaText(_ raMicrometres: Double,
                                    pagePrecision: Int?) -> String {
        "Ra " + formatMeaningful(raMicrometres, minimum: pagePrecision ?? 0)
    }

    public static func formatTolerance(_ tolerance: CADDrawingTolerance,
                                       nominalMM: Double,
                                       kind: CADDrawingDimensionKind,
                                       unit: CADDrawingUnit,
                                       precision: Int?) -> CADDrawingToleranceDisplay? {
        guard validateTolerance(tolerance, kind: kind, nominal: nominalMM).isEmpty else {
            return nil
        }
        let minimumDigits = max(0, min(6, precision ?? 3))
        func converted(_ value: Double) -> Double {
            kind == .angle ? value : displayValue(value, unit: unit)
        }
        func toleranceText(_ value: Double) -> String {
            // Page precision is a floor, not a ceiling: a tolerance of
            // 40.025 mm at "2 dp" must still print 40.025, and a 0.001
            // deviation must never become 0.00. The nominal dimension text
            // keeps the page precision.
            formatMeaningful(converted(value), minimum: minimumDigits)
        }
        switch tolerance.kind {
        case .symmetric:
            guard let deviation = tolerance.deviationMM else { return nil }
            let text = "±" + toleranceText(deviation)
            return CADDrawingToleranceDisplay(primarySuffix: text,
                                              upperDeviationMM: deviation,
                                              lowerDeviationMM: -deviation)
        case .deviation:
            guard let upper = tolerance.upperDeviationMM,
                  let lower = tolerance.lowerDeviationMM else { return nil }
            let texts = distinctTexts([converted(upper), converted(lower)],
                                      minimum: minimumDigits)
            func signed(_ text: String) -> String {
                text.hasPrefix("-") ? text : "+" + text
            }
            return CADDrawingToleranceDisplay(
                lines: [signed(texts[0]), signed(texts[1])],
                upperDeviationMM: upper,
                lowerDeviationMM: lower)
        case .limits:
            guard let upper = tolerance.upperLimitMM,
                  let lower = tolerance.lowerLimitMM else { return nil }
            // Both limits are absolute values. Their signed deviations are
            // measured from the basic nominal, which may legitimately sit
            // outside the interval; that is not an inconsistency. The pair
            // formatter keeps two close endpoints textually distinct.
            return CADDrawingToleranceDisplay(
                lines: distinctTexts([converted(upper), converted(lower)],
                                     minimum: minimumDigits),
                upperLimitMM: upper, lowerLimitMM: lower,
                upperDeviationMM: upper - nominalMM,
                lowerDeviationMM: lower - nominalMM,
                consistentWithNominal: true)
        case .fit:
            guard let fit = tolerance.fit,
                  let limits = iso286Limits(fit: fit, nominalMM: nominalMM) else { return nil }
            let designation = "H\(fit.holeGrade)/\(fit.shaftLetter.lowercased())\(fit.shaftGrade)"
            let hole = distinctTexts([converted(limits.holeLower),
                                      converted(limits.holeUpper)],
                                     minimum: minimumDigits)
            let shaft = distinctTexts([converted(limits.shaftLower),
                                       converted(limits.shaftUpper)],
                                      minimum: minimumDigits)
            let holeLine = "HOLE " + hole[0] + "–" + hole[1]
            let shaftLine = "SHAFT " + shaft[0] + "–" + shaft[1]
            return CADDrawingToleranceDisplay(
                primarySuffix: designation,
                lines: [holeLine, shaftLine],
                designation: designation,
                upperLimitMM: limits.holeUpper,
                lowerLimitMM: limits.holeLower,
                upperDeviationMM: limits.holeUpper - nominalMM,
                lowerDeviationMM: limits.holeLower - nominalMM,
                minClearanceMM: limits.minClearance,
                maxClearanceMM: limits.maxClearance,
                consistentWithNominal: true)
        }
    }

    // MARK: Annotation validation

    public static func validate(_ annotation: CADDrawingManufacturingAnnotation)
        -> [String] {
        var issues: [String] = []
        guard annotation.payloadIsExclusive else {
            return ["The manufacturing annotation must carry exactly one payload matching its kind."]
        }
        guard annotation.position.x.isFinite, annotation.position.y.isFinite else {
            return ["The annotation position must be finite."]
        }
        guard annotation.heightMM.isFinite, (0.5...50).contains(annotation.heightMM) else {
            return ["The annotation height must be in [0.5, 50] mm."]
        }
        switch annotation.kind {
        case .datumFeature:
            guard let datum = annotation.datum,
                  datumLetter(datum.letter) != nil else {
                return ["A datum feature needs a single A-Z letter."]
            }
            if let target = datum.leaderTarget,
               !target.x.isFinite || !target.y.isFinite {
                issues.append("The datum leader target must be finite.")
            }
        case .featureControlFrame:
            guard let frame = annotation.featureControlFrame else { return issues }
            guard frame.toleranceMM.isFinite, frame.toleranceMM > 0,
                  frame.toleranceMM <= 1000 else {
                issues.append("The feature-control tolerance must be in (0, 1000] mm.")
                return issues
            }
            guard frame.datumReferences.count <= 3 else {
                issues.append("A feature-control frame supports at most three datum references.")
                return issues
            }
            for reference in frame.datumReferences {
                if datumLetter(reference.letter) == nil {
                    issues.append("Every datum reference needs a single A-Z letter.")
                }
            }
            if let target = frame.leaderTarget,
               !target.x.isFinite || !target.y.isFinite {
                issues.append("The feature-control leader target must be finite.")
            }
        case .surfaceFinish:
            guard let finish = annotation.surfaceFinish else { return issues }
            if !finish.raMicrometres.isFinite || finish.raMicrometres <= 0
                || finish.raMicrometres > 1000 {
                issues.append("Ra must be a positive finite value (<= 1000 µm).")
            }
            if let method = finish.machiningMethod,
               trimmed(method, maxLength: 40) == nil {
                issues.append("The machining method must be 1…40 characters.")
            }
        case .weld:
            guard let weld = annotation.weld else { return issues }
            guard weld.sizeMM.isFinite, weld.sizeMM > 0, weld.sizeMM <= 1000 else {
                issues.append("The weld size must be in (0, 1000] mm.")
                return issues
            }
            if let length = weld.lengthMM {
                guard length.isFinite, length > 0, length <= 100_000 else {
                    issues.append("The weld length must be positive and finite.")
                    return issues
                }
            }
            if let pitch = weld.pitchMM {
                guard pitch.isFinite, pitch > 0, pitch <= 100_000 else {
                    issues.append("The weld pitch must be positive and finite.")
                    return issues
                }
            }
            if let tail = weld.tailNote, trimmed(tail, maxLength: 80) == nil {
                issues.append("The weld tail note must be 1…80 characters.")
            }
            if let target = weld.leaderTarget,
               !target.x.isFinite || !target.y.isFinite {
                issues.append("The weld leader target must be finite.")
            }
        case .threadCallout:
            guard let thread = annotation.thread else { return issues }
            issues.append(contentsOf: validateThreadStructure(thread))
            if annotation.feature == nil {
                issues.append("A thread callout requires a linked mechanical hole.")
            }
        case .counterboreCallout:
            guard annotation.counterbore != nil else { return issues }
            if annotation.feature == nil {
                issues.append("A counterbore callout requires a linked mechanical hole.")
            }
        }
        return issues
    }

    // MARK: Neutral symbol geometry

    public struct SymbolSegment: Sendable, Equatable {
        public var a: SIMD2<Double>
        public var b: SIMD2<Double>
        public init(_ a: SIMD2<Double>, _ b: SIMD2<Double>) {
            self.a = a
            self.b = b
        }
    }

    public struct SymbolCircle: Sendable, Equatable {
        public var center: SIMD2<Double>
        public var radius: Double
        public init(center: SIMD2<Double>, radius: Double) {
            self.center = center
            self.radius = radius
        }
    }

    public struct SymbolPolyline: Sendable, Equatable {
        public var points: [SIMD2<Double>]
        public var closed: Bool
        public init(points: [SIMD2<Double>], closed: Bool = false) {
            self.points = points
            self.closed = closed
        }
    }

    public struct SymbolGeometry: Sendable, Equatable {
        public var segments: [SymbolSegment] = []
        public var circles: [SymbolCircle] = []
        public var polylines: [SymbolPolyline] = []
        public init(segments: [SymbolSegment] = [],
                    circles: [SymbolCircle] = [],
                    polylines: [SymbolPolyline] = []) {
            self.segments = segments
            self.circles = circles
            self.polylines = polylines
        }
    }

    /// Vector mark for each geometric characteristic inside a unit square.
    /// Callers scale/translate it into the first frame cell.
    public static func gdtSymbol(_ symbol: CADDrawingGDTSymbol,
                                 minimum: SIMD2<Double>,
                                 maximum: SIMD2<Double>) -> SymbolGeometry {
        let width = max(maximum.x - minimum.x, 1e-6)
        let height = max(maximum.y - minimum.y, 1e-6)
        func p(_ x: Double, _ y: Double) -> SIMD2<Double> {
            SIMD2(minimum.x + x * width, minimum.y + y * height)
        }
        var geometry = SymbolGeometry()
        func line(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            geometry.segments.append(SymbolSegment(p(x1, y1), p(x2, y2)))
        }
        func circle(_ x: Double, _ y: Double, _ r: Double) {
            geometry.circles.append(SymbolCircle(center: p(x, y), radius: r * min(width, height)))
        }
        switch symbol {
        case .straightness:
            line(0.08, 0.5, 0.92, 0.5)
        case .flatness:
            geometry.polylines.append(SymbolPolyline(
                points: [p(0.28, 0.18), p(0.74, 0.18), p(0.60, 0.82), p(0.14, 0.82)],
                closed: true))
        case .circularity:
            circle(0.5, 0.5, 0.32)
        case .cylindricity:
            circle(0.5, 0.5, 0.30)
            line(0.22, 0.72, 0.32, 0.28)
            line(0.72, 0.72, 0.62, 0.28)
        case .profileLine:
            geometry.polylines.append(SymbolPolyline(
                points: [p(0.12, 0.25), p(0.32, 0.78), p(0.58, 0.22), p(0.82, 0.70)]))
        case .profileSurface:
            geometry.polylines.append(SymbolPolyline(
                points: [p(0.10, 0.30), p(0.30, 0.80), p(0.56, 0.24), p(0.80, 0.72)]))
            line(0.10, 0.12, 0.90, 0.12)
        case .angularity:
            line(0.15, 0.20, 0.85, 0.20)
            line(0.15, 0.20, 0.65, 0.85)
        case .perpendicularity:
            line(0.15, 0.18, 0.85, 0.18)
            line(0.50, 0.18, 0.50, 0.86)
        case .parallelism:
            line(0.20, 0.15, 0.58, 0.85)
            line(0.42, 0.15, 0.80, 0.85)
        case .position:
            circle(0.5, 0.5, 0.30)
            line(0.5, 0.10, 0.5, 0.90)
            line(0.10, 0.5, 0.90, 0.5)
        case .concentricity:
            circle(0.5, 0.5, 0.34)
            circle(0.5, 0.5, 0.16)
        case .symmetry:
            line(0.24, 0.14, 0.24, 0.86)
            line(0.76, 0.14, 0.76, 0.86)
            line(0.50, 0.08, 0.50, 0.92)
        case .runout:
            line(0.12, 0.22, 0.78, 0.78)
            line(0.78, 0.78, 0.58, 0.74)
            line(0.78, 0.78, 0.74, 0.58)
        case .totalRunout:
            line(0.10, 0.20, 0.80, 0.80)
            line(0.80, 0.80, 0.58, 0.76)
            line(0.80, 0.80, 0.76, 0.58)
            line(0.28, 0.08, 0.68, 0.48)
        }
        return geometry
    }

    public static func datumTriangle(tip: SIMD2<Double>,
                                     from direction: SIMD2<Double>,
                                     size: Double) -> SymbolGeometry {
        let length = simd_length(direction)
        let unit = length > 1e-9 ? direction / length : SIMD2(0.0, 1.0)
        let normal = SIMD2(-unit.y, unit.x)
        let baseCenter = tip + unit * size
        var geometry = SymbolGeometry()
        geometry.polylines.append(SymbolPolyline(
            points: [tip, baseCenter + normal * size * 0.55,
                     baseCenter - normal * size * 0.55],
            closed: true))
        return geometry
    }

    public static func surfaceFinishSymbol(origin: SIMD2<Double>,
                                           height: Double) -> SymbolGeometry {
        let h = max(height, 1)
        var geometry = SymbolGeometry()
        geometry.segments.append(SymbolSegment(origin, origin + SIMD2(h * 0.9, h * 1.1)))
        geometry.segments.append(SymbolSegment(origin + SIMD2(h * 0.9, h * 1.1),
                                               origin + SIMD2(h * 3.0, h * 2.4)))
        geometry.segments.append(SymbolSegment(origin + SIMD2(h * 0.4, h * 0.49),
                                               origin + SIMD2(h * 4.2, h * 0.49)))
        return geometry
    }

    public static func weldTriangle(origin: SIMD2<Double>,
                                    height: Double) -> SymbolGeometry {
        let h = max(height, 1)
        var geometry = SymbolGeometry()
        geometry.polylines.append(SymbolPolyline(
            points: [origin, origin + SIMD2(h * 1.4, 0), origin + SIMD2(0, h * 1.5)],
            closed: true))
        return geometry
    }

    /// Section-style counterbore mark: a wide top opening, a shoulder and a
    /// narrower pilot bore. Drawn left of the callout text.
    public static func counterboreSymbol(origin: SIMD2<Double>,
                                         height: Double) -> SymbolGeometry {
        let h = max(height, 1)
        var geometry = SymbolGeometry()
        geometry.segments.append(SymbolSegment(origin + SIMD2(0, h * 1.2),
                                               origin + SIMD2(h * 2.4, h * 1.2)))
        geometry.segments.append(SymbolSegment(origin + SIMD2(0, 0),
                                               origin + SIMD2(h * 2.4, 0)))
        geometry.segments.append(SymbolSegment(origin + SIMD2(0, 0),
                                               origin + SIMD2(0, h * 1.2)))
        geometry.segments.append(SymbolSegment(origin + SIMD2(h * 2.4, 0),
                                               origin + SIMD2(h * 2.4, h * 1.2)))
        geometry.segments.append(SymbolSegment(origin + SIMD2(h * 0.8, h * 1.2),
                                               origin + SIMD2(h * 0.8, h * 0.45)))
        geometry.segments.append(SymbolSegment(origin + SIMD2(h * 1.6, h * 0.45),
                                               origin + SIMD2(h * 1.6, h * 1.2)))
        geometry.segments.append(SymbolSegment(origin + SIMD2(h * 0.8, h * 0.45),
                                               origin + SIMD2(h * 1.6, h * 0.45)))
        return geometry
    }

    /// First-angle / third-angle projection mark: a truncated cone beside its
    /// circular end view. The side the circle appears on is the supported
    /// drafting distinction.
    public static func projectionSymbol(_ method: CADDrawingProjectionMethod,
                                        origin: SIMD2<Double>,
                                        height: Double) -> SymbolGeometry {
        let h = max(height, 1)
        var geometry = SymbolGeometry()
        let coneLeft = method == .firstAngle
        let circleCenter = origin + SIMD2(coneLeft ? h * 5.2 : h * 1.4, h)
        geometry.circles.append(SymbolCircle(center: circleCenter, radius: h * 0.85))
        let coneOrigin = origin + SIMD2(coneLeft ? h * 0.0 : h * 2.8, 0)
        geometry.polylines.append(SymbolPolyline(
            points: [coneOrigin + SIMD2(0, h * 0.15),
                     coneOrigin + SIMD2(h * 2.2, h * 0.55),
                     coneOrigin + SIMD2(h * 2.2, h * 1.45),
                     coneOrigin + SIMD2(0, h * 1.85)],
            closed: true))
        geometry.segments.append(SymbolSegment(coneOrigin + SIMD2(h * 0.9, h * 0.35),
                                               coneOrigin + SIMD2(h * 0.9, h * 1.65)))
        return geometry
    }
}
