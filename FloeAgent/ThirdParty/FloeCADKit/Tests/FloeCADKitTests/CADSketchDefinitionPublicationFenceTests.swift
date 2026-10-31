//
//  CADSketchDefinitionPublicationFenceTests.swift
//  FloeCADKitTests
//
//  R2 publication fence for the M06 diagnosis: the definition solve runs
//  detached and may land after the same sketch row already carries a newer
//  constraint/dimension/geometry snapshot, or in the middle of a real drag
//  conflict. These tests drive the production EditorViewModel and the real
//  SketchSolverBridge.DefinitionReport; the injected solver only gates WHEN the
//  actual report is delivered. No mock verdict decides an outcome.
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

private enum DefinitionFenceWaitError: Error {
    case solveDidNotLand
}

/// Blocks the detached definition solve at a deterministic checkpoint so the
/// test can make the document/gesture state change first. It does not change
/// the report: after release the closure still calls the production
/// `SketchSolverBridge.definitionReport`.
private final class DefinitionDeliveryGate: @unchecked Sendable {
    private let condition = NSCondition()
    private let heldSketch: Sketch
    private var started = false
    private var released = false

    init(holding sketch: Sketch) {
        heldSketch = sketch
    }

    func solve(_ sketch: Sketch) -> SketchSolverBridge.DefinitionReport {
        if sketch == heldSketch {
            condition.lock()
            started = true
            condition.broadcast()
            while !released {
                condition.wait()
            }
            condition.unlock()
        }
        return SketchSolverBridge.definitionReport(sketch)
    }

    /// Checkpoint: the real delivery is now parked and can be released at a
    /// known point, rather than sleeping and hoping it has already run.
    func waitUntilStarted() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 10)
        while !started {
            if !condition.wait(until: deadline) { return false }
        }
        return true
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
final class CADSketchDefinitionPublicationFenceTests: XCTestCase {
    private var documents: [FloeCADDocument] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        for document in documents { document.close() }
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        documents = []
        directories = []
    }

    // MARK: - Real same-id snapshots

    private struct Snapshots {
        var conflictingPrimary: Sketch
        var conflictingAlternate: Sketch
        var resolved: Sketch
        var entityID: UUID
    }

    private func makeSnapshots() -> Snapshots {
        let id = SketchID()
        let entityID = UUID()
        func make(radius: Double, center: SIMD2<Double>, radii: [Double]) -> Sketch {
            let dimensions = radii.map { value in
                SketchDimension(kind: .radius,
                                refs: [ConstraintRef(entityID: entityID, role: .whole)],
                                value: value)
            }
            return Sketch(id: id, name: "Publication fence", plane: .ground,
                          entities: [.circle(id: entityID, center: center, radius: radius)],
                          dimensions: dimensions)
        }
        return Snapshots(
            conflictingPrimary: make(radius: 25, center: SIMD2(60, 0), radii: [25, 40]),
            conflictingAlternate: make(radius: 15, center: SIMD2(80, -5), radii: [15, 55]),
            resolved: make(radius: 30, center: SIMD2(70, 5), radii: [30]),
            entityID: entityID)
    }

    private func makeDocument(with sketch: Sketch) async throws
        -> (document: FloeCADDocument, model: EditorViewModel) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADDefinitionPublication-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("Publication.floecad"),
            name: "Publication")
        documents.append(document)
        document.session.perform(AddSketchCommand(sketch: sketch))
        let model = document.viewModel()
        model.mode = .sketching(sketch.id, tool: nil)
        XCTAssertTrue(model.activeSketch == sketch)
        return (document, model)
    }

    /// Replace the current row's value without changing its id: exactly the
    /// "new constraints/dimensions/geometry while the old solve is detached"
    /// state the fence must reject.
    private func install(_ sketch: Sketch, in document: FloeCADDocument) {
        var installed = false
        document.session.preview { document in
            guard let index = document.sketches.firstIndex(where: { $0.id == sketch.id })
            else { return }
            document.sketches[index] = sketch
            installed = true
        }
        XCTAssertTrue(installed, "the same-id sketch row must still exist")
    }

    private func waitForDefinitionEpoch(
        _ model: EditorViewModel, greaterThan previous: Int
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while model.sketchDefinitionEpoch <= previous {
            guard ContinuousClock.now < deadline else {
                throw DefinitionFenceWaitError.solveDidNotLand
            }
            await Task.yield()
        }
    }

    /// A plane-normal ray aimed at a sketch-plane point, used to drive the
    /// production stroke/gesture entry exactly as the viewport does.
    private func ray(at point: SIMD2<Double>, in plane: SketchPlane) -> Ray {
        let world = plane.toWorld(point)
        let normal = plane.normal
        let origin = world + normal * 10
        return Ray(
            origin: SIMD3<Float>(Float(origin.x), Float(origin.y), Float(origin.z)),
            direction: SIMD3<Float>(Float(-normal.x), Float(-normal.y), Float(-normal.z)))
    }

    private func center(of sketch: Sketch) -> SIMD2<Double> {
        guard case let .circle(_, center, _)? = sketch.entities.first else {
            fatalError("fixture must contain the circle entity")
        }
        return center
    }

    // MARK: - Ordering tests

    func testResolvedReportForDifferentSameIDSnapshotCannotClearCurrentAttribution() async throws {
        let snapshots = makeSnapshots()
        let (document, model) = try await makeDocument(with: snapshots.conflictingPrimary)

        let primaryReport = SketchSolverBridge.definitionReport(snapshots.conflictingPrimary)
        XCTAssertTrue(primaryReport.conflicting)
        let primaryAttribution = primaryReport.conflictAttribution
        XCTAssertFalse(primaryAttribution.isEmpty)

        model.sketchDefinitionReport(for: snapshots.conflictingPrimary)
        try await waitForDefinitionEpoch(model, greaterThan: 0)
        XCTAssertEqual(model.sketchConflictAttribution, primaryAttribution)

        // Park a resolved report for a DIFFERENT snapshot of the SAME row.
        let gate = DefinitionDeliveryGate(holding: snapshots.resolved)
        defer { gate.release() }
        model.definitionSolver = { gate.solve($0) }
        model.sketchDefinitionReport(for: snapshots.resolved)
        guard gate.waitUntilStarted() else {
            XCTFail("the real detached solve must reach its delivery checkpoint")
            return
        }

        XCTAssertTrue(model.activeSketch == snapshots.conflictingPrimary)
        gate.release()
        try await waitForDefinitionEpoch(model, greaterThan: 1)
        XCTAssertEqual(model.sketchConflictAttribution, primaryAttribution,
                       "a resolved report for another same-id snapshot must not clear current blame")

        // A fresh report for the newly current snapshot still publishes.
        let alternateReport = SketchSolverBridge.definitionReport(snapshots.conflictingAlternate)
        XCTAssertTrue(alternateReport.conflicting)
        XCTAssertNotEqual(alternateReport.conflictAttribution, primaryAttribution)
        install(snapshots.conflictingAlternate, in: document)
        XCTAssertTrue(model.activeSketch == snapshots.conflictingAlternate)
        model.sketchDefinitionReport(for: snapshots.conflictingAlternate)
        try await waitForDefinitionEpoch(model, greaterThan: 2)
        XCTAssertEqual(model.sketchConflictAttribution, alternateReport.conflictAttribution,
                       "the fresh current report must still publish its own ids")
    }

    func testConflictingReportForDifferentSameIDSnapshotCannotPublishStaleAttribution() async throws {
        let snapshots = makeSnapshots()
        let (_, model) = try await makeDocument(with: snapshots.resolved)

        let resolvedReport = SketchSolverBridge.definitionReport(snapshots.resolved)
        XCTAssertFalse(resolvedReport.conflicting)
        XCTAssertTrue(resolvedReport.conflictAttribution.isEmpty)

        let staleReport = SketchSolverBridge.definitionReport(snapshots.conflictingPrimary)
        XCTAssertTrue(staleReport.conflicting)
        XCTAssertFalse(staleReport.conflictAttribution.isEmpty)

        let gateOld = DefinitionDeliveryGate(holding: snapshots.conflictingPrimary)
        let gateCurrent = DefinitionDeliveryGate(holding: snapshots.resolved)
        defer {
            gateOld.release()
            gateCurrent.release()
        }
        let old = snapshots.conflictingPrimary
        let current = snapshots.resolved
        model.definitionSolver = { sketch in
            if sketch == old { return gateOld.solve(sketch) }
            if sketch == current { return gateCurrent.solve(sketch) }
            return SketchSolverBridge.definitionReport(sketch)
        }

        model.sketchDefinitionReport(for: snapshots.conflictingPrimary)
        guard gateOld.waitUntilStarted() else {
            XCTFail("the real detached solve must reach its delivery checkpoint")
            return
        }
        XCTAssertTrue(model.activeSketch == snapshots.resolved)

        // Queue the current snapshot while the old report is still detached.
        model.sketchDefinitionReport(for: snapshots.resolved)
        gateOld.release()
        try await waitForDefinitionEpoch(model, greaterThan: 0)
        guard gateCurrent.waitUntilStarted() else {
            XCTFail("the real detached solve must reach its delivery checkpoint")
            return
        }

        XCTAssertEqual(model.sketchConflictAttribution, SketchSolverBridge.ConflictAttribution(),
                       "the old conflicting report must not paint its ids on the current resolved sketch")

        gateCurrent.release()
        try await waitForDefinitionEpoch(model, greaterThan: 1)
        XCTAssertEqual(model.sketchConflictAttribution, SketchSolverBridge.ConflictAttribution())
        XCTAssertEqual(model.sketchDefinitionStatus?.conflicting, false)
    }

    func testInFlightReportCannotOverwriteOngoingDragConflictBlame() async throws {
        let snapshots = makeSnapshots()
        let (_, model) = try await makeDocument(with: snapshots.conflictingPrimary)

        let currentReport = SketchSolverBridge.definitionReport(snapshots.conflictingPrimary)
        XCTAssertTrue(currentReport.conflicting)
        let dragAttribution = currentReport.conflictAttribution
        XCTAssertFalse(dragAttribution.isEmpty)

        model.sketchDefinitionReport(for: snapshots.conflictingPrimary)
        try await waitForDefinitionEpoch(model, greaterThan: 0)
        XCTAssertEqual(model.sketchConflictAttribution, dragAttribution)

        // Old conflicting snapshot of the same row, parked while the user drags.
        let gate = DefinitionDeliveryGate(holding: snapshots.conflictingAlternate)
        defer { gate.release() }
        model.definitionSolver = { gate.solve($0) }
        model.sketchDefinitionReport(for: snapshots.conflictingAlternate)
        guard gate.waitUntilStarted() else {
            XCTFail("the real detached solve must reach its delivery checkpoint")
            return
        }

        let staleReport = SketchSolverBridge.definitionReport(snapshots.conflictingAlternate)
        XCTAssertTrue(staleReport.conflicting)
        XCTAssertNotEqual(staleReport.conflictAttribution, dragAttribution)

        let start = center(of: snapshots.conflictingPrimary)
        let target = start + SIMD2(3, 0)
        XCTAssertGreaterThan(
            SketchSolverBridge.solveOutcome(
                snapshots.conflictingPrimary,
                movingEntity: snapshots.entityID,
                dragTarget: target).structuralResidual,
            SketchSolverBridge.overConstraintTolerance,
            "the fixture's saved system is genuinely contradictory")

        guard model.beginSketchStroke(ray: ray(at: start, in: .ground)) else {
            XCTFail("the real stroke entry must acquire the circle center")
            return
        }
        model.updateSketchStroke(ray: ray(at: target, in: .ground),
                                 gestureID: model.currentSketchDragGestureID)
        XCTAssertTrue(model.sketchSolveConflict)
        XCTAssertEqual(model.sketchConflictAttribution, dragAttribution)

        gate.release()
        try await waitForDefinitionEpoch(model, greaterThan: 1)
        XCTAssertTrue(model.sketchSolveConflict)
        XCTAssertEqual(model.sketchConflictAttribution, dragAttribution,
                       "an older report must not overwrite the ongoing drag episode's blame")
    }

    func testOngoingDragConflictIsNotClearedByExactCurrentResolvedReport() async throws {
        let snapshots = makeSnapshots()
        let (document, model) = try await makeDocument(with: snapshots.conflictingPrimary)

        let conflictReport = SketchSolverBridge.definitionReport(snapshots.conflictingPrimary)
        XCTAssertTrue(conflictReport.conflicting)
        let dragAttribution = conflictReport.conflictAttribution
        XCTAssertFalse(dragAttribution.isEmpty)
        model.sketchDefinitionReport(for: snapshots.conflictingPrimary)
        try await waitForDefinitionEpoch(model, greaterThan: 0)
        XCTAssertEqual(model.sketchConflictAttribution, dragAttribution)

        // Start the real drag episode: the drag path owns the blame.
        let start = center(of: snapshots.conflictingPrimary)
        let target = start + SIMD2(3, 0)
        guard model.beginSketchStroke(ray: ray(at: start, in: .ground)) else {
            XCTFail("the real stroke entry must acquire the circle center")
            return
        }
        model.updateSketchStroke(ray: ray(at: target, in: .ground),
                                 gestureID: model.currentSketchDragGestureID)
        XCTAssertTrue(model.sketchSolveConflict)
        XCTAssertEqual(model.sketchConflictAttribution, dragAttribution)

        // A dimension edit resolves the current row while the gesture is still
        // open. The exact-current resolved report must not clear the drag blame.
        install(snapshots.resolved, in: document)
        XCTAssertTrue(model.activeSketch == snapshots.resolved)
        let resolvedReport = SketchSolverBridge.definitionReport(snapshots.resolved)
        XCTAssertFalse(resolvedReport.conflicting)
        model.sketchDefinitionReport(for: snapshots.resolved)
        try await waitForDefinitionEpoch(model, greaterThan: 1)
        XCTAssertTrue(model.sketchSolveConflict)
        XCTAssertEqual(model.sketchConflictAttribution, dragAttribution,
                       "the drag episode stays authoritative until its own path clears it")
    }
}
