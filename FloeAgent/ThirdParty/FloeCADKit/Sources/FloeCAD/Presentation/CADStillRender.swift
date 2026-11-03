// Bounded offline raster export. Geometry, appearance and camera remain owned
// by the live CAD document and the existing RealityKit scene builder.
import Foundation

public nonisolated struct CADStillRenderSettings: Codable, Equatable, Sendable {
    public enum Quality: String, Codable, CaseIterable, Sendable {
        case standard, detailed
        public var sampleScale: Int { self == .detailed ? 2 : 1 }
    }
    public var quality: Quality
    public var width: Int
    public var height: Int
    public var exposureEV: Double
    public var saturation: Double
    public init(quality: Quality = .detailed, width: Int = 1280, height: Int = 960,
                exposureEV: Double = 0, saturation: Double = 1) {
        self.quality = quality; self.width = width; self.height = height
        self.exposureEV = exposureEV; self.saturation = saturation
    }
    public func validate() throws {
        guard (256...2048).contains(width), (256...2048).contains(height),
              width * height * quality.sampleScale * quality.sampleScale <= 8_388_608,
              exposureEV.isFinite, (-3...3).contains(exposureEV),
              saturation.isFinite, (0...2).contains(saturation) else {
            throw CADStillRenderError.invalidOptions
        }
    }
    public var renderWidth: Int { width * quality.sampleScale }
    public var renderHeight: Int { height * quality.sampleScale }
}

public nonisolated enum CADStillRenderError: Error, LocalizedError, Sendable {
    case invalidOptions, busy, unavailable, insufficientPixels, changed, encoding
    public var errorDescription: String? {
        switch self {
        case .invalidOptions: return FloeCADStrings.text("cad.render.error.options", "Choose a smaller image or valid image settings.")
        case .busy: return FloeCADStrings.text("cad.render.error.busy", "Wait for the current image to finish, or cancel it.")
        case .unavailable: return FloeCADStrings.text("cad.render.error.unavailable", "Keep Floe open to render this image.")
        case .insufficientPixels: return FloeCADStrings.text("cad.render.error.pixels", "This window could not render the requested image size. Try a smaller size.")
        case .changed: return FloeCADStrings.text("cad.render.error.changed", "The model changed. Render the image again.")
        case .encoding: return FloeCADStrings.text("cad.render.error.encoding", "The image could not be saved. Try again.")
        }
    }
}

@MainActor
public extension FloeCADDocument {
    var stillRenderSettings: CADStillRenderSettings {
        let saved = CADViewOverlayCodec.settings(session.document.sceneSettingsData).stillRender
        return saved.flatMap { (try? $0.validate()) == nil ? nil : $0 } ?? .init()
    }
    func setStillRenderSettings(_ value: CADStillRenderSettings) throws {
        try value.validate()
        guard !isClosed, session.writeBlock == nil else { throw CADStillRenderError.changed }
        guard value != stillRenderSettings else { return }
        let before = session.document.sceneSettingsData
        var settings = CADViewOverlayCodec.settings(before)
        settings.stillRender = value
        let after = try JSONEncoder().encode(settings)
        session.perform(SetSceneSettingsDataCommand(before: before, after: after))
        guard session.document.sceneSettingsData == after else { throw CADStillRenderError.changed }
    }
}

#if canImport(RealityKit) && canImport(UIKit) && canImport(SwiftUI)
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import ImageIO

public nonisolated struct CADStillRenderResult: Sendable {
    public var png: Data
    public var width: Int
    public var height: Int
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var revision: Int
    public var sourceSHA256: String
    public var imageSHA256: String
    public var elapsedSeconds: Double
    public var quality: CADStillRenderSettings.Quality
}

/// A single owned render, never a screen-size snapshot enlarged into a claimed
/// high-resolution render. The source-pixel floor is checked before filtering.
@MainActor
public final class CADStillRenderService {
    public static let shared = CADStillRenderService()
    private var busy = false
    public init() {}

    public func render(document: FloeCADDocument, settings: CADStillRenderSettings) async throws -> CADStillRenderResult {
        try settings.validate(); try Task.checkCancellation()
        guard !busy else { throw CADStillRenderError.busy }
        guard !document.isClosed else { throw CADStillRenderError.changed }
        busy = true
        defer { busy = false }
        let initialCount = document.liveChangeCount
        let settled = try await document.session.settleSaveStateBeforeIdentityPin(expectingChangeCount: initialCount)
        guard case .ready = settled, !document.isClosed else { throw CADStillRenderError.changed }
        let revision = document.revision, count = document.liveChangeCount
        let sha = document.contentSHA256, start = Date()
        guard let screen = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?.screen else { throw CADStillRenderError.unavailable }
        let scale = max(1, screen.scale)
        guard let host = CADPresentationServiceRenderHost(document: document,
            width: Int(ceil(CGFloat(settings.renderWidth) / scale)),
            height: Int(ceil(CGFloat(settings.renderHeight) / scale))) else { throw CADStillRenderError.unavailable }
        defer { host.release() }
        guard await host.waitUntilReady() else { try Task.checkCancellation(); throw CADStillRenderError.unavailable }
        try Task.checkCancellation()
        if let camera = document.activeSavedCamera { host.controller.showCamera(camera.presentationCamera) }
        // Wait for actual rendered frames after the scene/camera installation.
        try await Task.sleep(for: .milliseconds(100))
        let image = try await host.controller.snapshotImage(targetWidth: nil)
        guard let cg = image.cgImage else { throw CADStillRenderError.encoding }
        let sw = cg.width, sh = cg.height
        guard sw >= settings.renderWidth, sh >= settings.renderHeight else { throw CADStillRenderError.insufficientPixels }
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try CADStillRenderPixels.process(image: cg, settings: settings)
        }
        let png = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard !document.isClosed, document.revision == revision,
              document.liveChangeCount == count, document.contentSHA256 == sha else { throw CADStillRenderError.changed }
        return CADStillRenderResult(png: png, width: settings.width, height: settings.height,
            sourceWidth: sw, sourceHeight: sh, revision: revision, sourceSHA256: sha,
            imageSHA256: CADMaterialTexture.digest(png), elapsedSeconds: Date().timeIntervalSince(start), quality: settings.quality)
    }
}

nonisolated enum CADStillRenderPixels {
    static func process(image: CGImage, settings: CADStillRenderSettings) throws -> Data {
        try settings.validate(); try Task.checkCancellation()
        guard image.width >= settings.renderWidth, image.height >= settings.renderHeight,
              let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let output = CGColorSpace(name: CGColorSpace.sRGB) else { throw CADStillRenderError.insufficientPixels }
        let context = CIContext(options: [.workingColorSpace: linear, .outputColorSpace: output,
                                         .cacheIntermediates: false])
        defer { context.clearCaches() }
        var value = CIImage(cgImage: image, options: [.colorSpace: output])
        let exposure = CIFilter.exposureAdjust(); exposure.inputImage = value; exposure.ev = Float(settings.exposureEV)
        guard let exposed = exposure.outputImage else { throw CADStillRenderError.encoding }
        let color = CIFilter.colorControls(); color.inputImage = exposed; color.saturation = Float(settings.saturation)
        guard let corrected = color.outputImage else { throw CADStillRenderError.encoding }
        value = corrected
        // UIKit may round point sizes to complete device pixels. Crop that
        // subpixel excess to the requested frame before real downsampling.
        let aspect = CGFloat(settings.width) / CGFloat(settings.height)
        let w = min(value.extent.width, value.extent.height * aspect), h = min(value.extent.height, value.extent.width / aspect)
        let crop = CGRect(x: (value.extent.width-w)/2, y: (value.extent.height-h)/2, width: w, height: h)
        value = value.cropped(to: crop).transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        let resize = CIFilter.lanczosScaleTransform(); resize.inputImage = value
        resize.scale = Float(CGFloat(settings.height) / h); resize.aspectRatio = 1
        guard let resized = resize.outputImage else { throw CADStillRenderError.encoding }
        try Task.checkCancellation()
        guard let cg = context.createCGImage(resized, from: CGRect(x: 0, y: 0, width: settings.width, height: settings.height),
                                             format: .RGBA8, colorSpace: output) else { throw CADStillRenderError.encoding }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil) else { throw CADStillRenderError.encoding }
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGsRGBIntent: 0]] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CADStillRenderError.encoding }
        try Task.checkCancellation()
        return bytes as Data
    }
}
#endif
