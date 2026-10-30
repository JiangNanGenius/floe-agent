import XCTest
import Foundation
import SceneKit
import SceneKit.ModelIO
import ModelIO
import simd

/// Independent platform capability probe. It intentionally bypasses the old
/// ModelIO USDZ export guard: SceneKit has its own native USDZ writer.
@MainActor
final class CADUSDZWriterCapabilityTests: XCTestCase {
    private var workDir: URL!

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CADUSDZWriterCapability-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: false)
    }

    override func tearDown() async throws {
        if let workDir {
            try FileManager.default.removeItem(at: workDir)
            XCTAssertFalse(FileManager.default.fileExists(atPath: workDir.path))
        }
    }

    func testSceneKitWritesUSDZWithMDLMeshUVsAndScalarPBR() throws {
        #if targetEnvironment(simulator)
        let environment = "simulator"
        #else
        let environment = "device/native"
        #endif
        let runtime = "\(environment); \(ProcessInfo.processInfo.operatingSystemVersionString); "
            + "ModelIO USDZ export=\(MDLAsset.canExportFileExtension("usdz")), "
            + "USDZ import=\(MDLAsset.canImportFileExtension("usdz"))"
        let asset = makeAsset()
        let scene = SCNScene(mdlAsset: asset)
        let url = workDir.appendingPathComponent("native-writer.usdz")
        let wrote = scene.write(to: url, options: nil, delegate: nil, progressHandler: nil)
        XCTAssertTrue(wrote, "SceneKit USDZ writer failed: \(runtime)")
        guard wrote else { return }
        let archive = try Data(contentsOf: url)
        XCTAssertGreaterThan(archive.count, 4, runtime)
        XCTAssertEqual(Array(archive.prefix(4)), [80, 75, 3, 4], "The native writer must return a ZIP-based USDZ archive: \(runtime)")
        XCTContext.runActivity(named: runtime) { activity in
            let evidence = XCTAttachment(data: archive, uniformTypeIdentifier: "com.pixar.universal-scene-description-mobile")
            evidence.name = "native-writer.usdz"
            evidence.lifetime = .keepAlways
            activity.add(evidence)
        }

        // Read back with ModelIO, independently of SceneKit and the app's
        // importer/exporter, after the writer has returned.
        let roundTrip = MDLAsset(url: url)
        let meshes = roundTrip.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        XCTAssertEqual(meshes.count, 1, runtime)
        let mesh = try XCTUnwrap(meshes.first, runtime)
        XCTAssertEqual(mesh.vertexCount, 3, runtime)
        let positions = try floats(mesh, attribute: MDLVertexAttributePosition, components: 3)
        XCTAssertTrue(positions.contains([10, 0, 0]), "The native bridge changed numeric model coordinates: \(runtime)")
        XCTAssertTrue(positions.contains([0, 20, 0]), runtime)
        let uvs = try floats(mesh, attribute: MDLVertexAttributeTextureCoordinate, components: 2)
        for expected: [Float] in [[0.1, 0.2], [0.9, 0.2], [0.1, 0.8]] {
            XCTAssertTrue(uvs.contains { abs($0[0] - expected[0]) < 0.0001 && abs($0[1] - expected[1]) < 0.0001 },
                          "Native USDZ writer lost or changed UV \(expected): \(runtime)")
        }
        let submeshes = try XCTUnwrap(mesh.submeshes as? [MDLSubmesh], runtime)
        XCTAssertEqual(submeshes.count, 1, runtime)
        let material = try XCTUnwrap(submeshes.first?.material, runtime)
        let metallic = try XCTUnwrap(material.property(with: .metallic), runtime)
        let roughness = try XCTUnwrap(material.property(with: .roughness), runtime)
        XCTAssertEqual(metallic.type, .float, runtime)
        XCTAssertEqual(roughness.type, .float, runtime)
        XCTAssertEqual(metallic.floatValue, 0.75, accuracy: 0.003, runtime)
        XCTAssertEqual(roughness.floatValue, 0.35, accuracy: 0.003, runtime)
    }

    private func makeAsset() -> MDLAsset {
        let vertices: [Float] = [
            0, 0, 0, 0, 0, 1, 0.1, 0.2,
            10, 0, 0, 0, 0, 1, 0.9, 0.2,
            0, 20, 0, 0, 0, 1, 0.1, 0.8
        ]
        let indices: [UInt32] = [0, 1, 2]
        let vertexBytes = vertices.withUnsafeBytes { Data($0) }
        let indexBytes = indices.withUnsafeBytes { Data($0) }
        let allocator = MDLMeshBufferDataAllocator()
        let descriptor = MDLVertexDescriptor()
        descriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition, format: .float3, offset: 0, bufferIndex: 0)
        descriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal, format: .float3, offset: 12, bufferIndex: 0)
        descriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate, format: .float2, offset: 24, bufferIndex: 0)
        descriptor.layouts[0] = MDLVertexBufferLayout(stride: 32)
        let material = MDLMaterial(name: "ProbeMaterial", scatteringFunction: MDLPhysicallyPlausibleScatteringFunction())
        material.removeAllProperties()
        material.setProperty(MDLMaterialProperty(name: "baseColor", semantic: .baseColor, float3: SIMD3(0.2, 0.4, 0.8)))
        material.setProperty(MDLMaterialProperty(name: "metallic", semantic: .metallic, float: 0.75))
        material.setProperty(MDLMaterialProperty(name: "roughness", semantic: .roughness, float: 0.35))
        let submesh = MDLSubmesh(indexBuffer: allocator.newBuffer(with: indexBytes, type: .index),
                                indexCount: 3, indexType: .uInt32, geometryType: .triangles, material: material)
        let mesh = MDLMesh(vertexBuffer: allocator.newBuffer(with: vertexBytes, type: .vertex), vertexCount: 3,
                           descriptor: descriptor, submeshes: [submesh])
        mesh.name = "CapabilityTriangle"
        let asset = MDLAsset()
        asset.add(mesh)
        return asset
    }

    private func floats(_ mesh: MDLMesh, attribute: String, components: Int) throws -> [[Float]] {
        let data = try XCTUnwrap(mesh.vertexAttributeData(forAttributeNamed: attribute, as: components == 3 ? .float3 : .float2))
        return (0..<mesh.vertexCount).map { index in
            (0..<components).map { component in
                data.dataStart.advanced(by: index * data.stride + component * 4).loadUnaligned(as: Float.self)
            }
        }
    }
}
