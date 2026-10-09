//
//  Commands.swift
//  openshape3d
//
//  Undoable document mutations. Payloads are value snapshots — cheap because
//  mesh storage is copy-on-write.
//

import Foundation
import simd

protocol DocumentCommand {
    var title: String { get }
    func apply(to document: inout DesignDocument)
    func revert(in document: inout DesignDocument)
}

struct AddBodyCommand: DocumentCommand {
    let title: String
    let body: Body

    init(body: Body, title: String? = nil) {
        self.body = body
        self.title = title ?? "Add \(body.name)"
    }

    func apply(to document: inout DesignDocument) {
        document.bodies.append(body)
    }

    func revert(in document: inout DesignDocument) {
        document.bodies.removeAll { $0.id == body.id }
    }
}

struct DeleteBodiesCommand: DocumentCommand {
    let title = "Delete"
    /// Snapshots with original array indices so undo restores ordering.
    let removed: [(index: Int, body: Body)]

    init(ids: Set<BodyID>, document: DesignDocument) {
        removed = document.bodies.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { (index: $0.offset, body: $0.element) }
    }

    func apply(to document: inout DesignDocument) {
        let ids = Set(removed.map(\.body.id))
        document.bodies.removeAll { ids.contains($0.id) }
    }

    func revert(in document: inout DesignDocument) {
        for entry in removed.sorted(by: { $0.index < $1.index }) {
            let index = min(entry.index, document.bodies.count)
            document.bodies.insert(entry.body, at: index)
        }
    }
}

struct TransformBodiesCommand: DocumentCommand {
    /// Undo title: the tool that produced the transform ("Move" default;
    /// Scale/Rotate/Translate/Align pass their own).
    var title: String = "Move"
    let before: [BodyID: Transform3D]
    var after: [BodyID: Transform3D]

    func apply(to document: inout DesignDocument) {
        for (id, transform) in after {
            if let index = document.bodyIndex(of: id) {
                document.bodies[index].transform = transform
            }
        }
    }

    func revert(in document: inout DesignDocument) {
        for (id, transform) in before {
            if let index = document.bodyIndex(of: id) {
                document.bodies[index].transform = transform
            }
        }
    }
}

/// Swap a body's geometry/transform for a new version (face extrude,
/// push/pull results). Value snapshots both ways — of GEOMETRY: the body
/// keeps its live material and visibility (`Body.keepingAppearance`), since
/// several callers snapshot freshly built bodies that carry neither.
struct ReplaceBodyCommand: DocumentCommand {
    let title: String
    let before: Body
    let after: Body

    func apply(to document: inout DesignDocument) {
        if let index = document.bodyIndex(of: before.id) {
            var updated = after.keepingAppearance(of: document.bodies[index])
            updated.meshRevision = document.nextRevision()
            document.bodies[index] = updated
        }
    }

    func revert(in document: inout DesignDocument) {
        if let index = document.bodyIndex(of: before.id) {
            var restored = before.keepingAppearance(of: document.bodies[index])
            restored.meshRevision = document.nextRevision()
            document.bodies[index] = restored
        }
    }
}

/// Replace the target body's geometry with the boolean result and consume the
/// tool body. Both originals are snapshotted for undo. The result is built
/// fresh from the CSG mesh, so — like `ReplaceBodyCommand` — the target keeps
/// its live material and visibility; the tool's paint goes with the tool.
struct BooleanCommand: DocumentCommand {
    let title: String
    let targetBefore: Body
    let toolIndex: Int
    let toolBefore: Body
    /// Result body — same ID as the target, world-space mesh, identity transform.
    let result: Body

    init(kind: BooleanKind, targetBefore: Body, toolIndex: Int, toolBefore: Body, result: Body) {
        self.title = kind.rawValue.capitalized
        self.targetBefore = targetBefore
        self.toolIndex = toolIndex
        self.toolBefore = toolBefore
        self.result = result
    }

    func apply(to document: inout DesignDocument) {
        if let index = document.bodyIndex(of: targetBefore.id) {
            var updated = result.keepingAppearance(of: document.bodies[index])
            updated.meshRevision = document.nextRevision()
            document.bodies[index] = updated
        }
        document.bodies.removeAll { $0.id == toolBefore.id }
    }

    func revert(in document: inout DesignDocument) {
        if let index = document.bodyIndex(of: targetBefore.id) {
            var restored = targetBefore.keepingAppearance(of: document.bodies[index])
            restored.meshRevision = document.nextRevision()
            document.bodies[index] = restored
        }
        let index = min(toolIndex, document.bodies.count)
        var restoredTool = toolBefore
        restoredTool.meshRevision = document.nextRevision()
        document.bodies.insert(restoredTool, at: index)
    }
}

/// Groups several commands into one undo step (e.g. a cut that subtracts
/// from every intersected body commits one ReplaceBodyCommand per body).
struct CompositeCommand: DocumentCommand {
    let title: String
    let commands: [DocumentCommand]

    func apply(to document: inout DesignDocument) {
        for command in commands {
            command.apply(to: &document)
        }
    }

    func revert(in document: inout DesignDocument) {
        for command in commands.reversed() {
            command.revert(in: &document)
        }
    }
}

struct AddSketchEntityCommand: DocumentCommand {
    let title = "Sketch"
    let sketchID: SketchID
    let entity: SketchEntity
    var rectangleSizingAnchor: RectangleSizingAnchor? = nil
    var circleRadiusDirection: SIMD2<Double>? = nil

    func apply(to document: inout DesignDocument) {
        if let index = document.sketches.firstIndex(where: { $0.id == sketchID }) {
            document.sketches[index].entities.append(entity)
            if let circleRadiusDirection {
                document.sketches[index].circleRadiusDirections[entity.id] = circleRadiusDirection
            }
            if let rectangleSizingAnchor {
                document.sketches[index].rectangleSizingAnchors[entity.id] = rectangleSizingAnchor
            }
        }
    }

    func revert(in document: inout DesignDocument) {
        if let index = document.sketches.firstIndex(where: { $0.id == sketchID }) {
            document.sketches[index].entities.removeAll { $0.id == entity.id }
            document.sketches[index].rectangleSizingAnchors.removeValue(forKey: entity.id)
            document.sketches[index].circleRadiusDirections.removeValue(forKey: entity.id)
        }
    }
}

/// Bulk entity insertion in one undo step (Text glyph outlines, projected
/// body edges); optionally arrives flagged as construction geometry.
struct AddSketchEntitiesCommand: DocumentCommand {
    let title: String
    let sketchID: SketchID
    let entities: [SketchEntity]
    let asConstruction: Bool

    init(
        sketchID: SketchID, entities: [SketchEntity],
        title: String = "Sketch", asConstruction: Bool = false
    ) {
        self.sketchID = sketchID
        self.entities = entities
        self.title = title
        self.asConstruction = asConstruction
    }

    func apply(to document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].entities.append(contentsOf: entities)
        if asConstruction {
            document.sketches[index].setConstruction(true, forEntityIDs: entities.map(\.id))
        }
    }

    func revert(in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        let ids = Set(entities.map(\.id))
        document.sketches[index].entities.removeAll { ids.contains($0.id) }
        if asConstruction {
            document.sketches[index].setConstruction(false, forEntityIDs: ids)
        }
    }
}

/// Make Construction / Make Regular (spec §3.3): flips the construction flag
/// on a batch of sketch entities. Only IDs whose flag actually changes are
/// stored, so revert restores exactly the prior state.
struct SetConstructionCommand: DocumentCommand {
    let title: String
    let sketchID: SketchID
    let isConstruction: Bool
    let changedIDs: Set<UUID>

    init(sketchID: SketchID, entityIDs: Set<UUID>, isConstruction: Bool, sketch: Sketch) {
        self.sketchID = sketchID
        self.isConstruction = isConstruction
        self.changedIDs = entityIDs.filter { sketch.isConstruction($0) != isConstruction }
        self.title = isConstruction ? "Make Construction" : "Make Regular"
    }

    private func set(_ flag: Bool, in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].setConstruction(flag, forEntityIDs: changedIDs)
    }

    func apply(to document: inout DesignDocument) {
        set(isConstruction, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        set(!isConstruction, in: &document)
    }
}

/// Add a symbolic geometric constraint to a sketch (plan §C3). Applied
/// together with any solver-moved entity updates inside a `CompositeCommand`,
/// so one undo removes the constraint AND restores the pre-solve geometry.
struct AddSketchConstraintCommand: DocumentCommand {
    let title = "Constraint"
    let sketchID: SketchID
    let constraint: SketchConstraint

    func apply(to document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].constraints.append(constraint)
    }

    func revert(in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].constraints.removeAll { $0.id == constraint.id }
    }
}

/// Add a driving dimension to a sketch (plan §C2). Like a constraint, it is
/// applied together with any solver-moved entity updates in a
/// `CompositeCommand`, so one undo removes the dimension AND restores the
/// pre-solve geometry.
struct AddSketchDimensionCommand: DocumentCommand {
    let title = "Dimension"
    let sketchID: SketchID
    let dimension: SketchDimension

    func apply(to document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].dimensions.append(dimension)
    }

    func revert(in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].dimensions.removeAll { $0.id == dimension.id }
    }
}

/// Change a driving dimension's value (plan §C2). Paired with the solver-moved
/// entity updates in a `CompositeCommand` so editing a label is one undo step.
struct UpdateSketchDimensionCommand: DocumentCommand {
    let title = "Edit Dimension"
    let sketchID: SketchID
    let before: SketchDimension
    let after: SketchDimension

    private func replace(_ dimension: SketchDimension, in document: inout DesignDocument) {
        guard let sketchIndex = document.sketches.firstIndex(where: { $0.id == sketchID }),
              let dimIndex = document.sketches[sketchIndex].dimensions.firstIndex(where: {
                  $0.id == dimension.id
              })
        else { return }
        document.sketches[sketchIndex].dimensions[dimIndex] = dimension
    }

    func apply(to document: inout DesignDocument) {
        replace(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        replace(before, in: &document)
    }
}

/// Remove a symbolic constraint from a sketch (plan §C, constraint delete).
/// Undo re-appends it at its original position so the relationship (and any
/// re-solve it drove) is restored exactly.
struct RemoveSketchConstraintCommand: DocumentCommand {
    let title = "Delete Constraint"
    let sketchID: SketchID
    let constraint: SketchConstraint
    /// Original index so undo restores ordering.
    let index: Int

    func apply(to document: inout DesignDocument) {
        guard let s = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[s].constraints.removeAll { $0.id == constraint.id }
    }

    func revert(in document: inout DesignDocument) {
        guard let s = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        let clamped = min(max(index, 0), document.sketches[s].constraints.count)
        document.sketches[s].constraints.insert(constraint, at: clamped)
    }
}

/// Remove a driving dimension from a sketch (plan §C2). Undo re-appends it at
/// its original position.
struct RemoveSketchDimensionCommand: DocumentCommand {
    let title = "Delete Dimension"
    let sketchID: SketchID
    let dimension: SketchDimension
    let index: Int

    func apply(to document: inout DesignDocument) {
        guard let s = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[s].dimensions.removeAll { $0.id == dimension.id }
    }

    func revert(in document: inout DesignDocument) {
        guard let s = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        let clamped = min(max(index, 0), document.sketches[s].dimensions.count)
        document.sketches[s].dimensions.insert(dimension, at: clamped)
    }
}

/// Drag-edit of a sketch entity (endpoint/center/body moves). Coalesced with
/// `session.amend` during the drag, like TransformBodiesCommand.
struct UpdateSketchEntityCommand: DocumentCommand {
    let title = "Move"
    let sketchID: SketchID
    let before: SketchEntity
    let after: SketchEntity

    private func replace(_ entity: SketchEntity, in document: inout DesignDocument) {
        guard let sketchIndex = document.sketches.firstIndex(where: { $0.id == sketchID }),
              let entityIndex = document.sketches[sketchIndex].entities.firstIndex(where: {
                  $0.id == entity.id
              })
        else { return }
        document.sketches[sketchIndex].entities[entityIndex] = entity
    }

    func apply(to document: inout DesignDocument) {
        replace(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        replace(before, in: &document)
    }
}

/// Re-host a sketch on a different plane (spec §2.4). Entity coordinates are
/// plane-LOCAL, so they are left untouched: the drawing keeps its shape and
/// simply lands on the new plane, which is what "change the sketch plane"
/// means to the user. Everything built from the sketch re-evaluates against the
/// new orientation, so an extrude follows the sketch onto the new plane.
struct ChangeSketchPlaneCommand: DocumentCommand {
    let title = "Change Sketch Plane"
    let sketchID: SketchID
    let before: SketchPlane
    let after: SketchPlane

    private func setPlane(_ plane: SketchPlane, in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID })
        else { return }
        document.sketches[index].plane = plane
    }

    func apply(to document: inout DesignDocument) { setPlane(after, in: &document) }
    func revert(in document: inout DesignDocument) { setPlane(before, in: &document) }
}

/// Disconnect changes topology only; dimensions, geometry and unrelated
/// relationships are deliberately outside this command's mutation scope.
struct DisconnectSketchEndpointsCommand: DocumentCommand {
    let title = "Disconnect"
    let sketchID: SketchID
    let beforeConstraints: [SketchConstraint]
    let afterConstraints: [SketchConstraint]
    let beforeEndpoints: [ConstraintRef]
    let afterEndpoints: [ConstraintRef]

    private func set(_ constraints: [SketchConstraint], _ endpoints: [ConstraintRef],
                     in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].constraints = constraints
        document.sketches[index].disconnectedEndpoints = endpoints
    }
    func apply(to document: inout DesignDocument) { set(afterConstraints, afterEndpoints, in: &document) }
    func revert(in document: inout DesignDocument) { set(beforeConstraints, beforeEndpoints, in: &document) }
}

/// Solve-on-edit multi-entity update (plan §C1): a constraint solve during a
/// drag moves several entities at once. `before`/`after` are full snapshots
/// keyed by ID and applied ABSOLUTELY (set-by-ID, not delta), so the command
/// amend-coalesces cleanly across drag frames — every frame re-applies the
/// complete solved state, leaving no stale intermediate positions behind.
struct UpdateSketchEntitiesCommand: DocumentCommand {
    let title = "Move"
    let sketchID: SketchID
    let before: [SketchEntity]
    let after: [SketchEntity]

    private func replace(_ entities: [SketchEntity], in document: inout DesignDocument) {
        guard let sketchIndex = document.sketches.firstIndex(where: { $0.id == sketchID })
        else { return }
        var byID = [UUID: SketchEntity](minimumCapacity: entities.count)
        for entity in entities { byID[entity.id] = entity }
        for i in document.sketches[sketchIndex].entities.indices {
            if let replacement = byID[document.sketches[sketchIndex].entities[i].id] {
                document.sketches[sketchIndex].entities[i] = replacement
            }
        }
    }

    func apply(to document: inout DesignDocument) {
        replace(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        replace(before, in: &document)
    }
}

/// A distance-type change with its own history identity; no geometry movement.
struct SetLineDimensionKindCommand: DocumentCommand {
    let title = "Distance Type"
    let sketchID: SketchID
    let entityID: UUID
    let before: DimensionKind?
    let after: DimensionKind?
    var beforeDimension: SketchDimension? = nil
    var afterDimension: SketchDimension? = nil

    func apply(to document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].lineDimensionKinds[entityID] = after
        if let dimension = afterDimension,
           let dimensionIndex = document.sketches[index].dimensions.firstIndex(where: { $0.id == dimension.id }) {
            document.sketches[index].dimensions[dimensionIndex] = dimension
        }
    }
    func revert(in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].lineDimensionKinds[entityID] = before
        if let dimension = beforeDimension,
           let dimensionIndex = document.sketches[index].dimensions.firstIndex(where: { $0.id == dimension.id }) {
            document.sketches[index].dimensions[dimensionIndex] = dimension
        }
    }
}

/// Atomic topology/reference migration together with the initiating gesture.
/// Both snapshots retain the same sketch identity; Undo restores the primitive
/// and its original references rather than leaving a separate decomposition.
struct ReplaceSketchGeometryCommand: DocumentCommand {
    let title: String
    let before: Sketch
    let after: Sketch

    private func replace(_ sketch: Sketch, in document: inout DesignDocument) {
        guard before.id == after.id,
              let index = document.sketches.firstIndex(where: { $0.id == before.id }) else { return }
        document.sketches[index] = sketch
    }
    func apply(to document: inout DesignDocument) { replace(after, in: &document) }
    func revert(in document: inout DesignDocument) { replace(before, in: &document) }
}

/// The 2D position a `ConstraintRef` role names on an entity, for re-anchoring
/// constraints across trim. Nil for roles the entity doesn't have (and for
/// `.whole`, which is not a point).
private nonisolated func sketchPoint(_ entity: SketchEntity, role: PointRole) -> SIMD2<Double>? {
    switch (entity, role) {
    case let (.line(_, a, _), .endpointA): return a
    case let (.line(_, _, b), .endpointB): return b
    case let (.rect(_, mn, _), .endpointA): return mn
    case let (.rect(_, _, mx), .endpointB): return mx
    case let (.circle(_, c, _), .center): return c
    case let (.arc(_, c, r, sa, _), .endpointA): return c + r * SIMD2(cos(sa), sin(sa))
    case let (.arc(_, c, r, _, ea), .endpointB): return c + r * SIMD2(cos(ea), sin(ea))
    case let (.arc(_, c, _, _, _), .center): return c
    case let (.polygon(_, c, _, _, _), .center): return c
    default: return nil
    }
}

struct RemoveSketchEntitiesCommand: DocumentCommand {
    let title = "Delete"
    let sketchID: SketchID
    /// Snapshots with original array indices so undo restores ordering.
    let removed: [(index: Int, entity: SketchEntity)]
    /// Constraints/dimensions that referenced a removed entity — deleted in
    /// the SAME command, restored by the same undo. Leaving them behind was
    /// review R2-2: the solver silently dropped the dangling residuals, so a
    /// driving dimension kept displaying its value while driving nothing.
    let removedConstraints: [(index: Int, constraint: SketchConstraint)]
    let removedDimensions: [(index: Int, dimension: SketchDimension)]

    let beforeDisconnected: [ConstraintRef]
    let removedRectangleAnchors: [UUID: RectangleSizingAnchor]
    let removedRectangleGroups: [UUID: [UUID]]
    let removedLineDimensionKinds: [UUID: DimensionKind]

    init(ids: Set<UUID>, sketch: Sketch) {
        let affectedGroups = sketch.rotatedRectangleEdges.filter { !ids.isDisjoint(with: $0.value) }
        removedRectangleGroups = affectedGroups
        removedLineDimensionKinds = sketch.lineDimensionKinds.filter { ids.contains($0.key) }
        removedRectangleAnchors = sketch.rectangleSizingAnchors.filter { ids.contains($0.key) || affectedGroups[$0.key] != nil }
        beforeDisconnected = sketch.disconnectedEndpoints
        sketchID = sketch.id
        removed = sketch.entities.enumerated()
            .filter { ids.contains($0.element.id) }
            .map { (index: $0.offset, entity: $0.element) }
        removedConstraints = sketch.constraints.enumerated()
            .filter { $0.element.refs.contains { ids.contains($0.entityID) || ($0.role == .center && affectedGroups[$0.entityID] != nil) } }
            .map { (index: $0.offset, constraint: $0.element) }
        removedDimensions = sketch.dimensions.enumerated()
            .filter { $0.element.refs.contains { ids.contains($0.entityID) || ($0.role == .center && affectedGroups[$0.entityID] != nil) } }
            .map { (index: $0.offset, dimension: $0.element) }
    }

    func apply(to document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        apply(toSketch: &document.sketches[index])
    }

    /// The same removal on a sketch value — what a live preview of a
    /// split-off subset needs before the command is performed.
    func apply(toSketch sketch: inout Sketch) {
        let ids = Set(removed.map(\.entity.id))
        sketch.lineDimensionKinds = sketch.lineDimensionKinds.filter { !ids.contains($0.key) }
        sketch.rectangleSizingAnchors = sketch.rectangleSizingAnchors.filter { removedRectangleAnchors[$0.key] == nil }
        sketch.rotatedRectangleEdges = sketch.rotatedRectangleEdges.filter { removedRectangleGroups[$0.key] == nil }
        sketch.disconnectedEndpoints.removeAll { ids.contains($0.entityID) }
        sketch.entities.removeAll { ids.contains($0.id) }
        let constraintIDs = Set(removedConstraints.map(\.constraint.id))
        sketch.constraints.removeAll { constraintIDs.contains($0.id) }
        let dimensionIDs = Set(removedDimensions.map(\.dimension.id))
        sketch.dimensions.removeAll { dimensionIDs.contains($0.id) }
    }

    func revert(in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].disconnectedEndpoints = beforeDisconnected
        document.sketches[index].lineDimensionKinds.merge(removedLineDimensionKinds) { _, restored in restored }
        document.sketches[index].rotatedRectangleEdges.merge(removedRectangleGroups) { _, restored in restored }
        document.sketches[index].rectangleSizingAnchors.merge(removedRectangleAnchors) { _, restored in restored }
        for entry in removed.sorted(by: { $0.index < $1.index }) {
            let at = min(entry.index, document.sketches[index].entities.count)
            document.sketches[index].entities.insert(entry.entity, at: at)
        }
        for entry in removedConstraints.sorted(by: { $0.index < $1.index }) {
            let at = min(entry.index, document.sketches[index].constraints.count)
            document.sketches[index].constraints.insert(entry.constraint, at: at)
        }
        for entry in removedDimensions.sorted(by: { $0.index < $1.index }) {
            let at = min(entry.index, document.sketches[index].dimensions.count)
            document.sketches[index].dimensions.insert(entry.dimension, at: at)
        }
    }
}

/// Trim: replace one entity with the fragments left after deleting a span
/// (may be empty — the whole entity goes away).
///
/// Constraints and dimensions on the trimmed entity are handled in the SAME
/// command (review R2-2): a point-role ref re-anchors to whichever fragment
/// has a point at the same position; a `.whole` ref transfers when exactly
/// one fragment survives — or when every fragment is an arc of the SAME
/// supporting circle, where the statement stays unambiguous; anything that
/// can't transfer is dropped (and restored by undo) rather than left
/// dangling with a displayed value that drives nothing.
struct TrimCommand: DocumentCommand {
    let title = "Trim"
    let beforeDisconnected: [ConstraintRef]?
    let afterDisconnected: [ConstraintRef]?
    let beforeLineDimensionKinds: [UUID: DimensionKind]?
    let sketchID: SketchID
    let index: Int
    let removed: SketchEntity
    let fragments: [SketchEntity]
    let retargetedConstraints: [(index: Int, before: SketchConstraint, after: SketchConstraint)]
    let retargetedDimensions: [(index: Int, before: SketchDimension, after: SketchDimension)]
    let droppedConstraints: [(index: Int, constraint: SketchConstraint)]
    let droppedDimensions: [(index: Int, dimension: SketchDimension)]

    /// Legacy form with no constraint context (tests, callers that manage
    /// constraints themselves): geometry only.
    init(sketchID: SketchID, index: Int, removed: SketchEntity, fragments: [SketchEntity]) {
        self.sketchID = sketchID
        self.index = index
        self.removed = removed
        self.fragments = fragments
        beforeDisconnected = nil
        afterDisconnected = nil
        beforeLineDimensionKinds = nil
        retargetedConstraints = []
        retargetedDimensions = []
        droppedConstraints = []
        droppedDimensions = []
    }

    init(sketch: Sketch, index: Int, removed: SketchEntity, fragments: [SketchEntity]) {
        self.sketchID = sketch.id
        self.index = index
        self.removed = removed
        self.fragments = fragments

        /// Rewrite one ref off the trimmed entity, or nil when it can't move.
        func retarget(_ ref: ConstraintRef) -> ConstraintRef? {
            guard ref.entityID == removed.id else { return ref }
            if ref.role == .whole {
                // "The line is horizontal" transfers cleanly to a single
                // surviving piece; with two pieces the statement is ambiguous.
                if fragments.count == 1 {
                    return ConstraintRef(entityID: fragments[0].id, role: .whole)
                }
                // EXCEPT for same-circle arcs: a whole-entity statement about
                // a circle or arc (tangent, equal radius, a radius dimension)
                // is a statement about its SUPPORTING CIRCLE — center plus
                // radius — and every arc fragment of one trim carries that
                // circle identically, so the transfer is unambiguous. Anchor
                // the first fragment.
                if case let .arc(_, c0, r0, _, _)? = fragments.first,
                   fragments.allSatisfy({
                       if case let .arc(_, c, r, _, _) = $0 {
                           return simd_length(c - c0) < 1e-6 && abs(r - r0) < 1e-6
                       }
                       return false
                   }) {
                    return ConstraintRef(entityID: fragments[0].id, role: .whole)
                }
                return nil
            }
            guard let oldPoint = sketchPoint(removed, role: ref.role) else { return nil }
            for fragment in fragments {
                for role in [PointRole.endpointA, .endpointB, .center] {
                    if let p = sketchPoint(fragment, role: role),
                       simd_length(p - oldPoint) < 1e-6 {
                        return ConstraintRef(entityID: fragment.id, role: role)
                    }
                }
            }
            return nil  // the constrained point was on the span trimmed away
        }

        beforeDisconnected = sketch.disconnectedEndpoints
        beforeLineDimensionKinds = sketch.lineDimensionKinds
        afterDisconnected = sketch.disconnectedEndpoints.compactMap(retarget)

        var retargetedC: [(Int, SketchConstraint, SketchConstraint)] = []
        var droppedC: [(Int, SketchConstraint)] = []
        for (i, constraint) in sketch.constraints.enumerated()
        where constraint.refs.contains(where: { $0.entityID == removed.id }) {
            let newRefs = constraint.refs.compactMap(retarget)
            if newRefs.count == constraint.refs.count {
                var after = constraint
                after.refs = newRefs
                retargetedC.append((i, constraint, after))
            } else {
                droppedC.append((i, constraint))
            }
        }
        var retargetedD: [(Int, SketchDimension, SketchDimension)] = []
        var droppedD: [(Int, SketchDimension)] = []
        for (i, dimension) in sketch.dimensions.enumerated()
        where dimension.refs.contains(where: { $0.entityID == removed.id }) {
            if case let .rect(_, lo, hi) = removed,
               let edge = dimension.rectangleDrivingEdge,
               (0..<4).contains(edge),
               dimension.refs.allSatisfy({ $0.entityID == removed.id }) {
                // A rectangle size is solved through diagonal points, but its
                // owning edge must survive in full. Do not transfer a removed
                // top-edge driver to the bottom just because both corners live.
                let corners = [lo, SIMD2(hi.x, lo.y), hi, SIMD2(lo.x, hi.y)]
                let a = corners[edge], b = corners[(edge + 1) % 4]
                let survivor = fragments.first {
                    guard case let .line(_, p, q) = $0 else { return false }
                    return (simd_length(p - a) < 1e-6 && simd_length(q - b) < 1e-6)
                        || (simd_length(p - b) < 1e-6 && simd_length(q - a) < 1e-6)
                }
                if let survivor {
                    var after = dimension
                    after.refs = [.init(entityID: survivor.id, role: .endpointA),
                                  .init(entityID: survivor.id, role: .endpointB)]
                    after.rectangleDrivingEdge = nil
                    after.rectangleLabelEdges = nil
                    retargetedD.append((i, dimension, after))
                } else {
                    droppedD.append((i, dimension))
                }
                continue
            }
            let newRefs = dimension.refs.compactMap(retarget)
            if newRefs.count == dimension.refs.count {
                var after = dimension
                after.refs = newRefs
                retargetedD.append((i, dimension, after))
            } else {
                droppedD.append((i, dimension))
            }
        }
        retargetedConstraints = retargetedC.map { (index: $0.0, before: $0.1, after: $0.2) }
        retargetedDimensions = retargetedD.map { (index: $0.0, before: $0.1, after: $0.2) }
        droppedConstraints = droppedC.map { (index: $0.0, constraint: $0.1) }
        droppedDimensions = droppedD.map { (index: $0.0, dimension: $0.1) }
    }

    func apply(to document: inout DesignDocument) {
        guard let sketchIndex = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        if let afterDisconnected { document.sketches[sketchIndex].disconnectedEndpoints = afterDisconnected }
        if beforeLineDimensionKinds != nil,
           let kind = document.sketches[sketchIndex].lineDimensionKinds.removeValue(forKey: removed.id) {
            for fragment in fragments {
                if case .line = fragment { document.sketches[sketchIndex].lineDimensionKinds[fragment.id] = kind }
            }
        }
        document.sketches[sketchIndex].entities.removeAll { $0.id == removed.id }
        let at = min(index, document.sketches[sketchIndex].entities.count)
        document.sketches[sketchIndex].entities.insert(contentsOf: fragments, at: at)
        for entry in retargetedConstraints {
            if let i = document.sketches[sketchIndex].constraints
                .firstIndex(where: { $0.id == entry.before.id }) {
                document.sketches[sketchIndex].constraints[i] = entry.after
            }
        }
        for entry in retargetedDimensions {
            if let i = document.sketches[sketchIndex].dimensions
                .firstIndex(where: { $0.id == entry.before.id }) {
                document.sketches[sketchIndex].dimensions[i] = entry.after
            }
        }
        let droppedC = Set(droppedConstraints.map(\.constraint.id))
        document.sketches[sketchIndex].constraints.removeAll { droppedC.contains($0.id) }
        let droppedD = Set(droppedDimensions.map(\.dimension.id))
        document.sketches[sketchIndex].dimensions.removeAll { droppedD.contains($0.id) }
    }

    func revert(in document: inout DesignDocument) {
        guard let sketchIndex = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        if let beforeDisconnected { document.sketches[sketchIndex].disconnectedEndpoints = beforeDisconnected }
        if let beforeLineDimensionKinds { document.sketches[sketchIndex].lineDimensionKinds = beforeLineDimensionKinds }
        let ids = Set(fragments.map(\.id))
        document.sketches[sketchIndex].entities.removeAll { ids.contains($0.id) }
        let at = min(index, document.sketches[sketchIndex].entities.count)
        document.sketches[sketchIndex].entities.insert(removed, at: at)
        for entry in retargetedConstraints {
            if let i = document.sketches[sketchIndex].constraints
                .firstIndex(where: { $0.id == entry.after.id }) {
                document.sketches[sketchIndex].constraints[i] = entry.before
            }
        }
        for entry in retargetedDimensions {
            if let i = document.sketches[sketchIndex].dimensions
                .firstIndex(where: { $0.id == entry.after.id }) {
                document.sketches[sketchIndex].dimensions[i] = entry.before
            }
        }
        for entry in droppedConstraints.sorted(by: { $0.index < $1.index }) {
            let at = min(entry.index, document.sketches[sketchIndex].constraints.count)
            document.sketches[sketchIndex].constraints.insert(entry.constraint, at: at)
        }
        for entry in droppedDimensions.sorted(by: { $0.index < $1.index }) {
            let at = min(entry.index, document.sketches[sketchIndex].dimensions.count)
            document.sketches[sketchIndex].dimensions.insert(entry.dimension, at: at)
        }
    }
}

/// Mirror (spec §3): reflect a set of sketch entities across an axis line and
/// link each original point to its mirror with a `.symmetric` SketchConstraint,
/// so the copies keep tracking their sources under later solves. The mirrored
/// entities and their constraints are snapshotted with stable UUIDs at init
/// (via `mirroredSketchEntity`), so apply/revert are deterministic across
/// undo/redo and revert removes exactly what apply added.
struct MirrorSketchEntitiesCommand: DocumentCommand {
    let title = "Mirror"
    let sketchID: SketchID
    /// Mirrored copies (fresh IDs), one per valid source entity.
    let addedEntities: [SketchEntity]
    /// `.symmetric` constraints: refs = [source point, mirror point, axis line
    /// `.whole`] — the layout `SketchSolverBridge` lowers for `.symmetric`.
    let addedConstraints: [SketchConstraint]

    /// Fails when the axis entity is not a line in the sketch, or no source
    /// entity (other than the axis itself) resolves.
    init?(sketchID: SketchID, sourceEntityIDs: [UUID], axisEntityID: UUID, sketch: Sketch) {
        guard case let .line(_, axisA, axisB)? =
            sketch.entities.first(where: { $0.id == axisEntityID })
        else { return nil }

        let axisRef = ConstraintRef(entityID: axisEntityID, role: .whole)
        var entities: [SketchEntity] = []
        var constraints: [SketchConstraint] = []

        for id in sourceEntityIDs where id != axisEntityID {
            guard let source = sketch.entities.first(where: { $0.id == id }) else { continue }
            let mirror = mirroredSketchEntity(source, acrossA: axisA, b: axisB)
            entities.append(mirror)
            for role in source.symmetricPointRoles {
                // Only link a role pair when the mirror point is genuinely the
                // reflection of the source point across this axis. A rect's
                // corners are re-sorted into min/max by `mirroredSketchEntity`,
                // so an `.endpointA`↔`.endpointA` pairing there is geometrically
                // inconsistent (the `.symmetric` residual is nonzero from the
                // outset). Emitting it would make the next solve deform BOTH
                // rectangles, so those pairs are skipped — the mirror copy is
                // still placed correctly, just without a live link. Lines and
                // centre-based entities reflect role-for-role and are linked.
                guard let sp = source.symmetricPoint(for: role),
                      let mp = mirror.symmetricPoint(for: role)
                else { continue }
                let d = reflectPoint(sp, acrossA: axisA, b: axisB) - mp
                guard d.x * d.x + d.y * d.y <= 1e-12 else { continue }
                constraints.append(SketchConstraint(
                    kind: .symmetric,
                    refs: [
                        ConstraintRef(entityID: source.id, role: role),
                        ConstraintRef(entityID: mirror.id, role: role),
                        axisRef,
                    ]
                ))
            }
        }
        guard !entities.isEmpty else { return nil }

        self.sketchID = sketchID
        self.addedEntities = entities
        self.addedConstraints = constraints
    }

    func apply(to document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        document.sketches[index].entities.append(contentsOf: addedEntities)
        document.sketches[index].constraints.append(contentsOf: addedConstraints)
    }

    func revert(in document: inout DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == sketchID }) else { return }
        let entityIDs = Set(addedEntities.map(\.id))
        let constraintIDs = Set(addedConstraints.map(\.id))
        document.sketches[index].entities.removeAll { entityIDs.contains($0.id) }
        document.sketches[index].constraints.removeAll { constraintIDs.contains($0.id) }
    }
}

// MARK: - Feature graph (Phase D, Task C1)

/// Append a `FeatureNode` to the document's feature history as an undoable step.
///
/// This is the composable primitive the editor bundles into the SAME
/// `CompositeCommand` as the geometry command that created the body (e.g.
/// `AddBodyCommand` + `AppendFeatureCommand`), so a single user undo drops BOTH
/// the mesh and the history node — no orphan node survives the undo.
/// `DocumentSession.record(_:)` performs one of these standalone.
struct AppendFeatureCommand: DocumentCommand {
    let title: String
    let node: FeatureNode

    init(node: FeatureNode, title: String = "Add Feature") {
        self.node = node
        self.title = title
    }

    /// With a rollback marker set, a newly-created feature must land at the
    /// rollback point (right after the last ACTIVE node) — not tacked onto the
    /// tail behind the rolled-back nodes — and the marker advances to keep the
    /// new node active. When `rollbackIndex` is nil the behavior is byte-identical
    /// to a plain append.
    func apply(to document: inout DesignDocument) {
        if let cut = document.features.rollbackIndex {
            let at = min(cut, document.features.nodes.count)
            document.features.nodes.insert(node, at: at)
            document.features.rollbackIndex = cut + 1
        } else {
            document.features.nodes.append(node)
        }
    }

    func revert(in document: inout DesignDocument) {
        guard let idx = document.features.nodes.firstIndex(where: { $0.id == node.id })
        else { return }
        document.features.nodes.remove(at: idx)
        // The node counted toward the active prefix only if it sat before the
        // marker; if so, pull the marker back so it and the array stay in lockstep.
        if let cut = document.features.rollbackIndex, idx < cut {
            document.features.rollbackIndex = cut - 1
        }
    }
}

/// Change a feature node's operation parameters (e.g. an extrude distance edit).
/// Bundled inside the rebuild `CompositeCommand` (see
/// `DocumentSession.rebuildFrom`) together with the `ReplaceBody`/`AddBody`/
/// `DeleteBodies` commands the re-evaluation produced, so ONE undo reverts both
/// the parameter change and every downstream mesh it rebuilt.
struct EditFeatureCommand: DocumentCommand {
    let title = "Edit Feature"
    let featureID: FeatureID
    let before: FeatureKind
    let after: FeatureKind

    private func set(_ kind: FeatureKind, in document: inout DesignDocument) {
        guard let index = document.features.index(of: featureID) else { return }
        document.features.nodes[index].kind = kind
    }

    func apply(to document: inout DesignDocument) {
        set(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        set(before, in: &document)
    }
}

/// Change a feature node's operation parameters AND the set of body IDs it owns
/// in one step. Needed by pattern-count edits: bumping a linear/circular
/// pattern's `count` changes how many instance bodies the node produces, so the
/// node's `outputBodyIDs` must grow (fresh IDs the diff `AddBody`s) or shrink
/// (dropped IDs the diff `DeleteBodies`s) atomically with the spec change.
///
/// Like `EditFeatureCommand` (kind swap) but also swaps `outputBodyIDs`. Bundled
/// inside the rebuild `CompositeCommand` (see `DocumentSession.editPatternFeature`)
/// together with the `ReplaceBody`/`AddBody`/`DeleteBodies` commands the
/// re-evaluation produced, so ONE undo reverts the spec, the ownership change,
/// and every affected mesh.
struct EditFeatureOutputsCommand: DocumentCommand {
    let title = "Edit Feature"
    let featureID: FeatureID
    let beforeKind: FeatureKind
    let afterKind: FeatureKind
    let beforeOutputs: [BodyID]
    let afterOutputs: [BodyID]

    private func set(_ kind: FeatureKind, _ outputs: [BodyID], in document: inout DesignDocument) {
        guard let index = document.features.index(of: featureID) else { return }
        document.features.nodes[index].kind = kind
        document.features.nodes[index].outputBodyIDs = outputs
    }

    func apply(to document: inout DesignDocument) {
        set(afterKind, afterOutputs, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        set(beforeKind, beforeOutputs, in: &document)
    }
}

/// Toggle a feature node's suppress flag. Bundled with the rebuild body diff in
/// a `CompositeCommand` (same shape as `EditFeatureCommand`) so suppressing or
/// un-suppressing a step is one undo that also restores the affected meshes.
struct SetFeatureSuppressedCommand: DocumentCommand {
    let title: String
    let featureID: FeatureID
    let before: Bool
    let after: Bool

    init(featureID: FeatureID, before: Bool, after: Bool) {
        self.featureID = featureID
        self.before = before
        self.after = after
        self.title = after ? "Suppress Feature" : "Unsuppress Feature"
    }

    private func set(_ value: Bool, in document: inout DesignDocument) {
        guard let index = document.features.index(of: featureID) else { return }
        document.features.nodes[index].suppressed = value
    }

    func apply(to document: inout DesignDocument) {
        set(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        set(before, in: &document)
    }
}

/// Rename a feature history node (History panel). Standalone (not bundled with a
/// rebuild) — changing a node's display name never affects geometry. The VM
/// bundles this with `RenameItemCommand`s so the node and its bodies rename in
/// one undo step.
struct RenameFeatureCommand: DocumentCommand {
    let title = "Rename Feature"
    let featureID: FeatureID
    let before: String
    let after: String

    private func set(_ name: String, in document: inout DesignDocument) {
        guard let index = document.features.index(of: featureID) else { return }
        document.features.nodes[index].name = name
    }

    func apply(to document: inout DesignDocument) { set(after, in: &document) }
    func revert(in document: inout DesignDocument) { set(before, in: &document) }
}

/// Remove a feature node from the history (History panel delete). Bundled inside
/// the rebuild `CompositeCommand` (see `DocumentSession.deleteFeature`) with the
/// `ReplaceBody`/`DeleteBodies` commands the re-evaluation produced, so one undo
/// restores both the node (at its original position) and every affected mesh.
struct RemoveFeatureCommand: DocumentCommand {
    let title = "Delete Feature"
    let index: Int
    let node: FeatureNode
    /// The rollback marker BEFORE the removal, captured at construction so revert
    /// restores it EXACTLY. Recomputing `index < cut` in revert is wrong at the
    /// boundary `index == cut - 1` (the deleted node was the last active one):
    /// apply has already decremented the marker, so `index < cut` reads false and
    /// the marker is never pushed back — silently rolling the restored node back.
    let beforeRollback: Int?

    func apply(to document: inout DesignDocument) {
        document.features.nodes.removeAll { $0.id == node.id }
        // Removing an ACTIVE node (one before the marker) shortens the active
        // prefix by one; a rolled-back node leaves it unchanged.
        if let cut = beforeRollback {
            document.features.rollbackIndex = index < cut ? cut - 1 : cut
        }
    }

    func revert(in document: inout DesignDocument) {
        let clamped = min(max(index, 0), document.features.nodes.count)
        document.features.nodes.insert(node, at: clamped)
        document.features.rollbackIndex = beforeRollback   // exact restore
    }
}

/// Move (or clear) the feature-graph rollback marker (History panel "roll back to
/// here" / "return to latest"). Rides `DocumentSession.performRebuild` with the
/// downstream mesh diff so one undo restores both the marker and every body the
/// rolled-back nodes had produced. Value snapshots both ways (`Int?`, nil = no
/// rollback / all nodes active).
struct SetRollbackCommand: DocumentCommand {
    let before: Int?
    let after: Int?
    var title: String { after == nil ? "Return to Latest" : "Roll Back" }

    func apply(to document: inout DesignDocument) {
        document.features.rollbackIndex = after
    }

    func revert(in document: inout DesignDocument) {
        document.features.rollbackIndex = before
    }
}

/// Reorder a feature history node (History panel drag-to-reorder). Rides
/// `DocumentSession.moveFeature`'s `performRebuild` with the downstream mesh diff
/// so one undo restores both the ordering and every affected mesh. `evaluate`
/// replays nodes in array order, so moving a node earlier than one it references
/// simply fails that reference (`.brokenRef`) — surfaced as a History error badge
/// rather than being forbidden (mirrors Shapr3D). The rollback marker is a
/// positional COUNT and is intentionally left unchanged by a reorder.
///
/// Both indices are positions in the array AFTER the node is removed for the
/// move, so `remove(at:)`+`insert(at:)` is symmetric: apply inserts at `to`,
/// revert (which finds the node's current index by id) inserts back at `from`.
struct MoveFeatureCommand: DocumentCommand {
    let title = "Reorder Feature"
    let featureID: FeatureID
    let from: Int
    let to: Int

    private func reorder(toIndex: Int, in document: inout DesignDocument) {
        guard let current = document.features.index(of: featureID) else { return }
        var nodes = document.features.nodes
        let node = nodes.remove(at: current)
        nodes.insert(node, at: min(max(toIndex, 0), nodes.count))
        document.features.nodes = nodes
    }

    func apply(to document: inout DesignDocument) { reorder(toIndex: to, in: &document) }
    func revert(in document: inout DesignDocument) { reorder(toIndex: from, in: &document) }
}

// MARK: - Document variables (Phase D, Task B1 / spec §6.6)

/// Re-derive every variable's cached `.value` from its `.expression` in creation
/// order (VariableTable). `.value` is a pure cache of `.expression`, so any
/// command mutating `document.variables` re-resolves it here — keeping the cache
/// consistent across apply / undo / redo. (A snapshot value stored on the command
/// would go stale on redo, since redo re-applies the pre-edit `after.value`.)
func resolveVariableCache(_ document: inout DesignDocument) {
    let resolved = VariableTable.resolve(document.variables).resolved
    for index in document.variables.indices where index < resolved.count {
        document.variables[index].value = resolved[index].value
    }
}

/// Append a user-defined document variable to `document.variables`. The VM calls
/// `DocumentSession.variablesDidChange()` after performing this so the freshly
/// resolved values and any dependent feature/sketch formulas rebuild.
struct AddVariableCommand: DocumentCommand {
    let title = "Add Variable"
    let variable: Variable

    func apply(to document: inout DesignDocument) {
        document.variables.append(variable)
        resolveVariableCache(&document)
    }

    func revert(in document: inout DesignDocument) {
        document.variables.removeAll { $0.id == variable.id }
        resolveVariableCache(&document)
    }
}

/// Replace a variable's name/expression (same `id`) with a new snapshot. Full
/// value snapshots both ways; `before`/`after` share the variable's identity, so
/// this is a pure in-place replace located by `id`.
struct EditVariableCommand: DocumentCommand {
    let title = "Edit Variable"
    let before: Variable
    let after: Variable

    private func set(_ variable: Variable, in document: inout DesignDocument) {
        guard let index = document.variables.firstIndex(where: { $0.id == variable.id }) else { return }
        document.variables[index] = variable
    }

    func apply(to document: inout DesignDocument) {
        set(after, in: &document)
        resolveVariableCache(&document)
    }

    func revert(in document: inout DesignDocument) {
        set(before, in: &document)
        resolveVariableCache(&document)
    }
}

/// Remove a variable from `document.variables`. Undo re-inserts it at its
/// original position so creation-order (and every downstream reference resolved
/// against it) is restored exactly.
struct RemoveVariableCommand: DocumentCommand {
    let title = "Delete Variable"
    let index: Int
    let variable: Variable

    func apply(to document: inout DesignDocument) {
        document.variables.removeAll { $0.id == variable.id }
        resolveVariableCache(&document)
    }

    func revert(in document: inout DesignDocument) {
        let clamped = min(max(index, 0), document.variables.count)
        document.variables.insert(variable, at: clamped)
        resolveVariableCache(&document)
    }
}

// MARK: - Items Manager (spec §11)

/// A row in the Items Manager: any document item addressable by ID.
enum DocumentItemRef: Hashable {
    case body(BodyID)
    case sketch(SketchID)
    case plane(ConstructionPlaneID)
}

struct SetItemVisibilityCommand: DocumentCommand {
    let title: String
    /// Body/sketch/plane target; nil when the target is an inserted image.
    let item: DocumentItemRef?
    /// Inserted-image target (plan §B10). Images sit outside DocumentItemRef
    /// so the exhaustive switches over it across the app stay untouched.
    let imageID: InsertedImageID?
    let isHidden: Bool

    init(item: DocumentItemRef, isHidden: Bool) {
        self.item = item
        self.imageID = nil
        self.isHidden = isHidden
        self.title = isHidden ? "Hide" : "Show"
    }

    init(imageID: InsertedImageID, isHidden: Bool) {
        self.item = nil
        self.imageID = imageID
        self.isHidden = isHidden
        self.title = isHidden ? "Hide" : "Show"
    }

    private func setHidden(_ hidden: Bool, in document: inout DesignDocument) {
        if let imageID, let index = document.imageIndex(of: imageID) {
            document.images[index].isHidden = hidden
        }
        guard let item else { return }
        switch item {
        case .body(let id):
            if let index = document.bodyIndex(of: id) {
                document.bodies[index].isHidden = hidden
            }
        case .sketch(let id):
            if let index = document.sketches.firstIndex(where: { $0.id == id }) {
                document.sketches[index].isHidden = hidden
            }
        case .plane(let id):
            if let index = document.planes.firstIndex(where: { $0.id == id }) {
                document.planes[index].isHidden = hidden
            }
        }
    }

    func apply(to document: inout DesignDocument) {
        setHidden(isHidden, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        setHidden(!isHidden, in: &document)
    }
}

struct RenameItemCommand: DocumentCommand {
    let title = "Rename"
    /// Body/sketch/plane target; nil when the target is an inserted image.
    let item: DocumentItemRef?
    /// Inserted-image target (plan §B10), mirroring SetItemVisibilityCommand.
    let imageID: InsertedImageID?
    let before: String
    let after: String

    init(item: DocumentItemRef, before: String, after: String) {
        self.item = item
        self.imageID = nil
        self.before = before
        self.after = after
    }

    init(imageID: InsertedImageID, before: String, after: String) {
        self.item = nil
        self.imageID = imageID
        self.before = before
        self.after = after
    }

    private func setName(_ name: String, in document: inout DesignDocument) {
        if let imageID, let index = document.imageIndex(of: imageID) {
            document.images[index].name = name
        }
        guard let item else { return }
        switch item {
        case .body(let id):
            if let index = document.bodyIndex(of: id) {
                document.bodies[index].name = name
            }
        case .sketch(let id):
            if let index = document.sketches.firstIndex(where: { $0.id == id }) {
                document.sketches[index].name = name
            }
        case .plane:
            break // planes are unnamed in v1
        }
    }

    func apply(to document: inout DesignDocument) {
        setName(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        setName(before, in: &document)
    }
}

/// DXF import (plan §B14): creates the target sketch when no ground-plane
/// sketch exists yet, composed with AddSketchEntitiesCommand in one
/// CompositeCommand so the whole import is a single undo step.
struct AddSketchCommand: DocumentCommand {
    let title: String
    let sketch: Sketch

    init(sketch: Sketch, title: String = "Add Sketch") {
        self.sketch = sketch
        self.title = title
    }

    func apply(to document: inout DesignDocument) {
        document.sketches.append(sketch)
    }

    func revert(in document: inout DesignDocument) {
        document.sketches.removeAll { $0.id == sketch.id }
    }
}

struct DeleteSketchCommand: DocumentCommand {
    let title = "Delete"
    let index: Int
    let sketch: Sketch

    init?(id: SketchID, document: DesignDocument) {
        guard let index = document.sketches.firstIndex(where: { $0.id == id }) else { return nil }
        self.index = index
        self.sketch = document.sketches[index]
    }

    func apply(to document: inout DesignDocument) {
        document.sketches.removeAll { $0.id == sketch.id }
    }

    func revert(in document: inout DesignDocument) {
        document.sketches.insert(sketch, at: min(index, document.sketches.count))
    }
}

struct DeletePlaneCommand: DocumentCommand {
    let title = "Delete"
    let index: Int
    let plane: ConstructionPlane

    init?(id: ConstructionPlaneID, document: DesignDocument) {
        guard let index = document.planes.firstIndex(where: { $0.id == id }) else { return nil }
        self.index = index
        self.plane = document.planes[index]
    }

    func apply(to document: inout DesignDocument) {
        document.planes.removeAll { $0.id == plane.id }
    }

    func revert(in document: inout DesignDocument) {
        document.planes.insert(plane, at: min(index, document.planes.count))
    }
}

struct AddConstructionPlaneCommand: DocumentCommand {
    let title = "Offset Plane"
    let plane: ConstructionPlane

    func apply(to document: inout DesignDocument) {
        document.planes.append(plane)
    }

    func revert(in document: inout DesignDocument) {
        document.planes.removeAll { $0.id == plane.id }
    }
}

// MARK: - Construction axes (spec §6.2)

struct AddConstructionAxisCommand: DocumentCommand {
    let title: String
    let axis: ConstructionAxis

    init(axis: ConstructionAxis, title: String = "Add Axis") {
        self.axis = axis
        self.title = title
    }

    func apply(to document: inout DesignDocument) {
        document.axes.append(axis)
    }

    func revert(in document: inout DesignDocument) {
        document.axes.removeAll { $0.id == axis.id }
    }
}

struct DeleteAxisCommand: DocumentCommand {
    let title = "Delete"
    let index: Int
    let axis: ConstructionAxis

    init?(id: ConstructionAxisID, document: DesignDocument) {
        guard let index = document.axes.firstIndex(where: { $0.id == id }) else { return nil }
        self.index = index
        self.axis = document.axes[index]
    }

    func apply(to document: inout DesignDocument) {
        document.axes.removeAll { $0.id == axis.id }
    }

    func revert(in document: inout DesignDocument) {
        document.axes.insert(axis, at: min(index, document.axes.count))
    }
}

struct SetAxisHiddenCommand: DocumentCommand {
    let title: String
    let id: ConstructionAxisID
    let hidden: Bool

    init(id: ConstructionAxisID, hidden: Bool) {
        self.id = id
        self.hidden = hidden
        self.title = hidden ? "Hide Axis" : "Show Axis"
    }

    func apply(to document: inout DesignDocument) { set(&document, hidden) }
    func revert(in document: inout DesignDocument) { set(&document, !hidden) }

    private func set(_ document: inout DesignDocument, _ value: Bool) {
        guard let index = document.axes.firstIndex(where: { $0.id == id }) else { return }
        document.axes[index].isHidden = value
    }
}

struct RenameAxisCommand: DocumentCommand {
    let title = "Rename"
    let id: ConstructionAxisID
    let before: String
    let after: String

    init?(id: ConstructionAxisID, to newName: String, document: DesignDocument) {
        guard let axis = document.axes.first(where: { $0.id == id }) else { return nil }
        self.id = id
        self.before = axis.name
        self.after = newName
    }

    func apply(to document: inout DesignDocument) { set(&document, after) }
    func revert(in document: inout DesignDocument) { set(&document, before) }

    private func set(_ document: inout DesignDocument, _ value: String) {
        guard let index = document.axes.firstIndex(where: { $0.id == id }) else { return }
        document.axes[index].name = value
    }
}

struct ResizePrimitiveCommand: DocumentCommand {
    let title: String
    let bodyID: BodyID
    let beforeSpec: PrimitiveSpec
    let afterSpec: PrimitiveSpec

    init(bodyID: BodyID, beforeSpec: PrimitiveSpec, afterSpec: PrimitiveSpec) {
        self.bodyID = bodyID
        self.beforeSpec = beforeSpec
        self.afterSpec = afterSpec
        self.title = "Edit \(afterSpec.displayName)"
    }

    private func rebuild(_ document: inout DesignDocument, spec: PrimitiveSpec) {
        guard let index = document.bodyIndex(of: bodyID) else { return }
        let old = document.bodies[index]
        var rebuilt = Body(
            id: old.id,
            name: old.name,
            transform: old.transform,
            primitive: spec,
            euclidMesh: .primitive(spec),
            revision: document.nextRevision()
        )
        rebuilt.name = old.name
        // Carry the user-owned metadata the rebuild would otherwise reset —
        // resizing a hidden primitive used to make it visible again and drop
        // its material (2026-08-25 review round 2).
        rebuilt.isHidden = old.isHidden
        rebuilt.material = old.material
        // Rebuild the analytic B-rep too, mirroring FeatureGraph.evalPrimitive:
        // resizing an OCCT-rendered cylinder must not degrade it to the 48-gon
        // Euclid mesh (2026-08-25 review, C4). Curved primitives take the OCCT
        // tessellation for render+CSG; a box keeps the Euclid mesh but still
        // carries the brep so booleans stay analytic.
        if OCCTKernel.useOCCTAsSourceOfTruth,
           let handle = OCCTKernel.primitiveShape(spec, placement: .identity) {
            if OCCTKernel.hasCurvedFaces(spec) {
                rebuilt.adoptBRep(handle)
            } else {
                rebuilt.brep = handle
            }
        }
        document.bodies[index] = rebuilt
    }

    func apply(to document: inout DesignDocument) {
        rebuild(&document, spec: afterSpec)
    }

    func revert(in document: inout DesignDocument) {
        rebuild(&document, spec: beforeSpec)
    }
}

// MARK: - Materials (plan §B15)

/// Assigns one material to a set of bodies (Material sheet Apply). Per-body
/// before-snapshots restore mixed prior materials on undo.
struct SetMaterialCommand: DocumentCommand {
    let title = "Material"
    /// Prior material per body (nil value = legacy default look).
    let before: [BodyID: BodyMaterialSpec?]
    /// The material applied to every targeted body.
    let after: BodyMaterialSpec?

    init(bodyIDs: Set<BodyID>, material: BodyMaterialSpec?, document: DesignDocument) {
        var snapshots: [BodyID: BodyMaterialSpec?] = [:]
        for body in document.bodies where bodyIDs.contains(body.id) {
            snapshots[body.id] = body.material
        }
        self.before = snapshots
        self.after = material
    }

    func apply(to document: inout DesignDocument) {
        for id in before.keys {
            if let index = document.bodyIndex(of: id) {
                document.bodies[index].material = after
            }
        }
    }

    func revert(in document: inout DesignDocument) {
        for (id, material) in before {
            if let index = document.bodyIndex(of: id) {
                document.bodies[index].material = material
            }
        }
    }
}

// MARK: - Inserted images (plan §B10)

struct AddImageCommand: DocumentCommand {
    let title = "Insert Image"
    let image: InsertedImage

    func apply(to document: inout DesignDocument) {
        document.images.append(image)
    }

    func revert(in document: inout DesignDocument) {
        document.images.removeAll { $0.id == image.id }
    }
}

/// Gizmo move/resize and opacity-slider edits. Full value snapshots both ways
/// so `session.amend` coalesces a live drag into one undo step (same pattern
/// as UpdateSketchEntityCommand).
struct UpdateImageCommand: DocumentCommand {
    let title: String
    let before: InsertedImage
    let after: InsertedImage

    init(before: InsertedImage, after: InsertedImage, title: String = "Edit Image") {
        self.before = before
        self.after = after
        self.title = title
    }

    private func replace(_ image: InsertedImage, in document: inout DesignDocument) {
        if let index = document.imageIndex(of: before.id) {
            document.images[index] = image
        }
    }

    func apply(to document: inout DesignDocument) {
        replace(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        replace(before, in: &document)
    }
}

struct RemoveImageCommand: DocumentCommand {
    let title = "Delete"
    let index: Int
    let image: InsertedImage

    init?(id: InsertedImageID, document: DesignDocument) {
        guard let index = document.imageIndex(of: id) else { return nil }
        self.index = index
        self.image = document.images[index]
    }

    func apply(to document: inout DesignDocument) {
        document.images.removeAll { $0.id == image.id }
    }

    func revert(in document: inout DesignDocument) {
        document.images.insert(image, at: min(index, document.images.count))
    }
}

// MARK: - Symbols (plan §B16, spec §1.16)

struct AddSymbolCommand: DocumentCommand {
    let title = "Create Symbol"
    let symbol: Symbol

    func apply(to document: inout DesignDocument) {
        document.symbols.append(symbol)
    }

    func revert(in document: inout DesignDocument) {
        document.symbols.removeAll { $0.id == symbol.id }
    }
}

struct RenameSymbolCommand: DocumentCommand {
    let title = "Rename"
    let symbolID: SymbolID
    let before: String
    let after: String

    init?(id: SymbolID, to name: String, document: DesignDocument) {
        guard let symbol = document.symbols.first(where: { $0.id == id }) else { return nil }
        self.symbolID = id
        self.before = symbol.name
        self.after = name
    }

    private func setName(_ name: String, in document: inout DesignDocument) {
        guard let index = document.symbols.firstIndex(where: { $0.id == symbolID }) else { return }
        document.symbols[index].name = name
    }

    func apply(to document: inout DesignDocument) {
        setName(after, in: &document)
    }

    func revert(in document: inout DesignDocument) {
        setName(before, in: &document)
    }
}

struct RemoveSymbolCommand: DocumentCommand {
    let title = "Delete"
    let index: Int
    let symbol: Symbol

    init?(id: SymbolID, document: DesignDocument) {
        guard let index = document.symbols.firstIndex(where: { $0.id == id }) else { return nil }
        self.index = index
        self.symbol = document.symbols[index]
    }

    func apply(to document: inout DesignDocument) {
        document.symbols.removeAll { $0.id == symbol.id }
    }

    func revert(in document: inout DesignDocument) {
        document.symbols.insert(symbol, at: min(index, document.symbols.count))
    }
}
