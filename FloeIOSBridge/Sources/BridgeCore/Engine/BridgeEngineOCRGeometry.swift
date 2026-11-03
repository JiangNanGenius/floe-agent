import Foundation

/// One Vision text observation before coordinate conversion. `normalizedRect`
/// uses Vision's bottom-left origin and is relative to the already-up-oriented
/// image the engine hands to `VNImageRequestHandler`.
public struct BridgeEngineOCRTextObservation: Equatable, Sendable {
    public var text: String
    public var confidence: Double
    public var normalizedX: Double
    public var normalizedY: Double
    public var normalizedWidth: Double
    public var normalizedHeight: Double

    public init(text: String, confidence: Double,
                normalizedX: Double, normalizedY: Double,
                normalizedWidth: Double, normalizedHeight: Double) {
        self.text = text
        self.confidence = confidence
        self.normalizedX = normalizedX
        self.normalizedY = normalizedY
        self.normalizedWidth = normalizedWidth
        self.normalizedHeight = normalizedHeight
    }
}

/// One screen_text item in points, in the same shape `find_element` uses.
public struct BridgeEngineOCRItem: Equatable, Sendable {
    public var label: String
    public var confidence: Double
    public var frame: BridgeUIRect
    public var centerX: Double
    public var centerY: Double

    public init(label: String, confidence: Double, frame: BridgeUIRect) {
        self.label = label
        self.confidence = confidence
        self.frame = frame
        self.centerX = frame.midX
        self.centerY = frame.midY
    }
}

public enum BridgeEngineOCRGeometry {
    public static let defaultMinimumConfidence = 0.3
    public static let minimumConfidence = 0.0
    public static let maximumConfidence = 1.0

    /// Converts a Vision bounding box to screen points. Vision reports a
    /// normalized rect with a bottom-left origin; screen taps use a top-left
    /// origin. `imagePointWidth/Height` describe the displayed image the OCR
    /// ran on, so image insets and orientation are already encoded there.
    public static func screenRect(normalizedX: Double,
                                  normalizedY: Double,
                                  normalizedWidth: Double,
                                  normalizedHeight: Double,
                                  imagePointWidth: Double,
                                  imagePointHeight: Double) -> BridgeUIRect? {
        guard imagePointWidth > 0, imagePointHeight > 0 else { return nil }
        let x = normalizedX
        let y = normalizedY
        let width = normalizedWidth
        let height = normalizedHeight
        guard x.isFinite, y.isFinite, width.isFinite, height.isFinite else { return nil }
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)
        let clampedWidth = min(max(width, 0), 1 - clampedX)
        let clampedHeight = min(max(height, 0), 1 - clampedY)
        guard clampedWidth > 0, clampedHeight > 0 else { return nil }
        return BridgeUIRect(
            x: clampedX * imagePointWidth,
            y: (1 - clampedY - clampedHeight) * imagePointHeight,
            width: clampedWidth * imagePointWidth,
            height: clampedHeight * imagePointHeight
        )
    }

    public static func items(from observations: [BridgeEngineOCRTextObservation],
                             minimumConfidence: Double,
                             imagePointWidth: Double,
                             imagePointHeight: Double,
                             secureRects: [BridgeUIRect],
                             query: String?) -> [BridgeEngineOCRItem] {
        let confidenceFloor = min(max(minimumConfidence, Self.minimumConfidence), Self.maximumConfidence)
        let needle = query?.lowercased()
        var output: [BridgeEngineOCRItem] = []
        for observation in observations {
            let label = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty else { continue }
            guard observation.confidence >= confidenceFloor else { continue }
            guard let rect = screenRect(
                normalizedX: observation.normalizedX,
                normalizedY: observation.normalizedY,
                normalizedWidth: observation.normalizedWidth,
                normalizedHeight: observation.normalizedHeight,
                imagePointWidth: imagePointWidth,
                imagePointHeight: imagePointHeight
            ) else { continue }
            // A secure text field is a privacy boundary. Mask anything that
            // intersects it rather than trying to guess whether the pixels are
            // a password dot, a placeholder, or a revealed value.
            if secureRects.contains(where: { $0.intersectionArea(with: rect) > 0 }) {
                continue
            }
            if let needle, !needle.isEmpty, !label.lowercased().contains(needle) {
                continue
            }
            output.append(BridgeEngineOCRItem(
                label: label,
                confidence: observation.confidence,
                frame: rect
            ))
        }
        return readingOrder(output)
    }

    /// Stable top-to-bottom, then left-to-right order. Observations within a
    /// small vertical band (a status row or a label/value pair) read together.
    public static func readingOrder(_ items: [BridgeEngineOCRItem]) -> [BridgeEngineOCRItem] {
        let rowTolerance = 8.0
        return items.sorted { lhs, rhs in
            if abs(lhs.centerY - rhs.centerY) > rowTolerance {
                return lhs.centerY < rhs.centerY
            }
            if lhs.centerX != rhs.centerX { return lhs.centerX < rhs.centerX }
            return lhs.label < rhs.label
        }
    }
}
