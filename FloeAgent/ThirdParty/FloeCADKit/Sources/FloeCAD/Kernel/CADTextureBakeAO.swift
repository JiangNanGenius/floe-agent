// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

nonisolated extension CADTexturePaintKernel {
    struct BakeTriangle:Sendable {
        let a:SIMD3<Double>;let b:SIMD3<Double>;let c:SIMD3<Double>
    }
    static func rayBox(_ origin:SIMD3<Double>,_ direction:SIMD3<Double>,_ bounds:CADInterferenceAABB,_ limit:Double)->Bool {
        var lo=0.0,hi=limit
        for axis in 0..<3 {
            if abs(direction[axis])<1e-15 { if origin[axis]<bounds.min[axis] || origin[axis]>bounds.max[axis] { return false } }
            else {
                let a=(bounds.min[axis]-origin[axis])/direction[axis],b=(bounds.max[axis]-origin[axis])/direction[axis]
                lo=max(lo,min(a,b));hi=min(hi,max(a,b));if hi<lo { return false }
            }
        }
        return true
    }
    static func radicalInverse(_ index:Int)->Double {
        var value=UInt32(index),result=0.0,weight=0.5
        while value>0 { result += Double(value&1)*weight;weight *= 0.5;value >>= 1 }
        return result
    }
    /// Cosine-weighted hemispherical visibility over the CURRENT triangle mesh.
    /// This is a deterministic, bounded mesh AO bake, not an exact B-rep,
    /// screenshot, normal map, high/low transfer or light-transport solution.
    static func ambientOcclusion(_ source:CADTexturePaintSource,atlas:Atlas,samples:Int,maxDistance:Double,
                                 budget:CADTexturePaintBudget)throws->(values:[Double],rays:Int,occluded:Int) {
        guard [8,16,32].contains(samples),maxDistance.isFinite,maxDistance>0,maxDistance<=100000 else {
            throw fail("invalid_bake_settings","AO requires 8, 16 or 32 samples and a positive distance up to 100000 mm.")
        }
        let geometries=[CADTexturePaintGeometry(mesh:source.mesh,transform:source.transform)]+source.occluders
        guard geometries.count<=32,geometries.reduce(0,{$0+$1.mesh.triangleCount})<=100000 else { throw fail("bake_geometry_budget","AO accepts at most 100000 triangles across 32 bodies.") }
        var triangles:[BakeTriangle]=[],bounds:[CADInterferenceAABB]=[],centroids:[SIMD3<Double>]=[]
        for geometry in geometries {
            try CADUVRecord.validate(geometry.mesh)
            let points=geometry.mesh.positions.map { geometry.transform.applying(to:SIMD3(Double($0.x),Double($0.y),Double($0.z))) }
            guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && simd_length($0)<1e9 }) else { throw fail("invalid_bake_geometry","The transformed mesh is outside the bake coordinate budget.") }
            for f in 0..<geometry.mesh.triangleCount {
                if f&63==0 { try budget.check(64) }
                let ids=(0..<3).map { Int(geometry.mesh.indices[f*3+$0]) },a=points[ids[0]],b=points[ids[1]],c=points[ids[2]]
                guard simd_length(simd_cross(b-a,c-a))>1e-12 else { throw fail("invalid_bake_geometry","The body placement collapses a triangle.") }
                triangles.append(.init(a:a,b:b,c:c));bounds.append(.init(points:[a,b,c]));centroids.append((a+b+c)/3)
            }
        }
        let bvh=CADInterferenceBVH.build(triangleBounds:bounds,centroids:centroids,shouldStop:{ budget.shouldStop })
        try budget.check()
        guard !bvh.nodes.isEmpty else { throw fail("invalid_bake_geometry","The occluder hierarchy is unavailable.") }
        let targetBounds=bounds.prefix(source.mesh.triangleCount).reduce(CADInterferenceAABB.empty) { $0.union($1) }
        let bias=max(1e-8,targetBounds.diagonal*1e-7)
        func blocked(_ origin:SIMD3<Double>,_ direction:SIMD3<Double>,ignore:Int)throws->Bool {
            var stack=[0]
            while let index=stack.popLast() {
                try budget.check()
                let node=bvh.nodes[index]
                guard rayBox(origin,direction,node.bounds,maxDistance) else { continue }
                if node.count==0 { if node.left>=0 { stack.append(Int(node.left)) };if node.right>=0 { stack.append(Int(node.right)) } }
                else {
                    for offset in Int(node.start)..<Int(node.start+node.count) {
                        try budget.check()
                        let index=Int(bvh.order[offset]);if index==ignore { continue }
                        let t=triangles[index]
                        if let distance=ExtrudeEndKit.rayTriangle(origin:origin,direction:direction,a:t.a,b:t.b,c:t.c),distance>bias*0.25,distance<=maxDistance { return true }
                    }
                }
            }
            return false
        }
        var values=[Double](repeating:1,count:atlas.width*atlas.height),rays=0,occluded=0
        for pixel in atlas.owners.indices {
            let face=Int(atlas.owners[pixel]);if face<0 { continue }
            try budget.check()
            let uv=SIMD2((Double(pixel%atlas.width)+0.5)/Double(atlas.width),(Double(pixel/atlas.width)+0.5)/Double(atlas.height))
            guard let w=barycentric(uv,atlas.uv[face*3],atlas.uv[face*3+1],atlas.uv[face*3+2]) else { throw fail("invalid_bake_uv","An atlas triangle became degenerate.") }
            let triangle=triangles[face],point=triangle.a*w.x+triangle.b*w.y+triangle.c*w.z
            // A negative similarity placement reverses handedness. Match the
            // transformed authored surface normal, as the render/export path does.
            let n=simd_normalize(simd_cross(triangle.b-triangle.a,triangle.c-triangle.a))*(source.transform.scale<0 ? -1.0 : 1.0)
            let axis=abs(n.z)<0.9 ? SIMD3<Double>(0,0,1) : SIMD3<Double>(0,1,0)
            let tangent=simd_normalize(simd_cross(axis,n)),bitangent=simd_cross(n,tangent)
            var hits=0
            for sample in 0..<samples {
                let u=(Double(sample)+0.5)/Double(samples),phi=2*Double.pi*radicalInverse(sample)
                let r=sqrt(u),direction=tangent*(r*cos(phi))+bitangent*(r*sin(phi))+n*sqrt(1-u)
                if try blocked(point+n*bias,direction,ignore:face) { hits += 1 };rays += 1
            }
            occluded += hits;values[pixel]=1-Double(hits)/Double(samples)
        }
        return (values,rays,occluded)
    }
}
