import XCTest
import Foundation
import simd
@testable import FloeCAD

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import RealityKit
import UIKit

/// Regression coverage for the actual Present ground defect: the floor was
/// pinned 0.5 mm below the origin instead of below the transformed model, so a
/// 100 mm slab centred on the origin had its lower half hidden behind the
/// ground. These tests inspect the real `CADPresentationEntityBuilder` stage
/// hierarchy (not a projected image or a rewritten camera) and keep the
/// production camera/material path untouched.
@MainActor
final class CADPresentationFloorBoundsTests: XCTestCase {
    private let firstBodyID = UUID()
    private let secondBodyID = UUID()

    // MARK: Fixtures

    /// Closed 100 x 100 x 12 mm slab with bounds in presentation metres. The
    /// same geometry used by the Present colour witness; only its placement
    /// changes between cases.
    private func slabMesh(minY: Float = -0.05,
                          maxY: Float = 0.05) -> CADPresentationMesh {
        let lower = SIMD3<Float>(-0.05, minY, 0)
        let upper = SIMD3<Float>(0.05, maxY, 0.012)
        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        func addFace(_ corners: [SIMD3<Float>], _ normal: SIMD3<Float>) {
            let base = UInt32(positions.count)
            for corner in corners {
                positions.append(corner)
                normals.append(normal)
            }
            indices.append(contentsOf: [base, base + 1, base + 2,
                                        base, base + 2, base + 3])
        }
        addFace([SIMD3(-0.05, minY, upper.z), SIMD3(0.05, minY, upper.z),
                 SIMD3(0.05, maxY, upper.z), SIMD3(-0.05, maxY, upper.z)],
                SIMD3(0, 0, 1))
        addFace([SIMD3(0.05, minY, lower.z), SIMD3(-0.05, minY, lower.z),
                 SIMD3(-0.05, maxY, lower.z), SIMD3(0.05, maxY, lower.z)],
                SIMD3(0, 0, -1))
        addFace([SIMD3(0.05, minY, upper.z), SIMD3(0.05, minY, lower.z),
                 SIMD3(0.05, maxY, lower.z), SIMD3(0.05, maxY, upper.z)],
                SIMD3(1, 0, 0))
        addFace([SIMD3(-0.05, minY, lower.z), SIMD3(-0.05, minY, upper.z),
                 SIMD3(-0.05, maxY, upper.z), SIMD3(-0.05, maxY, lower.z)],
                SIMD3(-1, 0, 0))
        addFace([SIMD3(-0.05, maxY, upper.z), SIMD3(0.05, maxY, upper.z),
                 SIMD3(0.05, maxY, lower.z), SIMD3(-0.05, maxY, lower.z)],
                SIMD3(0, 1, 0))
        addFace([SIMD3(-0.05, minY, lower.z), SIMD3(0.05, minY, lower.z),
                 SIMD3(0.05, minY, upper.z), SIMD3(-0.05, minY, upper.z)],
                SIMD3(0, -1, 0))
        return CADPresentationMesh(
            positions: positions, normals: normals, indices: indices,
            uvs: nil, meshRevision: 1,
            boundsMin: lower, boundsMax: upper)
    }

    private func body(id: UUID,
                      transform: simd_float4x4 = matrix_identity_float4x4,
                      mesh: CADPresentationMesh) -> CADPresentationBody {
        CADPresentationBody(
            id: id, name: "ground probe", transform: transform,
            mesh: mesh, material: .neutral, faceMaterials: [],
            faceGroups: [], unresolvedFaceCount: 0, analyticBRep: false)
    }

    private func environment(floorVisible: Bool = true) -> CADPresentationEnvironment {
        CADPresentationEnvironment(
            kind: .studio, lightIntensity: 1,
            lightDirectionModel: SIMD3(0, 1, 0),
            backgroundColor: SIMD3(0.12, 0.14, 0.18),
            floorVisible: floorVisible,
            floorColor: SIMD3(0.5, 0.5, 0.52),
            floorSizeMM: 2_000,
            shadowsEnabled: true)
    }

    private func makeScene(bodies: [CADPresentationBody],
                           bounds: CADPresentationBounds?,
                           appearance: CADPresentationEnvironment? = nil) -> CADPresentationScene {
        CADPresentationScene(
            schemaVersion: CADPresentationScene.currentSchemaVersion,
            documentKey: "test://present-floor",
            documentRevision: 1, changeCount: 1,
            contentSHA256: "present-floor-fixture",
            bodies: bodies, images: [],
            environment: appearance ?? environment(),
            issues: [], bounds: bounds, materialCount: 0)
    }

    private func translation(_ value: SIMD3<Float>) -> simd_float4x4 {
        var matrix = matrix_identity_float4x4
        matrix.columns.3 = SIMD4<Float>(value.x, value.y, value.z, 1)
        return matrix
    }

    private func rotation(angle: Float) -> simd_float4x4 {
        simd_float4x4(simd_quatf(
            angle: angle,
            axis: simd_normalize(SIMD3<Float>(0.2, 1, 0.3))))
    }

    /// Independent expected bounds: uses the production transform helper but
    /// not the floor-placement code under test.
    private func expectedBounds(_ bodies: [CADPresentationBody],
                                transforms: [UUID: simd_float4x4]? = nil)
    -> CADPresentationBounds? {
        var result: CADPresentationBounds?
        for body in bodies {
            let transform = transforms?[body.id] ?? body.transform
            let bodyBounds = CADPresentationSceneBuilder.worldBounds(
                min: body.mesh.boundsMin, max: body.mesh.boundsMax,
                transform: transform)
            if let existing = result {
                result = CADPresentationBounds(
                    min: simd_min(existing.min, bodyBounds.min),
                    max: simd_max(existing.max, bodyBounds.max))
            } else {
                result = bodyBounds
            }
        }
        return result
    }

    private func transformedCorners(min: SIMD3<Float>, max: SIMD3<Float>,
                                    transform: simd_float4x4) -> [SIMD3<Float>] {
        var corners: [SIMD3<Float>] = []
        for x in [min.x, max.x] {
            for y in [min.y, max.y] {
                for z in [min.z, max.z] {
                    let point = transform * SIMD4<Float>(x, y, z, 1)
                    corners.append(SIMD3(point.x, point.y, point.z))
                }
            }
        }
        return corners
    }

    private func build(_ scene: CADPresentationScene) async throws
    -> CADPresentationBuildResult {
        try await CADPresentationEntityBuilder(
            cache: CADPresentationResourceCache()).build(scene: scene)
    }

    private func floor(in stage: Entity) -> Entity? {
        stage.children.first { $0.name.hasPrefix("CADPresentationFloor") }
    }

    // MARK: Static build

    func testFloorSitsJustBelowTransformedMinimumAndCentresOnFootprint() async throws {
        let mesh = slabMesh()
        var transform = rotation(angle: .pi / 7)
        transform.columns.3 = SIMD4<Float>(2.5, -1.3, -4.0, 1)
        let probe = body(id: firstBodyID, transform: transform, mesh: mesh)
        let bounds = try XCTUnwrap(expectedBounds([probe]))
        let result = try await build(makeScene(bodies: [probe], bounds: bounds))
        let ground = try XCTUnwrap(floor(in: result.stage))

        XCTAssertEqual(ground.position.y,
                       bounds.min.y - CADPresentationFloorPlacement.clearance,
                       accuracy: 1e-6)
        XCTAssertEqual(ground.position.x, bounds.center.x, accuracy: 1e-6)
        XCTAssertEqual(ground.position.z, bounds.center.z, accuracy: 1e-6)
        XCTAssertLessThan(ground.position.y, bounds.min.y,
                          "ground must be below the transformed model minimum")
        XCTAssertGreaterThan(ground.position.y, bounds.min.y - 0.01,
                             "ground clearance must stay bounded")
        for corner in transformedCorners(min: mesh.boundsMin, max: mesh.boundsMax,
                                         transform: transform) {
            XCTAssertGreaterThan(corner.y, ground.position.y,
                                 "no transformed model point may lie below the ground")
        }

        // Placement is the only change: the authored 2 m floor extent remains.
        let groundModel = try XCTUnwrap(ground as? ModelEntity)
        let meshBounds = try XCTUnwrap(groundModel.model?.mesh.bounds)
        XCTAssertEqual(meshBounds.max.x - meshBounds.min.x, 2.0, accuracy: 1e-3)
        XCTAssertEqual(meshBounds.max.z - meshBounds.min.z, 2.0, accuracy: 1e-3)
    }

    func testFloorTracksModelsAboveAndBelowOrigin() async throws {
        let mesh = slabMesh()
        for offsetY: Float in [-2.5, -0.75] {
            let probe = body(id: firstBodyID,
                             transform: translation(SIMD3<Float>(0, offsetY, 0)),
                             mesh: mesh)
            let bounds = try XCTUnwrap(expectedBounds([probe]))
            XCTAssertLessThanOrEqual(bounds.max.y, 0, "fixture must sit below the origin")
            let result = try await build(makeScene(bodies: [probe], bounds: bounds))
            let ground = try XCTUnwrap(floor(in: result.stage))
            XCTAssertEqual(ground.position.y,
                           bounds.min.y - CADPresentationFloorPlacement.clearance,
                           accuracy: 1e-6)
            XCTAssertLessThan(ground.position.y, bounds.min.y)
        }
        for offsetY: Float in [2.0, 12.0] {
            let probe = body(id: firstBodyID,
                             transform: translation(SIMD3<Float>(0, offsetY, 0)),
                             mesh: mesh)
            let bounds = try XCTUnwrap(expectedBounds([probe]))
            XCTAssertGreaterThan(bounds.min.y, 0, "fixture must sit above the origin")
            let result = try await build(makeScene(bodies: [probe], bounds: bounds))
            let ground = try XCTUnwrap(floor(in: result.stage))
            XCTAssertEqual(ground.position.y,
                           bounds.min.y - CADPresentationFloorPlacement.clearance,
                           accuracy: 1e-6)
        }
    }

    func testGroundFollowsTranslatedFootprint() async throws {
        let mesh = slabMesh()
        let probe = body(id: firstBodyID,
                         transform: translation(SIMD3<Float>(7.5, -0.4, -12.25)),
                         mesh: mesh)
        let bounds = try XCTUnwrap(expectedBounds([probe]))
        let result = try await build(makeScene(bodies: [probe], bounds: bounds))
        let ground = try XCTUnwrap(floor(in: result.stage))
        XCTAssertEqual(ground.position.x, bounds.center.x, accuracy: 1e-6)
        XCTAssertEqual(ground.position.z, bounds.center.z, accuracy: 1e-6)
        XCTAssertNotEqual(ground.position.x, 0)
        XCTAssertNotEqual(ground.position.z, 0)
        XCTAssertLessThan(ground.position.y, bounds.min.y)
    }

    func testGroundDoesNotCrossNegativeYGeometry() async throws {
        // Reproduces the failing witness slab class: a body straddling and
        // below Y=0. Every actual vertex must remain above the plane.
        let mesh = slabMesh(minY: -0.12, maxY: 0.03)
        let probe = body(id: firstBodyID, mesh: mesh)
        let bounds = try XCTUnwrap(expectedBounds([probe]))
        let result = try await build(makeScene(bodies: [probe], bounds: bounds))
        let ground = try XCTUnwrap(floor(in: result.stage))
        XCTAssertEqual(bounds.min.y - ground.position.y,
                       CADPresentationFloorPlacement.clearance, accuracy: 1e-6)
        for position in mesh.positions {
            XCTAssertGreaterThan(position.y, ground.position.y,
                                 "ground bisects body geometry at \(position)")
        }
    }

    func testHiddenFloorCreatesNoGroundAndUpdateIsNoOp() async throws {
        let mesh = slabMesh()
        let probe = body(id: firstBodyID, mesh: mesh)
        let bounds = try XCTUnwrap(expectedBounds([probe]))
        let scene = makeScene(bodies: [probe], bounds: bounds,
                              appearance: environment(floorVisible: false))
        let result = try await build(scene)
        XCTAssertNil(floor(in: result.stage))
        CADPresentationEntityBuilder.updateFloor(in: result.stage, bounds: bounds)
        XCTAssertNil(floor(in: result.stage))
    }

    func testEmptyAndInvalidBoundsUseTheBoundedFallback() async throws {
        let fallback = SIMD3<Float>(0, -CADPresentationFloorPlacement.clearance, 0)
        XCTAssertEqual(CADPresentationFloorPlacement.position(for: nil), fallback)
        let nan = CADPresentationBounds(
            min: SIMD3(Float.nan, -1, 0), max: SIMD3(1, 1, 1))
        XCTAssertEqual(CADPresentationFloorPlacement.position(for: nan), fallback)
        let inverted = CADPresentationBounds(
            min: SIMD3(0, 1, 0), max: SIMD3(1, -1, 1))
        XCTAssertEqual(CADPresentationFloorPlacement.position(for: inverted), fallback)

        let mesh = slabMesh()
        let probe = body(id: firstBodyID, mesh: mesh)
        let result = try await build(makeScene(bodies: [probe], bounds: nil))
        let ground = try XCTUnwrap(floor(in: result.stage))
        XCTAssertEqual(ground.position, fallback)
        XCTAssertTrue(ground.position.y.isFinite)
    }

    func testEnvironmentRedressUsesTheVisibleBounds() async throws {
        let cache = CADPresentationResourceCache()
        let builder = CADPresentationEntityBuilder(cache: cache)
        let mesh = slabMesh()
        let probe = body(id: firstBodyID,
                         transform: translation(SIMD3<Float>(1.0, -0.75, 2.0)),
                         mesh: mesh)
        let bounds = try XCTUnwrap(expectedBounds([probe]))
        let result = try await builder.build(
            scene: makeScene(bodies: [probe], bounds: nil))
        let fallbackFloor = try XCTUnwrap(floor(in: result.stage))
        XCTAssertEqual(fallbackFloor.position,
                       SIMD3<Float>(0, -CADPresentationFloorPlacement.clearance, 0))

        await builder.applyEnvironment(environment(), to: result.stage,
                                       bounds: bounds, cache: cache)
        let redressed = try XCTUnwrap(floor(in: result.stage))
        XCTAssertEqual(redressed.position.y,
                       bounds.min.y - CADPresentationFloorPlacement.clearance,
                       accuracy: 1e-6)
        XCTAssertEqual(redressed.position.x, bounds.center.x, accuracy: 1e-6)
        XCTAssertEqual(redressed.position.z, bounds.center.z, accuracy: 1e-6)
    }

    // MARK: Animation

    func testAnimatedBoundsFollowThePoseAndUnionMissingInstances() throws {
        let mesh = slabMesh()
        let first = body(id: firstBodyID, mesh: mesh)
        let second = body(id: secondBodyID,
                          transform: translation(SIMD3<Float>(0, 0.4, 0)),
                          mesh: mesh)
        let baselineBounds = try XCTUnwrap(expectedBounds([first, second]))
        let scene = makeScene(bodies: [first, second], bounds: baselineBounds)

        var animated = rotation(angle: .pi / 5)
        animated.columns.3 = SIMD4<Float>(1.25, -0.22, -0.5, 1)
        let expected = try XCTUnwrap(expectedBounds(
            [first, second], transforms: [first.id: animated]))
        let actual = try XCTUnwrap(CADPresentationFloorPlacement.bounds(
            for: scene, transforms: [first.id: animated]))
        XCTAssertEqual(actual.min.y, expected.min.y, accuracy: 1e-6)
        XCTAssertEqual(actual.max.y, expected.max.y, accuracy: 1e-6)
        XCTAssertEqual(actual.min.x, expected.min.x, accuracy: 1e-6)
        XCTAssertEqual(actual.max.z, expected.max.z, accuracy: 1e-6)
        XCTAssertLessThan(actual.min.y, baselineBounds.min.y,
                          "the animated pose must actually lower the minimum")
    }

    func testBuiltGroundFollowsAnAnimatedPoseAndRestoresTheBaseline() async throws {
        let mesh = slabMesh()
        let probe = body(id: firstBodyID, mesh: mesh)
        let baseline = try XCTUnwrap(expectedBounds([probe]))
        let scene = makeScene(bodies: [probe], bounds: baseline)
        let result = try await build(scene)
        let ground = try XCTUnwrap(floor(in: result.stage))
        let baselinePosition = ground.position

        var animated = rotation(angle: .pi / 5)
        animated.columns.3 = SIMD4<Float>(1.25, -0.22, -0.5, 1)
        let animatedBounds = try XCTUnwrap(
            CADPresentationFloorPlacement.bounds(
                for: scene, transforms: [probe.id: animated]))
        XCTAssertLessThan(animatedBounds.min.y, baseline.min.y)

        CADPresentationEntityBuilder.updateFloor(in: result.stage,
                                                 bounds: animatedBounds)
        XCTAssertEqual(ground.position.y,
                       animatedBounds.min.y - CADPresentationFloorPlacement.clearance,
                       accuracy: 1e-6)
        XCTAssertEqual(ground.position.x, animatedBounds.center.x, accuracy: 1e-6)
        XCTAssertEqual(ground.position.z, animatedBounds.center.z, accuracy: 1e-6)

        CADPresentationEntityBuilder.updateFloor(in: result.stage, bounds: baseline)
        XCTAssertEqual(ground.position, baselinePosition)
    }

    /// End-to-end render-controller path: a transient animation frame updates
    /// the floor through the same method playback/export use, and stopping
    /// playback restores the document pose. No document edit or snapshot is
    /// involved.
    func testControllerAnimationFrameMovesTheGroundAndClearRestoresIt() async throws {
        let mesh = slabMesh()
        let probe = body(id: firstBodyID, mesh: mesh)
        let baseline = try XCTUnwrap(expectedBounds([probe]))
        let scene = makeScene(bodies: [probe], bounds: baseline)
        let controller = CADPresentationRenderController()
        defer { controller.release() }
        controller.apply(scene)

        let deadline = Date().addingTimeInterval(60)
        while !controller.isStageReady, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(controller.isStageReady,
                      "the production controller must build its stage for this test")

        let ground = try XCTUnwrap(floorEntity(in: controller.arView.scene))
        XCTAssertEqual(ground.position.y,
                       baseline.min.y - CADPresentationFloorPlacement.clearance,
                       accuracy: 1e-5)
        let generation = controller.renderGeneration
        var animated = rotation(angle: .pi / 5)
        animated.columns.3 = SIMD4<Float>(1.25, -0.22, -0.5, 1)
        let animatedBounds = try XCTUnwrap(
            CADPresentationFloorPlacement.bounds(
                for: scene, transforms: [probe.id: animated]))
        XCTAssertTrue(controller.applyAnimation(
            camera: nil, instanceTransforms: [probe.id: animated],
            token: "floor-bounds-test", expectedGeneration: generation,
            lease: nil))
        XCTAssertEqual(ground.position.y,
                       animatedBounds.min.y - CADPresentationFloorPlacement.clearance,
                       accuracy: 1e-5)
        XCTAssertLessThan(ground.position.y, animatedBounds.min.y)
        XCTAssertLessThan(ground.position.y, baseline.min.y)

        controller.clearAnimation()
        XCTAssertEqual(ground.position.y,
                       baseline.min.y - CADPresentationFloorPlacement.clearance,
                       accuracy: 1e-5)
    }

    private func floorEntity(in scene: RealityFoundation.Scene) -> Entity? {
        if let direct = scene.findEntity(named: "CADPresentationFloor") {
            return direct
        }
        for anchor in scene.anchors {
            if let found = floorEntity(in: anchor as Entity) { return found }
        }
        return nil
    }

    private func floorEntity(in entity: Entity) -> Entity? {
        if entity.name.hasPrefix("CADPresentationFloor") { return entity }
        for child in entity.children {
            if let found = floorEntity(in: child) { return found }
        }
        return nil
    }
}
#endif
