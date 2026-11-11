// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import AVFoundation
import Observation
import FloeMeetings
import FloeMeetingsAV
#if canImport(SpeakerKit)
@preconcurrency import SpeakerKit
#endif

struct MeetingNativeSpeakerResult: Sendable {
    struct Span: Sendable { let start: Double; let end: Double; let label: Int }
    let spans: [Span]
    let centroids: [Int: [Float]]
}

/// One native inference at a time, separate from ASR selection. No microphone
/// or transcription is created here, and no SDK download route is enabled.
actor MeetingNativeSpeakerEngine {
    static let shared = MeetingNativeSpeakerEngine()
    enum Failure: Error { case busy, unavailable }
    private var busy = false
    #if canImport(SpeakerKit)
    private var model: SpeakerKit?
    #endif
    func recognize(_ audio: [Float]) async throws -> MeetingNativeSpeakerResult {
        guard !busy else { throw Failure.busy }
        guard (12_800...400_000).contains(audio.count), audio.allSatisfy(\.isFinite) else { throw Failure.unavailable }
        busy = true; defer { busy = false }
        #if canImport(SpeakerKit)
        if model == nil {
            let folder = try await MeetingSpeakerModelStore.shared.readyFolder()
            model = try await SpeakerKit(PyannoteConfig(modelFolder: folder.path, download: false, load: true,
                verbose: false, concurrentSegmenterWorkers: 1, concurrentEmbedderWorkers: 1))
        }
        try Task.checkCancellation()
        guard let model else { throw Failure.unavailable }
        let output = try await model.diarize(audioArray: audio,
            options: PyannoteDiarizationOptions(useExclusiveReconciliation: true, centroidSource: .trainableOnly))
        try Task.checkCancellation()
        let duration = Double(audio.count) / 16_000
        let spans = output.segments.compactMap { span -> MeetingNativeSpeakerResult.Span? in
            guard let label = span.speaker.speakerId,
                  span.startTime.isFinite, span.endTime.isFinite else { return nil }
            let start = max(0, Double(span.startTime)), end = min(duration, Double(span.endTime))
            guard end > start else { return nil }
            return .init(start: start, end: end, label: label)
        }
        return MeetingNativeSpeakerResult(spans: spans, centroids: output.speakerCentroidEmbeddings)
        #else
        throw Failure.unavailable
        #endif
    }
}

/// Service-owned, restartable attribution of the SAME finalized PCM chunks.
/// Text is never held waiting for diarization. Only small file references,
/// measured spans and recording-local centroids are checkpointed here.
@MainActor @Observable final class MeetingSpeakerRecognition {
    struct Part: Codable, Sendable, Hashable {
        let original: CaptureSessionID
        let file: String
        let range: MediaTimeRange
        let sourceStart: Double?
        init(original: CaptureSessionID, file: String, range: MediaTimeRange, sourceStart: Double? = nil) {
            self.original = original; self.file = file; self.range = range; self.sourceStart = sourceStart
        }
    }
    struct Window: Codable, Sendable {
        let range: MediaTimeRange
        let spans: [RecordingSpeakerSpan]
    }
    struct Recording: Codable, Sendable {
        var identity: RecordingSpeakerIdentity
        var windows: [Window] = []
    }
    private struct State: Codable { var recordings: [Recording] = []; var pending: [Part] = [] }
    private let meeting: MeetingID
    private let root: URL
    private let service: MeetingService
    private let onChange: @MainActor @Sendable () async -> Void
    private var state: State
    private var sealed: Set<CaptureSessionID>
    private var worker: Task<Void, Never>?
    private var epoch = UUID()
    private var seenRows: [TranscriptSegmentID: String] = [:]
    private(set) var diagnostic: String?
    private(set) var isWorking = false
    private(set) var modelStatus: MeetingSpeakerModelStore.Status = .absent

    init(meeting: MeetingID, root: URL, service: MeetingService,
         onChange: @escaping @MainActor @Sendable () async -> Void) throws {
        self.meeting = meeting; self.root = root; self.service = service; self.onChange = onChange
        let checkpoint = root.appendingPathComponent("recording-speakers.json")
        let restored: State
        if FileManager.default.fileExists(atPath: checkpoint.path) {
            let values = try checkpoint.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 16 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
            restored = try JSONDecoder().decode(State.self, from: Data(contentsOf: checkpoint))
            guard restored.pending.count <= 4096, restored.recordings.count <= 2048,
                  restored.recordings.allSatisfy({ $0.identity.meeting == meeting && $0.windows.count <= 100_000 }) else { throw PersonalContentError.invalidProject }
        } else { restored = State() }
        // A previous process cannot still own a microphone. Its finalized
        // files can finish attribution without resurrecting capture.
        state = restored
        sealed = Set(restored.pending.map(\.original))
    }
    func resumeSavedWork() async {
        await MeetingSpeakerModelStore.shared.restoreInstallation()
        await refreshModelStatus()
        startWorker()
    }
    func prepare() async {
        await MeetingSpeakerModelStore.shared.requestIfNeeded()
        await refreshModelStatus()
        startWorker()
    }
    func refreshModelStatus() async {
        modelStatus = await MeetingSpeakerModelStore.shared.status()
        if modelStatus == .ready { startWorker() }
    }
    func reportPreparationFailure() {
        diagnostic = IDELanguageRunText.t("说话人识别未完成，录音与文字已保留。可在会议设置中重试。", "Speaker recognition is unfinished. Audio and text are saved. Retry in meeting settings.")
    }
    func retry() async {
        diagnostic = nil
        await MeetingSpeakerModelStore.shared.requestIfNeeded(explicit: true)
        await refreshModelStatus(); startWorker()
    }
    func cancelPreparation() async {
        await cancelAndWait()
        await MeetingSpeakerModelStore.shared.cancelPreparation()
        await refreshModelStatus()
    }
    func enqueue(original: CaptureSessionID, file: URL, range: MediaTimeRange) {
        do {
            let prefix = root.resolvingSymlinksInPath().path + "/"
            let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
            _ = try MediaTimeRange(start: range.start, end: range.end)
            guard resolved.path.hasPrefix(prefix), range.duration <= 25 else { throw PersonalContentError.outsideLibrary }
            let relative = String(resolved.path.dropFirst(prefix.count))
            guard relative.hasPrefix("Recordings/Chunks/" + original.description + "/"), state.pending.count < 4096 else { throw PersonalContentError.invalidProject }
            if state.pending.contains(where: { $0.original == original && $0.file == relative }) { return }
            if state.recordings.first(where: { $0.identity.original == original })?.windows.contains(where: { $0.range.start <= range.start + 0.001 && $0.range.end >= range.end - 0.001 }) == true { return }
            state.pending.append(Part(original: original, file: relative, range: range))
            state.pending.sort {
                $0.original == $1.original ? $0.range.start < $1.range.start : $0.original.description < $1.original.description
            }
            try save(); startWorker()
        } catch { diagnostic = error.localizedDescription }
    }
    /// A saved/imported original uses its verified existing capture row and
    /// actual media intervals. This never accepts an arbitrary external file.
    func enqueueOriginal(_ original: CaptureSessionID, file: URL) async throws {
        let owner = try await service.sessions(meeting: meeting).first { $0.id == original }
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        let prefix = root.resolvingSymlinksInPath().path + "/"
        guard let owner, owner.state == .stopped, resolved.path.hasPrefix(prefix),
              (try? Self.originalFile(owner: owner, root: root)) == resolved else { throw PersonalContentError.changedDocument }
        let asset = AVURLAsset(url: resolved)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw FileSpeechError.invalidAudio }
        var coverage = MeetingCoverageMap()
        for window in state.recordings.first(where: { $0.identity.original == original })?.windows ?? [] { try coverage.commit(window.range) }
        for part in state.pending where part.original == original { try coverage.commit(part.range) }
        let gaps = coverage.uncoveredSubranges(of: try MediaTimeRange(start: 0, end: duration))
        let relative = String(resolved.path.dropFirst(prefix.count))
        for gap in gaps {
            var cursor = gap.start
            while cursor < gap.end {
                guard state.pending.count < 4096 else { throw PersonalContentError.invalidProject }
                let end = min(gap.end, cursor + 24)
                state.pending.append(Part(original: original, file: relative,
                    range: try MediaTimeRange(start: cursor, end: end), sourceStart: cursor))
                cursor = end
            }
        }
        sealed.insert(original); try save(); startWorker()
    }
    func captureFinished(_ original: CaptureSessionID) {
        sealed.insert(original); startWorker()
    }
    /// Reapply known spans when ASR commits later. Identity is already durable;
    /// this is a transactional speaker-only operation, never a second ASR pass.
    func applyStored(rows: [(original: CaptureSessionID, segment: TranscriptSegment)]) async throws -> Bool {
        var changed = false
        for value in rows {
            let row = value.segment
            let revision = (row.speakerID?.description ?? "") + (row.speakerCorrected ? "|user" : "|engine")
            guard seenRows[row.id] != revision else { continue }
            seenRows[row.id] = revision
            guard !row.speakerCorrected,
                  let recording = state.recordings.first(where: { $0.identity.original == value.original }),
                  let window = recording.windows.first(where: { $0.range.start <= row.range.start + 0.001 && $0.range.end >= row.range.end - 0.001 }),
                  let candidate = RecordingSpeakerSpan.unambiguousSpeaker(for: row.range, spans: window.spans),
                  candidate != row.speakerID else { continue }
            do {
                let count = try await service.applyRecordingSpeakers(meeting: meeting, original: value.original,
                    window: window.range, spans: window.spans)
                changed = changed || count > 0
            } catch { seenRows[row.id] = nil; throw error }
        }
        return changed
    }
    func cancelAndWait() async {
        epoch = UUID()
        let task = worker; task?.cancel(); await task?.value
        worker = nil; isWorking = false
    }
    private func nextBatch() -> [Part] {
        guard let first = state.pending.first else { return [] }
        var batch = [first], end = first.range.end
        for part in state.pending.dropFirst() {
            guard part.original == first.original, abs(part.range.start - end) < 0.005,
                  part.range.end - first.range.start <= 24 else { break }
            batch.append(part); end = part.range.end
            if end - first.range.start >= 12 { break }
        }
        return end - first.range.start >= 6 || sealed.contains(first.original) ? batch : []
    }
    private func startWorker() {
        guard worker == nil, diagnostic == nil, !nextBatch().isEmpty else { return }
        let token = UUID(); epoch = token; isWorking = true
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if self.epoch == token { self.worker = nil; self.isWorking = false } }
            do {
                while !Task.isCancelled, self.epoch == token, !self.nextBatch().isEmpty {
                    self.modelStatus = await MeetingSpeakerModelStore.shared.status()
                    if case .downloading = self.modelStatus {
                        try await Task.sleep(for: .milliseconds(250)); continue
                    }
                    guard self.modelStatus == .ready else { return }
                    let batch = self.nextBatch()
                    do { try await self.process(batch, token: token) }
                    catch MeetingNativeSpeakerEngine.Failure.busy { try await Task.sleep(for: .milliseconds(250)); continue }
                    await self.onChange()
                }
            } catch is CancellationError {} catch {
                if self.epoch == token { self.diagnostic = IDELanguageRunText.t("说话人识别未完成，录音与文字已保留。可在会议设置中重试。", "Speaker recognition is unfinished. Audio and text are saved. Retry in meeting settings.") }
            }
        }
    }
    private func process(_ batch: [Part], token: UUID) async throws {
        guard let first = batch.first, let last = batch.last else { return }
        let owners = try await service.sessions(meeting: meeting)
        guard let owner = owners.first(where: { $0.id == first.original && $0.meetingID == meeting }) else { throw PersonalContentError.changedDocument }
        let root = self.root
        let audio = try await Task.detached(priority: .utility) { () -> [Float] in
            var audio: [Float] = []
            for part in batch {
                try Task.checkCancellation()
                let file = root.appendingPathComponent(part.file).standardizedFileURL.resolvingSymlinksInPath()
                guard file.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw PersonalContentError.outsideLibrary }
                if part.sourceStart != nil {
                    guard try Self.originalFile(owner: owner, root: root) == file else { throw PersonalContentError.changedDocument }
                } else {
                    guard part.file.hasPrefix("Recordings/Chunks/" + first.original.description + "/") else { throw PersonalContentError.outsideLibrary }
                }
                let sourceStart = part.sourceStart ?? 0
                guard sourceStart.isFinite, sourceStart >= 0 else { throw FileSpeechError.invalidAudio }
                let asset = AVURLAsset(url: file)
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration + 0.15 >= sourceStart + part.range.duration,
                      let track = try await asset.loadTracks(withMediaType: .audio).first else { throw FileSpeechError.invalidAudio }
                audio += try SpeechAudioChunk.read(asset: asset, track: track, start: sourceStart, duration: part.range.duration)
            }
            return audio
        }.value
        try check(token)
        let output: MeetingNativeSpeakerResult
        if audio.count < 12_800 { output = .init(spans: [], centroids: [:]) }
        else { output = try await MeetingNativeSpeakerEngine.shared.recognize(audio) }
        try check(token)
        var recording = state.recordings.first { $0.identity.original == first.original }
            ?? Recording(identity: RecordingSpeakerIdentity(meeting: meeting, original: first.original))
        var durations: [Int: Double] = [:]
        for span in output.spans { durations[span.label, default: 0] += span.end - span.start }
        let identities = recording.identity.resolve(centroids: output.centroids, speechSeconds: durations)
        let beforeIdentity = state
        if let index = state.recordings.firstIndex(where: { $0.identity.original == first.original }) { state.recordings[index] = recording }
        else { state.recordings.append(recording) }
        do { try save() } catch { state = beforeIdentity; throw error }
        var speakers: [Int: SpeakerID] = [:]
        for (label, identity) in identities {
            if let speaker = try await service.resolveEngineSpeaker(meeting: meeting,
                scope: "native|" + meeting.description + "|" + first.original.description, label: identity.uuidString) { speakers[label] = speaker }
            try check(token)
        }
        let spans = try output.spans.compactMap { span -> RecordingSpeakerSpan? in
            guard let speaker = speakers[span.label] else { return nil }
            return RecordingSpeakerSpan(range: try MediaTimeRange(start: first.range.start + span.start,
                end: min(last.range.end, first.range.start + span.end)), speaker: speaker)
        }
        let window = Window(range: try MediaTimeRange(start: first.range.start, end: last.range.end), spans: spans)
        let beforeWindow = state
        recording.windows.append(window)
        if let index = state.recordings.firstIndex(where: { $0.identity.original == first.original }) { state.recordings[index] = recording }
        else { state.recordings.append(recording) }
        let consumed = Set(batch)
        state.pending.removeAll { consumed.contains($0) }
        // Persist track identities before database projection. A crash here
        // reapplies exactly these IDs; a new request never renumbers them.
        do { try save() } catch { state = beforeWindow; throw error }
        _ = try await service.applyRecordingSpeakers(meeting: meeting, original: first.original, window: window.range, spans: spans)
        try check(token)
    }
    private nonisolated static func originalFile(owner: CaptureSessionSnapshot, root: URL) throws -> URL {
        let file: URL
        if let source = owner.sourceFile { file = URL(fileURLWithPath: source) }
        else {
            let directory = root.appendingPathComponent("Recordings")
            guard owner.kind == .liveRecording,
                  owner.directory?.standardizedFileURL.resolvingSymlinksInPath() == directory.standardizedFileURL.resolvingSymlinksInPath() else { throw PersonalContentError.changedDocument }
            let configuration = CaptureConfiguration(directory: directory)
            let pcm = try MeetingPCMChunkRecorder.originalURL(configuration: configuration, session: owner.id)
            file = FileManager.default.fileExists(atPath: pcm.path) ? pcm : try AVAudioRecorderCaptureBackend.makeFileURL(configuration: configuration, session: owner.id)
        }
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw PersonalContentError.outsideLibrary }
        return resolved
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard token == epoch, FileManager.default.fileExists(atPath: root.appendingPathComponent("meeting.sqlite").path) else { throw CancellationError() }
    }
    private func save() throws {
        let data = try JSONEncoder().encode(state)
        guard data.count <= 16 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
        try data.write(to: root.appendingPathComponent("recording-speakers.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
    }
}
#endif
