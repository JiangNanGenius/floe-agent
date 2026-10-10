//
//  GLBExporter.swift
//  openshape3d
//
//  glTF 2.0 binary (.glb) export from RenderMesh buffers. One node + mesh per
//  body (transform baked into world space, matching the other exporters), a
//  single shared pbrMetallicRoughness material, and a single BIN buffer with
//  per-body position/normal/index bufferViews. All views are 4-byte aligned
//  (float triples and uint32 indices are naturally multiples of 4).
//  Convention: 1 model unit = 1 mm; glTF is meters-agnostic so no scaling.
//

import Foundation
import simd

nonisolated enum GLBExporter {

    // GLB container constants (glTF 2.0 §4: Binary glTF layout).
    static let magic: UInt32 = 0x46546C67          // "glTF"
    static let containerVersion: UInt32 = 2
    static let jsonChunkType: UInt32 = 0x4E4F534A  // "JSON"
    static let binChunkType: UInt32 = 0x004E4942   // "BIN\0"

    // Component types / targets from the glTF spec.
    private static let componentFloat = 5126
    private static let componentUInt32 = 5125
    private static let targetArrayBuffer = 34962
    private static let targetElementArrayBuffer = 34963

    static func glb(bodies: [Body]) -> Data {
        var bin = Data()
        var bufferViews = [[String: Any]]()
        var accessors = [[String: Any]]()
        var meshes = [[String: Any]]()
        var nodes = [[String: Any]]()

        // Empty meshes are skipped: glTF accessors require count >= 1, and an
        // infinite min/max would break JSON serialization.
        for body in bodies where !body.render.positions.isEmpty && !body.render.indices.isEmpty {
            let transform = body.transform
            var positions = [SIMD3<Float>]()
            positions.reserveCapacity(body.render.positions.count)
            var lo = SIMD3<Double>(repeating: .infinity)
            var hi = SIMD3<Double>(repeating: -.infinity)
            for p in body.render.positions {
                let world = transform.applying(to: SIMD3<Double>(p))
                lo = simd_min(lo, world)
                hi = simd_max(hi, world)
                positions.append(SIMD3<Float>(world))
            }
            var normals = [SIMD3<Float>]()
            normals.reserveCapacity(body.render.normals.count)
            for n in body.render.normals {
                // Uniform scale: rotating the normal is sufficient.
                let world = simd_normalize(transform.rotation.act(SIMD3<Double>(n)))
                normals.append(SIMD3<Float>(world))
            }

            let positionView = appendView(
                packed(positions), to: &bin, views: &bufferViews, target: targetArrayBuffer
            )
            let normalView = appendView(
                packed(normals), to: &bin, views: &bufferViews, target: targetArrayBuffer
            )
            let indexView = appendView(
                packed(body.render.indices), to: &bin, views: &bufferViews,
                target: targetElementArrayBuffer
            )

            let positionAccessor = accessors.count
            accessors.append([
                "bufferView": positionView,
                "componentType": componentFloat,
                "count": positions.count,
                "type": "VEC3",
                "min": [lo.x, lo.y, lo.z],
                "max": [hi.x, hi.y, hi.z],
            ])
            let normalAccessor = accessors.count
            accessors.append([
                "bufferView": normalView,
                "componentType": componentFloat,
                "count": normals.count,
                "type": "VEC3",
            ])
            let indexAccessor = accessors.count
            accessors.append([
                "bufferView": indexView,
                "componentType": componentUInt32,
                "count": body.render.indices.count,
                "type": "SCALAR",
            ])

            let meshIndex = meshes.count
            meshes.append([
                "name": body.name,
                "primitives": [[
                    "attributes": ["POSITION": positionAccessor, "NORMAL": normalAccessor],
                    "indices": indexAccessor,
                    "material": 0,
                    "mode": 4,  // TRIANGLES
                ]],
            ])
            nodes.append(["name": body.name, "mesh": meshIndex])
        }

        let json: [String: Any] = [
            "asset": ["version": "2.0", "generator": "openshape3d"],
            "scene": 0,
            "scenes": [["nodes": Array(nodes.indices)]],
            "nodes": nodes,
            "meshes": meshes,
            "accessors": accessors,
            "bufferViews": bufferViews,
            "buffers": [["byteLength": bin.count]],
            "materials": [[
                "name": "Default",
                "pbrMetallicRoughness": [
                    "baseColorFactor": [0.72, 0.75, 0.78, 1.0],
                    "metallicFactor": 0.1,
                    "roughnessFactor": 0.6,
                ],
            ]],
        ]

        // JSONSerialization never fails for this plist-safe dictionary.
        var jsonData = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
            ?? Data()
        while jsonData.count % 4 != 0 { jsonData.append(0x20) }  // pad with spaces
        while bin.count % 4 != 0 { bin.append(0x00) }

        var out = Data()
        appendU32(magic, to: &out)
        appendU32(containerVersion, to: &out)
        appendU32(UInt32(12 + 8 + jsonData.count + 8 + bin.count), to: &out)
        appendU32(UInt32(jsonData.count), to: &out)
        appendU32(jsonChunkType, to: &out)
        out.append(jsonData)
        appendU32(UInt32(bin.count), to: &out)
        appendU32(binChunkType, to: &out)
        out.append(bin)
        return out
    }

    // MARK: - Helpers

    /// Appends `payload` to the BIN blob at a 4-byte boundary and records the
    /// bufferView; returns the view's index.
    private static func appendView(
        _ payload: Data, to bin: inout Data, views: inout [[String: Any]], target: Int
    ) -> Int {
        while bin.count % 4 != 0 { bin.append(0x00) }
        let index = views.count
        views.append([
            "buffer": 0,
            "byteOffset": bin.count,
            "byteLength": payload.count,
            "target": target,
        ])
        bin.append(payload)
        return index
    }

    /// SIMD3<Float> has 16-byte stride; write tightly packed 12-byte triples.
    private static func packed(_ vectors: [SIMD3<Float>]) -> Data {
        var data = Data(capacity: vectors.count * 12)
        for v in vectors {
            withUnsafeBytes(of: v.x) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: v.y) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: v.z) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func packed(_ indices: [UInt32]) -> Data {
        var data = Data(capacity: indices.count * 4)
        for i in indices {
            withUnsafeBytes(of: i.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}
