import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import FloeToolboxCore
#if canImport(Vision)
import Vision
#endif

/// One recognized payload from a barcode, QR code, or an OCR pass. Values
/// are bounded before they reach the UI, and a scan never grants tool
/// authority: links are copied, never opened.
public struct OpticsScanItem: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case qrCode, barcode, text
    }
    public let id: UUID
    public let kind: Kind
    public let payload: String
    /// Human-readable source label, e.g. "QR", "EAN13", or "Text".
    public let detail: String

    public init(id: UUID = UUID(), kind: Kind, payload: String, detail: String) {
        self.id = id
        self.kind = kind
        self.payload = payload
        self.detail = detail
    }
}

/// Classifies a scanned payload for display only. The classification never
/// turns into navigation: a URL result is shown as text the user can copy.
public enum OpticsPayloadKind: String, Sendable, Hashable {
    case url, email, telephone, wifi, plainText
}

public enum OpticsPayloadPolicy {
    /// Conservative URL detection: only absolute http(s) URLs with a host, or
    /// an explicit "www." prefix, count as links.
    public static func kind(of payload: String) -> OpticsPayloadKind {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8192 else { return .plainText }
        let lowered = trimmed.lowercased()
        if lowered.hasPrefix("mailto:"), trimmed.count > 7 { return .email }
        if lowered.hasPrefix("tel:"), trimmed.count > 4 { return .telephone }
        if trimmed.hasPrefix("WIFI:") { return .wifi }
        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme), url.host != nil {
            return .url
        }
        if lowered.hasPrefix("www."), URL(string: "https://\(trimmed)")?.host != nil {
            return .url
        }
        return .plainText
    }

    /// The URL a payload represents, for display/copy only. Returns nil for
    /// non-URL payloads; callers must never feed this into a browser without
    /// an explicit user action outside this policy.
    public static func displayURL(of payload: String) -> URL? {
        guard kind(of: payload) == .url else { return nil }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("www.") {
            return URL(string: "https://\(trimmed)")
        }
        return URL(string: trimmed)
    }
}

/// Bounded image decode shared by every optics entry point: encoded bytes,
/// declared pixel dimensions, and decoded pixels all pass a ceiling before
/// and after decode, and oversized sources are downsampled through the
/// ImageIO thumbnail path with EXIF orientation always applied.
public enum OpticsImageDecoder {
    public static let maximumEncodedBytes = 20 * 1024 * 1024
    public static let maximumDecodeDimension = 8192
    public static let maximumPixels = 32 * 1024 * 1024

    public struct Decoded: Sendable {
        public let data: Data
        public let image: CGImage
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let wasDownsampled: Bool
    }

    public static func decode(
        _ data: Data,
        maximumEncodedBytes: Int = Self.maximumEncodedBytes,
        maximumPixels: Int = Self.maximumPixels,
        maximumDecodeDimension: Int = Self.maximumDecodeDimension
    ) throws -> Decoded {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else {
            throw ToolboxError.limit("image data")
        }
        let source = CGImageSourceCreateWithData(data as CFData,
                                                 [kCGImageSourceShouldCache: false] as CFDictionary)
        guard let source else { throw ToolboxError.invalid("image data") }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let widthNumber = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let heightNumber = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ToolboxError.invalid("image metadata")
        }
        let originalWidth = widthNumber.doubleValue
        let originalHeight = heightNumber.doubleValue
        guard originalWidth.isFinite, originalHeight.isFinite,
              originalWidth > 0, originalHeight > 0,
              originalWidth <= 32768, originalHeight <= 32768 else {
            throw ToolboxError.invalid("image dimensions")
        }
        let originalPixels = originalWidth * originalHeight
        let downsampleScale = originalPixels > Double(maximumPixels)
            ? (Double(maximumPixels) / originalPixels).squareRoot()
            : 1
        let targetMaxDimension = max(1, Int((max(originalWidth, originalHeight) * downsampleScale).rounded(.down)))
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: targetMaxDimension,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw ToolboxError.invalid("image decode")
        }
        guard image.width > 0, image.height > 0,
              image.width <= maximumDecodeDimension,
              image.height <= maximumDecodeDimension,
              Double(image.width) * Double(image.height) <= Double(maximumPixels) * 1.0001 else {
            throw ToolboxError.limit("decoded image")
        }
        let wasDownsampled = Double(image.width) * Double(image.height) < originalPixels * 0.999
        return Decoded(data: data, image: image,
                       pixelWidth: image.width, pixelHeight: image.height,
                       wasDownsampled: wasDownsampled)
    }
}

/// On-device recognition over decoded images. Vision covers every supported
/// symbology in one pass; the existing CoreImage QR reader stays as the
/// fallback for codes Vision misses (rotation/low contrast). OCR mirrors the
/// app's zh/en language handling so Chinese lines are not silently dropped.
public enum OpticsRecognition {
    public static let maximumResults = 64
    public static let maximumPayloadCharacters = 8192

    /// Barcodes and QR codes from a still image.
    public static func recognizeBarcodes(imageData: Data) throws -> [OpticsScanItem] {
        try Task.checkCancellation()
        let decoded = try OpticsImageDecoder.decode(imageData)
        try Task.checkCancellation()
        var items = detectBarcodesWithVision(in: decoded.image)
        if items.isEmpty {
            // Fallback path reuses the existing CoreImage QR detector; it is
            // already bounded and matches ToolboxQRView behavior.
            let payloads = (try? ToolboxQR.read(imageData: imageData)) ?? []
            items = payloads.map {
                OpticsScanItem(kind: .qrCode, payload: $0, detail: "QR")
            }
        }
        try Task.checkCancellation()
        return bounded(items)
    }

    /// On-device OCR from a still image (Chinese + English).
    public static func recognizeText(imageData: Data) throws -> [OpticsScanItem] {
        try Task.checkCancellation()
        let decoded = try OpticsImageDecoder.decode(imageData)
        try Task.checkCancellation()
        let items = detectTextWithVision(in: decoded.image)
        try Task.checkCancellation()
        return bounded(items)
    }

    /// Barcodes first, then text. Each path is independent: a barcode hit
    /// does not suppress OCR and vice versa.
    public static func recognizeAll(imageData: Data) throws -> [OpticsScanItem] {
        try Task.checkCancellation()
        let decoded = try OpticsImageDecoder.decode(imageData)
        return try recognizeAll(decoded: decoded)
    }

    /// Reuse the exact bounded, orientation-normalized image retained by the
    /// scanner, so recognition and subsequent image export see the same pixels.
    public static func recognizeAll(decoded: OpticsImageDecoder.Decoded) throws -> [OpticsScanItem] {
        try Task.checkCancellation()
        var items = detectBarcodesWithVision(in: decoded.image)
        if items.isEmpty {
            let payloads = (try? ToolboxQR.read(imageData: decoded.data)) ?? []
            items += payloads.map { OpticsScanItem(kind: .qrCode, payload: $0, detail: "QR") }
        }
        try Task.checkCancellation()
        items += detectTextWithVision(in: decoded.image)
        try Task.checkCancellation()
        return bounded(items)
    }

    // MARK: - Vision passes

    private static func detectBarcodesWithVision(in image: CGImage) -> [OpticsScanItem] {
#if canImport(Vision)
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue,
                  !payload.isEmpty, payload.utf8.count <= maximumPayloadCharacters else { return nil }
            let label = String(observation.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: ""))
            let kind: OpticsScanItem.Kind = label.uppercased().contains("QR") ? .qrCode : .barcode
            return OpticsScanItem(kind: kind, payload: payload, detail: label)
        }
#else
        return []
#endif
    }

    private static func detectTextWithVision(in image: CGImage) -> [OpticsScanItem] {
#if canImport(Vision)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Mirror VisualTextRecognizer: the default request is English-only
        // and would silently skip fully rendered CJK lines.
        let desiredLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        if let supported = try? request.supportedRecognitionLanguages() {
            let kept = desiredLanguages.filter { supported.contains($0) }
            if !kept.isEmpty { request.recognitionLanguages = kept }
        } else {
            request.recognitionLanguages = desiredLanguages
        }
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.utf8.count <= maximumPayloadCharacters else { return nil }
            return OpticsScanItem(kind: .text, payload: text, detail: "Text")
        }
#else
        return []
#endif
    }

    private static func bounded(_ items: [OpticsScanItem]) -> [OpticsScanItem] {
        Array(items.prefix(maximumResults))
    }
}

/// Real export artifacts from recognized content or scanned document pages.
/// PDF pages are drawn through the CoreGraphics PDF consumer so no UIKit
/// renderer is required; text exports stay bounded.
public enum OpticsScanExport {
    public static let maximumPages = 24
    public static let maximumTextBytes = 256 * 1024
    /// PDF page width in points (8.5in); pages keep their image aspect ratio.
    private static let pageWidth: CGFloat = 612

    public static func pdf(pages: [CGImage]) throws -> Data {
        guard !pages.isEmpty, pages.count <= maximumPages else {
            throw ToolboxError.limit("scan pages")
        }
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else {
            throw ToolboxError.invalid("PDF consumer")
        }
        let first = pages[0]
        var mediaBox = pageRect(for: first)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ToolboxError.invalid("PDF context")
        }
        for page in pages {
            let rect = pageRect(for: page)
            // Each page carries its own media box so mixed aspect ratios
            // (photos vs. document photos) never distort. CG requires the
            // box as CFData storing the CGRect by value.
            var box = rect
            let boxData = Data(bytes: &box, count: MemoryLayout<CGRect>.size) as CFData
            let dictionary: [CFString: Any] = [kCGPDFContextMediaBox: boxData]
            context.beginPDFPage(dictionary as CFDictionary)
            draw(page: page, in: context)
            context.endPDFPage()
        }
        context.closePDF()
        guard data.count > 0 else { throw ToolboxError.invalid("PDF output") }
        return data as Data
    }

    /// Imported files use the same decode and EXIF transform as recognition;
    /// the resulting PNG contains upright pixels, independent of metadata.
    public static func png(imageData: Data) throws -> Data {
        try Task.checkCancellation()
        let decoded = try OpticsImageDecoder.decode(imageData)
        try Task.checkCancellation()
        return try png(decoded.image)
    }

    public static func png(_ image: CGImage) throws -> Data {
        guard image.width > 0, image.height > 0,
              image.width <= 16384, image.height <= 16384 else {
            throw ToolboxError.invalid("PNG image")
        }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes as CFMutableData,
                                                                 UTType.png.identifier as CFString, 1, nil) else {
            throw ToolboxError.invalid("PNG encoder")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ToolboxError.invalid("PNG encoder")
        }
        return bytes as Data
    }

    public static func text(_ string: String) throws -> Data {
        guard !string.isEmpty, string.utf8.count <= maximumTextBytes else {
            throw ToolboxError.limit("text export")
        }
        guard let data = string.data(using: .utf8) else { throw ToolboxError.invalid("text encoding") }
        return data
    }

    // MARK: - PDF drawing

    private static func pageRect(for image: CGImage) -> CGRect {
        let ratio = CGFloat(image.height) / CGFloat(max(1, image.width))
        return CGRect(x: 0, y: 0, width: pageWidth, height: max(1, pageWidth * ratio))
    }

    private static func draw(page image: CGImage, in context: CGContext) {
        let rect = pageRect(for: image)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
    }
}
