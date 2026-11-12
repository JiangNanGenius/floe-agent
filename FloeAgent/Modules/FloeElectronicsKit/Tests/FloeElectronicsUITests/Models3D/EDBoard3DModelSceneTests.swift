// SPDX-License-Identifier: MPL-2.0
import XCTest
import Foundation
import SceneKit
import simd
@testable import FloeElectronicsUI
import FloeElectronicsCore

private actor CountingModelLoader: EDBoard3DModelLoading {
    var calls = 0
    var active = 0
    var maximumActive = 0
    let geometry: EDBoard3DModelGeometry
    let delay: Duration
    init(geometry: EDBoard3DModelGeometry, delay: Duration = .zero) {
        self.geometry = geometry; self.delay = delay
    }
    func loadModel(_ reference: EDAFootprintModelReference,
                   cancellation: EDBoard3DModelCancellation) async throws -> EDBoard3DModelGeometry {
        calls += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if delay > .zero { try? await Task.sleep(for: delay) }
        guard !cancellation.isCancelled else { throw EDBoard3DModelLoadError.cancelled }
        return geometry
    }
    func snapshot() -> (calls: Int, maximumActive: Int) { (calls, maximumActive) }
}

@MainActor
final class EDBoard3DModelSceneTests: XCTestCase {
    private func geometry(positions: Int = 4) -> EDBoard3DModelGeometry {
        let pos = (0..<positions).map { SIMD3<Float>(Float($0) * 0.1, 0, 0) }
        let part = EDBoard3DModelPart(name: "body", positions: pos, normals: Array(repeating: SIMD3<Float>(0, 0, 1), count: positions),
            indices: Array(0..<max(3, positions / 2 * 3)).map { UInt32($0 % max(1, positions)) })
        return .init(parts: [part], triangleCount: part.indices.count / 3, bufferBytes: part.cpuBytes)
    }
    private func bigGeometry() -> EDBoard3DModelGeometry {
        let vertices = 600_000
        let positions = Array(repeating: SIMD3<Float>(0, 0, 0), count: vertices)
        let normals = Array(repeating: SIMD3<Float>(0, 0, 1), count: vertices)
        let indices = Array(repeating: UInt32(0), count: vertices * 2)
        let part = EDBoard3DModelPart(name: "big", positions: positions, normals: normals, indices: indices)
        return .init(parts: [part], triangleCount: indices.count / 3, bufferBytes: part.cpuBytes)
    }
    private func project(references: [EDAFootprintModelReference], placements: Int) -> EDAProject {
        var project = EDAProject(title: "3D test")
        var definition = EDAFootprintDefinition(name: "Body")
        definition.modelReferences = references
        project.footprints = [definition]
        project.boards[0].footprints = (0..<placements).map { index in
            EDAFootprint(definitionID: definition.id, position: .init(Double(index) * 10, 0))
        }
        return project
    }
    private func reference(_ id: String, offset: [Double] = [0, 0, 0],
                           rotation: [Double] = [0, 0, 0], scale: [Double] = [1, 1, 1])
        -> EDAFootprintModelReference {
        .init(modelID: "model:test:" + id, sourceID: "test", sourcePath: id, fileName: id,
            format: "step", gitBlobSHA1: String(repeating: "a", count: 40),
            offsetMillimetres: offset, rotationDegrees: rotation, scale: scale)
    }

    func testMatrixUsesBoardCenteredThicknessAndBottomOffsetOnce() {
        let topReference = reference("top.step", offset: [1, 2, 3], rotation: [0, 90, 0])
        let topFootprint = EDAFootprint(definitionID: UUID(), position: .init(10, 20))
        let top = EDBoard3DRenderer.modelMatrix(reference: topReference, footprint: topFootprint, boardThickness: 1.6)
            * SIMD4<Float>(2, 0, 0, 1)
        XCTAssertEqual(top.x, 11, accuracy: 0.0001)
        XCTAssertEqual(top.y, 22, accuracy: 0.0001)
        XCTAssertEqual(top.z, 5.8, accuracy: 0.0001)

        let bottomReference = reference("bottom.step", offset: [0, 0, 1])
        var bottomFootprint = EDAFootprint(definitionID: UUID(), position: .zero)
        bottomFootprint.side = "B.Cu"
        let bottom = EDBoard3DRenderer.modelMatrix(reference: bottomReference, footprint: bottomFootprint, boardThickness: 1.6)
            * SIMD4<Float>(0, 2, 0, 1)
        XCTAssertEqual(bottom.x, 0, accuracy: 0.0001)
        XCTAssertEqual(bottom.y, 2, accuracy: 0.0001)
        // Board is centered at +/-0.8; the authored bottom offset is negated
        // exactly once by the native bottom-side Y flip: -1 - 0.8 = -1.8.
        XCTAssertEqual(bottom.z, -1.8, accuracy: 0.0001)
    }

    func testDuplicateSourceUsesOneLoaderCallAndOneSharedSceneKitGeometry() async {
        let loader = CountingModelLoader(geometry: geometry())
        var project = EDAProject(title: "Dedup")
        var definition = EDAFootprintDefinition(name: "Same body")
        definition.modelReferences = [reference("shared.step")]
        project.footprints = [definition]
        project.boards[0].footprints = [
            EDAFootprint(definitionID: definition.id, position: .zero),
            EDAFootprint(definitionID: definition.id, position: .init(5, 0))
        ]
        let renderer = EDBoard3DRenderer()
        await renderer.load(project: project, boardID: project.boards[0].id, loader: loader)
        await renderer.waitUntilIdle()
        let calls = await loader.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(renderer.renderedModelCount, 2)
        XCTAssertEqual(renderer.uniqueSceneGeometryCount, 1)
        let nodes = renderer.scene.rootNode.childNodes(passingTest: { node, _ in
            node.name?.hasPrefix("electronics.3d.model.") == true
        })
        XCTAssertEqual(nodes.count, 2)
        let first = nodes[0].childNodes.first?.geometry
        let second = nodes[1].childNodes.first?.geometry
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        XCTAssertEqual(ObjectIdentifier(first!), ObjectIdentifier(second!))
        XCTAssertEqual(renderer.state, .ready)
        renderer.stop()
        XCTAssertEqual(renderer.renderedModelCount, 0)
        XCTAssertEqual(renderer.scene.rootNode.childNodes(passingTest: { node, _ in node.name?.hasPrefix("electronics.3d.model.") == true }).count, 0)
    }

    func testAggregateBudgetRefusesSecondModelAndReportsPartialState() async {
        let loader = CountingModelLoader(geometry: bigGeometry())
        var project = EDAProject(title: "Budget")
        let first = EDAFootprintDefinition(name: "One")
        var firstWithRef = first; firstWithRef.modelReferences = [reference("one.step")]
        let second = EDAFootprintDefinition(name: "Two")
        var secondWithRef = second; secondWithRef.modelReferences = [reference("two.step")]
        project.footprints = [firstWithRef, secondWithRef]
        project.boards[0].footprints = [
            EDAFootprint(definitionID: first.id, position: .zero),
            EDAFootprint(definitionID: second.id, position: .init(10, 0))
        ]
        let renderer = EDBoard3DRenderer()
        await renderer.load(project: project, boardID: project.boards[0].id, loader: loader)
        await renderer.waitUntilIdle()
        XCTAssertEqual(renderer.renderedModelCount, 1)
        XCTAssertEqual(renderer.skippedModelCount, 1)
        XCTAssertLessThanOrEqual(renderer.retainedBytes, EDBoard3DRenderer.maximumAggregateBytes)
        XCTAssertTrue(renderer.status.contains("1"))
        XCTAssertNotNil(renderer.failureDetail)
        renderer.stop()
    }

    func testRapidReloadAndStopNeverOverlapModelParses() async {
        let loader = CountingModelLoader(geometry: geometry(positions: 4), delay: .milliseconds(120))
        let projectFixture = project(references: [reference("one.step")], placements: 1)
        let other = project(references: [reference("two.step")], placements: 1)
        let renderer = EDBoard3DRenderer()
        let first = Task { await renderer.load(project: projectFixture, boardID: projectFixture.boards[0].id, loader: loader) }
        try? await Task.sleep(for: .milliseconds(20))
        let second = Task { await renderer.load(project: other, boardID: other.boards[0].id, loader: loader) }
        await first.value
        await second.value
        await renderer.waitUntilIdle()
        let overlap = await loader.maximumActive
        XCTAssertEqual(overlap, 1)
        renderer.stop()
        await renderer.stopAndJoin()
        await renderer.load(project: projectFixture, boardID: projectFixture.boards[0].id, loader: loader)
        await renderer.waitUntilIdle()
        let finalOverlap = await loader.maximumActive
        XCTAssertEqual(finalOverlap, 1)
        XCTAssertEqual(renderer.renderedModelCount, 1)
    }
}
