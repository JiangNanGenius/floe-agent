//
//  PipelineStore.swift
//  openshape3d
//
//  Builds and caches every MTLRenderPipelineState and depth-stencil state.
//  All vertex data is pulled from buffers via vertex_id, so no vertex
//  descriptors are needed.
//

import Foundation
import Metal

final class PipelineStore {
    // Render pipelines
    let background: MTLRenderPipelineState
    let lit: MTLRenderPipelineState
    /// `lit` with the albedo sampled from a per-body texture (imported
    /// OBJ/glTF/USDZ bodies whose meshes carry texcoords).
    let litTextured: MTLRenderPipelineState
    let litTexturedBlended: MTLRenderPipelineState
    let litBlended: MTLRenderPipelineState   // preview bodies (translucent) + x-ray
    let depthOnly: MTLRenderPipelineState    // wireframe hidden-line prepass (no color writes)
    let unlitColor: MTLRenderPipelineState
    let edge: MTLRenderPipelineState
    /// Sketch strokes expanded to screen-space quads (Metal lines are 1px).
    let thickLine: MTLRenderPipelineState
    let grid: MTLRenderPipelineState
    let texturedQuad: MTLRenderPipelineState // Insert Image reference quads
    let blobShadow: MTLRenderPipelineState   // cheap planar ground shadows

    // Depth-stencil states
    let depthReadWrite: MTLDepthStencilState
    let depthReadOnly: MTLDepthStencilState
    let depthIgnore: MTLDepthStencilState
    /// Reversed test for the Show Hidden Edges pass: only fragments BEHIND
    /// the written depth survive.
    let depthGreaterReadOnly: MTLDepthStencilState

    init?(device: MTLDevice, library: MTLLibrary) {
        func makePipeline(
            vertex: String,
            fragment: String,
            blended: Bool,
            writesColor: Bool = true
        ) -> MTLRenderPipelineState? {
            guard let vertexFn = library.makeFunction(name: vertex),
                  let fragmentFn = library.makeFunction(name: fragment)
            else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFn
            descriptor.fragmentFunction = fragmentFn
            descriptor.rasterSampleCount = RenderContext.sampleCount
            descriptor.depthAttachmentPixelFormat = RenderContext.depthPixelFormat
            let color = descriptor.colorAttachments[0]!
            color.pixelFormat = RenderContext.colorPixelFormat
            if !writesColor {
                color.writeMask = []
            }
            if blended {
                color.isBlendingEnabled = true
                color.rgbBlendOperation = .add
                color.alphaBlendOperation = .add
                color.sourceRGBBlendFactor = .sourceAlpha
                color.destinationRGBBlendFactor = .oneMinusSourceAlpha
                color.sourceAlphaBlendFactor = .one
                color.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard
            let background = makePipeline(
                vertex: "vertex_fullscreen", fragment: "fragment_backgroundGradient", blended: false
            ),
            let lit = makePipeline(vertex: "vertex_lit", fragment: "fragment_lit", blended: false),
            let litTextured = makePipeline(
                vertex: "vertex_litTextured", fragment: "fragment_litTextured", blended: false),
            let litTexturedBlended = makePipeline(
                vertex: "vertex_litTextured", fragment: "fragment_litTextured", blended: true),
            let litBlended = makePipeline(vertex: "vertex_lit", fragment: "fragment_lit", blended: true),
            let depthOnly = makePipeline(
                vertex: "vertex_lit", fragment: "fragment_lit", blended: false, writesColor: false
            ),
            let unlitColor = makePipeline(
                vertex: "vertex_unlit", fragment: "fragment_flatColor", blended: true
            ),
            let edge = makePipeline(
                vertex: "vertex_edge", fragment: "fragment_flatColorClipped", blended: true
            ),
            let thickLine = makePipeline(
                vertex: "vertex_thickLine", fragment: "fragment_flatColorClipped", blended: true
            ),
            let grid = makePipeline(vertex: "vertex_grid", fragment: "fragment_grid", blended: true),
            let texturedQuad = makePipeline(
                vertex: "vertex_texturedQuad", fragment: "fragment_texturedQuad", blended: true
            ),
            let blobShadow = makePipeline(
                vertex: "vertex_texturedQuad", fragment: "fragment_blobShadow", blended: true
            )
        else { return nil }

        self.thickLine = thickLine
        self.background = background
        self.lit = lit
        self.litTextured = litTextured
        self.litTexturedBlended = litTexturedBlended
        self.litBlended = litBlended
        self.depthOnly = depthOnly
        self.unlitColor = unlitColor
        self.edge = edge
        self.grid = grid
        self.texturedQuad = texturedQuad
        self.blobShadow = blobShadow

        func makeDepthState(compare: MTLCompareFunction, write: Bool) -> MTLDepthStencilState? {
            let descriptor = MTLDepthStencilDescriptor()
            descriptor.depthCompareFunction = compare
            descriptor.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: descriptor)
        }

        guard
            let depthReadWrite = makeDepthState(compare: .less, write: true),
            let depthReadOnly = makeDepthState(compare: .less, write: false),
            let depthIgnore = makeDepthState(compare: .always, write: false),
            let depthGreaterReadOnly = makeDepthState(compare: .greater, write: false)
        else { return nil }

        self.depthReadWrite = depthReadWrite
        self.depthReadOnly = depthReadOnly
        self.depthIgnore = depthIgnore
        self.depthGreaterReadOnly = depthGreaterReadOnly
    }
}
