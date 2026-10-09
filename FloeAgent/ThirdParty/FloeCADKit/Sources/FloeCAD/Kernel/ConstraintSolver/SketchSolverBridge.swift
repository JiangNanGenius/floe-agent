//
//  SketchSolverBridge.swift
//  openshape3d
//
//  Bridges the symbolic sketch model (entities + SketchConstraint +
//  SketchDimension) to the numeric Levenberg–Marquardt solver
//  (`ConstraintSolver` / `ConstraintResidual`). It:
//
//   1. Collects each entity's mutable points into a flat variable vector where
//      2D point `i` occupies indices (2i, 2i+1); circle/arc/polygon radii become
//      scalar variables appended after all points.
//   2. WELDS points that are coincident — either joined by an explicit
//      `.coincident` constraint or lying within 1e-6 of each other — so they
//      share one variable pair and the solver moves them together.
//   3. Lowers each SketchConstraint / SketchDimension to the matching
//      `ConstraintResidual` struct, solves, and writes the solved values back
//      into a NEW `[SketchEntity]` (same IDs).
//
//  Degrees of freedom and per-entity fully-defined state are derived from the
//  null space of the numeric constraint Jacobian at the solution (see
//  `nullSpaceAnalysis`).
//
//  Scope notes (v1):
//   - Arc sweep is a scalar; its starting direction stays fixed. Ellipse angles
//     and radii are not solve variables. Arc endpoints are still not welded
//     (documented limitation).
//   - `.coincident` between two points welds them; `.coincident` of a point to a
//     whole line is lowered to a `ColinearPointConstraint` (point-on-line).
//
//  nonisolated + Double math to match the kernel.
//

import Foundation
import simd

nonisolated enum SketchSolverBridge {

    // MARK: - Public API

    /// Everything a caller needs to decide whether the solved geometry may
    /// be WRITTEN BACK. The solver always produces its best fit — for a
    /// conflicting system that best fit is a compromise satisfying nobody,
    /// and writing it into the document every drag frame was review finding
    /// R2-3. planegcs gates its geometry update on solve status
    /// (docs/FREECAD_PLAYBOOK.md S1); this is the same gate.
    struct Outcome {
        var entities: [SketchEntity]
        var dof: Int
        /// LM converged on the system it was given (INCLUDING any transient
        /// drag pull — a stretched drag legitimately leaves this false).
        var converged: Bool
        /// Norm of the STRUCTURAL residuals (constraints + dimensions only,
        /// no drag) at the solved state. Above tolerance = the constraint
        /// system itself is conflicting; hold the baseline, don't write.
        var structuralResidual: Double
    }

    /// Solve the sketch. When `movingEntity`/`dragTarget` are supplied, the
    /// moved entity's point NEAREST the drag target is pulled toward it with a
    /// transient `FixedPointConstraint` (drag-to-solve), while the rest of the
    /// geometry follows. Returns new entities (same IDs), the sketch's
    /// STRUCTURAL degrees of freedom (0 = fully defined), and the state a
    /// caller needs to gate writeback.
    /// `knownDOF`: a drag's structural DOF does not change from tick to tick
    /// (only geometry moves), so a caller that already has it passes it
    /// back and the null-space analysis — a 600×600 eigen-solve for a
    /// 150-line sketch, most of a tick's cost — is skipped.
    static func solveOutcome(
        _ sketch: Sketch,
        movingEntity: UUID?,
        dragTarget: SIMD2<Double>?,
        knownDOF: Int? = nil,
        preservingRectangleCorner: UUID? = nil,
        preservingLineDirection: UUID? = nil,
        preservingTangentCircle: (circle: UUID, line: UUID)? = nil
    ) -> Outcome {
        let sys = buildSystem(from: sketch, movingEntity: movingEntity, dragTarget: dragTarget,
                              preservingRectangleCorner: preservingRectangleCorner,
                              preservingLineDirection: preservingLineDirection,
                              preservingTangentCircle: preservingTangentCircle)
        guard !sys.initial.isEmpty else {
            return Outcome(entities: sketch.entities, dof: 0,
                           converged: true, structuralResidual: 0)
        }

        let result = ConstraintSolver.solve(
            initial: sys.initial,
            fixed: sys.fixed,
            constraints: sys.solveConstraints
        )
        var solved = result.variables
        var converged = result.converged
        func structuralResidual(_ variables: [Double]) -> Double {
            var sumSquares = 0.0
            for constraint in sys.structural {
                for r in constraint.residuals(variables) { sumSquares += r * r }
            }
            return sumSquares.squareRoot()
        }
        // A pointer target is a preference, not another saved constraint.
        // When it is off the allowed motion (e.g. a horizontal line with one
        // endpoint locked), first pull toward it, then project the compromise
        // back onto the structural system. Otherwise a valid one-DOF edit is
        // rejected as a conflict merely because the pointer moved diagonally.
        // Genuine structural contradictions still report their residual below.
        if movingEntity != nil, dragTarget != nil,
           structuralResidual(solved) > 1e-6 {
            let projected = ConstraintSolver.solve(
                initial: solved, fixed: sys.fixed, constraints: sys.structural)
            solved = projected.variables
            converged = projected.converged
        }
        let dof = knownDOF ?? nullSpaceAnalysis(sys, at: solved).dof
        let newEntities = writeBack(sketch.entities, sys: sys, vars: solved)
        return Outcome(entities: newEntities, dof: dof,
                       converged: converged,
                       structuralResidual: structuralResidual(solved))
    }

    /// Move/Rotate line targets are transient pointer intent. Build from the
    /// original sketch so saved locks and welded junctions retain their meaning.
    static func solveLineTransform(_ sketch: Sketch, targets: [SketchEntity],
                                   preservingLineID: UUID? = nil) -> [SketchEntity]? {
        guard !targets.isEmpty, targets.allSatisfy({ if case .line = $0 { return true }; return false })
        else { return nil }
        return solvePointTransform(sketch, targets: targets, preservingLineID: preservingLineID)
    }

    /// Solve rigid line/circle/arc intent against the original saved constraints.
    /// Arc orientation is carried separately from the center/sweep solver slots;
    /// a whole-arc Lock retains the original orientation as well as its center.
    /// Arc endpoint welding remains unsupported by the underlying sketch solver.
    static func solvePointTransform(_ sketch: Sketch, targets: [SketchEntity],
                                    preservingLineID: UUID? = nil) -> [SketchEntity]? {
        guard !targets.isEmpty, targets.allSatisfy({
            switch $0 { case .line, .circle, .arc: return true; default: return false }
        }) else { return nil }
        var anchored = sketch
        if let id = preservingLineID {
            anchored.constraints.append(SketchConstraint(kind: .fixed,
                refs: [.init(entityID: id, role: .whole)]))
        }
        let sys = buildSystem(from: anchored, movingEntity: nil, dragTarget: nil)
        var pulls = sys.structural
        for entity in targets {
            for slot in mutableSlots(entity) {
                guard let index = sys.pointIndex[SlotKey(entityID: slot.entityID, role: slot.role)]
                else { return nil }
                pulls.append(FixedPointConstraint(p: index, target: slot.position))
            }
        }
        let pulled = ConstraintSolver.solve(initial: sys.initial, fixed: sys.fixed, constraints: pulls)
        let projected = ConstraintSolver.solve(initial: pulled.variables, fixed: sys.fixed,
                                               constraints: sys.structural)
        let residual = sys.structural.flatMap { $0.residuals(projected.variables) }
            .reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        guard projected.converged, residual <= 1e-5 else { return nil }
        let wholeLocked = Set(sketch.constraints.filter { $0.kind == .fixed }
            .flatMap { $0.refs }.filter { $0.role == .whole }.map { $0.entityID })
        var oriented = sketch.entities
        for case let .arc(id, _, _, targetStart, _) in targets where !wholeLocked.contains(id) {
            guard let index = oriented.firstIndex(where: { $0.id == id }),
                  case let .arc(_, center, radius, start, end) = oriented[index] else { return nil }
            oriented[index] = .arc(id: id, center: center, radius: radius,
                startAngle: targetStart, endAngle: targetStart + SketchEntity.arcSweep(startAngle: start, endAngle: end))
        }
        return writeBack(oriented, sys: sys, vars: projected.variables)
    }

    /// A rectangle center drag is rigid translation, including for an
    /// undimensioned rectangle. Temporary size equations never enter history;
    /// existing locks and connections remain part of the projected system.
    static func solveAxisRectangleTranslation(_ sketch: Sketch, id: UUID,
                                               delta: SIMD2<Double>) -> [SketchEntity]? {
        guard case let .rect(_, lo, hi)? = sketch.entities.first(where: { $0.id == id }),
              delta.x.isFinite, delta.y.isFinite else { return nil }
        let sys = buildSystem(from: sketch, movingEntity: nil, dragTarget: nil)
        guard let a = sys.pointIndex[SlotKey(entityID: id, role: .endpointA)],
              let b = sys.pointIndex[SlotKey(entityID: id, role: .endpointB)] else { return nil }
        var rigid = sys.structural
        for axis in 0..<2 {
            rigid.append(AxisDistanceConstraint(pA: a, pB: b, axis: axis,
                sign: 1, distance: hi[axis] - lo[axis]))
        }
        var pulls = rigid
        pulls.append(FixedPointConstraint(p: a, target: lo + delta))
        pulls.append(FixedPointConstraint(p: b, target: hi + delta))
        let pulled = ConstraintSolver.solve(initial: sys.initial, fixed: sys.fixed, constraints: pulls)
        let projected = ConstraintSolver.solve(initial: pulled.variables, fixed: sys.fixed, constraints: rigid)
        let residual = rigid.flatMap { $0.residuals(projected.variables) }
            .reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        guard projected.converged, residual <= 1e-5 else { return nil }
        if zip(projected.variables, sys.initial).allSatisfy({ abs($0 - $1) < 1e-8 }) {
            return sketch.entities // Refused movement must not add a numerical-noise undo step.
        }
        return writeBack(sketch.entities, sys: sys, vars: projected.variables)
    }

    /// A free axis-aligned edge resizes against the opposite side. A saved
    /// dimension on that axis instead preserves size and translates the shape.
    /// Solve from the original sketch so explicit locks/relationships still win.
    static func solveAxisRectangleEdge(_ sketch: Sketch, id: UUID, edge: Int,
                                       delta: Double) -> [SketchEntity]? {
        guard let entity = sketch.entities.first(where: { $0.id == id }),
              case let .rect(_, lo, hi) = entity,
              let geometry = RectangleConstruction.axisEdge(entity, index: edge) else { return nil }
        let axis = edge % 2 == 0 ? 1 : 0
        let driven = sketch.dimensions.contains {
            $0.kind == (axis == 0 ? .horizontal : .vertical) &&
            $0.refs.count == 2 && $0.refs.allSatisfy { $0.entityID == id }
        }
        let shift = geometry.normal * delta
        var newLo = lo, newHi = hi
        if driven { newLo += shift; newHi += shift }
        else if edge == 0 || edge == 3 { newLo += shift }
        else { newHi += shift }
        guard newHi.x - newLo.x > 1e-3, newHi.y - newLo.y > 1e-3 else { return nil }
        let sys = buildSystem(from: sketch, movingEntity: nil, dragTarget: nil)
        var pulls = sys.structural
        for slot in mutableSlots(.rect(id: id, min: newLo, max: newHi)) {
            guard let index = sys.pointIndex[SlotKey(entityID: id, role: slot.role)] else { return nil }
            pulls.append(FixedPointConstraint(p: index, target: slot.position))
        }
        let pulled = ConstraintSolver.solve(initial: sys.initial, fixed: sys.fixed, constraints: pulls)
        let projected = ConstraintSolver.solve(initial: pulled.variables, fixed: sys.fixed, constraints: sys.structural)
        let residual = sys.structural.flatMap { $0.residuals(projected.variables) }
            .reduce(0.0) { $0 + $1 * $1 }.squareRoot()
        guard projected.converged, residual <= 1e-5 else { return nil }
        return writeBack(sketch.entities, sys: sys, vars: projected.variables)
    }

    /// Prefer the normalized lower-left corner for diagonal width/height edits.
    /// Paired reverse-drag checks corrected the earlier first-corner assumption.
    /// Explicit relationships win when holding that corner is incompatible.
    /// Legacy rectangles have no intent metadata and retain the existing solve.
    static func solveDimensionEdit(_ sketch: Sketch, dimension: SketchDimension,
                                   tolerance: Double = 1e-5,
                                   preservingLineID: UUID? = nil,
                                   preservingPoint: ConstraintRef? = nil) -> Outcome {
        let editedIDs = Set(dimension.refs.map(\.entityID))
        if dimension.kind == .distance, editedIDs.count == 1, let edge = editedIDs.first,
           let group = sketch.rotatedRectangleEdges.first(where: { $0.value.contains(edge) }),
           sketch.constraints.contains(where: {
               $0.kind == .fixed && $0.refs == [.init(entityID: group.key, role: .center)]
           }) {
            let directed = solveOutcome(sketch, movingEntity: nil, dragTarget: nil,
                                        preservingLineDirection: edge)
            if directed.converged && directed.structuralResidual <= tolerance { return directed }
        }
        // Fresh standalone line sizing retains the drawing start. This is only
        // a transient preference: a saved endpoint lock can override it.
        if let point = preservingPoint {
            var anchoredSketch = sketch
            anchoredSketch.constraints.append(SketchConstraint(kind: .fixed, refs: [point]))
            let anchored = solveOutcome(anchoredSketch, movingEntity: nil, dragTarget: nil)
            if anchored.converged && anchored.structuralResidual <= tolerance { return anchored }
        }
        // Three-point sizing can prefer an adjacent side, matching the
        // paired native baseline/height workflows. This is transient intent, never
        // a persisted Lock; explicit relationships still take precedence.
        if let id = preservingLineID,
           sketch.entities.contains(where: { if case .line = $0 { return $0.id == id }; return false }) {
            var anchoredSketch = sketch
            anchoredSketch.constraints.append(SketchConstraint(kind: .fixed,
                refs: [.init(entityID: id, role: .whole)]))
            let anchored = solveOutcome(anchoredSketch, movingEntity: nil, dragTarget: nil)
            if anchored.converged && anchored.structuralResidual <= tolerance { return anchored }
        }
        let ids = Set(dimension.refs.map(\.entityID))
        if (dimension.kind == .horizontal || dimension.kind == .vertical),
           ids.count == 1, let id = ids.first,
           sketch.rectangleSizingAnchors[id]?.cornerUsesMax != nil,
           sketch.entities.contains(where: { if case .rect = $0 { return $0.id == id }; return false }) {
            let anchored = solveOutcome(sketch, movingEntity: nil, dragTarget: nil,
                                        preservingRectangleCorner: id)
            if anchored.converged && anchored.structuralResidual <= tolerance { return anchored }
        }
        return solveOutcome(sketch, movingEntity: nil, dragTarget: nil)
    }

    static func solve(
        _ sketch: Sketch,
        movingEntity: UUID?,
        dragTarget: SIMD2<Double>?
    ) -> (entities: [SketchEntity], dof: Int) {
        let outcome = solveOutcome(sketch, movingEntity: movingEntity, dragTarget: dragTarget)
        return (outcome.entities, outcome.dof)
    }

    /// Conflict diagnosis stage 2: WHICH constraints/dimensions the solver
    /// could not satisfy. The clashing rows of a conflicting cluster share the
    /// solver's compromise error, so every member of the cluster is attributed
    /// (two dueling lengths both light up — there is no innocent party until
    /// the user picks one); rows the solve satisfies stay at ~0 residual and
    /// are never attributed. Stage 3 (rank analysis à la planegcs
    /// `diagnose()`) is the future refinement that separates redundant from
    /// conflicting at add time.
    struct ConflictAttribution: Equatable, Sendable {
        var constraintIDs: Set<UUID> = []
        var dimensionIDs: Set<UUID> = []
        var isEmpty: Bool { constraintIDs.isEmpty && dimensionIDs.isEmpty }
    }

    /// Attribute a conflicting sketch's unsatisfied residual rows to their
    /// source constraint/dimension UUIDs. Solves the STRUCTURAL system only
    /// (no drag), evaluates each lowered residual at the solution, and
    /// reports every source whose row norm exceeds `tolerance` — the same
    /// scale as `EditorViewModel.overConstraintTolerance`, and subject to the
    /// same mixed-units caveat until residual normalization lands.
    static func conflictAttribution(
        _ sketch: Sketch, tolerance: Double = 1e-3
    ) -> ConflictAttribution {
        let sys = buildSystem(from: sketch, movingEntity: nil, dragTarget: nil)
        guard !sys.initial.isEmpty, !sys.structural.isEmpty else {
            return ConflictAttribution()
        }
        let solved = ConstraintSolver.solve(
            initial: sys.initial,
            fixed: sys.fixed,
            constraints: sys.structural
        ).variables
        var out = ConflictAttribution()
        for (i, constraint) in sys.structural.enumerated() {
            var sumSquares = 0.0
            for r in constraint.residuals(solved) { sumSquares += r * r }
            guard sumSquares.squareRoot() > tolerance else { continue }
            switch sys.structuralSources[i] {
            case .constraint(let id): out.constraintIDs.insert(id)
            case .dimension(let id): out.dimensionIDs.insert(id)
            }
        }
        return out
    }

    /// Stage 3 (add-time diagnosis): given a CONFLICTING sketch and the
    /// candidate that made it so (passed via the exclusion sets), find the
    /// existing constraints/dimensions whose INDIVIDUAL removal lets the rest
    /// solve — the partners of the clash. Leave-one-out probe, re-derived
    /// rather than ported from planegcs's QR-based `diagnose()`: one small
    /// solve per source, run once at add time, and the answer is directly
    /// actionable ("delete any of these and the sketch solves"). Two honest
    /// edges: a multi-clash system where no single removal resolves falls
    /// back to residual attribution minus the candidate, and a sketch too
    /// large for the probe (probe cost is quadratic-ish in sources) skips
    /// straight to that fallback. Empty when the sketch is not conflicting.
    static func conflictPartners(
        in sketch: Sketch,
        excludingConstraints: Set<UUID> = [],
        excludingDimensions: Set<UUID> = [],
        tolerance: Double = 1e-3
    ) -> ConflictAttribution {
        guard residualNorm(sketch) > tolerance else { return ConflictAttribution() }
        func attributionFallback() -> ConflictAttribution {
            var blame = conflictAttribution(sketch, tolerance: tolerance)
            blame.constraintIDs.subtract(excludingConstraints)
            blame.dimensionIDs.subtract(excludingDimensions)
            return blame
        }
        guard sketch.constraints.count + sketch.dimensions.count <= 64 else {
            return attributionFallback()
        }
        var out = ConflictAttribution()
        for c in sketch.constraints where !excludingConstraints.contains(c.id) {
            var probe = sketch
            probe.constraints.removeAll { $0.id == c.id }
            if residualNorm(probe) <= tolerance { out.constraintIDs.insert(c.id) }
        }
        for d in sketch.dimensions where !excludingDimensions.contains(d.id) {
            var probe = sketch
            probe.dimensions.removeAll { $0.id == d.id }
            if residualNorm(probe) <= tolerance { out.dimensionIDs.insert(d.id) }
        }
        return out.isEmpty ? attributionFallback() : out
    }

    /// Residual norm of the sketch's structural constraint/dimension system at
    /// its solved state. ~0 means every constraint is mutually satisfiable; a
    /// value above a small tolerance signals a CONFLICTING (over-constrained)
    /// system the solver cannot satisfy. Used to refuse an over-constraining
    /// edit before it corrupts the sketch. Ignores any transient drag target.
    static func residualNorm(_ sketch: Sketch) -> Double {
        let sys = buildSystem(from: sketch, movingEntity: nil, dragTarget: nil)
        guard !sys.initial.isEmpty, !sys.structural.isEmpty else { return 0 }
        let result = ConstraintSolver.solve(
            initial: sys.initial,
            fixed: sys.fixed,
            constraints: sys.structural
        )
        return result.residualNorm
    }

    /// Per-entity fully-defined state: `true` when every variable the entity
    /// owns (its point coordinates + radius scalar) is determined — i.e. covered
    /// by the constraint Jacobian's rank (no null-space motion changes it).
    /// Heuristic: an entity variable is under-defined when it has a non-zero
    /// component in any null-space direction of the Jacobian at the solution.
    static func entityStates(_ sketch: Sketch) -> [UUID: Bool] {
        definitionReport(sketch).states
    }

    /// What the editor shows about a sketch's definition: the per-entity
    /// states (colours) and the structural DOF (the status chip) — from ONE
    /// solve and one null-space analysis, the same ones `solveOutcome` runs
    /// without a drag, so the chip's DOF is exactly `solve`'s.
    struct DefinitionReport: Equatable, Sendable {
        var states: [UUID: Bool]
        var dof: Int
        /// Supporting-line determinacy in axisEdge order; length may remain free.
        var rectangleEdges: [UUID: [Bool]] = [:]
    }

    static func definitionReport(_ sketch: Sketch) -> DefinitionReport {
        var states: [UUID: Bool] = [:]
        let sys = buildSystem(from: sketch, movingEntity: nil, dragTarget: nil)
        guard !sys.initial.isEmpty else {
            for e in sketch.entities { states[e.id] = true }
            return DefinitionReport(states: states, dof: 0)
        }
        let solved = ConstraintSolver.solve(
            initial: sys.initial,
            fixed: sys.fixed,
            constraints: sys.solveConstraints
        ).variables
        let analysis = nullSpaceAnalysis(sys, at: solved)
        for e in sketch.entities {
            states[e.id] = entityDetermined(e, sys: sys, determined: analysis.determined)
        }
        var edges: [UUID: [Bool]] = [:]
        for case let .rect(id, _, _) in sketch.entities {
            guard let a = sys.pointIndex[SlotKey(entityID: id, role: .endpointA)],
                  let b = sys.pointIndex[SlotKey(entityID: id, role: .endpointB)] else { continue }
            // Horizontal sides depend on y, vertical sides on x. A free
            // endpoint may slide along a determined supporting line.
            edges[id] = [2*a+1, 2*b, 2*b+1, 2*a].map { analysis.determined[$0] }
        }
        return DefinitionReport(states: states, dof: analysis.dof, rectangleEdges: edges)
    }

    // MARK: - System model

    private struct SlotKey: Hashable {
        let entityID: UUID
        let role: PointRole
    }

    private struct RawSlot {
        let entityID: UUID
        let role: PointRole
        let position: SIMD2<Double>
        let endpointLike: Bool
    }

    /// Which document object a lowered residual came from — the provenance
    /// that lets a conflict be attributed back to something the user can see
    /// and delete (stage 2 of conflict diagnosis).
    private enum ConflictSource {
        case constraint(UUID)
        case dimension(UUID)
    }

    /// The lowered numeric problem plus the maps needed to write results back
    /// and to analyse per-entity DOF.
    private struct System {
        var initial: [Double]
        var fixed: Set<Int>
        var pointCount: Int
        var pointIndex: [SlotKey: Int]
        var radiusVar: [UUID: Int]
        var arcSweepVar: [UUID: Int]
        /// Residuals for constraints + dimensions ONLY (no transient drag).
        var structural: [any ConstraintResidual]
        /// Source object per `structural` entry (same indices). A constraint
        /// that lowers to several residuals repeats its source.
        var structuralSources: [ConflictSource]
        /// `structural` plus the transient drag constraint (used for the solve).
        var solveConstraints: [any ConstraintResidual]
        var entityPoints: [UUID: [Int]]
    }

    // MARK: - Entity point / scalar enumeration

    private static func mutableSlots(_ e: SketchEntity) -> [RawSlot] {
        switch e {
        case let .line(id, a, b):
            return [RawSlot(entityID: id, role: .endpointA, position: a, endpointLike: true),
                    RawSlot(entityID: id, role: .endpointB, position: b, endpointLike: true)]
        case let .rect(id, mn, mx):
            return [RawSlot(entityID: id, role: .endpointA, position: mn, endpointLike: true),
                    RawSlot(entityID: id, role: .endpointB, position: mx, endpointLike: true)]
        case let .circle(id, c, _):
            return [RawSlot(entityID: id, role: .center, position: c, endpointLike: false)]
        case let .arc(id, c, _, _, _):
            return [RawSlot(entityID: id, role: .center, position: c, endpointLike: false)]
        case let .ellipse(id, c, _, _, _):
            return [RawSlot(entityID: id, role: .center, position: c, endpointLike: false)]
        case let .polygon(id, c, _, _, _):
            return [RawSlot(entityID: id, role: .center, position: c, endpointLike: false)]
        case let .spline(id, points, closed):
            // Expose the OPEN spline's ends so it can be constrained/welded to
            // neighbouring geometry like a line. Interior fit points are not
            // solver variables yet (spec §1.4 spline constraints are future
            // work), so the curve keeps its shape when the ends move.
            guard !closed, let first = points.first, let last = points.last,
                  points.count >= 2 else { return [] }
            return [RawSlot(entityID: id, role: .endpointA, position: first, endpointLike: true),
                    RawSlot(entityID: id, role: .endpointB, position: last, endpointLike: true)]
        }
    }

    private static func radiusScalar(_ e: SketchEntity) -> Double? {
        switch e {
        case let .circle(_, _, r): return r
        case let .arc(_, _, r, _, _): return r
        case let .polygon(_, _, r, _, _): return r
        default: return nil
        }
    }

    // MARK: - System construction

    private static func buildSystem(
        from sketch: Sketch,
        movingEntity: UUID?,
        dragTarget: SIMD2<Double>?,
        preservingRectangleCorner: UUID? = nil,
        preservingLineDirection: UUID? = nil,
        preservingTangentCircle: (circle: UUID, line: UUID)? = nil
    ) -> System {
        // 1. Raw point slots for every entity.
        var slots: [RawSlot] = []
        var rawIndexOf: [SlotKey: Int] = [:]
        for e in sketch.entities {
            for s in mutableSlots(e) {
                rawIndexOf[SlotKey(entityID: s.entityID, role: s.role)] = slots.count
                slots.append(s)
            }
        }

        // 2. Union-find weld.
        var parent = Array(0..<slots.count)
        func find(_ x: Int) -> Int {
            var r = x
            while parent[r] != r { parent[r] = parent[parent[r]]; r = parent[r] }
            return r
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        // Proximity weld (endpoint-like slots within 1e-6).
        for i in 0..<slots.count where slots[i].endpointLike {
            for j in (i + 1)..<slots.count where slots[j].endpointLike {
                let a = ConstraintRef(entityID: slots[i].entityID, role: slots[i].role)
                let b = ConstraintRef(entityID: slots[j].entityID, role: slots[j].role)
                guard !sketch.disconnectedEndpoints.contains(a),
                      !sketch.disconnectedEndpoints.contains(b) else { continue }
                if simd_distance(slots[i].position, slots[j].position) < 1e-6 { union(i, j) }
            }
        }
        // Explicit coincident weld (point-to-point only).
        for c in sketch.constraints where c.kind == .coincident && c.refs.count == 2 {
            let k0 = SlotKey(entityID: c.refs[0].entityID, role: c.refs[0].role)
            let k1 = SlotKey(entityID: c.refs[1].entityID, role: c.refs[1].role)
            if let i0 = rawIndexOf[k0], let i1 = rawIndexOf[k1] { union(i0, i1) }
        }

        // 3. Root -> point index, averaging welded positions.
        var rootToPoint: [Int: Int] = [:]
        var sumPos: [SIMD2<Double>] = []
        var countPos: [Int] = []
        for i in 0..<slots.count {
            let r = find(i)
            if let pi = rootToPoint[r] {
                sumPos[pi] += slots[i].position
                countPos[pi] += 1
            } else {
                rootToPoint[r] = sumPos.count
                sumPos.append(slots[i].position)
                countPos.append(1)
            }
        }
        let pointCount = sumPos.count
        let pointPos: [SIMD2<Double>] = (0..<pointCount).map { sumPos[$0] / Double(countPos[$0]) }

        // 4. slotKey -> point index.
        var pointIndex: [SlotKey: Int] = [:]
        for i in 0..<slots.count {
            pointIndex[SlotKey(entityID: slots[i].entityID, role: slots[i].role)] = rootToPoint[find(i)]
        }

        // 5. Radius scalars, appended after the points.
        var radiusVar: [UUID: Int] = [:]
        var scalarValues: [Double] = []
        for e in sketch.entities {
            if let r = radiusScalar(e) {
                radiusVar[e.id] = 2 * pointCount + scalarValues.count
                scalarValues.append(r)
            }
        }

        // Arc angle dimensions drive sweep while retaining the starting ray.
        var arcSweepVar: [UUID: Int] = [:]
        for case let .arc(id, _, _, start, end) in sketch.entities {
            arcSweepVar[id] = 2 * pointCount + scalarValues.count
            scalarValues.append(SketchEntity.arcSweep(startAngle: start, endAngle: end))
        }

        // 6. Initial variable vector.
        var initial = [Double](repeating: 0, count: 2 * pointCount + scalarValues.count)
        for pi in 0..<pointCount {
            initial[2 * pi] = pointPos[pi].x
            initial[2 * pi + 1] = pointPos[pi].y
        }
        for j in 0..<scalarValues.count { initial[2 * pointCount + j] = scalarValues[j] }

        // 7. Entity -> point indices.
        var entityPoints: [UUID: [Int]] = [:]
        for e in sketch.entities {
            entityPoints[e.id] = mutableSlots(e).compactMap {
                pointIndex[SlotKey(entityID: $0.entityID, role: $0.role)]
            }
        }

        // Resolve helpers.
        func pIdx(_ id: UUID, _ role: PointRole) -> Int? {
            pointIndex[SlotKey(entityID: id, role: role)]
        }
        func linePair(_ id: UUID) -> (Int, Int)? {
            guard let a = pIdx(id, .endpointA), let b = pIdx(id, .endpointB) else { return nil }
            return (a, b)
        }
        func pointOperand(_ ref: ConstraintRef) -> Int? {
            switch ref.role {
            case .endpointA, .endpointB, .center: return pIdx(ref.entityID, ref.role)
            case .whole: return nil
            }
        }
        func twoLines(_ refs: [ConstraintRef]) -> (Int, Int, Int, Int)? {
            guard refs.count == 2,
                  let (a1, b1) = linePair(refs[0].entityID),
                  let (a2, b2) = linePair(refs[1].entityID) else { return nil }
            return (a1, b1, a2, b2)
        }

        // 8. Fixed set from `.fixed` (Lock) constraints.
        var fixed = Set<Int>()
        func fixPoint(_ pi: Int) { fixed.insert(2 * pi); fixed.insert(2 * pi + 1) }
        for c in sketch.constraints where c.kind == .fixed {
            for ref in c.refs {
                switch ref.role {
                case .endpointA, .endpointB, .center:
                    if let pi = pIdx(ref.entityID, ref.role) { fixPoint(pi) }
                case .whole:
                    if let edge = ref.rectangleEdge, (0..<4).contains(edge),
                       case .rect? = sketch.entities.first(where: { $0.id == ref.entityID }),
                       let a = pIdx(ref.entityID, .endpointA),
                       let b = pIdx(ref.entityID, .endpointB) {
                        // A=lower-left, B=upper-right: pin three coordinates,
                        // leaving only the opposite edge's normal coordinate free.
                        let normalAxis = edge % 2 == 0 ? 1 : 0
                        fixed.insert(2 * a + (1 - normalAxis))
                        fixed.insert(2 * b + (1 - normalAxis))
                        fixed.insert(2 * (edge == 0 || edge == 3 ? a : b) + normalAxis)
                        continue
                    }
                    for pi in entityPoints[ref.entityID] ?? [] { fixPoint(pi) }
                    if let rv = radiusVar[ref.entityID] { fixed.insert(rv) }
                    if let av = arcSweepVar[ref.entityID] { fixed.insert(av) }
                }
            }
        }

        // Native diagonal dimensions hold left/bottom regardless of drag order
        // (paired up-left width and down-right height checks). Old corner
        // metadata still distinguishes diagonal from center creation; do not
        // reinterpret it as a permanent Lock or change ordinary dragging.
        if let id = preservingRectangleCorner,
           sketch.rectangleSizingAnchors[id]?.cornerUsesMax != nil,
           let a = pIdx(id, .endpointA) {
            fixPoint(a)
        }

        // 9. Lower constraints + dimensions to residuals, recording each
        // row's source object so a conflict can be attributed back to the
        // constraint/dimension the user sees (stage 2).
        var structural: [any ConstraintResidual] = []
        var structuralSources: [ConflictSource] = []
        var currentSource = ConflictSource.constraint(UUID()) // set per loop turn
        func lower(_ residual: any ConstraintResidual) {
            structural.append(residual)
            structuralSources.append(currentSource)
        }
        if let id = preservingLineDirection, let (a, b) = linePair(id) {
            let delta = SIMD2(initial[2*b] - initial[2*a], initial[2*b+1] - initial[2*a+1])
            if simd_length(delta) > 1e-9 {
                lower(LineDirectionConstraint(a: a, b: b, direction: simd_normalize(delta)))
            }
        }
        // Application-only preference: a free circle approaches the anchored
        // line along its normal without changing radius. This removes the
        // tangent's free along-line motion (especially unstable at tiny slopes).
        // The editor retries without this preference if saved constraints win.
        if let pair = preservingTangentCircle,
           let center = pIdx(pair.circle, .center), let rv = radiusVar[pair.circle],
           let (a, b) = linePair(pair.line) {
            let delta = SIMD2(initial[2*b] - initial[2*a], initial[2*b+1] - initial[2*a+1])
            if simd_length(delta) > 1e-9 {
                fixed.insert(rv)
                lower(PointProjectionConstraint(p: center,
                    origin: SIMD2(initial[2*center], initial[2*center+1]),
                    direction: simd_normalize(delta)))
            }
        }
        func appendAlign(_ refs: [ConstraintRef], horizontal: Bool) {
            let wholeLines = refs.filter { $0.role == .whole }
            if !wholeLines.isEmpty {
                for r in wholeLines where linePair(r.entityID) != nil {
                    let (a, b) = linePair(r.entityID)!
                    lower(horizontal
                        ? HorizontalConstraint(pA: a, pB: b)
                        : VerticalConstraint(pA: a, pB: b))
                }
            } else if refs.count == 2,
                      let a = pointOperand(refs[0]), let b = pointOperand(refs[1]) {
                lower(horizontal
                    ? HorizontalConstraint(pA: a, pB: b)
                    : VerticalConstraint(pA: a, pB: b))
            }
        }
        func appendColinear(_ point: ConstraintRef, _ line: ConstraintRef) {
            if let p = pointOperand(point), let (la, lb) = linePair(line.entityID) {
                lower(ColinearPointConstraint(p: p, lA: la, lB: lb))
            }
        }
        func appendTangent(_ refs: [ConstraintRef], branch: CircleTangency?) {
            guard refs.count == 2 else { return }
            if let ra = radiusVar[refs[0].entityID], let rb = radiusVar[refs[1].entityID],
               let ca = pIdx(refs[0].entityID, .center), let cb = pIdx(refs[1].entityID, .center) {
                // Seed the persisted contact branch geometrically. The free
                // six-variable LM solve otherwise stalls for some center rays.
                // Never move a fixed coordinate; every saved residual still
                // participates in the ensuing solve and conflict validation.
                let a = SIMD2(initial[2 * ca], initial[2 * ca + 1])
                let b = SIMD2(initial[2 * cb], initial[2 * cb + 1])
                let delta = b - a
                let distance = simd_length(delta)
                let internalContact = branch == .internalContact
                let target = internalContact ? abs(initial[ra] - initial[rb]) : initial[ra] + initial[rb]
                if distance > 1e-12, target >= 0, abs(distance - target) > 1e-10 {
                    let direction = delta / distance
                    if !fixed.contains(2 * ca), !fixed.contains(2 * ca + 1) {
                        let seed = b - direction * target
                        initial[2 * ca] = seed.x; initial[2 * ca + 1] = seed.y
                    } else if !fixed.contains(2 * cb), !fixed.contains(2 * cb + 1) {
                        let seed = a + direction * target
                        initial[2 * cb] = seed.x; initial[2 * cb + 1] = seed.y
                    }
                }
                lower(TangentCircleCircleConstraint(centerA: ca, centerB: cb, radiusA: ra, radiusB: rb, internalContact: internalContact))
                return
            }
            var lineRef: ConstraintRef?
            var circleRef: ConstraintRef?
            for r in refs {
                if radiusVar[r.entityID] != nil { circleRef = r }
                else if linePair(r.entityID) != nil { lineRef = r }
            }
            if let l = lineRef, let cRef = circleRef,
               let (a, b) = linePair(l.entityID),
               let center = pIdx(cRef.entityID, .center),
               let rv = radiusVar[cRef.entityID] {
                lower(TangentLineCircleConstraint(lA: a, lB: b, center: center, radiusVar: rv))
            }
        }
        func appendDistance(_ refs: [ConstraintRef], value: Double) {
            guard refs.count == 2 else { return }
            let r0 = refs[0], r1 = refs[1]
            if let p0 = pointOperand(r0), let p1 = pointOperand(r1) {
                lower(DistanceConstraint(pA: p0, pB: p1, distance: value))
            } else if let p = pointOperand(r0), r1.role == .whole, let (la, lb) = linePair(r1.entityID) {
                lower(PointDistanceToLineConstraint(p: p, lA: la, lB: lb, distance: value))
            } else if let p = pointOperand(r1), r0.role == .whole, let (la, lb) = linePair(r0.entityID) {
                lower(PointDistanceToLineConstraint(p: p, lA: la, lB: lb, distance: value))
            } else if r0.role == .whole, r1.role == .whole,
                      let (la, lb) = linePair(r0.entityID), let (a2, _) = linePair(r1.entityID) {
                lower(PointDistanceToLineConstraint(p: a2, lA: la, lB: lb, distance: value))
            }
        }

        for c in sketch.constraints {
            currentSource = .constraint(c.id)
            switch c.kind {
            case .fixed:
                // Rectangle centers are derived from their diagonal corners.
                // Pin only the midpoint so both size axes remain editable.
                for ref in c.refs where ref.role == .center {
                    if let (first, opposite) = RectangleConstruction.centerDiagonalReferences(ref.entityID, in: sketch),
                       let a = pIdx(first.entityID, first.role),
                       let b = pIdx(opposite.entityID, opposite.role) {
                        let target = SIMD2((initial[2 * a] + initial[2 * b]) / 2,
                                           (initial[2 * a + 1] + initial[2 * b + 1]) / 2)
                        lower(FixedMidpointConstraint(a: a, b: b, target: target))
                        continue
                    }
                    guard case let .rect(_, lo, hi)? = sketch.entities.first(where: { $0.id == ref.entityID }),
                          let a = pIdx(ref.entityID, .endpointA),
                          let b = pIdx(ref.entityID, .endpointB) else { continue }
                    lower(FixedMidpointConstraint(a: a, b: b, target: (lo + hi) / 2))
                }
            case .coincident:
                guard c.refs.count == 2 else { break }
                let r0 = c.refs[0], r1 = c.refs[1]
                if r1.role == .whole {
                    appendColinear(r0, r1)
                } else if r0.role == .whole {
                    appendColinear(r1, r0)
                } else if let a = pointOperand(r0), let b = pointOperand(r1), a != b {
                    lower(CoincidentConstraint(pA: a, pB: b))
                }
            case .horizontal:
                appendAlign(c.refs, horizontal: true)
            case .vertical:
                appendAlign(c.refs, horizontal: false)
            case .parallel:
                if let (a1, b1, a2, b2) = twoLines(c.refs) {
                    lower(ParallelConstraint(l1A: a1, l1B: b1, l2A: a2, l2B: b2))
                }
            case .perpendicular:
                if let (a1, b1, a2, b2) = twoLines(c.refs) {
                    lower(PerpendicularConstraint(l1A: a1, l1B: b1, l2A: a2, l2B: b2))
                }
            case .equalLength:
                if let (a1, b1, a2, b2) = twoLines(c.refs) {
                    lower(EqualLengthConstraint(l1A: a1, l1B: b1, l2A: a2, l2B: b2))
                }
            case .equalRadius:
                if c.refs.count == 2,
                   let rv1 = radiusVar[c.refs[0].entityID],
                   let rv2 = radiusVar[c.refs[1].entityID] {
                    lower(EqualRadiusConstraint(rVar1: rv1, rVar2: rv2))
                }
            case .concentric:
                if c.refs.count == 2,
                   let a = pIdx(c.refs[0].entityID, .center),
                   let b = pIdx(c.refs[1].entityID, .center), a != b {
                    lower(ConcentricConstraint(cA: a, cB: b))
                }
            case .midpoint:
                if c.refs.count == 2,
                   let p = pointOperand(c.refs[0]),
                   let (la, lb) = linePair(c.refs[1].entityID) {
                    lower(MidpointConstraint(p: p, lA: la, lB: lb))
                }
            case .symmetric:
                if c.refs.count == 3 || c.refs.count == 5,
                   let (la, lb) = linePair(c.refs[2].entityID) {
                    let r0 = c.refs[0], r1 = c.refs[1]
                    if r0.role == .whole, r1.role == .whole,
                       case .circle? = sketch.entities.first(where: { $0.id == r0.entityID }),
                       case .circle? = sketch.entities.first(where: { $0.id == r1.entityID }),
                       let a = pIdx(r0.entityID, .center), let b = pIdx(r1.entityID, .center),
                       let ra = radiusVar[r0.entityID], let rb = radiusVar[r1.entityID] {
                        lower(SymmetricConstraint(pA: a, pB: b, lA: la, lB: lb))
                        lower(EqualRadiusConstraint(rVar1: ra, rVar2: rb))
                    } else if let a = pointOperand(r0), let b = pointOperand(r1) {
                        lower(SymmetricConstraint(pA: a, pB: b, lA: la, lB: lb))
                        if c.refs.count == 5,
                           let p2 = pointOperand(c.refs[3]), let q2 = pointOperand(c.refs[4]) {
                            lower(SymmetricConstraint(pA: p2, pB: q2, lA: la, lB: lb))
                        }
                    }
                }
            case .tangent:
                appendTangent(c.refs, branch: c.circleTangency)
            case .colinear:
                guard c.refs.count == 2 else { break }
                let r0 = c.refs[0], r1 = c.refs[1]
                if r1.role == .whole, r0.role != .whole {
                    appendColinear(r0, r1)
                } else if r0.role == .whole, r1.role != .whole {
                    appendColinear(r1, r0)
                } else if r0.role == .whole, r1.role == .whole,
                          let (la, lb) = linePair(r0.entityID), let (a2, b2) = linePair(r1.entityID) {
                    lower(ColinearPointConstraint(p: a2, lA: la, lB: lb))
                    lower(ColinearPointConstraint(p: b2, lA: la, lB: lb))
                }
            }
        }

        for d in sketch.dimensions {
            currentSource = .dimension(d.id)
            switch d.kind {
            case .distance:
                appendDistance(d.refs, value: d.value)
            case .radius:
                if let ref = d.refs.first, let rv = radiusVar[ref.entityID] {
                    lower(RadiusConstraint(radiusVar: rv, radius: d.value))
                }
            case .diameter:
                if let ref = d.refs.first, let rv = radiusVar[ref.entityID] {
                    lower(RadiusConstraint(radiusVar: rv, radius: d.value / 2))
                }
            case .angle:
                if d.refs.count == 1, let ref = d.refs.first, let av = arcSweepVar[ref.entityID] {
                    lower(ArcSweepConstraint(sweepVar: av, sweep: d.value))
                } else if let (a1, b1, a2, b2) = twoLines(d.refs) {
                    lower(AngleConstraint(l1A: a1, l1B: b1, l2A: a2, l2B: b2, angle: d.value))
                }
            case .horizontal, .vertical:
                // Width / height between two points (a rect's corners). The
                // orientation sign comes from the geometry as drawn so the
                // solver drives the pair apart or together, never through zero.
                let axis = d.kind == .horizontal ? 0 : 1
                if d.refs.count == 2, let p0 = pointOperand(d.refs[0]), let p1 = pointOperand(d.refs[1]) {
                    let drawn = initial[2 * p1 + axis] - initial[2 * p0 + axis]
                    lower(AxisDistanceConstraint(pA: p0, pB: p1, axis: axis,
                                                 sign: drawn >= 0 ? 1 : -1, distance: d.value))
                }
            }
        }

        // 10. Transient drag constraint: pull the moved entity's nearest point.
        var solveConstraints = structural
        if let mid = movingEntity, let target = dragTarget,
           let pts = entityPoints[mid], !pts.isEmpty {
            var best = pts[0]
            var bestD = Double.greatestFiniteMagnitude
            for pi in pts {
                let pos = SIMD2(initial[2 * pi], initial[2 * pi + 1])
                let dd = simd_distance(pos, target)
                if dd < bestD { bestD = dd; best = pi }
            }
            solveConstraints.append(FixedPointConstraint(p: best, target: target))
        }

        return System(
            initial: initial,
            fixed: fixed,
            pointCount: pointCount,
            pointIndex: pointIndex,
            radiusVar: radiusVar,
            arcSweepVar: arcSweepVar,
            structural: structural,
            structuralSources: structuralSources,
            solveConstraints: solveConstraints,
            entityPoints: entityPoints
        )
    }

    // MARK: - Write back

    private static func writeBack(
        _ entities: [SketchEntity],
        sys: System,
        vars: [Double]
    ) -> [SketchEntity] {
        func pt(_ id: UUID, _ role: PointRole) -> SIMD2<Double>? {
            guard let idx = sys.pointIndex[SlotKey(entityID: id, role: role)] else { return nil }
            return SIMD2(vars[2 * idx], vars[2 * idx + 1])
        }
        func rad(_ id: UUID, _ fallback: Double) -> Double {
            guard let rv = sys.radiusVar[id] else { return fallback }
            return abs(vars[rv])
        }
        return entities.map { e in
            switch e {
            case let .line(id, a, b):
                return .line(id: id, a: pt(id, .endpointA) ?? a, b: pt(id, .endpointB) ?? b)
            case let .rect(id, mn, mx):
                return .rect(id: id, min: pt(id, .endpointA) ?? mn, max: pt(id, .endpointB) ?? mx)
            case let .circle(id, c, r):
                return .circle(id: id, center: pt(id, .center) ?? c, radius: rad(id, r))
            case let .arc(id, c, r, sa, ea):
                let oldSweep = SketchEntity.arcSweep(startAngle: sa, endAngle: ea)
                let sweep = sys.arcSweepVar[id].map { vars[$0] } ?? oldSweep
                // Avoid representation-only changes to untouched wrapped arcs.
                let end = abs(sweep - oldSweep) > 1e-10 ? sa + sweep : ea
                return .arc(id: id, center: pt(id, .center) ?? c, radius: rad(id, r),
                            startAngle: sa, endAngle: end)
            case let .ellipse(id, c, rx, ry, rot):
                return .ellipse(id: id, center: pt(id, .center) ?? c, radiusX: rx, radiusY: ry, rotation: rot)
            case let .polygon(id, c, r, sides, rot):
                return .polygon(id: id, center: pt(id, .center) ?? c, radius: rad(id, r),
                                sides: sides, rotation: rot)
            case let .spline(id, points, closed):
                // Move the ends the solver placed; interior points ride along by
                // the same translation so the curve is not distorted.
                guard !closed, points.count >= 2,
                      let a = pt(id, .endpointA) ?? points.first,
                      let b = pt(id, .endpointB) ?? points.last
                else { return e }
                var moved = points
                moved[0] = a
                moved[moved.count - 1] = b
                return .spline(id: id, points: moved, closed: closed)
            }
        }
    }

    // MARK: - Per-entity DOF

    private static func entityDetermined(
        _ e: SketchEntity,
        sys: System,
        determined: [Bool]
    ) -> Bool {
        var idxs: [Int] = []
        for pi in sys.entityPoints[e.id] ?? [] {
            idxs.append(2 * pi)
            idxs.append(2 * pi + 1)
        }
        if let rv = sys.radiusVar[e.id] { idxs.append(rv) }
        if let av = sys.arcSweepVar[e.id] { idxs.append(av) }
        guard !idxs.isEmpty else { return true }
        return idxs.allSatisfy { $0 < determined.count && determined[$0] }
    }

    // MARK: - Null-space analysis (DOF + per-variable determinacy)

    /// Analyse the structural constraint Jacobian at `x`: returns the estimated
    /// degrees of freedom (nullity) and, per global variable, whether it is
    /// determined (fixed vars and vars with no null-space component are `true`).
    private static func nullSpaceAnalysis(
        _ sys: System,
        at x: [Double]
    ) -> (dof: Int, determined: [Bool]) {
        let nGlobal = x.count
        var determined = [Bool](repeating: true, count: nGlobal) // fixed vars stay true
        let free = (0..<nGlobal).filter { !sys.fixed.contains($0) }
        let nf = free.count
        guard nf > 0 else { return (0, determined) }

        let cons = sys.structural
        // Residual layout, and which constraints read each variable — the
        // solver's sparsity pattern. The Jacobian used to re-evaluate EVERY
        // constraint twice per free variable (O(nf·m) residual calls, the
        // bulk of a 150-line sketch's analysis once the eigen-solve moved to
        // LAPACK); a variable only perturbs the residuals that read it.
        var offsets: [Int] = []
        offsets.reserveCapacity(cons.count)
        var m = 0
        for c in cons {
            offsets.append(m)
            m += max(0, c.residualCount)
        }
        guard m > 0 else {
            for g in free { determined[g] = false }
            return (nf, determined)
        }
        var columnOf = [Int](repeating: -1, count: nGlobal) // global var → free column
        for (col, g) in free.enumerated() { columnOf[g] = col }
        var affects = [[Int]](repeating: [], count: nGlobal)
        for (ci, c) in cons.enumerated() {
            for vi in c.variableIndices where vi >= 0 && vi < nGlobal {
                if !affects[vi].contains(ci) { affects[vi].append(ci) }
            }
        }

        // Numeric Jacobian (central differences), row-major m × nf.
        let h = 1e-6
        var J = [Double](repeating: 0, count: m * nf)
        var xw = x
        for (col, g) in free.enumerated() {
            let saved = xw[g]
            for ci in affects[g] {
                let c = cons[ci]
                xw[g] = saved + h
                let rp = c.residuals(xw)
                xw[g] = saved - h
                let rm = c.residuals(xw)
                xw[g] = saved
                let off = offsets[ci]
                let count = Swift.min(c.residualCount, rp.count, rm.count)
                for t in 0..<count {
                    J[(off + t) * nf + col] = (rp[t] - rm[t]) / (2 * h)
                }
            }
        }

        // Normal matrix M = JᵀJ (nf × nf, symmetric, row-major flat),
        // accumulated per constraint block: its rows × its free columns.
        var M = [Double](repeating: 0, count: nf * nf)
        for (ci, c) in cons.enumerated() {
            var cols: [Int] = []
            for vi in c.variableIndices where vi >= 0 && vi < nGlobal {
                let col = columnOf[vi]
                if col >= 0, !cols.contains(col) { cols.append(col) }
            }
            cols.sort()
            let off = offsets[ci]
            for t in 0..<Swift.max(0, c.residualCount) {
                let row = (off + t) * nf
                for a in cols {
                    let ja = J[row + a]
                    if ja == 0 { continue }
                    for b in cols where b >= a {
                        M[a * nf + b] += ja * J[row + b]
                    }
                }
            }
        }
        for a in 0..<nf {
            for b in (a + 1)..<nf { M[b * nf + a] = M[a * nf + b] }
        }

        let (values, vectors) = LinearAlgebra.symmetricEigen(M, n: nf)
        let lambdaMax = values.max() ?? 0
        let tol = Swift.max(lambdaMax * 1e-9, 1e-12)

        var nullEnergy = [Double](repeating: 0, count: nf)
        var dof = 0
        for k in 0..<nf where values[k] < tol {
            dof += 1
            for j in 0..<nf { nullEnergy[j] += vectors[k][j] * vectors[k][j] }
        }
        for (col, g) in free.enumerated() {
            determined[g] = nullEnergy[col] < 1e-6
        }
        return (dof, determined)
    }

}

// MARK: - Per-point solve state (A2)

/// Identifies a single solver point: an entity plus which of its points.
/// Two coincident (welded) points have DIFFERENT keys but resolve to the same
/// solver variables, so they report the same `SketchPointState`.
nonisolated struct SketchPointKey: Hashable, Sendable {
    var entityID: UUID
    var role: PointRole
}

/// Determinacy of one sketch point, for the on-canvas DOF markers.
/// - `free`: still has null-space motion (under-defined / movable).
/// - `constrained`: fully determined by constraints + dimensions (no motion).
/// - `locked`: pinned by a `.fixed` (Lock) constraint, or welded to a point
///   whose every variable is in the solver's fixed set.
nonisolated enum SketchPointState: Sendable, Equatable {
    case free
    case constrained
    case locked
}

nonisolated extension SketchSolverBridge {

    struct PointStateAnalysis {
        var points: [SketchPointKey: SketchPointState]
        /// Axis rectangle corners ordered min, bottom-right, max, top-left.
        var rectangleCorners: [UUID: [SketchPointState]]
    }

    /// Per-point determinacy for every point of every entity in `sketch`, keyed
    /// by (entityID, role). Reuses the SAME build → solve → null-space path as
    /// `entityStates`, but reports at (entity, role) granularity instead of one
    /// bool per entity. Coincident (welded) points share solver variables and
    /// therefore report identical states — desired for showing connected joints.
    static func pointStates(_ sketch: Sketch) -> [SketchPointKey: SketchPointState] {
        pointStateAnalysis(sketch).points
    }

    static func pointStateAnalysis(_ sketch: Sketch) -> PointStateAnalysis {
        var out: [SketchPointKey: SketchPointState] = [:]

        // Which points an explicit `.fixed` (Lock) constraint pins. A `.whole`
        // ref pins every point (and radius) of that entity; a point ref pins
        // just that (entity, role). Mirrors buildSystem's `.fixed` handling.
        var lockedWholeEntities = Set<UUID>()
        var lockedPoints = Set<SketchPointKey>()
        for c in sketch.constraints where c.kind == .fixed {
            for ref in c.refs {
                if ref.role == .whole {
                    // Side locks are classified from the actual fixed variables
                    // below, not as if both rectangle corners were fully locked.
                    if let edge = ref.rectangleEdge, (0..<4).contains(edge),
                       case .rect? = sketch.entities.first(where: { $0.id == ref.entityID }) {
                        continue
                    }
                    lockedWholeEntities.insert(ref.entityID)
                } else {
                    lockedPoints.insert(SketchPointKey(entityID: ref.entityID, role: ref.role))
                }
            }
        }
        func explicitlyLocked(_ id: UUID, _ role: PointRole) -> Bool {
            lockedWholeEntities.contains(id)
                || lockedPoints.contains(SketchPointKey(entityID: id, role: role))
        }

        let sys = buildSystem(from: sketch, movingEntity: nil, dragTarget: nil)

        // Degenerate (no variables / no entities): every enumerated point is as
        // determined as it can be — locked if pinned, else constrained (matches
        // `entityStates` returning `true` for an empty system).
        guard !sys.initial.isEmpty else {
            for e in sketch.entities {
                for slot in mutableSlots(e) {
                    let key = SketchPointKey(entityID: slot.entityID, role: slot.role)
                    out[key] = explicitlyLocked(slot.entityID, slot.role) ? .locked : .constrained
                }
            }
            return PointStateAnalysis(points: out, rectangleCorners: [:])
        }

        let solved = ConstraintSolver.solve(
            initial: sys.initial,
            fixed: sys.fixed,
            constraints: sys.solveConstraints
        ).variables
        let determined = nullSpaceAnalysis(sys, at: solved).determined

        for e in sketch.entities {
            for slot in mutableSlots(e) {
                let key = SketchPointKey(entityID: slot.entityID, role: slot.role)
                guard let pi = sys.pointIndex[SlotKey(entityID: slot.entityID, role: slot.role)] else {
                    out[key] = explicitlyLocked(slot.entityID, slot.role) ? .locked : .free
                    continue
                }
                // The point's own position variables (its welded x,y pair).
                let posVars = [2 * pi, 2 * pi + 1]
                // A circle/arc/polygon `.center` also carries the entity's
                // radius scalar — the round entity is not fully *defined* until
                // its radius is, but the radius does not affect whether the
                // point itself can move.
                var definingVars = posVars
                if slot.role == .center, let rv = sys.radiusVar[slot.entityID] {
                    definingVars.append(rv)
                }
                // `.locked` is about immobility of the POINT: an explicit lock,
                // or every POSITION variable pinned in the solver's fixed set —
                // a centre welded onto a fixed point is locked even while its
                // radius is still free.
                if explicitlyLocked(slot.entityID, slot.role)
                    || posVars.allSatisfy({ sys.fixed.contains($0) }) {
                    out[key] = .locked
                } else if definingVars.allSatisfy({ $0 < determined.count && determined[$0] }) {
                    out[key] = .constrained
                } else {
                    out[key] = .free
                }
            }
        }
        var corners: [UUID: [SketchPointState]] = [:]
        for case let .rect(id, _, _) in sketch.entities {
            guard let a = sys.pointIndex[SlotKey(entityID: id, role: .endpointA)],
                  let b = sys.pointIndex[SlotKey(entityID: id, role: .endpointB)] else { continue }
            // The off-diagonal corners combine coordinates from two solver
            // points. Classify those coordinates, not the endpoints as wholes.
            corners[id] = [[2*a, 2*a+1], [2*b, 2*a+1], [2*b, 2*b+1], [2*a, 2*b+1]].map { vars in
                if vars.allSatisfy({ sys.fixed.contains($0) }) { return .locked }
                if vars.allSatisfy({ $0 < determined.count && determined[$0] }) { return .constrained }
                return .free
            }
        }
        return PointStateAnalysis(points: out, rectangleCorners: corners)
    }
}
