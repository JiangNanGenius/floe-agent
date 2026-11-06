// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Foundation
import Observation
import FloeMeetings
import FloeMeetingsAV
import FloeNotes
import FloeTools

@MainActor @Observable final class MeetingProjectSession {
    private static var sessions: [UUID: MeetingProjectSession] = [:]
    let id: UUID
    let root: URL
    let service: MeetingService
    private let backend = MeetingSharedPCMBackend()
    private let audio: NativeCreativeAudioSession
    let environment: AppEnvironment
    let notebook = NotesSession()
    var intelligence = MeetingIntelligenceState()
    var isAnalyzing = false
    var intelligenceTask: Task<Void, Never>?
    var summaryTimer: Task<Void, Never>?
    var lastSummaryTranscriptCount = 0
    var liveTranscription: MeetingLiveTranscription?
    var rollingSummaryTask: Task<Void, Never>?
    var isUpdatingMinutes = false
    var rollingSummaryGeneration = UUID()
    private var captureSettlement: Task<Void, Never>?
    private var audioHeld = false
    private var playbackHeld = false
    private(set) var meeting: MeetingSnapshot
    private(set) var recordings: [CaptureSessionSnapshot] = []
    private(set) var transcript: [TranscriptSegment] = []
    private(set) var notes: [NoteEntry] = []
    private(set) var todos: [TodoItem] = []
    private(set) var decisions: [MeetingDecision] = []
    private(set) var speakers: [Speaker] = []
    private(set) var summaries: [SummaryRecord] = []
    private(set) var markers: [TimeMarker] = []
    private(set) var isRecording = false
    var isPaused = false
    private(set) var isProcessing = false
    private(set) var changingCapture = false
    private(set) var progress = 0.0
    private(set) var savedToNotes = false
    private var processing: Task<Void, Never>?
    private var generation = UUID()
    private var analysisSessions: [UUID: UUID] = [:]
    var diagnostic: String?
    var export: URL?
    var exportSourceIndex: URL?
    var isExportingDocument = false
    var documentExportTask: Task<Void, Never>?
    var documentExportCancellation: CancellationToken?
    var followups: MeetingFollowupCenter?
    var player: AVPlayer?
    var playingSession: CaptureSessionID?

    private init(id: UUID, root: URL, service: MeetingService, meeting: MeetingSnapshot, environment: AppEnvironment) {
        self.id = id; self.root = root; self.service = service; self.meeting = meeting
        self.environment = environment; audio = NativeCreativeAudioSession(environment: environment)
        do { followups = try MeetingFollowupCenter(root: root) }
        catch { diagnostic = error.localizedDescription }
        if let data = try? Data(contentsOf: root.appendingPathComponent("analysis-sessions.json")), data.count <= 1_024 * 1_024,
           let map = try? JSONDecoder().decode([UUID: UUID].self, from: data) { analysisSessions = map }
    }
    static func open(id: UUID, directory: URL, environment: AppEnvironment) async throws -> MeetingProjectSession {
        if let value = sessions[id] { return value }
        let file = directory.appendingPathComponent("meeting.sqlite")
        guard FileManager.default.fileExists(atPath: file.path) else { throw PersonalContentError.invalidProject }
        let service = MeetingService(database: try MeetingDatabase(path: file.path))
        let meeting = try await service.meeting(MeetingID(id))
        let value = MeetingProjectSession(id: id, root: directory, service: service, meeting: meeting, environment: environment)
        value.liveTranscription = try MeetingLiveTranscription(meetingID: MeetingID(id), root: directory,
            service: service, audio: environment.assistantAudioService, onChange: { [weak value] in
                await value?.liveTranscriptDidChange()
            })
        sessions[id] = value
        await service.setCaptureEventHandler { [weak value] event in
            Task { @MainActor in await value?.receiveCaptureEvent(event) }
        }
        await value.refresh()
        await value.loadNotebook()
        return value
    }
    static func prepareForDeletion(id: UUID) async {
        guard let value = sessions[id] else { return }
        await value.stopOwnedProcessing()
        sessions.removeValue(forKey: id)
    }
    func refresh() async {
        do {
            meeting = try await service.meeting(MeetingID(id))
            recordings = try await service.sessions(meeting: MeetingID(id))
            transcript = try await service.transcript(meeting: MeetingID(id))
            notes = try await service.notes(meeting: MeetingID(id))
            todos = try await service.todos(meeting: MeetingID(id))
            decisions = try await service.decisions(meeting: MeetingID(id))
            speakers = try await service.speakers(meeting: MeetingID(id))
            summaries = try await service.summaries(meeting: MeetingID(id))
            markers = try await service.markers(meeting: MeetingID(id))
            isRecording = await service.activeCaptureSession != nil
            if !isRecording { releaseAudio() }
            if let failure = await service.capturePersistenceFailure { diagnostic = failure.localizedDescription }
        } catch { diagnostic = error.localizedDescription }
    }
    func startRecording() async {
        guard !changingCapture, !isRecording else { return }
        changingCapture = true; diagnostic = nil
        defer { changingCapture = false }
        do {
            stopPlayback()
            guard await AVAudioApplication.requestRecordPermission() else { throw PersonalContentError.storageUnavailable }
            try audio.acquireRecording(); audioHeld = true
            configureLiveTranscription()
            let directory = root.appendingPathComponent("Recordings")
            _ = try await service.startCapture(meeting: MeetingID(id), backend: backend,
                configuration: .init(directory: directory))
            isPaused = false
            await refresh()
            synchronizeSummaryTimer()
        } catch { releaseAudio(); diagnostic = error.localizedDescription }
    }
    func stopRecording() async {
        guard !changingCapture else { return }
        changingCapture = true
        defer { changingCapture = false }
        do { _ = try await service.stopCapture() }
        catch { diagnostic = error.localizedDescription }
        await refresh()
        captureSettlement?.cancel()
        captureSettlement = Task { [weak self] in
            guard let self else { return }
            for _ in 0..<400 {
                if Task.isCancelled { return }
                if await self.service.activeCaptureSession == nil { await self.refresh(); return }
                try? await Task.sleep(for: .milliseconds(25))
            }
            self.diagnostic = IDELanguageRunText.t("录音正在结束，原文件已保留。", "Recording is still finishing. Its original file was preserved.")
        }
        isPaused = false
        synchronizeSummaryTimer()
    }
    func pauseRecording() async {
        guard isRecording else { return }
        await stopRecording()
        if !isRecording { isPaused = true }
    }
    private func releaseAudio() {
        guard audioHeld else { return }
        audioHeld = false; audio.releasePlayback()
    }
    func importFile(_ source: URL) async {
        do {
            let directory = root.appendingPathComponent("Media")
            let imported = try await Task.detached(priority: .userInitiated) {
                let access = source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 2_147_483_648 else { throw PersonalContentError.invalidProject }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = UUID().uuidString + "." + source.pathExtension.lowercased()
                let target = directory.appendingPathComponent(name)
                try FileManager.default.copyItem(at: source, to: target)
                let info = try await AudioFileProbe.probe(target)
                guard info.hasAudioTrack else { throw PersonalContentError.invalidProject }
                return target
            }.value
            _ = try await service.importFile(meeting: MeetingID(id), file: imported,
                kind: ["mp4", "mov", "m4v"].contains(imported.pathExtension) ? .importedVideo : .importedAudio,
                duration: AudioFileProbe.durationRange)
            await refresh()
        } catch { diagnostic = error.localizedDescription }
    }
    func mediaFile(for session: CaptureSessionSnapshot) throws -> URL {
        let file: URL
        if let source = session.sourceFile { file = URL(fileURLWithPath: source) }
        else {
            let configuration = CaptureConfiguration(directory: root.appendingPathComponent("Recordings"))
            let pcm = try MeetingPCMChunkRecorder.originalURL(configuration: configuration, session: session.id)
            file = FileManager.default.fileExists(atPath: pcm.path) ? pcm
                : try AVAudioRecorderCaptureBackend.makeFileURL(configuration: configuration, session: session.id)
        }
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().path + "/"),
              FileManager.default.fileExists(atPath: resolved.path) else { throw PersonalContentError.missingDocument }
        return resolved
    }
    func play(_ session: CaptureSessionSnapshot, at time: Double = 0) {
        guard !isRecording, session.state == .stopped else { return }
        do {
            let file = try mediaFile(for: session)
            if !playbackHeld { try audio.acquirePlayback(); playbackHeld = true }
            player?.pause()
            let player = AVPlayer(url: file)
            player.seek(to: CMTime(seconds: max(0, time), preferredTimescale: 600))
            self.player = player; playingSession = session.id
            player.play()
        } catch { diagnostic = error.localizedDescription }
    }
    func stopPlayback() {
        player?.pause(); player = nil; playingSession = nil
        if playbackHeld { playbackHeld = false; audio.releasePlayback() }
    }
    func originalCaptureSession(for session: CaptureSessionID) -> CaptureSessionID {
        if let original = liveTranscription?.originalSession(for: session), original != session { return original }
        if let original = analysisSessions.first(where: { $0.value == session.rawValue })?.key { return CaptureSessionID(original) }
        return session
    }
    func play(_ segment: TranscriptSegment) {
        let source = liveTranscription?.originalSession(for: segment.sessionID) ?? segment.sessionID
        guard let session = recordings.first(where: { $0.id == source }) else { return }
        play(session, at: segment.range.start)
    }
    func play(_ source: SourceReference) {
        if case .recording(let id, let range) = source,
           let recording = recordings.first(where: { $0.id == (liveTranscription?.originalSession(for: id) ?? id) }) {
            play(recording, at: range.start)
        }
    }
    func transcribe(_ source: CaptureSessionSnapshot) {
        guard !isProcessing, source.state == .stopped else { return }
        isProcessing = true; progress = 0; diagnostic = nil
        generation = UUID(); let token = generation
        processing = Task { [self] in
            defer { if generation == token { isProcessing = false; processing = nil } }
            do {
                let file = try mediaFile(for: source)
                let target: CaptureSessionID
                if source.kind != .liveRecording { target = source.id }
                else if let mapped = analysisSessions[source.id.rawValue],
                        recordings.contains(where: { $0.id.rawValue == mapped && $0.sourceFile == file.path }) {
                    target = CaptureSessionID(mapped)
                } else {
                    // A finalized original becomes an explicit file-analysis
                    // source. Live-ingestion fences remain unchanged.
                    target = try await service.importFile(meeting: MeetingID(id), file: file,
                        kind: .importedAudio, duration: AudioFileProbe.durationRange)
                    analysisSessions[source.id.rawValue] = target.rawValue
                    try JSONEncoder().encode(analysisSessions).write(to: root.appendingPathComponent("analysis-sessions.json"), options: .atomic)
                }
                let existing = try await service.transcript(meeting: MeetingID(id))
                guard !existing.contains(where: { $0.sessionID == target }) else {
                    await refresh(); return
                }
                let result = try await environment.assistantAudioService.transcribe(fileURL: file, language: .automatic, requiresTiming: true) { [weak self] fraction in
                    Task { @MainActor in
                        guard let self, self.generation == token else { return }
                        self.progress = min(1, max(0, fraction))
                    }
                }
                guard !result.segments.isEmpty else { throw PersonalContentError.invalidProject }
                for segment in result.segments {
                    try Task.checkCancellation()
                    guard generation == token else { throw CancellationError() }
                    _ = try await service.appendFinal(meeting: MeetingID(id), session: target, text: segment.text,
                        range: .init(start: segment.start, end: segment.end), language: result.language)
                }
                progress = 1
                await refresh()
            } catch {
                if !Task.isCancelled { diagnostic = error.localizedDescription }
                await refresh()
            }
        }
    }
    func cancelProcessing() {
        generation = UUID(); processing?.cancel(); processing = nil; isProcessing = false
        liveTranscription?.cancel()
    }
    func addNote(_ text: String) async -> Bool {
        do {
            _ = try await service.addNote(meeting: MeetingID(id), body: text, source: await currentSource())
            await refresh()
            savedToNotes = false
            return true
        } catch { diagnostic = error.localizedDescription; return false }
    }
    func addTodo(_ text: String) async -> Bool {
        do { _ = try await service.addTodo(meeting: MeetingID(id), text: text, origin: .user); await refresh(); savedToNotes = false; return true }
        catch { diagnostic = error.localizedDescription; return false }
    }
    func setDone(_ item: TodoItem, done: Bool) async {
        do { _ = try await service.updateTodo(item.id, meeting: MeetingID(id), status: done ? .done : .open); await refresh() }
        catch { diagnostic = error.localizedDescription }
    }
    func addMarker() async {
        do {
            _ = try await service.addMarker(meeting: MeetingID(id), label: nil, source: await currentSource())
            await refresh()
        } catch { diagnostic = error.localizedDescription }
    }
    private func currentSource() async -> SourceReference {
        if let session = await service.activeCaptureSession, let time = await backend.currentTime(), time.isFinite,
           let range = try? MediaTimeRange(start: max(0, time), end: max(0, time) + 0.01) {
            return .recording(session: session, range: range)
        }
        if let session = playingSession, let time = player?.currentTime().seconds, time.isFinite,
           let range = try? MediaTimeRange(start: max(0, time), end: max(0, time) + 0.01) {
            return .recording(session: session, range: range)
        }
        return .none
    }
    func correct(_ segment: TranscriptSegment, text: String) async {
        do { _ = try await service.correctSegment(segment.id, meeting: MeetingID(id), newText: text); await refresh() }
        catch { diagnostic = error.localizedDescription }
    }
    func addSpeaker(_ label: String) async {
        do { _ = try await service.addSpeaker(meeting: MeetingID(id), label: label, userNamed: true); await refresh() }
        catch { diagnostic = error.localizedDescription }
    }
    func exportTranscript(_ format: MeetingExportFormat) async {
        do {
            let data: Data
            if format == .srt || format == .vtt {
                data = try MeetingExport.captionData(cues: MeetingExport.cues(segments: transcript), format: format)
            } else {
                data = try MeetingExport.documentData(segments: transcript, speakers: speakers, title: meeting.title, format: format)
            }
            let directory = root.appendingPathComponent("Exports")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("meeting-" + UUID().uuidString + "." + (format == .markdown ? "md" : format.rawValue))
            try data.write(to: file, options: .atomic)
            export = file; exportSourceIndex = nil
        } catch { diagnostic = error.localizedDescription }
    }
    func saveAsNote() async {
        do {
            let text = String(decoding: try MeetingExport.documentData(segments: transcript, speakers: speakers,
                title: meeting.title, format: .txt), as: UTF8.self)
                + "\n\n" + notes.map(\.body).joined(separator: "\n\n")
                + "\n\n" + summaries.map(\.text).joined(separator: "\n\n")
                + "\n\n" + todos.map { ($0.status == .done ? "[x] " : "[ ] ") + $0.text }.joined(separator: "\n")
                + "\n\n" + decisions.map(\.text).joined(separator: "\n")
            _ = try await FloeNoteIntentService.create(text: text, title: meeting.title, notebook: nil,
                store: try await NotesRepository.shared.store())
            savedToNotes = true
        } catch { diagnostic = error.localizedDescription }
    }
}
#endif
