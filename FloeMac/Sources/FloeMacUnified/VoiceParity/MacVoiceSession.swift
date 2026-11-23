// SPDX-License-Identifier: MPL-2.0

import Combine
import FloeProviders
import Foundation

/// One user-started microphone owner. Dictation commits to the existing
/// draft, while continuous voice uses the existing task runtime for turns.
@MainActor
final class MacVoiceSession: ObservableObject {
    enum Mode { case dictation, conversation }
    enum Phase { case idle, preparing, listening, finishing, waiting, speaking }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var mode: Mode?
    @Published private(set) var transcript = ""
    @Published private(set) var problem: String?
    var isActive: Bool { phase != .idle }

    private let capture: any MacVoiceCapturing
    private let speaker: any MacVoiceSpeaking
    private var generation = UUID()
    private var listeningID = UUID()
    private var releaseWork: (() -> Void)?
    private var work: Task<Void, Never>?
    private var endpoint: Task<Void, Never>?
    private var playbackTimeout: Task<Void, Never>?
    private var lastSpeech: ContinuousClock.Instant?
    private var lastText: ContinuousClock.Instant?
    private var language: Locale = .current
    private var compose: ((String) -> Void)?
    private var turn: ((String) async throws -> String)?

    init(capture: any MacVoiceCapturing = MacSpeechCapture(),
         speaker: any MacVoiceSpeaking = MacVoiceSpeaker()) {
        self.capture = capture
        self.speaker = speaker
    }

    func start(_ mode: Mode, locale: Locale, admit: () -> (() -> Void)?,
               compose: @escaping (String) -> Void, turn: @escaping (String) async throws -> String) {
        guard !isActive, let releaseWork = admit() else { return }
        generation = UUID()
        self.releaseWork = releaseWork
        self.mode = mode
        self.language = locale
        self.compose = compose
        self.turn = turn
        problem = nil
        listen()
    }

    func finishDictation() {
        guard mode == .dictation, phase == .listening else { stop(); return }
        let owner = generation
        phase = .finishing
        capture.finishInput()
        guard generation == owner, phase == .finishing else { return }
        endpoint?.cancel()
        endpoint = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
            guard let self, generation == owner else { return }
            commitDictation()
        }
    }

    func stop() {
        generation = UUID()
        listeningID = UUID()
        work?.cancel()
        work = nil
        endpoint?.cancel()
        endpoint = nil
        playbackTimeout?.cancel()
        playbackTimeout = nil
        capture.cancel()
        speaker.stop()
        compose = nil
        turn = nil
        transcript = ""
        mode = nil
        phase = .idle
        releaseWork?()
        releaseWork = nil
    }

    private func listen() {
        let owner = generation
        let input = UUID()
        listeningID = input
        transcript = ""
        lastSpeech = nil
        lastText = nil
        phase = .preparing
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await capture.start(locale: language) { [weak self] update in
                    guard let self, generation == owner, listeningID == input else { return }
                    receive(update)
                }
                guard generation == owner, listeningID == input, phase == .preparing else { return }
                phase = .listening
            } catch is CancellationError {
                if generation == owner, listeningID == input { stop() }
            } catch {
                if generation == owner, listeningID == input {
                    fail((error as? MacVoiceCaptureError)?.message
                         ?? String(localized: "mac.voice.recognitionFailed"))
                }
            }
        }
    }

    private func receive(_ update: MacVoiceInputUpdate) {
        guard phase == .preparing || phase == .listening || phase == .finishing else { return }
        switch update {
        case .speechDetected:
            lastSpeech = .now
        case .text(let text, let final):
            let clean = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(8_000))
            if !clean.isEmpty, clean != transcript {
                transcript = clean
                lastText = .now
            }
            if mode == .dictation {
                if final { commitDictation() }
            } else if final && !VoiceConversationTurnValidity.isValidTurn(transcript) {
                fail(String(localized: "mac.voice.noSpeech"))
            } else if VoiceConversationTurnValidity.isValidTurn(transcript) {
                armEndpoint()
            }
        case .failed:
            if mode == .dictation, phase == .finishing { commitDictation() }
            else { fail(String(localized: "mac.voice.recognitionFailed")) }
        }
    }

    private func armEndpoint() {
        let silence = Duration.seconds(VoiceConversationEndpointPolicy.silenceWindow(for: transcript))
        let reference = max(lastText ?? .now, lastSpeech ?? lastText ?? .now)
        let remaining = max(.zero, silence - reference.duration(to: .now))
        let owner = generation
        endpoint?.cancel()
        endpoint = Task { [weak self] in
            do { try await Task.sleep(for: remaining) } catch { return }
            guard let self, generation == owner, phase == .listening else { return }
            let recent = max(lastText ?? .now, lastSpeech ?? lastText ?? .now)
            if recent.duration(to: .now) < silence {
                armEndpoint()
            } else {
                sendTurn()
            }
        }
    }

    private func commitDictation() {
        let text = transcript
        let commit = compose
        stop()
        if !text.isEmpty { commit?(text) }
    }

    private func sendTurn() {
        guard let turn, VoiceConversationTurnValidity.isValidTurn(transcript) else { return }
        let owner = generation
        let text = transcript
        listeningID = UUID()
        capture.cancel()
        phase = .waiting
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let answer = try await turn(text)
                guard generation == owner, !Task.isCancelled else { return }
                let spoken = Self.speechText(answer)
                if !spoken.isEmpty {
                    phase = .speaking
                    playbackTimeout = Task { [weak self] in
                        do { try await Task.sleep(for: .seconds(180)) } catch { return }
                        guard let self, generation == owner, phase == .speaking else { return }
                        fail(String(localized: "mac.voice.playbackFailed"))
                    }
                    let played = await speaker.speak(spoken, locale: language)
                    guard generation == owner, !Task.isCancelled else { return }
                    playbackTimeout?.cancel()
                    playbackTimeout = nil
                    guard played else {
                        fail(String(localized: "mac.voice.playbackFailed"))
                        return
                    }
                }
                listen()
            } catch is CancellationError {
                if generation == owner { stop() }
            } catch {
                if generation == owner { fail(String(localized: "mac.voice.turnFailed")) }
            }
        }
    }

    static func speechText(_ answer: String) -> String {
        let prose = String(answer.prefix(8_000))
            .replacingOccurrences(of: "(?s)```.*?(?:```|$)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: .regularExpression)
        let chinese = prose.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
        let spoken = SpeechAnswerProjection.project(prose, destination: .local(readLinks: false,
            language: chinese ? .chinese : .english)).spokenText
        return spoken.contains { $0.isLetter || $0.isNumber } ? spoken : ""
    }

    private func fail(_ message: String) {
        stop()
        problem = message
    }
}
