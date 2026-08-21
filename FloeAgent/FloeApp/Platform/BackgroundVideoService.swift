// FloeApp — Picture-in-Picture background keep-alive for agent runs.
//
// Translation-app style: a Picture-in-Picture video that plays the run's
// progress keeps the app alive while the user leaves the PiP floating.
// The video carries real, visible content (task title + progress + status),
// so it satisfies App Review's "must actually present audible/visual
// content" rule. The looping progress asset is synthesized on-device.

#if canImport(UIKit)
import Foundation
import UIKit
import AVKit
import AVFoundation
import FloeCore

@MainActor
final class BackgroundVideoService: NSObject, ObservableObject {
    struct GuidanceHint: Sendable {
        var label: String
        var instruction: String
        var point: CGPoint
    }

    @Published private(set) var isPiPActive = false
    @Published private(set) var isPreparingPiP = false
    @Published private(set) var isPiPPrepared = false
    @Published private(set) var lastError: String?
    /// Called only when AVKit/system closes PiP while Floe still owns the
    /// controller. Programmatic run teardown clears ownership first.
    var onUserStopped: (() -> Void)?

    private var pipController: AVPictureInPictureController?
    private var playerLayer: AVPlayerLayer?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentTitle = ""
    private var currentProgress = ""
    private var guidanceImage: UIImage?
    private var guidanceHints: [GuidanceHint] = []
    private var refreshTask: Task<Void, Never>?
    private var startGeneration: UInt64 = 0
    private var currentAssetURL: URL?
    /// AVKit requires the source layer to be in a visible hierarchy before
    /// PiP starts. Keep a small inline preview attached while the run is active.
    private var inlinePreview: UIView?
    private var isProgrammaticRetraction = false

    /// Starts (or updates) the PiP progress video for an active run. The
    /// user keeps the app alive by floating this PiP while in background.
    func begin(
        title: String,
        initialProgress: String,
        startImmediately: Bool = true
    ) async {
        startGeneration &+= 1
        let generation = startGeneration
        currentTitle = title
        currentProgress = initialProgress
        guidanceImage = nil
        guidanceHints = []
        stopPiPInternal()
        isPreparingPiP = true
        lastError = nil
        FloeLogger(category: .app).info(
            "pictureInPicturePrepareStarted generation=\(generation)"
        )
        defer { isPreparingPiP = false }
        // PiP with a playing video requires the audio background mode. Set the
        // session active so the system registers that capability at task start
        // instead of suspending the app the moment it backgrounds.
        configureAudioSession()
        guard let assetURL = await synthesizeProgressVideo(
            title: title,
            progress: initialProgress,
            guidanceImage: nil,
            guidanceHints: []
        ) else {
            lastError = "无法创建画中画进度视频"
            FloeLogger(category: .app).error(
                "pictureInPicturePrepareFailed stage=videoSynthesis generation=\(generation)"
            )
            deactivateAudioSession()
            return
        }
        guard !Task.isCancelled, generation == startGeneration else {
            try? FileManager.default.removeItem(at: assetURL)
            deactivateAudioSession()
            return
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            lastError = "当前设备不支持画中画"
            FloeLogger(category: .app).warning(
                "pictureInPicturePrepareFailed stage=unsupported generation=\(generation)"
            )
            try? FileManager.default.removeItem(at: assetURL)
            deactivateAudioSession()
            return
        }
        let item = AVPlayerItem(url: assetURL)
        let queue = AVQueuePlayer(playerItem: item)
        let layer = AVPlayerLayer(player: queue)
        guard attachInlinePreview(layer: layer) else {
            lastError = "画中画需要应用处于前台并显示预览"
            FloeLogger(category: .app).warning(
                "pictureInPicturePrepareFailed stage=inlinePreview generation=\(generation)"
            )
            try? FileManager.default.removeItem(at: assetURL)
            deactivateAudioSession()
            return
        }
        guard let controller = AVPictureInPictureController(playerLayer: layer) else {
            lastError = "无法初始化画中画控制器"
            FloeLogger(category: .app).error(
                "pictureInPicturePrepareFailed stage=controller generation=\(generation)"
            )
            removeInlinePreview()
            try? FileManager.default.removeItem(at: assetURL)
            deactivateAudioSession()
            return
        }
        currentAssetURL = assetURL
        player = queue
        playerLayer = layer
        looper = AVPlayerLooper(player: queue, templateItem: item)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pipController = controller
        queue.play()
        // AVKit readiness is asynchronous and varies by device. Starting at
        // a fixed delay silently fails on slower iPads, so wait for the real
        // capability signal with a bounded timeout.
        let deadline = Date().addingTimeInterval(6)
        while !controller.isPictureInPicturePossible && Date() < deadline {
            guard generation == startGeneration, !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard generation == startGeneration else { return }
        guard controller.isPictureInPicturePossible else {
            lastError = "画中画尚未就绪，请保持应用在前台后重试"
            FloeLogger(category: .app).warning(
                "pictureInPicturePrepareFailed stage=readinessTimeout generation=\(generation)"
            )
            stopPiPInternal()
            return
        }
        isPiPPrepared = true
        guard startImmediately else {
            FloeLogger(category: .app).info(
                "pictureInPicturePrepared generation=\(generation)"
            )
            return
        }
        startPreparedPictureInPicture()
    }

    func startPreparedPictureInPicture() {
        guard let controller = pipController,
              controller.isPictureInPicturePossible,
              !controller.isPictureInPictureActive else { return }
        FloeLogger(category: .app).info(
            "pictureInPictureStartRequested generation=\(startGeneration)"
        )
        controller.startPictureInPicture()
    }

    /// Returning to Floe retracts the floating surface without destroying
    /// the prepared player. Leaving the app again can therefore resume PiP
    /// while the same task batch remains active.
    func retractForForeground() {
        guard let controller = pipController, controller.isPictureInPictureActive else { return }
        isProgrammaticRetraction = true
        controller.stopPictureInPicture()
        FloeLogger(category: .app).info("pictureInPictureRetractedForForeground")
    }

    /// Updates the progress text and re-renders the looping video so the PiP
    /// actually reflects the latest state instead of a frozen first frame.
    func update(progress: String) {
        update(title: currentTitle, progress: progress)
    }

    func update(title: String, progress: String) {
        currentTitle = title
        currentProgress = progress
        let generation = startGeneration
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self, generation == self.startGeneration else { return }
            await self.refreshVideo(
                title: title,
                progress: progress,
                guidanceImage: self.guidanceImage,
                guidanceHints: self.guidanceHints,
                generation: generation
            )
        }
    }

    /// Replaces task progress with the latest operation guide while a real
    /// shared frame and hints exist. Clearing guidance returns PiP to progress.
    func updateGuidance(image: UIImage?, hints: [GuidanceHint]) {
        guidanceImage = image
        guidanceHints = hints
        let generation = startGeneration
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self, generation == self.startGeneration else { return }
            await self.refreshVideo(
                title: self.currentTitle,
                progress: self.currentProgress,
                guidanceImage: image,
                guidanceHints: hints,
                generation: generation
            )
        }
    }

    /// Re-synthesizes the progress asset and hot-swaps the player item so the
    /// floating PiP shows the latest title/progress without restarting PiP.
    private func refreshVideo(
        title: String,
        progress: String,
        guidanceImage: UIImage?,
        guidanceHints: [GuidanceHint],
        generation: UInt64
    ) async {
        guard isPiPActive, let player else { return }
        guard let assetURL = await synthesizeProgressVideo(
            title: title,
            progress: progress,
            guidanceImage: guidanceImage,
            guidanceHints: guidanceHints
        ) else { return }
        guard !Task.isCancelled, generation == startGeneration, isPiPActive else {
            try? FileManager.default.removeItem(at: assetURL)
            return
        }
        let item = AVPlayerItem(url: assetURL)
        looper?.disableLooping()
        // Never empty the active player's queue. Doing so makes AVKit close an
        // already-running PiP session before the replacement item arrives.
        // Remove only queued loop copies, then atomically replace the current
        // item so progress updates cannot tear down the background surface.
        for queuedItem in player.items().dropFirst() {
            player.remove(queuedItem)
        }
        player.replaceCurrentItem(with: item)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.play()
        if let old = currentAssetURL {
            try? FileManager.default.removeItem(at: old)
        }
        currentAssetURL = assetURL
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        startGeneration &+= 1
        stopPiPInternal()
    }

    private func stopPiPInternal() {
        refreshTask?.cancel()
        refreshTask = nil
        pipController?.stopPictureInPicture()
        pipController = nil
        looper = nil
        player?.pause()
        player = nil
        playerLayer = nil
        guidanceImage = nil
        guidanceHints = []
        removeInlinePreview()
        if let currentAssetURL {
            try? FileManager.default.removeItem(at: currentAssetURL)
            self.currentAssetURL = nil
        }
        isPiPActive = false
        isPreparingPiP = false
        isPiPPrepared = false
        isProgrammaticRetraction = false
        deactivateAudioSession()
    }

    /// Releases playback state after the user or system closes PiP without
    /// asking AVKit to stop the already-stopped controller a second time.
    private func handlePiPStopped(controllerID: ObjectIdentifier) {
        guard let currentController = pipController,
              ObjectIdentifier(currentController) == controllerID else { return }
        if isProgrammaticRetraction {
            isProgrammaticRetraction = false
            isPiPActive = false
            FloeLogger(category: .app).info("pictureInPictureRetractionCompleted")
            return
        }
        refreshTask?.cancel()
        refreshTask = nil
        startGeneration &+= 1
        pipController = nil
        looper = nil
        player?.pause()
        player = nil
        playerLayer = nil
        guidanceImage = nil
        guidanceHints = []
        removeInlinePreview()
        if let currentAssetURL {
            try? FileManager.default.removeItem(at: currentAssetURL)
            self.currentAssetURL = nil
        }
        isPiPActive = false
        isPiPPrepared = false
        deactivateAudioSession()
        onUserStopped?()
    }

    /// Configures the audio session for background playback so the PiP video
    /// keeps the app alive. Without this the app suspends the moment it
    /// backgrounds even while the PiP floats. Failure never breaks the run.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            let nsError = error as NSError
            FloeLogger(category: .app).warning(
                "pictureInPictureAudioSessionFailed domain=\(nsError.domain) code=\(nsError.code)"
            )
        }
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func attachInlinePreview(layer: AVPlayerLayer) -> Bool {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let window = scene.windows.first(where: \.isKeyWindow) else { return false }
        removeInlinePreview()
        // AVKit requires the source layer in the active hierarchy while it
        // prepares automatic PiP. Keep the source present without placing a
        // distracting black preview over the conversation UI.
        let width: CGFloat = 2
        let view = UIView(frame: CGRect(
            x: window.safeAreaInsets.left,
            y: window.bounds.height - window.safeAreaInsets.bottom - width,
            width: width,
            height: width
        ))
        view.backgroundColor = .clear
        view.layer.masksToBounds = true
        layer.frame = view.bounds
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        window.addSubview(view)
        inlinePreview = view
        return true
    }

    private func removeInlinePreview() {
        inlinePreview?.removeFromSuperview()
        inlinePreview = nil
    }

    private func renderProgressFrame(
        title: String,
        progress: String,
        guidanceImage: UIImage?,
        guidanceHints: [GuidanceHint]
    ) -> UIImage? {
        let size = CGSize(width: 640, height: 360)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if let guidanceImage, !guidanceHints.isEmpty {
                let sourceSize = guidanceImage.size
                let scale = min(size.width / max(1, sourceSize.width), size.height / max(1, sourceSize.height))
                let fitted = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
                let imageRect = CGRect(
                    x: (size.width - fitted.width) / 2,
                    y: (size.height - fitted.height) / 2,
                    width: fitted.width,
                    height: fitted.height
                )
                guidanceImage.draw(in: imageRect)
                for (index, hint) in guidanceHints.prefix(4).enumerated() {
                    let center = CGPoint(
                        x: imageRect.minX + min(max(hint.point.x, 0), 1) * imageRect.width,
                        y: imageRect.minY + min(max(hint.point.y, 0), 1) * imageRect.height
                    )
                    let marker = CGRect(x: center.x - 18, y: center.y - 18, width: 36, height: 36)
                    UIColor.systemYellow.withAlphaComponent(0.3).setFill()
                    context.cgContext.fillEllipse(in: marker)
                    UIColor.systemYellow.setStroke()
                    context.cgContext.setLineWidth(3)
                    context.cgContext.strokeEllipse(in: marker)
                    let number = "\(index + 1)" as NSString
                    number.draw(
                        at: CGPoint(x: center.x - 6, y: center.y - 10),
                        withAttributes: [
                            .font: UIFont.systemFont(ofSize: 17, weight: .bold),
                            .foregroundColor: UIColor.systemYellow
                        ]
                    )
                }
                let instruction = guidanceHints.prefix(2).enumerated().map {
                    "\($0.offset + 1). \($0.element.instruction)"
                }.joined(separator: "   ")
                let overlay = CGRect(x: 0, y: size.height - 66, width: size.width, height: 66)
                UIColor.black.withAlphaComponent(0.78).setFill()
                context.fill(overlay)
                (instruction as NSString).draw(
                    in: overlay.insetBy(dx: 18, dy: 12),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                        .foregroundColor: UIColor.white
                    ]
                )
                return
            }
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: UIColor.white
            ]
            let progressAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 22, weight: .regular),
                .foregroundColor: UIColor.lightGray
            ]
            title.draw(at: CGPoint(x: 32, y: 24), withAttributes: titleAttributes)
            progress.draw(at: CGPoint(x: 32, y: 96), withAttributes: progressAttributes)
        }
    }

    /// Synthesizes a short looping MP4 whose frames carry the run title and
    /// progress. Real, visible content — the surface review expects. PiP owns
    /// video playback continuity; avoiding a hand-built compressed audio
    /// sample also avoids AVAssetWriter rejecting the whole progress asset on
    /// some devices before PiP can even be requested.
    private func synthesizeProgressVideo(
        title: String,
        progress: String,
        guidanceImage: UIImage?,
        guidanceHints: [GuidanceHint]
    ) async -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-progress-\(UUID().uuidString).mp4")
        let size = CGSize(width: 640, height: 360)
        guard let frame = renderProgressFrame(
            title: title,
            progress: progress,
            guidanceImage: guidanceImage,
            guidanceHints: guidanceHints
        ),
              let cgImage = frame.cgImage else { return nil }
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: input,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                    kCVPixelBufferWidthKey as String: Int(size.width),
                    kCVPixelBufferHeightKey as String: Int(size.height)
                ]
            )
            guard writer.canAdd(input) else { return nil }
            writer.add(input)
            guard writer.startWriting() else { return nil }
            writer.startSession(atSourceTime: .zero)
            // 5 seconds at 2 fps = 10 frames of the same progress image.
            let readinessDeadline = Date().addingTimeInterval(2)
            for index in 0..<10 {
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    guard writer.status == .writing, Date() < readinessDeadline else {
                        writer.cancelWriting()
                        return nil
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                if let buffer = Self.pixelBuffer(from: cgImage, size: size) {
                    guard adaptor.append(
                        buffer,
                        withPresentationTime: CMTime(value: CMTimeValue(index), timescale: 2)
                    ) else {
                        writer.cancelWriting()
                        return nil
                    }
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            return writer.status == .completed ? url : nil
        } catch {
            return nil
        }
    }

    /// Builds a silent mono 16-bit PCM sample buffer of the given duration.
    /// Used so the synthesized PiP video carries an audio track.
    private static func silentAudioSampleBuffer(duration: Double, sampleRate: Double = 44_100) -> CMSampleBuffer? {
        let sampleCount = Int(duration * sampleRate)
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        )
        guard let format else { return nil }
        let dataSize = sampleCount * 2
        var blockBuffer: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard let blockBuffer else { return nil }
        // Explicitly zero the samples so the track is genuinely silent.
        var pointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer)
        if let pointer {
            memset(pointer, 0, dataSize)
        }
        var sampleBuffer: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: sampleCount,
            presentationTimeStamp: .zero,
            packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer
        )
        return sampleBuffer
    }

    private static func pixelBuffer(from cgImage: CGImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32ARGB,
            attributes as CFDictionary,
            &buffer
        )
        guard let pixelBuffer = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        return pixelBuffer
    }
}

extension BackgroundVideoService: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.isPiPActive = true
            self.isPreparingPiP = false
            self.lastError = nil
            FloeLogger(category: .app).info("pictureInPictureDidStart")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor in
            FloeLogger(category: .app).info("pictureInPictureDidStop")
            self.handlePiPStopped(controllerID: controllerID)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            let nsError = error as NSError
            FloeLogger(category: .app).error(
                "pictureInPictureStartFailed domain=\(nsError.domain) code=\(nsError.code)"
            )
            self.lastError = "画中画启动失败：\(error.localizedDescription)"
            self.stop()
        }
    }
}
#endif
