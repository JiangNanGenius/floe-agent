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
                    Text(text)
                        .font(FloeTheme.Typography.body)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            FloeTheme.primary.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 12)
                        )
                }
                if !attachments.isEmpty {
                    FlowChips(names: attachments)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "thread.role.user"))
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
