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
    /// A Picture-in-Picture video that plays the run's progress; keeps the
    /// app alive while the user leaves the PiP floating (translation-app
    /// style — the video carries real content, so it passes review).
    case pictureInPicture
    /// Screen sharing with an on-screen operation guide; the Broadcast
    /// Upload Extension stays alive while the user is broadcasting.
    case screenShare
}

public extension BackgroundExecutionPreference {
    /// Short user-facing label for the settings row.
    var title: String {
        switch self {
        case .standard: return "普通后台任务"
        case .pictureInPicture: return "画中画视频"
        case .screenShare: return "屏幕共享引导"
        }
    }

    /// One-line explanation shown under the picker.
    var subtitle: String {
        switch self {
        case .standard: return "30 秒完成窗口 + 动态岛进度 + 检查点恢复"
        case .pictureInPicture: return "浮窗播任务进度视频，切后台不断流"
        case .screenShare: return "共享屏幕画面 + 操作引导，扩展后台保活"
        }
    }
}
