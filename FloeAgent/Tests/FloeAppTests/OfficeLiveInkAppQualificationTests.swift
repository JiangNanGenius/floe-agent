// SPDX-License-Identifier: MPL-2.0
// Actual App/native engine and WebKit pixels before pointerup. Synthetic pen
// input proves presentation ordering, not physical Pencil latency or pressure.
#if canImport(UIKit) && canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
import XCTest
import UIKit
import SwiftUI
import WebKit
import ZIPFoundation
import FloeDocuments
import FloeCore
import FloeNotes
import FloeOfficeNative
@testable import FloeApp

@MainActor
final class OfficeLiveInkAppQualificationTests: XCTestCase {
    func testWordInkIsVisibleBeforeLiftingPen() async throws { try await exercise("docx") }
    func testWorkbookInkIsVisibleBeforeLiftingPen() async throws { try await exercise("xlsx") }
    func testPresentationInkIsVisibleBeforeLiftingPen() async throws { try await exercise("pptx") }

    func testWordSavedInkIsInNotesCover() async throws { try await exercise("docx", requireLivePresentation: false) }
    func testWorkbookSavedInkIsInNotesCover() async throws { try await exercise("xlsx", requireLivePresentation: false) }
    func testPresentationSavedInkIsInNotesCover() async throws { try await exercise("pptx", requireLivePresentation: false) }

    func testWordPinchInDrawingModeThenContinueWriting() async throws {
        try await exercise("docx", navigateBeforeDrawing: true)
    }
    func testWorkbookPinchInDrawingModeThenContinueWriting() async throws {
        try await exercise("xlsx", navigateBeforeDrawing: true)
    }
    func testPresentationPinchInDrawingModeThenContinueWriting() async throws {
        try await exercise("pptx", navigateBeforeDrawing: true)
    }

    private func exercise(_ format: String, requireLivePresentation: Bool = true,
                          navigateBeforeDrawing: Bool = false) async throws {
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
            if navigateBeforeDrawing {
                let navigation = try await web.callAsyncJavaScript(Self.pinch, arguments: [:],
                    in: nil, contentWorld: .page)
                let facts = try XCTUnwrap(navigation as? [String: Any])
                let attachment = XCTAttachment(string: String(describing: facts))
                attachment.name = "\(format)-actual-touch-pinch"; attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertNotEqual(facts["before"] as? Double, facts["after"] as? Double,
                                  "Touch handlers must change the real frontend zoom")
                XCTAssertEqual(facts["drawing"] as? Bool, true)
                XCTAssertEqual(facts["activeStroke"] as? Bool, false)
                XCTAssertEqual(facts["strokes"] as? Int, 0, "Fingers must not become pen contacts")
            }
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
            let saved = await session.saveInPlace()
            guard saved else { throw CocoaError(.fileWriteUnknown) }
            XCTAssertEqual(try vectorCount(in: source), 1,
                           "Only the Pencil contact may add a saved vector; touch navigation must not add ink")
            let postSaveState = try await web.evaluateJavaScript(#"""
            (() => ({ latch: window.floeModifiedSinceCommit ?? null,
                modified: app.map.stateChangeHandler.getItemValue('.uno:ModifiedStatus') ?? null,
                active: window.__floeOfficePenState().activeStroke }))()
            """#)
            let saveStateAttachment = XCTAttachment(string: String(describing: postSaveState))
            saveStateAttachment.name = "\(format)-post-save-state"; saveStateAttachment.lifetime = .keepAlways
            add(saveStateAttachment)
            let sourceHash = try FloeDigest.sha256Hex(ofFileAt: source)
            let pdf = try await session.exportCommittedCoverPDF(expectedSHA256: sourceHash)
            defer { try? FileManager.default.removeItem(at: pdf) }
            let coverData = try await Task.detached {
                try OfficeSavedCoverRenderer.firstPageData(at: pdf)
            }.value
            let generated = try XCTUnwrap(UIImage(data: coverData))
            let coverAttachment = XCTAttachment(image: generated)
            coverAttachment.name = "\(format)-saved-engine-first-page"; coverAttachment.lifetime = .keepAlways
            add(coverAttachment)
            let store = try NotesStore(root: root.appendingPathComponent("notes-store"))
            let imported = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
            let document = try await store.create(imported)
            let coverResource = try await NotesCoverImageProcessor.importCover(data: coverData, store: store)
            let covered = try await store.cacheOfficePreview(documentID: document.id,
                sourceResourceID: document.officeResourceID!, previewResourceID: coverResource,
                expectedRevision: document.revision)
            let outcome = await NotesDocumentCoverService.render(document: covered, store: store,
                size: CGSize(width: 320, height: 420), maximumSourceBytes: 128 * 1_024 * 1_024)
            let cardImage = try XCTUnwrap(outcome.image)
            let cardAttachment = XCTAttachment(image: cardImage)
            cardAttachment.name = "\(format)-notes-card-ink"; cardAttachment.lifetime = .keepAlways
            add(cardAttachment)
            await session.release()
            XCTAssertEqual(stillDown as? Bool, true, "The visual assertion must precede pointerup")
            XCTAssertEqual(afterLift as? Bool, false)
            if requireLivePresentation {
                XCTAssertGreaterThan(liveRedDelta, 80,
                    "Ink must appear while the pen is moving, before the final vector is committed")
            }
            XCTAssertGreaterThan(redPixels(generated), 40, "The saved engine preview must include the Office vector ink")
            XCTAssertEqual(outcome.source, .officeSavedPreview)
            XCTAssertGreaterThan(redPixels(cardImage), 10, "The actual Notes cover renderer must retain the saved ink")
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

    private func vectorCount(in url: URL) throws -> Int {
        let archive = try Archive(url: url, accessMode: .read)
        let counter = OfficeLiveInkVectorCounter()
        for entry in archive where entry.path == "word/document.xml"
            || entry.path.hasPrefix("xl/drawings/drawing")
            || entry.path.hasPrefix("ppt/slides/slide") {
            guard entry.path.hasSuffix(".xml") else { continue }
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false
            parser.shouldProcessNamespaces = true; parser.delegate = counter
            guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
        }
        return counter.count
    }

    /// Synthetic TouchEvents enter the real canvas handlers, beginning with
    /// one finger as required by CanvasSectionContainer. No direct zoom call,
    /// handler replacement or edit-state reset is allowed in this stimulus.
    private static let pinch = #"""
    const canvas = app.sectionContainer.canvas;
    const rect = canvas.getBoundingClientRect();
    const layout = app.activeDocument.activeLayout;
    const anchor = app.sectionContainer.getDocumentAnchorSection();
    const origin = app.activeDocument.fileSize.clone(); origin.pX=0; origin.pY=0;
    const end = app.activeDocument.fileSize.clone();
    const left = Math.max(0, anchor.myTopLeft[0], layout.documentToViewX(origin));
    const top = Math.max(0, anchor.myTopLeft[1], layout.documentToViewY(origin));
    const right = Math.min(canvas.width, anchor.myTopLeft[0]+anchor.size[0], layout.documentToViewX(end));
    const bottom = Math.min(canvas.height, anchor.myTopLeft[1]+anchor.size[1], layout.documentToViewY(end));
    const x = rect.left+(left+right)*.5*rect.width/canvas.width;
    const y = rect.top+(top+bottom)*.5*rect.height/canvas.height;
    const before = app.map.getZoom();
    const frame = () => new Promise(resolve => requestAnimationFrame(resolve));
    const touch = (id, offset) => new Touch({identifier:id,target:canvas,
        clientX:x+offset,clientY:y,pageX:x+offset+window.scrollX,pageY:y+window.scrollY});
    const send = (type, touches, changed) => canvas.dispatchEvent(new TouchEvent(type,
        {bubbles:true,cancelable:true,composed:true,touches,targetTouches:touches,changedTouches:changed}));
    let a=touch(971,-30), b=touch(972,30);
    send('touchstart',[a],[a]); await frame();
    send('touchstart',[a,b],[b]); await frame();
    send('touchmove',[a,b],[a,b]); await frame();
    a=touch(971,-60); b=touch(972,60);
    send('touchmove',[a,b],[a,b]); await frame();
    send('touchend',[],[a,b]);
    for (let i=0;i<30 && app.map.getZoom()===before;i++) await frame();
    const state=window.__floeOfficePenState();
    return {before,after:app.map.getZoom(),drawing:state.drawing,
        activeStroke:state.activeStroke,strokes:state.strokes};
    """#

    private static let beginAndMove = #"""
    const canvas = window.app && window.app.sectionContainer && window.app.sectionContainer.canvas;
    if (!canvas || !window.__floeOfficePenState().drawing) throw new Error('Actual Office pen surface unavailable');
    const layout = app.activeDocument && app.activeDocument.activeLayout;
    const size = app.activeDocument && app.activeDocument.fileSize;
    const section = app.sectionContainer.getDocumentAnchorSection();
    if (!layout || !size || !section) throw new Error('Actual document geometry unavailable');
    const rect = canvas.getBoundingClientRect();
    const scaleX = rect.width / canvas.width, scaleY = rect.height / canvas.height;
    const origin = size.clone(); origin.pX = 0; origin.pY = 0;
    const end = size.clone();
    const dx1 = layout.documentToViewX(origin), dy1 = layout.documentToViewY(origin);
    const dx2 = layout.documentToViewX(end), dy2 = layout.documentToViewY(end);
    const x1 = rect.left + Math.max(0, section.myTopLeft[0], Math.min(dx1, dx2)) * scaleX;
    const y1 = rect.top + Math.max(0, section.myTopLeft[1], Math.min(dy1, dy2)) * scaleY;
    const x2 = rect.left + Math.min(canvas.width, section.myTopLeft[0] + section.size[0], Math.max(dx1, dx2)) * scaleX;
    const y2 = rect.top + Math.min(canvas.height, section.myTopLeft[1] + section.size[1], Math.max(dy1, dy2)) * scaleY;
    if (![x1,y1,x2,y2].every(Number.isFinite) || x2-x1 < 120 || y2-y1 < 120)
        throw new Error('No visible document drawing area');
    const x = x1 + (x2-x1)*.35, y = y1 + (y2-y1)*.6;
    const length = Math.min(96,(x2-x1)*.25), amplitude = Math.min(24,(y2-y1)*.08);
    const send = (type, px, py, buttons) => canvas.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, composed: true, pointerType: 'pen', pointerId: 933,
        isPrimary: true, clientX: px, clientY: py, button: 0, buttons, pressure: buttons ? .5 : 0
    }));
    send('pointerdown', x, y, 1);
    for (let i = 1; i <= 12; ++i) {
        send('pointermove', x + i * length / 12, y + Math.sin(i / 3) * amplitude, 1);
        await new Promise(resolve => requestAnimationFrame(resolve));
    }
    window.__floeLiveInkQualificationEnd = () => send('pointerup', x + length, y + Math.sin(4) * amplitude, 0);
    return true;
    """#
    private static let liftPen = #"""
    window.__floeLiveInkQualificationEnd();
    delete window.__floeLiveInkQualificationEnd;
    true;
    """#
}

private final class OfficeLiveInkVectorCounter: NSObject, XMLParserDelegate {
    var count = 0
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "custGeom", namespaceURI == "http://schemas.openxmlformats.org/drawingml/2006/main"
            || namespaceURI == "http://purl.oclc.org/ooxml/drawingml/main" { count += 1 }
    }
}
#endif
