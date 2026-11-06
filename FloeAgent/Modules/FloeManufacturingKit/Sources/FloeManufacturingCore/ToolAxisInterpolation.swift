// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Shortest great-circle interpolation of tip-to-spindle axes. Tool roll is
/// unspecified. Opposite axes do not define a unique route and must be split
/// with an explicit intermediate pose, rather than jumping at the midpoint.
public enum ToolAxisInterpolation {
    public static func interpolate(_ a:[Double],_ b:[Double],fraction:Double) throws -> [Double] {
        guard CAMCheck.point(a), CAMCheck.point(b), fraction.isFinite,
              abs(CAMCheck.norm(a)-1) <= 1e-5, abs(CAMCheck.norm(b)-1) <= 1e-5 else {
            throw ManufacturingError.invalid("tool-axis interpolation requires unit axes and a finite fraction")
        }
        let t = min(1,max(0,fraction))
        let dot = min(1,max(-1,zip(a,b).reduce(0) { $0+$1.0*$1.1 }))
        guard dot > -1+1e-8 else { throw ManufacturingError.invalid("opposite tool axes require an explicit intermediate pose") }
        if t == 0 { return a }; if t == 1 { return b }
        if dot > 1-1e-12 { return a }
        let angle = acos(dot), denominator = sin(angle)
        let wa = sin((1-t)*angle)/denominator, wb = sin(t*angle)/denominator
        let mixed = zip(a,b).map { $0*wa+$1*wb }
        let norm = CAMCheck.norm(mixed)
        guard norm > 0 && norm.isFinite else { throw ManufacturingError.invalid("undefined tool-axis interpolation") }
        return mixed.map { $0/norm }
    }
}
