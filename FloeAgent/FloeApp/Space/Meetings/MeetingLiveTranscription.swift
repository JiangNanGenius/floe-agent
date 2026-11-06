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
}

/// Disk-backed work queue owned by the meeting service/session, not a View.
/// One ASR request at a time; completed results survive stop and navigation.
@MainActor @Observable final class MeetingLiveTranscription {
    let meetingID: MeetingID
    let root: URL
    private let service: MeetingService
    private let audio: AssistantAudioService
    private let onChange: @MainActor @Sendable () async -> Void
    private(set) var chunks: [MeetingLiveChunk] = []
    private(set) var isWorking = false
    var diagnostic: String?
    private var worker: Task<Void, Never>?
    private var generation = UUID()
    private var selectedServiceID: String?
    private var enabled = true

    init(meetingID: MeetingID, root: URL, service: MeetingService, audio: AssistantAudioService,
         onChange: @escaping @MainActor @Sendable () async -> Void) throws {
        self.meetingID = meetingID; self.root = root; self.service = service; self.audio = audio; self.onChange = onChange
        let file = root.appendingPathComponent("live-chunks.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            guard data.count <= 8 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
            chunks = try JSONDecoder().decode([MeetingLiveChunk].self, from: data)
            for index in chunks.indices where chunks[index].state == .transcribing {
                chunks[index].state = .unconfirmed
                chunks[index].error = IDELanguageRunText.t("上次转写结果尚未确认，可检查后重试。", "The previous transcription is unconfirmed. Check it before retrying.")
            }
        }
    }
    func configure(enabled: Bool, serviceID: String?) {
        self.enabled = enabled; selectedServiceID = serviceID
        // Opening/reconstructing an editor only restores configuration.
        // New native chunks or an explicit Retry own execution intent.
        if !enabled { cancel() }
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
        for index in chunks.indices where [.failed, .unconfirmed].contains(chunks[index].state) {
            chunks[index].state = chunks[index].decoded == nil ? .pending : .decoded
            chunks[index].error = nil
        }
        do { try save(); enabled = true; startWorker() } catch { diagnostic = error.localizedDescription }
    }
    func cancel() {
        enabled = false
        generation = UUID(); worker?.cancel(); worker = nil; isWorking = false
        for index in chunks.indices where chunks[index].state == .transcribing {
            chunks[index].state = .unconfirmed
            chunks[index].error = IDELanguageRunText.t("转写已停止，原录音与片段已保留。", "Transcription stopped. The recording and chunks were preserved.")
        }
        try? save()
    }
    private func startWorker() {
        guard enabled, worker == nil, chunks.contains(where: { [.pending, .decoded].contains($0.state) }) else { return }
        generation = UUID(); let epoch = generation
        isWorking = true
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == epoch { self.worker = nil; self.isWorking = false } }
            while !Task.isCancelled, self.generation == epoch,
                  let index = self.chunks.firstIndex(where: { [.pending, .decoded].contains($0.state) }) {
                let id = self.chunks[index].id
                do {
                    try await self.process(id: id, generation: epoch)
                    await self.onChange()
                } catch is CancellationError { return }
                catch {
                    guard self.generation == epoch, let failed = self.chunks.firstIndex(where: { $0.id == id }) else { return }
                    self.chunks[failed].state = .failed; self.chunks[failed].error = error.localizedDescription
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
            await audio.refreshAvailability(); try check(epoch)
            let route: String
            if let selectedServiceID, !selectedServiceID.isEmpty { route = selectedServiceID }
            else {
                guard audio.services.contains(where: { $0.id == AssistantAudioService.ID.transcriptionEnhanced && $0.ready }) else {
                    throw MeetingError.captureBackendFailed(IDELanguageRunText.t("录音已保存。请在会议设置中选择转写服务，再重试未完成片段。", "The recording is saved. Choose a transcription service in meeting settings, then retry unfinished chunks."))
                }
                route = AssistantAudioService.ID.transcriptionEnhanced
            }
            chunks[index].state = .transcribing; chunks[index].serviceID = route; try save()
            let result = try await audio.transcribe(fileURL: file, language: .automatic, serviceID: route, requiresTiming: true)
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
