// FloeCore — Background execution preference for agent runs.
//
// iOS cannot keep a long-running network stream alive indefinitely. This
// records which of the three supported surfaces the user picked, so the app
// keeps the run alive through the surface the user actually opted into.

import Foundation

public enum BackgroundExecutionPreference: String, Sendable, Codable, CaseIterable, Hashable {
    /// The 30s completion lease plus an iOS 26 continued-processing task
    /// (progress on the Dynamic Island, checkpoint + resume). No extra UI.
    case standard
    /// An inline Picture-in-Picture source that displays run progress. AVKit
    /// enters the system PiP surface when the user leaves the app.
    case pictureInPicture
    /// Screen sharing with an on-screen operation guide; the Broadcast
    /// Upload Extension stays alive while the user is broadcasting.
    case screenShare
}

public extension BackgroundExecutionPreference {
    /// Short user-facing label for the settings row.
    ///
    /// FloeCore is Foundation-only and cannot use the app's String Catalog, so
    /// (like the other Foundation-layer surfaces) both languages are kept
    /// together and resolved from the current locale.
    var title: String {
        switch self {
        case .standard: return BackgroundExecutionPreferenceText.t(
            "普通后台任务", "Regular background task"
        )
        case .pictureInPicture: return BackgroundExecutionPreferenceText.t(
            "系统画中画", "System Picture-in-Picture"
        )
        case .screenShare: return BackgroundExecutionPreferenceText.t(
            "屏幕共享引导", "On-screen sharing guide"
        )
        }
    }

    /// One-line explanation shown under the picker. Describes what the user
    /// experiences, not the implementation (no lease windows or checkpoints).
    var subtitle: String {
        switch self {
        case .standard: return BackgroundExecutionPreferenceText.t(
            "切到其他 App 后任务可继续运行，返回 Floe 时可恢复未完成的工作；具体时长由系统决定。",
            "The task can keep running after you leave the app and resume where it left off when you return; the system decides how long this lasts."
        )
        case .pictureInPicture: return BackgroundExecutionPreferenceText.t(
            "前台仅显示工具栏内嵌画面；离开 Floe 时自动进入系统画中画，也可手动控制。",
            "In Floe the picture stays embedded in the toolbar; leaving the app opens system Picture-in-Picture automatically, and you can control it manually."
        )
        case .screenShare: return BackgroundExecutionPreferenceText.t(
            "任务开始时打开系统共享授权；需要时可从工具栏手动显示进度画中画。",
            "Starts the system sharing permission when a task begins; you can show the progress picture from the toolbar whenever needed."
        )
        }
    }
}

/// Bilingual strings for the Foundation-only layer. Keep both languages
/// together so no user-facing text is added in one language only.
enum BackgroundExecutionPreferenceText {
    static func t(_ zh: String, _ en: String) -> String {
        Locale.current.identifier.hasPrefix("zh") ? zh : en
    }
}
