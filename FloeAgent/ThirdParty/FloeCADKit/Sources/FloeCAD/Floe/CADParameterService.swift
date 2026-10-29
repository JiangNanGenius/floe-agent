//
//  CADParameterService.swift
//  FloeCADKit
//
//  Typed feature-parameter introspection and atomic editing for the native
//  document. This is the same graph/undo/save authority the History panel and
//  the typed `feature.*` vocabulary use; it does not add a second model.
//
//  Units are explicit in every descriptor: distances/thickness/radius are mm,
//  angles are degrees (the graph stores degrees for revolve/draft/rotate and
//  radians only for PatternSpec.totalAngle, which is exposed as degrees here).
//
//  An update is ONE undo step. If the rebuild introduces a new FeatureError,
//  the service rolls the edit back and returns the errors, so a parameter edit
//  never leaves a half-broken graph that the caller believes succeeded.
//

import Foundation
import simd

nonisolated struct CADParameterEditError: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

@MainActor
public final class CADParameterService {
    public static let actions: [String] = ["list", "update", "updateSketchEntity", "undo", "redo"]

    private let document: FloeCADDocument

    public init(document: FloeCADDocument) {
        self.document = document
    }

    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        if let failure = revisionPinFailure(args) { return failure }
        switch action {
        case "list": return list(args)
        case "update": return update(args)
        case "updateSketchEntity": return updateSketchEntity(args)
        case "undo": return undo(args)
        case "redo": return redo(args)
        default:
            return Self.fail("unknown_action",
                             "Unknown parameter action '\(action)'. Use "
                                + Self.actions.joined(separator: ", ") + ".")
        }
    }

    private func revisionPinFailure(_ args: [String: Any]) -> [String: Any]? {
        guard let raw = args["revision"] ?? args["expected_revision"] else { return nil }
        let value: Int64
        if let raw = raw as? Int64 { value = raw }
        else if let raw = raw as? Int { value = Int64(raw) }
        else if let raw = raw as? NSNumber { value = raw.int64Value }
        else if let raw = raw as? String, let parsed = Int64(raw) { value = parsed }
        else { return Self.fail("bad_revision", "revision must be an integer.") }
        guard value == Int64(document.revision) else {
            return Self.fail(
                "revision_mismatch",
                "The document is at revision \(document.revision), not the requested "
                    + "\(value). Re-read it before this parameter action.")
        }
        return nil
    }

    // MARK: - Read

    private func list(_ args: [String: Any]) -> [String: Any] {
        var rows = document.session.document.features.nodes.map {
            Self.describe($0, document: document.session.document)
        }
        if let raw = CADMaterialService.string(args["feature_id"]) ?? CADMaterialService.string(args["id"]),
           let uuid = UUID(uuidString: raw) {
            rows = rows.filter { ($0["id"] as? String) == uuid.uuidString }
        }
        return Self.ok([
            "action": "list",
            "actions": Self.actions,
            "features": rows,
            "count": rows.count,
            // The typed existing-sketch edit is discoverable from the SAME
            // service that applies it: entity ids and the current radius come
            // from query kind=sketches (rows[].entityRows).
            "sketch_entity_update": [
                "supported_entity_kinds": ["circle"],
                "fields": ["sketch_id", "entity_id", "radius", "expected_radius"],
                "unit": "mm",
                "discover": "query kind=sketches -> rows[].entityRows",
            ],
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    // MARK: - Update

    private func update(_ args: [String: Any]) -> [String: Any] {
        guard let raw = CADMaterialService.string(args["feature_id"]) ?? CADMaterialService.string(args["id"]),
              let uuid = UUID(uuidString: raw) else {
            return Self.fail("missing_feature", "update needs feature_id (UUID from query kind=features).")
        }
        let featureID = FeatureID(raw: uuid)
        guard let node = document.session.document.features.node(featureID) else {
            return Self.fail("unknown_feature", "No feature \(raw) in this document.")
        }
        guard let changes = args["changes"] as? [String: Any], !changes.isEmpty else {
            return Self.fail("missing_changes",
                             "update needs changes: an object of parameter -> value (units per the feature descriptor).")
        }
        let edited: FeatureKind
        switch Self.updated(node.kind, changes: changes) {
        case .failure(let error):
            return Self.fail("bad_parameter", error.message)
        case .success(let kind):
            edited = kind
        }
        let beforeErrors = document.session.lastEvalErrors
        let beforeChangeCount = document.session.changeCount
        let checkpoint = document.captureEditCheckpoint()

        if case let .pattern(_, spec) = edited {
            document.session.editPatternFeature(featureID, spec: spec)
        } else {
            document.session.editFeature(featureID, to: edited)
        }
        let afterErrors = document.session.lastEvalErrors
        let introduced = afterErrors.filter { id, error in
            guard let old = beforeErrors[id] else { return true }
            return String(describing: old) != String(describing: error)
        }
        if !introduced.isEmpty {
            // Restore the exact document + undo/redo histories. A plain undo
            // would move the rejected edit into redoCommands, making the
            // invalid parameter change redoable and destroying prior redo.
            if document.session.changeCount != beforeChangeCount {
                document.restoreEditCheckpoint(checkpoint)
            }
            let details = introduced.map { id, error -> [String: Any] in
                ["feature_id": id.raw.uuidString,
                 "feature": document.session.document.features.node(id)?.name ?? id.raw.uuidString,
                 "error": String(describing: error)]
            }
            return [
                "ok": false,
                "error": "rebuild_failed",
                "message": "The parameter edit broke the rebuild; it was rolled back (nothing was kept).",
                "rolled_back": true,
                "errors": details,
                "revision": document.revision,
                "change_count": document.session.changeCount,
            ]
        }
        let changed = document.session.changeCount != beforeChangeCount
        let descriptor = document.session.document.features.node(featureID).map {
            Self.describe($0, document: document.session.document)
        } ?? [:]
        return Self.ok([
            "action": "update",
            "mutated": changed,
            "feature": descriptor,
            "applied_changes": changes,
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    // MARK: - Existing-sketch geometry

    /// Change one existing circle's radius by its stable entity id and rebuild
    /// every dependent feature in the SAME undo step. This is the supported
    /// route for editing an existing hole diameter: the diameter lives on the
    /// sketch circle that owns the cut profile, while the extrude feature only
    /// exposes distance/symmetric. The original ProfileRef dependencies stay
    /// intact — the graph is not edited, its sketch input is.
    ///
    /// `expected_radius` is an optional optimistic fence: pass the radius the
    /// query returned and a concurrent/other-window radius change is refused
    /// as `radius_mismatch` instead of being overwritten. The whole edit is
    /// checkpointed, so a rebuild that introduces a new FeatureError restores
    /// the document and BOTH undo/redo histories (the rejected edit does not
    /// become redoable).
    private func updateSketchEntity(_ args: [String: Any]) -> [String: Any] {
        // Refuse a mistyped field instead of silently dropping a safety fence
        // (for example `expectedRadius` must not turn into an unchecked edit).
        let allowed: Set<String> = [
            "action", "revision", "expected_revision",
            "sketch_id", "sketchID", "sketch",
            "entity_id", "entityID", "id",
            "radius", "expected_radius", "current_radius",
        ]
        let unknown = args.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            return Self.fail("unknown_argument",
                             "Unknown argument(s) \(unknown.joined(separator: ", ")). Allowed: "
                                + allowed.sorted().joined(separator: ", ") + ".")
        }
        guard let rawSketch = CADMaterialService.string(args["sketch_id"])
            ?? CADMaterialService.string(args["sketchID"])
            ?? CADMaterialService.string(args["sketch"]),
              let sketchUUID = UUID(uuidString: rawSketch) else {
            return Self.fail("missing_sketch",
                             "updateSketchEntity needs sketch_id (the UUID query kind=sketches returned).")
        }
        let sketchID = SketchID(raw: sketchUUID)
        guard let sketch = document.session.document.sketches.first(where: { $0.id == sketchID }) else {
            return Self.fail("unknown_sketch",
                             "No sketch \(rawSketch) in this document. Query kind=sketches first.")
        }
        guard let rawEntity = CADMaterialService.string(args["entity_id"])
            ?? CADMaterialService.string(args["entityID"])
            ?? CADMaterialService.string(args["id"]),
              let entityUUID = UUID(uuidString: rawEntity) else {
            return Self.fail("missing_entity",
                             "updateSketchEntity needs entity_id (the circle id query kind=sketches returned).")
        }
        guard let entityIndex = sketch.entities.firstIndex(where: { $0.id == entityUUID }) else {
            return Self.fail("unknown_entity",
                             "Sketch '\(sketch.name)' has no entity \(rawEntity). Query kind=sketches first.")
        }
        guard case let .circle(_, center, currentRadius) = sketch.entities[entityIndex] else {
            return Self.fail(
                "unsupported_entity",
                "updateSketchEntity currently edits a circle's radius only; entity \(rawEntity) is not a circle. "
                    + "Change other sketch geometry with the sketch tools, then rebuild.")
        }
        guard let rawRadius = args["radius"],
              let newRadius = CADMaterialService.number(rawRadius), newRadius.isFinite else {
            return Self.fail("bad_radius", "radius must be a finite millimetre value.")
        }
        guard newRadius > 1e-6 else {
            return Self.fail("bad_radius", "radius must be greater than 0 mm.")
        }
        if let rawExpected = args["expected_radius"] ?? args["current_radius"] {
            guard let expected = CADMaterialService.number(rawExpected), expected.isFinite else {
                return Self.fail("bad_expected_radius",
                                 "expected_radius must be the finite current radius from query kind=sketches.")
            }
            guard abs(expected - currentRadius) <= 1e-6 else {
                return Self.fail(
                    "radius_mismatch",
                    "The circle \(rawEntity) is currently \(currentRadius) mm, not the expected "
                        + "\(expected) mm. Re-query kind=sketches before editing it.")
            }
        }
        guard abs(newRadius - currentRadius) > 1e-9 else {
            return Self.fail("no_change",
                             "The circle \(rawEntity) already has radius \(currentRadius) mm.")
        }

        let before = sketch.entities[entityIndex]
        let after = SketchEntity.circle(id: entityUUID, center: center, radius: newRadius)
        // ONE composite: the sketch edit + every dependent feature rebuild are
        // one undo step, exactly as the interactive sketch tools commit.
        let beforeErrors = document.session.lastEvalErrors
        let beforeChangeCount = document.session.changeCount
        let checkpoint = document.captureEditCheckpoint()
        document.session.performWithSketchRebuild(
            UpdateSketchEntityCommand(title: "Edit Circle Radius",
                                      sketchID: sketchID, before: before, after: after),
            sketchID: sketchID)
        let afterErrors = document.session.lastEvalErrors
        let introduced = afterErrors.filter { id, error in
            guard let old = beforeErrors[id] else { return true }
            return String(describing: old) != String(describing: error)
        }
        if !introduced.isEmpty {
            // Restore the exact document + undo/redo histories. A plain undo
            // would move the rejected edit into redoCommands, making the
            // invalid geometry redoable and destroying prior redo.
            if document.session.changeCount != beforeChangeCount {
                document.restoreEditCheckpoint(checkpoint)
            }
            let details = introduced.map { id, error -> [String: Any] in
                ["feature_id": id.raw.uuidString,
                 "feature": document.session.document.features.node(id)?.name ?? id.raw.uuidString,
                 "error": String(describing: error)]
            }
            return [
                "ok": false,
                "error": "rebuild_failed",
                "message": "The sketch edit broke the rebuild; it was rolled back (nothing was kept).",
                "rolled_back": true,
                "errors": details,
                "revision": document.revision,
                "change_count": document.session.changeCount,
            ]
        }
        guard document.session.changeCount != beforeChangeCount else {
            return Self.fail("no_change", "The sketch edit produced no document change.")
        }
        let dependents = document.session.document.features.nodes
            .filter { $0.referencedSketchIDs.contains(sketchID) }
            .map { $0.id.raw.uuidString }
        return Self.ok([
            "action": "updateSketchEntity",
            "mutated": true,
            "sketch": ["id": sketchID.raw.uuidString, "name": sketch.name],
            "entity": [
                "id": entityUUID.uuidString,
                "kind": "circle",
                "center": [center.x, center.y],
                "old_radius": currentRadius,
                "radius": newRadius,
                "diameter": newRadius * 2,
                "unit": "mm",
            ],
            "applied_changes": ["radius": newRadius],
            "dependent_feature_ids": dependents,
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    private func undo(_ args: [String: Any]) -> [String: Any] {
        guard document.session.undoStack.canUndo else {
            return Self.fail("nothing_to_undo", "The document undo stack is empty.")
        }
        document.session.undo()
        return Self.ok([
            "action": "undo", "mutated": true,
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    private func redo(_ args: [String: Any]) -> [String: Any] {
        guard document.session.undoStack.canRedo else {
            return Self.fail("nothing_to_redo", "The document redo stack is empty.")
        }
        document.session.redo()
        return Self.ok([
            "action": "redo", "mutated": true,
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    // MARK: - Descriptors

    static func describe(_ node: FeatureNode, document: DesignDocument) -> [String: Any] {
        var parameters: [[String: Any]] = []
        var unit: String? = nil
        var kindName = "unknown"

        func add(_ name: String, _ unit: String?, _ value: Any,
                 minimum: Double? = nil, maximum: Double? = nil,
                 editable: Bool = true, note: String? = nil) {
            var row: [String: Any] = [
                "name": name,
                "unit": unit ?? "unitless",
                "value": value,
                "editable": editable,
            ]
            if let minimum { row["min"] = minimum }
            if let maximum { row["max"] = maximum }
            if let note { row["note"] = note }
            parameters.append(row)
        }

        func vector(_ name: String, _ value: SIMD3<Double>, _ unit: String?) {
            add(name, unit, [value.x, value.y, value.z])
        }

        switch node.kind {
        case let .primitive(spec, placement):
            kindName = "primitive"
            switch spec {
            case let .box(width, depth, height):
                add("width", "mm", width, minimum: 1e-6)
                add("depth", "mm", depth, minimum: 1e-6)
                add("height", "mm", height, minimum: 1e-6)
            case let .cylinder(radius, height):
                add("radius", "mm", radius, minimum: 1e-6)
                add("height", "mm", height, minimum: 1e-6)
            case let .sphere(radius):
                add("radius", "mm", radius, minimum: 1e-6)
            }
            vector("placement_translation", placement.translation, "mm")
            add("placement_scale", "unitless", placement.scale, minimum: 1e-6)
            unit = "mm"
        case let .extrude(_, _, distance, symmetric, _, _):
            kindName = "extrude"
            add("distance", "mm", distance.value)
            add("symmetric", "unitless", symmetric)
            if let formula = distance.formula { add("distance_formula", "unitless", formula, editable: false) }
            unit = "mm"
        case let .draftExtrude(_, _, distance, taperAngle, symmetric, _):
            kindName = "draftExtrude"
            add("distance", "mm", distance.value)
            add("taper_angle", "deg", taperAngle.value, minimum: -89, maximum: 89)
            add("symmetric", "unitless", symmetric)
            unit = "mm"
        case let .revolve(_, _, _, angle, _):
            kindName = "revolve"
            add("angle", "deg", angle.value, minimum: 0.0001, maximum: 360)
            unit = "deg"
        case let .sweep(_, _, spine, _, helix):
            kindName = "sweep"
            add("spine_points", "mm", spine.map { [$0.point.x, $0.point.y, $0.point.z] }, editable: false)
            if let helix {
                add("helix_radius", "mm", helix.radius, editable: false)
                add("helix_pitch", "mm", helix.pitch, editable: false)
                add("helix_turns", "unitless", helix.turns, editable: false)
            }
        case let .loft(sections, _):
            kindName = "loft"
            add("section_count", "unitless", sections.count, editable: false)
        case let .boolean(kind, _, tools):
            kindName = "boolean"
            add("boolean_kind", "unitless", String(describing: kind), editable: false)
            add("tool_count", "unitless", tools.count, editable: false)
        case let .transform(_, delta):
            kindName = "transform"
            vector("translation", delta.translation, "mm")
            add("scale", "unitless", delta.scale, editable: false)
        case let .mirror(_, _, keepOriginal):
            kindName = "mirror"
            add("keep_original", "unitless", keepOriginal, editable: false)
        case let .pattern(_, spec):
            kindName = "pattern"
            add("count", "unitless", spec.count, minimum: 1, maximum: 10_000)
            add("spacing", "mm", spec.spacing, minimum: 0)
            add("total_angle", "deg", spec.totalAngle * 180 / .pi, minimum: 0, maximum: 360)
            add("rotate_instances", "unitless", spec.rotateInstances)
            vector("axis", spec.axis, "unitless")
            vector("center", spec.center, "mm")
        case let .pushPull(_, distance, _):
            kindName = "pushPull"
            add("distance", "mm", distance.value)
            unit = "mm"
        case let .moveFace(_, delta):
            kindName = "moveFace"
            vector("delta_face_basis", delta.point, "mm")
        case let .scaleFace(_, factor):
            kindName = "scaleFace"
            add("factor", "unitless", factor.value, minimum: 1e-6)
        case let .rotateFace(_, angle, _):
            kindName = "rotateFace"
            add("angle", "deg", angle.value)
            unit = "deg"
        case let .draftFace(_, _, _, angle):
            kindName = "draftFace"
            add("angle", "deg", angle.value, minimum: -89, maximum: 89)
            unit = "deg"
        case let .chamfer(_, edges, setback):
            kindName = "chamfer"
            add("setback", "mm", setback.value, minimum: 1e-6)
            add("edge_count", "unitless", edges.count, editable: false)
            unit = "mm"
        case let .fillet(_, edges, radius):
            kindName = "fillet"
            add("radius", "mm", radius.value, minimum: 1e-6)
            add("edge_count", "unitless", edges.count, editable: false)
            unit = "mm"
        case let .shell(_, openFaces, thickness):
            kindName = "shell"
            add("thickness", "mm", thickness.value)
            add("open_face_count", "unitless", openFaces.count, editable: false)
            unit = "mm"
        case let .deleteFace(_, faces):
            kindName = "deleteFace"
            add("face_count", "unitless", faces.count, editable: false)
        case let .replaceFace(_, _, _, flip):
            kindName = "replaceFace"
            add("flip", "unitless", flip, editable: false)
        }

        let sketchIDs = node.referencedSketchIDs.map(\.raw.uuidString).sorted()
        var featureDeps = Set<String>()
        var bodyDeps = Set<String>()
        for bodyRef in bodyReferences(in: node.kind) {
            featureDeps.insert(bodyRef.producer.raw.uuidString)
            bodyDeps.insert(bodyRef.bodyID.raw.uuidString)
        }
        for ref in faceReferences(in: node.kind) {
            featureDeps.insert(ref.body.producer.raw.uuidString)
            bodyDeps.insert(ref.body.bodyID.raw.uuidString)
        }
        for ref in edgeReferences(in: node.kind) {
            featureDeps.insert(ref.body.producer.raw.uuidString)
            bodyDeps.insert(ref.body.bodyID.raw.uuidString)
        }
        let updateSupported = Self.updateSupported(node.kind)
        var actions = ["feature.suppress", "feature.delete", "feature.move"]
        if updateSupported { actions.insert("parameter.update", at: 0) }
        var row: [String: Any] = [
            "id": node.id.raw.uuidString,
            "name": node.name,
            "kind": kindName,
            "suppressed": node.suppressed,
            "output_body_ids": node.outputBodyIDs.map(\.raw.uuidString),
            "parameters": parameters,
            "units": unit ?? "unitless",
            "dependencies": [
                "sketch_ids": sketchIDs,
                "feature_ids": featureDeps.sorted(),
                "body_ids": bodyDeps.union(node.outputBodyIDs.map(\.raw.uuidString)).sorted(),
            ],
            "actions": actions,
            "update_supported": updateSupported,
        ]
        if let data = try? JSONEncoder().encode(node.kind),
           let definition = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            row["definition"] = definition
        }
        if let rollback = document.features.rollbackIndex {
            row["rollback_index"] = rollback
        }
        return row
    }

    private static func updateSupported(_ kind: FeatureKind) -> Bool {
        switch kind {
        case .primitive, .extrude, .draftExtrude, .revolve, .pattern,
             .pushPull, .scaleFace, .rotateFace, .draftFace, .chamfer,
             .fillet, .shell:
            return true
        default:
            return false
        }
    }

    // MARK: - Reference extraction (descriptors)

    private static func bodyReferences(in kind: FeatureKind) -> [BodyRef] {
        switch kind {
        case let .boolean(_, target, tools): return [target] + tools
        case let .transform(body, _), let .mirror(body, _, _),
             let .pattern(body, _), let .chamfer(body, _, _),
             let .fillet(body, _, _), let .shell(body, _, _),
             let .deleteFace(body, _):
            return [body]
        case .primitive, .extrude, .draftExtrude, .revolve, .sweep, .loft,
             .pushPull, .moveFace, .scaleFace, .rotateFace, .draftFace, .replaceFace:
            return []
        }
    }

    private static func faceReferences(in kind: FeatureKind) -> [FaceRef] {
        switch kind {
        case let .pushPull(face, _, _), let .moveFace(face, _),
             let .scaleFace(face, _), let .rotateFace(face, _, _),
             let .draftFace(face, _, _, _), let .replaceFace(face, _, _, _):
            return [face]
        case let .shell(_, openFaces, _): return openFaces
        case let .deleteFace(_, faces): return faces
        default: return []
        }
    }

    private static func edgeReferences(in kind: FeatureKind) -> [EdgeRef] {
        switch kind {
        case let .chamfer(_, edges, _), let .fillet(_, edges, _): return edges
        default: return []
        }
    }

    // MARK: - Editing

    /// Map the documented parameter vocabulary onto the typed FeatureKind.
    /// Unknown names are a refusal (never a silent no-op), and every numeric
    /// value is validated against the same physical bounds the interactive
    /// tools use.
    static func updated(_ kind: FeatureKind,
                        changes: [String: Any]) -> Result<FeatureKind, CADParameterEditError> {
        var didChange = false
        func value(_ name: String) -> Double? {
            guard let raw = changes[name] else { return nil }
            if let number = CADMaterialService.number(raw), number.isFinite { return number }
            return nil
        }
        func boolValue(_ name: String) -> Bool? {
            CADMaterialService.bool(changes[name])
        }
        func fail(_ name: String, _ message: String) -> Result<FeatureKind, CADParameterEditError> {
            .failure(CADParameterEditError("\(name): \(message)"))
        }
        func unknown(_ allowed: [String]) -> Result<FeatureKind, CADParameterEditError> {
            let known = Set(allowed)
            let extra = changes.keys.filter { !known.contains($0) }.sorted()
            if !extra.isEmpty {
                return .failure(CADParameterEditError(
                    "Unknown parameter(s) \(extra.joined(separator: ", ")). "
                    + "Allowed: \(allowed.joined(separator: ", ")) (units as reported by query kind=features)."))
            }
            return .failure(CADParameterEditError("No supported parameter value changed."))
        }

        switch kind {
        case let .primitive(spec, placement):
            switch spec {
            case let .box(width, depth, height):
                let w = value("width") ?? width
                let d = value("depth") ?? depth
                let h = value("height") ?? height
                didChange = w != width || d != depth || h != height
                guard w > 1e-6, d > 1e-6, h > 1e-6 else {
                    return fail("primitive", "width/depth/height must be > 0 mm.")
                }
                return didChange ? .success(.primitive(spec: .box(width: w, depth: d, height: h),
                                                       placement: placement))
                    : unknown(["width", "depth", "height"])
            case let .cylinder(radius, height):
                let r = value("radius") ?? radius
                let h = value("height") ?? height
                didChange = r != radius || h != height
                guard r > 1e-6, h > 1e-6 else {
                    return fail("primitive", "radius/height must be > 0 mm.")
                }
                return didChange ? .success(.primitive(spec: .cylinder(radius: r, height: h),
                                                       placement: placement))
                    : unknown(["radius", "height"])
            case let .sphere(radius):
                let r = value("radius") ?? radius
                didChange = r != radius
                guard r > 1e-6 else { return fail("radius", "radius must be > 0 mm.") }
                return didChange ? .success(.primitive(spec: .sphere(radius: r), placement: placement))
                    : unknown(["radius"])
            }
        case let .extrude(profile, plane, distance, symmetric, boolean, extras):
            let d = value("distance")
            let s = boolValue("symmetric")
            guard !changes.keys.contains(where: { !["distance", "symmetric"].contains($0) }) else {
                return unknown(["distance", "symmetric"])
            }
            didChange = d != nil || s != nil
            guard didChange else { return unknown(["distance", "symmetric"]) }
            let newDistance = d.map { Expr(value: $0, formula: nil) } ?? distance
            guard newDistance.value.isFinite, abs(newDistance.value) > 1e-6 else {
                return fail("distance", "distance must be a non-zero finite mm value.")
            }
            return .success(.extrude(profile: profile, plane: plane, distance: newDistance,
                                     symmetric: s ?? symmetric, boolean: boolean,
                                     extraProfiles: extras))
        case let .draftExtrude(profile, plane, distance, taperAngle, symmetric, boolean):
            let d = value("distance")
            let t = value("taper_angle")
            let s = boolValue("symmetric")
            guard !changes.keys.contains(where: { !["distance", "taper_angle", "symmetric"].contains($0) }) else {
                return unknown(["distance", "taper_angle", "symmetric"])
            }
            didChange = d != nil || t != nil || s != nil
            guard didChange else { return unknown(["distance", "taper_angle", "symmetric"]) }
            let newDistance = d.map { Expr(value: $0, formula: nil) } ?? distance
            let newTaper = t.map { Expr(value: $0, formula: nil) } ?? taperAngle
            guard abs(newDistance.value) > 1e-6 else { return fail("distance", "distance must be non-zero mm.") }
            guard abs(newTaper.value) < 89, newTaper.value != 0 else {
                return fail("taper_angle", "taper_angle must be a non-zero angle with |angle| < 89°.")
            }
            return .success(.draftExtrude(profile: profile, plane: plane,
                                          distance: newDistance, taperAngle: newTaper,
                                          symmetric: s ?? symmetric, boolean: boolean))
        case let .revolve(profile, plane, axis, angle, boolean):
            guard changes.keys.allSatisfy({ $0 == "angle" }) else { return unknown(["angle"]) }
            guard let a = value("angle") else { return unknown(["angle"]) }
            guard a > 0.0001, a <= 360 else { return fail("angle", "angle must be in (0, 360] degrees.") }
            return .success(.revolve(profile: profile, plane: plane, axis: axis,
                                     angle: Expr(value: a, formula: nil), boolean: boolean))
        case let .pattern(body, spec):
            guard changes.keys.allSatisfy({
                ["count", "spacing", "total_angle", "rotate_instances"].contains($0)
            }) else { return unknown(["count", "spacing", "total_angle", "rotate_instances"]) }
            let count = value("count").map { Int($0.rounded()) } ?? spec.count
            let spacing = value("spacing") ?? spec.spacing
            let totalAngleDegrees = value("total_angle").map { $0 } ?? (spec.totalAngle * 180 / .pi)
            let rotate = boolValue("rotate_instances") ?? spec.rotateInstances
            didChange = count != spec.count || spacing != spec.spacing
                || abs(totalAngleDegrees - spec.totalAngle * 180 / .pi) > 1e-9
                || rotate != spec.rotateInstances
            guard didChange else {
                return unknown(["count", "spacing", "total_angle", "rotate_instances"])
            }
            guard count >= 1, count <= 10_000 else { return fail("count", "count must be 1…10000 (total instances).") }
            guard spacing.isFinite, spacing >= 0 else { return fail("spacing", "spacing must be >= 0 mm.") }
            guard totalAngleDegrees.isFinite, totalAngleDegrees >= 0, totalAngleDegrees <= 360 else {
                return fail("total_angle", "total_angle must be 0…360 degrees.")
            }
            var newSpec = spec
            newSpec.count = count
            newSpec.spacing = spacing
            newSpec.totalAngle = totalAngleDegrees * .pi / 180
            newSpec.rotateInstances = rotate
            return .success(.pattern(body: body, spec: newSpec))
        case let .pushPull(face, distance, mode):
            guard changes.keys.allSatisfy({ $0 == "distance" }) else { return unknown(["distance"]) }
            guard let d = value("distance"), abs(d) > 1e-6 else {
                return fail("distance", "distance must be a non-zero finite mm value.")
            }
            return .success(.pushPull(face: face, distance: Expr(value: d, formula: nil), mode: mode))
        case let .scaleFace(face, factor):
            guard changes.keys.allSatisfy({ $0 == "factor" }) else { return unknown(["factor"]) }
            guard let f = value("factor"), f > 1e-6 else { return fail("factor", "factor must be > 0.") }
            return .success(.scaleFace(face: face, factor: Expr(value: f, formula: nil)))
        case let .rotateFace(face, angle, axis):
            guard changes.keys.allSatisfy({ $0 == "angle" }) else { return unknown(["angle"]) }
            guard let a = value("angle"), a.isFinite else { return fail("angle", "angle must be finite degrees.") }
            return .success(.rotateFace(face: face, angle: Expr(value: a, formula: nil), axis: axis))
        case let .draftFace(face, origin, normal, angle):
            guard changes.keys.allSatisfy({ $0 == "angle" }) else { return unknown(["angle"]) }
            guard let a = value("angle"), abs(a) < 89, a != 0 else {
                return fail("angle", "angle must be non-zero with |angle| < 89 degrees.")
            }
            return .success(.draftFace(face: face, neutralOrigin: origin,
                                       neutralNormal: normal, angle: Expr(value: a, formula: nil)))
        case let .chamfer(body, edges, setback):
            guard changes.keys.allSatisfy({ $0 == "setback" }) else { return unknown(["setback"]) }
            guard let s = value("setback"), s > 1e-6 else { return fail("setback", "setback must be > 0 mm.") }
            return .success(.chamfer(body: body, edges: edges, setback: Expr(value: s, formula: nil)))
        case let .fillet(body, edges, radius):
            guard changes.keys.allSatisfy({ $0 == "radius" }) else { return unknown(["radius"]) }
            guard let r = value("radius"), r > 1e-6 else { return fail("radius", "radius must be > 0 mm.") }
            return .success(.fillet(body: body, edges: edges, radius: Expr(value: r, formula: nil)))
        case let .shell(body, openFaces, thickness):
            guard changes.keys.allSatisfy({ $0 == "thickness" }) else { return unknown(["thickness"]) }
            guard let t = value("thickness"), abs(t) > 1e-6 else {
                return fail("thickness", "thickness must be a non-zero mm wall.")
            }
            return .success(.shell(body: body, openFaces: openFaces,
                                   thickness: Expr(value: t, formula: nil)))
        default:
            return .failure(CADParameterEditError(
                "This feature kind has no editable numeric parameter; "
                + "use feature.suppress/delete/move or draft a new operation."))
        }
    }

    // MARK: - Reply helpers

    static func ok(_ object: [String: Any]) -> [String: Any] {
        var reply = object
        reply["ok"] = true
        return reply
    }

    static func fail(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "error": code, "message": message]
    }
}
