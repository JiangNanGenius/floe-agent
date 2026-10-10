import Foundation
import simd

/// Transient radial intent. Saved dimensions/constraints are never replaced by
/// a drag, and the drag does not persist a driving radius or a center lock.
nonisolated enum SketchRadialDrag {
    static func solve(_ sketch: Sketch, entityID: UUID, radius: Double) -> [SketchEntity]? {
        guard radius.isFinite, radius > 1e-3,
              let entity = sketch.entities.first(where: { $0.id == entityID }) else { return nil }
        switch entity {
        case .arc, .circle: break
        default: return nil
        }
        var proposed = sketch
        proposed.dimensions.append(SketchDimension(kind: .radius,
            refs: [.init(entityID: entityID, role: .whole)], value: radius))
        proposed.constraints.append(SketchConstraint(kind: .fixed,
            refs: [.init(entityID: entityID, role: .center)]))
        let result = SketchSolverBridge.solveOutcome(proposed, movingEntity: nil, dragTarget: nil)
        guard result.converged, result.structuralResidual <= 1e-5 else { return nil }
        return result.entities
    }
}
