//
//  SketchConstraintTypes.swift
//  openshape3d
//
//  Persisted constraint & dimension data model for sketches (Phase C).
//  These types describe geometric relationships symbolically — they reference
//  sketch entities by ID and a point role — and are lowered into concrete
//  `ConstraintResidual` systems by `SketchSolverBridge` at solve time.
//
//  nonisolated + Double/Codable to match the rest of the kernel.
//

import Foundation

/// Which point of a referenced entity a constraint/dimension operand addresses.
/// `whole` means the entity itself (e.g. a line used as a direction/axis, or a
/// circle used for a radius/tangent) rather than one of its points.
nonisolated enum PointRole: String, Codable, Equatable, Sendable {
    case endpointA
    case endpointB
    case center
    case whole
}

/// A single operand of a constraint or dimension: an entity plus the point role
/// on that entity the operand refers to.
nonisolated struct ConstraintRef: Codable, Equatable, Sendable {
    var entityID: UUID
    var role: PointRole
    /// Optional side of an axis-aligned rectangle (bottom/right/top/left).
    /// Only used by whole-operand Lock; absent in legacy whole-entity locks.
    var rectangleEdge: Int? = nil

    init(entityID: UUID, role: PointRole, rectangleEdge: Int? = nil) {
        self.entityID = entityID
        self.role = role
        self.rectangleEdge = rectangleEdge
    }
}

/// Geometric constraint kinds (spec §3.2). `fixed` locks the referenced
/// point(s) in place (Lock).
nonisolated enum SketchConstraintKind: String, Codable, Equatable, Sendable {
    case coincident
    case horizontal
    case vertical
    case parallel
    case perpendicular
    case equalLength
    case equalRadius
    case concentric
    case midpoint
    case symmetric
    case tangent
    case colinear
    case fixed
}

/// Saved circle-circle Tangent branch; nil on legacy records means external.
nonisolated enum CircleTangency: String, Codable, Equatable, Sendable {
    case externalContact
    case internalContact
}

/// A symbolic constraint on a sketch. `refs` layout is kind-specific and
/// documented in `SketchSolverBridge` (which lowers each kind).
nonisolated struct SketchConstraint: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: SketchConstraintKind
    var refs: [ConstraintRef]
    var circleTangency: CircleTangency? = nil

    init(id: UUID = UUID(), kind: SketchConstraintKind, refs: [ConstraintRef],
         circleTangency: CircleTangency? = nil) {
        self.id = id
        self.kind = kind
        self.refs = refs
        self.circleTangency = circleTangency
    }
}

/// Dimension label kinds (spec §2.2).
nonisolated enum DimensionKind: String, Codable, Equatable, Sendable {
    case distance
    case radius
    case diameter
    case angle
    /// Distance between two points measured along the sketch X axis only —
    /// a rectangle's width (its two corners are its only solver points, so
    /// a plain `.distance` between them would dimension the diagonal).
    case horizontal
    /// Distance between two points measured along the sketch Y axis only —
    /// a rectangle's height.
    case vertical
}

/// A driving dimension: a measured value the solver drives geometry to satisfy.
/// `value` is in sketch units for linear kinds, and in RADIANS for `.angle`.
nonisolated struct SketchDimension: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var kind: DimensionKind
    var refs: [ConstraintRef]
    var value: Double
    /// Phase D (Task A2): optional parametric formula string driving `value`.
    /// nil for a plain numeric dimension. Decoded via the synthesized Codable's
    /// `decodeIfPresent`, so pre-tranche-3 sketches (no "formula" key) load as nil.
    var formula: String? = nil
    /// Retained constant arithmetic in its explicit input units. Unlike a
    /// variable formula, this is presentation/source text, not re-evaluated
    /// when document variables change. Optional for legacy documents.
    var displayExpression: String? = nil
    /// Optional annotation anchor relative to the referenced circle center, in
    /// sketch-plane units. Presentation only; never enters the solver.
    var labelOffset: SIMD2<Double>? = nil
    /// Committed axis-rectangle annotation sides, presentation only. Legacy nil
    /// retains existing placement; never adds dimensions or solver references.
    var rectangleLabelEdges: [Int]? = nil
    /// The primitive rectangle edge whose size was made driving. Unlike label
    /// aliases, this provenance determines whether Trim removes the driver.
    /// Legacy nil retains the existing point-reference transfer behavior.
    var rectangleDrivingEdge: Int? = nil

    init(id: UUID = UUID(),
         kind: DimensionKind,
         refs: [ConstraintRef],
         value: Double,
         formula: String? = nil,
         labelOffset: SIMD2<Double>? = nil,
         displayExpression: String? = nil,
         rectangleLabelEdges: [Int]? = nil,
         rectangleDrivingEdge: Int? = nil) {
        self.id = id
        self.kind = kind
        self.refs = refs
        self.value = value
        self.formula = formula
        self.displayExpression = displayExpression
        self.labelOffset = labelOffset
        self.rectangleLabelEdges = rectangleLabelEdges
        self.rectangleDrivingEdge = rectangleDrivingEdge
    }
}
