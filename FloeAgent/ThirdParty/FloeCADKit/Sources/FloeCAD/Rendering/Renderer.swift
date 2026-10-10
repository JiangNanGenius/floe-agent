//
//  Renderer.swift
//  openshape3d
//
//  Frame orchestration. Pass order in one encoder:
//  background → opaque bodies → feature edges → grid → translucent bodies.
//  (Sketch overlay and gizmo join in later build steps.)
//

import OCCTShim
import Foundation
import Metal
import MetalKit
import simd
import UIKit
import CoreGraphics

final class Renderer: NSObject, MTKViewDelegate {
    let context: RenderContext
    var camera = TurntableCamera()
    /// NDC shift of the on-screen image's centre — the phone palette's safe
    /// area (`ViewportSafeArea`). Set by the viewport coordinator, which picks
    /// and projects with this same value; offscreen captures stay centred.
    var centerOffset: SIMD2<Float> = .zero
    var scene = ViewportScene()

    private let cache = GPUResourceCache()
    private let quadTextures = ImageQuadTextureCache()
    private let bodyTextures = BodyTextureCache()
    private let gizmoRenderer = GizmoRenderer()
    #if DEBUG
    private var didMarkFirstDraw = false
    #endif
    private let orientationCubeRenderer = OrientationCubeRenderer()
    private var viewportSize = CGSize(width: 1, height: 1)

    /// Sketch stroke weight, in DRAWABLE PIXELS (`viewportSize` is the drawable,
    /// so this is already device pixels — ~3pt on a 2× display). Metal lines are
    /// 1px, which reads as a hairline; Shapr3D's sketch strokes are chunky.
    static let sketchStrokeWidthPixels: Float = 6

    /// World-units-per-gizmo-unit for constant ~screen size, shared by
    /// rendering and hit-testing.
    func gizmoScale(origin: SIMD3<Float>) -> Float {
        simd_length(camera.position - origin) * tan(camera.fovY * 0.5) * 0.24
    }

    init(context: RenderContext) {
        self.context = context
        super.init()
    }

    /// Called when the viewport is laid out or resized (rotation, split view).
    /// The coordinator uses it to re-publish the camera, since every SwiftUI
    /// overlay that projects world points is sized off this view.
    var viewportSizeChanged: (() -> Void)?

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if size.width > 0, size.height > 0 {
            viewportSize = size
            viewportSizeChanged?()
            // Rendering is paused/on-demand. Rotation can otherwise stretch
            // the previous drawable while SwiftUI markers already project
            // against the new bounds, until an unrelated scene action redraws.
            view.setNeedsDisplay()
        }
    }

    func draw(in view: MTKView) {
        #if DEBUG
        if !didMarkFirstDraw { didMarkFirstDraw = true; OpenTiming.mark("first draw") }
        #endif
        guard
            let descriptor = view.currentRenderPassDescriptor,
            let commandBuffer = context.commandQueue.makeCommandBuffer()
        else { return }

        // Every frame ends in a second overlay pass (cleared depth): the
        // orientation cube always, plus gizmo/pull arrow/plane pickers when
        // present. Keep the MSAA color texture and resolve at the end.
        let msaaColor = descriptor.colorAttachments[0].texture
        let resolveTarget = descriptor.colorAttachments[0].resolveTexture
        // A pass with a resolveTexture attached must use a resolving store
        // action (Metal validation asserts otherwise) — detach it here and
        // resolve in the overlay pass instead.
        descriptor.colorAttachments[0].resolveTexture = nil
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.depthAttachment.storeAction = .dontCare

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        cache.sync(with: scene, device: context.device)
        quadTextures.sync(quads: scene.imageQuads, device: context.device)
        bodyTextures.sync(bodies: scene.bodies, device: context.device)

        var frame = makeFrameUniforms()
        encodeScene(encoder: encoder, frame: &frame)
        encoder.endEncoding()

        // Overlays are never sectioned (they use the unclipped flat-color
        // fragment shader, but keep the uniforms honest too).
        frame.clipEnabled = 0

        // 6. Overlay pass: depth cleared so overlays draw on top.
        if let msaaColor {
            let overlay = MTLRenderPassDescriptor()
            overlay.colorAttachments[0].texture = msaaColor
            overlay.colorAttachments[0].loadAction = .load
            if let resolveTarget {
                overlay.colorAttachments[0].resolveTexture = resolveTarget
                overlay.colorAttachments[0].storeAction = .multisampleResolve
            } else {
                overlay.colorAttachments[0].storeAction = .store
            }
            overlay.depthAttachment.texture = descriptor.depthAttachment.texture
            overlay.depthAttachment.loadAction = .clear
            overlay.depthAttachment.storeAction = .dontCare
            overlay.depthAttachment.clearDepth = 1

            if let overlayEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: overlay) {
                gizmoRenderer.prepare(device: context.device)
                if var gizmo = scene.gizmo {
                    gizmo.scale = gizmoScale(origin: gizmo.origin)
                    gizmoRenderer.draw(
                        encoder: overlayEncoder,
                        pipelines: context.pipelines,
                        frame: &frame,
                        gizmo: gizmo
                    )
                }
                if !scene.planePickers.isEmpty {
                    // Origin tiles keep a constant on-screen size: resolve
                    // them here with the same gizmo unit the hit test uses.
                    let tiles = scene.planePickers.map { tile -> PlanePickerTile in
                        guard tile.screenProportional else { return tile }
                        let o = tile.plane.origin
                        let origin = SIMD3<Float>(Float(o.x), Float(o.y), Float(o.z))
                        return tile.scaled(by: PlanePicking.originTileScale(
                            gizmoUnit: Double(gizmoScale(origin: origin))))
                    }
                    gizmoRenderer.drawPlaneTiles(
                        encoder: overlayEncoder,
                        pipelines: context.pipelines,
                        frame: &frame,
                        tiles: tiles
                    )
                }
                // The pull handle is drawn as an always-on-top SwiftUI SF Symbol
                // overlay (ExtrudeGizmoOverlay), not in the 3D pass — so it stays
                // visible when the cap dips below/behind a surface. `scene.pullArrow`
                // is still populated for the geometric grab hit-test.
                // Orientation cube (spec §7.2), always on. Layout math is in
                // points so its NDC placement matches tap hit-testing.
                orientationCubeRenderer.prepare(device: context.device)
                orientationCubeRenderer.draw(
                    encoder: overlayEncoder,
                    pipelines: context.pipelines,
                    camera: camera,
                    viewSize: view.bounds.size
                )
                overlayEncoder.endEncoding()
            }
        }

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    /// Everything except the gizmo overlay — shared by live drawing and
    /// offscreen thumbnail/screenshot capture. `drawBackground`/`drawGrid`
    /// support screenshot options (transparent background, grid off).
    ///
    /// `renderScene`/`renderCamera` default to the live state; the canvas
    /// snapshot path passes a SNAPSHOT scene and a local fitted camera, so the
    /// encode never observes or changes the live viewport framing.
    private func encodeScene(
        encoder: MTLRenderCommandEncoder,
        frame: inout FrameUniforms,
        drawBackground: Bool = true,
        drawGrid: Bool = true,
        renderScene: ViewportScene? = nil
    ) {
        let pipelines = context.pipelines
        let scene = renderScene ?? self.scene
        let mode = scene.displayMode

        // 1. Background gradient
        if drawBackground {
            encoder.setRenderPipelineState(pipelines.background)
            encoder.setDepthStencilState(pipelines.depthIgnore)
            encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                                     index: Int(BufferIndexFrameUniforms.rawValue))
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // Frame uniforms for both stages up front; the fragment binding feeds
        // the section clip test in the edge/fill/sketch shaders.
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                               index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                                 index: Int(BufferIndexFrameUniforms.rawValue))

        // 1b. Ground blob shadows, before any body fragments land.
        if scene.groundShadow {
            drawGroundShadows(encoder: encoder, renderScene: scene)
        }

        // 2. Opaque bodies. Wireframe swaps the fill for a depth-only prepass
        // so hidden lines stay hidden; x-ray defers every body to the
        // translucent pass (6).
        switch mode {
        case .shaded, .shadedNoEdges:
            encoder.setDepthStencilState(pipelines.depthReadWrite)
            for drawable in scene.bodies where !drawable.isTranslucent {
                drawBody(drawable, encoder: encoder, pipeline: pipelines.lit, frame: frame)
            }
        case .wireframe:
            encoder.setDepthStencilState(pipelines.depthReadWrite)
            for drawable in scene.bodies where !drawable.isTranslucent {
                drawBody(drawable, encoder: encoder, pipeline: pipelines.depthOnly, frame: frame)
            }
        case .xray:
            break
        }

        // 3. Feature edges (+ optional hidden-edge pass, reversed depth test)
        if mode != .shadedNoEdges {
            encoder.setRenderPipelineState(pipelines.edge)
            encoder.setDepthStencilState(pipelines.depthReadOnly)
            for drawable in scene.bodies where !drawable.isTranslucent {
                drawEdges(drawable, encoder: encoder, frame: frame)
            }
            if scene.showHiddenEdges {
                encoder.setDepthStencilState(pipelines.depthGreaterReadOnly)
                for drawable in scene.bodies where !drawable.isTranslucent {
                    drawEdges(drawable, encoder: encoder, alphaScale: 0.25, frame: frame)
                }
            }
        }

        // 4. Active sketch grid, or ground in modeling (blended, depth read only)
        if drawGrid {
            encoder.setRenderPipelineState(pipelines.grid)
            encoder.setDepthStencilState(pipelines.depthReadOnly)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        // 4a. Image quads (Insert Image): blended, depth read, no depth write.
        if !scene.imageQuads.isEmpty {
            drawImageQuads(encoder: encoder, renderScene: scene)
        }

        // 4b. Closed-profile fills (edge pipeline reused for its depth bias so
        // fills win against coplanar body faces; blended, no depth write)
        if !scene.profileFills.isEmpty {
            encoder.setRenderPipelineState(pipelines.edge)
            encoder.setDepthStencilState(pipelines.depthReadOnly)
            for batch in scene.profileFills where !batch.triangles.isEmpty {
                var body = BodyUniforms()
                body.modelMatrix = matrix_identity_float4x4
                body.baseColor = batch.color
                let length = batch.triangles.count * MemoryLayout<SIMD3<Float>>.stride
                guard let buffer = batch.triangles.withUnsafeBytes({ raw in
                    context.device.makeBuffer(bytes: raw.baseAddress!, length: length,
                                              options: .storageModeShared)
                }) else { continue }
                encoder.setVertexBuffer(buffer, offset: 0, index: Int(BufferIndexPositions.rawValue))
                encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                       index: Int(BufferIndexBodyUniforms.rawValue))
                encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                         index: Int(BufferIndexBodyUniforms.rawValue))
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: batch.triangles.count)
            }
        }

        // 5. Sketch overlay strokes. Drawn with the THICK-line pipeline: Metal's
        // line primitive is 1px (a hairline on Retina), and a sketch on a solid's
        // face is coplanar with it, so the hairline also lost the depth fight and
        // the stroke would vanish. The quad expansion carries a bigger bias.
        if !scene.sketchLines.isEmpty {
            encoder.setRenderPipelineState(pipelines.thickLine)
            encoder.setDepthStencilState(pipelines.depthReadOnly)
            for batch in scene.sketchLines where !batch.segments.isEmpty {
                var body = BodyUniforms()
                body.modelMatrix = matrix_identity_float4x4
                body.baseColor = batch.color
                body.lineHalfWidthPx = Self.sketchStrokeWidthPixels / 2
                let length = batch.segments.count * MemoryLayout<SIMD3<Float>>.stride
                guard let buffer = batch.segments.withUnsafeBytes({ raw in
                    context.device.makeBuffer(bytes: raw.baseAddress!, length: length,
                                              options: .storageModeShared)
                }) else { continue }
                encoder.setVertexBuffer(buffer, offset: 0, index: Int(BufferIndexPositions.rawValue))
                encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                       index: Int(BufferIndexBodyUniforms.rawValue))
                encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                         index: Int(BufferIndexBodyUniforms.rawValue))
                // 2 endpoints per segment → 6 quad vertices per segment.
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: batch.segments.count / 2 * 6)
            }
        }

        // 6. Translucent bodies (previews) last; in x-ray every body renders
        // here at a fixed low alpha (depth read, no write).
        for drawable in scene.bodies where drawable.isTranslucent || mode == .xray {
            encoder.setDepthStencilState(pipelines.depthReadOnly)
            let xrayAlpha: Float? = (mode == .xray && !drawable.isTranslucent) ? 0.35 : nil
            drawBody(drawable, encoder: encoder, pipeline: pipelines.litBlended,
                     alphaOverride: xrayAlpha, frame: frame)
        }
    }

    /// Insert-Image reference quads: textured, blended, both windings so the
    /// image reads from either side (mirrored from the back, like paper).
    private func drawImageQuads(encoder: MTLRenderCommandEncoder, renderScene: ViewportScene) {
        encoder.setRenderPipelineState(context.pipelines.texturedQuad)
        encoder.setDepthStencilState(context.pipelines.depthReadOnly)
        for quad in renderScene.imageQuads {
            guard let texture = quadTextures.texture(for: quad.id) else { continue }
            let hx = quad.xAxis * (quad.width * 0.5)
            let hy = quad.yAxis * (quad.height * 0.5)
            let c0 = quad.origin - hx - hy // bottom-left
            let c1 = quad.origin + hx - hy // bottom-right
            let c2 = quad.origin + hx + hy // top-right
            let c3 = quad.origin - hx + hy // top-left
            let positions: [SIMD3<Float>] = [
                c0, c1, c2, c0, c2, c3,
                c0, c2, c1, c0, c3, c2,
            ]
            // Image v runs top-down: v=0 at the top edge (c3/c2).
            let u0 = SIMD2<Float>(0, 1), u1 = SIMD2<Float>(1, 1)
            let u2 = SIMD2<Float>(1, 0), u3 = SIMD2<Float>(0, 0)
            let uvs: [SIMD2<Float>] = [
                u0, u1, u2, u0, u2, u3,
                u0, u2, u1, u0, u3, u2,
            ]

            var body = BodyUniforms()
            body.modelMatrix = matrix_identity_float4x4
            body.baseColor = SIMD4(1, 1, 1, max(0, min(1, quad.opacity)))
            positions.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count,
                                       index: Int(BufferIndexPositions.rawValue))
            }
            uvs.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count,
                                       index: Int(BufferIndexTexcoords.rawValue))
            }
            encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                     index: Int(BufferIndexBodyUniforms.rawValue))
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: positions.count)
        }
    }

    /// Cheap planar blob shadows (visualization v1): one soft dark ellipse on
    /// the ground plane under each opaque body's AABB, fading as the body
    /// lifts off the ground.
    private func drawGroundShadows(encoder: MTLRenderCommandEncoder, renderScene: ViewportScene) {
        encoder.setRenderPipelineState(context.pipelines.blobShadow)
        encoder.setDepthStencilState(context.pipelines.depthReadOnly)
        for drawable in renderScene.bodies where !drawable.isTranslucent {
            let aabb = drawable.renderMesh.localAABB
            var lo = SIMD3<Float>(.greatestFiniteMagnitude, .greatestFiniteMagnitude,
                                  .greatestFiniteMagnitude)
            var hi = -lo
            for i in 0..<8 {
                let corner = SIMD3<Float>(
                    (i & 1) == 0 ? aabb.min.x : aabb.max.x,
                    (i & 2) == 0 ? aabb.min.y : aabb.max.y,
                    (i & 4) == 0 ? aabb.min.z : aabb.max.z
                )
                let world4 = drawable.modelMatrix * SIMD4(corner, 1)
                let world = SIMD3(world4.x, world4.y, world4.z)
                lo = simd_min(lo, world)
                hi = simd_max(hi, world)
            }
            let rx = max((hi.x - lo.x) * 0.5, 1e-3) * 1.25
            let rz = max((hi.z - lo.z) * 0.5, 1e-3) * 1.25
            let cx = (lo.x + hi.x) * 0.5
            let cz = (lo.z + hi.z) * 0.5
            let lift = max(lo.y, 0)
            let footprint = max(rx, rz)
            // Slight lift above y=0 to dodge z-fighting with coplanar faces.
            let y: Float = 0.002
            let c0 = SIMD3<Float>(cx - rx, y, cz - rz)
            let c1 = SIMD3<Float>(cx + rx, y, cz - rz)
            let c2 = SIMD3<Float>(cx + rx, y, cz + rz)
            let c3 = SIMD3<Float>(cx - rx, y, cz + rz)
            let positions: [SIMD3<Float>] = [c0, c1, c2, c0, c2, c3]
            let uvs: [SIMD2<Float>] = [
                SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1),
                SIMD2(0, 0), SIMD2(1, 1), SIMD2(0, 1),
            ]

            var body = BodyUniforms()
            body.modelMatrix = matrix_identity_float4x4
            let strength: Float = 0.30 / (1 + lift / max(footprint, 1e-3))
            body.baseColor = SIMD4(0.05, 0.06, 0.08, strength)
            positions.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count,
                                       index: Int(BufferIndexPositions.rawValue))
            }
            uvs.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count,
                                       index: Int(BufferIndexTexcoords.rawValue))
            }
            encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                     index: Int(BufferIndexBodyUniforms.rawValue))
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: positions.count)
        }
    }

    // MARK: - Thumbnail capture

    /// Offscreen render of an INDEPENDENT scene snapshot, returned as PNG data.
    ///
    /// This is the canvas-node thumbnail entry point and, unlike
    /// `makeThumbnailPNG(width:height:transparentBackground:showGrid:)`, it
    /// never reads or writes this renderer's live camera: it builds a LOCAL
    /// turntable camera fitted to the SNAPSHOT bounds and renders with that.
    /// The viewport passed for thumbnail capture is a detached, offscreen
    /// MTKView whose `Renderer` has never owned a live editor, so calling this
    /// against the live viewport is also harmless — the live camera, the
    /// viewport-size callback and the orientation-cube overlay are all
    /// untouched. No gizmo/overlay pass runs (the canvas preview shows bodies,
    /// edges, grid and assembly instances only).
    func makeSceneSnapshotPNG(
        _ snapshot: ViewportScene,
        width: Int = 640,
        height: Int = 480
    ) -> Data? {
        guard width > 0, height > 0 else { return nil }
        // A private fitted camera: frames the snapshot bounds isometrically
        // without mutating `self.camera` or invoking `viewportSizeChanged`.
        var snapshotCamera = TurntableCamera()
        if let bounds = snapshot.worldBounds {
            snapshotCamera.fit(boundsMin: bounds.min, boundsMax: bounds.max,
                               aspect: Float(width) / Float(height))
        }
        return renderPNG(scene: snapshot, camera: snapshotCamera,
                         width: width, height: height,
                         transparentBackground: false, showGrid: true)
    }

    /// Offscreen render of the current scene (no gizmo), returned as PNG data.
    /// Screenshot options: `transparentBackground` clears to alpha 0 and skips
    /// the gradient pass; `showGrid` off skips the ground grid.
    ///
    /// This renders with the renderer's OWN camera and exists for the live
    /// workbench screenshot/thumbnail providers (where the renderer IS the
    /// on-screen viewport). Canvas previews must use
    /// `makeSceneSnapshotPNG`, which fits an independent camera and so can
    /// never change the framing the user is looking at.
    func makeThumbnailPNG(
        width: Int = 640,
        height: Int = 480,
        transparentBackground: Bool = false,
        showGrid: Bool = true
    ) -> Data? {
        renderPNG(scene: scene, camera: camera, width: width, height: height,
                  transparentBackground: transparentBackground, showGrid: showGrid)
    }

    /// Shared offscreen encoder. It renders the supplied scene with the
    /// supplied camera into private multisample/resolve textures and reads the
    /// pixels back as PNG. The caller decides whether that camera is the live
    /// one (screenshot) or a local fitted snapshot camera (canvas thumbnail),
    /// which is what keeps thumbnail capture from re-framing the editor.
    private func renderPNG(
        scene: ViewportScene,
        camera: TurntableCamera,
        width: Int,
        height: Int,
        transparentBackground: Bool,
        showGrid: Bool
    ) -> Data? {
        let device = context.device

        let colorDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderContext.colorPixelFormat, width: width, height: height, mipmapped: false
        )
        colorDescriptor.textureType = .type2DMultisample
        colorDescriptor.sampleCount = RenderContext.sampleCount
        colorDescriptor.usage = [.renderTarget]
        colorDescriptor.storageMode = .private

        let resolveDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderContext.colorPixelFormat, width: width, height: height, mipmapped: false
        )
        resolveDescriptor.usage = [.renderTarget, .shaderRead]
        resolveDescriptor.storageMode = .shared

        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderContext.depthPixelFormat, width: width, height: height, mipmapped: false
        )
        depthDescriptor.textureType = .type2DMultisample
        depthDescriptor.sampleCount = RenderContext.sampleCount
        depthDescriptor.usage = [.renderTarget]
        depthDescriptor.storageMode = .private

        guard
            let colorTexture = device.makeTexture(descriptor: colorDescriptor),
            let resolveTexture = device.makeTexture(descriptor: resolveDescriptor),
            let depthTexture = device.makeTexture(descriptor: depthDescriptor),
            let commandBuffer = context.commandQueue.makeCommandBuffer()
        else {
            NSLog("[openshape3d] thumbnail: texture/commandBuffer creation failed")
            return nil
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].resolveTexture = resolveTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.colorAttachments[0].clearColor = transparentBackground
            ? MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            : MTLClearColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            NSLog("[openshape3d] thumbnail: encoder creation failed")
            return nil
        }

        cache.sync(with: scene, device: context.device)
        quadTextures.sync(quads: scene.imageQuads, device: context.device)
        bodyTextures.sync(bodies: scene.bodies, device: context.device)
        var frame = makeFrameUniforms(
            scene: scene,
            camera: camera,
            viewportSize: CGSize(width: width, height: height))
        encodeScene(
            encoder: encoder,
            frame: &frame,
            drawBackground: !transparentBackground,
            drawGrid: showGrid,
            renderScene: scene
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // Read back BGRA and wrap as PNG.
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        pixels.withUnsafeMutableBytes { raw in
            resolveTexture.getBytes(
                raw.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard
            let providerData = CFDataCreate(nil, pixels, pixels.count),
            let provider = CGDataProvider(data: providerData),
            let image = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                provider: provider, decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
            )
        else {
            NSLog("[openshape3d] thumbnail: CGImage creation failed")
            return nil
        }
        return UIImage(cgImage: image).pngData()
    }

    // MARK: - Draw helpers

    private func drawBody(
        _ drawable: BodyDrawable,
        encoder: MTLRenderCommandEncoder,
        pipeline: MTLRenderPipelineState,
        alphaOverride: Float? = nil,
        frame: FrameUniforms? = nil
    ) {
        guard let resources = cache.resources(for: drawable.id) else { return }
        // An imported body with a texture and texcoords shades through the
        // textured twin of the requested lit pipeline; depth-only and other
        // passes keep the pipeline they asked for.
        var chosen = pipeline
        if let texcoords = resources.texcoordBuffer,
           let texture = bodyTextures.texture(for: drawable.id) {
            if pipeline === context.pipelines.lit {
                chosen = context.pipelines.litTextured
            } else if pipeline === context.pipelines.litBlended {
                chosen = context.pipelines.litTexturedBlended
            }
            if chosen !== pipeline {
                encoder.setVertexBuffer(texcoords, offset: 0,
                                        index: Int(BufferIndexTexcoords.rawValue))
                encoder.setFragmentTexture(texture, index: 0)
            }
        }
        encoder.setRenderPipelineState(chosen)
        var body = makeBodyUniforms(drawable)
        if let alphaOverride {
            body.baseColor.w = alphaOverride
        }
        encoder.setVertexBuffer(resources.positionBuffer, offset: 0,
                                index: Int(BufferIndexPositions.rawValue))
        encoder.setVertexBuffer(resources.normalBuffer, offset: 0,
                                index: Int(BufferIndexNormals.rawValue))
        encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                               index: Int(BufferIndexBodyUniforms.rawValue))
        encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                 index: Int(BufferIndexBodyUniforms.rawValue))
        // Reuse the frame already bound for this encode: a snapshot encode's
        // frame carries the independent fitted camera, so per-draw lighting
        // must not rebuild one from the live camera.
        var drawFrame = frame ?? makeFrameUniforms()
        encoder.setFragmentBytes(&drawFrame, length: MemoryLayout<FrameUniforms>.stride,
                                 index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: resources.indexCount,
            indexType: .uint32,
            indexBuffer: resources.indexBuffer,
            indexBufferOffset: 0
        )
    }

    private func drawEdges(
        _ drawable: BodyDrawable,
        encoder: MTLRenderCommandEncoder,
        alphaScale: Float = 1,
        frame: FrameUniforms? = nil
    ) {
        guard let resources = cache.resources(for: drawable.id),
              let edgeBuffer = resources.edgeVertexBuffer,
              resources.edgeVertexCount > 0
        else { return }
        var body = makeBodyUniforms(drawable)
        let selected = drawable.selectionState == SelectionStateSelected.rawValue
        body.baseColor = selected
            ? (frame?.accentColor ?? makeFrameUniforms().accentColor)
            : SIMD4(0.13, 0.15, 0.17, 1)
        body.baseColor.w *= alphaScale
        encoder.setVertexBuffer(edgeBuffer, offset: 0, index: Int(BufferIndexPositions.rawValue))
        encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                               index: Int(BufferIndexBodyUniforms.rawValue))
        encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                 index: Int(BufferIndexBodyUniforms.rawValue))
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: resources.edgeVertexCount)
    }

    // MARK: - Uniforms

    private func makeFrameUniforms(viewportSize: CGSize? = nil) -> FrameUniforms {
        makeFrameUniforms(scene: scene, camera: camera, viewportSize: viewportSize,
                          centerOffsetOverride: nil)
    }

    /// Frame uniforms for an explicit scene/camera. The canvas snapshot path
    /// uses this so a thumbnail can never read the live camera (and so can
    /// neither re-frame the editor nor feed it a changed viewport).
    private func makeFrameUniforms(
        scene: ViewportScene,
        camera: TurntableCamera,
        viewportSize: CGSize?,
        centerOffsetOverride: SIMD2<Float>? = nil
    ) -> FrameUniforms {
        // An explicit size is an offscreen capture: no palette sits over it.
        let centerOffset = centerOffsetOverride
            ?? (viewportSize == nil ? self.centerOffset : .zero)
        let viewportSize = viewportSize ?? self.viewportSize
        let aspect = Float(viewportSize.width / max(viewportSize.height, 1))
        let cameraPosition = camera.position

        // Headlight: key light fixed relative to the camera, offset up and left,
        // so the model never goes dark while orbiting.
        let view = camera.viewMatrix
        let right = SIMD3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let up = SIMD3(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        let forward = simd_normalize(camera.target - cameraPosition)
        let lightDirection = simd_normalize(forward + right * 0.35 - up * 0.45)

        var frame = FrameUniforms()
        frame.viewProjectionMatrix = camera.viewProjection(aspect: aspect, centerOffset: centerOffset)
        frame.cameraPosition = SIMD4(cameraPosition, 1)
        frame.keyLightDirection = SIMD4(lightDirection, 0)
        frame.skyColor = SIMD4(1.0, 1.0, 1.05, 1)
        frame.groundColor = SIMD4(0.62, 0.60, 0.58, 1)
        frame.backgroundTop = SIMD4(0.94, 0.95, 0.97, 1)
        frame.backgroundBottom = SIMD4(0.82, 0.84, 0.88, 1)
        frame.accentColor = SIMD4(0.0, 0.52, 1.0, 1) // Shapr3D selection blue
        // The grid follows the zoom (bug report abb6ea37): at a fixed 1 mm
        // pitch and 120 mm fade radius it vanished as soon as the view pulled
        // back to metre scale. The pitch steps by decades so the view always
        // holds on the order of ten to a hundred minor lines, and the fade
        // radius grows with the camera distance so the plane never runs out
        // under a large model. Majors stay every tenth minor.
        let viewHeightMM = 2 * Double(camera.distance) * tan(Double(camera.fovY) * 0.5)
        let decade = floor(log10(max(viewHeightMM / 8, 1e-6)))
        let minorSpacing = Float(min(max(pow(10, decade), 1e-3), 1e6))
        let fadeRadius = max(120, camera.distance * 10)
        frame.gridParams = SIMD4(minorSpacing, 10, fadeRadius, 0)
        let gridPlane = scene.gridPlane ?? .ground
        let gridCenter = gridPlane.toWorld(gridPlane.toLocal(SIMD3<Double>(camera.target)))
        frame.gridCenter = SIMD4(SIMD3<Float>(gridCenter), 0)
        frame.gridOrigin = SIMD4(SIMD3<Float>(gridPlane.origin), 0)
        frame.gridXAxis = SIMD4(SIMD3<Float>(gridPlane.xAxis), 0)
        frame.gridYAxis = SIMD4(SIMD3<Float>(gridPlane.yAxis), 0)
        frame.edgeDepthBiasNDC = 1e-4
        frame.viewportWidth = Float(max(viewportSize.width, 1))
        frame.viewportHeight = Float(max(viewportSize.height, 1))

        // Section view: fragments beyond the plane are discarded (spec §16.1).
        if let section = scene.sectionPlane, section.enabled {
            let plane = section.clipVector
            if plane != .zero {
                frame.clipPlane = plane
                frame.clipEnabled = 1
            }
        }
        return frame
    }

    private func makeBodyUniforms(_ drawable: BodyDrawable) -> BodyUniforms {
        var body = BodyUniforms()
        body.modelMatrix = drawable.modelMatrix
        body.baseColor = drawable.baseColor
        body.selectionState = drawable.selectionState
        // Visualization-lite material: zero metallic/roughness (the C-struct
        // default) keeps the legacy shading path in fragment_lit.
        if let material = drawable.material {
            body.baseColor = material.baseColor
            body.metallic = material.metallic
            body.roughness = material.roughness
        }
        return body
    }
}
