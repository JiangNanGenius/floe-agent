// SPDX-License-Identifier: MPL-2.0
// Real pinned-engine export on a private runtime-supplied workbook. No user
// attachment bytes or identifiers are bundled. Opt in only on the canonical
// serialized iPad host with FLOE_OFFICE_EXPORT_QUALIFICATION=1.
#if canImport(UIKit) && canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
import XCTest
import Foundation
import SwiftUI
import UIKit
import WebKit
import PDFKit
import FloeCore
import FloeDocuments
import FloeTools
import FloeOfficeNative
@testable import FloeApp

@MainActor
final class OfficePDFExportAcceptanceTests: XCTestCase {
    private func input() throws -> (URL, String, URL) {
        let environment = ProcessInfo.processInfo.environment
        guard environment["FLOE_OFFICE_EXPORT_QUALIFICATION"] == "1",
              let encoded = environment["FLOE_OFFICE_PRIVATE_WORKBOOK_BASE64"],
              let expected = environment["FLOE_OFFICE_PRIVATE_WORKBOOK_SHA256"] else {
            throw XCTSkip("Requires explicit private workbook export qualification input")
        }
        executionTimeAllowance = 600
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertLessThan(data.count, 512 * 1024)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OfficePDFProof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("provided.xlsx")
        try data.write(to: source, options: .atomic)
        XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), expected)
        return (source, expected, root)
    }

    func testRealWorkbookScopeAndLandscapeFitProduceActualDifferentPDFs() async throws {
        let (source, sha, root) = try input()
        // Keep private output and native recovery input when the engine cannot
        // close. Ordinary completed evidence is attached before cleanup.
        do {
            let baseline = try await OfficePDFExportService.export(.init(
                sourceURL: source, sourceSHA256: sha, formatExtension: "xlsx",
                plan: .init(), ownedDirectory: root))
            XCTAssertEqual(baseline.pageCount, 2, "Actual supplied source prints two horizontal A4 slices")
            XCTAssertTrue(baseline.pageSizes.allSatisfy { $0.height > $0.width })
            attach(baseline.pdfURL, "provided-original-settings.pdf")

            let fitted = try await OfficePDFExportService.export(.init(
                sourceURL: source, sourceSHA256: sha, formatExtension: "xlsx",
                plan: .init(scope: .allVisibleSheets, pageSetup: .init(
                    paper: .a4, orientation: .landscape, fit: .fitToOnePage)), ownedDirectory: root))
            XCTAssertEqual(fitted.pageCount, 1)
            XCTAssertEqual(fitted.pageSizes.count, 1)
            XCTAssertEqual(fitted.pageSizes[0].width, 841.89, accuracy: 3)
            XCTAssertEqual(fitted.pageSizes[0].height, 595.28, accuracy: 3)
            XCTAssertEqual(fitted.appliedPrintPlan?.drawingPartsPreserved, true)
            XCTAssertFalse(fitted.appliedPrintPlan?.drawingPartPaths.isEmpty ?? true)
            attach(fitted.pdfURL, "provided-landscape-one-page.pdf")
            let fullPixels = try raster(fitted.pdfURL)
            XCTAssertGreaterThan(fullPixels.yellow, 500, "Full-content export must include off-cell highlighter ink")
            attach(fullPixels.png, "provided-landscape-one-page.png")

            let sheets = try OfficeRegionExport.workbookSheets(sourceURL: source, expectedSHA256: sha)
            let sheet = try XCTUnwrap(sheets.first(where: \.isVisible))
            let cells = try await OfficePDFExportService.export(.init(
                sourceURL: source, sourceSHA256: sha, formatExtension: "xlsx",
                plan: .init(scope: .sheet(name: sheet.name, cellRange: "A1:B1"),
                            pageSetup: .init(paper: .a4, orientation: .landscape, fit: .fitToOnePage)),
                ownedDirectory: root))
            XCTAssertEqual(cells.pageCount, 1)
            let scopedPixels = try raster(cells.pdfURL)
            XCTAssertEqual(scopedPixels.yellow, 0, "A1:B1 must exclude the off-range ink")
            let savedFields = try OfficeDocumentService.inspect(url: source).fields
            for reference in ["A1", "B1"] {
                let field = try XCTUnwrap(savedFields.first(where: {
                    $0.id == sheet.partPath + "|c|" + reference
                }))
                XCTAssertFalse(field.text.isEmpty)
                XCTAssertTrue(scopedPixels.text.contains(field.text), "The selected cell's actual text must survive export")
            }
            attach(cells.pdfURL, "provided-cells-only.pdf")
            attach(scopedPixels.png, "provided-cells-only.png")
            XCTAssertNotEqual(fitted.pdfSHA256, cells.pdfSHA256)
            try await inspectActualSystemPrintPanel(pdf: fitted.pdfURL)
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), sha)
            let quarantined = await OfficeAutomaticExecutionGate.shared.isQuarantined
            XCTAssertFalse(quarantined)
            try FileManager.default.removeItem(at: root)
        } catch {
            if !(await OfficeAutomaticExecutionGate.shared.isQuarantined) {
                try? FileManager.default.removeItem(at: root)
            }
            throw error
        }
    }

    func testNativeToolbarPrintOpensSharedOptionsAndSavedSource() async throws {
        let (source, sha, root) = try input()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let session = OfficeFileSession()
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let environment = AppEnvironment.preview()
        window.rootViewController = UIHostingController(rootView: NavigationStack {
            OfficeDocumentEditorView(relativePath: "provided.xlsx", session: session,
                                     onSaved: nil, requestsEditingOnAppear: false)
                .environmentObject(environment)
        })
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        do {
            await session.open(source)
            try await wait("actual Office document ready") { session.documentActionsReady }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            XCTAssertTrue(native.responds(to: NSSelectorFromString("setOnPrintRequested:")))
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            let generation = session.printRequestGeneration
            // This is the exact native message sent by the existing engine's
            // Print toolbar. It must open options BEFORE any PDF is generated.
            _ = try await web.evaluateJavaScript("window.webkit.messageHandlers.lok.postMessage('PRINT')")
            try await wait("native PRINT routed to app options") { session.printRequestGeneration == generation + 1 }
            try await wait("options sheet mounted") { window.rootViewController?.presentedViewController != nil }
            try await Task.sleep(for: .seconds(2))
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "native-toolbar-print-options-ipad"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), sha)
            await session.release()
            try FileManager.default.removeItem(at: root)
        } catch {
            await session.release()
            throw error
        }
    }

    func testChoicesKeepCurrentSheetIdentityAndStrictPages() throws {
        var choices = OfficePDFExportChoices()
        choices.scope = .currentSheet
        XCTAssertThrowsError(try choices.plan(activeSheetName: nil))
        let named = try choices.plan(activeSheetName: "Second")
        XCTAssertEqual(named.scope, .sheet(name: "Second", cellRange: nil))
        choices.pages = "2-1"
        XCTAssertThrowsError(try choices.plan(activeSheetName: "Second"))
        choices.pages = "1,3-4"
        XCTAssertEqual(try choices.plan(activeSheetName: "Second").pageRange?.normalizedPages, [1,3,4])
    }

    private func wait(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(120)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(condition(), description)
        if !condition() { throw CocoaError(.coderInvalidValue) }
    }

    private func attach(_ url: URL, _ name: String) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func attach(_ data: Data, _ name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func inspectActualSystemPrintPanel(pdf: URL) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive }))
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        // Instantiate the production presenter, with the exact generated
        // file. UIKit still owns AirPrint; no printer output is claimed.
        let presenter = OfficePreparedPDFPrintSheet.Presenter(url: pdf) { _ in }
        window.rootViewController = presenter
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        defer {
            UIPrintInteractionController.shared.dismiss(animated: false)
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(UIPrintInteractionController.shared.printingItem as? URL, pdf)
        XCTAssertEqual(UIPrintInteractionController.shared.printInfo?.orientation, .landscape)
        XCTAssertNotNil(presenter.presentedViewController, "UIKit must actually present its print panel")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "actual-landscape-pdf-system-print-panel"
        screenshot.lifetime = .keepAlways; add(screenshot)
    }

    private func raster(_ url: URL) throws -> (png: Data, yellow: Int, text: String) {
        try PDFKitGate.run {
            try withPDFExceptionGuard {
                let pdf = try XCTUnwrap(PDFDocument(url: url))
                let page = try XCTUnwrap(pdf.page(at: 0))
                let bounds = page.bounds(for: .cropBox)
                let width = 1200
                let height = Int(ceil(CGFloat(width) * bounds.height / bounds.width))
                let bytesPerRow = width * 4
                var bytes = [UInt8](repeating: 255, count: bytesPerRow * height)
                let png: Data = try bytes.withUnsafeMutableBytes { raw in
                    let context = try XCTUnwrap(CGContext(data: raw.baseAddress, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                    context.setFillColor(UIColor.white.cgColor)
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                    context.translateBy(x: 0, y: CGFloat(height))
                    context.scaleBy(x: CGFloat(width) / bounds.width, y: -CGFloat(width) / bounds.width)
                    context.translateBy(x: -bounds.minX, y: -bounds.minY)
                    page.draw(with: .cropBox, to: context)
                    let image = try XCTUnwrap(context.makeImage())
                    return try XCTUnwrap(UIImage(cgImage: image).pngData())
                }
                var yellow = 0
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    if bytes[offset] > 230 && bytes[offset + 1] > 180 && bytes[offset + 2] < 220 { yellow += 1 }
                }
                return (png, yellow, pdf.string ?? "")
            }
        }
    }
}
#endif
