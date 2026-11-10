// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeMusicCore
import FloeMusicNative
import FloeTools

/// Read/edit/run adapters for the existing authorized studio tools. This is
/// the original Music session, not a second editor or a model-owned file path.
@MainActor enum StudioMusicDJContract {
    nonisolated struct Command: Codable, Sendable {
        let action: String
        let required: [String]
        let optional: [String]
        let runtime: Bool
        let constraints: [String: String]
    }
    nonisolated struct Recording: Codable, Sendable {
        let assetID: MusicAssetID?
        let frames: Int64
        let sampleRate: Int
        let sha256: String
        let recovered: Bool
        let sourceMusicRevision: Int64
    }
    nonisolated struct Observation: Codable, Sendable {
        let workspace: String
        let projectID: UUID
        let musicRevision: Int64
        let djRevision: Int64
        let stateSource: String
        let available: Bool
        let savedSHA256: String?
        let sampleRate: Int
        let deckA: MusicDJSession.Deck
        let deckB: MusicDJSession.Deck
        let crossfader: Double
        let masterGain: Double
        let playingA: Bool
        let playingB: Bool
        let recordingState: String
        let recordingID: UUID?
        let lastRecording: Recording?
        let independentHeadphoneOutput: Bool
        let commands: [Command]
        let runActions: [String]
        let exportMaximumSeconds: Double
        let editExample: String
    }
    nonisolated struct RunInput: Codable, Sendable {
        var expectedMusicRevision: Int64?
        var expectedDJRevision: Int64?
        var durationSeconds: Double?
        var recordingID: UUID?
        var deck: MusicDJSession.DeckSlot?
        var expectedSidecarSHA256: String?
    }
    nonisolated struct StartedRecording: Codable, Sendable {
        let projectID: UUID
        let musicRevision: Int64
        let djRevision: Int64
        let recordingID: UUID
        let state: String
    }
    static let runActions = ["djRecordStart", "djRecordStop", "renderDJWAV", "renderDJMP3", "analyzeDJBeats", "resetDJ"]
    static var commands: [Command] {
        MusicDJEditCommand.Action.allCases.map { action in
            let required: [String]
            let optional: [String]
            switch action {
            case .load: required = ["deck", "assetID"]; optional = []
            case .eject, .jumpCue, .clearCue, .exitLoop: required = ["deck"]; optional = []
            case .seek: required = ["deck", "sample"]; optional = []
            case .rate: required = ["deck", "value"]; optional = []
            case .keyLock, .playing: required = ["deck", "enabled"]; optional = []
            case .beatGrid: required = ["deck", "value", "firstBeatSample", "beatCount"]; optional = []
            case .cue: required = ["deck", "sample"]; optional = ["label"]
            case .hotcue: required = ["deck", "index", "sample"]; optional = ["label"]
            case .jumpHotcue, .removeHotcue: required = ["deck", "index"]; optional = []
            case .loop: required = ["deck", "startBeat", "lengthBeats"]; optional = []
            case .sync: required = ["deck"]; optional = ["otherDeck"]
            case .crossfader, .masterGain, .cueGain: required = ["value"]; optional = []
            case .cueSource: required = ["cueSource"]; optional = []
            }
            var constraints: [String: String] = ["deck": "a|b", "samples": "integer project-rate frames; read sampleRate and asset duration", "source": "an assetID from this Music original; string or {rawValue:string}"]
            switch action {
            case .rate: constraints["value"] = "0.25...4 (playback multiplier)"
            case .beatGrid: constraints["value"] = "20...999 BPM"; constraints["beatCount"] = "1...100000"
            case .hotcue, .jumpHotcue, .removeHotcue: constraints["index"] = "0...7"
            case .crossfader: constraints["value"] = "0...1; 0=A, 1=B"
            case .masterGain, .cueGain: constraints["value"] = "0...4 linear gain"
            case .cueSource: constraints["cueSource"] = "none|deckA|deckB; saved setting only, no separate headphone audio output"
            case .loop: constraints["lengthBeats"] = "integer 1...32; inside the saved beat grid"
            default: break
            }
            return Command(action: action.rawValue, required: ["action"] + required, optional: optional,
                runtime: action != .cueGain && action != .cueSource, constraints: constraints)
        }
    }
    static func isDJEdit(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8), data.count <= 131_072,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return object["workspace"] as? String == "dj"
    }
    static func apply(_ json: String, session: MusicProjectSession, expectedMusicRevision: Int64) throws -> MusicDJWorkspace {
        let batch = try MusicDJEditBatch.decode(Data(json.utf8))
        return try session.applyDJBatch(batch, expectedMusicRevision: expectedMusicRevision)
    }
    static func inspect(id: UUID, directory: URL, document: MusicDocument) async throws -> Observation {
        let root = directory.appendingPathComponent("Music")
        let existing = try MusicProjectSession.existingForAudioObservation(id: id, directory: root)
        let saved: MusicDJWorkspace?
        let current: MusicDJSession
        let source: String
        let available: Bool
        if let existing, existing.document.revision == document.revision, let state = existing.djPresentationState {
            saved = existing.djWorkspaceForInspection; current = state; source = "live"; available = !existing.djRecoveryRequired
        } else {
            let file = root.appendingPathComponent("dj-session.json")
            if FileManager.default.fileExists(atPath: file.path) {
                do {
                    let data = try MusicNotationPackage.regularData(file, maximum: 16 * 1_024 * 1_024)
                    let value = try MusicDJWorkspace.decodeSaved(data, projectID: document.id)
                    saved = value; current = value.session; source = "saved"; available = true
                } catch {
                    saved = nil; current = try MusicDJSession(assets: document.assets, sampleRate: document.tempoMap.sampleRate)
                    source = "unavailable"; available = false
                }
            } else {
                saved = nil; current = try MusicDJSession(assets: document.assets, sampleRate: document.tempoMap.sampleRate)
                source = "empty"; available = existing?.djRecoveryRequired != true
            }
        }
        let audio = document.assets.first(where: { $0.kind != .midiFile })
        let example = try MusicDJEditBatch(expectedDJRevision: saved?.revision ?? 0, commands:
            audio.map { [.init(action: .load, deck: .a, assetID: $0.id), .init(action: .rate, deck: .a, value: 1)] }
                ?? [.init(action: .crossfader, value: 0.5)])
        let encoded = try JSONEncoder().encode(example)
        let sidecar = root.appendingPathComponent("dj-session.json")
        let savedBytes = try? MusicNotationPackage.regularData(sidecar, maximum: 16 * 1_024 * 1_024)
        let savedSHA256 = savedBytes.map { MusicNotationPackage.digest($0) }
        let recording = existing?.djLastRecording.map { receipt in
            Recording(assetID: document.assets.first(where: { $0.contentHash == receipt.sha256 })?.id,
                frames: receipt.frames, sampleRate: receipt.sampleRate, sha256: receipt.sha256,
                recovered: receipt.recovered, sourceMusicRevision: receipt.sourceRevision)
        }
        return Observation(workspace: "dj", projectID: id, musicRevision: document.revision, djRevision: saved?.revision ?? 0,
            stateSource: source, available: available, savedSHA256: savedSHA256, sampleRate: document.tempoMap.sampleRate,
            deckA: current.deckA, deckB: current.deckB, crossfader: current.crossfader, masterGain: current.masterGain,
            playingA: current.deckA.playing, playingB: current.deckB.playing,
            recordingState: existing?.djCapturePhase.rawValue ?? "idle", recordingID: existing?.djRecordingID,
            lastRecording: recording, independentHeadphoneOutput: false, commands: commands, runActions: runActions,
            exportMaximumSeconds: min(3_600, Double(268_435_456) / Double(document.tempoMap.sampleRate)),
            editExample: String(decoding: encoded, as: UTF8.self))
    }
    static func input(_ json: String?) throws -> RunInput {
        guard let json, json.utf8.count <= 16_384 else {
            throw MusicEditJSONError(code: "missingDJInput", path: "$.inputJSON", reason: "DJ run needs its typed input.",
                expected: "expectedMusicRevision and expectedDJRevision; durationSeconds for exports, recordingID for stop")
        }
        do {
            var data = Data(json.utf8)
            if var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let allowed: Set<String> = ["expectedMusicRevision", "expectedDJRevision", "durationSeconds", "recordingID", "deck", "expectedSidecarSHA256"]
                guard Set(object.keys).isSubset(of: allowed) else { throw MusicNativeError.invalid("unexpected DJ run field") }
                for field in ["expectedMusicRevision", "expectedDJRevision"] {
                    if let text = object[field] as? String, let value = Int64(text) { object[field] = value }
                }
                data = try JSONSerialization.data(withJSONObject: object)
            }
            return try JSONDecoder().decode(RunInput.self, from: data)
        }
        catch { throw MusicEditJSONError(code: "invalidDJInput", path: "$.inputJSON", reason: "Incorrect DJ run input.",
            expected: "integer revisions, numeric durationSeconds, or the exact recordingID returned by djRecordStart") }
    }
    static func start(input: RunInput, session: MusicProjectSession, cancellation: CancellationToken) async throws -> StartedRecording {
        guard let music = input.expectedMusicRevision, let dj = input.expectedDJRevision else {
            throw MusicEditJSONError(code: "missingDJRevision", path: "$.inputJSON", reason: "DJ record start needs both source revisions.", expected: "expectedMusicRevision and expectedDJRevision from studio.read.musicDJ")
        }
        let id = try await session.startDJRecording(expectedMusicRevision: music, expectedDJRevision: dj, cancellation: cancellation)
        return StartedRecording(projectID: session.id, musicRevision: music, djRevision: dj, recordingID: id, state: "recording")
    }
    static func analyze(input: RunInput, session: MusicProjectSession) async throws -> MusicDJBeatEstimate {
        guard let music = input.expectedMusicRevision, let dj = input.expectedDJRevision, let deck = input.deck else {
            throw MusicEditJSONError(code: "missingDJAnalysisInput", path: "$.inputJSON", reason: "Beat analysis needs the captured deck source.",
                expected: "expectedMusicRevision, expectedDJRevision and deck:'a'|'b'")
        }
        return try await session.analyzeDJForModel(deck, expectedMusicRevision: music, expectedDJRevision: dj)
    }
    static func reset(input: RunInput, session: MusicProjectSession) throws -> MusicDJWorkspace {
        guard let music = input.expectedMusicRevision, let sha = input.expectedSidecarSHA256 else {
            throw MusicEditJSONError(code: "missingDJRecoveryInput", path: "$.inputJSON", reason: "Recovery needs the exact saved sidecar fingerprint.",
                expected: "expectedMusicRevision and expectedSidecarSHA256 from studio.read.musicDJ.savedSHA256")
        }
        return try session.resetDJSettingsForModel(expectedMusicRevision: music, expectedSHA256: sha)
    }
    static func output(action: String, input: RunInput, session: MusicProjectSession) async throws -> URL {
        if action == "djRecordStop" {
            guard let id = input.recordingID else { throw MusicEditJSONError(code: "missingRecordingID", path: "$.inputJSON.recordingID", reason: "Stop needs the owned active recording.", expected: "the recordingID returned by djRecordStart") }
            return try await session.stopDJRecordingAndWait(recordingID: id).file
        }
        guard ["renderDJWAV", "renderDJMP3"].contains(action), let music = input.expectedMusicRevision,
              let dj = input.expectedDJRevision, let seconds = input.durationSeconds else {
            throw MusicEditJSONError(code: "missingDJExportInput", path: "$.inputJSON", reason: "DJ export needs its captured settings and duration.", expected: "expectedMusicRevision, expectedDJRevision, durationSeconds")
        }
        return try await session.exportDJAndWait(asMP3: action == "renderDJMP3", durationSeconds: seconds,
            expectedMusicRevision: music, expectedDJRevision: dj)
    }
}
#endif
