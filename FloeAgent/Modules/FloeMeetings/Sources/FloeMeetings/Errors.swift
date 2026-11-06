// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Bilingual user-facing strings. Deliberately tiny: the core exposes errors
/// and capability notes only; full product copy lives with the host UI.
public enum MeetingStrings {
    public static func text(_ english: String, _ chinese: String) -> String {
        switch Locale.current.language.languageCode?.identifier {
        case "zh": return chinese
        default: return english
        }
    }
}

public enum MeetingError: Error, Hashable, Sendable, LocalizedError {
    case invalidTimeRange(start: Double, end: Double)
    case meetingNotFound(MeetingID)
    case sessionNotFound(CaptureSessionID)
    case segmentNotFound(TranscriptSegmentID)
    case speakerNotFound(SpeakerID)
    case noteNotFound(NoteEntryID)
    case markerNotFound(TimeMarkerID)
    case todoNotFound(TodoItemID)
    case decisionNotFound(DecisionID)
    case noActiveCapture
    case captureAlreadyActive(CaptureSessionID)
    case captureSessionEnded(CaptureSessionID)
    case captureBackendFailed(String)
    case captureStopTimedOut(CaptureSessionID)
    case importedFileUnavailable(String)
    case staleRevision(expected: Int, actual: Int)
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidTimeRange:
            return MeetingStrings.text("Invalid time range.", "时间点无效。")
        case .meetingNotFound:
            return MeetingStrings.text("Meeting not found.", "找不到会议。")
        case .sessionNotFound:
            return MeetingStrings.text("Recording session not found.", "找不到录制会话。")
        case .segmentNotFound:
            return MeetingStrings.text("Transcript segment not found.", "找不到转写片段。")
        case .speakerNotFound:
            return MeetingStrings.text("Speaker not found.", "找不到发言人。")
        case .noteNotFound:
            return MeetingStrings.text("Note not found.", "找不到笔记。")
        case .markerNotFound:
            return MeetingStrings.text("Marker not found.", "找不到标记。")
        case .todoNotFound:
            return MeetingStrings.text("To-do not found.", "找不到待办。")
        case .decisionNotFound:
            return MeetingStrings.text("Decision not found.", "找不到结论。")
        case .noActiveCapture:
            return MeetingStrings.text("No recording is active.", "当前没有进行中的录制。")
        case .captureAlreadyActive:
            return MeetingStrings.text("A recording is already in progress.", "已有进行中的录制。")
        case .captureSessionEnded:
            return MeetingStrings.text("This recording session has ended.", "这次录制已结束。")
        case .captureBackendFailed(let message):
            return MeetingStrings.text("Recording failed: \(message)", "录制失败：\(message)")
        case .captureStopTimedOut:
            return MeetingStrings.text("Recording did not finish in time; saved partial audio.", "录制未能及时结束，已保留已录制的部分。")
        case .importedFileUnavailable(let name):
            return MeetingStrings.text("The imported file is unavailable: \(name)", "导入文件不可用：\(name)")
        case .staleRevision:
            return MeetingStrings.text("This content was changed elsewhere. Refresh and try again.", "内容已在别处更改，请刷新后重试。")
        case .persistenceFailed(let message):
            return MeetingStrings.text("Saving failed: \(message)", "保存失败：\(message)")
        }
    }
}
