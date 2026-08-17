// FloeApp — Text-to-speech for assistant answers.
//
// SPDX-License-Identifier: MPL-2.0
//
// Wraps AVSpeechSynthesizer so assistant answers can be read aloud. One
// utterance at a time; tapping speak again stops the current utterance.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import AVFoundation
import SwiftUI

@MainActor
final class SpeechService: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?

    @Published private(set) var isSpeaking = false
    @Published private(set) var speakingText: String?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// Starts speaking `text`, or stops if the same text is already playing.
    func speak(_ text: String) {
        if isSpeaking {
            if speakingText == text {
                stop()
                return
            }
            stop()
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: Self.preferredLanguage(for: text))
            ?? AVSpeechSynthesisVoice(language: "en-US")
        activeUtterance = utterance
        synthesizer.speak(utterance)
        isSpeaking = true
        speakingText = text
    }

    func stop() {
        activeUtterance = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
        speakingText = nil
    }

    private static func preferredLanguage(for text: String) -> String {
        let cjk = text.unicodeScalars.filter {
            (0x3400...0x9FFF).contains(Int($0.value))
        }.count
        let latin = text.unicodeScalars.filter {
            (0x41...0x5A).contains(Int($0.value)) || (0x61...0x7A).contains(Int($0.value))
        }.count
        return cjk >= latin ? "zh-CN" : "en-US"
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard self.activeUtterance === utterance else { return }
            self.activeUtterance = nil
            self.isSpeaking = false
            self.speakingText = nil
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            guard self.activeUtterance === utterance else { return }
            self.activeUtterance = nil
            self.isSpeaking = false
            self.speakingText = nil
        }
    }
}
#endif
