//
//  GizmoScreenLayout.swift
//  openshape3d
//
//  The single source of truth for WHERE the move/rotate gizmo's handles sit on
//  screen. Both the `MoveGizmoOverlay` (which draws them) and the viewport
//  (which hit-tests taps against them) use it, so the flat 2D handle a user
//  sees is exactly the target they grab. Everything is expressed as gizmo-local
//  offsets projected through a caller-supplied `project` closure
//  (local → world → screen), so the layout has no camera dependency of its own.
//

import Foundation
import simd
import CoreGraphics

nonisolated enum GizmoScreenLayout {
    /// Gizmo-local anchor distances (match GizmoGeometry).
    static let armLocal: Float = 0.82    // axis arrow
    /// Rotation arcs sit OUTSIDE the move arrows (armLocal) so the two don't
    /// share space — a grab meant for a move handle no longer catches a rotate
    /// arc. (They used to be at 0.62, tucked among the move controls.)
    static let ringLocal: Float = 0.98
    /// Plane-tile centre — derived, so it tracks the tile's own span.
    static var planeLocal: Float { (GizmoGeometry.planeMin + GizmoGeometry.planeMax) / 2 }

    /// Screen grab tolerances (points). Generous — these are touch targets.
    static let arrowHitRadius: CGFloat = 44
    /// Slop OUTSIDE a plane tile. The tile itself is a projected quad and a tap
    /// anywhere INSIDE it grabs the plane outright; this band only widens the
    /// target a little past the drawn edge for touch.
    static let planeHitRadius: CGFloat = 20
    /// Rotation arcs get a big touch band — they are now off on their own
    /// (outside the move arrows), so a generous target is safe and grabbable.
    static let ringHitRadius: CGFloat = 50
    /// Dead zone around the pivot (the free-move dot). A tap here grabs nothing
    /// rather than a random nearby handle, and it keeps the generous arrow band
    /// from claiming a dead-centre tap.
    static let pivotDeadZone: CGFloat = 18
    /// Grab radius for the pivot once it is ARMED for repositioning (tapping
    /// the centre turns the dot into a crosshair you drag). Bigger than the
    /// dead zone: at that point moving the control IS the gesture.
    static let pivotGrabRadius: CGFloat = 40

    /// A plane tile whose projected quad has shrunk below this fraction of the
    /// LARGEST tile's area is edge-on (its plane points at the camera) — it is
    /// faded by the overlay and skipped by the hit test, so an invisible sliver
    /// never claims a drag. Relative, so it means the same at every gizmo size.
    static let planeEdgeOnFraction: CGFloat = 0.18
    /// …with an absolute floor, for the degenerate case where ALL three tiles
    /// are small (a very short viewport).
    static let planeMinArea: CGFloat = 16

    /// How far out from the pivot a grab must be, as a fraction of that arc's
    /// own projected radius, before it counts as a rotation. Keeps the arcs'
    /// generous touch band from reaching in over the plane tiles — the tiles'
    /// outer corners already sit at ~0.54 gizmo units, and the arcs at 0.98.
    static let ringInnerFraction: CGFloat = 0.75

    /// The projected arm length these point tolerances were tuned against.
    ///
    /// The gizmo's on-screen size follows the VIEWPORT HEIGHT (its world scale
    /// cancels against the projection's half-height divide), so one gizmo unit
    /// is ~0.24 × viewportHeight/2 points: ~165pt on a portrait iPad, but only
    /// ~47pt in iPhone LANDSCAPE, where the 0.82-unit arm projects to ~39pt.
    /// Fixed point tolerances then stop describing the gizmo at all — see
    /// `shrinkFactor` (2026-08-25 review round 3, finding R3-A).
    static let referenceArmPoints: CGFloat = 96

    /// Fraction of the LONGEST arm below which an axis counts as foreshortened
    /// (pointing into the screen) and is skipped. Relative, so it means the
    /// same thing at every gizmo size.
    static let foreshortenedFraction: CGFloat = 0.25

    /// Scales the touch tolerances down when the gizmo itself is small.
    ///
    /// 1.0 at reference size and above (iPad and the test projector are
    /// unaffected); ~0.4 in iPhone landscape. Without it the tolerances were
    /// LARGER than the gizmo: the arrow gate compared the arm against the 44pt
    /// touch radius and skipped all three axes, and the 18pt pivot dead zone
    /// swallowed the plane handles at ~11pt — so a fully-opaque gizmo was
    /// completely un-grabbable and drags fell through to a camera orbit.
    static func shrinkFactor(longestArm: CGFloat) -> CGFloat {
        guard longestArm > 0 else { return 1 }
        return min(1, longestArm / referenceArmPoints)
    }

    static let axes: [GizmoPart] = [.xAxis, .yAxis, .zAxis]
    static let rings: [GizmoPart] = [.xRing, .yRing, .zRing]
    static let planes: [GizmoPart] = [.xyPlane, .yzPlane, .zxPlane]

    /// Screen point of an axis arrow, or nil if it projects off-screen.
    static func axisAnchor(_ part: GizmoPart,
                           project: (SIMD3<Float>) -> CGPoint?) -> CGPoint? {
        project(part.axisDirection * armLocal)
    }

    /// Screen point of a plane-move handle.
    static func planeAnchor(_ part: GizmoPart,
                            project: (SIMD3<Float>) -> CGPoint?) -> CGPoint? {
        project(planeCenterLocal(part))
    }

    /// The projected arc of a rotation ring (its on-screen ellipse segment).
    static func ringPolyline(_ part: GizmoPart,
                             project: (SIMD3<Float>) -> CGPoint?) -> [CGPoint] {
        let (u, v) = GizmoGeometry.ringBasis(for: part)
        let a0 = Float.pi / 4 - 15 * .pi / 180
        let a1 = Float.pi / 4 + 15 * .pi / 180
        let steps = 12
        var pts: [CGPoint] = []
        for i in 0...steps {
            let a = a0 + (a1 - a0) * Float(i) / Float(steps)
            if let p = project((u * cos(a) + v * sin(a)) * ringLocal) { pts.append(p) }
        }
        return pts
    }

    static func planeCenterLocal(_ part: GizmoPart) -> SIMD3<Float> {
        switch part {
        case .xyPlane: SIMD3(planeLocal, planeLocal, 0)
        case .yzPlane: SIMD3(0, planeLocal, planeLocal)
        default:       SIMD3(planeLocal, 0, planeLocal)
        }
    }

    /// The two in-plane axes of a plane tile (matching `GizmoGeometry`'s plane
    /// coordinates, so the drawn quad and the 3D drag constraint agree).
    static func planeBasis(for part: GizmoPart) -> (u: SIMD3<Float>, v: SIMD3<Float>) {
        switch part {
        case .yzPlane: (SIMD3(0, 1, 0), SIMD3(0, 0, 1))
        case .zxPlane: (SIMD3(0, 0, 1), SIMD3(1, 0, 0))
        default:       (SIMD3(1, 0, 0), SIMD3(0, 1, 0))   // xyPlane
        }
    }

    /// The tile's four corners in gizmo-local space, spanning the SAME square
    /// the 3D hit test accepts. Because they lie IN the plane, their projection
    /// is a parallelogram that leans with the plane — which is the whole point:
    /// the square a user sees tells them which way it will drag.
    static func planeCornersLocal(_ part: GizmoPart) -> [SIMD3<Float>] {
        let (u, v) = planeBasis(for: part)
        let a = GizmoGeometry.planeMin, b = GizmoGeometry.planeMax
        return [u * a + v * a, u * b + v * a, u * b + v * b, u * a + v * b]
    }

    /// The tile's projected quad (4 screen points), or nil if it clips.
    static func planeQuad(_ part: GizmoPart,
                          project: (SIMD3<Float>) -> CGPoint?) -> [CGPoint]? {
        let pts = planeCornersLocal(part).compactMap(project)
        return pts.count == 4 ? pts : nil
    }

    /// Shoelace area of a projected polygon (points²). Zero when edge-on.
    static func polygonArea(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }

    /// True when `point` is inside the projected quad (even-odd crossing).
    static func polygonContains(_ pts: [CGPoint], _ point: CGPoint) -> Bool {
        guard pts.count >= 3 else { return false }
        var inside = false
        var j = pts.count - 1
        for i in 0..<pts.count {
            let a = pts[i], b = pts[j]
            if (a.y > point.y) != (b.y > point.y) {
                let t = (point.y - a.y) / (b.y - a.y)
                if point.x < a.x + t * (b.x - a.x) { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    /// Screen radius of the pivot target: the dead zone normally, a bigger
    /// grab circle once the pivot is armed for repositioning.
    static func pivotRadius(armed: Bool,
                            project: (SIMD3<Float>) -> CGPoint?) -> CGFloat {
        let shrink = shrinkFactor(longestArm: longestArm(project: project))
        return max(armed ? 22 : 12, (armed ? pivotGrabRadius : pivotDeadZone) * shrink)
    }

    /// True when a tap lands on the gizmo's centre pivot.
    static func hitsPivot(at point: CGPoint, armed: Bool,
                          project: (SIMD3<Float>) -> CGPoint?) -> Bool {
        guard let center = project(.zero) else { return false }
        return hypot(point.x - center.x, point.y - center.y)
            <= pivotRadius(armed: armed, project: project)
    }

    /// Longest projected arm, the yardstick every tolerance is scaled by.
    static func longestArm(project: (SIMD3<Float>) -> CGPoint?) -> CGFloat {
        guard let center = project(.zero) else { return 0 }
        var longest: CGFloat = 0
        for part in axes {
            guard let tip = axisAnchor(part, project: project) else { continue }
            longest = max(longest, hypot(tip.x - center.x, tip.y - center.y))
        }
        return longest
    }

    /// The gizmo part under a screen tap, matching what the overlay draws.
    ///
    /// Plane tiles are projected QUADS — a tap inside one grabs that plane
    /// outright, before the arrows or the pivot dead zone get a say, because
    /// that quad is exactly the square the user aimed at. (The axis lines never
    /// cross a tile: it starts at `GizmoGeometry.planeMin` out from each axis.)
    /// Arrows are then line targets and rings the projected arc polyline, and
    /// ties resolve by the SMALLEST normalised distance (distance / that part's
    /// tolerance), so a tap a hair inside two overlapping targets picks the one
    /// it is most centred on. Rings go last, so where an arc passes behind an
    /// arrow the arrow wins — translation stays the easy default.
    static func hitTest(at point: CGPoint,
                        project: (SIMD3<Float>) -> CGPoint?,
                        ringsOnly: Bool = false) -> GizmoPart? {
        var best: (part: GizmoPart, score: CGFloat)?
        func consider(_ part: GizmoPart, _ distance: CGFloat, _ tol: CGFloat) {
            guard distance <= tol else { return }
            let score = distance / tol
            if best == nil || score < best!.score { best = (part, score) }
        }

        // How big is the gizmo on screen right now? Every tolerance below is
        // scaled by this, so the handles stay grabbable — and stay distinct —
        // at any viewport size.
        let center = project(.zero)
        var arms: [(part: GizmoPart, tip: CGPoint, length: CGFloat)] = []
        var longestArm: CGFloat = 0
        for part in axes {
            guard let tip = axisAnchor(part, project: project) else { continue }
            let length = center.map { hypot(tip.x - $0.x, tip.y - $0.y) } ?? 0
            arms.append((part, tip, length))
            longestArm = max(longestArm, length)
        }
        let shrink = shrinkFactor(longestArm: longestArm)
        // Floors keep a very small gizmo from having sub-pixel targets.
        let arrowTol = max(10, arrowHitRadius * shrink)
        let planeTol = max(6, planeHitRadius * shrink)
        let ringTol = max(12, ringHitRadius * shrink)
        let deadZone = pivotDeadZone * shrink

        // Rotate-a-face shows ONLY the rings; test them alone so the (invisible)
        // axis/plane targets can't win the hit near the centre and then get
        // filtered out, leaving the drag to fall through to a camera orbit.
        if ringsOnly {
            for part in rings {
                let poly = ringPolyline(part, project: project)
                if let d = distance(from: point, toPolyline: poly) { consider(part, d, ringTol) }
            }
            return best?.part
        }

        // Plane tiles first, as the quads they are drawn as. A tap INSIDE a
        // tile returns immediately: it beats the arrows' generous line band and
        // it is exempt from the pivot dead zone, which used to swallow the
        // inner corner of a tile on a small viewport (the tiles start only
        // ~0.18 gizmo units out).
        // Reversed, so where two tiles overlap on screen the one drawn ON TOP
        // (the overlay draws them in `planes` order) is the one grabbed.
        let tiles = visiblePlaneQuads(project: project)
        if let hit = tiles.reversed().first(where: { polygonContains($0.quad, point) }) {
            return hit.part
        }

        // An axis is grabbable along its whole projected LINE — from the pivot
        // out to the arrow — not just the arrowhead, so a grab anywhere on the
        // arrow lands. A foreshortened axis (arrow collapsed onto the pivot,
        // pointing into the screen) is skipped: the overlay fades it and
        // grabbing it there would be a surprise.
        // Dead-centre taps are the free-move pivot — grab nothing.
        if let center, hypot(point.x - center.x, point.y - center.y) < deadZone {
            return nil
        }
        // Just OUTSIDE a tile still counts, within a touch band around its edge.
        for tile in tiles {
            if let d = distance(from: point, toPolyline: tile.quad + [tile.quad[0]]) {
                consider(tile.part, d, planeTol)
            }
        }
        for arm in arms {
            if center != nil {
                // Skip an axis that is FORESHORTENED — collapsed toward the
                // pivot because it points into the screen. Measured against
                // the longest arm, not against a touch radius: comparing an
                // arm to `arrowHitRadius` meant that on any viewport where the
                // whole gizmo was smaller than the touch target, every axis
                // was skipped.
                guard arm.length >= longestArm * foreshortenedFraction else { continue }
                // Start the grabbable segment partway out from the pivot, so a
                // tap dead-centre (over the free-move dot) does not grab a
                // random axis, while grabs along the arrow's line still land.
                let c = center!
                let start = CGPoint(x: c.x + (arm.tip.x - c.x) * 0.4,
                                    y: c.y + (arm.tip.y - c.y) * 0.4)
                consider(arm.part, distance(from: point, toSegment: start, arm.tip), arrowTol)
            } else {
                consider(arm.part, hypot(arm.tip.x - point.x, arm.tip.y - point.y), arrowTol)
            }
        }
        // Rings only if nothing closer already won on a point target — and
        // only OUT where the arc actually is. A rotation arc rides at ~0.98
        // gizmo units, so its fat touch band (deliberately fat: rotation was
        // hard to grab) reaches all the way back over the plane tiles near the
        // pivot. That turned a near-miss on a skinny tile into a ROTATION —
        // the "dragging the squares doesn't stay in its plane" report. Grabs
        // deep inside the ring are not for the ring.
        if best == nil {
            for part in rings {
                let poly = ringPolyline(part, project: project)
                guard let d = distance(from: point, toPolyline: poly) else { continue }
                guard let center else { consider(part, d, ringTol); continue }
                let radii = poly.map { hypot($0.x - center.x, $0.y - center.y) }
                let inner = radii.min() ?? 0, outer = radii.max() ?? 0
                guard hypot(point.x - center.x, point.y - center.y) >= inner * ringInnerFraction
                else { continue }
                // …and the band never grows wider than the arc it belongs to.
                consider(part, d, min(ringTol, max(12, outer * 0.35)))
            }
        }
        return best?.part
    }

    /// One plane handle as it lands on screen: the quad the overlay draws and
    /// the hit test grabs, plus how big it is (how face-on the plane is).
    struct PlaneTile: Identifiable {
        let part: GizmoPart
        let quad: [CGPoint]
        let area: CGFloat
        var id: GizmoPart { part }
    }

    /// The plane tiles worth drawing/grabbing: projected quads, minus any that
    /// has collapsed edge-on (its plane pointing at the camera), where the
    /// drawn sliver would be both invisible and a lie about what it drags.
    static func visiblePlaneQuads(project: (SIMD3<Float>) -> CGPoint?) -> [PlaneTile] {
        var tiles: [PlaneTile] = []
        var largest: CGFloat = 0
        for part in planes {
            guard let quad = planeQuad(part, project: project) else { continue }
            let area = polygonArea(quad)
            tiles.append(PlaneTile(part: part, quad: quad, area: area))
            largest = max(largest, area)
        }
        let floor = max(largest * planeEdgeOnFraction, planeMinArea)
        return tiles.filter { $0.area >= floor }
    }

    private static func distance(from p: CGPoint, toPolyline pts: [CGPoint]) -> CGFloat? {
        guard pts.count >= 2 else { return nil }
        var best: CGFloat?
        for i in 0..<(pts.count - 1) {
            let d = distance(from: p, toSegment: pts[i], pts[i + 1])
            if best == nil || d < best! { best = d }
        }
        return best
    }

    private static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 1e-9 else { return hypot(p.x - a.x, p.y - a.y) }
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = min(max(t, 0), 1)
        return hypot(p.x - (a.x + dx * t), p.y - (a.y + dy * t))
    }
}
