//
//  CADPreferences.swift
//  FloeCADKit
//
//  Floe-owned replacement for OpenShape3D's app-shell `AppSettings`
//  (upstream `openshape3d/App/AppSettings.swift`). Only the preference
//  surface the extracted kernel/editor actually reads is implemented; the
//  display-unit and annotation enums are value types copied from the
//  upstream MIT source (see PATCHES.md).
//
//  Document geometry is always stored in millimetres. Display units convert
//  at the view/tool layer only, so changing the unit never rewrites geometry.
//

import Foundation
import Observation
import SwiftUI

// MARK: - Display units (upstream `DisplayUnit`)

nonisolated enum DisplayUnit: String, CaseIterable, Codable, Sendable {
    case millimeters = "mm"
    case centimeters = "cm"
    case meters = "m"
    case inches = "in"
    case feet = "ft"

    var symbol: String { rawValue }

    /// Multiply a millimetre value by this to get the display value.
    var factorFromMM: Double {
        switch self {
        case .millimeters: return 1
        case .centimeters: return 0.1
        case .meters: return 0.001
        case .inches: return 1 / 25.4
        case .feet: return 1 / 304.8
        }
    }

    /// Sensible decimals for a length readout in this unit.
    var lengthDecimals: Int {
        switch self {
        case .millimeters, .centimeters: return 2
        case .meters, .inches, .feet: return 3
        }
    }

    func display(fromMM value: Double) -> Double { value * factorFromMM }
    func mm(fromDisplay value: Double) -> Double { value / factorFromMM }

    /// "12.70 mm", "0.500 in" — a length readout.
    func lengthString(fromMM value: Double) -> String {
        String(format: "%.\(lengthDecimals)f %@", display(fromMM: value), symbol)
    }

    /// Compact length for labels/pills: trims trailing zeros ("12.7 mm").
    func compactLengthString(fromMM value: Double) -> String {
        let v = display(fromMM: value)
        let imperial = self == .inches || self == .feet
        let decimals = imperial || self == .millimeters ? 4 : 3
        let text = Self.groupedNumber(v, maxFractionDigits: decimals)
        if self == .inches { return text + "\"" }
        if self == .feet { return text + "'" }
        return "\(text) \(symbol)"
    }

    /// Schoolbook rounding to `maxFractionDigits`, trailing zeros trimmed,
    /// thousands grouped with a comma whatever the locale.
    static func groupedNumber(_ value: Double, maxFractionDigits: Int) -> String {
        let scale = pow(10.0, Double(maxFractionDigits))
        var rounded = (value * scale).rounded() / scale
        if rounded == 0 { rounded = 0 } // never "-0"
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.decimalSeparator = "."
        formatter.maximumFractionDigits = maxFractionDigits
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: rounded)) ?? String(rounded)
    }

    /// "161.29 cm²" — an area readout (factor squared).
    func areaString(fromMM2 value: Double) -> String {
        let f = factorFromMM
        return String(format: "%.\(lengthDecimals)f %@²", value * f * f, symbol)
    }

    /// A view-layer binding that shows and edits a millimetre value in this
    /// unit (get converts out, set converts back).
    func binding(_ mm: Binding<Double>) -> Binding<Double> {
        Binding(
            get: { self.display(fromMM: mm.wrappedValue) },
            set: { mm.wrappedValue = self.mm(fromDisplay: $0) }
        )
    }

    /// "16.387 cm³" — a volume readout (factor cubed).
    func volumeString(fromMM3 value: Double) -> String {
        let f = factorFromMM
        return String(format: "%.\(lengthDecimals)f %@³", value * f * f * f, symbol)
    }
}

nonisolated enum CircularAnnotations: String, CaseIterable, Codable, Sendable {
    case radiusAndDiameter, alwaysRadius
    var title: String {
        self == .alwaysRadius
            ? FloeCADStrings.text("cad.ui.prefs.circularAlwaysRadius", "Always Radius")
            : FloeCADStrings.text("cad.ui.prefs.circularRadiusAndDiameter", "Radius and Diameter")
    }
}

/// Which selected sketch entity stays in place when a new relationship is
/// solved. This is a solve-time preference, not a persisted geometry Lock.
nonisolated enum AnchoredSketchEntity: String, CaseIterable, Codable, Sendable {
    case firstSelected, lastSelected

    var title: String {
        switch self {
        case .firstSelected: FloeCADStrings.text("cad.ui.prefs.anchoredFirstSelected", "First Selected")
        case .lastSelected: FloeCADStrings.text("cad.ui.prefs.anchoredLastSelected", "Last Selected")
        }
    }
}

// MARK: - Preference store

/// Floe-owned preference store. The Floe app supplies the persistence
/// backing (UserDefaults or its own settings store) and reads it back
/// through `values`. Defaults mirror upstream's shipped defaults so a fresh
/// install behaves the same as the reviewed upstream build.
@Observable
final class CADPreferences {
    /// Numeric fields keep the system keyboard available on iPad unless the
    /// host explicitly turns it off.
    static let prefersSystemKeyboard: Bool = true

    /// Process-wide store. The Floe app may replace the backing UserDefaults
    /// suite but keeps this instance so the extracted editor resolves
    /// preferences the same way upstream did.
    static let shared = CADPreferences()

    nonisolated static func launchSampleCount(defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: "floe.cad.antiAliasing")
        return [1, 2, 4].contains(stored) ? stored : 4
    }

    var circularAnnotations: CircularAnnotations {
        didSet { defaults.set(circularAnnotations.rawValue, forKey: Key.circularAnnotations) }
    }
    var unit: DisplayUnit {
        didSet { defaults.set(unit.rawValue, forKey: Key.unit) }
    }
    /// Tool palette on the right for left-handed use (panels stay put).
    var paletteOnRight: Bool {
        didSet { defaults.set(paletteOnRight, forKey: Key.paletteOnRight) }
    }
    var singleKeyAction: SingleKeyAction {
        didSet { defaults.set(singleKeyAction.rawValue, forKey: Key.singleKeyAction) }
    }
    var alwaysShowDimensions: Bool {
        didSet { defaults.set(alwaysShowDimensions, forKey: Key.alwaysShowDimensions) }
    }
    var alwaysShowConstraints: Bool {
        didSet { defaults.set(alwaysShowConstraints, forKey: Key.alwaysShowConstraints) }
    }
    var anchoredSketchEntity: AnchoredSketchEntity {
        didSet { defaults.set(anchoredSketchEntity.rawValue, forKey: Key.anchoredSketchEntity) }
    }
    var snapToGrid: Bool {
        didSet { defaults.set(snapToGrid, forKey: Key.snapToGrid) }
    }
    var snapToSketchGuidelines: Bool {
        didSet { defaults.set(snapToSketchGuidelines, forKey: Key.snapToSketchGuidelines) }
    }
    var snapToSketchGuidepoints: Bool {
        didSet { defaults.set(snapToSketchGuidepoints, forKey: Key.snapToSketchGuidepoints) }
    }
    var snapToFaceGuidepoints: Bool {
        didSet { defaults.set(snapToFaceGuidepoints, forKey: Key.snapToFaceGuidepoints) }
    }
    var showSnapHints: Bool {
        didSet { defaults.set(showSnapHints, forKey: Key.showSnapHints) }
    }

    var snapOptions: SnapOptions {
        SnapOptions(grid: snapToGrid, sketchGuidepoints: snapToSketchGuidepoints,
                    faceGuidepoints: snapToFaceGuidepoints)
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        circularAnnotations = defaults.string(forKey: Key.circularAnnotations)
            .flatMap(CircularAnnotations.init) ?? .radiusAndDiameter
        snapToGrid = defaults.object(forKey: Key.snapToGrid) as? Bool ?? true
        snapToSketchGuidelines = defaults.object(forKey: Key.snapToSketchGuidelines) as? Bool ?? true
        snapToSketchGuidepoints = defaults.object(forKey: Key.snapToSketchGuidepoints) as? Bool ?? true
        snapToFaceGuidepoints = defaults.object(forKey: Key.snapToFaceGuidepoints) as? Bool ?? true
        showSnapHints = defaults.object(forKey: Key.showSnapHints) as? Bool ?? true
        unit = defaults.string(forKey: Key.unit).flatMap(DisplayUnit.init) ?? .millimeters
        paletteOnRight = defaults.bool(forKey: Key.paletteOnRight)
        singleKeyAction = defaults.string(forKey: Key.singleKeyAction)
            .flatMap(SingleKeyAction.init) ?? .hotkeys
        alwaysShowDimensions = defaults.object(forKey: Key.alwaysShowDimensions) as? Bool ?? false
        alwaysShowConstraints = defaults.object(forKey: Key.alwaysShowConstraints) as? Bool ?? false
        anchoredSketchEntity = defaults.string(forKey: Key.anchoredSketchEntity)
            .flatMap(AnchoredSketchEntity.init) ?? .firstSelected
    }

    private enum Key {
        static let unit = "floe.cad.unit"
        static let circularAnnotations = "floe.cad.circularAnnotations"
        static let singleKeyAction = "floe.cad.singleKeyAction"
        static let alwaysShowDimensions = "floe.cad.alwaysShowDimensions"
        static let alwaysShowConstraints = "floe.cad.alwaysShowConstraints"
        static let anchoredSketchEntity = "floe.cad.anchoredSketchEntity"
        static let snapToGrid = "floe.cad.snapToGrid"
        static let snapToSketchGuidelines = "floe.cad.snapToSketchGuidelines"
        static let snapToSketchGuidepoints = "floe.cad.snapToSketchGuidepoints"
        static let snapToFaceGuidepoints = "floe.cad.snapToFaceGuidepoints"
        static let showSnapHints = "floe.cad.showSnapHints"
        static let paletteOnRight = "floe.cad.paletteOnRight"
    }
}

// MARK: - Sendable kernel handles

/// `BRepHandle` wraps an immutable `TopoDS_Shape`: OCCT shapes are frozen
/// after creation, and serialization/measurement only read them. Marking the
/// handle sendable lets changed solids be serialized off the main actor.
extension BRepHandle: @unchecked Sendable {}

// MARK: - Open timing shim

/// Minimal replacement for upstream's DEBUG `OpenTiming` launch instrument.
/// Marks are dropped unless `FLOE_CAD_OPEN_TIMING=1` is set; they never
/// include document content.
nonisolated enum OpenTiming {
    static let isEnabled =
        ProcessInfo.processInfo.environment["FLOE_CAD_OPEN_TIMING"] == "1"

    static func mark(_ label: String) {
        guard isEnabled else { return }
        print("[FloeCAD open] \(label)")
    }
}
