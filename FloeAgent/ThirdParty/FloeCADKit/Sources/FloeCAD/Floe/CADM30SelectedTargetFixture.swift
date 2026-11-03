// SPDX-License-Identifier: MPL-2.0
// Synthetic seeds/readback only. Never sets selection or performs the model edit.
#if DEBUG
import Foundation
import simd

public struct CADM30TargetDescriptor: Codable, Sendable {
    public enum Target: String, Codable, CaseIterable, Sendable { case hole, thread, surface, datum }
    public var target: Target
    public var targetKind: String
    public var targetID: String
    public var targetName: String
    public var bodyID: String
    public var featureIDs: [String]
    public var planeIDs: [String]
    public var sketchID: String?
    public var entityID: String?
    public var variableID: String?
    public var editPayloadJSON: String
    public var initialValue: Double
    public var editedValue: Double
    public var cylinderOrigin: [Double]?
    public var cylinderAxis: [Double]?
    public var cylinderRadial: [Double]?
    public var cylinderLower: Double?
}

@MainActor public enum CADM30SelectedTargetFixture {
    public static func fail(_ message: String) -> CADDocumentError {
        CADDocumentError(code: "m30_fixture", message: message)
    }
    private static func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    private static func call(_ document: FloeCADDocument, _ action: String,
                             _ args: [String: Any] = [:]) throws -> [String: Any] {
        let result = CADParameterService(document: document).handle(action: action, args: args)
        guard result["ok"] as? Bool == true else { throw fail("\(action): \(result)") }
        return result
    }
    private static func id(_ reply: [String: Any], _ key: String) throws -> String {
        guard let value = (key == "variable_id" ? (reply["variable"] as? [String: Any])?["id"] as? String : reply[key] as? String), UUID(uuidString: value) != nil else { throw fail("Missing \(key)") }
        return value
    }
    private static func stock(_ doc: FloeCADDocument, circular: Bool = false) throws -> (FeatureNode, BodyID) {
        let entity = UUID()
        let sketch = Sketch(name: "M30 stock", plane: .ground, entities: circular
            ? [.circle(id: entity, center: .zero, radius: 4)]
            : [.rect(id: entity, min: .zero, max: SIMD2(100, 60))])
        let body = BodyID()
        let node = FeatureNode(name: "M30 stock", kind: .extrude(
            profile: ProfileRef(sketchID: sketch.id, entityIDs: [entity], holeEntityIDs: [], seedPoint: nil),
            plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: circular ? 16 : 10),
            symmetric: false, boolean: BooleanIntent(op: .newBody, resolvedTargets: []), extraProfiles: []), outputBodyIDs: [body])
        doc.session.recordAndRebuild([node], extra: [AddSketchCommand(sketch: sketch)], title: "M30 synthetic stock")
        try healthySession(doc)
        return (node, body)
    }
    private static func healthySession(_ doc: FloeCADDocument) throws {
        guard doc.session.lastEvalErrors.isEmpty, doc.session.lastReferenceErrors.isEmpty else {
            throw fail("Native replay errors: \(doc.session.lastEvalErrors) \(doc.session.lastReferenceErrors)")
        }
    }
    public static func seed(_ target: CADM30TargetDescriptor.Target, at url: URL)
    async throws -> (FloeCADDocument, CADM30TargetDescriptor) {
        guard OCCTKernel.useOCCTAsSourceOfTruth else { throw fail("Exact OCCT source of truth is required") }
        guard !FileManager.default.fileExists(atPath: url.path) else { throw fail("Never reseed an existing M30 file") }
        let doc = try await FloeCADDocument.create(at: url, name: "M30 \(target.rawValue) TEST-CREATED")
        do {
            var targetID = "", name = "", targetKind = "feature", bodyID = ""
            var sketchID: String?, entityID: String?, variableID: String?
            var edit: [String: Any] = [:]
            var initial = 0.0, final = 0.0
            var origin: [Double]?, axis: [Double]?, radial: [Double]?, lower: Double?
            switch target {
            case .hole:
                let (_, body) = try stock(doc); bodyID = body.raw.uuidString
                let circle = UUID(), sketch = Sketch(name: "M30 hole placement", plane: .ground,
                    entities: [.circle(id: circle, center: SIMD2(50, 30), radius: 5)])
                doc.session.perform(AddSketchCommand(sketch: sketch))
                let outcome = doc.execute(["op": "feature.hole", "args": [
                    "sketchID": sketch.id.raw.uuidString, "seedPoint": [50, 30],
                    "targetBodyID": bodyID, "type": "throughAll"]])
                guard outcome.isOK, let node = doc.session.document.features.nodes.last,
                      case .hole = node.kind else { throw fail("Native hole seed failed: \(outcome.message ?? "")") }
                targetID = node.id.raw.uuidString; name = node.name
                sketchID = sketch.id.raw.uuidString; entityID = circle.uuidString; initial = 5; final = 6
                edit = ["action": "updateSketchEntity", "sketch_id": sketchID!, "entity_id": entityID!,
                        "radius": final, "expected_radius": initial]
            case .thread:
                let (_, body) = try stock(doc, circular: true); bodyID = body.raw.uuidString
                let sources = try call(doc, "thread.sources")
                guard let row = (sources["rows"] as? [[String: Any]])?.first(where: { $0["side"] as? String == "external" }),
                      let index = row["face_index"] as? Int, let shape = doc.session.document.body(with: body)?.brep,
                      let cylinder = OCCTKernel.threadCylinder(shape, faceIndex: index) else { throw fail("No exact thread stock") }
                lower = cylinder.lower
                origin = [cylinder.origin.x, cylinder.origin.y, cylinder.origin.z]
                axis = [cylinder.axis.x, cylinder.axis.y, cylinder.axis.z]
                radial = [cylinder.radial.x, cylinder.radial.y, cylinder.radial.z]
                var args: [String: Any] = ["diameter": 8, "pitch": 1.25, "effective_length": 8,
                    "hand": "right", "ends": "flatTrim", "representation": "geometry", "phase_degrees": 0, "side": "external"]
                for key in ["body_id", "face_index", "query_token"] { args[key] = row[key] }
                targetID = try id(call(doc, "thread.create", args), "feature_id")
                name = doc.session.document.features.nodes.first { $0.id.raw.uuidString == targetID }!.name
                variableID = try id(call(doc, "variable.create", ["name": "m30Length", "expression": "8"]), "variable_id")
                _ = try call(doc, "feature.setExpression", ["feature_id": targetID,
                    "parameter": "effective_length", "expression": "m30Length"])
                initial = 8; final = 10
                edit = ["action": "variable.update", "variable_id": variableID!,
                        "expression": "10", "expected_expression": "8"]
            case .surface:
                var paths: [SweepPathDefinition] = []
                for z in [0.0, 10.0] {
                    let entity = UUID(), sketch = Sketch(name: "M30 section \(Int(z))",
                        plane: SketchPlane(origin: SIMD3(0, 0, z), xAxis: SIMD3(1, 0, 0), yAxis: SIMD3(0, 1, 0)),
                        entities: [.line(id: entity, a: .zero, b: SIMD2(20, 0))])
                    doc.session.perform(AddSketchCommand(sketch: sketch))
                    paths.append(.init(segments: [.init(sketchID: sketch.id, entityID: entity)]))
                    sketchID = sketch.id.raw.uuidString; entityID = entity.uuidString
                }
                func create(_ definition: CADSurfaceDefinition) throws -> FeatureNode {
                    let raw = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition))
                    let value = try id(call(doc, "surface.create", ["definition": raw]), "feature_id")
                    guard let node = doc.session.document.features.nodes.first(where: { $0.id.raw.uuidString == value }) else { throw fail("Missing surface") }
                    return node
                }
                let surface = try create(.init(operation: .loft, sections: paths, ruled: true))
                let body = surface.outputBodyIDs[0]; bodyID = body.raw.uuidString
                _ = try create(.init(operation: .thicken, sources: [.init(producer: surface.id, bodyID: body)], thickness: 2))
                targetID = surface.id.raw.uuidString; name = surface.name; initial = 20; final = 24
                edit = ["action": "updateSketchEntity", "sketch_id": sketchID!, "entity_id": entityID!,
                    "b": [24, 0], "expected_b": [20, 0]]
            case .datum:
                let (_, stockBody) = try stock(doc)
                variableID = try id(call(doc, "variable.create", ["name": "m30Tilt", "expression": "15"]), "variable_id")
                let query = doc.nativeQueryJSON(["scope": "faces", "limit": 500])
                let rows = (try JSONSerialization.jsonObject(with: query.payload) as? [String: Any])?["rows"] as? [[String: Any]] ?? []
                guard let top = rows.first(where: { $0["bodyID"] as? String == stockBody.raw.uuidString && (($0["normal"] as? [Double])?[1] ?? 0) > 0.99 }) else { throw fail("Missing top plane source") }
                let result = try call(doc, "datum.anglePlane.create", ["body_id": stockBody.raw.uuidString,
                    "face_index": top["index"]!, "query_token": top["query_token"]!,
                    "expression": "m30Tilt", "hinge_x": 1, "hinge_y": 0])
                targetID = try id(result, "plane_id"); targetKind = "datum_plane"
                let planeID = ConstructionPlaneID(raw: UUID(uuidString: targetID)!)
                guard let plane = doc.session.document.planes.first(where: { $0.id == planeID }) else { throw fail("Missing datum") }
                name = CADSelectionContext.constructionPlaneName(plane.id, in: doc.session.document.planes)
                let sketch = Sketch(name: "M30 datum child", plane: .ground,
                    entities: [.rect(id: UUID(), min: SIMD2(-2, -1), max: SIMD2(2, 1))],
                    support: PlaneRef(source: .construction(planeID)))
                let body = BodyID(); bodyID = body.raw.uuidString
                let child = FeatureNode(name: "M30 datum child", kind: .extrude(
                    profile: ProfileRef(sketchID: sketch.id, entityIDs: sketch.entities.map(\.id), holeEntityIDs: [], seedPoint: .zero),
                    plane: PlaneRef(source: .sketch(sketch.id)), distance: Expr(value: 3), symmetric: false,
                    boolean: BooleanIntent(op: .newBody, resolvedTargets: []), extraProfiles: []), outputBodyIDs: [body])
                guard doc.session.performAssociativeTransaction([AddSketchCommand(sketch: sketch), AppendFeatureCommand(node: child, title: "M30 datum child")], title: "M30 datum child") else { throw fail("Datum child failed") }
                initial = 15; final = 30
                edit = ["action": "variable.update", "variable_id": variableID!, "expression": "30", "expected_expression": "15"]
            }
            try healthySession(doc)
            let saved = await doc.save(); guard saved.succeeded else { throw fail(saved.error ?? "Save failed") }
            let descriptor = CADM30TargetDescriptor(target: target, targetKind: targetKind,
                targetID: targetID, targetName: name, bodyID: bodyID,
                featureIDs: doc.session.document.features.nodes.map { $0.id.raw.uuidString },
                planeIDs: doc.session.document.planes.map { $0.id.raw.uuidString },
                sketchID: sketchID, entityID: entityID, variableID: variableID,
                editPayloadJSON: try json(edit), initialValue: initial, editedValue: final,
                cylinderOrigin: origin, cylinderAxis: axis, cylinderRadial: radial, cylinderLower: lower)
            _ = try inspect(doc, descriptor: descriptor, edited: false)
            return (doc, descriptor)
        } catch { doc.close(); throw error }
    }

    /// Independent geometry assertions over the reopened native model and,
    /// separately, OCCT's STEP reader. No tool summary or rendered mesh is used.
    public static func inspect(_ doc: FloeCADDocument, descriptor d: CADM30TargetDescriptor,
                               edited: Bool, stepURL: URL? = nil) throws -> [String: String] {
        try healthySession(doc)
        guard doc.session.document.features.nodes.map({ $0.id.raw.uuidString }) == d.featureIDs,
              doc.session.document.planes.map({ $0.id.raw.uuidString }) == d.planeIDs,
              let body = doc.session.document.bodies.first(where: { $0.id.raw.uuidString == d.bodyID }),
              let native = body.brep, native.containsSolid else { throw fail("Identity/solid/rebuild changed") }
        let value = edited ? d.editedValue : d.initialValue
        let shapes: [BRepHandle]
        if let stepURL {
            shapes = OCCTKernel.readSTEP(from: stepURL)
            guard shapes.count == (d.target == .datum ? 2 : 1) else { throw fail("STEP exact solid count mismatch") }
        } else { shapes = [native] }
        let expectedVolume: Double?
        switch d.target {
        case .hole: expectedVolume = 60000 - .pi * value * value * 10
        case .surface: expectedVolume = (20 + value) / 2 * 10 * 2
        case .datum: expectedVolume = 24
        case .thread: expectedVolume = nil
        }
        let measured = expectedVolume.flatMap { volume in shapes.min { abs(OCCTKernel.volume($0) - volume) < abs(OCCTKernel.volume($1) - volume) } } ?? shapes[0]
        for shape in shapes {
            let health = OCCTKernel.healthReport(for: shape)
            guard health.error == nil, health.isValid, health.counts["solids"] == 1,
                  health.openFreeWires == 0 else { throw fail("Invalid exact shape: \(health.findingsSummary)") }
        }
        let volume = OCCTKernel.volume(measured)
        if let expectedVolume, abs(volume - expectedVolume) > 1e-4 { throw fail("Independent volume \(volume) expected \(expectedVolume)") }
        if stepURL != nil, abs(volume - OCCTKernel.volume(native)) > 1e-4 { throw fail("STEP/native volume disagreement") }
        switch d.target {
        case .hole:
            guard let raw = UUID(uuidString: d.targetID),
                  case let .hole(_, profile, _, _)? = doc.session.document.features.node(FeatureID(raw: raw))?.kind,
                  profile.sketchID.raw.uuidString == d.sketchID,
                  profile.entityIDs.contains(where: { $0.uuidString == d.entityID }) else { throw fail("Hole source/feature identity lost") }
            guard OCCTKernel.faceInfo(measured).contains(where: {
                if case let .cylindrical(radius)? = $0.signature?.kind { return abs(radius - value) < 1e-6 }; return false
            }) else { throw fail("Independent hole radius absent") }
        case .datum:
            guard let plane = doc.session.document.planes.first(where: { $0.id.raw.uuidString == d.targetID }),
                  case let .angle(definition)? = plane.definition,
                  definition.angle.formula == "m30Tilt", abs(definition.angle.value-value) < 1e-9,
                  abs(plane.plane.normal.y - cos(value * .pi / 180)) < 1e-9,
                  abs(plane.plane.normal.z - sin(value * .pi / 180)) < 1e-9 else { throw fail("Datum expression/replay mismatch") }
            guard OCCTKernel.faceInfo(measured).contains(where: {
                abs($0.area - 8) < 1e-5 && abs(abs($0.normal.y) - cos(value * .pi / 180)) < 1e-6
                    && abs(abs($0.normal.z) - sin(value * .pi / 180)) < 1e-6
            }) else { throw fail("Child exact cap normal did not follow datum") }
        case .thread:
            guard let raw = UUID(uuidString: d.targetID),
                  case let .thread(_, spec)? = doc.session.document.features.node(FeatureID(raw: raw))?.kind,
                  spec.representation == .geometry, spec.effectiveLength.formula == "m30Length",
                  abs(spec.effectiveLength.value-value) < 1e-9 else { throw fail("Thread formula/semantic identity lost") }
            try threadSection(measured, descriptor: d, length: value)
        case .surface:
            guard let id = UUID(uuidString: d.targetID),
                  case let .surface(definition)? = doc.session.document.features.node(FeatureID(raw: id))?.kind,
                  definition.operation == .loft else { throw fail("Surface definition/identity lost") }
        }
        return ["target_id": d.targetID, "body_id": d.bodyID, "volume_mm3": String(volume),
                "revision": String(doc.revision), "model_sha256": doc.modelSHA256,
                "solid_count": String(shapes.count), "source": stepURL == nil ? "native exact BRep" : "independent OCCT STEP reader"]
    }
    private static func threadSection(_ shape: BRepHandle, descriptor d: CADM30TargetDescriptor, length: Double) throws {
        func vector(_ v: [Double]?) throws -> SIMD3<Double> {
            guard let v, v.count == 3 else { throw fail("Thread source frame absent") }; return SIMD3(v[0], v[1], v[2])
        }
        let origin = try vector(d.cylinderOrigin), n = try vector(d.cylinderAxis), x = try vector(d.cylinderRadial)
        let pitch = 1.25, major = 4.0, minor = 4 - 5 * sqrt(3) / 16 * pitch
        func distance(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
            let delta = b-a, l2 = simd_dot(delta, delta)
            return l2 > 1e-20 ? simd_distance(p, a + delta * min(1, max(0, simd_dot(p-a, delta)/l2))) : simd_distance(p, a)
        }
        for theta in [0.0, Double.pi/2] {
            let r = x*cos(theta) + simd_cross(n,x)*sin(theta)
            let segments = OCCTKernel.sectionPolylines(shape, origin: origin, normal: simd_cross(n,r), deflection: 0.00001)
                .flatMap { Array(zip($0, $0.dropFirst())) }
            guard !segments.isEmpty else { throw fail("STEP/native thread section absent") }
            var count = 0
            for turn in -2..<12 {
                let z = -pitch + pitch * (Double(turn) + theta/(2 * .pi))
                guard z > pitch, z < length-pitch else { continue }; count += 1
                for (radius, axial) in [(minor,pitch/8),(minor,-pitch/8),((major+minor)/2,9*pitch/32),
                                        ((major+minor)/2,-9*pitch/32),(major,7*pitch/16),(major,-7*pitch/16)] {
                    let expected = origin + r*radius + n*((d.cylinderLower ?? 0)+z+axial)
                    let residual = segments.map { distance(expected,$0.0,$0.1) }.min() ?? .infinity
                    guard residual < 0.0003 else { throw fail("Independent thread flank/root residual \(residual)") }
                }
            }
            guard count > 2 else { throw fail("Insufficient independent thread turns") }
        }
    }
}
#endif
