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
    enum PiPPreparationState: String, Sendable {
        case idle
        case attachingVisibleSource
        case synthesizingVideo
        case waitingForMedia
        case prepared
        case starting
        case active
        case failed

        var localizedDescription: String {
            switch self {
            case .idle: "等待任务启动"
            case .attachingVisibleSource: "正在挂载画中画预览"
            case .synthesizingVideo: "正在生成任务进度视频"
            case .waitingForMedia: "正在等待 AVKit 就绪"
            case .prepared: "画中画已准备"
            case .starting: "正在启动画中画"
            case .active: "正在显示"
            case .failed: "画中画准备失败"
            }
        }
    }
    struct GuidanceHint: Sendable {
        var label: String
        var instruction: String
        var point: CGPoint
    }

    @Published private(set) var isPiPActive = false
    @Published private(set) var isPreparingPiP = false
    @Published private(set) var isPiPPrepared = false
    @Published private(set) var lastError: String?
    @Published private(set) var preparationState: PiPPreparationState = .idle
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
    /// PiP starts. Keep a non-trivial source host attached behind the app's
    /// root content; it must never cover Floe controls in the foreground.
    private var inlinePreview: UIView?
    private enum StopOrigin: String {
        case none
        case foregroundRetraction
        case controllerReplacement
        case taskBatchEnded
    }
    private var pendingStopOrigin: StopOrigin = .none
    /// Scene transitions can request PiP while the progress asset is still
    /// being encoded. Remember that request instead of launching a second
    /// preparation task that tears down the first controller.
    private var startWhenPrepared = false
    /// AVKit can reject the first request while the scene is between
    /// foreground-inactive and background. Keep the prepared source alive and
    /// retry once after that transition instead of rebuilding without a key
    /// window (which can never succeed).
    private var startAttemptCount = 0
    private var startRetryTask: Task<Void, Never>?

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
        stopPiPInternal(origin: .controllerReplacement)
        startAttemptCount = 0
        startWhenPrepared = startImmediately
        isPreparingPiP = true
        preparationState = .attachingVisibleSource
        lastError = nil
        FloeLogger(category: .app).info(
            "pictureInPicturePrepareStarted generation=\(generation)"
        )
        defer { isPreparingPiP = false }
        // Build the visual PiP source without owning the device audio session.
        // The session is activated only at the actual PiP start boundary so a
        // foreground agent run never pauses Music, podcasts or another app.
        guard prepareInlinePreview() else {
            preparationState = .failed
            lastError = "画中画需要可见的应用窗口"
            FloeLogger(category: .app).warning(
                "pictureInPicturePrepareFailed stage=inlinePreviewContainer generation=\(generation)"
            )
            deactivateAudioSession()
            return
        }
        preparationState = .synthesizingVideo
        guard let assetURL = await synthesizeProgressVideo(
            title: title,
            progress: initialProgress,
            guidanceImage: nil,
            guidanceHints: []
        ) else {
            preparationState = .failed
            lastError = "无法创建画中画进度视频"
            FloeLogger(category: .app).error(
                "pictureInPicturePrepareFailed stage=videoSynthesis generation=\(generation)"
            )
            removeInlinePreview()
            deactivateAudioSession()
            return
        }
        guard !Task.isCancelled, generation == startGeneration else {
            try? FileManager.default.removeItem(at: assetURL)
            deactivateAudioSession()
            return
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            preparationState = .failed
            lastError = "当前设备不支持画中画"
            FloeLogger(category: .app).warning(
                "pictureInPicturePrepareFailed stage=unsupported generation=\(generation)"
            )
            try? FileManager.default.removeItem(at: assetURL)
            deactivateAudioSession()
            return
        }
        let item = AVPlayerItem(url: assetURL)
        // AVPlayerLooper owns the queue population. Initializing the queue
        // with the same template item and then handing that item to the
        // looper can leave AVKit attached to an exhausted/black first item on
        // some iPadOS builds.
        let queue = AVQueuePlayer()
        queue.automaticallyWaitsToMinimizeStalling = false
        let layer = AVPlayerLayer(player: queue)
        layer.videoGravity = .resizeAspect
        guard attachInlinePreview(layer: layer) else {
            preparationState = .failed
            lastError = "画中画需要应用处于前台并显示预览"
            FloeLogger(category: .app).warning(
                "pictureInPicturePrepareFailed stage=inlinePreview generation=\(generation)"
            )
            try? FileManager.default.removeItem(at: assetURL)
            deactivateAudioSession()
            return
        }
        guard let controller = AVPictureInPictureController(playerLayer: layer) else {
            preparationState = .failed
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
        // AVPlayerLooper enqueues a copy of its template item. The template
        // itself never becomes the queue's active item and can remain
        // `.unknown` forever; Build 23 waited on that inactive object for ten
        // seconds and then discarded an otherwise valid PiP controller.
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        pipController = controller
        await queue.seek(to: .zero)
        queue.play()
        preparationState = .waitingForMedia
        // AVKit readiness is asynchronous and varies by device. Starting at
        // a fixed delay silently fails on slower iPads, so wait for the real
        // capability signal with a bounded timeout.
        let deadline = Date().addingTimeInterval(10)
        var playbackItem = queue.currentItem
        while (playbackItem == nil
                || playbackItem?.status == .unknown
                || !controller.isPictureInPicturePossible)
                && Date() < deadline {
            guard generation == startGeneration, !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(100))
            playbackItem = queue.currentItem
        }
        guard generation == startGeneration else { return }
        guard let playbackItem,
              playbackItem.status == .readyToPlay,
              controller.isPictureInPicturePossible else {
            preparationState = .failed
            lastError = "画中画尚未就绪，请保持应用在前台后重试"
            let itemError = playbackItem?.error as NSError?
            FloeLogger(category: .app).warning(
                "pictureInPicturePrepareFailed stage=readinessTimeout generation=\(generation) itemStatus=\(String(describing: playbackItem?.status)) possible=\(controller.isPictureInPicturePossible) errorDomain=\(itemError?.domain ?? "none") errorCode=\(itemError?.code ?? 0)"
            )
            stopPiPInternal(origin: .controllerReplacement)
            return
        }
        isPiPPrepared = true
        preparationState = .prepared
        guard startWhenPrepared else {
            FloeLogger(category: .app).info(
                "pictureInPicturePrepared generation=\(generation)"
            )
            return
        }
        startPreparedPictureInPicture()
    }

    func startPreparedPictureInPicture() {
        startWhenPrepared = true
        if isPreparingPiP, pipController == nil {
            FloeLogger(category: .app).info(
                "pictureInPictureStartDeferred generation=\(startGeneration)"
            )
            return
        }
        guard let controller = pipController,
              controller.isPictureInPicturePossible,
              !controller.isPictureInPictureActive else { return }
        configureAudioSession()
        preparationState = .starting
        FloeLogger(category: .app).info(
            "pictureInPictureStartRequested generation=\(startGeneration) attempt=\(startAttemptCount + 1) playerStatus=\(String(describing: player?.timeControlStatus)) itemStatus=\(String(describing: player?.currentItem?.status))"
        )
        startAttemptCount += 1
        controller.startPictureInPicture()
    }

    /// Returning to Floe retracts the floating surface without destroying
    /// the prepared player. Leaving the app again can therefore resume PiP
    /// while the same task batch remains active.
    func retractForForeground() {
        guard let controller = pipController, controller.isPictureInPictureActive else { return }
        pendingStopOrigin = .foregroundRetraction
        controller.stopPictureInPicture()
        FloeLogger(category: .app).info("pictureInPictureRetractedForForeground")
    }

    /// Updates the progress text and re-renders the looping video so the PiP
    /// actually reflects the latest state instead of a frozen first frame.
    func update(progress: String) {
        update(title: currentTitle, progress: progress)
    }

    func update(title: String, progress: String) {
        guard title != currentTitle || progress != currentProgress else { return }
        currentTitle = title
        currentProgress = progress
        let generation = startGeneration
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            // Collapse rapid run-state publications into one visual update.
            // Replacing AVPlayerItem on every database refresh made the PiP
            // transport overlay flash even when the text had not settled yet.
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            guard let self, generation == self.startGeneration else { return }
            // Never empty or replace the AVQueuePlayer while PiP owns it.
            // AVKit treats that short empty queue as end-of-playback and
            // closes the floating window at ordinary run-stage boundaries.
            guard !self.isPiPActive else {
                FloeLogger(category: .app).debug(
                    "pictureInPictureVisualRefreshDeferred reason=activePlayback generation=\(generation)"
                )
                return
            }
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
        guard !isPiPActive, let player else { return }
        guard let assetURL = await synthesizeProgressVideo(
            title: title,
            progress: progress,
            guidanceImage: guidanceImage,
            guidanceHints: guidanceHints
        ) else { return }
        guard !Task.isCancelled, generation == startGeneration, !isPiPActive else {
            try? FileManager.default.removeItem(at: assetURL)
            return
        }
        let item = AVPlayerItem(url: assetURL)
        looper?.disableLooping()
        for queuedItem in player.items() {
            player.remove(queuedItem)
        }
        looper = AVPlayerLooper(player: player, templateItem: item)
        await player.seek(to: .zero)
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
        stopPiPInternal(origin: .taskBatchEnded)
    }

    private func stopPiPInternal(origin: StopOrigin) {
        refreshTask?.cancel()
        refreshTask = nil
        startRetryTask?.cancel()
        startRetryTask = nil
        pendingStopOrigin = origin
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
        preparationState = .idle
        pendingStopOrigin = .none
        startWhenPrepared = false
        startAttemptCount = 0
        deactivateAudioSession()
    }

    /// Releases playback state after the user or system closes PiP without
    /// asking AVKit to stop the already-stopped controller a second time.
    private func handlePiPStopped(controllerID: ObjectIdentifier) {
        guard let currentController = pipController,
              ObjectIdentifier(currentController) == controllerID else { return }
        if pendingStopOrigin == .foregroundRetraction {
            pendingStopOrigin = .none
            isPiPActive = false
            preparationState = .prepared
            deactivateAudioSession()
            FloeLogger(category: .app).info("pictureInPictureRetractionCompleted")
            let generation = startGeneration
            refreshTask?.cancel()
            refreshTask = Task { @MainActor [weak self] in
                guard let self, generation == self.startGeneration else { return }
                await self.refreshVideo(
                    title: self.currentTitle,
                    progress: self.currentProgress,
                    guidanceImage: self.guidanceImage,
                    guidanceHints: self.guidanceHints,
                    generation: generation
                )
            }
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
        preparationState = .idle
        pendingStopOrigin = .none
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

    private func prepareInlinePreview() -> Bool {
        if inlinePreview?.window != nil { return true }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: {
                $0.activationState == .foregroundActive
                    || $0.activationState == .foregroundInactive
            }),
              let window = scene.windows.first(where: \.isKeyWindow)
                ?? scene.windows.first(where: { !$0.isHidden }) else { return false }
        removeInlinePreview()
        // AVKit requires the inline source to be genuinely visible. Inserting
        // it behind an opaque root view leaves isPictureInPicturePossible
        // false on iPadOS even though the layer has a window. Present the real
        // task-progress source as a small, non-interactive preview instead.
        let size = CGSize(width: 160, height: 90)
        let view = UIView(frame: CGRect(
            x: max(window.safeAreaInsets.left, window.bounds.width - window.safeAreaInsets.right - size.width - 12),
            y: max(window.safeAreaInsets.top + 12, 12),
            width: size.width,
            height: size.height
        ))
        view.backgroundColor = UIColor(red: 0.035, green: 0.043, blue: 0.065, alpha: 1)
        // Keep the source fully rendered. Reduced alpha can make AVKit reject
        // the source as non-visible. It is inserted behind the app's root
        // content, so no internal preview tile covers foreground controls.
        view.alpha = 1
        view.layer.masksToBounds = true
        view.layer.cornerRadius = 12
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor
        view.layer.borderWidth = 1
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.28
        view.layer.shadowRadius = 8
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        window.addSubview(view)
        inlinePreview = view
        return true
    }

    private func attachInlinePreview(layer: CALayer) -> Bool {
        guard prepareInlinePreview(), let inlinePreview else { return false }
        inlinePreview.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer.frame = inlinePreview.bounds
        inlinePreview.layer.addSublayer(layer)
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
            UIColor(red: 0.035, green: 0.043, blue: 0.065, alpha: 1).setFill()
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
            // The progress-only surface remains useful when no screen guidance
            // is active: identify the app, show the surfaced task and its real
            // stage, and turn the coordinator's percentage into a glanceable
            // bar. Multi-task batches include their carousel position in the
            // stage string (for example "2/3 · 正在调用工具 · 45%").
            let card = CGRect(x: 24, y: 20, width: size.width - 48, height: size.height - 40)
            UIColor(red: 0.075, green: 0.09, blue: 0.13, alpha: 1).setFill()
            UIBezierPath(roundedRect: card, cornerRadius: 28).fill()

            let mark = CGRect(x: 52, y: 48, width: 42, height: 42)
            UIColor.systemBlue.setFill()
            UIBezierPath(roundedRect: mark, cornerRadius: 12).fill()
            ("F" as NSString).draw(
                in: mark.insetBy(dx: 11, dy: 5),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 24, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
            )
            ("Floe Agent" as NSString).draw(
                at: CGPoint(x: 108, y: 54),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 23, weight: .semibold),
                    .foregroundColor: UIColor.white
                ]
            )
            let liveLabel = "任务持续运行中" as NSString
            liveLabel.draw(
                at: CGPoint(x: 440, y: 58),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 16, weight: .medium),
                    .foregroundColor: UIColor.systemGreen
                ]
            )

            (title as NSString).draw(
                in: CGRect(x: 52, y: 126, width: 536, height: 48),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 28, weight: .bold),
                    .foregroundColor: UIColor.white
                ]
            )
            (progress as NSString).draw(
                in: CGRect(x: 52, y: 184, width: 536, height: 38),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 21, weight: .medium),
                    .foregroundColor: UIColor(red: 0.72, green: 0.78, blue: 0.88, alpha: 1)
                ]
            )

            let track = CGRect(x: 52, y: 252, width: 536, height: 12)
            UIColor.white.withAlphaComponent(0.12).setFill()
            UIBezierPath(roundedRect: track, cornerRadius: 6).fill()
            let percent = Self.progressPercent(in: progress)
            let fillWidth = max(16, track.width * CGFloat(percent) / 100)
            UIColor.systemBlue.setFill()
            UIBezierPath(
                roundedRect: CGRect(x: track.minX, y: track.minY, width: fillWidth, height: track.height),
                cornerRadius: 6
            ).fill()
            let detail = percent > 0 ? "进度 \(percent)%" : "正在同步最新状态"
            (detail as NSString).draw(
                at: CGPoint(x: 52, y: 282),
                withAttributes: [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 17, weight: .medium),
                    .foregroundColor: UIColor.lightGray
                ]
            )
        }
    }

    private static func progressPercent(in text: String) -> Int {
        guard let expression = try? NSRegularExpression(pattern: #"(\d{1,3})\s*%"#),
              let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
              ),
              let range = Range(match.range(at: 1), in: text),
              let value = Int(text[range]) else { return 0 }
        return min(100, max(0, value))
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
        let controllerID = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor in
            guard self.pipController.map(ObjectIdentifier.init) == controllerID else {
                FloeLogger(category: .app).debug(
                    "pictureInPictureDidStartIgnored reason=staleController"
                )
                return
            }
            self.isPiPActive = true
            self.preparationState = .active
            self.isPreparingPiP = false
            self.startRetryTask?.cancel()
            self.startRetryTask = nil
            self.startAttemptCount = 0
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
        let controllerID = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor in
            let nsError = error as NSError
            FloeLogger(category: .app).error(
                "pictureInPictureStartFailed domain=\(nsError.domain) code=\(nsError.code) attempt=\(self.startAttemptCount) description=\(nsError.localizedDescription)"
            )
            self.lastError = "画中画启动失败：\(error.localizedDescription)"
            self.preparationState = .failed
            guard self.startWhenPrepared,
                  self.startAttemptCount < 2,
                  self.pipController.map(ObjectIdentifier.init) == controllerID else {
                // Preserve the valid foreground-prepared controller. A later
                // app departure can try it again without attempting to attach
                // a new source view while already backgrounded.
                self.isPiPPrepared = self.pipController != nil
                self.deactivateAudioSession()
                return
            }
            let generation = self.startGeneration
            self.startRetryTask?.cancel()
            self.startRetryTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled,
                      generation == self.startGeneration else { return }
                self.startPreparedPictureInPicture()
            }
        }
    }
}

#endif
