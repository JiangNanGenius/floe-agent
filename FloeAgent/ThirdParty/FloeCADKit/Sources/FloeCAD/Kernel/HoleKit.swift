//
//  HoleKit.swift
//  FloeCAD — M12 mechanical holes
//
//  The bounded adapter between a typed `HoleSpec` and the ALREADY-QUALIFIED
//  exact OCCT path: a closed (r, t) polygon revolved 360° by the existing
//  `OCCTKernel.revolveSolid`, then subtracted with the existing exact boolean.
//  No new kernel, parser, mesh fallback or synthetic sketch entities.
//
//  Axial convention (shared with the qualified kernel probe):
//  - `t = 0` is the placement circle's plane;
//  - positive t is INTO the chosen direction (`+plane.normal`, or
//    `-plane.normal` when `reversed`), so the lead-in at `t = -leadIn` is
//    OUTSIDE the entrance and can never over-cut the opening;
//  - through reach projects the target's WORLD AABB corners onto that axis and
//    pads both ends — never a fixed arbitrary depth;
//  - dimensions stay world millimetres even when the target is uniformly
//    scaled; the placement circle supplies the pilot radius.
//

import Foundation
import simd

nonisolated enum HoleKit {

    /// The lead-in outside the entrance face. Kept small and explicit; it is
    /// not the through-hole extent (that comes from the projected target).
    static let leadIn: Double = 1.0

    /// One closed axial cutter outline plus the semantic role of each boundary
    /// segment, in wire order. `nil` roles are the axis segment and the caps
    /// outside the material.
    struct CutterProfile {
        var points: [SIMD2<Double>]
        var roles: [HoleFaceRole?]
    }

    // MARK: - Validation

    /// Shared structural validation. `pilotDiameter` is nil for a write-time
    /// check where the placement sketch is not being resolved (non-finite and
    /// positive-value checks still run); evaluation/creation pass the actual
    /// pilot diameter so `counterboreDiameter`/`countersinkDiameter` must
    /// genuinely exceed it.
    static func validationIssue(_ spec: HoleSpec, pilotDiameter: Double?) -> String? {
        guard spec.version == HoleSpec.supportedVersion else {
            return "hole definition version \(spec.version) is not supported by this build (supports \(HoleSpec.supportedVersion))."
        }
        func positive(_ expr: Expr?, _ name: String) -> String? {
            guard let expr else { return nil }
            guard expr.value.isFinite, expr.value > 0 else {
                return "\(name) must be a positive finite millimetre value."
            }
            return nil
        }
        if let pilotDiameter {
            guard pilotDiameter.isFinite, pilotDiameter > 0 else {
                return "the placement circle must have a positive finite diameter."
            }
        }
        if let issue = positive(spec.depth, "depth") { return issue }
        if let issue = positive(spec.counterboreDiameter, "counterboreDiameter") { return issue }
        if let issue = positive(spec.counterboreDepth, "counterboreDepth") { return issue }
        if let issue = positive(spec.countersinkDiameter, "countersinkDiameter") { return issue }
        if let angle = spec.countersinkAngle {
            guard angle.value.isFinite, (30.0...170.0).contains(angle.value) else {
                return "countersinkAngle must be an included angle between 30 and 170 degrees."
            }
        }
        switch spec.kind {
        case .throughAll:
            break
        case .blind:
            guard spec.depth != nil else { return "a blind hole needs depth." }
        case .counterbore:
            guard let diameter = spec.counterboreDiameter else {
                return "a counterbore needs counterboreDiameter."
            }
            guard spec.counterboreDepth != nil else {
                return "a counterbore needs counterboreDepth."
            }
            if let pilotDiameter, diameter.value <= pilotDiameter {
                return "counterboreDiameter must exceed the pilot diameter."
            }
        case .countersink:
            guard let diameter = spec.countersinkDiameter else {
                return "a countersink needs countersinkDiameter."
            }
            guard spec.countersinkAngle != nil else {
                return "a countersink needs countersinkAngle."
            }
            if let pilotDiameter, diameter.value <= pilotDiameter {
                return "countersinkDiameter must exceed the pilot diameter."
            }
        }
        return nil
    }

    // MARK: - Placement circle

    /// The exact circle a `ProfileRef` names, as plane-local centre + radius.
    /// Resolution matches the evaluator: recorded entity ids first (with the
    /// seed disambiguating duplicate regions), then the innermost region at the
    /// seed. Non-circular profiles return nil — a hole has no guessed outline.
    static func circle(in sketch: Sketch, matching ref: ProfileRef) -> (center: SIMD2<Double>, radius: Double)? {
        let detected = ProfileDetector.detectProfiles(in: sketch)
        var region: Profile?
        let wanted = Set(ref.entityIDs)
        if !wanted.isEmpty {
            let exact = detected.filter { $0.sourceEntityIDs == wanted }
            let supersets = detected.filter { wanted.isSubset(of: $0.sourceEntityIDs) }
            if let seed = ref.seedPoint {
                region = exact.first { $0.contains(seed) } ?? supersets.first { $0.contains(seed) }
            }
            region = region ?? exact.first ?? supersets.first
        }
        if region == nil, let seed = ref.seedPoint {
            region = ProfileDetector.profiles(at: seed, in: sketch).first
        }
        guard let region, case let .circle(center, radius) = region.kind,
              radius.isFinite, radius > 0 else { return nil }
        return (center, radius)
    }

    // MARK: - Through extent

    /// Project every WORLD AABB corner onto the axial direction, relative to
    /// the entrance point. The result is the material span along the hole axis
    /// for through holes; a degenerate/absent box is refused rather than
    /// replaced by a made-up constant.
    static func projectedRange(minimum: SIMD3<Double>, maximum: SIMD3<Double>,
                               entry: SIMD3<Double>, inward: SIMD3<Double>) -> ClosedRange<Double>? {
        guard minimum.x.isFinite, minimum.y.isFinite, minimum.z.isFinite,
              maximum.x.isFinite, maximum.y.isFinite, maximum.z.isFinite,
              simd_length(inward) > 1e-9 else { return nil }
        var values: [Double] = []
        values.reserveCapacity(8)
        for x in [minimum.x, maximum.x] {
            for y in [minimum.y, maximum.y] {
                for z in [minimum.z, maximum.z] {
                    values.append(simd_dot(SIMD3(x, y, z) - entry, inward))
                }
            }
        }
        guard let lower = values.min(), let upper = values.max(),
              lower.isFinite, upper.isFinite, upper - lower > 1e-9 else { return nil }
        return lower...upper
    }

    // MARK: - Axial cutter

    /// Build the closed CCW (r, t) polygon for one typed hole. Returns nil when
    /// a required dimension is absent or the outline is degenerate, so callers
    /// report the stored spec honestly instead of constructing a different
    /// shape.
    static func cutterProfile(pilotRadius: Double, spec: HoleSpec,
                              worldRange: ClosedRange<Double>) -> CutterProfile? {
        guard pilotRadius.isFinite, pilotRadius > 0,
              worldRange.lowerBound.isFinite, worldRange.upperBound.isFinite,
              worldRange.lowerBound < worldRange.upperBound else { return nil }
        let r = pilotRadius
        let lead = leadIn
        let end = worldRange.upperBound + lead
        let points: [SIMD2<Double>]
        let roles: [HoleFaceRole?]
        switch spec.kind {
        case .throughAll:
            let start = worldRange.lowerBound - lead
            points = [SIMD2(0, start), SIMD2(r, start), SIMD2(r, end), SIMD2(0, end)]
            roles = [nil, .pilotWall, nil, nil]
        case .blind:
            guard let depth = spec.depth?.value, depth.isFinite, depth > 0 else { return nil }
            points = [SIMD2(0, -lead), SIMD2(r, -lead), SIMD2(r, depth), SIMD2(0, depth)]
            roles = [nil, .pilotWall, .bottom, nil]
        case .counterbore:
            guard let diameter = spec.counterboreDiameter?.value,
                  let depth = spec.counterboreDepth?.value,
                  diameter.isFinite, depth.isFinite, diameter > 2 * r, depth > 0
            else { return nil }
            let opening = diameter / 2
            points = [SIMD2(0, -lead), SIMD2(opening, -lead), SIMD2(opening, depth),
                      SIMD2(r, depth), SIMD2(r, end), SIMD2(0, end)]
            roles = [nil, .recessWall, .shoulder, .pilotWall, nil, nil]
        case .countersink:
            guard let diameter = spec.countersinkDiameter?.value,
                  let included = spec.countersinkAngle?.value,
                  diameter.isFinite, included.isFinite, diameter > 2 * r,
                  (30.0...170.0).contains(included)
            else { return nil }
            let opening = diameter / 2
            let coneDepth = (opening - r) / tan(included * .pi / 360)
            guard coneDepth.isFinite, coneDepth > 0 else { return nil }
            points = [SIMD2(0, -lead), SIMD2(opening, -lead), SIMD2(opening, 0),
                      SIMD2(r, coneDepth), SIMD2(r, end), SIMD2(0, end)]
            roles = [nil, .recessWall, .cone, .pilotWall, nil, nil]
        }
        guard Profile.signedArea(points) > 0 else { return nil }
        return CutterProfile(points: points, roles: roles)
    }
}
