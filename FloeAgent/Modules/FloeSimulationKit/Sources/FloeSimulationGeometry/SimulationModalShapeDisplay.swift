// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeSimulationCore

/// Mode shapes have no physical response amplitude. At preview scale 1, the
/// largest nodal movement is 2% of the undeformed mesh bounding-box diagonal.
public enum SimulationModalShapeDisplay {
    public static let previewFraction = 0.02
    public static func positions(mesh:SimulationMesh,field:SimulationResultField,scale:Double) throws -> [SimulationVector3] {
        guard field.id=="mode_shape",field.unit=="1",field.location == .node,field.components==3,field.imaginaryValues==nil,
              field.values.count==mesh.nodes.count*3,!mesh.nodes.isEmpty,scale.isFinite,mesh.nodes.allSatisfy(\.isFinite) else { throw SimulationError.solverFailure("Invalid normalized mode shape for preview.") }
        try field.validate()
        var lo=mesh.nodes[0],hi=lo
        for p in mesh.nodes {
            lo = .init(min(lo.x,p.x),min(lo.y,p.y),min(lo.z,p.z));hi = .init(max(hi.x,p.x),max(hi.y,p.y),max(hi.z,p.z))
        }
        let diagonal=hypot(hypot(hi.x-lo.x,hi.y-lo.y),hi.z-lo.z),amplitude=diagonal*previewFraction*scale
        guard diagonal.isFinite,diagonal>0,amplitude.isFinite else { throw SimulationError.resourceLimit("The mode preview scale cannot be represented.") }
        let positions=mesh.nodes.enumerated().map { i,p in
            p+SimulationVector3(field.values[i*3],field.values[i*3+1],field.values[i*3+2])*amplitude
        }
        guard positions.allSatisfy(\.isFinite) else { throw SimulationError.resourceLimit("The mode preview coordinates overflowed.") }
        return positions
    }
}
