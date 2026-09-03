// FloeApp — Picture-in-Picture background keep-alive for agent runs.
//
// A Picture-in-Picture surface that shows the current run's progress. Its
// inline source lives in Floe's existing task toolbar: AVKit may enter PiP when
// the user leaves the app, or the user can start/stop it from that toolbar.

#if canImport(UIKit)
import Foundation
import UIKit
import SwiftUI
import AVKit
import AVFoundation
import FloeCore

/// The AVKit presenting layer must belong to a live UIKit hierarchy. Keeping
/// it as this view's backing layer gives PiP a real inline source without ever
/// adding a preview above Floe's window.
private final class BackgroundPiPSourceHostView: UIView {
    var attachmentDidChange: (() -> Void)?

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true
        sampleBufferDisplayLayer.videoGravity = .resizeAspectFill
        sampleBufferDisplayLayer.backgroundColor = UIColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true
        sampleBufferDisplayLayer.videoGravity = .resizeAspectFill
        sampleBufferDisplayLayer.backgroundColor = UIColor.clear.cgColor
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        attachmentDidChange?()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachmentDidChange?()
    }
}

@MainActor
final class BackgroundVideoService: NSObject, ObservableObject {
    enum PiPPreparationState: String, Sendable {
        case idle
        case renderingContent
        case waitingForMedia
        case prepared
        case starting
        case active
        case failed

        var localizedDescription: String {
            switch self {
            case .idle: "等待任务启动"
            case .renderingContent: "正在准备画中画内容"
            case .waitingForMedia: "正在等待 AVKit 就绪"
            case .prepared: "画中画已就绪"
            case .starting: "正在启动画中画"
            case .active: "正在显示"
            case .failed: "画中画准备失败"
            }
        }

        var manualAction: PiPManualControlAction {
            switch self {
            case .prepared: .start
            case .active: .stop
            case .failed: .retryPreparation
            case .idle, .renderingContent, .waitingForMedia, .starting: .none
            }
        }

        var offersManualControl: Bool {
            switch self {
            case .prepared, .starting, .active, .failed: true
            case .idle, .renderingContent, .waitingForMedia: false
            }
        }

    }

    enum PiPManualControlAction: Sendable, Equatable {
        case none
        case start
        case stop
        case retryPreparation
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
    @Published private(set) var hasRunContext = false
    /// Called only when AVKit/system closes PiP while Floe still owns the
    /// controller. Programmatic run teardown clears ownership first.
    var onUserStopped: (() -> Void)?

    private var pipController: AVPictureInPictureController?
    private var sampleBufferLayer: AVSampleBufferDisplayLayer?
    private var activeSourceHostView: BackgroundPiPSourceHostView?
    private let sourceHostViews = NSHashTable<BackgroundPiPSourceHostView>.weakObjects()
    private var possibleObservation: NSKeyValueObservation?
    private var readyForDisplayObservation: NSKeyValueObservation?
    private struct RetiringPiPSource {
        let controller: AVPictureInPictureController
        let layer: AVSampleBufferDisplayLayer?
        let hostView: BackgroundPiPSourceHostView?
    }
    private var retiringPiPSources: [ObjectIdentifier: RetiringPiPSource] = [:]
    private var retiringPiPCleanupTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var currentTitle = ""
    private var currentProgress = ""
    private var guidanceImage: UIImage?
    private var guidanceHints: [GuidanceHint] = []
    private var refreshTask: Task<Void, Never>?
    private var startGeneration: UInt64 = 0
    private enum StopOrigin: String {
        case none
        case foregroundRetraction
        case manualControl
        case controllerReplacement
        case taskBatchEnded
    }
    private var pendingStopOrigin: StopOrigin = .none
    private var manualStartAttemptCount = 0
    private var ownsAudioSessionActivation = false
    private var preparationTask: Task<Void, Never>?
    private var startTimeoutTask: Task<Void, Never>?
    private var automaticallyStartsFromInline = false

    private var resolvedManualAction: PiPManualControlAction {
        if preparationState == .idle, hasRunContext {
            return .start
        }
        return preparationState.manualAction
    }

    var shouldOfferManualControl: Bool {
        hasRunContext
    }

    var canPerformManualControl: Bool {
        resolvedManualAction != .none
    }

    var manualControlTitle: String {
        switch resolvedManualAction {
        case .start: "启动画中画"
        case .stop: "关闭画中画"
        case .retryPreparation: "重试画中画准备"
        case .none: preparationState.localizedDescription
        }
    }

    var manualControlSystemImage: String {
        switch resolvedManualAction {
        case .start: "pip.enter"
        case .stop: "pip.exit"
        case .retryPreparation: "arrow.clockwise"
        case .none: "pip"
        }
    }

    /// Records an active run without creating an independent foreground
    /// surface. PiP mode prepares through the inline toolbar host so AVKit can
    /// honor the user's Home/app-switch gesture; other modes remain manual.
    func setRunContext(
        title: String,
        progress: String,
        automaticallyStartsFromInline: Bool = false
    ) {
        currentTitle = title
        currentProgress = progress
        self.automaticallyStartsFromInline = automaticallyStartsFromInline
        pipController?.canStartPictureInPictureAutomaticallyFromInline =
            automaticallyStartsFromInline
        if !hasRunContext {
            hasRunContext = true
        }
        if automaticallyStartsFromInline, preparationState == .prepared {
            configureAudioSession()
        } else if !automaticallyStartsFromInline,
                  !isPiPActive,
                  preparationState != .starting {
            deactivateAudioSession()
        }
        scheduleAutomaticPreparationIfNeeded()
    }

    fileprivate func registerSourceHost(_ hostView: BackgroundPiPSourceHostView) {
        sourceHostViews.add(hostView)
        scheduleAutomaticPreparationIfNeeded()
    }

    fileprivate func unregisterSourceHost(_ hostView: BackgroundPiPSourceHostView) {
        sourceHostViews.remove(hostView)
        let lostPendingSource = activeSourceHostView == nil
            && isPreparingPiP
            && availableSourceHost() == nil
        guard (activeSourceHostView === hostView || lostPendingSource),
              !isPiPActive,
              preparationState != .starting else { return }
        // A prepared controller cannot be moved to another backing layer.
        // Tear it down and invalidate any readiness wait; the newly visible
        // scene's host will prepare a fresh controller.
        preparationTask?.cancel()
        preparationTask = nil
        startGeneration &+= 1
        stopPiPInternal(origin: .controllerReplacement)
    }

    private func scheduleAutomaticPreparationIfNeeded() {
        guard hasRunContext,
              automaticallyStartsFromInline,
              preparationState == .idle,
              !isPreparingPiP,
              availableSourceHost() != nil else { return }
        let title = currentTitle
        let progress = currentProgress
        isPreparingPiP = true
        preparationState = .renderingContent
        preparationTask?.cancel()
        preparationTask = Task { @MainActor [weak self] in
            await self?.prepareInlineSource(
                title: title,
                initialProgress: progress,
                startAfterPreparation: false
            )
        }
    }

    /// Prepares a real inline sample-buffer source. Manual preparation starts
    /// immediately after readiness; automatic preparation only arms AVKit for
    /// the user's later Home/app-switch gesture.
    private func prepareInlineSource(
        title: String,
        initialProgress: String,
        startAfterPreparation: Bool
    ) async {
        guard !Task.isCancelled, hasRunContext else { return }
        startGeneration &+= 1
        let generation = startGeneration
        currentTitle = title
        currentProgress = initialProgress
        guidanceImage = nil
        guidanceHints = []
        stopPiPInternal(origin: .controllerReplacement)
        manualStartAttemptCount = 0
        isPreparingPiP = true
        preparationState = .renderingContent
        lastError = nil
        FloeLogger(category: .app).info(
            "pictureInPicturePrepareStarted generation=\(generation)"
        )
        // A later run can supersede this asynchronous preparation while AVKit
        // is publishing readiness. Never let the older task clear the newer
        // task's in-progress state when it eventually resumes.
        defer {
            if generation == startGeneration {
                isPreparingPiP = false
            }
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            preparationState = .failed
            lastError = "当前设备不支持画中画"
            FloeLogger(category: .app).warning(
                "pictureInPicturePrepareFailed stage=unsupported generation=\(generation)"
            )
            return
        }
        // AVKit requires a playback-capable audio category before the PiP
        // controller is created and `isPictureInPicturePossible` is observed.
        // Setting the category does not activate or steal the session; actual
        // activation remains paired with an explicit user start below.
        configureAudioSessionCategory()

        guard let hostView = availableSourceHost() else {
            preparationState = .failed
            lastError = "画中画按钮尚未连接到当前窗口，请保持此页面可见后重试"
            FloeLogger(category: .app).warning(
                "pictureInPicturePrepareFailed stage=inlineSourceHost generation=\(generation)"
            )
            return
        }

        // The layer is the backing layer of the small, existing toolbar
        // control. It is never installed directly on UIWindow and therefore
        // cannot become the old top-right floating preview.
        let layer = hostView.sampleBufferDisplayLayer
        layer.sampleBufferRenderer.flush()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor(red: 0.035, green: 0.043, blue: 0.065, alpha: 1).cgColor
        guard enqueueProgressFrame(
            on: layer,
            title: title,
            progress: initialProgress,
            guidanceImage: nil,
            guidanceHints: []
        ) else {
            preparationState = .failed
            lastError = "无法创建画中画进度画面"
            FloeLogger(category: .app).error(
                "pictureInPicturePrepareFailed stage=frameRender generation=\(generation)"
            )
            return
        }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: layer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = automaticallyStartsFromInline
        controller.requiresLinearPlayback = true
        sampleBufferLayer = layer
        activeSourceHostView = hostView
        pipController = controller
        installReadinessObservers(controller: controller, layer: layer, generation: generation)
        preparationState = .waitingForMedia

        // AVKit publishes possibility asynchronously. Waiting here means the
        // toolbar button calls start synchronously from the eventual user tap,
        // rather than storing a tap and starting later from a lifecycle event.
        let deadline = Date().addingTimeInterval(10)
        while (!controller.isPictureInPicturePossible || !layer.isReadyForDisplay)
            && Date() < deadline {
            guard generation == startGeneration, !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard generation == startGeneration else { return }
        guard controller.isPictureInPicturePossible, layer.isReadyForDisplay else {
            preparationState = .failed
            lastError = "AVKit 尚未允许画中画，请稍后从任务工具栏重试"
            let rendererError = layer.sampleBufferRenderer.error as NSError?
            FloeLogger(category: .app).warning(
                "pictureInPicturePrepareFailed stage=readinessTimeout generation=\(generation) possible=\(controller.isPictureInPicturePossible) readyForDisplay=\(layer.isReadyForDisplay) renderStatus=\(String(describing: layer.sampleBufferRenderer.status)) errorDomain=\(rendererError?.domain ?? "none") errorCode=\(rendererError?.code ?? 0)"
            )
            stopPiPInternal(origin: .controllerReplacement)
            preparationState = .failed
            lastError = "AVKit 尚未允许画中画，请稍后从任务工具栏重试"
            return
        }
        isPiPPrepared = true
        preparationState = .prepared
        lastError = nil
        FloeLogger(category: .app).info(
            "pictureInPicturePrepared generation=\(generation) source=inlineSampleBuffer automaticFromInline=\(automaticallyStartsFromInline) manualStartRequested=\(startAfterPreparation)"
        )
        if automaticallyStartsFromInline {
            // PiP background playback needs an active playback session before
            // the system handles the app-switch transition.
            configureAudioSession()
        }
        if startAfterPreparation {
            startFromUserAction()
        }
    }

    /// Handles the visible PiP toolbar control. This is the only production
    /// entry point that may call AVKit's start method.
    func performManualControl() {
        switch resolvedManualAction {
        case .start:
            if preparationState == .prepared {
                startFromUserAction()
            } else {
                let title = currentTitle
                let progress = currentProgress
                isPreparingPiP = true
                preparationState = .renderingContent
                preparationTask?.cancel()
                preparationTask = Task { @MainActor [weak self] in
                    await self?.prepareInlineSource(
                        title: title,
                        initialProgress: progress,
                        startAfterPreparation: true
                    )
                }
            }
        case .stop:
            stopFromUserAction()
        case .retryPreparation:
            let title = currentTitle
            let progress = currentProgress
            isPreparingPiP = true
            preparationState = .renderingContent
            preparationTask?.cancel()
            preparationTask = Task { @MainActor [weak self] in
                await self?.prepareInlineSource(
                    title: title,
                    initialProgress: progress,
                    startAfterPreparation: true
                )
            }
        case .none:
            FloeLogger(category: .app).info(
                "pictureInPictureManualControlIgnored state=\(preparationState.rawValue)"
            )
        }
    }

    private func startFromUserAction() {
        guard preparationState == .prepared else { return }
        guard let controller = pipController,
              let sampleBufferLayer,
              let activeSourceHostView,
              activeSourceHostView.window != nil,
              activeSourceHostView.sampleBufferDisplayLayer === sampleBufferLayer else {
            stopPiPInternal(origin: .controllerReplacement)
            preparationState = .failed
            lastError = "画中画内容已失效，请从工具栏重试"
            FloeLogger(category: .app).warning(
                "pictureInPictureManualStartUnavailable reason=missingPreparedSource generation=\(startGeneration)"
            )
            return
        }
        let renderer = sampleBufferLayer.sampleBufferRenderer
        guard sampleBufferLayer.isReadyForDisplay,
              renderer.status != .failed,
              !renderer.requiresFlushToResumeDecoding else {
            let rendererError = renderer.error as NSError?
            FloeLogger(category: .app).warning(
                "pictureInPictureManualStartUnavailable reason=stalePreparedSource generation=\(startGeneration) readyForDisplay=\(sampleBufferLayer.isReadyForDisplay) renderStatus=\(String(describing: renderer.status)) errorDomain=\(rendererError?.domain ?? "none") errorCode=\(rendererError?.code ?? 0)"
            )
            stopPiPInternal(origin: .controllerReplacement)
            preparationState = .failed
            lastError = "画中画内容需要重新准备，请从工具栏重试"
            return
        }
        guard controller.isPictureInPicturePossible,
              !controller.isPictureInPictureActive else {
            lastError = "当前系统暂时不能启动画中画，请稍后重试"
            FloeLogger(category: .app).warning(
                "pictureInPictureManualStartUnavailable generation=\(startGeneration)"
            )
            return
        }
        configureAudioSession()
        preparationState = .starting
        manualStartAttemptCount += 1
        FloeLogger(category: .app).info(
            "pictureInPictureStartRequested generation=\(startGeneration) source=userControl attempt=\(manualStartAttemptCount)"
        )
        controller.startPictureInPicture()
        let generation = startGeneration
        startTimeoutTask?.cancel()
        startTimeoutTask = Task { @MainActor [weak self, weak controller] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled,
                  let self,
                  generation == self.startGeneration,
                  self.preparationState == .starting,
                  controller?.isPictureInPictureActive != true else { return }
            self.isPreparingPiP = false
            self.isPiPActive = false
            self.isPiPPrepared = true
            self.preparationState = .prepared
            self.lastError = "系统没有完成画中画启动，请再次点击重试"
            self.deactivateAudioSession()
            FloeLogger(category: .app).warning(
                "pictureInPictureStartTimedOut generation=\(generation)"
            )
        }
    }

    private func stopFromUserAction() {
        guard let controller = pipController, controller.isPictureInPictureActive else { return }
        pendingStopOrigin = .manualControl
        controller.stopPictureInPicture()
        FloeLogger(category: .app).info("pictureInPictureStopRequested source=userControl")
    }

    /// Returning to Floe retracts the floating surface without destroying the
    /// prepared content source. Starting it again still requires another tap.
    func retractForForeground() {
        guard let controller = pipController, controller.isPictureInPictureActive else { return }
        pendingStopOrigin = .foregroundRetraction
        controller.stopPictureInPicture()
        FloeLogger(category: .app).info("pictureInPictureRetractedForForeground")
    }

    /// Updates the progress text and replaces the sample-buffer frame so an
    /// active PiP reflects the latest state instead of a frozen first frame.
    func update(progress: String) {
        update(title: currentTitle, progress: progress)
    }

    func update(title: String, progress: String) {
        if !hasRunContext {
            hasRunContext = true
        }
        guard title != currentTitle || progress != currentProgress else { return }
        currentTitle = title
        currentProgress = progress
        let generation = startGeneration
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            // Collapse rapid run-state publications into one visual update.
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            guard let self, generation == self.startGeneration else { return }
            self.refreshFrame(
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
            self.refreshFrame(
                title: self.currentTitle,
                progress: self.currentProgress,
                guidanceImage: image,
                guidanceHints: hints,
                generation: generation
            )
        }
    }

    private func refreshFrame(
        title: String,
        progress: String,
        guidanceImage: UIImage?,
        guidanceHints: [GuidanceHint],
        generation: UInt64
    ) {
        guard generation == startGeneration,
              let sampleBufferLayer,
              enqueueProgressFrame(
                on: sampleBufferLayer,
                title: title,
                progress: progress,
                guidanceImage: guidanceImage,
                guidanceHints: guidanceHints
              ) else { return }
        FloeLogger(category: .app).debug(
            "pictureInPictureFrameUpdated generation=\(generation) active=\(isPiPActive)"
        )
    }

    func stop() {
        preparationTask?.cancel()
        preparationTask = nil
        refreshTask?.cancel()
        refreshTask = nil
        startGeneration &+= 1
        stopPiPInternal(origin: .taskBatchEnded)
        currentTitle = ""
        currentProgress = ""
        hasRunContext = false
        automaticallyStartsFromInline = false
    }

    private func stopPiPInternal(origin: StopOrigin) {
        refreshTask?.cancel()
        refreshTask = nil
        startTimeoutTask?.cancel()
        startTimeoutTask = nil
        possibleObservation?.invalidate()
        possibleObservation = nil
        readyForDisplayObservation?.invalidate()
        readyForDisplayObservation = nil
        pendingStopOrigin = origin
        if let pipController {
            let controllerID = ObjectIdentifier(pipController)
            let needsDeferredSourceRelease = pipController.isPictureInPictureActive
                || preparationState == .starting
            if needsDeferredSourceRelease {
                // AVKit still renders from this source during its stop
                // animation. Keep both objects alive until didStop (with a
                // bounded fallback in case the callback is never delivered).
                retiringPiPSources[controllerID] = RetiringPiPSource(
                    controller: pipController,
                    layer: sampleBufferLayer,
                    hostView: activeSourceHostView
                )
                retiringPiPCleanupTasks[controllerID]?.cancel()
                retiringPiPCleanupTasks[controllerID] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.releaseRetiringPiPSource(controllerID: controllerID)
                }
            }
            pipController.stopPictureInPicture()
            if !needsDeferredSourceRelease {
                sampleBufferLayer?.sampleBufferRenderer.flush()
            }
        } else {
            sampleBufferLayer?.sampleBufferRenderer.flush()
        }
        pipController = nil
        sampleBufferLayer = nil
        activeSourceHostView = nil
        guidanceImage = nil
        guidanceHints = []
        isPiPActive = false
        isPreparingPiP = false
        isPiPPrepared = false
        preparationState = .idle
        pendingStopOrigin = .none
        manualStartAttemptCount = 0
        deactivateAudioSession()
    }

    @discardableResult
    private func releaseRetiringPiPSource(controllerID: ObjectIdentifier) -> Bool {
        retiringPiPCleanupTasks.removeValue(forKey: controllerID)?.cancel()
        guard let source = retiringPiPSources.removeValue(forKey: controllerID) else {
            return false
        }
        source.layer?.sampleBufferRenderer.flush()
        FloeLogger(category: .app).debug(
            "pictureInPictureRetiringSourceReleased controller=completedStop"
        )
        return true
    }

    /// Releases playback state after the user or system closes PiP without
    /// asking AVKit to stop the already-stopped controller a second time.
    private func handlePiPStopped(controllerID: ObjectIdentifier) {
        guard let currentController = pipController,
              ObjectIdentifier(currentController) == controllerID else { return }
        if pendingStopOrigin == .foregroundRetraction
            || pendingStopOrigin == .manualControl {
            startTimeoutTask?.cancel()
            startTimeoutTask = nil
            possibleObservation?.invalidate()
            possibleObservation = nil
            readyForDisplayObservation?.invalidate()
            readyForDisplayObservation = nil
            pendingStopOrigin = .none
            isPiPActive = false
            isPiPPrepared = false
            pipController = nil
            sampleBufferLayer?.sampleBufferRenderer.flush()
            sampleBufferLayer = nil
            activeSourceHostView = nil
            preparationState = .idle
            deactivateAudioSession()
            FloeLogger(category: .app).info("pictureInPictureIntentionalStopCompleted")
            scheduleAutomaticPreparationIfNeeded()
            return
        }
        refreshTask?.cancel()
        refreshTask = nil
        startGeneration &+= 1
        pipController = nil
        possibleObservation?.invalidate()
        possibleObservation = nil
        readyForDisplayObservation?.invalidate()
        readyForDisplayObservation = nil
        sampleBufferLayer?.sampleBufferRenderer.flush()
        sampleBufferLayer = nil
        activeSourceHostView = nil
        guidanceImage = nil
        guidanceHints = []
        isPiPActive = false
        isPiPPrepared = false
        preparationState = .idle
        pendingStopOrigin = .none
        automaticallyStartsFromInline = false
        deactivateAudioSession()
        onUserStopped?()
    }

    private func availableSourceHost() -> BackgroundPiPSourceHostView? {
        sourceHostViews.allObjects.first { hostView in
            guard let scene = hostView.window?.windowScene else { return false }
            return !hostView.isHidden
                && hostView.alpha > 0.01
                && hostView.bounds.width >= 16
                && hostView.bounds.height >= 9
                && (scene.activationState == .foregroundActive
                    || scene.activationState == .foregroundInactive)
        }
    }

    /// AVKit readiness is KVO-backed. Keep the bounded wait as the control
    /// flow, but log every real transition so physical-device reports can
    /// distinguish a missing inline source from a renderer or system refusal.
    private func installReadinessObservers(
        controller: AVPictureInPictureController,
        layer: AVSampleBufferDisplayLayer,
        generation: UInt64
    ) {
        possibleObservation?.invalidate()
        readyForDisplayObservation?.invalidate()
        possibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { _, change in
            // KVO may deliver off the main actor. Log only its Sendable value;
            // owner/generation validation remains in the bounded main-actor
            // readiness loop and delegate callbacks.
            let possible = change.newValue ?? false
            FloeLogger(category: .app).info(
                "pictureInPicturePossibleChanged generation=\(generation) possible=\(possible)"
            )
        }
        readyForDisplayObservation = layer.observe(
            \.isReadyForDisplay,
            options: [.initial, .new]
        ) { _, change in
            let readyForDisplay = change.newValue ?? false
            FloeLogger(category: .app).info(
                "pictureInPictureLayerReadyChanged generation=\(generation) readyForDisplay=\(readyForDisplay)"
            )
        }
    }

    /// Configures the audio session for background playback so the PiP video
    /// keeps the app alive. Without this the app suspends the moment it
    /// backgrounds even while the PiP floats. Failure never breaks the run.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        guard configureAudioSessionCategory() else { return }
        do {
            try session.setActive(true)
            ownsAudioSessionActivation = true
        } catch {
            let nsError = error as NSError
            FloeLogger(category: .app).warning(
                "pictureInPictureAudioSessionActivationFailed domain=\(nsError.domain) code=\(nsError.code)"
            )
        }
    }

    @discardableResult
    private func configureAudioSessionCategory() -> Bool {
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.mixWithOthers]
            )
            return true
        } catch {
            let nsError = error as NSError
            FloeLogger(category: .app).warning(
                "pictureInPictureAudioSessionCategoryFailed domain=\(nsError.domain) code=\(nsError.code)"
            )
            return false
        }
    }

    private func deactivateAudioSession() {
        guard ownsAudioSessionActivation else { return }
        ownsAudioSessionActivation = false
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playback,
              session.mode == .moviePlayback else {
            // Another Floe feature (for example voice input) has taken over
            // the process-wide session. It now owns deactivation as well.
            FloeLogger(category: .app).debug(
                "pictureInPictureAudioSessionRelinquished reason=configurationChanged"
            )
            return
        }
        do {
            try session.setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        } catch {
            let nsError = error as NSError
            FloeLogger(category: .app).warning(
                "pictureInPictureAudioSessionDeactivationFailed domain=\(nsError.domain) code=\(nsError.code)"
            )
        }
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

    private func enqueueProgressFrame(
        on layer: AVSampleBufferDisplayLayer,
        title: String,
        progress: String,
        guidanceImage: UIImage?,
        guidanceHints: [GuidanceHint]
    ) -> Bool {
        let size = CGSize(width: 640, height: 360)
        guard let frame = renderProgressFrame(
            title: title,
            progress: progress,
            guidanceImage: guidanceImage,
            guidanceHints: guidanceHints
        ),
              let cgImage = frame.cgImage,
              let pixelBuffer = Self.pixelBuffer(from: cgImage, size: size),
              let sampleBuffer = Self.videoSampleBuffer(from: pixelBuffer) else { return false }
        let renderer = layer.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)
        return renderer.status != .failed
    }

    /// Creates a display-immediately video sample. No visible in-app view or
    /// artificial playback timebase is needed; AVKit owns the detached layer
    /// only after a user explicitly starts PiP.
    private static func videoSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr,
              let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr,
              let sampleBuffer else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }
        return sampleBuffer
    }

    private static func pixelBuffer(from cgImage: CGImage, size: CGSize) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
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
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        FloeLogger(category: .app).info("pictureInPictureWillStart")
    }

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
            self.startTimeoutTask?.cancel()
            self.startTimeoutTask = nil
            let startSource = self.manualStartAttemptCount > 0
                ? "userControl" : "systemAutomaticInline"
            self.manualStartAttemptCount = 0
            self.lastError = nil
            FloeLogger(category: .app).info(
                "pictureInPictureDidStart source=\(startSource) inlineHostAttached=\(self.activeSourceHostView?.window != nil)"
            )
        }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        FloeLogger(category: .app).info("pictureInPictureWillStop")
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor in
            FloeLogger(category: .app).info("pictureInPictureDidStop")
            if self.releaseRetiringPiPSource(controllerID: controllerID) {
                return
            }
            self.handlePiPStopped(controllerID: controllerID)
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        let controllerID = ObjectIdentifier(pictureInPictureController)
        Task { @MainActor in
            guard self.pipController.map(ObjectIdentifier.init) == controllerID else {
                FloeLogger(category: .app).debug(
                    "pictureInPictureStartFailureIgnored reason=staleController"
                )
                return
            }
            let nsError = error as NSError
            self.startTimeoutTask?.cancel()
            self.startTimeoutTask = nil
            FloeLogger(category: .app).error(
                "pictureInPictureStartFailed domain=\(nsError.domain) code=\(nsError.code) attempt=\(self.manualStartAttemptCount)"
            )
            self.lastError = "画中画启动失败：\(error.localizedDescription)"
            // Keep the content source prepared. A later retry can only come
            // from a new explicit button press.
            self.isPiPActive = false
            self.isPiPPrepared = true
            self.preparationState = .prepared
            self.deactivateAudioSession()
        }
    }
}

extension BackgroundVideoService: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        FloeLogger(category: .app).debug(
            "pictureInPicturePlaybackRequest playing=\(playing) staticProgress=true"
        )
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        FloeLogger(category: .app).debug(
            "pictureInPictureRenderSizeChanged width=\(newRenderSize.width) height=\(newRenderSize.height)"
        )
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

/// A small source surface inside the existing PiP control. It gives AVKit the
/// required inline presenting hierarchy without creating a window-level tile.
private struct BackgroundPiPSourceHost: UIViewRepresentable {
    let videoService: BackgroundVideoService

    final class Coordinator {
        weak var videoService: BackgroundVideoService?

        init(videoService: BackgroundVideoService) {
            self.videoService = videoService
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(videoService: videoService)
    }

    func makeUIView(context: Context) -> BackgroundPiPSourceHostView {
        let view = BackgroundPiPSourceHostView(frame: .zero)
        view.attachmentDidChange = { [weak videoService, weak view] in
            guard let videoService, let view else { return }
            videoService.registerSourceHost(view)
        }
        videoService.registerSourceHost(view)
        return view
    }

    func updateUIView(_ uiView: BackgroundPiPSourceHostView, context: Context) {
        videoService.registerSourceHost(uiView)
    }

    static func dismantleUIView(
        _ uiView: BackgroundPiPSourceHostView,
        coordinator: Coordinator
    ) {
        uiView.attachmentDidChange = nil
        coordinator.videoService?.unregisterSourceHost(uiView)
    }
}

/// Shared run-surface control. The tiny inline preview is part of the existing
/// toolbar; it never creates an independent foreground overlay or starts PiP
/// from a scene-phase callback.
struct BackgroundPiPToolbarButton: View {
    @ObservedObject var videoService: BackgroundVideoService
    var isRunActive: Bool

    var body: some View {
        if isRunActive && videoService.shouldOfferManualControl {
            Button {
                videoService.performManualControl()
            } label: {
                HStack(spacing: 6) {
                    BackgroundPiPSourceHost(videoService: videoService)
                        .frame(width: 28, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .stroke(.secondary.opacity(0.3), lineWidth: 0.5)
                        }
                        .accessibilityHidden(true)
                    Label(
                        videoService.manualControlTitle,
                        systemImage: videoService.manualControlSystemImage
                    )
                }
            }
            .disabled(!videoService.canPerformManualControl)
            .accessibilityLabel(videoService.manualControlTitle)
            .accessibilityIdentifier("background.pip.control")
            .help(videoService.preparationState.localizedDescription)
        }
    }
}

#endif
