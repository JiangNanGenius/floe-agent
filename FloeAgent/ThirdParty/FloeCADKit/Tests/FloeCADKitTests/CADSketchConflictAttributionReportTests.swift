//
//  CADSketchConflictAttributionReportTests.swift
//  FloeCADKitTests
//
//  Contract between the M06 conflict diagnosis and the definition report that
//  now feeds the workbench's red relation overlays. The report's attribution
//  must be exactly the production `conflictAttribution` ids (and scale-
//  invariant), so the status chip and the highlighted badges cannot disagree
//  about WHICH saved relation failed.
//

import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADSketchConflictAttributionReportTests: XCTestCase {
    func testDefinitionReportPublishesTheSameRealRelationIDsAtThreeScales() {
        for scale in [1e-3, 1.0, 1e3] {
            let loop = CurveLoopFixture.make(scale: scale)
            let first = CurveLoopFixture.radiusDimension(loop, value: 25 * scale)
            let second = CurveLoopFixture.radiusDimension(loop, value: 40 * scale)
            let sketch = CurveLoopFixture.sketch(
                loop,
                constraints: CurveLoopFixture.loopConstraints(loop),
                dimensions: [first, second])

            let report = SketchSolverBridge.definitionReport(sketch)
            XCTAssertTrue(report.conflicting,
                          "scale \(scale): a contradictory driving pair must report conflicting")
            XCTAssertFalse(report.isFullyDefined,
                           "scale \(scale): a best fit must never be presented as satisfied")

            let direct = SketchSolverBridge.conflictAttribution(sketch)
            XCTAssertEqual(report.conflictAttribution, direct,
                           "scale \(scale): the report and the diagnosis must name the same rows")
            XCTAssertEqual(report.conflictAttribution.dimensionIDs,
                           Set([first.id, second.id]),
                           "scale \(scale): both real driving dimensions must be highlighted")
            XCTAssertTrue(report.conflictAttribution.constraintIDs.isEmpty,
                          "scale \(scale): satisfied loop relations must not be blamed")
        }
    }
}
