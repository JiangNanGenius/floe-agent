// SPDX-License-Identifier: MPL-2.0
// Adapted from the qualified Floe per-sample brush contracts.
// FloeBrushCore — platform-independent pressure and stroke samples.
//
// Qualification-only code. This module deliberately depends only on
// Foundation/CoreGraphics so its contract tests run on macOS without booting a
// simulator. The iOS adapter and host add UIKit/Metal/Drawsana behavior.

import Foundation

/// Where a pressure value came from. This is persisted with the sample so a
/// synthesized value can never be reported later as measured Apple Pencil
/// force.
///
/// The existing Floe Workbench model (`ImageFreehandStroke.Point`) stores only
/// `pressure: Double?` and loses provenance; that is a candidate migration
/// point, not something this package changes in production.
public enum MediaPreparedPressureSource: String, Codable, Hashable, Sendable {
    /// `UITouch.force / maximumPossibleForce` from an Apple Pencil sample.
    case real
    /// Imported legacy force without measured/simulated provenance.
    case legacyUnverified
    /// Host-side simulation (for example velocity-based width on a simulator
    /// or trackpad). Must be labeled as simulated in diagnostics and exports.
    case simulated
    /// No pressure input (finger/mouse). The renderer must not synthesize a
    /// time-varying pressure series for these samples.
    case none
}

/// A normalized drawing sample. `x`/`y` are in canvas-normalized coordinates
/// and are allowed to be outside 0...1 because the drawing canvas retains
/// out-of-bounds content by design.
public struct MediaPreparedBrushPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct MediaPreparedBrushSample: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    /// Normalized pressure 0...1, or nil when no pressure was measured.
    public var pressure: Double?
    public var pressureSource: MediaPreparedPressureSource
    /// Seconds relative to the beginning of the stroke. Used only for
    /// coalescing/dedup and diagnostics; not for rendering.
    public var timeOffset: Double

    public init(
        x: Double,
        y: Double,
        pressure: Double? = nil,
        pressureSource: MediaPreparedPressureSource? = nil,
        timeOffset: Double = 0
    ) {
        self.x = x
        self.y = y
        if let pressure, pressure.isFinite {
            self.pressure = min(max(pressure, 0), 1)
        } else {
            self.pressure = nil
        }
        if self.pressure == nil {
            self.pressureSource = .none
        } else {
            self.pressureSource = pressureSource ?? .legacyUnverified
        }
        self.timeOffset = timeOffset
    }

    public var point: MediaPreparedBrushPoint {
        MediaPreparedBrushPoint(x: x, y: y)
    }

    /// Validation used by the builder. Rejecting non-finite coordinates is
    /// important: a single NaN in a path makes Core Graphics drop the whole
    /// path on some OS versions.
    public var isFinite: Bool {
        x.isFinite && y.isFinite && timeOffset.isFinite
    }

    public func distance(to other: MediaPreparedBrushSample) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }

    /// Returns a copy with the pressure clamped and source normalized. A
    /// caller that supplies a pressure must also state whether it is real or
    /// simulated; unknown legacy origins remain explicitly unverified.
    public func normalized() -> MediaPreparedBrushSample {
        var copy = self
        if !copy.x.isFinite || !copy.y.isFinite {
            copy.x = copy.x.isFinite ? copy.x : 0
            copy.y = copy.y.isFinite ? copy.y : 0
        }
        if !copy.timeOffset.isFinite { copy.timeOffset = 0 }
        if let pressure = copy.pressure {
            copy.pressure = min(max(pressure, 0), 1)
        } else {
            copy.pressureSource = .none
        }
        return copy
    }
}

public struct MediaPreparedCanvasSize: Codable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}
