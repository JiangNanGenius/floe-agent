import Foundation
import XCTest
import simd
@testable import FloeCAD

@MainActor
final class CADShellOpeningTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []

    private struct Fixture {
        var document: FloeCADDocument
        var source: FeatureNode
        var body: BodyID
        var curvedFace: Int
    }

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloeShellOpenings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for document in documents { document.close() }
        documents = []
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    /// An exact half-cylinder: removing its curved side leaves connected end
    /// caps and a flat wall. Opening a full cylinder's side would instead
    /// disconnect both caps and is not an honest positive shell fixture.
    private func fixture(placement: Transform3D = .identity) async throws -> Fixture {
        let document = try await FloeCADDocument.create(
            at: directory.appendingPathComponent("\(UUID().uuidString).floecad"), name: "Curved opening")
        documents.append(document)
        let body = BodyID(), tool = BodyID()
        let cylinder = FeatureNode(name: "Cylinder", kind: .primitive(
            spec: .cylinder(radius: 10, height: 30), placement: placement), outputBodyIDs: [body])
        let cutter = FeatureNode(name: "Half cutter", kind: .primitive(
            spec: .box(width: 40, depth: 20, height: 40),
            placement: Transform3D(
                translation: placement.translation + placement.rotation.act(SIMD3(0, -5, 10) * placement.scale),
                rotation: placement.rotation, scale: placement.scale)), outputBodyIDs: [tool])
        let source = FeatureNode(name: "Half cylinder", kind: .boolean(kind: .subtract,
            target: BodyRef(producer: cylinder.id, bodyID: body),
            tools: [BodyRef(producer: cutter.id, bodyID: tool)]), outputBodyIDs: [body])
        document.session.recordAndRebuild([cylinder, cutter, source], title: "Half cylinder")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty, "\(document.session.lastEvalErrors)")
        let brep = try XCTUnwrap(document.session.document.body(with: body)?.brep)
        XCTAssertEqual(abs(OCCTKernel.volume(brep)), 1_500 * .pi * pow(placement.scale, 3), accuracy: 1e-4)
        let face = try XCTUnwrap(OCCTKernel.faceInfo(brep).first {
            guard let signature = $0.signature else { return false }
            if case .cylindrical = signature.kind { return true }
            return false
        })
        return Fixture(document: document, source: source, body: body, curvedFace: face.index)
    }

    private func volume(_ f: Fixture) throws -> Double {
        abs(OCCTKernel.volume(try XCTUnwrap(f.document.session.document.body(with: f.body)?.brep)))
    }

    private func assertWall(_ f: Fixture, thickness: Double,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let brep = try XCTUnwrap(f.document.session.document.body(with: f.body)?.brep, file: file, line: line)
        let planes = OCCTKernel.faceInfo(brep).filter {
            guard let signature = $0.signature else { return false }
            if case .planar = signature.kind { return true }
            return false
        }
        let z = planes.filter { abs($0.normal.z) > 0.999 }.map(\.centroid.z)
        XCTAssertGreaterThanOrEqual(z.count, 2, "Expected the actual flat wall's two surfaces", file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(z.max()) - XCTUnwrap(z.min()), thickness,
                       accuracy: 1e-4, file: file, line: line)
        let y = planes.filter { abs($0.normal.y) > 0.999 }.map(\.centroid.y)
        XCTAssertTrue(y.contains { abs($0 - thickness) < 1e-4 }, file: file, line: line)
        XCTAssertTrue(y.contains { abs($0 - (30 - thickness)) < 1e-4 }, file: file, line: line)
        XCTAssertGreaterThan(try volume(f), 0, file: file, line: line)
        XCTAssertLessThan(try volume(f), 1_500 * .pi, file: file, line: line)
    }

    @discardableResult
    private func shell(_ f: Fixture, thickness: Double = 1) throws -> FeatureNode {
        let response = CADCommandExecutor(viewModel: f.document.viewModel())
            .run(.shell(body: f.body, thickness: thickness, openFaces: [f.curvedFace]))
        XCTAssertEqual(response.status, 200, String(data: response.body, encoding: .utf8) ?? "")
        XCTAssertTrue(f.document.session.lastEvalErrors.isEmpty, "\(f.document.session.lastEvalErrors)")
        let node = try XCTUnwrap(f.document.session.document.features.nodes.last)
        guard case .shell = node.kind else { throw NSError(domain: "ExpectedShell", code: 1) }
        return node
    }

    func testPublicCurvedOpeningMeasuresActualWallsAndRetainsIdentityOnReopen() async throws {
        let f = try await fixture()
        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let initial = f.document.modelSHA256
        let undoCount = f.document.session.undoStack.undoCommands.count
        let feature = try shell(f)
        try assertWall(f, thickness: 1)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, undoCount + 1)
        let after = await f.document.save()
        XCTAssertTrue(after.succeeded, after.error ?? "")
        let identity = f.document.modelSHA256
        f.document.session.undo()
        XCTAssertEqual(try volume(f), 1_500 * .pi, accuracy: 1e-4)
        let undone = await f.document.save()
        XCTAssertTrue(undone.succeeded, undone.error ?? "")
        XCTAssertEqual(f.document.modelSHA256, initial)
        f.document.session.redo()
        try assertWall(f, thickness: 1)
        let redone = await f.document.save()
        XCTAssertTrue(redone.succeeded, redone.error ?? "")
        XCTAssertEqual(f.document.modelSHA256, identity)
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: f.document.url)
        documents.append(reopened)
        XCTAssertEqual(reopened.modelSHA256, identity)
        XCTAssertEqual(reopened.session.document.features.nodes.last?.id, feature.id)
        try assertWall(Fixture(document: reopened, source: f.source, body: f.body, curvedFace: f.curvedFace), thickness: 1)
        reopened.session.rebuildFrom(f.source.id)
        XCTAssertTrue(reopened.session.lastEvalErrors.isEmpty)
        try assertWall(Fixture(document: reopened, source: f.source, body: f.body, curvedFace: f.curvedFace), thickness: 1)
    }

    func testEditorTapSelectsTheWholeCurvedOpeningAndCommitsSameGeometry() async throws {
        let f = try await fixture()
        let model = f.document.viewModel()
        model.selectItemBody(f.body)
        model.beginShell()
        model.shellThickness = 1
        model.handle(.tap(ray: Ray(origin: SIMD3(0, 15, -30), direction: SIMD3(0, 0, 1))))
        XCTAssertEqual(model.shellSelectedFaces.count, 1)
        let face = try XCTUnwrap(model.shellSelectedFaces.first)
        XCTAssertNotNil(face.cylinder)
        XCTAssertGreaterThan(face.triangles.count, 2)
        let source = try XCTUnwrap(f.document.session.document.body(with: f.body))
        let point = try XCTUnwrap(EditorViewModel.shellOpenPoints(for: [face], mesh: source.render)?.first)
        XCTAssertEqual(hypot(point.x, point.z), 10, accuracy: 1e-5)
        XCTAssertLessThan(point.z, 0, "The point must lie on this half-cylinder, not the other half or the axis")
        XCTAssertTrue(model.canCommitShell)
        model.commitShell()
        XCTAssertTrue(f.document.session.lastEvalErrors.isEmpty)
        try assertWall(f, thickness: 1)
    }

    func testHistoryEditKeepsNamedInputOpeningAndChangesOnlyItsThickness() async throws {
        let f = try await fixture()
        let feature = try shell(f)
        guard case let .shell(_, faces, _) = feature.kind else { return XCTFail("Missing shell") }
        let name = try XCTUnwrap(faces.first?.elementName)
        let model = f.document.viewModel()
        XCTAssertTrue(model.beginShellEdit(feature.id), model.errorMessage ?? "")
        XCTAssertEqual(model.shellSelectedFaces.count, 1)
        XCTAssertEqual(model.shellSelectedFaces.first?.elementName, name)
        XCTAssertNotNil(model.shellSelectedFaces.first?.cylinder)
        model.shellThickness = 2
        XCTAssertTrue(model.canCommitShell)
        let count = f.document.session.document.features.nodes.count
        model.commitShell()
        XCTAssertEqual(f.document.session.document.features.nodes.count, count)
        XCTAssertEqual(f.document.session.document.features.nodes.last?.id, feature.id)
        try assertWall(f, thickness: 2)
        f.document.session.undo()
        try assertWall(f, thickness: 1)
        f.document.session.redo()
        try assertWall(f, thickness: 2)
        let saved = await f.document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: f.document.url)
        documents.append(reopened)
        XCTAssertTrue(reopened.viewModel().beginShellEdit(feature.id))
        try assertWall(Fixture(document: reopened, source: f.source, body: f.body, curvedFace: f.curvedFace), thickness: 2)
    }

    func testMissingNamedOrForeignOpeningRejectsTheEntireShellWithoutUpgrades() async throws {
        let f = try await fixture()
        let feature = try shell(f)
        guard case let .shell(ref, faces, _) = feature.kind else { return XCTFail("Missing shell") }
        var missing = try XCTUnwrap(faces.first)
        var name = try XCTUnwrap(missing.elementName)
        name.creator = FeatureID()
        missing.elementName = name
        var foreign = try XCTUnwrap(faces.first)
        foreign.body.bodyID = BodyID()
        var legacy = try XCTUnwrap(faces.first)
        legacy.elementName = nil
        f.document.session.undo()
        for refs in [[legacy, missing], [foreign]] {
            let node = FeatureNode(name: "Rejected opening", kind: .shell(
                body: ref, openFaces: refs, thickness: Expr(value: 1)), outputBodyIDs: [f.body])
            let graph = FeatureGraph(nodes: f.document.session.document.features.nodes + [node])
            var revision: UInt64 = 0
            let result = graph.evaluate(sketches: [], planes: [], naming: SignatureNaming()) {
                revision += 1
                return revision
            }
            XCTAssertNotNil(result.errors[node.id])
            XCTAssertNil(result.proposedUpgrades[node.id])
            let retained = try XCTUnwrap(result.bodies.first { $0.id == f.body })
            XCTAssertEqual(abs(OCCTKernel.volume(try XCTUnwrap(retained.brep))), 1_500 * .pi, accuracy: 1e-4)
        }
    }

    func testUnprovenHistoryAndMixedQualifiedOpeningNeverAdoptTodaysFace() async throws {
        let f = try await fixture()
        let good = try shell(f)
        guard case let .shell(reference, faces, _) = good.kind else { return XCTFail("Missing shell") }
        let qualified = try XCTUnwrap(faces.first)
        var unproven = qualified; unproven.elementName = nil; unproven.role = .derived(index: 0)
        f.document.session.undo()
        let bad = FeatureNode(name: "Unproven mixed shell", kind: .shell(
            body: reference, openFaces: [qualified, unproven], thickness: Expr(value: 1)), outputBodyIDs: [f.body])
        f.document.session.recordAndRebuild([bad], title: "Old mixed shell")
        XCTAssertNotNil(f.document.session.lastEvalErrors[bad.id])
        XCTAssertEqual(try volume(f), 1_500 * .pi, accuracy: 1e-4)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let graph = try encoder.encode(f.document.session.document.features)
        let undo = f.document.session.undoStack.undoCommands.count
        let model = f.document.viewModel()
        XCTAssertFalse(model.beginShellEdit(bad.id), "History is recovery of old intent, not a fresh selection")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.shellSelectedFaces.isEmpty)
        XCTAssertEqual(try encoder.encode(f.document.session.document.features), graph)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, undo)
        guard case let .shell(_, retained, _)? = f.document.session.document.features.node(bad.id)?.kind else {
            return XCTFail("Refusal lost the old operands")
        }
        XCTAssertEqual(retained, [qualified, unproven])
        f.document.session.undo()
        let source = try XCTUnwrap(f.document.session.document.body(with: f.body))
        let fresh = try XCTUnwrap(OCCTKernel.faceInfo(try XCTUnwrap(source.brep)).first { $0.index == f.curvedFace })
        let current = FaceRef(body: reference, creator: reference.producer,
            role: .derived(index: 0), signature: try XCTUnwrap(fresh.signature))
        XCTAssertNotNil(SignatureNaming().resolve(current, in: source, table: f.document.session.lastFaceTables[f.body]),
            "Refusing an old operand must leave current geometry selection usable")
    }

    func testKernelFailurePreservesSavedModelAndRedo() async throws {
        let f = try await fixture()
        _ = try shell(f)
        f.document.session.undo()
        let before = await f.document.save()
        XCTAssertTrue(before.succeeded, before.error ?? "")
        let identity = f.document.modelSHA256
        let ids = f.document.session.document.features.nodes.map(\.id)
        let count = f.document.session.undoStack.undoCommands.count
        let response = CADCommandExecutor(viewModel: f.document.viewModel())
            .run(.shell(body: f.body, thickness: 1_000, openFaces: [f.curvedFace]))
        XCTAssertEqual(response.status, 422)
        XCTAssertEqual(f.document.session.document.features.nodes.map(\.id), ids)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count)
        XCTAssertTrue(f.document.session.undoStack.canRedo)
        XCTAssertEqual(f.document.modelSHA256, identity)
        XCTAssertEqual(try volume(f), 1_500 * .pi, accuracy: 1e-4)
        f.document.session.redo()
        try assertWall(f, thickness: 1)
    }

    func testNonFiniteThicknessRejectsBeforeKernelWithoutChangingTheInput() async throws {
        let f = try await fixture()
        for thickness in [Double.nan, .infinity, -.infinity, 0] {
            let node = FeatureNode(name: "Invalid thickness", kind: .shell(
                body: BodyRef(producer: f.source.id, bodyID: f.body), openFaces: [],
                thickness: Expr(value: thickness)), outputBodyIDs: [f.body])
            let graph = FeatureGraph(nodes: f.document.session.document.features.nodes + [node])
            var revision: UInt64 = 0
            let result = graph.evaluate(sketches: [], planes: [], naming: SignatureNaming()) {
                revision += 1
                return revision
            }
            XCTAssertNotNil(result.errors[node.id])
            XCTAssertNil(result.proposedUpgrades[node.id])
            let retained = try XCTUnwrap(result.bodies.first { $0.id == f.body })
            XCTAssertEqual(abs(OCCTKernel.volume(try XCTUnwrap(retained.brep))), 1_500 * .pi, accuracy: 1e-4)
        }
    }

    func testRepeatedCurvedOpeningDoesNotCutADifferentSurface() async throws {
        let f = try await fixture()
        let first = try shell(f)
        let expected = try volume(f)
        guard case let .shell(body, faces, thickness) = first.kind else { return XCTFail("Missing shell") }
        f.document.session.undo()
        let node = FeatureNode(name: "Repeated opening", kind: .shell(
            body: body, openFaces: faces + faces, thickness: thickness), outputBodyIDs: [f.body])
        f.document.session.recordAndRebuild([node], title: "Repeated opening")
        XCTAssertTrue(f.document.session.lastEvalErrors.isEmpty, "\(f.document.session.lastEvalErrors)")
        XCTAssertEqual(try volume(f), expected, accuracy: 1e-4)
        try assertWall(f, thickness: 1)
    }

    func testPartialCylinderFitMeasuresTrueRadiusAfterTranslationRotationAndScale() async throws {
        let placement = Transform3D(translation: SIMD3(234, -47, 101),
            rotation: simd_quatd(angle: 0.67, axis: simd_normalize(SIMD3(1, 2, 3))), scale: 2)
        let f = try await fixture(placement: placement)
        let body = try XCTUnwrap(f.document.session.document.body(with: f.body))
        let faces = FaceTopology.enumerateFaces(in: body.render).cylindrical
        XCTAssertEqual(faces.count, 1)
        let cylinder = try XCTUnwrap(faces.first)
        XCTAssertEqual(cylinder.radius, 20, accuracy: 1e-3)
        let axis = placement.rotation.act(SIMD3<Double>(0, 1, 0))
        XCTAssertEqual(abs(simd_dot(cylinder.axisDir, axis)), 1, accuracy: 1e-5)
        let delta = cylinder.axisPoint - placement.translation
        XCTAssertLessThan(simd_length(delta - axis * simd_dot(delta, axis)), 1e-3)
        XCTAssertFalse(cylinder.matchesWholeBody, "A partial cylinder must not claim whole-body radial editing")
    }
}
