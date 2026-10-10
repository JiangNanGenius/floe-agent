//
//  GizmoRenderer.swift
//  openshape3d
//
//  Procedural move-gizmo mesh (XYZ arrows + three quarter-plane handles),
//  built once in gizmo-local space and drawn in an overlay pass with cleared
//  depth so it always sits on top of the model.
//

import OCCTShim
import Foundation
import Metal
import simd

final class GizmoRenderer {
    private struct Part {
        let part: GizmoPart?   // nil = non-interactive (centre dot)
        let vertexRange: Range<Int>
        let color: SIMD4<Float>
    }

    private var vertexBuffer: MTLBuffer?
    private var parts: [Part] = []

    // Shapr3D-style monochrome gizmo: white translate/rotate handles, white
    // plane tiles, a cyan centre dot. Axis identity comes from position, not
    // colour (matches the reference).
    private static let handleWhite = SIMD4<Float>(0.97, 0.97, 0.99, 1)
    private static let planeWhite = SIMD4<Float>(0.97, 0.97, 0.99, 0.5)
    private static let centerCyan = SIMD4<Float>(0.20, 0.80, 0.85, 1)

    private static let colors: [GizmoPart: SIMD4<Float>] = [
        .xAxis: handleWhite, .yAxis: handleWhite, .zAxis: handleWhite,
        .yzPlane: planeWhite, .zxPlane: planeWhite, .xyPlane: planeWhite,
        .xRing: handleWhite, .yRing: handleWhite, .zRing: handleWhite,
    ]

    func prepare(device: MTLDevice) {
        guard vertexBuffer == nil else { return }
        var vertices: [SIMD3<Float>] = []
        var built: [Part] = []

        for part in [GizmoPart.xAxis, .yAxis, .zAxis] {
            let start = vertices.count
            appendArrow(along: part.axisDirection, into: &vertices)
            built.append(Part(part: part, vertexRange: start..<vertices.count,
                              color: Self.colors[part]!))
        }
        for part in [GizmoPart.xyPlane, .yzPlane, .zxPlane] {
            let start = vertices.count
            appendPlaneHandle(normalAxis: part, into: &vertices)
            built.append(Part(part: part, vertexRange: start..<vertices.count,
                              color: Self.colors[part]!))
        }
        for part in [GizmoPart.xRing, .yRing, .zRing] {
            let start = vertices.count
            appendRotationGlyph(around: part, into: &vertices)
            built.append(Part(part: part, vertexRange: start..<vertices.count,
                              color: Self.colors[part]!))
        }
        // Centre dot (free-move pivot) — non-interactive (nil part).
        let dotStart = vertices.count
        appendCenterDot(into: &vertices)
        built.append(Part(part: nil, vertexRange: dotStart..<vertices.count,
                          color: Self.centerCyan))

        vertexBuffer = vertices.withUnsafeBytes { raw in
            device.makeBuffer(
                bytes: raw.baseAddress!,
                length: vertices.count * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared
            )
        }
        parts = built
    }

    func draw(
        encoder: MTLRenderCommandEncoder,
        pipelines: PipelineStore,
        frame: inout FrameUniforms,
        gizmo: GizmoState
    ) {
        guard let vertexBuffer else { return }

        var model = matrix_identity_float4x4
        model.columns.0 *= gizmo.scale
        model.columns.1 *= gizmo.scale
        model.columns.2 *= gizmo.scale
        model.columns.3 = SIMD4(gizmo.origin, 1)

        encoder.setRenderPipelineState(pipelines.unlitColor)
        encoder.setDepthStencilState(pipelines.depthReadWrite)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: Int(BufferIndexPositions.rawValue))
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                               index: Int(BufferIndexFrameUniforms.rawValue))

        for part in parts {
            var body = BodyUniforms()
            body.modelMatrix = model
            var color = part.color
            if let p = part.part, gizmo.highlighted == p {
                // Highlight in Shapr3D blue (arrows/handles are white).
                color = SIMD4(0.20, 0.55, 0.95, 1)
            }
            body.baseColor = color
            encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                   index: Int(BufferIndexBodyUniforms.rawValue))
            encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                     index: Int(BufferIndexBodyUniforms.rawValue))
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: part.vertexRange.lowerBound,
                vertexCount: part.vertexRange.count
            )
        }
    }

    /// Plane picker tiles: translucent bordered quads in world space. Tiny
    /// vertex payloads, so setVertexBytes instead of buffers.
    func drawPlaneTiles(
        encoder: MTLRenderCommandEncoder,
        pipelines: PipelineStore,
        frame: inout FrameUniforms,
        tiles: [PlanePickerTile]
    ) {
        guard !tiles.isEmpty else { return }
        encoder.setRenderPipelineState(pipelines.unlitColor)
        encoder.setDepthStencilState(pipelines.depthReadWrite)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                               index: Int(BufferIndexFrameUniforms.rawValue))

        for tile in tiles {
            let c = tile.worldCorners
            // Both windings so the quad is visible from either side.
            let triangles: [SIMD3<Float>] = [
                c[0], c[1], c[2], c[0], c[2], c[3],
                c[0], c[2], c[1], c[0], c[3], c[2],
            ]
            let border: [SIMD3<Float>] = [c[0], c[1], c[1], c[2], c[2], c[3], c[3], c[0]]

            var body = BodyUniforms()
            body.modelMatrix = matrix_identity_float4x4
            body.baseColor = tile.color
            encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                   index: Int(BufferIndexBodyUniforms.rawValue))
            encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                     index: Int(BufferIndexBodyUniforms.rawValue))
            triangles.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count,
                                       index: Int(BufferIndexPositions.rawValue))
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: triangles.count)

            body.baseColor = SIMD4(tile.color.x, tile.color.y, tile.color.z, 1)
            encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                   index: Int(BufferIndexBodyUniforms.rawValue))
            encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                     index: Int(BufferIndexBodyUniforms.rawValue))
            border.withUnsafeBytes { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: raw.count,
                                       index: Int(BufferIndexPositions.rawValue))
            }
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: border.count)
        }
    }

    // MARK: - Mesh generation (gizmo-local space, unit length arrows)

    private func appendArrow(along axis: SIMD3<Float>, into vertices: inout [SIMD3<Float>]) {
        // A tight cluster, but with a chunky arrowhead that is easy to grab.
        let shaftRadius: Float = 0.016
        let shaftLength: Float = 0.60
        let coneRadius: Float = 0.075
        let coneLength: Float = 0.24
        let segments = 16

        let (u, v) = perpendicularBasis(for: axis)

        func ring(radius: Float, at distance: Float) -> [SIMD3<Float>] {
            (0..<segments).map { i in
                let angle = Float(i) / Float(segments) * 2 * .pi
                return axis * distance + (u * cos(angle) + v * sin(angle)) * radius
            }
        }

        let base = ring(radius: shaftRadius, at: 0)
        let top = ring(radius: shaftRadius, at: shaftLength)
        let coneBase = ring(radius: coneRadius, at: shaftLength)
        let tip = axis * (shaftLength + coneLength)

        for i in 0..<segments {
            let j = (i + 1) % segments
            // Shaft side quad
            vertices.append(contentsOf: [base[i], top[i], top[j]])
            vertices.append(contentsOf: [base[i], top[j], base[j]])
            // Cone base cap
            vertices.append(contentsOf: [axis * shaftLength, coneBase[j], coneBase[i]])
            // Cone side
            vertices.append(contentsOf: [coneBase[i], coneBase[j], tip])
        }
    }

    private func appendPlaneHandle(normalAxis part: GizmoPart, into vertices: inout [SIMD3<Float>]) {
        let lo = GizmoGeometry.planeMin
        let hi = GizmoGeometry.planeMax
        let corners: [SIMD2<Float>] = [
            SIMD2(lo, lo), SIMD2(hi, lo), SIMD2(hi, hi), SIMD2(lo, hi),
        ]
        func lift(_ p: SIMD2<Float>) -> SIMD3<Float> {
            switch part {
            case .xyPlane: SIMD3(p.x, p.y, 0)
            case .yzPlane: SIMD3(0, p.x, p.y)
            case .zxPlane: SIMD3(p.y, 0, p.x)
            default: .zero
            }
        }
        let c = corners.map(lift)
        // Both windings so the quad is visible from either side.
        vertices.append(contentsOf: [c[0], c[1], c[2]])
        vertices.append(contentsOf: [c[0], c[2], c[3]])
        vertices.append(contentsOf: [c[0], c[2], c[1]])
        vertices.append(contentsOf: [c[0], c[3], c[2]])
    }

    /// A bold curved rotation arrow in the ring's plane — Shapr3D's rotation
    /// affordance. A thick ~90° arc with a clear arrowhead at each end, sized
    /// to be an obvious grab target (the tiny old glyph was the complaint). The
    /// hit test still uses the full circle at `ringRadius` (forgiving for touch).
    private func appendRotationGlyph(around part: GizmoPart, into vertices: inout [SIMD3<Float>]) {
        let r = GizmoGeometry.ringRadius
        let half: Float = 0.03             // band half-thickness (was 0.014)
        let (u, v) = GizmoGeometry.ringBasis(for: part)
        // A quarter-turn arc, centred at 45° so it sits in the gap between two
        // axes rather than crossing an arrow.
        let center: Float = .pi / 4
        let span: Float = 90 * .pi / 180
        // Leave room at the ends for the arrowheads so the band doesn't poke
        // through them.
        let headArc: Float = 12 * .pi / 180
        let a0 = center - span / 2, a1 = center + span / 2
        let bandStart = a0 + headArc, bandEnd = a1 - headArc
        let steps = 20
        func dir(_ a: Float) -> SIMD3<Float> { u * cos(a) + v * sin(a) }

        for i in 0..<steps {
            let t0 = bandStart + (bandEnd - bandStart) * Float(i) / Float(steps)
            let t1 = bandStart + (bandEnd - bandStart) * Float(i + 1) / Float(steps)
            let d0 = dir(t0), d1 = dir(t1)
            let c0 = d0 * (r - half), c1 = d0 * (r + half)
            let c2 = d1 * (r + half), c3 = d1 * (r - half)
            vertices.append(contentsOf: [c0, c1, c2, c0, c2, c3])
            vertices.append(contentsOf: [c0, c2, c1, c0, c3, c2])
        }
        // A broad, flat tangential arrowhead at each arc end.
        let headLength: Float = 0.15       // along the tangent (was 0.09)
        let headHalfWidth: Float = 0.09    // across the radial (was 0.05)
        func head(at a: Float, pointing forward: Bool) {
            let p = dir(a) * r
            let radial = dir(a)
            var tangent = u * -sin(a) + v * cos(a)
            if !forward { tangent = -tangent }
            let tip = p + tangent * headLength
            let b1 = p + radial * headHalfWidth
            let b2 = p - radial * headHalfWidth
            vertices.append(contentsOf: [tip, b1, b2])
            vertices.append(contentsOf: [tip, b2, b1])
        }
        head(at: bandStart, pointing: false)
        head(at: bandEnd, pointing: true)
    }

    /// A small cyan sphere-ish dot at the origin (free-move pivot).
    private func appendCenterDot(into vertices: inout [SIMD3<Float>]) {
        let r: Float = 0.055
        // Octahedron.
        let p = [SIMD3<Float>(r,0,0), SIMD3(-r,0,0), SIMD3(0,r,0),
                 SIMD3(0,-r,0), SIMD3(0,0,r), SIMD3(0,0,-r)]
        let faces = [(0,2,4),(2,1,4),(1,3,4),(3,0,4),
                     (2,0,5),(1,2,5),(3,1,5),(0,3,5)]
        for (a, b, c) in faces {
            vertices.append(contentsOf: [p[a], p[b], p[c]])
        }
    }

    private func perpendicularBasis(for axis: SIMD3<Float>) -> (SIMD3<Float>, SIMD3<Float>) {
        let reference: SIMD3<Float> = abs(axis.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let u = simd_normalize(simd_cross(reference, axis))
        let v = simd_cross(axis, u)
        return (u, v)
    }
}
