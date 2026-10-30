import Foundation
import CoreFoundation
import simd

/// Thin adapter over the existing association resolver, commands and OCCT
/// names. The session remains the sole transaction/undo/persistence authority.
@MainActor
public final class CADDatumService {
    public static let actions = ["datum.offsetPlane.create", "datum.offsetPlane.update",
                                 "datum.offsetPlane.delete", "sketch.setSupport", "sketch.clearSupport"]
    private let document: FloeCADDocument
    public init(document: FloeCADDocument) { self.document = document }

    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        if let block = document.session.writeBlock { return fail(block.code, block.message) }
        let common: Set<String> = ["action", "revision", "expected_revision"]
        let fields: Set<String>
        switch action {
        case "datum.offsetPlane.create": fields = ["body_id", "face_index", "query_token", "expression", "size"]
        case "datum.offsetPlane.update": fields = ["plane_id", "body_id", "face_index", "query_token", "expression", "expected_expression", "size"]
        case "datum.offsetPlane.delete": fields = ["plane_id"]
        case "sketch.setSupport": fields = ["sketch_id", "plane_id"]
        case "sketch.clearSupport": fields = ["sketch_id"]
        default: return fail("unknown_action", "Unknown datum action '\(action)'.")
        }
        let unknown = args.keys.filter { !common.union(fields).contains($0) }.sorted()
        guard unknown.isEmpty else { return fail("unknown_argument", "Unknown fields: \(unknown.joined(separator: ", ")).") }
        if let supplied = args["action"], (supplied as? String) != action {
            return fail("contradictory_action", "The action field contradicts the requested operation.")
        }
        for key in ["revision", "expected_revision"] where args[key] != nil {
            guard let value = integer(args[key]), value == document.revision else {
                return fail("revision_mismatch", "Re-query the current document revision before editing.")
            }
        }
        switch action {
        case "datum.offsetPlane.create": return create(args)
        case "datum.offsetPlane.update": return update(args)
        case "datum.offsetPlane.delete": return delete(args)
        case "sketch.setSupport": return support(args, clear: false)
        case "sketch.clearSupport": return support(args, clear: true)
        default: return fail("unknown_action", "Unknown datum action.")
        }
    }

    private nonisolated struct Failure: Error { var code: String; var message: String }
    private func fail(_ code: String, _ message: String, fields: [String: Any] = [:]) -> [String: Any] {
        var result: [String: Any] = ["ok": false, "error": code, "message": message, "mutated": false,
                                    "revision": document.revision, "change_count": document.session.changeCount]
        result.merge(fields) { _, value in value }
        return result
    }
    private func uuid(_ value: Any?) -> UUID? { (value as? String).flatMap(UUID.init(uuidString:)) }
    private func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= Double(Int.min), number.doubleValue < Double(Int.max) else { return nil }
            return number.intValue
        }
        return (value as? String).flatMap(Int.init)
    }
    private func size(_ value: Any?) throws -> Double? {
        guard let value else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0 else {
            throw Failure(code: "invalid_size", message: "size must be a finite positive length in mm.")
        }
        return number.doubleValue
    }
    private func expression(_ value: Any?) throws -> Expr {
        guard let source = value as? String else {
            throw Failure(code: "invalid_expression", message: "expression must be a distance expression in mm.")
        }
        let values = document.session.variableValues()
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        // Existing variables/functions get the first complete parse, including
        // valid expressions ending in a variable whose name resembles a unit.
        var parsed = ExpressionEvaluator.evaluateStrict(trimmed, variables: values)
        if parsed == nil, NumericParsing.trailingUnit(in: trimmed) == "mm" {
            parsed = ExpressionEvaluator.evaluateStrict(String(trimmed.dropLast(2)), variables: values)
        }
        guard let result = parsed, result.isFinite else {
            throw Failure(code: "invalid_expression", message: "expression must resolve to a finite distance in mm; use mm or omit the unit suffix.")
        }
        return Expr(value: result, formula: source)
    }

    private struct Source {
        var reference: FaceRef
        var version: GeometryVersionRef
        var frame: PlaneAttachmentFrame
        var plane: SketchPlane
    }
    private func source(_ args: [String: Any], distance: Expr) throws -> Source {
        guard let id = uuid(args["body_id"]), let index = integer(args["face_index"]), index > 0,
              let body = document.session.document.body(with: BodyID(raw: id)), let brep = body.brep else {
            throw Failure(code: "invalid_source", message: "Use body_id and the 1-based OCCT kernel face_index from query scope=faces.")
        }
        guard let token = args["query_token"] as? String, let generation = CADGeometryQueryGeneration.parse(token),
              generation.scope == "faces", generation.matches(documentRevision: document.revision,
                changeCount: document.session.changeCount, bodyID: id, meshRevision: body.meshRevision) else {
            throw Failure(code: "stale_query", message: "Re-query scope=faces for this body and use its current query_token.")
        }
        guard document.session.lastNamingRevisions[body.id] == body.meshRevision,
              let name = document.session.lastKernelNames[body.id]?[index], Self.isStable(name),
              document.session.lastKernelNames[body.id]?.values.filter({ $0 == name }).count == 1,
              let liveFace = OCCTKernel.faceInfo(brep).first(where: { $0.index == index }),
              liveFace.signature?.kind == .planar, liveFace.area.isFinite, liveFace.area > 0 else {
            throw Failure(code: "named_planar_source_required", message: "This face has no current, unique stable planar kernel name. Rebuild or select a supported named face.")
        }
        guard let acquired = document.session.associativeSource(for: body.id),
              let snapshotBRep = acquired.snapshot.body.brep else {
            throw Failure(code: "feature_source_required", message: "An offset plane needs a successful feature-owned exact source.")
        }
        // Names cross the boundary; indices NEVER do. A snapshot can have a
        // different kernel ordering from the live exact shape.
        let matches = acquired.snapshot.kernelNames.filter { $0.value == name }
        guard matches.count == 1, let snapshotIndex = matches.first?.key,
              let face = OCCTKernel.faceInfo(snapshotBRep).first(where: { $0.index == snapshotIndex }),
              let signature = face.signature, signature.kind == .planar, face.area.isFinite, face.area > 0 else {
            throw Failure(code: "ambiguous_source", message: "The selected stable face name is absent or ambiguous in its actual writer snapshot.")
        }
        let readable = SketchPlane.readable(origin: face.centroid, normal: face.normal)
        let frame = try PlaneAttachmentFrame.make(faceCentroid: face.centroid, faceNormal: face.normal,
                                                 referenceXAxis: readable.xAxis, anchorPoint: face.centroid)
        let producer = document.session.document.features.nodes.first {
            $0.outputBodyIDs.contains(body.id)
        }?.id ?? name.creator
        let reference = FaceRef(body: BodyRef(producer: producer, bodyID: body.id), creator: name.creator,
                                role: Self.role(name, index: snapshotIndex), signature: signature, elementName: name)
        let definition = OffsetPlaneDefinition(source: reference, sourceVersion: acquired.version,
                                               distance: distance, attachment: frame)
        let plane = try definition.resolvedPlane(face: SourceFaceGeometry(bodyID: body.id,
            centroid: face.centroid, normal: face.normal), bodyTransform: acquired.snapshot.body.transform)
        return Source(reference: reference, version: acquired.version, frame: frame, plane: plane)
    }

    private static func isStable(_ name: ElementName) -> Bool {
        if case .kernelFace = name.source { return false }
        return true
    }
    private static func role(_ name: ElementName, index: Int) -> FaceRole {
        switch name.source {
        case let .primitiveFace(role): return role
        case let .profileCap(end): return end ? .extrudeEndCap : .extrudeStartCap
        case .profileWall, .opFace, .kernelFace, .holeFace: return .derived(index: index)
        }
    }
    private func error(_ error: Error) -> [String: Any] {
        if let failure = error as? Failure { return fail(failure.code, failure.message) }
        return fail("invalid_definition", error.localizedDescription)
    }
    private func commit(_ commands: [DocumentCommand], title: String, action: String,
                        extra: [String: Any]) -> [String: Any] {
        guard document.session.performAssociativeTransaction(commands, title: title) else {
            let references: [[String: Any]] = document.session.lastRebuildRejection.map { key, value in
                var row: [String: Any] = ["error": value.message]
                switch key {
                case let .plane(id): row["plane_id"] = id.raw.uuidString
                case let .sketch(id): row["sketch_id"] = id.raw.uuidString
                case let .feature(id): row["feature_id"] = id.raw.uuidString
                }
                return row
            }
            let features = document.session.lastRejectedFeatureErrors.map {
                ["feature_id": $0.key.raw.uuidString, "error": String(describing: $0.value)]
            }
            return fail("rebuild_failed", "That edit would break dependent geometry; nothing was kept.",
                        fields: ["reference_errors": references, "feature_errors": features, "rolled_back": true])
        }
        var reply: [String: Any] = ["ok": true, "action": action, "mutated": true,
            "revision": document.revision, "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo, "can_redo": document.session.undoStack.canRedo]
        reply.merge(extra) { _, value in value }
        if let id = extra["plane_id"] as? String,
           let descriptor = Self.planeRows(document: document).first(where: { ($0["plane_id"] as? String) == id }) {
            reply["plane"] = descriptor
        }
        return reply
    }

    private func create(_ args: [String: Any]) -> [String: Any] {
        do {
            let distance = try expression(args["expression"])
            let displaySize = try size(args["size"]) ?? 100
            let selectedSource = try source(args, distance: distance)
            let definition = OffsetPlaneDefinition(source: selectedSource.reference, sourceVersion: selectedSource.version,
                                                  distance: distance, attachment: selectedSource.frame)
            let plane = ConstructionPlane(plane: selectedSource.plane, size: displaySize, definition: .offset(definition))
            return commit([AddConstructionPlaneCommand(plane: plane)], title: "Offset Plane",
                          action: "datum.offsetPlane.create", extra: ["plane_id": plane.id.raw.uuidString])
        } catch { return self.error(error) }
    }

    private func update(_ args: [String: Any]) -> [String: Any] {
        guard let id = uuid(args["plane_id"]), let plane = document.session.document.planes.first(where: { $0.id.raw == id }),
              case var .offset(definition)? = plane.definition else {
            return fail("unknown_offset_plane", "plane_id must name an existing associative offset plane.")
        }
        if let raw = args["expected_expression"] {
            guard let expected = raw as? String else {
                return fail("bad_expected_expression", "expected_expression must be the current exact stored formula string (empty when absent).")
            }
            guard expected == (definition.distance.formula ?? "") else {
                return fail("expression_mismatch", "The offset expression changed. Re-query scope=planes before editing.")
            }
        }
        do {
            let newSize = try size(args["size"])
            if let supplied = args["expression"] { definition.distance = try expression(supplied) }
            let sourceFields = ["body_id", "face_index", "query_token"]
            let reselect = sourceFields.contains { args[$0] != nil }
            if reselect {
                guard sourceFields.allSatisfy({ args[$0] != nil }) else {
                    return fail("incomplete_source", "Reselecting a source requires body_id, face_index and query_token together.")
                }
                let selectedSource = try source(args, distance: definition.distance)
                definition = OffsetPlaneDefinition(version: definition.version,
                    source: selectedSource.reference, sourceVersion: selectedSource.version,
                    distance: definition.distance, attachment: selectedSource.frame)
            }
            var commands: [DocumentCommand] = []
            if plane.definition != .offset(definition) {
                commands.append(EditConstructionPlaneDefinitionCommand(planeID: plane.id,
                    before: plane.definition, after: .offset(definition)))
            }
            if let newSize, newSize != plane.size {
                commands.append(SetDatumSizeCommand(planeID: plane.id, before: plane.size, after: newSize))
            }
            guard !commands.isEmpty else { return fail("no_change", "The plane already has those values.") }
            return commit(commands, title: "Edit Offset Plane", action: "datum.offsetPlane.update",
                          extra: ["plane_id": plane.id.raw.uuidString])
        } catch { return self.error(error) }
    }

    private func delete(_ args: [String: Any]) -> [String: Any] {
        guard let id = uuid(args["plane_id"]), let plane = document.session.document.planes.first(where: { $0.id.raw == id }),
              case .offset? = plane.definition else { return fail("unknown_offset_plane", "plane_id must name an existing associative offset plane.") }
        let model = document.session.document
        let sketches = model.sketches.filter {
            guard case let .construction(id)? = $0.support?.source else { return false }
            return id == plane.id
        }
        let sketchIDs = Set(sketches.map(\.id))
        let features = model.features.nodes.filter {
            $0.referencedConstructionPlaneIDs.contains(plane.id) || !$0.referencedSketchIDs.isDisjoint(with: sketchIDs)
        }
        guard sketches.isEmpty, features.isEmpty else {
            return fail("plane_in_use", "Detach or rehost the dependent sketches/features before deleting this plane.",
                fields: ["plane_id": plane.id.raw.uuidString,
                         "dependent_sketch_ids": sketches.map { $0.id.raw.uuidString },
                         "dependent_feature_ids": features.map { $0.id.raw.uuidString }])
        }
        guard let command = DeletePlaneCommand(id: plane.id, document: model) else { return fail("unknown_offset_plane", "The plane no longer exists.") }
        return commit([command], title: "Delete Offset Plane", action: "datum.offsetPlane.delete",
                      extra: ["plane_id": plane.id.raw.uuidString])
    }

    private func support(_ args: [String: Any], clear: Bool) -> [String: Any] {
        guard let id = uuid(args["sketch_id"]), let sketch = document.session.document.sketches.first(where: { $0.id.raw == id }) else {
            return fail("unknown_sketch", "sketch_id must name an existing sketch.")
        }
        let after: PlaneRef?
        var resolvedFrame = sketch.plane
        if clear {
            guard sketch.support != nil else { return fail("no_change", "The sketch already has an explicit plane.") }
            var scratch = EvalCache()
            var revision: UInt64 = 0
            let current = document.session.document
            let result = current.features.evaluate(sketches: current.sketches, planes: current.planes,
                naming: document.session.naming, nextRevision: { revision &+= 1; return revision },
                cache: &scratch, variables: document.session.variableValues())
            guard result.referenceErrors[.sketch(sketch.id)] == nil,
                  let frame = result.resolvedSketchSupportUpdates[sketch.id] else {
                return fail("unresolved_support", "The current support cannot be resolved. Rehost this sketch to a valid construction plane first.")
            }
            resolvedFrame = frame
            after = nil
        } else {
            guard let id = uuid(args["plane_id"]), document.session.document.planes.contains(where: { $0.id.raw == id }) else {
                return fail("unknown_plane", "plane_id must name an existing construction plane.")
            }
            after = PlaneRef(source: .construction(ConstructionPlaneID(raw: id)))
            guard after != sketch.support else { return fail("no_change", "The sketch already uses that support.") }
        }
        // Clearing freezes the currently resolved frame. Setting keeps local
        // entities/constraints and lets the common resolver derive coordinates.
        let command = ChangeSketchSupportCommand(sketchID: sketch.id, before: sketch.support, after: after,
                                                beforePlane: sketch.plane, afterPlane: resolvedFrame)
        return commit([command], title: clear ? "Detach Sketch Support" : "Set Sketch Support",
                      action: clear ? "sketch.clearSupport" : "sketch.setSupport",
                      extra: ["sketch_id": sketch.id.raw.uuidString])
    }

    static func planeRows(document: FloeCADDocument) -> [[String: Any]] {
        document.session.document.planes.map { plane in
            var row: [String: Any] = ["id": plane.id.raw.uuidString, "plane_id": plane.id.raw.uuidString,
                "kind": "explicit", "size": plane.size, "unit": "mm", "hidden": plane.isHidden,
                "frame": frameJSON(plane.plane), "editable": document.session.writeBlock == nil,
                "support_action": "sketch.setSupport"]
            if case let .offset(definition)? = plane.definition {
                row["kind"] = "offset"
                row["definition_version"] = definition.version
                row["expression"] = definition.distance.formula ?? String(definition.distance.value)
                row["formula"] = definition.distance.formula ?? NSNull()
                row["expression_unit"] = "mm"
                row["value"] = definition.distance.value
                row["source_body_id"] = definition.sourceVersion.bodyID.raw.uuidString
                row["source_writer_id"] = definition.sourceVersion.writer.raw.uuidString
                row["source_producer_id"] = definition.source.body.producer.raw.uuidString
                row["kernel_element_name"] = definition.source.elementName.flatMap(json) ?? NSNull()
                row["update_action"] = "datum.offsetPlane.update"
                row["delete_action"] = "datum.offsetPlane.delete"
            }
            if document.isReadOnly {
                row["status"] = "read_only"
                row["frame_status"] = "cached"
                row.removeValue(forKey: "support_action")
                row.removeValue(forKey: "update_action")
                row.removeValue(forKey: "delete_action")
                if document.project.hasOpaqueAssociations {
                    row["kind"] = "unsupported"
                    row["semantics"] = "opaque"
                }
            } else if let block = document.session.writeBlock {
                row["status"] = block.code
                row["frame_status"] = "cached"
                row["write_block"] = ["code": block.code, "message": block.message]
                row.removeValue(forKey: "support_action")
                row.removeValue(forKey: "update_action")
                row.removeValue(forKey: "delete_action")
            } else if let error = document.session.lastReferenceErrors[.plane(plane.id)] {
                row["status"] = "error"; row["error"] = error.message
            } else { row["status"] = "resolved"; row["frame_status"] = "resolved" }
            return row
        }
    }
    static func supportJSON(_ sketch: Sketch) -> Any {
        guard let support = sketch.support else { return NSNull() }
        var row: [String: Any] = ["clear_action": "sketch.clearSupport"]
        switch support.source {
        case let .construction(id): row["kind"] = "construction"; row["plane_id"] = id.raw.uuidString
        case let .sketch(id): row["kind"] = "sketch"; row["sketch_id"] = id.raw.uuidString
        case .ground: row["kind"] = "ground"
        case let .explicit(plane): row["kind"] = "explicit"; row["frame"] = frameJSON(plane)
        }
        return row
    }
    static func frameJSON(_ plane: SketchPlane) -> [String: Any] {
        func vector(_ v: SIMD3<Double>) -> [Double] { [v.x, v.y, v.z] }
        return ["origin": vector(plane.origin), "xAxis": vector(plane.xAxis),
                "yAxis": vector(plane.yAxis), "normal": vector(plane.normal)]
    }
    private static func json<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }
    /// Prepare linear name lookup tables and one snapshot OCCT face traversal
    /// per body. Native face rows then perform O(1) descriptor lookup.
    static func sourceDescriptors(document: FloeCADDocument, body: Body,
        planarIndices: Set<Int>,
        acquired: (version: GeometryVersionRef, snapshot: GeometryVersionSnapshot)?) -> [Int: [String: Any]] {
        guard document.session.writeBlock == nil, document.session.lastNamingRevisions[body.id] == body.meshRevision,
              let liveNames = document.session.lastKernelNames[body.id] else { return [:] }
        var liveCounts: [ElementName: Int] = [:]
        for name in liveNames.values { liveCounts[name, default: 0] += 1 }
        var snapshotIndices: [ElementName: [Int]] = [:]
        var snapshotPlanarIndices: Set<Int> = []
        if let acquired {
            for (index, name) in acquired.snapshot.kernelNames { snapshotIndices[name, default: []].append(index) }
            if let brep = acquired.snapshot.body.brep {
                snapshotPlanarIndices = Set(OCCTKernel.faceInfo(brep).filter {
                    $0.signature?.kind == .planar && $0.area.isFinite && $0.area > 0
                }.map(\.index))
            }
        }
        var descriptors: [Int: [String: Any]] = [:]
        for (index, name) in liveNames where isStable(name) && liveCounts[name] == 1 {
            var row: [String: Any] = ["kernel_element_name": json(name) ?? NSNull(), "datum_source_supported": false]
            if let acquired {
                row["source_writer_id"] = acquired.version.writer.raw.uuidString
                if planarIndices.contains(index), let matched = snapshotIndices[name], matched.count == 1,
                   snapshotPlanarIndices.contains(matched[0]) {
                    row["datum_source_supported"] = true
                    row["source_body_id"] = acquired.version.bodyID.raw.uuidString
                    row["datum_action"] = "datum.offsetPlane.create"
                    row["face_index_space"] = "occt_kernel_1_based"
                }
            }
            descriptors[index] = row
        }
        return descriptors
    }

}

/// Field-only adapter; changing display size never replaces the definition or
/// other plane fields installed by earlier commands in the same transaction.
private struct SetDatumSizeCommand: DocumentCommand {
    let title = "Resize Construction Plane"
    let planeID: ConstructionPlaneID
    let before: Double
    let after: Double
    private func set(_ value: Double, in document: inout DesignDocument) {
        guard let index = document.planes.firstIndex(where: { $0.id == planeID }) else { return }
        document.planes[index].size = value
    }
    func apply(to document: inout DesignDocument) { set(after, in: &document) }
    func revert(in document: inout DesignDocument) { set(before, in: &document) }
}
