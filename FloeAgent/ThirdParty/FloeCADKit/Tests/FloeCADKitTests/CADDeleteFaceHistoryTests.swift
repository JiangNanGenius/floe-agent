import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADDeleteFaceHistoryTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    private struct Fixture {
        var document: FloeCADDocument
        var body: BodyID
        var source: FeatureNode
        var cylinderIndex: Int
    }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FloeDeleteHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for document in documents { document.close() }
        documents = []
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func fixture(partialPositiveZ: Bool = false) async throws -> Fixture {
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("\(UUID().uuidString).floecad"), name: "Face history")
        documents.append(document)
        let body = BodyID(), tool = BodyID()
        let first = FeatureNode(name: "Source", kind: .primitive(
            spec: partialPositiveZ ? .cylinder(radius: 10, height: 30) : .box(width: 40, depth: 30, height: 10),
            placement: .identity), outputBodyIDs: [body])
        let cutter = FeatureNode(name: "Cutter", kind: .primitive(
            spec: partialPositiveZ ? .box(width: 40, depth: 20, height: 40) : .cylinder(radius: 3, height: 20),
            placement: Transform3D(translation: partialPositiveZ ? SIMD3(0, -5, -10) : SIMD3(0, -5, 0))),
            outputBodyIDs: [tool])
        let source = FeatureNode(name: "Cut", kind: .boolean(kind: .subtract,
            target: BodyRef(producer: first.id, bodyID: body),
            tools: [BodyRef(producer: cutter.id, bodyID: tool)]), outputBodyIDs: [body])
        document.session.recordAndRebuild([first, cutter, source], title: "Source")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty, "\(document.session.lastEvalErrors)")
        let brep = try XCTUnwrap(document.session.document.body(with: body)?.brep)
        let cylinder = try XCTUnwrap(OCCTKernel.faceInfo(brep).first {
            guard let signature = $0.signature else { return false }
            if case .cylindrical = signature.kind { return true }
            return false
        })
        return Fixture(document: document, body: body, source: source, cylinderIndex: cylinder.index)
    }

    private func heal(_ f: Fixture) throws -> FeatureNode {
        let response = CADCommandExecutor(viewModel: f.document.viewModel())
            .run(.deleteFace(body: f.body, faces: [f.cylinderIndex]))
        XCTAssertEqual(response.status, 200, String(data: response.body, encoding: .utf8) ?? "")
        let node = try XCTUnwrap(f.document.session.document.features.nodes.last)
        guard case .deleteFace = node.kind else { throw NSError(domain: "ExpectedDeleteFace", code: 1) }
        return node
    }

    private func volume(_ f: Fixture) throws -> Double {
        abs(OCCTKernel.volume(try XCTUnwrap(f.document.session.document.body(with: f.body)?.brep)))
    }

    func testHistoryKeepsNamedInputFaceAndUnchangedAcceptDoesNotRewriteIt() async throws {
        let f = try await fixture()
        let feature = try heal(f)
        XCTAssertEqual(try volume(f), 12_000, accuracy: 1e-4)
        guard case let .deleteFace(_, refs) = feature.kind else { return XCTFail("Missing feature") }
        let ref = try XCTUnwrap(refs.first)
        XCTAssertNotNil(ref.elementName)
        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let identity = f.document.modelSHA256
        let count = f.document.session.undoStack.undoCommands.count
        let model = f.document.viewModel()
        XCTAssertTrue(model.beginDeleteFaceEdit(feature.id), model.errorMessage ?? "")
        XCTAssertEqual(model.deleteFaceTargets.count, 1)
        let target = try XCTUnwrap(model.deleteFaceTargets.first)
        XCTAssertEqual(target.sourceReference, ref)
        XCTAssertEqual(target.elementName, ref.elementName)
        XCTAssertEqual(hypot(target.samplePoint.x, target.samplePoint.z), 3, accuracy: 1e-4)
        XCTAssertTrue(model.scene.profileFills.contains { $0.triangles.count == target.triangles.count * 3 },
                      "Highlight must use the consumed bore's triangles, not the already healed box")
        XCTAssertTrue(model.canCommitDeleteFace)
        model.commitDeleteFace()
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count)
        XCTAssertEqual(f.document.session.document.features.nodes.last?.id, feature.id)
        let accepted = await f.document.save()
        XCTAssertTrue(accepted.succeeded, accepted.error ?? "")
        XCTAssertEqual(f.document.modelSHA256, identity)
        f.document.session.undo()
        XCTAssertEqual(try volume(f), 12_000 - 90 * .pi, accuracy: 1e-4)
        f.document.session.redo()
        XCTAssertEqual(try volume(f), 12_000, accuracy: 1e-4)
        let redone = await f.document.save()
        XCTAssertTrue(redone.succeeded, redone.error ?? "")
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: f.document.url)
        documents.append(reopened)
        XCTAssertEqual(reopened.modelSHA256, identity)
        let reopenedModel = reopened.viewModel()
        XCTAssertTrue(reopenedModel.beginDeleteFaceEdit(feature.id))
        XCTAssertEqual(reopenedModel.deleteFaceTargets.first?.sourceReference, ref)
    }

    func testPlanarOpeningSampleStaysOnTheAnnulusInsteadOfInsideItsHole() async throws {
        let f = try await fixture()
        let body = try XCTUnwrap(f.document.session.document.body(with: f.body))
        let cap = try XCTUnwrap(FaceTopology.enumerateFaces(in: body.render).planar.first { $0.normal.y > 0.99 })
        XCTAssertFalse(cap.holes.isEmpty)
        let target = try XCTUnwrap(DeleteFaceKit.target(in: body.render, seedTriangle: try XCTUnwrap(cap.triangles.first)))
        XCTAssertEqual(target.samplePoint.y, 10, accuracy: 1e-4)
        XCTAssertGreaterThan(hypot(target.samplePoint.x, target.samplePoint.z), 3,
                             "The native surface point must lie outside the actual through bore")
    }

    func testPartialCylinderSampleStaysOnItsExistingPositiveHalf() async throws {
        let f = try await fixture(partialPositiveZ: true)
        let body = try XCTUnwrap(f.document.session.document.body(with: f.body))
        let cylinder = try XCTUnwrap(FaceTopology.enumerateFaces(in: body.render).cylindrical.first)
        let target = try XCTUnwrap(DeleteFaceKit.target(in: body.render, seedTriangle: try XCTUnwrap(cylinder.triangles.first)))
        XCTAssertEqual(hypot(target.samplePoint.x, target.samplePoint.z), 10, accuracy: 1e-4)
        XCTAssertGreaterThan(target.samplePoint.z, 0)
    }

    func testMissingNamedFaceCannotOpenAnEmptyHistoryPickOrChangeUndo() async throws {
        let f = try await fixture()
        let feature = try heal(f)
        guard case let .deleteFace(body, refs) = feature.kind else { return XCTFail("Missing feature") }
        var missing = try XCTUnwrap(refs.first)
        var name = try XCTUnwrap(missing.elementName)
        name.creator = FeatureID()
        missing.elementName = name
        let changed = FeatureKind.deleteFace(body: body, faces: [missing])
        f.document.session.perform(EditFeatureCommand(featureID: feature.id, before: feature.kind, after: changed))
        let count = f.document.session.undoStack.undoCommands.count
        let model = f.document.viewModel()
        XCTAssertFalse(model.beginDeleteFaceEdit(feature.id))
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.deleteFaceTargets.isEmpty)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count)
        guard case let .deleteFace(_, retained)? = f.document.session.document.features.node(feature.id)?.kind
        else { return XCTFail("Lost original feature") }
        XCTAssertEqual(retained, [missing])
        XCTAssertEqual(try volume(f), 12_000, accuracy: 1e-4)
    }

    func testFailedMixedOrForeignFaceReferencesNeverHealOrUpgradeTheInput() async throws {
        let f = try await fixture()
        let feature = try heal(f)
        guard case let .deleteFace(body, refs) = feature.kind else { return XCTFail("Missing feature") }
        var missing = try XCTUnwrap(refs.first)
        var name = try XCTUnwrap(missing.elementName)
        name.creator = FeatureID()
        missing.elementName = name
        var foreign = try XCTUnwrap(refs.first)
        foreign.body.bodyID = BodyID()
        var legacy = try XCTUnwrap(refs.first)
        legacy.elementName = nil
        f.document.session.undo()
        for selection in [[legacy, missing], [foreign]] {
            let node = FeatureNode(name: "Refused deletion", kind: .deleteFace(body: body, faces: selection), outputBodyIDs: [f.body])
            let graph = FeatureGraph(nodes: f.document.session.document.features.nodes + [node])
            var revision: UInt64 = 0
            let result = graph.evaluate(sketches: [], planes: [], naming: SignatureNaming()) {
                revision += 1
                return revision
            }
            XCTAssertNotNil(result.errors[node.id])
            XCTAssertNil(result.proposedUpgrades[node.id])
            let retained = try XCTUnwrap(result.bodies.first { $0.id == f.body })
            XCTAssertEqual(abs(OCCTKernel.volume(try XCTUnwrap(retained.brep))), 12_000 - 90 * .pi, accuracy: 1e-4)
        }
    }
}
