// FloeImages — Deterministic Core Image executor for validated operations.
//
// See docs/ALPHA_DAILY_PLAN.md §"Files, documents and images": the local
// image pipeline is deterministic and pure so it is unit-testable on any
// platform with Core Image. Every operation is validated via the committed
// ImageOperation.validate() before execution; model-supplied parameters
// never bypass validation.

import Foundation
import CoreGraphics
import CoreImage
import FloeCore

#if canImport(CoreImage)
/// Executes validated ImageOperations against a CGImage using Core Image.
/// Deterministic: the same operation applied to the same source produces
/// an identical output image (same extent + pixels).
public struct ImagePipeline: Sendable {
    private let context: CIContext

    public init(context: CIContext = CIContext(options: [.useSoftwareRenderer: false])) {
        self.context = context
    }

    /// Applies one validated operation to the source image.
    /// - Throws: `FloeError.validationFailed` for invalid parameters, or
    ///   `FloeError.internalError` when a filter cannot render.
    public func apply(_ operation: ImageOperation, to source: CGImage) throws -> CGImage {
        try operation.validate()
        let input = CIImage(cgImage: source)
        let output = try filter(operation, on: input)
        let extent = output.extent.isInfinite ? input.extent : output.extent
        guard let rendered = context.createCGImage(output, from: extent) else {
            throw FloeError.internalError("Core Image failed to render the operation")
        }
        return rendered
    }

    // MARK: - Operation → filter chain

    private func filter(_ operation: ImageOperation, on input: CIImage) throws -> CIImage {
        switch operation {
        case .crop(let rect):
            let extent = input.extent
            let crop = CGRect(
                x: extent.minX + rect.x * extent.width,
                y: extent.minY + rect.y * extent.height,
                width: rect.width * extent.width,
                height: rect.height * extent.height
            )
            return input.cropped(to: crop)

        case .rotate(let degrees):
            let radians = degrees * .pi / 180
            return input.transformed(by: CGAffineTransform(rotationAngle: radians))

        case .resize(let width, let height, let preserveAspect):
            let extent = input.extent
            let target: CGSize
            if preserveAspect {
                let scale = min(CGFloat(width) / extent.width, CGFloat(height) / extent.height)
                target = CGSize(width: extent.width * scale, height: extent.height * scale)
            } else {
                target = CGSize(width: width, height: height)
            }
            let scaleX = target.width / extent.width
            let scaleY = target.height / extent.height
            return input.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        case .adjustExposure(let ev):
            return try applyFilter("CIExposureAdjust", on: input, parameters: ["inputEV": ev])

        case .adjustColor(let saturation, let contrast, let brightness):
            return try applyFilter("CIColorControls", on: input, parameters: [
                "inputSaturation": saturation,
                "inputContrast": contrast,
                "inputBrightness": brightness
            ])

        case .sharpen(let radius):
            return try applyFilter("CISharpenLuminance", on: input, parameters: ["inputSharpness": radius / 100])

        case .blur(let radius):
            return try applyFilter("CIGaussianBlur", on: input, parameters: ["inputRadius": radius])

        case .removeMetadata:
            // Pixel-level no-op; metadata is stripped at export (ImageIO
            // destination without properties). Returning the input keeps the
            // pipeline pure; the exporter drops metadata.
            return input

        case .convertFormat, .compress:
            // Format/quality are export-time concerns handled by ImageIO in
            // the exporter; the pipeline keeps pixels unchanged.
            return input

        case .applyMask, .composite, .drawText, .watermark, .removeBackground:
            // These require additional assets (mask/overlay images) or
            // platform text/vision services. Surfaced as unsupported by the
            // local pipeline; remote/unsupported UI handles them honestly.
            throw FloeError.internalError("Operation requires additional assets or services")
        }
    }

    private func applyFilter(
        _ name: String,
        on input: CIImage,
        parameters: [String: Any]
    ) throws -> CIImage {
        guard let filter = CIFilter(name: name) else {
            throw FloeError.internalError("Core Image filter unavailable: \(name)")
        }
        filter.setValue(input, forKey: kCIInputImageKey)
        for (key, value) in parameters {
            filter.setValue(value, forKey: key)
        }
        guard let output = filter.outputImage else {
            throw FloeError.internalError("Core Image filter produced no output: \(name)")
        }
        return output
    }
}
#endif
