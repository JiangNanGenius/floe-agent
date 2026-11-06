// SPDX-License-Identifier: MPL-2.0
import Foundation
import XCTest
import Euclid
import simd
@testable import FloeCAD

final class CADBuildingLocalAnalysisTests: XCTestCase {
    private func request(action: String, model: CADBuildingDocument, geometry: [[String: Any]] = [],
                         structural: CADBuildingStructuralSettings = .init()) throws -> Data {
        let encoder = JSONEncoder()
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "action": action,
            "revision": 1, "changeCount": 1, "modelSHA256": String(repeating: "0", count: 64),
            "model": JSONSerialization.jsonObject(with: encoder.encode(model)), "geometry": geometry,
            "structural": JSONSerialization.jsonObject(with: encoder.encode(structural))], options: .sortedKeys)
    }
    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func mesh(_ element: CADBuildingElement, _ source: Euclid.Mesh) -> [String: Any] {
        let render = EuclidBridge.renderMesh(from: source)
        return ["elementID": element.id.uuidString, "bodyID": element.bodyIDs[0].uuidString,
            "verticesM": render.positions.map { [Double($0.x), Double($0.y), Double($0.z)] },
            "indices": render.indices.map(Int.init)]
    }
    private func coordinationFixture() -> (CADBuildingDocument, CADBuildingElement, CADBuildingElement) {
        var model = CADBuildingDocument(name: "Local coordination")
        let floor = model.storeys[0].id
        let duct = CADBuildingElement(storeyID: floor, kind: .duct, name: "Duct",
            a: [3000,-1000], b: [3000,1000], thicknessMM: 100, heightMM: 100, baseOffsetMM: 1500)
        let wall = CADBuildingElement(storeyID: floor, kind: .wall, name: "Wall",
            a: [0,0], b: [6000,0], thicknessMM: 200, heightMM: 3000)
        model.elements = [duct, wall]
        return (model, duct, wall)
    }
    func testNativeBeamMatchesUniformLoadClosedFormsAndOldPyNiteOracle() throws {
        var model = CADBuildingDocument(name: "Local beam")
        let beam = CADBuildingElement(storeyID: model.storeys[0].id, kind: .beam, name: "4m beam",
            a: [0,0], b: [4000,0], thicknessMM: 200, heightMM: 400)
        model.elements = [beam]
        var settings = CADBuildingStructuralSettings(); settings.memberID = beam.id; settings.lineLoadNPerMM = 2
        let simple = try XCTUnwrap(object(CADBuildingLocalAnalysis.evaluate(input:
            request(action: "structure", model: model, structural: settings)))["analysis"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(simple["minimumDeflectionMM"] as? Double), -0.03125, accuracy: 1e-12)
        // Prior real PyNiteFEA 3.2.1 study sampled its min-deflection search;
        // the native closed-form extremum is at exactly L/2.
        XCTAssertEqual(try XCTUnwrap(simple["minimumDeflectionMM"] as? Double), -0.031246173924874002, accuracy: 0.000004)
        XCTAssertEqual(simple["reactionSumN"] as? Double, 8000)
        XCTAssertEqual(simple["reactionAN"] as? Double, 4000)
        XCTAssertEqual(simple["reactionBN"] as? Double, 4000)
        XCTAssertEqual(simple["wholeBuildingAnalysis"] as? Bool, false)
        settings.support = .cantilever
        let cantilever = try XCTUnwrap(object(CADBuildingLocalAnalysis.evaluate(input:
            request(action: "structure", model: model, structural: settings)))["analysis"] as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(cantilever["minimumDeflectionMM"] as? Double), -0.3, accuracy: 1e-12)
        XCTAssertEqual(cantilever["reactionAN"] as? Double, 8000)
        XCTAssertEqual(cantilever["reactionBN"] as? Double, 0)
        XCTAssertEqual(cantilever["supportMomentAMagnitudeNMM"] as? Double, 16_000_000)
    }
    func testNativeCoordinationMeasuresRealIntersectionVolumeWithoutInventingDepth() throws {
        let (model, duct, wall) = coordinationFixture()
        let geometry = [mesh(duct, .cube(center: Vector(3,0,1.5), size: Vector(0.1,2,0.1))),
                        mesh(wall, .cube(center: Vector(3,0,1.5), size: Vector(6,0.2,3)))]
        let result = try object(CADBuildingLocalCoordination.evaluate(input: request(action: "mep", model: model, geometry: geometry)))
        let coordination = try XCTUnwrap(result["coordination"] as? [String: Any])
        XCTAssertEqual(coordination["status"] as? String, "evaluated")
        let clashes = try XCTUnwrap(coordination["clashes"] as? [[String: Any]])
        XCTAssertEqual(clashes.count, 1)
        let clash = try XCTUnwrap(clashes.first)
        XCTAssertEqual(try XCTUnwrap(clash["overlapVolumeM3"] as? Double), 0.002, accuracy: 1e-7)
        XCTAssertNil(clash["distanceM"])
        XCTAssertEqual(clash["a"] as? String, duct.id.uuidString)
        XCTAssertEqual(coordination["penetrationDepthComputed"] as? Bool, false)
    }
    func testOverlappingBoundsDoNotBecomeAPhantomGeometricClash() throws {
        let (model, duct, wall) = coordinationFixture()
        let rotation = Rotation(simd_quatd(angle: .pi/4, axis: SIMD3(0,0,1)))
        let slender = Euclid.Mesh.cube(center: .zero, size: Vector(0.1,2,0.1))
        let a = slender.transformed(by: .init(rotation: rotation))
        let b = slender.transformed(by: .init(rotation: rotation, translation: Vector(0.3,0.3,0)))
        let geometry = [mesh(duct, a), mesh(wall, b)]
        let result = try object(CADBuildingLocalCoordination.evaluate(input: request(action: "mep", model: model, geometry: geometry)))
        let coordination = try XCTUnwrap(result["coordination"] as? [String: Any])
        XCTAssertEqual(coordination["candidateMeshPairs"] as? Int, 1)
        XCTAssertEqual(coordination["evaluatedMeshPairs"] as? Int, 1)
        XCTAssertEqual((coordination["clashes"] as? [[String: Any]])?.count, 0,
                       "The two parallel rotated solids overlap in AABB but are geometrically disjoint")
    }
    func testOpenGeometryInvalidIndicesAndCancellationDoNotReturnAllClear() throws {
        let (model, duct, wall) = coordinationFixture()
        var open = mesh(duct, .cube(center: Vector(3,0,1.5), size: Vector(0.1,2,0.1)))
        var indices = try XCTUnwrap(open["indices"] as? [Int]); indices.removeLast(3); open["indices"] = indices
        let wallMesh = mesh(wall, .cube(center: Vector(3,0,1.5), size: Vector(6,0.2,3)))
        let input = try request(action: "mep", model: model, geometry: [open, wallMesh])
        let coordination = try XCTUnwrap(object(CADBuildingLocalCoordination.evaluate(input: input))["coordination"] as? [String: Any])
        XCTAssertEqual(coordination["status"] as? String, "notEvaluated")
        XCTAssertEqual((coordination["unevaluatedBodies"] as? [[String: Any]])?.count, 1)
        open["indices"] = [0,1,Int(UInt32.max)]
        XCTAssertThrowsError(try CADBuildingLocalCoordination.evaluate(input: request(action: "mep", model: model, geometry: [open, wallMesh])))
        XCTAssertThrowsError(try CADBuildingLocalCoordination.evaluate(input: input, cancelled: { true })) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }
}
