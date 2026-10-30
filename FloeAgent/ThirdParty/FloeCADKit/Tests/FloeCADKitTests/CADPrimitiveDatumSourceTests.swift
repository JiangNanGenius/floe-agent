import Foundation
import XCTest
import simd
@testable import FloeCAD

/// M07 follow-up — primitive named planar sources for associative datums.
///
/// Every fixture uses the production replay/naming path and a real OCCT box
/// (or cylinder) BRep. These tests never fabricate a kernel-name map and never
/// assume that a Euclid render triangle, face-table row, or `FaceTopology`
/// entry index is an OCCT face index.
@MainActor
final class CADPrimitiveDatumSourceTests: XCTestCase {
    private var revision: UInt64 = 0

    override func setUp() async throws {
        revision = 0
        XCTAssertTrue(OCCTKernel.useOCCTAsSourceOfTruth)
    }

    override func tearDown() async throws {}

    private struct Fixture {
        var graph: FeatureGraph
        var sketches: [Sketch]
        var planes: [ConstructionPlane]
        var plate: FeatureNode
        var plateBody: BodyID
        var boxNode: FeatureNode
        var boxBody: BodyID
        var boxSpec: PrimitiveSpec
        var boxPlacement: Transform3D
        var boxWriter: FeatureID
        var child: FeatureNode
        var childBody: BodyID
        var childSketch: SketchID
        var datum: ConstructionPlaneID { planes[0].id }
        var version: GeometryVersionRef {
            GeometryVersionRef(bodyID: boxBody, writer: boxWriter)
        }
    }

    private func nextRevision() -> UInt64 {
        revision += 1
        return revision
    }

    private func extrusion(_ sketch: Sketch, distance: Double,
                           body: BodyID = BodyID(), name: String) -> FeatureNode {
        FeatureNode(name: name, kind: .extrude(
            profile: ProfileRef(sketchID: sketch.id,
                                entityIDs: sketch.entities.map(\.id),
                                holeEntityIDs: [], seedPoint: .zero),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: distance),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [body])
    }

    /// A prior named OCCT extrude, then a primitive box, then an associative
    /// offset datum on the box's real top face and a child extrusion on a
    /// sketch supported by that datum.
    private func makeFixture(transform: Transform3D? = nil,
                             placement: Transform3D = .identity,
                             width: Double = 40, depth: Double = 30,
                             height: Double = 10) throws -> Fixture {
        let plateSketch = Sketch(name: "Plate profile", plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(100, 60))
        ])
        let plateBody = BodyID()
        let plate = extrusion(plateSketch, distance: 10, body: plateBody, name: "Plate")

        let spec = PrimitiveSpec.box(width: width, depth: depth, height: height)
        let boxBody = BodyID()
        let boxNode = FeatureNode(name: "Source box", kind: .primitive(
            spec: spec, placement: placement), outputBodyIDs: [boxBody])

        // Mint the source reference from the production replay, exactly as a
        // pick would: the face table's name for the real OCCT top face.
        let seed = FeatureGraph(nodes: [plate, boxNode]).evaluate(
            sketches: [plateSketch], planes: [], naming: SignatureNaming(),
            nextRevision: nextRevision)
        XCTAssertTrue(seed.errors.isEmpty)
        let boxBRep = try XCTUnwrap(seed.bodies.first { $0.id == boxBody }?.brep)
        let top = try XCTUnwrap(OCCTKernel.faceInfo(boxBRep).first { $0.normal.y > 0.99 })
        let topName = try XCTUnwrap(seed.kernelNames[boxBody]?[top.index])
        XCTAssertEqual(topName, ElementName(creator: boxNode.id,
                                            source: .primitiveFace(.boxFace(.py))))
        let faceRef = FaceRef(
            body: BodyRef(producer: boxNode.id, bodyID: boxBody),
            creator: boxNode.id,
            role: .boxFace(.py),
            signature: try XCTUnwrap(top.signature),
            elementName: topName)
        let frame = try PlaneAttachmentFrame.make(
            faceCentroid: top.centroid, faceNormal: top.normal,
            referenceXAxis: SIMD3(1, 0, 0), anchorPoint: top.centroid)

        var nodes = [plate, boxNode]
        var writer = boxNode.id
        if let transform {
            let moved = FeatureNode(name: "Source placement", kind: .transform(
                body: BodyRef(producer: boxNode.id, bodyID: boxBody), delta: transform),
                outputBodyIDs: [BodyID()])
            nodes.append(moved)
            writer = moved.id
        }
        let definition = OffsetPlaneDefinition(
            source: faceRef,
            sourceVersion: GeometryVersionRef(bodyID: boxBody, writer: writer),
            distance: Expr(value: 5), attachment: frame)
        // Deliberately wrong display caches must never be solve authority.
        let datum = ConstructionPlane(plane: .offsetGround(y: -999), size: 120,
                                      definition: .offset(definition))
        let supported = Sketch(name: "Supported profile", plane: .offsetGround(y: -888),
                               entities: [.rect(id: UUID(), min: SIMD2(-2, -1),
                                                max: SIMD2(2, 1))],
                               support: PlaneRef(source: .construction(datum.id)))
        let childBody = BodyID()
        let child = extrusion(supported, distance: 3, body: childBody,
                              name: "Supported prism")
        nodes.append(child)
        return Fixture(graph: FeatureGraph(nodes: nodes),
                       sketches: [plateSketch, supported], planes: [datum],
                       plate: plate, plateBody: plateBody,
                       boxNode: boxNode, boxBody: boxBody,
                       boxSpec: spec, boxPlacement: placement, boxWriter: writer,
                       child: child, childBody: childBody,
                       childSketch: supported.id)
    }

    private func evaluate(_ fixture: Fixture, cache: inout EvalCache) -> EvalResult {
        fixture.graph.evaluate(sketches: fixture.sketches, planes: fixture.planes,
                               naming: SignatureNaming(), nextRevision: nextRevision,
                               cache: &cache)
    }

    private func changingHeight(_ fixture: Fixture, to height: Double) -> Fixture {
        var result = fixture
        guard let index = result.graph.index(of: fixture.boxNode.id) else {
            XCTFail("missing box feature")
            return fixture
        }
        guard case let .box(width, depth, _) = fixture.boxSpec else {
            XCTFail("fixture is not a box")
            return fixture
        }
        result.graph.nodes[index].kind = .primitive(
            spec: .box(width: width, depth: depth, height: height),
            placement: fixture.boxPlacement)
        return result
    }

    private func bounds(_ body: Body) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .infinity)
        var hi = SIMD3<Double>(repeating: -.infinity)
        for local in body.render.positions {
            let point = body.transform.applying(to: SIMD3<Double>(local))
            lo = simd_min(lo, point)
            hi = simd_max(hi, point)
        }
        return (lo, hi)
    }

    private func topFaceName(_ result: EvalResult, bodyID: BodyID) throws -> ElementName {
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        let face = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(body.brep)).first {
            $0.normal.y > 0.99
        })
        return try XCTUnwrap(result.kernelNames[bodyID]?[face.index])
    }

    private func assertPrism(_ result: EvalResult, fixture: Fixture, bottom: Double,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)", file: file, line: line)
        XCTAssertTrue(result.referenceErrors.isEmpty, "\(result.referenceErrors)",
                      file: file, line: line)
        let body = try XCTUnwrap(result.bodies.first { $0.id == fixture.childBody },
                                 file: file, line: line)
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(body.brep, file: file, line: line)),
                       24, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(bounds(body).min.y, bottom, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(bounds(body).max.y, bottom + 3, accuracy: 1e-4, file: file, line: line)
        let plane = try XCTUnwrap(result.resolvedPlaneUpdates[fixture.datum],
                                  file: file, line: line)
        XCTAssertEqual(plane.origin.y, bottom, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(simd_length(plane.normal - SIMD3<Double>(0, 1, 0)), 0,
                       accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(result.resolvedSketchSupportUpdates[fixture.childSketch],
                                     file: file, line: line).origin.y,
                       bottom, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(result.lastBodyWriters[fixture.boxBody], fixture.boxWriter,
                       file: file, line: line)
    }

    private func replacing(_ definition: OffsetPlaneDefinition,
                           elementName: ElementName?) -> OffsetPlaneDefinition {
        var source = definition.source
        source.elementName = elementName
        return OffsetPlaneDefinition(version: definition.version, source: source,
                                     sourceVersion: definition.sourceVersion,
                                     distance: definition.distance,
                                     attachment: definition.attachment)
    }

    // MARK: - Kernel face map

    func testBoxPrimitivePublishesEveryPlanarKernelFaceExactly() async throws {
        let fixture = try makeFixture()
        var cache = EvalCache()
        let result = evaluate(fixture, cache: &cache)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")

        let body = try XCTUnwrap(result.bodies.first { $0.id == fixture.boxBody })
        XCTAssertEqual(body.primitive, .box(width: 40, depth: 30, height: 10))
        let brep = try XCTUnwrap(body.brep)
        let faces = Dictionary(uniqueKeysWithValues:
            OCCTKernel.faceInfo(brep).map { ($0.index, $0) })
        XCTAssertEqual(faces.count, 6)

        let names = try XCTUnwrap(result.kernelNames[fixture.boxBody])
        XCTAssertEqual(names.count, 6)
        XCTAssertEqual(Set(names.keys), Set(1...6))
        XCTAssertEqual(Set(names.values).count, 6,
                       "each planar kernel face must own one distinct role")

        let expected: [BoxFace: (normal: SIMD3<Double>, area: Double)] = [
            .px: (SIMD3(1, 0, 0), 10 * 30),
            .nx: (SIMD3(-1, 0, 0), 10 * 30),
            .py: (SIMD3(0, 1, 0), 40 * 30),
            .ny: (SIMD3(0, -1, 0), 40 * 30),
            .pz: (SIMD3(0, 0, 1), 40 * 10),
            .nz: (SIMD3(0, 0, -1), 40 * 10)
        ]
        for (index, name) in names {
            let face = try XCTUnwrap(faces[index])
            guard case let .primitiveFace(.boxFace(role)) = name.source else {
                return XCTFail("name \(name) for kernel face \(index) is not a box role")
            }
            XCTAssertEqual(name.creator, fixture.boxNode.id)
            let want = try XCTUnwrap(expected[role])
            XCTAssertGreaterThan(simd_dot(face.normal, want.normal), 0.999999,
                                 "kernel face \(index) is not the \(role) face")
            XCTAssertEqual(face.area, want.area, accuracy: 1e-6)
            XCTAssertEqual(try XCTUnwrap(face.signature).kind,
                           FaceSignature.Kind.planar)
        }

        // The +Y role is the real top face, and the render-side table carries
        // the same name for that face — the identity the UI mints.
        let top = try XCTUnwrap(faces.values.first { $0.normal.y > 0.999 })
        let topName = ElementName(creator: fixture.boxNode.id,
                                  source: .primitiveFace(.boxFace(.py)))
        XCTAssertEqual(names[top.index], topName)
        XCTAssertEqual(try topFaceName(result, bodyID: fixture.boxBody), topName)
        let table = try XCTUnwrap(result.faceTables[fixture.boxBody])
        XCTAssertEqual(table.entries.filter { $0.elementName == topName }.count, 1)
    }

    // MARK: - Datum resolution + cache

    func testBoxDatumIsColdHotEqualAndFollowsDimensionEdits() async throws {
        let fixture = try makeFixture()
        var cache = EvalCache()
        let cold = evaluate(fixture, cache: &cache)
        try assertPrism(cold, fixture: fixture, bottom: 15)
        let boxNames = try XCTUnwrap(cold.kernelNames[fixture.boxBody])
        let plateNames = try XCTUnwrap(cold.kernelNames[fixture.plateBody])
        XCTAssertEqual(plateNames.count, 6, "prior named extrude source baseline")
        let plateStamp = cache.entries[fixture.plate.id]?.fingerprint

        let hot = evaluate(fixture, cache: &cache)
        XCTAssertEqual(cache.lastRan, 0)
        XCTAssertEqual(cache.lastSkipped, fixture.graph.nodes.count)
        try assertPrism(hot, fixture: fixture, bottom: 15)
        XCTAssertEqual(hot.resolvedPlaneUpdates, cold.resolvedPlaneUpdates)
        XCTAssertEqual(hot.kernelNames[fixture.boxBody], boxNames)

        let changed = changingHeight(fixture, to: 20)
        let incremental = evaluate(changed, cache: &cache)
        XCTAssertEqual(cache.lastRan, 2, "box and its dependent prism must rebuild")
        XCTAssertEqual(cache.lastSkipped, 1, "the unrelated prior extrude stays cached")
        XCTAssertEqual(cache.entries[changed.plate.id]?.fingerprint, plateStamp)
        try assertPrism(incremental, fixture: changed, bottom: 25)
        XCTAssertEqual(incremental.kernelNames[changed.plateBody], plateNames,
                       "unrelated named extrude source and its map are untouched")
        XCTAssertEqual(incremental.lastBodyWriters[changed.plateBody], changed.plate.id)
        let changedBoxNames = try XCTUnwrap(incremental.kernelNames[changed.boxBody])
        XCTAssertEqual(changedBoxNames.count, 6)
        XCTAssertEqual(Set(changedBoxNames.values), Set(boxNames.values),
                       "a dimension edit keeps the same primitive face identities")
        XCTAssertEqual(try topFaceName(incremental, bodyID: changed.boxBody),
                       ElementName(creator: changed.boxNode.id,
                                   source: .primitiveFace(.boxFace(.py))))

        var empty = EvalCache()
        let rebuilt = evaluate(changed, cache: &empty)
        try assertPrism(rebuilt, fixture: changed, bottom: 25)
        XCTAssertEqual(incremental.resolvedPlaneUpdates, rebuilt.resolvedPlaneUpdates)
        XCTAssertEqual(incremental.resolvedSketchSupportUpdates,
                       rebuilt.resolvedSketchSupportUpdates)
        let a = try XCTUnwrap(incremental.bodies.first { $0.id == changed.childBody })
        let b = try XCTUnwrap(rebuilt.bodies.first { $0.id == changed.childBody })
        XCTAssertEqual(bounds(a).min, bounds(b).min)
        XCTAssertEqual(bounds(a).max, bounds(b).max)
        guard case let .offset(definition)? = changed.planes[0].definition else {
            return XCTFail("fixture lost its datum definition")
        }
        XCTAssertEqual(definition.distance.value, 5,
                       "pure replay must not rewrite the stored offset")
        XCTAssertEqual(definition.sourceVersion, fixture.version)
    }

    // MARK: - Transformed source

    func testTransformedBoxSourceUsesActualWriterAndWorldMillimetreOffset() async throws {
        let rotation = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        let transform = Transform3D(translation: SIMD3(10, 20, 30),
                                    rotation: rotation, scale: 2)
        let fixture = try makeFixture(transform: transform)
        XCTAssertNotEqual(fixture.version.writer, fixture.boxNode.id,
                          "the frozen version must name the actual writer PUT")
        var cache = EvalCache()
        let cold = evaluate(fixture, cache: &cache)
        XCTAssertTrue(cold.errors.isEmpty, "\(cold.errors)")
        XCTAssertTrue(cold.referenceErrors.isEmpty, "\(cold.referenceErrors)")

        let snapshot = try XCTUnwrap(cold.geometryVersions[fixture.version])
        XCTAssertEqual(snapshot.body.id, fixture.boxBody)
        XCTAssertEqual(snapshot.body.transform, transform)
        XCTAssertEqual(snapshot.kernelNames.count, 6)
        XCTAssertEqual(cold.lastBodyWriters[fixture.boxBody], fixture.boxWriter)

        // Local top centroid (0,10,0), scale 2 -> (0,20,0), rotate 90° about
        // Z -> (-20,0,0), translate -> (-10,20,30); then 5 world mm along the
        // rotated +Y normal (-1,0,0). The offset is never scaled twice.
        let plane = try XCTUnwrap(cold.resolvedPlaneUpdates[fixture.datum])
        XCTAssertEqual(plane.origin.x, -15, accuracy: 1e-6)
        XCTAssertEqual(plane.origin.y, 20, accuracy: 1e-6)
        XCTAssertEqual(plane.origin.z, 30, accuracy: 1e-6)
        XCTAssertEqual(simd_length(plane.normal - SIMD3<Double>(-1, 0, 0)), 0,
                       accuracy: 1e-8)
        let child = try XCTUnwrap(cold.bodies.first { $0.id == fixture.childBody })
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(child.brep)), 24, accuracy: 1e-5)
        XCTAssertEqual(bounds(child).min.x, -18, accuracy: 1e-4)
        XCTAssertEqual(bounds(child).max.x, -15, accuracy: 1e-4)

        let hot = evaluate(fixture, cache: &cache)
        XCTAssertEqual(cache.lastRan, 0)
        XCTAssertEqual(cache.lastSkipped, fixture.graph.nodes.count)
        XCTAssertEqual(hot.resolvedPlaneUpdates, cold.resolvedPlaneUpdates)
        XCTAssertEqual(hot.resolvedSketchSupportUpdates,
                       cold.resolvedSketchSupportUpdates)
    }

    // MARK: - Refusal

    func testPrimitiveDatumRefusesUnprovenMappingsWithoutMeshFallback() async throws {
        let fixture = try makeFixture()
        var validCache = EvalCache()
        try assertPrism(evaluate(fixture, cache: &validCache), fixture: fixture, bottom: 15)
        guard case let .offset(valid)? = fixture.planes[0].definition,
              let validName = valid.source.elementName else {
            return XCTFail("fixture has no valid named datum")
        }

        enum Mode: String {
            case noName, kernelIndex, foreignCreator, unmappedName
        }
        let modes: [Mode] = [.noName, .kernelIndex, .foreignCreator, .unmappedName]
        for mode in modes {
            let name: ElementName?
            switch mode {
            case .noName:
                name = nil
            case .kernelIndex:
                name = ElementName(creator: valid.source.creator,
                                   source: .kernelFace(index: 1))
            case .foreignCreator:
                name = ElementName(creator: FeatureID(),
                                   source: .primitiveFace(.boxFace(.py)))
            case .unmappedName:
                name = ElementName(creator: fixture.boxNode.id,
                                   source: .opFace(operation: fixture.boxNode.id,
                                                   parents: [validName], index: 0))
            }
            var changed = fixture
            changed.planes[0].definition = .offset(replacing(valid, elementName: name))
            var fresh = EvalCache()
            let result = evaluate(changed, cache: &fresh)
            XCTAssertFalse(result.bodies.contains { $0.id == fixture.childBody },
                           "\(mode.rawValue): unnamed/unmapped primitive sources must not build")
            XCTAssertNil(result.resolvedPlaneUpdates[fixture.datum],
                         "\(mode.rawValue): no mesh or nearest-face fallback")
            switch mode {
            case .noName, .kernelIndex:
                XCTAssertTrue(result.referenceErrors.values.contains(
                    .exactNamedPlaneRequired(fixture.version)),
                    "\(mode.rawValue): \(result.referenceErrors)")
            case .foreignCreator, .unmappedName:
                XCTAssertTrue(result.referenceErrors.values.contains(
                    .missingNamedFace(fixture.version)),
                    "\(mode.rawValue): \(result.referenceErrors)")
            }
            XCTAssertEqual(changed.planes[0].definition,
                           ConstructionPlaneDefinition.offset(replacing(valid, elementName: name)),
                           "\(mode.rawValue): pure evaluation must not rewrite the definition")
        }
    }

    // MARK: - Baked placement

    func testThinBoxAtLargeTranslationKeepsExactConstructionFaceNames() async throws {
        // A thin box far from the origin stresses any tolerance/signature
        // approach: the render signature's float centroid and area no longer
        // match the kernel's doubles closely in relative terms. Construction
        // face identity does not care. A pure translation preserves every
        // local face normal axis, so the names stay supported.
        let placement = Transform3D(
            translation: SIMD3(1_000_000.5, -2_000_000.25, 3_000_000.75),
            rotation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1),
            scale: 1)
        let fixture = try makeFixture(placement: placement, height: 1)
        var cache = EvalCache()
        let cold = evaluate(fixture, cache: &cache)
        let body = try XCTUnwrap(cold.bodies.first { $0.id == fixture.boxBody })
        let brep = try XCTUnwrap(body.brep)
        let faces = OCCTKernel.faceInfo(brep)
        XCTAssertEqual(faces.count, 6)
        let names = try XCTUnwrap(cold.kernelNames[fixture.boxBody])
        XCTAssertEqual(names.count, 6)
        let expected: [BoxFace: (normal: SIMD3<Double>, area: Double)] = [
            .px: (SIMD3(1, 0, 0), 1 * 30),
            .nx: (SIMD3(-1, 0, 0), 1 * 30),
            .py: (SIMD3(0, 1, 0), 40 * 30),
            .ny: (SIMD3(0, -1, 0), 40 * 30),
            .pz: (SIMD3(0, 0, 1), 40 * 1),
            .nz: (SIMD3(0, 0, -1), 40 * 1)
        ]
        for (index, name) in names {
            let face = try XCTUnwrap(faces.first { $0.index == index })
            guard case let .primitiveFace(.boxFace(role)) = name.source else {
                return XCTFail("name \(name) is not a box construction role")
            }
            let want = try XCTUnwrap(expected[role])
            XCTAssertGreaterThan(simd_dot(face.normal, want.normal), 0.999999)
            XCTAssertEqual(face.area, want.area, accuracy: 1e-3)
        }
        // The world top is the local YMax (RightFace) role, 2 million mm away.
        let top = try XCTUnwrap(faces.first { $0.normal.y > 0.999 })
        XCTAssertEqual(names[top.index],
                       ElementName(creator: fixture.boxNode.id,
                                   source: .primitiveFace(.boxFace(.py))))
        XCTAssertEqual(top.centroid.y, placement.translation.y + 1, accuracy: 1e-5)
        try assertPrism(cold, fixture: fixture, bottom: placement.translation.y + 1 + 5)

        // A parameter edit must keep the same six identities and still move
        // the datum/child, with no tolerance re-decision in between.
        let changed = changingHeight(fixture, to: 3)
        let incremental = evaluate(changed, cache: &cache)
        let changedNames = try XCTUnwrap(incremental.kernelNames[changed.boxBody])
        XCTAssertEqual(Set(changedNames.values), Set(names.values),
                       "height edit must not rename or drop construction faces")
        try assertPrism(incremental, fixture: changed,
                        bottom: placement.translation.y + 3 + 5)
    }

    func testRotatedBakedBoxPlacementRefusesInventedLocalRoles() async throws {
        // SignatureNaming labels a primitive's render faces by strongest WORLD
        // axis; the maker's named faces are LOCAL construction roles. A baked
        // rotation makes those two role systems disagree (here a 90° Y turn
        // permutes X/Z), so association is refused rather than re-labelled.
        let placement = Transform3D(
            translation: SIMD3(3, 4, 5),
            rotation: simd_quatd(angle: .pi / 2, axis: SIMD3(0, 1, 0)),
            scale: 1.5)
        let bodyID = BodyID()
        let node = FeatureNode(name: "Placed box", kind: .primitive(
            spec: .box(width: 40, depth: 30, height: 10), placement: placement),
            outputBodyIDs: [bodyID])
        let graph = FeatureGraph(nodes: [node])
        var cache = EvalCache()
        let result = graph.evaluate(sketches: [], planes: [], naming: SignatureNaming(),
                                    nextRevision: nextRevision, cache: &cache)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        XCTAssertNil(body.primitive, "a non-identity placement is baked, not parametric")
        XCTAssertNotNil(body.brep)
        let table = try XCTUnwrap(result.faceTables[bodyID])
        XCTAssertEqual(table.entries.filter { $0.elementName != nil }.count, 6,
                       "the render-side table still carries its world-axis labels")
        XCTAssertNil(result.kernelNames[bodyID],
                     "no exact kernel map is invented for a rotated baked placement")

        // A datum minted from one of those render-side names must therefore
        // report a missing named face instead of binding by geometry.
        let top = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(body.brep))
            .first { $0.normal.y > 0.999 })
        let tableName = try XCTUnwrap(table.entries.first {
            if case .boxFace(.py) = $0.role { return true }
            return false
        }?.elementName)
        let ref = FaceRef(body: BodyRef(producer: node.id, bodyID: bodyID),
                          creator: node.id, role: .boxFace(.py),
                          signature: try XCTUnwrap(top.signature),
                          elementName: tableName)
        let frame = try PlaneAttachmentFrame.make(
            faceCentroid: top.centroid, faceNormal: top.normal,
            referenceXAxis: SIMD3(1, 0, 0), anchorPoint: top.centroid)
        let definition = OffsetPlaneDefinition(source: ref,
            sourceVersion: GeometryVersionRef(bodyID: bodyID, writer: node.id),
            distance: Expr(value: 5), attachment: frame)
        let datum = ConstructionPlane(plane: .offsetGround(y: -999), size: 120,
                                      definition: .offset(definition))
        let supported = Sketch(name: "Unsupported", plane: .offsetGround(y: -888),
                               entities: [.rect(id: UUID(), min: SIMD2(-2, -1),
                                                max: SIMD2(2, 1))],
                               support: PlaneRef(source: .construction(datum.id)))
        let childBody = BodyID()
        let child = extrusion(supported, distance: 3, body: childBody, name: "Refused")
        let withChild = FeatureGraph(nodes: [node, child])
        let evaluated = withChild.evaluate(sketches: [supported], planes: [datum],
                                           naming: SignatureNaming(),
                                           nextRevision: nextRevision, cache: &cache)
        XCTAssertFalse(evaluated.bodies.contains { $0.id == childBody })
        XCTAssertTrue(evaluated.referenceErrors.values.contains(
            .missingNamedFace(GeometryVersionRef(bodyID: bodyID, writer: node.id))),
            "\(evaluated.referenceErrors)")
    }

    // MARK: - Curved primitive regression

    func testRotatedBakedCylinderRefusesWorldRoleNamesButKeepsDisplayRoles() async throws {
        // Cylinder cap roles are also assigned from the baked frame (fitted
        // axis + cap order), so a baked rotation must not be claimed as a
        // stable local construction identity. Display roles stay as they are;
        // only exact named association is withheld.
        let placement = Transform3D(
            translation: SIMD3(10, 20, 30),
            rotation: simd_quatd(angle: .pi / 2, axis: SIMD3(1, 0, 0)),
            scale: 1.5)
        let bodyID = BodyID()
        let node = FeatureNode(name: "Rotated cylinder", kind: .primitive(
            spec: .cylinder(radius: 5, height: 10), placement: placement),
            outputBodyIDs: [bodyID])
        let graph = FeatureGraph(nodes: [node])
        var cache = EvalCache()
        let result = graph.evaluate(sketches: [], planes: [], naming: SignatureNaming(),
                                    nextRevision: nextRevision, cache: &cache)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        XCTAssertNotNil(body.brep)
        let table = try XCTUnwrap(result.faceTables[bodyID])
        XCTAssertFalse(table.entries.isEmpty)
        XCTAssertEqual(table.entries.filter { $0.elementName != nil }.count,
                       table.entries.count, "display roles remain named")
        XCTAssertTrue(table.entries.contains {
            if case .cylinderCap = $0.role { return true }
            return false
        })
        XCTAssertNil(result.kernelNames[bodyID],
                     "a baked rotation must not claim world-derived cap roles as stable names")
    }


    func testCurvedPrimitiveStillUsesTheTessellationChannel() async throws {
        let bodyID = BodyID()
        let node = FeatureNode(name: "Cylinder", kind: .primitive(
            spec: .cylinder(radius: 5, height: 10), placement: .identity),
            outputBodyIDs: [bodyID])
        let graph = FeatureGraph(nodes: [node])
        var cache = EvalCache()
        let result = graph.evaluate(sketches: [], planes: [], naming: SignatureNaming(),
                                    nextRevision: nextRevision, cache: &cache)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        let body = try XCTUnwrap(result.bodies.first { $0.id == bodyID })
        let faces = OCCTKernel.faceInfo(try XCTUnwrap(body.brep))
        let names = try XCTUnwrap(result.kernelNames[bodyID])
        XCTAssertEqual(names.count, faces.count,
                       "each cylinder kernel face has a channel-derived name")
        var caps = 0
        for (index, name) in names {
            let face = try XCTUnwrap(faces.first { $0.index == index })
            switch name.source {
            case let .primitiveFace(.cylinderCap(top)):
                caps += 1
                XCTAssertEqual(face.normal.y > 0.99, top)
                XCTAssertEqual(try XCTUnwrap(face.signature).kind,
                               FaceSignature.Kind.planar)
            case .primitiveFace(.cylinderSide):
                guard case let .cylindrical(radius)? = face.signature?.kind else {
                    return XCTFail("cylinder side \(index) is not cylindrical")
                }
                XCTAssertEqual(radius, 5, accuracy: 1e-9)
            default:
                XCTFail("unexpected curved-primitive name \(name)")
            }
        }
        XCTAssertEqual(caps, 2)
    }
}
