import Foundation
import XCTest
import simd
@testable import FloeCAD

/// Production OCCT/replay/command tests. No session/storage/UI is simulated;
/// those integrations belong to the following package.
@MainActor
final class CADAssociativeDatumReplayTests: XCTestCase {
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
        var source: FeatureNode
        var sourceBody: BodyID
        var writer: FeatureID
        var child: FeatureNode
        var childBody: BodyID
        var childSketch: SketchID
        var unrelated: FeatureNode
        var datum: ConstructionPlaneID { planes[0].id }
        var version: GeometryVersionRef { GeometryVersionRef(bodyID: sourceBody, writer: writer) }
    }

    private func nextRevision() -> UInt64 {
        revision += 1
        return revision
    }

    private func extrude(_ sketch: Sketch, distance: Double, body: BodyID = BodyID(),
                         name: String) -> FeatureNode {
        FeatureNode(name: name, kind: .extrude(
            profile: ProfileRef(sketchID: sketch.id,
                                entityIDs: sketch.entities.map(\.id),
                                holeEntityIDs: [], seedPoint: .zero),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: distance),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [body])
    }

    private func makeFixture(transform: Transform3D? = nil) throws -> Fixture {
        let base = Sketch(name: "Plate profile", plane: .ground, entities: [
            .rect(id: UUID(), min: SIMD2(0, 0), max: SIMD2(100, 60))
        ])
        let sourceBody = BodyID()
        let source = extrude(base, distance: 10, body: sourceBody, name: "Plate")
        var nodes = [source]
        var writer = source.id
        if let transform {
            let moved = FeatureNode(name: "Source placement", kind: .transform(
                body: BodyRef(producer: source.id, bodyID: sourceBody), delta: transform),
                // Deliberate placeholder: actual writer PUTs sourceBody.
                outputBodyIDs: [BodyID()])
            nodes.append(moved)
            writer = moved.id
        }
        let initial = FeatureGraph(nodes: nodes).evaluate(
            sketches: [base], planes: [], naming: SignatureNaming(), nextRevision: nextRevision)
        XCTAssertTrue(initial.errors.isEmpty)
        let body = try XCTUnwrap(initial.bodies.first { $0.id == sourceBody })
        let brep = try XCTUnwrap(body.brep, "fixture must use the real OCCT solid")
        let face = try XCTUnwrap(OCCTKernel.faceInfo(brep).first { $0.normal.y > 0.99 })
        let signature = try XCTUnwrap(face.signature)
        let name = try XCTUnwrap(initial.kernelNames[sourceBody]?[face.index])
        let ref = FaceRef(body: BodyRef(producer: source.id, bodyID: sourceBody),
                          creator: name.creator, role: .extrudeEndCap,
                          signature: signature, elementName: name)
        let frame = try PlaneAttachmentFrame.make(
            faceCentroid: face.centroid, faceNormal: face.normal,
            referenceXAxis: SIMD3(1, 0, 0), anchorPoint: face.centroid)
        let definition = OffsetPlaneDefinition(
            source: ref, sourceVersion: GeometryVersionRef(bodyID: sourceBody, writer: writer),
            distance: Expr(value: 5), attachment: frame)
        // Deliberately wrong display caches must never be solve authority.
        let datum = ConstructionPlane(plane: .offsetGround(y: -999), size: 120,
                                      definition: .offset(definition))
        let supported = Sketch(name: "Supported profile", plane: .offsetGround(y: -888), entities: [
            .rect(id: UUID(), min: SIMD2(-2, -1), max: SIMD2(2, 1))
        ], support: PlaneRef(source: .construction(datum.id)))
        let childBody = BodyID()
        let child = extrude(supported, distance: 3, body: childBody, name: "Supported prism")
        let unrelated = FeatureNode(name: "Unrelated", kind: .primitive(
            spec: .box(width: 2, depth: 3, height: 4), placement: .identity), outputBodyIDs: [BodyID()])
        nodes += [child, unrelated]
        return Fixture(graph: FeatureGraph(nodes: nodes), sketches: [base, supported], planes: [datum],
                       source: source, sourceBody: sourceBody, writer: writer,
                       child: child, childBody: childBody, childSketch: supported.id,
                       unrelated: unrelated)
    }

    private func evaluate(_ fixture: Fixture, cache: inout EvalCache,
                          variables: [String: Double] = [:]) -> EvalResult {
        fixture.graph.evaluate(sketches: fixture.sketches, planes: fixture.planes,
                               naming: SignatureNaming(), nextRevision: nextRevision,
                               cache: &cache, variables: variables)
    }

    private func changingThickness(_ fixture: Fixture, to thickness: Double) -> Fixture {
        var result = fixture
        guard case let .extrude(profile, plane, _, symmetric, boolean, extras, _) = fixture.source.kind,
              let index = result.graph.index(of: fixture.source.id) else {
            XCTFail("missing plate feature")
            return fixture
        }
        result.graph.nodes[index].kind = .extrude(
            profile: profile, plane: plane, distance: Expr(value: thickness), symmetric: symmetric,
            boolean: boolean, extraProfiles: extras)
        return result
    }

    private func withDefinition(_ fixture: Fixture, _ edit: (inout OffsetPlaneDefinition) -> Void) -> Fixture {
        var result = fixture
        guard case var .offset(definition)? = result.planes[0].definition else {
            XCTFail("missing offset definition")
            return fixture
        }
        edit(&definition)
        result.planes[0].definition = .offset(definition)
        return result
    }

    private func bounds(_ body: Body) -> (min: SIMD3<Double>, max: SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .infinity)
        var hi = SIMD3<Double>(repeating: -.infinity)
        for local in body.render.positions {
            let p = body.transform.applying(to: SIMD3<Double>(local))
            lo = simd_min(lo, p)
            hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    private func assertPrism(_ result: EvalResult, fixture: Fixture, bottom: Double,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)", file: file, line: line)
        XCTAssertTrue(result.referenceErrors.isEmpty, "\(result.referenceErrors)", file: file, line: line)
        let body = try XCTUnwrap(result.bodies.first { $0.id == fixture.childBody }, file: file, line: line)
        let brep = try XCTUnwrap(body.brep, file: file, line: line)
        XCTAssertEqual(OCCTKernel.volume(brep), 24, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(bounds(body).min.y, bottom, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(bounds(body).max.y, bottom + 3, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(result.resolvedPlaneUpdates[fixture.datum]).origin.y,
                       bottom, accuracy: 1e-7, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(result.resolvedSketchSupportUpdates[fixture.childSketch]).origin.y,
                       bottom, accuracy: 1e-7, file: file, line: line)
    }

    func testPlateThicknessMovesDatumSupportedSketchAndExactExtrusion() async throws {
        let fixture = try makeFixture()
        var cache = EvalCache()
        let initial = evaluate(fixture, cache: &cache)
        try assertPrism(initial, fixture: fixture, bottom: 15)
        let changed = changingThickness(fixture, to: 20)
        let result = evaluate(changed, cache: &cache)
        try assertPrism(result, fixture: changed, bottom: 25)
        XCTAssertEqual(result.lastBodyWriters[fixture.sourceBody], fixture.source.id)
        XCTAssertEqual(result.geometryVersions[fixture.version]?.body.id, fixture.sourceBody)
        XCTAssertEqual(fixture.planes[0].plane.origin.y, -999, "pure replay cannot mutate its inputs")
        XCTAssertEqual(fixture.sketches[1].plane.origin.y, -888)
    }

    func testColdHotChangedSourceAndUnrelatedCacheEntryAgree() async throws {
        let fixture = try makeFixture()
        var cache = EvalCache()
        let cold = evaluate(fixture, cache: &cache)
        let unrelatedStamp = cache.entries[fixture.unrelated.id]?.fingerprint
        let hot = evaluate(fixture, cache: &cache)
        XCTAssertEqual(cache.lastRan, 0)
        XCTAssertEqual(cache.lastSkipped, fixture.graph.nodes.count)
        XCTAssertEqual(cold.resolvedPlaneUpdates, hot.resolvedPlaneUpdates)
        XCTAssertEqual(cold.resolvedSketchSupportUpdates, hot.resolvedSketchSupportUpdates)
        let changed = changingThickness(fixture, to: 20)
        let incremental = evaluate(changed, cache: &cache)
        XCTAssertEqual(cache.lastRan, 2, "source and supported prism must rebuild")
        XCTAssertEqual(cache.lastSkipped, 1, "unrelated node must remain reusable")
        XCTAssertEqual(cache.entries[fixture.unrelated.id]?.fingerprint, unrelatedStamp)
        var empty = EvalCache()
        let rebuilt = evaluate(changed, cache: &empty)
        try assertPrism(incremental, fixture: changed, bottom: 25)
        try assertPrism(rebuilt, fixture: changed, bottom: 25)
        XCTAssertEqual(incremental.resolvedPlaneUpdates, rebuilt.resolvedPlaneUpdates)
        let a = try XCTUnwrap(incremental.bodies.first { $0.id == changed.childBody })
        let b = try XCTUnwrap(rebuilt.bodies.first { $0.id == changed.childBody })
        XCTAssertEqual(bounds(a).min, bounds(b).min)
        XCTAssertEqual(bounds(a).max, bounds(b).max)
    }

    func testDerivedDisplayCacheChangesDoNotInvalidateAuthoritativeInputs() async throws {
        var fixture = try makeFixture()
        var cache = EvalCache()
        let first = evaluate(fixture, cache: &cache)
        fixture.planes[0].plane = try XCTUnwrap(first.resolvedPlaneUpdates[fixture.datum])
        fixture.sketches[1].plane = try XCTUnwrap(first.resolvedSketchSupportUpdates[fixture.childSketch])
        let second = evaluate(fixture, cache: &cache)
        XCTAssertEqual(cache.lastRan, 0)
        XCTAssertEqual(first.resolvedPlaneUpdates, second.resolvedPlaneUpdates)
        try assertPrism(second, fixture: fixture, bottom: 15)
    }

    func testPinnedWriterIsNotReboundToLaterInPlaceTransformOrAdoptedLiveBody() async throws {
        var fixture = try makeFixture()
        let later = FeatureNode(name: "Later move", kind: .transform(
            body: BodyRef(producer: fixture.source.id, bodyID: fixture.sourceBody),
            delta: Transform3D(translation: SIMD3(0, 100, 0))), outputBodyIDs: [BodyID()])
        fixture.graph.nodes.append(later)
        var cache = EvalCache()
        let first = evaluate(fixture, cache: &cache)
        try assertPrism(first, fixture: fixture, bottom: 15)
        XCTAssertEqual(first.lastBodyWriters[fixture.sourceBody], later.id)
        XCTAssertEqual(first.geometryVersions[fixture.version]?.body.transform.translation, SIMD3<Double>.zero)
        let live = try XCTUnwrap(first.bodies.first { $0.id == fixture.sourceBody })
        XCTAssertEqual(live.transform.translation.y, 100, accuracy: 1e-8)
        cache.adopt(Dictionary(first.bodies.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                    order: fixture.graph.nodes.map(\.id))
        let hot = evaluate(fixture, cache: &cache)
        XCTAssertEqual(cache.lastRan, 0)
        try assertPrism(hot, fixture: fixture, bottom: 15)
    }

    func testSourceTransformScaleAndProvenanceDifferFromActualWriter() async throws {
        let rotation = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        let transform = Transform3D(translation: SIMD3(10, 20, 30), rotation: rotation, scale: 2)
        let fixture = try makeFixture(transform: transform)
        XCTAssertNotEqual(fixture.writer, fixture.source.id)
        var cache = EvalCache()
        let result = evaluate(fixture, cache: &cache)
        XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
        XCTAssertTrue(result.referenceErrors.isEmpty, "\(result.referenceErrors)")
        let snapshot = try XCTUnwrap(result.geometryVersions[fixture.version])
        XCTAssertEqual(snapshot.body.transform, transform)
        let resolved = try XCTUnwrap(result.resolvedPlaneUpdates[fixture.datum])
        // Local top centroid (50,10,-30), scale/rotate/translate -> (-10,120,-30),
        // then offset 5 world mm along rotated +Y (-X), not scaled offset 10.
        XCTAssertEqual(resolved.origin.x, -15, accuracy: 1e-7)
        XCTAssertEqual(resolved.origin.y, 120, accuracy: 1e-7)
        XCTAssertEqual(resolved.origin.z, -30, accuracy: 1e-7)
        XCTAssertEqual(simd_length(resolved.normal - SIMD3(-1, 0, 0)), 0, accuracy: 1e-8)
        let child = try XCTUnwrap(result.bodies.first { $0.id == fixture.childBody })
        XCTAssertEqual(OCCTKernel.volume(try XCTUnwrap(child.brep)), 24, accuracy: 1e-5)
        XCTAssertEqual(bounds(child).min.x, -18, accuracy: 1e-4)
        XCTAssertEqual(bounds(child).max.x, -15, accuracy: 1e-4)
    }

    func testFormulaUsesExistingEvaluatorAndMissingVariableCannotUseCachedValue() async throws {
        let fixture = withDefinition(try makeFixture()) { $0.distance.formula = "gap * 2" }
        var cache = EvalCache()
        try assertPrism(evaluate(fixture, cache: &cache, variables: ["gap": 4]), fixture: fixture, bottom: 18)
        try assertPrism(evaluate(fixture, cache: &cache, variables: ["gap": 6]), fixture: fixture, bottom: 22)
        let failed = evaluate(fixture, cache: &cache)
        XCTAssertNotNil(failed.errors[fixture.child.id])
        XCTAssertTrue(failed.referenceErrors.values.contains(.invalidFormula("gap * 2")))
        XCTAssertFalse(failed.bodies.contains { $0.id == fixture.childBody })
        guard case let .offset(definition)? = fixture.planes[0].definition else { return XCTFail() }
        XCTAssertEqual(definition.distance.formula, "gap * 2")
        XCTAssertEqual(definition.distance.value, 5, "pure resolution preserves stored Expr cache")
    }

    func testSuppressedRolledBackMissingAndFailedSourceDoNotReuseSuccess() async throws {
        let fixture = try makeFixture()
        var originalCache = EvalCache()
        try assertPrism(evaluate(fixture, cache: &originalCache), fixture: fixture, bottom: 15)

        var suppressed = fixture
        suppressed.graph.nodes[0].suppressed = true
        var cache = originalCache
        let suppressedResult = evaluate(suppressed, cache: &cache)
        XCTAssertTrue(suppressedResult.referenceErrors.values.contains(.suppressedWriter(fixture.version)))
        XCTAssertFalse(suppressedResult.bodies.contains { $0.id == fixture.childBody })

        var rollback = fixture
        rollback.graph.rollbackIndex = 0
        cache = originalCache
        let rolled = evaluate(rollback, cache: &cache)
        XCTAssertTrue(rolled.referenceErrors.values.contains(.rolledBackWriter(fixture.version)))
        XCTAssertTrue(rolled.bodies.isEmpty)

        var missing = fixture
        missing.graph.nodes.removeFirst()
        cache = originalCache
        let absent = evaluate(missing, cache: &cache)
        XCTAssertTrue(absent.referenceErrors.values.contains(.missingWriter(fixture.version)))
        XCTAssertFalse(absent.bodies.contains { $0.id == fixture.childBody })

        var failed = fixture
        failed.graph.nodes[0].kind = .transform(
            body: BodyRef(producer: FeatureID(), bodyID: BodyID()), delta: .identity)
        cache = originalCache
        let broken = evaluate(failed, cache: &cache)
        XCTAssertTrue(broken.referenceErrors.values.contains(.failedWriter(fixture.version)))
        XCTAssertNil(broken.geometryVersions[fixture.version])
        XCTAssertFalse(broken.bodies.contains { $0.id == fixture.childBody })
    }

    func testForwardConsumerRemainsBrokenAfterFinalDisplayResolutionAndOnHotReplay() async throws {
        var fixture = try makeFixture()
        var cache = EvalCache()
        _ = evaluate(fixture, cache: &cache)
        fixture.graph.nodes.swapAt(0, 1)
        let first = evaluate(fixture, cache: &cache)
        XCTAssertTrue(first.referenceErrors.values.contains(.forwardSource(fixture.version)))
        XCTAssertNotNil(first.errors[fixture.child.id])
        XCTAssertFalse(first.bodies.contains { $0.id == fixture.childBody })
        // Display resolution can see the now-evaluated source, but it cannot
        // retroactively rescue the earlier failed consumer.
        XCTAssertNotNil(first.resolvedPlaneUpdates[fixture.datum])
        let hot = evaluate(fixture, cache: &cache)
        XCTAssertNotNil(hot.errors[fixture.child.id])
        XCTAssertFalse(hot.bodies.contains { $0.id == fixture.childBody })
        XCTAssertTrue(hot.referenceErrors.values.contains(.forwardSource(fixture.version)))
    }

    func testIndirectSourceProfileSupportCycleAndSelfSketchCycleAreDiagnosed() async throws {
        var fixture = try makeFixture()
        var cache = EvalCache()
        _ = evaluate(fixture, cache: &cache)
        fixture.sketches[0].support = PlaneRef(source: .construction(fixture.datum))
        let indirect = evaluate(fixture, cache: &cache)
        XCTAssertTrue(indirect.referenceErrors.values.contains { if case .cycle = $0 { return true }; return false })
        XCTAssertNotNil(indirect.errors[fixture.source.id])
        XCTAssertFalse(indirect.bodies.contains { $0.id == fixture.childBody })

        var selfCycle = try makeFixture()
        selfCycle.sketches[1].support = PlaneRef(source: .sketch(selfCycle.childSketch))
        let direct = evaluate(selfCycle, cache: &cache)
        XCTAssertTrue(direct.referenceErrors.values.contains { if case .cycle = $0 { return true }; return false })
        XCTAssertNotNil(direct.errors[selfCycle.child.id])
    }

    func testUnusedDatumAndSupportedSketchStillResolveOrReportBrokenReference() async throws {
        var fixture = try makeFixture()
        fixture.graph.nodes.removeAll { $0.id == fixture.child.id }
        var cache = EvalCache()
        let result = evaluate(fixture, cache: &cache)
        XCTAssertTrue(result.referenceErrors.isEmpty)
        XCTAssertEqual(result.resolvedPlaneUpdates[fixture.datum]?.origin.y, 15)
        XCTAssertEqual(result.resolvedSketchSupportUpdates[fixture.childSketch]?.origin.y, 15)
        fixture.graph.nodes.removeAll { $0.id == fixture.source.id }
        let broken = evaluate(fixture, cache: &cache)
        XCTAssertEqual(broken.referenceErrors[.plane(fixture.datum)], .missingWriter(fixture.version))
        XCTAssertNotNil(broken.referenceErrors[.sketch(fixture.childSketch)])
        XCTAssertNil(broken.resolvedPlaneUpdates[fixture.datum])
    }

    func testExactResolverRejectsMissingAmbiguousAndUnstableNamesWithoutMeshFallback() async throws {
        let fixture = try makeFixture()
        var cache = EvalCache()
        let result = evaluate(fixture, cache: &cache)
        let snapshot = try XCTUnwrap(result.geometryVersions[fixture.version])
        guard case let .offset(definition)? = fixture.planes[0].definition else { return XCTFail() }
        let name = try XCTUnwrap(definition.source.elementName)
        for mode in 0..<3 {
            var resolver = AssociativeGeometryResolver(graph: fixture.graph, sketches: fixture.sketches,
                                                      planes: fixture.planes)
            var body = snapshot.body
            var names = snapshot.kernelNames
            if mode == 0 { body.brep = nil }
            if mode == 1 { names[99999] = name }
            if mode == 2 { names = [:] }
            resolver.begin(fixture.source)
            resolver.finish(fixture.source, delta: EvalNodeDelta(ops: [
                .put(body, snapshot.faceTable, kernelNames: names)
            ]), stamp: snapshot.stamp)
            resolver.begin(fixture.child)
            let inputs = resolver.prepare(fixture.child)
            XCTAssertNotNil(inputs.error, "mode \(mode) must never fall back to the render mesh")
            XCTAssertNil(resolver.resolvedPlaneUpdates[fixture.datum])
        }
        let unstable = withDefinition(fixture) { value in
            var source = value.source
            source.elementName = ElementName(creator: source.creator, source: .kernelFace(index: 1))
            value = OffsetPlaneDefinition(source: source, sourceVersion: value.sourceVersion,
                                          distance: value.distance, attachment: value.attachment)
        }
        let rejected = evaluate(unstable, cache: &cache)
        XCTAssertTrue(rejected.referenceErrors.values.contains(.exactNamedPlaneRequired(fixture.version)))
        XCTAssertFalse(rejected.bodies.contains { $0.id == fixture.childBody })
    }

    func testJournalLastPutAndRemovalPreserveRequestedHistoryButFailedPutIsNotPublished() async throws {
        let fixture = try makeFixture()
        var cache = EvalCache()
        let result = evaluate(fixture, cache: &cache)
        let snapshot = try XCTUnwrap(result.geometryVersions[fixture.version])
        var last = snapshot.body
        last.transform.translation = SIMD3(1, 2, 3)
        var resolver = AssociativeGeometryResolver(graph: fixture.graph, sketches: fixture.sketches,
                                                  planes: fixture.planes)
        resolver.begin(fixture.source)
        resolver.finish(fixture.source, delta: EvalNodeDelta(ops: [
            .put(snapshot.body, snapshot.faceTable, kernelNames: snapshot.kernelNames),
            .put(last, snapshot.faceTable, kernelNames: snapshot.kernelNames), .remove(last.id)
        ]), stamp: 123)
        XCTAssertEqual(resolver.snapshots[fixture.version]?.body.transform.translation, SIMD3(1, 2, 3))
        XCTAssertEqual(resolver.snapshots[fixture.version]?.stamp, 123)
        XCTAssertNil(resolver.lastBodyWriters[last.id])
        resolver.begin(fixture.child)
        XCTAssertNil(resolver.prepare(fixture.child).error, "live removal must not erase a historical version")

        var failed = AssociativeGeometryResolver(graph: fixture.graph, sketches: fixture.sketches,
                                                planes: fixture.planes)
        failed.begin(fixture.source)
        failed.finish(fixture.source, delta: EvalNodeDelta(ops: [
            .put(last, snapshot.faceTable, kernelNames: snapshot.kernelNames)
        ], error: .kernelFailure("partial failure")), stamp: 456)
        XCTAssertNil(failed.snapshots[fixture.version])
        failed.begin(fixture.child)
        XCTAssertEqual(failed.prepare(fixture.child).error, .failedWriter(fixture.version))
    }

    func testRebuildPlanAppliesAndUndoesDefinitionDerivedCachesAndExactBodiesTogether() async throws {
        let fixture = try makeFixture()
        var cache = EvalCache()
        let initial = evaluate(fixture, cache: &cache)
        var document = DesignDocument()
        document.features = fixture.graph
        document.bodies = initial.bodies
        document.sketches = fixture.sketches
        document.planes = fixture.planes
        document.planes[0].plane = try XCTUnwrap(initial.resolvedPlaneUpdates[fixture.datum])
        document.sketches[1].plane = try XCTUnwrap(initial.resolvedSketchSupportUpdates[fixture.childSketch])
        let before = document
        let changed = withDefinition(changingThickness(fixture, to: 20)) { $0.distance.value = 8 }
        let newKind = try XCTUnwrap(changed.graph.node(fixture.source.id)).kind
        let leading: [DocumentCommand] = [
            EditFeatureCommand(featureID: fixture.source.id, before: fixture.source.kind, after: newKind),
            EditConstructionPlaneDefinitionCommand(planeID: fixture.datum,
                before: document.planes[0].definition, after: changed.planes[0].definition)
        ]
        var preview = document
        for command in leading { command.apply(to: &preview) }
        let plan = RebuildPlanner.plan(editedGraph: changed.graph, previousGraph: fixture.graph,
            document: document, sketches: document.sketches, planes: document.planes,
            naming: SignatureNaming(), cache: &cache, nextRevision: nextRevision,
            leadingCommands: leading, title: "Datum edit", previewDocument: preview)
        XCTAssertTrue(plan.errors.isEmpty)
        XCTAssertTrue(plan.referenceErrors.isEmpty)
        XCTAssertEqual(plan.resolvedPlaneUpdates[fixture.datum]?.origin.y, 28)
        let undo = UndoStack()
        undo.perform(CompositeCommand(title: "Datum edit", commands: plan.commands), on: &document)
        XCTAssertEqual(undo.undoCommands.count, 1)
        XCTAssertEqual(document.planes[0].definition, changed.planes[0].definition,
                       "derived command must not replace the new definition with its old record")
        XCTAssertEqual(document.planes[0].plane.origin.y, 28)
        XCTAssertEqual(document.sketches[1].plane.origin.y, 28)
        XCTAssertEqual(document.sketches[1].entities, before.sketches[1].entities)
        XCTAssertEqual(document.sketches[1].constraints, before.sketches[1].constraints)
        XCTAssertEqual(document.sketches[1].support, before.sketches[1].support)
        let updated = try XCTUnwrap(document.bodies.first { $0.id == fixture.childBody })
        XCTAssertEqual(bounds(updated).min.y, 28, accuracy: 1e-4)
        undo.undo(on: &document)
        XCTAssertEqual(document.planes, before.planes)
        XCTAssertEqual(document.sketches, before.sketches)
        XCTAssertEqual(bounds(try XCTUnwrap(document.bodies.first { $0.id == fixture.childBody })).min.y,
                       15, accuracy: 1e-4)
        undo.redo(on: &document)
        XCTAssertEqual(document.planes[0].definition, changed.planes[0].definition)
        XCTAssertEqual(document.planes[0].plane.origin.y, 28)
        XCTAssertEqual(document.sketches[1].id, fixture.childSketch)
        XCTAssertNotNil(document.bodies.first { $0.id == fixture.childBody }?.brep)
    }

    func testSupportRehostAndExplicitPlaneCommandsPreserveLocalGeometryAndUndoBinding() async throws {
        let fixture = try makeFixture()
        var document = DesignDocument()
        document.sketches = fixture.sketches
        let before = document.sketches[1]
        let support = ChangeSketchSupportCommand(sketchID: before.id, before: before.support,
            after: nil, beforePlane: before.plane, afterPlane: .ground)
        support.apply(to: &document)
        XCTAssertNil(document.sketches[1].support)
        XCTAssertEqual(document.sketches[1].entities, before.entities)
        support.revert(in: &document)
        XCTAssertEqual(document.sketches[1], before)
        let explicit = ChangeSketchPlaneCommand(sketch: before, after: .ground)
        explicit.apply(to: &document)
        XCTAssertNil(document.sketches[1].support)
        explicit.revert(in: &document)
        XCTAssertEqual(document.sketches[1], before)
    }

    func testLeadingNewDatumAndSupportEditAreNotOverwrittenByDerivedPlan() async throws {
        let fixture = try makeFixture()
        var cache = EvalCache()
        let initial = evaluate(fixture, cache: &cache)
        var document = DesignDocument()
        document.features = fixture.graph
        document.bodies = initial.bodies
        document.sketches = fixture.sketches
        document.planes = fixture.planes
        document.planes[0].plane = try XCTUnwrap(initial.resolvedPlaneUpdates[fixture.datum])
        document.sketches[1].plane = try XCTUnwrap(initial.resolvedSketchSupportUpdates[fixture.childSketch])
        let before = document
        let changed = withDefinition(fixture) { $0.distance.value = 12 }
        let newDatum = ConstructionPlane(plane: .offsetGround(y: -777), size: 90,
                                         definition: changed.planes[0].definition)
        let newSupport = PlaneRef(source: .construction(newDatum.id))
        let leading: [DocumentCommand] = [
            AddConstructionPlaneCommand(plane: newDatum),
            ChangeSketchSupportCommand(sketchID: fixture.childSketch,
                before: document.sketches[1].support, after: newSupport,
                beforePlane: document.sketches[1].plane, afterPlane: newDatum.plane)
        ]
        var preview = document
        for command in leading { command.apply(to: &preview) }
        let plan = RebuildPlanner.plan(editedGraph: fixture.graph, previousGraph: fixture.graph,
            document: document, sketches: document.sketches, planes: document.planes,
            naming: SignatureNaming(), cache: &cache, nextRevision: nextRevision,
            leadingCommands: leading, title: "Rehost", previewDocument: preview)
        XCTAssertTrue(plan.errors.isEmpty)
        XCTAssertTrue(plan.referenceErrors.isEmpty)
        let command = CompositeCommand(title: "Rehost", commands: plan.commands)
        command.apply(to: &document)
        XCTAssertEqual(document.sketches[1].support, newSupport)
        XCTAssertEqual(document.sketches[1].plane.origin.y, 22)
        XCTAssertEqual(document.planes.last?.definition, newDatum.definition)
        XCTAssertEqual(document.planes.last?.plane.origin.y, 22)
        XCTAssertEqual(document.sketches[1].entities, before.sketches[1].entities)
        XCTAssertEqual(bounds(try XCTUnwrap(document.bodies.first { $0.id == fixture.childBody })).min.y,
                       22, accuracy: 1e-4)
        command.revert(in: &document)
        XCTAssertEqual(document.planes, before.planes)
        XCTAssertEqual(document.sketches, before.sketches)
        command.apply(to: &document)
        XCTAssertEqual(document.sketches[1].support, newSupport)
        XCTAssertEqual(document.sketches[1].id, fixture.childSketch)
    }

    func testCapturedTypedDependencyGraphValidatesCandidateWithoutRebindingWriter() async throws {
        let fixture = try makeFixture()
        let captured = AssociativeDependencyGraph(graph: fixture.graph, sketches: fixture.sketches,
                                                 planes: fixture.planes)
        XCTAssertEqual(try captured.sourceVersions(reachableFrom: .feature(fixture.child.id)),
                       [fixture.version])
        XCTAssertTrue(captured.validationErrors(in: fixture.graph).isEmpty)
        var moved = fixture.graph
        moved.nodes.swapAt(0, 1)
        XCTAssertEqual(captured.validationErrors(in: moved)[.feature(fixture.child.id)],
                       .forwardSource(fixture.version))
        var removed = fixture.graph
        removed.nodes.removeAll { $0.id == fixture.source.id }
        XCTAssertEqual(captured.validationErrors(in: removed)[.plane(fixture.datum)],
                       .missingWriter(fixture.version))
        var suppressed = fixture.graph
        suppressed.nodes[0].suppressed = true
        XCTAssertEqual(captured.validationErrors(in: suppressed)[.feature(fixture.child.id)],
                       .suppressedWriter(fixture.version))
        // M26 may supply its already captured body VERSION edges. The datum
        // dependency walker traverses them rather than inferring new producers.
        let downstream = FeatureNode(name: "Child move", kind: .transform(
            body: BodyRef(producer: fixture.child.id, bodyID: fixture.childBody), delta: .identity),
            outputBodyIDs: [BodyID()])
        var extended = fixture.graph
        extended.nodes.append(downstream)
        let injected = AssociativeDependencyGraph(graph: extended, sketches: fixture.sketches,
            planes: fixture.planes, featureDependencies: [downstream.id: [fixture.child.id]])
        XCTAssertEqual(try injected.sourceVersions(reachableFrom: .feature(downstream.id)),
                       [fixture.version])
        extended.nodes.removeLast()
        extended.nodes.insert(downstream, at: 0)
        XCTAssertEqual(injected.validationErrors(in: extended)[.feature(downstream.id)],
                       .forwardSource(fixture.version))
    }
}
