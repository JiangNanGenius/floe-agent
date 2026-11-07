// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCAD
import FloeSimulationCore
import FloeSimulationAnimation
import FloeSimulationPhysics
import FloeSimulationUI

@MainActor enum CADSimulationAnimationExport {
    static func write(_ request:SimulationAnimationExportRequest,document:FloeCADDocument,geometry:CADSimulationGeometry) async throws {
        switch request.format {
        case .motionJSON: return
        case .glb:
            let extra = try extraParts(request,geometry:geometry)
            let base = try document.simulationGLBSource(expectedGeometrySHA256:request.graph.source.contentSHA256,extraParts:extra)
            let task = Task.detached(priority:.userInitiated) { try CADSimulationAnimationBridge.glb(base:base,request:request) }
            let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation(); try data.write(to:request.outputURL,options:.atomic)
        case .mp4:
            try await CADSimulationVideoExporter.render(bake:request.bake,to:request.outputURL,frame:{ index in
                try CADSimulationDisplayBuilder.make(geometry:geometry,source:request.graph.source,result:request.physics,frame:nil,field:nil,
                    physics:request.physicsConfiguration,pose:request.bake.frames[index],deformation:1,graph:request.graph)
            },progress:request.progress)
        }
    }
    private static func extraParts(_ request:SimulationAnimationExportRequest,geometry:CADSimulationGeometry) throws -> [CADSimulationExportPart] {
        var parts:[CADSimulationExportPart] = []
        let sourceIDs = Set(geometry.bodies.map { $0.id.uuidString.lowercased() })
        let boneIDs = Set(request.graph.bones.map(\.id))
        let ids = Set(request.bake.frames.flatMap { $0.objects.keys }).subtracting(sourceIDs).subtracting(boneIDs).subtracting(["camera"])
        guard ids.count <= 4096 else { throw SimulationError.resourceLimit("Reduce the number of animated particles or bodies for GLB export.") }
        for id in ids.sorted() {
            try Task.checkCancellation()
            guard let pose = request.bake.frames.first?.objects[id] else { throw SimulationError.invalidInput("An animated body has no initial pose.") }
            let body = request.physicsConfiguration.bodies.first { $0.sourceObjectID == id }
            var p:[SIMD3<Float>] = [], indices:[UInt32] = []
            if let body,let surface = CADSimulationColliderDisplay.surface(body.collider,translation:.zero,rotation:.identity) {
                p = surface.positionsMM; indices = surface.indices
            } else {
                // Small visible particle glyphs share the same sampled transforms.
                let radius = Float((body?.collider.radius ?? 0.001)*1000)
                p = [SIMD3(radius,0,0),SIMD3(-radius,0,0),SIMD3(0,radius,0),SIMD3(0,-radius,0),SIMD3(0,0,radius),SIMD3(0,0,-radius)]
                indices = [0,2,4,2,1,4,1,3,4,3,0,4,2,0,5,1,2,5,3,1,5,0,3,5]
                if body?.collider.kind == .convexHull { throw SimulationError.unsupported("Choose a triangle or decomposed Mesh collider for GLB geometry, or export MP4.") }
            }
            parts.append(.init(objectID:id,positionsMM:p,indices:indices,translationMM:SIMD3(pose.translation.x,pose.translation.y,pose.translation.z)*1000,rotation:SIMD4(pose.rotation.x,pose.rotation.y,pose.rotation.z,pose.rotation.w)))
        }
        if let physics = request.physics {
            let soft = physics.diagnostics["softSourceObjectIDs"].flatMap { try? JSONDecoder().decode([String:String].self,from:Data($0.utf8)) } ?? [:]
            for (key,id) in soft where !sourceIDs.contains(id) {
                guard let points = request.bake.frames.first?.softVertices["soft/"+key],
                      let raw = physics.diagnostics["soft/"+key+"/triangles"],
                      let triangles = try? JSONDecoder().decode([[UInt32]].self,from:Data(raw.utf8)),!triangles.isEmpty else { throw SimulationError.unsupported("Export rope animation as MP4; GLB soft bodies need a surface Mesh.") }
                parts.append(.init(objectID:id,positionsMM:points.map { SIMD3(Float($0.x*1000),Float($0.y*1000),Float($0.z*1000)) },indices:triangles.flatMap { $0 },translationMM:.zero))
            }
        }
        return parts
    }
}
#endif
