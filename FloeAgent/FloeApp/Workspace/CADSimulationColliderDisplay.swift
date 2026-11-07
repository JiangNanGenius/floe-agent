// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCAD
import FloeSimulationCore
import FloeSimulationPhysics
import FloeSimulationAnimation

nonisolated enum CADSimulationColliderDisplay {
    static func surface(_ collider: SimulationCollider, translation: SimulationVector3, rotation: SimulationQuaternion) -> CADSimulationDisplay.Surface? {
        var vertices: [SimulationVector3] = [], indices: [UInt32] = []
        switch collider.kind {
        case .box:
            let h = collider.halfExtents
            vertices = [.init(-h.x,-h.y,-h.z),.init(h.x,-h.y,-h.z),.init(h.x,h.y,-h.z),.init(-h.x,h.y,-h.z),.init(-h.x,-h.y,h.z),.init(h.x,-h.y,h.z),.init(h.x,h.y,h.z),.init(-h.x,h.y,h.z)]
            indices = [0,2,1,0,3,2,4,5,6,4,6,7,0,1,5,0,5,4,3,7,6,3,6,2,1,2,6,1,6,5,0,4,7,0,7,3]
        case .sphere,.capsule:
            let segments = 24, rings = 12, radius = collider.radius
            for y in 0...rings {
                let angle = Double(y)*Double.pi/Double(rings)
                let offset = collider.kind == .capsule ? (cos(angle) >= 0 ? collider.halfHeight : -collider.halfHeight) : 0
                for x in 0..<segments {
                    let longitude = Double(x)*2*Double.pi/Double(segments)
                    vertices.append(.init(radius*sin(angle)*cos(longitude),radius*cos(angle)+offset,radius*sin(angle)*sin(longitude)))
                }
            }
            for y in 0..<rings { for x in 0..<segments {
                let a = UInt32(y*segments+x), b = UInt32(y*segments+(x+1)%segments), c = a+UInt32(segments), d = b+UInt32(segments)
                if y > 0 { indices += [a,b,c] }
                if y < rings-1 { indices += [b,d,c] }
            } }
        case .triangleMesh,.convexDecomposition:
            vertices = collider.vertices; indices = collider.triangles.flatMap { $0 }
        case .convexHull: return nil
        }
        guard !indices.isEmpty else { return nil }
        let positions = vertices.map { vertex -> SIMD3<Float> in
            let p = SimulationAnimationMath.rotate(rotation,vertex)+translation
            return SIMD3(Float(p.x*1000),Float(p.y*1000),Float(p.z*1000))
        }
        return .init(positionsMM:positions,indices:indices,color:SIMD4(0.65,0.65,0.7,1))
    }
}
#endif
