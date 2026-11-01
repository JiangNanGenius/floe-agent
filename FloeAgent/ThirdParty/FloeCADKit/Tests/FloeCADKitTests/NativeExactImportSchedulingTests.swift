//
//  NativeExactImportSchedulingTests.swift
//  FloeCADKitTests
//
//  E31-R2 kernel qualification for the exact (STEP/IGES) import scheduler:
//
//    * the REAL reader + tessellator runs off the MainActor and returns an
//      immutable plan whose exact shapes are restored as INDEPENDENT handles
//      when applied (the plan contains no live/aliased BRepHandle);
//    * IGES solid/surface classification and the truthful payload survive the
//      scheduling split;
//    * a budget refusal happens before any body is built, and a cancellation
//      between prepared bodies leaves zero bodies (no half model);
//    * concurrent exact parses are serialized (the OCCT reader/controller is
//      process-global), and the peak concurrency is measured.
//
//  These tests run the production parser and commit path. They do not stub the
//  reader, the tessellator or the document commands.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation
import XCTest
import simd
@testable import FloeCAD

#if DEBUG
@MainActor
final class NativeExactImportSchedulingTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeExactScheduling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        CADExactImportService.testCheckpoint = nil
        CADExactImportService.testResetPeakConcurrentParsers()
        MeshImportKit.testImportBodyCheckpoint = nil
    }

    override func tearDown() async throws {
        CADExactImportService.testCheckpoint = nil
        MeshImportKit.testImportBodyCheckpoint = nil
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    // MARK: - Real fixtures

    private func boxHandle(_ size: Double = 20) throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: size, depth: size, height: size), placement: .identity),
            "the kernel must build the real box fixture")
    }

    private func twoSolidSTEP() throws -> Data {
        let first = try boxHandle(20)
        let second = try boxHandle(10)
        var moved = Transform3D.identity
        moved.translation = SIMD3<Double>(40, 0, 0)
        let placed = try XCTUnwrap(OCCTKernel.transformed(second, by: moved))
        let url = workDir.appendingPathComponent("two-solids-\(UUID().uuidString).step")
        XCTAssertTrue(OCCTKernel.writeSTEP([first, placed], to: url),
                      "the real STEP writer must produce the fixture")
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0)
        return data
    }

    private func oneSolidSTEP() throws -> Data {
        let box = try boxHandle(20)
        let url = workDir.appendingPathComponent("one-solid-\(UUID().uuidString).step")
        XCTAssertTrue(OCCTKernel.writeSTEP([box], to: url))
        return try Data(contentsOf: url)
    }

    private func solidIGES() throws -> Data {
        let box = try boxHandle(20)
        let url = workDir.appendingPathComponent("solid-\(UUID().uuidString).igs")
        XCTAssertTrue(OCCTKernel.debugWriteIGES([box], to: url, brepMode: true),
                      "OCCT's IGES writer must produce the solid fixture")
        return try Data(contentsOf: url)
    }

    private func surfaceIGES() throws -> Data {
        let box = try boxHandle(20)
        let url = workDir.appendingPathComponent("surfaces-\(UUID().uuidString).igs")
        XCTAssertTrue(OCCTKernel.debugWriteIGES([box], to: url, brepMode: false),
                      "OCCT's IGES writer must produce the surface fixture")
        return try Data(contentsOf: url)
    }

    private func makeDocument(_ name: String) async throws -> FloeCADDocument {
        try await FloeCADDocument.create(
            at: workDir.appendingPathComponent("\(name)-\(UUID().uuidString).floecad"),
            name: name)
    }

    private func object(_ outcome: CADCommandOutcome) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: outcome.payload)) as? [String: Any] ?? [:]
    }

    // MARK: - Off-main plan + independent exact bodies

    func testSTEPParseIsOffMainAndPlanRestoresIndependentExactBodies() async throws {
        let step = try twoSolidSTEP()
        let source = step
        let token = MeshImportCancellation()
        let plan = try await CADExactImportService.parseOffMain(
            data: step, format: "step", fileName: "two-solids.step",
            limits: .standard, cancellation: token)

        XCTAssertTrue(plan.parsedOffMain, "the real STEP read/tessellation must run off the MainActor")
        XCTAssertEqual(plan.solidCount, 2)
        XCTAssertEqual(plan.surfaceCount, 0)
        XCTAssertGreaterThan(plan.triangleCount, 0)
        XCTAssertGreaterThan(plan.retainedBytes, 0)
        XCTAssertEqual(step, source, "the source bytes must be unchanged")

        let first = try await makeDocument("First")
        defer { if !first.isClosed { first.close() } }
        let firstApplication = try CADExactImportService.apply(
            plan, to: first, cancellation: token, undoMode: .singleStep)
        XCTAssertTrue(firstApplication.outcome.isOK, firstApplication.outcome.message ?? "")
        XCTAssertEqual(first.summary().bodyCount, 2)
        XCTAssertEqual(first.session.undoStack.undoCommands.count, 1,
                       "the whole exact import must be exactly one undo step")
        let firstHandles = first.session.document.bodies.compactMap(\.brep)
        XCTAssertEqual(firstHandles.count, 2)
        let volumes = firstHandles.map { OCCTKernel.volume($0) }.sorted()
        XCTAssertEqual(volumes[0], 1_000.0, accuracy: 1e-6,
                       "the real exact volumes must survive the plan")
        XCTAssertEqual(volumes[1], 8_000.0, accuracy: 1e-6)

        // A second document restores NEW handles from the same immutable plan;
        // the plan never hands out a live/aliased handle.
        let second = try await makeDocument("Second")
        defer { if !second.isClosed { second.close() } }
        let secondApplication = try CADExactImportService.apply(
            plan, to: second, cancellation: token, undoMode: .singleStep)
        XCTAssertTrue(secondApplication.outcome.isOK)
        let secondHandles = second.session.document.bodies.compactMap(\.brep)
        XCTAssertEqual(secondHandles.count, 2)
        for handle in firstHandles {
            for other in secondHandles {
                XCTAssertFalse(handle === other,
                               "each apply must deserialize its own exact handle")
            }
        }

        first.session.undo()
        XCTAssertEqual(first.summary().bodyCount, 0, "undo must remove the whole import")
        first.session.redo()
        XCTAssertEqual(first.summary().bodyCount, 2)
    }

    func testIGESParseKeepsSolidAndSurfaceClassificationAcrossScheduling() async throws {
        let solidData = try solidIGES()
        let surfaceData = try surfaceIGES()

        let solidPlan = try await CADExactImportService.parseOffMain(
            data: solidData, format: "iges", fileName: "solid.igs",
            limits: .standard, cancellation: MeshImportCancellation())
        XCTAssertTrue(solidPlan.parsedOffMain)
        XCTAssertEqual(solidPlan.solidCount, 1)
        XCTAssertEqual(solidPlan.surfaceCount, 0)

        let surfacePlan = try await CADExactImportService.parseOffMain(
            data: surfaceData, format: "iges", fileName: "surfaces.igs",
            limits: .standard, cancellation: MeshImportCancellation())
        XCTAssertEqual(surfacePlan.solidCount, 0)
        XCTAssertGreaterThanOrEqual(surfacePlan.surfaceCount, 1)

        let document = try await makeDocument("IGES")
        defer { if !document.isClosed { document.close() } }
        let solidApplication = try CADExactImportService.apply(
            solidPlan, to: document, undoMode: .singleStep)
        let solidObject = object(solidApplication.outcome)
        XCTAssertEqual(solidObject["solidsImported"] as? Int, 1)
        XCTAssertEqual(solidObject["surfacesImported"] as? Int, 0)
        let solidBody = try XCTUnwrap(document.session.document.bodies.last)
        XCTAssertNotNil(solidBody.brep)
        XCTAssertNil(solidBody.surfaceBRep)

        let surfaceApplication = try CADExactImportService.apply(
            surfacePlan, to: document, undoMode: .singleStep)
        let surfaceObject = object(surfaceApplication.outcome)
        XCTAssertEqual(surfaceObject["solidsImported"] as? Int, 0)
        XCTAssertGreaterThanOrEqual(surfaceObject["surfacesImported"] as? Int ?? 0, 1)
        XCTAssertEqual(surfaceObject["openSurfaceBodies"] as? Int,
                       surfaceObject["surfacesImported"] as? Int)
        let surfaceRows = try XCTUnwrap(surfaceObject["imported"] as? [[String: Any]])
        XCTAssertTrue(surfaceRows.allSatisfy { $0["kind"] as? String == "surface" })
        XCTAssertTrue(surfaceRows.allSatisfy { $0["analyticBRep"] as? Bool == false })
        for body in document.session.document.bodies {
            if body.brep == nil {
                XCTAssertNotNil(body.surfaceBRep, "an IGES surface must keep its exact handle")
            }
        }
        XCTAssertEqual(document.session.undoStack.undoCommands.count, 2,
                       "each applied exact import is one undo step")
    }

    // MARK: - Budget refusal

    func testExactParseRefusesOverBudgetBeforeApply() async throws {
        let step = try oneSolidSTEP()
        let document = try await makeDocument("Budget")
        defer { if !document.isClosed { document.close() } }
        let tight = MeshImportLimits(maximumTriangles: 1,
                                     maximumParts: 4_096,
                                     maximumExpandedBytes: 256 * 1024 * 1024,
                                     maximumArchiveEntries: 5_000)
        do {
            _ = try await CADExactImportService.parseOffMain(
                data: step, format: "step", fileName: "over-budget.step",
                limits: tight, cancellation: MeshImportCancellation())
            XCTFail("a 1-triangle budget must refuse a real box")
        } catch let error as CADDocumentError {
            XCTAssertEqual(error.code, "import_over_budget", error.message)
        }
        XCTAssertEqual(document.summary().bodyCount, 0)
        XCTAssertFalse(document.session.undoStack.canUndo)
        XCTAssertFalse(step.isEmpty, "the fixture input must remain readable")
    }

    // MARK: - Cancellation / no half model

    func testCancelBetweenPreparedBodiesLeavesNoHalfModel() async throws {
        let step = try twoSolidSTEP()
        let document = try await makeDocument("Cancel")
        defer { if !document.isClosed { document.close() } }
        let token = MeshImportCancellation()
        let gate = ExactGate(holdPhase: "body", atBody: 1)
        CADExactImportService.testCheckpoint = { checkpoint in
            gate.checkpoint(checkpoint)
        }
        defer { CADExactImportService.testCheckpoint = nil }

        let task = Task { @MainActor () -> Result<CADExactImportApplication, Error>? in
            do {
                let plan = try await CADExactImportService.parseOffMain(
                    data: step, format: "step", fileName: "cancel.step",
                    limits: .standard, cancellation: token)
                return .success(try CADExactImportService.apply(
                    plan, to: document, cancellation: token, undoMode: .singleStep))
            } catch {
                return .failure(error)
            }
        }
        await gate.waitEntered()
        XCTAssertTrue(gate.observedOffMain,
                      "the gated body preparation must have run off the MainActor")
        token.cancel()
        gate.releaseGate()
        let result = await task.value
        guard case .failure(let error)? = result else {
            return XCTFail("a cancelled exact parse must not produce an application")
        }
        XCTAssertEqual((error as? CADDocumentError)?.code ?? "", "cancelled", error.localizedDescription)
        XCTAssertEqual(document.summary().bodyCount, 0,
                       "a cancel after the first prepared body must not leave a half model")
        XCTAssertEqual(document.session.changeCount, 0)
        XCTAssertFalse(document.session.undoStack.canUndo)
    }

    func testExactParsesAreSerializedAndMeasured() async throws {
        let step = try oneSolidSTEP()
        CADExactImportService.testResetPeakConcurrentParsers()
        let gate = ExactGate(holdPhase: "locked", atBody: 0)
        CADExactImportService.testCheckpoint = { checkpoint in
            gate.checkpoint(checkpoint)
        }
        defer {
            gate.deactivate()
            gate.releaseGate()
            CADExactImportService.testCheckpoint = nil
        }

        let first = Task {
            try await CADExactImportService.parseOffMain(
                data: step, format: "step", fileName: "first.step",
                cancellation: MeshImportCancellation())
        }
        await gate.waitEntered()
        let second = Task {
            try await CADExactImportService.parseOffMain(
                data: step, format: "step", fileName: "second.step",
                cancellation: MeshImportCancellation())
        }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(gate.enteredCount, 1,
                       "only one exact parse may enter the OCCT reader section")
        gate.releaseGate()
        let firstPlan = try await first.value
        let secondPlan = try await second.value
        XCTAssertEqual(firstPlan.solidCount, 1)
        XCTAssertEqual(secondPlan.solidCount, 1)
        XCTAssertEqual(CADExactImportService.testPeakConcurrentParsers, 1,
                       "exact parses must be serialized: OCCT readers are process-global")
    }

}

/// A deterministic gate on the REAL exact-import checkpoint.
nonisolated private final class ExactGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let holdPhase: String
    private let holdBody: Int
    private var enteredTotal = 0
    private var offMain = false
    private var released = false
    private var active = true

    init(holdPhase: String, atBody: Int) {
        self.holdPhase = holdPhase
        self.holdBody = atBody
    }

    func checkpoint(_ checkpoint: CADExactImportCheckpoint) {
        guard checkpoint.phase == holdPhase,
              holdBody == 0 || checkpoint.bodyIndex == holdBody else { return }
        lock.lock()
        guard active else { lock.unlock(); return }
        enteredTotal += 1
        offMain = !checkpoint.ranOnMainThread
        let shouldHold = !released
        released = true
        lock.unlock()
        guard shouldHold else { return }
        entered.signal()
        _ = release.wait(timeout: .now() + 20)
    }

    func waitEntered() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = self.entered.wait(timeout: .now() + 20)
                continuation.resume()
            }
        }
    }

    func releaseGate() { release.signal() }

    func deactivate() {
        lock.lock()
        active = false
        lock.unlock()
    }

    var enteredCountValue: Int {
        lock.lock()
        defer { lock.unlock() }
        return enteredTotal
    }

    var enteredCount: Int { enteredCountValue }
    var observedOffMain: Bool {
        lock.lock()
        defer { lock.unlock() }
        return offMain
    }
}
#endif
