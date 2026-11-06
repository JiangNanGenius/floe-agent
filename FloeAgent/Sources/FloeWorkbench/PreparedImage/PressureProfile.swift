// SPDX-License-Identifier: MPL-2.0
// Adapted from the qualified Floe per-sample brush contracts.
// FloeBrushCore — pressure mapping and comparison formulas.
//
// The existing Floe Workbench renderer averages all measured pressures in a
// stroke and applies one width to the entire path
// (`FloeAgent/Sources/FloeWorkbench/WorkbenchImageRenderer.swift:427-438` in
// main a74ad4ff). The functions below are the proposed per-sample contract and
// an exact reference copy of the current average behavior for comparison.

import Foundation

public struct MediaPreparedPressureProfile: Codable, Hashable, Sendable {
    /// When false, pressure does not change width at all.
    public var usesPressureForWidth: Bool
    /// When false, pressure does not change opacity at all.
    public var usesPressureForOpacity: Bool
    /// Width multiplier at pressure 0.
    public var minimumWidthRatio: Double
    /// Width multiplier at pressure 1.
    public var maximumWidthRatio: Double
    /// Gamma applied to normalized pressure before width interpolation.
    public var widthExponent: Double
    /// Minimum opacity multiplier at pressure 0.
    public var minimumOpacityRatio: Double
    /// Gamma applied to normalized pressure before opacity interpolation.
    public var opacityExponent: Double
    /// Hard floor in canvas points so a zero-force sample cannot disappear.
    public var minimumResolvedWidth: Double
    /// Width multiplier used for finger/mouse samples (no pressure).
    public var noPressureWidthRatio: Double
    /// Opacity multiplier used for finger/mouse samples (no pressure).
    public var noPressureOpacityRatio: Double

    public init(
        usesPressureForWidth: Bool = true,
        usesPressureForOpacity: Bool = true,
        minimumWidthRatio: Double = 0.15,
        maximumWidthRatio: Double = 1.0,
        widthExponent: Double = 1.0,
        minimumOpacityRatio: Double = 0.05,
        opacityExponent: Double = 1.0,
        minimumResolvedWidth: Double = 0.5,
        noPressureWidthRatio: Double = 1.0,
        noPressureOpacityRatio: Double = 1.0
    ) {
        self.usesPressureForWidth = usesPressureForWidth
        self.usesPressureForOpacity = usesPressureForOpacity
        self.minimumWidthRatio = min(max(minimumWidthRatio, 0), 1)
        self.maximumWidthRatio = min(max(maximumWidthRatio, 0), 4)
        self.widthExponent = max(widthExponent, 0.01)
        self.minimumOpacityRatio = min(max(minimumOpacityRatio, 0), 1)
        self.opacityExponent = max(opacityExponent, 0.01)
        self.minimumResolvedWidth = max(minimumResolvedWidth, 0)
        self.noPressureWidthRatio = max(noPressureWidthRatio, 0)
        self.noPressureOpacityRatio = min(max(noPressureOpacityRatio, 0), 1)
    }

    /// A profile that mirrors PencilKit/expected Pencil behavior: fine
    /// low-pressure lines and full pressure for hard strokes.
    public static let pencilLike = MediaPreparedPressureProfile()

    /// A profile that does not use pressure for width or opacity. Useful when
    /// a brush should be constant-width even if pressure samples exist.
    public static let constant = MediaPreparedPressureProfile(
        usesPressureForWidth: false,
        usesPressureForOpacity: false
    )

    public func clamped() -> MediaPreparedPressureProfile {
        MediaPreparedPressureProfile(
            usesPressureForWidth: usesPressureForWidth,
            usesPressureForOpacity: usesPressureForOpacity,
            minimumWidthRatio: minimumWidthRatio,
            maximumWidthRatio: maximumWidthRatio,
            widthExponent: widthExponent,
            minimumOpacityRatio: minimumOpacityRatio,
            opacityExponent: opacityExponent,
            minimumResolvedWidth: minimumResolvedWidth,
            noPressureWidthRatio: noPressureWidthRatio,
            noPressureOpacityRatio: noPressureOpacityRatio
        )
    }
}

public struct MediaPreparedResolvedSample: Codable, Hashable, Sendable {
    public var point: MediaPreparedBrushPoint
    public var width: Double
    public var opacity: Double
    public var pressure: Double?
    public var source: MediaPreparedPressureSource

    public init(
        point: MediaPreparedBrushPoint,
        width: Double,
        opacity: Double,
        pressure: Double?,
        source: MediaPreparedPressureSource
    ) {
        self.point = point
        self.width = width
        self.opacity = opacity
        self.pressure = pressure
        self.source = source
    }
}

public enum MediaPreparedPressureResolver {
    /// Resolves one sample to width/opacity. No pressure is invented for
    /// `.none`; a simulated value is mapped through the same curve but keeps
    /// its `.simulated` provenance.
    public static func resolve(
        _ sample: MediaPreparedBrushSample,
        baseWidth: Double,
        baseOpacity: Double,
        profile: MediaPreparedPressureProfile
    ) -> MediaPreparedResolvedSample {
        let sample = sample.normalized()
        let safeBaseWidth = max(baseWidth, 0)
        let safeBaseOpacity = min(max(baseOpacity, 0), 1)

        guard let pressure = sample.pressure, sample.pressureSource != .none else {
            return MediaPreparedResolvedSample(
                point: sample.point,
                width: max(profile.minimumResolvedWidth, safeBaseWidth * profile.noPressureWidthRatio),
                opacity: min(max(safeBaseOpacity * profile.noPressureOpacityRatio, 0), 1),
                pressure: nil,
                source: .none
            )
        }

        let p = min(max(pressure, 0), 1)
        let widthRatio: Double
        if profile.usesPressureForWidth {
            let curved = pow(p, profile.widthExponent)
            widthRatio = profile.minimumWidthRatio
                + (profile.maximumWidthRatio - profile.minimumWidthRatio) * curved
        } else {
            widthRatio = profile.maximumWidthRatio
        }
        let opacityRatio: Double
        if profile.usesPressureForOpacity {
            opacityRatio = profile.minimumOpacityRatio
                + (1 - profile.minimumOpacityRatio) * pow(p, profile.opacityExponent)
        } else {
            opacityRatio = 1
        }

        return MediaPreparedResolvedSample(
            point: sample.point,
            width: max(profile.minimumResolvedWidth, safeBaseWidth * widthRatio),
            opacity: min(max(safeBaseOpacity * opacityRatio, 0), 1),
            pressure: p,
            source: sample.pressureSource
        )
    }

    public static func resolve(
        _ samples: [MediaPreparedBrushSample],
        baseWidth: Double,
        baseOpacity: Double,
        profile: MediaPreparedPressureProfile
    ) -> [MediaPreparedResolvedSample] {
        samples.map {
            resolve($0, baseWidth: baseWidth, baseOpacity: baseOpacity, profile: profile)
        }
    }
}

/// Exact reference copy of the current Floe Workbench per-stroke average
/// pressure behavior (main a74ad4ff, WorkbenchImageRenderer.swift).
///
/// Keep this in sync when evaluating a production repair: it is intentionally
/// a small, testable mirror of the code being compared, not an imported
/// production module.
public enum MediaPreparedFloePressureReference {
    public static func averagedPressureScale(_ pressures: [Double?]) -> Double {
        let values = pressures.compactMap { $0 }
        guard !values.isEmpty else { return 1 }
        return max(0.15, min(values.reduce(0, +) / Double(values.count), 1))
    }

    /// Mirrors `let width = max(1, stroke.width * pressureScale)`.
    public static func averagedStrokeWidth(baseWidth: Double, pressures: [Double?]) -> Double {
        max(1, baseWidth * averagedPressureScale(pressures))
    }

    /// The production renderer has no per-point opacity dimension; opacity is
    /// one stroke-level value.
    public static func strokeOpacity(_ opacity: Double?) -> Double {
        max(0.02, min(opacity ?? 1, 1))
    }
}

/// Mirrors MaLiang's force math without importing UIKit/Metal.
///
/// Pinned source: MaLiang 594cd9e7124f270ab6d8f4998987eef0dc83f542.
/// `Brush.makeLine(from:to:)` computes
/// `endForce = from.force * 0.95 + to.force * 0.05` and
/// `forceRate = pow(endForce, forceSensitive)`; `makeLine(from:to:force:)`
/// multiplies `pointSize` by the resulting force. `Pan.init(touch:)` resets a
/// direct (finger) touch with zero force to 1, so the library does not
/// synthesize a time-varying finger pressure series.
public enum MaLiangForceReference {
    public static func interpolatedForce(previous: Double, current: Double) -> Double {
        previous * 0.95 + current * 0.05
    }

    public static func pointSize(base: Double, previousForce: Double, currentForce: Double, forceSensitive: Double) -> Double {
        let force = interpolatedForce(previous: previousForce, current: currentForce)
        return base * pow(max(force, 0), max(forceSensitive, 0))
    }

    /// MaLiang's `Pan` sets a direct-touch zero force to 1. Apple Pencil force
    /// is left as measured (including 0).
    public static func effectiveForce(rawForce: Double, isDirectTouch: Bool) -> Double {
        if isDirectTouch && rawForce == 0 { return 1 }
        return rawForce
    }
}

/// Drawsana has no force/pressure input in its pen tool. Its optional
/// `velocityBasedWidth` maps drag velocity to per-segment width. The adapter
/// must therefore supply widths from a pressure source externally if Drawsana
/// geometry is reused.
public enum DrawsanaWidthReference {
    public static func velocityWidth(base: Double, velocity: Double) -> Double {
        // This is a documentation sentinel, not a reimplementation of the
        // upstream heuristic. The actual heuristic lives in
        // DrawsanaUtilities.modulatedWidth and is only used by the iOS adapter.
        guard velocity.isFinite, velocity > 0 else { return base }
        return base
    }
}
