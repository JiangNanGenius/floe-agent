// SPDX-License-Identifier: MPL-2.0
// Real imported Symbol PPTX → native surface → native save → reopen.
// Source/OOXML checks are never substituted for reviewing the surface PNGs.
#if canImport(UIKit) && canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
import Foundation
import XCTest
import UIKit
import SwiftUI
import WebKit
import PDFKit
import ZIPFoundation
import CryptoKit
import FloeOfficeNative
@testable import FloeApp

@MainActor
final class OfficeSymbolBulletTests: XCTestCase {
    func testImportedSymbolBulletNativeRenderSaveAndReopenPreservesBodyPUA() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FLOE_NATIVE_SYMBOL_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in real native Symbol rendering qualification")
        }
        let input = URL(fileURLWithPath: try XCTUnwrap(env["FLOE_NATIVE_SYMBOL_INPUT"]))
        let expectedHash = try XCTUnwrap(env["FLOE_NATIVE_SYMBOL_INPUT_SHA256"])
        XCTAssertEqual(try digest(input), expectedHash, "Stage the untouched synthetic public fixture")
        executionTimeAllowance = 480
        continueAfterFailure = false
        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Qualification/OfficeSymbol-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("FLOE_NATIVE_SYMBOL_ARTIFACT_ROOT=\(root.path)")
        let source = root.appendingPathComponent("original-symbol.pptx")
        try fm.copyItem(at: input, to: source)
        attach(source, "symbol-original-pptx")
        let original = try inspect(source)
        XCTAssertEqual(original.texts, ["SYMBOL BULLET", "UNICODE BULLET", "BODY PUA \u{F0B7} KEEP"])
        XCTAssertEqual(original.bullets, ["\u{F0B7}", "•"])
        XCTAssertEqual(original.bulletFonts.first, "Symbol")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKey() }
        let output = root.appendingPathComponent("native-saved-symbol.pptx")
        for stage in ["original", "reopened"] {
            let session = OfficeFileSession()
            let window = mount(session, scene: scene)
            defer { window.isHidden = true; window.rootViewController = nil }
            do {
                await session.open(stage == "original" ? source : output)
                try await wait(120, "native Symbol open") { session.canAct && session.documentActionsReady && session.controller != nil }
                let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
                try await wait(45, "actual native slide paint") {
                    OfficeFileSession.hostRenderDiagnostics(native)["stage"] == "visible-render"
                }
                let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
                let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
                let surface = try await web.takeSnapshot(configuration: config)
                let surfaceURL = root.appendingPathComponent(stage + "-actual-surface.png")
                try XCTUnwrap(surface.pngData()).write(to: surfaceURL)
                attach(surfaceURL, stage + "-actual-Symbol-surface-review-required")
                if stage == "original" {
                    if session.readOnly {
                        let accepted = await session.requestEditing()
                        XCTAssertTrue(accepted, "Native edit entry rejected")
                    }
                    try await wait(150, "native editable Symbol document") {
                        !session.readOnly && session.canAct && session.documentActionsReady
                    }
                    let saved = try await session.exportDocument(format: "pptx")
                    try fm.copyItem(at: saved, to: output)
                    attach(output, "symbol-native-saved-pptx")
                    let result = try inspect(output)
                    XCTAssertEqual(result.texts.joined(), original.texts.joined(), "Native save changed ordinary text/PUA")
                    XCTAssertEqual(result.bullets.count, 2, "Native save dropped a bullet")
                    XCTAssertTrue(result.bullets.allSatisfy { ["\u{F0B7}", "•", "\u{E12C}"].contains($0) },
                        "Unexpected saved native Symbol substitution")
                }
                // This supplementary export exercises the engine's actual PDF
                // renderer. Its pixel gate does not qualify the bitmap surface;
                // the primary owner must inspect both actual-surface captures.
                let pdf = try await session.exportDocument(format: "pdf")
                let retainedPDF = root.appendingPathComponent(stage + "-native-render.pdf")
                try fm.copyItem(at: pdf, to: retainedPDF)
                attach(retainedPDF, stage + "-native-render-PDF")
                try assertFilledRoundBullet(retainedPDF, root: root, stage: stage)
                await session.release()
            } catch {
                await session.release()
                throw error
            }
            window.isHidden = true; window.rootViewController = nil
        }
        XCTAssertEqual(try digest(source), expectedHash, "Native save overwrote imported original")
        XCTAssertEqual(try digest(input), expectedHash, "Fixture input changed")
        let receipt: [String: Any] = ["originalSHA256": expectedHash, "savedSHA256": try digest(output),
            "ordinaryBodyPUAPreserved": true, "nativePDFBulletPixelGate": true,
            "actualSurfaceVisualReview": "pending-primary-review", "documentNormalizationByTest": false]
        let receiptURL = root.appendingPathComponent("verification.json")
        try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: receiptURL)
        attach(receiptURL, "symbol-native-verification")
    }

    private func inspect(_ url: URL) throws -> SymbolSlideXML {
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try XCTUnwrap(archive["ppt/slides/slide1.xml"])
        guard entry.uncompressedSize <= 1024 * 1024 else { throw failure("Unexpected fixture slide size") }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        let reader = SymbolSlideXML()
        let parser = XMLParser(data: data); parser.delegate = reader
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false
        guard parser.parse() else { throw parser.parserError ?? failure("Invalid native slide XML") }
        return reader
    }

    private func assertFilledRoundBullet(_ url: URL, root: URL, stage: String) throws {
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 1)
        let page = try XCTUnwrap(document.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width / bounds.height, 4.0 / 3.0, accuracy: 0.01)
        let width = 1440, height = 1080
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(height) / bounds.height)
            page.draw(with: .mediaBox, to: context)
            let image = try XCTUnwrap(context.makeImage())
            let png = try XCTUnwrap(UIImage(cgImage: image).pngData())
            let target = root.appendingPathComponent(stage + "-native-PDF-raster.png")
            try png.write(to: target); attach(target, stage + "-native-PDF-raster")
        }
        // Fixed public fixture: only the Symbol bullet lies in this region;
        // body text begins beyond x=108pt. Work in the raster's row order and
        // sample both vertical orientations to accommodate PDF bitmap origins.
        var candidates: [(Int, Int)] = []
        for y in 140..<270 {
            for x in 130..<200 {
                for row in [y, height - 1 - y] {
                    let offset = (row * width + x) * 4
                    if pixels[offset] < 100 && pixels[offset + 1] < 100 && pixels[offset + 2] < 100 {
                        candidates.append((x, y))
                    }
                }
            }
        }
        let minX = try XCTUnwrap(candidates.map(\.0).min(), "No rendered Symbol bullet; possible missing glyph")
        let maxX = try XCTUnwrap(candidates.map(\.0).max())
        let minY = try XCTUnwrap(candidates.map(\.1).min())
        let maxY = try XCTUnwrap(candidates.map(\.1).max())
        let w = maxX - minX + 1, h = maxY - minY + 1
        XCTAssertGreaterThan(w, 3); XCTAssertGreaterThan(h, 3)
        XCTAssertEqual(Double(w) / Double(h), 1, accuracy: 0.35, "Symbol glyph is not round")
        let fill = Double(candidates.count) / Double(w * h)
        XCTAssertGreaterThan(fill, 0.60, "Hollow missing-glyph square is not a filled bullet")
        XCTAssertLessThan(fill, 0.95, "A solid square is not a round bullet")
        let centerX = (minX + maxX) / 2, centerY = (minY + maxY) / 2
        XCTAssertTrue(candidates.contains { abs($0.0 - centerX) <= 1 && abs($0.1 - centerY) <= 1 },
            "Missing-glyph rectangle has an empty center")
    }

    private func mount(_ session: OfficeFileSession, scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: OfficeDocumentSurface(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        window.windowLevel = .normal + 1; window.makeKeyAndVisible(); return window
    }
    private func wait(_ seconds: TimeInterval, _ stage: String, _ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready(), Date() < deadline { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(100)) }
        guard ready() else { throw failure("Timed out: " + stage) }
    }
    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    private func attach(_ url: URL, _ name: String) {
        let attachment = XCTAttachment(contentsOfFile: url); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "OfficeSymbolQualification", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private final class SymbolSlideXML: NSObject, XMLParserDelegate {
    var texts: [String] = [], bullets: [String] = [], bulletFonts: [String] = []
    private var text: String?
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String]) {
        guard namespaceURI == "http://schemas.openxmlformats.org/drawingml/2006/main" else { return }
        if elementName == "t" { text = "" }
        if elementName == "buChar", let value = attributes["char"] { bullets.append(value) }
        if elementName == "buFont", let value = attributes["typeface"] { bulletFonts.append(value) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if text != nil { text?.append(string) } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t", let value = text { texts.append(value); text = nil }
    }
}
#endif
