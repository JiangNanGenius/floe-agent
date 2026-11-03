import Foundation
import XCTest
import OCCTShim
import simd
@testable import FloeCAD

/// These assert independently measured OCCT geometry, never requested metadata.
@MainActor
final class CADShellRegionTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ShellRegions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        for document in documents { document.close() }
        if let directory { try FileManager.default.removeItem(at: directory) }
    }
    /// Preserve full real ASCII if byte idempotence fails; Data's XCTest
    /// description alone contains only a byte count and cannot be diffed.
    private func preserveBRepDifference(before: Data, after: Data?, stage: String) {
        guard after != before else { return }
        for (suffix, bytes) in [("before", before), ("after", after ?? Data())] {
            let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.plain-text")
            attachment.name = "M22-" + stage + "-" + suffix + ".brep.txt"
            attachment.lifetime = .keepAlways; add(attachment)
        }
        let a = String(decoding: before, as: UTF8.self).components(separatedBy: "\n")
        let b = String(decoding: after ?? Data(), as: UTF8.self).components(separatedBy: "\n")
        var differences: [String] = []
        for i in 0..<max(a.count, b.count) {
            let old = i < a.count ? a[i] : "<missing>"
            let new = i < b.count ? b[i] : "<missing>"
            if old != new { differences.append("line \(i+1)\n- \(old)\n+ \(new)") }
        }
        let attachment = XCTAttachment(string: differences.joined(separator: "\n"))
        attachment.name = "M22-" + stage + "-actual-ascii-diff.txt"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    private func fixture() async throws -> (document: FloeCADDocument, body: BodyID) {
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("\(UUID()).floecad"), name: "Regional shell")
        documents.append(document)
        let id = BodyID()
        let node = FeatureNode(name: "Box", kind: .primitive(spec: .box(width: 40, depth: 30, height: 20), placement: .identity), outputBodyIDs: [id])
        document.session.recordAndRebuild([node], title: "Box")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty)
        return (document, id)
    }
    private func handle(_ document: FloeCADDocument, _ id: BodyID) throws -> BRepHandle {
        try XCTUnwrap(document.session.document.body(with: id)?.brep)
    }
    private func faces(_ handle: BRepHandle) throws -> (top: Int, bottom: Int, right: Int) {
        let rows = OCCTKernel.faceInfo(handle)
        return (try XCTUnwrap(rows.first { $0.normal.y > 0.999 }?.index),
                try XCTUnwrap(rows.first { $0.normal.y < -0.999 }?.index),
                try XCTUnwrap(rows.first { $0.normal.x > 0.999 }?.index))
    }
    private func assertGeometry(_ handle: BRepHandle, right: Double = 3, bottom: Double = 2,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let rows = OCCTKernel.faceInfo(handle).filter { $0.signature?.kind == .planar }
        func coordinate(_ component: Int) -> [Double] {
            rows.filter { abs($0.normal[component]) > 0.999 }.map { $0.centroid[component] }.sorted()
        }
        let xs = coordinate(0), ys = coordinate(1), zs = coordinate(2)
        XCTAssertEqual(xs.count, 4, file: file, line: line)
        XCTAssertGreaterThanOrEqual(ys.count, 3, file: file, line: line)
        XCTAssertEqual(zs.count, 4, file: file, line: line)
        guard xs.count == 4, ys.count >= 3, zs.count == 4 else { return }
        XCTAssertEqual(xs[1] - xs[0], 1, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(xs[3] - xs[2], right, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(ys[1] - ys[0], bottom, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(zs[1] - zs[0], 1, accuracy: 1e-4, file: file, line: line)
        XCTAssertEqual(zs[3] - zs[2], 1, accuracy: 1e-4, file: file, line: line)
        let expected = 40 * 30 * 20 - (40 - 1 - right) * (30 - 2) * (20 - bottom)
        XCTAssertEqual(abs(OCCTKernel.volume(handle)), expected, accuracy: 1e-3, file: file, line: line)
        let health = OCCTKernel.healthReportDictionary(for: handle, runBOPCheck: true)
        XCTAssertEqual(health["valid"] as? Bool, true, "\(health)", file: file, line: line)
        XCTAssertEqual((health["counts"] as? [String: Int])?["solids"], 1, file: file, line: line)
        XCTAssertEqual(health["openFreeWires"] as? Int, 0, file: file, line: line)
        XCTAssertEqual(health["closedFreeWires"] as? Int, 0, file: file, line: line)
    }
    private func createShell(_ document: FloeCADDocument, _ id: BodyID) throws -> FeatureNode {
        let selected = try faces(handle(document, id))
        let response = CADCommandExecutor(viewModel: document.viewModel()).run(.shell(
            body: id, thickness: 1, openFaces: [selected.top], regions: [
                .init(face: selected.right, thickness: 3), .init(face: selected.bottom, thickness: 2)]))
        XCTAssertEqual(response.status, 200, String(data: response.body, encoding: .utf8) ?? "")
        return try XCTUnwrap(document.session.document.features.nodes.last)
    }
    func testNativeRegionsMeasureUnequalActualWallsVolumeHealthAndIndependentInput() throws {
        let source = try XCTUnwrap(OCCTKernel.primitiveShape(.box(width: 40, depth: 30, height: 20), placement: .identity))
        let selected = try faces(source)
        let before = try XCTUnwrap(OCCTKernel.serialize(source))
        let result = try OCCTKernel.regionShellResultWithAncestry(source, openFaces: [selected.top],
            thickness: 1, regions: [(selected.right, 3), (selected.bottom, 2)]).get()
        try assertGeometry(result.handle)
        XCTAssertEqual(OCCTKernel.serialize(source), before)
        XCTAssertEqual(abs(OCCTKernel.volume(source)), 24_000, accuracy: 1e-4)
        XCTAssertFalse(result.ancestry.rows.isEmpty)
    }
    func testServiceUpdateSameFeatureOneUndoAndSavedReopen() async throws {
        let (document, body) = try await fixture()
        let undoCount = document.session.undoStack.undoCommands.count
        let node = try createShell(document, body)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCount + 1)
        try assertGeometry(handle(document, body))
        guard case let .regionShell(_, _, definition) = node.kind else { return XCTFail("Expected regional shell") }
        XCTAssertTrue(definition.regions.allSatisfy { $0.face.elementName?.isStableFaceIdentity == true })
        let region = try XCTUnwrap(definition.regions.first { $0.thickness.value == 3 })
        let reply = CADParameterService(document: document).handle(action: "update", args: [
            "feature_id": node.id.raw.uuidString, "changes": [region.parameterKey: 4]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(document.session.document.features.nodes.last?.id, node.id)
        try assertGeometry(handle(document, body), right: 4)
        document.session.undo(); try assertGeometry(handle(document, body))
        document.session.redo(); try assertGeometry(handle(document, body), right: 4)
        let saved = await document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        let digest = document.modelSHA256
        document.close()
        let reopened = try await FloeCADDocument.open(at: document.url); documents.append(reopened)
        XCTAssertEqual(reopened.modelSHA256, digest)
        reopened.session.rebuildFrom(node.id)
        XCTAssertTrue(reopened.session.lastEvalErrors.isEmpty)
        try assertGeometry(handle(reopened, body), right: 4)
        XCTAssertTrue(reopened.viewModel().beginShellEdit(node.id))
        XCTAssertEqual(reopened.viewModel().shellWallRegions.count, 2)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: reopened.session.document), 7)
    }
    func testFailedNativeAndCommandKeepOriginalAndExistingRedo() async throws {
        let (document, body) = try await fixture()
        let selected = try faces(handle(document, body))
        _ = try createShell(document, body)
        document.session.undo()
        let raw = try XCTUnwrap(OCCTKernel.serialize(handle(document, body)))
        let ids = document.session.document.features.nodes.map(\.id)
        let count = document.session.undoStack.undoCommands.count
        let response = CADCommandExecutor(viewModel: document.viewModel()).run(.shell(body: body,
            thickness: 1, openFaces: [selected.top], regions: [.init(face: selected.right, thickness: 1_000)]))
        XCTAssertEqual(response.status, 422)
        XCTAssertEqual(document.session.document.features.nodes.map(\.id), ids)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, count)
        XCTAssertTrue(document.session.undoStack.canRedo)
        preserveBRepDifference(before: raw, after: OCCTKernel.serialize(try handle(document, body)), stage: "rejected-command")
        XCTAssertEqual(OCCTKernel.serialize(try handle(document, body)), raw)
        document.session.redo(); try assertGeometry(handle(document, body))
    }
    func testUniformAttemptsAndEditorPreviewNeverMutateSharedInputBRep() async throws {
        let (document, id) = try await fixture()
        let source = try handle(document, id)
        let input = try XCTUnwrap(OCCTKernel.serialize(source))
        let opening = try XCTUnwrap(OCCTKernel.faceSample(source, index: faces(source).top))
        let success = try OCCTKernel.shellResultWithAncestry(source, openingAt: [opening],
            thickness: 1, tolerance: OCCTKernel.matchTolerance(for: source)).get()
        XCTAssertLessThan(OCCTKernel.volume(success.handle), 24_000)
        XCTAssertFalse(success.ancestry.rows.isEmpty)
        // BRepTools VERSION_2 ASCII is deterministic native topology/geometry,
        // not JSON dictionary order. Keep exact bytes AND geometric evidence.
        preserveBRepDifference(before: input, after: OCCTKernel.serialize(source), stage: "uniform-success")
        XCTAssertEqual(OCCTKernel.serialize(source), input)
        let refused = OCCTKernel.shellResultWithAncestry(source, openingAt: [opening],
            thickness: 1_000, tolerance: OCCTKernel.matchTolerance(for: source))
        if case let .failure(error) = refused { XCTAssertFalse(error.message.isEmpty) }
        else { XCTFail("An oversized wall must be refused") }
        preserveBRepDifference(before: input, after: OCCTKernel.serialize(source), stage: "uniform-refusal")
        XCTAssertEqual(OCCTKernel.serialize(source), input)
        XCTAssertEqual(OCCTKernel.volume(source), 24_000, accuracy: 1e-6)
        let originalRender = try XCTUnwrap(document.session.document.body(with: id)?.render)
        let model = document.viewModel(); model.selectItemBody(id); model.beginShell()
        preserveBRepDifference(before: input, after: OCCTKernel.serialize(source), stage: "initial-preview")
        XCTAssertEqual(OCCTKernel.serialize(source), input, "The initial closed-hollow preview owns its native input.")
        model.handle(.tap(ray: Ray(origin: SIMD3(0, 60, 0), direction: SIMD3(0, -1, 0))))
        preserveBRepDifference(before: input, after: OCCTKernel.serialize(source), stage: "tap-prepare")
        XCTAssertEqual(OCCTKernel.serialize(source), input)
        model.cancelShell()
        XCTAssertEqual(document.session.document.body(with: id)?.render, originalRender)
    }

    func testEditorWallPickingUsesWholeNamedFaceAndHistoryRetainsRegionIDs() async throws {
        let (document, body) = try await fixture()
        let model = document.viewModel()
        model.selectItemBody(body); model.beginShell(); model.shellThickness = 1
        model.handle(.tap(ray: Ray(origin: SIMD3(0, 60, 0), direction: SIMD3(0, -1, 0))))
        XCTAssertEqual(model.shellSelectedFaces.count, 1)
        model.shellPickingRegions = true; model.shellRegionThickness = 3
        model.handle(.tap(ray: Ray(origin: SIMD3(80, 10, 0), direction: SIMD3(-1, 0, 0))))
        XCTAssertEqual(model.shellWallRegions.count, 1)
        let right = try XCTUnwrap(model.shellWallRegions.first?.face.native)
        XCTAssertEqual(right.signature.normal.x, 1, accuracy: 1e-8)
        XCTAssertEqual(right.triangles.count, 2)
        model.shellRegionThickness = 2
        model.handle(.tap(ray: Ray(origin: SIMD3(0, -40, 0), direction: SIMD3(0, 1, 0))))
        XCTAssertEqual(model.shellWallRegions.count, 2)
        let bottom = try XCTUnwrap(model.shellWallRegions.last?.face.native)
        XCTAssertEqual(bottom.signature.normal.y, -1, accuracy: 1e-8)
        XCTAssertEqual(bottom.triangles.count, 2)
        XCTAssertNotEqual(right.index, bottom.index)
        XCTAssertTrue(model.canCommitShell)
        let undoCount = document.session.undoStack.undoCommands.count
        model.commitShell()
        XCTAssertEqual(document.session.undoStack.undoCommands.count, undoCount + 1)
        try assertGeometry(handle(document, body))
        let node = try XCTUnwrap(document.session.document.features.nodes.last)
        XCTAssertTrue(model.beginShellEdit(node.id))
        let identities = model.shellWallRegions.map(\.id)
        model.setShellWallThickness(try XCTUnwrap(identities.first), value: 4)
        model.commitShell()
        try assertGeometry(handle(document, body), right: 4)
        XCTAssertTrue(model.beginShellEdit(node.id))
        XCTAssertEqual(model.shellWallRegions.map(\.id), identities)
    }
    /// A quarter sphere has two adjoining flat walls. Opening the spherical
    /// support leaves those walls connected; opening an entire sphere would
    /// intentionally leave no shell and is not a positive fixture.
    private func quarterSphere() async throws -> (document: FloeCADDocument, body: BodyID, curved: Int) {
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("\(UUID()).floecad"), name: "Spherical opening")
        documents.append(document)
        let id = BodyID(), x = BodyID(), z = BodyID()
        let sphere = FeatureNode(name: "Sphere", kind: .primitive(spec: .sphere(radius: 10), placement: .identity), outputBodyIDs: [id])
        let cutX = FeatureNode(name: "Cut X", kind: .primitive(spec: .box(width: 20, depth: 40, height: 40),
            placement: Transform3D(translation: SIMD3(-10, -10, 0))), outputBodyIDs: [x])
        let cutZ = FeatureNode(name: "Cut Z", kind: .primitive(spec: .box(width: 40, depth: 20, height: 40),
            placement: Transform3D(translation: SIMD3(0, -10, -10))), outputBodyIDs: [z])
        let source = FeatureNode(name: "Quarter sphere", kind: .boolean(kind: .subtract,
            target: BodyRef(producer: sphere.id, bodyID: id), tools: [
                BodyRef(producer: cutX.id, bodyID: x), BodyRef(producer: cutZ.id, bodyID: z)]), outputBodyIDs: [id])
        document.session.recordAndRebuild([sphere, cutX, cutZ, source], title: "Quarter sphere")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty, "\(document.session.lastEvalErrors)")
        let brep = try handle(document, id)
        XCTAssertEqual(abs(OCCTKernel.volume(brep)), 1_000 * .pi / 3, accuracy: 1e-3)
        let curved = try XCTUnwrap(OCCTKernel.faceInfo(brep).first {
            if case .nativeSurface(type: 3) = $0.signature?.kind { return true }; return false
        }?.index)
        return (document, id, curved)
    }
    /// Independent integral for the SAME R10 quarter sphere. Two planar
    /// wall slabs minus their overlap; no output mesh or requested-volume metadata.
    private func expectedSphericalWallVolume(_ t: Double) -> Double {
        let radius = 10.0, steps = 128, h = t / Double(steps)
        var overlap = 0.0
        for i in 0...steps {
            let x = Double(i) * h, wx = i == 0 || i == steps ? 1.0 : (i.isMultiple(of: 2) ? 2 : 4)
            for j in 0...steps {
                let z = Double(j) * h, wz = j == 0 || j == steps ? 1.0 : (j.isMultiple(of: 2) ? 2 : 4)
                overlap += wx * wz * 2 * sqrt(radius * radius - x * x - z * z)
            }
        }
        overlap *= h * h / 9
        return Double.pi * (radius * radius * t - t * t * t / 3) - overlap
    }

    private func assertSphericalOpening(_ handle: BRepHandle, thickness: Double,
                                         file: StaticString = #filePath, line: UInt = #line) {
        let planes = OCCTKernel.faceInfo(handle).filter { $0.signature?.kind == .planar }
        for component in [0, 2] {
            let coordinates = planes.filter { abs($0.normal[component]) > 0.999 }.map { $0.centroid[component] }.sorted()
            XCTAssertEqual(coordinates.count, 2, file: file, line: line)
            if coordinates.count == 2 {
                XCTAssertEqual(coordinates[1] - coordinates[0], thickness, accuracy: 1e-4, file: file, line: line)
            }
        }
        XCTAssertGreaterThan(abs(OCCTKernel.volume(handle)), 0, file: file, line: line)
        XCTAssertLessThan(abs(OCCTKernel.volume(handle)), 1_000 * .pi / 3, file: file, line: line)
        XCTAssertEqual(OCCTKernel.volume(handle), expectedSphericalWallVolume(thickness), accuracy: 1e-3, file: file, line: line)
        XCTAssertLessThanOrEqual(OCCTBridge.maxTolerance(of: handle.shape), 1e-5, file: file, line: line)
        let health = OCCTKernel.healthReportDictionary(for: handle, runBOPCheck: true)
        XCTAssertEqual(health["valid"] as? Bool, true, "\(health)", file: file, line: line)
        XCTAssertEqual(health["openFreeWires"] as? Int, 0, file: file, line: line)
        XCTAssertEqual(health["closedFreeWires"] as? Int, 0, file: file, line: line)
    }
    func testSphericalSupportOpeningThroughCommandAndExactEditorPicking() async throws {
        let f = try await quarterSphere()
        let model = f.document.viewModel()
        model.selectItemBody(f.body); model.beginShell(); model.shellThickness = 1
        model.handle(.tap(ray: Ray(origin: SIMD3(40, 10, 40), direction: simd_normalize(SIMD3(-1, 0, -1)))))
        let selected = try XCTUnwrap(model.shellSelectedFaces.first)
        let native = try XCTUnwrap(selected.native)
        XCTAssertEqual(native.index, f.curved)
        XCTAssertGreaterThan(native.triangles.count, 4)
        XCTAssertEqual(simd_distance(native.point, SIMD3(0, 10, 0)), 10, accuracy: 1e-6)
        XCTAssertTrue(model.canCommitShell)
        model.cancelShell()
        let original = try handle(f.document, f.body)
        let inputBytes = try XCTUnwrap(OCCTKernel.serialize(original))
        let exactAttempt = OCCTKernel.shellResultWithAncestry(original, openingAt: [native.point],
            thickness: 1, tolerance: OCCTKernel.matchTolerance(for: original))
        switch exactAttempt {
        case let .success(result):
            assertSphericalOpening(result.handle, thickness: 1)
            XCTAssertFalse(result.ancestry.rows.isEmpty)
            let planarSources = OCCTKernel.faceInfo(original).filter { $0.signature?.kind == .planar }
            let resultPlanes = Set(OCCTKernel.faceInfo(result.handle).filter { $0.signature?.kind == .planar }.map(\.index))
            for plane in planarSources {
                let rows = result.ancestry.rows.filter {
                    $0.inputOrdinal == 0 && $0.inputKind == .face && $0.inputSubshape == plane.index
                        && resultPlanes.contains($0.resultFace)
                }
                XCTAssertEqual(Set(rows.map(\.resultFace)).count, 2, "Outer and inner wall need real ancestry from this original support.")
                XCTAssertTrue(rows.contains { $0.relation == .generated })
            }
        case let .failure(error): XCTFail("Spherical native opening: \(error.message)")
        }
        XCTAssertEqual(OCCTKernel.serialize(original), inputBytes)
        let count = f.document.session.undoStack.undoCommands.count
        let response = CADCommandExecutor(viewModel: model).run(.shell(body: f.body, thickness: 1, openFaces: [f.curved]))
        XCTAssertEqual(response.status, 200, String(data: response.body, encoding: .utf8) ?? "")
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, count + 1)
        assertSphericalOpening(try handle(f.document, f.body), thickness: 1)
        let node = try XCTUnwrap(f.document.session.document.features.nodes.last)
        XCTAssertTrue(model.beginShellEdit(node.id))
        XCTAssertNotNil(model.shellSelectedFaces.first?.native)
        model.shellThickness = 2; model.commitShell()
        assertSphericalOpening(try handle(f.document, f.body), thickness: 2)
        f.document.session.undo(); assertSphericalOpening(try handle(f.document, f.body), thickness: 1)
        f.document.session.redo(); assertSphericalOpening(try handle(f.document, f.body), thickness: 2)
        let saved = await f.document.save(); XCTAssertTrue(saved.succeeded, saved.error ?? "")
        f.document.close()
        let reopened = try await FloeCADDocument.open(at: f.document.url); documents.append(reopened)
        reopened.session.rebuildFrom(node.id)
        XCTAssertTrue(reopened.session.lastEvalErrors.isEmpty)
        assertSphericalOpening(try handle(reopened, f.body), thickness: 2)
        XCTAssertTrue(reopened.viewModel().beginShellEdit(node.id))
    }
    func testOpeningWholeSphereHasNoPlanarWallSupportAndPreservesInput() throws {
        let source = try XCTUnwrap(OCCTKernel.primitiveShape(.sphere(radius: 10), placement: .identity))
        let face = try XCTUnwrap(OCCTKernel.faceInfo(source).first)
        let point = try XCTUnwrap(OCCTKernel.faceSample(source, index: face.index))
        let before = try XCTUnwrap(OCCTKernel.serialize(source))
        let result = OCCTKernel.shellResultWithAncestry(source, openingAt: [point], thickness: 1,
            tolerance: OCCTKernel.matchTolerance(for: source))
        if case let .failure(error) = result { XCTAssertFalse(error.message.isEmpty) }
        else { XCTFail("Removing every curved support cannot manufacture a wall.") }
        preserveBRepDifference(before: before, after: OCCTKernel.serialize(source), stage: "no-planar-support")
        XCTAssertEqual(OCCTKernel.serialize(source), before)
        XCTAssertEqual(OCCTKernel.volume(source), 4_000 * Double.pi / 3, accuracy: 1e-3)
    }

    func testRegionalWriterFloorAndFutureDefinitionStaysOpaque() async throws {
        let (document, body) = try await fixture()
        let node = try createShell(document, body)
        let encoder = JSONEncoder()
        let kind = try encoder.encode(node.kind)
        func assessment(_ data: Data) throws -> CADDocumentFormat.Assessment {
            try CADDocumentFormat.assess(planes: [], sketches: [], features: [
                CADFeatureRecord(featureID: node.id.raw, orderIndex: 0, name: node.name, suppressed: false,
                    kind: data, outputBodyIDs: try encoder.encode(node.outputBodyIDs))])
        }
        XCTAssertEqual(try assessment(kind).requiredVersion, 7)
        XCTAssertFalse(try assessment(kind).isOpaqueReadOnly)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: kind) as? [String: Any])
        var shell = try XCTUnwrap(raw["regionShell"] as? [String: Any])
        var definition = try XCTUnwrap(shell["definition"] as? [String: Any])
        definition["version"] = 2; definition["futureTransition"] = "exact-blend"
        shell["definition"] = definition; raw["regionShell"] = shell
        let futureBytes = try JSONSerialization.data(withJSONObject: raw)
        let future = try assessment(futureBytes)
        XCTAssertEqual(future.requiredVersion, 7)
        XCTAssertTrue(future.opaqueFeatures.contains(node.id.raw))
        XCTAssertTrue(future.isOpaqueReadOnly)
    }

}
