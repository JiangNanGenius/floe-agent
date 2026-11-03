import CoreGraphics
import Foundation
import ImageIO
import XCTest
#if canImport(RealityKit)
import RealityKit
#endif
@testable import FloeCAD

@MainActor
final class CADTextureImportTests: XCTestCase {
    private let colors: [[UInt8]] = [
        [220, 40, 30, 255], [30, 210, 60, 255],
        [40, 60, 220, 128], [220, 190, 30, 255],
        [200, 40, 190, 255], [30, 190, 200, 255],
    ]

    func testKeepOriginalPreservesRealPixelsAlphaAndEncodedBytes() throws {
        let bytes = try image(width: 2, height: 2, pixels: Array(colors.prefix(4)))
        let input = selection(bytes, slot: .baseColor, choice: .original)
        let prepared = try CADTextureImport.prepare([input], existing: [])
        let texture = try XCTUnwrap(prepared.textures.first)
        XCTAssertEqual(texture.bytes, bytes)
        XCTAssertEqual(texture.colorSpace, .srgb)
        XCTAssertEqual(texture.orientation, .topLeft)
        XCTAssertFalse(try XCTUnwrap(prepared.receipts.first).converted)
        let actual = try pixels(texture.bytes)
        assertPixel(actual, at: 0, equals: colors[0])
        assertPixel(actual, at: 2, equals: colors[2], tolerance: 2)
        let preview = try pixels(try XCTUnwrap(prepared.receipts.first).readBackPreviewPNG)
        XCTAssertEqual(preview.width, 2)
        assertPixel(preview, at: 2, equals: colors[2], tolerance: 2)
    }

    func testExplicitTIFFConversionAppliesExifAndKeepsAlphaInActualPixels() throws {
        let source = try image(width: 2, height: 3, pixels: colors, type: "public.tiff", orientation: 6)
        let header = try CADTextureImport.inspect(source)
        XCTAssertEqual(header.exifOrientation, 6)
        XCTAssertFalse(header.canKeepOriginal)
        XCTAssertThrowsError(try CADTextureImport.prepare([selection(source, choice: .original)], existing: [])) {
            XCTAssertEqual($0 as? CADTextureImport.Failure, .originalNeedsConversion)
        }
        let prepared = try CADTextureImport.prepare([selection(source, choice: .png1024)], existing: [])
        let texture = try XCTUnwrap(prepared.textures.first)
        let output = try pixels(texture.bytes)
        XCTAssertEqual(output.width, 3)
        XCTAssertEqual(output.height, 2)
        // EXIF 6 rotates A B / C D / E F clockwise to E C A / F D B.
        for (index, colorIndex) in [4, 2, 0, 5, 3, 1].enumerated() {
            assertPixel(output, at: index, equals: colors[colorIndex], tolerance: 2)
        }
        let readBack = try pixels(try XCTUnwrap(prepared.receipts.first).readBackPreviewPNG)
        for (index, colorIndex) in [4, 2, 0, 5, 3, 1].enumerated() {
            assertPixel(readBack, at: index, equals: colors[colorIndex], tolerance: 2)
        }
        XCTAssertEqual(try CADTextureImport.inspect(texture.bytes).exifOrientation, 1)
        XCTAssertEqual(texture.orientation, .topLeft, "Photo EXIF and CAD sampling origin must not be applied twice")
        XCTAssertEqual(try CADTextureImport.inspect(source), header, "The original bytes and metadata stay intact")
    }

    func testP3ColorConversionAndLinearDataMapHaveDifferentCorrectPixelSemantics() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let sample: [UInt8] = [180, 80, 40, 128]
        let source = try image(width: 1, height: 1, pixels: [sample], space: p3)
        let color = try CADTextureImport.prepare([selection(source, slot: .baseColor, choice: .png512)], existing: [])
        let data = try CADTextureImport.prepare([selection(source, slot: .normal, choice: .png512)], existing: [])
        let colorPixels = try pixels(try XCTUnwrap(color.textures.first).bytes)
        let dataPixels = try pixels(try XCTUnwrap(data.textures.first).bytes)
        // Independent Display-P3 -> linear sRGB primary matrix, followed by
        // the standard transfer. Do not accept relabelled P3 bytes as sRGB.
        let linear = sample.prefix(3).map { srgbToLinear(Double($0) / 255) }
        let transformed = [
            1.224745 * linear[0] - 0.224904 * linear[1],
            -0.042058 * linear[0] + 1.042081 * linear[1],
            -0.019642 * linear[0] - 0.078655 * linear[1] + 1.098537 * linear[2],
        ].map { UInt8((linearToSRGB($0) * 255).rounded()) } + [sample[3]]
        assertPixel(colorPixels, at: 0, equals: transformed, tolerance: 4)
        assertPixel(dataPixels, at: 0, equals: sample, tolerance: 2)
        XCTAssertEqual(color.textures.first?.colorSpace, .srgb)
        XCTAssertEqual(data.textures.first?.colorSpace, .linear)
        XCTAssertNotEqual(Array(colorPixels.rgba.prefix(3)), Array(dataPixels.rgba.prefix(3)))
    }

    func testSixteenBitPNGRequiresChoiceAndQuantizesRealSamplesOnlyAfterConfirmation() throws {
        let values: [UInt16] = [0, 32768, 65535, 65535, 16384, 49152, 32768, 32768]
        let raw = values.flatMap { [UInt8($0 >> 8), UInt8($0 & 255)] }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(raw) as CFData))
        let cg = try XCTUnwrap(CGImage(width: 2, height: 1, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: 16, space: space,
            bitmapInfo: [.byteOrder16Big, CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)],
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let source = try encode(cg, type: "public.png")
        XCTAssertEqual(try CADTextureImport.inspect(source).depth, 16)
        XCTAssertThrowsError(try CADTextureImport.prepare([selection(source, choice: .original)], existing: []))
        let prepared = try CADTextureImport.prepare([selection(source, choice: .png512)], existing: [])
        let texture = try XCTUnwrap(prepared.textures.first)
        XCTAssertEqual(try CADTextureImport.inspect(texture.bytes).depth, 8)
        let actual = try pixels(texture.bytes)
        assertPixel(actual, at: 0, equals: [0, 128, 255, 255], tolerance: 2)
        assertPixel(actual, at: 1, equals: [64, 191, 128, 128], tolerance: 3)
        XCTAssertEqual(prepared.receipts.first?.sourceSHA256, CADMaterialTexture.digest(source))
    }

    func testGrayDataMapConversionKeepsNumericValuesWithoutGammaTransfer() throws {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.genericGrayGamma2_2))
        let provider = try XCTUnwrap(CGDataProvider(data: Data([UInt8(0), 64, 128, 255]) as CFData))
        let image = try XCTUnwrap(CGImage(width: 4, height: 1, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 4, space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let source = try encode(image, type: "public.png")
        let prepared = try CADTextureImport.prepare([selection(source, slot: .roughness, choice: .png512)], existing: [])
        let output = try pixels(try XCTUnwrap(prepared.textures.first).bytes)
        for (index, value) in [UInt8(0), 64, 128, 255].enumerated() {
            assertPixel(output, at: index, equals: [value, value, value, 255], tolerance: 1)
        }
        XCTAssertEqual(prepared.textures.first?.colorSpace, .linear)
    }

    func testLargeRealImageNeedsSmallerOptionAndKeepsSpatialAppearance() throws {
        // Four real quadrants, not a forged header. This file is small on disk
        // but its full-resolution mip chain does not fit the resident budget.
        let source = try quadrantImage(width: 4096, height: 4096)
        let original = selection(source, choice: .original)
        XCTAssertTrue(try CADTextureImport.inspect(source).canKeepOriginal)
        XCTAssertFalse(try CADTextureImport.budget([original], existing: []).fits)
        XCTAssertThrowsError(try CADTextureImport.prepare([original], existing: [])) {
            XCTAssertEqual($0 as? CADTextureImport.Failure, .memoryBudget)
        }
        let result = try CADTextureImport.prepare([selection(source, choice: .png1024)], existing: [])
        let output = try pixels(try XCTUnwrap(result.textures.first).bytes)
        XCTAssertEqual(output.width, 1024)
        XCTAssertEqual(output.height, 1024)
        for (index, position) in [(0, 100 * 1024 + 100), (1, 100 * 1024 + 900),
                                  (2, 900 * 1024 + 100), (3, 900 * 1024 + 900)] {
            assertPixel(output, at: position, equals: colors[index], tolerance: 3)
        }
        XCTAssertTrue(result.budget.fits)
        XCTAssertEqual(result.budget.residentBytes, CADTextureImport.mipmappedBytes(width: 1024, height: 1024))
    }

    func testBudgetIncludesExistingPixelsAndSemanticUploadsAndRefusesDuplicateChannels() throws {
        let source = try quadrantImage(width: 2048, height: 2048)
        let existing = [CADMaterialTexture(slot: .baseColor, bytes: source),
                        CADMaterialTexture(slot: .normal, bytes: source)]
        let selected = [selection(source, slot: .roughness, choice: .original),
                        selection(source, slot: .metallic, choice: .original)]
        let budget = try CADTextureImport.budget(selected, existing: existing)
        XCTAssertEqual(budget.resourceCount, 4, "The same bytes in different semantic slots require separate uploads")
        XCTAssertEqual(budget.decodedBytes, 4 * 2048 * 2048 * 4)
        XCTAssertEqual(budget.residentBytes, 4 * CADTextureImport.mipmappedBytes(width: 2048, height: 2048))
        XCTAssertFalse(budget.fits)
        XCTAssertThrowsError(try CADTextureImport.prepare(selected, existing: existing)) {
            XCTAssertEqual($0 as? CADTextureImport.Failure, .memoryBudget)
        }
        XCTAssertThrowsError(try CADTextureImport.budget([selected[0], selected[0]], existing: [])) {
            XCTAssertEqual($0 as? CADTextureImport.Failure, .duplicateSlots)
        }
        XCTAssertEqual(try CADTextureImport.budget([selected[0]], existing: [existing[0], existing[0]]).resourceCount, 2)
    }

    func testMalformedBatchAndCancelledWorkerReturnNoPartialResult() async throws {
        let valid = try image(width: 2, height: 2, pixels: Array(colors.prefix(4)))
        let invalid = CADTextureImport.Source(name: "broken.png", bytes: Data(valid.prefix(20)))
        XCTAssertThrowsError(try CADTextureImport.prepare([
            selection(valid, slot: .baseColor, choice: .original),
            .init(source: invalid, slot: .roughness, choice: .png512),
        ], existing: []))
        let task = Task { try await CADTextureImport.prepareAsync([selection(valid, choice: .png512)], existing: []) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled work must not deliver textures") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    #if canImport(UIKit)
    func testDraftCancellationLateCallbacksFailureAndSaveReopenKeepActualTextures() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CADTextureImport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("textures.floecad")
        let document = try await FloeCADDocument.create(at: url, name: "Texture import")
        defer { document.close() }
        let body = Body(id: BodyID(), name: "Texture triangle", transform: .identity, primitive: nil,
            render: RenderMesh(positions: [.init(0, 0, 0), .init(20, 0, 0), .init(0, 20, 0)],
                normals: [.init(0, 0, 1), .init(0, 0, 1), .init(0, 0, 1)], indices: [0, 1, 2],
                texcoords: [.init(0, 0), .init(1, 0), .init(0, 1)]), revision: 1)
        document.session.perform(AddBodyCommand(body: body, title: "Add textured triangle"))
        var target = CADMaterialTarget.empty
        target.bodyIDs = [body.id.raw]; target.bodyNames = [body.name]
        target.bodyMeshRevisions = [body.id.raw: body.meshRevision]
        let model = CADMaterialDraftModel(document: document, target: target,
            personalStore: CADPersonalMaterialLibraryStore(fileURL: directory.appendingPathComponent("materials.json")))
        defer { model.stopObserving(); model.cancelTextureImport() }
        let source = CADTextureImport.Source(name: "rotated.tiff", bytes: try image(width: 2, height: 3,
            pixels: colors, type: "public.tiff", orientation: 6))
        let normal = CADTextureImport.Source(name: "normal.png", bytes: try image(width: 2, height: 2,
            pixels: Array(colors.prefix(4))))
        let originalChange = document.liveChangeCount
        let originalUndo = document.session.undoStack.undoCommands.count
        let token = model.beginTextureImport()
        model.cancelTextureImport()
        model.stageTextureImport([source], startingAt: .baseColor, token: token)
        model.failTextureImport(CADTextureImport.Failure.conversionFailed, token: token)
        XCTAssertNil(model.textureImportReview)
        XCTAssertNil(model.errorMessage, "An abandoned picker must not report into a new interaction")
        XCTAssertTrue(model.draft.textures.isEmpty)

        let failedToken = model.beginTextureImport()
        model.stageTextureImport([source, .init(name: "broken", bytes: Data([1, 2, 3]))],
                                 startingAt: .baseColor, token: failedToken)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.draft.textures.isEmpty)
        XCTAssertEqual(document.liveChangeCount, originalChange)

        let current = model.beginTextureImport()
        model.stageTextureImport([source, normal], startingAt: .baseColor, token: current)
        model.prepareTextureImport([.init(source: source, slot: .baseColor, choice: .png512),
                                    .init(source: normal, slot: .normal, choice: .png512)])
        let deadline = Date().addingTimeInterval(5)
        while model.isImportingTextures && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isImportingTextures)
        XCTAssertNil(model.textureImportError)
        let prepared = try XCTUnwrap(model.preparedTextureImport)
        XCTAssertTrue(model.draft.textures.isEmpty, "Preparing and read-back do not mutate even the draft")
        XCTAssertEqual(document.liveChangeCount, originalChange)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, originalUndo)
        XCTAssertTrue(model.acceptPreparedTextureImport())
        XCTAssertEqual(model.draft.textures, prepared.textures)
        XCTAssertEqual(document.liveChangeCount, originalChange, "Using textures is still a local material draft")
        model.apply()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(document.session.undoStack.undoCommands.count, originalUndo + 1)
        let saved = await document.save()
        XCTAssertTrue(saved.succeeded, saved.error ?? "")
        document.close()
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        let material = try XCTUnwrap(reopened.session.document.bodies.first?.material)
        let reopenedBytes = try XCTUnwrap(material.baseColorTexture)
        XCTAssertEqual(reopenedBytes, prepared.textures.first?.bytes)
        let reopenedNormal = try XCTUnwrap(material.normalTexture)
        XCTAssertEqual(reopenedNormal, prepared.textures.last?.bytes)
        let normalPixels = try pixels(reopenedNormal)
        for index in 0..<4 { assertPixel(normalPixels, at: index, equals: colors[index], tolerance: 2) }
        let actual = try pixels(reopenedBytes)
        for (index, colorIndex) in [4, 2, 0, 5, 3, 1].enumerated() {
            assertPixel(actual, at: index, equals: colors[colorIndex], tolerance: 2)
        }
        XCTAssertEqual(material.textureColorSpace(for: .baseColor), .srgb)
        XCTAssertEqual(material.textureOrientation(for: .baseColor), .topLeft)
        XCTAssertEqual(material.textureColorSpace(for: .normal), .linear)
        XCTAssertEqual(material.textureOrientation(for: .normal), .topLeft)
        XCTAssertEqual(CADMaterialLibraryCodec.decode(reopened.session.document.materialLibraryData)
            .entries.first?.textures.first?.bytes, reopenedBytes)
    }

    func testDraftBudgetCountsOtherBodiesFacesAndUnreplacedDraftMaps() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CADTextureBudget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try await FloeCADDocument.create(at: directory.appendingPathComponent("budget.floecad"), name: "Budget")
        defer { document.close() }
        let bytes = try image(width: 2, height: 2, pixels: Array(colors.prefix(4)))
        var other = Body(id: BodyID(), name: "Existing textures", transform: .identity, primitive: nil,
            render: RenderMesh(positions: [.init(0, 0, 0), .init(1, 0, 0), .init(0, 1, 0)],
                normals: [.init(0, 0, 1), .init(0, 0, 1), .init(0, 0, 1)], indices: [0, 1, 2]), revision: 1)
        other.material = CADMaterialDefinition(name: "Body", textures: [CADMaterialTexture(slot: .baseColor, bytes: bytes)]).bodyMaterialSpec()
        let signature = FaceSignature(kind: .planar, normal: .init(0, 0, 1), centroid: .init(0.33, 0.33, 0), area: 0.5, planeOffset: 0)
        other.materialFaceBindings = [.init(key: .init(signature: signature, capturedIndex: 1),
            material: CADMaterialDefinition(name: "Face", textures: [CADMaterialTexture(slot: .normal, bytes: bytes)]).bodyMaterialSpec())]
        document.session.perform(AddBodyCommand(body: other, title: "Existing maps"))
        let model = CADMaterialDraftModel(document: document, target: .empty,
            personalStore: CADPersonalMaterialLibraryStore(fileURL: directory.appendingPathComponent("materials.json")))
        defer { model.stopObserving(); model.cancelTextureImport() }
        model.setTexture(slot: .roughness, data: bytes, displayName: "Draft roughness")
        XCTAssertNil(model.errorMessage)
        let budget = try model.estimateTextureImport([selection(bytes, slot: .metallic, choice: .original)])
        XCTAssertEqual(budget.resourceCount, 4)
        XCTAssertEqual(budget.decodedBytes, 4 * 2 * 2 * 4)
        XCTAssertEqual(budget.residentBytes, 4 * (2 * 2 * 4 + 4))
        let token = model.beginTextureImport()
        let source = CADTextureImport.Source(name: "Latest", bytes: bytes)
        model.stageTextureImport([source], startingAt: .metallic, token: token)
        model.prepareTextureImport([.init(source: source, slot: .metallic, choice: .original)])
        let deadline = Date().addingTimeInterval(5)
        while model.isImportingTextures && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.preparedTextureImport)
        model.setName("Latest draft edit")
        let latest = model.draft
        XCTAssertFalse(model.acceptPreparedTextureImport(), "A prepared result must not overwrite later draft edits")
        XCTAssertEqual(model.draft, latest)
        XCTAssertNotNil(model.textureImportError)
        document.close()
        XCTAssertFalse(model.acceptPreparedTextureImport(), "Closing the owning document fences acceptance")
    }
    #endif

    #if canImport(RealityKit) && canImport(UIKit)
    func testPresentationCacheSequentialReplacementUsesPixelAndMipCostsAndEvictsOldImages() async throws {
        let cache = CADPresentationResourceCache()
        defer { cache.dispose() }
        for index in 0..<20 {
            let bytes = try solidImage(width: 1024, height: 1024, red: CGFloat(index + 1) / 24)
            let image = CADPresentationImage(id: CADMaterialTexture.digest(bytes), mimeType: "image/png", bytes: bytes, byteCount: bytes.count)
            let resource = await cache.texture(for: image, semantic: .color, orientation: .topLeft)
            XCTAssertNotNil(resource)
            XCTAssertGreaterThan(cache.cachedTextureBytes, bytes.count, "Compressed PNG bytes are not a GPU memory measure")
            XCTAssertLessThanOrEqual(cache.cachedTextureBytes, CADTextureImport.maximumResidentBytes)
            XCTAssertLessThanOrEqual(cache.cachedImageBytes, CADImagePackingLimits.maximumDecodedBytes)
        }
        XCTAssertLessThan(cache.textureCount, 20, "Replacing images must evict old GPU cache references")
        XCTAssertLessThan(cache.cachedImageCount, 20, "Decoded copies must also be evicted")
        XCTAssertEqual(cache.cachedTextureBytes,
            cache.textureCount * CADTextureImport.mipmappedBytes(width: 1024, height: 1024))
        XCTAssertEqual(cache.cachedImageBytes, cache.cachedImageCount * 1024 * 1024 * 4)
        cache.dispose()
        XCTAssertEqual(cache.cachedTextureBytes, 0)
        XCTAssertEqual(cache.cachedImageBytes, 0)
        XCTAssertEqual(cache.textureCount, 0)
        XCTAssertEqual(cache.cachedImageCount, 0)
    }

    func testPresentationUploadFailureAndCancellationDoNotRetainDecodedTemporaries() async throws {
        let bytes = try self.image(width: 2, height: 2, pixels: Array(colors.prefix(4)))
        let image = CADPresentationImage(id: CADMaterialTexture.digest(bytes), mimeType: "image/png", bytes: bytes, byteCount: bytes.count)
        var failedUploads = 0
        let failed = CADPresentationResourceCache(generateTexture: { decoded, _ in
            XCTAssertEqual(decoded.width, 2, "Failure is injected after a real bitmap decode")
            failedUploads += 1
            throw CADTextureImport.Failure.conversionFailed
        })
        defer { failed.dispose() }
        let failure = await failed.texture(for: image, semantic: .color, orientation: .topLeft)
        XCTAssertNil(failure)
        XCTAssertEqual(failedUploads, 1)
        XCTAssertEqual(failed.cachedImageBytes, 0)
        XCTAssertEqual(failed.cachedTextureBytes, 0)
        XCTAssertEqual(failed.cachedImageCount, 0)
        XCTAssertEqual(failed.decodeFailureIDs(), [image.id])

        var continuation: CheckedContinuation<Void, Never>?
        var started = false
        let cancelled = CADPresentationResourceCache(generateTexture: { decoded, options in
            try Task.checkCancellation()
            XCTAssertEqual(decoded.width, 2)
            started = true
            await withCheckedContinuation { continuation = $0 }
            try Task.checkCancellation()
            return try await TextureResource.generate(from: decoded, options: options)
        })
        defer { cancelled.dispose() }
        let task = Task { await cancelled.texture(for: image, semantic: .color, orientation: .topLeft) }
        let deadline = Date().addingTimeInterval(5)
        while !started && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        continuation?.resume()
        XCTAssertTrue(started)
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(cancelled.cachedImageBytes, 0)
        XCTAssertEqual(cancelled.cachedTextureBytes, 0)
        XCTAssertEqual(cancelled.cachedImageCount, 0)
        XCTAssertTrue(cancelled.decodeFailureIDs().isEmpty, "Cancellation does not poison a future retry")
    }
    #endif

    private func selection(_ bytes: Data, slot: MaterialTextureSlot = .baseColor,
                           choice: CADTextureImport.Choice) -> CADTextureImport.Selection {
        .init(source: .init(name: "pixels", bytes: bytes), slot: slot, choice: choice)
    }

    private func image(width: Int, height: Int, pixels: [[UInt8]], type: String = "public.png",
                       orientation: Int = 1, space: CGColorSpace? = nil) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels.flatMap { $0 }) as CFData))
        let colorSpace = try XCTUnwrap(space ?? CGColorSpace(name: CGColorSpace.sRGB))
        let cg = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try encode(cg, type: type, orientation: orientation)
    }

    private func encode(_ image: CGImage, type: String, orientation: Int = 1) throws -> Data {
        let data = NSMutableData()
        let output = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(output))
        return data as Data
    }

    private func quadrantImage(width: Int, height: Int) throws -> Data {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = colors[(y < height / 2 ? 0 : 2) + (x < width / 2 ? 0 : 1)]
                let position = (y * width + x) * 4
                for channel in 0..<4 { rgba[position + channel] = color[channel] }
            }
        }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let cg = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try encode(cg, type: "public.png")
    }

    private func solidImage(width: Int, height: Int, red: CGFloat) throws -> Data {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: red, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try encode(XCTUnwrap(context.makeImage()), type: "public.png")
    }

    /// Independent sRGB bitmap read-back, without using the production export
    /// pixel helper. Recover straight alpha to compare actual image appearance.
    private func pixels(_ bytes: Data) throws -> (width: Int, height: Int, rgba: [UInt8]) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try rgba.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        for pixel in stride(from: 0, to: rgba.count, by: 4) where rgba[pixel + 3] > 0 {
            let alpha = Int(rgba[pixel + 3])
            for channel in 0..<3 { rgba[pixel + channel] = UInt8(min(255, (Int(rgba[pixel + channel]) * 255 + alpha / 2) / alpha)) }
        }
        return (image.width, image.height, rgba)
    }

    private func assertPixel(_ image: (width: Int, height: Int, rgba: [UInt8]), at index: Int,
                             equals expected: [UInt8], tolerance: Int = 1,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard index * 4 + 3 < image.rgba.count else { return XCTFail("Missing real pixel", file: file, line: line) }
        for channel in 0..<4 {
            XCTAssertLessThanOrEqual(abs(Int(image.rgba[index * 4 + channel]) - Int(expected[channel])), tolerance,
                                    "pixel \(index), channel \(channel)", file: file, line: line)
        }
    }

    private func srgbToLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private func linearToSRGB(_ value: Double) -> Double {
        let value = min(1, max(0, value))
        return value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}
