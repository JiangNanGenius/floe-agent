// FloeApp — User message bubble.
//
// SPDX-License-Identifier: MPL-2.0
//
// Right-aligned bubble on a faint primary tint, visually distinct from
// the assistant's left-aligned reading column. Optional attachment
// chips summarize MessagePart file/image parts inline. Text is verbatim
// (user input is not Markdown-rendered).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeModels

/// One user message: right-aligned bubble + attachment chips.
struct UserMessageBubble: View {
    let text: String
    /// Attachment display names (from file/image message parts).
    var attachments: [String] = []

    var body: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 6) {
                if !text.isEmpty {
                    credentialAwareContent
                }
                if !attachments.isEmpty {
                    FlowChips(names: attachments)
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
                            Text("安全凭据")
                                .font(FloeTheme.Typography.body.weight(.semibold))
                            Text("已安全保存，可由本任务按用途引用")
                                .font(FloeTheme.Typography.metadata)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "key.fill")
                            .foregroundStyle(FloeTheme.primary)
                    }
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("安全凭据卡")
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

/// Wrapping row of attachment chips (leading-aligned inside the
/// trailing column). Hand-rolled flow layout: chips wrap onto new rows
/// when they exceed the available width.
private struct FlowChips: View {
    let names: [String]

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in
                Label(name, systemImage: "paperclip")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        FloeTheme.primary.opacity(0.10),
                        in: Capsule()
                    )
            }
        }
    }
}
#endif
