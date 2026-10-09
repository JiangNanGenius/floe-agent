//
//  AutoConstraintEngine.swift
//  openshape3d
//
//  Live auto-constraint / inference for the sketch tools (spec §3, plan §B).
//  `infer` runs every drag frame while the user draws a stroke from `anchor`
//  (endpointA of the new entity) to `current` (endpointB). It returns a snapped
//  `current`, the guide segments to render, and the constraints to auto-emit if
//  the stroke commits.
//
//  Pure geometry: `nonisolated`, no MainActor, no I/O. `SketchTool` is passed by
//  value and only ever pattern-matched (never compared with `==`) so this stays
//  callable from nonisolated code even though `SketchTool` is MainActor-isolated
//  by default.
//

import Foundation
import simd

nonisolated struct AutoConstraintSettings: Codable, Equatable, Sendable {
    var enabled = true
    var horizontalVertical = true
    var pointSnap = true
    var parallelPerpendicular = true
    var tangent = true
    // Paired near-equal strokes (2026-09-08) remain independent in native.
    // Equality inference can move existing geometry, so require explicit opt-in.
    // Codable still restores the saved choice; manual Equal is unaffected.
    var equal = false
    /// Angular fallback for inference without a screen-space guide tolerance.
    /// Live line guides use a four-screen-point band (September 10 correction).
    ///
    /// Measured against Shapr3D on 2026-09-06 by drawing lines at known angles
    /// and checking whether the committed edge was snapped flat and carried a
    /// constraint badge: 0.57° yes, 1.15° no, 1.6° no. It was 5° here, which is
    /// why a line you meant to draw at a slight angle was grabbed flat and
    /// silently constrained.
    var angleToleranceDeg: Double = 1
    var pointTolerance: Double = 0.35
}

nonisolated enum AutoConstraintEngine {
    /// Ray intersections pass through Float coordinates. Admit only numerical
    /// roundoff at the screen-distance boundary, not an extra visible snap band.
    static func withinAxisDistance(_ delta: Double, tolerance: Double) -> Bool {
        abs(delta) <= tolerance + max(abs(tolerance) * 1e-6, 1e-9)
    }

    // Nested types are marked `nonisolated` explicitly: under the module's
    // `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` they do not inherit the outer
    // enum's isolation, and the nonisolated `infer` constructs them via their
    // memberwise initializers.
    nonisolated struct Guide: Equatable, Sendable {
        nonisolated enum Kind: Equatable, Sendable {
            case horizontal, vertical, pointOn, parallel, perpendicular, tangent, equalLength
        }
        var kind: Kind
        /// Plane-local segment endpoints to render. For point/marker guides
        /// (`pointOn`, `equalLength`, `tangent`) `a == b == the marked point`.
        var a: SIMD2<Double>
        var b: SIMD2<Double>
    }

    nonisolated struct Inferred: Equatable, Sendable {
        var kind: SketchConstraintKind
        /// Which point of the NEW entity this constraint attaches to.
        var selfRole: PointRole
        /// The existing entity the constraint targets; `nil` for pure axis
        /// constraints (horizontal / vertical).
        var targetEntityID: UUID?
        var targetRole: PointRole?
    }

    nonisolated struct Result: Sendable {
        var snappedPoint: SIMD2<Double>
        var guides: [Guide]
        var constraints: [Inferred]
    }

    // MARK: - Tunables

    /// Segments shorter than this are treated as degenerate (no direction).
    private static let lengthEpsilon: Double = 1e-9
    /// Relative tolerance for `equalLength` inference (3%).
    private static let equalLengthRelativeTolerance: Double = 0.03
    /// …capped in absolute terms at the point-snap tolerance. Inference adds a
    /// REAL constraint the solver then satisfies by moving geometry, and 3 %
    /// of a part-sized line is millimetres: drawing SOLIDWORKS practice
    /// problem 4.38's L-profile by touch (2026-09-04), a 98 mm segment next
    /// to a 96 mm one was inferred equal and the solve pulled the whole
    /// polyline off its grid (96 → 95.667, 150 → 148.167). Two lengths that
    /// differ by more than a snap step were placed differently on purpose.
    private static let equalLengthAbsoluteTolerance: Double = SnapEngine.pointTolerance
    /// How far horizontal / vertical guide lines extend past the segment.
    private static let guideMargin: Double = 1.0

    // MARK: - Entry point

    /// Directional acquisition and persistent relations are separate choices.
    /// Native Guide Lines can flatten a near-axis line with Auto-constraining
    /// off; disabling Guide Lines preserves raw aim even when Auto is on.
    static func inferLineInput(
        anchor: SIMD2<Double>, current: SIMD2<Double>, existing: [SketchEntity],
        settings: AutoConstraintSettings, guideLines: Bool,
        guideDistanceTolerance: Double? = nil
    ) -> Result {
        var acquisition = settings
        if !settings.enabled {
            acquisition.pointSnap = false
            acquisition.parallelPerpendicular = false
            acquisition.tangent = false
            acquisition.equal = false
        }
        let delta = current - anchor
        let exactlyAxisAligned = abs(delta.x) < 1e-9 || abs(delta.y) < 1e-9
        acquisition.horizontalVertical = guideLines ||
            (settings.enabled && settings.horizontalVertical && exactlyAxisAligned)
        acquisition.enabled = settings.enabled || guideLines
        guard acquisition.enabled else {
            return Result(snappedPoint: current, guides: [], constraints: [])
        }
        var result = inferLine(anchor: anchor, current: current,
            existing: existing, settings: acquisition,
            axisDistanceTolerance: guideLines ? guideDistanceTolerance : nil)
        if !settings.enabled {
            result.constraints = []
        } else if !settings.horizontalVertical {
            result.constraints.removeAll { $0.kind == .horizontal || $0.kind == .vertical }
        }
        return result
    }

    static func infer(
        tool: SketchTool,
        anchor: SIMD2<Double>,
        current: SIMD2<Double>,
        existing: [SketchEntity],
        settings: AutoConstraintSettings
    ) -> Result {
        guard settings.enabled else {
            return Result(snappedPoint: current, guides: [], constraints: [])
        }
        switch tool {
        case .line:
            return inferLine(anchor: anchor, current: current, existing: existing, settings: settings)
        default:
            // rect / circle / arc / ellipse / polygon (and the non-drawing
            // tools) only do point-snap in v1.
            return inferPointSnapOnly(current: current, existing: existing, settings: settings)
        }
    }

    /// Arc construction has a third-point stage, so its final tangent cannot
    /// be inferred by the two-point stroke path above. Match native's endpoint
    /// transition: when an arc endpoint is already on a line endpoint and the
    /// radius is perpendicular to that line within the configured angle gate,
    /// emit a real Tangent relationship. Interior crossings and merely nearby
    /// lines are deliberately excluded.
    static func inferArcTangencies(
        arc: SketchEntity,
        existing: [SketchEntity],
        settings: AutoConstraintSettings
    ) -> [Inferred] {
        guard settings.enabled, settings.tangent,
              case let .arc(_, center, radius, start, end) = arc,
              radius > lengthEpsilon else { return [] }

        let arcEndpoints = [
            SketchEntity.arcPoint(center: center, radius: radius, angle: start),
            SketchEntity.arcPoint(center: center, radius: radius, angle: end)
        ]
        let tolerance = settings.angleToleranceDeg * .pi / 180
        var inferred: [Inferred] = []
        var usedLines: Set<UUID> = []

        for endpoint in arcEndpoints {
            let radialVector = endpoint - center
            let radialLength = simd_length(radialVector)
            guard radialLength > lengthEpsilon else { continue }
            let radial = radialVector / radialLength
            var best: (id: UUID, deviation: Double)?

            for entity in existing {
                guard case let .line(id, a, b) = entity, !usedLines.contains(id) else { continue }
                let lineVector = b - a
                let lineLength = simd_length(lineVector)
                guard lineLength > lengthEpsilon,
                      min(simd_length(endpoint - a), simd_length(endpoint - b))
                        <= settings.pointTolerance else { continue }
                let direction = lineVector / lineLength
                let deviation = asin(min(1, abs(simd_dot(direction, radial))))
                if deviation <= tolerance,
                   best == nil || deviation < best!.deviation {
                    best = (id, deviation)
                }
            }

            if let best {
                usedLines.insert(best.id)
                inferred.append(Inferred(
                    kind: .tangent, selfRole: .whole,
                    targetEntityID: best.id, targetRole: .whole))
            }
        }
        return inferred
    }

    // MARK: - Non-line tools: point-snap only

    private static func inferPointSnapOnly(
        current: SIMD2<Double>,
        existing: [SketchEntity],
        settings: AutoConstraintSettings
    ) -> Result {
        // Non-line tools (rect / circle / arc / ellipse / polygon) only snap the
        // drawn point positionally — they do NOT emit a coincident constraint.
        // The drawn point's own role is ambiguous or absent: `makeEntity`
        // re-sorts a rect's corners into min/max at commit (so the grabbed
        // corner may be `.endpointA` or `.endpointB`), and circles/arcs/
        // ellipses/polygons expose only `.center`, never the rim point being
        // dragged. Any fixed `selfRole` we picked would weld the wrong point
        // (rect) or dangle against a nonexistent role (round entities), and
        // because coincidence is enforced by union-find welding rather than a
        // residual it would slip past the caller's over-constraint guard.
        // Positional snap gives the alignment without corrupting the graph.
        guard settings.pointSnap,
              let candidate = nearestRoleCandidate(
                  to: current, in: existing, tolerance: settings.pointTolerance)
        else {
            return Result(snappedPoint: current, guides: [], constraints: [])
        }
        return Result(snappedPoint: candidate.point, guides: [], constraints: [])
    }

    // MARK: - Line tool: full inference

    private static func inferLine(
        anchor: SIMD2<Double>,
        current: SIMD2<Double>,
        existing: [SketchEntity],
        settings: AutoConstraintSettings,
        axisDistanceTolerance: Double? = nil
    ) -> Result {
        var snapped = current
        var guides: [Guide] = []
        var constraints: [Inferred] = []

        let dir = current - anchor
        let length = simd_length(dir)
        let tolRad = settings.angleToleranceDeg * .pi / 180

        // 1. Point-coincident (endpointB) — highest priority; wins the snap.
        var didPointSnap = false
        if settings.pointSnap,
           let candidate = nearestRoleCandidate(
               to: current, in: existing, tolerance: settings.pointTolerance) {
            snapped = candidate.point
            didPointSnap = true
            constraints.append(Inferred(
                kind: .coincident,
                selfRole: .endpointB,
                targetEntityID: candidate.entityID,
                targetRole: candidate.role
            ))
            guides.append(Guide(kind: .pointOn, a: candidate.point, b: candidate.point))
        }

        // 2 & 3. Horizontal / vertical (mutually exclusive), only if the point
        // snap did not already pin the endpoint.
        var didHV = false
        if settings.horizontalVertical, !didPointSnap, length > lengthEpsilon {
            let devHorizontal = atan2(abs(dir.y), abs(dir.x))  // 0 == horizontal
            let devVertical = atan2(abs(dir.x), abs(dir.y))    // 0 == vertical
            let nearHorizontal = axisDistanceTolerance.map { withinAxisDistance(dir.y, tolerance: $0) } ?? (devHorizontal <= tolRad)
            let nearVertical = axisDistanceTolerance.map { withinAxisDistance(dir.x, tolerance: $0) } ?? (devVertical <= tolRad)
            if nearHorizontal, devHorizontal <= devVertical {
                snapped = SIMD2(current.x, anchor.y)
                constraints.append(Inferred(
                    kind: .horizontal, selfRole: .whole, targetEntityID: nil, targetRole: nil))
                let x0 = min(anchor.x, snapped.x) - guideMargin
                let x1 = max(anchor.x, snapped.x) + guideMargin
                guides.append(Guide(
                    kind: .horizontal, a: SIMD2(x0, anchor.y), b: SIMD2(x1, anchor.y)))
                didHV = true
            } else if nearVertical {
                snapped = SIMD2(anchor.x, current.y)
                constraints.append(Inferred(
                    kind: .vertical, selfRole: .whole, targetEntityID: nil, targetRole: nil))
                let y0 = min(anchor.y, snapped.y) - guideMargin
                let y1 = max(anchor.y, snapped.y) + guideMargin
                guides.append(Guide(
                    kind: .vertical, a: SIMD2(anchor.x, y0), b: SIMD2(anchor.x, y1)))
                didHV = true
            }
        }

        // 4. Parallel / perpendicular vs existing lines. Guides + constraints
        // always; snap the angle only if nothing above pinned the endpoint.
        // Skipped when h/v already fixed the orientation (would be redundant).
        if settings.parallelPerpendicular, !didHV, length > lengthEpsilon {
            let ndir = dir / length
            var bestParallel: (id: UUID, a: SIMD2<Double>, b: SIMD2<Double>, dev: Double)?
            var bestPerpendicular: (id: UUID, a: SIMD2<Double>, b: SIMD2<Double>, dev: Double)?

            for entity in existing {
                guard case let .line(id, la, lb) = entity else { continue }
                let refDir = lb - la
                let refLen = simd_length(refDir)
                guard refLen > lengthEpsilon else { continue }
                let nref = refDir / refLen
                // Undirected angle between the two lines, in [0, π/2].
                let angle = acos(min(1.0, max(0.0, abs(simd_dot(ndir, nref)))))
                let parallelDev = angle
                let perpendicularDev = (.pi / 2) - angle
                if parallelDev <= tolRad,
                   bestParallel == nil || parallelDev < bestParallel!.dev {
                    bestParallel = (id, la, lb, parallelDev)
                }
                if perpendicularDev <= tolRad,
                   bestPerpendicular == nil || perpendicularDev < bestPerpendicular!.dev {
                    bestPerpendicular = (id, la, lb, perpendicularDev)
                }
            }

            if let par = bestParallel {
                constraints.append(Inferred(
                    kind: .parallel, selfRole: .whole,
                    targetEntityID: par.id, targetRole: .whole))
                guides.append(Guide(kind: .parallel, a: par.a, b: par.b))
            }
            if let perp = bestPerpendicular {
                constraints.append(Inferred(
                    kind: .perpendicular, selfRole: .whole,
                    targetEntityID: perp.id, targetRole: .whole))
                guides.append(Guide(kind: .perpendicular, a: perp.a, b: perp.b))
            }

            // Snap the angle to the single closest relationship.
            if !didPointSnap {
                let parWins: Bool
                switch (bestParallel, bestPerpendicular) {
                case let (p?, q?): parWins = p.dev <= q.dev
                case (_?, nil): parWins = true
                default: parWins = false
                }
                if parWins, let par = bestParallel {
                    let nref = simd_normalize(par.b - par.a)
                    let signedLen = simd_dot(dir, nref) >= 0 ? length : -length
                    snapped = anchor + nref * signedLen
                } else if let perp = bestPerpendicular {
                    let nref = simd_normalize(perp.b - perp.a)
                    let perpDir = SIMD2(-nref.y, nref.x)
                    let signedLen = simd_dot(dir, perpDir) >= 0 ? length : -length
                    snapped = anchor + perpDir * signedLen
                }
            }
        }

        // 5. Equal length vs existing lines (constraint + marker; never snaps).
        if settings.equal, length > lengthEpsilon {
            var best: (id: UUID, relError: Double)?
            for entity in existing {
                guard case let .line(id, la, lb) = entity else { continue }
                let refLen = simd_length(lb - la)
                guard refLen > lengthEpsilon else { continue }
                let relError = abs(refLen - length) / refLen
                if relError <= equalLengthRelativeTolerance,
                   abs(refLen - length) <= equalLengthAbsoluteTolerance,
                   best == nil || relError < best!.relError {
                    best = (id, relError)
                }
            }
            if let best {
                constraints.append(Inferred(
                    kind: .equalLength, selfRole: .whole,
                    targetEntityID: best.id, targetRole: .whole))
                guides.append(Guide(kind: .equalLength, a: current, b: current))
            }
        }

        // 6. Tangent (gated, best-effort, never the primary snap). Requires the
        // endpoint to sit on a circle's boundary AND the direction to be
        // near-tangent; otherwise skip rather than emit a wrong constraint.
        if settings.tangent, length > lengthEpsilon {
            let ndir = dir / length
            for entity in existing {
                guard case let .circle(id, center, radius) = entity, radius > lengthEpsilon
                else { continue }
                let toEnd = current - center
                let distToCenter = simd_length(toEnd)
                guard distToCenter > lengthEpsilon,
                      abs(distToCenter - radius) <= settings.pointTolerance else { continue }
                let radial = toEnd / distToCenter
                // Deviation from tangency: 0 when the line ⟂ the radius.
                let tangentDev = asin(min(1.0, abs(simd_dot(ndir, radial))))
                if tangentDev <= tolRad {
                    constraints.append(Inferred(
                        kind: .tangent, selfRole: .whole,
                        targetEntityID: id, targetRole: .whole))
                    guides.append(Guide(kind: .tangent, a: current, b: current))
                    break
                }
            }
        }

        return Result(snappedPoint: snapped, guides: guides, constraints: constraints)
    }

    // MARK: - Role-addressable snap candidates

    /// Nearest existing entity point (within `tolerance`) that has a well-defined
    /// `PointRole` — line endpoints and shape centers. Rect corners / polygon
    /// vertices / arc rim points / line midpoints are intentionally excluded
    /// because they have no role to attach a coincident constraint to.
    static func nearestRoleCandidate(
        to p: SIMD2<Double>,
        in existing: [SketchEntity],
        tolerance: Double
    ) -> (point: SIMD2<Double>, entityID: UUID, role: PointRole)? {
        var best: (point: SIMD2<Double>, entityID: UUID, role: PointRole)?
        var bestDistance = Double.infinity
        for entity in existing {
            for candidate in roleCandidates(of: entity) {
                let d = simd_length(candidate.point - p)
                if d <= tolerance, d < bestDistance {
                    bestDistance = d
                    best = candidate
                }
            }
        }
        return best
    }

    private static func roleCandidates(
        of entity: SketchEntity
    ) -> [(point: SIMD2<Double>, entityID: UUID, role: PointRole)] {
        switch entity {
        case let .line(id, a, b):
            return [(a, id, .endpointA), (b, id, .endpointB)]
        case let .circle(id, center, _):
            return [(center, id, .center)]
        case let .arc(id, center, _, _, _):
            return [(center, id, .center)]
        case let .ellipse(id, center, _, _, _):
            return [(center, id, .center)]
        case let .polygon(id, center, _, _, _):
            return [(center, id, .center)]
        case let .spline(id, points, closed):
            // Auto-constrain can weld an open spline's ends to nearby geometry,
            // matching the endpoints `mutableSlots` exposes.
            guard !closed, let a = points.first, let b = points.last,
                  points.count >= 2 else { return [] }
            return [(a, id, .endpointA), (b, id, .endpointB)]
        case .rect:
            return []
        }
    }
}
