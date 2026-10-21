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

    /// Build-283 idle autosave: a real Notes Office editor with two real
    /// Pencil contacts must promote through the session-owned coordinator's
    /// idle debounce alone — no explicit save, no commitLiveEdits, no close.
    /// The pre-save truthful-dirty probe is asserted WHILE the ink is visible
    /// (this is the check that catches the build-282 false-negative class:
    /// commitLiveEdits claimed hadUnsaved=false with visible ink), then the
    /// test only waits for idle and reads the Notes revision/resource and the
    /// reopened package to prove the accepted ink entered the saved bytes.
    func testWordIdleAutosavePromotesVisiblePencilInkWithoutExplicitSave() async throws {
        guard ProcessInfo.processInfo.environment["FLOE_NATIVE_DRAWING_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in actual Notes/native save qualification")
        }
        XCTAssertTrue(UIView.areAnimationsEnabled,
                      "Live preview acceptance requires production UIKit animation timing")
        executionTimeAllowance = 450
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-idle-autosave-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // XCTest awaits teardown blocks before the next case. Register
        // storage removal first so the later override reset executes first.
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Idle ink.docx")
        try OfficeDocumentBuilder.createWord(at: source, title: "Idle ink", paragraphs: ["IDLE-ORIGINAL-KEEP"])
        let store = try NotesStore(root: root.appendingPathComponent("store"))
        let imported = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
        let document = try await store.create(imported)
        await NotesRepository.shared.setStoreOverride(store)
        addTeardownBlock {
            await NotesRepository.shared.setStoreOverride(nil)
        }
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
        let office = try await waitForBoundEditableOfficeSession(document: document)
        do {
            let native = try XCTUnwrap(office.controller as? FloeOfficeNativeViewController)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            try await wait { OfficeFileSession.hostRenderDiagnostics(native)["stage"] == "visible-render" }
            office.useInkPreferences(workspaceIdentity: root.path, documentKey: "Idle ink.docx")
            let preferences = office.inkPreferences
            let old = preferences.stroke
            defer {
                preferences.setPreset(old.preset); preferences.setColorHex(old.colorHex)
                preferences.setWidthMillimeters(old.widthMillimeters)
                preferences.setTransparencyPercent(old.transparencyPercent)
            }
            preferences.setPreset(.marker)
            preferences.setColorHex("#FF0000")
            preferences.setWidthMillimeters(4)
            try await office.toggleDrawing()
            await office.applyInkPreferences()
            XCTAssertNil(office.inkError)

            let originalDocument = try await store.document(document.id)
            let originalRevision = originalDocument.revision
            let originalResource = try await store.resourceURL(try XCTUnwrap(originalDocument.officeResourceID))
            let originalSHA = try FloeDigest.sha256Hex(ofFileAt: originalResource)
            // Strict baseline: the freshly opened editor must prove clean
            // before any contact. A dirty answer here means the truth chain
            // already diverged before the stimulus.
            let cleanBefore = await office.hasLocalEditsToProtect()
            XCTAssertFalse(cleanBefore, "A freshly opened committed document must prove clean")

            // Two real Pencil contacts, lifted. No explicit save follows.
            for index in 0..<2 {
                let before = try await snapshot(web, label: "idle-autosave-\(index)-before-contact")
                _ = try await web.callAsyncJavaScript(Self.beginAndMove,
                    arguments: ["contactIndex": index], in: nil, contentWorld: .page)
                let stillDown = try await web.evaluateJavaScript("window.__floeOfficePenState().activeStroke")
                XCTAssertEqual(stillDown as? Bool, true, "Contact \(index): pen must be down before lift")
                _ = try await snapshot(web, label: "idle-autosave-\(index)-while-pen-is-down")
                _ = try await web.evaluateJavaScript(Self.liftPen)
            }
            try await Task.sleep(for: .milliseconds(500))
            let afterLift = try await snapshot(web, label: "idle-autosave-after-lifting-pen")
            XCTAssertGreaterThan(redPixels(afterLift), 40,
                "Visible committed ink must exist on the canvas before the idle save")

            // The build-282 false-negative probe: with visible ink and no
            // save of any kind, the REAL dirty truth must report edits worth
            // protecting. This is the assertion that would have failed when
            // commitLiveEdits claimed hadUnsaved=false with visible ink.
            let dirtyWithVisibleInk = await office.hasLocalEditsToProtect()
            XCTAssertTrue(dirtyWithVisibleInk,
                "Visible accepted ink must read dirty before the idle save; the 282 false-clean regression lives here")

            try await attachLiveDiagnostics(web, label: "word-before-idle-save")

            // ONLY wait for the idle debounce/coordinator now. Never call
            // explicitSave/saveInPlace/commitLiveEdits/close in this test.
            let idleDeadline = ContinuousClock.now.advanced(by: .seconds(60))
            var savedDocument = originalDocument
            while savedDocument.revision == originalRevision && ContinuousClock.now < idleDeadline {
                try await Task.sleep(for: .milliseconds(250))
                savedDocument = try await store.document(document.id)
            }
            XCTAssertGreaterThan(savedDocument.revision, originalRevision,
                "The idle autosave must create a real new Notes revision without any explicit save trigger")
            guard let savedResourceID = savedDocument.officeResourceID else {
                throw CocoaError(.coderInvalidValue)
            }
            let savedResource = try await store.resourceURL(savedResourceID)
            let savedSHA = try FloeDigest.sha256Hex(ofFileAt: savedResource)
            XCTAssertNotEqual(savedSHA, originalSHA, "The promoted package must differ from the original")
            XCTAssertEqual(savedSHA.count, 64)

            // The saved state must prove clean after the idle promotion.
            let cleanDeadline = ContinuousClock.now.advanced(by: .seconds(30))
            var stillDirty = true
            while stillDirty && ContinuousClock.now < cleanDeadline {
                try await Task.sleep(for: .milliseconds(250))
                stillDirty = await office.hasLocalEditsToProtect()
            }
            XCTAssertFalse(stillDirty, "The saved state must prove clean after the idle promotion")
            let postSaveDocument = try await store.document(document.id)
            XCTAssertEqual(postSaveDocument.revision, savedDocument.revision,
                "No second promotion may race after the idle drain settles")

            // Reopen the real saved package and prove both accepted strokes
            // entered the persisted bytes (actual OOXML drawing markup).
            let stagedSaved = try NotesOfficeResourceStaging.stage(source: savedResource, fileExtension: "docx")
            defer { NotesOfficeResourceStaging.remove(stagedSaved) }
            XCTAssertGreaterThanOrEqual(try vectorCount(in: stagedSaved), 2,
                "Both Pencil contacts must be retained in the idled-saved package")
            let package = XCTAttachment(contentsOfFile: savedResource)
            package.name = "idle-autosave-saved-docx"; package.lifetime = .keepAlways
            add(package)
            let canvasAttachment = XCTAttachment(image: afterLift)
            canvasAttachment.name = "idle-autosave-visible-ink-before-wait"
            canvasAttachment.lifetime = .keepAlways
            add(canvasAttachment)
            await office.release()
        } catch {
            await office.release()
            throw error
        }
    }

    /// Ordinary ENGINE editing (not Pencil, not a physical keyboard): the
    /// production UNO dispatcher selects documented cell A3 and commits a
    /// unique cell string through the engine's own input path. The idle
    /// autosave must then promote through the session-owned coordinator
    /// alone — no applyEngineCommands, no explicit save, no commitLiveEdits,
    /// no close — and the reopened package must show A1 preserved and A3
    /// carrying the exact engine-typed text.
    func testWorkbookEngineCellEditIdleAutosavePromotesWithoutExplicitSave() async throws {
        guard ProcessInfo.processInfo.environment["FLOE_NATIVE_DRAWING_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in actual Notes/native save qualification")
        }
        XCTAssertTrue(UIView.areAnimationsEnabled,
                      "Live preview acceptance requires production UIKit animation timing")
        executionTimeAllowance = 450
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("notes-idle-cell-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // XCTest awaits teardown blocks before the next case. Register
        // storage removal first so the later override reset executes first.
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Idle cell.xlsx")
        try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [
            .init(name: "Idle", rows: [["ORIGINAL-CONTENT-KEEP", "12"], ["Formula", "=B1*2"]])
        ])
        let store = try NotesStore(root: root.appendingPathComponent("store"))
        let imported = try await NoteFileImporter.importFile(source, notebookID: nil, store: store)
        let document = try await store.create(imported)
        await NotesRepository.shared.setStoreOverride(store)
        addTeardownBlock {
            await NotesRepository.shared.setStoreOverride(nil)
        }
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
        let office = try await waitForBoundEditableOfficeSession(document: document)
        do {
            let native = try XCTUnwrap(office.controller as? FloeOfficeNativeViewController)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            try await wait {
                let facts = OfficeFileSession.hostRenderDiagnostics(native)
                return facts["stage"] == "visible-render" && facts["docLoaded"] == "1"
            }
            let originalDocument = try await store.document(document.id)
            let originalRevision = originalDocument.revision
            let originalResource = try await store.resourceURL(try XCTUnwrap(originalDocument.officeResourceID))
            let originalSHA = try FloeDigest.sha256Hex(ofFileAt: originalResource)
            let cleanBefore = await office.hasLocalEditsToProtect()
            XCTAssertFalse(cleanBefore, "A freshly opened committed workbook must prove clean")

            // Real engine edit stimulus (page-level, not the tool layer):
            // the production UNO dispatcher selects documented cell A3 and
            // commits the marker string through the engine's own input path.
            // Drawing mode stays off; nothing here saves.
            let stimulus = try await web.callAsyncJavaScript(Self.selectCellAndEnterString,
                arguments: ["cell": "A3", "marker": "IDLE-CELL-7"], in: nil, contentWorld: .page) as? [String: Any]
            let stimulusAttachment = XCTAttachment(string: String(describing: stimulus))
            stimulusAttachment.name = "idle-cell-engine-edit-stimulus"
            stimulusAttachment.lifetime = .keepAlways
            add(stimulusAttachment)
            XCTAssertEqual(stimulus?["accepted"] as? Bool, true,
                "The engine must accept the cell edit stimulus (path \(stimulus?["path"] ?? "unknown"))")

            // Truthful-demand gate: an accepted engine edit must read dirty.
            // This is the ordinary-editing counterpart of the Pencil case's
            // false-negative catch; no dirty is ever stubbed or forced.
            try await waitForDirtyTruth(office: office, timeout: .seconds(15))
            let dirtyAfterInput = await office.hasLocalEditsToProtect()
            XCTAssertTrue(dirtyAfterInput,
                "An accepted engine cell edit must read dirty before the idle save")

            // ONLY wait for the idle debounce/coordinator now.
            let idleDeadline = ContinuousClock.now.advanced(by: .seconds(60))
            var savedDocument = originalDocument
            while savedDocument.revision == originalRevision && ContinuousClock.now < idleDeadline {
                try await Task.sleep(for: .milliseconds(250))
                savedDocument = try await store.document(document.id)
            }
            XCTAssertGreaterThan(savedDocument.revision, originalRevision,
                "The idle autosave must create a real new Notes revision without any explicit save trigger")
            guard let savedResourceID = savedDocument.officeResourceID else {
                throw CocoaError(.coderInvalidValue)
            }
            let savedResource = try await store.resourceURL(savedResourceID)
            let savedSHA = try FloeDigest.sha256Hex(ofFileAt: savedResource)
            XCTAssertNotEqual(savedSHA, originalSHA, "The promoted package must differ from the original")
            XCTAssertEqual(savedSHA.count, 64)

            let cleanDeadline = ContinuousClock.now.advanced(by: .seconds(30))
            var stillDirty = true
            while stillDirty && ContinuousClock.now < cleanDeadline {
                try await Task.sleep(for: .milliseconds(250))
                stillDirty = await office.hasLocalEditsToProtect()
            }
            XCTAssertFalse(stillDirty, "The saved state must prove clean after the idle promotion")
            let postSaveDocument = try await store.document(document.id)
            XCTAssertEqual(postSaveDocument.revision, savedDocument.revision,
                "No second promotion may race after the idle drain settles")

            // Reopen the real saved package and prove the exact engine-typed
            // cell text landed in documented cell A3 while A1's original
            // marker survived untouched.
            let stagedSaved = try NotesOfficeResourceStaging.stage(source: savedResource, fileExtension: "xlsx")
            defer { NotesOfficeResourceStaging.remove(stagedSaved) }
            let snapshot = try OfficeDocumentService.inspect(url: stagedSaved)
            let fields = Dictionary(uniqueKeysWithValues: snapshot.fields.map { ($0.id, $0.text) })
            XCTAssertEqual(fields["xl/worksheets/sheet1.xml|c|A3"], "IDLE-CELL-7",
                "Documented cell A3 must carry the engine-typed text; got \(fields)")
            XCTAssertEqual(fields["xl/worksheets/sheet1.xml|c|A1"], "ORIGINAL-CONTENT-KEEP",
                "Cell A1's original marker must survive the idle save")
            let package = XCTAttachment(contentsOfFile: savedResource)
            package.name = "idle-cell-saved-workbook"; package.lifetime = .keepAlways
            add(package)
            await office.release()
        } catch {
            await office.release()
            throw error
        }
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
        // XCTest awaits teardown blocks before the next case. Register
        // storage removal first so the later override reset executes first.
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
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
        addTeardownBlock {
            await NotesRepository.shared.setStoreOverride(nil)
        }
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

    private func waitForBoundEditableOfficeSession(document: NoteDocument) async throws -> OfficeFileSession {
        try await wait {
            let bound = NotesOfficeLiveBinding.boundSession(documentID: document.id,
                                                            fileName: document.officeFileName)
            return bound?.canAct == true && bound?.documentActionsReady == true
        }
        let office = try XCTUnwrap(NotesOfficeLiveBinding.boundSession(documentID: document.id,
                                                                       fileName: document.officeFileName))
        if office.readOnly {
            let entered = await office.requestEditing()
            XCTAssertTrue(entered, office.error ?? "Edit entry refused")
        }
        try await wait {
            let bound = NotesOfficeLiveBinding.boundSession(documentID: document.id,
                                                            fileName: document.officeFileName)
            return bound?.readOnly == false && bound?.canAct == true
                && bound?.documentActionsReady == true && bound?.autosaveActive == true
        }
        return try XCTUnwrap(NotesOfficeLiveBinding.boundSession(documentID: document.id,
                                                                 fileName: document.officeFileName))
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
            return {modifiedBridge:{
                    installed:window.floeModificationTrackingInstalled === true,
                    latch:window.floeModifiedSinceCommit ?? null,
                    cached:app.map.stateChangeHandler?.getItemValue('.uno:ModifiedStatus') ?? null,
                    mapHook:window.L?.Map?.prototype?.floeExplicitSaveInstalled === true,
                    nativeHandler:!!window.webkit?.messageHandlers?.floeOfficeDocumentModified,
                    page:location.pathname.split('/').pop()},
                pen:window.__floeOfficePenState(),
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

    /// The engine can hold an accepted edit in memory briefly before the
    /// modified edge reaches the native probes; poll the REAL dirty truth
    /// (never a stub) until it reflects the accepted edit or time out.
    private func waitForDirtyTruth(office: OfficeFileSession, timeout: Duration) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var dirty = false
        while !dirty && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
            dirty = await office.hasLocalEditsToProtect()
        }
        XCTAssertTrue(dirty, "The real dirty probe must reflect the accepted engine edit")
        if !dirty { throw CocoaError(.coderInvalidValue) }
    }

    /// Documented-cell engine edit stimulus (page-level, never the tool
    /// layer): the production UNO dispatcher selects a documented cell
    /// (default A3), then the engine's own TextInput seam types the marker
    /// and a real Return commits the cell edit — the same textinput/key path
    /// physical or IME typing drives. Selection, edit mode and the resulting
    /// modified state are read back for assertions; nothing here saves.
    private static let selectCellAndEnterString = #"""
    const map = window.app && window.app.map;
    if (!map || typeof map.sendUnoCommand !== 'function')
        throw new Error('Engine UNO dispatcher unavailable');
    const frame = () => new Promise(resolve => requestAnimationFrame(resolve));
    // The pinned sendUnoCommand silently drops commands unless the engine UI
    // is in edit mode (control/Toolbar.js:371-379). Wait briefly for the
    // engine's own edit entry, then fail with evidence instead of pretending
    // the edit was attempted.
    let editReady = false;
    for (let i = 0; i < 60; i++) {
        if (typeof map.isEditMode === 'function' && map.isEditMode() === true) {
            editReady = true;
            break;
        }
        await frame();
    }
    if (!editReady)
        throw new Error('Engine UI is not in edit mode');
    const targetCell = (typeof cell === 'string' && /^[A-Z]+[0-9]+$/.test(cell)) ? cell : 'A3';
    const text = (typeof marker === 'string' && marker.length > 0) ? marker : 'IDLE-CELL-7';
    const addressOf = () => {
        try {
            const address = window.app && window.app.calc && window.app.calc.cellAddress;
            return address ? { x: address.x, y: address.y } : null;
        } catch (_) { return null; }
    };
    const expected = (() => {
        const match = /^([A-Z]+)([0-9]+)$/.exec(targetCell);
        if (!match) return null;
        let x = 0;
        for (const letter of match[1])
            x = x * 26 + (letter.charCodeAt(0) - 64);
        return { x: x - 1, y: parseInt(match[2], 10) - 1 };
    })();
    // Production cell-selection dispatch: control/CalcNotifications.ts:68 in
    // the pinned browser uses the same .uno:GoToCell/ToPoint route. The real
    // cellcursor message updates app.calc.cellAddress, so this is an engine
    // selection readback rather than a guessed property.
    map.sendUnoCommand('.uno:GoToCell', { 'ToPoint': { type: 'string', value: targetCell } });
    let address = null;
    for (let i = 0; i < 120; i++) {
        address = addressOf();
        if (address && expected && address.x === expected.x && address.y === expected.y) break;
        await frame();
    }
    if (!address || !expected || address.x !== expected.x || address.y !== expected.y)
        throw new Error('Engine cell selection did not reach ' + targetCell + ': ' + JSON.stringify(address));
    // Real engine text input: TextInput._sendText posts the pinned 'textinput'
    // websocket message (layer/marker/TextInput.js:877-905 and 1268-1272),
    // which kit/ChildSession.cpp:2205-2231 converts to ExtTextInput /
    // EndExtTextInput. The pinned TextInput has no insertText method, so the
    // old fallback could never run.
    const input = map._textInput;
    if (!input || typeof input._sendText !== 'function' || typeof input.focus !== 'function')
        throw new Error('Engine TextInput seam unavailable');
    input.focus(true);
    input._sendText(text);
    for (let i = 0; i < 6; i++) await frame();
    // Commit with the engine's real Return path. _sendText('\n') takes the
    // pinned _sendNewlineEvent branch, i.e. key type=input char=13 key=1280;
    // this is the COKit route that publishes the document modified state even
    // before any save. It is a finished cell edit, not an explicit save.
    input._sendText('\n');
    const modified = () => {
        if (window.floeModifiedSinceCommit === true) return true;
        const handler = map.stateChangeHandler;
        if (!handler || typeof handler.getItemValue !== 'function') return false;
        const value = handler.getItemValue('.uno:ModifiedStatus');
        return value === true || value === 'true';
    };
    let observed = modified();
    for (let i = 0; i < 120 && !observed; i++) {
        await frame();
        observed = modified();
    }
    let modifiedState = null;
    try { modifiedState = map.stateChangeHandler.getItemValue('.uno:ModifiedStatus'); } catch (_) {}
    return { path: 'textInput._sendText+Return', cell: targetCell, text: text,
        accepted: observed === true, latch: window.floeModifiedSinceCommit === true,
        modified: modifiedState, address: address, expected: expected,
        uiEdit: map.isEditMode() === true };
    """#

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
