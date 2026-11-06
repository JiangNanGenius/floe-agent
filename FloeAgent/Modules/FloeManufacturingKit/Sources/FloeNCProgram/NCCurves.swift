// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct NCPathSample: Encodable, Equatable, Sendable {
    public let parameter: Double
    public let point: NCVector
    public let position: NCPosition
}
public struct NCSampledPath: Encodable, Equatable, Sendable {
    public let motionIndex: Int
    public let line: Int
    public let rapid: Bool
    public let samples: [NCPathSample]
}

public enum NCGeometry {
    public static func uniformKnots(controlCount: Int, order: Int) -> [Double] {
        guard order >= 2, controlCount >= order else { return [] }
        let interiors = controlCount-order
        return Array(repeating:0,count:order) + (interiors > 0 ? (1...interiors).map { Double($0)/Double(interiors+1) } : []) + Array(repeating:1,count:order)
    }

    public static func sample(_ program: NCProgram, cancellation: NCCancellation? = nil) throws -> [NCSampledPath] {
        var remaining = program.configuration.maximumPoints
        return try program.motions.enumerated().map { index,motion in
            try cancellation?.check()
            var pairs = [(Double,NCVector)]()
            func append(_ t: Double, _ point: NCVector) throws {
                guard point.finite else { throw NCError("Non-finite curve evaluation",line:motion.line) }
                guard remaining > 0 else { throw NCError("Preview point budget exceeded; raise tolerance or budget",line:motion.line) }
                remaining -= 1; pairs.append((t,point))
            }
            let start = motion.start.displayPoint, end = motion.end.displayPoint
            switch motion.curve {
            case .unlocated: break // No fabricated initial traverse from machine home.
            case .line:
                try append(0,start); try append(1,end)
            case .arc(let center,let sweep,let plane):
                let axes = plane.axes, u = axes[0], v = axes[1], w = axes[2]
                let radius = hypot(start[u]-center[u],start[v]-center[v])
                let theta = atan2(start[v]-center[v],start[u]-center[u])
                let tolerance = program.configuration.chordToleranceMM
                let maxAngle = min(Double.pi/24,2*acos(max(-1,min(1,1-tolerance/radius))))
                guard maxAngle.isFinite, maxAngle > 0 else { throw NCError("Curve tolerance below floating point resolution",line:motion.line) }
                let required = ceil(abs(sweep)/maxAngle)
                guard required.isFinite, required < Double(remaining) else { throw NCError("Arc subdivision exceeds point budget",line:motion.line) }
                let count = max(1,Int(required))
                for i in 0...count {
                    try cancellation?.check()
                    let t = Double(i)/Double(count)
                    var point = center
                    point[u] += radius*cos(theta+sweep*t); point[v] += radius*sin(theta+sweep*t)
                    point[w] = start[w]+(end[w]-start[w])*t
                    // Accepted radius discrepancy is bounded separately by arcRadiusToleranceMM.
                    try append(t,i == 0 ? start : i == count ? end : point)
                }
            case .bezier(let controls):
                let h = controls.map { SIMD4<Double>($0.x,$0.y,$0.z,1) }
                try append(0,start)
                try flatten(h,from:0,to:1,tolerance:program.configuration.chordToleranceMM,depth:0,cancellation:cancellation,append:append)
            case .nurbs(let controls,let weights,let knots,let order):
                let spans = try bezierSpans(controls:controls,weights:weights,knots:knots,order:order,cancellation:cancellation)
                try append(0,start)
                for span in spans {
                    try flatten(span.controls,from:span.start,to:span.end,tolerance:program.configuration.chordToleranceMM,depth:0,cancellation:cancellation,append:append)
                }
            }
            let samples = pairs.map { t,point in
                var position = NCPosition()
                for axis in 0..<6 {
                    if let a = motion.start[axis],let b = motion.end[axis] {
                        position[axis] = axis < 3 ? point[axis] : a+(b-a)*t
                    }
                }
                return NCPathSample(parameter:t,point:point,position:position)
            }
            return NCSampledPath(motionIndex:index,line:motion.line,rapid:motion.rapid,samples:samples)
        }
    }

    private struct Span { let controls: [SIMD4<Double>]; let start,end: Double }
    private static func euclidean(_ h: SIMD4<Double>) -> NCVector { .init(h.x/h.w,h.y/h.w,h.z/h.w) }
    private static func distance(_ p: NCVector, toSegment a: NCVector, _ b: NCVector) -> Double {
        let d = b-a, q = p-a, squared = d.x*d.x+d.y*d.y+d.z*d.z
        let t = squared > 1e-28 ? max(0,min(1,(q.x*d.x+q.y*d.y+q.z*d.z)/squared)) : 0
        return (p-(a+d*t)).length
    }
    /// Positive rational weights keep the curve inside its Euclidean control hull.
    /// Subdivision stops only when that hull lies inside the chord's tolerance capsule.
    private static func flatten(_ controls: [SIMD4<Double>], from: Double, to: Double, tolerance: Double, depth: Int,
                                cancellation: NCCancellation?, append: (Double,NCVector) throws -> Void) throws {
        try cancellation?.check()
        let points = controls.map(euclidean), a = points[0], b = points[points.count-1]
        if points.allSatisfy({ distance($0,toSegment:a,b) <= tolerance }) { try append(to,b); return }
        guard depth < 32 else { throw NCError("Spline subdivision depth exceeded; no partial preview returned") }
        var rows = controls, left = [controls[0]], right = [controls[controls.count-1]]
        while rows.count > 1 {
            rows = (0..<(rows.count-1)).map { (rows[$0]+rows[$0+1])*0.5 }
            left.append(rows[0]); right.append(rows[rows.count-1])
        }
        let mid = (from+to)/2
        try flatten(left,from:from,to:mid,tolerance:tolerance,depth:depth+1,cancellation:cancellation,append:append)
        try flatten(Array(right.reversed()),from:mid,to:to,tolerance:tolerance,depth:depth+1,cancellation:cancellation,append:append)
    }
    /// Knot insertion in homogeneous coordinates; extracts exact rational Bezier spans.
    private static func bezierSpans(controls: [NCVector], weights: [Double], knots: [Double], order: Int,
                                    cancellation: NCCancellation?) throws -> [Span] {
        guard controls.count == weights.count, controls.count >= order, (2...6).contains(order),
              knots.count == controls.count+order,
              controls.allSatisfy(\.finite), weights.allSatisfy({ $0.isFinite && $0 >= 1e-9 && $0 <= 1e9 }),
              knots.allSatisfy(\.isFinite), zip(knots,knots.dropFirst()).allSatisfy({ $0 <= $1 }),
              knots.prefix(order).allSatisfy({ $0 == 0 }),knots.suffix(order).allSatisfy({ $0 == 1 })
        else { throw NCError("Invalid clamped NURBS geometry") }
        let degree = order-1
        var h = zip(controls,weights).map { p,w in SIMD4<Double>(p.x*w,p.y*w,p.z*w,w) }, u = knots
        let internalKnots = Array(Set(knots.filter { $0 > 0 && $0 < 1 })).sorted()
        for knot in internalKnots {
            try cancellation?.check()
            var multiplicity = u.filter { $0 == knot }.count
            guard multiplicity <= degree else { throw NCError("Discontinuous NURBS knot multiplicity is unsupported") }
            while multiplicity < degree {
                let n = h.count-1
                guard let k = (degree...n).last(where:{ u[$0] <= knot && knot < u[$0+1] }) else { throw NCError("Invalid knot span") }
                var q = Array(repeating:SIMD4<Double>(repeating:0),count:h.count+1)
                for i in 0...(k-degree) { q[i] = h[i] }
                for i in (k-multiplicity+1)...(n+1) { q[i] = h[i-1] }
                for i in (k-degree+1)...(k-multiplicity) {
                    let alpha = (knot-u[i])/(u[i+degree]-u[i])
                    q[i] = h[i-1]*(1-alpha)+h[i]*alpha
                }
                h = q; u.insert(knot,at:k+1); multiplicity += 1
            }
        }
        let breaks = [0.0]+internalKnots+[1.0]
        guard h.count == (breaks.count-1)*degree+1 else { throw NCError("NURBS span extraction failed") }
        return (0..<(breaks.count-1)).map { i in
            Span(controls:Array(h[(i*degree)...(i*degree+degree)]),start:breaks[i],end:breaks[i+1])
        }
    }
}
