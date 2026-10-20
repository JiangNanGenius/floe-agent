// SPDX-License-Identifier: MPL-2.0
// Actual App drawing mode/settings -> synthetic pen PointerEvents (canvas-direct
// bands plus a document.elementFromPoint overlap subset) -> real frontend/core ->
// saved vector OOXML -> native reopen. NOT physical Apple Pencil/pointer acceptance.
#if canImport(UIKit) && canImport(FloeOfficeNative) && targetEnvironment(simulator) && DEBUG
import Foundation
import XCTest
import UIKit
import SwiftUI
import WebKit
import ZIPFoundation
import CryptoKit
import FloeDocuments
import FloeOfficeNative
@testable import FloeApp

@MainActor
final class OfficeNativeDrawingAppQualificationTests: XCTestCase {
    func testDOCXTenNativeVectorStrokesSaveAndReopen() async throws { try await exercise("docx") }
    func testXLSXTenNativeVectorStrokesSaveAndReopen() async throws { try await exercise("xlsx") }
    func testPPTXTenNativeVectorStrokesSaveAndReopen() async throws { try await exercise("pptx") }

    /// Opt-in PRE-FIX baseline for the human dot contract. A short real native
    /// vector stroke is saved and reopened first as the positive control (the
    /// route/tool proof). Then the actual production pen bridge receives
    /// exactly one pen pointerdown and one pointerup at the same client point,
    /// with no pointermove and no epsilon, and the final save is reopened for
    /// an XML and engine-page-pixel check. The pinned v1 engine is expected to
    /// drop the zero-length FreehandLine, so this test intentionally fails
    /// with retained diagnostics when the dot is absent or invisible; it is
    /// never skipped, weakened or reported as a pass. No physical Pencil claim.
    func testDOCXZeroMotionNativePenDotPersistsAndReopens() async throws {
        try await exerciseZeroMotionPenDot("docx")
    }
    func testXLSXZeroMotionNativePenDotPersistsAndReopens() async throws {
        try await exerciseZeroMotionPenDot("xlsx")
    }
    func testPPTXZeroMotionNativePenDotPersistsAndReopens() async throws {
        try await exerciseZeroMotionPenDot("pptx")
    }

    /// Selected-style alpha acceptance (design HANDOFF §3): the explicitly
    /// selected highlighter preset (4.0 mm, 60% transparency) must persist a
    /// dot whose fill alpha equals the alpha derived from that real stroke
    /// (40000), while the opaque cross-negative terms keep the frozen opaque
    /// selectors above byte-stable: they still pass no extended seam
    /// arguments and still gate nil/100000 exactly as accepted in v1.
    func testDOCXZeroMotionHighlighterDotPersistsAndReopens() async throws {
        try await exerciseZeroMotionPenDot("docx", dotPreset: .highlighter)
    }
    func testXLSXZeroMotionHighlighterDotPersistsAndReopens() async throws {
        try await exerciseZeroMotionPenDot("xlsx", dotPreset: .highlighter)
    }
    func testPPTXZeroMotionHighlighterDotPersistsAndReopens() async throws {
        try await exerciseZeroMotionPenDot("pptx", dotPreset: .highlighter)
    }

    /// After-dot lifecycle (design HANDOFF §3.5) through the actual production
    /// bridge and the saved OOXML only: a moving stroke completes and persists
    /// after a zero-motion dot; each repeat tap persists exactly one new dot;
    /// the mixed tap+moving-ink document keeps exact counts, distinct geometry
    /// and per-style attributes; one real `.uno:Undo` removes only the newest
    /// dot with the prior strokes unchanged and `.uno:Redo` restores it.
    func testDOCXZeroMotionDotLifecycleNextStrokeRepeatTapsUndoRedo() async throws {
        try await exerciseDotLifecycle("docx")
    }
    func testXLSXZeroMotionDotLifecycleNextStrokeRepeatTapsUndoRedo() async throws {
        try await exerciseDotLifecycle("xlsx")
    }
    func testPPTXZeroMotionDotLifecycleNextStrokeRepeatTapsUndoRedo() async throws {
        try await exerciseDotLifecycle("pptx")
    }

    /// True-cancel contract. The integrated carrier owns a genuine
    /// window-level pointercancel listener (FloeOfficeNative.mm ce3543f,
    /// HEAD 08303a31) that aborts the unfinished contact instead of releasing
    /// it like an up. This test dispatches only a genuine
    /// pointerdown+pointercancel at one identical point (never a normal
    /// pointerup, no handler bypass), requires that the saved document
    /// persists no dot, and proves the next moving stroke completes through
    /// the same bridge afterwards. It is a permanent cancel-route regression
    /// gate, never skipped or weakened.
    func testDOCXZeroMotionDotTruePointerCancelPersistsNoDot() async throws {
        try await exerciseDotCancel("docx")
    }
    func testXLSXZeroMotionDotTruePointerCancelPersistsNoDot() async throws {
        try await exerciseDotCancel("xlsx")
    }
    func testPPTXZeroMotionDotTruePointerCancelPersistsNoDot() async throws {
        try await exerciseDotCancel("pptx")
    }

    /// Moving true-cancel contract (root review): a genuine pointerdown +
    /// several real pointermove + pointercancel sequence on the production
    /// window listener must leave the bridge with no stranded active stroke,
    /// must persist no partial path and no dot of any representation for the
    /// canceled contact, and must not disturb the previously completed
    /// strokes; the next genuine moving stroke still completes through the
    /// same bridge. Every event is a real dispatched PointerEvent reaching
    /// the pinned bridge's own registered listener — never a private
    /// cancel-handler call, never a fabricated up, no epsilon. On the
    /// integrated carrier (FloeOfficeNative.mm ce3543f, HEAD 08303a31) the
    /// ordered pointercancel closure aborts the unfinished core create, so
    /// the no-partial-ink gate is expected to pass; any persisted partial
    /// ink here is a genuine cancel-route regression. Never skipped, never
    /// weakened.
    func testDOCXMovingStrokeTruePointerCancelPersistsNoPartialPath() async throws {
        try await exerciseDotMovingCancel("docx")
    }
    func testXLSXMovingStrokeTruePointerCancelPersistsNoPartialPath() async throws {
        try await exerciseDotMovingCancel("xlsx")
    }
    func testPPTXMovingStrokeTruePointerCancelPersistsNoPartialPath() async throws {
        try await exerciseDotMovingCancel("pptx")
    }
    func testXLSXControlledStaleShapeHandleSelectionReplayStillDraws() async throws {
        try await exerciseStaleShapeHandleReplay("xlsx")
    }
    func testPPTXControlledStaleShapeHandleSelectionReplayStillDraws() async throws {
        try await exerciseStaleShapeHandleReplay("pptx")
    }

    /// Drawing-mode OFF→ON file-outcome contract for one format. One
    /// completed moving pen stroke through the production editor, then the
    /// real `OfficeFileSession.toggleDrawing` control OFF and ON again in the
    /// same session, then a second genuine moving contact, save and a fresh
    /// production reopen. The saved and reopened document must keep exactly
    /// the two real vector paths at the selected style and all original
    /// content, with no extra artifact. XLSX/PPTX are the same-selector
    /// contrast controls; the Writer re-enable outcome is the unmeasured
    /// case. Source only: the actual verdict belongs to root's full-App
    /// Simulator run and is neither claimed as a pass nor as a failure here.
    func testDOCXDrawingModeOffOnNextStrokePersistsAndReopens() async throws {
        try await exerciseDrawingModeOffOnNextStroke("docx")
    }
    func testXLSXDrawingModeOffOnNextStrokePersistsAndReopens() async throws {
        try await exerciseDrawingModeOffOnNextStroke("xlsx")
    }
    func testPPTXDrawingModeOffOnNextStrokePersistsAndReopens() async throws {
        try await exerciseDrawingModeOffOnNextStroke("pptx")
    }

    /// A rejected native drawing callback must revoke the App's published On
    /// state, the private native mirror and the page gate together. The fault
    /// wrapper invokes the real gate with `false` and then reports failure, so
    /// the production map is never permanently broken; the original function
    /// is restored before the test proves a normal cycle still works.
    func testRejectedDrawingToggleClearsAppAndNativeState() async throws {
        guard ProcessInfo.processInfo.environment["FLOE_NATIVE_DRAWING_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in App/native drawing failure regression; not executed")
        }
        executionTimeAllowance = 240
        continueAfterFailure = true
        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Qualification/OfficeDrawingFailure-\(UUID().uuidString)",
                                                     isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("failure.docx")
        try OfficeDocumentBuilder.createWord(at: source, title: "Pen failure",
                                             paragraphs: ["FAILURE-CLEAR-KEEP"])
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        let session = OfficeFileSession()
        let window = mount(session, in: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        do {
            await session.open(source)
            try await wait(120, "drawing failure regression open") {
                session.canAct && session.documentActionsReady && session.controller != nil
            }
            if session.readOnly {
                let accepted = await session.requestEditing()
                XCTAssertTrue(accepted, "Actual App edit entry rejected: \(session.error ?? "unknown")")
            }
            try await wait(150, "editable drawing failure document") {
                !session.readOnly && session.canAct && session.documentActionsReady && session.controller != nil
            }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))

            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode, "the real toggle must arm drawing before the failure case")
            XCTAssertEqual(try nativeDrawingFlag(native), true,
                           "the native host must mirror the armed state after a real toggle")

            try await withTemporaryDrawingModeFailure(web) {
                var rejected: Error?
                do { try await session.toggleDrawing() } catch { rejected = error }
                XCTAssertNotNil(rejected, "a rejected native drawing callback must surface an error")
                XCTAssertFalse(session.drawingMode,
                               "a rejected toggle must clear the published drawing state")
                XCTAssertNil(session.inkApplyOutcome, "a rejected toggle must clear the ink outcome")
                XCTAssertNil(session.inkError, "a rejected toggle must clear the ink error")
                XCTAssertEqual(try nativeDrawingFlag(native), false,
                               "the native private mirror must be disarmed after failure")
                let facts = try await officePenFacts(web)
                XCTAssertEqual(facts["drawing"] as? Bool, false,
                               "the page gate must be off after failure")
                XCTAssertEqual(facts["activeStroke"] as? Bool, false,
                               "a rejected toggle must not strand an active stroke")
            }

            // The wrapper is gone: the production gate, App state and native
            // mirror must all recover and still complete a normal cycle.
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode, "the real gate must recover after the temporary failure")
            XCTAssertEqual(try nativeDrawingFlag(native), true,
                           "the native mirror must recover with a successful toggle")
            try await session.toggleDrawing()
            XCTAssertFalse(session.drawingMode, "a normal disable must still publish Off")
            XCTAssertEqual(try nativeDrawingFlag(native), false,
                           "a successful disable must clear the native mirror")

            // Early capability guard with a live WebView: arm the real gate
            // directly, then reject through readOnly. The native mirror must
            // clear and the page routing must be revoked even though the
            // request fails; the returned error stays the real rejection.
            XCTAssertFalse(session.drawingMode, "the App state is Off before the direct guard case")
            let preGuardError = await setNativeDrawingMode(native, true)
            XCTAssertNil(preGuardError, "direct native enable must succeed before the guard case")
            XCTAssertEqual(try nativeDrawingFlag(native), true)
            let preGuardFacts = try await officePenFacts(web)
            XCTAssertEqual(preGuardFacts["drawing"] as? Bool, true,
                           "the page gate must be armed before the guard case")
            guard native.responds(to: NSSelectorFromString("setReadOnly:")) else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 24, userInfo: [
                    NSLocalizedDescriptionKey: "the native host does not expose the readOnly guard test seam"
                ])
            }
            native.setValue(true, forKey: "readOnly")
            let guardError = await setNativeDrawingMode(native, false)
            XCTAssertNotNil(guardError, "the readOnly guard must reject the toggle")
            XCTAssertEqual((guardError as NSError?)?.code, 35,
                           "the guard must return its real rejection, not a success")
            XCTAssertEqual(try nativeDrawingFlag(native), false,
                           "a guard rejection must clear the native mirror")
            let guardFacts = try await officePenFacts(web)
            XCTAssertEqual(guardFacts["drawing"] as? Bool, false,
                           "a guard rejection must revoke the page drawing routing")
            XCTAssertEqual(guardFacts["activeStroke"] as? Bool, false,
                           "a guard rejection must not leave an active stroke")
            native.setValue(false, forKey: "readOnly")

            // The App still completes a normal cycle after the guard cleanup.
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode, "the App must re-enable after a guard rejection")
            XCTAssertEqual(try nativeDrawingFlag(native), true)
            try await session.toggleDrawing()
            XCTAssertFalse(session.drawingMode, "the App must disable after a guard rejection")
            XCTAssertEqual(try nativeDrawingFlag(native), false)
            await session.release()
        } catch {
            await session.release()
            throw error
        }
    }

    /// Reopen previously saved synthetic assistant outputs with the newly linked
    /// engine. No model call or edit is performed by this qualification.
    func testPriorLiveModelArtifactsReopenWithoutAnotherModelCall() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FLOE_NATIVE_SAVED_ARTIFACTS_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in saved synthetic artifact reopen; not executed")
        }
        executionTimeAllowance = 1080
        continueAfterFailure = false
        let fm = FileManager.default
        let inputRoot = URL(fileURLWithPath: try XCTUnwrap(env["FLOE_NATIVE_SAVED_ARTIFACTS_ROOT"]), isDirectory: true)
        let manifestURL = URL(fileURLWithPath: try XCTUnwrap(env["FLOE_NATIVE_SAVED_ARTIFACTS_MANIFEST"]))
        let manifestSize = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard (1...65536).contains(manifestSize) else { throw CocoaError(.fileReadCorruptFile) }
        struct Manifest: Decodable {
            struct File: Decodable { let path: String; let sha256: String }
            let schemaVersion: Int; let files: [File]
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == 1, (1...6).contains(manifest.files.count),
              Set(manifest.files.map(\.path)).count == manifest.files.count else { throw CocoaError(.fileReadCorruptFile) }
        // Complete every target and hash preflight before mounting any Office UI.
        var inputs: [(url: URL, path: String, sha256: String)] = []
        for file in manifest.files {
            let url = try Self.savedArtifactURL(root: inputRoot, relativePath: file.path)
            guard file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  try hash(url) == file.sha256 else { throw CocoaError(.fileReadCorruptFile) }
            inputs.append((url, file.path, file.sha256))
        }
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let evidence = documents.appendingPathComponent("Qualification/OfficeSavedReopen-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: evidence, withIntermediateDirectories: true)
        print("FLOE_NATIVE_SAVED_ARTIFACTS_EVIDENCE=\(evidence.path)")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previous = scene.windows.first(where: \.isKeyWindow)
        defer { previous?.makeKey() }
        for (index, input) in inputs.enumerated() {
            // Revalidate immediately before each open, including path identity.
            let source = try Self.savedArtifactURL(root: inputRoot, relativePath: input.path)
            XCTAssertEqual(source, input.url)
            XCTAssertEqual(try hash(source), input.sha256)
            let session = OfficeFileSession()
            let window = mount(session, in: scene)
            defer { window.isHidden = true; window.rootViewController = nil }
            let prefix = String(format: "%02d", index + 1)
            var receipt: [String: Any] = ["relativePath": input.path, "sha256": input.sha256,
                "modelCalled": false, "editsPerformed": false, "visualReview": "pending-primary-image-review"]
            do {
                await session.open(source)
                try await wait(120, "saved artifact read-only open") {
                    session.canAct && session.documentActionsReady && session.controller != nil
                }
                XCTAssertTrue(session.readOnly, "Saved artifact qualification must not request editing")
                let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
                try await waitForPaint(native)
                // This case specifically requires actual decoded bitmap tiles;
                // an open-only policy or vector-ready string is insufficient.
                try await wait(45, "saved artifact decoded visible paint") {
                    let facts = OfficeFileSession.hostRenderDiagnostics(native)
                    return facts["stage"] == "visible-render" && facts["docLoaded"] == "1"
                        && (Int(facts["decodedTiles"] ?? "") ?? 0) > 0
                }
                receipt["nativeRenderDiagnostics"] = OfficeFileSession.hostRenderDiagnostics(native)
                let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
                let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
                let image = try await web.takeSnapshot(configuration: config)
                let png = evidence.appendingPathComponent("\(prefix)-native.png")
                try XCTUnwrap(image.pngData()).write(to: png); attach(png, name: "saved-artifact-\(prefix)-native")
                let whole = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let windowPNG = evidence.appendingPathComponent("\(prefix)-window.png")
                try XCTUnwrap(whole.pngData()).write(to: windowPNG); attach(windowPNG, name: "saved-artifact-\(prefix)-window")
                await session.release()
                XCTAssertEqual(try hash(source), input.sha256, "Read-only reopen changed saved artifact")
                receipt["sourceUnchangedAfterRelease"] = true
                receipt["decodedPaintPassed"] = true
            } catch {
                receipt["error"] = String(describing: error)
                if let native = session.controller as? FloeOfficeNativeViewController {
                    receipt["failureNativeRenderDiagnostics"] = OfficeFileSession.hostRenderDiagnostics(native)
                    if let web = OfficeExplicitSaveBridge.findWebView(in: native.view),
                       let image = try? await web.takeSnapshot(configuration: nil), let png = image.pngData() {
                        let target = evidence.appendingPathComponent("\(prefix)-failed-native.png")
                        try? png.write(to: target); attach(target, name: "saved-artifact-\(prefix)-failed-native")
                    }
                }
                await session.release()
                receipt["sourceUnchangedAfterRelease"] = (try? hash(source)) == input.sha256
                let target = evidence.appendingPathComponent("\(prefix)-receipt.json")
                try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: target)
                attach(target, name: "saved-artifact-\(prefix)-failure")
                window.isHidden = true; window.rootViewController = nil
                throw error
            }
            let target = evidence.appendingPathComponent("\(prefix)-receipt.json")
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: target)
            attach(target, name: "saved-artifact-\(prefix)-verification")
            window.isHidden = true; window.rootViewController = nil
        }
    }

    // Foundation-only boundary helper: no path traversal, aliases, symlinked
    // descendants, nonregular inputs or unbounded media under the allowed root.
    private static func savedArtifactURL(root: URL, relativePath: String) throws -> URL {
        guard root.isFileURL, !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"), !relativePath.contains("\0") else { throw CocoaError(.fileReadInvalidFileName) }
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              ["docx", "xlsx", "pptx"].contains(URL(fileURLWithPath: relativePath).pathExtension.lowercased()) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let allowed = root.standardizedFileURL.resolvingSymlinksInPath()
        let rootFacts = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootFacts.isDirectory == true, rootFacts.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        var target = allowed
        for part in parts {
            target.appendPathComponent(String(part))
            let facts = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard facts.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        }
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(allowed.path + "/") else { throw CocoaError(.fileReadNoPermission) }
        let facts = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard facts.isRegularFile == true, let size = facts.fileSize, size > 0, size < 16 * 1024 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return resolved
    }

    /// One deterministic contact stimulus. The first five contacts keep the
    /// original non-overlapping bands. The last five trace near-overlapping
    /// paths over the previous contact and route every PointerEvent through
    /// the real `document.elementFromPoint` target instead of forcing canvas.
    private struct StrokeStimulus {
        enum Kind: String {
            case band = "band-canvas-direct"
            case overlap = "overlap-hit-tested"
        }

        let index: Int
        let kind: Kind
        let gapMilliseconds: Int
        /// The real native style selected before this contact. Three ordinary
        /// pen, four marker and three highlighter contacts, kept while drawing
        /// mode stays on for the whole run. The style transition to highlighter
        /// deliberately happens after the 30 ms 5->6 overlap pair so applying a
        /// style can never lengthen that measured short-gap contact.
        let style: OfficeInkStylePreset
        var previousIndex: Int? { kind == .overlap ? index - 1 : nil }

        var facts: [String: Any] {
            ["index": index, "mode": kind.rawValue,
             "gapMilliseconds": gapMilliseconds, "overlapsStroke": previousIndex ?? -1,
             "style": style.rawValue]
        }
    }

    private static func stimulusPlan() -> [StrokeStimulus] {
        let styles: [OfficeInkStylePreset] = [.pen, .pen, .pen,
                                              .marker, .marker, .marker, .marker,
                                              .highlighter, .highlighter, .highlighter]
        return (0..<10).map { index in
            StrokeStimulus(index: index,
                           kind: index < 5 ? .band : .overlap,
                           gapMilliseconds: index.isMultiple(of: 2) ? 30 : 350,
                           style: styles[index])
        }
    }

    private func exercise(_ format: String) async throws {
        guard ProcessInfo.processInfo.environment["FLOE_NATIVE_DRAWING_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in App drawing + engine synthetic-stroke qualification; not executed")
        }
        executionTimeAllowance = 480
        // Accumulate package findings and still collect reopen images on a
        // validation failure; no false-success early return or weakened gate.
        continueAfterFailure = true
        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Qualification/OfficeDrawing-\(format)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("FLOE_NATIVE_DRAWING_ARTIFACT_ROOT=\(root.path)")
        let source = root.appendingPathComponent("original.\(format)")
        switch format {
        case "docx":
            try OfficeDocumentBuilder.createWord(at: source, title: "中文笔迹验收 Drawing",
                paragraphs: ["BASELINE-DRAWING-KEEP 中文正文 12345", "Second paragraph remains editable."])
        case "xlsx":
            try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [
                OfficeWorkbookSheet(name: "基准", rows: [["BASELINE-DRAWING-KEEP", "数值"], ["原值", "12"], ["公式", "=B2*2"]])
            ])
        default:
            try OfficeDocumentBuilder.createPresentation(at: source, title: "中文笔迹验收 Drawing", slides: [
                OfficePresentationSlide(title: "BASELINE-DRAWING-KEEP", bullets: ["中文原文 12345", "Editable original content"], notes: "DRAWING-NOTES-KEEP")
            ])
        }
        let sourceHash = try hash(source)
        let baseline = try package(source, format: format)
        XCTAssertEqual(baseline.customGeometryPaths.count, 0, "Fixture must contain no preinserted strokes")
        attach(source, name: "drawing-source-\(format)")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let session = OfficeFileSession()
        let window = mount(session, in: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        let exported: URL
        do {
            await session.open(source)
            try await wait(120, "initial native open") { session.canAct && session.documentActionsReady && session.controller != nil }
            if session.readOnly {
                let accepted = await session.requestEditing()
                XCTAssertTrue(accepted, "Actual App edit entry rejected: \(session.error ?? "unknown")")
            }
            try await wait(150, "editable native document") {
                !session.readOnly && session.canAct && session.documentActionsReady && session.controller != nil
            }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            // Keep mode armed across all contacts: toggling between them would
            // hide the production bridge's consecutive-stroke rearm defects.
            session.useInkPreferences(workspaceIdentity: root.path, documentKey: source.lastPathComponent)
            let preferences = session.inkPreferences
            let previousStroke = preferences.stroke
            defer {
                // Preset selection overwrites the two scalars by design; put
                // the exact pre-test values back afterwards, including a legacy
                // width that does not match its stored style label.
                preferences.setPreset(previousStroke.preset)
                preferences.setColorHex(previousStroke.colorHex)
                preferences.setWidthMillimeters(previousStroke.widthMillimeters)
                preferences.setTransparencyPercent(previousStroke.transparencyPercent)
            }
            let expectedStyles: [OfficeInkStylePreset: OfficeInkStroke] = [
                .pen: OfficeInkStroke(colorHex: "#FF0000", widthMillimeters: 0.5,
                                      transparencyPercent: 0, preset: .pen),
                .marker: OfficeInkStroke(colorHex: "#0000FF", widthMillimeters: 2.0,
                                         transparencyPercent: 0, preset: .marker),
                .highlighter: OfficeInkStroke(colorHex: "#FFCC00", widthMillimeters: 4.0,
                                              transparencyPercent: 60, preset: .highlighter)
            ]
            let expectedStyleOrder: [OfficeInkStylePreset] = [.pen, .marker, .highlighter]
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode)
            var penReceipts: [[String: Any]] = []
            let stimuli = Self.stimulusPlan()
            let expectedStyleCounts = Dictionary(grouping: stimuli, by: \.style)
                .mapValues { $0.count }
            XCTAssertEqual(expectedStyleCounts[.pen], 3, "Three ordinary pen contacts required")
            XCTAssertEqual(expectedStyleCounts[.marker], 4, "Four marker contacts required")
            XCTAssertEqual(expectedStyleCounts[.highlighter], 3, "Three highlighter contacts required")
            var previousPoints: [[Double]] = []
            var appliedStyle: OfficeInkStylePreset?
            for stimulus in stimuli {
                let index = stimulus.index
                guard let expected = expectedStyles[stimulus.style] else {
                    throw NSError(domain: "OfficeNativeDrawingQualification", code: 34,
                                  userInfo: [NSLocalizedDescriptionKey: "No expectation for selected style"])
                }
                // Same per-document setters and App reapply action as the pen
                // panel; preserve drawing mode across contacts and style
                // changes. Selecting a style writes its real width and
                // transparency through the normal preference API.
                if stimulus.style != appliedStyle {
                    preferences.setPreset(stimulus.style)
                    preferences.setColorHex(expected.colorHex)
                    await session.applyInkPreferences()
                    guard session.inkError == nil else { throw NSError(domain: "OfficeNativeDrawingQualification", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: session.inkError ?? "App ink attributes unavailable"]) }
                    XCTAssertEqual(preferences.stroke.preset, stimulus.style)
                    XCTAssertEqual(preferences.stroke.widthMillimeters, expected.widthMillimeters)
                    XCTAssertEqual(preferences.stroke.transparencyPercent, expected.transparencyPercent)
                    XCTAssertEqual(preferences.stroke.colorHex, expected.colorHex)
                    appliedStyle = stimulus.style
                }
                // Keep the original alternating 30/350 ms gaps. The overlap
                // subset starts at contact 6, so 6->7 is a 30 ms overlapping
                // pair; never lengthen a gap to hide a hit-test miss.
                try await Task.sleep(nanoseconds: UInt64(stimulus.gapMilliseconds) * 1_000_000)
                let sent = try await receiveStroke(index, web: web, native: native, window: window, root: root,
                    syntheticSource: source, stimulus: stimulus,
                    previousPoints: stimulus.kind == .overlap ? previousPoints : [])
                XCTAssertEqual(sent["strokeDelta"] as? Int, 1, "Actual pen bridge did not finish the stroke")
                XCTAssertGreaterThanOrEqual(sent["coreEventDelta"] as? Int ?? 0, 5, "Actual pen bridge did not forward all events")
                XCTAssertEqual(sent["activeAfter"] as? Bool, false)
                XCTAssertEqual(sent["downAccepted"] as? Bool, true,
                               "The real pen down must be accepted by the production bridge")
                try validateHitDiagnostics(sent, stimulus: stimulus)
                previousPoints = try clientPoints(sent, index: index)
                penReceipts.append(sent)
            }
            let overlapReceipts = penReceipts.filter {
                ($0["stimulusMode"] as? String) == StrokeStimulus.Kind.overlap.rawValue
            }
            XCTAssertEqual(overlapReceipts.count, 5, "Five hit-tested overlap contacts are required")
            XCTAssertTrue(overlapReceipts.contains {
                ($0["gapMilliseconds"] as? Int) == 30 && (($0["previousStrokeID"] as? Int) ?? -1) >= 5
            }, "A 30 ms pair of successive overlapping hit-tested strokes is required")
            XCTAssertTrue(overlapReceipts.allSatisfy {
                ($0["elapsedSincePreviousStrokeMilliseconds"] as? NSNumber) != nil
            }, "Every overlap contact must record its measured elapsed time")
            if session.drawingMode { try await session.toggleDrawing() }
            let nativeCopy = try await session.exportDocument(format: format)
            let copy = root.appendingPathComponent("drawn.\(format)")
            try fm.copyItem(at: nativeCopy, to: copy)
            exported = copy
            attach(copy, name: "drawing-native-saved-\(format)")
            XCTAssertEqual(try hash(source), sourceHash, "Native copy export altered original")
            let result = try package(copy, format: format)
            XCTAssertTrue(result.text.contains("BASELINE-DRAWING-KEEP"), "Original content lost")
            XCTAssertGreaterThanOrEqual(result.customGeometryPaths.count, 10, "Ten newly saved vector paths required")
            XCTAssertGreaterThanOrEqual(Set(result.customGeometryPaths).count, 10, "Stroke geometry must differ")
            XCTAssertTrue(result.customGeometryPointCounts.allSatisfy { $0 >= 3 }, "Missing actual vector points")
            // a:ln width is EMU (36,000/mm); App UNO width is 1/100 mm.
            // Allow one twip (635 EMU) for Writer's supported round-trip
            // quantization, far smaller than the deliberately different widths.
            for preset in expectedStyleOrder {
                guard let style = expectedStyles[preset] else { continue }
                let expectedEMU = style.lineWidthValue * 360
                let color = String(style.colorHex.dropFirst()).uppercased()
                XCTAssertTrue(result.vectorShapes.contains { shape in
                    shape.colorHex?.uppercased() == color
                        && shape.widthEMU.map { abs($0 - expectedEMU) <= 635 } == true
                        && !shape.paths.isEmpty
                }, "Actual saved vector shape did not retain \(preset.rawValue) \(color) / \(expectedEMU) EMU: \(result.vectorShapes)")
            }
            // Transparency must be a saved line alpha, not a UI-only label:
            // highlighter 60% transparent -> 40% opacity (40000), while pen
            // and marker stay opaque (no alpha or 100000). The small tolerance
            // only covers integer rounding, never a different style.
            let alphaTolerance = 1_000
            for preset in expectedStyleOrder {
                guard let style = expectedStyles[preset] else { continue }
                let expectedEMU = style.lineWidthValue * 360
                let color = String(style.colorHex.dropFirst()).uppercased()
                let matching = result.vectorShapes.filter {
                    $0.colorHex?.uppercased() == color
                        && $0.widthEMU.map { abs($0 - expectedEMU) <= 635 } == true
                        && !$0.paths.isEmpty
                }
                XCTAssertFalse(matching.isEmpty, "No saved vector shape for \(preset.rawValue)")
                XCTAssertEqual(matching.count, expectedStyleCounts[preset] ?? 0,
                               "Every \(preset.rawValue) contact must retain its own saved style")
                switch preset {
                case .highlighter:
                    XCTAssertTrue(matching.allSatisfy { shape in
                        guard let alpha = shape.alphaValue else { return false }
                        return abs(alpha - 40_000) <= alphaTolerance
                    }, "Highlighter must save a real 40% opacity line alpha: \(result.vectorShapes)")
                case .pen, .marker:
                    XCTAssertTrue(matching.allSatisfy {
                        $0.alphaValue == nil || $0.alphaValue == 100_000
                    }, "Opaque \(preset.rawValue) strokes must not save a transparent line alpha: \(result.vectorShapes)")
                }
            }
            if format == "xlsx" {
                XCTAssertEqual(result.cells["B2"], "12", "Excel basic value lost")
                XCTAssertEqual(result.formulas["B3"], "B2*2", "Excel formula lost or flattened")
                XCTAssertGreaterThanOrEqual(result.validAnchors, 10, "Excel strokes need nonzero visible sheet anchors")
            }
            if format == "pptx" { XCTAssertTrue(result.text.contains("DRAWING-NOTES-KEEP"), "Speaker notes lost") }
            let expectedLineStyles: [[String: Any]] = expectedStyleOrder.compactMap { preset in
                guard let style = expectedStyles[preset] else { return nil }
                return ["preset": preset.rawValue, "color": style.colorHex,
                        "widthEMU": style.lineWidthValue * 360,
                        "transparency": style.transparencyPercent,
                        "alpha": (100 - style.transparencyPercent) * 1_000] as [String: Any]
            }
            let expectedStyleCountValues = Dictionary(uniqueKeysWithValues:
                expectedStyleCounts.map { ($0.key.rawValue, $0.value) })
            let manifest: [String: Any] = [
                "format": format, "sourceSHA256": sourceHash, "outputSHA256": try hash(copy),
                "route": "OfficeFileSession.toggleDrawing/applyInkPreferences/pen-PointerEvent/production-DOM-MouseEvent/frontend-core/exportDocument",
                "strokeStimulusPlan": stimuli.map { $0.facts },
                "expectedStyleCounts": expectedStyleCountValues,
                "hitTestRouting": "first five bands canvas-direct; last five overlap contacts document.elementFromPoint; no fabricated overlay",
                "hitDiagnostics": "bounded tag/id/class/ownership, hit coordinates, overlay census, pre/post CanvasSection hit and bound names, stale-handle suspension counters and contact lifecycle; no page text",
                "hardwarePointerInput": "not-tested", "pressure": "not-tested",
                "syntheticPenBridgeReceipts": penReceipts,
                "expectedLineStyles": expectedLineStyles,
                "savedVectorLineStyles": result.vectorShapes.map { ["color": $0.colorHex ?? "MISSING", "widthEMU": $0.widthEMU ?? -1, "paths": $0.paths.count, "alpha": $0.alphaValue ?? -1] as [String: Any] },
                "lineWidthToleranceEMU": 635,
                "alphaTolerance": alphaTolerance,
                "vectorPaths": result.customGeometryPaths.count,
                "distinctVectorPaths": Set(result.customGeometryPaths).count,
                "vectorPointCounts": result.customGeometryPointCounts,
                "excelVisibleAnchors": result.validAnchors,
                "visualReview": "pending-primary-image-review"
            ]
            let receipt = root.appendingPathComponent("verification.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: receipt)
            attach(receipt, name: "drawing-verification-\(format)")
            await session.release()
        } catch { await session.release(); throw error }

        // Fresh native session, same production App surface, exact saved copy.
        let reopen = OfficeFileSession()
        let reopenWindow = mount(reopen, in: scene)
        defer { reopenWindow.isHidden = true; reopenWindow.rootViewController = nil }
        do {
            await reopen.open(exported)
            try await wait(120, "saved vector document reopen") { reopen.canAct && reopen.documentActionsReady && reopen.controller != nil }
            let native = try XCTUnwrap(reopen.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
            let image = try await web.takeSnapshot(configuration: config)
            let png = try XCTUnwrap(image.pngData())
            let screenshot = root.appendingPathComponent("reopened-native-\(format).png")
            try png.write(to: screenshot)
            attach(screenshot, name: "drawing-reopened-native-\(format)")
            let windowImage = UIGraphicsImageRenderer(bounds: reopenWindow.bounds).image { _ in
                reopenWindow.drawHierarchy(in: reopenWindow.bounds, afterScreenUpdates: true)
            }
            let whole = root.appendingPathComponent("reopened-window-\(format).png")
            try XCTUnwrap(windowImage.pngData()).write(to: whole)
            attach(whole, name: "drawing-reopened-window-\(format)")
            let receiptURL = root.appendingPathComponent("verification.json")
            var receipt = (try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL))) as? [String: Any] ?? [:]
            receipt["savedCopyReopened"] = true
            receipt["reopenNativeRenderDiagnostics"] = OfficeFileSession.hostRenderDiagnostics(native)
            receipt["visualReview"] = "pending-primary-image-review"
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: receiptURL)
            attach(receiptURL, name: "drawing-reopen-verification-\(format)")
            await reopen.release()
        } catch { await reopen.release(); throw error }
    }

    /// PRE-FIX baseline. See the three opt-in selectors above. This never
    /// weakens the human dot contract: a missing or invisible dot fails. A
    /// control-only save/reopen is produced from the same fixture first, so
    /// the control proves the route/tool before the zero-motion contact and
    /// provides the exact render baseline for the reopened-page pixel diff.
    /// `dotPreset` selects the real dot ink style. `.marker` (the three frozen
    /// selectors) keeps its explicit 0% transparency, the original seam
    /// arguments, waits and the nil/100000 opaque gate unchanged.
    /// `.highlighter` selects the real highlighter preset and derives the
    /// expected dot alpha from the actually selected stroke (strict 40000;
    /// a missing alpha element is valid only when the expectation is 100000),
    /// adds the opposite-style alpha/width cross-negatives below and requests
    /// the paint handoff receipt from the extended seam.
    private func exerciseZeroMotionPenDot(_ format: String,
                                          dotPreset: OfficeInkStylePreset = .marker) async throws {
        guard ProcessInfo.processInfo.environment["FLOE_NATIVE_DRAWING_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in native zero-motion dot baseline; not executed")
        }
        executionTimeAllowance = 600
        // Keep collecting the control/save/reopen evidence after a failed dot
        // assertion. The test still fails because every contract assertion is
        // retained; nothing is skipped or converted to an expected pass.
        continueAfterFailure = true
        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Qualification/OfficeZeroMotionDot-\(format)-\(UUID().uuidString)",
                                                     isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("FLOE_ZERO_MOTION_DOT_ARTIFACT_ROOT=\(root.path)")
        let source = root.appendingPathComponent("original.\(format)")
        switch format {
        case "docx":
            try OfficeDocumentBuilder.createWord(at: source, title: "中文零位移圆点验收",
                paragraphs: ["BASELINE-DOT-KEEP 中文正文 12345", "Second paragraph remains editable."])
        case "xlsx":
            try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [
                OfficeWorkbookSheet(name: "圆点", rows: [["BASELINE-DOT-KEEP", "数值"], ["原值", "12"], ["公式", "=B2*2"]])
            ])
        default:
            try OfficeDocumentBuilder.createPresentation(at: source, title: "中文零位移圆点验收", slides: [
                OfficePresentationSlide(title: "BASELINE-DOT-KEEP", bullets: ["中文原文 12345", "Editable original content"],
                                        notes: "DOT-NOTES-KEEP")
            ])
        }
        let sourceHash = try hash(source)
        let baseline = try package(source, format: format)
        XCTAssertEqual(baseline.customGeometryPaths.count, 0, "Fixture must contain no preinserted strokes")
        attach(source, name: "dot-source-\(format)")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let session = OfficeFileSession()
        let window = mount(session, in: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        let checkpoint: URL
        let exported: URL
        var controlPackage: DrawingQualificationXML?
        var controlPersisted = false
        var dotRouteAccepted = false
        var dotFraction: [Double]?
        var controlStyleEMU = 0
        var dotStyleEMU = 0
        var dotAlphaExpected = 100_000
        var controlShapeCount = 0
        var dotShapeCount = 0
        var dotPreSaveImage: UIImage?
        var dotOriginalClientPoint: CGPoint?
        // A persisted zero-motion dot is either the native filled circle the
        // engine finalizes for a tap (prstGeom ellipse, selected colour, no
        // outline) or, if another representation ever persisted, the previous
        // path-based candidate. The classifier is the accepted v1 predicate,
        // now shared with the new lifecycle exercises.
        let isNativeDotShape = Self.nativeDotShape
        do {
            await session.open(source)
            try await wait(120, "initial native open") {
                session.canAct && session.documentActionsReady && session.controller != nil
            }
            if session.readOnly {
                let accepted = await session.requestEditing()
                XCTAssertTrue(accepted, "Actual App edit entry rejected: \(session.error ?? "unknown")")
            }
            try await wait(150, "editable native document") {
                !session.readOnly && session.canAct && session.documentActionsReady && session.controller != nil
            }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            session.useInkPreferences(workspaceIdentity: root.path, documentKey: source.lastPathComponent)
            let preferences = session.inkPreferences
            let previousStroke = preferences.stroke
            defer {
                preferences.setPreset(previousStroke.preset)
                preferences.setColorHex(previousStroke.colorHex)
                preferences.setWidthMillimeters(previousStroke.widthMillimeters)
                preferences.setTransparencyPercent(previousStroke.transparencyPercent)
            }
            // Positive control: one short real native vector stroke through
            // the existing production pen bridge, then a control-only save
            // and reopen (below). This proves the route/tool before the dot.
            preferences.setPreset(.pen)
            preferences.setColorHex("#FF0000")
            preferences.setTransparencyPercent(0)
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode, "the real App drawing toggle must arm")
            await session.applyInkPreferences()
            XCTAssertNil(session.inkError, "control pen preferences must apply")
            let controlInkAck = session.inkApplyOutcome.map {
                $0 == .verified ? "verified" : "dispatchedUnverified"
            } ?? "nil"
            XCTAssertEqual(try nativeDrawingFlag(native), true)
            let controlStroke = preferences.stroke
            let preControlFacts = try await officePenFacts(web)
            XCTAssertEqual(preControlFacts["drawing"] as? Bool, true)
            XCTAssertEqual(preControlFacts["activeStroke"] as? Bool, false)
            let controlStimulus = StrokeStimulus(index: 0, kind: .band, gapMilliseconds: 30, style: .pen)
            let controlReceipt = try await receiveStroke(0, web: web, native: native, window: window, root: root,
                syntheticSource: source, stimulus: controlStimulus, previousPoints: [])
            try validateHitDiagnostics(controlReceipt, stimulus: controlStimulus)
            XCTAssertEqual(controlReceipt["strokeDelta"] as? Int, 1,
                           "The positive control did not complete through the actual pen bridge")
            XCTAssertEqual(controlReceipt["downAccepted"] as? Bool, true,
                           "The positive control down was not accepted by the production bridge")
            let postControlFacts = try await officePenFacts(web)
            XCTAssertEqual((postControlFacts["strokes"] as? Int ?? -1),
                           (preControlFacts["strokes"] as? Int ?? -1) + 1,
                           "The positive control must be counted by the actual pen bridge")
            if session.drawingMode { try await session.toggleDrawing() }
            XCTAssertFalse(session.drawingMode)
            let controlCopy = root.appendingPathComponent("control.\(format)")
            try fm.copyItem(at: try await session.exportDocument(format: format), to: controlCopy)
            checkpoint = controlCopy
            attach(controlCopy, name: "dot-control-saved-\(format)")
            let controlSaved = try package(controlCopy, format: format)
            controlPackage = controlSaved
            XCTAssertEqual(controlSaved.customGeometryPaths.count, 1,
                           "Positive control must save exactly one real native vector path before the dot")
            XCTAssertTrue(controlSaved.text.contains("BASELINE-DOT-KEEP"), "Control save lost original content")
            controlStyleEMU = controlStroke.lineWidthValue * 360
            let controlShapes = controlSaved.vectorShapes.filter { shape in
                shape.colorHex?.uppercased() == "FF0000"
                    && shape.widthEMU.map { abs($0 - controlStyleEMU) <= 635 } == true
                    && !shape.paths.isEmpty
            }
            controlShapeCount = controlShapes.count
            let prematureDotShapes = controlSaved.vectorShapes.filter { shape in
                (shape.colorHex?.uppercased() == "0000FF" && !shape.paths.isEmpty)
                    || isNativeDotShape(shape)
            }
            controlPersisted = controlSaved.customGeometryPaths.count == 1
                && controlShapes.count == 1 && prematureDotShapes.isEmpty
            XCTAssertTrue(controlPersisted,
                          "Positive control did not persist as exactly one red 0.5 mm vector: \(controlSaved.vectorShapes)")
            // Exact zero-motion contact: the dedicated seam dispatches only
            // pointerdown+pointerup at one identical client point. There is no
            // pointermove, no preview-only substitute and no epsilon.
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode, "the App must re-arm drawing for the dot")
            preferences.setPreset(dotPreset)
            preferences.setColorHex("#0000FF")
            if dotPreset == .marker {
                preferences.setTransparencyPercent(0)
            }
            await session.applyInkPreferences()
            XCTAssertNil(session.inkError, "dot \(dotPreset.rawValue) preferences must apply")
            let dotInkAck = session.inkApplyOutcome.map {
                $0 == .verified ? "verified" : "dispatchedUnverified"
            } ?? "nil"
            XCTAssertEqual(preferences.stroke.preset, dotPreset)
            XCTAssertEqual(preferences.stroke.widthMillimeters, dotPreset.widthMillimeters)
            XCTAssertEqual(preferences.stroke.colorHex, "#0000FF")
            let dotStroke = preferences.stroke
            dotStyleEMU = dotStroke.lineWidthValue * 360
            dotAlphaExpected = (100 - dotStroke.transparencyPercent) * 1_000
            if dotPreset == .marker {
                XCTAssertEqual(preferences.stroke.widthMillimeters, 2.0)
                XCTAssertEqual(preferences.stroke.transparencyPercent, 0,
                               "the frozen opaque marker variant must really carry no transparency")
                XCTAssertEqual(dotAlphaExpected, 100_000)
            } else {
                XCTAssertEqual(preferences.stroke.transparencyPercent, dotPreset.transparencyPercent)
                XCTAssertGreaterThan(preferences.stroke.transparencyPercent, 0,
                                     "the explicitly selected highlighter variant must really be transparent")
            }
            let nativeFlagBeforeDot = try nativeDrawingFlag(native)
            let nativeRenderBeforeDot = OfficeFileSession.hostRenderDiagnostics(native)
            let preDotFacts = try await officePenFacts(web)
            XCTAssertEqual(nativeFlagBeforeDot, true, "the native host must mirror armed drawing before the dot")
            XCTAssertEqual(preDotFacts["drawing"] as? Bool, true)
            XCTAssertEqual(preDotFacts["activeStroke"] as? Bool, false,
                           "a previous stroke must not remain active before the dot")
            let wantsPaintReceipt = dotPreset != .marker
            let zeroMotion = try await receiveZeroMotionDot(web: web, native: native, window: window,
                                                            root: root, syntheticSource: source,
                                                            paintReceipt: wantsPaintReceipt)
            if let raw = zeroMotion["dotFraction"] as? [Any], raw.count == 2,
               let fx = (raw[0] as? NSNumber)?.doubleValue,
               let fy = (raw[1] as? NSNumber)?.doubleValue, fx.isFinite, fy.isFinite {
                dotFraction = [fx, fy]
            }
            let routeReady = zeroMotion["routeReady"] as? Bool == true
            XCTAssertTrue(routeReady,
                          "The exact zero-motion input route was not prepared; this is not classified as an engine dot defect: \(zeroMotion)")
            if routeReady {
                XCTAssertEqual(zeroMotion["eventsDispatched"] as? Int, 2,
                               "The zero-motion seam must dispatch exactly one down and one up")
                XCTAssertEqual(zeroMotion["movesDispatched"] as? Int, 0,
                               "The zero-motion seam must not fabricate a move")
                if let rawPoints = zeroMotion["clientPoints"] as? [[Any]], rawPoints.count == 2,
                   let x0 = (rawPoints[0][0] as? NSNumber)?.doubleValue,
                   let y0 = (rawPoints[0][1] as? NSNumber)?.doubleValue,
                   let x1 = (rawPoints[1][0] as? NSNumber)?.doubleValue,
                   let y1 = (rawPoints[1][1] as? NSNumber)?.doubleValue {
                    dotOriginalClientPoint = CGPoint(x: x0, y: y0)
                    XCTAssertEqual(x0, x1, "The zero-motion down and up must use one identical X")
                    XCTAssertEqual(y0, y1, "The zero-motion down and up must use one identical Y")
                } else {
                    XCTFail("The zero-motion receipt did not expose its two identical client points")
                }
                if let pressure = zeroMotion["pressure"] as? [String: Any],
                   let down = (pressure["down"] as? NSNumber)?.doubleValue,
                   let up = (pressure["up"] as? NSNumber)?.doubleValue {
                    XCTAssertTrue(down.isFinite && up.isFinite,
                                  "The synthetic pressure facts must be finite")
                } else {
                    XCTFail("The zero-motion receipt did not expose finite pressure facts")
                }
                XCTAssertEqual(zeroMotion["downAccepted"] as? Bool, true,
                               "The actual production pen bridge did not accept the zero-motion down; not a dot-persistence defect")
                XCTAssertEqual(zeroMotion["activeAfterDown"] as? Bool, true,
                               "The production bridge must own the contact after the zero-motion down")
                XCTAssertEqual(zeroMotion["activeAfterUp"] as? Bool, false,
                               "The production bridge must finish the zero-motion contact")
                XCTAssertEqual(zeroMotion["strokeDelta"] as? Int, 1,
                               "The production bridge must count the completed zero-motion contact")
                XCTAssertEqual(zeroMotion["coreEventDelta"] as? Int, 2,
                               "The canonical replay for a zero-motion contact must be exactly mousedown+mouseup")
                dotRouteAccepted = zeroMotion["downAccepted"] as? Bool == true
                    && zeroMotion["activeAfterDown"] as? Bool == true
                    && zeroMotion["activeAfterUp"] as? Bool == false
                    && zeroMotion["strokeDelta"] as? Int == 1
                    && zeroMotion["coreEventDelta"] as? Int == 2
            }
            if wantsPaintReceipt && dotRouteAccepted {
                validateDotPaintReceipt(zeroMotion, label: "\(dotPreset.rawValue) dot")
            }
            try await Task.sleep(for: .milliseconds(350))
            let postDotFacts = try await officePenFacts(web)
            XCTAssertEqual(postDotFacts["activeStroke"] as? Bool, false,
                           "A rejected zero-motion contact must not leave an active stroke")
            if dotRouteAccepted {
                XCTAssertEqual((postDotFacts["strokes"] as? Int ?? -1),
                               (preDotFacts["strokes"] as? Int ?? -1) + 1,
                               "The production bridge must count the completed zero-motion contact")
            }
            let nativeFlagAfterDot = try nativeDrawingFlag(native)
            let nativeRenderAfterDot = OfficeFileSession.hostRenderDiagnostics(native)
            XCTAssertEqual(nativeFlagAfterDot, true,
                           "the native host drawing mirror must remain armed after the dot")
            let dotSurface = root.appendingPathComponent("dot-before-save-\(format).png")
            let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = true
            if let image = try? await web.takeSnapshot(configuration: configuration), let png = image.pngData() {
                dotPreSaveImage = image
                try png.write(to: dotSurface); attach(dotSurface, name: "dot-before-save-\(format)")
            }
            if session.drawingMode { try await session.toggleDrawing() }
            XCTAssertFalse(session.drawingMode)
            let nativeFlagAfterDisable = try nativeDrawingFlag(native)
            XCTAssertEqual(nativeFlagAfterDisable, false)
            let finalCopy = root.appendingPathComponent("drawn.\(format)")
            try fm.copyItem(at: try await session.exportDocument(format: format), to: finalCopy)
            exported = finalCopy
            attach(finalCopy, name: "dot-native-saved-\(format)")
            XCTAssertEqual(try hash(source), sourceHash, "Native copy export altered original")
            let saved = try package(finalCopy, format: format)
            XCTAssertTrue(saved.text.contains("BASELINE-DOT-KEEP"), "Final save lost original content")
            let finalControlShapes = saved.vectorShapes.filter { shape in
                shape.colorHex?.uppercased() == "FF0000"
                    && shape.widthEMU.map { abs($0 - controlStyleEMU) <= 635 } == true
                    && !shape.paths.isEmpty
            }
            // Every saved vector shape that is not the red 0.5 mm control is
            // the dot candidate: either the semantic native filled circle or
            // any real persisted path. This separates "the dot did not
            // persist" from "the dot persisted with the wrong selected style".
            let dotShapes = saved.vectorShapes.filter { shape in
                let isControl = shape.colorHex?.uppercased() == "FF0000"
                    && shape.widthEMU.map { abs($0 - controlStyleEMU) <= 635 } == true
                return !isControl && (isNativeDotShape(shape) || !shape.paths.isEmpty)
            }
            controlShapeCount = finalControlShapes.count
            dotShapeCount = dotShapes.count
            XCTAssertGreaterThanOrEqual(finalControlShapes.count, 1,
                                        "The positive control must still be present after the dot contact")
            if dotRouteAccepted && controlPersisted {
                XCTAssertFalse(dotShapes.isEmpty,
                    "BASELINE DEFECT (EXPECTED on pinned v1, not a weakened test): zero-motion dot accepted by the production pen bridge "
                    + "(down/up identical point, coreEventDelta=2, strokeDelta=1) but the saved \(format) has "
                    + "\(saved.customGeometryPaths.count) custom geometry path(s); control=\(finalControlShapes.count), dot=\(dotShapes.count). "
                    + "The human contract requires a persisted dot.")
            } else {
                XCTAssertFalse(dotShapes.isEmpty,
                    "Zero-motion dot was not persisted, but the control/route preconditions did not pass, so this is "
                    + "not classified as an engine dot defect: controlPersisted=\(controlPersisted) dotRouteAccepted=\(dotRouteAccepted) "
                    + "dotShapes=\(dotShapes.count) paths=\(saved.customGeometryPaths.count).")
            }
            if dotShapes.count > 0 {
                XCTAssertEqual(dotShapes.count, 1,
                               "The zero-motion contact must save exactly one new dot object")
                let dot = dotShapes[0]
                // Cross-negative expectations derived from the actual selection:
                // the opposite style's alpha/width MUST reject this real
                // persisted dot, so no "either style allowed" gate can exist.
                let oppositeAlphaValue = dotAlphaExpected == 100_000 ? 40_000 : 100_000
                let oppositePreset: OfficeInkStylePreset = dotPreset == .highlighter ? .marker : .highlighter
                let oppositeWidthEMU = OfficeInkStroke(colorHex: "#0000FF",
                                                       widthMillimeters: oppositePreset.widthMillimeters,
                                                       transparencyPercent: oppositePreset.transparencyPercent,
                                                       preset: oppositePreset).lineWidthValue * 360
                if isNativeDotShape(dot) {
                    // Native filled-circle persistence: the diameter is the
                    // square extent, the colour/alpha live in the fill, and an
                    // outline is structurally forbidden (it would paint 2W).
                    XCTAssertTrue(dot.widthEMU == nil || dot.widthEMU == 0,
                                  "A native dot must not save an outline width: \(dot)")
                    XCTAssertEqual(dot.extentEMU?.count, 2,
                                   "The native dot must save its own spPr extent: \(dot)")
                    let diameterEMU = dot.extentEMU?[0] ?? -1
                    let heightEMU = dot.extentEMU?[1] ?? -2
                    XCTAssertEqual(diameterEMU, heightEMU,
                                   "The native dot extent must be square (a true circle): \(dot)")
                    XCTAssertTrue(abs(diameterEMU - dotStyleEMU) <= 635,
                                  "The native dot diameter must equal the selected \(dotPreset.rawValue) width \(dotStyleEMU) EMU: \(dot)")
                    XCTAssertTrue(Self.dotAlphaSatisfies(dot.fillAlphaValue, expected: dotAlphaExpected),
                                  "The native dot fill alpha must equal the selected \(dotPreset.rawValue) style alpha \(dotAlphaExpected) (nil is only valid for the 100000 expectation): \(dot)")
                    XCTAssertFalse(Self.dotAlphaSatisfies(dot.fillAlphaValue, expected: oppositeAlphaValue),
                                  "cross-negative: a selected \(dotPreset.rawValue) dot must not satisfy the opposite alpha \(oppositeAlphaValue): \(dot)")
                    XCTAssertFalse(abs(diameterEMU - oppositeWidthEMU) <= 635,
                                  "cross-negative: the selected \(dotPreset.rawValue) dot must not satisfy the opposite width \(oppositeWidthEMU) EMU: \(dot)")
                } else {
                    XCTAssertTrue(dot.colorHex?.uppercased() == "0000FF",
                                  "The persisted dot must retain its selected marker blue: \(dot)")
                    XCTAssertTrue(dot.widthEMU.map { abs($0 - dotStyleEMU) <= 635 } == true,
                                  "The persisted dot must retain its selected \(dotPreset.rawValue) width: \(dot)")
                    XCTAssertTrue(Self.dotAlphaSatisfies(dot.alphaValue, expected: dotAlphaExpected),
                                  "The persisted dot line alpha must equal the selected \(dotPreset.rawValue) style alpha \(dotAlphaExpected) (nil is only valid for the 100000 expectation): \(dot)")
                    XCTAssertFalse(Self.dotAlphaSatisfies(dot.alphaValue, expected: oppositeAlphaValue),
                                  "cross-negative: a selected \(dotPreset.rawValue) dot must not satisfy the opposite alpha \(oppositeAlphaValue): \(dot)")
                    if let persistedWidthEMU = dot.widthEMU {
                        XCTAssertFalse(abs(persistedWidthEMU - oppositeWidthEMU) <= 635,
                                      "cross-negative: the selected \(dotPreset.rawValue) dot must not satisfy the opposite width \(oppositeWidthEMU) EMU: \(dot)")
                    }
                }
            }
            if format == "xlsx" {
                XCTAssertEqual(saved.cells["B2"], "12", "Excel basic value lost")
                XCTAssertEqual(saved.formulas["B3"], "B2*2", "Excel formula lost or flattened")
                XCTAssertGreaterThanOrEqual(saved.validAnchors, 1, "Positive control needs a valid Excel sheet anchor")
            }
            if format == "pptx" { XCTAssertTrue(saved.text.contains("DOT-NOTES-KEEP"), "Speaker notes lost") }
            let manifest: [String: Any] = [
                "format": format, "sourceSHA256": sourceHash,
                "controlCheckpointSHA256": try hash(checkpoint),
                "outputSHA256": try hash(finalCopy),
                "humanContract": "A zero-motion Pencil contact at one client point must persist a real native vector dot and survive save/reopen with visible engine pixels.",
                "expectedBaseline": "Pinned v1 may reject the single-point FreehandLine; this test must fail then with accepted down/up and control-persistence evidence, not pass or skip.",
                "route": "OfficeFileSession.toggleDrawing/applyInkPreferences/real pen pointerdown+pointerup at one point/FloeOfficeNative production gate/DOM mousedown+mouseup/core/exportDocument/reopen",
                "zeroMotionSeam": "dedicated real production-bridge seam: exactly pointerdown+pointerup at one identical client point; no pointermove, no epsilon, no preview-only substitute",
                "controlStimulus": controlStimulus.facts,
                "controlReceipt": controlReceipt,
                "zeroMotionReceipt": zeroMotion,
                "preControlPenFacts": preControlFacts,
                "postControlPenFacts": postControlFacts,
                "preDotPenFacts": preDotFacts,
                "postDotPenFacts": postDotFacts,
                "nativeAck": [
                    "drawingModeBeforeDot": nativeFlagBeforeDot,
                    "drawingModeAfterDot": nativeFlagAfterDot,
                    "drawingModeAfterDisable": nativeFlagAfterDisable,
                    "renderBeforeDot": nativeRenderBeforeDot,
                    "renderAfterDot": nativeRenderAfterDot,
                    "controlInkApplyOutcome": controlInkAck,
                    "dotInkApplyOutcome": dotInkAck,
                    "inkApplyOutcomeAtManifest": session.inkApplyOutcome.map {
                        $0 == .verified ? "verified" : "dispatchedUnverified"
                    } ?? "nil",
                    "sessionError": session.error ?? "nil",
                    "inkError": session.inkError ?? "nil",
                    "hasUncommittedChangesAfterDot": session.hasUncommittedChanges
                ] as [String: Any],
                "controlStyle": ["color": "#FF0000", "widthEMU": controlStyleEMU, "alpha": 100_000],
                "dotStyle": ["color": "#0000FF", "widthEMU": dotStyleEMU, "alpha": dotAlphaExpected,
                             "preset": dotPreset.rawValue,
                             "transparencyPercent": dotStroke.transparencyPercent],
                "controlPersisted": controlPersisted,
                "dotRouteAccepted": dotRouteAccepted,
                "controlSavedShapes": controlShapeCount,
                "dotSavedShapes": dotShapeCount,
                "controlCheckpointVectorPaths": controlPackage?.customGeometryPaths.count ?? -1,
                "savedVectorPaths": saved.customGeometryPaths.count,
                "savedVectorPointCounts": saved.customGeometryPaths.indices.map { saved.customGeometryPointCounts[$0] },
                "savedVectorLineStyles": saved.vectorShapes.map {
                    ["color": $0.colorHex ?? "MISSING", "widthEMU": $0.widthEMU ?? -1,
                     "paths": $0.paths.count, "alpha": $0.alphaValue ?? -1] as [String: Any]
                },
                "dotShapes": dotShapes.map {
                    ["color": $0.colorHex ?? "MISSING", "widthEMU": $0.widthEMU ?? -1,
                     "paths": $0.paths.count, "alpha": $0.alphaValue ?? -1,
                     "prst": $0.prstGeometry ?? "none", "fillColor": $0.fillColorHex ?? "MISSING",
                     "fillAlpha": $0.fillAlphaValue ?? -1, "lineNoFill": $0.lineIsNoFill,
                     "extentEMU": $0.extentEMU ?? [],
                     "placement": $0.placement ?? "none", "anchor": $0.anchor ?? "none"] as [String: Any]
                },
                "dotFraction": dotFraction ?? [],
                "visualVisibilityCheck": "pending reopened control-only vs final same-fixture engine page pixel diff",
                "hardwarePointerInput": "not-tested",
                "pressure": "synthetic-known-finite-not-hardware",
                "visualReview": "pending-primary-image-review"
            ]
            let receiptURL = root.appendingPathComponent("zero-motion-verification.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: receiptURL, options: .atomic)
            attach(receiptURL, name: "zero-motion-verification-\(format)")
            await session.release()
        } catch {
            await session.release()
            throw error
        }

        // Reopen the control-only checkpoint and the final saved copy in the
        // same production App surface. The engine page snapshots are the
        // visibility gate: XML shape count alone is never enough.
        let savedHash = try hash(exported)
        let reopenControl = OfficeFileSession()
        let controlWindow = mount(reopenControl, in: scene)
        defer { controlWindow.isHidden = true; controlWindow.rootViewController = nil }
        let controlImage: UIImage
        let controlProbe: [String: Any]
        do {
            await reopenControl.open(checkpoint)
            try await wait(120, "control-only saved copy reopen") {
                reopenControl.canAct && reopenControl.documentActionsReady && reopenControl.controller != nil
            }
            let native = try XCTUnwrap(reopenControl.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            try await Task.sleep(for: .milliseconds(400))
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = true
            controlImage = try await web.takeSnapshot(configuration: configuration)
            let png = root.appendingPathComponent("control-reopened-\(format).png")
            try XCTUnwrap(controlImage.pngData()).write(to: png); attach(png, name: "dot-control-reopened-\(format)")
            controlProbe = try await zeroMotionRenderProbe(web)
            await reopenControl.release()
            controlWindow.isHidden = true
            controlWindow.rootViewController = nil
        } catch { await reopenControl.release(); throw error }

        let reopenFinal = OfficeFileSession()
        let finalWindow = mount(reopenFinal, in: scene)
        defer { finalWindow.isHidden = true; finalWindow.rootViewController = nil }
        do {
            await reopenFinal.open(exported)
            try await wait(120, "final saved copy reopen") {
                reopenFinal.canAct && reopenFinal.documentActionsReady && reopenFinal.controller != nil
            }
            let native = try XCTUnwrap(reopenFinal.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            try await Task.sleep(for: .milliseconds(400))
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = true
            let finalImage = try await web.takeSnapshot(configuration: configuration)
            let png = root.appendingPathComponent("reopened-native-\(format).png")
            try XCTUnwrap(finalImage.pngData()).write(to: png); attach(png, name: "dot-reopened-native-\(format)")
            let finalProbe = try await zeroMotionRenderProbe(web)
            let reopened = try package(exported, format: format)
            XCTAssertTrue(reopened.text.contains("BASELINE-DOT-KEEP"), "Reopened copy lost original content")
            let reopenedControlShapes = reopened.vectorShapes.filter { shape in
                shape.colorHex?.uppercased() == "FF0000"
                    && shape.widthEMU.map { abs($0 - controlStyleEMU) <= 635 } == true
                    && !shape.paths.isEmpty
            }
            let reopenedDotShapes = reopened.vectorShapes.filter { shape in
                let isControl = shape.colorHex?.uppercased() == "FF0000"
                    && shape.widthEMU.map { abs($0 - controlStyleEMU) <= 635 } == true
                return !isControl && (isNativeDotShape(shape) || !shape.paths.isEmpty)
            }
            XCTAssertFalse(reopenedControlShapes.isEmpty,
                           "The persisted positive control did not survive reopen")
            if dotShapeCount > 0 {
                XCTAssertEqual(reopenedDotShapes.count, dotShapeCount,
                               "The zero-motion dot shape did not survive reopen")
            }
            var visibility: [String: Any] = ["available": false]
            if dotShapeCount > 0, let dotFraction, dotFraction.count == 2 {
                guard let x1 = (finalProbe["x1"] as? NSNumber)?.doubleValue,
                      let y1 = (finalProbe["y1"] as? NSNumber)?.doubleValue,
                      let x2 = (finalProbe["x2"] as? NSNumber)?.doubleValue,
                      let y2 = (finalProbe["y2"] as? NSNumber)?.doubleValue,
                      let viewportWidth = (finalProbe["viewportWidth"] as? NSNumber)?.doubleValue,
                      let viewportHeight = (finalProbe["viewportHeight"] as? NSNumber)?.doubleValue,
                      x2 > x1, y2 > y1, viewportWidth > 1, viewportHeight > 1 else {
                    XCTFail("The reopened final page did not expose finite geometry for the visibility check")
                    throw NSError(domain: "OfficeNativeDrawingQualification", code: 68, userInfo: [
                        NSLocalizedDescriptionKey: "reopened final page geometry unavailable"
                    ])
                }
                let dotPoint = CGPoint(x: x1 + dotFraction[0] * (x2 - x1),
                                       y: y1 + dotFraction[1] * (y2 - y1))
                var registrationDiagnostics: [String: Any]?
                // A reopened page can restore the document at a different scroll
                // offset than the live session, so the viewport-fraction point is
                // kept for diagnostics only. The gate expectation is anchored in
                // document content: the original input point
                // plus the scale and shift of the shared positive-control stroke
                // measured between the pre-save and the reopened control-only
                // pages. Thresholds stay exactly as before; a residual bound is
                // added, so a displaced dot fails.
                let registered = registeredDotCenter(preSave: dotPreSaveImage,
                                                     originalClientPoint: dotOriginalClientPoint,
                                                     controlReopened: controlImage,
                                                     finalReopened: finalImage,
                                                     viewport: CGSize(width: viewportWidth,
                                                                      height: viewportHeight))
                visibility = dotRenderFacts(control: controlImage, final: finalImage,
                                            point: registered.point, viewport: CGSize(width: viewportWidth,
                                                                              height: viewportHeight))
                registrationDiagnostics = registered.diagnostics
                visibility["fractionDiagnosticPoint"] = [dotPoint.x, dotPoint.y]
                visibility["registeredDiagnostics"] = registered.diagnostics
                XCTAssertEqual(registered.diagnostics["available"] as? Bool, true,
                               "The document-content registration was unavailable: \(registered.diagnostics)")
                XCTAssertEqual(visibility["available"] as? Bool, true,
                               "The reopened-page pixel comparison was unavailable: \(visibility)")
                let blue = visibility["bluePixelsInCrop"] as? Int ?? 0
                let changed = visibility["changedPixelsInCrop"] as? Int ?? 0
                XCTAssertGreaterThanOrEqual(blue, 12,
                    "VISIBILITY DEFECT: the saved dot XML exists but its reopened engine page has only \(blue) blue pixel(s) "
                    + "in the expected dot region; a zero-area/invisible shape is not a persisted human dot. \(visibility)")
                XCTAssertGreaterThanOrEqual(changed, 12,
                    "VISIBILITY DEFECT: control-only vs control+dot reopened-page pixel diff has only \(changed) changed "
                    + "pixel(s) in the expected dot region; XML alone is not accepted. \(visibility)")
                if let registrationDiagnostics, let residual = registrationDiagnostics["residualImagePx"] as? Double {
                    XCTAssertLessThanOrEqual(residual, 4.0,
                        "POSITION DEFECT: the reopened dot centroid is \(residual) image pixels from the "
                        + "document-content registered expectation; a shifted dot is not the same dot. \(registrationDiagnostics)")
                }
            } else if dotShapeCount == 0 {
                visibility = ["available": false, "reason": "no saved dot shape to render; baseline contract already failed"]
            } else {
                XCTFail("The saved dot shape exists but its original point fraction was unavailable, so the reopened-page visibility gate could not run")
                visibility = ["available": false, "reason": "dot-fraction-unavailable"]
            }
            let hashAfter = try hash(exported)
            XCTAssertEqual(hashAfter, savedHash, "The saved copy changed while it was reopened")
            let receiptURL = root.appendingPathComponent("zero-motion-verification.json")
            var receipt = (try? JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL))) as? [String: Any] ?? [:]
            receipt["savedCopyReopened"] = true
            receipt["savedCopySHA256BeforeReopen"] = savedHash
            receipt["savedCopySHA256AfterReopen"] = hashAfter
            receipt["savedCopyUnchangedAfterReopen"] = hashAfter == savedHash
            receipt["reopenedVectorPaths"] = reopened.customGeometryPaths.count
            receipt["reopenedControlSavedShapes"] = reopenedControlShapes.count
            receipt["reopenedDotSavedShapes"] = reopenedDotShapes.count
            receipt["reopenNativeRenderDiagnostics"] = OfficeFileSession.hostRenderDiagnostics(native)
            receipt["reopenRenderProbe"] = ["control": controlProbe, "final": finalProbe]
            receipt["visualVisibilityCheck"] = visibility
            receipt["visualReview"] = "pending-primary-image-review"
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: receiptURL, options: .atomic)
            attach(receiptURL, name: "zero-motion-reopen-verification-\(format)")
            await reopenFinal.release()
        } catch { await reopenFinal.release(); throw error }
    }

    /// Accepted v1 native filled-circle classifier, shared by the frozen
    /// opaque/highlighter dot acceptance and the new lifecycle exercises.
    private static func nativeDotShape(_ shape: DrawingQualificationXML.VectorShape) -> Bool {
        shape.prstGeometry == "ellipse"
            && (shape.fillColorHex ?? "").uppercased() == "0000FF"
            && shape.lineIsNoFill
            && shape.paths.isEmpty
    }

    /// Strict selected-style alpha rule. The expectation is derived from the
    /// actually selected stroke/transparency: a missing alpha element is valid
    /// only for the fully opaque expectation (100000); every other
    /// expectation must match the saved alpha exactly, so an
    /// opaque-vs-transparent cross-mismatch always fails.
    private static func dotAlphaSatisfies(_ actual: Int?, expected: Int) -> Bool {
        if expected == 100_000 { return actual == nil || actual == 100_000 }
        return actual == expected
    }

    /// Select one qualification ink style through the real per-document
    /// preference API and the App apply action, proving the applied state.
    private func applyInkStyle(_ style: OfficeInkStroke, preferences: OfficeInkPreferences,
                               session: OfficeFileSession, stage: String) async throws {
        preferences.setPreset(style.preset)
        preferences.setColorHex(style.colorHex)
        preferences.setWidthMillimeters(style.widthMillimeters)
        preferences.setTransparencyPercent(style.transparencyPercent)
        await session.applyInkPreferences()
        XCTAssertNil(session.inkError, "\(stage): App ink preferences failed to apply")
        XCTAssertEqual(preferences.stroke.preset, style.preset, "\(stage): preset mismatch")
        XCTAssertEqual(preferences.stroke.colorHex, style.colorHex, "\(stage): colour mismatch")
        XCTAssertEqual(preferences.stroke.widthMillimeters, style.widthMillimeters, "\(stage): width mismatch")
        XCTAssertEqual(preferences.stroke.transparencyPercent, style.transparencyPercent, "\(stage): transparency mismatch")
    }

    /// The extended seam's paint handoff receipt (design HANDOFF §3.4, root
    /// review strengthened for sole attribution): the completed zero-motion
    /// contact must own its preview paint handoff ALONE. The seam
    /// state-observes the bridge's own pending set immediately before the new
    /// contact with a bounded poll; only a drained (0) pre-contact pending
    /// makes the per-contact attribution honest, because the bridge's
    /// `lastClearReason` records the LAST clear of the whole pending set and
    /// cannot prove ownership while several handoffs are pending. The bounded
    /// drain poll must then observe an ACTUAL clear (`clearsAfter >
    /// clearsBefore`) whose reason is the bridge's geometric
    /// `handoffEvidenceComplete` value `painted`. Every field is a real
    /// bridge diagnostic (`__floeOfficePenState`/`__floeOfficePenPreview`);
    /// no success flag is invented and no timestamp alone is accepted.
    private func validateDotPaintReceipt(_ zeroMotion: [String: Any], label: String) {
        guard let paint = zeroMotion["paint"] as? [String: Any] else {
            XCTFail("\(label): the extended zero-motion seam did not return its paint receipt")
            return
        }
        XCTAssertEqual(paint["available"] as? Bool, true,
                       "\(label): the live preview surface was unavailable, so the paint handoff receipt cannot be taken: \(paint)")
        XCTAssertEqual(paint["preContactPending"] as? Int, 0,
                       "\(label): another preview handoff was still pending before this contact (bounded poll waited \(paint["preContactWaitedMilliseconds"] ?? -1) ms), so per-contact own-paint attribution is impossible and was not faked: \(paint)")
        XCTAssertEqual(paint["pendingAtUp"] as? Int, 1,
                       "\(label): the completed dot contact must register exactly its own sole preview paint handoff: \(paint)")
        XCTAssertEqual(paint["pendingAfterUp"] as? Int, 0,
                       "\(label): preview paint handoffs were still pending at the probe-window boundary: \(paint)")
        let clearsBefore = paint["clearsBefore"] as? Int ?? -1
        let clearsAfter = paint["clearsAfter"] as? Int ?? -2
        XCTAssertGreaterThan(clearsAfter, clearsBefore,
                             "\(label): the bounded drain poll observed no actual preview clear for this contact; a stale lastClearReason was not accepted as success: \(paint)")
        XCTAssertEqual(paint["lastClearReason"] as? String, "painted",
                       "\(label): the engine tile paint did not clear the pending preview handoff with paint evidence: \(paint)")
    }

    /// One genuine zero-motion tap through the production seam with the full
    /// frozen contact contract plus its paint handoff receipt. The contact
    /// still dispatches exactly pointerdown+pointerup at one identical point;
    /// `candidateOffset` only rotates the seam's existing real layout
    /// candidates so repeat taps persist at distinct positions.
    private func receiveValidatedDotTap(web: WKWebView, native: FloeOfficeNativeViewController,
                                        window: UIWindow, root: URL, syntheticSource: URL,
                                        label: String, candidateOffset: Int) async throws
        -> (receipt: [String: Any], routeAccepted: Bool) {
        let zeroMotion = try await receiveZeroMotionDot(web: web, native: native, window: window,
                                                        root: root, syntheticSource: syntheticSource,
                                                        paintReceipt: true, candidateOffset: candidateOffset,
                                                        receiptName: "zero-motion-dot-\(label)")
        let routeReady = zeroMotion["routeReady"] as? Bool == true
        XCTAssertTrue(routeReady, "\(label): the exact zero-motion input route was not prepared: \(zeroMotion)")
        guard routeReady else { return (zeroMotion, false) }
        XCTAssertEqual(zeroMotion["eventsDispatched"] as? Int, 2,
                       "\(label): the zero-motion seam must dispatch exactly one down and one second event")
        XCTAssertEqual(zeroMotion["movesDispatched"] as? Int, 0,
                       "\(label): the zero-motion seam must not fabricate a move")
        XCTAssertEqual(zeroMotion["secondEventKind"] as? String, "pointerup",
                       "\(label): a completed dot tap must end with the real pointerup")
        if let rawPoints = zeroMotion["clientPoints"] as? [[Any]], rawPoints.count == 2,
           let x0 = (rawPoints[0][0] as? NSNumber)?.doubleValue,
           let y0 = (rawPoints[0][1] as? NSNumber)?.doubleValue,
           let x1 = (rawPoints[1][0] as? NSNumber)?.doubleValue,
           let y1 = (rawPoints[1][1] as? NSNumber)?.doubleValue {
            XCTAssertEqual(x0, x1, "\(label): the zero-motion down and up must use one identical X")
            XCTAssertEqual(y0, y1, "\(label): the zero-motion down and up must use one identical Y")
        } else {
            XCTFail("\(label): the zero-motion receipt did not expose its two identical client points")
        }
        XCTAssertEqual(zeroMotion["downAccepted"] as? Bool, true,
                       "\(label): the actual production pen bridge did not accept the zero-motion down")
        XCTAssertEqual(zeroMotion["activeAfterDown"] as? Bool, true,
                       "\(label): the production bridge must own the contact after the zero-motion down")
        XCTAssertEqual(zeroMotion["activeAfterUp"] as? Bool, false,
                       "\(label): the production bridge must finish the zero-motion contact")
        XCTAssertEqual(zeroMotion["strokeDelta"] as? Int, 1,
                       "\(label): the production bridge must count the completed zero-motion contact")
        XCTAssertEqual(zeroMotion["coreEventDelta"] as? Int, 2,
                       "\(label): the canonical replay for a zero-motion contact must be exactly mousedown+mouseup")
        let accepted = zeroMotion["downAccepted"] as? Bool == true
            && zeroMotion["activeAfterDown"] as? Bool == true
            && zeroMotion["activeAfterUp"] as? Bool == false
            && zeroMotion["strokeDelta"] as? Int == 1
            && zeroMotion["coreEventDelta"] as? Int == 2
        if accepted { validateDotPaintReceipt(zeroMotion, label: label) }
        return (zeroMotion, accepted)
    }

    /// Dispatch one real engine command through the pinned frontend's
    /// production `map.sendUnoCommand` (the same dispatcher route the accepted
    /// stale-handle test uses for `.uno:SelectObject`) and retain its bounded
    /// receipt before any decoding assertion. No interpreter-local undo and no
    /// fixture injection substitute for the engine action.
    @discardableResult
    private func dispatchDotCommand(_ command: String, web: WKWebView, root: URL,
                                    label: String) async throws -> [String: Any] {
        var resultType = "not-returned"
        do {
            let receipt: Any? = try await web.callAsyncJavaScript(Self.dotUndoCommandScript,
                arguments: ["command": command], in: nil, contentWorld: .page)
            resultType = receipt.map { String(reflecting: type(of: $0)) } ?? "nil"
            guard let json = receipt as? String else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 74, userInfo: [
                    NSLocalizedDescriptionKey: "Real UNO \(command) dispatch did not return its JSON-string receipt (type=\(resultType))"
                ])
            }
            guard json.utf8.count <= 16_384 else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 75, userInfo: [
                    NSLocalizedDescriptionKey: "Real UNO \(command) receipt exceeded its bounded transport"
                ])
            }
            let receiptURL = root.appendingPathComponent("\(label).json")
            try Data(json.utf8).write(to: receiptURL, options: .atomic)
            attach(receiptURL, name: label)
            guard let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 76, userInfo: [
                    NSLocalizedDescriptionKey: "Real UNO \(command) receipt was not a JSON object"
                ])
            }
            XCTAssertEqual(decoded["command"] as? String, command, "\(label): the real dispatcher echoed a different command")
            XCTAssertNil(decoded["dispatchError"], "\(label): the real UNO \(command) dispatch failed: \(decoded)")
            return decoded
        } catch {
            let nsError = error as NSError
            let facts: [String: Any] = ["stage": "dispatch-real-uno-\(command)", "command": command,
                                        "WKResultType": resultType, "errorDomain": nsError.domain,
                                        "errorCode": nsError.code]
            let url = root.appendingPathComponent("\(label)-transport-failure.json")
            if let bytes = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: url, options: .atomic)
                attach(url, name: "\(label)-transport-failure")
            }
            throw error
        }
    }

    private static let dotUndoCommandScript = #"""
    const app = window.app;
    const map = app && app.map;
    if (!map || typeof map.sendUnoCommand !== 'function')
        throw new Error('production UNO dispatcher unavailable');
    const undoContext = () => {
        const bounded = value => value == null || typeof value === 'boolean' || typeof value === 'number'
            ? value : typeof value === 'string' ? value.slice(0, 512) : String(value).slice(0, 128);
        const state = command => { try { return bounded(map.stateChangeHandler && map.stateChangeHandler.getItemValue(command)); } catch { return null; } };
        const layer = map._docLayer;
        return {undo: state('.uno:Undo'), redo: state('.uno:Redo'),
            isEditMode: typeof map.isEditMode === 'function' ? map.isEditMode() : null,
            docType: layer ? bounded(layer._docType) : null,
            selectedPart: layer ? bounded(layer._selectedPart) : null};
    };
    const undoContextBefore = undoContext();
    const before = typeof window.__floeOfficePenState === 'function' ? window.__floeOfficePenState() : null;
    let dispatchError = null;
    try { map.sendUnoCommand(command); }
    catch (error) { dispatchError = String(error && error.message || error).slice(0, 128); }
    await new Promise(resolve => setTimeout(resolve, 400));
    const selection = app.definitions && app.definitions.graphicSelection
        && typeof app.definitions.graphicSelection.hasActiveSelection === 'function'
        ? app.definitions.graphicSelection.hasActiveSelection() === true : null;
    const out = {command, selectionActiveAfter: selection, before, undoContextBefore, undoContextAfter: undoContext(),
        after: typeof window.__floeOfficePenState === 'function' ? window.__floeOfficePenState() : null};
    if (dispatchError) out.dispatchError = dispatchError;
    return JSON.stringify(out);
    """#

    /// Read the existing native DocumentRepair command-values response without
    /// opening its UI. Diagnostic only: neither commands nor assertions change.
    private func captureActualUndoStack(_ web: WKWebView, root: URL, label: String) async throws {
        let value = try await web.callAsyncJavaScript(Self.actualUndoStackScript,
            arguments: [:], in: nil, contentWorld: .page)
        guard let json = value as? String, json.utf8.count <= 32_768 else {
            throw NSError(domain: "OfficeUndoObservation", code: 1)
        }
        let url = root.appendingPathComponent(label + ".json")
        try Data(json.utf8).write(to: url); attach(url, name: label)
    }

    private static let actualUndoStackScript = #"""
    const map = window.app && window.app.map;
    const layer = map && map._docLayer;
    const socket = window.app && window.app.socket;
    if (!layer || typeof layer._onDocumentRepair !== 'function' || !socket
        || typeof socket.sendMessage !== 'function' || window.__floeActualStackProbeDisabled)
        return JSON.stringify({available:false, reason:'existing-read-path-unavailable'});
    const own = Object.prototype.hasOwnProperty.call(layer, '_onDocumentRepair');
    const original = layer._onDocumentRepair;
    let reply = null;
    const actions = part => {
        if (!part || !Array.isArray(part.actions)) return {available:false,
            nativeKind: part === null ? 'null' : Array.isArray(part) ? 'array' : typeof part,
            nativeKeys: part && typeof part === 'object' ? Object.keys(part).slice(0, 12) : [],
            nativeActionsKind: part && part.actions === null ? 'null' : typeof (part && part.actions)};
        return {available:true, count:part.actions.length,
            actions:part.actions.slice(0, 20).map(action => ({index:action.index, viewId:action.viewId,
                comment:String(action.comment || '').slice(0, 256)}))};
    };
    layer._onDocumentRepair = function(payload) {
        if (payload && payload.commandName === '.uno:DocumentRepair') {
            reply = payload; return;
        }
        return original.apply(this, arguments);
    };
    const start = performance.now();
    try {
        socket.sendMessage('commandvalues command=.uno:DocumentRepair');
        while (!reply && performance.now() - start < 2500)
            await new Promise(resolve => setTimeout(resolve, 20));
        if (!reply) {
            window.__floeActualStackProbeDisabled = true;
            return JSON.stringify({available:false, reason:'native-response-timeout', waitedMS:performance.now()-start});
        }
        const undo = actions(reply.Undo), redo = actions(reply.Redo);
        return JSON.stringify({available:undo.available || redo.available, nativeCommand:reply.commandName,
            viewId:layer._viewId, selectedPart:layer._selectedPart,
            Undo:undo, Redo:redo, waitedMS:performance.now()-start});
    } catch(error) {
        return JSON.stringify({available:false, reason:'native-read-error', error:String(error.message||error).slice(0, 256)});
    } finally {
        if (own) layer._onDocumentRepair = original; else delete layer._onDocumentRepair;
    }
    """#

    /// Moving-ink identity: placement + paths + line alpha, order-stable.
    private func penShapeIdentities(_ pkg: DrawingQualificationXML, widthEMU: Int) -> [String] {
        pkg.vectorShapes.filter { shape in
            shape.colorHex?.uppercased() == "FF0000"
                && shape.widthEMU.map { abs($0 - widthEMU) <= 635 } == true
                && !shape.paths.isEmpty
        }.sorted { $0.description < $1.description }
         .map { "\($0.placement ?? "nil")|\($0.paths.joined(separator: ";"))|\($0.alphaValue.map(String.init) ?? "none")" }
    }

    /// Dot identity: the shape's own saved placement (or anchor, then the
    /// full semantic description as the honest fallback).
    private func dotPlacements(_ pkg: DrawingQualificationXML) -> [String] {
        pkg.vectorShapes.filter { Self.nativeDotShape($0) }
            .sorted { $0.description < $1.description }
            .map { shape in
                if let anchor = shape.anchor, anchor.hasPrefix("word-anchor:") {
                    return anchor + "|" + (shape.placement ?? "local-frame-missing")
                }
                return shape.placement ?? shape.anchor ?? shape.description
            }
    }

    private func unclassifiedShapes(_ pkg: DrawingQualificationXML, penWidthEMU: Int) -> [DrawingQualificationXML.VectorShape] {
        pkg.vectorShapes.filter { shape in
            let isPen = shape.colorHex?.uppercased() == "FF0000"
                && shape.widthEMU.map { abs($0 - penWidthEMU) <= 635 } == true
                && !shape.paths.isEmpty
            return !isPen && !Self.nativeDotShape(shape)
        }
    }

    /// After-dot lifecycle acceptance (design HANDOFF §3.5) through the actual
    /// production pen bridge and the saved OOXML only: a moving stroke
    /// completes and persists after a zero-motion dot; each repeat tap
    /// persists exactly one new dot at its own position; the mixed
    /// tap+moving-ink document keeps exact counts, distinct geometry and
    /// per-style attributes with the paint handoff receipt on every tap; one
    /// real `.uno:Undo` removes only the newest dot while every prior stroke
    /// stays identical, and `.uno:Redo` restores it at its original position.
    /// Authoritative file inspection only; no preview-only or fixture-based
    /// substitution.
    private func exerciseDotLifecycle(_ format: String) async throws {
        guard ProcessInfo.processInfo.environment["FLOE_NATIVE_DRAWING_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in native zero-motion dot lifecycle; not executed")
        }
        executionTimeAllowance = 600
        continueAfterFailure = true
        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Qualification/OfficeDotLifecycle-\(format)-\(UUID().uuidString)",
                                                   isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("FLOE_DOT_LIFECYCLE_ARTIFACT_ROOT=\(root.path)")
        let source = root.appendingPathComponent("original.\(format)")
        switch format {
        case "docx":
            try OfficeDocumentBuilder.createWord(at: source, title: "中文圆点生命周期验收",
                paragraphs: ["LIFECYCLE-DOT-KEEP 中文正文 12345", "Second paragraph remains editable."])
        case "xlsx":
            try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [
                OfficeWorkbookSheet(name: "圆点周期", rows: [["LIFECYCLE-DOT-KEEP", "数值"], ["原值", "12"], ["公式", "=B2*2"]])
            ])
        default:
            try OfficeDocumentBuilder.createPresentation(at: source, title: "中文圆点生命周期验收", slides: [
                OfficePresentationSlide(title: "LIFECYCLE-DOT-KEEP", bullets: ["中文原文 12345", "Editable original content"],
                                        notes: "LIFECYCLE-NOTES-KEEP")
            ])
        }
        let sourceHash = try hash(source)
        let baseline = try package(source, format: format)
        XCTAssertEqual(baseline.customGeometryPaths.count, 0, "Fixture must contain no preinserted strokes")
        attach(source, name: "lifecycle-source-\(format)")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let session = OfficeFileSession()
        let window = mount(session, in: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        let penStyle = OfficeInkStroke(colorHex: "#FF0000", widthMillimeters: 0.5,
                                       transparencyPercent: 0, preset: .pen)
        let markerStyle = OfficeInkStroke(colorHex: "#0000FF", widthMillimeters: 2.0,
                                          transparencyPercent: 0, preset: .marker)
        var tapReceipts: [[String: Any]] = []
        var strokeReceipts: [[String: Any]] = []
        var undoReceipt: [String: Any] = [:]
        var redoReceipt: [String: Any] = [:]
        do {
            await session.open(source)
            try await wait(120, "lifecycle native open") {
                session.canAct && session.documentActionsReady && session.controller != nil
            }
            if session.readOnly {
                let accepted = await session.requestEditing()
                XCTAssertTrue(accepted, "Actual App edit entry rejected: \(session.error ?? "unknown")")
            }
            try await wait(150, "lifecycle editable native document") {
                !session.readOnly && session.canAct && session.documentActionsReady && session.controller != nil
            }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            session.useInkPreferences(workspaceIdentity: root.path, documentKey: source.lastPathComponent)
            let preferences = session.inkPreferences
            let previousStroke = preferences.stroke
            defer {
                preferences.setPreset(previousStroke.preset)
                preferences.setColorHex(previousStroke.colorHex)
                preferences.setWidthMillimeters(previousStroke.widthMillimeters)
                preferences.setTransparencyPercent(previousStroke.transparencyPercent)
            }
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode, "the real App drawing toggle must arm")
            try await applyInkStyle(penStyle, preferences: preferences, session: session, stage: "lifecycle pen")
            let appliedPen = preferences.stroke
            let appliedPenEMU = appliedPen.lineWidthValue * 360
            let controlStimulus = StrokeStimulus(index: 0, kind: .band, gapMilliseconds: 30, style: .pen)
            let controlReceipt = try await receiveStroke(0, web: web, native: native, window: window,
                root: root, syntheticSource: source, stimulus: controlStimulus, previousPoints: [])
            try validateHitDiagnostics(controlReceipt, stimulus: controlStimulus)
            XCTAssertEqual(controlReceipt["strokeDelta"] as? Int, 1,
                           "The first moving stroke must complete through the actual pen bridge")
            strokeReceipts.append(controlReceipt)
            // The first dot, in the selected marker style.
            try await applyInkStyle(markerStyle, preferences: preferences, session: session, stage: "lifecycle marker")
            let appliedDot = preferences.stroke
            let appliedDotEMU = appliedDot.lineWidthValue * 360
            let tap1 = try await receiveValidatedDotTap(web: web, native: native, window: window,
                                                        root: root, syntheticSource: source,
                                                        label: "tap1", candidateOffset: 0)
            tapReceipts.append(tap1.receipt)
            // Requirement: after a genuine zero-motion contact the next moving
            // stroke works. The pen style is re-selected through the real
            // preference API without disarming drawing mode.
            try await applyInkStyle(penStyle, preferences: preferences, session: session, stage: "lifecycle pen after dot")
            let nextStimulus = StrokeStimulus(index: 1, kind: .band, gapMilliseconds: 30, style: .pen)
            let nextStroke = try await receiveStroke(1, web: web, native: native, window: window,
                root: root, syntheticSource: source, stimulus: nextStimulus, previousPoints: [])
            try validateHitDiagnostics(nextStroke, stimulus: nextStimulus)
            XCTAssertEqual(nextStroke["strokeDelta"] as? Int, 1,
                           "A moving stroke after a zero-motion dot must complete through the actual pen bridge")
            strokeReceipts.append(nextStroke)
            // Repeat taps: two further genuine zero-motion contacts. Each tap
            // must itself complete through the bridge and paint-clear.
            try await applyInkStyle(markerStyle, preferences: preferences, session: session, stage: "lifecycle marker repeat")
            let tap2 = try await receiveValidatedDotTap(web: web, native: native, window: window,
                                                       root: root, syntheticSource: source,
                                                       label: "tap2", candidateOffset: 1)
            let tap3 = try await receiveValidatedDotTap(web: web, native: native, window: window,
                                                       root: root, syntheticSource: source,
                                                       label: "tap3", candidateOffset: 2)
            tapReceipts.append(contentsOf: [tap2.receipt, tap3.receipt])
            if format == "pptx" { try await captureActualUndoStack(web, root: root, label: "actual-stack-after-taps-before-mode-off") }
            try await session.toggleDrawing()
            XCTAssertFalse(session.drawingMode, "the drawing toggle must disarm before the saves")
            if format == "pptx" { try await captureActualUndoStack(web, root: root, label: "actual-stack-after-mode-off-before-save") }
            let allCopy = root.appendingPathComponent("lifecycle-all.\(format)")
            try fm.copyItem(at: try await session.exportDocument(format: format), to: allCopy)
            attach(allCopy, name: "dot-lifecycle-saved-all-\(format)")
            if format == "pptx" { try await captureActualUndoStack(web, root: root, label: "actual-stack-after-all-save-before-undo") }
            XCTAssertEqual(try hash(source), sourceHash, "Lifecycle export altered the original fixture")
            let savedAll = try package(allCopy, format: format)
            XCTAssertTrue(savedAll.text.contains("LIFECYCLE-DOT-KEEP"), "Lifecycle save lost original content")
            if format == "xlsx" {
                XCTAssertEqual(savedAll.cells["B2"], "12", "Excel basic value lost")
                XCTAssertEqual(savedAll.formulas["B3"], "B2*2", "Excel formula lost or flattened")
                XCTAssertGreaterThanOrEqual(savedAll.validAnchors, 1, "Lifecycle shapes need a valid Excel sheet anchor")
            }
            if format == "pptx" { XCTAssertTrue(savedAll.text.contains("LIFECYCLE-NOTES-KEEP"), "Speaker notes lost") }
            // Mixed tap + moving-ink document: exact counts, geometry and style.
            XCTAssertEqual(penShapeIdentities(savedAll, widthEMU: appliedPenEMU).count, 2,
                           "The mixed document must keep exactly two selected-style pen paths: \(savedAll.vectorShapes)")
            XCTAssertEqual(Set(savedAll.customGeometryPaths).count, 2, "The two moving strokes must have distinct geometry")
            XCTAssertEqual(savedAll.customGeometryPaths.count, 2,
                           "The three dots must not add custom geometry paths: \(savedAll.customGeometryPaths.count)")
            XCTAssertTrue(savedAll.customGeometryPointCounts.allSatisfy { $0 >= 3 }, "Moving strokes need real vector points")
            let allDotIds = dotPlacements(savedAll)
            XCTAssertEqual(allDotIds.count, 3, "Each repeat tap must persist exactly one new dot: \(savedAll.vectorShapes)")
            XCTAssertEqual(Set(allDotIds).count, 3, "Each tapped dot must persist at its own distinct position: \(allDotIds)")
            XCTAssertEqual(unclassifiedShapes(savedAll, penWidthEMU: appliedPenEMU).count, 0,
                           "No other persisted vector shape is allowed: \(savedAll.vectorShapes)")
            for dot in savedAll.vectorShapes.filter({ Self.nativeDotShape($0) }) {
                XCTAssertTrue(dot.widthEMU == nil || dot.widthEMU == 0,
                              "A tapped dot must not save an outline width: \(dot)")
                XCTAssertTrue(dot.extentEMU?.count == 2
                              && (dot.extentEMU?[0] ?? -1) == (dot.extentEMU?[1] ?? -2)
                              && abs((dot.extentEMU?[0] ?? -1) - appliedDotEMU) <= 635,
                              "Every tapped dot must keep the selected marker width as its square extent: \(dot)")
                XCTAssertTrue(Self.dotAlphaSatisfies(dot.fillAlphaValue, expected: 100_000),
                              "Tapped opaque marker dots must keep the opaque fill alpha: \(dot)")
                XCTAssertFalse(Self.dotAlphaSatisfies(dot.fillAlphaValue, expected: 40_000),
                               "cross-negative: an opaque tapped dot must not satisfy the highlighter alpha: \(dot)")
            }
            let allPenIdentities = penShapeIdentities(savedAll, widthEMU: appliedPenEMU)
            // One real engine undo action must remove only the newest dot.
            undoReceipt = try await dispatchDotCommand(".uno:Undo", web: web, root: root, label: "dot-undo-receipt")
            if format == "pptx" { try await captureActualUndoStack(web, root: root, label: "actual-stack-after-undo-before-save") }
            let undoCopy = root.appendingPathComponent("lifecycle-undo.\(format)")
            try fm.copyItem(at: try await session.exportDocument(format: format), to: undoCopy)
            attach(undoCopy, name: "dot-lifecycle-saved-undo-\(format)")
            if format == "pptx" { try await captureActualUndoStack(web, root: root, label: "actual-stack-after-undo-save") }
            let savedUndo = try package(undoCopy, format: format)
            XCTAssertTrue(savedUndo.text.contains("LIFECYCLE-DOT-KEEP"), "Undo save lost original content")
            XCTAssertEqual(penShapeIdentities(savedUndo, widthEMU: appliedPenEMU), allPenIdentities,
                           "One undo action must leave every prior moving stroke unchanged")
            let undoDotIds = dotPlacements(savedUndo)
            XCTAssertEqual(undoDotIds.count, 2, "One undo action must remove exactly the newest dot: \(savedUndo.vectorShapes)")
            XCTAssertEqual(unclassifiedShapes(savedUndo, penWidthEMU: appliedPenEMU).count, 0,
                           "Undo must not persist any other shape: \(savedUndo.vectorShapes)")
            XCTAssertEqual(Set(allDotIds).subtracting(undoDotIds).count, 1,
                           "Undo must remove exactly one previously saved dot position: all=\(allDotIds) undo=\(undoDotIds)")
            XCTAssertTrue(Set(undoDotIds).isSubset(of: Set(allDotIds)),
                          "Undo must not move or restyle any surviving dot: \(undoDotIds)")
            // Redo restores the removed dot with the prior document unchanged.
            redoReceipt = try await dispatchDotCommand(".uno:Redo", web: web, root: root, label: "dot-redo-receipt")
            if format == "pptx" { try await captureActualUndoStack(web, root: root, label: "actual-stack-after-redo-before-save") }
            let redoCopy = root.appendingPathComponent("lifecycle-redo.\(format)")
            try fm.copyItem(at: try await session.exportDocument(format: format), to: redoCopy)
            attach(redoCopy, name: "dot-lifecycle-saved-redo-\(format)")
            let savedRedo = try package(redoCopy, format: format)
            XCTAssertEqual(penShapeIdentities(savedRedo, widthEMU: appliedPenEMU), allPenIdentities,
                           "Redo must keep the prior moving strokes unchanged")
            XCTAssertEqual(dotPlacements(savedRedo), allDotIds,
                           "Redo must restore the undone dot at its original position with no other change")
            XCTAssertEqual(savedRedo.vectorShapes.map(\.description).sorted(),
                           savedAll.vectorShapes.map(\.description).sorted(),
                           "After redo the saved shape set must equal the pre-undo shape set")
            XCTAssertEqual(try hash(source), sourceHash, "Undo/redo exports altered the original fixture")
            let manifest: [String: Any] = [
                "case": "dot-lifecycle", "format": format, "sourceSHA256": sourceHash,
                "savedAllSHA256": try hash(allCopy), "savedUndoSHA256": try hash(undoCopy),
                "savedRedoSHA256": try hash(redoCopy),
                "humanContract": "After a zero-motion dot the next moving stroke persists; each repeat tap adds exactly one dot; one undo removes only the newest dot leaving prior strokes unchanged; redo restores it.",
                "route": "OfficeFileSession.toggleDrawing/applyInkPreferences/production pen bridge dot seam (pointerdown+pointerup at one point)/stroke seam/map.sendUnoCommand(.uno:Undo|.uno:Redo)/exportDocument/OOXML file inspection",
                "penStyle": ["color": "#FF0000", "widthEMU": appliedPenEMU,
                             "alpha": (100 - appliedPen.transparencyPercent) * 1_000],
                "dotStyle": ["color": "#0000FF", "widthEMU": appliedDotEMU, "preset": appliedDot.preset.rawValue,
                             "alpha": (100 - appliedDot.transparencyPercent) * 1_000],
                "strokeReceipts": strokeReceipts, "tapReceipts": tapReceipts,
                "undoReceipt": undoReceipt, "redoReceipt": redoReceipt,
                "dotPlacementsAll": allDotIds, "dotPlacementsAfterUndo": undoDotIds,
                "savedAllShapes": savedAll.vectorShapes.map { ["color": $0.colorHex ?? "MISSING", "widthEMU": $0.widthEMU ?? -1, "paths": $0.paths.count, "alpha": $0.alphaValue ?? -1, "prst": $0.prstGeometry ?? "none", "fillColor": $0.fillColorHex ?? "MISSING", "fillAlpha": $0.fillAlphaValue ?? -1, "lineNoFill": $0.lineIsNoFill, "extentEMU": $0.extentEMU ?? [], "placement": $0.placement ?? "none"] as [String: Any] },
                "savedUndoShapes": savedUndo.vectorShapes.map { ["color": $0.colorHex ?? "MISSING", "widthEMU": $0.widthEMU ?? -1, "paths": $0.paths.count, "alpha": $0.alphaValue ?? -1, "prst": $0.prstGeometry ?? "none", "fillColor": $0.fillColorHex ?? "MISSING", "fillAlpha": $0.fillAlphaValue ?? -1, "lineNoFill": $0.lineIsNoFill, "extentEMU": $0.extentEMU ?? [], "placement": $0.placement ?? "none"] as [String: Any] },
                "savedRedoShapes": savedRedo.vectorShapes.map { ["color": $0.colorHex ?? "MISSING", "widthEMU": $0.widthEMU ?? -1, "paths": $0.paths.count, "alpha": $0.alphaValue ?? -1, "prst": $0.prstGeometry ?? "none", "fillColor": $0.fillColorHex ?? "MISSING", "fillAlpha": $0.fillAlphaValue ?? -1, "lineNoFill": $0.lineIsNoFill, "extentEMU": $0.extentEMU ?? [], "placement": $0.placement ?? "none"] as [String: Any] },
                "hardwarePointerInput": "not-tested",
                "visualReview": "pending-primary-image-review"
            ]
            let receiptURL = root.appendingPathComponent("dot-lifecycle-verification.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: receiptURL, options: .atomic)
            attach(receiptURL, name: "dot-lifecycle-verification-\(format)")
            await session.release()
        } catch {
            await session.release()
            throw error
        }
    }

    /// True-cancel acceptance. The integrated carrier owns a genuine
    /// window-level pointercancel listener (FloeOfficeNative.mm ce3543f,
    /// HEAD 08303a31): the cancel drops the contact's own preview with the
    /// `pointercancel` reason, posts the ordered Escape before ending the
    /// frontend contact and preserves every completed stroke — a
    /// between-down-and-up cancel must persist NOTHING. (The older pinned
    /// carrier routed window pointercancel to the normal up handler and
    /// finalized a dot; that closure is now integrated, so the no-dot gate
    /// below is expected to PASS and remains a permanent cancel-route
    /// regression gate.) This test dispatches only a real
    /// pointerdown+pointercancel at one identical point through the
    /// production listener (never a normal pointerup, no handler bypass, no
    /// epsilon), records the bridge's own counters and clear reasons, then
    /// requires that the saved document persists no dot of any representation
    /// while the next true moving stroke completes and persists through the
    /// same bridge. Never skipped, never weakened.
    private func exerciseDotCancel(_ format: String) async throws {
        guard ProcessInfo.processInfo.environment["FLOE_NATIVE_DRAWING_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in native true-pointer-cancel dot contract; not executed")
        }
        executionTimeAllowance = 600
        continueAfterFailure = true
        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Qualification/OfficeDotCancel-\(format)-\(UUID().uuidString)",
                                                   isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("FLOE_DOT_CANCEL_ARTIFACT_ROOT=\(root.path)")
        let source = root.appendingPathComponent("original.\(format)")
        switch format {
        case "docx":
            try OfficeDocumentBuilder.createWord(at: source, title: "中文取消触点验收",
                paragraphs: ["CANCEL-DOT-KEEP 中文正文 12345", "Second paragraph remains editable."])
        case "xlsx":
            try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [
                OfficeWorkbookSheet(name: "取消", rows: [["CANCEL-DOT-KEEP", "数值"], ["原值", "12"], ["公式", "=B2*2"]])
            ])
        default:
            try OfficeDocumentBuilder.createPresentation(at: source, title: "中文取消触点验收", slides: [
                OfficePresentationSlide(title: "CANCEL-DOT-KEEP", bullets: ["中文原文 12345", "Editable original content"],
                                        notes: "CANCEL-NOTES-KEEP")
            ])
        }
        let sourceHash = try hash(source)
        let baseline = try package(source, format: format)
        XCTAssertEqual(baseline.customGeometryPaths.count, 0, "Fixture must contain no preinserted strokes")
        attach(source, name: "cancel-source-\(format)")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let session = OfficeFileSession()
        let window = mount(session, in: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        let penStyle = OfficeInkStroke(colorHex: "#FF0000", widthMillimeters: 0.5,
                                       transparencyPercent: 0, preset: .pen)
        let markerStyle = OfficeInkStroke(colorHex: "#0000FF", widthMillimeters: 2.0,
                                          transparencyPercent: 0, preset: .marker)
        do {
            await session.open(source)
            try await wait(120, "cancel native open") {
                session.canAct && session.documentActionsReady && session.controller != nil
            }
            if session.readOnly {
                let accepted = await session.requestEditing()
                XCTAssertTrue(accepted, "Actual App edit entry rejected: \(session.error ?? "unknown")")
            }
            try await wait(150, "cancel editable native document") {
                !session.readOnly && session.canAct && session.documentActionsReady && session.controller != nil
            }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            session.useInkPreferences(workspaceIdentity: root.path, documentKey: source.lastPathComponent)
            let preferences = session.inkPreferences
            let previousStroke = preferences.stroke
            defer {
                preferences.setPreset(previousStroke.preset)
                preferences.setColorHex(previousStroke.colorHex)
                preferences.setWidthMillimeters(previousStroke.widthMillimeters)
                preferences.setTransparencyPercent(previousStroke.transparencyPercent)
            }
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode, "the real App drawing toggle must arm")
            try await applyInkStyle(penStyle, preferences: preferences, session: session, stage: "cancel pen")
            let appliedPen = preferences.stroke
            let appliedPenEMU = appliedPen.lineWidthValue * 360
            let controlStimulus = StrokeStimulus(index: 0, kind: .band, gapMilliseconds: 30, style: .pen)
            let controlReceipt = try await receiveStroke(0, web: web, native: native, window: window,
                root: root, syntheticSource: source, stimulus: controlStimulus, previousPoints: [])
            try validateHitDiagnostics(controlReceipt, stimulus: controlStimulus)
            XCTAssertEqual(controlReceipt["strokeDelta"] as? Int, 1,
                           "The cancel-case positive control did not complete through the actual pen bridge")
            // The canceled contact: the same real seam, but the second event
            // is an actual pointercancel at the identical point.
            try await applyInkStyle(markerStyle, preferences: preferences, session: session, stage: "cancel marker")
            let appliedDot = preferences.stroke
            let preCancelFacts = try await officePenFacts(web)
            XCTAssertEqual(preCancelFacts["drawing"] as? Bool, true)
            XCTAssertEqual(preCancelFacts["activeStroke"] as? Bool, false,
                           "a previous stroke must not remain active before the canceled contact")
            let cancel = try await receiveZeroMotionDot(web: web, native: native, window: window,
                                                        root: root, syntheticSource: source,
                                                        cancelWithPointerCancel: true,
                                                        receiptName: "zero-motion-dot-cancel")
            let routeReady = cancel["routeReady"] as? Bool == true
            XCTAssertTrue(routeReady, "The real cancel route was not prepared; this is not classified as a cancel-persistence defect: \(cancel)")
            XCTAssertEqual(cancel["eventsDispatched"] as? Int, 2,
                           "The cancel seam must dispatch exactly one down and the real pointercancel")
            XCTAssertEqual(cancel["movesDispatched"] as? Int, 0,
                           "The cancel seam must not fabricate a move")
            XCTAssertEqual(cancel["secondEventKind"] as? String, "pointercancel",
                           "The cancel seam must dispatch the real pointercancel, never a normal pointerup")
            if let rawPoints = cancel["clientPoints"] as? [[Any]], rawPoints.count == 2,
               let x0 = (rawPoints[0][0] as? NSNumber)?.doubleValue,
               let y0 = (rawPoints[0][1] as? NSNumber)?.doubleValue,
               let x1 = (rawPoints[1][0] as? NSNumber)?.doubleValue,
               let y1 = (rawPoints[1][1] as? NSNumber)?.doubleValue {
                XCTAssertEqual(x0, x1, "The cancel down and pointercancel must use one identical X")
                XCTAssertEqual(y0, y1, "The cancel down and pointercancel must use one identical Y")
            } else {
                XCTFail("The cancel receipt did not expose its two identical client points")
            }
            XCTAssertEqual(cancel["downAccepted"] as? Bool, true,
                           "The actual production pen bridge did not accept the zero-motion down")
            XCTAssertEqual(cancel["activeAfterDown"] as? Bool, true,
                           "The production bridge must own the contact after the zero-motion down")
            XCTAssertEqual(cancel["activeAfterUp"] as? Bool, false,
                           "A canceled contact must not strand the production bridge in an active stroke")
            if let preContactPending = cancel["preContactPending"] as? Int {
                XCTAssertEqual(preContactPending, 0,
                               "Another preview handoff was still pending before the canceled contact (waited \(cancel["preContactWaitedMilliseconds"] ?? -1) ms); the cancel evidence was not attributed across contacts")
            }
            if let cancelPreview = cancel["cancelPreview"] as? [String: Any] {
                let clearsBefore = cancelPreview["clearsBeforeContact"] as? Int ?? -1
                let clearsAfter = cancelPreview["clearsAfterContact"] as? Int ?? -2
                if clearsAfter > clearsBefore {
                    XCTAssertEqual(cancelPreview["lastClearReason"] as? String, "pointercancel",
                                   "The canceled contact's own preview drop must carry the bridge's pointercancel reason, never a paint success: \(cancelPreview)")
                }
            }
            try await Task.sleep(for: .milliseconds(350))
            let postCancelFacts = try await officePenFacts(web)
            XCTAssertEqual(postCancelFacts["activeStroke"] as? Bool, false,
                           "The canceled contact must not leave an active stroke")
            XCTAssertEqual(postCancelFacts["drawing"] as? Bool, true,
                           "The canceled contact must leave the pen gate armed for the next contact")
            // Requirement: the next true stroke still works through the bridge.
            try await applyInkStyle(penStyle, preferences: preferences, session: session, stage: "cancel pen after")
            let nextStimulus = StrokeStimulus(index: 1, kind: .band, gapMilliseconds: 30, style: .pen)
            let nextStroke = try await receiveStroke(1, web: web, native: native, window: window,
                root: root, syntheticSource: source, stimulus: nextStimulus, previousPoints: [])
            try validateHitDiagnostics(nextStroke, stimulus: nextStimulus)
            XCTAssertEqual(nextStroke["strokeDelta"] as? Int, 1,
                           "A moving stroke after a canceled contact must complete through the actual pen bridge")
            try await session.toggleDrawing()
            XCTAssertFalse(session.drawingMode)
            let savedCopy = root.appendingPathComponent("cancel-saved.\(format)")
            try fm.copyItem(at: try await session.exportDocument(format: format), to: savedCopy)
            attach(savedCopy, name: "dot-cancel-saved-\(format)")
            XCTAssertEqual(try hash(source), sourceHash, "Cancel export altered the original fixture")
            let saved = try package(savedCopy, format: format)
            XCTAssertTrue(saved.text.contains("CANCEL-DOT-KEEP"), "Cancel save lost original content")
            if format == "xlsx" {
                XCTAssertEqual(saved.cells["B2"], "12", "Excel basic value lost")
                XCTAssertEqual(saved.formulas["B3"], "B2*2", "Excel formula lost or flattened")
            }
            if format == "pptx" { XCTAssertTrue(saved.text.contains("CANCEL-NOTES-KEEP"), "Speaker notes lost") }
            // Authoritative file inspection: exactly the two true strokes and
            // no dot of any representation from the canceled contact.
            let cancelDots = saved.vectorShapes.filter { shape in
                Self.nativeDotShape(shape)
                    || (shape.colorHex?.uppercased() == "0000FF" && !shape.paths.isEmpty)
                    || ((shape.fillColorHex ?? "").uppercased() == "0000FF" && shape.prstGeometry != nil)
            }
            XCTAssertEqual(penShapeIdentities(saved, widthEMU: appliedPenEMU).count, 2,
                           "The two true strokes must persist with their selected style: \(saved.vectorShapes)")
            XCTAssertEqual(Set(saved.customGeometryPaths).count, 2, "Exactly the two moving strokes may own custom geometry")
            XCTAssertEqual(saved.customGeometryPaths.count, 2, "The canceled contact must not add any vector path")
            let downAccepted = cancel["downAccepted"] as? Bool == true
            if downAccepted {
                XCTAssertEqual(cancelDots.count, 0,
                    "CANCEL DEFECT (EXPECTED on the pinned pointercancel->up route, not a weakened test): the real "
                    + "pointercancel between down and up finalized as \(cancelDots.count) persisted dot(s) in the saved "
                    + "\(format); the human contract requires a canceled zero-motion contact to persist nothing. "
                    + "bridge counters: strokeDelta=\(String(describing: cancel["strokeDelta"])) "
                    + "coreEventDelta=\(String(describing: cancel["coreEventDelta"])). shapes=\(saved.vectorShapes)")
            } else {
                XCTAssertEqual(cancelDots.count, 0,
                               "The canceled contact never reached the engine, so no dot may persist either: \(saved.vectorShapes)")
            }
            let manifest: [String: Any] = [
                "case": "dot-cancel", "format": format, "sourceSHA256": sourceHash,
                "savedSHA256": try hash(savedCopy),
                "humanContract": "A genuine between-down-and-up cancel (real pointercancel on the production listener) must persist no dot; the next true stroke must still complete through the same bridge.",
                "expectedCurrent": "Integrated carrier (FloeOfficeNative.mm ce3543f, HEAD 08303a31) owns the ordered pointercancel closure, so the no-dot gate is expected to pass; any dot persisted through the cancel route is a real regression and fails this gate.",
                "route": "OfficeFileSession.toggleDrawing/applyInkPreferences/stroke seam/marker select/pointerdown+pointercancel at one point on the production listener/exportDocument/OOXML file inspection",
                "controlReceipt": controlReceipt, "cancelReceipt": cancel,
                "nextStrokeReceipt": nextStroke,
                "preCancelPenFacts": preCancelFacts, "postCancelPenFacts": postCancelFacts,
                "penStyle": ["color": "#FF0000", "widthEMU": appliedPenEMU],
                "dotStyle": ["color": "#0000FF", "widthEMU": appliedDot.lineWidthValue * 360, "preset": appliedDot.preset.rawValue],
                "savedShapes": saved.vectorShapes.map { ["color": $0.colorHex ?? "MISSING", "widthEMU": $0.widthEMU ?? -1, "paths": $0.paths.count, "alpha": $0.alphaValue ?? -1, "prst": $0.prstGeometry ?? "none", "fillColor": $0.fillColorHex ?? "MISSING", "fillAlpha": $0.fillAlphaValue ?? -1, "lineNoFill": $0.lineIsNoFill, "extentEMU": $0.extentEMU ?? [], "placement": $0.placement ?? "none"] as [String: Any] },
                "cancelDotShapes": cancelDots.map { ["color": $0.colorHex ?? "MISSING", "widthEMU": $0.widthEMU ?? -1, "paths": $0.paths.count, "prst": $0.prstGeometry ?? "none", "fillColor": $0.fillColorHex ?? "MISSING", "extentEMU": $0.extentEMU ?? []] as [String: Any] },
                "hardwarePointerInput": "not-tested",
                "visualReview": "pending-primary-image-review"
            ]
            let receiptURL = root.appendingPathComponent("dot-cancel-verification.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: receiptURL, options: .atomic)
            attach(receiptURL, name: "dot-cancel-verification-\(format)")
            await session.release()
        } catch {
            await session.release()
            throw error
        }
    }

    /// Moving true-cancel acceptance (root review). The pinned bridge owns a
    /// genuine window-level pointercancel listener (FloeOfficeNative.mm
    /// ce3543f, HEAD 08303a31): a moving pointerdown + several real
    /// pointermove + pointercancel sequence must abandon ONLY the unfinished
    /// contact — the bridge drops its live preview with the `pointercancel`
    /// reason, posts the ordered Escape before ending the frontend contact
    /// and preserves every completed stroke — so the saved document persists
    /// no partial path and no dot of any representation for the canceled
    /// contact, the previously completed stroke stays identical, and the
    /// next genuine moving stroke completes through the same bridge. All
    /// events are real dispatched PointerEvents on the production dispatch
    /// target (the genuine listener path); this test never calls a private
    /// cancel handler, never fabricates an up and uses no epsilon. A
    /// persisted partial ink here is a genuine cancel-route regression;
    /// the gate is never skipped or weakened.
    private func exerciseDotMovingCancel(_ format: String) async throws {
        guard ProcessInfo.processInfo.environment["FLOE_NATIVE_DRAWING_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in native moving true-pointer-cancel contract; not executed")
        }
        executionTimeAllowance = 600
        continueAfterFailure = true
        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Qualification/OfficeDotMovingCancel-\(format)-\(UUID().uuidString)",
                                                   isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("FLOE_DOT_MOVING_CANCEL_ARTIFACT_ROOT=\(root.path)")
        let source = root.appendingPathComponent("original.\(format)")
        switch format {
        case "docx":
            try OfficeDocumentBuilder.createWord(at: source, title: "中文移动取消触点验收",
                paragraphs: ["CANCEL-MOVE-KEEP 中文正文 12345", "Second paragraph remains editable."])
        case "xlsx":
            try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [
                OfficeWorkbookSheet(name: "移动取消", rows: [["CANCEL-MOVE-KEEP", "数值"], ["原值", "12"], ["公式", "=B2*2"]])
            ])
        default:
            try OfficeDocumentBuilder.createPresentation(at: source, title: "中文移动取消触点验收", slides: [
                OfficePresentationSlide(title: "CANCEL-MOVE-KEEP", bullets: ["中文原文 12345", "Editable original content"],
                                        notes: "CANCEL-MOVE-NOTES-KEEP")
            ])
        }
        let sourceHash = try hash(source)
        let baseline = try package(source, format: format)
        XCTAssertEqual(baseline.customGeometryPaths.count, 0, "Fixture must contain no preinserted strokes")
        attach(source, name: "moving-cancel-source-\(format)")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let session = OfficeFileSession()
        let window = mount(session, in: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        let penStyle = OfficeInkStroke(colorHex: "#FF0000", widthMillimeters: 0.5,
                                       transparencyPercent: 0, preset: .pen)
        let markerStyle = OfficeInkStroke(colorHex: "#0000FF", widthMillimeters: 2.0,
                                          transparencyPercent: 0, preset: .marker)
        do {
            await session.open(source)
            try await wait(120, "moving-cancel native open") {
                session.canAct && session.documentActionsReady && session.controller != nil
            }
            if session.readOnly {
                let accepted = await session.requestEditing()
                XCTAssertTrue(accepted, "Actual App edit entry rejected: \(session.error ?? "unknown")")
            }
            try await wait(150, "moving-cancel editable native document") {
                !session.readOnly && session.canAct && session.documentActionsReady && session.controller != nil
            }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            session.useInkPreferences(workspaceIdentity: root.path, documentKey: source.lastPathComponent)
            let preferences = session.inkPreferences
            let previousStroke = preferences.stroke
            defer {
                preferences.setPreset(previousStroke.preset)
                preferences.setColorHex(previousStroke.colorHex)
                preferences.setWidthMillimeters(previousStroke.widthMillimeters)
                preferences.setTransparencyPercent(previousStroke.transparencyPercent)
            }
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode, "the real App drawing toggle must arm")
            try await applyInkStyle(penStyle, preferences: preferences, session: session, stage: "moving-cancel pen")
            let appliedPen = preferences.stroke
            let appliedPenEMU = appliedPen.lineWidthValue * 360
            let controlStimulus = StrokeStimulus(index: 0, kind: .band, gapMilliseconds: 30, style: .pen)
            let controlReceipt = try await receiveStroke(0, web: web, native: native, window: window,
                root: root, syntheticSource: source, stimulus: controlStimulus, previousPoints: [])
            try validateHitDiagnostics(controlReceipt, stimulus: controlStimulus)
            XCTAssertEqual(controlReceipt["strokeDelta"] as? Int, 1,
                           "The moving-cancel positive control did not complete through the actual pen bridge")
            // The canceled moving contact: the same real seam, but the
            // contact carries several genuine pointermove events and ends
            // with the real pointercancel — never a normal pointerup.
            try await applyInkStyle(markerStyle, preferences: preferences, session: session, stage: "moving-cancel marker")
            let appliedDot = preferences.stroke
            let preCancelFacts = try await officePenFacts(web)
            XCTAssertEqual(preCancelFacts["drawing"] as? Bool, true)
            XCTAssertEqual(preCancelFacts["activeStroke"] as? Bool, false,
                           "a previous stroke must not remain active before the canceled moving contact")
            let movingSteps = 5
            let cancel = try await receiveZeroMotionDot(web: web, native: native, window: window,
                                                        root: root, syntheticSource: source,
                                                        cancelWithPointerCancel: true,
                                                        movingSteps: movingSteps,
                                                        receiptName: "moving-dot-cancel")
            let routeReady = cancel["routeReady"] as? Bool == true
            XCTAssertTrue(routeReady, "The real moving-cancel route was not prepared; this is not classified as a cancel-persistence defect: \(cancel)")
            XCTAssertEqual(cancel["eventsDispatched"] as? Int, 2 + movingSteps,
                           "The moving-cancel seam must dispatch exactly one down, \(movingSteps) real moves and the pointercancel")
            XCTAssertEqual(cancel["movesDispatched"] as? Int, movingSteps,
                           "The moving-cancel seam must dispatch exactly its \(movingSteps) genuine pointermove events")
            XCTAssertEqual(cancel["secondEventKind"] as? String, "pointercancel",
                           "The moving-cancel seam must end the contact with the real pointercancel, never a normal pointerup")
            if let movePoints = cancel["movePoints"] as? [[Any]] {
                XCTAssertEqual(movePoints.count, movingSteps, "The receipt must expose every dispatched move point")
                var previousPoint: [Double]?
                for raw in movePoints {
                    guard raw.count == 2,
                          let x = (raw[0] as? NSNumber)?.doubleValue,
                          let y = (raw[1] as? NSNumber)?.doubleValue else {
                        XCTFail("The moving-cancel receipt returned an invalid move point: \(raw)")
                        continue
                    }
                    if let previous = previousPoint {
                        XCTAssertFalse(previous[0] == x && previous[1] == y,
                                       "Every real pointermove must advance the contact to a distinct point: \(movePoints)")
                    }
                    previousPoint = [x, y]
                }
            } else {
                XCTFail("The moving-cancel receipt did not expose its real move points")
            }
            XCTAssertEqual(cancel["downAccepted"] as? Bool, true,
                           "The actual production pen bridge did not accept the moving down")
            XCTAssertEqual(cancel["activeAfterDown"] as? Bool, true,
                           "The production bridge must own the contact right after the moving down")
            XCTAssertEqual(cancel["activeAfterMoves"] as? Bool, true,
                           "The production pen bridge must keep this unfinished contact active through the \(movingSteps) genuine moves")
            XCTAssertEqual(cancel["activeAfterUp"] as? Bool, false,
                           "A canceled moving contact must not strand the production bridge in an active stroke")
            if let preContactPending = cancel["preContactPending"] as? Int {
                XCTAssertEqual(preContactPending, 0,
                               "Another preview handoff was still pending before the canceled moving contact (waited \(cancel["preContactWaitedMilliseconds"] ?? -1) ms); the cancel evidence was not attributed across contacts")
            }
            if let cancelPreview = cancel["cancelPreview"] as? [String: Any] {
                let clearsBefore = cancelPreview["clearsBeforeContact"] as? Int ?? -1
                let clearsAfter = cancelPreview["clearsAfterContact"] as? Int ?? -2
                if clearsAfter > clearsBefore {
                    XCTAssertEqual(cancelPreview["lastClearReason"] as? String, "pointercancel",
                                   "The canceled contact's own preview drop must carry the bridge's pointercancel reason, never a paint success: \(cancelPreview)")
                }
            }
            try await Task.sleep(for: .milliseconds(350))
            let postCancelFacts = try await officePenFacts(web)
            XCTAssertEqual(postCancelFacts["activeStroke"] as? Bool, false,
                           "The canceled moving contact must not leave an active stroke")
            XCTAssertEqual(postCancelFacts["drawing"] as? Bool, true,
                           "The canceled moving contact must leave the pen gate armed for the next contact")
            // Requirement: the next true stroke still works through the bridge.
            try await applyInkStyle(penStyle, preferences: preferences, session: session, stage: "moving-cancel pen after")
            let nextStimulus = StrokeStimulus(index: 1, kind: .band, gapMilliseconds: 30, style: .pen)
            let nextStroke = try await receiveStroke(1, web: web, native: native, window: window,
                root: root, syntheticSource: source, stimulus: nextStimulus, previousPoints: [])
            try validateHitDiagnostics(nextStroke, stimulus: nextStimulus)
            XCTAssertEqual(nextStroke["strokeDelta"] as? Int, 1,
                           "A moving stroke after a canceled moving contact must complete through the actual pen bridge")
            try await session.toggleDrawing()
            XCTAssertFalse(session.drawingMode)
            let savedCopy = root.appendingPathComponent("moving-cancel-saved.\(format)")
            try fm.copyItem(at: try await session.exportDocument(format: format), to: savedCopy)
            attach(savedCopy, name: "dot-moving-cancel-saved-\(format)")
            XCTAssertEqual(try hash(source), sourceHash, "Moving-cancel export altered the original fixture")
            let saved = try package(savedCopy, format: format)
            XCTAssertTrue(saved.text.contains("CANCEL-MOVE-KEEP"), "Moving-cancel save lost original content")
            if format == "xlsx" {
                XCTAssertEqual(saved.cells["B2"], "12", "Excel basic value lost")
                XCTAssertEqual(saved.formulas["B3"], "B2*2", "Excel formula lost or flattened")
            }
            if format == "pptx" { XCTAssertTrue(saved.text.contains("CANCEL-MOVE-NOTES-KEEP"), "Speaker notes lost") }
            // Authoritative file inspection: exactly the two true strokes, no
            // partial path and no dot of any representation from the canceled
            // moving contact, and every previously completed stroke kept.
            let cancelShapes = saved.vectorShapes.filter { shape in
                Self.nativeDotShape(shape)
                    || (shape.colorHex?.uppercased() == "0000FF" && !shape.paths.isEmpty)
                    || ((shape.fillColorHex ?? "").uppercased() == "0000FF" && shape.prstGeometry != nil)
            }
            XCTAssertEqual(penShapeIdentities(saved, widthEMU: appliedPenEMU).count, 2,
                           "The control and the recovery stroke must persist unchanged with their selected style: \(saved.vectorShapes)")
            XCTAssertEqual(Set(saved.customGeometryPaths).count, 2, "Exactly the two true strokes may own custom geometry")
            XCTAssertEqual(saved.customGeometryPaths.count, 2,
                           "The canceled moving contact must not persist any vector path of its own: \(saved.customGeometryPaths)")
            let downAccepted = cancel["downAccepted"] as? Bool == true
            if downAccepted {
                XCTAssertEqual(cancelShapes.count, 0,
                    "MOVING CANCEL DEFECT: the real pointerdown + \(movingSteps) moves + pointercancel on the production "
                    + "listener finalized as \(cancelShapes.count) persisted shape(s) in the saved \(format); the human "
                    + "contract requires a canceled moving contact to persist nothing. bridge counters: "
                    + "strokeDelta=\(String(describing: cancel["strokeDelta"])) "
                    + "coreEventDelta=\(String(describing: cancel["coreEventDelta"])). shapes=\(saved.vectorShapes)")
            } else {
                XCTAssertEqual(cancelShapes.count, 0,
                               "The canceled contact never reached the engine, so no marker ink may persist either: \(saved.vectorShapes)")
            }
            let manifest: [String: Any] = [
                "case": "dot-moving-cancel", "format": format, "sourceSHA256": sourceHash,
                "savedSHA256": try hash(savedCopy),
                "humanContract": "A genuine moving pointerdown + several real pointermove + pointercancel on the production listener must persist no partial path and no dot; previously completed strokes stay unchanged; the next true stroke still completes through the same bridge.",
                "carrierExpectation": "Integrated carrier (FloeOfficeNative.mm ce3543f, HEAD 08303a31) owns the ordered pointercancel closure, so the no-partial-ink gate is expected to pass; any persisted ink is a real cancel-route regression.",
                "route": "OfficeFileSession.toggleDrawing/applyInkPreferences/stroke seam/marker select/pointerdown+five real pointermove+pointercancel on the production listener/exportDocument/OOXML file inspection",
                "movingSteps": movingSteps,
                "controlReceipt": controlReceipt, "cancelReceipt": cancel,
                "nextStrokeReceipt": nextStroke,
                "preCancelPenFacts": preCancelFacts, "postCancelPenFacts": postCancelFacts,
                "penStyle": ["color": "#FF0000", "widthEMU": appliedPenEMU],
                "dotStyle": ["color": "#0000FF", "widthEMU": appliedDot.lineWidthValue * 360, "preset": appliedDot.preset.rawValue],
                "savedShapes": saved.vectorShapes.map { ["color": $0.colorHex ?? "MISSING", "widthEMU": $0.widthEMU ?? -1, "paths": $0.paths.count, "alpha": $0.alphaValue ?? -1, "prst": $0.prstGeometry ?? "none", "fillColor": $0.fillColorHex ?? "MISSING", "fillAlpha": $0.fillAlphaValue ?? -1, "lineNoFill": $0.lineIsNoFill, "extentEMU": $0.extentEMU ?? [], "placement": $0.placement ?? "none"] as [String: Any] },
                "cancelShapes": cancelShapes.map { ["color": $0.colorHex ?? "MISSING", "widthEMU": $0.widthEMU ?? -1, "paths": $0.paths.count, "prst": $0.prstGeometry ?? "none", "fillColor": $0.fillColorHex ?? "MISSING", "extentEMU": $0.extentEMU ?? []] as [String: Any] },
                "hardwarePointerInput": "not-tested",
                "visualReview": "pending-primary-image-review"
            ]
            let receiptURL = root.appendingPathComponent("dot-moving-cancel-verification.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: receiptURL, options: .atomic)
            attach(receiptURL, name: "dot-moving-cancel-verification-\(format)")
            await session.release()
        } catch {
            await session.release()
            throw error
        }
    }

    /// Drives only the production control path a real user drives:
    /// `OfficeFileSession.toggleDrawing` (the toolbar action), the per-document
    /// ink preference API and the existing band stroke receiver. One control
    /// stroke, one OFF→ON cycle, the post-re-arm stroke, a real disable, save,
    /// and a fresh production-session reopen that re-reads the same bytes.
    /// Exactly one cycle: the gate is exactly two persisted paths; another
    /// cycle without a contact adds no file outcome and a third contact would
    /// change that strict count.
    private func exerciseDrawingModeOffOnNextStroke(_ format: String) async throws {
        guard ProcessInfo.processInfo.environment["FLOE_NATIVE_DRAWING_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in native drawing-mode OFF→ON next-stroke file-outcome contract; not executed")
        }
        executionTimeAllowance = 600
        continueAfterFailure = true
        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Qualification/OfficeModeToggle-\(format)-\(UUID().uuidString)",
                                                   isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("FLOE_MODE_TOGGLE_ARTIFACT_ROOT=\(root.path)")
        let source = root.appendingPathComponent("original.\(format)")
        switch format {
        case "docx":
            try OfficeDocumentBuilder.createWord(at: source, title: "中文模式开关笔迹验收",
                paragraphs: ["MODE-TOGGLE-KEEP 中文正文 12345", "Second paragraph remains editable."])
        case "xlsx":
            try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [
                OfficeWorkbookSheet(name: "模式开关", rows: [["MODE-TOGGLE-KEEP", "数值"], ["原值", "12"], ["公式", "=B2*2"]])
            ])
        default:
            try OfficeDocumentBuilder.createPresentation(at: source, title: "中文模式开关笔迹验收", slides: [
                OfficePresentationSlide(title: "MODE-TOGGLE-KEEP", bullets: ["中文原文 12345", "Editable original content"],
                                        notes: "MODE-TOGGLE-NOTES-KEEP")
            ])
        }
        let sourceHash = try hash(source)
        let baseline = try package(source, format: format)
        XCTAssertEqual(baseline.customGeometryPaths.count, 0, "Fixture must contain no preinserted strokes")
        attach(source, name: "mode-toggle-source-\(format)")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let session = OfficeFileSession()
        let window = mount(session, in: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        let penStyle = OfficeInkStroke(colorHex: "#FF0000", widthMillimeters: 0.5,
                                       transparencyPercent: 0, preset: .pen)
        let exported: URL
        let appliedPenEMU: Int
        let savedFileSHA: String
        let savedGeometryPaths: [String]
        let savedPenIdentities: [String]
        do {
            await session.open(source)
            try await wait(120, "mode-toggle native open") {
                session.canAct && session.documentActionsReady && session.controller != nil
            }
            if session.readOnly {
                let accepted = await session.requestEditing()
                XCTAssertTrue(accepted, "Actual App edit entry rejected: \(session.error ?? "unknown")")
            }
            try await wait(150, "mode-toggle editable native document") {
                !session.readOnly && session.canAct && session.documentActionsReady && session.controller != nil
            }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            session.useInkPreferences(workspaceIdentity: root.path, documentKey: source.lastPathComponent)
            let preferences = session.inkPreferences
            let previousStroke = preferences.stroke
            defer {
                preferences.setPreset(previousStroke.preset)
                preferences.setColorHex(previousStroke.colorHex)
                preferences.setWidthMillimeters(previousStroke.widthMillimeters)
                preferences.setTransparencyPercent(previousStroke.transparencyPercent)
            }
            // Stage 1: arm through the real editor action, no bypass selector.
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode, "the real App drawing toggle must arm")
            XCTAssertEqual(try nativeDrawingFlag(native), true,
                           "the native host must mirror the armed state after a real toggle")
            let armedFacts = try await officePenFacts(web)
            XCTAssertEqual(armedFacts["drawing"] as? Bool, true)
            XCTAssertEqual(armedFacts["activeStroke"] as? Bool, false)
            try await applyInkStyle(penStyle, preferences: preferences, session: session, stage: "mode-toggle pen")
            let appliedPen = preferences.stroke
            appliedPenEMU = appliedPen.lineWidthValue * 360
            // Stage 2: the completed control contact through the existing seam.
            let controlStimulus = StrokeStimulus(index: 0, kind: .band, gapMilliseconds: 350, style: .pen)
            let controlReceipt = try await receiveStroke(0, web: web, native: native, window: window,
                root: root, syntheticSource: source, stimulus: controlStimulus, previousPoints: [])
            try validateHitDiagnostics(controlReceipt, stimulus: controlStimulus)
            XCTAssertEqual(controlReceipt["strokeDelta"] as? Int, 1,
                           "The mode-toggle positive control did not complete through the actual pen bridge")
            XCTAssertEqual(controlReceipt["downAccepted"] as? Bool, true,
                           "The real pen down must be accepted before the OFF→ON cycle")
            // Stage 3: the OFF half of the real toggle.
            try await session.toggleDrawing()
            XCTAssertFalse(session.drawingMode, "the real App drawing toggle must publish Off")
            XCTAssertEqual(try nativeDrawingFlag(native), false,
                           "the native mirror must disarm with a real disable")
            let offFacts = try await officePenFacts(web)
            XCTAssertEqual(offFacts["drawing"] as? Bool, false, "the page gate must be off after a real disable")
            XCTAssertEqual(offFacts["activeStroke"] as? Bool, false,
                           "a real disable must not strand an active stroke")
            // Stage 4: the ON half in the SAME session — the production re-arm.
            // The production enable reapplies the current ink.
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode, "the real App drawing toggle must re-arm after OFF")
            XCTAssertEqual(try nativeDrawingFlag(native), true,
                           "the native mirror must re-arm with the second real toggle")
            XCTAssertNil(session.inkError, "the re-enable path must republish the selected ink without an App error")
            XCTAssertEqual(preferences.stroke.preset, penStyle.preset,
                           "the selected preset must survive the OFF→ON cycle")
            XCTAssertEqual(preferences.stroke.colorHex, penStyle.colorHex,
                           "the selected colour must survive the OFF→ON cycle")
            XCTAssertEqual(preferences.stroke.widthMillimeters, penStyle.widthMillimeters,
                           "the selected width must survive the OFF→ON cycle")
            XCTAssertEqual(preferences.stroke.transparencyPercent, penStyle.transparencyPercent,
                           "the selected transparency must survive the OFF→ON cycle")
            let rearmedFacts = try await officePenFacts(web)
            XCTAssertEqual(rearmedFacts["drawing"] as? Bool, true,
                           "the page gate must be armed again after OFF→ON")
            XCTAssertEqual(rearmedFacts["activeStroke"] as? Bool, false,
                           "re-arming must not strand an active stroke")
            // Stage 5: the post-re-arm contact — the same receiver protocol, no
            // cancel, no zero-motion, no new seam arguments.
            let nextStimulus = StrokeStimulus(index: 1, kind: .band, gapMilliseconds: 350, style: .pen)
            let nextStroke = try await receiveStroke(1, web: web, native: native, window: window,
                root: root, syntheticSource: source, stimulus: nextStimulus, previousPoints: [])
            try validateHitDiagnostics(nextStroke, stimulus: nextStimulus)
            XCTAssertEqual(nextStroke["strokeDelta"] as? Int, 1,
                           "A moving stroke after the same-session OFF→ON re-arm must complete through the actual pen bridge")
            XCTAssertEqual(nextStroke["downAccepted"] as? Bool, true,
                           "The production bridge must accept the post-re-arm pen down")
            // Stage 6: leave drawing mode with the real control, then save.
            try await session.toggleDrawing()
            XCTAssertFalse(session.drawingMode)
            let savedCopy = root.appendingPathComponent("mode-toggle-saved.\(format)")
            try fm.copyItem(at: try await session.exportDocument(format: format), to: savedCopy)
            exported = savedCopy
            attach(savedCopy, name: "mode-toggle-saved-\(format)")
            XCTAssertEqual(try hash(source), sourceHash, "Mode-toggle export altered the original fixture")
            // Authoritative file inspection: exactly the two true strokes at
            // the selected style, the whole original content kept, no artifact.
            let saved = try package(savedCopy, format: format)
            savedFileSHA = try hash(savedCopy)
            savedGeometryPaths = saved.customGeometryPaths
            savedPenIdentities = penShapeIdentities(saved, widthEMU: appliedPenEMU)
            assertModeToggleOriginalContent(saved, format: format, stage: "saved")
            if format == "xlsx" {
                XCTAssertGreaterThanOrEqual(saved.validAnchors, 1,
                                            "The persisted Excel contacts need a nonzero visible sheet anchor")
            }
            XCTAssertEqual(saved.customGeometryPaths.count, 2,
                           "MODE-TOGGLE FILE GATE: the same-session OFF→ON re-arm must persist the control and the "
                           + "post-re-arm stroke as two true contacts; the saved \(format) carries "
                           + "\(saved.customGeometryPaths.count) vector path(s): \(saved.customGeometryPaths)")
            XCTAssertEqual(Set(saved.customGeometryPaths).count, 2,
                           "The two persisted contacts must own distinct real geometry")
            XCTAssertTrue(saved.customGeometryPointCounts.allSatisfy { $0 >= 3 }, "Missing actual vector points")
            XCTAssertEqual(savedPenIdentities.count, 2,
                           "The control and the post-re-arm stroke must persist at the selected red pen style: \(saved.vectorShapes)")
            XCTAssertEqual(saved.vectorShapes.filter { !$0.paths.isEmpty }.count, 2,
                           "No ink shape beyond the two real contacts may persist: \(saved.vectorShapes)")
            XCTAssertEqual(saved.vectorShapes.filter { Self.nativeDotShape($0) }.count, 0,
                           "The OFF→ON cycle must not persist a dot artifact: \(saved.vectorShapes)")
            for shape in saved.vectorShapes where !shape.paths.isEmpty {
                XCTAssertEqual(shape.colorHex?.uppercased(), "FF0000",
                               "The selected pen colour must persist: \(shape.description)")
                XCTAssertEqual(shape.widthEMU.map { abs($0 - appliedPenEMU) <= 635 }, true,
                               "The selected pen width must persist within one twip: \(shape.description)")
                XCTAssertTrue(shape.alphaValue == nil || shape.alphaValue == 100_000,
                              "Opaque pen strokes must not save a transparent line alpha: \(shape.description)")
            }
            let manifest: [String: Any] = [
                "case": "drawing-mode-off-on-next-stroke", "format": format, "sourceSHA256": sourceHash,
                "savedSHA256": savedFileSHA,
                "humanContract": "After a completed moving pen stroke, turning drawing mode OFF and back ON with the real editor control in the same session must leave the next genuine moving Pencil contact persisting exactly one new vector at the selected style, with the control stroke and all original content intact in the saved and reopened file.",
                "coverageGap": "Existing native cases never disable-then-re-enable drawing mode between strokes; whether the first post-re-arm contact persists is unmeasured and is not assumed here.",
                "toggleCycles": 1,
                "route": "OfficeFileSession.toggleDrawing (real editor action)/native setDrawingMode:completion:/applyInkPreferences/existing stroke seam/exportDocument/OOXML file inspection/fresh production reopen",
                "controlReceipt": controlReceipt, "nextStrokeReceipt": nextStroke,
                "armedFacts": armedFacts, "offFacts": offFacts, "rearmedFacts": rearmedFacts,
                "penStyle": ["color": "#FF0000", "widthEMU": appliedPenEMU, "preset": appliedPen.preset.rawValue],
                "savedShapes": saved.vectorShapes.map { ["color": $0.colorHex ?? "MISSING", "widthEMU": $0.widthEMU ?? -1, "paths": $0.paths.count, "alpha": $0.alphaValue ?? -1, "prst": $0.prstGeometry ?? "none", "fillColor": $0.fillColorHex ?? "MISSING", "fillAlpha": $0.fillAlphaValue ?? -1, "lineNoFill": $0.lineIsNoFill, "extentEMU": $0.extentEMU ?? [], "placement": $0.placement ?? "none"] as [String: Any] },
                "hardwarePointerInput": "not-tested",
                "visualReview": "pending-primary-image-review"
            ]
            let receiptURL = root.appendingPathComponent("mode-toggle-verification.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: receiptURL, options: .atomic)
            attach(receiptURL, name: "mode-toggle-verification-\(format)")
            await session.release()
        } catch {
            // Release the failed session before any reopen attempt.
            await session.release()
            throw error
        }
        // Fresh production session over the exact saved bytes: the real engine
        // must load and paint the two-path document, the reopen must not rewrite
        // the exported file, and the reread bytes must still carry the same two
        // selected-style vectors and all original content.
        let reopen = OfficeFileSession()
        let reopenWindow = mount(reopen, in: scene)
        defer { reopenWindow.isHidden = true; reopenWindow.rootViewController = nil }
        do {
            await reopen.open(exported)
            try await wait(120, "mode-toggle saved document reopen") {
                reopen.canAct && reopen.documentActionsReady && reopen.controller != nil
            }
            let reopened = try XCTUnwrap(reopen.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(reopened)
            let reopenedFileSHA = try hash(exported)
            XCTAssertEqual(reopenedFileSHA, savedFileSHA,
                           "the fresh production reopen altered the exported \(format) bytes")
            let reread = try package(exported, format: format)
            XCTAssertEqual(reread.customGeometryPaths, savedGeometryPaths,
                           "the reopened \(format) must keep the exact saved vector paths")
            XCTAssertEqual(penShapeIdentities(reread, widthEMU: appliedPenEMU), savedPenIdentities,
                           "the reopened \(format) must keep the same selected-style vectors")
            assertModeToggleOriginalContent(reread, format: format, stage: "reopened")
            print("FLOE_MODE_TOGGLE_REOPEN_SHA256=\(reopenedFileSHA)")
            let reopenWeb = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: reopened.view))
            let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
            let image = try await reopenWeb.takeSnapshot(configuration: config)
            let png = try XCTUnwrap(image.pngData())
            let screenshot = root.appendingPathComponent("mode-toggle-reopened-native-\(format).png")
            try png.write(to: screenshot)
            attach(screenshot, name: "mode-toggle-reopened-native-\(format)")
            let windowImage = UIGraphicsImageRenderer(bounds: reopenWindow.bounds).image { _ in
                reopenWindow.drawHierarchy(in: reopenWindow.bounds, afterScreenUpdates: true)
            }
            let whole = root.appendingPathComponent("mode-toggle-reopened-window-\(format).png")
            try XCTUnwrap(windowImage.pngData()).write(to: whole)
            attach(whole, name: "mode-toggle-reopened-window-\(format)")
            let receiptURL = root.appendingPathComponent("mode-toggle-verification.json")
            var receipt = (try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL))) as? [String: Any] ?? [:]
            receipt["savedCopyReopened"] = true
            receipt["reopenedFileSHA256"] = reopenedFileSHA
            receipt["reopenFileUnchanged"] = reopenedFileSHA == savedFileSHA
            receipt["reopenedVectorPaths"] = reread.customGeometryPaths.count
            receipt["reopenedCustomGeometryMatches"] = reread.customGeometryPaths == savedGeometryPaths
            receipt["reopenedPenIdentities"] = penShapeIdentities(reread, widthEMU: appliedPenEMU)
            receipt["reopenNativeRenderDiagnostics"] = OfficeFileSession.hostRenderDiagnostics(reopened)
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: receiptURL, options: .atomic)
            attach(receiptURL, name: "mode-toggle-reopen-verification-\(format)")
            await reopen.release()
        } catch { await reopen.release(); throw error }
    }

    /// Whole-fixture original-content semantics for the mode-toggle case: the
    /// Word title and both known paragraphs, every Excel label/value/formula,
    /// and the presentation title, bullets and speaker notes. Exercised on the
    /// saved file and again on the exact bytes reread after the fresh reopen.
    private func assertModeToggleOriginalContent(_ pkg: DrawingQualificationXML, format: String, stage: String) {
        switch format {
        case "docx":
            for expected in ["中文模式开关笔迹验收", "MODE-TOGGLE-KEEP 中文正文 12345",
                             "Second paragraph remains editable."] {
                XCTAssertTrue(pkg.text.contains(expected), "\(stage): Word original content lost: \(expected)")
            }
        case "xlsx":
            for expected in ["MODE-TOGGLE-KEEP", "数值", "原值", "公式"] {
                XCTAssertTrue(pkg.text.contains(expected), "\(stage): Excel original content lost: \(expected)")
            }
            XCTAssertEqual(pkg.cells["B2"], "12", "\(stage): Excel basic value lost")
            XCTAssertEqual(pkg.formulas["B3"], "B2*2", "\(stage): Excel formula lost or flattened")
        default:
            for expected in ["MODE-TOGGLE-KEEP", "中文原文 12345", "Editable original content",
                             "MODE-TOGGLE-NOTES-KEEP"] {
                XCTAssertTrue(pkg.text.contains(expected), "\(stage): Presentation original content lost: \(expected)")
            }
        }
    }

    /// Deterministic regression for the real S1 routing branch. A real engine
    /// freehand curve is selected by its post-stroke selection echo or with the
    /// pinned core's own select tool plus a real DOM down/up/click sequence
    /// (a standalone `click` never reaches `MouseControl`), the authentic
    /// `graphicselection:` message is captured
    /// through the document layer's actual message handler, the live core
    /// selection is cleared with the production gate, marker attributes are
    /// applied, and that captured delayed callback is replayed through the
    /// original frontend handler in the same JavaScript turn as a Pencil down
    /// on a real independent `shape-handle-*` child center. The production b83
    /// gate must record a positive suspension, the next contact must save
    /// exactly one new curve, and the prior curve's saved
    /// path/placement/anchor/style must not change.
    private func exerciseStaleShapeHandleReplay(_ format: String) async throws {
        guard ProcessInfo.processInfo.environment["FLOE_NATIVE_DRAWING_APP_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt-in App drawing + real stale shape-handle replay; not executed")
        }
        XCTAssertTrue(["xlsx", "pptx"].contains(format), "Only the two formats with observed stale handles are qualified")
        executionTimeAllowance = 600
        continueAfterFailure = true
        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent("Qualification/OfficeStaleHandle-\(format)-\(UUID().uuidString)",
                                                     isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("FLOE_STALE_HANDLE_ARTIFACT_ROOT=\(root.path)")
        let source = root.appendingPathComponent("original.\(format)")
        switch format {
        case "xlsx":
            try OfficeDocumentBuilder.createWorkbook(at: source, sheets: [
                OfficeWorkbookSheet(name: "基准", rows: [["BASELINE-DRAWING-KEEP", "数值"], ["原值", "12"], ["公式", "=B2*2"]])
            ])
        case "pptx":
            try OfficeDocumentBuilder.createPresentation(at: source, title: "中文笔迹验收 Stale Handle", slides: [
                OfficePresentationSlide(title: "BASELINE-DRAWING-KEEP",
                                        bullets: ["中文原文 12345", "Editable original content"],
                                        notes: "DRAWING-NOTES-KEEP")
            ])
        default:
            throw CocoaError(.featureUnsupported)
        }
        let sourceHash = try hash(source)
        let baseline = try package(source, format: format)
        XCTAssertEqual(baseline.customGeometryPaths.count, 0, "Fixture must contain no preinserted strokes")
        attach(source, name: "stale-handle-source-\(format)")
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let session = OfficeFileSession()
        let window = mount(session, in: scene)
        defer { window.isHidden = true; window.rootViewController = nil; previousKeyWindow?.makeKey() }
        let exported = root.appendingPathComponent("drawn.\(format)")
        var diagnosticsWeb: WKWebView?
        var diagnosticsNative: FloeOfficeNativeViewController?
        var selectionReceipt: [String: Any] = [:]
        var replayReceipt: [String: Any] = [:]
        do {
            await session.open(source)
            try await wait(120, "stale-handle native open") {
                session.canAct && session.documentActionsReady && session.controller != nil
            }
            if session.readOnly {
                let accepted = await session.requestEditing()
                XCTAssertTrue(accepted, "Actual App edit entry rejected: \(session.error ?? "unknown")")
            }
            try await wait(150, "stale-handle editable native document") {
                !session.readOnly && session.canAct && session.documentActionsReady && session.controller != nil
            }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            diagnosticsWeb = web
            diagnosticsNative = native
            session.useInkPreferences(workspaceIdentity: root.path, documentKey: source.lastPathComponent)
            let preferences = session.inkPreferences
            let previousStroke = preferences.stroke
            defer {
                preferences.setPreset(previousStroke.preset)
                preferences.setColorHex(previousStroke.colorHex)
                preferences.setWidthMillimeters(previousStroke.widthMillimeters)
                preferences.setTransparencyPercent(previousStroke.transparencyPercent)
            }
            preferences.setPreset(.pen)
            preferences.setColorHex("#FF0000")
            preferences.setWidthMillimeters(0.5)
            preferences.setTransparencyPercent(0)
            XCTAssertEqual(preferences.stroke.preset, .pen)
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode, "The real App toggle must arm drawing")
            await session.applyInkPreferences()
            XCTAssertNil(session.inkError,
                         "Pen attributes were rejected before the first curve: \(session.inkError ?? "unknown")")
            XCTAssertNotNil(session.inkApplyOutcome, "Pen attributes were not dispatched before the first curve")
            XCTAssertEqual(try nativeDrawingFlag(native), true)

            let firstStimulus = StrokeStimulus(index: 0, kind: .band, gapMilliseconds: 30, style: .pen)
            let firstReceipt = try await receiveStroke(0, web: web, native: native, window: window, root: root,
                syntheticSource: source, stimulus: firstStimulus, previousPoints: [])
            try validateHitDiagnostics(firstReceipt, stimulus: firstStimulus)
            XCTAssertEqual(firstReceipt["strokeDelta"] as? Int, 1, "The first production curve must complete")
            XCTAssertEqual(firstReceipt["downAccepted"] as? Bool, true)
            let curvePoints = try clientPoints(firstReceipt, index: 0)
            let visible = try visibleDocumentRect(firstReceipt)
            let firstFacts: [String: Any] = ["points": curvePoints,
                "visibleDocumentRect": visible, "receipt": firstReceipt]
            let firstFactsURL = root.appendingPathComponent("first-curve-receipt.json")
            try JSONSerialization.data(withJSONObject: firstFacts, options: [.prettyPrinted, .sortedKeys])
                .write(to: firstFactsURL, options: .atomic)
            attach(firstFactsURL, name: "stale-handle-first-curve-\(format)")

            // Select only after leaving the freehand tool, exactly as a user
            // would: production mode off, real core select command, then a
            // real down/up/click at an actual contact point of the
            // engine-created curve. A standalone DOM click never reaches the
            // pinned CanvasSectionContainer/MouseControl path.
            try await session.toggleDrawing()
            XCTAssertFalse(session.drawingMode, "Drawing must be off while the real object is selected")
            XCTAssertEqual(try nativeDrawingFlag(native), false)

            let selectionRequest: [String: Any] = ["documentFormat": format,
                "curvePoints": curvePoints, "visibleDocumentRect": visible]
            let selectionValue = try await web.callAsyncJavaScript(Self.staleHandleSelectionScript,
                arguments: selectionRequest, in: nil, contentWorld: .page)
            selectionReceipt = try decodePageReceipt(selectionValue, limit: 98_304,
                                                     stage: "real shape selection")
            let selectionURL = root.appendingPathComponent("selection-receipt.json")
            try JSONSerialization.data(withJSONObject: selectionReceipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: selectionURL, options: .atomic)
            attach(selectionURL, name: "stale-handle-selection-\(format)")
            guard let capture = selectionReceipt["capture"] as? [String: Any],
                  let message = capture["message"] as? String,
                  message.hasPrefix("graphicselection:"), message.utf8.count <= 16_384,
                  let captureType = capture["type"] as? String,
                  captureType == "freehandLine" || captureType == "pathLine" else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 60, userInfo: [
                    NSLocalizedDescriptionKey: "The real core selection did not return an authentic bounded freehand graphicselection message"
                ])
            }
            XCTAssertEqual(selectionReceipt["hookRestored"] as? Bool, true,
                           "The qualification hook must restore the exact original document-layer handler")
            // Acquisition proves the authentic engine callback and the hook
            // restore. Its immediate post-handler section/child snapshot is
            // retained as evidence, but a later genuine empty callback may
            // clear the persistent handles before this stage ends. The delayed
            // synchronous replay below must independently hit a real child
            // handle and prove the production suspension and saved 1->2.
            let afterCapture = selectionReceipt["afterCapture"] as? [String: Any]
            XCTAssertNotNil(afterCapture,
                            "The authentic callback must be sampled synchronously after the real handler")
            let capturePhase = selectionReceipt["capturePhase"] as? String
            XCTAssertTrue(["post-stroke-echo", "select-click"].contains(capturePhase ?? ""),
                          "The capture must record which real engine callback produced it: \(capturePhase ?? "nil")")

            // Clear the live core selection with the production gate, which
            // posts the same Escape pair as a normal dispose. The apply-ink
            // bridge refuses to style a selected object, so this also proves
            // the re-arm path is not styling the prior curve.
            let deselectValue = try await web.callAsyncJavaScript(Self.staleHandleDeselectScript,
                arguments: [:], in: nil, contentWorld: .page)
            let deselect = try decodePageReceipt(deselectValue, limit: 16_384,
                                                 stage: "production deselection")
            XCTAssertEqual(deselect["cleared"] as? Bool, true,
                           "The production gate must clear the real core selection before re-arming: \(deselect)")
            XCTAssertEqual(deselect["gateResult"] as? Bool, true)

            // Prior geometry checkpoint: one real saved curve, taken after the
            // selection was captured and cleared but before the delayed contact.
            // This keeps the selection click on the live first-curve view while
            // still giving the final package an exact before/after object.
            let checkpointNative = try await session.exportDocument(format: format)
            let checkpoint = root.appendingPathComponent("checkpoint1.\(format)")
            try fm.copyItem(at: checkpointNative, to: checkpoint)
            attach(checkpoint, name: "stale-handle-checkpoint-\(format)")
            let checkpointXML = try package(checkpoint, format: format)
            XCTAssertEqual(checkpointXML.customGeometryPaths.count, 1,
                           "The checkpoint must contain exactly the first engine-saved curve: \(checkpointXML.customGeometryPaths.count)")
            XCTAssertEqual(checkpointXML.vectorShapes.count, 1,
                           "The checkpoint must contain exactly one vector shape: \(checkpointXML.vectorShapes)")
            let priorShape = try XCTUnwrap(checkpointXML.vectorShapes.first)
            let priorPath = try XCTUnwrap(priorShape.paths.first)
            XCTAssertEqual(priorShape.paths.count, 1)
            XCTAssertEqual(priorShape.colorHex?.uppercased(), "FF0000")
            XCTAssertEqual(priorShape.widthEMU, 18_000)
            XCTAssertTrue(priorShape.alphaValue == nil || priorShape.alphaValue == 100_000)
            XCTAssertNotNil(priorShape.placement,
                            "The prior curve's own xfrm placement must be parsed for the before/after check")
            if format == "xlsx" {
                XCTAssertNotNil(priorShape.anchor,
                                "The prior curve's xdr anchor must be parsed for the before/after check")
                XCTAssertEqual(checkpointXML.validAnchors, 1,
                               "The prior curve must own exactly one visible sheet anchor")
            }
            let checkpointFacts: [String: Any] = [
                "format": format, "pathCount": checkpointXML.customGeometryPaths.count,
                "priorPathSHA256": Self.sha256(priorPath),
                "priorShape": priorShape.description,
                "priorPlacement": priorShape.placement ?? "missing",
                "priorAnchor": priorShape.anchor ?? "missing",
                "validAnchors": checkpointXML.validAnchors,
                "sourceSHA256": sourceHash, "checkpointSHA256": try hash(checkpoint)
            ]
            let checkpointJSON = root.appendingPathComponent("checkpoint-package.json")
            try JSONSerialization.data(withJSONObject: checkpointFacts, options: [.prettyPrinted, .sortedKeys])
                .write(to: checkpointJSON, options: .atomic)
            attach(checkpointJSON, name: "stale-handle-checkpoint-package-\(format)")

            // The checkpoint export must not leave a live core selection that
            // the ink bridge would refuse to style. Re-assert the production
            // deselect immediately before the real re-arm.
            let preArmValue = try await web.callAsyncJavaScript(Self.staleHandleDeselectScript,
                arguments: [:], in: nil, contentWorld: .page)
            let preArm = try decodePageReceipt(preArmValue, limit: 16_384,
                                               stage: "pre-arm deselection")
            XCTAssertEqual(preArm["cleared"] as? Bool, true,
                           "The production gate must leave no live selection before marker re-arm: \(preArm)")

            // The second contact uses a visibly different real native style so
            // the saved OOXML can prove these attributes were applied before it.
            preferences.setPreset(.marker)
            preferences.setColorHex("#0000FF")
            preferences.setWidthMillimeters(2.0)
            preferences.setTransparencyPercent(0)
            XCTAssertEqual(preferences.stroke.preset, .marker)
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode, "The real App toggle must re-arm drawing")
            XCTAssertEqual(try nativeDrawingFlag(native), true)
            await session.applyInkPreferences()
            XCTAssertNil(session.inkError,
                         "Marker attributes were rejected before the delayed replay: \(session.inkError ?? "unknown")")
            XCTAssertNotNil(session.inkApplyOutcome, "Marker attributes were not dispatched before the delayed replay")

            let replayRequest: [String: Any] = ["message": message, "curvePoints": curvePoints,
                "visibleDocumentRect": visible, "strokeID": 7]
            let replayValue = try await web.callAsyncJavaScript(Self.staleHandleReplayScript,
                arguments: replayRequest, in: nil, contentWorld: .page)
            replayReceipt = try decodePageReceipt(replayValue, limit: 65_536,
                                                  stage: "delayed selection replay")
            replayReceipt["replayedMessageSHA256"] = Self.sha256(message)
            let replayURL = root.appendingPathComponent("replay-receipt.json")
            try JSONSerialization.data(withJSONObject: replayReceipt, options: [.prettyPrinted, .sortedKeys])
                .write(to: replayURL, options: .atomic)
            attach(replayURL, name: "stale-handle-replay-\(format)")

            XCTAssertEqual(replayReceipt["beforeHitIsChildShapeHandle"] as? Bool, true,
                           "The contact must start on an independent shape-handle-* child: \(replayReceipt["beforeHitName"] ?? "nil")")
            XCTAssertEqual((replayReceipt["replayedMessageSHA256"] as? String)?.count, 64)
            XCTAssertGreaterThan(replayReceipt["suspensionDeltaAtDown"] as? Int ?? 0, 0,
                                 "The production b83 gate must record a positive stale-handle suspension at the down")
            let afterDown = replayReceipt["afterDown"] as? [String: Any]
            XCTAssertEqual(afterDown?["hitIsShapeHandle"] as? Bool, false,
                           "The replayed down must not remain routed to a shape handle")
            XCTAssertEqual(afterDown?["hitIsChildShapeHandle"] as? Bool, false,
                           "The replayed down must not remain routed to an independent handle child")
            XCTAssertEqual(afterDown?["shownChildCount"] as? Int, 0,
                           "Every shown independent shape-handle child must be hidden at the down")
            XCTAssertEqual(afterDown?["shown"] as? Bool, false)
            XCTAssertEqual(replayReceipt["downAccepted"] as? Bool, true)
            XCTAssertEqual(replayReceipt["strokeDelta"] as? Int, 1,
                           "The delayed-replay contact must save one new curve")
            XCTAssertGreaterThanOrEqual(replayReceipt["coreEventDelta"] as? Int ?? 0, 5)
            XCTAssertEqual(replayReceipt["activeAfter"] as? Bool, false)

            try await session.toggleDrawing()
            XCTAssertFalse(session.drawingMode, "The test must leave drawing off before the final export")
            let finalNative = try await session.exportDocument(format: format)
            try fm.copyItem(at: finalNative, to: exported)
            attach(exported, name: "stale-handle-saved-\(format)")
            XCTAssertEqual(try hash(source), sourceHash, "The original synthetic source must not change")
            let finalXML = try package(exported, format: format)
            XCTAssertEqual(finalXML.customGeometryPaths.count, 2,
                           "Exactly one additional engine-saved curve is required: \(finalXML.customGeometryPaths.count)")
            XCTAssertEqual(Set(finalXML.customGeometryPaths).count, 2, "The two saved curves must differ")
            XCTAssertTrue(finalXML.customGeometryPaths.contains(priorPath),
                          "The prior curve's saved path changed; prior=\(Self.sha256(priorPath)) "
                            + "final=\(finalXML.customGeometryPaths.map(Self.sha256))")
            let finalPrior = try XCTUnwrap(finalXML.vectorShapes.first { $0.paths.contains(priorPath) },
                                           "The prior vector shape disappeared after the new contact: \(finalXML.vectorShapes)")
            XCTAssertEqual(finalPrior.paths, priorShape.paths, "The prior curve path must remain unchanged")
            XCTAssertEqual(finalPrior.colorHex, priorShape.colorHex, "The prior curve style must remain unchanged")
            XCTAssertEqual(finalPrior.widthEMU, priorShape.widthEMU, "The prior curve width must remain unchanged")
            XCTAssertEqual(finalPrior.alphaValue, priorShape.alphaValue, "The prior curve alpha must remain unchanged")
            XCTAssertEqual(finalPrior.placement, priorShape.placement, "The prior curve placement must remain unchanged")
            if format == "xlsx" {
                XCTAssertEqual(finalPrior.anchor, priorShape.anchor, "The prior curve anchor must remain unchanged")
            }
            let newShape = try XCTUnwrap(finalXML.vectorShapes.first { !$0.paths.contains(priorPath) },
                                         "The new curve must be a distinct saved vector shape: \(finalXML.vectorShapes)")
            XCTAssertEqual(newShape.paths.count, 1)
            XCTAssertEqual(newShape.colorHex?.uppercased(), "0000FF",
                           "The delayed-replay curve must save the real marker colour applied before it")
            XCTAssertEqual(newShape.widthEMU, 72_000,
                           "The delayed-replay curve must save the real marker width applied before it")
            XCTAssertTrue(newShape.alphaValue == nil || newShape.alphaValue == 100_000)
            XCTAssertNotNil(newShape.placement, "The new curve's xfrm placement must be parsed")
            if format == "xlsx" {
                XCTAssertNotNil(newShape.anchor, "The new curve's xdr anchor must be parsed")
            }
            XCTAssertNotEqual(newShape.paths.first, priorPath)
            XCTAssertTrue(finalXML.text.contains("BASELINE-DRAWING-KEEP"), "Original text content was lost")
            if format == "xlsx" {
                XCTAssertEqual(finalXML.cells["B2"], "12", "Excel basic value lost")
                XCTAssertEqual(finalXML.formulas["B3"], "B2*2", "Excel formula lost or flattened")
                XCTAssertGreaterThanOrEqual(finalXML.validAnchors, checkpointXML.validAnchors + 1,
                                            "The new curve needs its own visible sheet anchor")
            }
            if format == "pptx" {
                XCTAssertTrue(finalXML.text.contains("DRAWING-NOTES-KEEP"), "Speaker notes lost")
            }

            let manifest: [String: Any] = [
                "format": format, "sourceSHA256": sourceHash,
                "checkpointSHA256": try hash(checkpoint), "outputSHA256": try hash(exported),
                "route": "real engine curve -> authentic post-stroke selection echo or real .uno:SelectObject DOM down/up/click -> captured graphicselection (post-handler snapshot) -> production deselection -> Native b83 replay+pen contact -> saved OOXML",
                "firstCurveClientPoints": curvePoints,
                "selection": selectionReceipt,
                "replay": replayReceipt,
                "replayedMessageSHA256": Self.sha256(message),
                "suspensionDeltaAtDown": replayReceipt["suspensionDeltaAtDown"] ?? -1,
                "priorPathSHA256": Self.sha256(priorPath),
                "priorShape": priorShape.description,
                "priorPlacement": priorShape.placement ?? "missing",
                "priorAnchor": priorShape.anchor ?? "missing",
                "finalPathSHA256s": finalXML.customGeometryPaths.map(Self.sha256),
                "finalShapes": finalXML.vectorShapes.map { shape in
                    ["description": shape.description, "placement": shape.placement ?? "missing",
                     "anchor": shape.anchor ?? "missing", "pathSHA256s": shape.paths.map(Self.sha256)] as [String: Any]
                },
                "validAnchors": finalXML.validAnchors,
                "hardwarePointerInput": "not-tested",
                "visualReview": "pending-primary-image-review"
            ]
            let receiptURL = root.appendingPathComponent("verification.json")
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
                .write(to: receiptURL, options: .atomic)
            attach(receiptURL, name: "stale-handle-verification-\(format)")
            await session.release()
        } catch {
            if let web = diagnosticsWeb {
                await retainStaleHandleFailure(web: web, native: diagnosticsNative, window: window,
                                               root: root, stage: "stale-handle-\(format)", error: error)
            }
            // Report the acquisition/replay failure itself. The old throw path
            // could surface the secondary session-close state-machine
            // InvalidTransition { idle -> failed(deinit) } instead of the
            // actual failure; keep the diagnostic JSON and make the first
            // failure readable.
            XCTFail("stale-handle \(format) failed: \(error.localizedDescription)")
            await session.release()
            return
        }

        // Fresh native session: the exact saved copy must reopen and paint.
        // Hash the file before the reopen session can touch it, and compare
        // only after that session is released; hashing twice inside the same
        // read window would not prove the reopen preserved the file.
        let savedCopyHashBeforeReopen = try hash(exported)
        let preReopenReceipt = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("verification.json")))) as? [String: Any]
        XCTAssertEqual(preReopenReceipt?["outputSHA256"] as? String, savedCopyHashBeforeReopen,
                       "The pre-reopen saved copy must match the just-written manifest")
        let reopen = OfficeFileSession()
        let reopenWindow = mount(reopen, in: scene)
        defer { reopenWindow.isHidden = true; reopenWindow.rootViewController = nil }
        do {
            await reopen.open(exported)
            try await wait(120, "stale-handle saved copy reopen") {
                reopen.canAct && reopen.documentActionsReady && reopen.controller != nil
            }
            let native = try XCTUnwrap(reopen.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            let config = WKSnapshotConfiguration(); config.afterScreenUpdates = true
            let image = try await web.takeSnapshot(configuration: config)
            let png = try XCTUnwrap(image.pngData())
            let screenshot = root.appendingPathComponent("reopened-native-\(format).png")
            try png.write(to: screenshot)
            attach(screenshot, name: "stale-handle-reopened-native-\(format)")
            let windowImage = UIGraphicsImageRenderer(bounds: reopenWindow.bounds).image { _ in
                reopenWindow.drawHierarchy(in: reopenWindow.bounds, afterScreenUpdates: true)
            }
            let whole = root.appendingPathComponent("reopened-window-\(format).png")
            try XCTUnwrap(windowImage.pngData()).write(to: whole)
            attach(whole, name: "stale-handle-reopened-window-\(format)")
            let renderDiagnostics = OfficeFileSession.hostRenderDiagnostics(native)
            await reopen.release()
            let savedCopyHashAfterReopen = try hash(exported)
            let receiptURL = root.appendingPathComponent("verification.json")
            var receipt = (try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL))) as? [String: Any] ?? [:]
            receipt["savedCopyReopened"] = true
            receipt["savedCopySHA256BeforeReopen"] = savedCopyHashBeforeReopen
            receipt["savedCopySHA256AfterReopen"] = savedCopyHashAfterReopen
            receipt["savedCopyUnchangedAfterReopen"] = savedCopyHashBeforeReopen == savedCopyHashAfterReopen
            receipt["reopenNativeRenderDiagnostics"] = renderDiagnostics
            receipt["visualReview"] = "pending-primary-image-review"
            XCTAssertEqual(savedCopyHashAfterReopen, savedCopyHashBeforeReopen,
                           "The saved copy changed while it was reopened")
            XCTAssertEqual(receipt["savedCopyUnchangedAfterReopen"] as? Bool, true)
            try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]).write(to: receiptURL)
            attach(receiptURL, name: "stale-handle-reopen-verification-\(format)")
        } catch { await reopen.release(); throw error }
    }

    private func receiveStroke(_ index: Int, web: WKWebView,
                               native: FloeOfficeNativeViewController, window: UIWindow,
                               root: URL, syntheticSource: URL,
                               stimulus: StrokeStimulus, previousPoints: [[Double]]) async throws -> [String: Any] {
        var resultType = "not-returned"
        var jsonByteCount: Int?
        var stage = "call-actual-pen-bridge"
        do {
            let receipt: Any? = try await web.callAsyncJavaScript(Self.strokeScript,
                arguments: ["strokeID": index,
                            "probeEnabled": ProcessInfo.processInfo.environment["FLOE_A3_PROBE"] == "1",
                            "stimulusMode": stimulus.kind.rawValue,
                            "gapMilliseconds": stimulus.gapMilliseconds,
                            "previousStrokeID": stimulus.previousIndex ?? -1,
                            "previousPoints": previousPoints], in: nil, contentWorld: .page)
            resultType = receipt.map { String(reflecting: type(of: $0)) } ?? "nil"
            stage = "decode-WK-JSON-string"
            guard let json = receipt as? String else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Actual pen bridge did not return its JSON-string receipt (type=\(resultType))"])
            }
            jsonByteCount = json.utf8.count
            guard json.utf8.count <= 65_536 else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "Actual pen bridge receipt exceeded its bounded transport"])
            }
            // Persist immediately, before JSON decoding, counter assertions,
            // another stroke, save or release can fail and erase this evidence.
            let receiptURL = root.appendingPathComponent("stroke-\(index + 1)-receipt.json")
            try Data(json.utf8).write(to: receiptURL, options: .atomic)
            attach(receiptURL, name: "stroke-\(index + 1)-actual-WK-receipt")
            guard let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 6,
                    userInfo: [NSLocalizedDescriptionKey: "Actual pen bridge receipt was not a JSON object"])
            }
            stage = "validate-actual-pen-receipt"
            guard (decoded["strokeDelta"] as? Int) == 1,
                  (decoded["coreEventDelta"] as? Int ?? 0) >= 5,
                  (decoded["activeAfter"] as? Bool) == false else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Actual pen bridge receipt did not confirm one complete forwarded stroke"])
            }
            return decoded
        } catch {
            await retainStrokeFailure(index, stage: stage, resultType: resultType, jsonByteCount: jsonByteCount,
                                      error: error, web: web, native: native, window: window, root: root, syntheticSource: syntheticSource)
            throw error
        }
    }

    /// Dedicated zero-motion seam. It only calls the real production bridge
    /// with a bounded JSON receipt; all acceptance facts stay on the page and
    /// no assertion is inferred from the preview.
    /// `paintReceipt`/`candidateOffset`/`cancelWithPointerCancel`/
    /// `movingSteps` extend the seam only when explicitly requested; the
    /// frozen opaque callers pass none, which keeps the original v1 argument
    /// set, script behavior and receipt file names unchanged. `movingSteps`
    /// (only honored together with `cancelWithPointerCancel`) turns the
    /// second contact into a genuine moving sequence — pointerdown, that many
    /// real pointermove events, then pointercancel — for the moving
    /// true-cancel exercise.
    private func receiveZeroMotionDot(web: WKWebView, native: FloeOfficeNativeViewController,
                                      window: UIWindow, root: URL,
                                      syntheticSource: URL,
                                      paintReceipt: Bool = false,
                                      candidateOffset: Int = 0,
                                      cancelWithPointerCancel: Bool = false,
                                      movingSteps: Int = 0,
                                      receiptName: String = "zero-motion-dot") async throws -> [String: Any] {
        var arguments: [String: Any] = [:]
        if paintReceipt { arguments["paintReceipt"] = true }
        if candidateOffset > 0 { arguments["candidateOffset"] = candidateOffset }
        if cancelWithPointerCancel { arguments["cancelWithPointerCancel"] = true }
        if movingSteps > 0 { arguments["movingSteps"] = movingSteps }
        var resultType = "not-returned"
        var jsonByteCount: Int?
        var stage = "call-zero-motion-pen-bridge"
        do {
            let receipt: Any? = try await web.callAsyncJavaScript(Self.zeroMotionDotScript,
                arguments: arguments, in: nil, contentWorld: .page)
            resultType = receipt.map { String(reflecting: type(of: $0)) } ?? "nil"
            stage = "decode-zero-motion-WK-JSON-string"
            guard let json = receipt as? String else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 70,
                    userInfo: [NSLocalizedDescriptionKey: "Zero-motion pen bridge did not return its JSON-string receipt (type=\(resultType))"])
            }
            jsonByteCount = json.utf8.count
            guard json.utf8.count <= 65_536 else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 71,
                    userInfo: [NSLocalizedDescriptionKey: "Zero-motion receipt exceeded its bounded transport"])
            }
            let receiptURL = root.appendingPathComponent("\(receiptName)-receipt.json")
            try Data(json.utf8).write(to: receiptURL, options: .atomic)
            attach(receiptURL, name: "\(receiptName)-actual-WK-receipt")
            guard let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 72,
                    userInfo: [NSLocalizedDescriptionKey: "Zero-motion receipt was not a JSON object"])
            }
            return decoded
        } catch {
            let nsError = error as NSError
            let facts: [String: Any] = ["stage": stage, "WKResultType": resultType,
                "receiptJSONBytes": jsonByteCount ?? -1, "errorDomain": nsError.domain,
                "errorCode": nsError.code]
            let url = root.appendingPathComponent("\(receiptName)-transport-failure.json")
            if let bytes = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: url, options: .atomic)
                attach(url, name: "\(receiptName)-transport-failure")
            }
            await retainStrokeFailure(1, stage: "zero-motion-dot", resultType: resultType,
                                      jsonByteCount: jsonByteCount, error: error, web: web, native: native,
                                      window: window, root: root, syntheticSource: syntheticSource)
            throw error
        }
    }

    /// Re-derive the visible document rectangle in a fresh reopened session so
    /// the original dot fraction maps to the current engine page pixels.
    private func zeroMotionRenderProbe(_ web: WKWebView) async throws -> [String: Any] {
        let receipt = try await web.callAsyncJavaScript(Self.zeroMotionRenderProbeScript,
            arguments: [:], in: nil, contentWorld: .page)
        guard let json = receipt as? String, json.utf8.count <= 16_384,
              let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NSError(domain: "OfficeNativeDrawingQualification", code: 73, userInfo: [
                NSLocalizedDescriptionKey: "Reopened page geometry probe was not a bounded JSON object"
            ])
        }
        return value
    }

    /// Count blue dot pixels in the expected region and compare the reopened
    /// control-only and control+dot engine pages at the same region. A saved
    /// shape whose zero-area geometry renders nothing cannot pass.
    private func dotRenderFacts(control: UIImage, final: UIImage, point: CGPoint,
                                viewport: CGSize, radiusCSS: CGFloat = 26) -> [String: Any] {
        guard let controlCG = control.cgImage, let finalCG = final.cgImage,
              controlCG.width == finalCG.width, controlCG.height == finalCG.height,
              viewport.width > 1, viewport.height > 1,
              let controlBytes = rgbaBytes(controlCG), let finalBytes = rgbaBytes(finalCG) else {
            return ["available": false, "reason": "image-or-bitmap-unavailable"]
        }
        let width = controlCG.width, height = controlCG.height
        let scaleX = CGFloat(width) / viewport.width
        let scaleY = CGFloat(height) / viewport.height
        let centerX = point.x * scaleX, centerY = point.y * scaleY
        let radius = radiusCSS * max(scaleX, scaleY)
        let left = max(0, Int((centerX - radius).rounded(.down)))
        let right = min(width - 1, Int((centerX + radius).rounded(.up)))
        let top = max(0, Int((centerY - radius).rounded(.down)))
        let bottom = min(height - 1, Int((centerY + radius).rounded(.up)))
        guard left <= right, top <= bottom else {
            return ["available": false, "reason": "dot-region-outside-image"]
        }
        var blueCrop = 0, blueWhole = 0, changedCrop = 0, changedWhole = 0
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let r0 = Int(controlBytes[offset]), g0 = Int(controlBytes[offset + 1])
                let b0 = Int(controlBytes[offset + 2])
                let r1 = Int(finalBytes[offset]), g1 = Int(finalBytes[offset + 1])
                let b1 = Int(finalBytes[offset + 2])
                let inCrop = x >= left && x <= right && y >= top && y <= bottom
                if b1 > 110 && b1 > r1 + 35 && b1 > g1 + 35 {
                    blueWhole += 1
                    if inCrop { blueCrop += 1 }
                }
                if max(abs(r1 - r0), max(abs(g1 - g0), abs(b1 - b0))) > 24 {
                    changedWhole += 1
                    if inCrop {
                        changedCrop += 1
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
        }
        return [
            "available": true, "imagePixels": [width, height],
            "pixelScale": [Double(scaleX), Double(scaleY)],
            "dotPixelPoint": [Double(centerX), Double(centerY)],
            "cropPixels": [left, top, right, bottom],
            "bluePixelsInCrop": blueCrop, "bluePixelsWhole": blueWhole,
            "changedPixelsInCrop": changedCrop, "changedPixelsWhole": changedWhole,
            "changedBBox": changedCrop > 0 ? [minX, minY, maxX, maxY] : []
        ]
    }

    /// Anchor the reopened dot expectation in document content. The dot
    /// original contact region is checked against the pre-save render, then
    /// mapped by the scale and centroid shift of the shared positive-control
    /// red stroke between the pre-save and reopened control-only pages, then
    /// cross-checked against the reopened final image. Returns a viewport-space
    /// point plus diagnostics; availability is false when the inputs cannot
    /// support a registration, which the caller must treat as a failure.
    private func registeredDotCenter(preSave: UIImage?, originalClientPoint: CGPoint?,
                                     controlReopened: UIImage?, finalReopened: UIImage?,
                                     viewport: CGSize) -> (point: CGPoint, diagnostics: [String: Any]) {
        let off = (point: CGPoint.zero, diagnostics: ["available": false, "reason": "images-unavailable"] as [String: Any])
        guard let preSave, let originalClientPoint, let controlReopened, let finalReopened,
              let preCG = preSave.cgImage, let ctrlCG = controlReopened.cgImage,
              let finCG = finalReopened.cgImage,
              preCG.width == ctrlCG.width, preCG.height == ctrlCG.height,
              finCG.width == preCG.width, finCG.height == preCG.height,
              viewport.width > 1, viewport.height > 1,
              let preBytes = rgbaBytes(preCG), let ctrlBytes = rgbaBytes(ctrlCG),
              let finBytes = rgbaBytes(finCG) else { return off }
        let width = preCG.width, height = preCG.height
        let scaleX = CGFloat(width) / viewport.width, scaleY = CGFloat(height) / viewport.height
        let original = CGPoint(x: originalClientPoint.x * scaleX, y: originalClientPoint.y * scaleY)
        // Use the existing 26 CSS-pixel input region. Blue controls elsewhere
        // in the editor are not document ink and cannot become the anchor.
        let radius = 26 * max(scaleX, scaleY)
        typealias Blob = (center: CGPoint, count: Int, spanX: CGFloat)
        func blob(_ bytes: [UInt8], around: CGPoint? = nil,
                  _ test: (Int, Int, Int) -> Bool) -> Blob {
            var seen = [Bool](repeating: false, count: width * height)
            var best: [Int] = []
            func matches(_ x: Int, _ y: Int) -> Bool {
                if let around, (abs(CGFloat(x) - around.x) > radius || abs(CGFloat(y) - around.y) > radius) { return false }
                let o = (y * width + x) * 4
                return test(Int(bytes[o]), Int(bytes[o+1]), Int(bytes[o+2]))
            }
            for y in 0..<height { for x in 0..<width {
                let idx = y * width + x
                if seen[idx] { continue }
                seen[idx] = true
                guard matches(x, y) else { continue }
                var stack = [idx]; var pts: [Int] = []
                while let c = stack.popLast() {
                    pts.append(c)
                    let cx = c % width, cy = c / width
                    for (nx, ny) in [(cx+1, cy), (cx-1, cy), (cx, cy+1), (cx, cy-1)] {
                        if nx >= 0, nx < width, ny >= 0, ny < height {
                            let j = ny * width + nx
                            if !seen[j] {
                                seen[j] = true
                                if matches(nx, ny) { stack.append(j) }
                            }
                        }
                    }
                }
                if pts.count > best.count { best = pts }
            } }
            guard !best.isEmpty else { return (.zero, 0, 0) }
            let xs = best.map { $0 % width }
            let cx = Double(xs.reduce(0, +)) / Double(best.count)
            let cy = Double(best.reduce(0) { $0 + $1 / width }) / Double(best.count)
            return (CGPoint(x: cx, y: cy), best.count, CGFloat((xs.max() ?? 0) - (xs.min() ?? 0)))
        }
        let isBlue: (Int, Int, Int) -> Bool = { r, g, b in b > 110 && b > r + 35 && b > g + 35 }
        let isRed: (Int, Int, Int) -> Bool = { r, g, b in r > 110 && r > g + 35 && r > b + 35 }
        let dotPre = blob(preBytes, around: original, isBlue)
        let strokePre = blob(preBytes, isRed)
        let strokeCtrl = blob(ctrlBytes, isRed)
        var diag: [String: Any] = ["available": false,
            "originalInputImageCenter": [original.x, original.y],
            "dotPre": [dotPre.center.x, dotPre.center.y], "dotPrePixels": dotPre.count,
            "strokePre": [strokePre.center.x, strokePre.center.y], "strokePrePixels": strokePre.count,
            "strokeCtrl": [strokeCtrl.center.x, strokeCtrl.center.y], "strokeCtrlPixels": strokeCtrl.count]
        guard dotPre.count >= 12, strokePre.count >= 200, strokeCtrl.count >= 200,
              strokePre.spanX > 100, strokeCtrl.spanX > 100 else {
            diag["reason"] = "registration-blobs-insufficient"; return (.zero, diag)
        }
        // The SAME saved positive-control path independently measures the
        // reopened document's scale and translation. Writer can fit the page
        // to a different zoom on reopen; one viewport fraction is insufficient.
        let zoom = strokeCtrl.spanX / strokePre.spanX
        guard zoom.isFinite, zoom > 0 else { return (.zero, diag) }
        let expected = CGPoint(x: strokeCtrl.center.x + (dotPre.center.x - strokePre.center.x) * zoom,
                               y: strokeCtrl.center.y + (dotPre.center.y - strokePre.center.y) * zoom)
        let dotFin = blob(finBytes, around: expected, isBlue)
        diag["contentScale"] = zoom
        diag["expectedImageCenter"] = [expected.x, expected.y]
        diag["dotFin"] = [dotFin.center.x, dotFin.center.y]; diag["dotFinPixels"] = dotFin.count
        guard dotFin.count >= 12 else { diag["reason"] = "reopened-dot-missing"; return (.zero, diag) }
        diag["residualImagePx"] = hypot(dotFin.center.x - expected.x, dotFin.center.y - expected.y)
        diag["available"] = true
        return (CGPoint(x: expected.x / scaleX, y: expected.y / scaleY), diag)
    }

    private func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let flags = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: flags) else {
                return false
            }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? bytes : nil
    }

    /// Decode the exact client coordinates that were dispatched, so the next
    /// overlap contact can be derived from the real previous contact rather
    /// than from a second, potentially divergent geometry calculation.
    private func clientPoints(_ receipt: [String: Any], index: Int) throws -> [[Double]] {
        guard let raw = receipt["clientPoints"] as? [[Any]], raw.count >= 4 else {
            throw NSError(domain: "OfficeNativeDrawingQualification", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "Stroke \(index + 1) did not return its actual client points"
            ])
        }
        return try raw.map { pair in
            guard pair.count == 2,
                  let x = (pair[0] as? NSNumber)?.doubleValue,
                  let y = (pair[1] as? NSNumber)?.doubleValue,
                  x.isFinite, y.isFinite else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 32, userInfo: [
                    NSLocalizedDescriptionKey: "Stroke \(index + 1) returned an invalid client point"
                ])
            }
            return [x, y]
        }
    }

    /// Assert that the stimulus actually recorded a real DOM route. No
    /// assertion requires a selection overlay to be hit: a canvas target is
    /// recorded just as honestly as an overlay target.
    private func validateHitDiagnostics(_ receipt: [String: Any], stimulus: StrokeStimulus) throws {
        guard let hit = receipt["hitDiagnostics"] as? [String: Any],
              let contacts = hit["contacts"] as? [[String: Any]],
              let overlayBefore = hit["overlayCensusBefore"] as? [String: Any],
              let overlayAfter = hit["overlayCensusAfter"] as? [String: Any] else {
            throw NSError(domain: "OfficeNativeDrawingQualification", code: 33, userInfo: [
                NSLocalizedDescriptionKey: "Bounded pen hit diagnostics were missing for stroke \(stimulus.index + 1)"
            ])
        }
        XCTAssertEqual(hit["stimulusMode"] as? String, stimulus.kind.rawValue)
        XCTAssertEqual(hit["gapMilliseconds"] as? Int, stimulus.gapMilliseconds)
        XCTAssertEqual(contacts.count, 5, "One down, three moves and one up are required")
        XCTAssertEqual(overlayBefore["canvasContainerFound"] as? Bool, true,
                       "The real canvas container must be inspectable")
        XCTAssertNotNil(overlayAfter["selection"] as? [String: Any],
                        "Selection state must be recorded, even when no selection exists")
        XCTAssertEqual(hit["clampedContacts"] as? Int, 0,
                       "Stimulus points must stay inside the visible document without clamping")
        // A previous core selection can leave a frontend shape-handle section
        // above the document in the real CanvasSection hit test. The production
        // Pencil replay must clear that local handle section before the down
        // and restore it afterwards; the core selection itself is untouched.
        if let selectionBefore = hit["shapeSelectionBeforeDown"] as? [String: Any],
           (selectionBefore["shown"] as? Bool == true
            || (selectionBefore["shownChildCount"] as? Int ?? 0) > 0) {
            let selectionAtDown = hit["shapeSelectionAtDown"] as? [String: Any]
            XCTAssertEqual(selectionAtDown?["shown"] as? Bool, false,
                           "A shown shape-handle section must be hidden for the replayed Pencil down")
            XCTAssertEqual(selectionAtDown?["shownChildCount"] as? Int, 0,
                           "Every independent shape-handle child must be hidden for the replayed Pencil down")
            XCTAssertEqual((hit["shapeHandleSuspensionsAtDown"] as? Int ?? 0)
                           - (hit["shapeHandleSuspensionsBeforeDown"] as? Int ?? 0), 1,
                           "The Pencil down must record exactly one frontend stale-handle suspension (not a core save ACK)")
        }
        // Direct root-cause gate: re-run the same pinned container hit test
        // after the down. A stale shape-handle-* child or the parent
        // shapeHandlesSection must not remain the winner. Overlay and
        // selection-rectangle sections are valid when their normal bounds
        // propagate the mousedown to the document (MouseControl); do not
        // hardcode mouse-control as the only acceptable name. The receipt
        // counters above are DOM replay counters, never a core save ACK; the
        // saved 10-path/exact 3-4-3 OOXML assertions in exercise() are the
        // core proof and reject a lost stroke. Never delete or force-miss the
        // sampled point.
        let hitBefore = hit["canvasHitSectionBeforeDown"] as? String
        let hitAtDown = hit["canvasHitSectionAtDown"] as? String
        let handleAtDown = hit["shapeHandleAtDown"] as? Bool
        XCTAssertNotNil(hitBefore, "The pre-down CanvasSection hit must be recorded")
        XCTAssertNotNil(hitAtDown, "The post-down hit test must resolve a real document section")
        XCTAssertEqual(handleAtDown, false,
                       "The Pencil down must not resolve to a shape-handle-* or shapeHandlesSection; before=\(hitBefore ?? "nil") after=\(hitAtDown ?? "nil")")
        if (hit["shapeHandleBeforeDown"] as? Bool) == true {
            XCTAssertEqual(handleAtDown, false,
                           "The stale shape handle present before the down must be cleared before replay")
        }
        if let boundNames = hit["canvasSectionAtDownBoundNames"] as? [String],
           let parentName = hit["shapeHandlesName"] as? String {
            XCTAssertFalse(boundNames.contains { $0 == parentName || $0.hasPrefix("shape-handle-") },
                           "The routed section's boundsList must not propagate the Pencil down to a shape handle: \(boundNames)")
        }
        let owners = contacts.compactMap {
            ($0["observedHitTarget"] as? [String: Any])?["ownership"] as? String
        }
        XCTAssertEqual(owners.count, contacts.count, "Every contact must record its actual DOM ownership")
        let knownOwners: Set<String> = ["canvas", "canvas-descendant", "canvas-container-overlay",
                                        "document-body", "outside-canvas-container", "detached", "unresolved"]
        XCTAssertTrue(owners.allSatisfy { knownOwners.contains($0) },
                      "Hit ownership must be one of the bounded categories: \(owners)")
        let routed = contacts.compactMap { $0["routedBy"] as? String }
        XCTAssertEqual(routed.count, contacts.count, "Every contact must record its dispatch route")
        if stimulus.kind == .overlap {
            XCTAssertEqual(hit["hitTested"] as? Bool, true)
            XCTAssertEqual(hit["previousStrokeID"] as? Int, stimulus.previousIndex ?? -1)
            XCTAssertEqual((hit["previousStrokeProbe"] as? [Any])?.count ?? -1, 4,
                           "The previous contact's four points must be probed before dispatch")
            XCTAssertTrue(routed.allSatisfy { $0 == "elementFromPoint" },
                          "Overlap contacts must dispatch at the real elementFromPoint result, not canvas: \(routed)")
            for contact in contacts {
                guard let observed = contact["observedHitTarget"] as? [String: Any],
                      let dispatched = contact["dispatchTarget"] as? [String: Any] else {
                    XCTFail("An overlap contact did not record both observed and dispatched targets")
                    continue
                }
                XCTAssertEqual(observed["tag"] as? String, dispatched["tag"] as? String,
                               "Overlap dispatch must use the observed DOM element, not a substitute")
                XCTAssertEqual(observed["ownership"] as? String, dispatched["ownership"] as? String)
                XCTAssertEqual(observed["insideCanvas"] as? Bool, dispatched["insideCanvas"] as? Bool)
            }
        } else {
            XCTAssertEqual(hit["hitTested"] as? Bool, false)
            XCTAssertTrue(routed.allSatisfy { $0 == "canvas-direct" },
                          "Band contacts must preserve the original canvas-direct dispatch")
            XCTAssertEqual((hit["previousStrokeProbe"] as? [Any])?.count ?? -1, 0)
            for contact in contacts {
                guard contact["dispatchTarget"] is [String: Any],
                      contact["observedHitTarget"] is [String: Any] else {
                    XCTFail("A band contact did not record observed and dispatched target facts")
                    continue
                }
                XCTAssertEqual((contact["dispatchTarget"] as? [String: Any])?["ownership"] as? String ?? "MISSING",
                               "canvas")
            }
        }
    }

    private func retainStrokeFailure(_ index: Int, stage: String, resultType: String,
                                     jsonByteCount: Int?, error: Error, web: WKWebView,
                                     native: FloeOfficeNativeViewController, window: UIWindow, root: URL,
                                     syntheticSource: URL) async {
        let prefix = "stroke-\(index + 1)-failure"
        let nsError = error as NSError
        var facts: [String: Any] = ["strokeIndex": index, "stage": stage, "WKResultType": resultType,
            "errorDomain": nsError.domain, "errorCode": nsError.code,
            "nativeRenderDiagnostics": OfficeFileSession.hostRenderDiagnostics(native),
            "hardwarePointerInput": "not-tested", "saveAndVectorVerification": "not-completed"]
        if let jsonByteCount { facts["receiptJSONBytes"] = jsonByteCount }
        // Allowlisted counters/layout only. No URL/path, page title, document
        // text, form values, clipboard, chat messages, credentials or cache edits.
        do {
            let observed = try await web.callAsyncJavaScript(Self.strokeFailureObservationScript,
                arguments: [:], in: nil, contentWorld: .page)
            if let json = observed as? String, json.utf8.count <= 16_384,
               let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                facts["actualPageAndPenState"] = value
            } else { facts["observationTransport"] = "missing-or-invalid-JSON-string" }
        } catch {
            facts["observationErrorDomain"] = (error as NSError).domain
            facts["observationErrorCode"] = (error as NSError).code
        }
        // Public read-only host URL, belonging to this exact synthetic test
        // session. Copy only persisted bytes; do not force a save, mutate or
        // scan recovery folders, and do not imply this captures unsaved core RAM.
        let working = native.workingFileURL
        if syntheticSource.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
           syntheticSource.lastPathComponent == "original." + working.pathExtension,
           ["docx", "xlsx", "pptx"].contains(working.pathExtension), working.isFileURL {
            do {
                let size = try working.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 16 * 1_024 * 1_024 else { throw CocoaError(.fileReadTooLarge) }
                let bytes = try Data(contentsOf: working)
                let copy = root.appendingPathComponent(prefix + "-working-copy." + working.pathExtension)
                try bytes.write(to: copy, options: .atomic)
                attach(copy, name: prefix + "-owned-synthetic-working-copy")
                facts["persistedWorkingCopyBytes"] = bytes.count
                facts["persistedWorkingCopySHA256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                facts["workingCopyInterpretation"] = "last-persisted-engine-bytes; no forced save; unsaved core edits may be absent"
            } catch {
                facts["workingCopyCaptureErrorDomain"] = (error as NSError).domain
                facts["workingCopyCaptureErrorCode"] = (error as NSError).code
            }
        } else { facts["workingCopyCapture"] = "not-owned-synthetic-session" }
        // Retain diagnostics before snapshots: a crashed/unresponsive renderer
        // may refuse its image, but must not lose the original failure facts.
        let diagnosticURL = root.appendingPathComponent(prefix + ".json")
        if let bytes = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]),
           (try? bytes.write(to: diagnosticURL, options: .atomic)) != nil {
            attach(diagnosticURL, name: prefix + "-actual-state")
        }
        do {
            let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = true
            let image = try await web.takeSnapshot(configuration: configuration)
            guard let png = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            let surface = root.appendingPathComponent(prefix + "-surface.png")
            try png.write(to: surface); attach(surface, name: prefix + "-actual-surface")
        } catch {
            let snapshotFailure = root.appendingPathComponent(prefix + "-snapshot-unavailable.txt")
            let message = "Actual WK snapshot unavailable; domain=\((error as NSError).domain) code=\((error as NSError).code)"
            if (try? Data(message.utf8).write(to: snapshotFailure)) != nil { attach(snapshotFailure, name: prefix + "-snapshot-unavailable") }
        }
        // This UIWindow contains only this test's synthetic Office surface;
        // do not use screen-wide capture that could include a background chat.
        let whole = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let png = whole.pngData() {
            let wholeURL = root.appendingPathComponent(prefix + "-window.png")
            if (try? png.write(to: wholeURL)) != nil { attach(wholeURL, name: prefix + "-actual-window") }
        }
    }

    private func visibleDocumentRect(_ receipt: [String: Any]) throws -> [String: Double] {
        guard let raw = receipt["visibleDocumentRect"] as? [String: Any] else {
            throw NSError(domain: "OfficeNativeDrawingQualification", code: 62, userInfo: [
                NSLocalizedDescriptionKey: "The first actual contact did not record its visible document rectangle"
            ])
        }
        var result: [String: Double] = [:]
        for key in ["x1", "y1", "x2", "y2"] {
            guard let value = (raw[key] as? NSNumber)?.doubleValue, value.isFinite else {
                throw NSError(domain: "OfficeNativeDrawingQualification", code: 63, userInfo: [
                    NSLocalizedDescriptionKey: "The visible document rectangle has no finite \(key)"
                ])
            }
            result[key] = value
        }
        guard (result["x1"] ?? 0) < (result["x2"] ?? 0), (result["y1"] ?? 0) < (result["y2"] ?? 0) else {
            throw NSError(domain: "OfficeNativeDrawingQualification", code: 64, userInfo: [
                NSLocalizedDescriptionKey: "The visible document rectangle is empty"
            ])
        }
        return result
    }

    private func decodePageReceipt(_ value: Any?, limit: Int, stage: String) throws -> [String: Any] {
        guard let json = value as? String else {
            throw NSError(domain: "OfficeNativeDrawingQualification", code: 65, userInfo: [
                NSLocalizedDescriptionKey: "The \(stage) page bridge did not return a JSON string"
            ])
        }
        guard json.utf8.count <= limit else {
            throw NSError(domain: "OfficeNativeDrawingQualification", code: 66, userInfo: [
                NSLocalizedDescriptionKey: "The \(stage) page receipt exceeded its bounded transport"
            ])
        }
        guard let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NSError(domain: "OfficeNativeDrawingQualification", code: 67, userInfo: [
                NSLocalizedDescriptionKey: "The \(stage) page receipt was not a JSON object"
            ])
        }
        return decoded
    }

    private static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Persist bounded page and surface facts after a real API/capture failure.
    /// No page text, path, title, form value or arbitrary message is retained:
    /// the page observation only reports counters, booleans and allowlisted
    /// names, and the qualification failure objects keep their own bounds.
    private func retainStaleHandleFailure(web: WKWebView,
                                          native: FloeOfficeNativeViewController?,
                                          window: UIWindow, root: URL,
                                          stage: String, error: Error) async {
        let nsError = error as NSError
        var facts: [String: Any] = ["stage": stage, "errorDomain": nsError.domain,
            "errorCode": nsError.code, "hardwarePointerInput": "not-tested",
            "saveAndVectorVerification": "not-completed"]
        if let native {
            facts["nativeRenderDiagnostics"] = OfficeFileSession.hostRenderDiagnostics(native)
        }
        do {
            let observed = try await web.callAsyncJavaScript(Self.staleHandleFailureObservationScript,
                arguments: [:], in: nil, contentWorld: .page)
            if let json = observed as? String, json.utf8.count <= 65_536,
               let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                facts["actualPageState"] = value
            } else {
                facts["observationTransport"] = "missing-or-invalid-JSON-string"
            }
        } catch {
            facts["observationErrorDomain"] = (error as NSError).domain
            facts["observationErrorCode"] = (error as NSError).code
        }
        let diagnosticURL = root.appendingPathComponent(stage + "-failure.json")
        if let bytes = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]),
           (try? bytes.write(to: diagnosticURL, options: .atomic)) != nil {
            attach(diagnosticURL, name: stage + "-actual-state")
        }
        do {
            let configuration = WKSnapshotConfiguration(); configuration.afterScreenUpdates = true
            let image = try await web.takeSnapshot(configuration: configuration)
            guard let png = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
            let surface = root.appendingPathComponent(stage + "-surface.png")
            try png.write(to: surface)
            attach(surface, name: stage + "-actual-surface")
        } catch {
            let message = "Actual WK snapshot unavailable; domain=\((error as NSError).domain) code=\((error as NSError).code)"
            let snapshotFailure = root.appendingPathComponent(stage + "-snapshot-unavailable.txt")
            if (try? Data(message.utf8).write(to: snapshotFailure)) != nil {
                attach(snapshotFailure, name: stage + "-snapshot-unavailable")
            }
        }
        let whole = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        if let png = whole.pngData() {
            let wholeURL = root.appendingPathComponent(stage + "-window.png")
            if (try? png.write(to: wholeURL)) != nil {
                attach(wholeURL, name: stage + "-actual-window")
            }
        }
    }

    private static let staleHandleFailureObservationScript = #"""
    const app = window.app;
    const selection = app && app.definitions && app.definitions.graphicSelection;
    const container = app && app.sectionContainer;
    const canvas = container && container.canvas;
    const section = selection && selection.handlesSection;
    const properties = section && section.sectionProperties ? section.sectionProperties : {};
    const subSections = Array.isArray(properties.subSections) ? properties.subSections : [];
    const finite = value => typeof value === 'number' && Number.isFinite(value) ? value : null;
    const bounded = (value, limit) => typeof value === 'string'
        ? (value.length > limit ? value.slice(0, limit) : value) : null;
    const targetFacts = () => {
        if (!canvas) return null;
        const rect = canvas.getBoundingClientRect();
        return {x:finite(rect.x), y:finite(rect.y), width:finite(rect.width), height:finite(rect.height),
            widthPixels:finite(canvas.width), heightPixels:finite(canvas.height)};
    };
    const pen = typeof window.__floeOfficePenState === 'function' ? window.__floeOfficePenState() : null;
    const state = selection && typeof selection.hasActiveSelection === 'function' ? {
        hasActiveSelection: selection.hasActiveSelection() === true,
        handlesFound: !!(section && container && typeof container.getSectionWithName === 'function'
            && container.getSectionWithName(section.name) === section),
        shown: section ? section.showSection === true : false,
        subSectionCount: subSections.length,
        shownChildCount: subSections.filter(sub => sub && sub.showSection === true).length,
        sectionName: section ? bounded(section.name, 64) : null
    } : null;
    const selectionFailure = window.__floeStaleHandleSelectionFailure || null;
    const replayFailure = window.__floeStaleHandleReplayFailure || null;
    delete window.__floeStaleHandleSelectionFailure;
    delete window.__floeStaleHandleReplayFailure;
    return JSON.stringify({selection:state, canvas:targetFacts(),
        targetSection:container && typeof container.targetSection === 'string'
            ? bounded(container.targetSection, 64) : null,
        docType:app && app.map && app.map._docLayer && typeof app.map._docLayer._docType === 'string'
            ? bounded(app.map._docLayer._docType, 32) : null,
        editable:!!(app && app.map && typeof app.map.isEditMode === 'function' && app.map.isEditMode()),
        pen:pen ? {drawing:pen.drawing === true, strokes:finite(pen.strokes),
            coreEvents:finite(pen.coreEvents), activeStroke:pen.activeStroke === true,
            shapeHandleSuspensions:finite(pen.shapeHandleSuspensions),
            error:typeof pen.error === 'string' ? bounded(pen.error, 64) : null} : null,
        selectionFailure, replayFailure});
    """#

    private static let strokeFailureObservationScript = #"""
    const finite = value => typeof value === 'number' && Number.isFinite(value) ? value : null;
    const map = window.app && window.app.map;
    const canvas = window.app && window.app.sectionContainer && window.app.sectionContainer.canvas;
    const rect = canvas && canvas.getBoundingClientRect();
    const pen = typeof window.__floeOfficePenState === 'function' ? window.__floeOfficePenState() : null;
    const hit = window.__floePenHitQualification;
    return JSON.stringify({socketObservation:window.__floePenSocketQualification || null,
        hitQualification:hit && typeof hit === 'object' ? hit : null,
        readyState:document.readyState, visibility:document.visibilityState,
        hasApp:!!window.app, hasMap:!!map, hasPenBridge:typeof window.__floeOfficePenState === 'function',
        docType:map && typeof map.getDocType === 'function' ? String(map.getDocType()).slice(0,32) : null,
        selectedPart:finite(map && map._docLayer && map._docLayer._selectedPart),
        editable:!!(map && typeof map.isEditMode === 'function' && map.isEditMode()),
        viewport:{width:finite(window.innerWidth),height:finite(window.innerHeight),scale:finite(window.devicePixelRatio)},
        canvas:rect ? {x:finite(rect.x),y:finite(rect.y),width:finite(rect.width),height:finite(rect.height)} : null,
        pen:pen ? {drawing:pen.drawing === true,strokes:finite(pen.strokes),coreEvents:finite(pen.coreEvents),
            armedDispatches:finite(pen.armedDispatches),activeStroke:pen.activeStroke === true,
            shapeHandleSuspensions:finite(pen.shapeHandleSuspensions),
            error:typeof pen.error === 'string' ? pen.error.slice(0,64) : null,
            toolState:typeof pen.toolState === 'string' ? pen.toolState.slice(0,64) : null} : null});
    """#

    private static let strokeScript = #"""
    const app = window.app;
    const container = app && app.sectionContainer;
    const canvas = container && container.canvas;
    const layout = app && app.activeDocument && app.activeDocument.activeLayout;
    const size = app && app.activeDocument && app.activeDocument.fileSize;
    if (!canvas || !layout || !size || typeof window.PointerEvent !== 'function'
        || typeof window.__floeOfficePenState !== 'function')
        throw new Error('production pen bridge or native document canvas unavailable');
    const before = window.__floeOfficePenState();
    if (!before.drawing || before.activeStroke) throw new Error('App pen mode not armed or previous stroke active');
    const rect = canvas.getBoundingClientRect();
    const section = container.getDocumentAnchorSection();
    const scaleX = rect.width / canvas.width, scaleY = rect.height / canvas.height;
    if (!section || !section.myTopLeft || !section.size || !Number.isFinite(scaleX) || !Number.isFinite(scaleY))
        throw new Error('actual document viewport geometry unavailable');
    // Transform actual document corners through the existing renderer layout,
    // then intersect with its document section and visible CSS canvas. Never
    // mistake twips, device pixels or a fixed screen point for client coords.
    const origin = size.clone(); origin.pX = 0; origin.pY = 0;
    const end = size.clone();
    const dx1 = layout.documentToViewX(origin), dy1 = layout.documentToViewY(origin);
    const dx2 = layout.documentToViewX(end), dy2 = layout.documentToViewY(end);
    const x1 = rect.left + Math.max(0, section.myTopLeft[0], Math.min(dx1, dx2)) * scaleX;
    const y1 = rect.top + Math.max(0, section.myTopLeft[1], Math.min(dy1, dy2)) * scaleY;
    const x2 = rect.left + Math.min(canvas.width, section.myTopLeft[0] + section.size[0], Math.max(dx1, dx2)) * scaleX;
    const y2 = rect.top + Math.min(canvas.height, section.myTopLeft[1] + section.size[1], Math.max(dy1, dy2)) * scaleY;
    if (![x1, y1, x2, y2].every(Number.isFinite) || x2 - x1 < 120 || y2 - y1 < 120)
        throw new Error('no safely visible document drawing area');
    // Small reusable stimulus helpers. Band contacts keep the original
    // canvas-direct dispatch; overlap contacts resolve the actual DOM element
    // at every contact point and dispatch the real synthetic PointerEvent
    // there. No overlay element is created or simulated.
    const canvasContainer = (() => {
        const byId = document.getElementById('canvas-container');
        if (byId && byId.contains(canvas)) return byId;
        return canvas.parentElement || null;
    })();
    const bounded = (value, limit) =>
        typeof value === 'string' ? (value.length > limit ? value.slice(0, limit) : value) : null;
    const round2 = (value) => Math.round(value * 100) / 100;
    const classOf = (element) => {
        if (!element || typeof element.getAttribute !== 'function') return null;
        return bounded(element.getAttribute('class'), 96);
    };
    const ownerOf = (element) => {
        if (!element) return 'unresolved';
        if (element === canvas) return 'canvas';
        if (canvas.contains(element)) return 'canvas-descendant';
        if (canvasContainer && canvasContainer.contains(element)) return 'canvas-container-overlay';
        if (element === document.body) return 'document-body';
        if (document.documentElement && document.documentElement.contains(element))
            return 'outside-canvas-container';
        return 'detached';
    };
    const targetFacts = (element) => {
        if (!element) return {tag:null,id:null,class:null,ownership:'unresolved',
            insideCanvas:false,insideCanvasContainer:false,svgAncestor:null,connected:false};
        const svg = typeof element.closest === 'function' ? element.closest('svg') : null;
        return {
            tag: bounded(element.tagName ? String(element.tagName).toLowerCase() : null, 24),
            id: bounded(typeof element.id === 'string' ? element.id : null, 64),
            class: classOf(element),
            ownership: ownerOf(element),
            insideCanvas: canvas.contains(element),
            insideCanvasContainer: !!(canvasContainer && canvasContainer.contains(element)),
            svgAncestor: svg ? {tag:'svg', id:bounded(svg.id, 64), class:classOf(svg)} : null,
            connected: element.isConnected === true
        };
    };
    const countInContainer = (selector) => {
        if (!canvasContainer) return null;
        try { return Math.min(canvasContainer.querySelectorAll(selector).length, 64); }
        catch (_) { return null; }
    };
    const selectionState = () => {
        try {
            const definition = window.app && window.app.CSections && window.app.CSections.ShapeHandlesSection;
            const sectionContainer = window.app && window.app.sectionContainer;
            const section = definition && typeof definition.name === 'string' && sectionContainer
                && typeof sectionContainer.getSectionWithName === 'function'
                ? sectionContainer.getSectionWithName(definition.name) : null;
            if (!section) return {sectionFound:false};
            const properties = section.sectionProperties || {};
            const svg = properties.svg || null;
            const subSections = Array.isArray(properties.subSections) ? properties.subSections : [];
            return {
                sectionFound:true,
                sectionName: bounded(definition.name, 48),
                shown: section.showSection === true,
                subSectionCount: Array.isArray(properties.subSections)
                    ? Math.min(properties.subSections.length, 32) : null,
                shownChildCount: Math.min(subSections.filter((sub) =>
                    sub && sub.showSection === true).length, 32),
                previewSvgPresent: !!svg,
                previewSvgDisplay: svg ? bounded(String(svg.style.display || ''), 24) : null,
                previewSvgPointerEvents: svg ? bounded(String(svg.style.pointerEvents || ''), 24) : null
            };
        } catch (_) { return {sectionFound:false, inspectionFailed:true}; }
    };
    const overlayCensus = () => {
        try {
            return {
                canvasContainerFound: !!canvasContainer,
                canvasContainerId: canvasContainer ? bounded(canvasContainer.id, 64) : null,
                canvasContainerClass: canvasContainer ? classOf(canvasContainer) : null,
                containerChildCount: canvasContainer && canvasContainer.children
                    ? Math.min(canvasContainer.children.length, 64) : null,
                svgCount: countInContainer('svg'),
                handleClassCount: countInContainer('[class*="handle" i]'),
                selectionClassCount: countInContainer('[class*="selection" i]'),
                overlayClassCount: countInContainer('[class*="overlay" i]'),
                htmlObjectCount: countInContainer('.html-object-section'),
                selection: selectionState()
            };
        } catch (_) {
            return {canvasContainerFound: !!canvasContainer, inspectionFailed: true,
                selection: {sectionFound:false, inspectionFailed:true}};
        }
    };
    const elementAt = (point) => {
        try { return document.elementFromPoint(point[0], point[1]); }
        catch (_) { return null; }
    };
    // Successive overlap patterns are small fractions of the visible
    // document area. Each contact is derived from the previous contact, so
    // the paths genuinely overlap while still producing distinct geometry.
    const overlapOffsets = [
        [[ .0018, .0012], [ .0026,-.0014], [-.0012, .0022], [-.0022,-.0014]],
        [[-.0022, .0016], [ .0012, .0022], [ .0024,-.0016], [-.0010,-.0022]],
        [[ .0022,-.0016], [-.0026, .0012], [ .0016, .0024], [-.0012,-.0018]],
        [[-.0016,-.0022], [ .0022, .0016], [-.0024, .0010], [ .0016,-.0026]],
        [[ .0026, .0010], [-.0018,-.0024], [ .0010, .0026], [-.0026, .0016]]
    ];
    const mode = stimulusMode === 'overlap-hit-tested' ? 'overlap'
        : stimulusMode === 'band-canvas-direct' ? 'band' : null;
    if (!mode) throw new Error('unknown qualification stimulus mode');
    const gap = typeof gapMilliseconds === 'number' && Number.isFinite(gapMilliseconds)
        ? gapMilliseconds : null;
    const previous = Array.isArray(previousPoints) && previousPoints.length === 4
        ? previousPoints.map((point) => Array.isArray(point) && point.length === 2
            && point.every((value) => typeof value === 'number' && Number.isFinite(value))
            ? [point[0], point[1]] : null)
        : null;
    if (mode === 'overlap' && (!previous || previous.some((point) => !point)))
        throw new Error('previous client points required for the overlap stimulus');
    const bandPenPoints = () => {
        const y = .25 + strokeID * .045;
        const fractions = [[.28,y],[.37 + strokeID*.005,y-.02],
            [.47,y+.02+strokeID*.002],[.57+strokeID*.003,y]];
        return fractions.map(([x,y]) => [x1 + x * (x2-x1), y1 + y * (y2-y1)]);
    };
    const overlapScale = 1.5; // ~3 px max on a 744 px canvas: still overlapping, but safely distinct in OOXML.
    const overlapPenPoints = () => {
        const offsets = overlapOffsets[Math.max(0, strokeID - 5) % overlapOffsets.length];
        const dx = x2 - x1, dy = y2 - y1;
        return previous.map(([x,y], pointIndex) => {
            const offset = offsets[pointIndex] || [0,0];
            return [x + offset[0] * dx * overlapScale, y + offset[1] * dy * overlapScale];
        });
    };
    const clamp = (value, lower, upper) => Math.min(upper, Math.max(lower, value));
    const points = mode === 'overlap' ? overlapPenPoints() : bandPenPoints();
    const clampedContacts = points.map((point) => {
        const x = clamp(point[0], x1 + 1, x2 - 1);
        const y = clamp(point[1], y1 + 1, y2 - 1);
        const changed = x !== point[0] || y !== point[1];
        point[0] = x; point[1] = y;
        return changed;
    });
    if (points.length < 4) throw new Error('qualified stroke needs at least four contact points');
    const previousStrokeProbe = previous ? previous.map((point, pointIndex) => {
        const hit = elementAt(point);
        return {pointIndex, x:round2(point[0]), y:round2(point[1]), target:targetFacts(hit)};
    }) : [];
    const overlayBefore = overlayCensus();
    // BEGIN boundedSocketObservation — qualification-only, no payload retention.
    const observeSocket = (enabled, app) => {
        const facts = {enabled: enabled === true, limit: 32, events: [], budgetExceeded: false,
            hooks: {}, restored: false, socketReplaced: false};
        const socket = app && app.socket;
        const transport = socket && socket.socket;
        const classifyState = (value) => {
            if (value === undefined) return 'missing';
            if (value === null) return 'null';
            if (value === true || value === 'true' || value === 'checked') return 'checked';
            if (value === false || value === 'false' || value === 'unchecked') return 'unchecked';
            if (value === 'enabled' || value === 'disabled') return value;
            return 'other-' + typeof value;
        };
        const readState = () => {
            const map = app && app.map, handler = map && map.stateChangeHandler;
            const available = !!handler && typeof handler.getItemValue === 'function';
            const result = {available, unfilled:'unavailable', filled:'unavailable'};
            if (available) {
                try {
                    result.unfilled = classifyState(handler.getItemValue('.uno:Freeline_Unfilled'));
                    result.filled = classifyState(handler.getItemValue('.uno:Freeline'));
                } catch (_) { result.readFailed = true; }
            }
            return result;
        };
        const restores = [];
        const recordType = (payload) => {
            if (typeof payload !== 'string') return null;
            const mouse = /^mouse type=(buttondown|buttonup|move)(?:\s|$)/.exec(payload);
            if (mouse) return mouse[1];
            const uno = /^uno (\.uno:Freeline_Unfilled|\.uno:Freeline|\.uno:SelectObject)(?:\s|$)/.exec(payload);
            return uno ? uno[1] : null;
        };
        const install = (target, key, phase) => {
            if (!target || typeof target[key] !== 'function') { facts.hooks[phase] = 'unavailable'; return; }
            const original = target[key];
            const descriptor = Object.getOwnPropertyDescriptor(target, key);
            const wrapped = function(...args) {
                // Inspect only known message kind, never coordinates/args/text.
                const type = recordType(args[0]);
                let entry;
                if (type) {
                    if (facts.events.length < facts.limit) {
                        entry = {phase, type, outcome:'entered'};
                        facts.events.push(entry);
                    } else facts.budgetExceeded = true;
                }
                try {
                    const result = Reflect.apply(original, this, args);
                    if (entry) entry.outcome = 'returned';
                    return result;
                } catch (error) {
                    if (entry) entry.outcome = 'threw';
                    throw error;
                }
            };
            try {
                target[key] = wrapped;
                if (target[key] !== wrapped) { facts.hooks[phase] = 'not-writable'; return; }
                facts.hooks[phase] = 'installed';
                restores.push(() => {
                    if (target[key] !== wrapped) { facts.hooks[phase] = 'changed-during-observation'; return; }
                    if (descriptor) Object.defineProperty(target, key, descriptor);
                    else delete target[key];
                });
            } catch (_) { facts.hooks[phase] = 'unavailable'; }
        };
        if (facts.enabled) {
            facts.toolStateBefore = readState();
            // Pinned Socket.sendMessage may return early or queue; transport.send
            // is the distinct actual frontend transport dispatch boundary.
            install(socket, 'sendMessage', 'frontend-sendMessage');
            install(transport, 'send', 'transport-send');
        }
        let finished = false;
        return {finish: () => {
            if (finished) return facts;
            finished = true;
            if (facts.enabled) {
                facts.toolStateAfter = readState();
                facts.socketReplaced = !!socket && socket.socket !== transport;
                for (const restore of restores.reverse()) {
                    try { restore(); } catch (_) { facts.restoreFailed = true; }
                }
            }
            facts.restored = !facts.restoreFailed;
            window.__floePenSocketQualification = facts;
            return facts;
        }};
    };
    // END boundedSocketObservation
    const observation = observeSocket(probeEnabled === true, app);
    try {
    const contacts = [];
    const post = (phase, point, buttons) => {
        const hit = elementAt(point);
        const target = mode === 'overlap' ? (hit || canvas) : canvas;
        const routedBy = mode === 'overlap'
            ? (hit ? 'elementFromPoint' : 'canvas-fallback') : 'canvas-direct';
        // Capture both targets before dispatch: the event itself may hide or
        // replace the overlay, and the receipt must describe the hit test that
        // actually routed this contact.
        const dispatchFacts = targetFacts(target);
        const hitFacts = targetFacts(hit);
        const type = phase === 'down' ? 'pointerdown' : phase === 'up' ? 'pointerup' : 'pointermove';
        target.dispatchEvent(new PointerEvent(type, {
            bubbles:true, cancelable:true, composed:true, pointerType:'pen',
            pointerId:41 + strokeID, isPrimary:true, clientX:point[0], clientY:point[1],
            button:0, buttons, pressure: buttons ? .5 : 0
        }));
        contacts.push({
            phase, x:round2(point[0]), y:round2(point[1]), routedBy,
            dispatchTarget:dispatchFacts, observedHitTarget:hitFacts,
            activeAfter:window.__floeOfficePenState().activeStroke === true
        });
    };
    // Content-free canvas route observation. This exposes a canvas-drawn
    // shape-handle section without treating it as a DOM overlay. Read before
    // and after the down so a stale previous value is visible.
    const canvasSectionName = () => {
        const sectionContainer = window.app && window.app.sectionContainer;
        return sectionContainer && typeof sectionContainer.targetSection === 'string'
            ? bounded(sectionContainer.targetSection, 64) : null;
    };
    // Re-derive the real CanvasSection hit with the pinned container's own
    // findSectionContainingPoint at the same client point. The shape-handle
    // root cause is a positive hit here, independent of DOM replay counters.
    const shapeHandlesName = (app.CSections && app.CSections.ShapeHandlesSection
        && app.CSections.ShapeHandlesSection.name) || 'shapeHandlesSection';
    const isShapeHandleSection = (name) => typeof name === 'string'
        && (name === shapeHandlesName || name.startsWith('shape-handle-'));
    const canvasPoint = (point) => {
        if (container && typeof container.convertPositionToCanvasLocale === 'function')
            return container.convertPositionToCanvasLocale({clientX:point[0], clientY:point[1]});
        const rect = canvas.getBoundingClientRect();
        return [Math.round((point[0] - rect.left) * app.dpiScale),
                Math.round((point[1] - rect.top) * app.dpiScale)];
    };
    const sectionHitAt = (point) => {
        try {
            if (!container || typeof container.findSectionContainingPoint !== 'function') return null;
            return container.findSectionContainingPoint(canvasPoint(point));
        } catch (_) { return null; }
    };
    const nameOfSection = (section) => section && typeof section.name === 'string'
        ? bounded(section.name, 64) : null;
    const boundNamesOf = (section) => {
        try {
            if (!section || !Array.isArray(section.boundsList)) return [];
            return section.boundsList.map((bound) => nameOfSection(bound))
                .filter((name) => typeof name === 'string').slice(0, 32);
        } catch (_) { return []; }
    };
    // Actual time from the previous contact's up to this down, including the
    // script's own pre-down probes. This is evidence, not the intended sleep.
    const strokeStart = performance.now();
    const elapsedSincePreviousStrokeMilliseconds = typeof window.__floePenLastStrokeEnd === 'number'
        ? round2(strokeStart - window.__floePenLastStrokeEnd) : null;
    const canvasSectionBeforeDown = canvasSectionName();
    const canvasHitSectionBeforeDown = nameOfSection(sectionHitAt(points[0]));
    const shapeHandleBeforeDown = isShapeHandleSection(canvasHitSectionBeforeDown);
    // The pinned CanvasSection hit test can put a stale shape-handle
    // subsection above the document. Record the bounded selection/handle
    // state and the production gate's suspension counter around the down so
    // the App test can prove the handle was cleared before replay.
    const shapeSelectionBeforeDown = selectionState();
    const shapeHandleSuspensionsBeforeDown = typeof before.shapeHandleSuspensions === 'number'
        ? before.shapeHandleSuspensions : null;
    post('down', points[0], 1);
    const downAccepted = contacts[0].activeAfter === true;
    const canvasSectionAtDown = canvasSectionName();
    const downHitSection = sectionHitAt(points[0]);
    const canvasHitSectionAtDown = nameOfSection(downHitSection);
    const shapeHandleAtDown = isShapeHandleSection(canvasHitSectionAtDown);
    const canvasSectionAtDownBoundNames = boundNamesOf(downHitSection);
    const shapeSelectionAtDown = selectionState();
    const shapeHandleSuspensionsAtDown = typeof window.__floeOfficePenState().shapeHandleSuspensions === 'number'
        ? window.__floeOfficePenState().shapeHandleSuspensions : null;
    for (let i = 1; i < points.length; i++) {
        await new Promise(resolve => setTimeout(resolve, 25));
        post('move', points[i], 1);
    }
    post('up', points[points.length - 1], 0);
    const after = window.__floeOfficePenState();
    const strokeDelta = after.strokes - before.strokes, coreEventDelta = after.coreEvents - before.coreEvents;
    window.__floePenLastStrokeEnd = performance.now();
    const hitDiagnostics = {
        stimulusMode:stimulusMode, hitTested:mode === 'overlap', gapMilliseconds:gap,
        previousStrokeID:previousStrokeID, elapsedSincePreviousStrokeMilliseconds,
        clampedContacts:clampedContacts.filter(Boolean).length,
        canvasSectionBeforeDown, canvasSectionAtDown,
        canvasHitSectionBeforeDown, canvasHitSectionAtDown,
        shapeHandleBeforeDown, shapeHandleAtDown,
        canvasSectionAtDownBoundNames, shapeHandlesName,
        shapeSelectionBeforeDown, shapeSelectionAtDown,
        shapeHandleSuspensionsBeforeDown, shapeHandleSuspensionsAtDown,
        overlayCensusBefore:overlayBefore, overlayCensusAfter:overlayCensus(),
        previousStrokeProbe, contacts
    };
    if (strokeDelta !== 1 || coreEventDelta < points.length + 1 || after.activeStroke) {
        // Preserve the bounded hit facts on the page so the Swift failure
        // path can attach them even though callAsyncJavaScript throws.
        window.__floePenHitQualification = {strokeID, strokeDelta, coreEventDelta,
            activeAfter:after.activeStroke, downAccepted, hitDiagnostics};
        const downFacts = contacts.length ? contacts[0].observedHitTarget : null;
        throw new Error('production pen bridge did not forward/finish synthetic stroke; down='
            + (downFacts ? downFacts.ownership + ':' + (downFacts.tag || '?') : 'none'));
    }
    window.__floePenHitQualification = null;
    return JSON.stringify({strokeID, stimulusMode:stimulusMode, hitTested:mode === 'overlap',
        gapMilliseconds:gap, previousStrokeID, elapsedSincePreviousStrokeMilliseconds,
        strokeDelta, coreEventDelta, activeAfter:after.activeStroke, downAccepted,
        before, after, canvasRect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},
        visibleDocumentRect:{x1,y1,x2,y2}, clientPoints:points, hitDiagnostics,
        hardwarePointerInput:'not-tested', pressure:'synthetic-not-hardware-tested',
        socketObservation:observation.finish()});
    } finally { observation.finish(); }
    """#

    /// Dedicated zero-motion seam for the human dot baseline. The existing
    /// stroke convenience plan requires four client points and three moves,
    /// which cannot represent a tap; this seam dispatches exactly one real pen
    /// pointerdown and one pointerup at one identical client point through the
    /// same production window-capture bridge. It never fabricates a move, an
    /// epsilon, a preview-only substitute or an SVG/bitmap shape.
    private static let zeroMotionDotScript = #"""
    const app = window.app;
    const container = app && app.sectionContainer;
    const canvas = container && container.canvas;
    const layout = app && app.activeDocument && app.activeDocument.activeLayout;
    const size = app && app.activeDocument && app.activeDocument.fileSize;
    if (!canvas || !layout || !size || !container
        || typeof container.getDocumentAnchorSection !== 'function'
        || typeof window.PointerEvent !== 'function'
        || typeof window.__floeOfficePenState !== 'function')
        throw new Error('production pen bridge or native document canvas unavailable');
    const finite = (value) => typeof value === 'number' && Number.isFinite(value) ? value : null;
    const wantPaint = typeof paintReceipt !== 'undefined' && paintReceipt === true;
    const realCancel = typeof cancelWithPointerCancel !== 'undefined' && cancelWithPointerCancel === true;
    const candidateOffsetApplied = typeof candidateOffset !== 'undefined'
        && Number.isInteger(candidateOffset) && candidateOffset > 0 ? candidateOffset : 0;
    const movingStepsRequested = typeof movingSteps !== 'undefined'
        && Number.isInteger(movingSteps) && Number.isFinite(movingSteps) && movingSteps > 0
        ? movingSteps : 0;
    const round2 = (value) => Math.round(value * 100) / 100;
    const bounded = (value, limit) => typeof value === 'string'
        ? (value.length > limit ? value.slice(0, limit) : value) : null;
    const before = window.__floeOfficePenState();
    const canvasContainer = (() => {
        const byId = document.getElementById('canvas-container');
        if (byId && byId.contains(canvas)) return byId;
        return canvas.parentElement || null;
    })();
    const classOf = (element) => element && typeof element.getAttribute === 'function'
        ? bounded(element.getAttribute('class'), 96) : null;
    const ownerOf = (element) => {
        if (!element) return 'unresolved';
        if (element === canvas) return 'canvas';
        if (canvas.contains(element)) return 'canvas-descendant';
        if (canvasContainer && canvasContainer.contains(element)) return 'canvas-container-overlay';
        if (element === document.body) return 'document-body';
        if (document.documentElement && document.documentElement.contains(element))
            return 'outside-canvas-container';
        return 'detached';
    };
    const targetFacts = (element) => {
        if (!element) return {tag:null,id:null,class:null,ownership:'unresolved',
            insideCanvas:false,insideCanvasContainer:false,connected:false};
        return {tag: bounded(element.tagName ? String(element.tagName).toLowerCase() : null, 24),
            id: bounded(typeof element.id === 'string' ? element.id : null, 64),
            class: classOf(element), ownership: ownerOf(element),
            insideCanvas: canvas.contains(element),
            insideCanvasContainer: !!(canvasContainer && canvasContainer.contains(element)),
            connected: element.isConnected === true};
    };
    const rect = canvas.getBoundingClientRect();
    const section = container.getDocumentAnchorSection();
    const scaleX = rect.width / canvas.width, scaleY = rect.height / canvas.height;
    if (!section || !section.myTopLeft || !section.size || !Number.isFinite(scaleX) || !Number.isFinite(scaleY))
        throw new Error('actual document viewport geometry unavailable');
    const origin = size.clone(); origin.pX = 0; origin.pY = 0;
    const end = size.clone();
    const dx1 = layout.documentToViewX(origin), dy1 = layout.documentToViewY(origin);
    const dx2 = layout.documentToViewX(end), dy2 = layout.documentToViewY(end);
    const x1 = rect.left + Math.max(0, section.myTopLeft[0], Math.min(dx1, dx2)) * scaleX;
    const y1 = rect.top + Math.max(0, section.myTopLeft[1], Math.min(dy1, dy2)) * scaleY;
    const x2 = rect.left + Math.min(canvas.width, section.myTopLeft[0] + section.size[0], Math.max(dx1, dx2)) * scaleX;
    const y2 = rect.top + Math.min(canvas.height, section.myTopLeft[1] + section.size[1], Math.max(dy1, dy2)) * scaleY;
    if (![x1, y1, x2, y2].every(Number.isFinite) || x2 - x1 < 120 || y2 - y1 < 120)
        throw new Error('no safely visible document drawing area');
    const base = {
        route: 'zero-motion-canvas-pointer', eventsDispatched: 0, movesDispatched: 0,
        before, canvasRect: {x:rect.x,y:rect.y,width:rect.width,height:rect.height},
        visibleDocumentRect: {x1,y1,x2,y2}, candidateProbes: [],
        hardwarePointerInput: 'not-tested', pressureSource: 'synthetic-known-finite'
    };
    if (before.drawing !== true || before.activeStroke === true) {
        base.reason = before.drawing !== true ? 'drawing-not-armed' : 'previous-active-stroke';
        return JSON.stringify(Object.assign({routeReady:false}, base));
    }
    // Pick a clean empty document area where the actual topmost DOM element is
    // inside the canvas. The candidates are real layout fractions, never a
    // fabricated target; the control band is at the upper-left.
    const candidates = [[.72,.72],[.72,.58],[.58,.72],[.81,.66],[.66,.81],[.84,.30],[.30,.84]];
    // Repeat taps rotate the same real layout candidates so each contact gets
    // its own position; no fabricated point is introduced.
    const orderedCandidates = candidateOffsetApplied > 0
        ? candidates.slice(candidateOffsetApplied % candidates.length)
            .concat(candidates.slice(0, candidateOffsetApplied % candidates.length))
        : candidates;
    let chosen = null;
    for (const [fx, fy] of orderedCandidates) {
        const px = x1 + fx * (x2 - x1), py = y1 + fy * (y2 - y1);
        let hit = null;
        try { hit = document.elementFromPoint(px, py); } catch (ignored) {}
        const facts = targetFacts(hit);
        base.candidateProbes.push({fraction:[fx,fy], point:[round2(px),round2(py)], target:facts});
        if (hit && canvas.contains(hit)) { chosen = {point:[px,py], fraction:[fx,fy], hit}; break; }
    }
    if (!chosen) {
        base.reason = 'no-clean-canvas-dot-target';
        return JSON.stringify(Object.assign({routeReady:false}, base));
    }
    const point = chosen.point;
    const dispatchTarget = chosen.hit;
    const pointerId = 941;
    const eventOptions = (buttons, pressure, at) => {
        const p = Array.isArray(at) && at.length === 2 ? at : point;
        return {
            bubbles:true, cancelable:true, composed:true, pointerType:'pen',
            pointerId, isPrimary:true, clientX:p[0], clientY:p[1],
            button:0, buttons, pressure
        };
    };
    // The real second contact event. With cancelWithPointerCancel the seam
    // dispatches a genuine pointercancel — the same pointerId/pointerType
    // landing on the pinned bridge's own registered window listener — and
    // never a normal pointerup. The frozen opaque route keeps pointerup.
    const secondEventKind = realCancel ? 'pointercancel' : 'pointerup';
    // A moving cancel extends the SAME genuine contact with real pointermove
    // events before the pointercancel: the engine really started an
    // unfinished contact that the cancel must abandon. Moves are honest,
    // small, strictly increasing steps from the same real chosen point.
    const movingContact = realCancel && movingStepsRequested > 0;
    const dispatchFacts = targetFacts(dispatchTarget);
    const observedHitFacts = targetFacts(chosen.hit);
    // Own-contact state observation (root review): with a bounded poll,
    // drain the bridge's pending preview handoffs BEFORE this contact. Only
    // a 0 pre-contact pending makes the later lastClearReason attributable
    // to this contact alone; the counts stay real bridge diagnostics and no
    // attribution is faked when the set cannot drain inside the bound.
    let preContactPending = null;
    let preContactWaited = null;
    if (wantPaint || realCancel) {
        const preStart = performance.now();
        let prePreview = typeof window.__floeOfficePenPreview === 'function'
            ? window.__floeOfficePenPreview() : null;
        preContactPending = prePreview ? prePreview.pending : -1;
        while (preContactPending > 0 && performance.now() - preStart < 7000) {
            await new Promise(resolve => setTimeout(resolve, 50));
            prePreview = typeof window.__floeOfficePenPreview === 'function'
                ? window.__floeOfficePenPreview() : null;
            preContactPending = prePreview ? prePreview.pending : -1;
        }
        preContactWaited = Math.round(performance.now() - preStart);
    }
    const clearsBeforeContact = window.__floeOfficePenState().previewClears;
    const downEvent = new PointerEvent('pointerdown', eventOptions(1, .5));
    dispatchTarget.dispatchEvent(downEvent);
    const afterDown = window.__floeOfficePenState();
    const previewAfterDown = typeof window.__floeOfficePenPreview === 'function'
        ? window.__floeOfficePenPreview() : null;
    const movePoints = [];
    let afterMoves = null;
    let previewAfterMoves = null;
    if (movingContact) {
        for (let step = 1; step <= movingStepsRequested; step += 1) {
            const at = [point[0] + step * 2.5, point[1] + step * 1.5];
            movePoints.push([round2(at[0]), round2(at[1])]);
            dispatchTarget.dispatchEvent(new PointerEvent('pointermove',
                eventOptions(1, .5, at)));
        }
        afterMoves = window.__floeOfficePenState();
        previewAfterMoves = typeof window.__floeOfficePenPreview === 'function'
            ? window.__floeOfficePenPreview() : null;
    }
    await new Promise(resolve => setTimeout(resolve, 40));
    const secondPoint = movingContact && movePoints.length
        ? movePoints[movePoints.length - 1] : point;
    const secondEvent = new PointerEvent(secondEventKind, eventOptions(0, 0, secondPoint));
    dispatchTarget.dispatchEvent(secondEvent);
    const afterUp = window.__floeOfficePenState();
    const previewAfterUp = typeof window.__floeOfficePenPreview === 'function'
        ? window.__floeOfficePenPreview() : null;
    const clearsAfterContact = afterUp.previewClears;
    const lastClearReasonAfterContact = afterUp.lastPreviewClear === undefined
        ? null : afterUp.lastPreviewClear;
    const strokeDelta = afterUp.strokes - before.strokes;
    const coreEventDelta = afterUp.coreEvents - before.coreEvents;
    let paint = null;
    if (wantPaint) {
        const pendingAtUp = previewAfterUp ? previewAfterUp.pending : -1;
        const clearsBefore = afterUp.previewClears;
        const startedAt = performance.now();
        let pendingNow = pendingAtUp;
        let reasonNow = afterUp.lastPreviewClear;
        while (performance.now() - startedAt < 6500) {
            const previewNow = typeof window.__floeOfficePenPreview === 'function'
                ? window.__floeOfficePenPreview() : null;
            const stateNow = window.__floeOfficePenState();
            pendingNow = previewNow ? previewNow.pending : -1;
            reasonNow = stateNow.lastPreviewClear;
            if (!previewNow || previewNow.available !== true || pendingNow <= 0) break;
            await new Promise(resolve => setTimeout(resolve, 50));
        }
        paint = {available: !!(previewAfterUp && previewAfterUp.available === true),
            preContactPending: preContactPending,
            preContactWaitedMilliseconds: preContactWaited,
            pendingAtUp: pendingAtUp,
            clearsBefore: clearsBefore,
            clearsAfter: window.__floeOfficePenState().previewClears,
            lastClearReason: reasonNow === undefined ? null : reasonNow,
            pendingAfterUp: pendingNow,
            waitedMilliseconds: Math.round(performance.now() - startedAt)};
    }
    const receipt = {
        routeReady: true, route: base.route,
        pointClient: [round2(point[0]), round2(point[1])],
        clientPoints: movingContact
            ? [[point[0], point[1]]].concat(movePoints, [secondPoint])
            : [[point[0], point[1]], [point[0], point[1]]],
        dotFraction: chosen.fraction,
        pressure: {down: finite(downEvent.pressure), up: finite(secondEvent.pressure)},
        eventsDispatched: movingContact ? 2 + movingStepsRequested : 2,
        movesDispatched: movingContact ? movingStepsRequested : 0,
        pointerId,
        dispatchTarget: dispatchFacts, observedHitTarget: observedHitFacts,
        candidateProbes: base.candidateProbes,
        before, afterDown, afterUp,
        activeAfterDown: afterDown.activeStroke === true,
        activeAfterUp: afterUp.activeStroke === true,
        downAccepted: afterDown.activeStroke === true,
        strokeDelta, coreEventDelta,
        previewAfterDown, previewAfterUp,
        visibleDocumentRect: base.visibleDocumentRect, canvasRect: base.canvasRect,
        hardwarePointerInput: 'not-tested', pressureSource: 'synthetic-known-finite'
    };
    // Extended seam facts are present only for explicitly extended callers,
    // so the frozen opaque receipt bytes stay unchanged.
    if (wantPaint || realCancel || candidateOffsetApplied > 0) {
        receipt.paint = paint;
        receipt.secondEventKind = secondEventKind;
        receipt.candidateOffset = candidateOffsetApplied;
    }
    if (realCancel) {
        receipt.preContactPending = preContactPending;
        receipt.preContactWaitedMilliseconds = preContactWaited;
        // The bridge's own clear counters around this contact: when the
        // contact itself caused a preview drop, that drop must carry the
        // pointercancel reason — a paint success for a canceled contact is
        // the exact defect shape this gate exists to catch.
        receipt.cancelPreview = {
            clearsBeforeContact: clearsBeforeContact,
            clearsAfterContact: clearsAfterContact,
            lastClearReason: lastClearReasonAfterContact
        };
    }
    if (movingContact) {
        // Only a moving contact exposes the mid-sequence state; the frozen
        // and zero-cancel receipts keep their existing key sets unchanged.
        receipt.activeAfterMoves = afterMoves.activeStroke === true;
        receipt.movePoints = movePoints;
        receipt.afterMoves = afterMoves;
        receipt.previewAfterMoves = previewAfterMoves;
    }
    return JSON.stringify(receipt);
    """#

    /// Fresh reopened-page geometry for mapping the original dot fraction to
    /// current engine-page snapshot pixels. Read-only, bounded and text-free.
    private static let zeroMotionRenderProbeScript = #"""
    const app = window.app;
    const container = app && app.sectionContainer;
    const canvas = container && container.canvas;
    const layout = app && app.activeDocument && app.activeDocument.activeLayout;
    const size = app && app.activeDocument && app.activeDocument.fileSize;
    if (!canvas || !layout || !size || !container || typeof container.getDocumentAnchorSection !== 'function')
        return JSON.stringify({available:false, reason:'document-geometry-unavailable'});
    const section = container.getDocumentAnchorSection();
    const rect = canvas.getBoundingClientRect();
    const scaleX = rect.width / canvas.width, scaleY = rect.height / canvas.height;
    if (!section || !section.myTopLeft || !section.size || !Number.isFinite(scaleX) || !Number.isFinite(scaleY))
        return JSON.stringify({available:false, reason:'section-geometry-unavailable'});
    const origin = size.clone(); origin.pX = 0; origin.pY = 0;
    const end = size.clone();
    const dx1 = layout.documentToViewX(origin), dy1 = layout.documentToViewY(origin);
    const dx2 = layout.documentToViewX(end), dy2 = layout.documentToViewY(end);
    const x1 = rect.left + Math.max(0, section.myTopLeft[0], Math.min(dx1, dx2)) * scaleX;
    const y1 = rect.top + Math.max(0, section.myTopLeft[1], Math.min(dy1, dy2)) * scaleY;
    const x2 = rect.left + Math.min(canvas.width, section.myTopLeft[0] + section.size[0], Math.max(dx1, dx2)) * scaleX;
    const y2 = rect.top + Math.min(canvas.height, section.myTopLeft[1] + section.size[1], Math.max(dy1, dy2)) * scaleY;
    return JSON.stringify({available:true, x1,y1,x2,y2,
        canvasRect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},
        viewportWidth:window.innerWidth, viewportHeight:window.innerHeight,
        scrollX:window.scrollX, scrollY:window.scrollY,
        visualScale:window.visualViewport ? window.visualViewport.scale : null,
        devicePixelRatio:window.devicePixelRatio,
        zoom:app.map && typeof app.map.getZoom === 'function' ? app.map.getZoom() : null});
    """#

    /// Qualification-only capture of a real core graphic selection. The pinned
    /// document layer routes `graphicselection:` through `_onMessage`; that
    /// exact instance handler is wrapped (never a made-up section or DOM), the
    /// real `.uno:SelectObject` command and a legacy MouseEvent click on an
    /// actual contact point select the engine-created curve, and the wrapper is
    /// restored in `finally`. The returned message is passed back to the replay
    /// script; no test global survives a successful call.
    private static let staleHandleSelectionScript = #"""
    const app = window.app;
    const map = app && app.map;
    const docLayer = map && map._docLayer;
    const container = app && app.sectionContainer;
    const canvas = container && container.canvas;
    const graphicSelection = app && app.definitions && app.definitions.graphicSelection;
    if (!canvas || !map || !container || !docLayer || !graphicSelection
        || typeof docLayer._onMessage !== 'function'
        || typeof graphicSelection.onMessage !== 'function'
        || typeof graphicSelection.hasActiveSelection !== 'function'
        || typeof map.sendUnoCommand !== 'function'
        || typeof container.getSectionWithName !== 'function'
        || typeof container.findSectionContainingPoint !== 'function'
        || typeof container.convertPositionToCanvasLocale !== 'function')
        throw new Error('pinned selection APIs unavailable');
    const rect = canvas.getBoundingClientRect();
    const scaleX = rect.width / canvas.width, scaleY = rect.height / canvas.height;
    if (!(scaleX > 0) || !(scaleY > 0) || Math.abs(scaleX - scaleY) > 0.001)
        throw new Error('actual canvas/client scale unavailable');
    const points = Array.isArray(curvePoints) ? curvePoints.filter(point =>
        Array.isArray(point) && point.length === 2
        && point.every(value => typeof value === 'number' && Number.isFinite(value))) : [];
    if (points.length < 2) throw new Error('actual first-curve endpoints unavailable');
    const visible = visibleDocumentRect && ['x1','y1','x2','y2'].every(key =>
        typeof visibleDocumentRect[key] === 'number' && Number.isFinite(visibleDocumentRect[key]))
        ? visibleDocumentRect : null;
    if (!visible) throw new Error('actual visible document rectangle unavailable');
    // The saved freehand path passes through its first and last contacts; the
    // two interior contacts become Bézier control points. Click the real
    // endpoints first, then fall back to the interior only as bounded attempts.
    const clickPoints = [points[0], points[points.length - 1]]
        .concat(points.slice(1, -1)).slice(0, 4);
    const round2 = value => Math.round(value * 100) / 100;
    const bounded = (value, limit) => typeof value === 'string'
        ? (value.length > limit ? value.slice(0, limit) : value) : null;
    const classOf = element => {
        if (!element || typeof element.getAttribute !== 'function') return null;
        return bounded(element.getAttribute('class'), 96);
    };
    const targetFacts = element => {
        if (!element) return {tag:null, id:null, class:null, connected:false};
        return {tag:bounded(element.tagName ? String(element.tagName).toLowerCase() : null, 24),
            id:bounded(typeof element.id === 'string' ? element.id : null, 64),
            class:classOf(element), connected:element.isConnected === true};
    };
    const canvasPoint = point => container.convertPositionToCanvasLocale({clientX:point[0], clientY:point[1]});
    const shapeHandlesName = (app.CSections && app.CSections.ShapeHandlesSection
        && app.CSections.ShapeHandlesSection.name) || 'shapeHandlesSection';
    const isShapeHandleName = name => typeof name === 'string'
        && (name === shapeHandlesName || name.startsWith('shape-handle-'));
    const isChildShapeHandleName = name => typeof name === 'string' && name.startsWith('shape-handle-');
    const isScalingHandleName = name => typeof name === 'string' && /^shape-handle-\d+$/.test(name);
    const nameOfSection = section => section && typeof section.name === 'string'
        ? bounded(section.name, 64) : null;
    const sectionHit = point => {
        try { return container.findSectionContainingPoint(canvasPoint(point)); }
        catch (ignored) { return null; }
    };
    const selectionState = () => {
        const section = graphicSelection.handlesSection;
        const properties = section && section.sectionProperties ? section.sectionProperties : {};
        const subSections = Array.isArray(properties.subSections) ? properties.subSections : [];
        return {hasActiveSelection: graphicSelection.hasActiveSelection() === true,
            handlesFound: !!(section && typeof container.getSectionWithName === 'function'
                && container.getSectionWithName(section.name) === section),
            shown: section ? section.showSection === true : false,
            subSectionCount: subSections.length,
            shownChildCount: subSections.filter(sub => sub && sub.showSection === true).length,
            sectionName: section ? bounded(section.name, 64) : null,
            position: section && Array.isArray(section.myTopLeft) && Array.isArray(section.size)
                ? [section.myTopLeft[0], section.myTopLeft[1], section.size[0], section.size[1]] : null};
    };
    const parseCapture = textMsg => {
        if (typeof textMsg !== 'string' || !textMsg.startsWith('graphicselection:')) return null;
        if (textMsg.length > 16384) return null;
        const body = textMsg.slice('graphicselection:'.length);
        if (!body || body.startsWith('EMPTY') || body.startsWith('INPLACE')) return null;
        let parsed;
        try { parsed = JSON.parse('[' + body + ']'); } catch (ignored) { return null; }
        if (!Array.isArray(parsed) || parsed.length <= 5) return null;
        const extra = parsed[5];
        const handles = extra && extra.handles && extra.handles.kinds;
        if (!handles || typeof handles !== 'object') return null;
        const rectangle = handles.rectangle;
        if (!rectangle || typeof rectangle !== 'object') return null;
        const ids = Object.keys(rectangle).filter(key => Array.isArray(rectangle[key]) && rectangle[key].length > 0);
        if (ids.length < 1) return null;
        return {message:textMsg, bytes:textMsg.length,
            id:extra && typeof extra.id === 'string' ? bounded(extra.id, 64) : null,
            // The first engine-created annotation is a freehand line in both
            // observed formats. Keep the core's own type string so the
            // capture cannot silently accept an unrelated object selection.
            type:extra && typeof extra.typeString === 'string'
                ? bounded(extra.typeString, 40) : null,
            handleKinds:Object.keys(handles).filter(key => typeof key === 'string').slice(0, 16),
            handleCount:ids.length,
            isDraggable:extra.isDraggable !== false,
            isResizable:extra.isResizable !== false,
            rectangle:[parsed[0], parsed[1], parsed[2], parsed[3]].map(value =>
                typeof value === 'number' && Number.isFinite(value) ? value : null)};
    };
    const curveCore = points.map(canvasPoint);
    const curveBounds = {
        minX:Math.min(...curveCore.map(point => point[0])),
        maxX:Math.max(...curveCore.map(point => point[0])),
        minY:Math.min(...curveCore.map(point => point[1])),
        maxY:Math.max(...curveCore.map(point => point[1]))
    };
    // Identity-only containment, not geometry equality: the handle section is
    // allowed to be larger than the contact points because of handles/line hit
    // slop, but it must describe the same real curve.
    const boundsMatch = position => {
        if (!position || position.length !== 4
            || !position.every(value => typeof value === 'number' && Number.isFinite(value))) return false;
        const tolerance = 192;
        return curveBounds.minX >= position[0] - tolerance
            && curveBounds.maxX <= position[0] + position[2] + tolerance
            && curveBounds.minY >= position[1] - tolerance
            && curveBounds.maxY <= position[1] + position[3] + tolerance;
    };
    const handleCandidates = () => {
        const section = graphicSelection.handlesSection;
        const subSections = section && section.sectionProperties
            && Array.isArray(section.sectionProperties.subSections)
            ? section.sectionProperties.subSections : [];
        const centerOfCanvas = [rect.left + rect.width / 2, rect.top + rect.height / 2];
        const candidates = [];
        for (const sub of subSections) {
            if (!sub || sub.showSection !== true) continue;
            const name = typeof sub.name === 'string' ? sub.name : '';
            if (!isScalingHandleName(name)) continue;
            if (!Array.isArray(sub.myTopLeft) || !Array.isArray(sub.size)) continue;
            if (!sub.myTopLeft.every(Number.isFinite) || !sub.size.every(Number.isFinite)) continue;
            const center = [rect.left + (sub.myTopLeft[0] + sub.size[0] / 2) * scaleX,
                            rect.top + (sub.myTopLeft[1] + sub.size[1] / 2) * scaleY];
            if (!center.every(Number.isFinite)) continue;
            const inCanvas = center[0] >= rect.left + 1 && center[0] <= rect.right - 1
                && center[1] >= rect.top + 1 && center[1] <= rect.bottom - 1;
            const inVisible = center[0] >= visible.x1 && center[0] <= visible.x2
                && center[1] >= visible.y1 && center[1] <= visible.y2;
            if (!inCanvas || !inVisible) continue;
            const coreCenter = canvasPoint(center);
            const mappingError = Math.max(
                Math.abs(coreCenter[0] - (sub.myTopLeft[0] + sub.size[0] / 2)),
                Math.abs(coreCenter[1] - (sub.myTopLeft[1] + sub.size[1] / 2)));
            const hitName = nameOfSection(sectionHit(center));
            candidates.push({name, center:[round2(center[0]), round2(center[1])],
                mappingError:round2(mappingError), hitName,
                hitIsShapeHandle:isShapeHandleName(hitName),
                hitIsChildShapeHandle:isChildShapeHandleName(hitName), visible:true,
                distanceFromCanvasCenter:round2(Math.hypot(center[0] - centerOfCanvas[0],
                    center[1] - centerOfCanvas[1]))});
            if (candidates.length >= 16) break;
        }
        return candidates;
    };
    // A standalone DOM `click` never reaches the pinned input path:
    // CanvasSectionContainer's `onClick` only runs when `positionOnMouseDown`
    // and `positionOnMouseUp` were recorded by the preceding down/up pair.
    // Dispatch the real browser-like sequence on the actual hit target. The
    // down/up record the pinned container positions (no core contact because
    // there is no drag), and the click reaches MouseControl.onClick, which
    // sends the real buttondown/buttonup click through the core. This uses
    // the pinned canvas/MouseControl path end to end; no mock section or
    // synthetic core message is fabricated.
    const dispatchSelectClick = (target, point) => {
        const base = {bubbles:true, cancelable:true, view:window,
            clientX:point[0], clientY:point[1], button:0};
        target.dispatchEvent(new MouseEvent('mousedown', {...base, buttons:1}));
        target.dispatchEvent(new MouseEvent('mouseup', {...base, buttons:0}));
        target.dispatchEvent(new MouseEvent('click', {...base, buttons:0}));
        return ['mousedown', 'mouseup', 'click'];
    };
    let captured = null;
    let capturedState = null;
    let capturedCandidates = [];
    let captureAt = null;
    let capturePhase = null;
    let selectAttemptStarted = false;
    let rejected = 0;
    let tooLarge = 0;
    const original = docLayer._onMessage;
    const ownDescriptor = Object.getOwnPropertyDescriptor(docLayer, '_onMessage');
    const hook = function (textMsg) {
        let value = null;
        if (!captured && typeof textMsg === 'string'
            && textMsg.startsWith('graphicselection:')) {
            value = parseCapture(textMsg);
            if (!value && textMsg.length > 16384) tooLarge += 1;
            else if (!value && !textMsg.slice('graphicselection:'.length).trim().startsWith('EMPTY'))
                rejected += 1;
        }
        const outcome = Reflect.apply(original, this, arguments);
        if (value) {
            captured = value;
            // Sample the authentic section and child-hit state in the same
            // synchronous turn that invoked the real handler. The next
            // `graphicselection: EMPTY` (the production Escape) clears
            // `GraphicSelection.rectangle`, removes the handles section and
            // its children; polling after any later timer would miss a
            // selection that did exist at handler time. The capture may come
            // from the engine's post-stroke selection echo or from the real
            // select contact below; both are the same actual first curve.
            capturedState = selectionState();
            capturedCandidates = handleCandidates();
            captureAt = Math.round(performance.now());
            capturePhase = selectAttemptStarted ? 'select-click' : 'post-stroke-echo';
        }
        return outcome;
    };
    const result = {step:'real-selection', format:documentFormat, ok:false,
        hookInstalled:false, hookRestored:false, deselectedBeforeSelect:false,
        attempts:[], rejectedMessages:0, tooLargeMessages:0, capture:null,
        captureAtMs:null, capturePhase:null, afterCapture:null,
        afterCaptureLive:null, realHandleCandidates:[], realHandleHit:null,
        curveBounds, selectionMatchesFirstCurve:false};
    let restored = false;
    try {
        docLayer._onMessage = hook;
        result.hookInstalled = docLayer._onMessage === hook;
        if (!result.hookInstalled) throw new Error('document layer message hook was not writable');
        // A positive auto-selection callback from the first stroke can still
        // be in flight when the production gate posts its Escape. Require a
        // stable clear window before the checkpoint/re-arm. The hook above
        // keeps the first authentic nonempty callback (with its immediate
        // post-handler snapshot) even if that callback is the in-flight echo;
        // the real select contact below is the fallback when it already
        // passed before the hook was installed.
        const clearDeadline = performance.now() + 3000;
        let clearSince = null;
        while (performance.now() < clearDeadline) {
            if (graphicSelection.hasActiveSelection() === false) {
                if (clearSince === null) clearSince = performance.now();
                else if (performance.now() - clearSince >= 250) break;
            } else {
                clearSince = null;
            }
            await new Promise(resolve => setTimeout(resolve, 50));
        }
        result.deselectedBeforeSelect = clearSince !== null
            && graphicSelection.hasActiveSelection() === false;
        // This is a best-effort clean start for the select contact, not an
        // acquisition requirement: the production-gate deselect below must
        // clear any live selection before the checkpoint and marker re-arm.
        for (const point of clickPoints) {
            if (captured) break;
            try { map.sendUnoCommand('.uno:SelectObject'); }
            catch (error) {
                throw new Error('real .uno:SelectObject failed: '
                    + String(error && error.message || error).slice(0, 96));
            }
            await new Promise(resolve => setTimeout(resolve, 200));
            if (captured) break;
            let hit = null;
            try { hit = document.elementFromPoint(point[0], point[1]); } catch (ignored) {}
            const attempt = {x:round2(point[0]), y:round2(point[1]),
                hit:targetFacts(hit), dispatched:false, captured:false,
                events:null, note:null};
            result.attempts.push(attempt);
            if (!hit || !(hit === canvas || canvas.contains(hit))) {
                attempt.note = 'actual-hit-outside-canvas';
                continue;
            }
            try {
                selectAttemptStarted = true;
                attempt.events = dispatchSelectClick(hit, point);
                attempt.dispatched = true;
            } catch (error) {
                attempt.note = String(error && error.message || error).slice(0, 120);
                continue;
            }
            const attemptDeadline = performance.now() + 1800;
            while (!captured && performance.now() < attemptDeadline)
                await new Promise(resolve => setTimeout(resolve, 50));
            attempt.captured = !!captured;
        }
        result.rejectedMessages = rejected;
        result.tooLargeMessages = tooLarge;
        result.capture = captured;
        result.captureAtMs = captureAt;
        result.capturePhase = capturePhase;
        // Keep the immediate post-handler snapshot as acquisition evidence.
        // A later empty callback legitimately clearing the persistent handles
        // is recorded separately and is not an acquisition failure; the
        // delayed replay below must independently recreate and hit a real
        // child handle and prove the production suspension and saved 1->2.
        result.afterCapture = capturedState;
        result.afterCaptureLive = selectionState();
        result.selectionMatchesFirstCurve = capturedState
            ? boundsMatch(capturedState.position) : false;
        result.realHandleCandidates = capturedCandidates;
        result.realHandleHit = capturedCandidates.find(candidate =>
            candidate.hitIsChildShapeHandle && candidate.mappingError <= 2.5) || null;
        result.captureLineKind = captured && typeof captured.type === 'string'
            ? captured.type : null;
        result.handlesClearedAfterCapture = !!capturedState
            && result.afterCaptureLive.hasActiveSelection === false;
        result.ok = result.hookInstalled && !!result.capture
            && (result.captureLineKind === 'freehandLine'
                || result.captureLineKind === 'pathLine');
        if (!result.ok) {
            const reasons = [];
            if (!result.hookInstalled) reasons.push('hook');
            if (!result.capture) reasons.push('capture');
            if (result.capture && result.captureLineKind !== 'freehandLine'
                && result.captureLineKind !== 'pathLine') reasons.push('line-kind');
            result.failureReasons = reasons;
        }
    } catch (error) {
        result.error = String(error && error.message || error).slice(0, 200);
    } finally {
        try {
            if (ownDescriptor) {
                Object.defineProperty(docLayer, '_onMessage', ownDescriptor);
                restored = docLayer._onMessage === original;
            } else if (docLayer._onMessage === hook) {
                delete docLayer._onMessage;
                restored = docLayer._onMessage === original;
            } else {
                restored = docLayer._onMessage === original;
            }
        } catch (ignored) { restored = false; }
    }
    result.hookRestored = restored;
    result.ok = result.ok && restored;
    if (!result.ok) {
        window.__floeStaleHandleSelectionFailure = result;
        throw new Error('real stale-handle selection capture failed: '
            + (result.error
                || (Array.isArray(result.failureReasons) && result.failureReasons.length > 0
                    ? result.failureReasons.join(',') : 'unconfirmed')));
    }
    return JSON.stringify(result);
    """#

    /// Production-gate deselection between capture and re-arm. It posts the
    /// same ordered Escape pair as the real dispose path; the selected core
    /// object is never cleared by touching the frontend rectangle directly.
    private static let staleHandleDeselectScript = #"""
    const app = window.app;
    const selection = app && app.definitions && app.definitions.graphicSelection;
    if (!selection || typeof selection.hasActiveSelection !== 'function'
        || typeof window.__floeSetOfficeDrawingMode !== 'function')
        throw new Error('production deselection APIs unavailable');
    const selectedBefore = selection.hasActiveSelection() === true;
    const gateResult = window.__floeSetOfficeDrawingMode(false) === true;
    // Require a stable clear window, not one false sample: the Escape's
    // empty-selection callback can trail a positive callback that was already
    // in flight. Waiting for both leaves the checkpoint and re-arm genuinely
    // unselected.
    const deadline = performance.now() + 3000;
    let clearSince = null;
    while (performance.now() < deadline) {
        if (selection.hasActiveSelection() === false) {
            if (clearSince === null) clearSince = performance.now();
            else if (performance.now() - clearSince >= 200) break;
        } else {
            clearSince = null;
        }
        await new Promise(resolve => setTimeout(resolve, 50));
    }
    const selectedAfter = selection.hasActiveSelection() === true;
    return JSON.stringify({selectedBefore, gateResult, selectedAfter,
        quietMilliseconds:clearSince === null
            ? 0 : Math.round(performance.now() - clearSince),
        cleared:selectedAfter === false && clearSince !== null});
    """#

    /// Replay the captured authentic `graphicselection:` callback through the
    /// original pinned frontend handler, then, in the same synchronous turn,
    /// find a shown independent scaling-handle child, map its actual
    /// canvas-core center to a client point, confirm the real CanvasSection
    /// hit is a `shape-handle-*`, and dispatch the next Pencil down on the real
    /// `elementFromPoint` target. No await occurs between replay and down, so a
    /// late deselect callback cannot erase the seeded stale section first.
    private static let staleHandleReplayScript = #"""
    const app = window.app;
    const map = app && app.map;
    const container = app && app.sectionContainer;
    const canvas = container && container.canvas;
    const graphicSelection = app && app.definitions && app.definitions.graphicSelection;
    const pen = typeof window.__floeOfficePenState === 'function' ? window.__floeOfficePenState() : null;
    if (!canvas || !map || !container || !graphicSelection || !pen
        || typeof graphicSelection.onMessage !== 'function'
        || typeof graphicSelection.hasActiveSelection !== 'function'
        || typeof container.findSectionContainingPoint !== 'function'
        || typeof container.convertPositionToCanvasLocale !== 'function')
        throw new Error('pinned replay APIs unavailable');
    if (pen.drawing !== true || pen.activeStroke === true)
        throw new Error('production pen gate is not armed for the delayed replay');
    if (typeof message !== 'string' || !message.startsWith('graphicselection:')
        || message.length > 16384)
        throw new Error('authentic bounded graphicselection message unavailable');
    if (graphicSelection.hasActiveSelection() === true)
        throw new Error('a live core selection still exists before the delayed replay');
    const rect = canvas.getBoundingClientRect();
    const scaleX = rect.width / canvas.width, scaleY = rect.height / canvas.height;
    if (!(scaleX > 0) || !(scaleY > 0) || Math.abs(scaleX - scaleY) > 0.001)
        throw new Error('actual canvas/client scale unavailable');
    const points = Array.isArray(curvePoints) ? curvePoints.filter(point =>
        Array.isArray(point) && point.length === 2
        && point.every(value => typeof value === 'number' && Number.isFinite(value))) : [];
    if (points.length < 1) throw new Error('actual first-curve points unavailable');
    let visible = visibleDocumentRect && ['x1','y1','x2','y2'].every(key =>
        typeof visibleDocumentRect[key] === 'number' && Number.isFinite(visibleDocumentRect[key]))
        ? visibleDocumentRect : null;
    if (!visible) throw new Error('actual visible document rectangle unavailable');
    // Prefer the live visible document area at replay time: the prior-curve
    // checkpoint export happened after the first contact and may have changed
    // the scroll/zoom. The handle must be inside what is actually visible now,
    // not only inside the first contact's old rectangle.
    try {
        const layout = app.activeDocument && app.activeDocument.activeLayout;
        const size = app.activeDocument && app.activeDocument.fileSize;
        const anchor = typeof container.getDocumentAnchorSection === 'function'
            ? container.getDocumentAnchorSection() : null;
        if (layout && size && anchor && Array.isArray(anchor.myTopLeft) && Array.isArray(anchor.size)
            && typeof layout.documentToViewX === 'function' && typeof layout.documentToViewY === 'function') {
            const origin = size.clone(); origin.pX = 0; origin.pY = 0;
            const end = size.clone();
            const dx1 = layout.documentToViewX(origin), dy1 = layout.documentToViewY(origin);
            const dx2 = layout.documentToViewX(end), dy2 = layout.documentToViewY(end);
            const x1 = rect.left + Math.max(0, anchor.myTopLeft[0], Math.min(dx1, dx2)) * scaleX;
            const y1 = rect.top + Math.max(0, anchor.myTopLeft[1], Math.min(dy1, dy2)) * scaleY;
            const x2 = rect.left + Math.min(canvas.width, anchor.myTopLeft[0] + anchor.size[0],
                Math.max(dx1, dx2)) * scaleX;
            const y2 = rect.top + Math.min(canvas.height, anchor.myTopLeft[1] + anchor.size[1],
                Math.max(dy1, dy2)) * scaleY;
            if ([x1, y1, x2, y2].every(Number.isFinite) && x2 - x1 > 120 && y2 - y1 > 120)
                visible = {x1, y1, x2, y2};
        }
    } catch (ignored) {}
    const sleep = milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds));
    const round2 = value => Math.round(value * 100) / 100;
    const bounded = (value, limit) => typeof value === 'string'
        ? (value.length > limit ? value.slice(0, limit) : value) : null;
    const classOf = element => {
        if (!element || typeof element.getAttribute !== 'function') return null;
        return bounded(element.getAttribute('class'), 96);
    };
    const targetFacts = element => {
        if (!element) return {tag:null, id:null, class:null, connected:false};
        return {tag:bounded(element.tagName ? String(element.tagName).toLowerCase() : null, 24),
            id:bounded(typeof element.id === 'string' ? element.id : null, 64),
            class:classOf(element), connected:element.isConnected === true};
    };
    const canvasPoint = point => container.convertPositionToCanvasLocale({clientX:point[0], clientY:point[1]});
    const shapeHandlesName = (app.CSections && app.CSections.ShapeHandlesSection
        && app.CSections.ShapeHandlesSection.name) || 'shapeHandlesSection';
    const isShapeHandleName = name => typeof name === 'string'
        && (name === shapeHandlesName || name.startsWith('shape-handle-'));
    const isChildShapeHandleName = name => typeof name === 'string' && name.startsWith('shape-handle-');
    const isScalingHandleName = name => typeof name === 'string' && /^shape-handle-\d+$/.test(name);
    const nameOfSection = section => section && typeof section.name === 'string'
        ? bounded(section.name, 64) : null;
    const sectionHit = point => {
        try { return container.findSectionContainingPoint(canvasPoint(point)); }
        catch (ignored) { return null; }
    };
    const selectionState = () => {
        const section = graphicSelection.handlesSection;
        const properties = section && section.sectionProperties ? section.sectionProperties : {};
        const subSections = Array.isArray(properties.subSections) ? properties.subSections : [];
        return {hasActiveSelection: graphicSelection.hasActiveSelection() === true,
            handlesFound: !!(section && typeof container.getSectionWithName === 'function'
                && container.getSectionWithName(section.name) === section),
            shown: section ? section.showSection === true : false,
            subSectionCount: subSections.length,
            shownChildCount: subSections.filter(sub => sub && sub.showSection === true).length,
            sectionName: section ? bounded(section.name, 64) : null,
            position: section && Array.isArray(section.myTopLeft) && Array.isArray(section.size)
                ? [section.myTopLeft[0], section.myTopLeft[1], section.size[0], section.size[1]] : null};
    };
    const curveCore = points.map(canvasPoint);
    const curveBounds = {
        minX:Math.min(...curveCore.map(point => point[0])),
        maxX:Math.max(...curveCore.map(point => point[0])),
        minY:Math.min(...curveCore.map(point => point[1])),
        maxY:Math.max(...curveCore.map(point => point[1]))
    };
    const boundsMatch = position => {
        if (!position || position.length !== 4
            || !position.every(value => typeof value === 'number' && Number.isFinite(value))) return false;
        const tolerance = 192;
        return curveBounds.minX >= position[0] - tolerance
            && curveBounds.maxX <= position[0] + position[2] + tolerance
            && curveBounds.minY >= position[1] - tolerance
            && curveBounds.maxY <= position[1] + position[3] + tolerance;
    };
    const handleCandidates = () => {
        const section = graphicSelection.handlesSection;
        const subSections = section && section.sectionProperties
            && Array.isArray(section.sectionProperties.subSections)
            ? section.sectionProperties.subSections : [];
        const centerOfCanvas = [rect.left + rect.width / 2, rect.top + rect.height / 2];
        const candidates = [];
        for (const sub of subSections) {
            if (!sub || sub.showSection !== true) continue;
            const name = typeof sub.name === 'string' ? sub.name : '';
            if (!isScalingHandleName(name)) continue;
            if (!Array.isArray(sub.myTopLeft) || !Array.isArray(sub.size)) continue;
            if (!sub.myTopLeft.every(Number.isFinite) || !sub.size.every(Number.isFinite)) continue;
            const center = [rect.left + (sub.myTopLeft[0] + sub.size[0] / 2) * scaleX,
                            rect.top + (sub.myTopLeft[1] + sub.size[1] / 2) * scaleY];
            if (!center.every(Number.isFinite)) continue;
            const inCanvas = center[0] >= rect.left + 1 && center[0] <= rect.right - 1
                && center[1] >= rect.top + 1 && center[1] <= rect.bottom - 1;
            const inVisible = center[0] >= visible.x1 && center[0] <= visible.x2
                && center[1] >= visible.y1 && center[1] <= visible.y2;
            if (!inCanvas || !inVisible) continue;
            const coreCenter = canvasPoint(center);
            const mappingError = Math.max(
                Math.abs(coreCenter[0] - (sub.myTopLeft[0] + sub.size[0] / 2)),
                Math.abs(coreCenter[1] - (sub.myTopLeft[1] + sub.size[1] / 2)));
            const hitName = nameOfSection(sectionHit(center));
            candidates.push({name, center:[round2(center[0]), round2(center[1])],
                mappingError:round2(mappingError), hitName,
                hitIsShapeHandle:isShapeHandleName(hitName),
                hitIsChildShapeHandle:isChildShapeHandleName(hitName), visible:true,
                distanceFromCanvasCenter:round2(Math.hypot(center[0] - centerOfCanvas[0],
                    center[1] - centerOfCanvas[1]))});
            if (candidates.length >= 16) break;
        }
        return candidates;
    };
    const insideVisible = point => point[0] >= visible.x1 + 1 && point[0] <= visible.x2 - 1
        && point[1] >= visible.y1 + 1 && point[1] <= visible.y2 - 1;
    const buildStrokePoints = center => {
        const centerX = (visible.x1 + visible.x2) / 2, centerY = (visible.y1 + visible.y2) / 2;
        let dx = centerX - center[0], dy = centerY - center[1];
        const length = Math.hypot(dx, dy);
        if (!Number.isFinite(length) || length < 1) return null;
        dx /= length; dy /= length;
        const perpendicular = [-dy, dx];
        const lateral = [0, 2, -2, 1];
        for (let distance = 40; distance >= 8; distance -= 4) {
            const stroke = [0, 1, 2, 3].map(index => [
                center[0] + dx * (distance * index / 3) + perpendicular[0] * lateral[index],
                center[1] + dy * (distance * index / 3) + perpendicular[1] * lateral[index]]);
            if (stroke.every(insideVisible)) return stroke;
        }
        return null;
    };
    const suspensionsBefore = pen.shapeHandleSuspensions;
    const result = {step:'delayed-selection-replay', strokeID,
        ok:false, beforeHitName:null, beforeHitIsShapeHandle:false,
        beforeHitIsChildShapeHandle:false, afterReplay:null, afterDown:null,
        suspensionDeltaAtDown:0, strokeDelta:0, coreEventDelta:0, downAccepted:false,
        activeAfter:null, clientPoints:[], chosenHandle:null, candidates:[],
        replayedMessageBytes:message.length, replayedMessageSHA256:null,
        selectionMatchesFirstCurve:false};
    try {
        // The exact captured frontend handler runs here. No await follows until
        // after the Pencil down below, so the stale section cannot be erased by
        // an async empty-selection callback between seeding and contact.
        graphicSelection.onMessage(message);
        result.afterReplay = selectionState();
        result.selectionMatchesFirstCurve = boundsMatch(result.afterReplay.position);
        result.candidates = handleCandidates();
        const chosen = result.candidates
            .filter(candidate => candidate.hitIsChildShapeHandle && candidate.mappingError <= 2.5)
            .sort((left, right) => right.distanceFromCanvasCenter - left.distanceFromCanvasCenter
                || left.name.localeCompare(right.name))[0] || null;
        result.chosenHandle = chosen;
        if (!chosen) throw new Error('no visible real shape-handle-* child center resolved');
        const beforeSection = sectionHit(chosen.center);
        result.beforeHitName = nameOfSection(beforeSection);
        result.beforeHitIsShapeHandle = isShapeHandleName(result.beforeHitName);
        result.beforeHitIsChildShapeHandle = isChildShapeHandleName(result.beforeHitName);
        if (!result.beforeHitIsChildShapeHandle)
            throw new Error('handle center did not resolve to an independent shape-handle-* section');
        const hitTarget = document.elementFromPoint(chosen.center[0], chosen.center[1]);
        result.elementFromPoint = targetFacts(hitTarget);
        if (!hitTarget || !(hitTarget === canvas || canvas.contains(hitTarget)))
            throw new Error('real handle center is not on the document canvas');
        result.clientPoints = buildStrokePoints(chosen.center);
        if (!result.clientPoints)
            throw new Error('no visible inward stroke points from the real handle center');
        result.strokeDistancePixels = round2(Math.hypot(
            result.clientPoints[3][0] - result.clientPoints[0][0],
            result.clientPoints[3][1] - result.clientPoints[0][1]));
        result.drawingBeforeDown = window.__floeOfficePenState().drawing === true;
        hitTarget.dispatchEvent(new PointerEvent('pointerdown', {
            bubbles:true, cancelable:true, composed:true, pointerType:'pen', pointerId:73,
            isPrimary:true, clientX:result.clientPoints[0][0], clientY:result.clientPoints[0][1],
            button:0, buttons:1, pressure:0.5
        }));
        const atDown = window.__floeOfficePenState();
        result.downAccepted = atDown.activeStroke === true;
        result.drawingAtDown = atDown.drawing === true;
        result.suspensionsAtDown = atDown.shapeHandleSuspensions;
        result.suspensionDeltaAtDown = atDown.shapeHandleSuspensions - suspensionsBefore;
        const afterDownSelection = selectionState();
        const afterDownSection = sectionHit(chosen.center);
        result.afterDown = {selection:afterDownSelection,
            hitName:nameOfSection(afterDownSection),
            hitIsShapeHandle:isShapeHandleName(nameOfSection(afterDownSection)),
            hitIsChildShapeHandle:isChildShapeHandleName(nameOfSection(afterDownSection)),
            shown:afterDownSelection.shown,
            shownChildCount:afterDownSelection.shownChildCount};
        for (let index = 1; index < result.clientPoints.length; index++) {
            await sleep(25);
            canvas.dispatchEvent(new PointerEvent('pointermove', {
                bubbles:true, cancelable:true, composed:true, pointerType:'pen', pointerId:73,
                isPrimary:true, clientX:result.clientPoints[index][0],
                clientY:result.clientPoints[index][1], button:0, buttons:1, pressure:0.5
            }));
        }
        await sleep(25);
        canvas.dispatchEvent(new PointerEvent('pointerup', {
            bubbles:true, cancelable:true, composed:true, pointerType:'pen', pointerId:73,
            isPrimary:true, clientX:result.clientPoints[result.clientPoints.length - 1][0],
            clientY:result.clientPoints[result.clientPoints.length - 1][1],
            button:0, buttons:0, pressure:0
        }));
        const after = window.__floeOfficePenState();
        result.strokeDelta = after.strokes - pen.strokes;
        result.coreEventDelta = after.coreEvents - pen.coreEvents;
        result.activeAfter = after.activeStroke === true;
        result.drawingAfter = after.drawing === true;
        result.suspensionsAfter = after.shapeHandleSuspensions;
        result.ok = result.drawingBeforeDown && result.downAccepted && result.drawingAtDown
            && result.suspensionDeltaAtDown > 0 && result.beforeHitIsChildShapeHandle
            && result.afterDown && result.afterDown.hitIsShapeHandle === false
            && result.afterDown.hitIsChildShapeHandle === false
            && result.afterDown.shownChildCount === 0 && result.afterDown.shown === false
            && result.strokeDelta === 1 && result.coreEventDelta >= 5
            && result.activeAfter === false;
    } catch (error) {
        result.error = String(error && error.message || error).slice(0, 200);
    }
    if (!result.ok) {
        window.__floeStaleHandleReplayFailure = result;
        throw new Error('delayed stale-handle replay failed: ' + (result.error || 'unconfirmed'));
    }
    return JSON.stringify(result);
    """#

    private func setNativeDrawingMode(_ native: FloeOfficeNativeViewController,
                                      _ enabled: Bool) async -> NSError? {
        await withCheckedContinuation { continuation in
            let callback: @convention(block) (NSError?) -> Void = { error in
                continuation.resume(returning: error as NSError?)
            }
            _ = native.perform(NSSelectorFromString("setDrawingMode:completion:"),
                               with: NSNumber(value: enabled), with: callback as AnyObject)
        }
    }

    private func nativeDrawingFlag(_ native: FloeOfficeNativeViewController) throws -> Bool {
        let getter = NSSelectorFromString("drawingModeEnabled")
        guard native.responds(to: getter),
              let value = native.value(forKey: "drawingModeEnabled") as? NSNumber else {
            throw NSError(domain: "OfficeNativeDrawingQualification", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "the native host does not expose its drawing-mode mirror"
            ])
        }
        return value.boolValue
    }

    private func officePenFacts(_ web: WKWebView) async throws -> [String: Any] {
        let receipt = try await web.callAsyncJavaScript(
            "return JSON.stringify(typeof window.__floeOfficePenState === 'function' ? window.__floeOfficePenState() : null);",
            arguments: [:], in: nil, contentWorld: .page)
        guard let json = receipt as? String, json.utf8.count <= 16_384,
              let facts = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NSError(domain: "OfficeNativeDrawingQualification", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "the page pen state was not a bounded JSON object"
            ])
        }
        return facts
    }

    /// Temporarily replaces the production drawing gate with a wrapper that
    /// disarms the real gate and then reports failure. The original function is
    /// restored on both success and error paths; the real map/core is never
    /// permanently broken for later async callbacks.
    private func withTemporaryDrawingModeFailure(_ web: WKWebView,
                                                 _ body: @MainActor () async throws -> Void) async throws {
        let installed = try await web.callAsyncJavaScript(Self.installFailingDrawingModeScript,
            arguments: [:], in: nil, contentWorld: .page)
        guard (installed as? Bool) == true else {
            throw NSError(domain: "OfficeNativeDrawingQualification", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "the temporary drawing failure wrapper could not be installed"
            ])
        }
        do {
            try await body()
        } catch {
            _ = try? await web.callAsyncJavaScript(Self.restoreDrawingModeScript,
                arguments: [:], in: nil, contentWorld: .page)
            throw error
        }
        let restored = try await web.callAsyncJavaScript(Self.restoreDrawingModeScript,
            arguments: [:], in: nil, contentWorld: .page)
        guard (restored as? Bool) == true else {
            throw NSError(domain: "OfficeNativeDrawingQualification", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "the production drawing gate was not restored"
            ])
        }
    }

    private static let installFailingDrawingModeScript = #"""
    if (typeof window.__floeSetOfficeDrawingMode !== 'function')
        throw new Error('production drawing gate unavailable');
    if (window.__floeOriginalOfficeDrawingMode)
        throw new Error('temporary drawing failure already installed');
    window.__floeOriginalOfficeDrawingMode = window.__floeSetOfficeDrawingMode;
    window.__floeSetOfficeDrawingMode = function (enabled) {
        const original = window.__floeOriginalOfficeDrawingMode;
        if (typeof original !== 'function') throw new Error('original drawing gate missing');
        original(false);
        return false;
    };
    return true;
    """#

    private static let restoreDrawingModeScript = #"""
    if (typeof window.__floeOriginalOfficeDrawingMode !== 'function') return false;
    window.__floeSetOfficeDrawingMode = window.__floeOriginalOfficeDrawingMode;
    delete window.__floeOriginalOfficeDrawingMode;
    return true;
    """#

    private func mount(_ session: OfficeFileSession, in scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene); window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(rootView: OfficeDocumentSurface(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity))
        window.windowLevel = .normal + 1; window.makeKeyAndVisible()
        return window
    }

    private func wait(_ seconds: TimeInterval, _ stage: String, _ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        guard ready() else { throw NSError(domain: "OfficeNativeDrawingQualification", code: 1,
                                          userInfo: [NSLocalizedDescriptionKey: "Timed out: \(stage)"]) }
    }

    private func waitForPaint(_ controller: FloeOfficeNativeViewController) async throws {
        try await wait(45, "native decoded tile/vector paint") {
            let facts = OfficeFileSession.hostRenderDiagnostics(controller)
            return facts["stage"] == "visible-render" && facts["docLoaded"] == "1"
                && ((Int(facts["decodedTiles"] ?? "") ?? 0) > 0 || facts["vectorRendering"] == "1")
        }
    }

    private func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private func attach(_ url: URL, name: String) {
        let attachment = XCTAttachment(contentsOfFile: url); attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
    }

    private func package(_ url: URL, format: String) throws -> DrawingQualificationXML {
        let archive = try Archive(url: url, accessMode: .read)
        let result = DrawingQualificationXML()
        for entry in archive where entry.path.hasSuffix(".xml") {
            let p = entry.path
            guard p == "word/document.xml" || p.hasPrefix("xl/worksheets/") || p == "xl/sharedStrings.xml"
                || p.hasPrefix("xl/drawings/drawing") || p.hasPrefix("ppt/slides/slide") || p.hasPrefix("ppt/notesSlides/notesSlide") else { continue }
            var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }
            let parser = XMLParser(data: bytes); parser.shouldResolveExternalEntities = false
            parser.shouldProcessNamespaces = true; parser.delegate = result
            guard parser.parse() else { throw parser.parserError ?? NSError(domain: "DrawingOOXML", code: 2) }
        }
        return result
    }
}

/// Independent saved-package XML inspection, no product reader or shape insertion.
private final class DrawingQualificationXML: NSObject, XMLParserDelegate {
    var text = "", cells: [String: String] = [:], formulas: [String: String] = [:]
    var customGeometryPaths: [String] = [], customGeometryPointCounts: [Int] = []
    struct VectorShape: CustomStringConvertible {
        var depth: Int, spPrDepth: Int?, paths: [String] = []
        var widthEMU: Int?, colorHex: String?
        /// `a:ln/a:solidFill/a:srgbClr/a:alpha@val`, in 1/1000 percent
        /// (100000 = fully opaque). Absent for an opaque line whose fill
        /// carries no explicit alpha element.
        var alphaValue: Int?
        /// Native filled-ellipse dot support: `spPr/a:prstGeom@prst`
        /// (e.g. "ellipse"), the shape's own `spPr/a:solidFill` colour/alpha,
        /// an explicit `spPr/a:ln/a:noFill` outline marker and the `a:ext`
        /// size in EMU. A filled zero-motion dot carries these instead of
        /// `a:ln` stroke attributes and must never be forced into the
        /// line-width shape model.
        var prstGeometry: String?
        var fillColorHex: String?
        var fillAlphaValue: Int?
        var lineIsNoFill = false
        var extentEMU: [Int]?
        var spFillDepth: Int?
        /// The shape's own `spPr/a:xfrm` placement, canonicalized for an
        /// exact before/after comparison. This is the presentation anchor and
        /// the spreadsheet shape frame, never the surrounding xdr anchor.
        var placement: String?
        /// The enclosing spreadsheet-drawing anchor, canonicalized. Text and
        /// presentation shapes have no xdr anchor.
        var anchor: String?
        var xfrmDepth: Int?
        var xfrmOffset: String?
        var xfrmExtent: String?
        var description: String { "vector(color=\(colorHex ?? "missing"), widthEMU=\(widthEMU ?? -1), alpha=\(alphaValue.map(String.init) ?? "none"), paths=\(paths.count), prst=\(prstGeometry ?? "none"), fillColor=\(fillColorHex ?? "none"), fillAlpha=\(fillAlphaValue.map(String.init) ?? "none"), lineNoFill=\(lineIsNoFill), extent=\(extentEMU.map { "\($0)" } ?? "none"))" }
    }
    var vectorShapes: [VectorShape] = []
    private var activeShapes: [VectorShape] = []
    private let drawingNamespaces: Set<String> = ["http://schemas.openxmlformats.org/drawingml/2006/main", "http://purl.oclc.org/ooxml/drawingml/main"]
    private let shapeNamespaces: Set<String> = [
        "http://schemas.openxmlformats.org/presentationml/2006/main", "http://purl.oclc.org/ooxml/presentationml/main",
        "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing", "http://purl.oclc.org/ooxml/drawingml/spreadsheetDrawing",
        "http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
    ]
    var validAnchors = 0
    private var inCustom = false, inPath = false, path = "", pointCount = 0
    private var cell = "", field = "", buffer = ""
    private var anchorKind: String?, anchorFields: [String: Int] = [:]
    private var elements: [String] = [], elementNamespaces: [String?] = [], anchorDepth = 0
    private var anchorNamespace: String?
    private var wordAnchorDepth: Int?
    private var wordAnchorFields: [String: String] = [:]
    private let wordDrawingNamespaces: Set<String> = [
        "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing",
        "http://purl.oclc.org/ooxml/drawingml/wordprocessingDrawing"
    ]

    private let spreadsheetDrawingNamespaces: Set<String> = [
        "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing",
        "http://purl.oclc.org/ooxml/drawingml/spreadsheetDrawing"
    ]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let local = String(name.split(separator: ":").last ?? "")
        elements.append(local); elementNamespaces.append(namespaceURI)
        if local == "anchor", wordDrawingNamespaces.contains(namespaceURI ?? "") {
            wordAnchorDepth = elements.count; wordAnchorFields = [:]
        }
        if let depth = wordAnchorDepth, elements.count == depth + 1,
           ["positionH", "positionV"].contains(local), wordDrawingNamespaces.contains(namespaceURI ?? "") {
            wordAnchorFields[local + ".relativeFrom"] = attributes["relativeFrom"]
        }

        if (local == "sp" || local == "wsp"), shapeNamespaces.contains(namespaceURI ?? "") {
            activeShapes.append(VectorShape(depth: elements.count, spPrDepth: nil))
        }
        if let last = activeShapes.indices.last {
            if local == "spPr", elements.count == activeShapes[last].depth + 1,
               namespaceURI == elementNamespaces[activeShapes[last].depth - 1] {
                activeShapes[last].spPrDepth = elements.count
            }
            if let properties = activeShapes[last].spPrDepth, elements.count >= properties,
               elements[properties - 1] == "spPr" {
                if local == "ln", elements.count == properties + 1, drawingNamespaces.contains(namespaceURI ?? "") {
                    activeShapes[last].widthEMU = Int(attributes["w"] ?? "")
                }
                // A filled native dot is identified by its own spPr parts,
                // never by an inferred line width: prstGeom preset, the direct
                // spPr solidFill colour (and optional alpha) and an explicit
                // a:ln/a:noFill. These are exactly the direct spPr children
                // the verified exporter writes for a no-outline filled circle.
                if local == "prstGeom", elements.count == properties + 1,
                   drawingNamespaces.contains(namespaceURI ?? "") {
                    activeShapes[last].prstGeometry = attributes["prst"]
                }
                if local == "noFill", elements.count == properties + 2,
                   elements[properties] == "ln",
                   drawingNamespaces.contains(namespaceURI ?? ""),
                   drawingNamespaces.contains(elementNamespaces[properties] ?? "") {
                    activeShapes[last].lineIsNoFill = true
                }
                if local == "solidFill", elements.count == properties + 1,
                   drawingNamespaces.contains(namespaceURI ?? "") {
                    activeShapes[last].spFillDepth = elements.count
                }
                if let fillDepth = activeShapes[last].spFillDepth,
                   elements.count == fillDepth + 1,
                   elements[fillDepth - 1] == "solidFill",
                   local == "srgbClr", drawingNamespaces.contains(namespaceURI ?? "") {
                    activeShapes[last].fillColorHex = attributes["val"]
                }
                if let fillDepth = activeShapes[last].spFillDepth,
                   elements.count == fillDepth + 2,
                   elements[fillDepth - 1] == "solidFill",
                   elements[fillDepth] == "srgbClr",
                   local == "alpha", drawingNamespaces.contains(namespaceURI ?? "") {
                    activeShapes[last].fillAlphaValue = Int(attributes["val"] ?? "")
                }
                // Only shape/spPr/a:ln/a:solidFill/a:srgbClr can establish
                // this path's line color. Text runs and shape fills never do.
                if local == "srgbClr", elements.count == properties + 3,
                   elements[properties] == "ln", elements[properties + 1] == "solidFill",
                   drawingNamespaces.contains(namespaceURI ?? ""),
                   drawingNamespaces.contains(elementNamespaces[properties] ?? ""),
                   drawingNamespaces.contains(elementNamespaces[properties + 1] ?? "") {
                    activeShapes[last].colorHex = attributes["val"]
                }
                // Line transparency is saved as an explicit alpha on the same
                // line colour. Only this shape/spPr/a:ln/a:solidFill/a:srgbClr
                // path may set it; fill/text alpha never does.
                if local == "alpha", elements.count == properties + 4,
                   elements[properties] == "ln", elements[properties + 1] == "solidFill",
                   elements[properties + 2] == "srgbClr",
                   drawingNamespaces.contains(namespaceURI ?? ""),
                   drawingNamespaces.contains(elementNamespaces[properties] ?? ""),
                   drawingNamespaces.contains(elementNamespaces[properties + 1] ?? ""),
                   drawingNamespaces.contains(elementNamespaces[properties + 2] ?? "") {
                    activeShapes[last].alphaValue = Int(attributes["val"] ?? "")
                }
                // The shape's own a:xfrm is the presentation placement and the
                // per-anchor shape frame in a spreadsheet drawing. It is the
                // direct child of this spPr; nested xfrm elements never count.
                if local == "xfrm", elements.count == properties + 1,
                   drawingNamespaces.contains(namespaceURI ?? "") {
                    activeShapes[last].xfrmDepth = elements.count
                    activeShapes[last].xfrmOffset = nil
                    activeShapes[last].xfrmExtent = nil
                }
                if let xfrmDepth = activeShapes[last].xfrmDepth,
                   elements.count == xfrmDepth + 1,
                   elements[xfrmDepth - 1] == "xfrm",
                   drawingNamespaces.contains(namespaceURI ?? "") {
                    if local == "off" {
                        activeShapes[last].xfrmOffset =
                            "x=\(attributes["x"] ?? "");y=\(attributes["y"] ?? "")"
                    }
                    if local == "ext" {
                        activeShapes[last].xfrmExtent =
                            "cx=\(attributes["cx"] ?? "");cy=\(attributes["cy"] ?? "")"
                        activeShapes[last].extentEMU = [Int(attributes["cx"] ?? "") ?? -1,
                                                        Int(attributes["cy"] ?? "") ?? -1]
                    }
                }
            }
        }
        if local == "custGeom" { inCustom = true }
        if inCustom && local == "path" { inPath = true; path = ""; pointCount = 0 }
        if inPath {
            path += name + attributes.keys.sorted().map { " \($0)=\(attributes[$0]!)" }.joined() + ";"
            if local == "pt" { pointCount += 1 }
        }
        if ["twoCellAnchor", "oneCellAnchor", "absoluteAnchor"].contains(local),
           spreadsheetDrawingNamespaces.contains(namespaceURI ?? "") {
            anchorKind = local; anchorFields = [:]; anchorDepth = elements.count; anchorNamespace = namespaceURI
        }
        // Shape a:xfrm/a:ext is not an anchor extent. Only direct children
        // of the current xdr anchor may establish its size or absolute origin.
        if anchorKind != nil, elements.count == anchorDepth + 1, namespaceURI == anchorNamespace {
            if local == "ext" {
                anchorFields["cx"] = Int(attributes["cx"] ?? "")
                anchorFields["cy"] = Int(attributes["cy"] ?? "")
            }
            if local == "pos" {
                anchorFields["x"] = Int(attributes["x"] ?? "")
                anchorFields["y"] = Int(attributes["y"] ?? "")
            }
        }
        if local == "c" { cell = attributes["r"] ?? "" }
        field = local; buffer = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer += string
        if field == "t" { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = String(name.split(separator: ":").last ?? "")
        if inPath && local == "path" {
            customGeometryPaths.append(path); customGeometryPointCounts.append(pointCount)
            if let last = activeShapes.indices.last, let properties = activeShapes[last].spPrDepth,
               elements.count > properties, elements[properties - 1] == "spPr", elements[properties] == "custGeom",
               drawingNamespaces.contains(elementNamespaces[properties] ?? "") {
                activeShapes[last].paths.append(path)
            }
            inPath = false
        }
        if local == "custGeom" { inCustom = false }
        if local == "v", !cell.isEmpty { cells[cell] = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
        if local == "f", !cell.isEmpty { formulas[cell] = buffer.trimmingCharacters(in: .whitespacesAndNewlines) }
        if local == "c" { cell = "" }
        if anchorKind != nil, elements.count == anchorDepth + 2,
           namespaceURI == anchorNamespace, elementNamespaces[elements.count - 2] == anchorNamespace,
           ["row", "col", "rowOff", "colOff"].contains(local),
           let parent = elements.dropLast().last, parent == "from" || parent == "to" {
            anchorFields[parent + "." + local] = Int(buffer.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if local == anchorKind, elements.count == anchorDepth {
            if anchorIsValid() { validAnchors += 1 }
            anchorKind = nil; anchorDepth = 0; anchorNamespace = nil
        }

        if let depth = wordAnchorDepth, elements.count == depth + 2, local == "posOffset",
           wordDrawingNamespaces.contains(namespaceURI ?? ""),
           let axis = elements.dropLast().last, ["positionH", "positionV"].contains(axis),
           let offset = Int(buffer.trimmingCharacters(in: .whitespacesAndNewlines)) {
            wordAnchorFields[axis + ".offset"] = String(offset)
        }
        if let last = activeShapes.last, last.depth == elements.count {
            var finished = last
            if let offset = finished.xfrmOffset, let extent = finished.xfrmExtent {
                finished.placement = offset + ";" + extent
            }
            if let kind = anchorKind, !anchorFields.isEmpty {
                finished.anchor = kind + ":" + anchorFields.keys.sorted()
                    .map { "\($0)=\(anchorFields[$0]!)" }.joined(separator: ",")
            }

            if wordAnchorDepth != nil,
               wordAnchorFields["positionH.offset"] != nil, wordAnchorFields["positionV.offset"] != nil {
                finished.anchor = "word-anchor:" + wordAnchorFields.keys.sorted()
                    .map { "\($0)=\(wordAnchorFields[$0]!)" }.joined(separator: ",")
            }
            let carriesCustomPath = !finished.paths.isEmpty
            let isFilledPresetShape = finished.prstGeometry != nil && finished.fillColorHex != nil
            if carriesCustomPath || isFilledPresetShape { vectorShapes.append(finished) }
            activeShapes.removeLast()
        }

        if local == "anchor", wordAnchorDepth == elements.count,
           wordDrawingNamespaces.contains(namespaceURI ?? "") {
            wordAnchorDepth = nil; wordAnchorFields = [:]
        }
        elements.removeLast(); elementNamespaces.removeLast()
        field = ""; buffer = ""
    }

    private func anchorIsValid() -> Bool {
        func marker(_ side: String) -> Bool {
            ["col", "colOff", "row", "rowOff"].allSatisfy {
                guard let value = anchorFields[side + "." + $0] else { return false }
                return value >= 0
            }
        }
        func increases(_ cell: String, _ offset: String) -> Bool {
            guard let start = anchorFields["from." + cell], let end = anchorFields["to." + cell],
                  let startOffset = anchorFields["from." + offset], let endOffset = anchorFields["to." + offset] else { return false }
            return end > start || (end == start && endOffset > startOffset)
        }
        let extent = (anchorFields["cx"] ?? 0) > 0 && (anchorFields["cy"] ?? 0) > 0
        switch anchorKind {
        case "twoCellAnchor": return marker("from") && marker("to") && increases("col", "colOff") && increases("row", "rowOff")
        case "oneCellAnchor": return marker("from") && extent
        case "absoluteAnchor":
            guard let x = anchorFields["x"], let y = anchorFields["y"] else { return false }
            return x >= 0 && y >= 0 && extent
        default: return false
        }
    }
}
#endif
