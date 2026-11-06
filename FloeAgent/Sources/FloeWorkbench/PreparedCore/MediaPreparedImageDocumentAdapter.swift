// The canonical document remains the owner; these are raster projections only.
import Foundation
import CoreGraphics

public enum MediaPreparedImageDocumentAdapter {
    /// Legacy pressure has no recorded input provenance. Never relabel it as
    /// measured Pencil force; callers creating new samples specify provenance.
    public static func samples(_ stroke: ImageFreehandStroke) -> [MediaPreparedBrushSample] {
        stroke.points.enumerated().map { index, point in
            MediaPreparedBrushSample(x: point.x, y: point.y, pressure: point.pressure,
                                     pressureSource: point.pressure == nil ? MediaPreparedPressureSource.none : .legacyUnverified,
                                     timeOffset: Double(index) / 120)
        }
    }

    public static func renderStroke(_ stroke: ImageFreehandStroke,
                                    sourceWidth: Int, sourceHeight: Int,
                                    renderScale: Double = 1,
                                    isCancelled: () -> Bool = { false }) throws -> CGImage {
        let hex = stroke.colorHex.hasPrefix("#") ? String(stroke.colorHex.dropFirst()) : stroke.colorHex
        guard (hex.count == 6 || hex.count == 8), let raw = UInt64(hex, radix: 16) else {
            throw MediaPreparedImageError.invalidGeometry
        }
        let shift = hex.count == 8 ? 8 : 0
        let color = CGColor(red: Double((raw >> (16 + shift)) & 255) / 255,
                            green: Double((raw >> (8 + shift)) & 255) / 255,
                            blue: Double((raw >> shift) & 255) / 255,
                            alpha: hex.count == 8 ? Double(raw & 255) / 255 : 1)
        // v1 calls this field hardness, but stores SOFTNESS (0 hard, 1 soft).
        return try MediaPreparedImageKernel.renderBrush(
            samples: samples(stroke), sourceWidth: sourceWidth, sourceHeight: sourceHeight,
            width: stroke.width, opacity: stroke.opacity ?? 1,
            hardness: 1 - (stroke.hardness ?? 0.5), color: color,
            renderScale: renderScale, isCancelled: isCancelled)
    }

    /// A single selection has a lossless projection. Compound boolean shapes
    /// remain canonical and are refused here until the compound adapter is used.
    public static func selection(_ selection: ImageSelection,
                                 sourceWidth: Int, sourceHeight: Int) throws -> MediaPreparedSelectionSpec {
        guard selection.shapes.count == 1, let shape = selection.shapes.first,
              shape.operation == .replace else { throw MediaPreparedImageError.invalidGeometry }
        let kind: MediaPreparedSelectionSpec.Shape
        switch shape.kind {
        case .rectangle: kind = .rectangle
        case .ellipse: kind = .ellipse
        case .lasso: kind = .lasso
        }
        return MediaPreparedSelectionSpec(
            shape: kind, points: shape.points.map { .init(x: $0.x, y: $0.y) },
            featherPixels: try MediaPreparedSelectionSpec.legacyFeatherPixels(
                normalized: selection.feather, sourceWidth: sourceWidth, sourceHeight: sourceHeight),
            inverted: selection.inverted)
    }
}
