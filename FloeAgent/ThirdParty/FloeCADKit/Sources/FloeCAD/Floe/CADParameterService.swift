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
import CoreFoundation
import simd

nonisolated struct CADParameterEditError: Error, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
}

@MainActor
public final class CADParameterService {
    /// Every executable action. The feature actions are the SAME three names
    /// `query kind=features` advertises (`feature.suppress`,
    /// `feature.delete`, `feature.move`), so a discovered action is always
    /// executable instead of a model-facing suggestion that silently has no
    /// implementation.
    public static let actions: [String] = [
        "list", "update", "updateSketchEntity", "deleteSketchEntity",
        "setSketchDimension", "removeSketchDimension",
        "feature.suppress", "feature.delete", "feature.move",
        "variable.create", "variable.update", "variable.delete",
        "feature.setExpression",
        "undo", "redo",
    ] + CADDatumService.actions

    /// Sketch-entity kinds with a real typed geometry edit. Polygon remains
    /// query-only until its side/rotation semantics are promoted with the same
    /// constraint evidence as the other kind-specific edits.
    public static let editableSketchEntityKinds: Set<String> = [
        "line", "rect", "circle", "arc", "ellipse", "spline",
    ]

    /// Driving dimension kinds accepted by `setSketchDimension`. `length` is
    /// the model-facing name for a line's point-to-point `.distance`.
    public static let editableDimensionKinds: Set<String> = [
        "length", "distance", "angle", "diameter", "radius", "width", "height",
    ]

    private let document: FloeCADDocument

    public init(document: FloeCADDocument) {
        self.document = document
    }

    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        if let refusal = CADServiceOperations.readOnlyRefusal(document: document, kind: "parameter", action: action) { return refusal }
        if let failure = revisionPinFailure(args) { return failure }
        if CADDatumService.actions.contains(action) {
            return CADDatumService(document: document).handle(action: action, args: args)
        }
        switch action {
        case "list": return list(args)
        case "update": return update(args)
        case "updateSketchEntity": return updateSketchEntity(args)
        case "deleteSketchEntity": return deleteSketchEntity(args)
        case "setSketchDimension": return setSketchDimension(args)
        case "removeSketchDimension": return removeSketchDimension(args)
        case "feature.suppress": return featureSuppress(args)
        case "feature.delete": return featureDelete(args)
        case "feature.move": return featureMove(args)
        case "variable.create": return variableCreate(args)
        case "variable.update": return variableUpdate(args)
        case "variable.delete": return variableDelete(args)
        case "feature.setExpression": return featureSetExpression(args)
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
            // The typed existing-sketch edits are discoverable from the SAME
            // service that applies them: entity ids and current geometry come
            // from query kind=sketches (rows[].entityRows).
            "sketch_entity_update": [
                "action": "updateSketchEntity",
                "supported_entity_kinds": ["line", "rect", "circle", "arc", "ellipse", "spline"],
                "fields": [
                    "sketch_id", "entity_id",
                    "line: a, b (alias start, end) + expected_a, expected_b",
                    "rect: min, max, center, width, height + expected_min, expected_max, expected_width, expected_height",
                    "circle: center, radius, diameter + expected_radius, expected_diameter, expected_center",
                    "arc: center, radius, diameter, start_angle_deg, end_angle_deg, sweep_angle_deg",
                    "arc fences: expected_center, expected_radius, expected_start_angle_deg, expected_end_angle_deg, expected_sweep_angle_deg",
                    "ellipse: center, radius_x, radius_y, rotation_deg + expected_center, expected_radius_x, expected_radius_y, expected_rotation_deg",
                    "spline: points (all fit points) or point_index (0-based) + point; expected_points / expected_point",
                ],
                "unit": "mm",
                "angle_unit": "degrees (stored radians are converted once)",
                "constraints": "A direct geometry edit is REFUSED with constraint_conflict only when "
                    + "the saved dimensions/constraints cannot be satisfied with the requested fields "
                    + "held. A satisfiable edit re-solves with the existing solver and commits every "
                    + "RELATED geometry move in the same undo step; unrelated entities, ids and "
                    + "constraints stay untouched. Circle/arc radius/diameter, arc sweep and rectangle "
                    + "width/height update their matching driving dimensions in the same undo step; use "
                    + "setSketchDimension for other values.",
                "locked": "A .fixed (Lock) constraint on the edited entity refuses the edit with "
                    + "locked_entity because a fixed solver variable carries no target residual.",
                "unsupported_references": "If a constraint/dimension references geometry the solver "
                    + "cannot validate for this kind (for example tangent/equalRadius on an ellipse), "
                    + "the edit is refused with dependent_reference and the exact ids instead of "
                    + "dropping or silently ignoring the relationship.",
                "discover": "query kind=sketches -> rows[].entityRows[].update_fields",
            ],
            "sketch_entity_delete": [
                "action": "deleteSketchEntity",
                "fields": ["sketch_id", "entity_id"],
                "semantics": "Deletes exactly one entity by stable id in one undo step. Constraints/"
                    + "dimensions whose refs are ALL this entity are removed with it and listed. A "
                    + "reference that also anchors another entity refuses with shared_references "
                    + "unless remove_shared_references:true is explicit. A pattern link that owns "
                    + "the entity refuses unless remove_pattern_link:true; instances then stay as "
                    + "ordinary entities and keep their ids. Nothing else is cascaded.",
                "discover": "query kind=sketches -> rows[].entityRows[].id",
            ],
            "sketch_dimension_update": [
                "action": "setSketchDimension",
                "supported_kinds": ["length", "distance", "angle", "diameter", "radius", "width", "height"],
                "fields": [
                    "sketch_id", "entity_id (or entity_ids for an angle between two lines)",
                    "kind", "value", "expected_value", "dimension_id (optional existing dimension)",
                    "refs (optional explicit [{entity_id, role}])",
                ],
                "units": ["length": "mm", "distance": "mm", "radius": "mm",
                          "diameter": "mm", "width": "mm", "height": "mm", "angle": "degrees"],
                "remove": "removeSketchDimension {sketch_id, dimension_id}",
                "discover": "query kind=constraints -> rows[] (editable dimensions carry update_action)",
            ],
            "feature_actions": [
                "feature.suppress": "{feature_id, suppressed: true|false}",
                "feature.delete": "{feature_id, force?: true}",
                "feature.move": "{feature_id, to_index: 0-based history position}",
            ],
            "variable_actions": [
                "variable.create": "{name, expression}",
                "variable.update": "{variable_id, name?, expression?, expected_expression?}",
                "variable.delete": "{variable_id}",
            ],
            "datum_actions": [
                "datum.offsetPlane.create": "{body_id, face_index (OCCT kernel 1-based), query_token, expression, size?}",
                "datum.offsetPlane.update": "{plane_id, expression?, expected_expression?, size?, body_id? + face_index? + query_token? (all three for source reselect)}",
                "datum.offsetPlane.delete": "{plane_id}",
                "sketch.setSupport": "{sketch_id, plane_id}",
                "sketch.clearSupport": "{sketch_id}",
            ],
            "datum_planes": CADDatumService.planeRows(document: document),
            "expression_update": [
                "action": "feature.setExpression",
                "fields": ["feature_id", "parameter", "expression", "expected_expression?"],
                "units": "The expression is written in the parameter's PUBLIC unit from "
                    + "query kind=features: deg for angle, mm for lengths, unitless for a factor. "
                    + "A public degree expression bound to a radian-persisted parameter is "
                    + "converted explicitly (formula radians(...)); stored values never take "
                    + "degrees as radians. Query rows expose formula/formula_unit (exact stored "
                    + "source), source_expression/source_expression_unit only when the stored "
                    + "source can be inverted safely, and public_expression/"
                    + "public_expression_unit (derived=true when only an equivalent degree "
                    + "expression is available for a legacy radian formula).",
                "supported": "Only the formula-capable scalars query kind=features reports "
                    + "with expression_action=feature.setExpression; other parameters refuse "
                    + "unsupported_parameter instead of a value-only mutation.",
                "expected_expression": "Compare with the parameter's current exact stored "
                    + "`formula` from query kind=features (empty string means the parameter "
                    + "currently has no formula). For a radian-persisted angle this is the "
                    + "radian-valued source, NOT public_expression; a legacy arbitrary radian "
                    + "formula must be fenced by that exact text. A mismatch refuses and "
                    + "preserves the document and redo history.",
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
        // Hole edits validate the pilot relation before mutation; other kinds
        // pay no sketch-resolution cost here (the helper short-circuits).
        let edited: FeatureKind
        switch Self.updated(node.kind, changes: changes,
                            pilotDiameter: Self.placementPilotDiameter(
                                node, document: document.session.document)) {
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
            // The undo entry a user actually sees must name the operation.
            // "Edit Feature" stays the shared editor default; hole edits are
            // a distinct one-step mechanical operation.
            document.session.editFeature(featureID, to: edited,
                                         title: Self.editTitle(for: node.kind))
        }
        if let rejection = Self.rebuildRejection(document) { return rejection }
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

    /// One planned entity edit: the new entity plus the matching driving
    /// dimensions that must move with it (so the stored sketch stays
    /// internally consistent), the applied fields and the reply row.
    private struct SketchEntityEditPlan {
        var after: SketchEntity
        /// Solver slots the caller explicitly asked for. They are held during
        /// the connected solve; the rest of the primitive may follow related
        /// constraints like any other related geometry.
        var heldRefs: [ConstraintRef]
        var dimensionUpdates: [(before: SketchDimension, after: SketchDimension)]
        var applied: [String: Any]
        var response: [String: Any]
        var title: String
    }

    /// Change one existing sketch entity's real geometry by its stable entity
    /// id and rebuild every dependent feature in the SAME undo step.
    ///
    /// Supported typed edits:
    ///   * line: `a`/`b` endpoints (aliases `start`/`end`);
    ///   * rect: `min`/`max` bounds, or `center` + `width`/`height`;
    ///   * circle: `center`, `radius` and/or `diameter`;
    ///   * arc: `center`, `radius`/`diameter`, and `start_angle_deg`,
    ///     `end_angle_deg` and/or `sweep_angle_deg`;
    ///   * ellipse: `center`, `radius_x`, `radius_y` and/or `rotation_deg`;
    ///   * spline: all fit `points`, or `point_index` (0-based) + `point`.
    ///
    /// The edit is REFUSED (`constraint_conflict`) only when the saved driving
    /// dimensions and geometric constraints cannot be satisfied WITH the
    /// caller's requested fields held. A satisfiable edit re-solves through
    /// the existing sketch solver and commits every RELATED geometry move in
    /// the SAME undo step; unrelated entities, their ids and their constraints
    /// stay untouched. A matching single-entity driving value — a circle/arc
    /// radius or diameter, an arc sweep angle, a rectangle's width/height, a
    /// line's own length/horizontal/vertical — is updated in the same undo step
    /// instead of becoming stale. Other driving values are changed through
    /// `setSketchDimension`.
    ///
    /// Optional optimistic fences (`expected_radius`, `expected_center`,
    /// `expected_a`/`expected_b`, `expected_min`/`expected_max`,
    /// `expected_width`/`expected_height`, `expected_start_angle_deg`,
    /// `expected_end_angle_deg`, `expected_sweep_angle_deg`,
    /// `expected_radius_x`, `expected_radius_y`, `expected_rotation_deg`,
    /// `expected_points`, `expected_point`) compare against the current
    /// geometry and refuse a concurrent edit instead of overwriting it. The
    /// whole edit is checkpointed, so a rebuild that introduces a new
    /// FeatureError restores the document and BOTH undo/redo histories.
    private func updateSketchEntity(_ args: [String: Any]) -> [String: Any] {
        // Refuse a mistyped field instead of silently dropping a safety fence.
        let allowed: Set<String> = [
            "action", "revision", "expected_revision",
            "sketch_id", "sketchID", "sketch",
            "entity_id", "entityID", "id",
            "a", "b", "start", "end", "endpointA", "endpointB",
            "min", "max", "low", "high", "center", "width", "height",
            "radius", "diameter", "expected_radius", "current_radius",
            "expected_diameter", "expected_center", "expected_a", "expected_b",
            "expected_min", "expected_max", "expected_width", "expected_height",
            "start_angle_deg", "start_angle", "startAngleDegrees",
            "end_angle_deg", "end_angle", "endAngleDegrees",
            "sweep_angle_deg", "sweep_angle", "sweepAngleDegrees",
            "expected_start_angle_deg", "expected_end_angle_deg",
            "expected_sweep_angle_deg",
            "radius_x", "radius_y", "rotation_deg", "rotation",
            "expected_radius_x", "expected_radius_y", "expected_rotation_deg",
            "points", "point", "point_index", "expected_point", "expected_points",
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
                             "updateSketchEntity needs entity_id (the entity id query kind=sketches returned).")
        }
        guard let entityIndex = sketch.entities.firstIndex(where: { $0.id == entityUUID }) else {
            return Self.fail("unknown_entity",
                             "Sketch '\(sketch.name)' has no entity \(rawEntity). Query kind=sketches first.")
        }
        let before = sketch.entities[entityIndex]
        if let failure = Self.editReferenceFailure(
            entity: before, entityID: entityUUID, sketch: sketch) {
            return Self.fail(failure.code, failure.message)
        }
        let plan: SketchEntityEditPlan
        switch before {
        case let .line(_, a, b):
            switch Self.lineEditPlan(args: args, id: entityUUID, a: a, b: b,
                                     dimensions: sketch.dimensions) {
            case .success(let value): plan = value
            case .failure(let error): return Self.fail(error.code, error.message)
            }
        case let .rect(_, low, high):
            switch Self.rectEditPlan(args: args, id: entityUUID, low: low, high: high,
                                     dimensions: sketch.dimensions) {
            case .success(let value): plan = value
            case .failure(let error): return Self.fail(error.code, error.message)
            }
        case let .circle(_, center, radius):
            switch Self.circleEditPlan(args: args, id: entityUUID, center: center, radius: radius,
                                       dimensions: sketch.dimensions) {
            case .success(let value): plan = value
            case .failure(let error): return Self.fail(error.code, error.message)
            }
        case let .arc(_, center, radius, startAngle, endAngle):
            switch Self.arcEditPlan(
                args: args, id: entityUUID, center: center, radius: radius,
                startAngle: startAngle, endAngle: endAngle,
                dimensions: sketch.dimensions,
                endpointConnected: Self.arcIsEndpointConnected(entityUUID, in: sketch)) {
            case .success(let value): plan = value
            case .failure(let error): return Self.fail(error.code, error.message)
            }
        case let .ellipse(_, center, radiusX, radiusY, rotation):
            switch Self.ellipseEditPlan(
                args: args, id: entityUUID, center: center,
                radiusX: radiusX, radiusY: radiusY, rotation: rotation) {
            case .success(let value): plan = value
            case .failure(let error): return Self.fail(error.code, error.message)
            }
        case let .spline(_, points, closed):
            switch Self.splineEditPlan(
                args: args, id: entityUUID, points: points, closed: closed) {
            case .success(let value): plan = value
            case .failure(let error): return Self.fail(error.code, error.message)
            }
        default:
            return Self.fail(
                "unsupported_entity",
                "updateSketchEntity edits line, rect, circle, arc, ellipse and spline entities; entity "
                    + "\(rawEntity) is \(Self.entityKindName(before)). Its editable flag is false in "
                    + "query kind=sketches. Change polygon geometry with the sketch tools.")
        }

        if plan.after == before && plan.dimensionUpdates.isEmpty {
            return Self.fail("no_change",
                             "The \(Self.entityKindName(before)) edit did not change any geometry.")
        }
        // Apply the new entity plus every matching driving value to a preview,
        // then solve the saved system with the REQUESTED fields held. This
        // follows the ordinary parametric path (the interactive editor and
        // `setSketchDimension`): related geometry moves as the constraints
        // require, unrelated entities keep their ids/geometry, and only a
        // genuinely unsatisfiable system is refused. The transient anchor is
        // never stored; it covers only the fields the caller named on the
        // edited primitive, never every entity and never unrequested fields.
        var proposed = sketch
        proposed.entities[entityIndex] = plan.after
        for (beforeDimension, afterDimension) in plan.dimensionUpdates {
            guard let index = proposed.dimensions.firstIndex(where: { $0.id == beforeDimension.id }) else {
                return Self.fail("unknown_dimension",
                                 "The driving dimension \(beforeDimension.id.uuidString) disappeared during the edit.")
            }
            proposed.dimensions[index] = afterDimension
        }
        // Interior spline fit points are now genuine solver variables. Preserve
        // the same direct-edit contract as the endpoint refs: a full points
        // replacement holds every supplied index; point_index holds exactly the
        // changed index. These transient holds never enter the document.
        var heldSplinePointIndices: [Int] = []
        if case let .spline(_, afterPoints, closed) = plan.after, !closed {
            if args["points"] != nil {
                heldSplinePointIndices = Array(afterPoints.indices)
            } else if case let .spline(_, beforePoints, _) = before,
                      beforePoints.count == afterPoints.count {
                heldSplinePointIndices = afterPoints.indices.filter {
                    beforePoints[$0] != afterPoints[$0]
                }
            }
        }
        let entitiesToCommit: [SketchEntity]
        switch Self.solveEditedSketch(proposed, edited: plan.after, heldRefs: plan.heldRefs,
                                      heldSplinePointIndices: heldSplinePointIndices) {
        case .success(let value): entitiesToCommit = value
        case .failure(let error): return Self.fail(error.code, error.message)
        }
        let movedEntities = zip(sketch.entities, entitiesToCommit).compactMap { before, after in
            before == after ? nil : (before: before, after: after)
        }
        guard !movedEntities.isEmpty || !plan.dimensionUpdates.isEmpty else {
            return Self.fail("no_change",
                             "The \(Self.entityKindName(before)) edit produced no document change.")
        }
        let solvedEdited = entitiesToCommit.first(where: { $0.id == entityUUID }) ?? plan.after
        let actual = Self.applyingSolvedGeometry(solvedEdited, to: plan)

        let beforeErrors = document.session.lastEvalErrors
        let beforeChangeCount = document.session.changeCount
        let checkpoint = document.captureEditCheckpoint()
        var commands: [DocumentCommand] = []
        for change in movedEntities {
            commands.append(UpdateSketchEntityCommand(
                title: plan.title, sketchID: sketchID,
                before: change.before, after: change.after))
        }
        for (beforeDimension, afterDimension) in plan.dimensionUpdates {
            commands.append(UpdateSketchDimensionCommand(
                sketchID: sketchID, before: beforeDimension, after: afterDimension))
        }
        document.session.performWithSketchRebuild(
            commands.count == 1 ? commands[0]
                : CompositeCommand(title: plan.title, commands: commands),
            sketchID: sketchID)
        if let failure = Self.rollbackIfRebuildBroke(
            document: document, beforeErrors: beforeErrors,
            beforeChangeCount: beforeChangeCount, checkpoint: checkpoint,
            message: "The sketch edit broke the rebuild; it was rolled back (nothing was kept).") {
            return failure
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
            "entity": actual.response,
            "applied_changes": actual.applied,
            "updated_dimension_ids": plan.dimensionUpdates.map { $0.after.id.uuidString },
            "dependent_feature_ids": dependents,
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    // MARK: - Sketch entity delete

    /// Delete exactly ONE entity by stable id, with explicit reference
    /// ownership rather than a broad cascade:
    ///   * a constraint/dimension that references ONLY this entity is owned by
    ///     it and is removed in the SAME undo step (and reported);
    ///   * a reference that also anchors another entity is REFUSED with
    ///     `shared_references` unless the caller passes
    ///     `remove_shared_references:true` explicitly;
    ///   * a live pattern link owning the entity is refused with
    ///     `pattern_link_reference` unless `remove_pattern_link:true`; then
    ///     only the link is removed, and every instance/seed keeps its id.
    /// Unaffected entities, their ids and unrelated constraints are untouched.
    /// The same checkpoint/rebuild rollback as an edit applies.
    private func deleteSketchEntity(_ args: [String: Any]) -> [String: Any] {
        let allowed: Set<String> = [
            "action", "revision", "expected_revision",
            "sketch_id", "sketchID", "sketch",
            "entity_id", "entityID", "id",
            "remove_shared_references", "remove_pattern_link",
        ]
        let unknown = args.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            return Self.fail("unknown_argument",
                             "Unknown argument(s) \(unknown.joined(separator: ", ")). Allowed: "
                                + allowed.sorted().joined(separator: ", ") + ".")
        }
        func optIn(_ key: String) -> Bool? {
            guard let raw = args[key] else { return false }
            // NSNumber bridges 1 to Bool; require the JSON/CF boolean type so
            // a numeric flag cannot silently opt into a reference cascade.
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            return number.boolValue
        }
        guard let removeShared = optIn("remove_shared_references") else {
            return Self.fail("bad_boolean", "remove_shared_references must be true or false.")
        }
        guard let removePatternLink = optIn("remove_pattern_link") else {
            return Self.fail("bad_boolean", "remove_pattern_link must be true or false.")
        }
        guard let rawSketch = CADMaterialService.string(args["sketch_id"])
            ?? CADMaterialService.string(args["sketchID"])
            ?? CADMaterialService.string(args["sketch"]),
              let sketchUUID = UUID(uuidString: rawSketch) else {
            return Self.fail("missing_sketch",
                             "deleteSketchEntity needs sketch_id (the UUID query kind=sketches returned).")
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
                             "deleteSketchEntity needs entity_id (the entity id query kind=sketches returned).")
        }
        guard let entity = sketch.entities.first(where: { $0.id == entityUUID }) else {
            return Self.fail("unknown_entity",
                             "Sketch '\(sketch.name)' has no entity \(rawEntity). Query kind=sketches first.")
        }
        let kind = Self.entityKindName(entity)
        let constraints = sketch.constraints.filter {
            $0.refs.contains { $0.entityID == entityUUID }
        }
        let dimensions = sketch.dimensions.filter {
            $0.refs.contains { $0.entityID == entityUUID }
        }
        func otherEntities(_ refs: [ConstraintRef]) -> [String] {
            Set(refs.compactMap {
                $0.entityID == entityUUID ? nil : $0.entityID.uuidString
            }).sorted()
        }
        let sharedConstraints = constraints.filter {
            $0.refs.contains { $0.entityID != entityUUID }
        }
        let sharedDimensions = dimensions.filter {
            $0.refs.contains { $0.entityID != entityUUID }
        }
        if (!sharedConstraints.isEmpty || !sharedDimensions.isEmpty) && !removeShared {
            var rows: [[String: Any]] = []
            for constraint in sharedConstraints {
                let refs = constraint.refs.filter { $0.entityID == entityUUID }
                rows.append([
                    "type": "constraint", "id": constraint.id.uuidString,
                    "kind": constraint.kind.rawValue,
                    "roles": refs.map { $0.role.rawValue },
                    "also_anchors": otherEntities(constraint.refs),
                ])
            }
            for dimension in sharedDimensions {
                let refs = dimension.refs.filter { $0.entityID == entityUUID }
                rows.append([
                    "type": "dimension", "id": dimension.id.uuidString,
                    "kind": dimension.kind.rawValue,
                    "roles": refs.map { $0.role.rawValue },
                    "also_anchors": otherEntities(dimension.refs),
                ])
            }
            return Self.fail(
                "shared_references",
                "Deleting this \(kind) would also remove references that anchor other entities: "
                    + rows.map { "\($0["type"] as? String ?? "ref") \($0["id"] as? String ?? "")"
                        + "(\($0["kind"] as? String ?? ""))" }.joined(separator: ", ")
                    + ". Nothing was changed. Delete or rebind those references first, or pass "
                    + "remove_shared_references:true to remove exactly them with this entity.",
                extra: ["references": rows])
        }

        let patternLinkIndex = sketch.patternLinks.firstIndex {
            $0.seedIDs.contains(entityUUID) || $0.allInstanceIDs.contains(entityUUID)
        }
        if let patternLinkIndex, !removePatternLink {
            let link = sketch.patternLinks[patternLinkIndex]
            return Self.fail(
                "pattern_link_reference",
                "This \(kind) belongs to pattern link \(link.id.uuidString) (seeds "
                    + link.seedIDs.map(\.uuidString).joined(separator: ", ")
                    + "). Nothing was changed. Pass remove_pattern_link:true to detach the link; "
                    + "all seeds/instances then stay as ordinary entities with their ids.",
                extra: ["pattern_link_id": link.id.uuidString])
        }

        let beforeErrors = document.session.lastEvalErrors
        let beforeChangeCount = document.session.changeCount
        let checkpoint = document.captureEditCheckpoint()
        let title = "Delete \(kind.capitalized)"
        var commands: [DocumentCommand] = [
            RemoveSketchEntitiesCommand(ids: [entityUUID], sketch: sketch)
        ]
        var removedPatternLink: String?
        if let patternLinkIndex, removePatternLink {
            let link = sketch.patternLinks[patternLinkIndex]
            removedPatternLink = link.id.uuidString
            commands.append(RemoveSketchPatternLinkCommand(
                sketchID: sketchID, link: link, index: patternLinkIndex))
        }
        document.session.performWithSketchRebuild(
            commands.count == 1 ? commands[0]
                : CompositeCommand(title: title, commands: commands),
            sketchID: sketchID)
        if let failure = Self.rollbackIfRebuildBroke(
            document: document, beforeErrors: beforeErrors,
            beforeChangeCount: beforeChangeCount, checkpoint: checkpoint,
            message: "Deleting the sketch entity broke the rebuild; it was rolled back (nothing was kept).") {
            return failure
        }
        guard document.session.changeCount != beforeChangeCount else {
            return Self.fail("no_change", "Deleting the sketch entity produced no document change.")
        }
        let dependents = document.session.document.features.nodes
            .filter { $0.referencedSketchIDs.contains(sketchID) }
            .map { $0.id.raw.uuidString }
        return Self.ok([
            "action": "deleteSketchEntity",
            "mutated": true,
            "sketch": ["id": sketchID.raw.uuidString, "name": sketch.name],
            "deleted_entity": ["id": entityUUID.uuidString, "kind": kind],
            "removed_reference_ids": (constraints.map(\.id) + dimensions.map(\.id))
                .map(\.uuidString).sorted(),
            "removed_dimensions": dimensions.map {
                ["id": $0.id.uuidString, "kind": $0.kind.rawValue]
            },
            "removed_constraints": constraints.map {
                ["id": $0.id.uuidString, "kind": $0.kind.rawValue]
            },
            "shared_references_removed": !sharedConstraints.isEmpty || !sharedDimensions.isEmpty,
            "pattern_link_removed": removedPatternLink.map { $0 as Any } ?? NSNull(),
            "dependent_feature_ids": dependents,
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    // MARK: - Sketch entity edit planning

    private struct SketchEditFailure: Error, Equatable {
        var code: String
        var message: String
    }

    private static func entityKindName(_ entity: SketchEntity) -> String {
        switch entity {
        case .line: "line"
        case .rect: "rect"
        case .circle: "circle"
        case .arc: "arc"
        case .ellipse: "ellipse"
        case .polygon: "polygon"
        case .spline: "spline"
        }
    }

    /// Refuse an edit whose saved relationships cannot actually be validated
    /// by the solver for this entity kind. A `.fixed` (Lock) is a target-less
    /// solver fence: rebuilding from the PROPOSED geometry would silently
    /// re-lock the new values, so it must be an explicit refusal. Other
    /// relationships are refused only when their reference role/kind is
    /// unsupported for the edited primitive (for example a tangent on an
    /// ellipse, or any reference to a closed spline) — never silently dropped.
    private static func editReferenceFailure(
        entity: SketchEntity, entityID: UUID, sketch: Sketch
    ) -> SketchEditFailure? {
        func references(_ refs: [ConstraintRef]) -> [ConstraintRef] {
            refs.filter { $0.entityID == entityID }
        }
        let constraints = sketch.constraints.filter { !references($0.refs).isEmpty }
        let dimensions = sketch.dimensions.filter { !references($0.refs).isEmpty }
        let kind = entityKindName(entity)

        let fixed = constraints.filter { $0.kind == .fixed }
        if !fixed.isEmpty {
            return SketchEditFailure(
                code: "locked_entity",
                message: "The \(kind) \(entityID.uuidString) is locked by fixed constraint(s) "
                    + fixed.map(\.id.uuidString).joined(separator: ", ")
                    + ". Nothing was changed. Remove the Lock explicitly in the sketch, then retry.")
        }

        func detail(_ id: UUID, _ name: String, _ refs: [ConstraintRef],
                    in allRefs: [ConstraintRef]) -> String {
            let others = Set(allRefs.compactMap { $0.entityID == entityID ? nil : $0.entityID.uuidString }).sorted()
            let roles = Set(refs.map { $0.role.rawValue }).sorted().joined(separator: "+")
            var text = "\(id.uuidString)(\(name), refs=\(roles)"
            if !others.isEmpty { text += ", also anchors " + others.joined(separator: ",") }
            return text + ")"
        }
        var unsupported: [String] = []
        for constraint in constraints {
            let refs = references(constraint.refs)
            let rejected: Bool
            switch entity {
            case .arc:
                // M02: connected arcs solve their endpoints. Endpoint refs are
                // editable for exactly the constraint vocabulary the solver
                // truthfully lowers with arc endpoints — connection (coincident
                // weld), junction tangency, and Lock. Chord-based relations
                // (parallel/perpendicular/equal-length/concentric) stay refused:
                // an arc's chord is not its direction.
                if refs.contains(where: { $0.role == .endpointA || $0.role == .endpointB }) {
                    switch constraint.kind {
                    case .coincident:
                        // R1 review: allow only counterparts the bridge
                        // truthfully lowers — another point role, or the whole
                        // of a line-like entity (a `linePair`). A whole
                        // circle/arc/ellipse/polygon (or a closed spline) has
                        // no such lowering; approving the edit would leave a
                        // ghost weld the solve silently drops.
                        rejected = !constraint.refs
                            .filter { $0.entityID != entityID }
                            .allSatisfy { Self.executableArcEndpointCounterpart($0, in: sketch) }
                    case .fixed:
                        rejected = false
                    case .tangent:
                        // Junction G1 exists only between this arc endpoint and
                        // an OPEN spline end; anything else (another arc, a
                        // circle, a closed spline) has no executable lowering.
                        let others = constraint.refs.filter { $0.entityID != entityID }
                        rejected = !(others.count == 1
                                     && (others[0].role == .endpointA || others[0].role == .endpointB)
                                     && {
                                        if case let .spline(_, _, closed)? =
                                            sketch.entities.first(where: { $0.id == others[0].entityID }) {
                                            return !closed
                                        }
                                        return false
                                     }())
                    default:
                        rejected = true
                    }
                } else {
                    rejected = false
                }
            case .ellipse:
                // A point-based relationship on the centre is validated by the
                // production solve. Tangency/equal-radius needs ellipse radius
                // variables the solver does not have, so those are ambiguous.
                rejected = (refs.contains { $0.role != .center }
                            && constraint.kind != .fixed)
                    || constraint.kind == .tangent || constraint.kind == .equalRadius
            case .spline(_, _, let closed):
                rejected = closed || refs.contains {
                    $0.role != .endpointA && $0.role != .endpointB
                }
            default:
                rejected = false
            }
            if rejected {
                unsupported.append(detail(constraint.id, constraint.kind.rawValue,
                                          refs, in: constraint.refs))
            }
        }
        for dimension in dimensions {
            let refs = references(dimension.refs)
            let rejected: Bool
            switch entity {
            case .arc:
                // M02: point-to-point driving dimensions (distance and the
                // axis distances) lower truthfully onto arc endpoints. Radius/
                // diameter/angle dimensions keep their center/whole semantics
                // and stay refused when addressed at an endpoint role.
                if refs.contains(where: { $0.role == .endpointA || $0.role == .endpointB }) {
                    switch dimension.kind {
                    case .distance:
                        // R1 review: point-to-point, or point-to-(whole
                        // line-like), lower truthfully; any other whole
                        // counterpart is a ghost the solve silently drops.
                        rejected = !dimension.refs
                            .filter { $0.entityID != entityID }
                            .allSatisfy { Self.executableArcEndpointCounterpart($0, in: sketch) }
                    case .horizontal, .vertical:
                        // Lowered strictly point-to-point.
                        rejected = !dimension.refs
                            .filter { $0.entityID != entityID }
                            .allSatisfy { $0.role == .endpointA || $0.role == .endpointB }
                    default:
                        rejected = true
                    }
                } else {
                    rejected = false
                }
            case .ellipse:
                // Only radius/diameter dimensions assume an ellipse radius
                // scalar; point/distance dimensions are checked by the
                // production solve like every other reference.
                rejected = dimension.kind == .radius || dimension.kind == .diameter
            case .spline(_, _, let closed):
                rejected = closed || refs.contains {
                    $0.role != .endpointA && $0.role != .endpointB
                }
            default:
                rejected = false
            }
            if rejected {
                unsupported.append(detail(dimension.id, dimension.kind.rawValue,
                                          refs, in: dimension.refs))
            }
        }
        guard !unsupported.isEmpty else { return nil }
        return SketchEditFailure(
            code: "dependent_reference",
            message: "The \(kind) edit is refused because these saved relationships use geometry "
                + "the constraint solver cannot validate for this kind: "
                + unsupported.joined(separator: "; ")
                + ". Nothing was changed. Remove or rebind them explicitly, then retry.")
    }

    private static let entityEditCommonKeys: Set<String> = [
        "action", "revision", "expected_revision",
        "sketch_id", "sketchID", "sketch",
        "entity_id", "entityID", "id",
    ]

    private static func rejectUnsupportedFields(
        _ args: [String: Any], allowed: Set<String>, entityKind: String
    ) -> SketchEditFailure? {
        let extra = args.keys.filter {
            !entityEditCommonKeys.contains($0) && !allowed.contains($0)
        }.sorted()
        guard extra.isEmpty else {
            return SketchEditFailure(
                code: "field_not_supported",
                message: "Field(s) \(extra.joined(separator: ", ")) do not apply to a \(entityKind) edit. "
                    + "Allowed: \(allowed.sorted().joined(separator: ", ")).")
        }
        return nil
    }

    private static func point2(_ value: Any?) -> SIMD2<Double>? {
        if let numbers = CADMaterialService.doubles(value), numbers.count == 2 {
            return SIMD2(numbers[0], numbers[1])
        }
        if let object = value as? [String: Any] {
            guard let x = CADMaterialService.number(object["x"]),
                  let y = CADMaterialService.number(object["y"]),
                  x.isFinite, y.isFinite else { return nil }
            return SIMD2(x, y)
        }
        return nil
    }

    private static func samePoint(_ left: SIMD2<Double>, _ right: SIMD2<Double>) -> Bool {
        abs(left.x - right.x) <= 1e-6 && abs(left.y - right.y) <= 1e-6
    }

    private static func samePoints(_ left: [SIMD2<Double>], _ right: [SIMD2<Double>]) -> Bool {
        left.count == right.count && zip(left, right).allSatisfy { samePoint($0, $1) }
    }

    /// The model-facing angle unit for every typed edit is degrees. Sketch
    /// storage keeps radians; convert exactly once at this boundary.
    private static func radians(fromDegrees value: Double) -> Double {
        value * Double.pi / 180
    }

    private static func degrees(fromRadians value: Double) -> Double {
        value * 180 / Double.pi
    }

    /// Canonical signed angle in (-π, π]. A 350° input becomes -10°, so the
    /// stored start ray is canonical while the original sweep is preserved.
    private static func normalizedRadians(_ value: Double) -> Double {
        var angle = value.truncatingRemainder(dividingBy: 2 * .pi)
        if angle <= -Double.pi { angle += 2 * .pi }
        if angle > Double.pi { angle -= 2 * .pi }
        return angle
    }

    private static func angleArgument(
        _ args: [String: Any], keys: [String]
    ) -> Result<(key: String, value: Double)?, SketchEditFailure> {
        for key in keys where args[key] != nil {
            guard let value = CADMaterialService.number(args[key]), value.isFinite else {
                return .failure(SketchEditFailure(
                    code: "bad_angle",
                    message: "\(key) must be a finite angle in degrees."))
            }
            return .success((key, value))
        }
        return .success(nil)
    }

    private static func integerValue(_ raw: Any?, code: String, label: String) -> Result<Int, SketchEditFailure> {
        guard let number = CADMaterialService.number(raw), number.isFinite,
              number == number.rounded(), number >= 0, number < Double(Int.max) else {
            return .failure(SketchEditFailure(
                code: code,
                message: "\(label) must be a non-negative whole number."))
        }
        return .success(Int(number))
    }

    private static func angularDifference(_ leftDegrees: Double, _ rightDegrees: Double) -> Double {
        abs(degrees(fromRadians: normalizedRadians(
            radians(fromDegrees: leftDegrees) - radians(fromDegrees: rightDegrees))))
    }

    /// Parse a list of plane points from either [[x, y], ...] or
    /// [{x, y}, ...]. Rejects non-finite values instead of storing NaN.
    private static func pointList(_ value: Any?) -> [SIMD2<Double>]? {
        guard let rows = value as? [Any] else { return nil }
        var points: [SIMD2<Double>] = []
        points.reserveCapacity(rows.count)
        for row in rows {
            guard let point = point2(row), point.x.isFinite, point.y.isFinite else { return nil }
            points.append(point)
        }
        return points
    }

    private static func firstPoint(_ args: [String: Any], keys: [String]) -> SIMD2<Double>? {
        for key in keys {
            if let raw = args[key] {
                return point2(raw)
            }
        }
        return nil
    }

    private static func fencePoint(_ args: [String: Any], key: String,
                                   current: SIMD2<Double>, code: String) -> SketchEditFailure? {
        guard let raw = args[key] else { return nil }
        guard let expected = point2(raw) else {
            return SketchEditFailure(code: code,
                                     message: "\(key) must be the current [x, y] point from query kind=sketches.")
        }
        guard samePoint(expected, current) else {
            return SketchEditFailure(
                code: "point_mismatch",
                message: "The entity is currently at [\(current.x), \(current.y)], not the expected "
                    + "[\(expected.x), \(expected.y)] \(key). Re-query kind=sketches before editing it.")
        }
        return nil
    }

    private static func lineEditPlan(
        args: [String: Any], id: UUID, a: SIMD2<Double>, b: SIMD2<Double>,
        dimensions: [SketchDimension]
    ) -> Result<SketchEntityEditPlan, SketchEditFailure> {
        if let failure = rejectUnsupportedFields(
            args,
            allowed: ["a", "b", "start", "end", "endpointA", "endpointB",
                      "expected_a", "expected_b"],
            entityKind: "line") {
            return .failure(failure)
        }
        let newA = firstPoint(args, keys: ["a", "start", "endpointA"]) ?? a
        let newB = firstPoint(args, keys: ["b", "end", "endpointB"]) ?? b
        let touchedA = ["a", "start", "endpointA"].contains { args[$0] != nil }
        let touchedB = ["b", "end", "endpointB"].contains { args[$0] != nil }
        guard touchedA || touchedB else {
            return .failure(SketchEditFailure(
                code: "missing_geometry",
                message: "A line edit needs a and/or b (aliases start/end) as finite [x, y] points."))
        }
        guard newA.x.isFinite, newA.y.isFinite, newB.x.isFinite, newB.y.isFinite else {
            return .failure(SketchEditFailure(code: "bad_point", message: "Line endpoints must be finite [x, y] points."))
        }
        if let failure = fencePoint(args, key: "expected_a", current: a, code: "bad_expected_a") { return .failure(failure) }
        if let failure = fencePoint(args, key: "expected_b", current: b, code: "bad_expected_b") { return .failure(failure) }
        let length = simd_length(newB - newA)
        guard length > 1e-9 else {
            return .failure(SketchEditFailure(
                code: "degenerate_line",
                message: "A line's endpoints must not coincide (zero length)."))
        }
        var updates: [(before: SketchDimension, after: SketchDimension)] = []
        for dimension in dimensions where Self.dimensionMeasuresLine(dimension, entityID: id) {
            // A formula-driven value is intentional design intent; a direct
            // geometry edit must not silently discard it. If the new geometry
            // still satisfies the formula, the residual check below passes;
            // otherwise the edit is refused.
            guard dimension.formula == nil else { continue }
            var after = dimension
            switch dimension.kind {
            case .distance:
                after.value = length
            case .horizontal:
                after.value = abs(newB.x - newA.x)
            case .vertical:
                after.value = abs(newB.y - newA.y)
            default:
                continue
            }
            if after.value <= 1e-9 {
                return .failure(SketchEditFailure(
                    code: "constraint_conflict",
                    message: "A \(dimension.kind.rawValue) driving dimension on this line would become "
                        + "zero; change the dimension with setSketchDimension instead."))
            }
            after.formula = nil
            after.displayExpression = nil
            if after != dimension { updates.append((dimension, after)) }
        }
        var heldRefs: [ConstraintRef] = []
        if touchedA { heldRefs.append(ConstraintRef(entityID: id, role: .endpointA)) }
        if touchedB { heldRefs.append(ConstraintRef(entityID: id, role: .endpointB)) }
        return .success(SketchEntityEditPlan(
            after: .line(id: id, a: newA, b: newB),
            heldRefs: heldRefs,
            dimensionUpdates: updates,
            applied: ["a": [newA.x, newA.y], "b": [newB.x, newB.y]],
            response: [
                "id": id.uuidString,
                "kind": "line",
                "a": [newA.x, newA.y],
                "b": [newB.x, newB.y],
                "lengthMM": length,
                "unit": "mm",
            ],
            title: "Edit Line"))
    }

    private static func dimensionMeasuresLine(_ dimension: SketchDimension, entityID: UUID) -> Bool {
        guard dimension.refs.count == 2 else { return false }
        guard dimension.refs.allSatisfy({ $0.entityID == entityID }) else { return false }
        return dimension.kind == .distance || dimension.kind == .horizontal || dimension.kind == .vertical
    }

    private static func rectEditPlan(
        args: [String: Any], id: UUID, low: SIMD2<Double>, high: SIMD2<Double>,
        dimensions: [SketchDimension]
    ) -> Result<SketchEntityEditPlan, SketchEditFailure> {
        if let failure = rejectUnsupportedFields(
            args,
            allowed: ["min", "max", "low", "high", "center", "width", "height",
                      "expected_min", "expected_max", "expected_center",
                      "expected_width", "expected_height"],
            entityKind: "rect") {
            return .failure(failure)
        }
        let currentLow = SIMD2(min(low.x, high.x), min(low.y, high.y))
        let currentHigh = SIMD2(max(low.x, high.x), max(low.y, high.y))
        let currentCenter = (currentLow + currentHigh) / 2
        let currentWidth = currentHigh.x - currentLow.x
        let currentHeight = currentHigh.y - currentLow.y

        let minValue = firstPoint(args, keys: ["min", "low"])
        let maxValue = firstPoint(args, keys: ["max", "high"])
        let centerValue = firstPoint(args, keys: ["center"])
        let widthValue = CADMaterialService.number(args["width"])
        let heightValue = CADMaterialService.number(args["height"])
        guard minValue != nil || maxValue != nil || centerValue != nil
                || widthValue != nil || heightValue != nil else {
            return .failure(SketchEditFailure(
                code: "missing_geometry",
                message: "A rect edit needs min/max, or center and/or width/height."))
        }
        if (minValue != nil || maxValue != nil) && (widthValue != nil || heightValue != nil) {
            return .failure(SketchEditFailure(
                code: "conflicting_geometry",
                message: "Use either min/max or width/height for a rect; combining both is ambiguous."))
        }
        if let failure = fencePoint(args, key: "expected_min", current: currentLow, code: "bad_expected_min") {
            return .failure(failure)
        }
        if let failure = fencePoint(args, key: "expected_max", current: currentHigh, code: "bad_expected_max") {
            return .failure(failure)
        }
        if let failure = fencePoint(args, key: "expected_center", current: currentCenter, code: "bad_expected_center") {
            return .failure(failure)
        }
        for (key, current, code) in [("expected_width", currentWidth, "bad_expected_width"),
                                     ("expected_height", currentHeight, "bad_expected_height")] {
            if let raw = args[key] {
                guard let expected = CADMaterialService.number(raw), expected.isFinite else {
                    return .failure(SketchEditFailure(code: code, message: "\(key) must be the current finite size in mm."))
                }
                guard abs(expected - current) <= 1e-6 else {
                    return .failure(SketchEditFailure(
                        code: "size_mismatch",
                        message: "The rect is currently \(current) mm on that axis, not the expected \(expected) mm. "
                            + "Re-query kind=sketches before editing it."))
                }
            }
        }

        let newLow: SIMD2<Double>
        let newHigh: SIMD2<Double>
        if minValue != nil || maxValue != nil {
            newLow = minValue ?? currentLow
            newHigh = maxValue ?? currentHigh
        } else {
            let newCenter = centerValue ?? currentCenter
            let width = widthValue ?? currentWidth
            let height = heightValue ?? currentHeight
            guard widthValue == nil || (width.isFinite && width > 1e-9) else {
                return .failure(SketchEditFailure(code: "bad_width", message: "width must be a positive finite mm value."))
            }
            guard heightValue == nil || (height.isFinite && height > 1e-9) else {
                return .failure(SketchEditFailure(code: "bad_height", message: "height must be a positive finite mm value."))
            }
            newLow = SIMD2(newCenter.x - width / 2, newCenter.y - height / 2)
            newHigh = SIMD2(newCenter.x + width / 2, newCenter.y + height / 2)
        }
        guard newLow.x.isFinite, newLow.y.isFinite, newHigh.x.isFinite, newHigh.y.isFinite else {
            return .failure(SketchEditFailure(code: "bad_point", message: "Rect bounds must be finite [x, y] points."))
        }
        let width = abs(newHigh.x - newLow.x)
        let height = abs(newHigh.y - newLow.y)
        guard width > 1e-9, height > 1e-9 else {
            return .failure(SketchEditFailure(
                code: "degenerate_rect",
                message: "A rect needs a positive width and height."))
        }
        let normalizedLow = SIMD2(min(newLow.x, newHigh.x), min(newLow.y, newHigh.y))
        let normalizedHigh = SIMD2(max(newLow.x, newHigh.x), max(newLow.y, newHigh.y))

        var updates: [(before: SketchDimension, after: SketchDimension)] = []
        for dimension in dimensions where Self.dimensionMeasuresRect(dimension, entityID: id) {
            guard dimension.formula == nil else { continue }
            var after = dimension
            switch dimension.kind {
            case .horizontal: after.value = width
            case .vertical: after.value = height
            default: continue
            }
            after.formula = nil
            after.displayExpression = nil
            if after != dimension { updates.append((dimension, after)) }
        }
        let center = (normalizedLow + normalizedHigh) / 2
        var heldRefs: [ConstraintRef] = []
        if centerValue != nil || widthValue != nil || heightValue != nil {
            // A framed edit fixes both bounds; a min/max edit fixes only the
            // side(s) the caller named and leaves the other side solvable.
            heldRefs = [ConstraintRef(entityID: id, role: .endpointA),
                        ConstraintRef(entityID: id, role: .endpointB)]
        } else {
            if minValue != nil {
                heldRefs.append(ConstraintRef(entityID: id, role: .endpointA))
            }
            if maxValue != nil {
                heldRefs.append(ConstraintRef(entityID: id, role: .endpointB))
            }
        }
        return .success(SketchEntityEditPlan(
            after: .rect(id: id, min: normalizedLow, max: normalizedHigh),
            heldRefs: heldRefs,
            dimensionUpdates: updates,
            applied: ["min": [normalizedLow.x, normalizedLow.y],
                      "max": [normalizedHigh.x, normalizedHigh.y]],
            response: [
                "id": id.uuidString,
                "kind": "rect",
                "min": [normalizedLow.x, normalizedLow.y],
                "max": [normalizedHigh.x, normalizedHigh.y],
                "center": [center.x, center.y],
                "widthMM": width,
                "heightMM": height,
                "unit": "mm",
            ],
            title: "Edit Rectangle"))
    }

    private static func dimensionMeasuresRect(_ dimension: SketchDimension, entityID: UUID) -> Bool {
        guard dimension.refs.count == 2 else { return false }
        guard dimension.refs.allSatisfy({ $0.entityID == entityID }) else { return false }
        return dimension.kind == .horizontal || dimension.kind == .vertical
    }

    private static func circleEditPlan(
        args: [String: Any], id: UUID, center: SIMD2<Double>, radius: Double,
        dimensions: [SketchDimension]
    ) -> Result<SketchEntityEditPlan, SketchEditFailure> {
        if let failure = rejectUnsupportedFields(
            args,
            allowed: ["center", "radius", "diameter", "expected_center",
                      "expected_radius", "current_radius", "expected_diameter"],
            entityKind: "circle") {
            return .failure(failure)
        }
        let centerValue = firstPoint(args, keys: ["center"])
        let radiusValue = CADMaterialService.number(args["radius"])
        let diameterValue = CADMaterialService.number(args["diameter"])
        guard centerValue != nil || radiusValue != nil || diameterValue != nil else {
            return .failure(SketchEditFailure(
                code: "missing_geometry",
                message: "A circle edit needs center, radius and/or diameter."))
        }
        if let failure = fencePoint(args, key: "expected_center", current: center, code: "bad_expected_center") {
            return .failure(failure)
        }
        if let raw = args["expected_radius"] ?? args["current_radius"] {
            guard let expected = CADMaterialService.number(raw), expected.isFinite else {
                return .failure(SketchEditFailure(
                    code: "bad_expected_radius",
                    message: "expected_radius must be the finite current radius from query kind=sketches."))
            }
            guard abs(expected - radius) <= 1e-6 else {
                return .failure(SketchEditFailure(
                    code: "radius_mismatch",
                    message: "The circle is currently \(radius) mm, not the expected \(expected) mm. "
                        + "Re-query kind=sketches before editing it."))
            }
        }
        if let raw = args["expected_diameter"] {
            guard let expected = CADMaterialService.number(raw), expected.isFinite else {
                return .failure(SketchEditFailure(
                    code: "bad_expected_diameter",
                    message: "expected_diameter must be the finite current diameter in mm."))
            }
            guard abs(expected - radius * 2) <= 1e-6 else {
                return .failure(SketchEditFailure(
                    code: "diameter_mismatch",
                    message: "The circle is currently \(radius * 2) mm diameter, not the expected "
                        + "\(expected) mm. Re-query kind=sketches before editing it."))
            }
        }
        var newRadius = radius
        if let radiusValue, let diameterValue {
            guard abs(radiusValue * 2 - diameterValue) <= 1e-6 else {
                return .failure(SketchEditFailure(
                    code: "conflicting_geometry",
                    message: "radius and diameter disagree; send one value."))
            }
            newRadius = radiusValue
        } else if let radiusValue {
            newRadius = radiusValue
        } else if let diameterValue {
            newRadius = diameterValue / 2
        }
        guard newRadius.isFinite, newRadius > 1e-6 else {
            return .failure(SketchEditFailure(code: "bad_radius", message: "radius must be greater than 0 mm."))
        }
        let newCenter = centerValue ?? center
        guard newCenter.x.isFinite, newCenter.y.isFinite else {
            return .failure(SketchEditFailure(code: "bad_point", message: "The circle center must be a finite [x, y] point."))
        }
        var updates: [(before: SketchDimension, after: SketchDimension)] = []
        for dimension in dimensions where dimension.refs.contains(where: { $0.entityID == id }) {
            guard dimension.formula == nil else { continue }
            var after = dimension
            switch dimension.kind {
            case .radius: after.value = newRadius
            case .diameter: after.value = newRadius * 2
            default: continue
            }
            after.formula = nil
            after.displayExpression = nil
            if after != dimension { updates.append((dimension, after)) }
        }
        let heldRefs: [ConstraintRef]
        if radiusValue != nil || diameterValue != nil {
            // There is no radius-only ConstraintRef; a whole ref holds the
            // requested radius and the center it is measured from.
            heldRefs = [ConstraintRef(entityID: id, role: .whole)]
        } else if centerValue != nil {
            heldRefs = [ConstraintRef(entityID: id, role: .center)]
        } else {
            heldRefs = []
        }
        return .success(SketchEntityEditPlan(
            after: .circle(id: id, center: newCenter, radius: newRadius),
            heldRefs: heldRefs,
            dimensionUpdates: updates,
            applied: ["center": [newCenter.x, newCenter.y], "radius": newRadius],
            response: [
                "id": id.uuidString,
                "kind": "circle",
                "center": [newCenter.x, newCenter.y],
                "old_radius": radius,
                "radius": newRadius,
                "diameter": newRadius * 2,
                "unit": "mm",
            ],
            title: "Edit Circle"))
    }

    /// Edit an existing ARC by stable id. Angles cross the model boundary in
    /// degrees; storage keeps radians with a CCW sweep normalized into
    /// [0, 2π). Changing the start angle alone rotates the arc and changes its
    /// sweep; `sweep_angle_deg` changes only the swept amount. A matching
    /// single-arc angle dimension is updated in the same undo step, exactly
    /// like a circle's radius/diameter dimension.
    private static func arcEditPlan(
        args: [String: Any], id: UUID, center: SIMD2<Double>, radius: Double,
        startAngle: Double, endAngle: Double, dimensions: [SketchDimension],
        endpointConnected: Bool
    ) -> Result<SketchEntityEditPlan, SketchEditFailure> {
        if let failure = rejectUnsupportedFields(
            args,
            allowed: ["center", "radius", "diameter",
                      "start_angle_deg", "start_angle", "startAngleDegrees",
                      "end_angle_deg", "end_angle", "endAngleDegrees",
                      "sweep_angle_deg", "sweep_angle", "sweepAngleDegrees",
                      "expected_center", "expected_radius", "current_radius",
                      "expected_diameter", "expected_start_angle_deg",
                      "expected_end_angle_deg", "expected_sweep_angle_deg"],
            entityKind: "arc") {
            return .failure(failure)
        }
        let centerValue = firstPoint(args, keys: ["center"])
        let ray = (angleArgument(args, keys: ["start_angle_deg", "start_angle", "startAngleDegrees"]))
        let endArg = (angleArgument(args, keys: ["end_angle_deg", "end_angle", "endAngleDegrees"]))
        let sweepArg = (angleArgument(args, keys: ["sweep_angle_deg", "sweep_angle", "sweepAngleDegrees"]))
        guard centerValue != nil || args["radius"] != nil || args["diameter"] != nil
                || args["start_angle_deg"] != nil || args["start_angle"] != nil
                || args["startAngleDegrees"] != nil || args["end_angle_deg"] != nil
                || args["end_angle"] != nil || args["endAngleDegrees"] != nil
                || args["sweep_angle_deg"] != nil || args["sweep_angle"] != nil
                || args["sweepAngleDegrees"] != nil else {
            return .failure(SketchEditFailure(
                code: "missing_geometry",
                message: "An arc edit needs center, radius/diameter, start_angle_deg, "
                    + "end_angle_deg and/or sweep_angle_deg."))
        }
        let startDegrees: (key: String, value: Double)?
        switch ray {
        case .success(let value): startDegrees = value
        case .failure(let error): return .failure(error)
        }
        let endDegrees: (key: String, value: Double)?
        switch endArg {
        case .success(let value): endDegrees = value
        case .failure(let error): return .failure(error)
        }
        let sweepDegrees: (key: String, value: Double)?
        switch sweepArg {
        case .success(let value): sweepDegrees = value
        case .failure(let error): return .failure(error)
        }

        if let failure = fencePoint(args, key: "expected_center", current: center,
                                    code: "bad_expected_center") { return .failure(failure) }
        let currentStartDegrees = degrees(fromRadians: normalizedRadians(startAngle))
        let currentEndDegrees = degrees(fromRadians: normalizedRadians(endAngle))
        let currentSweepDegrees = degrees(fromRadians:
            SketchEntity.arcSweep(startAngle: startAngle, endAngle: endAngle))
        if let raw = args["expected_start_angle_deg"] {
            guard let expected = CADMaterialService.number(raw), expected.isFinite else {
                return .failure(SketchEditFailure(
                    code: "bad_expected_start_angle_deg",
                    message: "expected_start_angle_deg must be the current finite angle in degrees."))
            }
            guard angularDifference(expected, currentStartDegrees) <= 1e-6 else {
                return .failure(SketchEditFailure(
                    code: "angle_mismatch",
                    message: "The arc starts at \(currentStartDegrees)°, not the expected "
                        + "\(expected)°. Re-query kind=sketches before editing it."))
            }
        }
        if let raw = args["expected_end_angle_deg"] {
            guard let expected = CADMaterialService.number(raw), expected.isFinite else {
                return .failure(SketchEditFailure(
                    code: "bad_expected_end_angle_deg",
                    message: "expected_end_angle_deg must be the current finite angle in degrees."))
            }
            guard angularDifference(expected, currentEndDegrees) <= 1e-6 else {
                return .failure(SketchEditFailure(
                    code: "angle_mismatch",
                    message: "The arc ends at \(currentEndDegrees)°, not the expected "
                        + "\(expected)°. Re-query kind=sketches before editing it."))
            }
        }
        if let raw = args["expected_sweep_angle_deg"] {
            guard let expected = CADMaterialService.number(raw), expected.isFinite else {
                return .failure(SketchEditFailure(
                    code: "bad_expected_sweep_angle_deg",
                    message: "expected_sweep_angle_deg must be the current finite angle in degrees."))
            }
            guard abs(expected - currentSweepDegrees) <= 1e-6 else {
                return .failure(SketchEditFailure(
                    code: "angle_mismatch",
                    message: "The arc sweeps \(currentSweepDegrees)°, not the expected "
                        + "\(expected)°. Re-query kind=sketches before editing it."))
            }
        }
        if let raw = args["expected_radius"] ?? args["current_radius"] {
            guard let expected = CADMaterialService.number(raw), expected.isFinite else {
                return .failure(SketchEditFailure(
                    code: "bad_expected_radius",
                    message: "expected_radius must be the finite current radius from query kind=sketches."))
            }
            guard abs(expected - radius) <= 1e-6 else {
                return .failure(SketchEditFailure(
                    code: "radius_mismatch",
                    message: "The arc is currently \(radius) mm, not the expected \(expected) mm. "
                        + "Re-query kind=sketches before editing it."))
            }
        }
        if let raw = args["expected_diameter"] {
            guard let expected = CADMaterialService.number(raw), expected.isFinite else {
                return .failure(SketchEditFailure(
                    code: "bad_expected_diameter",
                    message: "expected_diameter must be the finite current diameter in mm."))
            }
            guard abs(expected - radius * 2) <= 1e-6 else {
                return .failure(SketchEditFailure(
                    code: "diameter_mismatch",
                    message: "The arc is currently \(radius * 2) mm diameter, not the expected "
                        + "\(expected) mm. Re-query kind=sketches before editing it."))
            }
        }

        let newCenter = centerValue ?? center
        guard newCenter.x.isFinite, newCenter.y.isFinite else {
            return .failure(SketchEditFailure(
                code: "bad_point", message: "The arc center must be a finite [x, y] point."))
        }
        let radiusValue = args["radius"] == nil ? nil : CADMaterialService.number(args["radius"])
        let diameterValue = args["diameter"] == nil ? nil : CADMaterialService.number(args["diameter"])
        if args["radius"] != nil, radiusValue == nil || radiusValue?.isFinite != true {
            return .failure(SketchEditFailure(code: "bad_radius", message: "radius must be a finite mm value."))
        }
        if args["diameter"] != nil, diameterValue == nil || diameterValue?.isFinite != true {
            return .failure(SketchEditFailure(code: "bad_diameter", message: "diameter must be a finite mm value."))
        }
        var newRadius = radius
        if let radiusValue, let diameterValue {
            guard abs(radiusValue * 2 - diameterValue) <= 1e-6 else {
                return .failure(SketchEditFailure(
                    code: "conflicting_geometry", message: "radius and diameter disagree; send one value."))
            }
            newRadius = radiusValue
        } else if let radiusValue {
            newRadius = radiusValue
        } else if let diameterValue {
            newRadius = diameterValue / 2
        }
        guard newRadius.isFinite, newRadius > 1e-6 else {
            return .failure(SketchEditFailure(code: "bad_radius", message: "radius must be greater than 0 mm."))
        }

        var newStart = normalizedRadians(startAngle)
        if let startDegrees {
            newStart = normalizedRadians(radians(fromDegrees: startDegrees.value))
        }
        var sweep: Double
        if let endDegrees {
            let requestedEnd = radians(fromDegrees: endDegrees.value)
            sweep = SketchEntity.arcSweep(startAngle: newStart, endAngle: requestedEnd)
            if let sweepDegrees {
                let requestedSweep = radians(fromDegrees: sweepDegrees.value)
                guard abs(sweep - requestedSweep) <= 1e-6 else {
                    return .failure(SketchEditFailure(
                        code: "conflicting_geometry",
                        message: "end_angle_deg and sweep_angle_deg disagree; send one angle pair."))
                }
            }
        } else if let sweepDegrees {
            sweep = radians(fromDegrees: sweepDegrees.value)
        } else {
            sweep = SketchEntity.arcSweep(startAngle: newStart, endAngle: endAngle)
        }
        guard sweep.isFinite, sweep > 1e-9, sweep < 2 * .pi - 1e-9 else {
            return .failure(SketchEditFailure(
                code: "degenerate_arc",
                message: "An arc needs a positive sweep smaller than a full turn; use a circle "
                    + "for a complete closed curve."))
        }
        let newEnd = newStart + sweep

        var updates: [(before: SketchDimension, after: SketchDimension)] = []
        for dimension in dimensions where dimension.refs.contains(where: { $0.entityID == id }) {
            guard dimension.formula == nil else { continue }
            var after = dimension
            switch dimension.kind {
            case .radius:
                after.value = newRadius
            case .diameter:
                after.value = newRadius * 2
            case .angle where dimension.refs.count == 1:
                after.value = sweep
            default:
                continue
            }
            after.formula = nil
            after.displayExpression = nil
            if after != dimension { updates.append((dimension, after)) }
        }
        let startDeg = degrees(fromRadians: newStart)
        let endDeg = degrees(fromRadians: normalizedRadians(newEnd))
        let sweepDeg = degrees(fromRadians: sweep)
        let touchedShape = radiusValue != nil || diameterValue != nil
            || startDegrees != nil || endDegrees != nil || sweepDegrees != nil
        let heldRefs: [ConstraintRef]
        if touchedShape {
            if endpointConnected {
                // M02 connected arc: the endpoints are solver variables that
                // must stay free to find the tangency-consistent junctions.
                // Holding `.whole` would pin them at the naive derived
                // positions and every tangency edit would refuse as a
                // conflict. Hold exactly the requested scalars instead: the
                // center for a center edit, and the transient `radiusOnly`
                // anchor for a radius/diameter edit (the solved write-back
                // still reports the actual, tangency-consistent angles).
                var refs: [ConstraintRef] = []
                if radiusValue != nil || diameterValue != nil {
                    refs.append(ConstraintRef(entityID: id, role: .radiusOnly))
                }
                if centerValue != nil {
                    refs.append(ConstraintRef(entityID: id, role: .center))
                }
                heldRefs = refs
            } else {
                // Arc radius/sweep have no role-level ref; a whole ref holds the
                // requested scalar(s) and the center they are measured from.
                heldRefs = [ConstraintRef(entityID: id, role: .whole)]
            }
        } else if centerValue != nil {
            heldRefs = [ConstraintRef(entityID: id, role: .center)]
        } else {
            heldRefs = []
        }
        return .success(SketchEntityEditPlan(
            after: .arc(id: id, center: newCenter, radius: newRadius,
                        startAngle: newStart, endAngle: newEnd),
            heldRefs: heldRefs,
            dimensionUpdates: updates,
            applied: ["center": [newCenter.x, newCenter.y], "radius": newRadius,
                      "start_angle_deg": startDeg, "end_angle_deg": endDeg,
                      "sweep_angle_deg": sweepDeg],
            response: [
                "id": id.uuidString,
                "kind": "arc",
                "center": [newCenter.x, newCenter.y],
                "radius": newRadius,
                "diameter": newRadius * 2,
                "startAngleRadians": newStart,
                "endAngleRadians": newEnd,
                "startAngleDegrees": startDeg,
                "endAngleDegrees": endDeg,
                "sweepAngleDegrees": sweepDeg,
                "unit": "mm",
                "angleUnit": "degrees",
            ],
            title: "Edit Arc"))
    }

    /// Edit an existing ELLIPSE by stable id. Axis radii are millimetres and
    /// `rotation_deg` is the model-facing angle; the stored rotation is radians.
    /// The solver has no ellipse radius/rotation variables, so any saved
    /// dimension/tangent relationship is refused by `editReferenceFailure`
    /// rather than silently left stale.
    private static func ellipseEditPlan(
        args: [String: Any], id: UUID, center: SIMD2<Double>,
        radiusX: Double, radiusY: Double, rotation: Double
    ) -> Result<SketchEntityEditPlan, SketchEditFailure> {
        if let failure = rejectUnsupportedFields(
            args,
            allowed: ["center", "radius_x", "radius_y", "radiusX", "radiusY",
                      "rotation_deg", "rotation",
                      "expected_center", "expected_radius_x", "expected_radius_y",
                      "expected_rotation_deg"],
            entityKind: "ellipse") {
            return .failure(failure)
        }
        let centerValue = firstPoint(args, keys: ["center"])
        let hasRadiusX = args["radius_x"] != nil || args["radiusX"] != nil
        let hasRadiusY = args["radius_y"] != nil || args["radiusY"] != nil
        let rotationArg = (angleArgument(args, keys: ["rotation_deg", "rotation"]))
        guard centerValue != nil || hasRadiusX || hasRadiusY
                || args["rotation_deg"] != nil || args["rotation"] != nil else {
            return .failure(SketchEditFailure(
                code: "missing_geometry",
                message: "An ellipse edit needs center, radius_x, radius_y and/or rotation_deg."))
        }
        let rotationDegrees: (key: String, value: Double)?
        switch rotationArg {
        case .success(let value): rotationDegrees = value
        case .failure(let error): return .failure(error)
        }
        if let failure = fencePoint(args, key: "expected_center", current: center,
                                    code: "bad_expected_center") { return .failure(failure) }
        let currentRotationDegrees = degrees(fromRadians: normalizedRadians(rotation))
        for (key, current, code) in [
            ("expected_radius_x", radiusX, "bad_expected_radius_x"),
            ("expected_radius_y", radiusY, "bad_expected_radius_y"),
        ] {
            if let raw = args[key] {
                guard let expected = CADMaterialService.number(raw), expected.isFinite else {
                    return .failure(SketchEditFailure(
                        code: code, message: "\(key) must be the finite current radius in mm."))
                }
                guard abs(expected - current) <= 1e-6 else {
                    return .failure(SketchEditFailure(
                        code: "radius_mismatch",
                        message: "The ellipse axis is currently \(current) mm, not the expected "
                            + "\(expected) mm. Re-query kind=sketches before editing it."))
                }
            }
        }
        if let raw = args["expected_rotation_deg"] {
            guard let expected = CADMaterialService.number(raw), expected.isFinite else {
                return .failure(SketchEditFailure(
                    code: "bad_expected_rotation_deg",
                    message: "expected_rotation_deg must be the current finite angle in degrees."))
            }
            guard angularDifference(expected, currentRotationDegrees) <= 1e-6 else {
                return .failure(SketchEditFailure(
                    code: "angle_mismatch",
                    message: "The ellipse rotation is \(currentRotationDegrees)°, not the expected "
                        + "\(expected)°. Re-query kind=sketches before editing it."))
            }
        }
        let newCenter = centerValue ?? center
        guard newCenter.x.isFinite, newCenter.y.isFinite else {
            return .failure(SketchEditFailure(
                code: "bad_point", message: "The ellipse center must be a finite [x, y] point."))
        }
        func axis(_ keys: [String], current: Double, code: String) -> Result<Double, SketchEditFailure> {
            for key in keys where args[key] != nil {
                guard let value = CADMaterialService.number(args[key]), value.isFinite, value > 1e-6 else {
                    return .failure(SketchEditFailure(
                        code: code, message: "\(key) must be a positive finite mm radius."))
                }
                return .success(value)
            }
            return .success(current)
        }
        let newRadiusX: Double
        switch axis(["radius_x", "radiusX"], current: radiusX, code: "bad_radius_x") {
        case .success(let value): newRadiusX = value
        case .failure(let error): return .failure(error)
        }
        let newRadiusY: Double
        switch axis(["radius_y", "radiusY"], current: radiusY, code: "bad_radius_y") {
        case .success(let value): newRadiusY = value
        case .failure(let error): return .failure(error)
        }
        let newRotation = rotationDegrees.map {
            normalizedRadians(radians(fromDegrees: $0.value))
        } ?? normalizedRadians(rotation)
        let rotationDeg = degrees(fromRadians: newRotation)
        let heldRefs: [ConstraintRef] = centerValue == nil
            ? []
            : [ConstraintRef(entityID: id, role: .center)]
        return .success(SketchEntityEditPlan(
            after: .ellipse(id: id, center: newCenter,
                            radiusX: newRadiusX, radiusY: newRadiusY,
                            rotation: newRotation),
            heldRefs: heldRefs,
            dimensionUpdates: [],
            applied: ["center": [newCenter.x, newCenter.y],
                      "radius_x": newRadiusX, "radius_y": newRadiusY,
                      "rotation_deg": rotationDeg],
            response: [
                "id": id.uuidString,
                "kind": "ellipse",
                "center": [newCenter.x, newCenter.y],
                "radiusX": newRadiusX,
                "radiusY": newRadiusY,
                "rotationRadians": newRotation,
                "rotationDegrees": rotationDeg,
                "unit": "mm",
                "angleUnit": "degrees",
            ],
            title: "Edit Ellipse"))
    }

    /// Edit a SPLINE's fit points by stable entity id. `point_index` is the
    /// zero-based identity of one point in the stored order; `points` replaces
    /// the whole list and therefore every index. Open-spline fit points are
    /// solver variables, so the caller's edited indices are held transiently
    /// while related geometry solves; closed splines remain outside this model.
    private static func splineEditPlan(
        args: [String: Any], id: UUID, points: [SIMD2<Double>], closed: Bool
    ) -> Result<SketchEntityEditPlan, SketchEditFailure> {
        if let failure = rejectUnsupportedFields(
            args,
            allowed: ["points", "point", "point_index", "expected_point", "expected_points"],
            entityKind: "spline") {
            return .failure(failure)
        }
        let hasPoints = args["points"] != nil
        let hasIndexEdit = args["point_index"] != nil || args["point"] != nil
        guard hasPoints || hasIndexEdit else {
            return .failure(SketchEditFailure(
                code: "missing_geometry",
                message: "A spline edit needs points (all fit points) or point_index + point."))
        }
        if hasPoints && hasIndexEdit {
            return .failure(SketchEditFailure(
                code: "conflicting_geometry",
                message: "Send either points (replace all) or point_index + point (edit one); "
                    + "combining both is ambiguous."))
        }
        var newPoints = points
        var editedIndex: Int?
        if hasPoints {
            guard let parsed = pointList(args["points"]) else {
                return .failure(SketchEditFailure(
                    code: "bad_points",
                    message: "points must be [[x, y], ...] finite plane points, in fit order."))
            }
            guard parsed.count >= 2 else {
                return .failure(SketchEditFailure(
                    code: "bad_spline",
                    message: "A spline needs at least two fit points."))
            }
            if let raw = args["expected_points"] {
                guard let expected = pointList(raw) else {
                    return .failure(SketchEditFailure(
                        code: "bad_expected_points",
                        message: "expected_points must be the current [[x, y], ...] list."))
                }
                guard samePoints(expected, points) else {
                    return .failure(SketchEditFailure(
                        code: "points_mismatch",
                        message: "The spline's fit points changed since they were read; "
                            + "re-query kind=sketches before replacing them."))
                }
            }
            newPoints = parsed
        } else {
            guard let rawIndex = args["point_index"] else {
                return .failure(SketchEditFailure(
                    code: "missing_point_index",
                    message: "Editing one spline point needs point_index (0-based) and point."))
            }
            let index: Int
            switch integerValue(rawIndex, code: "bad_point_index", label: "point_index") {
            case .success(let value): index = value
            case .failure(let error): return .failure(error)
            }
            guard index < points.count else {
                return .failure(SketchEditFailure(
                    code: "unknown_point",
                    message: "point_index \(index) is outside this spline (0...\(points.count - 1))."))
            }
            guard let rawPoint = args["point"] else {
                return .failure(SketchEditFailure(
                    code: "missing_point",
                    message: "Editing one spline point needs point as a finite [x, y]."))
            }
            guard let point = point2(rawPoint), point.x.isFinite, point.y.isFinite else {
                return .failure(SketchEditFailure(
                    code: "bad_point", message: "point must be a finite [x, y] plane point."))
            }
            if let raw = args["expected_point"] {
                guard let expected = point2(raw) else {
                    return .failure(SketchEditFailure(
                        code: "bad_expected_point",
                        message: "expected_point must be the current [x, y] point."))
                }
                guard samePoint(expected, points[index]) else {
                    return .failure(SketchEditFailure(
                        code: "point_mismatch",
                        message: "Spline point \(index) is currently [\(points[index].x), "
                            + "\(points[index].y)], not the expected [\(expected.x), \(expected.y)]. "
                            + "Re-query kind=sketches before editing it."))
                }
            }
            newPoints[index] = point
            editedIndex = index
        }
        var heldRefs: [ConstraintRef] = []
        if !closed {
            if hasPoints {
                heldRefs = [ConstraintRef(entityID: id, role: .endpointA),
                            ConstraintRef(entityID: id, role: .endpointB)]
            } else if let editedIndex {
                if editedIndex == 0 {
                    heldRefs = [ConstraintRef(entityID: id, role: .endpointA)]
                } else if editedIndex == points.count - 1 {
                    heldRefs = [ConstraintRef(entityID: id, role: .endpointB)]
                }
            }
        }
        return .success(SketchEntityEditPlan(
            after: .spline(id: id, points: newPoints, closed: closed),
            heldRefs: heldRefs,
            dimensionUpdates: [],
            applied: ["points": newPoints.map { [$0.x, $0.y] }],
            response: [
                "id": id.uuidString,
                "kind": "spline",
                "closed": closed,
                "pointCount": newPoints.count,
                "points": newPoints.map { [$0.x, $0.y] },
                "editedPointIndex": editedIndex.map { $0 as Any } ?? NSNull(),
                "unit": "mm",
            ],
            title: "Edit Spline"))
    }

    // MARK: - Driving dimensions

    /// Create or update ONE driving dimension on an existing sketch. The
    /// geometry is re-solved with the same `SketchSolverBridge.solveDimensionEdit`
    /// the interactive dimension field uses; the dimension change and every
    /// moved entity commit as one undoable sketch rebuild.
    ///
    /// The model-facing `length` kind is a line's point-to-point `.distance`.
    /// `angle` is entered in DEGREES and stored in radians; every other kind is
    /// millimetres (diameter stores the diameter, not the radius).
    private func setSketchDimension(_ args: [String: Any]) -> [String: Any] {
        let allowed: Set<String> = [
            "action", "revision", "expected_revision",
            "sketch_id", "sketchID", "sketch",
            "entity_id", "entityID", "id", "entity_ids", "entityIDs",
            "kind", "value", "expected_value", "dimension_id",
            "refs",
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
                             "setSketchDimension needs sketch_id (the UUID query kind=sketches returned).")
        }
        let sketchID = SketchID(raw: sketchUUID)
        guard let sketch = document.session.document.sketches.first(where: { $0.id == sketchID }) else {
            return Self.fail("unknown_sketch", "No sketch \(rawSketch) in this document.")
        }
        guard let rawKind = CADMaterialService.string(args["kind"])?.lowercased(),
              Self.editableDimensionKinds.contains(rawKind) else {
            return Self.fail("bad_kind",
                             "setSketchDimension kind must be one of "
                                + Self.editableDimensionKinds.sorted().joined(separator: "|") + ".")
        }
        let requestedKind = rawKind == "length" ? "distance" : rawKind
        // Persisted spelling: a rectangle's width/height are the solver's
        // axis distances (horizontal/vertical), not a fourth dimension kind.
        let storedKindName: String
        switch requestedKind {
        case "width": storedKindName = "horizontal"
        case "height": storedKindName = "vertical"
        default: storedKindName = requestedKind
        }
        guard let rawValue = args["value"],
              let value = CADMaterialService.number(rawValue), value.isFinite else {
            return Self.fail("bad_value", "setSketchDimension needs a finite numeric value.")
        }

        let explicitRefs: [ConstraintRef]?
        if let rawRefs = args["refs"] {
            guard let rows = rawRefs as? [[String: Any]], !rows.isEmpty else {
                return Self.fail("bad_refs", "refs must be a non-empty array of {entity_id, role} objects.")
            }
            var refs: [ConstraintRef] = []
            for row in rows {
                guard let raw = CADMaterialService.string(row["entity_id"] ?? row["entityID"] ?? row["id"]),
                      let uuid = UUID(uuidString: raw),
                      sketch.entities.contains(where: { $0.id == uuid }) else {
                    return Self.fail("bad_refs", "Every ref needs an existing entity_id.")
                }
                let role: PointRole
                if let rawRole = CADMaterialService.string(row["role"]) {
                    // Explicit roles are admitted here, BEFORE any trial solve
                    // or document command. An omitted role keeps the legacy
                    // `.whole` default; an unknown or solver-local role never
                    // silently acquires another meaning.
                    guard let parsed = PointRole(rawValue: rawRole), parsed.isPersistable else {
                        return Self.fail(
                            "bad_refs",
                            "Unsupported ref role '\(rawRole)'. Use endpointA, endpointB, center or whole; "
                                + "radiusOnly is transient and cannot be saved.")
                    }
                    role = parsed
                } else {
                    role = .whole
                }
                refs.append(ConstraintRef(entityID: uuid, role: role))
            }
            explicitRefs = refs
        } else {
            explicitRefs = nil
        }

        let entityIDs: [UUID]
        if let list = args["entity_ids"] ?? args["entityIDs"] {
            guard let raws = list as? [Any] else {
                return Self.fail("bad_entity_ids", "entity_ids must be an array of entity UUID strings.")
            }
            var ids: [UUID] = []
            for raw in raws {
                guard let text = CADMaterialService.string(raw), let uuid = UUID(uuidString: text) else {
                    return Self.fail("bad_entity_ids", "entity_ids must contain entity UUID strings.")
                }
                ids.append(uuid)
            }
            entityIDs = ids
        } else if let raw = CADMaterialService.string(args["entity_id"])
                    ?? CADMaterialService.string(args["entityID"])
                    ?? CADMaterialService.string(args["id"]) {
            guard let uuid = UUID(uuidString: raw) else {
                return Self.fail("bad_entity_id", "entity_id must be an entity UUID.")
            }
            entityIDs = [uuid]
        } else {
            entityIDs = []
        }

        let refs: [ConstraintRef]
        if let explicitRefs {
            refs = explicitRefs
        } else {
            guard !entityIDs.isEmpty else {
                return Self.fail("missing_entity",
                                 "setSketchDimension needs entity_id, entity_ids or explicit refs.")
            }
            for id in entityIDs where !sketch.entities.contains(where: { $0.id == id }) {
                return Self.fail("unknown_entity", "Sketch '\(sketch.name)' has no entity \(id.uuidString).")
            }
            switch requestedKind {
            case "distance":
                if entityIDs.count == 1,
                   case .line? = sketch.entities.first(where: { $0.id == entityIDs[0] }) {
                    refs = [ConstraintRef(entityID: entityIDs[0], role: .endpointA),
                            ConstraintRef(entityID: entityIDs[0], role: .endpointB)]
                } else if entityIDs.count == 2,
                          sketch.entities.filter({ entityIDs.contains($0.id) }).allSatisfy({
                              if case .circle = $0 { return true }
                              return false
                          }) {
                    refs = [ConstraintRef(entityID: entityIDs[0], role: .center),
                            ConstraintRef(entityID: entityIDs[1], role: .center)]
                } else {
                    return Self.fail(
                        "unsupported_refs",
                        "A distance dimension is a line's length (one line entity), two circle centers, "
                            + "or explicit refs. Supply refs for point-to-point/point-to-line distances.")
                }
            case "angle":
                if entityIDs.count == 2 {
                    let lines = sketch.entities.filter { entityIDs.contains($0.id) }
                    guard lines.count == 2,
                          lines.allSatisfy({ if case .line = $0 { return true }; return false }) else {
                        return Self.fail("unsupported_refs", "An angle between two entities requires two lines.")
                    }
                    refs = entityIDs.map { ConstraintRef(entityID: $0, role: .whole) }
                } else if entityIDs.count == 1,
                          case .arc? = sketch.entities.first(where: { $0.id == entityIDs[0] }) {
                    refs = [ConstraintRef(entityID: entityIDs[0], role: .whole)]
                } else {
                    return Self.fail("unsupported_refs",
                                     "An angle dimension needs two lines, or one arc.")
                }
            case "diameter", "radius":
                guard entityIDs.count == 1,
                      let entity = sketch.entities.first(where: { $0.id == entityIDs[0] }) else {
                    return Self.fail("unsupported_refs", "A \(requestedKind) dimension needs one entity.")
                }
                let isCircle: Bool
                if case .circle = entity { isCircle = true } else { isCircle = false }
                let isArc: Bool
                if case .arc = entity { isArc = true } else { isArc = false }
                guard isCircle || (requestedKind == "radius" && isArc) else {
                    return Self.fail("unsupported_refs",
                                     requestedKind == "diameter"
                                        ? "A diameter dimension needs one circle."
                                        : "A radius dimension needs one circle or arc.")
                }
                refs = [ConstraintRef(entityID: entityIDs[0], role: .whole)]
            case "width", "height":
                guard entityIDs.count == 1,
                      case .rect? = sketch.entities.first(where: { $0.id == entityIDs[0] }) else {
                    return Self.fail("unsupported_refs",
                                     "A \(requestedKind) dimension needs one rectangle.")
                }
                refs = [ConstraintRef(entityID: entityIDs[0], role: .endpointA),
                        ConstraintRef(entityID: entityIDs[0], role: .endpointB)]
            default:
                return Self.fail("bad_kind", "Unsupported dimension kind '\(requestedKind)'.")
            }
        }
        guard !refs.isEmpty else {
            return Self.fail("missing_refs", "setSketchDimension needs at least one reference.")
        }

        let storedValue: Double
        let displayUnit: String
        if requestedKind == "angle" {
            guard value > 0, value < (refs.count == 1 ? 360 : 180) else {
                return Self.fail("bad_value",
                                 "Angle must be in (0, \(refs.count == 1 ? 360 : 180)) degrees.")
            }
            storedValue = value * .pi / 180
            displayUnit = "deg"
        } else {
            guard value > 1e-6 else {
                return Self.fail("bad_value", "\(requestedKind) must be greater than 0 mm.")
            }
            storedValue = value
            displayUnit = "mm"
        }

        let refKey = { (ref: ConstraintRef) in "\(ref.entityID.uuidString):\(ref.role.rawValue)" }
        let expectedRefs = Set(refs.map(refKey))
        var existingIndex: Int?
        if let rawDimension = CADMaterialService.string(args["dimension_id"]) {
            guard let dimensionID = UUID(uuidString: rawDimension),
                  let index = sketch.dimensions.firstIndex(where: { $0.id == dimensionID }) else {
                return Self.fail("unknown_dimension", "No dimension \(rawDimension) in sketch '\(sketch.name)'.")
            }
            let dimension = sketch.dimensions[index]
            guard dimension.kind.rawValue == storedKindName,
                  Set(dimension.refs.map(refKey)) == expectedRefs else {
                return Self.fail(
                    "dimension_mismatch",
                    "Dimension \(rawDimension) is \(dimension.kind.rawValue) and does not reference the "
                        + "requested entities/roles; omit dimension_id to create the requested dimension.")
            }
            existingIndex = index
        } else {
            existingIndex = sketch.dimensions.firstIndex {
                $0.kind.rawValue == storedKindName
                    && Set($0.refs.map(refKey)) == expectedRefs
            }
        }

        if let existingIndex {
            let before = sketch.dimensions[existingIndex]
            let currentDisplay = requestedKind == "angle" ? before.value * 180 / .pi : before.value
            if let rawExpected = args["expected_value"],
               let expected = CADMaterialService.number(rawExpected), expected.isFinite,
               abs(expected - currentDisplay) > 1e-6 {
                return Self.fail(
                    "value_mismatch",
                    "The dimension currently reads \(currentDisplay) \(displayUnit), not the expected "
                        + "\(expected) \(displayUnit). Re-query kind=constraints before editing it.")
            }
            if abs(before.value - storedValue) <= 1e-9 && before.formula == nil {
                return Self.fail("no_change", "The dimension already has that value.")
            }
        }

        var candidate: SketchDimension
        let isNew: Bool
        if let existingIndex {
            candidate = sketch.dimensions[existingIndex]
            candidate.value = storedValue
            candidate.formula = nil
            candidate.displayExpression = nil
            isNew = false
        } else {
            candidate = SketchDimension(kind: DimensionKind(rawValue: storedKindName) ?? .distance,
                                        refs: refs, value: storedValue)
            isNew = true
        }

        var proposed = sketch
        if let existingIndex {
            proposed.dimensions[existingIndex] = candidate
        } else {
            proposed.dimensions.append(candidate)
        }
        if SketchSolverBridge.residualNorm(proposed) > Self.overConstraintTolerance {
            // Name the actual saved relations, not a generic conflict label.
            // A newly proposed dimension is excluded from partner blame; the
            // user needs the existing IDs that already clash in the document.
            let blame = SketchSolverBridge.conflictPartners(
                in: proposed, excludingDimensions: isNew ? [candidate.id] : [])
            let ids = blame.constraintIDs.map(\.uuidString)
                + blame.dimensionIDs.map(\.uuidString)
            let suffix = ids.isEmpty ? "" : " Conflicting relation IDs: "
                + ids.sorted().joined(separator: ", ") + "."
            return Self.fail(
                "constraint_conflict",
                "The driving \(requestedKind) conflicts with the sketch's existing constraints/dimensions. "
                    + "Nothing was changed." + suffix
                    + " Remove or relax the conflicting relationship first.")
        }
        let solved = SketchSolverBridge.solveDimensionEdit(
            proposed, dimension: candidate, tolerance: Self.overConstraintTolerance)
        guard solved.converged, solved.structuralResidual <= Self.overConstraintTolerance else {
            return Self.fail(
                "solve_failed",
                "The solver could not make the sketch satisfy \(requestedKind) = \(value) \(displayUnit); "
                    + "nothing was changed.")
        }
        let changedEntities = zip(sketch.entities, solved.entities).compactMap { before, after in
            before == after ? nil : (before: before, after: after)
        }

        let beforeErrors = document.session.lastEvalErrors
        let beforeChangeCount = document.session.changeCount
        let checkpoint = document.captureEditCheckpoint()
        var commands: [DocumentCommand] = []
        if isNew {
            commands.append(AddSketchDimensionCommand(sketchID: sketchID, dimension: candidate))
        } else if let existingIndex {
            commands.append(UpdateSketchDimensionCommand(
                sketchID: sketchID, before: sketch.dimensions[existingIndex], after: candidate))
        }
        for change in changedEntities {
            commands.append(UpdateSketchEntityCommand(sketchID: sketchID,
                                                      before: change.before, after: change.after))
        }
        guard !commands.isEmpty else {
            return Self.fail("no_change", "The dimension produced no document change.")
        }
        document.session.performWithSketchRebuild(
            commands.count == 1 ? commands[0]
                : CompositeCommand(title: "Dimension", commands: commands),
            sketchID: sketchID)
        if let failure = Self.rollbackIfRebuildBroke(
            document: document, beforeErrors: beforeErrors,
            beforeChangeCount: beforeChangeCount, checkpoint: checkpoint,
            message: "The dimension broke the rebuild; it was rolled back (nothing was kept).") {
            return failure
        }
        guard document.session.changeCount != beforeChangeCount else {
            return Self.fail("no_change", "The dimension produced no document change.")
        }
        let dependents = document.session.document.features.nodes
            .filter { $0.referencedSketchIDs.contains(sketchID) }
            .map { $0.id.raw.uuidString }
        return Self.ok([
            "action": "setSketchDimension",
            "mutated": true,
            "sketch": ["id": sketchID.raw.uuidString, "name": sketch.name],
            "dimension": [
                "id": candidate.id.uuidString,
                "kind": candidate.kind.rawValue,
                "requested_kind": rawKind,
                "refs": candidate.refs.map { ["entity_id": $0.entityID.uuidString, "role": $0.role.rawValue] },
                "value": value,
                "unit": displayUnit,
                "stored_value": candidate.value,
                "stored_unit": candidate.kind == .angle ? "rad" : "mm",
                "created": isNew,
            ],
            "solved_entity_ids": changedEntities.map { $0.after.id.uuidString },
            "dependent_feature_ids": dependents,
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    /// Remove one driving dimension. The relaxed sketch is left as-is, exactly
    /// like the interactive Delete dimension action (undo restores the
    /// dimension at its original index).
    private func removeSketchDimension(_ args: [String: Any]) -> [String: Any] {
        guard let rawSketch = CADMaterialService.string(args["sketch_id"])
            ?? CADMaterialService.string(args["sketchID"])
            ?? CADMaterialService.string(args["sketch"]),
              let sketchUUID = UUID(uuidString: rawSketch) else {
            return Self.fail("missing_sketch", "removeSketchDimension needs sketch_id.")
        }
        let sketchID = SketchID(raw: sketchUUID)
        guard let sketch = document.session.document.sketches.first(where: { $0.id == sketchID }) else {
            return Self.fail("unknown_sketch", "No sketch \(rawSketch) in this document.")
        }
        guard let rawDimension = CADMaterialService.string(args["dimension_id"])
            ?? CADMaterialService.string(args["dimensionID"])
            ?? CADMaterialService.string(args["id"]),
              let dimensionID = UUID(uuidString: rawDimension),
              let index = sketch.dimensions.firstIndex(where: { $0.id == dimensionID }) else {
            return Self.fail("unknown_dimension",
                             "removeSketchDimension needs dimension_id from query kind=constraints.")
        }
        let dimension = sketch.dimensions[index]
        let beforeErrors = document.session.lastEvalErrors
        let beforeChangeCount = document.session.changeCount
        let checkpoint = document.captureEditCheckpoint()
        document.session.performWithSketchRebuild(
            RemoveSketchDimensionCommand(sketchID: sketchID, dimension: dimension, index: index),
            sketchID: sketchID)
        if let failure = Self.rollbackIfRebuildBroke(
            document: document, beforeErrors: beforeErrors,
            beforeChangeCount: beforeChangeCount, checkpoint: checkpoint,
            message: "Removing the dimension broke the rebuild; it was rolled back (nothing was kept).") {
            return failure
        }
        return Self.ok([
            "action": "removeSketchDimension",
            "mutated": document.session.changeCount != beforeChangeCount,
            "sketch": ["id": sketchID.raw.uuidString, "name": sketch.name],
            "removed_dimension": [
                "id": dimension.id.uuidString,
                "kind": dimension.kind.rawValue,
                "value": dimension.value,
            ],
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    // MARK: - Feature history actions

    /// Suppress or restore one feature node. This is the same
    /// `DocumentSession.setSuppressed` the History panel's eye toggle uses:
    /// the flag change and the downstream rebuild are one undo step.
    private func featureSuppress(_ args: [String: Any]) -> [String: Any] {
        guard let node = Self.featureNode(args, document: document.session.document) else {
            return Self.fail("missing_feature", "feature.suppress needs feature_id (UUID from query kind=features).")
        }
        var suppressed: Bool
        if let raw = args["suppressed"] {
            guard let value = CADMaterialService.bool(raw) else {
                return Self.fail("bad_suppressed", "feature.suppress suppressed must be a boolean.")
            }
            suppressed = value
        } else if let raw = args["restore"], let restore = CADMaterialService.bool(raw) {
            suppressed = !restore
        } else {
            return Self.fail("missing_suppressed",
                             "feature.suppress needs suppressed: true to hide the step or false to restore it.")
        }
        if node.suppressed == suppressed {
            return Self.fail("no_change",
                             "Feature '\(node.name)' is already \(suppressed ? "suppressed" : "active").")
        }
        let dependents = Self.dependentFeatureIDs(of: node, in: document.session.document)
        let beforeErrors = document.session.lastEvalErrors
        let beforeChangeCount = document.session.changeCount
        let checkpoint = document.captureEditCheckpoint()
        document.session.setSuppressed(node.id, suppressed)
        if let failure = Self.rollbackIfRebuildBroke(
            document: document, beforeErrors: beforeErrors,
            beforeChangeCount: beforeChangeCount, checkpoint: checkpoint,
            message: "\(suppressed ? "Suppressing" : "Restoring") '\(node.name)' broke the rebuild; "
                + "it was rolled back (nothing was kept).") {
            return failure
        }
        return Self.ok(Self.featureReply(
            action: "feature.suppress", nodeID: node.id, suppressed: suppressed,
            document: document.session.document, dependents: dependents,
            revision: document.revision, changeCount: document.session.changeCount,
            canUndo: document.session.undoStack.canUndo, canRedo: document.session.undoStack.canRedo))
    }

    /// Delete one feature node after a dependency check. A node whose output
    /// bodies are consumed by later features is refused unless `force: true`;
    /// even then the deletion must rebuild without new errors or it is rolled
    /// back. This keeps a model from silently breaking a downstream fillet,
    /// boolean or drawing.
    private func featureDelete(_ args: [String: Any]) -> [String: Any] {
        guard let node = Self.featureNode(args, document: document.session.document) else {
            return Self.fail("missing_feature", "feature.delete needs feature_id (UUID from query kind=features).")
        }
        let dependents = Self.dependentFeatureIDs(of: node, in: document.session.document)
        let force = CADMaterialService.bool(args["force"]) ?? false
        if !dependents.isEmpty && !force {
            let names = dependents.compactMap { id in
                document.session.document.features.node(FeatureID(raw: id))?.name
            }
            return [
                "ok": false,
                "error": "has_dependents",
                "message": "Feature '\(node.name)' produces bodies used by later features: "
                    + names.joined(separator: ", ")
                    + ". Delete or reorder those dependents first, or pass force:true only if this is intended; "
                    + "the deletion still rolls back if it breaks the rebuild.",
                "dependent_feature_ids": dependents.map(\.uuidString),
            ]
        }
        let beforeErrors = document.session.lastEvalErrors
        let beforeChangeCount = document.session.changeCount
        let checkpoint = document.captureEditCheckpoint()
        document.session.deleteFeature(node.id)
        if let failure = Self.rollbackIfRebuildBroke(
            document: document, beforeErrors: beforeErrors,
            beforeChangeCount: beforeChangeCount, checkpoint: checkpoint,
            message: "Deleting '\(node.name)' broke the rebuild; it was rolled back (nothing was kept).") {
            return failure
        }
        guard document.session.changeCount != beforeChangeCount else {
            return Self.fail("no_change", "Deleting '\(node.name)' produced no document change.")
        }
        return Self.ok([
            "action": "feature.delete",
            "mutated": true,
            "deleted_feature": ["id": node.id.raw.uuidString, "name": node.name],
            "forced": force,
            "dependent_feature_ids": dependents.map(\.uuidString),
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    /// Reorder one feature in history after verifying that every body
    /// dependency still evaluates in the new order. The same
    /// `DocumentSession.moveFeature` the History drag uses performs the
    /// rebuild as one undo step.
    private func featureMove(_ args: [String: Any]) -> [String: Any] {
        guard let node = Self.featureNode(args, document: document.session.document) else {
            return Self.fail("missing_feature", "feature.move needs feature_id (UUID from query kind=features).")
        }
        guard let rawIndex = args["to_index"] ?? args["index"] ?? args["to"],
              let target = CADMaterialService.number(rawIndex),
              target.rounded() == target else {
            return Self.fail("missing_index",
                             "feature.move needs to_index as a 0-based history position from query kind=features.")
        }
        let nodes = document.session.document.features.nodes
        guard let from = nodes.firstIndex(where: { $0.id == node.id }) else {
            return Self.fail("unknown_feature", "Feature '\(node.name)' is no longer in the history.")
        }
        let clamped = min(max(Int(target), 0), nodes.count - 1)
        guard clamped != from else {
            return Self.fail("no_change", "Feature '\(node.name)' is already at position \(from).")
        }
        // Resolve the CURRENT history's input versions before considering the
        // new order. Resolving against the candidate order would silently
        // change which in-place edit a later feature consumes.
        let dependencies = Self.resolvedBodyDependencies(in: nodes)
        var reordered = nodes
        reordered.remove(at: from)
        reordered.insert(node, at: clamped)
        var producerPosition: [FeatureID: Int] = [:]
        for (index, candidate) in reordered.enumerated() {
            producerPosition[candidate.id] = index
        }
        var offenders: [[String: Any]] = []
        for (index, candidate) in reordered.enumerated() {
            for ref in dependencies[candidate.id] ?? [] {
                // The producer here is the original order's preceding writer,
                // not necessarily the legacy BodyRef.producer. Several native
                // operations reserve fresh output ids but actually overwrite
                // the consumed body, leaving later refs bound to its creator.
                guard let producerIndex = producerPosition[ref.producer],
                      producerIndex >= index else { continue }
                offenders.append([
                    "feature_id": candidate.id.raw.uuidString,
                    "feature": candidate.name,
                    "body_id": ref.bodyID.raw.uuidString,
                    "producer_id": reordered[producerIndex].id.raw.uuidString,
                    "position": index,
                    "producer_position": producerIndex,
                ])
            }
        }
        if !offenders.isEmpty {
            return [
                "ok": false,
                "error": "dependency_order",
                "message": "That position would evaluate a feature before the body it references. "
                    + "Nothing was moved; move it after its producer and before its dependents.",
                "violations": offenders,
            ]
        }
        let dependents = Self.dependentFeatureIDs(of: node, in: document.session.document)
        let beforeErrors = document.session.lastEvalErrors
        let beforeChangeCount = document.session.changeCount
        let checkpoint = document.captureEditCheckpoint()
        document.session.moveFeature(node.id, to: clamped)
        if let failure = Self.rollbackIfRebuildBroke(
            document: document, beforeErrors: beforeErrors,
            beforeChangeCount: beforeChangeCount, checkpoint: checkpoint,
            message: "Moving '\(node.name)' broke the rebuild; it was rolled back (nothing was kept).") {
            return failure
        }
        guard document.session.changeCount != beforeChangeCount else {
            return Self.fail("no_change", "Moving '\(node.name)' produced no document change.")
        }
        return Self.ok([
            "action": "feature.move",
            "mutated": true,
            "feature_id": node.id.raw.uuidString,
            "name": node.name,
            "from_index": from,
            "to_index": clamped,
            "dependent_feature_ids": dependents.map(\.uuidString),
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    // MARK: - Variables and formula binding

    /// A precise, pre-commit refusal for a variable/expression edit.
    private struct VariableEditFailure: Error, Equatable {
        var code: String
        var message: String
        init(_ code: String, _ message: String) {
            self.code = code
            self.message = message
        }
    }

    private static let variableCreateKeys: Set<String> = [
        "action", "revision", "expected_revision", "name", "expression",
    ]
    private static let variableUpdateKeys: Set<String> = [
        "action", "revision", "expected_revision",
        "variable_id", "variableID", "id", "name", "expression", "expected_expression",
    ]
    private static let variableDeleteKeys: Set<String> = [
        "action", "revision", "expected_revision", "variable_id", "variableID", "id",
    ]
    private static let featureExpressionKeys: Set<String> = [
        "action", "revision", "expected_revision",
        "feature_id", "featureID", "id", "parameter", "expression", "expected_expression",
    ]

    /// Exact-action refusal for a mistyped field: a typo must never silently
    /// drop a safety fence (`expected_expression`) or a value.
    private static func rejectUnknownArguments(_ args: [String: Any], allowed: Set<String>,
                                               action: String) -> [String: Any]? {
        let unknown = args.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            return fail("unknown_argument",
                        "Unknown argument(s) \(unknown.joined(separator: ", ")) for \(action). Allowed: "
                            + allowed.sorted().joined(separator: ", ") + ".")
        }
        return nil
    }

    private func readOnlyRefusal() -> [String: Any]? {
        CADServiceOperations.readOnlyRefusal(document: document, kind: "parameter", action: "update")
    }

    /// Commit one variable-side command set through the session's atomic
    /// transaction and restore the EXACT checkpoint (document + undo/redo
    /// histories) when the downstream rebuild introduces a new FeatureError.
    /// Used by create, update and delete alike: a variable edit must never be
    /// accepted while a feature it drives has failed geometry. Returns nil on
    /// success, or the structured refusal to return to the caller.
    private func performVariableEdit(_ commands: [DocumentCommand],
                                     title: String) -> [String: Any]? {
        let beforeErrors = document.session.lastEvalErrors
        let beforeChangeCount = document.session.changeCount
        let checkpoint = document.captureEditCheckpoint()
        guard document.session.performVariableTransaction(commands, title: title) else {
            return Self.rebuildRejection(document) ?? Self.fail(
                "no_change", "The variable edit produced no document change.")
        }
        return Self.rollbackIfRebuildBroke(
            document: document, beforeErrors: beforeErrors,
            beforeChangeCount: beforeChangeCount, checkpoint: checkpoint,
            message: "The variable edit broke the rebuild; it was rolled back (nothing was kept).")
    }

    // MARK: Variable add / update / delete

    private func variableCreate(_ args: [String: Any]) -> [String: Any] {
        if let failure = Self.rejectUnknownArguments(args, allowed: Self.variableCreateKeys,
                                                     action: "variable.create") {
            return failure
        }
        if let refusal = readOnlyRefusal() { return refusal }
        guard let rawName = CADMaterialService.string(args["name"]),
              let rawExpression = CADMaterialService.string(args["expression"]) else {
            return Self.fail("missing_variable",
                             "variable.create needs name and expression (both strings).")
        }
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let expression = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !expression.isEmpty else {
            return Self.fail("missing_variable",
                             "variable.create needs a non-empty name and expression.")
        }
        let previous = document.session.document.variables
        let variable = Variable(name: name, expression: expression)
        let prospective = previous + [variable]
        if let failure = Self.validateVariableChange(
            previous: previous, prospective: prospective, focus: [variable.id]) {
            return Self.fail(failure.code, failure.message)
        }
        let resolved = VariableTable.resolve(prospective)
        guard let resolvedVariable = resolved.resolved.last,
              resolved.errors[variable.id] == nil else {
            return Self.fail("invalid_expression",
                             "Variable '\(name)' could not be resolved; nothing was changed.")
        }
        let command = AddVariableCommand(variable: resolvedVariable)
        if let failure = performVariableEdit([command], title: "Add Variable") {
            return failure
        }
        let row = Self.variableRow(for: resolvedVariable.id,
                                   in: document.session.document)
            ?? ["id": resolvedVariable.id.raw.uuidString,
                "name": resolvedVariable.name,
                "expression": resolvedVariable.expression,
                "value": resolvedVariable.value,
                "unit": "unitless"]
        return Self.ok([
            "action": "variable.create",
            "mutated": true,
            "variable": row,
            "variable_count": document.session.document.variables.count,
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    private func variableUpdate(_ args: [String: Any]) -> [String: Any] {
        if let failure = Self.rejectUnknownArguments(args, allowed: Self.variableUpdateKeys,
                                                     action: "variable.update") {
            return failure
        }
        if let refusal = readOnlyRefusal() { return refusal }
        guard let rawID = CADMaterialService.string(args["variable_id"])
            ?? CADMaterialService.string(args["variableID"])
            ?? CADMaterialService.string(args["id"]),
              let uuid = UUID(uuidString: rawID),
              let targetIndex = document.session.document.variables.firstIndex(where: {
                  $0.id.raw == uuid
              }) else {
            return Self.fail("unknown_variable",
                             "variable.update needs variable_id from query kind=variables.")
        }
        let target = document.session.document.variables[targetIndex]
        if let rawExpected = args["expected_expression"] {
            guard let expected = CADMaterialService.string(rawExpected) else {
                return Self.fail("bad_expected_expression",
                                 "expected_expression must be the current expression string from query kind=variables.")
            }
            guard expected == target.expression else {
                return Self.fail(
                    "expression_mismatch",
                    "Variable '\(target.name)' currently has expression \"\(target.expression)\", not "
                        + "the expected \"\(expected)\". Re-query kind=variables before editing it.")
            }
        }
        let newName: String
        if let rawName = args["name"] {
            guard let text = CADMaterialService.string(rawName) else {
                return Self.fail("bad_name", "name must be a string.")
            }
            newName = text.trimmingCharacters(in: .whitespaces)
            guard !newName.isEmpty else {
                return Self.fail("bad_name", "name must not be empty.")
            }
        } else {
            newName = target.name
        }
        let newExpression: String
        if args["expression"] != nil {
            guard let text = CADMaterialService.string(args["expression"]) else {
                return Self.fail("bad_expression", "expression must be a string.")
            }
            newExpression = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newExpression.isEmpty else {
                return Self.fail("bad_expression", "expression must not be empty.")
            }
        } else {
            newExpression = target.expression
        }
        let oldName = target.name.trimmingCharacters(in: .whitespaces)
        let renamed = newName != oldName
        let expressionChanged = newExpression != target.expression
        guard renamed || expressionChanged else {
            return Self.fail("no_change",
                             "Variable '\(target.name)' already has that name and expression.")
        }

        let previous = document.session.document.variables
        let oldValues = document.session.variableValues()
        var prospective = previous
        for index in prospective.indices {
            if prospective[index].id == target.id {
                prospective[index].name = newName
                prospective[index].expression = newExpression
            } else if renamed {
                if let rewritten = Self.rewriteIdentifier(
                    prospective[index].expression, from: oldName, to: newName) {
                    prospective[index].expression = rewritten
                }
            }
        }
        if let failure = Self.validateVariableChange(
            previous: previous, prospective: prospective, focus: [target.id]) {
            return Self.fail(failure.code, failure.message)
        }
        let resolved = VariableTable.resolve(prospective)
        for index in prospective.indices where index < resolved.resolved.count {
            prospective[index].value = resolved.resolved[index].value
        }
        guard resolved.errors[target.id] == nil else {
            return Self.fail("invalid_expression",
                             "Variable '\(newName)' could not be resolved; nothing was changed.")
        }
        let values = resolved.values

        var commands: [DocumentCommand] = []
        for (before, after) in zip(previous, prospective)
        where before.name != after.name || before.expression != after.expression {
            commands.append(EditVariableCommand(before: before, after: after))
        }

        var rewrittenFeatureIDs: [String] = []
        var rewrittenDimensionIDs: [String] = []
        var rewrittenPlaneIDs: [String] = []
        if renamed {
            for node in document.session.document.features.nodes {
                guard let after = DocumentSession.rewrittenKind(node.kind, rewriting: { formula in
                    Self.rewriteIdentifier(formula, from: oldName, to: newName)
                }) else { continue }
                if let failure = Self.rewrittenExpressionsFailure(
                    before: node.kind, after: after, featureName: node.name,
                    oldValues: oldValues, newValues: values) {
                    return Self.fail(failure.code, failure.message)
                }
                commands.append(EditFeatureCommand(
                    featureID: node.id, before: node.kind, after: after))
                rewrittenFeatureIDs.append(node.id.raw.uuidString)
            }
            for plane in document.session.document.planes {
                guard case var .offset(definition)? = plane.definition,
                      let formula = definition.distance.formula,
                      let rewritten = Self.rewriteIdentifier(formula, from: oldName, to: newName),
                      rewritten != formula else { continue }
                if ExpressionEvaluator.evaluate(rewritten, variables: values) == nil,
                   ExpressionEvaluator.evaluate(formula, variables: oldValues) != nil {
                    return Self.fail("unsupported_rewrite",
                        "Renaming '\(oldName)' would make plane \(plane.id.raw.uuidString) unreadable. Nothing was changed.")
                }
                definition.distance.formula = rewritten
                commands.append(EditConstructionPlaneDefinitionCommand(
                    planeID: plane.id, before: plane.definition, after: .offset(definition)))
                rewrittenPlaneIDs.append(plane.id.raw.uuidString)
            }
            for sketch in document.session.document.sketches {
                for dimension in sketch.dimensions {
                    guard let formula = dimension.formula,
                          let rewritten = Self.rewriteIdentifier(
                            formula, from: oldName, to: newName),
                          rewritten != formula else { continue }
                    if ExpressionEvaluator.evaluate(rewritten, variables: values) == nil,
                       ExpressionEvaluator.evaluate(formula, variables: oldValues) != nil {
                        return Self.fail(
                            "unsupported_rewrite",
                            "Renaming '\(oldName)' would make the \(dimension.kind.rawValue) "
                                + "dimension \(dimension.id.uuidString) unreadable ('\(rewritten)'). "
                                + "Nothing was changed.")
                    }
                    var after = dimension
                    after.formula = rewritten
                    commands.append(UpdateSketchDimensionCommand(
                        sketchID: sketch.id, before: dimension, after: after))
                    rewrittenDimensionIDs.append(dimension.id.uuidString)
                }
            }
        }
        guard !commands.isEmpty else {
            return Self.fail("no_change", "The variable edit produced no document change.")
        }
        if let failure = performVariableEdit(
            commands, title: renamed ? "Rename Variable" : "Edit Variable") {
            return failure
        }
        let row = Self.variableRow(for: target.id, in: document.session.document) ?? [:]
        var reply: [String: Any] = [
            "action": "variable.update",
            "mutated": true,
            "variable": row,
            "rewritten_feature_ids": rewrittenFeatureIDs,
            "rewritten_dimension_ids": rewrittenDimensionIDs,
            "rewritten_plane_ids": rewrittenPlaneIDs,
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ]
        if renamed { reply["renamed_from"] = oldName }
        return Self.ok(reply)
    }

    private func variableDelete(_ args: [String: Any]) -> [String: Any] {
        if let failure = Self.rejectUnknownArguments(args, allowed: Self.variableDeleteKeys,
                                                     action: "variable.delete") {
            return failure
        }
        if let refusal = readOnlyRefusal() { return refusal }
        guard let rawID = CADMaterialService.string(args["variable_id"])
            ?? CADMaterialService.string(args["variableID"])
            ?? CADMaterialService.string(args["id"]),
              let uuid = UUID(uuidString: rawID),
              let index = document.session.document.variables.firstIndex(where: {
                  $0.id.raw == uuid
              }) else {
            return Self.fail("unknown_variable",
                             "variable.delete needs variable_id from query kind=variables.")
        }
        let variable = document.session.document.variables[index]
        let name = variable.name.trimmingCharacters(in: .whitespaces)
        let dependents = Self.variableDependents(of: name, in: document.session.document)
        let count = dependents["count"] as? Int ?? 0
        if count > 0 {
            let featureIDs = (dependents["feature_parameters"] as? [[String: Any]] ?? [])
                .compactMap { $0["feature_id"] as? String }
            let dimensionIDs = (dependents["sketch_dimensions"] as? [[String: Any]] ?? [])
                .compactMap { $0["dimension_id"] as? String }
            let variableIDs = dependents["variable_ids"] as? [String] ?? []
            return [
                "ok": false,
                "error": "variable_in_use",
                "message": "Variable '\(name)' is still referenced by \(count) formula(s). "
                    + "Rebind or delete those first; nothing was changed.",
                "variable": ["id": variable.id.raw.uuidString, "name": variable.name],
                "dependents": dependents,
                "dependent_variable_ids": variableIDs,
                "dependent_feature_ids": Array(Set(featureIDs)).sorted(),
                "dependent_sketch_dimension_ids": Array(Set(dimensionIDs)).sorted(),
                "dependent_plane_ids": dependents["plane_ids"] ?? [],
                "revision": document.revision,
                "change_count": document.session.changeCount,
            ]
        }
        let command = RemoveVariableCommand(index: index, variable: variable)
        if let failure = performVariableEdit([command], title: "Delete Variable") {
            return failure
        }
        return Self.ok([
            "action": "variable.delete",
            "mutated": true,
            "removed_variable": [
                "id": variable.id.raw.uuidString,
                "name": variable.name,
                "expression": variable.expression,
            ],
            "dependents": dependents,
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    // MARK: Feature expression binding

    /// Bind a variable/function expression to ONE existing formula-capable
    /// scalar. The expression is authored in the parameter's PUBLIC unit; a
    /// radian-persisted parameter (`.rotateFace.angle`) is converted exactly
    /// once and stores an explicit `radians(...)` formula so later variable
    /// fan-out never interprets degrees as radians.
    private func featureSetExpression(_ args: [String: Any]) -> [String: Any] {
        if let failure = Self.rejectUnknownArguments(args, allowed: Self.featureExpressionKeys,
                                                     action: "feature.setExpression") {
            return failure
        }
        if let refusal = readOnlyRefusal() { return refusal }
        guard let rawFeature = CADMaterialService.string(args["feature_id"])
            ?? CADMaterialService.string(args["featureID"])
            ?? CADMaterialService.string(args["id"]),
              let featureUUID = UUID(uuidString: rawFeature),
              let node = document.session.document.features.node(FeatureID(raw: featureUUID)) else {
            return Self.fail("missing_feature",
                             "feature.setExpression needs feature_id from query kind=features.")
        }
        guard let rawParameter = CADMaterialService.string(args["parameter"]),
              !rawParameter.trimmingCharacters(in: .whitespaces).isEmpty else {
            return Self.fail("missing_parameter",
                             "feature.setExpression needs parameter (the name query kind=features reports).")
        }
        let parameter = Self.normalizedExpressionParameter(rawParameter)
        let slots = DocumentSession.expressionSlots(in: node.kind)
        guard let slot = slots.first(where: { $0.name == parameter }) else {
            let descriptor = Self.describe(node, document: document.session.document)
            let known = (descriptor["parameters"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
            if known.contains(parameter) {
                return Self.fail(
                    "unsupported_parameter",
                    "Feature '\(node.name)' parameter '\(parameter)' has no formula-capable "
                        + "stored expression in this document model; it is not changed to avoid a "
                        + "value-only edit that loses design intent. Formula-capable parameters: "
                        + (slots.isEmpty ? "none for this feature kind"
                            : slots.map(\.name).joined(separator: ", ")) + ".")
            }
            return Self.fail(
                "unknown_parameter",
                "Feature '\(node.name)' has no parameter '\(parameter)'. Parameters: "
                    + known.sorted().joined(separator: ", ") + ".")
        }
        guard let rawExpression = CADMaterialService.string(args["expression"]) else {
            return Self.fail("missing_expression",
                             "feature.setExpression needs expression (a number or variable/formula string).")
        }
        let expression = rawExpression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expression.isEmpty else {
            return Self.fail("missing_expression", "feature.setExpression needs a non-empty expression.")
        }
        if let rawExpected = args["expected_expression"] {
            guard let expected = CADMaterialService.string(rawExpected) else {
                return Self.fail("bad_expected_expression",
                                 "expected_expression must be the current formula string from query kind=features.")
            }
            let current = slot.expr.formula ?? ""
            guard expected == current else {
                return Self.fail(
                    "expression_mismatch",
                    "Feature '\(node.name)' parameter '\(slot.name)' currently has formula "
                        + (current.isEmpty ? "(none)" : "\"\(current)\"")
                        + ", not the expected \"\(expected)\". Re-query kind=features before editing it.")
            }
        }

        let values = document.session.variableValues()
        let publicValue: Double
        switch Self.evaluateExpression(expression, values: values) {
        case .failure(let failure):
            return Self.fail(failure.code, failure.message)
        case .success(let value):
            publicValue = value
        }
        // Validate the value the expression RESOLVES to through the SAME
        // public-unit entry point a numeric edit uses (`updated` converts a
        // public-degree angle to stored radians exactly once). The formula
        // text is the actual change, so a formula that evaluates to the
        // current value (e.g. 6 -> variable boreDepth = 6) must not be refused
        // as a numeric no-op.
        let numericKind: FeatureKind
        switch Self.updated(node.kind,
                            changes: [slot.name: publicValue],
                            requireChange: false,
                            pilotDiameter: Self.placementPilotDiameter(
                                node, document: document.session.document)) {
        case .failure(let error):
            return Self.fail("invalid_parameter_value", error.message)
        case .success(let kind):
            numericKind = kind
        }
        guard let numericSlot = DocumentSession.expressionSlot(in: numericKind, named: slot.name),
              let finalKindWithValue = DocumentSession.replacingExpression(
                in: numericKind, named: slot.name,
                with: Expr(value: numericSlot.expr.value,
                           formula: Self.storedFormula(
                            for: expression, slot: slot))) else {
            return Self.fail("unsupported_parameter",
                             "Feature '\(node.name)' parameter '\(slot.name)' cannot store a formula.")
        }
        guard let finalSlot = DocumentSession.expressionSlot(
            in: finalKindWithValue, named: slot.name) else {
            return Self.fail("unsupported_parameter",
                             "Feature '\(node.name)' parameter '\(slot.name)' cannot store a formula.")
        }
        guard finalSlot.expr != slot.expr else {
            return Self.fail("no_change",
                             "Feature '\(node.name)' parameter '\(slot.name)' already has that expression.")
        }

        let beforeErrors = document.session.lastEvalErrors
        let beforeChangeCount = document.session.changeCount
        let checkpoint = document.captureEditCheckpoint()
        document.session.editFeature(node.id, to: finalKindWithValue,
                                     title: Self.editTitle(for: node.kind))
        if let failure = Self.rollbackIfRebuildBroke(
            document: document, beforeErrors: beforeErrors,
            beforeChangeCount: beforeChangeCount, checkpoint: checkpoint,
            message: "The expression broke the rebuild; it was rolled back (nothing was kept).") {
            return failure
        }
        guard document.session.changeCount != beforeChangeCount else {
            return Self.fail("no_change", "The expression produced no document change.")
        }
        let descriptor = document.session.document.features.node(node.id).map {
            Self.describe($0, document: document.session.document)
        } ?? [:]
        var applied: [String: Any] = [
            "parameter": slot.name,
            "expression": expression,
            "value": finalSlot.publicValue,
            "unit": finalSlot.unit,
            "stored_value": finalSlot.expr.value,
            "stored_unit": finalSlot.storedUnit,
            "converted": finalSlot.storedScale != 1,
        ]
        if let formula = finalSlot.expr.formula { applied["formula"] = formula }
        return Self.ok([
            "action": "feature.setExpression",
            "mutated": true,
            "feature": descriptor,
            "applied": applied,
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    /// Query view of one stored formula in both units.
    ///
    /// A radian-persisted public-degree parameter needs a PUBLIC-degree source
    /// for callers. Only an EXACT whole-expression `radians(<source>)` call can
    /// be inverted safely: `radians(a) + sin(b)` also starts with `radians(`
    /// and ends with `)`, but its outer expression is radians. For that legacy
    /// case `source_expression` stays null (the radian source is not a degree
    /// source) and `public_expression` is a clearly-marked derived equivalent
    /// `(<stored>) * 180 / pi()`, which is valid syntax for the existing
    /// evaluator. The exact stored text remains in `formula` for the
    /// `expected_expression` fence.
    private struct PublicExpressionView {
        var sourceExpression: Any
        var sourceExpressionUnit: Any
        var publicExpression: Any
        var publicExpressionUnit: Any
        var publicExpressionDerived: Bool
    }

    private static func publicExpressionView(
        for slot: DocumentSession.FeatureExpressionSlot
    ) -> PublicExpressionView {
        guard let formula = slot.expr.formula else {
            return PublicExpressionView(
                sourceExpression: NSNull(), sourceExpressionUnit: NSNull(),
                publicExpression: NSNull(), publicExpressionUnit: NSNull(),
                publicExpressionDerived: false)
        }
        if slot.storedUnit == slot.unit {
            return PublicExpressionView(
                sourceExpression: formula, sourceExpressionUnit: slot.unit,
                publicExpression: formula, publicExpressionUnit: slot.unit,
                publicExpressionDerived: false)
        }
        if let body = wholeRadiansCallArgument(formula) {
            return PublicExpressionView(
                sourceExpression: body, sourceExpressionUnit: slot.unit,
                publicExpression: body, publicExpressionUnit: slot.unit,
                publicExpressionDerived: false)
        }
        return PublicExpressionView(
            sourceExpression: NSNull(), sourceExpressionUnit: NSNull(),
            publicExpression: "(\(formula)) * 180 / pi()",
            publicExpressionUnit: slot.unit,
            publicExpressionDerived: true)
    }

    /// The argument of an EXACT whole-expression `radians(<argument>)` call.
    ///
    /// The closing parenthesis must be the last non-space character and must
    /// match the opening one, so `radians(a) + sin(b)` is NOT unwrapped (its
    /// first call closes early). Nested parentheses inside the argument are
    /// balanced. No new evaluator is involved: this is the same token/operator
    /// syntax the stored formula already uses.
    private static func wholeRadiansCallArgument(_ formula: String) -> String? {
        let chars = Array(formula)
        var index = 0
        while index < chars.count, chars[index] == " " { index += 1 }
        let name = Array("radians")
        guard index + name.count <= chars.count,
              Array(chars[index..<(index + name.count)]) == name else { return nil }
        index += name.count
        while index < chars.count, chars[index] == " " { index += 1 }
        guard index < chars.count, chars[index] == "(" else { return nil }
        index += 1
        let bodyStart = index
        var depth = 1
        var closeIndex: Int?
        while index < chars.count {
            let character = chars[index]
            if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 {
                    closeIndex = index
                    break
                }
            }
            index += 1
        }
        guard let closeIndex else { return nil }
        var trailing = closeIndex + 1
        while trailing < chars.count, chars[trailing] == " " { trailing += 1 }
        guard trailing == chars.count else { return nil }
        let body = String(chars[bodyStart..<closeIndex])
            .trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? nil : body
    }

    /// Public formula source -> persisted `Expr.formula`.
    ///
    /// Most parameters persist the same text. A radian-persisted public-degree
    /// parameter must NOT persist the degree source unchanged: the existing
    /// fan-out evaluates a stored formula in the stored unit, so the explicit
    /// `radians(...)` conversion is part of the stored source. This keeps the
    /// user's expression intact inside the conversion.
    private static func storedFormula(for expression: String,
                                      slot: DocumentSession.FeatureExpressionSlot) -> String? {
        guard !ExpressionEvaluator.identifiers(in: expression).isEmpty else { return nil }
        if slot.unit == "deg", slot.storedUnit == "rad" {
            return "radians(\(expression))"
        }
        return expression
    }

    private static func normalizedExpressionParameter(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        if value == "taperangle" { value = "taper_angle" }
        if value == "totalangle" { value = "total_angle" }
        return value
    }

    // MARK: Variable validation

    /// Validate the whole prospective table BEFORE any command is built.
    ///
    /// Refuses: invalid/duplicate names, unknown functions, unresolved or
    /// forward references, cycles, and any NEW resolution error on a variable
    /// that resolved before (a later dependent must not silently break).
    private static func validateVariableChange(
        previous: [Variable],
        prospective: [Variable],
        focus: Set<VariableID>
    ) -> VariableEditFailure? {
        let oldErrors = VariableTable.resolve(previous).errors
        let trimmedNames = prospective.map { $0.name.trimmingCharacters(in: .whitespaces) }

        // 1. Name validity + case-insensitive uniqueness for the edited rows.
        var firstIndexByName: [String: Int] = [:]
        for (index, name) in trimmedNames.enumerated() where !name.isEmpty {
            guard VariableTable.isValidName(name) else {
                if focus.contains(prospective[index].id) {
                    return VariableEditFailure(
                        "invalid_name",
                        "\"\(prospective[index].name)\" isn't a valid variable name. Use a letter or "
                            + "underscore first, then letters/digits/underscore (max 100), and no "
                            + "leading \"__\".")
                }
                continue
            }
            let key = name.lowercased()
            if let existing = firstIndexByName[key], existing != index {
                let involved = focus.contains(prospective[index].id)
                    || focus.contains(prospective[existing].id)
                if involved {
                    return VariableEditFailure(
                        "duplicate_name",
                        "A variable named \"\(name)\" already exists (names are case-insensitive).")
                }
            } else {
                firstIndexByName[key] = index
            }
        }

        // 2. Cycles. A cycle that only involves variables already in error was
        // not introduced by this edit and must not block an unrelated change.
        if let cycle = firstVariableCycle(in: prospective) {
            let names = cycle.map { prospective[$0].name }
            let touchesThisEdit = cycle.contains { index in
                focus.contains(prospective[index].id)
                    || oldErrors[prospective[index].id] == nil
            }
            if touchesThisEdit {
                return VariableEditFailure(
                    "cyclic_reference",
                    "The variables form a cycle: \(names.joined(separator: " -> ")). "
                        + "A variable may only reference earlier variables. Nothing was changed.")
            }
        }

        // 3. Precise diagnostics for the edited variable's own expression.
        for (index, variable) in prospective.enumerated() where focus.contains(variable.id) {
            if let failure = expressionFailure(
                variable.expression, variableName: variable.name,
                focusIndex: index, variables: prospective) {
                return failure
            }
        }

        // 4. Any newly introduced resolver error (downstream breakage).
        let newErrors = VariableTable.resolve(prospective).errors
        for (id, message) in newErrors where oldErrors[id] == nil {
            let name = prospective.first { $0.id == id }?.name ?? id.raw.uuidString
            let code: String
            if message.hasPrefix("Invalid name") {
                code = "invalid_name"
            } else if message.hasPrefix("Duplicate name") {
                code = "duplicate_name"
            } else if message.contains("Unknown or forward reference") {
                code = "unresolved_reference"
            } else {
                code = "invalid_expression"
            }
            return VariableEditFailure(
                code,
                "Variable '\(name)' would become invalid: \(message). Nothing was changed.")
        }
        return nil
    }

    /// Token-aware, parser-compatible diagnostics for one variable expression.
    /// Uses `ExpressionEvaluator.identifiers` (real tokens, not substrings) and
    /// the same creation-order value map the resolver uses.
    private static func expressionFailure(
        _ raw: String,
        variableName: String,
        focusIndex: Int,
        variables: [Variable]
    ) -> VariableEditFailure? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return VariableEditFailure(
                "invalid_expression",
                "Variable '\(variableName)' needs a non-empty expression.")
        }
        let tokens = identifierTokens(in: text)
        let unknownCalls = Set(tokens.filter(\.isCall).map(\.text))
            .subtracting(ExpressionEvaluator.functionNames)
        if let unknown = unknownCalls.sorted().first {
            return VariableEditFailure(
                "unknown_function",
                "Unknown function '\(unknown)' in \"\(text)\". Supported functions: "
                    + ExpressionEvaluator.functionNames.sorted().joined(separator: ", ") + ".")
        }
        var indexByName: [String: Int] = [:]
        for (index, variable) in variables.enumerated() {
            let name = variable.name.trimmingCharacters(in: .whitespaces)
            if indexByName[name] == nil { indexByName[name] = index }
        }
        let references = ExpressionEvaluator.identifiers(in: text)
        for name in references.sorted() {
            if let index = indexByName[name] {
                if index == focusIndex {
                    return VariableEditFailure(
                        "cyclic_reference",
                        "Variable '\(variableName)' cannot reference itself. Nothing was changed.")
                }
                if index > focusIndex {
                    return VariableEditFailure(
                        "forward_reference",
                        "Variable '\(variableName)' references '\(name)', which is defined later. "
                            + "A variable may only reference earlier variables.")
                }
            } else if !ExpressionEvaluator.functionNames.contains(name) {
                let unitHint = NumericParsing.trailingUnit(in: text) == name
                    ? " A trailing unit suffix is not a variable; variables are unitless scalars."
                    : ""
                return VariableEditFailure(
                    "unresolved_reference",
                    "Variable '\(variableName)' references unknown variable '\(name)' in \"\(text)\". "
                        + "Create it first (variables resolve in creation order)." + unitHint)
            }
        }
        // A function library name used bare is a value reference, not a call.
        // A variable may legally own that name; the evaluator resolves the bare
        // token to the variable, so creation-order/cycle checks still apply.
        for token in tokens where !token.isCall {
            guard ExpressionEvaluator.functionNames.contains(token.text) else { continue }
            if let index = indexByName[token.text] {
                if index == focusIndex {
                    return VariableEditFailure(
                        "cyclic_reference",
                        "Variable '\(variableName)' cannot reference itself. Nothing was changed.")
                }
                if index > focusIndex {
                    return VariableEditFailure(
                        "forward_reference",
                        "Variable '\(variableName)' references '\(token.text)', which is defined "
                            + "later. A variable may only reference earlier variables.")
                }
            } else {
                return VariableEditFailure(
                    "unknown_function",
                    "'\(token.text)' is a function in \"\(text)\"; write \(token.text)(...) "
                        + "instead of using it as a value.")
            }
        }
        let earlier = VariableTable.resolve(Array(variables.prefix(focusIndex))).values
        if let value = ExpressionEvaluator.evaluate(text, variables: earlier), value.isFinite {
            return nil
        }
        let validation = ExpressionEvaluator.validationMessage(text, variables: earlier) ?? ""
        if validation.lowercased().contains("divide by zero") {
            return VariableEditFailure(
                "divided_by_zero",
                "Expression \"\(text)\" divides by zero. Nothing was changed.")
        }
        return VariableEditFailure(
            "invalid_expression",
            "Cannot evaluate \"\(text)\" for variable '\(variableName)'. "
                + (validation.isEmpty ? "Fix the arithmetic and references." : validation))
    }

    /// Evaluate one feature expression in the document's variable context.
    /// No unit conversion happens here; the caller applies the parameter's
    /// public/stored contract.
    private static func evaluateExpression(
        _ raw: String, values: [String: Double]
    ) -> Result<Double, VariableEditFailure> {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .failure(VariableEditFailure(
                "missing_expression", "An expression is required."))
        }
        let tokens = identifierTokens(in: text)
        let unknownCalls = Set(tokens.filter(\.isCall).map(\.text))
            .subtracting(ExpressionEvaluator.functionNames)
        if let unknown = unknownCalls.sorted().first {
            return .failure(VariableEditFailure(
                "unknown_function",
                "Unknown function '\(unknown)'. Supported functions: "
                    + ExpressionEvaluator.functionNames.sorted().joined(separator: ", ") + "."))
        }
        for token in tokens where !token.isCall {
            if ExpressionEvaluator.functionNames.contains(token.text), values[token.text] == nil {
                return .failure(VariableEditFailure(
                    "unknown_function",
                    "'\(token.text)' is a function; write \(token.text)(...) instead of "
                        + "using it as a value."))
            }
        }
        let references = ExpressionEvaluator.identifiers(in: text)
        let unresolved = references.filter { values[$0] == nil }.sorted()
        if let missing = unresolved.first {
            let unitHint = NumericParsing.trailingUnit(in: text) == missing
                ? " The parameter already uses its declared public unit; omit the unit suffix."
                : ""
            return .failure(VariableEditFailure(
                "unresolved_reference",
                "Unknown variable '\(missing)' in \"\(text)\". Create it first with "
                    + "variable.create." + unitHint))
        }
        if let value = ExpressionEvaluator.evaluate(text, variables: values), value.isFinite {
            return .success(value)
        }
        let validation = ExpressionEvaluator.validationMessage(text, variables: values) ?? ""
        if validation.lowercased().contains("divide by zero") {
            return .failure(VariableEditFailure(
                "divided_by_zero", "Expression \"\(text)\" divides by zero."))
        }
        return .failure(VariableEditFailure(
            "invalid_expression",
            "Cannot evaluate \"\(text)\". "
                + (validation.isEmpty ? "Fix the arithmetic and references." : validation)))
    }

    /// The feature's rewritten formulas must stay evaluable whenever they were
    /// evaluable before the rename. This turns an unsupported rewrite into a
    /// refusal instead of saving a dangling reference.
    private static func rewrittenExpressionsFailure(
        before: FeatureKind,
        after: FeatureKind,
        featureName: String,
        oldValues: [String: Double],
        newValues: [String: Double]
    ) -> VariableEditFailure? {
        for slot in DocumentSession.expressionSlots(in: after) {
            guard let formula = slot.expr.formula else { continue }
            guard ExpressionEvaluator.evaluate(formula, variables: newValues) == nil else { continue }
            if let oldFormula = DocumentSession.expressionSlot(in: before, named: slot.name)?
                .expr.formula,
               ExpressionEvaluator.evaluate(oldFormula, variables: oldValues) != nil {
                return VariableEditFailure(
                    "unsupported_rewrite",
                    "The rename would leave feature '\(featureName)' parameter '\(slot.name)' "
                        + "with an unreadable formula \"\(formula)\". Nothing was changed.")
            }
        }
        return nil
    }

    private struct IdentifierToken {
        var text: String
        var isCall: Bool
    }

    /// Same tokenization as `ExpressionEvaluator.identifiers`, but retaining
    /// whether the identifier is followed by "(". Used for function checks and
    /// the token-aware rename rewriter.
    private static func identifierTokens(in text: String) -> [IdentifierToken] {
        let chars = Array(text)
        var result: [IdentifierToken] = []
        var index = 0
        while index < chars.count {
            let character = chars[index]
            if character.isLetter || character == "_" {
                var name = ""
                while index < chars.count,
                      chars[index].isLetter || chars[index].isNumber || chars[index] == "_" {
                    name.append(chars[index])
                    index += 1
                }
                var lookahead = index
                while lookahead < chars.count, chars[lookahead] == " " { lookahead += 1 }
                result.append(IdentifierToken(
                    text: name,
                    isCall: lookahead < chars.count && chars[lookahead] == "("))
            } else {
                index += 1
            }
        }
        return result
    }

    /// Every identifier token that the evaluator would resolve as a VALUE
    /// (a function call's own name is excluded; its arguments are scanned).
    /// `ExpressionEvaluator.identifiers` additionally drops reserved function
    /// names even when used bare, which is right for diagnostics but would miss
    /// a legal variable named e.g. `pi`; dependency/deletion checks need the
    /// full value-token set.
    static func variableReferences(in text: String) -> Set<String> {
        Set(identifierTokens(in: text).filter { !$0.isCall }.map(\.text))
    }

    /// Replace the variable reference `old` with `new` using the SAME token
    /// boundaries as the evaluator: `w` inside `width`, `w2`, or `sqrt(` is
    /// never touched. Returns nil when the text does not reference `old`.
    static func rewriteIdentifier(_ text: String, from old: String, to new: String) -> String? {
        guard !old.isEmpty, old != new else { return nil }
        let chars = Array(text)
        var output = ""
        output.reserveCapacity(text.count + max(0, new.count - old.count))
        var index = 0
        var changed = false
        while index < chars.count {
            let character = chars[index]
            if character.isLetter || character == "_" {
                var end = index
                var token = ""
                while end < chars.count,
                      chars[end].isLetter || chars[end].isNumber || chars[end] == "_" {
                    token.append(chars[end])
                    end += 1
                }
                var lookahead = end
                while lookahead < chars.count, chars[lookahead] == " " { lookahead += 1 }
                let isCall = lookahead < chars.count && chars[lookahead] == "("
                if token == old, !isCall {
                    output += new
                    changed = true
                } else {
                    output += token
                }
                index = end
            } else {
                output.append(character)
                index += 1
            }
        }
        return changed ? output : nil
    }

    /// First cycle in the variable-reference graph, as variable indexes.
    private static func firstVariableCycle(in variables: [Variable]) -> [Int]? {
        let names = variables.map { $0.name.trimmingCharacters(in: .whitespaces) }
        var indexByName: [String: Int] = [:]
        for (index, name) in names.enumerated() where !name.isEmpty {
            if indexByName[name] == nil { indexByName[name] = index }
        }
        var adjacency: [Int: [Int]] = [:]
        for (index, variable) in variables.enumerated() {
            for reference in variableReferences(in: variable.expression) {
                if let target = indexByName[reference] {
                    adjacency[index, default: []].append(target)
                }
            }
        }
        var state: [Int: Int] = [:]  // 1 = visiting, 2 = done
        var stack: [Int] = []
        func visit(_ node: Int) -> [Int]? {
            if state[node] == 1 {
                if let start = stack.firstIndex(of: node) {
                    return Array(stack[start...]) + [node]
                }
                return [node, node]
            }
            if state[node] == 2 { return nil }
            state[node] = 1
            stack.append(node)
            for next in (adjacency[node] ?? []).sorted() {
                if let cycle = visit(next) { return cycle }
            }
            stack.removeLast()
            state[node] = 2
            return nil
        }
        for index in variables.indices {
            if let cycle = visit(index) { return cycle }
        }
        return nil
    }

    /// Everything that references this variable name, by exact IDs. Used by
    /// deletion refusal and the variables query, so both agree on the same
    /// token-aware reference set.
    static func variableDependents(of name: String,
                                   in document: DesignDocument) -> [String: Any] {
        var variableIDs: [String] = []
        var variableNames: [String] = []
        for variable in document.variables {
            guard variable.name.trimmingCharacters(in: .whitespaces) != name,
                  variableReferences(in: variable.expression).contains(name) else {
                continue
            }
            variableIDs.append(variable.id.raw.uuidString)
            variableNames.append(variable.name)
        }
        var featureRows: [[String: Any]] = []
        for node in document.features.nodes {
            for slot in DocumentSession.expressionSlots(in: node.kind) {
                guard let formula = slot.expr.formula,
                      variableReferences(in: formula).contains(name) else { continue }
                featureRows.append([
                    "feature_id": node.id.raw.uuidString,
                    "feature": node.name,
                    "parameter": slot.name,
                    "unit": slot.unit,
                    "formula": formula,
                ])
            }
        }
        var dimensionRows: [[String: Any]] = []
        for sketch in document.sketches {
            for dimension in sketch.dimensions {
                guard let formula = dimension.formula,
                      variableReferences(in: formula).contains(name) else { continue }
                dimensionRows.append([
                    "sketch_id": sketch.id.raw.uuidString,
                    "sketch": sketch.name,
                    "dimension_id": dimension.id.uuidString,
                    "kind": dimension.kind.rawValue,
                    "formula": formula,
                ])
            }
        }
        let planeRows: [[String: Any]] = document.planes.compactMap { plane in
            guard case let .offset(definition)? = plane.definition,
                  let formula = definition.distance.formula,
                  variableReferences(in: formula).contains(name) else { return nil }
            return ["plane_id": plane.id.raw.uuidString, "parameter": "distance",
                    "unit": "mm", "formula": formula]
        }
        return [
            "variable_ids": variableIDs,
            "variable_names": variableNames,
            "feature_parameters": featureRows,
            "sketch_dimensions": dimensionRows,
            "plane_parameters": planeRows,
            "plane_ids": planeRows.compactMap { $0["plane_id"] as? String },
            "count": variableIDs.count + featureRows.count + dimensionRows.count + planeRows.count,
        ]
    }

    static func variableRow(for id: VariableID,
                            in document: DesignDocument) -> [String: Any]? {
        variableRows(in: document).first {
            ($0["id"] as? String) == id.raw.uuidString
        }
    }

    /// One row per variable: identity, exact source, resolved value and unit
    /// contract, validity, and both directions of its dependency set.
    static func variableRows(in document: DesignDocument) -> [[String: Any]] {
        let resolution = VariableTable.resolve(document.variables)
        return document.variables.map { variable in
            let name = variable.name.trimmingCharacters(in: .whitespaces)
            let references = variableReferences(in: variable.expression)
            let dependsOn = document.variables.compactMap { other -> [String: Any]? in
                guard references.contains(other.name.trimmingCharacters(in: .whitespaces)) else {
                    return nil
                }
                return ["id": other.id.raw.uuidString, "name": other.name]
            }
            var row: [String: Any] = [
                "id": variable.id.raw.uuidString,
                "name": variable.name,
                "expression": variable.expression,
                "formula": variable.expression,
                "value": variable.value,
                "unit": "unitless",
                "editable": true,
                "update_action": "variable.update",
                "delete_action": "variable.delete",
                "depends_on": dependsOn,
                "referenced_by": variableDependents(of: name, in: document),
            ]
            if let error = resolution.errors[variable.id] {
                row["status"] = "error"
                row["error"] = error
                row["editable"] = false
            } else {
                row["status"] = "ok"
            }
            return row
        }
    }

    private static func featureNode(_ args: [String: Any],
                                    document: DesignDocument) -> FeatureNode? {
        guard let raw = CADMaterialService.string(args["feature_id"])
            ?? CADMaterialService.string(args["featureID"])
            ?? CADMaterialService.string(args["id"]),
              let uuid = UUID(uuidString: raw) else { return nil }
        return document.features.node(FeatureID(raw: uuid))
    }

    /// Feature nodes whose input bodies are produced by `node`.
    private static func dependentFeatureIDs(of node: FeatureNode,
                                            in document: DesignDocument) -> [UUID] {
        let dependencies = resolvedBodyDependencies(in: document.features.nodes)
        return document.features.nodes.compactMap { other in
            guard other.id != node.id else { return nil }
            return (dependencies[other.id] ?? []).contains(where: { $0.producer == node.id })
                ? other.id.raw : nil
        }
    }

    /// Every body a feature reads (through body, face or edge references).
    /// Keep producer identity as well as the reused BodyID for dependency checks.
    private static func referencedBodies(in node: FeatureNode) -> [BodyRef] {
        let refs = bodyReferences(in: node.kind)
            + faceReferences(in: node.kind).map(\.body)
            + edgeReferences(in: node.kind).map(\.body)
        var seen = Set<BodyRef>()
        return refs.filter { seen.insert($0).inserted }
    }

    /// Capture the body VERSION each feature consumes in the current history.
    /// BodyRef.producer remains the persisted provenance: older/native records
    /// can name the initial creator even after in-place writes. The evaluator
    /// reads the current body by BodyID, so its preceding writer is the actual
    /// ordering dependency. No stored refs or output ids are rewritten here.
    private static func resolvedBodyDependencies(
        in nodes: [FeatureNode]
    ) -> [FeatureID: [BodyRef]] {
        var writer: [BodyID: FeatureID] = [:]
        var result: [FeatureID: [BodyRef]] = [:]
        for node in nodes {
            var seen = Set<BodyRef>()
            result[node.id] = referencedBodies(in: node).compactMap { ref in
                let dependency = BodyRef(producer: writer[ref.bodyID] ?? ref.producer,
                                         bodyID: ref.bodyID)
                return seen.insert(dependency).inserted ? dependency : nil
            }
            // Declared ids cover new bodies (including mirror/pattern copies).
            // In-place evaluation additionally writes its input/target id even
            // when outputBodyIDs only contains a fresh placeholder.
            for id in node.outputBodyIDs + overwrittenBodyIDs(in: node.kind) {
                writer[id] = node.id
            }
        }
        return result
    }

    static func bodyWriterDependencies(in nodes: [FeatureNode]) -> [FeatureID: Set<FeatureID>] {
        resolvedBodyDependencies(in: nodes).mapValues { Set($0.map(\.producer)) }
    }

    /// Actual in-place outputs, matching FeatureGraph's dispatch. Do not mark
    /// pattern/mirror sources as written: those operations emit separate ids.
    private static func overwrittenBodyIDs(in kind: FeatureKind) -> [BodyID] {
        switch kind {
        case let .extrude(_, _, _, _, boolean, _),
             let .draftExtrude(_, _, _, _, _, boolean),
             let .revolve(_, _, _, _, boolean), let .sweep(_, _, _, boolean, _),
             let .loft(_, boolean):
            guard boolean.op != .newBody, let target = boolean.resolvedTargets.first else { return [] }
            return [target.bodyID]
        case let .boolean(_, target, _):
            return [target.bodyID]
        case let .hole(target, _, _, _):
            return [target.bodyID]
        case let .transform(body, _), let .chamfer(body, _, _),
             let .fillet(body, _, _), let .shell(body, _, _), let .deleteFace(body, _):
            return [body.bodyID]
        case let .pushPull(face, _, _), let .moveFace(face, _), let .scaleFace(face, _),
             let .rotateFace(face, _, _), let .draftFace(face, _, _, _),
             let .replaceFace(face, _, _, _):
            return [face.body.bodyID]
        case .primitive, .mirror, .pattern:
            return []
        }
    }

    private static func featureReply(action: String, nodeID: FeatureID, suppressed: Bool,
                                     document: DesignDocument, dependents: [UUID],
                                     revision: Int, changeCount: Int,
                                     canUndo: Bool, canRedo: Bool) -> [String: Any] {
        var reply: [String: Any] = [
            "action": action,
            "mutated": true,
            "feature_id": nodeID.raw.uuidString,
            "suppressed": suppressed,
            "dependent_feature_ids": dependents.map(\.uuidString),
            "revision": revision,
            "change_count": changeCount,
            "can_undo": canUndo,
            "can_redo": canRedo,
        ]
        if let node = document.features.node(nodeID) {
            reply["feature"] = describe(node, document: document)
        }
        return reply
    }

    private static func rebuildRejection(_ document: FloeCADDocument) -> [String: Any]? {
        let references = document.session.lastRebuildRejection
        let features = document.session.lastRejectedFeatureErrors
        guard !references.isEmpty || !features.isEmpty else { return nil }
        var details: [[String: Any]] = references.map { key, error in
            var row: [String: Any] = ["error": error.message]
            switch key {
            case let .plane(id): row["plane_id"] = id.raw.uuidString
            case let .sketch(id): row["sketch_id"] = id.raw.uuidString
            case let .feature(id): row["feature_id"] = id.raw.uuidString
            }
            return row
        }
        details += features.map { ["feature_id": $0.key.raw.uuidString,
                                   "error": String(describing: $0.value)] }
        return ["ok": false, "error": "rebuild_failed",
                "message": "That edit would break dependent geometry; nothing was kept.",
                "rolled_back": true, "errors": details,
                "revision": document.revision, "change_count": document.session.changeCount]
    }

    /// Shared rollback gate: a mutation that introduces a NEW rebuild error is
    /// restored from the exact checkpoint (document + undo/redo histories) and
    /// reported as `rebuild_failed`. Returns nil when nothing broke.
    private static func rollbackIfRebuildBroke(
        document: FloeCADDocument,
        beforeErrors: [FeatureID: FeatureError],
        beforeChangeCount: Int,
        checkpoint: CADEditCheckpoint,
        message: String
    ) -> [String: Any]? {
        if let rejection = rebuildRejection(document) { return rejection }
        let afterErrors = document.session.lastEvalErrors
        let introduced = afterErrors.filter { id, error in
            guard let old = beforeErrors[id] else { return true }
            return String(describing: old) != String(describing: error)
        }
        guard !introduced.isEmpty else { return nil }
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
            "message": message,
            "rolled_back": true,
            "errors": details,
            "revision": document.revision,
            "change_count": document.session.changeCount,
        ]
    }

    private static let overConstraintTolerance = 1e-3

    /// Solve a proposed entity edit through the existing sketch solver while
    /// holding only the caller's EXPLICIT fields on the edited primitive. A
    /// legal parametric/constraint solution therefore moves related geometry
    /// (other entities and any unrequested part of the edited primitive), the
    /// ordinary editor / `setSketchDimension` behavior; genuinely unrelated
    /// entities have no residual coupling and keep their geometry. The
    /// transient `.fixed` anchor is never stored and never covers every
    /// primitive in the sketch. Returns the solved entity list plus explicit
    /// failure diagnostics instead of silently accepting an unsatisfied system.
    private static func solveEditedSketch(
        _ sketch: Sketch, edited: SketchEntity, heldRefs: [ConstraintRef],
        heldSplinePointIndices: [Int] = []
    ) -> Result<[SketchEntity], SketchEditFailure> {
        let anchored: Sketch
        switch applyingCoincidentFollowers(sketch, edited: edited) {
        case .success(let value): anchored = value
        case .failure(let error): return .failure(error)
        }
        var solvedSketch = anchored
        if !heldRefs.isEmpty {
            solvedSketch.constraints.append(SketchConstraint(
                kind: .fixed, refs: heldRefs))
        }
        let outcome = SketchSolverBridge.solveOutcome(
            solvedSketch, movingEntity: nil, dragTarget: nil,
            holdingSplinePoints: heldSplinePointIndices.isEmpty
                ? [:] : [edited.id: Set(heldSplinePointIndices)])
        // Final admission: per-equation backward error AND absolute product
        // precision (see SketchSolverBridge.structuralNorms), AND a converged
        // solve. Small-scale contradictions cannot hide under display
        // precision; a best fit or failed solve leaves every byte unchanged.
        guard outcome.converged,
              outcome.structuralResidual <= overConstraintTolerance else {
            let blame = SketchSolverBridge.conflictAttribution(
                solvedSketch, tolerance: overConstraintTolerance)
            var rows = blame.constraintIDs.map(\.uuidString).sorted()
                + blame.dimensionIDs.map(\.uuidString).sorted()
            // M02/M06: connected-arc coherence failures attribute to the arc
            // entity itself — name it as geometry, never as a phantom
            // constraint id.
            rows += blame.entityIDs.map { "geometry:\($0.uuidString)" }.sorted()
            return .failure(SketchEditFailure(
                code: "constraint_conflict",
                message: "The \(entityKindName(edited)) edit cannot satisfy the saved constraints and "
                    + "driving dimensions with the requested geometry held"
                    + (rows.isEmpty ? "." : ": " + rows.joined(separator: ", ") + ".")
                    + " Nothing was changed. Keep the constrained value, or change the driving "
                    + "value with setSketchDimension."))
        }
        return .success(outcome.entities)
    }

    /// Rebuild the reply's geometry rows from the ACTUAL solved primitive. The
    /// caller's explicit fields are held exactly, but an unrequested
    /// endpoint/side may follow a saved constraint; reporting the stale plan
    /// values would claim geometry the document does not contain.
    private static func applyingSolvedGeometry(
        _ entity: SketchEntity, to plan: SketchEntityEditPlan
    ) -> (applied: [String: Any], response: [String: Any]) {
        var applied = plan.applied
        var response = plan.response
        switch entity {
        case let .line(_, a, b):
            applied["a"] = [a.x, a.y]
            applied["b"] = [b.x, b.y]
            response["a"] = [a.x, a.y]
            response["b"] = [b.x, b.y]
            response["lengthMM"] = simd_length(b - a)
        case let .rect(_, low, high):
            let center = (low + high) / 2
            applied["min"] = [low.x, low.y]
            applied["max"] = [high.x, high.y]
            response["min"] = [low.x, low.y]
            response["max"] = [high.x, high.y]
            response["center"] = [center.x, center.y]
            response["widthMM"] = abs(high.x - low.x)
            response["heightMM"] = abs(high.y - low.y)
        case let .circle(_, center, radius):
            applied["center"] = [center.x, center.y]
            applied["radius"] = radius
            response["center"] = [center.x, center.y]
            response["radius"] = radius
            response["diameter"] = radius * 2
        case let .arc(_, center, radius, startAngle, endAngle):
            let startDeg = degrees(fromRadians: normalizedRadians(startAngle))
            let endDeg = degrees(fromRadians: normalizedRadians(endAngle))
            let sweepDeg = degrees(fromRadians:
                SketchEntity.arcSweep(startAngle: startAngle, endAngle: endAngle))
            applied["center"] = [center.x, center.y]
            applied["radius"] = radius
            applied["start_angle_deg"] = startDeg
            applied["end_angle_deg"] = endDeg
            applied["sweep_angle_deg"] = sweepDeg
            response["center"] = [center.x, center.y]
            response["radius"] = radius
            response["diameter"] = radius * 2
            response["startAngleRadians"] = startAngle
            response["endAngleRadians"] = endAngle
            response["startAngleDegrees"] = startDeg
            response["endAngleDegrees"] = endDeg
            response["sweepAngleDegrees"] = sweepDeg
        case let .ellipse(_, center, radiusX, radiusY, rotation):
            applied["center"] = [center.x, center.y]
            applied["radius_x"] = radiusX
            applied["radius_y"] = radiusY
            applied["rotation_deg"] = degrees(fromRadians: normalizedRadians(rotation))
            response["center"] = [center.x, center.y]
            response["radiusX"] = radiusX
            response["radiusY"] = radiusY
            response["rotationRadians"] = rotation
            response["rotationDegrees"] = degrees(fromRadians: normalizedRadians(rotation))
        case let .spline(_, points, _):
            let rows = points.map { [$0.x, $0.y] }
            applied["points"] = rows
            response["points"] = rows
            response["pointCount"] = points.count
        case .polygon:
            break
        }
        return (applied, response)
    }

    /// A saved Coincident constraint is a stored weld. The solver represents a
    /// weld as one shared variable and would average the edited point with its
    /// partner's OLD position, pulling the requested edit halfway back. Carry
    /// the requested position to every coincident partner first, so the
    /// partner follows the edited geometry as the saved constraint requires.
    /// Only explicit constraints are followed; nothing is added or removed.
    /// A locked partner cannot follow, so that is a precise refusal rather
    /// than silently re-locking (and moving) the saved Lock's coordinates.
    private static func applyingCoincidentFollowers(
        _ sketch: Sketch, edited: SketchEntity
    ) -> Result<Sketch, SketchEditFailure> {
        var proposed = sketch
        var positions: [String: SIMD2<Double>] = [:]
        for slot in pointSlots(of: edited) {
            positions[slotKey(edited.id, slot.role)] = slot.point
        }
        var changed = true
        while changed {
            changed = false
            for constraint in sketch.constraints
            where constraint.kind == .coincident && constraint.refs.count == 2 {
                let first = constraint.refs[0]
                let second = constraint.refs[1]
                let firstKey = slotKey(first.entityID, first.role)
                let secondKey = slotKey(second.entityID, second.role)
                if let point = positions[firstKey], positions[secondKey] == nil {
                    positions[secondKey] = point
                    changed = true
                } else if let point = positions[secondKey], positions[firstKey] == nil {
                    positions[firstKey] = point
                    changed = true
                }
            }
        }
        for (index, entity) in proposed.entities.enumerated() where entity.id != edited.id {
            var updated = entity
            for slot in pointSlots(of: entity) {
                guard let point = positions[slotKey(entity.id, slot.role)],
                      let candidate = replacingPoint(point, role: slot.role, in: updated)
                else { continue }
                if simd_distance(point, slot.point) > 1e-9,
                   isPointLocked(ConstraintRef(entityID: entity.id, role: slot.role),
                                 in: sketch) {
                    return .failure(SketchEditFailure(
                        code: "constraint_conflict",
                        message: "The \(entityKindName(entity)) \(entity.id.uuidString) is a "
                            + "Coincident partner of the edited \(entityKindName(edited)) but is "
                            + "locked at its current point. Nothing was changed. Remove that Lock "
                            + "explicitly, or move the locked partner itself."))
                }
                updated = candidate
            }
            if updated != entity { proposed.entities[index] = updated }
        }
        return .success(proposed)
    }

    /// M02: the arc takes part in the connected-endpoint vocabulary — some
    /// saved constraint or dimension references it at an endpoint role, so the
    /// solver exposes the arc's endpoints as variables. The transient edit
    /// anchors must then leave the endpoints free (see `arcEditPlan`).
    private static func arcIsEndpointConnected(_ id: UUID, in sketch: Sketch) -> Bool {
        sketch.constraints.contains { constraint in
            constraint.refs.contains {
                $0.entityID == id
                    && ($0.role == .endpointA || $0.role == .endpointB)
            }
        } || sketch.dimensions.contains { dimension in
            dimension.refs.contains {
                $0.entityID == id
                    && ($0.role == .endpointA || $0.role == .endpointB)
            }
        }
    }

    /// R1 review: exactly the operand vocabulary the bridge truthfully lowers
    /// against an arc endpoint — another point role (a weld or a
    /// point-to-point dimension), or the whole of a line-like entity
    /// (line/rect/open spline) that resolves to a `linePair`. Whole
    /// circles/arcs/ellipses/polygons and closed splines have no such
    /// lowering: a saved relation against one would be silently dropped by
    /// the solve while still gating edits — a ghost the edit gate must
    /// refuse instead.
    private static func executableArcEndpointCounterpart(
        _ ref: ConstraintRef, in sketch: Sketch
    ) -> Bool {
        if ref.role == .endpointA || ref.role == .endpointB { return true }
        guard ref.role == .whole,
              let entity = sketch.entities.first(where: { $0.id == ref.entityID })
        else { return false }
        switch entity {
        case .line, .rect:
            return true
        case let .spline(_, _, closed):
            return !closed
        case .circle, .arc, .ellipse, .polygon:
            return false
        }
    }

    /// A stored Lock that pins this exact point: a whole-entity `.fixed`, or a
    /// `.fixed` naming the same point role.
    private static func isPointLocked(_ ref: ConstraintRef, in sketch: Sketch) -> Bool {
        sketch.constraints.contains { constraint in
            constraint.kind == .fixed && constraint.refs.contains { fixed in
                fixed.entityID == ref.entityID
                    && (fixed.role == .whole || fixed.role == ref.role)
            }
        }
    }

    /// Point slots the sketch solver exposes for an entity. Closed splines and
    /// solvers without point variables produce no slots.
    private static func pointSlots(
        of entity: SketchEntity
    ) -> [(role: PointRole, point: SIMD2<Double>)] {
        switch entity {
        case let .line(_, a, b):
            return [(.endpointA, a), (.endpointB, b)]
        case let .rect(_, low, high):
            return [(.endpointA, low), (.endpointB, high)]
        case let .circle(_, center, _), let .arc(_, center, _, _, _),
             let .ellipse(_, center, _, _, _), let .polygon(_, center, _, _, _):
            return [(.center, center)]
        case let .spline(_, points, closed):
            guard !closed, let first = points.first, let last = points.last else { return [] }
            return [(.endpointA, first), (.endpointB, last)]
        }
    }

    private static func slotKey(_ entityID: UUID, _ role: PointRole) -> String {
        "\(entityID.uuidString):\(role.rawValue)"
    }

    private static func replacingPoint(
        _ point: SIMD2<Double>, role: PointRole, in entity: SketchEntity
    ) -> SketchEntity? {
        switch (entity, role) {
        case let (.line(id, _, b), .endpointA):
            return .line(id: id, a: point, b: b)
        case let (.line(id, a, _), .endpointB):
            return .line(id: id, a: a, b: point)
        case let (.rect(id, _, high), .endpointA):
            return .rect(id: id, min: point, max: high)
        case let (.rect(id, low, _), .endpointB):
            return .rect(id: id, min: low, max: point)
        case let (.circle(id, _, radius), .center):
            return .circle(id: id, center: point, radius: radius)
        case let (.arc(id, _, radius, startAngle, endAngle), .center):
            return .arc(id: id, center: point, radius: radius,
                        startAngle: startAngle, endAngle: endAngle)
        case let (.ellipse(id, _, radiusX, radiusY, rotation), .center):
            return .ellipse(id: id, center: point, radiusX: radiusX,
                            radiusY: radiusY, rotation: rotation)
        case let (.polygon(id, _, radius, sides, rotation), .center):
            return .polygon(id: id, center: point, radius: radius,
                            sides: sides, rotation: rotation)
        case let (.spline(id, points, closed), .endpointA) where !closed && !points.isEmpty:
            var moved = points
            moved[0] = point
            return .spline(id: id, points: moved, closed: closed)
        case let (.spline(id, points, closed), .endpointB) where !closed && !points.isEmpty:
            var moved = points
            moved[moved.count - 1] = point
            return .spline(id: id, points: moved, closed: closed)
        default:
            return nil
        }
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

        /// Vectors are descriptors, not typed parameter values: no current
        /// `updated(_:changes:)` branch accepts one, so they are explicitly
        /// non-editable (query flags must match the executable vocabulary).
        func vector(_ name: String, _ value: SIMD3<Double>, _ unit: String?) {
            add(name, unit, [value.x, value.y, value.z], editable: false)
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
            add("placement_scale", "unitless", placement.scale, minimum: 1e-6, editable: false)
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
        case let .hole(_, profileRef, _, spec):
            kindName = "hole"
            add("hole_type", "unitless", spec.kind.rawValue,
                note: "throughAll | blind | counterbore | countersink")
            if let depth = spec.depth {
                add("depth", "mm", depth.value, minimum: 1e-6,
                    editable: spec.kind == .blind,
                    note: spec.kind == .blind ? nil : "Stored; applies to blind holes.")
            } else if spec.kind == .blind {
                add("depth", "mm", NSNull(), minimum: 1e-6,
                    note: "Required for a blind hole.")
            }
            if let diameter = spec.counterboreDiameter {
                add("counterbore_diameter", "mm", diameter.value, minimum: 1e-6,
                    editable: spec.kind == .counterbore,
                    note: spec.kind == .counterbore ? "Must exceed the pilot diameter." : "Stored; applies to counterbores.")
            }
            if let depth = spec.counterboreDepth {
                add("counterbore_depth", "mm", depth.value, minimum: 1e-6,
                    editable: spec.kind == .counterbore,
                    note: spec.kind == .counterbore ? nil : "Stored; applies to counterbores.")
            }
            if let diameter = spec.countersinkDiameter {
                add("countersink_diameter", "mm", diameter.value, minimum: 1e-6,
                    editable: spec.kind == .countersink,
                    note: spec.kind == .countersink ? "Must exceed the pilot diameter." : "Stored; applies to countersinks.")
            }
            if let angle = spec.countersinkAngle {
                add("countersink_angle", "deg", angle.value, minimum: 30, maximum: 170,
                    editable: spec.kind == .countersink,
                    note: "Included angle.")
            }
            add("reversed", "unitless", spec.reversed,
                note: spec.reversed ? "Drills along -plane.normal." : "Drills along +plane.normal.")
            if let sketch = document.sketches.first(where: { $0.id == profileRef.sketchID }),
               let circle = HoleKit.circle(in: sketch, matching: profileRef) {
                add("pilot_diameter", "mm", circle.radius * 2, editable: false,
                    note: "Derived from the placement circle; edit that circle to resize the hole.")
                add("position_u", "mm", circle.center.x, editable: false,
                    note: "Derived from the placement circle.")
                add("position_v", "mm", circle.center.y, editable: false,
                    note: "Derived from the placement circle.")
            }
            unit = "mm"
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
            add("angle", "deg", angle.value * (180 / .pi))
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

        // Formula contract for every expression-capable scalar. `formula` is
        // the EXACT persisted source used by expected_expression; `unit` is
        // the public input unit and `stored_unit` the persisted Expr unit.
        let expressionSlots = DocumentSession.expressionSlots(in: node.kind)
        for slot in expressionSlots {
            guard let index = parameters.firstIndex(where: {
                ($0["name"] as? String) == slot.name
            }) else { continue }
            parameters[index]["formula"] = slot.expr.formula ?? NSNull()
            parameters[index]["formula_unit"] = slot.storedUnit
            parameters[index]["stored_value"] = slot.expr.value
            parameters[index]["stored_unit"] = slot.storedUnit
            parameters[index]["set_expression_unit"] = slot.unit
            parameters[index]["expression_action"] = "feature.setExpression"
            parameters[index]["variable_references"] = slot.formulaReferences
            // Both units stay explicit: a converted formula exposes its
            // safely inverted source when (and only when) it is an exact
            // whole radians(...) call; a legacy arbitrary radian source is
            // never mislabeled as degrees.
            let view = publicExpressionView(for: slot)
            parameters[index]["source_expression"] = view.sourceExpression
            parameters[index]["source_expression_unit"] = view.sourceExpressionUnit
            parameters[index]["public_expression"] = view.publicExpression
            parameters[index]["public_expression_unit"] = view.publicExpressionUnit
            parameters[index]["public_expression_derived"] = view.publicExpressionDerived
        }

        let sketchIDs = node.referencedSketchIDs.map(\.raw.uuidString).sorted()
        let refs = referencedBodies(in: node)
        let resolved = resolvedBodyDependencies(in: document.features.nodes)[node.id] ?? refs
        let featureDeps = Set(resolved.map { $0.producer.raw.uuidString })
        let bodyDeps = Set(refs.map { $0.bodyID.raw.uuidString })
        let referenceProducers = Set(refs.map { $0.producer.raw.uuidString })
        let updateSupported = Self.updateSupported(node.kind)
        var actions = ["feature.suppress", "feature.delete", "feature.move"]
        if updateSupported { actions.insert("parameter.update", at: 0) }
        if !expressionSlots.isEmpty { actions.append("feature.setExpression") }
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
                "reference_producer_ids": referenceProducers.sorted(),
                "body_ids": bodyDeps.union(node.outputBodyIDs.map(\.raw.uuidString)).sorted(),
            ],
            "actions": actions,
            "update_supported": updateSupported,
            "expression_parameters": expressionSlots.map { slot -> [String: Any] in
                let view = publicExpressionView(for: slot)
                return [
                    "name": slot.name,
                    "unit": slot.unit,
                    "stored_unit": slot.storedUnit,
                    "value": slot.publicValue,
                    "stored_value": slot.expr.value,
                    "formula": slot.expr.formula ?? NSNull(),
                    "source_expression": view.sourceExpression,
                    "source_expression_unit": view.sourceExpressionUnit,
                    "public_expression": view.publicExpression,
                    "public_expression_unit": view.publicExpressionUnit,
                    "public_expression_derived": view.publicExpressionDerived,
                    "action": "feature.setExpression",
                ]
            },
            "variable_references": Array(Set(
                expressionSlots.flatMap(\.formulaReferences))).sorted(),
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
             .fillet, .shell, .hole:
            return true
        default:
            return false
        }
    }

    // MARK: - Reference extraction (descriptors)

    private static func bodyReferences(in kind: FeatureKind) -> [BodyRef] {
        switch kind {
        case let .extrude(_, _, _, _, boolean, _),
             let .draftExtrude(_, _, _, _, _, boolean),
             let .revolve(_, _, _, _, boolean), let .sweep(_, _, _, boolean, _),
             let .loft(_, boolean):
            return boolean.resolvedTargets
        case let .boolean(_, target, tools): return [target] + tools
        // Profile features consume the bodies their boolean intent names
        // (union/subtract/intersect), e.g. an extruded hole cut. Omitting them
        // hid real edges in the dependency graph, so deleting/ moving the
        // producer slipped through to the rebuild and failed there instead of
        // being refused as `has_dependents` / `dependency_order`.
        case let .extrude(_, _, _, _, boolean, _),
             let .draftExtrude(_, _, _, _, _, boolean),
             let .revolve(_, _, _, _, boolean),
             let .sweep(_, _, _, boolean, _),
             let .loft(_, boolean):
            return boolean.resolvedTargets
        case let .hole(target, _, _, _): return [target]
        case let .transform(body, _), let .mirror(body, _, _),
             let .pattern(body, _), let .chamfer(body, _, _),
             let .fillet(body, _, _), let .shell(body, _, _),
             let .deleteFace(body, _):
            return [body]
        case .primitive,
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

    /// The actual pilot diameter a hole feature's placement sketch resolves to,
    /// so a parameter edit can be validated BEFORE any mutation with the same
    /// relation creation and evaluation use (`counterboreDiameter` /
    /// `countersinkDiameter` must genuinely exceed the pilot). Nil when the
    /// feature is not a hole, the sketch is gone, or the region no longer
    /// resolves to a circle; the rebuild performs the final pilot-aware check.
    private static func placementPilotDiameter(_ node: FeatureNode,
                                               document: DesignDocument) -> Double? {
        guard case let .hole(_, profile, _, _) = node.kind,
              let sketch = document.sketches.first(where: { $0.id == profile.sketchID }),
              let circle = HoleKit.circle(in: sketch, matching: profile) else { return nil }
        return circle.radius * 2
    }

    /// The ONE user-visible undo title for a parameter edit. Mechanical holes
    /// are a distinct editable operation, so their step names the operation
    /// instead of the editor's generic "Edit Feature".
    private static func editTitle(for kind: FeatureKind) -> String {
        if case .hole = kind { return "Edit Hole" }
        return "Edit Feature"
    }

    /// Map the documented parameter vocabulary onto the typed FeatureKind.
    /// Unknown names are a refusal (never a silent no-op), and every numeric
    /// value is validated against the same physical bounds the interactive
    /// tools use.
    ///
    /// `requireChange` is the ordinary EDIT contract: at least one value must
    /// actually differ, otherwise the reply is the explicit no-op refusal.
    /// `feature.setExpression` passes `false` because its change is the
    /// FORMULA text; a formula bound to the current numeric value (e.g.
    /// `depth = 6` rebound to variable `boreDepth` = 6) must still validate and
    /// be stored as an Expr instead of being rejected as "nothing changed".
    /// Validation itself is identical in both modes, and `pilotDiameter`
    /// (resolved from the placement sketch) lets a hole edit use the SAME
    /// structural validation as creation/evaluation.
    static func updated(_ kind: FeatureKind,
                        changes: [String: Any],
                        requireChange: Bool = true,
                        pilotDiameter: Double? = nil) -> Result<FeatureKind, CADParameterEditError> {
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
            // Match feature.rotateFace creation and the native editor: the
            // public parameter is degrees, the persisted Expr is radians.
            return .success(.rotateFace(face: face,
                                        angle: Expr(value: a * (.pi / 180), formula: nil), axis: axis))
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
        case let .hole(target, profile, plane, spec):
            // One field mapping for BOTH the ordinary numeric edit and the
            // formula-binding prevalidation. The stored Expr comparison below
            // detects a real numeric change; a formula-only rebind supplies
            // the SAME number, so only the ordinary edit path enforces that
            // something moved.
            let allowed = ["hole_type", "depth", "counterbore_diameter",
                           "counterbore_depth", "countersink_diameter",
                           "countersink_angle", "reversed"]
            guard changes.keys.allSatisfy({ allowed.contains($0) }) else {
                return unknown(allowed)
            }
            var newSpec = spec
            if let raw = changes["hole_type"] {
                guard let name = raw as? String,
                      let kind = HoleSpec.Kind(rawValue: name) else {
                    return fail("hole_type",
                                "hole_type must be throughAll, blind, counterbore or countersink.")
                }
                // The documented single update may carry the new depth WITH the
                // type change; refuse only when neither the stored spec nor
                // this update supplies one. The bounds check below still
                // validates a supplied depth before any mutation.
                if kind == .blind, newSpec.depth == nil, value("depth") == nil {
                    return fail("depth", "A blind hole needs a depth; provide depth in this update.")
                }
                newSpec.kind = kind
            }
            if let depth = value("depth") {
                guard depth > 0, depth.isFinite else {
                    return fail("depth", "depth must be a positive finite mm value.")
                }
                // A numeric edit replaces a stale formula with the literal
                // value the caller supplied (same rule as every other Expr).
                newSpec.depth = Expr(value: depth, formula: nil)
            }
            if let diameter = value("counterbore_diameter") {
                guard diameter > 0, diameter.isFinite else {
                    return fail("counterbore_diameter", "counterbore_diameter must be positive mm.")
                }
                newSpec.counterboreDiameter = Expr(value: diameter, formula: nil)
            }
            if let depth = value("counterbore_depth") {
                guard depth > 0, depth.isFinite else {
                    return fail("counterbore_depth", "counterbore_depth must be positive mm.")
                }
                newSpec.counterboreDepth = Expr(value: depth, formula: nil)
            }
            if let diameter = value("countersink_diameter") {
                guard diameter > 0, diameter.isFinite else {
                    return fail("countersink_diameter", "countersink_diameter must be positive mm.")
                }
                newSpec.countersinkDiameter = Expr(value: diameter, formula: nil)
            }
            if let angle = value("countersink_angle") {
                guard angle.isFinite, (30.0...170.0).contains(angle) else {
                    return fail("countersink_angle",
                                "countersink_angle must be an included angle of 30…170 degrees.")
                }
                newSpec.countersinkAngle = Expr(value: angle, formula: nil)
            }
            if let reversed = boolValue("reversed") {
                newSpec.reversed = reversed
            }
            // A formula-only rebind changes `newSpec` at the caller (the stored
            // Expr gets its formula); the numeric specs are equal there, so the
            // caller's own expression-only check owns that decision. The
            // ordinary edit still refuses a true no-op.
            if requireChange, newSpec == spec {
                return .failure(CADParameterEditError(
                    "No supported hole parameter value changed. Structured bounds were still "
                    + "validated; supply a different value for a numeric edit."))
            }
            if let issue = HoleKit.validationIssue(newSpec, pilotDiameter: pilotDiameter) {
                return fail("hole", issue)
            }
            return .success(.hole(target: target, profile: profile, plane: plane,
                                  spec: newSpec))
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

    static func fail(_ code: String, _ message: String,
                     extra: [String: Any]) -> [String: Any] {
        var reply = fail(code, message)
        for (key, value) in extra { reply[key] = value }
        return reply
    }
}
