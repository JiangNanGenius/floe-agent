// SPDX-License-Identifier: MPL-2.0
// Focused real-App regression for the reported Office highlighter defect:
// a transparent 4.0 mm / 60% highlighter stroke must not paint a rectangular
// white background over the document's colored background, text or grid.
//
// This suite builds its own synthetic DOCX (no user attachment bytes), opens
// it through the REAL OfficeFileSession/FloeOfficeNative production editor,
// dispatches REAL Pen PointerEvents through the production Pencil gate,
// snapshots the live WKWebView, saves through the production export, reopens
// the saved copy and repeats the pixel checks. It deliberately does not use a
// mocked UNO engine or an SVG-only preview as evidence.
//
// The test is opt-in on the canonical iPad Simulator:
//   FLOE_OFFICE_HIGHLIGHTER_ALPHA_QUALIFICATION=1
// It is not a physical-Apple-Pencil/device claim; root owns that acceptance.
//
// `FloeAppTests` uses an explicit project.yml source list. Root must register
// this file there and regenerate the Xcode project:
//   - path: Tests/FloeAppTests/OfficeHighlighterAlphaTests.swift
// and run the selector named in the handoff.

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

    /// One real App run covering:
    ///  - live snapshot before the stroke,
    ///  - a saved control copy with no ink,
    ///  - a real 4.0 mm / 60% highlighter U-stroke through the production
    ///    Pencil bridge,
    ///  - live snapshot after the stroke,
    ///  - the final saved copy reopened by the production engine,
    ///  - pixel checks over the stroke's colored cell in both live and
    ///    reopened surfaces.
    func testHighlighterAlphaPreservesColoredBackgroundTextAndGridLiveAndReopened() async throws {
        guard ProcessInfo.processInfo.environment[Self.qualificationEnvironment] == "1" else {
            throw XCTSkip("Opt-in real-App Office highlighter alpha regression; "
                + "set \(Self.qualificationEnvironment)=1 to run")
        }
        executionTimeAllowance = 600

        let fm = FileManager.default
        let documents = try fm.url(for: .documentDirectory, in: .userDomainMask,
                                   appropriateFor: nil, create: true)
        let root = documents.appendingPathComponent(
            "Qualification/OfficeHighlighterAlpha-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        print("FLOE_HIGHLIGHTER_ALPHA_ARTIFACT_ROOT=\(root.path)")

        let fixture = root.appendingPathComponent("highlighter-alpha.docx")
        try makeFixture(at: fixture)
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

        var receipt: [String: Any] = [
            "test": "OfficeHighlighterAlphaTests",
            "selector": "FloeAppTests/OfficeHighlighterAlphaTests/"
                + "testHighlighterAlphaPreservesColoredBackgroundTextAndGridLiveAndReopened",
            "route": "real OfficeFileSession/FloeOfficeNative production editor -> "
                + "production FloeOfficeNative Pencil gate -> real Pen PointerEvent -> "
                + "real frontend/core -> live WKWebView snapshot -> production export -> "
                + "production reopen -> pixel checks",
            "fixture": fixture.lastPathComponent,
            "fixtureSHA256": fixtureHash,
            "fixtureKind": "synthetic DOCX with #DCEBFF shaded table cell, black text, visible grid borders",
            "hardwarePencil": "not-tested",
            "physicalDevice": "not-tested"
        ]
        defer { try? writeReceipt(receipt, root: root) }

        let controlURL = root.appendingPathComponent("control-no-ink.docx")
        let finalURL = root.appendingPathComponent("final-highlighter.docx")
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
            // the whole cell, while its center stays far from the 4 mm band;
            // a rectangular white bbox fill would therefore be unmistakable.
            let points = strokePoints(in: region, imageScale: before.scale,
                                      canvas: geometry.canvasRect)
            let strokeROI = strokeBBox(points: points, scale: before.scale,
                                       imageWidth: before.width, imageHeight: before.height)
            try validateROI(strokeROI, within: region, label: "LIVE")
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

            let dispatched = try await dispatchStroke(web, points: points)
            receipt["stroke"] = dispatched
            XCTAssertEqual(dispatched["strokeDelta"] as? Int, 1,
                           "The production Pencil gate did not complete exactly one stroke: \(dispatched)")
            XCTAssertEqual(dispatched["activeAfter"] as? Bool, false,
                           "The production Pencil gate still has an active contact: \(dispatched)")
            XCTAssertGreaterThanOrEqual(dispatched["coreEventDelta"] as? Int ?? 0, 5,
                                        "Too few samples reached the engine: \(dispatched)")

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
            let liveCorners = cornerDelta(before: before, after: after, region: strokeROI)
            receipt["liveCornerDelta"] = liveCorners
            XCTAssertLessThanOrEqual(liveCorners, 18.0,
                                     "LIVE: a non-stroke inset corner of the highlighter bbox changed by "
                                     + "\(liveCorners) per-channel; the white rectangle reaches the corners")

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

            // Production export of the ink-bearing document. The saved XML
            // and the reopened pixels are separate gates.
            let finalExport = try await session.exportDocument(format: "docx")
            try fm.copyItem(at: finalExport, to: finalURL)
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
        // not a substitute for the pixel/reopen gates below.
        let savedXML = try rawMember(finalURL, path: "word/document.xml")
        let xmlFacts = try assertSavedHighlighterXML(savedXML)
        receipt["savedXML"] = xmlFacts

        // Reopen the control (no ink) and the final (highlighter) copies in
        // the same production editor. Both are plain local DOCX files opened
        // by the same code path; the control page is the oracle.
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
        let controlROI = strokeBBox(in: controlRegion, fractions: Self.strokeFractions,
                                    imageWidth: controlImage.width, imageHeight: controlImage.height)
        let finalROI = strokeBBox(in: finalRegion, fractions: Self.strokeFractions,
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
        let reopenedCorners = cornerDelta(before: controlImage, after: finalImage, region: controlROI)
        receipt["reopenCornerDelta"] = reopenedCorners
        XCTAssertLessThanOrEqual(reopenedCorners, 18.0,
                                 "REOPENED: a non-stroke inset corner of the highlighter bbox changed by "
                                 + "\(reopenedCorners) per-channel after save/reopen; the white "
                                 + "rectangle reaches the bbox corners")

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

    // MARK: - Production stroke dispatch

    private static let strokeScript = #"""
    const app = window.app;
    const container = app && app.sectionContainer;
    const canvas = container && container.canvas;
    if (!canvas || typeof window.PointerEvent !== 'function')
        return JSON.stringify({ok:false, reason:'no-canvas'});
    const points = Array.isArray(strokePoints) ? strokePoints.filter(p =>
        Array.isArray(p) && p.length === 2 && p.every(Number.isFinite)) : [];
    if (points.length < 2) return JSON.stringify({ok:false, reason:'invalid-points'});
    const readState = () => {
        const state = window.__floePenState;
        return state ? {strokes: state.strokes || 0, coreEvents: state.coreEvents || 0,
            armedDispatches: state.armedDispatches || 0,
            activeStroke: state.activeStroke === true} : null;
    };
    const before = readState();
    if (!before) return JSON.stringify({ok:false, reason:'production-gate-missing'});
    const send = (type, p, buttons) => canvas.dispatchEvent(new PointerEvent(type, {
        bubbles:true, cancelable:true, composed:true, pointerType:'pen',
        pointerId:71, isPrimary:true, clientX:p[0], clientY:p[1],
        button:0, buttons:buttons, pressure:buttons ? 0.5 : 0
    }));
    try {
        send('pointerdown', points[0], 1);
        for (let i = 1; i < points.length; i += 1) send('pointermove', points[i], 1);
        send('pointerup', points[points.length - 1], 0);
    } catch (error) {
        return JSON.stringify({ok:false, reason:'dispatch-failed',
            message:String((error && error.message) || error)});
    }
    const after = readState();
    return JSON.stringify({ok:true, before:before, after:after,
        strokeDelta:(after.strokes || 0) - (before.strokes || 0),
        coreEventDelta:(after.coreEvents || 0) - (before.coreEvents || 0),
        activeAfter:after.activeStroke === true,
        points:points});
    """#

    private func dispatchStroke(_ web: WKWebView, points: [[Double]]) async throws -> [String: Any] {
        let raw = try await web.callAsyncJavaScript(
            Self.strokeScript,
            arguments: ["strokePoints": points],
            in: nil,
            contentWorld: .page
        )
        guard let json = raw as? String, json.utf8.count <= 32_768,
              let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "The production Pencil bridge did not return a bounded JSON receipt"])
        }
        guard (decoded["ok"] as? Bool) == true else {
            throw NSError(domain: "OfficeHighlighterAlpha", code: 11, userInfo: [
                NSLocalizedDescriptionKey: "The production Pencil bridge rejected the stroke: \(decoded)"])
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

    private func snapshot(_ web: WKWebView, root: URL, name: String) async throws -> Snapshot {
        let configuration = WKSnapshotConfiguration()
        configuration.afterScreenUpdates = true
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
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        var scanX0 = 0, scanY0 = 0, scanX1 = snapshot.width, scanY1 = snapshot.height
        if let rect, rect.width > 4, rect.height > 4 {
            scanX0 = max(0, Int(rect.minX.rounded(.down)))
            scanY0 = max(0, Int(rect.minY.rounded(.down)))
            scanX1 = min(snapshot.width, Int(rect.maxX.rounded(.up)))
            scanY1 = min(snapshot.height, Int(rect.maxY.rounded(.up)))
        }
        guard scanX1 > scanX0, scanY1 > scanY0 else { return nil }
        for y in scanY0..<scanY1 {
            let row = y * snapshot.width
            for x in scanX0..<scanX1 {
                let i = (row + x) * 4
                let r = Int(snapshot.pixels[i])
                let g = Int(snapshot.pixels[i + 1])
                let b = Int(snapshot.pixels[i + 2])
                guard Self.isFixtureBlue(r, g, b) else { continue }
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        let region = Region(x: minX, y: minY,
                            width: maxX - minX + 1, height: maxY - minY + 1)
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

    private func cornerDelta(before: Snapshot, after: Snapshot, region: Region) -> Double {
        guard before.width == after.width, before.height == after.height,
              region.width > 20, region.height > 20 else { return 999 }
        let insetX = max(4, region.width / 5)
        let insetY = max(4, region.height / 5)
        let x0 = region.x, y0 = region.y
        let x1 = region.x + region.width, y1 = region.y + region.height
        let corners = [(x0 + insetX, y0 + insetY), (x1 - insetX, y0 + insetY),
                       (x0 + insetX, y1 - insetY), (x1 - insetX, y1 - insetY)]
        var worst = 0.0
        for (x, y) in corners {
            var sb = (0.0, 0.0, 0.0), sa = (0.0, 0.0, 0.0), n = 0.0
            for dy in -2...2 {
                for dx in -2...2 {
                    let px = x + dx, py = y + dy
                    guard px >= 0, py >= 0, px < before.width, py < before.height else { continue }
                    let i = (py * before.width + px) * 4
                    sb.0 += Double(before.pixels[i]); sb.1 += Double(before.pixels[i + 1]); sb.2 += Double(before.pixels[i + 2])
                    sa.0 += Double(after.pixels[i]); sa.1 += Double(after.pixels[i + 1]); sa.2 += Double(after.pixels[i + 2])
                    n += 1
                }
            }
            guard n > 0 else { continue }
            let delta = max(abs(sa.0 / n - sb.0 / n),
                            max(abs(sa.1 / n - sb.1 / n), abs(sa.2 / n - sb.2 / n)))
            worst = max(worst, delta)
        }
        return worst
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
    private func strokePoints(in region: Region, imageScale: CGFloat,
                              canvas: CGRect) -> [[Double]] {
        let x0 = CGFloat(region.x) / imageScale
        let y0 = CGFloat(region.y) / imageScale
        let w = CGFloat(region.width) / imageScale
        let h = CGFloat(region.height) / imageScale
        var points: [[Double]] = []
        for (fx, fy) in Self.strokeFractions {
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
