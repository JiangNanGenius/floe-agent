//
//  NativeCADImportCancellationTests.swift
//  FloeAppTests
//
//  E31-R3 App-level qualification for manual import ownership:
//
//    * a manual STEP/IGES import that was superseded by a newer manual import
//      cannot apply its late failure over the newer import's selection, error,
//      bodies, revision or undo stack (the stale callback is released after the
//      newer import has already succeeded);
//    * the same fence covers a returned mesh probe: a superseded probe failure
//      cannot clear the newer probe's state, and the newer probe still applies;
//    * a units prompt captured under an older import cannot commit bodies or
//      an error after a newer manual import ran (revision/undo/selection stay);
//    * closing/fencing the manual import invalidates the pending probe and its
//      units apply, while a NEW import after the fence works normally;
//    * a real failure of the ACTIVE manual import is still surfaced (the
//      ownership fence is not a blanket error swallow).
//
//  The parse/commit path is the production service and the document actor; the
//  only test seam delays delivery of an already-failed callback so the stale
//  ordering is deterministic instead of timing-dependent. Nothing stubs the
//  parser, the reader or a document command.
//
//  SPDX-License-Identifier: MPL-2.0
//

#if canImport(UIKit)
// The ownership ordering seam (`manualImportFailureDeliveryHook`) exists only
// in DEBUG builds, so this suite is DEBUG-only like the kernel suites.
#if DEBUG
import Foundation
import simd
import XCTest
@testable import FloeCAD
import FloeCore
import FloeTools
import FloeWorkbench
@testable import FloeApp

@MainActor
final class NativeCADImportCancellationTests: XCTestCase {
    private var workspace: URL!

    override func setUp() async throws {
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-import-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        CADExactImportService.testCheckpoint = nil
        MeshImportKit.testParseCheckpoint = nil
        MeshImportKit.testImportBodyCheckpoint = nil
    }

    override func tearDown() async throws {
        CADExactImportService.testCheckpoint = nil
        MeshImportKit.testParseCheckpoint = nil
        MeshImportKit.testImportBodyCheckpoint = nil
        let url = workspace?.appendingPathComponent("Part.floecad")
        if let url {
            for proposal in FloeCAD3DBridge.shared.pendingProposals(for: url) {
                FloeCAD3DBridge.shared.discard(proposalID: proposal.id)
            }
            await FloeCAD3DBridge.shared.releaseDocument(at: url)
        }
        if let workspace { try? FileManager.default.removeItem(at: workspace) }
    }

    // MARK: - Fixtures

    private var documentURL: URL { workspace.appendingPathComponent("Part.floecad") }

    private func makeTargetDocument() async throws {
        let document = try await FloeCADDocument.create(at: documentURL, name: "Part")
        document.close()
    }

    private func openDocument() async throws -> FloeCADDocument {
        try await FloeCAD3DBridge.shared.openDocument(at: documentURL)
    }

    private func boxHandle(_ size: Double) throws -> BRepHandle {
        try XCTUnwrap(OCCTKernel.primitiveShape(
            .box(width: size, depth: size, height: size), placement: .identity),
            "the kernel must build the real box fixture")
    }

    /// Two real exact solids in one STEP payload, written by the production
    /// writer (used as the superseded import).
    private func twoSolidSTEP() throws -> Data {
        let first = try boxHandle(20)
        let second = try boxHandle(10)
        var moved = Transform3D.identity
        moved.translation = SIMD3<Double>(40, 0, 0)
        let placed = try XCTUnwrap(OCCTKernel.transformed(second, by: moved))
        let url = workspace.appendingPathComponent("superseded-\(UUID().uuidString).step")
        XCTAssertTrue(OCCTKernel.writeSTEP([first, placed], to: url))
        return try Data(contentsOf: url)
    }

    /// One real exact solid in one STEP payload (the newer import).
    private func oneSolidSTEP() throws -> Data {
        let box = try boxHandle(20)
        let url = workspace.appendingPathComponent("newer-\(UUID().uuidString).step")
        XCTAssertTrue(OCCTKernel.writeSTEP([box], to: url))
        return try Data(contentsOf: url)
    }

    // MARK: - Superseded exact failure must not overwrite the newer import

    func testSupersededExactFailureCannotOverwriteTheNewerManualImport() async throws {
        try await makeTargetDocument()
        let supersededData = try twoSolidSTEP()
        let newerData = try oneSolidSTEP()
        let document = try await openDocument()
        let model = document.viewModel()
        let changesBefore = document.session.changeCount

        // Hold the superseded parse at its first prepared body (real parse),
        // cancel it, then hold its failure delivery until the newer import has
        // committed.
        let parseGate = ImportParseGate(holdPhase: "body", atBody: 1)
        CADExactImportService.testCheckpoint = { checkpoint in
            parseGate.checkpoint(checkpoint)
        }
        let delivery = FailureDeliveryHold(fileName: "superseded.step")
        model.manualImportFailureDeliveryHook = { _, fileName, stage in
            guard stage == .exact else { return }
            await delivery.hold(fileName: fileName)
        }
        defer {
            parseGate.releaseGate()
            delivery.releaseGate()
            CADExactImportService.testCheckpoint = nil
            model.manualImportFailureDeliveryHook = nil
        }

        let superseded = Task { @MainActor in
            await model.importExactOffMain(data: supersededData,
                                           fileName: "superseded.step",
                                           format: "step")
        }
        let enteredParse = await parseGate.waitEntered()
        XCTAssertTrue(enteredParse, "the superseded import must reach the real parse checkpoint")
        superseded.cancel()
        parseGate.releaseGate()
        let reachedDelivery = await delivery.waitEntered()
        XCTAssertTrue(reachedDelivery,
                      "the cancelled import must reach its (stale) failure delivery")

        // The newer import runs to completion while the old failure is held.
        let newerAccepted = await model.importExactOffMain(data: newerData,
                                                           fileName: "newer.step",
                                                           format: "step")
        XCTAssertTrue(newerAccepted, model.errorMessage ?? "the newer import must succeed")
        let bodyCountAfterNewer = document.summary().bodyCount
        let changesAfterNewer = document.session.changeCount
        let undoAfterNewer = document.session.undoStack.undoCommands.count
        let selectionAfterNewer = model.selection
        XCTAssertEqual(bodyCountAfterNewer, 1)
        XCTAssertEqual(undoAfterNewer, 1)
        XCTAssertEqual(changesAfterNewer, changesBefore + 1,
                       "the newer import must be exactly one document change")
        XCTAssertNil(model.errorMessage, "the newer import must leave no error")

        delivery.releaseGate()
        let supersededResult = await superseded.value
        XCTAssertFalse(supersededResult, "the superseded import must not report success")

        XCTAssertNil(model.errorMessage,
                     "a superseded import's failure must not overwrite the newer import's state")
        XCTAssertEqual(document.summary().bodyCount, bodyCountAfterNewer)
        XCTAssertEqual(document.session.changeCount, changesAfterNewer)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoAfterNewer)
        XCTAssertEqual(model.selection, selectionAfterNewer,
                       "the newer import's selection must survive the stale callback")
    }

    // MARK: - Superseded probe failure must not clear the newer probe

    func testSupersededProbeFailureCannotClearTheNewerProbe() async throws {
        try await makeTargetDocument()
        let document = try await openDocument()
        let model = document.viewModel()
        let malformed = Data("this is not a glb".utf8)
        let newerGLB = try gridGLB(triangles: 2_000)

        let delivery = FailureDeliveryHold(fileName: "superseded.glb")
        model.manualImportFailureDeliveryHook = { _, fileName, stage in
            guard stage == .meshProbe else { return }
            await delivery.hold(fileName: fileName)
        }
        defer {
            delivery.releaseGate()
            model.manualImportFailureDeliveryHook = nil
        }

        let superseded = Task { @MainActor in
            await model.probeMeshOffMain(data: malformed, fileName: "superseded.glb")
        }
        let reachedDelivery = await delivery.waitEntered()
        XCTAssertTrue(reachedDelivery,
                      "the superseded probe's real failure must reach the stale delivery")

        let newerProbeResult = await model.probeMeshOffMainWithOperation(
            data: newerGLB, fileName: "newer.glb")
        let prepared = try XCTUnwrap(newerProbeResult, "the newer probe must parse")
        XCTAssertTrue(model.isCurrentManualImport(prepared.operation))
        XCTAssertNil(model.errorMessage)

        delivery.releaseGate()
        let supersededProbe = await superseded.value
        XCTAssertNil(supersededProbe, "the superseded probe must not hand out a probe")
        XCTAssertNil(model.errorMessage,
                     "a superseded probe failure must not clear the newer probe's state")
        XCTAssertTrue(model.isCurrentManualImport(prepared.operation),
                      "the newer probe must still own the units prompt")

        // The newer probe still applies: one mesh body, one undo step.
        await model.importMeshProbe(prepared.probe, unit: .millimetres,
                                    operation: prepared.operation)
        XCTAssertEqual(document.summary().bodyCount, 1)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, 1)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - A stale units prompt cannot commit over a newer import

    func testStaleUnitsApplyCannotCommitAfterANewerManualImport() async throws {
        try await makeTargetDocument()
        let document = try await openDocument()
        let model = document.viewModel()
        let glb = try gridGLB(triangles: 2_000)
        let probeResult = await model.probeMeshOffMainWithOperation(
            data: glb, fileName: "prompt.glb")
        let prepared = try XCTUnwrap(probeResult, "the units prompt fixture must parse")
        XCTAssertEqual(document.summary().bodyCount, 0)

        // A newer manual import supersedes the prompt's operation.
        let newerAccepted = await model.importExactOffMain(data: try oneSolidSTEP(),
                                                           fileName: "newer.step",
                                                           format: "step")
        XCTAssertTrue(newerAccepted)
        let bodyCount = document.summary().bodyCount
        let undoCount = document.session.undoStack.undoCommands.count
        let changes = document.session.changeCount
        let selection = model.selection
        XCTAssertEqual(bodyCount, 1)
        XCTAssertEqual(undoCount, 1)

        await model.importMeshProbe(prepared.probe, unit: .millimetres,
                                    operation: prepared.operation)

        XCTAssertEqual(document.summary().bodyCount, bodyCount,
                       "a stale units prompt must not add bodies")
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCount,
                       "a stale units prompt must not add an undo step")
        XCTAssertEqual(document.session.changeCount, changes)
        XCTAssertEqual(model.selection, selection)
        XCTAssertNil(model.errorMessage,
                     "the newer import must not gain a stale prompt error")
    }

    // MARK: - Close/fence covers the returned probe and the chosen units

    func testFencingManualImportsRejectsThePendingProbeAndUnitsApply() async throws {
        try await makeTargetDocument()
        let document = try await openDocument()
        let model = document.viewModel()
        let glb = try gridGLB(triangles: 2_000)
        let probeResult = await model.probeMeshOffMainWithOperation(
            data: glb, fileName: "prompt.glb")
        let prepared = try XCTUnwrap(probeResult)

        model.fenceManualImportOperations()
        XCTAssertFalse(model.isCurrentManualImport(prepared.operation),
                       "a closed/navigated surface must fence the pending probe")

        await model.importMeshProbe(prepared.probe, unit: .millimetres,
                                    operation: prepared.operation)
        XCTAssertEqual(document.summary().bodyCount, 0,
                       "the fenced prompt must not commit a body")
        XCTAssertFalse(document.session.undoStack.canUndo)

        // The fence is not a permanent break: a new manual import after it
        // owns the UI again.
        let accepted = await model.importExactOffMain(data: try oneSolidSTEP(),
                                                      fileName: "after-fence.step",
                                                      format: "step")
        XCTAssertTrue(accepted)
        XCTAssertEqual(document.summary().bodyCount, 1)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, 1)
    }

    // MARK: - Active, real failures are still actionable

    func testActiveManualImportFailureIsStillSurfaced() async throws {
        try await makeTargetDocument()
        let document = try await openDocument()
        let model = document.viewModel()

        // Garbage IGES bytes are the same real refusal fixture the existing
        // exact contract uses (`CADIGESTests`); the reader is the real one.
        let accepted = await model.importExactOffMain(
            data: Data("this is not an IGES file\n".utf8),
            fileName: "broken.igs", format: "iges")

        XCTAssertFalse(accepted)
        let message = try XCTUnwrap(model.errorMessage,
                                    "an active manual import failure must still be shown")
        XCTAssertTrue(message.contains("broken.igs"), message)
        XCTAssertEqual(document.summary().bodyCount, 0)
        XCTAssertFalse(document.session.undoStack.canUndo)
    }

    // MARK: - Real GLB fixture (same bytes shape the App import reads)

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }

    private func gridGLB(triangles: Int) throws -> Data {
        let quads = max(1, triangles / 2)
        var nx = 1
        while nx * nx * 2 < quads { nx += 1 }
        let ny = max(1, quads / nx)
        let vertexCount = (nx + 1) * (ny + 1)
        var positions = Data()
        var minV = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxV = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for y in 0...ny {
            for x in 0...nx {
                let p = SIMD3<Float>(Float(x), Float(y), 0)
                minV = simd_min(minV, p); maxV = simd_max(maxV, p)
                for value in [p.x, p.y, p.z] { appendUInt32(value.bitPattern, to: &positions) }
            }
        }
        var indices = Data()
        let row = UInt32(nx + 1)
        for y in 0..<ny {
            for x in 0..<nx {
                let i = UInt32(y) * row + UInt32(x)
                for value in [i, i + 1, i + row, i + 1, i + row + 1, i + row] {
                    appendUInt32(value, to: &indices)
                }
            }
        }
        let positionBytes = positions.count
        var jsonData = try JSONSerialization.data(withJSONObject: [
            "asset": ["version": "2.0", "generator": "E31-R3 fixture"],
            "scene": 0,
            "scenes": [["nodes": [0]]],
            "nodes": [["mesh": 0]],
            "meshes": [["name": "Grid", "primitives": [[
                "attributes": ["POSITION": 0], "indices": 1, "mode": 4
            ]]]],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": vertexCount,
                 "type": "VEC3", "min": [minV.x, minV.y, minV.z],
                 "max": [maxV.x, maxV.y, maxV.z]],
                ["bufferView": 1, "componentType": 5125, "count": indices.count / 4,
                 "type": "SCALAR"],
            ],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": positionBytes],
                ["buffer": 0, "byteOffset": positionBytes, "byteLength": indices.count],
            ],
            "buffers": [["byteLength": positionBytes + indices.count]],
        ], options: [.sortedKeys])
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }
        var bin = positions
        bin.append(indices)
        while bin.count % 4 != 0 { bin.append(0) }
        var out = Data([0x67, 0x6C, 0x54, 0x46])
        appendUInt32(2, to: &out)
        appendUInt32(UInt32(12 + 8 + jsonData.count + 8 + bin.count), to: &out)
        appendUInt32(UInt32(jsonData.count), to: &out)
        appendUInt32(0x4E4F534A, to: &out)
        out.append(jsonData)
        appendUInt32(UInt32(bin.count), to: &out)
        appendUInt32(0x004E4942, to: &out)
        out.append(bin)
        return out
    }
}

// MARK: - Deterministic ordering harness (no parser or document stub)

/// Holds the FIRST real exact parse at `holdPhase`/`atBody`.
nonisolated private final class ImportParseGate: @unchecked Sendable {
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let holdPhase: String
    private let holdBody: Int
    private var claimed = false

    init(holdPhase: String, atBody: Int) {
        self.holdPhase = holdPhase
        self.holdBody = atBody
    }

    func checkpoint(_ checkpoint: CADExactImportCheckpoint) {
        guard checkpoint.phase == holdPhase,
              holdBody == 0 || checkpoint.bodyIndex == holdBody else { return }
        lock.lock()
        let shouldHold = !claimed
        claimed = true
        lock.unlock()
        guard shouldHold else { return }
        entered.signal()
        _ = release.wait(timeout: .now() + 30)
    }

    func waitEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.entered.wait(timeout: .now() + 30) == .success)
            }
        }
    }

    func releaseGate() { release.signal() }
}

/// Holds a stale failure delivery on the MainActor until the test releases it,
/// WITHOUT blocking the MainActor (the newer import must run meanwhile).
nonisolated private final class FailureDeliveryHold: @unchecked Sendable {
    private let fileName: String
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)

    init(fileName: String) { self.fileName = fileName }

    func hold(fileName delivered: String) async {
        guard delivered == fileName else { return }
        entered.signal()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                _ = self.release.wait(timeout: .now() + 30)
                continuation.resume()
            }
        }
    }

    func waitEntered() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: self.entered.wait(timeout: .now() + 30) == .success)
            }
        }
    }

    func releaseGate() { release.signal() }
}
#endif
#endif
