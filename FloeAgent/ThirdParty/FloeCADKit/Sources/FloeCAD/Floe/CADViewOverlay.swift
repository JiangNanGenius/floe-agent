//
//  CADViewOverlay.swift
//  FloeCADKit
//
//  X22 — persisted section/measurement display authority shared by Edit,
//  Present, screenshots and animation export.
//
//  Before this file the section plane lived only in `EditorViewModel` (lost on
//  mode switch/reopen) and the measure tool was a transient pick readout. That
//  made the same document show a cut in an Edit screenshot but the full model
//  in a Present capture or MP4, with no user-visible statement of which view
//  state the file contained. This value is stored in the existing additive
//  `sceneSettings` record (one undoable document command) and is the SINGLE
//  source both renderers read.
//
//  There is no second section engine: the model-space plane below feeds the
//  existing Metal shader clip (`SectionPlaneState`) and the Presentation mesh
//  clip (`CADSectionMeshClip`), both using the same keep-side convention
//  `dot(point - origin, keepNormal) >= 0`.
//
//  Pure value math (Foundation + simd) so a rebuild/round trip can be checked
//  against a reference without a renderer.
//

import Foundation
import simd

// MARK: - Section plane

/// One persisted section plane in model millimetres (+Y up).
///
/// The plane frame (`origin`/`xAxis`/`yAxis`) is stored so the on-screen plane
/// rectangle keeps its authored orientation. The cut itself only uses the
/// plane; `flipped` selects which side stays visible, exactly like the Edit
/// Section flip badge.
public nonisolated struct CADSectionView: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    /// Model-space extent limits for the interactive plane rectangle.
    public static let minimumSizeMM = 1.0
    public static let maximumSizeMM = 1_000_000.0

    public var schemaVersion: Int
    /// False keeps the authored plane but shows the full model (Present
    /// toggle). Removing the section sets the whole optional to nil.
    public var enabled: Bool
    public var origin: [Double]
    public var xAxis: [Double]
    public var yAxis: [Double]
    public var flipped: Bool
    public var sizeMM: Double

    public init(schemaVersion: Int = CADSectionView.currentSchemaVersion,
                enabled: Bool = true,
                origin: SIMD3<Double>,
                xAxis: SIMD3<Double>,
                yAxis: SIMD3<Double>,
                flipped: Bool = false,
                sizeMM: Double = 8) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.origin = [origin.x, origin.y, origin.z]
        self.xAxis = [xAxis.x, xAxis.y, xAxis.z]
        self.yAxis = [yAxis.x, yAxis.y, yAxis.z]
        self.flipped = flipped
        self.sizeMM = sizeMM
    }

    public var originVector: SIMD3<Double> {
        Self.vector(origin) ?? .zero
    }

    public var xAxisVector: SIMD3<Double> {
        Self.vector(xAxis) ?? SIMD3(1, 0, 0)
    }

    public var yAxisVector: SIMD3<Double> {
        Self.vector(yAxis) ?? SIMD3(0, 0, -1)
    }

    /// Plane normal (`cross(xAxis, yAxis)`), normalized. Falls back to +Y for
    /// a degenerate frame so callers never receive NaN.
    public var normal: SIMD3<Double> {
        let cross = simd_cross(xAxisVector, yAxisVector)
        let length = simd_length(cross)
        guard length.isFinite, length > 1e-12 else { return SIMD3(0, 1, 0) }
        return cross / length
    }

    /// The side of the plane that stays visible.
    public var keepNormal: SIMD3<Double> {
        let n = normal
        return flipped ? -n : n
    }

    public var isValid: Bool {
        Self.vector(origin) != nil
            && Self.vector(xAxis) != nil
            && Self.vector(yAxis) != nil
            && simd_length(simd_cross(xAxisVector, yAxisVector)) > 1e-9
            && sizeMM.isFinite
    }

    /// Finite, orthonormal frame with the authored normal preserved. An
    /// invalid input returns nil instead of a silently rotated section.
    public var sanitized: CADSectionView? {
        guard isValid else { return nil }
        let n = normal
        var x = xAxisVector - simd_dot(xAxisVector, n) * n
        if simd_length(x) < 1e-9 {
            let pick: SIMD3<Double> = abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            x = pick - simd_dot(pick, n) * n
        }
        let xLength = simd_length(x)
        guard xLength.isFinite, xLength > 1e-9 else { return nil }
        x /= xLength
        let y = simd_normalize(simd_cross(n, x))
        guard x.x.isFinite, x.y.isFinite, x.z.isFinite,
              y.x.isFinite, y.y.isFinite, y.z.isFinite else { return nil }
        var copy = self
        copy.schemaVersion = CADSectionView.currentSchemaVersion
        copy.origin = [originVector.x, originVector.y, originVector.z]
        copy.xAxis = [x.x, x.y, x.z]
        copy.yAxis = [y.x, y.y, y.z]
        copy.sizeMM = min(max(sizeMM, CADSectionView.minimumSizeMM),
                          CADSectionView.maximumSizeMM)
        return copy
    }

    public var summaryJSON: [String: Any] {
        [
            "enabled": enabled,
            "origin": [originVector.x, originVector.y, originVector.z],
            "normal": [normal.x, normal.y, normal.z],
            "keep_normal": [keepNormal.x, keepNormal.y, keepNormal.z],
            "flipped": flipped,
            "size_mm": sizeMM,
        ]
    }

    private static func vector(_ values: [Double]) -> SIMD3<Double>? {
        guard values.count == 3, values.allSatisfy(\.isFinite) else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }

    // Missing keys decode to defaults so a package written by a build without
    // X22 (or a future additive field) still opens. Synthesized Codable would
    // throw `keyNotFound` for every absent optional/default field.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion, enabled, origin, xAxis, yAxis, flipped, sizeMM
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? CADSectionView.currentSchemaVersion
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        origin = try container.decodeIfPresent([Double].self, forKey: .origin) ?? [0, 0, 0]
        xAxis = try container.decodeIfPresent([Double].self, forKey: .xAxis) ?? [1, 0, 0]
        yAxis = try container.decodeIfPresent([Double].self, forKey: .yAxis) ?? [0, 0, -1]
        flipped = try container.decodeIfPresent(Bool.self, forKey: .flipped) ?? false
        sizeMM = try container.decodeIfPresent(Double.self, forKey: .sizeMM) ?? 8
    }
}

// MARK: - Measurement annotation

/// One saved point-to-point measurement guide in world millimetres.
///
/// The guide is the measured geometry (span line plus end ticks); the numeric
/// value is formatted in the user's display unit from `lengthMM` at the UI
/// boundary, so changing mm/inches never rewrites the document. Points are
/// world-space and intentionally NOT linked to kernel topology: a measurement
/// is an observation the user chose to keep, and it stays where it was taken
/// after an ordinary geometry edit.
public nonisolated struct CADMeasurementAnnotation: Codable, Equatable, Sendable, Identifiable {
    /// Upper bound for one document; beyond this a new annotation is refused
    /// with the exact limit instead of growing the package without limit.
    public static let maximumCount = 128
    static let minimumLengthMM = 1e-6

    public var id: UUID
    public var start: [Double]
    public var end: [Double]
    public var createdAt: Date

    public init(id: UUID = UUID(),
                start: SIMD3<Double>,
                end: SIMD3<Double>,
                createdAt: Date = Date()) {
        self.id = id
        self.start = [start.x, start.y, start.z]
        self.end = [end.x, end.y, end.z]
        self.createdAt = createdAt
    }

    public var startVector: SIMD3<Double> {
        Self.vector(start) ?? .zero
    }

    public var endVector: SIMD3<Double> {
        Self.vector(end) ?? .zero
    }

    public var lengthMM: Double {
        simd_length(endVector - startVector)
    }

    public var isValid: Bool {
        Self.vector(start) != nil && Self.vector(end) != nil
            && lengthMM.isFinite && lengthMM > Self.minimumLengthMM
    }

    public var sanitized: CADMeasurementAnnotation? {
        guard isValid else { return nil }
        var copy = self
        copy.start = [startVector.x, startVector.y, startVector.z]
        copy.end = [endVector.x, endVector.y, endVector.z]
        return copy
    }

    public var summaryJSON: [String: Any] {
        [
            "id": id.uuidString,
            "start": [startVector.x, startVector.y, startVector.z],
            "end": [endVector.x, endVector.y, endVector.z],
            "length_mm": lengthMM,
        ]
    }

    private static func vector(_ values: [Double]) -> SIMD3<Double>? {
        guard values.count == 3, values.allSatisfy(\.isFinite) else { return nil }
        return SIMD3(values[0], values[1], values[2])
    }

    private enum CodingKeys: String, CodingKey {
        case id, start, end, createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        start = try container.decodeIfPresent([Double].self, forKey: .start) ?? [0, 0, 0]
        end = try container.decodeIfPresent([Double].self, forKey: .end) ?? [0, 0, 0]
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

// MARK: - Overlay state

/// Persisted Edit/Present overlay state: the section plane and the saved
/// measurement guides, plus their shared visibility. One value, one document
/// command, one set of pixels.
public nonisolated struct CADViewOverlayState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Authored section plane. `nil` means no section exists; `enabled ==
    /// false` keeps it for a later re-enable without drawing it.
    public var section: CADSectionView?
    public var measurements: [CADMeasurementAnnotation]
    /// When false, saved annotations remain in the document but are neither
    /// drawn nor exported.
    public var showsMeasurements: Bool

    public init(schemaVersion: Int = CADViewOverlayState.currentSchemaVersion,
                section: CADSectionView? = nil,
                measurements: [CADMeasurementAnnotation] = [],
                showsMeasurements: Bool = true) {
        self.schemaVersion = schemaVersion
        self.section = section
        self.measurements = measurements
        self.showsMeasurements = showsMeasurements
    }

    public static let empty = CADViewOverlayState()

    /// The section that actually clips/draws (present + enabled + valid).
    public var activeSection: CADSectionView? {
        guard let section, section.enabled, let clean = section.sanitized else { return nil }
        return clean
    }

    /// Measurement guides that actually draw/export.
    public var visibleMeasurements: [CADMeasurementAnnotation] {
        guard showsMeasurements else { return [] }
        return measurements.compactMap(\.sanitized)
    }

    /// True when either layer produces visible pixels. Used to avoid adding
    /// overlay wording to ordinary screenshots/exports.
    public var hasVisibleContent: Bool {
        activeSection != nil || !visibleMeasurements.isEmpty
    }

    /// True when the document carries view-only content that a model exchange
    /// writer cannot represent (even if temporarily hidden).
    public var hasViewOnlyContent: Bool {
        section != nil || !measurements.isEmpty
    }

    public var isEmpty: Bool {
        section == nil && measurements.isEmpty
    }

    /// Deduplicated, bounded, finite. Invalid entries are dropped (the package
    /// stays openable) rather than repaired into a different measurement.
    public var sanitized: CADViewOverlayState {
        var seen = Set<UUID>()
        var clean: [CADMeasurementAnnotation] = []
        for annotation in measurements {
            guard clean.count < CADMeasurementAnnotation.maximumCount,
                  let value = annotation.sanitized,
                  seen.insert(value.id).inserted else { continue }
            clean.append(value)
        }
        var copy = self
        copy.schemaVersion = CADViewOverlayState.currentSchemaVersion
        copy.section = section?.sanitized
        copy.measurements = clean
        return copy
    }

    public var summaryJSON: [String: Any] {
        var value: [String: Any] = [
            "section_authored": section != nil,
            "measurements_visible": showsMeasurements,
            "measurement_count": measurements.count,
            "measurements": visibleMeasurements.map(\.summaryJSON),
        ]
        value["section"] = activeSection?.summaryJSON ?? NSNull()
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, section, measurements, showsMeasurements
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            ?? CADViewOverlayState.currentSchemaVersion
        section = try container.decodeIfPresent(CADSectionView.self, forKey: .section)
        measurements = try container.decodeIfPresent([CADMeasurementAnnotation].self,
                                                     forKey: .measurements) ?? []
        showsMeasurements = try container.decodeIfPresent(Bool.self, forKey: .showsMeasurements)
            ?? true
    }
}

// MARK: - Output contract

/// Exactly which native outputs carry the two view-only layers. A screenshot,
/// MP4 and PNG frame sequence render the real stage, so they carry both. Model
/// exchange writers write geometry only and never claim otherwise.
public nonisolated enum CADViewOverlayOutput: String, CaseIterable, Sendable {
    case screenshot
    case video
    case pngSequence
    case step
    case iges
    case glb
    case usdz
    case obj
    case stl
    case threeMF

    public var carriesSectionCut: Bool {
        switch self {
        case .screenshot, .video, .pngSequence: return true
        case .step, .iges, .glb, .usdz, .obj, .stl, .threeMF: return false
        }
    }

    public var carriesMeasurementGuides: Bool {
        carriesSectionCut
    }

    public var isModelExchange: Bool {
        !carriesSectionCut
    }

    /// Receipt wording for a model exchange when the document actually has
    /// view-only content. Nil for image/video outputs (whose pixels already
    /// contain it) and for an ordinary model with no overlays.
    public static func viewOnlyNotice(for output: CADViewOverlayOutput,
                                      overlay: CADViewOverlayState) -> String? {
        guard output.isModelExchange, overlay.hasViewOnlyContent else { return nil }
        var layers: [String] = []
        if overlay.section != nil { layers.append("the section cut") }
        if !overlay.measurements.isEmpty { layers.append("measurement guides") }
        let joined = layers.joined(separator: " and ")
        return "\(output.displayName) stores model geometry only; "
            + "\(joined) are view-only and are not included."
    }

    /// Accurate pre-write statement for screenshot/video paths when saved
    /// guides are visible: their LINES are real pixels/stage geometry, but the
    /// numeric value is not baked as text. Nil for a document with no visible
    /// guide, so an ordinary capture gets no gratuitous warning.
    public static func numericTextNotice(for output: CADViewOverlayOutput,
                                          overlay: CADViewOverlayState) -> String? {
        guard output.carriesMeasurementGuides,
              !overlay.visibleMeasurements.isEmpty else { return nil }
        return "\(output.displayName) includes the measurement guide lines, but "
            + "measurement values are not drawn as text into the pixels; they "
            + "remain in the overlay list/receipt."
    }

    public var displayName: String {
        switch self {
        case .screenshot: return "Screenshot"
        case .video: return "Video"
        case .pngSequence: return "PNG frame sequence"
        case .step: return "STEP"
        case .iges: return "IGES"
        case .glb: return "GLB"
        case .usdz: return "USDZ"
        case .obj: return "OBJ"
        case .stl: return "STL"
        case .threeMF: return "3MF"
        }
    }
}
