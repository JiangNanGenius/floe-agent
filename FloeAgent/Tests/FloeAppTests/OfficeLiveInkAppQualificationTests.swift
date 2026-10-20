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
import FloeTools
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
    func testWordRapidContactsStayVisibleAndSaveIndependently() async throws {
        try await exercise("docx", contactCount: 3)
    }

    /// Actual Notes view → its production commit closure → notes.edit → new
    /// immutable resource. This supplies deterministic recognized numbers;
    /// the separate sender proof verifies how the model receives the image.
    func testNotesAssistantCreatesCellsWithoutLosingLiveInk() async throws {
        guard ProcessInfo.processInfo.environment["FLOE_NATIVE_DRAWING_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in actual Notes/native save qualification")
        }
        executionTimeAllowance = 450
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-live-write-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Numbers.xlsx")
        try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [
            .init(name: "Numbers", rows: [["11111", "123456"], ["KEEP", "=B1*2"]])
        ])
        let store = try NotesStore(root: root.appendingPathComponent("store"))
        let imported = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
        let document = try await store.create(imported)
        let conversationID = UUID()
        try await store.bindAssistant(conversationID: conversationID, documentID: document.id, canEdit: true)
        await NotesRepository.shared.setStoreOverride(store)
        defer { Task { await NotesRepository.shared.setStoreOverride(nil) } }
        let notes = NotesSession()
        await notes.open(using: store)
        let selected = await notes.select(document)
        XCTAssertTrue(selected)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView:
            LiveNotesOfficeQualificationHost(session: notes).environmentObject(AppEnvironment.preview()))
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        try await wait {
            let bound = NotesOfficeLiveBinding.boundSession(documentID: document.id, fileName: document.officeFileName)
            return bound?.canAct == true && bound?.documentActionsReady == true
        }
        let office = try XCTUnwrap(NotesOfficeLiveBinding.boundSession(documentID: document.id, fileName: document.officeFileName))
        do {
            if office.readOnly {
                let entered = await office.requestEditing()
                XCTAssertTrue(entered, office.error ?? "Edit entry refused")
            }
            let native = try XCTUnwrap(office.controller as? FloeOfficeNativeViewController)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            try await wait { OfficeFileSession.hostRenderDiagnostics(native)["stage"] == "visible-render" }
            office.useInkPreferences(workspaceIdentity: root.path, documentKey: "Numbers.xlsx")
            let preferences = office.inkPreferences
            let old = preferences.stroke
            defer {
                preferences.setPreset(old.preset); preferences.setColorHex(old.colorHex)
                preferences.setWidthMillimeters(old.widthMillimeters)
                preferences.setTransparencyPercent(old.transparencyPercent)
            }
            preferences.setPreset(.marker); preferences.setColorHex("#FF0000")
            preferences.setWidthMillimeters(4)
            try await office.toggleDrawing()
            await office.applyInkPreferences()
            _ = try await web.callAsyncJavaScript(Self.beginAndMove, arguments: ["contactIndex": 0], in: nil, contentWorld: .page)
            _ = try await snapshot(web, label: "notes-write-active-contact")
            let originalID = try XCTUnwrap(document.officeResourceID)
            let originalResource = try await store.resourceURL(originalID)
            let originalSHA = try FloeDigest.sha256Hex(ofFileAt: originalResource)
            let runID = UUID()
            func edit(_ baseline: NoteDocument, sha: String, call: String) async throws -> ToolExecutionOutput {
                var operations: [[String: Any]] = (1...15).map {
                    ["action": "updateOfficeText", "fieldID": "xl/worksheets/sheet1.xml|c|C\($0)",
                     "text": String($0), "createCell": true]
                }
                operations.append(["action": "updateOfficeText", "fieldID": "xl/worksheets/sheet1.xml|c|C16",
                                   "text": "=SUM(C1:C15)", "createCell": true])
                let data = try JSONSerialization.data(withJSONObject: [
                    "documentID": document.id.uuidString, "expectedRevision": baseline.revision,
                    // Match the schema-valid payload seen on Build 282: no
                    // optional batch title. Exercise validation AND the real
                    // mounted editor/save/rewrite chain with that payload.
                    "expectedSHA256": sha, "operations": operations
                ])
                let args = try JSONDecoder().decode(NotesEditTool.Arguments.self, from: data)
                let tool = NotesEditTool()
                try tool.validate(args)
                return try await tool.execute(args, context: ToolContext(runID: runID, toolCallID: call,
                    workspaceRootURL: root, cancellation: CancellationToken(), conversationID: conversationID))
            }
            do {
                _ = try await edit(document, sha: originalSHA, call: "active-contact")
                XCTFail("An active pen contact must refuse a rewrite")
            } catch {
                let stillActive = try await web.evaluateJavaScript("window.__floeOfficePenState().activeStroke") as? Bool
                XCTAssertEqual(stillActive, true)
                let untouched = try await store.document(document.id)
                XCTAssertEqual(untouched.officeResourceID, originalID)
                XCTAssertEqual(untouched.revision, document.revision)
            }
            _ = try await web.evaluateJavaScript(Self.liftPen)
            try await Task.sleep(for: .milliseconds(750))
            let first = try await edit(document, sha: originalSHA, call: "commit-ink")
            XCTAssertTrue(first.summary.contains("liveContentCommitted"), first.summary)
            let inkDocument = try await store.document(document.id)
            let inkResource = try await store.resourceURL(XCTUnwrap(inkDocument.officeResourceID))
            XCTAssertEqual(try vectorCount(in: inkResource), 1)
            let stagedInk = try NotesOfficeResourceStaging.stage(source: inkResource, fileExtension: "xlsx")
            defer { NotesOfficeResourceStaging.remove(stagedInk) }
            let inkSnapshot = try OfficeDocumentService.inspect(url: stagedInk)
            XCTAssertFalse(inkSnapshot.fields.contains { $0.id.hasSuffix("|c|C1") }, "Ink commit must not claim a cell edit")
            try await wait { notes.document?.revision == inkDocument.revision && office.canAct }
            let saved = try await edit(inkDocument, sha: XCTUnwrap(inkSnapshot.sha256), call: "write-cells")
            let resultAttachment = XCTAttachment(string: saved.summary)
            resultAttachment.name = "notes-write-receipt"; resultAttachment.lifetime = .keepAlways; add(resultAttachment)
            let finalDocument = try await store.document(document.id)
            XCTAssertGreaterThan(finalDocument.revision, inkDocument.revision)
            let finalResource = try await store.resourceURL(XCTUnwrap(finalDocument.officeResourceID))
            let stagedFinal = try NotesOfficeResourceStaging.stage(source: finalResource, fileExtension: "xlsx")
            defer { NotesOfficeResourceStaging.remove(stagedFinal) }
            let final = try OfficeDocumentService.inspect(url: stagedFinal)
            let fields = Dictionary(uniqueKeysWithValues: final.fields.map { ($0.id, $0.text) })
            for number in 1...15 { XCTAssertEqual(fields["xl/worksheets/sheet1.xml|c|C\(number)"], String(number)) }
            XCTAssertEqual(fields["xl/worksheets/sheet1.xml|c|C16"], "=SUM(C1:C15)")
            for original in inkSnapshot.fields { XCTAssertEqual(fields[original.id], original.text) }
            XCTAssertEqual(try vectorCount(in: finalResource), 1)
            try await wait { notes.document?.revision == finalDocument.revision && office.canAct }
            let refreshDeadline = ContinuousClock.now.advanced(by: .seconds(30))
            var mountedSHA: String?
            repeat {
                if office.canAct { mountedSHA = try? await office.liveEngineStatus().sha256 }
                if mountedSHA == final.sha256 { break }
                try await Task.sleep(for: .milliseconds(100))
            } while ContinuousClock.now < refreshDeadline
            XCTAssertEqual(mountedSHA, final.sha256, "The same Notes editor must reopen the newly committed resource")
            let refreshedNative = try XCTUnwrap(office.controller as? FloeOfficeNativeViewController)
            let refreshedWeb = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: refreshedNative.view))
            _ = try await snapshot(refreshedWeb, label: "notes-write-after-resource-refresh")
            let calculatedCopy = try await office.exportDocument(format: "xlsx")
            defer { try? FileManager.default.removeItem(at: calculatedCopy) }
            let calculated = try OfficeOutputSnapshot.capture(url: calculatedCopy)
            let sum = try XCTUnwrap(calculated.formulaCells.first { $0.cell == "C16" })
            XCTAssertEqual(sum.formula, "SUM(C1:C15)")
            XCTAssertEqual(sum.cachedValue.flatMap(Double.init), 120)
            XCTAssertNil(sum.errorCode)
            XCTAssertEqual(try vectorCount(in: calculatedCopy), 1)
            let enginePackage = XCTAttachment(contentsOfFile: calculatedCopy)
            enginePackage.name = "notes-write-engine-calculated-120"; enginePackage.lifetime = .keepAlways; add(enginePackage)
            let package = XCTAttachment(contentsOfFile: finalResource)
            package.name = "notes-write-saved-workbook"; package.lifetime = .keepAlways; add(package)
            await office.release()
        } catch {
            await office.release()
            throw error
        }
    }

    private func exercise(_ format: String, requireLivePresentation: Bool = true,
                          navigateBeforeDrawing: Bool = false, contactCount: Int = 1) async throws {
        guard ProcessInfo.processInfo.environment["FLOE_NATIVE_DRAWING_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in actual App/native live ink qualification")
        }
        XCTAssertTrue(UIView.areAnimationsEnabled,
                      "Live preview acceptance requires production UIKit animation timing")
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
            var contacts: [(down: Bool?, lifted: Bool?, redDelta: Int, minimumLinePixels: Int)] = []
            for index in 0..<contactCount {
                let before = try await snapshot(web, label: "\(format)-\(index)-before-contact")
                _ = try await web.callAsyncJavaScript(Self.beginAndMove,
                    arguments: ["contactIndex": index], in: nil, contentWorld: .page)
                // No pointerup has been sent. Demand actual displayed pixels,
                // not a replay counter or an eventual saved-shape count.
                var duringFrames: [UIImage] = []
                for frame in 0..<3 {
                    duringFrames.append(try await snapshot(web,
                        label: "\(format)-\(index)-while-pen-is-down-\(frame)"))
                    let frameStillDown = try await web.evaluateJavaScript(
                        "window.__floeOfficePenState().activeStroke") as? Bool
                    XCTAssertEqual(frameStillDown, true,
                                   "Every preview frame must be captured before pointerup")
                }
                var minimumLinePixels = 80
                if requireLivePresentation {
                    let rawWidth = try await web.evaluateJavaScript(
                        "window.__floeOfficePenPreview().style.cssPx")
                    let cssWidth = try XCTUnwrap(rawWidth as? Double)
                    let pixelsWide = try XCTUnwrap(duringFrames.first?.cgImage?.width)
                    let pixelScale = Double(pixelsWide) / Double(web.bounds.width)
                    guard cssWidth.isFinite, cssWidth > 0,
                          pixelScale.isFinite, pixelScale > 0 else {
                        throw CocoaError(.coderInvalidValue)
                    }
                    // A round starting cap alone must not qualify as a line.
                    // Allow antialiasing and overlapping local/core caps.
                    let capRadius = cssWidth * pixelScale / 2 + 1
                    minimumLinePixels = max(80,
                        Int(ceil(2.5 * Double.pi * capRadius * capRadius)))
                }
                try await attachLiveDiagnostics(web, label: "\(format)-\(index)-live-geometry")
                let stillDown = try await web.evaluateJavaScript("window.__floeOfficePenState().activeStroke")
                _ = try await web.evaluateJavaScript(Self.liftPen)
                let afterLift = try await web.evaluateJavaScript("window.__floeOfficePenState().activeStroke")
                contacts.append((stillDown as? Bool, afterLift as? Bool,
                                 duringFrames.map { redPixels($0) - redPixels(before) }.min() ?? 0,
                                 minimumLinePixels))
                // The next contact starts without an artificial core-paint
                // sleep. Actual snapshot and frame costs are still present;
                // this does not claim a physical stylus sampling rate.
            }
            try await Task.sleep(for: .milliseconds(750))
            _ = try await snapshot(web, label: "\(format)-after-lifting-pen")
            try await attachLiveDiagnostics(web, label: "\(format)-after-lifting-geometry")
            let pendingPreview = try await web.evaluateJavaScript(
                "window.__floeOfficePenPreview ? window.__floeOfficePenPreview().pending : -1") as? Int
            let position = try await web.evaluateJavaScript(Self.committedInkPosition) as? [String: Any]
            let positionAttachment = XCTAttachment(string: String(describing: position))
            positionAttachment.name = "\(format)-raw-pen-versus-committed-paint"
            positionAttachment.lifetime = .keepAlways; add(positionAttachment)
            let saved = await session.saveInPlace()
            guard saved else { throw CocoaError(.fileWriteUnknown) }
            let packageAttachment = XCTAttachment(contentsOfFile: source)
            packageAttachment.name = "\(format)-actual-saved-vector-package"
            packageAttachment.lifetime = .keepAlways; add(packageAttachment)
            XCTAssertEqual(try vectorCount(in: source), contactCount,
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
            let pdfAttachment = XCTAttachment(contentsOfFile: pdf)
            pdfAttachment.name = "\(format)-actual-engine-export"
            pdfAttachment.lifetime = .keepAlways; add(pdfAttachment)
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
            if requireLivePresentation {
                XCTAssertGreaterThan(position?["pixels"] as? Int ?? 0, 80,
                    "The committed canvas must contain this stroke independently of its temporary overlay")
                XCTAssertLessThanOrEqual(position?["driftX"] as? Double ?? .infinity, 4,
                    "Committed ink must remain under the original pen path horizontally")
                XCTAssertLessThanOrEqual(position?["driftY"] as? Double ?? .infinity, 4,
                    "Committed ink must remain under the original pen path vertically; clearing an offset preview is insufficient")
                XCTAssertEqual(pendingPreview, 0,
                               "Visible opaque ink must hand off promptly; an old preview must not double the saved stroke")
            }
            for (index, contact) in contacts.enumerated() {
                XCTAssertEqual(contact.down, true, "Contact \(index): visual assertion must precede pointerup")
                XCTAssertEqual(contact.lifted, false)
                if requireLivePresentation {
                    XCTAssertGreaterThan(contact.redDelta, contact.minimumLinePixels,
                        "Contact \(index): every pre-lift frame must contain a line beyond its starting cap")
                }
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

    private func attachLiveDiagnostics(_ web: WKWebView, label: String) async throws {
        let value = try await web.evaluateJavaScript(#"""
        (() => {
            const app=window.app, c=app.sectionContainer.canvas, r=c.getBoundingClientRect();
            const a=app.sectionContainer.getDocumentAnchorSection();
            const svg=document.querySelector('#floe-ink-live-preview svg');
            return {pen:window.__floeOfficePenState(),
                preview:window.__floeOfficePenPreview ? window.__floeOfficePenPreview() : null,
                viewport:{width:innerWidth,height:innerHeight,scrollX,scrollY,
                    visualScale:visualViewport?.scale ?? null},
                canvas:{width:c.width,height:c.height,left:r.left,top:r.top,widthCSS:r.width,heightCSS:r.height},
                layout:{name:app.activeDocument.activeLayout.constructor.name,
                    zoom:app.map.getZoom(),dpiScale:app.dpiScale,twipsToPixels:app.twipsToPixels,
                    anchor:a.myTopLeft,size:a.size},
                paths:svg ? Array.from(svg.children).map(p=>({d:p.getAttribute('d'),
                    color:p.getAttribute('stroke'),width:p.getAttribute('stroke-width'),
                    opacity:p.getAttribute('stroke-opacity')})) : []};
        })()
        """#)
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(value), options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = label; attachment.lifetime = .keepAlways; add(attachment)
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
    const offset = typeof contactIndex === 'number' ? contactIndex * .15 : 0;
    const x = x1 + (x2-x1)*(.35+offset), y = y1 + (y2-y1)*.6;
    const length = Math.min(96,(x2-x1)*.25), amplitude = Math.min(24,(y2-y1)*.08);
    if (contactIndex === 0) {
        window.__floeLiveInkRawBounds = [Infinity,Infinity,-Infinity,-Infinity];
        window.__floeLiveInkBase = {width:canvas.width,height:canvas.height,
            rgba:canvas.getContext('2d').getImageData(0,0,canvas.width,canvas.height).data};
    }
    const include = (px,py) => {
        const b=window.__floeLiveInkRawBounds;
        b[0]=Math.min(b[0],px); b[1]=Math.min(b[1],py);
        b[2]=Math.max(b[2],px); b[3]=Math.max(b[3],py);
    };
    const send = (type, px, py, buttons) => {
        if (buttons) include(px,py);
        return canvas.dispatchEvent(new PointerEvent(type, {
        bubbles: true, cancelable: true, composed: true, pointerType: 'pen', pointerId: 933,
        isPrimary: true, clientX: px, clientY: py, button: 0, buttons, pressure: buttons ? .5 : 0
    })); };
    send('pointerdown', x, y, 1);
    for (let i = 1; i <= 12; ++i) {
        send('pointermove', x + i * length / 12, y + Math.sin(i / 3) * amplitude, 1);
        await new Promise(resolve => requestAnimationFrame(resolve));
    }
    window.__floeLiveInkQualificationEnd = () => send('pointerup', x + length, y + Math.sin(4) * amplitude, 0);
    return true;
    """#
    private static let committedInkPosition = #"""
    (() => {
        const c=app.sectionContainer.canvas, r=c.getBoundingClientRect();
        const rgba=c.getContext('2d').getImageData(0,0,c.width,c.height).data;
        const raw=window.__floeLiveInkRawBounds, base=window.__floeLiveInkBase;
        if (!raw || !base || base.width!==c.width || base.height!==c.height)
            throw new Error('Actual ink canvas geometry changed during the contact');
        const red=(a,i)=>a[i]>140 && a[i]>a[i+1]*1.5 && a[i]>a[i+2]*1.5;
        let minX=c.width,minY=c.height,maxX=-1,maxY=-1,pixels=0;
        // Exclude pre-existing red cells/text and unrelated UI. The generous
        // 48 CSS px observation margin retains the measured 17px Writer
        // displacement; it cannot make that displacement pass the 4px check.
        const left=Math.max(0,Math.floor((raw[0]-48-r.left)*c.width/r.width));
        const right=Math.min(c.width,Math.ceil((raw[2]+48-r.left)*c.width/r.width));
        const top=Math.max(0,Math.floor((raw[1]-48-r.top)*c.height/r.height));
        const bottom=Math.min(c.height,Math.ceil((raw[3]+48-r.top)*c.height/r.height));
        for (let y=top;y<bottom;y++) for (let x=left;x<right;x++) {
            const i=(y*c.width+x)*4;
            if (red(rgba,i) && !red(base.rgba,i)) {
                minX=Math.min(minX,x);maxX=Math.max(maxX,x);
                minY=Math.min(minY,y);maxY=Math.max(maxY,y);pixels++;
            }
        }
        if (!raw || !pixels) return {pixels};
        const painted=[r.left+minX*r.width/c.width,r.top+minY*r.height/c.height,
            r.left+(maxX+1)*r.width/c.width,r.top+(maxY+1)*r.height/c.height];
        return {pixels,raw,painted,
            driftX:Math.abs((raw[0]+raw[2]-painted[0]-painted[2])/2),
            driftY:Math.abs((raw[1]+raw[3]-painted[1]-painted[3])/2)};
    })()
    """#

    private static let liftPen = #"""
    window.__floeLiveInkQualificationEnd();
    delete window.__floeLiveInkQualificationEnd;
    true;
    """#
}

private struct LiveNotesOfficeQualificationHost: View {
    let session: NotesSession
    var body: some View {
        if let document = session.document {
            NotesOfficeView(session: session, document: document, onAssistant: {}, onLinkedMaps: {})
        }
    }
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
