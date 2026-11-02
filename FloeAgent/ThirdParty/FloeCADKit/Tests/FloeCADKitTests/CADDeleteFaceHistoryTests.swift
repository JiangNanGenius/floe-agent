import Foundation
import XCTest
import Euclid
import OCCTShim
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
        try await assertRemovedFaceRegionDoesNotRebind(compoundCutter: false)
    }

    func testChangingTheOriginalCompoundCutterCannotReuseADeletedFaceFragmentOrdinal() async throws {
        try await assertRemovedFaceRegionDoesNotRebind(compoundCutter: true)
    }

    // Compatibility change: a nil name plus derived ordinal never recorded
    // the selected face's identity. Keep it unresolved, even when today's
    // matching face has a qualified name. The original positive expectation
    // and source are retained in the primary proof-gate decision record.
    func testUnprovenLegacyFaceEditCannotPersistAnUpgrade() async throws {
        let f = try await fixture()
        let body = try XCTUnwrap(f.document.session.document.body(with: f.body))
        let brep = try XCTUnwrap(body.brep)
        let top = try XCTUnwrap(OCCTKernel.faceInfo(brep).first { $0.normal.y > 0.99 })
        let ref = FaceRef(body: BodyRef(producer: f.source.id, bodyID: f.body), creator: f.source.id,
            role: .derived(index: 0), signature: try XCTUnwrap(top.signature), elementName: nil)
        let originalVolume = abs(OCCTKernel.volume(brep))
        var revision: UInt64 = 0
        for distance in [1.0, -10.0] {
            let node = FeatureNode(name: "Legacy push", kind: .pushPull(face: ref,
                distance: Expr(value: distance), mode: .planarAxial), outputBodyIDs: [f.body])
            let graph = FeatureGraph(nodes: f.document.session.document.features.nodes + [node])
            let result = graph.evaluate(sketches: [], planes: [], naming: SignatureNaming()) {
                revision += 1
                return revision
            }
            XCTAssertNotNil(result.errors[node.id], "Unrecorded identity cannot authorize a persistent edit")
            XCTAssertNil(result.proposedUpgrades[node.id], "Today's name is not proof of yesterday's selection")
            XCTAssertEqual(abs(OCCTKernel.volume(try XCTUnwrap(result.bodies.first { $0.id == f.body }?.brep))), originalVolume, accuracy: 1e-4)
            guard case let .pushPull(saved, _, _) = graph.nodes.last?.kind else {
                return XCTFail("Legacy operand was lost")
            }
            XCTAssertEqual(saved, ref, "Refusal must retain the original reference without inventing provenance")
        }
    }

    func testExplicitRepairIsNewIntentAndUndoReopenPreservesTheOriginalUnprovenReference() async throws {
        let f = try await fixture()
        let brep = try XCTUnwrap(f.document.session.document.body(with: f.body)?.brep)
        let top = try XCTUnwrap(OCCTKernel.faceInfo(brep).first { $0.normal.y > 0.99 })
        let old = FaceRef(body: BodyRef(producer: f.source.id, bodyID: f.body), creator: f.source.id,
            role: .derived(index: 0), signature: try XCTUnwrap(top.signature))
        let broken = FeatureNode(name: "Old unproven push", kind: .pushPull(face: old,
            distance: Expr(value: 1), mode: .planarAxial), outputBodyIDs: [f.body])
        f.document.session.recordAndRebuild([broken], title: "Old feature")
        XCTAssertNotNil(f.document.session.lastEvalErrors[broken.id])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let originalGraph = try encoder.encode(f.document.session.document.features)
        let undo = f.document.session.undoStack.undoCommands.count
        let model = f.document.viewModel()
        XCTAssertTrue(model.beginFeatureFaceEdit(broken.id), model.errorMessage ?? "")
        model.handle(.tap(ray: Ray(origin: SIMD3(10, 50, 5), direction: SIMD3(0, -1, 0))))
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(f.document.session.lastEvalErrors.isEmpty, "\(f.document.session.lastEvalErrors)")
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, undo + 1)
        XCTAssertEqual(try volume(f), 13_200 - 99 * .pi, accuracy: 1e-4)
        guard case let .pushPull(repaired, _, _)? = f.document.session.document.features.node(broken.id)?.kind else {
            return XCTFail("Repair must keep the existing feature ID")
        }
        XCTAssertNotEqual(repaired, old)
        XCTAssertTrue(try XCTUnwrap(repaired.elementName).isStableFaceIdentity)
        f.document.session.undo()
        XCTAssertEqual(try encoder.encode(f.document.session.document.features), originalGraph)
        XCTAssertEqual(try volume(f), 12_000 - 90 * .pi, accuracy: 1e-4)
        let saved = await f.document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let reopened = try await FloeCADDocument.open(at: f.document.url); documents.append(reopened)
        XCTAssertEqual(try encoder.encode(reopened.session.document.features), originalGraph)
        guard case let .pushPull(restored, _, _)? = reopened.session.document.features.node(broken.id)?.kind else {
            return XCTFail("Old operand was lost on reopen")
        }
        XCTAssertEqual(restored, old)
        XCTAssertNil(restored.elementName, "Saving or opening cannot invent original selection provenance")
        var revision: UInt64 = 0
        let refused = reopened.session.document.features.evaluate(sketches: [], planes: [], naming: SignatureNaming()) {
            revision += 1; return revision
        }
        XCTAssertNotNil(refused.errors[broken.id])
        XCTAssertNil(refused.proposedUpgrades[broken.id])
        let insertion = try ProjectMergeKit.insert(reopened.session.document, into: DesignDocument(),
            translation: SIMD3(100, 0, 0))
        let mergedBroken = try XCTUnwrap(insertion.document.features.nodes.last)
        guard case let .pushPull(mergedRef, _, _) = mergedBroken.kind else { return XCTFail("Merge lost old intent") }
        XCTAssertNil(mergedRef.elementName, "Merge may remap IDs but cannot bless an unproven old face")
        XCTAssertEqual(mergedRef.role, old.role)
        let merged = insertion.document.features.evaluate(sketches: [], planes: [], naming: SignatureNaming()) {
            revision += 1; return revision
        }
        XCTAssertNotNil(merged.errors[mergedBroken.id])
        XCTAssertNil(merged.proposedUpgrades[mergedBroken.id])
        reopened.close()
        f.document.session.redo()
        XCTAssertEqual(try volume(f), 13_200 - 99 * .pi, accuracy: 1e-4)
        guard case let .pushPull(redone, _, _)? = f.document.session.document.features.node(broken.id)?.kind else {
            return XCTFail("Redo lost repaired identity")
        }
        XCTAssertEqual(redone, repaired)
        let redoneSaved = await f.document.save(); XCTAssertTrue(redoneSaved.succeeded, redoneSaved.error ?? "")
        f.document.close()
        let repairedOpen = try await FloeCADDocument.open(at: f.document.url); documents.append(repairedOpen)
        guard case let .pushPull(finalRef, _, _)? = repairedOpen.session.document.features.node(broken.id)?.kind else {
            return XCTFail("Repaired identity was not saved")
        }
        XCTAssertEqual(finalRef, repaired)
        XCTAssertEqual(abs(OCCTKernel.volume(try XCTUnwrap(repairedOpen.session.document.body(with: f.body)?.brep))),
            13_200 - 99 * .pi, accuracy: 1e-4)
    }

    func testRecordedSemanticLegacyUpgradeRemainsAtomicAcrossKernelFailure() throws {
        let bodyID = BodyID()
        let source = FeatureNode(name: "Box", kind: .primitive(
            spec: .box(width: 40, depth: 30, height: 10), placement: .identity), outputBodyIDs: [bodyID])
        var revision: UInt64 = 0
        let original = FeatureGraph(nodes: [source]).evaluate(sketches: [], planes: [], naming: SignatureNaming()) {
            revision += 1; return revision
        }
        let body = try XCTUnwrap(original.bodies.first)
        let brep = try XCTUnwrap(body.brep)
        let top = try XCTUnwrap(OCCTKernel.faceInfo(brep).first { $0.normal.y > 0.99 })
        let ref = FaceRef(body: BodyRef(producer: source.id, bodyID: bodyID), creator: source.id,
            role: .boxFace(.py), signature: try XCTUnwrap(top.signature), elementName: nil)
        let originalVolume = abs(OCCTKernel.volume(brep))
        for distance in [1.0, -10.0] {
            let node = FeatureNode(name: "Semantic legacy push", kind: .pushPull(face: ref,
                distance: Expr(value: distance), mode: .planarAxial), outputBodyIDs: [bodyID])
            let result = FeatureGraph(nodes: [source, node]).evaluate(sketches: [], planes: [], naming: SignatureNaming()) {
                revision += 1; return revision
            }
            if distance > 0 {
                XCTAssertTrue(result.errors.isEmpty, "\(result.errors)")
                XCTAssertNotNil(result.proposedUpgrades[node.id], "Recorded primitive role is a legitimate legacy identity")
                XCTAssertGreaterThan(abs(OCCTKernel.volume(try XCTUnwrap(result.bodies.first?.brep))), originalVolume)
            } else {
                XCTAssertNotNil(result.errors[node.id])
                XCTAssertNil(result.proposedUpgrades[node.id], "Kernel failure must not persist a proposed identity")
                XCTAssertEqual(abs(OCCTKernel.volume(try XCTUnwrap(result.bodies.first?.brep))), originalVolume, accuracy: 1e-4)
            }
        }
    }

    func testPartialSignatureCollisionCannotAuthorizePersistentReplayOrUpgrade() throws {
        let bodyID = BodyID()
        var source = FeatureNode(name: "Source", kind: .primitive(
            spec: .box(width: 2, depth: 2, height: 1), placement: .identity), outputBodyIDs: [bodyID])
        var revision: UInt64 = 0
        let a = FeatureGraph(nodes: [source]).evaluate(sketches: [], planes: [], naming: SignatureNaming()) {
            revision += 1; return revision
        }
        source.kind = .primitive(spec: .box(width: 4, depth: 1, height: 1), placement: .identity)
        let b = FeatureGraph(nodes: [source]).evaluate(sketches: [], planes: [], naming: SignatureNaming()) {
            revision += 1; return revision
        }
        XCTAssertTrue(a.errors.isEmpty && b.errors.isEmpty)
        var before = try XCTUnwrap(a.bodies.first), after = try XCTUnwrap(b.bodies.first)
        let displayTable = try XCTUnwrap(b.faceTables[bodyID])
        let displayTop = try XCTUnwrap(displayTable.entries.first { $0.signature.normal.y > 0.99 })
        let displayRef = FaceRef(body: BodyRef(producer: source.id, bodyID: bodyID), creator: source.id,
            role: .derived(index: 0), signature: displayTop.signature)
        XCTAssertNotNil(SignatureNaming().resolve(displayRef, in: after, table: displayTable),
                        "A current display pick cannot borrow another tessellation's native face channel")
        XCTAssertNil(SignatureNaming().resolvePersisted(displayRef, in: after, table: displayTable))
        // Primitive display meshes are independent of the OCCT tessellation.
        // This fixture needs the actual adopted native channel, not a guessed
        // correspondence between Euclid triangles and native face indices.
        XCTAssertTrue(before.adoptBRep(try XCTUnwrap(before.brep)))
        XCTAssertTrue(after.adoptBRep(try XCTUnwrap(after.brep)))
        let topA = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(before.brep)).first { $0.normal.y > 0.99 })
        let topB = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(after.brep)).first { $0.normal.y > 0.99 })
        let signatureA = try XCTUnwrap(topA.signature), signatureB = try XCTUnwrap(topB.signature)
        XCTAssertTrue(SignatureNaming.exactSignature(signatureA, signatureB),
                      "Different 2x2 and 4x1 boundaries really collide under the old partial fingerprint")
        let naming = SignatureNaming()
        let beforeTable = ElementNaming.attach(try XCTUnwrap(a.kernelNames[bodyID]),
            to: naming.faceTable(for: before, createdBy: source.id, scheme: .primitive(.box(width: 2, depth: 2, height: 1))),
            channel: OCCTKernel.renderMeshFaceChannel(from: try XCTUnwrap(before.brep)), body: before)
        let table = ElementNaming.attach(try XCTUnwrap(b.kernelNames[bodyID]),
            to: naming.faceTable(for: after, createdBy: source.id, scheme: .primitive(.box(width: 4, depth: 1, height: 1))),
            channel: OCCTKernel.renderMeshFaceChannel(from: try XCTUnwrap(after.brep)), body: after)
        let renderedTopA = try XCTUnwrap(beforeTable.entries.first { $0.signature.normal.y > 0.99 })
        let renderedTopB = try XCTUnwrap(table.entries.first { $0.signature.normal.y > 0.99 })
        XCTAssertTrue(SignatureNaming.exactSignature(renderedTopA.signature, renderedTopB.signature),
                      "The live-pick fingerprint must also collide in the actual adopted render")
        var ref = FaceRef(body: BodyRef(producer: source.id, bodyID: bodyID), creator: source.id,
                          role: .derived(index: 0), signature: renderedTopA.signature)
        let pick = try XCTUnwrap(naming.resolve(ref, in: after, table: table),
                                "Current selection geometry must remain available")
        XCTAssertNotNil(pick.elementName, "Today's semantic name must not become an old unrecorded intent")
        XCTAssertFalse(pick.identityProof.permitsPersistentReplay)
        XCTAssertNil(ElementNaming.upgraded(ref, from: pick))
        XCTAssertNil(naming.resolvePersisted(ref, in: after, table: table))
        // A still-present result ordinal is no stronger than the nil name.
        for sourceName in [ElementName.Source.kernelFace(index: topB.index),
                           .opFace(operation: source.id, parents: [], index: topB.index)] {
            let name = ElementName(creator: source.id, source: sourceName)
            ref.elementName = name
            var ordinalTable = table
            ordinalTable.nativeFaceNames?[topB.index] = name
            for index in ordinalTable.entries.indices where ordinalTable.entries[index].elementName == pick.elementName {
                ordinalTable.entries[index].elementName = name
            }
            XCTAssertNotNil(naming.resolve(ref, in: after, table: ordinalTable))
            XCTAssertNil(naming.resolvePersisted(ref, in: after, table: ordinalTable))
        }
        ref.elementName = pick.elementName
        XCTAssertNotNil(naming.resolvePersisted(ref, in: after, table: table),
                        "An actually recorded qualified identity may follow its intended top face")
    }

    private func assertRemovedFaceRegionDoesNotRebind(compoundCutter: Bool) async throws {
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
        var compound = FeatureNode(name: "Two-slot tool", kind: .boolean(kind: .union,
            target: tools[0], tools: [tools[1]]), outputBodyIDs: [firstSlotID])
        let initialTools = compoundCutter ? [BodyRef(producer: compound.id, bodyID: firstSlotID)] : tools
        var cut = FeatureNode(name: "Three regions", kind: .boolean(kind: .subtract, target: target, tools: initialTools),
                              outputBodyIDs: [bodyID])
        var revision: UInt64 = 0
        func evaluate(_ nodes: [FeatureNode]) -> EvalResult {
            FeatureGraph(nodes: nodes).evaluate(sketches: [], planes: [], naming: SignatureNaming()) {
                revision += 1
                return revision
            }
        }
        let initial = evaluate([source, a, b] + (compoundCutter ? [compound] : []) + [cut])
        XCTAssertTrue(initial.errors.isEmpty, "\(initial.errors)")
        let input = try XCTUnwrap(initial.bodies.first { $0.id == bodyID })
        XCTAssertEqual(abs(OCCTKernel.volume(try XCTUnwrap(input.brep))), 10_000, accuracy: 1e-4)
        let table = try XCTUnwrap(initial.faceTables[bodyID])
        let tops = table.entries.filter { $0.signature.normal.y > 0.99 }
        XCTAssertEqual(tops.count, 3, "The fixture must really split one top face into three disconnected regions")
        // The original181 failure selected this actual left region. Modern
        // names no longer expose an ordinal, so select the same physical face
        // explicitly and keep the old wire as an additional rejection below.
        let picked = try XCTUnwrap(tops.min { $0.signature.centroid.x < $1.signature.centroid.x })
        XCTAssertEqual(picked.signature.centroid.x, -21.25, accuracy: 1e-5)
        let reference = FaceRef(body: BodyRef(producer: cut.id, bodyID: bodyID), creator: cut.id,
            role: picked.role, signature: picked.signature, elementName: picked.elementName)
        XCTAssertFalse(try XCTUnwrap(reference.elementName).requiresExactSignature,
                       "The actual split region needs a qualified topological identity")
        var wider = source
        wider.kind = .primitive(spec: .box(width: 80, depth: 20, height: 10), placement: .identity)
        let resized = evaluate([wider, a, b] + (compoundCutter ? [compound] : []) + [cut])
        XCTAssertTrue(resized.errors.isEmpty, "\(resized.errors)")
        let widerBody = try XCTUnwrap(resized.bodies.first { $0.id == bodyID })
        let widerTable = try XCTUnwrap(resized.faceTables[bodyID])
        let changed = try XCTUnwrap(SignatureNaming().resolve(reference, in: widerBody, table: widerTable))
        XCTAssertEqual(changed.elementName, reference.elementName)
        let changedEntry = try XCTUnwrap(widerTable.entries.first { $0.elementName == reference.elementName })
        XCTAssertEqual(changedEntry.signature.centroid.x, -26.25, accuracy: 1e-5)
        XCTAssertGreaterThan(changedEntry.signature.area, picked.signature.area,
                             "The same named region must follow a real dimension change, not its old fingerprint")
        let originalFace = try XCTUnwrap(SignatureNaming().resolve(reference, in: input, table: table)?.planar)
        let corners = originalFace.outline.map { originalFace.origin + originalFace.basisX * $0.x + originalFace.basisY * $0.y }
        let minimum = try XCTUnwrap(corners.map(\.x).min()), maximum = try XCTUnwrap(corners.map(\.x).max())
        let remove = FeatureNode(name: "Remove original region", kind: .primitive(
            spec: .box(width: maximum - minimum + 2, depth: 40, height: 30),
            placement: Transform3D(translation: SIMD3((minimum + maximum) / 2, -10, 0))), outputBodyIDs: [removalID])
        let removedTool = BodyRef(producer: remove.id, bodyID: removalID)
        let prefix: [FeatureNode]
        if compoundCutter {
            compound.kind = .boolean(kind: .union, target: tools[0], tools: [tools[1], removedTool])
            prefix = [source, a, b, remove, compound, cut]
        } else {
            cut.kind = .boolean(kind: .subtract, target: target, tools: tools + [removedTool])
            prefix = [source, a, b, remove, cut]
        }
        let actual = evaluate(prefix)
        XCTAssertTrue(actual.errors.isEmpty, "\(actual.errors)")
        let surviving = try XCTUnwrap(actual.bodies.first { $0.id == bodyID })
        let survivingTable = try XCTUnwrap(actual.faceTables[bodyID])
        XCTAssertEqual(survivingTable.entries.filter { $0.signature.normal.y > 0.99 }.count, 2)
        XCTAssertFalse(OCCTKernel.faceInfo(try XCTUnwrap(surviving.brep)).contains {
            $0.normal.y > 0.99 && simd_distance($0.centroid, picked.signature.centroid) < 1e-5
        }, "The selected physical region must actually have disappeared")
        let rebound = SignatureNaming().resolve(reference, in: surviving, table: survivingTable)
        var oldWire = reference
        oldWire.elementName = ElementName(creator: cut.id, source: .opFace(operation: cut.id,
            parents: [ElementName(creator: source.id, source: .primitiveFace(.boxFace(.py)))], index: 0))
        XCTAssertNil(SignatureNaming().resolve(oldWire, in: surviving, table: survivingTable),
                     "The original181 legacy ordinal must not be treated as a modern qualified name")
        var unnamed = reference
        unnamed.elementName = nil
        XCTAssertNil(SignatureNaming().resolve(unnamed, in: surviving, table: survivingTable),
                     "A deleted unnamed cap cannot select a nearby survivor by body-scaled scoring")
        let aliases = survivingTable.entries.filter { $0.elementName == picked.elementName }.map { $0.signature.centroid }
        let attachment = XCTAttachment(string: "Actual three-to-two OCCT face split; compoundCutter=\(compoundCutter), removed centroid=\(picked.signature.centroid), old name=\(String(describing: picked.elementName)), current alias centroids=\(aliases), resolved=\(rebound != nil)")
        attachment.name = "real-removed-three-face-fragment.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertNil(rebound, "A deleted face must not become the surviving fragment with its old ordinal")

        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("FaceSplit.floecad"), name: "Face split")
        documents.append(document)
        document.session.recordAndRebuild(prefix, title: "Two regions")
        let deletion = FeatureNode(name: "Original region operation", kind: .deleteFace(body: reference.body, faces: [reference]), outputBodyIDs: [bodyID])
        let failed = evaluate(prefix + [deletion])
        switch failed.errors[deletion.id] {
        case .brokenRef?: break
        default: XCTFail("The lost ordinal must fail resolution before any native healing: \(failed.errors)")
        }
        let retainedVolume = abs(OCCTKernel.volume(try XCTUnwrap(surviving.brep)))
        XCTAssertEqual(abs(OCCTKernel.volume(try XCTUnwrap(failed.bodies.first { $0.id == bodyID }?.brep))),
                       retainedVolume, accuracy: 1e-4)
        XCTAssertNil(failed.proposedUpgrades[deletion.id])
        document.session.record(deletion)
        let undo = document.session.undoStack.undoCommands.count
        let model = document.viewModel()
        XCTAssertFalse(model.beginDeleteFaceEdit(deletion.id))
        XCTAssertTrue(model.deleteFaceTargets.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undo)
        document.session.undo()
        XCTAssertEqual(document.session.document.features.nodes.last?.id, cut.id)
        document.session.redo()
        XCTAssertEqual(document.session.document.features.nodes.last?.id, deletion.id)
        guard case let .deleteFace(_, retained)? = document.session.document.features.node(deletion.id)?.kind else {
            return XCTFail("The original failed operation must remain available for repair")
        }
        XCTAssertEqual(retained, [reference])
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let identity = document.modelSHA256
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url)
        documents.append(reopened)
        XCTAssertEqual(reopened.modelSHA256, identity)
        XCTAssertEqual(reopened.session.document.features.nodes.last?.id, deletion.id)
        XCTAssertFalse(reopened.viewModel().beginDeleteFaceEdit(deletion.id))
        XCTAssertEqual(abs(OCCTKernel.volume(try XCTUnwrap(reopened.session.document.body(with: bodyID)?.brep))),
                       retainedVolume, accuracy: 1e-4)
    }

    func testOperationRegionIdentityIgnoresTraversalOrderAndRefusesAmbiguousOrUnknownHistory() throws {
        let creator = FeatureID(), operation = FeatureID()
        let top = ElementName(creator: creator, source: .primitiveFace(.boxFace(.py)))
        let left = ElementName(creator: creator, source: .primitiveFace(.boxFace(.nx)))
        let right = ElementName(creator: creator, source: .primitiveFace(.boxFace(.px)))
        let rows = [
            ShapeAncestry.Row(resultFace: 1, inputOrdinal: 0, inputKind: .face, inputSubshape: 1, relation: .modified),
            ShapeAncestry.Row(resultFace: 2, inputOrdinal: 0, inputKind: .face, inputSubshape: 1, relation: .modified),
            ShapeAncestry.Row(resultFace: 3, inputOrdinal: 0, inputKind: .face, inputSubshape: 2, relation: .same),
            ShapeAncestry.Row(resultFace: 4, inputOrdinal: 0, inputKind: .face, inputSubshape: 3, relation: .same)
        ]
        let input = [1: top, 2: left, 3: right]
        let adjacency = [(edge: 1, faceA: 1, faceB: 3), (edge: 2, faceA: 2, faceB: 4)]
        let names = ElementNaming.composeNames(operation: operation, ancestry: ShapeAncestry(rows: rows),
                                               inputNames: [input], adjacency: adjacency)
        XCTAssertFalse(try XCTUnwrap(names[1]).requiresExactSignature)
        XCTAssertFalse(try XCTUnwrap(names[2]).requiresExactSignature)
        XCTAssertNotEqual(names[1], names[2])
        let permutation = [1: 22, 2: 11, 3: 8, 4: 9]
        let reversed = rows.reversed().map {
            ShapeAncestry.Row(resultFace: permutation[$0.resultFace]!, inputOrdinal: $0.inputOrdinal,
                inputKind: $0.inputKind, inputSubshape: $0.inputSubshape, relation: $0.relation)
        }
        let remapped = ElementNaming.composeNames(operation: operation, ancestry: ShapeAncestry(rows: reversed),
            inputNames: [input], adjacency: adjacency.reversed().map {
                (edge: $0.edge, faceA: permutation[$0.faceB]!, faceB: permutation[$0.faceA]!)
            })
        for (before, after) in permutation { XCTAssertEqual(names[before], remapped[after]) }
        let ambiguous = ElementNaming.composeNames(operation: operation, ancestry: ShapeAncestry(rows: rows),
            inputNames: [input], adjacency: [(edge: 1, faceA: 1, faceB: 3), (edge: 2, faceA: 2, faceB: 3)])
        XCTAssertTrue(try XCTUnwrap(ambiguous[1]).requiresExactSignature)
        XCTAssertTrue(try XCTUnwrap(ambiguous[2]).requiresExactSignature)
        let noContext = ElementNaming.composeNames(operation: operation, ancestry: ShapeAncestry(rows: rows),
                                                 inputNames: [input])
        XCTAssertTrue(try XCTUnwrap(noContext[1]).requiresExactSignature)
        let old = try XCTUnwrap(noContext[1])
        let inherited = ElementNaming.composeNames(operation: FeatureID(), ancestry: ShapeAncestry(rows: [
            .init(resultFace: 7, inputOrdinal: 0, inputKind: .face, inputSubshape: 1, relation: .same)
        ]), inputNames: [[1: old]])
        XCTAssertEqual(inherited[7], old, "A later operation cannot promote an inherited unqualified ordinal")
        let unknown = ElementNaming.composeNames(operation: operation, ancestry: ShapeAncestry(rows: [
            .init(resultFace: 1, inputOrdinal: 0, inputKind: .face, inputSubshape: 99, relation: .generated)
        ]), inputNames: [input])
        XCTAssertTrue(try XCTUnwrap(unknown[1]).requiresExactSignature,
                      "A sole output with no named ancestor is still not an identity")
    }

    func testProfileBoundaryNeverGivesItsFirstGeneratedSiblingAQualifiedFaceName() throws {
        let sketch = Sketch(plane: .ground, entities: [.rect(id: UUID(), min: SIMD2(-2, -2), max: SIMD2(2, 2))])
        let profile = try XCTUnwrap(ProfileDetector.detectProfiles(in: sketch).first)
        let creator = FeatureID()
        var rows = (1...4).map {
            ShapeAncestry.Row(resultFace: $0, inputOrdinal: 0, inputKind: .edge,
                             inputSubshape: $0, relation: .generated)
        }
        rows += [rows[1], .init(resultFace: 5, inputOrdinal: 0, inputKind: .edge, inputSubshape: 1, relation: .generated)]
        let initial = ElementNaming.extrudeNames(creator: creator, ancestry: ShapeAncestry(rows: rows),
                                                outer: profile, holes: [])
        XCTAssertTrue(try XCTUnwrap(initial[1]).requiresExactSignature)
        XCTAssertTrue(try XCTUnwrap(initial[5]).requiresExactSignature)
        XCTAssertFalse(try XCTUnwrap(initial[2]).requiresExactSignature,
                       "A repeated history row is not another physical wall")
        XCTAssertFalse(initial.values.contains { if case .profileWall = $0.source { return true }; return false })
        let changed = ElementNaming.extrudeNames(creator: creator,
            ancestry: ShapeAncestry(rows: rows.filter { $0.resultFace != 1 }), outer: profile, holes: [])
        XCTAssertFalse(try XCTUnwrap(changed[5]).requiresExactSignature)
        XCTAssertNotEqual(initial[1], changed[5], "Deleting the first sibling must not hand its identity to the last one")
        let reversed = ElementNaming.extrudeNames(creator: creator,
            ancestry: ShapeAncestry(rows: Array(rows.reversed())), outer: profile, holes: [])
        XCTAssertEqual(initial, reversed)
    }

    func testRealBentSweepCannotTransferARemovedSegmentWallToTheRemainingSegment() throws {
        let sketch = Sketch(plane: .ground, entities: [.rect(id: UUID(), min: SIMD2(-2, -2), max: SIMD2(2, 2))])
        let profile = try XCTUnwrap(ProfileDetector.detectProfiles(in: sketch).first)
        let creator = FeatureID(), bodyID = BodyID()
        let spine = [SIMD3<Double>(0, 0, 0), SIMD3(0, 12, 0), SIMD3(12, 24, 0)]
        let history = OCCTShapeHistory()
        let original = try XCTUnwrap(OCCTKernel.sweepSolid(outer: profile, holes: [], plane: .ground,
                                                         spine: spine, helix: nil, history: history))
        XCTAssertTrue(OCCTKernel.healthReport(for: original).isValid)
        let ancestry = ShapeAncestry(history)
        let names = ElementNaming.extrudeNames(creator: creator, ancestry: ancestry, outer: profile, holes: [])
        let families = Dictionary(grouping: ancestry.rows.filter { $0.inputKind == .edge && $0.relation == .generated },
                                  by: { $0.inputSubshape }).mapValues { Set($0.map(\.resultFace)) }
        let originalFaces = OCCTKernel.faceInfo(original)
        // Fixed physical selection: the negative-Z wall of the first segment
        // from original186. Dictionary order must not pick an easier side.
        let removed = try XCTUnwrap(originalFaces.filter { face in
            face.normal.z < -0.99 && face.centroid.y < spine[1].y
                && families.values.contains { $0.count > 1 && $0.contains(face.index) }
        }.min { $0.index < $1.index })
        let family = try XCTUnwrap(families.values.first { $0.contains(removed.index) && $0.count > 1 },
                                  "The real bent pipe must generate multiple walls from one profile boundary")
        for index in family { XCTAssertTrue(try XCTUnwrap(names[index]).requiresExactSignature) }
        let name = try XCTUnwrap(names[removed.index])
        let reference = FaceRef(body: BodyRef(producer: creator, bodyID: bodyID), creator: creator,
            role: .derived(index: removed.index), signature: try XCTUnwrap(removed.signature), elementName: name)
        func body(_ brep: BRepHandle) throws -> Body {
            var value = Body(id: bodyID, name: "Actual swept wall", euclidMesh: Euclid.Mesh([]), revision: 1)
            XCTAssertTrue(value.adoptBRep(brep)); return value
        }
        let before = try body(original)
        let beforeTable = ElementNaming.attach(names, to: SignatureNaming().faceTable(for: before, createdBy: creator, scheme: .generic),
                                               channel: OCCTKernel.renderMeshFaceChannel(from: original), body: before)
        XCTAssertNotNil(SignatureNaming().resolve(reference, in: before, table: beforeTable))
        var stale = beforeTable
        stale.nativeMeshRevision = before.meshRevision + 1
        XCTAssertNil(SignatureNaming().resolve(reference, in: before, table: stale))
        var foreign = beforeTable
        foreign.nativeBodyID = BodyID()
        XCTAssertNil(SignatureNaming().resolve(reference, in: before, table: foreign))
        var missing = beforeTable
        missing.nativeFaceNames?.removeValue(forKey: removed.index)
        XCTAssertNil(SignatureNaming().resolve(reference, in: before, table: missing))
        var malformedChannel = beforeTable
        malformedChannel.nativeFaceChannel?.removeLast()
        XCTAssertNil(SignatureNaming().resolve(reference, in: before, table: malformedChannel))
        let channel = OCCTKernel.renderMeshFaceChannel(from: original)
        var claimed: Set<Int> = []
        for member in originalFaces.filter({ family.contains($0.index) }) {
            let operand = FaceRef(body: reference.body, creator: creator, role: .derived(index: member.index),
                signature: try XCTUnwrap(member.signature), elementName: try XCTUnwrap(names[member.index]))
            let resolved = try XCTUnwrap(SignatureNaming().resolve(operand, in: before, table: beforeTable))
            XCTAssertFalse(resolved.triangles.isEmpty)
            XCTAssertTrue(resolved.triangles.allSatisfy { channel[$0] == UInt32(member.index) },
                          "A merged display patch cannot include the neighboring native face")
            XCTAssertTrue(claimed.isDisjoint(with: resolved.triangles))
            claimed.formUnion(resolved.triangles)
        }
        var moved = SketchPlane.ground
        moved.origin = spine[1]
        let nextHistory = OCCTShapeHistory()
        let next = try XCTUnwrap(OCCTKernel.sweepSolid(outer: profile, holes: [], plane: moved,
            spine: Array(spine.dropFirst()), helix: nil, history: nextHistory))
        XCTAssertTrue(OCCTKernel.healthReport(for: next).isValid)
        let nextNames = ElementNaming.extrudeNames(creator: creator, ancestry: ShapeAncestry(nextHistory), outer: profile, holes: [])
        XCTAssertFalse(nextNames.values.contains(name))
        XCTAssertFalse(OCCTKernel.faceInfo(next).contains { simd_distance($0.centroid, removed.centroid) < 1e-5 })
        let after = try body(next)
        let afterTable = ElementNaming.attach(nextNames, to: SignatureNaming().faceTable(for: after, createdBy: creator, scheme: .generic),
                                              channel: OCCTKernel.renderMeshFaceChannel(from: next), body: after)
        XCTAssertNil(SignatureNaming().resolve(reference, in: after, table: afterTable))
        let attachment = XCTAttachment(string: "Actual bent native sweep: original multi-wall family=\(family.sorted()), selected centroid=\(removed.centroid); first spine segment removed, old name absent=\(!nextNames.values.contains(name)), original volume=\(OCCTKernel.volume(original)), remaining volume=\(OCCTKernel.volume(next)).")
        attachment.name = "actual-sweep-first-sibling-identity"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
