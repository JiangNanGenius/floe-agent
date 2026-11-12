// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import AVFoundation
import CoreMedia
import Observation
import FloeCore
import FloeMeetings
import FloeMeetingsAV

struct MeetingLiveChunk: Codable, Identifiable {
    enum State: String, Codable { case pending, transcribing, decoded, complete, failed, unconfirmed }
    var id = UUID()
    var originalSessionID: CaptureSessionID
    var file: String
    var range: MediaTimeRange
    var analysisSessionID: CaptureSessionID?
    var state: State = .pending
    var decoded: [TimedSpeechSegment]?
    var language: String?
    var serviceID: String?
    var error: String?
    var busyRetries: Int?
    /// Identity of the actual ASR request that produced `decoded`. A fresh
    /// key is minted every time the chunk is sent to the provider, because a
    /// retried chunk is a new independent request whose speaker numbering
    /// must never be merged with the previous attempt's.
    var requestKey: UUID?
}

struct MeetingChunkTranscript: Sendable {
    let segments: [TimedSpeechSegment]
    let language: String?
}

/// The live gate belongs to exactly one capture session. A paused recording
/// and its resumed successor share the same media coordinate origin (both
/// start at 0), so coverage from the current session must never be applied to
/// an older session's chunks.
struct MeetingLiveCoverageGate: Sendable {
    let session: CaptureSessionID?
    let active: Bool
    let coverage: [MediaTimeRange]
}

/// Disk-backed work queue owned by the meeting service/session, not a View.
/// One ASR request at a time; completed results survive stop and navigation.
@MainActor @Observable final class MeetingLiveTranscription {
    let meetingID: MeetingID
    let root: URL
    private let service: MeetingService
    typealias TranscribeChunk = @MainActor @Sendable (URL, String?) async throws -> MeetingChunkTranscript
    private let transcribeChunk: TranscribeChunk
    typealias ProgressiveTranscribe = @MainActor @Sendable (URL, String?, MeetingFilePartialRelay) async throws -> MeetingChunkTranscript
    private var transcribeProgressively: ProgressiveTranscribe?
    private let retryDelay: @Sendable (Int) async throws -> Void
    private let onChange: @MainActor @Sendable () async -> Void
    private(set) var chunks: [MeetingLiveChunk] = []
    private(set) var isWorking = false
    private(set) var waitingForService = false
    private(set) var requiresRetry = false
    private(set) var enabled = true
    var diagnostic: String?
    private var worker: Task<Void, Never>?
    private var retiredWorkers: [UUID: Task<Void, Never>] = [:]
    private var filePartials: [UUID: Set<TranscriptSegmentID>] = [:]
    private var generation = UUID()
    private var selectedServiceID: String?
    /// Continuous live-ASR gate, supplied by the meeting session. While the
    /// gate reports active and the capture is still running, chunks whose
    /// ranges the live domain has not fully covered yet WAIT instead of
    /// paying for a duplicate transcription; on stop/degradation everything
    /// pending becomes eligible and the coverage filters prevent duplicates.
    var liveGate: (@MainActor @Sendable () -> MeetingLiveCoverageGate)?
    var liveCaptureFinished = false

    /// Live coverage only for the capture session it was measured on.
    private func liveCoverage(for session: CaptureSessionID) -> [MediaTimeRange] {
        guard let gate = liveGate?(), gate.active, gate.session == session else { return [] }
        return gate.coverage
    }

    private func liveCovers(_ range: MediaTimeRange, coverage: [MediaTimeRange]) -> Bool {
        let epsilon = 0.001
        guard !coverage.isEmpty else { return false }
        var cursor = range.start
        for interval in coverage.sorted(by: { $0.start < $1.start }) {
            if interval.end + epsilon < cursor { continue }
            if interval.start > cursor + epsilon { return false }
            cursor = max(cursor, interval.end)
            if cursor + epsilon >= range.end { return true }
        }
        return false
    }

    convenience init(meetingID: MeetingID, root: URL, service: MeetingService, audio: AssistantAudioService,
                     onChange: @escaping @MainActor @Sendable () async -> Void) throws {
        try self.init(meetingID: meetingID, root: root, service: service, transcribeChunk: { file, serviceID in
            try await Self.decode(file: file, serviceID: serviceID, audio: audio, relay: nil)
        }, onChange: onChange)
        transcribeProgressively = { file, serviceID, relay in
            try await Self.decode(file: file, serviceID: serviceID, audio: audio, relay: relay)
        }
    }
    private static func decode(file: URL, serviceID: String?, audio: AssistantAudioService,
                               relay: MeetingFilePartialRelay?) async throws -> MeetingChunkTranscript {
        await audio.refreshAvailability()
        let requested = serviceID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let route: String
        if let requested, !requested.isEmpty { route = requested }
        else {
            // The meeting picker's empty selection is the on-device model.
            // Never borrow the global dictation route here: the source choice
            // shown in the meeting is the source actually used.
            guard audio.services.contains(where: {
                $0.id == AssistantAudioService.ID.transcriptionEnhanced && $0.ready
            }) else {
                throw MeetingError.captureBackendFailed(IDELanguageRunText.t("录音已保存。请在会议设置中选择转写服务，再重试未完成片段。", "The recording is saved. Choose a transcription service in meeting settings, then retry unfinished chunks."))
            }
            route = AssistantAudioService.ID.transcriptionEnhanced
        }
        // A silent/non-human gap is a completed observation. Never send it to
        // a recognizer that can hallucinate a plausible video outro or a
        // bracketed sound tag; measured client audio decides.
        guard await MeetingAudioActivity.hasVoice(file: file) else {
            FloeLogger(category: .providers).info("meetingTranscriptionSkipped reason=noVoicedAudio")
            return MeetingChunkTranscript(segments: [], language: nil)
        }
        do {
            // Meetings opt in to provider speaker separation; adapters
            // only send the diarization flag for engines that support it,
            // and local engines honestly return no labels. A cloud failure
            // stays a visible retry instead of silently becoming local text.
            let result = try await audio.transcribe(fileURL: file, language: .automatic, serviceID: route,
                                                    requiresTiming: true, enableSpeakerAttribution: true,
                                                    allowLocalFallback: false,
                                                    onPartial: { relay?.offer($0) })
            return try await transcript(result, from: file)
        } catch AssistantAudioError.noSpeechRecognized {
            // Silence is a completed observation, not a broken recording.
            return MeetingChunkTranscript(segments: [], language: nil)
        }
    }

    /// A text-only cloud service still produced a real transcript. Anchor it
    /// to the measured source interval; do not fabricate word timestamps or
    /// mark the chunk complete while silently discarding the text.
    static func transcript(_ result: AssistantAudioTranscriptionResult, from file: URL) async throws -> MeetingChunkTranscript {
        guard result.segments.isEmpty else {
            return .init(segments: result.segments, language: result.language)
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .init(segments: [], language: result.language) }
        let interval = try await AudioFileProbe.durationRange(file)
        try Task.checkCancellation()
        FloeLogger(category: .providers).info("meetingTranscriptionTiming kind=sourceInterval")
        return .init(segments: [.init(start: interval.start, end: interval.end, text: text, words: [])], language: result.language)
    }

    init(meetingID: MeetingID, root: URL, service: MeetingService,
         transcribeChunk: @escaping TranscribeChunk,
         progressiveTranscribe: ProgressiveTranscribe? = nil,
         retryDelay: @escaping @Sendable (Int) async throws -> Void = { attempt in
             try await Task.sleep(for: .seconds(1 << (attempt - 1)))
         }, onChange: @escaping @MainActor @Sendable () async -> Void) throws {
        self.meetingID = meetingID; self.root = root; self.service = service
        self.transcribeChunk = transcribeChunk; self.transcribeProgressively = progressiveTranscribe
        self.retryDelay = retryDelay; self.onChange = onChange
        let file = root.appendingPathComponent("live-chunks.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= 8 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
            chunks = try JSONDecoder().decode([MeetingLiveChunk].self, from: data)
            for index in chunks.indices where chunks[index].state == .transcribing {
                chunks[index].state = .unconfirmed
                chunks[index].error = IDELanguageRunText.t("上次转写结果尚未确认，可检查后重试。", "The previous transcription is unconfirmed. Check it before retrying.")
            }
            // Any unfinished entry (pending, transcribing, decoded, failed or
            // unconfirmed) is recoverable work. A previous process may have
            // stopped before ever starting a pending chunk; the UI must offer
            // the explicit retry path for it instead of leaving it silent.
            requiresRetry = chunks.contains { $0.state != .complete }
        }
    }
    var pendingCount: Int { chunks.filter { [.pending, .transcribing, .decoded].contains($0.state) }.count }
    var unfinishedCount: Int { chunks.filter { $0.state != .complete }.count }
    var failedCount: Int { chunks.filter { [.failed, .unconfirmed].contains($0.state) }.count }

    func configure(enabled: Bool, serviceID: String?, resumeUnfinished: Bool = false) {
        self.enabled = enabled; selectedServiceID = serviceID
        // Opening/reconstructing an editor only restores configuration.
        // New native chunks or an explicit Retry own execution intent.
        if !enabled { cancel() }
        else if resumeUnfinished { retryUnfinished() }
    }
    func enqueue(session: CaptureSessionID, file: URL, range: MediaTimeRange) {
        do {
            let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
                  resolved.pathExtension == "m4a", (try resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
            let relative = String(resolved.path.dropFirst(root.resolvingSymlinksInPath().path.count + 1))
            guard !chunks.contains(where: { $0.file == relative }) else { return }
            guard chunks.count < 10_000 else { throw PersonalContentError.invalidProject }
            chunks.append(.init(originalSessionID: session, file: relative, range: range))
            try save(); startWorker()
        } catch { diagnostic = error.localizedDescription }
    }
    func originalSession(for analysis: CaptureSessionID) -> CaptureSessionID? {
        chunks.first(where: { $0.analysisSessionID == analysis })?.originalSessionID
    }
    func retryUnfinished() {
        guard worker == nil else { return }
        for index in chunks.indices where [.failed, .unconfirmed].contains(chunks[index].state) {
            chunks[index].state = chunks[index].decoded == nil ? .pending : .decoded
            chunks[index].error = nil
            chunks[index].busyRetries = nil
        }
        do {
            try save(); enabled = true; requiresRetry = false; diagnostic = nil; startWorker()
        } catch { requiresRetry = true; diagnostic = error.localizedDescription }
    }
    func cancel() {
        enabled = false
        generation = UUID()
        if let previous = worker {
            let retired = UUID(); retiredWorkers[retired] = previous
            previous.cancel()
            Task { [weak self] in
                await previous.value
                self?.retiredWorkers[retired] = nil
            }
        }
        worker = nil; isWorking = false; waitingForService = false
        for index in chunks.indices where chunks[index].state == .transcribing {
            chunks[index].state = .unconfirmed
            chunks[index].error = IDELanguageRunText.t("转写已停止，原录音与片段已保留。", "Transcription stopped. The recording and chunks were preserved.")
        }
        try? save()
    }
    func cancelAndWait() async {
        var previous = Array(retiredWorkers.values)
        if let worker { previous.append(worker) }
        cancel()
        for task in previous { await task.value }
    }
    func waitUntilIdle() async { await worker?.value }

    /// The live domain committed new coverage (or the capture ended): pending
    /// chunks may have become eligible. Cheap re-entry; the worker guards.
    func reevaluate() {
        startWorker()
    }

    private func firstEligibleChunkIndex() -> Int? {
        chunks.firstIndex { chunk in
            guard [.pending, .decoded].contains(chunk.state) else { return false }
            guard let gate = liveGate?(), gate.active, !liveCaptureFinished,
                  gate.session == chunk.originalSessionID else { return true }
            // Live is healthy for THIS original and the capture is running:
            // wait until the live domain fully covers this chunk (or the
            // capture stops). Older/paused sessions are never covered by the
            // current live timeline.
            return liveCovers(chunk.range, coverage: gate.coverage)
        }
    }

    private func startWorker() {
        guard enabled, !requiresRetry, worker == nil, firstEligibleChunkIndex() != nil else { return }
        generation = UUID(); let epoch = generation
        isWorking = true
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == epoch { self.worker = nil; self.isWorking = false; self.waitingForService = false }
            }
            while !Task.isCancelled, self.generation == epoch,
                  let index = self.firstEligibleChunkIndex() {
                let id = self.chunks[index].id
                do {
                    try await self.process(id: id, generation: epoch)
                    await self.retireFilePartials(epoch)
                    await self.onChange()
                } catch is CancellationError { await self.retireFilePartials(epoch); return }
                catch {
                    await self.retireFilePartials(epoch)
                    guard self.generation == epoch, let failed = self.chunks.firstIndex(where: { $0.id == id }) else { return }
                    if (error as? AssistantAudioError) == .transcriptionBusy,
                       (self.chunks[failed].busyRetries ?? 0) < 3 {
                        let attempt = (self.chunks[failed].busyRetries ?? 0) + 1
                        self.chunks[failed].busyRetries = attempt
                        self.chunks[failed].state = .pending
                        self.waitingForService = true
                        do {
                            try self.save()
                            await self.onChange()
                            try await self.retryDelay(attempt)
                            try self.check(epoch)
                            self.waitingForService = false
                            continue
                        } catch is CancellationError { return }
                        catch {
                            self.requiresRetry = true; self.diagnostic = error.localizedDescription
                            return
                        }
                    }
                    self.chunks[failed].state = .failed; self.chunks[failed].error = error.localizedDescription
                    self.requiresRetry = true
                    FloeLogger(category: .providers).warning("meetingTranscriptionQueue state=needsRetry code=\((error as NSError).code)")
                    self.diagnostic = error.localizedDescription; try? self.save()
                    await self.onChange()
                    // Retain the rest on disk. Missing configuration/busy
                    // local models cannot produce a cascade of fake results.
                    return
                }
            }
        }
    }
    /// Process one chunk against the real coverage of ITS original:
    /// - fully covered (live rows, file rows, or live coverage) → complete
    ///   with no provider request;
    /// - fully uncovered → one ordinary request for the chunk file;
    /// - partially covered → one request per REAL uncovered audio interval
    ///   (decoded from the chunk), never a proportionally cut sentence.
    private func process(id: UUID, generation epoch: UUID) async throws {
        guard var index = chunks.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
        let plan = try await fallbackPlan(for: chunks[index])
        guard !plan.requests.isEmpty else {
            chunks[index].state = .complete
            chunks[index].error = nil
            try save()
            return
        }
        let whole = plan.requests.count == 1
            && abs(plan.requests[0].range.start - chunks[index].range.start) < 0.001
            && abs(plan.requests[0].range.end - chunks[index].range.end) < 0.001
        var droppedSilentSegments = 0
        let file = root.appendingPathComponent(chunks[index].file).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw PersonalContentError.outsideLibrary }
        if chunks[index].analysisSessionID == nil {
            let existing = try await service.sessions(meeting: meetingID).first { $0.sourceFile == file.path && $0.kind == .importedAudio }
            let imported = if let existing { existing.id } else {
                // The analysis session is explicitly linked to its original:
                // the trusted lineage that scopes all duplicate detection.
                try await service.importFile(meeting: meetingID, file: file, kind: .importedAudio,
                    origin: chunks[index].originalSessionID, duration: AudioFileProbe.durationRange)
            }
            try check(epoch)
            index = chunks.firstIndex(where: { $0.id == id })!
            chunks[index].analysisSessionID = imported; try save()
        }
        if whole {
            if chunks[index].decoded == nil {
                chunks[index].state = .transcribing
                chunks[index].serviceID = selectedServiceID ?? AssistantAudioService.ID.transcriptionEnhanced
                // A new provider request begins here: mint its binding scope
                // now so this attempt's speaker labels live in their own
                // domain even when a previous attempt of the same chunk ran.
                chunks[index].requestKey = UUID()
                try save()
                let result = try await decodeChunk(file, analysis: chunks[index].analysisSessionID!, epoch: epoch)
                try check(epoch); index = chunks.firstIndex(where: { $0.id == id })!
                chunks[index].decoded = result.segments; chunks[index].language = result.language
                chunks[index].state = .decoded; try save() // Persist real provider output BEFORE committing segments.
            }
        }
        let item = chunks[index]
        guard let analysis = item.analysisSessionID else { throw PersonalContentError.invalidProject }
        // Duplicate fence scoped to THIS original's lineage (never the whole
        // meeting): an overlapping range is already durable — live coverage,
        // a completed chunk, or a user-corrected row — and is never
        // duplicated or overwritten here.
        let lineageRows = try await service.committedSegments(meeting: meetingID, original: item.originalSessionID)
        let coverage = liveCoverage(for: item.originalSessionID)
        func overlapsCommitted(_ start: Double, _ end: Double) -> Bool {
            let epsilon = 0.001
            return lineageRows.contains { $0.range.end > start + epsilon && $0.range.start < end - epsilon }
                || coverage.contains { $0.end > start + epsilon && $0.start < end - epsilon }
        }
        if whole {
            guard let decoded = item.decoded else { throw PersonalContentError.invalidProject }
            let voice = decoded.isEmpty
                ? nil : await MeetingAudioActivity.profile(file: file)
            for segment in decoded {
                try check(epoch)
                let start = item.range.start + max(0, segment.start)
                let end = min(item.range.end, item.range.start + segment.end)
                guard start.isFinite, end.isFinite, end > start,
                      !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                // A provider can place a plausible sentence in a silent tail
                // of an otherwise non-silent chunk. The client's own measured
                // speech profile decides whether this exact range has voice.
                guard Self.segmentHasVoice(segment, profile: voice) else {
                    droppedSilentSegments += 1
                    continue
                }
                let range = try MediaTimeRange(start: start, end: end)
                if overlapsCommitted(start, end) { continue }
                // Provider speaker labels restart on every request. Bind them
                // in THIS request's domain only: the same number from another
                // chunk or a retry is a different person until the user merges.
                let scope = segment.recognitionRequestID?.uuidString ?? item.requestKey?.uuidString ?? analysis.description
                let speaker = try await service.resolveEngineSpeaker(
                    meeting: meetingID, scope: scope, label: segment.speaker)
                _ = try await service.appendFinal(meeting: meetingID, session: analysis, text: segment.text, range: range, speaker: speaker, language: item.language)
            }
        } else {
            // Partial coverage: request only the real uncovered audio. A
            // retry after a failure naturally shrinks to the still-open gaps
            // because committed rows join the reserved map.
            for request in plan.requests {
                try check(epoch)
                index = chunks.firstIndex(where: { $0.id == id })!
                chunks[index].state = .transcribing
                chunks[index].serviceID = selectedServiceID ?? AssistantAudioService.ID.transcriptionEnhanced
                chunks[index].requestKey = UUID()
                try save()
                let result: MeetingChunkTranscript
                do {
                    result = try await decodeChunk(request.url, analysis: analysis, epoch: epoch)
                } catch {
                    try? FileManager.default.removeItem(at: request.url)
                    throw error
                }
                let voice = result.segments.isEmpty
                    ? nil : await MeetingAudioActivity.profile(file: request.url)
                try? FileManager.default.removeItem(at: request.url)
                try check(epoch); index = chunks.firstIndex(where: { $0.id == id })!
                for segment in result.segments {
                    let start = request.range.start + max(0, segment.start)
                    let end = min(request.range.end, request.range.start + segment.end)
                    guard start.isFinite, end.isFinite, end > start,
                          !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                    guard Self.segmentHasVoice(segment, profile: voice) else {
                        droppedSilentSegments += 1
                        continue
                    }
                    let range = try MediaTimeRange(start: start, end: end)
                    if overlapsCommitted(start, end) { continue }
                    let scope = segment.recognitionRequestID?.uuidString ?? chunks[index].requestKey?.uuidString ?? analysis.description
                    let speaker = try await service.resolveEngineSpeaker(
                        meeting: meetingID, scope: scope, label: segment.speaker)
                    _ = try await service.appendFinal(meeting: meetingID, session: analysis, text: segment.text, range: range, speaker: speaker, language: result.language)
                }
            }
            index = chunks.firstIndex(where: { $0.id == id })!
            chunks[index].decoded = nil
        }
        try check(epoch); index = chunks.firstIndex(where: { $0.id == id })!
        chunks[index].state = .complete; chunks[index].error = nil; try save()
        diagnostic = nil
        if droppedSilentSegments > 0 {
            FloeLogger(category: .providers).info(
                "meetingTranscriptionDroppedSilentSegments count=\(droppedSilentSegments)")
        }
    }

    private static func segmentHasVoice(
        _ segment: TimedSpeechSegment,
        profile: MeetingVoiceProfile?
    ) -> Bool {
        // Unreadable audio keeps the provider result; the real error must
        // surface instead of being misclassified as silence.
        guard let profile else { return true }
        return profile.hasVoice(
            start: segment.start, end: segment.end, margin: 0.2)
    }

    /// Decoder revisions replace one RAM-only partial. The bounded relay
    /// never queues one task per token, invents timestamps or persists drafts.
    private func decodeChunk(_ file: URL, analysis: CaptureSessionID, epoch: UUID) async throws -> MeetingChunkTranscript {
        guard let transcribeProgressively else { return try await transcribeChunk(file, selectedServiceID) }
        await retireFilePartials(epoch)
        let partial = try await service.beginPartial(meeting: meetingID, session: analysis, text: "")
        filePartials[epoch, default: []].insert(partial)
        let relay = MeetingFilePartialRelay()
        let observer = Task { [weak self, service, meetingID] in
            for await text in relay.stream {
                guard !Task.isCancelled, self?.generation == epoch else { break }
                await service.updatePartial(partial, meeting: meetingID, text: text)
            }
        }
        do {
            try check(epoch)
            let result = try await transcribeProgressively(file, selectedServiceID, relay)
            relay.finish(); await observer.value
            // Keep this draft until process() has durably committed the real
            // timed result. Readers never see a blank between partial/final.
            try check(epoch)
            return result
        } catch {
            relay.finish(); observer.cancel(); await observer.value
            await retireFilePartials(epoch)
            throw error
        }
    }
    private func retireFilePartials(_ epoch: UUID) async {
        let ids = filePartials.removeValue(forKey: epoch) ?? []
        for id in ids { await service.discardPartial(id, meeting: meetingID) }
    }
    private func check(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard generation == epoch, FileManager.default.fileExists(atPath: root.appendingPathComponent("meeting.sqlite").path) else { throw CancellationError() }
    }
}
/// One exact decode's bounded, thread-safe text channel; SDK callbacks can
/// arrive off-main. Finishing retires the channel before the partial is removed.
final class MeetingFilePartialRelay: Sendable {
    let stream: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    init() {
        let pair = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    func offer(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty, value.utf8.count <= 65_536 { continuation.yield(value) }
    }
    func finish() { continuation.finish() }
}

/// One file entry in the chunk queue: the file at `url` is a bounded WAV of
/// the exact uncovered media interval `range` (a partial-coverage fallback
/// request), never proportional text cutting.
private struct MeetingSubrangeRequest {
    let url: URL
    let range: MediaTimeRange
}

/// Fallback work item for one gap of one chunk.
private struct MeetingChunkTranscriptPlan {
    /// Requests in media order; a single request equal to the whole chunk
    /// range when nothing is covered.
    let requests: [MeetingSubrangeRequest]
}

extension MeetingLiveTranscription {
    private func save() throws {
        let data = try JSONEncoder().encode(chunks)
        guard data.count <= 8 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
        try data.write(to: root.appendingPathComponent("live-chunks.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    /// Real fallback plan: the chunk's range minus everything already durable
    /// for THIS original (committed rows of its lineage plus live coverage).
    /// Only real uncovered audio is ever requested; text is never cut.
    private func fallbackPlan(for item: MeetingLiveChunk) async throws -> MeetingChunkTranscriptPlan {
        let lineageRows = try await service.committedSegments(meeting: meetingID, original: item.originalSessionID)
        var reserved = MeetingCoverageMap()
        for row in lineageRows { try? reserved.commit(row.range) }
        for span in liveCoverage(for: item.originalSessionID) { try? reserved.commit(span) }
        let gaps = reserved.uncoveredSubranges(of: item.range)
        guard !gaps.isEmpty else { return MeetingChunkTranscriptPlan(requests: []) }
        if gaps.count == 1, abs(gaps[0].start - item.range.start) < 0.001,
           abs(gaps[0].end - item.range.end) < 0.001 {
            let file = root.appendingPathComponent(item.file).standardizedFileURL.resolvingSymlinksInPath()
            return MeetingChunkTranscriptPlan(requests: [MeetingSubrangeRequest(url: file, range: item.range)])
        }
        // Sub-range requests against the real uncovered audio.
        var requests: [MeetingSubrangeRequest] = []
        let directory = root.appendingPathComponent(".live-subranges")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for gap in gaps where gap.duration >= 0.3 {
            let target = directory.appendingPathComponent("\(item.id.uuidString)-\(Int(gap.start * 1000))-\(Int(gap.end * 1000)).wav")
            do {
                // Chunk files start at local zero; the request retains its
                // original media coordinate for adopting provider timings.
                let local = try MediaTimeRange(
                    start: gap.start - item.range.start,
                    end: gap.end - item.range.start)
                try await MeetingChunkSubrangeExtractor.extractWAV(
                    file: root.appendingPathComponent(item.file), range: local, to: target)
                requests.append(MeetingSubrangeRequest(url: target, range: gap))
            } catch {
                try? FileManager.default.removeItem(at: target)
                for request in requests { try? FileManager.default.removeItem(at: request.url) }
                // Propagate into the existing queue failure/retry path.
                // An extraction failure never means the real gap is covered.
                throw error
            }
        }
        return MeetingChunkTranscriptPlan(requests: requests)
    }
}

/// One chunk/file's measured speech activity in 50 ms windows. The profile is
/// used for two separate decisions: whether to call a recognizer at all, and
/// whether a provider segment actually covers real speech. A segment placed
/// in a silent tail can then be dropped even when another part of the chunk
/// contained speech — the exact shape of repeated video-outro hallucinations.
struct MeetingVoiceProfile: Sendable, Equatable {
    static let windowSeconds = 0.05
    let windows: [Bool]
    let duration: Double

    func hasVoice(start: Double, end: Double, margin: Double = 0.2) -> Bool {
        voicedWindowCount(start: start, end: end, margin: margin) > 0
    }

    func voicedWindowCount(start: Double, end: Double, margin: Double = 0.2) -> Int {
        guard !windows.isEmpty, duration > 0,
              start.isFinite, end.isFinite, margin.isFinite else { return 0 }
        let lower = max(0, min(duration, start - margin))
        let upper = max(lower, min(duration, max(start, end) + margin))
        let first = max(0, Int((lower / Self.windowSeconds).rounded(.down)))
        let last = min(windows.count - 1,
                       Int((upper / Self.windowSeconds).rounded(.up)) - 1)
        guard first <= last else { return 0 }
        return windows[first...last].reduce(0) { $0 + ($1 ? 1 : 0) }
    }
}

/// Client-side speech activity. This is deliberately only an energy/voiced
/// duration gate: it prevents an empty or silent input from reaching a model
/// that can hallucinate a plausible sentence, while a real short or quiet
/// utterance above the shared voice gate is retained.
enum MeetingAudioActivity {
    static let voicedRMS: Float = 0.002
    static let minimumVoicedSamples = 1_600 // 0.1 s at 16 kHz
    static let minimumVoicedWindows = 2 // two 50 ms windows
    static let windowSamples = 800 // 50 ms at 16 kHz

    static func hasVoice(samples: [Float]) -> Bool {
        guard !samples.isEmpty else { return false }
        var voiced = 0
        var offset = 0
        while offset < samples.count {
            let end = min(samples.count, offset + windowSamples)
            var energy: Float = 0
            for index in offset..<end {
                let value = samples[index]
                if value.isFinite { energy += value * value }
            }
            let count = end - offset
            if count > 0, (energy / Float(count)).squareRoot() >= voicedRMS {
                voiced += count
                if voiced >= minimumVoicedSamples { return true }
            }
            offset = end
        }
        return false
    }

    /// Speech activity for one bounded chunk. Unreadable files return `true`
    /// so the ordinary transcription error surfaces instead of being
    /// misreported as silence.
    static func hasVoice(file: URL) async -> Bool {
        guard let profile = await profile(file: file, maximumDuration: 120) else {
            return true
        }
        return profile.voicedWindowCount(
            start: 0, end: profile.duration, margin: 0) >= minimumVoicedWindows
    }

    /// Streaming 50 ms voice profile. `nil` means the audio could not be
    /// inspected or exceeds the bound; callers must not silently treat that
    /// as silence.
    static func profile(file: URL, maximumDuration: Double = 4 * 3_600) async -> MeetingVoiceProfile? {
        let asset = AVURLAsset(url: file)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0, duration <= maximumDuration,
              let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            return nil
        }
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        var carry: [Float] = []
        var windows: [Bool] = []
        var totalSamples = 0
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sample) }
            let count = CMSampleBufferGetNumSamples(sample)
            guard count > 0, count <= 400_000,
                  let block = CMSampleBufferGetDataBuffer(sample),
                  CMBlockBufferGetDataLength(block) == count * MemoryLayout<Float>.size else { continue }
            var values = [Float](repeating: 0, count: count)
            let status = values.withUnsafeMutableBytes { bytes in
                CMBlockBufferCopyDataBytes(block, atOffset: 0,
                    dataLength: bytes.count, destination: bytes.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            totalSamples += count
            carry.append(contentsOf: values)
            var offset = 0
            while offset + windowSamples <= carry.count {
                var energy: Float = 0
                for index in offset..<(offset + windowSamples) {
                    let value = carry[index]
                    if value.isFinite { energy += value * value }
                }
                windows.append((energy / Float(windowSamples)).squareRoot() >= voicedRMS)
                offset += windowSamples
            }
            if offset > 0 { carry = Array(carry[offset...]) }
        }
        guard reader.status != .failed else { return nil }
        if !carry.isEmpty {
            var energy: Float = 0
            for value in carry where value.isFinite { energy += value * value }
            windows.append((energy / Float(carry.count)).squareRoot() >= voicedRMS)
        }
        return MeetingVoiceProfile(
            windows: windows,
            duration: Double(totalSamples) / 16_000)
    }
}

/// Decode one chunk's audio track and write the exact [range) media span as
/// a bounded 16 kHz mono PCM WAV — the audio-level complement of the
/// coverage map: partial coverage produces a request for the real uncovered
/// samples, never a proportionally cut sentence.
enum MeetingChunkSubrangeExtractor {
    static func extractWAV(file: URL, range: MediaTimeRange, to output: URL) async throws {
        let asset = AVURLAsset(url: file)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw PersonalContentError.invalidProject }
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(readerOutput) else { throw PersonalContentError.invalidProject }
        reader.add(readerOutput)
        guard reader.startReading() else { throw PersonalContentError.invalidProject }
        defer { reader.cancelReading() }
        var pcm = Data()
        let startByte = Int(range.start * 16_000) * 2
        let endByte = Int(range.end * 16_000) * 2
        var offset = 0
        while reader.status == .reading {
            guard let sample = readerOutput.copyNextSampleBuffer() else { break }
            defer { CMSampleBufferInvalidate(sample) }
            let data = try CloudASRAudioExtractor.pcm16Data(from: sample)
            let sliceStart = max(0, startByte - offset)
            let sliceEnd = min(data.count, endByte - offset)
            if sliceEnd > sliceStart { pcm.append(data[sliceStart..<sliceEnd]) }
            offset += data.count
            if offset >= endByte { break }
        }
        guard reader.status != .failed, pcm.count >= 2 else { throw PersonalContentError.invalidProject }
        try CloudPCMCodec.wav(pcm16: pcm, sampleRate: 16_000).write(to: output, options: .atomic)
    }
}
#endif
