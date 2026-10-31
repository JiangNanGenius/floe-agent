// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import VideoEditorKit

/// The editor receives only real timed text; Floe owns provider selection,
/// cloud-first behavior and local fallback. When the App-owned service is
/// supplied, captions use the SAME shared ASR profile selection as microphone
/// dictation and file transcription instead of a parallel local-only path.
struct FloeVideoTranscriptionProvider: VideoTranscriptionProvider {
    let root: URL
    let assistant: AssistantAudioService?

    init(root: URL, assistant: AssistantAudioService? = nil) {
        self.root = root
        self.assistant = assistant
    }

    func transcribeVideo(input: VideoTranscriptionInput) async throws -> VideoTranscriptionResult {
        guard case .fileURL(let source) = input.source,
              source.isFileURL,
              source.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
                root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw TranscriptError.invalidVideoSource }
        let language = VoiceRecognitionLanguage(rawValue: UserDefaults.standard.string(forKey: VoiceRecognitionLanguage.defaultsKey) ?? "") ?? .automatic
        do {
            let segments: [TimedSpeechSegment]
            if let assistant {
                let result = try await assistant.transcribe(
                    fileURL: source,
                    language: language,
                    serviceID: nil,
                    requiresTiming: true)
                segments = result.segments
            } else {
                segments = try await FileSpeechTranscriber.shared.transcribe(url: source, language: language)
            }
            return .init(segments: segments.map { segment in
                .init(id: UUID(), startTime: segment.start, endTime: segment.end, text: segment.text,
                      words: segment.words.map { .init(id: UUID(), startTime: $0.start, endTime: $0.end, text: $0.text) })
            })
        } catch is CancellationError { throw TranscriptError.cancelled }
        catch { throw TranscriptError.providerFailure(message: error.localizedDescription) }
    }
}
#endif
