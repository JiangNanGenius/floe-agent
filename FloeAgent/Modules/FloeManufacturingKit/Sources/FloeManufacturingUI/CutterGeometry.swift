// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SceneKit
import UIKit
import simd
import FloeManufacturingCore

@MainActor enum CutterGeometry {
    /// Rotational profile in the same tip-origin/+Y convention as the native
    /// SDF. A ball nose is a lower hemisphere plus a cylinder; a drill has a
    /// conical tip whose height comes from the included angle.
    static func install(kind:String,radius:Double,length:Double,tipAngle:Double?,on root:SCNNode) {
        root.geometry = nil; root.childNodes.forEach { $0.removeFromParentNode() }
        guard radius > 0, length > 0 else { return }
        var profile = [SIMD2<Double>]() // [radius, axial distance]
        if kind == "ballNose" {
            profile = (0...16).map { i in
                let angle = Double(i) * .pi/32
                return SIMD2(radius*sin(angle),radius*(1-cos(angle)))
            }
        } else if kind == "drill", let tipAngle {
            profile = [SIMD2(0,0),SIMD2(radius,radius/tan(tipAngle * .pi/360))]
        } else { profile = [SIMD2(0,0),SIMD2(radius,0)] }
        if profile.last!.y < length { profile.append(SIMD2(radius,length)) }
        profile.append(SIMD2(0,length))
        let slices = 48
        var points = [SIMD3<Float>]()
        for p in profile {
            for i in 0..<slices {
                let a = Double(i)*2 * .pi/Double(slices)
                points.append(SIMD3(Float(p.x*cos(a)),Float(p.y),Float(p.x*sin(a))))
            }
        }
        var faces = [[Int]]()
        for row in 1..<profile.count {
            for i in 0..<slices {
                let a = (row-1)*slices+i, b = (row-1)*slices+(i+1)%slices, c = row*slices+i, d = row*slices+(i+1)%slices
                for t in [[a,c,b],[b,c,d]] {
                    let n = simd_cross(points[t[1]]-points[t[0]],points[t[2]]-points[t[0]])
                    if simd_length_squared(n) > 1e-15 { faces.append(t) }
                }
            }
        }
        guard let shaded = ManufacturingDisplaySurface.shadedMesh(points.map { [Double($0.x),Double($0.y),Double($0.z)] },triangles:faces,smoothing:true) else { return }
        let positions = SCNGeometrySource(vertices:shaded.vertices.map { SCNVector3($0[0],$0[1],$0[2]) })
        let ns = SCNGeometrySource(normals:shaded.normals.map { SCNVector3($0[0],$0[1],$0[2]) })
        let geometry = SCNGeometry(sources:[positions,ns],elements:[SCNGeometryElement(indices:shaded.triangles.flatMap { $0.map(Int32.init) },primitiveType:.triangles)])
        geometry.firstMaterial?.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.7)
        geometry.firstMaterial?.isDoubleSided = true
        root.geometry = geometry
    }
}
#endif
