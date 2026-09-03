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
    var title: String {
        switch self {
        case .standard: return "普通后台任务"
        case .pictureInPicture: return "系统画中画"
        case .screenShare: return "屏幕共享引导"
        }
    }

    /// One-line explanation shown under the picker.
    var subtitle: String {
        switch self {
        case .standard: return "30 秒完成窗口 + 动态岛进度 + 检查点恢复"
        case .pictureInPicture: return "前台仅显示工具栏内嵌画面；离开 Floe 时自动进入系统画中画，也可手动控制"
        case .screenShare: return "任务开始时打开系统共享授权；需要时可从工具栏手动显示进度画中画"
        }
    }
}
