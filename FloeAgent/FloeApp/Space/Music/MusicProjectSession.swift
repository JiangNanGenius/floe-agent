// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import AVFoundation
import Darwin
import Foundation
import Observation
import FloeMusicCore
import FloeMusicNative
import FloeMusicKeyboard

@MainActor private final class MusicKeyboardSink: KeyboardPerformanceSink {
    var handler: ((KeyboardPerformanceEvent) -> Void)?
    func receive(_ event: KeyboardPerformanceEvent) { handler?(event) }
}

/// Each personal Music project has one durable store and one service-owned
/// transport. Editor windows do not own renders or recorded original files.
@MainActor @Observable final class MusicProjectSession {
    private static var sessions: [UUID: MusicProjectSession] = [:]
    let id: UUID
    let root: URL
    let repository: NativeMusicRepository
    let store: MusicProjectStore
    private(set) var document: MusicDocument
    let keyboard: KeyboardPerformanceController
    private let sink = MusicKeyboardSink()
    private let audio: NativeCreativeAudioSession
    private var instrument: MusicLiveInstrument?
    private var player: AVAudioPlayer?
    private var recorder: AVAudioRecorder?
    private var microphoneFile: URL?
    private var handle: MusicSessionHandle
    private var lease: MusicRenderLease?
    private var renderTask: Task<Void, Never>?
    private var renderError: (any Error)?
    private(set) var isRendering = false
    private(set) var renderedFrames: Int64 = 0
    private(set) var isLive = false
    private(set) var isPlaying = false
    private(set) var isRecording = false
    private(set) var saving = false
    private(set) var exportedFile: URL?
    private(set) var exportedFiles: [URL] = []
    var selectedTrack: MusicTrackID?
    var selectedClip: MusicClipID?
    var playheadSeconds: Double = 0
    var looping = false
    private(set) var waveforms: [MusicAssetID: [Float]] = [:]
    private(set) var waveformErrors: [MusicAssetID: String] = [:]
    private(set) var dj: MusicDJSession?
    private var waveformTasks: [MusicAssetID: Task<Void, Never>] = [:]
    var diagnostic: String?
    var preset = "0"
    private var midiStart: UInt64?
    private var heldNotes: [String: (PerformanceNote, Int64)] = [:]
    private var capturedNotes: [MusicMIDINote] = []
    private let renderer = MusicOfflineRenderer()
    private let mp3 = MusicMP3Exporter()

    private init(id: UUID, root: URL, repository: NativeMusicRepository, store: MusicProjectStore,
                 document: MusicDocument, handle: MusicSessionHandle, environment: AppEnvironment) {
        self.id = id; self.root = root; self.repository = repository; self.store = store
        self.document = document; self.handle = handle
        audio = NativeCreativeAudioSession(environment: environment)
        keyboard = KeyboardPerformanceController(owner: KeyboardOwnerToken(id.uuidString), sink: sink)
        selectedTrack = document.tracks.first?.id
        sink.handler = { [weak self] in self?.receive($0) }
        if let bytes = try? Data(contentsOf: root.appendingPathComponent("dj-session.json")),
           let saved = try? JSONDecoder().decode(MusicDJSession.self, from: bytes) { dj = saved }
    }
    static func open(id: UUID, directory: URL, environment: AppEnvironment) async throws -> MusicProjectSession {
        if let value = sessions[id] { return value }
        let repository = try NativeMusicRepository(root: directory)
        let store = try await MusicProjectStore.open(projectID: .init(rawValue: id.uuidString.lowercased()), repository: repository)
        let document = try await store.currentSnapshot()
        let handle = await store.beginSession(ownerToken: "music-editor-" + UUID().uuidString)
        let value = MusicProjectSession(id: id, root: directory, repository: repository, store: store,
            document: document, handle: handle, environment: environment)
        sessions[id] = value
        value.loadWaveforms()
        return value
    }
    func apply(_ operations: [MusicEditOp], expectedRevision: Int64? = nil) async throws {
        guard !saving else { throw MusicError.invalidBatch(reason: "another edit is saving") }
        if let expectedRevision, expectedRevision != document.revision {
            throw MusicError.staleRevision(expected: expectedRevision, actual: document.revision)
        }
        saving = true
        defer { saving = false }
        cancelRender()
        stopPlayback()
        document = try await store.commit(.init(baseRevision: document.revision, author: "native-editor", ops: operations), as: handle)
        handle = .init(sessionID: handle.sessionID, ownerToken: handle.ownerToken, baseRevision: document.revision)
        loadWaveforms()
    }
    func addTrack() async {
        do {
            let track = try FloeMusicCore.MusicTrack(name: IDELanguageRunText.t("乐器轨", "Instrument"),
                kind: .midi, instrument: .init(pluginID: MusicNativeBuiltins.synth))
            try await apply([.insertTrack(track)])
            selectedTrack = track.id
        } catch { diagnostic = error.localizedDescription }
    }
    func addMIDIClip(to trackID: MusicTrackID) async throws -> MusicClip {
        guard document.tracks.contains(where: { $0.id == trackID && $0.kind == .midi }) else {
            throw MusicError.invalidTrack(reason: "Select an instrument track")
        }
        let clip = try MusicClip(name: IDELanguageRunText.t("MIDI 片段", "MIDI clip"), trackID: trackID,
            offset: .init(Int64(playheadSeconds * Double(document.tempoMap.sampleRate))),
            body: .midi(.init(durationTicks: Int64(document.tempoMap.ticksPerQuarter) * 16, notes: [])))
        try await apply([.insertClip(clip)])
        selectedTrack = trackID
        selectedClip = clip.id
        return clip
    }
    func undo(redo: Bool = false) async {
        do {
            cancelRender()
            document = try await (redo ? store.redo(handle) : store.undo(handle))
            handle = .init(sessionID: handle.sessionID, ownerToken: handle.ownerToken, baseRevision: document.revision)
        } catch { diagnostic = error.localizedDescription }
    }
    func importFile(_ url: URL) async {
        do {
            let repository = self.repository, sampleRate = document.tempoMap.sampleRate
            let imported = try await Task.detached(priority: .userInitiated) { () -> (MusicAsset, [FloeMusicCore.MusicTrack], MusicTempoMap?) in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 128 * 1_024 * 1_024 else { throw MusicError.invalidAsset(reason: "file size limit") }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                if ["mid", "midi"].contains(url.pathExtension.lowercased()) {
                    let imported = try MusicMIDINoteImport.read(url: url, sampleRate: sampleRate)
                    try await repository.stageAsset(.init(asset: imported.source, bytes: data))
                    return (imported.source, imported.tracks, imported.tempoMap)
                }
                let asset = try MusicAudioPreparation.inspect(url: url, projectSampleRate: sampleRate)
                try await repository.stageAsset(.init(asset: asset, bytes: data))
                let trackID = MusicTrackID()
                let clip = try MusicClip(name: asset.name, trackID: trackID, offset: .init(0),
                    body: .audio(.init(assetID: asset.id, durationSamples: asset.durationSamples.value)))
                let track = try FloeMusicCore.MusicTrack(id: trackID, name: asset.name, kind: .audio, clips: [clip])
                return (asset, [track], nil)
            }.value
            var operations: [MusicEditOp] = [.insertAsset(imported.0)]
            operations += imported.1.map(MusicEditOp.insertTrack)
            if document.tracks.isEmpty, let tempo = imported.2 { operations.append(.setTempoMap(tempo)) }
            try await apply(operations)
            selectedTrack = imported.1.first?.id
            selectedClip = imported.1.first?.clips.first?.id
        } catch { diagnostic = error.localizedDescription }
    }
    func startLive() {
        guard !isLive else { return }
        do {
            let patch = currentTrack?.instrument
            let voice = try MusicLiveInstrument(ownerToken: keyboard.owner.rawValue, authority: audio,
                preset: patch?.presetIndex ?? Int(preset) ?? 0, parameters: patch?.parameters ?? [:])
            try voice.start(); instrument = voice; isLive = true
        } catch { diagnostic = error.localizedDescription }
    }
    func stopLive() {
        keyboard.releaseAll(reason: .panelClosed)
        instrument?.stop(); instrument = nil; isLive = false
    }
    func changePreset(_ value: String?) {
        preset = value ?? "0"
        Task { await updateInstrument(preset: Int(preset) ?? 0) }
    }
    func startMIDIRecording() {
        guard !isRecording, midiStart == nil else { return }
        startLive()
        guard isLive else { return }
        capturedNotes = []; heldNotes = [:]; midiStart = mach_absolute_time()
    }
    var isMIDIRecording: Bool { midiStart != nil }
    private func recordingTick() throws -> Int64 {
        guard let start = midiStart else { return 0 }
        let seconds = AVAudioTime.seconds(forHostTime: mach_absolute_time() - start)
        let samples = min(Double(Int64.max / 2), seconds * Double(document.tempoMap.sampleRate))
        return try document.tempoMap.tick(atSample: .init(Int64(samples.rounded()))).value
    }
    func stopMIDIRecording() async {
        guard midiStart != nil else { return }
        do {
            let end = max(1, try recordingTick())
            for (_, value) in heldNotes {
                capturedNotes.append(try .init(pitch: Int(value.0.note), startTick: .init(value.1),
                    durationTicks: max(1, end - value.1), velocity: max(1, Int(value.0.velocity)), channel: Int(value.0.channel)))
            }
            heldNotes = [:]; midiStart = nil
            guard !capturedNotes.isEmpty else { return }
            var operations: [MusicEditOp] = []
            let track: FloeMusicCore.MusicTrack
            if let selected = document.tracks.first(where: { $0.id == selectedTrack && $0.kind == .midi }) { track = selected }
            else {
                track = try .init(name: IDELanguageRunText.t("键盘录制", "Keyboard take"), kind: .midi,
                    instrument: .init(pluginID: MusicNativeBuiltins.synth, presetIndex: Int(preset) ?? 0))
                operations.append(.insertTrack(track))
            }
            let length = capturedNotes.map { $0.startTick.value + $0.durationTicks }.max() ?? end
            let clip = try MusicClip(name: IDELanguageRunText.t("录制片段", "Recorded clip"), trackID: track.id,
                offset: .init(0), body: .midi(.init(durationTicks: max(1, length), notes: capturedNotes)))
            operations.append(.insertClip(clip))
            try await apply(operations)
            selectedTrack = track.id; capturedNotes = []
        } catch { midiStart = nil; diagnostic = error.localizedDescription }
    }
    private func receive(_ event: KeyboardPerformanceEvent) {
        do {
            let owner: KeyboardOwnerToken, message: MusicPerformanceMessage
            switch event {
            case .noteOn(let token, let note):
                owner = token; message = .noteOn(note: note.note, velocity: note.velocity, channel: note.channel)
                if midiStart != nil { heldNotes["\(note.channel):\(note.note)"] = (note, try recordingTick()) }
            case .noteOff(let token, let note, let channel):
                owner = token; message = .noteOff(note: note, channel: channel)
                if let held = heldNotes.removeValue(forKey: "\(channel):\(note)") {
                    capturedNotes.append(try .init(pitch: Int(note), startTick: .init(held.1),
                        durationTicks: max(1, (try recordingTick()) - held.1), velocity: max(1, Int(held.0.velocity)), channel: Int(channel)))
                }
            case .sustain(let token, let enabled): owner = token; message = .sustain(enabled)
            case .pitchBend(let token, let value): owner = token; message = .pitchBend(value)
            case .modulation(let token, let value): owner = token; message = .modulation(value)
            case .allNotesOff(let token): owner = token; message = .allNotesOff
            }
            if let instrument, isLive { try instrument.send(message, ownerToken: owner.rawValue) }
        } catch { diagnostic = error.localizedDescription }
    }
    func render(asMP3: Bool, play: Bool = false) {
        guard !isRendering else { return }
        isRendering = true; diagnostic = nil; renderError = nil; renderedFrames = 0
        let frozen = document
        renderTask = Task { [self] in
            defer { isRendering = false; renderTask = nil }
            do {
                let lease = try MusicRenderLease(document: frozen, ownerToken: handle.ownerToken)
                self.lease = lease
                let directory = root.appendingPathComponent("Exports")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let base = "mix-r\(frozen.revision)-" + UUID().uuidString
                let wav = directory.appendingPathComponent(base + ".wav")
                var sources: [ResolvedMusicSource] = []
                for asset in frozen.assets {
                    if asset.kind == .midiFile { continue }
                    sources.append(.init(asset: asset, url: try await repository.resolvedURL(for: asset)))
                }
                _ = try await renderer.render(document: frozen, sources: sources, destination: wav, lease: lease) { [weak self] frames in
                    Task { @MainActor in self?.renderedFrames = frames }
                }
                var output = wav
                if asMP3 {
                    output = try await mp3.encode(wav: wav, destination: directory.appendingPathComponent(base + ".mp3"),
                        document: frozen, lease: lease)
                }
                try Task.checkCancellation(); try lease.validate(document: document)
                exportedFile = output
                exportedFiles = [output]
                if play {
                    stopPlayback()
                    try audio.acquirePlayback()
                    do {
                        let player = try AVAudioPlayer(contentsOf: output)
                        player.currentTime = min(playheadSeconds, player.duration)
                        player.numberOfLoops = looping ? -1 : 0
                        guard player.play() else { throw MusicNativeError.render("playback did not start") }
                        self.player = player; isPlaying = true
                    } catch { audio.releasePlayback(); throw error }
                }
            } catch { renderError = error; if !Task.isCancelled { diagnostic = error.localizedDescription } }
        }
    }
    func renderAndWait(asMP3: Bool) async throws -> URL {
        guard !isRendering else { throw MusicError.invalidBatch(reason: "another render is running") }
        render(asMP3: asMP3)
        await withTaskCancellationHandler { await renderTask?.value } onCancel: {
            Task { @MainActor in self.cancelRender() }
        }
        try Task.checkCancellation()
        if let renderError { throw renderError }
        guard let exportedFile else { throw MusicNativeError.render("no saved output") }
        return exportedFile
    }
    func cancelRender() { lease?.invalidate(); lease = nil; renderTask?.cancel() }
    func stopPlayback() {
        let owned = player != nil
        player?.stop(); player = nil; isPlaying = false
        if owned { audio.releasePlayback() }
    }
    func startMicrophone() async {
        guard !isRecording, !isLive, !isPlaying else { return }
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw MusicNativeError.invalid("microphone permission denied") }
            try audio.acquireRecording()
            let directory = root.appendingPathComponent("Recordings")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(UUID().uuidString + ".m4a")
            let recorder = try AVAudioRecorder(url: file, settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: document.tempoMap.sampleRate, AVNumberOfChannelsKey: 1])
            guard recorder.record() else { throw MusicNativeError.invalid("recording did not start") }
            microphoneFile = file; self.recorder = recorder; isRecording = true
        } catch { audio.releasePlayback(); diagnostic = error.localizedDescription }
    }
    func stopMicrophone() async {
        recorder?.stop(); recorder = nil; isRecording = false; audio.releasePlayback()
        if let file = microphoneFile { microphoneFile = nil; await importFile(file) }
    }

    var currentTrack: FloeMusicCore.MusicTrack? { document.tracks.first { $0.id == selectedTrack } }
    var currentClip: MusicClip? { document.tracks.flatMap(\.clips).first { $0.id == selectedClip } }
    var durationSeconds: Double {
        let last = document.tracks.flatMap(\.clips).compactMap { try? $0.endSample(tempoMap: document.tempoMap).value }.max() ?? 0
        return Double(last) / Double(document.tempoMap.sampleRate)
    }
    var playbackPosition: Double { player?.isPlaying == true ? player?.currentTime ?? playheadSeconds : playheadSeconds }
    var playbackIsActive: Bool { player?.isPlaying == true }
    func seek(to seconds: Double) {
        playheadSeconds = min(max(0, seconds), max(durationSeconds, 1))
        if player != nil { player?.currentTime = playheadSeconds }
    }
    func setLooping(_ value: Bool) { looping = value; player?.numberOfLoops = value ? -1 : 0 }
    func selectTrack(_ id: MusicTrackID) {
        let wasLive = isLive
        if selectedTrack != id, wasLive { stopLive() }
        selectedTrack = id
        preset = String(currentTrack?.instrument?.presetIndex ?? 0)
        if wasLive { startLive() }
    }
    func selectClip(_ clip: MusicClip) { selectTrack(clip.trackID); selectedClip = clip.id }
    func reload() async throws {
        guard !saving else { return }
        document = try await store.currentSnapshot()
        handle = .init(sessionID: handle.sessionID, ownerToken: handle.ownerToken, baseRevision: document.revision)
        loadWaveforms()
    }
    func edit(_ operations: [MusicEditOp]) {
        Task { do { try await apply(operations) } catch { diagnostic = error.localizedDescription } }
    }
    func addAudioTrack() async {
        do {
            let track = try FloeMusicCore.MusicTrack(name: IDELanguageRunText.t("音频轨", "Audio"), kind: .audio)
            try await apply([.insertTrack(track)]); selectTrack(track.id)
        } catch { diagnostic = error.localizedDescription }
    }
    func updateStrip(_ id: MusicTrackID, _ change: (inout MusicStripSettings) -> Void) {
        guard var strip = document.tracks.first(where: { $0.id == id })?.strip else { return }
        change(&strip); edit([.setStrip(id, strip)])
    }
    func updateInstrument(preset: Int? = nil, parameter: String? = nil, value: Double = 0) async {
        do {
            guard let track = currentTrack, track.kind == .midi else {
                throw MusicError.invalidTrack(reason: IDELanguageRunText.t("请先选择乐器轨。", "Select an instrument track first."))
            }
            let running = isLive
            stopLive()
            var patch: MusicPluginState
            if let instrument = track.instrument { patch = instrument }
            else { patch = try MusicPluginState(pluginID: MusicNativeBuiltins.synth) }
            if let preset { patch.presetIndex = preset }
            if let parameter { patch.parameters[parameter] = value }
            try await apply([.setInstrument(track.id, patch)])
            self.preset = String(patch.presetIndex)
            if running { startLive() }
        } catch { diagnostic = error.localizedDescription }
    }
    func duplicateSelection() {
        guard let clip = currentClip else { return }
        do {
            let copy = try MusicWorkbenchEditing.duplicate(clip, tempoMap: document.tempoMap)
            edit([.insertClip(copy)]); selectedClip = copy.id
        } catch { diagnostic = error.localizedDescription }
    }
    func splitSelection() {
        guard let clip = currentClip else { return }
        do {
            let sample = MusicSampleTime(Int64(playbackPosition * Double(document.tempoMap.sampleRate)))
            edit(try MusicWorkbenchEditing.split(clip, at: sample, tempoMap: document.tempoMap))
        } catch { diagnostic = error.localizedDescription }
    }
    func addEffect(_ pluginID: String) {
        guard let track = currentTrack else { return }
        do {
            let parameters: [String: Double] = pluginID == MusicNativeBuiltins.eq
                ? ["frequency": 1000, "gainDB": 0, "bandwidth": 1] : ["mix": 0.2]
            edit([.setEffects(track.id, track.effects + [try MusicPluginState(pluginID: pluginID, parameters: parameters)])])
        } catch { diagnostic = error.localizedDescription }
    }
    func addReverbBus() {
        do {
            let bus = try MusicBus(id: .init(rawValue: UUID().uuidString.lowercased()),
                name: IDELanguageRunText.t("混响返回", "Reverb return"),
                effects: [.init(pluginID: MusicNativeBuiltins.reverb, parameters: ["mix": 1])], sends: [MusicBus.masterBusID])
            edit([.insertBus(bus)])
        } catch { diagnostic = error.localizedDescription }
    }
    func loadWaveforms() {
        for asset in document.assets where asset.kind != .midiFile && waveforms[asset.id] == nil && waveformTasks[asset.id] == nil {
            let repository = repository
            waveformTasks[asset.id] = Task { [weak self] in
                defer { self?.waveformTasks[asset.id] = nil }
                do {
                    let url = try await repository.resolvedURL(for: asset)
                    let peaks = try await Task.detached(priority: .utility) {
                        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
                        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { return [Float]() }
                        var peaks = [Float](repeating: 0, count: 512)
                        while file.framePosition < file.length {
                            try Task.checkCancellation()
                            let start = file.framePosition
                            try file.read(into: buffer)
                            guard buffer.frameLength > 0, let pcm = buffer.floatChannelData else { break }
                            for frame in 0..<Int(buffer.frameLength) {
                                let bin = min(511, Int(Double(start + Int64(frame)) / Double(file.length) * 512))
                                for channel in 0..<Int(file.processingFormat.channelCount) { peaks[bin] = max(peaks[bin], abs(pcm[channel][frame])) }
                            }
                        }
                        return peaks
                    }.value
                    self?.waveforms[asset.id] = peaks
                } catch { if !Task.isCancelled { self?.waveformErrors[asset.id] = error.localizedDescription } }
            }
        }
    }
    func changeDJ(_ change: (inout MusicDJSession) throws -> Void) {
        do {
            let old = dj
            var next = try MusicDJSession(id: old?.id ?? MusicDJSessionID(), assets: document.assets,
                deckA: old?.deckA ?? .init(), deckB: old?.deckB ?? .init(), crossfader: old?.crossfader ?? 0.5,
                cueSource: old?.cueSource ?? .none, cueGain: old?.cueGain ?? 1, masterGain: old?.masterGain ?? 1,
                sampleRate: document.tempoMap.sampleRate)
            try change(&next); try next.validate()
            try JSONEncoder().encode(next).write(to: root.appendingPathComponent("dj-session.json"), options: .atomic)
            dj = next
        } catch { diagnostic = error.localizedDescription }
    }
    func exportOriginals(stems: Bool) {
        guard !isRendering else { return }
        let frozen = document
        isRendering = true; diagnostic = nil; renderError = nil
        renderTask = Task { [self] in
            defer { isRendering = false; renderTask = nil }
            do {
                let lease = try MusicRenderLease(document: frozen, ownerToken: handle.ownerToken)
                self.lease = lease
                let directory = root.appendingPathComponent("Exports")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var outputs: [URL] = []
                if stems {
                    var sources: [ResolvedMusicSource] = []
                    for asset in frozen.assets where asset.kind != .midiFile {
                        sources.append(.init(asset: asset, url: try await repository.resolvedURL(for: asset)))
                    }
                    for (index, track) in frozen.tracks.enumerated() where !track.clips.isEmpty {
                        try Task.checkCancellation(); try lease.validate(document: document)
                        var stem = frozen
                        var audible = track; audible.strip.muted = false; audible.strip.soloed = true
                        stem.tracks = [audible]
                        let owners = Set([track.id.rawValue] + stem.buses.map { $0.id.rawValue })
                        stem.automationLanes.removeAll { !owners.contains($0.ownerID) }
                        let output = directory.appendingPathComponent("stem-\(index + 1)-r\(frozen.revision)-\(UUID().uuidString).wav")
                        _ = try await renderer.render(document: stem, sources: sources, destination: output, lease: lease)
                        outputs.append(output)
                    }
                    guard !outputs.isEmpty else { throw MusicNativeError.render("No clips to export") }
                } else {
                    let staging = root.appendingPathComponent(".package-\(UUID().uuidString)")
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let target = try NativeMusicRepository(root: staging)
                    for asset in frozen.assets {
                        let url = try await repository.resolvedURL(for: asset)
                        let bytes = try await Task.detached(priority: .utility) { try Data(contentsOf: url, options: .mappedIfSafe) }.value
                        try await target.stageAsset(.init(asset: asset, bytes: bytes))
                    }
                    _ = try await target.save(document: frozen, expectedRevision: nil, fence: nil)
                    if let dj { try JSONEncoder().encode(dj).write(to: staging.appendingPathComponent("dj-session.json"), options: .atomic) }
                    let output = directory.appendingPathComponent("music-project-r\(frozen.revision)-\(UUID().uuidString).zip")
                    let stagedZip = directory.appendingPathComponent(".package-\(UUID().uuidString).zip")
                    defer { try? FileManager.default.removeItem(at: stagedZip) }
                    try await Task.detached(priority: .utility) {
                        var coordinationError: NSError?
                        var copyError: (any Error)?
                        NSFileCoordinator().coordinate(readingItemAt: staging, options: .forUploading, error: &coordinationError) { archive in
                            do {
                                guard try archive.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw MusicNativeError.render("Project archive unavailable") }
                                try FileManager.default.copyItem(at: archive, to: stagedZip)
                            } catch { copyError = error }
                        }
                        if let coordinationError { throw coordinationError }
                        if let copyError { throw copyError }
                    }.value
                    try Task.checkCancellation(); try lease.validate(document: document)
                    try FileManager.default.moveItem(at: stagedZip, to: output)
                    outputs = [output]
                }
                try Task.checkCancellation(); try lease.validate(document: document)
                exportedFiles = outputs; exportedFile = outputs.first
            } catch { renderError = error; if !Task.isCancelled { diagnostic = error.localizedDescription } }
        }
    }
    func renderDJ(deck: MusicDJSession.DeckSlot? = nil) {
        guard !isRendering, var snapshot = dj else { return }
        do {
            try snapshot.setPlaying(.a, snapshot.deckA.assetID != nil && deck != .b)
            try snapshot.setPlaying(.b, snapshot.deckB.assetID != nil && deck != .a)
        } catch { diagnostic = error.localizedDescription; return }
        let frozen = document
        isRendering = true; diagnostic = nil; renderError = nil
        renderTask = Task { [self, snapshot] in
            defer { isRendering = false; renderTask = nil }
            do {
                let lease = try MusicRenderLease(document: frozen, ownerToken: handle.ownerToken)
                self.lease = lease
                let directory = root.appendingPathComponent("Exports")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let output = directory.appendingPathComponent("dj-r\(frozen.revision)-\(UUID().uuidString).wav")
                var sources: [ResolvedMusicSource] = []
                for asset in frozen.assets where asset.kind != .midiFile {
                    sources.append(.init(asset: asset, url: try await repository.resolvedURL(for: asset)))
                }
                let remaining = [snapshot.deckA, snapshot.deckB].filter(\.playing).map {
                    Double($0.assetDurationSamples - $0.playheadSamples) / $0.rate
                }.max() ?? 0
                let frames = Int64(min(remaining, Double(frozen.tempoMap.sampleRate) * 60))
                _ = try await MusicDJBounce().render(session: snapshot, sources: sources, document: frozen,
                    lease: lease, frames: frames, destination: output)
                try Task.checkCancellation(); try lease.validate(document: document)
                exportedFile = output
                exportedFiles = [output]
                stopPlayback(); try audio.acquirePlayback()
                do {
                    let player = try AVAudioPlayer(contentsOf: output)
                    guard player.play() else { throw MusicNativeError.render("DJ preview did not start") }
                    self.player = player; isPlaying = true
                } catch { audio.releasePlayback(); throw error }
            } catch { renderError = error; if !Task.isCancelled { diagnostic = error.localizedDescription } }
        }
    }
}
#endif
