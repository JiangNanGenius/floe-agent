import Foundation

/// Selection-based visibility applies to each annotation, not its entire sketch.
nonisolated enum SketchAnnotationVisibility {
    static func shows(
        refs: [ConstraintRef], alwaysShow: Bool,
        selectedEntities: Set<UUID>, selectedPoints: [ConstraintRef],
        explicitlySelected: Bool = false
    ) -> Bool {
        alwaysShow || explicitlySelected || refs.contains { ref in
            selectedEntities.contains(ref.entityID) || selectedPoints.contains { point in
                point.entityID == ref.entityID && (ref.role == .whole || point.role == ref.role)
            }
        }
    }
}
