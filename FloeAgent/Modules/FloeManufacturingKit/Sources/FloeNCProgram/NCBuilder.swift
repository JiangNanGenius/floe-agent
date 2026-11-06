// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Encodes connected neutral geometry with explicit process setup. No missing traverse
/// or tool change is invented. Nonuniform NURBS needs a different controller profile.
public enum NCBuilder {
    public static func program(start: NCVector, curves: [NCCurve], ends: [NCVector],
                               feedMMPerMinute: Double, spindleRPM: Double = 0,
                               configuration: NCConfiguration = .init()) throws -> NCProgram {
        guard start.finite,curves.count == ends.count,!curves.isEmpty,
              curves.count <= configuration.maximumBlocks,feedMMPerMinute.isFinite,feedMMPerMinute > 0,
              spindleRPM.isFinite,spindleRPM >= 0 else { throw NCError("Invalid neutral path or process setup") }
        func n(_ x:Double) -> String { NCFormat.number(x) }
        func xyz(_ p:NCVector) -> String { "X\(n(p.x)) Y\(n(p.y)) Z\(n(p.z))" }
        var source="G21 G90 G91.1 G8 G17 G94\nG0 \(xyz(start))\nF\(n(feedMMPerMinute))\nS\(n(spindleRPM)) M3\n",current=start
        for (curve,end) in zip(curves,ends) {
            guard end.finite else { throw NCError("Non-finite path endpoint") }
            switch curve {
            case .unlocated: throw NCError("Cannot encode an unlocated neutral path")
            case .line: source += "G1 \(xyz(end))\n"
            case .arc(let center,let sweep,let plane):
                guard center.finite,sweep.isFinite,abs(sweep) > 0,abs(sweep) <= 20000 * .pi else { throw NCError("Invalid analytic arc or turn budget") }
                let axes=plane.axes,u=axes[0],v=axes[1]
                let names=["I","J","K"]
                let full = current[u] == end[u] && current[v] == end[v]
                let startAngle=atan2(current[v]-center[v],current[u]-center[u])
                let endAngle=atan2(end[v]-center[v],end[u]-center[u])
                var base=endAngle-startAngle
                if full { base = sweep > 0 ? 2 * .pi : -2 * .pi }
                else if sweep > 0 { while base <= 0 { base += 2 * .pi } }
                else { while base >= 0 { base -= 2 * .pi } }
                let extra=(abs(sweep)-abs(base))/(2 * .pi)
                guard extra >= -1e-10,abs(extra-extra.rounded()) < 1e-10 else { throw NCError("Arc sweep does not match its endpoint and direction") }
                let turns=1+Int(extra.rounded())
                source += "G\(n(plane.code)) G\(sweep > 0 ? 3 : 2) \(xyz(end)) \(names[u])\(n(center[u]-current[u])) \(names[v])\(n(center[v]-current[v])) P\(turns)\n"
            case .bezier(let controls):
                guard (3...4).contains(controls.count),controls.allSatisfy(\.finite),
                      controls.first == current,controls.last == end,
                      controls.allSatisfy({ $0.z == current.z }) else { throw NCError("Spline must be a connected XY quadratic/cubic at fixed Z") }
                let first=controls[1]-current
                if controls.count == 4 {
                    let last=controls[2]-end
                    source += "G17 G5 X\(n(end.x)) Y\(n(end.y)) I\(n(first.x)) J\(n(first.y)) P\(n(last.x)) Q\(n(last.y))\n"
                } else { source += "G17 G5.1 X\(n(end.x)) Y\(n(end.y)) I\(n(first.x)) J\(n(first.y))\n" }
            case .nurbs(let controls,let weights,let knots,let order):
                guard controls.count == weights.count,controls.count <= configuration.maximumControlPoints,
                      (3...6).contains(order),controls.count >= order,
                      controls.first == current,controls.last == end,controls.allSatisfy({ $0.finite && $0.z == current.z }),
                      weights.allSatisfy({ $0.isFinite && $0 >= 1e-9 && $0 <= 1e9 }),
                      knots == NCGeometry.uniformKnots(controlCount:controls.count,order:order) else { throw NCError("G5.2 export needs connected XY controls, positive weights and clamped uniform knots; no silent linearization") }
                source += "G17\nG5.2 P\(n(weights[0])) L\(order)\n"
                for i in 1..<controls.count { source += "X\(n(controls[i].x)) Y\(n(controls[i].y)) P\(n(weights[i]))\n" }
                source += "G5.3\n"
            }
            current=end
        }
        source += "M5 M9\nM2\n"
        var config=configuration; config.initialPosition = .init()
        return try NCCodec.decode(source,configuration:config)
    }
}

public enum NCSamples {
    /// Created through the neutral encoder, not stored as a canned encoded string.
    public static func smooth() throws -> NCProgram {
        let start=NCVector(12,0,0),helixEnd=NCVector(12,0,4),cubicEnd=NCVector(30,0,4),quadraticEnd=NCVector(44,0,4),end=NCVector(60,0,4)
        let controls=[quadraticEnd,NCVector(48,12,4),NCVector(52,-10,4),NCVector(56,10,4),end]
        return try NCBuilder.program(start:start,curves:[
            .arc(center:.init(0,0,0),sweepRadians:4 * .pi,plane:.xy),
            .bezier(controls:[helixEnd,.init(18,15,4),.init(24,-15,4),cubicEnd]),
            .bezier(controls:[cubicEnd,.init(37,12,4),quadraticEnd]),
            .nurbs(controls:controls,weights:[1,0.7,1.5,0.8,1],knots:NCGeometry.uniformKnots(controlCount:controls.count,order:3),order:3)
        ],ends:[helixEnd,cubicEnd,quadraticEnd,end],feedMMPerMinute:240,spindleRPM:1800)
    }
    public static let turning = """
    G21 G18 G90 G91.1 G7 G95
    T1 M6
    G0 X40 Y0 Z5 C0
    G96 D2500 S160 M3
    F0.2 M8
    G1 Z0
    G1 X20
    G2 X30 Z-5 I5 K0
    G1 Z-30
    M5 M9
    G94 G97 S0
    G0 X50 Z10
    C720
    M2
    """
}
