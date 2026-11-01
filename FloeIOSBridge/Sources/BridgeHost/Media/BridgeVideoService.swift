import BridgeCore
import CoreGraphics
import Foundation
import ImageIO

// The shared-encoder/fan-out/lifecycle design is adapted from OpenMinis/iCTRL
// `iCTRLUITests/VideoStreamer.swift` at c1e4268859ba858d1579f7b846a56cb40641b7f6
// (Apache-2.0). See ThirdParty/iCTRL/MEDIA_ADAPTATIONS.md and LICENSE/NOTICE.

/// Host-owned H.264/fragmented-MP4 screen stream for the Bridge 1.0 RPC
/// `/stream` seam.
///
/// The service consumes only ``BridgeScreenFrameProvider`` values from
/// `BridgeRuntime.screenFrames`. It never calls XCTest, never starts a second
/// capture session, and never writes a frame, image or video to disk or a log.
/// All decode/encode/mux work happens on one private serial queue; the RPC
/// channel is the only output.
///
/// Lifecycle contract:
/// * `openStream` starts the shared producer when needed and returns `true`
///   only after this subscriber has received the init segment (ftyp+moov) and
///   a real keyframe fragment. It does not wait for the stream to end.
/// * One encoder/muxer is shared by all subscribers. Each subscriber gets a
///   fresh init segment and its own keyframe start.
/// * The encoder stops when the last subscriber leaves, the channel finishes,
///   the source becomes unavailable, a geometry (rotation/size) change occurs,
///   or `stop()` is called. There is no automatic infinite restart loop.
/// * The frame cache is exactly one in-flight capture. A new tick is skipped
///   while a capture is outstanding, and no frame bytes are retained after the
///   encode/mux step.
public final class BridgeVideoService: BridgeRPCStreamSource, @unchecked Sendable {
    /// Fixed response content type. The browser reads `avcC` from the fMP4 init
    /// segment when `X-Codec` is absent; the RPC transport does not expose a
    /// per-stream codec header here.
    public static let streamContentType = "video/mp4"

    /// The pipeline deliberately retains at most one pending capture/frame.
    public static let maximumCachedFrames = 1

    /// The whole init segment and the first IDR must fit in the RPC
    /// per-consumer buffer before `openStream` can return. The RPC default is
    /// 256 KiB; a 1600-wide 2 Mbps H.264 IDR can exceed that. The host owner
    /// should construct the RPC service with
    /// `streamConsumerBufferBytes: BridgeVideoService.recommendedRPCStreamConsumerBufferBytes`.
    public static let recommendedRPCStreamConsumerBufferBytes = 2 * 1_024 * 1_024

    public struct Configuration: Sendable, Equatable {
        /// Longest encoded edge. Both dimensions preserve aspect ratio and are
        /// rounded to even values for H.264.
        public var maxDimension: Int
        /// Requested capture/encode rate. Actual rate can be lower when the SDK
        /// gate is busy or the device is thermally constrained; this is not a
        /// delivery-rate guarantee.
        public var targetFramesPerSecond: Double
        public var averageBitRate: Int
        public var maxClients: Int
        public var keyFrameIntervalSeconds: Double
        /// Maximum time `openStream` waits for init+keyframe before returning
        /// unavailable. The HTTP consumer buffer is separate and bounded by the
        /// RPC service.
        public var openTimeoutSeconds: Double
        /// Consecutive silence from the provider after which an active stream
        /// is closed instead of showing a stale/black stream.
        public var sourceStallTimeoutSeconds: Double
        /// Maximum compressed source image accepted from the provider. This is
        /// a decode guard, not a retained frame cache.
        public var maximumSourceImageBytes: Int
        public var maximumSourceDimension: Int
        /// Chunk size used when writing a fragment into the bounded RPC
        /// channel. The whole fragment is never copied into an unbounded queue.
        public var chunkBytes: Int
        /// Bounded inter-frame timing; protects against a paused clock producing
        /// a giant sample duration.
        public var maximumFrameGapSeconds: Double

        public init(maxDimension: Int = 1_600,
                    targetFramesPerSecond: Double = 5,
                    averageBitRate: Int = 2_000_000,
                    maxClients: Int = 4,
                    keyFrameIntervalSeconds: Double = 2,
                    openTimeoutSeconds: Double = 4,
                    sourceStallTimeoutSeconds: Double = 8,
                    maximumSourceImageBytes: Int = 16 * 1_024 * 1_024,
                    maximumSourceDimension: Int = 8_192,
                    chunkBytes: Int = 64 * 1_024,
                    maximumFrameGapSeconds: Double = 2) {
            self.maxDimension = maxDimension
            self.targetFramesPerSecond = targetFramesPerSecond
            self.averageBitRate = averageBitRate
            self.maxClients = maxClients
            self.keyFrameIntervalSeconds = keyFrameIntervalSeconds
            self.openTimeoutSeconds = openTimeoutSeconds
            self.sourceStallTimeoutSeconds = sourceStallTimeoutSeconds
            self.maximumSourceImageBytes = maximumSourceImageBytes
            self.maximumSourceDimension = maximumSourceDimension
            self.chunkBytes = chunkBytes
            self.maximumFrameGapSeconds = maximumFrameGapSeconds
        }

        var sanitized: Configuration {
            var value = self
            value.maxDimension = min(max(value.maxDimension, 64), 4_096)
            value.targetFramesPerSecond = min(max(value.targetFramesPerSecond, 0.5), 30)
            value.averageBitRate = min(max(value.averageBitRate, 100_000), 20_000_000)
            value.maxClients = min(max(value.maxClients, 1), 16)
            value.keyFrameIntervalSeconds = min(max(value.keyFrameIntervalSeconds, 0.5), 10)
            value.openTimeoutSeconds = min(max(value.openTimeoutSeconds, 1), 15)
            value.sourceStallTimeoutSeconds = min(max(value.sourceStallTimeoutSeconds, 2), 60)
            value.maximumSourceImageBytes = min(max(value.maximumSourceImageBytes, 1_024 * 1_024),
                                                64 * 1_024 * 1_024)
            value.maximumSourceDimension = min(max(value.maximumSourceDimension, 256), 16_384)
            value.chunkBytes = min(max(value.chunkBytes, 4 * 1_024), 512 * 1_024)
            value.maximumFrameGapSeconds = min(max(value.maximumFrameGapSeconds, 0.2), 5)
            return value
        }
    }

    public struct Diagnostics: Sendable, Equatable {
        public let isRunning: Bool
        public let subscriberCount: Int
        public let generation: UInt64
        public let framesCaptured: Int
        public let framesEncoded: Int
        public let framesDropped: Int
        public let keyFrames: Int
        public let fragmentsSent: Int
        public let bytesSent: Int
        public let encodedWidth: Int
        public let encodedHeight: Int
        public let codec: String?
        public let captureOverlapPrevented: Int
        public let geometryFences: Int
        public let sourceUnavailableCount: Int
        public let lastError: String?
    }

    public let contentType: String = BridgeVideoService.streamContentType

    private let frames: BridgeScreenFrameRegistry
    private let configuration: Configuration
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let countersLock = BridgeRPCLock()
    private var counters = CounterState()

    private var subscribers: [UUID: Subscriber] = [:]
    private var pipeline: Pipeline?
    private var timer: DispatchSourceTimer?
    private var captureTask: Task<Void, Never>?
    private var captureInFlight = false
    private var generation: UInt64 = 0

    public init(frames: BridgeScreenFrameRegistry = BridgeRuntime.screenFrames,
                configuration: Configuration = Configuration()) {
        self.frames = frames
        self.configuration = configuration.sanitized
        self.queue = DispatchQueue(label: "org.floeagent.iosbridge.video.media",
                                   qos: .userInitiated)
        self.queue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        countersLock.withLock { counters.isRunning }
    }

    public var subscriberCount: Int {
        countersLock.withLock { counters.subscriberCount }
    }

    public func diagnostics() -> Diagnostics {
        countersLock.withLock {
            Diagnostics(isRunning: counters.isRunning,
                        subscriberCount: counters.subscriberCount,
                        generation: counters.generation,
                        framesCaptured: counters.framesCaptured,
                        framesEncoded: counters.framesEncoded,
                        framesDropped: counters.framesDropped,
                        keyFrames: counters.keyFrames,
                        fragmentsSent: counters.fragmentsSent,
                        bytesSent: counters.bytesSent,
                        encodedWidth: counters.encodedWidth,
                        encodedHeight: counters.encodedHeight,
                        codec: counters.codec,
                        captureOverlapPrevented: counters.captureOverlapPrevented,
                        geometryFences: counters.geometryFences,
                        sourceUnavailableCount: counters.sourceUnavailableCount,
                        lastError: counters.lastError)
        }
    }

    // MARK: - BridgeRPCStreamSource

    public func openStream(clientID: String, channel: BridgeRPCStreamChannel) async -> Bool {
        guard frames.currentProvider() != nil else {
            channel.finish()
            return false
        }

        let subscriber = Subscriber(clientID: clientID, channel: channel)
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                subscriber.attach(continuation)
                queue.async { [weak self] in
                    self?.accept(subscriber)
                }
            }
        }, onCancel: {
            subscriber.cancel()
            queue.async { [weak self] in
                self?.removeSubscriberLocked(subscriber, finishChannel: false)
            }
        })
    }

    /// Stop the producer, unsubscribe every consumer and fence all callbacks.
    /// A later `openStream` may start a fresh generation.
    public func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            stopLocked()
        } else {
            queue.sync { stopLocked() }
        }
    }

    // MARK: - Subscriber admission

    private func accept(_ subscriber: Subscriber) {
        if subscriber.isCancelled {
            subscriber.resolve(false)
            subscriber.channel.finish()
            return
        }
        guard frames.currentProvider() != nil else {
            subscriber.resolve(false)
            subscriber.channel.finish()
            return
        }
        guard subscribers.count < configuration.maxClients else {
            subscriber.resolve(false)
            subscriber.channel.finish()
            updateCounters { $0.lastError = "client limit reached" }
            return
        }
        guard !subscribers.values.contains(where: { $0.id == subscriber.id }) else { return }

        subscribers[subscriber.id] = subscriber
        updateSubscriberCount()

        if let existing = pipeline {
            if let initSegment = existing.initSegment {
                if !sendInit(initSegment, to: subscriber) {
                    removeSubscriberLocked(subscriber, finishChannel: true)
                    return
                }
                existing.encoder?.requestKeyframe()
            }
        } else {
            startPipelineLocked()
        }

        let timeout = configuration.openTimeoutSeconds
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            guard self.subscribers[subscriber.id] != nil,
                  !subscriber.isReady else { return }
            self.removeSubscriberLocked(subscriber, finishChannel: true)
            self.updateCounters { $0.lastError = "stream open timed out" }
        }
    }

    // MARK: - Producer lifecycle

    private func startPipelineLocked() {
        guard pipeline == nil, !subscribers.isEmpty else { return }
        guard frames.currentProvider() != nil else {
            closeAllSubscribersLocked()
            return
        }
        generation &+= 1
        let newPipeline = Pipeline(generation: generation,
                                   startedAt: CFAbsoluteTimeGetCurrent())
        pipeline = newPipeline
        updateCounters {
            $0.isRunning = true
            $0.generation = newPipeline.generation
            $0.encodedWidth = 0
            $0.encodedHeight = 0
            $0.codec = nil
            $0.lastError = nil
        }

        let source = DispatchSource.makeTimerSource(queue: queue)
        let interval = activeInterval()
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(15))
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        timer = source
        source.resume()
    }

    private func stopPipelineLocked() {
        timer?.cancel()
        timer = nil
        // Keep the capture gate closed until the outstanding provider call
        // actually returns. Cancellation is cooperative; clearing the flag
        // here could start a second capture while the SDK gate is still busy.
        let hadCapture = captureInFlight || captureTask != nil
        captureTask?.cancel()
        captureTask = nil
        if !hadCapture { captureInFlight = false }
        pipeline?.encoder?.invalidate()
        pipeline = nil
        generation &+= 1
        updateCounters {
            $0.isRunning = false
            $0.encodedWidth = 0
            $0.encodedHeight = 0
            $0.codec = nil
        }
    }

    private func stopLocked() {
        closeAllSubscribersLocked()
        stopPipelineLocked()
        updateCounters {
            $0.subscriberCount = 0
            $0.isRunning = false
        }
    }

    private func tick() {
        pruneFinishedSubscribersLocked()
        guard let current = pipeline else { return }
        guard !subscribers.isEmpty else {
            stopPipelineLocked()
            return
        }
        guard !captureInFlight else {
            updateCounters { $0.captureOverlapPrevented += 1 }
            return
        }
        guard let provider = frames.currentProvider() else {
            handleSourceUnavailableLocked(message: "frame provider unavailable")
            return
        }
        // A busy SDK gate (an RPC action owns it) or a temporarily locked screen
        // must skip this tick, not tear down the stream. Persistent silence is
        // handled by the bounded stall timeout below.
        guard provider.frameCaptureReady else {
            handleCaptureMissLocked(pipeline: current)
            return
        }

        let interval = activeInterval()
        timer?.schedule(deadline: .now() + interval,
                        repeating: interval,
                        leeway: .milliseconds(15))

        captureInFlight = true
        let generation = current.generation
        captureTask = Task { [weak self] in
            let frame = await provider.captureFrame()
            guard let self else { return }
            self.queue.async {
                self.finishCaptureLocked(frame, generation: generation)
            }
        }
    }

    private func finishCaptureLocked(_ frame: BridgeScreenFrame?, generation: UInt64) {
        captureInFlight = false
        captureTask = nil
        guard generation == self.generation, let current = pipeline else { return }

        guard let frame else {
            handleCaptureMissLocked(pipeline: current)
            return
        }
        guard !frame.imageData.isEmpty,
              frame.imageData.count <= configuration.maximumSourceImageBytes else {
            updateCounters { $0.framesDropped += 1 }
            handleCaptureMissLocked(pipeline: current)
            return
        }
        guard frame.pixelWidth > 0, frame.pixelHeight > 0,
              frame.pixelWidth <= configuration.maximumSourceDimension,
              frame.pixelHeight <= configuration.maximumSourceDimension else {
            updateCounters { $0.framesDropped += 1 }
            handleCaptureMissLocked(pipeline: current)
            return
        }
        guard let image = decode(frame) else {
            updateCounters { $0.framesDropped += 1 }
            handleCaptureMissLocked(pipeline: current)
            return
        }

        // Rotation or screen-size changes cannot be represented by a single
        // fMP4 init segment. Close every consumer and require a fresh open so a
        // player never mixes two geometries in one MSE SourceBuffer.
        if current.sourceWidth != 0,
           current.sourceWidth != image.width || current.sourceHeight != image.height {
            updateCounters { $0.geometryFences += 1 }
            closeAllSubscribersLocked()
            stopPipelineLocked()
            return
        }
        if current.sourceWidth == 0 {
            current.sourceWidth = image.width
            current.sourceHeight = image.height
        }

        if current.encoder == nil {
            guard let encoder = makeEncoderLocked(pipeline: current, image: image) else {
                updateCounters { $0.lastError = "encoder unavailable" }
                closeAllSubscribersLocked()
                stopPipelineLocked()
                return
            }
            current.encoder = encoder
        }
        guard let encoder = current.encoder else { return }

        updateCounters { $0.framesCaptured += 1 }
        let accepted = encoder.encode(image: image,
                                      capturedAt: frame.capturedAt.timeIntervalSince1970)
        if accepted {
            current.lastProgressAt = CFAbsoluteTimeGetCurrent()
            updateCounters { $0.framesEncoded += 1 }
        } else {
            updateCounters { $0.framesDropped += 1 }
        }
    }

    private func handleCaptureMissLocked(pipeline current: Pipeline) {
        let now = CFAbsoluteTimeGetCurrent()
        let last = current.lastProgressAt > 0 ? current.lastProgressAt : current.startedAt
        if now - last >= configuration.sourceStallTimeoutSeconds {
            handleSourceUnavailableLocked(message: "frame capture stalled")
        }
    }

    private func handleSourceUnavailableLocked(message: String) {
        updateCounters {
            $0.sourceUnavailableCount += 1
            $0.lastError = message
        }
        closeAllSubscribersLocked()
        stopPipelineLocked()
    }

    private func activeInterval() -> TimeInterval {
        var rate = configuration.targetFramesPerSecond
        switch ProcessInfo.processInfo.thermalState {
        case .serious:
            rate = min(rate, 5)
        case .critical:
            rate = min(rate, 2.5)
        default:
            break
        }
        return 1.0 / max(0.5, rate)
    }

    // MARK: - Encoder callbacks (media queue)

    private func makeEncoderLocked(pipeline current: Pipeline,
                                   image: CGImage) -> BridgeVideoEncoder? {
        let maximum = max(2, configuration.maxDimension)
        let scale = min(1, Double(maximum) / Double(max(image.width, image.height)))
        let width = max(2, Int((Double(image.width) * scale).rounded(.down)) & ~1)
        let height = max(2, Int((Double(image.height) * scale).rounded(.down)) & ~1)
        guard width >= 2, height >= 2 else { return nil }

        let encoderConfiguration = BridgeVideoEncoderConfiguration(
            generation: current.generation,
            width: width,
            height: height,
            framesPerSecond: configuration.targetFramesPerSecond,
            averageBitRate: configuration.averageBitRate,
            keyFrameIntervalSeconds: configuration.keyFrameIntervalSeconds,
            maximumFrameGapSeconds: configuration.maximumFrameGapSeconds
        )
        let generation = current.generation
        let encoder = BridgeVideoEncoder(
            configuration: encoderConfiguration,
            queue: queue,
            onInit: { [weak self] initSegment, codec, initWidth, initHeight in
                self?.handleInitLocked(generation: generation,
                                       initSegment: initSegment,
                                       codec: codec,
                                       width: initWidth,
                                       height: initHeight)
            },
            onAccessUnit: { [weak self] accessUnit in
                self?.handleAccessUnitLocked(generation: generation, accessUnit: accessUnit)
            },
            onFailure: { [weak self] message in
                guard let service = self else { return }
                service.queue.async {
                    service.handleEncoderFailureLocked(generation: generation, message: message)
                }
            }
        )
        guard encoder.start() else { return nil }
        current.encoder = encoder
        updateCounters {
            $0.encodedWidth = width
            $0.encodedHeight = height
        }
        return encoder
    }

    private func handleInitLocked(generation: UInt64,
                                  initSegment: Data,
                                  codec: String,
                                  width: Int,
                                  height: Int) {
        guard let current = pipeline, current.generation == generation else { return }
        current.initSegment = initSegment
        updateCounters {
            $0.codec = codec
            $0.encodedWidth = width
            $0.encodedHeight = height
        }
        for subscriber in Array(subscribers.values) {
            guard !subscriber.initWasSent else { continue }
            guard sendInit(initSegment, to: subscriber) else {
                removeSubscriberLocked(subscriber, finishChannel: true)
                continue
            }
        }
        if subscribers.isEmpty {
            stopPipelineLocked()
        }
    }

    private func handleAccessUnitLocked(generation: UInt64,
                                        accessUnit: BridgeVideoEncodedAccessUnit) {
        guard let current = pipeline, current.generation == generation else { return }
        guard !subscribers.isEmpty else {
            stopPipelineLocked()
            return
        }
        if accessUnit.keyframe {
            updateCounters { $0.keyFrames += 1 }
        }
        updateCounters {
            $0.fragmentsSent += 1
            $0.bytesSent += accessUnit.data.count
        }
        fanoutLocked(accessUnit)
    }

    private func handleEncoderFailureLocked(generation: UInt64, message: String) {
        guard let current = pipeline, current.generation == generation else { return }
        updateCounters { $0.lastError = message }
        closeAllSubscribersLocked()
        stopPipelineLocked()
    }

    // MARK: - Fan-out

    private func fanoutLocked(_ accessUnit: BridgeVideoEncodedAccessUnit) {
        guard let current = pipeline else { return }
        for subscriber in Array(subscribers.values) {
            if subscriber.channel.isFinished || subscriber.isCancelled {
                removeSubscriberLocked(subscriber, finishChannel: false)
                continue
            }
            if !subscriber.initWasSent {
                guard let initSegment = current.initSegment,
                      sendInit(initSegment, to: subscriber) else {
                    removeSubscriberLocked(subscriber, finishChannel: true)
                    continue
                }
            }
            // A late joiner must start at a keyframe. Until this subscriber has
            // its own keyframe, predicted fragments are skipped.
            if !subscriber.keyframeWasSent && !accessUnit.keyframe {
                continue
            }
            guard sendChunks(accessUnit.data, to: subscriber) else {
                removeSubscriberLocked(subscriber, finishChannel: true)
                continue
            }
            if accessUnit.keyframe && !subscriber.keyframeWasSent {
                subscriber.markKeyframeSent()
                if !subscriber.isReady {
                    subscriber.resolve(true)
                    updateSubscriberCount()
                }
            }
        }
        if subscribers.isEmpty {
            stopPipelineLocked()
        }
    }

    private func sendInit(_ initSegment: Data, to subscriber: Subscriber) -> Bool {
        guard !subscriber.initWasSent else { return true }
        guard !subscriber.channel.isFinished else { return false }
        guard sendChunks(initSegment, to: subscriber) else { return false }
        subscriber.markInitSent()
        return true
    }

    private func sendChunks(_ data: Data, to subscriber: Subscriber) -> Bool {
        guard !data.isEmpty else { return true }
        var offset = 0
        while offset < data.count {
            if subscriber.channel.isFinished || subscriber.isCancelled { return false }
            let end = min(offset + configuration.chunkBytes, data.count)
            let chunk = data.subdata(in: offset..<end)
            guard subscriber.channel.yield(chunk) else { return false }
            offset = end
        }
        return true
    }

    private func pruneFinishedSubscribersLocked() {
        for subscriber in Array(subscribers.values)
        where subscriber.channel.isFinished || subscriber.isCancelled {
            removeSubscriberLocked(subscriber, finishChannel: false)
        }
    }

    private func removeSubscriberLocked(_ subscriber: Subscriber, finishChannel: Bool) {
        guard subscribers.removeValue(forKey: subscriber.id) != nil else {
            if finishChannel {
                subscriber.resolve(false)
                subscriber.channel.finish()
            }
            return
        }
        if !subscriber.isReady {
            subscriber.resolve(false)
        }
        if finishChannel {
            subscriber.channel.finish()
        }
        updateSubscriberCount()
        if subscribers.isEmpty {
            stopPipelineLocked()
        }
    }

    private func closeAllSubscribersLocked() {
        let closing = Array(subscribers.values)
        subscribers.removeAll()
        for subscriber in closing {
            if !subscriber.isReady {
                subscriber.resolve(false)
            }
            subscriber.channel.finish()
        }
        updateSubscriberCount()
    }

    // MARK: - Diagnostics / helpers

    private func updateSubscriberCount() {
        updateCounters { $0.subscriberCount = self.subscribers.count }
    }

    private func updateCounters(_ body: (inout CounterState) -> Void) {
        countersLock.withLock { body(&counters) }
    }

    private func decode(_ frame: BridgeScreenFrame) -> CGImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(frame.imageData as CFData, options) else {
            return nil
        }
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let imageOptions = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, imageOptions) else {
            return nil
        }
        guard image.width > 0, image.height > 0 else { return nil }
        return image
    }

    private struct CounterState {
        var isRunning = false
        var subscriberCount = 0
        var generation: UInt64 = 0
        var framesCaptured = 0
        var framesEncoded = 0
        var framesDropped = 0
        var keyFrames = 0
        var fragmentsSent = 0
        var bytesSent = 0
        var encodedWidth = 0
        var encodedHeight = 0
        var codec: String?
        var captureOverlapPrevented = 0
        var geometryFences = 0
        var sourceUnavailableCount = 0
        var lastError: String?
    }

    private final class Pipeline {
        let generation: UInt64
        let startedAt: Double
        var encoder: BridgeVideoEncoder?
        var initSegment: Data?
        var sourceWidth = 0
        var sourceHeight = 0
        var lastProgressAt: Double = 0

        init(generation: UInt64, startedAt: Double) {
            self.generation = generation
            self.startedAt = startedAt
        }
    }

    /// Admission state and continuation are lock-guarded; channel writes and
    /// init/keyframe transitions happen only on the media queue. This is the
    /// ownership proof for the `@unchecked Sendable` conformance.
    private final class Subscriber: @unchecked Sendable {
        let id = UUID()
        let clientID: String
        let channel: BridgeRPCStreamChannel

        private let lock = BridgeRPCLock()
        private var resolved = false
        private var cancelled = false
        private var ready = false
        private var initSent = false
        private var keyframeSent = false
        private var continuation: CheckedContinuation<Bool, Never>?

        init(clientID: String, channel: BridgeRPCStreamChannel) {
            self.clientID = clientID
            self.channel = channel
        }

        var isCancelled: Bool {
            lock.withLock { cancelled }
        }

        var isReady: Bool {
            lock.withLock { ready }
        }

        var initWasSent: Bool {
            lock.withLock { initSent }
        }

        var keyframeWasSent: Bool {
            lock.withLock { keyframeSent }
        }

        func attach(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.lock()
            if resolved {
                let value = ready && !cancelled
                lock.unlock()
                continuation.resume(returning: value)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        func resolve(_ value: Bool) {
            var continuation: CheckedContinuation<Bool, Never>?
            lock.lock()
            if resolved {
                lock.unlock()
                return
            }
            resolved = true
            ready = value && !cancelled
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: value && !cancelled)
        }

        func cancel() {
            var continuation: CheckedContinuation<Bool, Never>?
            lock.lock()
            if resolved {
                cancelled = true
                lock.unlock()
                return
            }
            cancelled = true
            resolved = true
            ready = false
            continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: false)
        }

        func markInitSent() {
            lock.withLock { initSent = true }
        }

        func markKeyframeSent() {
            lock.withLock { keyframeSent = true }
        }
    }
}
