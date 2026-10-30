import XCTest
import ModelIO
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import simd
@testable import FloeCAD

/// A native SceneKit USDZ export with independent ModelIO/stored-ZIP readers.
/// Tests never call the app's mesh/material importer to validate the exporter.
@MainActor
final class CADUSDZMaterialExportTests: XCTestCase {
    private var workDir: URL!
    private var staging: URL!
    // MDLObject.parent is weak. Retain the entire imported hierarchy until
    // teardown so world-transform assertions do not lose their unit ancestor
    // when a test intentionally ignores the tuple's asset return value.
    private var importedAssets: [MDLAsset] = []

    override func setUp() async throws {
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("CADUSDZ-\(UUID().uuidString)")
        staging = workDir.appendingPathComponent("staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        importedAssets.removeAll()
        if let workDir { try FileManager.default.removeItem(at: workDir) }
    }

    private func requireExporter() throws {
        guard USDZExporter.isSupported else { throw XCTSkip("This runtime's native USDZ writer probe failed.") }
    }

    func testNativeWriterSupportIsNotBlockedByModelIOExportCapability() throws {
        let runtime = ProcessInfo.processInfo.operatingSystemVersionString
        XCTAssertTrue(USDZExporter.isSupported,
                      "Native USDZ writer capability failed on \(runtime); ModelIO export=\(MDLAsset.canExportFileExtension("usdz"))")
        let result = USDZExporter.export(bodies: [triangle()], temporaryDirectory: staging)
        XCTAssertTrue(result.succeeded, "\(runtime): \(result.diagnostics)")
        XCTAssertNotNil(result.data)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testNativeWriterProbeCleansOwnedScratchOnSuccessAndFailure() throws {
        XCTAssertTrue(USDZExporter.probeNativeWriter(temporaryDirectory: staging),
                      ProcessInfo.processInfo.operatingSystemVersionString)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        let unrelated = staging.appendingPathComponent("caller-owned.txt")
        let retained = Data("retain this caller file".utf8)
        try retained.write(to: unrelated)
        XCTAssertFalse(USDZExporter.probeNativeWriter(temporaryDirectory: unrelated),
                       "a file cannot be used as a probe's parent directory")
        XCTAssertEqual(try Data(contentsOf: unrelated), retained)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), ["caller-owned.txt"])
    }

    func testCapabilityRecoversAfterTemporaryIOFailureWithoutRestart() throws {
        let unavailableParent = workDir.appendingPathComponent("not-a-directory")
        let retained = Data("caller-owned file".utf8)
        try retained.write(to: unavailableParent)
        var cache = USDZExporter.WriterCapabilityCache()
        var uptime: TimeInterval = 100
        XCTAssertFalse(cache.check(clock: { uptime }) {
            USDZExporter.probeNativeWriter(temporaryDirectory: unavailableParent)
        })
        uptime = 101
        XCTAssertFalse(cache.check(clock: { uptime }) {
            XCTFail("temporary I/O failures must coalesce during the short cooldown")
            return true
        })
        uptime = 103
        XCTAssertTrue(cache.check(clock: { uptime }) {
            USDZExporter.probeNativeWriter(temporaryDirectory: staging)
        }, "restored writable storage must recover capability without a process restart")
        uptime = 104
        XCTAssertTrue(cache.check(clock: { uptime }) {
            XCTFail("a successful capability probe should remain cached")
            return false
        })
        XCTAssertEqual(try Data(contentsOf: unavailableParent), retained)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    private func triangle(_ name: String = "Triangle", uv: Bool = false) -> Body {
        let mesh = RenderMesh(positions: [SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(0, 20, 0)],
                              normals: Array(repeating: SIMD3(0, 0, 1), count: 3), indices: [0, 1, 2],
                              texcoords: uv ? [SIMD2(0.1, 0.2), SIMD2(0.9, 0.2), SIMD2(0.1, 0.8)] : nil)
        return Body(id: BodyID(), name: name, transform: .identity, primitive: nil, render: mesh, revision: 1)
    }

    private func exported(_ bodies: [Body]) throws -> (Data, MDLAsset, [MDLMesh]) {
        try requireExporter()
        let result = USDZExporter.export(bodies: bodies, temporaryDirectory: staging)
        XCTAssertTrue(result.succeeded, "\(result.diagnostics)")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty,
                      "staging resources must be gone before returning the archive")
        let data = try XCTUnwrap(result.data)
        let url = workDir.appendingPathComponent("roundtrip-\(UUID().uuidString).usdz")
        try data.write(to: url)
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        XCTAssertEqual(meshes.count, bodies.count)
        importedAssets.append(asset)
        return (data, asset, meshes)
    }

    private func material(_ mesh: MDLMesh) throws -> MDLMaterial {
        let submeshes = try XCTUnwrap(mesh.submeshes as? [MDLSubmesh])
        XCTAssertEqual(submeshes.count, 1)
        return try XCTUnwrap(submeshes.first?.material)
    }

    private func scalar(_ material: MDLMaterial, _ semantic: MDLMaterialSemantic) throws -> Float {
        let property = try XCTUnwrap(material.property(with: semantic))
        XCTAssertEqual(property.type, .float, "semantic \(semantic.rawValue) must remain a scalar")
        return property.floatValue
    }

    private func color(_ material: MDLMaterial, _ semantic: MDLMaterialSemantic) throws -> SIMD3<Float> {
        let property = try XCTUnwrap(material.property(with: semantic))
        switch property.type {
        case .float3: return property.float3Value
        case .float4: return SIMD3(property.float4Value.x, property.float4Value.y, property.float4Value.z)
        case .color:
            // Compare to the application's display-encoded sRGB canonical
            // factors, not device-dependent RGB or physical linear values.
            let canonicalSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedSRGB))
            let converted = try XCTUnwrap(property.color?.converted(to: canonicalSpace, intent: .defaultIntent, options: nil))
            let c = try XCTUnwrap(converted.components)
            return SIMD3(Float(c[0]), Float(c[1]), Float(c[2]))
        default:
            XCTFail("semantic \(semantic.rawValue) lost its color value")
            return .zero
        }
    }

    private func attribute(_ mesh: MDLMesh, _ name: String, count: Int) throws -> [[Float]] {
        let data = try XCTUnwrap(mesh.vertexAttributeData(forAttributeNamed: name, as: count == 3 ? .float3 : .float2))
        return (0..<mesh.vertexCount).map { vertex in
            (0..<count).map { component in
                data.dataStart.advanced(by: vertex * data.stride + component * 4).loadUnaligned(as: Float.self)
            }
        }
    }

    private func worldPositions(_ mesh: MDLMesh) throws -> [SIMD3<Float>] {
        let world = MDLTransform.globalTransform(with: mesh, atTime: 0)
        return try attribute(mesh, MDLVertexAttributePosition, count: 3).map { point in
            let p = world * SIMD4(point[0], point[1], point[2], 1)
            return SIMD3(p.x, p.y, p.z)
        }
    }

    func testTenMillimetresExportsAsOneCentimetreInComposedWorldSpace() throws {
        let (_, _, meshes) = try exported([triangle()])
        let mesh = try XCTUnwrap(meshes.first)
        // Raw buffers retain the existing millimetre contract. Physical size
        // requires composing the exported node transform as an external viewer.
        XCTAssertTrue(try attribute(mesh, MDLVertexAttributePosition, count: 3).contains([10, 0, 0]))
        let points = try worldPositions(mesh)
        let widthMetres = try XCTUnwrap(points.map(\.x).max()) - XCTUnwrap(points.map(\.x).min())
        let heightMetres = try XCTUnwrap(points.map(\.y).max()) - XCTUnwrap(points.map(\.y).min())
        XCTAssertEqual(widthMetres, 0.01, accuracy: 1e-7, "10 mm must be 0.01 m, not 10 m")
        XCTAssertEqual(heightMetres, 0.02, accuracy: 1e-7)
    }

    func testMillimetreConversionIncludesRotatedScaledAndTranslatedBodyPlacement() throws {
        var body = triangle("Placed")
        body.transform.scale = 2
        body.transform.rotation = simd_quatd(angle: .pi / 2, axis: SIMD3(0, 0, 1))
        body.transform.translation = SIMD3(10, 20, 30)
        let (_, _, meshes) = try exported([body])
        let points = try worldPositions(try XCTUnwrap(meshes.first))
        // Independently calculated: rotate the doubled triangle 90 degrees
        // around Z, then translate in mm; the exported hierarchy converts all
        // coordinates, including translation, to metres exactly once.
        let expected: [SIMD3<Float>] = [SIMD3(0.01, 0.02, 0.03), SIMD3(0.01, 0.04, 0.03), SIMD3(-0.03, 0.02, 0.03)]
        XCTAssertEqual(points.count, expected.count)
        for point in expected {
            XCTAssertTrue(points.contains { simd_distance($0, point) < 1e-7 },
                          "missing correctly placed metre-space vertex \(point), got \(points)")
        }
    }

    private func assertColor(_ actual: SIMD3<Float>, _ expected: SIMD3<Float>, file: StaticString = #filePath, line: UInt = #line) {
        for index in 0..<3 { XCTAssertEqual(actual[index], expected[index], accuracy: 0.003, file: file, line: line) }
    }

    func testHistoricalUntexturedBodyExportsDefaultMaterialAndMillimetres() throws {
        let body = triangle()
        let (bytes, _, meshes) = try exported([body])
        let mesh = try XCTUnwrap(meshes.first)
        let appearance = try material(mesh)
        assertColor(try color(appearance, .baseColor), SIMD3(0.72, 0.74, 0.78))
        XCTAssertEqual(try scalar(appearance, .metallic), 0, accuracy: 0.001)
        XCTAssertEqual(try scalar(appearance, .roughness), 0, accuracy: 0.001)
        let positions = try attribute(mesh, MDLVertexAttributePosition, count: 3)
        XCTAssertTrue(positions.contains([10, 0, 0]), "the established millimetre coordinate contract must remain unchanged")
        XCTAssertTrue(positions.contains([0, 20, 0]))
        XCTAssertTrue(try zipEntries(bytes).keys.contains { $0.hasSuffix(".usdc") || $0.hasSuffix(".usd") || $0.hasSuffix(".usda") })
        XCTAssertNotNil(USDZExporter.usdz(bodies: [body]), "the existing caller signature must keep working")
    }

    func testIndependentBodyPBRAndWorldPlacementSurviveRoundTrip() throws {
        var first = triangle("First")
        first.transform.translation = SIMD3(10, 20, 30)
        first.transform.scale = 2
        first.material = BodyMaterialSpec(baseColor: SIMD4(0.2, 0.4, 0.8, 1), metallic: 0.75, roughness: 0.35)
        first.material?.opacity = 0.45
        first.material?.emissive = SIMD3(0.1, 0.2, 0.3)
        first.material?.emissiveStrength = 2
        var second = triangle("Second")
        second.material = BodyMaterialSpec(baseColor: SIMD4(0.9, 0.1, 0.2, 1), metallic: 0.1, roughness: 0.85)
        let (_, _, meshes) = try exported([first, second])
        let firstMesh = try XCTUnwrap(meshes.first { $0.name == "First" })
        let a = try material(firstMesh)
        assertColor(try color(a, .baseColor), SIMD3(0.2, 0.4, 0.8))
        assertColor(try color(a, .emission), SIMD3(0.2, 0.4, 0.6))
        XCTAssertEqual(try scalar(a, .metallic), 0.75, accuracy: 0.003)
        XCTAssertEqual(try scalar(a, .roughness), 0.35, accuracy: 0.003)
        XCTAssertEqual(try scalar(a, .opacity), 0.45, accuracy: 0.003)
        let positions = try attribute(firstMesh, MDLVertexAttributePosition, count: 3)
        XCTAssertTrue(positions.contains([10, 20, 30]))
        XCTAssertTrue(positions.contains([30, 20, 30]))
        XCTAssertTrue(positions.contains([10, 60, 30]))
        let b = try material(try XCTUnwrap(meshes.first { $0.name == "Second" }))
        assertColor(try color(b, .baseColor), SIMD3(0.9, 0.1, 0.2))
        XCTAssertEqual(try scalar(b, .roughness), 0.85, accuracy: 0.003)
    }

    func testUVAndAllPBRTextureResourcesAreEmbeddedAndReadableAfterStagingRemoval() throws {
        var body = triangle(uv: true)
        var spec = BodyMaterialSpec(baseColor: SIMD4(repeating: 1), metallic: 1, roughness: 1)
        spec.baseColorTexture = try png([255, 0, 0, 255, 0, 0, 255, 255], width: 1, height: 2)
        spec.metallicTexture = try png([64, 64, 64, 255])
        spec.roughnessTexture = try png([192, 192, 192, 255])
        spec.normalTexture = try png([128, 128, 255, 255])
        spec.emissiveTexture = try png([0, 255, 0, 255])
        spec.emissive = SIMD3(repeating: 1)
        spec.opacityTexture = try png([128, 128, 128, 255, 64, 64, 64, 255], width: 1, height: 2)
        body.material = spec
        let (archive, _, meshes) = try exported([body])
        let mesh = try XCTUnwrap(meshes.first)
        let uvs = try attribute(mesh, MDLVertexAttributeTextureCoordinate, count: 2)
        for expected: [Float] in [[0.1, 0.8], [0.9, 0.8], [0.1, 0.2]] {
            XCTAssertTrue(uvs.contains { abs($0[0] - expected[0]) < 0.0001 && abs($0[1] - expected[1]) < 0.0001 })
        }
        let appearance = try material(mesh)
        let basePixels = try texturePixels(appearance, .baseColor)
        XCTAssertEqual(basePixels, [255, 0, 0, 255, 0, 0, 255, 255], "the two authored rows must keep their orientation")
        XCTAssertEqual(try texturePixels(appearance, .metallic).first, 64)
        XCTAssertEqual(try texturePixels(appearance, .roughness).first, 192)
        XCTAssertEqual(try texturePixels(appearance, .tangentSpaceNormal), [128, 128, 255, 255])
        XCTAssertEqual(try texturePixels(appearance, .emission), [0, 255, 0, 255])
        XCTAssertEqual(try texturePixels(appearance, .opacity).first, 128)
        let images = try zipEntries(archive).values.filter { MaterialImageSniffer.mimeType(of: $0) != nil }
        XCTAssertGreaterThanOrEqual(images.count, 6, "all resource channels must be inside the returned USDZ")
        XCTAssertTrue(images.contains { (try? imagePixels($0)) == basePixels })
        XCTAssertEqual(body.render.texcoords, [SIMD2(0.1, 0.2), SIMD2(0.9, 0.2), SIMD2(0.1, 0.8)], "export must not mutate source UVs")
    }

    func testMapFactorsAndAlbedoAlphaAreBakedRatherThanLost() throws {
        var body = triangle(uv: true)
        var spec = BodyMaterialSpec(baseColor: SIMD4(0.5, 1, 1, 1), metallic: 0.5, roughness: 0.25)
        spec.baseColorTexture = try png([255, 0, 0, 128])
        spec.opacity = 0.5
        spec.opacityTexture = try png([128, 128, 128, 255])
        spec.metallicTexture = try png([128, 128, 128, 255])
        spec.roughnessTexture = try png([128, 128, 128, 255])
        body.material = spec
        let (_, _, meshes) = try exported([body])
        let m = try material(try XCTUnwrap(meshes.first))
        // sRGB(1) * linear factor 0.5 -> sRGB 188; scalar maps stay linear.
        XCTAssertEqual(Float(try texturePixels(m, .baseColor)[0]), 188, accuracy: 1)
        XCTAssertEqual(Float(try texturePixels(m, .metallic)[0]), 64, accuracy: 1)
        XCTAssertEqual(Float(try texturePixels(m, .roughness)[0]), 32, accuracy: 1)
        XCTAssertEqual(Float(try texturePixels(m, .opacity)[0]), 32, accuracy: 1)
    }

    func testTextureMetadataControlsLinearColorAndBottomLeftRows() throws {
        var body = triangle(uv: true)
        let bytes = try png([128, 128, 128, 255, 255, 0, 0, 255], width: 1, height: 2)
        var spec = BodyMaterialSpec(baseColor: SIMD4(repeating: 1))
        spec.baseColorTexture = bytes
        spec.textureMetadata = [CADMaterialTextureMetadata(assetID: UUID(), slot: .baseColor, mimeType: "image/png",
                                                          colorSpace: .linear, orientation: .bottomLeft,
                                                          sha256: CADMaterialTexture.digest(bytes), byteCount: bytes.count)]
        body.material = spec
        let (_, _, meshes) = try exported([body])
        let pixels = try texturePixels(try material(try XCTUnwrap(meshes.first)), .baseColor)
        XCTAssertEqual(Array(pixels.prefix(4)), [255, 0, 0, 255])
        for channel in 4..<7 { XCTAssertEqual(Float(pixels[channel]), 188, accuracy: 1) }
    }

    func testStaleTextureIdentityFailsRatherThanRelabelingCurrentBytes() throws {
        try requireExporter()
        var body = triangle(uv: true)
        let bytes = try png([255, 0, 0, 255])
        var spec = BodyMaterialSpec(baseColor: SIMD4(repeating: 1))
        spec.baseColorTexture = bytes
        spec.textureMetadata = [CADMaterialTextureMetadata(assetID: UUID(), slot: .baseColor, mimeType: "image/png",
                                                          colorSpace: .srgb, orientation: .topLeft,
                                                          sha256: String(repeating: "0", count: 64), byteCount: bytes.count)]
        body.material = spec
        let result = USDZExporter.export(bodies: [body], temporaryDirectory: staging)
        XCTAssertNil(result.data)
        XCTAssertEqual(result.diagnostics.first?.code, "textureIdentityMismatch")
        XCTAssertEqual(result.diagnostics.first?.textureSlot, .baseColor)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testExplicitProjectionUsesExistingMaterialProjector() throws {
        var body = triangle()
        var spec = BodyMaterialSpec(baseColor: SIMD4(repeating: 1))
        spec.baseColorTexture = try png([0, 255, 0, 255])
        spec.uvMapping = CADMaterialUVMapping(source: .planarProjection, axis: .z, scaleMM: SIMD2(10, 20))
        body.material = spec
        let (_, _, meshes) = try exported([body])
        let uv = try attribute(try XCTUnwrap(meshes.first), MDLVertexAttributeTextureCoordinate, count: 2)
        XCTAssertTrue(uv.contains([0, 1]))
        XCTAssertTrue(uv.contains([1, 1]))
        XCTAssertTrue(uv.contains([0, 0]))
    }

    func testMissingTextureBytesReportsSlotAndReturnsNoDowngradedArchive() throws {
        try requireExporter()
        var body = triangle(uv: true)
        let bytes = try png([255, 255, 255, 255])
        var spec = BodyMaterialSpec()
        spec.textureMetadata = [CADMaterialTextureMetadata(assetID: UUID(), slot: .normal, mimeType: "image/png",
                                                          colorSpace: .linear, orientation: .topLeft,
                                                          sha256: CADMaterialTexture.digest(bytes), byteCount: bytes.count)]
        body.material = spec
        let result = USDZExporter.export(bodies: [body], temporaryDirectory: staging)
        XCTAssertNil(result.data)
        XCTAssertEqual(result.diagnostics.first?.code, "missingTexture")
        XCTAssertEqual(result.diagnostics.first?.bodyID, body.id.raw)
        XCTAssertEqual(result.diagnostics.first?.textureSlot, .normal)
        XCTAssertNil(USDZExporter.usdz(bodies: [body]))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testInvalidMapAndMissingUVsFailWithoutLeakingTemporaryResources() throws {
        try requireExporter()
        var invalid = triangle(uv: true)
        invalid.material = BodyMaterialSpec()
        invalid.material?.baseColorTexture = Data("not an image".utf8)
        let result = USDZExporter.export(bodies: [invalid], temporaryDirectory: staging)
        XCTAssertNil(result.data)
        XCTAssertEqual(result.diagnostics.first?.code, "invalidTexture")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        var missingUV = triangle()
        missingUV.material = BodyMaterialSpec()
        missingUV.material?.baseColorTexture = try png([255, 255, 255, 255])
        let missing = USDZExporter.export(bodies: [missingUV], temporaryDirectory: staging)
        XCTAssertNil(missing.data)
        XCTAssertEqual(missing.diagnostics.first?.code, "missingUVs")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testFaceOverridesAndUnsupportedEmissionDoNotBecomeBodyMaterialFallbacks() throws {
        try requireExporter()
        var body = triangle(uv: true)
        let signature = FaceSignature(kind: .planar, normal: SIMD3(0, 0, 1), centroid: .zero, area: 1, planeOffset: 0)
        body.materialFaceBindings = [CADFaceMaterialBinding(key: CADFaceKey(signature: signature), material: .default)]
        let face = USDZExporter.export(bodies: [body], temporaryDirectory: staging)
        XCTAssertNil(face.data)
        XCTAssertEqual(face.diagnostics.first?.code, "unsupportedFaceMaterials")
        body.materialFaceBindings = []
        body.material = BodyMaterialSpec()
        body.material?.emissive = SIMD3(repeating: 1)
        body.material?.emissiveStrength = 2
        body.material?.emissiveTexture = try png([255, 255, 255, 255])
        let emission = USDZExporter.export(bodies: [body], temporaryDirectory: staging)
        XCTAssertNil(emission.data)
        XCTAssertEqual(emission.diagnostics.first?.code, "unsupportedHDREmission")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testScalarHDREmissionIsRejectedInsteadOfClippedByNativeColorBridge() throws {
        try requireExporter()
        var body = triangle()
        body.material = BodyMaterialSpec()
        body.material?.emissive = SIMD3(0.4, 0.6, 0.8)
        body.material?.emissiveStrength = 2
        let result = USDZExporter.export(bodies: [body], temporaryDirectory: staging)
        XCTAssertNil(result.data)
        XCTAssertEqual(result.diagnostics.first?.code, "unsupportedHDREmission")
        XCTAssertEqual(result.diagnostics.first?.textureSlot, .emissive)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testFailureAfterTextureStagingCleansOnlyItsOwnResources() throws {
        try requireExporter()
        let unrelated = staging.appendingPathComponent("caller-owned.txt")
        let retained = Data("keep this independent file".utf8)
        try retained.write(to: unrelated)
        var body = triangle(uv: true)
        body.material = BodyMaterialSpec(baseColor: SIMD4(repeating: 1))
        body.material?.baseColorTexture = try png([255, 0, 0, 255, 0, 0, 255, 255], width: 1, height: 2)
        body.material?.opacityTexture = try png([128, 128, 128, 255])
        // The albedo image has already been staged when the adapter detects
        // incompatible opacity dimensions. This exercises failure cleanup.
        let result = USDZExporter.export(bodies: [body], temporaryDirectory: staging)
        XCTAssertNil(result.data)
        XCTAssertEqual(result.diagnostics.first?.code, "unsupportedOpacityDimensions")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), ["caller-owned.txt"])
        XCTAssertEqual(try Data(contentsOf: unrelated), retained)
    }

    private func texturePixels(_ material: MDLMaterial, _ semantic: MDLMaterialSemantic) throws -> [UInt8] {
        let property = try XCTUnwrap(material.property(with: semantic))
        XCTAssertEqual(property.type, .texture, "semantic \(semantic.rawValue) must retain its texture relationship")
        let texture = try XCTUnwrap(property.textureSamplerValue?.texture)
        let image = try XCTUnwrap(texture.imageFromTexture()?.takeUnretainedValue())
        return try rgba(image)
    }

    private func png(_ bytes: [UInt8], width: Int = 1, height: Int = 1) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }

    private func imagePixels(_ data: Data) throws -> [UInt8] {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try rgba(try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(success)
        return bytes
    }

    /// USDZ requires uncompressed ZIP entries. Validate the binary container
    /// and extract image bytes independently of ModelIO's resource resolver.
    private func zipEntries(_ archive: Data) throws -> [String: Data] {
        let bytes = [UInt8](archive)
        func uint(_ offset: Int, _ count: Int) throws -> Int {
            guard offset >= 0, offset + count <= bytes.count else { throw NSError(domain: "TruncatedZIP", code: 1) }
            return (0..<count).reduce(0) { $0 | Int(bytes[offset + $1]) << (8 * $1) }
        }
        var cursor = 0
        var result: [String: Data] = [:]
        while try uint(cursor, 4) == 0x04034b50 {
            let flags = try uint(cursor + 6, 2)
            XCTAssertEqual(flags & 8, 0, "USDZ local headers must declare their resource sizes")
            XCTAssertEqual(try uint(cursor + 8, 2), 0, "USDZ resources must be stored, not compressed")
            let size = try uint(cursor + 18, 4)
            XCTAssertEqual(try uint(cursor + 22, 4), size)
            let nameLength = try uint(cursor + 26, 2)
            let extraLength = try uint(cursor + 28, 2)
            let start = cursor + 30 + nameLength + extraLength
            guard start + size <= bytes.count, cursor + 30 + nameLength <= bytes.count else { throw NSError(domain: "TruncatedZIP", code: 2) }
            let name = String(decoding: bytes[(cursor + 30)..<(cursor + 30 + nameLength)], as: UTF8.self)
            XCTAssertFalse(name.hasPrefix("/"))
            XCTAssertFalse(name.split(separator: "/").contains(".."))
            XCTAssertEqual(start % 64, 0, "USDZ payloads must be 64-byte aligned")
            result[name] = Data(bytes[start..<(start + size)])
            cursor = start + size
        }
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(try uint(cursor, 4), 0x02014b50, "local entries must end at the central directory")
        return result
    }
}
