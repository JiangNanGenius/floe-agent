//
//  OBJExporter.swift
//  openshape3d
//
//  Wavefront OBJ export from RenderMesh buffers. Transforms are baked into
//  world space; one "o <name>" object per body. Indices are 1-based and
//  positions/normals share indices (welded parallel arrays), so faces are
//  emitted as "f v/vt/vn" when a UV set is available and "f v//vn" otherwise.
//  Convention: 1 model unit = 1 mm.
//
//  This is the TRUE single-file OBJ path. It deliberately carries no MTL or
//  image resources; callers that want a complete appearance must use
//  `OBJBundleExporter` (format `obj_bundle`), which writes a ZIP with
//  model.obj + model.mtl + relative textures. Never return ZIP bytes under a
//  .obj name or claim this file contains materials.
//

import Foundation
import simd

nonisolated enum OBJExporter {

    /// One merged OBJ containing every body as its own object.
    static func obj(bodies: [Body]) -> String {
        var out = header
        var vertexOffset = 0
        var vtOffset = 0
        for body in bodies {
            append(body: body, to: &out, vertexOffset: vertexOffset,
                   vtOffset: &vtOffset)
            vertexOffset += body.render.positions.count
        }
        return out
    }

    /// One OBJ string per body ("save each body separately").
    static func objPerBody(bodies: [Body]) -> [(name: String, obj: String)] {
        bodies.map { body in
            var out = header
            var vtOffset = 0
            append(body: body, to: &out, vertexOffset: 0, vtOffset: &vtOffset)
            return (sanitized(body.name), out)
        }
    }

    /// The limitation the native query/legacy HTTP export must report rather
    /// than implying that a single OBJ carries the applied appearance.
    static let materialLimitationNote = "Single-file OBJ contains geometry and UVs only; "
        + "no MTL or texture maps are included. Use the obj_bundle export for materials."

    private static let header = """
    # openshape3d OBJ export (units: mm)
    # Geometry and UVs only: no MTL, materials or texture images are included.
    # UV convention: OBJ bottom-left (v is flipped from the model's top-left UVs).

    """

    private static func append(body: Body, to out: inout String,
                               vertexOffset: Int, vtOffset: inout Int) {
        out += "o \(sanitized(body.name))\n"
        out += "s off\n"
        let transform = body.transform
        for p in body.render.positions {
            let world = transform.applying(to: SIMD3<Double>(p))
            out += String(format: "v %.6f %.6f %.6f\n", world.x, world.y, world.z)
        }
        for n in body.render.normals {
            // Uniform scale: rotating the normal is sufficient.
            let world = simd_normalize(transform.rotation.act(SIMD3<Double>(n)))
            out += String(format: "vn %.6f %.6f %.6f\n", world.x, world.y, world.z)
        }
        let uvs = effectiveUVs(for: body)
        if let uvs {
            for uv in uvs {
                out += String(format: "vt %.6f %.6f\n", uv.x, 1 - uv.y)
            }
        }
        let indices = body.render.indices
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]) + vertexOffset + 1
            let b = Int(indices[i + 1]) + vertexOffset + 1
            let c = Int(indices[i + 2]) + vertexOffset + 1
            if uvs != nil {
                let ta = Int(indices[i]) + vtOffset + 1
                let tb = Int(indices[i + 1]) + vtOffset + 1
                let tc = Int(indices[i + 2]) + vtOffset + 1
                out += "f \(a)/\(ta)/\(a) \(b)/\(tb)/\(b) \(c)/\(tc)/\(c)\n"
            } else {
                out += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
            }
            i += 3
        }
        if let uvs { vtOffset += uvs.count }
    }

    /// The same UV-source decision the material pipeline uses. A textured
    /// material with no authored UVs gets the deterministic export-only box
    /// projection, so a single-file OBJ still preserves a usable UV set.
    private static func effectiveUVs(for body: Body) -> [SIMD2<Float>]? {
        let material = body.material ?? .default
        var uvs = MaterialUVProjector.effectiveUVs(
            meshTexcoords: body.render.texcoords,
            positions: body.render.positions,
            normals: body.render.normals,
            indices: body.render.indices,
            mapping: material.uvMapping)
        if uvs == nil, material.hasAnyTexture,
           (material.uvMapping?.source ?? .mesh) == .mesh {
            uvs = MaterialUVProjector.project(
                positions: body.render.positions,
                normals: body.render.normals,
                indices: body.render.indices,
                mapping: CADMaterialUVMapping(source: .boxProjection, axis: .y,
                                              scaleMM: SIMD2(100, 100)))
        }
        guard let uvs, uvs.count == body.render.positions.count,
              uvs.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return nil
        }
        return uvs
    }

    private static func sanitized(_ name: String) -> String {
        // The object name is the rest of an `o` line. Replace whitespace and
        // `#` (an OBJ comment marker) so a user-provided name cannot inject a
        // new element or comment out the following vertices.
        let cleaned = name.map { $0.isWhitespace || $0 == "#" ? "_" : String($0) }
            .joined()
        return cleaned.isEmpty ? "Body" : cleaned
    }
}
