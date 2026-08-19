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

@MainActor
final class BackgroundVideoService: NSObject, ObservableObject {
    @Published private(set) var isPiPActive = false

    private var pipController: AVPictureInPictureController?
    private var playerLayer: AVPlayerLayer?
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var currentTitle = ""
    private var refreshTask: Task<Void, Never>?
    private var startGeneration: UInt64 = 0
    private var currentAssetURL: URL?

    /// Starts (or updates) the PiP progress video for an active run. The
    /// user keeps the app alive by floating this PiP while in background.
    func begin(title: String, initialProgress: String) async {
        startGeneration &+= 1
        let generation = startGeneration
        currentTitle = title
        stopPiPInternal()
        // PiP with a playing video requires the audio background mode. Set the
        // session active so the system registers that capability at task start
        // instead of suspending the app the moment it backgrounds.
        configureAudioSession()
        guard let assetURL = await synthesizeProgressVideo(
            title: title,
            progress: initialProgress
        ) else {
            deactivateAudioSession()
            return
        }
        guard !Task.isCancelled, generation == startGeneration else {
            try? FileManager.default.removeItem(at: assetURL)
            deactivateAudioSession()
            return
        }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            try? FileManager.default.removeItem(at: assetURL)
            deactivateAudioSession()
            return
        }
        let item = AVPlayerItem(url: assetURL)
        let queue = AVQueuePlayer(playerItem: item)
        let layer = AVPlayerLayer(player: queue)
        guard let controller = AVPictureInPictureController(playerLayer: layer) else {
            try? FileManager.default.removeItem(at: assetURL)
            deactivateAudioSession()
            return
        }
        currentAssetURL = assetURL
        player = queue
        playerLayer = layer
        looper = AVPlayerLooper(player: queue, templateItem: item)
        controller.delegate = self
        pipController = controller
        queue.play()
        controller.startPictureInPicture()
        isPiPActive = true
    }

    /// Updates the progress text and re-renders the looping video so the PiP
    /// actually reflects the latest state instead of a frozen first frame.
    func update(progress: String) {
        let generation = startGeneration
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self] in
            guard let self, generation == self.startGeneration else { return }
            await self.refreshVideo(
                title: self.currentTitle,
                progress: progress,
                generation: generation
            )
        }
    }

    /// Re-synthesizes the progress asset and hot-swaps the player item so the
    /// floating PiP shows the latest title/progress without restarting PiP.
    private func refreshVideo(title: String, progress: String, generation: UInt64) async {
        guard isPiPActive, let player else { return }
        guard let assetURL = await synthesizeProgressVideo(title: title, progress: progress) else { return }
        guard !Task.isCancelled, generation == startGeneration, isPiPActive else {
            try? FileManager.default.removeItem(at: assetURL)
            return
        }
        let item = AVPlayerItem(url: assetURL)
        looper?.disableLooping()
        player.removeAllItems()
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
        if let currentAssetURL {
            try? FileManager.default.removeItem(at: currentAssetURL)
            self.currentAssetURL = nil
        }
        isPiPActive = false
        deactivateAudioSession()
    }

    /// Releases playback state after the user or system closes PiP without
    /// asking AVKit to stop the already-stopped controller a second time.
    private func handlePiPStopped(_ controller: AVPictureInPictureController) {
        guard pipController === controller else {
            isPiPActive = false
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
        if let currentAssetURL {
            try? FileManager.default.removeItem(at: currentAssetURL)
            self.currentAssetURL = nil
        }
        isPiPActive = false
        deactivateAudioSession()
    }

    /// Configures the audio session for background playback so the PiP video
    /// keeps the app alive. Without this the app suspends the moment it
    /// backgrounds even while the PiP floats. Failure never breaks the run.
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {}
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func renderProgressFrame(title: String, progress: String) -> UIImage? {
        let size = CGSize(width: 640, height: 360)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
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
    /// progress. Real, visible content — the surface review expects.
    private func synthesizeProgressVideo(title: String, progress: String) async -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-progress-\(UUID().uuidString).mp4")
        let size = CGSize(width: 640, height: 360)
        guard let frame = renderProgressFrame(title: title, progress: progress),
              let cgImage = frame.cgImage else { return nil }
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(size.width),
                AVVideoHeightKey: Int(size.height)
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
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
        Task { @MainActor in self.isPiPActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in self.handlePiPStopped(pictureInPictureController) }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError _: Error
    ) {
        Task { @MainActor in self.stop() }
    }
}
#endif
