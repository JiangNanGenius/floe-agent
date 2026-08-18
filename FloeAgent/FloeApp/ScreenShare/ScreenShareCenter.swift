// FloeApp — Screen sharing + visual-analysis center.
//
// Owns the ReplayKit screen-sharing surface: presents the system broadcast
// picker, reads key frames the Broadcast Upload Extension drops into the
// shared App Group container, and hands them to the configured vision model
// so the assistant can "see" the iPad screen.

#if canImport(UIKit)
import Foundation
import UIKit
import ReplayKit
import FloeCore

@MainActor
final class ScreenShareCenter: NSObject, ObservableObject {
    @Published private(set) var isSharing = false
    /// The latest screen frame, refreshed ~1fps while broadcasting.
    @Published private(set) var latestFrame: UIImage?
    /// Detected guide hints from frame analysis (element text + tap point).
    @Published private(set) var guideHints: [GuideHint] = []

    static let appGroupID = "group.org.floeagent.ios"
    static let screenShareExtensionID = "org.floeagent.ios.screenshare"

    private let conversationCenter: ConversationCenter
    private var framePollTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var analysisConsentSessionID: UUID?

    private static let latestFrameName = "ScreenFrames/latest.jpg"
    private static let sessionStateName = "ScreenFrames/session.json"

    init(conversationCenter: ConversationCenter) {
        self.conversationCenter = conversationCenter
        super.init()
    }

    /// Starts polling the App Group for the extension's key frames.
    func startSharing() {
        guard !isSharing else { return }
        isSharing = true
        framePollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.refreshSharedFrame()
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    func stopSharing() {
        isSharing = false
        framePollTask?.cancel()
        framePollTask = nil
        latestFrame = nil
        guideHints = []
        activeSessionID = nil
        analysisConsentSessionID = nil
        removeSharedFrame()
    }

    /// Asks the vision model to describe the current screen, then derive
    /// guide hints (what to tap) from the frame content.
    func analyzeScreenAndGuide(userGoal: String) async {
        guard let snapshot = latestFrameSnapshot(),
              analysisConsentSessionID == snapshot.state.sessionID else { return }
        latestFrame = snapshot.image
        let description = await describeScreen(image: snapshot.image, prompt:
            "Describe the visible UI elements and what the user should tap to: \(userGoal). Return concise hints.")
        guideHints = Self.guideHints(from: description, frame: snapshot.image)
    }

    var analysisDestinationName: String {
        conversationCenter.screenAnalysisDestinationName() ?? "配置的视觉模型服务商"
    }

    var hasScreenAnalysisConsent: Bool {
        guard let activeSessionID else { return false }
        return analysisConsentSessionID == activeSessionID
    }

    @discardableResult
    func confirmScreenAnalysisTransmission() -> Bool {
        guard let snapshot = latestFrameSnapshot() else { return false }
        activeSessionID = snapshot.state.sessionID
        analysisConsentSessionID = snapshot.state.sessionID
        return true
    }

    /// A detected on-screen hint: which element to tap and roughly where.
    struct GuideHint: Identifiable, Sendable {
        let id = UUID()
        let elementText: String
        let tapPoint: CGPoint  // normalized 0-1
    }

    private static func guideHints(from description: String?, frame: UIImage) -> [GuideHint] {
        guard let description, !description.isEmpty else { return [] }
        // Placeholder parsing: in a full build the vision model returns
        // structured element rects; this scaffold shows the description as
        // one centered hint so the guide surface is honest, not fake.
        return [GuideHint(elementText: description, tapPoint: CGPoint(x: 0.5, y: 0.5))]
    }

    /// Presents the system picker that lets the user start (or stop) screen sharing.
    func makeBroadcastPicker() -> RPBroadcastActivityViewController {
        let picker = RPBroadcastActivityViewController()
        picker.delegate = self
        return picker
    }

    /// Presents the system broadcast picker and begins frame polling.
    func presentBroadcastPicker() {
        startSharing()
    }

    /// Reads the latest key frame the extension wrote, if any.
    func latestFrameImage() -> UIImage? {
        latestFrameSnapshot()?.image
    }

    /// Asks the configured vision model to describe the current screen.
    /// Returns nil when no frame is available or no vision model is set.
    private func describeScreen(image: UIImage, prompt: String) async -> String? {
        guard let data = image.jpegData(compressionQuality: 0.7) else { return nil }
        let base64 = data.base64EncodedString()
        return await conversationCenter.describeImage(
            base64: base64,
            mimeType: "image/jpeg",
            prompt: prompt
        )
    }

    private var containerURL: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        )
    }

    private func refreshSharedFrame() {
        guard let snapshot = latestFrameSnapshot() else {
            isSharing = false
            latestFrame = nil
            activeSessionID = nil
            analysisConsentSessionID = nil
            guideHints = []
            return
        }
        if activeSessionID != snapshot.state.sessionID {
            analysisConsentSessionID = nil
            guideHints = []
        }
        activeSessionID = snapshot.state.sessionID
        isSharing = true
        latestFrame = snapshot.image
    }

    private func latestFrameSnapshot() -> (state: ScreenShareSessionState, image: UIImage)? {
        guard let container = containerURL,
              let stateData = try? Data(contentsOf: container.appendingPathComponent(Self.sessionStateName)),
              let state = try? JSONDecoder().decode(ScreenShareSessionState.self, from: stateData),
              state.isFresh(),
              let frameData = try? Data(contentsOf: container.appendingPathComponent(Self.latestFrameName)),
              let image = UIImage(data: frameData) else {
            return nil
        }
        return (state, image)
    }

    private func removeSharedFrame() {
        guard let container = containerURL else { return }
        try? FileManager.default.removeItem(
            at: container.appendingPathComponent(Self.latestFrameName)
        )
    }
}

extension ScreenShareCenter: RPBroadcastActivityViewControllerDelegate {
    nonisolated func broadcastActivityViewController(
        _ broadcastActivityViewController: RPBroadcastActivityViewController,
        didFinishWith broadcastController: RPBroadcastController?,
        error: Error?
    ) {
        Task { @MainActor in
            if broadcastController?.isBroadcasting == true {
                self.startSharing()
            } else {
                self.stopSharing()
            }
        }
    }
}
#endif
