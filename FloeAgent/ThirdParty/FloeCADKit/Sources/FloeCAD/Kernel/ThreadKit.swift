import Foundation
import simd

/// Basic ISO metric profile in the AXIAL plane. The kernel entry keeps that
/// plane inclined to the helix tangent; the ordinary normal-section sweep
/// deliberately retains its previous behaviour.
nonisolated enum ThreadKit {
    static func axialCutter(_ spec: ThreadSpec, overlap: Double) -> [SIMD2<Double>] {
        let p = spec.pitch.value, lo = spec.minorRadius, hi = spec.majorRadius
        let slope = sqrt(3.0)
        if spec.side == .external {
            // A groove: root flat P/4; opening at major diameter 7P/8.
            return [SIMD2(lo, -p / 8), SIMD2(hi + overlap, -7 * p / 16 - overlap / slope),
                    SIMD2(hi + overlap, 7 * p / 16 + overlap / slope), SIMD2(lo, p / 8)]
        }
        // Female groove: root flat P/8 at major diameter; the remaining
        // female crest at minor diameter has axial width P/4.
        return [SIMD2(lo - overlap, -3 * p / 8 - overlap / slope), SIMD2(hi, -p / 16),
                SIMD2(hi, p / 16), SIMD2(lo - overlap, 3 * p / 8 + overlap / slope)]
    }

    struct Result {
        var shape: BRepHandle
        var names: [Int: ElementName]
    }

    static func apply(_ spec: ThreadSpec, cylinder: OCCTKernel.ThreadCylinder,
                      target: BRepHandle, targetNames: [Int: ElementName],
                      operation: FeatureID,
                      recordStep: ((String, BRepHandle) -> Void)? = nil) throws -> Result {
        try spec.validate()
        let p = spec.pitch.value, length = spec.effectiveLength.value
        guard cylinder.isInternal == (spec.side == .internal) else {
            throw CADThreadError.invalid("Choose an outside cylinder for an external thread, or a bore for an internal thread.")
        }
        let margin = spec.ends == .onePitchSetback ? p : 0
        guard length + 2 * margin <= cylinder.upper - cylinder.lower + 1e-7 else {
            throw CADThreadError.invalid("The full thread and its end margins must fit on this cylindrical face.")
        }
        if spec.side == .external {
            guard spec.majorRadius <= cylinder.radius + 1e-7 else {
                throw CADThreadError.invalid("This stock is too small for the selected external thread.")
            }
        } else {
            guard spec.minorRadius >= cylinder.radius - 1e-7 else {
                throw CADThreadError.invalid("This bore is too large for the selected internal thread.")
            }
        }
        if spec.representation == .schematic { return Result(shape: target, names: targetNames) }

        let start = cylinder.origin + cylinder.axis * (cylinder.lower + margin)
        func circle(_ radius: Double) -> Profile {
            let points = (0..<48).map { index -> SIMD2<Double> in
                let angle = 2 * Double.pi * Double(index) / 48
                return SIMD2(radius * cos(angle), radius * sin(angle))
            }
            return Profile(loop: points, kind: .circle(center: .zero, radius: radius), sourceEntityIDs: [])
        }
        func cylinderTool(_ radius: Double, bore: Double? = nil, seamAngle: Double = 0) throws -> BRepHandle {
            let x = cylinder.radial * cos(seamAngle)
                + simd_cross(cylinder.axis, cylinder.radial) * sin(seamAngle)
            let y = simd_cross(cylinder.axis, x)
            guard let result = OCCTKernel.extrudeSolid(outer: circle(radius),
                holes: bore.map { [circle($0)] } ?? [], extras: [], zMin: 0, zMax: length,
                origin: start, xAxis: x, yAxis: y, normal: cylinder.axis) else {
                throw CADThreadError.invalid("The thread boundary could not be built.")
            }
            return result
        }
        func healthy(_ shape: BRepHandle) throws {
            let h = OCCTKernel.healthReport(for: shape)
            guard h.error == nil, h.isValid, h.counts["solids"] == 1, h.openFreeWires == 0 else {
                throw CADThreadError.invalid("The thread did not produce one valid closed solid.")
            }
        }
        func boolean(_ a: BRepHandle, _ b: BRepHandle, _ op: BooleanKind) throws
            -> (BRepHandle, ShapeAncestry) {
            guard let target = OCCTKernel.threadOrientedSolid(a),
                  let tool = OCCTKernel.threadOrientedSolid(b) else {
                throw CADThreadError.invalid("The thread operands must be closed, oriented solids.")
            }
            switch OCCTKernel.booleanResultWithAncestry(target, tool, op: OCCTKernel.booleanOp(op)) {
            case let .success((outcome, ancestry)):
                guard outcome.solidCount == 1 else { throw CADThreadError.invalid("The thread split the solid.") }
                try healthy(outcome.handle)
                return (outcome.handle, ancestry)
            case let .failure(error): throw CADThreadError.invalid(error.message)
            }
        }
        var work = target, names = targetNames
        recordStep?("stock", work)
        func subtract(_ tool: BRepHandle) throws {
            let (next, ancestry) = try boolean(work, tool, .subtract)
            names = ElementNaming.composeNames(operation: operation, ancestry: ancestry,
                inputNames: [names, [:]])
            work = next
        }
        let epsilon = max(1e-4, p * 0.02)
        // Standard dimensions may change on the same feature only when the
        // frozen stock can actually supply them. Never add fictitious metal.
        if spec.side == .external, cylinder.radius > spec.majorRadius + 1e-7 {
            try subtract(cylinderTool(cylinder.radius + epsilon, bore: spec.majorRadius))
        }
        // Cutting a helical groove against a newly bored cylinder whose seam
        // begins at the axial profile can silently return unchanged stock in
        // OCCT. Build the bore and groove as ONE cutting solid instead. Only
        // the circular bore's parameter seam moves; dimensions, physical
        // thread phase, the frozen stock and its face identities do not.
        let boreTool: BRepHandle?
        var grooveBaseline = abs(OCCTKernel.volume(work))
        if spec.side == .internal {
            let bore = try cylinderTool(spec.minorRadius, seamAngle: spec.phaseRadians + .pi / 2)
            boreTool = bore
            if spec.minorRadius > cylinder.radius + 1e-7 {
                let (prepared, _) = try boolean(work, bore, .subtract)
                grooveBaseline = abs(OCCTKernel.volume(prepared))
                recordStep?("prepared-stock", prepared)
            } else { recordStep?("prepared-stock", work) }
        } else {
            boreTool = nil
            recordStep?("prepared-stock", work)
        }
        let positive = spec.hand == .right
        let lead = p
        let z = positive ? -lead : length + lead
        let helixOrigin = start + cylinder.axis * z
        let helix = HelixSpec(axisPoint: helixOrigin, axisDirection: cylinder.axis,
            referenceDirection: cylinder.radial, radius: spec.minorRadius,
            pitch: positive ? p : -p, turns: (length + 2 * lead) / p,
            startAngle: spec.phaseRadians)
        let cross = simd_cross(cylinder.axis, cylinder.radial)
        let radial = cylinder.radial * cos(spec.phaseRadians) + cross * sin(spec.phaseRadians)
        let section = axialCutter(spec, overlap: epsilon).map {
            SIMD2($0.x - spec.minorRadius, $0.y)
        }
        let plane = SketchPlane(origin: helixOrigin + radial * spec.minorRadius,
                                xAxis: radial, yAxis: cylinder.axis)
        guard let swept = OCCTKernel.threadSweepSolid(
            outer: Profile(loop: section, kind: .polygonal, sourceEntityIDs: []),
            plane: plane, helix: helix) else {
            throw CADThreadError.invalid("The axial thread profile could not be swept.")
        }
        try healthy(swept)
        recordStep?("swept-cutter", swept)
        let envelope = try cylinderTool(max(cylinder.radius, spec.majorRadius) + epsilon * 2)
        let (trimmed, _) = try boolean(swept, envelope, .intersect)
        recordStep?("trimmed-cutter", trimmed)
        let before = abs(OCCTKernel.volume(target))
        if let boreTool {
            let (combined, _) = try boolean(boreTool, trimmed, .union)
            recordStep?("combined-cutter", combined)
            try subtract(combined)
        } else { try subtract(trimmed) }
        recordStep?("result", work)
        let after = abs(OCCTKernel.volume(work))
        guard before.isFinite, after.isFinite, before > after + max(1e-7, before * 1e-10), after > 0 else {
            throw CADThreadError.invalid("The thread removes no material from this stock.")
        }
        guard grooveBaseline > after + max(1e-7, grooveBaseline * 1e-10) else {
            throw CADThreadError.invalid("The thread groove could not be cut. The stock is unchanged.")
        }
        return Result(shape: work, names: names)
    }
}
