// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
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
}

struct MeetingChunkTranscript: Sendable {
    let segments: [TimedSpeechSegment]
    let language: String?
}

/// Disk-backed work queue owned by the meeting service/session, not a View.
/// One ASR request at a time; completed results survive stop and navigation.
@MainActor @Observable final class MeetingLiveTranscription {
    let meetingID: MeetingID
    let root: URL
    private let service: MeetingService
    typealias TranscribeChunk = @MainActor @Sendable (URL, String?) async throws -> MeetingChunkTranscript
    private let transcribeChunk: TranscribeChunk
    private let retryDelay: @Sendable (Int) async throws -> Void
    private let onChange: @MainActor @Sendable () async -> Void
    private(set) var chunks: [MeetingLiveChunk] = []
    private(set) var isWorking = false
    private(set) var waitingForService = false
    private(set) var requiresRetry = false
    private(set) var enabled = true
    var diagnostic: String?
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var selectedServiceID: String?

    convenience init(meetingID: MeetingID, root: URL, service: MeetingService, audio: AssistantAudioService,
                     onChange: @escaping @MainActor @Sendable () async -> Void) throws {
        try self.init(meetingID: meetingID, root: root, service: service, transcribeChunk: { file, serviceID in
            await audio.refreshAvailability()
            let route: String
            if let serviceID, !serviceID.isEmpty { route = serviceID }
            else {
                guard audio.services.contains(where: { $0.id == AssistantAudioService.ID.transcriptionEnhanced && $0.ready }) else {
                    throw MeetingError.captureBackendFailed(IDELanguageRunText.t("录音已保存。请在会议设置中选择转写服务，再重试未完成片段。", "The recording is saved. Choose a transcription service in meeting settings, then retry unfinished chunks."))
                }
                route = AssistantAudioService.ID.transcriptionEnhanced
            }
            do {
                let result = try await audio.transcribe(fileURL: file, language: .automatic, serviceID: route, requiresTiming: true)
                return MeetingChunkTranscript(segments: result.segments, language: result.language)
            } catch AssistantAudioError.noSpeechRecognized {
                // Silence is a completed observation, not a broken recording.
                return MeetingChunkTranscript(segments: [], language: nil)
            }
        }, onChange: onChange)
    }

    init(meetingID: MeetingID, root: URL, service: MeetingService,
         transcribeChunk: @escaping TranscribeChunk,
         retryDelay: @escaping @Sendable (Int) async throws -> Void = { attempt in
             try await Task.sleep(for: .seconds(1 << (attempt - 1)))
         }, onChange: @escaping @MainActor @Sendable () async -> Void) throws {
        self.meetingID = meetingID; self.root = root; self.service = service
        self.transcribeChunk = transcribeChunk; self.retryDelay = retryDelay; self.onChange = onChange
        let file = root.appendingPathComponent("live-chunks.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= 8 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
            chunks = try JSONDecoder().decode([MeetingLiveChunk].self, from: data)
            for index in chunks.indices where chunks[index].state == .transcribing {
                chunks[index].state = .unconfirmed
                chunks[index].error = IDELanguageRunText.t("上次转写结果尚未确认，可检查后重试。", "The previous transcription is unconfirmed. Check it before retrying.")
            }
            requiresRetry = chunks.contains { [.failed, .unconfirmed].contains($0.state) }
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
        generation = UUID(); worker?.cancel(); worker = nil; isWorking = false; waitingForService = false
        for index in chunks.indices where chunks[index].state == .transcribing {
            chunks[index].state = .unconfirmed
            chunks[index].error = IDELanguageRunText.t("转写已停止，原录音与片段已保留。", "Transcription stopped. The recording and chunks were preserved.")
        }
        try? save()
    }
    func cancelAndWait() async {
        let previous = worker
        cancel()
        await previous?.value
    }
    func waitUntilIdle() async { await worker?.value }
    private func startWorker() {
        guard enabled, !requiresRetry, worker == nil, chunks.contains(where: { [.pending, .decoded].contains($0.state) }) else { return }
        generation = UUID(); let epoch = generation
        isWorking = true
        worker = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == epoch { self.worker = nil; self.isWorking = false; self.waitingForService = false }
            }
            while !Task.isCancelled, self.generation == epoch,
                  let index = self.chunks.firstIndex(where: { [.pending, .decoded].contains($0.state) }) {
                let id = self.chunks[index].id
                do {
                    try await self.process(id: id, generation: epoch)
                    await self.onChange()
                } catch is CancellationError { return }
                catch {
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
                    self.diagnostic = error.localizedDescription; try? self.save()
                    await self.onChange()
                    // Retain the rest on disk. Missing configuration/busy
                    // local models cannot produce a cascade of fake results.
                    return
                }
            }
        }
    }
    private func process(id: UUID, generation epoch: UUID) async throws {
        guard var index = chunks.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
        let file = root.appendingPathComponent(chunks[index].file).standardizedFileURL.resolvingSymlinksInPath()
        guard file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw PersonalContentError.outsideLibrary }
        if chunks[index].analysisSessionID == nil {
            let existing = try await service.sessions(meeting: meetingID).first { $0.sourceFile == file.path && $0.kind == .importedAudio }
            let imported = if let existing { existing.id } else {
                try await service.importFile(meeting: meetingID, file: file, kind: .importedAudio, duration: AudioFileProbe.durationRange)
            }
            try check(epoch)
            index = chunks.firstIndex(where: { $0.id == id })!
            chunks[index].analysisSessionID = imported; try save()
        }
        if chunks[index].decoded == nil {
            chunks[index].state = .transcribing
            chunks[index].serviceID = selectedServiceID ?? AssistantAudioService.ID.transcriptionEnhanced
            try save()
            let result = try await transcribeChunk(file, selectedServiceID)
            try check(epoch); index = chunks.firstIndex(where: { $0.id == id })!
            chunks[index].decoded = result.segments; chunks[index].language = result.language
            chunks[index].state = .decoded; try save() // Persist real provider output BEFORE committing segments.
        }
        let item = chunks[index]
        guard let analysis = item.analysisSessionID, let decoded = item.decoded else { throw PersonalContentError.invalidProject }
        var existing = try await service.transcript(meeting: meetingID).filter { $0.sessionID == analysis }
        for segment in decoded {
            try check(epoch)
            let start = item.range.start + max(0, segment.start)
            let end = min(item.range.end, item.range.start + segment.end)
            guard start.isFinite, end.isFinite, end > start, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let range = try MediaTimeRange(start: start, end: end)
            // Reopen/retry never duplicates an already committed segment or
            // overwrites a later user correction.
            if existing.contains(where: { abs($0.range.start - start) < 0.00001 && abs($0.range.end - end) < 0.00001 }) { continue }
            existing.append(try await service.appendFinal(meeting: meetingID, session: analysis, text: segment.text, range: range, language: item.language))
        }
        try check(epoch); index = chunks.firstIndex(where: { $0.id == id })!
        chunks[index].state = .complete; chunks[index].error = nil; try save()
        diagnostic = nil
    }
    private func check(_ epoch: UUID) throws {
        try Task.checkCancellation()
        guard generation == epoch, FileManager.default.fileExists(atPath: root.appendingPathComponent("meeting.sqlite").path) else { throw CancellationError() }
    }
    private func save() throws {
        let data = try JSONEncoder().encode(chunks)
        guard data.count <= 8 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
        try data.write(to: root.appendingPathComponent("live-chunks.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
#endif
