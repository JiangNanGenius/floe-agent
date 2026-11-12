// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import XCTest
@testable import FloeCAD

nonisolated final class CADImportedModelMeshTests: XCTestCase {
    @MainActor func testPinnedKiCadSTEPProducesRealMillimetreBuffersOffMain() async throws {
        let data = try Data(contentsOf: fixture())
        XCTAssertEqual(data.count, 40_618)
        XCTAssertEqual(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                       "1875571c326d0d9e96f36b4efeb8094068ef7619f0a449c781caf0b49c2e5861")
        let geometry = try await CADImportedModelMeshLoader.loadExactOffMain(
            data: data, format: "step", fileName: "R_0603_1608Metric.step",
            cancellation: .init())
        XCTAssertTrue(geometry.parsedOffMain)
        XCTAssertFalse(geometry.meshes.isEmpty)
        XCTAssertGreaterThan(geometry.triangleCount, 0)
        XCTAssertLessThanOrEqual(geometry.triangleCount, CADImportedModelMeshLoader.maximumTriangles)
        XCTAssertGreaterThan(geometry.bufferBytes, 0)
        XCTAssertLessThanOrEqual(geometry.bufferBytes, CADImportedModelMeshLoader.maximumBufferBytes)
        let positions = geometry.meshes.flatMap(\.positions)
        let width = try XCTUnwrap(positions.map(\.x).max()) - XCTUnwrap(positions.map(\.x).min())
        let depth = try XCTUnwrap(positions.map(\.y).max()) - XCTUnwrap(positions.map(\.y).min())
        XCTAssertEqual(width, 1.6, accuracy: 0.15, "The source is millimetres; do not auto-fit or rescale it.")
        XCTAssertEqual(depth, 0.8, accuracy: 0.15)
        XCTAssertEqual(geometry.meshes.reduce(0) { $0 + $1.indices.count / 3 }, geometry.triangleCount)
    }

    @MainActor func testCancelledRequestNeverReturnsGeometry() async throws {
        let token = MeshImportCancellation()
        token.cancel()
        do {
            _ = try await CADImportedModelMeshLoader.loadExactOffMain(
                data: Data([1]), format: "step", fileName: "cancelled.step", cancellation: token)
            XCTFail("A cancelled request must not return component geometry.")
        } catch is CancellationError {}
    }

    @MainActor func testInputCeilingRejectsBeforeParsing() async throws {
        do {
            _ = try await CADImportedModelMeshLoader.loadExactOffMain(
                data: Data(repeating: 0, count: CADImportedModelMeshLoader.maximumInputBytes + 1),
                format: "step", fileName: "oversized.step", cancellation: .init())
            XCTFail("Oversized source must be refused.")
        } catch let error as CADDocumentError {
            XCTAssertEqual(error.code, "import_over_budget")
        }
    }

    @MainActor func testMalformedBuffersCannotReachConsumers() throws {
        let good = triangle()
        var badIndex = good; badIndex.indices = [0, 1, 3]
        var nanPoint = good; nanPoint.positions[0].x = .nan
        var infiniteNormal = good; infiniteNormal.normals[0].z = .infinity
        var missingNormal = good; missingNormal.normals.removeLast()
        var hugePoint = good; hugePoint.positions[0].x = 10_001
        var partialTriangle = good; partialTriangle.indices.removeLast()
        for mesh in [badIndex, nanPoint, infiniteNormal, missingNormal, hugePoint, partialTriangle] {
            XCTAssertThrowsError(try CADImportedModelMeshLoader.validatedBuffers(
                from: plan([mesh]), cancellation: .init())) { error in
                XCTAssertEqual((error as? CADDocumentError)?.code, "invalid_component_model")
            }
        }
    }

    @MainActor func testAggregateBudgetsAndIncompleteSurfaceModelAreRefused() throws {
        var tooMany = triangle()
        tooMany.indices = Array(repeating: [UInt32(0), 1, 2],
                               count: CADImportedModelMeshLoader.maximumTriangles + 1).flatMap { $0 }
        XCTAssertThrowsError(try CADImportedModelMeshLoader.validatedBuffers(
            from: plan([tooMany]), cancellation: .init()))
        XCTAssertThrowsError(try CADImportedModelMeshLoader.validatedBuffers(
            from: plan([triangle()], retainedBytes: 48 * 1024 * 1024 + 1), cancellation: .init()))
        XCTAssertThrowsError(try CADImportedModelMeshLoader.validatedBuffers(
            from: plan([triangle()], skippedSurfaces: 1), cancellation: .init()))
    }

    private func fixture() throws -> URL {
        #if SWIFT_PACKAGE
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ElectronicsModels/R_0603_1608Metric.step")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url
        #else
        let bundle = Bundle(for: CADImportedModelMeshTests.self)
        return try XCTUnwrap(bundle.url(forResource: "R_0603_1608Metric", withExtension: "step",
                                       subdirectory: "ElectronicsModels")
            ?? bundle.url(forResource: "R_0603_1608Metric", withExtension: "step"),
            "Add Fixtures/ElectronicsModels to this test host's resources.")
        #endif
    }

    private func triangle() -> RenderMesh {
        .init(positions: [.init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0)],
              normals: Array(repeating: .init(0, 0, 1), count: 3), indices: [0, 1, 2])
    }

    private func plan(_ meshes: [RenderMesh], skippedSurfaces: Int = 0, retainedBytes: Int = 0) -> CADExactImportPlan {
        .init(format: "step", fileName: "test.step", solidCount: meshes.count, surfaceCount: 0,
              skippedSurfaceCount: skippedSurfaces,
              triangleCount: meshes.reduce(0) { $0 + $1.triangleCount },
              retainedBytes: retainedBytes, chargedBytes: 0, rootCount: meshes.count, parsedOffMain: true,
              bodies: meshes.map { .init(isSurface: false, baseName: "test", uniqueName: false,
                                        faceCount: nil, exactData: Data(), render: $0,
                                        edges: .init(segments: []), retainedBytes: 0) })
    }
}
