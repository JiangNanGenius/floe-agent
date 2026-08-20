// FloeApp — Assistant answer rendering.
//
// SPDX-License-Identifier: MPL-2.0
//
// The assistant's answer is the visual subject of the thread: a wide,
// left-aligned reading column on the opaque reading surface, rendered
// through MarkdownRendererView. It deliberately does NOT mirror the
// user bubble's tint/alignment so the two roles never blur. A read-aloud
// button lets the user hear the answer.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// One assistant answer: Markdown-rendered, full-width reading column.
struct AssistantMessageView: View {
    /// Markdown source of the answer.
    let text: String
    /// True while the owning run is non-terminal (incremental tail
    /// reparse instead of full-document parse per token).
    var isStreaming: Bool = false

    @EnvironmentObject private var speechService: SpeechService

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownRendererView(source: text, isStreaming: isStreaming)
            if !isStreaming, !text.isEmpty {
                HStack(spacing: 12) {
                    readAloudButton
                    copyButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "thread.role.assistant"))
        .accessibilityIdentifier("thread.assistant_message")
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = text
        } label: {
            Label("复制", systemImage: "doc.on.doc")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityLabel("复制")
    }

    private var readAloudButton: some View {
        let isThisMessageSpeaking = speechService.isSpeaking
            && speechService.speakingText == text
        return Button {
            speechService.speak(text)
        } label: {
            Label(
                isThisMessageSpeaking ? "停止朗读" : "朗读",
                systemImage: isThisMessageSpeaking ? "stop.circle.fill" : "speaker.wave.2"
            )
            .font(FloeTheme.Typography.metadata)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityLabel(isThisMessageSpeaking ? "停止朗读" : "朗读")
    }
}
#endif
