// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

/// Rendering only. The native result, stock quantities, collision queries and
/// exported mesh remain authoritative and never pass through this filter.
/// R9 preserves all geometric vertices. Smooth shading uses separate corner
/// normals; generic voxel geometry is never rounded without analytic ownership.
public enum ManufacturingDisplaySurface {
    /// Angle-weighted, crease-aware display normals avoid letting the long
    /// faces of an irregular voxel triangulation dominate a round surface.
    /// Three bounded local passes affect shading only, never mesh positions.
    public static func normals(_ input:[[Double]],triangles:[[Int]],cellSizeMM:Double,smoothing:Bool)->[[Double]] {
        guard input.count<=540_000,triangles.count<=180_000,input.allSatisfy({ $0.count==3 && $0.allSatisfy(\.isFinite) }),
              triangles.allSatisfy({ $0.count==3 && $0.allSatisfy { input.indices.contains($0) } }) else { return [] }
        let points = input.map { SIMD3<Double>($0[0],$0[1],$0[2]) }
        var sum = [SIMD3<Double>](repeating:.zero,count:points.count),seed = sum
        var neighbors = [Set<Int>](repeating:[],count:points.count),crease = [Bool](repeating:false,count:points.count)
        for t in triangles {
            let a = points[t[0]],b = points[t[1]],c = points[t[2]],cross = simd_cross(b-a,c-a),size = simd_length(cross)
            guard size>1e-16 else { continue };let face = cross/size
            for j in 0..<3 {
                let i = t[j],u = points[t[(j+1)%3]]-points[i],v = points[t[(j+2)%3]]-points[i]
                let angle = atan2(simd_length(simd_cross(u,v)),simd_dot(u,v))
                sum[i] += smoothing ? face*angle : cross
                if simd_length_squared(seed[i])==0 { seed[i] = face }
                else if simd_dot(seed[i],face)<0.5 { crease[i] = true }
                if smoothing { neighbors[i].insert(t[(j+1)%3]);neighbors[i].insert(t[(j+2)%3]) }
            }
        }
        func unit(_ n:SIMD3<Double>)->SIMD3<Double> { simd_length_squared(n)>1e-24 ? simd_normalize(n):SIMD3(0,0,1) }
        var values = sum.map(unit)
        if smoothing,cellSizeMM.isFinite,cellSizeMM>0 {
            let rings = neighbors.map { $0.sorted() }
            for _ in 0..<3 {
                var next = values
                for i in values.indices where !crease[i] {
                    var mean = values[i]*2
                    for j in rings[i] where !crease[j] && simd_distance(points[i],points[j])<=cellSizeMM*2 && simd_dot(values[i],values[j])>0.5 { mean += values[j] }
                    next[i] = unit(mean)
                }
                values = next
            }
        }
        return values.map { [$0.x,$0.y,$0.z] }
    }
    public struct Mesh:Sendable {
        public var vertices:[[Double]]
        public var triangles:[[Int]]
        public var refinementPasses:Int
        public var circularRings = false
    }
    private static func circularRings(_ points:[[Double]],triangles:[[Int]])->Bool {
        guard !points.isEmpty,points.count<=540_000,triangles.count<=180_000,points.allSatisfy({ $0.count==3 && $0.allSatisfy(\.isFinite) }),
              triangles.allSatisfy({ $0.count==3 && $0.allSatisfy { points.indices.contains($0) } }) else { return false }
        let scale = max(1,points.flatMap { $0 }.map(abs).max() ?? 1),epsilon = scale*1e-8
        var rings = [String:[Double]]()
        let radii = points.map { hypot($0[0],$0[1]) }
        for i in points.indices where radii[i]>epsilon {
            let p = points[i],key = "\(Int64((p[2]/epsilon).rounded())):\(Int64((radii[i]/epsilon).rounded()))"
            rings[key,default:[]].append(atan2(p[1],p[0]))
        }
        guard !rings.isEmpty else { return false }
        for angles in rings.values {
            guard (24...128).contains(angles.count) else { return false }
            let a = angles.sorted(),step = 2*Double.pi/Double(a.count)
            for i in a.indices { let delta = i+1<a.count ? a[i+1]-a[i] : a[0]+2*Double.pi-a[i];if abs(delta-step)>1e-7 { return false } }
        }
        return triangles.allSatisfy { t in
            let z = t.map { points[$0][2] },r = t.map { radii[$0] }
            return z.max()!-z.min()!<=epsilon || r.max()!-r.min()!<=epsilon
        }
    }
    /// Geometric fairing without analytic feature ownership can round real corners.
    /// Keep every source vertex/edge; smooth shading is a separate per-corner step.
    public static func mesh(_ input:[[Double]],triangles:[[Int]],cellSizeMM:Double)->Mesh {
        .init(vertices:input,triangles:triangles,refinementPasses:0,circularRings:circularRings(input,triangles:triangles))
    }
    public static func vertices(_ input:[[Double]],triangles:[[Int]],cellSizeMM:Double) -> [[Double]] { input }

    public struct ShadedMesh:Sendable {
        public let vertices:[[Double]]
        public let normals:[[Double]]
        public let triangles:[[Int]]
    }
    /// Split render vertices at sharp edges. Original triangle positions, flat faces,
    /// dimensions and topology stay exact; never share an averaged normal across a
    /// right-angle corner. The 35 degree crease threshold only controls lighting.
    public static func shadedMesh(_ input:[[Double]],triangles:[[Int]],smoothing:Bool)->ShadedMesh? {
        guard input.count<=540_000,triangles.count<=180_000,
              input.allSatisfy({ $0.count==3 && $0.allSatisfy(\.isFinite) }),
              triangles.allSatisfy({ $0.count==3 && $0.allSatisfy { input.indices.contains($0) } }) else { return nil }
        let points=input.map { SIMD3<Double>($0[0],$0[1],$0[2]) }
        var faceNormals=[SIMD3<Double>](),angles=[[Double]](),incident=[[Int]](repeating:[],count:input.count)
        for (index,t) in triangles.enumerated() {
            let a=points[t[0]],b=points[t[1]],c=points[t[2]],cross=simd_cross(b-a,c-a)
            let length=simd_length(cross)
            faceNormals.append(length>1e-16 ? cross/length : SIMD3<Double>(0,0,1))
            var cornerAngles=[Double]()
            for j in 0..<3 {
                let u=points[t[(j+1)%3]]-points[t[j]],v=points[t[(j+2)%3]]-points[t[j]]
                cornerAngles.append(atan2(simd_length(simd_cross(u,v)),simd_dot(u,v)))
                incident[t[j]].append(index)
            }
            angles.append(cornerAngles)
        }
        var output=[[Double]](),normals=[[Double]](),faces=[[Int]]()
        output.reserveCapacity(triangles.count*3);normals.reserveCapacity(triangles.count*3);faces.reserveCapacity(triangles.count)
        let threshold=cos(35*Double.pi/180)
        for (index,t) in triangles.enumerated() {
            let base=output.count
            for vertex in t {
                var normal=faceNormals[index]
                if smoothing && incident[vertex].count <= 128 {
                    var sum=SIMD3<Double>.zero
                    for face in incident[vertex] where simd_dot(faceNormals[index],faceNormals[face])>=threshold {
                        if let corner=triangles[face].firstIndex(of:vertex) { sum += faceNormals[face]*angles[face][corner] }
                    }
                    if simd_length_squared(sum)>1e-24 { normal=simd_normalize(sum) }
                }
                output.append(input[vertex]);normals.append([normal.x,normal.y,normal.z])
            }
            faces.append([base,base+1,base+2])
        }
        return .init(vertices:output,normals:normals,triangles:faces)
    }
}
