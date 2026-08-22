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
    enum LifecycleState: String, Sendable {
        case idle, requesting, waitingForFirstFrame, active, stopped, failed
    }

    @Published private(set) var lifecycleState: LifecycleState = .idle
    @Published private(set) var isSharing = false
    @Published private(set) var isWaitingForBroadcast = false
    @Published private(set) var sharingError: String?
    /// The latest screen frame, refreshed ~1fps while broadcasting.
    @Published private(set) var latestFrame: UIImage?
    /// Detected guide hints from frame analysis (element text + tap point).
    @Published private(set) var guideHints: [GuideHint] = []
    /// A task-start request waiting for the matching thread to present the
    /// system ReplayKit picker. ReplayKit still owns the final consent tap.
    @Published private(set) var requestedConversationID: UUID?

    var onGuidanceChanged: ((UIImage?, [GuideHint]) -> Void)?

    static let appGroupID = "group.org.floeagent.ios"
    static let screenShareExtensionID = "org.floeagent.ios.screenshare"

    private let conversationCenter: ConversationCenter
    private var framePollTask: Task<Void, Never>?
    private var activeSessionID: UUID?
    private var analysisConsentSessionID: UUID?
    private var lastFrameReceivedAt: Date?
    /// ReplayKit only exposes its system-owned picker view. Keep a tiny host
    /// in the foreground window long enough to invoke that button directly;
    /// Floe must not interpose a second instructional sheet before the real
    /// system confirmation.
    private var broadcastPickerHost: RPSystemBroadcastPickerView?

    private static let latestFrameName = "ScreenFrames/latest.jpg"
    private static let sessionStateName = "ScreenFrames/session.json"

    init(conversationCenter: ConversationCenter) {
        self.conversationCenter = conversationCenter
        super.init()
    }

    /// Starts polling the App Group for the extension's key frames.
    func startSharing() {
        guard framePollTask == nil else {
            FloeLogger(category: .app).debug("screenSharePollingAlreadyActive")
            return
        }
        FloeLogger(category: .app).info("screenSharePollingStarted")
        isWaitingForBroadcast = true
        if lifecycleState == .idle || lifecycleState == .stopped {
            lifecycleState = .waitingForFirstFrame
        }
        sharingError = nil
        let startedAt = Date()
        framePollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                self.refreshSharedFrame()
                if !self.isSharing,
                   Date().timeIntervalSince(startedAt) > 20,
                   self.sharingError == nil {
                    self.sharingError = "尚未收到系统广播画面。请确认已在系统列表中选择 Floe Agent 并点“开始直播”。"
                    FloeLogger(category: .app).warning(
                        "screenShareFrameTimeout seconds=20"
                    )
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }
        }
    }

    func requestBroadcast(for conversationID: UUID) {
        guard lifecycleState != .requesting,
              lifecycleState != .waitingForFirstFrame,
              lifecycleState != .active else {
            FloeLogger(category: .app).debug(
                "screenShareAuthorizationCoalesced conversation=\(conversationID.uuidString) state=\(lifecycleState.rawValue)"
            )
            return
        }
        FloeLogger(category: .app).info(
            "screenShareAuthorizationRequested conversation=\(conversationID.uuidString)"
        )
        requestedConversationID = conversationID
        lifecycleState = .requesting
        startSharing()
        presentSystemBroadcastConfirmation(conversationID: conversationID)
    }

    func stopSharing() {
        FloeLogger(category: .app).info("screenShareStopped")
        isSharing = false
        isWaitingForBroadcast = false
        sharingError = nil
        framePollTask?.cancel()
        framePollTask = nil
        latestFrame = nil
        guideHints = []
        onGuidanceChanged?(nil, [])
        activeSessionID = nil
        analysisConsentSessionID = nil
        lastFrameReceivedAt = nil
        lifecycleState = .stopped
        broadcastPickerHost?.removeFromSuperview()
        broadcastPickerHost = nil
        removeSharedFrame()
    }

    /// Opens ReplayKit's real confirmation directly. The request originates
    /// from the same user action that starts the task; the final broadcast
    /// decision remains entirely system-owned. If navigation is still being
    /// committed, wait briefly for a foreground key window instead of showing
    /// a Floe-owned waiting page that can become stuck.
    private func presentSystemBroadcastConfirmation(conversationID: UUID) {
        broadcastPickerHost?.removeFromSuperview()
        broadcastPickerHost = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<40 {
                guard self.requestedConversationID == conversationID else { return }
                if let window = Self.foregroundKeyWindow() {
                    let picker = RPSystemBroadcastPickerView(frame: CGRect(x: -4, y: -4, width: 2, height: 2))
                    picker.preferredExtension = Self.screenShareExtensionID
                    picker.showsMicrophoneButton = false
                    picker.alpha = 0.01
                    window.addSubview(picker)
                    self.broadcastPickerHost = picker
                    await Task.yield()
                    if let button = Self.firstButton(in: picker) {
                        self.requestedConversationID = nil
                        FloeLogger(category: .app).info(
                            "screenShareSystemConfirmationTriggered conversation=\(conversationID.uuidString) attempt=\(attempt + 1)"
                        )
                        button.sendActions(for: .touchUpInside)
                        try? await Task.sleep(for: .seconds(1))
                        picker.removeFromSuperview()
                        if self.broadcastPickerHost === picker {
                            self.broadcastPickerHost = nil
                        }
                        return
                    }
                    picker.removeFromSuperview()
                    self.broadcastPickerHost = nil
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self.sharingError = "无法发起系统屏幕共享确认，请重新开始任务后再试。"
            self.lifecycleState = .failed
            FloeLogger(category: .app).warning(
                "screenShareSystemConfirmationUnavailable conversation=\(conversationID.uuidString) attempts=40"
            )
        }
    }

    private static func foregroundKeyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }

    private static func firstButton(in view: UIView) -> UIButton? {
        if let button = view as? UIButton { return button }
        for child in view.subviews {
            if let button = firstButton(in: child) { return button }
        }
        return nil
    }

    /// Asks the vision model to describe the current screen, then derive
    /// guide hints (what to tap, where) from structured model output.
    func analyzeScreenAndGuide(userGoal: String) async {
        guard let snapshot = latestFrameSnapshot(),
              analysisConsentSessionID == snapshot.state.sessionID else { return }
        latestFrame = snapshot.image
        // Ask for structured hints: the model returns one JSON array whose
        // entries carry the element label and a normalized tap point, so the
        // guide can render a real highlight instead of a text blob.
        let description = await describeScreen(image: snapshot.image, prompt: """
            Identify the on-screen elements the user should tap to accomplish: \(userGoal). \
            Respond with ONLY a JSON array. Each element: {"label": "element name", \
            "instruction": "what to do", "x": 0.0-1.0, "y": 0.0-1.0} where x,y are \
            the normalized center of the tappable element. No prose outside the JSON.
            """)
        guideHints = Self.guideHints(from: description)
        onGuidanceChanged?(snapshot.image, guideHints)
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
        let instruction: String
        let tapPoint: CGPoint  // normalized 0-1
    }

    /// Parses the model's structured JSON hints. Falls back to a single
    /// centered text hint when the model returns prose instead of JSON, so
    /// the guide surface still shows something honest.
    private static func guideHints(from description: String?) -> [GuideHint] {
        guard let description, !description.isEmpty else { return [] }
        if let data = Self.extractJSON(from: description),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            let hints = array.compactMap { item -> GuideHint? in
                guard let label = item["label"] as? String,
                      let x = (item["x"] as? NSNumber)?.doubleValue,
                      let y = (item["y"] as? NSNumber)?.doubleValue else { return nil }
                return GuideHint(
                    elementText: label,
                    instruction: (item["instruction"] as? String) ?? label,
                    tapPoint: CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
                )
            }
            if !hints.isEmpty { return hints }
        }
        return [GuideHint(elementText: description, instruction: description, tapPoint: CGPoint(x: 0.5, y: 0.5))]
    }

    /// Extracts the first JSON array from model output (tolerant of prose
    /// around it, markdown fences, etc.).
    private static func extractJSON(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]") else { return nil }
        return String(text[start...end]).data(using: .utf8)
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
            // The extension writes at a best-effort cadence. A single stale or
            // partially replaced frame must not tear down the logical session:
            // that transition previously retriggered the consent alert every
            // time the next frame arrived.
            if let lastFrameReceivedAt,
               Date().timeIntervalSince(lastFrameReceivedAt) > 12 {
                isSharing = false
                isWaitingForBroadcast = true
                lifecycleState = .waitingForFirstFrame
            }
            return
        }
        if activeSessionID != snapshot.state.sessionID {
            analysisConsentSessionID = nil
            guideHints = []
            onGuidanceChanged?(nil, [])
        }
        activeSessionID = snapshot.state.sessionID
        analysisConsentSessionID = snapshot.state.sessionID
        lastFrameReceivedAt = Date()
        if !isSharing {
            FloeLogger(category: .app).info(
                "screenShareFirstFrameReceived session=\(snapshot.state.sessionID.uuidString)"
            )
        }
        isSharing = true
        isWaitingForBroadcast = false
        lifecycleState = .active
        sharingError = nil
        latestFrame = snapshot.image
    }

    private func latestFrameSnapshot() -> (state: ScreenShareSessionState, image: UIImage)? {
        guard let container = containerURL,
              let stateData = try? Data(floeContentsOf: container.appendingPathComponent(Self.sessionStateName)),
              let state = try? JSONDecoder().decode(ScreenShareSessionState.self, from: stateData),
              state.isFresh(),
              let frameData = try? Data(floeContentsOf: container.appendingPathComponent(Self.latestFrameName)),
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
        let didStartBroadcasting = broadcastController?.isBroadcasting == true
        Task { @MainActor in
            if didStartBroadcasting {
                FloeLogger(category: .app).info("screenShareBroadcastControllerStarted")
                self.startSharing()
            } else {
                let nsError = error as NSError?
                FloeLogger(category: .app).warning(
                    "screenShareBroadcastControllerCancelled domain=\(nsError?.domain ?? "none") code=\(nsError?.code ?? 0)"
                )
                self.stopSharing()
            }
        }
    }
}
#endif
