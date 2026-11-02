// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd
import OCCTShim

nonisolated struct SketchCurveIntersection: Equatable, Sendable {
    var point: SIMD2<Double>
    /// Exact target-domain parameter returned by the same native intersection,
    /// including an extrapolated B-spline domain when extending.
    var targetParameter: Double
}

nonisolated extension OCCTKernel {
    private static func curveFailure(_ fallback: String, _ message: String,
                                     status: OCCTOpStatus) -> SketchCurveEditFailure {
        let code: String
        switch status.code.rawValue {
        case 6: code = "curve_offset_cusp"
        case 7: code = "curve_offset_self_intersection"
        case 8: code = "curve_offset_collapse"
        default: code = fallback
        }
        return SketchCurveEditFailure(code: code, message: message)
    }

    private static func doubles(_ data: Data, count: Int, code: String) throws -> [Double] {
        guard data.count == count * MemoryLayout<Double>.size else {
            throw SketchCurveEditFailure(code: code, message: "The native curve result is invalid.")
        }
        let values: [Double] = data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 1e12 }) else {
            throw SketchCurveEditFailure(code: code, message: "The native curve result is outside the supported range.")
        }
        return values
    }

    static func sketchCurveIntersections(_ target: SketchCurveDefinition,
                                         boundary: SketchCurveDefinition,
                                         extensionDirection: Int) throws -> [SketchCurveIntersection] {
        try target.validate(); try boundary.validate()
        guard (-1...1).contains(extensionDirection) else {
            throw SketchCurveEditFailure(code: "invalid_curve_extension", message: "The extension direction is invalid.")
        }
        let status = OCCTOpStatus()
        guard let data = OCCTBridge.sketchCurveIntersections(
            target: target.nativeRecord, boundary: boundary.nativeRecord,
            extensionDirection: extensionDirection, tolerance: SketchCurveDefinition.epsilon, status: status) else {
            throw curveFailure("curve_intersection_refused",
                "The selected curves do not have an unambiguous intersection.", status: status)
        }
        guard data.count.isMultiple(of: 3 * MemoryLayout<Double>.size),
              data.count <= 1024 * 3 * MemoryLayout<Double>.size else {
            throw SketchCurveEditFailure(code: "invalid_curve_intersection", message: "The curve intersection result is invalid.")
        }
        let values: [Double] = data.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
        guard values.allSatisfy({ $0.isFinite && abs($0) <= 1e12 }) else {
            throw SketchCurveEditFailure(code: "invalid_curve_intersection", message: "The curve intersection result is outside the supported range.")
        }
        return stride(from: 0, to: values.count, by: 3).map {
            SketchCurveIntersection(point: SIMD2(values[$0], values[$0 + 1]), targetParameter: values[$0 + 2])
        }
    }

    static func sketchCurvePoints(_ definition: SketchCurveDefinition,
                                  parameters: [Double]) throws -> [SIMD2<Double>] {
        try definition.validate()
        guard !parameters.isEmpty, parameters.count <= 4096,
              parameters.allSatisfy({ $0.isFinite && abs($0) <= 1e12 }) else {
            throw SketchCurveEditFailure(code: "invalid_curve_parameter", message: "The curve parameter is invalid.")
        }
        let status = OCCTOpStatus()
        let packed = parameters.withUnsafeBytes { Data($0) }
        guard let data = OCCTBridge.sketchCurvePoints(
            definition: definition.nativeRecord, parameters: packed,
            tolerance: SketchCurveDefinition.epsilon, status: status) else {
            throw curveFailure("curve_evaluation_refused", "The exact curve could not be evaluated.", status: status)
        }
        let values = try doubles(data, count: parameters.count * 2, code: "invalid_curve_evaluation")
        return stride(from: 0, to: values.count, by: 2).map { SIMD2(values[$0], values[$0 + 1]) }
    }

    static func sketchCurveParameter(of point: SIMD2<Double>,
                                     on definition: SketchCurveDefinition,
                                     extended: Bool) throws -> Double {
        try definition.validate()
        guard point.x.isFinite, point.y.isFinite, abs(point.x) <= 1e12, abs(point.y) <= 1e12 else {
            throw SketchCurveEditFailure(code: "invalid_curve_pick", message: "The curve pick is invalid.")
        }
        let status = OCCTOpStatus()
        let packed = [point.x, point.y].withUnsafeBytes { Data($0) }
        guard let number = OCCTBridge.sketchCurveParameter(
            point: packed, definition: definition.nativeRecord, extended: extended,
            tolerance: SketchCurveDefinition.epsilon, status: status) else {
            throw curveFailure("curve_projection_refused", "The point could not be projected onto the exact curve.", status: status)
        }
        let value = number.doubleValue
        guard value.isFinite, abs(value) <= 1e12 else {
            throw SketchCurveEditFailure(code: "invalid_curve_parameter", message: "The projected curve parameter is invalid.")
        }
        return value
    }

    /// Returns actual native length and maximum normal-distance/tangent residuals.
    /// No result is admitted when a cusp, collapse or self-intersection is found.
    @discardableResult
    static func validateSketchNormalOffset(_ definition: SketchCurveDefinition) throws -> [Double] {
        try definition.validate()
        guard definition.isDerivedNormalOffset else {
            throw SketchCurveEditFailure(code: "invalid_curve_offset", message: "The definition is not an exact normal offset.")
        }
        let status = OCCTOpStatus()
        guard let data = OCCTBridge.validateSketchNormalOffset(
            definition.nativeRecord, tolerance: SketchCurveDefinition.epsilon, status: status) else {
            let message: String
            switch status.code.rawValue {
            case 6: message = "The offset forms a cusp. Reduce the distance or change the source curve."
            case 7: message = "The offset intersects itself. Reduce the distance or change the source curve."
            case 8: message = "The offset collapses the curve. Reduce the inward distance."
            default: message = "The exact normal offset could not be built. The original is unchanged."
            }
            throw curveFailure("curve_offset_refused", message, status: status)
        }
        return try doubles(data, count: 3, code: "invalid_curve_offset_diagnostics")
    }
}
