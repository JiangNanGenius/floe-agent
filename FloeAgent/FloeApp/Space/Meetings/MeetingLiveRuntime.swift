// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeMeetings

extension MeetingProjectSession {
    var visibleRecordings: [CaptureSessionSnapshot] {
        recordings.filter { !isAnalysisCapture($0) }
    }
    func configureLiveTranscription(resumeUnfinished: Bool = false) {
        liveTranscription?.configure(enabled: intelligence.liveTranscription != false,
            serviceID: intelligence.transcriptionServiceID, resumeUnfinished: resumeUnfinished)
    }
    func receiveCaptureEvent(_ event: CaptureEvent) async {
        guard !isStoppingForFileAction else { return }
        switch event {
        case .started(let session):
            captureEventSession = session
            await continuousASR?.start(captureSession: session)
        case .chunkFinalized(let session, let file, let range):
            // A finalized file belongs to its own original even when a newer
            // recording has already started; keep it in the disk queue.
            liveTranscription?.enqueue(session: session, file: file, range: range)
            speakerRecognition?.enqueue(original: session, file: file, range: range)
        case .stopped(let session, _):
            guard captureEventSession == session else {
                speakerRecognition?.captureFinished(session)
                return
            }
            captureEventSession = nil
            speakerRecognition?.captureFinished(session)
            // Join the live drain BEFORE opening the file fallback. The pump
            // already delivered every frame; the coordinator commits the
            // genuine tail and closes its lease here, so the file queue's
            // coverage snapshot cannot race a late final.
            await continuousASR?.captureDidStop()
            liveTranscription?.liveCaptureFinished = true
            liveTranscription?.reevaluate()
        case .cancelled(let session):
            guard captureEventSession == session else {
                speakerRecognition?.captureFinished(session)
                return
            }
            captureEventSession = nil
            speakerRecognition?.captureFinished(session)
            await continuousASR?.cancelAndWait()
            liveTranscription?.liveCaptureFinished = true
            liveTranscription?.reevaluate()
        case .failed(let session, let message):
            if let session {
                guard captureEventSession == session else {
                    speakerRecognition?.captureFinished(session)
                    return
                }
            } else {
                // A backend that failed before it produced a session cannot
                // belong to a newer active capture. Ignore it while a new
                // start is still preparing; startRecording reports its own
                // failure from the thrown begin call.
                guard captureEventSession == nil, !changingCapture else { return }
            }
            captureEventSession = nil
            if let session { speakerRecognition?.captureFinished(session) }
            diagnostic = message
            await continuousASR?.cancelAndWait()
            liveTranscription?.liveCaptureFinished = true
            liveTranscription?.reevaluate()
        }
        await refresh()
    }
    func liveTranscriptDidChange() async {
        liveTranscription?.reevaluate()
        await refresh()
        if let failure = speakerRecognition?.diagnostic { diagnostic = failure }
        if let failure = liveTranscription?.diagnostic { diagnostic = failure }
        // Explicit diagnostics: internal chunking/rotation counters stay out
        // of the ordinary transcript surface but remain observable.
        liveRecognitionDiagnostics = continuousASR?.metricsDescription ?? ""
        // The first useful chunk and the final drained chunk do not wait
        // for another timer tick. Minutes remain a separate stored record.
        if intelligence.automaticSummary, transcript.count > lastSummaryTranscriptCount,
           lastSummaryTranscriptCount == 0 || !isRecording { updateRollingMinutes() }
        synchronizeSummaryTimer()
    }
    func rollingTranscriptWindow() -> [TranscriptSegment] {
        guard let last = transcript.last else { return [] }
        let origin = liveTranscription?.originalSession(for: last.sessionID) ?? last.sessionID
        let start = max(0, last.range.end - 300)
        return transcript.filter {
            (liveTranscription?.originalSession(for: $0.sessionID) ?? $0.sessionID) == origin && $0.range.end >= start
        }.sorted { $0.range.start < $1.range.start }
    }
    func updateRollingMinutes() {
        guard intelligence.automaticSummary, !isUpdatingMinutes else { return }
        let segments = rollingTranscriptWindow()
        guard let first = segments.first, let last = segments.last else { return }
        let count = transcript.count
        let epoch = rollingSummaryGeneration
        isUpdatingMinutes = true
        rollingSummaryTask = Task { [self] in
            defer { if rollingSummaryGeneration == epoch { rollingSummaryTask = nil; isUpdatingMinutes = false } }
            do {
                let provider = try MeetingIntelligenceProvider.configured(in: environment)
                let source = segments.map { "[\($0.id.rawValue.uuidString) · \(sourceDescription(.recording(session: $0.sessionID, range: $0.range)) ?? meetingTime($0.range.start))] \($0.text)" }.joined(separator: "\n")
                let conclusions = decisions.map(\.text).joined(separator: "\n")
                let answer = try await provider.request(instruction: "\(minutesTemplate.instruction) Prepare independent rolling minutes from the latest five-minute source window and all cumulative decisions. Preserve earlier conclusions. Do not change personal notes or invent speakers.",
                    source: "Cumulative decisions:\n\(conclusions)\nRecent transcript:\n\(source)")
                try Task.checkCancellation()
                guard rollingSummaryGeneration == epoch else { throw CancellationError() }
                let summary = try await service.recordSummary(meeting: MeetingID(id), kind: summaries.isEmpty ? .first : .rolling,
                    text: answer, window: .init(start: first.range.start, end: last.range.end))
                lastSummaryTranscriptCount = count
                await refresh()
                rememberSummarySources(summary, segments: segments)
            } catch is CancellationError {} catch { diagnostic = error.localizedDescription }
        }
    }
    /// Host deletion/explicit-stop seam. Closing the editor does not call it.
    func stopOwnedProcessing() async -> Bool {
        await stopPlaybackAndWait()
        let previousProcessing = cancelAnalysisForOwnedStop(), previousSummary = rollingSummaryTask
        rollingSummaryGeneration = UUID()
        previousSummary?.cancel(); rollingSummaryTask = nil; isUpdatingMinutes = false
        summaryTimer?.cancel(); summaryTimer = nil
        await cancelDocumentExportAndWait()
        await followups?.cancelAndWait()
        await liveTranscription?.cancelAndWait()
        await continuousASR?.cancelAndWait(); continuousASR = nil
        await previousProcessing?.value; await previousSummary?.value
        let stopped = await stopRecordingForDeparture()
        summaryTimer?.cancel(); summaryTimer = nil
        await speakerRecognition?.cancelAndWait()
        return stopped
    }
}
#endif
