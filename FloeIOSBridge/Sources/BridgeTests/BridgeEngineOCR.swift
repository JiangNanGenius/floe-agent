import Foundation
import UIKit
import Vision
import BridgeCore

/// On-device Vision OCR over the actual fresh screen image.
///
/// The image is normalized to an up-oriented bitmap before recognition, so
/// Vision's normalized boxes always map to the displayed point space without a
/// second orientation transform. Secure regions are masked by the pure
/// geometry helper, never by trusting OCR text.
enum BridgeEngineOCR {
    static func observations(image: UIImage, fast: Bool) -> [BridgeEngineOCRTextObservation]? {
        guard let cgImage = upOrientedCGImage(image) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let results = request.results else { return [] }
        var output: [BridgeEngineOCRTextObservation] = []
        output.reserveCapacity(results.count)
        for observation in results {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox
            output.append(BridgeEngineOCRTextObservation(
                text: candidate.string,
                confidence: Double(candidate.confidence),
                normalizedX: Double(box.origin.x),
                normalizedY: Double(box.origin.y),
                normalizedWidth: Double(box.size.width),
                normalizedHeight: Double(box.size.height)
            ))
        }
        return output
    }

    /// Draws a screenshot into an upright bitmap. XCUIScreen images are
    /// normally `.up`; this guards the uncommon rotated case instead of
    /// applying an unverified manual transform.
    private static func upOrientedCGImage(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cgImage = image.cgImage {
            return cgImage
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let upright = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return upright.cgImage
    }
}
