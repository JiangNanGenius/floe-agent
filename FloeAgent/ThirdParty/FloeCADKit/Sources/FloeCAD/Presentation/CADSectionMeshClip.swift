//
//  CADSectionMeshClip.swift
//  FloeCADKit
//
//  X22 — the presentation-side half-space cut.
//
//  The Metal engineering viewport clips fragments in its shaders with
//  `SectionPlaneState.clipVector` (keep `dot(point - origin, normal) >= 0`).
//  RealityKit has no equivalent per-material clip plane, so Present/export
//  clip the SAME presentation mesh triangles against the SAME persisted plane
//  before the mesh reaches RealityKit. This is not a second section engine: it
//  consumes the one `CADSectionView` and produces open cut faces exactly like
//  the viewport (no caps), leaving the document/B-rep byte-identical.
//
//  Pure value math (Foundation + simd) so the exact triangle output can be
//  checked without a renderer.
//

import Foundation
import simd

/// The section plane expressed in one body's local presentation space, in
/// metres. `normal` points toward the side that stays visible.
nonisolated struct CADSectionClipPlane: Equatable, Sendable {
    var origin: SIMD3<Float>
    var normal: SIMD3<Float>

    var isValid: Bool {
        origin.x.isFinite && origin.y.isFinite && origin.z.isFinite
            && normal.x.isFinite && normal.y.isFinite && normal.z.isFinite
            && abs(simd_length(normal) - 1) < 0.01
    }
}

/// Triangle output of one half-space clip. `nil` from `clip` means "nothing
/// was cut" and the caller must reuse the original mesh/resource.
nonisolated struct CADClippedMesh: Equatable, Sendable {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var uvs: [SIMD2<Float>]?
    /// Authored mesh UVs, interpolated for the cut vertices when present.
    var authoredUVs: [SIMD2<Float>]?
    var indices: [UInt32]
    /// Triangles removed entirely because every vertex was on the cut side.
    var removedTriangleCount: Int
    /// True when no triangle survived (the body is outside the kept half).
    var isFullyClipped: Bool

    var isEmpty: Bool { indices.isEmpty }
}

/// Why a requested cut could not be produced. Never collapsed into
/// "unchanged": an active section whose plane/indices are unusable must be
/// reported, not silently rendered as the full model.
nonisolated enum CADSectionClipInvalidReason: String, Hashable, Sendable {
    case invalidPlane
    case invalidIndices
}

/// Complete result of one triangle-set clip. `.unchanged` means no triangle
/// was touched; `.clipped` may still be fully empty (`.isFullyClipped`).
nonisolated enum CADSectionClipOutcome: Equatable, Sendable {
    case unchanged
    case clipped(CADClippedMesh)
    case invalid(CADSectionClipInvalidReason)
    case cancelled
}

/// One value-only clip request. Every field is a Sendable value (CoW arrays),
/// so the stage builder can hand the exact body/group inputs to a detached CPU
/// worker without transferring the document, B-rep or RealityKit objects.
nonisolated struct CADSectionClipJob: Sendable {
    var positions: [SIMD3<Float>]
    var normals: [SIMD3<Float>]
    var uvs: [SIMD2<Float>]?
    var authoredUVs: [SIMD2<Float>]?
    var indices: [UInt32]
    var plane: CADSectionClipPlane
}

nonisolated enum CADSectionMeshClip {
    /// Presentation metres; cut-plane coincidence is kept (not removed).
    static let epsilon: Float = 1e-6
    /// A triangle smaller than this has no visible area after interpolation.
    private static let degeneracyEpsilon: Float = 1e-12

    // MARK: Plane conversion

    /// Convert the model-space section plane into a body-local presentation
    /// plane. Positions and the matrix are presentation metres (+Y up); only a
    /// uniform 1/1000 translation differs from the model.
    static func plane(section: CADSectionView,
                      transform: simd_float4x4) -> CADSectionClipPlane? {
        guard let clean = section.sanitized else { return nil }
        return plane(originMM: clean.originVector, normalMM: clean.keepNormal,
                     transform: transform)
    }

    /// Same conversion for callers that already hold plain model-space values
    /// (the presentation scene), with no dependency on the overlay type.
    static func plane(originMM: SIMD3<Double>, normalMM: SIMD3<Double>,
                      transform: simd_float4x4) -> CADSectionClipPlane? {
        let linear = simd_float3x3(
            SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z),
            SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z),
            SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        let determinant = simd_determinant(linear)
        guard determinant.isFinite, abs(determinant) > 1e-18 else { return nil }
        let inverse = simd_inverse(transform)
        let originModel = SIMD3<Float>(Float(originMM.x),
                                       Float(originMM.y),
                                       Float(originMM.z))
        // Presentation meshes are metres; the model/build units are fixed
        // millimetres, so this file stays independent of the presentation
        // core's platform guard.
        let originMetres = originModel / 1_000
        let local = inverse * SIMD4<Float>(originMetres, 1)
        let origin = SIMD3<Float>(local.x, local.y, local.z)

        let normalModel = SIMD3<Float>(Float(normalMM.x),
                                       Float(normalMM.y),
                                       Float(normalMM.z))
        // A plane normal transforms by the transpose of the linear part:
        // n_local ∝ M3ᵀ · n_world for p_world = M · p_local.
        let localNormal = linear.transpose * normalModel
        let length = simd_length(localNormal)
        guard length.isFinite, length > 1e-9 else { return nil }
        let plane = CADSectionClipPlane(origin: origin, normal: localNormal / length)
        return plane.isValid ? plane : nil
    }

    // MARK: Triangles

    /// Clip one indexed triangle set. `normals` may be empty (some imported
    /// meshes have none); `uvs` may be nil or not aligned. When the arrays are
    /// present and aligned the cut vertices interpolate them.
    ///
    /// The result keeps only the vertices its triangles actually reference
    /// (plus interpolated cut vertices), so clipping a face group does not copy
    /// the whole body's vertex arrays. Returns nil when no triangle was
    /// removed, so the caller keeps the exact original mesh resource and its
    /// cache identity. Use `outcome` when the caller must distinguish an
    /// untouched mesh from an invalid plane or a cancelled clip.
    static func clip(positions: [SIMD3<Float>],
                     normals: [SIMD3<Float>],
                     uvs: [SIMD2<Float>]?,
                     authoredUVs: [SIMD2<Float>]? = nil,
                     indices: [UInt32],
                     plane: CADSectionClipPlane) -> CADClippedMesh? {
        guard case .clipped(let value) = outcome(
            positions: positions, normals: normals, uvs: uvs,
            authoredUVs: authoredUVs, indices: indices, plane: plane) else {
            return nil
        }
        return value
    }

    /// Full clip result. Unlike `clip`, this never collapses an invalid plane,
    /// corrupt index buffer or a cancelled worker into "unchanged": the caller
    /// can report the real reason instead of drawing an uncut body.
    ///
    /// `shouldCancel` is deterministic for tests. Production callers leave it
    /// at the default, which observes the enclosing Task; the detached stage
    /// worker calls this off the main actor and checks every 1,024 triangles.
    static func outcome(positions: [SIMD3<Float>],
                        normals: [SIMD3<Float>],
                        uvs: [SIMD2<Float>]?,
                        authoredUVs: [SIMD2<Float>]? = nil,
                        indices: [UInt32],
                        plane: CADSectionClipPlane,
                        shouldCancel: () -> Bool = { Task.isCancelled })
    -> CADSectionClipOutcome {
        guard plane.isValid else { return .invalid(.invalidPlane) }
        guard indices.count >= 3, indices.count % 3 == 0 else {
            return .invalid(.invalidIndices)
        }
        for index in indices where Int(index) >= positions.count {
            return .invalid(.invalidIndices)
        }
        if shouldCancel() { return .cancelled }

        let normalsAligned = normals.count == positions.count
        let uvsAligned = uvs?.count == positions.count
        let authoredAligned = authoredUVs?.count == positions.count
        var map = [Int32](repeating: -1, count: positions.count)
        var outPositions: [SIMD3<Float>] = []
        var outNormals: [SIMD3<Float>] = []
        var outUVs: [SIMD2<Float>]? = uvsAligned ? [] : nil
        var outAuthored: [SIMD2<Float>]? = authoredAligned ? [] : nil
        var outIndices: [UInt32] = []
        let originalCapacity = min(indices.count, positions.count)
        outPositions.reserveCapacity(originalCapacity)
        outNormals.reserveCapacity(normalsAligned ? originalCapacity : 0)
        outUVs?.reserveCapacity(originalCapacity)
        outAuthored?.reserveCapacity(originalCapacity)
        outIndices.reserveCapacity(indices.count)
        var removed = 0
        var createdVertices = false
        var triangleCount = 0

        func appendOriginal(_ index: UInt32) -> UInt32 {
            let position = Int(index)
            if map[position] < 0 {
                map[position] = Int32(outPositions.count)
                outPositions.append(positions[position])
                if normalsAligned { outNormals.append(normals[position]) }
                if let values = uvs, uvsAligned { outUVs?.append(values[position]) }
                if let values = authoredUVs, authoredAligned {
                    outAuthored?.append(values[position])
                }
            }
            return UInt32(map[position])
        }

        func appendVertex(position: SIMD3<Float>,
                          normal: SIMD3<Float>?,
                          uv: SIMD2<Float>?,
                          authored: SIMD2<Float>?) -> UInt32 {
            let index = UInt32(outPositions.count)
            outPositions.append(position)
            if normalsAligned { outNormals.append(normal ?? .zero) }
            if outUVs != nil { outUVs?.append(uv ?? .zero) }
            if outAuthored != nil { outAuthored?.append(authored ?? .zero) }
            createdVertices = true
            return index
        }

        var triangle = 0
        while triangle + 2 < indices.count {
            if triangleCount & 0x3FF == 0, shouldCancel() { return .cancelled }
            triangleCount += 1
            let i0 = indices[triangle]
            let i1 = indices[triangle + 1]
            let i2 = indices[triangle + 2]
            triangle += 3
            let p0 = positions[Int(i0)]
            let p1 = positions[Int(i1)]
            let p2 = positions[Int(i2)]
            let d0 = signedDistance(p0, plane)
            let d1 = signedDistance(p1, plane)
            let d2 = signedDistance(p2, plane)
            let inside0 = d0 >= -epsilon
            let inside1 = d1 >= -epsilon
            let inside2 = d2 >= -epsilon

            if inside0 && inside1 && inside2 {
                let a = appendOriginal(i0)
                let b = appendOriginal(i1)
                let c = appendOriginal(i2)
                outIndices.append(a)
                outIndices.append(b)
                outIndices.append(c)
                continue
            }
            if !inside0 && !inside1 && !inside2 {
                removed += 1
                continue
            }

            // Sutherland–Hodgman on the triangle: keep the inside vertices in
            // order, insert the edge crossings. The result is a triangle or a
            // quad, triangulated as a fan exactly like a viewport's open cut.
            var polygon: [(position: SIMD3<Float>,
                           normal: SIMD3<Float>?,
                           uv: SIMD2<Float>?,
                           authored: SIMD2<Float>?)] = []
            appendIfInside(&polygon, index: i0, distance: d0,
                           positions: positions, normals: normalsAligned ? normals : nil,
                           uvs: uvsAligned ? uvs : nil,
                           authored: authoredAligned ? authoredUVs : nil)
            appendCrossing(&polygon, from: i0, to: i1, d0: d0, d1: d1,
                           positions: positions, normals: normalsAligned ? normals : nil,
                           uvs: uvsAligned ? uvs : nil,
                           authored: authoredAligned ? authoredUVs : nil)
            appendIfInside(&polygon, index: i1, distance: d1,
                           positions: positions, normals: normalsAligned ? normals : nil,
                           uvs: uvsAligned ? uvs : nil,
                           authored: authoredAligned ? authoredUVs : nil)
            appendCrossing(&polygon, from: i1, to: i2, d0: d1, d1: d2,
                           positions: positions, normals: normalsAligned ? normals : nil,
                           uvs: uvsAligned ? uvs : nil,
                           authored: authoredAligned ? authoredUVs : nil)
            appendIfInside(&polygon, index: i2, distance: d2,
                           positions: positions, normals: normalsAligned ? normals : nil,
                           uvs: uvsAligned ? uvs : nil,
                           authored: authoredAligned ? authoredUVs : nil)
            appendCrossing(&polygon, from: i2, to: i0, d0: d2, d1: d0,
                           positions: positions, normals: normalsAligned ? normals : nil,
                           uvs: uvsAligned ? uvs : nil,
                           authored: authoredAligned ? authoredUVs : nil)

            // Two vertices on the plane produce a duplicate corner; collapse
            // it before triangulating.
            var simplified: [(position: SIMD3<Float>,
                              normal: SIMD3<Float>?,
                              uv: SIMD2<Float>?,
                              authored: SIMD2<Float>?)] = []
            for vertex in polygon {
                if let last = simplified.last,
                   simd_distance(last.position, vertex.position) <= epsilon {
                    continue
                }
                simplified.append(vertex)
            }
            if simplified.count > 2,
               simd_distance(simplified[0].position,
                             simplified[simplified.count - 1].position) <= epsilon {
                simplified.removeLast()
            }
            guard simplified.count >= 3 else {
                removed += 1
                continue
            }

            var base: UInt32?
            var previous: UInt32?
            for vertex in simplified {
                let index = appendVertex(position: vertex.position,
                                         normal: vertex.normal, uv: vertex.uv,
                                         authored: vertex.authored)
                if let base, let previous {
                    if !isDegenerate(outPositions[Int(base)],
                                     outPositions[Int(previous)],
                                     outPositions[Int(index)]) {
                        outIndices.append(base)
                        outIndices.append(previous)
                        outIndices.append(index)
                    }
                } else {
                    base = index
                }
                previous = index
            }
            // Splitting a triangle always creates vertices; make that explicit
            // even when every fan triangle was degenerate (the mesh changed).
        }

        if removed == 0 && !createdVertices {
            return .unchanged
        }
        if outIndices.isEmpty {
            return .clipped(CADClippedMesh(
                positions: [], normals: [], uvs: outUVs, authoredUVs: outAuthored,
                indices: [], removedTriangleCount: removed, isFullyClipped: true))
        }
        return .clipped(CADClippedMesh(
            positions: outPositions, normals: outNormals,
            uvs: outUVs, authoredUVs: outAuthored, indices: outIndices,
            removedTriangleCount: removed, isFullyClipped: false))
    }

    /// Clip a value-only batch off the caller. The returned owner must await
    /// this task before it releases the build generation; no document, mesh
    /// resource or RealityKit entity crosses the actor boundary.
    static func clipOffMain(_ jobs: [CADSectionClipJob]) async
    -> [CADSectionClipOutcome] {
        let task = Task.detached(priority: .userInitiated) {
            clipJobs(jobs)
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    static func clipJobs(_ jobs: [CADSectionClipJob]) -> [CADSectionClipOutcome] {
        var results: [CADSectionClipOutcome] = []
        results.reserveCapacity(jobs.count)
        for job in jobs {
            results.append(outcome(
                positions: job.positions, normals: job.normals,
                uvs: job.uvs, authoredUVs: job.authoredUVs,
                indices: job.indices, plane: job.plane))
        }
        return results
    }

    // MARK: Segments

    /// Clip one guide segment to the kept half. Nil when the whole segment is
    /// removed or degenerate. Returned endpoints are on the kept side.
    static func clipSegment(_ start: SIMD3<Float>, _ end: SIMD3<Float>,
                            plane: CADSectionClipPlane) -> (SIMD3<Float>, SIMD3<Float>)? {
        guard plane.isValid else { return nil }
        let d0 = signedDistance(start, plane)
        let d1 = signedDistance(end, plane)
        let inside0 = d0 >= -epsilon
        let inside1 = d1 >= -epsilon
        if inside0 && inside1 {
            return simd_distance(start, end) > epsilon ? (start, end) : nil
        }
        if !inside0 && !inside1 { return nil }
        let denominator = d0 - d1
        guard abs(denominator) > 1e-9 else { return nil }
        let t = min(max(d0 / denominator, 0), 1)
        let crossing = start + (end - start) * t
        let keptStart = inside0 ? start : crossing
        let keptEnd = inside1 ? end : crossing
        return simd_distance(keptStart, keptEnd) > epsilon ? (keptStart, keptEnd) : nil
    }

    // MARK: Detail

    static func signedDistance(_ point: SIMD3<Float>,
                               _ plane: CADSectionClipPlane) -> Float {
        simd_dot(point - plane.origin, plane.normal)
    }

    private static func appendIfInside(
        _ polygon: inout [(position: SIMD3<Float>, normal: SIMD3<Float>?,
                           uv: SIMD2<Float>?, authored: SIMD2<Float>?)],
        index: UInt32, distance: Float,
        positions: [SIMD3<Float>], normals: [SIMD3<Float>]?,
        uvs: [SIMD2<Float>]?, authored: [SIMD2<Float>]?
    ) {
        guard distance >= -epsilon else { return }
        polygon.append((positions[Int(index)],
                        normals.map { $0[Int(index)] },
                        uvs.map { $0[Int(index)] },
                        authored.map { $0[Int(index)] }))
    }

    private static func appendCrossing(
        _ polygon: inout [(position: SIMD3<Float>, normal: SIMD3<Float>?,
                           uv: SIMD2<Float>?, authored: SIMD2<Float>?)],
        from a: UInt32, to b: UInt32, d0: Float, d1: Float,
        positions: [SIMD3<Float>], normals: [SIMD3<Float>]?,
        uvs: [SIMD2<Float>]?, authored: [SIMD2<Float>]?
    ) {
        let inside0 = d0 >= -epsilon
        let inside1 = d1 >= -epsilon
        guard inside0 != inside1 else { return }
        let denominator = d0 - d1
        guard abs(denominator) > 1e-12 else { return }
        let t = min(max(d0 / denominator, 0), 1)
        let p0 = positions[Int(a)]
        let p1 = positions[Int(b)]
        let position = p0 + (p1 - p0) * t
        var normal: SIMD3<Float>?
        if let normals {
            let interpolated = normals[Int(a)] + (normals[Int(b)] - normals[Int(a)]) * t
            let length = simd_length(interpolated)
            normal = length > 1e-9 ? interpolated / length : normals[Int(inside0 ? a : b)]
        }
        var uv: SIMD2<Float>?
        if let uvs {
            uv = uvs[Int(a)] + (uvs[Int(b)] - uvs[Int(a)]) * t
        }
        var authoredUV: SIMD2<Float>?
        if let authored {
            authoredUV = authored[Int(a)] + (authored[Int(b)] - authored[Int(a)]) * t
        }
        polygon.append((position, normal, uv, authoredUV))
    }

    private static func isDegenerate(_ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                     _ c: SIMD3<Float>) -> Bool {
        simd_length(simd_cross(b - a, c - a)) <= degeneracyEpsilon
    }
}

