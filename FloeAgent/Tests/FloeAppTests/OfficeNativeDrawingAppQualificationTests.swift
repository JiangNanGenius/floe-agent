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
    func testXLSXControlledStaleShapeHandleSelectionReplayStillDraws() async throws {
        try await exerciseStaleShapeHandleReplay("xlsx")
    }
    func testPPTXControlledStaleShapeHandleSelectionReplayStillDraws() async throws {
        try await exerciseStaleShapeHandleReplay("pptx")
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
        var description: String { "vector(color=\(colorHex ?? "missing"), widthEMU=\(widthEMU ?? -1), alpha=\(alphaValue.map(String.init) ?? "none"), paths=\(paths.count))" }
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
    private let spreadsheetDrawingNamespaces: Set<String> = [
        "http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing",
        "http://purl.oclc.org/ooxml/drawingml/spreadsheetDrawing"
    ]

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let local = String(name.split(separator: ":").last ?? "")
        elements.append(local); elementNamespaces.append(namespaceURI)
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
        if let last = activeShapes.last, last.depth == elements.count {
            var finished = last
            if let offset = finished.xfrmOffset, let extent = finished.xfrmExtent {
                finished.placement = offset + ";" + extent
            }
            if let kind = anchorKind, !anchorFields.isEmpty {
                finished.anchor = kind + ":" + anchorFields.keys.sorted()
                    .map { "\($0)=\(anchorFields[$0]!)" }.joined(separator: ",")
            }
            if !finished.paths.isEmpty { vectorShapes.append(finished) }
            activeShapes.removeLast()
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
