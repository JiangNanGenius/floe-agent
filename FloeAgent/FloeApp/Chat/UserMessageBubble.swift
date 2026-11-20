// FloeApp — User message bubble + shared attachment chips.
//
// SPDX-License-Identifier: MPL-2.0
//
// Right-aligned bubble on a faint primary tint, visually distinct from
// the assistant's left-aligned reading column. Optional attachment
// chips summarize MessagePart file/image parts inline. Text is verbatim
// (user input is not Markdown-rendered).
//
// `AttachmentChipRow` is the ONE reusable attachment surface: the user
// bubble renders it trailing, and returned design results (assistant
// notices carrying a real file/image part) render the same chips leading,
// so a returned attachment is never a second, bespoke presentation path.

#if canImport(SwiftUI)
import SwiftUI
import FloeCore
import FloeModels
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// One attachment chip: the display name plus the REAL part kind (an image
/// attachment must not render as a generic file, and vice versa).
struct AttachmentChipItem: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: MessagePart.Kind
    var attachmentID: UUID? = nil

    var systemImage: String {
        switch kind {
        case .image: return "photo"
        case .file: return "doc"
        default: return "paperclip"
        }
    }

    /// Maps persisted message parts to chips in stored order. Text/reasoning
    /// parts are not attachments.
    static func items(in parts: [MessagePart]) -> [AttachmentChipItem] {
        parts.compactMap { part in
            guard part.kind == .file || part.kind == .image else { return nil }
            let name = part.metadata["name"] ?? part.text ?? ""
            guard !name.isEmpty else { return nil }
            return AttachmentChipItem(
                id: part.attachmentID?.uuidString ?? part.id.uuidString,
                name: name,
                kind: part.kind, attachmentID: part.attachmentID)
        }
    }
}

/// Wrapping row of attachment chips. Leading-aligned inside trailing
/// columns and trailing-aligned in the assistant reading column.
struct AttachmentChipRow: View {
    let items: [AttachmentChipItem]
    var alignment: HorizontalAlignment = .trailing
    var onOpen: ((AttachmentChipItem) -> Void)? = nil
    var onDesign: ((AttachmentChipItem) -> Void)? = nil

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            ForEach(items) { item in
                Button { onOpen?(item) } label: {
                    Label(item.name, systemImage: item.systemImage)
                        .font(FloeTheme.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                        .background(FloeTheme.primary.opacity(0.10), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if let onDesign, let id = item.attachmentID {
                        Button { onDesign(item) } label: {
                            Label {
                                Text("design.owner.from_attachment_named \(item.name)")
                            } icon: {
                                Image(systemName: "square.on.square.dashed")
                            }
                        }
                        .accessibilityIdentifier("design.owner.fromAttachment.\(id.uuidString)")
                    }
                }
                .disabled(onOpen == nil)
                .accessibilityLabel(Text("chat.attachment.open_named \(item.name)"))
                .accessibilityIdentifier("thread.attachment.\(item.id)")
                #if FLOE_UNIFIED_MAC && FLOE_MAC_HOST_SMOKE
                .background(MacWorkbenchButtonFrameReader { HostAgentWorkspaceView.smokeAttachmentFrames[item.id] = $0 })
                #endif
            }
        }
    }
}

/// The timestamp belongs to the persisted message or assistant text event.
struct ChatMessageFooter: View {
    let sentAt: Date
    let messageID: String
    var userText: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(sentAt, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("thread.message.date.\(messageID)")
            if let userText, let text = CredentialMessagePart.clipboardText(userText) {
                ChatMessageCopyButton(text: text)
                    .accessibilityIdentifier("thread.user.copy.\(messageID)")
            }
        }
    }
}

struct ChatMessageCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            #if canImport(UIKit)
            UIPasteboard.general.string = text
            #elseif canImport(AppKit)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            #endif
            copied = true
        } label: {
            Label(copyTitle,
                  systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
                .frame(minWidth: FloeTheme.minimumTarget, minHeight: FloeTheme.minimumTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copied = false }
        }
    }

    private var copyTitle: String {
        #if canImport(UIKit)
        copied ? IDELanguageRunText.t("已复制", "Copied") : FloeL10n.l("workspace.workspace_canvas_view.copy")
        #else
        copied ? String(localized: "action.copied") : String(localized: "action.copy")
        #endif
    }

}

/// One user message: right-aligned bubble + attachment chips.
struct UserMessageBubble: View {
    let text: String
    /// Real attachment parts of the message (names + file/image kind).
    var attachments: [AttachmentChipItem] = []
    var onOpenAttachment: ((AttachmentChipItem) -> Void)? = nil
    var onDesignAttachment: ((AttachmentChipItem) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                if !text.isEmpty {
                    credentialAwareContent
                }
                if !attachments.isEmpty {
                    AttachmentChipRow(items: attachments, alignment: .trailing, onOpen: onOpenAttachment, onDesign: onDesignAttachment)
                }
            }
        }
        // Keep the role as a group label without replacing the actual message
        // and safe credential-card labels in the accessibility tree.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "thread.role.user"))
    }

    @ViewBuilder
    private var credentialAwareContent: some View {
        let parts = CredentialMessagePart.parse(text)
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(parts) { part in
                switch part.kind {
                case .text:
                    Text(part.value)
                        .font(FloeTheme.Typography.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                case .credential:
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("chat.user_message_bubble.secure_credentials")
                                .font(FloeTheme.Typography.body.weight(.semibold))
                            Text("chat.user_message_bubble.saved_securely_this_task_can_reference")
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "key.fill")
                            .foregroundStyle(FloeTheme.primary)
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("chat.user_message_bubble.secure_credentials_card")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FloeTheme.primary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct CredentialMessagePart: Identifiable {
    enum Kind { case text, credential }
    let id: Int
    let kind: Kind
    let value: String

    /// Copy the displayed message, preserving whitespace and excluding credential handles.
    static func clipboardText(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        guard text.contains("⟨credential:") else { return text }
        let parts = parse(text)
        guard parts.contains(where: { $0.kind == .text && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return nil }
        return parts.map { part in
            switch part.kind {
            case .text: return part.value
            case .credential: return String(localized: "chat.user_message_bubble.secure_credentials")
            }
        }.joined()
    }

    static func parse(_ text: String) -> [Self] {
        let pattern = #"⟨credential:[0-9A-Fa-f-]{36}⟩"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.init(id: 0, kind: .text, value: text)]
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [Self] = []
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound {
                result.append(.init(id: result.count, kind: .text, value: String(text[cursor..<range.lowerBound])))
            }
            result.append(.init(id: result.count, kind: .credential, value: String(text[range])))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result.append(.init(id: result.count, kind: .text, value: String(text[cursor...])))
        }
        return result.isEmpty ? [.init(id: 0, kind: .text, value: text)] : result
    }
}
#endif
