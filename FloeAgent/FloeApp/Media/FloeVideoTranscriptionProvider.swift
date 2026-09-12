// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && canImport(WhisperKit)
import Foundation
import VideoEditorKit

/// The editor receives only timed text; Floe owns model selection and fallback.
struct FloeVideoTranscriptionProvider: VideoTranscriptionProvider {
    let root: URL
    func transcribeVideo(input: VideoTranscriptionInput) async throws -> VideoTranscriptionResult {
        guard case .fileURL(let source) = input.source,
              source.isFileURL,
              source.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(
                root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else { throw TranscriptError.invalidVideoSource }
        let language = VoiceRecognitionLanguage(rawValue: UserDefaults.standard.string(forKey: VoiceRecognitionLanguage.defaultsKey) ?? "") ?? .automatic
        do {
            let segments = try await FileSpeechTranscriber.shared.transcribe(url: source, language: language)
            return .init(segments: segments.map { segment in
                .init(id: UUID(), startTime: segment.start, endTime: segment.end, text: segment.text,
                      words: segment.words.map { .init(id: UUID(), startTime: $0.start, endTime: $0.end, text: $0.text) })
            })
        } catch is CancellationError { throw TranscriptError.cancelled }
        catch { throw TranscriptError.providerFailure(message: error.localizedDescription) }
    }
}
#endif
