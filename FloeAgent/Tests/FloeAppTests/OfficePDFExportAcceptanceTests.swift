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
import FloeNotes
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

    func testRealWorkbookSelectedSheetsAndExactScaleProduceActualDifferentPDFs() async throws {
        let (source, sha, root) = try input()
        do {
            let sheets = try OfficeRegionExport.workbookSheets(sourceURL: source, expectedSHA256: sha)
            let visible = sheets.filter(\.isVisible)
            XCTAssertFalse(visible.isEmpty)

            // The explicit selection of exactly the visible tabs prints the
            // same content set, but through its own verified copy: the bytes
            // differ while the measured pagination stays honest.
            let selected = try await OfficePDFExportService.export(.init(
                sourceURL: source, sourceSHA256: sha, formatExtension: "xlsx",
                plan: .init(scope: .sheets(names: visible.map(\.name))),
                ownedDirectory: root))
            XCTAssertEqual(Set(selected.appliedPrintPlan?.printedSheetNames ?? []),
                           Set(visible.map(\.name)))
            XCTAssertGreaterThanOrEqual(selected.pageCount, 1)
            XCTAssertTrue(selected.appliedPrintPlan?.drawingPartsPreserved ?? false,
                          "the print copy must carry the ink/drawing members byte-for-byte")
            XCTAssertFalse(selected.pdfSHA256.isEmpty)
            attach(selected.pdfURL, "provided-selected-sheets.pdf")

            // An exact scale below 100% must never ADD pages for the same
            // content: 60% fits at least as much on a page as the source's
            // own 100% settings (the two horizontal A4 slices measured in
            // the baseline test).
            let scaled = try await OfficePDFExportService.export(.init(
                sourceURL: source, sourceSHA256: sha, formatExtension: "xlsx",
                plan: .init(scope: .sheets(names: visible.map(\.name)),
                            pageSetup: .init(scalePercent: 60)),
                ownedDirectory: root))
            XCTAssertLessThanOrEqual(scaled.pageCount, max(selected.pageCount, 2))
            XCTAssertGreaterThanOrEqual(scaled.pageCount, 1)
            XCTAssertNotEqual(scaled.pdfSHA256, selected.pdfSHA256,
                              "the scale member must change the actual PDF bytes")
            XCTAssertEqual(scaled.appliedPrintPlan?.appliedPageSetup.scalePercent, 60)
            attach(scaled.pdfURL, "provided-exact-scale-60.pdf")

            // A 1×1 fit-pages budget is the explicit spelling of the proven
            // one-page mode and must reproduce its page geometry truthfully.
            let fitted = try await OfficePDFExportService.export(.init(
                sourceURL: source, sourceSHA256: sha, formatExtension: "xlsx",
                plan: .init(scope: .sheets(names: visible.map(\.name)),
                            pageSetup: .init(paper: .a4, orientation: .landscape,
                                             fitPages: OfficePDFFitPages(width: 1, height: 1))),
                ownedDirectory: root))
            XCTAssertEqual(fitted.pageCount, 1)
            XCTAssertEqual(fitted.pageSizes.first?.width ?? 0, 841.89, accuracy: 3)
            XCTAssertEqual(fitted.pageSizes.first?.height ?? 0, 595.28, accuracy: 3)
            attach(fitted.pdfURL, "provided-fit-pages-1x1.pdf")

            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), sha,
                           "the original workbook bytes are never touched")
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

    func testRealWorkbookPrintGridlinesChangesTheActualRenderedPDF() async throws {
        let (source, sha, root) = try input()
        do {
            let sheets = try OfficeRegionExport.workbookSheets(sourceURL: source, expectedSHA256: sha)
            let visible = sheets.filter(\.isVisible)
            XCTAssertFalse(visible.isEmpty)
            // The user's real reproduction complaint: the printed PDF was a
            // white page of digits with no cell grid. Same scale for both
            // runs so the `printOptions@gridLines` member is the ONLY
            // difference; the first page of each is rastered from the real
            // PDF with the existing helper. No engine mock anywhere.
            let plain = try await OfficePDFExportService.export(.init(
                sourceURL: source, sourceSHA256: sha, formatExtension: "xlsx",
                plan: .init(scope: .sheets(names: visible.map(\.name)),
                            pageSetup: .init(scalePercent: 100)),
                ownedDirectory: root))
            XCTAssertNil(plain.appliedPrintPlan?.appliedPageSetup.printGridlines)
            let gridded = try await OfficePDFExportService.export(.init(
                sourceURL: source, sourceSHA256: sha, formatExtension: "xlsx",
                plan: .init(scope: .sheets(names: visible.map(\.name)),
                            pageSetup: .init(scalePercent: 100, printGridlines: true)),
                ownedDirectory: root))
            XCTAssertEqual(gridded.appliedPrintPlan?.appliedPageSetup.printGridlines, true)
            XCTAssertEqual(gridded.pageCount, plain.pageCount,
                           "gridlines must not change pagination, only what is drawn")
            XCTAssertNotEqual(gridded.pdfSHA256, plain.pdfSHA256,
                              "the printOptions member must reach the actual PDF bytes")
            let plainPixels = try raster(plain.pdfURL)
            let griddedPixels = try raster(gridded.pdfURL)
            XCTAssertGreaterThan(griddedPixels.inked, plainPixels.inked,
                                 "the printed copy must actually render cell gridlines, not just carry the member")
            attach(plain.pdfURL, "provided-grid-default.pdf")
            attach(gridded.pdfURL, "provided-grid-on.pdf")
            attach(griddedPixels.png, "provided-grid-on-page1.png")
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), sha,
                           "the original workbook bytes are never touched")
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
            try await wait("actual Office tiles painted") {
                let facts = OfficeFileSession.hostRenderDiagnostics(native)
                return facts["stage"] == "visible-render" && facts["docLoaded"] == "1"
                    && ((Int(facts["decodedTiles"] ?? "") ?? 0) > 0 || facts["vectorRendering"] == "1")
            }
            XCTAssertTrue(native.responds(to: NSSelectorFromString("setOnPrintRequested:")))
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            let generation = session.printRequestGeneration
            // This is the exact native message sent by the existing engine's
            // Print toolbar. It must open options BEFORE any PDF is generated.
            let requestedAt = Date()
            _ = try await web.evaluateJavaScript("(() => { window.webkit.messageHandlers.lok.postMessage('PRINT'); return true; })()")
            try await wait("native PRINT routed to app options") { session.printRequestGeneration == generation + 1 }
            try await wait("options sheet mounted") { window.rootViewController?.presentedViewController != nil }
            try await wait("first print preparation settled") {
                OfficeStageRecorder.shared.events.contains {
                    $0.at >= requestedAt && ($0.stage == "export.prepare.ok" || $0.stage == "export.prepare.refused")
                }
            }
            let firstPreparation = try XCTUnwrap(OfficeStageRecorder.shared.events.first {
                $0.at >= requestedAt && ($0.stage == "export.prepare.ok" || $0.stage == "export.prepare.refused")
            })
            XCTAssertEqual(firstPreparation.stage, "export.prepare.ok",
                           "The first native Print attempt must prepare its options, without requiring Retry: \(firstPreparation.detail)")
            attachWindow(window, "native-toolbar-print-options-app-window")
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), sha)
            window.rootViewController?.dismiss(animated: false)
            try await Task.sleep(for: .milliseconds(300))
            await session.release()
            try FileManager.default.removeItem(at: root)
        } catch {
            // Preserve the first failure before close/unmount can report a
            // secondary WebKit removal error.
            XCTFail("Native toolbar Print failed: \(error)")
            await session.release()
            return
        }
    }

    /// Real-owner regression for the exact path commit e8 repaired.
    ///
    /// Main's ordinary editable Notes owner trace (private
    /// office-preview-runtime/diagnostic-actual-print-02.jsonl) shows what the
    /// read-only `testNativeToolbarPrint…` host cannot reach: after the engine's
    /// PRINT opens the shared options sheet on an editable session, SwiftUI
    /// transiently remounts the sheet content into a fresh state container
    /// (two `export.options.loadBegin` breadcrumbs with different `view` ids)
    /// while the first preparation is still in flight. On the previous commit
    /// (source 542) the disappearing child ran `abandon(disappear)` → `dismiss()`,
    /// so the parent wrote the presentation binding nil and recorded
    /// `export.prepare.cancelRequested`; the second container then died on
    /// `noSource` — no preview, no Print. At e8 a transient disappearance is
    /// teardown-only, the second consumer records `export.prepare.joined`, one
    /// `export.prepare.ok` lands, and the automatic generation is accepted with
    /// the sheet still mounted. Explicit Cancel (and delivery completion) remain
    /// the only child paths allowed to dismiss.
    ///
    /// This test hosts the same production owner surfaces the Notes workspace
    /// uses (OfficeDocumentEditorView + OfficeFileSession + the pinned native
    /// controller), opened EDITABLE like the failing document, and drives the
    /// exact native PRINT toolbar message. Two explicit Cancels fence dismissal
    /// ownership: one after the accepted automatic preview (nothing may publish
    /// late), and one while a real pinned-engine render is in flight (the
    /// interrupted generation is cancelled or fenced, never published after the
    /// dismissal). Opt-in fixture semantics, window/session cleanup and the
    /// read-only test above are unchanged.
    func testEditableOwnerPrintSurvivesTransientRemountAndCancelFencesLatePublication() async throws {
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
                                     onSaved: nil, requestsEditingOnAppear: true)
                .environmentObject(environment)
        })
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        do {
            await session.open(source)
            // The failing surface is never a read-only preview: the production
            // edit handler must have acknowledged the editable session and the
            // owner-autosave must be idle before Print is meaningful.
            try await wait("editable owner acknowledged") {
                !session.readOnly && session.documentActionsReady && session.canAct
                    && OfficeStageRecorder.shared.events.contains {
                        $0.session == session.stageTraceSessionID
                            && $0.stage == "edit.acknowledged" && $0.detail["readOnly"] == "false"
                    }
            }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await wait("actual Office tiles painted") {
                let facts = OfficeFileSession.hostRenderDiagnostics(native)
                return facts["stage"] == "visible-render" && facts["docLoaded"] == "1"
                    && ((Int(facts["decodedTiles"] ?? "") ?? 0) > 0 || facts["vectorRendering"] == "1")
            }
            XCTAssertTrue(native.responds(to: NSSelectorFromString("setOnPrintRequested:")))
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))

            // MARK: Request A — remount survival through the accepted preview.
            let postedA = try await requestNativePrint(web: web, session: session,
                                                       baseGeneration: session.printRequestGeneration)
            try await wait("options sheet mounted (request A)") {
                window.rootViewController?.presentedViewController != nil
            }
            try await wait("request A preparation settled") {
                ownerEvents(for: session, since: postedA).contains {
                    $0.stage == "export.prepare.ok" || $0.stage == "export.prepare.refused"
                }
            }
            try await wait("automatic preview accepted without any Generate tap (request A)") {
                ownerEvents(for: session, since: postedA).contains {
                    $0.stage == "export.preview.generationAccepted"
                }
            }
            // Snapshot the whole pre-Cancel window. This session's print
            // lifecycle emits far fewer events than the recorder's process cap,
            // so the window is complete, and every breadcrumb below carries this
            // session's own correlation id.
            let a = ownerEvents(for: session, since: postedA)
            let prepareOK = try XCTUnwrap(a.first { $0.stage == "export.prepare.ok" },
                                          "The native Print on the editable owner must prepare without refusing: \(a.filter { $0.stage == "export.prepare.refused" }.first?.detail ?? [:])")
            XCTAssertEqual(a.filter { $0.stage == "export.prepare.started" }.count, 1,
                           "one modal request owns exactly one producer")
            XCTAssertEqual(a.filter { $0.stage == "export.prepare.refused" }.count, 0)
            let loadBegins = a.filter { $0.stage == "export.options.loadBegin" }
            XCTAssertFalse(loadBegins.isEmpty)
            XCTAssertEqual(Set(loadBegins.compactMap { $0.detail["view"] }).count, loadBegins.count,
                           "each loadBegin must name its own fresh state container")
            let joined = a.filter { $0.stage == "export.prepare.joined" }
            if loadBegins.count > 1 {
                // The transient fresh-container remount happened in this host
                // (as in Main's device trace): the second consumer must JOIN the
                // same in-flight preparation, never start a second producer and
                // never see a parent cancellation across the remount.
                XCTAssertEqual(joined.count, loadBegins.count - 1)
                XCTAssertGreaterThanOrEqual(joined.first?.at ?? .distantFuture, loadBegins[1].at)
                XCTAssertLessThanOrEqual(joined.last?.at ?? .distantPast, prepareOK.at)
                XCTAssertEqual(a.filter {
                    $0.stage == "export.options.teardown" && $0.detail["source"] == "disappear"
                }.count, loadBegins.count - 1,
                "a transient remount tears down only the leaving container's own preview work")
            } else {
                XCTAssertEqual(joined.count, 0)
            }
            // The 542 failure signature must be absent before any explicit
            // dismissal: a disappearing child called abandon("disappear"),
            // dismissed itself, and the parent then wrote the binding nil and
            // cancelled the still-live preparation.
            XCTAssertEqual(a.filter { $0.stage == "export.options.abandon" }.count, 0,
                           "Original-failure evidence: no child abandonment may precede an explicit dismissal")
            XCTAssertEqual(a.filter { $0.stage == "export.sheet.bindingSet" && $0.detail["nil"] == "true" }.count, 0,
                           "the parent presentation binding must survive the transient remount")
            XCTAssertEqual(a.filter { $0.stage == "export.prepare.cancelRequested" }.count, 0,
                           "no cancelled parent before an explicit dismissal")
            XCTAssertTrue(a.contains { $0.stage == "export.options.loaded"
                && $0.detail["view"] == loadBegins.last?.detail["view"] })
            XCTAssertNotNil(window.rootViewController?.presentedViewController,
                            "the options sheet must stay mounted through the accepted automatic preview")

            // Actual artifact and page evidence. The automatic generation is the
            // default print of the verified frozen source; the direct baseline
            // test above proves this exact fixture prints two horizontal A4
            // slices, and Main's device trace measured 2 pages for this first
            // automatic token. A different count means the automatic path
            // silently changed scope, not that the private fixture grew.
            let generateOK = try XCTUnwrap(a.first { $0.stage == "export.generate.ok" })
            let pages = try XCTUnwrap(Int(generateOK.detail["pages"] ?? ""))
            let bytes = try XCTUnwrap(Int(generateOK.detail["bytes"] ?? ""))
            XCTAssertEqual(pages, 2)
            XCTAssertGreaterThan(bytes, 4_096)
            let sheetViewA = try XCTUnwrap(window.rootViewController?.presentedViewController?.view)
            try await wait("accepted artifact surfaced in the dock (request A)") {
                Self.accessibilityNodes(in: sheetViewA).contains { $0.identifier == "office.pdf.inlinePreview" }
            }
            let measured = Self.accessibilityNodes(in: sheetViewA)
                .first { $0.identifier == "office.pdf.measuredPages" }
            XCTAssertNotNil(measured, "the dock must show the page count measured from the actual PDF")
            XCTAssertTrue(measured?.label.contains(String(pages)) ?? false,
                          "the visible measured count must equal the generated page count")
            attachWindow(window, "editable-owner-print-accepted-request-a")

            // Explicit Cancel on the delivered-idle sheet: this is the child's
            // own dismissal, so the parent's nil write and any cancellation must
            // come AFTER the abandon, and nothing may publish afterwards.
            let cancelAAt = Date()
            try await activateToolbarButton(in: window, labels: ["取消", "Cancel"])
            try await wait("explicit Cancel A dismissed the options sheet") {
                window.rootViewController?.presentedViewController == nil
            }
            // Give any leaked debounce/pending consumer the chance to publish:
            // the renderer debounces 550 ms and one render needs seconds.
            try await Task.sleep(for: .seconds(2))
            let aFull = ownerEvents(for: session, since: postedA)
            attachStages(aFull, "request-a-window.json")
            let abandonA = try XCTUnwrap(aFull.first {
                $0.stage == "export.options.abandon" && $0.detail["source"] == "cancelButton"
            }, "the Cancel toolbar button must run the sheet's own explicit abandon")
            XCTAssertGreaterThanOrEqual(abandonA.at, cancelAAt)
            let firstNil = aFull.first { $0.stage == "export.sheet.bindingSet" && $0.detail["nil"] == "true" }
            XCTAssertNotNil(firstNil, "the explicit dismissal must write the parent presentation binding nil")
            XCTAssertGreaterThanOrEqual(firstNil?.at ?? .distantPast, abandonA.at)
            if let firstCancel = aFull.first(where: { $0.stage == "export.prepare.cancelRequested" }) {
                XCTAssertGreaterThanOrEqual(firstCancel.at, abandonA.at,
                    "request cancellation belongs to the explicit dismissal only")
            }
            XCTAssertEqual(aFull.filter { $0.at > abandonA.at && [
                "export.preview.generationAccepted", "export.preview.generationStarted",
                "export.generate.started", "export.generate.ok"].contains($0.stage) }.count, 0,
                "an explicit Cancel releases the session without late successful publication")
            XCTAssertNil(window.rootViewController?.presentedViewController,
                         "Cancel must leave no owned options or nested print surface mounted")
            try await wait("session usable again after Cancel A") { session.canAct }

            // MARK: Request B — an explicit Cancel while the real engine renders.
            let postedB = try await requestNativePrint(web: web, session: session,
                                                       baseGeneration: session.printRequestGeneration)
            try await wait("options sheet mounted (request B)") {
                window.rootViewController?.presentedViewController != nil
            }
            try await wait("automatic render running (request B)") {
                ownerEvents(for: session, since: postedB).contains { $0.stage == "export.generate.started" }
            }
            // The pinned engine needs seconds for this workbook; cancelling well
            // inside that window means any late completion must hit the accept
            // fence instead of publishing into a dismissed sheet.
            try await Task.sleep(for: .milliseconds(600))
            let cancelBAt = Date()
            try await activateToolbarButton(in: window, labels: ["取消", "Cancel"])
            try await wait("explicit Cancel B dismissed the options sheet") {
                window.rootViewController?.presentedViewController == nil
            }
            try await Task.sleep(for: .seconds(2))
            let b = ownerEvents(for: session, since: postedB)
            attachStages(b, "request-b-window.json")
            let abandonB = try XCTUnwrap(b.first {
                $0.stage == "export.options.abandon" && $0.detail["source"] == "cancelButton"
            })
            XCTAssertGreaterThanOrEqual(abandonB.at, cancelBAt)
            XCTAssertEqual(b.filter { $0.stage == "export.options.abandon"
                && $0.detail["source"] != "cancelButton" }.count, 0,
                "again no child may abandon on a disappearance")
            XCTAssertEqual(b.filter { ($0.stage == "export.sheet.bindingSet" && $0.detail["nil"] == "true"
                || $0.stage == "export.prepare.cancelRequested") && $0.at < abandonB.at }.count, 0,
                "again no cancelled parent before the explicit dismissal")
            let acceptedB = b.filter { $0.stage == "export.preview.generationAccepted" }
            XCTAssertEqual(acceptedB.filter { $0.at > abandonB.at }.count, 0,
                "a render interrupted by the explicit Cancel must never publish afterwards")
            if acceptedB.isEmpty {
                XCTAssertTrue(b.contains {
                    ($0.stage == "export.preview.generationCancelled"
                        || $0.stage == "export.preview.generationFenced") && $0.at >= cancelBAt
                }, "the interrupted generation must be reported cancelled or fenced, not vanish silently")
            }
            XCTAssertNil(window.rootViewController?.presentedViewController)
            try await wait("session usable again after Cancel B") { session.canAct }

            // An editable owner saves before freezing its PDF source. That
            // authorized save may normalize the package even with no new input;
            // byte equality is only the read-only host's invariant. The supplied
            // attachment is a separate immutable runtime input, never this copy.
            let savedPackage = try Data(contentsOf: source)
            XCTAssertFalse(savedPackage.isEmpty)
            XCTAssertEqual(Array(savedPackage.prefix(4)), [0x50, 0x4b, 0x03, 0x04])
            let sourceAudit = try JSONSerialization.data(withJSONObject: [
                "inputSHA256": sha,
                "savedCopySHA256": try FloeDigest.sha256Hex(ofFileAt: source)
            ], options: [.sortedKeys])
            attach(sourceAudit, "editable-owner-source-audit.json")
            let quarantined = await OfficeAutomaticExecutionGate.shared.isQuarantined
            XCTAssertFalse(quarantined)
            await session.release()
            try FileManager.default.removeItem(at: root)
        } catch {
            // Preserve the first failure, as the read-only host test does, before
            // release can report a secondary WebKit removal error.
            XCTFail("Editable-owner print remount regression failed: \(error)")
            await session.release()
            return
        }
    }

    func testPreparationCancellationAndOwnershipRemainFenced() async throws {
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
            try await wait("actual Office document ready") { session.documentActionsReady && session.canAct }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await wait("actual Office tiles painted") {
                let facts = OfficeFileSession.hostRenderDiagnostics(native)
                return facts["stage"] == "visible-render" && facts["docLoaded"] == "1"
                    && ((Int(facts["decodedTiles"] ?? "") ?? 0) > 0 || facts["vectorRendering"] == "1")
            }

            // Cancel before the MainActor task starts: no scheduler timing or
            // non-Sendable result crosses a child-task boundary.
            let startedAt = Date()
            let cancelled = Task { @MainActor in
                do {
                    _ = try await session.preparePDFExport()
                    XCTFail("A cancelled load must not prepare an artifact")
                } catch is CancellationError { }
                catch { XCTFail("Expected cancellation, received: \(error)") }
            }
            cancelled.cancel()
            await cancelled.value
            XCTAssertTrue(session.canAct, "Cancellation must leave the session usable")
            XCTAssertFalse(OfficeStageRecorder.shared.events.contains {
                $0.session == session.stageTraceSessionID && $0.at >= startedAt
                    && $0.stage.hasPrefix("export.prepare.")
            }, "A cancelled load must not claim success or a stale-source refusal")

            // An independently held editor still refuses preparation. It must
            // not fabricate a source change or steal the holder's reservation.
            XCTAssertTrue(session.beginExternalRefresh(resigningFirstResponder: false))
            do {
                _ = try await session.preparePDFExport()
                XCTFail("A held session must refuse a new preparation")
            } catch {
                XCTAssertTrue(error is FloeError)
                XCTAssertFalse(error is OfficePDFExportScreenError)
            }
            XCTAssertFalse(session.canAct, "The original holder keeps its reservation")
            session.endExternalRefresh()
            XCTAssertTrue(session.canAct)

            let prepared = try await session.preparePDFExport()
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: prepared.sourceURL), prepared.sourceSHA256)
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), sha)
            let isCurrent = await prepared.isCurrent()
            XCTAssertTrue(isCurrent)
            await session.release()
            let remainsCurrent = await prepared.isCurrent()
            XCTAssertFalse(remainsCurrent, "A preparation cannot survive release of its exact owner")
            try FileManager.default.removeItem(at: root)
        } catch {
            await session.release()
            throw error
        }
    }

    func testSavedCoverRejectsMismatchedResourceAndCancellationThenRecovers() async throws {
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
            try await wait("actual Office document ready") { session.documentActionsReady && session.canAct }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await wait("actual Office tiles painted") {
                let facts = OfficeFileSession.hostRenderDiagnostics(native)
                return facts["stage"] == "visible-render" && facts["docLoaded"] == "1"
                    && ((Int(facts["decodedTiles"] ?? "") ?? 0) > 0 || facts["vectorRendering"] == "1")
            }
            let working = native.workingFileURL
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: working), sha)
            let exports = working.deletingLastPathComponent().appendingPathComponent("exports", isDirectory: true)
            func coverEntries() throws -> Set<String> {
                guard FileManager.default.fileExists(atPath: exports.path) else { return [] }
                return Set(try FileManager.default.contentsOfDirectory(atPath: exports.path)
                    .filter { $0.hasPrefix("cover-") })
            }
            let before = try coverEntries()
            // Correct-looking resource identity with wrong bytes must fail
            // before opening a converter, without leaving a job or PDF.
            let wrong = root.appendingPathComponent(sha)
            try Data("different saved bytes".utf8).write(to: wrong)
            do {
                _ = try await session.exportCommittedCoverPDF(expectedSHA256: sha, savedSourceURL: wrong)
                XCTFail("A mismatched saved resource must not produce a cover")
            } catch {
                XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
                XCTAssertEqual((error as NSError).code, CocoaError.fileReadCorruptFile.rawValue)
            }
            XCTAssertTrue(session.canAct)
            XCTAssertFalse(session.coverExportInFlight)
            XCTAssertEqual(try coverEntries(), before)
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), sha)

            // Cancellation happens before the child gets the MainActor: no
            // time-based race and no unnecessary input/operation claim.
            let cancelled = Task { @MainActor in
                do {
                    let unexpected = try await session.exportCommittedCoverPDF(
                        expectedSHA256: sha, savedSourceURL: source)
                    try? FileManager.default.removeItem(at: unexpected)
                    XCTFail("A cancelled cover must not produce an artifact")
                } catch is CancellationError { }
                catch { XCTFail("Expected cancellation, received: \(error)") }
            }
            cancelled.cancel()
            await cancelled.value
            XCTAssertTrue(session.canAct)
            XCTAssertFalse(session.coverExportInFlight)
            XCTAssertEqual(try coverEntries(), before)

            // A real retry must acquire the released claim and produce a
            // renderable PDF, leaving only its caller-owned output file.
            let pdf = try await session.exportCommittedCoverPDF(expectedSHA256: sha, savedSourceURL: source)
            XCTAssertGreaterThan(try Data(contentsOf: pdf).count, 4_096)
            let preview = try OfficeSavedCoverRenderer.firstPageData(at: pdf)
            XCTAssertNotNil(UIImage(data: preview))
            XCTAssertEqual(try coverEntries(), before.union([pdf.lastPathComponent]))
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), sha)
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: working), sha)
            XCTAssertTrue(session.canAct)
            XCTAssertFalse(session.coverExportInFlight)
            attach(pdf, "saved-cover-after-refusal-and-cancellation.pdf")
            try FileManager.default.removeItem(at: pdf)
            XCTAssertEqual(try coverEntries(), before)
            let quarantined = await OfficeAutomaticExecutionGate.shared.isQuarantined
            XCTAssertFalse(quarantined)
            await session.release()
            try FileManager.default.removeItem(at: root)
        } catch {
            await session.release()
            if !(await OfficeAutomaticExecutionGate.shared.isQuarantined) {
                try? FileManager.default.removeItem(at: root)
            }
            throw error
        }
    }

    func testAssistantExportToolReturnsActualPDFAndVisibleFileCard() async throws {
        let (source, sha, root) = try input()
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = try NotesStore(root: root.appendingPathComponent("notes", isDirectory: true))
        let runID = UUID(), conversationID = UUID(), callID = "call-actual-office-export"
        var ownedRunDirectory: URL?
        await NotesRepository.shared.setStoreOverride(store)
        do {
            let resource = try await store.importResource(from: source,
                mediaType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
            var document = NoteDocument(kind: .office, title: "Provided Workbook")
            document.officeResourceID = resource
            document.officeFileName = "provided.xlsx"
            let created = try await store.create(document)
            try await store.grantAccess(conversationID: conversationID, documentID: created.id, canEdit: false)
            let arguments = try JSONDecoder().decode(NotesExportTool.Arguments.self,
                from: JSONSerialization.data(withJSONObject: [
                    "documentID": created.id.uuidString, "format": "pdf",
                    "expectedRevision": created.revision, "targetPath": "exports/provided.pdf",
                    "paper": "a4", "orientation": "landscape", "fit": "fitToOnePage"
                ]))
            let tool = NotesExportTool()
            try tool.validate(arguments)
            let output = try await tool.execute(arguments, context: ToolContext(
                runID: runID, toolCallID: callID, scope: .local, workspaceRootURL: workspace,
                cancellation: CancellationToken(), conversationID: conversationID))
            XCTAssertEqual(output.outputFiles.count, 1)
            let receipt = try XCTUnwrap(output.outputFiles.first)
            let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(output.summary.utf8)) as? [String: Any])
            XCTAssertEqual(payload["pageCount"] as? Int, 1)
            XCTAssertEqual(payload["mimeType"] as? String, "application/pdf")
            XCTAssertEqual(payload["sha256"] as? String, receipt.sha256)
            guard case .verified(let snapshot) = RunOutputSnapshotStore.verify(receipt) else {
                XCTFail("The actual tool must return a retrievable binary snapshot")
                throw CocoaError(.fileReadCorruptFile)
            }
            let runDirectory = snapshot.deletingLastPathComponent().deletingLastPathComponent()
            guard runDirectory.lastPathComponent == runID.uuidString,
                  runDirectory.deletingLastPathComponent().lastPathComponent == "RunOutputs" else {
                XCTFail("Refuse cleanup outside this test's unique output run")
                throw CocoaError(.fileReadInvalidFileName)
            }
            ownedRunDirectory = runDirectory
            XCTAssertEqual(try Data(contentsOf: snapshot), try Data(contentsOf: workspace.appendingPathComponent("exports/provided.pdf")))
            XCTAssertEqual(try FloeDigest.sha256Hex(ofFileAt: source), sha)
            attach(snapshot, "assistant-tool-actual-export.pdf")

            let context = RunOutputReceiptContext(runID: runID, conversationID: conversationID,
                                                  callID: callID, toolName: NotesExportTool.name)
            XCTAssertTrue(RunOutputReceiptGate.accepts(receipt, in: context))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive }))
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController = UIHostingController(rootView: NavigationStack {
                RunOutputFilesCard(receipts: output.outputFiles, context: context)
                    .padding().navigationTitle("Floe")
            })
            window.windowLevel = .normal + 1
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
            try await Task.sleep(for: .seconds(2))
            attachWindow(window, "assistant-export-file-card-app-window")
            await NotesRepository.shared.setStoreOverride(nil)
            if let ownedRunDirectory { try FileManager.default.removeItem(at: ownedRunDirectory) }
            try FileManager.default.removeItem(at: root)
        } catch {
            await NotesRepository.shared.setStoreOverride(nil)
            if let ownedRunDirectory { try? FileManager.default.removeItem(at: ownedRunDirectory) }
            if !(await OfficeAutomaticExecutionGate.shared.isQuarantined) { try? FileManager.default.removeItem(at: root) }
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

    /// The durable owner-stage events of exactly one Office session inside one
    /// print request, ordered by record time. Content-free by the recorder's
    /// own contract; the per-container `view` ids are the remount evidence.
    private func ownerEvents(for session: OfficeFileSession, since: Date) -> [OfficeStageEvent] {
        OfficeStageRecorder.shared.events.filter {
            $0.session == session.stageTraceSessionID && $0.at >= since
        }
    }

    /// One real toolbar action. A readiness or admission failure must remain
    /// visible; the regression must never retry or clear the session error.
    private func requestNativePrint(web: WKWebView, session: OfficeFileSession,
                                    baseGeneration: Int) async throws -> Date {
        let postedAt = Date()
        _ = try await web.evaluateJavaScript("(() => { window.webkit.messageHandlers.lok.postMessage('PRINT'); return true; })()")
        try await wait("native PRINT routed to app options on its first attempt") {
            session.printRequestGeneration > baseGeneration
        }
        XCTAssertEqual(session.printRequestGeneration, baseGeneration + 1)
        return postedAt
    }

    /// Drives the presented options sheet's Cancel toolbar button through its
    /// real action path: first the accessibility activation SwiftUI wires to the
    /// production Button action, then — if the bridge has not vended the element
    /// yet — a genuine touch-up-inside delivered to the hosted control carrying
    /// the same visible title. Nothing reaches into view state or calls the
    /// sheet directly, so a broken explicit-dismissal path cannot pass by
    /// construction.
    private func activateToolbarButton(in window: UIWindow, labels: Set<String>) async throws {
        let sheet = try XCTUnwrap(window.rootViewController?.presentedViewController,
                                  "the options sheet must be presented before an explicit Cancel")
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            for node in Self.accessibilityNodes(in: sheet.view) where labels.contains(node.label) {
                if node.activate() { return }
            }
            for control in Self.uiButtons(in: sheet.view) where labels.contains(control.title) {
                control.button.sendActions(for: .touchUpInside)
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw CocoaError(.featureUnsupported, userInfo: [
            NSLocalizedDescriptionKey: "the explicit Cancel control must be reachable in the presented options sheet"])
    }

    /// Content-free lifecycle evidence for Main: the exact stage window an
    /// assertion set consumed, including every per-container `view` id.
    private func attachStages(_ events: [OfficeStageEvent], _ name: String) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(events) else { return }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private struct HostedAccessibilityNode {
        let identifier: String
        let label: String
        let activate: @MainActor () -> Bool
    }

    private struct HostedButton {
        let title: String
        let button: UIButton
    }

    /// Collects the accessibility nodes a hosted tree vends. The element count
    /// is queried on every container first: SwiftUI builds its assistive tree
    /// lazily, and this test is the client. UIAccessibilityElement wrappers are
    /// read directly; plain UIView elements are covered by the subview walk.
    private static func accessibilityNodes(in view: UIView) -> [HostedAccessibilityNode] {
        var nodes: [HostedAccessibilityNode] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ node: UIView, depth: Int) {
            guard depth < 64, visited.insert(ObjectIdentifier(node)).inserted else { return }
            let count = node.accessibilityElementCount()
            if node.isAccessibilityElement || node.accessibilityIdentifier != nil {
                nodes.append(HostedAccessibilityNode(
                    identifier: node.accessibilityIdentifier ?? "",
                    label: node.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    activate: { node.accessibilityActivate() }))
            }
            var elements = node.accessibilityElements ?? []
            if elements.isEmpty, count != NSNotFound, count > 0, count <= 4_096 {
                elements = (0..<count).compactMap { node.accessibilityElement(at: $0) }
            }
            for element in elements {
                // Only the accessibility wrappers are read here; real UIView
                // elements are covered by the subview walk below.
                guard let element = element as? UIAccessibilityElement else { continue }
                nodes.append(HostedAccessibilityNode(
                    identifier: element.accessibilityIdentifier ?? "",
                    label: element.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    activate: { element.accessibilityActivate() }))
            }
            for sub in node.subviews { walk(sub, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return nodes
    }

    private static func uiButtons(in view: UIView) -> [HostedButton] {
        var found: [HostedButton] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ node: UIView, depth: Int) {
            guard depth < 64, visited.insert(ObjectIdentifier(node)).inserted else { return }
            if let button = node as? UIButton {
                let title = (button.title(for: .normal) ?? button.accessibilityLabel ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                found.append(HostedButton(title: title, button: button))
            }
            for sub in node.subviews { walk(sub, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return found
    }

    private func attach(_ url: URL, _ name: String) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func attach(_ data: Data, _ name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func attachWindow(_ window: UIWindow, _ name: String) {
        // Hosted App tests cannot use XCUIScreen UI-automation APIs. Capture
        // this real App window; the runner separately records the full
        // Simulator display, including remote UIKit Print content.
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
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
        // On this SDK UIKit transfers and clears printingItem after present.
        // Check the actual printable input and mounted panel; the display
        // recording retains the real one-page ink preview.
        XCTAssertTrue(UIPrintInteractionController.canPrint(pdf))
        XCTAssertEqual(UIPrintInteractionController.shared.printInfo?.orientation, .landscape)
        XCTAssertNotNil(presenter.presentedViewController, "UIKit must actually present its print panel")
        attachWindow(window, "actual-system-print-presenter-app-window")
    }

    private func raster(_ url: URL) throws -> (png: Data, yellow: Int, inked: Int, text: String) {
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
                    // A raw bitmap CGContext uses PDF coordinates already.
                    // UIKit's additional Y flip would invert this attachment.
                    context.scaleBy(x: CGFloat(width) / bounds.width, y: CGFloat(width) / bounds.width)
                    context.translateBy(x: -bounds.minX, y: -bounds.minY)
                    page.draw(with: .cropBox, to: context)
                    let image = try XCTUnwrap(context.makeImage())
                    return try XCTUnwrap(UIImage(cgImage: image).pngData())
                }
                var yellow = 0
                var inked = 0
                for offset in stride(from: 0, to: bytes.count, by: 4) {
                    if bytes[offset] > 230 && bytes[offset + 1] > 180 && bytes[offset + 2] < 220 { yellow += 1 }
                    // Any pixel that is not (near-)white: the canvas starts
                    // white, so this counts everything the page actually
                    // drew — text, borders and, when chosen, cell gridlines.
                    if bytes[offset] < 240 || bytes[offset + 1] < 240 || bytes[offset + 2] < 240 { inked += 1 }
                }
                return (png, yellow, inked, pdf.string ?? "")
            }
        }
    }
}
#endif
