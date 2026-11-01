import BridgeCore
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

// Encoder/property/keyframe/parameter-set handling follows OpenMinis/iCTRL
// `iCTRLUITests/VideoStreamer.swift` at
// c1e4268859ba858d1579f7b846a56cb40641b7f6 (Apache-2.0), reimplemented for the
// typed Bridge frame provider. See ThirdParty/iCTRL/MEDIA_ADAPTATIONS.md.

/// One compressed access unit produced by ``BridgeVideoEncoder``. This value
/// crosses from the VideoToolbox callback thread to the serial media queue and
/// contains no UIKit/XCTest type.
struct BridgeVideoEncodedFrame: Sendable {
    let nalus: [Data]
    let keyframe: Bool
    let presentationTicks: UInt64
    let parameterSets: [Data]?
    let capturedAt: Double
    let submittedAt: Double
    let generation: UInt64
}

struct BridgeVideoEncodedAccessUnit: Sendable {
    let data: Data
    let keyframe: Bool
    let presentationTicks: UInt64
    let sampleBytes: Int
}

struct BridgeVideoEncoderConfiguration: Sendable {
    let generation: UInt64
    let width: Int
    let height: Int
    let framesPerSecond: Double
    let averageBitRate: Int
    let keyFrameIntervalSeconds: Double
    let maximumFrameGapSeconds: Double
}

/// Retains the VideoToolbox callback context until the session is completed and
/// invalidated. The callback only dereferences this object while the encoder is
/// alive; `deactivate()` fences all later callbacks before invalidation.
final class BridgeVideoCallbackContext: @unchecked Sendable {
    private let lock = BridgeRPCLock()
    private var active = true
    private weak var encoder: BridgeVideoEncoder?

    init() {}

    func bind(_ encoder: BridgeVideoEncoder) {
        lock.withLock { self.encoder = encoder }
    }

    func deactivate() {
        lock.withLock { active = false }
    }

    func deliver(status: OSStatus,
                 infoFlags: VTEncodeInfoFlags,
                 sampleBuffer: CMSampleBuffer?,
                 token: BridgeVideoFrameToken?) {
        let encoder = lock.withLock { active ? self.encoder : nil }
        guard let encoder else { return }

        if status != noErr {
            encoder.receiveFailure(status: status, token: token)
            return
        }
        if infoFlags.contains(.frameDropped) {
            encoder.receiveDroppedFrame(token: token)
            return
        }
        guard let sampleBuffer,
              let frame = BridgeVideoEncoder.assemble(sampleBuffer: sampleBuffer,
                                                      token: token) else {
            encoder.receiveDroppedFrame(token: token)
            return
        }
        encoder.receive(frame)
    }
}

/// Per-frame metadata retained through VideoToolbox's `sourceFrameRefcon`.
final class BridgeVideoFrameToken {
    let index: UInt64
    let capturedAt: Double
    let submittedAt: Double
    let generation: UInt64

    init(index: UInt64, capturedAt: Double, submittedAt: Double, generation: UInt64) {
        self.index = index
        self.capturedAt = capturedAt
        self.submittedAt = submittedAt
        self.generation = generation
    }
}

/// Real-time H.264 encoder and fMP4 muxer for one screen size.
///
/// Threading: all mutable encoder state is touched on the injected serial
/// queue. VideoToolbox's C callback only converts the sample buffer into a
/// `Sendable` value and dispatches it back to that queue. No actor or
/// MainActor inheritance is used, so the callback cannot inherit an executor.
final class BridgeVideoEncoder: @unchecked Sendable {
    typealias InitHandler = @Sendable (Data, String, Int, Int) -> Void
    typealias AccessUnitHandler = @Sendable (BridgeVideoEncodedAccessUnit) -> Void
    typealias FailureHandler = @Sendable (String) -> Void

    private let queue: DispatchQueue
    private let configuration: BridgeVideoEncoderConfiguration
    private let onInit: InitHandler
    private let onAccessUnit: AccessUnitHandler
    private let onFailure: FailureHandler
    private let callbackContext: BridgeVideoCallbackContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private var session: VTCompressionSession?
    private var pixelBufferPool: CVPixelBufferPool?
    private var muxer: BridgeFMP4Muxer?
    private var lastPresentationTicks: UInt64?
    private var lastSubmittedTicks: UInt64?
    private var firstCapturedAt: Double?
    private var pendingFrames = 0
    private var forceKeyframe = true
    private var invalidated = false

    init(configuration: BridgeVideoEncoderConfiguration,
         queue: DispatchQueue,
         onInit: @escaping InitHandler,
         onAccessUnit: @escaping AccessUnitHandler,
         onFailure: @escaping FailureHandler) {
        self.configuration = configuration
        self.queue = queue
        self.onInit = onInit
        self.onAccessUnit = onAccessUnit
        self.onFailure = onFailure
        self.callbackContext = BridgeVideoCallbackContext()
        self.callbackContext.bind(self)
    }

    /// Create a hardware-or-software VideoToolbox session. The system chooses
    /// the encoder; no hardware-only requirement is imposed.
    func start() -> Bool {
        guard !invalidated, session == nil else { return false }
        guard configuration.width > 0, configuration.height > 0 else { return false }
        makePixelBufferPool()

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(configuration.width),
            height: Int32(configuration.height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: Self.outputCallback,
            refcon: Unmanaged.passUnretained(callbackContext).toOpaque(),
            compressionSessionOut: &created
        )
        guard status == noErr, let created else {
            onFailure("VideoToolbox session create failed (\(status))")
            return false
        }

        let realTimeStatus = VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        let reorderStatus = VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_AllowFrameReordering,
            value: kCFBooleanFalse)
        let profileStatus = VTSessionSetProperty(
            created, key: kVTCompressionPropertyKey_ProfileLevel,
            value: kVTProfileLevel_H264_Baseline_AutoLevel)
        guard realTimeStatus == noErr, reorderStatus == noErr, profileStatus == noErr else {
            VTCompressionSessionInvalidate(created)
            onFailure("VideoToolbox realtime/no-reorder configuration failed")
            return false
        }
        _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                                 value: NSNumber(value: configuration.framesPerSecond))

        let keyFrameInterval = max(1, Int(configuration.framesPerSecond
            * configuration.keyFrameIntervalSeconds))
        _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                                 value: NSNumber(value: keyFrameInterval))
        _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration,
                                 value: NSNumber(value: configuration.keyFrameIntervalSeconds))
        _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate,
                                 value: NSNumber(value: configuration.averageBitRate))
        let burstBytes = NSNumber(value: Int(Double(configuration.averageBitRate) * 1.5 / 8))
        let dataRateLimits: [NSNumber] = [burstBytes, NSNumber(value: 1)]
        _ = VTSessionSetProperty(created, key: kVTCompressionPropertyKey_DataRateLimits,
                                 value: dataRateLimits as CFArray)

        let prepareStatus = VTCompressionSessionPrepareToEncodeFrames(created)
        guard prepareStatus == noErr else {
            VTCompressionSessionInvalidate(created)
            onFailure("VideoToolbox prepare failed (\(prepareStatus))")
            return false
        }
        session = created
        return true
    }

    /// Ask for a keyframe on the next submitted frame. Called on the media
    /// queue; no capture or encoder work is started here.
    func requestKeyframe() {
        forceKeyframe = true
    }

    var pendingFrameCount: Int {
        pendingFrames
    }

    /// Decode a host-owned immutable compressed frame and submit it to
    /// VideoToolbox. Returns false when the frame was dropped (pool/queue
    /// pressure, invalid image, or a rejected session).
    func encode(image: CGImage, capturedAt: Double) -> Bool {
        guard !invalidated, let session else { return false }
        guard pendingFrames < 2 else { return false }
        guard let pixelBuffer = makePixelBuffer(from: image) else { return false }

        if firstCapturedAt == nil { firstCapturedAt = capturedAt }
        let relativeSeconds = max(0, capturedAt - (firstCapturedAt ?? capturedAt))
        let raw = UInt64(relativeSeconds * Double(BridgeFMP4Muxer.timescale))
        let firstTick: UInt64
        if let lastSubmittedTicks {
            firstTick = max(raw, lastSubmittedTicks + 1)
        } else {
            firstTick = 0
        }
        lastSubmittedTicks = firstTick
        let pts = CMTime(value: CMTimeValue(firstTick),
                         timescale: CMTimeScale(BridgeFMP4Muxer.timescale))
        let token = BridgeVideoFrameToken(index: firstTick,
                                          capturedAt: capturedAt,
                                          submittedAt: CFAbsoluteTimeGetCurrent(),
                                          generation: configuration.generation)
        let refcon = Unmanaged.passRetained(token).toOpaque()
        var properties: CFDictionary?
        if forceKeyframe {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }

        pendingFrames += 1
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            sourceFrameRefcon: refcon,
            infoFlagsOut: nil
        )
        if status != noErr {
            pendingFrames = max(0, pendingFrames - 1)
            Unmanaged<BridgeVideoFrameToken>.fromOpaque(refcon).release()
            onFailure("VideoToolbox encode rejected the frame (\(status))")
            return false
        }
        forceKeyframe = false
        return true
    }

    /// Complete pending frames, invalidate the session and fence callbacks.
    /// Safe to call from the media queue; the callback only enqueues work and
    /// never blocks, so completing frames cannot deadlock on that queue.
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        callbackContext.deactivate()
        if let session {
            _ = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        pixelBufferPool = nil
        muxer = nil
        lastPresentationTicks = nil
        lastSubmittedTicks = nil
        firstCapturedAt = nil
        pendingFrames = 0
    }

    // MARK: - Callback entry (VideoToolbox thread)

    fileprivate func receive(_ frame: BridgeVideoEncodedFrame) {
        queue.async { [weak self] in
            self?.process(frame)
        }
    }

    fileprivate func receiveDroppedFrame(token: BridgeVideoFrameToken?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingFrames = max(0, self.pendingFrames - 1)
        }
    }

    fileprivate func receiveFailure(status: OSStatus, token: BridgeVideoFrameToken?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.pendingFrames = max(0, self.pendingFrames - 1)
            self.onFailure("VideoToolbox encode callback failed (\(status))")
        }
    }

    /// Convert a sample buffer to a Sendable value on the VideoToolbox thread.
    fileprivate static func assemble(sampleBuffer: CMSampleBuffer,
                                     token: BridgeVideoFrameToken?) -> BridgeVideoEncodedFrame? {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let keyframe = !notSync

        var parameterSets: [Data]?
        if keyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let sets = extractParameterSets(from: format)
            if !sets.isEmpty { parameterSets = sets }
        }

        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var lengthAtOffset = 0
        var totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block,
                                          atOffset: 0,
                                          lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &pointer) == noErr,
              let pointer else {
            return nil
        }

        let extracted = annexBNalus(fromAVCC: pointer, length: totalLength)
        var nalus: [Data] = []
        nalus.reserveCapacity(extracted.count)
        for nal in extracted where !nal.isEmpty {
            let type = nal[0] & 0x1F
            if type == 7 || type == 8 || type == 9 { continue }
            nalus.append(nal)
        }
        guard !nalus.isEmpty else { return nil }

        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let seconds = CMTimeGetSeconds(presentation)
        let ticks = (seconds.isFinite && seconds >= 0)
            ? UInt64(seconds * Double(BridgeFMP4Muxer.timescale))
            : (token?.index ?? 0)
        return BridgeVideoEncodedFrame(nalus: nalus,
                                       keyframe: keyframe,
                                       presentationTicks: ticks,
                                       parameterSets: parameterSets,
                                       capturedAt: token?.capturedAt ?? 0,
                                       submittedAt: token?.submittedAt ?? 0,
                                       generation: token?.generation ?? 0)
    }

    private static func extractParameterSets(from format: CMFormatDescription) -> [Data] {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil
        ) == noErr, count > 0 else {
            return []
        }
        var sets: [Data] = []
        sets.reserveCapacity(count)
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer, size > 0 else {
                continue
            }
            sets.append(Data(bytes: pointer, count: size))
        }
        return sets
    }

    private static func annexBNalus(fromAVCC pointer: UnsafeMutablePointer<Int8>,
                                    length: Int) -> [Data] {
        guard length > 0 else { return [] }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var nalus: [Data] = []
        var index = 0
        while index + 4 <= length {
            let size = Int(bytes[index]) << 24
                | Int(bytes[index + 1]) << 16
                | Int(bytes[index + 2]) << 8
                | Int(bytes[index + 3])
            index += 4
            guard size > 0, index + size <= length else { break }
            nalus.append(Data(bytes: bytes + index, count: size))
            index += size
        }
        return nalus
    }

    // MARK: - Media-queue processing

    private func process(_ frame: BridgeVideoEncodedFrame) {
        pendingFrames = max(0, pendingFrames - 1)
        guard !invalidated, frame.generation == configuration.generation else { return }

        if frame.keyframe, muxer == nil {
            guard let sets = frame.parameterSets,
                  let sps = sets.first(where: { $0.first.map { ($0 & 0x1F) == 7 } ?? false }),
                  let pps = sets.first(where: { $0.first.map { ($0 & 0x1F) == 8 } ?? false }),
                  let created = BridgeFMP4Muxer(width: configuration.width,
                                                height: configuration.height,
                                                sps: sps,
                                                pps: pps) else {
                onFailure("H.264 parameter sets unavailable")
                return
            }
            muxer = created
            onInit(created.initSegment(), created.codecString,
                   configuration.width, configuration.height)
        }
        guard let muxer else { return }

        let nominalTicks = UInt64(max(1, Int(90000.0 / max(0.1, configuration.framesPerSecond))))
        let maximumGapTicks = UInt64(max(1, Int(configuration.maximumFrameGapSeconds * 90_000)))
        var durationTicks: UInt64
        if let last = lastPresentationTicks,
           frame.presentationTicks > last {
            durationTicks = min(frame.presentationTicks - last, maximumGapTicks)
        } else if lastPresentationTicks != nil {
            durationTicks = 1
        } else {
            durationTicks = nominalTicks
        }
        durationTicks = max(1, durationTicks)
        lastPresentationTicks = frame.presentationTicks

        do {
            let fragment = try muxer.fragment(nalus: frame.nalus,
                                              durationTicks: UInt32(clamping: durationTicks),
                                              keyframe: frame.keyframe,
                                              presentationTicks: frame.presentationTicks)
            onAccessUnit(BridgeVideoEncodedAccessUnit(data: fragment,
                                                      keyframe: frame.keyframe,
                                                      presentationTicks: frame.presentationTicks,
                                                      sampleBytes: frame.nalus.reduce(0) { $0 + $1.count }))
        } catch {
            onFailure("fMP4 fragment construction failed")
        }
    }

    // MARK: - Pixel buffers

    private func makePixelBufferPool() {
        pixelBufferPool = nil
        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: configuration.width,
            kCVPixelBufferHeightKey: configuration.height,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let poolAttributes: [CFString: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey: 3,
        ]
        var pool: CVPixelBufferPool?
        if CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                   poolAttributes as CFDictionary,
                                   bufferAttributes as CFDictionary,
                                   &pool) == kCVReturnSuccess {
            pixelBufferPool = pool
        }
    }

    private func makePixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        if let pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            let attributes: [CFString: Any] = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ]
            guard CVPixelBufferCreate(kCFAllocatorDefault,
                                      configuration.width,
                                      configuration.height,
                                      kCVPixelFormatType_32BGRA,
                                      attributes as CFDictionary,
                                      &pixelBuffer) == kCVReturnSuccess else {
                return nil
            }
        }
        guard let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: configuration.width,
            height: configuration.height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0,
                                       y: 0,
                                       width: configuration.width,
                                       height: configuration.height))
        return pixelBuffer
    }

    private static let outputCallback: VTCompressionOutputCallback = {
        refcon, sourceFrameRefcon, status, infoFlags, sampleBuffer in
        guard let refcon else { return }
        let context = Unmanaged<BridgeVideoCallbackContext>
            .fromOpaque(refcon).takeUnretainedValue()
        var token: BridgeVideoFrameToken?
        if let sourceFrameRefcon {
            token = Unmanaged<BridgeVideoFrameToken>
                .fromOpaque(sourceFrameRefcon).takeRetainedValue()
        }
        context.deliver(status: status,
                        infoFlags: infoFlags,
                        sampleBuffer: sampleBuffer,
                        token: token)
    }
}
