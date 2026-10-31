//
//  CADPresentationFloorPlacement.swift
//  FloeCADKit
//
//  The Present ground is one real horizontal plane. Its height must follow the
//  actual transformed model instead of a fixed Y=0 guess: a body placed or
//  animated below the origin would otherwise be bisected by the ground. A
//  finite scene keeps the plane centred under the model so it still covers the
//  model footprint and receives its grounding shadow.
//
//  Only the floor moves. Body geometry, UVs, materials, camera projection and
//  lighting are untouched, and the floor's authored size, colour, visibility
//  and shadow behaviour remain the environment's.
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import Foundation
import simd

/// Renderer-neutral floor placement values. Entity mutation stays on the
/// builder/controller so this file never owns a second scene.
nonisolated enum CADPresentationFloorPlacement {
    /// Vertical gap between the lowest transformed model point and the ground,
    /// in presentation metres. This is the same 0.5 mm edge the old
    /// origin-relative floor used, now measured from the real minimum.
    static let clearance: Float = 0.0005

    /// Floor position in presentation metres. An empty scene or invalid bounds
    /// keeps the historical origin-relative placement rather than producing a
    /// NaN entity; a valid scene puts the plane just below its transformed
    /// minimum and centred on its transformed X/Z footprint.
    static func position(for bounds: CADPresentationBounds?) -> SIMD3<Float> {
        guard let bounds,
              isFinite(bounds.min), isFinite(bounds.max),
              bounds.min.x <= bounds.max.x,
              bounds.min.y <= bounds.max.y,
              bounds.min.z <= bounds.max.z else {
            return SIMD3(0, -clearance, 0)
        }
        let center = bounds.center
        guard isFinite(center) else {
            return SIMD3(0, -clearance, 0)
        }
        return SIMD3(center.x, bounds.min.y - clearance, center.z)
    }

    /// World bounds for the visible snapshot bodies under one animated
    /// transform map. A body missing from `transforms` keeps its static
    /// document transform, exactly as `applyAnimation` applies it. Invalid
    /// transforms/bounds are ignored rather than poisoning the ground with
    /// NaNs; an empty scene returns nil so the caller keeps the fallback.
    static func bounds(for scene: CADPresentationScene,
                       transforms: [UUID: simd_float4x4]? = nil) -> CADPresentationBounds? {
        var result: CADPresentationBounds?
        for body in scene.bodies {
            let transform = transforms?[body.id] ?? body.transform
            guard isFinite(transform) else { continue }
            guard isFinite(body.mesh.boundsMin), isFinite(body.mesh.boundsMax),
                  body.mesh.boundsMin.x <= body.mesh.boundsMax.x,
                  body.mesh.boundsMin.y <= body.mesh.boundsMax.y,
                  body.mesh.boundsMin.z <= body.mesh.boundsMax.z else {
                continue
            }
            let bodyBounds = CADPresentationSceneBuilder.worldBounds(
                min: body.mesh.boundsMin, max: body.mesh.boundsMax,
                transform: transform)
            guard isFinite(bodyBounds.min), isFinite(bodyBounds.max) else { continue }
            if let existing = result {
                result = CADPresentationBounds(
                    min: simd_min(existing.min, bodyBounds.min),
                    max: simd_max(existing.max, bodyBounds.max))
            } else {
                result = bodyBounds
            }
        }
        return result
    }

    static func isFinite(_ point: SIMD3<Float>) -> Bool {
        point.x.isFinite && point.y.isFinite && point.z.isFinite
    }

    static func isFinite(_ matrix: simd_float4x4) -> Bool {
        [matrix.columns.0, matrix.columns.1,
         matrix.columns.2, matrix.columns.3].allSatisfy {
            $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite
        }
    }
}
#endif
