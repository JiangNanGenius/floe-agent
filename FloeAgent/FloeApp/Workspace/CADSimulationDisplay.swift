// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCAD
import FloeSimulationCore
import FloeSimulationGeometry
import FloeSimulationPhysics
import FloeSimulationAnimation
import FloeSimulationUI

nonisolated enum CADSimulationDisplayBuilder {
    static func make(geometry: CADSimulationGeometry, source: SimulationSourceRef, result: SimulationResult?, frame: SimulationResultFrame?, field: SimulationResultField?, physics: PhysicsSimulationConfiguration, pose: SimulationAnimationPose?, deformation: Double) throws -> CADSimulationDisplay {
        var surfaces: [CADSimulationDisplay.Surface] = []
        func point(_ p: SimulationVector3) -> SIMD3<Float> { SIMD3(Float(p.x*1000),Float(p.y*1000),Float(p.z*1000)) }
        if let mesh = result?.mesh, let frame {
            let exterior = try SimulationMeshTopology.exteriorFaces(mesh)
            guard exterior.count <= 300_000 else { throw SimulationError.resourceLimit("The display exceeds 300,000 surface triangles.") }
            let displacement = frame.fields.first { $0.id == "displacement" && $0.location == .node && $0.components == 3 }
            let positions = mesh.nodes.enumerated().map { i, node -> SIMD3<Float> in
                var p = node
                if let displacement, i*3+2 < displacement.values.count {
                    p = p + SimulationVector3(displacement.values[i*3],displacement.values[i*3+1],displacement.values[i*3+2])*deformation
                }
                return point(p)
            }
            func magnitude(_ index: Int) -> Double? {
                guard let field, index >= 0, (index+1)*field.components <= field.values.count else { return nil }
                let range = index*field.components..<(index+1)*field.components
                if field.components == 1, field.imaginaryValues == nil { return field.values[index] }
                return range.reduce(0.0) { value, i in hypot(hypot(value,field.values[i]),field.imaginaryValues?[i] ?? 0) }
            }
            let values: [Double?] = exterior.map { face in
                guard let field else { return nil }
                if field.location == .element { return magnitude(face.elementIndex) }
                if field.location == .node {
                    let values = face.nodes.compactMap(magnitude)
                    return values.count == face.nodes.count ? values.reduce(0) { $0+$1/Double(values.count) } : nil
                }
                return nil
            }
            let finite = values.compactMap { $0 }.filter(\.isFinite), lo = finite.min() ?? 0, hi = finite.max() ?? 0
            var bins: [Int:[UInt32]] = [:]
            for (i, face) in exterior.enumerated() {
                let scale = max(abs(lo),abs(hi),1)
                let bin = values[i].flatMap { value -> Int? in
                    let normalized = (value/scale-lo/scale)/(hi/scale-lo/scale)
                    return normalized.isFinite ? min(15,max(0,Int(min(1,max(0,normalized))*15))) : nil
                } ?? 8
                bins[bin,default:[]] += face.nodes.map(UInt32.init)
            }
            for bin in bins.keys.sorted() {
                let t = Float(bin)/15
                surfaces.append(.init(positionsMM:positions,indices:bins[bin]!,color:SIMD4(t,0.25+0.5*(1-abs(2*t-1)),1-t,1)))
            }
            let legend = field.map { value in
                let name = value.components > 1 || value.imaginaryValues != nil ? "|\(value.simulationDisplayName)|" : value.simulationDisplayName
                return "\(name) · \(String(format:"%.4g",lo)) … \(String(format:"%.4g",hi)) \(value.unit)"
            }
            return .init(id:mesh.id,revision:UInt64(frame.id+1),surfaces:surfaces,legend:legend)
        }
        guard result == nil || result?.source == source else { throw SimulationError.staleSource }
        let positions = frame?.fields.first { $0.id == "body_position" }?.values
        let rotations = frame?.fields.first { $0.id == "body_rotation" }?.values
        let visible = frame?.fields.first { $0.id == "body_visible" }?.values
        let order = result?.diagnostics["bodyIDs"]?.split(separator:",").compactMap { UUID(uuidString:String($0)) } ?? physics.bodies.map(\.id)
        let rawSourceIDs = result?.diagnostics["bodySourceObjectIDs"]
        let sourceIDs = rawSourceIDs.flatMap { try? JSONDecoder().decode([String].self,from:Data($0.utf8)) }
        let cadObjectIDs = Set(geometry.bodies.map { $0.id.uuidString.lowercased() })
        let mappedCADBodies = Set(order.enumerated().compactMap { index,id in
            if let sourceIDs, sourceIDs.indices.contains(index), cadObjectIDs.contains(sourceIDs[index].lowercased()) { return id }
            return cadObjectIDs.contains(id.uuidString.lowercased()) ? id:nil
        })
        for cad in geometry.bodies {
            let index = sourceIDs?.firstIndex { $0.lowercased() == cad.id.uuidString.lowercased() } ?? order.firstIndex(of:cad.id)
            if pose?.hiddenObjects.contains(cad.id.uuidString.lowercased()) == true || pose?.hiddenObjects.contains(cad.id.uuidString) == true { continue }
            if pose == nil, let index, let visible, visible.indices.contains(index), visible[index] < 0.5 { continue }
            let objectPose = pose?.objects[cad.id.uuidString.lowercased()] ?? pose?.objects[cad.id.uuidString]
            let count = Double(max(1,cad.positionsMM.count))
            let origin = cad.positionsMM.reduce(SimulationVector3.zero) { $0+SimulationVector3($1[0]*0.001/count,$1[1]*0.001/count,$1[2]*0.001/count) }
            let transformed = cad.positionsMM.map { value -> SIMD3<Float> in
                var p = SimulationVector3(value[0]*0.001,value[1]*0.001,value[2]*0.001)
                if let objectPose {
                    let local = p-origin
                    p = SimulationAnimationMath.rotate(objectPose.rotation,.init(local.x*objectPose.scale.x,local.y*objectPose.scale.y,local.z*objectPose.scale.z))+objectPose.translation
                } else if let index, let positions, let rotations, index*3+2 < positions.count, index*4+3 < rotations.count {
                    let q = SimulationQuaternion(x:rotations[index*4],y:rotations[index*4+1],z:rotations[index*4+2],w:rotations[index*4+3])
                    p = SimulationAnimationMath.rotate(q,p-origin)+SimulationVector3(positions[index*3],positions[index*3+1],positions[index*3+2])
                }
                return point(p)
            }
            surfaces.append(.init(positionsMM:transformed,indices:cad.indices,color:SIMD4(0.2,0.55,0.85,1)))
        }
        var soft: [String:[SimulationVector3]] = [:]
        for field in frame?.fields ?? [] where field.id.hasPrefix("soft/") && field.components == 3 {
            soft[field.id] = stride(from:0,to:field.values.count-2,by:3).map { .init(field.values[$0],field.values[$0+1],field.values[$0+2]) }
        }
        if let pose { soft = pose.softVertices }
        for id in soft.keys.sorted() {
            let raw = result?.diagnostics[id+"/triangles"]
            let triangles = raw.flatMap { try? JSONDecoder().decode([[UInt32]].self,from:Data($0.utf8)) } ?? []
            let points = (soft[id] ?? []).map(point)
            if !triangles.isEmpty { surfaces.append(.init(positionsMM:points,indices:triangles.flatMap { $0 },color:SIMD4(0.95,0.5,0.2,1))) }
            else { surfaces += try markers(points,color:SIMD4(0.95,0.5,0.2,1)) }
        }
        var rendered = Set<UUID>()
        let cadIDs = Set(geometry.bodies.map { $0.id.uuidString.lowercased() })
        if physics.bodies.count <= 256 {
            for body in physics.bodies where !cadIDs.contains(body.sourceObjectID.lowercased()) {
                let index = order.firstIndex(of:body.id), objectPose = pose?.objects[body.sourceObjectID]
                if pose?.hiddenObjects.contains(body.sourceObjectID) == true { continue }
                if pose == nil, let index, let visible, visible.indices.contains(index), visible[index] < 0.5 { continue }
                var p = objectPose?.translation ?? body.translation, q = objectPose?.rotation ?? body.rotation
                if pose == nil, let index, let positions, let rotations, index*3+2 < positions.count, index*4+3 < rotations.count {
                    p = .init(positions[index*3],positions[index*3+1],positions[index*3+2])
                    q = .init(x:rotations[index*4],y:rotations[index*4+1],z:rotations[index*4+2],w:rotations[index*4+3])
                }
                if let surface = CADSimulationColliderDisplay.surface(body.collider,translation:p,rotation:q) { surfaces.append(surface); rendered.insert(body.id) }
            }
        }
        if let pose {
            let known = Set(geometry.bodies.map { $0.id.uuidString.lowercased() })
            let renderedTargets = Set(physics.bodies.filter { rendered.contains($0.id) }.map(\.sourceObjectID))
            let points = pose.objects.filter { !known.contains($0.key.lowercased()) && !renderedTargets.contains($0.key) && $0.key != "camera" && !pose.hiddenObjects.contains($0.key) }.map { point($0.value.translation) }
            surfaces += try markers(points,color:SIMD4(0.95,0.6,0.2,1))
        } else if let positions {
            let known = mappedCADBodies
            var points: [SIMD3<Float>] = []
            for (i,id) in order.enumerated() where !known.contains(id) && !rendered.contains(id) && i*3+2 < positions.count {
                if let visible, visible.indices.contains(i), visible[i] < 0.5 { continue }
                points.append(point(.init(positions[i*3],positions[i*3+1],positions[i*3+2])))
            }
            surfaces += try markers(points,color:SIMD4(0.95,0.6,0.2,1))
        }
        return .init(id:source.documentID,revision:UInt64(frame?.id ?? 0),surfaces:surfaces)
    }
    private static func markers(_ points: [SIMD3<Float>], color: SIMD4<Float>) throws -> [CADSimulationDisplay.Surface] {
        guard points.count <= 100_000 else { throw SimulationError.resourceLimit("The display exceeds 100,000 particle positions.") }
        guard !points.isEmpty else { return [] }
        var vertices: [SIMD3<Float>] = [], indices: [UInt32] = []
        for p in points {
            let offset = UInt32(vertices.count)
            vertices += [p+SIMD3(0,1,0),p+SIMD3(-1,-1,1),p+SIMD3(1,-1,1),p+SIMD3(0,-1,-1)]
            indices += [0,1,2,0,2,3,0,3,1,1,3,2].map { offset+UInt32($0) }
        }
        return [.init(positionsMM:vertices,indices:indices,color:color)]
    }
}

struct CADSimulationResultViewport: View {
    let entry: CADSimulationSessions.Entry
    let model: SimulationWorkbenchModel
    @State private var display: CADSimulationDisplay?
    @State private var failure: String?
    @State private var renderRevision: UInt64 = 0
    private var key: String {
        "\(model.document.source.contentSHA256)/\(model.result?.id.uuidString ?? "")/\(model.frameIndex)/\(model.selectedFieldID ?? "")/\(model.deformationScale)/\(model.displaysAnimation)/\(model.animationPreviewRevision)"
    }
    var body: some View {
        Group {
            if !model.sourceAvailable { ProgressView(IDELanguageRunText.t("模型已改变，正在更新", "Updating the changed model")) }
            else if let failure { ContentUnavailableView(IDELanguageRunText.t("无法显示", "Unable to display"),systemImage:"cube.transparent",description:Text(failure)) }
            else if let display { CADSimulationViewport(display:display) }
            else { ProgressView() }
        }.task(id:key) {
            let geometry = entry.geometry, source = model.document.source
            let result = model.displaysAnimation && model.result?.mesh != nil ? nil : model.result
            let frame = result == nil ? nil : model.currentFrame
            let field = model.currentField, physics = model.physics, pose = model.displaysAnimation ? model.animationPose : nil, scale = model.deformationScale
            let worker = Task.detached(priority:.userInitiated) { try CADSimulationDisplayBuilder.make(geometry:geometry,source:source,result:result,frame:frame,field:field,physics:physics,pose:pose,deformation:scale) }
            do {
                var value = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); renderRevision &+= 1; value.revision = renderRevision
                display = value; failure = nil
            } catch is CancellationError {} catch { display = nil; failure = error.localizedDescription }
        }
    }
}
#endif
