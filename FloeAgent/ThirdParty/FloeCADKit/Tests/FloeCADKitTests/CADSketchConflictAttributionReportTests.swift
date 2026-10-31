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
//  The second half drives the SAME debug fixtures the native M02/M06 UI tests
//  launch, through the production `EditorViewModel` label path. A badge must
//  name the SAVED driving value of a blamed conflicting dimension (the best
//  fit is never written back, so geometry cannot name it), while unblamed
//  saved readouts and unsaved live selections keep their measured source.
//

import Foundation
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

#if DEBUG
// The fixtures are DEBUG-only, exactly like the native workbench host. These
// tests use the SAME `CADDebugFixtures` factory the UI launch arguments use,
// so a seed that stops being genuinely supported fails here before another
// Simulator UI round.
@MainActor
final class CADSketchFixtureAndLabelContractTests: XCTestCase {
    private var documents: [FloeCADDocument] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        for document in documents { document.close() }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        documents = []
        directories = []
    }

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADSketchLabel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("\(name).floecad"), name: name)
        documents.append(document)
        return document
    }

    private func seededSketch(_ scenario: CADDebugFixtures.Scenario,
                              named name: String,
                              in document: FloeCADDocument) throws -> Sketch {
        try CADDebugFixtures.seed(scenario, in: document)
        return try XCTUnwrap(document.session.document.sketches.first { $0.name == name },
                             "the fixture factory must produce a named \(name) sketch")
    }

    /// The M02 fixture's arc/spline entities as the shared `CurveLoopFixture`
    /// shape, so the independent closure/G1 measurement is the exact one the
    /// 26 solver tests already use. This reads the SEEDED entities; it does not
    /// rebuild or re-declare the geometry.
    private func loopFixture(from sketch: Sketch) -> CurveLoopFixture.Loop? {
        guard let arcEntity = sketch.entities.first(where: {
                  if case .arc = $0 { return true }
                  return false
              }),
              case let .arc(arcID, center, radius, startAngle, endAngle) = arcEntity,
              let splineEntity = sketch.entities.first(where: {
                  if case .spline = $0 { return true }
                  return false
              }),
              case let .spline(splineID, points, closed) = splineEntity,
              !closed, points.count == 3 else { return nil }
        return CurveLoopFixture.Loop(
            arc: arcEntity, spline: splineEntity, arcID: arcID, splineID: splineID,
            start: SketchEntity.arcPoint(center: center, radius: radius, angle: startAngle),
            end: SketchEntity.arcPoint(center: center, radius: radius, angle: endAngle),
            scale: 1)
    }

    private func assertWeldedTangentLoop(_ entities: [SketchEntity],
                                         loop: CurveLoopFixture.Loop,
                                         scale: Double,
                                         file: StaticString = #filePath,
                                         line: UInt = #line) throws {
        let m = try XCTUnwrap(CurveLoopFixture.measure(entities, loop: loop),
                              "the solved loop must still contain both fixture entities",
                              file: file, line: line)
        XCTAssertLessThan(m.junctionGapStart, 1e-9,
                          "scale \(scale): the start junction split", file: file, line: line)
        XCTAssertLessThan(m.junctionGapEnd, 1e-9,
                          "scale \(scale): the end junction split", file: file, line: line)
        XCTAssertLessThan(m.onCircleStart, 1e-6,
                          "scale \(scale): the start left the arc", file: file, line: line)
        XCTAssertLessThan(m.onCircleEnd, 1e-6,
                          "scale \(scale): the end left the arc", file: file, line: line)
        XCTAssertLessThan(m.tangentDeviationStart, 1e-4,
                          "scale \(scale): the start junction is not G1",
                          file: file, line: line)
        XCTAssertLessThan(m.tangentDeviationEnd, 1e-4,
                          "scale \(scale): the end junction is not G1",
                          file: file, line: line)
    }

    // MARK: - M02 fixture sanity (the exact factory the UI launches)

    /// The native M02 host seeds this scenario and the status chip then says
    /// "2 relations not applied" instead of "2 DOF remaining". The two welded
    /// coincidences are enforced exactly by variable identity, so the report
    /// must not count them as dropped just because they lower to no residual
    /// row. This is the same factory, the real solver report, and the same
    /// independent closure/G1 measurement as `CADCurveConstraintSolvingTests`.
    func testSeededClosedArcSplineLoopIsActuallySupportedAndReportsTwoDOF() async throws {
        let document = try await makeDocument("Spline loop")
        let saved = try seededSketch(.closedArcSplineLoop, named: "Spline loop", in: document)

        XCTAssertEqual(saved.entities.count, 2,
                       "the fixture must contain exactly the arc and the open spline")
        XCTAssertEqual(saved.constraints.count, 5,
                       "two coincidences, two junction tangencies and the centre Lock")
        XCTAssertEqual(saved.dimensions.count, 1,
                       "the healthy loop has exactly one driving radius")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "the seeded dependent Extrude evaluated with errors")

        let report = SketchSolverBridge.definitionReport(saved)
        XCTAssertTrue(report.unsupportedRelationIDs.isEmpty,
                      "every saved loop relation is applied; welded coincidences are exact: \(report.unsupportedRelationIDs)")
        XCTAssertFalse(report.conflicting,
                       "a healthy welded/tangent loop must not report a conflict")
        XCTAssertTrue(report.converged, "the seeded loop must solve")
        XCTAssertEqual(report.dof, 2,
                       "radius + welds + on-circle + G1 leave two real tangent-configuration DOF")
        XCTAssertFalse(report.isFullyDefined,
                       "two remaining DOF is not fully defined")

        let loop = try XCTUnwrap(loopFixture(from: saved),
                                 "the seeded sketch must expose its arc + 3-point open spline")
        let outcome = SketchSolverBridge.solveOutcome(saved, movingEntity: nil, dragTarget: nil)
        XCTAssertTrue(outcome.converged)
        XCTAssertLessThanOrEqual(outcome.structuralResidual,
                                 SketchSolverBridge.overConstraintTolerance)
        XCTAssertEqual(outcome.dof, 2)
        try assertWeldedTangentLoop(outcome.entities, loop: loop, scale: 1)
        guard case let .arc(_, center, radius, _, _)? =
                outcome.entities.first(where: { $0.id == loop.arcID }) else {
            return XCTFail("the solved loop lost its arc")
        }
        XCTAssertEqual(radius, 25, accuracy: 1e-9)
        XCTAssertEqual(center.x, 60, accuracy: 1e-9)
        XCTAssertEqual(center.y, 0, accuracy: 1e-9)

        // The driven R25 -> R40 edit the on-canvas badge performs: the closure
        // and G1 tangency survive and the structural DOF stays two.
        var edited = saved
        edited.dimensions[0].value = 40
        let driven = SketchSolverBridge.solveDimensionEdit(
            edited, dimension: edited.dimensions[0])
        XCTAssertTrue(driven.converged, "the driven radius edit did not converge")
        XCTAssertLessThanOrEqual(driven.structuralResidual,
                                 SketchSolverBridge.overConstraintTolerance)
        XCTAssertEqual(driven.dof, 2, "the driven edit must not consume the tangent DOF")
        guard case let .arc(_, drivenCenter, drivenRadius, _, _)? =
                driven.entities.first(where: { $0.id == loop.arcID }) else {
            return XCTFail("the driven loop lost its arc")
        }
        XCTAssertEqual(drivenRadius, 40, accuracy: 1e-9)
        XCTAssertEqual(drivenCenter.x, 60, accuracy: 1e-9)
        XCTAssertEqual(drivenCenter.y, 0, accuracy: 1e-9)
        try assertWeldedTangentLoop(driven.entities, loop: loop, scale: 1)

        XCTAssertTrue(document.session.lastEvalErrors.isEmpty,
                      "the dependent Extrude must stay evaluable")
        XCTAssertTrue(document.session.document.features.nodes.contains {
            if case .extrude = $0.kind { return true }
            return false
        }, "the fixture must retain its real consuming Extrude")
        XCTAssertFalse(document.session.document.bodies.isEmpty,
                       "the consuming Extrude must still produce a body")
    }

    /// The M06 fixture is the same welded loop plus the contradictory pair and
    /// the unrelated line dimension. Its saved relations must all be applied
    /// and the report must blame EXACTLY the two radius dimensions.
    func testSeededConflictingLoopReportsOnlyTheTwoRadiusDimensions() async throws {
        let document = try await makeDocument("Spline conflict")
        let saved = try seededSketch(.conflictingArcSplineLoop, named: "Spline conflict",
                                     in: document)
        XCTAssertEqual(saved.constraints.count, 4,
                       "the contradictory loop keeps its two coincidences and two tangencies")
        XCTAssertEqual(saved.dimensions.count, 3,
                       "one clean line length plus the two contradictory radii")

        let report = SketchSolverBridge.definitionReport(saved)
        XCTAssertTrue(report.unsupportedRelationIDs.isEmpty,
                      "the conflicting fixture also uses the same supported loop relations")
        XCTAssertTrue(report.conflicting)
        let radiusIDs = Set(saved.dimensions.filter { $0.kind == .radius }.map(\.id))
        XCTAssertEqual(radiusIDs.count, 2)
        XCTAssertEqual(report.conflictAttribution.dimensionIDs, radiusIDs,
                       "exactly the two driving radius rows are blamed")
        XCTAssertTrue(report.conflictAttribution.constraintIDs.isEmpty,
                      "the welded/tangent loop relations are satisfied")
        XCTAssertFalse(report.isFullyDefined)
    }

    // MARK: - M06 badge values (production EditorViewModel label path)

    /// A blamed driving dimension must keep its own stored value even though
    /// the committed geometry is the last accepted state. Before the fix both
    /// red badges read R25 because the label followed `measuredValue` while
    /// the 40 mm row is not — and must not be — written back as a compromise.
    func testConflictingDrivingDimensionsKeepTheirDistinctStoredLabels() async throws {
        let document = try await makeDocument("Spline conflict")
        let seeded = try seededSketch(.conflictingArcSplineLoop, named: "Spline conflict",
                                      in: document)
        let model = document.viewModel()
        model.mode = .sketching(seeded.id, tool: nil)
        // `selectItemSketch` selects every entity of the opened sketch; mirror
        // that so the saved badges are visible on any preference state.
        model.selectedSketchEntityIDs = Set(seeded.entities.map(\.id))
        XCTAssertEqual(model.activeSketch?.id, seeded.id)

        // Drive the production status chip's own read. The first read only
        // schedules the real detached definition report; the publication then
        // sets attribution and the epoch the chip observes.
        _ = model.sketchDefinitionReport(for: seeded)
        await model.settleSketchDefinition()

        let status = try XCTUnwrap(model.sketchDefinitionStatus)
        XCTAssertTrue(status.conflicting)
        XCTAssertEqual(status.unsupportedCount, 0,
                       "the M02/M06 fixture's welded coincidences are applied, not dropped")
        let radiusDimensions = seeded.dimensions.filter { $0.kind == .radius }
        XCTAssertEqual(radiusDimensions.count, 2)
        let radiusValues = Dictionary(uniqueKeysWithValues: radiusDimensions
            .map { ($0.id, $0.value) })
        XCTAssertEqual(Set(radiusValues.values), Set([25, 40]))
        XCTAssertEqual(model.sketchConflictAttribution.dimensionIDs, Set(radiusValues.keys),
                       "both real driving radius rows are the published blame")

        // The diagnosis is read-only: the invalid best fit is never committed.
        let afterDiagnosis = try XCTUnwrap(
            document.session.document.sketches.first { $0.id == seeded.id })
        XCTAssertEqual(afterDiagnosis, seeded,
                       "publishing the report must not write the best fit into the document")
        guard case let .arc(_, center, radius, _, _)? =
                afterDiagnosis.entities.first(where: {
                    if case .arc = $0 { return true }
                    return false
                }) else {
            return XCTFail("the seeded arc disappeared")
        }
        XCTAssertEqual(radius, 25, accuracy: 1e-12,
                       "the committed geometry still says R25; only the labels must differ")
        XCTAssertEqual(center.x, 60, accuracy: 1e-12)
        XCTAssertEqual(center.y, 0, accuracy: 1e-12)

        let labels = model.sketchDimensionLabels
        var byDimension: [UUID: EditorViewModel.SketchDimensionLabel] = [:]
        for label in labels {
            guard let id = label.dimensionID, byDimension[id] == nil else { continue }
            byDimension[id] = label
        }
        let unit = CADPreferences.shared.unit
        for (dimensionID, storedValue) in radiusValues {
            let label = try XCTUnwrap(byDimension[dimensionID],
                                      "each saved radius row must have one badge")
            XCTAssertEqual(label.valueSource, .driving,
                           "a blamed driving dimension publishes its stored value")
            XCTAssertEqual(label.displayValue, storedValue, accuracy: 1e-12,
                           "dimension \(dimensionID) must keep its own saved \(storedValue) mm")
            XCTAssertEqual(label.text,
                           LiveDimensionKit.Kind.radius.prefix
                               + unit.compactLengthString(fromMM: storedValue),
                           "the badge text must use the production radius formatter, not a clone")
        }
        let first = try XCTUnwrap(byDimension[radiusDimensions[0].id])
        let second = try XCTUnwrap(byDimension[radiusDimensions[1].id])
        XCTAssertNotEqual(first.text, second.text,
                          "the two contradictory driving values must stay distinct on screen")

        // The unrelated, exactly satisfied line dimension is a normal badge and
        // is never part of the blame.
        let cleanID = try XCTUnwrap(seeded.dimensions.first { $0.kind == .distance }?.id)
        let clean = try XCTUnwrap(byDimension[cleanID])
        XCTAssertEqual(clean.valueSource, .driving)
        XCTAssertEqual(clean.displayValue, 60, accuracy: 1e-12)
        XCTAssertEqual(clean.text, unit.compactLengthString(fromMM: 60))
        XCTAssertFalse(model.sketchConflictAttribution.dimensionIDs.contains(cleanID))
    }

    /// The two non-driving value sources stay distinct from the driving one:
    /// a saved row outside the current blame keeps the measured reference
    /// readout of the committed geometry, and an unsaved live selection is a
    /// preview. Neither may ever be relabelled as a driving value.
    func testUnblamedSavedRowKeepsItsReferenceReadoutAndLiveSelectionIsAPreview() async throws {
        let document = try await makeDocument("Reference")
        let lineID = UUID()
        let line = SketchEntity.line(id: lineID, a: SIMD2(0, 0), b: SIMD2(40, 0))
        let dimension = SketchDimension(
            kind: .distance,
            refs: [ConstraintRef(entityID: lineID, role: .endpointA),
                   ConstraintRef(entityID: lineID, role: .endpointB)],
            value: 60)
        let sketchID = SketchID()
        document.session.perform(AddSketchCommand(
            sketch: Sketch(id: sketchID, name: "Reference", plane: .ground,
                           entities: [line], dimensions: [dimension])))
        let model = document.viewModel()
        model.mode = .sketching(sketchID, tool: nil)
        model.selectedSketchEntityIDs = [lineID]
        XCTAssertTrue(model.sketchConflictAttribution.isEmpty,
                      "no report has blamed this saved row")

        let unit = CADPreferences.shared.unit
        let reference = try XCTUnwrap(
            model.sketchDimensionLabels.first { $0.dimensionID == dimension.id })
        XCTAssertEqual(reference.valueSource, .reference,
                       "an unblamed saved row reads the committed geometry")
        XCTAssertEqual(reference.displayValue, 40, accuracy: 1e-12,
                       "the reference value is the actual committed length, not the stored 60")
        XCTAssertEqual(reference.text, unit.compactLengthString(fromMM: 40))

        let secondLineID = UUID()
        document.session.perform(AddSketchEntitiesCommand(
            sketchID: sketchID,
            entities: [.line(id: secondLineID, a: SIMD2(0, 10), b: SIMD2(30, 10))]))
        model.selectedSketchEntityIDs = [secondLineID]
        let preview = try XCTUnwrap(
            model.sketchDimensionLabels.first { $0.dimensionID == nil },
            "selecting an undimensioned line must offer the live candidate badge")
        XCTAssertEqual(preview.valueSource, .preview,
                       "an unsaved selection measurement is a live preview")
        XCTAssertEqual(preview.displayValue, 30, accuracy: 1e-12)
        XCTAssertEqual(preview.text, unit.compactLengthString(fromMM: 30))
    }
}
#endif
