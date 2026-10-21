import Foundation
import FloeCore
#if canImport(AVFoundation)
import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import VideoToolbox
#if canImport(Metal)
import Metal
#endif
#if canImport(MetalFX)
import MetalFX
#endif

// MARK: - Shared pixel buffer utilities

/// IOSurface-backed pixel buffer allocation for the enhancement pipeline.
/// Buffers are pooled by (format, width, height) and reused per stage so a
/// long video never allocates a frame per output.
final class MediaPixelBufferStore: @unchecked Sendable {
    private struct Key: Hashable {
        let format: OSType
        let width: Int
        let height: Int
        let variant: String
    }

    private let lock = NSLock()
    private var pools: [Key: CVPixelBufferPool] = [:]

    func makeBuffer(format: OSType, width: Int, height: Int) throws -> CVPixelBuffer {
        try makeBuffer(format: format, width: width, height: height, extraAttributes: nil)
    }

    /// Allocates a pooled buffer with extra attributes appended; the VT
    /// low-latency processors require their configuration's extended-pixel
    /// attributes, so those callers pass them through here.
    func makeBuffer(format: OSType, width: Int, height: Int, extraAttributes: [String: Any]?) throws -> CVPixelBuffer {
        let variant = extraAttributes.map { String(describing: $0.sorted { $0.key < $1.key }) } ?? ""
        let key = Key(format: format, width: width, height: height, variant: variant)
        let pool: CVPixelBufferPool = try lock.withLock {
            if let existing = pools[key] { return existing }
            var attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
            for (key, value) in extraAttributes ?? [:] { attributes[key] = value }
            var created: CVPixelBufferPool?
            let status = CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary,
                attributes as CFDictionary,
                &created
            )
            guard status == kCVReturnSuccess, let created else {
                throw FloeError.internalError("Could not create a \(width)x\(height) pixel buffer pool (status \(status))")
            }
            pools[key] = created
            return created
        }
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        guard status == kCVReturnSuccess, let buffer else {
            throw FloeError.internalError("Could not allocate a pixel buffer from the pool (status \(status))")
        }
        return buffer
    }

    func reset() {
        lock.withLock { pools.removeAll() }
    }
}

/// BGRA <-> RGhA (half float RGBA) conversion plus EXIF orientation through
/// one shared Core Image context. VTFrameProcessor requires RGhA; the decoder/
/// encoder work in BGRA.
final class MediaImageBridge: @unchecked Sendable {
    static let bgra = kCVPixelFormatType_32BGRA
    static let rgbaHalf = kCVPixelFormatType_64RGBAHalf

    let cicontext: CIContext
    let colorSpace: CGColorSpace

    init() {
        if let device = MTLCreateSystemDefaultDevice() {
            cicontext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        } else {
            cicontext = CIContext(options: [.cacheIntermediates: false])
        }
        colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }

    /// Renders `source` into `destination` (already allocated with matching
    /// dimensions), optionally applying an EXIF orientation.
    func render(source: CVPixelBuffer, destination: CVPixelBuffer, exifOrientation: UInt32 = 1) throws {
        var image = CIImage(cvPixelBuffer: source, options: [.colorSpace: colorSpace])
        if exifOrientation != 1 {
            image = image.oriented(forExifOrientation: Int32(exifOrientation))
        }
        let width = CVPixelBufferGetWidth(destination)
        let height = CVPixelBufferGetHeight(destination)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { throw FloeError.validationFailed("Frame image has an empty extent") }
        let scaled = extent.width != CGFloat(width) || extent.height != CGFloat(height)
            ? image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
            : image
        cicontext.render(
            scaled,
            to: destination,
            bounds: CGRect(x: 0, y: 0, width: width, height: height),
            colorSpace: colorSpace
        )
    }

    func bgraToHalfRGBA(_ source: CVPixelBuffer, store: MediaPixelBufferStore) throws -> CVPixelBuffer {
        let destination = try store.makeBuffer(
            format: Self.rgbaHalf,
            width: CVPixelBufferGetWidth(source),
            height: CVPixelBufferGetHeight(source)
        )
        try render(source: source, destination: destination)
        return destination
    }

    /// Bi-planar video-range YUV (the format the low-latency processors accept).
    func makeVideoRange420(width: Int, height: Int, store: MediaPixelBufferStore) throws -> CVPixelBuffer {
        try store.makeBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: width, height: height)
    }

    func toVideoRange420(_ source: CVPixelBuffer, store: MediaPixelBufferStore,
                         extraAttributes: [String: Any]? = nil) throws -> CVPixelBuffer {
        let destination = try store.makeBuffer(
            format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            width: CVPixelBufferGetWidth(source),
            height: CVPixelBufferGetHeight(source),
            extraAttributes: extraAttributes
        )
        try render(source: source, destination: destination)
        return destination
    }

    func halfRGBAToBGRA(_ source: CVPixelBuffer, store: MediaPixelBufferStore) throws -> CVPixelBuffer {
        let destination = try store.makeBuffer(
            format: Self.bgra,
            width: CVPixelBufferGetWidth(source),
            height: CVPixelBufferGetHeight(source)
        )
        try render(source: source, destination: destination)
        return destination
    }
}

/// Input class for VT super resolution without leaking the macOS 26-only
/// configuration enum into call sites that must also build for older macOS.
enum MediaSRInputType: Sendable {
    case video
    case image
}

// MARK: - Engine protocols

/// Frame interpolation engine. Produces `interpolatedPerPair` new frames for
/// every adjacent source pair; the pipeline appends the source frames itself.
protocol MediaInterpolationEngine: AnyObject, Sendable {
    var name: String { get }
    var interpolatedPerPair: Int { get }
    func prepare() throws -> [String]
    func interpolate(current: CVPixelBuffer, next: CVPixelBuffer, phases: [Float], outputs: [CVPixelBuffer]) throws
    func teardown()
}

/// Super-resolution engine. Produces one scaled frame per source frame.
protocol MediaSuperResolutionEngine: AnyObject, Sendable {
    var name: String { get }
    var outputWidth: Int { get }
    var outputHeight: Int { get }
    func prepare() throws -> [String]
    func scale(current: CVPixelBuffer, output: CVPixelBuffer) throws
    func teardown()
}

// MARK: - VideoToolbox frame rate conversion

// The VTFrameProcessor configuration types are excluded from the Simulator
// SDK headers (`#if ! TARGET_OS_SIMULATOR`). The engines below therefore
// compile on macOS hosts and physical iOS devices only; the Simulator keeps
// the honest "not supported" factory errors in MediaEnhancementPipeline.
#if !targetEnvironment(simulator)

/// `quality` / VTFrameProcessor `VTFrameRateConversionConfiguration`.
@available(iOS 26.0, macOS 15.4, *)
final class VideoToolboxInterpolationEngine: MediaInterpolationEngine, @unchecked Sendable {
    let name = "videotoolbox.frameRateConversion"
    let interpolatedPerPair: Int

    private let width: Int
    private let height: Int
    private let quality: MediaEnhancementQuality
    private let bridge: MediaImageBridge
    private let store: MediaPixelBufferStore
    private let lock = NSLock()
    private var processor: VTFrameProcessor?
    private var submissions = 0

    init(width: Int, height: Int, framesPerPair: Int, quality: MediaEnhancementQuality,
         bridge: MediaImageBridge, store: MediaPixelBufferStore) {
        self.width = width
        self.height = height
        self.interpolatedPerPair = max(0, framesPerPair - 1)
        self.quality = quality
        self.bridge = bridge
        self.store = store
    }

    func prepare() throws -> [String] {
        guard VTFrameRateConversionConfiguration.isSupported else {
            throw FloeError.invalidConfiguration("VTFrameProcessor frame rate conversion is not supported on this device")
        }
        let revisions = VTFrameRateConversionConfiguration.supportedRevisions
        let revision = VTFrameRateConversionConfiguration.defaultRevision
        guard revisions.contains(revision.rawValue) else {
            throw FloeError.invalidConfiguration("Frame rate conversion revision \(revision.rawValue) is unavailable")
        }
        guard let configuration = VTFrameRateConversionConfiguration(
            frameWidth: width,
            frameHeight: height,
            usePrecomputedFlow: false,
            qualityPrioritization: quality.vtPrioritizationIsQuality ? .quality : .normal,
            revision: revision
        ) else {
            throw FloeError.invalidConfiguration("Frame rate conversion does not accept \(width)x\(height) source frames")
        }
        let processor = VTFrameProcessor()
        do {
            try processor.startSession(configuration: configuration)
        } catch {
            throw FloeError.invalidConfiguration("Frame rate conversion session failed: \(error.localizedDescription)")
        }
        lock.withLock { self.processor = processor }
        let formats = configuration.supportedPixelFormats.map { MediaSourceInspector.fourCC($0) }
        return ["engine=\(name) prioritization=\(quality.vtPrioritizationIsQuality ? "quality" : "normal") formats=\(formats.joined(separator: ","))"]
    }

    func interpolate(current: CVPixelBuffer, next: CVPixelBuffer, phases: [Float], outputs: [CVPixelBuffer]) throws {
        guard let processor = lock.withLock({ self.processor }) else {
            throw FloeError.internalError("Frame rate conversion session was not started")
        }
        guard phases.count == outputs.count, !outputs.isEmpty else {
            throw FloeError.internalError("Interpolation requires one destination per phase")
        }
        let halfCurrent = try bridge.bgraToHalfRGBA(current, store: store)
        let halfNext = try bridge.bgraToHalfRGBA(next, store: store)
        let stamp = CMTime(value: 1, timescale: 1)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: halfCurrent, presentationTimeStamp: .zero),
              let nextFrame = VTFrameProcessorFrame(buffer: halfNext, presentationTimeStamp: stamp) else {
            throw FloeError.internalError("Could not wrap interpolation frames")
        }
        let destinations = try outputs.enumerated().map { index, _ -> VTFrameProcessorFrame in
            let half = try store.makeBuffer(format: MediaImageBridge.rgbaHalf, width: width, height: height)
            guard let frame = VTFrameProcessorFrame(buffer: half, presentationTimeStamp: CMTime(seconds: Double(phases[index]), preferredTimescale: 1_000_000)) else {
                throw FloeError.internalError("Could not allocate an interpolation destination")
            }
            return frame
        }
        // Each invocation is an independent normalized 0...1 source pair,
        // including chunks of one VFR gap; those clocks are not sequential.
        let mode: VTFrameRateConversionParameters.SubmissionMode = .random
        guard let parameters = VTFrameRateConversionParameters(
            sourceFrame: sourceFrame,
            nextFrame: nextFrame,
            opticalFlow: nil,
            interpolationPhase: phases,
            submissionMode: mode,
            destinationFrames: destinations
        ) else {
            throw FloeError.validationFailed("Frame rate conversion rejected the interpolation request")
        }
        try runVideoToolboxProcessSynchronously { completion in
            processor.process(parameters: parameters, completionHandler: completion)
        }
        for (index, frame) in destinations.enumerated() {
            try bridge.render(source: frame.buffer, destination: outputs[index])
        }
    }

    func teardown() {
        lock.withLock {
            processor?.endSession()
            processor = nil
        }
    }

}

/// Shared synchronous bridge for VideoToolbox completion-handler processing
/// running on the pipeline's dedicated worker queue.
@available(iOS 26.0, macOS 15.4, *)
func runVideoToolboxProcessSynchronously(
    _ body: (@escaping @Sendable (any VTFrameProcessorParameters, (any Error)?) -> Void) -> Void
) throws {
    let semaphore = DispatchSemaphore(value: 0)
    let errorBox = MediaCallbackErrorBox()
    body { _, error in
        errorBox.store(error)
        semaphore.signal()
    }
    semaphore.wait()
    if let error = errorBox.error {
        throw FloeError.internalError("VideoToolbox frame processing failed: \(error.localizedDescription)")
    }
}

/// Thread-safe error box for VideoToolbox callbacks.
final class MediaCallbackErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (any Error)?
    func store(_ error: (any Error)?) { lock.withLock { value = error } }
    var error: (any Error)? { lock.withLock { value } }
}

// MARK: - VideoToolbox low-latency frame interpolation

/// `lowLatency` / VTFrameProcessor `VTLowLatencyFrameInterpolationConfiguration`.
/// The API is inherently 2x (one interpolated frame per pair).
@available(iOS 26.0, macOS 26.0, *)
final class VideoToolboxLowLatencyInterpolationEngine: MediaInterpolationEngine, @unchecked Sendable {
    let name = "videotoolbox.lowLatencyFrameInterpolation"
    let interpolatedPerPair: Int

    private let width: Int
    private let height: Int
    private let bridge: MediaImageBridge
    private let store: MediaPixelBufferStore
    private let lock = NSLock()
    private var processor: VTFrameProcessor?
    private var sourceAttributes: [String: Any]?
    private var destinationAttributes: [String: Any]?

    init(width: Int, height: Int, framesPerPair: Int, bridge: MediaImageBridge, store: MediaPixelBufferStore) throws {
        self.width = width
        self.height = height
        self.bridge = bridge
        self.store = store
        self.interpolatedPerPair = framesPerPair - 1
        guard framesPerPair == 2 else {
            throw FloeError.invalidConfiguration("lowLatency interpolation supports exactly 2x frame rate conversion; request targetFPS = 2 x source or use mode=quality")
        }
    }

    func prepare() throws -> [String] {
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            throw FloeError.invalidConfiguration("Low-latency frame interpolation is not supported on this device")
        }
        guard let configuration = VTLowLatencyFrameInterpolationConfiguration(
            frameWidth: width, frameHeight: height, numberOfInterpolatedFrames: 1
        ) else {
            throw FloeError.invalidConfiguration("Low-latency frame interpolation does not accept \(width)x\(height) source frames")
        }
        let processor = VTFrameProcessor()
        do { try processor.startSession(configuration: configuration) } catch {
            throw FloeError.invalidConfiguration("Low-latency interpolation session failed: \(error.localizedDescription)")
        }
        lock.withLock {
            self.processor = processor
            self.sourceAttributes = Self.extendedAttributes(configuration.sourcePixelBufferAttributes)
            self.destinationAttributes = Self.extendedAttributes(configuration.destinationPixelBufferAttributes)
        }
        let formats = configuration.supportedPixelFormats.map { MediaSourceInspector.fourCC($0) }
        return ["engine=\(name) formats=\(formats.joined(separator: ","))"]
    }

    func interpolate(current: CVPixelBuffer, next: CVPixelBuffer, phases: [Float], outputs: [CVPixelBuffer]) throws {
        guard let processor = lock.withLock({ self.processor }) else {
            throw FloeError.internalError("Low-latency interpolation session was not started")
        }
        guard phases == [0.5], outputs.count == 1 else {
            throw FloeError.invalidConfiguration("lowLatency interpolation only produces the 0.5 midpoint")
        }
        // VTLowLatencyFrameInterpolation only accepts 420v bi-planar frames
        // carrying the configuration's extended-pixel attributes.
        let attributes = lock.withLock { sourceAttributes }
        let previous420 = try bridge.toVideoRange420(current, store: store, extraAttributes: attributes)
        let source420 = try bridge.toVideoRange420(next, store: store, extraAttributes: attributes)
        guard let previous = VTFrameProcessorFrame(buffer: previous420, presentationTimeStamp: .zero),
              let source = VTFrameProcessorFrame(buffer: source420, presentationTimeStamp: CMTime(value: 1, timescale: 1)) else {
            throw FloeError.internalError("Could not wrap low-latency interpolation frames")
        }
        let output420 = try store.makeBuffer(
            format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: width, height: height,
            extraAttributes: lock.withLock { destinationAttributes }
        )
        guard let destination = VTFrameProcessorFrame(buffer: output420, presentationTimeStamp: CMTime(value: 1, timescale: 2)) else {
            throw FloeError.internalError("Could not allocate a low-latency interpolation destination")
        }
        guard let parameters = VTLowLatencyFrameInterpolationParameters(
            sourceFrame: source, previousFrame: previous,
            interpolationPhase: [0.5], destinationFrames: [destination]
        ) else {
            throw FloeError.validationFailed("Low-latency interpolation rejected the request")
        }
        try runVideoToolboxProcessSynchronously { completion in
            processor.process(parameters: parameters, completionHandler: completion)
        }
        try bridge.render(source: output420, destination: outputs[0])
    }

    func teardown() {
        lock.withLock {
            processor?.endSession()
            processor = nil
        }
    }

    /// Only the VT-specific extended-pixel hints are forwarded; the width,
    /// height, format and surface attributes come from the pool.
    static func extendedAttributes(_ attributes: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in attributes {
            if key.contains("ExtendedPixels") { result[key] = value }
        }
        return result
    }
}

// MARK: - VideoToolbox super resolution

/// `quality` / VTFrameProcessor `VTSuperResolutionScalerConfiguration`.
/// The Apple model assets must already be present; the tool never downloads
/// them implicitly.
@available(iOS 26.0, macOS 26.0, *)
final class VideoToolboxSuperResolutionEngine: MediaSuperResolutionEngine, @unchecked Sendable {
    let name = "videotoolbox.superResolution"
    let outputWidth: Int
    let outputHeight: Int

    private let width: Int
    private let height: Int
    private let scaleFactor: Int
    private let inputType: VTSuperResolutionScalerConfiguration.InputType
    private let bridge: MediaImageBridge
    private let store: MediaPixelBufferStore
    private let lock = NSLock()
    private var processor: VTFrameProcessor?
    private var previousSource: CVPixelBuffer?
    private var previousOutput: CVPixelBuffer?
    private var submissions = 0

    init(width: Int, height: Int, scaleFactor: Int, inputType: VTSuperResolutionScalerConfiguration.InputType,
         bridge: MediaImageBridge, store: MediaPixelBufferStore) {
        self.width = width
        self.height = height
        self.scaleFactor = scaleFactor
        self.outputWidth = width * scaleFactor
        self.outputHeight = height * scaleFactor
        self.inputType = inputType
        self.bridge = bridge
        self.store = store
    }

    func prepare() throws -> [String] {
        guard VTSuperResolutionScalerConfiguration.isSupported else {
            throw FloeError.invalidConfiguration("VTFrameProcessor super resolution is not supported on this device")
        }
        let supported = VTSuperResolutionScalerConfiguration.supportedScaleFactors
        guard supported.contains(scaleFactor) else {
            throw FloeError.invalidConfiguration(
                "VT super resolution supports scale factors \(supported.map(String.init).joined(separator: ",")) on this device; requested \(scaleFactor)"
            )
        }
        guard let configuration = VTSuperResolutionScalerConfiguration(
            frameWidth: width, frameHeight: height, scaleFactor: scaleFactor,
            inputType: inputType, usePrecomputedFlow: false,
            qualityPrioritization: .normal,
            revision: VTSuperResolutionScalerConfiguration.defaultRevision
        ) else {
            throw FloeError.invalidConfiguration("VT super resolution does not accept \(width)x\(height) frames at \(scaleFactor)x")
        }
        switch configuration.configurationModelStatus {
        case .ready:
            break
        case .downloading:
            throw FloeError.invalidConfiguration("Apple super-resolution model assets are downloading (\(Int(configuration.configurationModelPercentageAvailable * 100))% complete); retry when ready")
        case .downloadRequired:
            throw FloeError.invalidConfiguration("Apple super-resolution model assets are not installed on this device; system settings must download them before this mode can run")
        @unknown default:
            throw FloeError.invalidConfiguration("Apple super-resolution model assets report an unknown state")
        }
        let processor = VTFrameProcessor()
        do { try processor.startSession(configuration: configuration) } catch {
            throw FloeError.invalidConfiguration("Super resolution session failed: \(error.localizedDescription)")
        }
        lock.withLock { self.processor = processor }
        return ["engine=\(name) model=ready scale=\(scaleFactor)"]
    }

    func scale(current: CVPixelBuffer, output: CVPixelBuffer) throws {
        guard let processor = lock.withLock({ self.processor }) else {
            throw FloeError.internalError("Super resolution session was not started")
        }
        let halfSource = try bridge.bgraToHalfRGBA(current, store: store)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: halfSource, presentationTimeStamp: .zero) else {
            throw FloeError.internalError("Could not wrap the super-resolution source frame")
        }
        let halfOutput = try store.makeBuffer(format: MediaImageBridge.rgbaHalf, width: outputWidth, height: outputHeight)
        guard let destinationFrame = VTFrameProcessorFrame(buffer: halfOutput, presentationTimeStamp: .zero) else {
            throw FloeError.internalError("Could not allocate the super-resolution destination")
        }
        let previous = lock.withLock { (previousSource, previousOutput) }
        let previousFrame = previous.0.flatMap { VTFrameProcessorFrame(buffer: $0, presentationTimeStamp: .zero) }
        let previousOutputFrame = previous.1.flatMap { VTFrameProcessorFrame(buffer: $0, presentationTimeStamp: .zero) }
        let mode: VTSuperResolutionScalerParameters.SubmissionMode = lock.withLock {
            defer { submissions += 1 }
            return submissions == 0 ? .random : .sequential
        }
        guard let parameters = VTSuperResolutionScalerParameters(
            sourceFrame: sourceFrame, previousFrame: previousFrame, previousOutputFrame: previousOutputFrame,
            opticalFlow: nil, submissionMode: mode, destinationFrame: destinationFrame
        ) else {
            throw FloeError.validationFailed("VT super resolution rejected the request")
        }
        try runVideoToolboxProcessSynchronously { completion in
            processor.process(parameters: parameters, completionHandler: completion)
        }
        lock.withLock {
            previousSource = halfSource
            previousOutput = halfOutput
        }
        try bridge.render(source: halfOutput, destination: output)
    }

    func teardown() {
        lock.withLock {
            processor?.endSession()
            processor = nil
            previousSource = nil
            previousOutput = nil
        }
    }
}

/// `lowLatency` / VTFrameProcessor `VTLowLatencySuperResolutionScalerConfiguration`.
@available(iOS 26.0, macOS 26.0, *)
final class VideoToolboxLowLatencySuperResolutionEngine: MediaSuperResolutionEngine, @unchecked Sendable {
    let name = "videotoolbox.lowLatencySuperResolutionScaler"
    let outputWidth: Int
    let outputHeight: Int

    private let width: Int
    private let height: Int
    private let scaleFactor: Float
    private let bridge: MediaImageBridge
    private let store: MediaPixelBufferStore
    private let lock = NSLock()
    private var processor: VTFrameProcessor?

    init(width: Int, height: Int, scaleFactor: Int, bridge: MediaImageBridge, store: MediaPixelBufferStore) {
        self.width = width
        self.height = height
        self.scaleFactor = Float(scaleFactor)
        self.outputWidth = width * scaleFactor
        self.outputHeight = height * scaleFactor
        self.bridge = bridge
        self.store = store
    }

    func prepare() throws -> [String] {
        guard VTLowLatencySuperResolutionScalerConfiguration.isSupported else {
            throw FloeError.invalidConfiguration("Low-latency super resolution is not supported on this device")
        }
        let configuration = VTLowLatencySuperResolutionScalerConfiguration(
            frameWidth: width, frameHeight: height, scaleFactor: scaleFactor
        )
        guard configuration.frameWidth == width, configuration.frameHeight == height else {
            throw FloeError.invalidConfiguration("Low-latency super resolution does not accept \(width)x\(height) at \(scaleFactor)x")
        }
        let processor = VTFrameProcessor()
        do { try processor.startSession(configuration: configuration) } catch {
            throw FloeError.invalidConfiguration("Low-latency super resolution session failed: \(error.localizedDescription)")
        }
        lock.withLock { self.processor = processor }
        return ["engine=\(name) scale=\(scaleFactor)"]
    }

    func scale(current: CVPixelBuffer, output: CVPixelBuffer) throws {
        guard let processor = lock.withLock({ self.processor }) else {
            throw FloeError.internalError("Low-latency super resolution session was not started")
        }
        // VTLowLatencySuperResolutionScaler consumes 420v bi-planar buffers.
        let source420 = try Self.make420v(from: current, bridge: bridge, store: store)
        guard let sourceFrame = VTFrameProcessorFrame(buffer: source420, presentationTimeStamp: .zero) else {
            throw FloeError.internalError("Could not wrap the low-latency super-resolution source frame")
        }
        let output420 = try Self.make420v(width: outputWidth, height: outputHeight, store: store)
        guard let destinationFrame = VTFrameProcessorFrame(buffer: output420, presentationTimeStamp: .zero) else {
            throw FloeError.internalError("Could not allocate the low-latency super-resolution destination")
        }
        let parameters = VTLowLatencySuperResolutionScalerParameters(sourceFrame: sourceFrame, destinationFrame: destinationFrame)
        try runVideoToolboxProcessSynchronously { completion in
            processor.process(parameters: parameters, completionHandler: completion)
        }
        try bridge.render(source: output420, destination: output)
    }

    func teardown() {
        lock.withLock {
            processor?.endSession()
            processor = nil
        }
    }

    private static func make420v(from buffer: CVPixelBuffer, bridge: MediaImageBridge, store: MediaPixelBufferStore) throws -> CVPixelBuffer {
        try bridge.toVideoRange420(buffer, store: store)
    }

    private static func make420v(width: Int, height: Int, store: MediaPixelBufferStore) throws -> CVPixelBuffer {
        try store.makeBuffer(format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: width, height: height)
    }
}

#endif // !targetEnvironment(simulator)

// MARK: - MetalFX spatial scaler

#if canImport(Metal) && canImport(MetalFX)
/// `metalFX` / MTLFXSpatialScaler. This is a GPU spatial upscaler, not a
/// learned super-resolution network; the result digest labels it as spatial.
final class MetalFXSpatialSuperResolutionEngine: MediaSuperResolutionEngine, @unchecked Sendable {
    let name = "metalFX.spatialScaler"
    let outputWidth: Int
    let outputHeight: Int

    private let width: Int
    private let height: Int
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let bridge: MediaImageBridge
    private let store: MediaPixelBufferStore
    private var textureCache: CVMetalTextureCache?
    private let lock = NSLock()
    private var scaler: MTLFXSpatialScaler?
    private var inputTexture: MTLTexture?
    private var outputTexture: MTLTexture?

    init(width: Int, height: Int, scaleFactor: Int, bridge: MediaImageBridge, store: MediaPixelBufferStore) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw FloeError.invalidConfiguration("MetalFX requires a Metal device")
        }
        self.device = device
        self.commandQueue = queue
        self.width = width
        self.height = height
        self.outputWidth = width * scaleFactor
        self.outputHeight = height * scaleFactor
        self.bridge = bridge
        self.store = store
    }

    func prepare() throws -> [String] {
        let descriptor = MTLFXSpatialScalerDescriptor()
        descriptor.inputWidth = width
        descriptor.inputHeight = height
        descriptor.outputWidth = outputWidth
        descriptor.outputHeight = outputHeight
        descriptor.colorTextureFormat = .bgra8Unorm
        descriptor.outputTextureFormat = .bgra8Unorm
        descriptor.colorProcessingMode = .perceptual
        guard MTLFXSpatialScalerDescriptor.supportsDevice(device) else {
            throw FloeError.invalidConfiguration("MetalFX spatial scaling is not supported on this device")
        }
        guard let scaler = descriptor.makeSpatialScaler(device: device) else {
            throw FloeError.invalidConfiguration("MetalFX spatial scaler could not be created for \(width)x\(height) -> \(outputWidth)x\(outputHeight)")
        }
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        lock.withLock {
            self.scaler = scaler
            self.textureCache = cache
        }
        return ["engine=\(name) spatialUpscale=\(width)x\(height)->\(outputWidth)x\(outputHeight)"]
    }

    func scale(current: CVPixelBuffer, output: CVPixelBuffer) throws {
        let scaler = try lock.withLock { () throws -> MTLFXSpatialScaler in
            guard let scaler else { throw FloeError.internalError("MetalFX scaler was not created") }
            return scaler
        }
        guard let cache = lock.withLock({ textureCache }) else {
            throw FloeError.internalError("Metal texture cache unavailable")
        }
        var cvInput: CVMetalTexture?
        let inputStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, current, nil, .bgra8Unorm, width, height, 0, &cvInput
        )
        guard inputStatus == kCVReturnSuccess, let cvInput, let inputTexture = CVMetalTextureGetTexture(cvInput) else {
            throw FloeError.internalError("MetalFX could not wrap the source frame")
        }
        var cvOutput: CVMetalTexture?
        let outputStatus = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, output, nil, .bgra8Unorm, outputWidth, outputHeight, 0, &cvOutput
        )
        guard outputStatus == kCVReturnSuccess, let cvOutput, let outputTexture = CVMetalTextureGetTexture(cvOutput) else {
            throw FloeError.internalError("MetalFX could not wrap the destination frame")
        }
        scaler.colorTexture = inputTexture
        scaler.outputTexture = outputTexture
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw FloeError.internalError("MetalFX could not create a command buffer")
        }
        scaler.encode(commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let error = commandBuffer.error {
            throw FloeError.internalError("MetalFX command failed: \(error.localizedDescription)")
        }
        _ = cvInput
        _ = cvOutput
    }

    func teardown() {
        lock.withLock {
            scaler = nil
            inputTexture = nil
            outputTexture = nil
            textureCache = nil
        }
    }
}
#endif

#endif
