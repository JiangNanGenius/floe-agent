// SPDX-License-Identifier: MPL-2.0
// Actual App/native engine and WebKit pixels before pointerup. Synthetic pen
// input proves presentation ordering, not physical Pencil latency or pressure.
#if canImport(UIKit) && canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
import XCTest
import UIKit
import SwiftUI
import WebKit
import FloeDocuments
import FloeOfficeNative
@testable import FloeApp

@MainActor
final class OfficeLiveInkAppQualificationTests: XCTestCase {
    func testWordInkIsVisibleBeforeLiftingPen() async throws { try await exercise("docx") }
    func testWorkbookInkIsVisibleBeforeLiftingPen() async throws { try await exercise("xlsx") }
    func testPresentationInkIsVisibleBeforeLiftingPen() async throws { try await exercise("pptx") }

    private func exercise(_ format: String) async throws {
        guard ProcessInfo.processInfo.environment["FLOE_NATIVE_DRAWING_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in actual App/native live ink qualification")
        }
        executionTimeAllowance = 300
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("live-ink-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Live ink.\(format)")
        switch format {
        case "docx":
            try OfficeDocumentBuilder.createWord(at: source, title: "Live ink", paragraphs: ["ORIGINAL-CONTENT-KEEP"])
        case "xlsx":
            try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [.init(name: "Live ink", rows: [["ORIGINAL-CONTENT-KEEP", "12"], ["Formula", "=B1*2"]])])
        default:
            try OfficeDocumentBuilder.createPresentation(at: source, title: "Live ink", slides: [.init(title: "ORIGINAL-CONTENT-KEEP", bullets: [], notes: "NOTES-KEEP")])
        }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let session = OfficeFileSession()
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: OfficeDocumentSurface(session: session))
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        do {
            await session.open(source)
            try await wait { session.canAct && session.documentActionsReady && session.controller != nil }
            if session.readOnly {
                let entered = await session.requestEditing()
                XCTAssertTrue(entered, session.error ?? "Edit entry rejected")
            }
            try await wait { !session.readOnly && session.canAct && session.documentActionsReady }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await wait {
                let facts = OfficeFileSession.hostRenderDiagnostics(native)
                return facts["stage"] == "visible-render" && facts["docLoaded"] == "1"
            }
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            session.useInkPreferences(workspaceIdentity: root.path, documentKey: source.lastPathComponent)
            let preferences = session.inkPreferences
            let old = preferences.stroke
            defer {
                preferences.setPreset(old.preset); preferences.setColorHex(old.colorHex)
                preferences.setWidthMillimeters(old.widthMillimeters)
                preferences.setTransparencyPercent(old.transparencyPercent)
            }
            preferences.setPreset(.marker)
            preferences.setColorHex("#FF0000")
            preferences.setWidthMillimeters(4)
            try await session.toggleDrawing()
            await session.applyInkPreferences()
            XCTAssertNil(session.inkError)
            try await Task.sleep(for: .milliseconds(150))
            let before = try await snapshot(web, label: "\(format)-before-contact")
            _ = try await web.callAsyncJavaScript(Self.beginAndMove, arguments: [:], in: nil, contentWorld: .page)
            // No pointerup has been sent. Demand actual displayed pixels, not
            // a replay counter or an eventual saved-shape count.
            let during = try await snapshot(web, label: "\(format)-while-pen-is-down")
            let stillDown = try await web.evaluateJavaScript("window.__floeOfficePenState().activeStroke")
            let liveRedDelta = redPixels(during) - redPixels(before)
            _ = try await web.evaluateJavaScript(Self.liftPen)
            let afterLift = try await web.evaluateJavaScript("window.__floeOfficePenState().activeStroke")
            try await Task.sleep(for: .milliseconds(500))
            _ = try await snapshot(web, label: "\(format)-after-lifting-pen")
            await session.release()
            XCTAssertEqual(stillDown as? Bool, true, "The visual assertion must precede pointerup")
            XCTAssertEqual(afterLift as? Bool, false)
            XCTAssertGreaterThan(liveRedDelta, 80,
                "Ink must appear while the pen is moving, before the final vector is committed")
        } catch {
            await session.release()
            throw error
        }
    }

    private func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(150))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(predicate(), "Actual document did not become ready")
        if !predicate() { throw CocoaError(.coderInvalidValue) }
    }

    private func snapshot(_ web: WKWebView, label: String) async throws -> UIImage {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
        let image = try await web.takeSnapshot(configuration: configuration)
        let attachment = XCTAttachment(image: image)
        attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
        return image
    }

    private func redPixels(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let flags = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: flags) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return 0 }
        return stride(from: 0, to: bytes.count, by: 4).reduce(into: 0) { count, offset in
            let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
            if r > 140 && r > g * 3 / 2 && r > b * 3 / 2 { count += 1 }
        }
    }

    private static let beginAndMove = #"""
    const canvas = window.app && window.app.sectionContainer && window.app.sectionContainer.canvas;
    if (!canvas || !window.__floeOfficePenState().drawing) throw new Error('Actual Office pen surface unavailable');
    const rect = canvas.getBoundingClientRect();
    const x = rect.left + rect.width * .38, y = rect.top + rect.height * .65;
    const send = (type, px, py, buttons) => canvas.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, composed: true, pointerType: 'pen', pointerId: 933,
        isPrimary: true, clientX: px, clientY: py, button: 0, buttons, pressure: buttons ? .5 : 0
    }));
    send('pointerdown', x, y, 1);
    for (let i = 1; i <= 12; ++i) {
        send('pointermove', x + i * 8, y + Math.sin(i / 3) * 24, 1);
        await new Promise(resolve => requestAnimationFrame(resolve));
    }
    window.__floeLiveInkQualificationEnd = () => send('pointerup', x + 96, y + Math.sin(4) * 24, 0);
    return true;
    """#
    private static let liftPen = #"""
    window.__floeLiveInkQualificationEnd();
    delete window.__floeLiveInkQualificationEnd;
    true;
    """#
}
#endif
