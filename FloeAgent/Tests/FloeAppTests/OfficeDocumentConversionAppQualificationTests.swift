// SPDX-License-Identifier: MPL-2.0
// Opt-in App-host integration: production bundled WK converter -> actual DOCX
// -> independent ZIP/XML checks -> real native Office open -> actual surface image evidence.
// A passing test proves this pipeline, NOT human verification of CJK glyphs.
#if canImport(UIKit) && canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
import Foundation
import XCTest
import UIKit
import SwiftUI
import WebKit
import ZIPFoundation
import CryptoKit
import FloeCore
import FloeTools
import FloeOfficeNative
@testable import FloeApp

@MainActor
final class OfficeDocumentConversionAppQualificationTests: XCTestCase {
    func testBundledMarkdownToDOCXChineseNativeRender() async throws {
        guard ProcessInfo.processInfo.environment["FLOE_CONVERSION_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in native Office conversion qualification; not executed")
        }
        executionTimeAllowance = 300
        continueAfterFailure = false
        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Qualification/OfficeConversion-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        // Deliberately retained for export even on failure. Primary removes only
        // this synthetic run directory AFTER exporting xcresult and these files.
        print("FLOE_CONVERSION_QUALIFICATION_ARTIFACT_ROOT=\(root.path)")
        let input = root.appendingPathComponent("bilingual.md")
        let output = root.appendingPathComponent("bilingual.docx")
        let source = """
        # 中文转换验收 Chinese conversion

        中文段落：春天的山水与城市。English text 12345.

        **中文粗体** and *English emphasis*.

        | 项目 Item | 数量 Count |
        | --- | --- |
        | 苹果 Apple | 12 |
        | 图纸 Drawing | 34 |
        """
        try Data(source.utf8).write(to: input, options: .atomic)
        let originalHash = try digest(input)
        let cancellation = CancellationToken()
        defer { cancellation.cancel() }
        let context = ToolContext(runID: UUID(), toolCallID: "conversion-app-qualification",
                                  scope: .local, workspaceRootURL: root,
                                  cancellation: cancellation)
        // Calls the exact tool execution path. No test-generated DOCX, JS
        // replacement, mock renderer, package writer or network service.
        _ = try await DocumentConvertTool().execute(
            DocumentConversionArguments(inputPath: "bilingual.md", outputPath: "bilingual.docx", format: "docx"),
            context: context)
        XCTAssertEqual(try digest(input), originalHash, "Conversion altered its source")
        XCTAssertGreaterThan(try Data(contentsOf: output).count, 1000)
        let archive = try Archive(url: output, accessMode: .read)
        let collector = ConversionQualificationWordXML()
        try parse(try member("word/document.xml", in: archive), with: collector)
        XCTAssertTrue(collector.text.contains("中文转换验收"))
        XCTAssertTrue(collector.text.contains("春天的山水与城市"))
        XCTAssertTrue(collector.text.contains("English text 12345"))
        XCTAssertTrue(collector.text.contains("苹果 Apple"))
        XCTAssertEqual(collector.tableRows, 3)
        XCTAssertEqual(collector.tableCells, 6)
        XCTAssertFalse(collector.chineseRunFonts.isEmpty, "No Chinese runs parsed")
        XCTAssertTrue(collector.chineseRunFonts.allSatisfy { $0 == "PingFang SC" },
                      "Chinese runs lack the actual installed East Asian family: \(collector.chineseRunFonts)")
        let styles = ConversionQualificationWordXML()
        try parse(try member("word/styles.xml", in: archive), with: styles)
        XCTAssertTrue(styles.fonts.contains("PingFang SC"), "Document defaults lost East Asian fonts")
        try attachFile(input, name: "conversion-input-markdown")
        try attachFile(output, name: "conversion-output-docx")

        let session = OfficeFileSession()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }, "No actual foreground App scene")
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIHostingController(rootView: OfficeDocumentSurface(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        window.rootViewController = host
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        do {
            await session.open(output)
            let deadline = Date().addingTimeInterval(120)
            while !(session.canAct && session.documentActionsReady && session.controller != nil), Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(session.canAct && session.documentActionsReady && session.controller != nil,
                          "Native open/readiness gate failed: \(session.error ?? "no error")")
            let controller = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            // Word's App readiness remains openOnly. Separately observe the
            // production host probe without replacing its business callbacks.
            // Native.mm finishWithStage("visible-render") is emitted only after
            // loaded, sized document + decoded tile OR proven vector paint.
            let paintDeadline = Date().addingTimeInterval(45)
            var renderFacts = OfficeFileSession.hostRenderDiagnostics(controller)
            while !Self.hasObservedPaint(renderFacts), Date() < paintDeadline {
                try await Task.sleep(for: .milliseconds(100))
                renderFacts = OfficeFileSession.hostRenderDiagnostics(controller)
            }
            let paintObserved = Self.hasObservedPaint(renderFacts)
            host.view.layoutIfNeeded()
            let webView = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: controller.view),
                                       "No real native Office web surface")
            XCTAssertGreaterThan(webView.bounds.width, 100)
            XCTAssertGreaterThan(webView.bounds.height, 100)
            // Capture even when the paint wait failed, preserving the actual
            // blank/stalled surface. Primary still checks Chinese glyph shape;
            // the native probe proves paint, not text legibility.
            let config = WKSnapshotConfiguration()
            config.afterScreenUpdates = true
            let officeImage = try await webView.takeSnapshot(configuration: config)
            try saveImage(officeImage, name: "native-office-surface", root: root)
            let windowImage = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try saveImage(windowImage, name: "native-office-window", root: root)
            let manifest: [String: Any] = [
                "schema": 1, "route": "DocumentConvertTool/bundled-WK/DOCX/OfficeFileSession",
                "sourceSHA256": originalHash, "docxSHA256": try digest(output),
                "independentOOXMLPassed": true, "nativeOpenGatePassed": true, "readinessPolicy": "openOnly",
                "nativePaintObserved": paintObserved, "nativeRenderDiagnostics": renderFacts,
                "chineseGlyphVisualReview": "pending-primary-image-review",
                "chineseRuns": collector.chineseRunFonts.count,
                "tableRows": collector.tableRows, "tableCells": collector.tableCells,
                "surfaceWidth": webView.bounds.width, "surfaceHeight": webView.bounds.height,
                "deviceEvidence": "Simulator App; not physical iPad acceptance"
            ]
            let receipt = root.appendingPathComponent("verification.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: receipt, options: .atomic)
            try attachFile(receipt, name: "conversion-verification-visual-review-pending")
            // After evidence, so a bounded missing paint is a real failure with
            // its screenshots/manifest retained; openOnly never fakes a pass.
            await session.release()
            XCTAssertTrue(paintObserved, "Native document never proved decoded tile/vector paint: \(renderFacts)")
        } catch {
            await session.release()
            throw error
        }
    }

    private static func hasObservedPaint(_ facts: [String: String]) -> Bool {
        let truth: (String?) -> Bool = { $0 == "1" || $0 == "true" }
        return facts["stage"] == "visible-render"
            && truth(facts["docLoaded"])
            && !(facts["docType"] ?? "").isEmpty
            && ((Int(facts["decodedTiles"] ?? "") ?? 0) > 0 || truth(facts["vectorRendering"]))
    }

    private func member(_ path: String, in archive: Archive) throws -> Data {
        let entry = try XCTUnwrap(archive[path], "Missing independent OOXML part \(path)")
        var bytes = Data()
        _ = try archive.extract(entry) { bytes.append($0) }
        return bytes
    }

    private func parse(_ bytes: Data, with delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: bytes)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? NSError(domain: "ConversionXML", code: 1) }
    }

    private func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func attachFile(_ url: URL, name: String) throws {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func saveImage(_ image: UIImage, name: String, root: URL) throws {
        let png = try XCTUnwrap(image.pngData())
        try png.write(to: root.appendingPathComponent(name + ".png"), options: .atomic)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Independent reader; does not reuse OfficeDocumentService or converter JS.
private final class ConversionQualificationWordXML: NSObject, XMLParserDelegate {
    private(set) var text = ""
    private(set) var fonts: [String] = []
    private(set) var chineseRunFonts: [String] = []
    private(set) var tableRows = 0
    private(set) var tableCells = 0
    private var inText = false
    private var runText = ""
    private var runFont: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        switch elementName {
        case "w:r": runText = ""; runFont = nil
        case "w:rFonts":
            if let font = attributes["w:eastAsia"] { fonts.append(font); runFont = font }
        case "w:t": inText = true
        case "w:tr": tableRows += 1
        case "w:tc": tableCells += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inText else { return }
        text += string
        runText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:t" { inText = false }
        if elementName == "w:r", runText.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) {
            chineseRunFonts.append(runFont ?? "MISSING")
        }
    }
}
#endif
