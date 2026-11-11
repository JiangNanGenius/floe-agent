#if os(iOS)
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import FloeToolboxCore
import FloeToolboxUtilities
@testable import FloeToolboxWorkbenches

@Suite(.serialized)
@MainActor
struct PhotoMeasurementMediaTests {
    @Test func largePNGExportKeepsImageAndAnnotationsInTheSamePixelSpace() throws {
        let image = try fixtureImage(width: 8192, height: 1024, landmark: true)
        let fixturePNG = try png(image)
        Attachment.record(Array(fixturePNG), named: "photo-fixture-8192x1024.png")
        let sourceBlue = try rgba(image, x: 6100, y: 512)
        var store = PhotoMeasureStore()
        store.beginImage(UUID())
        try store.addReferencePoint(PhotoPoint(3200, 512))
        try store.addReferencePoint(PhotoPoint(4800, 512))
        try store.applyCalibration(value: 1, unit: .meter)
        let reference = try #require(store.calibration)
        let png = try PhotoMeasureModel.renderAnnotatedPNG(
            image: image, pixels: PhotoPoint(8192, 1024), reference: reference,
            store: store, mode: .length, unit: .meter)
        Attachment.record(Array(png), named: "photo-export-4096x512.png")
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
        let exported = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(exported.width == 4096 && exported.height == 512)

        // The source's blue landmark and the orange reference line must each
        // move by the same 0.5 output scale. The old double map put the line at
        // x=800...1200, y=128 instead of x=1600...2400, y=256.
        let blue = try rgba(exported, x: 3050, y: 256)
        let referencePixel = try rgba(exported, x: 1800, y: 256)
        let oldDoubleScaledPosition = try rgba(exported, x: 900, y: 128)
        Attachment.record("""
            Fixture \(image.width)x\(image.height), RGBA(6100,512): \(sourceBlue)
            Export \(exported.width)x\(exported.height), RGBA(3050,256): \(blue)
            Reference RGBA(1800,256): \(referencePixel)
            Old double-scale RGBA(900,128): \(oldDoubleScaledPosition)
            """, named: "photo-export-pixels.txt")
        #expect(sourceBlue[0] < 40 && sourceBlue[1] < 40 && sourceBlue[2] > 220)
        #expect(blue[0] < 40 && blue[1] < 40 && blue[2] > 220)
        #expect(referencePixel[0] > 200 && referencePixel[1] > 60 && referencePixel[2] < 120)
        #expect(oldDoubleScaledPosition.prefix(3).allSatisfy { $0 > 240 })
    }

    @Test func longThinImageIsCappedBeforeThumbnailDecode() async throws {
        let data = try png(fixtureImage(width: 20_000, height: 32))
        // This also exercises the immutable CGImage result crossing executors.
        let decoded = try await Task.detached {
            try PhotoMeasureModel.decodeImage(from: data)
        }.value
        #expect(decoded.image.width == PhotoMeasureModel.maximumDecodeDimension)
        #expect(decoded.image.height > 0 && decoded.image.height < 32)
        #expect(decoded.pixels == PhotoPoint(Double(decoded.image.width), Double(decoded.image.height)))
        #expect(decoded.wasDownsampled)
        #expect(decoded.image.width * decoded.image.height <= PhotoMeasureModel.maximumPixels)
    }

    @Test func importingBeforeTheFirstViewportFitsTheImageAndAcceptsReferenceTaps() async throws {
        let data = try png(fixtureImage(width: 640, height: 480))
        let model = PhotoMeasureModel(importImage: { data }, exportImage: { _ in })
        await model.importFromHost()
        #expect(model.phase == .ready && model.transform == nil)
        model.setViewSize(CGSize(width: 800, height: 600))
        let transform = try #require(model.transform)
        #expect(transform.scale == 1.25 && transform.offset == .zero)
        model.tap(at: CGPoint(x: 100, y: 100))
        model.tap(at: CGPoint(x: 500, y: 100))
        #expect(model.referencePointCount == 2)
        #expect(model.store.referencePoints.map(\.position) == [PhotoPoint(80, 80), PhotoPoint(400, 80)])
        model.referenceValueText = "2"
        model.applyCalibration()
        #expect(model.isCalibrated && model.canExport)
    }

    @Test func windowResizeRefitsAndPreservesRelativeZoomAndFocus() async throws {
        let source = PhotoImportFixture()
        let model = try await calibratedModel(source)
        let store = model.store
        let original = try #require(model.transform)
        let focus = original.imagePoint(fromView: PhotoPoint(320, 240))
        model.setViewSize(CGSize(width: 320, height: 240))
        let resized = try #require(model.transform)
        #expect(abs(resized.scale - original.scale / 2) < 1e-6)
        let resizedFocus = resized.imagePoint(fromView: PhotoPoint(160, 120))
        #expect(abs(resizedFocus.x - focus.x) < 1e-6 && abs(resizedFocus.y - focus.y) < 1e-6)
        #expect(model.store == store)
        model.setViewSize(CGSize(width: 320, height: 240))
        #expect(model.transform == resized)
        model.setViewSize(.zero)
        model.setViewSize(CGSize(width: CGFloat.nan, height: 240))
        #expect(model.transform == resized)
        model.resetZoom()
        #expect(model.transform?.scale == 0.5 && model.transform?.offset == .zero)
        model.setViewSize(CGSize(width: 960, height: 720))
        #expect(model.transform?.scale == 1.5 && model.transform?.offset == .zero)
    }

    @Test func failedAndCancelledReplacementKeepTheCurrentMeasurement() async throws {
        let source = PhotoImportFixture()
        let model = try await calibratedModel(source)
        let original = try #require(model.image)
        let store = model.store
        let viewport = model.transform
        let pixels = model.imagePixels

        source.data = Data([0, 0xFF, 0x42])
        await model.importFromHost()
        #expect(model.phase == .ready && model.hint != nil)
        #expect(model.image === original && model.store == store)
        #expect(model.transform == viewport && model.imagePixels == pixels)
        #expect(model.referenceValueText == "2" && model.canExport)

        source.error = CancellationError()
        await model.importFromHost()
        #expect(model.phase == .ready && model.image === original && model.store == store)
        source.error = nil
        source.data = nil
        await model.importFromHost()
        #expect(model.phase == .ready && model.image === original && model.store == store)
    }

    @Test func emptyImportCancellationAndFailureLeaveImportingPhase() async {
        let source = PhotoImportFixture()
        let model = PhotoMeasureModel(importImage: { try await source.load() }, exportImage: { _ in })
        source.error = CancellationError()
        await model.importFromHost()
        #expect(model.phase == .empty && model.image == nil)
        source.error = nil
        source.data = Data([0, 0xFF, 0x42])
        await model.importFromHost()
        #expect(model.phase == .empty && model.image == nil && model.hint != nil)
    }

    @Test func callerCancellationRestoresTheOldReadyState() async throws {
        let source = PhotoImportFixture()
        let model = try await calibratedModel(source)
        let original = try #require(model.image)
        let store = model.store
        source.suspend = true
        let operation = Task { await model.importFromHost() }
        await source.waitForPending(1)
        #expect(model.phase == .importing)
        operation.cancel()
        source.finish(at: 0, with: .success(try png(fixtureImage(width: 80, height: 60))))
        await operation.value
        #expect(model.phase == .ready && model.image === original && model.store == store)
    }

    @Test func leavingTheWorkbenchFencesLatePickerSuccess() async throws {
        let source = PhotoImportFixture()
        let model = try await calibratedModel(source)
        let original = try #require(model.image)
        let store = model.store
        let viewport = model.transform
        source.suspend = true
        let operation = Task { await model.importFromHost() }
        await source.waitForPending(1)
        model.cancelImport()
        #expect(model.phase == .ready)
        source.finish(at: 0, with: .success(try png(fixtureImage(width: 80, height: 60))))
        await operation.value
        #expect(model.phase == .ready && model.image === original && model.store == store)
        #expect(model.transform == viewport && model.hint == nil)
    }

    @Test func olderImportFailureCannotReplaceANewerSuccessfulImport() async throws {
        let source = PhotoImportFixture()
        let model = try await calibratedModel(source)
        source.suspend = true
        let older = Task { await model.importFromHost() }
        await source.waitForPending(1)
        let newer = Task { await model.importFromHost() }
        await source.waitForPending(2)
        source.finish(at: 1, with: .success(try png(fixtureImage(width: 320, height: 240))))
        await newer.value
        let newerImage = try #require(model.image)
        let newerStore = model.store
        #expect(model.phase == .ready && model.imagePixels == PhotoPoint(320, 240))
        #expect(model.store.referencePoints.isEmpty && model.store.vertices.isEmpty)
        source.finish(at: 0, with: .failure(ToolboxError.invalid("late image")))
        await older.value
        #expect(model.phase == .ready && model.image === newerImage && model.store == newerStore)
        #expect(model.hint == nil)
    }

    private func calibratedModel(_ source: PhotoImportFixture) async throws -> PhotoMeasureModel {
        source.data = try png(fixtureImage(width: 640, height: 480))
        let model = PhotoMeasureModel(unit: .meter, importImage: { try await source.load() }, exportImage: { _ in })
        model.setViewSize(CGSize(width: 640, height: 480))
        await model.importFromHost()
        #expect(model.phase == .ready)
        model.tap(at: CGPoint(x: 80, y: 80))
        model.tap(at: CGPoint(x: 400, y: 80))
        model.referenceValueText = "2"
        model.applyCalibration()
        model.tap(at: CGPoint(x: 160, y: 240))
        model.tap(at: CGPoint(x: 480, y: 240))
        #expect(model.isCalibrated && model.store.vertices.count == 2)
        model.zoom(by: 1.5, anchor: CGPoint(x: 320, y: 240))
        model.pan(by: CGSize(width: 12, height: 8))
        return model
    }

    private func fixtureImage(width: Int, height: Int, landmark: Bool = false) throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        // The convenience initializer uses a different RGB profile. Construct
        // the fixture in the same explicit sRGB space as the pixel reader.
        context.setFillColor(try #require(CGColor(colorSpace: space, components: [1, 1, 1, 1])))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        if landmark {
            context.setFillColor(try #require(CGColor(colorSpace: space, components: [0, 0, 1, 1])))
            context.fill(CGRect(x: 6000, y: 400, width: 200, height: 224))
        }
        return try #require(context.makeImage())
    }

    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func rgba(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let pixel = try #require(image.cropping(to: CGRect(x: CGFloat(x), y: CGFloat(y), width: 1, height: 1)))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes
    }
}

/// A picker fixture that deliberately ignores cancellation until the test
/// delivers a result, so lifecycle fences must reject genuinely late callbacks.
@MainActor
private final class PhotoImportFixture {
    var data: Data?
    var error: (any Error)?
    var suspend = false
    private var pending: [CheckedContinuation<Data?, any Error>] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func load() async throws -> Data? {
        if !suspend {
            if let error { throw error }
            return data
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            let ready = waiters.filter { pending.count >= $0.count }
            waiters.removeAll { pending.count >= $0.count }
            for waiter in ready { waiter.continuation.resume() }
        }
    }

    func waitForPending(_ count: Int) async {
        if pending.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func finish(at index: Int, with result: Result<Data?, any Error>) {
        pending.remove(at: index).resume(with: result)
    }
}
#endif
