//
//  CADDrawingManufacturingTemplateTests.swift
//  FloeCADKitTests
//
//  E16/E18 focused native behavior: structured dimension tolerances with real
//  ISO 286 limits, datum/feature-control/surface/weld marks, an M6 thread and
//  counterbore callout bound to a live mechanical hole (update, stale, dangling,
//  undo, save/reopen, PDF/SVG/DXF symbol read-back), and a reusable sheet
//  template applied to several pages in one transaction (revision/precision
//  edits, save/reopen, export consistency, deletion-safe snapshot).
//
//  The tests decode actual vector attributes/entities, not labels alone. They
//  do not replace external-reader or physical-device acceptance; Root owns the
//  App/UI run.
//

import XCTest
import Foundation
import CoreGraphics
import simd
@testable import FloeCAD

@MainActor
final class CADDrawingManufacturingTemplateTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADDrawingMT-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    /// Retain the production exports before the fixture is removed so the
    /// integration owner can inspect them in independent PDF/DXF readers.
    private func retainExport(_ data: Data, name: String, type: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(data.isEmpty, "The actual export must not be empty.",
                       file: file, line: line)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Fixtures

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("\(name)-\(UUID().uuidString).floecad"),
            name: name)
    }

    private func mutatedDrawing(_ change: @escaping (inout [String: Any]) -> Void) throws -> Data {
        let base = try CADDrawingSet.standardSheet(for: UUID(), title: "Flat").encoded()
        var object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: base)) as? [String: Any])
        var pages = try XCTUnwrap(object["pages"] as? [[String: Any]])
        var page = pages[0]
        change(&page)
        pages[0] = page
        object["pages"] = pages
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func mutatedDrawingSchema(_ change: @escaping (inout [String: Any]) -> Void)
        throws -> Data {
        let base = try CADDrawingSet.standardSheet(for: UUID(), title: "Flat").encoded()
        var object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: base)) as? [String: Any])
        change(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    @discardableResult
    private func run(_ document: FloeCADDocument, _ object: [String: Any],
                     file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let outcome = document.execute(object)
        XCTAssertTrue(outcome.isOK,
                      "command failed (\(outcome.status)) \(outcome.errorCode ?? ""): "
                        + "\(outcome.message ?? "") — \(object)",
                      file: file, line: line)
        return (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    private func queryRows(_ document: FloeCADDocument, _ scope: String) throws -> [[String: Any]] {
        let outcome = document.nativeQueryJSON(["scope": scope])
        XCTAssertTrue(outcome.isOK, outcome.message ?? "")
        let object = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any])
        return try XCTUnwrap(object["rows"] as? [[String: Any]])
    }

    private func addSketch(_ document: FloeCADDocument, name: String,
                           entities: [[String: Any]]) throws -> (sketchID: String, entityIDs: [String]) {
        let created = try run(document, ["op": "sketch.create", "args": ["name": name]])
        let sketchID = try XCTUnwrap(created["sketchID"] as? String)
        let added = try run(document, ["op": "sketch.addEntities",
                                       "args": ["sketchID": sketchID, "entities": entities]])
        return (sketchID, added["entityIDs"] as? [String] ?? [])
    }

    private func makePlate(_ document: FloeCADDocument) throws -> (sketchID: String, bodyID: String) {
        let plate = try addSketch(document, name: "Plate",
                                  entities: [["kind": "rect", "min": [0, 0], "max": [100, 60]]])
        let extrude = try run(document, ["op": "feature.extrude",
                                         "args": ["sketchID": plate.sketchID,
                                                  "seedPoint": [50, 30], "distance": 10]])
        let bodyID = try XCTUnwrap(
            (extrude["producedBodyIDs"] as? [String])?.first
                ?? (extrude["changedBodyIDs"] as? [String])?.first)
        return (plate.sketchID, bodyID)
    }

    /// 100×60×10 plate with an M6 counterbore: Ø5 pilot (tap drill) and
    /// Ø11×6 counterbore. The pilot circle is the stable authoring feature.
    private func makeCounterboreFixture(_ document: FloeCADDocument) throws
        -> (bodyID: String, holeSketch: String, holeEntity: String, holeFeature: String) {
        let plate = try makePlate(document)
        let hole = try addSketch(document, name: "M6",
                                 entities: [["kind": "circle", "center": [50, 30], "radius": 2.5]])
        let created = try run(document, ["op": "feature.hole",
                                         "args": ["sketchID": hole.sketchID,
                                                  "seedPoint": [50, 30],
                                                  "targetBodyID": plate.bodyID,
                                                  "type": "counterbore",
                                                  "counterboreDiameter": 11,
                                                  "counterboreDepth": 6]])
        let featureID = try XCTUnwrap(created["featureID"] as? String,
                                      "hole creation must report its feature id: \(created)")
        return (plate.bodyID, hole.sketchID, hole.entityIDs[0], featureID)
    }

    private func makeMultiView(_ service: CADDrawingService, bodyID: String,
                               title: String = "Sheet") throws -> (pageID: String, frontID: String) {
        let created = service.handle(action: "multiViewSheet", args: [
            "bodyID": bodyID, "title": title,
            "sectionOrigin": [50.0, 5.0, 30.0], "sectionNormal": [0.0, 1.0, 0.0],
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let page = try XCTUnwrap(created["page"] as? [String: Any])
        let pageID = try XCTUnwrap(page["id"] as? String)
        let front = try XCTUnwrap((page["views"] as? [[String: Any]])?
            .first { ($0["kind"] as? String) == "front" })
        return (pageID, try XCTUnwrap(front["id"] as? String))
    }

    private func candidate(radius: Double, pageID: String, viewID: String,
                           service: CADDrawingService) throws -> [String: Any] {
        let reply = service.handle(action: "dimensionCandidates",
                                   args: ["pageID": pageID, "viewID": viewID])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        let rows = try XCTUnwrap(reply["candidates"] as? [[String: Any]])
        return try XCTUnwrap(rows.first {
            abs(($0["radiusMM"] as? Double ?? -1) - radius) <= 1e-4
        }, "candidate Ø\(radius * 2) missing: \(rows)")
    }

    private func manufacturingRow(_ geometry: [String: Any], id: String) -> [String: Any]? {
        (geometry["manufacturingAnnotations"] as? [[String: Any]])?
            .first { ($0["id"] as? String) == id }
    }

    private func dimensionRow(_ geometry: [String: Any], id: String) -> [String: Any]? {
        (geometry["manualDimensions"] as? [[String: Any]])?
            .first { ($0["id"] as? String) == id }
    }

    private func displayLines(_ row: [String: Any]) -> [String] {
        let display = row["display"] as? [String: Any] ?? [:]
        return display["textLines"] as? [String] ?? []
    }

    // MARK: - Pure rules

    func testISO286FitComputesPublishedLimitsAndStructuredDisplay() throws {
        let fit = CADDrawingISO286Fit(holeGrade: 7, shaftLetter: "h", shaftGrade: 6)
        let limits = try XCTUnwrap(CADDrawingManufacturingRules.iso286Limits(
            fit: fit, nominalMM: 40))
        XCTAssertEqual(limits.holeLower, 40, accuracy: 1e-9)
        XCTAssertEqual(limits.holeUpper, 40.025, accuracy: 1e-9, "Ø40 H7 upper limit")
        XCTAssertEqual(limits.shaftUpper, 40, accuracy: 1e-9, "Ø40 h6 upper limit")
        XCTAssertEqual(limits.shaftLower, 39.984, accuracy: 1e-9, "Ø40 h6 lower limit")
        XCTAssertEqual(limits.minClearance, 0, accuracy: 1e-9)
        XCTAssertEqual(limits.maxClearance, 0.041, accuracy: 1e-9)

        let tolerance = CADDrawingTolerance(kind: .fit, fit: fit)
        let display = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            tolerance, nominalMM: 40, kind: .diameter,
            unit: .millimetre, precision: 3))
        XCTAssertEqual(display.primarySuffix, "H7/h6")
        XCTAssertEqual(display.upperLimitMM ?? -1, 40.025, accuracy: 1e-9)
        XCTAssertEqual(display.lowerLimitMM ?? -1, 40, accuracy: 1e-9)
        XCTAssertEqual(display.maxClearanceMM ?? -1, 0.041, accuracy: 1e-9)
        XCTAssertTrue(display.lines.contains { $0.contains("40.025") })
        XCTAssertTrue(display.lines.contains { $0.contains("39.984") })
        XCTAssertTrue(display.consistentWithNominal)

        let symmetric = CADDrawingTolerance(kind: .symmetric, deviationMM: 0.05)
        let symmetricDisplay = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            symmetric, nominalMM: 10, kind: .length,
            unit: .millimetre, precision: 2))
        XCTAssertEqual(symmetricDisplay.primarySuffix, "±0.05")

        // Unit conversion is display-only: 0.254 mm is exactly 0.01 in.
        let inch = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            CADDrawingTolerance(kind: .symmetric, deviationMM: 0.254),
            nominalMM: 25.4, kind: .length, unit: .inch, precision: 2))
        XCTAssertEqual(inch.primarySuffix, "±0.01")

        // A fit on an angle is refused, never rendered as if valid.
        XCTAssertFalse(CADDrawingManufacturingRules.validateTolerance(
            tolerance, kind: .angle, nominal: 45).isEmpty)
    }

    func testISO286FitScopeAllowsOnlyDiameterAndLength() throws {
        let fit = CADDrawingISO286Fit(holeGrade: 7, shaftLetter: "h", shaftGrade: 6)
        let tolerance = CADDrawingTolerance(kind: .fit, fit: fit)
        XCTAssertTrue(CADDrawingManufacturingRules.validateTolerance(
            tolerance, kind: .diameter, nominal: 40).isEmpty)
        XCTAssertTrue(CADDrawingManufacturingRules.validateTolerance(
            tolerance, kind: .length, nominal: 40).isEmpty)

        let radiusIssues = CADDrawingManufacturingRules.validateTolerance(
            tolerance, kind: .radius, nominal: 20)
        XCTAssertFalse(radiusIssues.isEmpty)
        XCTAssertTrue(radiusIssues.joined().localizedCaseInsensitiveContains("radius"),
                      "the radius refusal must name the actual scope: \(radiusIssues)")
        let angleIssues = CADDrawingManufacturingRules.validateTolerance(
            tolerance, kind: .angle, nominal: 45)
        XCTAssertFalse(angleIssues.isEmpty)
        XCTAssertTrue(angleIssues.joined().localizedCaseInsensitiveContains("angle"))

        // Importantly, a radius is not silently doubled through the diameter
        // bands: the formatter refuses it as well.
        XCTAssertNil(CADDrawingManufacturingRules.formatTolerance(
            tolerance, nominalMM: 20, kind: .radius, unit: .millimetre, precision: 2))
        XCTAssertNil(CADDrawingManufacturingRules.formatTolerance(
            tolerance, nominalMM: 45, kind: .angle, unit: .millimetre, precision: 2))
    }

    func testAbsoluteLimitsAllowOneSidedBandsWithSignedDeviations() throws {
        // Both limits above the basic nominal are a valid absolute interval.
        let above = CADDrawingTolerance(kind: .limits,
                                        upperLimitMM: 40.2, lowerLimitMM: 40.1)
        XCTAssertTrue(CADDrawingManufacturingRules.validateTolerance(
            above, kind: .diameter, nominal: 40).isEmpty)
        let aboveDisplay = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            above, nominalMM: 40, kind: .diameter, unit: .millimetre, precision: 2))
        XCTAssertTrue(aboveDisplay.consistentWithNominal,
                      "a valid one-sided absolute band is not an inconsistency")
        XCTAssertEqual(try XCTUnwrap(aboveDisplay.upperDeviationMM), 0.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(aboveDisplay.lowerDeviationMM), 0.1, accuracy: 1e-9)
        XCTAssertEqual(aboveDisplay.lines, ["40.20", "40.10"])

        // Both limits below the basic nominal are equally valid.
        let below = CADDrawingTolerance(kind: .limits,
                                        upperLimitMM: 39.9, lowerLimitMM: 39.8)
        XCTAssertTrue(CADDrawingManufacturingRules.validateTolerance(
            below, kind: .diameter, nominal: 40).isEmpty)
        let belowDisplay = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            below, nominalMM: 40, kind: .diameter, unit: .millimetre, precision: 2))
        XCTAssertTrue(belowDisplay.consistentWithNominal)
        XCTAssertEqual(try XCTUnwrap(belowDisplay.upperDeviationMM), -0.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(belowDisplay.lowerDeviationMM), -0.2, accuracy: 1e-9)
        XCTAssertEqual(belowDisplay.lines, ["39.90", "39.80"])

        // The existing exact, centred limits keep their usual signed offsets.
        let centred = CADDrawingTolerance(kind: .limits,
                                          upperLimitMM: 40.05, lowerLimitMM: 39.95)
        let centredDisplay = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            centred, nominalMM: 40, kind: .diameter, unit: .millimetre, precision: 2))
        XCTAssertEqual(try XCTUnwrap(centredDisplay.upperDeviationMM), 0.05, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(centredDisplay.lowerDeviationMM), -0.05, accuracy: 1e-9)
        XCTAssertEqual(centredDisplay.lines, ["40.05", "39.95"])

        // Malformed absolute limits still fail closed: non-finite, reversed,
        // negative, missing and out-of-range values are all rejected.
        for malformed in [
            CADDrawingTolerance(kind: .limits, upperLimitMM: .nan, lowerLimitMM: 39.9),
            CADDrawingTolerance(kind: .limits, upperLimitMM: 39.9, lowerLimitMM: 39.95),
            CADDrawingTolerance(kind: .limits, upperLimitMM: 40.1, lowerLimitMM: -0.1),
            CADDrawingTolerance(kind: .limits, upperLimitMM: nil, lowerLimitMM: 39.9),
            CADDrawingTolerance(kind: .limits, upperLimitMM: 1_000_001, lowerLimitMM: 40),
        ] {
            XCTAssertFalse(CADDrawingManufacturingRules.validateTolerance(
                malformed, kind: .diameter, nominal: 40).isEmpty,
                           "\(malformed) must be rejected")
            XCTAssertNil(CADDrawingManufacturingRules.formatTolerance(
                malformed, nominalMM: 40, kind: .diameter,
                unit: .millimetre, precision: 2))
        }
    }

    func testToleranceTextKeepsNeededDecimalsAndExactMetadata() throws {
        let fit = CADDrawingISO286Fit(holeGrade: 7, shaftLetter: "h", shaftGrade: 6)
        let fitDisplay = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            CADDrawingTolerance(kind: .fit, fit: fit), nominalMM: 40,
            kind: .diameter, unit: .millimetre, precision: 2))
        XCTAssertEqual(fitDisplay.primarySuffix, "H7/h6")
        XCTAssertTrue(fitDisplay.lines.contains { $0.contains("40.025") })
        XCTAssertTrue(fitDisplay.lines.contains { $0.contains("39.984") })
        XCTAssertFalse(fitDisplay.lines.joined().contains("40.03"),
                       "page precision must not round away the published limits: \(fitDisplay.lines)")
        // Exact millimetre metadata survives any display precision/unit.
        XCTAssertEqual(try XCTUnwrap(fitDisplay.upperLimitMM), 40.025, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fitDisplay.lowerLimitMM), 40, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fitDisplay.maxClearanceMM), 0.041, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(fitDisplay.minClearanceMM), 0, accuracy: 1e-9)

        // A tiny nonzero symmetric deviation must never format as zero.
        let tiny = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            CADDrawingTolerance(kind: .symmetric, deviationMM: 0.001),
            nominalMM: 40, kind: .diameter, unit: .millimetre, precision: 2))
        XCTAssertEqual(tiny.primarySuffix, "±0.001")

        // Unequal signed deviations keep their own minimal decimal count.
        let deviation = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            CADDrawingTolerance(kind: .deviation,
                                upperDeviationMM: 0.001, lowerDeviationMM: -0.0005),
            nominalMM: 40, kind: .diameter, unit: .millimetre, precision: 2))
        XCTAssertEqual(deviation.lines, ["+0.001", "-0.0005"])
        XCTAssertEqual(try XCTUnwrap(deviation.upperDeviationMM), 0.001, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(deviation.lowerDeviationMM), -0.0005, accuracy: 1e-12)

        // Unequal absolute limits keep exact places too.
        let limits = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            CADDrawingTolerance(kind: .limits,
                                upperLimitMM: 40.025, lowerLimitMM: 39.984),
            nominalMM: 40, kind: .diameter, unit: .millimetre, precision: 2))
        XCTAssertEqual(limits.lines, ["40.025", "39.984"])

        // Inch display converts but still keeps enough places for 0.001 in.
        let inch = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            CADDrawingTolerance(kind: .symmetric, deviationMM: 0.0254),
            nominalMM: 25.4, kind: .length, unit: .inch, precision: 2))
        XCTAssertEqual(inch.primarySuffix, "±0.001")

        // Unit conversion still applies to limits/deviation (the edge fallback
        // must not bypass it), while the exact millimetre metadata stays.
        let inchLimits = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            CADDrawingTolerance(kind: .limits,
                                upperLimitMM: 25.654, lowerLimitMM: 25.4),
            nominalMM: 25.4, kind: .length, unit: .inch, precision: 2))
        XCTAssertEqual(inchLimits.lines, ["1.01", "1.00"])
        XCTAssertEqual(try XCTUnwrap(inchLimits.upperLimitMM), 25.654, accuracy: 1e-9)
        let inchDeviation = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            CADDrawingTolerance(kind: .deviation,
                                upperDeviationMM: 0.254, lowerDeviationMM: -0.254),
            nominalMM: 25.4, kind: .length, unit: .inch, precision: 2))
        XCTAssertEqual(inchDeviation.lines, ["+0.01", "-0.01"])

        // A zero deviation prints as zero, never "+-".
        let zero = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            CADDrawingTolerance(kind: .deviation,
                                upperDeviationMM: 0, lowerDeviationMM: -0.05),
            nominalMM: 10, kind: .length, unit: .millimetre, precision: 2))
        XCTAssertEqual(zero.lines, ["+0.00", "-0.05"])
        XCTAssertFalse(zero.lines.contains { $0.contains("+-") })

        // The same meaningful-decimal rule is shared by the manufacturing
        // display consumers (GD&T zone and surface roughness).
        XCTAssertEqual(CADDrawingManufacturingRules.formatMeaningful(0.001, minimum: 2),
                       "0.001")
        XCTAssertEqual(CADDrawingManufacturingRules.formatMeaningful(0.025, minimum: 2),
                       "0.025")
        XCTAssertEqual(CADDrawingManufacturingRules.formatMeaningful(0.2, minimum: 2),
                       "0.20")
        XCTAssertEqual(CADDrawingManufacturingRules.formatMeaningful(1.6, minimum: 2),
                       "1.60")
        XCTAssertEqual(CADDrawingManufacturingRules.formatMeaningful(1.6, minimum: 0), "1.6")

        // The actual manufacturing display consumers compose the same rule.
        XCTAssertEqual(CADDrawingManufacturingRules.featureControlToleranceText(
            0.001, diameterZone: true, pagePrecision: 2), "Ø0.001")
        XCTAssertEqual(CADDrawingManufacturingRules.featureControlToleranceText(
            0.001, diameterZone: false, pagePrecision: 2), "0.001")
        XCTAssertEqual(CADDrawingManufacturingRules.featureControlToleranceText(
            0.2, diameterZone: true, pagePrecision: 2), "Ø0.20")
        XCTAssertEqual(CADDrawingManufacturingRules.surfaceFinishRaText(
            0.025, pagePrecision: 2), "Ra 0.025")
        XCTAssertEqual(CADDrawingManufacturingRules.surfaceFinishRaText(
            1.6, pagePrecision: 2), "Ra 1.60")
        XCTAssertEqual(CADDrawingManufacturingRules.surfaceFinishRaText(
            1.6, pagePrecision: nil), "Ra 1.6")

        // Underflow must not erase a nonzero value; distinct interval endpoints
        // must not collapse to the same six-place text.
        XCTAssertEqual(CADDrawingManufacturingRules.formatMeaningful(
            1e-7, minimum: 2), "1e-07")
        let tinySymmetric = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            CADDrawingTolerance(kind: .symmetric, deviationMM: 1e-7),
            nominalMM: 1, kind: .length, unit: .millimetre, precision: 2))
        XCTAssertEqual(tinySymmetric.primarySuffix, "±1e-07")
        let tinyDeviation = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            CADDrawingTolerance(kind: .deviation,
                                upperDeviationMM: 1e-7, lowerDeviationMM: -1e-7),
            nominalMM: 1, kind: .length, unit: .millimetre, precision: 2))
        XCTAssertEqual(tinyDeviation.lines, ["+1e-07", "-1e-07"])
        let closeLimits = try XCTUnwrap(CADDrawingManufacturingRules.formatTolerance(
            CADDrawingTolerance(kind: .limits,
                                upperLimitMM: 1.00000002, lowerLimitMM: 1.00000001),
            nominalMM: 1, kind: .length, unit: .millimetre, precision: 2))
        XCTAssertEqual(closeLimits.lines, ["1.00000002", "1.00000001"],
                       "distinct absolute limits must never print as the same value")
        XCTAssertEqual(CADDrawingManufacturingRules.featureControlToleranceText(
            1e-7, diameterZone: true, pagePrecision: 2), "Ø1e-07")
        XCTAssertEqual(CADDrawingManufacturingRules.surfaceFinishRaText(
            1e-7, pagePrecision: 2), "Ra 1e-07")
    }

    func testTemplateNumberDraftsNeverSubstituteZero() throws {
        XCTAssertEqual(CADDrawingTemplateRules.parseNumberDraft("8"), 8)
        XCTAssertEqual(CADDrawingTemplateRules.parseNumberDraft(" 0.25 "), 0.25)
        XCTAssertEqual(CADDrawingTemplateRules.parseNumberDraft("8."), 8)
        for raw in ["", "   ", "abc", "0.25mm", "nan", "inf", "-inf"] {
            XCTAssertNil(CADDrawingTemplateRules.parseNumberDraft(raw),
                         "\(raw.debugDescription) must be an explicit error, not 0")
        }

        var template = CADDrawingSheetTemplate(name: "Draft bounds")
        template.style.marginMM = CADDrawingTemplateRules.parseNumberDraft("2") ?? 8
        XCTAssertFalse(CADDrawingTemplateRules.validate(template).isEmpty,
                       "a parsed out-of-range draft is still rejected by the template rules")
        template.style.marginMM = 8
        template.style.lineWidthMM = 0
        XCTAssertFalse(CADDrawingTemplateRules.validate(template).isEmpty)
    }

    func testTemplateAndManufacturingRoundTripKeepsStructuredFields() throws {
        let bodyID = UUID()
        var set = CADDrawingSet.multiViewSheet(
            bodyIDs: [bodyID], title: "Round trip",
            sectionOrigin: SIMD3(50, 5, 30), sectionNormal: SIMD3(0, 1, 0))
        let pageID = set.pages[0].id
        let viewID = set.pages[0].effectiveSheetViews[0].id
        let anchor = CADDrawingFeatureAnchor(centroid: SIMD3(50, 30, 5),
                                             direction: SIMD3(0, 1, 0), radiusMM: 2.5)
        let feature = CADDrawingFeatureReference(bodyID: bodyID, anchor: anchor,
                                                 featureID: UUID(), sketchID: UUID(),
                                                 sketchEntityID: UUID())
        let annotation = CADDrawingManufacturingAnnotation(
            kind: .threadCallout, viewID: viewID, position: SIMD2(20, 20),
            heightMM: 3, feature: feature,
            thread: CADDrawingThreadCallout(designation: "M6", pitchMM: 1.0,
                                            threadClass: "6H", through: true))
        set.pages[0].manufacturingAnnotations = [annotation]
        set.pages[0].manualDimensions = [CADDrawingManualDimension(
            kind: .diameter, drawingPoints: [SIMD2(0, 0), SIMD2(5, 0)],
            value: 10, textPosition: SIMD2(6, 6), viewID: viewID,
            feature: feature,
            tolerance: CADDrawingTolerance(kind: .fit, fit: CADDrawingISO286Fit()))]
        var template = CADDrawingSheetTemplate(name: "Round trip sheet",
                                               paper: .a3, projection: .firstAngle,
                                               units: .millimetre, precision: 2,
                                               revisionRows: [CADDrawingRevisionRow(
                                                revision: "A", date: "2026-11-01",
                                                description: "Initial release")])
        template.style.lineWidthMM = 0.35
        set.templates = [template]
        try CADDrawingTemplateRules.apply(template, to: &set.pages[0])

        let decoded = try CADDrawingSet.decode(from: set.encoded())
        XCTAssertEqual(decoded.schemaVersion, CADDrawingSet.currentSchemaVersion)
        XCTAssertEqual(decoded.pages[0].id, pageID)
        XCTAssertEqual(decoded.pages[0].effectiveSheetViews[0].id, viewID)
        XCTAssertEqual(decoded.pages[0].manufacturingAnnotations.count, 1)
        XCTAssertEqual(decoded.pages[0].manufacturingAnnotations[0].thread?.designation, "M6")
        XCTAssertEqual(decoded.pages[0].manualDimensions[0].tolerance?.kind, .fit)
        XCTAssertEqual(decoded.pages[0].sheetTemplate?.snapshot.projection, .firstAngle)
        XCTAssertEqual(decoded.pages[0].revisionRows.count, 1)
        XCTAssertEqual(decoded.templates.count, 1)
        XCTAssertEqual(decoded.templates[0].style.lineWidthMM, 0.35)
    }

    func testDrawingFloorRaisesOnlyForRealNewRecordsAndFailsClosedOnUnknown() throws {
        XCTAssertEqual(CADDocumentFormat.supportedVersion, 7)
        XCTAssertEqual(CADDocumentFormat.namedVersionFormatVersion, 6)
        XCTAssertEqual(CADDocumentFormat.drawingManufacturingVersion, 7)

        let flat = CADDrawingSet.standardSheet(for: UUID(), title: "Flat")
        XCTAssertEqual(try CADDocumentFormat.drawingRequiredVersion(flat.encoded()),
                       CADDocumentFormat.legacyVersion)
        var stamped = flat
        stamped.schemaVersion = CADDrawingSet.currentSchemaVersion
        XCTAssertEqual(try CADDocumentFormat.drawingRequiredVersion(stamped.encoded()),
                       CADDocumentFormat.legacyVersion,
                       "the stamped drawing schema alone is not new data")

        let shared = CADDrawingSet.multiViewSheet(
            bodyIDs: [UUID()], title: "Shared",
            sectionOrigin: .zero, sectionNormal: SIMD3(0, 1, 0))
        XCTAssertEqual(try CADDocumentFormat.drawingRequiredVersion(shared.encoded()),
                       CADDocumentFormat.drawingSheetViewVersion)

        var manufactured = shared
        manufactured.pages[0].manufacturingAnnotations = [
            CADDrawingManufacturingAnnotation(
                kind: .datumFeature, position: SIMD2(10, 10),
                datum: CADDrawingDatumFeature(letter: "A"))
        ]
        XCTAssertEqual(try CADDocumentFormat.drawingRequiredVersion(manufactured.encoded()), 7)

        var templated = shared
        templated.templates = [CADDrawingSheetTemplate(name: "Company")]
        try CADDrawingTemplateRules.apply(templated.templates[0], to: &templated.pages[0])
        XCTAssertEqual(try CADDocumentFormat.drawingRequiredVersion(templated.encoded()), 7)

        // Malformed bytes and an unknown future manufacturing record are
        // opaque read-only, never a downgrade/overwrite.
        let malformed = Data("not a drawing set".utf8)
        XCTAssertEqual(CADDocumentFormat.drawingRequiredVersion(malformed), 7)
        let malformedAssessment = try CADDocumentFormat.assess(
            planes: [], sketches: [], features: [], drawings: malformed)
        XCTAssertTrue(malformedAssessment.opaqueDrawings)

        let unknown = Data("""
        {"schemaVersion":5,"pages":[{"id":"33333333-3333-3333-3333-333333333333",
         "name":"S","kind":"front","manufacturingAnnotations":[
         {"id":"44444444-4444-4444-4444-444444444444","kind":"futureCallout",
          "position":[0,0],"heightMM":3}]}]}
        """.utf8)
        XCTAssertEqual(CADDocumentFormat.drawingRequiredVersion(unknown), 7)
        let unknownAssessment = try CADDocumentFormat.assess(
            planes: [], sketches: [], features: [], drawings: unknown)
        XCTAssertTrue(unknownAssessment.opaqueDrawings)

        // Page-level v5 presentation records are non-additive too: a malformed
        // type, an unknown key, an unknown enum or an out-of-range value must
        // raise the floor and open read-only instead of decoding to blanks.
        let malformedRows = try mutatedDrawing { $0["revisionRows"] = "future" }
        XCTAssertEqual(CADDocumentFormat.drawingRequiredVersion(malformedRows), 7)
        let malformedRowsAssessment = try CADDocumentFormat.assess(
            planes: [], sketches: [], features: [], drawings: malformedRows)
        XCTAssertTrue(malformedRowsAssessment.opaqueDrawings)
        let unknownRowKey = try mutatedDrawing {
            $0["revisionRows"] = [["revision": "B", "description": "Update", "future": 1]]
        }
        XCTAssertEqual(CADDocumentFormat.drawingRequiredVersion(unknownRowKey), 7)
        let unknownRowKeyAssessment = try CADDocumentFormat.assess(
            planes: [], sketches: [], features: [], drawings: unknownRowKey)
        XCTAssertTrue(unknownRowKeyAssessment.opaqueDrawings)
        let unknownUnit = try mutatedDrawing { $0["units"] = "furlong" }
        XCTAssertEqual(CADDocumentFormat.drawingRequiredVersion(unknownUnit), 7)
        let unknownUnitAssessment = try CADDocumentFormat.assess(
            planes: [], sketches: [], features: [], drawings: unknownUnit)
        XCTAssertTrue(unknownUnitAssessment.opaqueDrawings)
        let badPrecision = try mutatedDrawing { $0["precision"] = 9 }
        XCTAssertEqual(CADDocumentFormat.drawingRequiredVersion(badPrecision), 7)
        let badPrecisionAssessment = try CADDocumentFormat.assess(
            planes: [], sketches: [], features: [], drawings: badPrecision)
        XCTAssertTrue(badPrecisionAssessment.opaqueDrawings)
        let booleanPrecision = try mutatedDrawing { $0["precision"] = true }
        XCTAssertEqual(CADDocumentFormat.drawingRequiredVersion(booleanPrecision), 7)
        let booleanPrecisionAssessment = try CADDocumentFormat.assess(
            planes: [], sketches: [], features: [], drawings: booleanPrecision)
        XCTAssertTrue(booleanPrecisionAssessment.opaqueDrawings)
        let unknownTitleKey = try mutatedDrawing {
            $0["titleBlock"] = ["company": "Floe", "drawingNumber": "D-1", "future": 1]
        }
        XCTAssertEqual(CADDocumentFormat.drawingRequiredVersion(unknownTitleKey), 7)
        let unknownTitleKeyAssessment = try CADDocumentFormat.assess(
            planes: [], sketches: [], features: [], drawings: unknownTitleKey)
        XCTAssertTrue(unknownTitleKeyAssessment.opaqueDrawings)
        let booleanSchema = try mutatedDrawingSchema { $0["schemaVersion"] = true }
        XCTAssertEqual(CADDocumentFormat.drawingRequiredVersion(booleanSchema), 7)
        let booleanSchemaAssessment = try CADDocumentFormat.assess(
            planes: [], sketches: [], features: [], drawings: booleanSchema)
        XCTAssertTrue(booleanSchemaAssessment.opaqueDrawings)
        let negativeSchema = try mutatedDrawingSchema { $0["schemaVersion"] = -1 }
        XCTAssertEqual(CADDocumentFormat.drawingRequiredVersion(negativeSchema), 7)
        let negativeSchemaAssessment = try CADDocumentFormat.assess(
            planes: [], sketches: [], features: [], drawings: negativeSchema)
        XCTAssertTrue(negativeSchemaAssessment.opaqueDrawings)
    }

    // MARK: - E16: M6 thread + tolerance + datum frame, live association and vector symbols

    func testManufacturingAnnotationsBindToLiveHoleAndExportRealSymbols() async throws {
        let document = try await makeDocument("E16")
        let fixture = try makeCounterboreFixture(document)
        let service = CADDrawingService(document: document)
        let sheet = try makeMultiView(service, bodyID: fixture.bodyID, title: "E16 sheet")
        let pilot = try candidate(radius: 2.5, pageID: sheet.pageID, viewID: sheet.frontID,
                                  service: service)
        let reference = try XCTUnwrap(pilot["reference"] as? [String: Any])
        XCTAssertEqual(reference["featureID"] as? String, fixture.holeFeature)
        XCTAssertEqual(reference["sketchEntityID"] as? String, fixture.holeEntity)

        // One undoable add; projecting is derived cache only.
        let undoBefore = document.session.undoStack.undoCommands.count
        let datumAdd = service.handle(action: "addManufacturingAnnotation", args: [
            "pageID": sheet.pageID, "viewID": sheet.frontID, "kind": "datumFeature",
            "position": [10.0, 10.0], "heightMM": 3.0,
            "feature": reference, "datum": ["letter": "A"],
        ])
        XCTAssertEqual(datumAdd["ok"] as? Bool, true, "\(datumAdd)")
        let datumRow = try XCTUnwrap(datumAdd["manufacturingAnnotation"] as? [String: Any])
        let datumID = try XCTUnwrap(datumRow["id"] as? String)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore + 1)
        _ = service.handle(action: "project", args: ["pageID": sheet.pageID])
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore + 1,
                       "derived projection must not add undo")
        document.session.undo()
        var geometry = service.handle(action: "project", args: ["pageID": sheet.pageID])
        XCTAssertTrue((geometry["manufacturingAnnotations"] as? [[String: Any]] ?? [])
            .allSatisfy { ($0["kind"] as? String) != "datumFeature" })
        document.session.redo()
        geometry = service.handle(action: "project", args: ["pageID": sheet.pageID])
        _ = try XCTUnwrap(manufacturingRow(geometry, id: datumID))

        // Explicit, separated fixture positions: five marks at one point overlap
        // visually even though every semantic value is correct. These are the
        // author-supplied view-local positions a user would choose; production
        // never lays user annotations out automatically.
        func add(_ kind: String, position: [Double],
                 _ payload: [String: Any]) throws -> String {
            var args: [String: Any] = [
                "pageID": sheet.pageID, "viewID": sheet.frontID,
                "kind": kind, "position": position, "heightMM": 3.0,
                "feature": reference,
            ]
            for (key, value) in payload { args[key] = value }
            let reply = service.handle(action: "addManufacturingAnnotation", args: args)
            XCTAssertEqual(reply["ok"] as? Bool, true, "\(kind): \(reply)")
            let row = try XCTUnwrap(reply["manufacturingAnnotation"] as? [String: Any])
            return try XCTUnwrap(row["id"] as? String)
        }

        let counterboreID = try add("counterboreCallout", position: [0, 80],
                                    ["counterbore": [String: Any]()])
        let threadID = try add("threadCallout", position: [0, -20], ["thread": [
            "designation": "M6", "pitchMM": 1.0, "threadClass": "6H", "through": true,
        ]])
        let fcfID = try add("featureControlFrame", position: [55, 80], [
            "featureControlFrame": [
                "characteristic": "position", "toleranceMM": 0.2,
                "diameterZone": true,
                "datumReferences": [["letter": "A"], ["letter": "B"]],
            ],
        ])
        _ = try add("surfaceFinish", position: [55, -20], ["surfaceFinish": [
            "raMicrometres": 1.6, "machiningMethod": "Ground", "allAround": true,
        ]])
        _ = try add("weld", position: [110, 30], ["weld": [
            "type": "fillet", "sizeMM": 6, "lengthMM": 20, "pitchMM": 40,
            "allAround": true, "tailNote": "WPS-01",
        ]])
        let dimensionAdd = service.handle(action: "addDimension", args: [
            "pageID": sheet.pageID, "viewID": sheet.frontID, "kind": "diameter",
            "feature": reference,
            "tolerance": ["kind": "fit",
                          "fit": ["holeGrade": 7, "shaftLetter": "h", "shaftGrade": 6]],
        ])
        XCTAssertEqual(dimensionAdd["ok"] as? Bool, true, "\(dimensionAdd)")
        let dimension = try XCTUnwrap(dimensionAdd["dimension"] as? [String: Any])
        let dimensionID = try XCTUnwrap(dimension["id"] as? String)
        XCTAssertEqual(dimension["value"] as? Double ?? 0, 5, accuracy: 1e-6)
        XCTAssertEqual(dimension["text"] as? String, "Ø5 H7/h6")

        geometry = service.handle(action: "project", args: ["pageID": sheet.pageID])
        XCTAssertEqual(geometry["ok"] as? Bool, true, "\(geometry)")
        // The user-authored marks must occupy distinct view positions so each
        // mark can be read independently in the exported sheet (the datum is
        // the sixth). This guards the fixture, not an automatic layout rule.
        let markPositions = (geometry["manufacturingAnnotations"] as? [[String: Any]] ?? [])
            .compactMap { $0["localPosition"] as? [Double] }
        XCTAssertEqual(markPositions.count, 6)
        let uniqueMarks = Set(markPositions.map { pair in
            pair.map { String(format: "%.6f", $0) }.joined(separator: ",")
        })
        XCTAssertEqual(uniqueMarks.count, markPositions.count,
                       "the demonstration marks must not share one position")
        let counterbore = try XCTUnwrap(manufacturingRow(geometry, id: counterboreID))
        XCTAssertEqual(counterbore["status"] as? String, "resolved")
        XCTAssertTrue(displayLines(counterbore).contains { $0.contains("CBORE Ø11") })
        XCTAssertTrue(displayLines(counterbore).contains { $0.contains("DEPTH 6") })
        XCTAssertTrue(displayLines(counterbore).contains("THRU"))
        let counterboreComputed = try XCTUnwrap(counterbore["computed"] as? [String: Any])
        XCTAssertEqual(counterboreComputed["counterboreDiameterMM"] as? Double ?? 0, 11,
                       accuracy: 1e-6)

        let thread = try XCTUnwrap(manufacturingRow(geometry, id: threadID))
        XCTAssertEqual(thread["status"] as? String, "resolved")
        XCTAssertTrue(displayLines(thread).contains("M6×1.0-6H"))
        XCTAssertTrue(displayLines(thread).contains("THRU"))
        let threadDisplay = try XCTUnwrap(thread["display"] as? [String: Any])
        XCTAssertEqual(threadDisplay["geometricThread"] as? Bool, false,
                       "a drafting callout is not geometric helix evidence")
        XCTAssertEqual(threadDisplay["verification"] as? String, "linkedHoleTapDrill")
        let threadComputed = try XCTUnwrap(thread["computed"] as? [String: Any])
        XCTAssertEqual(threadComputed["pilotDiameterMM"] as? Double ?? 0, 5, accuracy: 1e-6)

        let fcf = try XCTUnwrap(manufacturingRow(geometry, id: fcfID))
        XCTAssertEqual(fcf["status"] as? String, "resolved")
        let fcfDisplay = try XCTUnwrap(fcf["display"] as? [String: Any])
        XCTAssertEqual(fcfDisplay["characteristic"] as? String, "position")
        XCTAssertEqual(fcfDisplay["toleranceText"] as? String, "Ø0.20")
        XCTAssertEqual((fcfDisplay["datumReferences"] as? [[String: Any]])?.count, 2)

        let dimensionRow = try XCTUnwrap(
            (geometry["manualDimensions"] as? [[String: Any]])?
                .first { ($0["id"] as? String) == dimensionID })
        let toleranceDisplay = try XCTUnwrap(dimensionRow["toleranceDisplay"] as? [String: Any])
        XCTAssertEqual(toleranceDisplay["designation"] as? String, "H7/h6")
        XCTAssertEqual(toleranceDisplay["upperLimitMM"] as? Double ?? 0, 5.012, accuracy: 1e-9)
        XCTAssertEqual(toleranceDisplay["lowerLimitMM"] as? Double ?? 0, 5.000, accuracy: 1e-9)
        XCTAssertEqual((toleranceDisplay["lines"] as? [String])?.count, 2)

        // Real vector output: the symbols are line/circle/path entities on the
        // ANNOTATIONS layer and the measured text is on DIMENSIONS. SVG needs
        // a separate fill-enabled group for glyphs, so the writer emits each
        // layer's text in its real `<layer>_TEXT` sibling (the DXF writer uses
        // one named layer for both). Assert both actual groups; the layer is
        // the pair, not a substring of the whole document.
        let svg = try service.exportData(pageID: UUID(uuidString: sheet.pageID)!,
                                         format: "svg")
        retainExport(svg, name: "e16-manufacturing.svg", type: "public.svg-image")
        let svgText = try XCTUnwrap(String(data: svg, encoding: .utf8))
        let annotationGroup = try XCTUnwrap(svgGroup(svgText, id: "ANNOTATIONS"))
        XCTAssertTrue(annotationGroup.contains("<line"))
        XCTAssertTrue(annotationGroup.contains("<circle"))
        XCTAssertTrue(annotationGroup.contains("<path"))
        let annotationText = try XCTUnwrap(svgGroup(svgText, id: "ANNOTATIONS_TEXT"))
        XCTAssertTrue(annotationText.contains("M6×1.0-6H"))
        XCTAssertTrue(annotationText.contains("CBORE Ø11"))
        XCTAssertTrue(annotationText.contains("Ra 1.6"))
        XCTAssertTrue(annotationText.contains("6 L20 P40"))
        let svgDimensions = try XCTUnwrap(svgGroup(svgText, id: "DIMENSIONS"))
        XCTAssertTrue(svgDimensions.contains("<line"))
        let svgDimensionText = try XCTUnwrap(svgGroup(svgText, id: "DIMENSIONS_TEXT"))
        XCTAssertTrue(svgDimensionText.contains("H7/h6"))
        XCTAssertTrue(svgDimensionText.contains("5.012"))

        let dxf = try service.exportData(pageID: UUID(uuidString: sheet.pageID)!,
                                         format: "dxf")
        retainExport(dxf, name: "e16-manufacturing.dxf", type: "public.data")
        // AC1009 is an ASCII file: $DWGCODEPAGE (ANSI_1252 here) plus the
        // `\U+nnnn` schema for characters outside the codepage, never raw
        // UTF-8. Assert the exact wire escape AND the real text a reader
        // obtains from one decode pass; the symbol expectations stay.
        XCTAssertTrue(dxf.allSatisfy { $0 < 0x80 },
                      "an R12/AC1009 DXF must be pure ASCII on the wire")
        let dxfText = try XCTUnwrap(String(data: dxf, encoding: .ascii))
        XCTAssertTrue(dxfText.contains("9\n$DWGCODEPAGE\n3\nANSI_1252"))
        XCTAssertTrue(dxfText.contains("ANNOTATIONS"))
        XCTAssertTrue(dxfText.contains("0\nTEXT\n"))
        XCTAssertTrue(dxfText.contains(#"M6\U+00D71.0-6H"#))
        XCTAssertTrue(dxfText.contains(#"CBORE \U+00D811"#))
        let dxfDecoded = DXFTextCodec.decode(dxfText)
        XCTAssertTrue(dxfDecoded.contains("M6×1.0-6H"))
        XCTAssertTrue(dxfDecoded.contains("CBORE Ø11"))
        XCTAssertTrue(dxfDecoded.contains("HOLE 5.000–5.012"))
        XCTAssertTrue(dxfDecoded.contains("SCALE 1:1 · mm"))
        XCTAssertTrue(dxfText.contains("0\nPOLYLINE\n"))
        XCTAssertTrue(dxfText.contains("0\nCIRCLE\n"))
        XCTAssertTrue(dxfText.contains("0\nLINE\n"))
        XCTAssertTrue(DXFKit.importDXF(dxf).count > 0)

        let pdf = try service.exportData(pageID: UUID(uuidString: sheet.pageID)!,
                                         format: "pdf")
        retainExport(pdf, name: "e16-manufacturing.pdf", type: "com.adobe.pdf")
        XCTAssertEqual(String(data: Data(pdf.prefix(5)), encoding: .ascii), "%PDF-")
        let provider = try XCTUnwrap(CGDataProvider(data: pdf as CFData))
        let pdfDocument = try XCTUnwrap(CGPDFDocument(provider))
        XCTAssertEqual(pdfDocument.numberOfPages, 1)
        let mediaBox = try XCTUnwrap(pdfDocument.page(at: 1)?.getBoxRect(.mediaBox))
        XCTAssertEqual(Double(mediaBox.width), 297 * 72 / 25.4, accuracy: 1.0)

        // Editing the SOURCE feature updates the counterbore callout on the
        // same annotation id/placement.
        let parameters = CADParameterService(document: document)
        let updated = parameters.handle(action: "update", args: [
            "feature_id": fixture.holeFeature,
            "changes": ["counterbore_diameter": 13.0, "counterbore_depth": 8.0],
        ])
        XCTAssertEqual(updated["ok"] as? Bool, true, "\(updated)")
        geometry = service.handle(action: "project", args: ["pageID": sheet.pageID])
        let updatedCounterbore = try XCTUnwrap(manufacturingRow(geometry, id: counterboreID))
        XCTAssertEqual(updatedCounterbore["id"] as? String, counterboreID)
        XCTAssertTrue(displayLines(updatedCounterbore).contains { $0.contains("CBORE Ø13") })
        XCTAssertTrue(displayLines(updatedCounterbore).contains { $0.contains("DEPTH 8") })

        // The linked DIMENSION does not get the manufacturing station-drift
        // relaxation. The depth edit moved the captured pilot face's centroid
        // 1.0 mm (tolerance 0.5) and no other face sits at the captured
        // station, so it must report the precise MISSING-cylinder reason —
        // never the ambiguous-face error (an empty match set is not
        // "several valid faces").
        let shiftedDimension = try XCTUnwrap(self.dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(shiftedDimension["id"] as? String, dimensionID)
        XCTAssertEqual(shiftedDimension["dangling"] as? Bool, true,
                       "the dimension keeps the captured axial station: \(shiftedDimension)")
        XCTAssertTrue(shiftedDimension["value"] is NSNull)
        XCTAssertTrue((shiftedDimension["reasons"] as? [String] ?? []).contains {
            $0.contains("The linked cylindrical face no longer exists")
                && $0.contains("deleted or the topology changed")
        }, "\(shiftedDimension)")
        XCTAssertFalse((shiftedDimension["reasons"] as? [String] ?? []).contains {
            $0.localizedCaseInsensitiveContains("ambiguous")
        }, "a missing cylinder must not be reported as an ambiguous face: \(shiftedDimension)")

        // Changing the pilot to Ø8 makes the explicit M6 callout conflict; it
        // becomes visibly stale, never retaining a plausible old value.
        let radiusEdit = parameters.handle(action: "updateSketchEntity", args: [
            "sketch_id": fixture.holeSketch, "entity_id": fixture.holeEntity, "radius": 4.0,
        ])
        XCTAssertEqual(radiusEdit["ok"] as? Bool, true, "\(radiusEdit)")
        geometry = service.handle(action: "project", args: ["pageID": sheet.pageID])
        let staleThread = try XCTUnwrap(manufacturingRow(geometry, id: threadID))
        XCTAssertEqual(staleThread["stale"] as? Bool, true)
        XCTAssertEqual(displayLines(staleThread), ["STALE"])
        XCTAssertNil(staleThread["computed"])
        XCTAssertTrue((staleThread["reasons"] as? [String] ?? []).contains {
            $0.localizedCaseInsensitiveContains("does not match")
        })

        // Save/reopen keeps the same ids and the honest stale state, then
        // deleting the source feature dangles every bound callout and the
        // tolerance dimension.
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        let reopenedService = CADDrawingService(document: reopened)
        geometry = reopenedService.handle(action: "project", args: ["pageID": sheet.pageID])
        let reopenedCounterbore = try XCTUnwrap(manufacturingRow(geometry, id: counterboreID))
        XCTAssertEqual(reopenedCounterbore["id"] as? String, counterboreID)
        let reopenedThread = try XCTUnwrap(manufacturingRow(geometry, id: threadID))
        XCTAssertEqual(reopenedThread["stale"] as? Bool, true)
        let reopenedParameters = CADParameterService(document: reopened)
        let deleted = reopenedParameters.handle(action: "feature.delete", args: [
            "feature_id": fixture.holeFeature, "force": true,
        ])
        XCTAssertEqual(deleted["ok"] as? Bool, true, "\(deleted)")
        geometry = reopenedService.handle(action: "project", args: ["pageID": sheet.pageID])
        let danglingCounterbore = try XCTUnwrap(manufacturingRow(geometry, id: counterboreID))
        XCTAssertEqual(danglingCounterbore["dangling"] as? Bool, true)
        XCTAssertEqual(displayLines(danglingCounterbore), ["STALE"],
                       "a deleted hole must not keep Ø13/DEPTH 8")
        let danglingDimension = try XCTUnwrap(
            (geometry["manualDimensions"] as? [[String: Any]])?
                .first { ($0["id"] as? String) == dimensionID })
        XCTAssertEqual(danglingDimension["dangling"] as? Bool, true)
        XCTAssertTrue(danglingDimension["value"] is NSNull)
        XCTAssertNil(danglingDimension["toleranceDisplay"])
        reopened.close()
    }

    // MARK: - R12 text encoding

    /// The isolated R12 codec: printable ASCII stays literal, Chinese and
    /// engineering symbols use `\U+nnnn`, non-BMP scalars use the UTF-16
    /// surrogate pair, and a literal author `\U+0041` is escaped once so a
    /// single decode pass restores it byte for byte. A legacy file with no
    /// escapes decodes to itself.
    func testDXFTextCodecRoundTripsEscapesAndLiteralBackslashes() throws {
        let cases = [
            "",
            "M6×1.0-6H",
            "CBORE Ø11",
            "HOLE 5.000–5.012",
            "SCALE 1:1 · mm · 3 dp",
            "中文零件 总成A",
            #"C:\U+0041"#,
            #"\\U+0041"#,
            #"literal \U+4E2D text"#,
            "naïve façade",
            "emoji 👩🏽‍👩🏽‍👧🏽‍👧🏽 🇦🇺",
            "tab\there",
        ]
        for original in cases {
            let wire = DXFTextCodec.encode(original)
            XCTAssertTrue(wire.unicodeScalars.allSatisfy { $0.value < 0x80 },
                          "the R12 wire form must be ASCII: \(wire)")
            XCTAssertEqual(DXFTextCodec.decode(wire), original,
                           "one decode pass must restore \(original.debugDescription)")
        }
        XCTAssertEqual(DXFTextCodec.encode("中文"), #"\U+4E2D\U+6587"#)
        XCTAssertEqual(DXFTextCodec.encode("Ø5 × M6–M8 · 1:1"),
                       #"\U+00D85 \U+00D7 M6\U+2013M8 \U+00B7 1:1"#)
        XCTAssertEqual(DXFTextCodec.encode(#"\U+0041"#), #"\U+005CU+0041"#)
        XCTAssertEqual(DXFTextCodec.decode(#"\U+005CU+0041"#), #"\U+0041"#)
        XCTAssertEqual(DXFTextCodec.decode(#"\U+D83DXU+DE00"#),
                       #"\U+D83DXU+DE00"#,
                       "A malformed second escape must not invent a surrogate pair")
        XCTAssertEqual(DXFTextCodec.decode(DXFTextCodec.encode(#"\U+0041"#)),
                       #"\U+0041"#, "the emitted backslash must not be decoded twice")
        // An existing unescaped legacy value keeps its literal bytes.
        XCTAssertEqual(DXFTextCodec.decode("Ø5 H7/h6"), "Ø5 H7/h6")
    }

    /// Real R12 export with Chinese and engineering symbols: asserted on the
    /// exact wire escapes, on the text one decode pass produces, and on the
    /// same page/annotation ids exporting byte-identical DXF after reopen.
    /// Both exports are retained for Root's independent reader.
    func testR12DXFEncodesChineseEngineeringTextAndLiteralBackslash() async throws {
        let document = try await makeDocument("R12-unicode")
        let fixture = try makeCounterboreFixture(document)
        let service = CADDrawingService(document: document)
        let sheetTitle = "中文 Ø5 × M6–M8 · 1:1"
        let created = service.handle(action: "standardSheet", args: [
            "bodyID": fixture.bodyID, "title": sheetTitle, "replace": true,
        ])
        XCTAssertEqual(created["ok"] as? Bool, true, "\(created)")
        let pages = try XCTUnwrap(created["pages"] as? [[String: Any]])
        let front = try XCTUnwrap(pages.first { ($0["kind"] as? String) == "front" })
        let pageID = try XCTUnwrap(front["id"] as? String)
        let annotationText = #"中文 Ø5 × M6–M8 · C:\U+0041 · Ra 1.6"#
        let added = service.handle(action: "addAnnotation", args: [
            "pageID": pageID,
            "text": annotationText, "position": [20.0, -20.0], "heightMM": 3.0,
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let annotation = try XCTUnwrap(added["annotation"] as? [String: Any])
        let annotationID = try XCTUnwrap(annotation["id"] as? String)
        XCTAssertEqual(annotation["text"] as? String, annotationText)

        let pageUUID = try XCTUnwrap(UUID(uuidString: pageID))
        let dxf = try service.exportData(pageID: pageUUID, format: "dxf")
        retainExport(dxf, name: "r12-unicode-before-reopen.dxf", type: "public.data")
        XCTAssertTrue(dxf.allSatisfy { $0 < 0x80 },
                      "an R12/AC1009 DXF must not carry raw UTF-8 bytes")
        let wire = try XCTUnwrap(String(data: dxf, encoding: .ascii))
        XCTAssertTrue(wire.contains("9\n$DWGCODEPAGE\n3\nANSI_1252"))
        // Exact wire escapes for 中文, the title's Ø/×/–/· and the annotation.
        XCTAssertTrue(wire.contains(#"\U+4E2D\U+6587 \U+00D85 \U+00D7 M6\U+2013M8 \U+00B7 1:1"#),
                      "the sheet title must be ASCII-escaped on the wire")
        XCTAssertTrue(wire.contains(
            #"\U+4E2D\U+6587 \U+00D85 \U+00D7 M6\U+2013M8 \U+00B7 C:\U+005CU+0041 \U+00B7 Ra 1.6"#),
            "the annotation must be ASCII-escaped on the wire")
        XCTAssertFalse(wire.contains(#"\U+0041"#),
                       "a literal author \\U+0041 must be escaped, not emitted raw")
        // One decode pass (what an independent DXF reader performs) gives the
        // real author text back, including the literal backslash.
        let decoded = DXFTextCodec.decode(wire)
        XCTAssertTrue(decoded.contains(annotationText))
        XCTAssertTrue(decoded.contains(sheetTitle))
        XCTAssertTrue(decoded.contains(#"C:\U+0041"#))
        XCTAssertTrue(decoded.contains("Ra 1.6"))

        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        let reopenedService = CADDrawingService(document: reopened)
        let geometry = reopenedService.handle(action: "project", args: ["pageID": pageID])
        let annotations = try XCTUnwrap(geometry["annotations"] as? [[String: Any]])
        let reopenedAnnotation = try XCTUnwrap(
            annotations.first { ($0["id"] as? String) == annotationID })
        XCTAssertEqual(reopenedAnnotation["text"] as? String, annotationText,
                       "the same annotation id and exact author text must survive reopen")
        let reopenedDxf = try reopenedService.exportData(pageID: pageUUID, format: "dxf")
        XCTAssertEqual(reopenedDxf, dxf,
                       "the same ids/annotations must export byte-identical R12 DXF")
        retainExport(reopenedDxf, name: "r12-unicode-after-reopen.dxf", type: "public.data")
        reopened.close()
    }

    // MARK: - Service edit contracts

    func testDimensionEditAcceptsOneSidedLimitsAndClearsTolerance() async throws {
        let document = try await makeDocument("dimension-edit")
        let fixture = try makeCounterboreFixture(document)
        let service = CADDrawingService(document: document)
        let sheet = try makeMultiView(service, bodyID: fixture.bodyID,
                                      title: "Dimension edit")
        let pilot = try candidate(radius: 2.5, pageID: sheet.pageID,
                                  viewID: sheet.frontID, service: service)
        let reference = try XCTUnwrap(pilot["reference"] as? [String: Any])

        // Both absolute limits above the Ø5 basic nominal are accepted by the
        // service, not rejected as an out-of-range nominal.
        let added = service.handle(action: "addDimension", args: [
            "pageID": sheet.pageID, "viewID": sheet.frontID, "kind": "diameter",
            "feature": reference,
            "tolerance": ["kind": "limits",
                          "upperLimitMM": 5.2, "lowerLimitMM": 5.1],
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let dimension = try XCTUnwrap(added["dimension"] as? [String: Any])
        let dimensionID = try XCTUnwrap(dimension["id"] as? String)
        let originalPoints = try XCTUnwrap(dimension["drawingPoints"] as? [[Double]])
        XCTAssertNil(dimension["toleranceWarning"])
        let toleranceDisplay = try XCTUnwrap(
            dimension["toleranceDisplay"] as? [String: Any])
        XCTAssertEqual(toleranceDisplay["consistentWithNominal"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(toleranceDisplay["upperDeviationMM"] as? Double),
                       0.2, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(toleranceDisplay["lowerDeviationMM"] as? Double),
                       0.1, accuracy: 1e-9)

        var geometry = service.handle(action: "project", args: ["pageID": sheet.pageID])
        var row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["stale"] as? Bool, false)
        XCTAssertEqual(row["status"] as? String, "resolved")
        XCTAssertNil(row["toleranceWarning"])

        // One atomic edit clears the tolerance, sets a text override and moves
        // the text, without touching the feature, value or geometry.
        let undoBefore = document.session.undoStack.undoCommands.count
        let cleared = service.handle(action: "updateDimension", args: [
            "pageID": sheet.pageID, "dimensionID": dimensionID,
            "text": "NOMINAL", "textPosition": [12.0, 13.0],
            "tolerance": NSNull(),
        ])
        XCTAssertEqual(cleared["ok"] as? Bool, true, "\(cleared)")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore + 1)
        geometry = service.handle(action: "project", args: ["pageID": sheet.pageID])
        row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["text"] as? String, "NOMINAL")
        XCTAssertEqual(row["textOverride"] as? String, "NOMINAL")
        XCTAssertNil(row["tolerance"])
        XCTAssertNil(row["toleranceDisplay"])
        XCTAssertEqual(row["value"] as? Double ?? 0, 5, accuracy: 1e-9)
        XCTAssertEqual(row["localTextPosition"] as? [Double], [12.0, 13.0])
        let preservedPoints = try XCTUnwrap(row["drawingPoints"] as? [[Double]])
        XCTAssertEqual(preservedPoints.count, originalPoints.count)
        for (before, after) in zip(originalPoints, preservedPoints) {
            XCTAssertEqual(before[0], after[0], accuracy: 1e-9)
            XCTAssertEqual(before[1], after[1], accuracy: 1e-9)
        }
        let preservedFeature = try XCTUnwrap(row["feature"] as? [String: Any])
        XCTAssertEqual(preservedFeature["featureID"] as? String, fixture.holeFeature)

        // A tolerance-only edit keeps the text override and accepts a band
        // entirely below the nominal, again without a stale/inconsistent flag.
        let refit = service.handle(action: "updateDimension", args: [
            "pageID": sheet.pageID, "dimensionID": dimensionID,
            "tolerance": ["kind": "limits",
                          "upperLimitMM": 4.9, "lowerLimitMM": 4.8],
        ])
        XCTAssertEqual(refit["ok"] as? Bool, true, "\(refit)")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore + 2)
        geometry = service.handle(action: "project", args: ["pageID": sheet.pageID])
        row = try XCTUnwrap(dimensionRow(geometry, id: dimensionID))
        XCTAssertEqual(row["text"] as? String, "NOMINAL",
                       "a tolerance-only edit must not lose the text override")
        XCTAssertEqual(row["textOverride"] as? String, "NOMINAL")
        XCTAssertEqual((row["tolerance"] as? [String: Any])?["kind"] as? String, "limits")
        XCTAssertEqual(row["stale"] as? Bool, false)
        XCTAssertNil(row["toleranceWarning"])
        let belowDisplay = try XCTUnwrap(row["toleranceDisplay"] as? [String: Any])
        XCTAssertEqual(belowDisplay["consistentWithNominal"] as? Bool, true)
        XCTAssertEqual(try XCTUnwrap(belowDisplay["upperDeviationMM"] as? Double),
                       -0.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(belowDisplay["lowerDeviationMM"] as? Double),
                       -0.2, accuracy: 1e-9)
        document.close()
    }

    func testManufacturingUpdateKeepsIDSourceAndUntouchedPayload() async throws {
        let document = try await makeDocument("manufacturing-edit")
        let fixture = try makeCounterboreFixture(document)
        let service = CADDrawingService(document: document)
        let sheet = try makeMultiView(service, bodyID: fixture.bodyID,
                                      title: "Manufacturing edit")
        let pilot = try candidate(radius: 2.5, pageID: sheet.pageID,
                                  viewID: sheet.frontID, service: service)
        let reference = try XCTUnwrap(pilot["reference"] as? [String: Any])
        let added = service.handle(action: "addManufacturingAnnotation", args: [
            "pageID": sheet.pageID, "viewID": sheet.frontID, "kind": "datumFeature",
            "position": [10.0, 10.0], "heightMM": 3.0,
            "feature": reference,
            "datum": ["letter": "A", "leaderTarget": [12.0, 8.0]],
        ])
        XCTAssertEqual(added["ok"] as? Bool, true, "\(added)")
        let annotation = try XCTUnwrap(
            added["manufacturingAnnotation"] as? [String: Any])
        let annotationID = try XCTUnwrap(annotation["id"] as? String)

        let undoBefore = document.session.undoStack.undoCommands.count
        let updated = service.handle(action: "updateManufacturingAnnotation", args: [
            "pageID": sheet.pageID, "annotationID": annotationID,
            "kind": "datumFeature", "position": [20.0, 18.0], "heightMM": 4.0,
            // The native editor starts from the stored payload and sends the
            // merged object, so the leader target it does not display is kept.
            "datum": ["letter": "B", "leaderTarget": [12.0, 8.0]],
        ])
        XCTAssertEqual(updated["ok"] as? Bool, true, "\(updated)")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore + 1)
        var geometry = service.handle(action: "project", args: ["pageID": sheet.pageID])
        var row = try XCTUnwrap(manufacturingRow(geometry, id: annotationID))
        XCTAssertEqual(row["id"] as? String, annotationID)
        var configured = try XCTUnwrap(row["configured"] as? [String: Any])
        XCTAssertEqual(configured["kind"] as? String, "datumFeature")
        XCTAssertEqual(configured["position"] as? [Double], [20.0, 18.0])
        XCTAssertEqual(configured["heightMM"] as? Double, 4.0)
        var datum = try XCTUnwrap(configured["datum"] as? [String: Any])
        XCTAssertEqual(datum["letter"] as? String, "B")
        XCTAssertEqual(datum["leaderTarget"] as? [Double], [12.0, 8.0])
        var feature = try XCTUnwrap(configured["feature"] as? [String: Any])
        XCTAssertEqual(feature["featureID"] as? String, fixture.holeFeature)

        // Omitting feature/position/height keeps them: this is what the native
        // editor relies on when the stored source is not re-selected.
        let second = service.handle(action: "updateManufacturingAnnotation", args: [
            "pageID": sheet.pageID, "annotationID": annotationID,
            "kind": "datumFeature",
            "datum": ["letter": "C", "leaderTarget": [12.0, 8.0]],
        ])
        XCTAssertEqual(second["ok"] as? Bool, true, "\(second)")
        geometry = service.handle(action: "project", args: ["pageID": sheet.pageID])
        row = try XCTUnwrap(manufacturingRow(geometry, id: annotationID))
        configured = try XCTUnwrap(row["configured"] as? [String: Any])
        XCTAssertEqual(configured["position"] as? [Double], [20.0, 18.0])
        XCTAssertEqual(configured["heightMM"] as? Double, 4.0)
        datum = try XCTUnwrap(configured["datum"] as? [String: Any])
        XCTAssertEqual(datum["letter"] as? String, "C")
        feature = try XCTUnwrap(configured["feature"] as? [String: Any])
        XCTAssertEqual(feature["featureID"] as? String, fixture.holeFeature)

        // Kind remains immutable; the editor never delete/recreates to switch.
        let bad = service.handle(action: "updateManufacturingAnnotation", args: [
            "pageID": sheet.pageID, "annotationID": annotationID,
            "kind": "weld", "weld": ["type": "fillet", "sizeMM": 6],
        ])
        XCTAssertEqual(bad["ok"] as? Bool, false)
        XCTAssertEqual(bad["error"] as? String, "kind_immutable")
        document.close()
    }

    func testManufacturingToleranceAndRoughnessKeepSmallValuesAtTwoDP() async throws {
        let document = try await makeDocument("manufacturing-small-values")
        let plate = try makePlate(document)
        let service = CADDrawingService(document: document)
        let sheet = try makeMultiView(service, bodyID: plate.bodyID,
                                      title: "Small values")
        let precision = service.handle(action: "updatePage", args: [
            "pageID": sheet.pageID, "precision": 2,
        ])
        XCTAssertEqual(precision["ok"] as? Bool, true, "\(precision)")

        let frame = service.handle(action: "addManufacturingAnnotation", args: [
            "pageID": sheet.pageID, "viewID": sheet.frontID,
            "kind": "featureControlFrame", "position": [20.0, 20.0], "heightMM": 3.0,
            "featureControlFrame": [
                "characteristic": "position", "toleranceMM": 0.001,
                "diameterZone": true,
                "datumReferences": [["letter": "A"]],
            ],
        ])
        XCTAssertEqual(frame["ok"] as? Bool, true, "\(frame)")
        let frameID = try XCTUnwrap(
            (frame["manufacturingAnnotation"] as? [String: Any])?["id"] as? String)

        let finish = service.handle(action: "addManufacturingAnnotation", args: [
            "pageID": sheet.pageID, "viewID": sheet.frontID,
            "kind": "surfaceFinish", "position": [40.0, 20.0], "heightMM": 3.0,
            "surfaceFinish": ["raMicrometres": 0.025, "allAround": false],
        ])
        XCTAssertEqual(finish["ok"] as? Bool, true, "\(finish)")
        let finishID = try XCTUnwrap(
            (finish["manufacturingAnnotation"] as? [String: Any])?["id"] as? String)

        let geometry = service.handle(action: "project", args: ["pageID": sheet.pageID])
        XCTAssertEqual(geometry["ok"] as? Bool, true, "\(geometry)")

        // The page says 2 dp, but the actual tolerance is 0.001 mm: the
        // displayed value must keep the third place, not become 0.00.
        let frameRow = try XCTUnwrap(manufacturingRow(geometry, id: frameID))
        let frameDisplay = try XCTUnwrap(frameRow["display"] as? [String: Any])
        XCTAssertEqual(frameDisplay["toleranceText"] as? String, "Ø0.001")
        let frameConfigured = try XCTUnwrap(frameRow["configured"] as? [String: Any])
        let framePayload = try XCTUnwrap(
            frameConfigured["featureControlFrame"] as? [String: Any])
        XCTAssertEqual(framePayload["toleranceMM"] as? Double ?? 0, 0.001,
                       accuracy: 1e-12, "exact GD&T tolerance metadata is retained")

        // Roughness is also a tolerance-like value; 0.025 µm must survive.
        let finishRow = try XCTUnwrap(manufacturingRow(geometry, id: finishID))
        let finishDisplay = try XCTUnwrap(finishRow["display"] as? [String: Any])
        XCTAssertEqual(finishDisplay["raText"] as? String, "Ra 0.025")
        let computed = try XCTUnwrap(finishRow["computed"] as? [String: Any])
        XCTAssertEqual(computed["raMicrometres"] as? Double ?? 0, 0.025,
                       accuracy: 1e-12, "exact micrometre metadata is retained")

        // The same precise text reaches the real vector export.
        let svg = try service.exportData(pageID: try XCTUnwrap(UUID(uuidString: sheet.pageID)),
                                         format: "svg")
        let svgText = try XCTUnwrap(String(data: svg, encoding: .utf8))
        XCTAssertTrue(svgText.contains("Ø0.001"))
        XCTAssertTrue(svgText.contains("Ra 0.025"))
        document.close()
    }

    // MARK: - E18: one template, two sheets, one transaction, reopen/export

    func testSheetTemplateAppliesToMultipleSheetsAndSurvivesDeletion() async throws {
        let document = try await makeDocument("E18")
        let plate = try makePlate(document)
        let service = CADDrawingService(document: document)
        let sheet = service.handle(action: "standardSheet",
                                   args: ["bodyID": plate.bodyID, "title": "E18"])
        XCTAssertEqual(sheet["ok"] as? Bool, true, "\(sheet)")
        let pages = try XCTUnwrap(sheet["pages"] as? [[String: Any]])
        XCTAssertEqual(pages.count, 4)
        let pageA = try XCTUnwrap(pages[0]["id"] as? String)
        let pageB = try XCTUnwrap(pages[1]["id"] as? String)

        let create = service.handle(action: "createTemplate", args: [
            "name": "Plant A3", "paper": "a3", "projection": "firstAngle",
            "units": "millimetre", "precision": 2,
            "style": ["marginMM": 8, "titleBlockWidthMM": 120,
                      "titleBlockHeightMM": 30, "lineWidthMM": 0.3,
                      "textHeightMM": 3.4],
            "titleBlock": ["company": "Floe Works", "drawingNumber": "DW-100"],
            "revisionRows": [
                ["revision": "A", "date": "2026-10-01", "description": "Initial release"],
                ["revision": "B", "date": "2026-10-15", "description": "Hole update"],
            ],
        ])
        XCTAssertEqual(create["ok"] as? Bool, true, "\(create)")
        let template = try XCTUnwrap(create["template"] as? [String: Any])
        let templateID = try XCTUnwrap(template["id"] as? String)

        let undoBefore = document.session.undoStack.undoCommands.count
        let applied = service.handle(action: "applyTemplate", args: [
            "templateID": templateID, "pageIDs": [pageA, pageB],
        ])
        XCTAssertEqual(applied["ok"] as? Bool, true, "\(applied)")
        XCTAssertEqual(applied["appliedCount"] as? Int, 2)
        XCTAssertEqual(applied["transaction"] as? String, "single")
        XCTAssertEqual(applied["undoSteps"] as? Int, 1)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBefore + 1)
        var pagesReply = service.handle(action: "pages", args: [:])
        var pageRows = try XCTUnwrap(pagesReply["pages"] as? [[String: Any]])
        for id in [pageA, pageB] {
            let row = try XCTUnwrap(pageRows.first { ($0["id"] as? String) == id })
            XCTAssertEqual(row["templateID"] as? String, templateID)
            XCTAssertEqual(row["projectionMethod"] as? String, "firstAngle")
            XCTAssertEqual(row["precision"] as? Int, 2)
            XCTAssertEqual((row["revisionRows"] as? [[String: Any]])?.count, 2)
            XCTAssertEqual((row["titleBlock"] as? [String: Any])?["company"] as? String,
                           "Floe Works")
        }
        // One undo removes the whole application from BOTH sheets.
        document.session.undo()
        pagesReply = service.handle(action: "pages", args: [:])
        pageRows = try XCTUnwrap(pagesReply["pages"] as? [[String: Any]])
        for id in [pageA, pageB] {
            let row = try XCTUnwrap(pageRows.first { ($0["id"] as? String) == id })
            XCTAssertNil(row["templateID"])
            XCTAssertNil(row["precision"])
        }
        document.session.redo()

        // Edit one sheet's revision table/precision; the other keeps its own.
        let updated = service.handle(action: "updatePage", args: [
            "pageID": pageA, "precision": 3,
            "revisionRows": [
                ["revision": "A", "date": "2026-10-01", "description": "Initial release"],
                ["revision": "B", "date": "2026-10-15", "description": "Hole update"],
                ["revision": "C", "date": "2026-11-01", "description": "Tolerance update"],
            ],
        ])
        XCTAssertEqual(updated["ok"] as? Bool, true, "\(updated)")
        let updatedPage = try XCTUnwrap(updated["page"] as? [String: Any])
        XCTAssertEqual(updatedPage["precision"] as? Int, 3)
        XCTAssertEqual((updatedPage["revisionRows"] as? [[String: Any]])?.count, 3)

        let pageAUUID = try XCTUnwrap(UUID(uuidString: pageA))
        let pageBUUID = try XCTUnwrap(UUID(uuidString: pageB))
        let svgA = try XCTUnwrap(String(data: service.exportData(pageID: pageAUUID,
                                                                 format: "svg"),
                                        encoding: .utf8))
        let svgB = try XCTUnwrap(String(data: service.exportData(pageID: pageBUUID,
                                                                 format: "svg"),
                                        encoding: .utf8))
        XCTAssertTrue(svgA.contains("3 dp"))
        XCTAssertTrue(svgB.contains("2 dp"))
        XCTAssertTrue(svgA.contains("FIRST ANGLE"))
        XCTAssertTrue(svgA.contains("Tolerance update"))
        XCTAssertTrue(svgB.contains("Hole update"))
        let titleA = try XCTUnwrap(svgGroup(svgA, id: "TITLE"))
        XCTAssertTrue(titleA.contains("<line"))
        XCTAssertTrue(titleA.contains("<circle"), "projection symbol carries its circle")
        XCTAssertTrue(titleA.contains("<path"), "projection symbol carries its cone")
        // TITLE carries the frame/symbol geometry; the title-block strings are
        // the writer's filled TITLE_TEXT sibling of the same layer.
        let titleTextA = try XCTUnwrap(svgGroup(svgA, id: "TITLE_TEXT"))
        XCTAssertTrue(titleTextA.contains("Floe Works"))
        let dxfA = try XCTUnwrap(String(data: service.exportData(pageID: pageAUUID,
                                                                 format: "dxf"),
                                        encoding: .utf8))
        XCTAssertTrue(dxfA.contains("TITLE"))
        XCTAssertTrue(dxfA.contains("Floe Works"))
        XCTAssertTrue(dxfA.contains("Tolerance update"))
        XCTAssertTrue(dxfA.contains("3 dp"))
        XCTAssertTrue(dxfA.contains("0\nTEXT\n"))
        let pdfA = try service.exportData(pageID: pageAUUID, format: "pdf")
        retainExport(Data(svgA.utf8), name: "e18-before-reopen.svg", type: "public.svg-image")
        retainExport(Data(dxfA.utf8), name: "e18-before-reopen.dxf", type: "public.data")
        retainExport(pdfA, name: "e18-before-reopen.pdf", type: "com.adobe.pdf")
        XCTAssertEqual(String(data: Data(pdfA.prefix(5)), encoding: .ascii), "%PDF-")

        // Save/reopen: same layout/revision/precision and byte-identical SVG.
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        let reopenedService = CADDrawingService(document: reopened)
        let reopenedPages = reopenedService.handle(action: "pages", args: [:])
        let reopenedRows = try XCTUnwrap(reopenedPages["pages"] as? [[String: Any]])
        let reopenedA = try XCTUnwrap(reopenedRows.first { ($0["id"] as? String) == pageA })
        XCTAssertEqual(reopenedA["templateID"] as? String, templateID)
        XCTAssertEqual(reopenedA["precision"] as? Int, 3)
        XCTAssertEqual((reopenedA["revisionRows"] as? [[String: Any]])?.count, 3)
        let reopenedSvgA = try XCTUnwrap(String(
            data: reopenedService.exportData(pageID: pageAUUID, format: "svg"),
            encoding: .utf8))
        XCTAssertEqual(reopenedSvgA, svgA,
                       "the saved/reopened sheet must render the same vector layout")
        let reopenedDxfA = try reopenedService.exportData(pageID: pageAUUID, format: "dxf")
        XCTAssertEqual(reopenedDxfA, Data(dxfA.utf8),
                       "saved/reopened DXF must retain the actual geometry and annotations")
        let reopenedPdfA = try reopenedService.exportData(pageID: pageAUUID, format: "pdf")
        retainExport(Data(reopenedSvgA.utf8), name: "e18-after-reopen.svg", type: "public.svg-image")
        retainExport(reopenedDxfA, name: "e18-after-reopen.dxf", type: "public.data")
        retainExport(reopenedPdfA, name: "e18-after-reopen.pdf", type: "com.adobe.pdf")

        // Deleting the library record does not change the applied page.
        let deleted = reopenedService.handle(action: "deleteTemplate", args: [
            "templateID": templateID,
        ])
        XCTAssertEqual(deleted["ok"] as? Bool, true, "\(deleted)")
        let afterDeleteSvg = try XCTUnwrap(String(
            data: reopenedService.exportData(pageID: pageAUUID, format: "svg"),
            encoding: .utf8))
        XCTAssertEqual(afterDeleteSvg, svgA,
                       "the page snapshot must survive template deletion")
        let afterDeletePages = reopenedService.handle(action: "pages", args: [:])
        let afterDeleteRow = try XCTUnwrap(
            (afterDeletePages["pages"] as? [[String: Any]])?
                .first { ($0["id"] as? String) == pageA })
        XCTAssertEqual(afterDeleteRow["templateID"] as? String, templateID)
        let listAfterDelete = reopenedService.handle(action: "listTemplates", args: [:])
        XCTAssertFalse((listAfterDelete["templates"] as? [[String: Any]] ?? [])
            .contains { ($0["id"] as? String) == templateID })

        // A bad batch is refused before any page changes.
        let undoBeforeBad = reopened.session.undoStack.undoCommands.count
        let pagesBeforeBad = reopenedService.handle(action: "pages", args: [:])
        let bad = reopenedService.handle(action: "applyTemplate", args: [
            "templateID": CADDrawingSheetTemplateLibrary.builtIns[0].id.uuidString,
            "pageIDs": [pageA, UUID().uuidString],
        ])
        XCTAssertEqual(bad["ok"] as? Bool, false)
        XCTAssertEqual(bad["error"] as? String, "unknown_page")
        XCTAssertEqual(reopened.session.undoStack.undoCommands.count, undoBeforeBad)
        let pagesAfterBad = reopenedService.handle(action: "pages", args: [:])
        for id in [pageA, pageB] {
            let before = try XCTUnwrap((pagesBeforeBad["pages"] as? [[String: Any]])?
                .first { ($0["id"] as? String) == id })
            let after = try XCTUnwrap((pagesAfterBad["pages"] as? [[String: Any]])?
                .first { ($0["id"] as? String) == id })
            XCTAssertEqual(before["templateID"] as? String, after["templateID"] as? String)
            XCTAssertEqual(before["precision"] as? Int, after["precision"] as? Int)
            XCTAssertEqual((before["revisionRows"] as? [[String: Any]])?.count,
                           (after["revisionRows"] as? [[String: Any]])?.count)
        }
        reopened.close()

        // Built-in first/third-angle presets are real supported layouts: a
        // multi-view sheet's Top view sits below/above Front accordingly.
        let second = try await makeDocument("E18-angle")
        let plateSecond = try makePlate(second)
        let secondService = CADDrawingService(document: second)
        let multi = try makeMultiView(secondService, bodyID: plateSecond.bodyID, title: "Angles")
        let builtIns = secondService.handle(action: "listTemplates", args: [:])
        let builtInRows = try XCTUnwrap(builtIns["builtIns"] as? [[String: Any]])
        let firstAngle = try XCTUnwrap(builtInRows.first {
            ($0["name"] as? String) == "A3 First Angle"
        })
        let thirdAngle = try XCTUnwrap(builtInRows.first {
            ($0["name"] as? String) == "A3 Third Angle"
        })
        let appliedFirst = secondService.handle(action: "applyTemplate", args: [
            "templateID": try XCTUnwrap(firstAngle["id"] as? String),
            "pageIDs": [multi.pageID],
        ])
        XCTAssertEqual(appliedFirst["ok"] as? Bool, true, "\(appliedFirst)")
        var multiGeometry = secondService.handle(action: "project", args: ["pageID": multi.pageID])
        var viewRows = try XCTUnwrap(multiGeometry["views"] as? [[String: Any]])
        let frontRow = try XCTUnwrap(viewRows.first { ($0["kind"] as? String) == "front" })
        let topRow = try XCTUnwrap(viewRows.first { ($0["kind"] as? String) == "top" })
        let frontBounds = try XCTUnwrap(frontRow["bounds"] as? [[Double]])
        let topBounds = try XCTUnwrap(topRow["bounds"] as? [[Double]])
        XCTAssertLessThan(topBounds[1][1], frontBounds[0][1],
                          "first angle places the Top view below Front")
        let appliedThird = secondService.handle(action: "applyTemplate", args: [
            "templateID": try XCTUnwrap(thirdAngle["id"] as? String),
            "pageIDs": [multi.pageID],
        ])
        XCTAssertEqual(appliedThird["ok"] as? Bool, true, "\(appliedThird)")
        multiGeometry = secondService.handle(action: "project", args: ["pageID": multi.pageID])
        viewRows = try XCTUnwrap(multiGeometry["views"] as? [[String: Any]])
        let frontAgain = try XCTUnwrap(viewRows.first { ($0["kind"] as? String) == "front" })
        let topAgain = try XCTUnwrap(viewRows.first { ($0["kind"] as? String) == "top" })
        let frontBoundsAgain = try XCTUnwrap(frontAgain["bounds"] as? [[Double]])
        let topBoundsAgain = try XCTUnwrap(topAgain["bounds"] as? [[Double]])
        XCTAssertGreaterThan(topBoundsAgain[0][1], frontBoundsAgain[1][1],
                             "third angle restores the Top view above Front")
        second.close()
    }

    // MARK: - E18 floor-7 named-version and rejected-update transaction

    func testFloorSevenDrawingSurvivesNamedVersionRestoreAndRejectedUpdate() async throws {
        let document = try await makeDocument("E18-floor7")
        let plate = try makePlate(document)
        let service = CADDrawingService(document: document)
        let sheet = service.handle(action: "standardSheet",
                                   args: ["bodyID": plate.bodyID, "title": "Floor 7"])
        XCTAssertEqual(sheet["ok"] as? Bool, true, "\(sheet)")
        let pages = try XCTUnwrap(sheet["pages"] as? [[String: Any]])
        let pageID = try XCTUnwrap(pages.first?["id"] as? String)
        let template = service.handle(action: "createTemplate", args: [
            "name": "Floor 7 template", "paper": "a3", "projection": "firstAngle",
            "units": "millimetre", "precision": 2,
            "revisionRows": [["revision": "A", "date": "2026-11-01",
                              "description": "Initial release"]],
        ])
        XCTAssertEqual(template["ok"] as? Bool, true, "\(template)")
        let templateID = try XCTUnwrap((template["template"] as? [String: Any])?["id"] as? String)
        let applied = service.handle(action: "applyTemplate", args: [
            "templateID": templateID, "pageIDs": [pageID],
        ])
        XCTAssertEqual(applied["ok"] as? Bool, true, "\(applied)")
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        let floorAfterApply = try manifestSchema(document.url)
        XCTAssertGreaterThanOrEqual(floorAfterApply, 7,
                                    "new drawing records must raise the package floor to 7")

        let base = try await document.createNamedVersion(name: "Floor 7 base")
        let revisionBeforeRejected = document.revision
        let contentBeforeRejected = document.contentSHA256
        let undoBeforeRejected = document.session.undoStack.undoCommands.count

        // A malformed revision row is refused BEFORE the drawing transaction;
        // it must not change the stored bytes, digest, revision or undo stack.
        let rejected = service.handle(action: "updatePage", args: [
            "pageID": pageID,
            "revisionRows": [["revision": "B", "description": "Update", "future": true]],
        ])
        XCTAssertEqual(rejected["ok"] as? Bool, false)
        XCTAssertEqual(rejected["error"] as? String, "unknown_revision_row_field")
        XCTAssertEqual(document.revision, revisionBeforeRejected)
        XCTAssertEqual(document.contentSHA256, contentBeforeRejected)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoBeforeRejected)
        let rejectedTitle = service.handle(action: "updatePage", args: [
            "pageID": pageID,
            "titleBlock": ["company": "Floe", "drawingNumber": "D-1", "future": 1],
        ])
        XCTAssertEqual(rejectedTitle["ok"] as? Bool, false)
        XCTAssertEqual(rejectedTitle["error"] as? String, "unknown_title_block_field")
        XCTAssertEqual(document.revision, revisionBeforeRejected)
        XCTAssertEqual(document.contentSHA256, contentBeforeRejected)
        let afterRejected = service.handle(action: "pages", args: [:])
        let afterRejectedRow = try XCTUnwrap(
            (afterRejected["pages"] as? [[String: Any]])?
                .first { ($0["id"] as? String) == pageID })
        XCTAssertEqual(afterRejectedRow["templateID"] as? String, templateID)
        XCTAssertEqual(afterRejectedRow["precision"] as? Int, 2)
        XCTAssertEqual((afterRejectedRow["revisionRows"] as? [[String: Any]])?.count, 1)

        // A real edit stays writable, then restores the floor-7 checkpoint.
        let edited = service.handle(action: "updatePage", args: [
            "pageID": pageID, "precision": 3,
            "revisionRows": [
                ["revision": "A", "date": "2026-11-01", "description": "Initial release"],
                ["revision": "B", "date": "2026-11-02", "description": "Tolerance update"],
            ],
        ])
        XCTAssertEqual(edited["ok"] as? Bool, true, "\(edited)")
        let editedSave = await document.save()
        XCTAssertTrue(editedSave.succeeded, editedSave.error ?? "")
        let floorAfterEdit = try manifestSchema(document.url)
        XCTAssertGreaterThanOrEqual(floorAfterEdit, 7)

        let restored = try await document.restoreNamedVersion(base.version.id)
        XCTAssertFalse(restored.alreadyCurrent)
        XCTAssertTrue(restored.undoBoundaryReset)
        XCTAssertGreaterThanOrEqual(document.project.formatVersion, 7,
                                    "restoring an old checkpoint must not lower the floor")
        let floorAfterRestore = try manifestSchema(document.url)
        XCTAssertGreaterThanOrEqual(floorAfterRestore, 7)
        XCTAssertFalse(document.isReadOnly)
        let restoredPages = service.handle(action: "pages", args: [:])
        let restoredRow = try XCTUnwrap(
            (restoredPages["pages"] as? [[String: Any]])?
                .first { ($0["id"] as? String) == pageID })
        XCTAssertEqual(restoredRow["templateID"] as? String, templateID)
        XCTAssertEqual(restoredRow["precision"] as? Int, 2)
        XCTAssertEqual((restoredRow["revisionRows"] as? [[String: Any]])?.count, 1)

        let restoredSave = await document.save()
        XCTAssertTrue(restoredSave.succeeded, restoredSave.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        let reopenedService = CADDrawingService(document: reopened)
        let reopenedPages = reopenedService.handle(action: "pages", args: [:])
        let reopenedRow = try XCTUnwrap(
            (reopenedPages["pages"] as? [[String: Any]])?
                .first { ($0["id"] as? String) == pageID })
        XCTAssertEqual(reopenedRow["templateID"] as? String, templateID)
        XCTAssertEqual(reopenedRow["precision"] as? Int, 2)
        XCTAssertEqual((reopenedRow["revisionRows"] as? [[String: Any]])?.count, 1)
        let reopenedList = reopenedService.handle(action: "listTemplates", args: [:])
        XCTAssertTrue((reopenedList["templates"] as? [[String: Any]] ?? [])
            .contains { ($0["id"] as? String) == templateID })
        let reopenedFloor = try manifestSchema(reopened.url)
        XCTAssertGreaterThanOrEqual(reopenedFloor, 7)
        reopened.close()
    }

    private func manifestSchema(_ url: URL) throws -> Int {
        let data = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(CADManifest.self, from: data).schemaVersion
    }

    // MARK: - SVG helpers

    private func svgGroup(_ text: String, id: String) -> String? {
        guard let start = text.range(of: "<g id=\"\(id)\"") else { return nil }
        guard let end = text.range(of: "</g>", range: start.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[start.lowerBound..<end.lowerBound])
    }
}
