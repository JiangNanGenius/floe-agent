// SPDX-License-Identifier: MPL-2.0
import Foundation
import UIKit
import simd

@MainActor enum CADSimulationRenderScene {
    static func make(_ display:CADSimulationDisplay) throws -> (scene:ViewportScene,lo:SIMD3<Float>,hi:SIMD3<Float>) {
        var scene = ViewportScene(); scene.showsGrid = false
        var lo = SIMD3<Float>(repeating:.infinity), hi = SIMD3<Float>(repeating:-.infinity)
        var triangleCount = 0
        for (index,surface) in display.surfaces.enumerated() {
            triangleCount += surface.indices.count/3
            guard triangleCount <= 600_000, !surface.positionsMM.isEmpty, surface.positionsMM.count <= 900_000,
                  surface.indices.count.isMultiple(of:3), surface.positionsMM.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
                  surface.indices.allSatisfy({ Int($0) < surface.positionsMM.count }) else { throw CADDocumentError(code:"simulation_display",message:"The simulation frame exceeds its display budget or has invalid geometry.") }
            var normals = Array(repeating:SIMD3<Float>.zero,count:surface.positionsMM.count)
            for i in stride(from:0,to:surface.indices.count,by:3) {
                let a = Int(surface.indices[i]), b = Int(surface.indices[i+1]), c = Int(surface.indices[i+2])
                let n = simd_cross(surface.positionsMM[b]-surface.positionsMM[a],surface.positionsMM[c]-surface.positionsMM[a]); normals[a] += n; normals[b] += n; normals[c] += n
            }
            normals = normals.map { simd_length_squared($0)>1e-20 ? simd_normalize($0):SIMD3(0,1,0) }
            for point in surface.positionsMM { lo = simd_min(lo,point); hi = simd_max(hi,point) }
            var uuid = display.id.uuid
            withUnsafeMutableBytes(of:&uuid) { bytes in for i in 0..<8 { bytes[15-i] ^= UInt8(truncatingIfNeeded:(index+1)>>(8*i)) } }
            let mesh = RenderMesh(positions:surface.positionsMM,normals:normals,indices:surface.indices)
            scene.bodies.append(.init(id:BodyID(raw:UUID(uuid:uuid)),renderMesh:mesh,edges:nil,meshRevision:display.revision,
                                      modelMatrix:matrix_identity_float4x4,baseColor:surface.color,material:nil))
        }
        return (scene,lo,hi)
    }
    static func applyCamera(_ pose:CADSimulationCamera,to camera:inout TurntableCamera) throws {
        let q = simd_quatd(vector:pose.rotation)
        guard pose.positionMeters.x.isFinite, pose.positionMeters.y.isFinite, pose.positionMeters.z.isFinite,
              q.vector.x.isFinite, q.vector.y.isFinite, q.vector.z.isFinite, q.vector.w.isFinite,
              abs(simd_length(q.vector)-1)<1e-6, pose.verticalFOVDegrees.isFinite, (5...170).contains(pose.verticalFOVDegrees) else { throw CADDocumentError(code:"simulation_camera",message:"The animation camera has invalid values.") }
        let back = SIMD3<Float>(q.act(SIMD3(0,0,1))), up = SIMD3<Float>(q.act(SIMD3(0,1,0)))
        let eye = SIMD3<Float>(pose.positionMeters*1000)
        let fov = Float(pose.verticalFOVDegrees)*Float.pi/180
        if let height = pose.orthographicHeightMeters {
            guard height.isFinite, height>0 else { throw CADDocumentError(code:"simulation_camera",message:"Choose a positive camera height.") }
            camera.distance = Float(height*500)/tan(TurntableCamera.defaultFovY*0.5); camera.projection = .orthographic
        } else { camera.distance = max(camera.distance,1); camera.projection = .perspective(fovY:fov) }
        camera.target = eye-back*camera.distance; camera.azimuth = atan2(back.x,back.z)
        camera.elevation = asin(min(1,max(-1,back.y))); camera.upVector = up
    }
}

/// Owns a private instance of the existing Metal renderer. No App view, camera,
/// selection or authoritative document is changed by offscreen video frames.
@MainActor public final class CADSimulationFrameRenderer {
    private let renderer:Renderer
    private var fitted = false
    private var revision:UInt64 = 0
    public init() throws {
        guard let context = RenderContext() else { throw CADDocumentError(code:"renderer_unavailable",message:"The 3D renderer is unavailable.") }
        renderer = Renderer(context:context)
    }
    public func fit(boundsMinMM:SIMD3<Float>,boundsMaxMM:SIMD3<Float>,width:Int,height:Int) {
        renderer.camera.fit(boundsMin:boundsMinMM,boundsMax:boundsMaxMM,aspect:Float(width)/Float(max(1,height))); fitted = true
    }
    public func capturePNG(_ display:CADSimulationDisplay,width:Int = 1280,height:Int = 720) throws -> Data {
        try Task.checkCancellation()
        var display = display; revision &+= 1; display.revision = revision
        guard (64...1920).contains(width),(64...1920).contains(height),width*height<=2_073_600 else { throw CADDocumentError(code:"render_size",message:"Choose a video frame no larger than 1920×1080.") }
        let snapshot = try CADSimulationRenderScene.make(display)
        renderer.scene = snapshot.scene
        if !fitted, snapshot.lo.x.isFinite { fit(boundsMinMM:snapshot.lo,boundsMaxMM:snapshot.hi,width:width,height:height) }
        if let camera = display.camera { try CADSimulationRenderScene.applyCamera(camera,to:&renderer.camera) }
        guard let png = renderer.makeThumbnailPNG(width:width,height:height,showGrid:false) else { throw CADDocumentError(code:"render_failed",message:"The simulation frame could not be rendered.") }
        return png
    }
}
