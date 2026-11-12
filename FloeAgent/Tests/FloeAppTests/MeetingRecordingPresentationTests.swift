// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
@testable import FloeApp

/// Directed contract for the recorder deck's independent capture and
/// transcription states. Pure values only; no player, microphone, device or
/// media session is created.
@Suite("Meeting capture deck state matrix", .serialized)
struct MeetingRecordingDeckStateTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func span(live: Bool = true, active: Bool = false, duration: Double? = nil,
                      started: Date? = nil) -> MeetingRecordingSpan {
        .init(isLiveRecording: live, isActive: active, duration: duration, startedAt: started)
    }

    @Test("Effective duration sums finalized live rows and the active capture once")
    func effectiveDurationIsLiveOnlyAndNotDoubleCounted() {
        let spans = [
            span(duration: 120),
            span(active: true, duration: nil, started: now.addingTimeInterval(-45)),
            span(live: false, duration: 600),
            span(active: true, duration: 30, started: now.addingTimeInterval(-300)),
            span(active: true, duration: nil, started: now.addingTimeInterval(60)),
        ]
        #expect(MeetingCapturePresentation.effectiveSeconds(in: spans, now: now) == 195)
        #expect(MeetingCapturePresentation.effectiveSeconds(
            in: [span(active: true, started: now.addingTimeInterval(60))], now: now) == 0)
    }

    @Test("Recording failure and transcription failure keep independent primary states")
    func captureAndTranscriptionPhasesStayIndependent() {
        let saved = [span(duration: 42)]
        let recording = MeetingCapturePresentation.resolve(
            isRecording: true, isPaused: false, isChangingCapture: false,
            transcriptionEnabled: true, isTranscribing: false, transcriptionLive: false,
            waitingForService: false, requiresRetry: true, unfinishedCount: 3,
            isProcessingSavedRecording: false,
            spans: [span(active: true, started: now.addingTimeInterval(-10))], now: now)
        #expect(recording.phase == .recording)
        #expect(recording.transcription == .retry)
        #expect(!recording.canRetryTranscription)
        #expect(recording.elapsedSeconds == 10)

        let paused = MeetingCapturePresentation.resolve(
            isRecording: false, isPaused: true, isChangingCapture: false,
            transcriptionEnabled: true, isTranscribing: false, transcriptionLive: false,
            waitingForService: false, requiresRetry: true, unfinishedCount: 1,
            isProcessingSavedRecording: false, spans: saved, now: now)
        #expect(paused.phase == .paused)
        #expect(paused.transcription == .retry)
        #expect(!paused.canRetryTranscription)

        let stopped = MeetingCapturePresentation.resolve(
            isRecording: false, isPaused: false, isChangingCapture: false,
            transcriptionEnabled: true, isTranscribing: false, transcriptionLive: false,
            waitingForService: false, requiresRetry: true, unfinishedCount: 1,
            isProcessingSavedRecording: false, spans: saved, now: now)
        #expect(stopped.phase == .saved)
        #expect(stopped.transcription == .retry)
        #expect(stopped.canRetryTranscription)
        #expect(stopped.savedRecordingCount == 1)
    }

    @Test("Off, live, fallback, waiting and saved-pass states are distinct")
    func transcriptionReasonIsExplicit() {
        let saved = [span(duration: 9)]
        func resolve(enabled: Bool = true, working: Bool = false, waiting: Bool = false,
                     retry: Bool = false, unfinished: Int = 0, processing: Bool = false,
                     live: Bool? = nil) -> MeetingCapturePresentation {
            .resolve(isRecording: false, isPaused: false, isChangingCapture: false,
                     transcriptionEnabled: enabled, isTranscribing: working,
                     transcriptionLive: live ?? working, waitingForService: waiting,
                     requiresRetry: retry, unfinishedCount: unfinished,
                     isProcessingSavedRecording: processing, spans: saved, now: now)
        }
        #expect(resolve(enabled: false).transcription == .off)
        #expect(resolve(working: true).transcription == .live)
        #expect(resolve(working: true, live: false).transcription == .fallback)
        #expect(resolve(waiting: true).transcription == .waiting)
        #expect(resolve(processing: true).transcription == .savedPass)
        #expect(resolve(retry: true, processing: true).transcription == .savedPass)
        #expect(!resolve(retry: true, processing: true).canRetryTranscription)
    }

    @Test("A changing capture never claims it has finished")
    func captureTransitionIsHonest() {
        let starting = MeetingCapturePresentation.resolve(
            isRecording: false, isPaused: false, isChangingCapture: true,
            transcriptionEnabled: true, isTranscribing: false, transcriptionLive: false,
            waitingForService: false, requiresRetry: false, unfinishedCount: 0,
            isProcessingSavedRecording: false, spans: [], now: now)
        #expect(starting.phase == .preparing)
        let stopping = MeetingCapturePresentation.resolve(
            isRecording: true, isPaused: false, isChangingCapture: true,
            transcriptionEnabled: true, isTranscribing: false, transcriptionLive: false,
            waitingForService: false, requiresRetry: false, unfinishedCount: 0,
            isProcessingSavedRecording: false,
            spans: [span(active: true, started: now.addingTimeInterval(-5))], now: now)
        #expect(stopping.phase == .finishing)
        #expect(!stopping.canRetryTranscription)
    }
}
#endif
