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

    func testRemovingOneOfThreeRealFaceFragmentsCannotRebindItsOrdinalToASurvivor() async throws {
        let bodyID = BodyID(), firstSlotID = BodyID(), secondSlotID = BodyID(), removalID = BodyID()
        let source = FeatureNode(name: "Plate", kind: .primitive(
            spec: .box(width: 60, depth: 20, height: 10), placement: .identity), outputBodyIDs: [bodyID])
        func slot(_ x: Double, _ output: BodyID) -> FeatureNode {
            FeatureNode(name: "Slot", kind: .primitive(spec: .box(width: 5, depth: 40, height: 30),
                placement: Transform3D(translation: SIMD3(x, -10, 0))), outputBodyIDs: [output])
        }
        let a = slot(-10, firstSlotID), b = slot(10, secondSlotID)
        let target = BodyRef(producer: source.id, bodyID: bodyID)
        let tools = [BodyRef(producer: a.id, bodyID: firstSlotID), BodyRef(producer: b.id, bodyID: secondSlotID)]
        var cut = FeatureNode(name: "Three regions", kind: .boolean(kind: .subtract, target: target, tools: tools),
                              outputBodyIDs: [bodyID])
        var revision: UInt64 = 0
        func evaluate(_ nodes: [FeatureNode]) -> EvalResult {
            FeatureGraph(nodes: nodes).evaluate(sketches: [], planes: [], naming: SignatureNaming()) {
                revision += 1
                return revision
            }
        }
        let initial = evaluate([source, a, b, cut])
        XCTAssertTrue(initial.errors.isEmpty, "\(initial.errors)")
        let input = try XCTUnwrap(initial.bodies.first { $0.id == bodyID })
        XCTAssertEqual(abs(OCCTKernel.volume(try XCTUnwrap(input.brep))), 10_000, accuracy: 1e-4)
        let table = try XCTUnwrap(initial.faceTables[bodyID])
        let tops = table.entries.filter { $0.signature.normal.y > 0.99 }
        XCTAssertEqual(tops.count, 3, "The fixture must really split one top face into three disconnected regions")
        let picked = try XCTUnwrap(tops.first {
            guard case let .opFace(operation, _, index)? = $0.elementName?.source else { return false }
            return operation == cut.id && index == 0
        })
        let reference = FaceRef(body: BodyRef(producer: cut.id, bodyID: bodyID), creator: cut.id,
            role: picked.role, signature: picked.signature, elementName: picked.elementName)
        let originalFace = try XCTUnwrap(SignatureNaming().resolve(reference, in: input, table: table)?.planar)
        let corners = originalFace.outline.map { originalFace.origin + originalFace.basisX * $0.x + originalFace.basisY * $0.y }
        let minimum = try XCTUnwrap(corners.map(\.x).min()), maximum = try XCTUnwrap(corners.map(\.x).max())
        let remove = FeatureNode(name: "Remove original region", kind: .primitive(
            spec: .box(width: maximum - minimum + 2, depth: 40, height: 30),
            placement: Transform3D(translation: SIMD3((minimum + maximum) / 2, -10, 0))), outputBodyIDs: [removalID])
        cut.kind = .boolean(kind: .subtract, target: target,
                            tools: tools + [BodyRef(producer: remove.id, bodyID: removalID)])
        let prefix = [source, a, b, remove, cut]
        let actual = evaluate(prefix)
        XCTAssertTrue(actual.errors.isEmpty, "\(actual.errors)")
        let surviving = try XCTUnwrap(actual.bodies.first { $0.id == bodyID })
        let survivingTable = try XCTUnwrap(actual.faceTables[bodyID])
        XCTAssertEqual(survivingTable.entries.filter { $0.signature.normal.y > 0.99 }.count, 2)
        XCTAssertFalse(OCCTKernel.faceInfo(try XCTUnwrap(surviving.brep)).contains {
            $0.normal.y > 0.99 && simd_distance($0.centroid, picked.signature.centroid) < 1e-5
        }, "The selected physical region must actually have disappeared")
        let rebound = SignatureNaming().resolve(reference, in: surviving, table: survivingTable)
        let aliases = survivingTable.entries.filter { $0.elementName == picked.elementName }.map { $0.signature.centroid }
        let attachment = XCTAttachment(string: "Actual three-to-two OCCT face split; removed centroid=\(picked.signature.centroid), old name=\(String(describing: picked.elementName)), current alias centroids=\(aliases), resolved=\(rebound != nil)")
        attachment.name = "real-removed-three-face-fragment.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertNil(rebound, "A deleted face must not become the surviving fragment with its old ordinal")

        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("FaceSplit.floecad"), name: "Face split")
        documents.append(document)
        document.session.recordAndRebuild(prefix, title: "Two regions")
        let deletion = FeatureNode(name: "Original region operation", kind: .deleteFace(body: reference.body, faces: [reference]), outputBodyIDs: [bodyID])
        document.session.record(deletion)
        let undo = document.session.undoStack.undoCommands.count
        let model = document.viewModel()
        XCTAssertFalse(model.beginDeleteFaceEdit(deletion.id))
        XCTAssertTrue(model.deleteFaceTargets.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
    }
}
