// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Prepared input for the host's summarizer. This module does not run any
/// LLM; it assembles exactly what a summarizer needs for an incremental
/// update: the transcript window since the last refresh plus every decision
/// recorded so far (decisions are durable and survive the rolling window).
public struct SummaryInput: Sendable, Hashable {
    public let meetingID: MeetingID
    public let sessionID: CaptureSessionID
    /// Media-time window [at-window, at] in the session's clock.
    public let window: MediaTimeRange
    /// Final segments intersecting the window, in transcript order, clipped
    /// to the window.
    public let segments: [TranscriptSegment]
    /// All decisions of the meeting, including ones made before the window.
    public let cumulativeDecisions: [MeetingDecision]
    /// Decisions first seen inside the window.
    public let freshDecisions: [MeetingDecision]

    public var isEmpty: Bool { segments.isEmpty && freshDecisions.isEmpty }
}

public enum SummaryInputBuilder {
    /// Build the incremental input at media time `at` within `session`,
    /// looking back `window` seconds (default five minutes).
    public static func build(
        meetingID: MeetingID,
        sessionID: CaptureSessionID,
        at: Double,
        window: Double = 300,
        segments: [TranscriptSegment],
        decisions: [MeetingDecision]
    ) throws -> SummaryInput {
        let range = try MediaTimeRange(start: max(0, at - window), end: at)
        let windowSegments = segments
            .filter { $0.sessionID == sessionID && $0.range.end > range.start && $0.range.start < range.end }
            .sorted { lhs, rhs in
                if lhs.range.start != rhs.range.start { return lhs.range.start < rhs.range.start }
                return lhs.ordinal < rhs.ordinal
            }
        let fresh = decisions.filter { decision in
            if case .recording(let session, let decisionRange) = decision.source, session == sessionID {
                return range.contains(decisionRange.start)
            }
            return false
        }
        return SummaryInput(
            meetingID: meetingID,
            sessionID: sessionID,
            window: range,
            segments: windowSegments,
            cumulativeDecisions: decisions,
            freshDecisions: fresh
        )
    }
}
