// FloeCoreTests — legacy 3D scene → unified CAD migration contract.
//
// Pure host-runnable coverage of the migration gate: representability, the
// stable canonical digest, colour parsing, the node state classifier and the
// persisted marker's forward compatibility.
import Foundation
import Testing
@testable import FloeCore

@Suite("Legacy scene migration")
struct LegacySceneMigrationTests {

    private func object(
        id: UUID = UUID(), name: String = "Cube", kind: CanvasSceneObjectKind = .box,
        position: CanvasVector3 = .init(x: 0, y: 0.6, z: 0),
        rotation: CanvasVector3 = .zero,
        scale: CanvasVector3 = .one,
        colorHex: String = "#5B8DEF",
        roughness: Double = 0.35, metallic: Bool = false, isHidden: Bool = false
    ) -> CanvasSceneObject {
        CanvasSceneObject(id: id, name: name, kind: kind, position: position,
                          rotation: rotation, scale: scale, colorHex: colorHex,
                          roughness: roughness, metallic: metallic, isHidden: isHidden)
    }

    private func scene(id: UUID = UUID(),
                       objects: [CanvasSceneObject]? = nil,
                       camera: CanvasSceneCamera = .init(),
                       lighting: CanvasSceneLighting = .init(),
                       background: CanvasSceneBackground = .studio,
                       showsGrid: Bool = true) -> CanvasScene3D {
        // `id` and `updatedAt` are part of the canonical scene bytes, so both
        // are pinned here: "equal scene values" must mean EXACTLY equal.
        CanvasScene3D(id: id, objects: objects ?? [object()], camera: camera,
                      lighting: lighting, background: background, showsGrid: showsGrid,
                      updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    // MARK: Representability

    @Test("the known legacy schema is fully representable for all five primitives")
    func allPrimitivesRepresentable() {
        let scene = scene(objects: CanvasSceneObjectKind.allCases.map {
            object(name: $0.rawValue, kind: $0)
        })
        let evaluation = LegacySceneMigration.evaluate(scene)
        #expect(evaluation.isFullyRepresentable)
        #expect(evaluation.reasons.isEmpty)
        #expect(evaluation.objectCount == 5)
    }

    @Test("a hidden object, nonuniform scale and rotated placement are representable")
    func placementAndNonuniformScaleRepresentable() {
        let evaluation = LegacySceneMigration.evaluate(scene(objects: [
            object(position: .init(x: -1.2, y: 2.5, z: 0.4),
                   rotation: .init(x: 10, y: -35.5, z: 179),
                   scale: .init(x: 0.25, y: 3.5, z: 1.75),
                   metallic: true, isHidden: true)
        ]))
        #expect(evaluation.isFullyRepresentable)
    }

    @Test("non-finite position/rotation/scale/roughness each refuse")
    func nonFiniteValuesRefuse() {
        let cases = [
            object(position: .init(x: .nan, y: 0, z: 0)),
            object(rotation: .init(x: 0, y: .infinity, z: 0)),
            object(scale: .init(x: .nan, y: 1, z: 1)),
            object(roughness: .nan),
        ]
        for candidate in cases {
            let evaluation = LegacySceneMigration.evaluate(scene(objects: [candidate]))
            #expect(!evaluation.isFullyRepresentable)
            #expect(evaluation.reasons.contains { $0.issue == .nonFiniteValue })
        }
    }

    @Test("zero and negative scale refuse; extreme scale refuses with its own code")
    func scaleBoundsRefuse() {
        let zero = LegacySceneMigration.evaluate(scene(objects: [
            object(scale: .init(x: 1, y: 0, z: 1))
        ]))
        #expect(zero.reasons.contains { $0.issue == .nonPositiveScale })
        let negative = LegacySceneMigration.evaluate(scene(objects: [
            object(scale: .init(x: -1, y: 1, z: 1))
        ]))
        #expect(negative.reasons.contains { $0.issue == .nonPositiveScale })
        let extreme = LegacySceneMigration.evaluate(scene(objects: [
            object(scale: .init(x: 20_000, y: 1, z: 1))
        ]))
        #expect(extreme.reasons.contains { $0.issue == .scaleOutOfRange })
    }

    @Test("an unparsable color refuses; all accepted hex forms pass")
    func colorValidation() {
        let bad = LegacySceneMigration.evaluate(scene(objects: [object(colorHex: "blue")]))
        #expect(bad.reasons.contains { $0.issue == .invalidColorHex })
        for hex in ["#5B8DEF", "#5B8DEF80", "5B8DEF", "#39C"] {
            let evaluation = LegacySceneMigration.evaluate(scene(objects: [object(colorHex: hex)]))
            #expect(evaluation.isFullyRepresentable, "\(hex) must parse")
        }
    }

    @Test("camera and lighting bounds refuse with precise field names")
    func cameraAndLightingValidation() {
        let badDistance = LegacySceneMigration.evaluate(scene(objects: nil, camera: .init(distance: 0)))
        #expect(badDistance.reasons.contains { $0.field == "camera.distance" })
        let badFov = LegacySceneMigration.evaluate(scene(objects: nil, camera: .init(fieldOfView: 0)))
        #expect(badFov.reasons.contains { $0.field == "camera.fieldOfView" })
        let badLight = LegacySceneMigration.evaluate(scene(objects: nil, lighting: .init(keyIntensity: -1)))
        #expect(badLight.reasons.contains { $0.issue == .invalidLighting })
    }

    @Test("duplicate object UUIDs refuse before provenance mapping")
    func duplicateIDsRefuse() {
        let id = UUID()
        let evaluation = LegacySceneMigration.evaluate(scene(objects: [
            object(id: id), object(id: id)
        ]))
        #expect(evaluation.reasons.contains { $0.issue == .duplicateObjectID })
    }

    @Test("an empty scene is representable (an empty native document)")
    func emptySceneRepresentable() {
        #expect(LegacySceneMigration.evaluate(scene(objects: [])).isFullyRepresentable)
    }

    // MARK: Canonical digest

    @Test("the canonical digest is stable across equal scene values")
    func digestStable() {
        // Equal INCLUDING the scene id and object ids: the digest identifies
        // exact bytes, so a fresh random UUID is genuinely a different scene.
        let fixedSceneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!
        let fixedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
        let first = LegacySceneMigration.canonicalDigest(
            of: scene(id: fixedSceneID, objects: [object(id: fixedID)]))
        let second = LegacySceneMigration.canonicalDigest(
            of: scene(id: fixedSceneID, objects: [object(id: fixedID)]))
        #expect(first == second)
        #expect(first.count == 64)
        // Digesting the SAME value is trivially stable too.
        let one = scene(id: fixedSceneID, objects: [object()])
        #expect(LegacySceneMigration.canonicalDigest(of: one)
                == LegacySceneMigration.canonicalDigest(of: one))
    }

    @Test("the canonical digest changes with any field/order change")
    func digestSensitive() {
        // Fixed scene + object ids so only the tested field differs.
        let sceneID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B0")!
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!
        let base = LegacySceneMigration.canonicalDigest(
            of: scene(id: sceneID, objects: [object(id: id)]))
        let moved = LegacySceneMigration.canonicalDigest(of: scene(id: sceneID, objects: [
            object(id: id, position: .init(x: 1, y: 0.6, z: 0))
        ]))
        #expect(base != moved)
        let reordered = LegacySceneMigration.canonicalDigest(of: scene(id: sceneID, objects: [
            object(id: id, name: "First"), object(id: id2, name: "Second")
        ]))
        let swapped = LegacySceneMigration.canonicalDigest(of: scene(id: sceneID, objects: [
            object(id: id2, name: "Second"), object(id: id, name: "First")
        ]))
        #expect(reordered != swapped)
    }

    // MARK: Color parsing

    @Test("hex parsing matches the legacy sRGB semantics")
    func hexParsing() throws {
        let six = try #require(LegacySceneMigration.parseColorHex("#3366CC"))
        #expect(abs(six.r - 0x33 / 255.0) < 1e-9)
        #expect(abs(six.g - 0x66 / 255.0) < 1e-9)
        #expect(abs(six.b - 0xCC / 255.0) < 1e-9)
        #expect(six.a == 1)
        let three = try #require(LegacySceneMigration.parseColorHex("#39C"))
        #expect(abs(three.r - 0x33 / 255.0) < 1e-9)
        // 8-digit keeps RGB and full opacity: the legacy renderer ignored alpha.
        let eight = try #require(LegacySceneMigration.parseColorHex("#3366CC80"))
        #expect(abs(eight.r - 0x33 / 255.0) < 1e-9)
        #expect(abs(eight.b - 0xCC / 255.0) < 1e-9)
        #expect(eight.a == 1)
        #expect(LegacySceneMigration.parseColorHex("#12") == nil)
        #expect(LegacySceneMigration.parseColorHex("nope") == nil)
    }

    // MARK: Marker compatibility

    @Test("a marker without schemaVersion decodes as version 1")
    func markerForwardCompatible() throws {
        let legacyJSON = #"{"sceneDigest":"abc","objectCount":3,"migratedAt":0}"#
        let marker = try JSONDecoder().decode(
            LegacySceneMigrationMarker.self, from: Data(legacyJSON.utf8))
        #expect(marker.schemaVersion == 1)
        #expect(marker.sceneDigest == "abc")
        #expect(marker.objectCount == 3)
    }

    @Test("markers round-trip through JSON")
    func markerRoundTrip() throws {
        let marker = LegacySceneMigrationMarker(
            sceneDigest: "digest", objectCount: 2,
            migratedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let data = try JSONEncoder().encode(marker)
        let decoded = try JSONDecoder().decode(LegacySceneMigrationMarker.self, from: data)
        #expect(decoded == marker)
    }

    // MARK: Node classifier

    @Test("node classification: not legacy, unchanged, migrated, conflict")
    func nodeClassifier() throws {
        // A plain node without an embedded scene is not a legacy scene.
        let plain = CanvasNode(kind: .text, text: "hello",
                               position: .init(x: 0, y: 0), size: .init(width: 10, height: 10))
        #expect(plain.legacySceneMigrationState == .notLegacyScene)

        let embedded = scene()
        let legacyNode = CanvasNode(kind: .scene3D, text: "Scene",
                                    position: .init(x: 0, y: 0),
                                    size: .init(width: 420, height: 300),
                                    scene3D: embedded)
        guard case .legacyUnchanged(let classified) = legacyNode.legacySceneMigrationState else {
            Issue.record("expected legacyUnchanged")
            return
        }
        #expect(LegacySceneMigration.canonicalDigest(of: classified)
                == LegacySceneMigration.canonicalDigest(of: embedded))

        // Marker matching the embedded digest → migrated.
        var migrated = legacyNode
        let marker = LegacySceneMigrationMarker(
            sceneDigest: LegacySceneMigration.canonicalDigest(of: embedded),
            objectCount: embedded.objects.count)
        migrated.metadata[CADCanvasNodePlanner.MetadataKeys.legacyMigration] =
            String(data: try JSONEncoder().encode(marker), encoding: .utf8)
        guard case .migrated = migrated.legacySceneMigrationState else {
            Issue.record("expected migrated")
            return
        }

        // Marker with a different digest → conflict, never auto-resolved.
        var conflicting = migrated
        conflicting.scene3D?.objects[0].name = "Edited after migration"
        guard case .conflict = conflicting.legacySceneMigrationState else {
            Issue.record("expected conflict")
            return
        }
    }

    // MARK: Persistence fixtures

    @Test("a migrated node survives the canvas codec round-trip with its embedded original")
    func migratedNodeCodecRoundTrip() throws {
        let fixedID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
        let embedded = scene(objects: [object(id: fixedID, scale: .init(x: 2, y: 1, z: 1.5))])
        let digest = LegacySceneMigration.canonicalDigest(of: embedded)
        let marker = LegacySceneMigrationMarker(
            sceneDigest: digest, objectCount: embedded.objects.count,
            migratedAt: Date(timeIntervalSince1970: 1_700_000_000))

        var node = CanvasNode(
            kind: .scene3D, text: "Scene", position: .init(x: 10, y: 20),
            size: .init(width: 420, height: 300), scene3D: embedded)
        node.kind = .file
        node.asset = CanvasAssetReference(
            id: UUID(), contentHash: String(repeating: "b", count: 64),
            localRelativePath: "Materials/render.png", mimeType: "image/png")
        node.metadata[CADCanvasNodePlanner.MetadataKeys.sourcePath] =
            "canvas-cad:\(UUID().uuidString)/Scene.floecad"
        node.metadata[CADCanvasNodePlanner.MetadataKeys.sourceHash] = String(repeating: "d", count: 64)
        node.metadata[CADCanvasNodePlanner.MetadataKeys.legacyMigration] =
            String(data: try JSONEncoder().encode(marker), encoding: .utf8)

        let document = CanvasDocument(name: "D", nodes: [node])
        let project = CanvasProject(
            id: UUID(), name: "P", documents: [document],
            selectedDocumentID: document.id)
        let data = try CanvasProjectCodec.encode(project)
        let decoded = try CanvasProjectCodec.decode(data)
        let roundTripped = try #require(decoded.documents.first?.nodes.first)

        // The recoverable original survives byte-identically (digest match)
        // and the marker still classifies the node as migrated.
        let original = try #require(roundTripped.scene3D)
        #expect(LegacySceneMigration.canonicalDigest(of: original) == digest)
        #expect(original.objects.first?.scale == CanvasVector3(x: 2, y: 1, z: 1.5))
        guard case .migrated(_, let decodedMarker) = roundTripped.legacySceneMigrationState else {
            Issue.record("marker must survive the codec round-trip")
            return
        }
        #expect(decodedMarker.sceneDigest == digest)
        #expect(CADCanvasNodePlanner.isNativeCADNode(roundTripped))
    }

    @Test("an unmigrated legacy node stays readable through the codec round-trip")
    func unmigratedNodeCodecRoundTrip() throws {
        let embedded = scene(objects: [
            object(name: "Cube", kind: .box),
            object(name: "Ground", kind: .plane, isHidden: true)
        ])
        let node = CanvasNode(
            kind: .scene3D, text: "Legacy", position: .init(x: 5, y: 5),
            size: .init(width: 420, height: 300), scene3D: embedded)
        let document = CanvasDocument(name: "D", nodes: [node])
        let project = CanvasProject(
            id: UUID(), name: "P", documents: [document],
            selectedDocumentID: document.id)
        let decoded = try CanvasProjectCodec.decode(CanvasProjectCodec.encode(project))
        let roundTripped = try #require(decoded.documents.first?.nodes.first)
        guard case .legacyUnchanged(let readable) = roundTripped.legacySceneMigrationState else {
            Issue.record("an unmigrated node must stay legacy-readable")
            return
        }
        #expect(readable.objects.count == 2)
        #expect(readable.objects.last?.isHidden == true)
    }
}
