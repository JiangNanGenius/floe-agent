//
//  USDZExporter.swift
//  openshape3d
//
//  USDZ export via ModelIO: MDLAsset assembled from RenderMesh buffers
//  (transforms baked into world space, one named MDLMesh per body) and written
//  through MDLAsset.export(to:). Guarded by canExportFileExtension("usdz");
//  returns nil when the platform cannot write USDZ (e.g. some simulators) so
//  the UI can hide the option — never faked. Convention: 1 model unit = 1 mm.
//

import Foundation
import ModelIO
import simd

nonisolated enum USDZExporter {

    /// True when ModelIO on this platform can write .usdz.
    static var isSupported: Bool {
        MDLAsset.canExportFileExtension("usdz")
    }

    /// USDZ archive bytes, or nil when export is unsupported or fails.
    static func usdz(bodies: [Body]) -> Data? {
        guard isSupported else { return nil }
        let asset = MDLAsset()
        var added = 0
        for body in bodies where !body.render.positions.isEmpty && !body.render.indices.isEmpty {
            asset.add(mdlMesh(for: body))
            added += 1
        }
        guard added > 0 else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("os3d-export-\(UUID().uuidString)")
            .appendingPathExtension("usdz")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try asset.export(to: url)
        } catch {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// Interleaved [position.xyz normal.xyz] float32 vertex buffer, world-baked.
    private static func mdlMesh(for body: Body) -> MDLMesh {
        let transform = body.transform
        var vertexData = Data(capacity: body.render.positions.count * 24)
        for (p, n) in zip(body.render.positions, body.render.normals) {
            let worldP = SIMD3<Float>(transform.applying(to: SIMD3<Double>(p)))
            // Uniform scale: rotating the normal is sufficient.
            let worldN = SIMD3<Float>(simd_normalize(transform.rotation.act(SIMD3<Double>(n))))
            for component in [worldP.x, worldP.y, worldP.z, worldN.x, worldN.y, worldN.z] {
                withUnsafeBytes(of: component) { vertexData.append(contentsOf: $0) }
            }
        }
        var indexData = Data(capacity: body.render.indices.count * 4)
        for index in body.render.indices {
            withUnsafeBytes(of: index.littleEndian) { indexData.append(contentsOf: $0) }
        }

        let allocator = MDLMeshBufferDataAllocator()
        let vertexBuffer = allocator.newBuffer(with: vertexData, type: .vertex)
        let indexBuffer = allocator.newBuffer(with: indexData, type: .index)

        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(
            name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0
        )
        descriptor.attributes[1] = MDLVertexAttribute(
            name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0
        )
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 24)

        let submesh = MDLSubmesh(
            indexBuffer: indexBuffer,
            indexCount: body.render.indices.count,
            indexType: .uInt32,
            geometryType: .triangles,
            material: nil
        )
        let mesh = MDLMesh(
            vertexBuffer: vertexBuffer,
            vertexCount: body.render.positions.count,
            descriptor: descriptor,
            submeshes: [submesh]
        )
        mesh.name = body.name
        return mesh
    }
}
