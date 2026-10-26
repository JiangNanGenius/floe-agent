#if canImport(UIKit) && canImport(Vision)
// FloeCore shared on-device OCR recognizer regression (compiled into the
// unified FloeAppTests target membership via FloeAgent/project.yml).
//
// The fixture draws text through the DEVICE text stack into a real bitmap and
// feeds those pixels back through the shipped recognizer, so both scripts
// must OCR to their EXACT characters. Before the recognizer carried a
// Chinese-capable language list with automatic per-line detection this failed
// on the CJK assertion: a default English-only VNRecognizeTextRequest
// silently skips rendered Chinese. The test never accepts tofu, a missing
// line, or a relaxed character set.
import Foundation
import Testing
import UIKit
@testable import FloeCore

@Suite("FloeCore.VisualTextRecognition")
struct VisualTextRecognitionTests {

    @Test("Rendered CJK and Latin lines both OCR to their exact characters")
    func recognizesRenderedCJKAndLatinExactly() throws {
        let size = CGSize(width: 1200, height: 420)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            let cjkFont = UIFont(name: "PingFang SC", size: 150) ?? .systemFont(ofSize: 150)
            ("\u{9759}\u{9ED8}\u{51E0}\u{4F55}" as NSString).draw(
                at: CGPoint(x: 40, y: 30),
                withAttributes: [.font: cjkFont, .foregroundColor: UIColor.black])
            ("Export PNG 1080\u{00d7}1350" as NSString).draw(
                at: CGPoint(x: 40, y: 250),
                withAttributes: [.font: UIFont.systemFont(ofSize: 100, weight: .bold),
                                 .foregroundColor: UIColor.black])
        }
        let data = try #require(image.jpegData(compressionQuality: 0.95),
                                "fixture image encoding failed")
        let regions = try VisualTextRecognizer.recognize(
            imageData: data,
            pixelWidth: Int(image.size.width * image.scale),
            pixelHeight: Int(image.size.height * image.scale))
        let text = regions.map(\.text).joined(separator: " ")
        #expect(text.contains("\u{9759}\u{9ED8}\u{51E0}\u{4F55}"),
                "rendered CJK did not OCR to the exact characters: \(text.prefix(200))")
        #expect(text.contains("Export PNG 1080\u{00d7}1350"),
                "rendered Latin did not OCR to the exact characters: \(text.prefix(200))")
    }
}

#endif
