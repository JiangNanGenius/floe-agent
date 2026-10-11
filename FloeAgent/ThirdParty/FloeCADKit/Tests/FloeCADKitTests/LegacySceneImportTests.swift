//
//  LegacySceneImportTests.swift
//  FloeCADKitTests
//
//  Focused coverage for the unified-3D migration import boundary:
//  all five legacy primitives, exact placement/material/visibility, the
//  nonuniform scale bake, the exact 1×0.04×1 plane slab, idempotent
//  re-import, refusal without mutation, save/reopen round-trip and the
//  viewport/editor consumption of the persisted scene presentation.
//

import XCTest
import simd
import Euclid
@testable import FloeCAD

@MainActor
final class LegacySceneImportTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeCADLegacyScene-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func object(
        kind: CADLegacyScene.Object.Kind,
        name: String = "Object",
        position: (Double, Double, Double) = (0, 0, 0),
        rotation: (Double, Double, Double) = (0, 0, 0),
        scale: (Double, Double, Double) = (1, 1, 1),
        colorHex: String = "#3366CC",
        roughness: Double = 0.35,
        metallic: Bool = false,
        hidden: Bool = false
    ) -> CADLegacyScene.Object {
        CADLegacyScene.Object(
            id: UUID(), name: name, kind: kind,
            positionX: position.0, positionY: position.1, positionZ: position.2,
            rotationX: rotation.0, rotationY: rotation.1, rotationZ: rotation.2,
            scaleX: scale.0, scaleY: scale.1, scaleZ: scale.2,
            colorHex: colorHex, roughness: roughness, metallic: metallic, isHidden: hidden)
    }

    private func scene(objects: [CADLegacyScene.Object],
                       showsGrid: Bool = true) -> CADLegacyScene {
        CADLegacyScene(
            objects: objects,
            camera: CADLegacyScene.Camera(
                yawDegrees: 38, pitchDegrees: -22, distance: 6.5,
                targetX: 0, targetY: 0, targetZ: 0, fieldOfViewDegrees: 48),
            lighting: CADLegacyScene.Lighting(
                keyIntensity: 28_000, fillIntensity: 7_000, castsShadows: true),
            background: .studio,
            showsGrid: showsGrid,
            sourceDigest: String(repeating: "a", count: 64),
            sourceSceneJSON: Data(#"{"objects":[]}"#.utf8))
    }

    private func makeDocument(name: String = "Scene") async throws -> (FloeCADDocument, URL) {
        let url = workDir.appendingPathComponent("\(name).floecad")
        let document = try await FloeCADDocument.create(at: url, name: name)
        return (document, url)
    }

    private func linear(_ component: Double) -> Double {
        component <= 0.04045 ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }

    // MARK: All five primitives, exact geometry

    func testImportAllFivePrimitivesBakesExactGeometry() async throws {
        let (document, _) = try await makeDocument()
        defer { document.close() }

        let box = object(kind: .box, name: "Box", position: (1, 2, 3), scale: (2, 3, 4))
        let sphere = object(kind: .sphere, name: "Sphere", scale: (1, 0.5, 1.5))
        let cylinder = object(kind: .cylinder, name: "Cylinder", scale: (0.25, 2, 0.25))
        let cone = object(kind: .cone, name: "Cone", scale: (0.5, 1, 0.5))
        let plane = object(kind: .plane, name: "Plane", position: (0, 0.02, 0))

        let result = try document.importLegacyScene(scene(objects: [box, sphere, cylinder, cone, plane]))
        XCTAssertEqual(result.bodyIDs, [box.id, sphere.id, cylinder.id, cone.id, plane.id])
        XCTAssertTrue(result.settingsWritten)

        let bodies = document.session.document.bodies
        XCTAssertEqual(bodies.count, 5)

        // Box: 2×3×4 m → 2000×3000×4000 mm centred at (1000, 2000, 3000) mm.
        let boxBody = try XCTUnwrap(bodies.first { $0.id.raw == box.id })
        XCTAssertEqual(boxBody.name, "Box")
        XCTAssertEqual(boxBody.transform.translation.x, 1000, accuracy: 1e-6)
        XCTAssertEqual(boxBody.transform.translation.y, 2000, accuracy: 1e-6)
        XCTAssertEqual(boxBody.transform.translation.z, 3000, accuracy: 1e-6)
        let boxAABB = boxBody.render.localAABB
        XCTAssertEqual(Double(boxAABB.max.x - boxAABB.min.x), 2000, accuracy: 1e-3)
        XCTAssertEqual(Double(boxAABB.max.y - boxAABB.min.y), 3000, accuracy: 1e-3)
        XCTAssertEqual(Double(boxAABB.max.z - boxAABB.min.z), 4000, accuracy: 1e-3)

        // Plane: the legacy 1 × 0.04 × 1 thin slab (fully rounded per
        // generateBox cornerRadius 0.02), NOT an infinite plane and not an
        // extrusion.
        let planeBody = try XCTUnwrap(bodies.first { $0.id.raw == plane.id })
        let planeAABB = planeBody.render.localAABB
        XCTAssertEqual(Double(planeAABB.max.x - planeAABB.min.x), 1000, accuracy: 1e-3)
        XCTAssertEqual(Double(planeAABB.max.y - planeAABB.min.y), 40, accuracy: 1e-3)
        XCTAssertEqual(Double(planeAABB.max.z - planeAABB.min.z), 1000, accuracy: 1e-3)

        // Nonuniform scale on the round primitives (ellipsoid / elliptical).
        let sphereBody = try XCTUnwrap(bodies.first { $0.id.raw == sphere.id })
        let sphereAABB = sphereBody.render.localAABB
        XCTAssertEqual(Double(sphereAABB.max.x - sphereAABB.min.x), 1000, accuracy: 1e-3)
        XCTAssertEqual(Double(sphereAABB.max.y - sphereAABB.min.y), 500, accuracy: 1e-3)
        XCTAssertEqual(Double(sphereAABB.max.z - sphereAABB.min.z), 1500, accuracy: 1e-3)
        let cylinderBody = try XCTUnwrap(bodies.first { $0.id.raw == cylinder.id })
        XCTAssertEqual(Double(cylinderBody.render.localAABB.max.y
                              - cylinderBody.render.localAABB.min.y), 2000, accuracy: 1e-3)
        let coneBody = try XCTUnwrap(bodies.first { $0.id.raw == cone.id })
        XCTAssertEqual(Double(coneBody.render.localAABB.max.y
                              - coneBody.render.localAABB.min.y), 1000, accuracy: 1e-3)

        // Plain mesh bodies: the rounded bevel is real geometry, never a
        // parametric feature or a primitive spec that would need replaying.
        for body in bodies {
            XCTAssertNil(body.primitive, "imports are plain mesh bodies")
        }
    }

    // MARK: Rounded legacy geometry (generateBox cornerRadius)

    /// RealityKit's `generateBox(size: 1, cornerRadius: 0.08)` is the convex
    /// rounded cuboid: every surface point is exactly 0.08 from the 0.84³
    /// core box. The import bakes that bevel as real convex mesh geometry and
    /// applies the per-axis entity scale — it is never silently sharpened.
    func testRoundedBoxBevelIsBakedExactlyAcrossNonUniformScale() async throws {
        let (document, _) = try await makeDocument(name: "RoundedBox")
        defer { document.close() }
        let scale = (2.0, 3.0, 4.0)
        let box = object(kind: .box, scale: scale)
        _ = try document.importLegacyScene(scene(objects: [box]))
        let body = try XCTUnwrap(document.session.document.bodies.first)
        let mesh = try XCTUnwrap(body.euclid, "the import keeps its exact mesh")

        XCTAssertTrue(mesh.isWatertight, "the rounded box must be a closed mesh")
        XCTAssertGreaterThan(mesh.signedVolume, 0, "faces must face outward")

        // Exact outer dimensions, centred on the entity origin.
        let bounds = mesh.bounds
        XCTAssertEqual(bounds.max.x - bounds.min.x, 2000, accuracy: 1e-6)
        XCTAssertEqual(bounds.max.y - bounds.min.y, 3000, accuracy: 1e-6)
        XCTAssertEqual(bounds.max.z - bounds.min.z, 4000, accuracy: 1e-6)
        XCTAssertEqual(bounds.center.x, 0, accuracy: 1e-9)
        XCTAssertEqual(bounds.center.y, 0, accuracy: 1e-9)
        XCTAssertEqual(bounds.center.z, 0, accuracy: 1e-9)

        let unitCore = Vector(0.5 - CADLegacySceneMesh.boxCornerRadius,
                              0.5 - CADLegacySceneMesh.boxCornerRadius,
                              0.5 - CADLegacySceneMesh.boxCornerRadius)
        let radius = CADLegacySceneMesh.boxCornerRadius
        let mm = 1000.0
        let sx = scale.0 * mm, sy = scale.1 * mm, sz = scale.2 * mm
        var flat = 0, curved = 0
        var closestToSharpCorner = Double.greatestFiniteMagnitude
        let sharpCorner = Vector(0.5, 0.5, 0.5)
        for polygon in mesh.polygons {
            for vertex in polygon.vertices {
                // Back to legacy unit space: ÷(scale · 1000).
                let unit = Vector(vertex.position.x / sx,
                                  vertex.position.y / sy,
                                  vertex.position.z / sz)
                let clamped = Vector(
                    min(max(unit.x, -unitCore.x), unitCore.x),
                    min(max(unit.y, -unitCore.y), unitCore.y),
                    min(max(unit.z, -unitCore.z), unitCore.z))
                let offset = unit - clamped
                let length = offset.length
                // The exact radius invariant: every vertex lies ON the
                // analytic rounded surface. A sharp box fails this at every
                // corner; a dropped or mis-scaled bevel fails it at the
                // edges.
                XCTAssertEqual(length, radius, accuracy: 1e-9)
                // Exact outward normal (also proves the winding). The mesh
                // is nonuniformly scaled, so the unit-space normal maps by
                // the inverse transpose (1/sx, 1/sy, 1/sz).
                let unitNormal = offset / length
                let transformed = Vector(unitNormal.x / sx,
                                         unitNormal.y / sy,
                                         unitNormal.z / sz)
                XCTAssertGreaterThan(vertex.normal.dot(transformed.normalized()), 1 - 1e-9,
                                     "vertex normals are the analytic outward normals")
                var outside = 0
                if unit.x > unitCore.x { outside += 1 }
                if unit.y > unitCore.y { outside += 1 }
                if unit.z > unitCore.z { outside += 1 }
                if outside == 0 { flat += 1 } else { curved += 1 }
                closestToSharpCorner = min(closestToSharpCorner,
                                           (unit - sharpCorner).length)
            }
        }
        XCTAssertGreaterThan(flat, 0, "flat face patches present")
        XCTAssertGreaterThan(curved, 8 * 100,
                             "12 edge cylinders and 8 corner octants tessellated")
        // The sharp corner point is NOT on the surface: the rounded surface
        // sits √3·r − r away from it; and the tessellation does reach the
        // corner region (min is finite and below the bevel).
        XCTAssertGreaterThan(closestToSharpCorner, 0.04,
                             "no sharp corner may survive")
        XCTAssertLessThan(closestToSharpCorner, radius,
                          "the surface must round toward the corner")
    }

    /// The legacy plane is `generateBox(size: (1, 0.04, 1), cornerRadius:
    /// 0.02)`: a thin fully rounded slab (radius = half the thickness), NOT a
    /// sharp box, NOT an infinite plane, NOT an extrusion.
    func testRoundedPlaneSlabKeepsTheLegacyRoundedRim() async throws {
        let (document, _) = try await makeDocument(name: "RoundedPlane")
        defer { document.close() }
        let scale = (3.0, 1.0, 3.0)
        let plane = object(kind: .plane, scale: scale)
        _ = try document.importLegacyScene(scene(objects: [plane]))
        let body = try XCTUnwrap(document.session.document.bodies.first)
        let mesh = try XCTUnwrap(body.euclid)

        XCTAssertTrue(mesh.isWatertight)
        XCTAssertGreaterThan(mesh.signedVolume, 0)
        let bounds = mesh.bounds
        XCTAssertEqual(bounds.max.x - bounds.min.x, 3000, accuracy: 1e-6)
        XCTAssertEqual(bounds.max.y - bounds.min.y, 40, accuracy: 1e-6)
        XCTAssertEqual(bounds.max.z - bounds.min.z, 3000, accuracy: 1e-6)

        let radius = CADLegacySceneMesh.planeCornerRadius
        let core = Vector(0.5 - radius, 0, 0.5 - radius)
        let mm = 1000.0
        let sx = scale.0 * mm, sy = scale.1 * mm, sz = scale.2 * mm
        var equatorRim = false
        var topReached = false
        var bottomReached = false
        var closestToSharpCorner = Double.greatestFiniteMagnitude
        let sharpCorner = Vector(0.5, radius, 0.5)
        for polygon in mesh.polygons {
            for vertex in polygon.vertices {
                let unit = Vector(vertex.position.x / sx,
                                  vertex.position.y / sy,
                                  vertex.position.z / sz)
                let clamped = Vector(
                    min(max(unit.x, -core.x), core.x),
                    min(max(unit.y, -core.y), core.y),
                    min(max(unit.z, -core.z), core.z))
                let offset = unit - clamped
                let length = offset.length
                XCTAssertEqual(length, radius, accuracy: 1e-9,
                               "the slab is fully rounded (radius = half thickness)")
                let unitNormal = offset / length
                let transformed = Vector(unitNormal.x / sx,
                                         unitNormal.y / sy,
                                         unitNormal.z / sz)
                XCTAssertGreaterThan(vertex.normal.dot(transformed.normalized()), 1 - 1e-9)
                if abs(unit.y) < 1e-9, abs(unit.x) > core.x + radius * 0.99,
                   abs(unit.z) <= core.z + 1e-9 {
                    equatorRim = true
                }
                if unit.y > radius - 1e-9 { topReached = true }
                if unit.y < -(radius - 1e-9) { bottomReached = true }
                closestToSharpCorner = min(closestToSharpCorner,
                                           (unit - sharpCorner).length)
            }
        }
        XCTAssertTrue(equatorRim, "the rounded rim crosses the mid-plane")
        XCTAssertTrue(topReached)
        XCTAssertTrue(bottomReached)
        XCTAssertGreaterThan(closestToSharpCorner, 0.01,
                             "the sharp slab corner must not survive")
    }

    /// Direct kernel check: the builder's closed convex mesh has the analytic
    /// Minkowski-sum volume within tessellation error, and the radius clamps
    /// to half the smallest dimension exactly like MeshResource does.
    func testRoundedBoxKitMatchesAnalyticSolid() throws {
        let radius = 0.08
        let mesh = RoundedBoxKit.mesh(size: Vector(1, 1, 1), cornerRadius: radius)
        XCTAssertTrue(mesh.isWatertight)
        let core = 1 - 2 * radius
        let analytic = core * core * core
            + 2 * radius * (core * core) * 3
            + Double.pi * radius * radius * (core * 3)
            + 4.0 / 3.0 * Double.pi * radius * radius * radius
        XCTAssertEqual(mesh.signedVolume, analytic, accuracy: analytic * 0.01)

        // Clamped radius (half thickness) — the legacy plane slab case.
        let slab = RoundedBoxKit.mesh(size: Vector(1, 0.04, 1), cornerRadius: 0.02)
        XCTAssertTrue(slab.isWatertight)
        XCTAssertEqual(slab.bounds.max.y, 0.02, accuracy: 1e-9)
        XCTAssertEqual(slab.bounds.min.y, -0.02, accuracy: 1e-9)

        // Zero radius falls back to the sharp box (6 quad faces).
        let sharp = RoundedBoxKit.mesh(size: Vector(2, 3, 4), cornerRadius: 0)
        XCTAssertTrue(sharp.isWatertight)
        XCTAssertEqual(sharp.bounds.max.x, 1, accuracy: 1e-12)
        XCTAssertEqual(sharp.polygons.count, 6)
    }

    // MARK: Disclosed visual approximations

    /// The bounded visual differences (unitless normalized lighting;
    /// planar ground shadow) are part of the import result AND persisted in
    /// the scene presentation, so T6 can disclose them with the migrated
    /// preview instead of hiding them in a private report.
    func testVisualApproximationsAreRecordedAndPersisted() async throws {
        let (document, _) = try await makeDocument(name: "Disclosures")
        defer { document.close() }
        let payload = scene(objects: [object(kind: .box)]) // castsShadows: true
        let result = try document.importLegacyScene(payload)
        XCTAssertEqual(result.visualApproximations,
                       [.lightingIntensityNormalized, .planarGroundShadow])
        let legacy = try XCTUnwrap(document.sceneSettings?.legacy)
        XCTAssertEqual(legacy.visualApproximations, result.visualApproximations)

        // No shadows → only the intensity normalization remains.
        var quiet = payload
        quiet.lighting.castsShadows = false
        let (document2, _) = try await makeDocument(name: "NoShadows")
        defer { document2.close() }
        let result2 = try document2.importLegacyScene(quiet)
        XCTAssertEqual(result2.visualApproximations, [.lightingIntensityNormalized])
        XCTAssertEqual(document2.sceneSettings?.legacy?.visualApproximations,
                       [.lightingIntensityNormalized])
    }

    func testRotationUsesLegacyZYXDegreeComposition() async throws {
        let (document, _) = try await makeDocument()
        defer { document.close() }
        let rotated = object(kind: .box, rotation: (10, -35.5, 179))
        _ = try document.importLegacyScene(scene(objects: [rotated]))
        let body = try XCTUnwrap(document.session.document.bodies.first)
        let deg = Double.pi / 180
        let expected = simd_normalize(
            simd_quatd(angle: 179 * deg, axis: SIMD3(0, 0, 1))
            * simd_quatd(angle: -35.5 * deg, axis: SIMD3(0, 1, 0))
            * simd_quatd(angle: 10 * deg, axis: SIMD3(1, 0, 0)))
        let dot = abs(simd_dot(simd_normalize(body.transform.rotation), expected))
        XCTAssertGreaterThan(dot, 1 - 1e-9, "rotation must be Z·Y·X in degrees")
    }

    func testMaterialVisibilityAndColorMapping() async throws {
        let (document, _) = try await makeDocument()
        defer { document.close() }
        let hidden = object(kind: .sphere, colorHex: "#3366CC",
                            roughness: 0.7, metallic: true, hidden: true)
        _ = try document.importLegacyScene(scene(objects: [hidden]))
        let body = try XCTUnwrap(document.session.document.bodies.first)
        XCTAssertTrue(body.isHidden)
        let material = try XCTUnwrap(body.material)
        XCTAssertEqual(material.baseColor.x, linear(0x33 / 255.0), accuracy: 1e-9)
        XCTAssertEqual(material.baseColor.y, linear(0x66 / 255.0), accuracy: 1e-9)
        XCTAssertEqual(material.baseColor.z, linear(0xCC / 255.0), accuracy: 1e-9)
        XCTAssertEqual(material.metallic, 1)
        XCTAssertEqual(material.roughness, 0.7, accuracy: 1e-9)
    }

    // MARK: Idempotency + refusal

    func testSecondImportOfTheSameSceneIsIdempotent() async throws {
        let (document, _) = try await makeDocument()
        defer { document.close() }
        let payload = scene(objects: [object(kind: .box), object(kind: .cone)])
        let first = try document.importLegacyScene(payload)
        let second = try document.importLegacyScene(payload)
        XCTAssertEqual(first.bodyIDs, second.bodyIDs)
        XCTAssertEqual(document.session.document.bodies.count, 2,
                       "re-import must never duplicate bodies")
    }

    func testInvalidSceneRefusesBeforeAnyMutation() async throws {
        let (document, _) = try await makeDocument()
        defer { document.close() }
        let invalid = scene(objects: [object(kind: .box, scale: (1, 0, 1))])
        XCTAssertThrowsError(try document.importLegacyScene(invalid)) { error in
            XCTAssertTrue(error is CADLegacySceneImportError)
        }
        XCTAssertTrue(document.session.document.bodies.isEmpty)
        XCTAssertNil(document.sceneSettings)
    }

    // MARK: Persistence + reopen

    func testSceneSettingsRoundTripThroughSaveAndReopen() async throws {
        let (document, url) = try await makeDocument(name: "RoundTrip")
        let payload = scene(objects: [object(kind: .box), object(kind: .plane)],
                            showsGrid: false)
        _ = try document.importLegacyScene(payload)
        let save = await document.save()
        XCTAssertTrue(save.succeeded, save.error ?? "")
        document.close()

        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertEqual(reopened.session.document.bodies.count, 2)
        let settings = try XCTUnwrap(reopened.sceneSettings)

        // Camera: yaw→azimuth, −pitch→elevation, metres→mm, FOV unchanged.
        let camera = try XCTUnwrap(settings.camera)
        XCTAssertEqual(camera.azimuthRadians, 38 * Double.pi / 180, accuracy: 1e-12)
        XCTAssertEqual(camera.elevationRadians, 22 * Double.pi / 180, accuracy: 1e-12)
        XCTAssertEqual(camera.distance, 6500, accuracy: 1e-9)
        XCTAssertEqual(camera.fovYDegrees, 48, accuracy: 1e-9)
        XCTAssertFalse(camera.isOrthographic)

        // Lighting: normalized against the legacy defaults; key direction from
        // (3.5, 5, 4) toward the origin; fill at (−3, 2.5, 2) m in mm.
        let lighting = try XCTUnwrap(settings.lighting)
        XCTAssertEqual(lighting.keyIntensityScale, 1, accuracy: 1e-9)
        XCTAssertEqual(lighting.fillIntensityScale, 1, accuracy: 1e-9)
        XCTAssertTrue(lighting.castsShadows)
        let key = SIMD3(lighting.keyDirectionX, lighting.keyDirectionY, lighting.keyDirectionZ)
        XCTAssertEqual(simd_length(key), 1, accuracy: 1e-9)
        XCTAssertEqual(lighting.fillPositionX, -3000, accuracy: 1e-9)
        XCTAssertEqual(lighting.fillPositionY, 2500, accuracy: 1e-9)
        XCTAssertEqual(lighting.fillPositionZ, 2000, accuracy: 1e-9)

        // Background: the exact legacy studio colour; grid flag carried.
        let background = try XCTUnwrap(settings.background)
        XCTAssertEqual(background.topRed, 0.12, accuracy: 1e-9)
        XCTAssertEqual(background.topGreen, 0.14, accuracy: 1e-9)
        XCTAssertEqual(background.topBlue, 0.18, accuracy: 1e-9)
        XCTAssertEqual(settings.showsGrid, false)

        // Provenance: digest, ordered legacy→body mapping and original bytes.
        let legacy = try XCTUnwrap(settings.legacy)
        XCTAssertEqual(legacy.sceneDigest, String(repeating: "a", count: 64))
        XCTAssertEqual(legacy.legacyObjectIDs, payload.objects.map(\.id))
        XCTAssertEqual(legacy.bodyIDs, payload.objects.map(\.id))
        XCTAssertEqual(legacy.originalSceneJSON, payload.sourceSceneJSON)
        // The disclosure list survives the save/reopen round trip.
        XCTAssertEqual(legacy.visualApproximations,
                       [.lightingIntensityNormalized, .planarGroundShadow])
    }

    // MARK: Editor / viewport consumption (no Metal needed)

    func testEditorConsumesImportedPresentation() async throws {
        let (document, _) = try await makeDocument(name: "Presentation")
        defer { document.close() }
        _ = try document.importLegacyScene(scene(objects: [object(kind: .box)],
                                                 showsGrid: false))
        let model = document.viewModel()
        let settings = try XCTUnwrap(model.sceneSettings)
        XCTAssertEqual(settings.camera?.azimuthRadians, 38 * Double.pi / 180)

        // The scene the renderer draws carries the appearance + grid flag.
        let viewportScene = model.scene
        XCTAssertNotNil(viewportScene.appearance)
        XCTAssertEqual(viewportScene.showsGrid, false)
        // The legacy shadow flag reaches the renderer's ground-shadow pass.
        XCTAssertTrue(viewportScene.groundShadow)

        // The opening camera is the authored legacy camera.
        let opening = try XCTUnwrap(model.savedSceneCamera)
        XCTAssertEqual(opening.azimuth, Float(38 * Double.pi / 180), accuracy: 1e-6)
        XCTAssertEqual(opening.elevation, Float(22 * Double.pi / 180), accuracy: 1e-6)
        XCTAssertEqual(opening.distance, 6500, accuracy: 1e-3)
    }

    func testTurntableCameraMapping() throws {
        let saved = CADSceneSettings.Camera(
            azimuthRadians: 0.5, elevationRadians: 0.25, distance: 1234,
            targetX: 1, targetY: 2, targetZ: 3, fovYDegrees: 48, isOrthographic: true)
        let camera = Renderer.turntableCamera(from: saved)
        XCTAssertEqual(camera.azimuth, 0.5, accuracy: 1e-6)
        XCTAssertEqual(camera.elevation, 0.25, accuracy: 1e-6)
        XCTAssertEqual(camera.distance, 1234, accuracy: 1e-3)
        XCTAssertEqual(camera.target, SIMD3<Float>(1, 2, 3))
        if case .orthographic = camera.projection {} else {
            XCTFail("orthographic projection must be preserved")
        }
    }

    // MARK: Scale normalisation bounds

    func testLightIntensityNormalisationIsBounded() throws {
        var payload = scene(objects: [])
        payload.lighting = CADLegacyScene.Lighting(
            keyIntensity: 28_000 * 5, fillIntensity: 0, castsShadows: false)
        let settings = FloeCADDocument.sceneSettings(from: payload)
        let lighting = try XCTUnwrap(settings.lighting)
        XCTAssertEqual(lighting.keyIntensityScale, 4, accuracy: 1e-9,
                       "intensity scale is bounded, not silently huge")
        XCTAssertEqual(lighting.fillIntensityScale, 0, accuracy: 1e-9)
    }
}
