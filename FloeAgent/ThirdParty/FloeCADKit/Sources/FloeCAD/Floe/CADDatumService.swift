import Foundation
import CoreFoundation
import simd

/// Thin adapter over the existing association resolver, commands and OCCT
/// names. The session remains the sole transaction/undo/persistence authority.
@MainActor
public final class CADDatumService {
    public static let actions = [
        "datum.offsetPlane.create", "datum.offsetPlane.update", "datum.offsetPlane.delete",
        "datum.anglePlane.create", "datum.anglePlane.update", "datum.anglePlane.delete",
        "datum.threePointPlane.create", "datum.threePointPlane.update",
        "datum.threePointPlane.delete",
        "datum.axis.create", "datum.axis.update", "datum.axis.delete",
        "datum.point.create", "datum.point.update", "datum.point.delete",
        "sketch.setSupport", "sketch.clearSupport",
    ]
    private let document: FloeCADDocument
    public init(document: FloeCADDocument) { self.document = document }

    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        if let block = document.session.writeBlock { return fail(block.code, block.message) }
        let common: Set<String> = ["action", "revision", "expected_revision"]
        let fields: Set<String>
        switch action {
        case "datum.offsetPlane.create":
            fields = ["body_id", "face_index", "query_token", "expression", "size"]
        case "datum.offsetPlane.update":
            fields = ["plane_id", "body_id", "face_index", "query_token", "expression",
                      "expected_expression", "size"]
        case "datum.offsetPlane.delete":
            fields = ["plane_id"]
        case "datum.anglePlane.create":
            fields = ["body_id", "face_index", "query_token", "expression", "size",
                      "hinge_x", "hinge_y"]
        case "datum.anglePlane.update":
            fields = ["plane_id", "body_id", "face_index", "query_token", "expression",
                      "expected_expression", "size", "hinge_x", "hinge_y"]
        case "datum.anglePlane.delete":
            fields = ["plane_id"]
        case "datum.threePointPlane.create":
            fields = ["points", "size"]
        case "datum.threePointPlane.update":
            fields = ["plane_id", "points", "point_index", "point", "expected_points", "size"]
        case "datum.threePointPlane.delete":
            fields = ["plane_id"]
        case "datum.axis.create":
            fields = ["kind", "body_id", "face_index", "edge_index", "query_token",
                      "plane_ids", "points", "offset", "size"]
        case "datum.axis.update":
            fields = ["axis_id", "kind", "body_id", "face_index", "edge_index", "query_token",
                      "plane_ids", "points", "offset", "expected_offset", "size"]
        case "datum.axis.delete":
            fields = ["axis_id"]
        case "datum.point.create":
            fields = ["kind", "body_id", "face_index", "edge_index", "query_token",
                      "points", "axis_id", "plane_id", "offset"]
        case "datum.point.update":
            fields = ["point_id", "kind", "body_id", "face_index", "edge_index", "query_token",
                      "points", "axis_id", "plane_id", "offset", "expected_offset"]
        case "datum.point.delete":
            fields = ["point_id"]
        case "sketch.setSupport":
            fields = ["sketch_id", "plane_id"]
        case "sketch.clearSupport":
            fields = ["sketch_id"]
        default:
            return fail("unknown_action", "Unknown datum action '\(action)'.")
        }
        let unknown = args.keys.filter { !common.union(fields).contains($0) }.sorted()
        guard unknown.isEmpty else {
            return fail("unknown_argument", "Unknown fields: \(unknown.joined(separator: ", ")).")
        }
        if let supplied = args["action"], (supplied as? String) != action {
            return fail("contradictory_action", "The action field contradicts the requested operation.")
        }
        for key in ["revision", "expected_revision"] where args[key] != nil {
            guard let value = integer(args[key]), value == document.revision else {
                return fail("revision_mismatch", "Re-query the current document revision before editing.")
            }
        }
        switch action {
        case "datum.offsetPlane.create": return createOffset(args)
        case "datum.offsetPlane.update": return updateOffset(args)
        case "datum.offsetPlane.delete": return delete(args)
        case "datum.anglePlane.create": return createAngle(args)
        case "datum.anglePlane.update": return updateAngle(args)
        case "datum.anglePlane.delete": return delete(args)
        case "datum.threePointPlane.create": return createThreePoint(args)
        case "datum.threePointPlane.update": return updateThreePoint(args)
        case "datum.threePointPlane.delete": return delete(args)
        case "datum.axis.create": return createAxis(args)
        case "datum.axis.update": return updateAxis(args)
        case "datum.axis.delete": return deleteAxis(args)
        case "datum.point.create": return createPoint(args)
        case "datum.point.update": return updatePoint(args)
        case "datum.point.delete": return deletePoint(args)
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
    private func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            return number.doubleValue
        }
        if let text = value as? String { return Double(text) }
        return nil
    }
    private func size(_ value: Any?) throws -> Double? {
        guard let value else { return nil }
        guard let number = double(value), number > 0 else {
            throw Failure(code: "invalid_size", message: "size must be a finite positive length in mm.")
        }
        return number
    }
    private func distanceExpression(_ value: Any?) throws -> Expr {
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
            throw Failure(code: "invalid_expression",
                          message: "expression must resolve to a finite distance in mm; use mm or omit the unit suffix.")
        }
        return Expr(value: result, formula: source)
    }
    /// Angle formulas are authored and stored in public degrees. The definition
    /// converts to radians exactly once at resolution; this parser never does.
    private func angleExpression(_ value: Any?) throws -> Expr {
        guard let source = value as? String else {
            throw Failure(code: "invalid_expression",
                          message: "expression must be an angle expression in degrees.")
        }
        let values = document.session.variableValues()
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        var parsed = ExpressionEvaluator.evaluateStrict(trimmed, variables: values)
        var formula = source
        if parsed == nil {
            let lower = trimmed.lowercased()
            if lower.hasSuffix("deg") {
                parsed = ExpressionEvaluator.evaluateStrict(
                    String(trimmed.dropLast(3)), variables: values)
            } else if trimmed.hasSuffix("°") {
                parsed = ExpressionEvaluator.evaluateStrict(
                    String(trimmed.dropLast()), variables: values)
                // The shared evaluator strips alphabetic unit suffixes but not
                // the degree glyph. Store a re-readable formula when the
                // caller used it, instead of a value the next fan-out cannot
                // parse.
                formula = String(trimmed.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let result = parsed, result.isFinite else {
            throw Failure(code: "invalid_expression",
                          message: "expression must resolve to a finite angle in degrees.")
        }
        return Expr(value: result, formula: formula)
    }
    /// Explicit local hinge direction in the source-face attachment frame.
    /// Omitted means the frozen frame's x axis. Supplied components are
    /// normalized once; a zero direction refuses.
    private func hinge(_ args: [String: Any], fallback: SIMD2<Double>) throws -> SIMD2<Double> {
        let hasX = args["hinge_x"] != nil
        let hasY = args["hinge_y"] != nil
        guard hasX == hasY else {
            throw Failure(code: "invalid_hinge",
                          message: "Send hinge_x and hinge_y together (local source-plane direction).")
        }
        guard hasX else { return fallback }
        guard let x = double(args["hinge_x"]), let y = double(args["hinge_y"]),
              x.isFinite, y.isFinite else {
            throw Failure(code: "invalid_hinge", message: "hinge_x and hinge_y must be finite numbers.")
        }
        let length = (x * x + y * y).squareRoot()
        guard length.isFinite, length > 1e-9 else {
            throw Failure(code: "invalid_hinge", message: "The hinge direction must not be zero.")
        }
        return SIMD2(x / length, y / length)
    }

    private struct Source {
        var reference: FaceRef
        var version: GeometryVersionRef
        var frame: PlaneAttachmentFrame
        var face: SourceFaceGeometry
        var bodyTransform: Transform3D
        var planeAtZero: SketchPlane
        /// Display extent derived from the frozen face's area (mm). Never
        /// affects the axis math — it sizes the drawn segment.
        var faceExtent: Double
    }
    private func source(_ args: [String: Any]) throws -> Source {
        guard let id = uuid(args["body_id"]), let index = integer(args["face_index"]), index > 0,
              let body = document.session.document.body(with: BodyID(raw: id)), let brep = body.brep else {
            throw Failure(code: "invalid_source",
                          message: "Use body_id and the 1-based OCCT kernel face_index from query scope=faces.")
        }
        guard let token = args["query_token"] as? String, let generation = CADGeometryQueryGeneration.parse(token),
              generation.scope == "faces", generation.matches(documentRevision: document.revision,
                changeCount: document.session.changeCount, bodyID: id, meshRevision: body.meshRevision) else {
            throw Failure(code: "stale_query",
                          message: "Re-query scope=faces for this body and use its current query_token.")
        }
        guard document.session.lastNamingRevisions[body.id] == body.meshRevision,
              let name = document.session.lastKernelNames[body.id]?[index], Self.isStable(name),
              document.session.lastKernelNames[body.id]?.values.filter({ $0 == name }).count == 1,
              let liveFace = OCCTKernel.faceInfo(brep).first(where: { $0.index == index }),
              liveFace.signature?.kind == .planar, liveFace.area.isFinite, liveFace.area > 0 else {
            throw Failure(code: "named_planar_source_required",
                          message: "This face has no current, unique stable planar kernel name. Rebuild or select a supported named face.")
        }
        guard let acquired = document.session.associativeSource(for: body.id),
              let snapshotBRep = acquired.snapshot.body.brep else {
            throw Failure(code: "feature_source_required",
                          message: "An associative plane needs a successful feature-owned exact source.")
        }
        // Names cross the boundary; indices NEVER do. A snapshot can have a
        // different kernel ordering from the live exact shape.
        let matches = acquired.snapshot.kernelNames.filter { $0.value == name }
        guard matches.count == 1, let snapshotIndex = matches.first?.key,
              let face = OCCTKernel.faceInfo(snapshotBRep).first(where: { $0.index == snapshotIndex }),
              let signature = face.signature, signature.kind == .planar,
              face.area.isFinite, face.area > 0, let liveSignature = liveFace.signature,
              SignatureNaming.acceptsNamedSignature(name, current: signature, reference: liveSignature) else {
            throw Failure(code: "ambiguous_source",
                          message: "The selected stable face name is absent or ambiguous in its actual writer snapshot.")
        }
        let readable = SketchPlane.readable(origin: face.centroid, normal: face.normal)
        let frame = try PlaneAttachmentFrame.make(faceCentroid: face.centroid, faceNormal: face.normal,
                                                 referenceXAxis: readable.xAxis, anchorPoint: face.centroid)
        let producer = document.session.document.features.nodes.first {
            $0.outputBodyIDs.contains(body.id)
        }?.id ?? name.creator
        let reference = FaceRef(body: BodyRef(producer: producer, bodyID: body.id), creator: name.creator,
                                role: Self.role(name, index: snapshotIndex), signature: signature, elementName: name)
        let sourceFace = SourceFaceGeometry(bodyID: body.id, centroid: face.centroid, normal: face.normal)
        let plane = try frame.resolvedPlane(face: sourceFace,
                                            bodyTransform: acquired.snapshot.body.transform,
                                            offsetMM: 0)
        return Source(reference: reference, version: acquired.version, frame: frame,
                      face: sourceFace, bodyTransform: acquired.snapshot.body.transform,
                      planeAtZero: plane,
                      faceExtent: max(signature.area.squareRoot(), 1e-6))
    }

    private struct CylinderSource {
        var reference: FaceRef
        var version: GeometryVersionRef
        var cylinder: SourceCylinderGeometry
        var bodyTransform: Transform3D
    }

    /// The exact named CYLINDRICAL kernel face the axis will follow.
    ///
    /// Same identity discipline as `source(_:)`: the stable NAME crosses the
    /// boundary (never the live index), the frozen writer's snapshot is the
    /// geometry source, the query token must still match, and a non-cylindrical
    /// face/absent axis point refuses. The analytic axis point is read from the
    /// exact face, so a partial cylinder resolves its true centre line.
    private func cylinderSource(_ args: [String: Any]) throws -> CylinderSource {
        guard let id = uuid(args["body_id"]), let index = integer(args["face_index"]), index > 0,
              let body = document.session.document.body(with: BodyID(raw: id)), let brep = body.brep else {
            throw Failure(code: "invalid_source",
                          message: "Use body_id and the 1-based OCCT kernel face_index from query scope=faces.")
        }
        guard let token = args["query_token"] as? String, let generation = CADGeometryQueryGeneration.parse(token),
              generation.scope == "faces", generation.matches(documentRevision: document.revision,
                changeCount: document.session.changeCount, bodyID: id, meshRevision: body.meshRevision) else {
            throw Failure(code: "stale_query",
                          message: "Re-query scope=faces for this body and use its current query_token.")
        }
        guard document.session.lastNamingRevisions[body.id] == body.meshRevision,
              let name = document.session.lastKernelNames[body.id]?[index], Self.isStable(name),
              document.session.lastKernelNames[body.id]?.values.filter({ $0 == name }).count == 1,
              let liveFace = OCCTKernel.faceInfo(brep).first(where: { $0.index == index }),
              Self.isCylindrical(liveFace.signature),
              liveFace.axisPoint != nil, liveFace.area.isFinite, liveFace.area > 0 else {
            throw Failure(code: "named_cylinder_source_required",
                          message: "This face is not a current, uniquely named cylindrical kernel face. "
                            + "Select a round face, or re-query the body after the edit.")
        }
        guard let acquired = document.session.associativeSource(for: body.id),
              let snapshotBRep = acquired.snapshot.body.brep else {
            throw Failure(code: "feature_source_required",
                          message: "An associative axis needs a successful feature-owned exact source.")
        }
        // Names cross the boundary; indices NEVER do.
        let matches = acquired.snapshot.kernelNames.filter { $0.value == name }
        guard matches.count == 1, let snapshotIndex = matches.first?.key,
              let face = OCCTKernel.faceInfo(snapshotBRep).first(where: { $0.index == snapshotIndex }),
              Self.isCylindrical(face.signature),
              let axisPoint = face.axisPoint,
              face.area.isFinite, face.area > 0,
              let signature = face.signature, let liveSignature = liveFace.signature,
              SignatureNaming.acceptsNamedSignature(name, current: signature, reference: liveSignature) else {
            throw Failure(code: "named_cylinder_source_required",
                          message: "The selected stable face name is absent, ambiguous or no longer "
                            + "cylindrical in its actual writer snapshot.")
        }
        let producer = document.session.document.features.nodes.first {
            $0.outputBodyIDs.contains(body.id)
        }?.id ?? name.creator
        let reference = FaceRef(body: BodyRef(producer: producer, bodyID: body.id), creator: name.creator,
                                role: Self.role(name, index: snapshotIndex),
                                signature: signature, elementName: name)
        let radius: Double
        if case let .cylindrical(value) = signature.kind { radius = value } else { radius = 0 }
        let cylinder = SourceCylinderGeometry(
            bodyID: body.id, centroid: face.centroid, axisPoint: axisPoint,
            axisDirection: face.normal, radius: radius,
            extent: max(2 * radius, face.area.squareRoot()))
        return CylinderSource(reference: reference, version: acquired.version,
                              cylinder: cylinder, bodyTransform: acquired.snapshot.body.transform)
    }

    /// The exact cylinder test: a signature AND a finite analytic axis point.
    /// A planar/other kind is never coerced into a cylinder.
    private static func isCylindrical(_ signature: FaceSignature?) -> Bool {
        guard let signature, case .cylindrical = signature.kind else { return false }
        return true
    }

    private static func isStable(_ name: ElementName) -> Bool {
        if case .kernelFace = name.source { return false }
        return true
    }
    private static func role(_ name: ElementName, index: Int) -> FaceRole {
        switch name.source {
        case let .primitiveFace(role): return role
        case let .profileCap(end): return end ? .extrudeEndCap : .extrudeStartCap
        case .profileWall, .opFace, .operationFace, .kernelFace, .immutableSourceFace, .holeFace: return .derived(index: index)
        }
    }
    private func error(_ error: Error) -> [String: Any] {
        if let failure = error as? Failure { return fail(failure.code, failure.message) }
        if let geometry = error as? AssociativeAxisPointError {
            switch geometry {
            case .coincidentPoints:
                return fail("coincident_points", geometry.localizedDescription)
            case .parallelSources:
                return fail("parallel_sources", geometry.localizedDescription)
            case .degenerateDirection, .degenerateReference:
                return fail("degenerate_source", geometry.localizedDescription)
            case .sourceVersionBodyMismatch, .sourceBodyMismatch:
                return fail("source_body_mismatch", geometry.localizedDescription)
            case .unsupportedDefinitionKind, .unsupportedSemanticVersion:
                return fail("unsupported_definition", geometry.localizedDescription)
            case .invalidDefinitionShape, .invalidAttachmentFrame, .invalidBodyTransform,
                 .nonFiniteValue, .axisNotInPlane:
                return fail("invalid_definition", geometry.localizedDescription)
            }
        }
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
                case let .axis(id): row["axis_id"] = id.raw.uuidString
                case let .datumPoint(id): row["point_id"] = id.raw.uuidString
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
        if let id = extra["axis_id"] as? String,
           let descriptor = Self.axisRows(document: document).first(where: { ($0["axis_id"] as? String) == id }) {
            reply["axis"] = descriptor
        }
        if let id = extra["point_id"] as? String,
           let descriptor = Self.datumPointRows(document: document).first(where: { ($0["point_id"] as? String) == id }) {
            reply["point"] = descriptor
        }
        return reply
    }

    // MARK: - Offset plane

    private func createOffset(_ args: [String: Any]) -> [String: Any] {
        do {
            let distance = try distanceExpression(args["expression"])
            let displaySize = try size(args["size"]) ?? 100
            let selected = try source(args)
            let definition = OffsetPlaneDefinition(source: selected.reference,
                                                   sourceVersion: selected.version,
                                                   distance: distance, attachment: selected.frame)
            let plane = try definition.resolvedPlane(face: selected.face,
                                                     bodyTransform: selected.bodyTransform)
            let record = ConstructionPlane(plane: plane, size: displaySize, definition: .offset(definition))
            return commit([AddConstructionPlaneCommand(plane: record)], title: "Offset Plane",
                          action: "datum.offsetPlane.create", extra: ["plane_id": record.id.raw.uuidString])
        } catch { return self.error(error) }
    }

    private func updateOffset(_ args: [String: Any]) -> [String: Any] {
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
            if let supplied = args["expression"] { definition.distance = try distanceExpression(supplied) }
            let sourceFields = ["body_id", "face_index", "query_token"]
            let reselect = sourceFields.contains { args[$0] != nil }
            if reselect {
                guard sourceFields.allSatisfy({ args[$0] != nil }) else {
                    return fail("incomplete_source", "Reselecting a source requires body_id, face_index and query_token together.")
                }
                let selected = try source(args)
                definition = OffsetPlaneDefinition(version: definition.version,
                    source: selected.reference, sourceVersion: selected.version,
                    distance: definition.distance, attachment: selected.frame)
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

    // MARK: - Angle plane

    private func createAngle(_ args: [String: Any]) -> [String: Any] {
        do {
            let angle = try angleExpression(args["expression"])
            let localHinge = try hinge(args, fallback: SIMD2(1, 0))
            let displaySize = try size(args["size"]) ?? 100
            let selected = try source(args)
            let definition = AnglePlaneDefinition(source: selected.reference,
                                                  sourceVersion: selected.version,
                                                  hinge: localHinge, angle: angle,
                                                  attachment: selected.frame)
            let plane = try definition.resolvedPlane(face: selected.face,
                                                     bodyTransform: selected.bodyTransform)
            let record = ConstructionPlane(plane: plane, size: displaySize, definition: .angle(definition))
            return commit([AddConstructionPlaneCommand(plane: record)], title: "Angle Plane",
                          action: "datum.anglePlane.create", extra: ["plane_id": record.id.raw.uuidString])
        } catch { return self.error(error) }
    }

    private func updateAngle(_ args: [String: Any]) -> [String: Any] {
        guard let id = uuid(args["plane_id"]), let plane = document.session.document.planes.first(where: { $0.id.raw == id }),
              case var .angle(definition)? = plane.definition else {
            return fail("unknown_angle_plane", "plane_id must name an existing associative angle plane.")
        }
        if let raw = args["expected_expression"] {
            guard let expected = raw as? String else {
                return fail("bad_expected_expression", "expected_expression must be the current exact stored formula string (empty when absent).")
            }
            guard expected == (definition.angle.formula ?? "") else {
                return fail("expression_mismatch", "The angle expression changed. Re-query scope=planes before editing.")
            }
        }
        do {
            let newSize = try size(args["size"])
            if let supplied = args["expression"] { definition.angle = try angleExpression(supplied) }
            if args["hinge_x"] != nil || args["hinge_y"] != nil {
                definition = AnglePlaneDefinition(version: definition.version,
                    source: definition.source, sourceVersion: definition.sourceVersion,
                    hinge: try hinge(args, fallback: definition.hinge),
                    angle: definition.angle, attachment: definition.attachment)
            }
            let sourceFields = ["body_id", "face_index", "query_token"]
            let reselect = sourceFields.contains { args[$0] != nil }
            if reselect {
                guard sourceFields.allSatisfy({ args[$0] != nil }) else {
                    return fail("incomplete_source", "Reselecting a source requires body_id, face_index and query_token together.")
                }
                let selected = try source(args)
                definition = AnglePlaneDefinition(version: definition.version,
                    source: selected.reference, sourceVersion: selected.version,
                    hinge: definition.hinge, angle: definition.angle, attachment: selected.frame)
            }
            var commands: [DocumentCommand] = []
            if plane.definition != .angle(definition) {
                commands.append(EditConstructionPlaneDefinitionCommand(planeID: plane.id,
                    before: plane.definition, after: .angle(definition)))
            }
            if let newSize, newSize != plane.size {
                commands.append(SetDatumSizeCommand(planeID: plane.id, before: plane.size, after: newSize))
            }
            guard !commands.isEmpty else { return fail("no_change", "The plane already has those values.") }
            return commit(commands, title: "Edit Angle Plane", action: "datum.anglePlane.update",
                          extra: ["plane_id": plane.id.raw.uuidString])
        } catch { return self.error(error) }
    }

    // MARK: - Three-point plane

    private func anchor(_ value: Any?) throws -> SketchAnchorRef {
        guard let object = value as? [String: Any],
              let sketchID = uuid(object["sketch_id"]),
              let entityID = uuid(object["entity_id"]),
              let roleRaw = object["role"] as? String,
              let role = PointRole(rawValue: roleRaw), role.isPersistable,
              role != .whole else {
            throw Failure(code: "invalid_points",
                          message: "Each point needs sketch_id, entity_id and role from query kind=sketches (endpointA, endpointB or center).")
        }
        return SketchAnchorRef(sketchID: SketchID(raw: sketchID),
                               entityID: entityID, role: role)
    }
    private func points(_ value: Any?) throws -> [SketchAnchorRef] {
        guard let array = value as? [Any], array.count == 3 else {
            throw Failure(code: "invalid_points",
                          message: "points must contain exactly three sketch point references.")
        }
        return try array.map(anchor)
    }
    private func expectedPoints(_ value: Any?) throws -> [SketchAnchorRef]? {
        guard let value else { return nil }
        return try points(value)
    }

    /// Verify every stored identity still names the role it claims. This is a
    /// preflight only; the domain transaction re-resolves the complete graph
    /// and refuses a replacement/topology change atomically.
    private func validateAnchors(_ refs: [SketchAnchorRef]) throws {
        for ref in refs {
            guard let sketch = document.session.document.sketches.first(where: { $0.id == ref.sketchID }) else {
                throw Failure(code: "unknown_sketch",
                              message: "Point \(ref.key) names a sketch that no longer exists.")
            }
            guard let entity = sketch.entities.first(where: { $0.id == ref.entityID }) else {
                throw Failure(code: "unknown_entity",
                              message: "Point \(ref.key) names an entity that no longer exists in sketch '\(sketch.name)'.")
            }
            guard entity.anchorRoles.contains(ref.role) else {
                throw Failure(code: "unsupported_anchor_role",
                              message: "That \(Self.entityKind(entity)) exposes no \(ref.role.rawValue) point. Use a line/rect endpoint or a circle/arc/ellipse/polygon centre.")
            }
        }
        guard Set(refs.map(\.key)).count == 3 else {
            throw Failure(code: "invalid_points", message: "The three source points must be distinct.")
        }
    }
    private static func entityKind(_ entity: SketchEntity) -> String {
        switch entity {
        case .line: return "line"
        case .rect: return "rectangle"
        case .circle: return "circle"
        case .arc: return "arc"
        case .ellipse: return "ellipse"
        case .polygon: return "polygon"
        case .spline: return "spline"
        }
    }
    private func previewPlane(_ definition: ThreePointPlaneDefinition) throws -> SketchPlane {
        var world: [SIMD3<Double>] = []
        for ref in definition.points {
            guard let sketch = document.session.document.sketches.first(where: { $0.id == ref.sketchID }),
                  let entity = sketch.entities.first(where: { $0.id == ref.entityID }),
                  let local = entity.anchorPoint(for: ref.role) else {
                throw Failure(code: "invalid_points", message: "A source point cannot be resolved.")
            }
            world.append(sketch.plane.toWorld(local))
        }
        do { return try definition.resolvedPlane(worldPoints: world) }
        catch { throw Failure(code: "invalid_points", message: error.localizedDescription) }
    }
    private func createThreePoint(_ args: [String: Any]) -> [String: Any] {
        do {
            let refs = try points(args["points"])
            try validateAnchors(refs)
            let displaySize = try size(args["size"]) ?? 100
            let definition = ThreePointPlaneDefinition(points: refs)
            let plane = try previewPlane(definition)
            let record = ConstructionPlane(plane: plane, size: displaySize,
                                           definition: .threePoints(definition))
            return commit([AddConstructionPlaneCommand(plane: record)], title: "3-Point Plane",
                          action: "datum.threePointPlane.create",
                          extra: ["plane_id": record.id.raw.uuidString])
        } catch { return self.error(error) }
    }
    private func updateThreePoint(_ args: [String: Any]) -> [String: Any] {
        guard let id = uuid(args["plane_id"]), let plane = document.session.document.planes.first(where: { $0.id.raw == id }),
              case let .threePoints(existing)? = plane.definition else {
            return fail("unknown_three_point_plane",
                        "plane_id must name an existing associative three-point plane.")
        }
        do {
            let expected = try expectedPoints(args["expected_points"])
            if let expected, expected != existing.points {
                return fail("points_mismatch",
                            "The three-point sources changed. Re-query scope=planes before editing.")
            }
            let newSize = try size(args["size"])
            var refs = existing.points
            let suppliedPoints = args["points"] != nil
            let suppliedIndex = args["point_index"] != nil || args["point"] != nil
            guard !(suppliedPoints && suppliedIndex) else {
                return fail("ambiguous_points",
                            "Send either points (all three) or point_index + point, not both.")
            }
            if suppliedPoints {
                refs = try points(args["points"])
            } else if suppliedIndex {
                guard let index = integer(args["point_index"]), (0..<3).contains(index) else {
                    return fail("invalid_point_index", "point_index must be 0, 1 or 2.")
                }
                refs[index] = try anchor(args["point"])
            }
            try validateAnchors(refs)
            let definition = ThreePointPlaneDefinition(version: existing.version, points: refs)
            var commands: [DocumentCommand] = []
            if plane.definition != .threePoints(definition) {
                commands.append(EditConstructionPlaneDefinitionCommand(planeID: plane.id,
                    before: plane.definition, after: .threePoints(definition)))
            }
            if let newSize, newSize != plane.size {
                commands.append(SetDatumSizeCommand(planeID: plane.id, before: plane.size, after: newSize))
            }
            guard !commands.isEmpty else { return fail("no_change", "The plane already has those values.") }
            return commit(commands, title: "Edit 3-Point Plane",
                          action: "datum.threePointPlane.update",
                          extra: ["plane_id": plane.id.raw.uuidString])
        } catch { return self.error(error) }
    }

    // MARK: - Delete / support

    private func delete(_ args: [String: Any]) -> [String: Any] {
        guard let id = uuid(args["plane_id"]),
              let plane = document.session.document.planes.first(where: { $0.id.raw == id }),
              let definition = plane.definition else {
            return fail("unknown_associative_plane",
                        "plane_id must name an existing associative construction plane.")
        }
        let action: String
        let title: String
        switch definition.kind {
        case .offset: action = "datum.offsetPlane.delete"; title = "Delete Offset Plane"
        case .angle: action = "datum.anglePlane.delete"; title = "Delete Angle Plane"
        case .threePoints: action = "datum.threePointPlane.delete"; title = "Delete 3-Point Plane"
        }
        let model = document.session.document
        let sketches = model.sketches.filter {
            guard case let .construction(planeID)? = $0.support?.source else { return false }
            return planeID == plane.id
        }
        let sketchIDs = Set(sketches.map(\.id))
        let features = model.features.nodes.filter {
            $0.referencedConstructionPlaneIDs.contains(plane.id)
                || !$0.referencedSketchIDs.isDisjoint(with: sketchIDs)
        }
        guard sketches.isEmpty, features.isEmpty else {
            return fail("plane_in_use",
                        "Detach or rehost the dependent sketches/features before deleting this plane.",
                        fields: ["plane_id": plane.id.raw.uuidString,
                                 "dependent_sketch_ids": sketches.map { $0.id.raw.uuidString },
                                 "dependent_feature_ids": features.map { $0.id.raw.uuidString }])
        }
        guard let command = DeletePlaneCommand(id: plane.id, document: model) else {
            return fail("unknown_associative_plane", "The plane no longer exists.")
        }
        return commit([command], title: title, action: action,
                      extra: ["plane_id": plane.id.raw.uuidString, "deleted_kind": definition.kind.rawValue])
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
                cache: &scratch, variables: document.session.variableValues(),
                axes: current.axes, datumPoints: current.datumPoints)
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

    // MARK: - M08 associative construction axes

    private struct EdgeSource {
        var reference: EdgeRef
        var version: GeometryVersionRef
        /// Frozen-writer snapshot geometry, body-local.
        var geometry: SourceAxisGeometry
        var bodyTransform: Transform3D
        /// Body-local direction used to choose the offset's perpendicular.
        var referenceDirection: SIMD3<Double>
    }

    /// One persisted straight edge source from the same generation-proof
    /// address `query scope=edges` returns: body_id + 1-based kernel
    /// edge_index + its query_token. The PERSISTED reference is the edge
    /// signature/name, never the index.
    private func edgeSource(_ args: [String: Any]) throws -> EdgeSource {
        guard let id = uuid(args["body_id"]), let index = integer(args["edge_index"]), index > 0,
              let body = document.session.document.body(with: BodyID(raw: id)),
              let brep = body.brep else {
            throw Failure(code: "invalid_source",
                          message: "Use body_id and the 1-based kernel edge_index from query scope=edges.")
        }
        guard let token = args["query_token"] as? String,
              let generation = CADGeometryQueryGeneration.parse(token),
              generation.scope == "edges",
              generation.matches(documentRevision: document.revision,
                                 changeCount: document.session.changeCount,
                                 bodyID: id, meshRevision: body.meshRevision) else {
            throw Failure(code: "stale_query",
                          message: "Re-query scope=edges for this body and use its current query_token.")
        }
        guard document.session.lastNamingRevisions[body.id] == body.meshRevision else {
            throw Failure(code: "source_revision_required",
                          message: "Rebuild this body before creating an associative edge source.")
        }
        guard let kernelMidpoint = OCCTKernel.edgeMidpoints(brep)[index] else {
            throw Failure(code: "invalid_source",
                          message: "edge_index must name a current kernel edge of this body.")
        }
        let liveEdges = EdgeTopology.selectableEdges(from: body.render)
        let tolerance = OCCTKernel.matchTolerance(for: brep)
        func midpoint(_ edge: SelectableEdge) -> SIMD3<Double> {
            SIMD3<Double>(Double(edge.midpoint.x), Double(edge.midpoint.y), Double(edge.midpoint.z))
        }
        guard let picked = liveEdges.min(by: {
            simd_distance(midpoint($0), kernelMidpoint) < simd_distance(midpoint($1), kernelMidpoint)
        }), simd_distance(midpoint(picked), kernelMidpoint) <= tolerance else {
            throw Failure(code: "ambiguous_edge_source",
                          message: "That kernel edge has no unique current mesh edge. Re-pick the edge.")
        }
        guard EdgeTopology.smoothChain(containing: picked, in: liveEdges).count == 1 else {
            throw Failure(code: "straight_edge_source_required",
                          message: "An associative edge source must be one straight edge, not a curved chain.")
        }
        guard let acquired = document.session.associativeSource(for: body.id) else {
            throw Failure(code: "feature_source_required",
                          message: "An associative datum needs a successful feature-owned exact source.")
        }
        guard let producer = document.session.document.features.nodes.first(where: {
            $0.outputBodyIDs.contains(body.id)
        })?.id else {
            throw Failure(code: "feature_source_required",
                          message: "An associative datum needs a feature-owned body.")
        }
        let liveNames = document.session.lastKernelNames[body.id] ?? [:]
        let edgeName = liveNames.isEmpty ? nil : ElementNaming.edgeNames(
            adjacency: OCCTKernel.edgeFaceAdjacency(brep), names: liveNames)[index]
        let signature = EdgeTopology.signature(of: picked)
        let reference = EdgeRef(
            body: BodyRef(producer: producer, bodyID: body.id),
            signature: signature, faceNames: edgeName)
        // The definition resolves against the FROZEN writer's snapshot, so the
        // creation preview must read the same body, not the live render.
        let context = EdgeTopology.ReferenceContext(body: acquired.snapshot.body,
                                                   kernelNames: acquired.snapshot.kernelNames)
        guard let resolved = context.resolve(reference)?.edge else {
            throw Failure(code: "ambiguous_source",
                          message: "The picked edge is absent from its writer snapshot. Rebuild and re-pick.")
        }
        func d(_ v: SIMD3<Float>) -> SIMD3<Double> {
            SIMD3<Double>(Double(v.x), Double(v.y), Double(v.z))
        }
        let geometry = SourceAxisGeometry.alongEdge(
            bodyID: body.id, start: d(resolved.start), end: d(resolved.end))
        let direction = simd_normalize(geometry.direction)
        var referenceDirection = d(resolved.normalA)
        referenceDirection -= direction * simd_dot(referenceDirection, direction)
        if simd_length(referenceDirection) <= 1e-6 {
            referenceDirection = d(resolved.normalB)
            referenceDirection -= direction * simd_dot(referenceDirection, direction)
        }
        if simd_length(referenceDirection) <= 1e-6 {
            referenceDirection = Self.anyPerpendicular(to: direction)
        }
        return EdgeSource(reference: reference, version: acquired.version,
                          geometry: geometry, bodyTransform: acquired.snapshot.body.transform,
                          referenceDirection: simd_normalize(referenceDirection))
    }

    /// Any unit vector perpendicular to `d` (stable smallest-component choice).
    private static func anyPerpendicular(to d: SIMD3<Double>) -> SIMD3<Double> {
        let axis: SIMD3<Double> = abs(d.x) < abs(d.y)
            ? (abs(d.x) < abs(d.z) ? SIMD3(1, 0, 0) : SIMD3(0, 0, 1))
            : (abs(d.y) < abs(d.z) ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1))
        return simd_normalize(simd_cross(d, axis))
    }

    /// The current derived frames of every associative datum, from one scratch
    /// replay: creation/update previews use the SAME resolution the next
    /// rebuild will, never a stale cached plane/axis/point.
    private func currentDerived() -> (
        planes: [ConstructionPlaneID: SketchPlane],
        sketchPlanes: [SketchID: SketchPlane],
        axes: [ConstructionAxisID: ResolvedAxisGeometry],
        points: [DatumPointID: ResolvedDatumPointGeometry]
    ) {
        var scratch = EvalCache()
        var revision: UInt64 = 0
        let model = document.session.document
        let result = model.features.evaluate(
            sketches: model.sketches, planes: model.planes,
            naming: document.session.naming,
            nextRevision: { revision &+= 1; return revision },
            cache: &scratch, variables: document.session.variableValues(),
            axes: model.axes, datumPoints: model.datumPoints)
        return (result.resolvedPlaneUpdates, result.resolvedSketchSupportUpdates,
                result.resolvedAxisUpdates, result.resolvedDatumPointUpdates)
    }

    private func planeFrames(_ ids: [ConstructionPlaneID])
        throws -> [(plane: SketchPlane, size: Double)] {
        let derived = currentDerived()
        return try ids.map { id in
            guard let record = document.session.document.planes.first(where: { $0.id == id }) else {
                throw Failure(code: "unknown_plane", message: "plane_ids must name existing construction planes.")
            }
            return (derived.planes[id] ?? record.plane, record.size)
        }
    }

    /// One point source from the service surface: either the solver's semantic
    /// sketch anchor or another persisted datum point.
    private func pointSources(_ value: Any?) throws -> [DatumPointSource] {
        guard let rows = value as? [[String: Any]], !rows.isEmpty else {
            throw Failure(code: "invalid_points",
                          message: "points must be a non-empty array of {sketch_id,entity_id,role} or {point_id} objects.")
        }
        return try rows.map { row in
            if let rawPoint = row["point_id"] {
                guard let id = uuid(rawPoint),
                      document.session.document.datumPoints.contains(where: { $0.id.raw == id }) else {
                    throw Failure(code: "unknown_point", message: "point_id must name an existing datum point.")
                }
                guard row.keys.allSatisfy({ $0 == "point_id" }) else {
                    throw Failure(code: "contradictory_source",
                                  message: "A point entry names either point_id or a sketch anchor, never both.")
                }
                return .datumPoint(DatumPointID(raw: id))
            }
            guard let anchor = try? self.anchor(row) else {
                throw Failure(code: "invalid_points",
                              message: "Each point must name {sketch_id,entity_id,role} or {point_id}.")
            }
            guard anchor.role == .endpointA || anchor.role == .endpointB || anchor.role == .center else {
                throw Failure(code: "invalid_points",
                              message: "A datum point source must be an endpoint or centre, not a whole entity.")
            }
            return .sketchAnchor(anchor)
        }
    }

    private func validatePointSources(_ sources: [DatumPointSource], count: Int, label: String) throws {
        guard sources.count == count else {
            throw Failure(code: "invalid_points", message: "\(label) needs exactly \(count) distinct points.")
        }
        guard Set(sources.map(\.diagnosticKey)).count == count else {
            throw Failure(code: "invalid_points", message: "\(label) must name distinct points.")
        }
        for source in sources {
            switch source {
            case let .sketchAnchor(anchor):
                guard let sketch = document.session.document.sketches.first(where: { $0.id == anchor.sketchID }) else {
                    throw Failure(code: "unknown_sketch", message: "The anchor's sketch no longer exists.")
                }
                guard let entity = sketch.entities.first(where: { $0.id == anchor.entityID }),
                      entity.anchorPoint(for: anchor.role) != nil else {
                    throw Failure(code: "invalid_points",
                                  message: "The anchor's entity/role is not a persisted semantic point.")
                }
            case .datumPoint:
                break
            }
        }
    }

    private func worldPoint(_ source: DatumPointSource) throws -> SIMD3<Double> {
        switch source {
        case let .sketchAnchor(anchor):
            guard let sketch = document.session.document.sketches.first(where: { $0.id == anchor.sketchID }),
                  let entity = sketch.entities.first(where: { $0.id == anchor.entityID }),
                  let local = entity.anchorPoint(for: anchor.role) else {
                throw Failure(code: "invalid_points",
                              message: "The anchor's entity/role is no longer a persisted semantic point.")
            }
            let derived = currentDerived()
            let plane = derived.sketchPlanes[anchor.sketchID] ?? sketch.plane
            return plane.toWorld(local)
        case let .datumPoint(id):
            let derived = currentDerived()
            if let resolved = derived.points[id] { return resolved.position }
            guard let record = document.session.document.datumPoints.first(where: { $0.id == id }) else {
                throw Failure(code: "unknown_point", message: "The referenced datum point no longer exists.")
            }
            return record.position
        }
    }

    private func offsetExpression(_ value: Any?) throws -> Expr? {
        guard let value else { return nil }
        return try distanceExpression(value)
    }

    private func axisDefinition(_ args: [String: Any]) throws -> ConstructionAxisDefinition {
        guard let kind = (args["kind"] as? String)?.trimmingCharacters(in: .whitespaces) else {
            throw Failure(code: "missing_kind",
                          message: "kind must be face, edge, cylinder, twoPoints or twoPlanes.")
        }
        let offset = try offsetExpression(args["offset"])
        switch kind {
        case ConstructionAxisDefinition.Kind.face.rawValue:
            let selected = try source(args)
            let definition = FaceAxisDefinition(
                source: selected.reference, sourceVersion: selected.version,
                attachment: selected.frame,
                offset: offset ?? Expr(value: 0))
            try definition.validate()
            return .face(definition)
        case ConstructionAxisDefinition.Kind.edge.rawValue:
            let selected = try edgeSource(args)
            let definition = EdgeAxisDefinition(
                source: selected.reference, sourceVersion: selected.version,
                reference: selected.referenceDirection,
                offset: offset ?? Expr(value: 0))
            try definition.validate()
            return .edge(definition)
        case ConstructionAxisDefinition.Kind.cylinder.rawValue:
            guard offset == nil else {
                throw Failure(code: "offset_unsupported",
                              message: "A cylinder axis is the face's own centre line; it has no offset.")
            }
            let selected = try cylinderSource(args)
            let definition = CylinderAxisDefinition(
                source: selected.reference, sourceVersion: selected.version)
            try definition.validate()
            return .cylinder(definition)
        case ConstructionAxisDefinition.Kind.twoPoints.rawValue:
            guard offset == nil else {
                throw Failure(code: "offset_unsupported",
                              message: "A two-point axis follows its points; it has no offset.")
            }
            let sources = try pointSources(args["points"])
            try validatePointSources(sources, count: 2, label: "A two-point axis")
            let definition = TwoPointAxisDefinition(points: sources)
            try definition.validate()
            return .twoPoints(definition)
        case ConstructionAxisDefinition.Kind.twoPlanes.rawValue:
            guard offset == nil else {
                throw Failure(code: "offset_unsupported",
                              message: "A two-plane axis follows the plane intersection; it has no offset.")
            }
            guard let raw = args["plane_ids"] as? [Any], raw.count == 2 else {
                throw Failure(code: "invalid_planes",
                              message: "plane_ids must carry exactly two construction plane ids.")
            }
            let ids = try raw.map { value -> ConstructionPlaneID in
                guard let id = uuid(value),
                      document.session.document.planes.contains(where: { $0.id.raw == id }) else {
                    throw Failure(code: "unknown_plane",
                                  message: "plane_ids must name existing construction planes.")
                }
                return ConstructionPlaneID(raw: id)
            }
            let definition = TwoPlaneAxisDefinition(planes: ids)
            try definition.validate()
            return .twoPlanes(definition)
        default:
            throw Failure(code: "unknown_kind",
                          message: "kind must be face, edge, cylinder, twoPoints or twoPlanes.")
        }
    }

    /// Preview the EXACT frame a definition resolves to right now, from the
    /// same source values the resolver will read on the next rebuild.
    private func previewAxis(
        _ definition: ConstructionAxisDefinition, args: [String: Any]
    ) throws -> ResolvedAxisGeometry {
        switch definition {
        case let .face(payload):
            let selected = try source(args)
            let extent = max(selected.faceExtent * selected.bodyTransform.scale, 1e-6)
            return try payload.resolvedAxis(
                face: selected.face, bodyTransform: selected.bodyTransform, extent: extent)
        case let .edge(payload):
            let selected = try edgeSource(args)
            return try payload.resolvedAxis(
                edge: selected.geometry, bodyTransform: selected.bodyTransform,
                scale: selected.bodyTransform.scale)
        case let .cylinder(payload):
            let selected = try cylinderSource(args)
            return try payload.resolvedAxis(
                cylinder: selected.cylinder, bodyTransform: selected.bodyTransform,
                scale: selected.bodyTransform.scale)
        case let .twoPoints(payload):
            let world = try payload.points.map(worldPoint)
            return try payload.resolvedAxis(worldPoints: world)
        case let .twoPlanes(payload):
            let frames = try planeFrames(payload.planes)
            return try payload.resolvedAxis(
                planes: frames.map(\.plane), sizes: frames.map(\.size))
        }
    }

    private func createAxis(_ args: [String: Any]) -> [String: Any] {
        do {
            let definition = try axisDefinition(args)
            let displaySize = try size(args["size"])
            let geometry = try previewAxis(definition, args: args)
            guard let axis = ConstructionAxis(
                origin: geometry.origin, direction: geometry.direction,
                length: displaySize ?? max(geometry.extent, 1e-6),
                name: "Axis \(document.session.document.axes.count + 1)",
                definition: definition)
            else {
                throw Failure(code: "degenerate_source",
                              message: "That source does not define a usable axis direction.")
            }
            return commit([AddConstructionAxisCommand(axis: axis)], title: "Add Axis",
                          action: "datum.axis.create",
                          extra: ["axis_id": axis.id.raw.uuidString])
        } catch { return self.error(error) }
    }

    private func updateAxis(_ args: [String: Any]) -> [String: Any] {
        guard let id = uuid(args["axis_id"]),
              let axis = document.session.document.axes.first(where: { $0.id.raw == id }),
              let current = axis.definition else {
            return fail("unknown_associative_axis",
                        "axis_id must name an existing associative construction axis.")
        }
        if let raw = args["expected_offset"] {
            guard let expected = raw as? String else {
                return fail("bad_expected_offset",
                            "expected_offset must be the current exact stored formula string (empty when absent).")
            }
            guard expected == (current.expressionSlots.first(where: { $0.name == "offset" })?.expr.formula ?? "") else {
                return fail("offset_mismatch",
                            "The axis offset changed. Re-query scope=axes before editing.")
            }
        }
        do {
            let newSize = try size(args["size"])
            let offset = try offsetExpression(args["offset"])
            let sourceFields = ["kind", "body_id", "face_index", "edge_index", "query_token",
                                "plane_ids", "points"]
            if let offset {
                guard !sourceFields.contains(where: { args[$0] != nil }) else {
                    throw Failure(code: "ambiguous_update",
                                  message: "Send either offset or the complete source fields, not both.")
                }
                guard current.expressionSlots.contains(where: { $0.name == "offset" }) else {
                    throw Failure(code: "offset_unsupported",
                                  message: "This axis kind follows its sources and has no offset.")
                }
                guard let edited = current.settingExpression(named: "offset", to: offset) else {
                    throw Failure(code: "offset_unsupported",
                                  message: "This axis kind has no offset slot.")
                }
                var commands: [DocumentCommand] = []
                if edited != current {
                    commands.append(EditConstructionAxisDefinitionCommand(
                        axisID: axis.id, before: current, after: edited))
                }
                if let newSize, newSize != axis.length {
                    commands.append(SetAxisLengthCommand(axisID: axis.id,
                                                         before: axis.length, after: newSize))
                }
                guard !commands.isEmpty else {
                    return fail("no_change", "The axis already has those values.")
                }
                return commit(commands, title: "Edit Construction Axis",
                              action: "datum.axis.update",
                              extra: ["axis_id": axis.id.raw.uuidString])
            }
            let reselect = sourceFields.contains { args[$0] != nil }
            guard reselect else {
                var commands: [DocumentCommand] = []
                if let newSize, newSize != axis.length {
                    commands.append(SetAxisLengthCommand(axisID: axis.id,
                                                         before: axis.length, after: newSize))
                }
                guard !commands.isEmpty else {
                    return fail("no_change", "The axis already has those values.")
                }
                return commit(commands, title: "Edit Construction Axis",
                              action: "datum.axis.update",
                              extra: ["axis_id": axis.id.raw.uuidString])
            }
            // A fresh-source reselect keeps the axis's own kind. The source
            // triple alone cannot tell a planar face from a cylindrical one,
            // and the axis already owns that semantic; requiring the caller to
            // restate it made a valid "reselect the other face" fail as
            // missing_kind. An explicitly supplied kind still goes through the
            // kind_mismatch guard below, so this never switches the definition.
            var reselectArgs = args
            if reselectArgs["kind"] == nil {
                reselectArgs["kind"] = current.kind.rawValue
            }
            var definition = try axisDefinition(reselectArgs)
            guard definition.kind == current.kind else {
                return fail("kind_mismatch", "Reselect the source with the axis's own kind (\(current.kind.rawValue)).")
            }
            // Reselecting the SOURCE must not reset an independently authored
            // offset (value and formula). This is the same contract the M07
            // plane update uses; only an explicit offset argument replaces it.
            if args["offset"] == nil,
               let slot = current.expressionSlots.first(where: { $0.name == "offset" }),
               let preserved = definition.settingExpression(named: "offset", to: slot.expr) {
                definition = preserved
            }
            var commands: [DocumentCommand] = []
            if definition != current {
                commands.append(EditConstructionAxisDefinitionCommand(
                    axisID: axis.id, before: current, after: definition))
            }
            if let newSize, newSize != axis.length {
                commands.append(SetAxisLengthCommand(axisID: axis.id,
                                                     before: axis.length, after: newSize))
            }
            guard !commands.isEmpty else { return fail("no_change", "The axis already has that source.") }
            return commit(commands, title: "Reselect Axis Source",
                          action: "datum.axis.update",
                          extra: ["axis_id": axis.id.raw.uuidString])
        } catch { return self.error(error) }
    }

    private func deleteAxis(_ args: [String: Any]) -> [String: Any] {
        guard let id = uuid(args["axis_id"]),
              let axis = document.session.document.axes.first(where: { $0.id.raw == id }) else {
            return fail("unknown_axis", "axis_id must name an existing construction axis.")
        }
        let model = document.session.document
        let patterns = model.features.nodes.filter {
            if case let .pattern(_, spec) = $0.kind, spec.axisRef?.axisID == axis.id { return true }
            return false
        }
        // M08 R2: a revolve that stores this axis identity is a consumer too,
        // so deleting the axis would orphan it on the next replay.
        let revolves = model.features.nodes.filter { node in
            guard case let .revolve(_, _, ref, _, _) = node.kind,
                  case let .constructionAxis(id) = ref.source else { return false }
            return id == axis.id
        }
        let points = model.datumPoints.filter { $0.definition?.axisID == axis.id }
        guard patterns.isEmpty, revolves.isEmpty, points.isEmpty else {
            return fail("axis_in_use",
                        "Repoint the dependent patterns/revolves/datum points before deleting this axis.",
                        fields: ["axis_id": axis.id.raw.uuidString,
                                 "dependent_feature_ids": (patterns + revolves)
                                    .map { $0.id.raw.uuidString }.sorted(),
                                 "dependent_pattern_feature_ids": patterns.map { $0.id.raw.uuidString },
                                 "dependent_revolve_feature_ids": revolves.map { $0.id.raw.uuidString },
                                 "dependent_point_ids": points.map { $0.id.raw.uuidString }])
        }
        guard let command = DeleteAxisCommand(id: axis.id, document: model) else {
            return fail("unknown_axis", "The axis no longer exists.")
        }
        let kind = axis.definition?.kind.rawValue ?? "explicit"
        return commit([command], title: "Delete Axis", action: "datum.axis.delete",
                      extra: ["axis_id": axis.id.raw.uuidString, "deleted_kind": kind])
    }

    // MARK: - M08 associative datum points

    private func pointDefinition(_ args: [String: Any]) throws -> DatumPointDefinition {
        guard let kind = (args["kind"] as? String)?.trimmingCharacters(in: .whitespaces) else {
            throw Failure(code: "missing_kind",
                          message: "kind must be faceCenter, edgePoint, twoPointMidpoint, axisPoint or axisPlane.")
        }
        let offset = try offsetExpression(args["offset"])
        switch kind {
        case DatumPointDefinition.Kind.faceCenter.rawValue:
            guard offset == nil else {
                throw Failure(code: "offset_unsupported",
                              message: "A face-centre point follows the face; it has no offset.")
            }
            let selected = try source(args)
            let definition = FaceCenterPointDefinition(
                source: selected.reference, sourceVersion: selected.version)
            try definition.validate()
            return .faceCenter(definition)
        case DatumPointDefinition.Kind.edgePoint.rawValue:
            let selected = try edgeSource(args)
            let definition = EdgePointDefinition(
                source: selected.reference, sourceVersion: selected.version,
                offset: offset ?? Expr(value: 0))
            try definition.validate()
            return .edgePoint(definition)
        case DatumPointDefinition.Kind.twoPointMidpoint.rawValue:
            guard offset == nil else {
                throw Failure(code: "offset_unsupported",
                              message: "A midpoint follows its points; it has no offset.")
            }
            let sources = try pointSources(args["points"])
            try validatePointSources(sources, count: 2, label: "A midpoint")
            let definition = TwoPointMidpointDefinition(points: sources)
            try definition.validate()
            return .twoPointMidpoint(definition)
        case DatumPointDefinition.Kind.axisPoint.rawValue:
            guard let rawAxis = args["axis_id"], let axisID = uuid(rawAxis),
                  document.session.document.axes.contains(where: { $0.id.raw == axisID }) else {
                throw Failure(code: "unknown_axis", message: "axis_id must name an existing construction axis.")
            }
            let definition = AxisPointDefinition(
                axis: ConstructionAxisID(raw: axisID),
                offset: offset ?? Expr(value: 0))
            try definition.validate()
            return .axisPoint(definition)
        case DatumPointDefinition.Kind.axisPlane.rawValue:
            guard offset == nil else {
                throw Failure(code: "offset_unsupported",
                              message: "An axis/plane point follows both sources; it has no offset.")
            }
            guard let rawAxis = args["axis_id"], let axisID = uuid(rawAxis),
                  document.session.document.axes.contains(where: { $0.id.raw == axisID }) else {
                throw Failure(code: "unknown_axis", message: "axis_id must name an existing construction axis.")
            }
            guard let rawPlane = args["plane_id"], let planeID = uuid(rawPlane),
                  document.session.document.planes.contains(where: { $0.id.raw == planeID }) else {
                throw Failure(code: "unknown_plane", message: "plane_id must name an existing construction plane.")
            }
            let definition = AxisPlanePointDefinition(
                axis: ConstructionAxisID(raw: axisID),
                plane: ConstructionPlaneID(raw: planeID))
            try definition.validate()
            return .axisPlane(definition)
        default:
            throw Failure(code: "unknown_kind",
                          message: "kind must be faceCenter, edgePoint, twoPointMidpoint, axisPoint or axisPlane.")
        }
    }

    private func previewPoint(
        _ definition: DatumPointDefinition, args: [String: Any]
    ) throws -> ResolvedDatumPointGeometry {
        switch definition {
        case let .faceCenter(payload):
            let selected = try source(args)
            return try payload.resolvedPoint(
                face: selected.face, bodyTransform: selected.bodyTransform)
        case let .edgePoint(payload):
            let selected = try edgeSource(args)
            return try payload.resolvedPoint(
                edge: selected.geometry, bodyTransform: selected.bodyTransform)
        case let .twoPointMidpoint(payload):
            let world = try payload.points.map(worldPoint)
            return try payload.resolvedPoint(worldPoints: world)
        case let .axisPoint(payload):
            let derived = currentDerived()
            guard let frame = derived.axes[payload.axis] else {
                throw Failure(code: "unresolved_axis",
                              message: "The referenced axis cannot be resolved right now.")
            }
            return try payload.resolvedPoint(axis: frame)
        case let .axisPlane(payload):
            let derived = currentDerived()
            guard let frame = derived.axes[payload.axis] else {
                throw Failure(code: "unresolved_axis",
                              message: "The referenced axis cannot be resolved right now.")
            }
            guard let plane = derived.planes[payload.plane]
                    ?? document.session.document.planes.first(where: { $0.id == payload.plane })?.plane else {
                throw Failure(code: "unknown_plane",
                              message: "The referenced construction plane no longer exists.")
            }
            return try payload.resolvedPoint(axis: frame, plane: plane)
        }
    }

    private func createPoint(_ args: [String: Any]) -> [String: Any] {
        do {
            let definition = try pointDefinition(args)
            let geometry = try previewPoint(definition, args: args)
            let point = DatumPoint(
                position: geometry.position,
                name: "Point \(document.session.document.datumPoints.count + 1)",
                definition: definition)
            return commit([AddDatumPointCommand(point: point)], title: "Add Point",
                          action: "datum.point.create",
                          extra: ["point_id": point.id.raw.uuidString])
        } catch { return self.error(error) }
    }

    private func updatePoint(_ args: [String: Any]) -> [String: Any] {
        guard let id = uuid(args["point_id"]),
              let point = document.session.document.datumPoints.first(where: { $0.id.raw == id }),
              let current = point.definition else {
            return fail("unknown_associative_point",
                        "point_id must name an existing associative datum point.")
        }
        if let raw = args["expected_offset"] {
            guard let expected = raw as? String else {
                return fail("bad_expected_offset",
                            "expected_offset must be the current exact stored formula string (empty when absent).")
            }
            guard expected == (current.expressionSlots.first(where: { $0.name == "offset" })?.expr.formula ?? "") else {
                return fail("offset_mismatch",
                            "The point offset changed. Re-query scope=datumPoints before editing.")
            }
        }
        do {
            let offset = try offsetExpression(args["offset"])
            if let offset {
                guard current.expressionSlots.contains(where: { $0.name == "offset" }) else {
                    throw Failure(code: "offset_unsupported",
                                  message: "This point kind follows its sources and has no offset.")
                }
                guard let edited = current.settingExpression(named: "offset", to: offset) else {
                    throw Failure(code: "offset_unsupported",
                                  message: "This point kind has no offset slot.")
                }
                // An offset-only edit keeps the source kind and every other
                // field. Mixing both in one call is ambiguous, so it refuses
                // instead of silently dropping the source fields.
                let sourceFields = ["kind", "body_id", "face_index", "edge_index",
                                    "query_token", "points", "axis_id", "plane_id"]
                if sourceFields.contains(where: { args[$0] != nil }) {
                    throw Failure(code: "ambiguous_update",
                                  message: "Send either offset or the complete source fields, not both.")
                }
                return commit([EditDatumPointDefinitionCommand(
                    pointID: point.id, before: current, after: edited)],
                    title: "Edit Point", action: "datum.point.update",
                    extra: ["point_id": point.id.raw.uuidString])
            }
            let reselect = ["kind", "body_id", "face_index", "edge_index", "query_token",
                            "points", "axis_id", "plane_id"].contains { args[$0] != nil }
            guard reselect else { return fail("no_change", "The point already has those values.") }
            // Same kind-preserving reselect as axes: the point already owns its
            // kind, and an explicit contradicting kind still refuses.
            var reselectArgs = args
            if reselectArgs["kind"] == nil {
                reselectArgs["kind"] = current.kind.rawValue
            }
            var definition = try pointDefinition(reselectArgs)
            guard definition.kind == current.kind else {
                return fail("kind_mismatch",
                            "Reselect the source with the point's own kind (\(current.kind.rawValue)).")
            }
            // A source reselect keeps an authored offset; only an explicit
            // offset argument replaces it (the axis and M07 rules are the same).
            if args["offset"] == nil,
               let slot = current.expressionSlots.first(where: { $0.name == "offset" }),
               let preserved = definition.settingExpression(named: "offset", to: slot.expr) {
                definition = preserved
            }
            guard definition != current else { return fail("no_change", "The point already has that source.") }
            return commit([EditDatumPointDefinitionCommand(
                pointID: point.id, before: current, after: definition)],
                title: "Reselect Point Source", action: "datum.point.update",
                extra: ["point_id": point.id.raw.uuidString])
        } catch { return self.error(error) }
    }

    private func deletePoint(_ args: [String: Any]) -> [String: Any] {
        guard let id = uuid(args["point_id"]),
              let point = document.session.document.datumPoints.first(where: { $0.id.raw == id }) else {
            return fail("unknown_point", "point_id must name an existing datum point.")
        }
        let model = document.session.document
        let axes = model.axes.filter {
            guard case let .twoPoints(definition)? = $0.definition else { return false }
            return definition.points.contains { if case let .datumPoint(pid) = $0 { return pid == point.id } else { return false } }
        }
        let points = model.datumPoints.filter { other in
            guard other.id != point.id, case let .twoPointMidpoint(definition)? = other.definition else { return false }
            return definition.points.contains { if case let .datumPoint(pid) = $0 { return pid == point.id } else { return false } }
        }
        guard axes.isEmpty, points.isEmpty else {
            return fail("point_in_use",
                        "Repoint the dependent axes/points before deleting this point.",
                        fields: ["point_id": point.id.raw.uuidString,
                                 "dependent_axis_ids": axes.map { $0.id.raw.uuidString },
                                 "dependent_point_ids": points.map { $0.id.raw.uuidString }])
        }
        guard let command = DeleteDatumPointCommand(id: point.id, document: model) else {
            return fail("unknown_point", "The point no longer exists.")
        }
        let kind = point.definition?.kind.rawValue ?? "explicit"
        return commit([command], title: "Delete Point", action: "datum.point.delete",
                      extra: ["point_id": point.id.raw.uuidString, "deleted_kind": kind])
    }

    // MARK: - Query rows

    static func planeRows(document: FloeCADDocument) -> [[String: Any]] {
        document.session.document.planes.map { plane in
            var row: [String: Any] = ["id": plane.id.raw.uuidString, "plane_id": plane.id.raw.uuidString,
                "kind": "explicit", "size": plane.size, "unit": "mm", "hidden": plane.isHidden,
                "frame": frameJSON(plane.plane), "editable": document.session.writeBlock == nil,
                "support_action": "sketch.setSupport"]
            switch plane.definition {
            case let .offset(definition)?:
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
                row["source_ids"] = [definition.sourceVersion.bodyID.raw.uuidString,
                                     definition.sourceVersion.writer.raw.uuidString]
                row["update_action"] = "datum.offsetPlane.update"
                row["delete_action"] = "datum.offsetPlane.delete"
                row["supported_operations"] = ["update_expression", "reselect_source", "resize", "delete"]
            case let .angle(definition)?:
                row["kind"] = "angle"
                row["definition_version"] = definition.version
                row["expression"] = definition.angle.formula ?? String(definition.angle.value)
                row["formula"] = definition.angle.formula ?? NSNull()
                row["expression_unit"] = "deg"
                row["value"] = definition.angle.value
                row["hinge_local"] = [definition.hinge.x, definition.hinge.y]
                row["source_body_id"] = definition.sourceVersion.bodyID.raw.uuidString
                row["source_writer_id"] = definition.sourceVersion.writer.raw.uuidString
                row["source_producer_id"] = definition.source.body.producer.raw.uuidString
                row["kernel_element_name"] = definition.source.elementName.flatMap(json) ?? NSNull()
                row["source_ids"] = [definition.sourceVersion.bodyID.raw.uuidString,
                                     definition.sourceVersion.writer.raw.uuidString]
                row["update_action"] = "datum.anglePlane.update"
                row["delete_action"] = "datum.anglePlane.delete"
                row["supported_operations"] = ["update_expression", "set_hinge",
                                               "reselect_source", "resize", "delete"]
            case let .threePoints(definition)?:
                row["kind"] = "threePoints"
                row["definition_version"] = definition.version
                row["expression_unit"] = "mm"
                row["points"] = definition.points.map { anchorRow($0, document: document) }
                row["source_sketch_ids"] = definition.points.map { $0.sketchID.raw.uuidString }
                row["source_ids"] = definition.points.map { $0.key }
                row["update_action"] = "datum.threePointPlane.update"
                row["delete_action"] = "datum.threePointPlane.delete"
                row["supported_operations"] = ["reselect_points", "resize", "delete"]
            case nil:
                break
            }
            if document.isReadOnly {
                row["status"] = "read_only"
                row["frame_status"] = "cached"
                row.removeValue(forKey: "support_action")
                row.removeValue(forKey: "update_action")
                row.removeValue(forKey: "delete_action")
                row.removeValue(forKey: "supported_operations")
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
                row.removeValue(forKey: "supported_operations")
            } else if let error = document.session.lastReferenceErrors[.plane(plane.id)] {
                row["status"] = "error"; row["error"] = error.message
            } else { row["status"] = "resolved"; row["frame_status"] = "resolved" }
            return row
        }
    }

    /// One query row per construction axis, including its associative
    /// definition and the consumers that keep the relationship alive.
    static func axisRows(document: FloeCADDocument) -> [[String: Any]] {
        let model = document.session.document
        var patternUsers: [ConstructionAxisID: [String]] = [:]
        for node in model.features.nodes {
            guard case let .pattern(_, spec) = node.kind, let ref = spec.axisRef else { continue }
            patternUsers[ref.axisID, default: []].append(node.id.raw.uuidString)
        }
        var pointUsers: [ConstructionAxisID: [String]] = [:]
        for point in model.datumPoints {
            guard let id = point.definition?.axisID else { continue }
            pointUsers[id, default: []].append(point.id.raw.uuidString)
        }
        var revolveUsers: [ConstructionAxisID: [String]] = [:]
        for node in model.features.nodes {
            guard case let .revolve(_, _, ref, _, _) = node.kind,
                  case let .constructionAxis(id) = ref.source else { continue }
            revolveUsers[id, default: []].append(node.id.raw.uuidString)
        }
        func vector(_ v: SIMD3<Double>) -> [Double] { [v.x, v.y, v.z] }

        return model.axes.map { axis in
            var row: [String: Any] = [
                "id": axis.id.raw.uuidString,
                "axis_id": axis.id.raw.uuidString,
                "name": axis.name,
                "kind": "explicit",
                "length": axis.length,
                "unit": "mm",
                "hidden": axis.isHidden,
                "origin": vector(axis.origin),
                "direction": vector(axis.direction),
                "frame": ["origin": vector(axis.origin), "direction": vector(axis.direction)],
                "frame_status": "cached",
                "editable": document.session.writeBlock == nil,
                "supported_operations": ["datum.axis.update", "datum.axis.delete"],
            ]
            if let consumers = patternUsers[axis.id] { row["used_by_pattern_feature_ids"] = consumers.sorted() }
            if let consumers = revolveUsers[axis.id] { row["used_by_revolve_feature_ids"] = consumers.sorted() }
            if let consumers = pointUsers[axis.id] { row["used_by_point_ids"] = consumers.sorted() }
            let consumers = (patternUsers[axis.id] ?? []) + (revolveUsers[axis.id] ?? [])
                + (pointUsers[axis.id] ?? [])
            if !consumers.isEmpty { row["used_by_feature_ids"] = consumers.sorted() }
            if let definition = axis.definition {
                row["definition_version"] = definition.semanticVersion
                row["supported_definition_version"] = definition.supportedSemanticVersion
                row["offset_supported"] = definition.expressionSlots.contains { $0.name == "offset" }
                switch definition {
                case let .face(payload):
                    row["kind"] = "face"
                    row["surface_mode"] = "planar"
                    row["source_body_id"] = payload.sourceVersion.bodyID.raw.uuidString
                    row["source_writer_id"] = payload.sourceVersion.writer.raw.uuidString
                    row["source_producer_id"] = payload.source.body.producer.raw.uuidString
                    row["kernel_element_name"] = payload.source.elementName.flatMap(json) ?? NSNull()
                    row["hinge_frame"] = [
                        "normal": vector(payload.attachment.normal),
                        "xAxis": vector(payload.attachment.xAxis),
                    ]
                case let .cylinder(payload):
                    row["kind"] = "cylinder"
                    row["surface_mode"] = "cylinder"
                    row["source_body_id"] = payload.sourceVersion.bodyID.raw.uuidString
                    row["source_writer_id"] = payload.sourceVersion.writer.raw.uuidString
                    row["source_producer_id"] = payload.source.body.producer.raw.uuidString
                    row["kernel_element_name"] = payload.source.elementName.flatMap(json) ?? NSNull()
                    // The FaceRef signature's radius is persisted IDENTITY, not
                    // the current size; the current line is `frame` above.
                    if case let .cylindrical(radius) = payload.source.signature.kind {
                        row["frozen_source_radius"] = radius
                    }
                    row["definition_semantics"] = "analytic-cylinder-axis"
                case let .edge(payload):
                    row["kind"] = "edge"
                    row["source_body_id"] = payload.sourceVersion.bodyID.raw.uuidString
                    row["source_writer_id"] = payload.sourceVersion.writer.raw.uuidString
                    row["source_producer_id"] = payload.source.body.producer.raw.uuidString
                    row["edge_midpoint"] = vector(payload.source.signature.midpoint)
                    row["edge_direction"] = vector(payload.source.signature.direction)
                    row["edge_length"] = payload.source.signature.length
                case let .twoPoints(payload):
                    row["kind"] = "twoPoints"
                    row["points"] = payload.points.map {
                        pointSourceRow($0, document: document)
                    }
                    row["source_sketch_ids"] = Array(Set(payload.points.compactMap {
                        if case let .sketchAnchor(anchor) = $0 { return anchor.sketchID.raw.uuidString }
                        return nil
                    })).sorted()
                    row["source_point_ids"] = payload.points.compactMap {
                        if case let .datumPoint(id) = $0 { return id.raw.uuidString }
                        return nil
                    }
                case let .twoPlanes(payload):
                    row["kind"] = "twoPlanes"
                    row["plane_ids"] = payload.planes.map { $0.raw.uuidString }
                }
                if let slot = definition.expressionSlots.first(where: { $0.name == "offset" }) {
                    row["expression"] = slot.expr.formula ?? String(slot.expr.value)
                    row["formula"] = slot.expr.formula ?? NSNull()
                    row["expression_unit"] = slot.unit
                    row["value"] = slot.expr.value
                }
                row["update_action"] = "datum.axis.update"
                row["delete_action"] = "datum.axis.delete"
            }
            if document.isReadOnly {
                row["status"] = "read_only"
                if document.project.hasOpaqueAssociations, axis.definition != nil {
                    row["kind"] = "unsupported"
                    row["semantics"] = "opaque"
                    row.removeValue(forKey: "origin")
                    row.removeValue(forKey: "direction")
                }
                row.removeValue(forKey: "update_action")
                row.removeValue(forKey: "delete_action")
            } else if let block = document.session.writeBlock {
                row["status"] = block.code
                row["write_block"] = ["code": block.code, "message": block.message]
                row.removeValue(forKey: "update_action")
                row.removeValue(forKey: "delete_action")
            } else if let error = document.session.lastReferenceErrors[.axis(axis.id)] {
                row["status"] = "error"
                row["error"] = error.message
            } else if axis.definition == nil {
                row["status"] = "explicit"
            } else {
                row["status"] = "resolved"
                row["frame_status"] = "resolved"
            }
            return row
        }
    }

    /// One query row per datum point, with its definition and consumers.
    static func datumPointRows(document: FloeCADDocument) -> [[String: Any]] {
        let model = document.session.document
        var axisUsers: [DatumPointID: [String]] = [:]
        for axis in model.axes {
            guard case let .twoPoints(definition)? = axis.definition else { continue }
            for source in definition.points {
                if case let .datumPoint(id) = source {
                    axisUsers[id, default: []].append(axis.id.raw.uuidString)
                }
            }
        }
        var pointUsers: [DatumPointID: [String]] = [:]
        for point in model.datumPoints {
            guard case let .twoPointMidpoint(definition)? = point.definition else { continue }
            for source in definition.points {
                if case let .datumPoint(id) = source, id != point.id {
                    pointUsers[id, default: []].append(point.id.raw.uuidString)
                }
            }
        }
        func vector(_ v: SIMD3<Double>) -> [Double] { [v.x, v.y, v.z] }

        return model.datumPoints.map { point in
            var row: [String: Any] = [
                "id": point.id.raw.uuidString,
                "point_id": point.id.raw.uuidString,
                "name": point.name,
                "kind": "explicit",
                "unit": "mm",
                "hidden": point.isHidden,
                "position": vector(point.position),
                "frame_status": "cached",
                "editable": document.session.writeBlock == nil,
                "supported_operations": ["datum.point.update", "datum.point.delete"],
            ]
            if let consumers = axisUsers[point.id] { row["used_by_axis_ids"] = consumers.sorted() }
            if let consumers = pointUsers[point.id] { row["used_by_point_ids"] = consumers.sorted() }
            if let definition = point.definition {
                row["definition_version"] = definition.semanticVersion
                row["supported_definition_version"] = definition.supportedSemanticVersion
                row["offset_supported"] = definition.expressionSlots.contains { $0.name == "offset" }
                switch definition {
                case let .faceCenter(payload):
                    row["kind"] = "faceCenter"
                    row["source_body_id"] = payload.sourceVersion.bodyID.raw.uuidString
                    row["source_writer_id"] = payload.sourceVersion.writer.raw.uuidString
                    row["source_producer_id"] = payload.source.body.producer.raw.uuidString
                    row["kernel_element_name"] = payload.source.elementName.flatMap(json) ?? NSNull()
                case let .edgePoint(payload):
                    row["kind"] = "edgePoint"
                    row["source_body_id"] = payload.sourceVersion.bodyID.raw.uuidString
                    row["source_writer_id"] = payload.sourceVersion.writer.raw.uuidString
                    row["source_producer_id"] = payload.source.body.producer.raw.uuidString
                    row["edge_midpoint"] = vector(payload.source.signature.midpoint)
                    row["edge_direction"] = vector(payload.source.signature.direction)
                    row["edge_length"] = payload.source.signature.length
                case let .twoPointMidpoint(payload):
                    row["kind"] = "twoPointMidpoint"
                    row["points"] = payload.points.map {
                        pointSourceRow($0, document: document)
                    }
                case let .axisPoint(payload):
                    row["kind"] = "axisPoint"
                    row["axis_id"] = payload.axis.raw.uuidString
                case let .axisPlane(payload):
                    row["kind"] = "axisPlane"
                    row["axis_id"] = payload.axis.raw.uuidString
                    row["plane_id"] = payload.plane.raw.uuidString
                }
                if let slot = definition.expressionSlots.first(where: { $0.name == "offset" }) {
                    row["expression"] = slot.expr.formula ?? String(slot.expr.value)
                    row["formula"] = slot.expr.formula ?? NSNull()
                    row["expression_unit"] = slot.unit
                    row["value"] = slot.expr.value
                }
                row["update_action"] = "datum.point.update"
                row["delete_action"] = "datum.point.delete"
            }
            if document.isReadOnly {
                row["status"] = "read_only"
                if document.project.hasOpaqueAssociations, point.definition != nil {
                    row["kind"] = "unsupported"
                    row["semantics"] = "opaque"
                    row.removeValue(forKey: "position")
                }
                row.removeValue(forKey: "update_action")
                row.removeValue(forKey: "delete_action")
            } else if let block = document.session.writeBlock {
                row["status"] = block.code
                row["write_block"] = ["code": block.code, "message": block.message]
                row.removeValue(forKey: "update_action")
                row.removeValue(forKey: "delete_action")
            } else if let error = document.session.lastReferenceErrors[.datumPoint(point.id)] {
                row["status"] = "error"
                row["error"] = error.message
            } else if point.definition == nil {
                row["status"] = "explicit"
            } else {
                row["status"] = "resolved"
                row["frame_status"] = "resolved"
            }
            return row
        }
    }

    /// One point source as a query row: its persisted identity plus (for a
    /// sketch anchor) the current plane-local position for selection display.
    /// The world position is a read-only convenience, never persisted.
    private static func pointSourceRow(
        _ source: DatumPointSource, document: FloeCADDocument
    ) -> [String: Any] {
        switch source {
        case let .sketchAnchor(anchor):
            var row: [String: Any] = [
                "source_kind": "sketchAnchor",
                "sketch_id": anchor.sketchID.raw.uuidString,
                "entity_id": anchor.entityID.uuidString,
                "role": anchor.role.rawValue,
            ]
            if let sketch = document.session.document.sketches.first(where: { $0.id == anchor.sketchID }) {
                row["sketch_name"] = sketch.name
                if let entity = sketch.entities.first(where: { $0.id == anchor.entityID }),
                   let local = entity.anchorPoint(for: anchor.role) {
                    row["point_local"] = [local.x, local.y]
                    let world = sketch.plane.toWorld(local)
                    row["point_world"] = [world.x, world.y, world.z]
                    row["resolved"] = true
                } else {
                    row["resolved"] = false
                }
            } else {
                row["resolved"] = false
            }
            return row
        case let .datumPoint(id):
            var row: [String: Any] = [
                "source_kind": "datumPoint",
                "point_id": id.raw.uuidString,
            ]
            if let record = document.session.document.datumPoints.first(where: { $0.id == id }) {
                row["name"] = record.name
                row["point_world"] = [record.position.x, record.position.y, record.position.z]
                row["resolved"] = document.session.lastReferenceErrors[.datumPoint(id)] == nil
            } else {
                row["resolved"] = false
            }
            return row
        }
    }

    private static func anchorRow(_ ref: SketchAnchorRef, document: FloeCADDocument) -> [String: Any] {
        var row: [String: Any] = ["sketch_id": ref.sketchID.raw.uuidString,
                                  "entity_id": ref.entityID.uuidString,
                                  "role": ref.role.rawValue, "unit": "mm"]
        guard let sketch = document.session.document.sketches.first(where: { $0.id == ref.sketchID }) else {
            row["resolved"] = false
            row["error"] = "missing_sketch"
            return row
        }
        row["sketch_name"] = sketch.name
        guard let entity = sketch.entities.first(where: { $0.id == ref.entityID }) else {
            row["resolved"] = false
            row["error"] = "missing_entity"
            return row
        }
        guard let local = entity.anchorPoint(for: ref.role) else {
            row["resolved"] = false
            row["error"] = "unsupported_anchor_role"
            return row
        }
        let world = sketch.plane.toWorld(local)
        row["point_local"] = [local.x, local.y]
        row["point_world"] = [world.x, world.y, world.z]
        row["resolved"] = true
        return row
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
        cylindricalIndices: Set<Int> = [],
        acquired: (version: GeometryVersionRef, snapshot: GeometryVersionSnapshot)?) -> [Int: [String: Any]] {
        guard document.session.writeBlock == nil, document.session.lastNamingRevisions[body.id] == body.meshRevision,
              let liveNames = document.session.lastKernelNames[body.id] else { return [:] }
        var liveCounts: [ElementName: Int] = [:]
        for name in liveNames.values { liveCounts[name, default: 0] += 1 }
        var snapshotIndices: [ElementName: [Int]] = [:]
        var snapshotPlanarIndices: Set<Int> = []
        var snapshotCylindricalIndices: Set<Int> = []
        if let acquired {
            for (index, name) in acquired.snapshot.kernelNames { snapshotIndices[name, default: []].append(index) }
            if let brep = acquired.snapshot.body.brep {
                for face in OCCTKernel.faceInfo(brep) {
                    guard face.area.isFinite, face.area > 0,
                          let signature = face.signature else { continue }
                    switch signature.kind {
                    case .planar: snapshotPlanarIndices.insert(face.index)
                    case .cylindrical: snapshotCylindricalIndices.insert(face.index)
                    }
                }
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
                    row["datum_actions"] = ["datum.offsetPlane.create", "datum.anglePlane.create"]
                    row["face_index_space"] = "occt_kernel_1_based"
                } else if cylindricalIndices.contains(index),
                          let matched = snapshotIndices[name], matched.count == 1,
                          snapshotCylindricalIndices.contains(matched[0]) {
                    // M08 R2: a cylindrical face is a valid CONSTRUCTION AXIS
                    // source (its analytic axis), not a plane source. The
                    // action says exactly which, so a caller cannot send a
                    // cylinder index to a face-plane action.
                    row["datum_source_supported"] = true
                    row["source_body_id"] = acquired.version.bodyID.raw.uuidString
                    row["datum_action"] = "datum.axis.create"
                    row["datum_actions"] = ["datum.axis.create"]
                    row["datum_axis_kind"] = "cylinder"
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
/// Field-only adapter; changing an axis's display length never replaces its
/// definition or other fields installed by earlier commands in the same
/// transaction (the same contract as `SetDatumSizeCommand`).
private struct SetAxisLengthCommand: DocumentCommand {
    let title = "Resize Construction Axis"
    let axisID: ConstructionAxisID
    let before: Double
    let after: Double

    private func set(_ value: Double, in document: inout DesignDocument) {
        guard let index = document.axes.firstIndex(where: { $0.id == axisID }) else { return }
        document.axes[index].length = value
    }
    func apply(to document: inout DesignDocument) { set(after, in: &document) }
    func revert(in document: inout DesignDocument) { set(before, in: &document) }
}

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
