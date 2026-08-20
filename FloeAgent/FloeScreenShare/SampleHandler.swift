// FloeScreenShare — ReplayKit Broadcast Upload Extension.
//
// Captures the device screen while the user has explicitly started screen
// sharing (via RPBroadcastActivityViewController or Control Center). The
// extension is a separate process the system keeps alive for the lifetime of
// the broadcast — this is the "screen sharing / remote assist" surface, and
// the same process the agent can piggyback on for background presence.
//
// Key frames are throttled to ~1 fps and written as JPEG to the shared App
// Group container, where the host app reads them for visual analysis (the
// assistant "sees" the screen). No video is uploaded anywhere by default.

import ReplayKit
import CoreMedia
import CoreImage
import UIKit
import FloeCore

final class SampleHandler: RPBroadcastSampleHandler {

    private static let appGroupID = "group.org.floeagent.ios"
    private static let latestFrameName = "ScreenFrames/latest.jpg"
    private static let sessionStateName = "ScreenFrames/session.json"

    private var lastCapture = Date.distantPast
    private var sessionID: UUID?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let sessionID = UUID()
        self.sessionID = sessionID
        // Drop stale frames from a previous broadcast.
        if let container = Self.containerURL {
            let framesDir = container.appendingPathComponent("ScreenFrames")
            try? FileManager.default.removeItem(at: framesDir)
            try? FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)
            writeSessionState(
                ScreenShareSessionState(sessionID: sessionID, isActive: true),
                container: container
            )
        }
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard sampleBufferType == .video else { return }
        let now = Date()
        guard now.timeIntervalSince(lastCapture) >= 1.0 else { return }
        lastCapture = now
        saveKeyFrame(sampleBuffer)
    }

    override func broadcastFinished() {
        lastCapture = .distantPast
        guard let sessionID, let container = Self.containerURL else { return }
        try? FileManager.default.removeItem(
            at: container.appendingPathComponent(Self.latestFrameName)
        )
        writeSessionState(
            ScreenShareSessionState(sessionID: sessionID, isActive: false),
            container: container
        )
        self.sessionID = nil
    }

    private func saveKeyFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        guard let data = image.jpegData(compressionQuality: 0.6) else { return }
        guard let sessionID, let container = Self.containerURL else { return }
        let framesDir = container.appendingPathComponent("ScreenFrames")
        try? FileManager.default.createDirectory(
            at: framesDir,
            withIntermediateDirectories: true
        )
        let url = framesDir.appendingPathComponent("latest.jpg")
        try? data.write(to: url, options: .atomic)
        writeSessionState(
            ScreenShareSessionState(sessionID: sessionID, isActive: true),
            container: container
        )
    }

    private func writeSessionState(_ state: ScreenShareSessionState, container: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(
            to: container.appendingPathComponent(Self.sessionStateName),
            options: .atomic
        )
    }

    private static var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupID
        )
    }
}
