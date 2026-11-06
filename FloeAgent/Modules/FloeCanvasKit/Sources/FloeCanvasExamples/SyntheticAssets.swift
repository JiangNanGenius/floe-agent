// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeCanvasCore
import CoreGraphics
import ImageIO

// MARK: - Synthetic asset bytes
//
// The qualification sample embeds real, decodable bytes — never random junk
// wearing a mime type — because the rendered export path must have genuine
// content to draw. Image and PDF bytes are fully valid; audio is a valid
// RIFF/WAVE; video is a bundled 0.5-second H.264 synthetic color clip.
// Editor child-project bytes remain fixture-only opaque records.

enum SyntheticAssets {
    /// Canonical 1x1 red PNG (base64 of a complete, valid PNG stream).
    static let png1x1Base64 =
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    static func png1x1() -> Data {
        Data(base64Encoded: png1x1Base64)!
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A visible 96×64 deterministic image, so preview/export checks can
    /// distinguish actual content from an empty placeholder.
    static func pngTile() -> Data {
        let context = CGContext(data: nil, width: 96, height: 64,
            bitsPerComponent: 8, bytesPerRow: 96 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for row in 0..<8 {
            for column in 0..<12 {
                let dark = (row + column) % 2 == 0
                context.setFillColor(CGColor(red: dark ? 0.12 : 0.85,
                    green: dark ? 0.38 : 0.93, blue: dark ? 0.75 : 1, alpha: 1))
                context.fill(CGRect(x: column * 8, y: row * 8, width: 8, height: 8))
            }
        }
        context.setStrokeColor(CGColor(red: 1, green: 0.4, blue: 0.1, alpha: 1))
        context.setLineWidth(4)
        context.move(to: .init(x: 4, y: 4)); context.addLine(to: .init(x: 92, y: 60))
        context.strokePath()
        let bytes = NSMutableData()
        let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        precondition(CGImageDestinationFinalize(destination), "synthetic PNG encoding failed")
        return bytes as Data
    }

    /// Minimal but fully valid single-page PDF with a correct xref table.
    /// `CGPDFDocument` opens this; the native exporter draws a real page
    /// crop from it in rendered exports.
    static func minimalPDF(pageCount: Int = 1) -> Data {
        var objects: [String] = []
        // Object numbering: 1 catalog, 2 pages, then page/stream pairs (3/4, 5/6, ...).
        let pageObjectIDs = (0..<max(1, pageCount)).map { 3 + 2 * $0 }
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append(
            "<< /Type /Pages /Kids [\(pageObjectIDs.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pageObjectIDs.count) >>")
        for (index, objectID) in pageObjectIDs.enumerated() {
            // Landscape letter-ish media box, slightly different per page so
            // multi-page rendering is observable.
            let width = 612 + index * 10
            let height = 792
            objects.append(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(width) \(height)] "
                + "/Resources << >> /Contents \(objectID + 1) 0 R >>")
            // One content stream per page: a filled gray rectangle.
            let stream = "0.82 g 72 72 200 120 re f"
            objects.append(
                "<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }

        var body = "%PDF-1.4\n%âãÏÓ\n".data(using: .utf8)!
        var offsets: [Int] = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(body.count)
            let text = "\(index + 1) 0 obj\n\(object)\nendobj\n"
            body.append(Data(text.utf8))
        }
        let xrefOffset = body.count
        var xref = "xref\n0 \(objects.count + 1)\n"
        xref += String(format: "%010d %05d f \n", 0, 65535)
        for offset in offsets.dropFirst() {
            xref += String(format: "%010d %05d n \n", offset, 0)
        }
        xref += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\n"
        xref += "startxref\n\(xrefOffset)\n%%EOF\n"
        body.append(Data(xref.utf8))
        return body
    }

    /// Valid 8-bit PCM mono WAV with a deterministic short sine tone.
    static func wavTone(sampleCount: Int = 800, frequency: Double = 440) -> Data {
        let sampleRate: UInt32 = 8000
        let byteRate = sampleRate
        let blockAlign: UInt16 = 1
        let bitsPerSample: UInt16 = 8
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        let dataSize = UInt32(sampleCount)
        let fileSize = 36 + dataSize
        data.append(withUnsafeBytes(of: fileSize.littleEndian) { Data($0) })
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: UInt32(16).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: UInt16(1).littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: sampleRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
        data.append(withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
        data.append("data".data(using: .ascii)!)
        data.append(withUnsafeBytes(of: dataSize.littleEndian) { Data($0) })
        for index in 0..<sampleCount {
            let phase = 2 * Double.pi * frequency * Double(index) / Double(sampleRate)
            let sample = UInt8((sin(phase) * 0.4 + 0.5) * 255)
            data.append(sample)
        }
        return data
    }

    /// Real, decodable H.264 fixture; generated locally from a synthetic
    /// solid color. This never invokes an interpreter or media process at
    /// product runtime.
    static func syntheticVideoBytes() -> Data {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(
            forResource: "synthetic-video", withExtension: "mp4", subdirectory: "Fixtures")
                ?? bundle.url(forResource: "synthetic-video", withExtension: "mp4"),
              let bytes = try? Data(contentsOf: url) else {
            preconditionFailure("Missing bundled synthetic-video.mp4 qualification fixture")
        }
        return bytes
    }

    /// Opaque child-project archive for the editor reference. Fixture-only:
    /// it carries identity + revision + synthetic content and is never
    /// interpreted by the canvas kit (no CAD/media engine is implied).
    static func childProjectArchive(projectID: UUID, revision: Int64, editorKind: String) -> Data {
        let body: [String: String] = [
            "fixture": "true",
            "projectID": projectID.uuidString,
            "appliedRevision": "\(revision)",
            "editorKind": editorKind,
            "content": "synthetic child project bytes for qualification only",
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(body)) ?? Data("{}".utf8)
    }

    // MARK: Asset registry

    /// Every synthetic asset used by the mixed sample, keyed by asset id.
    struct Registry: Sendable {
        var bytes: [UUID: Data]
        var locators: [UUID: CanvasAssetLocator]

        func resolverBytes() -> [UUID: Data] { bytes }
    }

    /// Builds the asset registry for the mixed research+flow sample. All
    /// locators carry real sha256 + byteCount so the native archive
    /// integrity check exercises the strengthened digest/size cross-check.
    static func makeRegistry() -> Registry {
        var bytes: [UUID: Data] = [:]
        var locators: [UUID: CanvasAssetLocator] = [:]

        func register(
            _ id: UUID, data: Data, mime: String, path: String,
            license: String? = nil
        ) {
            bytes[id] = data
            locators[id] = CanvasAssetLocator(
                id: id,
                contentHash: sha256(data),
                relativePath: path,
                mimeType: mime,
                byteCount: Int64(data.count),
                license: license)
        }

        register(
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
            data: pngTile(), mime: "image/png", path: "assets/plan.png")
        register(
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")!,
            data: wavTone(), mime: "audio/wav", path: "assets/note.wav")
        register(
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
            data: syntheticVideoBytes(), mime: "video/mp4", path: "assets/clip.mp4")
        register(
            UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            data: minimalPDF(pageCount: 2), mime: "application/pdf",
            path: "assets/report.pdf", license: "CC-BY-4.0")
        register(
            UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
            data: png1x1(), mime: "image/png", path: "assets/formula-render.png")
        return Registry(bytes: bytes, locators: locators)
    }
}
