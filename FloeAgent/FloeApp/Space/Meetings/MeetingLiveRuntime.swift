// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeMeetings

extension MeetingProjectSession {
    var visibleRecordings: [CaptureSessionSnapshot] {
        let internalSessions = Set(liveTranscription?.chunks.compactMap(\.analysisSessionID) ?? [])
        return recordings.filter { !internalSessions.contains($0.id) }
    }
    func configureLiveTranscription(resumeUnfinished: Bool = false) {
        liveTranscription?.configure(enabled: intelligence.liveTranscription != false,
            serviceID: intelligence.transcriptionServiceID, resumeUnfinished: resumeUnfinished)
    }
    func receiveCaptureEvent(_ event: CaptureEvent) async {
        switch event {
        case .chunkFinalized(let session, let file, let range):
            liveTranscription?.enqueue(session: session, file: file, range: range)
        case .failed(_, let message): diagnostic = message
        default: break
        }
        await refresh()
    }
    func liveTranscriptDidChange() async {
        await refresh()
        if let failure = liveTranscription?.diagnostic { diagnostic = failure }
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
    func stopOwnedProcessing() async {
        cancelProcessing(); rollingSummaryGeneration = UUID()
        await cancelDocumentExportAndWait()
        await followups?.cancelAndWait()
        rollingSummaryTask?.cancel(); rollingSummaryTask = nil; isUpdatingMinutes = false
        summaryTimer?.cancel(); summaryTimer = nil
        if isRecording { await stopRecording() }
        summaryTimer?.cancel(); summaryTimer = nil; await liveTranscription?.cancelAndWait()
    }
}
#endif
