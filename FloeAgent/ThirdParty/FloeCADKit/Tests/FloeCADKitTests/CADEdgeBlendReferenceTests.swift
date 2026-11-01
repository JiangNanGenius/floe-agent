import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADEdgeBlendReferenceTests: XCTestCase {
    private var revision: UInt64 = 0

    private struct Fixture {
        var sketch: Sketch
        var source: FeatureNode
        var body: BodyID
        var edges: [(index: Int, reference: EdgeRef)]
    }

    private func evaluate(_ fixture: Fixture, blend: FeatureNode? = nil) -> EvalResult {
        FeatureGraph(nodes: [fixture.source] + (blend.map { [$0] } ?? []))
            .evaluate(sketches: [fixture.sketch], planes: [], naming: SignatureNaming()) {
                self.revision += 1
                return self.revision
            }
    }

    private func fixture() throws -> Fixture {
        let entity = UUID()
        let sketch = Sketch(name: "Blend source", plane: .ground, entities: [
            .rect(id: entity, min: .zero, max: SIMD2(40, 20)),
        ])
        let bodyID = BodyID()
        let source = FeatureNode(name: "Box", kind: .extrude(
            profile: ProfileRef(sketchID: sketch.id, entityIDs: [entity],
                                holeEntityIDs: [], seedPoint: SIMD2(5, 5)),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: 10),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [bodyID])
        var fixture = Fixture(sketch: sketch, source: source, body: bodyID, edges: [])
        let result = evaluate(fixture)
        XCTAssertTrue(result.errors.isEmpty)
        let body = try XCTUnwrap(result.bodies.first)
        let brep = try XCTUnwrap(body.brep)
        let names = ElementNaming.edgeNames(
            adjacency: OCCTKernel.edgeFaceAdjacency(brep),
            names: try XCTUnwrap(result.kernelNames[bodyID]))
        var references: [Int: EdgeRef] = [:]
        for edge in EdgeTopology.selectableEdges(from: body.render) {
            let midpoint = edge.midpoint
            guard let index = OCCTKernel.nearestEdgeIndex(
                brep, to: SIMD3(Double(midpoint.x), Double(midpoint.y), Double(midpoint.z)),
                tolerance: OCCTKernel.matchTolerance(for: brep)),
                  let name = names[index] else { continue }
            references[index] = EdgeRef(
                body: BodyRef(producer: source.id, bodyID: bodyID),
                signature: EdgeTopology.signature(of: edge), faceNames: name)
        }
        fixture.edges = references.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        XCTAssertEqual(fixture.edges.count, 12)
        return fixture
    }

    private func blend(_ fixture: Fixture, refs: [EdgeRef], fillet: Bool,
                       amount: Double = 1) -> FeatureNode {
        let body = BodyRef(producer: fixture.source.id, bodyID: fixture.body)
        return FeatureNode(name: fillet ? "Fillet" : "Chamfer", kind: fillet
            ? .fillet(body: body, edges: refs, radius: Expr(value: amount))
            : .chamfer(body: body, edges: refs, setback: Expr(value: amount)),
            outputBodyIDs: [fixture.body])
    }

    private func volume(_ result: EvalResult) throws -> Double {
        let body = try XCTUnwrap(result.bodies.first)
        return abs(OCCTKernel.volume(try XCTUnwrap(body.brep)))
    }

    private func assertRejected(_ fixture: Fixture, refs: [EdgeRef], fillet: Bool,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let node = blend(fixture, refs: refs, fillet: fillet)
        let result = evaluate(fixture, blend: node)
        guard case .brokenRef? = result.errors[node.id] else {
            return XCTFail("Expected a broken reference, got \(result.errors)", file: file, line: line)
        }
        XCTAssertEqual(try volume(result), 8_000, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(result.bodies.map(\.id), [fixture.body], file: file, line: line)
        XCTAssertNil(result.proposedUpgrades[node.id], file: file, line: line)
    }

    func testMissingNamedEdgeNeverUsesItsStillValidGeometricFingerprint() throws {
        let fixture = try fixture()
        var reference = try XCTUnwrap(fixture.edges.first?.reference)
        let available = EdgeTopology.selectableEdges(from: try XCTUnwrap(evaluate(fixture).bodies.first).render)
        XCTAssertNotNil(EdgeTopology.resolve(reference.signature, in: available, sizeScale: 50))
        var name = try XCTUnwrap(reference.faceNames)
        name.faceA.creator = FeatureID()
        reference.faceNames = name
        for fillet in [true, false] {
            try assertRejected(fixture, refs: [reference], fillet: fillet)
        }
    }

    func testMixedNamedAndLegacyBatchCannotBypassALostName() throws {
        let fixture = try fixture()
        var named = fixture.edges[0].reference
        var name = try XCTUnwrap(named.faceNames)
        name.faceB.creator = FeatureID()
        named.faceNames = name
        var legacy = fixture.edges[1].reference
        legacy.faceNames = nil
        for fillet in [true, false] {
            try assertRejected(fixture, refs: [named, legacy], fillet: fillet)
        }
    }

    func testOneUnresolvedLegacyEdgeRejectsTheEntireSelection() throws {
        let fixture = try fixture()
        var valid = fixture.edges[0].reference
        valid.faceNames = nil
        var invalid = valid
        invalid.signature.normalA = .zero
        invalid.signature.normalB = .zero
        invalid.signature.direction = .zero
        for fillet in [true, false] {
            try assertRejected(fixture, refs: [valid, invalid], fillet: fillet)
        }
    }

    func testForeignBodyReferenceCannotBlendATargetLookalike() throws {
        let fixture = try fixture()
        var invalid = fixture.edges[0].reference
        invalid.body.bodyID = BodyID()
        try assertRejected(fixture, refs: [invalid], fillet: true)
    }

    func testDuplicateAndMixedLegacyPicksBlendOnceAndEarnActualNames() throws {
        let fixture = try fixture()
        let named = fixture.edges[0].reference
        var legacy = named
        legacy.faceNames = nil
        for fillet in [true, false] {
            let once = evaluate(fixture, blend: blend(fixture, refs: [named], fillet: fillet))
            let duplicateNode = blend(fixture, refs: [named, legacy, named], fillet: fillet)
            let duplicate = evaluate(fixture, blend: duplicateNode)
            XCTAssertTrue(once.errors.isEmpty, "\(once.errors)")
            XCTAssertTrue(duplicate.errors.isEmpty, "\(duplicate.errors)")
            XCTAssertLessThan(try volume(once), 8_000)
            XCTAssertEqual(try volume(once), try volume(duplicate), accuracy: 1e-6)
            XCTAssertFalse(try XCTUnwrap(duplicate.kernelNames[fixture.body]).isEmpty)
            let upgraded = try XCTUnwrap(duplicate.proposedUpgrades[duplicateNode.id])
            let upgradedEdges: [EdgeRef]
            switch upgraded {
            case let .fillet(_, edges, _), let .chamfer(_, edges, _): upgradedEdges = edges
            default: return XCTFail("Unexpected upgraded kind")
            }
            XCTAssertEqual(upgradedEdges.count, 3)
            XCTAssertTrue(upgradedEdges.allSatisfy { $0.faceNames == named.faceNames })
        }
    }

    func testNonFiniteBlendAmountsLeaveTheExactInputBody() throws {
        let fixture = try fixture()
        for value in [Double.infinity, Double.nan] {
            let node = blend(fixture, refs: [fixture.edges[0].reference], fillet: true, amount: value)
            let result = evaluate(fixture, blend: node)
            XCTAssertNotNil(result.errors[node.id])
            XCTAssertEqual(try volume(result), 8_000, accuracy: 1e-6)
        }
    }

    func testMeshBlendCannotSilentlySkipAnInvalidSelectedTool() throws {
        let fixture = try fixture()
        let body = try XCTUnwrap(evaluate(fixture).bodies.first)
        let edge = try XCTUnwrap(EdgeTopology.selectableEdges(from: body.render).first)
        func d(_ point: SIMD3<Float>) -> SIMD3<Double> {
            SIMD3(Double(point.x), Double(point.y), Double(point.z))
        }
        let valid = BlendEdgeSpec(p0: d(edge.start), p1: d(edge.end),
                                  normalA: d(edge.normalA), normalB: d(edge.normalB),
                                  isConvex: edge.isConvex)
        let invalid = BlendEdgeSpec(p0: d(edge.start), p1: d(edge.start),
                                    normalA: d(edge.normalA), normalB: d(edge.normalB),
                                    isConvex: edge.isConvex)
        for fillet in [true, false] {
            let mesh = body.euclidMesh()
            let standalone = KernelOps.blendEdges(mesh: mesh, edges: [valid],
                                                  amount: 1, isFillet: fillet)
            XCTAssertFalse(standalone.polygons.isEmpty)
            for selection in [[valid, invalid], [invalid, valid]] {
                let refused = KernelOps.blendEdges(mesh: mesh, edges: selection,
                                                   amount: 1, isFillet: fillet)
                XCTAssertTrue(refused.polygons.isEmpty,
                              "One bad selected tool must reject the entire legacy mesh blend")
            }
        }
    }

    func testConcaveNativeAndMeshBlendsReportTheirActualGeometricEffect() throws {
        let points: [SIMD2<Double>] = [
            .zero, SIMD2(40, 0), SIMD2(40, 10), SIMD2(20, 10), SIMD2(20, 30), SIMD2(0, 30),
        ]
        let ids = points.map { _ in UUID() }
        let sketch = Sketch(name: "Reentrant corner", plane: .ground,
                            entities: points.indices.map { index in
            .line(id: ids[index], a: points[index], b: points[(index + 1) % points.count])
        })
        let bodyID = BodyID()
        let source = FeatureNode(name: "L profile", kind: .extrude(
            profile: ProfileRef(sketchID: sketch.id, entityIDs: ids,
                                holeEntityIDs: [], seedPoint: SIMD2(5, 5)),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: 10),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
            extraProfiles: []), outputBodyIDs: [bodyID])
        let fixture = Fixture(sketch: sketch, source: source, body: bodyID, edges: [])
        let original = evaluate(fixture)
        XCTAssertTrue(original.errors.isEmpty, "\(original.errors)")
        let body = try XCTUnwrap(original.bodies.first)
        let brep = try XCTUnwrap(body.brep)
        XCTAssertEqual(try volume(original), 8_000, accuracy: 1e-5)
        let concave = try XCTUnwrap(EdgeTopology.selectableEdges(from: body.render)
            .first { !$0.isConvex && abs($0.direction.y) > 0.99 })
        let midpoint = concave.midpoint
        let index = try XCTUnwrap(OCCTKernel.nearestEdgeIndex(
            brep, to: SIMD3(Double(midpoint.x), Double(midpoint.y), Double(midpoint.z)),
            tolerance: OCCTKernel.matchTolerance(for: brep)))
        let names = ElementNaming.edgeNames(adjacency: OCCTKernel.edgeFaceAdjacency(brep),
                                            names: try XCTUnwrap(original.kernelNames[bodyID]))
        let ref = EdgeRef(body: BodyRef(producer: source.id, bodyID: bodyID),
                          signature: EdgeTopology.signature(of: concave),
                          faceNames: try XCTUnwrap(names[index]))
        func d(_ point: SIMD3<Float>) -> SIMD3<Double> {
            SIMD3(Double(point.x), Double(point.y), Double(point.z))
        }
        let spec = BlendEdgeSpec(p0: d(concave.start), p1: d(concave.end),
                                 normalA: d(concave.normalA), normalB: d(concave.normalB),
                                 isConvex: false)
        for fillet in [true, false] {
            let exact = evaluate(fixture, blend: blend(fixture, refs: [ref], fillet: fillet))
            XCTAssertTrue(exact.errors.isEmpty, "\(exact.errors)")
            let expected = 8_000 + 10 * (fillet ? 1 - Double.pi / 4 : 0.5)
            XCTAssertEqual(try volume(exact), expected, accuracy: 1e-4)
            XCTAssertNotNil(exact.bodies.first?.brep)
            let mesh = KernelOps.blendEdges(mesh: body.euclidMesh(), edges: [spec],
                                            amount: 1, isFillet: fillet)
            XCTAssertFalse(mesh.polygons.isEmpty)
            // The legacy tessellated path is an approximation, never an
            // analytic BRep. Quantify its actual effect against the exact one.
            let approximate = Body(id: bodyID, name: "Mesh blend", euclidMesh: mesh, revision: 0)
            XCTAssertNil(approximate.brep)
            XCTAssertEqual(abs(MeasureKit.volume(of: approximate)), expected, accuracy: 0.15)
        }
    }

    // Exercise the actual command transaction, not just graph evaluation.
    // Every failure must retain the undo stack and the exact saved identity.
    func testPublicBlendReceiptsReportAllEdgesAndRollbackKernelFailures() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeBlendReceipt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await FloeCADDocument.create(
            at: root.appendingPathComponent("Part.floecad"), name: "Blend receipt")
        defer { document.close() }
        let fixture = try fixture()
        document.session.perform(AddSketchCommand(sketch: fixture.sketch, title: "Source"))
        document.session.recordAndRebuild([fixture.source], title: "Box")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        let initialSave = await document.save()
        XCTAssertTrue(initialSave.succeeded, initialSave.error ?? "")
        let identity = document.modelSHA256
        let model = EditorViewModel(session: document.session)
        let executor = CADCommandExecutor(viewModel: model)
        let index = fixture.edges[0].index

        func payload(_ response: AgentResponse) throws -> [String: Any] {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        }
        func report(_ response: AgentResponse) throws -> [String: Any] {
            try XCTUnwrap(try payload(response)["edgeProcessing"] as? [String: Any])
        }

        for (selection, amount, expectedStatus) in [([index, Int.max], 1.0, 404),
                                                    ([index], 1_000.0, 422)] {
            let response = executor.run(.blend(body: fixture.body, isFillet: true,
                                               amount: amount, edges: selection))
            let body = try payload(response)
            XCTAssertEqual(response.status, expectedStatus, "\(body)")
            let outcome = try report(response)
            XCTAssertEqual(outcome["requested"] as? [Int], selection)
            XCTAssertEqual(outcome["processed"] as? [Int], [])
            XCTAssertEqual(outcome["rejected"] as? [Int], selection)
            XCTAssertEqual(outcome["atomic"] as? Bool, true)
            XCTAssertEqual(document.session.document.features.nodes.map(\.id), [fixture.source.id])
            XCTAssertEqual(document.modelSHA256, identity)
            let saved = await document.save()
            XCTAssertTrue(saved.succeeded, saved.error ?? "")
            XCTAssertEqual(document.modelSHA256, identity)
        }

        let response = executor.run(.blend(body: fixture.body, isFillet: true,
                                          amount: 1, edges: [index, index]))
        let body = try payload(response)
        XCTAssertEqual(response.status, 200, "\(body)")
        XCTAssertEqual(try report(response)["requested"] as? [Int], [index, index])
        XCTAssertEqual(try report(response)["processed"] as? [Int], [index])
        XCTAssertEqual(try report(response)["rejected"] as? [Int], [])
        XCTAssertEqual(try payload(response)["undoSteps"] as? Int, 1)
        let featureID = try XCTUnwrap(document.session.document.features.nodes.last?.id)
        document.session.undo()
        XCTAssertEqual(document.session.document.features.nodes.map(\.id), [fixture.source.id])
        document.session.redo()
        XCTAssertEqual(document.session.document.features.nodes.last?.id, featureID)
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let url = document.url
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        XCTAssertEqual(reopened.session.document.features.nodes.last?.id, featureID)
        XCTAssertEqual(reopened.session.document.bodies.first?.id, fixture.body)
        XCTAssertTrue(reopened.session.lastEvalErrors.isEmpty)
        reopened.session.rebuildFrom(fixture.source.id)
        XCTAssertTrue(reopened.session.lastEvalErrors.isEmpty)
        XCTAssertLessThan(abs(OCCTKernel.volume(try XCTUnwrap(
            reopened.session.document.bodies.first?.brep))), 8_000)
    }

    func testHistoryCannotPreselectALookalikeForAMissingNamedEdge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FloeEdgeHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = try await FloeCADDocument.create(at: root.appendingPathComponent("Part.floecad"), name: "Edge history")
        defer { document.close() }
        let f = try fixture()
        document.session.perform(AddSketchCommand(sketch: f.sketch))
        document.session.recordAndRebuild([f.source], title: "Source")
        var lost = f.edges[0].reference
        var name = try XCTUnwrap(lost.faceNames)
        name.faceA.creator = FeatureID()
        lost.faceNames = name
        let node = blend(f, refs: [lost], fillet: true)
        // Preserve an explicitly broken history operand; the consumed box
        // still has an indistinguishable geometric edge at the old position.
        document.session.record(node)
        let count = document.session.undoStack.undoCommands.count
        let model = document.viewModel()
        _ = model.beginBlendEdit(node.id)
        XCTAssertTrue(model.blendSelectedEdges.isEmpty,
                      "History must not turn a lost identity into a geometric replacement")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, count)
        XCTAssertEqual(abs(OCCTKernel.volume(try XCTUnwrap(document.session.document.bodies.first?.brep))),
                       8_000, accuracy: 1e-4)
    }

    func testRemovedMemberOfARealTwoEdgeFamilyCannotRoundTheSurvivingEdge() throws {
        let leftCircle = UUID(), rightCircle = UUID()
        // Put each periodic seam outside the visible arc of the lens. This
        // leaves two actual named cylindrical walls meeting at two edges,
        // rather than a seam splitting one wall into separately named faces.
        let left = Sketch(name: "Left", plane: SketchPlane(origin: SIMD3(-5, 0, 0),
            xAxis: SIMD3(-1, 0, 0), yAxis: SIMD3(0, 0, 1)),
            entities: [.circle(id: leftCircle, center: .zero, radius: 10)])
        let right = Sketch(name: "Right", plane: SketchPlane(origin: SIMD3(5, 0, 0),
            xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 0, -1)),
            entities: [.circle(id: rightCircle, center: .zero, radius: 10)])
        let body = BodyID(), other = BodyID()
        func cylinder(_ sketch: Sketch, entity: UUID, output: BodyID) -> FeatureNode {
            FeatureNode(name: sketch.name, kind: .extrude(
                profile: ProfileRef(sketchID: sketch.id, entityIDs: [entity], holeEntityIDs: [], seedPoint: .zero),
                plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: 20),
                symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []), extraProfiles: []),
                outputBodyIDs: [output])
        }
        let a = cylinder(left, entity: leftCircle, output: body)
        let b = cylinder(right, entity: rightCircle, output: other)
        let intersect = FeatureNode(name: "Lens", kind: .boolean(kind: .intersect,
            target: BodyRef(producer: a.id, bodyID: body), tools: [BodyRef(producer: b.id, bodyID: other)]),
            outputBodyIDs: [body])
        func evaluateNodes(_ nodes: [FeatureNode]) -> EvalResult {
            FeatureGraph(nodes: nodes).evaluate(sketches: [left, right], planes: [], naming: SignatureNaming()) {
                self.revision += 1
                return self.revision
            }
        }
        let prefix = [a, b, intersect]
        let initial = evaluateNodes(prefix)
        XCTAssertTrue(initial.errors.isEmpty, "\(initial.errors)")
        let original = try XCTUnwrap(initial.bodies.first { $0.id == body })
        let brep = try XCTUnwrap(original.brep)
        let nativeNames = try XCTUnwrap(initial.kernelNames[body])
        let adjacency = OCCTKernel.edgeFaceAdjacency(brep)
        // This deliberately describes the shipped legacy representation:
        // an ordinal among edges between the same two named faces.
        var families: [EdgeName: [Int]] = [:]
        for edge in adjacency.sorted(by: { $0.edge < $1.edge }) {
            guard let faceA = nativeNames[edge.faceA], let faceB = nativeNames[edge.faceB] else { continue }
            families[EdgeName(faceA: faceA, faceB: faceB, occurrence: 0), default: []].append(edge.edge)
        }
        let family = try XCTUnwrap(families.first { $0.value.count == 2 },
                                  "Fixture must contain the actual two-edge family")
        let selectedIndex = try XCTUnwrap(family.value.first)
        let selected = try XCTUnwrap(EdgeTopology.selectableEdges(from: original.render).first {
            let midpoint = $0.midpoint
            return OCCTKernel.nearestEdgeIndex(brep,
                to: SIMD3(Double(midpoint.x), Double(midpoint.y), Double(midpoint.z)),
                tolerance: OCCTKernel.matchTolerance(for: brep)) == selectedIndex
        })
        let signature = EdgeTopology.signature(of: selected)
        guard abs(signature.direction.y) > 0.99, abs(signature.length - 20) < 1e-4 else {
            XCTFail("The selected family must be the two vertical lens intersections")
            throw NSError(domain: "LensFixture", code: 1)
        }
        let oldRef = EdgeRef(body: BodyRef(producer: intersect.id, bodyID: body),
                            signature: signature, faceNames: family.key)
        let cutterBody = BodyID()
        let cutter = FeatureNode(name: "Remove selected seam", kind: .primitive(
            spec: .box(width: 40, depth: 20, height: 30),
            placement: Transform3D(translation: SIMD3(0, -5, signature.midpoint.z > 0 ? 15 : -15))),
            outputBodyIDs: [cutterBody])
        let cut = FeatureNode(name: "Trim lens", kind: .boolean(kind: .subtract,
            target: BodyRef(producer: intersect.id, bodyID: body),
            tools: [BodyRef(producer: cutter.id, bodyID: cutterBody)]), outputBodyIDs: [body])
        let trimmedNodes = prefix + [cutter, cut]
        let trimmed = evaluateNodes(trimmedNodes)
        XCTAssertTrue(trimmed.errors.isEmpty, "\(trimmed.errors)")
        let input = try XCTUnwrap(trimmed.bodies.first { $0.id == body })
        let inputBRep = try XCTUnwrap(input.brep)
        XCTAssertNil(OCCTKernel.nearestEdgeIndex(inputBRep, to: signature.midpoint,
                                               tolerance: OCCTKernel.matchTolerance(for: inputBRep)))
        let fillet = FeatureNode(name: "Original seam fillet", kind: .fillet(
            body: oldRef.body, edges: [oldRef], radius: Expr(value: 1)), outputBodyIDs: [body])
        let actual = evaluateNodes(trimmedNodes + [fillet])
        let inputVolume = abs(OCCTKernel.volume(inputBRep))
        let resultVolume = abs(OCCTKernel.volume(try XCTUnwrap(actual.bodies.first { $0.id == body }?.brep)))
        let evidence = XCTAttachment(string: "Actual OCCT lens; removed edge index=\(selectedIndex), midpoint=\(signature.midpoint); input volume=\(inputVolume), output=\(resultVolume), errors=\(actual.errors)")
        evidence.name = "real-removed-two-edge-family.txt"
        evidence.lifetime = .keepAlways
        add(evidence)
        XCTAssertNotNil(actual.errors[fillet.id], "A removed identity must not become the surviving ordinal-zero edge")
        XCTAssertEqual(resultVolume, inputVolume, accuracy: 1e-4)
    }
}
