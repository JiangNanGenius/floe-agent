// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd
import OCCTShim

nonisolated extension OCCTKernel {
    static func sketchCurveIntersections(_ target: SketchCurveDefinition,
                                         boundary: SketchCurveDefinition,
                                         extendTarget: Bool) throws -> [SIMD2<Double>] {
        try target.validate(); try boundary.validate()
        let status = OCCTOpStatus()
        guard let data = OCCTBridge.sketchCurveIntersections(
            target: target.nativeRecord, boundary: boundary.nativeRecord,
            extendTarget: extendTarget, tolerance: SketchCurveDefinition.epsilon, status: status) else {
            throw SketchCurveEditFailure(code: "curve_intersection_refused",
                message: "The selected curves do not have an unambiguous intersection.")
        }
        guard data.count.isMultiple(of: 2 * MemoryLayout<Double>.size), data.count <= 1024 * 2 * MemoryLayout<Double>.size else {
            throw SketchCurveEditFailure(code: "invalid_curve_intersection", message: "The curve intersection result is invalid.")
        }
        let values: [Double] = data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 1e12 }) else {
            throw SketchCurveEditFailure(code: "invalid_curve_intersection", message: "The curve intersection result is outside the supported range.")
        }
        return stride(from: 0, to: values.count, by: 2).map { SIMD2(values[$0], values[$0 + 1]) }
    }
}
