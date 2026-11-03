import Foundation
import simd
import OCCTShim

nonisolated extension OCCTKernel {
    private static func surfaceBasis(_ plane: SketchPlane) -> OCCTPlaneBasis {
        let n = simd_normalize(simd_cross(plane.xAxis,plane.yAxis))
        return OCCTPlaneBasis(originX:plane.origin.x,originY:plane.origin.y,originZ:plane.origin.z,
            xAxisX:plane.xAxis.x,xAxisY:plane.xAxis.y,xAxisZ:plane.xAxis.z,
            yAxisX:plane.yAxis.x,yAxisY:plane.yAxis.y,yAxisZ:plane.yAxis.z,
            normalX:n.x,normalY:n.y,normalZ:n.z)
    }
    static func loftSurface(_ definition: CADSurfaceDefinition, sketch: (SketchID) -> Sketch?) throws -> BRepHandle {
        let sections = try definition.resolvedSections(sketch: sketch)
        let status = OCCTOpStatus()
        guard let shape = OCCTBridge.surfaceLoft(curves:sections.map(\.curves),
            reversed:sections.map { $0.reversed.map { NSNumber(value:$0) } }, bases:sections.map { surfaceBasis($0.plane) },
            ruled:definition.ruled,tolerance:definition.tolerance,status:status) else {
            throw OCCTOpError(status)
        }
        return BRepHandle(shape)
    }
    static func surfaceOperation(_ definition: CADSurfaceDefinition, inputs: [BRepHandle]) throws -> BRepHandle {
        try definition.validate()
        let values: [Double]
        if let trim = definition.trim { values = [trim.uMin,trim.uMax,trim.vMin,trim.vMax] }
        else if let thickness = definition.thickness { values = [thickness] }
        else { values = [] }
        let data = values.withUnsafeBytes { Data($0) }, status = OCCTOpStatus()
        let snapshots = inputs.compactMap(independentSnapshot)
        guard snapshots.count == inputs.count else {
            throw LoftSurfaceError.invalid("The exact surface inputs could not be isolated for editing.")
        }
        guard let shape = OCCTBridge.surfaceOperation(definition.operation.rawValue,shapes:snapshots.map(\.shape),
            parameters:data,tolerance:definition.tolerance,requireClosed:definition.requireClosed,status:status) else {
            throw OCCTOpError(status)
        }
        return BRepHandle(shape)
    }
    static func surfaceDiagnostics(_ handle: BRepHandle) -> [String: Any] {
        OCCTBridge.surfaceDiagnostics(handle.shape)
    }
    nonisolated struct SurfaceDifferential: Sendable {
        var point: SIMD3<Double>; var du: SIMD3<Double>; var dv: SIMD3<Double>
        var duu: SIMD3<Double>; var duv: SIMD3<Double>; var dvv: SIMD3<Double>
        /// Normal of the underlying support's (u,v) orientation. A reversed
        /// topological face does not change the parameterization's derivatives.
        var normal: SIMD3<Double>? {
            let n = simd_cross(du,dv), length = simd_length(n)
            return length > 1e-12 ? n / length : nil
        }
        func normalCurvature(along direction: SIMD2<Double>) -> Double? {
            guard let normal, direction.x.isFinite, direction.y.isFinite else { return nil }
            let tangent = direction.x * du + direction.y * dv
            let speed2 = simd_dot(tangent,tangent)
            guard speed2 > 1e-18 else { return nil }
            let second = direction.x * direction.x * duu + 2 * direction.x * direction.y * duv
                + direction.y * direction.y * dvv
            let result = simd_dot(second,normal) / speed2
            return result.isFinite ? result : nil
        }
    }
    static func surfaceDifferential(_ handle: BRepHandle, faceIndex: Int, u: Double, v: Double) -> SurfaceDifferential? {
        guard let data = OCCTBridge.surfaceDifferential(handle.shape,faceIndex:faceIndex,u:u,v:v),
              data.count == 18 * MemoryLayout<Double>.size else { return nil }
        let d: [Double] = data.withUnsafeBytes { Array($0.bindMemory(to:Double.self)) }
        guard d.allSatisfy(\.isFinite) else { return nil }
        func vector(_ offset: Int) -> SIMD3<Double> { SIMD3(d[offset],d[offset+1],d[offset+2]) }
        return SurfaceDifferential(point:vector(0),du:vector(3),dv:vector(6),duu:vector(9),duv:vector(12),dvv:vector(15))
    }
}
