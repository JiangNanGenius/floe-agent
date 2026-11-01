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
}
