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
    var allowsReadAloud: Bool = true
    var onSaveToNotes: ((String) -> Void)? = nil
    /// Real file/image parts carried by the assistant notice. A returned
    /// adopted design result renders through this SAME shared chip surface
    /// (image parts keep the image icon), never through a second path.
    var attachments: [AttachmentChipItem] = []
    var onOpenAttachment: ((AttachmentChipItem) -> Void)? = nil

    @EnvironmentObject private var speechService: SpeechService
    @Environment(\.continuousVoiceActive) private var continuousVoiceActive

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MarkdownRendererView(source: text, isStreaming: isStreaming)
            if !attachments.isEmpty {
                AttachmentChipRow(items: attachments, alignment: .leading, onOpen: onOpenAttachment)
            }
            if !isStreaming, !text.isEmpty {
                HStack(spacing: 12) {
                    if allowsReadAloud { readAloudButton }
                    if speechService.isSpeaking && ownsPlayback {
                        Button(speechService.isPaused ? "voice.action.resume" : "voice.action.pause", systemImage: speechService.isPaused ? "play.fill" : "pause.fill") {
                            if speechService.isPaused { speechService.resume() } else { speechService.pause() }
                        }
                        .font(FloeTheme.Typography.metadata)
                        .frame(minHeight: FloeTheme.minimumTarget)
                    }
                    copyButton
                    if let onSaveToNotes {
                        Button("chat.assistant_message_view.save_to_notes", systemImage: "square.and.arrow.down") { onSaveToNotes(text) }
                            .font(FloeTheme.Typography.metadata).frame(minHeight: FloeTheme.minimumTarget)
                    }
                }
            }
            if allowsReadAloud, let failed = speechService.failedText, AnswerSpeechText.plainText(failed) == AnswerSpeechText.plainText(text), let failureKey = speechService.failureKey {
                HStack {
                    Text(LocalizedStringKey(failureKey)).font(.footnote).foregroundStyle(.red)
                    Button("voice.action.retry") { speechService.retry() }
                    Button("voice.action.system_voice") { speechService.useSystemVoice() }
                }
                .disabled(continuousVoiceActive)
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
            Label("workspace.workspace_canvas_view.copy", systemImage: "doc.on.doc")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityLabel("workspace.workspace_canvas_view.copy")
    }

    private var ownsPlayback: Bool {
        guard let current = speechService.speakingText else { return false }
        return AnswerSpeechText.plainText(current) == AnswerSpeechText.plainText(text)
    }

    private var readAloudButton: some View {
        let isThisMessageSpeaking = speechService.isSpeaking && ownsPlayback
        return Button {
            speechService.speak(text)
        } label: {
            Label(
                isThisMessageSpeaking ? "chat.assistant_message_view.stop_reading" : "chat.assistant_message_view.read_aloud",
                systemImage: isThisMessageSpeaking ? "stop.circle.fill" : "speaker.wave.2"
            )
            .font(FloeTheme.Typography.metadata)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(continuousVoiceActive)
        .frame(minHeight: FloeTheme.minimumTarget)
        .accessibilityLabel(isThisMessageSpeaking ? "chat.assistant_message_view.stop_reading" : "chat.assistant_message_view.read_aloud")
    }
}
#endif
