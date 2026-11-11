import Foundation
import Testing
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
import FloeToolboxCore
@testable import FloeToolboxUtilities

// All fixtures are generated in-memory (rendered text, generated QR codes);
// no real camera, photos, or network access is involved.

/// Renders text through the platform UI text engine (AppKit/UIKit) rather
/// than raw CoreText line drawing: Vision OCR needs properly rasterized
/// glyphs, and the UI engines anti-alias correctly on both platforms.
private func renderTextImage(_ text: String,
                             size: CGSize = CGSize(width: 1200, height: 360),
                             fontSize: CGFloat = 120,
                             fontName: String = "Helvetica-Bold") throws -> CGImage {
#if canImport(AppKit)
    // NSBitmapImageRep keeps the raster pixel-exact regardless of the
    // display's backing scale factor (NSImage lockFocus would upscale).
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false,
                               colorSpaceName: .calibratedRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let font = NSFont(name: fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
    (text as NSString).draw(at: NSPoint(x: 30, y: (size.height - fontSize) / 2),
                            withAttributes: [
                                .font: font,
                                .foregroundColor: NSColor.black,
                            ])
    NSGraphicsContext.restoreGraphicsState()
    return try #require(rep.cgImage, "Failed to render synthetic text image")
#elseif canImport(UIKit)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let uiImage = renderer.image { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: size))
        let font = UIFont(name: fontName, size: fontSize)
            ?? UIFont.systemFont(ofSize: fontSize, weight: .bold)
        (text as NSString).draw(at: CGPoint(x: 30, y: (size.height - fontSize) / 2),
                                withAttributes: [
                                    .font: font,
                                    .foregroundColor: UIColor.black,
                                ])
    }
    return try #require(uiImage.cgImage, "Failed to render synthetic text image")
#else
    throw ToolboxError.unsupported("text rendering")
#endif
}

private func pngData(_ image: CGImage) throws -> Data {
    try OpticsScanExport.png(image)
}

@Test func qrRoundTripThroughRecognition() throws {
    let payload = "https://floe-agent.com/toolbox/scan?ok=1"
    let code = try ToolboxQR.png(text: payload, correction: .high, scale: 8)
    let items = try OpticsRecognition.recognizeBarcodes(imageData: code)
    #expect(items.contains(where: { $0.kind == .qrCode && $0.payload == payload }))
    // The Vision pass labels the symbology for display.
    #expect(items.contains(where: { $0.detail.uppercased().contains("QR") }))
}

@Test func generatedQRAndTextImageAreBoundedByDecoder() throws {
    let code = try ToolboxQR.png(text: "bounds-check", scale: 4)
    let decoded = try OpticsImageDecoder.decode(code)
    #expect(decoded.pixelWidth > 0 && decoded.pixelHeight > 0)
    #expect(!decoded.wasDownsampled)
}

@Test func recognizeAllFindsRenderedTextViaOnDeviceOCR() throws {
    let image = try renderTextImage("FLOE 2026")
    let data = try pngData(image)
    let items = try OpticsRecognition.recognizeAll(imageData: data)
    let joined = items.filter { $0.kind == .text }.map(\.payload).joined(separator: " ").uppercased()
    #expect(joined.contains("FLOE"), "OCR result missing expected text: \(joined)")
}

@Test func recognizeTextIsBoundedAndSortedForReading() throws {
    let image = try renderTextImage("HELLO WORLD")
    let data = try pngData(image)
    let items = try OpticsRecognition.recognizeText(imageData: data)
    #expect(!items.isEmpty)
    #expect(items.allSatisfy { $0.kind == .text })
    #expect(items.allSatisfy { $0.payload.utf8.count <= OpticsRecognition.maximumPayloadCharacters })
}

@Test func recognizeTextKeepsChineseLinesFromBeingDropped() throws {
    // Mirrors the app OCR contract: a request defaulting to English-only
    // would silently skip fully rendered CJK lines.
    let image = try renderTextImage("扫描识别测试", fontName: "PingFangSC-Semibold")
    let data = try pngData(image)
    let items = try OpticsRecognition.recognizeText(imageData: data)
    let joined = items.map(\.payload).joined()
    #expect(joined.contains("扫描"), "OCR dropped Chinese lines: \(joined)")
}

@Test func decoderRejectsEmptyOversizeAndNonImageData() throws {
    #expect(throws: ToolboxError.self) { try OpticsImageDecoder.decode(Data()) }
    #expect(throws: ToolboxError.self) {
        try OpticsImageDecoder.decode(Data(repeating: 0x7f, count: 64))
    }
    let tooLarge = Data(repeating: 0, count: 1024)
    #expect(throws: ToolboxError.self) {
        try OpticsImageDecoder.decode(tooLarge, maximumEncodedBytes: 16)
    }
}

@Test func decoderDownsamplesInsideAPixelBudget() throws {
    let image = try renderTextImage("DOWNSAMPLE", size: CGSize(width: 2000, height: 1200))
    let data = try pngData(image)
    let decoded = try OpticsImageDecoder.decode(data, maximumPixels: 500_000)
    #expect(decoded.wasDownsampled)
    #expect(Double(decoded.pixelWidth) * Double(decoded.pixelHeight) <= 500_000 * 1.0001)
}

@Test func pdfExportBuildsRealMultiPageDocumentWithPerPageMediaBox() throws {
    let wide = try renderTextImage("PAGE ONE", size: CGSize(width: 960, height: 480))
    let tall = try renderTextImage("PAGE TWO", size: CGSize(width: 640, height: 960))
    let data = try OpticsScanExport.pdf(pages: [wide, tall])
    #expect(data.starts(with: Data("%PDF".utf8)))
    guard let document = CGPDFDocument(CGDataProvider(data: data as CFData)!) else {
        Issue.record("PDF did not parse back")
        return
    }
    #expect(document.numberOfPages == 2)
    let firstBox = document.page(at: 1)!.getBoxRect(.mediaBox)
    let secondBox = document.page(at: 2)!.getBoxRect(.mediaBox)
    // Page width is fixed at 612pt; each page keeps its image aspect ratio.
    #expect(abs(firstBox.width - 612) < 0.01)
    #expect(abs(secondBox.width - 612) < 0.01)
    #expect(abs(firstBox.height / firstBox.width - 0.5) < 0.01)
    #expect(abs(secondBox.height / secondBox.width - 1.5) < 0.01)
}

@Test func pdfExportEnforcesPageBounds() throws {
    let page = try renderTextImage("ONLY", size: CGSize(width: 320, height: 200))
    #expect(throws: ToolboxError.self) { try OpticsScanExport.pdf(pages: []) }
    let tooMany = Array(repeating: page, count: OpticsScanExport.maximumPages + 1)
    #expect(throws: ToolboxError.self) { try OpticsScanExport.pdf(pages: tooMany) }
}

@Test func pngExportRoundTripsThroughDecoder() throws {
    let image = try renderTextImage("PNG ROUND TRIP", size: CGSize(width: 640, height: 240))
    let data = try OpticsScanExport.png(image)
    let decoded = try OpticsImageDecoder.decode(data)
    #expect(decoded.pixelWidth == 640 && decoded.pixelHeight == 240)
}

@Test(arguments: [2, 3, 6, 8])
func importedPNGExportAppliesEXIFLikeRecognition(orientation: Int) throws {
    let width = 96, height = 48
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 48, y: 24, width: 48, height: 24))
    let raw = try #require(context.makeImage())
    let encoded = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(
        encoded as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, raw, [
        kCGImagePropertyOrientation: orientation,
        kCGImageDestinationLossyCompressionQuality: 1.0,
    ] as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    let source = try #require(CGImageSourceCreateWithData(encoded as CFData, nil))
    let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue == orientation)

    let recognitionImage = try OpticsImageDecoder.decode(encoded as Data)
    let untransformed = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(try rgbaPixels(recognitionImage.image) != rgbaPixels(untransformed))
    let exported = try OpticsScanExport.png(imageData: encoded as Data)
    let png = try OpticsImageDecoder.decode(exported)
    #expect(png.pixelWidth == (orientation >= 5 ? height : width))
    #expect(png.pixelHeight == (orientation >= 5 ? width : height))
    #expect(try rgbaPixels(png.image) == rgbaPixels(recognitionImage.image))
}

private func rgbaPixels(_ image: CGImage) throws -> Data {
    let rowBytes = image.width * 4
    var bytes = [UInt8](repeating: 0, count: rowBytes * image.height)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: rowBytes,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
        return true
    }
    #expect(rendered)
    return Data(bytes)
}

@Test func textExportBoundsAndRoundTripsUTF8() throws {
    let value = "中文扫描结果 / scan result 🧪"
    let data = try OpticsScanExport.text(value)
    #expect(String(data: data, encoding: .utf8) == value)
    #expect(throws: ToolboxError.self) {
        try OpticsScanExport.text(String(repeating: "x", count: OpticsScanExport.maximumTextBytes + 1))
    }
}

@Test func payloadPolicyClassifiesForDisplayOnly() {
    #expect(OpticsPayloadPolicy.kind(of: "https://example.com/a?b=1") == .url)
    #expect(OpticsPayloadPolicy.kind(of: "http://example.com") == .url)
    #expect(OpticsPayloadPolicy.kind(of: "www.example.com") == .url)
    #expect(OpticsPayloadPolicy.kind(of: "mailto:someone@example.com") == .email)
    #expect(OpticsPayloadPolicy.kind(of: "tel:+15551234") == .telephone)
    #expect(OpticsPayloadPolicy.kind(of: "WIFI:T:WPA;S:home;;") == .wifi)
    #expect(OpticsPayloadPolicy.kind(of: "just some text") == .plainText)
    // A URL-shaped payload is surfaced for copy only; a payload that is not
    // a URL has no display URL, so nothing can be auto-opened.
    #expect(OpticsPayloadPolicy.displayURL(of: "just some text") == nil)
    #expect(OpticsPayloadPolicy.displayURL(of: "ftp://example.com/file") == nil)
    #expect(OpticsPayloadPolicy.displayURL(of: "https://example.com")?.host == "example.com")
    #expect(OpticsPayloadPolicy.displayURL(of: "www.example.com")?.scheme == "https")
}
