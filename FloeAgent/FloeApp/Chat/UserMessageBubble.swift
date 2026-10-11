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

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels

/// One attachment chip: the display name plus the REAL part kind (an image
/// attachment must not render as a generic file, and vice versa).
struct AttachmentChipItem: Identifiable, Hashable {
    let id: String
    let name: String
    let kind: MessagePart.Kind

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
                kind: part.kind)
        }
    }
}

/// Wrapping row of attachment chips. Leading-aligned inside trailing
/// columns and trailing-aligned in the assistant reading column.
struct AttachmentChipRow: View {
    let items: [AttachmentChipItem]
    var alignment: HorizontalAlignment = .trailing

    var body: some View {
        VStack(alignment: alignment, spacing: 4) {
            ForEach(items) { item in
                Label(item.name, systemImage: item.systemImage)
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        FloeTheme.primary.opacity(0.10),
                        in: Capsule()
                    )
                    .accessibilityIdentifier("thread.attachment.\(item.id)")
            }
        }
    }
}

/// One user message: right-aligned bubble + attachment chips.
struct UserMessageBubble: View {
    let text: String
    /// Real attachment parts of the message (names + file/image kind).
    var attachments: [AttachmentChipItem] = []

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                if !text.isEmpty {
                    credentialAwareContent
                }
                if !attachments.isEmpty {
                    AttachmentChipRow(items: attachments, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
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

private struct CredentialMessagePart: Identifiable {
    enum Kind { case text, credential }
    let id = UUID()
    let kind: Kind
    let value: String

    static func parse(_ text: String) -> [Self] {
        let pattern = #"⟨credential:[0-9A-Fa-f-]{36}⟩"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.init(kind: .text, value: text)]
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [Self] = []
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: nsRange) {
            guard let range = Range(match.range, in: text) else { continue }
            if cursor < range.lowerBound {
                result.append(.init(kind: .text, value: String(text[cursor..<range.lowerBound])))
            }
            result.append(.init(kind: .credential, value: String(text[range])))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            result.append(.init(kind: .text, value: String(text[cursor...])))
        }
        return result.isEmpty ? [.init(kind: .text, value: text)] : result
    }
}
#endif
