// SPDX-License-Identifier: MPL-2.0
// Actual App drawing mode/settings -> synthetic pen PointerEvents -> real frontend/core -> saved
// vector OOXML -> native reopen. NOT physical Apple Pencil/pointer acceptance.
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
            // Keep mode armed across both strokes: toggling between them would
            // hide the production bridge's consecutive-stroke rearm defects.
            session.useInkPreferences(workspaceIdentity: root.path, documentKey: source.lastPathComponent)
            let preferences = session.inkPreferences
            let previousStroke = preferences.stroke
            defer {
                preferences.setColorHex(previousStroke.colorHex)
                preferences.setWidthMillimeters(previousStroke.widthMillimeters)
                preferences.setTransparencyPercent(previousStroke.transparencyPercent)
            }
            let expectedStyles = [OfficeInkStroke(colorHex: "#FF0000", widthMillimeters: 0.4),
                                  OfficeInkStroke(colorHex: "#0000FF", widthMillimeters: 1.2)]
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode)
            var penReceipts: [[String: Any]] = []
            for index in 0..<10 {
                // Same per-document setters and App reapply action as the pen
                // panel; preserve drawing mode across contacts and style changes.
                let expected = expectedStyles[index < 5 ? 0 : 1]
                if index == 0 || index == 5 {
                    preferences.setColorHex(expected.colorHex)
                    preferences.setWidthMillimeters(expected.widthMillimeters)
                    preferences.setTransparencyPercent(0)
                    await session.applyInkPreferences()
                    guard session.inkError == nil else { throw NSError(domain: "OfficeNativeDrawingQualification", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: session.inkError ?? "App ink attributes unavailable"]) }
                }
                // Alternate short and long inter-contact delays. Keep mode on
                // across all ten contacts and change attributes after stroke 5.
                try await Task.sleep(nanoseconds: index.isMultiple(of: 2) ? 30_000_000 : 350_000_000)
                let sent = try await receiveStroke(index, web: web, native: native, window: window, root: root, syntheticSource: source)
                XCTAssertEqual(sent["strokeDelta"] as? Int, 1, "Actual pen bridge did not finish the stroke")
                XCTAssertGreaterThanOrEqual(sent["coreEventDelta"] as? Int ?? 0, 5, "Actual pen bridge did not forward all events")
                XCTAssertEqual(sent["activeAfter"] as? Bool, false)
                penReceipts.append(sent)
            }
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
            for style in expectedStyles {
                let expectedEMU = style.lineWidthValue * 360
                let color = String(style.colorHex.dropFirst()).uppercased()
                XCTAssertTrue(result.vectorShapes.contains { shape in
                    shape.colorHex?.uppercased() == color
                        && shape.widthEMU.map { abs($0 - expectedEMU) <= 635 } == true
                        && !shape.paths.isEmpty
                }, "Actual saved vector shape did not retain \(color) / \(expectedEMU) EMU: \(result.vectorShapes)")
            }
            if format == "xlsx" {
                XCTAssertEqual(result.cells["B2"], "12", "Excel basic value lost")
                XCTAssertEqual(result.formulas["B3"], "B2*2", "Excel formula lost or flattened")
                XCTAssertGreaterThanOrEqual(result.validAnchors, 10, "Excel strokes need nonzero visible sheet anchors")
            }
            if format == "pptx" { XCTAssertTrue(result.text.contains("DRAWING-NOTES-KEEP"), "Speaker notes lost") }
            let manifest: [String: Any] = [
                "format": format, "sourceSHA256": sourceHash, "outputSHA256": try hash(copy),
                "route": "OfficeFileSession.toggleDrawing/applyInkPreferences/pen-PointerEvent/production-DOM-MouseEvent/frontend-core/exportDocument",
                "hardwarePointerInput": "not-tested", "pressure": "not-tested",
                "syntheticPenBridgeReceipts": penReceipts,
                "expectedLineStyles": expectedStyles.map { ["color": $0.colorHex, "widthEMU": $0.lineWidthValue * 360] as [String: Any] },
                "savedVectorLineStyles": result.vectorShapes.map { ["color": $0.colorHex ?? "MISSING", "widthEMU": $0.widthEMU ?? -1, "paths": $0.paths.count] as [String: Any] },
                "lineWidthToleranceEMU": 635,
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
                               root: URL, syntheticSource: URL) async throws -> [String: Any] {
        var resultType = "not-returned"
        var jsonByteCount: Int?
        var stage = "call-actual-pen-bridge"
        do {
            let receipt: Any? = try await web.callAsyncJavaScript(Self.strokeScript,
                arguments: ["strokeID": index, "probeEnabled": ProcessInfo.processInfo.environment["FLOE_A3_PROBE"] == "1"], in: nil, contentWorld: .page)
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
    return JSON.stringify({socketObservation:window.__floePenSocketQualification || null,
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
    const y = .25 + strokeID * .045;
    const fractions = [[.28,y],[.37 + strokeID*.005,y-.02],[.47,y+.02+strokeID*.002],[.57+strokeID*.003,y]];
    const points = fractions.map(([x,y]) => [x1 + x * (x2-x1), y1 + y * (y2-y1)]);
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
    const post = (type, p, buttons) => canvas.dispatchEvent(new PointerEvent(type, {
        bubbles:true, cancelable:true, composed:true, pointerType:'pen', pointerId:41 + strokeID,
        isPrimary:true, clientX:p[0], clientY:p[1], button:0, buttons, pressure: buttons ? .5 : 0
    }));
    post('pointerdown', points[0], 1);
    for (let i = 1; i < points.length; i++) {
        await new Promise(resolve => setTimeout(resolve, 25));
        post('pointermove', points[i], 1);
    }
    post('pointerup', points[points.length - 1], 0);
    const after = window.__floeOfficePenState();
    const strokeDelta = after.strokes - before.strokes, coreEventDelta = after.coreEvents - before.coreEvents;
    if (strokeDelta !== 1 || coreEventDelta < points.length + 1 || after.activeStroke)
        throw new Error('production pen bridge did not forward/finish synthetic stroke');
    return JSON.stringify({strokeID, strokeDelta, coreEventDelta, activeAfter:after.activeStroke,
        before, after, canvasRect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},
        visibleDocumentRect:{x1,y1,x2,y2}, clientPoints:points,
        hardwarePointerInput:'not-tested', pressure:'synthetic-not-hardware-tested',
        socketObservation:observation.finish()});
    } finally { observation.finish(); }
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
        var description: String { "vector(color=\(colorHex ?? "missing"), widthEMU=\(widthEMU ?? -1), paths=\(paths.count))" }
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
