//
//  AreaSelect.swift
//  openshape3d
//
//  Pure marquee-selection logic (plan §B13, spec §8.2). Dragging
//  left→right makes a WINDOW box (only items completely inside select);
//  right→left makes a CROSSING box (any vertex inside selects). The
//  world→screen projection is injected as a closure so the membership
//  rules unit-test without a camera; hidden items are always skipped.
//

import Foundation
import simd

/// One selectable item offered to the marquee: a body or a sketch entity,
/// sampled as world-space points (mesh vertices / tessellated endpoints).
nonisolated struct AreaSelectCandidate {
    enum Item: Hashable, Sendable {
        case body(BodyID)
        case sketchEntity(UUID)
    }

    var item: Item
    /// World-space sample points. Window mode requires every point inside
    /// the marquee; crossing mode requires at least one.
    var points: [SIMD3<Float>]
    var isHidden: Bool = false
}

nonisolated enum AreaSelect {

    /// Window = fully inside (left→right drag); crossing = touched
    /// (right→left drag).
    enum Mode: Sendable {
        case window
        case crossing
    }

    /// v1 selection filters (spec §8.2's B/F/E keys reduced to the
    /// Bodies | Sketches chips; faces/edges later).
    enum Filter: Sendable {
        case bodiesOnly
        case sketchEntitiesOnly
        case bodiesAndSketchEntities
    }

    /// Drag direction decides the semantics — left→right window,
    /// right→left crossing (spec §8.2).
    static func mode(dragStart: SIMD2<Double>, dragEnd: SIMD2<Double>) -> Mode {
        dragEnd.x >= dragStart.x ? .window : .crossing
    }

    /// Items selected by a marquee drag from `dragStart` to `dragEnd`
    /// (screen points; the rect is their normalized bounds). `project` maps
    /// a world point to screen space, returning nil for points that don't
    /// reach the screen (behind the camera) — those never count as inside.
    static func select(
        candidates: [AreaSelectCandidate],
        dragStart: SIMD2<Double>,
        dragEnd: SIMD2<Double>,
        filter: Filter,
        project: (SIMD3<Float>) -> SIMD2<Double>?
    ) -> [AreaSelectCandidate.Item] {
        let mode = mode(dragStart: dragStart, dragEnd: dragEnd)
        let lo = simd_min(dragStart, dragEnd)
        let hi = simd_max(dragStart, dragEnd)

        func inside(_ world: SIMD3<Float>) -> Bool {
            guard let p = project(world) else { return false }
            return p.x >= lo.x && p.x <= hi.x && p.y >= lo.y && p.y <= hi.y
        }

        var result: [AreaSelectCandidate.Item] = []
        for candidate in candidates where !candidate.isHidden {
            if case .sketchEntity = candidate.item, filter == .bodiesOnly {
                continue
            }
            if case .body = candidate.item, filter == .sketchEntitiesOnly {
                continue
            }
            guard !candidate.points.isEmpty else { continue }
            let selected: Bool
            switch mode {
            case .window:
                selected = candidate.points.allSatisfy(inside)
            case .crossing:
                selected = candidate.points.contains(where: inside)
            }
            if selected {
                result.append(candidate.item)
            }
        }
        return result
    }
}
