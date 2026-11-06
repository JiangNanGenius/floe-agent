// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
@preconcurrency import SceneKit
import simd
import FloeManufacturingCore

@MainActor enum CAMSurfaceGeometry {
    static func make(_ raw:[[Double]],triangles rawTriangles:[[Int]],smooth:Bool,cellSize:Double,coordinate:([Double])->SCNVector3)->SCNGeometry {
        let mesh = smooth ? ManufacturingDisplaySurface.mesh(raw,triangles:rawTriangles,cellSizeMM:cellSize) : nil
        let vertices = mesh?.vertices ?? raw,triangles = mesh?.triangles ?? rawTriangles
        if mesh?.circularRings == true {
            var points = [SCNVector3](),normals = [SCNVector3]()
            points.reserveCapacity(triangles.count*3);normals.reserveCapacity(triangles.count*3)
            for t in triangles {
                let p = t.map { vertices[$0] },a = SIMD3(p[0][0],p[0][1],p[0][2]),b = SIMD3(p[1][0],p[1][1],p[1][2]),c = SIMD3(p[2][0],p[2][1],p[2][2])
                let cross = simd_cross(b-a,c-a)
                let planar = abs(p[0][2]-p[1][2])<1e-7 && abs(p[0][2]-p[2][2])<1e-7
                let face = simd_length_squared(cross)>1e-24 ? simd_normalize(cross):SIMD3<Double>(0,0,1)
                let centre = (a+b+c)/3,sign = face.x*centre.x+face.y*centre.y>=0 ? 1.0 : -1.0
                for q in p {
                    points.append(coordinate(q))
                    let r = hypot(q[0],q[1])
                    normals.append(coordinate(planar || r<1e-12 ? [face.x,face.y,face.z] : [sign*q[0]/r,sign*q[1]/r,0]))
                }
            }
            return .init(sources:[SCNGeometrySource(vertices:points),SCNGeometrySource(normals:normals)],elements:[SCNGeometryElement(indices:Array(0..<Int32(points.count)),primitiveType:.triangles)])
        }
        guard let shaded = ManufacturingDisplaySurface.shadedMesh(vertices,triangles:triangles,smoothing:smooth) else { return SCNGeometry() }
        return .init(sources:[SCNGeometrySource(vertices:shaded.vertices.map(coordinate)),SCNGeometrySource(normals:shaded.normals.map(coordinate))],
                     elements:[SCNGeometryElement(indices:shaded.triangles.flatMap { $0.map(Int32.init) },primitiveType:.triangles)])
    }
}
#endif
