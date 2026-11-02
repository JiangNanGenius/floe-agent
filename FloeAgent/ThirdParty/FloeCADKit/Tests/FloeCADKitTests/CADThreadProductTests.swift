import Foundation
import XCTest
import simd
@testable import FloeCAD

/// New standard-product assertions. NOT the eight qualified custom normal-
/// section probes, and NOT executed by the private implementation lane.
@MainActor
final class CADThreadProductTests: XCTestCase {
    private var directory: URL!
    private var documents: [FloeCADDocument] = []
    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("MetricThread-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertTrue(OCCTKernel.useOCCTAsSourceOfTruth)
    }
    override func tearDown() async throws {
        for document in documents where !document.isClosed { document.close() }
        if let directory { try? FileManager.default.removeItem(at: directory) }
        documents = []
    }
    private struct Fixture {
        var document: FloeCADDocument
        var bodyID: BodyID
        var writer: FeatureID
        var source: [String: Any]
        var cylinder: OCCTKernel.ThreadCylinder
    }
    private func fixture(_ side: ThreadSpec.Side, oblique: Bool = false) async throws -> Fixture {
        let url = directory.appendingPathComponent("\(UUID()).floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Metric thread stock")
        documents.append(document)
        let outerID = UUID(), innerID = UUID()
        var entities: [SketchEntity] = [.circle(id: outerID, center: .zero, radius: side == .external ? 4 : 6)]
        if side == .internal { entities.append(.circle(id: innerID, center: .zero, radius: 3)) }
        let sketch = Sketch(name: "Stock", plane: .ground, entities: entities)
        let bodyID = BodyID()
        let feature = FeatureNode(name: "Stock", kind: .extrude(
            profile: ProfileRef(sketchID: sketch.id, entityIDs: [outerID],
                holeEntityIDs: side == .internal ? [[innerID]] : [], seedPoint: nil),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: 16),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []), extraProfiles: []),
            outputBodyIDs: [bodyID])
        document.session.recordAndRebuild([feature], extra: [AddSketchCommand(sketch: sketch)], title: "Stock")
        XCTAssertTrue(document.session.lastEvalErrors.isEmpty, "\(document.session.lastEvalErrors)")
        var writer = feature.id
        if oblique {
            let transform = Transform3D(translation: SIMD3(12, -4, 9),
                rotation: simd_quatd(angle: 0.7, axis: simd_normalize(SIMD3(1, 2, 3))))
            let move = FeatureNode(name: "Placement", kind: .transform(
                body: BodyRef(producer: feature.id, bodyID: bodyID), delta: transform), outputBodyIDs: [bodyID])
            document.session.recordAndRebuild([move], title: "Placement")
            writer = move.id
        }
        let reply = CADParameterService(document: document).handle(action: "thread.sources", args: [:])
        let rows = reply["rows"] as? [[String: Any]] ?? []
        let source = try XCTUnwrap(rows.first { $0["side"] as? String == side.rawValue }, "\(reply)")
        let acquired = try XCTUnwrap(document.session.associativeSource(for: bodyID))
        let index = try XCTUnwrap(source["face_index"] as? Int)
        let body = try XCTUnwrap(document.session.document.body(with: bodyID))
        let cylinder = try XCTUnwrap(OCCTKernel.threadCylinder(try XCTUnwrap(body.brep), faceIndex: index))
        return Fixture(document: document, bodyID: bodyID, writer: writer, source: source,
            cylinder: try cylinder.world(acquired.snapshot.body.transform))
    }
    @discardableResult
    private func create(_ f: Fixture, hand: ThreadSpec.Hand = .right,
                        phase: Double = 0, ends: ThreadSpec.Ends = .flatTrim,
                        mode: ThreadSpec.Representation = .geometry) throws -> FeatureID {
        var args: [String: Any] = ["diameter": 8, "pitch": 1.25, "effective_length": 8,
            "hand": hand.rawValue, "ends": ends.rawValue, "representation": mode.rawValue,
            "phase_degrees": phase, "side": f.source["side"] as? String ?? ""]
        for key in ["body_id", "face_index", "query_token"] { args[key] = f.source[key] }
        let reply = CADParameterService(document: f.document).handle(action: "thread.create", args: args)
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        return FeatureID(raw: try XCTUnwrap(UUID(uuidString: try XCTUnwrap(reply["feature_id"] as? String))))
    }
    private func spec(_ document: FloeCADDocument, _ id: FeatureID) throws -> ThreadSpec {
        guard case let .thread(_, spec)? = document.session.document.features.node(id)?.kind else {
            throw CADThreadError.invalid("Missing thread feature")
        }
        return spec
    }
    private func shape(_ f: Fixture) throws -> BRepHandle {
        try XCTUnwrap(f.document.session.document.body(with: f.bodyID)?.brep)
    }
    private func healthy(_ shape: BRepHandle) {
        let health = OCCTKernel.healthReport(for: shape)
        XCTAssertNil(health.error); XCTAssertTrue(health.isValid, health.findingsSummary)
        XCTAssertEqual(health.counts["solids"], 1); XCTAssertEqual(health.openFreeWires, 0)
    }
    private func distance(_ p: SIMD3<Double>, to a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = b - a, length2 = simd_dot(d, d)
        guard length2 > 1e-20 else { return simd_distance(p, a) }
        let t = min(1, max(0, simd_dot(p - a, d) / length2))
        return simd_distance(p, a + t * d)
    }
    /// Observe returned exact-kernel sections. Expected axial tooth corners,
    /// flank midpoints and pitch come from published BASIC-profile fractions,
    /// never ThreadKit.axialCutter, a sampled helix or rendered triangles.
    private func axialEvidence(_ shape: BRepHandle, f: Fixture, spec: ThreadSpec,
                               file: StaticString = #filePath, line: UInt = #line) {
        let p = 1.25, length = 8.0
        let major = 4.0, minor = 3.323417653293407
        let phase = spec.phaseRadians, sign = spec.hand == .right ? 1.0 : -1.0
        let offset = f.cylinder.lower + (spec.ends == .onePitchSetback ? p : 0)
        let initial = sign > 0 ? -p : length + p
        for theta in [0.0, Double.pi / 2] {
            let x = f.cylinder.radial, n = f.cylinder.axis
            let r = x * cos(theta) + simd_cross(n, x) * sin(theta)
            let section = OCCTKernel.sectionPolylines(shape, origin: f.cylinder.origin,
                normal: simd_cross(n, r), deflection: 0.00001)
            let segments = section.flatMap { Array(zip($0, $0.dropFirst())) }
            XCTAssertFalse(segments.isEmpty, file: file, line: line)
            var centers: [Double] = []
            for turn in -2..<12 {
                let z = initial + sign * p * (Double(turn) + (theta - phase) / (2 * .pi))
                guard z > p, z < length - p else { continue }
                centers.append(z)
                let rootHalf = spec.side == .external ? p / 8 : p / 16
                let rootRadius = spec.side == .external ? minor : major
                let flankHalf = spec.side == .external ? 9 * p / 32 : 7 * p / 32
                let edgeHalf = spec.side == .external ? 7 * p / 16 : 3 * p / 8
                let edgeRadius = spec.side == .external ? major : minor
                for (radius, axial) in [(rootRadius, rootHalf), (rootRadius, -rootHalf),
                                        ((major + minor) / 2, flankHalf), ((major + minor) / 2, -flankHalf),
                                        (edgeRadius, edgeHalf), (edgeRadius, -edgeHalf)] {
                    let expected = f.cylinder.origin + r * radius + n * (offset + z + axial)
                    let error = segments.map { distance(expected, to: $0.0, $0.1) }.min() ?? .infinity
                    XCTAssertLessThan(error, 0.0003, "Axial basic-profile corner/flank error; theta=\(theta), phase=\(phase)", file: file, line: line)
                }
            }
            centers.sort()
            XCTAssertGreaterThan(centers.count, 2, file: file, line: line)
            for pair in zip(centers, centers.dropFirst()) {
                XCTAssertEqual(pair.1 - pair.0, p, accuracy: 1e-10, file: file, line: line)
            }
        }
    }
    private func exactFiles(_ url: URL) throws -> [String: Data] {
        let names = try FileManager.default.subpathsOfDirectory(atPath: url.path)
        var result: [String: Data] = [:]
        for name in names {
            let path = url.appendingPathComponent(name)
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path.path, isDirectory: &directory), !directory.boolValue {
                result[name] = try Data(contentsOf: path)
            }
        }
        return result
    }

    func testReviewedBasicDimensionsAndAxialFlankFractions() async throws {
        let f = try await fixture(.external)
        let id = try create(f, mode: .schematic), s = try spec(f.document, id)
        XCTAssertEqual(s.pitchDiameter, 7.188101183952089, accuracy: 1e-12)
        XCTAssertEqual(s.minorRadius * 2, 6.646835306586814, accuracy: 1e-12)
        let cutter = ThreadKit.axialCutter(s, overlap: 0)
        let flank = cutter[1] - cutter[0]
        XCTAssertEqual(atan2(abs(flank.x), abs(flank.y)), .pi / 3, accuracy: 1e-12)
        XCTAssertEqual(cutter[3].y - cutter[0].y, 1.25 / 4, accuracy: 1e-12)
        XCTAssertFalse(ThreadCatalog.pitches(for: 8).contains(0.7))
    }
    func testExternalRightHandAxialProfileAtZeroPhase() async throws {
        let f = try await fixture(.external); let id = try create(f)
        healthy(try shape(f)); axialEvidence(try shape(f), f: f, spec: try spec(f.document, id))
    }
    func testExternalLeftHandAxialProfileAtZeroPhase() async throws {
        let f = try await fixture(.external); let id = try create(f, hand: .left)
        healthy(try shape(f)); axialEvidence(try shape(f), f: f, spec: try spec(f.document, id))
    }
    func testInternalRightHandAxialProfileAtZeroPhase() async throws {
        let f = try await fixture(.internal)
        let stock = try shape(f)
        let id = try create(f)
        let s = try spec(f.document, id)
        var stages: [[String: Any]] = []
        _ = try ThreadKit.apply(s, cylinder: f.cylinder, target: stock, targetNames: [:], operation: FeatureID()) { name, shape in
            let sections = OCCTKernel.sectionPolylines(shape, origin: f.cylinder.origin,
                normal: simd_cross(f.cylinder.axis, f.cylinder.radial), deflection: 0.00001)
            stages.append(["stage": name, "volume": OCCTKernel.volume(shape),
                "section": sections.map { $0.map { [$0.x, $0.y, $0.z] } }])
        }
        let evidence: [String: Any] = ["stages": stages,
            "origin": [f.cylinder.origin.x, f.cylinder.origin.y, f.cylinder.origin.z],
            "axis": [f.cylinder.axis.x, f.cylinder.axis.y, f.cylinder.axis.z],
            "radial": [f.cylinder.radial.x, f.cylinder.radial.y, f.cylinder.radial.z],
            "lower": f.cylinder.lower, "upper": f.cylinder.upper]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "M13 actual internal thread intermediate sections.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        healthy(try shape(f)); axialEvidence(try shape(f), f: f, spec: try spec(f.document, id))
    }
    func testInternalLeftHandAxialProfileAtZeroPhase() async throws {
        let f = try await fixture(.internal); let id = try create(f, hand: .left)
        healthy(try shape(f)); axialEvidence(try shape(f), f: f, spec: try spec(f.document, id))
    }
    func testNonzeroPhaseBothSidesCannotHideInitialPlacementError() async throws {
        for side in ThreadSpec.Side.allCases {
            for hand in ThreadSpec.Hand.allCases {
                let f = try await fixture(side); let id = try create(f, hand: hand, phase: 60)
                axialEvidence(try shape(f), f: f, spec: try spec(f.document, id))
            }
        }
    }
    func testOnePitchSetbackHasRealUnthreadedEndsAndEffectiveLength() async throws {
        let f = try await fixture(.external); let id = try create(f, ends: .onePitchSetback)
        axialEvidence(try shape(f), f: f, spec: try spec(f.document, id))
        let old = try XCTUnwrap(f.document.session.inputBody(for: id, bodyID: f.bodyID)?.brep)
        let normal = f.cylinder.axis
        for z in [0.5, 10.0] {
            let origin = f.cylinder.origin + normal * z
            let before = OCCTKernel.sectionPolylines(old, origin: origin, normal: normal, deflection: 0.001).flatMap { $0 }
            let after = OCCTKernel.sectionPolylines(try shape(f), origin: origin, normal: normal, deflection: 0.001).flatMap { $0 }
            XCTAssertFalse(before.isEmpty); XCTAssertFalse(after.isEmpty)
            XCTAssertEqual(after.map { simd_length($0 - origin) }.max() ?? 0,
                           before.map { simd_length($0 - origin) }.max() ?? 0, accuracy: 0.001)
        }
    }
    func testSchematicPreservesOriginalBodyAndIsExplicitInQueries() async throws {
        let f = try await fixture(.external)
        let before = try XCTUnwrap(f.document.session.document.body(with: f.bodyID))
        let bytes = try XCTUnwrap(OCCTKernel.serialize(try XCTUnwrap(before.brep)))
        let id = try create(f, mode: .schematic)
        let after = try XCTUnwrap(f.document.session.document.body(with: f.bodyID))
        XCTAssertEqual(after.render, before.render); XCTAssertEqual(after.uvData, before.uvData)
        XCTAssertEqual(after.transform, before.transform); XCTAssertEqual(after.material, before.material)
        XCTAssertEqual(OCCTKernel.serialize(try XCTUnwrap(after.brep)), bytes)
        let row = CADThreadService.describe(try spec(f.document, id))
        XCTAssertEqual(row["exact_thread_geometry"] as? Bool, false)
        XCTAssertEqual(row["schematic_keeps_original_solid"] as? Bool, true)
    }
    func testSameFeatureSizePitchLengthEndModeEditUndoSaveReopen() async throws {
        let f = try await fixture(.external); let id = try create(f, mode: .schematic)
        let count = f.document.session.document.features.nodes.count
        let reply = CADParameterService(document: f.document).handle(action: "thread.update", args: [
            "feature_id": id.raw.uuidString, "changes": ["diameter": 6, "pitch": 1, "effective_length": 6,
                "hand": "left", "ends": "onePitchSetback", "representation": "geometry"]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(f.document.session.document.features.nodes.count, count)
        XCTAssertEqual(try spec(f.document, id).diameter, 6)
        f.document.session.undo(); XCTAssertEqual(try spec(f.document, id).representation, .schematic)
        f.document.session.redo(); XCTAssertEqual(try spec(f.document, id).representation, .geometry)
        let save = await f.document.save(); XCTAssertTrue(save.succeeded, save.error ?? "")
        let url = f.document.url; f.document.close()
        let opened = try await FloeCADDocument.open(at: url); documents.append(opened)
        let restored = try spec(opened, id)
        XCTAssertEqual(restored.diameter, 6); XCTAssertEqual(restored.pitch.value, 1)
        XCTAssertEqual(restored.effectiveLength.value, 6); XCTAssertEqual(restored.hand, .left)
        XCTAssertEqual(restored.ends, .onePitchSetback); XCTAssertEqual(restored.representation, .geometry)
        let edit = CADParameterService(document: opened).handle(action: "thread.update", args: [
            "feature_id": id.raw.uuidString, "changes": ["effective_length": 7]])
        XCTAssertEqual(edit["ok"] as? Bool, true, "\(edit)")
        XCTAssertEqual(opened.session.document.features.nodes.count, count)
    }
    func testGenericParameterUpdateEditsSameThreadFeature() async throws {
        let f = try await fixture(.external); let id = try create(f, mode: .schematic)
        let beforeCount = f.document.session.document.features.nodes.count
        let node = try XCTUnwrap(f.document.session.document.features.node(id))
        let descriptor = CADParameterService.describe(node, document: f.document.session.document)
        XCTAssertEqual(descriptor["kind"] as? String, "thread")
        let reply = CADParameterService(document: f.document).handle(action: "update", args: [
            "feature_id": id.raw.uuidString, "changes": ["effective_length": 7, "hand": "left"]])
        XCTAssertEqual(reply["ok"] as? Bool, true, "\(reply)")
        XCTAssertEqual(try spec(f.document, id).effectiveLength.value, 7)
        XCTAssertEqual(try spec(f.document, id).hand, .left)
        XCTAssertEqual(f.document.session.document.features.nodes.count, beforeCount)
    }
    func testStaleSourceQueryAndUnsupportedPitchCannotCreateFeature() async throws {
        let f = try await fixture(.external)
        let count = f.document.session.document.features.nodes.count
        let generation = f.document.session.changeCount
        var args: [String: Any] = ["diameter": 8, "pitch": 0.7, "effective_length": 8,
            "representation": "schematic"]
        for key in ["body_id", "face_index", "query_token"] { args[key] = f.source[key] }
        let service = CADParameterService(document: f.document)
        let pitch = service.handle(action: "thread.create", args: args)
        XCTAssertEqual(pitch["ok"] as? Bool, false)
        XCTAssertEqual(f.document.session.document.features.nodes.count, count)
        XCTAssertEqual(f.document.session.changeCount, generation)
        f.document.session.perform(AddSketchCommand(sketch: Sketch(name: "Unrelated", plane: .ground)))
        args["pitch"] = 1.25
        let stale = service.handle(action: "thread.create", args: args)
        XCTAssertEqual(stale["ok"] as? Bool, false)
        XCTAssertEqual(f.document.session.document.features.nodes.count, count)
    }

    func testVariableExpressionUsesExistingFeatureSetterAndFanout() async throws {
        let f = try await fixture(.external); let id = try create(f, mode: .schematic)
        let service = CADParameterService(document: f.document)
        XCTAssertEqual(service.handle(action: "variable.create", args: ["name": "threadLength", "expression": "8"])["ok"] as? Bool, true)
        let bind = service.handle(action: "feature.setExpression", args: ["feature_id": id.raw.uuidString,
            "parameter": "effective_length", "expression": "threadLength"])
        XCTAssertEqual(bind["ok"] as? Bool, true, "\(bind)")
        XCTAssertEqual(try spec(f.document, id).effectiveLength.formula, "threadLength")
        let variable = try XCTUnwrap(f.document.session.document.variables.first { $0.name == "threadLength" })
        let edit = service.handle(action: "variable.update", args: ["variable_id": variable.id.raw.uuidString, "expression": "10"])
        XCTAssertEqual(edit["ok"] as? Bool, true, "\(edit)")
        XCTAssertEqual(try spec(f.document, id).effectiveLength.value, 10)
        f.document.session.undo(); XCTAssertEqual(try spec(f.document, id).effectiveLength.value, 8)
    }
    func testInvalidStockAndStaleEditsPreserveSourceBytesUndoRedo() async throws {
        let f = try await fixture(.external); let id = try create(f, mode: .schematic)
        let save = await f.document.save(); XCTAssertTrue(save.succeeded)
        let files = try exactFiles(f.document.url), before = try spec(f.document, id)
        let persistence = f.document.session.persistenceChangeCount
        let depth = f.document.session.undoStack.undoCommands.count, redo = f.document.session.undoStack.redoCommands.count
        let failed = CADParameterService(document: f.document).handle(action: "thread.update", args: [
            "feature_id": id.raw.uuidString, "changes": ["diameter": 12, "pitch": 1.75, "representation": "geometry"]])
        XCTAssertEqual(failed["ok"] as? Bool, false)
        XCTAssertEqual(try spec(f.document, id), before)
        XCTAssertEqual(f.document.session.persistenceChangeCount, persistence)
        XCTAssertEqual(f.document.session.undoStack.undoCommands.count, depth)
        XCTAssertEqual(f.document.session.undoStack.redoCommands.count, redo)
        XCTAssertEqual(try exactFiles(f.document.url), files)
        let stale = CADParameterService(document: f.document).handle(action: "thread.update", args: [
            "feature_id": id.raw.uuidString, "expected_change_count": -1, "changes": ["effective_length": 6]])
        XCTAssertEqual(stale["error"] as? String, "stale_thread")
        XCTAssertEqual(try spec(f.document, id), before)
    }
    func testSourceDeletionIsHardDependencyAndInsertIsExplicitlyUnsupported() async throws {
        let f = try await fixture(.external); let id = try create(f, mode: .schematic)
        let before = f.document.session.persistenceChangeCount
        f.document.session.deleteFeature(f.writer)
        XCTAssertEqual(f.document.session.persistenceChangeCount, before)
        XCTAssertNotNil(f.document.session.document.features.node(f.writer))
        XCTAssertNotNil(f.document.session.document.features.node(id))
        XCTAssertThrowsError(try ProjectMergeKit.insert(f.document.session.document, into: DesignDocument()))
    }
    func testConditionalFloorFutureOpaqueAndCorruptKnownContract() async throws {
        let f = try await fixture(.external)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: f.document.session.document), 1)
        let id = try create(f, mode: .schematic)
        XCTAssertEqual(CADDocumentFormat.requiredFormat(document: f.document.session.document), 7)
        let save = await f.document.save(); XCTAssertTrue(save.succeeded, save.error ?? "")
        let record = try FileCADDocumentStore(packageURL: f.document.url).verifiedPackage(at: f.document.url).document
        var row = try XCTUnwrap(record.features.first { $0.featureID == id.raw })
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: row.kind) as? [String: Any])
        var payload = try XCTUnwrap(original["thread"] as? [String: Any])
        var value = try XCTUnwrap(payload["spec"] as? [String: Any])
        value["version"] = 2; payload["spec"] = value
        row.kind = try JSONSerialization.data(withJSONObject: ["thread": payload])
        let future = try CADDocumentFormat.assess(planes: [], sketches: [], features: [row])
        XCTAssertEqual(future.requiredVersion, 7); XCTAssertTrue(future.opaqueFeatures.contains(id.raw))
        value["version"] = true; payload["spec"] = value
        row.kind = try JSONSerialization.data(withJSONObject: ["thread": payload])
        XCTAssertThrowsError(try CADDocumentFormat.assess(planes: [], sketches: [], features: [row]))
    }
    func testExactSTEPAndBRepRoundTripsRetainAxialProfile() async throws {
        let f = try await fixture(.external); let id = try create(f)
        let shape = try shape(f), s = try spec(f.document, id)
        let bytes = try XCTUnwrap(OCCTKernel.serialize(shape))
        let restored = try XCTUnwrap(OCCTKernel.deserialize(bytes))
        healthy(restored); axialEvidence(restored, f: f, spec: s)
        let path = directory.appendingPathComponent("thread.step")
        XCTAssertTrue(OCCTKernel.writeSTEP([shape], to: path))
        let read = OCCTKernel.readSTEP(from: path)
        XCTAssertEqual(read.count, 1)
        let exact = try XCTUnwrap(read.first)
        healthy(exact); axialEvidence(exact, f: f, spec: s)
        XCTAssertEqual(OCCTKernel.volume(exact), OCCTKernel.volume(shape), accuracy: 1e-4)
    }
    func testObliqueSourceKeepsStandardAxialGeometry() async throws {
        let f = try await fixture(.external, oblique: true); let id = try create(f)
        healthy(try shape(f)); axialEvidence(try shape(f), f: f, spec: try spec(f.document, id))
    }
}
