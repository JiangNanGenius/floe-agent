//
//  OBJExporter.swift
//  openshape3d
//
//  Wavefront OBJ export from RenderMesh buffers. Transforms are baked into
//  world space; one "o <name>" object per body. Indices are 1-based and
//  positions/normals share indices (welded parallel arrays), so faces are
//  emitted as "f v//vn". Convention: 1 model unit = 1 mm.
//

import Foundation
import simd

nonisolated enum OBJExporter {

    /// One merged OBJ containing every body as its own object.
    static func obj(bodies: [Body]) -> String {
        var out = header
        var vertexOffset = 0
        for body in bodies {
            append(body: body, to: &out, vertexOffset: vertexOffset)
            vertexOffset += body.render.positions.count
        }
        return out
    }

    /// One OBJ string per body ("save each body separately").
    static func objPerBody(bodies: [Body]) -> [(name: String, obj: String)] {
        bodies.map { body in
            var out = header
            append(body: body, to: &out, vertexOffset: 0)
            return (sanitized(body.name), out)
        }
    }

    private static let header = "# openshape3d OBJ export (units: mm)\n"

    private static func append(body: Body, to out: inout String, vertexOffset: Int) {
        out += "o \(sanitized(body.name))\n"
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
        let indices = body.render.indices
        var i = 0
        while i + 2 < indices.count {
            let a = Int(indices[i]) + vertexOffset + 1
            let b = Int(indices[i + 1]) + vertexOffset + 1
            let c = Int(indices[i + 2]) + vertexOffset + 1
            out += "f \(a)//\(a) \(b)//\(b) \(c)//\(c)\n"
            i += 3
        }
    }

    private static func sanitized(_ name: String) -> String {
        let cleaned = name.map { $0.isWhitespace ? "_" : String($0) }.joined()
        return cleaned.isEmpty ? "Body" : cleaned
    }
}
