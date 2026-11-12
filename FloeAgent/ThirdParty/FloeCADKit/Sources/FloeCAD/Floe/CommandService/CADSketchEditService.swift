//
//  CADSketchEditService.swift
//  FloeCADKit
//
//  Headless symbolic sketch editing and imported drawing geometry for the
//  SAME native document. Constraint add/update/remove use the existing
//  DocumentCommand history (one undo step); a drawing transfer appends real
//  entities into one explicit sketch. No parallel editor state, solver or
//  file format is introduced.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation
import simd

@MainActor
public final class CADSketchEditService {
    /// The exact executable vocabulary this service advertises. Every name
    /// below is dispatched by `handle(action:args:)`.
    public static let actions = [
        "addSketchConstraint", "updateSketchConstraint", "removeSketchConstraint",
    ]

    private let document: FloeCADDocument

    public init(document: FloeCADDocument) {
        self.document = document
    }

    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        guard Self.actions.contains(action) else {
            return Self.fail("unknown_constraint_action",
                             "Unknown sketch constraint action '\(action)'. Use "
                                + Self.actions.joined(separator: ", ") + ".")
        }
        guard !document.isClosed else {
            return Self.fail("document_closed", "The CAD document is closed.")
        }
        guard !document.isReadOnly, document.session.writeBlock == nil else {
            let block = document.session.writeBlock
            return Self.fail(block?.code ?? "read_only",
                             block?.message ?? "This CAD document is read-only.")
        }
        if let raw = args["revision"] ?? args["expected_revision"],
           let value = Self.number(raw), value != Double(document.revision) {
            return Self.fail("revision_mismatch",
                             "The document is at revision \(document.revision), not the requested "
                                + "\(Int(value)). Re-read it before this constraint action.")
        }
        switch action {
        case "addSketchConstraint": return addConstraint(args)
        case "updateSketchConstraint": return updateConstraint(args)
        default: return removeConstraint(args)
        }
    }

    // MARK: - Constraint actions

    private func addConstraint(_ args: [String: Any]) -> [String: Any] {
        let allowed: Set<String> = [
            "action", "revision", "expected_revision",
            "sketch_id", "sketchID", "sketch",
            "kind", "refs", "circle_tangency", "circleTangency",
        ]
        if let unknown = unknownKeys(args, allowed: allowed) { return unknown }
        guard let sketch = sketch(args) else {
            return Self.fail("missing_sketch",
                             "addSketchConstraint needs sketch_id (the UUID studio.read returned).")
        }
        guard let rawKind = Self.string(args["kind"]),
              let kind = SketchConstraintKind(rawValue: rawKind) else {
            return Self.fail("missing_kind",
                             "addSketchConstraint needs kind ("
                                + Self.constraintKindNames + ").")
        }
        guard let refs = parseRefs(args["refs"], sketch: sketch) else {
            return Self.fail("invalid_refs",
                             "refs must be a non-empty array of {entity_id, role"
                                + " (endpointA|endpointB|center|whole), rectangle_edge?}; every entity "
                                + "id must exist in this sketch.")
        }
        let tangency: CircleTangency?
        do { tangency = try parseTangency(args) } catch { return Self.fail("invalid_tangency", error.localizedDescription) }
        guard kind == .tangent || tangency == nil else {
            return Self.fail("invalid_tangency", "circle_tangency only applies to a tangent constraint.")
        }
        guard !sketch.constraints.contains(where: { $0.kind == kind && $0.refs == refs }) else {
            return Self.fail("duplicate_constraint",
                             "This sketch already has that \(kind.rawValue) constraint on the same references. "
                                + "Query kind=constraints for its existing id.")
        }
        let constraint = SketchConstraint(kind: kind, refs: refs, circleTangency: tangency)
        let before = document.session.changeCount
        document.session.perform(AddSketchConstraintCommand(sketchID: sketch.id, constraint: constraint))
        guard document.session.changeCount != before else {
            return Self.fail("no_change", "The constraint produced no document change.")
        }
        return Self.ok([
            "action": "addSketchConstraint",
            "mutated": true,
            "sketch": ["id": sketch.id.raw.uuidString, "name": sketch.name],
            "constraint": Self.constraintRow(constraint, sketchID: sketch.id),
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    private func updateConstraint(_ args: [String: Any]) -> [String: Any] {
        let allowed: Set<String> = [
            "action", "revision", "expected_revision",
            "sketch_id", "sketchID", "sketch",
            "constraint_id", "constraintID", "id",
            "kind", "refs", "circle_tangency", "circleTangency",
        ]
        if let unknown = unknownKeys(args, allowed: allowed) { return unknown }
        guard let sketch = sketch(args) else {
            return Self.fail("missing_sketch",
                             "updateSketchConstraint needs sketch_id (the UUID studio.read returned).")
        }
        guard let rawID = Self.string(args["constraint_id"] ?? args["constraintID"] ?? args["id"]),
              let id = UUID(uuidString: rawID),
              let index = sketch.constraints.firstIndex(where: { $0.id == id }) else {
            return Self.fail("unknown_constraint",
                             "updateSketchConstraint needs constraint_id from query kind=constraints.")
        }
        let existing = sketch.constraints[index]
        let kind: SketchConstraintKind
        if let raw = Self.string(args["kind"]) {
            guard let parsed = SketchConstraintKind(rawValue: raw) else {
                return Self.fail("invalid_kind", "kind must be one of " + Self.constraintKindNames + ".")
            }
            kind = parsed
        } else { kind = existing.kind }
        let refs: [ConstraintRef]
        if args["refs"] != nil {
            guard let parsed = parseRefs(args["refs"], sketch: sketch) else {
                return Self.fail("invalid_refs", "refs must reference existing entities in this sketch.")
            }
            refs = parsed
        } else { refs = existing.refs }
        let tangency: CircleTangency?
        do { tangency = try parseTangency(args, fallback: existing.circleTangency) }
        catch { return Self.fail("invalid_tangency", error.localizedDescription) }
        guard kind == .tangent || tangency == nil else {
            return Self.fail("invalid_tangency", "circle_tangency only applies to a tangent constraint.")
        }
        let updated = SketchConstraint(id: existing.id, kind: kind, refs: refs, circleTangency: tangency)
        guard updated != existing else {
            return Self.fail("no_change", "The constraint already has those values.")
        }
        let before = document.session.changeCount
        document.session.perform(UpdateSketchConstraintCommand(
            sketchID: sketch.id, before: existing, after: updated))
        guard document.session.changeCount != before else {
            return Self.fail("no_change", "The constraint update produced no document change.")
        }
        return Self.ok([
            "action": "updateSketchConstraint",
            "mutated": true,
            "sketch": ["id": sketch.id.raw.uuidString, "name": sketch.name],
            "constraint": Self.constraintRow(updated, sketchID: sketch.id),
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    private func removeConstraint(_ args: [String: Any]) -> [String: Any] {
        let allowed: Set<String> = [
            "action", "revision", "expected_revision",
            "sketch_id", "sketchID", "sketch",
            "constraint_id", "constraintID", "id",
        ]
        if let unknown = unknownKeys(args, allowed: allowed) { return unknown }
        guard let sketch = sketch(args) else {
            return Self.fail("missing_sketch",
                             "removeSketchConstraint needs sketch_id (the UUID studio.read returned).")
        }
        guard let rawID = Self.string(args["constraint_id"] ?? args["constraintID"] ?? args["id"]),
              let id = UUID(uuidString: rawID),
              let index = sketch.constraints.firstIndex(where: { $0.id == id }) else {
            return Self.fail("unknown_constraint",
                             "removeSketchConstraint needs constraint_id from query kind=constraints.")
        }
        let constraint = sketch.constraints[index]
        let before = document.session.changeCount
        document.session.perform(RemoveSketchConstraintCommand(
            sketchID: sketch.id, constraint: constraint, index: index))
        guard document.session.changeCount != before else {
            return Self.fail("no_change", "Removing the constraint produced no document change.")
        }
        return Self.ok([
            "action": "removeSketchConstraint",
            "mutated": true,
            "sketch": ["id": sketch.id.raw.uuidString, "name": sketch.name],
            "removed_constraint": Self.constraintRow(constraint, sketchID: sketch.id),
            "revision": document.revision,
            "change_count": document.session.changeCount,
            "can_undo": document.session.undoStack.canUndo,
            "can_redo": document.session.undoStack.canRedo,
        ])
    }

    // MARK: - Imported drawing geometry

    /// Append the exact entities of a decoded DXF/DWG drawing transfer into an
    /// explicit sketch. The existing source decoder, transfer validation and
    /// sketch-rebuild gate stay authoritative; this function only performs the
    /// one atomic entity append after the caller has verified its task file and
    /// the target original.
    public func importDrawingSketch(_ source: CADSketchTransferEnvelope,
                                    into sketchID: UUID,
                                    placement: CADSketchTransferPlacement) throws -> CADSketchImportReceipt {
        guard !document.isClosed else { throw CADSketchTransferError.invalid("The target model is closed.") }
        guard !document.isReadOnly, document.session.writeBlock == nil else {
            let block = document.session.writeBlock
            throw CADSketchTransferError.invalid(block?.message ?? "The target model is read-only.")
        }
        try source.validate()
        let target = SketchID(raw: sketchID)
        guard source.purpose == .modelSketch, placement.target == .selected,
              let sketch = document.session.document.sketches.first(where: { $0.id == target }) else {
            throw CADSketchImportError.targetUnavailable
        }
        let entities = try placement.entities(snapshot: source.snapshot)
        try Self.validate(entities)
        let existingIDs = Set(document.session.document.sketches.flatMap { $0.entities.map(\.id) })
        guard entities.count <= 40_000 - sketch.entities.count,
              Set(entities.map(\.id)).isDisjoint(with: existingIDs) else {
            throw CADSketchImportError.invalidGeometry
        }
        let checkpoint = document.captureEditCheckpoint()
        guard document.session.performWithSketchRebuild(
            AddSketchEntitiesCommand(sketchID: sketch.id, entities: entities,
                                     title: "Import drawing"), sketchID: sketch.id) else {
            document.restoreEditCheckpoint(checkpoint)
            throw CADSketchImportError.rebuildFailed
        }
        guard let result = document.session.document.sketches.first(where: { $0.id == sketch.id }),
              Set(entities.map(\.id)).isSubset(of: Set(result.entities.map(\.id))) else {
            document.restoreEditCheckpoint(checkpoint)
            throw CADSketchImportError.resultNeedsReview
        }
        return CADSketchImportReceipt(sketchID: sketch.id.raw,
                                      entityIDs: entities.map(\.id),
                                      editRevision: document.session.changeCount)
    }

    // MARK: - Validation and replies

    private static let constraintKindNames = "coincident, horizontal, vertical, parallel, perpendicular, equalLength, equalRadius, concentric, midpoint, symmetric, tangent, colinear, fixed"

    private func sketch(_ args: [String: Any]) -> Sketch? {
        guard let raw = Self.string(args["sketch_id"] ?? args["sketchID"] ?? args["sketch"]),
              let id = UUID(uuidString: raw) else { return nil }
        return document.session.document.sketches.first { $0.id.raw == id }
    }

    private func parseRefs(_ value: Any?, sketch: Sketch) -> [ConstraintRef]? {
        guard let rows = value as? [Any], (1...8).contains(rows.count) else { return nil }
        var refs: [ConstraintRef] = []
        for row in rows {
            guard let object = row as? [String: Any],
                  Set(object.keys).isSubset(of: ["entity_id", "entityID", "role", "rectangle_edge"]),
                  let rawEntity = Self.string(object["entity_id"] ?? object["entityID"]),
                  let entityID = UUID(uuidString: rawEntity),
                  sketch.entities.contains(where: { $0.id == entityID }),
                  let rawRole = Self.string(object["role"]),
                  let role = PointRole(rawValue: rawRole), role.isPersistable else { return nil }
            let edge: Int?
            if let raw = object["rectangle_edge"] {
                guard let number = Self.number(raw), number.rounded() == number,
                      (0...3).contains(Int(number)) else { return nil }
                edge = Int(number)
            } else { edge = nil }
            refs.append(ConstraintRef(entityID: entityID, role: role, rectangleEdge: edge))
        }
        return refs
    }

    private func parseTangency(_ args: [String: Any],
                               fallback: CircleTangency? = nil) throws -> CircleTangency? {
        guard let raw = args["circle_tangency"] ?? args["circleTangency"] else { return fallback }
        guard let value = raw as? String, let parsed = CircleTangency(rawValue: value) else {
            throw CADSketchTransferError.invalid("circle_tangency must be externalContact or internalContact.")
        }
        return parsed
    }

    private func unknownKeys(_ args: [String: Any], allowed: Set<String>) -> [String: Any]? {
        let unknown = args.keys.filter { !allowed.contains($0) }.sorted()
        guard !unknown.isEmpty else { return nil }
        return Self.fail("unknown_argument",
                         "Unknown argument(s) \(unknown.joined(separator: ", ")). Allowed: "
                            + allowed.sorted().joined(separator: ", ") + ".")
    }

    private static func validate(_ entities: [SketchEntity]) throws {
        guard !entities.isEmpty, entities.count <= 40_000,
              Set(entities.map(\.id)).count == entities.count else {
            throw CADSketchImportError.invalidGeometry
        }
        func number(_ value: Double) -> Bool { value.isFinite && abs(value) <= 1e12 }
        func point(_ value: SIMD2<Double>) -> Bool { number(value.x) && number(value.y) }
        for entity in entities {
            let valid: Bool
            switch entity {
            case let .line(_, a, b): valid = point(a) && point(b) && a != b
            case let .rect(_, lo, hi): valid = point(lo) && point(hi) && lo.x < hi.x && lo.y < hi.y
            case let .circle(_, center, r): valid = point(center) && number(r) && r > 0
            case let .arc(_, center, r, a, b):
                valid = point(center) && number(r) && r > 0 && number(a) && number(b)
                    && SketchEntity.arcSweep(startAngle: a, endAngle: b) > 1e-9
            case let .ellipse(_, center, rx, ry, rotation):
                valid = point(center) && number(rx) && number(ry) && rx > 0 && ry > 0 && number(rotation)
            case let .polygon(_, center, r, sides, rotation):
                valid = point(center) && number(r) && r > 0 && (3...20_000).contains(sides) && number(rotation)
            case let .spline(_, points, _):
                valid = points.count >= 2 && points.allSatisfy(point)
            case let .exactCurve(_, definition):
                valid = (try? definition.tessellatedPoints().allSatisfy(point)) == true
            }
            guard valid else { throw CADSketchImportError.invalidGeometry }
        }
    }

    private static func constraintRow(_ constraint: SketchConstraint, sketchID: SketchID) -> [String: Any] {
        var row: [String: Any] = [
            "id": constraint.id.uuidString,
            "sketchID": sketchID.raw.uuidString,
            "kind": constraint.kind.rawValue,
            "refs": constraint.refs.map {
                ["entity_id": $0.entityID.uuidString, "role": $0.role.rawValue,
                 "rectangle_edge": $0.rectangleEdge ?? NSNull()] as [String: Any]
            },
        ]
        if let tangency = constraint.circleTangency { row["circle_tangency"] = tangency.rawValue }
        return row
    }

    private static func fail(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "mutated": false, "error": code, "message": message]
    }
    private static func ok(_ value: [String: Any]) -> [String: Any] {
        var reply = value
        reply["ok"] = true
        return reply
    }
    private static func string(_ value: Any?) -> String? {
        value as? String
    }
    private static func number(_ value: Any) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

/// One undoable constraint replacement. The existing Remove/Add commands would
/// move the relation to the end of the saved array; this keeps its position so
/// undo/redo restores the exact prior ordering.
private struct UpdateSketchConstraintCommand: DocumentCommand {
    let title = "Edit Constraint"
    let sketchID: SketchID
    let before: SketchConstraint
    let after: SketchConstraint

    func apply(to document: inout DesignDocument) {
        replace(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        replace(before, in: &document)
    }

    private func replace(_ constraint: SketchConstraint, in document: inout DesignDocument) {
        guard let sketchIndex = document.sketches.firstIndex(where: { $0.id == sketchID }),
              let index = document.sketches[sketchIndex].constraints.firstIndex(where: { $0.id == constraint.id })
        else { return }
        document.sketches[sketchIndex].constraints[index] = constraint
    }
}
