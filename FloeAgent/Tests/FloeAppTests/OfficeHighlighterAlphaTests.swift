// SPDX-License-Identifier: MPL-2.0
// Focused real-App regression for the reported Office highlighter defect:
// a transparent 4.0 mm / 60% highlighter stroke must not paint a rectangular
// white background over the document's colored background, text or grid.
//
// One shared body covers the Word control and the user's Excel/XLSX case. It
// builds its own synthetic DOCX/XLSX (no user attachment bytes), opens the
// document through the REAL OfficeFileSession/FloeOfficeNative production
// editor, dispatches REAL Pen PointerEvents through the production Pencil
// gate, snapshots the live WKWebView, saves through the production export,
// reopens the saved copy and repeats the pixel checks. It deliberately does
// not use a mocked UNO engine or an SVG-only preview as evidence.
//
// The test is opt-in on the canonical iPad Simulator:
//   FLOE_OFFICE_HIGHLIGHTER_ALPHA_QUALIFICATION=1
// It is not a physical-Apple-Pencil/device claim; root owns that acceptance.
//
// This file is already an explicit FloeAppTests project.yml member; adding the
// XLSX selector needs no project regeneration or new test file.

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
final class OfficeHighlighterAlphaTests: XCTestCase {
    private static let qualificationEnvironment = "FLOE_OFFICE_HIGHLIGHTER_ALPHA_QUALIFICATION"
    private static func isFixtureBlue(_ r: Int, _ g: Int, _ b: Int) -> Bool {
        // The fixture's table shading is #DCEBFF. Leave enough tolerance for
        // the engine's color management and anti-aliased cell edges, while
        // excluding white (r=255) and the UI's neutral chrome.
        r >= 200 && r <= 244 && g >= 222 && g <= 252 && b >= 238
            && b - r >= 12 && b - g >= 4
    }

    /// U path inside the shaded cell. The top horizontal segment intentionally
    /// crosses the cell's first text line; the geometric center stays empty so
    /// a white bounding-box fill is visible as a center/background change.
    private static var strokeFractions: [(Double, Double)] {
        [
            (0.18, 0.12), (0.50, 0.12), (0.82, 0.12),
            (0.82, 0.45), (0.82, 0.78),
            (0.50, 0.78), (0.18, 0.78),
            (0.18, 0.45), (0.18, 0.60)
        ]
    }

    /// U path inside the large XLSX C3 cell. The 10%/90% edges leave a wide
    /// interior for the predeclared non-stroke patches, while the top segment
    /// crosses the wrapped bold cell text. This is the intended polyline; the
    /// dense real contact below is interpolated from it.
    private static let xlsxStrokeFractions: [(Double, Double)] = [
        (0.10, 0.10), (0.50, 0.10), (0.90, 0.10),
        (0.90, 0.50), (0.90, 0.90),
        (0.50, 0.90), (0.10, 0.90),
        (0.10, 0.55), (0.10, 0.45)
    ]

    private enum AlphaFixtureFormat: String, Equatable {
        case docx
        case xlsx
    }

    private func strokeFractions(for format: AlphaFixtureFormat) -> [(Double, Double)] {
        format == .docx ? Self.strokeFractions : Self.xlsxStrokeFractions
    }

    /// One real App run covering:
    ///  - live snapshot before the stroke,
    ///  - a saved control copy with no ink,
    ///  - a real 4.0 mm / 60% highlighter U-stroke through the production
    ///    Pencil bridge,
    ///  - an actual WK snapshot while the SAME contact is still down and the
    ///    production live preview is active (the reported white box may appear
    ///    before lift),
    ///  - the contact's single lift, then the retired-preview/core snapshot,
    ///  - the final saved copy reopened by the production engine,
    ///  - pixel checks over the stroke's colored cell in the while-down,
    ///    retired-preview and reopened surfaces.
    func testHighlighterAlphaPreservesColoredBackgroundTextAndGridLiveAndReopened() async throws {
        try await run(.docx)
    }

    func testXLSXHighlighterAlphaPreservesColoredCellTextAndGridLiveAndReopened() async throws {
        try await run(.xlsx)
    }

    /// Private, opt-in reproduction input. Attachment bytes are supplied only
    /// through the local xctestrun environment and never committed as fixtures.
    /// This captures the real opened/editable/armed document; it is diagnosis,
    /// not a passing assertion that the reported white rectangle is repaired.
    func testProvidedWorkbookDisplayDiagnostic() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment[Self.qualificationEnvironment] == "1",
              let encoded = environment["FLOE_OFFICE_PRIVATE_WORKBOOK_BASE64"],
              let expected = environment["FLOE_OFFICE_PRIVATE_WORKBOOK_SHA256"] else {
            throw XCTSkip("Private workbook diagnostic requires explicit local input")
        }
        executionTimeAllowance = 420
        let data = try XCTUnwrap(Data(base64Encoded: encoded))
        XCTAssertLessThanOrEqual(data.count, 512 * 1024)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, expected, "Private reproduction input digest mismatch")
        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent(
            "Qualification/OfficeProvidedWorkbook-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = root.appendingPathComponent("provided.xlsx")
        try data.write(to: fixture, options: .atomic)
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 51, userInfo: [
                NSLocalizedDescriptionKey: "No foreground scene for private reproduction"])
        }
        let previous = scene.windows.first(where: \.isKeyWindow)
        let session = OfficeFileSession()
        let window = mount(session, in: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
        }
        var receipt: [String: Any] = [
            "purpose": "Private actual-workbook display diagnosis; no fix acceptance claim",
            "inputSHA256": digest,
            "inputBytes": data.count,
            "physicalPencil": "not-tested"
        ]
        defer { try? writeReceipt(receipt, root: root) }
        do {
            await session.open(fixture)
            try await wait(120, "provided workbook native open") {
                session.canAct && session.documentActionsReady && session.controller != nil
            }
            var native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            var web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            try await Task.sleep(for: .milliseconds(450))
            _ = try await snapshot(web, root: root, name: "provided-opened")
            receipt["openedPaint"] = OfficeFileSession.hostRenderDiagnostics(native)
            if session.readOnly {
                let accepted = await session.requestEditing()
                XCTAssertTrue(accepted, "Actual workbook could not enter its isolated editor")
            }
            try await wait(150, "provided workbook editable") {
                !session.readOnly && session.canAct && session.documentActionsReady
                    && session.controller != nil
            }
            native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            try await Task.sleep(for: .milliseconds(450))
            _ = try await snapshot(web, root: root, name: "provided-editable")
            session.useInkPreferences(workspaceIdentity: root.path, documentKey: "provided.xlsx")
            session.inkPreferences.setPreset(.highlighter)
            session.inkPreferences.setColorHex("#FFCC00")
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode)
            await session.applyInkPreferences()
            XCTAssertNil(session.inkError)
            try await Task.sleep(for: .milliseconds(450))
            _ = try await snapshot(web, root: root, name: "provided-highlighter-armed")
            receipt["armedPreview"] = try await currentPreviewState(web)
            if environment["FLOE_OFFICE_PRIVATE_DRAW_DIAGNOSTIC"] == "1" {
                let geometry = try await geometryProbe(web)
                let rect = geometry.canvasRect
                let fractions: [(Double, Double)] = [
                    (0.25, 0.64), (0.65, 0.64), (0.65, 0.86),
                    (0.25, 0.86), (0.25, 0.72)
                ]
                let points = fractions.map { point in [
                    Double(rect.minX) + Double(rect.width) * point.0,
                    Double(rect.minY) + Double(rect.height) * point.1
                ] }
                let dense = try densified(points)
                receipt["diagnosticPointsCSS"] = points
                let gridBefore = try await snapshot(web, root: root, name: "provided-grid-before-stroke")
                receipt["diagnosticBegin"] = try await strokePhase(web, phase: "begin", points: dense)
                do {
                    let contact = try await snapshot(web, root: root, name: "provided-grid-contact")
                    let metrics = try providedGridRetention(before: gridBefore, after: contact, points: points)
                    receipt["contactGridRetention"] = metrics
                    XCTAssertGreaterThanOrEqual(metrics["retainedFraction"] as? Double ?? 0, 0.95,
                                                "Grid lines disappeared during contact")
                } catch {
                    _ = try? await strokePhase(web, phase: "cleanup", points: dense)
                    throw error
                }
                let lifted = try await strokePhase(web, phase: "lift", points: dense)
                receipt["diagnosticLift"] = lifted
                XCTAssertEqual(lifted["strokeDelta"] as? Int, 1)
                XCTAssertEqual(lifted["activeAfter"] as? Bool, false)
                _ = try await snapshot(web, root: root, name: "provided-grid-after-lift",
                                       afterScreenUpdates: false)
                let firstRetired = try await waitForPreviewRetirement(web, timeout: 8)
                receipt["diagnosticSettledPreview"] = firstRetired
                XCTAssertEqual(firstRetired["livePreview"] as? Bool, false)
                XCTAssertEqual(firstRetired["lastPreviewClear"] as? String, "painted")
                let settled = try await snapshot(web, root: root, name: "provided-grid-settled")
                let retention = try providedGridRetention(before: gridBefore, after: settled, points: points)
                receipt["settledGridRetention"] = retention
                XCTAssertGreaterThanOrEqual(retention["retainedFraction"] as? Double ?? 0, 0.95,
                                            "Post-lift repaint erased the empty-cell grid")
                let firstYellow = providedNewHighlighterPixels(before: gridBefore, after: settled, points: points)
                receipt["firstNewHighlighterPixels"] = firstYellow
                XCTAssertGreaterThan(firstYellow, 300, "The engine must actually display the committed stroke")
                // A second equal-sized group in another row band must not
                // inherit the first buffer's alpha or erase either region.
                let secondPoints = points.map { [$0[0], $0[1] - Double(rect.height) * 0.28] }
                let secondDense = try densified(secondPoints)
                let secondBefore = try await snapshot(web, root: root, name: "provided-grid-second-before")
                receipt["secondDiagnosticPointsCSS"] = secondPoints
                receipt["secondDiagnosticBegin"] = try await strokePhase(web, phase: "begin", points: secondDense)
                do {
                    let secondContact = try await snapshot(web, root: root, name: "provided-grid-second-contact")
                    let contactRetention = try providedGridRetention(before: secondBefore, after: secondContact, points: secondPoints)
                    receipt["secondContactGridRetention"] = contactRetention
                    XCTAssertGreaterThanOrEqual(contactRetention["retainedFraction"] as? Double ?? 0, 0.95)
                } catch {
                    _ = try? await strokePhase(web, phase: "cleanup", points: secondDense)
                    throw error
                }
                let secondLift = try await strokePhase(web, phase: "lift", points: secondDense)
                receipt["secondDiagnosticLift"] = secondLift
                XCTAssertEqual(secondLift["strokeDelta"] as? Int, 1)
                XCTAssertEqual(secondLift["activeAfter"] as? Bool, false)
                let secondRetired = try await waitForPreviewRetirement(web, timeout: 8)
                receipt["secondSettledPreview"] = secondRetired
                XCTAssertEqual(secondRetired["livePreview"] as? Bool, false)
                XCTAssertEqual(secondRetired["lastPreviewClear"] as? String, "painted")
                let secondSettled = try await snapshot(web, root: root, name: "provided-grid-second-settled")
                let secondRetention = try providedGridRetention(before: secondBefore, after: secondSettled, points: secondPoints)
                receipt["secondSettledGridRetention"] = secondRetention
                XCTAssertGreaterThanOrEqual(secondRetention["retainedFraction"] as? Double ?? 0, 0.95)
                let secondYellow = providedNewHighlighterPixels(before: secondBefore, after: secondSettled, points: secondPoints)
                receipt["secondNewHighlighterPixels"] = secondYellow
                XCTAssertGreaterThan(secondYellow, 300, "The second committed stroke must remain visible")
                let firstStillRetained = try providedGridRetention(before: gridBefore, after: secondSettled, points: points)
                receipt["firstGridAfterSecondStroke"] = firstStillRetained
                XCTAssertGreaterThanOrEqual(firstStillRetained["retainedFraction"] as? Double ?? 0, 0.95)
                try await session.toggleDrawing()
                let exported = try await session.exportDocument(format: "xlsx")
                let copy = root.appendingPathComponent("provided-with-diagnostic-stroke.xlsx")
                try fm.copyItem(at: exported, to: copy)
                attach(copy, name: "provided-with-diagnostic-stroke")
                receipt["diagnosticExportSHA256"] = try hash(copy)
            }
            XCTAssertEqual(try hash(fixture), expected, "Diagnostic changed the supplied input copy")
            receipt["inputUnchanged"] = true
            receipt["status"] = "actual display and optional grid-retention assertions recorded"
            await session.release()
        } catch {
            receipt["error"] = error.localizedDescription
            await session.release()
            throw error
        }
    }

    /// Sample only neutral grid pixels selected from the BEFORE image in
    /// the inner 60% of the actual stroke bounds, away from every U segment.
    /// The AFTER image cannot change which pixels participate in the oracle.
    private func providedNewHighlighterPixels(before: Snapshot, after: Snapshot,
                                             points: [[Double]]) -> Int {
        guard before.width == after.width, before.height == after.height,
              let minX = points.map({ $0[0] }).min(), let maxX = points.map({ $0[0] }).max(),
              let minY = points.map({ $0[1] }).min(), let maxY = points.map({ $0[1] }).max() else { return 0 }
        let scale = Double(before.scale)
        let left = max(0, Int(minX * scale) - 24), right = min(before.width, Int(maxX * scale) + 24)
        let top = max(0, Int(minY * scale) - 24), bottom = min(before.height, Int(maxY * scale) + 24)
        var count = 0
        for y in top..<bottom { for x in left..<right {
            let i = (y * before.width + x) * 4
            let r = Int(before.pixels[i]), g = Int(before.pixels[i + 1]), b = Int(before.pixels[i + 2])
            guard min(r,g,b) >= 170, max(r,g,b) - min(r,g,b) <= 8 else { continue }
            let ar = Int(after.pixels[i]), ag = Int(after.pixels[i + 1]), ab = Int(after.pixels[i + 2])
            if ar >= 240, ag >= 200, ab <= 220, ag - ab >= 20 { count += 1 }
        } }
        return count
    }

    private func providedGridRetention(before: Snapshot, after: Snapshot,
                                       points: [[Double]]) throws -> [String: Any] {
        guard before.width == after.width, before.height == after.height,
              before.scale == after.scale,
              let minX = points.map({ $0[0] }).min(), let maxX = points.map({ $0[0] }).max(),
              let minY = points.map({ $0[1] }).min(), let maxY = points.map({ $0[1] }).max() else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 52, userInfo: [
                NSLocalizedDescriptionKey: "Grid comparison geometry changed"])
        }
        let scale = Double(before.scale)
        let left = Int((minX + (maxX - minX) * 0.20) * scale)
        let right = Int((maxX - (maxX - minX) * 0.20) * scale)
        let top = Int((minY + (maxY - minY) * 0.20) * scale)
        let bottom = Int((maxY - (maxY - minY) * 0.20) * scale)
        guard left >= 0, top >= 0, right < before.width, bottom < before.height,
              right > left, bottom > top else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 53, userInfo: [
                NSLocalizedDescriptionKey: "Grid oracle is outside the actual snapshot"])
        }
        var baseline = 0, retained = 0, whitened = 0
        for y in top..<bottom {
            for x in left..<right {
                let index = (y * before.width + x) * 4
                let original = (0..<3).map { Int(before.pixels[index + $0]) }
                guard let low = original.min(), let high = original.max(),
                      low >= 170, high <= 245, high - low <= 8 else { continue }
                baseline += 1
                let current = (0..<3).map { Int(after.pixels[index + $0]) }
                if zip(original, current).allSatisfy({ abs($0.0 - $0.1) <= 18 }) { retained += 1 }
                if current.allSatisfy({ $0 >= 250 }) { whitened += 1 }
            }
        }
        guard baseline >= 100 else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 54, userInfo: [
                NSLocalizedDescriptionKey: "The pre-stroke area contains too few visible grid pixels"])
        }
        return ["baselineGridPixels": baseline, "retainedGridPixels": retained,
                "whitenedGridPixels": whitened,
                "retainedFraction": Double(retained) / Double(baseline),
                "roiPixels": [left, top, right, bottom]]
    }

    private func run(_ format: AlphaFixtureFormat) async throws {
        guard ProcessInfo.processInfo.environment[Self.qualificationEnvironment] == "1" else {
            throw XCTSkip("Opt-in real-App Office highlighter alpha regression; "
                + "set \(Self.qualificationEnvironment)=1 to run")
        }
        executionTimeAllowance = 600

        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent(
            "Qualification/OfficeHighlighterAlpha-\(format.rawValue)-\(UUID().uuidString)",
            isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("FLOE_HIGHLIGHTER_ALPHA_ARTIFACT_ROOT=\(root.path)")

        let fixture = root.appendingPathComponent("highlighter-alpha.\(format.rawValue)")
        switch format {
        case .docx:
            try makeFixture(at: fixture)
        case .xlsx:
            try makeXLSXFixture(at: fixture)
        }
        let fixtureHash = try hash(fixture)

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No active foreground UIWindowScene"])
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)

        let session = OfficeFileSession()
        let window = mount(session, in: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        let selector = format == .docx
            ? "FloeAppTests/OfficeHighlighterAlphaTests/"
                + "testHighlighterAlphaPreservesColoredBackgroundTextAndGridLiveAndReopened"
            : "FloeAppTests/OfficeHighlighterAlphaTests/"
                + "testXLSXHighlighterAlphaPreservesColoredCellTextAndGridLiveAndReopened"
        let fixtureKind = format == .docx
            ? "synthetic DOCX with #DCEBFF shaded table cell, black text, visible grid borders"
            : "synthetic XLSX with #DCEBFF filled C3, black wrapped text, dark border and real neighbours"
        var receipt: [String: Any] = [
            "test": "OfficeHighlighterAlphaTests",
            "selector": selector,
            "format": format.rawValue,
            "route": "real OfficeFileSession/FloeOfficeNative production editor -> "
                + "production FloeOfficeNative Pencil gate -> real Pen PointerEvent -> "
                + "real frontend/core -> live WKWebView snapshot -> production export -> "
                + "production reopen -> pixel checks",
            "fixture": fixture.lastPathComponent,
            "fixtureSHA256": fixtureHash,
            "fixtureKind": fixtureKind,
            "hardwarePencil": "not-tested",
            "physicalDevice": "not-tested"
        ]
        defer { try? writeReceipt(receipt, root: root) }
        attach(fixture, name: "fixture-\(format.rawValue)")

        let controlURL = root.appendingPathComponent("control-no-ink.\(format.rawValue)")
        let finalURL = root.appendingPathComponent("final-highlighter.\(format.rawValue)")
        // The fixture itself is the no-ink control; the production session
        // only ever edits its own working copy, so this exact file can be
        // reopened as the pixel oracle without an intermediate export.
        try fm.copyItem(at: fixture, to: controlURL)
        do {
            await session.open(fixture)
            try await wait(120, "initial native Office open") {
                session.canAct && session.documentActionsReady && session.controller != nil
            }
            if session.readOnly {
                let accepted = await session.requestEditing()
                XCTAssertTrue(accepted, "The synthetic local fixture could not enter edit mode: \(session.error ?? "unknown")")
            }
            try await wait(150, "editable native Office document") {
                !session.readOnly && session.canAct && session.documentActionsReady && session.controller != nil
            }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))

            receipt["controlSHA256"] = fixtureHash
            try await Task.sleep(for: .milliseconds(450))

            let before = try await snapshot(web, root: root, name: "live-before")
            let geometry = try await geometryProbe(web)
            let pageImageRect = CGRect(
                x: geometry.pageX1 * before.scale,
                y: geometry.pageY1 * before.scale,
                width: max(1, (geometry.pageX2 - geometry.pageX1) * before.scale),
                height: max(1, (geometry.pageY2 - geometry.pageY1) * before.scale)
            )
            guard let region = coloredRegion(in: before, within: pageImageRect) else {
                attach(before, name: "live-before-no-colored-region")
                throw NSError(domain: "OfficeHighlighterAlpha", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "The synthetic #DCEBFF shaded cell was not visible in the live page; "
                        + "the fixture or the engine page geometry is invalid"
                ])
            }
            // The stroke is a U inside the shaded cell. Its bounding box is
            // the whole stroke, while the predeclared quadrant patches below
            // stay far from the full dense path; a rectangular white bbox fill
            // would therefore be unmistakable.
            let fractions = strokeFractions(for: format)
            let points = strokePoints(in: region, fractions: fractions,
                                      imageScale: before.scale,
                                      canvas: geometry.canvasRect)
            let strokeROI = strokeBBox(points: points, scale: before.scale,
                                       imageWidth: before.width, imageHeight: before.height)
            try validateROI(strokeROI, within: region, label: "LIVE")
            // Select the non-stroke oracle BEFORE any contact, from geometry
            // only. A 5x5 patch must be wholly inside the blue cell and its
            // nearest pixel must clear the real 4 mm half-width, AA and a
            // smoothing margin. There is no post-image or yellow-based pick.
            let livePatches = try interiorSamplePatches(points: points,
                                                        snapshot: before, cell: region)
            receipt["nonStrokePatchClearance"] = livePatches.first?.clearance ?? -1
            receipt["nonStrokePatches"] = livePatches.map(\.facts)
            receipt["liveRegion"] = region.facts
            receipt["liveStrokeROI"] = strokeROI.facts
            let beforeMetrics = metrics(in: before, region: strokeROI)
            receipt["liveBefore"] = beforeMetrics.facts

            // Select the real highlighter preset through the production
            // preferences/apply path, not a test-only command.
            session.useInkPreferences(workspaceIdentity: root.path,
                                      documentKey: fixture.lastPathComponent)
            let preferences = session.inkPreferences
            preferences.setPreset(.highlighter)
            preferences.setColorHex("#FFCC00")
            try await session.toggleDrawing()
            XCTAssertTrue(session.drawingMode, "Drawing mode did not turn on")
            await session.applyInkPreferences()
            XCTAssertNil(session.inkError, "The production highlighter style dispatch failed: \(session.inkError ?? "")")
            receipt["inkApplyOutcome"] = String(describing: session.inkApplyOutcome)

            let pencilValue = try await web.evaluateJavaScript("window.__floePencilOnly === true")
            let pencilReady = (pencilValue as? Bool) == true
            XCTAssertTrue(pencilReady, "The production Pencil-only drawing gate is not active")

            // Real dense contact: begin the SAME contact and dispatch every
            // point as a pointermove while the pen is still down. The actual
            // WK snapshot below is taken in this phase, because the reported
            // white rectangle can appear while the pen is down and the
            // preview-retired core gate alone cannot prove that state. The
            // contact is lifted exactly once afterwards, including on a
            // mid-contact snapshot/gate error.
            let densePoints = try densified(points)
            let density = strokeDensityFacts(original: points, dense: densePoints)
            receipt["strokeDensity"] = density
            XCTAssertGreaterThanOrEqual(densePoints.count, 120,
                                        "The dense contact is too short to be a real 2-4 CSS px stream: \(density)")
            XCTAssertLessThanOrEqual(density["maxStepCss"] as? Double ?? .greatestFiniteMagnitude, 4.0,
                                     "A dense contact interval exceeded 4 CSS px: \(density)")
            let begun = try await strokePhase(web, phase: "begin", points: densePoints)
            receipt["strokeBegin"] = begun
            XCTAssertEqual(begun["activeStroke"] as? Bool, true,
                           "MID-CONTACT: the production contact is not active after all dense moves: \(begun)")
            XCTAssertEqual(begun["strokeDeltaSoFar"] as? Int, 0,
                           "MID-CONTACT: a stroke completed before the pen lifted: \(begun)")
            XCTAssertEqual(begun["inputPointCount"] as? Int, densePoints.count,
                           "MID-CONTACT: the production gate did not receive every dense point: \(begun)")
            XCTAssertGreaterThanOrEqual(begun["coreEventDeltaSoFar"] as? Int ?? 0, 80,
                                        "MID-CONTACT: too few dense samples reached the engine: \(begun)")

            var midContactSeen = false
            do {
                let midPreview = try await waitForActivePreview(web, timeout: 3.0)
                receipt["midPreviewState"] = midPreview
                let midActive = (midPreview["activeStroke"] as? Bool) == true
                let midPreviewLive = (midPreview["livePreview"] as? Bool) == true
                XCTAssertTrue(midActive,
                              "MID-CONTACT: the production contact is not active while the pen is down: \(midPreview)")
                XCTAssertTrue(midPreviewLive,
                              "MID-CONTACT: the production live preview is not active while the pen is down: "
                                  + "\(midPreview)")
                try await Task.sleep(for: .milliseconds(60))
                let midAtSnapshot = try await currentPreviewState(web)
                receipt["midPreviewStateAtSnapshot"] = midAtSnapshot
                let midActiveAtSnapshot = (midAtSnapshot["activeStroke"] as? Bool) == true
                let midPreviewAtSnapshot = (midAtSnapshot["livePreview"] as? Bool) == true
                XCTAssertTrue(midActiveAtSnapshot,
                              "MID-CONTACT: the contact is not active at the while-down snapshot: \(midAtSnapshot)")
                XCTAssertTrue(midPreviewAtSnapshot,
                              "MID-CONTACT: the live preview is not active at the while-down snapshot: "
                                  + "\(midAtSnapshot)")
                let mid = try await snapshot(web, root: root, name: "mid-contact")
                midContactSeen = true
                receipt["midContactPNG"] = "mid-contact.png"
                let midAfterSnapshot = try await currentPreviewState(web)
                receipt["midPreviewStateAfterSnapshot"] = midAfterSnapshot
                XCTAssertTrue((midAfterSnapshot["activeStroke"] as? Bool) == true,
                              "MID-CONTACT: the contact ended during the while-down snapshot: \(midAfterSnapshot)")
                let midMetrics = metrics(in: mid, region: strokeROI)
                receipt["midContact"] = midMetrics.facts
                receipt["midChangedPixels"] = changedPixels(before: before, after: mid, region: strokeROI)
                let midCenter = centerDelta(before: before, after: mid, region: strokeROI)
                receipt["midCenterDelta"] = midCenter
                try assertPreserved(
                    before: beforeMetrics,
                    after: midMetrics,
                    label: "MID-CONTACT",
                    beforeName: "colored cell/text/grid before the contact",
                    afterName: "colored cell/text/grid while the pen is down"
                )
                XCTAssertGreaterThan(midMetrics.yellow, beforeMetrics.yellow + 50,
                                     "MID-CONTACT: no yellow highlighter band appeared while the pen is "
                                         + "down: \(midMetrics.facts)")
                XCTAssertLessThanOrEqual(midCenter, 18.0,
                                         "MID-CONTACT: the non-stroke center changed by \(midCenter) "
                                             + "per-channel while the pen is down; a rectangular white wash is present")
                let midPatchDelta = try patchDelta(before: before, after: mid, patches: livePatches)
                receipt["midInteriorPatches"] = midPatchDelta.facts
                receipt["midInteriorWorstDelta"] = midPatchDelta.worst
                XCTAssertLessThanOrEqual(midPatchDelta.worst, 18.0,
                                         "MID-CONTACT: a predeclared non-stroke interior patch changed by "
                                             + "\(midPatchDelta.worst) per-channel while the pen is down; "
                                             + "Patches: \(midPatchDelta.facts)")
                let midBand = bandDarkPixels(before: before, after: mid, points: points,
                                             scale: before.scale, search: strokeROI)
                receipt["midBandText"] = midBand.facts
                XCTAssertGreaterThan(midBand.beforeDark, 0,
                                     "MID-CONTACT: the highlighter band did not cross text/grid; "
                                         + "the fixture/path assertion is invalid: \(midBand.facts)")
                XCTAssertGreaterThanOrEqual(midBand.afterDark, midBand.beforeDark * 2 / 5,
                                            "MID-CONTACT: black text/grid under the highlighter band was "
                                                + "erased while the pen is down: \(midBand.facts)")
            } catch {
                receipt["midContactFailure"] = String(describing: error)
                XCTFail("MID-CONTACT: the while-down snapshot/gate could not run: \(error)")
            }
            receipt["midContactSeen"] = midContactSeen

            let dispatched: [String: Any]
            do {
                dispatched = try await strokePhase(web, phase: "lift", points: densePoints)
            } catch {
                // The snapshot/gate path above must never leave the real
                // contact down. Try one explicit lift/release before failing.
                _ = try? await strokePhase(web, phase: "cleanup", points: densePoints)
                throw error
            }
            receipt["stroke"] = dispatched
            if (dispatched["activeAfter"] as? Bool) == true {
                // A rejected/ignored first lift must not strand the real
                // contact; retry one explicit pointerup and retain the receipt.
                if let cleanup = try? await strokePhase(web, phase: "cleanup", points: densePoints) {
                    receipt["strokeCleanup"] = cleanup
                }
            }
            XCTAssertEqual(dispatched["strokeDelta"] as? Int, 1,
                           "The production Pencil gate did not complete exactly one stroke: \(dispatched)")
            XCTAssertEqual(dispatched["activeAfter"] as? Bool, false,
                           "The production Pencil gate still has an active contact: \(dispatched)")
            XCTAssertEqual(dispatched["inputPointCount"] as? Int, densePoints.count,
                           "The production gate did not receive every dense point: \(dispatched)")
            XCTAssertGreaterThanOrEqual(dispatched["coreEventDelta"] as? Int ?? 0, 80,
                                        "Too few dense samples reached the engine: \(dispatched)")

            if format == .xlsx {
                // The user observes the white box AFTER lift. Observe the
                // first available frames before waiting for preview retirement
                // or the later settled tile; preserve every frame, not just a
                // successful retry. The runner also records this actual window.
                let liftedAt = Date()
                var frames: [[String: Any]] = []
                for frame in 0..<4 {
                    if frame > 0 { try await Task.sleep(for: .milliseconds(50)) }
                    let state = try await currentPreviewState(web)
                    let image = try await snapshot(web, root: root,
                        name: "post-lift-\(frame)", afterScreenUpdates: false)
                    let m = metrics(in: image, region: strokeROI)
                    let patches = try patchDelta(before: before, after: image, patches: livePatches)
                    frames.append(["index": frame, "elapsedAfterLiftReturn": Date().timeIntervalSince(liftedAt),
                        "preview": state, "metrics": m.facts, "patches": patches.facts])
                    try assertPreserved(before: beforeMetrics, after: m, label: "POST-LIFT \(frame)",
                        beforeName: "colored cell before stroke", afterName: "first available frame after lift")
                    XCTAssertLessThanOrEqual(patches.worst, 18.0,
                        "POST-LIFT \(frame): non-stroke background changed: \(patches.facts)")
                    XCTAssertGreaterThan(m.yellow, beforeMetrics.yellow + 50,
                        "POST-LIFT \(frame): highlighter disappeared during handoff")
                }
                receipt["postLiftFrames"] = frames
            }

            // The front-end keeps its own SVG preview until the composited
            // document paint is observed. Wait for that retirement first, so
            // the live pixels below are the engine's tile and not only the
            // presentation overlay. A timeout retains a frame/receipt and
            // throws: the LIVE gate never runs on presentation-only pixels.
            let previewFacts = try await waitForPreviewRetirement(web, timeout: 8.0)
            receipt["livePreviewState"] = previewFacts
            guard (previewFacts["livePreview"] as? Bool) == false else {
                // Never let a live assertion pass on the SVG presentation
                // overlay. Retain the timeout frame and fail with the actual
                // preview state; the engine tile must be the evidence.
                let timeoutFrame = try? await snapshot(web, root: root, name: "live-preview-timeout")
                if let timeoutFrame { attach(timeoutFrame, name: "live-preview-timeout") }
                receipt["livePreviewTimeout"] = true
                throw NSError(domain: "OfficeHighlighterAlpha", code: 16, userInfo: [
                    NSLocalizedDescriptionKey: "The production SVG preview did not retire within 8 s "
                        + "(state: \(previewFacts)); the live gate refuses to pass from the overlay. "
                        + "The engine tile pixels are not proven."])
            }

            // Wait for the engine's tile/ink update and retry the snapshot
            // only while the yellow band is still absent. The retry is
            // bounded; a never-painted stroke is a real failure.
            var after: Snapshot?
            var afterMetrics: RegionMetrics?
            for attempt in 0..<6 {
                try await Task.sleep(for: .milliseconds(attempt == 0 ? 700 : 450))
                let state = try await currentPreviewState(web)
                guard (state["livePreview"] as? Bool) == false else {
                    // The overlay came back or is still live; a snapshot in
                    // this state is presentation-only and may not satisfy the
                    // LIVE gate.
                    continue
                }
                let candidate = try await snapshot(web, root: root, name: "live-after-\(attempt)")
                let candidateMetrics = metrics(in: candidate, region: strokeROI)
                if candidateMetrics.yellow >= beforeMetrics.yellow + 50 {
                    after = candidate
                    afterMetrics = candidateMetrics
                    break
                }
                if attempt == 5 {
                    after = candidate
                    afterMetrics = candidateMetrics
                }
            }
            guard let after, let afterMetrics else {
                throw NSError(domain: "OfficeHighlighterAlpha", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "No live snapshot was produced after the highlighter stroke"])
            }
            receipt["liveAfter"] = afterMetrics.facts
            receipt["liveChangedPixels"] = changedPixels(before: before, after: after, region: strokeROI)
            receipt["liveCenterDelta"] = centerDelta(before: before, after: after, region: strokeROI)

            try assertPreserved(
                before: beforeMetrics,
                after: afterMetrics,
                label: "LIVE",
                beforeName: "colored cell/text/grid before stroke",
                afterName: "colored cell/text/grid after highlighter"
            )
            XCTAssertGreaterThan(afterMetrics.yellow, beforeMetrics.yellow + 50,
                                 "LIVE: no yellow highlighter band appeared in the stroke cell: "
                                 + "\(afterMetrics.facts)")
            let center = centerDelta(before: before, after: after, region: strokeROI)
            XCTAssertLessThanOrEqual(center, 18.0,
                                     "LIVE: the non-stroke center of the highlighter bbox changed by "
                                     + "\(center) per-channel; a rectangular white wash is present")
            let livePatchDelta = try patchDelta(before: before, after: after,
                                                patches: livePatches)
            receipt["liveInteriorPatches"] = livePatchDelta.facts
            receipt["liveInteriorWorstDelta"] = livePatchDelta.worst
            XCTAssertLessThanOrEqual(livePatchDelta.worst, 18.0,
                                     "LIVE: a predeclared non-stroke interior patch changed by "
                                     + "\(livePatchDelta.worst) per-channel; a white bbox fill or a "
                                     + "smoothed band reaches it. Patches: \(livePatchDelta.facts)")

            // Text/grid actually under the 4 mm band: the U's top segment is
            // placed on the cell's first text line. Dark pixels there prove
            // the highlighter tints rather than erases the underlying ink.
            let band = bandDarkPixels(before: before, after: after,
                                      points: points, scale: before.scale,
                                      search: strokeROI)
            receipt["liveBandText"] = band.facts
            XCTAssertGreaterThan(band.beforeDark, 0,
                                 "LIVE: the highlighter band did not cross any text/grid pixel; "
                                 + "the fixture/path assertion is invalid: \(band.facts)")
            XCTAssertGreaterThanOrEqual(band.afterDark, band.beforeDark * 2 / 5,
                                        "LIVE: black text/grid under the highlighter band was erased: "
                                        + "\(band.facts). A white highlighter bbox would remove it.")

            // Production export of the ink-bearing document. Calc needs the
            // drawing tool left before export, exactly like the existing
            // XLSX native drawing qualification; Word keeps its current path.
            if format == .xlsx, session.drawingMode {
                try await session.toggleDrawing()
                XCTAssertFalse(session.drawingMode, "Drawing mode did not turn off before XLSX export")
            }
            let finalExport = try await session.exportDocument(format: format.rawValue)
            try fm.copyItem(at: finalExport, to: finalURL)
            attach(finalURL, name: "final-\(format.rawValue)")
            receipt["finalSHA256"] = try hash(finalURL)
            XCTAssertEqual(try hash(fixture), fixtureHash,
                           "The production session mutated the source fixture; control/final comparison is invalid")
            await session.release()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        } catch {
            await session.release()
            window.isHidden = true
            window.rootViewController = nil
            let failure = ["error": String(describing: error)]
            receipt["failure"] = failure
            try? writeReceipt(receipt, root: root)
            throw error
        }

        // Saved style: a real open freehand path with a 40%-opacity line and
        // no shape fill. This is the wire style the engine received; it is
        // not a substitute for the pixel/reopen gates below. Word and Excel
        // save the same DML path inside different containers, so Excel is
        // validated in its actual spreadsheetDrawing member.
        if format == .docx {
            let savedXML = try rawMember(finalURL, path: "word/document.xml")
            receipt["savedXMLMember"] = "word/document.xml"
            receipt["savedXML"] = try assertSavedHighlighterXML(savedXML)
        } else {
            let member = try xlsxDrawingMember(finalURL)
            receipt["savedXMLMember"] = member
            let savedDrawing = try rawMember(finalURL, path: member)
            receipt["savedXML"] = try assertSavedHighlighterDrawingXML(savedDrawing)
        }

        // Reopen the control (no ink) and the final (highlighter) copies in
        // the same production editor. Both are plain local fixture files
        // opened by the same code path; the control cell is the oracle.
        let (controlImage, controlGeometry) = try await reopenImage(
            controlURL, scene: scene, root: root, name: "control-reopened")
        let (finalImage, finalGeometry) = try await reopenImage(
            finalURL, scene: scene, root: root, name: "final-reopened")
        XCTAssertEqual(controlImage.width, finalImage.width, "Control/final reopened image widths differ")
        XCTAssertEqual(controlImage.height, finalImage.height, "Control/final reopened image heights differ")

        let controlPageRect = pageImageRect(controlGeometry, scale: controlImage.scale)
        let finalPageRect = pageImageRect(finalGeometry, scale: finalImage.scale)
        guard let controlRegion = coloredRegion(in: controlImage, within: controlPageRect) else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "The reopened no-ink control lost the synthetic shaded cell"])
        }
        guard let finalRegion = coloredRegion(in: finalImage, within: finalPageRect) else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "The reopened final document lost the synthetic shaded cell; "
                    + "a white rectangular background may have covered it"])
        }
        let savedFractions = strokeFractions(for: format)
        let controlROI = strokeBBox(in: controlRegion, fractions: savedFractions,
                                    imageWidth: controlImage.width, imageHeight: controlImage.height)
        let finalROI = strokeBBox(in: finalRegion, fractions: savedFractions,
                                  imageWidth: finalImage.width, imageHeight: finalImage.height)
        let controlMetrics = metrics(in: controlImage, region: controlROI)
        let finalMetrics = metrics(in: finalImage, region: finalROI)
        receipt["reopenControlRegion"] = controlRegion.facts
        receipt["reopenFinalRegion"] = finalRegion.facts
        receipt["reopenControlROI"] = controlROI.facts
        receipt["reopenFinalROI"] = finalROI.facts
        receipt["reopenControl"] = controlMetrics.facts
        receipt["reopenFinal"] = finalMetrics.facts
        let controlCellArea = max(1, controlRegion.area)
        XCTAssertGreaterThanOrEqual(finalRegion.area, controlCellArea / 2,
                                    "The reopened final colored cell shrank from \(controlRegion.facts) "
                                    + "to \(finalRegion.facts); the highlighter bbox is covering it")
        try assertPreserved(
            before: controlMetrics,
            after: finalMetrics,
            label: "REOPENED",
            beforeName: "reopened no-ink control colored cell/text/grid",
            afterName: "reopened saved highlighter colored cell/text/grid"
        )
        let reopenedCenter = max(abs(finalMetrics.centerMean.0 - controlMetrics.centerMean.0),
                                 max(abs(finalMetrics.centerMean.1 - controlMetrics.centerMean.1),
                                     abs(finalMetrics.centerMean.2 - controlMetrics.centerMean.2)))
        receipt["reopenCenterDelta"] = reopenedCenter
        XCTAssertLessThanOrEqual(reopenedCenter, 18.0,
                                 "REOPENED: the non-stroke center of the highlighter bbox changed by "
                                 + "\(reopenedCenter) per-channel after save/reopen; a rectangular "
                                 + "white background is present in the saved rendering")
        // Recompute the planned normalized path and the safe patches in the
        // no-ink control cell, then map them by normalized cell coordinates
        // into the saved final cell. The blue cell size/alignment is checked
        // before the mapped comparison; a shifted or shrunken cell cannot
        // silently move the oracle.
        let controlPlanned = strokePoints(in: controlRegion,
                                          fractions: savedFractions,
                                          imageScale: controlImage.scale,
                                          canvas: .zero)
        let controlPatches = try interiorSamplePatches(points: controlPlanned,
                                                       snapshot: controlImage,
                                                       cell: controlRegion)
        let finalPlanned = strokePoints(in: finalRegion,
                                        fractions: savedFractions,
                                        imageScale: finalImage.scale,
                                        canvas: .zero)
        let finalPatches = try mappedInteriorPatches(controlPatches,
                                                     from: controlRegion,
                                                     to: finalRegion,
                                                     snapshot: finalImage,
                                                     points: finalPlanned)
        let reopenedPatchDelta = try patchDelta(before: controlImage,
                                                after: finalImage,
                                                patches: controlPatches,
                                                mapped: finalPatches)
        receipt["reopenInteriorPatches"] = reopenedPatchDelta.facts
        receipt["reopenInteriorWorstDelta"] = reopenedPatchDelta.worst
        XCTAssertLessThanOrEqual(reopenedPatchDelta.worst, 18.0,
                                 "REOPENED: a predeclared non-stroke interior patch changed by "
                                 + "\(reopenedPatchDelta.worst) per-channel after save/reopen; the "
                                 + "saved white rectangle reaches it. Patches: \(reopenedPatchDelta.facts)")

        receipt["liveBeforePNG"] = "live-before.png"
        receipt["liveAfterPNG"] = "live-after.png"
        receipt["controlReopenedPNG"] = "control-reopened.png"
        receipt["finalReopenedPNG"] = "final-reopened.png"
        receipt["featureStatus"] = "diagnosis only: user's white-box defect is not yet declared fixed; "
            + "this test records the actual live/save/reopen pixels for root's decision"
        try writeReceipt(receipt, root: root)
    }

    // MARK: - Synthetic fixture

    /// A minimal, deterministic Word document with:
    ///  - a 2 x 2 table with visible dark grid borders,
    ///  - a #DCEBFF shaded cell containing bold black text (the highlighter target),
    ///  - a second #E8F5E9 cell and a baseline paragraph outside the target.
    /// The live stroke is drawn by the test itself, not embedded in the fixture.
    private func makeFixture(at url: URL) throws {
        let fm = FileManager.default
        let base = url.deletingLastPathComponent()
            .appendingPathComponent("fixture-base-\(UUID().uuidString).docx")
        defer { try? fm.removeItem(at: base) }
        try OfficeDocumentBuilder.createWord(at: base, title: "Highlighter Alpha", paragraphs: ["placeholder"])

        let read = try Archive(url: base, accessMode: .read)
        var entries: [String: Data] = [:]
        for entry in read {
            var data = Data()
            _ = try read.extract(entry) { data.append($0) }
            entries[entry.path] = data
        }
        entries["word/document.xml"] = Data(Self.fixtureDocumentXML.utf8)
        let write = try Archive(url: url, accessMode: .create)
        for (path, data) in entries.sorted(by: { $0.key < $1.key }) {
            try write.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                let lower = Int(position)
                let upper = min(data.count, lower + size)
                return data.subdata(in: lower..<upper)
            }
        }
        // Fail before opening the engine if the synthetic replacement XML is
        // not a valid Office package; the engine's own open error is then not
        // confused with a layout/pixel failure.
        _ = try OfficeDocumentService.inspect(url: url)
    }

    private static let fixtureDocumentXML = #"""
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
    <w:p><w:r><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:b/><w:sz w:val="36"/></w:rPr><w:t>HIGHLIGHTER-ALPHA-TEXT</w:t></w:r></w:p>
    <w:tbl><w:tblPr><w:tblW w:w="9000" w:type="dxa"/><w:tblBorders><w:top w:val="single" w:sz="12" w:space="0" w:color="1F2937"/><w:left w:val="single" w:sz="12" w:space="0" w:color="1F2937"/><w:bottom w:val="single" w:sz="12" w:space="0" w:color="1F2937"/><w:right w:val="single" w:sz="12" w:space="0" w:color="1F2937"/><w:insideH w:val="single" w:sz="12" w:space="0" w:color="1F2937"/><w:insideV w:val="single" w:sz="12" w:space="0" w:color="1F2937"/></w:tblBorders></w:tblPr>
    <w:tr><w:trPr><w:trHeight w:val="3000"/></w:trPr><w:tc><w:tcPr><w:tcW w:w="4500" w:type="dxa"/><w:shd w:val="clear" w:color="auto" w:fill="DCEBFF"/><w:vAlign w:val="top"/></w:tcPr><w:p><w:r><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:b/><w:sz w:val="44"/></w:rPr><w:t>HIGHLIGHTER-GRID-TEXT</w:t></w:r></w:p></w:tc><w:tc><w:tcPr><w:tcW w:w="4500" w:type="dxa"/><w:shd w:val="clear" w:color="auto" w:fill="E8F5E9"/></w:tcPr><w:p><w:r><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:sz w:val="36"/></w:rPr><w:t>GRID-GREEN</w:t></w:r></w:p></w:tc></w:tr>
    <w:tr><w:trPr><w:trHeight w:val="1400"/></w:trPr><w:tc><w:tcPr><w:tcW w:w="4500" w:type="dxa"/><w:shd w:val="clear" w:color="auto" w:fill="FFF2CC"/></w:tcPr><w:p><w:r><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:sz w:val="32"/></w:rPr><w:t>SECOND-ROW-TEXT</w:t></w:r></w:p></w:tc><w:tc><w:tcPr><w:tcW w:w="4500" w:type="dxa"/><w:shd w:val="clear" w:color="auto" w:fill="FDE2E1"/></w:tcPr><w:p><w:r><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:sz w:val="32"/></w:rPr><w:t>GRID-RED</w:t></w:r></w:p></w:tc></w:tr>
    </w:tbl>
    <w:p><w:r><w:rPr><w:rFonts w:ascii="Arial" w:hAnsi="Arial"/><w:sz w:val="28"/></w:rPr><w:t>BASELINE-CONTENT-KEEP</w:t></w:r></w:p>
    <w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
    </w:body></w:document>
    """#

    /// A real XLSX package: let the production builder write every member,
    /// then replace only the worksheet and style parts. The target C3 cell is
    /// one large #DCEBFF fill with a dark border and bold wrapped black text;
    /// A/B and rows 4-10 keep real text/numbers so Calc's grid and neighbours
    /// are not synthetic colored rectangles. A1 is deliberately not the
    /// target because the default active-cell overlay can cover it.
    private func makeXLSXFixture(at url: URL) throws {
        let fm = FileManager.default
        let base = url.deletingLastPathComponent()
            .appendingPathComponent("fixture-base-\(UUID().uuidString).xlsx")
        defer { try? fm.removeItem(at: base) }
        try OfficeDocumentBuilder.createWorkbook(at: base, sheets: [
            .init(name: "Alpha", rows: [["placeholder"]])
        ])

        let read = try Archive(url: base, accessMode: .read)
        var entries: [String: Data] = [:]
        for entry in read where entry.type == .file {
            var data = Data()
            _ = try read.extract(entry) { data.append($0) }
            entries[entry.path] = data
        }
        guard entries["xl/styles.xml"] != nil, entries["xl/worksheets/sheet1.xml"] != nil else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 55, userInfo: [
                NSLocalizedDescriptionKey: "The workbook builder did not emit the replaceable styles/worksheet members"])
        }
        entries["xl/styles.xml"] = Data(Self.xlsxStylesXML.utf8)
        entries["xl/worksheets/sheet1.xml"] = Data(Self.xlsxSheetXML.utf8)

        let write = try Archive(url: url, accessMode: .create)
        for (path, data) in entries.sorted(by: { $0.key < $1.key }) {
            try write.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
                let lower = Int(position)
                let upper = min(data.count, lower + size)
                return data.subdata(in: lower..<upper)
            }
        }
        let inspected = try OfficeDocumentService.inspect(url: url)
        guard inspected.kind == .workbook,
              inspected.workbookPreview?.sheets.map(\.name) == ["Alpha"] else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 56, userInfo: [
                NSLocalizedDescriptionKey: "The synthetic XLSX no longer inspects as the expected Alpha workbook"])
        }
    }

    private static let xlsxStylesXML = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <fonts count="3"><font><sz val="11"/><name val="Arial"/></font><font><b/><color rgb="FFFFFFFF"/><sz val="11"/><name val="Arial"/></font><font><b/><sz val="16"/><name val="Arial"/></font></fonts>
    <fills count="4"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF2563EB"/><bgColor indexed="64"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="FFDCEBFF"/><bgColor indexed="64"/></patternFill></fill></fills>
    <borders count="2"><border><left/><right/><top/><bottom/><diagonal/></border><border><left style="thin"><color rgb="FF1F2937"/></left><right style="thin"><color rgb="FF1F2937"/></right><top style="thin"><color rgb="FF1F2937"/></top><bottom style="thin"><color rgb="FF1F2937"/></bottom><diagonal/></border></borders>
    <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
    <cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" xfId="0" applyFont="1" applyFill="1"/><xf numFmtId="0" fontId="2" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1"><alignment vertical="top" wrapText="1"/></xf></cellXfs>
    <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
    </styleSheet>
    """#

    private static let xlsxSheetXML = #"""
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
    <dimension ref="A1:C10"/>
    <sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>
    <sheetFormatPr defaultRowHeight="18"/>
    <cols><col min="1" max="1" width="20" customWidth="1"/><col min="2" max="2" width="12" customWidth="1"/><col min="3" max="3" width="38" customWidth="1"/></cols>
    <sheetData>
    <row r="1"><c r="A1" t="inlineStr"><is><t>HIGHLIGHTER-ALPHA-XLSX</t></is></c><c r="B1" t="inlineStr"><is><t>VALUE</t></is></c><c r="C1" t="inlineStr"><is><t>GRID</t></is></c></row>
    <row r="2"><c r="A2" t="inlineStr"><is><t>BASELINE-KEEP</t></is></c><c r="B2"><v>12</v></c><c r="C2" t="inlineStr"><is><t>ROW-2</t></is></c></row>
    <row r="3" ht="180" customHeight="1"><c r="A3" t="inlineStr"><is><t>TARGET</t></is></c><c r="B3" t="inlineStr"><is><t>GRID</t></is></c><c r="C3" s="2" t="inlineStr"><is><t xml:space="preserve">EXCEL-HIGHLIGHTER-GRID-TEXT-ALPHA-12345 REAL CELL TEXT KEEP THIS VISIBLE</t></is></c></row>
    <row r="4"><c r="A4" t="inlineStr"><is><t>ROW-4</t></is></c><c r="B4"><v>4</v></c><c r="C4" t="inlineStr"><is><t>KEEP-4</t></is></c></row>
    <row r="5"><c r="A5" t="inlineStr"><is><t>ROW-5</t></is></c><c r="B5"><v>5</v></c><c r="C5" t="inlineStr"><is><t>KEEP-5</t></is></c></row>
    <row r="6"><c r="A6" t="inlineStr"><is><t>ROW-6</t></is></c><c r="B6"><v>6</v></c><c r="C6" t="inlineStr"><is><t>KEEP-6</t></is></c></row>
    <row r="7"><c r="A7" t="inlineStr"><is><t>ROW-7</t></is></c><c r="B7"><v>7</v></c><c r="C7" t="inlineStr"><is><t>KEEP-7</t></is></c></row>
    <row r="8"><c r="A8" t="inlineStr"><is><t>ROW-8</t></is></c><c r="B8"><v>8</v></c><c r="C8" t="inlineStr"><is><t>KEEP-8</t></is></c></row>
    <row r="9"><c r="A9" t="inlineStr"><is><t>ROW-9</t></is></c><c r="B9"><v>9</v></c><c r="C9" t="inlineStr"><is><t>KEEP-9</t></is></c></row>
    <row r="10"><c r="A10" t="inlineStr"><is><t>ROW-10</t></is></c><c r="B10"><v>10</v></c><c r="C10" t="inlineStr"><is><t>KEEP-10</t></is></c></row>
    </sheetData>
    </worksheet>
    """#

    // MARK: - Production stroke dispatch

    private static let strokeScript = #"""
    const phase = String(strokePhase || '');
    const app = window.app;
    const container = app && app.sectionContainer;
    const canvas = container && container.canvas;
    if (!canvas || typeof window.PointerEvent !== 'function')
        return JSON.stringify({ok:false, phase:phase, reason:'no-canvas'});
    const rawPoints = Array.isArray(strokePoints) ? strokePoints.filter(p =>
        Array.isArray(p) && p.length === 2 && p.every(Number.isFinite)) : [];
    const readState = () => {
        const state = window.__floePenState;
        return state ? {strokes: state.strokes || 0, coreEvents: state.coreEvents || 0,
            armedDispatches: state.armedDispatches || 0,
            activeStroke: state.activeStroke === true} : null;
    };
    const send = (type, p, buttons) => canvas.dispatchEvent(new PointerEvent(type, {
        bubbles:true, cancelable:true, composed:true, pointerType:'pen',
        pointerId:71, isPrimary:true, clientX:p[0], clientY:p[1],
        button:0, buttons:buttons, pressure:buttons ? 0.5 : 0
    }));
    if (phase === 'begin') {
        if (window.__floeHighlighterContact)
            return JSON.stringify({ok:false, phase:phase, reason:'contact-already-open'});
        if (rawPoints.length < 2)
            return JSON.stringify({ok:false, phase:phase, reason:'invalid-points'});
        const before = readState();
        if (!before)
            return JSON.stringify({ok:false, phase:phase, reason:'production-gate-missing'});
        const contact = {before:before, last:rawPoints[0],
            inputPointCount:rawPoints.length, movesDispatched:0, lifted:false};
        window.__floeHighlighterContact = contact;
        let sentIndex = 0;
        try {
            send('pointerdown', rawPoints[0], 1);
            for (let i = 1; i < rawPoints.length; i += 1) {
                send('pointermove', rawPoints[i], 1);
                contact.last = rawPoints[i];
                contact.movesDispatched = i;
                sentIndex = i;
            }
        } catch (error) {
            try { send('pointerup', rawPoints[sentIndex], 0); } catch (ignored) {}
            delete window.__floeHighlighterContact;
            return JSON.stringify({ok:false, phase:phase, reason:'dispatch-failed',
                message:String((error && error.message) || error)});
        }
        const after = readState();
        return JSON.stringify({ok:true, phase:phase, before:before, after:after,
            activeStroke:after ? after.activeStroke === true : false,
            inputPointCount:rawPoints.length, movesDispatched:Math.max(0, rawPoints.length - 1),
            coreEventDeltaSoFar:after ? (after.coreEvents || 0) - (before.coreEvents || 0) : -1,
            strokeDeltaSoFar:after ? (after.strokes || 0) - (before.strokes || 0) : -1});
    }
    if (phase === 'lift' || phase === 'cleanup') {
        const contact = window.__floeHighlighterContact;
        if (!contact)
            return JSON.stringify({ok:true, phase:phase, released:false, reason:'no-open-contact'});
        if (contact.lifted) {
            delete window.__floeHighlighterContact;
            return JSON.stringify({ok:true, phase:phase, released:false, reason:'already-lifted'});
        }
        try {
            send('pointerup', contact.last, 0);
        } catch (error) {
            return JSON.stringify({ok:false, phase:phase, reason:'lift-failed',
                message:String((error && error.message) || error)});
        }
        contact.lifted = true;
        const after = readState();
        const stillActive = after ? after.activeStroke === true : true;
        const result = {ok:true, phase:phase, before:contact.before, after:after,
            strokeDelta:after ? (after.strokes || 0) - (contact.before.strokes || 0) : -1,
            coreEventDelta:after ? (after.coreEvents || 0) - (contact.before.coreEvents || 0) : -1,
            activeAfter:stillActive,
            inputPointCount:contact.inputPointCount,
            movesDispatched:contact.movesDispatched,
            lifted:true, lastPoint:contact.last};
        if (stillActive) contact.lifted = false;
        else delete window.__floeHighlighterContact;
        return JSON.stringify(result);
    }
    return JSON.stringify({ok:false, phase:phase, reason:'unknown-phase'});
    """#

    private func strokePhase(_ web: WKWebView, phase: String,
                             points: [[Double]]) async throws -> [String: Any] {
        let raw = try await web.callAsyncJavaScript(
            Self.strokeScript,
            arguments: ["strokePhase": phase, "strokePoints": points],
            in: nil,
            contentWorld: .page
        )
        guard let json = raw as? String, json.utf8.count <= 32_768,
              let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "The production Pencil bridge did not return a bounded JSON receipt for \(phase)"])
        }
        guard (decoded["ok"] as? Bool) == true else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "The production Pencil bridge rejected the \(phase) phase: \(decoded)"])
        }
        return decoded
    }

    // MARK: - Geometry and snapshots

    private struct Geometry {
        let pageX1: CGFloat
        let pageY1: CGFloat
        let pageX2: CGFloat
        let pageY2: CGFloat
        let canvasRect: CGRect
    }

    private static let geometryScript = #"""
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
    return JSON.stringify({available:true, pageX1:x1, pageY1:y1, pageX2:x2, pageY2:y2,
        canvasRect:{x:rect.left,y:rect.top,width:rect.width,height:rect.height},
        viewportWidth:window.innerWidth, viewportHeight:window.innerHeight});
    """#

    private func geometryProbe(_ web: WKWebView) async throws -> Geometry {
        let raw = try await web.callAsyncJavaScript(Self.geometryScript, arguments: [:],
                                                    in: nil, contentWorld: .page)
        guard let json = raw as? String, json.utf8.count <= 16_384,
              let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              (value["available"] as? Bool) == true,
              let x1 = number(value["pageX1"]), let y1 = number(value["pageY1"]),
              let x2 = number(value["pageX2"]), let y2 = number(value["pageY2"]),
              x2 > x1, y2 > y1 else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "The pinned engine's visible document rectangle is unavailable"])
        }
        var canvas = CGRect.zero
        if let c = value["canvasRect"] as? [String: Any],
           let x = number(c["x"]), let y = number(c["y"]),
           let w = number(c["width"]), let h = number(c["height"]) {
            canvas = CGRect(x: x, y: y, width: w, height: h)
        }
        return Geometry(pageX1: x1, pageY1: y1, pageX2: x2, pageY2: y2, canvasRect: canvas)
    }

    private struct Snapshot {
        let image: UIImage
        let width: Int
        let height: Int
        let pixels: [UInt8]
        let scale: CGFloat
    }

    private func snapshot(_ web: WKWebView, root: URL, name: String,
                          afterScreenUpdates: Bool = true) async throws -> Snapshot {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = afterScreenUpdates
        let image = try await web.takeSnapshot(configuration: configuration)
        guard let cg = image.cgImage,
              let bytes = rgbaBytes(cg) else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "The WKWebView snapshot could not be decoded as RGBA"])
        }
        let png = root.appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: png, options: .atomic)
        attach(png, name: name)
        let scale = CGFloat(cg.width) / max(1, web.bounds.width)
        return Snapshot(image: image, width: cg.width, height: cg.height, pixels: bytes, scale: scale)
    }

    private func attach(_ snapshot: Snapshot, name: String) {
        let attachment = XCTAttachment(image: snapshot.image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let flags = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: flags) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return rendered ? bytes : nil
    }

    // MARK: - Colored region and pixel metrics

    private struct Region {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
        var area: Int { max(0, width) * max(0, height) }
        var facts: [String: Any] { ["x": x, "y": y, "width": width, "height": height] }
    }

    private func coloredRegion(in snapshot: Snapshot, within rect: CGRect?) -> Region? {
        var scanX0 = 0, scanY0 = 0, scanX1 = snapshot.width, scanY1 = snapshot.height
        if let rect, rect.width > 4, rect.height > 4 {
            scanX0 = max(0, Int(rect.minX.rounded(.down)))
            scanY0 = max(0, Int(rect.minY.rounded(.down)))
            scanX1 = min(snapshot.width, Int(rect.maxX.rounded(.up)))
            scanY1 = min(snapshot.height, Int(rect.maxY.rounded(.up)))
        }
        guard scanX1 > scanX0, scanY1 > scanY0 else { return nil }
        // The bbox of all matches can also capture isolated anti-aliased or
        // chrome pixels that happen to fall inside the color tolerance, which
        // inflates the region far beyond the shaded cell. Use the largest
        // 4-connected matching component so the stroke is localized to the
        // cell itself.
        let w = scanX1 - scanX0, h = scanY1 - scanY0
        var mask = [Bool](repeating: false, count: w * h)
        for y in scanY0..<scanY1 {
            let row = y * snapshot.width
            for x in scanX0..<scanX1 {
                let i = (row + x) * 4
                if Self.isFixtureBlue(Int(snapshot.pixels[i]), Int(snapshot.pixels[i + 1]),
                                      Int(snapshot.pixels[i + 2])) {
                    mask[(y - scanY0) * w + (x - scanX0)] = true
                }
            }
        }
        var visited = [Bool](repeating: false, count: w * h)
        var bestCount = 0, bestX0 = 0, bestY0 = 0, bestX1 = -1, bestY1 = -1
        var stack: [Int] = []
        for start in 0..<(w * h) where mask[start] && !visited[start] {
            visited[start] = true
            stack.append(start)
            var count = 0, mnx = Int.max, mny = Int.max, mxx = Int.min, mxy = Int.min
            while let cur = stack.popLast() {
                let cy = cur / w, cx = cur % w
                count += 1
                mnx = min(mnx, cx); mxx = max(mxx, cx)
                mny = min(mny, cy); mxy = max(mxy, cy)
                let left = cx > 0 ? cur - 1 : -1
                let right = cx + 1 < w ? cur + 1 : -1
                let up = cy > 0 ? cur - w : -1
                let down = cy + 1 < h ? cur + w : -1
                for nb in [left, right, up, down] where nb >= 0 && mask[nb] && !visited[nb] {
                    visited[nb] = true
                    stack.append(nb)
                }
            }
            if count > bestCount {
                bestCount = count
                bestX0 = mnx; bestY0 = mny; bestX1 = mxx; bestY1 = mxy
            }
        }
        guard bestCount > 0 else { return nil }
        let region = Region(x: scanX0 + bestX0, y: scanY0 + bestY0,
                            width: bestX1 - bestX0 + 1, height: bestY1 - bestY0 + 1)
        guard region.area >= 2_500, region.width >= 50, region.height >= 40 else { return nil }
        return region
    }

    private struct RegionMetrics {
        let area: Int
        let blue: Int
        let dark: Int
        let nearWhite: Int
        let yellow: Int
        let centerMean: (Double, Double, Double)
        var facts: [String: Any] {
            ["area": area, "blue": blue, "dark": dark, "nearWhite": nearWhite,
             "yellow": yellow, "centerMean": [centerMean.0, centerMean.1, centerMean.2]]
        }
    }

    private func metrics(in snapshot: Snapshot, region: Region) -> RegionMetrics {
        var blue = 0, dark = 0, white = 0, yellow = 0
        var sr = 0.0, sg = 0.0, sb = 0.0, sn = 0.0
        let x0 = max(0, region.x), y0 = max(0, region.y)
        let x1 = min(snapshot.width, region.x + region.width)
        let y1 = min(snapshot.height, region.y + region.height)
        guard x1 > x0, y1 > y0 else {
            return RegionMetrics(area: 0, blue: 0, dark: 0, nearWhite: 0, yellow: 0,
                                 centerMean: (0, 0, 0))
        }
        let cx0 = x0 + (x1 - x0) / 4, cx1 = x1 - (x1 - x0) / 4
        let cy0 = y0 + (y1 - y0) / 4, cy1 = y1 - (y1 - y0) / 4
        for y in y0..<y1 {
            let row = y * snapshot.width
            for x in x0..<x1 {
                let i = (row + x) * 4
                let r = Int(snapshot.pixels[i])
                let g = Int(snapshot.pixels[i + 1])
                let b = Int(snapshot.pixels[i + 2])
                if Self.isFixtureBlue(r, g, b) { blue += 1 }
                let luma = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
                if luma < 120 { dark += 1 }
                if r > 235 && g > 235 && b > 235 { white += 1 }
                if r > 180 && g > 140 && b < 190 && r > b + 25 { yellow += 1 }
                if x >= cx0 && x < cx1 && y >= cy0 && y < cy1 {
                    sr += Double(r); sg += Double(g); sb += Double(b); sn += 1
                }
            }
        }
        let center = sn > 0 ? (sr / sn, sg / sn, sb / sn) : (0.0, 0.0, 0.0)
        return RegionMetrics(area: (x1 - x0) * (y1 - y0), blue: blue, dark: dark,
                             nearWhite: white, yellow: yellow, centerMean: center)
    }

    private func assertPreserved(before: RegionMetrics, after: RegionMetrics,
                                 label: String,
                                 beforeName: String, afterName: String) throws {
        // Ratios tolerate the control/final reopen being at a slightly
        // different page zoom while still failing a white rectangle that
        // replaces most of the cell.
        let beforeArea = Double(max(1, before.area))
        let afterArea = Double(max(1, after.area))
        let blueBefore = Double(before.blue) / beforeArea
        let blueAfter = Double(after.blue) / afterArea
        let darkBefore = Double(before.dark) / beforeArea
        let darkAfter = Double(after.dark) / afterArea
        let whiteBefore = Double(before.nearWhite) / beforeArea
        let whiteAfter = Double(after.nearWhite) / afterArea
        XCTAssertGreaterThanOrEqual(blueAfter, blueBefore * 0.35,
            "\(label): the blue cell/background is no longer visible enough. "
            + "blue ratio \(blueBefore) -> \(blueAfter); before=\(before.facts) after=\(after.facts). "
            + "Expected the non-white \(beforeName) to remain under/around the highlighter.")
        XCTAssertGreaterThanOrEqual(darkAfter, darkBefore * 0.45,
            "\(label): black text/grid pixels were erased. dark ratio \(darkBefore) -> \(darkAfter); "
            + "before=\(before.facts) after=\(after.facts). "
            + "A rectangular white highlighter background would remove the \(beforeName).")
        let whiteAllowance = whiteBefore + 0.05
        XCTAssertLessThanOrEqual(whiteAfter, whiteAllowance,
            "\(label): the near-white fraction in the highlighter cell grew from \(whiteBefore) to "
            + "\(whiteAfter) (allowance \(whiteAllowance)). before=\(before.facts) "
            + "after=\(after.facts). This is the user-reported rectangular white background signature.")
    }

    private func centerDelta(before: Snapshot, after: Snapshot, region: Region) -> Double {
        let b = metrics(in: before, region: region).centerMean
        let a = metrics(in: after, region: region).centerMean
        return max(abs(a.0 - b.0), max(abs(a.1 - b.1), abs(a.2 - b.2)))
    }

    /// Linear interpolation of the intended polyline at <= 4 CSS px. The
    /// production gate receives one continuous contact; the cap is a hard
    /// fixture/path assertion, not a silent thinning step.
    private func densified(_ points: [[Double]], maxStep: Double = 3.0,
                           limit: Int = 512) throws -> [[Double]] {
        guard points.count >= 2 else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 40, userInfo: [
                NSLocalizedDescriptionKey: "The planned stroke has fewer than two points"])
        }
        guard maxStep > 0, maxStep <= 4.0 else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 41, userInfo: [
                NSLocalizedDescriptionKey: "The dense-contact step must be within 2...4 CSS px"])
        }
        var result: [[Double]] = [points[0]]
        for index in 1..<points.count {
            let a = points[index - 1], b = points[index]
            guard a.count == 2, b.count == 2 else {
                throw NSError(domain: "OfficeHighlighterAlpha", code: 42, userInfo: [
                    NSLocalizedDescriptionKey: "The planned stroke contains a non-2D point"])
            }
            let dx = b[0] - a[0], dy = b[1] - a[1]
            let length = hypot(dx, dy)
            let steps = max(1, Int(ceil(length / maxStep)))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                result.append([a[0] + dx * t, a[1] + dy * t])
            }
            guard result.count <= limit else {
                throw NSError(domain: "OfficeHighlighterAlpha", code: 43, userInfo: [
                    NSLocalizedDescriptionKey: "The dense stroke needs more than \(limit) points; "
                        + "adjust the fixture/path instead of widening the interval"])
            }
        }
        return result
    }

    private func strokeDensityFacts(original: [[Double]], dense: [[Double]]) -> [String: Any] {
        var maxStep = 0.0, total = 0.0
        if dense.count >= 2 {
            for index in 1..<dense.count {
                let dx = dense[index][0] - dense[index - 1][0]
                let dy = dense[index][1] - dense[index - 1][1]
                let step = hypot(dx, dy)
                maxStep = max(maxStep, step)
                total += step
            }
        }
        return ["originalVertices": original.count, "inputPointCount": dense.count,
                "movesDispatched": max(0, dense.count - 1),
                "maxStepCss": maxStep, "plannedPathLengthCss": total]
    }

    private struct InteriorPatch {
        let quadrant: String
        let centerX: Int
        let centerY: Int
        let distance: Double
        let clearance: Double
        var facts: [String: Any] {
            ["quadrant": quadrant, "x": centerX, "y": centerY,
             "distance": distance, "clearance": clearance]
        }
    }

    private struct PatchDelta {
        let worst: Double
        let facts: [[String: Any]]
    }

    private func imagePath(_ points: [[Double]], scale: CGFloat) -> [CGPoint] {
        points.compactMap { point in
            guard point.count == 2 else { return nil }
            return CGPoint(x: CGFloat(point[0] * Double(scale)),
                           y: CGFloat(point[1] * Double(scale)))
        }
    }

    /// Predeclared interior samples, one per bbox quadrant. Every pixel of the
    /// 5x5 patch must clear the actual 4 mm half-width plus AA and smoothing
    /// margin to the full planned path. If a quadrant cannot qualify, the
    /// fixture/path is invalid; the threshold is never lowered.
    private func interiorSamplePatches(points: [[Double]], snapshot: Snapshot,
                                       cell: Region) throws -> [InteriorPatch] {
        let path = imagePath(points, scale: snapshot.scale)
        guard path.count >= 2 else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 44, userInfo: [
                NSLocalizedDescriptionKey: "The planned stroke cannot produce image-space samples"])
        }
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for point in path {
            minX = min(minX, Double(point.x)); maxX = max(maxX, Double(point.x))
            minY = min(minY, Double(point.y)); maxY = max(maxY, Double(point.y))
        }
        guard maxX > minX, maxY > minY else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 45, userInfo: [
                NSLocalizedDescriptionKey: "The planned stroke bbox is degenerate"])
        }
        let clearance = 4.0 / 25.4 * 96.0 * Double(snapshot.scale) * 0.5 + 2.0 + 6.0
        let quadrants: [(String, Double, Double)] = [
            ("topLeft", 0.25, 0.25), ("topRight", 0.75, 0.25),
            ("bottomLeft", 0.25, 0.75), ("bottomRight", 0.75, 0.75)
        ]
        var patches: [InteriorPatch] = []
        for (name, fx, fy) in quadrants {
            let centerX = Int((minX + (maxX - minX) * fx).rounded())
            let centerY = Int((minY + (maxY - minY) * fy).rounded())
            guard centerX - 2 >= cell.x, centerX + 2 < cell.x + cell.width,
                  centerY - 2 >= cell.y, centerY + 2 < cell.y + cell.height,
                  centerX - 2 >= 0, centerX + 2 < snapshot.width,
                  centerY - 2 >= 0, centerY + 2 < snapshot.height else {
                throw NSError(domain: "OfficeHighlighterAlpha", code: 46, userInfo: [
                    NSLocalizedDescriptionKey: "\(name): the 5x5 patch at (\(centerX),\(centerY)) "
                        + "is not wholly inside the colored cell \(cell.facts)"])
            }
            let distance = minimumPatchDistance(centerX: centerX, centerY: centerY, path: path)
            guard distance > clearance else {
                throw NSError(domain: "OfficeHighlighterAlpha", code: 47, userInfo: [
                    NSLocalizedDescriptionKey: "\(name): the 5x5 patch at (\(centerX),\(centerY)) "
                        + "has distance \(distance) <= clearance \(clearance); the fixture/path "
                        + "does not provide a non-stroke oracle"])
            }
            patches.append(InteriorPatch(quadrant: name, centerX: centerX, centerY: centerY,
                                         distance: distance, clearance: clearance))
        }
        guard Set(patches.map(\.quadrant)).count == 4 else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 48, userInfo: [
                NSLocalizedDescriptionKey: "The non-stroke samples do not cover four quadrants"])
        }
        return patches
    }

    private func minimumPatchDistance(centerX: Int, centerY: Int, path: [CGPoint]) -> Double {
        guard path.count >= 2 else { return 0 }
        var minimum = Double.greatestFiniteMagnitude
        for dy in -2...2 {
            for dx in -2...2 {
                let point = CGPoint(x: CGFloat(centerX + dx) + 0.5,
                                    y: CGFloat(centerY + dy) + 0.5)
                var nearest = Double.greatestFiniteMagnitude
                for index in 1..<path.count {
                    nearest = min(nearest,
                                  distanceToSegment(point, path[index - 1], path[index]))
                }
                minimum = min(minimum, nearest)
            }
        }
        return minimum
    }

    private func patchMean(_ snapshot: Snapshot, centerX: Int,
                           centerY: Int) -> (Double, Double, Double) {
        var red = 0.0, green = 0.0, blue = 0.0
        for dy in -2...2 {
            for dx in -2...2 {
                let index = ((centerY + dy) * snapshot.width + centerX + dx) * 4
                red += Double(snapshot.pixels[index])
                green += Double(snapshot.pixels[index + 1])
                blue += Double(snapshot.pixels[index + 2])
            }
        }
        let count = 25.0
        return (red / count, green / count, blue / count)
    }

    private func patchDelta(before: Snapshot, after: Snapshot,
                            patches: [InteriorPatch],
                            mapped: [InteriorPatch]? = nil) throws -> PatchDelta {
        guard before.width == after.width, before.height == after.height else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 49, userInfo: [
                NSLocalizedDescriptionKey: "The live/control and final snapshots have different sizes"])
        }
        let mappedCount = mapped?.count ?? patches.count
        guard !patches.isEmpty, mappedCount == patches.count else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 50, userInfo: [
                NSLocalizedDescriptionKey: "The non-stroke patch set is empty or misaligned"])
        }
        var worst = 0.0
        var facts: [[String: Any]] = []
        for (index, patch) in patches.enumerated() {
            let target = mapped?[index] ?? patch
            let beforeMean = patchMean(before, centerX: patch.centerX, centerY: patch.centerY)
            let afterMean = patchMean(after, centerX: target.centerX, centerY: target.centerY)
            let delta = max(abs(afterMean.0 - beforeMean.0),
                            max(abs(afterMean.1 - beforeMean.1),
                                abs(afterMean.2 - beforeMean.2)))
            worst = max(worst, delta)
            var fact = patch.facts
            if mapped != nil {
                fact["afterX"] = target.centerX
                fact["afterY"] = target.centerY
                fact["mappedDistance"] = target.distance
                fact["mappedClearance"] = target.clearance
            }
            fact["beforeMean"] = [beforeMean.0, beforeMean.1, beforeMean.2]
            fact["afterMean"] = [afterMean.0, afterMean.1, afterMean.2]
            fact["delta"] = delta
            facts.append(fact)
        }
        return PatchDelta(worst: worst, facts: facts)
    }

    private func mappedInteriorPatches(_ patches: [InteriorPatch],
                                       from control: Region, to final: Region,
                                       snapshot: Snapshot,
                                       points: [[Double]]) throws -> [InteriorPatch] {
        let toleranceX = max(4, control.width / 32)
        let toleranceY = max(4, control.height / 32)
        XCTAssertLessThanOrEqual(abs(final.width - control.width), toleranceX,
                                 "The final blue cell width changed from \(control.facts) to \(final.facts); "
                                     + "mapped samples would be invalid")
        XCTAssertLessThanOrEqual(abs(final.height - control.height), toleranceY,
                                 "The final blue cell height changed from \(control.facts) to \(final.facts); "
                                     + "mapped samples would be invalid")
        XCTAssertLessThanOrEqual(abs(final.x - control.x), toleranceX,
                                 "The final blue cell X moved from \(control.facts) to \(final.facts); "
                                     + "mapped samples would be invalid")
        XCTAssertLessThanOrEqual(abs(final.y - control.y), toleranceY,
                                 "The final blue cell Y moved from \(control.facts) to \(final.facts); "
                                     + "mapped samples would be invalid")
        guard abs(final.width - control.width) <= toleranceX,
              abs(final.height - control.height) <= toleranceY,
              abs(final.x - control.x) <= toleranceX,
              abs(final.y - control.y) <= toleranceY else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 51, userInfo: [
                NSLocalizedDescriptionKey: "The control and final blue cells are not aligned: "
                    + "\(control.facts) vs \(final.facts)"])
        }
        let path = imagePath(points, scale: snapshot.scale)
        guard path.count >= 2 else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 52, userInfo: [
                NSLocalizedDescriptionKey: "The reopened planned stroke has no image-space samples"])
        }
        let clearance = 4.0 / 25.4 * 96.0 * Double(snapshot.scale) * 0.5 + 2.0 + 6.0
        var mapped: [InteriorPatch] = []
        for patch in patches {
            let nx = (Double(patch.centerX) - Double(control.x)) / Double(max(1, control.width))
            let ny = (Double(patch.centerY) - Double(control.y)) / Double(max(1, control.height))
            let centerX = Int((Double(final.x) + nx * Double(final.width)).rounded())
            let centerY = Int((Double(final.y) + ny * Double(final.height)).rounded())
            guard centerX - 2 >= final.x, centerX + 2 < final.x + final.width,
                  centerY - 2 >= final.y, centerY + 2 < final.y + final.height,
                  centerX - 2 >= 0, centerX + 2 < snapshot.width,
                  centerY - 2 >= 0, centerY + 2 < snapshot.height else {
                throw NSError(domain: "OfficeHighlighterAlpha", code: 53, userInfo: [
                    NSLocalizedDescriptionKey: "\(patch.quadrant): the mapped 5x5 patch at "
                        + "(\(centerX),\(centerY)) is not wholly inside the final cell \(final.facts)"])
            }
            let distance = minimumPatchDistance(centerX: centerX, centerY: centerY, path: path)
            guard distance > clearance else {
                throw NSError(domain: "OfficeHighlighterAlpha", code: 54, userInfo: [
                    NSLocalizedDescriptionKey: "\(patch.quadrant): the mapped patch at "
                        + "(\(centerX),\(centerY)) has distance \(distance) <= clearance \(clearance)"])
            }
            mapped.append(InteriorPatch(quadrant: patch.quadrant, centerX: centerX,
                                        centerY: centerY, distance: distance,
                                        clearance: clearance))
        }
        return mapped
    }

    private func changedPixels(before: Snapshot, after: Snapshot, region: Region) -> Int {
        guard before.width == after.width, before.height == after.height else { return -1 }
        var changed = 0
        let x0 = max(0, region.x), y0 = max(0, region.y)
        let x1 = min(before.width, region.x + region.width)
        let y1 = min(before.height, region.y + region.height)
        guard x1 > x0, y1 > y0 else { return 0 }
        for y in y0..<y1 {
            let row = y * before.width
            for x in x0..<x1 {
                let i = (row + x) * 4
                let d = max(abs(Int(after.pixels[i]) - Int(before.pixels[i])),
                            max(abs(Int(after.pixels[i + 1]) - Int(before.pixels[i + 1])),
                                abs(Int(after.pixels[i + 2]) - Int(before.pixels[i + 2]))))
                if d > 18 { changed += 1 }
            }
        }
        return changed
    }

    /// Convert the detected cell rectangle into client CSS points and build a
    /// U-shaped freehand path with its interior far from the 4 mm band.
    private func strokePoints(in region: Region, fractions: [(Double, Double)],
                              imageScale: CGFloat, canvas: CGRect) -> [[Double]] {
        let x0 = CGFloat(region.x) / imageScale
        let y0 = CGFloat(region.y) / imageScale
        let w = CGFloat(region.width) / imageScale
        let h = CGFloat(region.height) / imageScale
        var points: [[Double]] = []
        for (fx, fy) in fractions {
            var px = x0 + w * fx
            var py = y0 + h * fy
            if canvas.width > 2 && canvas.height > 2 {
                px = min(max(px, canvas.minX + 2), canvas.maxX - 2)
                py = min(max(py, canvas.minY + 2), canvas.maxY - 2)
            }
            points.append([Double(px), Double(py)])
        }
        return points
    }

    private func strokeBBox(points: [[Double]], scale: CGFloat,
                            imageWidth: Int, imageHeight: Int) -> Region {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
        for point in points where point.count == 2 {
            let x = point[0] * Double(scale)
            let y = point[1] * Double(scale)
            minX = min(minX, x); minY = min(minY, y)
            maxX = max(maxX, x); maxY = max(maxY, y)
        }
        let margin = 8.0
        let x0 = max(0, Int((minX - margin).rounded(.down)))
        let y0 = max(0, Int((minY - margin).rounded(.down)))
        let x1 = min(imageWidth, Int((maxX + margin).rounded(.up)))
        let y1 = min(imageHeight, Int((maxY + margin).rounded(.up)))
        return Region(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }

    private func strokeBBox(in region: Region, fractions: [(Double, Double)],
                            imageWidth: Int, imageHeight: Int) -> Region {
        let x0 = Double(region.x), y0 = Double(region.y)
        let w = Double(region.width), h = Double(region.height)
        let points = fractions.map { [x0 + w * $0.0, y0 + h * $0.1] }
        return strokeBBox(points: points, scale: 1,
                          imageWidth: imageWidth, imageHeight: imageHeight)
    }

    private func validateROI(_ roi: Region, within cell: Region, label: String) throws {
        guard roi.area >= 2_000, roi.width >= 40, roi.height >= 40,
              roi.x >= cell.x, roi.y >= cell.y,
              roi.x + roi.width <= cell.x + cell.width,
              roi.y + roi.height <= cell.y + cell.height else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 15, userInfo: [
                NSLocalizedDescriptionKey: "\(label): the computed stroke bounding box \(roi.facts) "
                    + "is not a sufficiently large region inside the shaded cell \(cell.facts)"])
        }
    }

    private static let previewStateScript = #"""
    return JSON.stringify(window.__floeOfficePenState ? window.__floeOfficePenState() : null);
    """#

    private func currentPreviewState(_ web: WKWebView) async throws -> [String: Any] {
        var raw: Any?
        do {
            raw = try await web.callAsyncJavaScript(Self.previewStateScript, arguments: [:],
                                                    in: nil, contentWorld: .page)
        } catch {
            raw = nil
        }
        if let json = raw as? String, json.utf8.count <= 16_384,
           let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
           let value = object as? [String: Any] {
            return value
        }
        return ["available": false]
    }

    private func waitForPreviewRetirement(_ web: WKWebView, timeout: TimeInterval) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any] = ["available": false]
        while Date() < deadline {
            var raw: Any?
            do {
                raw = try await web.callAsyncJavaScript(Self.previewStateScript, arguments: [:],
                                                        in: nil, contentWorld: .page)
            } catch {
                raw = nil
            }
            if let json = raw as? String, json.utf8.count <= 16_384,
               let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
               let value = object as? [String: Any] {
                last = value
                if (value["livePreview"] as? Bool) == false { return value }
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        last["timedOut"] = true
        return last
    }

    /// Wait for the real in-progress contact and its presentation preview to
    /// both be active. This is the boundary the retired-preview gate cannot
    /// prove; a timeout is recorded and the mid-contact snapshot still runs so
    /// the failure retains actual pixels instead of skipping the case.
    private func waitForActivePreview(_ web: WKWebView,
                                      timeout: TimeInterval) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any] = ["available": false]
        while Date() < deadline {
            last = try await currentPreviewState(web)
            if (last["activeStroke"] as? Bool) == true,
               (last["livePreview"] as? Bool) == true {
                return last
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        last["timedOut"] = true
        return last
    }

    private struct BandTextFacts {
        let beforeDark: Int
        let afterDark: Int
        let bandPixels: Int
        var facts: [String: Any] {
            ["beforeDark": beforeDark, "afterDark": afterDark, "bandPixels": bandPixels]
        }
    }

    private func bandDarkPixels(before: Snapshot, after: Snapshot,
                                points: [[Double]], scale: CGFloat,
                                search: Region) -> BandTextFacts {
        let path = points.map { CGPoint(x: $0[0] * Double(scale), y: $0[1] * Double(scale)) }
        guard path.count >= 2, before.width == after.width, before.height == after.height else {
            return BandTextFacts(beforeDark: 0, afterDark: 0, bandPixels: 0)
        }
        // 4.0 mm at 96 dpi, half-width in image pixels, plus AA margin.
        let bandHalf = max(6.0, 4.0 / 25.4 * 96.0 * Double(scale) * 0.5 + 3.0)
        let x0 = max(0, search.x), y0 = max(0, search.y)
        let x1 = min(before.width, search.x + search.width)
        let y1 = min(before.height, search.y + search.height)
        guard x1 > x0, y1 > y0 else {
            return BandTextFacts(beforeDark: 0, afterDark: 0, bandPixels: 0)
        }
        var beforeDark = 0, afterDark = 0, bandPixels = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let p = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                var distance = Double.greatestFiniteMagnitude
                for i in 1..<path.count {
                    distance = min(distance, distanceToSegment(p, path[i - 1], path[i]))
                    if distance <= bandHalf { break }
                }
                guard distance <= bandHalf else { continue }
                bandPixels += 1
                let index = (y * before.width + x) * 4
                let lb = 0.2126 * Double(before.pixels[index])
                    + 0.7152 * Double(before.pixels[index + 1])
                    + 0.0722 * Double(before.pixels[index + 2])
                let la = 0.2126 * Double(after.pixels[index])
                    + 0.7152 * Double(after.pixels[index + 1])
                    + 0.0722 * Double(after.pixels[index + 2])
                if lb < 120 { beforeDark += 1 }
                if la < 120 { afterDark += 1 }
            }
        }
        return BandTextFacts(beforeDark: beforeDark, afterDark: afterDark, bandPixels: bandPixels)
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared <= 1e-9 {
            return hypot(Double(p.x - a.x), Double(p.y - a.y))
        }
        let t = max(0.0, min(1.0, (Double(p.x - a.x) * dx + Double(p.y - a.y) * dy) / lengthSquared))
        let x = Double(a.x) + t * dx, y = Double(a.y) + t * dy
        return hypot(Double(p.x) - x, Double(p.y) - y)
    }

    // MARK: - Saved XML

    private func assertSavedHighlighterXML(_ xmlData: Data) throws -> [String: Any] {
        let xml = String(decoding: xmlData, as: UTF8.self)
        let blocks = xml.components(separatedBy: "<wps:wsp>").dropFirst().compactMap {
            $0.components(separatedBy: "</wps:wsp>").first
        }
        let highlighter = blocks.filter {
            $0.contains("FFCC00") && $0.contains("alpha val=\"40000\"")
        }
        XCTAssertEqual(highlighter.count, 1,
                       "Expected exactly one saved #FFCC00 / 40%-opacity highlighter path; "
                       + "found \(highlighter.count) of \(blocks.count) DML shapes")
        guard let shape = highlighter.first else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "No saved highlighter DML shape with #FFCC00 and alpha 40000"])
        }
        XCTAssertTrue(shape.contains("<a:path fill=\"none\""),
                      "The saved highlighter path is not an unfilled open path: \(shape.prefix(600))")
        guard let lineStart = shape.range(of: "<a:ln ")?.lowerBound else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "The saved highlighter shape has no <a:ln ...> element"])
        }
        let beforeLine = String(shape[..<lineStart])
        XCTAssertFalse(beforeLine.contains("<a:solidFill"),
                       "The saved highlighter shape carries a shape fill before its line: \(shape.prefix(600))")
        let lineTag = String(shape[lineStart...].prefix(160))
        let lineWidthEMU = lineTag.split(separator: "\"").compactMap { Int($0) }.first
        // Writer stores the 4.0 mm request in twips; allow one twip (635 EMU)
        // for the round trip, exactly like the existing saved-alpha gate.
        XCTAssertTrue(lineWidthEMU.map { abs($0 - 144_000) <= 635 } == true,
                      "The saved highlighter line width is not the 4.0 mm request: \(lineTag)")
        return ["dmlShapes": blocks.count, "highlighterShapes": highlighter.count,
                "pathFillNone": true, "lineColor": "FFCC00", "lineAlpha": 40_000,
                "lineEMU": lineWidthEMU ?? -1]
    }

    private func xlsxDrawingMember(_ url: URL) throws -> String {
        let archive = try Archive(url: url, accessMode: .read)
        var members: [String] = []
        for entry in archive where entry.type == .file {
            let path = entry.path
            guard path.hasPrefix("xl/drawings/"), path.hasSuffix(".xml") else { continue }
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            guard name.hasPrefix("drawing") else { continue }
            members.append(path)
        }
        let sorted = members.sorted()
        guard sorted.count == 1, let member = sorted.first else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 22, userInfo: [
                NSLocalizedDescriptionKey: "Expected exactly one xl/drawings/drawing*.xml member; "
                    + "found \(sorted)"])
        }
        return member
    }

    /// Excel saves the same DML path inside a spreadsheetDrawing xdr:sp.
    /// This validates that actual member, its one highlighter style and a
    /// valid enclosing sheet anchor; the Word wps/document.xml check is not
    /// reused as Excel evidence.
    private func assertSavedHighlighterDrawingXML(_ xmlData: Data) throws -> [String: Any] {
        let xml = String(decoding: xmlData, as: UTF8.self)
        let ns = xml as NSString
        let shapeRegex = try NSRegularExpression(
            pattern: #"<xdr:sp(?:\s[^>]*)?>.*?</xdr:sp>"#,
            options: [.dotMatchesLineSeparators])
        let matches = shapeRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        let shapes = matches.map { ns.substring(with: $0.range) }
        XCTAssertGreaterThan(shapes.count, 0,
                             "The saved XLSX drawing has no <xdr:sp> shape")
        let highlighter = shapes.filter {
            $0.contains("FFCC00") && $0.contains("alpha val=\"40000\"")
        }
        XCTAssertEqual(highlighter.count, 1,
                       "Expected exactly one saved xlsx #FFCC00 / 40%-opacity highlighter path; "
                       + "found \(highlighter.count) of \(shapes.count) xdr:sp shapes")
        guard let shape = highlighter.first else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 23, userInfo: [
                NSLocalizedDescriptionKey: "No saved xlsx highlighter xdr:sp with #FFCC00 and alpha 40000"])
        }
        XCTAssertTrue(shape.contains("<a:path fill=\"none\""),
                      "The saved xlsx highlighter path is not an unfilled open path: \(shape.prefix(600))")
        XCTAssertTrue(shape.contains("<a:pt "),
                      "The saved xlsx highlighter path has no real geometry points: \(shape.prefix(600))")
        guard let lineStart = shape.range(of: "<a:ln ")?.lowerBound else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 24, userInfo: [
                NSLocalizedDescriptionKey: "The saved xlsx highlighter shape has no <a:ln ...> element"])
        }
        let beforeLine = String(shape[..<lineStart])
        XCTAssertFalse(beforeLine.contains("<a:solidFill"),
                       "The saved xlsx highlighter shape carries a shape fill before its line: "
                           + "\(shape.prefix(600))")
        let lineTag = String(shape[lineStart...].prefix(240))
        XCTAssertTrue(lineTag.contains("FFCC00"),
                      "The saved xlsx highlighter line is not #FFCC00: \(lineTag)")
        XCTAssertTrue(lineTag.contains("alpha val=\"40000\""),
                      "The saved xlsx highlighter line is not 40% opaque: \(lineTag)")
        let lineWidthEMU = firstIntegerAttribute(named: "w", in: lineTag)
        XCTAssertTrue(lineWidthEMU.map { abs($0 - 144_000) <= 635 } == true,
                      "The saved xlsx highlighter line width is not the 4.0 mm request: \(lineTag)")
        guard let anchor = spreadsheetAnchor(containing: shape, in: xml) else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 25, userInfo: [
                NSLocalizedDescriptionKey: "The saved xlsx highlighter shape has no enclosing xdr anchor"])
        }
        XCTAssertTrue((anchor["valid"] as? Bool) == true,
                      "The saved xlsx highlighter anchor is not a valid visible sheet anchor: \(anchor)")
        return ["drawingShapes": shapes.count, "highlighterShapes": highlighter.count,
                "pathFillNone": true, "lineColor": "FFCC00", "lineAlpha": 40_000,
                "lineEMU": lineWidthEMU ?? -1, "anchor": anchor]
    }

    private func firstIntegerAttribute(named name: String, in tag: String) -> Int? {
        guard let range = tag.range(of: " \(name)=\"") else { return nil }
        let digits = tag[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    private func spreadsheetAnchor(containing shape: String, in xml: String) -> [String: Any]? {
        for kind in ["twoCellAnchor", "oneCellAnchor", "absoluteAnchor"] {
            let open = "<xdr:\(kind)"
            let close = "</xdr:\(kind)>"
            var search = xml.startIndex
            while let start = xml.range(of: open, range: search..<xml.endIndex) {
                guard let end = xml.range(of: close,
                                          range: start.lowerBound..<xml.endIndex) else { break }
                let block = String(xml[start.lowerBound..<end.upperBound])
                if block.contains(shape) {
                    return spreadsheetAnchorFacts(kind: kind, block: block)
                }
                search = end.upperBound
            }
        }
        return nil
    }

    private func spreadsheetAnchorFacts(kind: String, block: String) -> [String: Any]? {
        func marker(_ side: String) -> [String: Int]? {
            let open = "<xdr:\(side)>", close = "</xdr:\(side)>"
            guard let start = block.range(of: open),
                  let end = block.range(of: close, range: start.upperBound..<block.endIndex) else {
                return nil
            }
            let inner = String(block[start.upperBound..<end.lowerBound])
            var values: [String: Int] = [:]
            for key in ["col", "colOff", "row", "rowOff"] {
                let elementOpen = "<xdr:\(key)>"
                let elementClose = "</xdr:\(key)>"
                guard let elementStart = inner.range(of: elementOpen),
                      let elementEnd = inner.range(of: elementClose,
                                                   range: elementStart.upperBound..<inner.endIndex),
                      let value = Int(String(inner[elementStart.upperBound..<elementEnd.lowerBound])
                          .trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    return nil
                }
                values[key] = value
            }
            return values
        }
        func extent() -> (Int, Int)? {
            guard let start = block.range(of: "<xdr:ext") else { return nil }
            let tail = String(block[start.lowerBound...])
            guard let end = tail.range(of: ">") else { return nil }
            let tagText = String(tail[..<end.upperBound])
            guard let cx = firstIntegerAttribute(named: "cx", in: tagText),
                  let cy = firstIntegerAttribute(named: "cy", in: tagText) else { return nil }
            return (cx, cy)
        }
        var facts: [String: Any] = ["kind": kind, "valid": false]
        switch kind {
        case "twoCellAnchor":
            guard let from = marker("from"), let to = marker("to"),
                  from.values.allSatisfy({ $0 >= 0 }), to.values.allSatisfy({ $0 >= 0 }),
                  let fromCol = from["col"], let toCol = to["col"],
                  let fromColOff = from["colOff"], let toColOff = to["colOff"],
                  let fromRow = from["row"], let toRow = to["row"],
                  let fromRowOff = from["rowOff"], let toRowOff = to["rowOff"],
                  (toCol > fromCol || (toCol == fromCol && toColOff > fromColOff)),
                  (toRow > fromRow || (toRow == fromRow && toRowOff > fromRowOff)) else {
                return facts
            }
            facts["from"] = from
            facts["to"] = to
            facts["valid"] = true
            return facts
        case "oneCellAnchor":
            guard let from = marker("from"), from.values.allSatisfy({ $0 >= 0 }),
                  let ext = extent(), ext.0 > 0, ext.1 > 0 else { return facts }
            facts["from"] = from
            facts["cx"] = ext.0
            facts["cy"] = ext.1
            facts["valid"] = true
            return facts
        case "absoluteAnchor":
            guard let start = block.range(of: "<xdr:pos") else { return facts }
            let tail = String(block[start.lowerBound...])
            guard let end = tail.range(of: ">") else { return facts }
            let tagText = String(tail[..<end.upperBound])
            guard let x = firstIntegerAttribute(named: "x", in: tagText),
                  let y = firstIntegerAttribute(named: "y", in: tagText),
                  x >= 0, y >= 0,
                  let ext = extent(), ext.0 > 0, ext.1 > 0 else { return facts }
            facts["x"] = x
            facts["y"] = y
            facts["cx"] = ext.0
            facts["cy"] = ext.1
            facts["valid"] = true
            return facts
        default:
            return nil
        }
    }

    // MARK: - Reopen

    private func reopenImage(_ url: URL, scene: UIWindowScene, root: URL,
                             name: String) async throws -> (Snapshot, Geometry) {
        let session = OfficeFileSession()
        let window = mount(session, in: scene)
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        do {
            await session.open(url)
            try await wait(120, "\(name) reopen") {
                session.canAct && session.documentActionsReady && session.controller != nil
            }
            let native = try XCTUnwrap(session.controller as? FloeOfficeNativeViewController)
            try await waitForPaint(native)
            let web = try XCTUnwrap(OfficeExplicitSaveBridge.findWebView(in: native.view))
            try await Task.sleep(for: .milliseconds(450))
            let geometry = try await geometryProbe(web)
            let image = try await snapshot(web, root: root, name: name)
            if url.pathExtension.lowercased() == "xlsx" {
                // The Notes card uses the committed-PDF cover path, which is
                // distinct from the WK editor image. Preserve its actual PDF
                // and rendered PNG for the primary's visual/pixel comparison;
                // a successful editor snapshot alone cannot qualify the cover.
                let inputSHA = try hash(url)
                let exported = try await session.exportCommittedCoverPDF(expectedSHA256: inputSHA)
                defer { try? FileManager.default.removeItem(at: exported) }
                let pdf = root.appendingPathComponent("\(name)-cover.pdf")
                try FileManager.default.copyItem(at: exported, to: pdf)
                attach(pdf, name: "\(name)-cover-pdf")
                let data = try await Task.detached(priority: .userInitiated) {
                    try OfficeSavedCoverRenderer.firstPageData(at: pdf)
                }.value
                let png = root.appendingPathComponent("\(name)-cover.png")
                try data.write(to: png, options: .atomic)
                attach(png, name: "\(name)-cover-png")
                XCTAssertNotNil(UIImage(data: data), "The production cover renderer returned no image")
                XCTAssertEqual(try hash(url), inputSHA, "Cover export changed its committed input")
            }
            await session.release()
            return (image, geometry)
        } catch {
            // A wait/snapshot/geometry failure must not leave the engine
            // worker owned by this test window.
            await session.release()
            throw error
        }
    }

    private func pageImageRect(_ geometry: Geometry, scale: CGFloat) -> CGRect {
        CGRect(x: geometry.pageX1 * scale, y: geometry.pageY1 * scale,
               width: max(1, (geometry.pageX2 - geometry.pageX1) * scale),
               height: max(1, (geometry.pageY2 - geometry.pageY1) * scale))
    }

    // MARK: - Helpers

    private func number(_ value: Any?) -> CGFloat? {
        if let value = value as? NSNumber { return CGFloat(truncating: value) }
        if let value = value as? Double { return CGFloat(value) }
        if let value = value as? Int { return CGFloat(value) }
        return nil
    }

    private func mount(_ session: OfficeFileSession, in scene: UIWindowScene) -> UIWindow {
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(
            rootView: OfficeDocumentSurface(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        return window
    }

    private func wait(_ seconds: TimeInterval, _ stage: String,
                      _ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !ready(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        guard ready() else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "Timed out: \(stage)"])
        }
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

    private func rawMember(_ url: URL, path: String) throws -> Data {
        let archive = try Archive(url: url, accessMode: .read)
        guard let entry = archive[path] else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "Missing ZIP member \(path)"])
        }
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    private func writeReceipt(_ receipt: [String: Any], root: URL) throws {
        let url = root.appendingPathComponent("highlighter-alpha-receipt.json")
        try JSONSerialization.data(withJSONObject: receipt,
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: url, options: .atomic)
        attach(url, name: "highlighter-alpha-receipt")
    }
}

private extension OfficeHighlighterAlphaTests {
    func attach(_ url: URL, name: String) {
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
#endif
