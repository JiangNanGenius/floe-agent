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
                switch preset {
                case .highlighter:
                    XCTAssertTrue(matching.contains { shape in
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
                "hitDiagnostics": "bounded tag/id/class/ownership, hit coordinates, overlay census, previous-stroke probe and contact lifecycle; no page text",
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
            return {
                sectionFound:true,
                sectionName: bounded(definition.name, 48),
                shown: section.showSection === true,
                subSectionCount: Array.isArray(properties.subSections)
                    ? Math.min(properties.subSections.length, 32) : null,
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
    // Actual time from the previous contact's up to this down, including the
    // script's own pre-down probes. This is evidence, not the intended sleep.
    const strokeStart = performance.now();
    const elapsedSincePreviousStrokeMilliseconds = typeof window.__floePenLastStrokeEnd === 'number'
        ? round2(strokeStart - window.__floePenLastStrokeEnd) : null;
    const canvasSectionBeforeDown = canvasSectionName();
    post('down', points[0], 1);
    const downAccepted = contacts[0].activeAfter === true;
    const canvasSectionAtDown = canvasSectionName();
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
            if !last.paths.isEmpty { vectorShapes.append(last) }
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
