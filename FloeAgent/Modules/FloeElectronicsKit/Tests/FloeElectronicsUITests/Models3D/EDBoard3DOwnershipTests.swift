// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import simd
@testable import FloeElectronicsUI
import FloeElectronicsCore

/// Represents a parser that cannot finish until its current native call exits.
/// Cancellation is observed only after the test explicitly releases that call.
private actor GatedBoardModelLoader: EDBoard3DModelLoading {
    let geometry: EDBoard3DModelGeometry
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var maximumActive = 0

    init(geometry: EDBoard3DModelGeometry) { self.geometry = geometry }

    func loadModel(_ reference: EDAFootprintModelReference,
                   cancellation: EDBoard3DModelCancellation) async throws -> EDBoard3DModelGeometry {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        if !released { await withCheckedContinuation { pending.append($0) } }
        active -= 1
        guard !cancellation.isCancelled else { throw EDBoard3DModelLoadError.cancelled }
        return geometry
    }

    func releasePending() {
        released = true
        let waiting = pending
        pending.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

private struct ImmediateBoardModelLoader: EDBoard3DModelLoading {
    let geometry: EDBoard3DModelGeometry
    func loadModel(_ reference: EDAFootprintModelReference,
                   cancellation: EDBoard3DModelCancellation) async throws -> EDBoard3DModelGeometry {
        guard !cancellation.isCancelled else { throw EDBoard3DModelLoadError.cancelled }
        return geometry
    }
}

@MainActor private final class BoardLoadCallProbe {
    var entered = false
    var returned = false
}

@MainActor
final class EDBoard3DOwnershipTests: XCTestCase {
    private func geometry() -> EDBoard3DModelGeometry {
        let part = EDBoard3DModelPart(name: "asymmetric",
            positions: [.init(0, 0, 0), .init(2, 0, 0), .init(0, 1, 0)],
            normals: Array(repeating: .init(0, 0, 1), count: 3), indices: [0, 1, 2])
        return .init(parts: [part], triangleCount: 1, bufferBytes: part.cpuBytes)
    }

    private func project(_ name: String) -> EDAProject {
        var project = EDAProject(title: name)
        var footprint = EDAFootprintDefinition(name: name)
        footprint.modelReferences = [.init(modelID: "model:test:" + name,
            sourceID: "test", sourcePath: name + ".step", fileName: name + ".step",
            format: "step", gitBlobSHA1: String(repeating: "a", count: 40))]
        project.footprints = [footprint]
        project.boards[0].footprints = [.init(definitionID: footprint.id, position: .zero)]
        return project
    }

    private func waitForCall(_ count: Int, loader: GatedBoardModelLoader) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await loader.calls < count {
            guard ContinuousClock.now < deadline else { XCTFail("loader did not enter"); return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    private func waitForEntry(_ probe: BoardLoadCallProbe) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !probe.entered {
            guard ContinuousClock.now < deadline else { XCTFail("MainActor load call did not enter"); return }
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func testOverlappingReloadsRetainAndJoinTheNonCooperativeParseBeforeReturning() async {
        let loader = GatedBoardModelLoader(geometry: geometry())
        let renderer = EDBoard3DRenderer()
        let old = project("old"), next = project("next"), latest = project("latest")
        await renderer.load(project: old, boardID: old.boards[0].id, loader: loader)
        await waitForCall(1, loader: loader)

        let firstProbe = BoardLoadCallProbe()
        let first = Task { @MainActor in
            firstProbe.entered = true
            await renderer.load(project: next, boardID: next.boards[0].id, loader: loader)
            firstProbe.returned = true
        }
        await waitForEntry(firstProbe)
        let secondProbe = BoardLoadCallProbe()
        let second = Task { @MainActor in
            secondProbe.entered = true
            await renderer.load(project: latest, boardID: latest.boards[0].id, loader: loader)
            secondProbe.returned = true
        }
        await waitForEntry(secondProbe)

        // The entered flag and load call run in the same MainActor job. A
        // caller that loses the old handle returns here before the gate opens.
        XCTAssertFalse(firstProbe.returned)
        XCTAssertFalse(secondProbe.returned)
        renderer.stop()
        await loader.releasePending()
        await first.value
        await second.value
        await renderer.stopAndJoin()
        let calls = await loader.calls
        let active = await loader.active
        let maximum = await loader.maximumActive
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(active, 0)
        XCTAssertEqual(maximum, 1)
        XCTAssertEqual(renderer.state, .idle)
        XCTAssertEqual(renderer.renderedModelCount, 0)
        XCTAssertEqual(renderer.retainedBytes, 0)
    }

    func testLateDisappearFromOldPresentationCannotStopTheNewPresentation() async {
        let renderer = EDBoard3DRenderer()
        let loader = ImmediateBoardModelLoader(geometry: geometry())
        let old = project("old"), next = project("next")
        let oldOwner = UUID(), nextOwner = UUID()
        await renderer.load(project: old, boardID: old.boards[0].id, loader: loader, ownerID: oldOwner)
        await renderer.waitUntilIdle()
        await renderer.load(project: next, boardID: next.boards[0].id, loader: loader, ownerID: nextOwner)
        await renderer.waitUntilIdle()
        XCTAssertEqual(renderer.state, .ready)
        XCTAssertEqual(renderer.renderedModelCount, 1)
        await renderer.stopAndJoin(ownerID: oldOwner)
        XCTAssertEqual(renderer.state, .ready)
        XCTAssertEqual(renderer.renderedModelCount, 1)
        await renderer.stopAndJoin(ownerID: nextOwner)
        XCTAssertEqual(renderer.state, .idle)
        XCTAssertEqual(renderer.retainedBytes, 0)
    }

    func testBottomModelFollowsTheNativeFootprintPadTransform() {
        let reference = EDAFootprintModelReference(modelID: "model:test:asymmetric",
            sourceID: "test", sourcePath: "asymmetric.step", fileName: "asymmetric.step",
            format: "step", gitBlobSHA1: String(repeating: "a", count: 40),
            offsetMillimetres: [0.5, 1.25, 0.75])
        let footprint = EDAFootprint(definitionID: UUID(), position: .init(10, 20),
            angle: 90, side: "B.Cu")
        let transformed = EDBoard3DRenderer.modelMatrix(reference: reference,
            footprint: footprint, boardThickness: 1.6) * SIMD4<Float>(2, 3, 4, 1)
        let padFrame = footprint.point(.init(2.5, 4.25))
        XCTAssertEqual(padFrame.x, 5.75, accuracy: 0.0001)
        XCTAssertEqual(padFrame.y, 17.5, accuracy: 0.0001)
        XCTAssertEqual(Double(transformed.x), padFrame.x, accuracy: 0.0001)
        XCTAssertEqual(Double(transformed.y), padFrame.y, accuracy: 0.0001)
        XCTAssertEqual(transformed.z, -5.55, accuracy: 0.0001)
    }

    func testSharedGeometryStillChargesEveryPlacementAgainstTheTriangleBudget() async {
        let part = EDBoard3DModelPart(name: "many-triangles",
            positions: [.init(0, 0, 0), .init(2, 0, 0), .init(0, 1, 0)],
            normals: Array(repeating: .init(0, 0, 1), count: 3),
            indices: (0..<600_000).map { UInt32($0 % 3) })
        let loader = ImmediateBoardModelLoader(geometry: .init(parts: [part],
            triangleCount: 200_000, bufferBytes: part.cpuBytes))
        var design = project("instanced")
        let definitionID = design.footprints[0].id
        design.boards[0].footprints = (0..<6).map {
            .init(definitionID: definitionID, position: .init(Double($0) * 5, 0))
        }
        let renderer = EDBoard3DRenderer()
        await renderer.load(project: design, boardID: design.boards[0].id, loader: loader)
        await renderer.waitUntilIdle()
        XCTAssertEqual(renderer.uniqueSceneGeometryCount, 1)
        XCTAssertEqual(renderer.renderedModelCount, 5)
        XCTAssertEqual(renderer.skippedModelCount, 1)
        XCTAssertEqual(renderer.state, .ready)
        XCTAssertNotNil(renderer.failureDetail)
        await renderer.stopAndJoin()
    }

    func testClosingWorkbenchJoinsOwnedNonCooperativeModelWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-3d-close-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = project("closing")
        let store = try await EDAProjectStore.create(root: root, project: project)
        let session = try await EDWorkbenchSession(store: store)
        let loader = GatedBoardModelLoader(geometry: geometry())
        await session.board3DRenderer.load(project: project, boardID: project.boards[0].id, loader: loader)
        await waitForCall(1, loader: loader)
        let probe = BoardLoadCallProbe()
        let closing = Task { @MainActor in
            probe.entered = true
            await session.close()
            probe.returned = true
        }
        await waitForEntry(probe)
        XCTAssertFalse(probe.returned)
        XCTAssertFalse(session.isClosed)
        await loader.releasePending()
        await closing.value
        XCTAssertTrue(session.isClosed)
        XCTAssertEqual(session.board3DRenderer.state, .idle)
        let active = await loader.active
        XCTAssertEqual(active, 0)
        await session.board3DRenderer.load(project: project, boardID: project.boards[0].id, loader: loader)
        await session.board3DRenderer.waitUntilIdle()
        let callsAfterClose = await loader.calls
        XCTAssertEqual(callsAfterClose, 1)
        XCTAssertEqual(session.board3DRenderer.state, .idle)
        await session.board3DRenderer.stopAndJoin()
    }
}
