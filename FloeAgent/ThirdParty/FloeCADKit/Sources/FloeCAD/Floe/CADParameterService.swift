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
    /// Every executable action. The feature actions are the SAME three names
    /// `query kind=features` advertises (`feature.suppress`,
    /// `feature.delete`, `feature.move`), so a discovered action is always
    /// executable instead of a model-facing suggestion that silently has no
    /// implementation.
    public static let actions: [String] = [
        "list", "update", "updateSketchEntity",
        "setSketchDimension", "removeSketchDimension",
        "feature.suppress", "feature.delete", "feature.move",
        "undo", "redo",
    ]

    /// Sketch-entity kinds with a real typed geometry edit.
    public static let editableSketchEntityKinds: Set<String> = ["line", "rect", "circle"]

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
        if let failure = revisionPinFailure(args) { return failure }
        switch action {
        case "list": return list(args)
        case "update": return update(args)
        case "updateSketchEntity": return updateSketchEntity(args)
        case "setSketchDimension": return setSketchDimension(args)
        case "removeSketchDimension": return removeSketchDimension(args)
        case "feature.suppress": return featureSuppress(args)
        case "feature.delete": return featureDelete(args)
        case "feature.move": return featureMove(args)
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
                "supported_entity_kinds": ["line", "rect", "circle"],
                "fields": [
                    "sketch_id", "entity_id",
                    "line: a, b (alias start, end) + expected_a, expected_b",
                    "rect: min, max, center, width, height + expected_min, expected_max, expected_width, expected_height",
                    "circle: center, radius, diameter + expected_radius, expected_diameter, expected_center",
                ],
                "unit": "mm",
                "constraints": "A direct geometry edit is REFUSED with constraint_conflict when it "
                    + "would leave an existing driving dimension/constraint unsatisfied. Circle "
                    + "radius/diameter and rectangle width/height update their matching driving "
                    + "dimensions in the same undo step; use setSketchDimension for other values.",
                "discover": "query kind=sketches -> rows[].entityRows[].update_fields",
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

    /// One planned entity edit: the new entity plus the matching driving
    /// dimensions that must move with it (so the stored sketch stays
    /// internally consistent), the applied fields and the reply row.
    private struct SketchEntityEditPlan {
        var after: SketchEntity
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
    ///   * circle: `center`, `radius` and/or `diameter`.
    ///
    /// The edit is REFUSED (`constraint_conflict`) when it would leave an
    /// existing driving dimension or geometric constraint unsatisfied. A
    /// matching single-entity driving value — a circle's radius/diameter, a
    /// rectangle's width/height, a line's own length/horizontal/vertical —
    /// is updated in the same undo step instead of becoming stale. Other
    /// driving values are changed through `setSketchDimension`.
    ///
    /// Optional optimistic fences (`expected_radius`, `expected_center`,
    /// `expected_a`/`expected_b`, `expected_min`/`expected_max`,
    /// `expected_width`/`expected_height`) compare against the current
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
        default:
            return Self.fail(
                "unsupported_entity",
                "updateSketchEntity edits line, rect and circle entities; entity \(rawEntity) "
                    + "is \(Self.entityKindName(before)). Its editable flags are false in "
                    + "query kind=sketches. Change unsupported geometry with the sketch tools.")
        }

        if plan.after == before && plan.dimensionUpdates.isEmpty {
            return Self.fail("no_change",
                             "The \(Self.entityKindName(before)) edit did not change any geometry.")
        }
        // Keep the STORED sketch consistent before the rebuild: apply the new
        // entity plus every matching driving value to a preview, and refuse a
        // change the saved constraints cannot satisfy. This gate is the same
        // `residualNorm` the interactive sketch tool uses before writing.
        var proposed = sketch
        proposed.entities[entityIndex] = plan.after
        for (beforeDimension, afterDimension) in plan.dimensionUpdates {
            guard let index = proposed.dimensions.firstIndex(where: { $0.id == beforeDimension.id }) else {
                return Self.fail("unknown_dimension",
                                 "The driving dimension \(beforeDimension.id.uuidString) disappeared during the edit.")
            }
            proposed.dimensions[index] = afterDimension
        }
        if SketchSolverBridge.residualNorm(proposed) > Self.overConstraintTolerance {
            return Self.fail(
                "constraint_conflict",
                "The \(Self.entityKindName(before)) edit would violate an existing sketch constraint or "
                    + "driving dimension. Nothing was changed. Read query kind=constraints and either keep "
                    + "the constrained value or change the driving value with setSketchDimension.")
        }

        let beforeErrors = document.session.lastEvalErrors
        let beforeChangeCount = document.session.changeCount
        let checkpoint = document.captureEditCheckpoint()
        var commands: [DocumentCommand] = [
            UpdateSketchEntityCommand(title: plan.title, sketchID: sketchID,
                                      before: before, after: plan.after)
        ]
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
            "entity": plan.response,
            "applied_changes": plan.applied,
            "updated_dimension_ids": plan.dimensionUpdates.map { $0.after.id.uuidString },
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
        return .success(SketchEntityEditPlan(
            after: .line(id: id, a: newA, b: newB),
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
        return .success(SketchEntityEditPlan(
            after: .rect(id: id, min: normalizedLow, max: normalizedHigh),
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
        return .success(SketchEntityEditPlan(
            after: .circle(id: id, center: newCenter, radius: newRadius),
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
                let role = CADMaterialService.string(row["role"]).flatMap(PointRole.init(rawValue:)) ?? .whole
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
            return Self.fail(
                "constraint_conflict",
                "The driving \(requestedKind) conflicts with the sketch's existing constraints/dimensions; "
                    + "nothing was changed. Remove or relax the conflicting relationship first.")
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
        var reordered = nodes
        reordered.remove(at: from)
        reordered.insert(node, at: clamped)
        var producerPosition: [UUID: Int] = [:]
        for (index, candidate) in reordered.enumerated() {
            for body in candidate.outputBodyIDs {
                producerPosition[body.raw] = index
            }
        }
        var offenders: [[String: Any]] = []
        for (index, candidate) in reordered.enumerated() {
            for body in Self.referencedBodyIDs(in: candidate) {
                // A feature that MODIFIES a body in place (transform, mirror,
                // pattern, fillet, shell, face edits) references that same
                // body and also owns it as output. That is a self-reference,
                // not a dependency on a later node.
                guard let producerIndex = producerPosition[body.raw],
                      producerIndex != index,
                      producerIndex >= index else { continue }
                offenders.append([
                    "feature_id": candidate.id.raw.uuidString,
                    "feature": candidate.name,
                    "body_id": body.raw.uuidString,
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
        let outputs = Set(node.outputBodyIDs.map(\.raw))
        guard !outputs.isEmpty else { return [] }
        return document.features.nodes.compactMap { other in
            guard other.id != node.id else { return nil }
            let refs = referencedBodyIDs(in: other).map(\.raw)
            return refs.contains(where: { outputs.contains($0) }) ? other.id.raw : nil
        }
    }

    /// Every body a feature reads (through body, face or edge references).
    private static func referencedBodyIDs(in node: FeatureNode) -> [BodyID] {
        var ids: [BodyID] = []
        for ref in bodyReferences(in: node.kind) { ids.append(ref.bodyID) }
        for ref in faceReferences(in: node.kind) { ids.append(ref.body.bodyID) }
        for ref in edgeReferences(in: node.kind) { ids.append(ref.body.bodyID) }
        return ids
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
