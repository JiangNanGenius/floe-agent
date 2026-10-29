//
//  CADViewAppearance.swift
//  FloeCADKit
//
//  Persisted/presentation appearance shared by the Metal engineering viewport
//  and any future RealityKit presentation. Three environments are stored
//  together (studio/daylight/dark) so switching is deterministic and the whole
//  choice rides in the existing additive `sceneSettings` document column.
//
//  Presentation owns no geometry and no undo stack: it reads the immutable
//  scene snapshot and calls `FloeCADDocument.applyViewAppearance` for changes.
//

import Foundation

nonisolated enum CADViewEnvironmentKind: String, Codable, CaseIterable, Sendable {
    case studio
    case daylight
    case dark
}

nonisolated struct CADViewEnvironmentSettings: Codable, Equatable, Sendable {
    /// Relative key-light intensity; 1 = the neutral viewport default.
    var lightIntensity: Double
    /// World-space key-light direction (right-handed, +Y up), not necessarily
    /// unit length; consumers normalize it.
    var lightDirection: [Double]
    /// Display background in sRGB 0…1.
    var backgroundColor: [Double]

    init(lightIntensity: Double, lightDirection: [Double],
         backgroundColor: [Double]) {
        self.lightIntensity = lightIntensity
        self.lightDirection = lightDirection
        self.backgroundColor = backgroundColor
    }

    var sanitized: CADViewEnvironmentSettings {
        var copy = self
        copy.lightIntensity = min(max(lightIntensity.isFinite ? lightIntensity : 1, 0), 16)
        if copy.lightDirection.count != 3 || !copy.lightDirection.allSatisfy(\.isFinite) {
            copy.lightDirection = [0.35, 0.55, 0.75]
        }
        if copy.backgroundColor.count != 3 || !copy.backgroundColor.allSatisfy(\.isFinite) {
            copy.backgroundColor = [0.12, 0.14, 0.18]
        }
        copy.backgroundColor = copy.backgroundColor.map { min(max($0, 0), 1) }
        return copy
    }
}

nonisolated struct CADViewAppearance: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var activeEnvironment: CADViewEnvironmentKind
    var studio: CADViewEnvironmentSettings
    var daylight: CADViewEnvironmentSettings
    var dark: CADViewEnvironmentSettings
    var floorVisible: Bool
    /// sRGB 0…1.
    var floorColor: [Double]
    /// Physical floor extent in millimetres.
    var floorSizeMM: Double
    var shadowsEnabled: Bool

    init(schemaVersion: Int = CADViewAppearance.currentSchemaVersion,
         activeEnvironment: CADViewEnvironmentKind = .studio,
         studio: CADViewEnvironmentSettings = CADViewAppearance.defaultStudio,
         daylight: CADViewEnvironmentSettings = CADViewAppearance.defaultDaylight,
         dark: CADViewEnvironmentSettings = CADViewAppearance.defaultDark,
         floorVisible: Bool = true,
         floorColor: [Double] = [0.5, 0.5, 0.52],
         floorSizeMM: Double = 2000,
         shadowsEnabled: Bool = true) {
        self.schemaVersion = schemaVersion
        self.activeEnvironment = activeEnvironment
        self.studio = studio
        self.daylight = daylight
        self.dark = dark
        self.floorVisible = floorVisible
        self.floorColor = floorColor
        self.floorSizeMM = floorSizeMM
        self.shadowsEnabled = shadowsEnabled
    }

    static let defaultStudio = CADViewEnvironmentSettings(
        lightIntensity: 1.0,
        lightDirection: [0.35, 0.55, 0.75],
        backgroundColor: [0.12, 0.14, 0.18])
    static let defaultDaylight = CADViewEnvironmentSettings(
        lightIntensity: 1.4,
        lightDirection: [0.3, 0.8, 0.5],
        backgroundColor: [0.62, 0.76, 0.9])
    static let defaultDark = CADViewEnvironmentSettings(
        lightIntensity: 0.6,
        lightDirection: [0.2, 0.3, 0.8],
        backgroundColor: [0.03, 0.035, 0.05])

    static let `default` = CADViewAppearance()

    var sanitized: CADViewAppearance {
        var copy = self
        copy.schemaVersion = Self.currentSchemaVersion
        copy.studio = studio.sanitized
        copy.daylight = daylight.sanitized
        copy.dark = dark.sanitized
        if copy.floorColor.count != 3 || !copy.floorColor.allSatisfy(\.isFinite) {
            copy.floorColor = [0.5, 0.5, 0.52]
        }
        copy.floorColor = copy.floorColor.map { min(max($0, 0), 1) }
        copy.floorSizeMM = min(max(floorSizeMM.isFinite ? floorSizeMM : 2000, 10), 200_000)
        return copy
    }

    static func current(for settings: CADSceneSettings?) -> CADViewAppearance {
        guard let settings else { return .default }
        if let presentation = settings.presentation {
            return presentation.sanitized
        }
        // Historical packages only carry camera/lighting/background. Map the
        // studio environment from those exact values instead of ignoring them.
        var appearance = CADViewAppearance()
        var studio = appearance.studio
        if let lighting = settings.lighting {
            studio.lightIntensity = min(max(lighting.keyIntensityScale, 0), 16)
            studio.lightDirection = [lighting.keyDirectionX,
                                     lighting.keyDirectionY,
                                     lighting.keyDirectionZ]
            appearance.shadowsEnabled = lighting.castsShadows
        }
        if let background = settings.background {
            studio.backgroundColor = [background.topRed, background.topGreen, background.topBlue]
        }
        appearance.studio = studio.sanitized
        return appearance
    }
}
