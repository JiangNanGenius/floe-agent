// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A half-open time range in seconds, relative to the start of its capture
/// session (media time). Used to anchor transcript segments, markers and
/// summary windows to a point in the original recording.
public struct MediaTimeRange: Hashable, Sendable, Codable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end < 1_000_000_000 else {
            throw MeetingError.invalidTimeRange(start: start, end: end)
        }
        self.start = start
        self.end = end
    }

    public var duration: Double { end - start }
    public func contains(_ seconds: Double) -> Bool { seconds >= start && seconds < end }
    public func shifted(by offset: Double) throws -> MediaTimeRange {
        try MediaTimeRange(start: start + offset, end: end + offset)
    }

    /// Internal restore path for rows already validated at insert time.
    init(uncheckedStart start: Double, end: Double) {
        precondition(start.isFinite && end.isFinite && start >= 0 && end > start)
        self.start = start
        self.end = end
    }
}

/// Where a piece of meeting content came from. Notes, markers, todos,
/// decisions and corrections all carry one so the UI can jump back to the
/// original audio/transcript position ("时间点连接文字").
public enum SourceReference: Hashable, Sendable, Codable {
    /// A span of the original recording of the given session.
    case recording(session: CaptureSessionID, range: MediaTimeRange)
    /// A specific transcript segment.
    case segment(TranscriptSegmentID)
    /// An imported audio/video file that was not recorded by this app.
    case importedFile(fileName: String, range: MediaTimeRange?)
    /// No media anchor (e.g. typed manually without a timestamp).
    case none

    public var session: CaptureSessionID? {
        switch self {
        case .recording(let session, _): return session
        case .segment: return nil
        case .importedFile: return nil
        case .none: return nil
        }
    }
}
