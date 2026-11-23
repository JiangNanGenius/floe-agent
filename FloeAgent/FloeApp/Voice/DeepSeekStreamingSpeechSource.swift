// FloeApp — DeepSeek streaming read-aloud source for the continuous voice
// conversation.
//
// SPDX-License-Identifier: MPL-2.0
//
// The continuous voice session synthesizes through the bridge's `synthesize`
// seam. Two shapes exist:
//
// * AGGREGATED ROUND UNIT — the coordinator emits ONE unit for the whole
//   answer on the DeepSeek route, carrying the round's cleaned body as an
//   ordered `AsyncStream<String>` (`VoiceConversationSpeechUnit.textStream`).
//   THIS source opens the official `/v1/tools/tts` WebSocket once per round:
//   text deltas flow to the server while the model is still generating and
//   PCM flows back continuously. `finish_text` is sent when the text stream
//   ends, so the coordinator MUST terminate the stream at round-text
//   completion.
//
// * Ordinary per-sentence units keep the existing whole-text POST
//   `ConfiguredTTSSpeechSource` (manual/auto read-aloud) or the per-request
//   WebSocket adapter below. Full-text manual read-aloud and auto-read keep
//   the POST adapter; every non-DeepSeek provider keeps its adapter
//   untouched.
//
// Request identity, credential resolution, the neutral-rate seam and the
// frozen playback controls are IDENTICAL across all routes.

#if canImport(UIKit)
import Foundation
import FloeCore
import FloeProviders

@MainActor
struct DeepSeekStreamingSpeechSource {
    let snapshot: TTSSettingsSnapshot
    let settings: TTSSettingsService

    /// Continuous round synthesis over one WebSocket session. The text
    /// stream is forwarded verbatim and in order; empty deltas are ignored,
    /// whitespace is billed like any other scalar. The caller terminates the
    /// stream when the round text is complete.
    func synthesize(textStream: AsyncStream<String>, sessionID: UUID, segmentIndex: Int) -> TTSConfiguredStream {
        let (stream, sender) = TTSAudioChunkStream.make()
        let settings = self.settings
        let snapshot = self.snapshot
        let producer = Task { @MainActor in
            do {
                // Validate before the credential is read: an unusable voice
                // must report its problem and never touch the Keychain
                // (same rule as TTSConfiguredStream.make).
                guard DeepSeekSpeechAPI.voices.contains(snapshot.voiceID) else {
                    throw TTSSynthesisError.invalidConfiguration("invalid DeepSeek speech configuration")
                }
                let value = try await settings.credential(for: snapshot)
                try Task.checkCancellation()
                let session = DeepSeekStreamingSpeechSession(
                    voiceID: snapshot.voiceID, credential: value)
                for try await chunk in session.synthesize(
                    text: textStream, sessionID: sessionID, segmentIndex: segmentIndex) {
                    try Task.checkCancellation()
                    // Cooperative: a cancelled forwarder closes its own
                    // channel so a parked send can never outlive the round
                    // (and the socket behind it is cancelled with it).
                    try await CancellableSpeechSend.send(chunk, sender: sender)
                }
                sender.finish()
            } catch {
                sender.finish(throwing: error)
            }
        }
        sender.attach(producer)
        return TTSConfiguredStream(
            stream: stream,
            playbackControls: snapshot.playbackControls,
            close: { sender.finish(throwing: TTSSynthesisError.cancelled) })
    }

    /// Per-sentence WebSocket synthesis (one session per sentence) for seams
    /// that synthesize one bounded segment per request.
    func synthesize(text: String, sessionID: UUID, segmentIndex: Int, adapter: DeepSeekStreamingSpeechAdapter) -> TTSConfiguredStream {
        let request = TTSSynthesisRequest(
            sessionID: sessionID, segmentIndex: segmentIndex,
            provider: snapshot.provider, billingRoute: snapshot.billingRoute,
            region: snapshot.alibabaRegion, openAIBaseURL: snapshot.openAIBaseURL,
            modelID: snapshot.modelID,
            voiceID: snapshot.voiceID, text: text,
            speechRateRatio: TTSPlaybackControls.neutralRate,
            language: snapshot.language)
        let (stream, sender) = TTSAudioChunkStream.make()
        let adapter = adapter
        let credential: @MainActor @Sendable () async throws -> String = {
            try await settings.credential(for: snapshot)
        }
        let producer = Task { @MainActor in
            do {
                // Configuration is validated before the credential is read:
                // an unusable request must report its problem and never
                // touch the Keychain (same rule as TTSConfiguredStream.make).
                if let problem = request.validationProblem() {
                    throw TTSSynthesisError.invalidConfiguration(problem)
                }
                let value = try await credential()
                try Task.checkCancellation()
                for try await chunk in adapter.synthesize(request, credential: value) {
                    try Task.checkCancellation()
                    try await CancellableSpeechSend.send(chunk, sender: sender)
                }
                sender.finish()
            } catch {
                sender.finish(throwing: error)
            }
        }
        sender.attach(producer)
        return TTSConfiguredStream(
            stream: stream,
            playbackControls: snapshot.playbackControls,
            close: { sender.finish(throwing: TTSSynthesisError.cancelled) })
    }
}
#endif
