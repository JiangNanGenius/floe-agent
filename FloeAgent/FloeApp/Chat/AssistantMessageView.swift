// FloeApp — Assistant answer rendering.
//
// SPDX-License-Identifier: MPL-2.0
//
// The assistant's answer is the visual subject of the thread: a wide,
// left-aligned reading column on the opaque reading surface, rendered
// through the shared Markdown body (InlineAnswerBodyView on iPad, the same
// MarkdownRendererView core on macOS). It deliberately does NOT mirror the
// user bubble's tint/alignment so the two roles never blur. A read-aloud
// button lets the user hear the answer where the speech service exists.

#if canImport(SwiftUI) && (canImport(UIKit) || os(macOS))
import SwiftUI

/// One assistant answer: Markdown-rendered, full-width reading column.
struct AssistantMessageView: View {
    /// Markdown source of the answer.
    let text: String
    /// True while the owning run is non-terminal (incremental tail
    /// reparse instead of full-document parse per token).
    var isStreaming: Bool = false
    var allowsReadAloud: Bool = true
    var speechOwnerID: UUID? = nil
    var onSaveToNotes: ((String) -> Void)? = nil
    /// Real file/image parts carried by the assistant notice. A returned
    /// adopted design result renders through this SAME shared chip surface
    /// (image parts keep the image icon), never through a second path.
    var attachments: [AttachmentChipItem] = []
    var onOpenAttachment: ((AttachmentChipItem) -> Void)? = nil
    var onDesignAttachment: ((AttachmentChipItem) -> Void)? = nil
    var helpRunID: UUID? = nil

    #if canImport(UIKit)
    @EnvironmentObject private var speechService: SpeechService
    @Environment(\.continuousVoiceActive) private var continuousVoiceActive
    @State private var localSpeechOwnerID = UUID()

    private var playbackOwnerID: UUID { speechOwnerID ?? localSpeechOwnerID }
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            #if canImport(UIKit)
            InlineAnswerBodyView(source: text, isStreaming: isStreaming, helpRunID: helpRunID)
            #else
            // The macOS host reuses the identical Markdown reading core;
            // InlineAnswerBodyView's timer/host overlays are iPad surfaces.
            MarkdownRendererView(source: text, isStreaming: isStreaming)
            #endif
            if !attachments.isEmpty {
                AttachmentChipRow(items: attachments, alignment: .leading, onOpen: onOpenAttachment, onDesign: onDesignAttachment)
            }
            #if canImport(UIKit)
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
                    ChatMessageCopyButton(text: text)
                }
            }
            if allowsReadAloud, speechService.failureOwnerID == playbackOwnerID, let failureKey = speechService.failureKey {
                HStack {
                    Text(LocalizedStringKey(failureKey)).font(.footnote).foregroundStyle(.red)
                    Button("voice.action.retry") { speechService.retry() }
                    Button("voice.action.system_voice") { speechService.useSystemVoice() }
                }
                .disabled(continuousVoiceActive)
            }
            #else
            // No speech service is linked into the native Mac host; the
            // copy action stays available on the same reading column.
            if !isStreaming, !text.isEmpty {
                HStack(spacing: 12) {
                    ChatMessageCopyButton(text: text)
                }
            }
            #endif
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "thread.role.assistant"))
        .accessibilityIdentifier("thread.assistant_message")
        #if canImport(UIKit)
        .onDisappear { speechService.clearFailure(ownerID: playbackOwnerID) }
        #endif
    }

    #if canImport(UIKit)
    private var ownsPlayback: Bool {
        speechService.activeOwnerID == playbackOwnerID
    }

    private var readAloudButton: some View {
        let isThisMessageSpeaking = speechService.isSpeaking && ownsPlayback
        return Button {
            speechService.speak(text, ownerID: playbackOwnerID)
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
    #endif
}
#endif
