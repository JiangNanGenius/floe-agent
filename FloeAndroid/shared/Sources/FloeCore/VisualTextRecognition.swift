import Foundation

#if canImport(Vision)
import Vision
#endif

/// A bounded, OCR-derived visual text anchor. This is deliberately not called
/// an accessibility element: neither a screenshot nor RFB proves native roles,
/// enabled state, hierarchy, or action semantics.
public struct VisualTextRegion: Sendable, Codable, Hashable {
    public let reference: String
    public let text: String
    public let confidence: Float
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(
        reference: String,
        text: String,
        confidence: Float,
        x: Int,
        y: Int,
        width: Int,
        height: Int
    ) {
        self.reference = reference
        self.text = text
        self.confidence = confidence
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Int { x + width / 2 }
    public var centerY: Int { y + height / 2 }
}

public enum VisualTextRecognizer {
    /// Recognizes visible text into upper-left-origin screenshot pixel bounds.
    /// Results are reading-order sorted, bounded, and assigned per-frame refs.
    public static func recognize(
        imageData: Data,
        pixelWidth: Int,
        pixelHeight: Int,
        referencePrefix: String = "text",
        limit: Int = 80
    ) throws -> [VisualTextRegion] {
        guard pixelWidth > 0, pixelHeight > 0, !imageData.isEmpty, limit > 0 else { return [] }
#if canImport(Vision)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        let handler = VNImageRequestHandler(data: imageData, options: [:])
        try handler.perform([request])
        let observations = (request.results ?? []).compactMap { observation -> (String, Float, CGRect)? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let normalized = observation.boundingBox
            let rawX = Int((normalized.minX * Double(pixelWidth)).rounded(.down))
            let rawY = Int(((1 - normalized.maxY) * Double(pixelHeight)).rounded(.down))
            let x = max(0, min(pixelWidth - 1, rawX))
            let y = max(0, min(pixelHeight - 1, rawY))
            let width = max(1, min(
                pixelWidth - x,
                Int((normalized.width * Double(pixelWidth)).rounded(.up))
            ))
            let height = max(1, min(
                pixelHeight - y,
                Int((normalized.height * Double(pixelHeight)).rounded(.up))
            ))
            return (text, candidate.confidence, CGRect(x: x, y: y, width: width, height: height))
        }
        let sorted = observations.sorted {
            if abs($0.2.minY - $1.2.minY) > 8 { return $0.2.minY < $1.2.minY }
            return $0.2.minX < $1.2.minX
        }
        return sorted.prefix(limit).enumerated().map { index, item in
            VisualTextRegion(
                reference: "\(referencePrefix)-\(index + 1)",
                text: item.0,
                confidence: item.1,
                x: Int(item.2.minX),
                y: Int(item.2.minY),
                width: Int(item.2.width),
                height: Int(item.2.height)
            )
        }
#else
        return []
#endif
    }
}
