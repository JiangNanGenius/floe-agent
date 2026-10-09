//
//  OrientationCube.swift
//  openshape3d
//
//  Screen-corner orientation cube (spec §7.2): a small camera-tracking cube
//  drawn in the overlay pass. Tapping a face or corner snaps the turntable
//  camera to that orientation. Layout + hit math live in OrientationCube
//  (shared by rendering and tap routing); OrientationCubeRenderer draws it
//  with the gizmo's unlit pipeline.
//

import OCCTShim
import Foundation
import Metal
import simd
import CoreGraphics

nonisolated enum OrientationCube {
    /// On-screen footprint (points) and placement in the top-trailing corner,
    /// below the navigation bar chrome.
    static let sizePoints: CGFloat = 92
    static let topInset: CGFloat = 96
    static let trailingInset: CGFloat = 14

    /// Cube-local half extent; the ortho volume leaves margin so the rotated
    /// cube (corner radius √3 ≈ 1.73) never clips its viewport.
    static let halfExtent: Float = 1
    static let orthoHalfExtent: Float = 1.75

    /// Hits with all three |coordinates| above this fraction of the half
    /// extent count as corner taps.
    static let cornerFraction: Float = 0.55

    static func rect(in viewSize: CGSize) -> CGRect {
        CGRect(
            x: viewSize.width - trailingInset - sizePoints,
            y: topInset,
            width: sizePoints,
            height: sizePoints
        )
    }

    // MARK: - Face labels (spec §7.2)

    /// A standard-view name drawn over the cube face that snaps to it.
    nonisolated struct FaceLabel: Identifiable, Equatable, Sendable {
        var id: String { name }
        /// Matches `StandardView.rawValue`, so the cube and the Views menu
        /// never disagree about which way is Front.
        var name: String
        var point: CGPoint
        /// Fades as the face turns away, so only the faces you could actually
        /// tap are named and the cube does not turn into a wall of text.
        var opacity: Double
    }

    /// Outward normal of each named face. Derived from `StandardView`: azimuth
    /// 0 / elevation 0 puts the eye on +Z, which is Front.
    static let faceNormals: [(name: String, normal: SIMD3<Float>)] = [
        (StandardView.front.rawValue, SIMD3(0, 0, 1)),
        (StandardView.back.rawValue, SIMD3(0, 0, -1)),
        (StandardView.right.rawValue, SIMD3(1, 0, 0)),
        (StandardView.left.rawValue, SIMD3(-1, 0, 0)),
        (StandardView.top.rawValue, SIMD3(0, 1, 0)),
        (StandardView.bottom.rawValue, SIMD3(0, -1, 0)),
    ]

    /// A face must be turned at least this far toward the camera to be named.
    /// Geometrically a face is visible whenever this is above 0, but the last
    /// few degrees are too foreshortened to read; 0.25 (~75° off head-on) keeps
    /// every face you could sensibly tap — including the shallow Top face of
    /// the default isometric, whose facing is only 0.43 — and drops the rest.
    static let labelMinFacing: Float = 0.25

    /// Named faces currently turned toward the camera, in screen points.
    ///
    /// Pure layout: the same projection the cube is drawn with, so a label
    /// always sits on the face it names, at any orientation.
    static func faceLabels(camera: TurntableCamera, viewSize: CGSize) -> [FaceLabel] {
        guard viewSize.width > 0, viewSize.height > 0 else { return [] }
        let eyeOffset = camera.position - camera.target
        guard simd_length(eyeOffset) > 1e-6 else { return [] }
        let eye = simd_normalize(eyeOffset)
        let vp = viewProjection(camera: camera, viewSize: viewSize)

        return faceNormals.compactMap { face in
            let facing = simd_dot(face.normal, eye)
            guard facing > labelMinFacing else { return nil }
            // Sit slightly proud of the surface so the label is never buried
            // in the face colour at a grazing angle.
            let centre = face.normal * (halfExtent * 1.02)
            let clip = vp * SIMD4(centre.x, centre.y, centre.z, 1)
            guard abs(clip.w) > 1e-6 else { return nil }
            let ndc = SIMD3(clip.x, clip.y, clip.z) / clip.w
            let point = CGPoint(
                x: CGFloat(ndc.x * 0.5 + 0.5) * viewSize.width,
                y: CGFloat(1 - (ndc.y * 0.5 + 0.5)) * viewSize.height
            )
            // Ramp from just-visible to fully opaque across the usable range.
            let t = (facing - labelMinFacing) / (1 - labelMinFacing)
            return FaceLabel(name: face.name, point: point,
                             opacity: Double(min(max(t * 1.6, 0.25), 1)))
        }
    }

    /// Rotation-only view of the camera (world → view, no translation).
    static func rotationView(of camera: TurntableCamera) -> simd_float4x4 {
        var view = camera.viewMatrix
        view.columns.3 = SIMD4(0, 0, 0, 1)
        return view
    }

    /// Full view-projection for the cube: camera rotation → small ortho
    /// volume → NDC placement in the corner viewport.
    static func viewProjection(camera: TurntableCamera, viewSize: CGSize) -> simd_float4x4 {
        let ortho = Matrices.orthographic(
            halfWidth: orthoHalfExtent,
            halfHeight: orthoHalfExtent,
            near: -orthoHalfExtent,
            far: orthoHalfExtent
        )
        let r = rect(in: viewSize)
        var placement = matrix_identity_float4x4
        placement.columns.0.x = Float(r.width / viewSize.width)
        placement.columns.1.y = Float(r.height / viewSize.height)
        placement.columns.3.x = Float(2 * r.midX / viewSize.width - 1)
        placement.columns.3.y = Float(1 - 2 * r.midY / viewSize.height)
        return placement * ortho * rotationView(of: camera)
    }

    /// Face/corner under a tap, as the camera pose looking at it head-on;
    /// nil when the tap misses the cube. A dedicated mini ray is built in
    /// cube-local space: an ortho ray through the tap's corner-viewport
    /// coordinates, un-rotated by the camera basis.
    static func hitPose(
        at point: CGPoint, camera: TurntableCamera, viewSize: CGSize
    ) -> TurntableCamera? {
        let r = rect(in: viewSize)
        guard r.width > 0, r.contains(point) else { return nil }
        let u = Float((point.x - r.midX) / (r.width / 2))
        let v = Float(-(point.y - r.midY) / (r.height / 2))

        // Camera basis in world space (view matrix rows).
        let view = camera.viewMatrix
        let right = SIMD3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let up = SIMD3(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        let back = SIMD3(view.columns.0.z, view.columns.1.z, view.columns.2.z)

        let origin = right * (u * orthoHalfExtent)
            + up * (v * orthoHalfExtent)
            + back * (orthoHalfExtent * 2)
        let direction = -back
        guard let hit = intersectCube(origin: origin, direction: direction) else { return nil }

        let p = hit / halfExtent
        let normal: SIMD3<Float>
        if min(abs(p.x), min(abs(p.y), abs(p.z))) > cornerFraction {
            // Corner: look down the corner diagonal.
            normal = simd_normalize(SIMD3(
                p.x < 0 ? -1 : 1, p.y < 0 ? -1 : 1, p.z < 0 ? -1 : 1
            ))
        } else {
            // Face: the axis with the dominant coordinate.
            let a = abs(p)
            if a.x >= a.y && a.x >= a.z {
                normal = SIMD3(p.x < 0 ? -1 : 1, 0, 0)
            } else if a.y >= a.z {
                normal = SIMD3(0, p.y < 0 ? -1 : 1, 0)
            } else {
                normal = SIMD3(0, 0, p.z < 0 ? -1 : 1)
            }
        }
        return pose(lookingAlong: normal, from: camera)
    }

    /// Turntable pose with the eye along `normal` (unit, world space).
    /// Top/bottom clamp to ±elevationLimit (±89°, 1° off plan — Y-up
    /// turntable) and keep the current azimuth.
    static func pose(
        lookingAlong normal: SIMD3<Float>, from camera: TurntableCamera
    ) -> TurntableCamera {
        var cam = camera
        cam.elevation = min(
            max(asin(min(max(normal.y, -1), 1)), -TurntableCamera.elevationLimit),
            TurntableCamera.elevationLimit
        )
        if abs(normal.x) + abs(normal.z) > 1e-5 {
            cam.azimuth = atan2(normal.x, normal.z)
        }
        return cam
    }

    /// Slab intersection with the cube [-halfExtent, halfExtent]³; returns
    /// the entry point (or the origin when starting inside).
    static func intersectCube(
        origin: SIMD3<Float>, direction: SIMD3<Float>
    ) -> SIMD3<Float>? {
        var tMin = -Float.infinity
        var tMax = Float.infinity
        for i in 0..<3 {
            let o = origin[i]
            let d = direction[i]
            if abs(d) < 1e-8 {
                if abs(o) > halfExtent { return nil }
                continue
            }
            var t0 = (-halfExtent - o) / d
            var t1 = (halfExtent - o) / d
            if t0 > t1 { swap(&t0, &t1) }
            tMin = max(tMin, t0)
            tMax = min(tMax, t1)
        }
        guard tMin <= tMax, tMax > 0 else { return nil }
        return origin + direction * max(tMin, 0)
    }
}

/// Draws the orientation cube in the overlay pass, reusing the gizmo's
/// unlit-color pipeline: 6 distinctly shaded faces + dark edge lines.
final class OrientationCubeRenderer {
    private struct Face {
        let vertexRange: Range<Int>
        let color: SIMD4<Float>
    }

    private var vertexBuffer: MTLBuffer?
    private var faces: [Face] = []
    private var edgeBuffer: MTLBuffer?
    private var edgeVertexCount = 0

    /// Axis-tinted shades matching the gizmo colors; the positive face of
    /// each axis is the brighter one.
    private static let faceColors: [SIMD4<Float>] = [
        SIMD4(0.93, 0.52, 0.50, 1),  // +X
        SIMD4(0.66, 0.33, 0.32, 1),  // -X
        SIMD4(0.62, 0.85, 0.55, 1),  // +Y
        SIMD4(0.40, 0.58, 0.36, 1),  // -Y
        SIMD4(0.55, 0.70, 0.95, 1),  // +Z
        SIMD4(0.35, 0.46, 0.68, 1),  // -Z
    ]

    func prepare(device: MTLDevice) {
        guard vertexBuffer == nil else { return }
        let h = OrientationCube.halfExtent
        var vertices: [SIMD3<Float>] = []
        var built: [Face] = []

        // (normal axis, sign) per face, matching faceColors order.
        let axes: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = [
            (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
            (SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1)),
            (SIMD3(0, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 0)),
            (SIMD3(0, -1, 0), SIMD3(0, 0, -1), SIMD3(1, 0, 0)),
            (SIMD3(0, 0, 1), SIMD3(0, 1, 0), SIMD3(-1, 0, 0)),
            (SIMD3(0, 0, -1), SIMD3(0, 1, 0), SIMD3(1, 0, 0)),
        ]
        for (index, (n, u, v)) in axes.enumerated() {
            let start = vertices.count
            let c = n * h
            let uh = u * h
            let vh = v * h
            let corners: [SIMD3<Float>] = [
                c - uh - vh, c - uh + vh, c + uh + vh, c + uh - vh,
            ]
            vertices.append(contentsOf: [corners[0], corners[1], corners[2]])
            vertices.append(contentsOf: [corners[0], corners[2], corners[3]])
            built.append(Face(
                vertexRange: start..<vertices.count,
                color: Self.faceColors[index]
            ))
        }

        vertexBuffer = vertices.withUnsafeBytes { raw in
            device.makeBuffer(
                bytes: raw.baseAddress!,
                length: vertices.count * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared
            )
        }
        faces = built

        // 12 edges as a line list.
        var edges: [SIMD3<Float>] = []
        for x in [-h, h] {
            for y in [-h, h] {
                edges.append(contentsOf: [SIMD3(x, y, -h), SIMD3(x, y, h)])
                edges.append(contentsOf: [SIMD3(x, -h, y), SIMD3(x, h, y)])
                edges.append(contentsOf: [SIMD3(-h, x, y), SIMD3(h, x, y)])
            }
        }
        edgeVertexCount = edges.count
        edgeBuffer = edges.withUnsafeBytes { raw in
            device.makeBuffer(
                bytes: raw.baseAddress!,
                length: edges.count * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared
            )
        }
    }

    func draw(
        encoder: MTLRenderCommandEncoder,
        pipelines: PipelineStore,
        camera: TurntableCamera,
        viewSize: CGSize
    ) {
        guard let vertexBuffer, let edgeBuffer,
              viewSize.width > 0, viewSize.height > 0
        else { return }

        var frame = FrameUniforms()
        frame.viewProjectionMatrix = OrientationCube.viewProjection(
            camera: camera, viewSize: viewSize
        )

        encoder.setRenderPipelineState(pipelines.unlitColor)
        encoder.setDepthStencilState(pipelines.depthReadWrite)
        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride,
                               index: Int(BufferIndexFrameUniforms.rawValue))
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: Int(BufferIndexPositions.rawValue))

        for face in faces {
            var body = BodyUniforms()
            body.modelMatrix = matrix_identity_float4x4
            body.baseColor = face.color
            encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                   index: Int(BufferIndexBodyUniforms.rawValue))
            encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                     index: Int(BufferIndexBodyUniforms.rawValue))
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: face.vertexRange.lowerBound,
                vertexCount: face.vertexRange.count
            )
        }

        var body = BodyUniforms()
        body.modelMatrix = matrix_identity_float4x4
        body.baseColor = SIMD4(0.13, 0.15, 0.17, 1)
        encoder.setVertexBuffer(edgeBuffer, offset: 0, index: Int(BufferIndexPositions.rawValue))
        encoder.setVertexBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                               index: Int(BufferIndexBodyUniforms.rawValue))
        encoder.setFragmentBytes(&body, length: MemoryLayout<BodyUniforms>.stride,
                                 index: Int(BufferIndexBodyUniforms.rawValue))
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: edgeVertexCount)
    }
}
